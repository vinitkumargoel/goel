import { useEffect, useRef } from 'react'
import { useTranslation } from 'react-i18next'
import type { Filter, FilterCounts } from '../lib/filters'

/** Phone order: what people check most, first. Empty statuses stay out, except the current one. */
const CHIPS = ['all', 'active', 'queued', 'failed', 'completed', 'paused', 'seeding'] as const

interface FilterChipsProps {
  filter: Filter
  counts: FilterCounts
  onFilter: (filter: Filter) => void
}

/**
 * ≤680px: the sidebar's status filters as a scrolling chip row under the topbar, so switching
 * doesn't take the drawer. CSS hides it on wider screens, where the sidebar is always there.
 */
export function FilterChips({ filter, counts, onFilter }: FilterChipsProps) {
  const { t } = useTranslation()
  const row = useRef<HTMLDivElement>(null)
  const shown = CHIPS.filter((f) => f === 'all' || f === filter || counts[f] > 0)
  const label = (f: (typeof CHIPS)[number]) =>
    f === 'all' ? t('workflow.chips.all') : f === 'completed' ? t('workflow.chips.done') : t(`status.${f}`)

  // Keep the current chip in view when the filter changes from elsewhere (sidebar, a digit key).
  useEffect(() => {
    row.current?.querySelector<HTMLElement>('[aria-pressed="true"]')?.scrollIntoView?.({
      block: 'nearest',
      inline: 'nearest',
    })
  }, [filter])

  return (
    <div className="fchips" ref={row} role="group" aria-label={t('workflow.chips.label')}>
      {shown.map((f) => (
        <button
          key={f}
          type="button"
          className={`fchip${f === filter ? ' on' : ''}${f === 'failed' && counts.failed > 0 ? ' bad' : ''}`}
          aria-pressed={f === filter}
          onClick={() => onFilter(f)}
        >
          {label(f)}{' '}
          <span className="fcount">{counts[f]}</span>
        </button>
      ))}
    </div>
  )
}
