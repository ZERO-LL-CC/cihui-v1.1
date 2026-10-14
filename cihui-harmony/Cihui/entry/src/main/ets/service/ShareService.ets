/**
 * F11 打卡分享图服务
 *
 * - componentSnapshot.createFromBuilder 离屏快照分享卡片 @Builder → PixelMap；
 * - imagePacker 打包 JPEG 写入应用缓存目录；
 * - 通过安全组件 SaveButton 的点击授权（无需手动申请相册权限），
 *   MediaAssetChangeRequest.createImageAssetRequest 保存到系统相册。
 * 任一步失败都向上抛错，由页面 Toast 提示，不假装成功。
 */
import { componentSnapshot } from '@kit.ArkUI';
import { image } from '@kit.ImageKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';

export class ShareService {
  /**
   * 把 @Builder 离屏快照打包成 JPEG 写入缓存目录，返回文件绝对路径。
   * F11 保存相册与 F18 Canvas 失败降级分享共用这一段。
   */
  static async snapshotBuilderToJpg(context: common.Context, builder: CustomBuilder, fileName: string): Promise<string> {
    const pixelMap: image.PixelMap = await componentSnapshot.createFromBuilder(builder, 200, false);
    try {
      const packer: image.ImagePacker = image.createImagePacker();
      let buffer: ArrayBuffer = new ArrayBuffer(0);
      try {
        const packOptions: image.PackingOption = {
          format: 'image/jpeg',
          quality: 95,
        } as image.PackingOption;
        buffer = await packer.packing(pixelMap, packOptions);
      } finally {
        packer.release();
      }

      const path: string = `${context.cacheDir}/${fileName}.jpg`;
      const file = fs.openSync(path,
        fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, buffer);
      } finally {
        fs.closeSync(file);
      }
      return path;
    } finally {
      pixelMap.release();
    }
  }

  /**
   * 生成分享卡片并保存到相册。
   * @param context UIAbility 上下文
   * @param builder 分享卡片 @Builder（CustomBuilder）
   * @param fileName 文件名（不含扩展名）
   */
  static async saveCardToGallery(context: common.Context, builder: CustomBuilder, fileName: string): Promise<void> {
    const path: string = await ShareService.snapshotBuilderToJpg(context, builder, fileName);
    await ShareService.saveFileToGallery(context, path);
  }

  /** 把缓存目录里的图片文件保存到系统相册 */
  static async saveFileToGallery(context: common.Context, path: string): Promise<void> {
    const uri: string = `file://${path}`;
    const request: photoAccessHelper.MediaAssetChangeRequest =
      photoAccessHelper.MediaAssetChangeRequest.createImageAssetRequest(context, uri);
    const helper: photoAccessHelper.PhotoAccessHelper = photoAccessHelper.getPhotoAccessHelper(context);
    await helper.applyChanges(request);
  }
}
