import { hilog } from '@kit.PerformanceAnalysisKit';
import { image } from '@kit.ImageKit';
import { common } from '@kit.AbilityKit';
import { OcrService, OcrProgressCallback } from '../../service/OcrService';

/**
 * HMS textRecognition 真机探针页（dev 专用，不进任何业务导航）。
 *
 * 用途：与 PC 版 TrOCR 做同图对比 —— 把两张手写词表照片
 * （rawfile/ocr_demo/demo_pageA.jpg / demo_pageB.jpg）喂给 OcrService
 * （即线上 F3/F4 用的 HMS 识别链路），逐行打到 hilog。
 *
 * hilog 过滤：hdc shell hilog | grep HmsOcrProbe
 * 页面进入即自动跑，跑完打 ALL_DONE。
 */

const DOMAIN: number = 0x0000;
const TAG: string = 'HmsOcrProbe';

interface PageSpec {
  rawName: string;
  label: string;
}

const PAGES: PageSpec[] = [
  { rawName: 'ocr_demo/pageA.jpg', label: 'PAGE_A' },
  { rawName: 'ocr_demo/pageB.jpg', label: 'PAGE_B' },
];

@Entry
@ComponentV2
struct HmsOcrProbePage {
  @Local logLines: string[] = [];
  @Local busy: boolean = false;

  aboutToAppear(): void {
    this.log('probe start, auto run');
    this.run();
  }

  private log(msg: string): void {
    const line: string = `${new Date().toISOString().slice(11, 23)} ${msg}`;
    this.logLines.push(line);
    if (this.logLines.length > 600) {
      this.logLines.splice(0, this.logLines.length - 600);
    }
    hilog.info(DOMAIN, TAG, '%{public}s', line);
  }

  private async decode(rawName: string): Promise<image.PixelMap> {
    const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    const buf: Uint8Array = await ctx.resourceManager.getRawFileContent(rawName);
    const ab: ArrayBuffer = buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength) as ArrayBuffer;
    const src: image.ImageSource = image.createImageSource(ab);
    const pm: image.PixelMap = await src.createPixelMap();
    await src.release();
    return pm;
  }

  private async run(): Promise<void> {
    if (this.busy) {
      this.log('busy, skip');
      return;
    }
    this.busy = true;
    try {
      for (const p of PAGES) {
        const t0: number = Date.now();
        const pm: image.PixelMap = await this.decode(p.rawName);
        const info: image.ImageInfo = await pm.getImageInfo();
        this.log(`${p.label} decoded ${info.size.width}x${info.size.height} in ${Date.now() - t0}ms`);

        const progress: OcrProgressCallback = (percent: number, text: string) => {
          hilog.debug(DOMAIN, TAG, '%{public}s progress %{public}d %{public}s', p.label, percent, text);
        };
        const t1: number = Date.now();
        const results = await OcrService.recognize([pm], progress);
        const lines: string[] = results.length > 0 ? results[0].lines : [];
        this.log(`${p.label} ocr ${Date.now() - t1}ms lines=${lines.length}`);
        this.log(`${p.label} BEGIN`);
        for (let i: number = 0; i < lines.length; i++) {
          this.log(`${p.label}|${i}|${lines[i]}`);
        }
        this.log(`${p.label} END`);
        await pm.release();
      }
      this.log('ALL_DONE');
    } catch (err) {
      this.log(`FAIL: ${JSON.stringify(err)}`);
    }
    this.busy = false;
  }

  build() {
    Column() {
      Text('HMS OCR 同图对比探针').fontSize(20).fontWeight(FontWeight.Bold).margin({ top: 12 })
      Row({ space: 10 }) {
        Button('重跑').onClick(() => this.run())
        Button('清日志').onClick(() => {
          this.logLines = [];
        })
      }.margin(8)

      Scroll() {
        Column() {
          ForEach(this.logLines, (line: string, idx: number) => {
            Text(line).fontSize(12).fontFamily('monospace').margin({ bottom: 2 })
          }, (line: string, idx: number) => `${idx}-${line}`)
        }.alignItems(HorizontalAlign.Start).width('100%').padding(8)
      }
      .layoutWeight(1)
      .width('100%')
      .backgroundColor('#101418')
      .scrollBar(BarState.Auto)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F1F3F5')
  }
}
