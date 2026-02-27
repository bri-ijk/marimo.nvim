--- server.lua
--- Locates a running marimo server and retrieves its auth token.
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

return M
