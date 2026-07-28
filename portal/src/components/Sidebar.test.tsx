import { screen } from '@testing-library/react'
import { describe, expect, it, vi } from 'vitest'
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

  it('leaves no untranslated key path in the rendered output', () => {
    const { container } = renderSidebar()
    expect(container.textContent).not.toMatch(/\b(sidebar|common|status)\.\w+/)
  })
})
