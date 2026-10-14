/**
 * F5 云词本目录测试（Node 内置 test runner）。
 * 5 本词书为随包真实词库（ECDICT/MIT），10 本分年级词书标注 coming（筹备中）。
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

describe('云词本目录', () => {
  test('分组覆盖全部 15 本词书且无重复', () => {
    const groups = getGroups();
    assert.equal(groups.length, 3);
    const ids: string[] = [];
    for (const g of groups) {
      for (const b of g.featured) {
        ids.push(b.id);
      }
      for (const b of g.chips) {
        ids.push(b.id);
      }
    }
    assert.equal(ids.length, 15);
    assert.equal(new Set(ids).size, 15);
  });

  test('大学词书 3 本全部为大卡', () => {
    const uni = getGroups()[0];
    assert.equal(uni.title, '大学词书');
    assert.equal(uni.featured.length, 3);
    assert.equal(uni.chips.length, 0);
  });

  test('真实词书词数为 ECDICT 生成口径，筹备中词书词数为 0', () => {
    assert.equal(findCloudBook('cet4')?.totalCount, 3846);
    assert.equal(findCloudBook('cet6')?.totalCount, 5406);
    assert.equal(findCloudBook('kaoyan')?.totalCount, 4801);
    assert.equal(findCloudBook('gaokao')?.totalCount, 3671);
    assert.equal(findCloudBook('zhongkao')?.totalCount, 1599);
    assert.equal(findCloudBook('p3')?.coming, true);
    assert.equal(findCloudBook('p3')?.totalCount, 0);
    assert.equal(findCloudBook('not-exist'), null);
  });

  test('真实词书 12 个预览词且来自本书，筹备中与未知 ID 返回空', () => {
    const cet4 = getSampleWords('cet4');
    assert.equal(cet4.length, 12);
    assert.equal(cet4[0].english, 'abandon');
    assert.ok(cet4.every((w) => w.meaning.length > 0));
    assert.equal(getSampleWords('p3').length, 0);
    assert.equal(getSampleWords('xxx').length, 0);
  });

  test('搜索：中文词书名、年级、英文预览词均可命中', () => {
    assert.ok(searchBooks('四级').some((b) => b.id === 'cet4'));
    assert.ok(searchBooks('七年级').some((b) => b.id === 'j1'));
    // abandon 在 cet4/cet6/kaoyan/gaokao 的前 12 个预览词内
    const abandonHits = searchBooks('abandon').map((b) => b.id).sort();
    assert.deepEqual(abandonHits, ['cet4', 'cet6', 'gaokao', 'kaoyan']);
    assert.deepEqual(searchBooks(''), []);
    assert.deepEqual(searchBooks('不存在的词书xyz'), []);
  });

  test('热门搜索固定 8 个', () => {
    assert.equal(HOT_SEARCH.length, 8);
  });
});
