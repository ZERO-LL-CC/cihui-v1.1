/**
 * 云词本搜索历史（F5）：内存态单例，默认空列表（用户搜索后才产生数据）。
 * TODO(F15)：登录后随云备份持久化；当前杀进程清空，符合本期「内存数组临时仓库」约束。
 */
@ObservedV2
export class CloudSearchStore {
  static readonly INSTANCE: CloudSearchStore = new CloudSearchStore();
  @Trace history: string[] = [];
  private static readonly MAX: number = 10;

  private constructor() {}

  add(keyword: string): void {
    const kw: string = keyword.trim();
    if (kw.length === 0) {
      return;
    }
    const rest: string[] = this.history.filter((k: string): boolean => k !== kw);
    rest.unshift(kw);
    if (rest.length > CloudSearchStore.MAX) {
      rest.pop();
    }
    this.history = rest;
  }

  clear(): void {
    this.history = [];
  }
}
