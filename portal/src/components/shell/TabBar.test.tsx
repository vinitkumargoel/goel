import { screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { createRef } from 'react'
import { describe, expect, it, vi } from 'vitest'
import { i18n, renderWithI18n } from '../../test/renderWithI18n'
import { TabBar } from './TabBar'

function setup(canWrite = true, drawerOpen = false) {
  const props = { onView: vi.fn(), onAdd: vi.fn(), onDrawer: vi.fn(), drawerButtonRef: createRef<HTMLButtonElement>() }
  renderWithI18n(<TabBar view="history" canWrite={canWrite} drawerOpen={drawerOpen} {...props} />)
  return props
}

describe('TabBar', () => {
  it('marks the current section and switches sections', async () => {
    const props = setup()
    expect(screen.getByRole('navigation', { name: i18n.t('shell.tabs.label') })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: i18n.t('common.history') })).toHaveAttribute('aria-current', 'page')
    await userEvent.click(screen.getByRole('button', { name: i18n.t('shell.tabs.board') }))
    await userEvent.click(screen.getByRole('button', { name: i18n.t('common.settings') }))
    expect(props.onView.mock.calls).toEqual([['library'], ['settings']])
  })

  it('puts Add under the thumb, except for a read-only session', async () => {
    const props = setup()
    await userEvent.click(screen.getByRole('button', { name: i18n.t('topbar.addDownload') }))
    expect(props.onAdd).toHaveBeenCalled()
  })

  it('has no Add for a read-only session', () => {
    setup(false)
    expect(screen.queryByRole('button', { name: i18n.t('topbar.addDownload') })).toBeNull()
  })

  it('opens the filters drawer and reports it expanded', async () => {
    const props = setup(true, true)
    const filters = screen.getByRole('button', { name: i18n.t('shell.tabs.filters') })
    expect(filters).toHaveAttribute('aria-expanded', 'true')
    expect(props.drawerButtonRef.current).toBe(filters)
    await userEvent.click(filters)
    expect(props.onDrawer).toHaveBeenCalled()
  })
})
