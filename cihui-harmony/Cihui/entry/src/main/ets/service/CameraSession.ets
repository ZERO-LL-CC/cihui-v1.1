/**
 * 相机会话（F3）：封装 @kit.CameraKit 的预览与拍照，供全屏微信式相机页使用。
 * 真实 API 已按本机 SDK（API 26）签名编写并通过编译；取景/拍照效果需真机/模拟器核验。
 * 注意：调用方必须先获得 ohos.permission.CAMERA 授权。
 */
import { camera } from '@kit.CameraKit';
import { image } from '@kit.ImageKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

const TAG: string = 'CihuiCamera';

export class CameraSession {
  private context: common.UIAbilityContext | null = null;
  private manager: camera.CameraManager | null = null;
  private session: camera.PhotoSession | null = null;
  private input: camera.CameraInput | null = null;
  private previewOutput: camera.PreviewOutput | null = null;
  private photoOutput: camera.PhotoOutput | null = null;
  private pendingResolve: ((pm: image.PixelMap) => void) | null = null;
  private pendingReject: ((err: Error) => void) | null = null;

  /** 初始化预览：surfaceId 来自 XComponent onLoad 后的 getXComponentSurfaceId */
  async start(context: common.UIAbilityContext, surfaceId: string): Promise<void> {
    this.context = context;
    // 分阶段打点：真机启动失败时凭 hilog（tag=CihuiCamera）即可定位卡在哪一步、错误码是多少
    let step: string = 'getCameraManager';
    try {
      const manager: camera.CameraManager = camera.getCameraManager(context);
      this.manager = manager;

      step = 'getSupportedCameras';
      const devices: camera.CameraDevice[] = manager.getSupportedCameras();
      let device: camera.CameraDevice | undefined = devices.find((d: camera.CameraDevice): boolean =>
        d.cameraPosition === camera.CameraPosition.CAMERA_POSITION_BACK);
      if (!device) {
        device = devices[0];
      }
      if (!device) {
        throw new Error('未检测到可用摄像头');
      }

      // createSession 自 API 11 起替代已废弃的 createCaptureSession；NORMAL_PHOTO 场景对应 PhotoSession
      step = 'createSession';
      const session: camera.PhotoSession =
        manager.createSession<camera.PhotoSession>(camera.SceneMode.NORMAL_PHOTO);
      step = 'createCameraInput';
      const input: camera.CameraInput = manager.createCameraInput(device);

      // 关键修复：必须先取该设备在 NORMAL_PHOTO 场景下支持的输出能力，再用其中的真实 profile 创建输出流。
      // 若像原来那样用缺 profile 的 createPreviewOutput(surfaceId) / createPhotoOutput()，addOutput 时
      // 底层校验“profile 与 input 对应且非空”失败，抛出无数字码的普通 Error，页面表现为
      // “相机启动失败（addInputOutput，错误码 -1）”。
      step = 'getSupportedOutputCapability';
      const outputCap: camera.CameraOutputCapability =
        manager.getSupportedOutputCapability(device, camera.SceneMode.NORMAL_PHOTO);
      const previewProfile: camera.Profile | undefined = outputCap?.previewProfiles?.[0];
      const photoProfile: camera.Profile | undefined = outputCap?.photoProfiles?.[0];
      if (!previewProfile || !photoProfile) {
        throw new Error('当前设备不支持拍照输出配置');
      }

      step = 'createPreviewOutput';
      const previewOutput: camera.PreviewOutput = manager.createPreviewOutput(previewProfile, surfaceId);
      step = 'createPhotoOutput';
      // 单 profile 重载（无 surface）：拍照结果通过 photoAvailable 事件回传
      const photoOutput: camera.PhotoOutput = manager.createPhotoOutput(photoProfile);

      photoOutput.on('photoAvailable', async (err: Error, photo: camera.Photo): Promise<void> => {
        if (err) {
          if (this.pendingReject) {
            this.pendingReject(err);
          }
          return;
        }
        try {
          // Image 不直接暴露 byteBuffer：先取 JPEG 组件，再由其 byteBuffer 解码
          const component: image.Component = await photo.main.getComponent(image.ComponentType.JPEG);
          const buffer: ArrayBuffer = component.byteBuffer;
          const source: image.ImageSource = image.createImageSource(buffer);
          const pixelMap: image.PixelMap = await source.createPixelMap();
          await source.release();
          await photo.release();
          if (this.pendingResolve) {
            this.pendingResolve(pixelMap);
          }
        } catch (e) {
          hilog.error(0x0000, TAG, 'decode photo failed: %{public}s', JSON.stringify(e));
          if (this.pendingReject) {
            this.pendingReject(e as Error);
          }
        }
      });

      step = 'input.open';
      await input.open();
      step = 'beginConfig';
      session.beginConfig();
      step = 'addInputOutput';
      session.addInput(input);
      session.addOutput(previewOutput);
      session.addOutput(photoOutput);
      step = 'commitConfig';
      await session.commitConfig();
      step = 'session.start';
      await session.start();

      this.session = session;
      this.input = input;
      this.previewOutput = previewOutput;
      this.photoOutput = photoOutput;
      hilog.info(0x0000, TAG, 'camera started ok');
    } catch (e) {
      const em: string = (e as Error)?.message ?? '';
      if (em.indexOf('未检测到可用摄像头') >= 0) {
        hilog.error(0x0000, TAG, 'start failed: no camera device');
        throw new Error(em);
      }
      const be = e as BusinessError;
      const code: number = typeof be?.code === 'number' ? be.code : -1;
      hilog.error(0x0000, TAG, 'start failed at %{public}s code=%{public}d msg=%{public}s',
        step, code, em);
      throw new Error(`相机启动失败（${step}，错误码 ${code}）`);
    }
  }

  /** 拍照：返回定格 PixelMap；同一时刻只允许一张在途 */
  capture(): Promise<image.PixelMap> {
    return new Promise<image.PixelMap>((resolve: (pm: image.PixelMap) => void, reject: (err: Error) => void): void => {
      if (!this.session || !this.photoOutput) {
        reject(new Error('相机未就绪'));
        return;
      }
      this.pendingResolve = resolve;
      this.pendingReject = reject;
      const setting: camera.PhotoCaptureSetting = {
        quality: camera.QualityLevel.QUALITY_LEVEL_MEDIUM,
        mirror: false
      };
      this.photoOutput.capture(setting).catch((err: Error): void => {
        this.pendingResolve = null;
        this.pendingReject = null;
        reject(err);
      });
    });
  }

  /** 切换闪光灯（自动/常亮/关闭循环），设备不支持时返回 false */
  toggleFlash(): boolean {
    if (!this.session) {
      return false;
    }
    try {
      if (!this.session.hasFlash()) {
        return false;
      }
      const order: camera.FlashMode[] = [
        camera.FlashMode.FLASH_MODE_CLOSE,
        camera.FlashMode.FLASH_MODE_AUTO,
        camera.FlashMode.FLASH_MODE_OPEN
      ];
      const current: camera.FlashMode = this.session.getFlashMode ? this.session.getFlashMode() : camera.FlashMode.FLASH_MODE_CLOSE;
      const idx: number = order.indexOf(current);
      const next: camera.FlashMode = order[(idx + 1) % order.length];
      if (this.session.isFlashModeSupported(next)) {
        this.session.setFlashMode(next);
        return true;
      }
      return false;
    } catch (err) {
      hilog.warn(0x0000, TAG, 'flash toggle failed: %{public}s', JSON.stringify(err));
      return false;
    }
  }

  /** 释放全部相机会话资源（页面消失时必须调用） */
  async release(): Promise<void> {
    try {
      if (this.session) {
        await this.session.stop();
      }
      if (this.previewOutput) {
        await this.previewOutput.release();
      }
      if (this.photoOutput) {
        await this.photoOutput.release();
      }
      if (this.input) {
        await this.input.close();
      }
      if (this.session) {
        await this.session.release();
      }
    } catch (err) {
      hilog.warn(0x0000, TAG, 'release failed: %{public}s', JSON.stringify(err));
    } finally {
      this.session = null;
      this.input = null;
      this.previewOutput = null;
      this.photoOutput = null;
      this.manager = null;
    }
  }
}
