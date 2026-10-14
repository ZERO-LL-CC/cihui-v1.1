/**
 * F15 云备份同步状态（V2 可观察）：个人页 / 账号页显示
 * 未开启 / 同步中 / 已同步（含上次时间）/ 同步失败（含原因）。
 */

export type SyncStatus = 'off' | 'syncing' | 'synced' | 'failed';

@ObservedV2
export class SyncStore {
  static readonly INSTANCE: SyncStore = new SyncStore();
  @Trace status: SyncStatus = 'off';
  @Trace lastSyncAt: number = 0;
  @Trace message: string = '';

  private constructor() {
  }

  setSyncing(): void {
    this.status = 'syncing';
    this.message = '';
  }

  setSynced(at: number): void {
    this.status = 'synced';
    this.lastSyncAt = at;
    this.message = '';
  }

  setFailed(reason: string): void {
    this.status = 'failed';
    this.message = reason;
  }

  reset(): void {
    this.status = 'off';
    this.lastSyncAt = 0;
    this.message = '';
  }

  statusText(): string {
    if (this.status === 'syncing') {
      return '同步中…';
    }
    if (this.status === 'failed') {
      return '同步失败';
    }
    if (this.status === 'synced') {
      return '云备份已开启';
    }
    return '云备份未开启';
  }
}
