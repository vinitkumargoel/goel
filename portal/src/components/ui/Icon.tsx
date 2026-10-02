import type { ReactNode, SVGProps } from 'react'

/**
 * The Studio icon set: 24-unit strokes drawn with `currentColor`, the mockup's `studio-i-*`
 * symbols plus the few the portal needs beyond them. Decorative by default (`aria-hidden`);
 * give the button that holds one its accessible name.
 */
const PATHS = {
  plus: <path d="M12 5v14M5 12h14" />,
  minus: <path d="M5 12h14" />,
  search: (
    <>
      <circle cx="11" cy="11" r="7" />
      <path d="M20 20l-3.6-3.6" />
    </>
  ),
  pause: <path d="M9 5.5v13M15 5.5v13" />,
  play: <path d="M7.5 5v14l11-7z" />,
  retry: (
    <>
      <path d="M3.5 12a8.5 8.5 0 1 0 2.6-6.1L3.5 8.5" />
      <path d="M3.5 3.5v5h5" />
    </>
  ),
  folder: (
    <path d="M3 7.5A2.5 2.5 0 0 1 5.5 5H9l2 2.2h7.5A2.5 2.5 0 0 1 21 9.7v7.8a2.5 2.5 0 0 1-2.5 2.5h-13A2.5 2.5 0 0 1 3 17.5z" />
  ),
  folderPlus: (
    <>
      <path d="M3 7.5A2.5 2.5 0 0 1 5.5 5H9l2 2.2h7.5A2.5 2.5 0 0 1 21 9.7v7.8a2.5 2.5 0 0 1-2.5 2.5h-13A2.5 2.5 0 0 1 3 17.5z" />
      <path d="M12 11v5M9.5 13.5h5" />
    </>
  ),
  copy: (
    <>
      <rect x="9" y="9" width="11" height="11" rx="2.5" />
      <path d="M15 9V6.5A2.5 2.5 0 0 0 12.5 4h-6A2.5 2.5 0 0 0 4 6.5v6A2.5 2.5 0 0 0 6.5 15H9" />
    </>
  ),
  link: (
    <>
      <path d="M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1" />
      <path d="M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1" />
    </>
  ),
  x: <path d="M6.5 6.5l11 11M17.5 6.5l-11 11" />,
  check: <path d="M5 12.5l4.5 4.5L19 7.5" />,
  chevronDown: <path d="M6.5 9.5l5.5 5.5 5.5-5.5" />,
  chevronRight: <path d="M9.5 6.5l5.5 5.5-5.5 5.5" />,
  chevronLeft: <path d="M14.5 6.5L9 12l5.5 5.5" />,
  chevronUp: <path d="M6.5 14.5L12 9l5.5 5.5" />,
  down: <path d="M12 4.5v14M6.5 13l5.5 5.5 5.5-5.5" />,
  up: <path d="M12 19.5v-14M6.5 11L12 5.5l5.5 5.5" />,
  toTop: <path d="M5.5 4.5h13M12 20V9M7 13.5l5-5 5 5" />,
  toBottom: <path d="M5.5 19.5h13M12 4v11M7 10.5l5 5 5-5" />,
  clock: (
    <>
      <circle cx="12" cy="12" r="8.5" />
      <path d="M12 7.5V12l3 2" />
    </>
  ),
  alert: (
    <>
      <path d="M10.3 4.2a2 2 0 0 1 3.4 0l7.5 13a2 2 0 0 1-1.7 3H4.5a2 2 0 0 1-1.7-3z" />
      <path d="M12 10v3.5M12 16.8v.2" />
    </>
  ),
  trash: <path d="M4.5 7h15M9.5 7V4.5h5V7M6.5 7l1 12.5h9l1-12.5" />,
  settings: (
    <>
      <path d="M4 6.5h9M17 6.5h3M4 12h3M11 12h9M4 17.5h11M19 17.5h1" />
      <circle cx="15" cy="6.5" r="2" />
      <circle cx="9" cy="12" r="2" />
      <circle cx="17" cy="17.5" r="2" />
    </>
  ),
  board: (
    <>
      <rect x="3.5" y="4" width="7" height="16" rx="2" />
      <rect x="13.5" y="4" width="7" height="9" rx="2" />
      <rect x="13.5" y="16" width="7" height="4" rx="1.5" />
    </>
  ),
  list: (
    <>
      <path d="M9 6.5h11M9 12h11M9 17.5h11" />
      <path d="M4.5 6.5h.01M4.5 12h.01M4.5 17.5h.01" strokeWidth="2.6" />
    </>
  ),
  grid: (
    <>
      <rect x="4" y="4" width="7" height="7" rx="2" />
      <rect x="13" y="4" width="7" height="7" rx="2" />
      <rect x="4" y="13" width="7" height="7" rx="2" />
      <rect x="13" y="13" width="7" height="7" rx="2" />
    </>
  ),
  server: (
    <>
      <rect x="3.5" y="4" width="17" height="7" rx="2" />
      <rect x="3.5" y="13" width="17" height="7" rx="2" />
      <path d="M7.5 7.5h.01M7.5 16.5h.01" strokeWidth="2.6" />
    </>
  ),
  history: (
    <>
      <path d="M3.5 12a8.5 8.5 0 1 0 2.6-6.1L3.5 8.5" />
      <path d="M3.5 3.5v5h5M12 8v4.3l3 1.8" />
    </>
  ),
  tag: (
    <>
      <path d="M3.5 12.2V4.5a1 1 0 0 1 1-1h7.7l8.3 8.3a1.5 1.5 0 0 1 0 2.1l-6.6 6.6a1.5 1.5 0 0 1-2.1 0z" />
      <circle cx="8" cy="8" r="1.4" />
    </>
  ),
  film: (
    <>
      <rect x="3.5" y="4" width="17" height="16" rx="2.5" />
      <path d="M7.5 4v16M16.5 4v16M3.5 9h4M3.5 15h4M16.5 9h4M16.5 15h4" />
    </>
  ),
  music: (
    <>
      <path d="M9 17.5V6l11-2v11.5" />
      <circle cx="6.5" cy="17.5" r="2.5" />
      <circle cx="17.5" cy="15.5" r="2.5" />
    </>
  ),
  disc: (
    <>
      <circle cx="12" cy="12" r="8.5" />
      <circle cx="12" cy="12" r="2.5" />
    </>
  ),
  archive: (
    <>
      <rect x="3.5" y="4" width="17" height="5" rx="1.5" />
      <path d="M5 9v9.5A1.5 1.5 0 0 0 6.5 20h11a1.5 1.5 0 0 0 1.5-1.5V9M10 13h4" />
    </>
  ),
  app: (
    <>
      <path d="M12 3.5l7.5 4.2v8.6L12 20.5l-7.5-4.2V7.7z" />
      <path d="M4.5 7.7L12 12l7.5-4.3M12 12v8.5" />
    </>
  ),
  doc: (
    <>
      <path d="M6.5 3.5h7.5l4.5 4.5v12.5h-12z" />
      <path d="M13.5 3.5v5h5M9 13h6M9 16.5h4.5" />
    </>
  ),
  file: (
    <>
      <path d="M6.5 3.5h7.5l4.5 4.5v12.5h-12z" />
      <path d="M13.5 3.5v5h5" />
    </>
  ),
  image: (
    <>
      <rect x="3.5" y="4.5" width="17" height="15" rx="2.5" />
      <circle cx="9" cy="10" r="1.8" />
      <path d="M20.5 15.5l-4.5-4.5-8.5 8.5" />
    </>
  ),
  magnet: (
    <>
      <path d="M5 4h4.5v7a2.5 2.5 0 0 0 5 0V4H19v7a7 7 0 0 1-14 0z" />
      <path d="M5 8h4.5M14.5 8H19" />
    </>
  ),
  globe: (
    <>
      <circle cx="12" cy="12" r="8.5" />
      <path d="M3.5 12h17M12 3.5c2.5 2.6 3.5 5.4 3.5 8.5s-1 5.9-3.5 8.5c-2.5-2.6-3.5-5.4-3.5-8.5s1-5.9 3.5-8.5z" />
    </>
  ),
  bolt: <path d="M13 3L5 13.5h6l-1 7.5 8-10.5h-6z" />,
  gauge: (
    <>
      <path d="M4 17.5a8 8 0 1 1 16 0" />
      <path d="M12 17.5l4-5.5" />
    </>
  ),
  filter: <path d="M4 5h16l-6 7.5V18l-4 2v-7.5z" />,
  sort: <path d="M7.5 4.5v15M4 16l3.5 3.5L11 16M16.5 19.5v-15M13 8l3.5-3.5L20 8" />,
  more: <path d="M5.5 12h.01M12 12h.01M18.5 12h.01" strokeWidth="3" />,
  eye: (
    <>
      <path d="M2.5 12S6 5.5 12 5.5 21.5 12 21.5 12 18 18.5 12 18.5 2.5 12 2.5 12z" />
      <circle cx="12" cy="12" r="2.8" />
    </>
  ),
  upload: <path d="M12 15V4.5M7.5 9L12 4.5 16.5 9M4.5 15v3.5a1.5 1.5 0 0 0 1.5 1.5h12a1.5 1.5 0 0 0 1.5-1.5V15" />,
  download: <path d="M12 4.5V15M7.5 10.5L12 15l4.5-4.5M4.5 15v3.5a1.5 1.5 0 0 0 1.5 1.5h12a1.5 1.5 0 0 0 1.5-1.5V15" />,
  key: (
    <>
      <circle cx="8" cy="15.5" r="4" />
      <path d="M11 12.5l8.5-8.5M16.5 7l2.5 2.5M14.5 9l2 2" />
    </>
  ),
  lock: (
    <>
      <rect x="5" y="10.5" width="14" height="10" rx="2.5" />
      <path d="M8 10.5V8a4 4 0 0 1 8 0v2.5" />
    </>
  ),
  shield: (
    <>
      <path d="M12 3.5l7.5 3v5.5c0 4.6-3.2 7.6-7.5 8.5-4.3-.9-7.5-3.9-7.5-8.5V6.5z" />
      <path d="M9 12l2 2 4-4" />
    </>
  ),
  wifi: (
    <>
      <path d="M2.5 9a14 14 0 0 1 19 0M5.5 12.5a9.5 9.5 0 0 1 13 0M8.5 16a5 5 0 0 1 7 0" />
      <path d="M12 19.5h.01" strokeWidth="2.6" />
    </>
  ),
  wifiOff: (
    <>
      <path d="M8.5 16a5 5 0 0 1 7 0M5.5 12.5a9.5 9.5 0 0 1 4-2.3M2.5 9a14 14 0 0 1 4.2-2.6M14.5 10.2a9.5 9.5 0 0 1 4 2.3M12.5 5.6A14 14 0 0 1 21.5 9" />
      <path d="M12 19.5h.01" strokeWidth="2.6" />
      <path d="M4 4l16 16" />
    </>
  ),
  cal: (
    <>
      <rect x="3.5" y="5" width="17" height="15.5" rx="2.5" />
      <path d="M3.5 10h17M8 3v4M16 3v4" />
    </>
  ),
  bell: (
    <>
      <path d="M6 16.5V11a6 6 0 0 1 12 0v5.5l1.5 1.5h-15z" />
      <path d="M10 20.5h4" />
    </>
  ),
  chart: <path d="M3.5 20.5h17M6.5 17v-5M11 17V7M15.5 17v-8M20 17v-3" />,
  term: (
    <>
      <rect x="3.5" y="4.5" width="17" height="15" rx="2.5" />
      <path d="M7.5 9.5l3 2.5-3 2.5M13 15h3.5" />
    </>
  ),
  phone: (
    <>
      <rect x="7" y="2.5" width="10" height="19" rx="2.5" />
      <path d="M11 18.5h2" />
    </>
  ),
  cmd: (
    <path d="M9 6.5a2.5 2.5 0 1 0-2.5 2.5h11A2.5 2.5 0 1 0 15 6.5v11a2.5 2.5 0 1 0 2.5-2.5h-11A2.5 2.5 0 1 0 9 17.5z" />
  ),
  grip: <path d="M9 6h.01M15 6h.01M9 12h.01M15 12h.01M9 18h.01M15 18h.01" strokeWidth="2.8" />,
  info: (
    <>
      <circle cx="12" cy="12" r="8.5" />
      <path d="M12 11v5.5M12 7.8v.2" />
    </>
  ),
  ext: (
    <path d="M14 4h6v6M20 4l-8.5 8.5M18 14v4.5a1.5 1.5 0 0 1-1.5 1.5h-11A1.5 1.5 0 0 1 4 18.5v-11A1.5 1.5 0 0 1 5.5 6H10" />
  ),
  refresh: (
    <path d="M19.5 11A7.5 7.5 0 0 0 6 6.6L4 8.5M4 4v4.5h4.5M4.5 13A7.5 7.5 0 0 0 18 17.4l2-1.9M20 20v-4.5h-4.5" />
  ),
  stop: <rect x="6.5" y="6.5" width="11" height="11" rx="2" />,
  power: <path d="M12 3.5V12M6.5 6.5a7.5 7.5 0 1 0 11 0" />,
  user: (
    <>
      <circle cx="12" cy="8.5" r="3.8" />
      <path d="M4.5 20.5a7.5 7.5 0 0 1 15 0" />
    </>
  ),
  logout: <path d="M14 4.5h4a1.5 1.5 0 0 1 1.5 1.5v12a1.5 1.5 0 0 1-1.5 1.5h-4M10 16.5L5.5 12 10 7.5M5.5 12H15" />,
  inbox: (
    <>
      <path d="M3.5 13.5L6.2 5h11.6l2.7 8.5v5a1.5 1.5 0 0 1-1.5 1.5H5a1.5 1.5 0 0 1-1.5-1.5z" />
      <path d="M3.5 13.5h5l1.2 2h4.6l1.2-2h5" />
    </>
  ),
  sidebar: (
    <>
      <rect x="3.5" y="4.5" width="17" height="15" rx="2.5" />
      <path d="M9.5 4.5v15" />
    </>
  ),
  panel: (
    <>
      <rect x="3.5" y="4.5" width="17" height="15" rx="2.5" />
      <path d="M14.5 4.5v15" />
    </>
  ),
  menu: <path d="M4.5 7h15M4.5 12h15M4.5 17h15" />,
  arrow: <path d="M5 12h14M13.5 6.5L19 12l-5.5 5.5" />,
  vol: (
    <>
      <path d="M4 9.5h3.5L12.5 5v14l-5-4.5H4z" />
      <path d="M16 9a4.5 4.5 0 0 1 0 6M18.5 6.5a8 8 0 0 1 0 11" />
    </>
  ),
  mute: (
    <>
      <path d="M4 9.5h3.5L12.5 5v14l-5-4.5H4z" />
      <path d="M16.5 9.5l5 5M21.5 9.5l-5 5" />
    </>
  ),
  full: <path d="M4 9V4h5M20 9V4h-5M4 15v5h5M20 15v5h-5" />,
  subs: (
    <>
      <rect x="3.5" y="5" width="17" height="14" rx="2.5" />
      <path d="M7 12.5h3.5M13 12.5h4M7 15.5h6" />
    </>
  ),
  hash: <path d="M5 9h14.5M4.5 15H19M10 4l-2 16M16 4l-2 16" />,
  plug: <path d="M9 3v5M15 3v5M6.5 8h11v3.5a5.5 5.5 0 0 1-11 0zM12 17v4" />,
  home: <path d="M3.5 11L12 4l8.5 7v8a1.5 1.5 0 0 1-1.5 1.5h-4.5v-6h-5v6H5A1.5 1.5 0 0 1 3.5 19z" />,
  snail: (
    <>
      <path d="M3.5 18.5h15a2.5 2.5 0 0 0 2.5-2.5V9" />
      <circle cx="11" cy="12" r="5.5" />
      <path d="M11 12a2 2 0 1 1 2-2M19.5 6.5l1.5 2.5M22 6l-1 3" />
    </>
  ),
  sparkle: (
    <>
      <path d="M12 3.5l1.9 5.1 5.1 1.9-5.1 1.9-1.9 5.1-1.9-5.1L5 10.5l5.1-1.9z" />
      <path d="M18.5 16l.8 2 2 .8-2 .8-.8 2-.8-2-2-.8 2-.8z" />
    </>
  ),
  moon: <path d="M19.5 14.5A8 8 0 0 1 9.5 4.5a8 8 0 1 0 10 10z" />,
  sun: (
    <>
      <circle cx="12" cy="12" r="4" />
      <path d="M12 2.5v2M12 19.5v2M2.5 12h2M19.5 12h2M5.3 5.3l1.4 1.4M17.3 17.3l1.4 1.4M5.3 18.7l1.4-1.4M17.3 6.7l1.4-1.4" />
    </>
  ),
  note: (
    <>
      <path d="M5 4.5h14v10l-5 5H5z" />
      <path d="M14 19.5v-5h5M8.5 9h7M8.5 12.5h4" />
    </>
  ),
  keyboard: (
    <>
      <rect x="2.5" y="6" width="19" height="12" rx="2.5" />
      <path d="M6.5 10h.01M10 10h.01M14 10h.01M17.5 10h.01M8 14h8" strokeWidth="2" />
    </>
  ),
  seed: <path d="M12 19.5v-14M6.5 11L12 5.5l5.5 5.5M5 20h14" />,
  stream: (
    <>
      <circle cx="12" cy="12" r="8.5" />
      <path d="M10 8.5v7l5.5-3.5z" />
    </>
  ),
  pin: <path d="M9 3.5h6M10 3.5v5L7 12v1.5h10V12l-3-3.5v-5M12 13.5v7" />,
  translate: (
    <>
      <path d="M4 5.5h9M8.5 3.5v2M6 5.5c.8 3.5 3 6 6 7.5M11 5.5c-.8 3.5-3 6-6.5 7.5" />
      <path d="M12.5 20.5l4-9.5 4 9.5M14 17h5" />
    </>
  ),
} satisfies Record<string, ReactNode>

export type IconName = keyof typeof PATHS

export const ICON_NAMES = Object.keys(PATHS) as IconName[]

type Size = 's' | 'm' | 'l' | 'xl'

interface IconProps extends Omit<SVGProps<SVGSVGElement>, 'name'> {
  name: IconName
  /** s 14 · m 16 (default) · l 20 · xl 28. */
  size?: Size
  /** An accessible name makes the icon an image; without one it is hidden from assistive tech. */
  label?: string
}

export function Icon({ name, size = 'm', label, className, ...rest }: IconProps) {
  const cls = `ic${size === 'm' ? '' : ` ${size}`}${className ? ` ${className}` : ''}`
  return (
    <svg
      className={cls}
      viewBox="0 0 24 24"
      focusable="false"
      {...(label ? { role: 'img', 'aria-label': label } : { 'aria-hidden': true })}
      {...rest}
    >
      {PATHS[name]}
    </svg>
  )
}
