import { useCallback, useRef } from 'react'

/**
 * The omnibox's input. It is on screen at every width — on a phone it is the search — so "/" and
 * ⌘F only have to focus it and select what is there.
 */
export function useSearchFocus() {
  const searchRef = useRef<HTMLInputElement>(null)

  const focusSearch = useCallback(() => {
    const input = searchRef.current
    if (!input) return
    input.focus()
    input.select()
  }, [])

  return { searchRef, focusSearch }
}
