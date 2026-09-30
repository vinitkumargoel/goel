import { useCallback } from 'react'
import { useTranslation } from 'react-i18next'
import { bandwidthMenuEntries } from '../components/BandwidthPill'
import type { MenuState } from '../components/ContextMenu'
import type { BandwidthUpdate } from '../lib/bandwidth'
import type { Bandwidth } from './useBandwidth'
import type { ToastTone } from './useToasts'

/** Builds the status-bar pill's menu, opening upward from the pill, and applies the pick. */
export function useBandwidthMenu(
  bandwidth: Bandwidth,
  openMenu: (menu: MenuState) => void,
  toast: (message: string, tone?: ToastTone) => void,
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
        entries: bandwidthMenuEntries(
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
      })
    },
    [state, openMenu, apply, t],
  )
}
