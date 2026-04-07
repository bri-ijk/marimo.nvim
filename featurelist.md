# Features to add

- Fail to start server if there are unparseable cells in the buffer
  - search for "app.\_unparsable_cell" or find some other way to detect this cleanly
  - Prompt the user to fix them before trying to run the server
- Run stale cells
- Run cells corresponding to the visual selection range of the buffer
- Target and run all markdown cells in the buffer
  - option to automatically execute all markdown cells on marimo start/attach
- Run current cells' dependencies
- Toggle disable/enable on current cell
- Extract code from all cells in the buffer and craft a single script to run
  - prompt the user to deal with elements first:
    1. unparseable cells - include? how to format? comments? something else?
    2. markdown cells - should they be included in the script? If so, how should they be formatted? docstrings? comments? something else?
    3. disabled cells - should they be included in the script? If so, how should they be formatted? comments? something else?
    4. redundant imports, variables, functions, etc. - should they be included in the script? If so, how should they be formatted? comments? something else?

## Feasibility Assessment

Sorted from easiest/highest-feasibility to hardest/lowest-feasibility.

### 1) Run cells corresponding to the visual selection range of the buffer

**Feasibility:** Very high

Why:
- The plugin already has `parser.get_cell_ranges(bufnr)` and `session:run_cell(index, code)`.
- This is mostly Neovim range plumbing + mapping selected lines to cell indices.
- No upstream marimo API changes needed.

Potential implementation:
```lua
-- in init.lua
function M.run_selection()
  local bufnr = vim.api.nvim_get_current_buf()
  local session = _sessions[bufnr]
  if not session or not session.ready then
    vim.notify('[marimo] not attached or not ready', vim.log.levels.WARN)
    return
  end

  local start_line = vim.fn.line("'<")
  local end_line = vim.fn.line("'>")
  if start_line > end_line then
    start_line, end_line = end_line, start_line
  end

  local ranges = parser.get_cell_ranges(bufnr)
  for i, r in ipairs(ranges) do
    if r.finish >= start_line and r.start <= end_line then
      local idx = i - 1
      local code = parser.cell_code_at_index(bufnr, idx)
      if code then
        session:run_cell(idx, code)
      end
    end
  end
end
```

### 2) Target and run all markdown cells in the buffer (optionally autorun on start/attach)

**Feasibility:** High

Why:
- We can detect markdown-like cells heuristically from extracted code (e.g. `mo.md(...)`, `md(...)`).
- Running them is just another `session:run_cell(...)` call.
- Autorun can hook after successful attach/start.

Risk:
- Markdown in marimo is still Python code; detection is heuristic unless we parse AST.

Potential implementation:
```lua
local function is_markdown_cell(code)
  if not code then return false end
  return code:match("%f[%w_]mo%.md%s*%(")
      or code:match("%f[%w_]md%s*%(")
end

function M.run_markdown_cells()
  local bufnr = vim.api.nvim_get_current_buf()
  local session = _sessions[bufnr]
  if not session or not session.ready then return end

  for i = 0, #session.cell_ids - 1 do
    local code = parser.cell_code_at_index(bufnr, i)
    if is_markdown_cell(code) then
      session:run_cell(i, code)
    end
  end
end

-- optional: call from attach callback if config.opts.autorun_markdown_on_attach
```

### 3) Fail to start server if there are unparseable cells in the buffer

**Feasibility:** Medium-high

Why:
- Feasible with a preflight check before `M.start()`.
- A pure text search (`app._unparsable_cell`) is unreliable; parser-level validation is better.
- Likely requires a Python subprocess using marimo internals for robust detection.

Risk:
- Adds startup latency and dependency on marimo internal APIs.

Potential implementation:
```lua
-- preflight in init.lua before server.start(...)
local function has_unparsable_cells(path, cb)
  vim.system({
    'python', '-c', [[
import sys
# pseudo-code: load marimo parser and validate cell defs in file
# print count of unparsable cells
print(0)
    ]],
    path,
  }, { text = true }, function(out)
    local n = tonumber((out.stdout or ''):match('%d+')) or 0
    cb(n > 0, n)
  end)
end
```

### 4) Run stale cells

**Feasibility:** Medium

Why:
- Strong implementation depends on marimo exposing staleness via WS/HTTP.
- If unavailable, plugin can only approximate stale state locally (code hash/change tick), which may diverge from kernel truth.

Potential implementation (API-first):
```lua
-- if kernel-ready / status payload includes stale flags
-- session.stale_by_cell_id = { [cell_id] = true/false }

function M.run_stale_cells()
  local bufnr = vim.api.nvim_get_current_buf()
  local session = _sessions[bufnr]
  if not session or not session.ready then return end

  for idx = 0, #session.cell_ids - 1 do
    local cell_id = session.cell_ids[idx + 1]
    if session.stale_by_cell_id and session.stale_by_cell_id[cell_id] then
      local code = parser.cell_code_at_index(bufnr, idx)
      if code then session:run_cell(idx, code) end
    end
  end
end
```

### 5) Run current cell's dependencies

**Feasibility:** Medium-low

Why:
- Correct dependency graph is maintained in marimo runtime, not in plugin.
- Local static analysis is possible but error-prone.
- Best path is an upstream/API-backed dependency query.

Potential implementation:
```lua
-- pseudo flow
-- 1) get current cell index
-- 2) ask marimo runtime/API for upstream dependency indices
-- 3) topologically run dependencies, then target

function M.run_cell_with_deps()
  local target = parser.cell_index_at_line(0, vim.api.nvim_win_get_cursor(0)[1])
  local deps = fetch_deps_from_runtime(target) -- needs API/subprocess bridge
  for _, idx in ipairs(deps) do
    local code = parser.cell_code_at_index(0, idx)
    if code then current_session:run_cell(idx, code) end
  end
end
```

### 6) Toggle disable/enable on current cell

**Feasibility:** Low-medium

Why:
- Clean behavior requires a first-class marimo API for per-cell disabled state.
- Without API support, plugin-side simulation is brittle and can conflict with marimo UI/kernel state.

Potential implementation (if API exists):
```lua
function Session:toggle_cell_disabled(cell_index, disabled)
  local cell_id = self.cell_ids[cell_index + 1]
  if not cell_id then return end
  post_kernel_json(self, '/api/kernel/cell/config', {
    cellId = cell_id,
    disabled = disabled,
  }, function(out, status, body)
    -- handle diagnostics
  end)
end
```

### 7) Extract code from all cells and craft a single runnable script (with user prompts)

**Feasibility:** Low

Why:
- Technically possible to concatenate extracted cell code, but correctness is tricky:
  - ordering/duplicate imports/redefinitions,
  - markdown conversion policy,
  - disabled/unparseable/stale policy,
  - preserving semantics for reactive notebook patterns.
- Requires non-trivial UX for prompts and preview before write/run.

Potential implementation:
```lua
function M.export_script(opts)
  local bufnr = vim.api.nvim_get_current_buf()
  local ranges = parser.get_cell_ranges(bufnr)
  local chunks = {}

  for i = 0, #ranges - 1 do
    local code = parser.cell_code_at_index(bufnr, i)
    if code then
      chunks[#chunks + 1] = string.format('# --- cell %d ---\n%s\n', i, code)
    end
  end

  local script = table.concat(chunks, '\n')
  -- then apply policy decisions from opts/prompts:
  -- include_markdown, include_disabled, include_unparsable, dedupe_imports, ...

  local out = vim.fn.expand('%:p:r') .. '.export.py'
  vim.fn.writefile(vim.split(script, '\n'), out)
  vim.notify('[marimo] exported script: ' .. out)
end
```

---

## Suggested implementation order

1. Visual selection run
2. Markdown-targeted run (+ optional autorun)
3. Unparseable preflight check
4. Run stale cells (only if API support is found)
5. Run dependencies
6. Toggle disable/enable
7. Script export with prompt-driven policies
