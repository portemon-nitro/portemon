-- Coordinates the retail field recovery phases behind WhiteOut.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")
local FieldMapDataCache = require("libs.assets.src.field.FieldMapDataCache")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local FieldCoveredSwap = require("libs.hgss.src.transition.FieldCoveredSwap")

local MESSAGE_BANK = 203
local MOTHER_MESSAGE = 4
local CENTER_MESSAGE = 3
local WHITEOUT_TO_MOM = "common.whited_out_to_mom"
local WHITEOUT_TO_CENTER = "common.whited_out_to_pokecenter"
local FADE_STEPS = { 0, 2, 4, 6, 8, 10, 12, 14, 16 }

---@class FieldBlackoutStatus
---@field phase string
---@field coverColor "white"|"black"|nil
---@field coverAlpha number|nil
---@field waitingInput boolean
---@field error unknown|nil
---@field complete boolean
---@field followup string|nil
---@class FieldBlackoutFlow
---@field cacheFs CacheFs
---@field loader table<string, unknown>
---@field transition table<string, unknown>
---@field sourceMap fun(): table<string, unknown>
---@field world table<string, unknown>
---@field mons table<string, unknown>
---@field audio table<string, unknown>
---@field overworld table<string, unknown>
---@field dialogue table<string, unknown>|nil
local FieldBlackoutFlow = {}
FieldBlackoutFlow.__index = FieldBlackoutFlow

function FieldBlackoutFlow.new(opts)
  assert(type(opts) == "table", "blackout flow options are required")
  for _, name in ipairs({ "cacheFs", "loader", "transition", "world", "mons", "audio", "overworld" }) do
    assert(opts[name] ~= nil, "blackout flow requires " .. name)
  end
  return setmetatable({
    cacheFs = opts.cacheFs,
    loader = opts.loader,
    transition = opts.transition,
    sourceMap = opts.sourceMap,
    world = opts.world,
    mons = opts.mons,
    audio = opts.audio,
    overworld = opts.overworld,
    dialogue = opts.dialogue,
    active = nil,
    nextId = 0,
  }, FieldBlackoutFlow)
end

function FieldBlackoutFlow:start(spawnKey)
  assert(self.active == nil, "blackout recovery is already active")
  local phase, failure = self.overworld:phase()
  if failure ~= nil or phase == "failed" then
    error(failure or Errors.new(FieldErrors.FIELD_OVERWORLD_LIFECYCLE_INVALID, "blackout lifecycle has failed", {}), 0)
  end
  if phase == "present" then
    self.overworld:requestLeave()
    phase = "leaving"
  elseif phase ~= "absent" then
    Errors.raise(
      FieldErrors.FIELD_OVERWORLD_LIFECYCLE_INVALID,
      "blackout cannot start during an overworld transition",
      { phase = phase }
    )
  end
  local destination = FieldMapDataCache.blackoutDestination(self.cacheFs, spawnKey)
  if destination == nil then
    Errors.raise(
      FieldErrors.FIELD_MAP_UNKNOWN,
      "blackout spawn has no generated death destination",
      { spawn = spawnKey }
    )
  end
  self.nextId = self.nextId + 1
  self.active = {
    id = tostring(self.nextId),
    spawnKey = spawnKey,
    destination = destination,
    phase = "leave",
    fadeStep = 0,
    followup = spawnKey == "SPAWN_NEW_BARK" and WHITEOUT_TO_MOM or WHITEOUT_TO_CENTER,
  }
  return self.active.id
end

function FieldBlackoutFlow:updateFixed(input)
  local run = self.active
  if run == nil or run.error ~= nil or run.complete then
    return
  end
  local phase = run.phase
  if phase == "leave" then
    local lifecyclePhase, failure = self.overworld:phase()
    if failure ~= nil or lifecyclePhase == "failed" then
      run.error = failure
    elseif lifecyclePhase == "absent" then
      local swap =
        FieldCoveredSwap.new({ loader = self.loader, transition = self.transition, sourceMap = self.sourceMap() })
      swap:start(run.destination)
      run.swap = swap
      run.phase = "relocate"
    end
  elseif phase == "relocate" then
    if run.swap:done() then
      if run.swap:error() ~= nil then
        run.error = run.swap:error()
      else
        self.world:clearFlag(FieldScriptSymbols.flagsByName.FLAG_HAVE_FOLLOWER)
        self.world:setVar(FieldScriptSymbols.variablesByName.VAR_FOLLOWER_TRAINER_NUM, 0)
        self.mons:healParty()
        self.audio:fadeMusicOut({ target = 0, durationTicks = 20 })
        run.phase = "fade_music"
      end
    end
  elseif phase == "fade_music" then
    if not self.audio:isMusicFadeActive() then
      self.audio:stopMusic()
      self:_openMessage(run)
      run.phase = "message_in"
    end
  elseif phase == "message_in" then
    if run.fadeStep == #FADE_STEPS - 1 and self.dialogue:printProgress().done then
      run.phase = "message_wait"
    end
  elseif phase == "message_wait" then
    if input ~= nil and (input.pressedAction == true or input.pressedCancel == true or input.touchPressed == true) then
      self.dialogue:close(true)
      run.fadeStep = 0
      run.phase = "message_out"
    end
  elseif phase == "message_out" then
    if run.fadeStep == #FADE_STEPS - 1 and not self.dialogue:isOpen() then
      self.overworld:requestRestore()
      run.phase = "restore"
    end
  elseif phase == "restore" then
    local lifecyclePhase, failure = self.overworld:phase()
    if failure ~= nil or lifecyclePhase == "failed" then
      run.error = failure
    elseif lifecyclePhase == "present" then
      run.complete = true
      run.phase = "complete"
    end
  end
end

function FieldBlackoutFlow:updateSourceFrame()
  local run = self.active
  if run == nil then
    return
  end
  if run.phase == "message_in" or run.phase == "message_out" then
    run.fadeStep = math.min(run.fadeStep + 1, #FADE_STEPS - 1)
  end
end

function FieldBlackoutFlow:_openMessage(run)
  local messageId = run.followup == WHITEOUT_TO_MOM and MOTHER_MESSAGE or CENTER_MESSAGE
  local message = string.format("msg.hgss.%04d.%05d", MESSAGE_BANK, messageId)
  local node = { op = "say", message = message }
  self.dialogue:openMessage(node)
  self.dialogue:startPrint(message, {}, { [0] = { text = "player_name" } })
end

---@return FieldBlackoutStatus
function FieldBlackoutFlow:status()
  local run = self.active
  if run == nil then
    return { phase = "idle" }
  end
  local coverColor, coverAlpha
  if run.phase == "message_in" then
    coverColor = "white"
    coverAlpha = 1 - FADE_STEPS[run.fadeStep + 1] / 16
  elseif run.phase == "message_out" or run.phase == "restore" then
    coverColor = "black"
    coverAlpha = FADE_STEPS[run.fadeStep + 1] / 16
  end
  return {
    phase = run.phase,
    fadeStep = run.fadeStep,
    waitingInput = run.phase == "message_wait",
    coverColor = coverColor,
    coverAlpha = coverAlpha,
    error = run.error,
    complete = run.complete == true,
    followup = run.complete and run.followup or nil,
  }
end

function FieldBlackoutFlow:consumeResult(runId)
  local run = self.active
  if run == nil or run.id ~= runId or not run.complete then
    return nil
  end
  local followup = run.followup
  self.active = nil
  return followup
end

function FieldBlackoutFlow:cancel(runId)
  if self.active ~= nil and self.active.id == runId then
    if self.dialogue:isOpen() then
      self.dialogue:close(false)
    end
    self.active = nil
  end
end

function FieldBlackoutFlow:dispose()
  local run = self.active
  if run ~= nil and self.dialogue ~= nil and self.dialogue:isOpen() then
    self.dialogue:close(false)
  end
  self.active = nil
end

return FieldBlackoutFlow
