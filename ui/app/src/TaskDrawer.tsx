import { useCallback, useEffect, useRef, useState } from 'react'
import { command, deleteComment, fetchComments, fetchTask, resolveDecision, type IssueComment, type Task, type TaskDetail } from './api'
import { animateOverlayOut, elapsed, type Toast } from './ui-interactions'

function parseCheckboxes(body: string): { index: number; checked: boolean; text: string }[] {
  if (!body) return []
  const lines = body.split('\n')
  const result: { index: number; checked: boolean; text: string }[] = []
  let idx = 0
  for (const line of lines) {
    const m = line.match(/^\s*[-*]\s+\[([ xX])\]\s*(.*)$/)
    if (m) {
      result.push({ index: idx++, checked: m[1].toLowerCase() === 'x', text: m[2].trim() })
    }
  }
  return result
}

/** History marker prefixes emitted by set-check */
const HISTORY_MARKERS = ['✅ выполнено:', '↩️ снята отметка:']

export default function TaskDrawer({ n, task, onClose, onAction, ask, mergeBlockReason }: {
  n: number; task: Task | null; onClose: () => void
  onAction: (a: string, n?: number, comment?: string) => void; ask: (t: string, b: string, ok: (reason?: string) => void, withInput?: boolean) => void
  mergeBlockReason: string | undefined
}) {
  const [d, setD] = useState<TaskDetail | null>(null)
  const [comments, setComments] = useState<IssueComment[]>([])
  const [commentText, setCommentText] = useState('')
  const [sending, setSending] = useState(false)
  const [resolveText, setResolveText] = useState('')
  const [resolving, setResolving] = useState(false)
  const [mergeErr, setMergeErr] = useState<string | null>(null)
  const [merging, setMerging] = useState(false)
  const [mergeVerifyOutput, setMergeVerifyOutput] = useState<string | null>(null)
  const [mergeVerifyVerdict, setMergeVerifyVerdict] = useState<string | null>(null)
  const logRef = useRef<HTMLPreElement>(null)
  const tid = useRef(0)
  const [toasts, setToasts] = useState<Toast[]>([])
  const toast = useCallback((msg: string, err?: boolean) => {
    const id = ++tid.current
    setToasts((t) => [...t, { id, msg, err }])
    setTimeout(() => setToasts((t) => t.filter((x) => x.id !== id)), 3400)
  }, [])
  const bgRef = useRef<HTMLDivElement>(null)
  const panelRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    let on = true
    const load = async () => { const x = await fetchTask(n); if (on) setD(x) }
    load(); const i = setInterval(load, 2500); return () => { on = false; clearInterval(i) }
  }, [n])
  useEffect(() => { if (logRef.current) logRef.current.scrollTop = logRef.current.scrollHeight }, [d?.log])

  const loadComments = useCallback(async () => {
    const cs = await fetchComments(n); setComments(cs)
  }, [n])
  useEffect(() => {
    loadComments()
    const i = setInterval(loadComments, 15000)
    return () => clearInterval(i)
  }, [loadComments])

  const sendComment = async () => {
    const text = commentText.trim()
    if (!text) return
    setSending(true)
    const r = await command('comment', n, text)
    setSending(false)
    toast(r.msg || (r.ok ? 'ok' : 'failed'), !r.ok)
    if (r.ok) { setCommentText(''); loadComments() }
  }

  const close = () => animateOverlayOut(bgRef, panelRef, onClose, 'right')

  const phase = d?.status.phase ?? (d?.alive ? 'running' : '—')
  const cost = d?.status.cost_usd
  const pr = d?.status.pr || task?.pr

  const checkboxItems = parseCheckboxes(d?.body ?? '')
  const historyComments = comments.filter((c) => HISTORY_MARKERS.some((p) => c.body.startsWith(p)))
  const discussionComments = comments.filter((c) => !HISTORY_MARKERS.some((p) => c.body.startsWith(p)))

  const CONVERGENCE_MARKERS = [
    'needs-rework', 'verify-merged', 're-check', 'request-changes',
    'plan failed', 'rework', 'analyst',
  ]
  const convComments = comments.filter((c) => {
    const lower = c.body.toLowerCase()
    return CONVERGENCE_MARKERS.some((m) => lower.includes(m))
  })

  return (
    <div ref={bgRef} className="drawer-bg" onClick={close}>
      <div ref={panelRef} className="drawer" onClick={(e) => e.stopPropagation()}>
        <div className="drawer-head">
          <div>
            <div className="drawer-id"><span className="num">#{n}</span>{task && <span className={'badge b-' + task.state}>{task.state}</span>}
              {d?.alive && <span className="live-tag"><span className="phase-dot" />live</span>}</div>
            <h2 className="drawer-title">{task?.title ?? 'task #' + n}</h2>
          </div>
          <button className="btn ghost" onClick={close}>✕</button>
        </div>

        <div className="drawer-stats">
          <div><span className="ds-label">phase</span><span className="ds-val">{phase}</span></div>
          {d?.started && d.alive && <div><span className="ds-label">elapsed</span><span className="ds-val">{elapsed(d.started)}</span></div>}
          {cost != null && <div><span className="ds-label">cost</span><span className="ds-val">${Number(cost).toFixed(3)}</span></div>}
          {pr && <div><span className="ds-label">pr</span><a className="ds-val pr" href={pr} target="_blank" rel="noreferrer">open ↗</a></div>}
        </div>

        {task?.kind === 'charter' && (
          <div className="convergence-section" data-testid="convergence-section">
            <div className="drawer-section">
              Convergence
              {(task.rework_n ?? 0) > 0
                ? <span className="conv-count" data-testid="conv-count">
                    {'↺'}{task.rework_n} re-check{task.rework_n === 1 ? '' : 's'}
                  </span>
                : <span className="conv-clean" data-testid="conv-clean">clean</span>
              }
            </div>
            {convComments.length > 0 ? (
              <div className="conv-feed" data-testid="conv-feed">
                {convComments.map((c) => (
                  <div key={c.id} className="conv-event">
                    <span className="conv-meta">
                      <span className="conv-author">{c.author}</span>
                      <span className="conv-ts">
                        {new Date(c.created).toLocaleString()}
                      </span>
                    </span>
                    <pre className="conv-body">
                      {c.body.length > 320 ? c.body.slice(0, 320) + '…' : c.body}
                    </pre>
                  </div>
                ))}
              </div>
            ) : (
              <div className="conv-empty" data-testid="conv-empty">no re-checks yet</div>
            )}
          </div>
        )}

        {task && task.state !== 'done' && (
          <div className="drawer-actions">
            {task.state === 'plan-review' && !task.plan_convergence_active && (
              <>
                <button className="btn sm pri" onClick={() => ask('Approve plan #' + n, "Releases this charter's tasks to be launched.", () => onAction('approve', n))}>Approve plan</button>
                <button className="btn sm ghost" onClick={() => ask('Request changes #' + n,
                  'Опишите, что нужно доработать в плане:',
                  (reason) => onAction('request-changes', n, reason),
                  true)}>Request changes</button>
              </>
            )}
            {task.state === 'plan-review' && task.plan_convergence_active && (
              <span className="dim">plan-convergence in progress</span>
            )}
            {task.state === 'approved' && task.finale_pr && (
              <>
                <button className="btn sm pri" disabled={merging || mergeBlockReason !== undefined} title={mergeBlockReason} onClick={async () => {
                  setMergeErr(null)
                  setMergeVerifyVerdict(null)
                  setMergeVerifyOutput(null)
                  setMerging(true)
                  const r = await command('merge', n)
                  setMerging(false)
                  if (!r.ok) {
                    setMergeErr(r.msg || 'merge failed')
                    if (r.verify_verdict) setMergeVerifyVerdict(r.verify_verdict)
                    if (r.verify_output) setMergeVerifyOutput(r.verify_output)
                  } else if (r.verify_verdict && r.verify_verdict !== 'green') {
                    setMergeVerifyVerdict(r.verify_verdict)
                    if (r.verify_output) setMergeVerifyOutput(r.verify_output)
                  }
                }}>{merging ? '⏳ Merging…' : 'Merge'}</button>
                {mergeErr && <span className="err-inline">{mergeErr}</span>}
                {mergeVerifyVerdict && (
                  <span className={mergeVerifyVerdict === 'green' ? 'verify-ok' : 'err-inline'}>
                    CI: {mergeVerifyVerdict}
                  </span>
                )}
                {mergeVerifyOutput && mergeVerifyVerdict !== 'green' && (
                  <details className="verify-details">
                    <summary>CI output</summary>
                    <pre className="verify-pre">{mergeVerifyOutput}</pre>
                  </details>
                )}
              </>
            )}
            {task.state === 'held'
              ? <button className="btn sm" onClick={() => onAction('unhold', n)}>Un-hold</button>
              : <button className="btn sm ghost" onClick={() => onAction('hold', n)}>Hold</button>}
          </div>
        )}

        {task && task.labels.includes('type:human-decision') && task.state !== 'done' && (
          <>
            <div className="drawer-section">Решить задачу</div>
            <div className="disc-compose">
              <textarea
                className="disc-input"
                value={resolveText}
                onChange={(e) => setResolveText(e.target.value)}
                placeholder="Текст решения (опционально)…"
                rows={3}
                data-testid="resolve-text"
              />
              <button
                className="btn sm pri"
                data-testid="resolve-submit-btn"
                disabled={resolving}
                onClick={async () => {
                  setResolving(true)
                  const r = await resolveDecision(n, resolveText)
                  setResolving(false)
                  toast(r.msg || (r.ok ? 'resolved' : 'failed'), !r.ok)
                  if (r.ok) close()
                }}
              >{resolving ? 'Решение…' : 'Решить'}</button>
            </div>
          </>
        )}

        {d?.body && (
          <>
            <div className="drawer-section">Description</div>
            <div className="task-body-prose" data-testid="task-body-prose"><pre style={{ whiteSpace: 'pre-wrap', margin: 0 }}>{d.body}</pre></div>
          </>
        )}

        {d?.prompt && <><div className="drawer-section">Brief</div><div className="brief">{d.prompt}</div></>}

        {checkboxItems.length > 0 && (
          <>
            <div className="drawer-section" data-testid="checklist-section">Checklist</div>
            <div className="checklist">
              {checkboxItems.map((item) => (
                <div
                  key={item.index}
                  className="checklist-item"
                  data-testid="checklist-item"
                  data-index={item.index}
                >
                  <span className={'checklist-box' + (item.checked ? ' checklist-box-checked' : '')} aria-hidden="true">
                    {item.checked ? '✓' : ''}
                  </span>
                  <span className={item.checked ? 'checked' : ''}>{item.text}</span>
                </div>
              ))}
            </div>
          </>
        )}

        {historyComments.length > 0 && (
          <>
            <div className="drawer-section" data-testid="history-section">История</div>
            <div className="history">
              {historyComments.map((c, i) => (
                <div key={c.id || i} className="history-entry" data-testid="history-entry">
                  <span className="history-body">{c.body}</span>
                  <span className="history-meta muted">{c.author}{c.created ? ' · ' + elapsed(c.created) : ''}</span>
                </div>
              ))}
            </div>
          </>
        )}

        <div className="drawer-section">Discussion</div>
        <div className="discussion">
          {discussionComments.length === 0
            ? <div className="disc-empty muted">no comments yet</div>
            : discussionComments.map((c, i) => (
              <div className="disc-comment" key={c.id || i} data-testid="disc-comment">
                <div className="disc-meta">
                  <span className="disc-author">{c.author}</span>
                  {c.created && <span className="disc-time muted">{elapsed(c.created)}</span>}
                  <button
                    className="btn ghost disc-del"
                    data-testid="delete-comment-btn"
                    title="Delete comment"
                    onClick={() => ask(
                      'Delete comment',
                      'Are you sure you want to delete this comment? This cannot be undone.',
                      async () => {
                        const r = await deleteComment(n, c.id)
                        if (!r.ok) toast(r.msg || 'delete failed', true)
                        else loadComments()
                      }
                    )}
                  >✕</button>
                </div>
                <div className="disc-body">{c.body}</div>
              </div>
            ))}
          <div className="disc-compose">
            <textarea
              className="disc-input"
              value={commentText}
              onChange={(e) => setCommentText(e.target.value)}
              placeholder="Leave a comment…"
              rows={3}
            />
            <button
              className="btn sm pri"
              disabled={!commentText.trim() || sending}
              onClick={sendComment}
            >{sending ? 'Sending…' : 'Send'}</button>
          </div>
        </div>
        {toasts.map((t) => <div key={t.id} className={'toast' + (t.err ? ' err' : '')}>{t.msg}</div>)}

        <div className="drawer-section">Agent log {d?.alive && <span className="muted">· live</span>}</div>
        <pre className="log" ref={logRef}>{d?.log?.trim() || (d?.alive ? 'agent working… (output appears when it streams/finishes)' : 'no log yet')}</pre>
      </div>
    </div>
  )
}
