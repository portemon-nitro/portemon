-- Owns one field runtime's battle launch and presentation lifetime.

local MetatileBehavior = require("libs.hgss.src.world.MetatileBehavior")
local TimeOfDayProps = require("libs.hgss.src.presentation.TimeOfDayProps")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")

---@class FieldBattleCoordinator
---@field runtime FieldRuntime? borrowed field composition while live
---@field battleRuntime table<string, unknown>?
---@field battlePresentation table<string, unknown>?
---@field _battleLaunch table<string, unknown>?
---@field _battleReceipt table<string, unknown>?
---@field _lastBattleResult table<string, unknown>?
---@field _battlePresentationFactory table<string, unknown>?
---@field _battlePresentationBindingId integer?
---@field _battlePresentationWithdrawn boolean
---@field _disposed boolean
local FieldBattleCoordinator = {}
FieldBattleCoordinator.__index = FieldBattleCoordinator

---@param runtime FieldRuntime
---@return FieldBattleCoordinator
function FieldBattleCoordinator.new(runtime)
  return setmetatable({
    runtime = runtime,
    _battlePresentationWithdrawn = false,
    _disposed = false,
  }, FieldBattleCoordinator)
end

---@param self FieldBattleCoordinator
---@return FieldRuntime
local function fieldRuntime(self)
  return assert(self.runtime, "field battle coordinator is disposed")
end

-- Freezes the evolution world facts at battle composition: the encounter
-- clock band the gameplay already uses, with morning folded into day
-- for the source morning/day check, plus the standing map identity.
-- Reads only, never the live clock after return; without a readable
-- field clock or map the context stays absent and no evolution stages.
---@param self FieldBattleCoordinator
---@return table<string, unknown>? frozen evolution context for the launched battle
local function frozenEvolutionContext(self)
  local runtime = self.runtime
  if type(runtime) ~= "table" then
    return nil
  end
  if type(runtime.encounterTimeOfDay) ~= "function" then
    return nil
  end
  local okClock, band = pcall(function()
    return runtime:encounterTimeOfDay()
  end)
  if not okClock or type(band) ~= "string" or band == "" then
    return nil
  end
  -- Source day checks answer morning beside day; only night stays late.
  local timeOfDay = band
  if timeOfDay == "morning" then
    timeOfDay = "day"
  elseif timeOfDay ~= "day" and timeOfDay ~= "night" then
    return nil
  end
  local context = { timeOfDay = timeOfDay } --[[@as table<string, unknown>]]
  local session = runtime.session
  local map = nil
  if type(session) == "table" then
    map = session.currentMap
  end
  if map == nil then
    map = runtime.runtimeMap
  end
  if type(map) == "table" and type(map.mapId) == "number" then
    context.mapId = map.mapId
  end
  return context
end

-- Releases one scripted-defeat transfer under its authored continuation:
-- defeat hands music ownership to the recovery path untouched, clears
-- both holds and stale input, and drops the owned port and launch while
-- the receipt published at the transfer stays readable.
---@param self FieldBattleCoordinator
---@param launch table<string, unknown>
local function releaseScriptedTransfer(self, launch)
  self:_resumeBattleAudio(launch, false)
  if fieldRuntime(self).session ~= nil then
    fieldRuntime(self).session:setBattleActive(false)
    fieldRuntime(self).session:setForegroundHold(false)
  end
  if fieldRuntime(self).input ~= nil then
    fieldRuntime(self).input:clearAll()
  end
  self.battleRuntime = nil
  self._battleLaunch = nil
end

local NEXT_BATTLE_LAUNCH_ID = 0

-- Outdoor background identities selecting source-daylight scenes; every
-- other background plays under its interior band. Mirrors the source
-- background identity order behind the presentation scene inventory.
local OUTDOOR_BATTLE_BACKGROUNDS = {
  general = true,
  ocean = true,
  city = true,
  forest = true,
  mountain = true,
  snow = true,
}

-- Battle-private standing-tile water set behind MetatileBehavior_IsSurfableWater
-- (src/metatile_behavior.c). Battle scene selection keeps its own copy so
-- field movement keeps using MetatileBehavior.isSurfableWater unchanged.
local BATTLE_SURFABLE_WATER_BEHAVIORS = {
  [16] = true,
  [17] = true,
  [18] = true,
  [19] = true,
  [20] = true,
  [21] = true,
  [25] = true,
  [42] = true,
  [80] = true,
  [81] = true,
  [82] = true,
  [83] = true,
  [115] = true,
  [120] = true,
  [124] = true,
}

-- Battle terrain class for one standing metatile behavior, in the precedence
-- of FieldSystem_GetTerrainFromStandingTile (src/battle/battle_setup.c):
-- ice, tall/very tall grass, sand, snow, marsh mud, cave floor
-- (include/constants/metatile_behavior.h), then the surfable-water flag set.
-- Returns nil when no special class applies so the background default holds.
---@param behavior integer?
---@return string? battle terrain class, nil when the background default applies
local function battleTerrainForStandingBehavior(behavior)
  if behavior == nil then
    return nil
  end
  if behavior == 32 then
    return "ice"
  end
  if MetatileBehavior.isTallGrass(behavior) or MetatileBehavior.isVeryTallGrass(behavior) then
    return "grass"
  end
  if behavior == 33 then
    return "sand"
  end
  if behavior == 168 then
    return "snow"
  end
  if behavior == 164 then
    return "great_marsh"
  end
  if behavior == 8 then
    return "cave"
  end
  if BATTLE_SURFABLE_WATER_BEHAVIORS[behavior] == true then
    return "water"
  end
  return nil
end

-- Default battle terrain per background family when the standing behavior
-- names none explicitly.
local DEFAULT_BATTLE_TERRAINS = {
  general = "plain",
  ocean = "water",
  city = "building",
  forest = "grass",
  mountain = "mountain",
  snow = "snow",
  building_1 = "building",
  building_2 = "building",
  building_3 = "building",
  cave_1 = "cave",
  cave_2 = "cave",
  cave_3 = "cave",
  will = "will",
  koga = "koga",
  bruno = "bruno",
  karen = "karen",
  lance = "lance",
  distortion_world = "distortion_world",
}

-- Binds the per-launch presented-battle factory: the runtime calls it once
-- with a detached launch descriptor at admission and uses the fresh
-- five-operation port it returns for that launch only. A stored disposable
-- port can never span two launches, so production binds a factory instead.
-- Mirrors the party preparation binding: one owner, monotonically
-- increasing identities, and stale unbinds never detach a replacement.
---@param factory fun(descriptor: table<string, unknown>): table<string, unknown> per-launch presentation factory
---@return integer binding identity for the presented lifetime
function FieldBattleCoordinator:bindBattlePresentation(factory)
  assert(type(factory) == "function", "battle presentation binding requires its factory function")
  assert(self._battlePresentationFactory == nil, "one battle presentation binding owns the presented lifetime")
  self._battlePresentationBindingId = (self._battlePresentationBindingId or 0) + 1
  self._battlePresentationFactory = { id = self._battlePresentationBindingId, make = factory }
  self._battlePresentationWithdrawn = false
  return self._battlePresentationBindingId
end

-- Removes only the matching binding: a stale unbind never drops a
-- replacement presentation, and launches admitted after disposal fail at
-- admission instead of presenting without a screen.
---@param binding integer binding identity from bindBattlePresentation
function FieldBattleCoordinator:unbindBattlePresentation(binding)
  local current = self._battlePresentationFactory
  if current ~= nil and current.id == binding then
    self._battlePresentationFactory = nil
    self._battlePresentationWithdrawn = true
  end
end

---@param port table<string, unknown> battle presentation port
function FieldBattleCoordinator:attachBattlePresentation(port)
  assert(type(port) == "table", "battle presentation stays a record")
  assert(type(port.enter) == "function", "battle presentation implements enter")
  assert(type(port.present) == "function", "battle presentation implements present")
  assert(type(port.leave) == "function", "battle presentation implements leave")
  assert(type(port.dispose) == "function", "battle presentation implements dispose")
  self.battlePresentation = port
end

-- Starts the owned application battle lifetime for one launch request and
-- freezes player input until it returns. Only one battle runs at a time;
-- presentation readiness (attached or default) gates entry and return.
---@param args { request: table<string, unknown>, scenario: table<string, unknown>?, presentation: table<string, unknown>?, seed: integer? }
---@return table<string, unknown> the owned application battle lifetime
function FieldBattleCoordinator:startBattle(args)
  assert(type(args) == "table", "battle launches require an argument record")
  assert(self.battleRuntime == nil, "a battle is already active")
  local BattleRuntime = require("game.hgss.src.battle.BattleRuntime")
  local request = assert(args.request, "battle launches require their request")
  local scenario = args.scenario or fieldRuntime(self):buildBattleScenario(request)
  local launch = self._battleLaunch
  if launch ~= nil and launch.request.id == request.id and type(launch.environment) == "table" then
    local detachedScenario = {}
    for key, value in pairs(scenario) do
      detachedScenario[key] = value
    end
    local environment = {}
    if type(scenario.environment) == "table" then
      for key, value in pairs(scenario.environment) do
        environment[key] = value
      end
    end
    environment.terrain = launch.environment.terrain
    detachedScenario.environment = environment
    scenario = detachedScenario
  end
  -- Live consequence owners ride along so resolution stages through
  -- them: the bag and dex owners plus the player money facts. Prize
  -- inputs, captures, planned consumption, and roamer deltas arrive from
  -- explicit drivers; without them the runtime stages only what the
  -- executed battle determines.
  local playerFacts = nil
  if fieldRuntime(self).playerData ~= nil and fieldRuntime(self).playerDataContext ~= nil then
    playerFacts = { record = fieldRuntime(self).playerData, context = fieldRuntime(self).playerDataContext }
  end
  local runtime = fieldRuntime(self)
  local pokegear = nil
  if
    runtime.pokegearState ~= nil
    and runtime.pokegearRandom ~= nil
    and runtime.pokegearCatalog ~= nil
    and runtime.itemCatalog ~= nil
    and runtime.eventState ~= nil
  then
    local eventState = runtime.eventState --[[@as table<string, unknown>]]
    local isFlagSet = eventState.isFlagSet --[[@as fun(self: table<string, unknown>, flag: integer): boolean]]
    pokegear = {
      state = runtime.pokegearState,
      savingsEnabled = isFlagSet(eventState, FieldScriptSymbols.flagsByName.FLAG_SYS_MOMS_SAVINGS),
      random = runtime.pokegearRandom,
      itemCatalog = runtime.itemCatalog,
      momPurchases = runtime.pokegearCatalog.momPurchases,
    }
  end
  -- The presentation port resolves per launch: an explicit caller port
  -- wins, then the bound per-launch factory's fresh port for its admitted
  -- launch, then the stored port. A presented field without its bound
  -- factory never implicitly succeeds headless at this boundary.
  local presentation = args.presentation
  if presentation == nil then
    local activeLaunch = self._battleLaunch
    if
      activeLaunch ~= nil
      and activeLaunch.presented == true
      and activeLaunch.request.id == request.id
      and activeLaunch.port ~= nil
    then
      presentation = activeLaunch.port
    else
      presentation = self.battlePresentation
    end
  end
  local battleArgs = {
    request = request,
    scenario = scenario,
    presentation = presentation,
    party = fieldRuntime(self).monService,
    bag = fieldRuntime(self).bagService,
    dex = fieldRuntime(self).dexKnowledge,
    player = playerFacts,
    pokegear = pokegear,
    seed = args.seed,
  }
  -- The frozen evolution clock and map ride the same composition into
  -- the runtime; an unreadable field simply stages no evolution.
  local evolutionContext = frozenEvolutionContext(self)
  if evolutionContext ~= nil then
    battleArgs.evolutionContext = evolutionContext
  end
  local battle = BattleRuntime.new(battleArgs)
  self.battleRuntime = battle
  if fieldRuntime(self).session ~= nil then
    fieldRuntime(self).session:setBattleActive(true)
  end
  return battle
end

-- Reconciles the derived input gate from the current battle ownership:
-- a field-owned launch or battle handle plus any directly constructed
-- battle over the same live party. Both edges assign, so the gate never
-- latches true and an owned launch or return interval is never cleared
-- while it still owns the field.
function FieldBattleCoordinator:reconcileBattleGate()
  if fieldRuntime(self).session == nil then
    return
  end
  local owned = self.battleRuntime ~= nil or self._battleLaunch ~= nil
  local direct = false
  if fieldRuntime(self).monService ~= nil then
    local BattleRuntime = require("game.hgss.src.battle.BattleRuntime")
    direct = BattleRuntime.isActiveFor(fieldRuntime(self).monService)
  end
  fieldRuntime(self).session:setBattleActive(owned or direct)
end

-- Drives the owned battle once per runtime update and returns through the
-- stable field when it settles. A committed battle records its outcome
-- words for script result reads; a failed battle faults the runtime
-- loudly instead of resuming the story as a success. Presented launches
-- advance only here: the host-update pump skips them, and the envelope's
-- fixed driver is their sole caller.
function FieldBattleCoordinator:updateBattle()
  if self._disposed then
    return
  end
  local launch = self._battleLaunch
  if launch ~= nil and launch.presented == true then
    self:_updatePresentedBattle(launch)
    return
  end
  if launch ~= nil and launch.phase == "leaving" then
    local phase, failure = fieldRuntime(self).overworld:phase()
    if failure ~= nil or phase == "failed" then
      launch.phase = "failed"
      launch.error = failure
      error(failure or "overworld leave failed", 0)
    end
    if phase ~= "absent" then
      self:reconcileBattleGate()
      return
    end
    local request = launch.request
    self:startBattle({ request = request, scenario = launch.scenario })
    launch.phase = "active"
  end

  if launch ~= nil and launch.phase == "restoring" then
    local phase, failure = fieldRuntime(self).overworld:phase()
    if failure ~= nil or phase == "failed" then
      launch.phase = "failed"
      launch.error = failure
      error(failure or "overworld restore failed", 0)
    end
    if phase ~= "present" then
      self:reconcileBattleGate()
      return
    end
    launch.phase = "complete"
    launch.committed = true
    self._lastBattleResult = { result = launch.result, sourceResult = launch.sourceResult }
    self._battleReceipt = launch
    self._battleLaunch = nil
    self:reconcileBattleGate()
    return
  end

  local battle = self.battleRuntime
  if battle == nil then
    self:reconcileBattleGate()
    return
  end
  battle:update()
  local status = battle:status()
  if status.phase ~= "complete" and status.phase ~= "failed" then
    self:reconcileBattleGate()
    return
  end
  local accepted = true
  local decision = nil
  if status.phase == "complete" then
    accepted, decision =
      pcall(fieldRuntime(self).acceptCommittedBattleStatus, fieldRuntime(self), launch, battle, status)
  end
  battle:dispose()
  self.battleRuntime = nil
  self:reconcileBattleGate()
  if status.phase == "failed" or not accepted then
    local failure = status.error or (not accepted and tostring(decision)) or "the battle reported a failure"
    if launch ~= nil then
      launch.phase = "failed"
      launch.error = failure
      self._battleReceipt = launch
      self._battleLaunch = nil
    end
    error(failure, 0)
  end
  if decision ~= nil then
    if launch == nil then
      self._lastBattleResult = { result = decision.result, sourceResult = decision.sourceResult }
    elseif not decision.successful then
      launch.phase = "complete"
      launch.committed = true
      self._lastBattleResult = { result = decision.result, sourceResult = decision.sourceResult }
      self._battleReceipt = launch
      self._battleLaunch = nil
    else
      launch.phase = "restoring"
      self._lastBattleResult = { result = decision.result, sourceResult = decision.sourceResult }
      fieldRuntime(self).overworld:requestRestore()
    end
  end
  self:reconcileBattleGate()
end

-- Advances one presented launch through its covered envelope: full field
-- cover before semantic leave, one construction under that cover, ordered
-- playback and exactly-once commit, terminal cover before disposal, and
-- the distinct continuing, scripted-defeat, and automatic-defeat returns.
-- Every wait is level-triggered and idempotent across fixed updates. A
-- reported screen failure or any terminal launch failure faults the
-- runtime with its original cause; a presented battle never quietly
-- returns to the field.
---@param launch table<string, unknown> presented launch record
function FieldBattleCoordinator:_updatePresentedBattle(launch)
  if launch.screenError ~= nil then
    error(launch.screenError, 0)
  end
  local phase = launch.phase
  if phase == "covering" then
    if launch.coverComplete == true then
      fieldRuntime(self).overworld:requestLeave()
      launch.phase = "leaving"
    end
    return
  end
  if phase == "leaving" then
    local overworldPhase, failure = fieldRuntime(self).overworld:phase()
    if failure ~= nil or overworldPhase == "failed" then
      error(failure or "overworld leave failed", 0)
    end
    if overworldPhase ~= "absent" then
      return
    end
    self:startBattle({ request = launch.request })
    launch.phase = "active"
    return
  end
  if phase == "active" then
    local battle = assert(self.battleRuntime, "presented battle vanished before settlement")
    battle:update()
    local status = battle:status()
    if status.phase ~= "complete" and status.phase ~= "failed" then
      return
    end
    if status.phase == "failed" then
      error(status.error or "the battle reported a failure", 0)
    end
    local decision = fieldRuntime(self):acceptCommittedBattleStatus(launch, battle, status)
    assert(decision ~= nil, "a complete presented battle returns its acceptance decision")
    launch.phase = "terminal"
    return
  end
  if phase == "terminal" then
    if launch.battleCovered ~= true then
      return
    end
    -- Terminal playback and acknowledgement finished under full battle
    -- cover: dispose the battle port once while the envelope retains its
    -- cover. The battle reference stays until the safe field returns so
    -- the transient save gate and settle loops observe the lifetime.
    local battle = self.battleRuntime
    if battle ~= nil then
      battle:dispose()
    end
    local result = launch.result
    if result == "loss" or result == "draw" then
      if launch.scripted == true then
        -- Scripted defeat publishes its receipt while absent for the
        -- authored continuation and transfers hold and cover there. The
        -- battle reference releases now (settle loops observe the owned
        -- lifetime until this handoff); the launch record persists until
        -- the continuation restores or recovers, keeping the transient
        -- save gate closed through the transfer.
        launch.phase = "transfer"
        launch.committed = true
        self._lastBattleResult = { result = result, sourceResult = launch.sourceResult }
        self._battleReceipt = launch
        self.battleRuntime = nil
      else
        self:_beginAutomaticRecovery(launch)
      end
    else
      self._lastBattleResult = { result = result, sourceResult = launch.sourceResult }
      fieldRuntime(self).overworld:requestRestore()
      launch.phase = "restoring"
    end
    return
  end
  if phase == "restoring" then
    local overworldPhase, failure = fieldRuntime(self).overworld:phase()
    if failure ~= nil or overworldPhase == "failed" then
      error(failure or "overworld restore failed", 0)
    end
    if overworldPhase ~= "present" then
      return
    end
    -- The continuing return waits for actual destination scene and actor
    -- presentation, never for presence alone; only then does field music
    -- resume once ahead of the reveal.
    if not fieldRuntime(self):destinationWorldPresentable() then
      return
    end
    fieldRuntime(self):acknowledgeDestinationPresentation()
    self:_resumeBattleAudio(launch, true)
    launch.phase = "revealing"
    return
  end
  if phase == "revealing" then
    if launch.revealed ~= true then
      return
    end
    self:_publishPresentedReceipt(launch)
    return
  end
  if phase == "recovering" then
    self:_pumpAutomaticRecovery(launch)
    return
  end
  if phase == "transfer" then
    self:_finishScriptedTransfer(launch)
    return
  end
end

-- Starts the existing whiteout recovery exactly once for an automatically
-- launched defeat: relocation, healing, follower reset, message, and the
-- scheduled mom and Pokemon Center follow-up stay with that owner. The
-- launch has no launching script to perform the recovery.
---@param launch table<string, unknown> presented launch record
function FieldBattleCoordinator:_beginAutomaticRecovery(launch)
  if launch.recoveryStarted == true then
    return
  end
  launch.recoveryStarted = true
  local flow = assert(fieldRuntime(self).blackoutFlow, "automatic defeat recovery requires its blackout flow")
  local travel = fieldRuntime(self).fieldTravel
  assert(travel ~= nil and travel.lastHealSpawn ~= nil, "automatic defeat recovery requires its durable spawn")
  launch.recoveryRunId = flow:start(travel.lastHealSpawn)
  launch.pendingRecoveryInput = nil
  launch.phase = "recovering"
end

-- Pumps the automatic recovery through the existing flow until its
-- follow-up is scheduled, then waits for the restored present field and
-- its actual scene readiness before exposing the safe field. The flow is
-- driven directly because no launching script owns its task: the waiting
-- recovery message answers only one queued genuine edge per tick, and
-- every other phase pumps dry. The consumed edge clears whether or not
-- the flow accepted it, so one held press never acknowledges twice. The
-- follow-up runs as a background script since no parent task run exists
-- to parent it to.
---@param launch table<string, unknown> presented launch record
function FieldBattleCoordinator:_pumpAutomaticRecovery(launch)
  local flow = assert(fieldRuntime(self).blackoutFlow, "automatic defeat recovery lost its blackout flow")
  if launch.recoveryFollowup ~= true then
    local status = flow:status()
    if status.error ~= nil then
      error(status.error, 0)
    end
    if status.complete ~= true then
      local pending = launch.pendingRecoveryInput
      launch.pendingRecoveryInput = nil
      local admitted = type(pending) == "table" and pending.runId == launch.recoveryRunId
      flow:updateFixed({
        pressedAction = admitted == true and pending.pressedAction == true,
        pressedCancel = admitted == true and pending.pressedCancel == true,
        touchPressed = admitted == true and pending.touchPressed == true,
      })
      -- A tick that completes the flow falls through to the follow-up
      -- below instead of waiting another tick: the restored field and
      -- its committed receipt publish together, never a tick apart.
      status = flow:status()
      if status.error ~= nil then
        error(status.error, 0)
      end
      if status.complete ~= true then
        return
      end
    end
    local followup = flow:consumeResult(launch.recoveryRunId)
    assert(type(followup) == "string", "completed blackout supplies its follow-up")
    local scheduler = fieldRuntime(self).scripts ~= nil and fieldRuntime(self).scripts.scheduler or nil
    assert(scheduler ~= nil, "automatic defeat recovery requires its scheduler")
    local composed = scheduler:resolveComposition(followup)
    if composed == nil then
      error("blackout follow-up script is unavailable: " .. followup, 0)
    end
    local session = fieldRuntime(self).session
    scheduler:createBackground(composed, nil, session ~= nil and session.tick or 0)
    launch.recoveryFollowup = true
  end
  local overworldPhase, failure = fieldRuntime(self).overworld:phase()
  if failure ~= nil or overworldPhase == "failed" then
    error(failure or "recovery restore failed", 0)
  end
  if overworldPhase ~= "present" then
    return
  end
  if not fieldRuntime(self):destinationWorldPresentable() then
    return
  end
  fieldRuntime(self):acknowledgeDestinationPresentation()
  -- Defeat transfers music ownership to the recovery path: release the
  -- hold without replaying, respecting its authored music decision.
  self:_resumeBattleAudio(launch, false)
  launch.result = launch.result or "loss"
  launch.sourceResult = launch.sourceResult or 0
  self:_publishPresentedReceipt(launch)
end

-- Finishes a scripted-defeat transfer once its authored continuation takes
-- ownership: an observed blackout run that completes and is consumed, or
-- an authored ordinary restoration. Until then the field stays covered
-- and absent under the source script's authority.
---@param launch table<string, unknown> presented launch record
function FieldBattleCoordinator:_finishScriptedTransfer(launch)
  local overworldPhase, failure = fieldRuntime(self).overworld:phase()
  if failure ~= nil or overworldPhase == "failed" then
    error(failure or "transfer restore failed", 0)
  end
  if overworldPhase == "present" then
    releaseScriptedTransfer(self, launch)
    return
  end
  local flow = fieldRuntime(self).blackoutFlow
  if flow == nil then
    return
  end
  local status = flow:status()
  if status.phase ~= "idle" then
    launch.transferBlackoutSeen = true
    return
  end
  if launch.transferBlackoutSeen ~= true then
    return
  end
  releaseScriptedTransfer(self, launch)
end

-- Battle host observation for script result reads: the latest committed
-- outcome words, or nil when no battle has committed yet.
---@return table<string, unknown>?
function FieldBattleCoordinator:lastBattleResult()
  return self._lastBattleResult
end

-- Battle host observation for script battle tasks: the owned battle's
-- committed outcome for one launch, or nil when no owned battle carries
-- that identity.
---@param launchId string
---@return table<string, unknown>?
function FieldBattleCoordinator:battleStatus(launchId)
  local receipt = self._battleReceipt
  if receipt ~= nil and receipt.launchId == launchId then
    return {
      phase = receipt.phase,
      committed = receipt.committed == true,
      result = receipt.result,
      sourceResult = receipt.sourceResult,
      error = receipt.error,
    }
  end
  local launch = self._battleLaunch
  if launch ~= nil and launch.launchId == launchId then
    return {
      phase = launch.phase,
      committed = launch.committed == true,
      result = launch.result,
      sourceResult = launch.sourceResult,
      error = launch.error,
    }
  end
  local battle = self.battleRuntime
  if battle == nil then
    return nil
  end
  return battle:battleStatus(launchId)
end

-- Battle host launch for script battle tasks: issues a unique launch
-- identity per call (two runs of one script site never share a commit
-- receipt) and starts the owned battle for the evaluated payload. A bound
-- presented factory takes the covered envelope route (cover first, leave
-- only under full cover); without one the launch keeps its headless
-- leave-first behavior.
---@param spec { launchId: string?, kind: string?, details: table<string, unknown>? }
---@return string the issued launch identity
function FieldBattleCoordinator:launchBattle(spec)
  assert(type(spec) == "table", "battle host launches require a spec record")
  assert(self._battleLaunch == nil and self.battleRuntime == nil, "a field-owned battle is already active")
  self._battleReceipt = nil
  NEXT_BATTLE_LAUNCH_ID = NEXT_BATTLE_LAUNCH_ID + 1
  local tag = spec.launchId or spec.kind or "battle"
  local launchId = tostring(tag) .. "#" .. tostring(NEXT_BATTLE_LAUNCH_ID)
  local payload = spec.details or {}
  assert(type(payload) == "table", "battle host launches carry their payload record")
  local request = { id = launchId, kind = spec.kind or "wild", payload = payload }
  if self._battlePresentationFactory ~= nil then
    return self:launchPresentedBattle(launchId, request, nil)
  end
  assert(self._battlePresentationWithdrawn ~= true, "presented launches require their factory binding")
  fieldRuntime(self).overworld:requestLeave()
  self._battleLaunch = { launchId = launchId, phase = "leaving", request = request }
  return launchId
end

-- Reads the party lead for admission pre-seeding: slot zero carries the
-- opening battler, and anything unreadable simply pre-seeds nothing while
-- the required preparation path reports with its context later.
---@return table<string, unknown>? lead mon record, nil when unavailable
function FieldBattleCoordinator:_launchLeadMon()
  local runtime = self.runtime
  local service = type(runtime) == "table" and runtime.monService or nil
  if type(service) ~= "table" or type(service.partyMon) ~= "function" then
    return nil
  end
  local ok, mon = pcall(function()
    return service:partyMon(0)
  end)
  if not ok or type(mon) ~= "table" then
    return nil
  end
  return mon
end

-- Reads the wild foe for admission pre-seeding: trainer rosters resolve
-- later through their catalog, so only a carried foe record pre-seeds.
---@param request table<string, unknown> launch request carrying its identity and kind
---@return table<string, unknown>? foe mon record, nil when unavailable
function FieldBattleCoordinator:_launchFoeMon(request)
  local payload = request.payload
  if type(payload) == "table" and type(payload.mon) == "table" then
    return payload.mon
  end
  return nil
end

-- Admits one presented launch: captures the launch environment before the
-- field changes, builds the fresh per-launch port through the bound
-- factory, then claims input/foreground and the battle-music policy for
-- the launch lifetime. Semantic leave waits for full field cover under
-- the envelope's fixed driver. A factory failure fails the admission
-- loudly with no partial claim and never impersonates a battle.
---@param launchId string issued launch identity
---@param request table<string, unknown> launch request carrying its identity and kind
---@param method string? encounter method for step admissions, nil otherwise
---@return string the issued launch identity
function FieldBattleCoordinator:launchPresentedBattle(launchId, request, method)
  assert(self._battleLaunch == nil and self.battleRuntime == nil, "a field-owned battle is already active")
  local binding = assert(self._battlePresentationFactory, "presented launches require their factory binding")
  local environment = self:_captureLaunchEnvironment(request, method)
  local transitionContext = self:_captureTransitionContext(request, environment)
  local launch = {
    launchId = launchId,
    phase = "covering",
    request = request,
    presented = true,
    scripted = false,
    environment = environment,
    transitionContext = transitionContext,
    coverComplete = false,
    battleCovered = false,
    revealed = false,
    result = nil,
    sourceResult = nil,
    committed = false,
    error = nil,
    recovery = nil,
    recoveryFollowup = false,
    transferBlackoutSeen = false,
  }
  local function presentedStatus()
    return self:_presentedLaunchStatus(launchId)
  end
  local function presentedAdvance()
    self:updateBattle()
  end
  local function presentedSubmit(reply)
    return self:_presentedSubmit(launchId, reply)
  end
  local function presentedNotify(event, detail)
    self:_presentedNotify(launchId, event, detail)
  end
  local function presentedRecoveryInput(edge)
    return self:_presentedRecoveryInput(launchId, edge)
  end
  local launchSpeed = fieldRuntime(self).playerData.options.textSpeed
  assert(
    type(launchSpeed) == "string" and launchSpeed ~= "",
    "presented battle launches carry the player narration pace"
  )
  local descriptor = {
    launchId = launchId,
    kind = request.kind,
    scripted = false,
    environment = environment,
    transitionContext = transitionContext,
    textSpeed = launchSpeed,
    audio = fieldRuntime(self).audio,
    musicRole = self:_battleMusicRole(request),
    trainerClass = self:_battleTrainerClass(request),
    leadMon = self:_launchLeadMon(),
    foeMon = self:_launchFoeMon(request),
    host = {
      status = presentedStatus,
      advance = presentedAdvance,
      submit = presentedSubmit,
      notify = presentedNotify,
      recoveryInput = presentedRecoveryInput,
    },
  }
  local ok, port = pcall(binding.make, descriptor)
  if not ok or type(port) ~= "table" then
    error(
      "presented battle admission failed for launch "
        .. launchId
        .. ": "
        .. tostring(port or "presented battle factory returned no port"),
      0
    )
  end
  launch.port = port
  self._battleLaunch = launch
  -- Claim input and the foreground hold synchronously, before another
  -- catch-up tick can start a step: held and edge state clears so nothing
  -- sticks across the envelope boundary.
  if fieldRuntime(self).session ~= nil then
    fieldRuntime(self).session:setBattleActive(true)
    fieldRuntime(self).session:setForegroundHold(true)
  end
  if fieldRuntime(self).input ~= nil then
    fieldRuntime(self).input:clearAll()
  end
  -- The bench re-enrolls its near portrait, cry, and effect demands on
  -- the next update even when the party revision has not changed since
  -- map entry; the lead and foe stage at required urgency through the
  -- admitted descriptor. Field policy suspends later, on the same tick
  -- the battle music voices with the transition effect.
  local runtime = fieldRuntime(self)
  if type(runtime.refreshPartyWarmup) == "function" then
    runtime:refreshPartyWarmup()
  end
  return launchId
end

-- Captures the semantic selector facts from the prepared request before
-- the field changes. Trainer templates are read without materializing a
-- party or consuming the world RNG.
---@param request table<string, unknown> admitted source battle request
---@param environment table<string, unknown> immutable field environment captured for this launch
---@return table<string, unknown> normalized selector context
function FieldBattleCoordinator:_captureTransitionContext(request, environment)
  local payload = request.payload
  assert(type(payload) == "table", "presented battle requests carry their source payload")
  local sourceEnvironment = payload.environment
  if type(sourceEnvironment) ~= "table" then
    sourceEnvironment = {}
  end
  local function sourceFlag(key)
    local value = payload[key]
    if value == nil then
      value = sourceEnvironment[key]
    end
    if value == nil then
      return false
    end
    assert(type(value) == "boolean", "transition source flags are explicit booleans: " .. key)
    return value
  end

  -- Source EncounterEffect_GetDefaultEffect: water and cave keep their own
  -- fallback and every other battle terrain uses plain; only the NITE and
  -- LATE RTC times are late, whatever band the battle scene shows.
  local terrain = environment.terrain
  if terrain ~= "water" and terrain ~= "cave" then
    terrain = "plain"
  end
  local timeOfDay = TimeOfDayProps.rtcCodeForHour(environment.hour) >= 3 and "late" or "day"
  local context = {
    kind = request.kind,
    doubleBattle = sourceFlag("doubleBattle") or payload.format == "double" or payload.format == "wild-double",
    specialBattle = sourceFlag("specialBattle"),
    alternateTransition = sourceFlag("alternateTransition"),
    terrain = terrain,
    timeOfDay = timeOfDay,
  }
  local profileGender = assert(fieldRuntime(self).playerData.profile.gender, "player profile carries its gender")
  assert(profileGender == 0 or profileGender == 1, "player profile gender is a normalized binary value")
  context.playerGender = profileGender == 0 and "male" or "female"

  if request.kind == "trainer" then
    local trainer = payload.trainer
    local trainers = payload.trainers
    if type(trainers) == "table" and #trainers > 0 then
      trainer = assert(trainers[1]).id
      context.doubleBattle = true
    end
    assert(trainer ~= nil, "trainer transition context names its first trainer")
    local catalog = assert(fieldRuntime(self)._trainerCatalog, "trainer transition context reads the trainer catalog")
    local template = assert(
      require("libs.hgss.src.battle.HgssTrainerCatalog").trainer(catalog, trainer),
      "trainer transition context resolves its trainer template"
    )
    assert(
      type(template.trainerClass) == "string" or type(template.trainerClass) == "number",
      "trainer transition context resolves its trainer class for trainer " .. tostring(trainer)
    )
    if type(template.trainerClass) == "string" and template.trainerClass ~= "" then
      context.trainerClass = template.trainerClass
    elseif type(template.trainerClass) == "number" then
      -- Numeric native classes ride the context untouched: the encounter
      -- selector resolves them through the pinned class table while
      -- genuinely-absent identities keep the designed unknown route and
      -- music role there.
      context.trainerClass = template.trainerClass
    else
      context.trainerClass = "SOURCE_UNKNOWN_TRAINER"
    end
    context.doubleBattle = context.doubleBattle or template.doubleBattle == true
  elseif request.kind == "wild" then
    local mon = payload.mon
    local species = payload.species
    if species == nil and type(mon) == "table" then
      species = mon.species
    end
    context.wildSpecies = species
    local fallback = payload.wildSetupFallback
    if fallback == nil then
      fallback = sourceEnvironment.wildSetupFallback
    end
    if fallback == nil then
      fallback = species == nil
    end
    assert(type(fallback) == "boolean", "wild transition setup fallback is an explicit source fact")
    context.wildSetupFallback = fallback
  else
    error("presented transition context requires a trainer or wild launch", 0)
  end

  return context
end

-- Captures the actual launch environment before the field changes: source
-- map identity, committed tile and surface, standing behavior, avatar
-- movement mode, and time of day. Explicit source-request environment
-- overrides ride the record untouched for the scenario; the semantic
-- battle background resolves from the map's compiled battle background
-- with the surfing override to ocean, and terrain follows the standing
-- behavior ahead of the background default. Neither scene nor audio
-- selection consumes battle or encounter randomness.
---@param request table<string, unknown> launch request carrying its payload
---@param method string? encounter method for step admissions, nil otherwise
---@return table<string, unknown> detached launch environment
function FieldBattleCoordinator:_captureLaunchEnvironment(request, method)
  local BattlePresentationCache = require("libs.assets.src.battle.BattlePresentationCache")
  local environment = self:_fieldBattleEnvironment()
  if BattlePresentationCache.parseSceneKey(environment.sceneKey) == nil then
    error("presented battle resolved an unknown scene context: " .. environment.sceneKey, 0)
  end
  local explicit = nil
  local payload = request.payload
  if type(payload) == "table" and type(payload.environment) == "table" then
    explicit = payload.environment
  end
  environment.method = method
  environment.sourceEnvironment = explicit
  return environment
end

-- Cheap battle-scene freshness facts shared by prediction and selection: the
-- raw clock band before indoor clamping, the avatar movement mode, and
-- the authored map background. Each mirrors its _fieldBattleEnvironment
-- rule exactly so the memo and the launched scene agree.
---@param self FieldBattleCoordinator
---@return integer hourInt truncated field hour
---@return string rawBand "day"|"evening"|"night" before indoor clamping
local function sampledBattleClock(self)
  local hour = 12
  local runtime = self.runtime
  if type(runtime) == "table" and runtime.localClock ~= nil then
    local clock = runtime.localClock
    local okClock, now = pcall(function()
      return clock:nowLocal()
    end)
    if okClock and type(now) == "table" and type(now.hour) == "number" then
      hour = now.hour
    end
  end
  local hourInt = math.floor(hour)
  if hourInt < 0 or hourInt >= 24 then
    return 12, "day"
  end
  local band = "day"
  local okBand, bandName = pcall(TimeOfDayProps.bandForHour, hourInt)
  if okBand and bandName == "eve" then
    band = "evening"
  elseif okBand and bandName == "nite" then
    band = "night"
  end
  return hourInt, band
end

---@param self FieldBattleCoordinator
---@return string avatar durable movement mode, "walking" when unreadable
local function sampledMovementMode(self)
  local runtime = self.runtime
  if type(runtime) ~= "table" then
    return "walking"
  end
  local avatar = runtime.playerAvatar
  if avatar ~= nil and type(avatar.status) == "function" then
    local okStatus, status = pcall(function()
      return avatar:status()
    end)
    if okStatus and type(status) == "table" and type(status.durableState) == "string" then
      return status.durableState
    end
  end
  return "walking"
end

---@param map table<string, unknown>?
---@return string authored battle background, "general" when absent
local function authoredBattleBackground(map)
  if type(map) == "table" and type(map.fieldData) == "table" then
    local compiled = map.fieldData.battleBackground
    if type(compiled) == "string" and compiled ~= "" then
      return compiled
    end
  end
  return "general"
end

-- The battle environment the player's committed tile would launch now; the
-- scene key may name an unknown context, which launch capture rejects.
---@param sample { movementMode: string, hour: integer, rawBand: string }? private prefetch sample reused for memo consistency
---@return table<string, unknown> detached field battle environment
function FieldBattleCoordinator:_fieldBattleEnvironment(sample)
  local session = fieldRuntime(self).session
  local map = nil
  if session ~= nil then
    map = session.currentMap
  end
  if map == nil then
    map = fieldRuntime(self).runtimeMap
  end
  local background = authoredBattleBackground(map)
  local player = fieldRuntime(self).player
  local fieldX, fieldZ, surfaceId = nil, nil, nil
  local behavior = nil
  if player ~= nil then
    fieldX, fieldZ, surfaceId = player.fieldX, player.fieldZ, player.surfaceId
    behavior = fieldRuntime(self):arrivalBehavior(map, player)
  end
  local movementMode = nil
  local hourInt = nil
  local rawBand = nil
  if type(sample) == "table" and type(sample.movementMode) == "string" then
    movementMode = sample.movementMode
  else
    movementMode = sampledMovementMode(self)
  end
  if type(sample) == "table" and type(sample.hour) == "number" and type(sample.rawBand) == "string" then
    hourInt = sample.hour
    rawBand = sample.rawBand
  else
    hourInt, rawBand = sampledBattleClock(self)
  end
  if movementMode == "surfing" then
    background = "ocean"
  end
  local band = rawBand
  if OUTDOOR_BATTLE_BACKGROUNDS[background] ~= true then
    band = "day"
  end
  local terrain = DEFAULT_BATTLE_TERRAINS[background] or "plain"
  local standingTerrain = battleTerrainForStandingBehavior(behavior)
  if standingTerrain ~= nil then
    terrain = standingTerrain
  end
  return {
    mapId = (type(map) == "table" and map.mapId) or nil,
    fieldX = fieldX,
    fieldZ = fieldZ,
    surfaceId = surfaceId,
    behavior = behavior,
    movementMode = movementMode,
    background = background,
    terrain = terrain,
    time = band,
    hour = hourInt,
    sceneKey = background .. "/" .. terrain .. "/" .. band,
  }
end

-- Publishes the already computed battle-scene prediction for idle
-- presentation warmup: the memoized key survives only while the
-- committed map, tile, surface, raw time band, movement mode, and
-- authored background still match the prefetch snapshot
-- and no accepted launch owns the field. Read-only: it never
-- recomputes the environment, never queues derived work, and never
-- synthesizes a scene before the first prefetch.
---@return string? memoized valid scene key, nil when stale, launched, or absent
function FieldBattleCoordinator:predictedSceneKey()
  if self._disposed then
    return nil
  end
  if self._battleLaunch ~= nil then
    return nil
  end
  local memo = self._prefetchSceneKey
  if type(memo) ~= "string" or memo == "" then
    return nil
  end
  local runtime = self.runtime
  if type(runtime) ~= "table" then
    return nil
  end
  local session = runtime.session
  local player = runtime.player
  if type(session) ~= "table" or type(player) ~= "table" then
    return nil
  end
  if session.currentMap == nil then
    return nil
  end
  if
    self._prefetchMap ~= session.currentMap
    or self._prefetchX ~= player.fieldX
    or self._prefetchZ ~= player.fieldZ
    or self._prefetchSurface ~= player.surfaceId
    or self._prefetchAuthoredBackground ~= authoredBattleBackground(session.currentMap)
    or self._prefetchMovementMode ~= sampledMovementMode(self)
  then
    return nil
  end
  local _, rawBand = sampledBattleClock(self)
  if self._prefetchRawBand ~= rawBand then
    return nil
  end
  local BattlePresentationCache = require("libs.assets.src.battle.BattlePresentationCache")
  if BattlePresentationCache.parseSceneKey(memo) == nil then
    return nil
  end
  return memo
end

-- Queues the battle scene the next encounter at the committed tile would
-- launch at near urgency, so the shared battle catalog behind every scene
-- builds before an encounter holds the field. Only presented battles need
-- scenes; the environment resolves again only when the committed context
-- (tile, raw time band, movement mode, or authored background) changes,
-- and an unresolvable context clears the memo for the launch to reject.
function FieldBattleCoordinator:prefetchEncounterScene()
  if self._disposed or self._battlePresentationFactory == nil or self._battleLaunch ~= nil then
    return
  end
  local runtime = fieldRuntime(self)
  local host = runtime.derivedAssets
  local session = runtime.session
  local player = runtime.player
  if host == nil or host.requestBattleScene == nil or session == nil or session.currentMap == nil or player == nil then
    return
  end
  local map = session.currentMap
  local authoredBackground = authoredBattleBackground(map)
  local movementMode = sampledMovementMode(self)
  local hourInt, rawBand = sampledBattleClock(self)
  if
    self._prefetchMap == map
    and self._prefetchX == player.fieldX
    and self._prefetchZ == player.fieldZ
    and self._prefetchSurface == player.surfaceId
    and self._prefetchAuthoredBackground == authoredBackground
    and self._prefetchMovementMode == movementMode
    and self._prefetchRawBand == rawBand
  then
    return
  end
  local previousSceneKey = self._prefetchSceneKey
  self._prefetchMap, self._prefetchX, self._prefetchZ = map, player.fieldX, player.fieldZ
  self._prefetchSurface = player.surfaceId
  self._prefetchAuthoredBackground = authoredBackground
  self._prefetchMovementMode = movementMode
  self._prefetchRawBand = rawBand
  local BattlePresentationCache = require("libs.assets.src.battle.BattlePresentationCache")
  local sceneKey =
    self:_fieldBattleEnvironment({ movementMode = movementMode, hour = hourInt, rawBand = rawBand }).sceneKey
  if BattlePresentationCache.parseSceneKey(sceneKey) == nil then
    self._prefetchSceneKey = nil
    return
  end
  if sceneKey ~= previousSceneKey then
    self._prefetchSceneKey = sceneKey
    host.requestBattleScene(sceneKey, "near")
  end
end

-- Chooses the source-defined battle music track for one launch: the
-- wild special-species table wins first, then the trainer class table
-- with the rival override, then the ordinary kind default, with the
-- Kanto regional remap last. Selection consumes no battle or
-- encounter randomness and never infers from display strings. The
-- presentation stages this selected sequence through the normalized
-- audio catalog; selection does not depend on a verified manifest.
---@param request table<string, unknown> launch request carrying its kind and payload
---@return string|number? resolved trainer class key or numeric native class, nil for wild launches
function FieldBattleCoordinator:_battleTrainerClass(request)
  local payload = request.payload
  if type(payload) ~= "table" then
    payload = {}
  end
  local trainerClass = nil
  if request.kind ~= "wild" and (payload.trainer ~= nil or payload.trainerClass ~= nil) then
    if type(payload.trainerClass) == "string" or type(payload.trainerClass) == "number" then
      trainerClass = payload.trainerClass
    else
      if fieldRuntime(self).trainerClassFor ~= nil then
        local okClass, class = pcall(fieldRuntime(self).trainerClassFor, fieldRuntime(self), payload.trainer)
        if okClass and type(class) == "string" then
          trainerClass = class
        elseif okClass and type(class) == "number" then
          trainerClass = class
        end
      end
      if trainerClass == nil and payload.trainer ~= nil then
        -- The runtime class lookup answers string classes only, so numeric
        -- catalog classes resolve from the template the transition capture
        -- reads; selection maps them precisely while genuinely-absent
        -- identities keep the ordinary default there.
        local catalog = fieldRuntime(self)._trainerCatalog
        if catalog ~= nil then
          local HgssTrainerCatalog = require("libs.hgss.src.battle.HgssTrainerCatalog")
          local okTemplate, template = pcall(HgssTrainerCatalog.trainer, catalog, payload.trainer)
          if okTemplate and type(template) == "table" and type(template.trainerClass) == "number" then
            trainerClass = template.trainerClass
          end
        end
      end
    end
  end
  return trainerClass
end

---@param request table<string, unknown> launch request carrying its kind and payload
---@return string? normalized battle-music sequence symbol
function FieldBattleCoordinator:_battleMusicRole(request)
  local BattleMusicSelection = require("game.hgss.src.battle.BattleMusicSelection")
  local payload = request.payload
  if type(payload) ~= "table" then
    payload = {}
  end
  local species = type(payload.species) == "string" and payload.species or nil
  local rivalName = type(payload.rivalName) == "string" and payload.rivalName or nil
  local trainerClass = self:_battleTrainerClass(request)
  local okSelect, selected = pcall(BattleMusicSelection.select, {
    kind = request.kind,
    species = species,
    trainerClass = trainerClass,
    rivalName = rivalName,
  })
  if not okSelect or type(selected) ~= "table" or type(selected.music) ~= "string" then
    return nil
  end
  return selected.music --[[@as string]]
end

-- Presented-launch observation for the envelope's fixed driver: the launch
-- phase, the owned battle phase, overworld presence, and recovery
-- ownership. Nil once the launch clears, so stale envelopes drop it.
---@param launchId string
---@return table<string, unknown>? detached launch status snapshot
function FieldBattleCoordinator:_presentedLaunchStatus(launchId)
  local launch = self._battleLaunch
  if launch == nil or launch.launchId ~= launchId then
    return nil
  end
  local snapshot = {
    phase = launch.phase,
    result = launch.result,
    sourceResult = launch.sourceResult,
    committed = launch.committed == true,
    scripted = launch.scripted == true,
    battlePhase = nil,
    overworld = nil,
    blackoutPhase = nil,
  }
  local battle = self.battleRuntime
  if battle ~= nil then
    local okBattle, battleStatus = pcall(function()
      return battle:status()
    end)
    if okBattle and type(battleStatus) == "table" then
      snapshot.battlePhase = battleStatus.phase
    end
  end
  if fieldRuntime(self).overworld ~= nil then
    local okOverworld, phase = pcall(function()
      return fieldRuntime(self).overworld:phase()
    end)
    if okOverworld then
      snapshot.overworld = phase
    end
  end
  if fieldRuntime(self).blackoutFlow ~= nil then
    local okFlow, flowStatus = pcall(function()
      return fieldRuntime(self).blackoutFlow:status()
    end)
    if okFlow and type(flowStatus) == "table" then
      snapshot.blackoutPhase = flowStatus.phase
    end
  end
  return snapshot
end

-- Queues one genuine recovery edge for the waiting defeat message: only
-- the matching launch admits it, only while recovering, and only while
-- the recovery flow itself waits for input. Anything else is dropped and
-- never deferred, so a press under cover or ahead of the wait cannot
-- answer it later. At most one edge waits per recovery run; the pump
-- consumes it exactly once on the next tick.
---@param launchId string owning launch identity
---@param edge table<string, unknown> one-shot semantic recovery edge
---@return boolean admitted
function FieldBattleCoordinator:_presentedRecoveryInput(launchId, edge)
  local launch = self._battleLaunch
  if launch == nil or launch.launchId ~= launchId or launch.phase ~= "recovering" then
    return false
  end
  local flow = fieldRuntime(self).blackoutFlow
  if flow == nil then
    return false
  end
  local okStatus, status = pcall(function()
    return flow:status()
  end)
  if not okStatus or type(status) ~= "table" or status.waitingInput ~= true then
    return false
  end
  if type(edge) ~= "table" then
    return false
  end
  local pending = nil
  if edge.pressedAction == true then
    pending = { pressedAction = true }
  elseif edge.pressedCancel == true then
    pending = { pressedCancel = true }
  elseif edge.touchPressed == true then
    pending = { touchPressed = true }
  end
  if pending == nil then
    return false
  end
  pending.runId = launch.recoveryRunId
  launch.pendingRecoveryInput = pending
  return true
end

-- Presented decision submission behind the battle screen's accepted-choice
-- boundary: only the live launch battle answers, and only while it owns
-- an open request.
---@param launchId string
---@param reply table<string, unknown> sealed controller reply
---@return boolean stored
---@return table<string, unknown>? input error when the reply is rejected
function FieldBattleCoordinator:_presentedSubmit(launchId, reply)
  local launch = self._battleLaunch
  if launch == nil or launch.launchId ~= launchId then
    return false, { message = "no presented battle owns this launch" }
  end
  local battle = self.battleRuntime
  if battle == nil then
    return false, { message = "the presented battle is not constructed yet" }
  end
  return battle:submit(reply)
end

-- Presented cover handshake from the envelope: each event fires its phase
-- transition exactly once; stale or out-of-phase events are ignored. A lost
-- renderer arrives as screen-failed carrying the original screen error
-- text. The envelope may report from inside its own protected calls, so
-- the first report is kept and raised by the next launch pump.
---@param launchId string
---@param event string cover-complete, battle-covered, revealed, or screen-failed
---@param detail string? original screen error text behind a screen-failed event
function FieldBattleCoordinator:_presentedNotify(launchId, event, detail)
  local launch = self._battleLaunch
  if launch == nil or launch.launchId ~= launchId then
    return
  end
  if event == "cover-complete" then
    if launch.phase == "covering" then
      launch.coverComplete = true
    end
  elseif event == "battle-covered" then
    if launch.phase == "terminal" then
      launch.battleCovered = true
    end
  elseif event == "revealed" then
    if launch.phase == "revealing" then
      launch.revealed = true
    end
  elseif event == "screen-failed" then
    if launch.screenError == nil then
      launch.screenError = detail or "the presented battle screen failed"
    end
  end
end

-- Releases the battle-music claim for one launch: a matching continuing
-- return restores the current field policy once, while defeat transfers
-- ownership to the blackout and source recovery path untouched.
---@param launch table<string, unknown> presented launch record
---@param restoreMusic boolean true to restore the current field policy once
function FieldBattleCoordinator:_resumeBattleAudio(launch, restoreMusic)
  local audio = fieldRuntime(self).audio
  if audio == nil or type(audio.resumeFieldPolicy) ~= "function" then
    return
  end
  audio:resumeFieldPolicy(launch.launchId, restoreMusic == true)
end

-- Adopts the committed receipt's validated player candidate money into the
-- live profile exactly once: prize money and blackout debits reach the live
-- wallet through this boundary, since the committer stages but never
-- publishes player money itself. Later saves capture the adopted money.
---@param launch table<string, unknown> launch record carrying its result
---@param receipt table<string, unknown> committed outcome receipt
function FieldBattleCoordinator:adoptCommittedPlayerMoney(launch, receipt)
  if launch.moneyAdopted == true then
    return
  end
  launch.moneyAdopted = true
  local candidate = receipt.player
  if type(candidate) ~= "table" or type(candidate.profile) ~= "table" then
    return
  end
  local live = fieldRuntime(self).playerData
  if type(live) ~= "table" or type(live.profile) ~= "table" then
    return
  end
  -- The live profile is borrowed by scripts, the mart, and the run gate:
  -- adopt the wallet in place so every borrower keeps observing and
  -- persisting one record.
  live.profile.money = candidate.profile.money
end

-- Publishes one committed continuing receipt only after the restored field
-- is revealed: usable field completion reaches scripts and saves solely
-- through this boundary.
---@param launch table<string, unknown> presented launch record
function FieldBattleCoordinator:_publishPresentedReceipt(launch)
  self._lastBattleResult = { result = launch.result, sourceResult = launch.sourceResult }
  self._battleReceipt = launch
  launch.phase = "complete"
  launch.committed = true
  self._battleLaunch = nil
  -- The retained battle reference releases here: the save gate stays
  -- closed through settlement, restoration, and reveal, and settle loops
  -- observe the owned lifetime until the safe field returns.
  self.battleRuntime = nil
  if fieldRuntime(self).session ~= nil then
    fieldRuntime(self).session:setBattleActive(false)
    fieldRuntime(self).session:setForegroundHold(false)
  end
  if fieldRuntime(self).input ~= nil then
    fieldRuntime(self).input:clearAll()
  end
end

-- Releases a prepared but unconsumed encounter without rerolling: the
-- service protection lifts and later steps may attempt anew. The prepared
-- mon is discarded, never battled and never committed.
---@return boolean released true when a pending encounter was held
function FieldBattleCoordinator:cancelPendingEncounter()
  if fieldRuntime(self).pendingEncounter == nil then
    return false
  end
  fieldRuntime(self):consumePendingEncounter()
  return true
end

---@param tag string launch source identity
---@return string unique launch identity
function FieldBattleCoordinator:nextLaunchIdentity(tag)
  NEXT_BATTLE_LAUNCH_ID = NEXT_BATTLE_LAUNCH_ID + 1
  return tostring(tag) .. "#" .. tostring(NEXT_BATTLE_LAUNCH_ID)
end

---@return table<string, unknown>?
function FieldBattleCoordinator:activeBattle()
  return self.battleRuntime
end

---@return boolean whether an admitted battle launch owns the field
function FieldBattleCoordinator:hasLaunch()
  return self._battleLaunch ~= nil
end

function FieldBattleCoordinator:hasBattleWork()
  return self.battleRuntime ~= nil or self._battleLaunch ~= nil
end

---@return boolean whether the host update owns the next battle pump
function FieldBattleCoordinator:shouldPumpFromHost()
  local launch = self._battleLaunch
  return (self.battleRuntime ~= nil or launch ~= nil) and (launch == nil or launch.presented ~= true)
end

function FieldBattleCoordinator:clearReceipt()
  self._battleReceipt = nil
end

---@return boolean whether presented launches are currently bound
function FieldBattleCoordinator:hasPresentationFactory()
  return self._battlePresentationFactory ~= nil
end

---@param launchId string launch issued to the script battle host
function FieldBattleCoordinator:markScriptedLaunch(launchId)
  local launch = self._battleLaunch
  if launch ~= nil and launch.launchId == launchId then
    launch.scripted = true
  end
end

---@param self FieldBattleCoordinator
function FieldBattleCoordinator:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  if self.battleRuntime ~= nil then
    self.battleRuntime:dispose()
  end
  self.battleRuntime = nil
  self._battleLaunch = nil
  self._battleReceipt = nil
  self._lastBattleResult = nil
  self.battlePresentation = nil
  self._battlePresentationFactory = nil
  self._battlePresentationBindingId = nil
  self._battlePresentationWithdrawn = false
  self.runtime = nil
end

return FieldBattleCoordinator
