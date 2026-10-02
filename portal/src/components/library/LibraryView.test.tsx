import { act, fireEvent, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import type { ComponentProps } from 'react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { useAppKeys, type AppKeyDeps } from '../../hooks/useAppKeys'
import { LONG_PRESS_MS } from '../../hooks/useLongPress'
import { UNSORTED } from '../../lib/sort'
import type { TaskRow } from '../../lib/types'
import en from '../../locales/en.json'
import { makeTask } from '../../test/makeTask'
import { renderWithI18n } from '../../test/renderWithI18n'
import { LibraryView } from './LibraryView'

/** A download in flight, as the old row tests drew it. */
function dl(id: string, over: Partial<TaskRow> = {}): TaskRow {
  return makeTask(id, {
    name: `${id}.iso`,
    status: 'Downloading',
    statusToken: 'downloading',
    progress: 0.42,
    downSpeed: 1_500_000,
    totalBytes: 5_000_000_000,
    doneBytes: 2_100_000_000,
    conns: 4,
    etaSeconds: 600,
    ...over,
  })
}

type Props = ComponentProps<typeof LibraryView>

function handlers() {
  return {
    onSelection: vi.fn(),
    onOpen: vi.fn(),
    onSort: vi.fn(),
    onAction: vi.fn(),
    onMenu: vi.fn(),
    onClearSearch: vi.fn(),
    onAdd: vi.fn(),
    onStream: vi.fn(),
  }
}

function props(over: Partial<Props> = {}, h = handlers()): Props {
  const tasks = over.tasks ?? []
  return {
    tasks,
    total: tasks.length,
    loaded: true,
    search: '',
    selectedIds: new Set<string>(),
    lead: null,
    sort: UNSORTED,
    canWrite: true,
    layout: 'table',
    ...h,
    ...over,
  }
}

function renderLibrary(over: Partial<Props> = {}) {
  const h = handlers()
  const result = renderWithI18n(<LibraryView {...props(over, h)} />)
  const rerender = (next: Partial<Props>) => result.rerender(<LibraryView {...props({ ...over, ...next }, h)} />)
  return { ...result, handlers: h, rerender }
}

afterEach(() => {
  vi.unstubAllGlobals()
  vi.useRealTimers()
})

const TWO = [dl('a'), dl('b')]

describe('LibraryView — empty states', () => {
  it('shows a loading state, not the empty state, before the first snapshot', () => {
    renderLibrary({ loaded: false })
    expect(screen.getByRole('status')).toHaveTextContent(en.common.loading)
    expect(screen.queryByText(en.library.emptyQueueTitle)).toBeNull()
  })

  it('shows an error with Retry when the snapshot keeps failing', async () => {
    const onRetry = vi.fn()
    renderLibrary({ loaded: false, error: true, onRetry })
    expect(screen.getByRole('alert')).toHaveTextContent(en.library.loadErrorTitle)
    expect(screen.queryByText(en.common.loading)).toBeNull()
    await userEvent.click(screen.getByRole('button', { name: en.common.retry }))
    expect(onRetry).toHaveBeenCalled()
  })

  it('renders the empty-queue body as rich text with the Add label bolded, plus an Add button', async () => {
    const { container, handlers: h } = renderLibrary()
    expect(screen.getByText(en.library.emptyQueueTitle)).toBeInTheDocument()
    expect(container.querySelector('.empty p b')).toHaveTextContent(en.common.add)
    expect(container.textContent).not.toContain('<bold>')
    expect(container.textContent).toContain('to queue a URL, magnet, or torrent.')
    await userEvent.click(screen.getByRole('button', { name: en.common.add }))
    expect(h.onAdd).toHaveBeenCalled()
  })

  it('offers no call to action to a read-only session', () => {
    renderLibrary({ canWrite: false, readOnly: true })
    expect(screen.getByText(en.library.emptyReadOnlyBody)).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: en.common.add })).toBeNull()
  })

  it('says when a filter hides every download', () => {
    renderLibrary({ total: 4 })
    expect(screen.getByText(en.library.emptyTitle)).toBeInTheDocument()
    expect(screen.getByText(en.library.emptyFilterBody)).toBeInTheDocument()
  })

  it('offers Clear search when a search matches nothing', async () => {
    const { handlers: h } = renderLibrary({ search: 'ubuntuu', total: 3 })
    expect(screen.getByText('No downloads match “ubuntuu”')).toBeInTheDocument()
    await userEvent.click(screen.getByRole('button', { name: en.library.clearSearch }))
    expect(h.onClearSearch).toHaveBeenCalled()
  })

  it('offers Clear search and filter when a filter is also narrowing the list', () => {
    renderLibrary({ search: 'ubuntuu', total: 3, filtered: true })
    expect(screen.getByRole('button', { name: en.library.clearSearchAndFilter })).toBeInTheDocument()
  })

  it('leaves the read-only banner to the shell', () => {
    renderLibrary({ tasks: TWO, readOnly: true, canWrite: false })
    expect(screen.queryByText(en.library.readOnlyBanner)).toBeNull()
  })
})

describe.each(['table', 'board'] as const)('LibraryView — %s, the listbox', (layout) => {
  it('is a labelled listbox with one tab stop on the lead', () => {
    renderLibrary({ layout, tasks: TWO, selectedIds: new Set(['b']), lead: 'b' })
    expect(screen.getByRole('listbox', { name: en.library.queueLabel })).toHaveAttribute('aria-multiselectable', 'true')
    const options = screen.getAllByRole('option')
    expect(options.map((o) => o.getAttribute('tabindex'))).toEqual(['-1', '0'])
    expect(options[1]).toHaveAttribute('aria-selected', 'true')
    expect(options[0]).toHaveAttribute('data-id', 'a')
  })

  it('names each option by what it is and how it is doing, and points it at the actions hint', () => {
    renderLibrary({ layout, tasks: [dl('a'), makeTask('f', { statusToken: 'failed', status: 'Failed', error: 'Disk full' })] })
    const [a, f] = screen.getAllByRole('option')
    expect(a).toHaveAccessibleName('a.iso, HTTP, Downloading, 42%')
    expect(f).toHaveAccessibleName('f.iso, HTTP, failed: Disk full')
    expect(a).toHaveAccessibleDescription(en.library.actionsHint)
    expect(a).toHaveAttribute('aria-keyshortcuts', 'Space Enter Control+Space Meta+Space')
  })

  it('keeps every control inside an option hidden from assistive tech on a desktop', () => {
    renderLibrary({ layout, tasks: [dl('a'), makeTask('p', { statusToken: 'paused', status: 'Paused' })] })
    for (const option of screen.getAllByRole('option')) {
      expect(within(option).queryAllByRole('button')).toEqual([])
    }
    expect(screen.queryAllByRole('button', { name: /More actions/ })).toEqual([])
  })

  it('draws a long list in pages, yet End and the arrows still reach every item', async () => {
    const many = Array.from({ length: 400 }, (_, i) => dl(`t${String(i).padStart(3, '0')}`))
    const { handlers: h } = renderLibrary({ layout, tasks: many, lead: 't000', selectedIds: new Set(['t000']) })
    expect(screen.getAllByRole('option')).toHaveLength(300)
    expect(screen.getByRole('button', { name: /Show 100 more of 100 remaining/ })).toBeInTheDocument()
    screen.getAllByRole('option')[0]!.focus()
    await userEvent.keyboard('{End}')
    expect(h.onSelection).toHaveBeenLastCalledWith({ type: 'single', id: 't399' })
    await vi.waitFor(() => expect(document.activeElement).toHaveAttribute('data-id', 't399'))
    expect(screen.getAllByRole('option').length).toBeGreaterThan(300)
  }, 20_000)

  it('opens on click, toggles on ⌘-click and ranges on Shift-click', async () => {
    const { handlers: h } = renderLibrary({ layout, tasks: TWO })
    const [a, b] = screen.getAllByRole('option')
    const user = userEvent.setup()
    await user.click(a!)
    expect(h.onOpen).toHaveBeenCalledWith('a')
    await user.keyboard('{Meta>}')
    await user.click(b!)
    await user.keyboard('{/Meta}')
    expect(h.onSelection).toHaveBeenCalledWith({ type: 'toggle', id: 'b' })
    await user.keyboard('{Shift>}')
    await user.click(b!)
    await user.keyboard('{/Shift}')
    expect(h.onSelection).toHaveBeenCalledWith({ type: 'range', id: 'b', order: ['a', 'b'] })
  })

  it('moves with the arrow keys, ranges with Shift, opens on Enter, menus on Shift+F10', async () => {
    const { handlers: h } = renderLibrary({ layout, tasks: [...TWO, dl('c')], selectedIds: new Set(['a']), lead: 'a' })
    screen.getAllByRole('option')[0]!.focus()
    await userEvent.keyboard('{ArrowDown}')
    expect(h.onSelection).toHaveBeenLastCalledWith({ type: 'single', id: 'b' })
    expect(screen.getAllByRole('option')[1]).toHaveFocus()
    await userEvent.keyboard('{Shift>}{ArrowDown}{/Shift}')
    expect(h.onSelection).toHaveBeenLastCalledWith({ type: 'range', id: 'c', order: ['a', 'b', 'c'] })
    await userEvent.keyboard('{Home}')
    expect(screen.getAllByRole('option')[0]).toHaveFocus()
    await userEvent.keyboard('{End}')
    expect(screen.getAllByRole('option')[2]).toHaveFocus()
    await userEvent.keyboard('{Enter}')
    expect(h.onOpen).toHaveBeenCalledWith('c')
    await userEvent.keyboard('{Shift>}{F10}{/Shift}')
    expect(h.onMenu).toHaveBeenCalledWith('c', expect.any(Number), expect.any(Number))
  })

  it('selects everything with Ctrl+A', async () => {
    const { handlers: h } = renderLibrary({ layout, tasks: TWO })
    screen.getAllByRole('option')[0]!.focus()
    await userEvent.keyboard('{Control>}a{/Control}')
    expect(h.onSelection).toHaveBeenCalledWith({ type: 'all', order: ['a', 'b'] })
  })

  it('opens the menu at the pointer on right-click, and from the ⋯ button without opening the item', async () => {
    const { handlers: h, container } = renderLibrary({ layout, tasks: TWO })
    fireEvent.contextMenu(screen.getAllByRole('option')[0]!, { clientX: 12, clientY: 34 })
    expect(h.onMenu).toHaveBeenCalledWith('a', 12, 34)
    const more = container.querySelector<HTMLElement>('[aria-label="More actions for b.iso"]')!
    expect(more).toHaveAttribute('aria-haspopup', 'menu')
    await userEvent.click(more)
    expect(h.onMenu).toHaveBeenLastCalledWith('b', expect.any(Number), expect.any(Number))
    expect(h.onOpen).not.toHaveBeenCalled()
  })

  it('moves focus to the neighbouring item when the focused one is removed', () => {
    const three = [...TWO, dl('c')]
    const { rerender } = renderLibrary({ layout, tasks: three })
    screen.getAllByRole('option')[1]!.focus()
    rerender({ tasks: [three[0]!, three[2]!] })
    expect(document.activeElement).toHaveAttribute('data-id', 'c')
  })

  it('focuses the empty state when the last item goes', () => {
    const { rerender, container } = renderLibrary({ layout, tasks: [dl('a')] })
    screen.getByRole('option').focus()
    rerender({ tasks: [], total: 0 })
    expect(container.querySelector('.lib-empty')).toHaveFocus()
  })

  it('pulses revealed items once they are on screen', () => {
    renderLibrary({ layout, tasks: TWO, reveal: { ids: ['b'], seq: 1 } })
    const b = screen.getAllByRole('option')[1]!
    expect(b).toHaveAttribute('data-pulse')
    fireEvent.animationEnd(b)
    expect(b).not.toHaveAttribute('data-pulse')
  })

  it('enters select mode on a long press; taps then toggle and the select bar docks', () => {
    vi.useFakeTimers()
    const onSelecting = vi.fn()
    const { handlers: h, rerender } = renderLibrary({ layout, tasks: TWO, onSelecting })
    const row = screen.getAllByRole('option')[0]!
    fireEvent.pointerDown(row, { pointerType: 'touch', isPrimary: true, clientX: 5, clientY: 5 })
    act(() => vi.advanceTimersByTime(LONG_PRESS_MS))
    expect(onSelecting).toHaveBeenCalledWith(true)
    expect(h.onSelection).toHaveBeenCalledWith({ type: 'set', ids: ['a'] })
    // The click the same touch produces does not open the item.
    fireEvent.click(row)
    expect(h.onOpen).not.toHaveBeenCalled()
    vi.useRealTimers()

    rerender({ selecting: true, selectedIds: new Set(['a']), lead: 'a', selectBar: <div>select bar</div>, bulk: <div>bulk bar</div> })
    fireEvent.click(screen.getAllByRole('option')[1]!)
    expect(h.onSelection).toHaveBeenLastCalledWith({ type: 'toggle', id: 'b' })
    expect(screen.getByText('select bar')).toBeInTheDocument()
    expect(screen.queryByText('bulk bar')).toBeNull()
    expect(document.querySelectorAll('.check.on')).toHaveLength(1)
  })

  it('docks the bulk bar for a multi-selection', () => {
    renderLibrary({ layout, tasks: TWO, bulk: <div role="toolbar" aria-label="bulk" /> })
    expect(screen.getByRole('toolbar', { name: 'bulk' }).closest('.lib-dock')).not.toBeNull()
  })

  it('renders the chips and tools it is given above the list', () => {
    renderLibrary({ layout, tasks: TWO, chips: <div>chips</div>, tools: <div>tools</div> })
    expect(screen.getByText('chips').closest('.lib-bar')).toHaveTextContent('tools')
  })
})

describe('LibraryView — with the app keys', () => {
  const ROWS = [dl('a'), dl('b', { statusToken: 'paused', status: 'Paused' })]

  /** The list plus the document-level shortcuts, wired as App wires them. */
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
    return <LibraryView {...props({ tasks: ROWS, selectedIds: new Set(['a']), lead: 'a', onSelection })} />
  }

  it('pauses the selection on Space from a focused item, and toggles the item on Ctrl+Space', async () => {
    const runBulk = vi.fn(async () => {})
    const onSelection = vi.fn()
    renderWithI18n(<Keyed runBulk={runBulk} onSelection={onSelection} />)
    screen.getAllByRole('option')[0]!.focus()
    await userEvent.keyboard(' ')
    expect(runBulk).toHaveBeenCalledWith('pause', ['a'])
    expect(onSelection).not.toHaveBeenCalledWith({ type: 'toggle', id: 'a' })
    await userEvent.keyboard('{Control>} {/Control}')
    expect(onSelection).toHaveBeenCalledWith({ type: 'toggle', id: 'a' })
    expect(runBulk).toHaveBeenCalledTimes(1)
  })
})
