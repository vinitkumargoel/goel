import { useEffect, useRef, type RefObject } from 'react'
import { useTranslation } from 'react-i18next'
import { SearchIcon } from './Icons'

interface MobileSearchProps {
  value: string
  onChange: (value: string) => void
  /** Cancel clears the query and closes; focus goes back to `returnFocusTo`. */
  onClose: () => void
  returnFocusTo: RefObject<HTMLElement | null>
}

/** The ≤680px search: a full-width bar over the topbar, opened by its search icon or "/". */
export function MobileSearch({ value, onChange, onClose, returnFocusTo }: MobileSearchProps) {
  const { t } = useTranslation()
  const input = useRef<HTMLInputElement>(null)

  useEffect(() => {
    input.current?.focus()
    const back = returnFocusTo
    return () => {
      const el = back.current
      if (el?.isConnected) el.focus()
    }
  }, [returnFocusTo])

  const cancel = () => {
    onChange('')
    onClose()
  }

  return (
    <div className="msearch" role="search">
      <div className="search">
        <SearchIcon aria-hidden="true" />
        <input
          ref={input}
          type="search"
          value={value}
          onChange={(e) => onChange(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === 'Escape') {
              // Ours, not the page's: the global Escape would also close unrelated menus.
              e.preventDefault()
              e.stopPropagation()
              cancel()
            }
          }}
          placeholder={t('topbar.searchDownloads')}
          aria-label={t('topbar.searchDownloads')}
        />
      </div>
      <button type="button" className="btn ghost msearch-cancel" onClick={cancel}>
        {t('topbar.cancelSearch')}
      </button>
    </div>
  )
}
