import { useState } from 'react'
import { command, createIssue, facilitateMessage, type FacilitateMessage, type IssuePayload, type IssueResult, type State } from './api'

function hasValidAcceptanceBlock(text: string): boolean {
  if (!text.trim()) return false
  const lines = text.split('\n')
  let inBlock = false
  for (const line of lines) {
    if (/^## Acceptance \(machine\)/.test(line)) { inBlock = true; continue }
    if (inBlock && /^## /.test(line)) break
    if (inBlock && /^\s*- (test|check): .+/.test(line)) return true
  }
  return false
}

export default function NewIssueModal({ state, onClose, onToast }: {
  state: State | null
  onClose: () => void
  onToast: (msg: string, err?: boolean) => void
}) {
  const [kind, setKind] = useState<'charter' | 'task'>('charter')
  const [title, setTitle] = useState('')
  const [what, setWhat] = useState('')
  const [why, setWhy] = useState('')
  const [scope, setScope] = useState('')
  const [constraints, setConstraints] = useState('')
  const [acceptance, setAcceptance] = useState('')
  const [description, setDescription] = useState('')
  const [charterN, setCharterN] = useState('')
  const [dependsOn, setDependsOn] = useState('')
  const [autoPlanApprove, setAutoPlanApprove] = useState(false)
  const [autoMerge, setAutoMerge] = useState(false)
  const [submitting, setSubmitting] = useState(false)
  const [step, setStep] = useState<'form' | 'discuss' | 'summary'>('form')
  const [charterSuccess, setCharterSuccess] = useState<IssueResult | null>(null)
  const [launching, setLaunching] = useState(false)

  // Facilitator discussion state
  const [chatMessages, setChatMessages] = useState<FacilitateMessage[]>([])
  const [chatInput, setChatInput] = useState('')
  const [facilitating, setFacilitating] = useState(false)
  const [acceptanceBlock, setAcceptanceBlock] = useState('')
  const [facilitatorError, setFacilitatorError] = useState<string | null>(null)

  const charters = (state?.board ?? []).filter((x) => x.kind === 'charter')
  const charterLabel = charters.find((c) => String(c.n) === charterN)

  const isValid = kind === 'charter'
    ? !!(title.trim() && what.trim() && why.trim())
    : !!(title.trim() && description.trim() && charterN)

  const isBlockValid = hasValidAcceptanceBlock(acceptanceBlock)

  const handleFacilitate = async () => {
    const msg = chatInput.trim()
    if (!msg) return
    setChatInput('')
    const newHistory: FacilitateMessage[] = [...chatMessages, { role: 'user', content: msg }]
    setChatMessages(newHistory)
    setFacilitating(true)
    setFacilitatorError(null)
    try {
      const draft: Record<string, unknown> = kind === 'charter'
        ? { title, what, why, scope, constraints }
        : { title, description, charter: charterN, depends_on: dependsOn }
      const r = await facilitateMessage(kind, draft, msg, chatMessages)
      if (r.ok) {
        setChatMessages([...newHistory, { role: 'facilitator', content: r.message }])
        if (r.acceptance_block) {
          setAcceptanceBlock(r.acceptance_block)
        }
      } else {
        setFacilitatorError(r.message)
      }
    } finally {
      setFacilitating(false)
    }
  }

  const handleSubmit = async () => {
    if (!isValid || submitting) return
    const p: IssuePayload = kind === 'charter'
      ? { kind: 'charter', title, what, why, scope, constraints, acceptance, acceptance_block: acceptanceBlock.trim() || undefined, auto_plan_approve: autoPlanApprove, auto_merge: autoMerge }
      : { kind: 'task', title, description, charter: Number(charterN), depends_on: dependsOn.trim() || undefined, acceptance_block: acceptanceBlock.trim() || undefined }
    setSubmitting(true)
    try {
      const r = await createIssue(p)
      if (r.ok && kind === 'charter') {
        setCharterSuccess(r)
      } else {
        onToast(r.msg || (r.ok ? 'created' : 'failed'), !r.ok)
        if (r.ok) onClose()
      }
    } catch (e: unknown) {
      onToast('request failed: ' + String(e), true)
    } finally {
      setSubmitting(false)
    }
  }

  const handleLaunch = async () => {
    setLaunching(true)
    try {
      const r = await command('run')
      onToast(r.msg || (r.ok ? 'Launcher started' : 'failed'), !r.ok)
    } catch (e: unknown) {
      onToast('request failed: ' + String(e), true)
    } finally {
      setLaunching(false)
      onClose()
    }
  }

  if (charterSuccess) {
    return (
      <div className="modal-bg" data-testid="ni-success-backdrop">
        <div className="modal ni-modal" data-testid="ni-success-panel" onClick={(e) => e.stopPropagation()}>
          <div className="ni-head">
            <h3>Чартер создан</h3>
            <button className="btn ghost" onClick={onClose}>✕</button>
          </div>
          <div className="ni-success" data-testid="ni-success-msg">
            <div className="ni-success-icon">✓</div>
            <div className="ni-success-text">
              Чартер <strong>#{charterSuccess.number}</strong> успешно создан
            </div>
          </div>
          <div className="ni-run-warning" data-testid="ni-run-warning">
            ⚠ Запуск лаунчера захватит все доступные задачи и запустит реальных агентов — это тратит средства из вашего пула ($).
          </div>
          <div className="m-actions">
            <button className="btn" data-testid="ni-close-btn" onClick={onClose}>Закрыть</button>
            <button className="btn pri" data-testid="ni-launch-btn" disabled={launching} onClick={handleLaunch}>
              {launching ? 'Запуск…' : '▶ Запустить'}
            </button>
          </div>
        </div>
      </div>
    )
  }

  if (step === 'discuss') {
    return (
      <div className="modal-bg" data-testid="ni-discuss-backdrop" onClick={onClose}>
        <div className="modal ni-modal ni-discuss-modal" data-testid="ni-discuss-panel" onClick={(e) => e.stopPropagation()}>
          <div className="ni-head">
            <h3>Обсуждение с фасилитатором</h3>
            <button className="btn ghost" onClick={onClose}>✕</button>
          </div>

          {/* Chat section */}
          <div className="ni-chat" data-testid="ni-facilitator-chat">
            {chatMessages.length === 0 && !facilitatorError && (
              <div className="ni-chat-hint muted">
                Опишите что нужно — фасилитатор задаст уточняющие вопросы и предложит блок Acceptance (machine). Или заполните блок ниже вручную.
              </div>
            )}
            {facilitatorError && (
              <div className="ni-facilitator-error" data-testid="ni-facilitator-error">
                {facilitatorError}
              </div>
            )}
            {chatMessages.map((m, i) => (
              <div
                key={i}
                className={'ni-chat-msg ni-chat-' + m.role}
                data-testid="ni-chat-message"
                data-role={m.role}
              >
                <span className="ni-chat-role">{m.role === 'user' ? 'Вы' : 'Фасилитатор'}</span>
                <span className="ni-chat-content">{m.content}</span>
              </div>
            ))}
            {facilitating && <div className="ni-chat-loading muted">Фасилитатор думает…</div>}
          </div>

          {/* Chat input */}
          <div className="ni-chat-compose">
            <textarea
              className="disc-input"
              data-testid="ni-chat-input"
              value={chatInput}
              onChange={(e) => setChatInput(e.target.value)}
              onKeyDown={(e) => { if (e.key === 'Enter' && (e.ctrlKey || e.metaKey) && chatInput.trim() && !facilitating) handleFacilitate() }}
              placeholder="Ваш ответ или уточнение…"
              rows={2}
              disabled={facilitating}
            />
            <button
              className="btn sm pri"
              data-testid="ni-chat-send"
              disabled={!chatInput.trim() || facilitating}
              onClick={handleFacilitate}
            >{facilitating ? 'Отправка…' : 'Отправить'}</button>
          </div>

          {/* Acceptance block manual entry / auto-populated */}
          <div className="ni-acceptance-section">
            <label className="fld">
              <span>Acceptance (machine) <span className="ni-required">*</span></span>
              <textarea
                data-testid="ni-acceptance-input"
                className="ni-acceptance-textarea"
                value={acceptanceBlock}
                onChange={(e) => setAcceptanceBlock(e.target.value)}
                placeholder={'## Acceptance (machine)\n- check: make test\n- test: path/to/test.sh'}
                rows={5}
              />
            </label>
            {acceptanceBlock.trim() && (
              isBlockValid
                ? <div className="ni-acceptance-valid" data-testid="ni-acceptance-valid">✓ Валидный блок</div>
                : <div className="ni-acceptance-invalid" data-testid="ni-acceptance-invalid">✗ Нужен заголовок «## Acceptance (machine)» и минимум одна строка «- test: …» или «- check: …»</div>
            )}
          </div>

          <div className="m-actions">
            <button className="btn" data-testid="ni-discuss-back" onClick={() => setStep('form')}>← Назад</button>
            <button
              className="btn pri"
              data-testid="ni-discuss-continue"
              disabled={!isBlockValid}
              onClick={() => setStep('summary')}
            >Продолжить →</button>
          </div>
        </div>
      </div>
    )
  }

  if (step === 'summary') {
    return (
      <div className="modal-bg" data-testid="ni-summary-backdrop" onClick={onClose}>
        <div className="modal ni-modal ni-summary-modal" data-testid="ni-summary-panel" onClick={(e) => e.stopPropagation()}>
          <div className="ni-head">
            <h3>Подтвердить создание</h3>
            <button className="btn ghost" onClick={onClose}>✕</button>
          </div>
          <div className="ni-summary" data-testid="ni-summary-body">
            <div className="ni-summary-kind" data-testid="ni-summary-kind">
              {kind === 'charter' ? 'Charter' : 'Task'}
            </div>
            <div className="ni-summary-title" data-testid="ni-summary-title">{title}</div>
            {kind === 'charter' ? (
              <div className="ni-summary-sections">
                <div className="ni-summary-section">
                  <div className="ni-summary-label">WHAT</div>
                  <div className="ni-summary-value" data-testid="ni-summary-what">{what}</div>
                </div>
                <div className="ni-summary-section">
                  <div className="ni-summary-label">WHY</div>
                  <div className="ni-summary-value" data-testid="ni-summary-why">{why}</div>
                </div>
                {scope.trim() && (
                  <div className="ni-summary-section">
                    <div className="ni-summary-label">Скоуп</div>
                    <div className="ni-summary-value">{scope}</div>
                  </div>
                )}
                {constraints.trim() && (
                  <div className="ni-summary-section">
                    <div className="ni-summary-label">Констрейнты</div>
                    <div className="ni-summary-value">{constraints}</div>
                  </div>
                )}
                {acceptance.trim() && (
                  <div className="ni-summary-section">
                    <div className="ni-summary-label">Acceptance</div>
                    <div className="ni-summary-value">{acceptance}</div>
                  </div>
                )}
                {acceptanceBlock.trim() && (
                  <div className="ni-summary-section">
                    <div className="ni-summary-label">Acceptance (machine)</div>
                    <div className="ni-summary-value" data-testid="ni-summary-acceptance-block">{acceptanceBlock}</div>
                  </div>
                )}
              </div>
            ) : (
              <div className="ni-summary-sections">
                <div className="ni-summary-section">
                  <div className="ni-summary-label">Description</div>
                  <div className="ni-summary-value" data-testid="ni-summary-description">{description}</div>
                </div>
                <div className="ni-summary-section">
                  <div className="ni-summary-label">Charter</div>
                  <div className="ni-summary-value" data-testid="ni-summary-charter">
                    #{charterN}{charterLabel ? ` ${charterLabel.title}` : ''}
                  </div>
                </div>
                {dependsOn.trim() && (
                  <div className="ni-summary-section">
                    <div className="ni-summary-label">Depends-on</div>
                    <div className="ni-summary-value" data-testid="ni-summary-depends">#{dependsOn.trim()}</div>
                  </div>
                )}
                {acceptanceBlock.trim() && (
                  <div className="ni-summary-section">
                    <div className="ni-summary-label">Acceptance (machine)</div>
                    <div className="ni-summary-value" data-testid="ni-summary-acceptance-block">{acceptanceBlock}</div>
                  </div>
                )}
              </div>
            )}
          </div>
          <div className="m-actions">
            <button className="btn" data-testid="ni-edit-btn" onClick={() => setStep('discuss')}>Редактировать</button>
            <button className="btn pri" data-testid="ni-confirm-btn" disabled={submitting} onClick={handleSubmit}>
              {submitting ? 'Creating…' : 'Подтвердить'}
            </button>
          </div>
        </div>
      </div>
    )
  }

  return (
    <div className="modal-bg" onClick={onClose}>
      <div className="modal ni-modal" onClick={(e) => e.stopPropagation()}>
        <div className="ni-head">
          <h3>New issue</h3>
          <button className="btn ghost" onClick={onClose}>✕</button>
        </div>
        <div className="ni-tabs">
          <button className={'ni-tab' + (kind === 'charter' ? ' on' : '')} onClick={() => setKind('charter')}>Charter</button>
          <button className={'ni-tab' + (kind === 'task' ? ' on' : '')} onClick={() => setKind('task')}>Task</button>
        </div>
        <label className="fld">Title *<input value={title} onChange={(e) => setTitle(e.target.value)} placeholder="Short descriptive title" data-testid="ni-title" /></label>
        {kind === 'charter' ? (
          <>
            <label className="fld">WHAT *<textarea value={what} onChange={(e) => setWhat(e.target.value)} placeholder="What exactly needs to be built/done?" rows={2} data-testid="ni-what" /></label>
            <label className="fld">WHY *<textarea value={why} onChange={(e) => setWhy(e.target.value)} placeholder="Why is this needed? Business / user value." rows={2} data-testid="ni-why" /></label>
            <label className="fld">Scope<textarea value={scope} onChange={(e) => setScope(e.target.value)} placeholder="In-scope / out-of-scope" rows={2} /></label>
            <label className="fld">Constraints<textarea value={constraints} onChange={(e) => setConstraints(e.target.value)} placeholder="Technical, time, or budget constraints" rows={2} /></label>
            <label className="fld">Acceptance<textarea value={acceptance} onChange={(e) => setAcceptance(e.target.value)} placeholder="Acceptance criteria (checklist)" rows={3} /></label>
            <label>
              <input type="checkbox" checked={autoPlanApprove}
                     onChange={e => setAutoPlanApprove(e.target.checked)} />
              {" "}Auto-approve plan (skip manual plan-review gate for this charter)
            </label>
            <label>
              <input type="checkbox" checked={autoMerge}
                     onChange={e => setAutoMerge(e.target.checked)} />
              {" "}Auto-merge on green CI (skip manual merge gate for this charter)
            </label>
          </>
        ) : (
          <>
            <label className="fld">Description *<textarea value={description} onChange={(e) => setDescription(e.target.value)} placeholder="What this task does" rows={3} /></label>
            <label className="fld">Charter *
              <select value={charterN} onChange={(e) => setCharterN(e.target.value)}>
                <option value="">— select charter —</option>
                {charters.map((c) => <option key={c.n} value={String(c.n)}>#{c.n} {c.title}</option>)}
              </select>
            </label>
            <label className="fld">Depends-on (optional)<input value={dependsOn} onChange={(e) => setDependsOn(e.target.value)} placeholder="Issue number, e.g. 42" /></label>
          </>
        )}
        <div className="m-actions">
          <button className="btn" onClick={onClose}>Cancel</button>
          <button className="btn pri" data-testid="ni-submit" disabled={!isValid || submitting} onClick={() => { if (isValid) setStep('discuss') }}>{submitting ? 'Creating…' : 'Create'}</button>
        </div>
      </div>
    </div>
  )
}
