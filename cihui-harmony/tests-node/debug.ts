import { addBook, emptyData, importTransaction, applyJudgeToData, upsertCheckin, addWord } from '../Cihui/entry/src/main/ets/model/RepoCore.ts';
import { evaluateGates, buildDayPlan } from '../Cihui/entry/src/main/ets/model/SchedulerCore.ts';

function ts(dayOffset: number): number {
  return new Date(2026, 8, 1 + dayOffset, 12, 0, 0).getTime();
}

let d: any = emptyData();
d = addBook(d, { name: '测试本', source: 'DIY_MANUAL' }, ts(0));
const bookId = d.books[0].id;
d = importTransaction(d, [
  { bookId, english: 'one', meanings: ['一'], source: 'MANUAL' },
  { bookId, english: 'two', meanings: ['二'], source: 'MANUAL' },
], ts(0));
console.log('after import schedules:', JSON.stringify(d.schedules, null, 1));
const ids = d.words.map((w: any) => w.id);
d = applyJudgeToData(d, ids[0], 'FIRST', 'KNOWN', ts(0)).data;
d = applyJudgeToData(d, ids[1], 'FIRST', 'KNOWN', ts(0)).data;
console.log('after pass schedules:', JSON.stringify(d.schedules, null, 1));
const g = evaluateGates({ schedules: d.schedules, records: d.records, settings: d.settings }, '2026-09-01');
console.log('gates D0:', JSON.stringify(g));
const plan = buildDayPlan({ schedules: d.schedules, records: d.records, settings: d.settings }, '2026-09-01');
console.log('plan D0:', JSON.stringify(plan));
