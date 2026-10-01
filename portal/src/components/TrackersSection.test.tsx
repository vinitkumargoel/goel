import { screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it, vi } from 'vitest'
import type { QueueControls } from '../hooks/useQueueControls'
import type { TrackerRow } from '../lib/types'
import { renderWithI18n } from '../test/renderWithI18n'
import { TrackersSection } from './TrackersSection'

const TRACKERS: TrackerRow[] = [
  { url: 'udp://a.example:80/announce', host: 'a.example', tier: 0, status: 'Working', state: 'working', seeds: 5, leeches: 2, message: '' },
  { url: 'udp://b.example:80/announce', host: 'b.example', tier: 1, status: 'Timed out', state: 'error', seeds: null, leeches: null, message: 'Timed out' },
]

function controls() {
  return { editTrackers: vi.fn(() => Promise.resolve(true)) } as unknown as QueueControls & {
    editTrackers: ReturnType<typeof vi.fn>
  }
}

describe('TrackersSection', () => {
  it('shows an erroring tracker in red with its message, and no controls when read-only', () => {
    renderWithI18n(<TrackersSection taskId="t" trackers={TRACKERS} />)
    expect(screen.getByText('Error')).toBeInTheDocument()
    expect(screen.getByText('Timed out')).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /Add/ })).toBeNull()
    expect(screen.queryByRole('button', { name: /Remove tracker/ })).toBeNull()
  })

  it('adds pasted trackers in one request and refuses a bad URL', async () => {
    const queue = controls()
    renderWithI18n(<TrackersSection taskId="t" trackers={TRACKERS} queue={queue} />)
    await userEvent.click(screen.getByRole('button', { name: 'Add' }))
    const box = screen.getByRole('textbox', { name: 'Tracker URLs to add' })
    await userEvent.type(box, 'udp://c.example/announce junk')
    expect(screen.getByText('Not a tracker announce URL: junk')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Add 1 tracker' })).toBeDisabled()
    await userEvent.clear(box)
    await userEvent.type(box, 'udp://c.example/announce, https://d.example/announce')
    await userEvent.click(screen.getByRole('button', { name: 'Add 2 trackers' }))
    expect(queue.editTrackers).toHaveBeenCalledWith({
      id: 't',
      add: ['udp://c.example/announce', 'https://d.example/announce'],
    })
  })

  it('edits and removes a tracker', async () => {
    const queue = controls()
    renderWithI18n(<TrackersSection taskId="t" trackers={TRACKERS} queue={queue} />)
    await userEvent.click(screen.getByRole('button', { name: 'Remove tracker b.example' }))
    expect(queue.editTrackers).toHaveBeenCalledWith({ id: 't', remove: ['udp://b.example:80/announce'] })

    await userEvent.click(screen.getByRole('button', { name: 'Edit tracker a.example' }))
    const input = screen.getByRole('textbox', { name: 'Tracker URL' })
    await userEvent.clear(input)
    await userEvent.type(input, 'udp://a2.example:80/announce')
    await userEvent.click(screen.getByRole('button', { name: 'Save' }))
    expect(queue.editTrackers).toHaveBeenLastCalledWith({
      id: 't',
      edit: { old: 'udp://a.example:80/announce', new: 'udp://a2.example:80/announce' },
    })
  })
})
