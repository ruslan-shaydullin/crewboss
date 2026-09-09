import { useState } from 'react'
import type { Task } from './api'

export default function QueuePanel({ queueOrder, savedOrder, board, isLoopRunning, onQueueChange, onLaunch, pendingQueue, onRemovePending, onOpen }: {
  queueOrder: number[]
  savedOrder: number[]
  board: Task[]
  isLoopRunning: boolean
  onQueueChange: (order: number[]) => Promise<void>
  onLaunch: () => Promise<void>
  pendingQueue: number[]
  onRemovePending: (n: number) => void
  onOpen: (n: number) => void
}) {
  const [isEditing, setIsEditing] = useState(false)
  const charterMap = new Map(board.filter((t) => t.kind === 'charter').map((t) => [t.n, t]))
  const isDirty = JSON.stringify(queueOrder) !== JSON.stringify(savedOrder)
  const move = (idx: number, dir: -1 | 1) => {
    const newOrder = [...queueOrder]
    const target = idx + dir
    if (target < 0 || target >= newOrder.length) return
    ;[newOrder[idx], newOrder[target]] = [newOrder[target], newOrder[idx]]
    onQueueChange(newOrder)
  }
  const remove = (idx: number) => {
    const newOrder = queueOrder.filter((_, i) => i !== idx)
    onQueueChange(newOrder)
  }
  const launchLabel = isEditing
    ? '💾 Сохранить'
    : isLoopRunning
    ? '✎ Редактировать'
    : '▶ Запустить очередь'
  const handleLaunchBtn = async () => {
    if (isEditing) {
      setIsEditing(false)
    } else if (isLoopRunning) {
      setIsEditing(true)
    } else {
      await onLaunch()
    }
  }
  return (
    <div className="queue-panel" data-testid="queue-panel">
      <div className="queue-panel__head">
        <span>Queue</span>
        <span className="queue-panel__count">{queueOrder.length}</span>
        {isDirty && (
          <span className="queue-panel__dirty" data-testid="queue-dirty-indicator" title="Unsaved changes">●</span>
        )}
      </div>
      {queueOrder.length === 0 ? (
        <div className="queue-panel__empty" data-testid="queue-empty">
          Queue is empty — click + Queue on a charter card
        </div>
      ) : (
        <ol className="queue-panel__list">
          {queueOrder.map((n, idx) => {
            const charter = charterMap.get(n)
            return (
              <li key={n} className={`queue-panel__item${charter?.stuck?.is_stuck ? " queue-panel__item--stuck" : ""}`} title={charter?.stuck?.is_stuck ? (charter.stuck?.reason ?? undefined) : undefined} data-testid="queue-item" data-n={n} onClick={() => onOpen(n)}>
                <span className="queue-panel__pos">{idx + 1}.</span>
                <span className="queue-panel__label">
                  <span className="num">#{n}</span>
                  {charter && <span className="queue-panel__title"> — {charter.title}</span>}
                </span>
                <div className="queue-panel__controls">
                  <button className="btn ghost xs" onClick={() => move(idx, -1)} disabled={idx === 0} aria-label="Move up">↑</button>
                  <button className="btn ghost xs" onClick={() => move(idx, 1)} disabled={idx === queueOrder.length - 1} aria-label="Move down">↓</button>
                  <button className="btn ghost xs" onClick={() => remove(idx)} aria-label="Remove from queue" data-testid="queue-remove-btn">✕</button>
                </div>
              </li>
            )
          })}
        </ol>
      )}
      <button
        className="queue-btn--launch"
        disabled={!isEditing && !isLoopRunning && queueOrder.length === 0}
        data-testid="queue-launch-btn"
        onClick={handleLaunchBtn}
      >
        {launchLabel}
      </button>
      {pendingQueue.length > 0 && (
        <div className="queue-panel__pending" data-testid="queue-pending-section">
          <div className="queue-panel__pending-head">Pending</div>
          <ol className="queue-panel__list">
            {pendingQueue.map((n) => {
              const charter = charterMap.get(n)
              return (
                <li key={n} className="queue-panel__item queue-panel__item--pending" data-testid="queue-pending-item" data-n={n}>
                  <span className="queue-panel__label">
                    <span className="num">#{n}</span>
                    {charter && <span className="queue-panel__title"> — {charter.title}</span>}
                  </span>
                  <button
                    className="btn sm pri"
                    data-testid="queue-pending-confirm-btn"
                    onClick={() => {
                      onQueueChange([...queueOrder, n])
                      onRemovePending(n)
                    }}
                  >Подтвердить добавление</button>
                </li>
              )
            })}
          </ol>
        </div>
      )}
    </div>
  )
}
