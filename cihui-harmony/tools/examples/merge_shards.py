#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
把 data/shards/gen_*.tsv 合并进 data/ai_pairs.tsv（去重、过质量闸门）。

用法：
  python merge_shards.py           # 合并并报告
  python merge_shards.py --dry     # 只看能收多少条
"""
import glob
import importlib.util
import os
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location('be', os.path.join(ROOT, 'build_examples.py'))
be = importlib.util.module_from_spec(spec)
spec.loader.exec_module(be)
spec2 = importlib.util.spec_from_file_location('vs', os.path.join(ROOT, 'verify_shard.py'))
vs = importlib.util.module_from_spec(spec2)
spec2.loader.exec_module(vs)


def main():
    dry = '--dry' in sys.argv
    out = os.path.join(ROOT, 'data', 'ai_pairs.tsv')
    done = {}
    if os.path.exists(out):
        for line in open(out, encoding='utf-8-sig'):
            f = line.rstrip('\n').split('\t')
            if len(f) >= 3 and f[0].strip():
                done[f[0].strip().lower()] = (f[1], f[2])

    added = bad = dup = 0
    files = sorted(glob.glob(os.path.join(ROOT, 'data', 'shards', 'gen_*.tsv')))
    for p in files:
        for w, en, zh in vs.load_lines(p):
            if w in done:
                dup += 1
                continue
            if vs.check(w, en, zh):
                bad += 1
                continue
            done[w] = (en, zh)
            added += 1
    print(f'分片文件 {len(files)} 个，新增 {added} 条，跳过重复 {dup}，不合格 {bad}，累计 {len(done)} 条')
    if dry:
        return
    with open(out, 'w', encoding='utf-8', newline='\n') as f:
        for w, (en, zh) in done.items():
            f.write(f'{w}\t{en}\t{zh}\n')
    print(f'已写入 {out}')


if __name__ == '__main__':
    main()
