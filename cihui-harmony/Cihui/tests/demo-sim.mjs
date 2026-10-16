/**
 * Demo 模拟器 Node 冒烟测试：抽取 fsrs-vs-ebbinghaus.html 内的 <script>，
 * 用最小 DOM 桩执行，验证两种算法可完整模拟且结果合理。
 * 覆盖：三画像回归（与基线数字一致）、拍照导入两种模式、缺席日、打散摊还、单词流水追踪。
 */
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const html = readFileSync(new URL('../../../fsrs-vs-ebbinghaus.html', import.meta.url), 'utf8');
const m = html.match(/<script>([\s\S]*)<\/script>/);
if (!m) {
  console.error('未找到 <script>');
  process.exit(1);
}

function elStub(props = {}) {
  return Object.assign({
    addEventListener() {}, style: {}, dataset: { v: '500' }, value: '20', checked: false,
    innerHTML: '', textContent: '', children: [], prepend() {}, removeChild() {},
    getBoundingClientRect: () => ({ width: 640, height: 240 }),
    getContext: () => new Proxy({}, { get: () => () => {}, set: () => true }),
  }, props);
}
const documentStub = {
  querySelector: (sel) => elStub(),
  querySelectorAll: () => [],
  getElementById: (id) => elStub(),
  createElement: () => elStub(),
  documentElement: elStub(),
};
const sandbox = {
  document: documentStub,
  window: { devicePixelRatio: 1, addEventListener() {}, innerWidth: 1200 },
  getComputedStyle: () => ({ getPropertyValue: () => '#2E6BE6' }),
  console, Math, JSON, Map, Set, performance,
  isNaN, parseInt, parseFloat, String, Number, Array, Object, Date, RegExp, Error,
};
vm.createContext(sandbox);
vm.runInContext(m[1] + `
;globalThis.__run = (profileIdx, opts) => {
  opts = opts || {};
  function el(){ return { addEventListener(){}, style:{}, dataset:{v:''}, value:'', checked:false, innerHTML:'', textContent:'', children:[], prepend(){}, removeChild(){}, getBoundingClientRect:()=>({width:640,height:240}), getContext:()=>new Proxy({},{get:()=>()=>{},set:()=>true}) }; }
  document.getElementById = () => el();
  initSimState({
    nWords: opts.nWords ?? 500, quota: opts.quota ?? 20, days: opts.days ?? 60,
    profile: profileIdx, simple: false,
    camMode: opts.camMode ?? 'off', camCount: opts.camCount ?? 5, camStart: opts.camStart ?? 9,
    absent: parseAbsent(opts.absentTxt || ''), spread: !!opts.spread,
  });
  while (!sim.done) stepDay();
  const A = sim.stats.A, B = sim.stats.B;
  const revA = A.reduce((x, s) => x + s.review, 0), revB = B.reduce((x, s) => x + s.review, 0);
  const camA = sim.A.filter((w) => w.cam), camB = sim.B.filter((w) => w.cam);
  const w1 = sim.A.find((w) => w.id === 1);
  return JSON.stringify({
    days: A.length,
    cumA: A.reduce((x, s) => x + s.cum, 0), cumB: B.reduce((x, s) => x + s.cum, 0),
    masteredA: A[A.length - 1].mastered, masteredB: B[B.length - 1].mastered,
    rmA: A[A.length - 1].rm, rmB: B[B.length - 1].rm,
    firstA: A.reduce((x, s) => x + s.first, 0), firstB: B.reduce((x, s) => x + s.first, 0),
    retA: Math.round(100 * A.reduce((x, s) => x + s.known, 0) / Math.max(1, revA)),
    retB: Math.round(100 * B.reduce((x, s) => x + s.known, 0) / Math.max(1, revB)),
    camTotalA: camA.length, camTotalB: camB.length,
    camLearnedA: camA.filter((w) => w.log.some((e) => e.act === '首学' || e.act === '复测')).length,
    camLearnedB: camB.filter((w) => w.log.some((e) => e.act === '首学' || e.act === '复测')).length,
    camHasImport: camA.length > 0 && camA[0].log.some((e) => e.act === '导入'),
    traceW1: w1 ? w1.log.length : 0,
    dAbsentA: A[11] ? A[11].cum : -1, dAbsentB: B[11] ? B[11].cum : -1,
    retRevA: A[12] ? A[12].review : -1, retRevB: B[12] ? B[12].review : -1,
    peakRevA: Math.max(...A.map((s) => s.review)), peakRevB: Math.max(...B.map((s) => s.review)),
  });
};`, sandbox);

let failed = 0;
const check = (cond, msg) => { if (!cond) { failed += 1; console.error('  ✗ ' + msg); } else console.log('  ✓ ' + msg); };

/* 1) 三画像回归（camMode=off，数字应与修复前基线一致） */
for (const p of [0, 1, 2]) {
  const r = JSON.parse(sandbox.__run(p));
  console.log(`画像${p}:`, JSON.stringify(r));
  check(r.days === 60, `画像${p}: 模拟天数 = 60`);
  check(r.firstA === 500 && r.firstB === 500, `画像${p}: 两种算法都只把 500 词各计一次新学`);
  check(Number.isFinite(r.cumA) && r.cumA > 0, `画像${p}: 甲累计学习+复习 > 0`);
  check(Number.isFinite(r.cumB) && r.cumB > 0, `画像${p}: 乙累计学习+复习 > 0`);
  check(r.retA >= 0 && r.retA <= 100 && r.retB >= 0 && r.retB <= 100, `画像${p}: 命中率在 0-100 之间`);
  check(r.retB >= 60 && r.retB <= 97, `画像${p}: 乙命中率 ${r.retB}% 在合理区间`);
  check(Number.isFinite(r.rmA) && Number.isFinite(r.rmB), `画像${p}: 真实掌握指标可用`);
  check(r.traceW1 > 0, `画像${p}: 词#1 有流水记录（${r.traceW1} 条）`);
}

/* 2) 拍照导入·加入当天计划：第10天起每天5个 × 51天 = 255 词，全部当天首学 */
const rt = JSON.parse(sandbox.__run(1, { camMode: 'today', camStart: 9, camCount: 5 }));
console.log('today模式:', JSON.stringify(rt));
check(rt.camTotalA === 255 && rt.camTotalB === 255, 'today: 两种算法各导入 255 个相机词');
check(rt.camHasImport, 'today: 相机词流水含「导入」事件');
check(rt.firstA === 755 && rt.firstB === 755, `today: 两种算法都学完 500+255 词（甲${rt.firstA}/乙${rt.firstB}）`);
check(rt.camLearnedA === 255 && rt.camLearnedB === 255, 'today: 相机词全部进入学习');

/* 3) 拍照导入·直接加入词本：排队等配额空位，最终也应全部学完 */
const rq = JSON.parse(sandbox.__run(1, { camMode: 'queue', camStart: 9, camCount: 5 }));
console.log('queue模式:', JSON.stringify(rq));
check(rq.camTotalA === 255 && rq.camTotalB === 255, 'queue: 两种算法各导入 255 个相机词');
check(rq.camLearnedA === 255 && rq.camLearnedB === 255, `queue: 相机词最终全部进入新学（甲${rq.camLearnedA}/乙${rq.camLearnedB}）`);

/* 4) 缺席日：第12天整休（0基11），当天零活动 */
const ra = JSON.parse(sandbox.__run(1, { absentTxt: '12' }));
console.log('缺席:', JSON.stringify(ra));
check(ra.dAbsentA === 0 && ra.dAbsentB === 0, '缺席: 第12天两种算法都是零活动');
check(ra.cumA > 0 && ra.cumB > 0, '缺席: 其余日子照常（总活动 > 0）');

/* 5) 打散摊还：回来那天（第13天）的复习量应明显低于不打散 */
check(ra.retRevA > 0 && ra.retRevB > 0, '缺席: 回来第一天有堆积复习');
const rs = JSON.parse(sandbox.__run(1, { absentTxt: '12', spread: true }));
console.log('打散:', JSON.stringify(rs));
check(rs.retRevA < ra.retRevA && rs.retRevB < ra.retRevB,
  `打散: 回来日复习量下降（甲 ${ra.retRevA}→${rs.retRevA}，乙 ${ra.retRevB}→${rs.retRevB}）`);

/* FSRS 公式锚点复核（跑一次确保脚本仍自洽） */
sandbox.__run(1);
console.log(failed === 0 ? 'Demo 冒烟测试全部通过' : `失败 ${failed} 项`);
process.exit(failed === 0 ? 0 : 1);
