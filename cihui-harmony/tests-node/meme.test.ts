/**
 * F17 梗句导入与背诵 · 纯逻辑单测（Node 内置 test runner）。
 * 运行：node --import ./register.mjs --test meme.test.ts
 */
import { test, describe } from 'node:test';
import assert from 'node:assert/strict';

import { emptyData } from '../Cihui/entry/src/main/ets/model/RepoCore.ts';
import type { AppData } from '../Cihui/entry/src/main/ets/model/RepoCore.ts';
import { newImportedSchedule, newStudyRecord } from '../Cihui/entry/src/main/ets/model/SchedulerCore.ts';
import type { ReviewSchedule, Word, WordBook } from '../Cihui/entry/src/main/ets/model/Types.ts';
import {
  advanceSession,
  badgeOf,
  badgeLabel,
  buildCandidates,
  createMemeImport,
  createRestudySession,
  findResumableSession,
  sessionPendingCount,
  shuffleList,
  summarizeCandidates,
  tokenizeEnglish,
} from '../Cihui/entry/src/main/ets/model/MemeCore.ts';
import type { MemeCandidate } from '../Cihui/entry/src/main/ets/model/MemeCore.ts';

const NOW = new Date(2026, 8, 12, 10, 0, 0).getTime();

function word(id: string, english: string, bookId: string): Word {
  return {
    id,
    bookId,
    english,
    phonetic: '',
    meanings: ['x'],
    source: 'DIY_PHOTO',
    missingMeaning: false,
    diySupplement: false,
    createdAt: NOW - 1000,
  };
}

function schedule(wordId: string, stage: string): ReviewSchedule {
  const s = newImportedSchedule(wordId);
  s.stage = stage as ReviewSchedule['stage'];
  s.status = stage === 'MASTERED' ? 'MASTERED' : 'LEARNING';
  return s;
}

describe('F17 拆词 tokenizeEnglish', () => {
  test('小写化、按非字母切分、丢短词/数字/停用词、按序去重', () => {
    // you/the/here 是停用词；词内撇号保留 can't；123 丢；quick 去重
    const toks = tokenizeEnglish("You you can't CAN'T eat 123 here-here, the quick quick.");
    assert.deepEqual(toks, ["can't", 'eat', 'quick']);
  });

  test('纯虚词/空串返回空数组', () => {
    assert.deepEqual(tokenizeEnglish('the is a an of to'), []);
    assert.deepEqual(tokenizeEnglish(''), []);
    assert.deepEqual(tokenizeEnglish('123 456'), []);
  });
});

describe('F17 候选三态 buildCandidates / summarizeCandidates', () => {
  test('新词蓝、学习中黄、已掌握绿（默认勾选态正确）', () => {
    const wLearn = word('w1', 'apple', 'b1');
    const wMaster = word('w2', 'banana', 'b1');
    const cands = buildCandidates(
      ['apple', 'banana', 'cherry'],
      [wLearn, wMaster],
      [schedule('w1', 'R1'), schedule('w2', 'MASTERED')],
    );
    assert.equal(cands.length, 3);
    assert.equal(cands[0].kind, 'LEARNING');
    assert.equal(cands[0].selected, true);
    assert.equal(cands[0].toggleable, true);
    assert.equal(cands[1].kind, 'MASTERED');
    assert.equal(cands[1].selected, false);
    assert.equal(cands[1].toggleable, false);
    assert.equal(cands[2].kind, 'NEW');
    assert.equal(cands[2].existingWordId, '');
    assert.equal(cands[2].selected, true);

    const s = summarizeCandidates(cands);
    assert.deepEqual(s, { total: 3, mastered: 1, learning: 1, fresh: 1, willStudy: 2 });
  });

  test('已掌握被手动纳入时 willStudy 计入', () => {
    const wMaster = word('w2', 'banana', 'b1');
    const cands = buildCandidates(['banana'], [wMaster], [schedule('w2', 'MASTERED')]);
    cands[0].selected = true;
    assert.equal(summarizeCandidates(cands).willStudy, 1);
  });
});

describe('F17 洗牌 shuffleList', () => {
  test('注入 rng 时结果确定，且不丢元素', () => {
    const base = [1, 2, 3, 4, 5];
    const out = shuffleList(base, () => 0);
    assert.equal(out.length, 5);
    assert.deepEqual([...out].sort((a, b) => a - b), [1, 2, 3, 4, 5]);
    // 不改原数组
    assert.deepEqual(base, [1, 2, 3, 4, 5]);
  });
});

describe('F17 导入事务 createMemeImport', () => {
  test('新词建 MEME 词本/单词/调度/梗句/进行中会话，原数据不被污染', () => {
    const data: AppData = emptyData();
    const cands: MemeCandidate[] = [
      { token: 'eat', kind: 'NEW', existingWordId: '', selected: true, toggleable: true },
      { token: 'apple', kind: 'NEW', existingWordId: '', selected: true, toggleable: true },
      { token: 'the', kind: 'NEW', existingWordId: '', selected: false, toggleable: true },
    ];
    const before = JSON.stringify(data);
    const r = createMemeImport(data, {
      chinese: '同学这里不能吃饭',
      english: 'Students cannot eat the apple here',
      candidates: cands,
    }, NOW, () => 0);

    // 原数据不可变
    assert.equal(JSON.stringify(data), before);
    // 词本
    assert.equal(r.data.books.length, 1);
    assert.equal(r.data.books[0].source, 'MEME');
    // 三个词都入库（未勾选的 the 也属于梗句词本，但不进会话）
    assert.equal(r.data.words.length, 3);
    assert.ok(r.data.words.every((w) => w.source === 'MEME'));
    assert.equal(r.data.words[0].missingMeaning, true);
    // 梗句
    assert.equal(r.data.memes.length, 1);
    assert.equal(r.data.memes[0].wordIds.length, 3);
    // 会话只含勾选的 2 词
    assert.equal(r.session.status, 'in_progress');
    assert.equal(r.session.items.length, 2);
    assert.ok(r.session.items.every((it) => it.state === 'pending' && it.verdict === null));
  });

  test('勾选不足 2 词拒绝导入', () => {
    const data = emptyData();
    assert.throws(() => createMemeImport(data, {
      chinese: '短',
      english: 'eat',
      candidates: [{ token: 'eat', kind: 'NEW', existingWordId: '', selected: true, toggleable: true }],
    }, NOW), /至少保留 2/);
  });

  test('同名梗句词本自动追加序号', () => {
    const data = emptyData();
    const mk = (): MemeCandidate[] => [
      { token: 'eat', kind: 'NEW', existingWordId: '', selected: true, toggleable: true },
      { token: 'run', kind: 'NEW', existingWordId: '', selected: true, toggleable: true },
    ];
    const r1 = createMemeImport(data, { chinese: '重复句子', english: 'eat run', candidates: mk() }, NOW);
    const r2 = createMemeImport(r1.data, { chinese: '重复句子', english: 'eat run', candidates: mk() }, NOW + 1);
    assert.equal(r1.data.books[0].name, '重复句子');
    assert.equal(r2.data.books[1].name, '重复句子·2');
  });

  test('学习中旧词复用 id，不重复建单词', () => {
    const data = emptyData();
    const exist = word('old1', 'apple', 'b0');
    data.books.push({ id: 'b0', name: '旧本', source: 'DIY_PHOTO', createdAt: NOW - 9999 } as WordBook);
    data.words.push(exist);
    data.records.push(newStudyRecord('old1'));
    data.schedules.push(schedule('old1', 'R2'));
    const r = createMemeImport(data, {
      chinese: '吃苹果',
      english: 'eat apple',
      candidates: [
        { token: 'eat', kind: 'NEW', existingWordId: '', selected: true, toggleable: true },
        { token: 'apple', kind: 'LEARNING', existingWordId: 'old1', selected: true, toggleable: true },
      ],
    }, NOW);
    // 旧词 apple(old1) 保留，只新建 eat 一个 MEME 单词
    assert.equal(r.data.words.length, 2);
    const memeWords = r.data.words.filter((w) => w.source === 'MEME');
    assert.equal(memeWords.length, 1);
    assert.equal(memeWords[0].english, 'eat');
    const apple = r.data.words.find((w) => w.english === 'apple');
    assert.equal(apple?.id, 'old1');
    assert.ok(r.session.items.some((it) => it.wordId === 'old1'));
  });
});

describe('F17 会话推进 advanceSession', () => {
  function importTwo(): AppData {
    const data = emptyData();
    const r = createMemeImport(data, {
      chinese: '测试句',
      english: 'apple banana',
      candidates: [
        { token: 'apple', kind: 'NEW', existingWordId: '', selected: true, toggleable: true },
        { token: 'banana', kind: 'NEW', existingWordId: '', selected: true, toggleable: true },
      ],
    }, NOW);
    return r.data;
  }

  test('新词判认识走 FIRST 调度，离开 NEW 节点', () => {
    let d = importTwo();
    const sid = d.sessions[0].id;
    const wid = d.sessions[0].items[0].wordId;
    const r = advanceSession(d, sid, wid, 'KNOWN', NOW + 1000);
    d = r.data;
    const s = d.schedules.find((x) => x.wordId === wid);
    assert.notEqual(s?.stage, 'NEW');
    const item = r.session.items.find((it) => it.wordId === wid);
    assert.equal(item?.state, 'reviewed');
    assert.equal(item?.verdict, 'KNOWN');
    assert.equal(r.completed, false);
  });

  test('模糊保持 pending 供 UI 重插队尾，会话不完成', () => {
    let d = importTwo();
    const sid = d.sessions[0].id;
    const wid = d.sessions[0].items[0].wordId;
    const r = advanceSession(d, sid, wid, 'VAGUE', NOW + 1000);
    assert.equal(r.completed, false);
    assert.equal(sessionPendingCount(r.session), 2);
    const item = r.session.items.find((it) => it.wordId === wid);
    assert.equal(item?.state, 'pending');
    assert.equal(item?.verdict, 'VAGUE');
  });

  test('全部 reviewed 后会话 completed 并回写梗句学习时间', () => {
    let d = importTwo();
    const sid = d.sessions[0].id;
    const [a, b] = d.sessions[0].items;
    let r = advanceSession(d, sid, a.wordId, 'KNOWN', NOW + 1000);
    d = r.data;
    r = advanceSession(d, sid, b.wordId, 'UNKNOWN', NOW + 2000);
    assert.equal(r.completed, true);
    assert.equal(r.session.status, 'completed');
    assert.equal(r.session.completedAt, NOW + 2000);
    assert.equal(r.knownCount, 1);
    assert.equal(r.data.memes[0].lastStudiedAt, NOW + 2000);
  });

  test('学习中词只进会话不改排期', () => {
    const data = emptyData();
    data.books.push({ id: 'b0', name: '旧本', source: 'DIY_PHOTO', createdAt: NOW - 9999 } as WordBook);
    data.words.push(word('old1', 'apple', 'b0'));
    data.records.push(newStudyRecord('old1'));
    data.schedules.push(schedule('old1', 'R4'));
    const r = createMemeImport(data, {
      chinese: '旧词强化',
      english: 'apple banana',
      candidates: [
        { token: 'apple', kind: 'LEARNING', existingWordId: 'old1', selected: true, toggleable: true },
        { token: 'banana', kind: 'NEW', existingWordId: '', selected: true, toggleable: true },
      ],
    }, NOW);
    let d2 = r.data;
    const sid = d2.sessions[0].id;
    const before = JSON.stringify(d2.schedules.find((x) => x.wordId === 'old1'));
    const out = advanceSession(d2, sid, 'old1', 'KNOWN', NOW + 500);
    const after = JSON.stringify(out.data.schedules.find((x) => x.wordId === 'old1'));
    assert.equal(before, after);
  });
});

describe('F17 续背查找 findResumableSession', () => {
  test('按 memeId 过滤、只取 in_progress、取最新一场', () => {
    const d = emptyData();
    d.sessions = [
      { id: 's1', memeId: 'm1', items: [], createdAt: 1, completedAt: 0, status: 'completed' },
      { id: 's2', memeId: 'm1', items: [], createdAt: 2, completedAt: 0, status: 'in_progress' },
      { id: 's3', memeId: 'm1', items: [], createdAt: 3, completedAt: 0, status: 'in_progress' },
      { id: 's4', memeId: 'm2', items: [], createdAt: 4, completedAt: 0, status: 'in_progress' },
    ];
    assert.equal(findResumableSession(d, 'm1')?.id, 's3');
    assert.equal(findResumableSession(d, 'm2')?.id, 's4');
    assert.equal(findResumableSession(d, 'm9'), null);
  });
});

describe('F17 再背一遍 createRestudySession', () => {
  test('全部词（含已掌握）重新洗牌、会话重置为进行中', () => {
    const d = emptyData();
    d.memes = [{
      id: 'm1', chinese: 'x', english: 'a b c', bookId: 'b1',
      wordIds: ['w1', 'w2', 'w3'], createdAt: NOW, lastStudiedAt: NOW,
    }];
    const r = createRestudySession(d, d.memes[0], NOW + 5000, () => 0);
    assert.equal(r.session.items.length, 3);
    assert.equal(r.session.status, 'in_progress');
    assert.ok(r.session.items.every((it) => it.state === 'pending'));
  });
});

describe('F18 徽章分级 badgeOf（随 F17 先测）', () => {
  test('边界：0.8 金、0.5 银、以下铜、零词防御', () => {
    assert.equal(badgeOf(8, 10), 'GOLD');
    assert.equal(badgeOf(5, 10), 'SILVER');
    assert.equal(badgeOf(4, 10), 'BRONZE');
    assert.equal(badgeOf(0, 0), 'BRONZE');
    assert.equal(badgeLabel('GOLD'), '梗王金');
    assert.equal(badgeLabel('SILVER'), '梗手银');
    assert.equal(badgeLabel('BRONZE'), '梗新人铜');
  });
});
