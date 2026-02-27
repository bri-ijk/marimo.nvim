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

-- Pattern that matches the start of any marimo cell-like block.
local CELL_PATTERNS = {
    '^@app%.cell',
    '^@app%.function',
    '^@app%.class_definition',
    '^with%s+app%.setup%s*:',
}

--- Returns true if `line` (1-indexed string content) is a cell delimiter.
--- @param line string
--- @return boolean
local function is_delimiter(line)
    for _, pat in ipairs(CELL_PATTERNS) do
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
    return ranges
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

return M
