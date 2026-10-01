/**
 * Multi-selection for the download list, as a pure reducer so the Shift/⌘ rules are testable
 * without a DOM. `lead` is the row the detail panel shows and the anchor a Shift range grows from.
 */
export interface Selection {
  ids: ReadonlySet<string>
  lead: string | null
}

export type SelectionAction =
  /** Plain click or arrow key: this row only. */
  | { type: 'single'; id: string }
  /** ⌘/Ctrl-click or Space: add or drop one row, keeping the rest. */
  | { type: 'toggle'; id: string }
  /** Shift-click or Shift+arrow: everything between the lead and this row, in visible order. */
  | { type: 'range'; id: string; order: readonly string[] }
  | { type: 'all'; order: readonly string[] }
  /** Exactly these rows, the first as lead: e.g. the downloads just added. */
  | { type: 'set'; ids: readonly string[] }
  | { type: 'clear' }
  /** Drops ids that are no longer in the list, e.g. after a remove or a snapshot. */
  | { type: 'prune'; existing: readonly string[] }

export const EMPTY_SELECTION: Selection = { ids: new Set(), lead: null }

export function selectionReducer(state: Selection, action: SelectionAction): Selection {
  switch (action.type) {
    case 'single':
      return { ids: new Set([action.id]), lead: action.id }

    case 'toggle': {
      const ids = new Set(state.ids)
      if (ids.has(action.id)) {
        ids.delete(action.id)
        const lead = state.lead === action.id ? (lastOf(ids) ?? null) : state.lead
        return { ids, lead }
      }
      ids.add(action.id)
      return { ids, lead: action.id }
    }

    case 'range': {
      const from = state.lead == null ? -1 : action.order.indexOf(state.lead)
      const to = action.order.indexOf(action.id)
      if (to < 0) return state
      if (from < 0) return { ids: new Set([action.id]), lead: action.id }
      const [lo, hi] = from <= to ? [from, to] : [to, from]
      // The lead stays put so a second Shift-click re-ranges from the same anchor, as in Finder.
      return { ids: new Set(action.order.slice(lo, hi + 1)), lead: state.lead }
    }

    case 'all':
      if (action.order.length === 0) return EMPTY_SELECTION
      return {
        ids: new Set(action.order),
        lead: state.lead != null && action.order.includes(state.lead) ? state.lead : action.order[0]!,
      }

    case 'set':
      if (action.ids.length === 0) return EMPTY_SELECTION
      return { ids: new Set(action.ids), lead: action.ids[0]! }

    case 'clear':
      return EMPTY_SELECTION

    case 'prune': {
      const existing = new Set(action.existing)
      const ids = new Set([...state.ids].filter((id) => existing.has(id)))
      const lead = state.lead != null && existing.has(state.lead) ? state.lead : null
      if (ids.size === state.ids.size && lead === state.lead) return state
      return { ids, lead }
    }
  }
}

function lastOf(ids: ReadonlySet<string>): string | undefined {
  let last: string | undefined
  for (const id of ids) last = id
  return last
}

/** Maps a pointer click's modifiers to the reducer action a desktop list would take. */
export function clickAction(
  id: string,
  mods: { shift: boolean; toggle: boolean },
  order: readonly string[],
): SelectionAction {
  if (mods.shift) return { type: 'range', id, order }
  if (mods.toggle) return { type: 'toggle', id }
  return { type: 'single', id }
}
