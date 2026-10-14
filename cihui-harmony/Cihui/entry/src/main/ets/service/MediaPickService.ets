/**
 * 系统相册选图（F3）：相机页左下角“相册”入口，等价于直接选图，支持多选、按选择顺序返回。
 * PhotoViewPicker 由系统图库 UI 承载，无需申请相册权限。
 * 注意：picker 回传的是临时授权 URI（file://media/Photo/...），直接 createImageSource(uri)
 * 在部分镜像上会报 CreateImageSourceExec error，必须先 fileIo.openSync 拿 fd 再解码。
 */
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { image } from '@kit.ImageKit';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0003;
const TAG: string = 'MediaPickService';

export class MediaPickService {
  static async pickPhotos(maxCount: number): Promise<image.PixelMap[]> {
    const picker: photoAccessHelper.PhotoViewPicker = new photoAccessHelper.PhotoViewPicker();
    const result: photoAccessHelper.PhotoSelectResult = await picker.select({
      MIMEType: photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE,
      maxSelectNumber: maxCount
    });
    const out: image.PixelMap[] = [];
    for (const uri of result.photoUris) {
      const file: fileIo.File = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      try {
        const source: image.ImageSource = image.createImageSource(file.fd);
        const pixelMap: image.PixelMap = await source.createPixelMap();
        await source.release();
        out.push(pixelMap);
      } catch (err) {
        hilog.error(DOMAIN, TAG, 'decode picked photo failed: %{public}s', (err as Error)?.message ?? String(err));
        throw new Error('decode picked photo failed');
      } finally {
        try {
          fileIo.closeSync(file);
        } catch (e) {
          hilog.warn(DOMAIN, TAG, 'close picked fd failed: %{public}s', (e as Error)?.message ?? String(e));
        }
      }
    }
    return out;
  }
}
