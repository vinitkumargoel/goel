import { useTranslation } from 'react-i18next'
import { formatToken, joinSearch, splitSearch, type SearchToken } from '../lib/search'
import { CloseIcon } from './Icons'

/**
 * The finished `is:` / `host:` / `type:` tokens of a search, as removable chips before the field.
 * `value` is the whole search; the caller's input shows `rest` and passes edits to `onRest`.
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

export function SearchChips({ chips, onRemove }: { chips: readonly SearchToken[]; onRemove: (index: number) => void }) {
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
            <CloseIcon aria-hidden="true" />
          </button>
        </span>
      ))}
    </span>
  )
}
