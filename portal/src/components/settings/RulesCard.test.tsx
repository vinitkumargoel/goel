import { screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { ApiError } from '../../lib/api'
import type { PortalRule } from '../../lib/types'
import en from '../../locales/en.json'
import de from '../../locales/de.json'
import { renderWithI18n } from '../../test/renderWithI18n'
import { RulesCard } from './RulesCard'

const api = vi.hoisted(() => ({ rules: vi.fn(), updateRules: vi.fn() }))

vi.mock('../../lib/api', async (importOriginal) => {
  const real = await importOriginal<typeof import('../../lib/api')>()
  return { ...real, api }
})
vi.mock('../add/FolderPicker', () => ({ FolderPicker: () => null }))

const A: PortalRule = {
  id: 'a',
  name: 'Disk images',
  enabled: true,
  match: 'all',
  conditions: [{ field: 'fileExtension', op: 'isAnyOf', value: 'dmg, pkg' }],
  tag: 'apps',
  startPaused: false,
}
const B: PortalRule = {
  id: 'b',
  name: 'Big files',
  enabled: true,
  match: 'any',
  conditions: [{ field: 'size', op: 'largerThan', value: '1 GB' }],
  folder: '/srv/big',
  startPaused: false,
  whenDone: { kind: 'runScript', locked: true },
}

function renderCard(canWrite = true) {
  const onToast = vi.fn()
  renderWithI18n(<RulesCard canWrite={canWrite} onToast={onToast} />)
  return { onToast }
}

const lastSent = (): PortalRule[] => api.updateRules.mock.calls.at(-1)![0]

beforeEach(() => {
  api.rules.mockReset().mockResolvedValue({ rules: [A, B] })
  api.updateRules.mockReset().mockImplementation(async (rules: PortalRule[]) => ({
    rules: rules.map((r, i) => ({ ...r, id: r.id ?? `new${i}` })),
  }))
})

describe('RulesCard', () => {
  it('renders nothing for a server without rules', async () => {
    api.rules.mockRejectedValue(new ApiError('http', 'nope', 404))
    renderCard()
    await waitFor(() => expect(api.rules).toHaveBeenCalled())
    expect(screen.queryByText(en.rules.title)).toBeNull()
  })

  it('lists the rules in order with a summary', async () => {
    renderCard()
    const items = await screen.findAllByRole('listitem')
    expect(items).toHaveLength(2)
    expect(items[0]).toHaveTextContent('Disk images')
    expect(items[0]).toHaveTextContent('Extension is any of dmg, pkg')
  })

  it('disables a rule and keeps a locked when-done out of the request', async () => {
    renderCard()
    const toggle = await screen.findByRole('switch', { name: 'Big files' })
    await userEvent.click(toggle)
    await waitFor(() => expect(api.updateRules).toHaveBeenCalled())
    const sent = lastSent()
    expect(sent[1]).toMatchObject({ id: 'b', enabled: false })
    expect(sent[1]).not.toHaveProperty('whenDone')
  })

  it('reorders with real buttons and disables the ends', async () => {
    renderCard()
    const up = await screen.findByRole('button', { name: 'Move rule Big files up' })
    expect(screen.getByRole('button', { name: 'Move rule Disk images up' })).toBeDisabled()
    expect(screen.getByRole('button', { name: 'Move rule Big files down' })).toBeDisabled()
    await userEvent.click(up)
    await waitFor(() => expect(lastSent().map((r) => r.id)).toEqual(['b', 'a']))
    await waitFor(() => expect(screen.getAllByRole('listitem')[0]).toHaveTextContent('Big files'))
  })

  it('deletes after confirmation', async () => {
    renderCard()
    await userEvent.click(await screen.findByRole('button', { name: 'Delete rule Disk images' }))
    expect(api.updateRules).not.toHaveBeenCalled()
    const dialog = await screen.findByRole('alertdialog')
    await userEvent.click(within(dialog).getByRole('button', { name: en.rules.delete.confirm }))
    await waitFor(() => expect(lastSent().map((r) => r.id)).toEqual(['b']))
  })

  it('adds a rule through the editor, validating first', async () => {
    renderCard()
    await userEvent.click(await screen.findByRole('button', { name: en.rules.add }))
    const dialog = await screen.findByRole('dialog', { name: en.rules.editor.addTitle })
    await userEvent.click(within(dialog).getByRole('button', { name: en.rules.editor.save }))
    expect(api.updateRules).not.toHaveBeenCalled()
    expect(within(dialog).getAllByRole('alert').length).toBeGreaterThan(0)

    await userEvent.type(within(dialog).getByLabelText(en.rules.editor.name), 'PDFs')
    await userEvent.type(within(dialog).getByLabelText('Value of condition 1'), 'pdf')
    await userEvent.type(within(dialog).getByLabelText(en.rules.editor.tag), 'docs')
    await userEvent.click(within(dialog).getByRole('button', { name: en.rules.editor.save }))
    await waitFor(() => expect(api.updateRules).toHaveBeenCalled())
    const added = lastSent().at(-1)!
    expect(added).toMatchObject({ name: 'PDFs', tag: 'docs', enabled: true, conditions: [{ field: 'fileExtension', value: 'pdf' }] })
    expect(added).not.toHaveProperty('id')
    await waitFor(() => expect(screen.queryByRole('dialog')).toBeNull())
  })

  it('edits a rule and explains a locked action', async () => {
    renderCard()
    await userEvent.click(await screen.findByRole('button', { name: 'Edit rule Big files' }))
    const dialog = await screen.findByRole('dialog')
    expect(within(dialog).getByRole('note')).toHaveTextContent(en.rules.editor.doneLocked)
    await userEvent.clear(within(dialog).getByLabelText(en.rules.editor.speed))
    await userEvent.type(within(dialog).getByLabelText(en.rules.editor.speed), '500')
    await userEvent.click(within(dialog).getByRole('button', { name: en.rules.editor.save }))
    await waitFor(() => expect(lastSent()[1]).toMatchObject({ id: 'b', speedLimitBytesPerSec: 500000 }))
    expect(lastSent()[1]).not.toHaveProperty('whenDone')
  })

  it('shows a refusal from the server and keeps the editor open', async () => {
    api.updateRules.mockRejectedValue(new ApiError('http', 'That regular expression is not valid.', 400))
    const { onToast } = renderCard()
    await userEvent.click(await screen.findByRole('button', { name: 'Edit rule Disk images' }))
    await userEvent.click(await screen.findByRole('button', { name: en.rules.editor.save }))
    await waitFor(() => expect(onToast).toHaveBeenCalledWith('That regular expression is not valid.', 'warn'))
    expect(screen.getByRole('dialog')).toBeInTheDocument()
  })

  it('is read-only without write access', async () => {
    renderCard(false)
    expect(await screen.findByRole('switch', { name: 'Disk images' })).toBeDisabled()
    expect(screen.queryByRole('button', { name: en.rules.add })).toBeNull()
    expect(screen.getByRole('button', { name: 'Edit rule Disk images' })).toBeDisabled()
  })
})

describe('rules strings', () => {
  it('have a German twin for every key', () => {
    const keys = (o: object, p = ''): string[] =>
      Object.entries(o).flatMap(([k, v]) => (typeof v === 'object' ? keys(v, `${p}${k}.`) : [`${p}${k}`]))
    expect(keys(de.rules)).toEqual(keys(en.rules))
  })
})
