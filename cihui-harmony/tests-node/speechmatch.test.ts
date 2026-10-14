import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  matchSpoken,
  normalizeMeaning,
  normalizeSpoken,
  splitMeanings,
} from '../Cihui/entry/src/main/ets/model/SpeechMatch.ts';

test('normalizeMeaning 剥离英文词性与括号补充', () => {
  assert.equal(normalizeMeaning('vt. 放弃；抛弃'), '放弃抛弃');
  assert.equal(normalizeMeaning('n. 能力（某种技能）'), '能力');
  assert.equal(normalizeMeaning('adj.  急切的，渴望的'), '急切的渴望的');
});

test('normalizeMeaning 剥离中文词性', () => {
  assert.equal(normalizeMeaning('名词 地平线'), '地平线');
  assert.equal(normalizeMeaning('动词 宣布；声明'), '宣布声明');
});

test('splitMeanings 多义项拆分去重保序', () => {
  const senses = splitMeanings(['v. 宣布；声明', '声明']);
  assert.deepEqual(senses, ['宣布', '声明']);
});

test('normalizeSpoken 全角标点与空白归一', () => {
  assert.equal(normalizeSpoken(' 放弃！'), '放弃');
  assert.equal(normalizeSpoken('ａｂａｎｄｏｎ'), 'abandon');
  assert.equal(normalizeSpoken('，，。'), '');
});

test('MID 标准档：完整命中任一义项即认识，尾字丢失不算', () => {
  const meanings = ['vt. 放弃；抛弃', 'n. 放纵'];
  assert.equal(matchSpoken('这个词就是放弃吧', meanings, 'MID').known, true);
  assert.equal(matchSpoken('我选择抛弃它', meanings, 'MID').known, true);
  assert.equal(matchSpoken('放', meanings, 'MID').known, false);
});

test('STRICT 严格档：只认第一个义项', () => {
  const meanings = ['v. 宣布；声明', 'adj. 公然的'];
  assert.equal(matchSpoken('宣布一下', meanings, 'STRICT').known, true);
  assert.equal(matchSpoken('声明一下', meanings, 'STRICT').known, false);
  assert.equal(matchSpoken('这是公然的', meanings, 'STRICT').known, false);
});

test('LEN 宽松档：义项前两字命中也算认识', () => {
  const meanings = ['adj. 急切的；渴望的'];
  assert.equal(matchSpoken('急切', meanings, 'LEN').known, true);
  assert.equal(matchSpoken('渴望', meanings, 'MID').known, false);
});

test('静音/空结果不自动过词', () => {
  assert.equal(matchSpoken('', ['放弃'], 'MID').known, false);
  assert.equal(matchSpoken('。。。', ['放弃'], 'MID').known, false);
  assert.equal(matchSpoken('放弃', [], 'MID').known, false);
});
