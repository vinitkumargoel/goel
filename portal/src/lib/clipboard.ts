/**
 * Copy to clipboard, resolving to whether anything actually landed there.
 *
 * `navigator.clipboard` is undefined in a non-secure context — which is the
 * default LAN deployment, plain HTTP — so a selection copy stands in. The
 * return value is honest on purpose: a "Copied" toast over an empty clipboard
 * is a lie the user only discovers when they paste.
 */
export async function copyText(text: string): Promise<boolean> {
  if (navigator.clipboard?.writeText) {
    try {
      await navigator.clipboard.writeText(text)
      return true
    } catch {
      // Permission denied, or a non-secure context that advertises the API
      // anyway. Fall through to the selection path.
    }
  }
  return selectionCopy(text)
}

function selectionCopy(text: string): boolean {
  try {
    const area = document.createElement('textarea')
    area.value = text
    area.setAttribute('readonly', '')
    area.style.position = 'fixed'
    area.style.opacity = '0'
    document.body.appendChild(area)
    area.select()
    // Deprecated, and the only thing that works without a secure context.
    const ok = document.execCommand('copy')
    area.remove()
    return ok
  } catch {
    return false
  }
}
