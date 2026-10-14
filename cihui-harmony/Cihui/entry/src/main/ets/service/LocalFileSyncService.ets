/**
 * F15 同步服务（本期本地实现）。
 *
 * SyncService 接口（云端实现位 TODO）：backupNow / exportToFile / importFromFile / status。
 * 本期无后端：
 * - backupNow：把全量数据 + 账号资料写成 JSON（应用沙箱 filesDir/cihui/backup），
 *   用短暂延时模拟网络同步并驱动「同步中 → 已同步/失败」状态；
 * - exportToFile：系统文档保存选择器，让用户把 .json 备份存到自选位置（换机载体）；
 * - importFromFile：系统文档选择器选回备份，先把本机现状另存「恢复前本地副本」，
 *   再按时间戳合并恢复（合并规则见 SyncCore），不覆盖、可回退；
 * - simulateWipe：验收用「模拟换机」，只清学习数据、保留登录。
 *
 * 安全标注（云端实现时必须落实，当前本地文件未加密）：
 * TODO(F15-cloud) 备份文件落盘与传输需加密（建议 AES-GCM，密钥经 HUKS 管理），
 *                  云端通道、账号鉴权与多端实时同步属二期，方案随开放问题 Q8 定稿。
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { picker } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { DataStore } from '../viewmodel/DataStore';
import { AuthStore, UserProfile } from '../viewmodel/AuthStore';
import { SyncStore } from '../viewmodel/SyncStore';
import {
  buildBackup,
  mergeAppData,
  mergeProfile,
  parseBackup,
} from '../model/SyncCore';
import type { BackupFile, MergeSummary, ProfileSnapshot } from '../model/SyncCore';
import type { AppData } from '../model/RepoCore';

/** 同步操作结果（UI 直接展示 message） */
export interface SyncOutcome {
  ok: boolean;
  message: string;
}

/** 恢复结果，附合并后的数量统计 */
export interface ImportOutcome extends SyncOutcome {
  summary: MergeSummary | null;
}

/** 同步服务接口：云端实现按此契约替换本地实现 */
export interface SyncService {
  backupNow(context: common.Context, silent: boolean): Promise<SyncOutcome>;
  exportToFile(context: common.Context): Promise<SyncOutcome>;
  importFromFile(context: common.Context): Promise<ImportOutcome>;
}

function pad2(n: number): string {
  return n < 10 ? `0${n}` : `${n}`;
}

function stampOf(ts: number): string {
  const d: Date = new Date(ts);
  return `${d.getFullYear()}${pad2(d.getMonth() + 1)}${pad2(d.getDate())}`
    + `-${pad2(d.getHours())}${pad2(d.getMinutes())}${pad2(d.getSeconds())}`;
}

export class LocalFileSyncService implements SyncService {
  static readonly INSTANCE: LocalFileSyncService = new LocalFileSyncService();
  private static readonly DELAY_MS: number = 600;

  private constructor() {
  }

  private profileSnapshot(): ProfileSnapshot | null {
    const p: UserProfile | null = AuthStore.INSTANCE.profile;
    if (p === null) {
      return null;
    }
    const snap: ProfileSnapshot = {
      name: p.name,
      phone: p.phone,
      email: p.email,
      wechat: p.wechat,
      qq: p.qq,
      cloudEnabled: p.cloudEnabled,
    };
    return snap;
  }

  private backupJson(now: number): string {
    const file: BackupFile = buildBackup(
      JSON.parse(DataStore.INSTANCE.snapshot()) as AppData,
      this.profileSnapshot(),
      now,
    );
    return JSON.stringify(file);
  }

  private backupDir(context: common.Context): string {
    return `${context.filesDir}/cihui/backup`;
  }

  /** 写沙箱内文件（自动建目录） */
  private writeInternal(context: common.Context, relPath: string, content: string): void {
    const dir: string = this.backupDir(context);
    try {
      fs.mkdirSync(dir, true);
    } catch (_e) {
      // 目录已存在时 mkdir 可能抛错，忽略
    }
    const path: string = `${dir}/${relPath}`;
    const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, content);
    } finally {
      fs.closeSync(file);
    }
  }

  private readInternal(context: common.Context, relPath: string): string | null {
    const path: string = `${this.backupDir(context)}/${relPath}`;
    try {
      fs.accessSync(path);
    } catch (_e) {
      return null;
    }
    return fs.readTextSync(path);
  }

  private delay(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void): void => {
      setTimeout(resolve, ms);
    });
  }

  private enableCloudFlag(): void {
    const p: UserProfile | null = AuthStore.INSTANCE.profile;
    if (p !== null && !p.cloudEnabled) {
      AuthStore.INSTANCE.updateProfile({ cloudEnabled: true });
    }
  }

  async backupNow(context: common.Context, silent: boolean): Promise<SyncOutcome> {
    SyncStore.INSTANCE.setSyncing();
    try {
      const now: number = Date.now();
      const content: string = this.backupJson(now);
      // 模拟网络同步耗时（云端实现替换为真实上传）
      await this.delay(LocalFileSyncService.DELAY_MS);
      this.writeInternal(context, 'latest.json', content);
      this.writeInternal(context, `cihui-backup-${stampOf(now)}.json`, content);
      this.enableCloudFlag();
      SyncStore.INSTANCE.setSynced(now);
      const outcome: SyncOutcome = { ok: true, message: silent ? '' : '备份完成' };
      return outcome;
    } catch (e) {
      const reason: string = (e as Error)?.message ?? '备份失败';
      SyncStore.INSTANCE.setFailed(reason);
      return { ok: false, message: `备份失败：${reason}` };
    }
  }

  async exportToFile(context: common.Context): Promise<SyncOutcome> {
    try {
      const now: number = Date.now();
      const content: string = this.backupJson(now);
      const options: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
      options.newFileNames = [`词慧备份-${stampOf(now)}.json`];
      options.fileSuffixChoices = ['词慧备份|.json'];
      const viewPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker();
      const uris: string[] = await viewPicker.save(options);
      if (!uris || uris.length === 0) {
        return { ok: false, message: '已取消导出' };
      }
      const file = fs.openSync(uris[0], fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, content);
      } finally {
        fs.closeSync(file);
      }
      this.enableCloudFlag();
      SyncStore.INSTANCE.setSynced(now);
      return { ok: true, message: '备份文件已导出' };
    } catch (e) {
      const reason: string = (e as Error)?.message ?? '导出失败';
      SyncStore.INSTANCE.setFailed(reason);
      return { ok: false, message: `导出失败：${reason}` };
    }
  }

  private readPickerUri(uri: string): string {
    const file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
    try {
      const stat = fs.statSync(file.fd);
      // 动态QA BUG-07：fs.readSync 第二参必须是 ArrayBuffer，传 Uint8Array 运行期报
      // "Invalid arraybuffer or options"，导致导入恢复必失败
      const ab: ArrayBuffer = new ArrayBuffer(stat.size);
      fs.readSync(file.fd, ab);
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
      return decoder.decodeWithStream(new Uint8Array(ab));
    } finally {
      fs.closeSync(file);
    }
  }

  async importFromFile(context: common.Context): Promise<ImportOutcome> {
    let uris: string[] = [];
    try {
      const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      options.fileSuffixFilters = ['词慧备份|.json'];
      const viewPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker();
      uris = await viewPicker.select(options);
    } catch (e) {
      return { ok: false, message: `打开文件失败：${(e as Error)?.message ?? ''}`, summary: null };
    }
    if (!uris || uris.length === 0) {
      return { ok: false, message: '已取消恢复', summary: null };
    }
    try {
      const text: string = this.readPickerUri(uris[0]);
      const backup: BackupFile = parseBackup(text);

      // 恢复前先把本机现状另存本地副本（保留本地副本，可回退）
      const now: number = Date.now();
      const safetyJson: string = this.backupJson(now);
      this.writeInternal(context, `before-restore-${stampOf(now)}.json`, safetyJson);

      // 本机最近一次备份时间（无则视为 0，备份文件更新）
      const localRaw: string | null = this.readInternal(context, 'latest.json');
      let localExportedAt: number = 0;
      if (localRaw !== null) {
        try {
          localExportedAt = parseBackup(localRaw).exportedAt;
        } catch (_e) {
          localExportedAt = 0;
        }
      }
      const localData: AppData = JSON.parse(DataStore.INSTANCE.snapshot()) as AppData;
      const merged = mergeAppData(localData, backup.appData, backup.exportedAt > localExportedAt);
      DataStore.INSTANCE.restore(JSON.stringify(merged.data));

      // 账号：已登录以当前账号为准；未登录（换机）恢复备份资料
      const mergedProfile: ProfileSnapshot | null = mergeProfile(this.profileSnapshot(), backup.profile);
      if (AuthStore.INSTANCE.profile === null && mergedProfile !== null) {
        const p: UserProfile = new UserProfile();
        p.name = mergedProfile.name;
        p.phone = mergedProfile.phone;
        p.email = mergedProfile.email;
        p.wechat = mergedProfile.wechat;
        p.qq = mergedProfile.qq;
        p.cloudEnabled = mergedProfile.cloudEnabled;
        AuthStore.INSTANCE.login(p);
      }
      SyncStore.INSTANCE.setSynced(now);
      return {
        ok: true,
        message: `恢复完成：词本 ${merged.summary.books} 本、单词 ${merged.summary.words} 个，本机原数据已留存副本`,
        summary: merged.summary,
      };
    } catch (e) {
      const reason: string = (e as Error)?.message ?? '恢复失败';
      SyncStore.INSTANCE.setFailed(reason);
      return { ok: false, message: `恢复失败：${reason}（本机数据未改动）`, summary: null };
    }
  }

  /** 验收辅助：模拟换机——清空本机学习数据，保留登录账号 */
  simulateWipe(): SyncOutcome {
    DataStore.INSTANCE.resetForTest();
    SyncStore.INSTANCE.reset();
    return { ok: true, message: '已模拟换机：本机学习数据已清空，账号仍登录' };
  }
}
