// GoelCore re-exports the platform-free contract layer so that every GoelCore
// source file — and every downstream importer (`GoelApp`, `GoelDaemon`, the
// tests) — sees the domain model, engine-seam protocols, and wire DTOs through a
// single `import GoelCore`, exactly as before the contract layer was split out.
//
// The split is a *build-graph* boundary (GoelContracts has zero platform deps, so
// iOS/Android can link it alone); it is intentionally invisible at the call site.
@_exported import GoelContracts
