-- Shared journey rig for the pocket-gear acceptance suites: boots the real
-- field runtime over real maps, scripts, and state owners, then drives and
-- settles production flows through semantic input only. Only host audio,
-- host input snapshots, the wall clock, and the save root are recording
-- boundaries; world routes, actors, warps, and saves stay real, and no gear
-- implementation is ever faked. Suites own their scenarios; this rig owns
-- only the driving.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local OpeningLifecycle = require("tests.acceptance.support.OpeningLifecycle")
local FieldApplicationHost = require("libs.hgss.src.field.FieldApplicationHost")
local FieldApplicationIds = require("libs.hgss.src.field.FieldApplicationIds")
local FieldMenuCompositionCoordinator = require("game.hgss.src.field.FieldMenuCompositionCoordinator")
local FieldMovement = require("tests.acceptance.support.FieldMovement")
local FieldState = require("game.hgss.src.field.FieldState")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local LocalClock = require("game.src.LocalClock")

local Fixture = {}

---@param _ unknown
local function void(_)
end

Fixture.TOWN = "MAP_NEW_BARK"
Fixture.HOUSE_1F = "MAP_NEW_BARK_PLAYER_HOUSE_1F"
Fixture.LAB_1F = "MAP_NEW_BARK_ELMS_LAB_1F"
Fixture.POKECENTER = "MAP_GOLDENROD_POKECENTER_1F"
Fixture.TOWER_2F = "MAP_GOLDENROD_RADIO_TOWER_2F"
Fixture.FLOWER_SHOP = "MAP_GOLDENROD_FLOWER_SHOP"

Fixture.TOWN_HOUSE_DOOR_APPROACH = { fieldX = 695, fieldZ = 397 }

Fixture.POKEGEAR_ACTION = "vanilla.pokegear"
Fixture.SAVE_ACTION = "vanilla.save"

Fixture.FLAGS = FieldScriptSymbols.flagsByName
Fixture.VARS = FieldScriptSymbols.variablesByName

-- The proven opening-and-town geography closure: the same maps the
-- field-composition journeys already boot, so no suite invents its own
-- member selection.
Fixture.JOURNEY_ASSETS = {
  "field-runtime",
  "map:33",
  "map:34",
  "map:39",
  "map:60",
  "map:61",
  "map:63",
  "map:67",
  "map:71",
  "map:76",
  "map:112",
  "map:185",
  "map:143",
  "map:184",
  "map:186",
  "map-data:33",
  "map-data:34",
  "map-data:39",
  "map-data:60",
  "map-data:61",
  "map-data:63",
  "map-data:67",
  "map-data:71",
  "map-data:76",
  "map-data:112",
  "map-data:185",
  "map-data:143",
  "map-data:184",
  "map-data:186",
}

---@param moduleName string
---@param missingMessage string
---@return table
function Fixture.requireFeature(moduleName, missingMessage)
  local ok, mod = pcall(require, moduleName)
  if not ok then
    error(missingMessage, 0)
  end
  assert(type(mod) == "table", missingMessage)
  return mod --[[@as table]]
end

---@param map string
---@param fn fun(game: table)
---@param fieldOptions table<string, unknown>?
function Fixture.withGame(map, fn, fieldOptions)
  local options = { recordingScriptHosts = true }
  for key, value in pairs(fieldOptions or {}) do
    options[key] = value
  end
  local game = AcceptanceHarness.new():boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = map,
    save = "fresh",
    fieldOptions = options,
  })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    fn(game)
    Assert.equal(game:renderAttempts(), 0, "gear acceptance must stop before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

-- Boots one game with an overridden player profile and host clock through
-- the harness's own shaped factory. The caller owns the returned game and
-- must close it. Used to vary the first-impression gate without touching
-- production composition.
---@param options { map: string, profile: table<string, unknown>?, clock: table<string, integer>? }
---@return table game
function Fixture.bootVariant(options)
  assert(type(options) == "table" and type(options.map) == "string", "variant boots need their map")
  local profile = options.profile or { name = "GOLD", gender = 0 }
  local sample = options.clock or { year = 2000, month = 1, day = 1, hour = 12, minute = 0, second = 0 }
  local defaultFactory = AcceptanceHarness.new().gameFactory
  local harness = AcceptanceHarness.new({
    gameFactory = function(versionId, map)
      local game = defaultFactory(versionId, map)
      game.playerData.profile.name = profile.name
      game.playerData.profile.gender = profile.gender
      return game
    end,
  })
  local game = harness:boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = options.map,
    save = "fresh",
    fieldOptions = {
      recordingScriptHosts = true,
      localClock = LocalClock.new(function()
        return { year = sample.year, month = sample.month, day = sample.day, hour = sample.hour, minute = sample.minute, second = sample.second }
      end),
    },
  })
  game:waitForFieldEntry()
  return game
end

-- The composed gear owner must exist before any journey leg runs: one
-- concrete composition module, a registered Start Menu destination with a
-- factory, and durable gear state owned by the field runtime.
---@param game table
function Fixture.compositionGates(game)
  local PokegearComposition = Fixture.requireFeature(
    "game.hgss.src.pokegear.PokegearComposition",
    "the field has no composed gear owner yet: runtime, menus, and scripts cannot reach the feature"
  )
  Assert.notNil(PokegearComposition.compose, "the gear composition must publish its explicit construction entrypoint")
  local coordinator = FieldMenuCompositionCoordinator.new(game.runtime)
  local found = false
  for _, descriptor in ipairs(coordinator:applicationDescriptors()) do
    if descriptor.id == FieldApplicationIds.POKEGEAR then
      found = true
      Assert.isTrue(
        type(descriptor.factory) == "function",
        "the gear destination must carry a factory returning a usable screen"
      )
    end
  end
  Assert.isTrue(found, "the field application catalogue must register the gear destination")
  Assert.notNil(game.runtime.pokegearState, "the field runtime must own durable gear state")
end

---@param game table
function Fixture.pressActionEdge(game)
  game.runtime:pressAction()
  game:step()
  game.runtime:releaseAction()
end

-- Settles production dialogue, choices, and foreground scripts with
-- affirmative default answers. Returns false when the field stays owned
-- past the budget instead of failing deep inside a journey leg.
---@param game table
---@param budget integer?
---@return boolean settled
function Fixture.drainField(game, budget)
  for _ = 1, budget or 240 do
    local snapshot = game:snapshot()
    local scheduler = game.runtime.scripts.scheduler
    local foreground = scheduler and scheduler:foregroundEnvironmentId()
    local pokegearHost = game.runtime.pokegear and game.runtime.pokegear.scriptHost
    local blackout = game.runtime.blackoutFlow and game.runtime.blackoutFlow:status()
    if pokegearHost ~= nil and pokegearHost:isActive() then
      Fixture.pressActionEdge(game)
    elseif game.runtime.scripts.dialogueHost:yesNoPresentation() ~= nil then
      Fixture.pressActionEdge(game)
    elseif blackout ~= nil and blackout.waitingInput then
      Fixture.pressActionEdge(game)
    elseif snapshot.dialogue.modal then
      Fixture.pressActionEdge(game)
    elseif foreground ~= nil or snapshot.fieldLocked then
      game:step()
    else
      return true
    end
  end
  return false
end

---@param game table
---@return boolean settled
function Fixture.settleField(game)
  game:waitForFieldEntry()
  return Fixture.drainField(game, 480)
end

-- Settles production scripting to a free field: dialogue and yes-no
-- prompts, scripted menu choices, the naming keyboard, and foreground
-- scripts. Only raw input edges are used. Returns whether the field came
-- free.
---@param game table
---@param budget integer?
---@return boolean settled
function Fixture.settleScripting(game, budget)
  local tick = 0
  for _ = 1, budget or 720 do
    tick = tick + 1
    if game.runtime.errorText then
      error("production scripting faulted: " .. tostring(game.runtime.errorText), 0)
    end
    local naming = game.runtime.pokemonNaming
    local namingActive = naming ~= nil and naming:isActive()
    if game:contextChoiceStatus() ~= nil and not namingActive then
      Fixture.pressActionEdge(game)
    elseif namingActive then
      Fixture.pressActionEdge(game)
      game:move("north")
      for _ = 1, 4 do
        game:move("east")
      end
      Fixture.pressActionEdge(game)
    else
      local snapshot = game:snapshot()
      local scheduler = game.runtime.scripts.scheduler
      local foreground = scheduler and scheduler:foregroundEnvironmentId()
      if game.runtime.scripts.dialogueHost:yesNoPresentation() ~= nil then
        Fixture.pressActionEdge(game)
      elseif snapshot.dialogue.modal then
        Fixture.pressActionEdge(game)
      elseif foreground ~= nil or snapshot.fieldLocked then
        if tick % 3 == 0 then
          Fixture.pressActionEdge(game)
        else
          game:step()
        end
      else
        return true
      end
    end
  end
  return false
end

-- Settles a fresh map entry to completion: entry staging (which places
-- actors) only advances while the harness keeps ticking, so this ticks
-- staging while draining production dialogue and foreground scripts until
-- the stage is gone and the field is free.
---@param game table
---@param label string
function Fixture.settleArrival(game, label)
  for _ = 1, 960 do
    local snapshot = game:snapshot()
    local scheduler = game.runtime.scripts.scheduler
    local foreground = scheduler and scheduler:foregroundEnvironmentId()
    local staged = game.runtime.session.mapEntryStage ~= nil
    if not staged and foreground == nil and not snapshot.fieldLocked and not snapshot.dialogue.modal then
      return
    end
    if game.runtime.scripts.dialogueHost:yesNoPresentation() ~= nil then
      Fixture.pressActionEdge(game)
    elseif snapshot.dialogue.modal then
      Fixture.pressActionEdge(game)
    else
      game:step()
    end
  end
  error("entering " .. label .. " never settled its entry staging and field", 0)
end

---@param game table
---@return integer count
function Fixture.scriptFaults(game)
  local count = 0
  for _, record in ipairs(game:hostEvents().records) do
    if record.name == "script.error" then
      count = count + 1
    end
  end
  return count
end

-- Answers a ringing gear call through field Action input when one is
-- waiting. Returns whether a call was accepted and completed.
---@param game table
---@return boolean accepted
function Fixture.acceptRingingCall(game)
  local calls = game.runtime.incomingCalls
  if calls == nil then
    return false
  end
  local note = calls:notification()
  if not note then
    return false
  end
  local host = assert(game.runtime.pokegear.scriptHost, "the incoming call uses the composed phone host")
  Fixture.pressActionEdge(game)
  Assert.isTrue(host:isActive(), "field Action must acquire the ringing caller")
  Assert.isTrue(Fixture.drainField(game, 480), "an accepted call must complete its dialogue and return the field")
  Assert.isFalse(host:isActive(), "a completed incoming call releases its host handle")
  Assert.isFalse(calls:notification(), "field Action must answer and clear the ring")
  return true
end

-- Walks one production step at a time in `direction`, draining production
-- dialogue and accepting ringing calls after every step.
---@param game table
---@param direction string
---@param opts { stopMapId: integer?, stop: (fun(game: table): boolean)?, budget: integer? }?
---@return string reason
function Fixture.walkSteps(game, direction, opts)
  local options = opts or {}
  local function arrived()
    Fixture.settleArrival(game, assert(game:snapshot().mapSymbol, "walk arrival needs its map symbol"))
    return "map"
  end
  local budget = options.budget or 600
  for _ = 1, budget do
    if options.stopMapId ~= nil and game:snapshot().mapId == options.stopMapId then
      return arrived()
    end
    if options.stop ~= nil and options.stop(game) then
      return "stop"
    end
    local snapshot = game:snapshot()
    if snapshot.dialogue.modal or game.runtime.scripts.scheduler:foregroundEnvironmentId() ~= nil then
      Assert.isTrue(Fixture.drainField(game, 480), "the walk must settle production dialogue before continuing")
    else
      Fixture.acceptRingingCall(game)
      game:move(direction)
      game:advanceUntil("the walk step resolves", function(current)
        return current.player.motion == "idle"
      end, 120)
    end
  end
  if options.stopMapId ~= nil and game:snapshot().mapId == options.stopMapId then
    return arrived()
  end
  if options.stop ~= nil and options.stop(game) then
    return "stop"
  end
  return "budget"
end

-- Faces `actorId` from an adjacent tile and starts its production
-- interaction script. Every candidate tile comes from live actor data and
-- production movement.
---@param game table
---@param actorId string
function Fixture.talkTo(game, actorId)
  for _ = 1, 3 do
    local live = assert(game.runtime.actors:getById(actorId), "the target actor must be live before talking: " .. actorId)
    local committed = live:getFieldPosition()
    local ax = assert(committed.fieldX, "live actors carry their field column: " .. actorId)
    local az = assert(committed.fieldZ, "live actors carry their field row: " .. actorId)
    local candidates = {
      { fieldX = ax, fieldZ = az + 1, facing = "north" },
      { fieldX = ax, fieldZ = az - 1, facing = "south" },
      { fieldX = ax + 1, fieldZ = az, facing = "west" },
      { fieldX = ax - 1, fieldZ = az, facing = "east" },
    }
    for _, tile in ipairs(candidates) do
      local routed = FieldMovement.route(game, tile)
      if routed ~= nil then
        game:moveTo(tile)
        game:face(tile.facing)
        local snapshot = game:pressAction()
        void(snapshot)
        local interaction = game:interaction()
        if interaction.actorId == actorId then
          Assert.isTrue(Fixture.drainField(game, 480), "talking to " .. actorId .. " must settle its script")
          return
        end
        Assert.isTrue(Fixture.drainField(game, 240), "a neighbouring interaction must settle before moving on")
      end
    end
  end
  error("no adjacent tile could face " .. actorId .. " for interaction", 0)
end

-- Enters the door warp leading to `targetSymbol` by trying every live warp
-- on the current map through production movement. A wrong door returns
-- through its own warp before the next attempt.
---@param game table
---@param targetSymbol string
function Fixture.takeWarpTo(game, targetSymbol)
  local origin = assert(game:snapshot().mapSymbol, "warp search needs the current map symbol")
  Fixture.settleArrival(game, origin)
  local warps = assert(game.runtime.runtimeMap.fieldData.events.warps, "warp search needs production warp data on " .. origin)
  local deltas = {
    { dx = 1, dz = 0, direction = "east" },
    { dx = -1, dz = 0, direction = "west" },
    { dx = 0, dz = 1, direction = "south" },
    { dx = 0, dz = -1, direction = "north" },
  }
  local function pressDirection(direction)
    local before = game:snapshot().mapSymbol
    game:move(direction)
    if game:snapshot().transition.phase ~= "idle" then
      game:waitForTransition()
      return game:snapshot().mapSymbol ~= before
    end
    return game:snapshot().mapSymbol ~= before
  end
  local pressOrder = { "south", "north", "west", "east" }
  local function reach(tile)
    local ok = pcall(function()
      game:moveTo(tile)
    end)
    if ok then
      return true
    end
    if game:snapshot().mapSymbol ~= origin then
      return false
    end
    Fixture.drainField(game, 240)
    if game:snapshot().mapSymbol ~= origin then
      return false
    end
    local retry = pcall(function()
      game:moveTo(tile)
    end)
    return retry
  end
  local function stepInto(warp)
    local function onTile()
      local player = game:snapshot().player
      return player.fieldX == warp.fieldX and player.fieldZ == warp.fieldZ
    end
    local function pressAll()
      if not onTile() then
        if not reach({ fieldX = warp.fieldX, fieldZ = warp.fieldZ }) or not onTile() then
          return false
        end
      end
      for _, direction in ipairs(pressOrder) do
        if game:snapshot().mapSymbol ~= origin then
          return true
        end
        if not onTile() then
          local stood = pcall(function()
            game:moveTo({ fieldX = warp.fieldX, fieldZ = warp.fieldZ })
          end)
          if not stood or not onTile() then
            return false
          end
        end
        if game:snapshot().dialogue.modal then
          Assert.isTrue(Fixture.drainField(game, 240), "a warp-side scene must settle before pressing")
        elseif pressDirection(direction) then
          return true
        end
      end
      return game:snapshot().mapSymbol ~= origin
    end
    local function blindTo()
      for _ = 1, 16 do
        if game:snapshot().mapSymbol ~= origin then
          return true
        end
        if onTile() then
          return true
        end
        local snapshot = game:snapshot()
        if snapshot.dialogue.modal or game.runtime.scripts.scheduler:foregroundEnvironmentId() ~= nil then
          Assert.isTrue(Fixture.drainField(game, 480), "the blind walk must settle production dialogue")
        else
          local player = snapshot.player
          if player.fieldX ~= warp.fieldX then
            game:move(player.fieldX < warp.fieldX and "east" or "west")
          elseif player.fieldZ ~= warp.fieldZ then
            game:move(player.fieldZ < warp.fieldZ and "south" or "north")
          else
            return true
          end
          game:advanceUntil("the blind step resolves", function(current)
            return current.player.motion == "idle"
          end, 120)
        end
      end
      return onTile() or game:snapshot().mapSymbol ~= origin
    end
    if pressAll() then
      return true
    end
    if game:snapshot().mapSymbol ~= origin then
      return true
    end
    if blindTo() then
      if game:snapshot().mapSymbol ~= origin then
        return true
      end
      if pressAll() then
        return true
      end
    end
    if game:snapshot().mapSymbol ~= origin then
      return true
    end
    for _, step in ipairs(deltas) do
      if game:snapshot().mapSymbol ~= origin then
        return true
      end
      local neighbor = { fieldX = warp.fieldX - step.dx, fieldZ = warp.fieldZ - step.dz }
      local reached = reach(neighbor)
      if reached and game:snapshot().mapSymbol == origin then
        if game:snapshot().dialogue.modal then
          Assert.isTrue(Fixture.drainField(game, 240), "a warp-side scene must settle before bumping " .. step.direction)
        elseif pressDirection(step.direction) then
          return true
        elseif onTile() then
          if pressAll() then
            return true
          end
        end
      end
    end
    return game:snapshot().mapSymbol ~= origin
  end
  for index = 0, #warps - 1 do
    if game:snapshot().mapSymbol ~= origin then
      break
    end
    local destination = game:warpDestination(index)
    if destination.mapSymbol == targetSymbol and stepInto(destination) then
      local arrived = game:snapshot().mapSymbol
      if arrived == targetSymbol then
        Fixture.settleArrival(game, arrived)
        return
      end
    end
  end
  Assert.equal(game:snapshot().mapSymbol, targetSymbol, "some live door on " .. origin .. " must reach " .. targetSymbol)
end

-- Whether any tile adjacent to `actorId` is reachable through production
-- movement right now, reading the live position on every call.
---@param game table
---@param actorId string
---@return boolean reachable
function Fixture.sweepReachable(game, actorId)
  local live = game.runtime.actors:getById(actorId)
  if live == nil or type(live.getFieldPosition) ~= "function" then
    return false
  end
  local committed = live:getFieldPosition()
  if type(committed) ~= "table" or type(committed.fieldX) ~= "number" then
    return false
  end
  local neighbors = {
    { fieldX = committed.fieldX, fieldZ = committed.fieldZ + 1 },
    { fieldX = committed.fieldX, fieldZ = committed.fieldZ - 1 },
    { fieldX = committed.fieldX + 1, fieldZ = committed.fieldZ },
    { fieldX = committed.fieldX - 1, fieldZ = committed.fieldZ },
  }
  for _, tile in ipairs(neighbors) do
    if FieldMovement.route(game, tile) ~= nil then
      return true
    end
  end
  return false
end

-- Talks to every reachable live object actor on the current map once,
-- draining each production script, until `done` observes the wanted world
-- effect. Actors no adjacent tile can reach are skipped: their scripts are
-- not reachable by ordinary play either.
---@param game table
---@param done fun(game: table): boolean
---@param budget integer?
---@return boolean reached
function Fixture.sweepActors(game, done, budget)
  local seen = 0
  for actorId in pairs(game:snapshot().actors) do
    if done(game) then
      return true
    end
    if actorId:match(":object:%d+$") ~= nil then
      seen = seen + 1
      if budget ~= nil and seen > budget then
        break
      end
      if Fixture.sweepReachable(game, actorId) then
        local ok, err = pcall(Fixture.talkTo, game, actorId)
        if not ok then
          error("actor sweep stalled at " .. actorId .. ": " .. tostring(err), 0)
        end
        Fixture.acceptRingingCall(game)
      end
    end
  end
  return done(game)
end

-- Opens the acquired gear through the production Start Menu and waits
-- until the application owns the tick.
---@param game table
function Fixture.openGearThroughMenu(game)
  for _ = 1, 3 do
    if game.runtime.applicationHost:status().phase == FieldApplicationHost.PHASES.menu then
      break
    end
    game.runtime:pressMenu()
    game:step()
    game.runtime:releaseMenu()
  end
  game:advanceUntil("the start menu becomes modal", function()
    return game.runtime.applicationHost:status().phase == FieldApplicationHost.PHASES.menu
  end, 120)
  local status = game.runtime.applicationHost:status()
  local target = nil
  for _, action in ipairs(assert(status.menu.actions, "the menu must list its actions")) do
    if action.id == Fixture.POKEGEAR_ACTION then
      Assert.isTrue(action.enabled == true, "the acquired gear must stay usable")
      target = action.position
    end
  end
  Assert.notNil(target, "the menu must offer the acquired gear")
  local callbacks = setmetatable({
    runtime = {
      input = game.runtime.input,
      actionKeys = game.runtime.actionKeys,
      cancelKeys = game.runtime.cancelKeys,
      menuKeys = game.runtime.menuKeys,
    },
  }, FieldState)
  for _ = 1, (#status.menu.actions + 1) * 2 do
    local current = game.runtime.applicationHost:status()
    if assert(current.menu, "the menu phase must expose its controller status").selectedPosition == target then
      break
    end
    callbacks:keypressed("s")
    game:step()
    callbacks:keyreleased("s")
  end
  game.runtime.input:pressAction("key:return")
  game:step()
  game.runtime.input:releaseAction("key:return")
  game:advanceUntil("the gear application owns the tick", function()
    return game.runtime.applicationHost:status().phase == FieldApplicationHost.PHASES.application
  end, 240)
end

-- Cancels the open gear back to an owned field.
---@param game table
function Fixture.closeGearThroughMenu(game)
  for _ = 1, 4 do
    if game.runtime.applicationHost:status().phase == FieldApplicationHost.PHASES.closed then
      break
    end
    game.runtime:pressCancel()
    game:step()
    game.runtime:releaseCancel()
  end
  game:advanceUntil("the gear closes back to the field", function(snapshot)
    return game.runtime.applicationHost:status().phase == FieldApplicationHost.PHASES.closed
      and not snapshot.fieldLocked
  end, 240)
end

-- Saves through the production Start Menu Save action and reloads the
-- published record into a fresh runtime over the same namespace. Returns
-- the reloaded game.
---@param game table
---@return table reloaded
function Fixture.saveAndReload(game)
  for _ = 1, 4 do
    if game.runtime.applicationHost:status().phase == FieldApplicationHost.PHASES.menu then
      break
    end
    game.runtime:pressMenu()
    game:step()
    game.runtime:releaseMenu()
  end
  game:advanceUntil("the start menu becomes modal for saving", function()
    return game.runtime.applicationHost:status().phase == FieldApplicationHost.PHASES.menu
  end, 120)
  local status = game.runtime.applicationHost:status()
  local menu = assert(status.menu, "the menu phase must expose its controller status")
  local savePosition = nil
  for _, action in ipairs(assert(status.menu.actions, "the menu must list its actions")) do
    if action.id == Fixture.SAVE_ACTION then
      Assert.isTrue(action.enabled, "the Save action must be enabled at a permitted point")
      savePosition = action.position
    end
  end
  Assert.notNil(savePosition, "the production menu must offer Save at a permitted point")
  local function pressMenuKey(key)
    local callbacks = setmetatable({
      runtime = {
        input = game.runtime.input,
        actionKeys = game.runtime.actionKeys,
        cancelKeys = game.runtime.cancelKeys,
        menuKeys = game.runtime.menuKeys,
      },
    }, FieldState)
    callbacks:keypressed(key)
    game:step()
    callbacks:keyreleased(key)
  end
  local seen = {}
  for _ = 1, (#status.menu.actions + 1) * 6 do
    local current = game.runtime.applicationHost:status()
    Assert.equal(current.phase, FieldApplicationHost.PHASES.menu, "saving must keep the menu modal")
    local selected = assert(current.menu, "the menu phase must expose its controller status").selectedPosition
    if selected == savePosition then
      break
    end
    if seen[selected] then
      seen = {}
      pressMenuKey("d")
    else
      seen[selected] = true
      pressMenuKey("s")
    end
  end
  Assert.equal(
    game.runtime.applicationHost:status().menu.selectedPosition,
    savePosition,
    "the menu must navigate to its Save entry"
  )
  local writesBefore = game.lifecycle.saveWrites
  game.runtime.input:pressAction("key:return")
  game:step()
  game.runtime.input:releaseAction("key:return")
  game:advanceUntil("the save action publishes", function()
    if game.runtime.errorText then
      error("production save faulted: " .. tostring(game.runtime.errorText), 0)
    end
    return game.lifecycle.saveWrites > writesBefore
  end, 240)
  Assert.isTrue(game.lifecycle.saveWrites > 0, "the save action must publish through the save store")
  for _ = 1, 4 do
    if game.runtime.applicationHost:status().phase == FieldApplicationHost.PHASES.closed then
      break
    end
    game.runtime:pressCancel()
    game:step()
    game.runtime:releaseCancel()
  end
  game:advanceUntil("the save menu closes back to the field", function(snapshot)
    return game.runtime.applicationHost:status().phase == FieldApplicationHost.PHASES.closed
      and not snapshot.fieldLocked
  end, 240)
  local saveId = game.runtime.saveId
  local persisted = assert(game.runtime.saveStore:load(saveId), "the actual save store must reload the published record")
  game:_disposeRuntime()
  local runtime = game.harness:_newRuntime(persisted, game.saveNamespace, game.faults, game.lifecycle, game.fieldOptions, false)
  game.runtime = runtime
  game.hosts = runtime.scriptHosts or {}
  game.runtimeDisposed = false
  game.disposeErr = nil
  game.saveStatus = runtime.saveStatus
  game:waitForFieldEntry()
  Assert.isTrue(Fixture.settleField(game), "the reloaded save must settle back to an owned field")
  return game
end

-- Completes the house Mom scene, then Elm's lab welcome, dispatcher
-- conversation, starter pick, and corridor gift through their source
-- scripts. Every effect arrives through its script exactly once; no
-- progression flag is ever seeded and no dialogue is ever replaced.
-- Ends on the played lab frontier with the field owned.
---@param game table
function Fixture.playOpeningToLabFrontier(game)
  local world = assert(game.runtime.scripts and game.runtime.scripts.worldState, "the opening journey needs live world state")
  Assert.isFalse(world:isFlagSet(Fixture.FLAGS.FLAG_GOT_POKEGEAR), "a genuine New Game starts without the gear")
  game:moveTo(Fixture.TOWN_HOUSE_DOOR_APPROACH)
  game:step({ direction = "north" })
  local transition = game:waitForTransition()
  Assert.equal(transition.destination.mapSymbol, Fixture.HOUSE_1F, "the town door must reach the house interior")
  OpeningLifecycle.completeOpeningHouseScene(game)
  for _, flag in ipairs(OpeningLifecycle.MOM_GRANTED_FLAGS) do
    Assert.isTrue(world:isFlagSet(flag), "the Mom scene must grant its early progression flags")
  end
  Assert.isTrue(Fixture.settleField(game), "the Mom scene must release the field")
  Fixture.takeWarpTo(game, Fixture.TOWN)
  Fixture.takeWarpTo(game, Fixture.LAB_1F)
  Assert.isTrue(Fixture.settleField(game), "the lab welcome must settle before Elm is approached")
  game:moveTo({ fieldX = 4, fieldZ = 10 })
  Assert.isTrue(Fixture.settleScripting(game), "the lab welcome scene must conclude and release the field")
  local ELM_SCRIPT = "vanilla.hgss.scr_seq.0843.script_000"
  local elmFound = false
  do
    local actorIds = {}
    for actorId in pairs(game:snapshot().actors) do
      if actorId:match(":object:%d+$") ~= nil then
        actorIds[#actorIds + 1] = actorId
      end
    end
    table.sort(actorIds)
    for _, actorId in ipairs(actorIds) do
      if not elmFound then
        if pcall(Fixture.talkTo, game, actorId) then
          if game:interaction().scriptId == ELM_SCRIPT then
            elmFound = true
          else
            Assert.isTrue(Fixture.drainField(game, 200), "a neighbourly chat must settle before Elm is approached")
          end
        end
      end
    end
  end
  Assert.isTrue(elmFound, "Elm must start his dispatcher script through the real interaction")
  Assert.isTrue(Fixture.settleScripting(game), "Elm's conversation must conclude and release the field")
  local STARTER_SCRIPT = "vanilla.hgss.scr_seq.0843.script_012"
  local triggered = false
  for _, tile in ipairs({
    { fieldX = 8, fieldZ = 5 },
    { fieldX = 7, fieldZ = 4 },
    { fieldX = 9, fieldZ = 4 },
    { fieldX = 8, fieldZ = 3 },
  }) do
    if not triggered then
      local ok = pcall(function()
        game:moveTo(tile)
      end)
      if ok then
        for _, facing in ipairs({ "north", "south", "east", "west" }) do
          if not triggered then
            game:face(facing)
            game:pressAction()
            if game:interaction().scriptId == STARTER_SCRIPT then
              triggered = true
            end
          end
        end
      end
    end
  end
  Assert.isTrue(triggered, "the ball table must start the generated starter script")
  Assert.isTrue(
    Fixture.settleScripting(game) and world:isFlagSet(Fixture.FLAGS.FLAG_GOT_STARTER),
    "choosing the starter through the real lab dialogue must grant the starter"
  )
  Assert.isTrue(Fixture.settleField(game), "the starter scene must release the field")
  game:moveTo({ fieldX = 4, fieldZ = 10 })
  Assert.equal(
    Fixture.walkSteps(game, "south", {
      stop = function()
        return world:getVar(Fixture.VARS.VAR_SCENE_ELMS_LAB) == 2
      end,
      budget = 300,
    }),
    "stop",
    "the corridor gift must conclude before the exit walk"
  )
  Assert.isTrue(Fixture.settleField(game), "the corridor gift must release the field")
end

return Fixture
