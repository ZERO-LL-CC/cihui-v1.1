import { worker, MessageEvents, ThreadWorkerGlobalScope, util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import mindSporeLite from '@ohos.ai.mindSporeLite';

/**
 * TrOCR 探针 Worker：承接全部重活（rawfile->沙箱拷贝、loadModelFromFile、
 * encoder/decoder 推理、自回归解码、文本比对），避免同步 fs 与原生加载
 * 阻塞 UI 主线程触发 appfreeze 看门狗。
 *
 * 上下文限制与对策：
 *   - Worker 无 UIAbilityContext / ResourceManager：沙箱目录由主线程传入
 *     probeDir；rawfile 以主线程 getRawFdSync 预取的 fd+offset+length 传入。
 *   - /proc/self/status 为进程级，Worker 内读 VmRSS 语义不变。
 *
 * 消息协议：
 *   主 -> Worker（启动，仅一条）:
 *     { cmd:'run', device:'cpu'|'nnrt', probeDir:string,
 *       rawFiles: Record<string, RawFdInfo> }
 *   Worker -> 主:
 *     { type:'log', line:string }
 *     { type:'summary', device:string, summary:PipelineSummary }
 *     { type:'fail', message:string }
 */

interface RawFdInfo {
  fd: number;
  offset: number;
  length: number;
}

interface RunRequest {
  cmd: string;
  device: string;
  probeDir: string;
  rawFiles: Record<string, RawFdInfo>;
}

interface LogMessage {
  type: string;
  line: string;
}

interface SummaryMessage {
  type: string;
  device: string;
  summary: PipelineSummary;
}

interface FailMessage {
  type: string;
  message: string;
}

// ---------- MindSpore Lite Context 的本地结构镜像（SDK 未导出这些 interface） ----------
interface ProbeCpuDevice {
  threadNum?: number;
  threadAffinityMode?: mindSporeLite.ThreadAffinityMode;
  threadAffinityCoreList?: number[];
  precisionMode?: string;
}

interface ProbeNNRTDevice {
  deviceID?: bigint;
  performanceMode?: mindSporeLite.PerformanceMode;
  priority?: mindSporeLite.Priority;
}

interface ProbeMsContext {
  target?: string[];
  cpu?: ProbeCpuDevice;
  nnrt?: ProbeNNRTDevice;
}

interface PreparedFile {
  path: string;
  copyMs: number;
}

/** 单轮设备流水线的汇总结果 */
interface PipelineSummary {
  encMs: number;
  firstMs: number;
  step1Argmax: number;
  steps: number;
  avgStepMs: number;
  totalStepMs: number;
  text: string;
  match: boolean;
  resizeWorked: boolean;
  s12Ok: number;
}

// ---------- 常量（与 PC spike 转换参数严格一致） ----------
const DOMAIN: number = 0x0000;
const TAG: string = 'TrOcrProbe';
const START_TOKEN: number = 2;      // GPT-2 <|endoftext|>，也是 decoder_start_token_id
const EOS_TOKEN: number = 2;
const MAX_NEW_TOKENS: number = 20;
const ENC_SEQ: number = 577;        // (384/16)^2 + 1
const NUM_LAYERS: number = 12;
const NUM_HEADS: number = 16;
const HEAD_DIM: number = 64;
const PIXEL_BIN_BYTES: number = 3 * 384 * 384 * 4;
const PC_BASELINE_TEXT: string = 'Hello world .';
const PC_STEP1_ARGMAX: number = 31414;

const workerPort: ThreadWorkerGlobalScope = worker.workerPort;

function postLog(msg: string): void {
  const line = `${new Date().toISOString().slice(11, 23)} ${msg}`;
  hilog.info(DOMAIN, TAG, '%{public}s', line);
  const m: LogMessage = { type: 'log', line: line };
  workerPort.postMessage(m);
}

/** 读 /proc/self/status 的 VmRSS（kB），失败返回 -1 */
function readVmRssKb(): number {
  try {
    const text: string = fs.readTextSync('/proc/self/status');
    const m: RegExpMatchArray | null = text.match(/VmRSS:\s+(\d+)\s+kB/);
    if (m !== null && m.length > 1) {
      return parseInt(m[1], 10);
    }
  } catch (err) {
    hilog.warn(DOMAIN, TAG, 'readVmRss failed: %{public}s', JSON.stringify(err));
  }
  return -1;
}

function meanOf(arr: number[]): number {
  if (arr.length === 0) {
    return 0;
  }
  let s = 0;
  for (const v of arr) {
    s += v;
  }
  return Math.round(s / arr.length);
}

/** GPT-2 bytes_to_unicode 的逆映射：charCode -> 原始字节 */
function buildByteDecoder(): Map<number, number> {
  const bs: number[] = [];
  for (let b = 33; b <= 126; b++) {
    bs.push(b);
  }
  for (let b = 161; b <= 172; b++) {
    bs.push(b);
  }
  for (let b = 174; b <= 255; b++) {
    bs.push(b);
  }
  const cs: number[] = bs.slice();
  let n = 0;
  for (let b = 0; b < 256; b++) {
    if (bs.indexOf(b) < 0) {
      bs.push(b);
      cs.push(256 + n);
      n++;
    }
  }
  const m: Map<number, number> = new Map<number, number>();
  for (let i = 0; i < bs.length; i++) {
    m.set(cs[i], bs[i]);
  }
  return m;
}

/** token id 序列 -> 文本（跳过特殊 token，等价 skip_special_tokens） */
function decodeGpt2Ids(vocabInv: Map<number, string>, ids: number[]): string {
  const byteDec: Map<number, number> = buildByteDecoder();
  const bytes: number[] = [];
  for (const id of ids) {
    if (id === EOS_TOKEN || id === START_TOKEN) {
      continue;
    }
    const tok: string | undefined = vocabInv.get(id);
    if (tok === undefined) {
      continue;
    }
    for (let i = 0; i < tok.length; i++) {
      const b: number | undefined = byteDec.get(tok.charCodeAt(i));
      if (b !== undefined) {
        bytes.push(b);
      }
    }
  }
  const u8: Uint8Array = new Uint8Array(bytes);
  return util.TextDecoder.create('utf-8').decodeToString(u8);
}

function argmax(ab: ArrayBuffer): number {
  const f = new Float32Array(ab);
  let best = 0;
  let bv = f[0];
  for (let i = 1; i < f.length; i++) {
    if (f[i] > bv) {
      bv = f[i];
      best = i;
    }
  }
  return best;
}

/** rawfile(fd) -> 沙箱流式拷贝（4MB 分块），同尺寸已存在则跳过 */
function copyFdToSandbox(info: RawFdInfo, dstPath: string): number {
  try {
    const st: fs.Stat = fs.statSync(dstPath);
    if (st.size === info.length) {
      return 0;
    }
  } catch (err) {
    // 文件不存在，走正常拷贝
  }
  const file: fs.File = fs.openSync(dstPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
  const CHUNK: number = 4 * 1024 * 1024;
  const buf: ArrayBuffer = new ArrayBuffer(CHUNK);
  let pos: number = 0;
  while (pos < info.length) {
    const want: number = Math.min(CHUNK, info.length - pos);
    const got: number = fs.readSync(info.fd, buf, { offset: info.offset + pos, length: want });
    if (got <= 0) {
      break;
    }
    fs.writeSync(file.fd, buf, { length: got });
    pos += got;
  }
  fs.closeSync(file.fd);
  return pos;
}

function prepareFile(probeDir: string, name: string, info: RawFdInfo): PreparedFile {
  try {
    fs.mkdirSync(probeDir, true);
  } catch (_e) {
    // 目录已存在，忽略
  }
  const dst: string = `${probeDir}/${name}`;
  const t0 = Date.now();
  const copied: number = copyFdToSandbox(info, dst);
  const pf: PreparedFile = { path: dst, copyMs: copied === 0 ? 0 : Date.now() - t0 };
  return pf;
}

function buildContext(device: string, deviceId?: bigint): ProbeMsContext {
  const c: ProbeMsContext = {};
  if (device === 'nnrt' && deviceId !== undefined) {
    c.target = ['nnrt'];
    const nd: ProbeNNRTDevice = {};
    nd.deviceID = deviceId;
    nd.performanceMode = mindSporeLite.PerformanceMode.PERFORMANCE_HIGH;
    c.nnrt = nd;
  } else {
    c.target = ['cpu'];
    const cd: ProbeCpuDevice = {};
    cd.threadNum = 4;
    cd.threadAffinityMode = mindSporeLite.ThreadAffinityMode.BIG_CORES_FIRST;
    c.cpu = cd;
  }
  return c;
}

function loadVocab(probeDir: string, info: RawFdInfo): Map<number, string> {
  const pf: PreparedFile = prepareFile(probeDir, 'vocab.json', info);
  const text: string = fs.readTextSync(pf.path);
  const obj: Record<string, number> = JSON.parse(text) as Record<string, number>;
  const inv: Map<number, string> = new Map<number, string>();
  const keys: string[] = Object.keys(obj);
  for (const k of keys) {
    inv.set(obj[k], k);
  }
  postLog(`vocab loaded: ${keys.length} entries`);
  return inv;
}

/**
 * 单设备完整流水线（Worker 线程内）。所有模型引用都是本函数局部变量——
 * 函数返回即断引用，随后主线程 terminate Worker 并测 RSS 回落。
 */
async function runDevicePipeline(device: string, probeDir: string, rawFiles: Record<string, RawFdInfo>): Promise<PipelineSummary> {
  const summary: PipelineSummary = {
    encMs: -1, firstMs: -1, step1Argmax: -1, steps: 0, avgStepMs: -1,
    totalStepMs: -1, text: '', match: false, resizeWorked: false, s12Ok: 0
  };
  const t0 = Date.now();

  // 1. 拷贝 + 加载
  const encFile: PreparedFile = prepareFile(probeDir, 'encoder_int8w.ms', rawFiles['encoder_int8w.ms']);
  const firstFile: PreparedFile = prepareFile(probeDir, 'decoder_first_int8w.ms', rawFiles['decoder_first_int8w.ms']);
  const dynFile: PreparedFile = prepareFile(probeDir, 'decoder_step_int8w.ms', rawFiles['decoder_step_int8w.ms']);
  const s12File: PreparedFile = prepareFile(probeDir, 'decoder_step_S12_int8w.ms', rawFiles['decoder_step_S12_int8w.ms']);
  const pvFile: PreparedFile = prepareFile(probeDir, 'pixel_values.bin', rawFiles['pixel_values.bin']);
  postLog(`copy enc=${encFile.copyMs}ms first=${firstFile.copyMs}ms dyn=${dynFile.copyMs}ms s12=${s12File.copyMs}ms rss=${readVmRssKb()}kB`);

  let ctx: ProbeMsContext = buildContext('cpu');
  if (device === 'nnrt') {
    const descs = mindSporeLite.getAllNNRTDeviceDescriptions();
    postLog(`nnrt devices=${descs.length}`);
    if (descs.length === 0) {
      postLog('NNRT_UNAVAILABLE: 无 NPU 设备描述，API 不支持或该机型未开放');
      return summary;
    }
    postLog(`nnrt device0: type=${descs[0].deviceType()} name=${descs[0].deviceName()}`);
    ctx = buildContext('nnrt', descs[0].deviceID());
  }

  let t1 = Date.now();
  const encModel = await mindSporeLite.loadModelFromFile(encFile.path, ctx as ESObject);
  postLog(`load encoder ${Date.now() - t1}ms rss=${readVmRssKb()}kB`);
  t1 = Date.now();
  const firstModel = await mindSporeLite.loadModelFromFile(firstFile.path, ctx as ESObject);
  postLog(`load decoder_first ${Date.now() - t1}ms rss=${readVmRssKb()}kB`);
  t1 = Date.now();
  const dynModel = await mindSporeLite.loadModelFromFile(dynFile.path, ctx as ESObject);
  postLog(`load decoder_step(dynamic) ${Date.now() - t1}ms rss=${readVmRssKb()}kB`);
  t1 = Date.now();
  const s12Model = await mindSporeLite.loadModelFromFile(s12File.path, ctx as ESObject);
  postLog(`load decoder_step(S12) ${Date.now() - t1}ms loadTotal=${Date.now() - t0}ms rss=${readVmRssKb()}kB`);

  // 2. encoder：pixel_values.bin 直接喂数据（与 PC 基准逐位一致，保证比对有效性）
  const pvFd: fs.File = fs.openSync(pvFile.path, fs.OpenMode.READ_ONLY);
  const pv: ArrayBuffer = new ArrayBuffer(PIXEL_BIN_BYTES);
  fs.readSync(pvFd.fd, pv);
  fs.closeSync(pvFd);
  const encIns = encModel.getInputs();
  const encTensor = encIns[0];
  postLog(`encoder input: name=${encTensor.name} shape=[${encTensor.shape}] size=${encTensor.dataSize} bin=${pv.byteLength}`);
  encTensor.setData(pv);
  let t2 = Date.now();
  const encOuts = await encModel.predict([encTensor]);
  summary.encMs = Date.now() - t2;
  const encHidden: ArrayBuffer = encOuts[0].getData();
  postLog(`ENCODER ${summary.encMs}ms out=${encHidden.byteLength}B rss=${readVmRssKb()}kB`);

  // 3. decoder_first：step1
  const firstIns = firstModel.getInputs();
  for (const t of firstIns) {
    if (t.name.indexOf('input_ids') >= 0) {
      const ids: Int32Array = new Int32Array([START_TOKEN]);
      t.setData(ids.buffer as ArrayBuffer);
    } else {
      t.setData(encHidden);
    }
  }
  t2 = Date.now();
  const firstOuts = await firstModel.predict(firstIns);
  summary.firstMs = Date.now() - t2;
  let logits: ArrayBuffer = firstOuts[0].getData();
  let pastSelf: ArrayBuffer = firstOuts[1].getData();
  let pastCross: ArrayBuffer = firstOuts[2].getData();
  summary.step1Argmax = argmax(logits);
  postLog(`DECODER_FIRST ${summary.firstMs}ms step1_argmax=${summary.step1Argmax} (PC=${PC_STEP1_ARGMAX}) rss=${readVmRssKb()}kB`);

  // 4. 自回归：dynamic 模型 + resize 逐桶；失败则降级 S12 纯测速
  const vocabInv: Map<number, string> = loadVocab(probeDir, rawFiles['vocab.json']);
  const gen: number[] = [START_TOKEN, summary.step1Argmax];
  const stepTimes: number[] = [];
  let S: number = 1; // past_self 当前长度
  for (let step = 2; step <= MAX_NEW_TOKENS; step++) {
    const nextId: number = argmax(logits);
    if (nextId === EOS_TOKEN) {
      postLog(`step${step}: EOS reached`);
      break;
    }
    gen.push(nextId);
    const dynIns = dynModel.getInputs();
    const dims: Array<Array<number>> = [];
    for (const t of dynIns) {
      if (t.name.indexOf('past_self') >= 0) {
        dims.push([NUM_LAYERS, 2, 1, NUM_HEADS, S, HEAD_DIM]);
      } else if (t.name.indexOf('past_cross') >= 0) {
        dims.push([NUM_LAYERS, 2, 1, NUM_HEADS, ENC_SEQ, HEAD_DIM]);
      } else {
        dims.push([1, 1]);
      }
    }
    let resized: boolean = false;
    let resizeErr: string = '';
    try {
      resized = dynModel.resize(dynIns, dims);
    } catch (err) {
      resizeErr = JSON.stringify(err);
    }
    if (!resized) {
      postLog(`RESIZE_FAIL at S=${S}: ${resizeErr.length > 0 ? resizeErr : 'resize returned false'}`);
      break;
    }
    summary.resizeWorked = true;
    const ins2 = dynModel.getInputs();
    for (const t of ins2) {
      if (t.name.indexOf('past_self') >= 0) {
        t.setData(pastSelf);
      } else if (t.name.indexOf('past_cross') >= 0) {
        t.setData(pastCross);
      } else {
        const ids: Int32Array = new Int32Array([nextId]);
        t.setData(ids.buffer as ArrayBuffer);
      }
    }
    t2 = Date.now();
    try {
      const outs = await dynModel.predict(ins2);
      stepTimes.push(Date.now() - t2);
      logits = outs[0].getData();
      pastSelf = outs[1].getData();
      pastCross = outs[2].getData();
      S += 1;
    } catch (err) {
      postLog(`PREDICT_FAIL at step${step} S=${S}: ${JSON.stringify(err)}`);
      break;
    }
  }
  summary.steps = stepTimes.length;
  summary.avgStepMs = meanOf(stepTimes);
  summary.totalStepMs = stepTimes.reduce((a: number, b: number) => a + b, 0);
  postLog(`DECODE steps=${summary.steps} avg=${summary.avgStepMs}ms total=${summary.totalStepMs}ms resizeWorked=${summary.resizeWorked}`);

  // 5. 文本比对（仅 dynamic+resize 全程成功时才有意义）
  summary.text = decodeGpt2Ids(vocabInv, gen);
  summary.match = summary.resizeWorked && summary.text.trim() === PC_BASELINE_TEXT;
  postLog(`TEXT device="${summary.text}" pc="${PC_BASELINE_TEXT}" match=${summary.match ? 'YES' : 'NO'}`);
  postLog(`==== ${device.toUpperCase()} RESULT enc=${summary.encMs}ms first=${summary.firstMs}ms avgStep=${summary.avgStepMs}ms match=${summary.match ? 'YES' : 'NO'} rss=${readVmRssKb()}kB ====`);

  // 6. S12 定长模型纯测速 3 步（补零无 mask，输出不正确，仅代表算力时延）
  const s12Ins = s12Model.getInputs();
  const zeroSelf: ArrayBuffer = new ArrayBuffer(NUM_LAYERS * 2 * 1 * NUM_HEADS * 12 * HEAD_DIM * 4);
  for (let i = 0; i < 3; i++) {
    for (const t of s12Ins) {
      if (t.name.indexOf('past_self') >= 0) {
        t.setData(zeroSelf);
      } else if (t.name.indexOf('past_cross') >= 0) {
        t.setData(pastCross);
      } else {
        const ids: Int32Array = new Int32Array([START_TOKEN]);
        t.setData(ids.buffer as ArrayBuffer);
      }
    }
    t2 = Date.now();
    try {
      await s12Model.predict(s12Ins);
      summary.s12Ok++;
      postLog(`S12 step${i + 1} ${Date.now() - t2}ms`);
    } catch (err) {
      postLog(`S12 predict fail: ${JSON.stringify(err)}`);
      break;
    }
  }
  return summary;
}

workerPort.onmessage = (e: MessageEvents) => {
  const req: RunRequest = e.data as RunRequest;
  if (req.cmd !== 'run') {
    return;
  }
  const device: string = req.device;
  postLog(`worker pipeline start device=${device}`);
  runDevicePipeline(device, req.probeDir, req.rawFiles).then((summary: PipelineSummary) => {
    const m: SummaryMessage = { type: 'summary', device: device, summary: summary };
    workerPort.postMessage(m);
  }).catch((err: Object) => {
    const f: FailMessage = { type: 'fail', message: JSON.stringify(err) };
    workerPort.postMessage(f);
    hilog.error(DOMAIN, TAG, 'worker pipeline fail %{public}s', JSON.stringify(err));
  });
};
