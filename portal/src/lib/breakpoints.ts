/**
 * The portal's two layout breakpoints, shared by the stylesheets and the code that must agree
 * with them (keep the numbers in step with the `@media` rules in styles/).
 *
 * - phone  ≤ 600px: one column, lanes stacked, the rail becomes a bottom tab bar and a drawer,
 *   the detail opens as a full-screen sheet.
 * - narrow ≤ 920px: the detail sheet floats over the board instead of sitting beside it.
 */
export const PHONE_MAX = 600
export const NARROW_MAX = 920

export const PHONE_QUERY = `(max-width: ${PHONE_MAX}px)`
export const NARROW_QUERY = `(max-width: ${NARROW_MAX}px)`
