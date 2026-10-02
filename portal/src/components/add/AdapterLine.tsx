import { useTranslation } from 'react-i18next'
import type { NetworkAdapter } from '../../lib/types'

/** An interface as a pickable line: its name, its address, and whether it is metered. */
export function AdapterLine({ adapter }: { adapter: NetworkAdapter }) {
  const { t } = useTranslation()
  return (
    <span className="adapter-line">
      <span className="ell">{adapter.label}</span>
      <span className="mono faint small">{adapter.ipv4 ?? t('adapter.noAddress')}</span>
      {adapter.expensive && <span className="pill warn nodot">{t('adapter.metered')}</span>}
    </span>
  )
}
