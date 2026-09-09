import { useRef, useState } from 'react'
import { config } from './api'
import { animateOverlayOut } from './ui-interactions'

export function Modal({ title, body, onCancel, onOk, withInput }: {
  title: string; body: string; onCancel: () => void; onOk: (reason?: string) => void; withInput?: boolean
}) {
  const [reason, setReason] = useState('')
  const bgRef = useRef<HTMLDivElement>(null)
  const panelRef = useRef<HTMLDivElement>(null)
  const cancel = () => animateOverlayOut(bgRef, panelRef, onCancel)
  const ok = () => animateOverlayOut(bgRef, panelRef, () => onOk(withInput ? reason : undefined))
  return (
    <div ref={bgRef} className="modal-bg" onClick={cancel}>
      <div ref={panelRef} className="modal" onClick={(e) => e.stopPropagation()}>
        <h3>{title}</h3><p>{body}</p>
        {withInput && (
          <label className="fld"><textarea rows={4} value={reason} onChange={(e) => setReason(e.target.value)} placeholder="Причина…" /></label>
        )}
        <div className="m-actions">
          <button className="btn" onClick={cancel}>Cancel</button>
          <button className="btn pri" disabled={withInput === true && !reason.trim()} onClick={ok}>Confirm</button>
        </div>
      </div>
    </div>
  )
}

export function SettingsModal({ onClose, onSaved }: { onClose: () => void; onSaved: () => void }) {
  const [url, setUrl] = useState(config.url)
  const [token, setToken] = useState(config.token)
  const bgRef = useRef<HTMLDivElement>(null)
  const panelRef = useRef<HTMLDivElement>(null)
  const close = () => animateOverlayOut(bgRef, panelRef, onClose)
  return (
    <div ref={bgRef} className="modal-bg" onClick={close}>
      <div ref={panelRef} className="modal" onClick={(e) => e.stopPropagation()}>
        <h3>Connection</h3>
        <label className="fld">API URL<input value={url} onChange={(e) => setUrl(e.target.value)} placeholder="http://127.0.0.1:8787" /></label>
        <label className="fld">API token<input value={token} onChange={(e) => setToken(e.target.value)} type="password" placeholder="CB_API_TOKEN" /></label>
        <p className="hint">Your token stays in this tab's memory. Reconnect after a page reload.</p>
        <div className="m-actions"><button className="btn" onClick={close}>Close</button>
          <button className="btn pri" onClick={() => { config.url = url.trim(); config.token = token.trim(); onSaved() }}>Save & reconnect</button></div>
      </div>
    </div>
  )
}
