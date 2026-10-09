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

function ModalStack.new()
  return setmetatable({ _layers = {}, _ids = {} }, ModalStack)
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
end

function ModalStack:top()
  return self._layers[#self._layers]
end

function ModalStack:pop()
  local layer = self:top()
  if layer ~= nil then
    self._layers[#self._layers] = nil
    self._ids[layer.id] = nil
  end
  return layer
end

function ModalStack:layers()
  local function copy(value)
    if type(value) ~= "table" then
      return value
    end
    local result = {}
    for key, child in pairs(value) do
      result[key] = copy(child)
    end
    return result
  end
  local snapshot = {}
  for index, layer in ipairs(self._layers) do
    snapshot[index] = {
      id = layer.id,
      kind = layer.kind,
      payload = copy(layer.payload),
      opener = copy(layer.opener),
    }
  end
  return snapshot
end

function ModalStack:dispose()
  self._layers = {}
  self._ids = {}
end

return ModalStack
