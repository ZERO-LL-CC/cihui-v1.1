#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
从 Tatoeba 中英句对构建「一词一例句」离线库。

输入（data/ 目录）：
  cmn-eng.zip        manythings.org 打包的 Tatoeba 中英句对（TSV：英文 \t 中文 \t 署名）
  pairs.tsv          可选，自建句对（英文 \t 中文），与 zip 合并使用
输出（rawfile/examples/）：
  <bookId>.json      每本词书一个文件，App 按当前词书懒加载
  gaps.json          data/ 下，未被覆盖的词，供 AI 补生成
  report.txt         覆盖率报告

用法：
  python build_examples.py            # 建库 + 报告
  python build_examples.py --dry      # 只出报告不写文件
"""
import json
import os
import re
import sys
import zipfile
import collections

ROOT = os.path.dirname(os.path.abspath(__file__))
RAW = os.path.normpath(os.path.join(ROOT, '..', '..', 'Cihui', 'entry', 'src', 'main', 'resources', 'rawfile'))
DATA = os.path.join(ROOT, 'data')
OUT_DIR = os.path.join(RAW, 'examples')

BOOKS = ['zhongkao', 'gaokao', 'cet4', 'cet6', 'kaoyan', 'ielts', 'toefl', 'gre', 'collins', 'oxford3000']

CJK = re.compile(r'[\u4e00-\u9fff]')
LATIN = re.compile(r'[A-Za-z]')
# 英文句子只允许这些字符，出现别的（数字、引号、括号、表情、罕见符号）直接丢
CLEAN_EN = re.compile(r"^[A-Za-z][A-Za-z ,.'\-!?;:]*$")
# 中文译文必须基本是中文（允许标点与少量英文缩写）
BAD_ZH_RATIO = 0.25

# 上架审核红线分两档：
#   HARD 命中即丢（任何情况下不出现），SOFT 只在自己是目标词时放行，
#   否则整句不给别的词用（避免「学 grape 的例句里出现枪」这种连带风险）。
HARD_EN = [
    'fuck', 'shit', 'bitch', 'bastard', 'asshole', 'slut', 'whore', 'nigger', 'nigga', 'retard',
    'porn', 'nude', 'naked', 'rape', 'prostitut', 'condom', 'penis', 'vagina', 'orgasm',
    'masturbat', 'horny', 'nazi', 'hitler', 'terrorist', 'negro',
    'cocaine', 'heroin', 'marijuan', 'methamphet', 'suicide',
]
SOFT_EN = [
    'kill', 'murder', 'corpse', 'gun', 'shoot', 'shot', 'blood', 'stab', 'bomb', 'war', 'weapon',
    'torture', 'drug', 'weed', 'drunk', 'alcohol', 'cigarette', 'smoking', 'sex', 'sexual',
    'breast', 'virgin', 'damn', 'god', 'jesus', 'christ', 'bible', 'church', 'pray', 'religion',
    'muslim', 'islam', 'jew', 'president', 'election', 'vote', 'government', 'politic', 'army',
    'soldier', 'racis', 'slaver', 'slave', 'communis', 'capitalis', 'socialis',
]
# 中文侧只保留真正需要整句回避的词；单字（死/杀/血/性/裸/战）误伤太狠，全部剔除
HARD_ZH = ['强奸', '色情', '裸体', '自杀', '纳粹', '希特勒', '毒品', '吸毒', '妓女', '妈的', '操你']
ZH_FAMILY = {
    '战争': ['war'], '军队': ['army', 'soldier'], '恐怖袭击': ['terrorist'], '炸弹': ['bomb'],
    '枪支': ['gun'], '尸体': ['corpse'], '鲜血': ['blood'], '总统': ['president'],
    '选举': ['election', 'vote'], '政治': ['politic', 'government'], '宗教': ['religion'],
    '上帝': ['god'], '祈祷': ['pray'], '种族歧视': ['racis'], '奴隶': ['slave'],
}
SOFT_ZH = ['战争', '军队', '恐怖袭击', '炸弹', '枪支', '尸体', '鲜血', '总统', '选举', '政治',
           '宗教', '上帝', '祈祷', '种族歧视', '奴隶']

# 常见不规则动词 -> 各种形态，补前缀规则覆盖不到的
IRREGULAR = {
    'be': ['am', 'is', 'are', 'was', 'were', 'been', 'being'],
    'go': ['went', 'gone', 'goes', 'going'],
    'have': ['has', 'had', 'having'],
    'do': ['does', 'did', 'done', 'doing'],
    'say': ['said', 'says'],
    'get': ['got', 'gotten', 'gets', 'getting'],
    'make': ['made', 'makes', 'making'],
    'know': ['knew', 'known', 'knows'],
    'think': ['thought', 'thinks'],
    'take': ['took', 'taken', 'takes', 'taking'],
    'see': ['saw', 'seen', 'sees', 'seeing'],
    'come': ['came', 'comes', 'coming'],
    'give': ['gave', 'given', 'gives', 'giving'],
    'find': ['found', 'finds'],
    'tell': ['told', 'tells'],
    'become': ['became', 'becomes', 'becoming'],
    'leave': ['left', 'leaves', 'leaving'],
    'feel': ['felt', 'feels'],
    'bring': ['brought', 'brings'],
    'begin': ['began', 'begun', 'begins', 'beginning'],
    'keep': ['kept', 'keeps'],
    'hold': ['held', 'holds'],
    'write': ['wrote', 'written', 'writes', 'writing'],
    'stand': ['stood', 'stands'],
    'hear': ['heard', 'hears'],
    'let': ['lets', 'letting'],
    'mean': ['meant', 'means'],
    'set': ['sets', 'setting'],
    'meet': ['met', 'meets', 'meeting'],
    'run': ['ran', 'runs', 'running'],
    'pay': ['paid', 'pays'],
    'sit': ['sat', 'sits', 'sitting'],
    'speak': ['spoke', 'spoken', 'speaks'],
    'lie': ['lay', 'lain', 'lies', 'lying'],
    'lead': ['led', 'leads'],
    'grow': ['grew', 'grown', 'grows'],
    'lose': ['lost', 'loses', 'losing'],
    'fall': ['fell', 'fallen', 'falls'],
    'send': ['sent', 'sends'],
    'build': ['built', 'builds'],
    'understand': ['understood', 'understands'],
    'draw': ['drew', 'drawn', 'draws'],
    'break': ['broke', 'broken', 'breaks'],
    'spend': ['spent', 'spends'],
    'cut': ['cuts', 'cutting'],
    'rise': ['rose', 'risen', 'rises', 'rising'],
    'drive': ['drove', 'driven', 'drives'],
    'buy': ['bought', 'buys'],
    'wear': ['wore', 'worn', 'wears'],
    'choose': ['chose', 'chosen', 'chooses'],
    'eat': ['ate', 'eaten', 'eats', 'eating'],
    'drink': ['drank', 'drunk', 'drinks'],
    'sleep': ['slept', 'sleeps'],
    'teach': ['taught', 'teaches'],
    'catch': ['caught', 'catches'],
    'fight': ['fought', 'fights'],
    'throw': ['threw', 'thrown', 'throws'],
    'sell': ['sold', 'sells'],
    'win': ['won', 'wins', 'winning'],
    'forget': ['forgot', 'forgotten', 'forgets'],
    'hide': ['hid', 'hidden', 'hides'],
    'fly': ['flew', 'flown', 'flies'],
    'become': ['became', 'becomes'],
}

SUFFIXES = ('s', 'es', 'ed', 'd', 'ing', 'er', 'est', 'ly', 'ment', 'ness', 'ion',
            'ation', 'ions', 'ings', 'ers', 'al', 'ful', 'less')


ALIAS = {}


def load_alias():
    """ECDICT 的词形表（wore->wear / griddles->griddle），比后缀规则准得多"""
    global ALIAS
    if ALIAS:
        return ALIAS
    p = os.path.join(RAW, 'dict', 'ecdict-lite.json')
    if os.path.exists(p):
        d = json.load(open(p, encoding='utf-8'))
        for k, v in (d.get('alias') or {}).items():
            k = str(k).strip().lower()
            v = str(v).strip().lower()
            if k and v and k != v:
                ALIAS[k] = v
    return ALIAS


def alias_variants(tok):
    """沿 alias 链向上追原形（最多 3 跳），并带上每一跳的后缀规则候选"""
    out = {tok}
    cur = tok
    for _ in range(3):
        nxt = ALIAS.get(cur)
        if not nxt or nxt in out:
            break
        out.add(nxt)
        cur = nxt
    return out


def token_variants(tok):
    """token -> 可能的原形候选（含自身）"""
    t = tok.lower()
    out = alias_variants(t)
    for suf in ('ies', 'ied', 'ing', 'est', 'ers', 'ed', 'es', 'er', 'ly', 's', 'd'):
        if t.endswith(suf) and len(t) > len(suf) + 2:
            base = t[: -len(suf)]
            out.add(base)
            out.add(base + 'e')
            out.add(base + 'y')
            # 双写辅音还原：stopped -> stop, running -> run
            if len(base) > 2 and base[-1] == base[-2]:
                out.add(base[:-1])
                out.add(base[:-1] + 'e')
    return out


def load_book_words():
    """bookId -> [word]；word -> set(bookId)"""
    book_words = collections.OrderedDict()
    word_books = collections.defaultdict(set)
    for b in BOOKS:
        p = os.path.join(RAW, 'cloudbooks', b + '.json')
        if not os.path.exists(p):
            continue
        d = json.load(open(p, encoding='utf-8'))
        arr = d if isinstance(d, list) else d.get('words', [])
        ws = []
        for x in arr:
            w = x if isinstance(x, str) else (x.get('w') or x.get('english') or '')
            w = w.strip()
            if w:
                ws.append(w)
                word_books[w.lower()].add(b)
        book_words[b] = ws
    return book_words, word_books


def load_tatoeba_pairs():
    pairs = []
    z = os.path.join(DATA, 'cmn-eng.zip')
    if os.path.exists(z):
        raw = zipfile.ZipFile(z).read('cmn.txt').decode('utf-8', 'replace')
        for line in raw.splitlines():
            p = line.split('\t')
            if len(p) >= 2:
                e, c = p[0].strip(), p[1].strip()
                if e and c:
                    pairs.append((e, c))
    extra = os.path.join(DATA, 'pairs.tsv')
    if os.path.exists(extra):
        for line in open(extra, encoding='utf-8'):
            p = line.rstrip('\n').split('\t')
            if len(p) >= 2:
                pairs.append((p[0].strip(), p[1].strip()))
    # 去重（同英文只留第一条，避免同一句多译文）
    seen = set()
    uniq = []
    for e, c in pairs:
        k = e.lower()
        if k in seen:
            continue
        seen.add(k)
        uniq.append((e, c))
    return uniq


def zh_ok(zh):
    if len(zh) < 3:
        return False
    if not CJK.search(zh):
        return False
    letters = len(LATIN.findall(zh))
    if letters / max(len(zh), 1) > BAD_ZH_RATIO:
        return False
    for b in HARD_ZH:
        if b in zh:
            return False
    return True


def zh_soft(zh):
    return {b for b in SOFT_ZH if b in zh}


_INFLECT = r'(s|es|ed|ing|d|er|ers|ly)?'


def _hit(low, b):
    """整词 + 常见屈折后缀匹配，避免 'heroin' 命中 'heroine'、'sex' 命中 'Sussex'"""
    return re.search(r'\b' + re.escape(b) + _INFLECT + r'\b', low) is not None


def sensitive_ok(word, en, zh):
    """目标词自己属于敏感词家族时放行（politics / slavery / gun），否则含敏感词的句子不给它用"""
    bases = set(en_soft(en))
    for z in zh_soft(zh):
        bases |= set(ZH_FAMILY.get(z, ()))
    if not bases:
        return True
    for b in bases:
        if word.startswith(b[:5]) or b.startswith(word[:5]):
            return True
    return False


def same_family(word, soft_hits):
    """word 是否属于命中敏感词的同一词干（politics/politician、slave/slavery）"""
    for b in soft_hits:
        if word.startswith(b[:5]) or b.startswith(word[:5]):
            return True
    return False


def en_ok(en):
    if not CLEAN_EN.match(en):
        return False
    words = en.split()
    if len(words) < 4 or len(words) > 18:
        return False
    low = en.lower()
    for b in HARD_EN:
        if _hit(low, b):
            return False
    return True


def en_soft(en):
    low = en.lower()
    return {b for b in SOFT_EN if _hit(low, b)}


def score(en, exact):
    n = len(en.split())
    # 越接近 8~12 词的完整句子越好；精确原形加分；Tom 句减分（Tatoeba 里太多）
    s = 0.0
    s += 5.0 if 6 <= n <= 14 else 2.0
    s += 3.0 if exact else 0.0
    s -= abs(n - 9) * 0.2
    if en.lower().startswith('tom') or ' tom ' in en.lower():
        s -= 1.0
    return s


def load_ai_pairs():
    """AI 补生成的句子：word \t en \t zh，只用于填 Tatoeba 没覆盖的词"""
    path = os.path.join(DATA, 'ai_pairs.tsv')
    out = []
    if not os.path.exists(path):
        return out
    for line in open(path, encoding='utf-8'):
        f = line.rstrip('\n').split('\t')
        if len(f) >= 3:
            w, en, zh = f[0].strip().lower(), f[1].strip(), f[2].strip()
            if w and en and zh:
                out.append((w, en, zh))
    return out


def build_phrase_index(all_words):
    """短语词条（ice cream / take off）按首词索引，token 命中首词时再核对整条短语"""
    idx = {}
    for w in all_words:
        if ' ' in w:
            idx.setdefault(w.split()[0], []).append(w)
    return idx


def harvest_tatoeba(pairs, best, srcs, all_words, phrases):
    """整句扫描：一条中英句对可能同时命中多个词，取该词的最高分句"""
    import zhconv
    for en, zh in pairs:
        if not en_ok(en):
            continue
        en_soft_hit = en_soft(en)
        low_en = en.lower()
        hit = {}
        for t in re.findall(r"[A-Za-z][A-Za-z'-]*", en):
            tl = t.lower()
            if tl in all_words:
                hit[tl] = True
                continue
            for v in token_variants(tl):
                if v in all_words:
                    hit[v] = False
                    break
            for ph in phrases.get(tl, ()):
                if ph in low_en:
                    hit[ph] = False
        if not hit:
            continue
        zhs = zhconv.convert(zh, 'zh-cn')
        if not zh_ok(zhs):
            continue
        zh_soft_hit = zh_soft(zhs)
        for w, exact in hit.items():
            # 句子含敏感词时只留给敏感词自己用（同性词干算自己，如 politics/politician）
            if (en_soft_hit or zh_soft_hit) and not sensitive_ok(w, en, zhs):
                continue
            sc = score(en, exact)
            old = best.get(w)
            if old is None or sc > old[0]:
                best[w] = (sc, en, zhs, exact)
                srcs[w] = 'tatoeba'


def harvest_ai(ai_pairs, best, srcs):
    """AI 只填 Tatoeba 没覆盖的词（真人语料优先，质量更高）。
    敏感判定与 harvest_tatoeba 同规则：目标词自身属敏感词家族时放行
    （ward 被 war+d 误命中、bomber/shooter/slaver 等同族词要能进）。"""
    n = 0
    for w, en, zh in ai_pairs:
        if w in best:
            continue
        if not en_ok(en) or not zh_ok(zh):
            continue
        if not sensitive_ok(w, en, zh):
            continue
        best[w] = (score(en, True), en, zh, True)
        srcs[w] = 'ai'
        n += 1
    return n


COMMON_TOP = 6000


def build_common(best, pairs, all_words):
    """通用例句包：词书并集里最常用的 COMMON_TOP 个词，给梗句本/自定义词本兜底。
    频次取自 Tatoeba 中英句对（变形经词形表归到原形）。"""
    freq = collections.Counter()
    for en, zh in pairs:
        for t in re.findall(r"[A-Za-z][A-Za-z'-]*", en):
            tl = t.lower()
            if tl in all_words:
                freq[tl] += 1
                continue
            for v in token_variants(tl):
                if v in all_words:
                    freq[v] += 1
                    break
    ranked = [w for w in all_words if w in best and freq.get(w, 0) > 0]
    ranked.sort(key=lambda w: (-freq[w], w))
    picked = ranked[:COMMON_TOP]
    items = [{'w': w, 'e': best[w][1], 'z': best[w][2]} for w in picked]
    payload = {'book': 'common', 'src': 'tatoeba', 'v': 1, 'items': items}
    p = os.path.join(OUT_DIR, 'common.json')
    text = json.dumps(payload, ensure_ascii=False, separators=(',', ':'))
    open(p, 'w', encoding='utf-8', newline='\n').write(text)
    print(f'  {"common":12} {len(items):5} 条  {len(text.encode("utf-8")) / 1024:6.1f} KB')
    return len(text.encode('utf-8'))


def main():
    dry = '--dry' in sys.argv

    load_alias()
    book_words, word_books = load_book_words()
    all_words = set(word_books.keys())
    tatoeba = load_tatoeba_pairs()
    ai_pairs = load_ai_pairs()
    print(f'Tatoeba 句对 {len(tatoeba)} 条，AI 预生成 {len(ai_pairs)} 条，'
          f'词书 {len(book_words)} 本，去重词 {len(all_words)} 个')

    best = {}   # word -> (score, en, zh, exact)
    srcs = {}   # word -> 'tatoeba' | 'ai'
    phrases = build_phrase_index(all_words)
    harvest_tatoeba(tatoeba, best, srcs, all_words, phrases)
    n_ai = harvest_ai(ai_pairs, best, srcs)
    print(f'Tatoeba 覆盖 {len(best) - n_ai} 词，AI 补 {n_ai} 词')

    # 覆盖率
    lines = []
    total_hit = total = 0
    for b, ws in book_words.items():
        uniq = list(dict.fromkeys(w.lower() for w in ws))
        hit = [w for w in uniq if w in best]
        total_hit += len(hit)
        total += len(uniq)
        lines.append(f'{b:12} {len(hit):5}/{len(uniq):5} = {len(hit)/max(len(uniq),1):5.1%}')
    print('\n'.join(lines))
    print(f'{"合计":12} {total_hit:5}/{total:5} = {total_hit/max(total,1):5.1%}')

    gaps = sorted(all_words - set(best.keys()))
    print(f'未覆盖词 {len(gaps)} 个')

    if dry:
        return

    os.makedirs(DATA, exist_ok=True)
    os.makedirs(OUT_DIR, exist_ok=True)
    json.dump(gaps, open(os.path.join(DATA, 'gaps.json'), 'w', encoding='utf-8'),
              ensure_ascii=False, indent=0)
    open(os.path.join(DATA, 'report.txt'), 'w', encoding='utf-8').write('\n'.join(lines) + '\n')

    size_total = 0
    for b, ws in book_words.items():
        items = []
        for w in dict.fromkeys(x.lower() for x in ws):
            if w in best:
                items.append({'w': w, 'e': best[w][1], 'z': best[w][2]})
        payload = {'book': b, 'src': 'tatoeba', 'v': 1, 'items': items}
        p = os.path.join(OUT_DIR, b + '.json')
        s = json.dumps(payload, ensure_ascii=False, separators=(',', ':'))
        open(p, 'w', encoding='utf-8', newline='\n').write(s)
        size_total += len(s.encode('utf-8'))
        print(f'  {b:12} {len(items):5} 条  {len(s.encode("utf-8"))/1024:6.1f} KB')
    size_total += build_common(best, tatoeba, all_words)
    print(f'总计 {size_total/1024/1024:.2f} MB')


if __name__ == '__main__':
    main()

