import { fireEvent, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it, vi } from 'vitest'
import { toLocalInput } from '../../lib/queueControls'
import en from '../../locales/en.json'
import { makeTask } from '../../test/makeTask'
import { renderWithI18n } from '../../test/renderWithI18n'
import { QueueDialog, StartPicker, type QueueEdit } from './QueueDialogs'

function renderEdit(edit: QueueEdit, tasks = [makeTask('a')]) {
  const handlers = { onSpeed: vi.fn(), onTags: vi.fn(), onStart: vi.fn() }
  const onClose = vi.fn()
  renderWithI18n(<QueueDialog edit={edit} tasks={tasks} onClose={onClose} handlers={handlers} />)
  return { ...handlers, onClose }
}

describe('QueueDialog', () => {
  it('renders nothing without an edit', () => {
    renderWithI18n(
      <QueueDialog edit={null} tasks={[]} onClose={vi.fn()} handlers={{ onSpeed: vi.fn(), onTags: vi.fn(), onStart: vi.fn() }} />,
    )
    expect(screen.queryByRole('dialog')).toBeNull()
  })

  describe('speed', () => {
    it('saves a limit in the chosen unit and closes', async () => {
      const task = makeTask('a', { name: 'big.iso' })
      const h = renderEdit({ kind: 'speed', task })
      const dialog = screen.getByRole('dialog', { name: en.queue.speedTitle })
      expect(within(dialog).getByText('big.iso')).toBeInTheDocument()
      const field = screen.getByLabelText(en.queue.speedLabel)
      expect(field).toHaveFocus()
      await userEvent.type(field, '512')
      await userEvent.click(screen.getByRole('radio', { name: 'KB/s' }))
      await userEvent.click(screen.getByRole('button', { name: en.common.save }))
      expect(h.onClose).toHaveBeenCalled()
      expect(h.onSpeed).toHaveBeenCalledWith(task, 512 * 1024)
    })

    it('refuses an unreadable number', async () => {
      const h = renderEdit({ kind: 'speed', task: makeTask('a') })
      await userEvent.type(screen.getByLabelText(en.queue.speedLabel), 'fast')
      expect(screen.getByLabelText(en.queue.speedLabel)).toHaveAttribute('aria-invalid', 'true')
      expect(screen.getByRole('button', { name: en.common.save })).toBeDisabled()
      await userEvent.keyboard('{Enter}')
      expect(h.onSpeed).not.toHaveBeenCalled()
    })

    it('pre-fills a set limit and offers to clear it', async () => {
      const task = makeTask('a', { speedLimit: 2 * 1024 * 1024 })
      const h = renderEdit({ kind: 'speed', task })
      expect(screen.getByLabelText(en.queue.speedLabel)).toHaveValue('2')
      expect(screen.getByRole('radio', { name: 'MB/s' })).toBeChecked()
      await userEvent.click(screen.getByRole('button', { name: en.queue.noLimit }))
      expect(h.onSpeed).toHaveBeenCalledWith(task, null)
      expect(h.onClose).toHaveBeenCalled()
    })

    it('has no clear button without a limit, and Escape closes without saving', async () => {
      const h = renderEdit({ kind: 'speed', task: makeTask('a') })
      expect(screen.queryByRole('button', { name: en.queue.noLimit })).toBeNull()
      await userEvent.keyboard('{Escape}')
      expect(h.onClose).toHaveBeenCalled()
      expect(h.onSpeed).not.toHaveBeenCalled()
    })
  })

  describe('tags', () => {
    it('edits tags as chips and suggests the queue’s other tags', async () => {
      const task = makeTask('a', { tags: ['linux'] })
      const tasks = [task, makeTask('b', { tags: ['tv', 'Linux'] }), makeTask('c', { tags: ['tv'] })]
      const h = renderEdit({ kind: 'tags', task }, tasks)
      const field = screen.getByLabelText(en.queue.tagsLabel, { selector: 'input' })
      expect(field).toHaveValue('linux')
      const current = screen.getByRole('group', { name: en.queue.tagsCurrent })
      expect(within(current).getByRole('button', { name: 'Remove tag linux' })).toBeInTheDocument()
      // "Linux" is already on it, whatever the case; "tv" is offered.
      expect(screen.queryByRole('button', { name: 'Linux' })).toBeNull()
      await userEvent.click(screen.getByRole('button', { name: 'tv' }))
      expect(field).toHaveValue('linux, tv')
      await userEvent.click(screen.getByRole('button', { name: 'Remove tag linux' }))
      expect(field).toHaveValue('tv')
      await userEvent.click(screen.getByRole('button', { name: en.common.save }))
      expect(h.onTags).toHaveBeenCalledWith(task, ['tv'])
    })

    it('drops blanks and repeats', async () => {
      const task = makeTask('a')
      const h = renderEdit({ kind: 'tags', task })
      await userEvent.type(screen.getByLabelText(en.queue.tagsLabel, { selector: 'input' }), 'a, , A, b{Enter}')
      expect(h.onTags).toHaveBeenCalledWith(task, ['a', 'b'])
    })

    it('offers at most twelve suggestions', () => {
      const tags = Array.from({ length: 15 }, (_, i) => `t${String(i).padStart(2, '0')}`)
      renderEdit({ kind: 'tags', task: makeTask('a') }, [makeTask('a'), makeTask('b', { tags })])
      expect(screen.getAllByRole('button', { name: /^t\d\d$/ })).toHaveLength(12)
    })
  })

  describe('start', () => {
    it('starts now, tonight, or at a custom time', async () => {
      const task = makeTask('a')
      const h = renderEdit({ kind: 'start', task })
      expect(screen.getByRole('radio', { name: en.queue.startNow })).toBeChecked()
      await userEvent.click(screen.getByRole('radio', { name: 'Tonight 01:00' }))
      await userEvent.click(screen.getByRole('button', { name: en.common.save }))
      const at = h.onStart.mock.calls[0]?.[1] as Date
      expect(at.getHours()).toBe(1)
      expect(at.getTime()).toBeGreaterThan(Date.now())
    })

    it('says when it is held and refuses a past custom time', async () => {
      const startAt = Math.floor(Date.now() / 1000) + 3600
      const h = renderEdit({ kind: 'start', task: makeTask('a', { startAt }) })
      expect(screen.getByRole('radio', { name: en.queue.startCustom })).toBeChecked()
      expect(screen.getByText(/Currently held until/)).toBeInTheDocument()
      const input = screen.getByLabelText(en.queue.startCustom, { selector: 'input' })
      fireEvent.change(input, { target: { value: '2001-01-01T10:00' } })
      expect(input).toHaveAttribute('aria-invalid', 'true')
      expect(screen.getByRole('button', { name: en.common.save })).toBeDisabled()
      const later = new Date(Date.now() + 2 * 3600_000)
      fireEvent.change(input, { target: { value: toLocalInput(later) } })
      await userEvent.click(screen.getByRole('button', { name: en.common.save }))
      expect((h.onStart.mock.calls[0]?.[1] as Date).getTime()).toBeGreaterThan(Date.now())
    })

    it('clears a hold with Now', async () => {
      const task = makeTask('a', { startAt: Math.floor(Date.now() / 1000) + 3600 })
      const h = renderEdit({ kind: 'start', task })
      await userEvent.click(screen.getByRole('radio', { name: en.queue.startNow }))
      await userEvent.click(screen.getByRole('button', { name: en.common.save }))
      expect(h.onStart).toHaveBeenCalledWith(task, null)
    })
  })

  describe('cap', () => {
    it('saves both directions, blank as no limit', async () => {
      const onSave = vi.fn()
      renderEdit({ kind: 'cap', down: 1024 * 1024, up: null, onSave })
      expect(screen.getByRole('dialog', { name: en.queue.capTitle })).toBeInTheDocument()
      expect(screen.getByLabelText(`↓ ${en.chart.down}`)).toHaveValue('1')
      expect(screen.getByLabelText(`↑ ${en.chart.up}`)).toHaveValue('')
      await userEvent.type(screen.getByLabelText(`↑ ${en.chart.up}`), '200')
      const kb = screen.getAllByRole('radio', { name: 'KB/s' })[1]!
      await userEvent.click(kb)
      await userEvent.click(screen.getByRole('button', { name: en.common.save }))
      expect(onSave).toHaveBeenCalledWith(1024 * 1024, 200 * 1024)
    })
  })
})

describe('StartPicker', () => {
  it('reports each choice and whether it is usable', async () => {
    const onChange = vi.fn()
    renderWithI18n(<StartPicker initial={null} onChange={onChange} />)
    await userEvent.click(screen.getByRole('radio', { name: en.queue.startCustom }))
    expect(onChange).toHaveBeenLastCalledWith(expect.any(Date), true)
    fireEvent.change(screen.getByLabelText(en.queue.startCustom, { selector: 'input' }), { target: { value: 'nope' } })
    expect(onChange).toHaveBeenLastCalledWith(null, false)
    await userEvent.click(screen.getByRole('radio', { name: en.queue.startNow }))
    expect(onChange).toHaveBeenLastCalledWith(null, true)
  })
})
