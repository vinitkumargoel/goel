import { useTranslation } from 'react-i18next'
import type { TFunction } from 'i18next'
import { capSummary, isLocked, type BandwidthState } from '../lib/bandwidth'
import type { MenuEntry } from './ContextMenu'
import { ChevronDownIcon } from './Icons'

interface BandwidthPillProps {
  state: BandwidthState
  canWrite: boolean
  menuOpen: boolean
  onOpen: (anchor: DOMRect) => void
}

/** "Profile: Medium ▾", or "Unlimited" while limits are off. Plain text for a read-only session. */
export function BandwidthPill({ state, canWrite, menuOpen, onOpen }: BandwidthPillProps) {
  const { t } = useTranslation()
  const label = state.enabled
    ? t('statusbar.profile', { name: state.selected })
    : t('statusbar.unlimited')

  if (!canWrite) return <span className="bw-pill ro">{label}</span>

  return (
    <button
      type="button"
      className={`bw-pill${state.enabled ? ' on' : ''}`}
      aria-haspopup="menu"
      aria-expanded={menuOpen}
      title={t('statusbar.bandwidthMenu')}
      onClick={(e) => onOpen(e.currentTarget.getBoundingClientRect())}
    >
      <span className="bw-l">{label}</span>
      <ChevronDownIcon aria-hidden="true" />
    </button>
  )
}

/** The pill's menu: one radio item per profile with its caps, then the Unlimited switch. */
export function bandwidthMenuEntries(
  state: BandwidthState,
  t: TFunction,
  onSelect: (name: string) => void,
  onUnlimited: () => void,
): MenuEntry[] {
  const noCap = t('settings.bandwidth.noCap')
  const managed = t('settings.bandwidth.managed')
  // Picking a profile also switches limits on, so it needs both fields free unless already on.
  const profileLocked = isLocked(state, 'selected') || (!state.enabled && isLocked(state, 'enabled'))
  const toggleLocked = isLocked(state, 'enabled')
  return [
    ...state.profiles.map(
      (p): MenuEntry => ({
        key: `p-${p.name}`,
        label: p.name,
        detail: profileLocked ? `${capSummary(p, noCap)} · ${managed}` : capSummary(p, noCap),
        checked: state.enabled && p.name === state.selected,
        disabled: profileLocked,
        action: () => onSelect(p.name),
      }),
    ),
    { separator: true },
    {
      key: 'unlimited',
      label: t('statusbar.unlimitedToggle'),
      detail: toggleLocked ? managed : undefined,
      checked: !state.enabled,
      disabled: toggleLocked,
      action: onUnlimited,
    },
  ]
}
