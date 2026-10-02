import { fireEvent, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import en from '../../locales/en.json'
import { ApiError } from '../../lib/api'
import type { ScheduleState } from '../../lib/types'
import { renderWithI18n } from '../../test/renderWithI18n'
import { brushColor } from './scheduleBrush'
import { ScheduleCard } from './ScheduleCard'

const api = vi.hoisted(() => ({ schedule: vi.fn(), updateSchedule: vi.fn() }))

vi.mock('../../lib/api', async (importOriginal) => {
  const real = await importOriginal<typeof import('../../lib/api')>()
  return { ...real, api }
})

const STATE: ScheduleState = {
  enabled: true,
  startMinute: 60,
  endMinute: 420,
  days: [1, 2, 3, 4, 5, 6, 7],
  profile: 'Night',
  profiles: ['Low', 'Night'],
}

function cell(day: string, hour: string) {
  return screen.getByRole('gridcell', { name: new RegExp(`^${day} ${hour}:00`) })
}

describe('ScheduleCard', () => {
  beforeEach(() => {
    api.schedule.mockReset()
    api.updateSchedule.mockReset()
  })

  it('paints the open hours of the window, and sums it up', async () => {
    api.schedule.mockResolvedValue(STATE)
    renderWithI18n(<ScheduleCard canWrite onToast={vi.fn()} onDirty={vi.fn()} />)
    await screen.findByRole('grid')
    expect(cell('Mon', '03').className).toContain('open')
    expect(cell('Mon', '03')).toHaveAccessibleName(`Mon 03:00: ${en.schedule.open}`)
    expect(cell('Mon', '12').className).not.toContain('open')
    expect(screen.getByText('01:00 – 07:00')).toBeInTheDocument()
  })

  it('paints a dragged range into the draft and saves it', async () => {
    api.schedule.mockResolvedValue(STATE)
    api.updateSchedule.mockImplementation((body) => Promise.resolve({ ...STATE, ...body }))
    const onDirty = vi.fn()
    const onToast = vi.fn()
    renderWithI18n(<ScheduleCard canWrite onToast={onToast} onDirty={onDirty} />)
    await screen.findByRole('grid')
    fireEvent.pointerDown(cell('Tue', '09'))
    fireEvent.pointerUp(window)
    await waitFor(() => expect(onDirty).toHaveBeenLastCalledWith(true))
    fireEvent.click(screen.getByRole('button', { name: 'Save' }))
    await waitFor(() => expect(api.updateSchedule).toHaveBeenCalled())
    expect(api.updateSchedule.mock.calls[0]![0]).toMatchObject({ startMinute: 540, endMinute: 600, enabled: true })
    await waitFor(() => expect(onToast).toHaveBeenCalledWith(en.schedule.saved))
    await waitFor(() => expect(onDirty).toHaveBeenLastCalledWith(false))
  })

  it('edits the window, days and profile from the controls, and Discard undoes it', async () => {
    api.schedule.mockResolvedValue(STATE)
    const onDirty = vi.fn()
    renderWithI18n(<ScheduleCard canWrite onToast={vi.fn()} onDirty={onDirty} />)
    await screen.findByRole('grid')
    await userEvent.selectOptions(screen.getByLabelText(en.schedule.from), '22')
    expect(screen.getByText('22:00 – 07:00')).toBeInTheDocument()
    const sunday = screen.getByRole('rowheader', { name: 'Sun' })
    expect(sunday).toHaveAttribute('aria-pressed', 'true')
    await userEvent.click(sunday)
    expect(sunday).toHaveAttribute('aria-pressed', 'false')
    await userEvent.click(screen.getByRole('radio', { name: en.schedule.profileKeep }))
    expect(screen.getByRole('radio', { name: en.schedule.profileKeep })).toHaveAttribute('aria-checked', 'true')
    expect(onDirty).toHaveBeenLastCalledWith(true)
    await userEvent.click(screen.getByRole('button', { name: en.settings.discard }))
    expect(screen.getByText('01:00 – 07:00')).toBeInTheDocument()
    expect(sunday).toHaveAttribute('aria-pressed', 'true')
    expect(onDirty).toHaveBeenLastCalledWith(false)
  })

  it('switches the schedule off in the draft', async () => {
    api.schedule.mockResolvedValue(STATE)
    api.updateSchedule.mockImplementation((body) => Promise.resolve({ ...STATE, ...body }))
    renderWithI18n(<ScheduleCard canWrite onToast={vi.fn()} onDirty={vi.fn()} />)
    await userEvent.click(await screen.findByRole('switch', { name: en.schedule.enabled }))
    await userEvent.click(screen.getByRole('button', { name: en.common.save }))
    expect(api.updateSchedule.mock.calls[0]![0]).toMatchObject({ enabled: false })
  })

  it('says All day when the window is the whole day', async () => {
    api.schedule.mockResolvedValue({ ...STATE, startMinute: 0, endMinute: 0 })
    renderWithI18n(<ScheduleCard canWrite onToast={vi.fn()} onDirty={vi.fn()} />)
    expect(await screen.findByText(en.schedule.allDay)).toBeInTheDocument()
  })

  it('is read-only without write access', async () => {
    api.schedule.mockResolvedValue(STATE)
    renderWithI18n(<ScheduleCard canWrite={false} onToast={vi.fn()} onDirty={vi.fn()} />)
    await screen.findByRole('grid')
    expect(screen.getByRole('switch', { name: /schedule/i })).toBeDisabled()
    expect(screen.getByRole('grid')).toHaveAttribute('aria-readonly', 'true')
    fireEvent.pointerDown(cell('Tue', '09'))
    fireEvent.pointerUp(window)
    expect(cell('Tue', '09').className).not.toContain('open')
    expect(screen.queryByRole('button', { name: 'Save' })).toBeNull()
  })

  it('warns when saving fails', async () => {
    api.schedule.mockResolvedValue(STATE)
    api.updateSchedule.mockRejectedValue(new Error('Refused'))
    const onToast = vi.fn()
    renderWithI18n(<ScheduleCard canWrite onToast={onToast} onDirty={vi.fn()} />)
    await userEvent.click(await screen.findByRole('switch', { name: en.schedule.enabled }))
    await userEvent.click(screen.getByRole('button', { name: en.common.save }))
    await waitFor(() => expect(onToast).toHaveBeenCalledWith(expect.any(String), 'warn'))
  })

  it('stays away on a server without a scheduler', async () => {
    api.schedule.mockRejectedValue(new ApiError('http', 'Not found', 404))
    const { container } = renderWithI18n(<ScheduleCard canWrite onToast={vi.fn()} onDirty={vi.fn()} />)
    await waitFor(() => expect(api.schedule).toHaveBeenCalled())
    expect(container.textContent).toBe('')
  })

  it('says so when the schedule cannot be read', async () => {
    api.schedule.mockRejectedValue(new ApiError('http', 'Boom', 500))
    renderWithI18n(<ScheduleCard canWrite onToast={vi.fn()} onDirty={vi.fn()} />)
    expect(await screen.findByRole('alert')).toHaveTextContent(en.api.actionFailed)
  })
})

describe('brushColor', () => {
  it('gives each profile a stable token colour, and Keep current the accent', () => {
    expect(brushColor('', ['Low'])).toBe('var(--accent)')
    expect(brushColor('Low', ['Low', 'High'])).toBe('var(--up)')
    expect(brushColor('Gone', ['Low'])).toBe(brushColor('Gone', ['Low']))
    expect(brushColor('Gone', ['Low'])).toMatch(/^var\(--/)
  })
})
