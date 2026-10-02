import { screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, describe, expect, it, vi } from 'vitest'
import en from '../../locales/en.json'
import { i18n, renderWithI18n } from '../../test/renderWithI18n'
import { LanguageRow, NotifyRow } from './BrowserPrefsCard'

afterEach(async () => {
  vi.unstubAllGlobals()
  await i18n.changeLanguage('en')
  try {
    localStorage.clear()
  } catch {
    // No storage in this runner: nothing to reset.
  }
})

describe('LanguageRow', () => {
  it('offers Automatic and each language named in itself, and switches at once', async () => {
    renderWithI18n(<LanguageRow />)
    const select = screen.getByLabelText(en.browser.language)
    expect(select).toHaveValue('')
    expect(screen.getByRole('option', { name: /^Automatic/ })).toBeInTheDocument()
    expect(screen.getByRole('option', { name: 'Deutsch' })).toHaveAttribute('lang', 'de')
    await userEvent.selectOptions(select, 'de')
    expect(i18n.language).toBe('de')
    expect(select).toHaveValue('de')
  })
})

describe('NotifyRow', () => {
  it('is off and explains itself where the browser has no notifications', () => {
    vi.stubGlobal('Notification', undefined)
    // `'Notification' in window` is what counts; a stubbed undefined still counts as present.
    delete (window as { Notification?: unknown }).Notification
    renderWithI18n(<NotifyRow onToast={vi.fn()} />)
    const sw = screen.getByRole('switch', { name: en.browser.notify })
    expect(sw).toBeDisabled()
    expect(sw).toHaveAccessibleDescription(en.browser.notifyUnsupported)
  })

  it('asks for permission from the click and says when it is on', async () => {
    const requestPermission = vi.fn(async () => 'granted' as const)
    vi.stubGlobal('Notification', { permission: 'default', requestPermission })
    const onToast = vi.fn()
    renderWithI18n(<NotifyRow onToast={onToast} />)
    const sw = screen.getByRole('switch', { name: en.browser.notify })
    expect(sw).toHaveAccessibleDescription(en.browser.notifyHint)
    await userEvent.click(sw)
    expect(requestPermission).toHaveBeenCalled()
    expect(onToast).toHaveBeenCalledWith(en.browser.notifyOn)
  })

  it('stays off and says why when the site is blocked', () => {
    vi.stubGlobal('Notification', { permission: 'denied', requestPermission: vi.fn() })
    renderWithI18n(<NotifyRow onToast={vi.fn()} />)
    const sw = screen.getByRole('switch', { name: en.browser.notify })
    expect(sw).toBeDisabled()
    expect(sw).toHaveAccessibleDescription(en.browser.notifyDenied)
  })
})
