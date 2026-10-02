import { useEffect, useId, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { api } from '../../lib/api'
import type { NetworkAdapter, NetworkState } from '../../lib/types'
import { Icon } from '../ui/Icon'
import { AdapterLine } from './AdapterLine'

export type NetMode = 'auto' | 'split' | 'single'

export interface AddNetwork {
  net: NetworkState | null
  eligible: NetworkAdapter[]
  /** Two or more usable interfaces: only then is there a choice to offer. */
  show: boolean
  mode: NetMode
  setMode: (mode: NetMode) => void
  chosen: string[]
  setChosen: (update: (chosen: string[]) => string[]) => void
  single: string
  setSingle: (name: string) => void
  /** The `network` spec to send; null when a split has no interface ticked. */
  spec: () => string | null
}

/** The server's interfaces (`/api/network`) and which of them this add should use. */
export function useAddNetwork(): AddNetwork {
  const [net, setNet] = useState<NetworkState | null>(null)
  const [mode, setMode] = useState<NetMode>('auto')
  const [chosen, setChosen] = useState<string[]>([])
  const [single, setSingle] = useState('')

  useEffect(() => {
    let cancelled = false
    void api
      .network()
      .then((n) => {
        if (cancelled) return
        setNet(n)
        const eligible = n.adapters.filter((a) => a.eligible)
        setChosen(eligible.map((a) => a.name))
        setSingle(eligible[0]?.name ?? '')
      })
      .catch(() => {
        // Swallowed on purpose: without the choice the add still goes out on the server's default route.
      })
    return () => {
      cancelled = true
    }
  }, [])

  const eligible = net?.adapters.filter((a) => a.eligible) ?? []
  const show = eligible.length >= 2

  const spec = (): string | null => {
    if (!show) return 'auto'
    if (mode === 'single') return single ? `single:${single}` : 'auto'
    if (mode !== 'split') return 'auto'
    if (chosen.length === 0) return null
    if (chosen.length === 1) return `single:${chosen[0]}`
    return chosen.length === eligible.length ? 'aggregate' : `aggregate:${chosen.join(',')}`
  }

  return { net, eligible, show, mode, setMode, chosen, setChosen, single, setSingle, spec }
}

/** Automatic, split across several interfaces, or all through one. */
export function NetworkChoice({ network }: { network: AddNetwork }) {
  const { t } = useTranslation()
  const id = useId()
  const { net, eligible, mode, chosen, single } = network
  if (!network.show || !net) return null
  return (
    <div className="col add-opt add-net">
      <label className="lbl" htmlFor={`${id}-mode`}>
        {t('addDialog.network')}
      </label>
      <div className="field select">
        <select id={`${id}-mode`} value={mode} onChange={(e) => network.setMode(e.target.value as NetMode)}>
          <option value="auto">{net.aggregation ? t('addDialog.modeAutoSplit') : t('addDialog.modeAutoDefault')}</option>
          <option value="split">{t('addDialog.modeSplit')}</option>
          <option value="single">{t('addDialog.modeSingle')}</option>
        </select>
        <Icon name="chevronDown" size="s" />
      </div>

      {mode === 'split' && (
        <div className="col add-adapters" role="group" aria-label={t('addDialog.modeSplit')}>
          {eligible.map((a) => (
            <label key={a.name} className="add-adapter small">
              <input
                type="checkbox"
                className="check"
                checked={chosen.includes(a.name)}
                onChange={(e) => {
                  const on = e.target.checked
                  network.setChosen((c) => (on ? [...c, a.name] : c.filter((n) => n !== a.name)))
                }}
              />
              <AdapterLine adapter={a} />
            </label>
          ))}
        </div>
      )}

      {mode === 'single' && (
        <div className="field select">
          <select aria-label={t('addDialog.modeSingle')} value={single} onChange={(e) => network.setSingle(e.target.value)}>
            {eligible.map((a) => (
              <option key={a.name} value={a.name}>
                {a.label}
                {a.ipv4 ? ` — ${a.ipv4}` : ''}
              </option>
            ))}
          </select>
          <Icon name="chevronDown" size="s" />
        </div>
      )}

      <span className="help">{t('addDialog.splitHint', { count: eligible.length })}</span>
    </div>
  )
}
