/**
 * F17 梗句导入（并入统一背词流程后）· 纯逻辑单测（Node 内置 test runner）。
 * 运行：node --import ./register.mjs --test meme.test.ts
 *
 * 重构口径：梗句不再有专用背诵会话——新词走 RepoCore.importTransaction
 * 统一排期（QUEUE/TODAY），F18 梗卡在「梗句关联全部词 mastered」后自动解锁。
 */
import { test, describe } from 'node:test';
import assert from 'node:assert/strict';

import { emptyData, importTransaction } from '../Cihui/entry/src/main/ets/model/RepoCore.ts';
import type { AppData } from '../Cihui/entry/src/main/ets/model/RepoCore.ts';
import { newImportedSchedule, newStudyRecord } from '../Cihui/entry/src/main/ets/model/SchedulerCore.ts';
import type { ReviewSchedule, Word, WordBook } from '../Cihui/entry/src/main/ets/model/Types.ts';
import {
  backfillMemeMeanings,
  badgeOf,
  badgeLabel,
  buildCandidates,
  createMemeBook,
  createMemeRecord,
  memeMasteredCount,
  memeWordDrafts,
  resolveMemeWordIds,
  shuffleList,
  summarizeCandidates,
  tokenizeEnglish,
  unlockMemeCards,
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

function cand(token: string, kind: MemeCandidate['kind'] = 'NEW',
  existingWordId = '', selected = true): MemeCandidate {
  return { token, kind, existingWordId, selected, toggleable: kind !== 'MASTERED' };
}

describe('F17 拆词 tokenizeEnglish', () => {
  test('小写化、按非字母切分、丢短词/数字/停用词、按序去重', () => {
    // you/the/here 是停用词；can't 的词头 can 是停用词 → 缩写兜底整词丢弃（见 MemeCore 注释）；
    // 123 丢；quick 去重
    const toks = tokenizeEnglish("You you can't CAN'T eat 123 here-here, the quick quick.");
    assert.deepEqual(toks, ['eat', 'quick']);
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

describe('F17 导入链路（createMemeBook → memeWordDrafts → importTransaction → resolve → createMemeRecord）', () => {
  function cands(): MemeCandidate[] {
    return [
      cand('eat'),
      cand('apple'),
      cand('the', 'NEW', '', false), // 未勾选：仍入库归梗句词本，但不参与「至少 2 词」
    ];
  }

  test('新词建 MEME 词本/单词/调度/梗句，原数据不被污染', () => {
    const data: AppData = emptyData();
    const before = JSON.stringify(data);
    const booked = createMemeBook(data, '同学这里不能吃饭', NOW);
    const drafts = memeWordDrafts(cands(), booked.bookId);
    const imported = importTransaction(booked.data, drafts, NOW, 'QUEUE');
    const ids = resolveMemeWordIds(imported, cands(), booked.bookId);
    const rec = createMemeRecord(imported, '同学这里不能吃饭',
      'Students cannot eat the apple here', booked.bookId, ids, NOW);
    const r = rec.data;

    // 原数据不可变
    assert.equal(JSON.stringify(data), before);
    // 词本
    assert.equal(r.books.length, 1);
    assert.equal(r.books[0].source, 'MEME');
    // 三个新词都入库（未勾选的 the 也属于梗句词本）
    assert.equal(r.words.length, 3);
    assert.ok(r.words.every((w) => w.source === 'MEME'));
    assert.equal(r.words[0].missingMeaning, true);
    // 梗句记录词 id 与导入结果一一对应
    assert.equal(r.memes.length, 1);
    assert.equal(r.memes[0].wordIds.length, 3);
    assert.deepEqual([...ids].sort(), [...r.words.map((w) => w.id)].sort());
    // 统一导入事务已排期（QUEUE 口径），不再创建任何背诵会话
    assert.equal(r.schedules.length, 3);
    assert.equal(r.sessions.length, 0);
  });

  test('TODAY 入列：dueDay=今天且标 intake=TODAY（与拍照导入同口径）', () => {
    const booked = createMemeBook(emptyData(), '今天就背', NOW);
    const drafts = memeWordDrafts([cand('eat'), cand('run')], booked.bookId);
    const r = importTransaction(booked.data, drafts, NOW, 'TODAY');
    assert.ok(r.schedules.every((s) => s.intake === 'TODAY'));
    assert.ok(r.schedules.every((s) => s.dueDay.length > 0));
  });

  test('学习中旧词复用 id，不重复建单词；释义 backfill 只补空不覆盖', () => {
    const data = emptyData();
    data.books.push({ id: 'b0', name: '旧本', source: 'DIY_PHOTO', createdAt: NOW - 9999 } as WordBook);
    // old1 释义为空（老版本遗留），old2 释义已有（用户手填）
    data.words.push({ ...word('old1', 'apple', 'b0'), meanings: [], missingMeaning: true });
    data.words.push(word('old2', 'banana', 'b0'));
    data.records.push(newStudyRecord('old1'));
    data.records.push(newStudyRecord('old2'));
    data.schedules.push(schedule('old1', 'R2'));
    data.schedules.push(schedule('old2', 'R4'));
    const cs: MemeCandidate[] = [
      cand('eat'),
      { ...cand('apple', 'LEARNING', 'old1'), meaning: '苹果', phonetic: '/ˈæpl/' },
      { ...cand('banana', 'LEARNING', 'old2'), meaning: '香蕉' },
    ];
    const booked = createMemeBook(data, '吃苹果', NOW);
    const drafts = memeWordDrafts(cs, booked.bookId);
    // 只有新词 eat 进统一导入事务
    assert.equal(drafts.length, 1);
    assert.equal(drafts[0].english, 'eat');
    let next = importTransaction(booked.data, drafts, NOW, 'QUEUE');
    next = backfillMemeMeanings(next, cs);
    const ids = resolveMemeWordIds(next, cs, booked.bookId);
    const r = createMemeRecord(next, '吃苹果', 'eat apple banana', booked.bookId, ids, NOW).data;

    // 旧词保留且不重复
    assert.equal(r.words.filter((w) => w.english === 'apple').length, 1);
    const apple = r.words.find((w) => w.english === 'apple');
    assert.equal(apple?.id, 'old1');
    // backfill：old1 空释义被词典结果补上；old2 已有释义不被覆盖
    assert.deepEqual(apple?.meanings, ['苹果']);
    assert.equal(apple?.phonetic, '/ˈæpl/');
    const banana = r.words.find((w) => w.english === 'banana');
    assert.deepEqual(banana?.meanings, ['x']);
    // 梗句词 id：旧词复用 + 新词回查
    assert.equal(ids.length, 3);
    assert.ok(ids.includes('old1') && ids.includes('old2'));
  });

  test('resolveMemeWordIds 按词本 + 小写英文回查新词 id', () => {
    const booked = createMemeBook(emptyData(), '回查', NOW);
    const drafts = memeWordDrafts([cand('Eat')], booked.bookId);
    const r = importTransaction(booked.data, drafts, NOW, 'QUEUE');
    const ids = resolveMemeWordIds(r, [cand('eat')], booked.bookId);
    assert.equal(ids.length, 1);
    assert.equal(ids[0], r.words[0].id);
  });
});

describe('F18 解锁 unlockMemeCards（梗句关联全部词 mastered 才落卡）', () => {
  function importMeme(intake: 'QUEUE' | 'TODAY' = 'QUEUE'): AppData {
    const booked = createMemeBook(emptyData(), '测试句', NOW);
    const cs = [cand('apple'), cand('banana')];
    const drafts = memeWordDrafts(cs, booked.bookId);
    let d = importTransaction(booked.data, drafts, NOW, intake);
    const ids = resolveMemeWordIds(d, cs, booked.bookId);
    return createMemeRecord(d, '测试句', 'apple banana', booked.bookId, ids, NOW).data;
  }

  test('未全部 mastered 不解锁', () => {
    const d = importMeme();
    // 只掌握其中一个词
    const partial: AppData = {
      ...d,
      schedules: d.schedules.map((s) =>
        s.wordId === d.memes[0].wordIds[0] ? schedule(s.wordId, 'MASTERED') : s),
    };
    const out = unlockMemeCards(partial, NOW + 1000);
    assert.equal(out.memeCards.length, 0);
    assert.equal(memeMasteredCount(out, out.memes[0]), 1);
  });

  test('全部 mastered 自动落卡：masteredCount 实时=总数、徽章金、幂等不重复', () => {
    const d = importMeme();
    const all: AppData = {
      ...d,
      schedules: d.schedules.map((s) => schedule(s.wordId, 'MASTERED')),
    };
    assert.equal(memeMasteredCount(all, all.memes[0]), 2);
    const out = unlockMemeCards(all, NOW + 1000);
    assert.equal(out.memeCards.length, 1);
    const card = out.memeCards[0];
    assert.equal(card.memeId, out.memes[0].id);
    assert.equal(card.masteredCount, 2);
    assert.equal(card.totalCount, 2);
    assert.equal(card.badgeLevel, 'GOLD');
    assert.equal(card.cardImagePath, '');
    // 幂等：重复调用不产生第二张卡
    assert.equal(unlockMemeCards(out, NOW + 2000).memeCards.length, 1);
  });

  test('无梗句 / 梗句无词时原样返回', () => {
    const d = emptyData();
    assert.equal(unlockMemeCards(d, NOW), d);
    const noWords: AppData = {
      ...emptyData(),
      memes: [{ id: 'm1', chinese: 'x', english: 'y', bookId: 'b1', wordIds: [], createdAt: NOW, lastStudiedAt: 0 }],
    };
    assert.equal(unlockMemeCards(noWords, NOW), noWords);
  });

  test('历史已解锁梗卡保留：已有卡的梗句不重复落卡', () => {
    const d = importMeme();
    const all: AppData = {
      ...d,
      schedules: d.schedules.map((s) => schedule(s.wordId, 'MASTERED')),
      memeCards: [{
        id: 'c1', memeId: d.memes[0].id, cardImagePath: '/old.jpg',
        masteredCount: 1, totalCount: 2, badgeLevel: 'SILVER',
        unlockedDay: '2026-08-01', isFavorite: true, sharedCount: 3, unlockedAt: NOW - 999,
      }],
    };
    const out = unlockMemeCards(all, NOW + 1000);
    assert.equal(out.memeCards.length, 1);
    assert.equal(out.memeCards[0].id, 'c1');
    assert.equal(out.memeCards[0].cardImagePath, '/old.jpg');
  });
});

describe('F18 徽章分级 badgeOf', () => {
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
