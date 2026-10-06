-- Owns field save capture and publication coordination for one runtime.

local FieldApplicationHost = require("libs.hgss.src.field.FieldApplicationHost")
local FieldAudioSave = require("libs.hgss.src.audio.FieldAudioSave")
local FieldTransition = require("libs.hgss.src.transition.FieldTransition")
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

---@param self FieldSaveCoordinator
---@param allowMenu boolean
---@return table<string, unknown>?, string|table<string, unknown>?
function FieldSaveCoordinator:capture(allowMenu)
  local runtime = self.runtime
  local pcHost = runtime.pcApplicationHost
  if pcHost ~= nil and pcHost:isActive() then
    return nil, "Save deferred: a PC application is active"
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
    scripts = ScriptSave.capture(runtime.scripts.scheduler, session.tick, {
      registryFingerprint = runtime.scripts:registryFingerprint(),
    }),
    auxiliaryUi = runtime.auxiliaryFieldUi:capture(),
    audio = FieldAudioSave.capture(runtime.audio),
    mons = runtime.monService:capture(),
    bag = runtime.bagService:capture(),
    mart = assert(runtime.martService, "field runtime has no mart service"):capture(),
    mailbox = assert(runtime.mailbox, "field runtime has no mailbox"):capture(),
    photoAlbum = assert(runtime.photoAlbum, "field runtime has no photo album"):capture(),
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
