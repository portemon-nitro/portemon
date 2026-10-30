-- Production-composed field-move aftermath: Rock Smash (item roll after the
-- encounter check), Headbutt (struck tree table), and Sweet Scent (weather
-- gate, tint, encounter roll) through the real field scheduler, script
-- services, and party-menu admission. The world generator is replaced by a
-- scripted one so every roll is exact; nothing renders. The harness stands in
-- for the field-move presentation by finishing blocking cues and effects each
-- tick. Player-facing note: Chatter eligibility matches FieldMove_CheckChatter,
-- while field use stays unavailable (chatter_recording_deferred) until a
-- voice-recording application owner exists.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FakeAudioOutput = require("tests.acceptance.support.FakeAudioOutput")
local FieldCoordinates = require("libs.hgss.src.field.FieldCoordinates")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local MapCatalog = require("romdump.src.digest.map.MapCatalog")
local PlayTime = require("libs.hgss.src.save.PlayTime")
local PlayerProgression = require("libs.hgss.src.save.PlayerProgression")

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = {
      "field-runtime",
      "map-data:33",
      "map:33",
      "map-data:48",
      "map:48",
      "map-data:34",
      "map:34",
      "map-data:35",
      "map:35",
      "map-data:67",
      "map:67",
      "map-data:73",
      "map:73",
      "map-data:176",
      "map:176",
      "audio-bank:728",
      "message-bank:23",
      "message-bank:40",
      "message-bank:150",
      "audio-bank:152",
      "message-bank:211",
      "audio-bank:702",
      "audio-bank:703",
      "audio-bank:709",
    },
    tags = { "field", "field-move", "acceptance" },
  },
  tests = {},
}

local ROUTE_30 = "MAP_ROUTE_30"
local ROCK_CAVE = "MAP_DARK_CAVE_ROUTE_31_SIDE"
local DIRECTIONS = {
  { facing = "north", dx = 0, dz = 1 },
  { facing = "south", dx = 0, dz = -1 },
  { facing = "west", dx = 1, dz = 0 },
  { facing = "east", dx = -1, dz = 0 },
}

local function withGame(mapSymbol, fn)
  local game = AcceptanceHarness.new({
    gameFactory = function(versionId)
      return {
        saveId = "save-00000001",
        versionId = versionId,
        location = { mapSymbol = mapSymbol, fieldX = 10, fieldZ = 10, facing = "south" },
        playerData = {
          profile = {
            name = "GOLD",
            gender = 0,
            trainerId = 1,
            money = 3000,
            badges = 0,
            nationalDex = false,
            runningShoes = false,
            runningShoesLock = false,
            rivalName = "Silver",
          },
          options = { textSpeed = "fastest", textFrame = 0 },
        },
        fieldTravel = { lastHealSpawn = "SPAWN_NEW_BARK" },
        fashionCase = require("libs.hgss.src.save.FashionCaseState").empty(),
        playTime = PlayTime.new(),
        worldState = FieldEventState.new(),
        mons = require("tests.support.MonBucket").emptyForVersion(versionId),
        bag = require("libs.hgss.src.save.BagSave").empty(),
        mart = require("libs.hgss.src.save.MartSave").empty(),
      }
    end,
  }):boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = mapSymbol,
    save = "fresh",
    fieldOptions = {
      audioHost = "production",
      audioOutput = FakeAudioOutput.new(),
      recordingScriptHosts = true,
    },
  })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    fn(game)
    Assert.equal(game:renderAttempts(), 0, "field-move aftermath acceptance stops before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

-- The party leader knows the move and the badge gate is open.
local function equip(game, move, badge)
  local mons = assert(game.runtime.monService, "live mon service required")
  Assert.isTrue(
    mons:giveMon({ species = "CHIKORITA", level = 5, heldItem = "NONE", form = 0, location = 7 }),
    "setup gift must enter the party"
  )
  mons:setMove(0, 0, move)
  if badge ~= nil then
    PlayerProgression.new(game.runtime.playerData.profile):awardBadge(badge)
  end
end

-- Replaces the world generator with a scripted one: the first values are
-- served in order, then a fixed series keeps wild generation deterministic.
local function scriptDraws(game, values)
  local world = game.runtime.scripts.worldState
  local drawn = 0
  local rng = {}
  function rng:nextRaw()
    drawn = drawn + 1
    return values[drawn] or (drawn * 977) % 65536
  end
  function rng:capture()
    return { state = 1, calls = drawn }
  end
  world.rng = rng
  return function()
    return drawn
  end
end

local function stand(game, fieldX, fieldZ, facing)
  game.runtime.player:setScriptPosition({ fieldX = fieldX, fieldZ = fieldZ })
  game:step()
  game:face(facing)
end

-- Confirms dialogue until the named script ends, failing on a script fault.
-- The harness stands in for the presentation by finishing the field-move cue
-- each tick, so blocking cut-ins/gestures/emotes and polled effects observe
-- the same one-tick completion production reports.
local function pumpCue(game)
  local scheduler = game.runtime.scripts.scheduler
  local cue = scheduler ~= nil and scheduler._services.fieldMoveCue or nil
  if cue ~= nil then
    cue:finishBlockingCue()
    cue:finishEffects()
  end
end

local function runScriptToEnd(game, scriptId, firstEvent)
  for _ = 1, 900 do
    for index = firstEvent + 1, #game:hostEvents().records do
      local event = game:hostEvents().records[index]
      Assert.isTrue(event.name ~= "script.error", scriptId .. " must not fault: " .. tostring(event.payload.message))
      if event.name == "script.ended" and event.payload.scriptId == scriptId then
        return event.payload
      end
    end
    if game.runtime.battleCoordinator:hasBattleWork() then
      return { battle = true }
    end
    if game:snapshot().dialogue.waiting or game:snapshot().dialogue.modal then
      game.runtime:pressAction()
      game:step()
      pumpCue(game)
      game.runtime:releaseAction()
    else
      game:step()
      pumpCue(game)
    end
  end
  error(scriptId .. " did not end", 0)
end

local function smashRock(game)
  for _, event in ipairs(game.runtime.runtimeMap.fieldData.events.objects) do
    if event.scriptId == "common.field_rock_smash" then
      return event
    end
  end
  error("generated cave data has no smash rock", 0)
end

-- An open tile beside any of the target tiles, with the facing toward it.
local function openSide(game, targets)
  local map = game.runtime.runtimeMap
  local function isTarget(fieldX, fieldZ)
    for _, target in ipairs(targets) do
      if target.x == fieldX and target.z == fieldZ then
        return true
      end
    end
    return false
  end
  for _, target in ipairs(targets) do
    for _, side in ipairs(DIRECTIONS) do
      local fieldX, fieldZ = target.x + side.dx, target.z + side.dz
      local localX, localZ = FieldCoordinates.fieldToLocal(map, fieldX, fieldZ)
      if not isTarget(fieldX, fieldZ) and map.collision:containsLocal(localX, localZ) then
        local cell = map.collision:getLocal(localX, localZ)
        if not cell.blocked and cell.behavior ~= 6 then
          return fieldX, fieldZ, side.facing
        end
      end
    end
  end
  error("no open tile beside the target", 0)
end

local function standBeside(game, event)
  local mapId = MapCatalog.require(ROCK_CAVE).id
  local actorId = "map:" .. mapId .. ":object:" .. event.objectEventId
  local actor = assert(game:actor(actorId), "the source rock actor is present")
  local fieldX, fieldZ, facing = openSide(game, { { x = actor.fieldX, z = actor.fieldZ } })
  stand(game, fieldX, fieldZ, facing)
  return actorId
end

local function bagCount(game, item)
  return game.runtime.bagService:quantity(item)
end

function T.tests.rock_smash_field_and_menu_paths_share_the_item_aftermath()
  withGame(ROCK_CAVE, function(game)
    equip(game, "ROCK_SMASH", "zephyr")
    local actorId = standBeside(game, smashRock(game))
    -- The cave's rock smash rate is 50: an opportunity draw of 99 misses, then
    -- odds 50 hit on a draw of 5 and ladder index 0 picks the first item.
    local drawn = scriptDraws(game, { 99, 5, 0 })
    local before = bagCount(game, "MAX_ETHER")
    local events = #game:hostEvents().records
    game:pressAction()
    Assert.equal(game:interaction().scriptId, "common.field_rock_smash")
    runScriptToEnd(game, "common.field_rock_smash", events)
    Assert.equal(drawn(), 3, "one encounter draw, one hit draw, one item draw")
    Assert.equal(bagCount(game, "MAX_ETHER"), before + 1, "the found item reaches the bag through the script")
    local actor = game:actor(actorId)
    Assert.isTrue(actor == nil or actor.visible == false, "the retail script hides the smashed rock")
    Assert.isNil(game.runtime.pendingEncounterId, "a missed encounter check leaves nothing prepared")
    -- The party-menu entry runs the same encounter check and item roll
    -- through the same aftermath service; the field path above left no
    -- battle work behind, so the menu script admits onto an idle scheduler.
    scriptDraws(game, { 99, 5, 0 })
    local menuBefore = bagCount(game, "MAX_ETHER")
    local menuEvents = #game:hostEvents().records
    game.runtime:_admitFieldAction("pokemon.field_move", { move = "rock_smash", slot = 0 })
    runScriptToEnd(game, "common.menu_rock_smash", menuEvents)
    Assert.equal(
      bagCount(game, "MAX_ETHER"),
      menuBefore + 1,
      "the menu path rolls the same item through the same service"
    )
  end)
end

-- The first regular tree tile carrying the headbutt metatile behavior.
local function treeStand(game)
  local map = game.runtime.runtimeMap
  local struck = {}
  local behaviors = {}
  -- An object standing on the tile (a cut tree, for one) answers Action first.
  local occupied = {}
  for _, actor in ipairs(game.runtime.actors:actorsOf(map.mapId)) do
    local at = game.runtime.actors:getPosition(actor.actorId)
    if at ~= nil then
      occupied[at.fieldX .. ":" .. at.fieldZ] = true
    end
  end
  for _, tree in ipairs(map.fieldData.headbutt.regularTrees) do
    for _, coord in ipairs(tree) do
      local localX, localZ = FieldCoordinates.fieldToLocal(map, coord.x, coord.z)
      if map.collision:containsLocal(localX, localZ) then
        local behavior = map.collision:getLocal(localX, localZ).behavior
        behaviors[behavior] = (behaviors[behavior] or 0) + 1
        if behavior == 6 and not occupied[coord.x .. ":" .. coord.z] then
          struck[#struck + 1] = coord
        end
      end
    end
  end
  local summary = {}
  for behavior, count in pairs(behaviors) do
    summary[#summary + 1] = behavior .. "x" .. count
  end
  Assert.isTrue(
    #struck > 0,
    "Route 30 tree coordinates carry the headbutt behavior; found " .. table.concat(summary, ",")
  )
  return openSide(game, { struck[1] })
end

local function headbuttSetup(game)
  equip(game, "HEADBUTT")
  local fieldX, fieldZ, facing = treeStand(game)
  stand(game, fieldX, fieldZ, facing)
  -- The follower would answer Action itself from the facing tile.
  game.runtime.followingMon:recallToPlayer()
  -- Trainer ID 1 selects the rare table for the first tree of 30; slot draw
  -- zero is the first slot.
  return scriptDraws(game, { 0, 0 })
end

local function assertPreparedRareEncounter(game)
  local pending = assert(game.runtime.pendingEncounter, "the struck tree prepares its wild encounter")
  local rare = game.runtime.runtimeMap.fieldData.headbutt.slots.rare[1].species
  Assert.equal(pending.mons[1].mon.species, rare, "the rare table's first slot answers a zero slot draw")
end

function T.tests.headbutt_tree_in_front_runs_the_headbutt_script_and_starts_the_tree_encounter()
  withGame(ROUTE_30, function(game)
    local drawn = headbuttSetup(game)
    local events = #game:hostEvents().records
    game:pressAction()
    local player = game:snapshot().player
    Assert.equal(
      game:interaction().scriptId,
      "common.field_headbutt",
      "A on a headbutt tile runs the retail script; player "
        .. player.fieldX
        .. ","
        .. player.fieldZ
        .. " "
        .. tostring(player.facing)
        .. " kind="
        .. tostring(game:interaction().kind)
        .. " actor="
        .. tostring(game:interaction().actorId)
        .. " script="
        .. tostring(game:interaction().scriptId)
    )
    local ended = runScriptToEnd(game, "common.field_headbutt", events)
    Assert.isTrue(ended.battle == true or ended.completed == true)
    Assert.isTrue(drawn() >= 2, "the slot and level rolls draw")
    assertPreparedRareEncounter(game)
  end)
end

function T.tests.headbutt_from_the_party_menu_runs_the_menu_script()
  withGame(ROUTE_30, function(game)
    headbuttSetup(game)
    local events = #game:hostEvents().records
    game.runtime:_admitFieldAction("pokemon.field_move", { move = "headbutt", slot = 0 })
    runScriptToEnd(game, "common.menu_headbutt", events)
    assertPreparedRareEncounter(game)
  end)
end

-- The first open tile of the active map whose behavior satisfies the test.
local function findTile(game, wanted)
  local map = game.runtime.runtimeMap
  for localZ = 0, 255 do
    for localX = 0, 255 do
      if map.collision:containsLocal(localX, localZ) then
        local cell = map.collision:getLocal(localX, localZ)
        if not cell.blocked and wanted(cell.behavior) then
          return FieldCoordinates.localToField(map, localX, localZ)
        end
      end
    end
  end
  error("the active map has no matching open tile", 0)
end

function T.tests.sweet_scent_without_an_encounter_or_in_rain_fades_without_a_battle()
  withGame(ROUTE_30, function(game)
    equip(game, "SWEET_SCENT")
    -- A tile without encounters fades the tint out and reports nothing;
    -- neither scenario launches a battle, so both share one boot with the
    -- weather override applied last.
    local fieldX, fieldZ = findTile(game, function(behavior)
      return behavior == 0
    end)
    stand(game, fieldX, fieldZ, "south")
    local events = #game:hostEvents().records
    game.runtime:_admitFieldAction("pokemon.field_move", { move = "sweet_scent", slot = 0 })
    local ended = runScriptToEnd(game, "runtime.sweet_scent", events)
    Assert.isTrue(ended.completed, "the scent script ends with the nothing-happened message")
    Assert.isNil(game.runtime.scentTint:presentationOverlay(), "the tint is released at the end")
    Assert.isNil(game.runtime.pendingEncounterId, "a tile without encounters prepares nothing")
    game.runtime:_setLiveWeather(game.runtime.runtimeMap, 1)
    local rainEvents = #game:hostEvents().records
    game.runtime:_admitFieldAction("pokemon.field_move", { move = "sweet_scent", slot = 0 })
    local rainEnded = runScriptToEnd(game, "runtime.sweet_scent", rainEvents)
    Assert.isTrue(rainEnded.completed, "the scent script completes after the faded message")
    Assert.isNil(game.runtime.scentTint:presentationOverlay(), "unsuitable weather never tints the screen")
  end)
end

function T.tests.sweet_scent_on_grass_prepares_an_encounter_and_launches_the_wild_battle()
  withGame(ROUTE_30, function(game)
    equip(game, "SWEET_SCENT")
    local fieldX, fieldZ = findTile(game, function(behavior)
      return behavior == 2
    end)
    stand(game, fieldX, fieldZ, "south")
    local drawn = scriptDraws(game, { 0, 0 })
    local events = #game:hostEvents().records
    game.runtime:_admitFieldAction("pokemon.field_move", { move = "sweet_scent", slot = 0 })
    local ended = runScriptToEnd(game, "runtime.sweet_scent", events)
    Assert.isTrue(ended.battle == true, "the scent launches the prepared wild battle")
    Assert.isTrue(drawn() >= 2, "the scent rolls its slot and level without an opportunity roll")
    Assert.notNil(game.runtime.pendingEncounter or game.runtime.battleCoordinator:hasBattleWork())
  end)
end

return T
