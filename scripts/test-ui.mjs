#!/usr/bin/env node
import { spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'

// Vitest's jsdom environment owns localStorage. Newer Node releases also expose
// a global Web Storage implementation that shadows jsdom unless disabled.
const env = { ...process.env }
if (process.allowedNodeEnvironmentFlags.has('--no-experimental-webstorage')) {
  env.NODE_OPTIONS = [env.NODE_OPTIONS, '--no-experimental-webstorage'].filter(Boolean).join(' ')
}

const result = spawnSync('npm', ['test', '--', '--run'], {
  cwd: fileURLToPath(new URL('../ui/app/', import.meta.url)),
  env,
  stdio: 'inherit',
})
if (result.error) console.error(result.error.message)
process.exit(result.status ?? 1)
