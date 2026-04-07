local M = {}

local config = require("marimo.config")

local GROUP = vim.api.nvim_create_augroup("marimo-keymaps", { clear = true })

local function is_python_buffer(bufnr)
	if vim.api.nvim_buf_is_valid(bufnr) == false then
		return false
	end
	if vim.bo[bufnr].buftype ~= "" then
		return false
	end
	if vim.bo[bufnr].filetype == "python" then
		return true
	end
	local name = vim.api.nvim_buf_get_name(bufnr)
	return name:match("%.py$") ~= nil
end

local function set_buffer_keymaps(bufnr)
	local keys = config.opts.keys
	if keys == false or type(keys) ~= "table" then
		return
	end
	if vim.b[bufnr].marimo_keymaps_applied then
		return
	end

	for _, spec in ipairs(keys) do
		if type(spec) == "table" and spec.lhs and spec.cmd then
			vim.keymap.set(spec.mode or "n", spec.lhs, function()
				vim.cmd(spec.cmd)
			end, {
				buffer = bufnr,
				silent = spec.silent ~= false,
				noremap = spec.noremap ~= false,
				desc = spec.desc,
			})
		end
	end

	vim.b[bufnr].marimo_keymaps_applied = true
end

local function set_enter_keymaps(bufnr)
	if not config.opts.enter_to_run then
		return
	end
	if vim.b[bufnr].marimo_enter_keymaps_applied then
		return
	end

	vim.keymap.set("n", "<CR>", "<cmd>MarimoRunCell<CR>", {
		buffer = bufnr,
		silent = true,
		noremap = true,
		desc = "Run marimo cell",
	})
	vim.keymap.set("v", "<CR>", "<cmd>MarimoRunVisual<CR>", {
		buffer = bufnr,
		silent = true,
		noremap = true,
		desc = "Run marimo selection",
	})

	vim.b[bufnr].marimo_enter_keymaps_applied = true
end

function M.setup()
	vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile" }, {
		group = GROUP,
		callback = function(args)
			if is_python_buffer(args.buf) then
				set_buffer_keymaps(args.buf)
				set_enter_keymaps(args.buf)
			end
		end,
	})

	local current = vim.api.nvim_get_current_buf()
	if is_python_buffer(current) then
		set_buffer_keymaps(current)
		set_enter_keymaps(current)
	end
end

return M
