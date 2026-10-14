/**
 * 云词本目录（F5）。
 *
 * 词书内容已真实化：大学/高中/中考 5 本词书来自开源 ECDICT（MIT，
 * skywind3000/ECDICT），按考纲标签 cet4/cet6/ky/gk/zk 筛选，
 * 元数据与预览词由 _ecdict/generate_books.py 生成到
 * CloudBookData.generated.ts，整本词书随包放在 rawfile/cloudbooks。
 *
 * 分年级（高一~高三、七~九年级、小学三~六年级）词书需要教材版本授权词表，
 * ECDICT 无对应标签，未编造数据，先以 coming=true 标注「筹备中」，
 * 接入开源教材词表后补齐。
 *
 * 该文件为纯逻辑 .ts（无 ArkUI 依赖），可在 Node 下直接单测。
 */
import { GENERATED_BOOKS } from './CloudBookData.generated';

/** 云词书元数据 */
export interface CloudBookMeta {
  /** 云词书稳定 ID（与 WordBook.cloudBookId 对应，用于幂等导入判断） */
  id: string;
  name: string;
  version: string;
  totalCount: number;
  category: string;
  /** 年级标签（高一 / 七年级 / 小学三年级等），大学词书为空 */
  grade: string;
  /** 是否热门（详情/列表可打热门标） */
  hot: boolean;
  /** 词书内容是否尚未接入（true 时不可下载，详情页显示筹备中） */
  coming?: boolean;
}

/** 词书词条（预览与下载导入共用） */
export interface CloudSampleWord {
  english: string;
  phonetic: string;
  meaning: string;
}

/** 库页分组：featured 为大卡片，chips 为横/换行小胶囊 */
export interface CloudGroup {
  title: string;
  featured: CloudBookMeta[];
  chips: CloudBookMeta[];
}

/** 热门搜索 8 个（前 3 个在搜索页带序号样式） */
export const HOT_SEARCH: string[] = [
  '四级', '中考', 'abandon', '高考', '考研', '六级', '小学三年级', '七年级',
];

const REAL_BOOKS: CloudBookMeta[] = GENERATED_BOOKS.map((g): CloudBookMeta => g.meta);

const PREVIEW_MAP: Map<string, CloudSampleWord[]> = new Map<string, CloudSampleWord[]>();
for (const g of GENERATED_BOOKS) {
  PREVIEW_MAP.set(g.meta.id, g.preview.map((w: CloudSampleWord): CloudSampleWord => ({
    english: w.english,
    phonetic: w.phonetic,
    meaning: w.meaning,
  })));
}

/** 分年级词书：教材词表接入前展示为「筹备中」，不提供下载 */
const COMING_BOOKS: CloudBookMeta[] = [
  { id: 'g1', name: '高一词汇', version: '人教版（筹备中）', totalCount: 0, category: '高中词书', grade: '高一', hot: false, coming: true },
  { id: 'g2', name: '高二词汇', version: '人教版（筹备中）', totalCount: 0, category: '高中词书', grade: '高二', hot: false, coming: true },
  { id: 'g3', name: '高三词汇', version: '人教版（筹备中）', totalCount: 0, category: '高中词书', grade: '高三', hot: false, coming: true },
  { id: 'j1', name: '七年级词汇', version: '人教版（筹备中）', totalCount: 0, category: '初中 / 小学', grade: '七年级', hot: false, coming: true },
  { id: 'j2', name: '八年级词汇', version: '人教版（筹备中）', totalCount: 0, category: '初中 / 小学', grade: '八年级', hot: false, coming: true },
  { id: 'j3', name: '九年级词汇', version: '人教版（筹备中）', totalCount: 0, category: '初中 / 小学', grade: '九年级', hot: false, coming: true },
  { id: 'p3', name: '小学三年级', version: '人教 PEP（筹备中）', totalCount: 0, category: '初中 / 小学', grade: '小学三年级', hot: false, coming: true },
  { id: 'p4', name: '小学四年级', version: '人教 PEP（筹备中）', totalCount: 0, category: '初中 / 小学', grade: '小学四年级', hot: false, coming: true },
  { id: 'p5', name: '小学五年级', version: '人教 PEP（筹备中）', totalCount: 0, category: '初中 / 小学', grade: '小学五年级', hot: false, coming: true },
  { id: 'p6', name: '小学六年级', version: '人教 PEP（筹备中）', totalCount: 0, category: '初中 / 小学', grade: '小学六年级', hot: false, coming: true },
];

const BOOKS: CloudBookMeta[] = REAL_BOOKS.concat(COMING_BOOKS);

/** 库页分组（大学：3 张大卡；高中：高考大卡 + 三个年级胶囊；初中/小学：全部胶囊） */
export function getGroups(): CloudGroup[] {
  const all: CloudBookMeta[] = BOOKS;
  const uni: CloudBookMeta[] = all.filter((b: CloudBookMeta): boolean => b.category === '大学词书');
  const senior: CloudBookMeta[] = all.filter((b: CloudBookMeta): boolean => b.category === '高中词书');
  const junior: CloudBookMeta[] = all.filter((b: CloudBookMeta): boolean => b.category === '初中 / 小学');
  const g1: CloudGroup = { title: '大学词书', featured: uni, chips: [] };
  const g2: CloudGroup = {
    title: '高中词书',
    featured: senior.filter((b: CloudBookMeta): boolean => b.grade.length === 0),
    chips: senior.filter((b: CloudBookMeta): boolean => b.grade.length > 0),
  };
  const g3: CloudGroup = { title: '初中 / 小学', featured: [], chips: junior };
  return [g1, g2, g3];
}

export function findCloudBook(id: string): CloudBookMeta | null {
  const hit: CloudBookMeta | undefined = BOOKS.find((b: CloudBookMeta): boolean => b.id === id);
  return hit ? hit : null;
}

/** 词书详情页预览词：取真实词书前 12 词；筹备中词书为空 */
export function getSampleWords(id: string): CloudSampleWord[] {
  const words: CloudSampleWord[] | undefined = PREVIEW_MAP.get(id);
  return words ? words.map((w: CloudSampleWord): CloudSampleWord => ({
    english: w.english,
    phonetic: w.phonetic,
    meaning: w.meaning,
  })) : [];
}

/** 搜索：匹配词书名 / 版本 / 年级，或已接入词书预览词的英文 */
export function searchBooks(keyword: string): CloudBookMeta[] {
  const kw: string = keyword.trim().toLowerCase();
  if (kw.length === 0) {
    return [];
  }
  return BOOKS.filter((b: CloudBookMeta): boolean => {
    const inMeta: boolean = b.name.toLowerCase().indexOf(kw) >= 0
      || b.version.toLowerCase().indexOf(kw) >= 0
      || b.grade.toLowerCase().indexOf(kw) >= 0
      || b.category.toLowerCase().indexOf(kw) >= 0;
    if (inMeta) {
      return true;
    }
    const preview: CloudSampleWord[] | undefined = PREVIEW_MAP.get(b.id);
    if (!preview) {
      return false;
    }
    return preview.some((w: CloudSampleWord): boolean => w.english.toLowerCase().indexOf(kw) >= 0);
  });
}
