--- parser.lua
--- Scans a marimo .py buffer for @app.cell (and related) decorator lines
--- and maps cursor line numbers to 0-based cell indices.
---
--- Marimo cell delimiters recognised:
---   @app.cell
---   @app.cell(...)
---   @app.function
---   @app.class_definition
---   with app.setup:   (treated as cell index 0 when present)
---
--- Each delimiter line begins a new cell that runs until the next delimiter
--- or end-of-file. The index is the order of appearance (0-based), matching
--- the order of cell_ids[] in the kernel-ready message.

local M = {}

--- Per-buffer cache of parsed cell ranges keyed by changedtick.
--- @type table<integer, {tick: integer, lines: string[], ranges: {start: integer, finish: integer}[]}>
local _cache = {}

--- Strip one marimo wrapper indentation level from each line.
--- @param lines string[]
--- @return string[]
local function deindent_cell_body(lines)
	local body = {}
	for _, line in ipairs(lines) do
		body[#body + 1] = line:gsub("^    ", "", 1)
	end
	return body
end

--- Remove the generated top-level `return ...` block that marimo saves at the
--- end of each cell wrapper. This keeps only the executable cell body.
---
--- We remove from the last line matching exactly one wrapper indentation level
--- (`"    return"`) to the end of the extracted function body, which handles
--- both one-line and multi-line tuple returns without touching nested returns.
---
--- @param lines string[]
--- @return string[]
local function strip_generated_return(lines)
	local return_start = nil
	for i = #lines, 1, -1 do
		if lines[i]:match("^    return%f[%W]") or lines[i] == "    return" then
			return_start = i
			break
		end
	end

	local last = #lines
	while last > 0 and lines[last]:match("^%s*$") do
		last = last - 1
	end

	if return_start and return_start <= last then
		last = return_start - 1
		while last > 0 and lines[last]:match("^%s*$") do
			last = last - 1
		end
	end

	local body = {}
	for i = 1, last do
		body[#body + 1] = lines[i]
	end
	return body
end

--- Pattern that matches a marimo setup block.
local SETUP_PATTERN = "^%s*with%s+app%.setup%s*(%b())?%s*:"
local CELL_PATTERN = "^%s*@app%.cell"
local FUNCTION_PATTERN = "^%s*@app%.function"
local CLASS_PATTERN = "^%s*@app%.class_definition"

local DECORATOR_PATTERNS = {
	CELL_PATTERN,
	FUNCTION_PATTERN,
	CLASS_PATTERN,
}

--- Return true if a line is a marimo setup block.
--- @param line string
--- @return boolean
local function is_setup_line(line)
	if line:match(SETUP_PATTERN) then
		return true
	end
	local stripped = line:gsub("^%s+", "")
	if stripped:match("^with%s+app%s*%.%s*setup%f[%W]") then
		return stripped:match(":") ~= nil
	end
	local compact = line:gsub("%s+", "")
	return compact:match("^withapp%.setup") ~= nil
end

--- Return the delimiter kind for a line, or nil if not a delimiter.
--- @param line string
--- @return string|nil

local function delimiter_kind(line)
	if line:match(CELL_PATTERN) then
		return "cell"
	end
	if line:match(FUNCTION_PATTERN) then
		return "function"
	end
	if line:match(CLASS_PATTERN) then
		return "class_definition"
	end
	if is_setup_line(line) then
		return "setup"
	end
	return nil
end

--- Returns true if `line` (1-indexed string content) is a cell delimiter.
--- @param line string
--- @return boolean
local function is_delimiter(line)
	if is_setup_line(line) then
		return true
	end
	for _, pat in ipairs(DECORATOR_PATTERNS) do
		if line:match(pat) then
			return true
		end
	end
	return false
end

--- Build a list of {start_line, end_line} ranges (1-based, inclusive) for
--- every cell in the buffer, in order.
---
--- @param bufnr integer  buffer handle (0 = current)
--- @return {start: integer, finish: integer}[]
function M.get_cell_ranges(bufnr)
	bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
	local tick = vim.api.nvim_buf_get_changedtick(bufnr)
	local cached = _cache[bufnr]
	if cached and cached.tick == tick then
		return cached.ranges
	end

	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local ranges = {}
	local current_start = nil

	for i, line in ipairs(lines) do
		if is_delimiter(line) then
			if current_start ~= nil then
				-- close the previous cell just before this delimiter
				ranges[#ranges].finish = i - 1
			end
			current_start = i
			ranges[#ranges + 1] = { start = i, finish = #lines }
		end
	end

	-- If no delimiters found the file is not a valid marimo notebook.
	_cache[bufnr] = { tick = tick, lines = lines, ranges = ranges }
	return ranges
end

--- Return a list of cell kinds aligned with get_cell_ranges.
--- Values: "cell", "function", "class_definition", "setup".
--- @param bufnr integer
--- @return string[]
function M.get_cell_kinds(bufnr)
	bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
	local tick = vim.api.nvim_buf_get_changedtick(bufnr)
	local cached = _cache[bufnr]
	local lines
	local ranges
	if cached and cached.tick == tick then
		lines = cached.lines
		ranges = cached.ranges
	else
		lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		ranges = M.get_cell_ranges(bufnr)
	end

	local kinds = {}
	for i, range in ipairs(ranges) do
		local line = lines[range.start] or ""
		kinds[i] = delimiter_kind(line) or "cell"
	end

	return kinds
end

--- Given a 1-based cursor line, return the 0-based cell index the cursor is
--- inside, or nil if the cursor is above the first cell delimiter.
---
--- @param bufnr integer
--- @param cursor_line integer  1-based
--- @return integer|nil
function M.cell_index_at_line(bufnr, cursor_line)
	local ranges = M.get_cell_ranges(bufnr)
	if #ranges == 0 then
		return nil
	end

	-- Walk backwards: the cursor belongs to the last cell whose start <= cursor.
	for i = #ranges, 1, -1 do
		if cursor_line >= ranges[i].start then
			return i - 1 -- convert to 0-based
		end
	end

	return nil -- cursor is above the first cell
end

--- Return the raw marimo cell code body for a 0-based cell index.
--- For `@app.cell`-style cells, this strips decorators and the `def` wrapper,
--- then de-indents the function body by one level. For `with app.setup:` cells,
--- it returns the indented block body.
---
--- @param bufnr integer
--- @param cell_index integer  0-based
--- @return string|nil
function M.cell_code_at_index(bufnr, cell_index)
	bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
	local ranges = M.get_cell_ranges(bufnr)
	local range = ranges[cell_index + 1]
	if not range then
		return nil
	end

	local tick = vim.api.nvim_buf_get_changedtick(bufnr)
	local cached = _cache[bufnr]
	local full_lines
	if cached and cached.tick == tick then
		full_lines = cached.lines
	else
		full_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	end

	local lines = {}
	for i = range.start, range.finish do
		lines[#lines + 1] = full_lines[i]
	end
	if #lines == 0 then
		return nil
	end

	if is_setup_line(lines[1]) then
		local body = {}
		for i = 2, #lines do
			body[#body + 1] = lines[i]
		end
		return table.concat(deindent_cell_body(body), "\n")
	end

	local def_line = nil
	for i, line in ipairs(lines) do
		if line:match("^def%s+") or line:match("^async%s+def%s+") then
			def_line = i
			break
		end
	end

	if not def_line then
		return nil
	end

	local body = {}
	for i = def_line + 1, #lines do
		body[#body + 1] = lines[i]
	end

	body = strip_generated_return(body)
	body = deindent_cell_body(body)

	return table.concat(body, "\n")
end

--- Return true if the buffer contains a `with app.setup:` block.
--- @param bufnr integer
--- @return boolean
function M.has_setup_cell(bufnr)
	bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
	local tick = vim.api.nvim_buf_get_changedtick(bufnr)
	local cached = _cache[bufnr]
	local lines
	if cached and cached.tick == tick then
		lines = cached.lines
	else
		lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	end

	for _, line in ipairs(lines) do
		if is_setup_line(line) then
			return true
		end
	end

	return false
end

return M
