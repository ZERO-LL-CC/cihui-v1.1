/**
 * Node 模块解析钩子：让 SchedulerCore.ts 等源文件里无扩展名的相对导入
 * （如 `from './Types'`）在 ESM 严格解析下自动尝试追加 `.ts`。
 * 零第三方依赖，仅服务于 tests/ 目录的 Node 侧单测，不进入 ArkTS 编译。
 */
import { existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

export async function resolve(specifier, context, nextResolve) {
  if (specifier.startsWith('.') && !/\.[cm]?[jt]s$/.test(specifier)) {
    try {
      const resolved = await nextResolve(specifier, context);
      return resolved;
    } catch (err) {
      const basePath = fileURLToPath(new URL(specifier, context.parentURL));
      if (existsSync(basePath + '.ts')) {
        return nextResolve(specifier + '.ts', context);
      }
      throw err;
    }
  }
  return nextResolve(specifier, context);
}
