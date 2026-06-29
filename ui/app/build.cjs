'use strict';
// Custom esbuild-based build script — used when vite build is unavailable
// (e.g. seccomp environments that block CJS-from-ESM import interop).
const esbuild  = require('./node_modules/esbuild/lib/main.js');
const tsc      = require('./node_modules/typescript/lib/typescript.js');
const path     = require('path');
const fs       = require('fs');

const root = __dirname;
const outdir = path.join(root, 'dist');

// ── 1. TypeScript type-check (noEmit) ────────────────────────────────────
const configFile = tsc.findConfigFile(root, tsc.sys.fileExists, 'tsconfig.json');
const { config } = tsc.readConfigFile(configFile, tsc.sys.readFile);
const parsed = tsc.parseJsonConfigFileContent(config, tsc.sys, root);
const program = tsc.createProgram(parsed.fileNames, parsed.options);
const diags = [
  ...program.getSyntacticDiagnostics(),
  ...program.getSemanticDiagnostics(),
].filter(d => d.category === tsc.DiagnosticCategory.Error);

if (diags.length) {
  const host = tsc.createCompilerHost({});
  console.error(tsc.formatDiagnosticsWithColorAndContext(diags, host));
  process.exit(1);
}
console.log('tsc: no type errors');

// ── 2. Bundle with esbuild ────────────────────────────────────────────────
fs.rmSync(outdir, { recursive: true, force: true });
fs.mkdirSync(outdir, { recursive: true });

esbuild.buildSync({
  entryPoints: [path.join(root, 'src/main.tsx')],
  bundle: true,
  platform: 'browser',
  format: 'esm',
  outfile: path.join(outdir, 'main.js'),
  minify: true,
  sourcemap: false,
  loader: { '.tsx': 'tsx', '.ts': 'ts', '.css': 'css' },
  define: { 'process.env.NODE_ENV': '"production"' },
  logLevel: 'info',
});

// ── 3. Emit index.html ────────────────────────────────────────────────────
const html = fs.readFileSync(path.join(root, 'index.html'), 'utf8')
  .replace('<script type="module" src="/src/main.tsx"></script>',
           '<script type="module" src="/main.js"></script>');
fs.writeFileSync(path.join(outdir, 'index.html'), html);

console.log('build complete → dist/');
