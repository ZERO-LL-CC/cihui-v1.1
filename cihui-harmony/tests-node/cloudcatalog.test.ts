/**
 * F5 云词本目录测试（Node 内置 test runner）。
 * 10 本词书全部为随包真实词库（ECDICT/MIT）：基础核心/大学/出国/高中/中考五类。
 * 运行：node --import ./register.mjs --test cloudcatalog.test.ts
 */
import { test, describe } from 'node:test';
import assert from 'node:assert/strict';

import {
  HOT_SEARCH,
  findCloudBook,
  getGroups,
  getSampleWords,
  searchBooks,
} from '../Cihui/entry/src/main/ets/service/CloudCatalog.ts';

const ALL_IDS: string[] = [
  'oxford3000', 'collins', 'cet4', 'cet6', 'kaoyan',
  'ielts', 'toefl', 'gre', 'gaokao', 'zhongkao',
];

describe('云词本目录', () => {
  test('分组覆盖全部 10 本词书且无重复、无遗留占位', () => {
    const groups = getGroups();
    const ids: string[] = [];
    for (const g of groups) {
      for (const b of g.featured) {
        ids.push(b.id);
      }
      for (const b of g.chips) {
        ids.push(b.id);
      }
    }
    assert.equal(ids.length, 10);
    assert.equal(new Set(ids).size, 10);
    assert.deepEqual([...ids].sort(), [...ALL_IDS].sort());
    // 「筹备中」占位词书已全部下线
    for (const ghost of ['g1', 'g2', 'g3', 'j1', 'j2', 'j3', 'p3', 'p4', 'p5', 'p6']) {
      assert.equal(findCloudBook(ghost), null);
    }
  });

  test('新分类分组与排序：基础核心 → 大学 → 出国 → 高中 → 初中/小学', () => {
    const groups = getGroups();
    assert.deepEqual(groups.map((g) => g.title),
      ['基础核心', '大学词书', '出国词书', '高中词书', '初中 / 小学']);
    const [basic, uni, abroad, senior, junior] = groups;
    assert.deepEqual(basic.featured.map((b) => b.id), ['oxford3000', 'collins']);
    assert.equal(basic.chips.length, 0);
    assert.deepEqual(uni.featured.map((b) => b.id), ['cet4', 'cet6', 'kaoyan']);
    assert.equal(uni.chips.length, 0);
    assert.deepEqual(abroad.featured.map((b) => b.id), ['ielts', 'toefl', 'gre']);
    assert.equal(abroad.chips.length, 0);
    assert.deepEqual(senior.featured.map((b) => b.id), ['gaokao']);
    assert.equal(senior.chips.length, 0);
    assert.equal(junior.featured.length, 0);
    assert.deepEqual(junior.chips.map((b) => b.id), ['zhongkao']);
  });

  test('10 本词书词数与 ECDICT 生成口径一致，热门标记就位', () => {
    assert.equal(findCloudBook('oxford3000')?.totalCount, 3455);
    assert.equal(findCloudBook('collins')?.totalCount, 10553);
    assert.equal(findCloudBook('cet4')?.totalCount, 3846);
    assert.equal(findCloudBook('cet6')?.totalCount, 5406);
    assert.equal(findCloudBook('kaoyan')?.totalCount, 4801);
    assert.equal(findCloudBook('ielts')?.totalCount, 5040);
    assert.equal(findCloudBook('toefl')?.totalCount, 6974);
    assert.equal(findCloudBook('gre')?.totalCount, 7504);
    assert.equal(findCloudBook('gaokao')?.totalCount, 3671);
    assert.equal(findCloudBook('zhongkao')?.totalCount, 1599);
    assert.equal(findCloudBook('not-exist'), null);
    // hot：oxford3000/cet4/cet6/kaoyan/ielts/toefl 为热门
    for (const id of ['oxford3000', 'cet4', 'cet6', 'kaoyan', 'ielts', 'toefl']) {
      assert.equal(findCloudBook(id)?.hot, true, id);
    }
    for (const id of ['collins', 'gre', 'gaokao', 'zhongkao']) {
      assert.equal(findCloudBook(id)?.hot, false, id);
    }
  });

  test('每本词书 12 个预览词且来自本书，未知 ID 返回空', () => {
    for (const id of ALL_IDS) {
      const words = getSampleWords(id);
      assert.equal(words.length, 12, id);
      assert.ok(words.every((w) => w.english.length > 0 && w.meaning.length > 0), id);
    }
    assert.equal(getSampleWords('oxford3000')[0].english, 'only');
    assert.equal(getSampleWords('xxx').length, 0);
  });

  test('搜索：中文词书名、分类、英文预览词均可命中', () => {
    assert.ok(searchBooks('四级').some((b) => b.id === 'cet4'));
    assert.ok(searchBooks('牛津3000').some((b) => b.id === 'oxford3000'));
    assert.ok(searchBooks('雅思').some((b) => b.id === 'ielts'));
    assert.ok(searchBooks('中考').some((b) => b.id === 'zhongkao'));
    // preparation 在 oxford3000/gaokao 的预览词内
    assert.deepEqual(
      searchBooks('preparation').map((b) => b.id).sort(), ['gaokao', 'oxford3000']);
    assert.deepEqual(searchBooks(''), []);
    assert.deepEqual(searchBooks('不存在的词书xyz'), []);
  });

  test('热门搜索固定 8 个，且关键词都能命中至少一本词书或预览词', () => {
    assert.equal(HOT_SEARCH.length, 8);
    for (const kw of HOT_SEARCH) {
      assert.ok(searchBooks(kw).length > 0, kw);
    }
  });
});
