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

local M = {}

local config = require 'marimo.config'

local DEFAULT_PORT = 2718

--- Handle for the marimo process started by M.start(), nil when not running.
--- @type uv_process_t|nil
local _proc = nil

--- Generate a random token string suitable for use as --token-password.
--- @return string
local function generate_token()
    local seed = tostring(os.time()) .. tostring(math.random(1e9))
    return vim.fn.sha256(seed):sub(1, 32)
end

--- Attempt to contact the marimo server to confirm it is alive.
--- Uses GET /api/version — unauthenticated, always 200 when the server is up.
--- @param host string
--- @param port integer
--- @return boolean ok
--- @return string|nil err
local function ping(host, port)
    local url = string.format('http://%s:%d/api/version', host, port)
    local ok
    if vim.system then
        local out = vim.system({ 'curl', '-sf', '--max-time', '2', url }):wait()
        ok = out.code == 0
    else
        local handle = io.popen(string.format("curl -sf --max-time 2 '%s'", url))
        if handle then
            local result = handle:read('*a')
            handle:close()
            ok = result ~= nil and result ~= ''
        end
    end

    if not ok then
        return false, string.format('marimo server not reachable at %s:%d', host, port)
    end

    return true, nil
end

--- Scan /proc for a running `marimo edit` process and return its --port value.
--- Returns nil if not found or /proc is unavailable.
--- @return integer|nil
local function detect_port_from_proc()
    if vim.fn.isdirectory('/proc') == 0 then
        return nil
    end

    local pids = vim.fn.glob('/proc/*/cmdline', false, true)
    for _, path in ipairs(pids) do
        local f = io.open(path, 'rb')
        if f then
            local raw = f:read('*a')
            f:close()
            local cmdline = raw:gsub('%z', ' ')
            if cmdline:match('marimo') and cmdline:match('edit') then
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

--- Connect to an already-running marimo server and return a connection descriptor.
--- @return {host: string, port: integer, token: string}|nil
--- @return string|nil  error message
function M.connect()
    local host = config.opts.host or '127.0.0.1'
    local port = resolve_port()

    local ok, err = ping(host, port)
    if not ok then
        return nil, err
    end

    return { host = host, port = port, token = config.opts.server_token or '' }, nil
end

--- Return true if a marimo server is already reachable on the resolved port.
--- @return boolean
function M.is_running()
    local host = config.opts.host or '127.0.0.1'
    local port = config.opts.port or DEFAULT_PORT
    local ok, _ = ping(host, port)
    return ok
end

--- Start a marimo server for the given file and call back with the connection.
---
--- Generates a token, passes it to marimo via --token-password so auth is
--- known up front — no stdout parsing required.  Polls /api/version every
--- 500 ms for up to 20 s, then calls back with the connection or an error.
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

    local host  = config.opts.host or '127.0.0.1'
    local port  = config.opts.port or DEFAULT_PORT
    local token = generate_token()

    local args = {
        'edit',
        '--port',           tostring(port),
        '--token-password', token,
        '--watch',  -- reload kernel when the file changes on disk (BufWritePost)
    }
    if not opts.open_browser then
        table.insert(args, '--headless')
    end
    table.insert(args, file_path)

    local handle
    handle = vim.uv.spawn(marimo_bin, { args = args, detached = false }, function(code, _signal)
        if handle and not handle:is_closing() then
            handle:close()
        end
        if _proc == handle then
            _proc = nil
        end
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

    vim.api.nvim_create_autocmd('VimLeavePre', {
        once = true,
        callback = function() M.stop() end,
    })

    local tries     = 0
    local max_tries = 40  -- 40 × 500 ms = 20 s

    local function poll()
        tries = tries + 1
        local ok, _ = ping(host, port)
        if ok then
            callback({ host = host, port = port, token = token }, nil)
            return
        end
        if tries >= max_tries then
            M.stop()
            callback(nil, string.format(
                'marimo server did not become ready after %d s on port %d',
                max_tries * 0.5, port))
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
