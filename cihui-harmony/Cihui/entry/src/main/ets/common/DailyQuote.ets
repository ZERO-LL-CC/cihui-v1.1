/**
 * 打卡卡/成功页底部署名句。
 *
 * 规则：共 10 句，按「每 10 天轮换一句」推进，同一句在一次持久期内不重复出现，
 * 周期 100 天后回到第一句。用「本地日序 / 10」取模，跨天即稳定切换，
 * 不需要存任何状态，也不会因为重装/换机而错位。
 */
export class DailyQuote {
  /** 每句停留的天数 */
  private static readonly DAYS_PER_LINE: number = 10;

  private static readonly LINES: string[] = [
    '按艾宾浩斯节奏，今天又记住了一点',
    '一天十个词，一年就是三千六百个',
    '记不住的词，多见几次就成了老朋友',
    '今天的坚持，是明天的语感',
    '单词不是背下来的，是用出来的',
    '慢一点没关系，别停下来就好',
    '每多认一个词，世界就多开一扇窗',
    '重复不是笨办法，是最快的路',
    '你今天认下的词，明天会替你说话',
    '读得出口的词，才真正属于你'
  ];

  /** 当前该显示的那一句 */
  static current(): string {
    // 以 1970 起的本地日序为基，每 DAYS_PER_LINE 天换一句
    const dayIndex: number = Math.floor(Date.now() / 86400000);
    const slot: number = Math.floor(dayIndex / DailyQuote.DAYS_PER_LINE);
    const len: number = DailyQuote.LINES.length;
    return DailyQuote.LINES[((slot % len) + len) % len];
  }

  static count(): number {
    return DailyQuote.LINES.length;
  }
}
