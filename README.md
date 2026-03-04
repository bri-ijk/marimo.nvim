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
- Toggle cursor-follow on/off with `:MarimoToggleFollow`

> [!IMPORTANT]
> Browser scroll-to-cell on cursor movement depends on
> [marimo-team/marimo #8497](https://github.com/marimo-team/marimo/pull/8497)
> which is not yet merged. The plugin connects and tracks cells correctly but
> the browser will not scroll until that PR lands.

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
| `:MarimoToggleFollow` | Toggle automatic browser scroll on cursor movement |
| `:MarimoStatus` | Show connection status for the current buffer |

## Configuration

```lua
require('marimo').setup({
  -- Automatically open the browser when :MarimoStart is called.
  open_browser = true,

  -- Port for the managed server (:MarimoStart).
  -- nil = default Marimo port (2718).
  port = nil,

  -- Host Marimo is running on.
  host = '127.0.0.1',

  -- Automatically scroll the browser when the cursor moves to a new cell.
  -- Requires marimo-team/marimo#8497 to be merged before this has any effect.
  follow_cursor = true,

  -- Path to the websocat binary. nil = use 'websocat' from PATH.
  websocat_bin = nil,
})
```

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
