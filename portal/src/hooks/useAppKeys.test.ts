import { describe, expect, it, vi } from 'vitest'
import type { StatusToken, TaskRow } from '../lib/types'
import { runShortcut, type AppKeyDeps } from './useAppKeys'

const row = (id: string, statusToken: StatusToken): TaskRow => ({ id, statusToken }) as TaskRow
const ROWS = [row('a', 'downloading'), row('b', 'paused'), row('c', 'completed')]

function deps(over: Partial<AppKeyDeps> = {}): AppKeyDeps {
  return {
    enabled: true,
    onEscape: vi.fn(),
    view: 'library',
    visible: ROWS,
    lead: null,
    selectedVisible: [],
    canWrite: true,
    select: vi.fn(),
    openDetail: vi.fn(),
    runBulk: vi.fn(async () => {}),
    removeMany: vi.fn(),
    openAdd: vi.fn(),
    focusSearch: vi.fn(),
    openHelp: vi.fn(),
    rowElement: vi.fn(() => undefined),
    ...over,
  }
}

describe('runShortcut', () => {
  it('moves the selection with J and K, clamped at the ends', () => {
    const d = deps({ lead: 'b' })
    expect(runShortcut('next', d)).toBe(true)
    expect(d.select).toHaveBeenLastCalledWith({ type: 'single', id: 'c' })
    runShortcut('prev', d)
    expect(d.select).toHaveBeenLastCalledWith({ type: 'single', id: 'a' })
    runShortcut('next', deps({ lead: 'c', select: d.select }))
    expect(d.select).toHaveBeenLastCalledWith({ type: 'single', id: 'c' })
  })

  it('starts J at the top and K at the bottom with nothing selected', () => {
    const d = deps()
    runShortcut('next', d)
    expect(d.select).toHaveBeenLastCalledWith({ type: 'single', id: 'a' })
    runShortcut('prev', d)
    expect(d.select).toHaveBeenLastCalledWith({ type: 'single', id: 'c' })
  })

  it('pauses anything running in the selection, else resumes', () => {
    const d = deps({ selectedVisible: [ROWS[0]!, ROWS[1]!] })
    runShortcut('toggle', d)
    expect(d.runBulk).toHaveBeenCalledWith('pause', ['a'])
    const e = deps({ selectedVisible: [ROWS[1]!] })
    runShortcut('toggle', e)
    expect(e.runBulk).toHaveBeenCalledWith('resume', ['b'])
    expect(runShortcut('toggle', deps({ selectedVisible: [ROWS[2]!] }))).toBe(false)
  })

  it('removes the selection through the confirm flow', () => {
    const d = deps({ selectedVisible: [ROWS[0]!, ROWS[2]!] })
    expect(runShortcut('remove', d)).toBe(true)
    expect(d.removeMany).toHaveBeenCalledWith(['a', 'c'])
    expect(runShortcut('remove', deps())).toBe(false)
  })

  it('opens the lead row, and routes help, search and add', () => {
    const d = deps({ lead: 'a', selectedVisible: [ROWS[0]!] })
    runShortcut('open', d)
    expect(d.openDetail).toHaveBeenCalledWith('a')
    runShortcut('help', d)
    runShortcut('search', d)
    runShortcut('add', d)
    expect(d.openHelp).toHaveBeenCalled()
    expect(d.focusSearch).toHaveBeenCalled()
    expect(d.openAdd).toHaveBeenCalled()
  })

  it('does nothing that changes state in a read-only session', () => {
    const d = deps({ canWrite: false, selectedVisible: [ROWS[0]!] })
    expect(runShortcut('add', d)).toBe(false)
    expect(runShortcut('toggle', d)).toBe(false)
    expect(runShortcut('remove', d)).toBe(false)
    expect(d.openAdd).not.toHaveBeenCalled()
    expect(d.runBulk).not.toHaveBeenCalled()
  })

  it('leaves library keys alone on other views', () => {
    const d = deps({ view: 'history' })
    expect(runShortcut('next', d)).toBe(false)
    expect(runShortcut('help', d)).toBe(true)
  })
})
