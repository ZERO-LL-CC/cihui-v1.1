/**
 * 本地状态文件（qa19 新增）。
 *
 * 背景：F1–F16 按约定用内存数组做临时仓库，杀进程/重装后数据归零；
 * 用户实测「杀进程重进打卡记录消失」（动态 QA BUG-B），因此在不引入后端、
 * 不改变内存仓库架构的前提下，把 AppData 与账号资料自动落盘到应用沙箱
 * filesDir/cihui/state，每次提交实时写盘，启动时读回。
 *
 * 导出/导入 JSON 备份仍走 LocalFileSyncService（用户自选位置、换机载体），
 * 本文件只负责「杀进程不丢」的本机自动持久化。
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';

export class LocalStateFiles {
  private static dir: string = '';

  /** EntryAbility.onCreate 调用一次，建好沙箱目录 */
  static boot(context: common.Context): void {
    if (LocalStateFiles.dir !== '') {
      return;
    }
    LocalStateFiles.dir = `${context.filesDir}/cihui/state`;
    try {
      fs.mkdirSync(LocalStateFiles.dir, true);
    } catch (_e) {
      // 目录已存在时 mkdir 可能抛错，忽略
    }
  }

  /** 整文件覆盖写；未 boot（无上下文）时静默降级为纯内存 */
  static write(name: string, content: string): void {
    if (LocalStateFiles.dir === '') {
      return;
    }
    const path: string = `${LocalStateFiles.dir}/${name}`;
    const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, content);
    } finally {
      fs.closeSync(file);
    }
  }

  /** 读文本；文件不存在或未 boot 返回 null */
  static read(name: string): string | null {
    if (LocalStateFiles.dir === '') {
      return null;
    }
    const path: string = `${LocalStateFiles.dir}/${name}`;
    try {
      fs.accessSync(path);
    } catch (_e) {
      return null;
    }
    try {
      return fs.readTextSync(path);
    } catch (_e) {
      return null;
    }
  }

  /** 删除文件（退出登录清账号资料用）；不存在不报错 */
  static remove(name: string): void {
    if (LocalStateFiles.dir === '') {
      return;
    }
    const path: string = `${LocalStateFiles.dir}/${name}`;
    try {
      fs.accessSync(path);
      fs.unlinkSync(path);
    } catch (_e) {
      // 不存在即视为已删除
    }
  }
}
