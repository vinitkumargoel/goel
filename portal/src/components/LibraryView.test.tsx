import { screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it, vi } from 'vitest'
import { renderWithI18n } from '../test/renderWithI18n'
import en from '../locales/en.json'
import { UNSORTED, type SortState } from '../lib/sort'
import type { TaskRow } from '../lib/types'
import { LibraryView } from './LibraryView'

function task(over: Partial<TaskRow> = {}): TaskRow {
  return {
    id: 't1',
    name: 'ubuntu-24.04.iso',
    status: 'Downloading',
    statusToken: 'downloading',
    kind: 'http',
    progress: 0.42,
    downSpeed: 1_500_000,
    upSpeed: 0,
    totalBytes: 5_000_000_000,
    doneBytes: 2_100_000_000,
    upBytes: 0,
    ratio: 0,
    seeds: null,
    conns: 4,
    addedAt: 1_700_000_000,
    etaSeconds: 600,
    error: null,
    source: 'https://example.com/ubuntu.iso',
    multiFile: false,
    fileCount: 1,
    streamable: false,
    ...over,
  }
}

interface Options {
  tasks?: TaskRow[]
  total?: number
  loaded?: boolean
  search?: string
  canWrite?: boolean
  readOnly?: boolean
  selectedIds?: string[]
  sort?: SortState
}

function renderLibrary(over: Options = {}) {
  const handlers = {
    onSelection: vi.fn(),
    onOpen: vi.fn(),
    onSort: vi.fn(),
    onAction: vi.fn(),
    onMenu: vi.fn(),
    onClearSearch: vi.fn(),
    onAdd: vi.fn(),
  }
  const tasks = over.tasks ?? []
  const result = renderWithI18n(
    <LibraryView
      tasks={tasks}
      total={over.total ?? tasks.length}
      loaded={over.loaded ?? true}
      search={over.search ?? ''}
      selectedIds={new Set(over.selectedIds ?? [])}
      lead={over.selectedIds?.[0] ?? null}
      sort={over.sort ?? UNSORTED}
      canWrite={over.canWrite ?? true}
      readOnly={over.readOnly ?? false}
      {...handlers}
    />,
  )
  return { ...result, handlers }
}

const TWO = [task({ id: 'a', name: 'a.iso' }), task({ id: 'b', name: 'b.iso' })]

describe('LibraryView', () => {
  it('renders the column headers from the catalogue', () => {
    renderLibrary()
    expect(screen.getByText(en.library.colName)).toBeInTheDocument()
    expect(screen.getByText(en.library.colSize)).toBeInTheDocument()
    expect(screen.getByText(en.library.colStatus)).toBeInTheDocument()
    expect(screen.getByText(en.library.colSpeed)).toBeInTheDocument()
  })

  it('shows a loading state, not the empty state, before the first snapshot', () => {
    renderLibrary({ loaded: false })
    expect(screen.getByText(en.common.loading)).toBeInTheDocument()
    expect(screen.queryByText(en.library.emptyQueueTitle)).toBeNull()
  })

  it('renders the empty-queue body as rich text with the Add label bolded, plus an Add button', async () => {
    const { container, handlers } = renderLibrary()
    expect(screen.getByText(en.library.emptyQueueTitle)).toBeInTheDocument()
    const bold = container.querySelector('.empty p b')
    expect(bold).not.toBeNull()
    expect(bold).toHaveTextContent(en.common.add)

    // The <bold> tag must be consumed by Trans, not printed.
    expect(container.textContent).not.toContain('<bold>')
    expect(container.textContent).toContain('to queue a URL, magnet, or torrent.')

    await userEvent.click(screen.getByRole('button', { name: en.common.add }))
    expect(handlers.onAdd).toHaveBeenCalled()
  })

  it('offers no call to action to a read-only session', () => {
    renderLibrary({ canWrite: false, readOnly: true })
    expect(screen.getByText(en.library.emptyReadOnlyBody)).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: en.common.add })).toBeNull()
  })

  it('offers Clear search when a search matches nothing', async () => {
    const { handlers } = renderLibrary({ search: 'ubuntuu', total: 3 })
    expect(screen.getByText('No downloads match “ubuntuu”')).toBeInTheDocument()
    await userEvent.click(screen.getByRole('button', { name: en.library.clearSearch }))
    expect(handlers.onClearSearch).toHaveBeenCalled()
  })

  it('shows the read-only banner only when read-only', () => {
    const { unmount } = renderLibrary({ readOnly: false })
    expect(screen.queryByText(en.library.readOnlyBanner)).toBeNull()
    unmount()

    renderLibrary({ readOnly: true })
    expect(screen.getByText(en.library.readOnlyBanner)).toBeInTheDocument()
  })

  it('labels the row action button with the translated action', () => {
    renderLibrary({ tasks: [task({ statusToken: 'downloading' })] })
    expect(screen.getByRole('button', { name: en.common.pause })).toBeInTheDocument()
  })

  it('labels a paused row with Resume rather than the raw token', () => {
    renderLibrary({ tasks: [task({ statusToken: 'paused' })] })
    expect(screen.getByRole('button', { name: en.common.resume })).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'resume' })).toBeNull()
  })

  it('passes the server-rendered status string through untouched', () => {
    renderLibrary({ tasks: [task({ status: 'Downloading' })] })
    expect(screen.getAllByText(/Downloading/).length).toBeGreaterThan(0)
  })

  it('shows the short protocol badge, not the long name', () => {
    renderLibrary({ tasks: [task({ kind: 'torrent' })] })
    expect(screen.getByText('BT')).toBeInTheDocument()
    expect(screen.queryByText('BITTORRENT')).toBeNull()
  })

  it('is a labelled listbox with one tab stop and a progressbar per row', () => {
    renderLibrary({ tasks: TWO, selectedIds: ['b'] })
    expect(screen.getByRole('listbox', { name: en.library.queueLabel })).toBeInTheDocument()
    const options = screen.getAllByRole('option')
    expect(options.map((o) => o.getAttribute('tabindex'))).toEqual(['-1', '0'])
    expect(options[1]).toHaveAttribute('aria-selected', 'true')
    expect(screen.getAllByRole('progressbar')[0]).toHaveAttribute('aria-valuenow', '42')
  })

  it('opens a row on click, toggles on ⌘-click and ranges on Shift-click', async () => {
    const { handlers } = renderLibrary({ tasks: TWO })
    const [a, b] = screen.getAllByRole('option')
    await userEvent.click(a!)
    expect(handlers.onOpen).toHaveBeenCalledWith('a')

    const user = userEvent.setup()
    await user.keyboard('{Meta>}')
    await user.click(b!)
    await user.keyboard('{/Meta}')
    expect(handlers.onSelection).toHaveBeenCalledWith({ type: 'toggle', id: 'b' })

    await user.keyboard('{Shift>}')
    await user.click(b!)
    await user.keyboard('{/Shift}')
    expect(handlers.onSelection).toHaveBeenCalledWith({ type: 'range', id: 'b', order: ['a', 'b'] })
  })

  it('moves the selection with the arrow keys and opens the menu on Shift+F10', async () => {
    const { handlers } = renderLibrary({ tasks: TWO, selectedIds: ['a'] })
    screen.getAllByRole('option')[0]!.focus()
    await userEvent.keyboard('{ArrowDown}')
    expect(handlers.onSelection).toHaveBeenCalledWith({ type: 'single', id: 'b' })
    expect(screen.getAllByRole('option')[1]).toHaveFocus()

    await userEvent.keyboard('{Shift>}{F10}{/Shift}')
    expect(handlers.onMenu).toHaveBeenCalledWith('b', expect.any(Number), expect.any(Number))
  })

  it('selects every row with Ctrl+A', async () => {
    const { handlers } = renderLibrary({ tasks: TWO })
    screen.getAllByRole('option')[0]!.focus()
    await userEvent.keyboard('{Control>}a{/Control}')
    expect(handlers.onSelection).toHaveBeenCalledWith({ type: 'all', order: ['a', 'b'] })
  })

  it('gives each row a More button that opens its menu', async () => {
    const { handlers } = renderLibrary({ tasks: TWO })
    const more = screen.getByRole('button', { name: 'More actions for a.iso' })
    expect(more).toHaveAttribute('aria-haspopup', 'menu')
    await userEvent.click(more)
    expect(handlers.onMenu).toHaveBeenCalledWith('a', expect.any(Number), expect.any(Number))
    expect(handlers.onOpen).not.toHaveBeenCalled()
  })

  it('sorts from header buttons and reports the sort on the column header', async () => {
    const { handlers } = renderLibrary({ tasks: TWO, sort: { key: 'name', dir: 'desc' } })
    const headers = screen.getAllByRole('columnheader')
    expect(headers[0]).toHaveAttribute('aria-sort', 'descending')
    expect(headers[1]).toHaveAttribute('aria-sort', 'none')
    await userEvent.click(screen.getByRole('button', { name: en.library.colSize }))
    expect(handlers.onSort).toHaveBeenCalledWith('size')
  })
})
