import { useCallback, useEffect, useRef, useState } from 'react'
import { ApiError, api } from '../lib/api'
import type { FolderListing } from '../lib/types'
import { FolderIcon, FolderPlusIcon } from './Icons'

interface FolderPickerProps {
  initialPath: string
  canCreate: boolean
  onPick: (path: string, listing: FolderListing) => void
  onClose: () => void
  onWarn: (message: string) => void
}

export function FolderPicker({
  initialPath,
  canCreate,
  onPick,
  onClose,
  onWarn,
}: FolderPickerProps) {
  const [listing, setListing] = useState<FolderListing | null>(null)
  const [loading, setLoading] = useState(true)
  const [failed, setFailed] = useState(false)
  const [naming, setNaming] = useState(false)
  const [newName, setNewName] = useState('')
  const nameRef = useRef<HTMLInputElement>(null)

  // Read once through a ref: as a dep, a re-render would undo the user's navigation.
  const startRef = useRef(initialPath)
  // Guards out-of-order responses: a slow parent request must not overwrite a newer child one.
  const seqRef = useRef(0)

  // Ref, not a dep: `onWarn` is a fresh arrow each SSE tick, which would re-fire the mount effect ~1x/s.
  const warnRef = useRef(onWarn)
  warnRef.current = onWarn

  const load = useCallback((path: string | undefined) => {
    const seq = ++seqRef.current
    setLoading(true)
    void api
      .folders(path)
      .then((next) => {
        if (seq !== seqRef.current) return
        setListing(next)
        setFailed(false)
        setLoading(false)
      })
      .catch((e: unknown) => {
        if (seq !== seqRef.current) return
        setLoading(false)
        if (path !== undefined) {
          load(undefined)
          warnRef.current(e instanceof Error ? e.message : 'Could not open that folder')
          return
        }
        setFailed(true)
        warnRef.current(e instanceof Error ? e.message : 'Could not list folders')
      })
  }, [])

  useEffect(() => {
    const start = startRef.current
    load(start.trim() ? start : undefined)
  }, [load])

  useEffect(() => {
    if (naming) nameRef.current?.focus()
  }, [naming])

  // Capture phase is required: otherwise Escape also reaches the App handler and closes the Add dialog.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== 'Escape') return
      e.stopPropagation()
      if (naming) setNaming(false)
      else onClose()
    }
    document.addEventListener('keydown', onKey, true)
    return () => document.removeEventListener('keydown', onKey, true)
  }, [naming, onClose])

  function create() {
    const name = newName.trim()
    if (!name) {
      warnRef.current('Name the folder first')
      return
    }
    const parent = listing?.path
    void api
      .createFolder(parent ? { name, parent } : { name })
      .then((created) => {
        setNaming(false)
        setNewName('')
        load(created.path)
      })
      .catch((e: unknown) => {
        // `api` already toasted 'refused'/'auth'; re-reporting them would double-toast.
        if (e instanceof ApiError && e.kind !== 'refused' && e.kind !== 'auth') {
          warnRef.current(e.message)
        }
      })
  }

  return (
    <div
      className="scrim open picker-scrim"
      onClick={(e) => {
        if (e.target !== e.currentTarget) return
        // The Add dialog under this one also closes on backdrop click; without this both dismiss.
        e.stopPropagation()
        onClose()
      }}
    >
      <div className="modal picker">
        <div className="mhead">
          <div className="mic">
            <FolderIcon />
          </div>
          <h3>Choose a folder</h3>
        </div>

        {listing && listing.places.length > 0 && (
          <div className="pkplaces">
            {listing.places.map((p) => (
              <button
                key={p.path}
                className={`pkplace${p.path === listing.path ? ' on' : ''}`}
                disabled={!p.readable}
                title={p.readable ? p.path : `${p.path} — no permission to open`}
                onClick={() => load(p.path)}
              >
                {p.name}
              </button>
            ))}
          </div>
        )}

        <div className="pkpath" title={listing?.path ?? ''}>
          {listing ? folderLabel(listing.path, listing.home) : '…'}
        </div>

        <div className="mbody pkbody">
          {failed && <p className="fhint">Could not read that folder.</p>}

          {listing?.parent && (
            <button className="pkrow up" onClick={() => load(listing.parent ?? undefined)}>
              <FolderIcon />
              <span>Up one level</span>
            </button>
          )}

          {listing?.folders.map((f) => (
            <button
              key={f.path}
              className={`pkrow${f.readable ? '' : ' locked'}`}
              disabled={!f.readable}
              title={f.readable ? f.path : `${f.path} — no permission to open`}
              onClick={() => load(f.path)}
            >
              <FolderIcon />
              <span className="ell">{f.name}</span>
              {!f.readable && <span className="pkno">no access</span>}
            </button>
          ))}

          {listing && listing.folders.length === 0 && !loading && (
            <p className="fhint">
              No subfolders here.{' '}
              {canCreate && listing.writable
                ? 'Use this folder, or make a new one.'
                : 'Use this folder.'}
            </p>
          )}

          {naming && (
            <div className="pknew">
              <input
                className="finput"
                ref={nameRef}
                value={newName}
                onChange={(e) => setNewName(e.target.value)}
                onKeyDown={(e) => {
                  if (e.key === 'Enter') create()
                }}
                placeholder="New folder name"
              />
              <button className="btn" onClick={create}>
                Create
              </button>
            </div>
          )}
        </div>

        <div className="mfoot">
          {canCreate && listing?.writable && !naming && (
            <button className="btn ghost" onClick={() => setNaming(true)}>
              <FolderPlusIcon /> New folder
            </button>
          )}
          <div className="sp" />
          <button className="btn" onClick={onClose}>
            Cancel
          </button>
          <button
            className="btn primary"
            disabled={!listing || !listing.writable}
            title={listing && !listing.writable ? 'No permission to write here' : undefined}
            onClick={() => listing && onPick(listing.path, listing)}
          >
            Use this folder
          </button>
        </div>
      </div>
    </div>
  )
}

export function folderLabel(path: string, home: string | null): string {
  if (path === '/') return 'Computer'
  const parts = (rest: string) => rest.split('/').filter(Boolean)
  if (home) {
    const base = home.replace(/\/+$/, '')
    if (path === base) return 'Home'
    if (path.startsWith(base + '/')) {
      return ['Home', ...parts(path.slice(base.length + 1))].join(' / ')
    }
  }
  return parts(path).join(' / ') || path
}
