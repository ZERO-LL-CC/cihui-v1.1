# -*- coding: utf-8 -*-
"""Generate the compact offline English->Chinese dictionary from ECDICT (MIT).

v2 (F17 修复「卡片背面没有中文」):
  1) 排序口径改对: 非考纲词按真实词频排名 (BNC/COCA rank, 越小越常用) 升序保留，
     无频次数据的词排最后。v1 把「无频次数据」当成最高频，把 utterly / embarrassment
     这类真实常用词挤出了 CAP，却塞进一堆没人用的冷僻词。
  2) 新增 alias 词形索引: 解析 ECDICT 的 exchange 字段 (p 过去式 / d 过去分词 /
     i 现在分词 / 3 三单 / r 比较级 / t 最高级 / s 复数)，把派生形映射到原形。
     这样 shattered / gets / executed / done / hooked 都能查到 shatter / get ...
     的释义，而包体只多约 0.9MB (不用给每个变形单独存一份释义)。

Input : _ecdict/ecdict.csv + rawfile/cloudbooks/{cet4,cet6,kaoyan,gaokao,zhongkao}.json
Output: rawfile/dict/ecdict-lite.json
        {"words":[{"w","p","m"}...],"alias":{"shattered":"shatter",...}}
"""
import csv
import io
import json
import os
import re
import sys

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')

CSV = r'F:\PORJECT\cihui-harmony\_ecdict\ecdict.csv'
RAW_DIR = r'F:\PORJECT\cihui-harmony\Cihui\entry\src\main\resources\rawfile'
CLOUD_DIR = os.path.join(RAW_DIR, 'cloudbooks')
OUT = os.path.join(RAW_DIR, 'dict', 'ecdict-lite.json')
CLOUD_BOOKS = ['cet4', 'cet6', 'kaoyan', 'gaokao', 'zhongkao']
EXAM = {'zk', 'gk', 'cet4', 'cet6', 'ky'}
# 36000 原形 + 约 2.8 万条词形别名 ≈ 3.5MB，覆盖全部考纲词与梗句引擎实际产出的词
CAP = 36000
# 词条只收单个 token (允许内部连字符/撇号)；带空格的短语永远匹配不到拆词结果，白占体积
WORD_RE = re.compile(r"^[a-zA-Z][a-zA-Z'\-]{0,32}$")
# ECDICT exchange 里表示「变形」的键；0=原形 1=变形类别，不需要
FORM_KEYS = ('p', 'd', 'i', '3', 'r', 't', 's')
BIG = 10 ** 9


def clean_meaning(trans):
    raw = (trans or '').replace('\r', '\n').replace('\\r', '\n').replace('\\n', '\n')
    parts = [p.strip() for p in raw.split('\n') if p.strip()]
    if not parts:
        return ''
    m = '；'.join(parts)
    m = m.replace('/', '；')
    return m[:120]


def rank_of(v):
    """BNC/COCA 名次；缺失或非正数视为未知（排最后）"""
    s = (v or '').strip()
    if s.isdigit() and int(s) > 0:
        return int(s)
    return BIG


def to_int(v, default=0):
    s = (v or '').strip()
    return int(s) if s.isdigit() else default


def parse_forms(exchange):
    """从 exchange 解析派生词形（去重、保留小写、丢非法 token）"""
    out = []
    for seg in (exchange or '').split('/'):
        key, _, val = seg.partition(':')
        if key not in FORM_KEYS:
            continue
        for piece in val.replace('|', ',').split(','):
            w = piece.strip().lower()
            if w and w not in out and WORD_RE.match(w) and len(w) >= 2:
                out.append(w)
    return out


def load_cloud_books():
    """五本考纲云书：权威释义，音标已带斜杠"""
    cloud = {}
    for bid in CLOUD_BOOKS:
        path = os.path.join(CLOUD_DIR, bid + '.json')
        if not os.path.exists(path):
            continue
        with open(path, encoding='utf-8') as f:
            data = json.load(f)
        for it in data.get('words', []):
            w = (it.get('w') or '').strip()
            m = (it.get('m') or '').strip()
            if not w or not m:
                continue
            k = w.lower()
            if k not in cloud:
                cloud[k] = (w, (it.get('p') or '').strip(), m)
    return cloud


def main():
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    cloud = load_cloud_books()

    # key -> dict(is_exam, rank, neg_collins, word, phonetic, meaning)
    best = {}
    for k, (w, ph, m) in cloud.items():
        best[k] = {'exam': True, 'rank': BIG, 'col': 0, 'w': w, 'p': ph, 'm': m}

    forms = {}   # 原形 key -> [派生形]（含未入库的原形，后面按需取用）
    with open(CSV, encoding='utf-8') as f:
        for row in csv.DictReader(f):
            word = (row.get('word') or '').strip()
            trans = (row.get('translation') or '').strip()
            if not WORD_RE.match(word) or len(word) < 2 or not trans:
                continue
            meaning = clean_meaning(trans)
            if not meaning:
                continue
            k = word.lower()
            phon = (row.get('phonetic') or '').strip()
            collins = to_int(row.get('collins'))
            oxford = (row.get('oxford') or '').strip()
            rk = min(rank_of(row.get('bnc')), rank_of(row.get('frq')))
            is_exam = bool(set((row.get('tag') or '').split()) & EXAM)
            if k not in best and (is_exam or collins >= 1 or oxford == '1' or rk < BIG):
                best[k] = {
                    'exam': is_exam,
                    'rank': rk,
                    'col': collins,
                    'w': word,
                    'p': ('/' + phon + '/') if phon else '',
                    'm': meaning,
                }
            forms.setdefault(k, []).extend(parse_forms(row.get('exchange')))

    items = list(best.values())
    # 考纲词无条件保留；其余按真实词频升序（同频次时柯林斯星级高的优先）
    exam_items = sorted([x for x in items if x['exam']], key=lambda x: x['w'].lower())
    other = sorted([x for x in items if not x['exam']], key=lambda x: (x['rank'], -x['col']))
    keep = exam_items + other[:max(0, CAP - len(exam_items))]
    keys = set(x['w'].lower() for x in keep)

    # 词形索引：派生形 -> 原形，只收「原形已入库、派生形自己没入库」的
    alias = {}
    for base in keys:
        for v in forms.get(base, []):
            if v not in keys and v not in alias:
                alias[v] = base

    words = [{'w': x['w'], 'p': x['p'], 'm': x['m']} for x in keep]
    with open(OUT, 'w', encoding='utf-8') as fo:
        json.dump({'words': words, 'alias': alias}, fo,
                  ensure_ascii=False, separators=(',', ':'))
    size = os.path.getsize(OUT)
    print('cloud=%d exam=%d other_pool=%d kept=%d alias=%d'
          % (len(cloud), len(exam_items), len(other), len(words), len(alias)))
    print('out=%s bytes=%d (%.2f MB)' % (OUT, size, size / 1048576.0))

    # 自检：梗句引擎最容易漏的那些变形
    checks = ['shattered', 'utterly', 'gets', 'executed', 'greatest', 'overheated',
              'embarrassment', 'defenses', 'done', 'nailed', 'hooked', 'moving',
              'boiled', 'crashing', 'dying', 'fried', 'broken']
    bad = [c for c in checks if c not in keys and c not in alias]
    print('self-check miss:', bad if bad else 'NONE')


if __name__ == '__main__':
    main()
