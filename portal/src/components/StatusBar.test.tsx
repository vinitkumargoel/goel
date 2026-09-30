import { screen } from '@testing-library/react'
import { describe, expect, it } from 'vitest'
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
})
