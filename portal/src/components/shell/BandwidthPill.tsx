import type { TFunction } from 'i18next'
import { useTranslation } from 'react-i18next'
import { capSummary, isLocked, type BandwidthState } from '../../lib/bandwidth'
import { Icon } from '../ui/Icon'
import type { MenuEntry } from '../ui/Menu'

interface BandwidthPillProps {
  state: BandwidthState
  canWrite: boolean
  /** A narrow bar: just the profile name, which "Profile: …" would truncate. */
  compact?: boolean
  menuOpen: boolean
  onOpen: (anchor: DOMRect) => void
}

/** The snail chip: "Profile: Medium ▾" while a limit is on, "Unlimited" while it is off. */
export function BandwidthPill({ state, canWrite, compact = false, menuOpen, onOpen }: BandwidthPillProps) {
  const { t } = useTranslation()
  const label = !state.enabled
    ? t('statusbar.unlimited')
    : compact
      ? state.selected
      : t('statusbar.profile', { name: state.selected })

  if (!canWrite) {
    return (
      <span className={`chip sm bw-pill ro${state.enabled ? ' lim' : ''}`}>
        <Icon name="snail" size="s" />
        {label}
      </span>
    )
  }

  return (
    <button
      type="button"
      className={`chip sm bw-pill${state.enabled ? ' lim' : ''}`}
      aria-haspopup="menu"
      aria-expanded={menuOpen}
      title={compact && state.enabled ? t('statusbar.profile', { name: state.selected }) : t('statusbar.bandwidthMenu')}
      onClick={(e) => onOpen(e.currentTarget.getBoundingClientRect())}
    >
      <Icon name="snail" size="s" />
      <span className="bw-l">{label}</span>
      <Icon name="chevronDown" size="s" />
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
