-- Adapts the source PC prop effects and queries to the retained field owners.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")

---@class PcTerminal
---@field _mailbox table<string, unknown>
---@field _photoAlbum table<string, unknown>
---@field _sourcePolicy table<string, unknown>
---@field _resolveTerminalProp fun(propRef: string): table<string, unknown>
---@field _activeProp table<string, unknown>?
---@field _activeRole string?
local PcTerminal = {}
PcTerminal.__index = PcTerminal

local function validatePolicy(policy)
  assert(type(policy) == "table" and type(policy.slots) == "table", "PC terminal source policy is required")
  assert(policy.animationTag == 90, "PC terminal manager selector is source tag 90")
  assert(
    type(policy.candidateBuildModelMembers) == "table" and #policy.candidateBuildModelMembers == 2,
    "PC terminal candidate order is compiled"
  )
  for slot = 0, 1 do
    local record = assert(policy.slots[slot], "PC terminal source slot is compiled")
    assert(record.role == (slot == 0 and "terminal.on" or "terminal.off"), "PC terminal slot role is source-defined")
    assert(record.playMode == "forward", "PC terminal animations play forward")
  end
end

---@param options { mailbox: table<string, unknown>, photoAlbum: table<string, unknown>, sourcePolicy: table<string, unknown>, resolveTerminalProp: fun(propRef: string): table<string, unknown> }
---@return PcTerminal
function PcTerminal.new(options)
  assert(type(options) == "table", "PC terminal requires its source owners")
  assert(
    type(options.mailbox) == "table" and type(options.mailbox.usedCount) == "function",
    "PC terminal borrows Mailbox"
  )
  assert(
    type(options.photoAlbum) == "table" and type(options.photoAlbum.usedCount) == "function",
    "PC terminal borrows Photo Album"
  )
  validatePolicy(options.sourcePolicy)
  assert(type(options.resolveTerminalProp) == "function", "PC terminal needs canonical prop resolution")
  return setmetatable({
    _mailbox = options.mailbox,
    _photoAlbum = options.photoAlbum,
    _sourcePolicy = options.sourcePolicy,
    _resolveTerminalProp = options.resolveTerminalProp,
    _activeProp = nil,
    _activeRole = nil,
  }, PcTerminal)
end

---@param kind "mailbox"|"photos"|"seals"
---@return integer
function PcTerminal:count(kind)
  if kind == "mailbox" then
    return self._mailbox:usedCount()
  elseif kind == "photos" then
    return self._photoAlbum:usedCount()
  elseif kind == "seals" then
    return 0
  end
  error("unsupported PC count kind: " .. tostring(kind), 0)
end

---@param action "start"|"on"|"off"
---@param propRef string
function PcTerminal:effect(action, propRef)
  assert(propRef == "pc_terminal", "PC source prop reference is closed")
  if action == "start" then
    assert(self._activeProp == nil, "PC terminal animation manager is already loaded")
    local prop = self._resolveTerminalProp(propRef)
    assert(type(prop) == "table", "source PC terminal prop is present on the active map")
    assert(type(prop.play) == "function" and type(prop.isFinished) == "function", "terminal prop playback is complete")
    assert(type(prop.stop) == "function", "terminal prop playback supports release")
    self._activeProp = prop
    return
  end
  assert(action == "on" or action == "off", "PC terminal effect action is closed")
  local prop = assert(self._activeProp, "PC terminal animation manager must be loaded before playback")
  if self._activeRole ~= nil then
    assert(self:effectFinished(), "the current PC terminal clip must finish before the next one starts")
    prop:stop(self._activeRole)
    self._activeRole = nil
  end
  local slot = action == "on" and 0 or 1
  local definition = self._sourcePolicy.slots[slot]
  prop:play(definition.role, "once")
  self._activeRole = definition.role
end

---@return boolean
function PcTerminal:effectFinished()
  local prop = assert(self._activeProp, "PC terminal wait requires a loaded animation manager")
  local role = assert(self._activeRole, "PC terminal wait requires active playback")
  return prop:isFinished(role)
end

function PcTerminal:releaseEffect()
  local prop = self._activeProp
  if prop == nil then
    return
  end
  if self._activeRole ~= nil then
    prop:stop(self._activeRole)
  end
  self._activeRole = nil
  self._activeProp = nil
end

function PcTerminal:openCapsules()
  -- Capsule editing is intentionally deferred. Complete synchronously with no child,
  -- data mutation, or wait token so the source shell can continue to its next command.
end

---@return integer source invalid or missing record status
function PcTerminal:hallOfFameStatus()
  return 1
end

function PcTerminal:openHallOfFame()
  Errors.raise(
    ScriptErrors.SCRIPT_UNSUPPORTED_REACHABLE,
    "Hall of Fame records are not available in this save schema",
    {}
  )
end

return PcTerminal
