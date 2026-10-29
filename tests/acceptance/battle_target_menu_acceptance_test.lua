-- Target-menu journey through the production battle runtime and screen
-- constructors. The acceptance harness supplies the live field owners and
-- real prepared cache; headless adapters stop before graphics rendering.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local BattlePresentationCache = require("libs.assets.src.battle.BattlePresentationCache")
local CacheFs = require("libs.storage.src.CacheFs")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local PlayTime = require("libs.hgss.src.save.PlayTime")
local ScreenTopology = require("libs.ui.src.ScreenTopology")
local SourceTick = require("libs.hgss.src.field.SourceTick")

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    tags = { "battle", "target-menu", "journey" },
  },
  tests = {},
}

local MAP = "MAP_NEW_BARK_ELMS_LAB_1F"
local TICK = SourceTick.DT

local function harness()
  return AcceptanceHarness.new({
    gameFactory = function(versionId, map)
      return {
        saveId = "save-00000001",
        versionId = versionId,
        location = { mapSymbol = map or MAP, fieldX = 4, fieldZ = 13, facing = "north" },
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
        mons = require("tests.support.MonBucket").emptyForVersion(versionId, 7),
        bag = require("libs.hgss.src.save.BagSave").empty(),
        mart = require("libs.hgss.src.save.MartSave").empty(),
      }
    end,
  })
end

local function measurement()
  return {
    width = 256,
    height = 384,
    topology = ScreenTopology.dualDisplay(
      { id = "main", rect = { x = 0, y = 0, width = 256, height = 192 }, touch = false, role = "world" },
      { id = "lower", rect = { x = 0, y = 192, width = 256, height = 192 }, touch = true, role = "auxiliary" },
      "battle-target-menu-acceptance"
    ),
    pixelRatio = 1,
    signature = "battle-target-menu-acceptance",
  }
end

local function drawable(key)
  return {
    key = key,
    getWidth = function()
      return 256
    end,
    getHeight = function()
      return 192
    end,
    getDimensions = function()
      return 256, 192
    end,
    setFilter = function() end,
  }
end

local function presentationServices()
  local images = {}
  return {
    assets = {
      prepare = function()
        return true
      end,
      drawable = function(key)
        images[key] = images[key] or drawable(key)
        return images[key]
      end,
      release = function() end,
    },
    text = {
      measure = function(text)
        return { width = #tostring(text) * 8, height = 16 }
      end,
      drawText = function() end,
      drawTextForRole = function() end,
      measureForRole = function(_, text)
        return { width = #tostring(text) * 8, height = 16 }
      end,
    },
    windows = { drawWindow = function() end },
    audio = { play = function() return true end, stop = function() return true end },
  }
end

local function foeRecord(catalog, species, seed, name)
  local Fixture = require("libs.mons.tests.catalog_fixture")
  local record = Fixture.makeFactory(seed, catalog):createNormal(Fixture.normalRequest({ species = species, level = 8 }))
  record.nickname = name
  record.moves = { { move = "TACKLE", pp = 35, ppUps = 0 } }
  return record
end

local function pumpTo(screen, battle, predicate, label)
  for _ = 1, 1800 do
    local before = screen:status()
    if before.mode == "intro" or before.mode == "narration" then
      screen:input({ { type = "confirm" } })
    end
    battle:update()
    screen:updateFixed(TICK)
    if predicate() then
      return
    end
    local status = screen:status()
    Assert.isFalse(status.mode == "failed", label .. " screen failed: " .. tostring(status.error))
  end
  local status = screen:status()
  error(
    "battle target journey did not reach "
      .. label
      .. "; screen="
      .. tostring(status.mode)
      .. "; error="
      .. tostring(status.error)
      .. "; battle="
      .. tostring(battle:status().phase)
      .. "; battleError="
      .. tostring(battle:status().error)
      .. "; request="
      .. tostring(battle:status().request ~= nil),
    0
  )
end

local function openTargetJourney()
  local versionId = AcceptanceHarness.defaultVersion()
  local game = harness():boot({ versionId = versionId, map = MAP, save = "fresh" })
  game:waitForFieldEntry()

  local party = game.runtime.monService
  Assert.isTrue(party:giveMon({ species = "CHIKORITA", level = 8, heldItem = "NONE", form = 0 }), "the lead joins the live party")
  Assert.isTrue(party:giveMon({ species = "CYNDAQUIL", level = 8, heldItem = "NONE", form = 0 }), "the partner joins the live party")
  party:setMove(0, 0, "TACKLE")
  party:setMove(1, 0, "TACKLE")

  local BattleRuntime = require("game.hgss.src.battle.BattleRuntime")
  local BattleScreenState = require("game.hgss.src.battle.BattleScreenState")
  local Model = require("game.hgss.src.battle.BattlePresentationModel")
  local ScenarioFactory = require("libs.hgss.src.battle.HgssBattleScenarioFactory")
  local catalog = party:catalog()
  local presentation = presentationServices()
  local manifest = assert(
    BattlePresentationCache.load(CacheFs.forVersion(versionId)),
    "the ready version carries the real staged battle presentation manifest"
  )
  Assert.isTrue(manifest.verified == true, "the target journey reads verified staged presentation data")

  local launchId = "acceptance-target-menu-" .. versionId
  local scenario = ScenarioFactory.fromTrainer({
    id = launchId,
    trainers = {
      {
        id = "target-left",
        class = 2,
        name = "LEFT",
        party = {
          foeRecord(catalog, "TOTODILE", 0xD050001, "LEFT"),
          foeRecord(catalog, "CHIKORITA", 0xD050003, "HIDDEN LEFT"),
        },
        aiPasses = {},
      },
      {
        id = "target-right",
        class = 2,
        name = "RIGHT",
        party = {
          foeRecord(catalog, "EEVEE", 0xD050002, "RIGHT"),
          foeRecord(catalog, "CYNDAQUIL", 0xD050004, "HIDDEN RIGHT"),
        },
        aiPasses = {},
      },
    },
  }, {
    party = party,
    bag = game.runtime.bagService,
    player = {
      trainerId = 99,
      trainerName = "MINT",
      trainerClassKey = "PKMN_TRAINER_ETHAN",
      language = "english",
    },
  })

  local holder = {}
  local screen = BattleScreenState.new({
    launchId = launchId,
    manifest = manifest,
    model = Model,
    submit = function(reply)
      holder.replies[#holder.replies + 1] = reply
      return holder.battle:submit(reply)
    end,
    measureDisplay = measurement,
    assets = presentation.assets,
    text = presentation.text,
    windows = presentation.windows,
    audio = presentation.audio,
    monCatalog = catalog,
    monIconProvider = {
      frame = function(_, _key, _animation, _frameIndex)
        return drawable("target-icon")
      end,
    },
  })
  holder.replies = {}
  holder.screen = screen
  holder.battle = BattleRuntime.new({
    request = { id = launchId, kind = "trainer", payload = { trainer = "target-menu" } },
    scenario = scenario,
    presentation = screen:presentationPort(),
    party = party,
    bag = game.runtime.bagService,
  })

  pumpTo(screen, holder.battle, function()
    return screen:status().mode == "command" and screen:view().menuInputEnabled == true
  end, "command menu")
  screen:input({ { type = "confirm" } })
  pumpTo(screen, holder.battle, function()
    return screen:status().mode == "moves" and screen:view().menuInputEnabled == true
  end, "move menu")
  screen:input({ { type = "confirm" } })
  pumpTo(screen, holder.battle, function()
    return screen:status().mode == "target"
  end, "target menu")
  return game, screen, holder.battle, holder.replies
end

local function closeJourney(game, screen, battle)
  screen:dispose()
  battle:dispose()
  game:close()
  Assert.equal(game:renderAttempts(), 0, "target interaction stops before GPU rendering")
  Assert.isNil(love.filesystem.getInfo(game.saveNamespace), "teardown removes the isolated save namespace")
end

function T.tests.revealed_double_targets_publish_only_visible_source_facts()
  local game, screen, battle = openTargetJourney()
  local ok, err = xpcall(function()
    local view = screen:view()
    Assert.equal(#view.targets, 2, "only the two positioned foe participants appear in the target controls")
    Assert.equal(view.targets[1].name, "LEFT", "the first source slot keeps its actual active nickname")
    Assert.equal(view.targets[2].name, "RIGHT", "the second source slot keeps its actual active nickname")
    Assert.notNil(view.targets[1].gender, "the target button exposes the active mon's gender marker")
    Assert.isTrue(type(view.targets[1].iconKey) == "string", "the target button exposes its staged mon icon identity")
    Assert.isTrue(type(view.targets[1].position) == "number", "display slot identity remains separate from combatant identity")
    for _, candidate in ipairs(view.targets) do
      Assert.isFalse(candidate.name:find("HIDDEN", 1, true) ~= nil, "unrevealed reserves stay out of target labels")
    end
    Assert.notNil(battle:status().request, "the open source decision remains pending while the menu is shown")
  end, debug.traceback)
  closeJourney(game, screen, battle)
  if not ok then
    error(err, 0)
  end
end

function T.tests.target_navigation_moves_between_source_grid_slots()
  local game, screen, battle = openTargetJourney()
  local ok, err = xpcall(function()
    local start = screen:view().selection
    Assert.equal(start, "target:0", "the first active foe occupies the lower-left native target slot")
    screen:input({ { type = "navigate", direction = "right" } })
    screen:updateFixed(TICK)
    local moved = screen:view().selection
    Assert.equal(moved, "target:2", "right selects the lower-right grid neighbor instead of the next flat-list item; got " .. tostring(moved))
    Assert.notNil(battle:status().request, "navigation does not seal the pending kernel request")
  end, debug.traceback)
  closeJourney(game, screen, battle)
  if not ok then
    error(err, 0)
  end
end

function T.tests.target_confirmation_waits_for_feedback_and_seals_one_admitted_fragment()
  local game, screen, battle, replies = openTargetJourney()
  local ok, err = xpcall(function()
    local target = assert(screen:view().targets[1], "the first active opponent has a target control")
    local regions = require("game.hgss.src.battle.BattleMenuRegions").forLayout("target")
    local emptyRegion = nil
    local region = nil
    for _, candidate in ipairs(regions) do
      if candidate.id == target.id then
        region = candidate
      elseif candidate.id == "target:3" then
        emptyRegion = candidate
      end
    end
    Assert.notNil(region, "the active target uses the provider's native pointer region")
    Assert.notNil(emptyRegion, "the empty target button keeps its native bounds")
    local box = region --[[@as table<string, number|string>]]
    local x = box.x + math.floor(box.w / 2)
    local y = 192 + box.y + math.floor(box.h / 2)
    local empty = emptyRegion --[[@as table<string, number|string>]]
    local emptyX = empty.x + math.floor(empty.w / 2)
    local emptyY = 192 + empty.y + math.floor(empty.h / 2)
    screen:input({ { type = "pointer_down", pointerId = "touch:empty", x = emptyX, y = emptyY } })
    screen:input({ { type = "pointer_up", pointerId = "touch:empty", x = emptyX, y = emptyY } })
    screen:updateFixed(TICK)
    Assert.equal(screen:status().mode, "target", "an unoccupied source cell cannot become an eligible target by pointer bounds")
    Assert.equal(#screen:view().staged, 0, "an unoccupied source cell seals no fragment")

    screen:input({ { type = "pointer_down", pointerId = "touch:target", x = x, y = y } })
    screen:updateFixed(TICK)
    Assert.equal(#screen:view().staged, 0, "press feedback does not stage a choice before the target release")
    screen:input({ { type = "pointer_up", pointerId = "touch:target", x = x, y = y } })
    Assert.equal(#screen:view().staged, 0, "release feedback runs before the target choice is staged")
    for _ = 1, 8 do
      screen:updateFixed(TICK)
      if #screen:view().staged > 0 then
        break
      end
    end
    local staged = screen:view().staged
    Assert.equal(#staged, 1, "one eligible release stages exactly one target choice for the current actor")
    local request = assert(battle:status().request, "the two-actor source request stays open for its partner")
    Assert.equal(staged[1].combatant, request.actors[1].combatant, "the staged target choice stays bound to its actor")
    Assert.equal(#replies, 0, "the battle waits for the partner's choice before submitting the complete reply")

    pumpTo(screen, battle, function()
      return screen:status().mode == "command" and screen:view().menuInputEnabled == true
    end, "partner command menu")
    screen:input({ { type = "confirm" } })
    screen:input({ { type = "confirm" } })
    pumpTo(screen, battle, function()
      return screen:status().mode == "moves" and screen:view().menuInputEnabled == true
    end, "partner move menu")
    screen:input({ { type = "confirm" } })
    pumpTo(screen, battle, function()
      return screen:status().mode == "target"
    end, "partner target menu")
    screen:input({ { type = "confirm" } })
    Assert.equal(#replies, 1, "the partner's eligible choice submits one complete two-actor reply")
    local reply = replies[1]
    Assert.equal(#reply.choices, 2, "the reply preserves both actors' selected fragments")
    Assert.equal(
      reply.choices[1].payload.target.position,
      target.position,
      "the first choice keeps the exact target position admitted from the kernel"
    )
  end, debug.traceback)
  closeJourney(game, screen, battle)
  if not ok then
    error(err, 0)
  end
end

return T
