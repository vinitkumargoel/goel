/**
 * Dev-only fixture mode: `npm run dev`, then open `/?fixtures` (or `?fixtures=empty|loading|error|
 * offline|readonly`). Imported first by main.tsx so it can rewrite the boot values before
 * lib/boot reads them. `import.meta.env.DEV` is false in a build, so Rollup drops all of this.
 */
import { installMockServer, type FixtureMode } from './mockServer'

const MODES: readonly FixtureMode[] = ['full', 'empty', 'loading', 'error', 'offline', 'readonly']

if (import.meta.env.DEV) {
  const params = new URLSearchParams(location.search)
  if (params.has('fixtures')) {
    const asked = params.get('fixtures') ?? ''
    const mode: FixtureMode = (MODES as readonly string[]).includes(asked) ? (asked as FixtureMode) : 'full'
    const boot = document.getElementById('goel-boot')
    if (boot) {
      const values = JSON.parse(boot.textContent || '{}') as Record<string, unknown>
      values['readOnly'] = mode === 'readonly'
      values['username'] = 'admin'
      if (params.has('lang')) values['language'] = params.get('lang')
      boot.textContent = JSON.stringify(values)
    }
    if (params.has('theme')) {
      try {
        localStorage.setItem('goel-web-theme', params.get('theme') ?? 'auto')
      } catch {
        // Private mode: the stored choice wins anyway.
      }
    }
    installMockServer(mode)
  }
}
