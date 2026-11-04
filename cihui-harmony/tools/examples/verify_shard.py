#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
校验一个 AI 分片：data/shards/gen_XX.tsv 是否把 in_XX.tsv 里的词全写齐、且过质量闸门。

用法：
  python verify_shard.py 00            # 只报告
  python verify_shard.py 00 --strict   # 有不合格就以非 0 退出（给 agent 自检用）
"""
import importlib.util
import os
import re
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location('be', os.path.join(ROOT, 'build_examples.py'))
be = importlib.util.module_from_spec(spec)
spec.loader.exec_module(be)


def load_lines(path):
    out = []
    if not os.path.exists(path):
        return out
    for line in open(path, encoding='utf-8-sig'):
        f = line.rstrip('\n').split('\t')
        if len(f) >= 3 and f[0].strip():
            out.append((f[0].strip().lower(), f[1].strip(), f[2].strip()))
    return out


def check(word, en, zh):
    if not en or not zh:
        return '空行'
    if not be.CLEAN_EN.match(en):
        return '英文含非法字符'
    n = len(en.split())
    if n < 6 or n > 16:
        return f'英文 {n} 词（要 6~16）'
    if not be.en_ok(en):
        return '英文命中硬禁词'
    if not be.zh_ok(zh):
        return '中文不合格（疑似非中文/含硬禁词）'
    soft = be.en_soft(en) | set(be.zh_soft(zh))
    if soft and not be.sensitive_ok(word, en, zh):
        return '含敏感词：' + '/'.join(sorted(soft))
    # 目标词必须真出现
    low = en.lower()
    if ' ' in word:
        if word not in low:
            return '句中没有该短语'
    else:
        toks = re.findall(r"[A-Za-z][A-Za-z'-]*", low)
        ok = False
        for t in toks:
            tl = t.lower()
            if tl == word or word in be.token_variants(tl):
                ok = True
                break
        if not ok:
            return '句中没有该词'
    return ''


def main():
    if len(sys.argv) < 2:
        print('用法: python verify_shard.py 00 [--strict]')
        return 2
    tag = sys.argv[1].zfill(2)
    strict = '--strict' in sys.argv
    inp = os.path.join(ROOT, 'data', 'shards', f'in_{tag}.tsv')
    words = [l.split('\t')[0].strip().lower() for l in open(inp, encoding='utf-8-sig') if l.strip()]
    # 允许分批写入：gen_XX.tsv / gen_XX_a.tsv / gen_XX_b.tsv ...
    gen_dir = os.path.join(ROOT, 'data', 'shards')
    rows = []
    for fn in sorted(os.listdir(gen_dir)):
        if fn == f'gen_{tag}.tsv' or (fn.startswith(f'gen_{tag}_') and fn.endswith('.tsv')):
            rows.extend(load_lines(os.path.join(gen_dir, fn)))
    got = {}
    dup = 0
    for w, en, zh in rows:
        if w in got:
            dup += 1
        got[w] = (en, zh)

    problems = []
    missing = []
    for w in words:
        if w not in got:
            missing.append(w)
            continue
        msg = check(w, *got[w])
        if msg:
            problems.append((w, msg))

    done = len(words) - len(missing)
    print(f'分片 {tag}：目标 {len(words)}，已写 {done}，缺失 {len(missing)}，'
          f'不合格 {len(problems)}，重复 {dup}')
    ok = len(words) - len(missing) - len(problems)
    print(f'合格 {ok}/{len(words)} = {ok / max(len(words), 1):.1%}')
    if problems[:20]:
        print('--- 不合格样例 ---')
        for w, m in problems[:20]:
            print(f'  {w}\t{m}\t{got[w][0]}')
    if missing[:20]:
        print('--- 缺失样例 ---')
        print('  ' + ' '.join(missing[:20]))
    if strict and (missing or problems):
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
