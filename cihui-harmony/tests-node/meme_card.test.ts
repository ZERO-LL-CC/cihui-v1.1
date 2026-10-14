/**
 * F18 梗卡册纯函数单测：同梗句只留一张卡、空路径保留旧图、收藏/分享/删除、倒序。
 * 运行：node --import ./register.mjs --test meme_card.test.ts
 */
import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import {
  bumpMemeCardShareInto,
  removeMemeCardInto,
  sortMemeCardsDesc,
  toggleMemeCardFavoriteInto,
  upsertMemeCardInto,
} from '../Cihui/entry/src/main/ets/model/MemeCore';
import type { MemeCard } from '../Cihui/entry/src/main/ets/model/Types';

function makeCard(over: Partial<MemeCard>): MemeCard {
  return {
    id: over.id ?? 'card-x',
    memeId: over.memeId ?? 'meme-1',
    cardImagePath: over.cardImagePath ?? '/cache/a.png',
    masteredCount: over.masteredCount ?? 1,
    totalCount: over.totalCount ?? 4,
    badgeLevel: over.badgeLevel ?? 'BRONZE',
    unlockedDay: over.unlockedDay ?? '2026-09-15',
    isFavorite: over.isFavorite ?? false,
    sharedCount: over.sharedCount ?? 0,
    unlockedAt: over.unlockedAt ?? 1000,
  };
}

describe('F18 upsertMemeCardInto 落卡与更新', () => {
  test('空列表新建：字段齐全，未收藏、分享 0，徽章按掌握率分级', () => {
    const r = upsertMemeCardInto([], {
      memeId: 'm1', cardImagePath: '', masteredCount: 4, totalCount: 5, unlockedDay: '2026-09-15',
    }, 1000);
    assert.equal(r.cards.length, 1);
    const c = r.card;
    assert.equal(c.memeId, 'm1');
    assert.equal(c.masteredCount, 4);
    assert.equal(c.totalCount, 5);
    assert.equal(c.badgeLevel, 'GOLD'); // 4/5 = 0.8，>=0.8 即 GOLD
    assert.equal(c.isFavorite, false);
    assert.equal(c.sharedCount, 0);
    assert.equal(c.unlockedAt, 1000);
    assert.ok(c.id.startsWith('memecard'));
  });

  test('掌握率 0.8 整为 GOLD；0.5 整为 SILVER', () => {
    const gold = upsertMemeCardInto([], {
      memeId: 'g', cardImagePath: 'p', masteredCount: 8, totalCount: 10, unlockedDay: 'd',
    }, 1);
    assert.equal(gold.card.badgeLevel, 'GOLD');
    const silver = upsertMemeCardInto([], {
      memeId: 's', cardImagePath: 'p', masteredCount: 5, totalCount: 10, unlockedDay: 'd',
    }, 1);
    assert.equal(silver.card.badgeLevel, 'SILVER');
  });

  test('同 memeId 再背完：只留一张，id 不变，数据随最新更新', () => {
    const first = upsertMemeCardInto([], {
      memeId: 'm1', cardImagePath: '/a.png', masteredCount: 2, totalCount: 4, unlockedDay: '2026-09-14',
    }, 1000);
    // 模拟用户已收藏、已分享 2 次
    first.cards[0].isFavorite = true;
    first.cards[0].sharedCount = 2;
    const second = upsertMemeCardInto(first.cards, {
      memeId: 'm1', cardImagePath: '/b.png', masteredCount: 4, totalCount: 4, unlockedDay: '2026-09-15',
    }, 2000);
    assert.equal(second.cards.length, 1);
    const c = second.card;
    assert.equal(c.id, first.cards[0].id);
    assert.equal(c.cardImagePath, '/b.png');
    assert.equal(c.masteredCount, 4);
    assert.equal(c.badgeLevel, 'GOLD');
    assert.equal(c.unlockedDay, '2026-09-15');
    assert.equal(c.unlockedAt, 2000);
    // 收藏与分享次数沿用
    assert.equal(c.isFavorite, true);
    assert.equal(c.sharedCount, 2);
  });

  test('cardImagePath 传空串时保留旧图路径（Canvas 尚未画好/失败的场景）', () => {
    const first = upsertMemeCardInto([], {
      memeId: 'm1', cardImagePath: '/keep.png', masteredCount: 3, totalCount: 4, unlockedDay: 'd1',
    }, 1000);
    const second = upsertMemeCardInto(first.cards, {
      memeId: 'm1', cardImagePath: '', masteredCount: 4, totalCount: 4, unlockedDay: 'd2',
    }, 2000);
    assert.equal(second.cards.length, 1);
    assert.equal(second.card.cardImagePath, '/keep.png');
    assert.equal(second.card.masteredCount, 4);
  });

  test('不同 memeId 各自一张，互不覆盖', () => {
    const a = upsertMemeCardInto([], {
      memeId: 'a', cardImagePath: 'pa', masteredCount: 1, totalCount: 2, unlockedDay: 'd',
    }, 1000);
    const b = upsertMemeCardInto(a.cards, {
      memeId: 'b', cardImagePath: 'pb', masteredCount: 1, totalCount: 2, unlockedDay: 'd',
    }, 2000);
    assert.equal(b.cards.length, 2);
  });
});

describe('F18 收藏 / 分享计数 / 删除 / 排序', () => {
  test('toggle 只翻转目标卡', () => {
    const cards = [makeCard({ id: 'c1', isFavorite: false }), makeCard({ id: 'c2', isFavorite: true })];
    const out = toggleMemeCardFavoriteInto(cards, 'c1');
    assert.equal(out[0].isFavorite, true);
    assert.equal(out[1].isFavorite, true);
    // 原数组不被改
    assert.equal(cards[0].isFavorite, false);
  });

  test('bump 分享次数 +1，其余不动', () => {
    const cards = [makeCard({ id: 'c1', sharedCount: 0 }), makeCard({ id: 'c2', sharedCount: 3 })];
    const out = bumpMemeCardShareInto(cards, 'c2');
    assert.equal(out[0].sharedCount, 0);
    assert.equal(out[1].sharedCount, 4);
  });

  test('remove 只删卡不抛错，找不到时长度不变', () => {
    const cards = [makeCard({ id: 'c1' }), makeCard({ id: 'c2' })];
    assert.equal(removeMemeCardInto(cards, 'c1').length, 1);
    assert.equal(removeMemeCardInto(cards, 'nope').length, 2);
  });

  test('卡册按 unlockedAt 倒序', () => {
    const cards = [
      makeCard({ id: 'old', unlockedAt: 1000 }),
      makeCard({ id: 'mid', unlockedAt: 2000 }),
      makeCard({ id: 'new', unlockedAt: 3000 }),
    ];
    const sorted = sortMemeCardsDesc(cards);
    assert.deepEqual(sorted.map((c: MemeCard): string => c.id), ['new', 'mid', 'old']);
    // 不改动原数组顺序
    assert.equal(cards[0].id, 'old');
  });
});
