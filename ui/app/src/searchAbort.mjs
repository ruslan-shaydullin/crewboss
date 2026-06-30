// searchAbort.mjs — single source of truth for the cockpit search's no-hang
// fetch. Plain ESM (no TypeScript), importable by stock node v18 with no
// transpile, so the behavioral no-hang proof (tests/994-search-abort.test.mjs)
// can exercise the REAL frontend abort code with zero npm dependency.
//
// charter #994 / leaf 994.2. The literal constraint: search must NEVER hang on
// a slow/degraded backend — responsiveness is the whole point.

/**
 * Race fetch(url, { ...init, signal }) against an AbortController that aborts
 * after timeoutMs. On timeout the in-flight fetch is aborted and this rejects
 * (AbortError); on network error it rejects too. The timer is always cleared in
 * `finally`. Uses the global `fetch` so tests can stub `globalThis.fetch`.
 *
 * @param {string} url
 * @param {RequestInit} [init]
 * @param {number} [timeoutMs]
 * @returns {Promise<Response>}
 */
export const DEFAULT_SEARCH_TIMEOUT_MS = 5000

export async function fetchWithTimeout(url, init = {}, timeoutMs = DEFAULT_SEARCH_TIMEOUT_MS) {
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), timeoutMs)
  try {
    return await fetch(url, { ...init, signal: controller.signal })
  } finally {
    clearTimeout(timer)
  }
}

// Resolve the cockpit API base + token without hard-depending on a browser.
// In the app, config is localStorage-backed (api.ts); in stock-node test/proof
// contexts there is no localStorage, so fall back to safe defaults. Never throws.
function resolveConfig() {
  try {
    if (typeof localStorage !== 'undefined' && localStorage) {
      return {
        url: localStorage.getItem('cb_api') || 'http://127.0.0.1:8787',
        token: localStorage.getItem('cb_token') || '',
      }
    }
  } catch { /* localStorage access denied — fall through to defaults */ }
  return { url: 'http://127.0.0.1:8787', token: '' }
}

/**
 * searchBoard(q, timeoutMs) — the cockpit board search, hardened so it can
 * NEVER hang on a slow/degraded backend (charter #994). It runs the real
 * /api/search fetch through fetchWithTimeout (AbortController), and maps a
 * timeout / abort / network error / non-ok response to `null` — the existing UI
 * contract, so the search spinner always clears. The {results} -> Task[]
 * parsing contract is unchanged. Exported here (plain ESM) so the zero-dep
 * behavioral no-hang proof can exercise the REAL search path on stock node.
 *
 * @param {string} q
 * @param {number} [timeoutMs]
 * @returns {Promise<unknown[] | null>}
 */
export async function searchBoard(q, timeoutMs) {
  const ms = timeoutMs ?? DEFAULT_SEARCH_TIMEOUT_MS
  const { url, token } = resolveConfig()
  try {
    const r = await fetchWithTimeout(
      url + '/api/search?q=' + encodeURIComponent(q),
      { headers: { Authorization: 'Bearer ' + token } },
      ms,
    )
    if (!r.ok) return null
    const data = await r.json()
    return data.results
  } catch {
    return null
  }
}
