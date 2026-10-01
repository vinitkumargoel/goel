/**
 * The tab icon as a live progress ring, with a red dot while anything has failed — the tab
 * says "still going" or "needs you" without being the one in front. Idle and healthy, the
 * page shell's own SVG icon is put back.
 */

const SIZE = 64

let original: string | null = null
let lastKey = ''

function iconLink(): HTMLLinkElement | null {
  return document.querySelector<HTMLLinkElement>('link[rel="icon"]')
}

export function drawFavicon(progress: number | null, failed: boolean): void {
  const link = iconLink()
  if (!link) return
  if (original == null) original = link.href
  const key = `${progress == null ? '-' : Math.round(progress * 40)}|${failed}`
  if (key === lastKey) return
  lastKey = key

  if (progress == null && !failed) {
    link.type = 'image/svg+xml'
    link.href = original
    return
  }
  const canvas = document.createElement('canvas')
  canvas.width = SIZE
  canvas.height = SIZE
  const ctx = canvas.getContext('2d')
  // jsdom and some privacy modes have no 2D context; the static icon stays.
  if (!ctx) return

  ctx.beginPath()
  ctx.arc(32, 32, 28, 0, Math.PI * 2)
  ctx.fillStyle = '#2f83e6'
  ctx.fill()
  if (progress != null) {
    ctx.lineWidth = 8
    ctx.lineCap = 'round'
    ctx.strokeStyle = 'rgba(255,255,255,0.28)'
    ctx.beginPath()
    ctx.arc(32, 32, 20, 0, Math.PI * 2)
    ctx.stroke()
    ctx.strokeStyle = '#ffffff'
    ctx.beginPath()
    ctx.arc(32, 32, 20, -Math.PI / 2, -Math.PI / 2 + Math.PI * 2 * Math.max(0.02, progress))
    ctx.stroke()
  }
  if (failed) {
    ctx.beginPath()
    ctx.arc(50, 14, 12, 0, Math.PI * 2)
    ctx.fillStyle = '#f87171'
    ctx.fill()
    ctx.lineWidth = 3
    ctx.strokeStyle = '#15171d'
    ctx.stroke()
  }
  link.type = 'image/png'
  link.href = canvas.toDataURL('image/png')
}
