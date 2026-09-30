import { screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { useState } from 'react'
import { describe, expect, it, vi } from 'vitest'
import en from '../locales/en.json'
import { renderWithI18n } from '../test/renderWithI18n'
import { Topbar } from './Topbar'

function Harness({ onSearch = vi.fn() }: { onSearch?: (v: string) => void }) {
  const [search, setSearch] = useState('')
  const [open, setOpen] = useState(false)
  return (
    <Topbar
      search={search}
      onSearch={(v) => {
        setSearch(v)
        onSearch(v)
      }}
      mobileSearchOpen={open}
      onMobileSearch={setOpen}
      downSpeed={0}
      upSpeed={0}
      speedSamples={[
        { down: 1, up: 0 },
        { down: 2, up: 0 },
      ]}
      showPanelToggle
      panelOpen={false}
      onTogglePanel={vi.fn()}
      onAdd={vi.fn()}
      onToggleSidebar={vi.fn()}
      onUserMenu={vi.fn()}
      userMenuOpen={false}
      sidebarOpen={false}
      canWrite
    />
  )
}

describe('Topbar', () => {
  it('advertises its shortcuts', () => {
    renderWithI18n(<Harness />)
    expect(screen.getByRole('searchbox', { name: en.topbar.searchDownloads })).toHaveAttribute(
      'aria-keyshortcuts',
      '/',
    )
    const add = screen.getByRole('button', { name: en.common.add })
    expect(add).toHaveAttribute('aria-keyshortcuts', 'N')
    expect(add).toHaveAttribute('title', 'Add download (N)')
    expect(screen.getByRole('img', { name: en.topbar.speedTrend })).toBeInTheDocument()
  })

  it('opens the phone search over the bar, focused, and Escape clears and restores focus', async () => {
    const onSearch = vi.fn()
    renderWithI18n(<Harness onSearch={onSearch} />)
    const toggle = screen.getByRole('button', { name: en.topbar.openSearch })
    await userEvent.click(toggle)
    expect(toggle).toHaveAttribute('aria-expanded', 'true')
    const bar = screen.getByRole('search')
    const input = bar.querySelector('input')!
    expect(input).toHaveFocus()
    await userEvent.type(input, 'iso')
    expect(onSearch).toHaveBeenLastCalledWith('iso')
    await userEvent.keyboard('{Escape}')
    expect(screen.queryByRole('search')).toBeNull()
    expect(onSearch).toHaveBeenLastCalledWith('')
    expect(toggle).toHaveFocus()
  })

  it('closes the phone search with Cancel', async () => {
    renderWithI18n(<Harness />)
    await userEvent.click(screen.getByRole('button', { name: en.topbar.openSearch }))
    await userEvent.click(screen.getByRole('button', { name: en.topbar.cancelSearch }))
    expect(screen.queryByRole('search')).toBeNull()
  })
})
