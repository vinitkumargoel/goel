import { screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { speedStore } from '../../lib/speedStore'
import type { TaskRow } from '../../lib/types'
import { i18n, renderWithI18n } from '../../test/renderWithI18n'
import { connectionOf, Header, type Connection } from './Header'

afterEach(() => speedStore.reset())

function renderHeader(connection: Connection = 'live', over: Partial<Parameters<typeof Header>[0]> = {}) {
  const props = {
    connection,
    downSpeed: 2 * 1024 * 1024,
    upSpeed: 0,
    showPanelToggle: true,
    panelOpen: false,
    onTogglePanel: vi.fn(),
    onUserMenu: vi.fn(),
    userMenuOpen: false,
    ...over,
  }
  return { ...renderWithI18n(<Header {...props} />), props }
}

describe('connectionOf', () => {
  it('says Connecting before the first snapshot, Reconnecting after a drop', () => {
    expect(connectionOf(true, true)).toBe('live')
    expect(connectionOf(false, true)).toBe('reconnecting')
    expect(connectionOf(false, false)).toBe('connecting')
  })
})

describe('Header', () => {
  it('shows the connection state as a status', () => {
    const { unmount } = renderHeader('live')
    expect(screen.getByRole('status')).toHaveTextContent(i18n.t('shell.conn.live'))
    expect(screen.getByRole('status')).toHaveClass('good')
    unmount()
    renderHeader('reconnecting')
    expect(screen.getByRole('status')).toHaveTextContent(i18n.t('shell.conn.reconnecting'))
    expect(screen.getByRole('status')).toHaveClass('warn')
  })

  it('names the live rates and draws the trend once there are two samples', () => {
    const { unmount } = renderHeader()
    expect(screen.getByRole('group', { name: /Download 2\.0 MB\/s/ })).toBeInTheDocument()
    expect(screen.queryByRole('img', { name: i18n.t('topbar.speedTrend') })).toBeNull()
    unmount()
    speedStore.record([{ id: 'a', downSpeed: 1, upSpeed: 0 } as TaskRow])
    speedStore.record([{ id: 'a', downSpeed: 2, upSpeed: 0 } as TaskRow])
    renderHeader()
    expect(screen.getByRole('img', { name: i18n.t('topbar.speedTrend') })).toBeInTheDocument()
  })

  it('toggles the detail sheet, reflecting its state', async () => {
    const { props, rerender } = renderHeader()
    const toggle = screen.getByRole('button', { name: i18n.t('topbar.detailPanel') })
    expect(toggle).toHaveAttribute('aria-pressed', 'false')
    await userEvent.click(toggle)
    expect(props.onTogglePanel).toHaveBeenCalled()
    rerender(<Header {...props} panelOpen />)
    expect(toggle).toHaveAttribute('aria-pressed', 'true')
  })

  it('hides the sheet toggle outside the library', () => {
    renderHeader('live', { showPanelToggle: false })
    expect(screen.queryByRole('button', { name: i18n.t('topbar.detailPanel') })).toBeNull()
  })

  it('opens the account menu anchored to the chip', async () => {
    const { props } = renderHeader('live', { userMenuOpen: true })
    const chip = screen.getByRole('button', { name: /account/i })
    expect(chip).toHaveAttribute('aria-haspopup', 'menu')
    expect(chip).toHaveAttribute('aria-expanded', 'true')
    await userEvent.click(chip)
    expect(props.onUserMenu).toHaveBeenCalledWith(expect.objectContaining({ x: expect.any(Number) }))
  })
})
