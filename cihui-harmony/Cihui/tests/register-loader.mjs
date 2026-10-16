/** 注册 ts-resolve-hook（node --import 入口） */
import { register } from 'node:module';
register('./ts-resolve-hook.mjs', import.meta.url);
