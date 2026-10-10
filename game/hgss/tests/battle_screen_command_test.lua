-- Controller coverage for the battle screen through the real runtime:
-- mode walking with reentrant edges, source identity maps, empty and
-- unusable slots with their reasons, narration acknowledgement
-- consumption, input-key rules, per-case overrides, the selection arrow
-- cycle, screen-level draw restoration, and sealed projected fragments.
-- Synthetic fixtures only.

local Assert = require("tests.support.Assert")
local ApplicationPresentation = require("libs.ui.src.ApplicationPresentation")
local BattleScreenInterface = require("game.hgss.src.battle.BattleScreenInterface")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local FakeGraphics = require("tests.support.FakeGraphics")
local HgssBagService = require("libs.hgss.src.items.HgssBagService")
local ItemFixture = require("libs.items.tests.item_fixture")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")
local ScreenTopology = require("libs.ui.src.ScreenTopology")

local T = {}
local TICK = 1 / 60

local STATE_MODULE = "game.hgss.src.battle.BattleScreenState"
local MODEL_MODULE = "game.hgss.src.battle.BattlePresentationModel"
local RUNTIME_MODULE = "game.hgss.src.battle.BattleRuntime"
local SCENARIO_FACTORY_MODULE = "libs.hgss.src.battle.HgssBattleScenarioFactory"

---@param species string
---@param level integer
---@param seed integer
---@return table full mon-domain record with a single known move
local function foeRecord(species, level, seed)
  local catalog = CatalogFixture.makeCatalog()
  local factory = CatalogFixture.makeFactory(seed, catalog)
  local record = factory:createNormal(CatalogFixture.normalRequest({ species = species, level = level }))
  record.moves = { { move = "TACKLE", pp = 35, ppUps = 0 } }
  return record
end

---@return table live party owner holding the described pair
local function makeParty(leadSpec, reserveSpec, leadPp)
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
  for index, member in ipairs({ leadSpec, reserveSpec }) do
    local factory = CatalogFixture.makeFactory(member.seed, catalog)
    local req = { species = member.species, level = member.level }
    if member.ability ~= nil then
      req.ability = member.ability
    end
    local record = factory:createNormal(CatalogFixture.normalRequest(req))
    local pp = 35
    if index == 1 and leadPp ~= nil then
      pp = leadPp
    end
    record.moves = { { move = "TACKLE", pp = pp, ppUps = 0 } }
    Assert.isTrue(owner:addMon(record), "the command path needs its live party member")
  end
  return owner
end

---@return table dual-surface display facts
local function dualMeasurement()
  return {
    width = 256,
    height = 384,
    topology = ScreenTopology.dualDisplay(
      { id = "main", rect = { x = 0, y = 0, width = 256, height = 192 }, touch = false, role = "world" },
      { id = "lower", rect = { x = 0, y = 192, width = 256, height = 192 }, touch = true, role = "auxiliary" },
      "battle-screen-command-test:dual"
    ),
    pixelRatio = 1,
    signature = "battle-screen-command-test:dual",
  }
end

---@return table recording text boundary with drawn content
local function recordingText()
  local text = { draws = {} }
  function text.measure(content)
    return { width = 8 * #tostring(content), height = 16 }
  end
  function text.drawText(content, x, y)
    text.draws[#text.draws + 1] = { content = tostring(content), x = x, y = y }
  end
  return text
end

---@param opts table? rig options: leadPp, overrides, seed
---@return table live rig with the runtime, screen, and submit log
local function openRig(opts)
  opts = opts or {}
  local BattleRuntime = require(RUNTIME_MODULE)
  local BattleScreenState = require(STATE_MODULE)
  local Model = require(MODEL_MODULE)
  local holder = {}
  local rig = { submits = {}, measurement = dualMeasurement(), text = recordingText() }
  rig.windows = { calls = {} }
  function rig.windows.drawWindow(box, frameKey, background)
    rig.windows.calls[#rig.windows.calls + 1] = { box = box, frame = frameKey, background = background }
  end
  rig.audio = { plays = {} }
  function rig.audio.play(name)
    rig.audio.plays[#rig.audio.plays + 1] = name
    return true
  end
  rig.assets = { hold = {}, images = {}, prepared = {}, released = {} }
  function rig.assets.prepare(demand)
    rig.assets.prepared[#rig.assets.prepared + 1] = demand
    return true
  end
  function rig.assets.drawable(key)
    if rig.assets.images[key] == nil then
      rig.assets.images[key] = { handle = key }
    end
    return rig.assets.images[key]
  end
  function rig.assets.release(key)
    rig.assets.released[key] = (rig.assets.released[key] or 0) + 1
  end
  local party = makeParty(
    { species = "EEVEE", level = 20, seed = 0x33333333 },
    { species = "EEVEE", level = 5, seed = 0x44444444, ability = "RUN_AWAY" },
    opts.leadPp
  )
  local bag = HgssBagService.new({ catalog = ItemFixture.makeCatalog() })
  local launchId = opts.launchId or "launch-screen-command"
  local launch = {
    id = launchId,
    kind = "wild",
    payload = { attemptId = launchId .. "-attempt", species = "EEVEE", form = 0, level = 4, personality = 1, ability = "RUN_AWAY" },
  }
  local ScenarioFactory = require(SCENARIO_FACTORY_MODULE)
  local scenario = ScenarioFactory.fromEncounter(
    { attemptId = launchId .. "-attempt", mon = foeRecord("EEVEE", 20, 0x5EED0002) },
    { party = party, bag = bag, player = { trainerId = 99, trainerName = "MINT", language = "french" } }
  )
  local screen = BattleScreenState.new({
    launchId = launchId,
    manifest = { schema = "test", version = { id = "t", language = "english" }, verified = false, scenes = { { key = "general/plain/day" } } },
    model = Model,
    submit = function(reply)
      rig.submits[#rig.submits + 1] = reply
      return holder.battle:submit(reply)
    end,
    measureDisplay = function()
      return rig.measurement
    end,
    assets = rig.assets,
    text = rig.text,
    windows = rig.windows,
    audio = rig.audio,
    overrides = opts.overrides,
  })
  rig.screen = screen
  rig.port = screen:presentationPort()
  holder.battle = BattleRuntime.new({
    request = launch,
    scenario = scenario,
    party = party,
    bag = bag,
    presentation = rig.port,
    seed = opts.seed or 0x12345678,
  })
  rig.battle = holder.battle
  rig.party = party
  function rig.pump(ticks, dt)
    for _ = 1, ticks or 1 do
      rig.battle:update()
      rig.screen:updateFixed(dt or TICK)
    end
  end
  return rig
end

---@param rig table live screen rig under test driving
---@param mode string awaited controller mode under test driving
---@return table the screen status once the mode is reached
local function driveToMode(rig, mode)
  for _ = 1, 600 do
    rig.pump(1)
    local status = rig.screen:status()
    if status.mode == "failed" then
      error("the battle screen failed while driving to " .. mode .. ": " .. tostring(status.error), 0)
    end
    if status.mode == mode then
      return status
    end
  end
  error("the battle screen never reached " .. mode, 0)
end

-- Command walking stays on one request: Fight opens moves, cancel
-- returns, reentrant confirms seal exactly one reply, and stale edges in
-- waiting seal nothing.
function T.command_walking_with_reentrant_edges_seals_once()
  local rig = openRig({})
  driveToMode(rig, "command")
  assert(rig.screen:status().request ~= nil, "the prompt mirrors its request")
  rig.screen:input({ { type = "confirm" } })
  rig.pump(1)
  Assert.equal(rig.screen:status().mode, "moves", "confirming Fight opens move selection")
  rig.screen:input({ { type = "confirm" } })
  rig.pump(1)
  Assert.equal(rig.screen:status().mode, "awaiting_resolution", "confirming the known slot submits")
  Assert.equal(#rig.submits, 1, "exactly one reply reaches the runtime")
  rig.screen:input({ { type = "confirm" } })
  rig.screen:input({ { type = "confirm" } })
  rig.pump(2)
  Assert.equal(#rig.submits, 1, "reentrant confirms while waiting seal nothing more")
  Assert.isNil(rig.screen:status().request, "the answered request is no longer mirrored as open")
  rig.screen:dispose()
  rig.battle:dispose()
end

-- Keyboard navigation follows the native touch topology across
-- commands and the two-by-two move table into cancel and back.
function T.navigation_follows_the_native_topology()
  local rig = openRig({})
  driveToMode(rig, "command")
  Assert.equal(rig.screen:view().selection, "fight", "the prompt rests on the first command")
  rig.screen:input({ { type = "navigate", direction = "right" } })
  rig.pump(1)
  Assert.equal(rig.screen:view().selection, "fight", "the wide top command keeps horizontal edges")
  rig.screen:input({ { type = "navigate", direction = "down" } })
  rig.pump(1)
  Assert.equal(rig.screen:view().selection, "run", "down from the top reaches the bottom middle")
  rig.screen:input({ { type = "navigate", direction = "left" } })
  rig.pump(1)
  Assert.equal(rig.screen:view().selection, "bag", "left from the middle reaches the lower left")
  rig.screen:input({ { type = "navigate", direction = "up" } })
  rig.pump(1)
  Assert.equal(rig.screen:view().selection, "fight", "up returns to the top command")
  rig.screen:input({ { type = "confirm" } })
  rig.pump(1)
  rig.screen:input({ { type = "navigate", direction = "down" } })
  rig.pump(1)
  rig.screen:input({ { type = "navigate", direction = "down" } })
  rig.pump(1)
  Assert.equal(rig.screen:view().selection, "cancel", "down through the table reaches cancel")
  rig.screen:input({ { type = "confirm" } })
  rig.pump(1)
  Assert.equal(rig.screen:status().mode, "command", "confirming cancel returns to command")
  rig.screen:dispose()
  rig.battle:dispose()
end

-- A genuinely spent move set keeps its slot with the kernel reason and
-- refuses without spending the turn, while the kernel struggle entry
-- stays reachable beside the native slots.
function T.spent_slots_refuse_with_their_reason()
  local rig = openRig({ leadPp = 0, launchId = "launch-screen-spent-local" })
  driveToMode(rig, "command")
  rig.screen:input({ { type = "confirm" } })
  rig.pump(1)
  Assert.equal(rig.screen:status().mode, "moves", "Fight still opens with no usable power")
  local moves = assert(rig.screen:view().moves, "the spent slots stay listed")
  Assert.isFalse(moves[1].enabled, "the spent slot is not selectable")
  Assert.isTrue(type(moves[1].reason) == "string" and moves[1].reason ~= "", "the spent slot keeps its reason")
  local struggle = nil
  for _, move in ipairs(moves) do
    if move.slot == 4 then
      struggle = move
    end
  end
  Assert.notNil(struggle, "the kernel struggle entry stays reachable")
  rig.screen:input({ { type = "confirm" } })
  rig.pump(1)
  Assert.equal(rig.screen:status().mode, "moves", "confirming the spent slot stays on the decision")
  Assert.equal(#rig.submits, 0, "the refused slot spends no turn")
  rig.screen:dispose()
  rig.battle:dispose()
end

local openSealingScreen ---@type fun(launchId: string, specs: table[], requestId: integer): table

-- Paired pointer focus then confirmation seals the focused move once:
-- the first complete press on a new slot only moves focus, the second
-- matched press seals the exact projected fragment, and a later orphan
-- release seals nothing more.
function T.paired_second_tap_seals_the_focused_move_once()
  local rig = openSealingScreen("launch-paired-confirm-local", {
    { id = "move:0", slot = 0, move = "TACKLE", name = "Tackle", pp = 35, maxPp = 35, target = { kind = "position", position = 2 } },
    { id = "move:1", slot = 1, move = "GROWL", name = "Growl", pp = 40, maxPp = 40, target = { kind = "position", position = 2 } },
  }, 9010)
  rig.screen:input({ { type = "confirm" } })
  rig.pump(1)
  Assert.equal(rig.screen:status().mode, "moves", "Fight opens move selection")
  Assert.equal(rig.screen:view().selection, "move:0", "move selection rests on the first slot")
  local x, y = 192, 236
  rig.screen:input({ { type = "pointer_down", pointerId = "touch:focus", x = x, y = y } })
  rig.screen:input({ { type = "pointer_up", pointerId = "touch:focus", x = x, y = y } })
  rig.pump(1)
  Assert.equal(rig.screen:view().selection, "move:1", "the first tap focuses the new slot")
  Assert.equal(#rig.submits, 0, "the first tap seals nothing")
  local request = assert(rig.screen:status().request, "the prompt mirrors its request")
  local projected = rig.expectedById["move:1"]
  Assert.notNil(projected, "the focused slot carries its projected fragment")
  rig.screen:input({ { type = "pointer_down", pointerId = "touch:seal", x = x, y = y } })
  rig.screen:input({ { type = "pointer_up", pointerId = "touch:seal", x = x, y = y } })
  rig.pump(1)
  Assert.equal(#rig.submits, 1, "the second matched tap seals once")
  Assert.equal(rig.screen:status().mode, "awaiting_resolution", "the sealed move waits for resolution")
  local sealed = assert(rig.submits[1], "the sealed reply is recorded")
  Assert.equal(sealed.requestId, request.requestId, "the reply answers the open request")
  Assert.equal(sealed.epoch, request.epoch, "the reply carries the open epoch")
  Assert.equal(sealed.controller, request.controller, "the reply carries the open controller")
  Assert.deepEqual(sealed.choices[1], projected, "the sealed fragment keeps its actor and target")
  rig.screen:input({ { type = "pointer_up", pointerId = "touch:orphan", x = x, y = y } })
  rig.pump(1)
  Assert.equal(#rig.submits, 1, "an orphan release seals nothing more")
  rig.screen:dispose()
end

---@param launchId string owning launch identity under test driving
---@param specs table[] projected move specs with id, move, name, pp, maxPp, and target under test driving
---@param requestId integer synthetic request identity under test driving
---@return table live screen-only rig with an accepting submit boundary
function openSealingScreen(launchId, specs, requestId)
  local BattleScreenState = require(STATE_MODULE)
  local Model = require(MODEL_MODULE)
  local rig = { submits = {}, measurement = dualMeasurement(), text = recordingText() }
  rig.windows = { calls = {} }
  function rig.windows.drawWindow(box, frameKey, background)
    rig.windows.calls[#rig.windows.calls + 1] = { box = box, frame = frameKey, background = background }
  end
  rig.audio = { plays = {} }
  function rig.audio.play(name)
    rig.audio.plays[#rig.audio.plays + 1] = name
    return true
  end
  rig.assets = { hold = {}, images = {}, prepared = {}, released = {} }
  function rig.assets.prepare(demand)
    rig.assets.prepared[#rig.assets.prepared + 1] = demand
    return true
  end
  function rig.assets.drawable(key)
    if rig.assets.images[key] == nil then
      rig.assets.images[key] = { handle = key }
    end
    return rig.assets.images[key]
  end
  function rig.assets.release(key)
    rig.assets.released[key] = (rig.assets.released[key] or 0) + 1
  end
  local screen = BattleScreenState.new({
    launchId = launchId,
    manifest = { schema = "test", version = { id = "t", language = "english" }, verified = false, scenes = { { key = "general/plain/day" } } },
    model = Model,
    submit = function(reply)
      rig.submits[#rig.submits + 1] = reply
      return true
    end,
    measureDisplay = function()
      return rig.measurement
    end,
    assets = rig.assets,
    text = rig.text,
    windows = rig.windows,
    audio = rig.audio,
  })
  rig.screen = screen
  rig.port = screen:presentationPort()
  function rig.pump(ticks, dt)
    for _ = 1, ticks or 1 do
      rig.screen:updateFixed(dt or TICK)
    end
  end
  local BattleProtocol = require("libs.battle.src.BattleProtocol")
  local offered = {}
  rig.expectedById = {}
  for _, spec in ipairs(specs) do
    local choice = {
      actor = { combatant = 1, activation = 1 },
      kind = "attack",
      payload = { moveSlot = spec.slot, target = spec.target },
    }
    BattleProtocol.validateTarget(spec.target)
    BattleProtocol.validateChoice(choice, "action")
    offered[#offered + 1] = {
      id = spec.id,
      role = "move",
      display = { move = spec.move, name = spec.name, pp = spec.pp, maxPp = spec.maxPp },
      enabled = true,
      choice = choice,
    }
    rig.expectedById[spec.id] = choice
  end
  local actors = {
    {
      combatant = 1,
      activation = 1,
      kind = "action",
      choices = offered,
    },
  }
  local decision = {
    requestId = requestId,
    epoch = 1,
    controller = "player",
    kind = "action",
    actors = actors,
  }
  decision.options = {
    requestId = requestId,
    epoch = 1,
    controller = "player",
    kind = "action",
    actors = actors,
  }
  local function ownRecord()
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
      name = "LEAD",
      level = 20,
      selector = "back",
      moves = { { move = "TACKLE", name = "Tackle", pp = 35, maxPp = 35 } },
    }
  end
  local function foeRecordEntry()
    return {
      combatant = 3,
      participant = 3,
      side = 2,
      controller = "wild",
      active = true,
      hp = 57,
      maxHp = 57,
      species = "EEVEE",
      form = 0,
      name = "FOE",
      level = 20,
      selector = "front",
    }
  end
  rig.expectedChoice = rig.expectedById[specs[1].id]
  rig.port.present({
    launchId = launchId,
    packetId = 4242,
    events = {},
    before = { own = { ownRecord() }, foes = { foeRecordEntry() } },
    after = { own = { ownRecord() }, foes = { foeRecordEntry() } },
    request = decision,
    result = nil,
  })
  for _ = 1, 600 do
    rig.pump(1)
    local status = rig.screen:status()
    if status.mode == "failed" then
      error("the sealing screen failed while driving to command: " .. tostring(status.error), 0)
    end
    if status.mode == "command" and status.request ~= nil and status.request.requestId == requestId then
      return rig
    end
  end
  error("the sealing screen never reached its command decision", 0)
  return rig
end

-- Complete projected intents seal unchanged: side-wide and field-wide
-- fragments never open a picker and never rewrite their target.
function T.projected_side_and_field_targets_seal_unchanged()
  local side = openSealingScreen("launch-sealed-side-local", {
    { id = "move:0", slot = 0, move = "TACKLE", name = "Tackle", pp = 35, maxPp = 35, target = { kind = "side", side = 2 } },
  }, 9001)
  side.screen:input({ { type = "confirm" } })
  side.pump(1)
  Assert.equal(side.screen:status().mode, "moves", "Fight opens move selection for the side intent")
  side.screen:input({ { type = "confirm" } })
  side.pump(1)
  Assert.equal(#side.submits, 1, "the side intent seals without a picker")
  Assert.isTrue(side.screen:status().mode ~= "target", "the side intent never opens target selection")
  local sideSealed = assert(side.submits[1], "the side reply is recorded")
  Assert.deepEqual(sideSealed.choices[1], side.expectedChoice, "the side fragment keeps its target")
  side.screen:dispose()
  local field = openSealingScreen("launch-sealed-field-local", {
    { id = "move:0", slot = 0, move = "TACKLE", name = "Tackle", pp = 35, maxPp = 35, target = { kind = "field" } },
  }, 9002)
  field.screen:input({ { type = "confirm" } })
  field.pump(1)
  Assert.equal(field.screen:status().mode, "moves", "Fight opens move selection for the field intent")
  field.screen:input({ { type = "pointer_down", pointerId = "touch:field", x = 64, y = 237 } })
  field.screen:input({ { type = "pointer_up", pointerId = "touch:field", x = 64, y = 237 } })
  field.pump(1)
  Assert.equal(#field.submits, 1, "touch on the focused slot seals the field intent")
  Assert.isTrue(field.screen:status().mode ~= "target", "the field intent never opens target selection")
  local fieldSealed = assert(field.submits[1], "the field reply is recorded")
  Assert.deepEqual(fieldSealed.choices[1], field.expectedChoice, "the field fragment keeps its target")
  field.screen:dispose()
end

-- Overlong labels never escape their regions: narration and menu text
-- truncate through the borrowed measure service.
function T.long_labels_truncate_inside_their_regions()
  local rig = openRig({})
  driveToMode(rig, "command")
  rig.screen:input({ { type = "confirm" } })
  rig.pump(1)
  local graphics = FakeGraphics.new({})
  rig.screen:draw({ graphics = graphics })
  for _, drawn in ipairs(rig.text.draws) do
    Assert.isTrue(#drawn.content <= 30, "drawn labels stay inside their regions: " .. drawn.content)
  end
  rig.screen:dispose()
  rig.battle:dispose()
end

-- Narration consumes its acknowledgement edges: confirming during the
-- opening never submits and never exposes the prompt early.
function T.opening_narration_consumes_its_edges()
  local rig = openRig({ launchId = "launch-screen-narration-local" })
  local opened = false
  for _ = 1, 60 do
    rig.pump(1)
    local mode = rig.screen:status().mode
    if mode == "intro" or mode == "narration" then
      opened = true
      break
    end
  end
  Assert.isTrue(opened, "the opening plays its cues first")
  rig.screen:input({ { type = "confirm" } })
  rig.screen:input({ { type = "confirm" } })
  rig.pump(2)
  Assert.equal(#rig.submits, 0, "narration edges never submit")
  driveToMode(rig, "command")
  rig.screen:dispose()
  rig.battle:dispose()
end

-- Outside presses change nothing and dismiss nothing; the input key
-- stays stable across redraws and turns on semantic changes.
function T.outside_presses_change_nothing_and_keys_track_semantics()
  local rig = openRig({})
  driveToMode(rig, "command")
  local key = assert(rig.screen:status().presentation, "the prompt carries its plan").inputKey
  rig.screen:input({ { type = "pointer_down", pointerId = "touch:9", x = 10, y = 10 } })
  rig.screen:input({ { type = "pointer_up", pointerId = "touch:9", x = 10, y = 10 } })
  rig.pump(1)
  Assert.equal(rig.screen:status().mode, "command", "outside presses keep the decision")
  Assert.equal(#rig.submits, 0, "outside presses seal nothing")
  Assert.equal(rig.screen:status().presentation.inputKey, key, "redraws keep the input identity")
  rig.screen:input({ { type = "confirm" } })
  rig.pump(1)
  Assert.isTrue(rig.screen:status().presentation.inputKey ~= key, "semantic changes turn the input key")
  rig.screen:dispose()
  rig.battle:dispose()
end

-- A per-case resolver override replaces the whole paired plan and an
-- unknown override key fails the screen explicitly instead of half
-- resolving.
function T.case_overrides_replace_plans_and_bad_keys_fail()
  local defaults = BattleScreenInterface.defaults()
  local seen = {}
  local custom = {}
  for key, resolver in pairs(defaults) do
    custom[key] = function(context, view)
      seen[#seen + 1] = key
      local plan = resolver(context, view)
      plan.content.overrideTag = "local-probe"
      return plan
    end
  end
  local rig = openRig({ overrides = { cases = custom }, launchId = "launch-screen-override-local" })
  driveToMode(rig, "command")
  Assert.isTrue(#seen > 0, "the per-case override resolves")
  Assert.equal(
    rig.screen:status().presentation.content.overrideTag,
    "local-probe",
    "the override plan publishes"
  )
  rig.screen:dispose()
  rig.battle:dispose()
  local sad = openRig({ overrides = { cases = { noSuchCase = function() end } }, launchId = "launch-screen-badkey-local" })
  sad.pump(2)
  Assert.equal(sad.screen:status().mode, "failed", "an unknown override key fails explicitly")
  sad.screen:dispose()
  sad.battle:dispose()
end

-- The selection arrow traverses its cycle finitely: drawing across many
-- ticks cycles with a fixed period and never hangs on the zero-time
-- entry.
function T.arrow_cycles_with_a_fixed_period()
  local rig = openRig({})
  driveToMode(rig, "command")
  local shapes = {}
  for _ = 1, 40 do
    rig.pump(1)
    local graphics = FakeGraphics.new({})
    rig.screen:draw({ graphics = graphics })
    local parts = {}
    for _, entry in ipairs(graphics.draws) do
      parts[#parts + 1] = tostring(entry.x) .. "," .. tostring(entry.y)
    end
    shapes[#shapes + 1] = table.concat(parts, "|")
  end
  Assert.equal(shapes[1], shapes[35], "the arrow cycle repeats with its authored period")
  rig.screen:dispose()
  rig.battle:dispose()
end

-- Screen drawing restores borrowed graphics state exactly.
function T.screen_draw_restores_borrowed_state()
  local rig = openRig({})
  driveToMode(rig, "command")
  local graphics = FakeGraphics.new({})
  local function state()
    local r, g, b, a = graphics.getColor()
    return { color = { r, g, b, a }, canvas = graphics.getCanvas(), shader = graphics.getShader(), blend = graphics.getBlendMode(), scissor = graphics.getScissor(), depth = graphics:pushDepth() }
  end
  local before = state()
  rig.screen:draw({ graphics = graphics })
  Assert.deepEqual(state(), before, "the screen draw restores borrowed graphics state exactly")
  Assert.isTrue(#graphics.draws > 0, "the screen draw reaches the recording boundary")
  rig.screen:dispose()
  rig.battle:dispose()
end

-- Direct native-pane harness: synthetic snapshots through the real battle
-- renderer with minting asset stubs and a recording text boundary, so
-- composite anchors, cell quads, and dynamic wording pin exactly.
local RENDERER_MODULE = "game.hgss.src.battle.BattleRenderer"

---@param overrides table? snapshot fields replacing the healthy defaults
---@return table internal semantic snapshot under drawing
local function nativeView(overrides)
  local view = {
    mode = "command",
    selection = "fight",
    armed = nil,
    requestId = 7,
    message = "",
    messageId = 1,
    battlers = {
      {
        combatant = 1,
        side = 1,
        hp = 30,
        maxHp = 30,
        visible = true,
        name = "LEAD",
        level = 9,
        exp = 120,
        condition = "burn",
        shakeDx = 0,
      },
      {
        combatant = 2,
        side = 2,
        hp = 12,
        maxHp = 12,
        visible = true,
        name = "FOE",
        level = 3,
        exp = nil,
        condition = nil,
        shakeDx = 0,
      },
    },
    commands = {
      { id = "fight", enabled = true },
      { id = "bag", enabled = true },
      { id = "pokemon", enabled = true },
      { id = "run", enabled = true },
    },
    moves = {
      { slot = 0, name = "TACKLE", pp = 35, maxPp = 35, moveType = "NORMAL", enabled = true },
      { slot = 1, name = "GROWL", pp = 40, maxPp = 40, moveType = "NORMAL", enabled = true },
    },
    partyRoster = {
      { slot = 0, hp = 30, maxHp = 30 },
      { slot = 1, hp = 0, maxHp = 28 },
    },
    foeCount = 2,
    arrowFrame = 1,
    childIntent = nil,
  }
  if overrides ~= nil then
    for key, value in pairs(overrides) do
      view[key] = value
    end
  end
  return view
end

---@param paneId string drawn pane identity
---@param view table internal semantic snapshot under drawing
---@param layout string? interaction layout under drawing
---@param held string[]? artwork keys reporting unavailable
---@return table graphics, text, and window records behind one draw
local function drawNativePane(paneId, view, layout, held)
  local BattleRenderer = require(RENDERER_MODULE)
  local graphics = FakeGraphics.new({})
  local text = recordingText()
  local windows = { calls = {} }
  function windows.drawWindow(box, frameKey, background)
    windows.calls[#windows.calls + 1] = { box = box, frame = frameKey, background = background }
  end
  local missing = {}
  for _, key in ipairs(held or {}) do
    missing[key] = true
  end
  local resources = {
    graphics = graphics,
    text = text,
    windows = windows,
    assets = {
      drawable = function(_, key)
        if missing[key] then
          return nil
        end
        return { handle = key }
      end,
    },
    frameKey = "default",
    sceneImageKey = "scene:test",
  }
  local content = {}
  if paneId == "interaction" then
    content = { layout = layout or "command" }
  end
  BattleRenderer.drawPane(resources, view, paneId, content)
  return { graphics = graphics, text = text, windows = windows }
end

---@param graphics table recording graphics boundary under inspection
---@param handle string artwork identity under inspection
---@return table[] draws carrying that artwork identity, in draw order
local function drawsOf(graphics, handle)
  local found = {}
  for _, entry in ipairs(graphics.draws) do
    if type(entry.image) == "table" and entry.image.handle == handle then
      found[#found + 1] = entry
    end
  end
  return found
end

---@param text table recording text boundary under inspection
---@param content string drawn wording under inspection
---@param x number drawn horizontal origin under inspection
---@param y number drawn vertical origin under inspection
---@return boolean true when the exact wording draws at the anchor
local function textAt(text, content, x, y)
  for _, entry in ipairs(text.draws) do
    if entry.content == content and entry.x == x and entry.y == y then
      return true
    end
  end
  return false
end

-- The HUD composites draw at their anchors with the compiled local
-- offsets: two 64x64 objects each, banded into 8-pixel quads over the
-- staged strip row. The enemy anchor stays unclamped offscreen.
function T.native_hud_composites_draw_at_anchors_with_compiled_offsets()
  local drawn = drawNativePane("detail", nativeView({ arrowFrame = 0 }), nil, {})
  local player = drawsOf(drawn.graphics, "hud:player")
  Assert.equal(#player, 16, "the player composite draws two banded objects")
  Assert.equal(player[1].x, 128, "the player composite starts at anchor.x-64")
  Assert.equal(player[1].y, 84, "the player composite starts at anchor.y-32")
  Assert.equal(player[1].quad.x, 0, "the player composite opens its first tile")
  Assert.equal(player[1].quad.w, 64, "the player bands span the object width")
  Assert.equal(player[1].quad.imgW, 1024, "the player quads reference the staged strip width")
  Assert.equal(player[8].y, 140, "the player first object bands cover 64 pixels")
  Assert.equal(player[9].x, 192, "the player second object starts at anchor.x")
  Assert.equal(player[9].y, 84, "the player second object shares the row")
  Assert.equal(player[9].quad.x, 256, "the player second object opens tile 32")
  local enemy = drawsOf(drawn.graphics, "hud:enemy")
  Assert.equal(#enemy, 16, "the enemy composite draws two banded objects")
  Assert.equal(enemy[1].x, -6, "the enemy composite starts offscreen unclamped")
  Assert.equal(enemy[1].y, 8, "the enemy composite starts at anchor.y-28")
  Assert.equal(enemy[1].quad.x, 0, "the enemy composite opens its first tile")
  Assert.equal(enemy[9].x, 58, "the enemy second object starts at anchor.x")
  Assert.equal(enemy[9].y, 8, "the enemy second object shares the row")
  Assert.equal(enemy[9].quad.x, 256, "the enemy second object opens tile 32")
end

-- Dynamic HUD content sits in the composite geometry: names, levels, and
-- conditions on both sides, numeric health and experience on the player
-- side only, and a fraction bar per side. Foe numbers never print.
function T.native_hud_dynamic_content_uses_composite_geometry()
  local drawn = drawNativePane("detail", nativeView({ arrowFrame = 0 }), nil, {})
  Assert.isTrue(textAt(drawn.text, "LEAD", 144, 92), "the player name keeps its anchor")
  Assert.isTrue(textAt(drawn.text, "Lv9", 144, 104), "the player level keeps its anchor")
  Assert.isTrue(textAt(drawn.text, "30/30", 144, 116), "the player prints numeric health")
  Assert.isTrue(textAt(drawn.text, "120", 192, 116), "the player prints numeric experience")
  Assert.isTrue(textAt(drawn.text, "burn", 176, 104), "the player prints its major condition")
  Assert.isTrue(textAt(drawn.text, "FOE", 8, 16), "the foe name keeps its anchor")
  Assert.isTrue(textAt(drawn.text, "Lv3", 8, 28), "the foe level keeps its anchor")
  for _, entry in ipairs(drawn.text.draws) do
    Assert.isFalse(entry.content == "12/12", "the foe prints no numeric health")
  end
  local bars = {}
  for _, entry in ipairs(drawn.graphics.rectangles) do
    if entry.mode == "fill" then
      bars[#bars + 1] = entry
    end
  end
  Assert.equal(#bars, 2, "both sides fill their health bar")
  Assert.equal(bars[1].x, 8, "the foe bar sits in the enemy composite")
  Assert.equal(bars[1].y, 44, "the foe bar mirrors the player bar row")
  Assert.equal(bars[1].w, 48, "the full foe bar spans its slot")
  Assert.equal(bars[2].x, 144, "the player bar keeps its anchor")
  Assert.equal(bars[2].y, 108, "the player bar keeps its row")
  Assert.equal(bars[2].w, 48, "the full player bar spans its slot")
end

-- Missing strips draw nothing and never substitute: held keys skip their
-- composites while the wording and bars still draw.
function T.native_missing_art_draws_nothing()
  local drawn = drawNativePane("detail", nativeView({ arrowFrame = 3 }), nil, { "hud:player", "hud:enemy", "arrow" })
  Assert.equal(#drawsOf(drawn.graphics, "hud:player"), 0, "the held player strip draws nothing")
  Assert.equal(#drawsOf(drawn.graphics, "hud:enemy"), 0, "the held enemy strip draws nothing")
  Assert.equal(#drawsOf(drawn.graphics, "arrow"), 0, "the held arrow draws nothing")
  Assert.isTrue(textAt(drawn.text, "LEAD", 144, 92), "held art keeps the player wording")
  Assert.isTrue(textAt(drawn.text, "FOE", 8, 16), "held art keeps the foe wording")
end

-- The arrow draws its authored cells: the zero-time opening cell draws
-- nothing, every other cell bands its objects over the arrow strip, and
-- unknown frames draw nothing.
function T.native_arrow_draws_authored_cells_with_bounded_zero_advance()
  local zero = drawNativePane("detail", nativeView({ arrowFrame = 0 }), nil, {})
  Assert.equal(#drawsOf(zero.graphics, "arrow"), 0, "the zero-time cell draws nothing")
  local first = drawNativePane("detail", nativeView({ arrowFrame = 1 }), nil, {})
  local one = drawsOf(first.graphics, "arrow")
  Assert.equal(#one, 2, "the first cell bands its one object")
  Assert.equal(one[1].x, 112, "the arrow sits left of the player anchor")
  Assert.equal(one[1].y, 106, "the arrow shares the player anchor row")
  Assert.equal(one[1].quad.x, 0, "the first cell opens tile 0")
  Assert.equal(one[1].quad.imgW, 208, "the arrow quads reference the staged strip width")
  Assert.equal(one[2].quad.x, 16, "the first cell bands row-major")
  local third = drawNativePane("detail", nativeView({ arrowFrame = 3 }), nil, {})
  local three = drawsOf(third.graphics, "arrow")
  Assert.equal(#three, 4, "the third cell bands its two objects")
  Assert.equal(three[1].x, 104, "the wider cells reach further left")
  Assert.equal(three[1].quad.x, 32, "the third cell opens tile 4")
  Assert.equal(three[3].x, 120, "the second object abuts the first")
  Assert.equal(three[3].quad.x, 48, "the second object opens tile 6")
  Assert.equal(three[3].quad.w, 8, "the second object keeps its narrow width")
  local fifth = drawNativePane("detail", nativeView({ arrowFrame = 5 }), nil, {})
  local five = drawsOf(fifth.graphics, "arrow")
  Assert.equal(#five, 4, "the final cell bands its two objects")
  Assert.equal(five[1].quad.x, 80, "the final cell opens tile 10")
  Assert.equal(five[3].quad.x, 96, "the final narrow object opens tile 12")
  for _, frame in ipairs({ -1, 6 }) do
    local stray = drawNativePane("detail", nativeView({ arrowFrame = frame }), nil, {})
    Assert.equal(#drawsOf(stray.graphics, "arrow"), 0, "frame " .. frame .. " draws no arrow")
  end
  local missing = nativeView({})
  missing.arrowFrame = nil
  local silent = drawNativePane("detail", missing, nil, {})
  Assert.equal(#drawsOf(silent.graphics, "arrow"), 0, "a missing frame draws no arrow")
end

-- The live selection clock traverses the authored cells with their
-- authored counts: every displayed cell carries art, the order cycles
-- 1 through 5 with a 34-tick period, and the zero-time entry never
-- displays or hangs the cycle.
function T.native_arrow_cycles_through_authored_cells()
  local rig = openRig({})
  driveToMode(rig, "command")
  local cellOfQuadX = { [0] = 1, [16] = 2, [32] = 3, [56] = 4, [80] = 5 }
  local counts = { [1] = 0, [2] = 0, [3] = 0, [4] = 0, [5] = 0 }
  local order = {}
  for _ = 1, 68 do
    rig.pump(1)
    local graphics = FakeGraphics.new({})
    rig.screen:draw({ graphics = graphics })
    local bands = drawsOf(graphics, "arrow")
    Assert.isTrue(#bands == 2 or #bands == 4, "every displayed arrow cell carries art")
    local cell = cellOfQuadX[bands[1].quad.x]
    Assert.notNil(cell, "every arrow band opens an authored tile")
    counts[cell] = counts[cell] + 1
    if order[#order] ~= cell then
      order[#order + 1] = cell
    end
  end
  Assert.deepEqual(counts, { [1] = 8, [2] = 8, [3] = 8, [4] = 32, [5] = 12 }, "two periods hold the authored counts")
  for index = 2, #order do
    Assert.equal(order[index], order[index - 1] % 5 + 1, "the cells cycle in authored order")
  end
  rig.screen:dispose()
  rig.battle:dispose()
end

-- Party gauges draw source cells by roster visibility: the committed
-- battle roster behind the player row, the revealed foe count behind
-- the enemy row. Unrevealed foes keep the absent cell.
function T.native_gauges_use_source_cells_by_roster_visibility()
  local drawn = drawNativePane("interaction", nativeView({}), "command", {})
  local player = drawsOf(drawn.graphics, "gauges:player")
  Assert.equal(#player, 12, "the player row bands six cells")
  Assert.equal(player[1].x, 4, "the player cells center on their slots")
  Assert.equal(player[1].y, 5, "the player row keeps its origin")
  Assert.equal(player[1].quad.x, 32, "the healthy lead selects its cell")
  Assert.equal(player[1].quad.imgW, 128, "the gauge quads reference the staged strip width")
  Assert.equal(player[3].quad.x, 64, "the fainted reserve selects its cell")
  Assert.equal(player[5].quad.x, 0, "the empty slots keep the absent cell")
  Assert.equal(player[5].x, 42, "the third slot keeps its pitch")
  local enemy = drawsOf(drawn.graphics, "gauges:enemy")
  Assert.equal(#enemy, 12, "the enemy row bands six cells")
  Assert.equal(enemy[1].x, 222, "the enemy row keeps its right origin")
  Assert.equal(enemy[1].y, 1, "the enemy row keeps its row")
  Assert.equal(enemy[1].quad.x, 32, "the revealed foe selects its cell")
  Assert.equal(enemy[3].quad.x, 32, "the second foe selects its cell")
  Assert.equal(enemy[5].quad.x, 0, "unrevealed foes keep the absent cell")
end

-- The live roster behind the real battle selects the same cells: the
-- two standing party members light their slots while the rest stay
-- absent, and the single revealed foe lights only its own slot.
function T.native_gauges_follow_the_live_roster()
  local rig = openRig({})
  driveToMode(rig, "command")
  local graphics = FakeGraphics.new({})
  rig.screen:draw({ graphics = graphics })
  local player = drawsOf(graphics, "gauges:player")
  Assert.equal(#player, 12, "the live player row bands six cells")
  Assert.equal(player[1].quad.x, 32, "the live lead selects its cell")
  Assert.equal(player[3].quad.x, 32, "the live reserve selects its cell")
  Assert.equal(player[5].quad.x, 0, "the live empty slots keep the absent cell")
  local enemy = drawsOf(graphics, "gauges:enemy")
  Assert.equal(#enemy, 12, "the live enemy row bands six cells")
  Assert.equal(enemy[1].quad.x, 32, "the live foe selects its cell")
  Assert.equal(enemy[3].quad.x, 0, "unrevealed live foes keep the absent cell")
  rig.screen:dispose()
  rig.battle:dispose()
end

-- Move facts sit at their compiled anchors: names keep the two-by-two
-- anchors, types sit left on the lower row, and PP splits into current
-- and max fields. The merged single string never draws.
function T.native_move_facts_use_compiled_type_and_split_pp_anchors()
  local rig = openRig({})
  driveToMode(rig, "command")
  rig.screen:input({ { type = "confirm" } })
  rig.pump(1)
  Assert.equal(rig.screen:status().mode, "moves", "Fight opens move selection")
  local moves = assert(rig.screen:view().moves, "the move facts stay listed")
  local first = nil
  for _, move in ipairs(moves) do
    if move.slot == 0 then
      first = move
    end
  end
  first = assert(first, "the first slot stays listed")
  local graphics = FakeGraphics.new({})
  rig.screen:draw({ graphics = graphics })
  local text = rig.text
  Assert.isTrue(textAt(text, first.name, 64, 45), "the first move name keeps its anchor: " .. tostring(first.name))
  Assert.isTrue(textAt(text, first.moveType, 32, 61), "the type sits left on the lower row: " .. tostring(first.moveType))
  Assert.isTrue(textAt(text, tostring(first.pp), 59, 61), "the PP current keeps its field: " .. tostring(first.pp))
  Assert.isTrue(textAt(text, "/" .. tostring(first.maxPp), 76, 61), "the PP max keeps its field: " .. tostring(first.maxPp))
  for _, entry in ipairs(text.draws) do
    Assert.isNil(
      tostring(entry.content):match("^PP %d+/%d+$"),
      "the merged PP string never draws: " .. tostring(entry.content)
    )
  end
  rig.screen:dispose()
  rig.battle:dispose()
end

-- The arrow shows only while a decision is open: leaving the selection
-- hides it while the composites and gauges keep drawing.
function T.native_arrow_hides_outside_selection_modes()
  local rig = openRig({})
  driveToMode(rig, "command")
  local shown = FakeGraphics.new({})
  rig.screen:draw({ graphics = shown })
  Assert.isTrue(#drawsOf(shown, "arrow") > 0, "the command root shows the arrow")
  rig.screen:input({ { type = "confirm" } })
  rig.pump(1)
  Assert.equal(rig.screen:status().mode, "moves", "Fight opens move selection")
  rig.screen:input({ { type = "confirm" } })
  rig.pump(1)
  Assert.equal(rig.screen:status().mode, "awaiting_resolution", "confirming the known slot submits")
  local settled = FakeGraphics.new({})
  rig.screen:draw({ graphics = settled })
  Assert.equal(#drawsOf(settled, "arrow"), 0, "the submitted decision hides the arrow")
  Assert.isTrue(#drawsOf(settled, "hud:player") > 0, "the submitted decision keeps its composite")
  rig.screen:dispose()
  rig.battle:dispose()
end

-- A rejecting cue sink fails the screen with context instead of escaping
-- as a host error: the send-out cry never reaches an interactive
-- decision, the failure names the launch and the cue role, nothing
-- commits, and later ticks replay nothing.
function T.rejecting_cue_sink_fails_the_screen_with_context()
  local rig = openRig({ launchId = "launch-cue-failure" })
  local dispatches = 0
  rig.audio.play = function(_)
    dispatches = dispatches + 1
    error("injected cue fault", 0)
  end
  local failed = nil
  for _ = 1, 600 do
    local settled, settleErr = pcall(function()
      rig.pump(1)
    end)
    Assert.isTrue(settled, "cue audio never escapes as a host error: " .. tostring(settleErr))
    local status = rig.screen:status()
    if status.mode == "failed" then
      failed = status
      break
    end
  end
  Assert.notNil(failed, "the rejecting sink fails the screen")
  local context = tostring(failed.error)
  Assert.isTrue(context:find("launch-cue-failure", 1, true) ~= nil, "the failure names its launch: " .. context)
  Assert.isTrue(context:find("cry:EEVEE", 1, true) ~= nil, "the failure names its cue role: " .. context)
  Assert.isTrue(dispatches >= 1, "the faulty cue was dispatched before failing")
  Assert.equal(#rig.submits, 0, "no decision commits behind a failed cue")
  for _ = 1, 30 do
    local settled, settleErr = pcall(function()
      rig.pump(1)
    end)
    Assert.isTrue(settled, "later ticks stay controlled: " .. tostring(settleErr))
  end
  Assert.equal(dispatches, 1, "a failed screen replays no cue")
  Assert.isTrue(rig.screen:status().mode ~= "command", "the faulty cue never reaches an interactive decision")
  rig.screen:dispose()
  rig.battle:dispose()
end

-- Terminal narration holds for an explicit acknowledgment: hundreds of
-- ticks without input keep the readable outcome and refuse leave and
-- readiness, while one real confirm after the reveal releases exactly
-- once through the normal return.
---@param launchId string owning launch identity under test driving
---@return table live rig with a weak foe for a quick terminal route
local function openWeakTerminalRig(launchId)
  local BattleRuntime = require(RUNTIME_MODULE)
  local BattleScreenState = require(STATE_MODULE)
  local Model = require(MODEL_MODULE)
  local holder = {}
  local rig = { submits = {}, measurement = dualMeasurement(), text = recordingText() }
  rig.windows = { calls = {} }
  function rig.windows.drawWindow(box, frameKey, background)
    rig.windows.calls[#rig.windows.calls + 1] = { box = box, frame = frameKey, background = background }
  end
  rig.audio = { plays = {} }
  function rig.audio.play(name)
    rig.audio.plays[#rig.audio.plays + 1] = name
    return true
  end
  rig.assets = { hold = {}, images = {}, prepared = {}, released = {} }
  function rig.assets.prepare(demand)
    rig.assets.prepared[#rig.assets.prepared + 1] = demand
    return true
  end
  function rig.assets.drawable(key)
    if rig.assets.images[key] == nil then
      rig.assets.images[key] = { handle = key }
    end
    return rig.assets.images[key]
  end
  function rig.assets.release(key)
    rig.assets.released[key] = (rig.assets.released[key] or 0) + 1
  end
  local party = makeParty(
    { species = "EEVEE", level = 20, seed = 0x33333333 },
    { species = "EEVEE", level = 5, seed = 0x44444444, ability = "RUN_AWAY" }
  )
  local bag = HgssBagService.new({ catalog = ItemFixture.makeCatalog() })
  local launch = {
    id = launchId,
    kind = "wild",
    payload = { attemptId = launchId .. "-attempt", species = "EEVEE", form = 0, level = 4, personality = 1, ability = "RUN_AWAY" },
  }
  local ScenarioFactory = require(SCENARIO_FACTORY_MODULE)
  local scenario = ScenarioFactory.fromEncounter(
    { attemptId = launchId .. "-attempt", mon = foeRecord("EEVEE", 4, 0x5EED0002) },
    { party = party, bag = bag, player = { trainerId = 99, trainerName = "MINT", language = "french" } }
  )
  local screen = BattleScreenState.new({
    launchId = launchId,
    manifest = { schema = "test", version = { id = "t", language = "english" }, verified = false, scenes = { { key = "general/plain/day" } } },
    model = Model,
    submit = function(reply)
      rig.submits[#rig.submits + 1] = reply
      return holder.battle:submit(reply)
    end,
    measureDisplay = function()
      return rig.measurement
    end,
    assets = rig.assets,
    text = rig.text,
    windows = rig.windows,
    audio = rig.audio,
  })
  rig.screen = screen
  rig.port = screen:presentationPort()
  holder.battle = BattleRuntime.new({
    request = launch,
    scenario = scenario,
    party = party,
    bag = bag,
    presentation = rig.port,
    seed = 0x12345678,
  })
  rig.battle = holder.battle
  rig.party = party
  function rig.pump(ticks, dt)
    for _ = 1, ticks or 1 do
      rig.battle:update()
      rig.screen:updateFixed(dt or TICK)
    end
  end
  return rig
end

function T.terminal_narration_holds_until_an_explicit_acknowledgment()
  local rig = openWeakTerminalRig("launch-terminal-hold-local")
  local reached = false
  for _ = 1, 40 do
    for _ = 1, 600 do
      rig.pump(1)
      local status = rig.screen:status()
      if status.mode == "failed" then
        error("the terminal route failed: " .. tostring(status.error), 0)
      end
      if status.mode == "outcome" then
        reached = true
        break
      end
      if status.mode == "command" and status.request ~= nil then
        break
      end
      if rig.battle:status().phase == "complete" or rig.battle:status().phase == "failed" then
        break
      end
    end
    if rig.screen:status().mode == "outcome" then
      reached = true
      break
    end
    if rig.battle:status().phase == "complete" or rig.battle:status().phase == "failed" then
      break
    end
    if rig.screen:status().mode == "command" then
      rig.screen:input({ { type = "confirm" } })
      rig.pump(1)
      if rig.screen:status().mode == "moves" then
        rig.screen:input({ { type = "confirm" } })
        rig.pump(1)
      end
    elseif rig.screen:status().mode == "child" then
      error("the weak-foe terminal route never opens a child", 0)
    end
  end
  Assert.isTrue(reached, "the winning route presents its terminal narration")
  local shown = assert(rig.screen:view().message, "the terminal page stays readable")
  Assert.isTrue(shown ~= "", "the terminal page stays readable without input")
  for _ = 1, 600 do
    rig.pump(1)
  end
  Assert.equal(rig.screen:status().mode, "outcome", "hundreds of ticks without input keep the outcome")
  local held = assert(rig.screen:view().message, "the held outcome stays readable")
  Assert.isTrue(held ~= "", "the held outcome stays readable without input")
  Assert.isFalse(rig.port.leave({ kind = "wild" }), "leave refuses before the final acknowledgment")
  Assert.isFalse(rig.port.ready(), "readiness waits for the final acknowledgment")
  Assert.isTrue(rig.battle:status().phase ~= "complete", "the runtime does not return before acknowledgment")
  rig.screen:input({ { type = "confirm" } })
  rig.pump(1)
  for _ = 1, 120 do
    rig.pump(1)
  end
  Assert.isTrue(rig.port.leave({ kind = "wild" }), "one explicit acknowledgment releases the terminal page")
  Assert.isTrue(rig.port.ready(), "the acknowledged outcome settles")
  for _ = 1, 120 do
    rig.pump(1)
  end
  Assert.equal(rig.battle:status().phase, "complete", "the acknowledged battle returns through its normal phase")
  local sealed = #rig.submits
  rig.screen:input({ { type = "confirm" } })
  rig.pump(1)
  Assert.equal(#rig.submits, sealed, "a repeated edge after the terminal ack seals nothing more")
  rig.screen:dispose()
  rig.battle:dispose()
end

---@param launchId string owning launch identity under test driving
---@return table live screen-only rig holding a two-page terminal narration
local function openLongOutcomeRig(launchId)
  local BattleScreenState = require(STATE_MODULE)
  local Model = require(MODEL_MODULE)
  local rig = { submits = {}, measurement = dualMeasurement(), text = recordingText() }
  rig.windows = { calls = {} }
  function rig.windows.drawWindow(box, frameKey, background)
    rig.windows.calls[#rig.windows.calls + 1] = { box = box, frame = frameKey, background = background }
  end
  rig.audio = { plays = {} }
  function rig.audio.play(name)
    rig.audio.plays[#rig.audio.plays + 1] = name
    return true
  end
  rig.assets = { hold = {}, images = {}, prepared = {}, released = {} }
  function rig.assets.prepare(demand)
    rig.assets.prepared[#rig.assets.prepared + 1] = demand
    return true
  end
  function rig.assets.drawable(key)
    if rig.assets.images[key] == nil then
      rig.assets.images[key] = { handle = key }
    end
    return rig.assets.images[key]
  end
  function rig.assets.release(key)
    rig.assets.released[key] = (rig.assets.released[key] or 0) + 1
  end
  local screen = BattleScreenState.new({
    launchId = launchId,
    manifest = { schema = "test", version = { id = "t", language = "english" }, verified = false, scenes = { { key = "general/plain/day" } } },
    model = Model,
    submit = function(reply)
      rig.submits[#rig.submits + 1] = reply
      return true
    end,
    measureDisplay = function()
      return rig.measurement
    end,
    assets = rig.assets,
    text = rig.text,
    windows = rig.windows,
    audio = rig.audio,
  })
  rig.screen = screen
  rig.port = screen:presentationPort()
  function rig.pump(ticks, dt)
    for _ = 1, ticks or 1 do
      rig.screen:updateFixed(dt or TICK)
    end
  end
  local foeName = string.rep("FOE ", 20)
  local function ownRecord()
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
      name = "LEAD",
      level = 20,
      selector = "back",
      moves = { { move = "TACKLE", name = "Tackle", pp = 35, maxPp = 35 } },
    }
  end
  local function foeEntry()
    return {
      combatant = 3,
      participant = 3,
      side = 2,
      controller = "wild",
      active = true,
      hp = 57,
      maxHp = 57,
      species = "EEVEE",
      form = 0,
      name = foeName,
      level = 20,
      selector = "front",
    }
  end
  rig.port.present({
    launchId = launchId,
    packetId = 1,
    events = {},
    before = { own = { ownRecord() }, foes = { foeEntry() } },
    after = { own = { ownRecord() }, foes = { foeEntry() } },
    request = nil,
    result = { word = "win" },
  })
  return rig
end

-- A two-page terminal narration consumes one edge per stage: an early
-- edge only finishes the running reveal, the next edge turns the page,
-- and only the final revealed page acknowledges without spilling into
-- another decision.
function T.multipage_terminal_acknowledgment_consumes_each_edge_once()
  local rig = openLongOutcomeRig("launch-outcome-pages-local")
  local reached = false
  for _ = 1, 1200 do
    rig.pump(1)
    local status = rig.screen:status()
    if status.mode == "failed" then
      error("the paged outcome failed: " .. tostring(status.error), 0)
    end
    if status.mode == "outcome" then
      reached = true
      break
    end
  end
  Assert.isTrue(reached, "the long terminal narration reaches its outcome")
  rig.screen:input({ { type = "confirm" } })
  rig.pump(1)
  Assert.equal(rig.screen:status().mode, "outcome", "an early edge keeps the outcome")
  Assert.isFalse(rig.port.leave({ kind = "wild" }), "an early accelerate never releases")
  Assert.isFalse(rig.port.ready(), "an early accelerate never settles")
  Assert.equal(#rig.submits, 0, "an early accelerate seals nothing")
  rig.screen:input({ { type = "confirm" } })
  rig.pump(1)
  Assert.equal(rig.screen:status().mode, "outcome", "a page turn keeps the outcome")
  Assert.isFalse(rig.port.leave({ kind = "wild" }), "a page turn never releases")
  Assert.isFalse(rig.port.ready(), "a page turn never settles")
  Assert.equal(#rig.submits, 0, "a page turn seals nothing")
  for _ = 1, 300 do
    rig.pump(1)
  end
  Assert.equal(rig.screen:status().mode, "outcome", "the final page holds before its acknowledgment")
  Assert.isFalse(rig.port.leave({ kind = "wild" }), "the final page holds before its acknowledgment")
  Assert.isFalse(rig.port.ready(), "the final page stays unsettled before its acknowledgment")
  rig.screen:input({ { type = "confirm" } })
  rig.pump(1)
  for _ = 1, 120 do
    rig.pump(1)
  end
  Assert.isTrue(rig.port.leave({ kind = "wild" }), "the final acknowledgment releases the outcome")
  Assert.isTrue(rig.port.ready(), "the final acknowledgment settles")
  local sealed = #rig.submits
  rig.screen:input({ { type = "confirm" } })
  rig.pump(1)
  Assert.equal(#rig.submits, sealed, "a repeated edge after the final ack seals nothing more")
  Assert.equal(rig.screen:status().mode, "outcome", "a repeated edge never leaves the outcome")
  rig.screen:dispose()
end

-- A matched dialogue tap acknowledges exactly like a key edge: a
-- release with no press and a press whose release leaves the pane
-- never touch the page, while one matched tap per reveal stage
-- accelerates, turns, then finally acknowledges without sealing.
function T.matched_dialogue_taps_acknowledge_the_terminal_page()
  local rig = openLongOutcomeRig("launch-outcome-tap-local")
  local reached = false
  for _ = 1, 1200 do
    rig.pump(1)
    local status = rig.screen:status()
    if status.mode == "failed" then
      error("the tapped outcome failed: " .. tostring(status.error), 0)
    end
    if status.mode == "outcome" then
      reached = true
      break
    end
  end
  Assert.isTrue(reached, "the long terminal narration reaches its outcome")
  local function tap(id, downX, downY, upX, upY)
    rig.screen:input({ { type = "pointer_down", pointerId = id, x = downX, y = downY } })
    rig.screen:input({ { type = "pointer_up", pointerId = id, x = upX, y = upY } })
    rig.pump(1)
  end
  rig.screen:input({ { type = "pointer_up", pointerId = "touch:tap-orphan", x = 128, y = 288 } })
  rig.pump(1)
  Assert.isFalse(rig.port.leave({ kind = "wild" }), "a release with no press never releases")
  Assert.isFalse(rig.port.ready(), "a release with no press never settles")
  tap("touch:tap-early", 128, 288, 128, 288)
  Assert.equal(rig.screen:status().mode, "outcome", "an early tap keeps the outcome")
  Assert.isFalse(rig.port.leave({ kind = "wild" }), "an early tap only accelerates")
  Assert.isFalse(rig.port.ready(), "an early tap never settles")
  tap("touch:tap-turn", 128, 288, 128, 288)
  Assert.equal(rig.screen:status().mode, "outcome", "a page-turn tap keeps the outcome")
  Assert.isFalse(rig.port.leave({ kind = "wild" }), "a page-turn tap never releases")
  for _ = 1, 300 do
    rig.pump(1)
  end
  Assert.equal(rig.screen:status().mode, "outcome", "the final page holds before its tap")
  Assert.isFalse(rig.port.leave({ kind = "wild" }), "the final page holds before its tap")
  rig.screen:input({ { type = "pointer_down", pointerId = "touch:tap-drag", x = 128, y = 288 } })
  rig.screen:input({ { type = "pointer_up", pointerId = "touch:tap-drag", x = 300, y = 300 } })
  rig.pump(1)
  Assert.isFalse(rig.port.leave({ kind = "wild" }), "a release dragged off the pane never acknowledges")
  tap("touch:tap-final", 128, 288, 128, 288)
  for _ = 1, 120 do
    rig.pump(1)
  end
  Assert.isTrue(rig.port.leave({ kind = "wild" }), "the final matched tap acknowledges the outcome")
  Assert.isTrue(rig.port.ready(), "the tapped acknowledgment settles")
  Assert.equal(#rig.submits, 0, "dialogue taps seal no decision")
  rig.screen:dispose()
end

---@param launchId string owning launch identity under test driving
---@param speed string? launch narration pace under test driving, nil for the established default
---@return table screen-only rig paced by its launch option
local function openPacedScreen(launchId, speed)
  local BattleScreenState = require(STATE_MODULE)
  local Model = require(MODEL_MODULE)
  local rig = { submits = {}, measurement = dualMeasurement(), text = recordingText() }
  rig.windows = { calls = {} }
  function rig.windows.drawWindow(box, frameKey, background)
    rig.windows.calls[#rig.windows.calls + 1] = { box = box, frame = frameKey, background = background }
  end
  rig.audio = { plays = {} }
  function rig.audio.play(name)
    rig.audio.plays[#rig.audio.plays + 1] = name
    return true
  end
  rig.assets = { hold = {}, images = {}, prepared = {}, released = {} }
  function rig.assets.prepare(demand)
    rig.assets.prepared[#rig.assets.prepared + 1] = demand
    return true
  end
  function rig.assets.drawable(key)
    if rig.assets.images[key] == nil then
      rig.assets.images[key] = { handle = key }
    end
    return rig.assets.images[key]
  end
  function rig.assets.release(key)
    rig.assets.released[key] = (rig.assets.released[key] or 0) + 1
  end
  local options = {
    launchId = launchId,
    manifest = {
      schema = "test",
      version = { id = "t", language = "english" },
      verified = false,
      scenes = { { key = "general/plain/day" } },
    },
    model = Model,
    submit = function(reply)
      rig.submits[#rig.submits + 1] = reply
      return true
    end,
    measureDisplay = function()
      return rig.measurement
    end,
    assets = rig.assets,
    text = rig.text,
    windows = rig.windows,
    audio = rig.audio,
  }
  if speed ~= nil then
    options.textSpeed = speed
  end
  local screen = BattleScreenState.new(options)
  rig.screen = screen
  rig.port = screen:presentationPort()
  function rig.pump(ticks, dt)
    for _ = 1, ticks or 1 do
      rig.screen:updateFixed(dt or TICK)
    end
  end
  local function ownRecord()
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
      name = "LEAD",
      level = 20,
      selector = "back",
      moves = { { move = "TACKLE", name = "Tackle", pp = 35, maxPp = 35 } },
    }
  end
  local function foeRecordEntry()
    return {
      combatant = 3,
      participant = 3,
      side = 2,
      controller = "wild",
      active = true,
      hp = 57,
      maxHp = 57,
      species = "EEVEE",
      form = 0,
      name = "FOE",
      level = 20,
      selector = "front",
    }
  end
  rig.port.present({
    launchId = launchId,
    packetId = 4242,
    events = {},
    before = { own = { ownRecord() }, foes = { foeRecordEntry() } },
    after = { own = { ownRecord() }, foes = { foeRecordEntry() } },
    request = nil,
    result = nil,
  })
  return rig
end

-- Each launch keeps its own narration pace: an unhurried and a hurried
-- screen reveal different prefixes after the same ticks, acceleration
-- still takes two deliberate edges, batched ticks match single ticks,
-- an unknown pace fails, and omitting the pace keeps the middle
-- cadence.
function T.launches_keep_their_own_narration_pace_and_edges()
  local Utf8Glyphs = require("libs.assets.src.Utf8Glyphs")
  local BattleTimeline = require("game.hgss.src.battle.BattleTimeline")
  local function glyphCount(shown)
    local total = 0
    for _ in Utf8Glyphs.iter(shown) do
      total = total + 1
    end
    return total
  end
  local slow = openPacedScreen("launch-paced-slow-local", "slow")
  local quickest = openPacedScreen("launch-paced-quickest-local", "fastest")
  slow.pump(2)
  quickest.pump(2)
  Assert.equal(
    glyphCount(slow.screen:view().message),
    1,
    "the unhurried launch shows one glyph after two ticks"
  )
  Assert.equal(
    glyphCount(quickest.screen:view().message),
    4,
    "the hurried launch shows four glyphs after two ticks"
  )
  local badOk, _ = pcall(openPacedScreen, "launch-paced-bad-local", "warp")
  Assert.isFalse(badOk, "an unknown launch pace fails instead of guessing")
  local plain = openPacedScreen("launch-paced-plain-local", nil)
  plain.pump(5)
  Assert.equal(
    glyphCount(plain.screen:view().message),
    2,
    "omitting the launch pace keeps the middle cadence"
  )
  local narration = BattleTimeline.new({ sound = function(_) end, textSpeed = "slow" })
  narration:announce("ABCDEFGHIJKLMNOPQRST", true)
  narration:update(TICK, function(_)
    return true
  end)
  local consumed, finished = narration:ack()
  Assert.isTrue(consumed, "an edge during the reveal is consumed by the page")
  Assert.isFalse(finished, "finishing the reveal never acknowledges the final page on the same edge")
  Assert.equal(glyphCount(narration:message()), 20, "the edge completes the running page")
  narration:update(TICK, function(_)
    return true
  end)
  Assert.equal(glyphCount(narration:message()), 20, "later ticks never collapse an accelerated page")
  local consumedAgain, finishedFinally = narration:ack()
  Assert.isTrue(consumedAgain, "the final page consumes its own edge")
  Assert.isTrue(finishedFinally, "a second deliberate edge acknowledges the revealed final page")
  local single = BattleTimeline.new({ sound = function(_) end, textSpeed = "slow" })
  single:announce("ABCDEFGHIJKLMNOPQRST", false)
  single:update(4 / 60, function(_)
    return true
  end)
  local batched = BattleTimeline.new({ sound = function(_) end, textSpeed = "slow" })
  batched:announce("ABCDEFGHIJKLMNOPQRST", false)
  for _ = 1, 4 do
    batched:update(TICK, function(_)
      return true
    end)
  end
  Assert.equal(single:message(), batched:message(), "batched ticks reveal the same glyphs as single ticks")
  slow.screen:dispose()
  quickest.screen:dispose()
  plain.screen:dispose()
end

return { tests = T }
