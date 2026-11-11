-- Live battle journeys through the production battle runtime on one booted
-- field game: a status condition reaches the detached presentation packet, and
-- a double-battle target menu runs through the real screen constructors to a
-- complete reply. Headless adapters stop before graphics rendering.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local BattlePresentationCache = require("libs.assets.src.battle.BattlePresentationCache")
local CacheFs = require("libs.storage.src.CacheFs")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local FinalizedGameFixture = require("tests.support.FinalizedGameFixture")
local ScreenTopology = require("libs.ui.src.ScreenTopology")
local SessionFixture = require("libs.battle.tests.session_fixture")
local SourceTick = require("libs.hgss.src.field.SourceTick")

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = {
      "field-runtime",
      "audio-bank:702",
      "battle-presentation:global",
      -- Both journeys bind one launch view: the player backpic and lead
      -- ball behind every packet, the YOUNGSTER front behind the doubles
      -- trainer battle, and the single evolution bundle behind the
      -- committed post-battle evolution.
      "battle-trainer-picture:back-PKMN_TRAINER_ETHAN",
      "battle-trainer-picture:front-YOUNGSTER",
      "battle-ball:POKE_BALL",
      "battle-evolution:global",
      "map-data:7",
      "map-data:61",
      "map-data:111",
      "map:7",
      "map:61",
      "map:111",
    },
    tags = { "battle", "status", "target-menu", "journey" },
  },
  tests = {},
}

local MAP = "MAP_NEW_BARK_ELMS_LAB_1F"
local TICK = SourceTick.DT

local function harness()
  return AcceptanceHarness.new({
    gameFactory = function(versionId, map)
      return FinalizedGameFixture.build(versionId, {
        saveId = "save-live-battle",
        location = { mapSymbol = map or MAP, fieldX = 4, fieldZ = 13, facing = "north" },
      })
    end,
  })
end

local function measurement()
  return {
    width = 256,
    height = 384,
    topology = ScreenTopology.dualDisplay(
      { id = "main", rect = { x = 0, y = 0, width = 256, height = 192 }, touch = false, role = "world" },
      { id = "lower", rect = { x = 0, y = 192, width = 256, height = 192 }, touch = true, role = "auxiliary" }
    ),
    pixelRatio = 1,
    signature = "battle-live-acceptance",
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

---@param cacheFs table? versioned derived cache staging the evolution leaf, nil when the journey evolves nothing
---@return table presentation service doubles behind the acceptance screen
local function presentationServices(cacheFs)
  local images = {}
  local assets = {
    prepare = function()
      return true
    end,
    drawable = function(key)
      images[key] = images[key] or drawable(key)
      return images[key]
    end,
    release = function() end,
  }
  -- The evolution journey stages its single selected bundle late through
  -- the same leaf the field envelope would demand: pending never applies
  -- here because the suite stages the receipt, so readiness reads it once.
  if cacheFs ~= nil then
    function assets.prepareEvolution()
      local record, recordErr = BattlePresentationCache.loadEvolution(cacheFs)
      if record == nil then
        error("the prepared cache stages the acceptance evolution leaf: " .. tostring(recordErr), 0)
      end
      return record
    end
  end
  return {
    assets = assets,
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
    audio = {
      play = function()
        return true
      end,
      playMusic = function()
        return true
      end,
      playFanfare = function()
        return true
      end,
      isFanfarePlaying = function()
        return false
      end,
      stop = function()
        return true
      end,
      stopMusic = function()
        return true
      end,
    },
  }
end

local function foeRecord(catalog, species, seed, name)
  local record = CatalogFixture.makeFactory(seed, catalog)
    :createNormal(CatalogFixture.normalRequest({ species = species, level = 8 }))
  record.nickname = name
  record.moves = { { move = "TACKLE", pp = 35, ppUps = 0 } }
  return record
end

local function recordingPort(packets)
  return {
    enter = function()
      return true
    end,
    present = function(packet)
      packets[#packets + 1] = packet
    end,
    ready = function()
      return true
    end,
    leave = function()
      return true
    end,
    dispose = function() end,
  }
end

local function sleepPacket(packets)
  for _, packet in ipairs(packets) do
    for _, event in ipairs(packet.events) do
      local payload = event.payload
      if event.kind == "status" and type(payload) == "table" and payload.key == "sleep" then
        return packet
      end
    end
  end
  return nil
end

local function assertHypnosisSleepProjection(game)
  local service = game.runtime.monService
  service:setMove(0, 0, "HYPNOSIS")
  local enemy = CatalogFixture.makeFactory(0xD03A51E, service:catalog())
    :createNormal(CatalogFixture.normalRequest({ species = "TOTODILE", level = 20 }))
  enemy.moves = { { move = "GROWL", pp = 40, ppUps = 0 } }

  local launch = {
    id = "launch-battle-status-presentation",
    kind = "wild",
    payload = { species = "TOTODILE", level = 20, mon = enemy },
  }
  local scenario = require("libs.hgss.src.battle.HgssBattleScenarioFactory").fromEncounter(launch.payload, {
    party = service,
    player = { trainerId = 99, trainerName = "MINT", language = "french" },
  })
  local packets = {}
  local battle = require("game.hgss.src.battle.BattleRuntime").new({
    request = launch,
    scenario = scenario,
    presentation = recordingPort(packets),
    party = service,
    seed = 0xD03A51E,
  })
  local ok, err = xpcall(function()
    local ticks = 0
    while sleepPacket(packets) == nil and battle:status().phase ~= "failed" and ticks < 600 do
      game:step()
      battle:update()
      local current = battle:status()
      if current.phase == "running" and current.request ~= nil then
        local actor = assert(current.request.actors, "the move request names its actor")[1]
        local reply = SessionFixture.replyFor(current.request, {
          SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(2)),
        })
        local accepted, replyErr = battle:submit(reply)
        Assert.isTrue(accepted, "the Hypnosis decision is accepted: " .. tostring(replyErr))
      end
      ticks = ticks + 1
    end

    Assert.isTrue(battle:status().phase ~= "failed", "the battle stays live: " .. tostring(battle:status().error))
    local packet = sleepPacket(packets)
    Assert.isTrue(packet ~= nil, "a successful Hypnosis publishes the canonical sleep event")
    local asleep = false
    for _, combatant in ipairs(assert(packet.after.foes, "the packet carries its detached foe view")) do
      asleep = asleep or combatant.condition == "sleep"
    end
    Assert.isTrue(asleep, "the same production packet projects the foe as asleep")
  end, debug.traceback)
  battle:dispose()
  if not ok then
    error(err, 0)
  end
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
    string.format(
      "battle target journey did not reach %s; screen=%s error=%s battle=%s battleError=%s request=%s",
      label,
      tostring(status.mode),
      tostring(status.error),
      tostring(battle:status().phase),
      tostring(battle:status().error),
      tostring(battle:status().request ~= nil)
    ),
    0
  )
end

---@param cacheFs table versioned derived cache staging the selected leaves
---@param versionId string ready game version under the journey
---@param trainerSelectors string[] exact semantic trainer selectors behind the journey
---@param ballSelectors string[] exact semantic ball selectors behind the journey
---@return table per-launch battle view over the real staged core
local function launchViewFor(cacheFs, versionId, trainerSelectors, ballSelectors)
  -- The screen binds one launch view, never the global inventory: shared
  -- core sections borrow by reference while only the journey's selected
  -- leaves attach as launch entries.
  local core =
    assert(BattlePresentationCache.load(cacheFs), "the ready version carries verified battle presentation resources")
  Assert.isTrue(core.verified == true, "the journey reads verified staged presentation data")
  local view = {}
  for key, value in pairs(core) do
    view[key] = value
  end
  local trainerEntries = {}
  for _, selector in ipairs(trainerSelectors) do
    local record = assert(
      BattlePresentationCache.loadTrainerPicture(cacheFs, selector),
      versionId .. " stages the selected trainer leaf " .. selector
    )
    trainerEntries[selector] = record.entry
  end
  view.trainerPictures = { entries = trainerEntries }
  local ballEntries = {}
  for _, selector in ipairs(ballSelectors) do
    local record = assert(
      BattlePresentationCache.loadBall(cacheFs, selector),
      versionId .. " stages the selected ball leaf " .. selector
    )
    ballEntries[selector] = record.entry
  end
  view.battleBalls = { entries = ballEntries }
  return view
end

local function assertTargetMenuJourney(game)
  local versionId = game.versionId
  local party = game.runtime.monService
  party:setMove(0, 0, "TACKLE")
  party:setMove(1, 0, "TACKLE")

  local catalog = party:catalog()
  local cacheFs = CacheFs.forVersion(versionId)
  local presentation = presentationServices()
  local manifest = launchViewFor(
    cacheFs,
    versionId,
    { "back:PKMN_TRAINER_ETHAN", "front:YOUNGSTER" },
    { "ball:POKE_BALL" }
  )

  local launchId = "acceptance-target-menu-" .. versionId
  local scenario = require("libs.hgss.src.battle.HgssBattleScenarioFactory").fromTrainer({
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

  local replies = {}
  local battle
  local screen = require("game.hgss.src.battle.BattleScreenState").new({
    launchId = launchId,
    splRandomState = { state = 0 },
    manifest = manifest,
    model = require("game.hgss.src.battle.BattlePresentationModel"),
    submit = function(reply)
      replies[#replies + 1] = reply
      return battle:submit(reply)
    end,
    measureDisplay = measurement,
    assets = presentation.assets,
    text = presentation.text,
    windows = presentation.windows,
    audio = presentation.audio,
    monCatalog = catalog,
    monIconProvider = {
      frame = function()
        return drawable("target-icon")
      end,
    },
  })
  battle = require("game.hgss.src.battle.BattleRuntime").new({
    request = { id = launchId, kind = "trainer", payload = { trainer = "target-menu" } },
    scenario = scenario,
    presentation = screen:presentationPort(),
    party = party,
    bag = game.runtime.bagService,
  })

  local function toTargetMenu(label)
    pumpTo(screen, battle, function()
      return screen:status().mode == "command" and screen:view().menuInputEnabled == true
    end, label .. " command menu")
    screen:input({ { type = "confirm" } })
    pumpTo(screen, battle, function()
      return screen:status().mode == "moves" and screen:view().menuInputEnabled == true
    end, label .. " move menu")
    screen:input({ { type = "confirm" } })
    pumpTo(screen, battle, function()
      return screen:status().mode == "target"
    end, label .. " target menu")
  end

  local ok, err = xpcall(function()
    toTargetMenu("lead")
    local view = screen:view()
    Assert.equal(#view.targets, 2, "only the two positioned foe participants appear in the target controls")
    Assert.equal(view.targets[1].name, "LEFT", "the first source slot keeps its actual active nickname")
    Assert.equal(view.targets[2].name, "RIGHT", "the second source slot keeps its actual active nickname")
    Assert.isTrue(type(view.targets[1].iconKey) == "string", "the target button exposes its staged mon icon identity")
    Assert.notNil(battle:status().request, "the open source decision remains pending while the menu is shown")

    Assert.equal(view.selection, "target:0", "the first active foe occupies the lower-left native target slot")
    screen:input({ { type = "navigate", direction = "right" } })
    screen:updateFixed(TICK)
    Assert.equal(screen:view().selection, "target:2", "right selects the lower-right grid neighbor")
    screen:input({ { type = "navigate", direction = "left" } })
    screen:updateFixed(TICK)

    local target = view.targets[1]
    screen:input({ { type = "confirm" } })
    for _ = 1, 8 do
      screen:updateFixed(TICK)
      if #screen:view().staged > 0 then
        break
      end
    end
    local staged = screen:view().staged
    Assert.equal(#staged, 1, "one confirmed target stages exactly one choice for the current actor")
    local request = assert(battle:status().request, "the two-actor source request stays open for its partner")
    Assert.equal(staged[1].combatant, request.actors[1].combatant, "the staged target choice stays bound to its actor")
    Assert.equal(#replies, 0, "the battle waits for the partner's choice before submitting the complete reply")

    toTargetMenu("partner")
    screen:input({ { type = "confirm" } })
    Assert.equal(#replies, 1, "the partner's choice submits one complete two-actor reply")
    Assert.equal(#replies[1].choices, 2, "the reply preserves both actors' selected fragments")
    Assert.equal(
      replies[1].choices[1].payload.target.position,
      target.position,
      "the first choice keeps the exact target position admitted from the kernel"
    )
  end, debug.traceback)
  screen:dispose()
  battle:dispose()
  if not ok then
    error(err, 0)
  end
end

-- Uses the production HGSS party, battle, completion child, and presentation
-- port with ROM-derived evolution rules, through the retail congratulations
-- line before the acceptance render trap permits any GPU operation.
local function assertEvolutionSceneJourney(game)
  local service = game.runtime.monService
  Assert.isTrue(
    service:giveMon({ species = "CYNDAQUIL", level = 13, heldItem = "NONE", form = 0 }),
    "the party needs a level-eligible evolution subject"
  )
  service:setMove(0, 0, "TACKLE")
  local catalog = service:catalog()
  local subject = assert(service:partyMon(0), "the evolution candidate is readable")
  local Experience = require("libs.mons.src.gen4.Experience")
  local growthCurve = catalog:growthCurve(catalog:species(subject.species).growthCurve)
  subject.experience = Experience.expFor(growthCurve, 14) - 1
  local preparation = assert(
    service:preparePartyChanges(service:partyRevision(), { { slot = 0, mon = subject } }),
    "the evolution candidate accepts its staged experience"
  )
  preparation.publish()
  local enemy = foeRecord(catalog, "CHANSEY", 20, "PRACTICE")
  enemy.moves = { { move = "SPLASH", pp = 40, ppUps = 0 } }

  local launchId = "acceptance-evolution-presentation-" .. game.versionId
  local launch = {
    id = launchId,
    kind = "wild",
    payload = { species = "CHANSEY", level = 20, mon = enemy },
  }
  local scenario = require("libs.hgss.src.battle.HgssBattleScenarioFactory").fromEncounter(launch.payload, {
    party = service,
    player = {
      trainerId = 99,
      trainerName = "MINT",
      trainerClassKey = "PKMN_TRAINER_ETHAN",
      language = "english",
    },
  })
  local cacheFs = CacheFs.forVersion(game.versionId)
  local manifest = launchViewFor(cacheFs, game.versionId, { "back:PKMN_TRAINER_ETHAN" }, { "ball:POKE_BALL" })
  local presentation = presentationServices(cacheFs)
  local BattleScreenState = require("game.hgss.src.battle.BattleScreenState")
  local SessionFixture = require("libs.battle.tests.session_fixture")
  local battle
  local screen = BattleScreenState.new({
    launchId = launchId,
    splRandomState = { state = 0 },
    manifest = manifest,
    model = require("game.hgss.src.battle.BattlePresentationModel"),
    submit = function(reply)
      return battle:submit(reply)
    end,
    measureDisplay = measurement,
    assets = presentation.assets,
    text = presentation.text,
    windows = presentation.windows,
    audio = presentation.audio,
    monCatalog = catalog,
    monIconProvider = {
      frame = function()
        return drawable("evolution-icon")
      end,
    },
  })
  battle = require("game.hgss.src.battle.BattleRuntime").new({
    request = launch,
    scenario = scenario,
    presentation = screen:presentationPort(),
    party = service,
    seed = 0xE7010710,
    evolutionContext = { timeOfDay = "day", mapId = 7 },
  })

  local ok, err = xpcall(function()
    local sceneView, evolvedLine
    for _ = 1, 5000 do
      local screenStatus = screen:status()
      if
        screenStatus.mode == "intro"
        or screenStatus.mode == "narration"
        or screenStatus.mode == "outcome"
        or screen:view().levelUpStats ~= nil
      then
        screen:input({ { type = "confirm" } })
      end
      game:step()
      battle:update()
      screen:updateFixed(TICK)

      local child = screen:_snapshot().childView
      -- The committed evolution may still be staging its selected leaf:
      -- a pending child carries no renderer state yet, so only a
      -- presented child advances the scene proof.
      if type(child) == "table" and child.kind == "evolution" and type(child.presentation) == "table" then
        local childPresentation = child.presentation --[[@as table<string, any>]]
        sceneView = sceneView or childPresentation.scene
        local message = child.phase == "evolved_message" and childPresentation.presentation.message
        if type(message) == "string" and message:lower():find("quilava", 1, true) then
          evolvedLine = message
          break
        end
      end

      local status = battle:status()
      Assert.isFalse(status.phase == "failed", "the live evolution battle stays composed")
      if status.phase == "running" and status.request ~= nil then
        local request = status.request
        local actor = assert(request.actors[1], "the request names its actor")
        local fragment = request.kind == "learn_move"
            and { actor = actor, kind = "confirm", payload = { decision = "decline" } }
          or SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(2))
        Assert.isTrue(battle:submit(SessionFixture.replyFor(request, { fragment })), "the battle accepts its decision")
      end
    end

    local scene = assert(sceneView, "the leveled Cyndaquil opens its post-battle evolution scene")
    Assert.equal(scene.main.oldSpecies, "CYNDAQUIL", "the old Pokepic shows the committed subject")
    Assert.equal(scene.main.newSpecies, "QUILAVA", "the new Pokepic shows the ROM-derived target")
    Assert.equal(scene.particles.identity, "evolution", "the scene carries the evolution particle set")
    Assert.notNil(evolvedLine, "the live scene prints its congratulations")
  end, debug.traceback)
  screen:dispose()
  battle:dispose()
  if not ok then
    error(err, 0)
  end
end

function T.tests.live_battle_projects_status_and_drives_the_target_menu()
  local versionId = AcceptanceHarness.defaultVersion()
  local game = harness():boot({ versionId = versionId, map = MAP, save = "fresh" })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    local party = game.runtime.monService
    Assert.isTrue(
      party:giveMon({ species = "GASTLY", level = 20, heldItem = "NONE", form = 0 }),
      "the lead joins the live party"
    )
    Assert.isTrue(
      party:giveMon({ species = "CYNDAQUIL", level = 8, heldItem = "NONE", form = 0 }),
      "the partner joins the live party"
    )
    assertHypnosisSleepProjection(game)
    assertTargetMenuJourney(game)
  end, debug.traceback)
  game:close()
  if ok then
    Assert.equal(game:renderAttempts(), 0, "the journeys stop before GPU rendering")
    Assert.isNil(love.filesystem.getInfo(game.saveNamespace), "teardown removes the isolated save namespace")
  end
  if not ok then
    error(err, 0)
  end
end

function T.tests.live_battle_opens_the_rom_derived_evolution_scene()
  local versionId = AcceptanceHarness.defaultVersion()
  local game = harness():boot({ versionId = versionId, map = MAP, save = "fresh" })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    assertEvolutionSceneJourney(game)
  end, debug.traceback)
  game:close()
  if ok then
    Assert.equal(game:renderAttempts(), 0, "the evolution journey stops before GPU rendering")
    Assert.isNil(love.filesystem.getInfo(game.saveNamespace), "teardown removes the isolated save namespace")
  end
  if not ok then
    error(err, 0)
  end
end

return T
