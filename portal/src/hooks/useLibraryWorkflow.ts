import { useCallback, useEffect, useRef, useState } from 'react'
import type { GroupBy } from '../lib/grouping'
import { loadLibraryPrefs, saveLibraryPref, type Density, type LibraryLayout } from '../lib/libraryPrefs'

/**
 * The library's view state beyond filter and sort: grouping, density and layout (remembered per
 * browser), touch select mode, the rows to reveal after an add, and the command palette.
 */
export function useLibraryWorkflow(selectedCount: number) {
  const [prefs, setPrefs] = useState(loadLibraryPrefs)
  const [selecting, setSelecting] = useState(false)
  const [reveal, setReveal] = useState<{ ids: readonly string[]; seq: number } | null>(null)
  const [paletteOpen, setPaletteOpen] = useState(false)
  const seq = useRef(0)

  const setGroup = useCallback((group: GroupBy) => {
    setPrefs((p) => ({ ...p, group }))
    saveLibraryPref('group', group)
  }, [])
  const setDensity = useCallback((density: Density) => {
    setPrefs((p) => ({ ...p, density }))
    saveLibraryPref('density', density)
  }, [])
  const setLayout = useCallback((layout: LibraryLayout) => {
    setPrefs((p) => ({ ...p, layout }))
    saveLibraryPref('layout', layout)
  }, [])

  /** Scroll to these rows and pulse them once; the list does it as soon as they render. */
  const revealRows = useCallback((ids: readonly string[]) => {
    if (ids.length > 0) setReveal({ ids, seq: ++seq.current })
  }, [])

  // Select mode ends by itself once nothing is left selected.
  useEffect(() => {
    if (selecting && selectedCount === 0) setSelecting(false)
  }, [selecting, selectedCount])

  const openPalette = useCallback(() => setPaletteOpen(true), [])
  const closePalette = useCallback(() => setPaletteOpen(false), [])

  return {
    ...prefs,
    setGroup,
    setDensity,
    setLayout,
    selecting,
    setSelecting,
    reveal,
    revealRows,
    paletteOpen,
    openPalette,
    closePalette,
  }
}
