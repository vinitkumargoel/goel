import { useId, useRef, type KeyboardEvent } from 'react'
import { Trans, useTranslation } from 'react-i18next'
import { THEME_CHOICES, type ThemeChoice } from '../../lib/theme'

interface ThemeTilesProps {
  theme: ThemeChoice
  onPick: (choice: ThemeChoice, label: string) => void
}

/**
 * Light, Dark and Match system as small pictures of the window in each palette: a radio group,
 * one Tab stop, the arrow keys move and pick.
 */
export function ThemeTiles({ theme, onPick }: ThemeTilesProps) {
  const { t } = useTranslation()
  const ref = useRef<HTMLDivElement>(null)
  const id = useId()
  const label = (c: ThemeChoice) => (c === 'auto' ? t('pages.settings.matchSystem') : t(`settings.theme.${c}`))

  const pick = (c: ThemeChoice | undefined) => {
    if (!c) return
    onPick(c, label(c))
    ref.current?.querySelector<HTMLElement>(`[data-theme-choice="${c}"]`)?.focus()
  }
  const onKeyDown = (e: KeyboardEvent<HTMLDivElement>) => {
    const at = THEME_CHOICES.indexOf(theme)
    const n = THEME_CHOICES.length
    const go = (i: number) => {
      e.preventDefault()
      pick(THEME_CHOICES[(i + n) % n])
    }
    switch (e.key) {
      case 'ArrowRight':
      case 'ArrowDown':
        return go(at + 1)
      case 'ArrowLeft':
      case 'ArrowUp':
        return go(at - 1)
      case 'Home':
        return go(0)
      case 'End':
        return go(n - 1)
    }
  }

  return (
    <div className="set-theme">
      <p className="small muted set-theme-d" id={`${id}-d`}>
        <Trans i18nKey="settings.theme.desc" components={{ bold: <b /> }} />
      </p>
      <div
        ref={ref}
        className="set-tiles"
        role="radiogroup"
        aria-label={t('settings.theme.name')}
        aria-describedby={`${id}-d`}
        onKeyDown={onKeyDown}
      >
        {THEME_CHOICES.map((c) => {
          const on = c === theme
          return (
            <button
              key={c}
              type="button"
              role="radio"
              aria-checked={on}
              tabIndex={on ? 0 : -1}
              data-theme-choice={c}
              className={`set-tile${on ? ' on' : ''}`}
              onClick={() => onPick(c, label(c))}
            >
              <span className={`set-pic set-pic-${c}`} aria-hidden="true">
                <i />
                <i />
                <b />
              </span>
              <span className="small">{label(c)}</span>
            </button>
          )
        })}
      </div>
    </div>
  )
}
