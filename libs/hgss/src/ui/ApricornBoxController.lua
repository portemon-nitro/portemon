-- Owns transient Apricorn Box focus, quantity, prompt, and value-only selection.

---@class ApricornBoxController
---@field private _mode "browse"|"kurt_select"
---@field private _service table<string, unknown>
---@field private _keys string[] canonical semantic Apricorn keys
---@field private _selected integer
---@field private _quantity integer
---@field private _phase string
---@field private _delay integer
---@field private _cursorOffsetY integer
---@field private _cursorReturnTicks integer
---@field private _returnPhase string?
---@field private _action integer
---@field private _effect fun(sequence: string|integer)
---@field private _prompt YesNoPromptController
---@field private _promptPlacement { x: integer, y: integer, shape: string, initialSelection: string }
---@field private _closed boolean
---@field private _result table<string, unknown>?
local ApricornBoxController = {}
ApricornBoxController.__index = ApricornBoxController
local YesNoPromptController = require("libs.hgss.src.ui.YesNoPromptController")

local SOURCE_SOUND = { browseSelect = 1515, select = 1500, cancel = 1514, touchCancel = 1666 }
local ROW_SELECTION_DELAY = 4

local function integer(value, minimum, maximum)
  return type(value) == "number" and value % 1 == 0 and value >= minimum and value <= maximum
end

---@param opts table<string, unknown>
---@return ApricornBoxController
function ApricornBoxController.new(opts)
  assert(type(opts) == "table", "the Box controller requires options")
  assert(opts.mode == "browse" or opts.mode == "kurt_select", "the Box controller requires a supported mode")
  local service = assert(opts.service, "the Box controller borrows the live Apricorn service")
  assert(type(service.capture) == "function", "the Box controller reads fresh stock snapshots")
  local keys = assert(opts.apricornKeys, "the Box controller requires canonical Apricorn keys")
  assert(type(keys) == "table" and #keys == 7, "the Box controller requires seven canonical Apricorn keys")
  local ownedKeys = {}
  local seenKeys = {}
  for _, key in ipairs(keys) do
    assert(type(key) == "string" and key ~= "", "Apricorn keys are semantic names")
    assert(not seenKeys[key], "canonical Apricorn keys are unique")
    seenKeys[key] = true
    ownedKeys[#ownedKeys + 1] = key
  end
  assert(type(opts.effect) == "function", "the Box controller needs the composed UI sound port")
  local promptShape = assert(opts.promptShape, "the Box controller requires the generated compact prompt shape")
  local promptPlacement = assert(opts.promptPlacement, "the Box controller requires source action placement")
  assert(promptPlacement.shape == "compact", "the Box controller uses the compact source prompt")
  local prompt = YesNoPromptController.new(promptShape, opts.effect)
  return setmetatable({
    _mode = opts.mode,
    _service = service,
    _keys = ownedKeys,
    _selected = 1,
    _quantity = 1,
    _phase = opts.mode == "browse" and "browse" or "rows",
    _delay = 0,
    _cursorOffsetY = 0,
    _action = opts.mode == "browse" and 3 or 1,
    _effect = opts.effect,
    _prompt = prompt,
    _promptPlacement = promptPlacement,
    _closed = false,
    _result = nil,
  }, ApricornBoxController)
end

function ApricornBoxController:_play(sequence)
  self._effect(sequence)
end

function ApricornBoxController:_selectRow(index, touch)
  if self._phase ~= "browse" and self._phase ~= "rows" then
    return
  end
  self._selected = index
  self._action = self._mode == "browse" and 3 or 1
  local row = self:status().rows[index]
  if row.quantity == 0 then
    return
  end
  if self._mode == "browse" then
    self:_play(touch and SOURCE_SOUND.browseSelect or SOURCE_SOUND.select)
    self._phase = "actions"
    self._cursorOffsetY = 6
    self:_play(SOURCE_SOUND.select)
    return
  end
  self:_play(SOURCE_SOUND.select)
  self._quantity = 1
  self._phase = "selection_delay"
  self._delay = ROW_SELECTION_DELAY
  self._cursorOffsetY = 0
end

local function adjustQuantity(self, delta)
  local maximum = self:status().rows[self._selected].quantity
  if maximum == 0 then
    return
  end
  local quantity = math.max(1, math.min(maximum, self._quantity + delta))
  if quantity ~= self._quantity then
    self._quantity = quantity
    self:_play(SOURCE_SOUND.select)
  end
end

local function activateAction(self)
  if self._mode == "browse" and self._action ~= 3 then
    return
  end
  if self._mode == "kurt_select" then
    if self._action == 1 then
      self._phase = "quantity"
    else
      self._phase = "row_return_delay"
      self._returnPhase = "rows"
      self._cursorReturnTicks = 4
      self._cursorOffsetY = 6
    end
  elseif self._action == 1 then
    local row = self:status().rows[self._selected]
    self._result = { kind = "closed", selected = { apricornKey = row.apricornKey, quantity = 1 } }
    self._closed = true
  else
    self._phase = "row_return_delay"
    self._returnPhase = "browse"
    self._cursorReturnTicks = 4
    self._cursorOffsetY = 6
  end
end

function ApricornBoxController:_openPrompt()
  self._phase = "confirm"
  self._prompt:open(self._promptPlacement)
end

---@param uiInput table[] semantic input events from the owning application
function ApricornBoxController:updateFixed(uiInput)
  assert(type(uiInput) == "table", "Box input is an ordered event list")
  if self._closed then
    return
  end
  if self._phase == "confirm" then
    self._prompt:updateFixed(uiInput)
    local answer = self._prompt:takeResult()
    if answer == "yes" then
      local row = self:status().rows[self._selected]
      self._result = {
        kind = "closed",
        selected = { apricornKey = row.apricornKey, quantity = self._quantity },
      }
      self._closed = true
    elseif answer == "no" then
      self._phase = "quantity"
    end
    return
  end
  if self._phase == "row_return_delay" then
    self._cursorOffsetY = self._cursorOffsetY - 2
    self._cursorReturnTicks = self._cursorReturnTicks - 1
    if self._cursorReturnTicks == 0 then
      self._phase = assert(self._returnPhase, "cursor return has a destination phase")
      self._returnPhase = nil
    end
    return
  end
  if self._phase == "selection_delay" then
    self._delay = self._delay - 1
    self._cursorOffsetY = math.min(6, self._cursorOffsetY + 2)
    if self._delay == 0 then
      self._phase = "actions"
      self._cursorOffsetY = 6
      self:_play(SOURCE_SOUND.select)
    end
  end
  for _, event in ipairs(uiInput) do
    assert(type(event) == "table" and type(event.type) == "string", "Box input events are records")
    if event.type == "pointer_cancel" then
      -- The presentation session drops a captured pointer before stale up events.
    elseif event.type == "cancel" or event.type == "dismiss" then
      self:_play(event.source == "touch" and SOURCE_SOUND.touchCancel or SOURCE_SOUND.cancel)
      if self._phase == "actions" then
        self._phase = "row_return_delay"
        self._returnPhase = self._mode == "browse" and "browse" or "rows"
        self._cursorReturnTicks = 4
        self._cursorOffsetY = 6
      else
        self._result = { kind = "closed" }
        self._closed = true
        return
      end
    elseif event.type == "touch_row" then
      assert(integer(event.index, 1, #self._keys), "Box touch selection names a canonical row")
      self:_selectRow(event.index, true)
    elseif event.type == "navigate" then
      assert(
        event.direction == "up" or event.direction == "down" or event.direction == "left" or event.direction == "right",
        "Box navigation uses a cardinal direction"
      )
      if self._phase == "actions" then
        local count = self._mode == "browse" and 3 or 2
        local previous = self._action
        if self._mode == "browse" then
          self._action = 3
        else
          self._action = event.direction == "up" and (previous == 1 and count or previous - 1)
            or (previous == count and 1 or previous + 1)
        end
        if previous ~= self._action then
          self:_play(SOURCE_SOUND.select)
        end
      elseif self._phase == "quantity" then
        if event.direction == "left" then
          adjustQuantity(self, -1)
        elseif event.direction == "right" then
          adjustQuantity(self, 1)
        elseif event.direction == "up" then
          adjustQuantity(self, 10)
        else
          adjustQuantity(self, -10)
        end
      elseif event.direction == "up" or event.direction == "down" then
        local previous = self._selected
        self._selected = event.direction == "up" and (previous == 1 and #self._keys or previous - 1)
          or (previous == #self._keys and 1 or previous + 1)
        if self._selected ~= previous then
          self:_play(SOURCE_SOUND.select)
        end
      end
    elseif event.type == "quantity_control" then
      assert(integer(event.index, 1, 6), "quantity controls use the six source controls")
      if self._phase == "quantity" then
        if event.index == 1 then
          self:_openPrompt()
          self:_play(SOURCE_SOUND.select)
        elseif event.index == 2 then
          self._phase = "quantity"
          self:_play(SOURCE_SOUND.cancel)
        else
          adjustQuantity(self, ({ [3] = 1, [4] = -1, [5] = 10, [6] = -10 })[event.index])
        end
      end
    elseif event.type == "action_control" then
      local count = self._mode == "browse" and 3 or 2
      assert(integer(event.index, 1, count), "Box action selection names a source menu row")
      if self._phase == "actions" then
        if self._mode == "browse" and event.index ~= 3 then
          -- Source USE and TASTE labels remain visible until their effects exist.
        else
          self._action = event.index
          self:_play(SOURCE_SOUND.select)
          activateAction(self)
          if self._closed then
            return
          end
        end
      end
    elseif event.type == "confirm" then
      if self._phase == "browse" then
        self:_selectRow(self._selected, false)
      elseif self._phase == "rows" then
        self:_selectRow(self._selected, false)
      elseif self._phase == "quantity" then
        self:_openPrompt()
        self:_play(SOURCE_SOUND.select)
      elseif self._phase == "actions" then
        self:_play(SOURCE_SOUND.select)
        activateAction(self)
        if self._closed then
          return
        end
      end
    else
      assert(event.type == "pointer_down", "Box input supports source actions and application pointer events")
    end
  end
end

---@return table<string, unknown>
function ApricornBoxController:status()
  local bucket = self._service:capture()
  assert(type(bucket) == "table" and type(bucket.apricorns) == "table", "the Apricorn service snapshot has stock")
  local rows = {}
  for index, key in ipairs(self._keys) do
    local quantity = bucket.apricorns[key] or 0
    assert(integer(quantity, 0, 99), "Apricorn stock is bounded by the service contract")
    rows[index] = { apricornKey = key, quantity = quantity }
  end
  local cursorSequenceId = self._phase == "selection_delay" and 4
    or self._phase == "row_return_delay" and 4
    or (self._phase == "actions" or self._phase == "quantity" or self._phase == "confirm") and 5
    or (self._phase == "rows" or self._phase == "browse") and self._cursorOffsetY ~= 0 and 3
    or self._phase == "rows" and 3
    or 0
  return {
    open = not self._closed,
    mode = self._mode,
    phase = self._phase,
    rows = rows,
    selectedIndex = self._selected,
    selectedAction = self._action,
    actionsEnabled = self._mode == "browse" and { false, false, true } or { true, true },
    quantity = self._quantity,
    maximum = rows[self._selected].quantity,
    confirmationPrompt = self._phase == "confirm" and self._prompt:status() or nil,
    cursorSequenceId = cursorSequenceId,
    cursorOffsetY = self._cursorOffsetY,
  }
end

---@return table<string, unknown>?
function ApricornBoxController:takeResult()
  local result = self._result
  self._result = nil
  return result
end

function ApricornBoxController:dispose()
  self._result = nil
  self._closed = true
  self._prompt:dispose()
end

return ApricornBoxController
