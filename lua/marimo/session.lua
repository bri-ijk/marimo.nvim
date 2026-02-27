--- session.lua
--- Manages the connection to a running marimo server for a single notebook file.
---
--- Responsibilities:
---   1. Spawn websocat as a stdio subprocess to bridge the WebSocket connection (Neovim has no built-in WebSocket client).
---   2. Connect to ws://<host>:<port>/ws?session_id=<uuid>&file=<path>
---   3. Parse the kernel-ready message to build an ordered cell_id list.
---   4. Expose focus_cell(index) which POSTs to /api/kernel/focus_cell once
---      that endpoint exists upstream (currently a documented no-op stub).
---   5. Expose refresh() to re-request kernel-ready after a file save.
---
--- One Session object is created per attached buffer.

local M = {}
M.__index = M

local config = require 'marimo.config'

-- ── Helpers ──────────────────────────────────────────────────────────────────

--- Percent-encode a string for safe use in a URI query parameter.
--- Encodes everything except unreserved characters (RFC 3986 §2.3).
--- @param s string
--- @return string
local function uri_encode(s)
    return s:gsub('[^A-Za-z0-9%-._~]', function(c)
        return string.format('%%%02X', c:byte())
    end)
end

--- Generate a random UUID v4 string.
--- @return string
local function uuid4()
    local template = 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'
    return template:gsub('[xy]', function(c)
        local v = (c == 'x') and math.random(0, 0xf) or math.random(8, 0xb)
        return string.format('%x', v)
    end)
end

--- Find websocat binary: config override → PATH.
--- @return string|nil
local function find_websocat()
    if config.opts.websocat_bin then
        return config.opts.websocat_bin
    end
    -- vim.fn.exepath returns '' when not found.
    local found = vim.fn.exepath('websocat')
    if found ~= '' then
        return found
    end
    return nil
end

-- Session constructor

--- Create a new Session for the given connection descriptor and notebook path.
---
--- @param conn {host: string, port: integer, token: string}
--- @param notebook_path string  absolute path to the .py notebook file
--- @return table  Session object
function M.new(conn, notebook_path)
    local self = setmetatable({}, M)
    self.conn = conn
    self.notebook_path = notebook_path
    self.session_id = uuid4()
    self.cell_ids = {} -- ordered list: cell_ids[i] = marimo CellId (1-based)
    self.ready = false -- true once kernel-ready has been parsed
    self.closed = false

    -- websocat subprocess handles
    self._ws_handle = nil
    self._stdin_pipe = nil
    self._read_buffer = ''

    -- Callbacks registered by events.lua
    self._on_ready = nil -- called when cell_ids is populated / refreshed

    return self
end

-- Internal: WebSocket I/O

--- Write a newline-terminated JSON message to websocat stdin (→ WebSocket).
--- @param msg table
function M:_send(msg)
    if self.closed or not self._stdin_pipe then
        return
    end
    local line = vim.json.encode(msg) .. '\n'
    self._stdin_pipe:write(line)
end

--- Dispatch a fully-assembled JSON message received from the server.
--- @param msg table
function M:_handle_message(msg)
    if msg.op == 'kernel-ready' then
        local data = msg.data or {}
        self.cell_ids = data.cell_ids or {}
        self.ready = true
        vim.defer_fn(function()
            if self._on_ready then
                self._on_ready(self.cell_ids)
            end
        end, 0)
    end
    -- Future: handle 'update-cell-ids' (cell reordering) here.
end

--- Process raw data arriving from websocat stdout.
--- Messages are newline-delimited JSON; reads may be fragmented.
--- @param data string
function M:_on_data(data)
    self._read_buffer = self._read_buffer .. data
    local s = self._read_buffer:find('\n')
    while s do
        local line = self._read_buffer:sub(1, s - 1)
        self._read_buffer = self._read_buffer:sub(s + 1)
        s = self._read_buffer:find('\n')

        if line ~= '' then
            local ok, msg = pcall(vim.json.decode, line)
            if ok and type(msg) == 'table' then
                self:_handle_message(msg)
            end
        end
    end
end

-- Public: connect / close

--- Start the websocat subprocess and connect to the marimo WebSocket.
--- Calls on_ready(cell_ids) once kernel-ready is received.
---
--- @param on_ready fun(cell_ids: string[])|nil
--- @return string|nil  error message (nil = success)
function M:connect(on_ready)
    local websocat = find_websocat()
    if not websocat then
        return
            'websocat not found. Install it (cargo install websocat) and ensure it is on PATH, '
            .. 'or set vim.g.marimo_websocat_bin / require("marimo").setup({ websocat_bin = "..." }).'
    end

    self._on_ready    = on_ready

    local ws_url      = string.format(
        'ws://%s:%d/ws?session_id=%s&file=%s',
        self.conn.host,
        self.conn.port,
        self.session_id,
        uri_encode(self.notebook_path)
    )

    local stdin_pipe  = assert(vim.uv.new_pipe())
    local stdout_pipe = assert(vim.uv.new_pipe())
    local stderr_pipe = assert(vim.uv.new_pipe())

    local args        = {
        '--no-line',      -- don't add extra newlines
        '-B', '10485760', -- 10 MiB max message size
        '--origin', string.format('http://%s:%d', self.conn.host, self.conn.port),
        ws_url,
    }

    local handle, _   = vim.uv.spawn(websocat, {
        args = args,
        stdio = { stdin_pipe, stdout_pipe, stderr_pipe },
    })

    if not handle then
        stdin_pipe:close(); stdout_pipe:close(); stderr_pipe:close()
        return 'failed to spawn websocat'
    end

    self._ws_handle  = handle
    self._stdin_pipe = stdin_pipe

    -- Read stdout → parse messages
    stdout_pipe:read_start(function(err, data)
        if data then
            vim.defer_fn(function()
                self:_on_data(data)
            end, 0)
        elseif not data then
            -- EOF: websocat exited (server closed connection or websocat crashed)
            vim.defer_fn(function()
                if not self.closed then
                    self.ready = false
                    vim.notify('[marimo] WebSocket connection lost', vim.log.levels.WARN)
                end
            end, 0)
        end
    end)

    -- Drain stderr so the pipe doesn't block.
    stderr_pipe:read_start(function(_, _) end)

    return nil -- success
end

--- Tear down the websocat subprocess and pipes without marking the session
--- as permanently closed.  Used internally by both close() and refresh().
function M:_teardown()
    self.ready = false
    if self._stdin_pipe and not self._stdin_pipe:is_closing() then
        self._stdin_pipe:close()
    end
    if self._ws_handle and not self._ws_handle:is_closing() then
        self._ws_handle:kill()
    end
    self._stdin_pipe = nil
    self._ws_handle  = nil
end

--- Close the WebSocket connection and kill websocat.
function M:close()
    if self.closed then return end
    self.closed = true
    self:_teardown()
end

-- Public: focus a cell

--- Tell the browser to scroll to the cell at the given 0-based index.
---
--- Currently this function is a documented stub: the upstream marimo server
--- does not yet expose an HTTP endpoint to trigger FocusCellNotification from
--- an external client.  See: https://github.com/marimo-team/marimo (open issue)
---
--- Once the endpoint exists the implementation below should be uncommented and
--- the stub removed.
---
--- @param cell_index integer  0-based cell index matching kernel-ready order
function M:focus_cell(cell_index)
    if not self.ready then return end

    -- cell_ids is 1-based in Lua; cell_index is 0-based from the parser.
    local cell_id = self.cell_ids[cell_index + 1]
    if not cell_id then return end

    -- STUB
    -- The endpoint POST /api/kernel/focus_cell does not yet exist in marimo.
    -- When it is added upstream, replace this comment block with the curl call
    -- below (already wired up, just needs the endpoint to be live).
    --
    -- vim.system({
    --   'curl', '-sf', '-X', 'POST',
    --   '-H', 'Content-Type: application/json',
    --   '-H', 'Marimo-Session-Id: ' .. self.session_id,
    --   '-H', 'Marimo-Server-Token: ' .. self.conn.token,
    --   '-d', vim.json.encode({ cell_id = cell_id }),
    --   string.format(
    --     'http://%s:%d/api/kernel/focus_cell',
    --     self.conn.host, self.conn.port
    --   ),
    -- }, { text = true })
    -- END STUB

    -- For debugging: expose what would be sent so the user can test manually.
    vim.api.nvim_echo(
        { { string.format('[marimo] focus_cell stub: cell_id=%s (index %d)', cell_id, cell_index),
            'Comment' } },
        false, {}
    )
end

--- Request a fresh kernel-ready by closing and reopening the WebSocket.
--- Call this after `:w` when cells may have been reordered in the file.
function M:refresh()
    if self.closed then return end
    local on_ready = self._on_ready
    self:_teardown()
    self._read_buffer = ''
    self.session_id = uuid4()
    self:connect(on_ready)
end

return M
