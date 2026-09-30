import { afterEach, describe, expect, it, vi } from 'vitest'
import source from './login.js?raw'

// Mirrors the markup RemotePortalPage.loginPage renders (the parts login.js touches).
const markup = `
<form class="card" id="f">
  <div class="fld"><label for="u">Username</label><input id="u" name="username"></div>
  <div class="fld"><label for="p">Password</label><div class="pw"><input id="p" name="password" type="password"><button type="button" class="eye" id="eye" aria-controls="p" aria-pressed="false" aria-label="Show password"></button></div>
  <div class="caps" id="caps" role="status" hidden>Caps Lock is on</div></div>
  <button type="submit" id="submit">Sign in</button>
  <div class="foot"><span id="plain">Plain HTTP</span><span id="secure" hidden>Secure connection</span></div>
</form>`

function boot(protocol = 'http:') {
  document.body.innerHTML = markup
  // The script reads the bare `location` global; hand it one with the protocol under test.
  new Function('location', source)({ protocol, href: '' })
  return {
    password: document.getElementById('p') as HTMLInputElement,
    eye: document.getElementById('eye') as HTMLButtonElement,
    caps: document.getElementById('caps') as HTMLElement,
    plain: document.getElementById('plain') as HTMLElement,
    secure: document.getElementById('secure') as HTMLElement,
  }
}

function key(type: 'keydown' | 'keyup', capsOn: boolean) {
  return new KeyboardEvent(type, { key: 'a', modifierCapsLock: capsOn, bubbles: true })
}

afterEach(() => {
  document.body.innerHTML = ''
  vi.unstubAllGlobals()
})

describe('login page script', () => {
  it('toggles password visibility with aria-pressed and keeps the caret', () => {
    const { password, eye } = boot()
    password.value = 'hunter2'
    password.focus()
    password.setSelectionRange(3, 3)

    eye.click()
    expect(password.type).toBe('text')
    expect(eye.getAttribute('aria-pressed')).toBe('true')
    expect(eye.getAttribute('aria-label')).toBe('Show password')
    expect(document.activeElement).toBe(password)
    expect(password.selectionStart).toBe(3)

    eye.click()
    expect(password.type).toBe('password')
    expect(eye.getAttribute('aria-pressed')).toBe('false')
  })

  it('does not let a mouse press on the toggle steal focus from the field', () => {
    const { password, eye } = boot()
    password.focus()
    const down = new MouseEvent('mousedown', { bubbles: true, cancelable: true })
    eye.dispatchEvent(down)
    expect(down.defaultPrevented).toBe(true)
  })

  it('shows the caps-lock warning from the key event state and hides it on blur', () => {
    const { password, caps } = boot()
    expect(caps.hidden).toBe(true)
    password.dispatchEvent(key('keydown', true))
    expect(caps.hidden).toBe(false)
    password.dispatchEvent(key('keyup', false))
    expect(caps.hidden).toBe(true)
    password.dispatchEvent(key('keyup', true))
    password.dispatchEvent(new FocusEvent('blur'))
    expect(caps.hidden).toBe(true)
  })

  it('warns about plain HTTP only over http:', () => {
    const http = boot('http:')
    expect(http.plain.hidden).toBe(false)
    expect(http.secure.hidden).toBe(true)

    const https = boot('https:')
    expect(https.plain.hidden).toBe(true)
    expect(https.secure.hidden).toBe(false)
  })

  it('still finds the submit button now that the eye toggle precedes it', () => {
    // A request that never settles: the busy state is what is under test.
    vi.stubGlobal('fetch', () => new Promise(() => {}))
    boot()
    const submit = document.getElementById('submit') as HTMLButtonElement
    const form = document.getElementById('f') as HTMLFormElement
    form.dispatchEvent(new Event('submit', { cancelable: true }))
    expect(submit.disabled).toBe(true)
    expect((document.getElementById('eye') as HTMLButtonElement).disabled).toBe(false)
  })
})
