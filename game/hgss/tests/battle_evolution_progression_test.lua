-- Post-battle level-up evolution: only party slots whose derived level
-- actually rose during the battle enter the native evolution sequence
-- before field return. The sequence starts on its own without a
-- confirmation gate, cancel is honored only where the source method
-- permits it, learned moves resolve through the native picker, and each
-- finished evolution publishes exactly once through the battle committer
-- without replaying battle rewards. A stale owner between commit and
-- publication changes nothing live.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local ItemFixture = require("libs.items.tests.item_fixture")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")
local HgssBagService = require("libs.hgss.src.items.HgssBagService")
local Experience = require("libs.mons.src.gen4.Experience")
local MonStats = require("libs.mons.src.gen4.MonStats")
local BattlePresentationModel = require("game.hgss.src.battle.BattlePresentationModel")
local BattlePresentationManifestFixture = require("tests.support.BattlePresentationManifestFixture")
local BattlePresentationSchema = require("libs.assets.src.battle.BattlePresentationSchema")
local ScreenTopology = require("libs.ui.src.ScreenTopology")
local SessionFixture = require("libs.battle.tests.session_fixture")

local RUNTIME_MODULE = "game.hgss.src.battle.BattleRuntime"
local STATE_MODULE = "game.hgss.src.battle.BattleScreenState"
local SCENARIO_FACTORY_MODULE = "libs.hgss.src.battle.HgssBattleScenarioFactory"

local TICK = 1 / 30

local T = {}

---@param value unknown value under test preparation
---@return unknown a detached copy sharing no table with the source
local function deepCopy(value)
  if type(value) ~= "table" then
    return value
  end
  local copy = {}
  for key, item in pairs(value) do
    copy[deepCopy(key)] = deepCopy(item)
  end
  return copy
end

---@return table detached schema-valid staged manifest for the evolution harness scene
local function screenManifest()
  local manifest = deepCopy(BattlePresentationManifestFixture.manifest())
  manifest.scenes = { { key = "general/plain/day", background = "general", terrain = "plain", time = "day" } }
  BattlePresentationSchema.assertManifest(manifest)
  return manifest
end

---@param image table fake image handle under inspection
---@return integer staged image width
local function fakeImageWidth(image)
  return image.width
end

---@param image table fake image handle under inspection
---@return integer staged image height
local function fakeImageHeight(image)
  return image.height
end

---@param image table fake image handle under inspection
---@return integer, integer staged image dimensions
local function fakeImageDimensions(image)
  return image.width, image.height
end

local function fakeImageSetFilter() end

---@param key string image identity under test preparation
---@return table fake image handle carrying the renderer-required dimensions
local function fakeDrawable(key)
  local hudImage = key:match("^hud:") ~= nil
  return {
    handle = key,
    width = hudImage and 1648 or 80,
    height = hudImage and 8 or 80,
    getWidth = fakeImageWidth,
    getHeight = fakeImageHeight,
    getDimensions = fakeImageDimensions,
    setFilter = fakeImageSetFilter,
  }
end

---@return table caller-owned dual-surface display facts
local function dualMeasurement()
  return {
    width = 256,
    height = 384,
    topology = ScreenTopology.dualDisplay(
      { id = "main", rect = { x = 0, y = 0, width = 256, height = 192 }, touch = false, role = "world" },
      { id = "lower", rect = { x = 0, y = 192, width = 256, height = 192 }, touch = true, role = "auxiliary" }
    ),
    pixelRatio = 1,
    signature = "postbattle-evolution:dual",
  }
end

-- Builds the shared mon catalog with per-test evolution slots grafted
-- onto the fixture root, plus an item catalog with the evolution blocker
-- re-keyed from its deterministic placeholder when requested.
---@param mutate fun(root: table<string, unknown>)|nil species edits for one rig
---@param withBlocker boolean true while the rig holds the evolution blocker item
---@return table mon catalog carrying exactly the rig slots
---@return table item catalog for the rig bag and screen
local function evolutionCatalogs(mutator, withBlocker)
  local root = CatalogFixture.buildAssetRoot()
  if mutator ~= nil then
    mutator(root)
  end
  local itemRoot = ItemFixture.buildAssetRoot()
  if withBlocker then
    local record = assert(itemRoot.items.ITEM_204, "the item fixture carries the blocker placeholder")
    itemRoot.items.ITEM_204 = nil
    itemRoot.items.EVERSTONE = record
  end
  local ItemCatalog = require("libs.items.src.ItemCatalog")
  local MonCatalog = require("libs.mons.src.MonCatalog")
  local items = ItemCatalog.new(itemRoot)
  return MonCatalog.new(root, items), items
end

---@param root table<string, unknown> mutable synthetic mon asset root under grafting
local function graftLevelSlot(root)
  local species = root.species --[[@as table<string, table<string, unknown>>]]
  local forms = species.EEVEE.forms --[[@as table<integer, table<string, unknown>>]]
  forms[0].evolutions = {
    { method = "level", level = 10, target = "TOTODILE", form = 0 },
  }
end

---@param root table<string, unknown> mutable synthetic mon asset root under grafting
local function graftBondSlot(root)
  local species = root.species --[[@as table<string, table<string, unknown>>]]
  local forms = species.PICHU.forms --[[@as table<integer, table<string, unknown>>]]
  forms[0].evolutions = {
    { method = "friendship_day", target = "TOTODILE", form = 0 },
  }
end

---@param root table<string, unknown> mutable synthetic mon asset root under grafting
local function graftNincadaLine(root)
  local species = root.species --[[@as table<string, table<string, unknown>>]]
  local function stats(hp, attack, defense, speed, specialAttack, specialDefense)
    return {
      hp = hp,
      attack = attack,
      defense = defense,
      speed = speed,
      specialAttack = specialAttack,
      specialDefense = specialDefense,
    }
  end
  local held = {
    common = { item = "NONE", nativeId = 0 },
    rare = { item = "NONE", nativeId = 0 },
  }
  species.NINCADA = {
    nativeId = 290,
    name = "NINCADA",
    growthCurve = "erratic",
    baseFriendship = 70,
    genderRatio = 31,
    eggCycles = 15,
    eggGroups = { "bug", "bug" },
    catchRate = 255,
    baseExpYield = 65,
    evYield = stats(0, 0, 1, 0, 0, 0),
    heldItems = held,
    color = 3,
    flip = false,
    forms = {
      [0] = {
        baseStats = stats(31, 45, 90, 40, 30, 30),
        types = { "bug", "ground" },
        abilities = { "OVERGROW" },
        tmhm = {},
        levelUpMoves = {
          { level = 1, move = "SCRATCH" },
          { level = 1, move = "HARDEN" },
        },
        evolutions = {
          { method = "level_ninjask", level = 20, target = "NINJASK", form = 0 },
          { method = "level_shedinja", level = 20, target = "SHEDINJA", form = 0 },
        },
        icon = "NINCADA/f0",
        portrait = "NINCADA/f0/male/plain",
      },
    },
  }
  species.NINJASK = {
    nativeId = 291,
    name = "NINJASK",
    growthCurve = "erratic",
    baseFriendship = 70,
    genderRatio = 31,
    eggCycles = 15,
    eggGroups = { "bug", "bug" },
    catchRate = 120,
    baseExpYield = 155,
    evYield = stats(0, 0, 0, 2, 0, 0),
    heldItems = held,
    color = 3,
    flip = false,
    forms = {
      [0] = {
        baseStats = stats(61, 90, 45, 160, 50, 50),
        types = { "bug", "flying" },
        abilities = { "OVERGROW" },
        tmhm = {},
        levelUpMoves = {
          { level = 1, move = "SCRATCH" },
          { level = 1, move = "HARDEN" },
        },
        evolutions = {},
        icon = "NINJASK/f0",
        portrait = "NINJASK/f0/male/plain",
      },
    },
  }
end

---@param catalog table mon catalog under test preparation
---@param mon table<string, unknown> generated mon pinned one experience below its next level
---@param level integer current battle level under pinning
local function pinOneBelow(catalog, mon, level)
  local species = catalog:species(mon.species)
  local curve = catalog:growthCurve(species.growthCurve)
  mon.experience = Experience.expFor(curve, level + 1) - 1
  mon.condition.currentHp = MonStats.derive(mon, catalog).maxHp
end

---@param catalog table mon catalog under test preparation
---@param specs table<integer, table<string, unknown>> ordered party specs under building
---@return table live party owner holding the described members in order
local function makePartyOwnerWith(catalog, specs)
  local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
  local owner = HgssMonService.new({
    catalog = catalog,
    bucket = MonsSave.capture(Party.new():capture(), Lcrng.new(0x22222222):capture()),
    profile = CatalogFixture.profile(),
    game = "heartgold",
    language = "english",
    charmap = CatalogFixture.CHARMAP,
    games = CatalogFixture.GAMES,
    languages = CatalogFixture.LANGUAGES,
    items = CatalogFixture.ITEMS,
    balls = CatalogFixture.BALLS,
    mapSection = 7,
    date = CatalogFixture.metDate(),
  })
  local factory = CatalogFixture.makeFactory(0xCA900001, catalog)
  for index, spec in ipairs(specs) do
    local request = CatalogFixture.normalRequest({
      species = spec.species,
      level = spec.level,
      heldItem = spec.heldItem,
    })
    local record = factory:createNormal(request)
    if spec.below == true then
      pinOneBelow(catalog, record, spec.level)
    else
      record.condition.currentHp = MonStats.derive(record, catalog).maxHp
    end
    if spec.moves ~= nil then
      record.moves = spec.moves
    end
    if spec.friendship ~= nil then
      record.friendship = spec.friendship
    end
    Assert.isTrue(owner:addMon(record), "the evolution path needs its live party member " .. tostring(index))
  end
  return owner
end

---@param catalog table mon catalog under test preparation
---@param species string foe species key under test preparation
---@param level integer foe battle level under test preparation
---@return table full mon-domain record for the enemy side
local function makeFoe(catalog, species, level)
  local factory = CatalogFixture.makeFactory(0x5EED0002, catalog)
  local record = factory:createNormal(CatalogFixture.normalRequest({ species = species, level = level }))
  record.moves = { { move = "TACKLE", pp = 35, ppUps = 0 } }
  return record
end

---@param itemCatalog table item catalog under test preparation
---@param stock table<integer, { key: string, quantity: integer }> stocked items under preparation
---@return table bag owner holding the described stock
local function makeStockedBag(itemCatalog, stock)
  local bag = HgssBagService.new({ catalog = itemCatalog })
  for _, entry in ipairs(stock) do
    Assert.isTrue(bag:add(entry.key, entry.quantity), "the evolution path stocks " .. entry.key)
  end
  return bag
end

-- Builds the live dex knowledge owner over the rig mon catalog: the
-- generated catalog gains ordinary policies for grafted species the
-- shared dex fixture never knew, while display and completion sets filter
-- to exactly the rig species so construction sees the admitted set.
---@param catalog table mon catalog under test preparation
---@return table live dex knowledge owner with an empty history
local function dexOwnerFor(catalog)
  local PokedexKnowledge = require("libs.hgss.src.mons.PokedexKnowledge")
  local PokedexDexFixture = require("libs.hgss.tests.mons.pokedex_dex_fixture")
  local pokedexCatalog = PokedexDexFixture.buildPokedexCatalog()
  for _, key in ipairs(catalog:speciesKeys()) do
    if pokedexCatalog.species[key] == nil then
      pokedexCatalog.species[key] = {
        formPolicy = {
          kind = "ordinary",
          variants = { { id = 0, form = 0 } },
          defaultVariant = 0,
          rememberCaughtVariants = false,
          rememberFirstPersonality = false,
        },
      }
    end
  end
  local keep = {}
  for _, key in ipairs(catalog:speciesKeys()) do
    keep[key] = true
  end
  local function filter(list)
    local kept = {}
    for _, key in ipairs(list) do
      if keep[key] == true then
        kept[#kept + 1] = key
      end
    end
    return kept
  end
  pokedexCatalog.dexOrders = {
    johto = filter(pokedexCatalog.dexOrders.johto),
    national = filter(pokedexCatalog.dexOrders.national),
  }
  pokedexCatalog.completionSets = {
    johto = filter(pokedexCatalog.completionSets.johto),
    national = filter(pokedexCatalog.completionSets.national),
  }
  return PokedexKnowledge.new(PokedexDexFixture.refs(catalog, pokedexCatalog))
end

-- Builds the live game-stats owner over the rig mon catalog with
-- nothing counted. The allow-set admits exactly the rig species so
-- registration validation sees the same references production composes.
---@param catalog table mon catalog under test preparation
---@return table live game-stats owner with a zero score
local function statsOwnerFor(catalog)
  local GameStats = require("libs.hgss.src.mons.GameStats")
  local allowed = {}
  for _, key in ipairs(catalog:speciesKeys()) do
    allowed[key] = true
  end
  return GameStats.new({ species = allowed })
end

---@return integer the authoritative register points per fresh registration
local function registerPoints()
  local GameStats = require("libs.hgss.src.mons.GameStats")
  return GameStats.SCORE_POINTS[GameStats.SCORE_EVENT_REGISTER_SPECIES_CAUGHT]
end

---@param opts table rig options under test preparation
---@return table live rig with the runtime, the real screen, and its port
local function openEvolutionRig(opts)
  local BattleRuntime = require(RUNTIME_MODULE)
  local BattleScreenState = require(STATE_MODULE)
  local ScenarioFactory = require(SCENARIO_FACTORY_MODULE)
  local holder = {}
  local rig = {
    measurement = dualMeasurement(),
    text = { draws = {} },
    windows = { calls = {} },
    audio = { plays = {} },
    assets = { prepared = {}, released = {}, images = {} },
  }
  function rig.text.measure(content)
    return { width = 8 * #tostring(content), height = 16 }
  end
  function rig.text.drawText(content, x, y)
    rig.text.draws[#rig.text.draws + 1] = { content = tostring(content), x = x, y = y }
  end
  function rig.windows.drawWindow(box, frameKey, background)
    rig.windows.calls[#rig.windows.calls + 1] = { box = box, frame = frameKey, background = background }
  end
  function rig.windows.drawApplicationFrame(box, frameIndex)
    rig.windows.calls[#rig.windows.calls + 1] = { applicationBox = box, frame = frameIndex }
  end
  function rig.audio.play(first, second)
    rig.audio.plays[#rig.audio.plays + 1] = second ~= nil and second or first
    return true
  end
  function rig.assets.prepare(_)
    rig.assets.prepared[#rig.assets.prepared + 1] = true
    return true
  end
  function rig.assets.drawable(key)
    if rig.assets.images[key] == nil then
      rig.assets.images[key] = fakeDrawable(key)
    end
    return rig.assets.images[key]
  end
  function rig.assets.release(key)
    rig.assets.released[key] = (rig.assets.released[key] or 0) + 1
  end
  local catalog = assert(opts.catalog, "the evolution rig needs its mon catalog")
  local party = makePartyOwnerWith(catalog, opts.partySpecs)
  local bag = opts.bag
  local player = { trainerId = 99, trainerName = "MINT", language = "french" }
  local launchId = opts.launchId or "launch-postbattle-evolution"
  local foe = makeFoe(catalog, opts.foeSpecies or "EEVEE", opts.foeLevel or 3)
  local scenario = ScenarioFactory.fromEncounter(
    { attemptId = launchId .. "-attempt", mon = foe },
    { party = party, bag = bag, player = player }
  )
  local launch = {
    id = launchId,
    kind = "wild",
    payload = {
      attemptId = launchId .. "-attempt",
      species = opts.foeSpecies or "EEVEE",
      form = 0,
      level = opts.foeLevel or 3,
      personality = 1,
      ability = "RUN_AWAY",
    },
  }
  local screen = BattleScreenState.new({
    launchId = launchId,
    manifest = screenManifest(),
    model = BattlePresentationModel,
    submit = function(reply)
      return holder.battle:submit(reply)
    end,
    measureDisplay = function()
      return rig.measurement
    end,
    itemCatalog = opts.itemCatalog,
    monCatalog = catalog,
    assets = rig.assets,
    text = rig.text,
    windows = rig.windows,
    audio = rig.audio,
  })
  rig.screen = screen
  rig.port = screen:presentationPort()
  local args = {
    request = launch,
    scenario = scenario,
    party = party,
    presentation = rig.port,
    seed = 0x12345678,
    evolutionContext = opts.evolutionContext,
  }
  if bag ~= nil then
    args.bag = bag
  end
  if opts.dex ~= nil then
    args.dex = opts.dex
  end
  if opts.stats ~= nil then
    args.stats = opts.stats
  end
  if opts.captures ~= nil then
    args.captures = opts.captures
  end
  holder.battle = BattleRuntime.new(args)
  rig.battle = holder.battle
  rig.party = party
  rig.bag = bag
  rig.catalog = catalog
  function rig.pump(ticks)
    for _ = 1, ticks or 1 do
      rig.battle:update()
      rig.screen:updateFixed(TICK)
    end
  end
  return rig
end

-- Acknowledges narration through the real screen path exactly as a player
-- would, so the terminal outcome can be observed and acknowledged.
---@param rig table live evolution rig under test driving
local function ackNarration(rig)
  local mode = rig.screen:status().mode
  if mode == "intro" or mode == "narration" or mode == "outcome" then
    rig.screen:input({ { type = "confirm" } })
  end
end

---@param rig table live evolution rig under test driving
---@param request table<string, unknown> pending player decision under answering
---@return table executable attack fragment for the lead combatant
local function attackFragment(rig, request)
  local options = rig.battle:decisionOptions(request.requestId)
  Assert.notNil(options, "the opening decision projects its options")
  assert(options ~= nil, "the attack projects its options")
  for _, actor in ipairs(options.actors) do
    for _, choice in ipairs(actor.choices or {}) do
      if choice.enabled == true and type(choice.choice) == "table" and choice.choice.kind == "attack" then
        return choice.choice
      end
    end
  end
  error("the lead decision offers no executable attack")
end

-- Answers attack decisions until the foe faints and the commit receipt
-- publishes, declining any mid-battle learning through the kernel path.
---@param rig table live evolution rig under test driving
---@param budget integer maximum update ticks before the driver gives up
---@return table<string, unknown> status once the commit receipt is published
local function driveToCommitted(rig, budget)
  for _ = 1, budget do
    rig.pump(1)
    ackNarration(rig)
    local current = rig.battle:status()
    if current.phase == "failed" then
      error("the evolution battle failed: " .. tostring(current.error), 0)
    end
    if current.phase == "running" and current.request ~= nil then
      local request = current.request --[[@as table<string, unknown>]]
      if request.kind == "learn_move" then
        local actor = assert(request.actors[1], "learning answers its combatant")
        local accepted, replyErr = rig.battle:submit(
          SessionFixture.replyFor(request, { { actor = actor, kind = "confirm", payload = { decision = "decline" } } })
        )
        Assert.isTrue(accepted, "mid-battle learning declines: " .. tostring(replyErr))
      else
        local fragment = attackFragment(rig, request)
        local accepted, replyErr = rig.battle:submit(SessionFixture.replyFor(request, { fragment }))
        Assert.isTrue(accepted, "the lead attack is accepted: " .. tostring(replyErr))
      end
    end
    if current.outcomeReceipt ~= nil and current.outcomeReceipt.committed == true then
      return current
    end
  end
  error("the evolution battle never published its commit receipt")
end

-- Waits for the postbattle evolution decision through the real completion
-- lane. Errors when the lifetime returns to the field with no evolution
-- decision offered.
---@param rig table live evolution rig under test driving
---@param budget integer maximum update ticks before the driver gives up
---@return table<string, unknown> completion description once the evolution is offered
local function driveToEvolution(rig, budget)
  for _ = 1, budget do
    rig.pump(1)
    ackNarration(rig)
    local completion = rig.screen:status().completion
    if type(completion) == "table" and completion.kind == "evolution" then
      return completion
    end
    if rig.battle:status().phase == "complete" then
      error("the battle returned to the field without offering its evolution")
    end
  end
  error("the committed battle never offered its evolution decision")
end

-- Lets the offered evolution sequence run to field return with no player
-- input: the native entry, cry, and animation start on their own.
---@param rig table live evolution rig under test driving
---@param budget integer maximum update ticks before the driver gives up
local function runEvolutionHandsFree(rig, budget)
  for _ = 1, budget do
    rig.pump(1)
    ackNarration(rig)
    if rig.battle:status().phase == "complete" then
      return
    end
    if rig.battle:status().phase == "failed" then
      error("the evolution run failed: " .. tostring(rig.battle:status().error), 0)
    end
  end
  error("the offered evolution never settled back to the field")
end

local function singleTackle()
  return { { move = "TACKLE", pp = 35, ppUps = 0 } }
end

-- Only the slot whose derived level actually rose evolves, exactly once:
-- the already-eligible benched member that gained nothing stays, the
-- original battle receipt survives the extra publication untouched, and
-- the evolved record persists across save and reload.
function T.newly_leveled_mon_evolves_once_while_unleveled_eligible_mon_stays()
  local catalog = evolutionCatalogs(graftLevelSlot, false)
  local rig = openEvolutionRig({
    launchId = "launch-level-gain-evolves",
    catalog = catalog,
    itemCatalog = ItemFixture.makeCatalog(),
    partySpecs = {
      { species = "EEVEE", level = 9, below = true, moves = singleTackle() },
      { species = "EEVEE", level = 12, moves = singleTackle() },
    },
    evolutionContext = { timeOfDay = "day", mapId = 7 },
  })
  local committed = driveToCommitted(rig, 1500)
  Assert.equal(committed.result, "win", "the lead settles the bout as a win")
  local receipt = assert(committed.outcomeReceipt, "completion carries its commit receipt")
  Assert.isTrue(receipt.committed, "the battle receipt commits before any evolution")
  Assert.isTrue((committed.completionPending or 0) >= 1, "the committed win queues its leveled member for evolution")
  local offered = driveToEvolution(rig, 1200)
  Assert.equal(offered.kind, "evolution", "the offered completion names the evolution decision")
  runEvolutionHandsFree(rig, 1500)
  Assert.equal(rig.battle:status().phase, "complete", "the evolved member still returns to the field")
  Assert.isNil(rig.screen:status().completion, "the finished evolution consumes its completion")
  local evolved = rig.party:partyMon(0)
  Assert.equal(evolved.species, "TOTODILE", "the leveled member evolves once into its first matching rule")
  Assert.equal(rig.party:partyCount(), 2, "the evolution publishes no extra party member")
  local steady = rig.party:partyMon(1)
  Assert.equal(steady.species, "EEVEE", "the already-eligible member that gained nothing stays")
  local survivor = rig.battle:status()
  Assert.deepEqual(survivor.outcomeReceipt, receipt, "the evolution pass never rewrites the battle receipt")
  local saveable, _ = rig.battle:canSave()
  Assert.isTrue(saveable, "the save gate reopens once every evolution settles")
  -- Ordinary save and reload see the evolved record in its party slot.
  local FakeCache = require("tests.support.FakeCache")
  local SaveFs = require("libs.storage.src.SaveFs")
  local saves = SaveFs.global(FakeCache.new())
  local bucket = rig.party:capture()
  Assert.isTrue(saves:writeLua("mons.lua", bucket), "the evolved party writes through the save root")
  local loaded = assert(saves:loadLua("mons.lua"), "the evolved party reads back through the save root")
  local context = CatalogFixture.domainContext(CatalogFixture.makeCatalog())
  Assert.isTrue(MonsSave.validate(loaded, context), "the reloaded bucket validates before restore")
  local restored = MonsSave.restore(loaded, context)
  local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
  local reloaded = HgssMonService.new({
    catalog = CatalogFixture.makeCatalog(),
    bucket = MonsSave.capture(restored.party:capture(), restored.rng:capture(), restored.boxes:capture()),
    profile = CatalogFixture.profile(),
    game = "heartgold",
    language = "english",
    charmap = CatalogFixture.CHARMAP,
    games = CatalogFixture.GAMES,
    languages = CatalogFixture.LANGUAGES,
    items = CatalogFixture.ITEMS,
    balls = CatalogFixture.BALLS,
    mapSection = 7,
    date = CatalogFixture.metDate(),
  })
  Assert.equal(reloaded:partyMon(0).species, "TOTODILE", "the reloaded party keeps the evolved species")
  rig.battle:dispose()
  rig.screen:dispose()
end

-- The first matching rule under the frozen launch clock decides: a bond
-- evolution answers its permitted daytime while the held blocker stops
-- the same level trigger cold in the same battle.
function T.daytime_bond_evolves_while_the_held_blocker_holds()
  local catalog, items = evolutionCatalogs(function(root)
    graftBondSlot(root)
    graftLevelSlot(root)
  end, true)
  local rig = openEvolutionRig({
    launchId = "launch-day-bond-evolves",
    catalog = catalog,
    itemCatalog = items,
    partySpecs = {
      { species = "PICHU", level = 9, below = true, moves = singleTackle(), friendship = 230 },
      { species = "EEVEE", level = 9, below = true, moves = singleTackle(), heldItem = "EVERSTONE" },
    },
    evolutionContext = { timeOfDay = "day", mapId = 7 },
  })
  driveToCommitted(rig, 1500)
  driveToEvolution(rig, 1200)
  runEvolutionHandsFree(rig, 1500)
  Assert.equal(rig.battle:status().phase, "complete", "the daytime bond still returns to the field")
  Assert.equal(rig.party:partyMon(0).species, "TOTODILE", "the bond answers its permitted daytime")
  Assert.equal(rig.party:partyMon(1).species, "EEVEE", "the held blocker stops the same level trigger")
  Assert.equal(rig.party:partyMon(1).heldItem, "EVERSTONE", "the blocker stays held after the refused evolution")
  rig.battle:dispose()
  rig.screen:dispose()
end

-- The same bond stays closed at night: the leveled member keeps its
-- species, the lifetime still completes, and the receipt still commits.
function T.nighttime_withholds_the_daytime_bond()
  local catalog = evolutionCatalogs(graftBondSlot, false)
  local rig = openEvolutionRig({
    launchId = "launch-night-withholds-bond",
    catalog = catalog,
    itemCatalog = ItemFixture.makeCatalog(),
    partySpecs = {
      { species = "PICHU", level = 9, below = true, moves = singleTackle(), friendship = 230 },
    },
    evolutionContext = { timeOfDay = "night", mapId = 7 },
  })
  local committed = driveToCommitted(rig, 1500)
  Assert.equal(committed.result, "win", "the night bout still settles as a win")
  for _ = 1, 600 do
    rig.pump(1)
    ackNarration(rig)
    if rig.battle:status().phase == "complete" then
      break
    end
  end
  Assert.equal(rig.battle:status().phase, "complete", "the withheld evolution still returns to the field")
  Assert.isNil(rig.screen:status().completion, "the closed bond offers no completion")
  Assert.equal(rig.party:partyMon(0).species, "PICHU", "the bond keeps its species outside its permitted time")
  rig.battle:dispose()
  rig.screen:dispose()
end

-- No clock means no invention: a launch without its frozen time of day
-- refuses to stage evolution instead of guessing a default.
function T.missing_launch_clock_refuses_evolution_planning()
  local BattleRuntime = require(RUNTIME_MODULE)
  local catalog = evolutionCatalogs(graftLevelSlot, false)
  local party = makePartyOwnerWith(catalog, {
    { species = "EEVEE", level = 9, below = true, moves = singleTackle() },
  })
  local ok, failure = pcall(BattleRuntime.new, {
    request = { id = "launch-clockless", kind = "wild", payload = { species = "EEVEE", level = 3 } },
    party = party,
    seed = 0x12345678,
    evolutionContext = { mapId = 7 },
  })
  Assert.isFalse(ok, "a clockless launch context never builds: " .. tostring(failure))
end

-- The shed side product publishes atomically: one evolved primary, one
-- permitted extra with its ball spent, and the original receipt intact.
function T.shed_side_product_publishes_with_its_ball_spent()
  local catalog, items = evolutionCatalogs(graftNincadaLine, false)
  local rig = openEvolutionRig({
    launchId = "launch-shed-side-product",
    catalog = catalog,
    itemCatalog = items,
    partySpecs = {
      { species = "NINCADA", level = 19, below = true, moves = singleTackle() },
    },
    bag = makeStockedBag(items, { { key = "POKE_BALL", quantity = 3 } }),
    evolutionContext = { timeOfDay = "day", mapId = 7 },
  })
  local committed = driveToCommitted(rig, 1500)
  local receipt = assert(committed.outcomeReceipt, "completion carries its commit receipt")
  driveToEvolution(rig, 1200)
  runEvolutionHandsFree(rig, 1500)
  Assert.equal(rig.battle:status().phase, "complete", "the shed line still returns to the field")
  Assert.equal(rig.party:partyMon(0).species, "NINJASK", "the primary stages its evolved species")
  Assert.equal(rig.party:partyCount(), 2, "the permitted extra joins the party exactly once")
  Assert.equal(rig.party:partyMon(1).species, "SHEDINJA", "the extra is the shed side product")
  Assert.equal(rig.bag:quantity("POKE_BALL"), 2, "the side product spends exactly one spare ball")
  Assert.deepEqual(rig.battle:status().outcomeReceipt, receipt, "the side product never republishes rewards")
  rig.battle:dispose()
  rig.screen:dispose()
end

-- Retail registers the evolved mon as caught on publication, and the shed
-- side product with it: one atomic commit lands the evolved primary, the
-- extra, and both caught flags while the abandoned pre-evolution species
-- stays uncaught.
function T.evolution_registers_the_evolved_mon_and_its_side_product_as_caught()
  local catalog, items = evolutionCatalogs(graftNincadaLine, false)
  local dex = dexOwnerFor(catalog)
  local rig = openEvolutionRig({
    launchId = "launch-evolution-registers-caught",
    catalog = catalog,
    itemCatalog = items,
    partySpecs = {
      { species = "NINCADA", level = 19, below = true, moves = singleTackle() },
    },
    bag = makeStockedBag(items, { { key = "POKE_BALL", quantity = 3 } }),
    evolutionContext = { timeOfDay = "day", mapId = 7 },
    dex = dex,
  })
  Assert.isFalse(dex:isCaught("NINJASK"), "setup: the evolved species starts uncaught")
  Assert.isFalse(dex:isCaught("SHEDINJA"), "setup: the side product starts uncaught")
  driveToCommitted(rig, 1500)
  driveToEvolution(rig, 1200)
  runEvolutionHandsFree(rig, 1500)
  Assert.equal(rig.battle:status().phase, "complete", "the registered evolution still returns to the field")
  Assert.equal(rig.party:partyMon(0).species, "NINJASK", "the primary stages its evolved species")
  Assert.equal(rig.party:partyCount(), 2, "the permitted extra joins the party exactly once")
  Assert.isTrue(dex:isCaught("NINJASK"), "publication registers the evolved mon as caught")
  Assert.isTrue(dex:isCaught("SHEDINJA"), "publication registers the shed side product as caught")
  Assert.isFalse(
    dex:isCaught("NINCADA"),
    "publication registers only the evolved mon and its side product"
  )
  rig.battle:dispose()
  rig.screen:dispose()
end

-- A fled outcome still queues the leveled member: retail checks evolution
-- after flights as well as wins and captures, so the fled word passes the
-- same eligibility gate over the committed party.
function T.fled_outcome_queues_the_leveled_member()
  local catalog = evolutionCatalogs(graftLevelSlot, false)
  local rig = openEvolutionRig({
    launchId = "launch-fled-queues-evolution",
    catalog = catalog,
    itemCatalog = ItemFixture.makeCatalog(),
    partySpecs = {
      { species = "EEVEE", level = 9, below = true, moves = singleTackle() },
    },
    evolutionContext = { timeOfDay = "day", mapId = 7 },
  })
  local live = rig.party:partyMon(0)
  local species = catalog:species(live.species)
  local curve = catalog:growthCurve(species.growthCurve)
  local staged = deepCopy(live)
  staged.experience = Experience.expFor(curve, 10)
  local prep, reason = rig.party:preparePartyChanges(rig.party:partyRevision(), { { slot = 0, mon = staged } })
  Assert.notNil(prep, "the level gain stages: " .. tostring(reason))
  assert(prep ~= nil, "the level gain stages")
  Assert.isTrue(prep.isCurrent(), "the level gain stays current")
  prep.publish()
  rig.battle._result = "flee"
  rig.battle:_buildEvolutions()
  local queued = rig.battle._completions
  Assert.equal(#queued, 1, "the fled outcome queues exactly one evolution")
  Assert.equal(queued[1].kind, "evolution", "the queued completion names the evolution decision")
  Assert.equal(queued[1].partySlot, 0, "the queued completion names the leveled slot")
  rig.battle:dispose()
  rig.screen:dispose()
end

-- A stale owner between commit and publication changes nothing live: the
-- evolved record never lands, the concurrent bag change survives, the
-- committed receipt still stands, and the lifetime still returns safely.
function T.stale_evolution_staging_changes_no_live_owner()
  local catalog, items = evolutionCatalogs(graftNincadaLine, false)
  local rig = openEvolutionRig({
    launchId = "launch-stale-evolution",
    catalog = catalog,
    itemCatalog = items,
    partySpecs = {
      { species = "NINCADA", level = 19, below = true, moves = singleTackle() },
    },
    bag = makeStockedBag(items, { { key = "POKE_BALL", quantity = 3 } }),
    evolutionContext = { timeOfDay = "day", mapId = 7 },
  })
  local committed = driveToCommitted(rig, 1500)
  local receipt = assert(committed.outcomeReceipt, "completion carries its commit receipt")
  Assert.isTrue(rig.bag:add("POKE_BALL", 1), "setup: a concurrent live change moves the bag owner")
  runEvolutionHandsFree(rig, 1500)
  Assert.equal(rig.battle:status().phase, "complete", "the refused evolution still returns to the field")
  Assert.equal(rig.party:partyMon(0).species, "NINCADA", "the stale evolution never lands its record")
  Assert.equal(rig.party:partyCount(), 1, "the stale evolution stages no side product")
  Assert.equal(rig.bag:quantity("POKE_BALL"), 4, "the concurrent bag change survives untouched")
  Assert.deepEqual(rig.battle:status().outcomeReceipt, receipt, "the refused pass never republishes rewards")
  Assert.notNil(rig.battle:status().completionError, "the refused staging stays visible on the status")
  rig.battle:dispose()
  rig.screen:dispose()
end

-- A stale evolution changes no live owner, dex included: the evolved
-- record never lands, the concurrent bag change survives, and neither
-- caught flag is set.
function T.stale_evolution_registers_no_caught_flags()
  local catalog, items = evolutionCatalogs(graftNincadaLine, false)
  local dex = dexOwnerFor(catalog)
  local rig = openEvolutionRig({
    launchId = "launch-stale-evolution-registers-nothing",
    catalog = catalog,
    itemCatalog = items,
    partySpecs = {
      { species = "NINCADA", level = 19, below = true, moves = singleTackle() },
    },
    bag = makeStockedBag(items, { { key = "POKE_BALL", quantity = 3 } }),
    evolutionContext = { timeOfDay = "day", mapId = 7 },
    dex = dex,
  })
  local committed = driveToCommitted(rig, 1500)
  local receipt = assert(committed.outcomeReceipt, "completion carries its commit receipt")
  Assert.isTrue(rig.bag:add("POKE_BALL", 1), "setup: a concurrent live change moves the bag owner")
  runEvolutionHandsFree(rig, 1500)
  Assert.equal(rig.battle:status().phase, "complete", "the refused evolution still returns to the field")
  Assert.equal(rig.party:partyMon(0).species, "NINCADA", "the stale evolution never lands its record")
  Assert.equal(rig.party:partyCount(), 1, "the stale evolution stages no side product")
  Assert.isFalse(dex:isCaught("NINJASK"), "the refused evolution registers no primary flag")
  Assert.isFalse(dex:isCaught("SHEDINJA"), "the refused evolution registers no side-product flag")
  Assert.deepEqual(rig.battle:status().outcomeReceipt, receipt, "the refused pass never republishes rewards")
  Assert.notNil(rig.battle:status().completionError, "the refused staging stays visible on the status")
  rig.battle:dispose()
  rig.screen:dispose()
end

-- Replayed ticks after settlement publish nothing more: one primary, one
-- permitted extra, and stable stock no matter how long the return waits.
function T.settled_evolution_ignores_replayed_ticks()
  local catalog, items = evolutionCatalogs(graftNincadaLine, false)
  local rig = openEvolutionRig({
    launchId = "launch-evolution-replay",
    catalog = catalog,
    itemCatalog = items,
    partySpecs = {
      { species = "NINCADA", level = 19, below = true, moves = singleTackle() },
    },
    bag = makeStockedBag(items, { { key = "POKE_BALL", quantity = 3 } }),
    evolutionContext = { timeOfDay = "day", mapId = 7 },
  })
  driveToCommitted(rig, 1500)
  driveToEvolution(rig, 1200)
  runEvolutionHandsFree(rig, 1500)
  Assert.equal(rig.battle:status().phase, "complete", "setup: the evolution settles first")
  for _ = 1, 60 do
    rig.pump(1)
  end
  Assert.equal(rig.party:partyMon(0).species, "NINJASK", "replayed ticks keep the single evolved primary")
  Assert.equal(rig.party:partyCount(), 2, "replayed ticks stage no second extra")
  Assert.equal(rig.bag:quantity("POKE_BALL"), 2, "replayed ticks spend no second ball")
  rig.battle:dispose()
  rig.screen:dispose()
end

-- A declined first member still yields to the second: cancel during the
-- permitted sequence publishes nothing for the first while the next
-- leveled member still receives its own opportunity.
function T.cancelled_first_member_yields_to_the_second()
  local catalog = evolutionCatalogs(graftLevelSlot, false)
  local rig = openEvolutionRig({
    launchId = "launch-cancel-yields",
    catalog = catalog,
    itemCatalog = ItemFixture.makeCatalog(),
    partySpecs = {
      { species = "EEVEE", level = 9, below = true, moves = singleTackle() },
      { species = "EEVEE", level = 9, below = true, moves = singleTackle() },
    },
    evolutionContext = { timeOfDay = "day", mapId = 7 },
  })
  -- Both members see combat: the lead strikes once, the reserve swaps in
  -- and finishes the bout, so both genuinely earn their level.
  local turns = 0
  for _ = 1, 1500 do
    rig.pump(1)
    ackNarration(rig)
    local current = rig.battle:status()
    if current.phase == "failed" then
      error("the evolution battle failed: " .. tostring(current.error), 0)
    end
    if current.phase == "running" and current.request ~= nil then
      turns = turns + 1
      local request = current.request --[[@as table<string, unknown>]]
      local options = rig.battle:decisionOptions(request.requestId)
      Assert.notNil(options, "every answered turn projects its options")
      assert(options ~= nil, "the swap turn projects its options")
      local fragment = nil
      local wanted = turns == 2 and "switch" or "attack"
      for _, actor in ipairs(options.actors) do
        for _, choice in ipairs(actor.choices or {}) do
          if choice.enabled == true and type(choice.choice) == "table" and choice.choice.kind == wanted then
            fragment = fragment or choice.choice
          end
        end
      end
      Assert.notNil(fragment, "turn " .. turns .. " offers its " .. wanted)
      local accepted, replyErr = rig.battle:submit(SessionFixture.replyFor(request, { fragment }))
      Assert.isTrue(accepted, "turn " .. turns .. " is accepted: " .. tostring(replyErr))
    end
    if current.outcomeReceipt ~= nil and current.outcomeReceipt.committed == true then
      break
    end
  end
  Assert.notNil(rig.battle:status().outcomeReceipt, "the swapped bout publishes its commit receipt")
  local first = driveToEvolution(rig, 1200)
  local firstId = assert(first.completionId, "the offered evolution carries its completion identity")
  -- Retail honors cancel only during the transformation beat and drops
  -- earlier presses, so mash B while the first completion stays open: the
  -- press landing on the transformation beat declines it and yields.
  local secondOffered = false
  for _ = 1, 1500 do
    local open = rig.screen:status().completion
    if type(open) == "table" and open.kind == "evolution" and open.completionId == firstId then
      rig.screen:input({ { type = "cancel" } })
    end
    rig.pump(1)
    ackNarration(rig)
    local completion = rig.screen:status().completion
    if type(completion) == "table" and completion.kind == "evolution" and completion.completionId ~= firstId then
      secondOffered = true
      break
    end
    if rig.battle:status().phase == "complete" then
      break
    end
  end
  Assert.isTrue(secondOffered, "declining the first member still offers the second")
  runEvolutionHandsFree(rig, 1500)
  Assert.equal(rig.battle:status().phase, "complete", "the yielded sequence still returns to the field")
  Assert.equal(rig.party:partyMon(0).species, "EEVEE", "the declined member publishes nothing")
  Assert.equal(rig.party:partyMon(1).species, "TOTODILE", "the second member still receives its opportunity")
  rig.battle:dispose()
  rig.screen:dispose()
end

-- A declined evolution publishes nothing, dex included: the member keeps
-- its species and the evolved flag stays unset.
function T.declined_evolution_registers_no_caught_flag()
  local catalog = evolutionCatalogs(graftLevelSlot, false)
  local dex = dexOwnerFor(catalog)
  local rig = openEvolutionRig({
    launchId = "launch-decline-registers-nothing",
    catalog = catalog,
    itemCatalog = ItemFixture.makeCatalog(),
    partySpecs = {
      { species = "EEVEE", level = 9, below = true, moves = singleTackle() },
    },
    evolutionContext = { timeOfDay = "day", mapId = 7 },
    dex = dex,
  })
  driveToCommitted(rig, 1500)
  local offered = driveToEvolution(rig, 1200)
  local offeredId = assert(offered.completionId, "the offered evolution carries its completion identity")
  -- Retail honors cancel only during the transformation beat and drops
  -- earlier presses, so mash B while the single completion stays open the
  -- same way the yielded-sequence test declines its first member.
  for _ = 1, 1500 do
    local open = rig.screen:status().completion
    if type(open) == "table" and open.kind == "evolution" and open.completionId == offeredId then
      rig.screen:input({ { type = "cancel" } })
    end
    rig.pump(1)
    ackNarration(rig)
    if rig.battle:status().phase == "complete" then
      break
    end
    if rig.battle:status().phase == "failed" then
      error("the declined evolution failed: " .. tostring(rig.battle:status().error), 0)
    end
  end
  Assert.equal(rig.battle:status().phase, "complete", "the declined evolution still returns to the field")
  Assert.equal(rig.party:partyMon(0).species, "EEVEE", "the declined member publishes nothing")
  Assert.isFalse(dex:isCaught("TOTODILE"), "the declined evolution registers no caught flag")
  rig.battle:dispose()
  rig.screen:dispose()
end

-- Counts one fresh species per registered mon through the live owner.
---@param owner table live game-stats owner under preparation
---@param speciesList string[] admitted species keys under counting
local function countSpecies(owner, speciesList)
  local GameStats = require("libs.hgss.src.mons.GameStats")
  local observations = {}
  for _, key in ipairs(speciesList) do
    observations[#observations + 1] = { kind = "unique_caught", species = key }
    observations[#observations + 1] = {
      kind = "score",
      species = key,
      event = GameStats.SCORE_EVENT_REGISTER_SPECIES_CAUGHT,
      points = GameStats.SCORE_POINTS[GameStats.SCORE_EVENT_REGISTER_SPECIES_CAUGHT],
    }
  end
  owner:prepareChanges({ observations = observations }):publish()
end

-- Evolution publication is the first stats producer: one atomic commit
-- lands the evolved primary, the shed side product, both dex caught
-- flags, both unique counts, and both register scores, while the
-- abandoned pre-evolution species stays uncounted.
function T.evolution_publish_counts_unique_and_scores_once_with_dex()
  local catalog, items = evolutionCatalogs(graftNincadaLine, false)
  local dex = dexOwnerFor(catalog)
  local stats = statsOwnerFor(catalog)
  local rig = openEvolutionRig({
    launchId = "launch-evolution-counts-stats",
    catalog = catalog,
    itemCatalog = items,
    partySpecs = {
      { species = "NINCADA", level = 19, below = true, moves = singleTackle() },
    },
    bag = makeStockedBag(items, { { key = "POKE_BALL", quantity = 3 } }),
    evolutionContext = { timeOfDay = "day", mapId = 7 },
    dex = dex,
    stats = stats,
  })
  Assert.equal(stats:uniqueCount(), 0, "setup: nothing is counted before publication")
  Assert.equal(stats:score(), 0, "setup: the score starts at zero")
  driveToCommitted(rig, 1500)
  driveToEvolution(rig, 1200)
  runEvolutionHandsFree(rig, 1500)
  Assert.equal(rig.battle:status().phase, "complete", "the counted evolution still returns to the field")
  Assert.equal(rig.party:partyMon(0).species, "NINJASK", "the primary stages its evolved species")
  Assert.isTrue(dex:isCaught("NINJASK"), "the joint publication registers the evolved dex flag")
  Assert.isTrue(dex:isCaught("SHEDINJA"), "the joint publication registers the side-product dex flag")
  Assert.isTrue(stats:isCounted("NINJASK"), "publication counts the evolved mon once")
  Assert.isTrue(stats:isCounted("SHEDINJA"), "publication counts the shed side product once")
  Assert.isFalse(stats:isCounted("NINCADA"), "publication counts only the evolved mon and its side product")
  Assert.equal(stats:uniqueCount(), 2, "publication counts exactly the two fresh species")
  Assert.equal(stats:score(), registerPoints() * 2, "publication awards one register score per fresh species")
  rig.battle:dispose()
  rig.screen:dispose()
end

-- A re-publish of already-counted species recounts blindly like retail:
-- every completed evolution re-runs its register increment and score
-- (EVO_STATE_REGISTER + shed side product, unconditional). The joint
-- publication still lands party and dex history; the unique total
-- increments again and the score awards again per subject.
function T.duplicate_species_republish_counts_again_blindly()
  local catalog, items = evolutionCatalogs(graftNincadaLine, false)
  local stats = statsOwnerFor(catalog)
  countSpecies(stats, { "NINJASK", "SHEDINJA" })
  local rig = openEvolutionRig({
    launchId = "launch-evolution-duplicate-scores-again",
    catalog = catalog,
    itemCatalog = items,
    partySpecs = {
      { species = "NINCADA", level = 19, below = true, moves = singleTackle() },
    },
    bag = makeStockedBag(items, { { key = "POKE_BALL", quantity = 3 } }),
    evolutionContext = { timeOfDay = "day", mapId = 7 },
    stats = stats,
  })
  driveToCommitted(rig, 1500)
  driveToEvolution(rig, 1200)
  runEvolutionHandsFree(rig, 1500)
  Assert.equal(rig.battle:status().phase, "complete", "the duplicate evolution still returns to the field")
  Assert.equal(rig.party:partyMon(0).species, "NINJASK", "the duplicate evolution still lands its record")
  Assert.equal(stats:uniqueCount(), 4, "the re-publish increments the blind total again")
  Assert.equal(stats:score(), registerPoints() * 4, "the re-publish awards its register points again")
  rig.battle:dispose()
  rig.screen:dispose()
end

-- A declined evolution publishes nothing, counts included: the member
-- keeps its species and the score stays at zero.
function T.declined_evolution_counts_nothing()
  local catalog = evolutionCatalogs(graftLevelSlot, false)
  local stats = statsOwnerFor(catalog)
  local rig = openEvolutionRig({
    launchId = "launch-decline-counts-nothing",
    catalog = catalog,
    itemCatalog = ItemFixture.makeCatalog(),
    partySpecs = {
      { species = "EEVEE", level = 9, below = true, moves = singleTackle() },
    },
    evolutionContext = { timeOfDay = "day", mapId = 7 },
    stats = stats,
  })
  driveToCommitted(rig, 1500)
  local offered = driveToEvolution(rig, 1200)
  local offeredId = assert(offered.completionId, "the offered evolution carries its completion identity")
  for _ = 1, 1500 do
    local open = rig.screen:status().completion
    if type(open) == "table" and open.kind == "evolution" and open.completionId == offeredId then
      rig.screen:input({ { type = "cancel" } })
    end
    rig.pump(1)
    ackNarration(rig)
    if rig.battle:status().phase == "complete" then
      break
    end
    if rig.battle:status().phase == "failed" then
      error("the declined evolution failed: " .. tostring(rig.battle:status().error), 0)
    end
  end
  Assert.equal(rig.battle:status().phase, "complete", "the declined evolution still returns to the field")
  Assert.equal(rig.party:partyMon(0).species, "EEVEE", "the declined member publishes nothing")
  Assert.equal(stats:uniqueCount(), 0, "the declined evolution counts nothing")
  Assert.equal(stats:score(), 0, "the declined evolution awards no points")
  rig.battle:dispose()
  rig.screen:dispose()
end

-- A stale evolution changes no live owner, counts included: the evolved
-- record never lands, the concurrent bag change survives, and neither
-- the unique count nor the score moves.
function T.stale_evolution_counts_nothing()
  local catalog, items = evolutionCatalogs(graftNincadaLine, false)
  local stats = statsOwnerFor(catalog)
  local rig = openEvolutionRig({
    launchId = "launch-stale-evolution-counts-nothing",
    catalog = catalog,
    itemCatalog = items,
    partySpecs = {
      { species = "NINCADA", level = 19, below = true, moves = singleTackle() },
    },
    bag = makeStockedBag(items, { { key = "POKE_BALL", quantity = 3 } }),
    evolutionContext = { timeOfDay = "day", mapId = 7 },
    stats = stats,
  })
  local committed = driveToCommitted(rig, 1500)
  local receipt = assert(committed.outcomeReceipt, "completion carries its commit receipt")
  Assert.isTrue(rig.bag:add("POKE_BALL", 1), "setup: a concurrent live change moves the bag owner")
  runEvolutionHandsFree(rig, 1500)
  Assert.equal(rig.battle:status().phase, "complete", "the refused evolution still returns to the field")
  Assert.equal(rig.party:partyMon(0).species, "NINCADA", "the stale evolution never lands its record")
  Assert.equal(stats:uniqueCount(), 0, "the refused evolution counts nothing")
  Assert.equal(stats:score(), 0, "the refused evolution awards no points")
  Assert.deepEqual(rig.battle:status().outcomeReceipt, receipt, "the refused pass never republishes rewards")
  Assert.notNil(rig.battle:status().completionError, "the refused staging stays visible on the status")
  rig.battle:dispose()
  rig.screen:dispose()
end

-- The battle-capture lane scores its fresh species exactly once and never
-- counts it unique: one committed capture lands one register score while
-- the unique counter stays put (retail receipt paths never advance it).
function T.battle_capture_publish_scores_without_counting_unique()
  local catalog = evolutionCatalogs(graftLevelSlot, false)
  local stats = statsOwnerFor(catalog)
  local rig = openEvolutionRig({
    launchId = "launch-capture-scores-stats",
    catalog = catalog,
    itemCatalog = ItemFixture.makeCatalog(),
    partySpecs = {
      { species = "EEVEE", level = 9, below = true, moves = singleTackle() },
    },
    evolutionContext = { timeOfDay = "day", mapId = 7 },
    stats = stats,
    captures = { { captureId = "stats-catch-1", success = true, mon = makeFoe(catalog, "EEVEE", 3) } },
  })
  local committed = driveToCommitted(rig, 1500)
  Assert.equal(committed.result, "win", "the capture bout still settles as a win")
  Assert.isTrue(stats:isCounted("EEVEE"), "the capture publication registers the scored species")
  Assert.equal(stats:uniqueCount(), 0, "the capture publication advances no unique count")
  Assert.equal(stats:score(), registerPoints(), "the capture publication awards one register score")
  rig.battle:dispose()
  rig.screen:dispose()
end

-- A capture of an already-counted species stages nothing: the commit
-- still retains the caught mon while unique counts and score stay put.
function T.duplicate_capture_counts_nothing()
  local catalog = evolutionCatalogs(graftLevelSlot, false)
  local stats = statsOwnerFor(catalog)
  countSpecies(stats, { "EEVEE" })
  local rig = openEvolutionRig({
    launchId = "launch-duplicate-capture-counts-nothing",
    catalog = catalog,
    itemCatalog = ItemFixture.makeCatalog(),
    partySpecs = {
      { species = "EEVEE", level = 9, below = true, moves = singleTackle() },
    },
    evolutionContext = { timeOfDay = "day", mapId = 7 },
    stats = stats,
    captures = { { captureId = "stats-catch-2", success = true, mon = makeFoe(catalog, "EEVEE", 3) } },
  })
  driveToCommitted(rig, 1500)
  Assert.equal(stats:uniqueCount(), 1, "the duplicate capture counts nothing twice")
  Assert.equal(stats:score(), registerPoints(), "the duplicate capture awards no further points")
  rig.battle:dispose()
  rig.screen:dispose()
end

function T.soulsilver_variant_stays_blocked_without_its_owned_cache(context)
  local GameVersion = require("romdump.src.source.GameVersion")
  local RomImporter = require("romdump.src.source.RomImporter")
  local known = false
  for _, versionId in ipairs(GameVersion.ORDER) do
    if versionId == "soulsilver" then
      known = true
    end
  end
  Assert.isTrue(known, "setup: the second version is a known parity dimension")
  if not RomImporter.isReady("soulsilver") then
    context:skip(
      "BLOCKED: no ready soulsilver user-owned ROM cache in this checkout; second-version evolution parity is unverified"
    )
  end
  Assert.isTrue(
    false,
    "a ready soulsilver cache appeared: this probe must grow a real second-version comparison before it may pass"
  )
end

return { tests = T }
