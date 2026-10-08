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

-- A surface that cannot fit a paired pane at 1x reports too-small
-- instead of a squeezed battle, and claims no pointer.
function T.too_small_reports_instead_of_squeezing()
  local session = ApplicationPresentation.new(BattleScreenInterface.defaults(), nil)
  local small = resolve(session, tinyMeasurement(), "command")
  Assert.isTrue(small.content.tooSmall == true, "the too-small plan says so explicitly")
  Assert.isNil(
    small.mapInput({ type = "pointer_down", pointerId = "touch:0", x = 10, y = 10 }, view("command"), small),
    "the too-small plan claims no pointer"
  )
end

-- Near-square single surfaces stay noninteractive until the compact
-- adapter lands: a pending plan with no pointer claims.
function T.square_surfaces_stay_pending()
  local session = ApplicationPresentation.new(BattleScreenInterface.defaults(), nil)
  local pending = resolve(session, squareMeasurement(), "command")
  Assert.isTrue(pending.content.pendingAdapter == true, "the pending plan says so explicitly")
  Assert.isNil(
    pending.mapInput({ type = "pointer_down", pointerId = "touch:0", x = 128, y = 83 }, view("command"), pending),
    "the pending plan claims no pointer"
  )
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

return { tests = T }
