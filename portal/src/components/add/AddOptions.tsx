import { useId } from 'react'
import { useTranslation } from 'react-i18next'
import type { AddPriority } from '../../lib/addPrefs'
import { Seg } from '../ui/Controls'
import { Icon } from '../ui/Icon'
import { shortFolder } from './addHelpers'
import { folderLabel } from './FolderPicker'

interface AddOptionsProps {
  /** Blank: the server's default folder. */
  folder: string
  /** The server's home, once the picker has told us; folders then read "Home / …". */
  home: string | null
  recent: readonly string[]
  onFolder: (folder: string) => void
  onBrowse: () => void
  priority: AddPriority
  onPriority: (p: AddPriority) => void
  paused: boolean
  onPaused: (paused: boolean) => void
}

/** The choices most adds touch: where it lands, how urgent it is, and whether it starts. */
export function AddOptions(props: AddOptionsProps) {
  const { folder, home, onFolder, priority, paused } = props
  const { t } = useTranslation()
  const id = useId()
  const recent = props.recent.filter((f) => f !== folder)
  return (
    <div className="add-grid">
      <div className="col add-opt add-folder">
        <span className="lbl" id={`${id}-folder`}>
          {t('addDialog.saveTo')} <span className="pill nodot add-server">{t('addDialog.serverFolder')}</span>
        </span>
        {/* Read-only on purpose: a typed absolute path is refused only after the request is composed. */}
        <div className="field add-folder-field" role="group" aria-labelledby={`${id}-folder`}>
          <Icon name="folder" size="s" className="acc" />
          <span className={`ell add-folder-val${folder ? '' : ' faint'}`} title={folder || undefined}>
            {folder ? folderLabel(folder, home) : t('addDialog.defaultFolder')}
          </span>
          {folder && (
            <button
              type="button"
              className="ibtn sm"
              onClick={() => onFolder('')}
              title={t('addDialog.useDefaultFolder')}
              aria-label={t('addDialog.useDefaultFolder')}
            >
              <Icon name="x" size="s" />
            </button>
          )}
          <button type="button" className="btn sm soft" onClick={props.onBrowse}>
            {t('addDialog.browse')}
          </button>
        </div>
        {recent.length > 0 && (
          <div className="add-recent" role="group" aria-label={t('workflow.add.recentFolders')}>
            <span className="tiny faint" aria-hidden="true">
              {t('workflow.add.recent')}
            </span>
            {recent.map((f) => (
              <button key={f} type="button" className="chip sm" title={f} onClick={() => onFolder(f)}>
                {home ? folderLabel(f, home) : shortFolder(f)}
              </button>
            ))}
          </div>
        )}
      </div>
      <div className="col add-opt">
        <span className="lbl" aria-hidden="true">
          {t('addDialog.priority')}
        </span>
        <Seg<AddPriority>
          value={priority}
          label={t('addDialog.priority')}
          onChange={props.onPriority}
          full
          options={[
            { value: 'high', label: t('task.priority.high') },
            { value: 'normal', label: t('task.priority.normal') },
            { value: 'low', label: t('task.priority.low') },
          ]}
        />
      </div>
      <div className="col add-opt">
        <span className="lbl" aria-hidden="true">
          {t('adding.whenAdded')}
        </span>
        <Seg<'now' | 'paused'>
          value={paused ? 'paused' : 'now'}
          label={t('adding.whenAdded')}
          onChange={(v) => props.onPaused(v === 'paused')}
          full
          options={[
            { value: 'now', label: t('adding.startNow'), icon: 'play' },
            { value: 'paused', label: t('adding.paused'), icon: 'pause' },
          ]}
        />
      </div>
    </div>
  )
}
