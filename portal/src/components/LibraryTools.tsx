import { useId } from 'react'
import { useTranslation } from 'react-i18next'
import { GROUP_BYS, type GroupBy } from '../lib/grouping'
import type { Density, LibraryLayout } from '../lib/libraryPrefs'
import type { SortKey, SortState } from '../lib/sort'
import { SortPicker } from './LibraryView'

interface LibraryToolsProps {
  count: number
  group: GroupBy
  onGroup: (group: GroupBy) => void
  density: Density
  onDensity: (density: Density) => void
  layout: LibraryLayout
  onLayout: (layout: LibraryLayout) => void
  /** Card view has no column headers, so its sort lives here. */
  sort: SortState
  onSort: (key: SortKey) => void
}

/** The strip above the list: how many rows, grouping, density and table vs cards. */
export function LibraryTools({
  count,
  group,
  onGroup,
  density,
  onDensity,
  layout,
  onLayout,
  sort,
  onSort,
}: LibraryToolsProps) {
  const { t } = useTranslation()
  const groupId = useId()
  return (
    <div className="ltools">
      <span className="lcount">{t('workflow.library.count', { count })}</span>
      <span className="sp" />
      {layout === 'cards' && <SortPicker sort={sort} onSort={onSort} />}
      <label className="lt-label" htmlFor={groupId}>
        {t('workflow.library.groupBy')}
      </label>
      <select
        id={groupId}
        className="lt-select"
        value={group}
        onChange={(e) => onGroup(e.target.value as GroupBy)}
      >
        {GROUP_BYS.map((g) => (
          <option key={g} value={g}>
            {t(`workflow.library.group.${g}`)}
          </option>
        ))}
      </select>
      <Toggle
        label={t('workflow.library.density')}
        value={density}
        options={[
          ['comfortable', t('workflow.library.comfortable')],
          ['compact', t('workflow.library.compact')],
        ]}
        onChange={onDensity}
      />
      <Toggle
        label={t('workflow.library.layout')}
        value={layout}
        options={[
          ['table', t('workflow.library.table')],
          ['cards', t('workflow.library.cards')],
        ]}
        onChange={onLayout}
      />
    </div>
  )
}

/** A two-way segmented switch: buttons with aria-pressed inside a labelled group. */
function Toggle<V extends string>({
  label,
  value,
  options,
  onChange,
}: {
  label: string
  value: V
  options: readonly (readonly [V, string])[]
  onChange: (value: V) => void
}) {
  return (
    <div className="seg lt-seg" role="group" aria-label={label}>
      {options.map(([v, text]) => (
        <button
          key={v}
          type="button"
          aria-pressed={value === v}
          className={value === v ? 'on' : undefined}
          onClick={() => onChange(v)}
        >
          {text}
        </button>
      ))}
    </div>
  )
}
