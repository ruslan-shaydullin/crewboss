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
export async function fetchWithTimeout(url, init = {}, timeoutMs = 5000) {
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), timeoutMs)
  try {
    return await fetch(url, { ...init, signal: controller.signal })
  } finally {
    clearTimeout(timer)
  }
}
