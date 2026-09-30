import { useCallback, useEffect, useRef, useState } from 'react'
import { useMediaQuery } from './useMediaQuery'

export const PHONE_QUERY = '(max-width: 680px)'

/**
 * The topbar search: the inline field on wide windows, the overlay bar ≤680px. `focusSearch` (the
 * "/" shortcut) picks whichever is on screen.
 */
export function useSearchFocus() {
  const searchRef = useRef<HTMLInputElement>(null)
  const [mobileSearch, setMobileSearch] = useState(false)
  const phone = useMediaQuery(PHONE_QUERY)

  // The phone search bar has no place on a wide window.
  useEffect(() => {
    if (!phone) setMobileSearch(false)
  }, [phone])

  const focusSearch = useCallback(() => {
    if (window.matchMedia?.(PHONE_QUERY).matches) {
      setMobileSearch(true)
      return
    }
    searchRef.current?.focus()
    searchRef.current?.select()
  }, [])

  return { searchRef, mobileSearch, setMobileSearch, focusSearch }
}
