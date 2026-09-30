import { act, fireEvent, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it, vi } from 'vitest'
import en from '../locales/en.json'
import type { Toast } from '../hooks/useToasts'
import { renderWithI18n } from '../test/renderWithI18n'
import { Toasts } from './Toasts'

const TOASTS: Toast[] = [
  { id: 1, message: 'Copied', tone: 'copy', leaving: false },
  { id: 2, message: 'Could not reach the server', tone: 'warn', leaving: false },
  { id: 3, message: 'Removed', tone: 'trash', leaving: true },
]

function renderToasts() {
  const handlers = { onDismiss: vi.fn(), onPause: vi.fn(), onResume: vi.fn() }
  const result = renderWithI18n(<Toasts toasts={TOASTS} {...handlers} />)
  return { ...result, handlers }
}

describe('Toasts', () => {
  it('announces warnings in an alert region and the rest politely', () => {
    renderToasts()
    const alert = screen.getByRole('alert')
    expect(within(alert).getByText('Could not reach the server')).toBeInTheDocument()
    expect(within(alert).queryByText('Copied')).toBeNull()

    const status = screen.getByRole('status')
    expect(status).toHaveAttribute('aria-live', 'polite')
    expect(within(status).getByText('Copied')).toBeInTheDocument()
  })

  it('applies the exit class to a leaving toast', () => {
    renderToasts()
    expect(screen.getByText('Removed').closest('.toast')).toHaveClass('out')
    expect(screen.getByText('Copied').closest('.toast')).not.toHaveClass('out')
  })

  it('has a dismiss button per toast', async () => {
    const { handlers } = renderToasts()
    const buttons = screen.getAllByRole('button', { name: en.toast.dismiss })
    expect(buttons).toHaveLength(3)
    await userEvent.click(within(screen.getByRole('alert')).getByRole('button'))
    expect(handlers.onDismiss).toHaveBeenCalledWith(2)
  })

  it('pauses on hover and resumes on leave', () => {
    const { handlers } = renderToasts()
    const warn = screen.getByText('Could not reach the server').closest('.toast')!
    fireEvent.mouseEnter(warn)
    expect(handlers.onPause).toHaveBeenLastCalledWith(2)
    fireEvent.mouseLeave(warn)
    expect(handlers.onResume).toHaveBeenLastCalledWith(2)
  })

  it('pauses while its dismiss button has focus', () => {
    const { handlers } = renderToasts()
    handlers.onPause.mockClear()
    act(() => within(screen.getByRole('alert')).getByRole('button').focus())
    expect(handlers.onPause).toHaveBeenCalledWith(2)
  })
})
