/**
 * What the installed app was launched with: the Web Share Target (`/?url=…&text=…`, the manifest's
 * `share_target`) and the "Add download" shortcut (`/?add=1`).
 */
export interface Launch {
  /** Links shared into the app, one per line; empty when none came. */
  links: string
  /** Open the Add dialog, with `links` in it when there are some. */
  open: boolean
  /** The query string without the parameters consumed here, so a reload does not reopen the dialog. */
  rest: string
}

const CONSUMED = ['url', 'text', 'title', 'add']

export function parseLaunch(search: string): Launch {
  const params = new URLSearchParams(search)
  const url = (params.get('url') ?? '').trim()
  const text = (params.get('text') ?? '').trim()
  // Some browsers put the link in `text` only, or repeat it in both: keep each distinct once.
  const links = [...new Set([url, text].filter(Boolean))].join('\n')
  const open = links !== '' || params.get('add') === '1'
  for (const key of CONSUMED) params.delete(key)
  const rest = params.toString()
  return { links, open, rest: rest ? `?${rest}` : '' }
}
