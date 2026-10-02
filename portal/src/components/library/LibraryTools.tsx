import { useId } from 'react'
import { useTranslation } from 'react-i18next'
import { GROUP_BYS, type GroupBy } from '../../lib/grouping'
import type { Density, LibraryLayout } from '../../lib/libraryPrefs'
import type { SortKey, SortState } from '../../lib/sort'
import { Seg } from '../ui/Controls'
import { Icon } from '../ui/Icon'
import { Popover } from '../ui/Popover'
import { SortPicker } from './SortPicker'

interface LibraryToolsProps {
  count: number
  group: GroupBy
  onGroup: (group: GroupBy) => void
  density: Density
  onDensity: (density: Density) => void
  layout: LibraryLayout
  onLayout: (layout: LibraryLayout) => void
  /** The board (and a phone's table) has no column headers, so the sort lives here too. */
  sort: SortState
  onSort: (key: SortKey) => void
}

/**
 * The right end of the filter row: how many downloads show, a View popover (sort, Group by,
 * density) and the Board / Table switch.
 */
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
    <div className="lib-tools">
      <span className="lib-count small muted">{t('workflow.library.count', { count })}</span>
      <Popover
        label={t('board.tools.viewOptions')}
        triggerClassName="chip"
        alignEnd
        className="lib-viewpop"
        trigger={
          <>
            <Icon name="sort" size="s" />
            <span className="lib-viewlbl">{t('board.tools.view')}</span>
            <Icon name="chevronDown" size="s" />
          </>
        }
      >
        <div className="lib-vrow">
          <span className="lbl">{t('library.sortBy')}</span>
          <SortPicker sort={sort} onSort={onSort} />
        </div>
        <div className="lib-vrow">
          <label className="lbl" htmlFor={groupId}>
            {t('workflow.library.groupBy')}
          </label>
          <span className="field sm select">
            <select id={groupId} value={group} onChange={(e) => onGroup(e.target.value as GroupBy)}>
              {GROUP_BYS.map((g) => (
                <option key={g} value={g}>
                  {t(`workflow.library.group.${g}`)}
                </option>
              ))}
            </select>
            <Icon name="chevronDown" size="s" />
          </span>
        </div>
        <div className="lib-vrow">
          <span className="lbl" aria-hidden="true">
            {t('workflow.library.density')}
          </span>
          <Seg
            size="sm"
            label={t('workflow.library.density')}
            value={density}
            onChange={onDensity}
            options={[
              { value: 'comfortable', label: t('workflow.library.comfortable') },
              { value: 'compact', label: t('workflow.library.compact') },
            ]}
          />
        </div>
      </Popover>
      <Seg
        size="sm"
        iconOnly
        className="lib-layout"
        label={t('workflow.library.layout')}
        value={layout}
        onChange={onLayout}
        options={[
          { value: 'board', label: t('workflow.library.board'), icon: 'board' },
          { value: 'table', label: t('workflow.library.table'), icon: 'list' },
        ]}
      />
    </div>
  )
}
