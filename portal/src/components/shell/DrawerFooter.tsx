import { useTranslation } from 'react-i18next'
import type { Bandwidth } from '../../hooks/useBandwidth'
import { Icon } from '../ui/Icon'
import { BandwidthPill } from './BandwidthPill'

interface DrawerFooterProps {
  readOnly: boolean
  canWrite: boolean
  bandwidth: Bandwidth
  bandwidthMenuOpen: boolean
  onBandwidthMenu: (anchor: DOMRect) => void
  onPauseAll: () => void
  onResumeAll: () => void
}

/** On a phone the status bar's controls move into the filter drawer: pause/resume all and the speed pill. */
export function DrawerFooter({
  readOnly,
  canWrite,
  bandwidth,
  bandwidthMenuOpen,
  onBandwidthMenu,
  onPauseAll,
  onResumeAll,
}: DrawerFooterProps) {
  const { t } = useTranslation()
  return (
    <>
      {!readOnly && (
        <>
          <button type="button" className="btn sm" onClick={onPauseAll}>
            <Icon name="pause" />
            {t('statusbar.pauseAll')}
          </button>
          <button type="button" className="btn sm" onClick={onResumeAll}>
            <Icon name="play" />
            {t('statusbar.resumeAll')}
          </button>
        </>
      )}
      {bandwidth.status !== 'unsupported' && bandwidth.state && (
        <BandwidthPill
          state={bandwidth.state}
          canWrite={canWrite}
          menuOpen={bandwidthMenuOpen}
          onOpen={onBandwidthMenu}
        />
      )}
    </>
  )
}
