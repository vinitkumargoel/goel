import { useCallback, useEffect, useRef, useState } from 'react'
import { ApiError, api } from '../lib/api'
import type { FolderListing } from '../lib/types'
import { FolderIcon, FolderPlusIcon } from './Icons'

/**
 * Browses the server's downloads folder so nobody has to type an absolute path
 * into the Add dialog.
 *
 * Web-only by design: the macOS app opens a real `NSOpenPanel`, which knows
 * about sandbox scope and mounted volumes in ways this cannot.
 *
 * The whole tree is server-supplied — `path`, `parent` and every entry's `path`
 * come back from `GET /api/folders`, which refuses anything outside the
 * downloads root. Nothing here joins or trims a path, so there is no second,
 * weaker copy of that boundary living in JavaScript.
 */

interface FolderPickerProps {
  /** Folder to open on first render; falls back to the root when unreachable. */
  initialPath: string
  /** Hidden in read-only sessions, where the server would refuse the POST. */
  canCreate: boolean
  /** `root` travels with the choice so the caller can shorten it for display
   *  without a second request just to learn where the root is. */
  onPick: (path: string, root: string) => void
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
  // second, and the mount effect below would yank the user back to the root
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
        // A path that no longer exists (the folder was deleted, or the downloads
        // root moved) should not strand the picker — fall back to the root,
        // which the server always has.
        if (path !== undefined) {
          load(undefined)
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

  const atRoot = listing !== null && listing.parent === null

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

        <div className="pkpath" title={listing?.path ?? ''}>
          {listing ? folderLabel(listing.path, listing.root) : '…'}
        </div>

        <div className="mbody pkbody">
          {failed && <p className="fhint">Could not read the downloads folder.</p>}

          {!atRoot && listing && (
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
            <button key={f.path} className="pkrow" onClick={() => load(f.path)}>
              <FolderIcon />
              <span className="ell">{f.name}</span>
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
            disabled={!listing}
            onClick={() => listing && onPick(listing.path, listing.root)}
          >
            Use this folder
          </button>
        </div>
      </div>
    </div>
  )
}

/**
 * The path as the user thinks of it: "Downloads / Linux / ISOs", not the
 * server's absolute path. Callers keep the absolute one as a `title`, because
 * that is what a support conversation needs.
 *
 * `root` may be null when it has not been fetched yet, in which case the
 * absolute path is shown — a long true path beats a short invented one.
 */
export function folderLabel(path: string, root: string | null): string {
  if (!root) return path
  const base = root.replace(/\/+$/, '')
  const baseName = base.split('/').filter(Boolean).pop() ?? base
  if (path === base) return baseName
  // A prefix mismatch means a symlinked or differently-spelled path that the
  // server nonetheless resolved inside the root. Show it as it is.
  if (!path.startsWith(base + '/')) return path
  const rest = path.slice(base.length + 1)
  return [baseName, ...rest.split('/').filter(Boolean)].join(' / ')
}
