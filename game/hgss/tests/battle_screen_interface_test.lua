-- Plan-level coverage for the paired battle interface: native pane
-- sizes across display classes, stable input identity, source-region hit
-- mapping with gap/outside refusal and no outside dismissal, the
-- explicit too-small report, the noninteractive pending adapter, and a
-- draw-state restoring render smoke through the recording boundary.

local Assert = require("tests.support.Assert")
local ApplicationPresentation = require("libs.ui.src.ApplicationPresentation")
local BattleMenuPresenter = require("game.hgss.src.battle.BattleMenuPresenter")
local BattleRenderer = require("game.hgss.src.battle.BattleRenderer")
local BattleScreenInterface = require("game.hgss.src.battle.BattleScreenInterface")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local FakeGraphics = require("tests.support.FakeGraphics")
local LogicalSurface = require("libs.ui.src.LogicalSurface")
local HgssBagService = require("libs.hgss.src.items.HgssBagService")
local ItemFixture = require("libs.items.tests.item_fixture")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")
local ScreenTopology = require("libs.ui.src.ScreenTopology")
local BattlePresentationManifestFixture = require("tests.support.BattlePresentationManifestFixture")
local BagPresentationFixture = require("tests.support.BagPresentationFixture")

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
  local manifest = BattlePresentationManifestFixture.manifest()
  return {
    mode = mode,
    battleKind = "wild",
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
    commands = {
      { id = "fight", enabled = true, label = "FIGHT" },
      { id = "bag", enabled = true, label = "BAG" },
      { id = "pokemon", enabled = true, label = "POKEMON" },
      { id = "run", enabled = true, label = "RUN" },
    },
    slotGeometry = manifest.battlefield.slots,
    hudSections = { player = manifest.hud.player, enemy = manifest.hud.enemy },
    gaugeFamilies = { player = manifest.hud.partyGauges[2], enemy = manifest.hud.partyGauges[1] },
    menuLayers = {
      command = manifest.menus.command.screens,
      moves = manifest.menus.moves.screens,
      target = manifest.menus.target.screens,
      twoOption = manifest.menus.twoOption.screens,
    },
    hudPatchSpans = manifest.hud.patchSpans,
    textPalettes = {
      narration = manifest.messages.roles.narration.palette,
      hud = manifest.messages.roles.hud.palette,
      menu = manifest.messages.roles.menu.palette,
    },
    menuText = { pp = "PP", cancel = "CANCEL" },
    effectInstances = {},
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

function T.learn_confirmation_uses_the_native_two_option_scope_and_hit_regions()
  local session = ApplicationPresentation.new(BattleScreenInterface.defaults(), nil)
  local childView = view("child")
  childView.childView = {
    kind = "learn",
    interactive = true,
    confirmation = { kind = "replace", slot = 0 },
    rows = { { id = "learn:0", label = "TACKLE" } },
  }
  local plan = session:resolve(dualMeasurement(), childView)
  Assert.equal(plan.content.layout, "two-option", "a staged learning confirmation selects its source menu")
  local top = plan.mapInput({ type = "pointer_down", pointerId = "learn-confirm", x = 8, y = 40 }, childView, plan)
  Assert.equal(top.type, "child_press", "the top source option retains child activation semantics")
  Assert.equal(top.control.id, "confirm", "the top Forget/Yes option confirms the staged learning action")
  local bottom = plan.mapInput({ type = "pointer_down", pointerId = "learn-back", x = 8, y = 112 }, childView, plan)
  Assert.equal(bottom.type, "child_press", "the bottom source option retains child activation semantics")
  Assert.equal(bottom.control.id, "back", "the bottom Keep/No option returns to the learning list")
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
  local aimed =
    targets.mapInput({ type = "pointer_down", pointerId = "touch:0", x = 60, y = 116 }, view("target"), targets)
  Assert.notNil(aimed, "the admitted target anchor activates")
  Assert.equal(aimed.control.scope, "target", "target anchors carry the target scope")
end

-- Native target hitboxes are independent of the icon centers. Their
-- source inclusive edges become half-open rectangles, leaving the center
-- gutter and the edges between upper/lower slots unclaimed.
function T.target_hitboxes_follow_the_native_source_bounds()
  local session = ApplicationPresentation.new(BattleScreenInterface.defaults(), nil)
  local plan = resolve(session, dualMeasurement(), "target")
  local snapshot = view("target")
  local function targetAt(x, y)
    local mapped = plan.mapInput({ type = "pointer_down", pointerId = "target-bounds", x = x, y = y }, snapshot, plan)
    return mapped ~= nil and mapped.control.id or nil
  end

  for _, sample in ipairs({
    { x = 0, y = 88, target = "target:0" },
    { x = 120, y = 100, target = "target:0" },
    { x = 120, y = 144, target = "target:0" },
    { x = 136, y = 8, target = "target:1" },
    { x = 255, y = 8, target = "target:1" },
    { x = 136, y = 80, target = "target:1" },
    { x = 255, y = 80, target = "target:1" },
    { x = 136, y = 88, target = "target:2" },
    { x = 255, y = 88, target = "target:2" },
    { x = 136, y = 144, target = "target:2" },
    { x = 255, y = 144, target = "target:2" },
    { x = 0, y = 8, target = "target:3" },
    { x = 120, y = 8, target = "target:3" },
    { x = 0, y = 80, target = "target:3" },
    { x = 120, y = 80, target = "target:3" },
  }) do
    Assert.equal(targetAt(sample.x, sample.y), sample.target, "the source target rectangle includes its edge")
  end

  for _, point in ipairs({
    { x = 121, y = 100 },
    { x = 135, y = 100 },
    { x = 100, y = 7 },
    { x = 100, y = 81 },
    { x = 100, y = 87 },
    { x = 100, y = 145 },
    { x = 136, y = 81 },
    { x = 255, y = 81 },
  }) do
    Assert.isNil(targetAt(point.x, point.y), "gaps between source target regions claim no adjacent slot")
  end
  Assert.isNil(targetAt(0, 87), "the upper edge before a target row is excluded")
  Assert.isNil(targetAt(121, 100), "the first pixel after a target row is excluded")
end

-- The source touch table uses adjacent command and move ranges and four
-- independently admitted target ranges. Each sampled point resolves to
-- at most one semantic control, including the pixels shared by boundaries.
function T.source_hit_ranges_have_single_control_ownership()
  local session = ApplicationPresentation.new(BattleScreenInterface.defaults(), nil)
  local function assertRange(mode, candidates, samples)
    local plan = resolve(session, dualMeasurement(), mode)
    local snapshot = view(mode)
    snapshot.targetCandidates = candidates
    for _, sample in ipairs(samples) do
      local mapped =
        plan.mapInput({ type = "pointer_down", pointerId = "source-range", x = sample.x, y = sample.y }, snapshot, plan)
      if sample.control == nil then
        Assert.isNil(mapped, mode .. " leaves source gutter/outside pixels unclaimed")
      else
        Assert.notNil(mapped, mode .. " admits its source range")
        Assert.equal(mapped.control.id, sample.control, mode .. " maps one source pixel to one control")
        Assert.equal(mapped.type, "battle_press", mode .. " produces one press edge")
      end
    end
  end

  assertRange("command", nil, {
    { x = 0, y = 24, control = "fight" },
    { x = 255, y = 143, control = "fight" },
    { x = 0, y = 144, control = "bag" },
    { x = 79, y = 191, control = "bag" },
    { x = 176, y = 144, control = "pokemon" },
    { x = 255, y = 191, control = "pokemon" },
    { x = 88, y = 152, control = "run" },
    { x = 167, y = 191, control = "run" },
    { x = 80, y = 160 },
    { x = 168, y = 160 },
    { x = 0, y = 23 },
  })

  assertRange("moves", nil, {
    { x = 0, y = 24, control = "move:0" },
    { x = 127, y = 79, control = "move:0" },
    { x = 128, y = 24, control = "move:1" },
    { x = 255, y = 79, control = "move:1" },
    { x = 0, y = 88, control = "move:2" },
    { x = 127, y = 143, control = "move:2" },
    { x = 128, y = 88, control = "move:3" },
    { x = 255, y = 143, control = "move:3" },
    { x = 8, y = 152, control = "cancel" },
    { x = 247, y = 191, control = "cancel" },
    { x = 128, y = 80 },
    { x = 0, y = 144 },
  })

  local candidates = {}
  for index = 0, 3 do
    candidates[#candidates + 1] = {
      id = "target:" .. index,
      position = index + 1,
      combatant = index + 1,
      enabled = true,
      name = "FOE " .. index,
      level = 20,
    }
  end
  assertRange("target", candidates, {
    { x = 0, y = 88, control = "target:0" },
    { x = 120, y = 144, control = "target:0" },
    { x = 136, y = 8, control = "target:1" },
    { x = 255, y = 80, control = "target:1" },
    { x = 136, y = 88, control = "target:2" },
    { x = 255, y = 144, control = "target:2" },
    { x = 0, y = 8, control = "target:3" },
    { x = 120, y = 80, control = "target:3" },
    { x = 121, y = 100 },
    { x = 135, y = 100 },
    { x = 100, y = 87 },
    { x = 0, y = 87 },
  })
end

-- A pair without room takes the compact pane instead of a squeezed
-- battle: the full command composition stays reachable and
-- pointer-operable on the tiny host.
function T.pair_without_room_takes_the_compact_pane()
  local session = ApplicationPresentation.new(BattleScreenInterface.defaults(), nil)
  local small = resolve(session, tinyMeasurement(), "command")
  Assert.isTrue(small.content.compact == true, "the fallback plan is the compact composition")
  Assert.isNil(small.content.tooSmall, "the fallback fits its one pane, it is not too small")
  local pressed =
    small.mapInput({ type = "pointer_down", pointerId = "touch:0", x = 152, y = 154 }, view("command"), small)
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
  local pressed =
    single.mapInput({ type = "pointer_down", pointerId = "touch:0", x = 152, y = 154 }, view("command"), single)
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
  local function image(key)
    if images[key] == nil then
      images[key] = {
        handle = key,
        getDimensions = function()
          return 80, 80
        end,
        getWidth = function()
          return 80
        end,
        getHeight = function()
          return 80
        end,
        setFilter = function() end,
      }
    end
    return images[key]
  end
  local resources = {
    graphics = graphics,
    text = {
      measure = function(content)
        return { width = 8 * #tostring(content), height = 16 }
      end,
      drawText = function(_, _, _) end,
    },
    windows = {
      background = { 0.2, 0.3, 0.1, 1 },
      drawWindow = function(_, _, _) end,
    },
    assets = {
      drawable = function(_, key)
        return image(key)
      end,
      menuBlendTargets = function(self, blendGraphics)
        if self.menuBlend == nil then
          self.menuBlend = BattleMenuPresenter.newBlendTargets(blendGraphics)
        end
        return self.menuBlend
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
  rig.windows = { calls = {}, background = { 0.2, 0.3, 0.1, 1 } }
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
      rig.assets.images[key] = {
        handle = key,
        getDimensions = function()
          return 80, 80
        end,
        getWidth = function()
          return 80
        end,
        getHeight = function()
          return 80
        end,
        setFilter = function() end,
      }
    end
    local stored = rig.assets.images[key]
    if key:sub(1, 4) == "mon:" then
      return { lease = stored, quad = { handle = "quad:" .. key } }
    end
    return stored
  end
  function rig.assets.release(key)
    rig.assets.released[key] = (rig.assets.released[key] or 0) + 1
  end
  local launchId = opts.launchId or "launch-pointer-cancel"
  local screen = BattleScreenState.new({
    launchId = launchId,
    manifest = BattlePresentationManifestFixture.manifest(),
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
  for _ = 1, 20 do
    if rig.screen:view().menuInputEnabled then
      break
    end
    rig.pump(1)
  end
  rig.screen:input({ { type = "confirm" } })
  for _ = 1, 20 do
    rig.pump(1)
    if rig.screen:status().mode == "moves" and rig.screen:view().menuInputEnabled then
      break
    end
  end
  Assert.equal(
    rig.screen:status().mode,
    "moves",
    "Fight opens move selection (got "
      .. rig.screen:status().mode
      .. ", gate "
      .. tostring(rig.screen:view().menuInputEnabled)
      .. ")"
  )
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
  local foreignSounds = #rig.audio.plays
  rig.screen:input({ { type = "pointer_down", pointerId = "touch:A", x = 64, y = 237 } })
  rig.screen:input({ { type = "pointer_up", pointerId = "touch:B", x = 64, y = 237 } })
  rig.pump(1)
  Assert.equal(#rig.submits, 0, "a different pointer cannot release the armed move")
  Assert.equal(rig.screen:status().mode, "moves", "a foreign release leaves move selection open")
  Assert.equal(rig.screen:view().selection, "move:0", "a foreign release does not move focus")
  Assert.equal(#rig.audio.plays, foreignSounds, "a foreign release plays no activation sound")
  rig.screen:input({ { type = "pointer_up", pointerId = "touch:A", x = 64, y = 237 } })
  rig.pump(1)
  Assert.equal(#rig.submits, 1, "the original pointer completes its still-armed tap once")
  Assert.equal(rig.screen:status().mode, "awaiting_resolution", "the original pointer's move waits for resolution")
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
    windows = { calls = {}, background = { 0.2, 0.3, 0.1, 1 } },
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
      rig.assets.images[key] = {
        handle = key,
        getDimensions = function()
          return 80, 80
        end,
        getWidth = function()
          return 80
        end,
        getHeight = function()
          return 80
        end,
        setFilter = function() end,
      }
    end
    local stored = rig.assets.images[key]
    if key:sub(1, 4) == "mon:" then
      return { lease = stored, quad = { handle = "quad:" .. key } }
    end
    return stored
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
  rig.bagManifest = BagPresentationFixture.manifest()
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
  local battleBagRenderer = {}
  battleBagRenderer.owner = battleBagRenderer
  function battleBagRenderer:prepare(_)
    return true
  end
  function battleBagRenderer:draw(_, plan, _)
    rig.bagPlacement = plan.panes[1].placement
    return true
  end
  local screen = BattleScreenState.new({
    launchId = launchId,
    manifest = BattlePresentationManifestFixture.manifest(),
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
    battleMenus = {
      bag = {
        manifest = rig.bagManifest,
        renderer = battleBagRenderer,
        icons = {},
      },
    },
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
    if status.mode == mode and (mode ~= "command" and mode ~= "moves" or rig.screen:view().menuInputEnabled) then
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
  driveToMode(rig, "command")
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

-- Taps the focused native Bag cell, then the generated Use button.
---@param rig table live screen rig under test driving
---@return boolean sealed true once the native selection sealed a reply
local function tapSealsBagReply(rig)
  local function tap(rect)
    local x = rect.x + rect.width / 2
    local y = rect.y + rect.height / 2 + (rig.layout == "paired" and 192 or 0)
    local pointerId = "touch:native-bag"
    rig.screen:input({ { type = "pointer_down", pointerId = pointerId, x = x, y = y } })
    rig.screen:input({ { type = "pointer_up", pointerId = pointerId, x = x, y = y } })
    rig.pump(1)
  end
  local interactive = rig.bagManifest.interactive
  tap(interactive.itemSlots.slots[1].rect)
  rig.pump(2)
  tap(interactive.overlays.actionMenu.slots[1].hitRect)
  rig.pump(8)
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
    openBagFromCommand(rig)
    rig.screen:draw({ graphics = FakeGraphics.new({}) })
    Assert.equal(rig.screen:status().mode, "child", "drawing the borrowed native renderer keeps the Bag open" .. tag)
    local paneFrame = assert(rig.bagPlacement, "the open Bag draws through the borrowed renderer" .. tag).frame
    Assert.deepEqual(
      { paneFrame.x, paneFrame.y, paneFrame.width, paneFrame.height },
      layout == "compact" and { 0, 0, 256, 192 } or { 0, 192, 256, 192 },
      "the Bag draws inside the battle interaction pane" .. tag
    )
    walkToMedicineFirstCell(rig)
    press(rig, { type = "cancel" })
    press(rig, { type = "cancel" })
    Assert.equal(rig.screen:status().mode, "command", "leaving the medicine pocket returns to command" .. tag)
    openBagFromCommand(rig)
    walkToBallsFirstCell(rig)
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
    rig.pump(1)
    press(rig, { type = "confirm" })
    rig.pump(8)
    Assert.equal(#rig.submits, 0, "using the serving opens its target picker without sealing" .. tag)
    press(rig, { type = "cancel" })
    Assert.equal(rig.screen:status().mode, "child", "target cancel returns to the retained bag" .. tag)
    press(rig, { type = "cancel" })
    Assert.equal(rig.screen:status().mode, "command", "bag cancel returns to command" .. tag)
    Assert.equal(rig.bag:revision(), revision, "bag browsing moves no stock" .. tag)
    Assert.equal(rig.bag:quantity("POTION"), 5, "staging a serving takes no stock" .. tag)
    openBagFromCommand(rig)
    walkToMedicineFirstCell(rig)
    press(rig, { type = "confirm" })
    rig.pump(1)
    press(rig, { type = "confirm" })
    rig.pump(8)
    if #rig.submits == 0 and rig.screen:status().mode == "child" then
      press(rig, { type = "confirm" })
    end
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
    Assert.isTrue(tapSealsBagReply(capture), "a tap on the visible ball throws it" .. tag)
    Assert.equal(#capture.submits, 1, "the throw seals exactly one reply" .. tag)
    Assert.deepEqual(capture.submits[1].choices[1], ballFragment, "the throw matches its native fragment" .. tag)
    capture.screen:dispose()
    capture.battle:dispose()
  end
end

function T.native_battle_bag_draws_under_the_battle_pane_placement()
  local graphics = FakeGraphics.new()
  local received
  local bagRenderer = {
    draw = function(_, _, plan)
      received = plan.panes[1].placement
      LogicalSurface.draw(graphics, received, function() end)
    end,
  }
  local placement = {
    frame = { x = 0, y = 192, width = 256, height = 192 },
    origin = { x = 0, y = 192 },
    scale = 1,
    logicalWidth = 256,
    logicalHeight = 192,
    clipRect = { x = 0, y = 192, width = 256, height = 192 },
  }
  local handled = BattleRenderer.drawNativeChild({
    battleMenus = { bag = { renderer = bagRenderer, icons = {} } },
  }, {
    kind = "bag",
    native = { open = true, layout = {} },
  }, placement)

  Assert.isTrue(handled, "the native bag child is rendered")
  Assert.isTrue(received == placement, "the bag draws under the battle pane placement")
  Assert.equal(graphics:pushDepth(), 0, "the native placement completes its logical drawing scope")
end

function T.native_battle_party_waits_for_its_icon_pages()
  local draws = 0
  local partyRenderer = {
    draw = function()
      draws = draws + 1
    end,
  }
  local state = "pending"
  local resources = {
    assets = {
      state = function()
        return state
      end,
    },
    battleMenus = { party = { renderer = partyRenderer, icons = {} } },
  }
  local placement = {
    frame = { x = 0, y = 192, width = 256, height = 192 },
    origin = { x = 0, y = 192 },
    scale = 1,
    logicalWidth = 256,
    logicalHeight = 192,
    clipRect = { x = 0, y = 192, width = 256, height = 192 },
  }
  for _, kind in ipairs({ "party", "target" }) do
    state = "pending"
    local child = { kind = kind, native = { open = true, layout = {} } }
    Assert.isTrue(BattleRenderer.drawNativeChild(resources, child, placement), "the pending " .. kind .. " stays native")
    Assert.equal(draws, 0, "the " .. kind .. " picker draws no icon before its page is prepared")
    state = "ready"
    Assert.isTrue(BattleRenderer.drawNativeChild(resources, child, placement), "the ready " .. kind .. " is rendered")
    Assert.equal(draws, 1, "the " .. kind .. " picker draws once its icon pages are prepared")
    draws = 0
  end
end

return { tests = T }
