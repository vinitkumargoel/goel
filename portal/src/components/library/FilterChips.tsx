import { useEffect, useRef, type MouseEvent } from 'react'
import { useTranslation } from 'react-i18next'
import { TYPE_FILTERS, isTypeFilter, type Filter, type FilterCounts } from '../../lib/filters'
import { Icon } from '../ui/Icon'
import type { MenuEntry, MenuState } from '../ui/Menu'

/** What people check most, first. Empty statuses stay out, except the current one. */
const CHIPS = ['all', 'active', 'queued', 'failed', 'completed', 'paused', 'seeding'] as const

interface FilterChipsProps {
  filter: Filter
  counts: FilterCounts
  onFilter: (filter: Filter) => void
  /** Every tag in the queue, most used first. */
  tags?: readonly { tag: string; count: number }[]
  activeTag?: string | null
  onTag?: (tag: string) => void
  /** Opens the Type ▾ and Tags ▾ menus (the app's one floating menu). */
  openMenu?: (menu: MenuState) => void
}

/** Where a chip's menu opens: under the chip, aligned to its left edge. */
function below(e: MouseEvent<HTMLButtonElement>) {
  const r = e.currentTarget.getBoundingClientRect()
  return { x: r.left, y: r.bottom + 6 }
}

/**
 * The status filters as a row of chips over the board, then Type ▾ and Tags ▾. The row scrolls
 * sideways on its own when it doesn't fit, never the page.
 */
export function FilterChips({ filter, counts, onFilter, tags = [], activeTag = null, onTag, openMenu }: FilterChipsProps) {
  const { t } = useTranslation()
  const row = useRef<HTMLDivElement>(null)
  const shown = CHIPS.filter((f) => f === 'all' || f === filter || counts[f] > 0)
  const label = (f: (typeof CHIPS)[number]) =>
    f === 'all' ? t('workflow.chips.all') : f === 'completed' ? t('workflow.chips.done') : t(`status.${f}`)
  const type = isTypeFilter(filter) ? filter : null

  // Keep the current chip in view when the filter changes from elsewhere (the rail, a digit key).
  useEffect(() => {
    row.current?.querySelector<HTMLElement>('[aria-pressed="true"]')?.scrollIntoView?.({
      block: 'nearest',
      inline: 'nearest',
    })
  }, [filter, activeTag])

  const typeMenu = (e: MouseEvent<HTMLButtonElement>) => {
    const entries: MenuEntry[] = [
      { key: 'all', label: t('board.chips.allTypes'), checked: type == null, action: () => onFilter('all') },
      { separator: true },
      ...TYPE_FILTERS.filter((f) => counts[f] > 0 || f === type).map((f) => ({
        key: f,
        label: t(`fileType.${f}`),
        detail: t('workflow.library.count', { count: counts[f] }),
        checked: f === type,
        action: () => onFilter(f),
      })),
    ]
    openMenu?.({ ...below(e), entries, label: t('board.chips.type') })
  }

  const tagMenu = (e: MouseEvent<HTMLButtonElement>) => {
    const entries: MenuEntry[] = tags.map(({ tag, count }) => ({
      key: `tag:${tag}`,
      label: tag,
      detail: t('workflow.library.count', { count }),
      checked: activeTag != null && tag.toLowerCase() === activeTag.toLowerCase(),
      action: () => onTag?.(tag),
    }))
    openMenu?.({ ...below(e), entries, label: t('board.chips.tags') })
  }

  return (
    <div className="lib-chips" ref={row} role="group" aria-label={t('workflow.chips.label')}>
      {shown.map((f) => (
        <button
          key={f}
          type="button"
          className={`chip${f === 'failed' && counts.failed > 0 ? ' bad' : ''}`}
          aria-pressed={f === filter && activeTag == null}
          onClick={() => onFilter(f)}
        >
          {label(f)} <span className="n">{counts[f]}</span>
        </button>
      ))}
      {openMenu && (
        <>
          <span className="vsep" aria-hidden="true" />
          <button
            type="button"
            className="chip"
            aria-pressed={type != null}
            aria-haspopup="menu"
            onClick={typeMenu}
          >
            {type ? t(`fileType.${type}`) : t('board.chips.type')}
            <Icon name="chevronDown" size="s" />
          </button>
          {tags.length > 0 && (
            <button
              type="button"
              className="chip"
              aria-pressed={activeTag != null}
              aria-haspopup="menu"
              onClick={tagMenu}
            >
              <Icon name="tag" size="s" />
              {activeTag ?? t('board.chips.tags')}
              <Icon name="chevronDown" size="s" />
            </button>
          )}
        </>
      )}
    </div>
  )
}
