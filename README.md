# marimo.nvim

Sync the [Marimo](https://marimo.io) notebook browser view with your Neovim cursor.

When you navigate between cells in a Marimo `.py` file, the notebook open in
your browser scrolls to match — the same way
[typst-preview.nvim](https://github.com/chomosuke/typst-preview.nvim) works for
Typst documents.

> [!NOTE]
> Requires a running `marimo edit` server and
> [`websocat`](#dependencies) on your PATH.

> [!IMPORTANT]
> Browser scroll sync depends on a small upstream change to Marimo that has been
> submitted as [marimo-team/marimo #8497](https://github.com/marimo-team/marimo/pull/8497).
> Until that PR is merged, the plugin connects and tracks cells correctly but the
> browser will not scroll. See [Status](#status) for details.

---

## Features

- Automatically scrolls the Marimo browser to the cell under the cursor
- Detects a running `marimo edit` server — no port config required in most cases
- Refreshes the cell map on every file save, handling reordered or renamed cells
- Per-buffer: attach and detach independently for multiple open notebooks
- Toggle cursor-follow on/off at any time with `:MarimoToggleFollow`

## Status

| Piece | State |
|---|---|
| Cell parsing (`@app.cell` boundaries) | Working |
| WebSocket connection + `kernel-ready` | Working |
| Cell ID map (index → Marimo cell ID) | Working |
| Browser scroll on cursor move | **Pending** [#8497](https://github.com/marimo-team/marimo/pull/8497) |

Once the upstream PR lands, the browser scroll will activate automatically —
no changes to this plugin will be needed.

## Dependencies

- **[Marimo](https://marimo.io)** — `pip install marimo`
- **[websocat](https://github.com/vi/websocat)** — bridges Neovim to the
  Marimo WebSocket (Neovim has no built-in WebSocket client)

Install `websocat` with any of:

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

### [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use {
  'brian2001dineen-afk/marimo.nvim',
  config = function()
    require('marimo').setup()
  end,
}
```

### [vim-plug](https://github.com/junegunn/vim-plug)

```vim
Plug 'brian2001dineen-afk/marimo.nvim'
lua require('marimo').setup()
```

## Usage

1. Start your notebook: `marimo edit my_notebook.py`
2. Open the same file in Neovim
3. Run `:MarimoAttach`
4. Move between cells — the browser follows

### Commands

| Command | Description |
|---|---|
| `:MarimoAttach` | Connect the current buffer to a running Marimo server |
| `:MarimoDetach` | Disconnect the current buffer |
| `:MarimoToggleFollow` | Toggle automatic browser scroll on cursor movement |
| `:MarimoStatus` | Show connection status for the current buffer |

## Configuration

All options and their defaults:

```lua
require('marimo').setup({
  -- Port Marimo is running on.
  -- nil = auto-detect from running processes (recommended).
  port = nil,

  -- Host Marimo is running on.
  host = '127.0.0.1',

  -- Automatically scroll the browser when the cursor moves to a new cell.
  follow_cursor = true,

  -- Path to the websocat binary.
  -- nil = use 'websocat' from PATH.
  websocat_bin = nil,

  -- Marimo server token. Normally not needed — fetched automatically.
  server_token = nil,
})
```

### Use websocat installed via Mason

If you manage binaries through
[mason.nvim](https://github.com/williamboman/mason.nvim), point the plugin at
Mason's bin directory:

```lua
require('marimo').setup({
  websocat_bin = vim.fn.stdpath('data') .. '/mason/bin/websocat',
})
```

## Contributing

Contributions are welcome. The plugin is intentionally small — if you have a
feature idea, open an issue first so we can discuss the approach.

## Credits

- [Marimo](https://github.com/marimo-team/marimo) — the reactive notebook this
  plugin integrates with
- [typst-preview.nvim](https://github.com/chomosuke/typst-preview.nvim) —
  structural inspiration for the plugin architecture
