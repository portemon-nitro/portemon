-- Plan-level coverage for the paired battle interface: native pane
-- sizes across display classes, stable input identity, source-region hit
-- mapping with gap/outside refusal and no outside dismissal, the
-- explicit too-small report, the noninteractive pending adapter, and a
-- draw-state restoring render smoke through the recording boundary.

local Assert = require("tests.support.Assert")
local ApplicationPresentation = require("libs.ui.src.ApplicationPresentation")
local BattleScreenInterface = require("game.hgss.src.battle.BattleScreenInterface")
local FakeGraphics = require("tests.support.FakeGraphics")
local ScreenTopology = require("libs.ui.src.ScreenTopology")

local T = {}
local TICK = 1 / 60

local STATE_MODULE = "game.hgss.src.battle.BattleScreenState"
local MODEL_MODULE = "game.hgss.src.battle.BattlePresentationModel"

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

return { tests = T }
