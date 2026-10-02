import { useRef, type KeyboardEvent, type ReactNode } from 'react'
import { Icon, type IconName } from './Icon'

export interface SegOption<T extends string> {
  value: T
  label: string
  icon?: IconName
  /** Shown as the tooltip; the label is the accessible name. */
  title?: string
  disabled?: boolean
}

interface SegProps<T extends string> {
  value: T
  options: readonly SegOption<T>[]
  onChange: (value: T) => void
  /** Names the group. */
  label: string
  size?: 'sm' | 'md'
  full?: boolean
  /** Icons only, the label kept for assistive tech and the tooltip. */
  iconOnly?: boolean
  className?: string
}

/**
 * The Studio segmented control as an ARIA radio group: one Tab stop, arrow keys move and select,
 * Home/End jump. Use it for a small exclusive choice (Board/Table, a priority, a theme).
 */
export function Seg<T extends string>({
  value,
  options,
  onChange,
  label,
  size = 'md',
  full = false,
  iconOnly = false,
  className,
}: SegProps<T>) {
  const ref = useRef<HTMLDivElement>(null)
  const enabled = options.filter((o) => !o.disabled)
  const pick = (next: SegOption<T> | undefined) => {
    if (!next) return
    onChange(next.value)
    ref.current?.querySelector<HTMLElement>(`[data-value="${CSS.escape(next.value)}"]`)?.focus()
  }
  const onKeyDown = (e: KeyboardEvent<HTMLDivElement>) => {
    const at = enabled.findIndex((o) => o.value === value)
    const step = (d: number) => {
      e.preventDefault()
      pick(enabled[(at + d + enabled.length) % enabled.length])
    }
    switch (e.key) {
      case 'ArrowRight':
      case 'ArrowDown':
        return step(1)
      case 'ArrowLeft':
      case 'ArrowUp':
        return step(-1)
      case 'Home':
        e.preventDefault()
        return pick(enabled[0])
      case 'End':
        e.preventDefault()
        return pick(enabled[enabled.length - 1])
    }
  }
  const cls = ['seg', size === 'sm' ? 'sm' : '', full ? 'full' : '', className ?? ''].filter(Boolean).join(' ')
  return (
    <div ref={ref} className={cls} role="radiogroup" aria-label={label} onKeyDown={onKeyDown}>
      {options.map((o) => {
        const on = o.value === value
        return (
          <button
            key={o.value}
            type="button"
            role="radio"
            aria-checked={on}
            data-value={o.value}
            tabIndex={on ? 0 : -1}
            disabled={o.disabled}
            title={o.title ?? (iconOnly ? o.label : undefined)}
            aria-label={iconOnly ? o.label : undefined}
            onClick={() => onChange(o.value)}
          >
            {o.icon && <Icon name={o.icon} size="s" />}
            {!iconOnly && <span>{o.label}</span>}
          </button>
        )
      })}
    </div>
  )
}

interface SwitchProps {
  checked: boolean
  onChange: (checked: boolean) => void
  /** The accessible name when no visible label is tied to it. */
  label?: string
  labelledBy?: string
  describedBy?: string
  disabled?: boolean
  id?: string
}

/** The Studio toggle as a `role="switch"` button. */
export function Switch({ checked, onChange, label, labelledBy, describedBy, disabled, id }: SwitchProps) {
  return (
    <button
      type="button"
      role="switch"
      id={id}
      className="toggle"
      aria-checked={checked}
      aria-label={label}
      aria-labelledby={labelledBy}
      aria-describedby={describedBy}
      disabled={disabled}
      onClick={() => onChange(!checked)}
    />
  )
}

interface ToggleRowProps {
  title: ReactNode
  detail?: ReactNode
  checked: boolean
  onChange: (checked: boolean) => void
  disabled?: boolean
  id: string
}

/** A settings row (`.srow`): title and detail on the left, the switch on the right, all one label. */
export function ToggleRow({ title, detail, checked, onChange, disabled, id }: ToggleRowProps) {
  return (
    <div className="srow">
      <div className="sl">
        <b id={`${id}-t`}>{title}</b>
        {detail && <span id={`${id}-d`}>{detail}</span>}
      </div>
      <Switch
        checked={checked}
        onChange={onChange}
        disabled={disabled}
        labelledBy={`${id}-t`}
        describedBy={detail ? `${id}-d` : undefined}
      />
    </div>
  )
}
