import type { SVGProps } from 'react'
import type { FileType } from '../lib/taskKind'

/**
 * Every icon in the portal, as components.
 *
 * These were `innerHTML` strings in the old build, which meant any name that
 * reached them had to be hand-escaped. As JSX they cannot inject markup at all,
 * so the escaping helper the old portal needed is simply gone.
 */

type IconProps = SVGProps<SVGSVGElement>

const stroke = {
  fill: 'none',
  stroke: 'currentColor',
  strokeWidth: 2,
  strokeLinecap: 'round',
  strokeLinejoin: 'round',
} as const

export function PlayIcon(props: IconProps) {
  return (
    <svg viewBox="0 0 24 24" fill="currentColor" {...props}>
      <path d="M8 5v14l11-7z" />
    </svg>
  )
}

export function PauseIcon(props: IconProps) {
  return (
    <svg viewBox="0 0 24 24" fill="currentColor" {...props}>
      <path d="M7 5h3.5v14H7zM13.5 5H17v14h-3.5z" />
    </svg>
  )
}

export function RetryIcon(props: IconProps) {
  return (
    <svg viewBox="0 0 24 24" {...props}>
      <path
        d="M4 12a8 8 0 018-8c2.5 0 4.7 1.1 6.2 2.9M20 5v4h-4M20 12a8 8 0 01-8 8c-2.5 0-4.7-1.1-6.2-2.9M4 19v-4h4"
        {...stroke}
      />
    </svg>
  )
}

export function CopyIcon(props: IconProps) {
  return (
    <svg viewBox="0 0 24 24" {...props}>
      <rect x="9" y="9" width="11" height="11" rx="2" {...stroke} />
      <path d="M5 15V5a2 2 0 012-2h10" {...stroke} />
    </svg>
  )
}

export function CheckIcon(props: IconProps) {
  return (
    <svg viewBox="0 0 24 24" {...props}>
      <path d="M20 6L9 17l-5-5" {...stroke} strokeWidth={3} />
    </svg>
  )
}

export function DownloadIcon(props: IconProps) {
  return (
    <svg viewBox="0 0 24 24" {...props}>
      <path d="M12 3v12m0 0l-4-4m4 4l4-4M5 21h14" {...stroke} />
    </svg>
  )
}

export function StreamIcon(props: IconProps) {
  return (
    <svg viewBox="0 0 24 24" {...props}>
      <circle cx="12" cy="12" r="9" {...stroke} />
      <path d="M10 8l6 4-6 4V8z" fill="currentColor" />
    </svg>
  )
}

export function TrashIcon(props: IconProps) {
  return (
    <svg viewBox="0 0 24 24" {...props}>
      <path d="M4 7h16M9 7V4h6v3m-7 0v12a1 1 0 001 1h6a1 1 0 001-1V7" {...stroke} />
    </svg>
  )
}

export function LinkIcon(props: IconProps) {
  return (
    <svg viewBox="0 0 24 24" {...props}>
      <path d="M10 13a5 5 0 007 0l3-3a5 5 0 00-7-7l-1 1" {...stroke} />
      <path d="M14 11a5 5 0 00-7 0l-3 3a5 5 0 007 7l1-1" {...stroke} />
    </svg>
  )
}

export function RecheckIcon(props: IconProps) {
  return (
    <svg viewBox="0 0 24 24" {...props}>
      <path d="M20 6L9 17l-5-5" {...stroke} />
      <circle cx="12" cy="12" r="9" {...stroke} strokeWidth={1.5} />
    </svg>
  )
}

export function FileIcon(props: IconProps) {
  return (
    <svg viewBox="0 0 24 24" {...props}>
      <path d="M14 3H7a2 2 0 00-2 2v14a2 2 0 002 2h10a2 2 0 002-2V8l-5-5z" {...stroke} strokeLinecap="butt" />
    </svg>
  )
}

export function CloseIcon(props: IconProps) {
  return (
    <svg viewBox="0 0 24 24" {...props}>
      <path d="M6 6l12 12M18 6L6 18" {...stroke} />
    </svg>
  )
}

export function WarnIcon(props: IconProps) {
  return (
    <svg viewBox="0 0 24 24" {...props}>
      <path d="M12 3l9 16H3l9-16zM12 10v4M12 17h.01" {...stroke} />
    </svg>
  )
}

export function LogoutIcon(props: IconProps) {
  return (
    <svg viewBox="0 0 24 24" {...props}>
      <path d="M9 21H5a2 2 0 01-2-2V5a2 2 0 012-2h4M16 17l5-5-5-5M21 12H9" {...stroke} />
    </svg>
  )
}

export function SearchIcon(props: IconProps) {
  return (
    <svg viewBox="0 0 24 24" {...props}>
      <circle cx="11" cy="11" r="7" {...stroke} />
      <path d="M21 21l-4-4" {...stroke} />
    </svg>
  )
}

export function MenuIcon(props: IconProps) {
  return (
    <svg viewBox="0 0 24 24" {...props}>
      <path d="M4 6h16M4 12h16M4 18h16" {...stroke} />
    </svg>
  )
}

export function PlusIcon(props: IconProps) {
  return (
    <svg viewBox="0 0 24 24" {...props}>
      <path d="M12 5v14M5 12h14" {...stroke} strokeWidth={2.2} />
    </svg>
  )
}

export function FolderIcon(props: IconProps) {
  return (
    <svg viewBox="0 0 24 24" {...props}>
      <path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z" {...stroke} />
    </svg>
  )
}

export function FolderPlusIcon(props: IconProps) {
  return (
    <svg viewBox="0 0 24 24" {...props}>
      <path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z" {...stroke} />
      <path d="M12 10v6M9 13h6" {...stroke} />
    </svg>
  )
}

export function PanelIcon(props: IconProps) {
  return (
    <svg viewBox="0 0 24 24" {...props}>
      <rect x="3" y="4" width="18" height="16" rx="2" {...stroke} />
      <path d="M15 4v16" {...stroke} />
    </svg>
  )
}

export function ChevronDownIcon(props: IconProps) {
  return (
    <svg viewBox="0 0 24 24" {...props}>
      <path d="M6 9l6 6 6-6" {...stroke} />
    </svg>
  )
}

export function ArrowDownIcon(props: IconProps) {
  return (
    <svg viewBox="0 0 24 24" {...props}>
      <path d="M12 4v14m0 0l-5-5m5 5l5-5" {...stroke} />
    </svg>
  )
}

export function ArrowUpIcon(props: IconProps) {
  return (
    <svg viewBox="0 0 24 24" {...props}>
      <path d="M12 20V6m0 0l-5 5m5-5l5 5" {...stroke} />
    </svg>
  )
}

// ---- sidebar ----

export function ListIcon(props: IconProps) {
  return (
    <svg viewBox="0 0 24 24" {...props}>
      <path d="M3 7h18M3 12h18M3 17h18" {...stroke} />
    </svg>
  )
}

export function ActiveIcon(props: IconProps) {
  return (
    <svg viewBox="0 0 24 24" {...props}>
      <path d="M12 3v11m0 0l-4-4m4 4l4-4M5 19h14" {...stroke} />
    </svg>
  )
}

export function PausedIcon(props: IconProps) {
  return (
    <svg viewBox="0 0 24 24" {...props}>
      <path d="M8 5v14M16 5v14" {...stroke} />
    </svg>
  )
}

export function CompletedIcon(props: IconProps) {
  return (
    <svg viewBox="0 0 24 24" {...props}>
      <path d="M20 6L9 17l-5-5" {...stroke} />
    </svg>
  )
}

export function SeedingIcon(props: IconProps) {
  return (
    <svg viewBox="0 0 24 24" {...props}>
      <path d="M12 21V8m0 0l-4 4m4-4l4 4M5 5h14" {...stroke} />
    </svg>
  )
}

export function FailedIcon(props: IconProps) {
  return (
    <svg viewBox="0 0 24 24" {...props}>
      <circle cx="12" cy="12" r="9" {...stroke} />
      <path d="M12 8v4m0 4h.01" {...stroke} />
    </svg>
  )
}

export function HistoryIcon(props: IconProps) {
  return (
    <svg viewBox="0 0 24 24" {...props}>
      <path d="M3 12a9 9 0 109-9 9 9 0 00-7 3.3M3 4v4h4M12 7v5l3 2" {...stroke} />
    </svg>
  )
}

export function SettingsIcon(props: IconProps) {
  return (
    <svg viewBox="0 0 24 24" {...props}>
      <circle cx="12" cy="12" r="3" {...stroke} />
      <path
        d="M19.4 15a1.6 1.6 0 00.3 1.8l.1.1a2 2 0 11-2.9 2.8l-.1-.1a1.6 1.6 0 00-2.7 1.1V21a2 2 0 11-4 0 1.6 1.6 0 00-2.7-1.1l-.1.1a2 2 0 11-2.8-2.9l.1-.1a1.6 1.6 0 00-1.1-2.7H3a2 2 0 110-4 1.6 1.6 0 001.1-2.7l-.1-.1a2 2 0 112.8-2.8l.1.1A1.6 1.6 0 009 4.6V4a2 2 0 114 0 1.6 1.6 0 002.7 1.1l.1-.1a2 2 0 112.8 2.8l-.1.1a1.6 1.6 0 001.1 2.7H21a2 2 0 110 4h-.6a1.6 1.6 0 00-1 .4z"
        {...stroke}
        strokeWidth={1.5}
      />
    </svg>
  )
}

// ---- file-type tiles (always white on a coloured tile) ----

const tile = {
  fill: 'none',
  stroke: '#fff',
  strokeWidth: 2,
  strokeLinejoin: 'round',
} as const

export function FileTypeIcon({ type, ...props }: IconProps & { type: FileType }) {
  switch (type) {
    case 'iso':
      return (
        <svg viewBox="0 0 24 24" {...props}>
          <circle cx="12" cy="12" r="9" {...tile} />
          <circle cx="12" cy="12" r="2.5" fill="#fff" />
        </svg>
      )
    case 'video':
      return (
        <svg viewBox="0 0 24 24" {...props}>
          <rect x="2" y="5" width="14" height="14" rx="2" {...tile} />
          <path d="M16 9l6-3v12l-6-3" {...tile} />
        </svg>
      )
    case 'archive':
      return (
        <svg viewBox="0 0 24 24" {...props}>
          <rect x="4" y="3" width="16" height="18" rx="2" {...tile} />
          <path d="M12 3v3m-2 0h4m-2 3v3" {...tile} strokeLinecap="round" />
        </svg>
      )
    case 'app':
      return (
        <svg viewBox="0 0 24 24" {...props}>
          <path
            d="M12 2l3 3-3 3-3-3 3-3zM5 9l3 3-3 3-3-3 3-3zM19 9l3 3-3 3-3-3zM12 16l3 3-3 3-3-3z"
            {...tile}
            strokeWidth={1.6}
          />
        </svg>
      )
    case 'magnet':
      return (
        <svg viewBox="0 0 24 24" {...props}>
          <path d="M5 4h4v8a3 3 0 006 0V4h4v8a7 7 0 01-14 0V4z" {...tile} />
          <path d="M5 8h4M15 8h4" {...tile} />
        </svg>
      )
    case 'doc':
      return (
        <svg viewBox="0 0 24 24" {...props}>
          <path d="M14 3H7a2 2 0 00-2 2v14a2 2 0 002 2h10a2 2 0 002-2V8l-5-5z" {...tile} />
        </svg>
      )
  }
}

/** The brand mark, shared with the server-rendered login page. */
export function Logo(props: IconProps) {
  return (
    <svg viewBox="0 0 48 48" {...props}>
      <defs>
        <linearGradient id="goel-lg" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor="#5db4f5" />
          <stop offset="1" stopColor="#2f83e6" />
        </linearGradient>
      </defs>
      <rect width="48" height="48" rx="10.8" fill="url(#goel-lg)" />
      <g stroke="#fff" strokeWidth="3.4" strokeLinecap="round" strokeLinejoin="round" fill="none">
        <circle cx="24" cy="21" r="8.5" />
        <path d="M32.5 12.5 L32.5 32 Q32.5 36 27 36" />
      </g>
      <circle cx="38.2" cy="11" r="3.1" fill="#fff" />
    </svg>
  )
}
