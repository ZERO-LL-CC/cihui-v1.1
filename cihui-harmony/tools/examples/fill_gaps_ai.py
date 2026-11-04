#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
给 Tatoeba 没覆盖到的词补例句（一次性，跑完就不要再调）。

产出 data/ai_pairs.tsv（词 \t 英文 \t 中文），build_examples.py 会把它当兜底源合并。
所有输出都会再过一遍与 Tatoeba 相同的质量闸门（长度 / 字符 / 敏感词 / 是否真含该词）。

用法：
  python fill_gaps_ai.py --key ark-xxx --limit 40          # 先小批试跑，看质量和速度
  python fill_gaps_ai.py --key ark-xxx                     # 全量补齐（可中断，重跑续跑）
  python fill_gaps_ai.py --key ark-xxx --books cet4,cet6   # 只补指定词书缺的词
"""
import argparse
import json
import os
import queue
import re
import sys
import threading
import time
import urllib.request

ROOT = os.path.dirname(os.path.abspath(__file__))
RAW = os.path.normpath(os.path.join(ROOT, '..', '..', 'Cihui', 'entry', 'src', 'main', 'resources', 'rawfile'))
DATA = os.path.join(ROOT, 'data')

ENDPOINT = 'https://ark.cn-beijing.volces.com/api/v3/chat/completions'
MODEL = 'doubao-seed-2-0-lite-260428'

CJK = re.compile(r'[\u4e00-\u9fff]')
LATIN = re.compile(r'[A-Za-z]')
CLEAN_EN = re.compile(r"^[A-Za-z][A-Za-z ,.'\-!?;:]*$")

BAN_EN = ['fuck', 'shit', 'bitch', 'damn', 'sex', 'porn', 'rape', 'kill', 'murder', 'suicide',
          'gun', 'blood', 'drug', 'drunk', 'god', 'jesus', 'church', 'war', 'army', 'nazi',
          'politic', 'government', 'president', 'religion', 'slave', 'racis', 'naked']
BAN_ZH = ['杀', '死', '自杀', '枪', '血', '尸', '强奸', '性', '裸', '妓', '毒品', '吸毒', '醉',
          '战', '军队', '恐怖', '炸', '总统', '选举', '政府', '政治', '宗教', '上帝', '教堂',
          '纳粹', '希特勒', '种族', '奴隶', '屁', '屎', '妈的', '操']

PROMPT = """你是英语学习词典的例句编写员。为下面每个单词各写 1 条英文例句和中文翻译。

要求：
1. 例句 6~14 个单词，语法完整、自然地道，接近日常英语，不要文言和诗歌。
2. 例句必须出现该单词（可变形：时态、复数、比较级），并且用的是给定的那个义项。
3. 句子难度贴近中国大学英语四级，不要用生僻词堆砌，不要出现人名 Tom/Smith 之类。
4. 内容中性安全：不涉及政治、宗教、暴力、性、死亡、毒品、种族。
5. 中文翻译要通顺，不要直译腔，不要加解释性括号。
6. 只输出 JSON 数组，不要任何解释、不要 markdown 代码块。

输出格式（严格）：
[{"w":"单词","e":"English sentence.","z":"中文翻译。"}]

单词与义项：
%s
"""


def http_post(key, payload, timeout=90):
    body = json.dumps(payload).encode('utf-8')
    req = urllib.request.Request(ENDPOINT, data=body, method='POST')
    req.add_header('Content-Type', 'application/json')
    req.add_header('Authorization', 'Bearer ' + key)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode('utf-8'))


def parse_content(text):
    t = text.strip()
    if t.startswith('```'):
        t = re.sub(r'^```[a-zA-Z]*\n?', '', t)
        t = re.sub(r'\n?```$', '', t)
    l = t.find('[')
    r = t.rfind(']')
    if l < 0 or r <= l:
        return []
    try:
        arr = json.loads(t[l:r + 1])
    except Exception:
        return []
    return arr if isinstance(arr, list) else []


def token_variants(tok):
    t = tok.lower()
    out = {t}
    for suf in ('ies', 'ied', 'ing', 'est', 'ers', 'ed', 'es', 'er', 'ly', 's', 'd'):
        if t.endswith(suf) and len(t) > len(suf) + 2:
            base = t[: -len(suf)]
            out.add(base)
            out.add(base + 'e')
            out.add(base + 'y')
            if len(base) > 2 and base[-1] == base[-2]:
                out.add(base[:-1])
    return out


def word_err_hint(ex):
    msg = str(ex)[:120]
    return '  请求异常：' + msg


def accept(word, en, zh):
    """与 build_examples.py 同口径的质量闸门"""
    if not en or not zh:
        return False
    en, zh = en.strip(), zh.strip()
    if not CLEAN_EN.match(en):
        return False
    n = len(en.split())
    if n < 5 or n > 16:
        return False
    low = en.lower()
    for b in BAN_EN:
        if b in low:
            return False
    if not CJK.search(zh) or len(zh) < 4:
        return False
    letters = len(LATIN.findall(zh))
    if letters / max(len(zh), 1) > 0.25:
        return False
    for b in BAN_ZH:
        if b in zh:
            return False
    # 必须真的含这个词（允许变形）
    toks = re.findall(r"[A-Za-z][A-Za-z'-]*", low)
    ok = False
    for t in toks:
        if t == word or word in token_variants(t):
            ok = True
            break
    return ok


def load_meanings():
    """词 -> 中文释义（给模型看义项，避免写错意思）"""
    p = os.path.join(RAW, 'dict', 'ecdict-lite.json')
    d = json.load(open(p, encoding='utf-8'))
    m = {}
    for it in d.get('words', []):
        m[it['w'].strip().lower()] = it['m']
    return m


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--key', required=True)
    ap.add_argument('--workers', type=int, default=4)
    ap.add_argument('--batch', type=int, default=8)
    ap.add_argument('--limit', type=int, default=0)
    ap.add_argument('--books', default='')
    args = ap.parse_args()

    gaps = json.load(open(os.path.join(DATA, 'gaps.json'), encoding='utf-8'))
    if args.books:
        want = set()
        for b in args.books.split(','):
            p = os.path.join(RAW, 'cloudbooks', b.strip() + '.json')
            if os.path.exists(p):
                d = json.load(open(p, encoding='utf-8'))
                arr = d if isinstance(d, list) else d.get('words', [])
                for x in arr:
                    w = x if isinstance(x, str) else (x.get('w') or '')
                    if w:
                        want.add(w.strip().lower())
        gaps = [w for w in gaps if w in want]

    out_path = os.path.join(DATA, 'ai_pairs.tsv')
    done = {}
    if os.path.exists(out_path):
        for line in open(out_path, encoding='utf-8'):
            p = line.rstrip('\n').split('\t')
            if len(p) >= 3:
                done[p[0]] = True
    # 按词书优先级排：主力词书先补，冷门词书（GRE/柯林斯）最后，跑不完也不影响大多数人
    PRIORITY = ['zhongkao', 'gaokao', 'cet4', 'cet6', 'oxford3000', 'kaoyan', 'ielts', 'toefl', 'gre', 'collins']
    rank = {}
    for i, b in enumerate(PRIORITY):
        bp = os.path.join(RAW, 'cloudbooks', b + '.json')
        if not os.path.exists(bp):
            continue
        bd = json.load(open(bp, encoding='utf-8'))
        arr = bd if isinstance(bd, list) else bd.get('words', [])
        for x in arr:
            w = x if isinstance(x, str) else (x.get('w') or '')
            w = w.strip().lower()
            if w and w not in rank:
                rank[w] = i
    gaps = sorted(gaps, key=lambda w: (rank.get(w, 99), w))
    todo = [w for w in gaps if w not in done]
    if args.limit:
        todo = todo[:args.limit]
    print(f'待补 {len(todo)} 词（已有 {len(done)}），并发 {args.workers}，每批 {args.batch}')

    meanings = load_meanings()
    q = queue.Queue()
    for i in range(0, len(todo), args.batch):
        q.put(todo[i:i + args.batch])

    lock = threading.Lock()
    stat = {'ok': 0, 'bad': 0, 'fail': 0, 'err': 0}
    t0 = time.time()

    def worker():
        while True:
            try:
                chunk = q.get_nowait()
            except queue.Empty:
                return
            lines = []
            for w in chunk:
                m = meanings.get(w, '')
                m = m.split('；')[0][:60] if m else ''
                lines.append(f'- {w}：{m}')
            prompt = PROMPT % '\n'.join(lines)
            rows = []
            for attempt in range(3):
                try:
                    resp = http_post(args.key, {
                        'model': MODEL,
                        'messages': [{'role': 'user', 'content': prompt}],
                        'temperature': 0.6,
                    })
                    content = resp['choices'][0]['message']['content']
                    rows = parse_content(content)
                    if rows:
                        break
                except Exception as ex:
                    with lock:
                        stat['err'] += 1
                    if stat['err'] <= 3:
                        print(f'  {word_err_hint(ex)}')
                    time.sleep(2 + attempt * 3)
            got = {}
            for r in rows:
                if not isinstance(r, dict):
                    continue
                w = str(r.get('w', '')).strip().lower()
                e = str(r.get('e', '')).strip()
                z = str(r.get('z', '')).strip()
                if w in chunk and w not in got:
                    got[w] = (e, z)
            for w in chunk:
                if w not in got:
                    with lock:
                        stat['fail'] += 1
                    continue
                e, z = got[w]
                if accept(w, e, z):
                    lines_out = f'{w}\t{e}\t{z}\n'
                    with lock:
                        with open(out_path, 'a', encoding='utf-8') as f:
                            f.write(lines_out)
                        stat['ok'] += 1
                else:
                    with lock:
                        stat['bad'] += 1
            q.task_done()

    ths = [threading.Thread(target=worker, daemon=True) for _ in range(args.workers)]
    for t in ths:
        t.start()
    last = 0
    while any(t.is_alive() for t in ths):
        time.sleep(5)
        now = stat['ok'] + stat['bad'] + stat['fail']
        if now != last:
            last = now
            el = time.time() - t0
            speed = now / max(el, 1)
            print(f'  进度 {now}/{len(todo)}  成功 {stat["ok"]} 不合格 {stat["bad"]} 失败 {stat["fail"]}'
                  f'  {speed:.2f} 词/秒  HTTP异常 {stat["err"]}  预计剩 {int((len(todo)-now)/max(speed,0.01))} 秒')
    print(f'完成：成功 {stat["ok"]}，不合格 {stat["bad"]}，失败 {stat["fail"]}，耗时 {int(time.time()-t0)} 秒')


if __name__ == '__main__':
    main()
