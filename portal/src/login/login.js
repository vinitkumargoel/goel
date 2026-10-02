// The sign-in page's only script. Served as a static asset, so the portal's CSP can forbid inline
// script everywhere; RemotePortalPage renders the markup and the localized strings.
;(function () {
  'use strict'

  // A choice made in the portal (Settings → Appearance) follows this browser to the sign-in page.
  // Mirrors lib/theme.ts: the Studio values as they are, the pre-Studio ones mapped onto them.
  // Only light and dark are written; Auto leaves the server's value, which CSS already resolves.
  var LEGACY = { 'frost-light': 'light', 'frost-dark': 'dark', dracula: 'dark', nord: 'dark' }
  try {
    var stored = localStorage.getItem('goel-web-theme')
    var theme = stored && (LEGACY[stored] || stored)
    if (theme === 'light' || theme === 'dark') document.documentElement.setAttribute('data-theme', theme)
  } catch (_) {
    // Blocked storage (private mode): the server's theme stands.
  }

  var form = document.getElementById('f')
  if (!form) return

  // Rendered into data- attributes by the server; this file is cached apart from the HTML that
  // carries them, so a stale copy or a missing attribute falls back to English, never to nothing.
  function msg(name, fallback) {
    return form.dataset[name] || fallback
  }

  var password = document.getElementById('p')

  // A server-rendered error (after a failed form POST) gets the same treatment as a fetched one.
  var initial = form.querySelector('.err')
  if (initial && password) {
    initial.id = 'err'
    initial.setAttribute('role', 'alert')
    password.setAttribute('aria-describedby', 'err')
    password.select()
  }

  // Plain HTTP earns the warning; https (directly or through a TLS proxy) shows the lock instead.
  var plain = document.getElementById('plain')
  var secure = document.getElementById('secure')
  if (plain && secure && location.protocol !== 'http:') {
    plain.hidden = true
    secure.hidden = false
  }

  // Show/hide password: a constant label plus aria-pressed is the toggle-button pattern (the state
  // is announced, not a changing name). A mouse press must not pull focus out of the field.
  var eye = document.getElementById('eye')
  if (eye && password) {
    eye.addEventListener('mousedown', function (e) {
      e.preventDefault()
    })
    eye.addEventListener('click', function () {
      var reveal = password.type === 'password'
      var start = password.selectionStart
      var end = password.selectionEnd
      password.type = reveal ? 'text' : 'password'
      eye.setAttribute('aria-pressed', reveal ? 'true' : 'false')
      // Keyboard users keep focus on the toggle; a pointer click never left the field.
      if (document.activeElement === password && start !== null && end !== null) {
        password.setSelectionRange(start, end)
      }
    })
  }

  // Caps Lock is only knowable from a key event, so it is checked on every key in the field.
  var caps = document.getElementById('caps')
  if (caps && password) {
    var check = function (e) {
      if (typeof e.getModifierState !== 'function') return
      caps.hidden = !e.getModifierState('CapsLock')
    }
    password.addEventListener('keydown', check)
    password.addEventListener('keyup', check)
    password.addEventListener('blur', function () {
      caps.hidden = true
    })
  }

  function show(message) {
    var el = form.querySelector('.err')
    if (!el) {
      el = document.createElement('div')
      el.className = 'err'
      el.setAttribute('role', 'alert')
      form.insertBefore(el, form.children[1])
    }
    el.id = 'err'
    // A live region speaks only on change: a second wrong password in a row would be silent.
    // Empty it, then refill on the next frame so it is announced again.
    el.textContent = ''
    var target = el
    requestAnimationFrame(function () {
      target.textContent = message
    })
    // Most failures are a mistyped password: put the user straight back in that field.
    password.setAttribute('aria-describedby', 'err')
    password.select()
  }

  form.addEventListener('submit', function (e) {
    e.preventDefault()
    // Not the first <button>: the password field's eye toggle comes before it.
    var button = form.querySelector('button[type="submit"]')
    var idle = button.textContent
    button.disabled = true
    button.textContent = msg('msgBusy', 'Signing in…')
    form.classList.add('busy')

    var done = function () {
      button.disabled = false
      button.textContent = idle
      form.classList.remove('busy')
    }

    fetch('/login', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ username: document.getElementById('u').value, password: password.value }),
    })
      .then(function (r) {
        if (r.ok) {
          location.href = '/'
          return
        }
        return r
          .json()
          .catch(function () {
            return { error: msg('msgFailed', 'Sign-in failed') }
          })
          .then(function (j) {
            show((j && j.error) || msg('msgCredentials', 'Wrong username or password'))
            done()
          })
      })
      .catch(function () {
        show(msg('msgOffline', 'Could not reach the server'))
        done()
      })
  })
})()
