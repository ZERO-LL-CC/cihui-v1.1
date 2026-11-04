/**
 * OCR 词书约束纠错测试（PRD-ocr-correction-v1 F-2/F-3/F-5，Node 内置 test runner）。
 * 运行：cd F:/PORJECT/cihui-harmony/tests-node && node --import ./register.mjs --test ocr-corrector.test.ts
 *
 * 数据：fixtures/hms-out_pageAB.txt（真实畅享 90 HMS textRecognition 输出，两页 89 词 GT）
 * 评测口径：每行首个 alpha token（过滤 n/v/a/ad/vi/vt/adj/adv 及长度<2），
 * 经 corrector 后小写落入 GT 计命中，要求 ≥84/89。
 */
import { test, describe, before } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

import { ocrCorrector } from '../Cihui/entry/src/main/ets/service/OcrCorrector.ts';
import { parseOcrLines } from '../Cihui/entry/src/main/ets/service/OcrParser.ts';

const HERE: string = dirname(fileURLToPath(import.meta.url));
const RAW_WORDBANK: string =
  join(HERE, '..', 'Cihui', 'entry', 'src', 'main', 'resources', 'rawfile', 'ocr_correction', 'wordbank.json');
const FIXTURE: string = join(HERE, 'fixtures', 'hms-out_pageAB.txt');
const GT_FILE: string = join(HERE, 'fixtures', 'gt.json');

const JUNK: Set<string> = new Set(['n', 'v', 'a', 'ad', 'vi', 'vt', 'adj', 'adv']);
const CORRECT_FN = (english: string) => ocrCorrector.correct(english);

before(() => {
  const text: string = readFileSync(RAW_WORDBANK, 'utf-8');
  assert.ok(ocrCorrector.loadFromText(text), 'wordbank.json 加载失败');
  assert.ok(ocrCorrector.isReady);
});

describe('F-2 单点纠错用例', () => {
  test('caracity → capacity（混淆对 o-a + r-n 加权命中）', () => {
    const r = ocrCorrector.correct('caracity');
    assert.equal(r.english, 'capacity');
    assert.equal(r.suspect, false);
  });

  test('cue 本身是合法词 → 原样返回且不标记', () => {
    const r = ocrCorrector.correct('cue');
    assert.equal(r.english, 'cue');
    assert.equal(r.suspect, false);
  });

  test('dim 本身是合法词 → 原样返回且不标记', () => {
    const r = ocrCorrector.correct('dim');
    assert.equal(r.english, 'dim');
    assert.equal(r.suspect, false);
  });

  test('inspsrnatton 损毁过重 → suspect=true 且原文保留', () => {
    const r = ocrCorrector.correct('inspsrnatton');
    assert.equal(r.english, 'inspsrnatton');
    assert.equal(r.suspect, true);
  });

  test('witter → 形近纠正（已知歧义，同分按词频取词，允许 wither/writer/winter），必不 suspect', () => {
    const r = ocrCorrector.correct('witter');
    assert.equal(r.suspect, false);
    assert.ok(['wither', 'writer', 'winter'].includes(r.english), `got ${r.english}`);
  });

  test('大小写风格保持：Caracity → Capacity（首字母大写）', () => {
    const r = ocrCorrector.correct('Caracity');
    assert.equal(r.english, 'Capacity');
    assert.equal(r.suspect, false);
  });

  test('直命中保留原大小写风格：Apple → Apple', () => {
    const r = ocrCorrector.correct('Apple');
    assert.equal(r.english, 'Apple');
    assert.equal(r.suspect, false);
  });

  test('词组（含空格）不做纠错', () => {
    const r = ocrCorrector.correct('ice cream');
    assert.equal(r.english, 'ice cream');
    assert.equal(r.suspect, false);
  });

  test('过短 token（长度<2）不纠不标', () => {
    const r = ocrCorrector.correct('n');
    assert.equal(r.english, 'n');
    assert.equal(r.suspect, false);
  });

  test('性能：fixture 全量 token 纠错耗时打点（真机预算 500ms/50 词，Node 并发环境放宽）', () => {
    // 用 fixture 行的首 token 跑 50 次量级，验证总耗时。
    // 注意：node --test 全量并发跑时 V8 冷启动会拖慢首轮，先预热再计时；
    // 真机 500ms 验收以 OcrReviewPage 的 [ocr-correct] hilog 打点为准。
    const fixture: string = readFileSync(FIXTURE, 'utf-8');
    const tokens: string[] = [];
    for (const line of fixture.split('\n')) {
      if (!line.startsWith('PAGE_')) {
        continue;
      }
      const text: string = line.split(' ').slice(1).join(' ').toLowerCase();
      const all: string[] = text.match(/[a-z]+/g) ?? [];
      const tok: string | undefined = all.find((t: string): boolean => !JUNK.has(t) && t.length >= 2);
      if (tok) {
        tokens.push(tok);
      }
    }
    assert.ok(tokens.length >= 40, `token 数异常: ${tokens.length}`);
    // 预热：JIT/缓存
    ocrCorrector.correct('caracity');
    ocrCorrector.correct('caracity');
    const t0 = Date.now();
    for (const t of tokens) {
      ocrCorrector.correct(t);
    }
    const ms = Date.now() - t0;
    console.info(`perf: ${tokens.length} tokens corrected in ${ms}ms (budget 500ms per 50 words on device)`);
    assert.ok(ms <= 1000, `fixture ${tokens.length} 词纠错耗时 ${ms}ms 超 Node 环境预算 1000ms`);
  });
});

describe('F-3 parseOcrLines 集成', () => {
  test('head 提取后应用纠错，rest 切分不受纠正词长度影响', () => {
    const r = parseOcrLines(['caracity  n. 能力；容量'], CORRECT_FN);
    assert.equal(r.length, 1);
    assert.equal(r[0].english, 'capacity');
    assert.equal(r[0].suspect, false);
    assert.ok(r[0].meaning.includes('能力'));
    assert.ok(r[0].meaning.includes('容量'));
  });

  test('suspect=true 透传到 OcrDraft', () => {
    const r = parseOcrLines(['inspsrnatton'], CORRECT_FN);
    assert.equal(r.length, 1);
    assert.equal(r[0].english, 'inspsrnatton');
    assert.equal(r[0].suspect, true);
  });

  test('无 correct 参数（降级路径）→ suspect 恒 false', () => {
    const r = parseOcrLines(['inspsrnatton', 'caracity  n. 能力']);
    assert.equal(r.length, 2);
    assert.equal(r[0].suspect, false);
    assert.equal(r[0].english, 'inspsrnatton');
    assert.equal(r[1].suspect, false);
    assert.equal(r[1].english, 'caracity');
  });

  test('去重合并时 suspect 向上传播', () => {
    const r = parseOcrLines(['caracity  n. 能力', 'inspsrnatton', 'caracity  v. 估算'], CORRECT_FN);
    // 两行 caracity 纠成同一词合并为一条；inspsrnatton suspect 独立成行
    const car = r.find((d) => d.english === 'capacity');
    assert.ok(car, 'caracity 应纠为 capacity');
    assert.equal(car!.suspect, false);
    const bad = r.find((d) => d.suspect);
    assert.ok(bad, 'inspsrnatton 行应 suspect');
  });

  test('纠正后大小写风格：head 首字母大写时纠正词转首字母大写', () => {
    const r = parseOcrLines(['Caracity  n. 能力'], CORRECT_FN);
    assert.equal(r[0].english, 'Capacity');
  });
});

describe('F-3/F-5 fixture 评测（真实 HMS 输出，两页 89 词）', () => {
  const gt: Record<string, string[]> = JSON.parse(readFileSync(GT_FILE, 'utf-8'));
  const fixture: string = readFileSync(FIXTURE, 'utf-8');

  // 与 PC 参考实现 eval_hms_v2.py 相同的行级口径
  function pageLines(): Map<string, string[]> {
    const per: Map<string, string[]> = new Map();
    for (const line of fixture.split('\n')) {
      if (!line.startsWith('PAGE_')) {
        continue;
      }
      const sp: number = line.indexOf(' ');
      const page: string = line.substring(0, sp);
      const text: string = line.substring(sp + 1);
      if (!per.has(page)) {
        per.set(page, []);
      }
      per.get(page)!.push(text);
    }
    return per;
  }

  function evalPage(page: string): { hits: Set<string>; detail: string[] } {
    const lines: string[] = pageLines().get(page) ?? [];
    const gtSet: Set<string> = new Set(gt[page].map((w: string): string => w.toLowerCase()));
    const hits: Set<string> = new Set();
    const detail: string[] = [];
    for (const text of lines) {
      const all: string[] = text.toLowerCase().match(/[a-z]+/g) ?? [];
      const tok: string | undefined = all.find((t: string): boolean => !JUNK.has(t) && t.length >= 2);
      if (tok === undefined) {
        continue;
      }
      const r = ocrCorrector.correct(tok);
      if (gtSet.has(r.english.toLowerCase())) {
        hits.add(r.english.toLowerCase());
        detail.push(`${tok} -> ${r.english}`);
      } else {
        detail.push(`MISS ${tok} -> ${r.english}`);
      }
    }
    return { hits, detail };
  }

  test('PAGE_A 命中数达标（39 词）', () => {
    const { hits, detail } = evalPage('PAGE_A');
    console.info(`PAGE_A ${hits.size}/${gt['PAGE_A'].length}: misses=[${gt['PAGE_A'].filter((w: string): boolean => !hits.has(w)).join(',')}]`);
    console.info(`  detail: ${detail.filter((d: string): boolean => d.startsWith('MISS')).join(' | ')}`);
    assert.ok(hits.size >= 33, `PAGE_A 命中 ${hits.size}/${gt['PAGE_A'].length}`);
  });

  test('PAGE_B 命中数达标（50 词）', () => {
    const { hits, detail } = evalPage('PAGE_B');
    console.info(`PAGE_B ${hits.size}/${gt['PAGE_B'].length}: misses=[${gt['PAGE_B'].filter((w: string): boolean => !hits.has(w)).join(',')}]`);
    console.info(`  detail: ${detail.filter((d: string): boolean => d.startsWith('MISS')).join(' | ')}`);
    assert.ok(hits.size >= 47, `PAGE_B 命中 ${hits.size}/${gt['PAGE_B'].length}`);
  });

  test('综合命中 ≥84/89（PRD F-5 验收线）', () => {
    let tot = 0;
    let hit = 0;
    for (const page of ['PAGE_A', 'PAGE_B']) {
      const { hits } = evalPage(page);
      tot += gt[page].length;
      hit += hits.size;
    }
    console.info(`TOTAL ${hit}/${tot}`);
    assert.ok(hit >= 84, `综合命中 ${hit}/${tot}，低于验收线 84`);
  });

  test('parseOcrLines 全量跑 fixture 不抛异常且 suspect 字段存在', () => {
    const per: Map<string, string[]> = pageLines();
    const all: string[] = [];
    for (const lines of per.values()) {
      all.push(...lines);
    }
    const drafts = parseOcrLines(all, CORRECT_FN);
    assert.ok(drafts.length > 0);
    for (const d of drafts) {
      assert.equal(typeof d.suspect, 'boolean');
    }
  });
});
