/**
 * 词形还原（lemmatizer）· 纯逻辑，零 import，Node 可直接单测。
 *
 * 为什么需要：离线词典只收原形，而梗句英文里大量出现变形
 * （shattered / executed / nailed / hooked / gets / greatest / moving）。
 * 词典侧已经用 ECDICT 的 exchange 字段生成了 2.8 万条「派生形→原形」索引，
 * 这里的规则还原是**第二道兜底**：索引没覆盖到的词（新造词、拼写变体）再按规则试。
 *
 * 口径：返回**有序候选**，最可能的原形在前；调用方按顺序查词典，第一个命中即用。
 * 规则只做保守还原（宁可不还原，也不要还原成另一个真实单词而给出错释义）。
 */

/** 不规则动词/名词的「变形 → 原形」，只收高频、无歧义的那些 */
const IRREGULAR_PAIRS: string[][] = [
  // be / have / do / go
  ['is', 'be'], ['am', 'be'], ['are', 'be'], ['was', 'be'], ['were', 'be'],
  ['been', 'be'], ['being', 'be'],
  ['has', 'have'], ['had', 'have'], ['having', 'have'],
  ['does', 'do'], ['did', 'do'], ['done', 'do'], ['doing', 'do'],
  ['goes', 'go'], ['went', 'go'], ['gone', 'go'], ['going', 'go'],
  // 高频不规则动词
  ['got', 'get'], ['gotten', 'get'], ['gets', 'get'], ['getting', 'get'],
  ['made', 'make'], ['makes', 'make'], ['making', 'make'],
  ['said', 'say'], ['says', 'say'], ['saying', 'say'],
  ['knew', 'know'], ['known', 'know'], ['knows', 'know'],
  ['thought', 'think'], ['thinks', 'think'],
  ['took', 'take'], ['taken', 'take'], ['takes', 'take'],
  ['came', 'come'], ['comes', 'come'],
  ['saw', 'see'], ['seen', 'see'], ['sees', 'see'],
  ['felt', 'feel'], ['feels', 'feel'],
  ['left', 'leave'], ['leaves', 'leave'],
  ['kept', 'keep'], ['keeps', 'keep'],
  ['brought', 'bring'], ['brings', 'bring'],
  ['bought', 'buy'], ['buys', 'buy'],
  ['built', 'build'], ['builds', 'build'],
  ['broke', 'break'], ['broken', 'break'], ['breaks', 'break'],
  ['spoke', 'speak'], ['spoken', 'speak'], ['speaks', 'speak'],
  ['wrote', 'write'], ['written', 'write'], ['writes', 'write'],
  ['ran', 'run'], ['runs', 'run'], ['running', 'run'],
  ['sat', 'sit'], ['sits', 'sit'], ['sitting', 'sit'],
  ['stood', 'stand'], ['stands', 'stand'],
  ['lost', 'lose'], ['loses', 'lose'], ['losing', 'lose'],
  ['paid', 'pay'], ['pays', 'pay'],
  ['met', 'meet'], ['meets', 'meet'],
  ['won', 'win'], ['wins', 'win'], ['winning', 'win'],
  ['sold', 'sell'], ['sells', 'sell'],
  ['told', 'tell'], ['tells', 'tell'],
  ['ate', 'eat'], ['eaten', 'eat'], ['eats', 'eat'],
  ['drank', 'drink'], ['drunk', 'drink'],
  ['slept', 'sleep'], ['sleeps', 'sleep'],
  ['woke', 'wake'], ['woken', 'wake'],
  ['threw', 'throw'], ['thrown', 'throw'],
  ['caught', 'catch'], ['catches', 'catch'],
  ['taught', 'teach'], ['teaches', 'teach'],
  ['fought', 'fight'], ['fights', 'fight'],
  ['hung', 'hang'], ['hangs', 'hang'],
  ['dug', 'dig'], ['digs', 'dig'],
  ['fed', 'feed'], ['feeds', 'feed'],
  ['led', 'lead'], ['leads', 'lead'],
  ['fled', 'flee'],
  ['sought', 'seek'], ['seeks', 'seek'],
  ['shook', 'shake'], ['shaken', 'shake'],
  ['froze', 'freeze'], ['frozen', 'freeze'],
  ['stole', 'steal'], ['stolen', 'steal'],
  ['hid', 'hide'], ['hidden', 'hide'],
  ['bit', 'bite'], ['bitten', 'bite'],
  ['blew', 'blow'], ['blown', 'blow'],
  ['grew', 'grow'], ['grown', 'grow'],
  ['drew', 'draw'], ['drawn', 'draw'],
  ['flew', 'fly'], ['flown', 'fly'], ['flies', 'fly'],
  ['dying', 'die'], ['dies', 'die'],
  ['lay', 'lie'], ['lain', 'lie'], ['lying', 'lie'],
  ['beat', 'beat'], ['beaten', 'beat'],
  ['bore', 'bear'], ['borne', 'bear'], ['born', 'bear'],
  ['rode', 'ride'], ['ridden', 'ride'],
  ['rose', 'rise'], ['risen', 'rise'],
  ['wore', 'wear'], ['worn', 'wear'],
  ['tore', 'tear'], ['torn', 'tear'],
  ['swam', 'swim'], ['swum', 'swim'],
  ['sang', 'sing'], ['sung', 'sing'],
  ['began', 'begin'], ['begun', 'begin'],
  ['drove', 'drive'], ['driven', 'drive'],
  // 不规则复数 / 比较级
  ['children', 'child'], ['men', 'man'], ['women', 'woman'],
  ['people', 'person'], ['feet', 'foot'], ['teeth', 'tooth'],
  ['mice', 'mouse'], ['geese', 'goose'],
  ['better', 'good'], ['best', 'good'], ['worse', 'bad'], ['worst', 'bad'],
  ['more', 'many'], ['most', 'many'], ['less', 'little'], ['least', 'little'],
  ['further', 'far'], ['furthest', 'far'], ['farther', 'far'], ['farthest', 'far'],
];

/** 二维数组 → Map（ArkTS 要求元组字面量显式成型，直接 new Map([...]) 会类型不匹配） */
function pairsToMap(pairs: string[][]): Map<string, string> {
  const m: Map<string, string> = new Map<string, string>();
  for (const p of pairs) {
    if (p.length >= 2) {
      m.set(p[0], p[1]);
    }
  }
  return m;
}

export const IRREGULAR: Map<string, string> = pairsToMap(IRREGULAR_PAIRS);

/** 词尾双写辅音的去重（stopped → stop，running → run） */
function undouble(stem: string): string {
  const n: number = stem.length;
  if (n < 3) {
    return '';
  }
  const last: string = stem.charAt(n - 1);
  const prev: string = stem.charAt(n - 2);
  if (last !== prev) {
    return '';
  }
  if ('aeiou'.indexOf(last) >= 0) {
    return '';
  }
  if ('bdfglmnprstz'.indexOf(last) < 0) {
    return '';
  }
  return stem.substring(0, n - 1);
}

/** 把 -y 结尾还原成 -i（studies → study） */
function yFromI(stem: string): string {
  const n: number = stem.length;
  if (n >= 2 && stem.charAt(n - 1) === 'i') {
    return stem.substring(0, n - 1) + 'y';
  }
  return '';
}

/**
 * 返回该词形可能的原形候选（有序，最可能在前）。
 * 不含入参本身；遇到已知不规则形直接返回对应原形。
 */
export function lemmaCandidates(word: string): string[] {
  const w: string = word.trim().toLowerCase();
  if (w.length < 3) {
    return [];
  }
  const out: string[] = [];
  const push = (s: string): void => {
    if (s.length >= 2 && s !== w && out.indexOf(s) < 0) {
      out.push(s);
    }
  };

  // 1) 不规则表优先：gets → get 这种规则还原也能出 get，但 done → do 只有表能给
  const irregular: string | undefined = IRREGULAR.get(w);
  if (irregular !== undefined) {
    push(irregular);
  }

  // 2) 复数 / 三单
  if (w.endsWith('ies')) {
    push(w.substring(0, w.length - 3) + 'y');     // studies → study
  }
  if (w.endsWith('ves')) {
    push(w.substring(0, w.length - 3) + 'f');     // shelves → shelf
    push(w.substring(0, w.length - 3) + 'fe');    // knives → knife
  }
  if (w.endsWith('es')) {
    push(w.substring(0, w.length - 2));           // boxes → box
  }
  if (w.endsWith('s') && !w.endsWith('ss') && !w.endsWith('us') && !w.endsWith('is')) {
    push(w.substring(0, w.length - 1));           // gets → get / defenses → defense
  }

  // 3) 过去式 / 过去分词
  if (w.endsWith('ied')) {
    push(w.substring(0, w.length - 3) + 'y');     // tried → try
  }
  if (w.endsWith('ed')) {
    const stem: string = w.substring(0, w.length - 2);
    push(stem);                                   // nailed → nail
    push(stem + 'e');                             // executed → execute
    const un: string = undouble(stem);
    if (un.length > 0) {
      push(un);                                   // stopped → stop / shattered → shatter
    }
  }

  // 4) 现在分词
  if (w.endsWith('ing')) {
    const stem: string = w.substring(0, w.length - 3);
    push(stem);                                   // looking → look
    push(stem + 'e');                             // moving → move
    const un: string = undouble(stem);
    if (un.length > 0) {
      push(un);                                   // running → run
    }
    const y: string = yFromI(stem);
    if (y.length > 0) {
      push(y);                                    // dying → dy? no；lying → ly? 由不规则表处理
    }
  }

  // 5) 比较级 / 最高级
  if (w.endsWith('est')) {
    const stem: string = w.substring(0, w.length - 3);
    push(stem);                                   // greatest → great
    push(stem + 'e');                             // latest → late
    const un: string = undouble(stem);
    if (un.length > 0) {
      push(un);                                   // biggest → big
    }
  }
  if (w.endsWith('er')) {
    const stem: string = w.substring(0, w.length - 2);
    push(stem);                                   // greater → great
    push(stem + 'e');                             // nicer → nice
    const un: string = undouble(stem);
    if (un.length > 0) {
      push(un);                                   // bigger → big
    }
  }

  // 6) 副词 / 名词化派生
  if (w.endsWith('ly') && w.length > 4) {
    const stem: string = w.substring(0, w.length - 2);
    push(stem);                                   // utterly → utter / badly → badl?(查不到，无害)
    const y: string = yFromI(stem);               // happily → happy
    if (y.length > 0) {
      push(y);
    }
    if (stem.endsWith('al') || stem.endsWith('ic')) {
      push(stem.substring(0, stem.length - 2));   // basically → basic
    }
  }
  if (w.endsWith('ment') && w.length > 6) {
    push(w.substring(0, w.length - 4));           // embarrassment → embarrass
  }
  if (w.endsWith('ness') && w.length > 6) {
    push(w.substring(0, w.length - 4));           // happiness → happi(查不到)
    const y: string = yFromI(w.substring(0, w.length - 4));
    if (y.length > 0) {
      push(y);                                    // happiness → happy
    }
  }
  if (w.endsWith('ily') && w.length > 5) {
    push(w.substring(0, w.length - 3) + 'y');     // easily → easy
  }

  return out;
}
