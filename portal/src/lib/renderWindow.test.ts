import { describe, expect, it } from 'vitest'
import { limitToInclude, windowIds, WINDOW_PAGE, WINDOW_THRESHOLD } from './renderWindow'

const ids = (n: number) => Array.from({ length: n }, (_, i) => `t${i}`)

describe('renderWindow', () => {
  it('draws a short list whole', () => {
    expect(windowIds(ids(WINDOW_THRESHOLD), 10)).toBeNull()
  })

  it('caps a long list to the first `limit` ids in order', () => {
    const set = windowIds(ids(1000), 400)!
    expect(set.size).toBe(400)
    expect(set.has('t399')).toBe(true)
    expect(set.has('t400')).toBe(false)
    expect(windowIds(ids(1000), 1000)).toBeNull()
  })

  it('widens the limit to reach an item beyond it, and leaves it when already drawn', () => {
    const order = ids(1000)
    expect(limitToInclude(order, 300, 't10')).toBe(300)
    expect(limitToInclude(order, 300, 't500')).toBe(500 + WINDOW_PAGE)
    expect(limitToInclude(order, 300, 'gone')).toBe(300)
  })
})
