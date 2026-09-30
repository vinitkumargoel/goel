import { afterEach, describe, expect, it } from 'vitest'
import { resolveShortcut } from './shortcuts'

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

  it('takes Delete from a focused row', () => {
    const row = el('<div role="option" tabindex="0"></div>')
    expect(resolveShortcut({ key: 'Delete', target: row })).toBe('remove')
  })
})
