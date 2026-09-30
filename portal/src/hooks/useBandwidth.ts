import { useCallback, useEffect, useRef, useState } from 'react'
import { api, ApiError, failureMessage } from '../lib/api'
import { isBandwidthState, type BandwidthState, type BandwidthUpdate } from '../lib/bandwidth'

export const BANDWIDTH_POLL_MS = 15_000

export type BandwidthStatus = 'loading' | 'ready' | 'unsupported' | 'error'

export interface Bandwidth {
  status: BandwidthStatus
  state: BandwidthState | null
  /**
   * Posts the change and adopts the server's echo. Resolves to null on success; on failure to the
   * message to show, or '' when the api layer already reported it (a 403 refusal, a 401 redirect).
   */
  update: (body: BandwidthUpdate) => Promise<string | null>
}

function visible(): boolean {
  return typeof document === 'undefined' || document.visibilityState !== 'hidden'
}

/**
 * The daemon's bandwidth profiles: fetched on mount, then every 15s while the tab is visible (the
 * event stream carries only tasks). A 404 — a daemon older than the feature — marks it
 * `unsupported`, and it stays hidden without polling again.
 */
export function useBandwidth(): Bandwidth {
  const [status, setStatus] = useState<BandwidthStatus>('loading')
  const [state, setState] = useState<BandwidthState | null>(null)
  const unsupported = useRef(false)
  /** Bumped by every write, so a poll that started before it can't overwrite the echo. */
  const epoch = useRef(0)

  const load = useCallback(async () => {
    if (unsupported.current) return
    const started = epoch.current
    try {
      const next: unknown = await api.bandwidth()
      if (epoch.current !== started) return
      if (!isBandwidthState(next)) {
        // Not the documented shape (e.g. an intermediary's page): retry on the next tick.
        setStatus((s) => (s === 'ready' ? s : 'error'))
        return
      }
      setState(next)
      setStatus('ready')
    } catch (e) {
      if (e instanceof ApiError && e.status === 404) {
        unsupported.current = true
        setStatus('unsupported')
        return
      }
      // Keep showing the last good state through a daemon restart; only a first failure shows.
      setStatus((s) => (s === 'ready' ? s : 'error'))
    }
  }, [])

  useEffect(() => {
    void load()
    const timer = setInterval(() => {
      if (visible()) void load()
    }, BANDWIDTH_POLL_MS)
    const onVisible = () => {
      if (visible()) void load()
    }
    document.addEventListener('visibilitychange', onVisible)
    return () => {
      clearInterval(timer)
      document.removeEventListener('visibilitychange', onVisible)
    }
  }, [load])

  const update = useCallback(async (body: BandwidthUpdate): Promise<string | null> => {
    epoch.current++
    try {
      const next: unknown = await api.updateBandwidth(body)
      // A poll that started while the write was in flight may carry pre-write state: void it.
      epoch.current++
      if (isBandwidthState(next)) {
        setState(next)
        setStatus('ready')
      }
      return null
    } catch (e) {
      // '' for a 403: the refusal handler has already toasted it.
      return failureMessage(e) ?? ''
    }
  }, [])

  return { status, state, update }
}
