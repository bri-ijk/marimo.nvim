local M = {}

--- Percent-encode a string for safe use in a URI query parameter.
--- Encodes everything except unreserved characters (RFC 3986 section 2.3).
--- @param s string
--- @return string
function M.uri_encode(s)
	return s:gsub("[^A-Za-z0-9%-._~]", function(c)
		return string.format("%%%02X", c:byte())
	end)
end

return M
