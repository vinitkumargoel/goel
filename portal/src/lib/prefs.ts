/** Per-browser layout habits. Storage may be unavailable (private mode, blocked site data). */

const AUTO_HIDE_KEY = 'goel.panel.autoHide'

/** Off by default: with nothing selected the panel shows the queue overview. */
export function loadPanelAutoHide(): boolean {
  try {
    return localStorage.getItem(AUTO_HIDE_KEY) === '1'
  } catch {
    return false
  }
}

export function savePanelAutoHide(on: boolean): void {
  try {
    if (on) localStorage.setItem(AUTO_HIDE_KEY, '1')
    else localStorage.removeItem(AUTO_HIDE_KEY)
  } catch {
    // A convenience: without storage the choice lasts until reload.
  }
}

/**
 * Whether the detail panel is on screen. Auto-hide only ever hides it — never opens it — and only
 * while nothing is selected, so a selection still brings the panel in when the user left it open.
 */
export function panelVisible(open: boolean, autoHide: boolean, hasSelection: boolean): boolean {
  return open && (hasSelection || !autoHide)
}

const RAIL_KEY = 'goel.rail.expanded'

/** The desktop rail: slim icons by default, as in the app; labels and counts once pinned open. */
export function loadRailExpanded(): boolean {
  try {
    return localStorage.getItem(RAIL_KEY) === '1'
  } catch {
    return false
  }
}

export function saveRailExpanded(on: boolean): void {
  try {
    if (on) localStorage.setItem(RAIL_KEY, '1')
    else localStorage.removeItem(RAIL_KEY)
  } catch {
    // A convenience: without storage the choice lasts until reload.
  }
}
