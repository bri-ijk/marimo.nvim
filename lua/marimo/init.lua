--- init.lua  (lua/marimo/init.lua)
--- Public API for marimo.nvim.
---
--- Usage in user config:
---
---   require('marimo').setup({
---     -- optional overrides; see config.lua for all options
---     port = 2718,
---     follow_cursor = true,
---     open_browser = false,
---   })
---
--- Open a marimo notebook .py file, then either:
---   :MarimoStart   — launch marimo edit for the current file and auto-attach
---   :MarimoAttach  — attach to an already-running marimo server

local M         = {}

local config    = require 'marimo.config'
local server    = require 'marimo.server'
local Session   = require 'marimo.session'
local events    = require 'marimo.events'

--- Registry of active sessions keyed by bufnr.
--- @type table<integer, table>
local _sessions = {}

-- Setup

--- Configure the plugin.  Call once in your Neovim config before using any
--- commands.  All options are optional; sensible defaults are applied.
---
--- @param opts table|nil  See lua/marimo/config.lua for available keys.
function M.setup(opts)
    config.setup(opts)
end

-- Core API

--- Attach the current buffer to a running marimo server.
--- Idempotent: calling again on an already-attached buffer re-connects.
function M.attach()
    local bufnr = vim.api.nvim_get_current_buf()
    local path  = vim.api.nvim_buf_get_name(bufnr)

    if path == '' then
        vim.notify('[marimo] buffer has no file path', vim.log.levels.ERROR)
        return
    end

    -- Detach silently first if already attached (re-attach / reconnect).
    if _sessions[bufnr] then
        _sessions[bufnr]:close()
        events.detach(bufnr)
        _sessions[bufnr] = nil
    end

    -- Locate the running marimo server.
    local conn, err = server.connect()
    if not conn then
        vim.notify('[marimo] ' .. (err or 'could not connect to marimo server'),
            vim.log.levels.ERROR)
        return
    end

    -- Create session and start WebSocket connection.
    local session = Session.new(conn, path)
    local ws_err = session:connect(function(cell_ids)
        vim.notify(
            string.format('[marimo] ready — %d cells loaded (%s:%d)',
                #cell_ids, conn.host, conn.port),
            vim.log.levels.INFO
        )
    end)

    if ws_err then
        vim.notify('[marimo] ' .. ws_err, vim.log.levels.ERROR)
        return
    end

    _sessions[bufnr] = session

    -- Wire autocmds; on_delete keeps _sessions in sync when the buffer closes.
    events.attach(bufnr, session, function()
        _sessions[bufnr] = nil
    end)

    vim.notify(
        string.format('[marimo] connecting to %s:%d …', conn.host, conn.port),
        vim.log.levels.INFO
    )
end

--- Start a marimo server for the current buffer's file and then auto-attach.
--- If a server is already running, skips launch and attaches directly.
function M.start()
    local bufnr = vim.api.nvim_get_current_buf()
    local path  = vim.api.nvim_buf_get_name(bufnr)

    if path == '' then
        vim.notify('[marimo] buffer has no file path', vim.log.levels.ERROR)
        return
    end

    -- If a server is already reachable, just attach to it.
    if server.is_running() then
        vim.notify('[marimo] server already running — attaching …', vim.log.levels.INFO)
        M.attach()
        return
    end

    vim.notify('[marimo] starting marimo server …', vim.log.levels.INFO)

    server.start(path, { open_browser = config.opts.open_browser }, function(conn, err)
        vim.schedule(function()
            if err then
                vim.notify('[marimo] ' .. err, vim.log.levels.ERROR)
                return
            end
            -- Server is up; run a normal attach now that the port is known.
            M.attach()
        end)
    end)
end

--- Stop the marimo server started by :MarimoStart and detach the current buffer.
function M.stop()
    local bufnr = vim.api.nvim_get_current_buf()
    if _sessions[bufnr] then
        M.detach(bufnr)
    end
    server.stop()
    vim.notify('[marimo] server stopped', vim.log.levels.INFO)
end

--- Detach the current (or specified) buffer from its marimo session.
--- @param bufnr integer|nil  defaults to current buffer
function M.detach(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    local session = _sessions[bufnr]
    if not session then
        vim.notify('[marimo] buffer is not attached', vim.log.levels.WARN)
        return
    end
    session:close()
    events.detach(bufnr)
    _sessions[bufnr] = nil
    vim.notify('[marimo] detached', vim.log.levels.INFO)
end

--- Toggle the follow_cursor option globally.
function M.toggle_follow()
    config.opts.follow_cursor = not config.opts.follow_cursor
    vim.notify(
        '[marimo] follow cursor: ' .. (config.opts.follow_cursor and 'ON' or 'OFF'),
        vim.log.levels.INFO
    )
end

--- Print the sync status for the current buffer.
function M.status()
    local bufnr   = vim.api.nvim_get_current_buf()
    local session = _sessions[bufnr]

    if not session then
        vim.notify('[marimo] not attached (run :MarimoAttach)', vim.log.levels.INFO)
        return
    end

    local lines = {
        string.format('  host        : %s', session.conn.host),
        string.format('  port        : %d', session.conn.port),
        string.format('  session_id  : %s', session.session_id),
        string.format('  ready       : %s', tostring(session.ready)),
        string.format('  cells       : %d', #session.cell_ids),
        string.format('  follow      : %s', tostring(config.opts.follow_cursor)),
        string.format('  notebook    : %s', session.notebook_path),
    }
    vim.notify('[marimo] status\n' .. table.concat(lines, '\n'), vim.log.levels.INFO)
end

--- Return the active session for a buffer (nil if not attached).
--- Useful for integration with other plugins / user scripts.
--- @param bufnr integer|nil
--- @return table|nil
function M.get_session(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    return _sessions[bufnr]
end

return M
