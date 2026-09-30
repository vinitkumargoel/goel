import { screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it, vi } from 'vitest'
import en from '../locales/en.json'
import { renderWithI18n } from '../test/renderWithI18n'
import { StatusBar } from './StatusBar'

const base = { live: true, loaded: true, active: 4, downSpeed: 0, upSpeed: 0, readOnly: false }

describe('StatusBar', () => {
  it('shows Live and the active count', () => {
    renderWithI18n(<StatusBar {...base} />)
    expect(screen.getByRole('status')).toHaveTextContent(en.statusbar.live)
    expect(screen.getByText('4 active')).toBeInTheDocument()
  })

  it('warns that data may be stale once the stream drops', () => {
    renderWithI18n(<StatusBar {...base} live={false} />)
    expect(screen.getByRole('status')).toHaveTextContent(en.statusbar.reconnecting)
  })

  it('says Connecting before the first snapshot rather than Reconnecting', () => {
    renderWithI18n(<StatusBar {...base} live={false} loaded={false} />)
    expect(screen.getByRole('status')).toHaveTextContent(en.statusbar.connecting)
  })

  it('shows the Read-only chip only for a read-only session', () => {
    const { unmount } = renderWithI18n(<StatusBar {...base} />)
    expect(screen.queryByText(en.statusbar.readOnly)).toBeNull()
    unmount()
    renderWithI18n(<StatusBar {...base} readOnly />)
    expect(screen.getByText(en.statusbar.readOnly)).toBeInTheDocument()
  })

  it('offers Pause all and Resume all, except to a read-only session', async () => {
    const onPauseAll = vi.fn()
    const onResumeAll = vi.fn()
    const { unmount } = renderWithI18n(
      <StatusBar {...base} onPauseAll={onPauseAll} onResumeAll={onResumeAll} />,
    )
    expect(screen.getByRole('group', { name: en.statusbar.allControls })).toBeInTheDocument()
    await userEvent.click(screen.getByRole('button', { name: en.statusbar.pauseAll }))
    await userEvent.click(screen.getByRole('button', { name: en.statusbar.resumeAll }))
    expect(onPauseAll).toHaveBeenCalledTimes(1)
    expect(onResumeAll).toHaveBeenCalledTimes(1)
    unmount()
    renderWithI18n(<StatusBar {...base} readOnly onPauseAll={onPauseAll} onResumeAll={onResumeAll} />)
    expect(screen.queryByRole('button', { name: en.statusbar.pauseAll })).toBeNull()
  })

  it('shows the active profile pill and opens its menu', async () => {
    const onBandwidthMenu = vi.fn()
    const bandwidth = { enabled: true, selected: 'Medium', profiles: [] }
    const { rerender } = renderWithI18n(
      <StatusBar {...base} bandwidth={bandwidth} onBandwidthMenu={onBandwidthMenu} />,
    )
    const pill = screen.getByRole('button', { name: /Profile: Medium/ })
    expect(pill).toHaveAttribute('aria-haspopup', 'menu')
    await userEvent.click(pill)
    expect(onBandwidthMenu).toHaveBeenCalled()
    rerender(
      <StatusBar {...base} bandwidth={{ ...bandwidth, enabled: false }} onBandwidthMenu={onBandwidthMenu} />,
    )
    expect(screen.getByRole('button', { name: new RegExp(en.statusbar.unlimited) })).toBeInTheDocument()
  })

  it('shows the pill as plain text when read-only, and hides it without bandwidth', () => {
    const bandwidth = { enabled: true, selected: 'Low', profiles: [] }
    const { unmount } = renderWithI18n(
      <StatusBar {...base} readOnly bandwidth={bandwidth} onBandwidthMenu={vi.fn()} />,
    )
    expect(screen.getByText('Profile: Low').closest('button')).toBeNull()
    unmount()
    renderWithI18n(<StatusBar {...base} bandwidth={null} onBandwidthMenu={vi.fn()} />)
    expect(screen.queryByText(/Profile:/)).toBeNull()
  })
})
