--- commands.lua
--- Registers user-facing Neovim commands for the marimo plugin.
---
--- Commands:
---   :MarimoAttach          Connect current buffer to a running marimo server
---   :MarimoDetach          Disconnect current buffer
---   :MarimoToggleFollow    Toggle automatic cursor-follow (follow_cursor option)
---   :MarimoStatus          Print connection status for the current buffer

local M = {}

local function create_commands()
    local marimo = require 'marimo'

    vim.api.nvim_create_user_command('MarimoAttach', function()
        marimo.attach()
    end, { desc = 'Connect the current marimo notebook buffer to a running server' })

    vim.api.nvim_create_user_command('MarimoDetach', function()
        marimo.detach()
    end, { desc = 'Disconnect the current marimo notebook buffer from the server' })

    vim.api.nvim_create_user_command('MarimoToggleFollow', function()
        marimo.toggle_follow()
    end, { desc = 'Toggle automatic browser scroll-follow on cursor movement' })

    vim.api.nvim_create_user_command('MarimoStatus', function()
        marimo.status()
    end, { desc = 'Show marimo sync status for the current buffer' })
end

function M.create_commands()
    create_commands()
end

return M
