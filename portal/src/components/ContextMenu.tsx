import {
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
  type KeyboardEvent,
  type ReactNode,
} from 'react'

export interface MenuItem {
  key: string
  label: string
  icon?: ReactNode
  danger?: boolean
  action: () => void
}

export type MenuEntry = MenuItem | { separator: true }

export interface MenuState {
  x: number
  y: number
  entries: MenuEntry[]
  /** Accessible name for the menu, e.g. the download it acts on. */
  label?: string
}

const EDGE_GAP = 8

interface ContextMenuProps {
  menu: MenuState | null
  onClose: () => void
}

export function ContextMenu({ menu, onClose }: ContextMenuProps) {
  const ref = useRef<HTMLDivElement>(null)
  const opener = useRef<Element | null>(null)
  const [pos, setPos] = useState<{ left: number; top: number } | null>(null)

  // Clamping needs the menu's measured size, so the first pass must render hidden and reposition after paint.
  useLayoutEffect(() => {
    if (!menu || !ref.current) {
      setPos(null)
      return
    }
    const r = ref.current.getBoundingClientRect()
    setPos({
      left: Math.max(EDGE_GAP, Math.min(menu.x, window.innerWidth - r.width - EDGE_GAP)),
      top: Math.max(EDGE_GAP, Math.min(menu.y, window.innerHeight - r.height - EDGE_GAP)),
    })
  }, [menu])

  // Remember who opened the menu. Focus moves in only once it is positioned: a
  // `visibility:hidden` element can't take focus, so doing it on open would silently fail.
  const focusedFor = useRef<MenuState | null>(null)
  useEffect(() => {
    if (!menu) {
      focusedFor.current = null
      return
    }
    if (focusedFor.current === menu) return
    if (focusedFor.current === null) opener.current = document.activeElement
    if (!pos) return
    focusedFor.current = menu
    items(ref.current)[0]?.focus()
  }, [menu, pos])

  useEffect(() => {
    if (!menu) return
    // Capture phase: without it another control's own handler runs first and can reopen a menu this closes.
    const onDocClick = (e: MouseEvent) => {
      if (!(e.target as Element | null)?.closest('.menu')) onClose()
    }
    document.addEventListener('click', onDocClick, true)
    return () => document.removeEventListener('click', onDocClick, true)
  }, [menu, onClose])

  if (!menu) return null

  const restoreFocus = () => {
    const el = opener.current
    if (el instanceof HTMLElement && el.isConnected) el.focus()
  }

  const onKeyDown = (e: KeyboardEvent<HTMLDivElement>) => {
    const list = items(ref.current)
    const at = list.indexOf(document.activeElement as HTMLElement)
    const move = (i: number) => {
      e.preventDefault()
      list[(i + list.length) % list.length]?.focus()
    }
    switch (e.key) {
      case 'ArrowDown':
        return move(at + 1)
      case 'ArrowUp':
        return move(at < 0 ? -1 : at - 1)
      case 'Home':
        return move(0)
      case 'End':
        return move(-1)
      case 'Escape':
        e.preventDefault()
        e.stopPropagation()
        onClose()
        restoreFocus()
        return
      case 'Tab':
        // A menu is one tab stop: leaving it closes it, as a native menu does.
        e.preventDefault()
        onClose()
        restoreFocus()
        return
    }
  }

  return (
    <div
      className="menu"
      ref={ref}
      role="menu"
      aria-label={menu.label}
      onKeyDown={onKeyDown}
      style={
        pos
          ? { left: pos.left, top: pos.top }
          : { left: 0, top: 0, visibility: 'hidden' }
      }
    >
      {menu.entries.map((entry, i) =>
        'separator' in entry ? (
          <div className="msep" role="separator" key={`sep-${i}`} />
        ) : (
          <button
            type="button"
            role="menuitem"
            tabIndex={-1}
            className={`mi${entry.danger ? ' danger' : ''}`}
            key={entry.key}
            onClick={() => {
              onClose()
              // Focus goes home before the action runs, so a dialog the action opens can take it.
              restoreFocus()
              entry.action()
            }}
          >
            {entry.icon}
            <span className="t">{entry.label}</span>
          </button>
        ),
      )}
    </div>
  )
}

function items(root: HTMLElement | null): HTMLElement[] {
  return root ? [...root.querySelectorAll<HTMLElement>('[role="menuitem"]')] : []
}
