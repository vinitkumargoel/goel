import { describe, expect, it } from 'vitest'
import { fuzzyScore, rankCommands, type PaletteCommand } from './palette'

const cmd = (id: string, group: PaletteCommand['group'], label: string, keywords?: string): PaletteCommand => ({
  id,
  group,
  label,
  keywords,
  run: () => {},
})

describe('fuzzyScore', () => {
  it('matches in-order characters and rejects anything else', () => {
    expect(fuzzyScore('ubi', 'ubuntu.iso')).not.toBeNull()
    expect(fuzzyScore('ubu', 'Group by: Status')).toBeNull()
    expect(fuzzyScore('osi', 'ubuntu.iso')).toBeNull()
  })

  it('needs every word to match', () => {
    expect(fuzzyScore('ubu iso', 'ubuntu-24.04.iso')).not.toBeNull()
    expect(fuzzyScore('ubu mkv', 'ubuntu-24.04.iso')).toBeNull()
  })

  it('ranks substrings, and word starts, above scattered letters', () => {
    const substring = fuzzyScore('iso', 'ubuntu.iso')!
    const scattered = fuzzyScore('iso', 'i-see-oranges')!
    expect(substring).toBeGreaterThan(scattered)
    expect(fuzzyScore('set', 'Settings')!).toBeGreaterThan(fuzzyScore('set', 'Reset')!)
  })
})

describe('rankCommands', () => {
  const commands = [
    cmd('add', 'add', 'Add download'),
    cmd('t1', 'downloads', 'ubuntu.iso'),
    cmd('t2', 'downloads', 'fedora.iso'),
    cmd('history', 'view', 'History'),
    cmd('dark', 'settings', 'Theme: Dark', 'appearance'),
  ]

  it('shows everything except downloads with no query', () => {
    expect(rankCommands(commands, '').map((g) => g.group)).toEqual(['add', 'view', 'settings'])
  })

  it('finds downloads by name and settings by keyword', () => {
    const groups = rankCommands(commands, 'iso')
    expect(groups[0]).toEqual({ group: 'downloads', commands: [commands[1], commands[2]] })
    expect(rankCommands(commands, 'appear')[0]?.commands[0]?.id).toBe('dark')
  })

  it('caps each group', () => {
    const many = Array.from({ length: 20 }, (_, i) => cmd(`t${i}`, 'downloads', `file ${i}`))
    expect(rankCommands(many, 'file', 5)[0]?.commands).toHaveLength(5)
  })
})
