import { useTranslation } from 'react-i18next'
import type { TaskGroup } from '../lib/grouping'

/** A section's sticky header: what the rows share, and how many there are. */
export function GroupHeader({ id, group }: { id: string; group: TaskGroup }) {
  const { t } = useTranslation()
  const label =
    group.by === 'status'
      ? t(`workflow.group.status.${group.key}`, { defaultValue: group.key })
      : group.by === 'added'
        ? t(`history.groups.${group.key}`, { defaultValue: group.key })
        : group.key || t('workflow.group.noHost')
  return (
    <div className="ghead" id={id}>
      <span className="glabel">{label}</span>
      <span className="gcount">{group.tasks.length}</span>
    </div>
  )
}
