import { screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, describe, expect, it, vi } from 'vitest'
import type { ReactNode } from 'react'
import { renderWithI18n } from '../test/renderWithI18n'
import en from '../locales/en.json'
import { UNSORTED, type SortState } from '../lib/sort'
import type { TaskRow } from '../lib/types'
import { useAppKeys, type AppKeyDeps } from '../hooks/useAppKeys'
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
  bulk?: ReactNode
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
      bulk={over.bulk}
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

  it('offers Clear search and filter when a filter is also narrowing the list', () => {
    renderWithI18n(
      <LibraryView
        tasks={[]}
        total={3}
        loaded
        search="ubuntuu"
        filtered
        selectedIds={new Set()}
        lead={null}
        sort={UNSORTED}
        canWrite
        readOnly={false}
        onSelection={vi.fn()}
        onOpen={vi.fn()}
        onSort={vi.fn()}
        onAction={vi.fn()}
        onMenu={vi.fn()}
        onClearSearch={vi.fn()}
        onAdd={vi.fn()}
      />,
    )
    expect(screen.getByRole('button', { name: en.library.clearSearchAndFilter })).toBeInTheDocument()
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
    const { container } = renderLibrary({ tasks: [task({ statusToken: 'downloading' })] })
    expect(container.querySelector('.sbtn')).toHaveAttribute('aria-label', en.common.pause)
  })

  it('labels a paused row with Resume rather than the raw token', () => {
    const { container } = renderLibrary({ tasks: [task({ statusToken: 'paused' })] })
    expect(container.querySelector('.sbtn')).toHaveAttribute('aria-label', en.common.resume)
  })

  it('keeps controls out of the options and points each option at the actions hint', () => {
    renderLibrary({ tasks: TWO })
    // An option may not contain controls: the in-row buttons are pointer-only shortcuts.
    expect(screen.queryAllByRole('button', { name: /More actions/ })).toEqual([])
    const option = screen.getAllByRole('option')[0]!
    expect(option).toHaveAccessibleDescription(en.library.actionsHint)
  })

  it('shows an error with Retry when the snapshot keeps failing', async () => {
    const onRetry = vi.fn()
    renderWithI18n(
      <LibraryView
        tasks={[]}
        total={0}
        loaded={false}
        error
        search=""
        selectedIds={new Set()}
        lead={null}
        sort={UNSORTED}
        canWrite
        readOnly={false}
        onSelection={vi.fn()}
        onOpen={vi.fn()}
        onSort={vi.fn()}
        onAction={vi.fn()}
        onMenu={vi.fn()}
        onClearSearch={vi.fn()}
        onAdd={vi.fn()}
        onRetry={onRetry}
      />,
    )
    expect(screen.getByText(en.library.loadErrorTitle)).toBeInTheDocument()
    expect(screen.queryByText(en.common.loading)).toBeNull()
    await userEvent.click(screen.getByRole('button', { name: en.common.retry }))
    expect(onRetry).toHaveBeenCalled()
  })

  it('shows nothing for an idle row and a second upload line when seeding', () => {
    const { container } = renderLibrary({
      tasks: [
        task({ id: 'idle', downSpeed: 0, upSpeed: 0 }),
        task({ id: 'seed', downSpeed: 0, upSpeed: 2048 }),
      ],
    })
    const cells = container.querySelectorAll('.c.dspd')
    expect(cells[0]).toHaveTextContent(/^$/)
    expect(cells[1]!.querySelector('.uspd')).toHaveTextContent('↑ 2.0 KB/s')
  })

  it('moves focus to the neighbouring row when the focused row is removed', () => {
    const THREE = [...TWO, task({ id: 'c', name: 'c.iso' })]
    const { rerender } = renderLibrary({ tasks: THREE })
    screen.getAllByRole('option')[1]!.focus()
    const props = {
      total: 2,
      loaded: true,
      search: '',
      selectedIds: new Set<string>(),
      lead: null,
      sort: UNSORTED,
      canWrite: true,
      readOnly: false,
      onSelection: vi.fn(),
      onOpen: vi.fn(),
      onSort: vi.fn(),
      onAction: vi.fn(),
      onMenu: vi.fn(),
      onClearSearch: vi.fn(),
      onAdd: vi.fn(),
    }
    rerender(<LibraryView {...props} tasks={[THREE[0]!, THREE[2]!]} />)
    expect(screen.getAllByRole('option')[1]).toHaveFocus()
    expect(screen.getAllByRole('option')[1]).toHaveAttribute('data-id', 'c')
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
    const { handlers, container } = renderLibrary({ tasks: TWO })
    const more = container.querySelector<HTMLElement>('[aria-label="More actions for a.iso"]')!
    expect(more).toHaveAttribute('aria-haspopup', 'menu')
    await userEvent.click(more)
    expect(handlers.onMenu).toHaveBeenCalledWith('a', expect.any(Number), expect.any(Number))
    expect(handlers.onOpen).not.toHaveBeenCalled()
  })

  it('sorts from header buttons and puts the sort state in the button name', async () => {
    const { handlers } = renderLibrary({ tasks: TWO, sort: { key: 'name', dir: 'desc' } })
    // Outside a grid, role=columnheader and aria-sort are ignored; the name carries the state.
    expect(screen.queryAllByRole('columnheader')).toEqual([])
    expect(screen.getByRole('button', { name: 'Name, sorted descending' })).toBeInTheDocument()
    await userEvent.click(screen.getByRole('button', { name: en.library.colSize }))
    expect(handlers.onSort).toHaveBeenCalledWith('size')
    await userEvent.click(screen.getByRole('button', { name: en.library.colSpeed }))
    expect(handlers.onSort).toHaveBeenCalledWith('speed')
  })
})

describe('LibraryView — Status and Added columns', () => {
  it('sorts by ETA from the Status column, and by Added from its header', async () => {
    const { handlers } = renderLibrary({ tasks: [task()] })
    expect(document.querySelector('.c.eta')).toBeNull()
    await userEvent.click(screen.getByRole('button', { name: en.library.colEta }))
    expect(handlers.onSort).toHaveBeenCalledWith('eta')
    await userEvent.click(screen.getByRole('button', { name: en.library.colAdded }))
    expect(handlers.onSort).toHaveBeenCalledWith('added')
  })

  it('marks a stored ETA sort on its header', () => {
    renderLibrary({ tasks: [task()], sort: { key: 'eta', dir: 'desc' } })
    expect(screen.getByRole('button', { name: 'ETA, sorted descending' })).toBeInTheDocument()
  })

  it('keeps sorting reachable while the bulk bar holds the header slot', async () => {
    const { handlers } = renderLibrary({
      tasks: TWO,
      sort: { key: 'eta', dir: 'asc' },
      bulk: <div role="toolbar" aria-label="bulk" />,
    })
    expect(screen.queryByRole('button', { name: en.library.colName })).toBeNull()
    const picker = screen.getByRole('combobox', { name: en.library.sortBy })
    expect(picker).toHaveValue('eta')
    await userEvent.selectOptions(picker, 'size')
    expect(handlers.onSort).toHaveBeenCalledWith('size')
    await userEvent.click(screen.getByRole('button', { name: 'ETA, sorted ascending' }))
    expect(handlers.onSort).toHaveBeenLastCalledWith('eta')
  })

  it('folds the ETA into Status, and shows a relative Added time with the absolute one in its title', () => {
    const addedAt = Math.floor(Date.now() / 1000) - 2 * 3600
    const { container } = renderLibrary({
      tasks: [task({ id: 'a', etaSeconds: 600, addedAt }), task({ id: 'b', etaSeconds: null })],
    })
    expect(container.querySelector('.c.eta')).toBeNull()
    const status = [...container.querySelectorAll('.c.status')].map((el) => el.textContent)
    expect(status[0]).toContain('Downloading · 10m left')
    expect(status[1]).toContain('Downloading · 42%')
    const added = container.querySelector<HTMLElement>('.c.added')!
    expect(added).toHaveTextContent('2h ago')
    expect(added.title).not.toBe('')
  })
})

describe('LibraryView — phone cards', () => {
  afterEach(() => {
    vi.unstubAllGlobals()
  })

  function phone() {
    vi.stubGlobal('matchMedia', (query: string) => ({
      matches: query.includes('max-width: 680px'),
      media: query,
      addEventListener: () => {},
      removeEventListener: () => {},
    }))
  }

  it('gives each card an announced pause/resume button and a meta line', async () => {
    phone()
    const { handlers, container } = renderLibrary({
      tasks: [task({ doneBytes: 2.9 * 1024 ** 3, totalBytes: 4.7 * 1024 ** 3, downSpeed: 12 * 1024 ** 2, etaSeconds: 120 })],
    })
    const button = screen.getByRole('button', { name: 'Pause ubuntu-24.04.iso' })
    expect(button).not.toHaveAttribute('aria-hidden')
    await userEvent.click(button)
    expect(handlers.onAction).toHaveBeenCalledWith('t1', 'pause')
    expect(handlers.onOpen).not.toHaveBeenCalled()
    expect(container.querySelector('.pmeta')).toHaveTextContent('2.9/4.7 GB · 12 MB/s · 2m')
  })

  it('shows the floating Add button only to a session that can write', () => {
    const { unmount } = renderLibrary({ tasks: [task()] })
    expect(screen.getByRole('button', { name: en.topbar.addDownload })).toHaveAttribute('aria-keyshortcuts', 'N')
    unmount()
    renderLibrary({ tasks: [task()], canWrite: false, readOnly: true })
    expect(screen.queryByRole('button', { name: en.topbar.addDownload })).toBeNull()
  })
})

describe('LibraryView — with the app keys', () => {
  const ROWS = [task({ id: 'a', name: 'a.iso' }), task({ id: 'b', name: 'b.iso', statusToken: 'paused' })]

  /** The row list plus the document-level shortcuts, wired as App wires them. */
  function Keyed({ runBulk, onSelection }: { runBulk: AppKeyDeps['runBulk']; onSelection: AppKeyDeps['select'] }) {
    useAppKeys({
      enabled: true,
      onEscape: vi.fn(),
      view: 'library',
      visible: ROWS,
      lead: 'a',
      selectedVisible: [ROWS[0]!],
      canWrite: true,
      select: onSelection,
      openDetail: vi.fn(),
      runBulk,
      removeMany: vi.fn(),
      openAdd: vi.fn(),
      focusSearch: vi.fn(),
      openHelp: vi.fn(),
      rowElement: () => undefined,
    })
    return (
      <LibraryView
        tasks={ROWS}
        total={ROWS.length}
        loaded
        search=""
        selectedIds={new Set(['a'])}
        lead="a"
        sort={UNSORTED}
        canWrite
        readOnly={false}
        onSelection={onSelection}
        onOpen={vi.fn()}
        onSort={vi.fn()}
        onAction={vi.fn()}
        onMenu={vi.fn()}
        onClearSearch={vi.fn()}
        onAdd={vi.fn()}
      />
    )
  }

  it('pauses the selection on Space from a focused row, and toggles the row on Ctrl+Space', async () => {
    const runBulk = vi.fn(async () => {})
    const onSelection = vi.fn()
    renderWithI18n(<Keyed runBulk={runBulk} onSelection={onSelection} />)
    const row = screen.getAllByRole('option')[0]!
    expect(row).toHaveAttribute('aria-keyshortcuts', expect.stringContaining('Space'))
    row.focus()

    await userEvent.keyboard(' ')
    expect(runBulk).toHaveBeenCalledWith('pause', ['a'])
    expect(onSelection).not.toHaveBeenCalledWith({ type: 'toggle', id: 'a' })

    await userEvent.keyboard('{Control>} {/Control}')
    expect(onSelection).toHaveBeenCalledWith({ type: 'toggle', id: 'a' })
    expect(runBulk).toHaveBeenCalledTimes(1)
  })
})

