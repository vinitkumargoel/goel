/**
 * Opt-in system notifications, per browser. The preference and the permission are separate:
 * a user can turn it on here while the browser still says "ask", and turning it off never
 * revokes the permission (only the browser can).
 */

const KEY = 'goel.notify'

export type NotifyPermission = 'granted' | 'denied' | 'default' | 'unsupported'

export function notifySupported(): boolean {
  return typeof window !== 'undefined' && 'Notification' in window
}

export function notifyPermission(): NotifyPermission {
  return notifySupported() ? Notification.permission : 'unsupported'
}

export function loadNotify(): boolean {
  try {
    return localStorage.getItem(KEY) === '1'
  } catch {
    return false
  }
}

export function saveNotify(on: boolean): void {
  try {
    if (on) localStorage.setItem(KEY, '1')
    else localStorage.removeItem(KEY)
  } catch {
    // Private mode: the choice lasts this page load only.
  }
}

/** Asks only when the browser has not decided yet; resolves to what it now says. */
export async function requestNotify(): Promise<NotifyPermission> {
  if (!notifySupported()) return 'unsupported'
  if (Notification.permission !== 'default') return Notification.permission
  try {
    return await Notification.requestPermission()
  } catch {
    return Notification.permission
  }
}

/** Nothing when the tab is in front: the in-app toast already said it. */
export function showNotification(title: string, body: string, onClick: () => void): void {
  if (!loadNotify() || notifyPermission() !== 'granted') return
  if (document.visibilityState === 'visible' && document.hasFocus()) return
  try {
    const n = new Notification(title, { body, icon: '/icons/icon-192.png', tag: `${title}\u0000${body}` })
    n.onclick = () => {
      window.focus()
      onClick()
      n.close()
    }
  } catch {
    // Some mobile browsers only allow notifications from a service worker; the toast still ran.
  }
}
