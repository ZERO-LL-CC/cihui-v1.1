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

# 上架审核红线：涉政 / 涉黄 / 暴力 / 毒品 / 脏话 / 宗教敏感，命中即丢
BLACKLIST = [
    # 脏话与侮辱
    'fuck', 'fucking', 'shit', 'bitch', 'bastard', 'damn', 'asshole', 'crap', 'slut', 'whore',
    'nigger', 'nigga', 'retard', 'idiot', 'stupid', 'moron', 'dumb',
    # 性
    'sex', 'sexual', 'porn', 'naked', 'nude', 'rape', 'prostitute', 'condom', 'penis', 'vagina',
    'breast', 'orgasm', 'masturbat', 'horny', 'virgin',
    # 暴力与死亡
    'kill', 'killed', 'killing', 'murder', 'murdered', 'suicide', 'corpse', 'gun', 'shoot', 'shot',
    'blood', 'stab', 'bomb', 'terrorist', 'war', 'weapon', 'torture',
    # 毒品与酒精滥用
    'drug', 'cocaine', 'heroin', 'marijuana', 'weed', 'drunk', 'alcohol', 'cigarette', 'smoking',
    # 政治与宗教敏感
    'god', 'jesus', 'christ', 'bible', 'church', 'pray', 'religion', 'muslim', 'islam', 'jew',
    'communis', 'capitalis', 'socialis', 'president', 'election', 'vote', 'government', 'politic',
    'war', 'army', 'soldier', 'nazi', 'hitler', 'racis', 'slavery', 'slave',
    # 缩写与专名噪声
    'ok', 'okay', 'hi', 'hello', 'yeah', 'wow', 'oh', 'ah', 'uh', 'hmm',
]
BLACKLIST_ZH = [
    '杀', '死', '自杀', '枪', '血', '尸', '强奸', '性', '裸', '妓', '毒品', '吸毒', '醉',
    '战', '军队', '恐怖', '炸', '总统', '选举', '投票', '政府', '政治', '宗教', '上帝', '教堂',
    '祈祷', '纳粹', '希特勒', '种族', '奴隶', '屁', '屎', '妈的', '操',
]

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


def token_variants(tok):
    """token -> 可能的原形候选（含自身）"""
    t = tok.lower()
    out = {t}
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
    for b in BLACKLIST_ZH:
        if b in zh:
            return False
    return True


def en_ok(en):
    if not CLEAN_EN.match(en):
        return False
    words = en.split()
    if len(words) < 4 or len(words) > 18:
        return False
    low = en.lower()
    for b in BLACKLIST:
        if len(b) <= 3:
            # 短词要求整词命中，避免 "shot" 命中 "photoshoot"、'ok' 命中 'look'
            if re.search(r'\b' + re.escape(b) + r'\b', low):
                return False
        elif b in low:
            return False
    return True


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


def harvest_tatoeba(pairs, best, srcs, all_words):
    """整句扫描：一条中英句对可能同时命中多个词，取该词的最高分句"""
    import zhconv
    for en, zh in pairs:
        if not en_ok(en):
            continue
        hit = {}
        for t in re.findall(r"[A-Za-z][A-Za-z'-]*", en):
            if t.lower() in all_words:
                hit[t.lower()] = True
                continue
            for v in token_variants(t):
                if v in all_words:
                    hit[v] = False
                    break
        if not hit:
            continue
        zhs = zhconv.convert(zh, 'zh-cn')
        if not zh_ok(zhs):
            continue
        for w, exact in hit.items():
            sc = score(en, exact)
            old = best.get(w)
            if old is None or sc > old[0]:
                best[w] = (sc, en, zhs, exact)
                srcs[w] = 'tatoeba'


def harvest_ai(ai_pairs, best, srcs):
    """AI 只填 Tatoeba 没覆盖的词（真人语料优先，质量更高）"""
    n = 0
    for w, en, zh in ai_pairs:
        if w in best:
            continue
        if not en_ok(en) or not zh_ok(zh):
            continue
        best[w] = (score(en, True), en, zh, True)
        srcs[w] = 'ai'
        n += 1
    return n


def main():
    dry = '--dry' in sys.argv

    book_words, word_books = load_book_words()
    all_words = set(word_books.keys())
    tatoeba = load_tatoeba_pairs()
    ai_pairs = load_ai_pairs()
    print(f'Tatoeba 句对 {len(tatoeba)} 条，AI 预生成 {len(ai_pairs)} 条，'
          f'词书 {len(book_words)} 本，去重词 {len(all_words)} 个')

    best = {}   # word -> (score, en, zh, exact)
    srcs = {}   # word -> 'tatoeba' | 'ai'
    harvest_tatoeba(tatoeba, best, srcs, all_words)
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
    print(f'总计 {size_total/1024/1024:.2f} MB')


if __name__ == '__main__':
    main()

