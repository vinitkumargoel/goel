import { useCallback } from 'react'
import { useTranslation } from 'react-i18next'
import { bandwidthMenuEntries } from '../components/shell/BandwidthPill'
import type { TFunction } from 'i18next'
import type { MenuEntry, MenuState } from '../components/ui/Menu'
import type { QueueEdit } from '../components/dialogs/QueueDialogs'
import { isLocked, type BandwidthState, type BandwidthUpdate } from '../lib/bandwidth'
import type { Bandwidth } from './useBandwidth'
import type { ToastTone } from './useToasts'

/** Builds the status-bar pill's menu, opening upward from the pill, and applies the pick. */
export function useBandwidthMenu(
  bandwidth: Bandwidth,
  openMenu: (menu: MenuState) => void,
  toast: (message: string, tone?: ToastTone) => void,
  /** "Custom…": opens the two-field editor for the active profile's caps. */
  onCustom?: (edit: QueueEdit) => void,
) {
  const { t } = useTranslation()
  const { state, update } = bandwidth

  const apply = useCallback(
    async (body: BandwidthUpdate, done: string) => {
      const error = await update(body)
      if (error === null) toast(done)
      else if (error) toast(error, 'warn')
    },
    [update, toast],
  )

  return useCallback(
    (anchor: DOMRect) => {
      if (!state) return
      openMenu({
        x: anchor.left,
        y: anchor.top - 6,
        above: true,
        label: t('statusbar.bandwidthMenu'),
        entries: [
          ...bandwidthMenuEntries(
            state,
            t,
            (name) => void apply({ enabled: true, selected: name }, t('statusbar.bandwidthSet', { name })),
            () =>
              void apply(
                { enabled: !state.enabled },
                state.enabled
                  ? t('statusbar.bandwidthOff')
                  : t('statusbar.bandwidthSet', { name: state.selected }),
              ),
          ),
          ...customEntry(state, t, onCustom, (down, up) =>
            void apply(
              {
                enabled: true,
                selected: state.selected,
                profiles: [{ name: state.selected, downBytesPerSec: down, upBytesPerSec: up }],
              },
              t('queue.capSet', { name: state.selected }),
            ),
          ),
        ],
      })
    },
    [state, openMenu, apply, t, onCustom],
  )
}

/** Custom caps edit the selected profile in place — the server has no anonymous "custom" slot. */
function customEntry(
  state: BandwidthState,
  t: TFunction,
  onCustom: ((edit: QueueEdit) => void) | undefined,
  save: (down: number | null, up: number | null) => void,
): MenuEntry[] {
  if (!onCustom || isLocked(state, 'selected') || isLocked(state, 'enabled')) return []
  const profile = state.profiles.find((p) => p.name === state.selected)
  if (!profile) return []
  return [
    {
      key: 'custom',
      label: t('queue.capMenu'),
      detail: t('queue.capMenuDetail', { name: profile.name }),
      action: () =>
        onCustom({ kind: 'cap', down: profile.downBytesPerSec, up: profile.upBytesPerSec, onSave: save }),
    },
  ]
}
