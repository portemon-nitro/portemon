-- Field composition coverage for the pocket gear: single-modal ownership
-- under competing entries, save/reload durability, and honest
-- dependency-bound coverage. Every journey boots the real field runtime
-- over real maps, scripts, and state owners; only host audio, host input
-- snapshots, the wall clock, and the save root are recording boundaries.
-- World routes, actors, and warps are discovered live from production data, never
-- hardcoded beyond the proven opening coordinates. No ROM bytes are read
-- here and no gear implementation is faked.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local OpeningLifecycle = require("tests.acceptance.support.OpeningLifecycle")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local FieldApplicationHost = require("libs.hgss.src.field.FieldApplicationHost")
local FieldApplicationIds = require("libs.hgss.src.field.FieldApplicationIds")
local FieldMenuCompositionCoordinator = require("game.hgss.src.field.FieldMenuCompositionCoordinator")
local FieldMovement = require("tests.acceptance.support.FieldMovement")
local FieldState = require("game.hgss.src.field.FieldState")
local CacheFs = require("libs.storage.src.CacheFs")
local PokegearCache = require("libs.assets.src.PokegearCache")

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = {
      "field-runtime",
      "map:33",
      "map:60",
      "map:61",
      "map:63",
      "map-data:33",
      "map-data:60",
      "map-data:61",
      "map-data:63",
    },
    tags = { "pokegear" },
  },
  tests = {},
}

local function void(_) end

local FLAGS = FieldScriptSymbols.flagsByName
local FLAG_GOT_POKEGEAR = FLAGS.FLAG_GOT_POKEGEAR
local FLAG_GOT_STARTER = FLAGS.FLAG_GOT_STARTER
local FLAG_GOT_RADIO_CARD = FLAGS.FLAG_GOT_RADIO_CARD
local FLAG_GOT_ELMS_PANIC_CALL = FLAGS.FLAG_GOT_ELMS_PANIC_CALL
local VAR_SCENE_ELMS_LAB = FieldScriptSymbols.variablesByName.VAR_SCENE_ELMS_LAB

local function nativeMomKey(game)
  local catalog = assert(game.runtime.pokegearCatalog, "the field runtime owns its compiled phone catalog")
  for _, contact in ipairs(assert(catalog.contacts, "the compiled phone catalog lists contacts")) do
    if contact.id == 0 then
      assert(contact.family == "mother", "native phonebook contact zero is Mom")
      local key = assert(contact.key, "native Mom carries its semantic key")
      return key
    end
  end
  error("the compiled phone catalog contains native contact zero", 0)
end

local TOWN = "MAP_NEW_BARK"
local HOUSE_1F = "MAP_NEW_BARK_PLAYER_HOUSE_1F"
local LAB_1F = "MAP_NEW_BARK_ELMS_LAB_1F"
local TOWN_HOUSE_DOOR_APPROACH = { fieldX = 695, fieldZ = 397 }
local POKEGEAR_ACTION = "vanilla.pokegear"
local SAVE_ACTION = "vanilla.save"

-- Loads a gear module that does not exist yet at this baseline. The
-- failure names the missing behaviour instead of surfacing as a suite
-- load error, so the pre-implementation red stays attributable.
---@param moduleName string
---@param missingMessage string
---@return table
local function requireFeature(moduleName, missingMessage)
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
local function withGame(map, fn, fieldOptions)
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

-- The composed gear owner must exist before any journey leg runs: one
-- concrete composition module, a registered Start Menu destination with a
-- factory, and durable gear state owned by the field runtime.
---@param game table
local function compositionGates(game)
  local PokegearComposition = requireFeature(
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
local function pressActionEdge(game)
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
local function drainField(game, budget)
  for _ = 1, budget or 240 do
    local snapshot = game:snapshot()
    local scheduler = game.runtime.scripts.scheduler
    local foreground = scheduler and scheduler:foregroundEnvironmentId()
    local phoneHost = game.runtime.pokegear and game.runtime.pokegear.scriptHost
    if phoneHost ~= nil and phoneHost:isActive() then
      pressActionEdge(game)
    elseif game.runtime.scripts.dialogueHost:yesNoPresentation() ~= nil then
      pressActionEdge(game)
    elseif snapshot.dialogue.modal then
      pressActionEdge(game)
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
local function settleField(game)
  game:waitForFieldEntry()
  return drainField(game, 480)
end

-- Settles a fresh map entry to completion: entry staging (which places
-- actors) only advances while the harness keeps ticking, and arrival
-- scenes only finish once their actors exist, so this ticks staging while
-- draining production dialogue and foreground scripts until the stage is
-- gone and the field is free. Draining alone is not enough: it returns
-- while the field is briefly free with actors still unplaced, which hangs
-- later scenes on missing persons.
---@param game table
---@param label string
local function settleArrival(game, label)
  for _ = 1, 960 do
    local snapshot = game:snapshot()
    local scheduler = game.runtime.scripts.scheduler
    local foreground = scheduler and scheduler:foregroundEnvironmentId()
    local staged = game.runtime.session.mapEntryStage ~= nil
    if not staged and foreground == nil and not snapshot.fieldLocked and not snapshot.dialogue.modal then
      return
    end
    if game.runtime.scripts.dialogueHost:yesNoPresentation() ~= nil then
      pressActionEdge(game)
    elseif snapshot.dialogue.modal then
      pressActionEdge(game)
    else
      game:step()
    end
  end
  error("entering " .. label .. " never settled its entry staging and field", 0)
end

-- Settles production scripting to a free field: dialogue and yes-no
-- prompts, scripted menu choices, the naming keyboard, and foreground
-- scripts. Menu answers confirm the highlighted entry and naming answers
-- accept a glyph so the name is never empty, then submit through the
-- source OK key. Choice surfaces without a status readout (the starter
-- choice) are fed by a periodic action edge while the field stays locked
-- without modal dialogue. Only raw input edges are used: the resolving
-- press would start a fresh talk instead of feeding the hosts. Returns
-- whether the field came free.
---@param game table
---@param budget integer?
---@return boolean settled
local function settleScripting(game, budget)
  local tick = 0
  for _ = 1, budget or 720 do
    tick = tick + 1
    if game.runtime.errorText then
      error("production scripting faulted: " .. tostring(game.runtime.errorText), 0)
    end
    local naming = game.runtime.monNaming
    local namingActive = naming ~= nil and naming:isActive()
    if game:contextChoiceStatus() ~= nil and not namingActive then
      pressActionEdge(game)
    elseif namingActive then
      pressActionEdge(game)
      game:move("north")
      for _ = 1, 4 do
        game:move("east")
      end
      pressActionEdge(game)
    else
      local snapshot = game:snapshot()
      local scheduler = game.runtime.scripts.scheduler
      local foreground = scheduler and scheduler:foregroundEnvironmentId()
      if game.runtime.scripts.dialogueHost:yesNoPresentation() ~= nil then
        pressActionEdge(game)
      elseif snapshot.dialogue.modal then
        pressActionEdge(game)
      elseif foreground ~= nil or snapshot.fieldLocked then
        if tick % 3 == 0 then
          pressActionEdge(game)
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

-- Answers a ringing gear call through field Action when one is waiting.
-- Returns whether a call was accepted and completed. The
-- acceptance is the end-to-end incoming-call proof: the pending trigger
-- must clear and the field must return to its owner afterwards.
---@param game table
---@return boolean accepted
local function acceptRingingCall(game)
  local calls = game.runtime.incomingCalls
  if calls == nil then
    return false
  end
  local note = calls:notification()
  if not note then
    return false
  end
  local host = assert(game.runtime.pokegear.scriptHost, "incoming calls use the composed field host")
  pressActionEdge(game)
  Assert.isTrue(host:isActive(), "field Action must acquire the ringing call")
  Assert.isTrue(drainField(game, 480), "an accepted call must complete its dialogue and return the field")
  Assert.isFalse(host:isActive(), "completed field Action releases its phone host handle")
  Assert.isFalse(calls:notification(), "field Action must end the ring")
  return true
end

---@param game table
---@return integer count
local function scriptFaults(game)
  local count = 0
  for _, record in ipairs(game:hostEvents().records) do
    if record.name == "script.error" then
      count = count + 1
    end
  end
  return count
end

-- Walks one production step at a time in `direction`, draining production
-- dialogue and accepting ringing calls after every step. Stops when
-- `stop` returns true, the map changes to `stopMapId`, or the budget runs
-- out. A map arrival settles its entry staging before returning, so later
-- legs meet placed actors and a free field.
---@param game table
---@param direction string
---@param opts { stopMapId: integer?, stop: (fun(game: table): boolean)?, budget: integer? }?
---@return string reason
local function walkSteps(game, direction, opts)
  local options = opts or {}
  local function arrived()
    settleArrival(game, assert(game:snapshot().mapSymbol, "walk arrival needs its map symbol"))
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
      Assert.isTrue(drainField(game, 480), "the walk must settle production dialogue before continuing")
    else
      acceptRingingCall(game)
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
-- production movement; a wrong facing never silently presses elsewhere.
---@param game table
---@param actorId string
local function talkTo(game, actorId)
  -- Actors may wander between planning and arrival, so every attempt
  -- re-reads the live position instead of trusting a stale read.
  for _ = 1, 3 do
    local live =
      assert(game.runtime.actors:getById(actorId), "the target actor must be live before talking: " .. actorId)
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
          Assert.isTrue(drainField(game, 480), "talking to " .. actorId .. " must settle its script")
          return
        end
        Assert.isTrue(drainField(game, 240), "a neighbouring interaction must settle before moving on")
      end
    end
  end
  error("no adjacent tile could face " .. actorId .. " for interaction", 0)
end

-- Enters the door warp leading to `targetSymbol` by trying every live warp
-- on the current map through production movement. Interior anchors (entrance
-- and stair tiles) are walkable and fire through the standing direction
-- gate, so the harness stands on the tile and presses each direction
-- through production input; outdoor door tiles are blocked, so the harness
-- bumps them from each routable cardinal neighbor instead. A transition is
-- detected through the live transition phase and settled to completion;
-- arrival entry scripts are drained before the next attempt so a welcoming
-- scene never locks the following route. A wrong door returns through its
-- own warp before the next attempt. Production warp and transition logic
-- are untouched; only the harness driving changed.
---@param game table
---@param targetSymbol string
local function takeWarpTo(game, targetSymbol)
  local origin = assert(game:snapshot().mapSymbol, "warp search needs the current map symbol")
  settleArrival(game, origin)
  local warps =
    assert(game.runtime.runtimeMap.fieldData.events.warps, "warp search needs production warp data on " .. origin)
  local deltas = {
    { dx = 1, dz = 0, direction = "east" },
    { dx = -1, dz = 0, direction = "west" },
    { dx = 0, dz = 1, direction = "south" },
    { dx = 0, dz = -1, direction = "north" },
  }
  -- Presses one production input edge and settles a started transition to
  -- completion. Returns true when the map changed.
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
  -- Reaches `tile` through production movement, retrying once after
  -- draining: a coordinate scene (an item gift, a greeting) may own the
  -- field mid-route on the first attempt and release it for the second.
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
    drainField(game, 240)
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
    -- Presses every gate direction from the anchor tile, re-standing
    -- first whenever a wrong direction stepped off. Returns true when
    -- the map changed.
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
          Assert.isTrue(drainField(game, 240), "a warp-side scene must settle before pressing")
        elseif pressDirection(direction) then
          return true
        end
      end
      return game:snapshot().mapSymbol ~= origin
    end
    -- Walkable anchor first: stand on the tile, then press its gates.
    if pressAll() then
      return true
    end
    if game:snapshot().mapSymbol ~= origin then
      return true
    end
    -- Blind-step fallback for anchors beyond a logical-zone seam the
    -- planner refuses to cross: axis-aligned real steps toward the tile,
    -- draining production scenes along the way, then the gate presses.
    -- Bounded so furniture never traps the search.
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
          Assert.isTrue(drainField(game, 480), "the blind walk must settle production dialogue")
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
    -- Blocked anchor, or a walkable one no route reaches directly:
    -- approach from each routable neighbor. Bumping a walkable anchor
    -- steps onto it, which then owns the gate presses.
    for _, step in ipairs(deltas) do
      if game:snapshot().mapSymbol ~= origin then
        return true
      end
      local neighbor = { fieldX = warp.fieldX - step.dx, fieldZ = warp.fieldZ - step.dz }
      local reached = reach(neighbor)
      if reached and game:snapshot().mapSymbol == origin then
        if game:snapshot().dialogue.modal then
          Assert.isTrue(drainField(game, 240), "a warp-side scene must settle before bumping " .. step.direction)
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
    if stepInto(destination) then
      local arrived = game:snapshot().mapSymbol
      if arrived == targetSymbol then
        settleArrival(game, arrived)
        return
      end
      if arrived ~= origin then
        local back = game.runtime.runtimeMap.fieldData.events.warps
        assert(back ~= nil, "the arrival map must publish its return warps")
        local returned = false
        for inner = 0, #back - 1 do
          if game:snapshot().mapSymbol == origin then
            returned = true
            break
          end
          if game:snapshot().mapSymbol ~= arrived then
            break
          end
          local dest = game:warpDestination(inner)
          if stepInto(dest) and game:snapshot().mapSymbol == origin then
            returned = true
            break
          end
        end
        Assert.isTrue(returned, "a wrong door on " .. origin .. " must lead back before the next attempt")
        settleArrival(game, origin)
      end
    end
  end
  Assert.equal(
    game:snapshot().mapSymbol,
    targetSymbol,
    "some live door on " .. origin .. " must reach " .. targetSymbol
  )
end

-- Talks to every reachable live object actor on the current map once,
-- draining each production script, until `done` observes the wanted world
-- effect. Actors no adjacent tile can reach (behind desks, behind counters)
-- are skipped, never asserted through: their scripts are not reachable by
-- ordinary play either.
---@param game table
---@param done fun(game: table): boolean
---@param budget integer?
---@return boolean reached
local sweepReachable ---@type fun(game: table, actorId: string): boolean
local function sweepActors(game, done, budget)
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
      if sweepReachable(game, actorId) then
        local ok, err = pcall(talkTo, game, actorId)
        if not ok then
          error("actor sweep stalled at " .. actorId .. ": " .. tostring(err), 0)
        end
        acceptRingingCall(game)
      end
    end
  end
  return done(game)
end

-- Whether any tile adjacent to `actorId` is reachable through production
-- movement right now. Actors decide their own wander, so the check reads
-- the live position on every call.
---@param game table
---@param actorId string
---@return boolean reachable
sweepReachable = function(game, actorId)
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

-- Opens the acquired gear through the production Start Menu and waits
-- until the application owns the tick. The first edge after an
-- application close can fall on the map resume tick, so the press
-- repeats until the menu owns the tick.
---@param game table
local function openGearThroughMenu(game)
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
    if action.id == POKEGEAR_ACTION then
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

-- Cancels the open gear back to an owned field. The shell takes two
-- cancels (the first returns focus, the second closes back to the
-- retained menu) and the menu takes one more, so edges repeat until the
-- field owns the tick again.
---@param game table
local function closeGearThroughMenu(game)
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
-- published record into a fresh runtime over the same namespace, following
-- the established field-save roundtrip shape. Returns the reloaded game.
---@param game table
---@return table reloaded
local function saveAndReload(game)
  -- The first menu edge after an application close can fall on the map
  -- resume tick, so the press repeats until the menu owns the tick.
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
    if action.id == SAVE_ACTION then
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
  -- The menu is a two-dimensional focus graph: down alone cycles the
  -- left column forever, so any revisited entry sidesteps right once
  -- before continuing down. The loop still ends on the Save entry, and
  -- a missed arrival fails loudly instead of confirming elsewhere.
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
  -- Confirming Save publishes synchronously and returns to the field:
  -- the helper waits for the publication itself before reloading. A
  -- faulting save surfaces its production error instead of timing out.
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
  local persisted =
    assert(game.runtime.saveStore:load(saveId), "the actual save store must reload the published record")
  game:_disposeRuntime()
  local runtime =
    game.harness:_newRuntime(persisted, game.saveNamespace, game.faults, game.lifecycle, game.fieldOptions, false)
  game.runtime = runtime
  game.hosts = runtime.scriptHosts or {}
  game.runtimeDisposed = false
  game.disposeErr = nil
  game.saveStatus = runtime.saveStatus
  game:waitForFieldEntry()
  Assert.isTrue(settleField(game), "the reloaded save must settle back to an owned field")
  return game
end

function T.tests.competing_field_entries_keep_a_single_modal_owner()
  withGame(TOWN, function(game)
    compositionGates(game)
    -- Ownership setup only: the acquired flag lets the menu route open.
    -- No journey is claimed here; progression truth lives with the
    -- opening scenario.
    game:setWorldState({ flag = FLAG_GOT_POKEGEAR })
    local playerBefore = game:snapshot().player

    local function hostPhase()
      return game.runtime.applicationHost:status().phase
    end
    local function openGear()
      openGearThroughMenu(game)
    end
    local function closeGear()
      closeGearThroughMenu(game)
    end

    -- The normal entry owns the tick alone: the session never double-steps
    -- the player underneath the open screen.
    openGear()
    for _ = 1, 30 do
      game:step()
    end
    local playerDuring = game:snapshot().player
    Assert.equal(playerDuring.fieldX, playerBefore.fieldX, "the open gear must not drift the player column")
    Assert.equal(playerDuring.fieldZ, playerBefore.fieldZ, "the open gear must not drift the player row")
    Assert.isNil(
      game.runtime.scripts.scheduler:foregroundEnvironmentId(),
      "the normal gear must not share its tick with a foreground script"
    )

    -- A menu press while the gear owns the tick never steals ownership or
    -- opens a second modal.
    game.runtime:pressMenu()
    game:step()
    game.runtime:releaseMenu()
    for _ = 1, 10 do
      game:step()
    end
    Assert.equal(
      hostPhase(),
      FieldApplicationHost.PHASES.application,
      "a competing menu press must not dethrone the open gear"
    )

    -- Action input while the gear owns the tick never starts field
    -- dialogue or a second application behind it.
    game:pressAction()
    Assert.isTrue(drainField(game, 120), "field input during the gear must settle without a second owner")
    Assert.equal(hostPhase(), FieldApplicationHost.PHASES.application, "field dialogue must not open under the gear")

    -- Cancel closes exactly once: the field resumes and committed state
    -- survives the round trip.
    closeGear()

    -- Reopen proves no leaked capture: the second open owns the tick the
    -- same way and closes cleanly again.
    openGear()
    Assert.equal(
      hostPhase(),
      FieldApplicationHost.PHASES.application,
      "the reopened gear must own the tick exactly once"
    )
    closeGear()
    Assert.equal(scriptFaults(game), 0, "competing entries must not fault any script")

    -- Real travel preserves the single owner too: walking to Route 29
    -- crosses a production seam without starting a second modal, and the
    -- field stays settled afterwards. The walk starts from the clear
    -- west corridor; the rows by the house are walled.
    game:moveTo({ fieldX = 676, fieldZ = 396 })
    Assert.equal(
      walkSteps(game, "west", { stopMapId = 33, budget = 900 }),
      "map",
      "the ownership walk must reach Route 29 on foot"
    )
    acceptRingingCall(game)
    Assert.isTrue(settleField(game), "the travelled field must settle under one owner")
    Assert.equal(scriptFaults(game), 0, "travel must not fault any script")

    -- Fly without its source move is refused through the production lane,
    -- never a silent warp: the field stays exactly where it is. Travel
    -- with a computed permitted set needs the source move and stays a
    -- recorded handoff until that seam exists.
    local mapBeforeFly = game:snapshot().mapSymbol
    local playerBeforeFly = game:snapshot().player
    Assert.isTrue(settleField(game), "the field must be idle before the Fly refusal probe")
    Assert.equal(game:snapshot().mapSymbol, mapBeforeFly, "the refusal probe must not warp")
    Assert.equal(game:snapshot().player.fieldX, playerBeforeFly.fieldX, "the refusal probe must not move the player")
    Assert.isTrue(settleField(game), "the journey must end back on an owned field")
  end)
end

-- Save reload is durable but never a live-UI snapshot: registered and
-- reordered contacts, staged gifts, markings, skins, tuning, and a pending
-- durable trigger all survive verbatim, while an active call or staged
-- reward refuses capture without corrupting the prior save and nothing
-- dead resurrects afterwards.
function T.tests.gear_save_reload_keeps_facts_without_resurrecting_calls()
  withGame(TOWN, function(game)
    compositionGates(game)
    -- Durability setup through the real durable owner and the real
    -- compiled catalog keys. The setup path is the production mutator
    -- set, not the journey scripts; journeys own the opening scenario.
    -- Saving needs a permitted point, which a fresh boot is not: the
    -- played house scene below only unlocks the production Save route
    -- and registers nobody, so every durable fact still comes from the
    -- mutators that follow.
    game:moveTo(TOWN_HOUSE_DOOR_APPROACH)
    game:step({ direction = "north" })
    local houseTransition = game:waitForTransition()
    Assert.equal(houseTransition.destination.mapSymbol, HOUSE_1F, "durability plays the real house scene")
    OpeningLifecycle.completeOpeningHouseScene(game)
    Assert.isTrue(settleField(game), "the house scene must release the field")
    takeWarpTo(game, TOWN)
    game:setWorldState({ flag = FLAG_GOT_POKEGEAR })
    local gearState = assert(game.runtime.pokegearState, "durability needs live gear state")
    local manifest = PokegearCache.loadManifest(CacheFs.forVersion(AcceptanceHarness.defaultVersion()))
    local catalog = assert(manifest.catalog, "durability setup needs the real contact catalog")
    local contacts = assert(catalog.contacts, "the catalog must carry its contacts")
    Assert.isTrue(#contacts >= 2, "reordering needs at least two native contacts")
    local firstKey = assert(contacts[1].key, "native contacts carry semantic keys")
    local secondKey = assert(contacts[2].key, "native contacts carry semantic keys")
    Assert.isTrue(type(firstKey) == "string" and type(secondKey) == "string", "contact keys stay semantic")
    local regionMap = assert(catalog.regionMap, "the catalog must carry its region map")
    Assert.isTrue(#regionMap.locations >= 1, "markings need at least one native location")
    local locationKey = assert(regionMap.locations[1].mapSymbol, "native locations carry their map symbol")
    local triggers = assert(catalog.callTriggers, "the catalog must carry its call triggers")
    Assert.isTrue(#triggers >= 1, "a pending trigger needs a native trigger record")
    local triggerKey = assert(triggers[1].key, "native triggers carry their key")
    Assert.isTrue(type(triggerKey) == "string", "trigger keys stay semantic")

    gearState:registerContact(firstKey)
    gearState:registerContact(secondKey)
    gearState:setContactOrder({ secondKey, firstKey })
    gearState:setContactReward(firstKey, { item = "POTION", quantity = 1 })
    gearState:setMarking(locationKey, {
      icons = { 1, false, false, false },
      words = { false, false, false, false },
    })
    gearState:setPreference("skin", 2)
    gearState:setPreference("mapZoomed", true)
    gearState:setPreference("radioCursor", { x = 4, y = 0 })
    gearState:setPreference("lastApp", "phone")
    gearState:setTrigger(triggerKey, true)
    local revisionBeforeSave = gearState:revision()
    Assert.isTrue(revisionBeforeSave > 0, "durability setup must commit through the real owner")

    -- The stable save roundtrips every durable fact verbatim.
    saveAndReload(game)
    gearState = assert(game.runtime.pokegearState, "the reloaded game needs live gear state")
    local phone = gearState:readPhone()
    Assert.deepEqual(phone.contactOrder, { secondKey, firstKey }, "reload must retain the manual contact order")
    Assert.deepEqual(phone.triggers, { [triggerKey] = true }, "reload must retain the pending durable trigger")
    local preferences = gearState:readPreferences()
    Assert.equal(preferences.skin, 2, "reload must retain the chosen skin")
    Assert.isTrue(preferences.mapZoomed, "reload must retain the map zoom")
    Assert.deepEqual(preferences.radioCursor, { x = 4, y = 0 }, "reload must retain tuner position")
    Assert.equal(preferences.lastApp, "phone", "reload must retain the remembered application")
    local captured = gearState:capture()
    local savedCards = assert(captured.registeredCards, "the persisted bucket must carry its card set")
    Assert.isTrue(savedCards.phone == true, "reload must retain the base companion card")
    local savedMarkings = assert(captured.markings, "the persisted bucket must carry its markings")
    Assert.notNil(savedMarkings[locationKey], "reload must retain the placed marking")

    -- No live call or audio resurrects: the field is idle and silent.
    Assert.isTrue(settleField(game), "the reloaded game must settle to an idle field")
    local calls = game.runtime.incomingCalls
    if calls ~= nil then
      Assert.isFalse(calls:notification(), "reload must not resurrect a ringing call")
    end

    -- An open gear refuses capture without touching the prior save: the
    -- modal screen blocks the snapshot, closing resumes it, and the
    -- committed facts above still reload afterwards.
    openGearThroughMenu(game)
    Assert.isNil(game.runtime:captureGameSave(), "an open gear must refuse save capture while it owns the tick")
    closeGearThroughMenu(game)
    Assert.notNil(game.runtime:captureGameSave(), "closing the gear must resume save capture")
    saveAndReload(game)
    gearState = assert(game.runtime.pokegearState, "the second reload needs live gear state")
    Assert.deepEqual(
      gearState:readPhone().contactOrder,
      { secondKey, firstKey },
      "the refusal must not corrupt the prior durable facts"
    )
    Assert.isTrue(settleField(game), "durability must end back on an owned field")
  end)
end

-- Dependency-bound coverage stays honest: every native contact and show
-- resolves through its real policy, only contacts registered through
-- played scripts count as end-to-end (the reachable frontier certifies
-- none), Day-Care and Kurt contacts stay explicitly excluded with exact
-- partition sums, and missing Day Care, Kurt, and Safari facts fail with
-- attribution before any mutation, never as fabricated replies or
-- success flags.
function T.tests.dependency_bound_contacts_and_shows_stay_honest()
  withGame(TOWN, function(game)
    compositionGates(game)
    local PhoneCall = requireFeature(
      "game.hgss.src.pokegear.PhoneCall",
      "contact coverage has no conversation policy yet: no caller can resolve its source program"
    )
    local PhoneWorldContext = requireFeature(
      "game.hgss.src.pokegear.PhoneWorldContext",
      "contact coverage has no shared world projection yet: dependency reads cannot attribute their owner"
    )
    local manifest = PokegearCache.loadManifest(CacheFs.forVersion(AcceptanceHarness.defaultVersion()))
    local catalog = assert(manifest.catalog, "coverage needs the real compiled catalog")
    local nativeContacts = assert(catalog.contacts, "the catalog must carry its native contacts")
    Assert.isTrue(#nativeContacts > 0, "the compiled phonebook must carry native contacts")
    local order = assert(catalog.contactOrder, "the catalog must cover every caller with its order")
    Assert.isTrue(#order > 0, "the contact order must cover native callers")
    local seen = {}
    for _, contact in ipairs(nativeContacts) do
      Assert.notNil(contact.key, "every native contact carries a semantic key")
      Assert.isNil(seen[contact.key], "native contact keys never repeat")
      seen[contact.key] = true
    end
    local ordered = {}
    for _, key in ipairs(order) do
      Assert.isTrue(seen[key] == true, "every ordered contact is a compiled native caller")
      Assert.isNil(ordered[key], "native contacts appear once in the compiled order")
      ordered[key] = true
    end
    for key in pairs(seen) do
      Assert.isTrue(ordered[key] == true, "the compiled order includes every native contact")
    end
    local shows = assert(catalog.shows, "the catalog must carry its broadcast programs")
    Assert.isTrue(#shows > 0, "the compiled family must carry broadcast programs")

    -- Every native caller resolves through the real policy; an unknown
    -- family is an attributed failure, never a default conversation.
    Assert.notNil(PhoneCall.selectProgram, "the policy must publish its program selection")
    local selectionFailure = nil
    local ok = pcall(function()
      PhoneCall.selectProgram("no-such-family", {})
    end)
    if ok then
      selectionFailure = "an unknown caller family selected a program instead of failing"
    end
    Assert.isNil(selectionFailure, "unknown caller families must never resolve to a fabricated program")

    -- Only contacts registered through played scripts count as
    -- end-to-end, and the journey stops at the Elm-registration leg: this
    -- run plays the house scene (whose scripts carry no registration site,
    -- so the played set is honestly empty) and walks the town exit, whose
    -- scene gates on the unplayed starter path and never runs. The Elm
    -- registration itself sits past the sealed lab door proved by the
    -- opening play, so it is marked blocked here instead of certified.
    game:moveTo(TOWN_HOUSE_DOOR_APPROACH)
    game:step({ direction = "north" })
    local houseTransition = game:waitForTransition()
    Assert.equal(houseTransition.destination.mapSymbol, HOUSE_1F, "coverage plays the real house scene")
    OpeningLifecycle.completeOpeningHouseScene(game)
    Assert.isTrue(settleField(game), "the house scene must release the field")
    takeWarpTo(game, TOWN)
    local worldState =
      assert(game.runtime.scripts and game.runtime.scripts.worldState, "coverage needs live world state")
    local gearState = assert(game.runtime.pokegearState, "coverage needs live gear state")
    Assert.equal(
      walkSteps(game, "west", {
        stop = function()
          return #gearState:readPhone().contactOrder > 1
        end,
        budget = 900,
      }),
      "budget",
      "the town-exit scene must stay silent without its starter-path story"
    )
    Assert.isTrue(settleField(game), "the silent walk must release the field")
    -- The Elm-registration leg is marked blocked: no caller registered,
    -- the gear flag never set, and no script faulted along the way. The
    -- registration's town-exit script needs the starter path, which the
    -- opening play proves dead-ends at the occupied lab door.
    Assert.deepEqual(
      gearState:readPhone().contactOrder,
      { nativeMomKey(game) },
      "Elm registration waits past the sealed lab door while native Mom remains registered"
    )
    Assert.isFalse(worldState:isFlagSet(FLAG_GOT_POKEGEAR), "the gear handoff waits past the sealed lab door")
    -- The universe partition at the reachable frontier: the bootstrapped
    -- Mom contact, the played set (empty -- the house scene registers
    -- nobody), the excluded dependency-bound contacts, and every other
    -- native contact policy-only. The sums hold exactly; no contact is reclassified to
    -- hide the frontier. The exclusions below are registered only inside
    -- their absent-subsystem maps: the Day-Care couple registers in the
    -- Route-34 Day-Care lobby, and Kurt registers in Kurt's house. No
    -- Safari script anywhere in the corpus registers a number, so Safari
    -- stays a domain-case exclusion below rather than a contact key.
    local excluded = {
      ["hg.trainer.202.map.0.contact.3"] = true,
      ["hg.trainer.202.map.0.contact.4"] = true,
      ["hg.trainer.203.map.0.contact.5"] = true,
    }
    for key in pairs(excluded) do
      Assert.isTrue(seen[key] == true, "every excluded contact is a compiled native caller: " .. key)
    end
    local playedOrder = gearState:readPhone().contactOrder
    local bootstrappedMomKey = nativeMomKey(game)
    local endToEnd = {}
    for _, key in ipairs(playedOrder) do
      if key ~= bootstrappedMomKey then
        endToEnd[key] = true
      end
    end
    local endToEndCount = 0
    local bootstrappedCount = 0
    local excludedCount = 0
    local policyOnlyCount = 0
    for _, contact in ipairs(nativeContacts) do
      if contact.key == bootstrappedMomKey then
        bootstrappedCount = bootstrappedCount + 1
      elseif endToEnd[contact.key] then
        Assert.isNil(excluded[contact.key], "a played contact is never excluded: " .. contact.key)
        endToEndCount = endToEndCount + 1
      elseif excluded[contact.key] then
        excludedCount = excludedCount + 1
      else
        policyOnlyCount = policyOnlyCount + 1
      end
    end
    Assert.equal(endToEndCount, 0, "the frontier certifies no contact end-to-end: the house scene registers nobody")
    Assert.equal(bootstrappedCount, 1, "the default Mom contact is accounted for once")
    Assert.equal(excludedCount, 3, "the exclusion set holds exactly its Day-Care pair and Kurt")
    Assert.equal(policyOnlyCount, 71, "every remaining native contact stays policy-only, never certified")
    Assert.equal(
      bootstrappedCount + endToEndCount + excludedCount + policyOnlyCount,
      75,
      "the coverage table must account for every native contact exactly once"
    )

    -- Missing larger-world facts fail with attribution before any state
    -- change: no fabricated egg, box-full, dex-threshold, safari, or
    -- production reply may ever appear.
    local revisionBefore = gearState:revision()
    local triggersBefore = gearState:readPhone().triggers
    local world = PhoneWorldContext.new({ state = gearState, flags = {} })
    for _, key in ipairs({ "daycare.egg", "safari.test", "kurt.production" }) do
      local failure = Assert.throws(function()
        world:read(key)
      end, "absent " .. key .. " must fail instead of fabricating a call")
      local domain = key:match("^([^.]+)%.")
      Assert.equal((failure --[[@as table]]).domain, domain, "the absent read must attribute " .. domain)
    end
    Assert.equal(gearState:revision(), revisionBefore, "failed dependency reads must not mutate gear state")
    Assert.deepEqual(gearState:readPhone().triggers, triggersBefore, "failed dependency reads must raise no trigger")
    Assert.equal(scriptFaults(game), 0, "coverage must run without script faults")
  end)
end

return T
