/**
 * F15 云备份纯逻辑：备份文件结构、解析校验、按时间戳合并恢复（可 Node 单测）。
 *
 * 备份文件（JSON）：
 * { format:'cihui-backup', version:1, exportedAt, appData, profile }
 *
 * 冲突策略（MVP，对应功能卡 F15）：
 * - 词本 / 单词 / 调度 / 学习记录 / 打卡：按稳定主键并集合并，不丢任何一端数据；
 * - 同主键冲突取「更新」一方：调度看 lastVerdictAt，记录逐时间戳字段取最大，
 *   词本看 createdAt，单词做义项并集；打卡按天 OR（完成过就算完成）；
 * - 设置为整组 KV，不做字段级合并：以备份文件 exportedAt 新旧决定整组归属；
 * - 账号资料：当前已登录账号为准（不跨账号覆盖），未登录（换机）时恢复备份中的资料；
 * - 恢复前由服务层把本机现状另存一份「恢复前本地副本」，合并不覆盖、可回退。
 * 完整多端实时同步属二期，本期只做本地 JSON 导出/导入与合并，云端通道 TODO。
 */
import type { AppData } from './RepoCore';
import { emptyData } from './RepoCore';
import type {
  CheckInRecord,
  MemeCard,
  MemeSentence,
  SavedSentence,
  ReviewSchedule,
  Settings,
  StudyRecord,
  StudySession,
  Word,
  WordBook,
} from './Types';

/** 按 id 合并两组实体：本机在前、备份在后，同 id 以备份覆盖（F17–F19 云备份合并） */
function unionById<T extends { id: string }>(local: T[], remote: T[]): T[] {
  const map: Map<string, T> = new Map<string, T>();
  local.forEach((x: T): void => {
    map.set(x.id, x);
  });
  remote.forEach((x: T): void => {
    map.set(x.id, x);
  });
  return Array.from(map.values());
}

export const BACKUP_FORMAT = 'cihui-backup';
export const BACKUP_VERSION = 1;

export interface ProfileSnapshot {
  name: string;
  phone: string;
  email: string;
  wechat: string;
  qq: string;
  cloudEnabled: boolean;
}

export interface BackupFile {
  format: string;
  version: number;
  exportedAt: number;
  appData: AppData;
  profile: ProfileSnapshot | null;
}

export interface MergeSummary {
  books: number;
  words: number;
  schedules: number;
  records: number;
  checkins: number;
  addedBooks: number;
  addedWords: number;
}

function clone<T>(v: T): T {
  return JSON.parse(JSON.stringify(v)) as T;
}

function maxStr(a: string, b: string): string {
  return a >= b ? a : b;
}

export function buildBackup(data: AppData, profile: ProfileSnapshot | null, now: number): BackupFile {
  return {
    format: BACKUP_FORMAT,
    version: BACKUP_VERSION,
    exportedAt: now,
    appData: clone(data),
    profile: profile === null ? null : clone(profile),
  };
}

/** 解析并校验备份文件；非法文件抛错，由 UI 提示「同步失败/文件无效」，不动本机数据 */
export function parseBackup(json: string): BackupFile {
  let parsed: BackupFile;
  try {
    parsed = JSON.parse(json) as BackupFile;
  } catch (_e) {
    throw new Error('备份文件不是有效的 JSON');
  }
  if (!parsed || parsed.format !== BACKUP_FORMAT) {
    throw new Error('不是词慧备份文件');
  }
  if (parsed.version !== BACKUP_VERSION) {
    throw new Error(`不支持的备份版本：${parsed.version}`);
  }
  const d = parsed.appData;
  if (!d || !Array.isArray(d.books) || !Array.isArray(d.words) || !Array.isArray(d.schedules)
    || !Array.isArray(d.records) || !Array.isArray(d.checkins) || typeof d.settings !== 'object') {
    throw new Error('备份内容不完整');
  }
  return parsed;
}

function mergeBooks(local: WordBook[], remote: WordBook[]): { list: WordBook[]; added: number } {
  const map = new Map<string, WordBook>();
  for (const b of local) {
    map.set(b.id, clone(b));
  }
  let added = 0;
  for (const b of remote) {
    const exist = map.get(b.id);
    if (!exist) {
      map.set(b.id, clone(b));
      added += 1;
    } else if (b.createdAt > exist.createdAt) {
      map.set(b.id, clone(b));
    }
  }
  return { list: Array.from(map.values()).sort((a, b) => a.createdAt - b.createdAt), added };
}

function mergeWords(local: Word[], remote: Word[]): { list: Word[]; added: number } {
  const map = new Map<string, Word>();
  for (const w of local) {
    map.set(w.id, clone(w));
  }
  let added = 0;
  for (const rw of remote) {
    const exist = map.get(rw.id);
    if (!exist) {
      map.set(rw.id, clone(rw));
      added += 1;
      continue;
    }
    // 义项并集（本机在前），去重保序；音标/补录信息互相补全
    const meanings: string[] = exist.meanings.slice();
    for (const m of rw.meanings) {
      if (m !== '' && meanings.indexOf(m) < 0) {
        meanings.push(m);
      }
    }
    const merged: Word = {
      ...exist,
      phonetic: exist.phonetic !== '' ? exist.phonetic : rw.phonetic,
      meanings,
      missingMeaning: exist.missingMeaning && rw.missingMeaning,
      diySupplement: exist.diySupplement || rw.diySupplement,
      createdAt: Math.min(exist.createdAt, rw.createdAt),
    };
    map.set(rw.id, merged);
  }
  return { list: Array.from(map.values()).sort((a, b) => a.createdAt - b.createdAt), added };
}

function statusRank(s: ReviewSchedule): number {
  if (s.status === 'MASTERED') {
    return 2;
  }
  if (s.status === 'WRONG') {
    return 1;
  }
  return 0;
}

function mergeSchedules(local: ReviewSchedule[], remote: ReviewSchedule[]): ReviewSchedule[] {
  const map = new Map<string, ReviewSchedule>();
  for (const s of local) {
    map.set(s.wordId, clone(s));
  }
  for (const rs0 of remote) {
    const rs: ReviewSchedule = clone(rs0);
    const exist = map.get(rs.wordId);
    if (!exist) {
      map.set(rs.wordId, rs);
      continue;
    }
    // 最近一次判定更新的一方为准；时间戳相同（含都为 0）时掌握态优先
    const winner: ReviewSchedule = rs.lastVerdictAt > exist.lastVerdictAt ? rs
      : (rs.lastVerdictAt < exist.lastVerdictAt ? exist
        : (statusRank(rs) >= statusRank(exist) ? rs : exist));
    map.set(rs.wordId, winner);
  }
  return Array.from(map.values());
}

function mergeRecords(local: StudyRecord[], remote: StudyRecord[]): StudyRecord[] {
  const map = new Map<string, StudyRecord>();
  for (const r of local) {
    map.set(r.wordId, clone(r));
  }
  for (const rr0 of remote) {
    const rr: StudyRecord = clone(rr0);
    const exist = map.get(rr.wordId);
    if (!exist) {
      map.set(rr.wordId, rr);
      continue;
    }
    map.set(rr.wordId, {
      wordId: rr.wordId,
      firstStudyAt: Math.max(exist.firstStudyAt, rr.firstStudyAt),
      firstPassedAt: Math.max(exist.firstPassedAt, rr.firstPassedAt),
      s1DoneAt: Math.max(exist.s1DoneAt, rr.s1DoneAt),
      s2DoneAt: Math.max(exist.s2DoneAt, rr.s2DoneAt),
      s3DoneAt: Math.max(exist.s3DoneAt, rr.s3DoneAt),
      lastStudyDay: maxStr(exist.lastStudyDay, rr.lastStudyDay),
    });
  }
  return Array.from(map.values());
}

function mergeCheckins(local: CheckInRecord[], remote: CheckInRecord[]): CheckInRecord[] {
  const map = new Map<string, CheckInRecord>();
  for (const c of local) {
    map.set(c.day, clone(c));
  }
  for (const rc0 of remote) {
    const rc: CheckInRecord = clone(rc0);
    const exist = map.get(rc.day);
    if (!exist) {
      map.set(rc.day, rc);
      continue;
    }
    map.set(rc.day, {
      day: rc.day,
      p1NewDone: exist.p1NewDone || rc.p1NewDone,
      p2ReviewDone: exist.p2ReviewDone || rc.p2ReviewDone,
      p3WrongDone: exist.p3WrongDone || rc.p3WrongDone,
      p3Required: exist.p3Required || rc.p3Required,
      checkedIn: exist.checkedIn || rc.checkedIn,
      makeup: exist.makeup || rc.makeup,
      streak: Math.max(exist.streak, rc.streak),
    });
  }
  return Array.from(map.values()).sort((a, b) => (a.day < b.day ? -1 : 1));
}

/**
 * 合并两份全量数据。
 * @param preferRemoteSettings 备份文件比本机新时为 true，设置整组取备份；否则保留本机设置。
 */
export function mergeAppData(
  local: AppData,
  remote: AppData,
  preferRemoteSettings: boolean,
): { data: AppData; summary: MergeSummary } {
  const books = mergeBooks(local.books, remote.books);
  const words = mergeWords(local.words, remote.words);
  const merged: AppData = {
    books: books.list,
    words: words.list,
    schedules: mergeSchedules(local.schedules, remote.schedules),
    records: mergeRecords(local.records, remote.records),
    checkins: mergeCheckins(local.checkins, remote.checkins),
    settings: clone(preferRemoteSettings ? remote.settings : local.settings) as Settings,
    memes: unionById<MemeSentence>(local.memes ?? [], remote.memes ?? []),
    sessions: unionById<StudySession>(local.sessions ?? [], remote.sessions ?? []),
    memeCards: unionById<MemeCard>(local.memeCards ?? [], remote.memeCards ?? []),
    savedSentences: unionById<SavedSentence>(local.savedSentences ?? [], remote.savedSentences ?? []),
  };
  const summary: MergeSummary = {
    books: merged.books.length,
    words: merged.words.length,
    schedules: merged.schedules.length,
    records: merged.records.length,
    checkins: merged.checkins.length,
    addedBooks: books.added,
    addedWords: words.added,
  };
  return { data: merged, summary };
}

/** 账号资料合并：已登录以当前账号为准；未登录（换机）恢复备份资料 */
export function mergeProfile(
  current: ProfileSnapshot | null,
  backup: ProfileSnapshot | null,
): ProfileSnapshot | null {
  if (current !== null) {
    return current;
  }
  return backup === null ? null : clone(backup);
}

export function emptyBackup(now: number): BackupFile {
  return {
    format: BACKUP_FORMAT,
    version: BACKUP_VERSION,
    exportedAt: now,
    appData: emptyData(),
    profile: null,
  };
}
