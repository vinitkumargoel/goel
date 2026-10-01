import { fireEvent, screen, waitFor } from '@testing-library/react'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { ApiError } from '../lib/api'
import type { ScheduleState } from '../lib/types'
import { renderWithI18n } from '../test/renderWithI18n'
import { ScheduleCard } from './ScheduleCard'

const api = vi.hoisted(() => ({ schedule: vi.fn(), updateSchedule: vi.fn() }))

vi.mock('../lib/api', async (importOriginal) => {
  const real = await importOriginal<typeof import('../lib/api')>()
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

  it('paints the open hours of the window', async () => {
    api.schedule.mockResolvedValue(STATE)
    renderWithI18n(<ScheduleCard canWrite onToast={vi.fn()} onDirty={vi.fn()} />)
    await screen.findByRole('grid')
    expect(cell('Mon', '03').className).toContain('open')
    expect(cell('Mon', '12').className).not.toContain('open')
  })

  it('paints a dragged range into the draft and saves it', async () => {
    api.schedule.mockResolvedValue(STATE)
    api.updateSchedule.mockImplementation((body) => Promise.resolve({ ...STATE, ...body }))
    const onDirty = vi.fn()
    renderWithI18n(<ScheduleCard canWrite onToast={vi.fn()} onDirty={onDirty} />)
    await screen.findByRole('grid')
    fireEvent.pointerDown(cell('Tue', '09'))
    fireEvent.pointerUp(window)
    await waitFor(() => expect(onDirty).toHaveBeenLastCalledWith(true))
    fireEvent.click(screen.getByRole('button', { name: 'Save' }))
    await waitFor(() => expect(api.updateSchedule).toHaveBeenCalled())
    expect(api.updateSchedule.mock.calls[0]![0]).toMatchObject({ startMinute: 540, endMinute: 600, enabled: true })
  })

  it('is read-only without write access', async () => {
    api.schedule.mockResolvedValue(STATE)
    renderWithI18n(<ScheduleCard canWrite={false} onToast={vi.fn()} onDirty={vi.fn()} />)
    await screen.findByRole('grid')
    expect(screen.getByRole('checkbox', { name: /schedule/i })).toBeDisabled()
    fireEvent.pointerDown(cell('Tue', '09'))
    fireEvent.pointerUp(window)
    expect(screen.queryByRole('button', { name: 'Save' })).toBeNull()
  })

  it('stays away on a server without a scheduler', async () => {
    api.schedule.mockRejectedValue(new ApiError('http', 'Not found', 404))
    const { container } = renderWithI18n(<ScheduleCard canWrite onToast={vi.fn()} onDirty={vi.fn()} />)
    await waitFor(() => expect(api.schedule).toHaveBeenCalled())
    expect(container.textContent).toBe('')
  })
})
