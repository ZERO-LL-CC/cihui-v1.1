/** MemeCore 语法/导入冒烟测试：验证修改后可被 Node 正常加载 */
import { createMemeImport } from '../entry/src/main/ets/model/MemeCore.ts';
import assert from 'node:assert';
assert.strictEqual(typeof createMemeImport, 'function');
console.log('MemeCore 冒烟通过');
