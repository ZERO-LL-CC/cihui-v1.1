/**
 * F4 OCR 行解析器测试（Node 内置 test runner，直接吃工程里的 .ts 纯逻辑源码）。
 * 运行：node --import ./register.mjs --test ocrparser.test.ts
 */
import { test, describe } from 'node:test';
import assert from 'node:assert/strict';

import { parseOcrLines, tokenizeEnglishWords } from '../Cihui/entry/src/main/ets/service/OcrParser.ts';

describe('parseOcrLines 基础配对', () => {
  test('英文 + 词性 + 中文释义 同一行', () => {
    const r = parseOcrLines(['apple  n. 苹果；苹果树']);
    assert.equal(r.length, 1);
    assert.equal(r[0].english, 'apple');
    assert.equal(r[0].phonetic, '');
    assert.ok(r[0].meaning.includes('苹果'));
    assert.ok(r[0].meaning.includes('苹果树'));
    assert.ok(!r[0].meaning.includes('n.'));
  });

  test('音标行与词性剥离（斜杠音标）', () => {
    const r = parseOcrLines(['abandon', '/əˈbændən/', 'v. 放弃；抛弃']);
    assert.equal(r.length, 1);
    assert.equal(r[0].english, 'abandon');
    assert.equal(r[0].phonetic, '/əˈbændən/');
    assert.equal(r[0].meaning, '放弃；抛弃');
  });

  test('方括号音标归一为斜杠', () => {
    const r = parseOcrLines(['book', '[bʊk]', 'n. 书；书本']);
    assert.equal(r.length, 1);
    assert.equal(r[0].phonetic, '/bʊk/');
  });
});

describe('parseOcrLines 跨行与去重', () => {
  test('纯中文续行挂到上一条英文', () => {
    const r = parseOcrLines(['patient', '/ˈpeɪʃnt/', 'adj. 有耐心的', 'n. 病人']);
    assert.equal(r.length, 1);
    assert.ok(r[0].meaning.includes('有耐心的'));
    assert.ok(r[0].meaning.includes('病人'));
  });

  test('重复英文按小写合并释义与音标', () => {
    const r = parseOcrLines([
      'book  n. 书',
      'book  v. 预订',
    ]);
    assert.equal(r.length, 1);
    assert.ok(r[0].meaning.includes('书'));
    assert.ok(r[0].meaning.includes('预订'));
  });

  test('序号与多条编号释义清理', () => {
    const r = parseOcrLines(['run  1.跑 2.运营 3.褪色']);
    assert.equal(r.length, 1);
    assert.equal(r[0].english, 'run');
    assert.ok(!/^\d/.test(r[0].meaning.trim()));
  });
});

describe('parseOcrLines 噪声过滤', () => {
  test('纯数字、页码、空行被过滤', () => {
    const r = parseOcrLines(['', '12', 'Unit 1', 'cat  n. 猫', '  ']);
    const words = r.map((x) => x.english);
    assert.deepEqual(words, ['cat']);
  });

  test('空数组返回空结果', () => {
    assert.deepEqual(parseOcrLines([]), []);
  });
});

describe('tokenizeEnglishWords 单词气泡分词 (#25)', () => {
  test('拆出独立单词，去标题/词性/功能词，保序', () => {
    const r = tokenizeEnglishWords([
      'Unit 1',
      'abandon /əˈbændən/ v. 放弃；抛弃',
      'ability n. 能力；才能',
      'the cat and the dog',
    ]);
    assert.deepEqual(r, ['abandon', 'ability', 'cat', 'dog']);
  });

  test('按小写去重并保留首次拼写', () => {
    assert.deepEqual(tokenizeEnglishWords(['Book', 'book', 'BOOK']), ['Book']);
  });

  test('词性裸词与缩写被过滤', () => {
    assert.deepEqual(tokenizeEnglishWords(['adj.', 'n.', 'sth.', 'eg.']), []);
  });

  test('撇号与连字符单词整体保留', () => {
    const r = tokenizeEnglishWords(["don't", 'state-of-the-art', 'well-known']);
    assert.deepEqual(r, ["don't", 'state-of-the-art', 'well-known']);
  });

  test('空输入返回空数组', () => {
    assert.deepEqual(tokenizeEnglishWords([]), []);
  });
});
