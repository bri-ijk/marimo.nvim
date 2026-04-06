# Features to add

- Fail to start server if there are unparseable cells in the buffer
  - search for "app.\_unparsable_cell" or find some other way to detect this cleanly
  - Prompt the user to fix them before trying to run the server
- Run stale cells
- Run markdown cells / autorun markdown cells on marimo start
- Run current cells' dependencies
- Toggle disable/enable on current cell

## Feasibility Assessment

### 1. Fail to start server if there are unparseable cells in the buffer

**Feasibility: High.**

Marimo serializes cells with a `class CellImpl` repr that includes an `_unparsable: bool` flag. When you save a `.py` file, marimo parses each cell block back through its serialization format — if a cell body fails to round-trip (e.g. syntax error, broken decorator, missing indent), `_unparsable` gets set to `True` and the cell is skipped at runtime.

The plugin can detect this in two ways:

- **Inspect the serialized cell reprs in the buffer.** Each `@app.cell` / `@app.function` / `@app.class_definition` block is a function whose body starts with `__marimo__ = CellImpl(...)`. If the block cannot be parsed back, marimo marks it internally — but this state is not written back into the file in plain text, so the plugin cannot read it without invoking the Python parser.

- **Invoke marimo's Python parser at startup.** The cleanest approach is to run a short Python snippet via `vim.system` that calls `marimo._runtime. получить_cell_impls()` or reads the file via `marimo._ast.factory.parse_cell_defs()` to get each cell's `_unparsable` status. If any cell is unparsable, abort the `:MarimoStart` flow and prompt the user to fix them in a text editor first. This adds a startup latency cost (a subprocess call to Python on each start), but it is the only reliable approach.

Implementation sketch: add a `parser.check_unparsable_cells(file_path)` function that spawns `python -c "import marimo._ast.factory as f; ..."` and returns the list of unparsable cell indices, then gate `M.start()` on a clean result.

---

### 2. Run stale cells

**Feasibility: Medium (needs API support from marimo).**

A "stale" cell is one whose outputs are out of date because upstream cells have changed since it last ran. Marimo tracks this state internally in the kernel (each `CellRunner` maintains a `stale` flag). Whether the server exposes this information over its HTTP API or WebSocket protocol determines how feasible this is:

- **If marimo exposes stale state in the WebSocket `kernel-ready` message or a `/api/kernel/status` endpoint:** the plugin can read it similarly to how it reads `cell_ids`. Each cell's stale state would be sent alongside its `cell_id`. The plugin would then show stale cells differently in the buffer (e.g. with a sign or virtual text) and offer `:MarimoRunStale` to run only those.

- **If no API support exists:** the plugin could compute staleness locally by tracking the last-edited version of each cell (e.g. via buffer change ticks or a hash of cell code) and comparing it against the last-known kernel-computed hash. This is approximate — it requires the plugin to maintain its own notion of what "stale" means, which may diverge from marimo's internal definition. It is implementable but could be wrong in edge cases (e.g. when a cell's behavior changes due to non-code state like global variables or imported module changes).

Recommended path: check whether marimo's HTTP or WS protocol currently exposes stale cell information. If not, open an upstream issue first; implement the local-comparison fallback only if upstream is unwilling to add API support.

---

### 3. Run markdown cells / autorun markdown cells on marimo start

**Feasibility: High for the read side, Medium for autorun.**

- **Reading markdown cells:** Marimo does not have a distinct "markdown cell" type in the Python format. All cells are Python code — if you want a markdown cell you either write a plain comment (`# My markdown text`) or use a `with app.md(...)` block. The plugin's parser already handles `app.md(...)` blocks (they use the `app.function` / decorator pattern). The plugin can extract the contents of `app.md("...")` calls from the cell body and render them as virtual text or in a floating window, but this would be purely cosmetic — the plugin would be authoring display logic, not integrating with marimo's actual markdown rendering pipeline.

- **Autorun markdown cells on start:** Marimo executes only Python code cells; markdown is not executed. There is nothing to "autorun" unless the user means "show a preview of markdown cells when the notebook loads." If so, the plugin could extract `app.md(...)` content and display it via `nvim_buf_set_virtual_text()` or a floating window after the session becomes ready. This does not interact with marimo's kernel at all — it is purely a client-side display feature.

The feature as described is not well-defined for marimo's execution model. Clarify intent before implementing.

---

### 4. Run current cells' dependencies

**Feasibility: Medium.**

Marimo maintains a directed acyclic graph (DAG) of cell dependencies internally in `_cell_runner.py`. The server API does expose this graph — it can be read from the `marimo._ört` module — but it is not currently exposed over the HTTP or WebSocket API.

Two approaches:

- **Query marimo's Python runtime directly** (similar to the unparsable-cells check): spawn a Python subprocess that imports `marimo._runtime.runner` and traverses the cell dependency graph for a given cell index. Return the list of upstream cell indices, then run those first before running the target cell. This is reliable but adds latency per invocation.

- **Build the dependency graph locally in the plugin** by statically analyzing Python code: for each cell, extract all variable names defined in it (via the parser + Python AST) and all variables referenced (imported names, local reads). Build a coarse dependency graph from that. This is fast and offline, but can easily produce false positives (a variable name being present does not mean it came from a specific cell's output) and misses runtime dependencies (e.g. a cell that reads from a global set by another cell via string interpolation).

The Python-subprocess approach is the correct foundation. If upstream eventually exposes the dependency graph via the WebSocket protocol, the plugin can switch to that for lower latency.

---

### 5. Toggle disable/enable on current cell

**Feasibility: Low-to-Medium (requires upstream API support).**

Marimo does not have a built-in "disabled" cell concept at the Python level — disabled cells are a UI feature (the run button is grayed out), not a runtime feature. The server simply does not execute a disabled cell when it computes the DAG.

Whether this is implementable depends on whether the server API supports marking a cell as disabled:

- **If marimo exposes a `PATCH /api/kernel/cells/{cell_id}` or similar endpoint:** the plugin could send `{ "disabled": true }` to toggle the cell's run state. This would require inspecting marimo's API to confirm the endpoint exists and its request schema.

- **If no such endpoint exists:** the plugin could simulate the effect locally by intercepting the cell's code and replacing it with a no-op before sending it to `run_cell`. When re-enabled, restore the original code. This is fragile — it modifies what the plugin sends to the server, which could confuse marimo's cell ordering or state tracking if it relies on exact code hashes.

The feature should be deferred until the upstream API is confirmed to support per-cell disabled state.
