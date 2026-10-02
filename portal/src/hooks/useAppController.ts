import { useCallback, useEffect, useRef } from 'react'
import { BOOT } from '../lib/boot'
import { NARROW_QUERY, PHONE_QUERY } from '../lib/breakpoints'
import type { RowAction } from '../lib/taskKind'
import type { TaskRow } from '../lib/types'
import { useActivitySignals } from './useActivitySignals'
import { useAddFlow } from './useAddFlow'
import { useAppData } from './useAppData'
import { useAppMenus } from './useAppMenus'
import { useAppNavigation, useRouteSync } from './useAppNavigation'
import { useAppState, useSettingsDirty } from './useAppState'
import { useDetail } from './useDetail'
import { useLibraryModel } from './useLibraryModel'
import { useLibraryWorkflow } from './useLibraryWorkflow'
import { useMediaQuery } from './useMediaQuery'
import { useQueueControls } from './useQueueControls'
import { useSearchFocus } from './useSearchFocus'
import { useThemeChoice } from './useThemeChoice'
import { useBackLayers, useWindowKeys } from './useWindowKeys'

/**
 * Everything the portal's window needs, wired together: state, server data, what is on screen,
 * navigation, menus, the add flow, the keyboard and Back. App only lays it out.
 */
export function useAppController() {
  const core = useLibraryCore()
  const { state, data, model, nav, queue, canWrite, openPlayer } = core
  const { tasks, toast, refresh, actions } = data
  const { setView, setHelpOpen, setFilter } = state

  const menus = useAppMenus({
    setMenu: state.setMenu,
    bandwidth: data.bandwidth,
    onCustomBandwidth: canWrite ? queue.controls.edit : undefined,
    openSettings: useCallback(() => setView('settings'), [setView]),
    openHelp: useCallback(() => setHelpOpen(true), [setHelpOpen]),
    tasks,
    selectedIds: state.selection.ids,
    selectedVisible: model.selectedVisible,
    canWrite,
    select: state.select,
    copy: data.copy,
    toast,
    runAction: actions.runAction,
    runBulk: actions.runBulk,
    removeTask: actions.removeTask,
    removeMany: actions.removeMany,
    queue: queue.controls,
    onStream: openPlayer,
  })

  const { selectView, openDetail } = nav
  useActivitySignals({
    tasks,
    loaded: data.loaded,
    toast,
    onShow: useCallback(
      (id: string) => {
        selectView('library')
        openDetail(id)
      },
      [selectView, openDetail],
    ),
  })

  const add = useAddFlow({
    canWrite,
    toast,
    refresh,
    onReveal: nav.revealAdded,
    onQueued: useCallback(
      (resetFilter: boolean) => {
        if (resetFilter) setFilter('all')
        selectView('library')
      },
      [selectView, setFilter],
    ),
  })

  const chrome = useWindowChrome(core, add)
  return { ...core, ...chrome, menus, add }
}

/** State, server data, what is on screen, the detail sheet and navigation: the library itself. */
function useLibraryCore() {
  const state = useAppState()
  const settings = useSettingsDirty()
  const [theme, setTheme] = useThemeChoice()
  const drawerButtonRef = useRef<HTMLButtonElement>(null)
  const { searchRef, focusSearch } = useSearchFocus()
  const phone = useMediaQuery(PHONE_QUERY)
  const data = useAppData(state.setConfirmReq)
  const { tasks, toast, refresh, loaded } = data
  const canWrite = !BOOT.readOnly
  const { selection, select, setPlaying } = state
  const wf = useLibraryWorkflow(selection.ids.size)
  const model = useLibraryModel({ ...state, tasks, group: wf.group })
  const detail = useDetail(model.detailId, tasks, state.view === 'library' && model.panelShown, data.warn)

  // A snapshot without a selected row means it was removed elsewhere; drop it from the selection.
  useEffect(() => {
    if (loaded) select({ type: 'prune', existing: tasks.map((t) => t.id) })
  }, [tasks, loaded])

  const queue = useQueueControls({ tasks, toast, refresh, reload: detail.reload })
  const openPlayer = useCallback((task: TaskRow) => setPlaying(task.id), [setPlaying])
  const playingTask = state.playing == null ? undefined : tasks.find((task) => task.id === state.playing)

  const nav = useAppNavigation({
    state,
    visible: model.visible,
    detailId: model.detailId,
    panelShown: model.panelShown,
    settingsDirtyRef: settings.settingsDirtyRef,
    revealRows: wf.revealRows,
  })

  return {
    state,
    settings,
    theme,
    setTheme,
    drawerButtonRef,
    searchRef,
    focusSearch,
    phone,
    data,
    canWrite,
    wf,
    model,
    detail,
    queue,
    openPlayer,
    playingTask,
    nav,
  }
}

/** The keyboard, the route in the address bar, Back, and whether a dialog makes the window inert. */
function useWindowChrome(core: ReturnType<typeof useLibraryCore>, add: ReturnType<typeof useAddFlow>) {
  const { state, data, model, wf, nav, queue, settings, canWrite } = core
  const { actions } = data

  // While a dialog is up, everything behind it is inert: Tab, a screen reader's virtual cursor and
  // a stray click can't reach it, even when focus has fallen back to <body>.
  const modalOpen =
    add.addOpen ||
    state.confirmReq != null ||
    state.helpOpen ||
    wf.paletteOpen ||
    queue.editing ||
    state.playing != null

  useWindowKeys({
    state,
    nav,
    modalOpen,
    settingsDirtyRef: settings.settingsDirtyRef,
    focusSearch: core.focusSearch,
    endSelecting: () => wf.setSelecting(false),
    closeAdd: add.closeAdd,
    pasteLinks: (text) => add.openAddWith(text, true),
    visible: model.ordered,
    selectedVisible: model.selectedVisible,
    canWrite,
    runBulk: actions.runBulk,
    removeMany: actions.removeMany,
    openAdd: add.openAdd,
    copy: data.copy,
    openPalette: wf.openPalette,
  })

  const { runAction } = actions
  const onRowAction = useCallback((id: string, a: RowAction) => void runAction(id, a), [runAction])

  useRouteSync(state, model.selectedLead)

  const narrow = useMediaQuery(NARROW_QUERY)
  useBackLayers({
    state,
    sheetCovers: state.view === 'library' && model.panelShown && narrow,
    closePanel: nav.closePanel,
    addOpen: add.addOpen,
    closeAdd: add.closeAdd,
    paletteOpen: wf.paletteOpen,
    closePalette: wf.closePalette,
  })

  return { modalOpen, onRowAction, narrow }
}

export type AppController = ReturnType<typeof useAppController>
