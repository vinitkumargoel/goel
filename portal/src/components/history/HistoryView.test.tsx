import { screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import en from '../../locales/en.json'
import type { HistoryRow } from '../../lib/types'
import { renderWithI18n } from '../../test/renderWithI18n'
import { HistoryView } from './HistoryView'

const api = vi.hoisted(() => ({
  history: vi.fn(),
  removeHistory: vi.fn(() => Promise.resolve()),
  removeHistoryMany: vi.fn(() => Promise.resolve()),
  clearHistory: vi.fn(() => Promise.resolve()),
  add: vi.fn(() => Promise.resolve({ added: 1, refused: 0 })),
}))
const clipboard = vi.hoisted(() => ({ copyText: vi.fn(async () => true) }))

vi.mock('../../lib/api', async (importOriginal) => {
  const real = await importOriginal<typeof import('../../lib/api')>()
  return { ...real, api }
})
vi.mock('../../lib/clipboard', () => clipboard)
// The picker browses the server's folders; here it stands in as one button that picks.
vi.mock('../add/FolderPicker', () => ({
  FolderPicker: ({ onPick, onClose }: { onPick: (path: string, listing: never) => void; onClose: () => void }) => (
    <div role="dialog" aria-label="Pick a folder">
      <button onClick={() => onPick('/dl/Movies', undefined as never)}>Pick Movies</button>
      <button onClick={onClose}>Close picker</button>
    </div>
  ),
}))

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
  api.removeHistory.mockClear()
  api.removeHistoryMany.mockClear()
  api.add.mockClear()
  clipboard.copyText.mockReset().mockResolvedValue(true)
  api.history.mockReset().mockResolvedValue([entry('1', 'ubuntu.iso', 'http', 0), entry('2', 'movie.mkv', 'torrent', 40)])
})

afterEach(() => {
  vi.unstubAllGlobals()
})

function renderHistory(over: Partial<{ canWrite: boolean; refreshKey: string }> = {}) {
  const handlers = { onReadd: vi.fn(async () => {}), onRemoved: vi.fn(), onWarn: vi.fn(), onToast: vi.fn() }
  const view = renderWithI18n(<HistoryView canWrite {...handlers} {...over} />)
  return { ...handlers, ...view }
}

async function openClearMenu() {
  await userEvent.click(await screen.findByRole('button', { name: en.historyBulk.clear }))
  return screen.getByRole('menu', { name: en.historyBulk.clearOlder })
}

describe('HistoryView', () => {
  it('groups entries under day headings with their counts', async () => {
    renderHistory()
    expect(await screen.findByRole('heading', { name: en.history.groups.today })).toHaveTextContent('Today · 1')
    expect(screen.getByRole('heading', { name: en.history.groups.older })).toBeInTheDocument()
    const today = screen.getByRole('region', { name: en.history.groups.today })
    expect(within(today).getByText('ubuntu.iso')).toBeInTheDocument()
    expect(within(today).getByText('HTTP · example.com · 1.0 KB')).toBeInTheDocument()
  })

  it('filters by search and protocol chips, and says when nothing matches', async () => {
    renderHistory()
    const search = await screen.findByRole('searchbox', { name: en.history.search })
    await userEvent.type(search, 'movie')
    expect(screen.queryByText('ubuntu.iso')).toBeNull()
    expect(screen.getByText('movie.mkv')).toBeInTheDocument()
    const protocols = screen.getByRole('group', { name: en.history.protocol })
    await userEvent.click(within(protocols).getByRole('button', { name: 'HTTP' }))
    expect(within(protocols).getByRole('button', { name: 'HTTP' })).toHaveAttribute('aria-pressed', 'true')
    expect(screen.getByText(en.history.noMatch)).toBeInTheDocument()
    await userEvent.click(within(protocols).getByRole('button', { name: en.history.allProtocols }))
    expect(screen.getByText('movie.mkv')).toBeInTheDocument()
  })

  it('shows what is shown in a summary line', async () => {
    renderHistory()
    expect(await screen.findByText('2 items · 2.0 KB')).toBeInTheDocument()
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
    const protocols = await screen.findByRole('group', { name: en.history.protocol })
    await userEvent.click(within(protocols).getByRole('button', { name: 'BitTorrent' }))
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
    const menu = await openClearMenu()
    await userEvent.click(within(menu).getByRole('menuitem', { name: en.historyBulk.clearAll }))
    const dialog = await screen.findByRole('alertdialog')
    expect(within(dialog).getByText('2 entries will be removed from the history.')).toBeInTheDocument()
    expect(within(dialog).getByRole('button', { name: en.common.cancel })).toHaveFocus()
    expect(api.clearHistory).not.toHaveBeenCalled()
    await userEvent.click(within(dialog).getByRole('button', { name: 'Clear 2 entries' }))
    expect(api.clearHistory).toHaveBeenCalledWith(undefined)
    await waitFor(() => expect(api.history).toHaveBeenCalledTimes(2))
  })

  it('counts only the older entries for "older than", and sends the age in seconds', async () => {
    renderHistory()
    const menu = await openClearMenu()
    await userEvent.click(within(menu).getByRole('menuitem', { name: en.historyBulk.clear30 }))
    const dialog = await screen.findByRole('alertdialog')
    expect(within(dialog).getByText('1 entry will be removed from the history.')).toBeInTheDocument()
    expect(within(dialog).getByText(/more than 30 days ago/)).toBeInTheDocument()
    await userEvent.click(within(dialog).getByRole('button', { name: 'Clear 1 entry' }))
    expect(api.clearHistory).toHaveBeenCalledWith(30 * 86400)
  })

  it('Cancel leaves the history alone', async () => {
    renderHistory()
    const menu = await openClearMenu()
    await userEvent.click(within(menu).getByRole('menuitem', { name: en.historyBulk.clear30 }))
    await userEvent.click(await screen.findByRole('button', { name: en.common.cancel }))
    expect(screen.queryByRole('alertdialog')).toBeNull()
    expect(api.clearHistory).not.toHaveBeenCalled()
  })

  it('says so instead of asking when nothing is old enough', async () => {
    api.history.mockResolvedValue([entry('1', 'ubuntu.iso', 'http', 0)])
    const handlers = renderHistory()
    const menu = await openClearMenu()
    await userEvent.click(within(menu).getByRole('menuitem', { name: en.historyBulk.clear7 }))
    expect(screen.queryByRole('alertdialog')).toBeNull()
    expect(handlers.onToast).toHaveBeenCalledWith('Nothing that old in the history.')
  })

  it('offers no clearing, selecting, re-adding or removing to a read-only session, but still saving', async () => {
    renderHistory({ canWrite: false })
    await screen.findByText('ubuntu.iso')
    expect(screen.queryByRole('button', { name: en.historyBulk.clear })).toBeNull()
    expect(screen.queryByRole('button', { name: 'Select' })).toBeNull()
    expect(screen.queryByRole('button', { name: 'Re-add ubuntu.iso' })).toBeNull()
    expect(screen.queryByRole('button', { name: 'Remove ubuntu.iso from history' })).toBeNull()
    const save = screen.getByRole('link', { name: 'Save ubuntu.iso to this device' })
    expect(save).toHaveAttribute('href', '/stream?history=1')
    expect(save).toHaveAttribute('download')
  })

  it('re-adds an entry from its card', async () => {
    const handlers = renderHistory()
    await userEvent.click(await screen.findByRole('button', { name: 'Re-add ubuntu.iso' }))
    expect(handlers.onReadd).toHaveBeenCalledWith('https://example.com/ubuntu.iso')
  })

  it('removes one entry, tells App, and reloads quietly', async () => {
    const handlers = renderHistory()
    await userEvent.click(await screen.findByRole('button', { name: 'Remove ubuntu.iso from history' }))
    expect(api.removeHistory).toHaveBeenCalledWith('1')
    await waitFor(() => expect(handlers.onRemoved).toHaveBeenCalled())
    await waitFor(() => expect(api.history).toHaveBeenCalledTimes(2))
    // Quiet: the list never dropped to the loading state.
    expect(screen.queryByText(en.common.loading)).toBeNull()
  })

  it('reports a failed removal', async () => {
    api.removeHistory.mockRejectedValueOnce(new Error('Server said no'))
    const handlers = renderHistory()
    await userEvent.click(await screen.findByRole('button', { name: 'Remove ubuntu.iso from history' }))
    await waitFor(() => expect(handlers.onWarn).toHaveBeenCalled())
    expect(handlers.onRemoved).not.toHaveBeenCalled()
  })

  it('copies the source link', async () => {
    const handlers = renderHistory()
    await userEvent.click(await screen.findByRole('button', { name: 'Copy the link of movie.mkv' }))
    expect(clipboard.copyText).toHaveBeenCalledWith('https://example.com/movie.mkv')
    await waitFor(() => expect(handlers.onToast).toHaveBeenCalledWith(en.toast.copied))
  })

  it('says when the link could not be copied', async () => {
    clipboard.copyText.mockResolvedValue(false)
    const handlers = renderHistory()
    await userEvent.click(await screen.findByRole('button', { name: 'Copy the link of movie.mkv' }))
    await waitFor(() => expect(handlers.onWarn).toHaveBeenCalledWith(en.toast.copyFailed))
  })

  it('re-adds into a picked folder from the row menu', async () => {
    const handlers = renderHistory()
    await userEvent.click(await screen.findByRole('button', { name: 'More actions for movie.mkv' }))
    const menu = screen.getByRole('menu', { name: 'movie.mkv' })
    await userEvent.click(within(menu).getByRole('menuitem', { name: en.historyBulk.readdTo }))
    await userEvent.click(await screen.findByRole('button', { name: 'Pick Movies' }))
    expect(api.add).toHaveBeenCalledWith({ url: 'https://example.com/movie.mkv', folder: '/dl/Movies' })
    await waitFor(() => expect(handlers.onToast).toHaveBeenCalledWith(en.toast.readded))
    expect(screen.queryByRole('dialog', { name: 'Pick a folder' })).toBeNull()
  })

  it('removes from the row menu too', async () => {
    renderHistory()
    await userEvent.click(await screen.findByRole('button', { name: 'More actions for movie.mkv' }))
    await userEvent.click(screen.getByRole('menuitem', { name: 'Remove from history' }))
    expect(api.removeHistory).toHaveBeenCalledWith('2')
  })

  it('removes ticked entries in select mode, then leaves the selection empty', async () => {
    const handlers = renderHistory()
    expect(await screen.findByText('ubuntu.iso')).toBeInTheDocument()
    expect(screen.queryByRole('checkbox', { name: 'Select ubuntu.iso' })).toBeNull()
    await userEvent.click(screen.getByRole('button', { name: 'Select' }))
    await userEvent.click(screen.getByRole('checkbox', { name: 'Select ubuntu.iso' }))
    await userEvent.click(screen.getByRole('button', { name: 'Remove 1 selected' }))
    expect(api.removeHistoryMany).toHaveBeenCalledWith(['1'])
    await waitFor(() => expect(handlers.onToast).toHaveBeenCalledWith('Removed 1 entry'))
    expect(screen.queryByRole('button', { name: /selected/ })).toBeNull()
  })

  it('selects every shown entry at once, and Done leaves select mode', async () => {
    renderHistory()
    await userEvent.click(await screen.findByRole('button', { name: 'Select' }))
    await userEvent.click(screen.getByRole('checkbox', { name: en.historyBulk.selectAll }))
    expect(screen.getByRole('checkbox', { name: 'Select ubuntu.iso' })).toBeChecked()
    expect(screen.getByRole('checkbox', { name: 'Select movie.mkv' })).toBeChecked()
    expect(screen.getByRole('button', { name: 'Remove 2 selected' })).toBeInTheDocument()
    await userEvent.click(screen.getByRole('button', { name: en.workflow.library.done }))
    expect(screen.queryByRole('checkbox', { name: 'Select ubuntu.iso' })).toBeNull()
  })

  it('reloads quietly when refreshKey changes, not on mount', async () => {
    const view = renderHistory({ refreshKey: 'a' })
    await screen.findByText('ubuntu.iso')
    expect(api.history).toHaveBeenCalledTimes(1)
    api.history.mockResolvedValue([entry('3', 'new.zip', 'http', 0)])
    view.rerender(<HistoryView canWrite onReadd={view.onReadd} onRemoved={view.onRemoved} onWarn={view.onWarn} refreshKey="b" />)
    expect(await screen.findByText('new.zip')).toBeInTheDocument()
    expect(api.history).toHaveBeenCalledTimes(2)
  })

  it('shows a load error with Retry', async () => {
    api.history.mockRejectedValueOnce(new Error('down'))
    renderHistory()
    const alert = await screen.findByRole('alert')
    expect(alert).toHaveTextContent(en.history.loadError)
    await userEvent.click(within(alert).getByRole('button', { name: en.common.retry }))
    expect(await screen.findByText('ubuntu.iso')).toBeInTheDocument()
  })

  it('shows a loading state, then an empty one without tools', async () => {
    let resolve: (rows: HistoryRow[]) => void = () => {}
    api.history.mockReturnValue(new Promise((r) => (resolve = r)))
    renderHistory()
    expect(screen.getByRole('status')).toHaveTextContent(en.common.loading)
    resolve([])
    expect(await screen.findByText(en.history.empty)).toBeInTheDocument()
    expect(screen.queryByRole('searchbox')).toBeNull()
    expect(screen.queryByRole('button', { name: en.history.exportCsv })).toBeNull()
  })

  it('totals this month by file type in the side card', async () => {
    renderHistory()
    const side = await screen.findByRole('complementary', { name: 'This month' })
    expect(within(side).getByText('1 file finished')).toBeInTheDocument()
    expect(within(side).getByText(en.fileType.iso)).toBeInTheDocument()
    expect(within(side).getByText('All time: 2 entries · 2.0 KB')).toBeInTheDocument()
  })
})
