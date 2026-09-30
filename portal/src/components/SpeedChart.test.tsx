import { screen } from '@testing-library/react'
import { describe, expect, it } from 'vitest'
import { renderWithI18n } from '../test/renderWithI18n'
import { Sparkline, SpeedChart } from './SpeedChart'

describe('SpeedChart', () => {
  it('names the chart with both peaks and labels the time axis', () => {
    const { container } = renderWithI18n(
      <SpeedChart samples={[{ down: 1024, up: 0 }, { down: 2048, up: 512 }]} />,
    )
    const img = screen.getByRole('img')
    expect(img).toHaveAccessibleName(/download peak 2\.0 KB\/s, upload peak 512 B\/s/)
    expect(screen.getByText('Peak 2.0 KB/s')).toBeInTheDocument()
    expect(screen.getByText('60s ago')).toBeInTheDocument()
    expect(screen.getByText('now')).toBeInTheDocument()
    expect(container.querySelector('.schart-area')?.getAttribute('d')).toMatch(/Z$/)
  })

  it('renders an idle, empty chart without paths', () => {
    const { container } = renderWithI18n(<SpeedChart samples={[]} />)
    expect(screen.getByText('Peak 0 B/s')).toBeInTheDocument()
    expect(container.querySelector('.schart-down')?.getAttribute('d')).toBe('')
  })
})

describe('Sparkline', () => {
  it('is a named image', () => {
    renderWithI18n(<Sparkline samples={[{ down: 5, up: 0 }]} label="Trend" />)
    expect(screen.getByRole('img', { name: 'Trend' })).toBeInTheDocument()
  })
})
