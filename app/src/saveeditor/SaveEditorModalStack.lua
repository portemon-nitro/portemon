-- Owns retained Save Editor modal layers and their opener records.

---@class SaveEditorModalStack
---@field push fun(self: SaveEditorModalStack, layer: table<string, unknown>)
---@field top fun(self: SaveEditorModalStack): table<string, unknown>?
---@field pop fun(self: SaveEditorModalStack): table<string, unknown>?
---@field layers fun(self: SaveEditorModalStack): table[]
---@field dispose fun(self: SaveEditorModalStack)
local ModalStack = {}
ModalStack.__index = ModalStack

local KINDS = {
  leave = true,
  ["bag-item"] = true,
  ["bag-remove"] = true,
  move = true,
  choice = true,
  number = true,
  name = true,
}

---@param value unknown
---@return unknown
local function copyValue(value)
  if type(value) ~= "table" then
    return value
  end
  local result = {}
  for key, child in pairs(value) do
    result[key] = copyValue(child)
  end
  return result
end

---@param layer table<string, unknown>
---@return table<string, unknown>
local function detachLayer(layer)
  return {
    id = layer.id,
    kind = layer.kind,
    payload = copyValue(layer.payload),
    opener = copyValue(layer.opener),
  }
end

---@param layers table[]
---@return table[]
local function detachAll(layers)
  local snapshot = {}
  for index, layer in ipairs(layers) do
    snapshot[index] = detachLayer(layer)
  end
  return snapshot
end

function ModalStack.new()
  return setmetatable(
    { _layers = {}, _ids = {}, _revision = 0, _cachedLayers = nil, _cachedRevision = nil },
    ModalStack
  )
end

-- Returns the detached layers snapshot shared by readers, rebuilding it
-- only after a stack mutation moved the revision forward. Readers always
-- receive a further copy, so neither the owned records nor this cached
-- representation can be mutated from outside.
---@return table[]
function ModalStack:_detachedLayers()
  if self._cachedLayers == nil or self._cachedRevision ~= self._revision then
    self._cachedLayers = detachAll(self._layers)
    self._cachedRevision = self._revision
  end
  return assert(self._cachedLayers, "a revision always materializes its detached snapshot")
end

function ModalStack:push(layer)
  assert(type(layer) == "table", "modal layer is required")
  assert(type(layer.id) == "string" and layer.id ~= "", "modal layer identity is required")
  assert(KINDS[layer.kind] == true, "unknown Save Editor modal layer kind")
  assert(type(layer.payload) == "table", "modal layer payload is required")
  assert(type(layer.opener) == "table", "modal layer opener is required")
  assert(type(layer.opener.controlId) == "string", "modal opener control is required")
  assert(type(layer.opener.regionId) == "string", "modal opener region is required")
  assert(type(layer.opener.scrollAnchor) == "number", "modal opener scroll anchor is required")
  assert(not self._ids[layer.id], "a live modal layer identity cannot be pushed twice")
  self._layers[#self._layers + 1] = layer
  self._ids[layer.id] = true
  self._revision = self._revision + 1
  self._cachedLayers = nil
end

function ModalStack:top()
  local layer = self._layers[#self._layers]
  if layer == nil then
    return nil
  end
  return detachLayer(layer)
end

function ModalStack:pop()
  local layer = self._layers[#self._layers]
  if layer ~= nil then
    self._layers[#self._layers] = nil
    self._ids[layer.id] = nil
    self._revision = self._revision + 1
    self._cachedLayers = nil
  end
  return layer
end

function ModalStack:layers()
  return copyValue(self:_detachedLayers())
end

function ModalStack:dispose()
  self._layers = {}
  self._ids = {}
  self._revision = 0
  self._cachedLayers = nil
  self._cachedRevision = nil
end

return ModalStack
