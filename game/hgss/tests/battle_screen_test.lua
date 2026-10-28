-- One interactive battle screen over the real application runtime: player
-- commands reach the kernel exactly once through semantic input, paired
-- panes honor the native source regions, visible cues drain in event
-- order independently of host drawing, and definitions plus resource
-- leases follow single ownership with explicit failure.
--
-- These scenarios drive the real battle lifetime (real scenario factory,
-- real native session, real committer) through the real screen and its
-- presentation port, with paired display measurements and recording
-- graphics/audio doubles. Fixtures are synthetic only, so the run needs
-- no dump capabilities. Each scenario first names its missing screen
-- owner, so the run stays red until that owner lands.

local Assert = require("tests.support.Assert")
local BattlePresentationManifestFixture = require("tests.support.BattlePresentationManifestFixture")
local BattlePresentationSchema = require("libs.assets.src.battle.BattlePresentationSchema")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local FakeGraphics = require("tests.support.FakeGraphics")
local HgssBagService = require("libs.hgss.src.items.HgssBagService")
local ItemFixture = require("libs.items.tests.item_fixture")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")
local ScreenTopology = require("libs.ui.src.ScreenTopology")
local SourceTick = require("libs.hgss.src.field.SourceTick")

local T = {}

local STATE_MODULE = "game.hgss.src.battle.BattleScreenState"
local TIMELINE_MODULE = "game.hgss.src.battle.BattleTimeline"
local INTERFACE_MODULE = "game.hgss.src.battle.BattleScreenInterface"
local RENDERER_MODULE = "game.hgss.src.battle.BattleRenderer"
local ASSETS_MODULE = "game.hgss.src.battle.BattlePresentationAssets"
local MODEL_MODULE = "game.hgss.src.battle.BattlePresentationModel"
local RUNTIME_MODULE = "game.hgss.src.battle.BattleRuntime"
local SCENARIO_FACTORY_MODULE = "libs.hgss.src.battle.HgssBattleScenarioFactory"
local PRESENTATION_CACHE_MODULE = "libs.assets.src.battle.BattlePresentationCache"

local TICK = SourceTick.DT

---@param behavior string the missing screen responsibility naming this red
---@param primary string the scenario's own missing owner, loaded first so the red names it
---@return table the five battle screen owners plus the detached view model
local function battleScreenModules(behavior, primary)
  local function load(name, role)
    local ok, loaded = pcall(require, name)
    Assert.isTrue(ok, "the battle screen owns " .. role .. ": " .. behavior .. " (" .. name .. ")")
    return assert(loaded, "the battle screen owner loads: " .. name)
  end
  local owners = {
    [STATE_MODULE] = "the interactive command controller",
    [TIMELINE_MODULE] = "the ordered visible-state cue player",
    [INTERFACE_MODULE] = "the paired plan resolver",
    [RENDERER_MODULE] = "the source-backed paired drawing",
    [ASSETS_MODULE] = "the per-launch preparation leases",
    [MODEL_MODULE] = "the detached opening and packet views",
  }
  local modules = {}
  local keys = {
    state = STATE_MODULE,
    timeline = TIMELINE_MODULE,
    interface = INTERFACE_MODULE,
    renderer = RENDERER_MODULE,
    assets = ASSETS_MODULE,
    model = MODEL_MODULE,
  }
  local first = nil
  for key, name in pairs(keys) do
    if name == primary then
      first = key
    end
  end
  if first ~= nil then
    modules[first] = load(primary, owners[primary])
  end
  for key, name in pairs(keys) do
    if modules[key] == nil then
      modules[key] = load(name, owners[name])
    end
  end
  return modules
end

---@param record table<string, unknown> full mon-domain record under test preparation
---@return table<string, unknown> the same record striking with a single known move
---@param move string? staged move identity, a basic strike when absent
---@param pp integer? staged power points, full when absent
local function tackleOnly(record, move, pp)
  record.moves = { { move = move or "TACKLE", pp = pp == nil and 35 or pp, ppUps = 0 } }
  return record --[[@as table<string, unknown>]]
end

---@param species string catalog species key under test preparation
---@param level integer battle level under test preparation
---@param seed integer fixed generator state under test preparation
---@return table full mon-domain record
local function foeRecord(species, level, seed)
  local catalog = CatalogFixture.makeCatalog()
  local factory = CatalogFixture.makeFactory(seed, catalog)
  return tackleOnly(factory:createNormal(CatalogFixture.normalRequest({ species = species, level = level })))
end

---@param spec table lead/reserve description under test preparation
---@return table live party owner holding the described pair
local function makeParty(leadSpec, reserveSpec)
  local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
  local catalog = CatalogFixture.makeCatalog()
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
  for _, member in ipairs({ leadSpec, reserveSpec }) do
    local factory = CatalogFixture.makeFactory(member.seed, catalog)
    local req = { species = member.species, level = member.level }
    if member.ability ~= nil then
      req.ability = member.ability
    end
    local record = tackleOnly(factory:createNormal(CatalogFixture.normalRequest(req)), member.move, member.pp)
    Assert.isTrue(owner:addMon(record), "the screen path needs its live party member")
  end
  return owner
end

---@param id string launch identity under test preparation
---@return table wild launch request carrying the required species payload
local function wildLaunch(id)
  return {
    id = id,
    kind = "wild",
    payload = {
      attemptId = id .. "-attempt",
      species = "EEVEE",
      form = 0,
      level = 4,
      personality = 1,
      ability = "RUN_AWAY",
    },
  }
end

---@param first table main/world surface description under test preparation
---@param second table lower/auxiliary surface description under test preparation
---@param signature string stable measurement identity under test preparation
---@return table caller-owned paired display facts
local function pairedMeasurement(first, second, signature)
  return {
    width = first.rect.width,
    height = first.rect.height + second.rect.height,
    topology = ScreenTopology.dualDisplay(first, second),
    pixelRatio = 1,
    signature = signature,
  }
end

---@return table caller-owned dual-surface display facts with a 256x192 detail pane over a 256x192 interaction pane
local function dualMeasurement()
  return pairedMeasurement(
    { id = "main", rect = { x = 0, y = 0, width = 256, height = 192 }, touch = false, role = "world" },
    { id = "lower", rect = { x = 0, y = 192, width = 256, height = 192 }, touch = true, role = "auxiliary" },
    "battle-screen-test:dual"
  )
end

---@return table caller-owned single wide surface display facts
local function wideMeasurement()
  return {
    width = 512,
    height = 192,
    topology = ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = 512, height = 192 },
      touch = true,
      role = "world",
    }),
    pixelRatio = 1,
    signature = "battle-screen-test:wide",
  }
end

---@return table caller-owned single tiny surface display facts that cannot fit a paired pane at 1x
local function tinyMeasurement()
  return {
    width = 100,
    height = 60,
    topology = ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = 100, height = 60 },
      touch = true,
      role = "world",
    }),
    pixelRatio = 1,
    signature = "battle-screen-test:tiny",
  }
end

---@param muted boolean? when true playback stays silent while still recording
---@return table recording semantic sound boundary with per-name counts
local function recordingAudio(muted)
  local audio = { plays = {}, stops = {}, muted = muted == true }
  function audio.play(first, second)
    -- The production voice subsystem dispatches sink ports colon-style,
    -- so the recorded semantic cue is the second argument when present.
    -- Muted playback still accepts every voice (silently): unavailability
    -- is modeled by absent ports, never by a muted answer, so muted
    -- cues drain instead of failing the screen.
    audio.plays[#audio.plays + 1] = second ~= nil and second or first
    return true
  end
  function audio.playPanned(_, symbol, pan)
    audio.plays[#audio.plays + 1] = symbol
    audio.pans = audio.pans or {}
    audio.pans[#audio.pans + 1] = { symbol = symbol, pan = pan }
    return true
  end
  function audio.playFanfare(_, symbol)
    audio.plays[#audio.plays + 1] = symbol
    return true
  end
  function audio.stop(_, symbol)
    audio.stops[#audio.stops + 1] = symbol
    return true
  end
  function audio.count(name)
    local total = 0
    for _, played in ipairs(audio.plays) do
      if played == name then
        total = total + 1
      end
    end
    return total
  end
  return audio
end

---@return table recording frame-drawing boundary keyed by selected frame name
local function recordingWindows()
  local windows = { calls = {} }
  function windows.drawWindow(box, frameKey, background)
    windows.calls[#windows.calls + 1] = { box = box, frame = frameKey, background = background }
  end
  function windows.frames()
    local seen = {}
    for _, call in ipairs(windows.calls) do
      seen[call.frame] = true
    end
    return seen
  end
  return windows
end

---@return table recording text-measurement boundary that stays usable for the whole test
local function recordingText()
  local text = { measures = 0, draws = 0, disposed = false, lastY = {} }
  function text.measure(content)
    text.measures = text.measures + 1
    return { width = 8 * #tostring(content), height = 16 }
  end
  function text.drawText(content, _x, y)
    text.draws = text.draws + 1
    text.lastY[tostring(content)] = y
  end
  return text
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
---@param width integer? staged image width, native default when absent
---@param height integer? staged image height, native default when absent
---@return table fake image handle carrying the renderer-required dimensions
local function fakeDrawable(key, width, height)
  local hudImage = key:match("^hud:") ~= nil
  return {
    handle = key,
    width = width or (hudImage and 1648 or 80),
    height = height or (hudImage and 8 or 80),
    getWidth = fakeImageWidth,
    getHeight = fakeImageHeight,
    getDimensions = fakeImageDimensions,
    setFilter = fakeImageSetFilter,
  }
end

---@param opts table? heldKeys: image keys reporting unavailable; failPrepare: preparation error; seedImages: pre-made handles
---@return table preparation double owning only the handles it hands out
local function stubAssets(opts)
  opts = opts or {}
  local held = {}
  for _, key in ipairs(opts.heldKeys or {}) do
    held[key] = true
  end
  local assets = {
    hold = held,
    failPrepare = opts.failPrepare,
    images = opts.seedImages or {},
    prepared = {},
    released = {},
  }
  function assets.prepare(demand)
    if assets.failPrepare ~= nil then
      return nil, assets.failPrepare
    end
    assets.prepared[#assets.prepared + 1] = demand
    return true
  end
  function assets.drawable(key)
    if assets.hold[key] then
      return nil
    end
    if assets.images[key] == nil then
      assets.images[key] = fakeDrawable(key)
    end
    return assets.images[key]
  end
  function assets.release(key)
    assets.released[key] = (assets.released[key] or 0) + 1
  end
  function assets.releaseCount(key)
    return assets.released[key] or 0
  end
  return assets
end

---@param sceneKey string semantic scene identity under test preparation
---@return table planning manifest carrying the scene inventory without staged files
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

---@param sceneKey string semantic scene identity under test preparation
---@return table detached schema-valid staged manifest carrying the requested scene
local function screenManifest(sceneKey)
  local background, terrain, time = sceneKey:match("^([^/]+)/([^/]+)/([^/]+)$")
  assert(
    background ~= nil and terrain ~= nil and time ~= nil,
    "the screen fixture needs a background/terrain/time scene key"
  )
  local manifest = deepCopy(BattlePresentationManifestFixture.manifest())
  manifest.scenes = { { key = sceneKey, background = background, terrain = terrain, time = time } }
  BattlePresentationSchema.assertManifest(manifest)
  return manifest
end

---@return string a valid semantic scene key assembled from the real presentation inventory
local function testSceneKey()
  local Cache = require(PRESENTATION_CACHE_MODULE)
  return Cache.sceneKey(Cache.BACKGROUNDS[1], Cache.TERRAINS[1], Cache.TIMES[1])
end

---@param modules table loaded screen owners under test driving
---@param opts table rig options: launchId, scenario, party, bag, seed, measurement, assets, audio, windows, text, overrides
---@return table live rig with the runtime, screen, port tap, and submit log
local function openRig(modules, opts)
  local BattleRuntime = require(RUNTIME_MODULE)
  local holder = {}
  local rig = {
    submits = {},
    measurement = opts.measurement,
    audio = opts.audio or recordingAudio(false),
    windows = opts.windows or recordingWindows(),
    text = opts.text or recordingText(),
    assets = opts.assets or stubAssets({}),
  }
  local sceneKey = testSceneKey()
  if opts.overrides ~= nil and opts.overrides.sceneKey ~= nil then
    sceneKey = opts.overrides.sceneKey
  end
  local screen = modules.state.new({
    launchId = opts.launchId,
    manifest = opts.manifest or screenManifest(sceneKey),
    model = modules.model,
    submit = function(reply)
      rig.submits[#rig.submits + 1] = reply
      return holder.battle:submit(reply)
    end,
    measureDisplay = function()
      return rig.measurement
    end,
    -- The battle screen borrows the immutable item catalog so its bag
    -- child can group stocked items by pocket, exactly like production.
    itemCatalog = ItemFixture.makeCatalog(),
    monCatalog = CatalogFixture.makeCatalog(),
    assets = rig.assets,
    text = rig.text,
    windows = rig.windows,
    audio = rig.audio,
    overrides = opts.overrides,
  })
  rig.screen = screen
  rig.port = screen:presentationPort()
  holder.battle = BattleRuntime.new({
    request = opts.launch,
    scenario = opts.scenario,
    party = opts.party,
    bag = opts.bag,
    presentation = rig.port,
    seed = opts.seed or 0x12345678,
  })
  rig.battle = holder.battle
  function rig.pump(ticks, dt)
    for _ = 1, ticks or 1 do
      rig.battle:update()
      rig.screen:updateFixed(dt or TICK)
    end
  end
  return rig
end

---@param rig table live screen rig under test driving
---@return table the real wild scenario context for the rig parties
local function wildContext(rig)
  return {
    party = rig.party,
    bag = rig.bag,
    player = {
      trainerId = 99,
      trainerName = "MINT",
      trainerClassKey = "PKMN_TRAINER_ETHAN",
      language = "french",
    },
  }
end

---@param modules table loaded screen owners under test driving
---@param id string launch identity under test driving
---@param leadSpec table lead description under test driving
---@param reserveSpec table reserve description under test driving
---@param foe table foe record under test driving
---@param opts table? measurement/assets/audio/windows/overrides/seed
---@return table live rig with a wild battle behind the real screen
local function openWildRig(modules, id, leadSpec, reserveSpec, foe, opts)
  opts = opts or {}
  local ScenarioFactory = require(SCENARIO_FACTORY_MODULE)
  local party = makeParty(leadSpec, reserveSpec)
  local bag = HgssBagService.new({ catalog = ItemFixture.makeCatalog() })
  local launch = wildLaunch(id)
  local scenario = ScenarioFactory.fromEncounter({ attemptId = launch.id .. "-attempt", mon = foe }, {
    party = party,
    bag = bag,
    player = {
      trainerId = 99,
      trainerName = "MINT",
      trainerClassKey = "PKMN_TRAINER_ETHAN",
      language = "french",
    },
  })
  local rig = openRig(modules, {
    launchId = id,
    launch = launch,
    scenario = scenario,
    party = party,
    bag = bag,
    seed = opts.seed or 0x12345678,
    measurement = opts.measurement or dualMeasurement(),
    assets = opts.assets,
    audio = opts.audio,
    windows = opts.windows,
    text = opts.text,
    overrides = opts.overrides,
  })
  rig.party = party
  rig.bag = bag
  rig.scenario = scenario
  return rig
end

---@param rig table live screen rig under test driving
---@param mode string awaited controller mode under test driving
---@param budget integer maximum fixed ticks before the driver gives up
---@return table the screen status once the mode is reached
local function driveToMode(rig, mode, budget)
  for _ = 1, budget do
    rig.pump(1)
    local status = rig.screen:status()
    if status.mode == "failed" then
      error("the battle screen failed while driving to " .. mode .. ": " .. tostring(status.error), 0)
    end
    if status.mode == mode and (mode ~= "command" and mode ~= "moves" or rig.screen:view().menuInputEnabled) then
      return status
    end
  end
  error("the battle screen never reached " .. mode, 0)
end

---@param plan table resolved complete plan under inspection
---@return table pane placement by pane role for the paired composition
local function paneSizes(plan)
  local sizes = {}
  for _, pane in ipairs(assert(plan.panes, "the resolved plan carries its panes")) do
    sizes[#sizes + 1] = {
      width = pane.placement.logicalWidth,
      height = pane.placement.logicalHeight,
    }
  end
  return sizes
end

---@param graphics table recording graphics namespace under inspection
---@return string serialized draw shapes without image identities for redraw comparison
local function drawShapes(graphics)
  local parts = {}
  for _, entry in ipairs(graphics.draws) do
    parts[#parts + 1] = string.format(
      "%s:%s:%s:%s",
      tostring(entry.kind),
      tostring(entry.x),
      tostring(entry.y),
      tostring(entry.quad ~= nil)
    )
  end
  return table.concat(parts, "|")
end

---@param graphics table recording graphics namespace under inspection
---@return table borrowed state snapshot the draw must restore exactly
local function graphicsState(graphics)
  local r, g, b, a = graphics.getColor()
  return {
    color = { r, g, b, a },
    canvas = graphics.getCanvas(),
    shader = graphics.getShader(),
    blend = graphics.getBlendMode(),
    scissor = graphics.getScissor(),
    depth = graphics:pushDepth(),
  }
end

---@param value unknown
---@return string serialized shape without functions for privacy inspection
local function serializeShape(value)
  local parts = {}
  local function walk(node, depth)
    if depth > 6 then
      parts[#parts + 1] = "..."
      return
    end
    if type(node) ~= "table" then
      parts[#parts + 1] = tostring(node)
      return
    end
    parts[#parts + 1] = "{"
    local first = true
    for key, item in
      pairs(node --[[@as table<unknown, unknown>]])
    do
      if not first then
        parts[#parts + 1] = ","
      end
      first = false
      parts[#parts + 1] = tostring(key) .. "="
      walk(item, depth + 1)
    end
    parts[#parts + 1] = "}"
  end
  walk(value, 0)
  return table.concat(parts)
end

---@param rig table live screen rig under test driving
---@param x number host-unit horizontal pointer position under test driving
---@param y number host-unit vertical pointer position under test driving
local function tap(rig, x, y)
  rig.screen:input({ { type = "pointer_down", pointerId = "touch:0", x = x, y = y } })
  rig.screen:input({ { type = "pointer_up", pointerId = "touch:0", x = x, y = y } })
end

-- Collects every exact portrait selector the launch demanded through
-- the preparation boundary, in demand order. Demands name exact
-- canonical selectors only, never the generic side keys.
---@param rig table live screen rig under test driving
---@return string[] exact canonical portrait selectors demanded so far
local function demandedPortraits(rig)
  local selectors = {}
  local seen = {}
  for _, demand in ipairs(rig.assets.prepared) do
    for _, page in ipairs(type(demand) == "table" and demand.pages or {}) do
      if type(page) == "string" and not seen[page] then
        seen[page] = true
        selectors[#selectors + 1] = page
      end
    end
  end
  return selectors
end

-- Terminal leave carries an explicit final-page acknowledgment: while
-- narration plays, one genuine confirm through the real screen path
-- advances it exactly as a player would, so the battle can settle.
---@param rig table live screen rig under test driving
local function ackNarration(rig)
  local mode = rig.screen:status().mode
  if mode == "intro" or mode == "narration" or mode == "outcome"
    or rig.screen._timeline:messageActive() or rig.screen._timeline:levelUpStats() ~= nil
  then
    rig.screen:input({ { type = "confirm" } })
  end
end

-- Player commands reach the kernel exactly once: the opening decision
-- stays open with no automatic choice, Fight opens the true move slots
-- with their PP and type facts, cancels walk back without leaving the
-- battle, one accepted move seals a single reply, later edges and stale
-- taps seal nothing, a disabled slot keeps its reason without spending
-- the turn, and a refused run in a trainer battle stays on the same
-- decision without costing the turn.
function T.interactive_commands_reach_the_runtime_exactly_once()
  local modules = battleScreenModules("real player decisions run through one screen", STATE_MODULE)
  local rig = openWildRig(
    modules,
    "launch-screen-commands",
    { species = "EEVEE", level = 20, seed = 0x33333333 },
    { species = "EEVEE", level = 5, seed = 0x44444444, ability = "RUN_AWAY" },
    foeRecord("EEVEE", 20, 0x5EED0002)
  )

  -- No automatic choice: the opening decision arrives and stays open
  -- across ticks that carry no input, addressed only to the player side.
  local command = driveToMode(rig, "command", 600)
  Assert.isTrue(command.ready, "the command prompt accepts input once its cues finish")
  local requestId = assert(command.request, "the command prompt mirrors the open request").requestId
  rig.pump(30)
  Assert.equal(rig.screen:status().request.requestId, requestId, "idle ticks never answer the open decision")
  Assert.equal(#rig.submits, 0, "idle ticks seal no reply")
  local seenFoeReserve = false
  do
    local foeIds = {}
    for _, seed in ipairs(rig.scenario.participants[2].roster) do
      foeIds[seed.id] = true
    end
    local shape = serializeShape(rig.screen:view())
    for id in pairs(foeIds) do
      if
        id ~= rig.screen:status().request.actors[1].combatant and shape:find("combatant=" .. tostring(id), 1, true)
      then
        seenFoeReserve = true
      end
    end
  end
  Assert.isFalse(seenFoeReserve, "the displayed view never exposes unrevealed enemy reserves")

  -- The detached view is caller-owned: mutating a copy changes no later
  -- read of the same decision.
  do
    local first = rig.screen:view()
    first.selection = "mutated"
    Assert.equal(rig.screen:view().selection, "fight", "mutating a returned view never reaches the controller")
  end

  -- Fight opens the true slots: one known move with its PP facts, the
  -- remaining slots visibly empty, and cancel returns to command.
  -- The settled command root keeps its framed select prompt: the
  -- top-screen narration names the acting lead while the command menu
  -- stays open over it, so the view never goes chrome-only mid-decision.
  local openingView = rig.screen:view()
  Assert.isTrue(openingView.message ~= "", "the settled command root keeps its staged prompt")
  Assert.isTrue(string.find(openingView.message, "EEVEE", 1, true) ~= nil, "the staged prompt names its acting battler")
  Assert.equal(openingView.selection, "fight", "the command prompt rests on the first command")
  local commands = assert(openingView.commands, "the command prompt lists its four commands")
  Assert.equal(#commands, 4, "Fight, Bag, Pokemon and Run stay reachable")
  rig.screen:input({ { type = "confirm" } })
  rig.pump(1)
  Assert.equal(rig.screen:status().mode, "moves", "confirming the first command opens move selection")
  local moves = assert(rig.screen:view().moves, "move selection lists its slots")
  Assert.equal(#moves, 4, "move selection spans the four native slots")
  Assert.equal(moves[1].slot, 0, "slots keep their zero-based identity")
  Assert.isTrue(moves[1].enabled, "the known strike stays selectable")
  for index = 2, 4 do
    Assert.isFalse(moves[index].enabled, "empty slots stay visibly unselectable")
  end
  rig.screen:input({ { type = "cancel" } })
  rig.pump(1)
  Assert.equal(rig.screen:status().mode, "command", "cancel from moves returns to command")
  Assert.isTrue(rig.screen:view().message ~= "", "returning to command restores the staged prompt")
  Assert.isTrue(
    string.find(rig.screen:view().message, "EEVEE", 1, true) ~= nil,
    "the restored prompt still names its acting battler"
  )
  Assert.equal(#rig.submits, 0, "cancelling spends no turn")

  -- One accepted move seals exactly one reply: selecting the slot and
  -- confirming resolves the single-target choice without a invented
  -- target prompt, and every later edge is dropped.
  tap(rig, 128, 83 + 192)
  rig.pump(1)
  Assert.equal(rig.screen:status().mode, "moves", "activating the top command opens move selection by pointer")
  tap(rig, 64, 45 + 192)
  rig.pump(1)
  Assert.equal(rig.screen:view().selection, "move:0", "activating the first move slot selects that slot")
  rig.screen:input({ { type = "confirm" } })
  rig.pump(1)
  Assert.equal(rig.screen:status().mode, "awaiting_resolution", "an accepted move waits for its resolution")
  Assert.equal(#rig.submits, 1, "exactly one valid reply reaches the runtime")
  rig.screen:input({ { type = "confirm" } })
  tap(rig, 192, 44 + 192)
  rig.pump(2)
  Assert.equal(#rig.submits, 1, "edges and stale taps while waiting seal nothing more")

  -- A spent move set seals through Fight alone: with no usable PP the
  -- kernel projects its struggle option, so tapping Fight completes
  -- the turn with the projected struggle instead of opening moves.
  local spentModules = modules
  local spent = openWildRig(
    spentModules,
    "launch-screen-spent",
    { species = "EEVEE", level = 20, seed = 0x77777777, pp = 0 },
    { species = "EEVEE", level = 5, seed = 0x88888888, ability = "RUN_AWAY" },
    foeRecord("EEVEE", 20, 0x5EED0009)
  )
  driveToMode(spent, "command", 600)
  local spentStatus = assert(spent.screen:status().request, "the spent battle mirrors its open request")
  local spentOptions, spentOptionsErr = spent.battle:decisionOptions(spentStatus.requestId)
  Assert.notNil(spentOptions, "the runtime projects options for the spent request: " .. tostring(spentOptionsErr))
  local spentAddressed = assert(spentStatus.actors[1], "the spent request addresses its lead")
  local spentStruggle = nil
  for _, entry in ipairs(assert(spentOptions.actors, "the spent projection addresses its actors")) do
    if
      type(entry) == "table"
      and entry.combatant == spentAddressed.combatant
      and entry.activation == spentAddressed.activation
    then
      for _, choice in ipairs(entry.choices) do
        if type(choice) == "table" and choice.role == "move" and type(choice.id) == "string" then
          if choice.id == "move:struggle" then
            spentStruggle = choice
          else
            Assert.isFalse(choice.enabled == true, "no ordinary move stays usable beside the struggle")
          end
        end
      end
    end
  end
  spentStruggle = assert(spentStruggle, "the kernel projects its struggle option")
  Assert.isTrue(spentStruggle.enabled == true, "the projected struggle stays enabled")
  local spentEnabled = {}
  if type(spentStruggle.targets) == "table" then
    for _, variant in ipairs(spentStruggle.targets) do
      if type(variant) == "table" and variant.enabled == true then
        spentEnabled[#spentEnabled + 1] = variant
      end
    end
  end
  Assert.isTrue(#spentEnabled <= 1, "the spent single holds at most one struggle recipient")
  local spentExpected = spentStruggle.choice
  if #spentEnabled == 1 then
    spentExpected = spentEnabled[1].choice
  end
  tap(spent, 128, 83 + 192)
  spent.pump(1)
  Assert.equal(
    spent.screen:status().mode,
    "awaiting_resolution",
    "Fight seals the projected struggle without opening moves"
  )
  Assert.equal(#spent.submits, 1, "the spent turn submits exactly one reply")
  local spentSealed = assert(spent.submits[1], "the spent reply is recorded")
  Assert.deepEqual(spentSealed.choices[1], spentExpected, "the sealed fragment keeps the projected struggle")
  Assert.isNil(spent.screen:status().request, "the answered request is no longer mirrored as open")

  -- A refused run stays put: in a trainer battle the run command is
  -- listed but disabled, and confirming it never spends the turn.
  do
    local ScenarioFactory = require(SCENARIO_FACTORY_MODULE)
    local party = makeParty(
      { species = "EEVEE", level = 20, seed = 0x99999999 },
      { species = "EEVEE", level = 5, seed = 0xAAAAAAAA, ability = "RUN_AWAY" }
    )
    local bag = HgssBagService.new({ catalog = ItemFixture.makeCatalog() })
    local foe = foeRecord("TOTODILE", 4, 0x5EED000B)
    local trainers = {
      { id = "trainer-screen-run", class = "YOUNGSTER", name = "TRAINER", party = { foe }, aiPasses = {} },
    }
    local scenario = ScenarioFactory.fromTrainer({ id = "trainer-screen-run", trainers = trainers }, {
      party = party,
      bag = bag,
      player = {
        trainerId = 99,
        trainerName = "MINT",
        trainerClassKey = "PKMN_TRAINER_ETHAN",
        language = "french",
      },
    })
    local trainerRig = openRig(modules, {
      launchId = "launch-screen-trainer-run",
      launch = { id = "launch-screen-trainer-run", kind = "trainer", payload = { trainer = "trainer-screen-run" } },
      scenario = scenario,
      party = party,
      bag = bag,
      measurement = dualMeasurement(),
    })
    trainerRig.party = party
    trainerRig.bag = bag
    trainerRig.scenario = scenario
    driveToMode(trainerRig, "command", 1200)
    local trainerRequest =
      assert(trainerRig.screen:status().request, "the trainer battle mirrors its open request").requestId
    local trainerCommands = assert(trainerRig.screen:view().commands, "the trainer prompt lists its commands")
    local run = nil
    for _, entry in ipairs(trainerCommands) do
      if entry.id == "run" then
        run = entry
      end
    end
    run = assert(run, "Run stays listed in a trainer battle")
    Assert.isFalse(run.enabled, "Run is not selectable against a trainer")
    Assert.isTrue(type(run.reason) == "string" and run.reason ~= "", "the refused run keeps its reason")
    tap(trainerRig, 128, 176 + 192)
    trainerRig.pump(2)
    Assert.equal(trainerRig.screen:status().mode, "command", "confirming a refused run stays on the same decision")
    Assert.equal(#trainerRig.submits, 0, "a refused run spends no turn")
    Assert.equal(
      trainerRig.screen:status().request.requestId,
      trainerRequest,
      "a refused run keeps the same request open"
    )
    trainerRig.screen:dispose()
    trainerRig.battle:dispose()
  end

  rig.screen:dispose()
  rig.battle:dispose()
  spent.screen:dispose()
  spent.battle:dispose()
end

-- Paired panes honor the native source regions: two 256x192 panes with
-- the battlefield on the main surface and interaction below, every
-- command/move/cancel anchor activates its own semantic control, gaps
-- and the outside activate nothing, press art follows the armed press
-- without hover sealing, redraws never advance state, and borrowed
-- graphics state is restored. A surface too small for 1x reports
-- too-small instead of a squeezed battle.
function T.paired_panes_use_source_regions_and_survive_redraw()
  local modules = battleScreenModules("source-backed native presentation on paired displays", RENDERER_MODULE)
  local rig = openWildRig(
    modules,
    "launch-screen-paired",
    { species = "EEVEE", level = 20, seed = 0x33333333, ability = "RUN_AWAY" },
    { species = "EEVEE", level = 5, seed = 0x44444444, ability = "RUN_AWAY" },
    foeRecord("EEVEE", 20, 0x5EED0002)
  )
  driveToMode(rig, "command", 600)

  -- Two logical panes at native size: detail above, interaction below,
  -- with one stable input identity across redraws.
  local plan = assert(rig.screen:status().presentation, "the command status carries its complete plan")
  Assert.isTrue(type(plan.render) == "function", "the complete plan carries its draw entry")
  Assert.isTrue(type(plan.mapInput) == "function", "the complete plan carries its pointer mapping")
  local sizes = paneSizes(plan)
  Assert.equal(#sizes, 2, "the paired composition resolves exactly two panes")
  for _, size in ipairs(sizes) do
    Assert.equal(size.width, 256, "each logical pane spans the native width")
    Assert.equal(size.height, 192, "each logical pane spans the native height")
  end
  local key = plan.inputKey
  rig.pump(3)
  Assert.equal(rig.screen:status().presentation.inputKey, key, "equivalent re-resolution keeps its input identity")

  -- Source command anchors each activate their own control: the top
  -- command, the two bottom-corner menus as child intents that spend
  -- nothing, and cancel regions walk back without leaving the battle.
  tap(rig, 128, 83 + 192)
  rig.pump(1)
  Assert.equal(rig.screen:status().mode, "moves", "the top anchor opens move selection")
  -- Focus then seal: the first tap on a new slot only moves focus, so
  -- stepping focus away first keeps the anchor tap from sealing the
  -- already-focused slot while still proving the anchor selects it.
  rig.screen:input({ { type = "navigate", direction = "down" } })
  rig.pump(1)
  tap(rig, 64, 45 + 192)
  rig.pump(1)
  Assert.equal(rig.screen:view().selection, "move:0", "the first move anchor selects the first slot")
  tap(rig, 128, 175 + 192)
  rig.pump(1)
  Assert.equal(rig.screen:status().mode, "command", "the cancel anchor returns to command")
  Assert.equal(#rig.submits, 0, "walking the menus spends no turn")
  local commandRequest = assert(rig.screen:status().request, "the menu walk mirrors its request").requestId
  tap(rig, 40, 169 + 192)
  rig.pump(1)
  Assert.equal(rig.screen:status().mode, "child", "the lower-left anchor opens its child")
  Assert.equal(rig.screen:view().childIntent.kind, "bag", "the lower-left child carries the bag intent")
  Assert.equal(#rig.submits, 0, "opening the bag child spends no turn")
  rig.screen:input({ { type = "cancel" } })
  rig.pump(1)
  Assert.equal(rig.screen:status().mode, "command", "cancelling the child returns to the same decision")
  Assert.equal(rig.screen:status().request.requestId, commandRequest, "the child keeps the parent request")
  tap(rig, 216, 168 + 192)
  rig.pump(1)
  Assert.equal(rig.screen:status().mode, "child", "the lower-right anchor opens its child")
  Assert.equal(rig.screen:view().childIntent.kind, "party", "the lower-right child carries the party intent")
  rig.screen:input({ { type = "cancel" } })
  rig.pump(1)
  Assert.equal(rig.screen:status().mode, "command", "cancelling the party child returns to command")

  -- Gaps and the outside map to nothing: between the bottom controls
  -- and above the bottom row, and on the detail pane, taps have no
  -- target and never dismiss the battle.
  local gapPlan = assert(rig.screen:status().presentation, "the gap probes read the current plan")
  local gapView = rig.screen:view()
  Assert.isNil(
    gapPlan.mapInput({ type = "pointer_down", pointerId = "touch:9", x = 84, y = 170 + 192 }, gapView, gapPlan),
    "the gutter between the bottom controls claims no command"
  )
  Assert.isNil(
    gapPlan.mapInput({ type = "pointer_down", pointerId = "touch:9", x = 100, y = 148 + 192 }, gapView, gapPlan),
    "the strip above the bottom row claims no command"
  )
  Assert.isNil(
    gapPlan.mapInput({ type = "pointer_down", pointerId = "touch:9", x = 10, y = 10 }, gapView, gapPlan),
    "the detail pane dismisses nothing in a battle"
  )
  Assert.equal(rig.screen:status().mode, "command", "unmapped taps keep the same decision")

  -- Empty move slots are not selectable: with a single known move the
  -- remaining anchors leave the selection alone.
  tap(rig, 128, 83 + 192)
  rig.pump(1)
  -- See the focus note above: stepping focus away first keeps the
  -- anchor tap to a focus move instead of a seal.
  rig.screen:input({ { type = "navigate", direction = "down" } })
  rig.pump(1)
  tap(rig, 64, 45 + 192)
  rig.pump(1)
  Assert.equal(rig.screen:view().selection, "move:0", "the first move anchor selects the known slot")
  tap(rig, 192, 44 + 192)
  rig.pump(1)
  Assert.equal(rig.screen:view().selection, "move:0", "an empty slot leaves the selection alone")
  Assert.equal(#rig.submits, 0, "an empty slot seals nothing")

  -- Press art follows the armed press: pressing changes the
  -- interaction drawing, releasing elsewhere cancels, hovering alone
  -- seals nothing, and the sealed command still needs its release.
  local graphics = FakeGraphics.new({})
  -- The picture pass reuses one mesh for every portrait, so a recorded
  -- mesh always shows the last submitted texture: journal every texture
  -- the renderer submits to prove each battler draws its own image.
  local meshTextures = {}
  do
    local realNewMesh = graphics.newMesh
    graphics.newMesh = function(...)
      local mesh = realNewMesh(...)
      local realSetTexture = mesh.setTexture
      mesh.setTexture = function(self, texture)
        meshTextures[#meshTextures + 1] = texture
        return realSetTexture(self, texture)
      end
      return mesh
    end
  end
  local function drawNow()
    for key in pairs(graphics.draws) do
      graphics.draws[key] = nil
    end
    rig.screen:draw({ graphics = graphics })
    return drawShapes(graphics)
  end
  tap(rig, 128, 175 + 192)
  rig.pump(1)
  Assert.equal(rig.screen:status().mode, "command", "the moves cancel anchor returns to command by pointer")
  -- The re-entered prompt reveals before it arms: the press probes wait
  -- for the production input gate instead of racing it.
  driveToMode(rig, "command", 30)
  drawNow()
  local releasedY = rig.text.lastY["FIGHT"]
  Assert.isTrue(#graphics.draws > 0, "the command composition draws through the recording boundary")
  rig.screen:input({ { type = "pointer_down", pointerId = "touch:3", x = 128, y = 83 + 192 } })
  drawNow()
  Assert.equal(rig.text.lastY["FIGHT"], releasedY - 2, "the armed press lifts its label like the source task")
  rig.screen:input({ { type = "pointer_move", pointerId = "touch:3", x = 84, y = 170 + 192 } })
  rig.screen:input({ { type = "pointer_up", pointerId = "touch:3", x = 84, y = 170 + 192 } })
  rig.pump(1)
  Assert.equal(rig.screen:status().mode, "command", "releasing an armed press off its control cancels the press")
  Assert.equal(#rig.submits, 0, "a press released off its control seals nothing")
  rig.screen:input({ { type = "pointer_move", pointerId = "touch:4", x = 40, y = 169 + 192 } })
  rig.pump(1)
  Assert.equal(drawNow(), drawNow(), "hover alone leaves the drawing untouched")
  Assert.equal(#rig.submits, 0, "hover alone seals no choice")

  -- Both battlers draw from their own images with narration framed by
  -- the selected window, redraws are inert, and borrowed graphics
  -- state returns exactly.
  local playerBack = fakeDrawable("battler:player-back")
  local enemyFront = fakeDrawable("battler:enemy-front")
  -- Battlers draw their own exact canonical portraits, never the
  -- generic side keys: back selectors keep the back handle, front
  -- selectors the front handle, so each drawn image stays identifiable.
  for _, selector in ipairs(demandedPortraits(rig)) do
    if selector:sub(-5) == "/back" then
      rig.assets.images["mon:" .. selector] = playerBack
    else
      rig.assets.images["mon:" .. selector] = enemyFront
    end
  end
  rig.pump(2)
  drawNow()
  local function wasDrawn(image)
    for _, entry in ipairs(graphics.draws) do
      if entry.image == image then
        return true
      end
    end
    for _, texture in ipairs(meshTextures) do
      if texture == image then
        return true
      end
    end
    return false
  end
  Assert.isTrue(wasDrawn(playerBack), "the player battler draws from its own back image")
  Assert.isTrue(wasDrawn(enemyFront), "the enemy battler draws from its own front image")
  Assert.isTrue(#rig.windows.calls > 0, "narration and menus draw through the selected window frame")
  local firstPass = drawNow()
  local soundCount = #rig.audio.plays
  local secondPass = drawNow()
  Assert.equal(firstPass, secondPass, "drawing twice restarts and reticks nothing")
  Assert.equal(#rig.audio.plays, soundCount, "drawing plays no sound")
  Assert.equal(rig.screen:status().mode, "command", "drawing advances no controller mode")
  local before = graphicsState(graphics)
  drawNow()
  Assert.deepEqual(graphicsState(graphics), before, "the paired draw restores borrowed graphics state exactly")

  -- A pair without room takes the compact pane instead of squeezing:
  -- a surface that cannot fit a paired pane at 1x keeps the logical
  -- battle on the single-pane composition with every control reachable.
  rig.measurement = tinyMeasurement()
  rig.screen:input({ { type = "pointer_down", pointerId = "touch:5", x = 128, y = 83 + 192 } })
  rig.pump(1)
  local small = rig.screen:status()
  local smallPlan = assert(small.presentation, "the small surface still resolves a plan")
  Assert.isTrue(smallPlan.content.compact == true, "the small surface takes the compact composition")
  Assert.equal(small.mode, "command", "a small surface keeps the logical battle, only the layout reports")
  Assert.isNil(
    smallPlan.mapInput({ type = "pointer_down", pointerId = "touch:5", x = 10, y = 10 }, rig.screen:view(), smallPlan),
    "the scene claims no command on the compact fallback"
  )
  rig.screen:cancelPointerCapture()
  rig.screen:input({ { type = "pointer_up", pointerId = "touch:5", x = 128, y = 83 + 192 } })
  rig.pump(1)
  Assert.equal(#rig.submits, 0, "the held press from the roomy layout never activates after the shrink")
  rig.measurement = dualMeasurement()
  rig.pump(2)
  local restored = assert(rig.screen:status().presentation, "the restored surface resolves a plan")
  Assert.equal(#restored.panes, 2, "restoring room brings back both paired panes without rebuilding the battle")

  -- Run closes the battle last: the assured flight seals one reply and
  -- the battle settles fled with both sides standing.
  driveToMode(rig, "command", 600)
  tap(rig, 128, 176 + 192)
  rig.pump(1)
  Assert.equal(rig.screen:status().mode, "awaiting_resolution", "the run anchor submits the flight")
  Assert.equal(#rig.submits, 1, "the run seals exactly one reply")
  for _ = 1, 600 do
    ackNarration(rig)
    rig.pump(1)
    if rig.battle:status().phase == "complete" then
      break
    end
  end
  Assert.equal(rig.battle:status().phase, "complete", "the flight settles the battle")
  Assert.equal(rig.battle:status().result, "flee", "the assured flight reports flee, not a fabricated loss")
  rig.screen:dispose()
  rig.battle:dispose()
end

-- Visible cues drain in event order without host-clock effects: health
-- checkpoints apply in turn order with no read-ahead, the next request
-- waits for earlier cues, identical accepted time under different draw
-- schedules settles identically with one-shot sounds, a held image
-- holds its cue without leaking later health, and the terminal result
-- is narrated once with exact final values even when playback is muted.
function T.visible_cues_drain_in_order_without_host_clock_effects()
  local modules = battleScreenModules("ordered visible-state cues independent of host drawing", TIMELINE_MODULE)
  local rig = openWildRig(
    modules,
    "launch-screen-timeline",
    { species = "EEVEE", level = 5, seed = 0x33333333, move = "QUICK_ATTACK" },
    { species = "EEVEE", level = 5, seed = 0x44444444, ability = "RUN_AWAY" },
    foeRecord("EEVEE", 30, 0x5EED0002)
  )
  driveToMode(rig, "command", 600)
  tap(rig, 128, 83 + 192)
  rig.pump(1)
  tap(rig, 64, 45 + 192)
  rig.pump(1)
  rig.screen:input({ { type = "confirm" } })
  rig.pump(1)
  Assert.equal(rig.screen:status().mode, "awaiting_resolution", "the timeline battle accepts its strike")

  -- Event order without read-ahead: both health facts move from their
  -- opening values, the earlier checkpoint lands strictly before the
  -- later one is shown, and no request opens while cues are pending.
  local opening = rig.screen:view()
  local openingPlayer = opening.battlers[1].hp
  local openingEnemy = opening.battlers[2].hp
  local playerMovedAt = nil
  local enemyMovedAt = nil
  local requestAt = nil
  local faintAt = nil
  local port = rig.screen:presentationPort()
  for tick = 1, 600 do
    rig.pump(1)
    local view = rig.screen:view()
    if enemyMovedAt == nil and view.battlers[2].hp ~= openingEnemy then
      enemyMovedAt = tick
    end
    if playerMovedAt == nil and view.battlers[1].hp ~= openingPlayer then
      playerMovedAt = tick
    end
    if faintAt == nil and view.battlers[1].hp == 0 and view.battlers[1].visible == false then
      faintAt = tick
    end
    local status = rig.screen:status()
    if status.request ~= nil and requestAt == nil then
      requestAt = tick
    end
    if status.mode == "command" or status.request ~= nil then
      break
    end
  end
  Assert.notNil(enemyMovedAt, "the traded turn moves the enemy health fact")
  Assert.notNil(playerMovedAt, "the traded turn moves the player health fact")
  Assert.isTrue(enemyMovedAt ~= playerMovedAt, "two health changes in one turn land as two checkpoints")
  local firstMove = math.min(enemyMovedAt --[[@as integer]], playerMovedAt --[[@as integer]])
  local lastMove = math.max(enemyMovedAt --[[@as integer]], playerMovedAt --[[@as integer]])
  Assert.isTrue(firstMove < lastMove, "the earlier checkpoint is shown strictly before the later one")
  Assert.notNil(faintAt, "the knockout hides the zero-health battler")
  Assert.isTrue(faintAt --[[@as integer]] >= lastMove, "the faint cue never precedes its health checkpoint")
  Assert.notNil(requestAt, "the knockout opens its replacement obligation")
  Assert.isTrue(
    requestAt --[[@as integer]] > faintAt --[[@as integer]],
    "the next request never appears before the earlier cues finish"
  )
  Assert.equal(port.ready(), false, "the port reports back-pressure while no test holds it")

  -- Identical accepted time settles identically: sparse drawing, dense
  -- drawing, and extra draws between ticks reach the same displayed
  -- facts, sounds, and replies.
  local function quickWinRig(audio, drawsPerTick)
    local twin = openWildRig(
      modules,
      "launch-screen-clock-" .. tostring(drawsPerTick) .. "-" .. tostring(#audio.plays),
      { species = "EEVEE", level = 20, seed = 0x55555555 },
      { species = "EEVEE", level = 5, seed = 0x66666666, ability = "RUN_AWAY" },
      foeRecord("EEVEE", 4, 0x5EED0007),
      { audio = audio, seed = 0x12345678 }
    )
    return twin, drawsPerTick
  end
  local function settleTwin(twin, drawsPerTick)
    driveToMode(twin, "command", 1200)
    tap(twin, 128, 83 + 192)
    twin.pump(1)
    tap(twin, 64, 45 + 192)
    twin.pump(1)
    twin.screen:input({ { type = "confirm" } })
    local graphics = FakeGraphics.new({})
    for _ = 1, 1800 do
      ackNarration(twin)
      twin.pump(1)
      for _ = 1, drawsPerTick do
        twin.screen:draw({ graphics = graphics })
      end
      if twin.battle:status().phase == "complete" then
        break
      end
    end
    return twin
  end
  local sparseAudio = recordingAudio(false)
  local sparse = settleTwin(quickWinRig(sparseAudio, 0))
  local denseAudio = recordingAudio(false)
  local dense = settleTwin(quickWinRig(denseAudio, 3))
  local sparseStatus = sparse.battle:status()
  local sparseScreenStatus = sparse.screen:status()
  Assert.equal(
    sparseStatus.phase,
    "complete",
    "the sparsely drawn twin settles (screen="
      .. tostring(sparseScreenStatus.mode)
      .. ", error="
      .. tostring(sparseScreenStatus.error)
      .. ")"
  )
  Assert.equal(dense.battle:status().phase, "complete", "the densely drawn twin settles")
  Assert.deepEqual(
    { sparse.screen:view().battlers[1].hp, sparse.screen:view().battlers[2].hp },
    { dense.screen:view().battlers[1].hp, dense.screen:view().battlers[2].hp },
    "draw schedules never change the displayed health facts"
  )
  Assert.deepEqual(sparseAudio.plays, denseAudio.plays, "draw schedules never change one-shot sounds")
  Assert.equal(#sparse.submits, #dense.submits, "draw schedules never change the sealed replies")
  Assert.equal(sparse.screen:view().message, dense.screen:view().message, "both schedules narrate the same outcome")
  for _, twin in ipairs({ sparse, dense }) do
    twin.screen:dispose()
    twin.battle:dispose()
  end

  -- A held image holds its cue: while the incoming drawable is
  -- unavailable the displayed health stays at its earlier checkpoint
  -- and readiness stays false; releasing it completes exactly.
  do
    local heldAssets = stubAssets({})
    local held = openWildRig(
      modules,
      "launch-screen-held",
      { species = "EEVEE", level = 20, seed = 0x12121212 },
      { species = "EEVEE", level = 5, seed = 0x34343434, ability = "RUN_AWAY" },
      foeRecord("EEVEE", 20, 0x5EED0013),
      { assets = heldAssets }
    )
    driveToMode(held, "command", 600)
    -- The strike cue gates on the foe's exact incoming portrait, never
    -- the generic side key: holding that demanded key holds the cue.
    local heldFoeKey = nil
    for _, selector in ipairs(demandedPortraits(held)) do
      if selector:sub(-5) ~= "/back" then
        heldFoeKey = heldFoeKey or selector
      end
    end
    heldFoeKey = assert(heldFoeKey, "the launch demands its exact foe portrait")
    heldAssets.hold["mon:" .. heldFoeKey] = true
    tap(held, 128, 83 + 192)
    held.pump(1)
    tap(held, 64, 45 + 192)
    held.pump(1)
    held.screen:input({ { type = "confirm" } })
    held.pump(1)
    local beforeHold = held.screen:view().battlers[2].hp
    for _ = 1, 120 do
      held.pump(1)
    end
    Assert.equal(
      held.screen:view().battlers[2].hp,
      beforeHold,
      "a cue needing an unavailable drawable never leaks its later health"
    )
    Assert.isFalse(held.screen:status().ready, "the held cue reports unready instead of skipping ahead")
    heldAssets.hold["mon:" .. heldFoeKey] = nil
    driveToMode(held, "command", 900)
    Assert.isTrue(held.screen:status().ready, "releasing the drawable completes the held cue")
    held.screen:dispose()
    held.battle:dispose()
  end

  -- The terminal result is narrated once with exact final values, and
  -- muted playback still drains every cue to the same facts.
  local function narratedOutcome(audio)
    local twin = openWildRig(
      modules,
      "launch-screen-outcome-" .. tostring(audio.muted),
      { species = "EEVEE", level = 20, seed = 0x5A5A5A5A },
      { species = "EEVEE", level = 5, seed = 0x6B6B6B6B, ability = "RUN_AWAY" },
      foeRecord("EEVEE", 4, 0x5EED0017),
      { audio = audio }
    )
    driveToMode(twin, "command", 600)
    tap(twin, 128, 83 + 192)
    twin.pump(1)
    tap(twin, 64, 45 + 192)
    twin.pump(1)
    twin.screen:input({ { type = "confirm" } })
    for _ = 1, 2400 do
      ackNarration(twin)
      twin.pump(1)
      if twin.battle:status().phase == "complete" then
        break
      end
    end
    local outcomeStatus = twin.screen:status()
    Assert.equal(
      twin.battle:status().phase,
      "complete",
      "the wild win completes without a result page (screen="
        .. tostring(outcomeStatus.mode)
        .. ", error="
        .. tostring(outcomeStatus.error)
        .. ", settled="
        .. tostring(twin.screen._timeline:settled())
        .. ", outcomeDone="
        .. tostring(twin.screen._outcomeDone)
        .. ", registration="
        .. tostring(twin.screen._pendingRegistration ~= nil or twin.screen._registrationChild ~= nil)
        .. ")"
    )
    Assert.isTrue(
      twin.screen:_portLeave({}),
      "the wild win leaves after its final cues settle without an acknowledgment"
    )
    return twin
  end
  local sounding = narratedOutcome(recordingAudio(false))
  Assert.isTrue(#sounding.audio.plays > 0, "cue starts play their sounds once each")
  local cryPlays = {}
  local otherCounts = {}
  for _, played in ipairs(sounding.audio.plays) do
    if type(played) == "string" and played:sub(1, 4) == "cry:" then
      cryPlays[#cryPlays + 1] = played
    else
      otherCounts[played] = (otherCounts[played] or 0) + 1
    end
  end
  for name, total in pairs(otherCounts) do
    Assert.equal(total, 1, "every non-cry cue sound plays exactly once: " .. tostring(name))
  end
  -- Retail voices all three: the wild foe send-out, the player
  -- send-out, and the fainted foe. A same-species matchup keys all
  -- three identically, so the exact ordered triple is the source
  -- truth: a missing or extra cry fails.
  Assert.deepEqual(
    cryPlays,
    { "cry:EEVEE", "cry:EEVEE", "cry:EEVEE" },
    "the win voices exactly its three send-out and faint cries in order"
  )
  local liveHp = sounding.party:partyMon(0).condition.currentHp
  Assert.equal(
    sounding.screen:view().battlers[1].hp,
    liveHp,
    "the drained view carries the exact final health, not an interpolation residue"
  )
  -- Capture the terminal wording before teardown: a disposed screen
  -- releases its scene, so the muted twin compares against the
  -- retained copy instead of a released view.
  local soundingMessage = sounding.screen:view().message
  sounding.screen:dispose()
  sounding.battle:dispose()
  local muted = narratedOutcome(recordingAudio(true))
  Assert.equal(muted.battle:status().phase, "complete", "muted playback never deadlocks a cue")
  Assert.equal(muted.screen:view().message, soundingMessage, "muted playback narrates the same terminal result")
  muted.screen:dispose()
  muted.battle:dispose()

  rig.screen:dispose()
  rig.battle:dispose()
end

-- Definitions and leases follow single ownership: validated custom
-- scene and frame content is actually drawn instead of vanilla content,
-- invalid definitions fail explicitly with resource context, a geometry
-- change cancels a held press before new hit testing, and disposal at
-- entry, playback, or terminal time releases each owned handle once
-- while borrowed text and window services stay usable.
function T.definitions_and_leases_follow_single_ownership()
  local modules = battleScreenModules("overrideable definitions with exact release ownership", ASSETS_MODULE)
  local Cache = require(PRESENTATION_CACHE_MODULE)
  local sceneKey = Cache.sceneKey(Cache.BACKGROUNDS[4], Cache.TERRAINS[3], Cache.TIMES[1])

  -- Selected content is actually drawn: the custom scene handle and
  -- the custom frame reach the recording boundary, vanilla handles
  -- never appear.
  local customScene = fakeDrawable("scene:custom", 512, 256)
  local vanillaScene = fakeDrawable("scene:vanilla", 512, 256)
  local assets = stubAssets({ seedImages = { ["scene:custom"] = customScene, ["scene:vanilla"] = vanillaScene } })
  local windows = recordingWindows()
  local rig = openWildRig(
    modules,
    "launch-screen-owned",
    { species = "EEVEE", level = 20, seed = 0x33333333 },
    { species = "EEVEE", level = 5, seed = 0x44444444, ability = "RUN_AWAY" },
    foeRecord("EEVEE", 20, 0x5EED0002),
    {
      assets = assets,
      windows = windows,
      overrides = {
        sceneKey = sceneKey,
        sceneImage = "scene:custom",
        frameKey = "custom-test-frame",
        frames = { ["custom-test-frame"] = {} },
      },
    }
  )
  -- The battle demand is built through the real presentation inventory:
  -- the planning manifest yields a nonempty bounded demand.
  do
    local demand, bounded = Cache.requirements(
      screenManifest(sceneKey),
      { background = Cache.BACKGROUNDS[4], terrain = Cache.TERRAINS[3], time = Cache.TIMES[1] },
      { "EEVEE/back", "EEVEE/front" },
      nil,
      { "back:PKMN_TRAINER_ETHAN", "front:YOUNGSTER" },
      { "ball:POKE_BALL" }
    )
    Assert.notNil(demand, "the planning manifest yields its resource demand through the real inventory")
    Assert.isTrue(bounded == true or bounded == false, "the demand reports its bounded readiness")
  end
  driveToMode(rig, "command", 600)
  local graphics = FakeGraphics.new({})
  rig.screen:draw({ graphics = graphics })
  local function wasDrawn(image)
    for _, entry in ipairs(graphics.draws) do
      if entry.image == image then
        return true
      end
    end
    return false
  end
  Assert.isTrue(wasDrawn(customScene), "the selected custom scene is actually drawn")
  Assert.isFalse(wasDrawn(vanillaScene), "custom content is never replaced by vanilla content")
  Assert.isTrue(windows.frames()["custom-test-frame"] == true, "the selected custom frame is actually drawn")

  -- A held press dies on geometry change: pressing, shrinking to a
  -- wide layout, then releasing activates nothing stale.
  rig.screen:input({ { type = "pointer_down", pointerId = "touch:7", x = 128, y = 83 + 192 } })
  rig.pump(1)
  rig.measurement = wideMeasurement()
  rig.pump(1)
  rig.screen:input({ { type = "pointer_up", pointerId = "touch:7", x = 128, y = 83 + 192 } })
  rig.pump(1)
  Assert.equal(rig.screen:status().mode, "command", "a remeasured layout cancels the held press first")
  Assert.equal(#rig.submits, 0, "no stale activation survives a geometry change")
  rig.measurement = dualMeasurement()
  rig.pump(2)

  -- Invalid definitions fail explicitly: an unknown frame stops
  -- interaction with launch and resource context, never a blank
  -- success or a substituted frame.
  do
    local badWindows = recordingWindows()
    local bad = openWildRig(
      modules,
      "launch-screen-bad-frame",
      { species = "EEVEE", level = 20, seed = 0xDEADBEEF },
      { species = "EEVEE", level = 5, seed = 0xFEEDBEEF, ability = "RUN_AWAY" },
      foeRecord("EEVEE", 20, 0x5EED0021),
      { windows = badWindows, overrides = { sceneKey = sceneKey, frameKey = "no-such-frame" } }
    )
    local failed = nil
    for _ = 1, 300 do
      bad.pump(1)
      if bad.screen:status().mode == "failed" then
        failed = bad.screen:status()
        break
      end
    end
    failed = assert(failed, "the unknown frame stops the screen instead of substituting")
    Assert.isTrue(type(failed.error) == "string" and failed.error ~= "", "the failure carries its context")
    Assert.isTrue(
      failed.error:find("no%-such%-frame", 1) ~= nil or failed.error:find("frame", 1) ~= nil,
      "the failure names its missing definition"
    )
    bad.screen:dispose()
    bad.screen:dispose()
    bad.battle:dispose()
  end

  -- Preparation failure fails the launch: the asset error becomes the
  -- screen failure with no false interaction.
  do
    local failing = stubAssets({ failPrepare = "test-scene-missing" })
    local sad = openWildRig(
      modules,
      "launch-screen-bad-scene",
      { species = "EEVEE", level = 20, seed = 0xABCDEF01 },
      { species = "EEVEE", level = 5, seed = 0xABCDEF02, ability = "RUN_AWAY" },
      foeRecord("EEVEE", 20, 0x5EED0023),
      { assets = failing }
    )
    local failed = nil
    for _ = 1, 300 do
      sad.pump(1)
      if sad.screen:status().mode == "failed" then
        failed = sad.screen:status()
        break
      end
    end
    failed = assert(failed, "a preparation failure stops the screen")
    Assert.isTrue(
      (failed.error or ""):find("test%-scene%-missing", 1) ~= nil,
      "the preparation error reaches the failure context"
    )
    sad.screen:dispose()
    sad.battle:dispose()
  end

  -- Exactly-once release at every lifetime point: disposing twice
  -- during entry, playback, and terminal leave releases each owned
  -- handle once, keeps borrowed services usable, and drops queued input.
  local function disposeProbe(id, drive)
    local probeAssets = stubAssets({})
    local probeWindows = recordingWindows()
    local probeText = recordingText()
    local probe = openWildRig(
      modules,
      id,
      { species = "EEVEE", level = 20, seed = 0x0BADF00D },
      { species = "EEVEE", level = 5, seed = 0x0BADF00E, ability = "RUN_AWAY" },
      foeRecord("EEVEE", 20, 0x5EED0025),
      { assets = probeAssets, windows = probeWindows, text = probeText }
    )
    drive(probe)
    probe.screen:dispose()
    probe.screen:dispose()
    probe.screen:input({ { type = "confirm" } })
    probe.pump(1)
    probe.screen:draw({ graphics = FakeGraphics.new({}) })
    probe.battle:dispose()
    for key, total in pairs(probeAssets.released) do
      Assert.equal(total, 1, "the owned handle releases exactly once: " .. tostring(key))
    end
    Assert.isTrue(probeText.measure("after") ~= nil, "the borrowed text service stays usable after disposal")
    probeWindows.drawWindow({ x = 0, y = 0, w = 8, h = 8 }, "custom-test-frame", nil)
    Assert.isTrue(#probeWindows.calls > 0, "the borrowed window service stays usable after disposal")
    return probe
  end
  local entering = disposeProbe("launch-screen-dispose-entry", function(probe)
    probe.pump(1)
  end)
  Assert.equal(#entering.submits, 0, "disposing during entry seals nothing")
  local playing = disposeProbe("launch-screen-dispose-play", function(probe)
    driveToMode(probe, "command", 600)
    tap(probe, 128, 83 + 192)
    probe.pump(1)
  end)
  Assert.equal(#playing.submits, 0, "disposing during playback seals nothing")
  local terminal = disposeProbe("launch-screen-dispose-terminal", function(probe)
    driveToMode(probe, "command", 600)
    tap(probe, 128, 176 + 192)
    probe.pump(1)
    for _ = 1, 600 do
      ackNarration(probe)
      probe.pump(1)
      if probe.battle:status().phase == "complete" then
        break
      end
    end
    Assert.equal(probe.battle:status().phase, "complete", "the terminal probe settles before disposal")
  end)
  Assert.equal(#terminal.submits, 1, "disposing at terminal time keeps its single sealed reply")

  rig.screen:dispose()
  rig.battle:dispose()
end

-- A malformed staged manifest never boots a runnable screen: with the
-- required picture sections absent the real constructor fails naming
-- the missing field, and the schema validator rejects the same copy,
-- so no empty battle can pass as staged.
function T.malformed_staged_manifest_fails_before_any_command_input()
  local modules = battleScreenModules("strict staged manifest construction", STATE_MODULE)
  local withoutPictures = screenManifest(testSceneKey())
  withoutPictures.pictures = nil
  local ok, err = pcall(modules.state.new, {
    launchId = "launch-screen-malformed",
    manifest = withoutPictures,
    model = modules.model,
    submit = function(_)
      return true
    end,
    measureDisplay = dualMeasurement,
    assets = stubAssets({}),
    text = recordingText(),
    windows = recordingWindows(),
    audio = recordingAudio(false),
  })
  Assert.isFalse(ok, "a manifest without pictures never constructs a screen")
  Assert.isTrue(
    type(err) == "string" and err:find("pictures", 1) ~= nil,
    "the constructor names its missing pictures section: " .. tostring(err)
  )
  local schemaOk = pcall(BattlePresentationSchema.assertManifest, withoutPictures)
  Assert.isFalse(schemaOk, "the malformed copy also fails schema validation instead of reading as staged")
end

-- Detached scene selection never leaks between tests: retargeting one
-- copied manifest leaves a second copy and the shared source on their
-- own scenes, and every copy stays schema-valid.
function T.detached_manifest_copies_keep_their_own_scene_key()
  local Cache = require(PRESENTATION_CACHE_MODULE)
  local otherKey = Cache.sceneKey(Cache.BACKGROUNDS[4], Cache.TERRAINS[3], Cache.TIMES[1])
  local first = screenManifest(testSceneKey())
  local second = screenManifest(otherKey)
  Assert.equal(second.scenes[1].key, otherKey, "each copy carries its own requested scene")
  second.scenes[1].key = testSceneKey()
  second.scenes[1].background = Cache.BACKGROUNDS[1]
  second.scenes[1].terrain = Cache.TERRAINS[1]
  second.scenes[1].time = Cache.TIMES[1]
  Assert.equal(first.scenes[1].key, testSceneKey(), "retargeting a sibling copy never touches this copy")
  BattlePresentationSchema.assertManifest(first)
  BattlePresentationSchema.assertManifest(second)
  Assert.equal(
    BattlePresentationManifestFixture.manifest().scenes[1].key,
    "general/grass/day",
    "per-test copies never mutate the shared source fixture"
  )
end

---@param value integer unsigned word under staging
---@return string four little-endian bytes staging one command word
local function nativeU32(value)
  return string.char(
    value % 256,
    math.floor(value / 256) % 256,
    math.floor(value / 65536) % 256,
    math.floor(value / 16777216) % 256
  )
end

---@param list table<integer, integer> command words under staging
---@return string staged byte stream lowering one program
local function nativeStreamOf(list)
  local parts = {}
  for _, word in ipairs(list) do
    parts[#parts + 1] = nativeU32(word)
  end
  return table.concat(parts)
end

---@param launchId string owning launch identity under test preparation
---@return table staged-effect fixture holding a closed synthetic TACKLE program
local function stagedTackle(launchId)
  local EffectStagingFixture = require("tests.support.EffectStagingFixture")
  local BattleAnimationCompiler = require("romdump.src.digest.battle.BattleAnimationCompiler")
  local staging = EffectStagingFixture.new({ launchId = launchId })
  local record = EffectStagingFixture.effectRecord("TACKLE", {})
  local program =
    assert(BattleAnimationCompiler.compile({ key = "TACKLE", stream = nativeStreamOf({ 34, 1, 2, 3, 29, 50, 4 }) }))
  record.program = {
    entry = program.entry,
    instructions = program.instructions,
    subprograms = program.subprograms,
    taskKinds = program.taskKinds,
  }
  staging:stageEffect("TACKLE", record, {})
  return staging
end

---@param staging table staged-effect fixture under test preparation
---@return table preparation services serving portraits plus the staged TACKLE closure
local function nativeScreenServices(staging)
  local portraits = stubAssets({})
  local services = {}
  function services.prepare(demand)
    return portraits.prepare(demand)
  end
  function services.drawable(key)
    local staged = staging.services.drawable(key)
    if staged ~= nil then
      return staged
    end
    return portraits.drawable(key)
  end
  function services.release(key)
    portraits.release(key)
    return staging.services.release(key)
  end
  function services.requestEffect(key)
    return staging.services.requestEffect(key)
  end
  function services.loadEffect(key)
    return staging.services.loadEffect(key)
  end
  function services.resolveEffectResource(effect, resourceKey)
    return staging.services.resolveEffectResource(effect, resourceKey)
  end
  function services.releaseEffectResource(lease)
    return staging.services.releaseEffectResource(lease)
  end
  return services
end

---@return table detached own lead record under test driving
local function nativeOwnRecord()
  return {
    combatant = 1,
    participant = 1,
    side = 1,
    controller = "player",
    active = true,
    hp = 52,
    maxHp = 52,
    species = "EEVEE",
    form = 0,
    ballKey = "POKE_BALL",
    name = "LEAD",
    level = 20,
    selector = "back",
    moves = { { move = "TACKLE", name = "Tackle", pp = 35, maxPp = 35 } },
  }
end

---@param hp integer foe health under test driving
---@return table detached foe record under test driving
local function nativeFoeRecord(hp)
  return {
    combatant = 3,
    participant = 3,
    side = 2,
    controller = "wild",
    active = true,
    hp = hp,
    maxHp = 57,
    species = "EEVEE",
    form = 0,
    ballKey = "POKE_BALL",
    name = "FOE",
    level = 20,
    selector = "front",
  }
end

---@param foeHp integer foe health after the view under test driving
---@return table detached dynamic view under test driving
local function nativeView(foeHp)
  return {
    playerTrainer = { classKey = "PKMN_TRAINER_ETHAN", name = "MINT" },
    own = { nativeOwnRecord() },
    foes = { nativeFoeRecord(foeHp) },
  }
end

function T.native_animation_positioned_sound_reaches_screen_audio()
  local modules = battleScreenModules("positioned native effect audio", STATE_MODULE)
  local audio = recordingAudio(false)
  local screen = modules.state.new({
    launchId = "positioned-effect-sound",
    manifest = screenManifest(testSceneKey()),
    model = modules.model,
    submit = function(_)
      return true
    end,
    measureDisplay = dualMeasurement,
    assets = stubAssets({}),
    text = recordingText(),
    windows = recordingWindows(),
    audio = audio,
  })
  local player = screen._player
  local handle = assert(player:start({
    launchId = "positioned-effect-sound",
    packetId = 1,
    topology = {
      attacker = { combatant = 3, activation = 9, sideType = 1 },
      targets = { { combatant = 1, activation = 7, sideType = 0 } },
    },
  }, {
    entry = "main",
    subprograms = {},
    taskKinds = {},
    instructions = { { op = "play-positioned-sound", sound = "effect-probe", values = { 45 } } },
  }))
  player:stepSourceTick({ tick = 1 })
  Assert.equal(player:status(handle), "waiting", "the production player starts its sound")
  Assert.notNil(audio.pans, "the screen forwards positioned effects to panned audio")
  Assert.equal(audio.pans[1].symbol, "effect-probe", "the screen voices the named effect")
  Assert.equal(audio.pans[1].pan, -45, "the screen preserves source-relative pan")
  screen:dispose()
end

function T.native_animation_cry_reaches_the_attacker_voice()
  local modules = battleScreenModules("native effect cry", STATE_MODULE)
  local audio = recordingAudio(false)
  function audio:playCry(species, pattern, form, mode, pan, volume, pitch)
    self.cry =
      { species = species, pattern = pattern, form = form, mode = mode, pan = pan, volume = volume, pitch = pitch }
    return true
  end
  function audio:isCryFinished()
    return true
  end
  local catalog = {}
  function catalog:species(_)
    return { nativeId = 133 }
  end
  local screen = modules.state.new({
    launchId = "animation-cry",
    manifest = screenManifest(testSceneKey()),
    model = modules.model,
    submit = function(_)
      return true
    end,
    measureDisplay = dualMeasurement,
    assets = stubAssets({}),
    text = recordingText(),
    windows = recordingWindows(),
    audio = audio,
    monCatalog = catalog,
  })
  screen._timeline:reset(nativeView(57))
  local player = screen._player
  local handle = assert(player:start({
    launchId = "animation-cry",
    packetId = 1,
    topology = {
      attacker = { combatant = 3, activation = 9, sideType = 1 },
      targets = { { combatant = 1, activation = 7, sideType = 0 } },
    },
  }, {
    entry = "main",
    subprograms = {},
    taskKinds = {},
    instructions = { { op = "play-cry", values = { 5, 45, 127 } } },
  }))
  player:stepSourceTick({ tick = 1 })
  Assert.equal(player:status(handle), "waiting", "the screen owns the attacker's cry")
  Assert.notNil(audio.cry, "animation cry uses the actual cry player")
  Assert.equal(audio.cry.species, 133, "the attacker's visible species selects the cry")
  Assert.equal(audio.cry.pattern, 5, "the native cry pattern is preserved")
  Assert.equal(audio.cry.pan, -45, "the native cry pan is converted for the attacker")
  Assert.equal(audio.cry.volume, 127, "the native cry volume is preserved")
  screen:dispose()
end

---@return table detached active own lead record carrying real event-time slot facts
local function activeLeadRecord()
  local record = nativeOwnRecord()
  record.activation = 7
  record.position = 1
  return record
end

---@param combatant integer benched reserve identity under test driving
---@return table detached benched reserve record carrying no slot facts
local function reserveRecord(combatant)
  local record = nativeOwnRecord()
  record.combatant = combatant
  record.active = false
  record.name = "RESERVE"
  return record
end

---@param hp integer foe health under test driving
---@return table detached active foe record carrying real event-time slot facts
local function activeFoeRecord(hp)
  local record = nativeFoeRecord(hp)
  record.activation = 9
  record.position = 2
  return record
end

---@param foeHp integer foe health after the view under test driving
---@return table detached production-shaped dynamic view picturing a full own roster
local function rosterView(foeHp)
  return {
    playerTrainer = { classKey = "PKMN_TRAINER_ETHAN", name = "MINT" },
    own = { activeLeadRecord(), reserveRecord(2), reserveRecord(4) },
    foes = { activeFoeRecord(foeHp) },
  }
end

---@param view table displayed screen view under inspection
---@return integer displayed foe health
local function displayedFoeHp(view)
  for _, entry in ipairs(view.battlers or {}) do
    if entry.side == 2 then
      return entry.hp
    end
  end
  error("the displayed view names its foe", 0)
end

-- Live native-effect playback through the production screen: a Tackle
-- strike packet carrying its accepted semantic effect key demands only
-- that exact effect, runs the selected program through the screen-owned
-- player before the health checkpoint, holds readiness until real
-- completion, then applies the exact checkpoint and releases its
-- occurrence exactly once on disposal. The fixed source tick follows HGSS.
function T.live_tackle_strike_runs_its_selected_program_before_health()
  local modules = battleScreenModules("live native effects through one screen-owned player", STATE_MODULE)
  Assert.equal(modules.state.SOURCE_FRAME, SourceTick.DT, "the battle source tick matches the shared HGSS cadence")
  local launchId = "launch-screen-native-tackle"
  local staging = stagedTackle(launchId)
  local Model = modules.model
  local measurement = dualMeasurement()
  local text = recordingText()
  local windows = recordingWindows()
  local audio = recordingAudio(false)
  local submits = {}
  local screen = modules.state.new({
    launchId = launchId,
    manifest = screenManifest(testSceneKey()),
    model = Model,
    submit = function(reply)
      submits[#submits + 1] = reply
      return true
    end,
    measureDisplay = function()
      return measurement
    end,
    assets = nativeScreenServices(staging),
    text = text,
    windows = windows,
    audio = audio,
  })
  local port = screen:presentationPort()
  port.present({
    launchId = launchId,
    packetId = 1,
    events = {},
    before = nativeView(57),
    after = nativeView(57),
  })
  port.present({
    launchId = launchId,
    packetId = 2,
    events = {
      {
        sequence = 1,
        kind = "struck",
        cause = { key = "TACKLE" },
        audience = "public",
        actors = { { combatant = 1 } },
        targets = { { combatant = 3 } },
        move = { executed = "TACKLE" },
        actionId = 51,
        hitIndex = 1,
        effectKey = "TACKLE",
        payload = { target = 3, damage = 14, hitIndex = 1 },
        after = { hp = { [1] = 52, [3] = 43 } },
      },
    },
    before = nativeView(57),
    after = nativeView(43),
  })
  for _ = 1, 900 do
    local mode = screen:status().mode
    if mode == "intro" or mode == "narration" or mode == "outcome"
    or rig.screen._timeline:messageActive() or rig.screen._timeline:levelUpStats() ~= nil
  then
      screen:input({ { type = "confirm" } })
    end
    screen:updateFixed(TICK)
    if #staging.requests > 0 then
      break
    end
  end
  Assert.deepEqual(staging.requests, { "TACKLE" }, "only the selected TACKLE effect is ever demanded")
  Assert.isFalse(screen:status().ready, "the cue holds readiness until real completion")
  local settledHp = nil
  for _ = 1, 1200 do
    local mode = screen:status().mode
    if mode == "intro" or mode == "narration" or mode == "outcome"
    or rig.screen._timeline:messageActive() or rig.screen._timeline:levelUpStats() ~= nil
  then
      screen:input({ { type = "confirm" } })
    end
    screen:updateFixed(TICK)
    Assert.equal(
      #screen:view().effectInstances,
      0,
      "state-only visual work publishes no drawable picture while running"
    )
    if displayedFoeHp(screen:view()) == 43 and screen:status().ready then
      settledHp = 43
      break
    end
  end
  Assert.equal(settledHp, 43, "the exact checkpoint applies after real completion")
  Assert.deepEqual(staging.requests, { "TACKLE" }, "settling demands nothing beyond the selected effect")
  Assert.equal(#submits, 0, "presentation alone seals no reply")
  screen:dispose()
  Assert.deepEqual(staging.requests, { "TACKLE" }, "disposal starts no late effect work")
  port.present({
    launchId = launchId,
    packetId = 3,
    events = {},
    before = nativeView(43),
    after = nativeView(43),
  })
  Assert.deepEqual(staging.requests, { "TACKLE" }, "a late delivery after disposal demands nothing")
end

-- Benched reserves picture in the production own roster without slot
-- facts, so the screen must not invent live side positions from their
-- combatant identities: the strike still resolves the solo slots and
-- runs its selected program before the health checkpoint instead of
-- failing the topology with phantom positions.
function T.benched_reserves_contribute_no_live_side_positions()
  local modules = battleScreenModules("benched reserves keep no live side positions", STATE_MODULE)
  local launchId = "launch-screen-native-bench"
  local staging = stagedTackle(launchId)
  local Model = modules.model
  local measurement = dualMeasurement()
  local text = recordingText()
  local windows = recordingWindows()
  local audio = recordingAudio(false)
  local screen = modules.state.new({
    launchId = launchId,
    manifest = screenManifest(testSceneKey()),
    model = Model,
    submit = function(_)
      return true
    end,
    measureDisplay = function()
      return measurement
    end,
    assets = nativeScreenServices(staging),
    text = text,
    windows = windows,
    audio = audio,
  })
  local port = screen:presentationPort()
  port.present({
    launchId = launchId,
    packetId = 1,
    events = {},
    before = rosterView(57),
    after = rosterView(57),
  })
  port.present({
    launchId = launchId,
    packetId = 2,
    events = {
      {
        sequence = 1,
        kind = "struck",
        cause = { key = "TACKLE" },
        audience = "public",
        actors = { { combatant = 1, activation = 7 } },
        targets = { { combatant = 3, activation = 9 } },
        move = { executed = "TACKLE" },
        actionId = 51,
        hitIndex = 1,
        effectKey = "TACKLE",
        payload = { target = 3, damage = 14, hitIndex = 1 },
        after = { hp = { [1] = 52, [3] = 43 } },
      },
    },
    before = rosterView(57),
    after = rosterView(43),
  })
  for _ = 1, 900 do
    local mode = screen:status().mode
    if mode == "intro" or mode == "narration" or mode == "outcome"
    or rig.screen._timeline:messageActive() or rig.screen._timeline:levelUpStats() ~= nil
  then
      screen:input({ { type = "confirm" } })
    end
    screen:updateFixed(TICK)
    if #staging.requests > 0 then
      break
    end
  end
  Assert.deepEqual(staging.requests, { "TACKLE" }, "only the selected TACKLE effect is ever demanded")
  Assert.isNil(screen:status().error, "benched reserves fail no source topology")
  local settledHp = nil
  for _ = 1, 1200 do
    local mode = screen:status().mode
    if mode == "intro" or mode == "narration" or mode == "outcome"
    or rig.screen._timeline:messageActive() or rig.screen._timeline:levelUpStats() ~= nil
  then
      screen:input({ { type = "confirm" } })
    end
    screen:updateFixed(TICK)
    Assert.equal(
      #screen:view().effectInstances,
      0,
      "state-only visual work publishes no drawable picture past benched reserves"
    )
    if displayedFoeHp(screen:view()) == 43 and screen:status().ready then
      settledHp = 43
      break
    end
  end
  Assert.equal(settledHp, 43, "the exact checkpoint applies after real completion")
  screen:dispose()
end

function T.keypad_focus_cursor_hides_after_pointer_input()
  local modules = battleScreenModules("keypad focus belongs to the last input source", STATE_MODULE)
  local rig = openWildRig(
    modules,
    "launch-screen-keypad-focus",
    { species = "EEVEE", level = 20, seed = 0x77777777 },
    { species = "EEVEE", level = 5, seed = 0x88888888, ability = "RUN_AWAY" },
    foeRecord("EEVEE", 20, 0x5EED0007)
  )
  driveToMode(rig, "command", 600)

  Assert.isFalse(rig.screen:view().cursorVisible, "touch-first command input starts without the keypad cursor")
  rig.screen:input({ { type = "navigate", direction = "down" } })
  rig.pump(1)
  Assert.isTrue(rig.screen:view().cursorVisible, "keyboard focus shows the source keypad cursor")
  rig.screen:input({
    { type = "battle_press", control = { scope = "command", id = "bag" }, pointerId = 1 },
  })
  rig.pump(1)
  Assert.isFalse(rig.screen:view().cursorVisible, "touch input hides the keypad cursor")
  rig.screen:dispose()
end

return { tests = T }
