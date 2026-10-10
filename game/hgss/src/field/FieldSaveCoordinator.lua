-- Owns field save capture and publication coordination for one runtime.

local FieldApplicationHost = require("libs.hgss.src.field.FieldApplicationHost")
local FieldAudioSave = require("libs.hgss.src.audio.FieldAudioSave")
local FieldTransition = require("libs.hgss.src.transition.FieldTransition")
local EncounterSave = require("libs.hgss.src.save.EncounterSave")
local GameSave = require("libs.hgss.src.save.GameSave")
local ScriptSave = require("libs.script.src.ScriptSave")

---@class FieldSaveCoordinator
---@field runtime FieldRuntime
local FieldSaveCoordinator = {}
FieldSaveCoordinator.__index = FieldSaveCoordinator

---@param runtime FieldRuntime
---@return FieldSaveCoordinator
function FieldSaveCoordinator.new(runtime)
  return setmetatable({ runtime = runtime }, FieldSaveCoordinator)
end

---@param session FieldSession
---@param allowMenu boolean
---@return boolean
local function canCapture(session, allowMenu)
  return session
    and session.player
    and session.player.motion == "idle"
    and (not session.transition or session.transition.phase == FieldTransition.PHASES.idle)
    and not session.mapEntryController:isActive()
    and (not session.dialogue or not session.dialogue:isModal())
    and (not session.signpost or not session.signpost:isModal())
    and (
      not session.applicationHost
      or not session.applicationHost:isActive()
      or (allowMenu and session.applicationHost:status().phase == FieldApplicationHost.PHASES.menu)
    )
end

-- The composed mart host plugs its modal lifecycle into this owner. No host
-- is manufactured here; until one is composed, ordinary capture rules
-- decide whether the field is stable.
local function hostIsActive(runtime)
  local host = runtime.martHost
  return host ~= nil and host:isActive()
end

-- The battle-lifetime save gate: an owned battle denies capture from
-- launch acquisition through every completion subflow, and a prepared but
-- unconsumed encounter denies it the same way. Only the stable field
-- return re-enables capture; a cancelled battle without publication keeps
-- the gate closed.
---@class BattleSaveGate
---@field canSave fun(self: BattleSaveGate): boolean, table<string, unknown>?

---@param runtime table<string, unknown>
---@return string? busy reason, or nil when no battle owns the field
local function battleBusyReason(runtime)
  local battle = runtime.battleRuntime --[[@as BattleSaveGate?]]
  if battle ~= nil then
    local saveable, reason = battle:canSave()
    if not saveable then
      local phase = (type(reason) == "table" and reason.phase) or "battle"
      return "Save deferred: battle " .. tostring(phase) .. " owns the field"
    end
  end
  if runtime.pendingEncounterId ~= nil then
    return "Save deferred: a prepared encounter owns the field"
  end
  -- An admitted battle launch owns the field from cover through battle,
  -- settlement, restoration, and reveal: no shutdown or manual save may
  -- publish a half-battle field record before the safe field returns.
  if runtime._battleLaunch ~= nil then
    return "Save deferred: a battle launch owns the field"
  end
  return nil
end

---@param self FieldSaveCoordinator
---@param allowMenu boolean
---@return table<string, unknown>?, string|table<string, unknown>?
function FieldSaveCoordinator:capture(allowMenu)
  local runtime = self.runtime
  local pcHost = runtime.pcApplicationHost
  if pcHost ~= nil and pcHost:isActive() then
    return nil, "Save deferred: a PC application is active"
  end
  local battleReason = battleBusyReason(runtime)
  if battleReason ~= nil then
    return nil, battleReason
  end
  -- A pending or active field operation denies capture before any
  -- publication starts: the world is mid-mutation and the record would
  -- describe neither the before nor the after state. Runtimes without
  -- the menu composition predate this gate and keep their old boundary.
  local menu = runtime.pokemonMenu
  if
    type(menu) == "table"
    and type(menu.fieldMoves) == "table"
    and type(menu.fieldMoves.isBusy) == "function"
    and menu.fieldMoves:isBusy()
  then
    return nil, "Save deferred: a field operation is pending or active"
  end
  if not canCapture(runtime.session, allowMenu == true) then
    return nil, "Save deferred: movement, transition, map entry, or modal state is active"
  end
  if hostIsActive(runtime) then
    return nil, "Save deferred: a mart transaction is active"
  end
  if runtime.playerAvatar and not runtime.playerAvatar:isStableForSave() then
    return nil, "Save deferred: avatar transition state is not stable"
  end

  local session = runtime.session
  local player = session.player
  local runtimeMap = session.currentMap
  assert(type(runtimeMap.terrainDependencyHash) == "string", "runtime map terrain dependency identity required")

  local world = runtime.scripts.worldState:capture(runtime.actors:captureObjects())
  local weatherState = runtimeMap --[[@as table]]
  local snapshot = {
    schema = GameSave.SCHEMA,
    saveId = runtime.saveId,
    versionId = runtime.versionId,
    mapId = runtimeMap.mapId,
    fieldX = player.fieldX,
    fieldZ = player.fieldZ,
    worldY = player.worldY,
    surfaceId = player.surfaceId,
    terrainDependencyHash = runtimeMap.terrainDependencyHash,
    facing = player.facing,
    weatherId = assert(weatherState.effectiveWeatherId, "active runtime weather is required"),
    playTimeSeconds = runtime.playTime:seconds(),
    playerData = runtime.playerData,
    fieldTravel = assert(runtime.fieldTravel, "field runtime has no travel state"):capture(),
    fashionCase = assert(runtime.fashionCase, "field runtime has no Fashion Case state"):capture(),
    world = world,
    scripts = ScriptSave.capture(runtime.scripts.scheduler, session.tick),
    auxiliaryUi = runtime.auxiliaryFieldUi:capture(),
    audio = FieldAudioSave.capture(runtime.audio),
    mons = runtime.monService:capture(),
    bag = runtime.bagService:capture(),
    mart = assert(runtime.martService, "field runtime has no mart service"):capture(),
    mailbox = assert(runtime.mailbox, "field runtime has no mailbox"):capture(),
    photoAlbum = assert(runtime.photoAlbum, "field runtime has no photo album"):capture(),
    encounters = EncounterSave.capture(assert(runtime.roamerState, "field runtime has no roamer state")),
    pokedex = assert(runtime.dexKnowledge, "field runtime has no dex knowledge"):bucket(),
  }
  if runtime.playerAvatar then
    snapshot.avatar = runtime.playerAvatar:capture()
  end

  return snapshot
end

---@param self FieldSaveCoordinator
---@return table<string, unknown>?, string|table<string, unknown>?
function FieldSaveCoordinator:captureManual()
  local runtime = self.runtime
  if not canCapture(runtime.session, true) then
    return nil, "Save deferred: the field is not stable"
  end
  return self:capture(true)
end

function FieldSaveCoordinator:save()
  local runtime = self.runtime
  assert(runtime.saveStore, "manual Save requires a save store")
  -- Keep this call on the runtime facade so test/runtime subclasses may
  -- replace the menu-specific capture policy without owning persistence.
  local record, reason = runtime:_captureManualSaveFromMenu()
  assert(record, reason)
  if runtime.savePublished then
    runtime.saveStore:save(record)
  else
    runtime.saveStore:publishFirst(record)
    runtime.savePublished = true
  end
end

return FieldSaveCoordinator
