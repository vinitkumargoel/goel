import { useMemo } from 'react'
import { useTranslation } from 'react-i18next'
import type { RouteView as View } from '../lib/route'
import { TYPE_FILTERS, type Filter } from '../lib/filters'
import type { GroupBy } from '../lib/grouping'
import type { Density, LibraryLayout } from '../lib/libraryPrefs'
import type { PaletteCommand } from '../lib/palette'
import { FILTER_KEYS } from '../lib/shortcuts'
import { THEME_CHOICES, type ThemeChoice } from '../lib/theme'
import type { TaskRow } from '../lib/types'

export interface PaletteDeps {
  tasks: readonly TaskRow[]
  canWrite: boolean
  openAdd: () => void
  /** Shows a download: the library, unfiltered if need be, with it selected and in view. */
  showTask: (id: string) => void
  goToFilter: (filter: Filter) => void
  goToView: (view: View) => void
  togglePanel: () => void
  openHelp: () => void
  pauseAll: () => void
  resumeAll: () => void
  retryFailed: () => void
  setTheme: (theme: ThemeChoice) => void
  setGroup: (group: GroupBy) => void
  setDensity: (density: Density) => void
  setLayout: (layout: LibraryLayout) => void
}

const STATUS_FILTERS = ['active', 'queued', 'paused', 'completed', 'seeding', 'failed'] as const

/** Every command the ⌘K palette offers, rebuilt when the tasks or the handlers change. */
export function usePaletteCommands(d: PaletteDeps): PaletteCommand[] {
  const { t } = useTranslation()
  return useMemo(() => {
    const digit = (f: Filter) => {
      const at = FILTER_KEYS.indexOf(f)
      return at >= 0 ? [String(at + 1)] : undefined
    }
    const list: PaletteCommand[] = []
    if (d.canWrite) {
      list.push({ id: 'add', group: 'add', label: t('topbar.addDownload'), keys: ['N'], run: d.openAdd })
    }
    for (const task of d.tasks) {
      list.push({ id: `task:${task.id}`, group: 'downloads', label: task.name, run: () => d.showTask(task.id) })
    }
    list.push(
      { id: 'all', group: 'view', label: t('sidebar.allDownloads'), keys: digit('all'), run: () => d.goToFilter('all') },
      ...STATUS_FILTERS.map(
        (f): PaletteCommand => ({
          id: `f:${f}`,
          group: 'view',
          label: t('workflow.palette.show', { what: t(`status.${f}`) }),
          keys: digit(f),
          run: () => d.goToFilter(f),
        }),
      ),
      ...TYPE_FILTERS.map(
        (f): PaletteCommand => ({
          id: `f:${f}`,
          group: 'view',
          label: t('workflow.palette.show', { what: t(`fileType.${f}`) }),
          keys: digit(f),
          run: () => d.goToFilter(f),
        }),
      ),
      { id: 'history', group: 'view', label: t('workflow.palette.history'), keys: ['G', 'H'], run: () => d.goToView('history') },
      { id: 'settings', group: 'view', label: t('workflow.palette.settings'), keys: ['G', 'S'], run: () => d.goToView('settings') },
      { id: 'panel', group: 'view', label: t('workflow.palette.panel'), run: d.togglePanel },
      { id: 'help', group: 'view', label: t('shortcuts.title'), keys: ['?'], run: d.openHelp },
    )
    if (d.canWrite) {
      list.push(
        { id: 'pauseAll', group: 'actions', label: t('workflow.palette.pauseAll'), run: d.pauseAll },
        { id: 'resumeAll', group: 'actions', label: t('workflow.palette.resumeAll'), run: d.resumeAll },
        { id: 'retryFailed', group: 'actions', label: t('workflow.palette.retryFailed'), run: d.retryFailed },
      )
    }
    for (const theme of THEME_CHOICES) {
      const name = t(`settings.theme.${theme}`)
      list.push({
        id: `theme:${theme}`,
        group: 'settings',
        label: t('workflow.palette.theme', { name }),
        keywords: 'appearance colour color dark light',
        run: () => d.setTheme(theme),
      })
    }
    const groups: GroupBy[] = ['none', 'status', 'added', 'host']
    for (const g of groups) {
      list.push({
        id: `group:${g}`,
        group: 'settings',
        label: t('workflow.palette.groupBy', { what: t(`workflow.library.group.${g}`) }),
        run: () => d.setGroup(g),
      })
    }
    list.push(
      { id: 'density:compact', group: 'settings', label: t('workflow.palette.density', { what: t('workflow.library.compact') }), run: () => d.setDensity('compact') },
      { id: 'density:comfortable', group: 'settings', label: t('workflow.palette.density', { what: t('workflow.library.comfortable') }), run: () => d.setDensity('comfortable') },
      { id: 'layout:board', group: 'settings', label: t('workflow.palette.layout', { what: t('workflow.library.board') }), run: () => d.setLayout('board') },
      { id: 'layout:table', group: 'settings', label: t('workflow.palette.layout', { what: t('workflow.library.table') }), run: () => d.setLayout('table') },
    )
    return list
  }, [d, t])
}
