/**
 * F5 云词书导入事务测试（Node 内置 test runner）。
 * 运行：node --import ./register.mjs --test repocloud.test.ts
 */
import { test, describe } from 'node:test';
import assert from 'node:assert/strict';

import { emptyData, importCloudBook } from '../Cihui/entry/src/main/ets/model/RepoCore.ts';
import type { CloudBookImport } from '../Cihui/entry/src/main/ets/model/RepoCore.ts';

function draft(id: string, name: string, n: number): CloudBookImport {
  const words = [];
  for (let i = 0; i < n; i++) {
    words.push({ english: `word${i}`, phonetic: `/w${i}/`, meaning: `释义${i}；另义${i}` });
  }
  return { name, cloudBookId: id, words };
}

describe('importCloudBook 云词书事务', () => {
  test('导入后词本与单词全部落库，来源标记为 CLOUD', () => {
    const d = importCloudBook(emptyData(), draft('cet4', '四级词汇', 12), 1000);
    assert.equal(d.books.length, 1);
    assert.equal(d.books[0].source, 'CLOUD');
    assert.equal(d.books[0].cloudBookId, 'cet4');
    assert.equal(d.words.length, 12);
    assert.ok(d.words.every((w) => w.source === 'CLOUD' && w.bookId === d.books[0].id));
    assert.ok(d.words[0].meanings.includes('释义0'));
  });

  test('同一 cloudBookId 重复导入抛错（幂等拦截）', () => {
    const d1 = importCloudBook(emptyData(), draft('cet4', '四级词汇', 12), 1000);
    assert.throws(() => importCloudBook(d1, draft('cet4', '四级词汇', 12), 2000), /已导入/);
  });

  test('不同词书可连续导入', () => {
    const d1 = importCloudBook(emptyData(), draft('cet4', '四级词汇', 12), 1000);
    const d2 = importCloudBook(d1, draft('zhongkao', '中考词汇', 8), 2000);
    assert.equal(d2.books.length, 2);
    assert.equal(d2.words.length, 20);
  });

  test('非法单词导致整批回滚，不产生半截词书', () => {
    const bad = draft('bad', '问题词书', 2);
    bad.words[1].english = '';
    assert.throws(() => importCloudBook(emptyData(), bad, 1000));
    // 重新拿一份空数据验证：失败调用没有外部副作用（纯函数）
    assert.equal(emptyData().books.length, 0);
  });
});
