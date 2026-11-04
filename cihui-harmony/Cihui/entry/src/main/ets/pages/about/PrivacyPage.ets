/**
 * 隐私与关于页：完整隐私政策 + 开发者信息 + Tatoeba 例句库署名。
 * 上架要求「隐私政策必须能在应用内打开」，本页内容与 AGC 提交的隐私政策一致。
 */
import { NavStore } from '../../viewmodel/NavStore';
import { Colors, TypeScale } from '../../common/DesignTokens';

interface PSection {
  title: string;
  body: string;
}

const SECTIONS: PSection[] = [
  {
    title: '说词 隐私政策',
    body: '生效日期：2026年11月5日\n\n「说词」（包名 com.cihui.word）是一款背单词应用，开发者张俞蔚。这个应用的核心功能基本都在你的手机本地完成，我们尽量少碰你的数据。'
  },
  {
    title: '一、我们用到的权限和用途',
    body: '相机：你主动点「拍照导入词表」或「拍照识词」时才申请，拍的照片只在手机本地做文字识别，不上传、不保存原图。\n\n麦克风：你用「语音快过」时申请，对着手机说出单词的中文意思，应用在本地离线判断，录音不上传也不保存。\n\n提醒：开启每日打卡提醒后，应用调用系统提醒能力定时提醒复习，随时可在设置里关闭。\n\n网络：本应用没有申请网络权限，完全离线运行，不联网、不上传。'
  },
  {
    title: '二、数据存在哪',
    body: '学习记录、词书、打卡、例句收藏，全部存在你的手机本地，我们拿不到，也不会上传到任何服务器。应用没有账号体系，无需登录或注册即可使用全部功能。'
  },
  {
    title: '三、例句从哪来',
    body: '页面里的例句是在应用打包时一次性预置进安装包的，阅读时直接读本地文件，不联网。真人例句来自开放语料库 Tatoeba（CC BY 2.0 FR 许可，需署名），少数生僻词由人工编写补充并校对。这个过程不涉及你的任何数据。'
  },
  {
    title: '四、你的权利',
    body: '权限：系统「设置 → 应用 → 说词 → 权限」里随时开或关。\n\n数据：系统「设置 → 应用 → 说词 → 存储」里清除数据，即可删掉全部本地记录。'
  },
  {
    title: '五、儿童隐私',
    body: '本应用是学习工具，不面向未满 14 周岁的儿童提供定向服务，也不会主动收集儿童的个人信息。如监护人发现儿童在使用本应用时提交了个人信息，可通过下方邮箱联系我们处理。'
  },
  {
    title: '六、本政策的更新',
    body: '政策有大的改动，会在应用内或本页面提示。'
  },
  {
    title: '七、联系我们',
    body: '开发者：张俞蔚\n邮箱：2783448353@qq.com'
  }
];

@ComponentV2
export struct PrivacyPage {
  @Builder
  TopBar() {
    Row() {
      Button() {
        Image($r('app.media.ic_back')).width(26).height(26)
      }
      .type(ButtonType.Normal).width(44).height(44).backgroundColor(Color.Transparent)
      .onClick(() => NavStore.INSTANCE.back())
      Text('隐私与关于')
        .fontSize(TypeScale.CARD_TITLE).fontWeight(FontWeight.Medium).fontColor(Colors.TEXT_MAIN)
        .layoutWeight(1).textAlign(TextAlign.Center)
      Row().width(44).height(44)
    }
    .width('100%').height(56)
  }

  build() {
    NavDestination() {
      Column() {
        this.TopBar()
        Scroll() {
          Column() {
            ForEach(SECTIONS, (s: PSection) => {
              Column() {
                Text(s.title)
                  .fontSize(s.title.indexOf('隐私政策') >= 0 ? 22 : 15)
                  .fontWeight(s.title.indexOf('隐私政策') >= 0 ? FontWeight.Bold : FontWeight.Medium)
                  .fontColor(Colors.TEXT_MAIN)
                  .width('100%')
                  .margin({ bottom: 10 })
                Text(s.body)
                  .fontSize(14)
                  .fontColor(Colors.TEXT_SUB)
                  .lineHeight(22)
                  .width('100%')
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
              .margin({ bottom: 22 })
            }, (s: PSection) => s.title)

            // 例句来源署名（CC BY 2.0 署名义务）
            Column() {
              Text('例句来源署名')
                .fontSize(15).fontWeight(FontWeight.Medium).fontColor(Colors.TEXT_MAIN)
                .width('100%').margin({ bottom: 10 })
              Text('例句来源：Tatoeba 开放语料库（CC BY 2.0 FR），部分生僻词例句由人工编写补充并校对。')
                .fontSize(14).fontColor(Colors.TEXT_SUB).lineHeight(22).width('100%')
            }
            .width('100%').alignItems(HorizontalAlign.Start)

            Column().height(60)
          }
          .width('100%')
          .padding({ left: 24, right: 24, top: 16 })
          .alignItems(HorizontalAlign.Start)
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .align(Alignment.Top)
      }
      .width('100%').height('100%').backgroundColor(Colors.PAGE_BG)
    }
    .hideTitleBar(true)
  }
}
