import { useEffect, useState } from 'react'

/** Whether `query` matches now; follows changes. False where `matchMedia` is missing (jsdom). */
export function useMediaQuery(query: string): boolean {
  const [matches, setMatches] = useState(
    () => typeof window.matchMedia === 'function' && window.matchMedia(query).matches,
  )
  useEffect(() => {
    if (typeof window.matchMedia !== 'function') return
    const list = window.matchMedia(query)
    setMatches(list.matches)
    const onChange = (e: MediaQueryListEvent) => setMatches(e.matches)
    list.addEventListener('change', onChange)
    return () => list.removeEventListener('change', onChange)
  }, [query])
  return matches
}
