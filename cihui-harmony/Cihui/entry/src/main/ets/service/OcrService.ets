/**
 * OCR 识别服务（F3 识别卡 / F4 校对页共用）：
 * 真实接入 @kit.CoreVisionKit（HMS，起始 4.0.0(10)）的 textRecognition，
 * 初始化 → 传 PixelMap → 取行文本 → 释放；识别在调用方异步任务中执行，不阻塞 UI。
 * 行解析（英文/中文配对、去重）在 F4 校对页完成，本服务只负责按阅读顺序返回原始文本行。
 */
import { textRecognition } from '@kit.CoreVisionKit';
import { image } from '@kit.ImageKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'CihuiOcr';

/** 单张图片的识别结果：图片本身 + 按阅读顺序排列的原始文本行 */
export interface OcrImageResult {
  pixelMap: image.PixelMap;
  lines: string[];
}

/** 进度回调：percent 0–100，text 为卡片文案 */
export type OcrProgressCallback = (percent: number, text: string) => void;

export class OcrService {
  /**
   * 批量识别多张图（连拍/多选按数组合并）。
   * 进度口径对齐 F3：起步 18%，每张完成推进，最后一张到 62%（解析阶段），
   * 全部完成回调 100%（对勾停留由页面控制）。
   */
  static async recognize(images: image.PixelMap[], onProgress: OcrProgressCallback): Promise<OcrImageResult[]> {
    if (images.length === 0) {
      throw new Error('没有可识别的图片');
    }
    let initialized: boolean = false;
    try {
      onProgress(18, '正在识别图片…');
      const initOk: boolean = await textRecognition.init();
      if (!initOk) {
        throw new Error('文字识别引擎初始化失败');
      }
      initialized = true;

      const results: OcrImageResult[] = [];
      for (let i: number = 0; i < images.length; i++) {
        const result: textRecognition.TextRecognitionResult =
          await textRecognition.recognizeText(
            { pixelMap: images[i] },
            { isDirectionDetectionSupported: true }
          );
        results.push({ pixelMap: images[i], lines: OcrService.extractLines(result) });
        if (images.length === 1) {
          onProgress(62, '正在整理识别结果…');
        } else {
          onProgress(18 + Math.round(44 * (i + 1) / images.length), `正在识别第 ${i + 1}/${images.length} 张…`);
        }
      }
      onProgress(100, '识别完成');
      return results;
    } catch (err) {
      hilog.error(0x0000, TAG, 'recognize failed: %{public}s', JSON.stringify(err));
      throw new Error('文字识别失败：' + ((err as Error).message || JSON.stringify(err)));
    } finally {
      if (initialized) {
        try {
          await textRecognition.release();
        } catch (err) {
          hilog.warn(0x0000, TAG, 'release failed: %{public}s', JSON.stringify(err));
        }
      }
    }
  }

  /** 从识别结果中按“块 → 行”展开为阅读顺序文本行，去空行 */
  private static extractLines(result: textRecognition.TextRecognitionResult): string[] {
    const lines: string[] = [];
    if (result.blocks && result.blocks.length > 0) {
      for (const block of result.blocks) {
        if (block.lines && block.lines.length > 0) {
          for (const line of block.lines) {
            const v: string = (line.value ?? '').trim();
            if (v.length > 0) {
              lines.push(v);
            }
          }
        } else if (block.value) {
          const v: string = block.value.trim();
          if (v.length > 0) {
            lines.push(v);
          }
        }
      }
    } else if (result.value) {
      for (const raw of result.value.split('\n')) {
        const v: string = raw.trim();
        if (v.length > 0) {
          lines.push(v);
        }
      }
    }
    return lines;
  }
}
