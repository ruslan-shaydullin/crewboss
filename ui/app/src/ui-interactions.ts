import { useEffect, useLayoutEffect, useRef, useState } from 'react'

export type Toast = { id: number; msg: string; err?: boolean; exiting?: boolean }

export function prefersReducedMotion(): boolean {
  return window.matchMedia('(prefers-reduced-motion: reduce)').matches
}

/** animate a number toward `value` (easeOutCubic) — premium count-up on change. */
export function useCountUp(value: number, ms = 600): number {
  const [n, setN] = useState(value)
  const from = useRef(value)
  useEffect(() => {
    const a = from.current, b = value
    if (a === b) { setN(b); return }
    if (prefersReducedMotion()) { from.current = b; setN(b); return }
    let raf = 0, start = 0
    const tick = (t: number) => {
      if (!start) start = t
      const p = Math.min(1, (t - start) / ms)
      const e = 1 - Math.pow(1 - p, 3)
      setN(a + (b - a) * e)
      if (p < 1) raf = requestAnimationFrame(tick); else { from.current = b; setN(b) }
    }
    raf = requestAnimationFrame(tick)
    return () => cancelAnimationFrame(raf)
  }, [value, ms])
  return n
}

/** Relative position of an element within its FLIP container. */
type FlipPos = { left: number; top: number }

/**
 * FLIP hook: measures children by data-flip-key before/after renders and
 * plays translate animations for moved items.
 *
 * Positions are read from offsetLeft/offsetTop (the LAYOUT box, relative to
 * offsetParent) — NOT getBoundingClientRect, which includes the element's
 * current CSS transform. A transform-inclusive read makes the hook ingest its
 * own in-flight .animate() output (and the `.task` `rise` entry animation),
 * fabricating a phantom ~5px delta on every render → a self-sustaining jitter
 * that fires on every idle re-render (e.g. the 1s setTick). offsetTop/offsetLeft
 * are transform-free, so an idle render yields dy=0 and nothing animates; cards
 * only FLIP on a genuine layout change (real reorder / add / remove).
 */
export function useFlip(containerRef: React.RefObject<HTMLElement | null>) {
  const snapshot = useRef<Map<string, FlipPos>>(new Map())

  useLayoutEffect(() => {
    const el = containerRef.current
    if (!el) return

    const prev = snapshot.current
    const reduced = prefersReducedMotion()

    // INVERT + PLAY: animate children from old layout positions to new
    Array.from(el.children).forEach((child) => {
      const c = child as HTMLElement
      const key = c.dataset.flipKey
      if (!key) return
      const oldPos = prev.get(key)
      if (!oldPos) return
      const dx = oldPos.left - c.offsetLeft
      const dy = oldPos.top - c.offsetTop
      if ((Math.abs(dx) < 0.5 && Math.abs(dy) < 0.5) || reduced) return
      c.animate(
        [{ transform: `translate(${dx}px,${dy}px)` }, { transform: 'none' }],
        { duration: 300, easing: 'cubic-bezier(.2,.7,.2,1)' }
      )
    })

    // FIRST (for next render): snapshot current layout positions (transform-free)
    const next = new Map<string, FlipPos>()
    Array.from(el.children).forEach((child) => {
      const c = child as HTMLElement
      const key = c.dataset.flipKey
      if (key) next.set(key, { left: c.offsetLeft, top: c.offsetTop })
    })
    snapshot.current = next
  })
}

export function animateOverlayOut(
  bgRef: React.RefObject<HTMLElement | null>,
  panelRef: React.RefObject<HTMLElement | null>,
  done: () => void,
  slideDir: 'scale' | 'right' = 'scale'
) {
  if (prefersReducedMotion() || !bgRef.current || !panelRef.current) { done(); return }
  const dur = 180
  bgRef.current.animate([{ opacity: 1 }, { opacity: 0 }], { duration: dur, easing: 'ease-in', fill: 'forwards' })
  const panelKf = slideDir === 'right'
    ? [{ transform: 'translateX(0)', opacity: 1 }, { transform: 'translateX(40px)', opacity: 0 }]
    : [{ transform: 'scale(1)', opacity: 1 }, { transform: 'scale(.97)', opacity: 0 }]
  panelRef.current.animate(panelKf, { duration: dur, easing: 'ease-in', fill: 'forwards' })
  setTimeout(done, dur + 10)
}

export function elapsed(iso: string): string {
  if (!iso) return ''
  const t = Date.parse(iso); if (isNaN(t)) return ''
  let s = Math.max(0, Math.floor((Date.now() - t) / 1000))
  const m = Math.floor(s / 60); s = s % 60
  return m > 0 ? `${m}m ${s}s` : `${s}s`
}
