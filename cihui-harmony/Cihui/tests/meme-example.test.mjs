/**
 * 梗句兜底例句单测（Node 直跑纯逻辑，无需真机）。
 * 跑法：node --import ./tests/register-loader.mjs tests/meme-example.test.mjs
 *
 * 死守的几条：
 * - 只认「真的含这个词」的梗句（含时态/复数变形），不误命中别的词
 * - 同分取更短的句子，语境更集中
 * - 中英有一边为空就当没有，不给半张卡
 */
import { findMemeExample, sentenceHasWord, tokenMatchesWord } from '../entry/src/main/ets/model/MemeExampleCore.ts';

let pass = 0;
let fail = 0;

function eq(name, actual, expected) {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a === e) {
    pass++;
  } else {
    fail++;
    console.log(`FAIL ${name}\n  expect: ${e}\n  actual: ${a}`);
  }
}

function m(english, chinese) {
  return {
    id: english, chinese, english, bookId: 'bk', wordIds: [], createdAt: 0, lastStudiedAt: 0,
  };
}

// ---- 词形匹配 ----
eq('原形命中', tokenMatchesWord('abandon', 'abandon'), true);
eq('过去式命中', tokenMatchesWord('abandoned', 'abandon'), true);
eq('复数命中', tokenMatchesWord('studies', 'study'), true);
eq('分词命中', tokenMatchesWord('running', 'run'), true);
eq('不相干不命中', tokenMatchesWord('abandon', 'ability'), false);
eq('空 token 不命中', tokenMatchesWord('', 'abandon'), false);

// ---- 句子级 ----
eq('句子含原形', sentenceHasWord('I will abandon this plan.', 'abandon'), true);
eq('句子含变形', sentenceHasWord('They abandoned the old house.', 'abandon'), true);
eq('句子不含', sentenceHasWord('This is a simple test.', 'abandon'), false);
eq('短语整段匹配', sentenceHasWord('We ate ice cream together.', 'ice cream'), true);
eq('短语不拆分命中', sentenceHasWord('Ice melts fast today.', 'ice cream'), false);

// ---- 挑句子 ----
const MEMES = [
  m('When the plan failed, we had to abandon it completely.', '计划失败时我们只能彻底放弃它。'),
  m('She abandoned the idea after one try.', '她试了一次就放弃了这个想法。'),
  m('Nobody likes a lazy worker like that.', '没人喜欢那样偷懒的人。'),
];

const hit = findMemeExample('abandon', MEMES);
eq('取最短的那条', hit, {
  en: 'She abandoned the idea after one try.',
  zh: '她试了一次就放弃了这个想法。',
});
eq('没有命中返回 null', findMemeExample('abandon', [m('A quiet room helps me focus.', '安静的房间让我更专注。')]), null);
eq('空数组返回 null', findMemeExample('abandon', []), null);
eq('空词返回 null', findMemeExample('   ', MEMES), null);

// 中英有一边为空 -> 不算
eq('缺译文跳过', findMemeExample('abandon', [m('We abandon it.', '')]), null);
eq('缺原文跳过', findMemeExample('abandon', [m('', '我们放弃它。')]), null);

// 多个候选时同长度取先出现的
const TIE = [
  m('We abandon it now.', '我们现在放弃它。'),
  m('They abandon us too.', '他们也放弃我们。'),
];
eq('同长度取先出现', findMemeExample('abandon', TIE), { en: 'We abandon it now.', zh: '我们现在放弃它。' });

console.log(`\n${pass} passed, ${fail} failed`);
if (fail > 0) {
  process.exit(1);
}
