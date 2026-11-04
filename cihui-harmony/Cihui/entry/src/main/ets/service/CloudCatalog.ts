/**
 * 云词本目录（F5）。
 *
 * 词书内容已真实化：10 本词书全部来自开源 ECDICT（MIT，
 * skywind3000/ECDICT），覆盖 基础核心/大学/出国/高中/中考 五类，
 * 元数据与预览词由 _ecdict/generate_books.py 生成到
 * CloudBookData.generated.ts，整本词书随包放在 rawfile/cloudbooks。
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
  /** 年级标签（高一 / 七年级 / 中考等），非分年级词书为空 */
  grade: string;
  /** 是否热门（详情/列表可打热门标） */
  hot: boolean;
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

/** 热门搜索 8 个（前 3 个在搜索页带序号样式；必须都能命中词书或预览词） */
export const HOT_SEARCH: string[] = [
  '四级', '中考', '高考', '牛津3000', '考研', '六级', '雅思', '柯林斯',
];

const PREVIEW_MAP: Map<string, CloudSampleWord[]> = new Map<string, CloudSampleWord[]>();
for (const g of GENERATED_BOOKS) {
  PREVIEW_MAP.set(g.meta.id, g.preview.map((w: CloudSampleWord): CloudSampleWord => ({
    english: w.english,
    phonetic: w.phonetic,
    meaning: w.meaning,
  })));
}

const BOOKS: CloudBookMeta[] = GENERATED_BOOKS.map((g): CloudBookMeta => g.meta);

/** 分组展示顺序；数据里出现的新分类会追加在末尾，不丢弃 */
const CATEGORY_ORDER: string[] = ['基础核心', '大学词书', '出国词书', '高中词书', '初中 / 小学'];

/** 库页分组：年级为空的词书作大卡，带年级标签的作小胶囊；空分组跳过 */
export function getGroups(): CloudGroup[] {
  const byCat: Map<string, CloudBookMeta[]> = new Map<string, CloudBookMeta[]>();
  const order: string[] = CATEGORY_ORDER.slice();
  for (const b of BOOKS) {
    if (!byCat.has(b.category)) {
      byCat.set(b.category, []);
      if (order.indexOf(b.category) < 0) {
        order.push(b.category);
      }
    }
    byCat.get(b.category)!.push(b);
  }
  const out: CloudGroup[] = [];
  for (const cat of order) {
    const items: CloudBookMeta[] | undefined = byCat.get(cat);
    if (items === undefined || items.length === 0) {
      continue;
    }
    out.push({
      title: cat,
      featured: items.filter((b: CloudBookMeta): boolean => b.grade.length === 0),
      chips: items.filter((b: CloudBookMeta): boolean => b.grade.length > 0),
    });
  }
  return out;
}

export function findCloudBook(id: string): CloudBookMeta | null {
  const hit: CloudBookMeta | undefined = BOOKS.find((b: CloudBookMeta): boolean => b.id === id);
  return hit ? hit : null;
}

/** 词书详情页预览词：取真实词书前 12 词 */
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
