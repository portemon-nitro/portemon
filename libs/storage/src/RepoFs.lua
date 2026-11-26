-- Neutral repository-root reader for checked-in resources. An injected source
-- reader (for example love.filesystem inside a portable archive) is consulted
-- before the physical checkout. Paths stay confined to one canonical
-- repo-relative spelling; missing files remain nil.

---@class RepoFs
---@field private _root string
---@field private _sourceFs { read: fun(path: string): string|nil }?
local RepoFs = {}
RepoFs.__index = RepoFs

---@param root string repo root (source base directory)
---@param sourceFs { read: fun(path: string): string|nil }? archive/source reader
---@return RepoFs
function RepoFs.new(root, sourceFs)
  assert(type(root) == "string" and root ~= "", "repo fs requires the repo root")
  assert(sourceFs == nil or type(sourceFs.read) == "function", "repo fs source reader requires read(path)")
  return setmetatable({ _root = root, _sourceFs = sourceFs }, RepoFs)
end

-- Validate and canonicalize once before either backend is consulted.
---@param relativePath string
---@return string canonical
function RepoFs:_canonical(relativePath)
  assert(type(relativePath) == "string", "repo fs paths are repo-relative")
  local canonical = relativePath:gsub("\\", "/")
  assert(canonical:sub(1, 1) ~= "/", "repo fs paths are repo-relative")
  local components = {}
  for component in canonical:gmatch("[^/]+") do
    assert(component ~= "." and component ~= "..", "repo fs paths may not contain traversal components")
    components[#components + 1] = component
  end
  assert(#components > 0, "repo fs paths are repo-relative")
  return table.concat(components, "/")
end

-- Confines a repo-relative path below the physical root.
---@param relativePath string
---@return string
function RepoFs:_full(relativePath)
  local canonical = self:_canonical(relativePath)
  local full = self._root .. "/" .. canonical
  assert(full:sub(1, #self._root) == self._root, "repo fs path escapes the repo root")
  return full
end

---@param path string
---@return string|nil
function RepoFs:read(path)
  local canonical = self:_canonical(path)
  if self._sourceFs ~= nil then
    local sourced = self._sourceFs.read(canonical)
    if sourced ~= nil then
      return sourced
    end
  end
  local handle = io.open(self:_full(canonical), "rb")
  if not handle then
    return nil
  end
  local data = handle:read("*a")
  handle:close()
  return data
end

return RepoFs
