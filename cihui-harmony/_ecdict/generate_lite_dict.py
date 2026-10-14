# -*- coding: utf-8 -*-
"""Generate a compact offline English->Chinese dictionary from ECDICT (MIT).

Used by the OCR word-bubble picker (#25): after OCR splits the photo into single
English words, this dictionary fills phonetic + Chinese meaning offline.

Sources (deterministic):
  1) the five bundled cloud books (cet4/cet6/kaoyan/gaokao/zhongkao) -> full exam
     syllabus words with Chinese, merged & de-duplicated;
  2) ECDICT high-frequency words (collins>=1, oxford=1, BNC/COCA rank <= FREQ_CAP).
Output: rawfile/dict/ecdict-lite.json -> {"words":[{"w","p","m"}]} (same shape as cloud books).
"""
import csv, json, io, os, sys, re

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')

CSV = r'F:\PORJECT\cihui-harmony\_ecdict\ecdict.csv'
RAW_DIR = r'F:\PORJECT\cihui-harmony\Cihui\entry\src\main\resources\rawfile'
CLOUD_DIR = os.path.join(RAW_DIR, 'cloudbooks')
OUT = os.path.join(RAW_DIR, 'dict', 'ecdict-lite.json')
CLOUD_BOOKS = ['cet4', 'cet6', 'kaoyan', 'gaokao', 'zhongkao']
EXAM = {'zk', 'gk', 'cet4', 'cet6', 'ky'}
FREQ_CAP = 8000
CAP = 36000
WORD_RE = re.compile(r"^[a-zA-Z][a-zA-Z'\- ]{0,32}$")


def clean_meaning(trans):
    raw = (trans or '').replace('\r', '\n').replace('\\r', '\n').replace('\\n', '\n')
    parts = [p.strip() for p in raw.split('\n') if p.strip()]
    if not parts:
        return ''
    m = '；'.join(parts)
    m = m.replace('/', '；')
    return m[:120]


def to_int(v):
    s = (v or '').strip()
    return int(s) if s.isdigit() else 999999


def main():
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    # key=lower word -> (score, is_exam, word, phonetic_with_slashes, meaning)
    best = {}

    # 1) bundled exam cloud books (authoritative, already cleaned, phonetic has slashes)
    from_cloud = 0
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
            if k not in best:
                best[k] = (1000000, True, w, (it.get('p') or '').strip(), m)
                from_cloud += 1

    # 2) ECDICT: fill exam gaps (safety net) + high-frequency words
    exam_extra = 0
    with open(CSV, encoding='utf-8') as f:
        r = csv.DictReader(f)
        for row in r:
            tags = set((row.get('tag') or '').split())
            word = (row.get('word') or '').strip()
            trans = (row.get('translation') or '').strip()
            if not WORD_RE.match(word) or len(word) < 2 or not trans:
                continue
            meaning = clean_meaning(trans)
            if not meaning:
                continue
            k = word.lower()
            collins = to_int(row.get('collins'))
            oxford = to_int(row.get('oxford'))
            bnc = to_int(row.get('bnc'))
            frq = to_int(row.get('frq'))
            is_exam = len(tags & EXAM) > 0
            high_freq = collins >= 1 or oxford == 1 or bnc <= FREQ_CAP or frq <= FREQ_CAP
            if k in best:
                continue
            if is_exam:
                best[k] = (1000000, True, word, ('/' + row.get('phonetic', '').strip() + '/') if row.get('phonetic', '').strip() else '', meaning)
                exam_extra += 1
            elif high_freq:
                score = collins * 1000 + oxford * 300 + max(0, FREQ_CAP - min(bnc, frq))
                best[k] = (score, False, word, ('/' + row.get('phonetic', '').strip() + '/') if row.get('phonetic', '').strip() else '', meaning)

    items = sorted(best.values(), key=lambda x: -x[0])
    exam_items = [x for x in items if x[1]]
    other = [x for x in items if not x[1]]
    keep = exam_items + other[:max(0, CAP - len(exam_items))]
    words = [{'w': w, 'p': ph, 'm': m} for _s, _e, w, ph, m in keep]
    with open(OUT, 'w', encoding='utf-8') as fo:
        json.dump({'words': words}, fo, ensure_ascii=False, separators=(',', ':'))
    size = os.path.getsize(OUT)
    print('cloud_exam=%d exam_extra=%d high_freq_pool=%d kept=%d'
          % (from_cloud, exam_extra, len(other), len(words)))
    print('out=%s bytes=%d (%.2f MB)' % (OUT, size, size / 1048576.0))


if __name__ == '__main__':
    main()
