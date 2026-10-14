/**
 * F18 梗卡片服务
 *
 * 技术选型说明（API26 实测）：OffscreenCanvas 的 ImageBitmap 在声明式类型里只有
 * width/height/close，拿不到像素 buffer，也没有 toDataURL，无法在 service 层导出图片文件。
 * 因此卡片画面统一用 ArkUI @Builder 绘制（页面内 MemeCardView/FallbackCard），
 * 离屏导出走 F11 已验证的 componentSnapshot.createFromBuilder → JPEG（见 ShareService），
 * 文字渲染比 Canvas 更清晰，也天然支持减弱动效与字体缩放。本服务只保留：
 * - 徽章短文案/配色、默认分享文案；
 * - 缓存图片保存系统相册（由 SaveButton 安全控件授权后调用）；
 * - Share Kit 系统分享面板（图片记录 + 文本记录），无目标时页面降级存相册。
 */
import { fileUri } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { systemShare } from '@kit.ShareKit';
import { uniformTypeDescriptor as utd } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import type { MemeBadgeLevel } from '../model/Types';

/** 梗卡绘制入参（页面从 MemeCard + MemeSentence 组装） */
export interface MemeCardSpec {
  chinese: string;
  english: string;
  masteredCount: number;
  totalCount: number;
  unlockedDay: string; // YYYY-MM-DD
  badgeLevel: MemeBadgeLevel;
}

export class MemeCardService {
  /** 徽章短文案（卡面圆形徽章内） */
  static badgeShort(level: MemeBadgeLevel): string {
    if (level === 'GOLD') {
      return '梗王';
    }
    if (level === 'SILVER') {
      return '梗手';
    }
    return '新人';
  }

  /** 徽章主色（金/银/铜，扁平不用 emoji） */
  static badgeColor(level: MemeBadgeLevel): string {
    if (level === 'GOLD') {
      return '#F5C542';
    }
    if (level === 'SILVER') {
      return '#C7D0DA';
    }
    return '#D08A4E';
  }

  /** 默认分享文案（原句过长截断，避免系统分享面板文案溢出） */
  static shareText(spec: MemeCardSpec | null, fallback?: string): string {
    if (spec === null) {
      return fallback ?? '我在词慧解锁了一个梗卡！';
    }
    const sentence: string = spec.chinese.length > 18 ? `${spec.chinese.slice(0, 18)}…` : spec.chinese;
    return `我在词慧解锁了一个梗：${sentence}，已掌握 ${spec.masteredCount} 个词！`;
  }

  /** 保存缓存图片（快照 JPEG）到系统相册（页面需先经 SaveButton 安全控件授权） */
  static async saveImageToGallery(context: common.Context, path: string): Promise<void> {
    const uri: string = `file://${path}`;
    const request: photoAccessHelper.MediaAssetChangeRequest =
      photoAccessHelper.MediaAssetChangeRequest.createImageAssetRequest(context, uri);
    const helper: photoAccessHelper.PhotoAccessHelper = photoAccessHelper.getPhotoAccessHelper(context);
    await helper.applyChanges(request);
  }

  /** 拉起 Share Kit 系统分享面板：JPEG 图片 + 默认文案文本 */
  static async shareImage(context: common.UIAbilityContext, path: string, text: string): Promise<void> {
    const shareData: systemShare.SharedData = new systemShare.SharedData({
      utd: utd.UniformDataType.JPEG,
      uri: fileUri.getUriFromPath(path),
      title: '词慧梗卡',
      description: text,
    });
    shareData.addRecord({
      utd: utd.UniformDataType.PLAIN_TEXT,
      content: text,
    });
    const controller: systemShare.ShareController = new systemShare.ShareController(shareData);
    await controller.show(context, {
      selectionMode: systemShare.SelectionMode.SINGLE,
      previewMode: systemShare.SharePreviewMode.DEFAULT,
    });
  }
}
