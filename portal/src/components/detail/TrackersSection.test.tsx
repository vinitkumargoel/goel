import { screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it, vi } from 'vitest'
import type { QueueControls } from '../../hooks/useQueueControls'
import en from '../../locales/en.json'
import type { TrackerRow } from '../../lib/types'
import { renderWithI18n } from '../../test/renderWithI18n'
import { TrackersSection } from './TrackersSection'

const TRACKERS: TrackerRow[] = [
  { url: 'udp://a.example:80/announce', host: 'a.example', tier: 0, status: 'Working', state: 'working', seeds: 5, leeches: 2, message: '' },
  { url: 'udp://b.example:80/announce', host: 'b.example', tier: 1, status: 'Timed out', state: 'error', seeds: null, leeches: null, message: 'Timed out' },
  { url: 'https://c.example/announce', host: '', tier: 2, status: 'Updating', state: 'updating', seeds: null, leeches: null, message: '' },
]

function controls(ok = true) {
  return {
    edit: vi.fn(),
    move: vi.fn(),
    setSequential: vi.fn(),
    setTags: vi.fn(),
    setStartAt: vi.fn(),
    editTrackers: vi.fn(() => Promise.resolve(ok)),
  } satisfies QueueControls
}

describe('TrackersSection', () => {
  it('shows an erroring tracker in red with its message, and no controls when read-only', () => {
    renderWithI18n(<TrackersSection taskId="t" trackers={TRACKERS} />)
    expect(screen.getByText('Error')).toHaveClass('pill', 'bad')
    expect(screen.getByText('Timed out')).toBeInTheDocument()
    expect(screen.getByText('Working')).toHaveClass('pill', 'good')
    expect(screen.getByText('Updating')).toHaveClass('pill', 'warn')
    expect(screen.queryByRole('button', { name: /Add/ })).toBeNull()
    expect(screen.queryByRole('button', { name: /Remove tracker/ })).toBeNull()
  })

  it('counts the trackers, shows seeds and leechers where sent, and falls back to the URL for a missing host', () => {
    renderWithI18n(<TrackersSection taskId="t" trackers={TRACKERS} />)
    expect(screen.getByText('Trackers · 3')).toBeInTheDocument()
    expect(screen.getByText('5 seeds · 2 leechers')).toBeInTheDocument()
    expect(screen.getByTitle('https://c.example/announce')).toHaveTextContent('https://c.example/announce')
  })

  it('renders nothing for a read-only torrent without trackers, and says so to a writer', () => {
    const { container, unmount } = renderWithI18n(<TrackersSection taskId="t" trackers={[]} />)
    expect(container).toBeEmptyDOMElement()
    unmount()
    renderWithI18n(<TrackersSection taskId="t" trackers={[]} queue={controls()} />)
    expect(screen.getByText(en.trackers.none)).toBeInTheDocument()
  })

  it('adds pasted trackers in one request and refuses a bad URL', async () => {
    const queue = controls()
    renderWithI18n(<TrackersSection taskId="t" trackers={TRACKERS} queue={queue} />)
    await userEvent.click(screen.getByRole('button', { name: 'Add' }))
    const box = screen.getByRole('textbox', { name: 'Tracker URLs to add' })
    expect(box).toHaveFocus()
    await userEvent.type(box, 'udp://c.example/announce junk')
    expect(screen.getByText('Not a tracker announce URL: junk')).toBeInTheDocument()
    expect(box).toHaveAttribute('aria-invalid', 'true')
    expect(screen.getByRole('button', { name: 'Add 1 tracker' })).toBeDisabled()
    await userEvent.clear(box)
    await userEvent.type(box, 'udp://c.example/announce, https://d.example/announce')
    await userEvent.click(screen.getByRole('button', { name: 'Add 2 trackers' }))
    expect(queue.editTrackers).toHaveBeenCalledWith({
      id: 't',
      add: ['udp://c.example/announce', 'https://d.example/announce'],
    })
    await vi.waitFor(() => expect(screen.queryByRole('textbox')).toBeNull())
  })

  it('keeps the form open when the server refuses, and cancels with Escape', async () => {
    const queue = controls(false)
    renderWithI18n(<TrackersSection taskId="t" trackers={TRACKERS} queue={queue} />)
    await userEvent.click(screen.getByRole('button', { name: 'Add' }))
    await userEvent.type(screen.getByRole('textbox'), 'udp://c.example/announce')
    await userEvent.click(screen.getByRole('button', { name: 'Add 1 tracker' }))
    expect(screen.getByRole('textbox')).toBeInTheDocument()
    await userEvent.click(screen.getByRole('textbox'))
    await userEvent.keyboard('{Escape}')
    expect(screen.queryByRole('textbox')).toBeNull()
  })

  it('edits and removes a tracker', async () => {
    const queue = controls()
    renderWithI18n(<TrackersSection taskId="t" trackers={TRACKERS} queue={queue} />)
    await userEvent.click(screen.getByRole('button', { name: 'Remove tracker b.example' }))
    expect(queue.editTrackers).toHaveBeenCalledWith({ id: 't', remove: ['udp://b.example:80/announce'] })

    await userEvent.click(screen.getByRole('button', { name: 'Edit tracker a.example' }))
    const input = screen.getByRole('textbox', { name: 'Tracker URL' })
    expect(screen.getByRole('button', { name: en.common.save })).toBeDisabled()
    await userEvent.clear(input)
    await userEvent.type(input, 'nope')
    expect(screen.getByText('Not a tracker announce URL: nope')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: en.common.save })).toBeDisabled()
    await userEvent.clear(input)
    await userEvent.type(input, 'udp://a2.example:80/announce')
    await userEvent.click(screen.getByRole('button', { name: en.common.save }))
    expect(queue.editTrackers).toHaveBeenLastCalledWith({
      id: 't',
      edit: { old: 'udp://a.example:80/announce', new: 'udp://a2.example:80/announce' },
    })
  })

  it('cancels an edit', async () => {
    renderWithI18n(<TrackersSection taskId="t" trackers={TRACKERS} queue={controls()} />)
    await userEvent.click(screen.getByRole('button', { name: 'Edit tracker a.example' }))
    await userEvent.click(screen.getByRole('button', { name: en.common.cancel }))
    expect(screen.queryByRole('textbox')).toBeNull()
  })
})
