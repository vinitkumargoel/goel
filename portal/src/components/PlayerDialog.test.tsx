import { fireEvent, screen } from '@testing-library/react'
import { describe, expect, it, vi } from 'vitest'
import type { TaskRow } from '../lib/types'
import { renderWithI18n } from '../test/renderWithI18n'
import { canPlayInBrowser, PlayerDialog } from './PlayerDialog'

function task(name: string, extra: Partial<TaskRow> = {}): TaskRow {
  return { id: 'x', name, statusToken: 'downloading', totalBytes: 1000, doneBytes: 250, ...extra } as TaskRow
}

describe('PlayerDialog', () => {
  it('knows which containers a browser will not play', () => {
    expect(canPlayInBrowser('a.mp4')).toBe(true)
    expect(canPlayInBrowser('a.MKV')).toBe(false)
  })

  it('plays an mp4 and shows how much has arrived', () => {
    renderWithI18n(<PlayerDialog task={task('film.mp4')} onClose={vi.fn()} onCopy={vi.fn()} />)
    expect(document.querySelector('video')).toHaveAttribute('src', '/stream?id=x')
    expect(screen.getByRole('progressbar')).toHaveAttribute('aria-valuenow', '25')
  })

  it('offers Save and Copy link for an mkv instead of a doomed player', () => {
    const onCopy = vi.fn()
    renderWithI18n(
      <PlayerDialog task={task('film.mkv', { statusToken: 'completed', doneBytes: 1000 })} onClose={vi.fn()} onCopy={onCopy} />,
    )
    expect(document.querySelector('video')).toBeNull()
    expect(screen.getByText("Can't play .mkv here")).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Save to this device' })).toHaveAttribute('href', '/stream?id=x&dl=1')
    fireEvent.click(screen.getByRole('button', { name: 'Copy link' }))
    expect(onCopy).toHaveBeenCalledWith(expect.stringContaining('/stream?id=x'))
  })

  it('falls back when the browser fails to play', () => {
    renderWithI18n(<PlayerDialog task={task('film.mp4')} onClose={vi.fn()} onCopy={vi.fn()} />)
    fireEvent.error(document.querySelector('video')!)
    expect(screen.getByText("Can't play .mp4 here")).toBeInTheDocument()
  })
})
