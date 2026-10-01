import { afterEach, describe, expect, it } from 'vitest'
import { filterForShortcut, isPaletteKey, resolveGo, resolveShortcut } from './shortcuts'

function el(html: string): HTMLElement {
  const host = document.createElement('div')
  host.innerHTML = html
  document.body.append(host)
  return host.firstElementChild as HTMLElement
}

afterEach(() => {
  document.body.innerHTML = ''
})

const onBody = (key: string, extra = {}) => resolveShortcut({ key, target: document.body, ...extra })

describe('resolveShortcut', () => {
  it('maps each documented key from the page', () => {
    expect(onBody('/')).toBe('search')
    expect(onBody('?')).toBe('help')
    expect(onBody('n')).toBe('add')
    expect(onBody('N')).toBe('add')
    expect(onBody('j')).toBe('next')
    expect(onBody('K')).toBe('prev')
    expect(onBody(' ')).toBe('toggle')
    expect(onBody('Enter')).toBe('open')
    expect(onBody('Delete')).toBe('remove')
    expect(onBody('Backspace')).toBe('remove')
    expect(onBody('x')).toBeNull()
  })

  it('stays out of text entry of every kind', () => {
    for (const html of ['<input>', '<textarea></textarea>', '<select></select>', '<div contenteditable="true"></div>']) {
      expect(resolveShortcut({ key: 'n', target: el(html) })).toBeNull()
    }
    const inner = el('<div contenteditable="true"><span>x</span></div>').firstElementChild!
    expect(resolveShortcut({ key: '/', target: inner })).toBeNull()
  })

  it('leaves modified keys and handled events alone', () => {
    expect(onBody('n', { metaKey: true })).toBeNull()
    expect(onBody('j', { ctrlKey: true })).toBeNull()
    expect(onBody('k', { altKey: true })).toBeNull()
    expect(onBody(' ', { defaultPrevented: true })).toBeNull()
  })

  it('lets a focused button keep Space, Enter and Delete, but not letters', () => {
    const button = el('<button>Go</button>')
    expect(resolveShortcut({ key: ' ', target: button })).toBeNull()
    expect(resolveShortcut({ key: 'Enter', target: button })).toBeNull()
    expect(resolveShortcut({ key: 'Delete', target: button })).toBeNull()
    expect(resolveShortcut({ key: 'j', target: button })).toBe('next')
  })

  it('ignores auto-repeat for the activation keys only', () => {
    expect(onBody(' ', { repeat: true })).toBeNull()
    expect(onBody('Delete', { repeat: true })).toBeNull()
    expect(onBody('j', { repeat: true })).toBe('next')
  })

  it('takes Delete from a focused row', () => {
    const row = el('<div role="option" tabindex="0"></div>')
    expect(resolveShortcut({ key: 'Delete', target: row })).toBe('remove')
  })

  it('leaves every key to an open menu', () => {
    for (const role of ['menuitem', 'menuitemcheckbox', 'menuitemradio']) {
      const item = el(`<button role="${role}">Pause</button>`)
      for (const key of ['n', 'j', '/', ' ', 'Delete']) {
        expect(resolveShortcut({ key, target: item })).toBeNull()
      }
    }
    const inside = el('<div role="menu"><span tabindex="-1">x</span></div>').firstElementChild!
    expect(resolveShortcut({ key: 'n', target: inside })).toBeNull()
  })

  it('maps the digit, retry, copy and go keys', () => {
    expect(onBody('1')).toBe('filter-1')
    expect(onBody('9')).toBe('filter-9')
    expect(onBody('0')).toBeNull()
    expect(onBody('r')).toBe('retry')
    expect(onBody('C')).toBe('copy')
    expect(onBody('g')).toBe('go')
  })
})

describe('shortcut helpers', () => {
  it('maps digits to the sidebar order', () => {
    expect(filterForShortcut('filter-1')).toBe('all')
    expect(filterForShortcut('filter-7')).toBe('failed')
    expect(filterForShortcut('filter-9')).toBe('audio')
    expect(filterForShortcut('add')).toBeNull()
  })

  it('finishes a G sequence with H or S only', () => {
    expect(resolveGo({ key: 'h', target: null })).toBe('go-history')
    expect(resolveGo({ key: 'S', target: null })).toBe('go-settings')
    expect(resolveGo({ key: 'x', target: null })).toBeNull()
  })

  it('knows the palette key', () => {
    expect(isPaletteKey({ key: 'k', metaKey: true, target: null })).toBe(true)
    expect(isPaletteKey({ key: 'K', ctrlKey: true, target: null })).toBe(true)
    expect(isPaletteKey({ key: 'k', target: null })).toBe(false)
  })
})
