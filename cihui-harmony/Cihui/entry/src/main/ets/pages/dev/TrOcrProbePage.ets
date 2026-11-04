import { hilog } from '@kit.PerformanceAnalysisKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { worker, MessageEvents, ErrorEvent } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';
import { resourceManager } from '@kit.LocalizationKit';

/**
 * TrOCR 端侧化真机探针页（dev 专用，不进任何业务导航）。
 *
 * v2：全部重活（拷贝/加载/推理/解码）已搬入 Worker 线程
 * （entry/src/main/ets/workers/TrOcrProbeWorker.ets），修复主线程同步 fs
 * 读写 + 原生模型加载导致 appfreeze 看门狗杀进程的问题。
 * 本页只做：收集 rawfile fd、发启动消息、收进度日志、渲染、卸载打点。
 *
 * hilog 过滤：hdc shell hilog | grep TrOcrProbe
 */

// ---------- Worker 消息协议（与 TrOcrProbeWorker.ets 严格一致） ----------
interface RawFdInfo {
  fd: number;
  offset: number;
  length: number;
}

interface WorkerMessage {
  type: string;
  line: string;
  device: string;
  summary: WorkerPipelineSummary;
  message: string;
}

interface WorkerPipelineSummary {
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

// ---------- 常量 ----------
const DOMAIN: number = 0x0000;
const TAG: string = 'TrOcrProbe';
const RAW_DIR: string = 'ocr_probe';
const WORKER_SCRIPT: string = 'entry/ets/workers/TrOcrProbeWorker.ets';
const PROBE_FILES: string[] = [
  'encoder_int8w.ms',
  'decoder_first_int8w.ms',
  'decoder_step_int8w.ms',
  'decoder_step_S12_int8w.ms',
  'pixel_values.bin',
  'vocab.json',
];

/** 读 /proc/self/status 的 VmRSS（kB），失败返回 -1（进程级，主/Worker 线程同值） */
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

@Entry
@ComponentV2
struct TrOcrProbePage {
  @Local logLines: string[] = [];
  @Local busy: boolean = false;
  private currentWorker: worker.ThreadWorker | null = null;

  aboutToAppear(): void {
    this.log(`probe start (worker mode), rss=${readVmRssKb()}kB`);
    this.startRun('cpu');
  }

  aboutToDisappear(): void {
    this.stopWorker();
  }

  private log(msg: string): void {
    const line = `${new Date().toISOString().slice(11, 23)} ${msg}`;
    this.logLines.push(line);
    hilog.info(DOMAIN, TAG, '%{public}s', line);
    if (this.logLines.length > 400) {
      this.logLines.splice(0, this.logLines.length - 400);
    }
  }

  private stopWorker(): void {
    if (this.currentWorker !== null) {
      try {
        this.currentWorker.terminate();
      } catch (err) {
        hilog.warn(DOMAIN, TAG, 'terminate worker failed: %{public}s', JSON.stringify(err));
      }
      this.currentWorker = null;
    }
  }

  /** 主线程预取 rawfile 描述符（ResourceManager 不可跨线程），随消息发给 Worker */
  private collectRawFds(rm: resourceManager.ResourceManager): Record<string, RawFdInfo> {
    const fds: Record<string, RawFdInfo> = {};
    for (const name of PROBE_FILES) {
      const d: resourceManager.RawFileDescriptor = rm.getRawFdSync(`${RAW_DIR}/${name}`);
      const info: RawFdInfo = { fd: d.fd, offset: d.offset, length: d.length };
      fds[name] = info;
    }
    return fds;
  }

  private startRun(device: string): void {
    if (this.busy) {
      this.log('busy: 上一轮未结束，忽略本次点击');
      return;
    }
    this.busy = true;
    try {
      const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      const probeDir: string = `${ctx.filesDir}/ocr_probe`;
      try {
        fs.mkdirSync(probeDir, true);
      } catch (_e) {
        // 目录已存在
      }
      const fds: Record<string, RawFdInfo> = this.collectRawFds(ctx.resourceManager);
      this.log(`==== ${device.toUpperCase()} run begin (worker) rss=${readVmRssKb()}kB fds=${PROBE_FILES.length} ====`);

      const w: worker.ThreadWorker = new worker.ThreadWorker(WORKER_SCRIPT);
      this.currentWorker = w;
      w.onmessage = (ev: MessageEvents) => {
        const msg: WorkerMessage = ev.data as WorkerMessage;
        if (msg.type === 'log') {
          this.logLines.push(msg.line);
          if (this.logLines.length > 400) {
            this.logLines.splice(0, this.logLines.length - 400);
          }
        } else if (msg.type === 'summary') {
          const s: WorkerPipelineSummary = msg.summary;
          this.log(`SUMMARY ${msg.device.toUpperCase()} enc=${s.encMs}ms first=${s.firstMs}ms ` +
            `step1=${s.step1Argmax} steps=${s.steps} avgStep=${s.avgStepMs}ms ` +
            `resize=${s.resizeWorked ? 'OK' : 'FAIL'} match=${s.match ? 'YES' : 'NO'} s12ok=${s.s12Ok}`);
          this.finishRun(msg.device);
        } else if (msg.type === 'fail') {
          this.log(`WORKER_FAIL: ${msg.message}`);
          this.finishRun(msg.device);
        }
      };
      w.onerror = (ev: ErrorEvent) => {
        this.log(`WORKER_ERROR: ${ev.message}`);
        this.finishRun(device);
      };

      const request: Record<string, Object> = {
        'cmd': 'run',
        'device': device as Object,
        'probeDir': probeDir as Object,
        'rawFiles': fds as Object
      };
      w.postMessage(request);
      if (device === 'cpu') {
        this.log('CPU 探针已提交 Worker；跑完可点 NNRt 对比。');
      }
    } catch (err) {
      this.log(`SUBMIT_FAIL: ${JSON.stringify(err)}`);
      this.busy = false;
    }
  }

  private finishRun(device: string): void {
    // 注意：terminate 强杀 Worker 可能跳过 finalizer，native 模型内存是否回落
    // 以 RSS 实测为准，如实记录（这正是本探针要观测的内容之一）。
    const rssBefore: number = readVmRssKb();
    this.stopWorker();
    // 主线程统一释放 rawfile fd 引用
    try {
      const rm: resourceManager.ResourceManager =
        (getContext(this) as common.UIAbilityContext).resourceManager;
      for (const name of PROBE_FILES) {
        try {
          rm.closeRawFdSync(`${RAW_DIR}/${name}`);
        } catch (_e) {
          // 已关闭或无效，忽略
        }
      }
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'closeRawFd failed: %{public}s', JSON.stringify(err));
    }
    setTimeout(() => {
      const rssAfter: number = readVmRssKb();
      this.log(`UNLOAD ${device} rss before-terminate=${rssBefore}kB, after 3s=${rssAfter}kB`);
      if (device === 'cpu') {
        this.log('CPU run done. 点 NNRt 按钮跑 NPU 对比。');
      }
      this.busy = false;
    }, 3000);
  }

  build() {
    Column() {
      Text('TrOCR 真机探针（Worker 版）').fontSize(20).fontWeight(FontWeight.Bold).margin({ top: 12 })
      Row({ space: 10 }) {
        Button('CPU 探针').onClick(() => this.startRun('cpu'))
        Button('NNRt 探针').onClick(() => this.startRun('nnrt'))
        Button('清日志').onClick(() => {
          this.logLines = [];
        })
      }.margin(8)

      Scroll() {
        Column() {
          ForEach(this.logLines, (line: string, idx: number) => {
            Text(line).fontSize(12).fontFamily('monospace').margin({ bottom: 2 })
          }, (line: string, idx: number) => `${idx}-${line}`)
        }.alignItems(HorizontalAlign.Start).width('100%').padding(8)
      }
      .layoutWeight(1)
      .width('100%')
      .backgroundColor('#101418')
      .scrollBar(BarState.Auto)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F1F3F5')
  }
}
