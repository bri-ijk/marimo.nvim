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

local M = {}

local config = require("marimo.config")
local server = require("marimo.server")
local Session = require("marimo.session")
local events = require("marimo.events")
local parser = require("marimo.parser")

--- Registry of active sessions keyed by bufnr.
--- @type table<integer, table>
local _sessions = {}

--- Return true when extracted cell code looks like a markdown-rendering cell.
--- @param code string|nil
--- @return boolean
local function is_markdown_cell(code)
	if not code or code == "" then
		return false
	end
	return code:match("%f[%w_]mo%.md%s*%(") ~= nil or code:match("%f[%w_]md%s*%(") ~= nil
end

--- Run markdown-targeted cells for a buffer/session pair.
--- @param bufnr integer
--- @param session table
--- @param silent boolean|nil
--- @return integer ran_count
local function run_markdown_cells_for_buffer(bufnr, session, silent)
	local ran_count = 0
	-- Make sure to run the marimo `import marimo as md` cell first if it exists, so that subsequent markdown cells can find the `md` alias.
	-- TODO: test
	-- (this is hacky as it relies on the import cell being first, but marimo itself doesn't currently guarantee any particular cell order)
	session:run_cell(0, parser.cell_code_at_index(bufnr, 0))
	for i = 0, (#session.cell_ids - 1) do
		local code = parser.cell_code_at_index(bufnr, i)
		if code and is_markdown_cell(code) then
			session:run_cell(i, code)
			ran_count = ran_count + 1
		end
	end

	if not silent then
		if ran_count == 0 then
			vim.notify("[marimo] no markdown-targeted cells found", vim.log.levels.INFO)
		else
			vim.notify(string.format("[marimo] ran %d markdown-targeted cells", ran_count), vim.log.levels.INFO)
		end
	end

	return ran_count
end

-- Setup

--- Configure the plugin.  Call once in your Neovim config before using any
--- commands.  All options are optional; sensible defaults are applied.
---
--- @param opts table|nil  See lua/marimo/config.lua for available keys.
function M.setup(opts)
	config.setup(opts)
end

-- Core API

--- Internal: attach a buffer to marimo using a known connection descriptor.
--- @param bufnr integer
--- @param path  string
--- @param conn  table  { host, port, token }
local function attach_with_conn(bufnr, path, conn)
	-- Detach silently first if already attached.
	if _sessions[bufnr] then
		_sessions[bufnr]:close()
		events.detach(bufnr)
		_sessions[bufnr] = nil
	end

	local session = Session.new(conn, path)
	local did_initial_ready = false
	local ws_err = session:connect(function(cell_ids)
		vim.notify(
			string.format("[marimo] ready — %d cells loaded (%s:%d)", #cell_ids, conn.host, conn.port),
			vim.log.levels.INFO
		)

		if not did_initial_ready then
			did_initial_ready = true
			if config.opts.autorun_markdown_on_attach then
				run_markdown_cells_for_buffer(bufnr, session, true)
			end
		end
	end)

	if ws_err then
		vim.notify("[marimo] " .. ws_err, vim.log.levels.ERROR)
		return
	end

	_sessions[bufnr] = session

	events.attach(bufnr, session, function()
		_sessions[bufnr] = nil
	end)

	vim.notify(string.format("[marimo] connecting to %s:%d …", conn.host, conn.port), vim.log.levels.INFO)

	return session
end

--- Attach the current buffer to a running marimo server.
--- Idempotent: calling again on an already-attached buffer re-connects.
function M.attach()
	local bufnr = vim.api.nvim_get_current_buf()
	local path = vim.api.nvim_buf_get_name(bufnr)

	if path == "" then
		vim.notify("[marimo] buffer has no file path", vim.log.levels.ERROR)
		return
	end

	local conn, err = server.connect(path)
	if not conn then
		vim.notify("[marimo] " .. (err or "could not connect to marimo server"), vim.log.levels.ERROR)
		return
	end

	return attach_with_conn(bufnr, path, conn)
end

--- Start a marimo server for the current buffer's file and then auto-attach.
--- If a server is already running, skips launch and attaches directly.
function M.start()
	local bufnr = vim.api.nvim_get_current_buf()
	local path = vim.api.nvim_buf_get_name(bufnr)

	if path == "" then
		vim.notify("[marimo] buffer has no file path", vim.log.levels.ERROR)
		return
	end

	-- If a server is already reachable, just attach to it.
	if server.is_running() then
		vim.notify("[marimo] server already running — attaching …", vim.log.levels.INFO)
		local session = M.attach()
		if session and config.opts.open_browser then
			local url, open_err = server.open_browser(session.conn, path)
			if open_err then
				vim.notify("[marimo] " .. open_err .. ": " .. url, vim.log.levels.WARN)
			else
				vim.notify("[marimo] opened browser: " .. url, vim.log.levels.INFO)
			end
		end
		return
	end

	vim.notify("[marimo] starting marimo server …", vim.log.levels.INFO)

	server.start(path, function(conn, err)
		vim.schedule(function()
			if err then
				vim.notify("[marimo] " .. err, vim.log.levels.ERROR)
				return
			end
			attach_with_conn(bufnr, path, conn)
			if config.opts.open_browser then
				local url, open_err = server.open_browser(conn, path)
				if open_err then
					vim.notify("[marimo] " .. open_err .. ": " .. url, vim.log.levels.WARN)
				else
					vim.notify("[marimo] opened browser: " .. url, vim.log.levels.INFO)
				end
			else
				vim.notify("[marimo] browser URL: " .. server.browser_url(conn, path), vim.log.levels.INFO)
			end
		end)
	end)
end

--- Stop the marimo server started by :MarimoStart and detach the current buffer.
function M.stop()
	local bufnr = vim.api.nvim_get_current_buf()
	if _sessions[bufnr] then
		M.detach(bufnr)
	end
	if server.stop() then
		vim.notify("[marimo] stopping managed server", vim.log.levels.INFO)
	else
		vim.notify("[marimo] no managed server found", vim.log.levels.WARN)
	end
end

--- Detach the current (or specified) buffer from its marimo session.
--- @param bufnr integer|nil  defaults to current buffer
function M.detach(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	local session = _sessions[bufnr]
	if not session then
		vim.notify("[marimo] buffer is not attached", vim.log.levels.WARN)
		return
	end
	session:close()
	events.detach(bufnr)
	_sessions[bufnr] = nil
	vim.notify("[marimo] detached", vim.log.levels.INFO)
end

--- Toggle the follow_cursor option globally.
function M.toggle_follow()
	config.opts.follow_cursor = not config.opts.follow_cursor
	vim.notify("[marimo] follow cursor: " .. (config.opts.follow_cursor and "ON" or "OFF"), vim.log.levels.INFO)
end

--- Print the sync status for the current buffer.
function M.status()
	local bufnr = vim.api.nvim_get_current_buf()
	local session = _sessions[bufnr]

	if not session then
		vim.notify("[marimo] not attached (run :MarimoAttach)", vim.log.levels.INFO)
		return
	end

	local lines = {
		string.format("  host        : %s", session.conn.host),
		string.format("  port        : %d", session.conn.port),
		string.format("  session_id  : %s", session.session_id),
		string.format("  ready       : %s", tostring(session.ready)),
		string.format("  cells       : %d", #session.cell_ids),
		string.format("  follow      : %s", tostring(config.opts.follow_cursor)),
		string.format("  notebook    : %s", session.notebook_path),
	}
	vim.notify("[marimo] status\n" .. table.concat(lines, "\n"), vim.log.levels.INFO)
end

--- Run the marimo cell under the cursor.
function M.run_cell()
	local bufnr = vim.api.nvim_get_current_buf()
	local session = _sessions[bufnr]

	if not session then
		vim.notify("[marimo] not attached (run :MarimoAttach)", vim.log.levels.WARN)
		return
	end
	if not session.ready then
		vim.notify("[marimo] session is not ready yet", vim.log.levels.WARN)
		return
	end

	local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
	local idx = parser.cell_index_at_line(bufnr, cursor_line)
	if idx == nil then
		vim.notify("[marimo] cursor is not inside a marimo cell", vim.log.levels.WARN)
		return
	end

	local code = parser.cell_code_at_index(bufnr, idx)
	if code == nil then
		vim.notify("[marimo] could not extract cell code from buffer", vim.log.levels.WARN)
		return
	end

	session:run_cell(idx, code)
end

--- Run all of the marimo cells in the current buffer.
function M.run_all_cells()
	local bufnr = vim.api.nvim_get_current_buf()
	local session = _sessions[bufnr]

	if not session then
		vim.notify("[marimo] not attached (run :MarimoAttach)", vim.log.levels.WARN)
		return
	end
	if not session.ready then
		vim.notify("[marimo] session is not ready yet", vim.log.levels.WARN)
		return
	end

	for i = 0, (#session.cell_ids - 1) do
		local cell_code = parser.cell_code_at_index(bufnr, i)
		if cell_code == nil then
			vim.notify("[marimo] could not extract cell code from buffer", vim.log.levels.WARN)
			return
		end
		if cell_code then
			session:run_cell(i, cell_code)
		end
	end
end

--- Run every cell that overlaps the visual selection range.
--- @param line_start integer|nil
--- @param line_end integer|nil
function M.run_visual(line_start, line_end)
	local bufnr = vim.api.nvim_get_current_buf()
	local session = _sessions[bufnr]

	if not session then
		vim.notify("[marimo] not attached (run :MarimoAttach)", vim.log.levels.WARN)
		return
	end
	if not session.ready then
		vim.notify("[marimo] session is not ready yet", vim.log.levels.WARN)
		return
	end

	local first = line_start or vim.fn.line("'<")
	local last = line_end or vim.fn.line("'>")
	if first <= 0 or last <= 0 then
		vim.notify("[marimo] no visual selection range found", vim.log.levels.WARN)
		return
	end
	if first > last then
		first, last = last, first
	end

	local ranges = parser.get_cell_ranges(bufnr)
	local ran_count = 0

	for i, range in ipairs(ranges) do
		if range.finish >= first and range.start <= last then
			local idx = i - 1
			local code = parser.cell_code_at_index(bufnr, idx)
			if code then
				session:run_cell(idx, code)
				ran_count = ran_count + 1
			end
		end
	end

	if ran_count == 0 then
		vim.notify("[marimo] no marimo cells intersect visual selection", vim.log.levels.WARN)
		return
	end

	vim.notify(string.format("[marimo] ran %d cells from visual selection", ran_count), vim.log.levels.INFO)
end

--- Run all markdown-targeted cells in the current buffer.
function M.run_markdown_cells()
	local bufnr = vim.api.nvim_get_current_buf()
	local session = _sessions[bufnr]

	if not session then
		vim.notify("[marimo] not attached (run :MarimoAttach)", vim.log.levels.WARN)
		return
	end
	if not session.ready then
		vim.notify("[marimo] session is not ready yet", vim.log.levels.WARN)
		return
	end

	run_markdown_cells_for_buffer(bufnr, session, false)
end

--- Jump cursor to the start line of a 0-based marimo cell index.
--- @param cell_index integer
function M.jump_to_cell(cell_index)
	local bufnr = vim.api.nvim_get_current_buf()
	local idx = tonumber(cell_index)
	if not idx then
		vim.notify("[marimo] invalid cell index", vim.log.levels.WARN)
		return
	end

	idx = math.floor(idx)
	if idx < 0 then
		vim.notify("[marimo] cell index must be >= 0", vim.log.levels.WARN)
		return
	end

	local ranges = parser.get_cell_ranges(bufnr)
	if #ranges == 0 then
		vim.notify("[marimo] no marimo cells found in current buffer", vim.log.levels.WARN)
		return
	end

	local target = ranges[idx + 1]
	if not target then
		vim.notify(string.format("[marimo] cell index out of range (0..%d)", #ranges - 1), vim.log.levels.WARN)
		return
	end

	vim.api.nvim_win_set_cursor(0, { target.start, 0 })
	vim.cmd("normal! zvzz")
	vim.notify(string.format("[marimo] jumped to cell %d", idx), vim.log.levels.INFO)
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
