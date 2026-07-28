import { useEffect, useLayoutEffect, useRef, useState, type ReactNode } from 'react'

export interface MenuItem {
  key: string
  label: string
  icon?: ReactNode
  danger?: boolean
  action: () => void
}

/** A separator between groups. */
export type MenuEntry = MenuItem | { separator: true }

export interface MenuState {
  x: number
  y: number
  entries: MenuEntry[]
}

const EDGE_GAP = 8

interface ContextMenuProps {
  menu: MenuState | null
  onClose: () => void
}

export function ContextMenu({ menu, onClose }: ContextMenuProps) {
  const ref = useRef<HTMLDivElement>(null)
  const [pos, setPos] = useState<{ left: number; top: number } | null>(null)

  // Position after paint: the clamp needs the menu's real size (depends on its longest label). Rendering
  // off-screen first avoids a visible jump from the unclamped position to the clamped one.
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

  useEffect(() => {
    if (!menu) return
    // Capture phase, so a click that lands on another control closes this menu
    // before that control's own handler runs and possibly opens a new one.
    const onDocClick = (e: MouseEvent) => {
      if (!(e.target as Element | null)?.closest('.menu')) onClose()
    }
    document.addEventListener('click', onDocClick, true)
    return () => document.removeEventListener('click', onDocClick, true)
  }, [menu, onClose])

  if (!menu) return null

  return (
    <div
      className="menu"
      ref={ref}
      style={
        pos
          ? { left: pos.left, top: pos.top }
          : // First pass: laid out for measurement only, kept out of sight.
            { left: 0, top: 0, visibility: 'hidden' }
      }
    >
      {menu.entries.map((entry, i) =>
        'separator' in entry ? (
          <div className="msep" key={`sep-${i}`} />
        ) : (
          <div
            className={`mi${entry.danger ? ' danger' : ''}`}
            key={entry.key}
            onClick={() => {
              entry.action()
              onClose()
            }}
          >
            {entry.icon}
            <span className="t">{entry.label}</span>
          </div>
        ),
      )}
    </div>
  )
}
