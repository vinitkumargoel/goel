import { useCallback } from 'react'
import type { QueueEdit } from '../components/dialogs/QueueDialogs'
import type { MenuState } from '../components/ui/Menu'
import type { AppMenu } from './useAppState'
import type { Bandwidth } from './useBandwidth'
import { useBandwidthMenu } from './useBandwidthMenu'
import { useMenus } from './useMenus'

type MenuDeps = Omit<Parameters<typeof useMenus>[0], 'openMenu'>

interface Deps extends MenuDeps {
  setMenu: (menu: AppMenu | null) => void
  bandwidth: Bandwidth
  /** "Custom…" on the bandwidth menu; absent when the portal is read-only. */
  onCustomBandwidth?: (edit: QueueEdit) => void
  openSettings: () => void
  openHelp: () => void
}

/**
 * The app's three menu owners on its one `Menu`: rows (and the type chips), the user menu, and
 * the bandwidth pill. Each tags the menu so its control can show itself open.
 */
export function useAppMenus({ setMenu, bandwidth, onCustomBandwidth, openSettings, openHelp, ...deps }: Deps) {
  const openMenu = useCallback((m: MenuState) => setMenu({ ...m, owner: 'row' }), [setMenu])

  const { openRowMenu, removeEntries, userMenu } = useMenus({ ...deps, openMenu })

  const openUserMenu = useCallback(
    (anchor: DOMRect) => setMenu({ ...userMenu(anchor, openSettings, openHelp), owner: 'user' }),
    [userMenu, setMenu, openSettings, openHelp],
  )

  const openBandwidthMenu = useBandwidthMenu(
    bandwidth,
    useCallback((m: MenuState) => setMenu({ ...m, owner: 'bandwidth' }), [setMenu]),
    deps.toast,
    onCustomBandwidth,
  )

  return { openMenu, openRowMenu, removeEntries, openUserMenu, openBandwidthMenu }
}
