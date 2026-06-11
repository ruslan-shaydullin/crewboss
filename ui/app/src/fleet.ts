/** fleet.ts — deterministic role → fleet-character mapping + XP/level helpers.
 *  No runtime deps; all derived from role name + board state. */

import type { Task } from './api'

// --- deterministic hash (djb2-like, always positive) ---
function hashStr(s: string): number {
  let h = 0
  for (let i = 0; i < s.length; i++) {
    h = (Math.imul(31, h) + s.charCodeAt(i)) | 0
  }
  return Math.abs(h)
}

// --- ship types per kind ---
const KINDS: Record<string, { ship: string; emoji: string }> = {
  manager:  { ship: 'Flagship',  emoji: '⚓' },
  analyst:  { ship: 'Scout',     emoji: '🔭' },
  executor: { ship: 'Frigate',   emoji: '⚡' },
}

const NAMES = [
  'Aurora', 'Orion',   'Nova',    'Vega',    'Atlas',
  'Hermes', 'Titan',   'Lyra',    'Cetus',   'Draco',
  'Hydra',  'Lynx',    'Pavo',    'Rigel',   'Sirius',
  'Castor', 'Pollux',  'Deneb',   'Altair',  'Fomalhaut',
]

const COLORS = [
  '#5b9cf0', '#b39bff', '#46ce8e', '#e0b64a',
  '#f0ac67', '#7dd8f0', '#c980f0', '#f06780',
  '#60d9b0', '#f0d060',
]

export type FleetChar = {
  ship:  string  // 'Flagship' | 'Scout' | 'Frigate'
  name:  string  // stable name derived from role hash
  color: string  // stable accent color derived from role hash
  emoji: string  // ship-type emoji
}

/** Deterministic fleet character for a given role.
 *  `kind` is 'manager' | 'analyst' | 'executor' (from OrgNode or guessKind). */
export function getFleetChar(role: string, kind: string): FleetChar {
  const h = hashStr(role)
  const k = KINDS[kind] ?? KINDS['executor']
  return {
    ship:  k.ship,
    name:  NAMES[h % NAMES.length],
    color: COLORS[h % COLORS.length],
    emoji: k.emoji,
  }
}

/** Heuristic kind inference from role name when OrgNode data is unavailable. */
export function guessKind(role: string): string {
  const r = role.toLowerCase()
  if (/lead|head|boss|manager|director|chief|cto|ceo|vp/.test(r)) return 'manager'
  if (/analyst|reviewer|researcher|auditor|architect/.test(r)) return 'analyst'
  return 'executor'
}

// --- XP / levels (pure derivation from board, no extra storage) ---
// XP = number of done leaf tasks on the board (team fleet XP).
// Level thresholds: 3 done per level (linear, max level 10).

const XP_PER_LEVEL = 3
const MAX_LEVEL = 10

export function computeXP(board: Task[]): number {
  return board.filter((t) => t.kind === 'leaf' && t.state === 'done').length
}

export type LevelInfo = {
  level:    number  // 1 … MAX_LEVEL
  progress: number  // done within this level band
  needed:   number  // done needed to reach next level
  xp:       number  // raw XP
}

export function xpToLevel(xp: number): LevelInfo {
  const level = Math.min(MAX_LEVEL, Math.floor(xp / XP_PER_LEVEL) + 1)
  const atMax = level === MAX_LEVEL
  const base  = (level - 1) * XP_PER_LEVEL
  const progress = atMax ? XP_PER_LEVEL : Math.min(xp - base, XP_PER_LEVEL)
  return { level, progress, needed: XP_PER_LEVEL, xp }
}
