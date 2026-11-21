-- The gym mechanism owner for one live field: the closed dispatcher over the
-- port's implemented native mechanisms (the Violet lift and the Azalea
-- Spinarak transports, the Ecruteak candles, the Cianwood winch and the
-- Blackthorn platforms), the persisted union they settle, and the runtime
-- geometry that union implies.
--
-- The source keeps exactly one active mechanism in the saved union
-- (include/gymmick.h), places its props and plates when the map loads
-- (GymmickInit_*), and clears the union on every non-connection map entry
-- (src/field/warp_tasks.c::FieldSystem_InitMapOnEnter). This owner mirrors
-- that lifecycle: a map load installs the settled runtime geometry from the
-- union, a swap to a destination map clears the union before the destination
-- map's own init script installs its kind, and the seamless connection path
-- never reaches either, which is why a connection retains the union.
--
-- Handles are per activation and never saved: one ride owns the player
-- transport and the source sounds, and cancelling or completing it releases
-- them exactly once. A script's own `gym_init` command never touches runtime
-- geometry, exactly like the source init commands, so a car the player stands
-- on cannot be dropped by a re-entry.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")
local GymMechanismState = require("libs.hgss.src.field.GymMechanismState")
local VioletGym = require("libs.hgss.src.field.gymmick.VioletGym")
local AzaleaGym = require("libs.hgss.src.field.gymmick.AzaleaGym")
local CianwoodGym = require("libs.hgss.src.field.gymmick.CianwoodGym")
local EcruteakGym = require("libs.hgss.src.field.gymmick.EcruteakGym")
local BlackthornGym = require("libs.hgss.src.field.gymmick.BlackthornGym")

-- The source script environment's trainer attributes the candle commands read
-- (SCRIPTENV_ENGAGED_TRAINER_0_EVENT): the live trainer engagement owner
-- answers which actor occupies engagement slot 0. Without one no candle can be
-- bound or extinguished, which is the source's own assertion path.
---@class GymMechanismTrainerEngagement
---@field engagedActor fun(): string|nil

-- The collaborators a live field supplies once: the saved union, the runtime
-- plateau it projects, and the live services the rides read.
---@class GymMechanismOptions
---@field state GymMechanismState the saved union this mechanism owns
---@field geometry GymMechanismGeometry the runtime plateau the union implies
---@field playerOf fun(): table<string, unknown> reads the live field player
---@field actors table<string, unknown>
---@field followingMon table<string, unknown>
---@field audio table<string, unknown>? the source audio host the rides play through
---@field camera table<string, unknown>?
---@field foregroundScript (fun(): string|nil)? reads the script frame that owns the field
---@field trainerEngagement GymMechanismTrainerEngagement? the live engaged-trainer identity owner

-- The presented source-prop factory the rendering composition installs once:
-- every call claims one live prop instance the mechanism animates and releases.
---@class GymMechanismModelFactory
---@field car fun(): table<string, unknown>
---@field spider fun(slot: integer): table<string, unknown>
---@field candle (fun(index: integer): table<string, unknown>)? nil when the composition publishes no candle prop
---@field platform (fun(slot: integer, kind: string): table<string, unknown>)? nil when the composition publishes no platform prop

-- The immutable presentation snapshot the field draws: where the owned source
-- props stand this tick. The mechanism owns every transform, so a renderer
-- only applies them.
---@class GymMechanism.PropPlacement
---@field x number
---@field y number
---@field z number
---@field rotationDegrees number
---@class GymMechanism.SpiderPlacement: GymMechanism.PropPlacement
---@field slot integer
---@class GymMechanism.CandlePlacement: GymMechanism.PropPlacement
---@field index integer
---@field scale number
---@field culled boolean
---@class GymMechanism.PlatformPlacement: GymMechanism.PropPlacement
---@field slot integer one-based source platform index
---@class GymMechanism.Presentation
---@field car GymMechanism.PropPlacement?
---@field spiders GymMechanism.SpiderPlacement[]?
---@field candles GymMechanism.CandlePlacement[]?
---@field platforms GymMechanism.PlatformPlacement[]?
---@field fog table<string, unknown>? the gym's own map fog the field applies

---@class GymMechanism
---@field private _state GymMechanismState
---@field private _geometry table<string, unknown>
---@field private _playerOf fun(): table<string, unknown>
---@field private _actors table<string, unknown>
---@field private _followingMon table<string, unknown>
---@field private _audio table<string, unknown>
---@field private _camera table<string, unknown>?
---@field private _foregroundScript (fun(): string|nil)?
---@field private _ownerScript string? the script frame that started the owned activation
---@field private _active table<string, unknown>|nil
---@field private _switch { sound: string }|nil the switch flip waiting for its own source sound
---@field private _runtimeMap table<string, unknown>|nil
---@field private _modelFactory GymMechanismModelFactory|nil
---@field private _carModel table<string, unknown>|nil
---@field private _spiderModels table<integer, table<string, unknown>>
---@field private _candleModels table<integer, table<string, unknown>>
---@field private _platformModels table<integer, table<string, unknown>>
---@field private _ecruteak EcruteakGym|nil the live candle mechanism of this map
---@field private _winch CianwoodGym|nil the live winch cutscene
---@field private _blackthorn BlackthornGym|nil the live platform mechanism of this map
---@field private _result integer|nil the source boolean the blocking command answers
---@field private _trainerEngagement GymMechanismTrainerEngagement|nil
local GymMechanism = {}
GymMechanism.__index = GymMechanism

-- The pinned Azalea switch sound (src/field/gymmick/azalea.c).
GymMechanism.SWITCH_SEQUENCE = AzaleaGym.SWITCH_SEQUENCE

---@param options GymMechanismOptions
---@return GymMechanism
function GymMechanism.new(options)
  assert(type(options) == "table", "the gym mechanism needs its collaborators")
  assert(options.state and options.state.capture, "the gym mechanism owns the saved union")
  assert(options.geometry and options.geometry.bindMap, "the gym mechanism needs its runtime geometry")
  assert(type(options.playerOf) == "function", "the gym mechanism reads the live field player through an accessor")
  assert(options.actors and options.actors.partnerId, "the gym mechanism needs the actor owner")
  assert(
    options.followingMon and options.followingMon.repositionRelativeToPlayer,
    "the gym mechanism needs the follower owner"
  )
  local audio = assert(options.audio, "the gym mechanism needs the source audio host")
  assert(audio.play and audio.stop, "the gym mechanism needs the source audio host")
  if options.foregroundScript ~= nil then
    assert(
      type(options.foregroundScript) == "function",
      "the gym mechanism foreground-script lookup must be a function"
    )
  end
  if options.trainerEngagement ~= nil then
    assert(
      type(options.trainerEngagement.engagedActor) == "function",
      "the trainer engagement context answers the engaged trainer actor"
    )
  end
  return setmetatable({
    _foregroundScript = options.foregroundScript,
    _state = options.state,
    _geometry = options.geometry,
    _playerOf = options.playerOf,
    _actors = options.actors,
    _followingMon = options.followingMon,
    _audio = audio,
    _camera = options.camera,
    _active = nil,
    _switch = nil,
    _runtimeMap = nil,
    _modelFactory = nil,
    _carModel = nil,
    _spiderModels = {},
    _candleModels = {},
    _platformModels = {},
    _ecruteak = nil,
    _winch = nil,
    _blackthorn = nil,
    _result = nil,
    _trainerEngagement = options.trainerEngagement,
  }, GymMechanism)
end

-- Map load: publish the settled runtime geometry the saved union describes,
-- project it over the loaded map's generated terrain and permission grid, and
-- restore what the settled kind owns on this map - the source Gymmick_Init call
-- site.
---@param runtimeMap table<string, unknown>
function GymMechanism:bindMap(runtimeMap)
  assert(type(runtimeMap) == "table", "the gym mechanism binds to one runtime map")
  local kind = self._state:kind()
  self._geometry:restoreViolet(kind == GymMechanismState.VIOLET and self._state:violetRaised() or false)
  self._geometry:setBlackthornPlatforms(
    kind == GymMechanismState.BLACKTHORN and self._state:blackthornPlatforms() or nil
  )
  self._geometry:bindMap(runtimeMap)
  self._runtimeMap = runtimeMap
  self:_syncModels()
  self:_restoreMapState()
end

-- GymmickInit_*: the settled union decides what the loaded map starts with.
-- Ecruteak installs the gym's own fog; Cianwood puts the winch records on
-- their last frame. Violet and Azalea own only their runtime geometry and
-- their props, which bindMap already published.
---@private
function GymMechanism:_restoreMapState()
  local runtimeMap = self._runtimeMap
  if runtimeMap == nil then
    return
  end
  local kind = self._state:kind()
  if kind == GymMechanismState.ECRUTEAK then
    local environment = runtimeMap.renderEnvironment
    if environment ~= nil then
      environment.fog = EcruteakGym.FOG
    end
    return
  end
  if kind == GymMechanismState.CIANWOOD and self._state:cianwoodWinchRaised() then
    CianwoodGym.restoreSettled(runtimeMap)
  end
end

-- The source gym init command: install one closed kind and its source
-- defaults. Runtime geometry is untouched, exactly like Save_Gymmick_Init: a
-- mechanism whose own tables were loaded at map load (the Blackthorn platforms)
-- keeps running for the rest of the visit, so the gym's own on-load init command
-- never drops a platform the player is standing on. A different kind replaces
-- the previous mechanism outright.
---@param kind string
function GymMechanism:initialize(kind)
  if self._active ~= nil or self._switch ~= nil then
    Errors.raise(FieldErrors.FIELD_GYM_MECHANISM_BUSY, "a gym transport owns the field during gym init", {
      kind = kind,
    })
  end
  -- A mechanism whose own tables were loaded at map load keeps them for the
  -- rest of the visit; every other kind is rebuilt from the installed union.
  local keepsMapTables = kind == GymMechanismState.BLACKTHORN and self._state:kind() == kind
  if not keepsMapTables then
    self:_releaseLeaves()
  end
  self._state:initialize(kind)
  self:_syncModels()
end

-- The non-connection world swap: the source clears the union before the
-- destination map's own init script installs its kind, and the destination
-- map starts with no plate of its own.
---@param runtimeMap table<string, unknown>
function GymMechanism:enterMap(runtimeMap)
  self._ownerScript = nil
  self:cancelRide("the field left the map")
  self:_releaseLeaves()
  self._state:initialize(GymMechanismState.NONE)
  self:bindMap(runtimeMap)
end

function GymMechanism:unbind()
  self._ownerScript = nil
  self:cancelRide("the field retired")
  self:_releaseLeaves()
  self:_releaseModels()
  self._runtimeMap = nil
  self._geometry:unbind()
end

---@return boolean
function GymMechanism:isRiding()
  local blackthorn = self._blackthorn
  if self._active ~= nil or self._switch ~= nil or self._winch ~= nil then
    return true
  end
  if blackthorn ~= nil and blackthorn:isRunning() then
    return true
  end
  local ecruteak = self._ecruteak
  return ecruteak ~= nil and not ecruteak:isExtinguishComplete()
end

-- The presented composition installs the source-model bridge once. A headless
-- composition never installs one: the mechanism then owns no visual at all and
-- every presentation call stays inert.
---@param factory GymMechanismModelFactory|nil
function GymMechanism:setModelFactory(factory)
  if factory ~= nil then
    assert(
      type(factory.car) == "function" and type(factory.spider) == "function",
      "the gym mechanism model factory creates both source props"
    )
    assert(
      factory.candle == nil or type(factory.candle) == "function",
      "a gym mechanism candle factory creates the source candle prop"
    )
    assert(
      factory.platform == nil or type(factory.platform) == "function",
      "a gym mechanism platform factory creates the source platform props"
    )
  end
  self:_releaseModels()
  self._modelFactory = factory
  self:_syncModels()
end

---@private
function GymMechanism:_releaseCarModel()
  if self._carModel ~= nil then
    self._carModel:dispose()
    self._carModel = nil
  end
end

---@private
function GymMechanism:_releaseSpiderModels()
  for slot, model in pairs(self._spiderModels) do
    model:dispose()
    self._spiderModels[slot] = nil
  end
end

-- Release every presented source prop exactly once. A factory change and a map
-- teardown both land here, so no instance outlives the map whose union loaded
-- it.
---@private
function GymMechanism:_releaseModels()
  self:_releaseCarModel()
  self:_releaseSpiderModels()
  self:_releaseCandleModels()
  self:_releasePlatformModels()
end

---@private
function GymMechanism:_releasePlatformModels()
  for slot, model in pairs(self._platformModels) do
    model:dispose()
    self._platformModels[slot] = nil
  end
end

---@private
function GymMechanism:_releaseCandleModels()
  for index, model in pairs(self._candleModels) do
    model:dispose()
    self._candleModels[index] = nil
  end
end

-- Release the live mechanism leaves of this map exactly once. A gym init, a map
-- swap and a field teardown all land here, so no candle tracker, winch cutscene
-- or platform action outlives the map whose union installed it.
---@private
function GymMechanism:_releaseLeaves()
  local ecruteak = self._ecruteak
  self._ecruteak = nil
  if ecruteak ~= nil then
    ecruteak:dispose()
  end
  local winch = self._winch
  self._winch = nil
  if winch ~= nil then
    winch:dispose()
  end
  local blackthorn = self._blackthorn
  self._blackthorn = nil
  if blackthorn ~= nil then
    blackthorn:dispose()
  end
end

-- Keep the presented props matched to the settled union the map loaded with.
-- The source map init loads exactly the active mechanism's models
-- (GymmickInit_Violet loads the car, GymmickInit_Azalea the four Spinarak,
-- GymmickInit_Ecruteak the four candle props, GymmickInit_Blackthorn the three
-- platforms) and loads nothing for a cleared union or for the winch, whose props
-- the map scene places itself. The platform mechanism itself is not only its
-- props: it owns the runtime platform floors and the step-triggered action, so
-- it exists for the whole map visit even when no composition presents a model.
---@private
function GymMechanism:_syncModels()
  local factory = self._modelFactory
  local kind = self._state:kind()
  if kind == GymMechanismState.BLACKTHORN and self._runtimeMap ~= nil and self._blackthorn == nil then
    self:_blackthornGym()
  end
  if factory == nil or self._runtimeMap == nil or kind == GymMechanismState.NONE then
    self:_releaseModels()
    return
  end
  if kind == GymMechanismState.VIOLET then
    self:_releaseSpiderModels()
    self:_releaseCandleModels()
    self:_releasePlatformModels()
    if self._carModel == nil then
      self._carModel = factory.car()
    end
    return
  end
  if kind == GymMechanismState.AZALEA then
    self:_releaseCarModel()
    self:_releaseCandleModels()
    self:_releasePlatformModels()
    for slot = 1, GymMechanismState.SPIDER_SLOTS do
      if self._spiderModels[slot] == nil then
        self._spiderModels[slot] = factory.spider(slot)
      end
    end
    return
  end
  if kind == GymMechanismState.ECRUTEAK then
    self:_releaseCarModel()
    self:_releaseSpiderModels()
    self:_releasePlatformModels()
    -- The gym's live candle mechanism exists for the whole Ecruteak visit: the
    -- source allocates its local data at map load, not at the first command.
    self:_ecruteakGym()
    local newCandle = factory.candle
    if newCandle ~= nil then
      for index = 1, GymMechanismState.CANDLE_COUNT do
        if self._candleModels[index] == nil then
          self._candleModels[index] = newCandle(index)
        end
      end
    end
    return
  end
  if kind == GymMechanismState.BLACKTHORN then
    self:_releaseCarModel()
    self:_releaseSpiderModels()
    self:_releaseCandleModels()
    -- The platform mechanism exists for the whole Blackthorn visit and owns the
    -- three platform tables the source allocates at map load.
    self:_blackthornGym()
    local newPlatform = factory.platform
    if newPlatform ~= nil then
      for slot = 1, GymMechanismState.BLACKTHORN_PLATFORMS do
        if self._platformModels[slot] == nil then
          self._platformModels[slot] = newPlatform(slot, assert(BlackthornGym.PLATFORM_MODELS[slot]))
        end
      end
    end
    return
  end
  assert(kind == GymMechanismState.CIANWOOD, "the gym mechanism union is closed")
  self:_releaseModels()
end

-- Advance the presented source models one fixed tick of the field. Only the
-- instances' own clip clocks move here: the mechanism neither reads nor
-- advances gameplay state on this path.
function GymMechanism:updatePresentation()
  if self._carModel ~= nil then
    self._carModel:updateFixed()
  end
  for _, model in pairs(self._spiderModels) do
    model:updateFixed()
  end
  for _, model in pairs(self._candleModels) do
    model:updateFixed()
  end
  for _, model in pairs(self._platformModels) do
    model:updateFixed()
  end
end

-- Advance the one gameplay mechanism this field drives without a script: the
-- Blackthorn platform action a completed step started. Every other mechanism is
-- driven by its blocking script task.
function GymMechanism:updateFixed()
  local blackthorn = self._blackthorn
  if blackthorn == nil then
    return
  end
  blackthorn:updateFixed()
end

-- The car's own world placement: the source prop stands on the pad centre
-- tile ((FX32_CONST(0xF8), FX32_CONST(0x148)) = tile (15,20)) with the null
-- rotation override MapPropManager_LoadOne was given, at whichever height the
-- lift holds. While the lift runs, the car and its riders share the carried
-- height, so the riding player's own height is the car's.
---@return GymMechanism.PropPlacement
local function carPlacement(self)
  local point = assert(self._geometry:violetCarWorldPoint(), "the car's own map is required")
  local worldY
  if self._active ~= nil then
    local player = self._playerOf()
    assert(player ~= nil, "the gym mechanism needs the live field player")
    worldY = player.worldY
  else
    worldY = self._geometry:violetCarWorldY()
  end
  return { x = point.x, y = worldY, z = point.z, rotationDegrees = 0 }
end

-- The four Spinarak placements: each spider stands on its settled route node
-- until its own ride carries it, and the ride publishes the prop's route
-- position for every motion tick.
---@return GymMechanism.SpiderPlacement[]
local function spiderPlacements(self)
  local runtimeMap = assert(self._runtimeMap, "the spiders' map is required")
  local ride = self._active
  local liveSlot, livePoint = nil, nil
  if ride ~= nil then
    liveSlot = ride:spiderSlot()
    livePoint = ride:spiderWorldPosition()
  end
  local placements = {}
  for slot, endpoint in ipairs(self._state:spiderEndpoints()) do
    local placement
    if slot == liveSlot and livePoint ~= nil then
      placement = { x = livePoint.x, y = livePoint.y, z = livePoint.z, slot = slot, rotationDegrees = 0 }
    else
      local node = AzaleaGym.nodePosition(endpoint)
      local settled = AzaleaGym.nodeWorldPosition(runtimeMap, endpoint, self._geometry:floorWorldY(node.x, node.z))
      placement = { x = settled.x, y = settled.y, z = settled.z, slot = slot, rotationDegrees = 0 }
    end
    placements[#placements + 1] = placement
  end
  return placements
end

-- The four candle placements: each candle stands on its own medium trainer's
-- current world point, which is how the source's follow task tracks a bound
-- trainer. A composition with no candle props loaded presents none.
---@return GymMechanism.CandlePlacement[]
local function candlePlacements(self)
  local ecruteak = self._ecruteak
  if ecruteak == nil then
    return {}
  end
  local placements = {}
  for _, candle in ipairs(ecruteak:candlePlacements()) do
    if self._candleModels[candle.index] ~= nil then
      placements[#placements + 1] = {
        index = candle.index,
        x = candle.x,
        y = candle.y,
        z = candle.z,
        scale = candle.scale,
        culled = candle.culled,
        rotationDegrees = 0,
      }
    end
  end
  return placements
end

-- The immutable presentation snapshot the field draws: where the owned source
-- props stand this tick. The mechanism owns every transform, so a renderer
-- only applies them.
---@return GymMechanism.Presentation
function GymMechanism:presentation()
  if self._runtimeMap == nil then
    return { car = nil, spiders = nil, candles = nil }
  end
  local kind = self._state:kind()
  if kind == GymMechanismState.VIOLET then
    return { car = carPlacement(self), spiders = nil, candles = nil }
  end
  if kind == GymMechanismState.AZALEA then
    return { car = nil, spiders = spiderPlacements(self), candles = nil }
  end
  if kind == GymMechanismState.ECRUTEAK then
    return { car = nil, spiders = nil, candles = candlePlacements(self), fog = EcruteakGym.FOG }
  end
  if kind == GymMechanismState.BLACKTHORN then
    local blackthorn = self:_blackthornGym()
    return { car = nil, spiders = nil, candles = nil, platforms = blackthorn:presentation() }
  end
  return { car = nil, spiders = nil, candles = nil }
end

-- A gym mechanism activation belongs to the script frame that started it: a
-- capture taken while that frame still owns the field would describe a field
-- whose mechanism has not finished returning control, so the activation stays
-- unstable for save until its own script released the field.
---@return boolean
function GymMechanism:isStableForSave()
  if self:isRiding() then
    return false
  end
  local owner = self._ownerScript
  if owner == nil then
    return true
  end
  local current = self._foregroundScript ~= nil and self._foregroundScript() or nil
  if current ~= owner then
    self._ownerScript = nil
    return true
  end
  return false
end

---@return table<string, unknown>
function GymMechanism:capture()
  return self._state:capture()
end

---@param kind string
local function requireKind(self, kind)
  if self._state:kind() ~= kind then
    Errors.raise(FieldErrors.FIELD_GYM_MECHANISM_INVALID, "the field's gym mechanism is not " .. kind, {
      kind = self._state:kind(),
    })
  end
end

-- The live candle mechanism of this map. The source allocates the gym's local
-- data at map load (GymmickInit_Ecruteak) and every candle command reads it; a
-- command reaching a map with no Ecruteak mechanism has already failed its kind
-- test, so this leaf is only created for the map whose union is Ecruteak.
---@private
---@return EcruteakGym
function GymMechanism:_ecruteakGym()
  local ecruteak = self._ecruteak
  if ecruteak == nil then
    local runtimeMap = assert(self._runtimeMap, "the candle mechanism needs the live map")
    ecruteak = EcruteakGym.new({
      state = self._state,
      actors = self._actors,
      audio = self._audio,
      mapId = assert(runtimeMap.mapId, "the candle mechanism binds the live map's medium objects"),
    })
    self._ecruteak = ecruteak
  end
  return ecruteak
end

-- The live platform mechanism of this map. The source allocates the gym's
-- local platform data at map load (GymmickInit_Blackthorn) and every platform
-- action reads it; the platform tables follow the union the map loaded with, so
-- a later gym init command settles only the saved union, exactly like
-- Save_Gymmick_Init.
---@private
---@return BlackthornGym
function GymMechanism:_blackthornGym()
  local blackthorn = self._blackthorn
  if blackthorn == nil then
    local player = self._playerOf()
    assert(player ~= nil, "the blackthorn mechanism needs the live field player")
    blackthorn = BlackthornGym.new({
      state = self._state,
      geometry = self._geometry,
      player = player,
      audio = self._audio,
    })
    self._blackthorn = blackthorn
  end
  return blackthorn
end

-- SCRIPTENV_ENGAGED_TRAINER_0_EVENT: the actor of engagement slot 0. A
-- command that needs it without one is the source's own assertion failure.
---@private
---@return string actorId
function GymMechanism:_engagedActorId()
  local engagement = self._trainerEngagement
  local actorId = engagement ~= nil and engagement.engagedActor() or nil
  if type(actorId) ~= "string" or actorId == "" then
    Errors.raise(
      FieldErrors.FIELD_GYM_MECHANISM_INVALID,
      "the source candle command needs an engaged trainer",
      { slot = 0 }
    )
  end
  -- Errors.raise carries no noreturn annotation, so the guard above leaves the
  -- value unnarrowed; reaching here proves the source slot holds an actor.
  return assert(actorId, "engagement slot 0 holds the actor the candle command reads")
end

-- ScrCmd_EcruteakGymBindCandleToTrainer: a wrong gym answers the source FALSE
-- and does nothing; otherwise the engaged trainer's candle follows it.
function GymMechanism:bindCandle()
  if self._state:kind() ~= GymMechanismState.ECRUTEAK then
    return
  end
  self:_ecruteakGym():bindCandle(self:_engagedActorId())
end

-- ScrCmd_EcruteakGymUnbindCandleFromTrainer: a wrong gym does nothing, and so
-- does an unbind with no live candle mechanism.
function GymMechanism:unbindCandle()
  if self._state:kind() ~= GymMechanismState.ECRUTEAK then
    return
  end
  local ecruteak = self._ecruteak
  if ecruteak ~= nil then
    ecruteak:unbindCandle()
  end
end

-- Start the one ride this task will drive. The switch flip is not a ride: it
-- commits its bit in the same tick and only waits for its own source sound.
---@param action string
---@param operands
---| { selector: integer?, switchNumber: integer? }
---| { useLastInteracted: boolean?, lastInteractedActor: string? }|nil
function GymMechanism:begin(action, operands)
  if self:isRiding() then
    Errors.raise(FieldErrors.FIELD_GYM_MECHANISM_BUSY, "another gym transport owns the field", { action = action })
  end
  operands = operands or {}
  self._ownerScript = self._foregroundScript ~= nil and self._foregroundScript() or nil
  if action == "elevator" then
    requireKind(self, GymMechanismState.VIOLET)
    local player = self._playerOf()
    assert(player ~= nil, "the gym mechanism needs the live field player")
    local ride = VioletGym.new({
      player = player,
      actors = self._actors,
      followingMon = self._followingMon,
      geometry = self._geometry,
      audio = self._audio,
      state = self._state,
    })
    ride:start()
    self._active = ride
    return
  end
  if action == "spinarak" then
    requireKind(self, GymMechanismState.AZALEA)
    local player = self._playerOf()
    assert(player ~= nil, "the gym mechanism needs the live field player")
    local selector = assert(operands.selector, "a spider ride needs its source selector")
    -- The ride drives the one spider standing on the selected endpoint, so it
    -- carries that spider's presented model as well as its own source rules.
    local spiderSlot = self._state:spiderAtEndpoint(selector)
    local ride = AzaleaGym.new({
      player = player,
      actors = self._actors,
      followingMon = self._followingMon,
      audio = self._audio,
      state = self._state,
      camera = self._camera,
      model = spiderSlot ~= nil and self._spiderModels[spiderSlot] or nil,
    })
    if ride:start(selector) then
      self._active = ride
    else
      self._active = nil
    end
    return
  end
  if action == "switch" then
    requireKind(self, GymMechanismState.AZALEA)
    self._state:toggleSwitch(assert(operands.switchNumber, "a switch flip needs its source switch number"))
    self._audio:play(GymMechanism.SWITCH_SEQUENCE)
    self._switch = { sound = GymMechanism.SWITCH_SEQUENCE }
    return
  end
  if action == "candle_extinguish" then
    -- ScrCmd_EcruteakGymExtinguishCandle returns TRUE for every mechanism kind,
    -- so a wrong gym yields once without touching a candle; the byte selector
    -- names the source script environment attribute the candle is read from.
    if self._state:kind() ~= GymMechanismState.ECRUTEAK then
      return
    end
    local actorId
    if operands.useLastInteracted == true then
      actorId = operands.lastInteractedActor
      if type(actorId) ~= "string" or actorId == "" then
        Errors.raise(
          FieldErrors.FIELD_GYM_MECHANISM_INVALID,
          "the source candle command needs the last interacted actor",
          { actor = tostring(actorId) }
        )
      end
    else
      actorId = self:_engagedActorId()
    end
    -- Errors.raise carries no noreturn annotation, so the branch's guard leaves
    -- the value unnarrowed; reaching here proves the command read an actor.
    self:_ecruteakGym():beginExtinguish(assert(actorId, "the candle command resolves the actor it extinguishes"))
    return
  end
  if action == "winch" then
    -- ScrCmd_CianwoodGymTurnWinch answers OpenTrainer/refusal through its own
    -- output variable: the mechanism writes the source boolean either way.
    local winch = CianwoodGym.new({
      state = self._state,
      camera = self._camera,
      runtimeMap = self._runtimeMap,
    })
    local accepted = winch:activate()
    self._result = accepted and 1 or 0
    if accepted then
      self._winch = winch
    else
      winch:dispose()
    end
    return
  end
  Errors.raise(FieldErrors.FIELD_GYM_MECHANISM_INVALID, "unknown gym mechanism action", { action = tostring(action) })
end

-- The source boolean a blocking gym command answers, taken exactly once by the
-- task that completed it.
---@return integer|nil
function GymMechanism:takeResult()
  local result = self._result
  self._result = nil
  return result
end

-- One fixed tick of the owned activation. Answers "complete" when nothing is
-- left to wait for, including a refused ride whose source table had no route.
---@return string status
function GymMechanism:step()
  local switchWait = self._switch
  if switchWait ~= nil then
    local complete = true
    if type(self._audio.isEffectWaitComplete) == "function" then
      complete = self._audio:isEffectWaitComplete(switchWait.sound) == true
    end
    if complete then
      self._switch = nil
      return "complete"
    end
    return "riding"
  end
  local winch = self._winch
  if winch ~= nil then
    winch:updateFixed()
    if not winch:isComplete() then
      return "riding"
    end
    winch:dispose()
    self._winch = nil
    return "complete"
  end
  local ecruteak = self._ecruteak
  if ecruteak ~= nil and not ecruteak:isExtinguishComplete() then
    ecruteak:updateFixed()
    if not ecruteak:isExtinguishComplete() then
      return "riding"
    end
    return "complete"
  end
  local ride = self._active
  if ride == nil then
    return "complete"
  end
  ride:updateFixed()
  if not ride:isComplete() then
    return "riding"
  end
  ride:dispose()
  self._active = nil
  return "complete"
end

-- Cancel the owned activation: the ride restores its anchor and its settled
-- floor, and the switch keeps the bit it already committed.
---@param reason string?
function GymMechanism:cancelRide(reason)
  local winch = self._winch
  if winch ~= nil then
    self._winch = nil
    winch:cancel(reason)
    winch:dispose()
  end
  local ecruteak = self._ecruteak
  if ecruteak ~= nil then
    ecruteak:cancelExtinguish()
  end
  local blackthorn = self._blackthorn
  if blackthorn ~= nil then
    blackthorn:cancel()
  end
  local ride = self._active
  if ride == nil then
    return
  end
  self._active = nil
  ride:cancel(reason)
  ride:dispose()
end

-- The completed-step seam the field asks before publishing an ordinary step
-- or warp. Only the source's platform buttons claim a completed step: the
-- mechanism is asked exactly once per committed step, a real button starts the
-- platform action, and the claimed tick publishes no ordinary step, no warp and
-- no encounter.
---@param step { mapId: integer, fieldX: integer, fieldZ: integer, facing: string }
---@return boolean claimed
function GymMechanism:tryClaimCompletedStep(step)
  if self._state:kind() ~= GymMechanismState.BLACKTHORN then
    return false
  end
  local blackthorn = self:_blackthornGym()
  if blackthorn:isRunning() then
    return false
  end
  if not blackthorn:startAction(step.fieldX, step.fieldZ) then
    return false
  end
  return true
end

return GymMechanism
