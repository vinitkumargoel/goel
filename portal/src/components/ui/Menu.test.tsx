import { screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { useState } from 'react'
import { describe, expect, it, vi } from 'vitest'
import { renderWithI18n } from '../../test/renderWithI18n'
import { Menu, type MenuState } from './Menu'

function Harness({ onPick }: { onPick: (key: string) => void }) {
  const [menu, setMenu] = useState<MenuState | null>(null)
  return (
    <>
      <button
        aria-haspopup="menu"
        onClick={() =>
          setMenu({
            x: 10,
            y: 10,
            label: 'debian.iso',
            entries: [
              { key: 'a', label: 'Pause', action: () => onPick('a') },
              { separator: true },
              { heading: 'Copy' },
              { key: 'b', label: 'Copy source link', action: () => onPick('b') },
              { key: 'c', label: 'Remove', danger: true, action: () => onPick('c') },
            ],
          })
        }
      >
        More
      </button>
      <Menu menu={menu} onClose={() => setMenu(null)} />
    </>
  )
}

async function open() {
  const onPick = vi.fn()
  renderWithI18n(<Harness onPick={onPick} />)
  const opener = screen.getByRole('button', { name: 'More' })
  await userEvent.click(opener)
  return { onPick, opener }
}

describe('Menu', () => {
  it('closes, rather than reopens, when its own trigger is clicked again', async () => {
    const { opener } = await open()
    expect(screen.getByRole('menu')).toBeInTheDocument()
    await userEvent.click(opener)
    expect(screen.queryByRole('menu')).toBeNull()
    await userEvent.click(opener)
    expect(screen.getByRole('menu')).toBeInTheDocument()
  })

  it('is a labelled menu of menuitems, focuses the first, and draws danger and headings', async () => {
    await open()
    expect(screen.getByRole('menu', { name: 'debian.iso' })).toBeInTheDocument()
    const items = screen.getAllByRole('menuitem')
    expect(items).toHaveLength(3)
    expect(items[0]).toHaveFocus()
    expect(items[2]).toHaveClass('dang')
    expect(screen.getByText('Copy')).not.toHaveAttribute('role', 'menuitem')
  })

  it('moves with the arrow keys, wrapping, and jumps with Home/End', async () => {
    await open()
    const items = screen.getAllByRole('menuitem')
    await userEvent.keyboard('{ArrowDown}')
    expect(items[1]).toHaveFocus()
    await userEvent.keyboard('{End}')
    expect(items[2]).toHaveFocus()
    await userEvent.keyboard('{ArrowDown}')
    expect(items[0]).toHaveFocus()
    await userEvent.keyboard('{ArrowUp}')
    expect(items[2]).toHaveFocus()
    await userEvent.keyboard('{Home}')
    expect(items[0]).toHaveFocus()
  })

  it('closes on Escape and gives focus back to the opener', async () => {
    const { opener } = await open()
    await userEvent.keyboard('{Escape}')
    expect(screen.queryByRole('menu')).toBeNull()
    expect(opener).toHaveFocus()
  })

  it('runs the chosen item with Enter and closes', async () => {
    const { onPick } = await open()
    await userEvent.keyboard('{ArrowDown}{Enter}')
    expect(onPick).toHaveBeenCalledWith('b')
    expect(screen.queryByRole('menu')).toBeNull()
  })

  it('renders choices as checkable radio items, with detail, kbd hints and disabled entries', async () => {
    const pick = vi.fn()
    renderWithI18n(
      <Menu
        menu={{
          x: 0,
          y: 0,
          entries: [
            { key: 'a', label: 'Low', detail: '↓ 1 MB/s', checked: true, action: pick },
            { key: 'b', label: 'High', checked: false, disabled: true, action: pick },
            { key: 'c', label: 'Pause', shortcut: 'Space', action: pick },
          ],
        }}
        onClose={vi.fn()}
      />,
    )
    const radios = screen.getAllByRole('menuitemradio')
    expect(radios[0]).toHaveAttribute('aria-checked', 'true')
    expect(radios[0]).toHaveTextContent('↓ 1 MB/s')
    expect(radios[1]).toHaveAttribute('aria-disabled', 'true')
    await userEvent.click(radios[1]!)
    expect(pick).not.toHaveBeenCalled()
    expect(screen.getByRole('menuitem', { name: 'Pause' })).toHaveAttribute('aria-keyshortcuts', 'Space')
  })
})
