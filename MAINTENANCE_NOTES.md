# marimo.nvim Maintenance Notes

Date: 2026-04-06

This document is an implementation review only. No significant behavior changes were made while preparing it.

## High-priority observations

- `lua/marimo/init.lua`: `run_all_cells()` loops `for i = 0, #session.cell_ids`.
  - This is off-by-one for 0-based indexing, because valid indices are `0 .. (#session.cell_ids - 1)`.
  - Current behavior can hit one extra iteration, fail to parse code for that index, notify warning, and return early.
  - Suggested fix: iterate `for i = 0, #session.cell_ids - 1 do` and optionally no-op when `#session.cell_ids == 0`.

- `lua/marimo/session.lua`: `focus_cell` feature detection currently keys off a single 404 and then disables focus for the session (`_focus_cell_supported = false`).
  - This is pragmatic and reduces noise.
  - Caveat: if a 404 is caused by wrong server/port during a transient state, focus remains disabled until reconnect.
  - Suggested follow-up: optionally expose this state in `:MarimoStatus` so users immediately understand why follow mode is inactive.

## Medium-priority observations

- `lua/marimo/server.lua` + `lua/marimo/session.lua`: duplicate `uri_encode()` implementations.
  - Suggested simplification: move to a small shared utility module.

- `lua/marimo/session.lua`: duplicated HTTP POST/curl logic between `focus_cell` and `run_cell`.
  - `focus_cell` now has robust status/body reporting; `run_cell` still uses `curl -sf` and loses HTTP diagnostics.
  - Suggested simplification: centralize a reusable request helper (headers, token handling, status extraction, error formatting).

- `lua/marimo/server.lua`: function docs mention fallback to `ss`/`lsof` for port detection, but implementation currently only uses `/proc` and default port.
  - This is doc/implementation drift.

> Implement fallback.

- `lua/marimo/server.lua`: `M.start(file_path, opts, callback)` accepts `opts` but does not use it.
  - Suggested cleanup: remove parameter or use it for launch-time overrides.

> Investigate its original intent and either implement or remove.

## Low-priority observations

- `lua/marimo/config.lua`: `setup()` merges into `M.opts` in-place.
  - If users call `setup()` multiple times, options accumulate from prior calls.
  - This is common in plugins, but can surprise tests/reloads.

> Keep immutable defaults and rebuild `M.opts` from defaults each setup call.

- `lua/marimo/commands.lua`: top doc comment does not list `:MarimoRunAll` even though the command exists.

> Keep command docs synchronized with implementation.

- `lua/marimo/session.lua`: `stderr_pipe:read_start(function(_, data) if data then end end)` is effectively a no-op.

> Investigate its original intent and either implement or remove.

## File-by-file summary

- `plugin/marimo.lua`
  - Minimal and clean plugin entrypoint.

- `lua/marimo/commands.lua`
  - Clear command registration; update docs to include all commands.

- `lua/marimo/config.lua`
  - Small and readable config surface; consider immutable defaults pattern.

- `lua/marimo/events.lua`
  - Good guardrails for session churn and redundant cursor events.
  - Nice use of per-buffer augroups.

- `lua/marimo/parser.lua`
  - Clear and focused extraction logic.
  - Main risk is repeated full-buffer scans (`get_cell_ranges`) for every operation; acceptable for moderate files, but cache/invalidation could help very large notebooks.

- `lua/marimo/server.lua`
  - Good process lifecycle handling and PID persistence.
  - Main follow-ups are doc drift + small API consistency cleanups.

- `lua/marimo/session.lua`
  - Most complex module; reconnection/generation handling is thoughtful.
  - Good recent improvements in `focus_cell` diagnostics.
  - Worth extracting shared HTTP helpers to reduce branching complexity.

- `lua/marimo/init.lua`
  - User-facing API is straightforward.
  - `run_all_cells()` off-by-one loop should be addressed first.

## Suggested cleanup order (later PRs)

1. Fix `run_all_cells()` indexing bug.
2. Unify HTTP request handling for `focus_cell`/`run_cell`.
3. Align `is_running()` port resolution with `connect()`.
4. Resolve comment drift (`ss`/`lsof`, command list, old PR references).
5. Optional refactors (shared `uri_encode`, config default reset pattern, parser caching).
