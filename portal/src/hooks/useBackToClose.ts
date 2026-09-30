import { useEffect, useId, useRef } from 'react'

interface LayerState {
  goelLayers?: string[]
}

function layers(): string[] {
  return ((history.state as LayerState | null)?.goelLayers ?? []).slice()
}

/** The address the portal was showing when it stepped back to drop a closed layer's entry. */
let keepHash: string | null = null

/**
 * Steps back over a layer's own entry without navigating. The entry underneath still has the
 * address from when the layer opened; if the portal moved on meanwhile (picking Settings in the
 * drawer closes the drawer *and* switches view) landing there would fire a hashchange that routes
 * straight back. So the current address is carried down onto that entry.
 */
function dropEntry(): void {
  // After this commit's other effects, so the address is the one the new state mirrors.
  queueMicrotask(() => {
    keepHash = location.hash
    history.back()
  })
}

window.addEventListener('popstate', () => {
  if (keepHash == null) return
  if (location.hash !== keepHash) history.replaceState(history.state, '', keepHash)
  keepHash = null
})

/**
 * Makes Back (the Android button, an iOS edge swipe, the browser's own) close an open layer — the
 * phone sheet, the drawer, a dialog — instead of leaving the portal. Opening pushes a history entry
 * tagged with this layer; closing from the UI pops it again, so the history never fills with dead
 * entries. Tags stack, so closing a dialog over the sheet leaves the sheet's entry alone.
 */
export function useBackToClose(open: boolean, close: () => void): void {
  const id = useId()
  const closeRef = useRef(close)
  closeRef.current = close

  useEffect(() => {
    if (!open) return
    history.pushState({ ...(history.state as object | null), goelLayers: [...layers(), id] }, '')
    let popped = false
    const onPop = () => {
      if (layers().includes(id)) return
      popped = true
      closeRef.current()
    }
    window.addEventListener('popstate', onPop)
    return () => {
      window.removeEventListener('popstate', onPop)
      if (!popped && layers().at(-1) === id) dropEntry()
    }
  }, [open, id])
}
