-- Coordinates the editor's asynchronous opening, input, session, and resources.

local ApplicationPresentation = require("libs.ui.src.ApplicationPresentation")
local CacheFs = require("libs.storage.src.CacheFs")
local Errors = require("libs.errors.src.Errors")
local FieldTextRenderer = require("libs.hgss.src.ui.FieldTextRenderer")
local HgssInputBindings = require("libs.hgss.src.ui.HgssInputBindings")
local PlayerData = require("libs.hgss.src.save.PlayerData")
local DisplayContext = require("libs.ui.src.DisplayContext")
local Interface = require("app.src.saveeditor.SaveEditorInterface")
local Renderer = require("app.src.saveeditor.SaveEditorRenderer")
local Controller = require("app.src.saveeditor.SaveEditorController")
local ValueEditor = require("app.src.saveeditor.SaveEditorValueEditor")
local Composition = require("app.src.saveeditor.SaveEditorComposition")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local Utf8Glyphs = require("libs.assets.src.Utf8Glyphs")

---@class SaveEditorState
---@field valueEditor SaveEditorValueEditor?
---@field versionId string
---@field saveId string
---@field width number
---@field height number
---@field derivedAssets { requestMilestone: fun(name: string, urgency: string): unknown }
---@field repositoryRoot string
---@field onResult fun(result: table<string, unknown>)
---@field displayContext DisplayContext
---@field controller SaveEditorController
---@field renderer SaveEditorRenderer?
---@field presentation ApplicationPresentation?
---@field status string
---@field message string
---@field session SaveEditorSession?
---@field dependencies table<string, unknown>?
---@field errorMessage string?
---@field notice string?
---@field generation number
---@field disposed boolean
---@field resultSent boolean
---@field approvedExit boolean
---@field closeReason string?
local State = {}
State.__index = State

local function message(value)
  if Errors.is(value) then
    return value.message
  end
  return tostring(value)
end

local function makeText(versionId)
  return FieldTextRenderer.new({ cacheFs = CacheFs.forVersion(versionId) })
end

function State.new(options)
  assert(type(options) == "table", "save editor state options are required")
  assert(type(options.versionId) == "string" and options.versionId ~= "")
  assert(type(options.saveId) == "string" and options.saveId ~= "")
  assert(type(options.derivedAssets) == "table" and type(options.derivedAssets.requestMilestone) == "function")
  assert(type(options.repositoryRoot) == "string" and options.repositoryRoot ~= "")
  assert(type(options.onResult) == "function")
  local width, height = options.width, options.height
  if width == nil or height == nil then
    width, height = love.graphics.getDimensions()
  end
  local text = makeText(options.versionId)
  local rendererOk, rendererOrError = pcall(Renderer.new, { text = text })
  if not rendererOk then
    pcall(function()
      text:release()
    end)
    error(rendererOrError, 0)
  end
  local presentationOk, presentationOrError = pcall(ApplicationPresentation.new, Interface.defaults())
  if not presentationOk then
    pcall(function()
      assert(rendererOrError):dispose()
    end)
    error(presentationOrError, 0)
  end
  ---@type SaveEditorState
  local self = setmetatable({
    versionId = options.versionId,
    saveId = options.saveId,
    width = width,
    height = height,
    derivedAssets = options.derivedAssets,
    repositoryRoot = options.repositoryRoot,
    onResult = options.onResult,
    displayContext = options.displayContext or DisplayContext.new({}),
    controller = Controller.new(),
    renderer = assert(rendererOrError),
    presentation = assert(presentationOrError),
    status = "opening",
    message = "Preparing save data",
    session = nil,
    dependencies = nil,
    valueEditor = nil,
    errorMessage = nil,
    notice = nil,
    generation = 1,
    disposed = false,
    resultSent = false,
    approvedExit = false,
    closeReason = nil,
  }, State)
  local resolveOk, resolveError = pcall(function()
    self:_resolve(self:_snapshot())
  end)
  if not resolveOk then
    self.presentation:dispose()
    self.renderer:dispose()
    self.presentation, self.renderer = nil, nil
    error(resolveError, 0)
  end
  return self
end

function State:_readyReadiness()
  local ready = true
  for _, name in ipairs({ "field-planning", "field-runtime" }) do
    local result = self.derivedAssets.requestMilestone(name, "required")
    if result == true then
      -- Milestone available.
    elseif type(result) == "table" and result.state == "failed" then
      error(
        Errors.new(
          "SAVE_EDITOR_ASSET_PREPARATION_FAILED",
          tostring(result.failure or (name .. " preparation failed")),
          {
            milestone = name,
          }
        ),
        0
      )
    elseif type(result) == "table" and result.state == "ready" then
      -- Explicit terminal success from a host adapter.
    else
      ready = false
    end
  end
  return ready
end

function State:update()
  if self.disposed or self.status ~= "opening" then
    return
  end
  local generation = self.generation
  local readyOk, ready = pcall(function()
    return self:_readyReadiness()
  end)
  if generation ~= self.generation or self.disposed then
    return
  end
  if not readyOk then
    self:_openingFailed(ready)
    return
  end
  if not ready then
    return
  end
  local opened, graphOrError = pcall(Composition.open, {
    versionId = self.versionId,
    saveId = self.saveId,
    repositoryRoot = self.repositoryRoot,
    derivedAssets = self.derivedAssets,
  })
  if generation ~= self.generation or self.disposed then
    return
  end
  if not opened then
    self:_openingFailed(graphOrError)
    return
  end
  self.dependencies = graphOrError
  self.session = assert(graphOrError.session)
  self.status, self.errorMessage = "ready", nil
  self:_resolve(self:_snapshot())
end

function State:_openingFailed(err)
  if not Errors.is(err) then
    error(err, 0)
  end
  self.status = "error"
  self.errorMessage = message(err)
  self.controller.focus = "retry"
  self:_resolve(self:_snapshot())
end

function State:_snapshot()
  local session = self.session and self.session:snapshot() or nil
  local flags = session and self:_flagRows(session.flags) or {}
  return {
    kind = "save_editor",
    status = self.status,
    message = self.errorMessage or self.message,
    errorMessage = self.errorMessage,
    notice = self.notice,
    versionId = self.versionId,
    saveId = self.saveId,
    session = session,
    ready = session ~= nil,
    dirty = self.session ~= nil and self.session:isDirty() or false,
    dirtySections = session and session.dirtySections or { money = false, flags = false },
    section = self.controller.section,
    sections = self.controller:snapshot().sections,
    navigationRows = {
      { role = "action", id = "section:Player", targetId = "section:Player", label = "Player" },
      { role = "action", id = "section:Progress", targetId = "section:Progress", label = "Progress" },
    },
    modal = self.controller.modal,
    focus = self.controller.focus,
    scrollOffset = self.controller.scrollOffset,
    query = self.controller.query,
    flagFilter = self.controller.flagFilter,
    flagGroup = self.controller.flagGroup,
    flagGroupLabel = self.controller.flagGroup or self.controller.flagFilter,
    flagFilterLabel = self.controller.flagGroup or self.controller.flagFilter,
    flagRows = flags,
    valueEditor = self.valueEditor and self.valueEditor:snapshot() or nil,
  }
end

function State:_flagRows(values)
  local rows = {}
  local query = self.controller.query:lower()
  for name, flagId in pairs(FieldScriptSymbols.flagsByName) do
    local named = name:sub(1, 9) ~= "FLAG_UNK_"
    local inFilter = self.controller.flagFilter == "All" or named
    if self.controller.flagGroup then
      inFilter = name:sub(6, 6) == self.controller.flagGroup
    end
    if inFilter and (query == "" or name:lower():find(query, 1, true)) then
      rows[#rows + 1] = { name = name, id = flagId, value = values[flagId] == true }
    end
  end
  table.sort(rows, function(a, b)
    return a.name < b.name
  end)
  return rows
end

function State:_resolve(view)
  return self.presentation:resolve(self.displayContext:measure(self.width, self.height), view)
end

function State:_sendResult()
  if self.resultSent then
    return
  end
  self.resultSent = true
  self.onResult({ kind = "main_menu" })
end

function State:_save(leave)
  if not self.session then
    return false
  end
  local result = self.session:save(self.valueEditor ~= nil)
  if not result.ok then
    self.errorMessage = message(result.error)
    return false
  end
  self.errorMessage = nil
  if leave then
    self.controller.modal = nil
    if self.closeReason == "quit" then
      self.approvedExit = true
      love.event.quit(0)
    else
      self:_sendResult()
    end
  end
  return true
end

function State:_discard(leave)
  if self.valueEditor then
    self.valueEditor:cancel()
    self.valueEditor = nil
  end
  if self.session then
    self.session:discard()
  end
  self.errorMessage = nil
  if leave then
    self.controller.modal = nil
    if self.closeReason == "quit" then
      self.approvedExit = true
      love.event.quit(0)
    else
      self:_sendResult()
    end
  end
end

function State:_requestBack()
  if self.valueEditor then
    self.valueEditor:cancel()
    self.valueEditor = nil
    self.controller:cancelInteraction()
  elseif self.session and self.session:isDirty() then
    self.closeReason = "back"
    self.controller:openModal("leave")
  else
    self:_sendResult()
  end
end

function State:requestClose(reason)
  assert(reason == "back" or reason == "quit", "save editor close reason is invalid")
  if self.approvedExit then
    return false
  end
  if self.disposed then
    return false
  end
  if self.valueEditor or (self.session and self.session:isDirty()) then
    self.closeReason = reason
    self.controller:openModal("leave")
    return true
  end
  if reason == "back" then
    self:_sendResult()
  end
  return false
end

function State:onImportAttempt()
  self.notice = "Close the editor before importing another ROM."
end

function State:_activate(targetId)
  if self.status == "error" then
    if targetId == "retry" then
      self.generation = self.generation + 1
      self.status, self.errorMessage = "opening", nil
    elseif targetId == "back" then
      self:_sendResult()
    end
    return
  end
  if self.valueEditor then
    local valueKind = self.valueEditor:snapshot().kind
    local digitAction = targetId:match("^digit%-(.+)$")
    if digitAction then
      self.valueEditor:press(digitAction)
    elseif valueKind == "choice" then
      if targetId == "page-next" then
        self.valueEditor:press("page_next")
      elseif targetId == "page-previous" then
        self.valueEditor:press("page_previous")
      else
        self.valueEditor:activateTarget(targetId)
      end
    elseif valueKind == "name" then
      local controlId = targetId:match("^name%-control:(.+)$")
      if controlId then
        self.valueEditor:activateTarget(controlId)
      else
        self.valueEditor:activateTarget(targetId)
      end
    elseif targetId == "confirm" then
      if self.valueEditor:press("confirm") then
        local result = self.valueEditor:result()
        if result and result.kind == "confirm" then
          local changed = self.session:setMoney(result.value)
          if changed.ok then
            self.valueEditor = nil
          else
            self.errorMessage = message(changed.error)
          end
        end
      end
    elseif targetId == "cancel" then
      self.valueEditor:cancel()
      self.valueEditor = nil
    end
    return
  end
  if self.controller.modal then
    if targetId == "cancel" then
      self.controller.modal = nil
    elseif targetId == "discard" then
      self:_discard(true)
    elseif targetId == "save" then
      self:_save(true)
    end
    return
  end
  if targetId == "section:Player" or targetId == "section:Progress" then
    self.controller.section = targetId:sub(9)
    self.controller.focus = self.controller.section == "Player" and "money" or ("flag:" .. self:_firstFlagName())
    self.controller:cancelInteraction()
    return
  end
  if targetId == "section" then
    self.controller.section = self.controller.section == "Player" and "Progress" or "Player"
    self.controller.focus = self.controller.section == "Player" and "money" or ("flag:" .. self:_firstFlagName())
    return
  end
  if targetId == "group-previous" then
    self:_cycleFlagFilter(-1)
    return
  elseif targetId == "group-next" then
    self:_cycleFlagFilter(1)
    return
  elseif targetId == "filter-named" then
    self.controller.flagFilter = self.controller.flagFilter == "Named" and "All" or "Named"
    self.controller.flagGroup = nil
    self.controller.focus = "flag:" .. self:_firstFlagName()
    self.controller.scrollOffset = 0
    return
  end
  if targetId == "money" then
    local money = assert(self.session:snapshot().money)
    self.valueEditor =
      ValueEditor.new({ kind = "integer", value = money, min = 0, max = PlayerData.MAX_MONEY, base = "decimal" })
    self._pointerOpenedValue = self._pointerDispatching == true
  elseif targetId:sub(1, 5) == "flag:" then
    local name = targetId:sub(6)
    local current = self.session:snapshot().flags[FieldScriptSymbols.flagsByName[name]] == true
    local result = self.session:setFlag(name, not current)
    if not result.ok then
      self.errorMessage = message(result.error)
    end
  elseif targetId == "save" then
    self:_save(false)
  elseif targetId == "discard" then
    self:_discard(false)
  elseif targetId == "back" then
    self:_requestBack()
  end
end

function State:_firstFlagName()
  return assert(self:_flagRows({})[1], "field flags catalog is empty").name
end

function State:_moveFlagFocus(direction)
  local rows = self:_flagRows(self.session:snapshot().flags)
  if #rows == 0 then
    return
  end
  local current = 1
  for index, row in ipairs(rows) do
    if self.controller.focus == "flag:" .. row.name then
      current = index
      break
    end
  end
  current = math.max(1, math.min(#rows, current + direction))
  self.controller.focus = "flag:" .. rows[current].name
  local plan = self:_resolve(self:_snapshot())
  local layout = assert(plan.content.layout)
  local rowHeight = layout.viewport.height <= 200 and 22 or 34
  local visibleFlags = math.max(1, math.floor(layout.content.height / rowHeight) - 2)
  if current > self.controller.scrollOffset + visibleFlags then
    self.controller.scrollOffset = current - visibleFlags
  elseif current <= self.controller.scrollOffset then
    self.controller.scrollOffset = current - 1
  end
end

function State:_cycleFlagFilter(direction)
  local ordered = { "Named", "All" }
  local groups = {}
  for name in pairs(FieldScriptSymbols.flagsByName) do
    local group = name:sub(6, 6)
    if group:match("%a") then
      groups[group] = true
    end
  end
  for group in pairs(groups) do
    ordered[#ordered + 1] = group
  end
  table.sort(ordered, function(a, b)
    if a == "Named" then
      return true
    end
    if b == "Named" then
      return false
    end
    if a == "All" then
      return true
    end
    if b == "All" then
      return false
    end
    return a < b
  end)
  local current = self.controller.flagGroup or self.controller.flagFilter
  local index = 1
  for i, group in ipairs(ordered) do
    if group == current then
      index = i
      break
    end
  end
  local nextFilter = ordered[(index - 1 + direction) % #ordered + 1]
  self.controller.flagFilter = nextFilter == "All" and "All" or "Named"
  self.controller.flagGroup = nextFilter ~= "All" and nextFilter ~= "Named" and nextFilter or nil
  self.controller.scrollOffset = 0
  self.controller.focus = "flag:" .. self:_firstFlagName()
end

function State:_dispatchIntent(intent)
  if intent == nil then
    return
  end
  if intent.kind == "back" then
    self:_requestBack()
  elseif intent.kind == "activate" then
    self:_activate(intent.targetId)
  elseif intent.kind == "action" then
    self:_activate(intent.action)
  elseif intent.kind == "cancel" then
    self.controller.modal = nil
  elseif intent.kind == "move" then
    if self.controller.section == "Progress" then
      if intent.direction == "left" then
        self.controller.section = "Player"
        self.controller.focus = "money"
      elseif intent.direction == "right" then
        self:_cycleFlagFilter(1)
      elseif intent.direction == "up" or intent.direction == "down" then
        self:_moveFlagFocus(intent.direction == "down" and 1 or -1)
      end
    elseif intent.direction == "right" or intent.direction == "down" then
      self.controller.section = "Progress"
      self.controller.focus = "flag:" .. self:_firstFlagName()
    else
      self.controller.section = "Player"
      self.controller.focus = "money"
    end
    self.controller:cancelInteraction()
  end
end

function State:_pointer(events)
  if self.disposed then
    return
  end
  local view = self:_snapshot()
  local plan = self:_resolve(view)
  local mapped = self.presentation:mapInput(events, view)
  for _, event in ipairs(mapped) do
    self._pointerDispatching = event.pointerId == "mouse:1"
    self:_dispatchIntent(self.controller:pointer(event))
    self._pointerDispatching = false
  end
  if self.disposed then
    return plan
  end
  self:_resolve(self:_snapshot())
  return plan
end

function State:view()
  local view = self:_snapshot()
  local plan = self:_resolve(view)
  view.presentation = plan
  view.layout = plan.content.layout
  return view
end

function State:draw()
  if self.disposed then
    return
  end
  local view = self:view()
  ApplicationPresentation.draw(
    self.renderer.graphics,
    { renderer = self.renderer, text = self.renderer.text },
    view,
    view.presentation
  )
end

function State:resize(width, height)
  self.width, self.height = width, height
  self.presentation:cancelPointers()
  self.controller:cancelInteraction()
end

function State:focus(focused)
  if not focused then
    self.presentation:cancelPointers()
    self.controller:cancelInteraction()
  end
end

function State:keypressed(key, _, isrepeat)
  if self.disposed or isrepeat then
    return
  end
  if self.status == "opening" and not HgssInputBindings.isCancelKey(key) then
    return
  end
  if self.valueEditor then
    if key == "home" then
      self.valueEditor:press("group_previous")
      return
    elseif key == "end" then
      self.valueEditor:press("group_next")
      return
    end
    if key == "pageup" then
      self.valueEditor:press("page_previous")
      return
    elseif key == "pagedown" then
      self.valueEditor:press("page_next")
      return
    end
    if (key == "return" or key == "kpenter") and self._pointerOpenedValue then
      self._pointerOpenedValue = false
    elseif key == "return" or key == "kpenter" then
      self:_activate("confirm")
    elseif key == "escape" then
      self.valueEditor:cancel()
      self.valueEditor = nil
    elseif key == "backspace" then
      self.valueEditor:press("backspace")
    elseif key == "left" or key == "right" or key == "up" or key == "down" then
      self.valueEditor:press(key)
    end
    return
  end
  if self.controller.section == "Progress" and key == "home" then
    self:_cycleFlagFilter(-1)
    return
  elseif self.controller.section == "Progress" and key == "end" then
    self:_cycleFlagFilter(1)
    return
  end
  if self.controller.section == "Progress" and key == "backspace" then
    local glyphs = {}
    for glyph in Utf8Glyphs.iter(self.controller.query) do
      glyphs[#glyphs + 1] = glyph
    end
    if #glyphs > 0 then
      table.remove(glyphs)
      self.controller.query = table.concat(glyphs)
      self.controller.scrollOffset = 0
    end
    return
  end
  if self.controller.section == "Progress" and (#key == 1 or key == "space") then
    return
  end
  local action = key
  if HgssInputBindings.isCancelKey(key) then
    action = "back"
  elseif HgssInputBindings.isActionKey(key) then
    action = "confirm"
  end
  if self.controller.modal and (key == "left" or key == "right" or key == "up" or key == "down") then
    self:_dispatchIntent(self.controller:press(action))
  elseif self.status == "error" then
    self:_activate(key == "escape" and "back" or "retry")
  else
    self:_dispatchIntent(self.controller:press(action))
  end
end

function State:textinput(text)
  if self.valueEditor then
    self.valueEditor:textinput(text)
  elseif self.controller.section == "Progress" then
    self.controller.query = self.controller.query .. text
  end
end

function State:keyreleased() end

function State:gamepadpressed(_, button)
  local keys = { dpup = "up", dpdown = "down", dpleft = "left", dpright = "right", a = "confirm", b = "back" }
  local action = keys[button]
  if self.valueEditor then
    if action then
      self.valueEditor:press(action)
    end
  elseif action then
    self:_dispatchIntent(self.controller:press(action))
  end
end

function State:gamepadreleased() end
function State:gamepadaxis() end

function State:mousepressed(x, y, button, istouch)
  if button == 1 and not istouch then
    self:_pointer({ { type = "pointer_down", pointerId = "mouse:1", x = x, y = y } })
  end
end
function State:mousemoved(x, y, _, _, istouch)
  if not istouch then
    self:_pointer({ { type = "pointer_move", pointerId = "mouse:1", x = x, y = y } })
  end
end
function State:mousereleased(x, y, button, istouch)
  if button == 1 and not istouch then
    self:_pointer({ { type = "pointer_up", pointerId = "mouse:1", x = x, y = y } })
  end
end
function State:touchpressed(id, x, y)
  self:_pointer({ { type = "pointer_down", pointerId = "touch:" .. tostring(id), x = x, y = y } })
end
function State:touchmoved(id, x, y)
  self:_pointer({ { type = "pointer_move", pointerId = "touch:" .. tostring(id), x = x, y = y } })
end
function State:touchreleased(id, x, y)
  self:_pointer({ { type = "pointer_up", pointerId = "touch:" .. tostring(id), x = x, y = y } })
end
function State:wheelmoved(_, y)
  self.controller.scrollOffset = math.max(0, math.floor(self.controller.scrollOffset - y))
end

function State:dispose()
  if self.disposed then
    return
  end
  self.disposed = true
  self.generation = self.generation + 1
  self.presentation:dispose()
  if self.renderer then
    self.renderer:dispose()
    self.renderer = nil
  end
  self.valueEditor = nil
  self.session = nil
  self.dependencies = nil
end

return State
