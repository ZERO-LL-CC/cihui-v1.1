#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
从 Tatoeba 官方导出（句子 + 链接表）生成中英句对，产出 data/pairs.tsv。

比起 manythings 的 3 万条打包句对，官方链接表能拿到全部「英文句子 ↔ 中文译文」配对，
覆盖率高一大截。代价是要处理 460MB 的 links.csv（流式读，内存只放 id 集合）。

输入：eng_sentences.tsv.bz2 / cmn_sentences.tsv.bz2 / links.tar.bz2
输出：data/pairs.tsv（英文 \\t 中文 \\t 来源句号）
"""
import bz2
import os
import sys
import tarfile

DATA = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'data')


def read_ids(path):
    ids = set()
    with bz2.open(path, 'rt', encoding='utf-8', errors='replace') as f:
        for line in f:
            i = line.find('\t')
            if i > 0:
                ids.add(int(line[:i]))
    return ids


def read_texts(path, want=None):
    out = {}
    with bz2.open(path, 'rt', encoding='utf-8', errors='replace') as f:
        for line in f:
            p = line.rstrip('\n').split('\t', 2)
            if len(p) < 3:
                continue
            try:
                sid = int(p[0])
            except ValueError:
                continue
            if want is not None and sid not in want:
                continue
            out[sid] = p[2]
    return out


def main():
    t0 = 0
    print('1/4 读英文句号…')
    eng_ids = read_ids(os.path.join(DATA, 'eng_sentences.tsv.bz2'))
    print(f'    英文句子 {len(eng_ids)}')
    print('2/4 读中文句子…')
    cmn = read_texts(os.path.join(DATA, 'cmn_sentences.tsv.bz2'))
    print(f'    中文句子 {len(cmn)}')

    print('3/4 扫链接表（460MB，约 2~4 分钟）…')
    pairs = []
    n = 0
    tar = tarfile.open(os.path.join(DATA, 'links.tar.bz2'), 'r:bz2')
    f = tar.extractfile(tar.getmembers()[0])
    for line in f:
        n += 1
        i = line.find(b'\t')
        if i < 0:
            continue
        try:
            a = int(line[:i])
            b = int(line[i + 1:].strip())
        except ValueError:
            continue
        # 一条链接两端可能是任意语言，只留「英文 ↔ 中文」这一种
        if a in eng_ids and b in cmn:
            pairs.append((a, b))
        elif b in eng_ids and a in cmn:
            pairs.append((b, a))
        if n % 5000000 == 0:
            print(f'    已扫 {n // 1000000}M 行，命中 {len(pairs)} 对')
    print(f'    链接 {n} 行，中英配对 {len(pairs)} 对')

    print('4/4 取英文原文…')
    need = set(a for a, _ in pairs)
    eng = read_texts(os.path.join(DATA, 'eng_sentences.tsv.bz2'), want=need)
    del eng_ids

    out = os.path.join(DATA, 'pairs.tsv')
    kept = 0
    with open(out, 'w', encoding='utf-8', newline='\n') as w:
        for a, b in pairs:
            e = eng.get(a)
            z = cmn.get(b)
            if not e or not z:
                continue
            w.write(f'{e}\t{z}\t{a}-{b}\n')
            kept += 1
    print(f'写出 {kept} 条到 {out}')
    t0 = os.path.getsize(out)
    print(f'文件 {t0 / 1024 / 1024:.1f} MB')


if __name__ == '__main__':
    main()
