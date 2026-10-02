import { useId, type RefObject } from 'react'
import { useMediaQuery } from '../../hooks/useMediaQuery'
import { PHONE_QUERY } from '../../lib/breakpoints'
import { useTranslation } from 'react-i18next'
import { summarizeLinks } from '../../lib/links'
import { formatToken, joinSearch, splitSearch, type SearchToken } from '../../lib/search'
import { fileType, kindBadge, type FileType } from '../../lib/taskKind'
import type { TaskKind } from '../../lib/types'
import { Art } from '../ui/Art'
import { Icon } from '../ui/Icon'

/**
 * The finished `is:` / `host:` / `type:` tokens of a search, as removable chips before the field.
 * `value` is the whole search; the input shows `rest` and passes edits to `onRest`.
 */
export function useSearchChips(value: string, onChange: (value: string) => void) {
  const { chips, rest } = splitSearch(value)
  const onRest = (next: string) => onChange(joinSearch(chips, next))
  const remove = (index: number) => onChange(joinSearch(chips.filter((_, i) => i !== index), rest))
  /** Backspace in an empty field takes the last chip back into the text, to edit. */
  const onBackspace = (caretAtStart: boolean) => {
    if (!caretAtStart || chips.length === 0) return false
    const last = chips[chips.length - 1]!
    onChange(joinSearch(chips.slice(0, -1), formatToken(last) + rest))
    return true
  }
  return { chips, rest, onRest, remove, onBackspace }
}

function SearchChips({ chips, onRemove }: { chips: readonly SearchToken[]; onRemove: (index: number) => void }) {
  const { t } = useTranslation()
  if (chips.length === 0) return null
  return (
    <span className="schips">
      {chips.map((chip, i) => (
        <span key={`${i}:${formatToken(chip)}`} className="schip">
          <span className="schip-k">{chip.key}:</span>
          {chip.value}
          <button
            type="button"
            className="schip-x"
            aria-label={t('workflow.search.removeToken', { token: formatToken(chip) })}
            onClick={() => onRemove(i)}
          >
            <Icon name="x" size="s" />
          </button>
        </span>
      ))}
    </span>
  )
}

/** A guess at what a link is, for the suggestion's artwork and badge, before the server has seen it. */
function guessKind(link: string): { kind: TaskKind; type: FileType; name: string } {
  if (/^magnet:/i.test(link)) {
    const dn = /[?&]dn=([^&]+)/i.exec(link)?.[1]
    let name = link
    try {
      if (dn) name = decodeURIComponent(dn.replace(/\+/g, ' '))
    } catch {
      // A malformed escape: show the raw link.
    }
    return { kind: 'torrent', type: 'magnet', name }
  }
  const scheme = /^(\w+):/.exec(link)?.[1]?.toLowerCase()
  const kind: TaskKind = scheme === 'ftp' || scheme === 'ftps' ? 'ftp' : scheme === 'sftp' ? 'sftp' : /\.m3u8(\?|$)/i.test(link) ? 'hls' : 'http'
  let name = link
  try {
    const u = new URL(link)
    name = decodeURIComponent(u.pathname.split('/').filter(Boolean).pop() ?? '') || u.host
  } catch {
    // Not a URL the browser can parse: show it as typed.
  }
  return { kind, type: fileType({ name, kind, statusToken: '' }), name }
}

interface OmniboxProps {
  /** The library search. */
  value: string
  onChange: (value: string) => void
  inputRef: RefObject<HTMLInputElement | null>
  canWrite: boolean
  /** Opens Add empty. */
  onAdd: () => void
  /** Opens Add with these links; `pasted` when they came from the clipboard. */
  onAddLinks: (text: string, pasted: boolean) => void
  /** Queues typed links straight away, with the remembered folder and priority. */
  onQuickAdd: (text: string) => void
  onPalette: () => void
}

/**
 * Studio's one box for starting anything: paste a link (or a magnet, or a stream) and Add opens
 * with it; type anything else and it searches the library, with `is:` / `host:` / `type:` tokens
 * turning into chips. ⌘K opens the command palette from here.
 */
export function Omnibox({
  value,
  onChange,
  inputRef,
  canWrite,
  onAdd,
  onAddLinks,
  onQuickAdd,
  onPalette,
}: OmniboxProps) {
  const { t } = useTranslation()
  const hintId = useId()
  const sugId = useId()
  const tokens = useSearchChips(value, onChange)
  const phone = useMediaQuery(PHONE_QUERY)
  const links = canWrite ? summarizeLinks(tokens.rest) : null
  const offer = links != null && links.valid > 0 ? links : null
  const first = offer?.lines.find((l) => l.supported)?.text ?? ''
  const guess = offer ? guessKind(first) : null

  const take = () => {
    const text = tokens.rest.trim()
    onChange(joinSearch(tokens.chips, ''))
    return text
  }
  const addTyped = () => {
    if (offer) onQuickAdd(take())
  }
  const openOptions = () => {
    if (offer) onAddLinks(take(), false)
  }

  const placeholder = !canWrite
    ? t('shell.omnibox.placeholderReadOnly')
    : tokens.chips.length > 0
      ? ''
      : phone
        ? t('shell.omnibox.placeholderShort')
        : t('shell.omnibox.placeholder')

  return (
    <div className={`omni${offer ? ' has-sug' : ''}`} role="search">
      <div className="omni-in">
        <Icon name={canWrite ? 'plus' : 'search'} size="l" className="omni-ic" />
        <SearchChips chips={tokens.chips} onRemove={tokens.remove} />
        <input
          ref={inputRef}
          type="search"
          className="omni-field"
          value={tokens.rest}
          enterKeyHint={offer ? 'go' : 'search'}
          autoComplete="off"
          autoCorrect="off"
          autoCapitalize="off"
          spellCheck={false}
          onChange={(e) => tokens.onRest(e.target.value)}
          onPaste={(e) => {
            if (!canWrite) return
            const text = e.clipboardData.getData('text/plain').trim()
            // Pasting links into an empty box opens Add with them, as pasting anywhere else does.
            if (text && tokens.rest.trim() === '' && summarizeLinks(text).valid > 0) {
              e.preventDefault()
              onAddLinks(text, true)
            }
          }}
          onKeyDown={(e) => {
            const el = e.currentTarget
            if (e.key === 'Enter' && offer) {
              e.preventDefault()
              addTyped()
            } else if (e.key === 'Backspace' && tokens.onBackspace(el.selectionStart === 0 && el.selectionEnd === 0)) {
              e.preventDefault()
            } else if (e.key === 'Escape' && value !== '') {
              // Ours: a first Escape clears the search; the next one reaches the page.
              e.preventDefault()
              e.stopPropagation()
              onChange('')
            }
          }}
          placeholder={placeholder}
          aria-label={canWrite ? t('shell.omnibox.label') : t('topbar.searchDownloads')}
          aria-describedby={offer ? `${hintId} ${sugId}` : hintId}
          aria-keyshortcuts="/"
        />
        <span id={hintId} hidden>
          {canWrite ? t('shell.omnibox.hint') : t('workflow.search.hint')}
        </span>
        {value !== '' && (
          <button type="button" className="ibtn sm omni-clear" onClick={() => onChange('')} aria-label={t('shell.omnibox.clear')}>
            <Icon name="x" size="s" />
          </button>
        )}
        <button
          type="button"
          className="kbd omni-k"
          onClick={onPalette}
          aria-label={t('workflow.palette.label')}
          aria-keyshortcuts="Meta+K Control+K"
          title={t('shortcuts.hint', { label: t('workflow.palette.label'), key: '⌘K' })}
        >
          ⌘K
        </button>
        {canWrite && (
          <button
            type="button"
            className="btn pri omni-add"
            onClick={offer ? addTyped : onAdd}
            aria-keyshortcuts="N"
            title={t('shortcuts.hint', { label: t('topbar.addDownload'), key: 'N' })}
          >
            <Icon name="plus" />
            <span>{t('common.add')}</span>
          </button>
        )}
      </div>
      {offer && guess && (
        <div className="omni-sug" id={sugId} role="status">
          <Art kind={guess.type} size="s" />
          <span className="col omni-sug-t">
            <span className="eyebrow acc">{t('shell.omnibox.found', { count: offer.valid })}</span>
            <span className="small ell">{offer.valid > 1 ? first : guess.name}</span>
          </span>
          <span className="badge">{kindBadge(guess.kind)}</span>
          <button type="button" className="btn sm ghost" onClick={openOptions}>
            {t('shell.omnibox.options')}
          </button>
          <button type="button" className="btn sm pri" onClick={addTyped}>
            <Icon name="arrow" />
            {t('shell.omnibox.addCount', { count: offer.valid })}
          </button>
        </div>
      )}
    </div>
  )
}
