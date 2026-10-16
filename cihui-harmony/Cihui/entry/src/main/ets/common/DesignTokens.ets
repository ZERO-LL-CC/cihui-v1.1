/**
 * 词慧设计令牌（F1）：颜色 / 字号 / 圆角 / 动效曲线时长，全局唯一来源。
 * 字号数值默认单位 fp，自动跟随系统字号缩放。
 */
import { curves } from '@kit.ArkUI';

export class Colors {
  static readonly BRAND: string = '#0A59F7';
  static readonly BRAND_PRESSED: string = '#0846C0';
  static readonly BRAND_SOFT: string = '#E9F0FE';
  static readonly TEXT_MAIN: string = '#17202E';
  static readonly TEXT_SUB: string = '#5A6575';
  static readonly TEXT_WEAK: string = '#98A2B2';
  static readonly DIVIDER: string = '#E7EAF1';
  static readonly PAGE_BG: string = '#EDF0F6';
  static readonly WHITE: string = '#FFFFFF';
  static readonly KNOW_GREEN: string = '#179C5B';
  static readonly KNOW_GREEN_SOFT: string = '#E5F5EC';
  static readonly FUZZY_ORANGE: string = '#EC8A12';
  static readonly FUZZY_ORANGE_SOFT: string = '#FDF1DE';
  static readonly UNKNOWN_RED: string = '#E14B4B';
  static readonly UNKNOWN_RED_SOFT: string = '#FCEAEA';
  /** F12 计划大表节点色（与原型 v1.2 全文统一） */
  static readonly STAGE_NEW: string = '#EC8A12';
  static readonly STAGE_R1: string = '#179C5B';
  static readonly STAGE_R2: string = '#1FA9C9';
  static readonly STAGE_R4: string = '#6E5CF6';
  static readonly STAGE_R7: string = '#FF7A45';
  static readonly STAGE_R15: string = '#E14B4B';
  static readonly STAGE_WRONG: string = '#E14B4B';
}

/** F12 复习节点 → 彩点颜色（计划表 / 小日历 / 补卡分组共用） */
export class StageColors {
  static colorOf(stage: string): string {
    if (stage === 'NEW') {
      return Colors.STAGE_NEW;
    }
    if (stage === 'R1') {
      return Colors.STAGE_R1;
    }
    if (stage === 'R2') {
      return Colors.STAGE_R2;
    }
    if (stage === 'R4') {
      return Colors.STAGE_R4;
    }
    if (stage === 'R7') {
      return Colors.STAGE_R7;
    }
    if (stage === 'R15') {
      return Colors.STAGE_R15;
    }
    if (stage === 'WRONG') {
      return Colors.STAGE_WRONG;
    }
    return Colors.TEXT_WEAK;
  }
}

export class TypeScale {
  static readonly TITLE_LARGE: number = 26;
  static readonly CARD_TITLE: number = 17;
  static readonly BODY: number = 15;
  static readonly CAPTION: number = 12;
}

export class Radius {
  static readonly CARD: number = 20;
  static readonly SHEET: number = 24;
  static readonly BUTTON: number = 16;
  static readonly CONTROL: number = 12;
}

/** 动效令牌；减弱动效时由调用方降级为透明度渐变 */
export class Motion {
  static readonly MICRO: number = 120;
  static readonly FEEDBACK: number = 200;
  static readonly SHEET: number = 280;
  static readonly PAGE: number = 320;
  static readonly REDUCED: number = 240;
  static readonly STAGGER_STEP: number = 50;
  /** 页面转场 cubic-bezier(.2,0,0,1) */
  static pageCurve(): ICurve {
    return curves.cubicBezierCurve(0.2, 0, 0, 1);
  }
  /** 底部升起 sheet cubic-bezier(.05,.7,.1,1) */
  static sheetCurve(): ICurve {
    return curves.cubicBezierCurve(0.05, 0.7, 0.1, 1);
  }
}

/** 最小可点击热区 44vp */
export class TouchTarget {
  static readonly MIN: number = 44;
}

/**
 * 悬浮胶囊 Tab（Index.FloatingBar）：栏体布局与页面内容避让同源，禁止再写魔数。
 * CLEARANCE = 内容需避让的高度，初值由「栏体高 + 外距 + 安全间距」估算，
 * 真机 dumpLayout 实测「屏高 − 栏体顶边」后校正（详见设计说明第 12 章）。
 */
export class FloatingTab {
  static readonly HEIGHT: number = 64;
  /** 胶囊内层内容高度 */
  static readonly CONTENT_HEIGHT: number = 56;
  static readonly MARGIN: number = 10;
  static readonly SAFE_GAP: number = 8;
  /** 内容底部需预留的避让高度（实测反推，非理论值） */
  static readonly CLEARANCE: number = 82;
}
