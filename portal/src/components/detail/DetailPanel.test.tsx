import { fireEvent, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import type { ComponentProps } from 'react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import en from '../../locales/en.json'
import sheet from '../../locales/en.json'
import { speedStore } from '../../lib/speedStore'
import type { TaskDetail, TaskRow } from '../../lib/types'
import { makeTask } from '../../test/makeTask'
import { renderWithI18n } from '../../test/renderWithI18n'
import { DetailPanel } from './DetailPanel'
import type { DetailTab } from './DetailPanes'

const S = sheet.sheet

const ROW: TaskRow = makeTask('t1', {
  name: 'debian-13.iso',
  status: 'Paused',
  statusToken: 'paused',
  kind: 'torrent',
  progress: 0.5,
  totalBytes: 4_000_000_000,
  doneBytes: 2_000_000_000,
  upBytes: 100_000,
  ratio: 0.05,
  seeds: 12,
  conns: 30,
  addedAt: 1_700_000_000,
  source: 'magnet:?xt=urn:btih:abc',
  multiFile: true,
  fileCount: 3,
})

const DETAIL: TaskDetail = {
  row: ROW,
  savePath: '/srv/downloads/debian-13.iso',
  sequential: true,
  infoHash: 'abc123',
  files: [],
  trackers: [],
  connections: [],
  pieces: [],
  server: null,
  mimeType: null,
}

const HTTP: TaskDetail = {
  ...DETAIL,
  row: {
    ...ROW,
    kind: 'http',
    multiFile: false,
    fileCount: 1,
    statusToken: 'downloading',
    status: 'Downloading',
    source: 'https://example.org/debian-13.iso',
  },
  server: 'Apache',
  mimeType: 'application/x-iso9660-image',
  connections: [
    { id: 's1', label: 'Segment 1', detail: '0–1 GB', down: 1024, up: 0, progress: 1, adapterId: null, adapterLabel: null },
    { id: 's2', label: 'Segment 2', detail: '1–2 GB', down: 2048, up: 0, progress: 0.5, adapterId: null, adapterLabel: null },
  ],
}

afterEach(() => {
  vi.unstubAllGlobals()
  speedStore.reset()
})

/** Pretends the viewport is `width` px wide, for the panel's two breakpoints. */
function viewport(width: number) {
  vi.stubGlobal('matchMedia', (query: string) => {
    const max = Number(/max-width:\s*(\d+)px/.exec(query)?.[1] ?? Infinity)
    return { matches: width <= max, media: query, addEventListener: () => {}, removeEventListener: () => {} }
  })
}

type Props = ComponentProps<typeof DetailPanel>

function renderPanel(detail: TaskDetail | null, over: Partial<Props> = {}) {
  const props: Props = {
    detail,
    open: true,
    tab: 'overview',
    canWrite: true,
    onTab: vi.fn(),
    onClose: vi.fn(),
    onAction: vi.fn(),
    onRemove: vi.fn(),
    onMore: vi.fn(),
    onCopy: vi.fn(),
    onSetFiles: vi.fn(() => Promise.resolve()),
    onCyclePriority: vi.fn(),
    ...over,
  }
  return { ...renderWithI18n(<DetailPanel {...props} />), props }
}

function withRow(over: Partial<TaskRow>, detail: TaskDetail = DETAIL): TaskDetail {
  return { ...detail, row: { ...detail.row, ...over } }
}

describe('DetailPanel · frame', () => {
  it('shows the overview it is given when nothing is selected', () => {
    renderPanel(null, { overview: <p>queue overview</p> })
    expect(screen.getByText('queue overview')).toBeInTheDocument()
  })

  it('says it is loading when a download is picked but its detail has not arrived', () => {
    renderPanel(null)
    expect(screen.getByRole('status')).toHaveTextContent(en.common.loading)
  })

  it('hides itself from assistive tech and the tab order while closed', () => {
    const { container } = renderPanel(DETAIL, { open: false })
    const aside = container.querySelector('aside')!
    expect(aside).toHaveAttribute('aria-hidden', 'true')
    expect(aside).toHaveAttribute('inert')
    expect(aside).toHaveClass('closed')
  })

  it('stays a plain complementary panel on wide screens', () => {
    renderPanel(DETAIL)
    expect(screen.queryByRole('dialog')).toBeNull()
    expect(screen.getByRole('complementary', { name: en.detail.label })).toBeInTheDocument()
  })

  it('floats over the board as a modal dialog at narrow widths: focus inside, Escape and the scrim close', async () => {
    viewport(800)
    const onClose = vi.fn()
    const { container } = renderPanel(DETAIL, { onClose })
    const sheet = screen.getByRole('dialog', { name: en.detail.label })
    expect(sheet).toHaveAttribute('aria-modal', 'true')
    expect(sheet).toHaveClass('over')
    expect(sheet).not.toHaveClass('phone')
    expect(screen.getByRole('button', { name: en.detail.closePanel })).toHaveFocus()
    await userEvent.keyboard('{Escape}')
    expect(onClose).toHaveBeenCalledTimes(1)
    fireEvent.click(container.querySelector('.dscrim')!)
    expect(onClose).toHaveBeenCalledTimes(2)
    expect(container.querySelector('.dgrab')).toBeNull()
  })

  it('leaves Tab and Escape to a dialog stacked over it', async () => {
    viewport(800)
    const onClose = vi.fn()
    renderPanel(DETAIL, { onClose, trapFocus: false })
    await userEvent.keyboard('{Escape}')
    expect(onClose).not.toHaveBeenCalled()
  })

  it('gives the overview a close button when it floats', async () => {
    viewport(800)
    const onClose = vi.fn()
    renderPanel(null, { onClose, overview: <p>queue overview</p> })
    const close = screen.getByRole('button', { name: en.detail.closePanel })
    expect(close).toHaveFocus()
    await userEvent.click(close)
    expect(onClose).toHaveBeenCalled()
  })

  it('becomes a full-height sheet on phones and dismisses when its grabber is dragged down far enough', () => {
    viewport(390)
    const onClose = vi.fn()
    const { container } = renderPanel(DETAIL, { onClose })
    const sheet = screen.getByRole('dialog', { name: en.detail.label })
    expect(sheet).toHaveClass('phone')
    const grabber = container.querySelector<HTMLElement>('.dgrab')!
    expect(grabber).toHaveAttribute('title', en.detail.sheetHandle)
    fireEvent.pointerDown(grabber, { clientY: 100, pointerId: 1 })
    fireEvent.pointerMove(grabber, { clientY: 140, pointerId: 1 })
    expect(sheet.style.transform).toBe('translateY(40px)')
    fireEvent.pointerUp(grabber, { clientY: 140, pointerId: 1 })
    expect(onClose).not.toHaveBeenCalled()
    fireEvent.pointerDown(grabber, { clientY: 100, pointerId: 1 })
    fireEvent.pointerUp(grabber, { clientY: 260, pointerId: 1 })
    expect(onClose).toHaveBeenCalled()
  })

  it('grows with the finger when the phone sheet is pulled up, and goes tall past the detent', () => {
    viewport(390)
    const { container } = renderPanel(DETAIL)
    const sheet = screen.getByRole('dialog')
    const grabber = container.querySelector<HTMLElement>('.dgrab')!
    fireEvent.pointerDown(grabber, { clientY: 300, pointerId: 1 })
    fireEvent.pointerMove(grabber, { clientY: 250, pointerId: 1 })
    expect(sheet.style.getPropertyValue('--grow')).toBe('50px')
    fireEvent.pointerUp(grabber, { clientY: 200, pointerId: 1 })
    expect(sheet).toHaveClass('expanded')
  })
})

describe('DetailPanel · head and tabs', () => {
  it('breaks a long title at separators and keeps the full name as its tooltip', () => {
    renderPanel(withRow({ name: 'Some.Show.S01E01.1080p' }))
    const title = screen.getByRole('heading', { level: 2 })
    expect(title).toHaveAttribute('title', 'Some.Show.S01E01.1080p')
    expect(title.querySelectorAll('wbr').length).toBeGreaterThan(0)
  })

  it('shows the kind badge, the state pill with time left, and live rates while downloading', () => {
    renderPanel(withRow({ statusToken: 'downloading', status: 'Downloading', etaSeconds: 120, downSpeed: 2048, upSpeed: 1024 }))
    expect(screen.getByTitle('BitTorrent')).toHaveTextContent('BT')
    expect(screen.getByText('Downloading · 2m left')).toHaveClass('pill', 'acc')
    expect(screen.getByText('Download 2.0 KB/s, upload 1.0 KB/s')).toBeInTheDocument()
  })

  it('draws a failed download’s pill in the bad tone', () => {
    renderPanel(withRow({ statusToken: 'failed', status: 'Failed' }))
    expect(screen.getByText('Failed', { selector: '.pill' })).toHaveClass('bad')
  })

  it('translates the close-panel accessible name and closes from it', async () => {
    const { props } = renderPanel(DETAIL)
    await userEvent.click(screen.getByRole('button', { name: en.detail.closePanel }))
    expect(props.onClose).toHaveBeenCalled()
  })

  it('offers Overview, Files, Peers and Network for a torrent, labelled from the catalogue', () => {
    renderPanel(DETAIL)
    const names = screen.getAllByRole('tab').map((tab) => tab.textContent)
    expect(names).toEqual([S.tabs.overview, en.detail.tabs.files, en.detail.tabs.peers, S.tabs.network])
  })

  it('has no Peers tab for an HTTP download, and shows Overview if Peers was left selected', () => {
    renderPanel(HTTP, { tab: 'peers' })
    expect(screen.queryByRole('tab', { name: en.detail.tabs.peers })).toBeNull()
    expect(screen.getByRole('tab', { name: S.tabs.overview })).toHaveAttribute('aria-selected', 'true')
  })

  it('exposes the sections as a tablist with the current tab selected', () => {
    renderPanel(DETAIL)
    expect(screen.getByRole('tablist', { name: en.detail.tabsLabel })).toBeInTheDocument()
    const overview = screen.getByRole('tab', { name: S.tabs.overview })
    expect(overview).toHaveAttribute('aria-selected', 'true')
    expect(overview).toHaveAttribute('tabindex', '0')
    expect(screen.getByRole('tab', { name: S.tabs.network })).toHaveAttribute('tabindex', '-1')
    const panel = screen.getByRole('tabpanel')
    expect(panel).toHaveAttribute('aria-labelledby', overview.id)
    expect(overview).toHaveAttribute('aria-controls', panel.id)
  })

  it.each<[string, DetailTab, DetailTab]>([
    ['ArrowRight', 'overview', 'files'],
    ['ArrowLeft', 'overview', 'network'],
    ['End', 'overview', 'network'],
    ['Home', 'network', 'overview'],
    ['ArrowRight', 'network', 'overview'],
  ])('moves with %s from %s to %s', async (key, from, to) => {
    const onTab = vi.fn()
    renderPanel(DETAIL, { tab: from, onTab })
    screen.getAllByRole('tab').find((tab) => tab.getAttribute('aria-selected') === 'true')!.focus()
    await userEvent.keyboard(`{${key}}`)
    expect(onTab).toHaveBeenCalledWith(to)
  })

  it('skips the missing Peers tab with the arrow keys', async () => {
    const onTab = vi.fn()
    renderPanel(HTTP, { tab: 'files', onTab })
    screen.getByRole('tab', { name: en.detail.tabs.files }).focus()
    await userEvent.keyboard('{ArrowRight}')
    expect(onTab).toHaveBeenCalledWith('network')
  })

  it('switches tab on click', async () => {
    const onTab = vi.fn()
    renderPanel(DETAIL, { onTab })
    await userEvent.click(screen.getByRole('tab', { name: en.detail.tabs.peers }))
    expect(onTab).toHaveBeenCalledWith('peers')
  })
})

describe('DetailPanel · action bar', () => {
  it('puts the primary action first, then copy, remove and more', async () => {
    const { props } = renderPanel(DETAIL)
    const bar = screen.getByRole('group', { name: en.detail.actions })
    const buttons = within(bar).getAllByRole('button')
    expect(buttons).toHaveLength(4)
    expect(buttons[0]).toHaveClass('pri')
    expect(buttons[0]).toHaveAccessibleName(en.common.resume)
    await userEvent.click(buttons[0]!)
    expect(props.onAction).toHaveBeenCalledWith('t1', 'resume')
  })

  it('offers Pause while downloading and Retry after a failure', () => {
    const { unmount } = renderPanel(HTTP)
    expect(within(screen.getByRole('group', { name: en.detail.actions })).getByRole('button', { name: en.common.pause })).toBeInTheDocument()
    unmount()
    renderPanel(withRow({ statusToken: 'failed', status: 'Failed' }))
    expect(within(screen.getByRole('group', { name: en.detail.actions })).getByRole('button', { name: en.common.retry })).toBeInTheDocument()
  })

  it('copies the magnet, naming it so, and an ordinary link as a link', async () => {
    const { props, unmount } = renderPanel(DETAIL)
    await userEvent.click(screen.getByRole('button', { name: S.copyMagnet }))
    expect(props.onCopy).toHaveBeenCalledWith('magnet:?xt=urn:btih:abc')
    unmount()
    renderPanel(HTTP)
    expect(screen.getByRole('button', { name: en.common.copyLink })).toBeInTheDocument()
  })

  it('opens the remove and more menus above their buttons', async () => {
    const { props } = renderPanel(DETAIL)
    const remove = screen.getByRole('button', { name: en.common.remove })
    expect(remove).toHaveAttribute('aria-haspopup', 'menu')
    await userEvent.click(remove)
    expect(props.onRemove).toHaveBeenCalledWith('t1', { x: 0, y: -6 })
    const more = screen.getByRole('button', { name: en.detail.moreActions })
    expect(more).toHaveAttribute('aria-haspopup', 'menu')
    await userEvent.click(more)
    expect(props.onMore).toHaveBeenCalledWith('t1', expect.objectContaining({ x: expect.any(Number) }))
  })

  it('offers a read-only session no primary action and no Remove', () => {
    renderPanel(DETAIL, { canWrite: false })
    const bar = screen.getByRole('group', { name: en.detail.actions })
    expect(within(bar).queryByRole('button', { name: en.common.resume })).toBeNull()
    expect(within(bar).queryByRole('button', { name: en.common.remove })).toBeNull()
    expect(within(bar).getAllByRole('button')).toHaveLength(2)
  })

  it('saves a finished file to the device, or a multi-file download as one zip', () => {
    const single = withRow({ statusToken: 'completed', status: 'Completed', multiFile: false, kind: 'http' })
    const { unmount } = renderPanel(single)
    const save = screen.getByRole('link', { name: en.menu.saveToDevice })
    expect(save).toHaveAttribute('href', '/stream?id=t1&dl=1')
    expect(save).toHaveAttribute('download', 'debian-13.iso')
    unmount()
    renderPanel(withRow({ statusToken: 'seeding', status: 'Seeding' }), { canWrite: false })
    const all = screen.getByRole('link', { name: en.detail.downloadAll })
    expect(all).toHaveAttribute('href', '/stream?id=t1&zip=1')
    expect(all).toHaveAttribute('title', en.detail.downloadAllHint)
  })

  it('streams a read-only, still-running download that can play', async () => {
    const onStream = vi.fn()
    renderPanel(withRow({ statusToken: 'downloading', status: 'Downloading', streamable: true }), { canWrite: false, onStream })
    await userEvent.click(screen.getByRole('button', { name: en.common.stream }))
    expect(onStream).toHaveBeenCalledWith(expect.objectContaining({ id: 't1' }))
  })

  it('opens the stream in a new tab when the app has no player', async () => {
    const open = vi.fn()
    vi.stubGlobal('open', open)
    renderPanel(withRow({ statusToken: 'downloading', status: 'Downloading', streamable: true }), { canWrite: false })
    await userEvent.click(screen.getByRole('button', { name: en.common.stream }))
    expect(open).toHaveBeenCalledWith('/stream?id=t1', '_blank', 'noopener,noreferrer')
  })
})
