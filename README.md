# marimo.nvim

Launch and sync a [Marimo](https://marimo.io) notebook directly from Neovim —
no terminal required.

## Features

- **`:MarimoStart`** — starts `marimo edit` for the current file, opens the
  browser, and connects the plugin, all in one command
- Automatically reloads the notebook when you save in Neovim (`--watch`)
- Connects as a background kiosk client so the browser session is never
  interrupted
- Per-buffer: attach and detach independently for multiple open notebooks
- Run a single cell (`:MarimoRunCell`) or all cells (`:MarimoRunAll`)
- Toggle cursor-follow on/off with `:MarimoToggleFollow`
- Browser scroll-to-cell on cursor movement is supported on current marimo
  stable releases via `POST /api/kernel/focus_cell`

## Dependencies

- **[Marimo](https://marimo.io)** — `pip install marimo`
- **[websocat](https://github.com/vi/websocat)** — WebSocket bridge (Neovim
  has no built-in WebSocket client)

```sh
cargo install websocat          # via Rust/cargo
brew install websocat           # macOS Homebrew
# or grab a binary from https://github.com/vi/websocat/releases
```

## Installation

### [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  'brian2001dineen-afk/marimo.nvim',
  opts = {},
}
```

## Usage

Open a Marimo notebook file in Neovim and run:

```
:MarimoStart
```

That's it. The plugin starts the server, opens the browser, and connects in the
background. Save the file in Neovim (`:w`) and the notebook reloads in the browser.

To connect to a server you already started manually:

```
:MarimoAttach
```

### Commands

| Command | Description |
|---|---|
| `:MarimoStart` | Start `marimo edit` for the current file and connect |
| `:MarimoStop` | Stop the managed server and disconnect |
| `:MarimoAttach` | Connect to an already-running Marimo server |
| `:MarimoDetach` | Disconnect the current buffer |
| `:MarimoRunCell` | Run the marimo cell under the cursor |
| `:MarimoRunAll` | Run all marimo cells in the current buffer |
| `:MarimoToggleFollow` | Toggle automatic browser scroll on cursor movement |
| `:MarimoStatus` | Show connection status for the current buffer |

## Configuration

```lua
require('marimo').setup({
  -- Automatically open the browser when :MarimoStart is called.
  open_browser = true,

  -- Explicit marimo executable for :MarimoStart.
  -- Leave nil to use `marimo` from PATH.
  marimo_bin = nil,

  -- Temporary local marimo checkout for :MarimoStart.
  -- Runs: uv run --project <dir> marimo ...
  marimo_project = nil,

  -- Port for the managed server (:MarimoStart).
  -- nil = default Marimo port (2718).
  port = nil,

  -- Host Marimo is running on.
  host = '127.0.0.1',

  -- Automatically scroll the browser when the cursor moves to a new cell.
  follow_cursor = true,

  -- Path to the websocat binary. nil = use 'websocat' from PATH.
  websocat_bin = nil,
})
```

You can override or disable the default buffer-local keymaps that the
plugin installs for Python files:

```lua
-- Disable all default keymaps
require('marimo').setup({ keys = false })

-- Provide a custom set of buffer-local mappings (applied only for .py files)
require('marimo').setup({
  keys = {
    { mode = 'n', lhs = '<localleader>s', cmd = 'MarimoRunCell', desc = 'Run cell' },
    -- add or replace other mappings as needed
  }
})
```

The entries in `keys` are plain tables describing mappings. They are applied
buffer-locally and only for Python buffers (filetype 'python' or files ending
in `.py`).

`:MarimoStart` opens the notebook in kiosk mode using a URL like
`http://localhost:2718/?file=/path/to/notebook.py&kiosk=true`, so the browser
can receive focus-sync notifications without taking over the main session.

For local marimo development, you can point the plugin at a checkout with:

```lua
require('marimo').setup({
  marimo_project = '/home/bri/projects/marimo',
})
```

`marimo_project` is intended as a temporary development override while testing
against a local marimo checkout. For normal use, leave it unset and let the
plugin use your installed `marimo` binary.

### websocat via Mason

```lua
require('marimo').setup({
  websocat_bin = vim.fn.stdpath('data') .. '/mason/bin/websocat',
})
```

## Contributing

Contributions are welcome. The plugin is intentionally small — open an issue
first if you have a feature idea.

## Credits

- [Marimo](https://github.com/marimo-team/marimo) — the reactive notebook
- [typst-preview.nvim](https://github.com/chomosuke/typst-preview.nvim) —
  architectural inspiration
