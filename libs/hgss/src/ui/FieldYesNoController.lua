-- Owns the semantic state of the field Yes/No command. Selection changes and
-- answers play the dialogue-advance blip through the composed audio host,
-- matching the source list-menu behavior; boundary no-ops stay silent and a
-- missing host keeps the choice silent.

---@class FieldYesNoController
---@field _audio table<string, unknown>? { play: fun(self: table<string, unknown>, soundRef: string) }
local FieldYesNoController = {}
FieldYesNoController.__index = FieldYesNoController

---@param opts { audio: table<string, unknown>? }?
---@return FieldYesNoController
function FieldYesNoController.new(opts)
  if opts ~= nil then
    assert(type(opts) == "table", "field yes/no options must be a table")
    assert(opts.audio == nil or type(opts.audio.play) == "function", "field yes/no audio host must provide play")
  end
  local audio = opts and opts.audio or nil
  return setmetatable({ active = false, selectedIndex = 0, result = nil, _audio = audio }, FieldYesNoController)
end

---@param self FieldYesNoController
local function playAdvance(self)
  if self._audio then
    self._audio:play("SEQ_SE_DP_SELECT")
  end
end

---@param request { yesText: string, noText: string, frameIndex: integer? }
function FieldYesNoController:open(request)
  assert(not self.active, "field yes/no choice is already active")
  assert(type(request) == "table", "field yes/no request is required")
  assert(type(request.yesText) == "string" and type(request.noText) == "string", "field yes/no labels are required")
  assert(
    request.frameIndex == nil
      or (type(request.frameIndex) == "number" and request.frameIndex % 1 == 0 and request.frameIndex >= 0),
    "field yes/no frame is invalid"
  )
  self.active = true
  self.selectedIndex = 0
  self.result = nil
  self.yesText = request.yesText
  self.noText = request.noText
  self.frameIndex = request.frameIndex
end

-- Semantic choice events translated by the live presentation host from the
-- fixed-tick input lane. Raw directional/action/cancel edges never reach
-- this controller directly.
---@param event { type: string, row: integer?, direction: string? }
function FieldYesNoController:handleEvent(event)
  if not self.active then
    return
  end
  assert(type(event) == "table" and type(event.type) == "string", "choice event is invalid")
  if event.type == "focus" then
    assert(event.row == 0 or event.row == 1, "choice focus is outside the two choices")
    if self.selectedIndex ~= event.row then
      self.selectedIndex = event.row
      playAdvance(self)
    end
  elseif event.type == "navigate" then
    if event.direction == "up" then
      if self.selectedIndex > 0 then
        self.selectedIndex = self.selectedIndex - 1
        playAdvance(self)
      end
    elseif event.direction == "down" then
      if self.selectedIndex < 1 then
        self.selectedIndex = self.selectedIndex + 1
        playAdvance(self)
      end
    elseif event.direction == "left" or event.direction == "right" then
      -- Horizontal edges never move the two-row selection.
    else
      assert(false, "choice navigate direction is invalid")
    end
  elseif event.type == "confirm" then
    self.result = { accepted = self.selectedIndex == 0 }
    playAdvance(self)
  elseif event.type == "cancel" then
    self.result = { accepted = false }
    playAdvance(self)
  else
    assert(false, "unknown choice event " .. event.type)
  end
end

---@return table<string, unknown>
function FieldYesNoController:status()
  return {
    active = self.active,
    selectedIndex = self.selectedIndex,
    yesText = self.yesText,
    noText = self.noText,
    frameIndex = self.frameIndex,
    result = self.result and { accepted = self.result.accepted } or nil,
  }
end

---@return { accepted: boolean }?
function FieldYesNoController:takeResult()
  if not self.result then
    return nil
  end
  local result = self.result
  self.result = nil
  return { accepted = result.accepted }
end

function FieldYesNoController:close()
  self.active = false
  self.result = nil
  self.yesText = nil
  self.noText = nil
  self.frameIndex = nil
end

return FieldYesNoController
