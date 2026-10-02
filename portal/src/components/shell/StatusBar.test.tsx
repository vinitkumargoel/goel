import { screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it, vi } from 'vitest'
import en from '../../locales/en.json'
import { i18n, renderWithI18n } from '../../test/renderWithI18n'
import { StatusBar } from './StatusBar'

const queue = { active: 4, queued: 0, paused: 1, seeding: 0, failed: 2 }
const idle = { remainingBytes: 0, rate: 0, seconds: null, unknown: 0 }
const base = { queue, downSpeed: 0, upSpeed: 0, estimate: idle, readOnly: false }

describe('StatusBar', () => {
  it('summarises only the non-empty queue states, always keeping active', () => {
    renderWithI18n(<StatusBar {...base} queue={{ ...queue, active: 0 }} />)
    expect(screen.getByText('0 active')).toBeInTheDocument()
    expect(screen.getByText('1 paused')).toBeInTheDocument()
    expect(screen.getByText('2 failed')).toBeInTheDocument()
    expect(screen.queryByText(/queued|seeding/)).toBeNull()
  })

  it('makes each count a shortcut to its filter, failures in red', async () => {
    const onFilter = vi.fn()
    renderWithI18n(<StatusBar {...base} onFilter={onFilter} />)
    const failed = screen.getByRole('button', { name: '2 failed' })
    expect(failed).toHaveClass('bad')
    await userEvent.click(failed)
    await userEvent.click(screen.getByRole('button', { name: '4 active' }))
    expect(onFilter.mock.calls).toEqual([['failed'], ['active']])
  })

  it('says what is left and when it should be done, noting downloads without a size', () => {
    renderWithI18n(
      <StatusBar {...base} estimate={{ remainingBytes: 3 * 1024 ** 3, rate: 1, seconds: 60, unknown: 2 }} />,
    )
    expect(screen.getByText(/3\.0 GB left · done ≈ .+ · 2 without a size/)).toBeInTheDocument()
  })

  it('leaves the estimate out when nothing is pending', () => {
    renderWithI18n(<StatusBar {...base} />)
    expect(screen.queryByText(/left/)).toBeNull()
  })

  it('shows the Read-only pill only for a read-only session', () => {
    const { unmount } = renderWithI18n(<StatusBar {...base} />)
    expect(screen.queryByText(en.statusbar.readOnly)).toBeNull()
    unmount()
    renderWithI18n(<StatusBar {...base} readOnly />)
    expect(screen.getByText(en.statusbar.readOnly)).toBeInTheDocument()
  })

  it('offers Pause all and Resume all, except to a read-only session', async () => {
    const onPauseAll = vi.fn()
    const onResumeAll = vi.fn()
    const { unmount } = renderWithI18n(<StatusBar {...base} onPauseAll={onPauseAll} onResumeAll={onResumeAll} />)
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
    const { rerender } = renderWithI18n(<StatusBar {...base} bandwidth={bandwidth} onBandwidthMenu={onBandwidthMenu} />)
    const pill = screen.getByRole('button', { name: /Profile: Medium/ })
    expect(pill).toHaveAttribute('aria-haspopup', 'menu')
    await userEvent.click(pill)
    expect(onBandwidthMenu).toHaveBeenCalled()
    rerender(<StatusBar {...base} bandwidth={{ ...bandwidth, enabled: false }} onBandwidthMenu={onBandwidthMenu} />)
    expect(screen.getByRole('button', { name: new RegExp(en.statusbar.unlimited) })).toBeInTheDocument()
  })

  it('shows the pill as plain text when read-only, and hides it without bandwidth', () => {
    const bandwidth = { enabled: true, selected: 'Low', profiles: [] }
    const { unmount } = renderWithI18n(<StatusBar {...base} readOnly bandwidth={bandwidth} onBandwidthMenu={vi.fn()} />)
    expect(screen.getByText('Profile: Low').closest('button')).toBeNull()
    unmount()
    renderWithI18n(<StatusBar {...base} bandwidth={null} onBandwidthMenu={vi.fn()} />)
    expect(screen.queryByText(/Profile:/)).toBeNull()
  })

  it('opens the speed graph in a popover and closes it with Escape', async () => {
    renderWithI18n(<StatusBar {...base} />)
    const trigger = screen.getByRole('button', { name: i18n.t('shell.status.chart') })
    await userEvent.click(trigger)
    expect(trigger).toHaveAttribute('aria-expanded', 'true')
    expect(screen.getByRole('dialog', { name: i18n.t('shell.status.chart') })).toHaveTextContent(
      i18n.t('shell.status.idle'),
    )
    await userEvent.keyboard('{Escape}')
    expect(screen.queryByRole('dialog')).toBeNull()
    expect(trigger).toHaveFocus()
  })
})
