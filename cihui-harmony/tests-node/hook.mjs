// Node ESM resolve hook：让 ArkTS 工程里无扩展名的相对 import（'./Types'）在 Node 测试环境解析到 .ts
export async function resolve(specifier, context, nextResolve) {
  if (specifier.startsWith('.') && !specifier.endsWith('.ts') && !specifier.endsWith('.mjs')) {
    try {
      return await nextResolve(specifier, context);
    } catch (err) {
      return await nextResolve(specifier + '.ts', context);
    }
  }
  return nextResolve(specifier, context);
}
