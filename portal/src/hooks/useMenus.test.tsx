import { renderHook } from '@testing-library/react'
import type { ReactNode } from 'react'
import { I18nextProvider } from 'react-i18next'
import { describe, expect, it, vi } from 'vitest'
import type { MenuItem, MenuState } from '../components/ui/Menu'
import i18n from '../i18n'
import type { StatusToken, TaskRow } from '../lib/types'
import { useMenus } from './useMenus'

function wrapper({ children }: { children: ReactNode }) {
  return <I18nextProvider i18n={i18n}>{children}</I18nextProvider>
}

const row = (id: string, statusToken: StatusToken): TaskRow =>
  ({ id, name: `${id}.iso`, statusToken, kind: 'http', source: `https://x/${id}` }) as TaskRow

const TASKS = [row('a', 'downloading'), row('b', 'paused'), row('c', 'downloading')]

function setup(selected: string[]) {
  const deps = {
    tasks: TASKS,
    selectedIds: new Set(selected),
    selectedVisible: TASKS.filter((t) => selected.includes(t.id)),
    canWrite: true,
    select: vi.fn(),
    openMenu: vi.fn<(m: MenuState) => void>(),
    copy: vi.fn(),
    toast: vi.fn(),
    runAction: vi.fn(async () => {}),
    runBulk: vi.fn(async () => {}),
    removeTask: vi.fn(),
    removeMany: vi.fn(),
  }
  const { result } = renderHook(() => useMenus(deps), { wrapper })
  const labels = () =>
    deps.openMenu.mock.calls[0]![0].entries
      .filter((e): e is MenuItem => !('separator' in e))
      .map((e) => e.label)
  const pick = (label: string) =>
    deps.openMenu.mock.calls[0]![0].entries
      .filter((e): e is MenuItem => !('separator' in e))
      .find((e) => e.label === label)!
      .action()
  return { result, deps, labels, pick }
}

describe('useMenus', () => {
  it('acts on the whole selection when the row is inside a multi-selection', () => {
    const { result, deps, labels, pick } = setup(['a', 'b', 'c'])
    result.current.openRowMenu('a', 0, 0)
    expect(deps.select).not.toHaveBeenCalled()
    expect(deps.openMenu.mock.calls[0]![0].label).toBe('3 selected')
    expect(labels()).toEqual(['Pause 2', 'Resume', 'Copy links', 'Remove 3'])

    pick('Pause 2')
    expect(deps.runBulk).toHaveBeenCalledWith('pause', ['a', 'c'])
    pick('Remove 3')
    expect(deps.removeMany).toHaveBeenCalledWith(['a', 'b', 'c'])
  })

  it('builds single-row entries for a row outside the selection, and selects it', () => {
    const { result, deps, labels } = setup(['b', 'c'])
    result.current.openRowMenu('a', 0, 0)
    expect(deps.select).toHaveBeenCalledWith({ type: 'single', id: 'a' })
    expect(labels()).toEqual(['Pause', 'Copy source link', 'Remove from list', 'Remove with data'])
  })

  it('builds single-row entries for a lone selected row', () => {
    const { result, labels } = setup(['a'])
    result.current.openRowMenu('a', 0, 0)
    expect(labels()[0]).toBe('Pause')
  })
})
