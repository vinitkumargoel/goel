import { fireEvent, render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { useState } from 'react'
import { describe, expect, it, vi } from 'vitest'
import { renderWithI18n } from '../../test/renderWithI18n'
import { Art } from './Art'
import { Seg, Switch, ToggleRow } from './Controls'
import { Icon, ICON_NAMES } from './Icon'
import { Bar, Ring } from './Meter'
import { Modal } from './Modal'
import { Popover } from './Popover'
import { SpeedChart } from './SpeedChart'

describe('Icon', () => {
  it('is decorative unless labelled', () => {
    const { container } = render(<Icon name="pause" />)
    expect(container.querySelector('svg')).toHaveAttribute('aria-hidden', 'true')
    render(<Icon name="alert" label="Failed" />)
    expect(screen.getByRole('img', { name: 'Failed' })).toBeInTheDocument()
  })

  it('draws every name', () => {
    for (const name of ICON_NAMES) {
      const { container, unmount } = render(<Icon name={name} />)
      expect(container.querySelector('svg')?.innerHTML, name).not.toBe('')
      unmount()
    }
  })
})

describe('Art', () => {
  it('draws the type tile, faded and sized on request', () => {
    const { container } = render(<Art kind="video" size="l" faded />)
    expect(container.firstElementChild).toHaveClass('art', 'video', 'l', 'faded')
    expect(container.firstElementChild).toHaveAttribute('aria-hidden', 'true')
  })
})

describe('Ring and Bar', () => {
  it('report progress when labelled', () => {
    render(<Ring value={0.426} label="Progress" tone="up" />)
    const ring = screen.getByRole('progressbar', { name: 'Progress' })
    expect(ring).toHaveAttribute('aria-valuenow', '43')
    expect(ring.querySelector('svg')).toHaveClass('ring', 'up')
    render(<Bar value={0.5} label="Bar" thin />)
    expect(screen.getByRole('progressbar', { name: 'Bar' })).toHaveAttribute('aria-valuenow', '50')
  })

  it('spin, or go indeterminate, with no value, and hide when unlabelled', () => {
    const { container } = render(
      <>
        <Ring value={null} />
        <Bar value={null} label="Waiting" />
      </>,
    )
    expect(container.querySelector('.rw')).toHaveAttribute('aria-hidden', 'true')
    expect(container.querySelector('.ring')).toHaveClass('spin')
    const bar = screen.getByRole('progressbar', { name: 'Waiting' })
    expect(bar).toHaveClass('ind')
    expect(bar).not.toHaveAttribute('aria-valuenow')
  })
})

describe('Seg', () => {
  function Harness({ onChange }: { onChange: (v: string) => void }) {
    const [value, setValue] = useState<'a' | 'b' | 'c'>('a')
    return (
      <Seg
        label="Layout"
        value={value}
        onChange={(v) => {
          setValue(v)
          onChange(v)
        }}
        options={[
          { value: 'a', label: 'Board' },
          { value: 'b', label: 'Table', disabled: true },
          { value: 'c', label: 'Grid' },
        ]}
      />
    )
  }

  it('is a radio group with one tab stop; arrows skip disabled options', async () => {
    const onChange = vi.fn()
    render(<Harness onChange={onChange} />)
    expect(screen.getByRole('radiogroup', { name: 'Layout' })).toBeInTheDocument()
    const board = screen.getByRole('radio', { name: 'Board' })
    expect(board).toHaveAttribute('aria-checked', 'true')
    expect(board).toHaveAttribute('tabindex', '0')
    expect(screen.getByRole('radio', { name: 'Grid' })).toHaveAttribute('tabindex', '-1')
    board.focus()
    await userEvent.keyboard('{ArrowRight}')
    expect(onChange).toHaveBeenLastCalledWith('c')
    expect(screen.getByRole('radio', { name: 'Grid' })).toHaveFocus()
    await userEvent.keyboard('{Home}')
    expect(onChange).toHaveBeenLastCalledWith('a')
    await userEvent.click(screen.getByRole('radio', { name: 'Grid' }))
    expect(screen.getByRole('radio', { name: 'Grid' })).toHaveAttribute('aria-checked', 'true')
  })
})

describe('Switch and ToggleRow', () => {
  it('flip their state', async () => {
    const onChange = vi.fn()
    render(<Switch checked={false} onChange={onChange} label="Sequential" />)
    const sw = screen.getByRole('switch', { name: 'Sequential' })
    expect(sw).toHaveAttribute('aria-checked', 'false')
    await userEvent.click(sw)
    expect(onChange).toHaveBeenCalledWith(true)
  })

  it('names the switch by its row and describes it by the detail', () => {
    render(<ToggleRow id="seq" title="Sequential" detail="Download in order" checked onChange={vi.fn()} />)
    const sw = screen.getByRole('switch', { name: 'Sequential' })
    expect(sw).toHaveAccessibleDescription('Download in order')
    expect(sw).toHaveAttribute('aria-checked', 'true')
  })
})

describe('Modal', () => {
  it('is a labelled modal that closes on Escape and on a scrim press, not on its sheet', async () => {
    const onClose = vi.fn()
    render(
      <Modal labelledBy="t" onClose={onClose}>
        <h2 id="t">Add downloads</h2>
        <button>OK</button>
      </Modal>,
    )
    const dialog = screen.getByRole('dialog', { name: 'Add downloads' })
    expect(dialog).toHaveAttribute('aria-modal', 'true')
    fireEvent.mouseDown(dialog)
    expect(onClose).not.toHaveBeenCalled()
    fireEvent.mouseDown(dialog.parentElement!)
    expect(onClose).toHaveBeenCalledTimes(1)
    await userEvent.keyboard('{Escape}')
    expect(onClose).toHaveBeenCalledTimes(2)
  })

  it('keeps the scrim inert when it holds unsaved input', () => {
    const onClose = vi.fn()
    render(
      <Modal labelledBy="t" onClose={onClose} scrimCloses={false} role="alertdialog">
        <h2 id="t">Remove</h2>
      </Modal>,
    )
    fireEvent.mouseDown(screen.getByRole('alertdialog').parentElement!)
    expect(onClose).not.toHaveBeenCalled()
  })
})

describe('Popover', () => {
  it('opens from its trigger and closes on an outside press', async () => {
    render(
      <>
        <Popover label="Speed" trigger="S">
          chart
        </Popover>
        <button>Elsewhere</button>
      </>,
    )
    const trigger = screen.getByRole('button', { name: 'Speed' })
    await userEvent.click(trigger)
    expect(screen.getByRole('dialog', { name: 'Speed' })).toHaveTextContent('chart')
    expect(trigger).toHaveAttribute('aria-controls', screen.getByRole('dialog').id)
    await userEvent.click(screen.getByRole('button', { name: 'Elsewhere' }))
    expect(screen.queryByRole('dialog')).toBeNull()
  })
})

describe('SpeedChart', () => {
  it('names the chart with both peaks and closes the area path', () => {
    const { container } = renderWithI18n(<SpeedChart samples={[{ down: 1024, up: 0 }, { down: 2048, up: 512 }]} />)
    expect(screen.getByRole('img')).toHaveAccessibleName(/download peak 2\.0 KB\/s, upload peak 512 B\/s/)
    expect(container.querySelector('.spark .a')?.getAttribute('d')).toMatch(/Z$/)
    expect(container.querySelector('.chart-dot')).toBeInTheDocument()
  })

  it('renders an idle, empty chart without paths or dot', () => {
    const { container } = renderWithI18n(<SpeedChart samples={[]} />)
    expect(container.querySelector('.spark .l')?.getAttribute('d')).toBe('')
    expect(container.querySelector('.chart-dot')).toBeNull()
  })

  it('takes an explicit name and can leave out the upload line', () => {
    const { container } = renderWithI18n(<SpeedChart samples={[{ down: 5, up: 1 }]} label="Trend" showUp={false} />)
    expect(screen.getByRole('img', { name: 'Trend' })).toBeInTheDocument()
    expect(container.querySelector('.spark .l2')).toBeNull()
  })
})
