/**
 * F11 打卡分享图服务
 *
 * - componentSnapshot 快照分享卡片 → PixelMap；
 * - imagePacker 打包 JPEG 写入应用缓存目录；
 * - 通过安全组件 SaveButton 的点击授权（临时授予 WRITE_IMAGEVIDEO，无需申请受限权限），
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
   * 按组件 id 截图并打包成 JPEG（组件需真实挂载）。
   * createFromBuilder 对未挂载的 @Builder 会抛 observeComponentCreation2 of undefined，
   * 所以分享卡改为「真实挂载 + 按 id 取图」，宿主压在不透明页面层下面，用户看不见。
   */
  static async snapshotByIdToJpg(context: common.Context, id: string, fileName: string): Promise<string> {
    const pixelMap: image.PixelMap = await componentSnapshot.get(id);
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
      const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
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
   * 把缓存目录里的图片文件保存到系统相册。
   * 依赖 SaveButton 点击时授予的临时 WRITE_IMAGEVIDEO，必须在点击回调链里调用。
   */
  static async saveFileToGallery(context: common.Context, path: string): Promise<void> {
    const uri: string = `file://${path}`;
    const request: photoAccessHelper.MediaAssetChangeRequest =
      photoAccessHelper.MediaAssetChangeRequest.createImageAssetRequest(context, uri);
    const helper: photoAccessHelper.PhotoAccessHelper = photoAccessHelper.getPhotoAccessHelper(context);
    await helper.applyChanges(request);
  }
}
