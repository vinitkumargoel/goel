import { useCallback, useEffect, useId, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import i18n from '../../i18n'
import { ApiError, api } from '../../lib/api'
import type { FolderListing } from '../../lib/types'
import { Art } from '../ui/Art'
import { Icon } from '../ui/Icon'
import { Modal } from '../ui/Modal'

interface FolderPickerProps {
  initialPath: string
  canCreate: boolean
  onPick: (path: string, listing: FolderListing) => void
  onClose: () => void
  onWarn: (message: string) => void
}

/**
 * The server's folders, one level at a time, stacked over the Add dialog. What can be opened and
 * written is exactly what the server says (`readable`, `writable`); nothing is inferred here.
 */
export function FolderPicker({ initialPath, canCreate, onPick, onClose, onWarn }: FolderPickerProps) {
  const { t } = useTranslation()
  const [listing, setListing] = useState<FolderListing | null>(null)
  const [loading, setLoading] = useState(true)
  const [failed, setFailed] = useState(false)
  const [naming, setNaming] = useState(false)
  const [newName, setNewName] = useState('')
  const nameRef = useRef<HTMLInputElement>(null)
  const titleId = useId()

  // Read once through a ref: as a dep, a re-render would undo the user's navigation.
  const startRef = useRef(initialPath)
  // Guards out-of-order responses: a slow parent request must not overwrite a newer child one.
  const seqRef = useRef(0)
  // Ref, not a dep: `onWarn` is a fresh arrow each SSE tick, which would re-fire the mount effect.
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
        // `i18n.t`, not the hook's `t`: as a dep it would rebuild this callback and re-fire the mount effect.
        if (path !== undefined) {
          // A path that has gone or can't be read: fall back to the default folder.
          load(undefined)
          warnRef.current(e instanceof Error ? e.message : i18n.t('folderPicker.openError'))
          return
        }
        setFailed(true)
        warnRef.current(e instanceof Error ? e.message : i18n.t('folderPicker.listError'))
      })
  }, [])

  useEffect(() => {
    const start = startRef.current
    load(start.trim() ? start : undefined)
  }, [load])

  useEffect(() => {
    if (naming) nameRef.current?.focus()
  }, [naming])

  function create() {
    const name = newName.trim()
    if (!name) {
      warnRef.current(t('folderPicker.nameFirst'))
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
        // `api` already toasted 'refused' and 'auth'; reporting them again would double-toast.
        if (e instanceof ApiError && e.kind !== 'refused' && e.kind !== 'auth') warnRef.current(e.message)
      })
  }

  const canMake = canCreate && listing?.writable === true

  return (
    <Modal
      labelledBy={titleId}
      // Escape first leaves the new-folder field, then the picker; never the Add dialog below.
      onClose={() => (naming ? setNaming(false) : onClose())}
      width={500}
      className="fp"
    >
      <div className="sheet-h">
        <Icon name="folder" size="l" className="acc" />
        <h2 className="h2" id={titleId}>
          {t('folderPicker.title')}
        </h2>
      </div>

      {listing && listing.places.length > 0 && (
        <div className="fp-places" role="group" aria-label={t('adding.places')}>
          {listing.places.map((p) => (
            <button
              key={p.path}
              type="button"
              className={`chip${p.path === listing.path ? ' on' : ''}`}
              aria-pressed={p.path === listing.path}
              disabled={!p.readable}
              title={p.readable ? p.path : t('folderPicker.noPermission', { path: p.path })}
              onClick={() => load(p.path)}
            >
              {p.name}
            </button>
          ))}
        </div>
      )}

      <div className="fp-path">
        <button
          type="button"
          className="ibtn sm"
          disabled={!listing?.parent}
          aria-label={t('folderPicker.upOneLevel')}
          title={t('folderPicker.upOneLevel')}
          onClick={() => listing?.parent && load(listing.parent)}
        >
          <Icon name="chevronLeft" size="s" />
        </button>
        <span className="ell small fp-where" title={listing?.path ?? ''}>
          {listing ? folderLabel(listing.path, listing.home) : '…'}
        </span>
        {loading && <span className="tiny faint">{t('common.loading')}</span>}
      </div>

      <div className="sheet-b fp-body" aria-busy={loading}>
        {failed && (
          <p className="note bad">
            <Icon name="alert" />
            <span>{t('folderPicker.readError')}</span>
          </p>
        )}

        {listing?.parent && (
          <button type="button" className="fp-row" onClick={() => load(listing.parent ?? undefined)}>
            <Art kind="ghost" size="xs" glyph="chevronUp" />
            <span className="ell">{t('folderPicker.upOneLevel')}</span>
          </button>
        )}

        {listing?.folders.map((f) => (
          <button
            key={f.path}
            type="button"
            className="fp-row"
            disabled={!f.readable}
            title={f.readable ? f.path : t('folderPicker.noPermission', { path: f.path })}
            onClick={() => load(f.path)}
          >
            <Art kind="dir" size="xs" faded={!f.readable} />
            <span className="ell">{f.name}</span>
            {f.readable ? (
              <Icon name="chevronRight" size="s" className="faint" />
            ) : (
              <span className="tag">{t('folderPicker.noAccess')}</span>
            )}
          </button>
        ))}

        {listing && listing.folders.length === 0 && !loading && (
          <p className="help fp-empty">
            {t('folderPicker.noSubfolders')}{' '}
            {canMake ? t('folderPicker.useOrCreate') : t('folderPicker.useThis')}
          </p>
        )}

        {naming && (
          <div className="fp-new">
            <div className="field">
              <input
                ref={nameRef}
                value={newName}
                aria-label={t('folderPicker.newFolderPlaceholder')}
                placeholder={t('folderPicker.newFolderPlaceholder')}
                onChange={(e) => setNewName(e.target.value)}
                onKeyDown={(e) => {
                  if (e.key === 'Enter') create()
                }}
              />
            </div>
            <button type="button" className="btn soft" onClick={create}>
              {t('common.create')}
            </button>
          </div>
        )}
      </div>

      <div className="sheet-f">
        {canMake && !naming && (
          <button type="button" className="btn ghost" onClick={() => setNaming(true)}>
            <Icon name="folderPlus" />
            {t('folderPicker.newFolder')}
          </button>
        )}
        <span className="sp" />
        <button type="button" className="btn" onClick={onClose}>
          {t('common.cancel')}
        </button>
        <button
          type="button"
          className="btn pri"
          disabled={!listing || !listing.writable}
          title={listing && !listing.writable ? t('folderPicker.noWritePermission') : undefined}
          onClick={() => listing && onPick(listing.path, listing)}
        >
          {t('folderPicker.usePick')}
        </button>
      </div>
    </Modal>
  )
}

/** Plain function, called outside React too — reads the shared instance rather than a hook. */
export function folderLabel(path: string, home: string | null): string {
  if (path === '/') return i18n.t('folderPicker.computer')
  const parts = (rest: string) => rest.split('/').filter(Boolean)
  if (home) {
    const base = home.replace(/\/+$/, '')
    const homeLabel = i18n.t('folderPicker.home')
    if (path === base) return homeLabel
    if (path.startsWith(base + '/')) return [homeLabel, ...parts(path.slice(base.length + 1))].join(' / ')
  }
  return parts(path).join(' / ') || path
}
