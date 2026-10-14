# -*- coding: utf-8 -*-
import csv, sys, io, collections
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')
path = r'F:\PORJECT\cihui-harmony\_ecdict\ecdict.csv'
tags_count = collections.Counter()
n = 0
sample = {}
with open(path, encoding='utf-8') as f:
    r = csv.DictReader(f)
    for row in r:
        n += 1
        t = (row.get('tag') or '').strip()
        if t:
            for x in t.split(' '):
                x = x.strip()
                if x:
                    tags_count[x] += 1
                    if x not in sample:
                        sample[x] = row['word']
print('rows:', n)
for t, c in tags_count.most_common(40):
    print(t, c, sample.get(t))
