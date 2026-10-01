import { Fragment, useEffect, useId, useMemo, useRef, useState, type KeyboardEvent } from 'react'
import { useTranslation } from 'react-i18next'
import { afterHistorySettles } from '../hooks/useBackToClose'
import { useDialogFocus } from '../hooks/useDialogFocus'
import { usePaletteCommands, type PaletteDeps } from '../hooks/usePaletteCommands'
import { rankCommands, type PaletteCommand } from '../lib/palette'
import { SearchIcon } from './Icons'

/** The palette with its commands; mount it only while open, so they are built only then. */
export function PaletteHost({ onClose, ...deps }: PaletteDeps & { onClose: () => void }) {
  const commands = usePaletteCommands(deps)
  return <CommandPalette commands={commands} onClose={onClose} />
}

interface CommandPaletteProps {
  commands: readonly PaletteCommand[]
  onClose: () => void
}

/**
 * ⌘/Ctrl+K: one field that finds a command or a download. A combobox over a grouped listbox —
 * focus stays in the field, the arrow keys move `aria-activedescendant`, Enter runs the active
 * command and closes.
 */
export function CommandPalette({ commands, onClose }: CommandPaletteProps) {
  const { t } = useTranslation()
  const ref = useRef<HTMLDivElement>(null)
  const inputRef = useRef<HTMLInputElement>(null)
  const [query, setQuery] = useState('')
  const [active, setActive] = useState(0)
  const baseId = useId()
  useDialogFocus(ref, { onEscape: onClose })

  useEffect(() => {
    inputRef.current?.focus()
  }, [])

  const groups = useMemo(() => rankCommands(commands, query), [commands, query])
  const flat = useMemo(() => groups.flatMap((g) => g.commands), [groups])
  const current = flat[Math.min(active, flat.length - 1)]
  const optionId = (c: PaletteCommand) => `${baseId}-${c.id}`

  // A new query starts from the best match.
  useEffect(() => setActive(0), [query])

  useEffect(() => {
    if (!current) return
    const el = document.getElementById(optionId(current))
    el?.scrollIntoView?.({ block: 'nearest' })
    // optionId is derived from baseId, which never changes.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [current])

  const run = (c: PaletteCommand | undefined) => {
    if (!c) return
    onClose()
    // The palette's own history entry is dropped as it unmounts; a layer the command opens in the
    // same commit would have its entry popped instead and close at once. Run after that settles.
    setTimeout(() => void afterHistorySettles().then(() => c.run()), 0)
  }

  const onKeyDown = (e: KeyboardEvent<HTMLInputElement>) => {
    const move = (to: number) => {
      e.preventDefault()
      if (flat.length > 0) setActive((to + flat.length) % flat.length)
    }
    switch (e.key) {
      case 'ArrowDown':
        return move(active + 1)
      case 'ArrowUp':
        return move(active - 1)
      case 'Home':
        if (e.ctrlKey || e.metaKey) move(0)
        return
      case 'End':
        if (e.ctrlKey || e.metaKey) move(flat.length - 1)
        return
      case 'Enter':
        e.preventDefault()
        run(current)
        return
    }
  }

  return (
    <div
      className="scrim open palette-scrim"
      onClick={(e) => {
        if (e.target === e.currentTarget) onClose()
      }}
    >
      <div className="modal palette" ref={ref} role="dialog" aria-modal="true" aria-label={t('workflow.palette.label')}>
        <div className="pinput">
          <SearchIcon aria-hidden="true" />
          <input
            ref={inputRef}
            role="combobox"
            aria-expanded="true"
            aria-controls={`${baseId}-list`}
            aria-autocomplete="list"
            aria-activedescendant={current ? optionId(current) : undefined}
            aria-label={t('workflow.palette.label')}
            placeholder={t('workflow.palette.placeholder')}
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            onKeyDown={onKeyDown}
            autoComplete="off"
            spellCheck={false}
          />
          <kbd className="kbd">Esc</kbd>
        </div>
        <div className="plist" id={`${baseId}-list`} role="listbox" aria-label={t('workflow.palette.results')}>
          {flat.length === 0 && (
            <div className="pempty" role="presentation">
              {t('workflow.palette.empty', { query })}
            </div>
          )}
          {groups.map((g) => (
            <div key={g.group} role="group" aria-labelledby={`${baseId}-g-${g.group}`}>
              <div className="pghead" id={`${baseId}-g-${g.group}`} role="presentation">
                {t(`workflow.palette.group.${g.group}`)}
              </div>
              {g.commands.map((c) => {
                const on = c === current
                return (
                  <div
                    key={c.id}
                    id={optionId(c)}
                    role="option"
                    aria-selected={on}
                    className={`popt${on ? ' on' : ''}`}
                    onMouseMove={() => {
                      if (!on) setActive(flat.indexOf(c))
                    }}
                    onClick={() => run(c)}
                  >
                    <span className="plabel">{c.label}</span>
                    {c.keys && (
                      <span className="pkeys" aria-hidden="true">
                        {c.keys.map((k, i) => (
                          <Fragment key={i}>
                            <kbd className="kbd">{k}</kbd>
                          </Fragment>
                        ))}
                      </span>
                    )}
                  </div>
                )
              })}
            </div>
          ))}
        </div>
        <div className="pfoot" aria-hidden="true">
          <span>
            <kbd className="kbd">↑</kbd>
            <kbd className="kbd">↓</kbd> {t('workflow.palette.move')}
          </span>
          <span>
            <kbd className="kbd">↵</kbd> {t('workflow.palette.run')}
          </span>
        </div>
      </div>
    </div>
  )
}
