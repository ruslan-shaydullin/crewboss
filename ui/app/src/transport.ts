import { demoRequest } from './demo'

export const DEMO_MODE = import.meta.env?.VITE_CREWBOSS_DEMO === '1'

export function apiRequest(url: string, options?: RequestInit): Promise<Response> {
  if (DEMO_MODE) return demoRequest(url, options)
  const authorization = new Headers(options?.headers).get('Authorization') ?? ''
  if (!authorization.startsWith('Bearer ') || !authorization.slice(7).trim()) {
    return Promise.resolve(new Response(JSON.stringify({ ok: false, msg: 'Connect to the API first' }), {
      status: 401, headers: { 'Content-Type': 'application/json' },
    }))
  }
  return fetch(url, options)
}
