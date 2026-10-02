import { screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import type { ComponentProps } from 'react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { groupTasks } from '../../lib/grouping'
import { UNSORTED } from '../../lib/sort'
import type { TaskRow } from '../../lib/types'
import en from '../../locales/en.json'
import { makeTask } from '../../test/makeTask'
import { renderWithI18n } from '../../test/renderWithI18n'
import { LibraryView } from './LibraryView'

function dl(id: string, over: Partial<TaskRow> = {}): TaskRow {
  return makeTask(id, {
    name: `${id}.iso`,
    status: 'Downloading',
    statusToken: 'downloading',
    progress: 0.42,
    downSpeed: 1_500_000,
    totalBytes: 5_000_000_000,
    doneBytes: 2_100_000_000,
    etaSeconds: 600,
    ...over,
  })
}

type Props = ComponentProps<typeof LibraryView>

function renderTable(over: Partial<Props> = {}) {
  const h = {
    onSelection: vi.fn(),
    onOpen: vi.fn(),
    onSort: vi.fn(),
    onAction: vi.fn(),
    onMenu: vi.fn(),
    onClearSearch: vi.fn(),
    onAdd: vi.fn(),
  }
  const tasks = over.tasks ?? [dl('a')]
  const result = renderWithI18n(
    <LibraryView
      tasks={tasks}
      total={tasks.length}
      loaded
      search=""
      selectedIds={new Set()}
      lead={null}
      sort={UNSORTED}
      canWrite
      layout="table"
      {...h}
      {...over}
    />,
  )
  return { ...result, handlers: h }
}

afterEach(() => vi.unstubAllGlobals())

describe('Table — columns and sorting', () => {
  it('renders the column headers from the catalogue, as plain buttons', () => {
    renderTable()
    for (const label of [
      en.library.colName,
      en.library.colSize,
      en.library.colStatus,
      en.library.colEta,
      en.library.colSpeed,
      en.library.colAdded,
    ]) {
      expect(screen.getByRole('button', { name: label })).toBeInTheDocument()
    }
    // Outside a grid, role=columnheader and aria-sort are ignored; the name carries the state.
    expect(screen.queryAllByRole('columnheader')).toEqual([])
  })

  it('sorts from the headers, ETA from the Status column, and names the active sort', async () => {
    const { handlers: h } = renderTable({ sort: { key: 'name', dir: 'desc' } })
    expect(screen.getByRole('button', { name: 'Name, sorted descending' })).toBeInTheDocument()
    for (const [label, key] of [
      [en.library.colSize, 'size'],
      [en.library.colSpeed, 'speed'],
      [en.library.colEta, 'eta'],
      [en.library.colAdded, 'added'],
      [en.library.colStatus, 'status'],
    ] as const) {
      await userEvent.click(screen.getByRole('button', { name: label }))
      expect(h.onSort).toHaveBeenLastCalledWith(key)
    }
  })

  it('marks a stored ETA sort on its header', () => {
    renderTable({ sort: { key: 'eta', dir: 'asc' } })
    expect(screen.getByRole('button', { name: 'ETA, sorted ascending' })).toBeInTheDocument()
  })

  it('keeps the headers while the bulk bar floats, so sorting stays reachable', () => {
    renderTable({ bulk: <div role="toolbar" aria-label="bulk" /> })
    expect(screen.getByRole('button', { name: en.library.colName })).toBeInTheDocument()
  })

  it('draws no headers for an empty list', () => {
    renderTable({ tasks: [], total: 0 })
    expect(screen.queryByRole('button', { name: en.library.colName })).toBeNull()
  })
})

describe('Table — cells', () => {
  it('folds the ETA into Status, and shows a relative Added time with the absolute one in its title', () => {
    const addedAt = Math.floor(Date.now() / 1000) - 2 * 3600
    const { container } = renderTable({ tasks: [dl('a', { addedAt }), dl('b', { etaSeconds: null })] })
    const status = [...container.querySelectorAll('.lt-row .lt-status')].map((el) => el.textContent)
    expect(status[0]).toBe('Downloading · 10m left')
    expect(status[1]).toBe('Downloading · 42%')
    const added = container.querySelector<HTMLElement>('.lt-row .lt-added')!
    expect(added).toHaveTextContent('2h ago')
    expect(added.title).not.toBe('')
  })

  it('passes the server status through, adding the figure each state is about', () => {
    const { container } = renderTable({
      tasks: [
        makeTask('q', { status: 'Queued', queuePosition: 1 }),
        makeTask('p', { statusToken: 'paused', status: 'Paused', progress: 0.34 }),
        makeTask('s', { statusToken: 'seeding', status: 'Seeding', ratio: 1.2 }),
        makeTask('d', { statusToken: 'completed', status: 'Completed', progress: 1 }),
      ],
    })
    const status = [...container.querySelectorAll('.lt-row .lt-status .pill')]
    expect(status.map((el) => el.textContent)).toEqual(['Queued · #2', 'Paused · 34%', 'Seeding 1.20×', 'Completed'])
    expect(status.map((el) => el.className)).toEqual(['pill', 'pill', 'pill up', 'pill good'])
  })

  it('shows a failed row its reason under the name and a red pill', () => {
    const { container } = renderTable({
      tasks: [makeTask('f', { statusToken: 'failed', status: 'Failed', error: 'Server closed the connection' })],
    })
    expect(container.querySelector('.lt-why')).toHaveTextContent('Server closed the connection')
    expect(container.querySelector('.lt-status .pill')).toHaveClass('bad')
    expect(container.querySelector('.lt-status .pill')).toHaveAttribute('title', 'Server closed the connection')
  })

  it('shows nothing for an idle row and a second upload line when seeding', () => {
    const { container } = renderTable({
      tasks: [dl('idle', { downSpeed: 0, upSpeed: 0 }), dl('seed', { downSpeed: 0, upSpeed: 2048 })],
    })
    const cells = container.querySelectorAll('.lt-row .lt-speed')
    expect(cells[0]).toHaveTextContent(/^$/)
    expect(cells[1]!.querySelector('.lt-up')).toHaveTextContent('↑ 2.0 KB/s')
  })

  it('shows the short protocol badge and a progress bar per row', () => {
    renderTable({ tasks: [dl('a', { kind: 'torrent' })] })
    expect(screen.getByText('BT')).toHaveAttribute('title', 'BitTorrent')
    expect(screen.getByRole('progressbar', { name: en.library.progress })).toHaveAttribute('aria-valuenow', '42')
  })

  it('labels the in-row action with the translated action, and only for a session that can write', async () => {
    const { container, handlers: h, unmount } = renderTable({
      tasks: [dl('a'), makeTask('p', { statusToken: 'paused', status: 'Paused' }), makeTask('d', { statusToken: 'completed' })],
    })
    const buttons = container.querySelectorAll<HTMLElement>('.lt-act')
    expect([...buttons].map((b) => b.getAttribute('aria-label'))).toEqual([en.common.pause, en.common.resume])
    await userEvent.click(buttons[1]!)
    expect(h.onAction).toHaveBeenCalledWith('p', 'resume')
    expect(h.onOpen).not.toHaveBeenCalled()
    unmount()
    const ro = renderTable({ canWrite: false, tasks: [dl('a')] })
    expect(ro.container.querySelector('.lt-act')).toBeNull()
  })

  it('switches density by class', () => {
    const { container } = renderTable({ density: 'compact' })
    expect(container.querySelector('.lt.compact')).not.toBeNull()
  })
})

describe('Table — groups', () => {
  it('renders sections as labelled groups with a count', () => {
    const rows = [dl('a'), makeTask('b', { statusToken: 'failed', status: 'Failed' })]
    renderTable({ tasks: rows, groups: groupTasks(rows, 'status') })
    const failed = screen.getByRole('group', { name: /Failed/ })
    expect(within(failed).getByRole('option')).toHaveAttribute('data-id', 'b')
    expect(screen.getByRole('group', { name: /Downloading/ })).toHaveTextContent('1')
  })

  it('names a host-less section by its wording', () => {
    const rows = [makeTask('m', { source: 'magnet:?xt=urn:btih:abc' })]
    renderTable({ tasks: rows, groups: groupTasks(rows, 'host') })
    expect(screen.getByRole('group', { name: new RegExp(en.workflow.group.noHost.replace(/[()]/g, '\\$&')) })).toBeInTheDocument()
  })
})

describe('Table — phone', () => {
  function phone() {
    vi.stubGlobal('matchMedia', (query: string) => ({
      matches: query.includes('max-width: 600px'),
      media: query,
      addEventListener: () => {},
      removeEventListener: () => {},
    }))
  }

  it('gives each card an announced action button and a meta line, and drops the headers', async () => {
    phone()
    const { handlers: h, container } = renderTable({
      tasks: [
        dl('ubuntu', {
          name: 'ubuntu-24.04.iso',
          doneBytes: 2.9 * 1024 ** 3,
          totalBytes: 4.7 * 1024 ** 3,
          downSpeed: 12 * 1024 ** 2,
          etaSeconds: 120,
        }),
      ],
    })
    expect(screen.queryByRole('button', { name: en.library.colName })).toBeNull()
    const button = screen.getByRole('button', { name: 'Pause ubuntu-24.04.iso' })
    expect(button).not.toHaveAttribute('aria-hidden')
    await userEvent.click(button)
    expect(h.onAction).toHaveBeenCalledWith('ubuntu', 'pause')
    expect(h.onOpen).not.toHaveBeenCalled()
    expect(container.querySelector('.lt-pmeta')).toHaveTextContent('2.9/4.7 GB · 12 MB/s · 2m')
    expect(container.querySelector('[aria-label^="More actions"]')).toBeNull()
  })

  it('puts a failed card’s reason in its meta line', () => {
    phone()
    const { container } = renderTable({
      tasks: [makeTask('f', { statusToken: 'failed', status: 'Failed', error: 'Disk full' })],
    })
    expect(container.querySelector('.lt-pmeta')).toHaveTextContent('Failed — Disk full')
  })
})
