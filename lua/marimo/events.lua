--- events.lua
--- Per-buffer autocmds for cursor tracking and file-save refresh.
---
--- For each attached buffer we create an augroup named
---   'marimo-<bufnr>'
--- containing:
---   CursorMoved  → compute cell index from cursor line → session:focus_cell()
---   BufWritePost → session:refresh() to re-sync cell_ids after saves
---   BufDelete    → clean up the session for this buffer

local M = {}

local parser = require 'marimo.parser'
local config = require 'marimo.config'

--- Register all autocmds for `bufnr`, wired to `session`.
---
--- @param bufnr     integer   buffer handle
--- @param session   table     Session object (from session.lua)
--- @param on_delete fun()|nil called after BufDelete tears down the session
function M.attach(bufnr, session, on_delete)
    local group = vim.api.nvim_create_augroup('marimo-' .. bufnr, { clear = true })

    -- Track last cell to avoid redundant focus_cell calls on column-only moves.
    local last_cell_index = nil

    vim.api.nvim_create_autocmd('CursorMoved', {
        group = group,
        buffer = bufnr,
        callback = function()
            if not config.opts.follow_cursor then return end
            if not session.ready then return end

            local cursor_line = vim.api.nvim_win_get_cursor(0)[1] -- 1-based
            local idx = parser.cell_index_at_line(bufnr, cursor_line)

            if idx == nil then return end
            if idx == last_cell_index then return end -- same cell, skip

            last_cell_index = idx
            session:focus_cell(idx)
        end,
    })

    -- After saving, cell order may have changed — refresh cell_ids from server.
    vim.api.nvim_create_autocmd('BufWritePost', {
        group = group,
        buffer = bufnr,
        callback = function()
            session:refresh()
            last_cell_index = nil -- force re-send on next cursor move
        end,
    })

    -- When the buffer is deleted, tear down the session and notify init.lua so
    -- it can remove the entry from its _sessions registry.
    vim.api.nvim_create_autocmd('BufDelete', {
        group = group,
        buffer = bufnr,
        callback = function()
            session:close()
            pcall(vim.api.nvim_del_augroup_by_name, 'marimo-' .. bufnr)
            if on_delete then on_delete() end
        end,
    })
end

--- Remove all autocmds for `bufnr` (called by :MarimoDetach).
--- @param bufnr integer
function M.detach(bufnr)
    pcall(vim.api.nvim_del_augroup_by_name, 'marimo-' .. bufnr)
end

return M
