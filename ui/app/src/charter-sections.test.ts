import { describe, it, expect } from 'vitest'

const CHARTER_SECTIONS = [
  { key: 'sec-inprogress', label: 'В работе',  states: new Set(['approved','in-progress','plan-review','review']),                       defaultExpanded: true  },
  { key: 'sec-new',        label: 'Новые',      states: new Set(['open','needs-plan','needs-analysis','team-review','blocked','held']),  defaultExpanded: true  },
  { key: 'sec-done',       label: 'Выполнено',  states: new Set(['done','CLOSED']),                                                         defaultExpanded: false },
] as const

const findSection = (state: string) => CHARTER_SECTIONS.find((s) => (s.states as ReadonlySet<string>).has(state))

describe('charter section classification (#289)', () => {
  it('has exactly 3 sections', () => {
    expect(CHARTER_SECTIONS).toHaveLength(3)
  })

  it.each(['approved', 'in-progress', 'plan-review', 'review'])(
    '%s → В работе', (state) => {
      expect(findSection(state)?.label).toBe('В работе')
    }
  )

  it.each(['open', 'needs-plan', 'needs-analysis', 'team-review', 'blocked', 'held'])(
    '%s → Новые', (state) => {
      expect(findSection(state)?.label).toBe('Новые')
    }
  )

  it.each(['done', 'CLOSED'])(
    '%s → Выполнено', (state) => {
      expect(findSection(state)?.label).toBe('Выполнено')
    }
  )

  it('needs-analysis is NOT in В работе', () => {
    expect(findSection('needs-analysis')?.label).not.toBe('В работе')
  })

  it('team-review is NOT in В работе', () => {
    expect(findSection('team-review')?.label).not.toBe('В работе')
  })

  it('Выполнено is collapsed by default', () => {
    const done = CHARTER_SECTIONS.find((s) => s.label === 'Выполнено')
    expect(done?.defaultExpanded).toBe(false)
  })

  it('В работе and Новые are expanded by default', () => {
    const active = CHARTER_SECTIONS.filter((s) => s.label !== 'Выполнено')
    active.forEach((s) => expect(s.defaultExpanded).toBe(true))
  })
})
