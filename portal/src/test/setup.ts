import '@testing-library/jest-dom/vitest'
import { cleanup } from '@testing-library/react'
import { afterEach } from 'vitest'

// Vitest does not auto-clean between tests when `globals: false`.
afterEach(() => {
  cleanup()
})
