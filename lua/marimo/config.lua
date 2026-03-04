local M = {}

M.opts = {
    -- Port marimo is running on. Set to nil to auto-detect from running processes.
    port = nil,
    -- Host marimo is running on.
    host = '127.0.0.1',
    -- Whether to follow cursor movement in the browser automatically.
    follow_cursor = true,
    -- Path to websocat binary. If nil, falls back to 'websocat' on PATH.
    -- websocat is required for WebSocket communication (neovim has no built-in WS client).
    -- Install with: cargo install websocat, or from https://github.com/vi/websocat
    websocat_bin = nil,
    -- Marimo server token. Optional; set this if your server is configured to require a token.
    server_token = nil,
    -- Whether to open the browser automatically when starting the marimo server.
    open_browser = true,
}

--- Merge user opts into defaults.
--- @param opts table|nil
function M.setup(opts)
    M.opts = vim.tbl_deep_extend('force', M.opts, opts or {})
end

return M
