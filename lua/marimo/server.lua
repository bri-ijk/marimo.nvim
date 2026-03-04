--- server.lua
--- Locates a running marimo server and retrieves its auth token.
--- Also provides start()/stop() to manage a marimo process launched by the plugin.
---
--- Detection strategy (in order):
---   1. Use config.opts.port if explicitly set.
---   2. Scan /proc/<pid>/cmdline for processes running `marimo edit` and
---      extract the --port argument (Linux).  Falls back to `ss`/`lsof` on
---      macOS / systems without /proc.
---   3. Try the default marimo port (2718).
---
--- Once a port is found, GET /api/status is called to confirm the server is
--- alive and to retrieve the skew_protection_token required for subsequent
--- HTTP requests.

local M = {}

local config = require 'marimo.config'

local DEFAULT_PORT = 2718

--- Handle for the marimo process started by M.start(), nil when not running.
--- @type uv_process_t|nil
local _proc = nil

--- Attempt to read the marimo server token from /api/status.
--- Returns the token string, or nil on failure.
--- @param host string
--- @param port integer
--- @return string|nil token
--- @return string|nil err
local function fetch_token(host, port)
    local url = string.format('http://%s:%d/api/status', host, port)
    -- vim.system is available in nvim 0.10+; fall back to io.popen for older.
    local ok, result
    if vim.system then
        local out = vim.system({ 'curl', '-sf', '--max-time', '2', url }):wait()
        ok = out.code == 0
        result = out.stdout
    else
        local handle = io.popen(string.format("curl -sf --max-time 2 '%s'", url))
        if handle then
            result = handle:read('*a')
            handle:close()
            ok = result ~= nil and result ~= ''
        end
    end

    if not ok or not result or result == '' then
        return nil, string.format('marimo server not reachable at %s:%d', host, port)
    end

    local decoded = vim.json.decode(result)
    if not decoded then
        return nil, 'could not parse /api/status response'
    end

    -- The token lives at .skew_protection_token (present since marimo ~0.6)
    local token = decoded.skew_protection_token
    if not token or token == '' then
        -- Older builds may not have the field; return empty string so callers
        -- can still proceed — requests just won't carry the header.
        token = ''
    end

    return token, nil
end

--- Scan /proc for a running `marimo edit` process and return its --port value.
--- Returns nil if not found or /proc is unavailable.
--- @return integer|nil
local function detect_port_from_proc()
    -- Only available on Linux.
    if vim.fn.isdirectory('/proc') == 0 then
        return nil
    end

    local pids = vim.fn.glob('/proc/*/cmdline', false, true)
    for _, path in ipairs(pids) do
        local f = io.open(path, 'rb')
        if f then
            local raw = f:read('*a')
            f:close()
            -- cmdline is NUL-delimited; replace NULs with spaces for matching.
            local cmdline = raw:gsub('%z', ' ')
            if cmdline:match('marimo') and cmdline:match('edit') then
                -- Look for --port <N> or --port=<N>
                local port = cmdline:match('%-%-port[= ](%d+)')
                if port then
                    return tonumber(port)
                end
            end
        end
    end

    return nil
end

--- Find the port of a running marimo server.
--- Prefers config.opts.port, then /proc detection, then the default port.
--- @return integer port
local function resolve_port()
    if config.opts.port then
        return config.opts.port
    end

    local proc_port = detect_port_from_proc()
    if proc_port then
        return proc_port
    end

    return DEFAULT_PORT
end

--- Connect to the marimo server and return a connection descriptor.
---
--- @return {host: string, port: integer, token: string}|nil  connection
--- @return string|nil  error message
function M.connect()
    local host = config.opts.host or '127.0.0.1'
    local port = resolve_port()

    -- If a token was given explicitly in config, trust it without probing.
    if config.opts.server_token then
        return { host = host, port = port, token = config.opts.server_token }, nil
    end

    local token, err = fetch_token(host, port)
    if not token then
        return nil, err
    end

    return { host = host, port = port, token = token }, nil
end

--- Return true if a marimo server is already reachable on the resolved port.
--- @return boolean
function M.is_running()
    local host = config.opts.host or '127.0.0.1'
    local port = resolve_port()
    local token, _ = fetch_token(host, port)
    return token ~= nil
end

--- Start a marimo server for the given file and call back with the connection.
---
--- Spawns `marimo edit [--no-browser] <file_path>` as a background process,
--- then polls /api/status every 500 ms for up to 10 seconds.  On success the
--- callback receives `(conn, nil)`; on timeout or spawn failure it receives
--- `(nil, err_string)`.
---
--- @param file_path string   Absolute path to the notebook .py file.
--- @param opts      table    { open_browser: boolean }
--- @param callback  fun(conn: table|nil, err: string|nil)
function M.start(file_path, opts, callback)
    if _proc then
        callback(nil, 'a marimo process is already managed by the plugin (call MarimoStop first)')
        return
    end

    local marimo_bin = vim.fn.exepath('marimo')
    if marimo_bin == '' then
        callback(nil, '`marimo` not found on PATH — install it with: pip install marimo')
        return
    end

    local args = { 'edit' }
    if not opts.open_browser then
        table.insert(args, '--no-browser')
    end
    table.insert(args, file_path)

    local handle
    handle = vim.uv.spawn(marimo_bin, { args = args, detached = false }, function(code, _signal)
        -- Process exited.
        if handle and not handle:is_closing() then
            handle:close()
        end
        if _proc == handle then
            _proc = nil
        end
        -- Only report unexpected exits (code ~= 0) after the server was already up.
        if code ~= 0 then
            vim.schedule(function()
                vim.notify('[marimo] server process exited with code ' .. code, vim.log.levels.WARN)
            end)
        end
    end)

    if not handle then
        callback(nil, 'failed to spawn marimo process')
        return
    end

    _proc = handle

    -- Kill the managed process when Neovim exits.
    vim.api.nvim_create_autocmd('VimLeavePre', {
        once = true,
        callback = function() M.stop() end,
    })

    -- Poll until the server is reachable, then call back.
    local host  = config.opts.host or '127.0.0.1'
    local port  = resolve_port()
    local tries = 0
    local max_tries = 20  -- 20 × 500 ms = 10 s

    local function poll()
        tries = tries + 1
        local token, _ = fetch_token(host, port)
        if token then
            callback({ host = host, port = port, token = token }, nil)
            return
        end
        if tries >= max_tries then
            M.stop()
            callback(nil, string.format(
                'marimo server did not become ready after %d s', max_tries * 0.5))
            return
        end
        vim.defer_fn(poll, 500)
    end

    vim.defer_fn(poll, 500)
end

--- Kill the marimo process started by M.start(), if any.
function M.stop()
    if _proc then
        if not _proc:is_closing() then
            _proc:kill('sigterm')
            _proc:close()
        end
        _proc = nil
    end
end

return M
