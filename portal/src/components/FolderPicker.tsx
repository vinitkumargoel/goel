import { useCallback, useEffect, useRef, useState } from 'react'
import { ApiError, api } from '../lib/api'
import type { FolderListing } from '../lib/types'
import { FolderIcon, FolderPlusIcon } from './Icons'

/**
 * Browses the server's filesystem so nobody has to type an absolute path into
 * the Add dialog.
 *
 * Web-only by design: the macOS app opens a real `NSOpenPanel`, which knows
 * about sandbox scope and mounted volumes in ways this cannot.
 *
 * The whole tree is server-supplied — `path`, `parent`, `places` and every
 * entry's `path` come back from `GET /api/folders`. Nothing here joins or trims
 * a path, and nothing here decides what is reachable: `readable` and `writable`
 * are the server's report of what its own user may do, and this only greys out
 * what it is told to. A permission guess made in JavaScript would be a guess
 * about someone else's filesystem.
 */

interface FolderPickerProps {
  /** Folder to open on first render; falls back to the default when unreachable. */
  initialPath: string
  /** Hidden in read-only sessions, where the server would refuse the POST. */
  canCreate: boolean
  /** The listing travels with the choice so the caller can shorten the path for
   *  display, and recognise "this is just the default", without a second request. */
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

  // `initialPath` is only the starting point; re-navigating must not be undone
  // by a re-render, so it is read once through a ref rather than in a dep list.
  const startRef = useRef(initialPath)
  // Out-of-order responses: a fast click on a deep folder while a slow parent
  // request is still open would otherwise land the user somewhere they left.
  const seqRef = useRef(0)

  // Held in a ref rather than a dependency. The callers above pass a fresh arrow
  // on every render, and the whole app re-renders on every SSE tick — so a
  // `useCallback([onWarn])` would give `load` a new identity roughly once a
  // second, and the mount effect below would yank the user back to the start
  // mid-browse.
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
        // A path that no longer exists, or that this user may not read, should
        // not strand the picker — fall back to the default folder, which the
        // server always has.
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

  // Escape belongs to the innermost thing that is open. Without the capture
  // phase it would reach the App-level handler and close the Add dialog too,
  // discarding a typed URL to dismiss a folder list.
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
        // Navigate into it: creating a folder here always means wanting to use
        // it, and the alternative is finding it again in a list that just grew.
        load(created.path)
      })
      .catch((e: unknown) => {
        // `api` has already toasted a 403. A 400 carries the server's sentence
        // about the name itself, which is the only thing the user can fix.
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
        // The Add dialog sits under this one and closes on its own backdrop
        // click. Without this the two would dismiss together.
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
            // Clicking navigates *into* a folder rather than selecting it, so
            // there is exactly one way to choose: "Use this folder" always means
            // the one named above the list. A row that both selects and drills in
            // makes "which folder am I about to save to" ambiguous.
            //
            // An unreadable folder stays visible but inert. Hiding it would be a
            // worse answer to "where did my folder go" than showing why.
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
            // Not writable means the download would fail at submit time with a
            // 403 the user could do nothing about. Refusing the choice here says
            // the same thing while it is still fixable.
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

/**
 * The path as the user thinks of it: "Home / Downloads / Linux" rather than
 * `/Users/someone/Downloads/Linux`. Callers keep the absolute one as a `title`,
 * because that is what a support conversation needs.
 *
 * `home` may be empty before the first listing arrives, in which case the
 * absolute path is shown — a long true path beats a short invented one.
 */
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
  // Outside home — a mounted volume, or a system path. There is no shorter
  // honest form, so show every component.
  return parts(path).join(' / ') || path
}
