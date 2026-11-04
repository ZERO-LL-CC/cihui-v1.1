/**
 * 本地状态文件（qa19 新增；多账号分区为后续扩展）。
 *
 * 目录结构：
 *   filesDir/cihui/state/profile.json             ← 全局：当前登录账号
 *   filesDir/cihui/state/accounts.json            ← 全局：本机账号表
 *   filesDir/cihui/state/u/<accountId>/data.json  ← 账号私有：词本/进度/打卡
 *
 * 全局区（writeGlobal / readGlobal）始终指向 state 根目录，供 AuthStore 与账号表使用；
 * 分区（write / read）指向 u/<accountId>，由 bindAccount 切换，供 DataStore 使用。
 *
 * 分区的原因：换账号不能看到上个账号的打卡与进度（历史实现共用一个 data.json，
 * 退出登录直接清空学习数据，用户丢失真实记录）。
 *
 * 导出/导入 JSON 备份仍走 LocalFileSyncService（用户自选位置、换机载体）。
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

/** 未登录时的分区名 */
export const GUEST_ACCOUNT: string = '_guest';

export class LocalStateFiles {
  private static baseDir: string = '';
  private static dir: string = '';

  /**
   * EntryAbility.onCreate 调用一次，建好沙箱根目录。
   * 此处**不绑定**账号分区：先让 AuthStore 读出当前账号，再由它 bindAccount，
   * 否则老版本数据会在启动瞬间被迁到 _guest 分区，登录用户反而看不到。
   */
  static boot(context: common.Context): void {
    if (LocalStateFiles.baseDir !== '') {
      return;
    }
    LocalStateFiles.baseDir = `${context.filesDir}/cihui/state`;
    LocalStateFiles.mkdir(LocalStateFiles.baseDir);
  }

  private static mkdir(path: string): void {
    try {
      fs.mkdirSync(path, true);
    } catch (_e) {
      // 目录已存在时 mkdir 可能抛错，忽略
    }
  }

  /**
   * 判断文件/目录是否存在。
   * 注意：不能用 fs.accessSync —— 实测对不存在的路径**不抛错**，会让存在性判断恒为 true，
   * 导致老数据迁移被误判为「目标已存在」而整批跳过。statSync 的行为可靠。
   */
  private static exists(path: string): boolean {
    try {
      fs.statSync(path);
      return true;
    } catch (_e) {
      return false;
    }
  }

  /** accountId 来自 unionID / 邮箱哈希，仍需过滤掉路径分隔符，防目录穿越 */
  private static safeId(id: string): string {
    const cleaned: string = id.replace(/[^A-Za-z0-9_-]/g, '_');
    return cleaned === '' ? GUEST_ACCOUNT : cleaned;
  }

  /**
   * 切换到指定账号分区。
   * 老版本单目录（state/*.json）首次升级时迁移到当前分区，避免用户数据凭空消失。
   */
  static bindAccount(accountId: string): void {
    if (LocalStateFiles.baseDir === '') {
      return;
    }
    const id: string = LocalStateFiles.safeId(accountId);
    const next: string = `${LocalStateFiles.baseDir}/u/${id}`;
    LocalStateFiles.mkdir(next);
    LocalStateFiles.migrateLegacy(next);
    LocalStateFiles.dir = next;
  }

  /** 进程内只迁移一次：老文件搬进分区后即删除，避免被复制到后续每个账号 */
  private static migrated: boolean = false;

  private static migrateLegacy(nextDir: string): void {
    if (LocalStateFiles.migrated) {
      return;
    }
    LocalStateFiles.migrated = true;
    // 用局部数组而非静态字段：ArkTS 静态数组在跨方法访问时效期不稳
    const legacyFiles: string[] = [
      'data.json',
      'study-session.json',
      'round-draft-browse.json',
      'round-draft-speech.json',
    ];
    hilog.info(0x0000, 'CihuiState', 'migrate → %{public}s files=%{public}d', nextDir, legacyFiles.length);
    for (let i = 0; i < legacyFiles.length; i++) {
      const name: string = legacyFiles[i];
      const src: string = `${LocalStateFiles.baseDir}/${name}`;
      const dst: string = `${nextDir}/${name}`;
      let text: string = '';
      try {
        text = fs.readTextSync(src);
      } catch (e) {
        hilog.info(0x0000, 'CihuiState', 'skip %{public}s: %{public}s', name, JSON.stringify(e));
        continue;
      }
      if (LocalStateFiles.exists(dst)) {
        hilog.info(0x0000, 'CihuiState', 'dst exists, skip %{public}s', name);
        continue;
      }
      try {
        LocalStateFiles.writeTo(nextDir, name, text);
        fs.unlinkSync(src);
        hilog.info(0x0000, 'CihuiState', 'migrated %{public}s len=%{public}d', name, text.length);
      } catch (e) {
        hilog.warn(0x0000, 'CihuiState', 'write %{public}s failed: %{public}s', name, JSON.stringify(e));
      }
    }
  }

  /** 当前分区标识（供日志与备份命名） */
  static currentAccount(): string {
    if (LocalStateFiles.dir === '') {
      return GUEST_ACCOUNT;
    }
    const parts: string[] = LocalStateFiles.dir.split('/');
    return parts[parts.length - 1];
  }

  private static writeTo(dir: string, name: string, content: string): void {
    if (dir === '') {
      return;
    }
    const path: string = `${dir}/${name}`;
    const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, content);
    } finally {
      fs.closeSync(file);
    }
  }

  private static readFrom(dir: string, name: string): string | null {
    if (dir === '') {
      return null;
    }
    const path: string = `${dir}/${name}`;
    if (!LocalStateFiles.exists(path)) {
      return null;
    }
    try {
      return fs.readTextSync(path);
    } catch (_e) {
      return null;
    }
  }

  private static removeFrom(dir: string, name: string): void {
    if (dir === '') {
      return;
    }
    const path: string = `${dir}/${name}`;
    try {
      if (LocalStateFiles.exists(path)) {
        fs.unlinkSync(path);
      }
    } catch (_e) {
      // 不存在即视为已删除
    }
  }

  /* ---------- 当前账号分区 ---------- */

  /** 整文件覆盖写；未 boot（无上下文）时静默降级为纯内存 */
  static write(name: string, content: string): void {
    LocalStateFiles.writeTo(LocalStateFiles.dir, name, content);
  }

  static read(name: string): string | null {
    return LocalStateFiles.readFrom(LocalStateFiles.dir, name);
  }

  static remove(name: string): void {
    LocalStateFiles.removeFrom(LocalStateFiles.dir, name);
  }

  /* ---------- 全局区（不随账号切换） ---------- */

  static writeGlobal(name: string, content: string): void {
    LocalStateFiles.writeTo(LocalStateFiles.baseDir, name, content);
  }

  static readGlobal(name: string): string | null {
    return LocalStateFiles.readFrom(LocalStateFiles.baseDir, name);
  }

  static removeGlobal(name: string): void {
    LocalStateFiles.removeFrom(LocalStateFiles.baseDir, name);
  }
}
