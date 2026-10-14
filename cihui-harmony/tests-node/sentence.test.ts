/**
 * F19 今日例句纯函数单测：今日词收集、分批、模型 JSON 解析容错、高亮分段、Prompt。
 * 运行：node --import ./register.mjs --test sentence.test.ts
 */
import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import {
  SENTENCE_BATCH_SIZE,
  buildPrompt,
  chunkItems,
  collectTodayWordIds,
  extractJsonArray,
  highlightSegments,
  joinWordsByIds,
  parseSentencePayload,
} from '../Cihui/entry/src/main/ets/model/SentenceCore';
import type { ReviewSchedule, StudyRecord, Word } from '../Cihui/entry/src/main/ets/model/Types';

function makeWord(id: string, en: string, meanings: string[] = ['释义']): Word {
  return {
    id, bookId: 'b1', english: en, phonetic: '', meanings, source: 'DIY_PHOTO',
    missingMeaning: false, diySupplement: '', createdAt: 0,
  };
}

function record(wordId: string, lastStudyDay: string): StudyRecord {
  return {
    wordId, firstStudyAt: 0, firstPassedAt: 0, s1DoneAt: 0, s2DoneAt: 0, s3DoneAt: 0, lastStudyDay,
  };
}

function schedule(wordId: string, lastVerdictAt: number): ReviewSchedule {
  return {
    wordId, stage: 'R1', firstLearnDay: '2026-09-10', dueDay: '2026-09-15',
    status: 'LEARNING', forceNextDay: false, roundRequeue: false, wrongReason: '', lastVerdictAt,
  };
}

describe('F19 collectTodayWordIds 今日词源', () => {
  test('今日学过的新词 + 今日判定的复习词，去重保序', () => {
    // 2026-09-15 12:00 本地
    const tsToday: number = new Date(2026, 8, 15, 12, 0, 0).getTime();
    const tsYesterday: number = new Date(2026, 8, 14, 9, 0, 0).getTime();
    const records: StudyRecord[] = [
      record('w1', '2026-09-15'),
      record('w2', '2026-09-14'), // 昨天学的不算
      record('w3', '2026-09-15'),
    ];
    const schedules: ReviewSchedule[] = [
      schedule('w3', tsToday),    // 与新词重复，只保留一次
      schedule('w4', tsToday),    // 今日复习
      schedule('w5', tsYesterday), // 昨天复习不算
      schedule('w6', 0),          // 从未判定
    ];
    const ids = collectTodayWordIds(records, schedules, '2026-09-15');
    assert.deepEqual(ids, ['w1', 'w3', 'w4']);
  });

  test('空记录空调度返回空数组', () => {
    assert.deepEqual(collectTodayWordIds([], [], '2026-09-15'), []);
  });
});

describe('F19 joinWordsByIds 按序 join，缺失 id 跳过', () => {
  test('顺序以 ids 为准，找不到的 id 不占位', () => {
    const words: Word[] = [makeWord('a', 'apple'), makeWord('b', 'banana')];
    const out = joinWordsByIds(words, ['b', 'x', 'a']);
    assert.deepEqual(out.map((w: Word): string => w.english), ['banana', 'apple']);
  });
});

describe('F19 chunkItems 分批', () => {
  test('200 词按每批 20 分 10 批，不丢不重', () => {
    const items: number[] = [];
    for (let i = 0; i < 200; i++) {
      items.push(i);
    }
    const batches = chunkItems(items, SENTENCE_BATCH_SIZE);
    assert.equal(batches.length, 10);
    assert.equal(batches[0].length, 20);
    assert.equal(batches[9].length, 20);
    assert.equal(batches[9][19], 199);
  });

  test('不足一批只有一批；空数组为空批次', () => {
    assert.equal(chunkItems([1, 2], 20).length, 1);
    assert.deepEqual(chunkItems([], 20), []);
  });
});

describe('F19 extractJsonArray 容错提取', () => {
  test('剥离 ```json 围栏', () => {
    const raw = '好的，结果如下：\n```json\n[{"sentence":"a"}]\n```';
    assert.equal(extractJsonArray(raw), '[{"sentence":"a"}]');
  });

  test('前后有解释文字时截取首个 [ 到末个 ]', () => {
    const raw = 'prefix [1,2] suffix ]';
    assert.equal(extractJsonArray(raw), '[1,2]');
  });
});

describe('F19 parseSentencePayload 解析与校验', () => {
  const words: Word[] = [makeWord('w1', 'Apple'), makeWord('w2', 'BANANA')];

  test('正常数组：trim、words 小写化并只保留列表词、去重', () => {
    const raw = JSON.stringify([
      { sentence: ' I eat an apple. ', translation: ' 我吃苹果。 ', words: ['apple', 'Apple', 'ghost'] },
    ]);
    const out = parseSentencePayload(raw, words);
    assert.equal(out.length, 1);
    assert.equal(out[0].sentence, 'I eat an apple.');
    assert.equal(out[0].translation, '我吃苹果。');
    assert.deepEqual(out[0].words, ['apple']);
  });

  test('缺翻译的句子被丢弃，全部非法时抛错', () => {
    const raw = JSON.stringify([{ sentence: 'no translation', words: [] }]);
    assert.throws(() => parseSentencePayload(raw, words), /没有可用例句/);
  });

  test('非 JSON 抛错；非数组抛错', () => {
    assert.throws(() => parseSentencePayload('not json', words), /合法 JSON/);
    assert.throws(() => parseSentencePayload('{"a":1}', words), /JSON 数组/);
  });

  test('words 不是数组时按空数组处理，句子仍保留', () => {
    const raw = JSON.stringify([{ sentence: 'Ok then.', translation: '那好吧。', words: 'x' }]);
    const out = parseSentencePayload(raw, words);
    assert.equal(out.length, 1);
    assert.deepEqual(out[0].words, []);
  });
});

describe('F19 highlightSegments 高亮分段', () => {
  test('命中词单独成段且 hit=true，相邻同类段合并', () => {
    const segs = highlightSegments('An apple a day.', ['apple']);
    const joined: string = segs.map((s): string => s.text).join('');
    assert.equal(joined, 'An apple a day.');
    const hitSegs = segs.filter((s): boolean => s.hit);
    assert.equal(hitSegs.length, 1);
    assert.equal(hitSegs[0].text, 'apple');
  });

  test('大小写不敏感；无命中时没有 hit 段', () => {
    const segs = highlightSegments('APPLE again', ['apple']);
    assert.equal(segs.filter((s): boolean => s.hit).length, 1);
    assert.equal(highlightSegments('nothing here', ['apple']).some((s): boolean => s.hit), false);
  });
});

describe('F19 buildPrompt', () => {
  test('包含全部给定单词与 JSON 输出约束', () => {
    const p = buildPrompt([makeWord('w1', 'abandon', ['放弃'])], 5);
    assert.ok(p.includes('abandon'));
    assert.ok(p.includes('放弃'));
    assert.ok(p.includes('JSON'));
    assert.ok(p.includes('5'));
  });
});
