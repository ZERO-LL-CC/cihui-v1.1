import { emptyData, importCloudBook } from '../Cihui/entry/src/main/ets/model/RepoCore.ts';
import { buildProfileStats } from '../Cihui/entry/src/main/ets/model/SchedulerCore.ts';

const samples = [];
for (let i = 0; i < 12; i++) {
  samples.push({ english: 'w' + i, phonetic: '/w/', meaning: 'm' + i });
}
let d = emptyData();
d = importCloudBook(d, { name: 'CET4', cloudBookId: 'c4', words: samples }, Date.now());
console.log('words', d.words.length, 'schedules', d.schedules.length);
const s = buildProfileStats({ schedules: d.schedules, records: d.records, settings: d.settings }, [], '2026-09-13', d.words.length);
console.log(JSON.stringify(s));
