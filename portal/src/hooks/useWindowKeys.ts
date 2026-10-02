import type { RefObject } from 'react'
import { useAppKeys, type AppKeyDeps } from './useAppKeys'
import type { AppState } from './useAppState'
import { useBackToClose } from './useBackToClose'
import { usePasteToAdd } from './usePasteToAdd'
import { rowElement, type useAppNavigation } from './useAppNavigation'

type Navigation = ReturnType<typeof useAppNavigation>

type Deps = Pick<
  AppKeyDeps,
  'visible' | 'selectedVisible' | 'canWrite' | 'runBulk' | 'removeMany' | 'openAdd' | 'copy' | 'openPalette'
> & {
  state: AppState
  nav: Navigation
  /** A dialog is up: shortcuts and paste-to-add stand down. */
  modalOpen: boolean
  settingsDirtyRef: RefObject<boolean>
  focusSearch: () => void
  /** Escape also leaves select mode and closes Add. */
  endSelecting: () => void
  closeAdd: () => void
  /** A link pasted with nothing focused. */
  pasteLinks: (text: string) => void
}

/** The window's keyboard: single-key shortcuts, Escape, and a link pasted with nothing focused. */
export function useWindowKeys({ state, nav, modalOpen, settingsDirtyRef, ...deps }: Deps) {
  const { view, setView, menu, setMenu, setSidebarOpen, setHelpOpen, selection, select } = state
  const { selectView, openDetail, goToFilter } = nav

  useAppKeys({
    // An open menu owns the keyboard like a modal does: N or Delete must not act behind it.
    enabled: !modalOpen && menu == null,
    onEscape: () => {
      setMenu(null)
      deps.endSelecting()
      deps.closeAdd()
      setSidebarOpen(false)
      setHelpOpen(false)
    },
    view,
    visible: deps.visible,
    lead: selection.lead,
    selectedVisible: deps.selectedVisible,
    canWrite: deps.canWrite,
    select,
    openDetail,
    runBulk: deps.runBulk,
    removeMany: deps.removeMany,
    openAdd: deps.openAdd,
    focusSearch: () => {
      if (view === 'settings' && settingsDirtyRef.current) return selectView('library')
      setView('library')
      deps.focusSearch()
    },
    openHelp: () => setHelpOpen(true),
    rowElement,
    goToFilter: (f) => goToFilter(f),
    goToView: (v) => selectView(v),
    copy: deps.copy,
    openPalette: deps.openPalette,
  })

  usePasteToAdd(deps.canWrite && !modalOpen && menu == null, deps.pasteLinks)
}

interface Layers {
  state: AppState
  /** The detail sheet covers the library (narrow layout) and is open. */
  sheetCovers: boolean
  closePanel: () => void
  addOpen: boolean
  closeAdd: () => void
  paletteOpen: boolean
  closePalette: () => void
}

/** Back closes whatever layer is on top rather than leaving the portal. */
export function useBackLayers(layers: Layers) {
  const { state, sheetCovers, closePanel, addOpen, closeAdd, paletteOpen, closePalette } = layers
  const { sidebarOpen, setSidebarOpen, helpOpen, setHelpOpen, confirmReq, setConfirmReq } = state
  useBackToClose(sheetCovers, closePanel)
  useBackToClose(sidebarOpen, () => setSidebarOpen(false))
  useBackToClose(addOpen, closeAdd)
  useBackToClose(helpOpen, () => setHelpOpen(false))
  useBackToClose(paletteOpen, closePalette)
  useBackToClose(confirmReq != null, () => setConfirmReq(null))
}
