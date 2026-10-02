import { screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { createRef, type ComponentProps } from 'react'
import { describe, expect, it, vi } from 'vitest'
import en from '../../locales/en.json'
import { i18n, renderWithI18n } from '../../test/renderWithI18n'
import { Rail, type FilterCounts } from './Rail'

const COUNTS: FilterCounts = {
  all: 7,
  active: 2,
  queued: 0,
  paused: 1,
  completed: 3,
  seeding: 1,
  failed: 0,
  video: 4,
  iso: 2,
  archive: 0,
  app: 0,
  audio: 0,
  image: 0,
  doc: 0,
  other: 0,
}

type Props = ComponentProps<typeof Rail>

function props(over: Partial<Props> = {}): Props {
  return {
    view: 'library',
    filter: 'all',
    counts: COUNTS,
    canWrite: true,
    onSelectFilter: vi.fn(),
    onSelectView: vi.fn(),
    onSelectTag: vi.fn(),
    onAdd: vi.fn(),
    variant: 'rail',
    expanded: true,
    onToggleExpanded: vi.fn(),
    ...over,
  }
}

describe('Rail, expanded', () => {
  it('renders its section headings and every status from the catalogue', () => {
    renderWithI18n(<Rail {...props()} />)
    for (const heading of [en.sidebar.library, en.sidebar.status, en.sidebar.type, en.sidebar.tools]) {
      expect(screen.getByText(heading)).toBeInTheDocument()
    }
    for (const label of Object.values(en.status)) expect(screen.getByText(label)).toBeInTheDocument()
    expect(screen.getByText(en.sidebar.allDownloads)).toBeInTheDocument()
    expect(screen.getByText(en.common.history)).toBeInTheDocument()
    expect(screen.getByText(en.common.settings)).toBeInTheDocument()
  })

  it('shows the per-filter counts and marks the current filter', () => {
    renderWithI18n(<Rail {...props()} />)
    const all = screen.getByRole('button', { name: new RegExp(en.sidebar.allDownloads) })
    expect(all).toHaveAttribute('aria-current', 'page')
    expect(all).toHaveTextContent('7')
    expect(screen.getByRole('button', { name: new RegExp(en.status.completed) })).toHaveTextContent('3')
  })

  it('folds away empty types until asked', async () => {
    renderWithI18n(<Rail {...props()} />)
    expect(screen.getByText(en.fileType.video)).toBeInTheDocument()
    expect(screen.queryByText(en.fileType.audio)).toBeNull()
    const more = screen.getByRole('button', { name: 'Show 6 more types' })
    expect(more).toHaveAttribute('aria-expanded', 'false')
    await userEvent.click(more)
    for (const label of Object.values(en.fileType)) expect(screen.getByText(label)).toBeInTheDocument()
    expect(screen.getByRole('button', { name: en.sidebar.fewerTypes })).toHaveAttribute('aria-expanded', 'true')
  })

  it('flags failures in red only when there are some', () => {
    const { unmount, container } = renderWithI18n(<Rail {...props()} />)
    expect(container.querySelector('.n.bad')).toBeNull()
    unmount()
    const again = renderWithI18n(<Rail {...props({ counts: { ...COUNTS, failed: 2 } })} />)
    expect(again.container.querySelector('.n.bad')).toHaveTextContent('2')
  })

  it('selects filters, views and tags', async () => {
    const p = props({ tags: [{ tag: 'linux', count: 3 }] })
    renderWithI18n(<Rail {...p} />)
    await userEvent.click(screen.getByRole('button', { name: new RegExp(en.status.paused) }))
    await userEvent.click(screen.getByRole('button', { name: new RegExp(en.common.history) }))
    await userEvent.click(screen.getByRole('button', { name: /linux/ }))
    expect(p.onSelectFilter).toHaveBeenCalledWith('paused')
    expect(p.onSelectView).toHaveBeenCalledWith('history')
    expect(p.onSelectTag).toHaveBeenCalledWith('linux')
  })

  it('marks the active tag instead of the filter', () => {
    renderWithI18n(<Rail {...props({ tags: [{ tag: 'linux', count: 3 }], activeTag: 'Linux' })} />)
    expect(screen.getByRole('button', { name: /linux/ })).toHaveAttribute('aria-current', 'page')
    expect(screen.getByRole('button', { name: new RegExp(en.sidebar.allDownloads) })).not.toHaveAttribute('aria-current')
  })

  it('leaves no untranslated key path in the rendered output', () => {
    const { container } = renderWithI18n(<Rail {...props()} />)
    expect(container.textContent).not.toMatch(/\b(sidebar|common|status|fileType|shell)\.\w+/)
  })
})

describe('Rail, slim', () => {
  it('names icon-only items, with a count only where there is one', () => {
    renderWithI18n(<Rail {...props({ expanded: false })} />)
    expect(screen.getByRole('button', { name: `${en.sidebar.allDownloads}, 7` })).toBeInTheDocument()
    const queued = screen.getByRole('button', { name: en.status.queued })
    expect(queued).toHaveAttribute('title', en.status.queued)
    expect(queued.querySelector('.dot')).toBeNull()
    // Types live in the wide rail and the drawer only.
    expect(screen.queryByText(en.sidebar.type)).toBeNull()
  })

  it('caps a big count dot at 99+', () => {
    renderWithI18n(<Rail {...props({ expanded: false, counts: { ...COUNTS, all: 140 } })} />)
    expect(screen.getByRole('button', { name: `${en.sidebar.allDownloads}, 140` })).toHaveTextContent('99+')
  })

  it('adds and toggles labels', async () => {
    const p = props({ expanded: false })
    renderWithI18n(<Rail {...p} />)
    await userEvent.click(screen.getByRole('button', { name: i18n.t('shell.rail.add') }))
    const pin = screen.getByRole('button', { name: i18n.t('shell.rail.expand') })
    expect(pin).toHaveAttribute('aria-pressed', 'false')
    await userEvent.click(pin)
    expect(p.onAdd).toHaveBeenCalled()
    expect(p.onToggleExpanded).toHaveBeenCalled()
  })

  it('has no Add for a read-only session', () => {
    renderWithI18n(<Rail {...props({ canWrite: false })} />)
    expect(screen.queryByRole('button', { name: i18n.t('shell.rail.add') })).toBeNull()
  })
})

describe('Rail, as the phone drawer', () => {
  function drawer(open: boolean, returnFocusTo = createRef<HTMLButtonElement>(), onClose = vi.fn()) {
    return <Rail {...props({ variant: 'drawer', open, returnFocusTo, onClose, footer: <button>Pause all</button> })} />
  }

  it('is inert while closed, so Tab and screen readers skip it', () => {
    const { rerender } = renderWithI18n(drawer(false))
    const nav = screen.getByRole('navigation', { hidden: true })
    expect(nav).toHaveAttribute('inert')
    rerender(drawer(true))
    expect(nav).not.toHaveAttribute('inert')
    expect(nav).toHaveAccessibleName(i18n.t('shell.drawer.title'))
  })

  it('takes focus on open and hands it back to the Filters tab on close', () => {
    const tab = document.createElement('button')
    document.body.appendChild(tab)
    const ref = { current: tab }
    const { rerender } = renderWithI18n(drawer(false, ref))
    rerender(drawer(true, ref))
    expect(screen.getByRole('button', { name: new RegExp(en.sidebar.allDownloads) })).toHaveFocus()
    rerender(drawer(false, ref))
    expect(tab).toHaveFocus()
    tab.remove()
  })

  it('closes from its button and carries the footer', async () => {
    const onClose = vi.fn()
    renderWithI18n(drawer(true, createRef(), onClose))
    expect(screen.getByRole('button', { name: 'Pause all' })).toBeInTheDocument()
    await userEvent.click(screen.getByRole('button', { name: en.common.close }))
    expect(onClose).toHaveBeenCalled()
  })
})
