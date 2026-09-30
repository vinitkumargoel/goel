import { screen } from '@testing-library/react'
import { createRef } from 'react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { renderWithI18n } from '../test/renderWithI18n'
import en from '../locales/en.json'
import { Sidebar, type FilterCounts } from './Sidebar'

const COUNTS: FilterCounts = {
  all: 7,
  active: 2,
  paused: 1,
  completed: 3,
  seeding: 1,
  failed: 0,
  video: 4,
  iso: 2,
  archive: 0,
  app: 0,
}

function renderSidebar() {
  return renderWithI18n(
    <Sidebar
      view="library"
      filter="all"
      counts={COUNTS}
      open={false}
      onSelectFilter={vi.fn()}
      onSelectView={vi.fn()}
      onClose={vi.fn()}
    />,
  )
}

describe('Sidebar', () => {
  it('renders its section headings from the catalogue', () => {
    renderSidebar()
    expect(screen.getByText(en.sidebar.library)).toBeInTheDocument()
    expect(screen.getByText(en.sidebar.status)).toBeInTheDocument()
    expect(screen.getByText(en.sidebar.tools)).toBeInTheDocument()
  })

  it('renders every status filter label from the catalogue', () => {
    renderSidebar()
    for (const label of Object.values(en.status)) {
      expect(screen.getByText(label)).toBeInTheDocument()
    }
  })

  it('renders the shared nav labels from the catalogue', () => {
    renderSidebar()
    expect(screen.getByText(en.sidebar.allDownloads)).toBeInTheDocument()
    expect(screen.getByText(en.common.history)).toBeInTheDocument()
    expect(screen.getByText(en.common.settings)).toBeInTheDocument()
  })

  it('still shows the per-filter counts', () => {
    renderSidebar()
    expect(screen.getByText('7')).toBeInTheDocument()
    expect(screen.getByText('3')).toBeInTheDocument()
  })

  it('renders the Type group from the catalogue', () => {
    renderSidebar()
    expect(screen.getByText(en.sidebar.type)).toBeInTheDocument()
    for (const label of Object.values(en.fileType)) {
      expect(screen.getByText(label)).toBeInTheDocument()
    }
  })

  it('makes every item a real button and marks the current filter', () => {
    renderSidebar()
    const all = screen.getByRole('button', { name: new RegExp(en.sidebar.allDownloads) })
    expect(all).toHaveAttribute('aria-current', 'page')
    expect(screen.getByRole('button', { name: new RegExp(en.common.history) })).toBeInTheDocument()
  })

  it('leaves no untranslated key path in the rendered output', () => {
    const { container } = renderSidebar()
    expect(container.textContent).not.toMatch(/\b(sidebar|common|status|fileType)\.\w+/)
  })

  describe('as an off-canvas drawer', () => {
    afterEach(() => {
      vi.unstubAllGlobals()
    })

    function asDrawer() {
      vi.stubGlobal('matchMedia', (query: string) => ({
        matches: true,
        media: query,
        addEventListener: () => {},
        removeEventListener: () => {},
      }))
    }

    function drawer(open: boolean, returnFocusTo = createRef<HTMLButtonElement>()) {
      return (
        <Sidebar
          view="library"
          filter="all"
          counts={COUNTS}
          open={open}
          onSelectFilter={vi.fn()}
          onSelectView={vi.fn()}
          onClose={vi.fn()}
          returnFocusTo={returnFocusTo}
        />
      )
    }

    it('is inert while closed, so Tab and screen readers skip it', () => {
      asDrawer()
      const { rerender } = renderWithI18n(drawer(false))
      const nav = screen.getByRole('navigation', { hidden: true })
      expect(nav).toHaveAttribute('inert')
      rerender(drawer(true))
      expect(nav).not.toHaveAttribute('inert')
    })

    it('takes focus on open and hands it back to the hamburger on close', () => {
      asDrawer()
      const hamburger = document.createElement('button')
      document.body.appendChild(hamburger)
      const ref = { current: hamburger }
      const { rerender } = renderWithI18n(drawer(false, ref))
      rerender(drawer(true, ref))
      expect(screen.getByRole('button', { name: new RegExp(en.sidebar.allDownloads) })).toHaveFocus()
      rerender(drawer(false, ref))
      expect(hamburger).toHaveFocus()
      hamburger.remove()
    })
  })
})
