import { useEffect, useId, useState } from 'react'
import { useTranslation } from 'react-i18next'
import type { ToastTone } from '../../hooks/useToasts'
import { api, ApiError, failureMessage } from '../../lib/api'
import { isDirty, SIMULTANEOUS_RANGE, settingsDiff, settingsProblems } from '../../lib/serverSettings'
import type { ServerSettings } from '../../lib/types'
import { FolderPicker } from '../add/FolderPicker'
import { Seg, ToggleRow } from '../ui/Controls'
import { Icon } from '../ui/Icon'
import { DirtyStrip, SettingsCard } from './SettingsParts'

type Group = 'general' | 'bittorrent'
type Load = { status: 'loading' } | { status: 'unsupported' } | { status: 'error' } | { status: 'ready' }

interface Props {
  canWrite: boolean
  onToast: (message: string, tone?: ToastTone) => void
  /** Edits are waiting for Save in either card. */
  onDirty: (dirty: boolean) => void
}

/**
 * Settings › General and BitTorrent: the server's default folder, how many downloads run at once,
 * and the peer and privacy basics, as the desktop app's panes have them. Edits collect in a draft
 * per card and are validated twice, here and by the server, before Save writes only what changed.
 * A server without editable settings (404) shows nothing.
 */
export function ServerSettingsCards({ canWrite, onToast, onDirty }: Props) {
  const { t } = useTranslation()
  const id = useId()
  const [load, setLoad] = useState<Load>({ status: 'loading' })
  const [saved, setSaved] = useState<ServerSettings | null>(null)
  const [draft, setDraft] = useState<ServerSettings | null>(null)
  const [busy, setBusy] = useState(false)
  const [picking, setPicking] = useState(false)

  useEffect(() => {
    let live = true
    api
      .serverSettings()
      .then((s) => {
        if (!live) return
        setSaved(s)
        setDraft(s)
        setLoad({ status: 'ready' })
      })
      .catch((e: unknown) => {
        if (live) setLoad(e instanceof ApiError && e.status === 404 ? { status: 'unsupported' } : { status: 'error' })
      })
    return () => {
      live = false
    }
  }, [])

  const dirtyIn = (group: Group) =>
    saved != null && draft != null && isDirty(saved, { ...saved, [group]: draft[group] })
  const generalDirty = dirtyIn('general')
  const btDirty = dirtyIn('bittorrent')
  const anyDirty = generalDirty || btDirty
  useEffect(() => onDirty(anyDirty), [anyDirty, onDirty])

  if (load.status === 'loading' || load.status === 'unsupported') return null
  if (load.status === 'error' || !saved || !draft) {
    return (
      <SettingsCard title={t('settings.general.title')} icon="settings">
        <p className="srow small muted" role="alert">
          {t('api.actionFailed')}
        </p>
      </SettingsCard>
    )
  }

  const disabled = !canWrite || busy
  const problems = settingsProblems(draft)
  const editGeneral = (patch: Partial<ServerSettings['general']>) =>
    setDraft((d) => (d ? { ...d, general: { ...d.general, ...patch } } : d))
  const editBt = (patch: Partial<ServerSettings['bittorrent']>) =>
    setDraft((d) => (d ? { ...d, bittorrent: { ...d.bittorrent, ...patch } } : d))

  const save = async (group: Group) => {
    // Only this card's changes: the other card's pending edits stay in its own strip.
    const update = settingsDiff(saved, { ...saved, [group]: draft[group] })
    setBusy(true)
    try {
      const next = await api.updateServerSettings(update)
      setSaved(next)
      // Adopt the echo for the saved card; keep the other card's draft as it was.
      setDraft((d) => (d ? { ...d, [group]: next[group] } : next))
      setSaved((s) => (s ? { ...s, [group]: next[group] } : next))
      onToast(t('settings.saved'))
    } catch (e) {
      const message = failureMessage(e)
      if (message) onToast(message, 'warn')
    } finally {
      setBusy(false)
    }
  }
  const discard = (group: Group) => setDraft((d) => (d ? { ...d, [group]: saved[group] } : d))

  const g = draft.general
  const b = draft.bittorrent
  return (
    <>
      <SettingsCard title={t('settings.general.title')} icon="settings">
        <div className="srow set-col">
          <div className="row">
            <div className="sl">
              <b id={`${id}-folder`}>{t('settings.general.folder')}</b>
              <span>{t('settings.general.folderDesc')}</span>
            </div>
            {canWrite && (
              <button type="button" className="btn sm" disabled={busy} onClick={() => setPicking(true)}>
                <Icon name="folder" size="s" />
                {t('settings.general.choose')}
              </button>
            )}
          </div>
          <label className="field sm">
            <input
              className="mono"
              value={g.defaultSaveDirectory}
              disabled={disabled}
              aria-labelledby={`${id}-folder`}
              aria-invalid={problems.includes('folder')}
              spellCheck={false}
              onChange={(e) => editGeneral({ defaultSaveDirectory: e.target.value })}
            />
          </label>
          {problems.includes('folder') && (
            <p className="help bad" role="alert">
              {t('settings.general.folderInvalid')}
            </p>
          )}
        </div>

        <div className="srow">
          <div className="sl">
            <b id={`${id}-rule`}>{t('settings.general.rule')}</b>
            <span>{t('settings.general.ruleDesc')}</span>
          </div>
          <Seg
            size="sm"
            className="set-wrap"
            label={t('settings.general.rule')}
            value={g.defaultFolderRule}
            options={(['automatic', 'byType', 'bySource', 'fixed'] as const).map((value) => ({
              value,
              label: t(`settings.general.rules.${value}`),
              disabled,
            }))}
            onChange={(defaultFolderRule) => editGeneral({ defaultFolderRule })}
          />
        </div>

        <div className="srow">
          <div className="sl">
            <b id={`${id}-exists`}>{t('settings.general.exists')}</b>
            <span>{t('settings.general.existsDesc')}</span>
          </div>
          <Seg
            size="sm"
            label={t('settings.general.exists')}
            value={g.existingFileReaction}
            options={(['rename', 'overwrite'] as const).map((value) => ({
              value,
              label: t(`settings.general.reactions.${value}`),
              disabled,
            }))}
            onChange={(existingFileReaction) => editGeneral({ existingFileReaction })}
          />
        </div>

        <div className="srow">
          <div className="sl">
            <b id={`${id}-max`}>{t('settings.general.simultaneous')}</b>
            <span>{t('settings.general.simultaneousDesc', { profile: g.profile })}</span>
            {problems.includes('simultaneous') && (
              <span className="bad" role="alert">
                {t('settings.general.simultaneousInvalid', SIMULTANEOUS_RANGE)}
              </span>
            )}
          </div>
          <span className="field sm">
            <input
              type="number"
              inputMode="numeric"
              min={SIMULTANEOUS_RANGE.min}
              max={SIMULTANEOUS_RANGE.max}
              value={Number.isNaN(g.maxSimultaneousDownloads) ? '' : g.maxSimultaneousDownloads}
              disabled={disabled}
              aria-labelledby={`${id}-max`}
              aria-invalid={problems.includes('simultaneous')}
              onChange={(e) => editGeneral({ maxSimultaneousDownloads: e.target.value === '' ? NaN : Number(e.target.value) })}
            />
          </span>
        </div>

        {canWrite && (
          <DirtyStrip
            dirty={generalDirty}
            busy={busy}
            saveDisabled={problems.length > 0}
            onDiscard={() => discard('general')}
            onSave={() => void save('general')}
          />
        )}
      </SettingsCard>

      <SettingsCard title={t('settings.bt.title')} icon="magnet">
        <div className="srow">
          <div className="sl">
            <b>{t('settings.bt.encryption')}</b>
            <span>{t('settings.bt.encryptionDesc')}</span>
          </div>
          <Seg
            size="sm"
            label={t('settings.bt.encryption')}
            value={b.encryptionMode}
            options={(['prefer', 'require', 'disable'] as const).map((value) => ({
              value,
              label: t(`settings.bt.modes.${value}`),
              disabled,
            }))}
            onChange={(encryptionMode) => editBt({ encryptionMode })}
          />
        </div>
        <ToggleRow id={`${id}-dht`} title={t('settings.bt.dht')} detail={t('settings.bt.dhtDesc')} checked={b.dht} disabled={disabled} onChange={(dht) => editBt({ dht })} />
        <ToggleRow id={`${id}-pex`} title={t('settings.bt.pex')} detail={t('settings.bt.pexDesc')} checked={b.pex} disabled={disabled} onChange={(pex) => editBt({ pex })} />
        <ToggleRow id={`${id}-lpd`} title={t('settings.bt.lpd')} detail={t('settings.bt.lpdDesc')} checked={b.lpd} disabled={disabled} onChange={(lpd) => editBt({ lpd })} />
        <ToggleRow id={`${id}-utp`} title={t('settings.bt.utp')} detail={t('settings.bt.utpDesc')} checked={b.utp} disabled={disabled} onChange={(utp) => editBt({ utp })} />
        <ToggleRow
          id={`${id}-del`}
          title={t('settings.bt.autoDelete')}
          detail={t('settings.bt.autoDeleteDesc')}
          checked={b.autoDeleteTorrent}
          disabled={disabled}
          onChange={(autoDeleteTorrent) => editBt({ autoDeleteTorrent })}
        />
        {canWrite && (
          <DirtyStrip dirty={btDirty} busy={busy} onDiscard={() => discard('bittorrent')} onSave={() => void save('bittorrent')} />
        )}
      </SettingsCard>

      {picking && (
        <FolderPicker
          initialPath={g.defaultSaveDirectory}
          canCreate={canWrite}
          onWarn={(m) => onToast(m, 'warn')}
          onClose={() => setPicking(false)}
          onPick={(path) => {
            setPicking(false)
            editGeneral({ defaultSaveDirectory: path })
          }}
        />
      )}
    </>
  )
}
