-- Plan-level coverage for the paired battle interface: native pane
-- sizes across display classes, stable input identity, source-region hit
-- mapping with gap/outside refusal and no outside dismissal, the
-- explicit too-small report, the noninteractive pending adapter, and a
-- draw-state restoring render smoke through the recording boundary.

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

---@return table caller-owned paired display facts with a 256x192 detail pane over a 256x192 interaction pane
local function dualMeasurement()
  return {
    width = 256,
    height = 384,
    topology = ScreenTopology.dualDisplay(
      { id = "main", rect = { x = 0, y = 0, width = 256, height = 192 }, touch = false, role = "world" },
      { id = "lower", rect = { x = 0, y = 192, width = 256, height = 192 }, touch = true, role = "auxiliary" },
      "battle-interface-test:dual"
    ),
    pixelRatio = 1,
    signature = "battle-interface-test:dual",
  }
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
    signature = "battle-interface-test:wide",
  }
end

---@return table caller-owned near-square single surface display facts
local function squareMeasurement()
  return {
    width = 256,
    height = 192,
    topology = ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = 256, height = 192 },
      touch = true,
      role = "world",
    }),
    pixelRatio = 1,
    signature = "battle-interface-test:square",
  }
end

---@return table caller-owned tiny surface display facts that cannot fit a paired pane at 1x
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
    signature = "battle-interface-test:tiny",
  }
end

---@param mode string controller mode under test driving
---@return table internal semantic snapshot for resolvers and renderers
local function view(mode)
  return {
    mode = mode,
    selection = "fight",
    armed = nil,
    requestId = 7,
    message = " onboarding",
    messageId = 1,
    battlers = {
      { combatant = 1, side = 1, hp = 52, maxHp = 52, visible = true, name = "LEAD", level = 20, shakeDx = 0 },
      { combatant = 3, side = 2, hp = 57, maxHp = 57, visible = true, name = "FOE", level = 20, shakeDx = 0 },
    },
    partyRoster = {
      { slot = 0, hp = 52, maxHp = 52 },
      { slot = 1, hp = 21, maxHp = 21 },
    },
    foeCount = 1,
    arrowFrame = 0,
    childIntent = nil,
  }
end

---@param session table presentation session under test driving
---@param measurement table display facts under test driving
---@param mode string controller mode under test driving
---@return table resolved complete plan
local function resolve(session, measurement, mode)
  return session:resolve(measurement, view(mode))
end

-- Paired composition resolves two native panes: detail above and
-- interaction below on dual displays, side by side on wide ones, with
-- one stable input identity across equivalent resolutions.
function T.paired_plans_use_native_panes_with_stable_identity()
  local session = ApplicationPresentation.new(BattleScreenInterface.defaults(), nil)
  local dual = resolve(session, dualMeasurement(), "command")
  Assert.equal(#dual.panes, 2, "the dual composition resolves exactly two panes")
  for _, pane in ipairs(dual.panes) do
    Assert.equal(pane.placement.logicalWidth, 256, "each logical pane spans the native width")
    Assert.equal(pane.placement.logicalHeight, 192, "each logical pane spans the native height")
  end
  local key = dual.inputKey
  resolve(session, dualMeasurement(), "command")
  Assert.equal(session:plan().inputKey, key, "equivalent re-resolution keeps its input identity")
  local wide = resolve(session, wideMeasurement(), "command")
  Assert.equal(#wide.panes, 2, "the wide composition resolves exactly two panes")
  for _, pane in ipairs(wide.panes) do
    Assert.equal(pane.placement.logicalWidth, 256, "each wide pane spans the native width")
    Assert.equal(pane.placement.logicalHeight, 192, "each wide pane spans the native height")
  end
end

-- Source command anchors each map to their own control while gaps, the
-- detail surface, and outside presses map to nothing and never dismiss.
function T.command_anchors_map_gaps_and_outside_do_not()
  local session = ApplicationPresentation.new(BattleScreenInterface.defaults(), nil)
  local plan = resolve(session, dualMeasurement(), "command")
  local snapshot = view("command")
  local function controlAt(x, y)
    local mapped = plan.mapInput({ type = "pointer_down", pointerId = "touch:0", x = x, y = y }, snapshot, plan)
    if mapped == nil then
      return nil
    end
    return mapped.control.id
  end
  Assert.equal(controlAt(128, 83), "fight", "the top anchor opens the command")
  Assert.equal(controlAt(40, 169), "bag", "the lower-left anchor opens the bag")
  Assert.equal(controlAt(216, 168), "pokemon", "the lower-right anchor opens the party")
  Assert.equal(controlAt(128, 176), "run", "the bottom anchor runs")
  Assert.isNil(controlAt(84, 170), "the gutter between the bottom controls claims nothing")
  Assert.isNil(controlAt(100, 148), "the strip above the bottom row claims nothing")
  Assert.isNil(controlAt(10, 10), "the upper corner claims no command")
  Assert.isNil(
    plan.mapInput({ type = "pointer_down", pointerId = "touch:0", outside = true }, snapshot, plan),
    "outside presses never dismiss a battle"
  )
end

-- Move anchors map per slot with their cancel region; target anchors map
-- per admitted target.
function T.move_and_target_anchors_map()
  local session = ApplicationPresentation.new(BattleScreenInterface.defaults(), nil)
  local moves = resolve(session, dualMeasurement(), "moves")
  local snapshot = view("moves")
  local function moveAt(x, y)
    local mapped = moves.mapInput({ type = "pointer_down", pointerId = "touch:0", x = x, y = y }, snapshot, moves)
    if mapped == nil then
      return nil
    end
    return mapped.control.id
  end
  Assert.equal(moveAt(64, 45), "move:0", "the upper-left move anchor selects the first slot")
  Assert.equal(moveAt(192, 44), "move:1", "the upper-right move anchor selects the second slot")
  Assert.equal(moveAt(64, 108), "move:2", "the lower-left move anchor selects the third slot")
  Assert.equal(moveAt(192, 107), "move:3", "the lower-right move anchor selects the fourth slot")
  Assert.equal(moveAt(128, 175), "cancel", "the bottom anchor cancels")
  local targets = resolve(session, dualMeasurement(), "target")
  local aimed = targets.mapInput(
    { type = "pointer_down", pointerId = "touch:0", x = 60, y = 116 },
    view("target"),
    targets
  )
  Assert.notNil(aimed, "the admitted target anchor activates")
  Assert.equal(aimed.control.scope, "target", "target anchors carry the target scope")
end

-- A pair without room takes the compact pane instead of a squeezed
-- battle: the full command composition stays reachable and
-- pointer-operable on the tiny host.
function T.pair_without_room_takes_the_compact_pane()
  local session = ApplicationPresentation.new(BattleScreenInterface.defaults(), nil)
  local small = resolve(session, tinyMeasurement(), "command")
  Assert.isTrue(small.content.compact == true, "the fallback plan is the compact composition")
  Assert.isNil(small.content.tooSmall, "the fallback fits its one pane, it is not too small")
  local pressed = small.mapInput(
    { type = "pointer_down", pointerId = "touch:0", x = 152, y = 154 },
    view("command"),
    small
  )
  Assert.notNil(pressed, "the fallback Fight cell claims its control")
  Assert.equal(pressed.control.id, "fight", "the fallback keeps the Fight identity")
end

-- Near-square single surfaces resolve the compact single pane with
-- the shared command controls.
function T.square_surfaces_resolve_the_compact_pane()
  local session = ApplicationPresentation.new(BattleScreenInterface.defaults(), nil)
  local single = resolve(session, squareMeasurement(), "command")
  Assert.isTrue(single.content.compact == true, "the single-surface plan is the compact composition")
  Assert.equal(#single.panes, 1, "the single-surface plan resolves one pane")
  local pressed = single.mapInput(
    { type = "pointer_down", pointerId = "touch:0", x = 152, y = 154 },
    view("command"),
    single
  )
  Assert.notNil(pressed, "the single-pane Fight cell claims its control")
  Assert.equal(pressed.control.id, "fight", "the single pane keeps the Fight identity")
end

-- Rendering restores borrowed graphics state exactly and draws both
-- panes through the recording boundary.
function T.render_restores_borrowed_state()
  local session = ApplicationPresentation.new(BattleScreenInterface.defaults(), nil)
  local plan = resolve(session, dualMeasurement(), "command")
  local graphics = FakeGraphics.new({})
  local images = {}
  local resources = {
    graphics = graphics,
    text = {
      measure = function(content)
        return { width = 8 * #tostring(content), height = 16 }
      end,
      drawText = function(_, _, _) end,
    },
    windows = {
      drawWindow = function(_, _, _) end,
    },
    assets = {
      drawable = function(_, key)
        if images[key] == nil then
          images[key] = { handle = key }
        end
        return images[key]
      end,
    },
    frameKey = "default",
    sceneImageKey = "scene:test",
  }
  local function state()
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
  local before = state()
  ApplicationPresentation.draw(graphics, resources, view("command"), plan)
  Assert.deepEqual(state(), before, "the paired draw restores borrowed graphics state exactly")
  Assert.isTrue(#graphics.draws > 0, "the composition draws through the recording boundary")
end

---@return table caller-owned paired display facts
local function interfaceDualMeasurement()
  return {
    width = 256,
    height = 384,
    topology = ScreenTopology.dualDisplay(
      { id = "main", rect = { x = 0, y = 0, width = 256, height = 192 }, touch = false, role = "world" },
      { id = "lower", rect = { x = 0, y = 192, width = 256, height = 192 }, touch = true, role = "auxiliary" },
      "battle-pointer-test:dual"
    ),
    pixelRatio = 1,
    signature = "battle-pointer-test:dual",
  }
end

---@param opts table? rig options: launchId
---@return table live screen-only rig with an accepting submit boundary
local function openInterfaceRig(opts)
  opts = opts or {}
  local BattleScreenState = require(STATE_MODULE)
  local Model = require(MODEL_MODULE)
  local rig = { submits = {}, measurement = interfaceDualMeasurement(), text = nil }
  rig.text = {
    draws = {},
    measure = function(content)
      return { width = 8 * #tostring(content), height = 16 }
    end,
    drawText = function(content, x, y)
      rig.text.draws[#rig.text.draws + 1] = { content = tostring(content), x = x, y = y }
    end,
  }
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
  local launchId = opts.launchId or "launch-pointer-cancel"
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
  local target = { kind = "position", position = 2 }
  local choice = {
    actor = { combatant = 1, activation = 1 },
    kind = "attack",
    payload = { moveSlot = 0, target = target },
  }
  local BattleProtocol = require("libs.battle.src.BattleProtocol")
  BattleProtocol.validateTarget(target)
  BattleProtocol.validateChoice(choice, "action")
  local decision = {
    requestId = 9101,
    epoch = 1,
    controller = "player",
    kind = "action",
    actors = {
      {
        combatant = 1,
        activation = 1,
        kind = "action",
        choices = {
          {
            id = "move:0",
            role = "move",
            display = { move = "TACKLE", name = "Tackle", pp = 35, maxPp = 35 },
            enabled = true,
            choice = choice,
          },
        },
      },
    },
  }
  decision.options = {
    requestId = 9101,
    epoch = 1,
    controller = "player",
    kind = "action",
    actors = decision.actors,
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
  local function foeRecord()
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
    before = { own = { ownRecord() }, foes = { foeRecord() } },
    after = { own = { ownRecord() }, foes = { foeRecord() } },
    request = decision,
    result = nil,
  })
  for _ = 1, 600 do
    rig.pump(1)
    local status = rig.screen:status()
    if status.mode == "failed" then
      error("the pointer screen failed while driving to command: " .. tostring(status.error), 0)
    end
    if status.mode == "command" and status.request ~= nil and status.request.requestId == 9101 then
      return rig
    end
  end
  error("the pointer screen never reached its command decision", 0)
  return rig
end

-- Cancelled and refused pointer edges spend nothing: a disabled slot
-- reports its reason and keeps focus, orphan and outside releases seal
-- nothing, a reflow between press and release cancels the hold, and a
-- later matched tap on the focused slot still seals exactly once.
function T.cancelled_and_refused_pointer_edges_spend_nothing()
  local rig = openInterfaceRig({ launchId = "launch-pointer-cancel-local" })
  Assert.equal(rig.screen:status().mode, "command", "the pointer decision opens")
  rig.screen:input({ { type = "confirm" } })
  rig.pump(1)
  Assert.equal(rig.screen:status().mode, "moves", "Fight opens move selection")
  Assert.equal(rig.screen:view().selection, "move:0", "move selection rests on the first slot")
  rig.screen:input({ { type = "pointer_down", pointerId = "touch:disabled", x = 192, y = 236 } })
  rig.screen:input({ { type = "pointer_up", pointerId = "touch:disabled", x = 192, y = 236 } })
  rig.pump(1)
  Assert.equal(#rig.submits, 0, "the disabled slot seals nothing")
  Assert.equal(rig.screen:view().selection, "move:0", "the refused slot keeps its focus")
  Assert.isTrue(rig.screen:view().message ~= "", "the refused slot reports its reason")
  rig.screen:input({ { type = "pointer_up", pointerId = "touch:orphan", x = 64, y = 237 } })
  rig.pump(1)
  Assert.equal(#rig.submits, 0, "a release with no press seals nothing")
  rig.screen:input({ { type = "pointer_down", pointerId = "touch:outside", x = 64, y = 237 } })
  rig.screen:input({ { type = "pointer_up", pointerId = "touch:outside", x = 10, y = 10 } })
  rig.pump(1)
  Assert.equal(#rig.submits, 0, "a release outside the pane seals nothing")
  Assert.equal(rig.screen:status().mode, "moves", "the outside release keeps the decision")
  rig.screen:input({ { type = "pointer_down", pointerId = "touch:reflow", x = 64, y = 237 } })
  rig.measurement.signature = "battle-pointer-test:reflowed"
  rig.pump(2)
  rig.screen:input({ { type = "pointer_up", pointerId = "touch:reflow", x = 64, y = 237 } })
  rig.pump(1)
  Assert.equal(#rig.submits, 0, "a reflowed hold seals nothing")
  Assert.equal(rig.screen:status().mode, "moves", "the cancelled hold keeps the decision")
  rig.screen:input({ { type = "pointer_down", pointerId = "touch:valid", x = 64, y = 237 } })
  rig.screen:input({ { type = "pointer_up", pointerId = "touch:valid", x = 64, y = 237 } })
  rig.pump(1)
  Assert.equal(#rig.submits, 1, "a matched tap on the focused slot seals once")
  Assert.equal(rig.screen:status().mode, "awaiting_resolution", "the sealed move waits for resolution")
  rig.screen:dispose()
end

---@param layout string "paired" or "compact" surface arrangement under test driving
---@return table caller-owned display facts for the layout
local function childMeasurement(layout)
  if layout == "compact" then
    return {
      width = 256,
      height = 192,
      topology = ScreenTopology.oneDisplay({
        id = "main",
        rect = { x = 0, y = 0, width = 256, height = 192 },
        touch = true,
        role = "world",
      }),
      pixelRatio = 1,
      signature = "battle-bag-test:compact",
    }
  end
  return {
    width = 256,
    height = 384,
    topology = ScreenTopology.dualDisplay(
      { id = "main", rect = { x = 0, y = 0, width = 256, height = 192 }, touch = false, role = "world" },
      { id = "lower", rect = { x = 0, y = 192, width = 256, height = 192 }, touch = true, role = "auxiliary" }
    ),
    pixelRatio = 1,
    signature = "battle-bag-test:paired",
  }
end

---@param specs table lead/reserve descriptions under test preparation
---@return table live party owner holding the described members in order
local function makePartyOwner(specs)
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
  for _, member in ipairs(specs) do
    local factory = CatalogFixture.makeFactory(member.seed, catalog)
    local record =
      factory:createNormal(CatalogFixture.normalRequest({ species = member.species, level = member.level }))
    if member.currentHp ~= nil then
      record.condition.currentHp = member.currentHp
    end
    Assert.isTrue(owner:addMon(record), "the bag path needs its live party member")
  end
  return owner
end

---@param spec table foe description under test preparation
---@return table full mon-domain record for the enemy side
local function makeFoe(spec)
  local catalog = CatalogFixture.makeCatalog()
  local factory = CatalogFixture.makeFactory(spec.seed, catalog)
  local record = factory:createNormal(CatalogFixture.normalRequest({ species = spec.species, level = spec.level }))
  record.moves = { { move = "TACKLE", pp = 35, ppUps = 0 } }
  return record
end

---@param opts table rig options under test preparation
---@return table live rig with the runtime, screen, stocked bag, and submit log
local function openChildRig(opts)
  local BattleRuntime = require(RUNTIME_MODULE)
  local BattleScreenState = require(STATE_MODULE)
  local Model = require(MODEL_MODULE)
  local ScenarioFactory = require(SCENARIO_FACTORY_MODULE)
  local holder = {}
  local layout = opts.layout or "paired"
  local rig = {
    submits = {},
    measurement = childMeasurement(layout),
    layout = layout,
    text = { draws = {} },
    windows = { calls = {} },
    audio = { plays = {} },
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
  function rig.audio.play(name)
    rig.audio.plays[#rig.audio.plays + 1] = name
    return true
  end
  rig.assets = { prepared = {}, released = {} }
  function rig.assets.prepare(demand)
    rig.assets.prepared[#rig.assets.prepared + 1] = demand
    return true
  end
  function rig.assets.drawable(key)
    if rig.assets.images == nil then
      rig.assets.images = {}
    end
    if rig.assets.images[key] == nil then
      rig.assets.images[key] = { handle = key }
    end
    return rig.assets.images[key]
  end
  function rig.assets.release(key)
    rig.assets.released[key] = (rig.assets.released[key] or 0) + 1
  end
  local party = makePartyOwner(opts.party)
  local bag = HgssBagService.new({ catalog = ItemFixture.makeCatalog() })
  for _, stocked in ipairs(opts.bag or {}) do
    Assert.isTrue(bag:add(stocked.key, stocked.qty), "the bag path stocks its " .. stocked.key)
  end
  rig.party = party
  rig.bag = bag
  local launchId = opts.launchId or "launch-battle-bag"
  local foeSpec = opts.foe or { species = "EEVEE", level = 4, seed = 0x5EED0002 }
  local foe = makeFoe(foeSpec)
  local scenario = ScenarioFactory.fromEncounter(
    { attemptId = launchId .. "-attempt", mon = foe },
    { party = party, bag = bag, player = { trainerId = 99, trainerName = "MINT", language = "french" } }
  )
  local launch = {
    id = launchId,
    kind = "wild",
    payload = {
      attemptId = launchId .. "-attempt",
      species = foeSpec.species,
      form = 0,
      level = foeSpec.level,
      personality = 1,
      ability = "RUN_AWAY",
    },
  }
  local screen = BattleScreenState.new({
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
      return holder.battle:submit(reply)
    end,
    measureDisplay = function()
      return rig.measurement
    end,
    itemCatalog = ItemFixture.makeCatalog(),
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
    seed = opts.seedNum or 0x12345678,
  })
  rig.battle = holder.battle
  function rig.pump(ticks)
    for _ = 1, ticks or 1 do
      rig.battle:update()
      rig.screen:updateFixed(TICK)
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
  error("the battle screen never reached " .. mode .. " (" .. rig.layout .. ")", 0)
end

---@param rig table live screen rig under test driving
---@param event table<string, unknown> semantic input batch under test driving
local function press(rig, event)
  rig.screen:input({ event })
  rig.pump(1)
end

-- Terminal leave carries an explicit final-page acknowledgment: while
-- narration plays, one genuine confirm through the real screen path
-- advances it exactly as a player would, so the battle can settle.
---@param rig table live screen rig under test driving
local function ackNarration(rig)
  local mode = rig.screen:status().mode
  if mode == "intro" or mode == "narration" or mode == "outcome" then
    rig.screen:input({ { type = "confirm" } })
  end
end

---@param rig table live screen rig under test driving, resting on its command prompt
local function openBagFromCommand(rig)
  press(rig, { type = "navigate", direction = "down" })
  press(rig, { type = "navigate", direction = "left" })
  press(rig, { type = "confirm" })
  Assert.equal(rig.screen:status().mode, "child", "the Bag command opens the bag child (" .. rig.layout .. ")")
end

---@param rig table live screen rig under test driving, resting on the open bag child
local function walkToMedicineFirstCell(rig)
  press(rig, { type = "navigate", direction = "up" })
  press(rig, { type = "navigate", direction = "right" })
  press(rig, { type = "navigate", direction = "down" })
end

---@param rig table live screen rig under test driving, resting on the open bag child
local function walkToBallsFirstCell(rig)
  press(rig, { type = "navigate", direction = "up" })
  press(rig, { type = "navigate", direction = "right" })
  press(rig, { type = "navigate", direction = "right" })
  press(rig, { type = "navigate", direction = "down" })
end

---@param rig table live screen rig under test driving
---@return table the mirrored open request under test driving
local function openScreenRequest(rig)
  local request = rig.screen:status().request
  Assert.notNil(request, "the prompt mirrors its request (" .. rig.layout .. ")")
  return request --[[@as table<string, unknown>]]
end

---@param rig table live screen rig under test driving
---@param request table open request under projection
---@return table detached native decision options for the open request
local function optionsFor(rig, request)
  local options, optionsErr = rig.battle:decisionOptions(request.requestId)
  Assert.notNil(options, "the runtime projects options for the open request: " .. tostring(optionsErr))
  return options --[[@as table<string, unknown>]]
end

---@param request table battle request under inspection
---@return string the decision kind carried by the request
local function requestKind(request)
  if type(request.kind) == "string" and request.kind ~= "action" then
    return request.kind --[[@as string]]
  end
  return "action"
end

---@param rig table live screen rig under test driving
---@param request table open action request under projection
---@return table the first enabled move fragment, still unsubmitted
local function firstEnabledMoveFragment(rig, request)
  local options = optionsFor(rig, request)
  for _, actor in ipairs(options.actors) do
    for _, choice in ipairs(actor.choices) do
      if choice.role == "move" and choice.enabled == true then
        return choice.choice
      end
    end
  end
  error("the action request carries an enabled move (" .. rig.layout .. ")", 0)
end

---@param rig table live screen rig under test driving
---@return table<string, integer> drawn text census keyed by content for one render
local function renderedContents(rig)
  rig.text.draws = {}
  rig.screen:draw({ graphics = FakeGraphics.new({}) })
  local census = {}
  for _, drawn in ipairs(rig.text.draws) do
    local content = tostring(drawn.content)
    census[content] = (census[content] or 0) + 1
  end
  return census
end

---@param census table<string, integer> rendered text census under inspection
---@return integer distinct drawn contents
local function censusSize(census)
  local total = 0
  for _, _ in pairs(census) do
    total = total + 1
  end
  return total
end

-- The open bag paints its own pocket rows instead of the command
-- fallback: strictly more text appears and a new entry names the
-- given item marker, matched without case.
---@param before table<string, integer> command text census under comparison
---@param after table<string, integer> bag text census under comparison
---@param marker string required new visible item marker under comparison
---@param what string bag description under comparison
local function assertPaintsBagRows(before, after, marker, what)
  Assert.isTrue(
    censusSize(after) >= censusSize(before) + 4,
    "the open " .. what .. " paints its own rows instead of the command fallback"
  )
  local seen = false
  for content, _ in pairs(after) do
    if before[content] == nil and tostring(content):lower():find(marker, 1, true) ~= nil then
      seen = true
    end
  end
  Assert.isTrue(seen, "the open " .. what .. " names its stocked entries (" .. marker .. ")")
end

-- Probes the open bag with matched press/release taps across the
-- interaction surface until one tap seals a reply. A tap that closes
-- the bag without sealing reopens it and walks back once, so a footer
-- cancel never ends the probe early. Two passes cover entries that
-- focus on the first tap and seal on the second.
---@param rig table live screen rig under test driving
---@param yLo integer first host row under probing
---@param yHi integer last host row under probing
---@param rewalk fun(rig: table) reopens the bag and walks back after a cancel tap
---@return boolean sealed true once a tap sealed exactly one reply
local function tapSealsBagReply(rig, yLo, yHi, rewalk)
  local taps = 0
  local cancelled = 0
  for pass = 1, 2 do
    local y = yLo
    while y <= yHi do
      local x = 8
      while x <= 248 do
        if rig.screen:status().mode ~= "child" then
          if #rig.submits > 0 then
            return true
          end
          if cancelled >= 1 then
            return false
          end
          cancelled = cancelled + 1
          rewalk(rig)
          if rig.screen:status().mode ~= "child" then
            return false
          end
        end
        taps = taps + 1
        local id = "touch:bag:" .. tostring(pass) .. ":" .. tostring(taps)
        rig.screen:input({ { type = "pointer_down", pointerId = id, x = x, y = y } })
        rig.screen:input({ { type = "pointer_up", pointerId = id, x = x, y = y } })
        rig.pump(1)
        if #rig.submits > 0 then
          return true
        end
        x = x + 16
      end
      y = y + 16
    end
  end
  return #rig.submits > 0
end

-- The stocked battle bag opens over the real item catalogs with its
-- medicine and ball pockets browsable on both display cases: pocket
-- tabs expose each stocked entry with its quantity, staging a serving
-- keeps the retained bag behind its target, every cancel path leaves
-- live stock untouched, and a tap on the visible ball throws exactly
-- the stocked native fragment.
function T.stocked_bag_lists_pockets_and_tap_throws_the_visible_ball()
  for _, layout in ipairs({ "paired", "compact" }) do
    local tag = " (" .. layout .. ")"
    local yLo, yHi = 8, 184
    if layout == "paired" then
      yLo, yHi = 200, 376
    end
    local rig = openChildRig({
      layout = layout,
      launchId = "launch-visible-bag-" .. layout,
      party = {
        { species = "EEVEE", level = 20, seed = 0x33333333, currentHp = 10 },
        { species = "EEVEE", level = 5, seed = 0x44444444, ability = "RUN_AWAY", currentHp = 10 },
      },
      bag = {
        { key = "POTION", qty = 5 },
        { key = "POKE_BALL", qty = 5 },
        { key = "SOOTHE_BELL", qty = 1 },
      },
    })
    driveToMode(rig, "command")
    local commandRequest = openScreenRequest(rig)
    local healOptions = optionsFor(rig, commandRequest)
    local enabledPotions = {}
    for _, actor in ipairs(healOptions.actors) do
      for _, choice in ipairs(actor.choices) do
        if type(choice.id) == "string" and choice.id:match("^item:POTION:") ~= nil then
          if choice.enabled == true then
            enabledPotions[#enabledPotions + 1] = choice.choice
          end
        end
      end
    end
    Assert.isTrue(#enabledPotions >= 1, "the stocked healing stays selectable" .. tag)
    local commandInk = renderedContents(rig)
    openBagFromCommand(rig)
    walkToMedicineFirstCell(rig)
    assertPaintsBagRows(commandInk, renderedContents(rig), "potion", "medicine pocket" .. tag)
    press(rig, { type = "cancel" })
    press(rig, { type = "cancel" })
    Assert.equal(rig.screen:status().mode, "command", "leaving the medicine pocket returns to command" .. tag)
    openBagFromCommand(rig)
    walkToBallsFirstCell(rig)
    assertPaintsBagRows(commandInk, renderedContents(rig), "ball", "balls pocket" .. tag)
    press(rig, { type = "cancel" })
    press(rig, { type = "cancel" })
    Assert.equal(rig.screen:status().mode, "command", "leaving the pockets returns to command" .. tag)
    Assert.equal(#rig.submits, 0, "browsing the pockets seals no reply" .. tag)
    local revision = rig.bag:revision()
    openBagFromCommand(rig)
    walkToMedicineFirstCell(rig)
    press(rig, { type = "confirm" })
    Assert.equal(#rig.submits, 0, "staging the serving seals no reply" .. tag)
    Assert.equal(rig.screen:status().mode, "child", "staging keeps the child open" .. tag)
    press(rig, { type = "cancel" })
    Assert.equal(rig.screen:status().mode, "child", "target cancel returns to the retained bag" .. tag)
    press(rig, { type = "cancel" })
    Assert.equal(rig.screen:status().mode, "command", "bag cancel returns to command" .. tag)
    Assert.equal(rig.bag:revision(), revision, "bag browsing moves no stock" .. tag)
    Assert.equal(rig.bag:quantity("POTION"), 5, "staging a serving takes no stock" .. tag)
    openBagFromCommand(rig)
    walkToMedicineFirstCell(rig)
    press(rig, { type = "confirm" })
    press(rig, { type = "confirm" })
    if #rig.submits == 0 and rig.screen:status().mode == "child" then
      press(rig, { type = "navigate", direction = "down" })
      press(rig, { type = "confirm" })
    end
    Assert.equal(#rig.submits, 1, "accepting the serving seals exactly one reply" .. tag)
    local sealed = rig.submits[1].choices[1]
    local matched = false
    for _, candidate in ipairs(enabledPotions) do
      local ok = pcall(Assert.deepEqual, sealed, candidate, "the serving matches its native fragment" .. tag)
      if ok then
        matched = true
      end
    end
    Assert.isTrue(matched, "the serving matches its native fragment" .. tag)
    Assert.equal(rig.bag:quantity("POTION"), 5, "native execution takes no field stock mid-battle" .. tag)
    for _ = 1, 60 do
      local current = rig.battle:status()
      if current.phase == "complete" or current.phase == "failed" then
        break
      end
      if current.request ~= nil and requestKind(current.request) == "action" then
        local fragment = firstEnabledMoveFragment(rig, current.request)
        local ok, submitErr = rig.battle:submit({
          requestId = current.request.requestId,
          epoch = current.request.epoch,
          controller = current.request.controller,
          choices = { fragment },
        })
        Assert.isTrue(ok, "the kernel accepts the projected move: " .. tostring(submitErr))
      end
      ackNarration(rig)
      rig.pump(20)
    end
    Assert.equal(rig.battle:status().phase, "complete", "the serving battle settles" .. tag)
    Assert.equal(rig.bag:quantity("POTION"), 4, "the accepted serving publishes exactly once" .. tag)
    rig.screen:dispose()
    rig.battle:dispose()

    local capture = openChildRig({
      layout = layout,
      launchId = "launch-visible-throw-" .. layout,
      party = {
        { species = "EEVEE", level = 20, seed = 0x33333333 },
        { species = "EEVEE", level = 5, seed = 0x44444444, ability = "RUN_AWAY" },
      },
      bag = {
        { key = "MASTER_BALL", qty = 1 },
        { key = "POTION", qty = 3 },
      },
    })
    driveToMode(capture, "command")
    local catchRequest = openScreenRequest(capture)
    local catchOptions = optionsFor(capture, catchRequest)
    local ballFragment = nil
    for _, actor in ipairs(catchOptions.actors) do
      for _, choice in ipairs(actor.choices) do
        if
          type(choice.choice) == "table"
          and type(choice.choice.payload) == "table"
          and choice.choice.payload.item == "MASTER_BALL"
        then
          if choice.enabled == true then
            ballFragment = choice.choice
          end
        end
      end
    end
    Assert.notNil(ballFragment, "the wild ball stays throwable" .. tag)
    openBagFromCommand(capture)
    walkToBallsFirstCell(capture)
    local function rewalk()
      openBagFromCommand(capture)
      walkToBallsFirstCell(capture)
    end
    Assert.isTrue(tapSealsBagReply(capture, yLo, yHi, rewalk), "a tap on the visible ball throws it" .. tag)
    Assert.equal(#capture.submits, 1, "the throw seals exactly one reply" .. tag)
    Assert.deepEqual(capture.submits[1].choices[1], ballFragment, "the throw matches its native fragment" .. tag)
    capture.screen:dispose()
    capture.battle:dispose()
  end
end

return { tests = T }
