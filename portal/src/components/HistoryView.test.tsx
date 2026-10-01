import { screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import en from '../locales/en.json'
import type { HistoryRow } from '../lib/types'
import { renderWithI18n } from '../test/renderWithI18n'
import { HistoryView } from './HistoryView'

const api = vi.hoisted(() => ({
  history: vi.fn(),
  removeHistory: vi.fn(),
  clearHistory: vi.fn(() => Promise.resolve()),
}))

vi.mock('../lib/api', async (importOriginal) => {
  const real = await importOriginal<typeof import('../lib/api')>()
  return { ...real, api }
})

const now = Math.floor(Date.now() / 1000)

const entry = (id: string, name: string, kind: HistoryRow['kind'], ageDays: number): HistoryRow => ({
  id,
  name,
  kind,
  totalBytes: 1024,
  savePath: `/dl/${name}`,
  completedAt: now - ageDays * 86400,
  source: `https://example.com/${name}`,
})

beforeEach(() => {
  api.clearHistory.mockClear()
  api.history.mockReset().mockResolvedValue([
    entry('1', 'ubuntu.iso', 'http', 0),
    entry('2', 'movie.mkv', 'torrent', 40),
  ])
})

afterEach(() => {
  vi.unstubAllGlobals()
})

function renderHistory() {
  const handlers = { onReadd: vi.fn(async () => {}), onRemoved: vi.fn(), onWarn: vi.fn(), onToast: vi.fn() }
  renderWithI18n(<HistoryView canWrite {...handlers} />)
  return handlers
}

describe('HistoryView', () => {
  it('groups entries under day headings', async () => {
    renderHistory()
    expect(await screen.findByRole('heading', { name: en.history.groups.today })).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: en.history.groups.older })).toBeInTheDocument()
    const today = screen.getByRole('region', { name: en.history.groups.today })
    expect(within(today).getByText('ubuntu.iso')).toBeInTheDocument()
  })

  it('filters by search and protocol, and says when nothing matches', async () => {
    renderHistory()
    const search = await screen.findByRole('searchbox', { name: en.history.search })
    await userEvent.type(search, 'movie')
    expect(screen.queryByText('ubuntu.iso')).toBeNull()
    expect(screen.getByText('movie.mkv')).toBeInTheDocument()
    await userEvent.selectOptions(screen.getByLabelText(en.history.protocol), 'http')
    expect(screen.getByText(en.history.noMatch)).toBeInTheDocument()
  })

  it('exports what is shown as CSV', async () => {
    const created: Blob[] = []
    vi.stubGlobal('URL', {
      ...URL,
      createObjectURL: (b: Blob) => (created.push(b), 'blob:x'),
      revokeObjectURL: () => {},
    })
    const click = vi.spyOn(HTMLAnchorElement.prototype, 'click').mockImplementation(() => {})
    const handlers = renderHistory()
    await userEvent.selectOptions(await screen.findByLabelText(en.history.protocol), 'torrent')
    await userEvent.click(screen.getByRole('button', { name: en.history.exportCsv }))
    expect(click).toHaveBeenCalled()
    const text = await created[0]!.text()
    expect(text).toContain('movie.mkv')
    expect(text).not.toContain('ubuntu.iso')
    expect(handlers.onToast).toHaveBeenCalledWith('Exported 1 entry')
    click.mockRestore()
  })

  it('asks before clearing everything, says how many, and defaults to Cancel', async () => {
    renderHistory()
    await userEvent.selectOptions(await screen.findByRole('combobox', { name: 'Clear older than' }), 'all')
    const dialog = screen.getByRole('alertdialog')
    expect(within(dialog).getByText('2 entries will be removed from the history.')).toBeInTheDocument()
    expect(within(dialog).getByRole('button', { name: en.common.cancel })).toHaveFocus()
    expect(api.clearHistory).not.toHaveBeenCalled()
    await userEvent.click(within(dialog).getByRole('button', { name: 'Clear 2 entries' }))
    expect(api.clearHistory).toHaveBeenCalledWith(undefined)
  })

  it('counts only the older entries for "older than", and skips the request when there are none', async () => {
    renderHistory()
    await userEvent.selectOptions(await screen.findByRole('combobox', { name: 'Clear older than' }), '30')
    expect(screen.getByText('1 entry will be removed from the history.')).toBeInTheDocument()
    await userEvent.click(screen.getByRole('button', { name: en.common.cancel }))
    expect(api.clearHistory).not.toHaveBeenCalled()
  })

  it('says so instead of asking when nothing is old enough', async () => {
    api.history.mockResolvedValue([entry('1', 'ubuntu.iso', 'http', 0)])
    const handlers = renderHistory()
    await userEvent.selectOptions(await screen.findByRole('combobox', { name: 'Clear older than' }), '7')
    expect(screen.queryByRole('alertdialog')).toBeNull()
    expect(handlers.onToast).toHaveBeenCalledWith('Nothing that old in the history.')
  })

  it('offers no clearing to a read-only session', async () => {
    renderWithI18n(<HistoryView canWrite={false} onReadd={vi.fn()} onRemoved={vi.fn()} onWarn={vi.fn()} />)
    await screen.findByText('ubuntu.iso')
    expect(screen.queryByRole('combobox', { name: 'Clear older than' })).toBeNull()
  })
})
