# Ignoring paths and the doc-reuse reminder

Contents: closest notes in the doc-reuse reminder · ignoring paths (.okfignore)

## Closest notes in the doc-reuse reminder

If an `okf` search binary is on PATH (or `OKF_SEARCH_BIN` points to one), the doc-reuse reminder adds
`Closest existing notes (okf search): a, b, c.` Read those before writing a new note. No binary, a
slow one (2 s limit) or a failing one: the reminder is unchanged.

## Ignoring paths (`.okfignore`)

A `.okfignore` at the bundle root (one glob per line, `#` comments, trailing `/` = directories
only, no `/` = a name at any depth, a leading `**/` = any depth with the root, `!` unsupported) keeps paths such as `archive/` or `.trash/`
out of every layer, `okf-verify` included. The run prints `ignore: N file(s) excluded`; a file that
excludes every note exits 2. Never create it yourself: only `okf-check --init-ignore <bundle>`
writes it, once, on the owner's request.
