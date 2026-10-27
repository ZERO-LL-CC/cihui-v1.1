/**
 * 词慧 · 语音口述匹配单测（SpeechMatch）
 *
 * 覆盖真机暴露的两类「说了中文也不通过」：
 * 1. 词性标注是 a. / ad.（不是 adj./adv.）→ 归一后残留 a 前缀，义项永远匹配不上
 * 2. 领域标签 [计] [经] [医] [法] → 归一后残留中文字，同样匹配不上
 */
import { matchSpoken, normalizeMeaning, splitMeanings } from '../entry/src/main/ets/model/SpeechMatch.ts';

let pass = 0;
let fail = 0;
function check(cond, name) {
  if (cond) {
    pass += 1;
    console.log(`  ✓ ${name}`);
  } else {
    fail += 1;
    console.log(`  ✗ ${name}`);
  }
}

console.log('[1] 释义归一：词性前缀');
check(normalizeMeaning('a. 重要的') === '重要的', 'a. 形容词前缀被去掉（词库实际写法）');
check(normalizeMeaning('ad. 事实上') === '事实上', 'ad. 副词前缀被去掉');
check(normalizeMeaning('adj. 重要的') === '重要的', 'adj. 仍被去掉');
check(normalizeMeaning('adv. 最后') === '最后', 'adv. 仍被去掉');
check(normalizeMeaning('n. 节目') === '节目', 'n. 名词前缀被去掉');
check(normalizeMeaning('vt. 规划') === '规划', 'vt. 及物动词前缀被去掉');
check(normalizeMeaning('vi. 变卖') === '变卖', 'vi. 不及物动词前缀被去掉');
check(normalizeMeaning('abbr. 缩写') === '缩写', 'abbr. 缩写前缀被去掉（不被 a. 抢先）');

console.log('[2] 释义归一：领域标签与标点');
check(normalizeMeaning('[计] 程序') === '程序', '[计] 领域标签被去掉');
check(normalizeMeaning('[经] 公众') === '公众', '[经] 领域标签被去掉');
check(normalizeMeaning('[医] 会议') === '会议', '[医] 领域标签被去掉');
check(normalizeMeaning('重要的（指事物）') === '重要的', '圆括号补充被去掉');

console.log('[3] 义项拆分');
const sig = ['a. 重要的, 有效的, 有含义的, 暗示的, 值得注意的'];
check(JSON.stringify(splitMeanings(sig)) ===
  JSON.stringify(['重要的', '有效的', '有含义的', '暗示的', '值得注意的']),
  '英文逗号 + a. 前缀：拆成 5 个干净义项');
const zhComma = ['a. 重要的，重大的'];
check(JSON.stringify(splitMeanings(zhComma)) === JSON.stringify(['重要的', '重大的']),
  '中文逗号也能拆分');
const prog = ['n. 节目, 节目单, 程序, 纲要；[计] 程序'];
check(splitMeanings(prog).indexOf('计程序') < 0, '不再产生「计程序」这种脏义项');
check(splitMeanings(prog).indexOf('程序') >= 0, '「程序」义项正常保留');

console.log('[4] 三档判定（significant 真机实例）');
check(matchSpoken('重要的', sig, 'MID').known === true, 'MID：说「重要的」通过');
check(matchSpoken('重要的', sig, 'STRICT').known === true, 'STRICT：第一个义项就是「重要的」，通过');
check(matchSpoken('值得注意的', sig, 'STRICT').known === false, 'STRICT：非首个义项不通过');
check(matchSpoken('值得注意的', sig, 'MID').known === true, 'MID：任一义项通过');
check(matchSpoken('重要的', sig, 'LEN').known === true, 'LEN：通过');

console.log('[5] 判定边界');
check(matchSpoken('', sig, 'MID').known === false, '空识别结果不通过');
check(matchSpoken('   ', sig, 'MID').known === false, '纯空白不通过');
check(matchSpoken('不知道', sig, 'MID').known === false, '不相干的口述不通过');
check(matchSpoken('我觉得是重要的意思', sig, 'MID').known === true, '整句里包含义项也算通过');
check(matchSpoken('重要的', [], 'MID').known === false, '无释义不通过');
check(matchSpoken('重要的', ['［计］重要的'], 'MID').known === true, '全角方括号标签也能去掉');

console.log('[6] 口述归一：全角与标点');
check(matchSpoken('重要的。', sig, 'MID').known === true, '句末中文句号不影响');
check(matchSpoken('重 要 的', sig, 'MID').known === true, '词间空格不影响');

console.log(`[词慧语音匹配测试] 通过 ${pass} 项，失败 ${fail} 项`);
process.exit(fail > 0 ? 1 : 0);
