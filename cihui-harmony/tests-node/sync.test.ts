/**
 * F15 云备份合并逻辑测试（Node 内置 test runner）。
 * 运行：node --import ./register.mjs --test sync.test.ts
 */
import { test, describe } from 'node:test';
import assert from 'node:assert/strict';

import { emptyData } from '../Cihui/entry/src/main/ets/model/RepoCore.ts';
import type { AppData } from '../Cihui/entry/src/main/ets/model/RepoCore.ts';
import type {
  CheckInRecord,
  ReviewSchedule,
  StudyRecord,
  Word,
  WordBook,
} from '../Cihui/entry/src/main/ets/model/Types.ts';
import {
  buildBackup,
  mergeAppData,
  mergeProfile,
  parseBackup,
} from '../Cihui/entry/src/main/ets/model/SyncCore.ts';
import type { ProfileSnapshot } from '../Cihui/entry/src/main/ets/model/SyncCore.ts';

function book(id: string, name: string, createdAt: number): WordBook {
  return { id, name, source: 'DIY_MANUAL', createdAt };
}

function word(id: string, meanings: string[], createdAt: number, missing = false): Word {
  return {
    id,
    bookId: 'b1',
    english: id,
    phonetic: '',
    meanings,
    source: 'MANUAL',
    missingMeaning: missing,
    diySupplement: false,
    createdAt,
  };
}

function schedule(wordId: string, stage: string, status: string, lastVerdictAt: number): ReviewSchedule {
  return {
    wordId,
    stage: stage as ReviewSchedule['stage'],
    firstLearnDay: '2026-09-01',
    dueDay: '2026-09-12',
    status: status as ReviewSchedule['status'],
    forceNextDay: false,
    roundRequeue: false,
    wrongReason: '',
    lastVerdictAt,
  };
}

function record(wordId: string, firstPassedAt: number): StudyRecord {
  return {
    wordId,
    firstStudyAt: 1,
    firstPassedAt,
    s1DoneAt: 0,
    s2DoneAt: 0,
    s3DoneAt: 0,
    lastStudyDay: firstPassedAt > 0 ? '2026-09-10' : '',
  };
}

function checkin(day: string, checkedIn: boolean, makeup = false, streak = 1): CheckInRecord {
  return {
    day,
    p1NewDone: checkedIn,
    p2ReviewDone: checkedIn,
    p3WrongDone: checkedIn,
    p3Required: false,
    checkedIn,
    makeup,
    streak,
  };
}

function profile(name: string): ProfileSnapshot {
  return { name, phone: '', email: '', wechat: '', qq: '', cloudEnabled: true };
}

describe('F15 备份文件结构与解析', () => {
  test('buildBackup → parseBackup 往返一致', () => {
    const data: AppData = emptyData();
    data.books.push(book('b1', '我的词本', 1000));
    data.words.push(word('w1', ['苹果'], 1000));
    const file = buildBackup(data, profile('张三'), 5000);
    const parsed = parseBackup(JSON.stringify(file));
    assert.equal(parsed.format, 'cihui-backup');
    assert.equal(parsed.exportedAt, 5000);
    assert.equal(parsed.appData.books.length, 1);
    assert.equal(parsed.profile?.name, '张三');
  });

  test('非法文件全部拒绝，且报错信息明确', () => {
    assert.throws(() => parseBackup('{bad json'), /JSON/);
    assert.throws(() => parseBackup(JSON.stringify({ format: 'other' })), /不是词慧备份/);
    assert.throws(() => parseBackup(JSON.stringify({ format: 'cihui-backup', version: 9 })), /版本/);
    assert.throws(() => parseBackup(JSON.stringify({
      format: 'cihui-backup',
      version: 1,
      appData: {},
    })), /内容不完整/);
  });
});

describe('F15 按时间戳合并恢复', () => {
  test('不相交数据取并集，设置按备份新旧整组归属', () => {
    const local: AppData = emptyData();
    local.books.push(book('b1', '本机词本', 1000));
    local.words.push(word('w1', ['一'], 1000));
    local.settings.dailyNewCount = 10;

    const remote: AppData = emptyData();
    remote.books.push(book('b2', '新机词本', 2000));
    remote.words.push(word('w2', ['二'], 2000));
    remote.settings.dailyNewCount = 30;

    const merged = mergeAppData(local, remote, true);
    assert.equal(merged.summary.books, 2);
    assert.equal(merged.summary.words, 2);
    assert.equal(merged.data.settings.dailyNewCount, 30);

    // 备份更旧时保留本机设置
    const keepLocal = mergeAppData(local, remote, false);
    assert.equal(keepLocal.data.settings.dailyNewCount, 10);
  });

  test('同一单词：义项并集去重，任一端有释义则不再缺释义', () => {
    const local: AppData = emptyData();
    local.words.push(word('w1', ['苹果'], 1000, true));
    const remote: AppData = emptyData();
    const rw = word('w1', ['苹果', '苹果树'], 2000, false);
    remote.words.push(rw);

    const { data } = mergeAppData(local, remote, false);
    assert.equal(data.words.length, 1);
    assert.deepEqual(data.words[0].meanings, ['苹果', '苹果树']);
    assert.equal(data.words[0].missingMeaning, false);
    assert.equal(data.words[0].diySupplement, false);
  });

  test('调度冲突：lastVerdictAt 新的一方为准；同时间掌握态优先', () => {
    const local: AppData = emptyData();
    local.schedules.push(schedule('w1', 'R2', 'LEARNING', 5000));
    const remote: AppData = emptyData();
    remote.schedules.push(schedule('w1', 'R7', 'LEARNING', 9000));
    let { data } = mergeAppData(local, remote, false);
    assert.equal(data.schedules[0].stage, 'R7');

    // 时间戳相同：MASTERED 优先
    const local2: AppData = emptyData();
    local2.schedules.push(schedule('w1', 'R15', 'MASTERED', 9000));
    const remote2: AppData = emptyData();
    remote2.schedules.push(schedule('w1', 'R1', 'WRONG', 9000));
    data = mergeAppData(local2, remote2, false).data;
    assert.equal(data.schedules[0].status, 'MASTERED');
  });

  test('学习记录逐字段取最大时间戳；打卡按天 OR（完成过即完成）', () => {
    const local: AppData = emptyData();
    local.records.push(record('w1', 5000));
    local.checkins.push(checkin('2026-09-10', false));
    const remote: AppData = emptyData();
    const rr = record('w1', 9000);
    rr.firstStudyAt = 2000;
    remote.records.push(rr);
    remote.checkins.push(checkin('2026-09-10', true, true, 3));
    remote.checkins.push(checkin('2026-09-11', true, false, 4));

    const { data } = mergeAppData(local, remote, false);
    assert.equal(data.records[0].firstPassedAt, 9000);
    assert.equal(data.records[0].firstStudyAt, 2000);
    const c10 = data.checkins.find((c) => c.day === '2026-09-10');
    assert.equal(c10?.checkedIn, true);
    assert.equal(c10?.makeup, true);
    assert.equal(c10?.streak, 3);
    assert.equal(data.checkins.length, 2);
  });

  test('与自身合并幂等：数量不增加、状态不回退', () => {
    const data: AppData = emptyData();
    data.books.push(book('b1', '词本', 1000));
    data.words.push(word('w1', ['一'], 1000));
    data.schedules.push(schedule('w1', 'R4', 'MASTERED', 8000));
    data.checkins.push(checkin('2026-09-10', true, false, 2));
    const clone: AppData = JSON.parse(JSON.stringify(data)) as AppData;
    const { data: merged, summary } = mergeAppData(data, clone, false);
    assert.equal(summary.addedBooks, 0);
    assert.equal(summary.addedWords, 0);
    assert.equal(merged.schedules[0].stage, 'R4');
    assert.equal(merged.checkins[0].streak, 2);
  });
});

describe('F15 账号资料合并', () => {
  test('已登录以当前账号为准；未登录（换机）恢复备份资料', () => {
    assert.equal(mergeProfile(profile('本机用户'), profile('备份用户'))?.name, '本机用户');
    assert.equal(mergeProfile(null, profile('备份用户'))?.name, '备份用户');
    assert.equal(mergeProfile(profile('本机用户'), null)?.name, '本机用户');
    assert.equal(mergeProfile(null, null), null);
  });
});
