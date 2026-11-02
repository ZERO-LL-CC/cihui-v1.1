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

console.log('[7] 词性全域隔离（任意位置，不只是行首）');
check(normalizeMeaning('vt. 放弃, 抛弃；n. 放任') === '放弃抛弃放任', '中段 n. 也被隔离');
check(normalizeMeaning('n.&vt. 使重要') === '使重要', '连写 n.&vt. 两个都隔离');
check(normalizeMeaning('名词 重要性') === '重要性', '中文词性前缀被隔离');
check(normalizeMeaning('重要性（名词）') === '重要性', '圆括号里的中文词性被隔离');
const multi = splitMeanings(['n. 能力, 才干；vt. 使有能力']);
check(JSON.stringify(multi) === JSON.stringify(['能力', '才干', '使有能力']),
  '一条释义里两段不同词性，拆出的义项都不带词性残留');

console.log('[8] 方括号：标签删除 / 补字保留');
check(normalizeMeaning('腹[部]') === '腹部', '腹[部] 去括号留字（旧实现只剩「腹」）');
check(normalizeMeaning('[医] 腹[部]') === '腹部', '[医] 删标签 + [部] 留字');
check(matchSpoken('腹部', ['n. 腹部；[医] 腹[部]'], 'STRICT').known === true, 'STRICT：说「腹部」通过');
check(matchSpoken('腹部', ['[医] 腹[部]'], 'MID').known === true, '只有标签义项时也能比对「腹部」');

console.log('[9] 只念词性不算通过');
check(matchSpoken('名词', sig, 'LEN').known === false, '只说「名词」不通过');
check(matchSpoken('形容词', sig, 'LEN').known === false, '只说「形容词」不通过');
check(matchSpoken('这个是形容词 重要的', sig, 'MID').known === true, '带词性口癖但说出了释义，通过');

console.log('[10] 尾缀容错（说「能干」＝「能干的」）');
check(matchSpoken('能干', ['a. 能干的, 能够的'], 'MID').known === true, 'MID：省略「的」也通过');
check(matchSpoken('能干', ['a. 能干的, 能够的'], 'STRICT').known === true, 'STRICT：首个义项省「的」通过');
check(matchSpoken('能', ['a. 能干的'], 'MID').known === false, '只说出一个字不通过');

console.log('[11] 释义本身就是词性名（adverb = n. 副词）不被自己的隔离规则抹掉');
check(JSON.stringify(splitMeanings(['n. 副词'])) === JSON.stringify(['副词']), 'adverb：隔离后为空则回退保留「副词」');
check(matchSpoken('副词', ['n. 副词'], 'MID').known === true, 'MID：说「副词」通过');
check(matchSpoken('副词', ['n. 副词'], 'STRICT').known === true, 'STRICT：说「副词」通过');
check(matchSpoken('冠词', ['n. 文章, 冠词；[计] 信件'], 'MID').known === true, 'article：含正常义项时也能说「冠词」');
check(splitMeanings(['n. 文章, 冠词']).indexOf('冠词') >= 0, 'article：「冠词」义项保留');

console.log('[12] 中文释义里的 OCR 残渣清洗（真机录入实例）');
check(normalizeMeaning('精精密的ladi') === '精精密的', '(adj) 识别成 ladi 的残渣被清掉');
check(normalizeMeaning('代表n)') === '代表', '不配对的右括号残渣 n) 被清掉');
check(normalizeMeaning('竞争(1') === '竞争', '不配对的左括号残渣 (1 被清掉');
check(normalizeMeaning('各种名样的lad))') === '各种名样的', '尾部 lad)) 被清掉');
check(normalizeMeaning('DNA') === 'dna', '纯英文释义不受影响');
check(splitMeanings(['n. DNA 脱氧核糖核酸']).indexOf('脱氧核糖核酸') >= 0, '中英混排只留中文');

console.log('[13] 连续重复字折叠（释义录成「精精密的」）');
check(matchSpoken('精密的', ['精精密的ladi'], 'MID').known === true, '说「精密的」能对上「精精密的」');
check(matchSpoken('精精密的', ['精精密的'], 'MID').known === true, '照卡片上的错释义复述也算对');

console.log('[14] 单字容错（离线 ASR 错一个字）');
// 反向死守：说错一个字绝不能判过。ASR 把「精密的」识别成「阴密的」时，
// 正确反应是「不通过 + 提示」，而不是「放宽到错字也算对」——放过它等于教用户记错。
check(matchSpoken('阴密的', ['精精密的ladi'], 'MID').known === false,
  '真机实例：说「精密的」被 ASR 识别成「阴密的」，必须不过');
check(matchSpoken('阴密的', ['精密的'], 'MID').known === false, '「阴密的」不能因形近判过「精密的」');
check(matchSpoken('精密的', ['精精密的ladi'], 'MID').known === true,
  '释义录成「精精密的」时，说「精密的」应判过（折叠在清洗侧做）');
check(matchSpoken('各种名样的', ['各种名样的lad))'], 'MID').known === true,
  '释义带 OCR 残渣时，说干净版本能过（残渣在匹配侧清除）');
check(matchSpoken('我喜欢吃饭', ['精精密的'], 'MID').known === false, '不相干整句不误过');
check(matchSpoken('随便说点什么', ['精精密的ladi'], 'MID').known === false, '不相干整句不误过（脏释义）');

console.log(`[词慧语音匹配测试] 通过 ${pass} 项，失败 ${fail} 项`);
process.exit(fail > 0 ? 1 : 0);
