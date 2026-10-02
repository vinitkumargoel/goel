import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { useRef, useState } from 'react'
import { describe, expect, it, vi } from 'vitest'
import { useDialogFocus } from './useDialogFocus'

function Dialog({ onEscape }: { onEscape: () => void }) {
  const ref = useRef<HTMLDivElement>(null)
  const [editing, setEditing] = useState(true)
  useDialogFocus(ref, { onEscape })
  return (
    <div ref={ref} role="dialog">
      <button>First</button>
      {editing && (
        <form data-local-escape>
          <input
            aria-label="Tracker"
            onKeyDown={(e) => {
              if (e.key === 'Escape') {
                e.stopPropagation()
                setEditing(false)
              }
            }}
          />
        </form>
      )}
      <button>Last</button>
    </div>
  )
}

describe('useDialogFocus', () => {
  it('wraps Tab inside the dialog and hands focus back on unmount', async () => {
    const opener = document.createElement('button')
    document.body.appendChild(opener)
    opener.focus()
    const { unmount } = render(<Dialog onEscape={vi.fn()} />)
    screen.getByRole('button', { name: 'Last' }).focus()
    await userEvent.tab()
    expect(screen.getByRole('button', { name: 'First' })).toHaveFocus()
    await userEvent.tab({ shift: true })
    expect(screen.getByRole('button', { name: 'Last' })).toHaveFocus()
    unmount()
    expect(opener).toHaveFocus()
    opener.remove()
  })

  it('lets an inline editor take the first Escape; the next closes the dialog', async () => {
    const onEscape = vi.fn()
    render(<Dialog onEscape={onEscape} />)
    screen.getByRole('textbox', { name: 'Tracker' }).focus()
    await userEvent.keyboard('{Escape}')
    expect(onEscape).not.toHaveBeenCalled()
    expect(screen.queryByRole('textbox')).toBeNull()
    await userEvent.keyboard('{Escape}')
    expect(onEscape).toHaveBeenCalledTimes(1)
  })

  it('moves focus to the first control on mount', () => {
    render(<Dialog onEscape={vi.fn()} />)
    expect(screen.getByRole('button', { name: 'First' })).toHaveFocus()
  })

  it('focuses the sheet itself when it holds no control', () => {
    function Empty() {
      const ref = useRef<HTMLDivElement>(null)
      useDialogFocus(ref)
      return (
        <div ref={ref} role="dialog">
          <p>Just text</p>
        </div>
      )
    }
    render(<Empty />)
    expect(screen.getByRole('dialog')).toHaveFocus()
  })

  it('leaves focus alone when the content already took it', () => {
    function Auto() {
      const ref = useRef<HTMLDivElement>(null)
      useDialogFocus(ref)
      return (
        <div ref={ref} role="dialog">
          <button>First</button>
          <input aria-label="Url" autoFocus />
        </div>
      )
    }
    render(<Auto />)
    expect(screen.getByRole('textbox', { name: 'Url' })).toHaveFocus()
  })
})
