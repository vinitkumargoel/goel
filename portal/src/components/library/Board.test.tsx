import { fireEvent, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import type { ComponentProps } from 'react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { UNSORTED } from '../../lib/sort'
import type { TaskRow } from '../../lib/types'
import en from '../../locales/en.json'
import boardEn from '../../locales/en.json'
import { makeTask } from '../../test/makeTask'
import { renderWithI18n } from '../../test/renderWithI18n'
import { LibraryView } from './LibraryView'

vi.mock('../../lib/saveFile', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../lib/saveFile')>()),
  saveToDevice: vi.fn(),
}))

const { saveToDevice } = await import('../../lib/saveFile')

const NOW_S = Math.floor(Date.now() / 1000)

const TASKS: TaskRow[] = [
  makeTask('dl', {
    name: 'ubuntu.iso',
    status: 'Downloading',
    statusToken: 'downloading',
    progress: 0.62,
    downSpeed: 12 * 1024 ** 2,
    upSpeed: 640 * 1024,
    totalBytes: 4.7 * 1024 ** 3,
    etaSeconds: 180,
    source: 'https://releases.ubuntu.com/ubuntu.iso',
  }),
  makeTask('meta', { name: 'magnet', status: 'Fetching metadata', statusToken: 'metadata', kind: 'torrent' }),
  makeTask('q2', { name: 'figma.dmg', status: 'Queued', queuePosition: 2 }),
  makeTask('q1', { name: 'field.flac', status: 'Queued', queuePosition: 1, startAt: NOW_S + 3600 }),
  makeTask('fail', { name: 'fedora.iso', status: 'Failed', statusToken: 'failed', error: 'FTP server closed the connection' }),
  makeTask('pause', { name: 'imagenet.zip', status: 'Paused', statusToken: 'paused', progress: 0.34 }),
  makeTask('done', { name: 'bunny.mp4', status: 'Completed', statusToken: 'completed', progress: 1, streamable: true, completedAt: NOW_S - 60 }),
  makeTask('pdf', { name: 'pack.pdf', status: 'Completed', statusToken: 'completed', progress: 1, completedAt: NOW_S - 120 }),
  makeTask('seed', { name: 'debian.iso', status: 'Seeding', statusToken: 'seeding', ratio: 1.2, upSpeed: 1.8 * 1024 ** 2, completedAt: NOW_S - 300 }),
]

type Props = ComponentProps<typeof LibraryView>

function renderBoard(over: Partial<Props> = {}) {
  const h = {
    onSelection: vi.fn(),
    onOpen: vi.fn(),
    onSort: vi.fn(),
    onAction: vi.fn(),
    onMenu: vi.fn(),
    onClearSearch: vi.fn(),
    onAdd: vi.fn(),
    onStream: vi.fn(),
  }
  const tasks = over.tasks ?? TASKS
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
      layout="board"
      {...h}
      {...over}
    />,
  )
  return { ...result, handlers: h }
}

function card(id: string): HTMLElement {
  return screen.getAllByRole('option').find((o) => o.dataset.id === id)!
}

afterEach(() => vi.unstubAllGlobals())

describe('Board — lanes', () => {
  it('lanes every state as the app does, with titles and counts', () => {
    renderBoard()
    const lanes = screen.getAllByRole('group')
    expect(lanes.map((g) => g.getAttribute('data-lane'))).toEqual(['downloading', 'upNext', 'needsYou', 'done'])
    expect(screen.getByRole('group', { name: `${boardEn.board.lane.downloading} 2` })).toBeInTheDocument()
    expect(screen.getByRole('group', { name: `${boardEn.board.lane.upNext} 2` })).toBeInTheDocument()
    expect(screen.getByRole('group', { name: `${boardEn.board.lane.needsYou} 2` })).toBeInTheDocument()
    expect(screen.getByRole('group', { name: `${boardEn.board.lane.doneToday} 3` })).toBeInTheDocument()
  })

  it('says plain Done once a card finished before today', () => {
    renderBoard({ tasks: [makeTask('old', { statusToken: 'completed', completedAt: NOW_S - 3 * 86400 })] })
    expect(screen.getByRole('group', { name: `${boardEn.board.lane.done} 1` })).toBeInTheDocument()
  })

  it('sums the Downloading lane’s rate and says Up next starts in order, in queue order', () => {
    renderBoard()
    const downloading = screen.getByRole('group', { name: /^Downloading/ })
    expect(downloading).toHaveTextContent('↓ 12 MB/s')
    const upNext = screen.getByRole('group', { name: /^Up next/ })
    expect(upNext).toHaveTextContent(boardEn.board.lane.inOrder)
    expect(within(upNext).getAllByRole('option').map((o) => o.dataset.id)).toEqual(['q1', 'q2'])
  })

  it('lanes by the Group by groups when one is chosen', () => {
    renderBoard({ group: 'status' })
    expect(screen.getByRole('group', { name: 'Fetching metadata 1' })).toBeInTheDocument()
    expect(screen.getByRole('group', { name: 'Seeding 1' })).toBeInTheDocument()
    expect(screen.getAllByRole('group')).toHaveLength(7)
  })

  it('walks the cards lane by lane, and across lanes with ← and →', async () => {
    const { handlers: h } = renderBoard({ selectedIds: new Set(['dl']), lead: 'dl' })
    card('dl').focus()
    await userEvent.keyboard('{ArrowRight}')
    expect(h.onSelection).toHaveBeenLastCalledWith({ type: 'single', id: 'q1' })
    expect(card('q1')).toHaveFocus()
    await userEvent.keyboard('{ArrowDown}')
    expect(card('q2')).toHaveFocus()
    await userEvent.keyboard('{ArrowDown}')
    // Reading order runs on into the next lane.
    expect(card('fail')).toHaveFocus()
    await userEvent.keyboard('{ArrowLeft}')
    expect(card('q1')).toHaveFocus()
    await userEvent.keyboard('{ArrowLeft}')
    expect(card('dl')).toHaveFocus()
  })

  it('ranges over the lane order on Shift-click', async () => {
    const { handlers: h } = renderBoard({ lead: 'dl', selectedIds: new Set(['dl']) })
    const user = userEvent.setup()
    await user.keyboard('{Shift>}')
    await user.click(card('q2'))
    await user.keyboard('{/Shift}')
    expect(h.onSelection).toHaveBeenCalledWith({
      type: 'range',
      id: 'q2',
      order: ['dl', 'meta', 'q1', 'q2', 'fail', 'pause', 'done', 'pdf', 'seed'],
    })
  })
})

describe('Board — cards', () => {
  it('draws the moving download as the tall card: badge, arc, host and size, rates', () => {
    renderBoard()
    const dl = card('dl')
    expect(dl).toHaveClass('dcard')
    expect(within(dl).getByText('HTTP')).toBeInTheDocument()
    expect(within(dl).getByRole('progressbar', { name: en.library.progress })).toHaveAttribute('aria-valuenow', '62')
    expect(dl).toHaveTextContent('releases.ubuntu.com · 4.7 GB')
    expect(dl).toHaveTextContent('↓ 12 MB/s')
    expect(dl).toHaveTextContent('↑ 640 KB/s')
    expect(dl).toHaveTextContent('3m left')
  })

  it('draws every other state as a compact card saying what that state is about', () => {
    renderBoard()
    expect(card('meta')).toHaveClass('mcard')
    expect(card('meta')).toHaveTextContent(boardEn.board.card.requesting)
    expect(within(card('meta')).getByRole('progressbar')).not.toHaveAttribute('aria-valuenow')
    expect(card('q2')).toHaveTextContent('HTTP · 977 KB · Queued · #3')
    expect(card('q1')).toHaveTextContent(/Queued · #2 · starts /)
    expect(card('fail')).toHaveClass('fail')
    expect(card('fail')).toHaveTextContent('FTP server closed the connection')
    expect(card('pause')).toHaveTextContent('Paused · 34% · 977 KB')
    expect(card('pause').querySelector('.art')).toHaveClass('faded')
    expect(card('seed')).toHaveTextContent('Seeding 1.20× · ↑ 1.8 MB/s')
    expect(card('done')).toHaveTextContent('HTTP · 977 KB')
  })

  it('switches every card to compact in compact density', () => {
    renderBoard({ density: 'compact' })
    expect(card('dl')).toHaveClass('mcard')
    expect(card('dl')).toHaveTextContent('62% · ↓ 12 MB/s · 3m')
  })

  it('marks the selection with the accent ring class', () => {
    renderBoard({ selectedIds: new Set(['pause']) })
    expect(card('pause')).toHaveClass('sel')
    expect(card('pause')).toHaveAttribute('aria-selected', 'true')
  })

  it('wires each card’s buttons: pause, retry, resume, play and save', async () => {
    const { handlers: h } = renderBoard()
    const press = (id: string, label: string) =>
      fireEvent.click(card(id).querySelector<HTMLElement>(`[aria-label="${label}"]`)!)
    press('dl', en.common.pause)
    expect(h.onAction).toHaveBeenLastCalledWith('dl', 'pause')
    press('fail', en.common.retry)
    expect(h.onAction).toHaveBeenLastCalledWith('fail', 'retry')
    press('pause', en.common.resume)
    expect(h.onAction).toHaveBeenLastCalledWith('pause', 'resume')
    press('done', en.common.stream)
    expect(h.onStream).toHaveBeenCalledWith(expect.objectContaining({ id: 'done' }))
    press('pdf', en.menu.saveToDevice)
    expect(saveToDevice).toHaveBeenCalledWith(expect.stringContaining('pdf'), 'pack.pdf')
    expect(h.onOpen).not.toHaveBeenCalled()
  })

  it('offers a read-only session play and save, but nothing that changes a download', () => {
    renderBoard({ canWrite: false })
    expect(card('dl').querySelector(`[aria-label="${en.common.pause}"]`)).toBeNull()
    expect(card('fail').querySelector(`[aria-label="${en.common.retry}"]`)).toBeNull()
    expect(card('pause').querySelector(`[aria-label="${en.common.resume}"]`)).toBeNull()
    expect(card('done').querySelector(`[aria-label="${en.common.stream}"]`)).not.toBeNull()
    expect(card('pdf').querySelector(`[aria-label="${en.menu.saveToDevice}"]`)).not.toBeNull()
  })

  it('announces the card buttons on a phone, with the download’s name', () => {
    vi.stubGlobal('matchMedia', (query: string) => ({
      matches: query.includes('max-width: 600px'),
      media: query,
      addEventListener: () => {},
      removeEventListener: () => {},
    }))
    renderBoard()
    expect(screen.getByRole('button', { name: 'Retry fedora.iso' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Stream bunny.mp4' })).toBeInTheDocument()
    expect(screen.queryAllByRole('button', { name: /More actions/ })).toEqual([])
    expect(document.querySelector('[aria-label^="More actions"]')).toBeNull()
  })
})
