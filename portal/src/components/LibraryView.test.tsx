import { screen } from '@testing-library/react'
import { describe, expect, it, vi } from 'vitest'
import { renderWithI18n } from '../test/renderWithI18n'
import en from '../locales/en.json'
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

function renderLibrary(over: { tasks?: TaskRow[]; readOnly?: boolean } = {}) {
  return renderWithI18n(
    <LibraryView
      tasks={over.tasks ?? []}
      selectedId={null}
      canWrite
      readOnly={over.readOnly ?? false}
      onSelect={vi.fn()}
      onAction={vi.fn()}
      onContextMenu={vi.fn()}
    />,
  )
}

describe('LibraryView', () => {
  it('renders the column headers from the catalogue', () => {
    renderLibrary()
    expect(screen.getByText(en.library.colName)).toBeInTheDocument()
    expect(screen.getByText(en.library.colSize)).toBeInTheDocument()
    expect(screen.getByText(en.library.colStatus)).toBeInTheDocument()
    expect(screen.getByText(en.library.colSpeed)).toBeInTheDocument()
  })

  it('renders the empty state from the catalogue', () => {
    renderLibrary()
    expect(screen.getByText(en.library.emptyTitle)).toBeInTheDocument()
  })

  it('renders the empty-state body as rich text with the Add label bolded', () => {
    const { container } = renderLibrary()
    const bold = container.querySelector('.empty p b')
    expect(bold).not.toBeNull()
    expect(bold).toHaveTextContent(en.common.add)

    // The <bold> tag must be consumed by Trans, not printed.
    expect(container.textContent).not.toContain('<bold>')
    expect(container.textContent).toContain('to queue a URL, magnet, or torrent.')
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
    expect(screen.getByText(/Downloading/)).toBeInTheDocument()
  })
})
