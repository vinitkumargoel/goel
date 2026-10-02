import { fireEvent, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it, vi } from 'vitest'
import en from '../../locales/en.json'
import sheet from '../../locales/en.json'
import type { TaskRow } from '../../lib/types'
import { makeTask } from '../../test/makeTask'
import { renderWithI18n } from '../../test/renderWithI18n'
import { canPlayInBrowser, PlayerDialog } from './PlayerDialog'

const S = sheet.sheet.player

function task(name: string, extra: Partial<TaskRow> = {}): TaskRow {
  return makeTask('x', { name, statusToken: 'downloading', totalBytes: 1000, doneBytes: 250, ...extra })
}

describe('PlayerDialog', () => {
  it('knows which containers a browser will not play', () => {
    expect(canPlayInBrowser('a.mp4')).toBe(true)
    expect(canPlayInBrowser('a.MKV')).toBe(false)
    expect(canPlayInBrowser('Show/a.ts')).toBe(false)
  })

  it('is a modal dialog named by the file, closed by Done or Escape', async () => {
    const onClose = vi.fn()
    renderWithI18n(<PlayerDialog task={task('film.mp4')} onClose={onClose} onCopy={vi.fn()} />)
    const dialog = screen.getByRole('dialog', { name: 'film.mp4' })
    expect(dialog).toHaveAttribute('aria-modal', 'true')
    await userEvent.click(screen.getByRole('button', { name: S.done }))
    await userEvent.keyboard('{Escape}')
    expect(onClose).toHaveBeenCalledTimes(2)
  })

  it('plays an mp4 and shows how much has arrived', () => {
    renderWithI18n(<PlayerDialog task={task('film.mp4')} onClose={vi.fn()} onCopy={vi.fn()} />)
    expect(document.querySelector('video')).toHaveAttribute('src', '/stream?id=x')
    expect(screen.getByRole('progressbar', { name: en.player.buffered })).toHaveAttribute('aria-valuenow', '25')
    expect(screen.getByText(/^250 B of 1000 B downloaded/)).toBeInTheDocument()
  })

  it('shows no arrival bar once the file is complete', () => {
    renderWithI18n(
      <PlayerDialog task={task('film.mp4', { statusToken: 'completed', doneBytes: 1000 })} onClose={vi.fn()} onCopy={vi.fn()} />,
    )
    expect(screen.queryByRole('progressbar')).toBeNull()
  })

  it('drives the video from its glass controls', async () => {
    renderWithI18n(<PlayerDialog task={task('film.mp4')} onClose={vi.fn()} onCopy={vi.fn()} />)
    const video = document.querySelector('video')!
    const play = vi.spyOn(video, 'play').mockResolvedValue()
    const pause = vi.spyOn(video, 'pause').mockImplementation(() => {})
    await userEvent.click(screen.getByRole('button', { name: S.play }))
    expect(play).toHaveBeenCalled()
    fireEvent.play(video)
    Object.defineProperty(video, 'paused', { value: false, configurable: true })
    await userEvent.click(screen.getByRole('button', { name: S.pause }))
    expect(pause).toHaveBeenCalled()

    await userEvent.click(screen.getByRole('button', { name: S.mute }))
    expect(video.muted).toBe(true)
    fireEvent.volumeChange(video)
    expect(screen.getByRole('button', { name: S.unmute })).toHaveAttribute('aria-pressed', 'true')
  })

  it('seeks once the duration is known', () => {
    renderWithI18n(<PlayerDialog task={task('film.mp4')} onClose={vi.fn()} onCopy={vi.fn()} />)
    const video = document.querySelector('video')!
    const seek = screen.getByRole('slider', { name: S.seek })
    expect(seek).toBeDisabled()
    Object.defineProperty(video, 'duration', { value: 120, configurable: true })
    fireEvent.durationChange(video)
    expect(seek).toBeEnabled()
    fireEvent.change(seek, { target: { value: '30' } })
    expect(video.currentTime).toBe(30)
    fireEvent.timeUpdate(video)
    expect(screen.getByText('2:00')).toBeInTheDocument()
  })

  it('offers Save, Copy link and a new tab for an mkv instead of a doomed player', () => {
    const onCopy = vi.fn()
    renderWithI18n(
      <PlayerDialog task={task('film.mkv', { statusToken: 'completed', doneBytes: 1000 })} onClose={vi.fn()} onCopy={onCopy} />,
    )
    expect(document.querySelector('video')).toBeNull()
    expect(screen.getByText("Can't play .mkv here")).toBeInTheDocument()
    expect(screen.getByRole('link', { name: en.menu.saveToDevice })).toHaveAttribute('href', '/stream?id=x&dl=1')
    const tab = screen.getByRole('link', { name: S.openTab })
    expect(tab).toHaveAttribute('target', '_blank')
    expect(tab).toHaveAttribute('rel', 'noopener noreferrer')
    fireEvent.click(screen.getByRole('button', { name: en.player.copyLink }))
    expect(onCopy).toHaveBeenCalledWith(expect.stringContaining('/stream?id=x'))
  })

  it('offers no Save while an unplayable file is still arriving, and says how much is there', () => {
    renderWithI18n(<PlayerDialog task={task('film.avi')} onClose={vi.fn()} onCopy={vi.fn()} />)
    expect(screen.queryByRole('link', { name: en.menu.saveToDevice })).toBeNull()
    expect(screen.getByRole('progressbar', { name: en.player.buffered })).toBeInTheDocument()
  })

  it('names "this file" when there is no extension', () => {
    renderWithI18n(<PlayerDialog task={task('README', { statusToken: 'completed' })} onClose={vi.fn()} onCopy={vi.fn()} />)
    fireEvent.error(document.querySelector('video')!)
    expect(screen.getByText("Can't play this file here")).toBeInTheDocument()
  })

  it('falls back when the browser fails to play', () => {
    renderWithI18n(<PlayerDialog task={task('film.mp4')} onClose={vi.fn()} onCopy={vi.fn()} />)
    fireEvent.error(document.querySelector('video')!)
    expect(screen.getByText("Can't play .mp4 here")).toBeInTheDocument()
  })
})
