import { fmtSize } from './format'

/** `GET/POST /api/bandwidth`. A null cap is unlimited. Mirror of the router's Encodable. */
export interface BandwidthProfile {
  name: string
  downBytesPerSec: number | null
  upBytesPerSec: number | null
}

/** Fields an MDM policy pins; the server 403s a POST that changes one. */
export type LockableField = 'enabled' | 'selected'

export interface BandwidthState {
  enabled: boolean
  selected: string
  profiles: BandwidthProfile[]
  /** Missing on a daemon that predates policy locks; treated as nothing locked. */
  locked?: LockableField[]
}

export function isLocked(state: BandwidthState, field: LockableField): boolean {
  return state.locked?.includes(field) ?? false
}

/** Every field optional: the server keeps what is left out (a missing cap key too; `null` = unlimited). */
export interface BandwidthUpdate {
  enabled?: boolean
  selected?: string
  profiles?: BandwidthProfile[]
}

export type RateUnit = 'KB' | 'MB'

export const UNIT_BYTES: Record<RateUnit, number> = { KB: 1024, MB: 1024 * 1024 }

/** "↓ 2.0 MB/s · ↑ 500 KB/s"; `noCap` stands in for an unlimited direction. */
export function capSummary(profile: BandwidthProfile, noCap: string): string {
  const one = (bytes: number | null) => (bytes == null ? noCap : `${fmtSize(bytes)}/s`)
  return `↓ ${one(profile.downBytesPerSec)} · ↑ ${one(profile.upBytesPerSec)}`
}

/** An editable form of a cap: the number the user sees and the unit it is in. Unlimited is ''. */
export interface CapField {
  value: string
  unit: RateUnit
}

/** MB/s when the cap is a whole-ish number of megabytes, KB/s otherwise. */
export function toField(bytes: number | null): CapField {
  if (bytes == null) return { value: '', unit: 'MB' }
  if (bytes >= UNIT_BYTES.MB) return { value: trim(bytes / UNIT_BYTES.MB), unit: 'MB' }
  return { value: trim(bytes / UNIT_BYTES.KB), unit: 'KB' }
}

function trim(n: number): string {
  return String(Math.round(n * 100) / 100)
}

/**
 * Bytes per second for a field: `null` (unlimited) when blank, `undefined` when it is not a
 * non-negative number — the caller refuses to save rather than guessing.
 */
export function fromField(field: CapField): number | null | undefined {
  const raw = field.value.trim()
  if (raw === '') return null
  const n = Number(raw)
  if (!isFinite(n) || n < 0) return undefined
  return Math.round(n * UNIT_BYTES[field.unit])
}

/** Narrows a parsed body; anything malformed is treated as "no bandwidth feature" by the caller. */
export function isBandwidthState(value: unknown): value is BandwidthState {
  if (typeof value !== 'object' || value === null) return false
  const v = value as Partial<BandwidthState>
  return (
    typeof v.enabled === 'boolean' &&
    typeof v.selected === 'string' &&
    (v.locked === undefined || (Array.isArray(v.locked) && v.locked.every((l) => typeof l === 'string'))) &&
    Array.isArray(v.profiles) &&
    v.profiles.every(
      (p) =>
        typeof p === 'object' &&
        p !== null &&
        typeof p.name === 'string' &&
        (p.downBytesPerSec === null || typeof p.downBytesPerSec === 'number') &&
        (p.upBytesPerSec === null || typeof p.upBytesPerSec === 'number'),
    )
  )
}
