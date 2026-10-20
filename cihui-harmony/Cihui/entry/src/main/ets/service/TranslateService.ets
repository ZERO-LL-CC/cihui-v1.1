/**
 * 词慧 · F17 梗句中文 → 英文翻译服务（端侧离线版）
 *
 * 历史：早期走公共 LibreTranslate（已停服 403），之后改为云端大模型翻译，
 * 但接口 Key 从未配置，链路必然失败（死代码）。现已整体移除：
 * - 不再 import http / 不再持有任何 Key / 不发任何网络请求；
 * - 改为调用 model/OfflineTranslateCore 的端侧「梗味短语表 + 改写策略」引擎：
 *   L1 整句库直出高质量英文、L2 梗词命中给「英文脚手架」、L3 未命中留空不编造；
 * - 能力边界诚实标注：needsManual / message 由引擎给出，UI 负责提示与手动润色。
 *
 * 产品兜底始终是「用户手动填写英文框」，离线引擎只是加速器，不是必需路径。
 */
import type { TranslateMode, TranslateResult } from '../model/OfflineTranslateCore';
import { translateOffline } from '../model/OfflineTranslateCore';

class TranslateServiceImpl {
  /** 离线引擎恒定可用（零网络、零密钥、零模型，断网也能跑） */
  available(): boolean {
    return true;
  }

  /**
   * 中文 → 英文（梗味模式）。
   * 有英文结果（整句命中 / 梗词脚手架）则返回；未命中或空输入抛 Error，
   * message 可直接 Toast。方法签名保持不变（MemeImportPage 仍在调用）。
   */
  async zhToEn(zh: string): Promise<string> {
    if (zh.trim().length === 0) {
      throw new Error('请先输入中文句子');
    }
    const result: TranslateResult = translateOffline(zh, 'MEME');
    if (result.english.length > 0) {
      return result.english;
    }
    throw new Error(result.message.length > 0 ? result.message : '未识别到梗词，请手动填写英文');
  }

  /**
   * 详细翻译结果：UI 需要 hits / level / rewrittenZh 时调用（不抛业务异常）。
   * @param zh   中文原句
   * @param mode 'MEME' 梗味模式 / 'LITERAL' 只检测梗
   */
  async translateDetail(zh: string, mode: TranslateMode): Promise<TranslateResult> {
    return translateOffline(zh, mode);
  }
}

export const TranslateService: TranslateServiceImpl = new TranslateServiceImpl();
