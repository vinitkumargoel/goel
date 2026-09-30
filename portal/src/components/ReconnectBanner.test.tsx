import { screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it, vi } from 'vitest'
import en from '../locales/en.json'
import { renderWithI18n } from '../test/renderWithI18n'
import { isStale, ReconnectBanner, STALE_AFTER_MS } from './ReconnectBanner'

describe('isStale', () => {
  it('needs the stream down and the data older than the grace period', () => {
    expect(isStale(false, 1000, 1000 + STALE_AFTER_MS + 1)).toBe(true)
    expect(isStale(false, 1000, 1000 + STALE_AFTER_MS)).toBe(false)
    expect(isStale(true, 1000, 1000 + 60_000)).toBe(false)
    expect(isStale(false, null, 60_000)).toBe(false)
  })
})

describe('ReconnectBanner', () => {
  it('keeps an empty polite live region while connected', () => {
    renderWithI18n(<ReconnectBanner stale={false} lastUpdate={0} now={0} onRetry={vi.fn()} />)
    const region = screen.getByRole('status')
    expect(region).toHaveAttribute('aria-live', 'polite')
    expect(region).toBeEmptyDOMElement()
    expect(screen.queryByRole('button')).toBeNull()
  })

  it('shows the data age, announces once, and retries on demand', async () => {
    const onRetry = vi.fn()
    renderWithI18n(<ReconnectBanner stale lastUpdate={1_000} now={15_000} onRetry={onRetry} />)
    expect(screen.getByText(/Connection lost — showing data from 0:14 ago/)).toBeInTheDocument()
    expect(screen.getByRole('status')).toHaveTextContent(en.reconnect.announce)
    await userEvent.click(screen.getByRole('button', { name: en.reconnect.retryNow }))
    expect(onRetry).toHaveBeenCalled()
  })
})
