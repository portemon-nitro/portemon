-- The move reminder's pointer input: the source's own touch targets on the
-- bottom screen (four list rows, the TEACH and RETURN buttons, and the yes/no
-- prompt's two answer boxes) reached through the presented plan. A host tap is
-- inverted into the interactive screen's logical coordinates and answered by
-- the application state exactly like the pad edges; a tap outside every source
-- rectangle resolves no target, so a stray press never teaches or cancels.

local Assert = require("tests.support.Assert")
local MoveRelearnerRenderer = require("libs.hgss.src.ui.MoveRelearnerRenderer")
local MoveRelearnerState = require("game.hgss.src.field.MoveRelearnerState")
local ScreenTopology = require("libs.ui.src.ScreenTopology")

local T = {
  metadata = {
    tags = { "field", "mons", "input" },
  },
  tests = {},
}

local MANIFEST = {
  main = { image = "main", width = 256, height = 256 },
  sub = { image = "sub", width = 256, height = 256 },
  buttons = { image = "buttons", width = 512, height = 256 },
  messages = {},
  windows = {
    categoryLabel = { x = 136, y = 32, width = 48, height = 16 },
    powerLabel = { x = 136, y = 48, width = 48, height = 16 },
    accuracyLabel = { x = 136, y = 64, width = 64, height = 16 },
    power = { x = 224, y = 48, width = 24, height = 16 },
    accuracy = { x = 224, y = 64, width = 24, height = 16 },
    description = { x = 136, y = 80, width = 120, height = 80 },
    list = { x = 40, y = 32, width = 80, height = 128 },
    title = { x = 8, y = 0, width = 240, height = 24 },
    teach = { x = 120, y = 168, width = 64, height = 24 },
    returnButton = { x = 192, y = 168, width = 64, height = 24 },
    knownTitle = { x = 184, y = 104, width = 56, height = 32 },
    monName = { x = 152, y = 40, width = 80, height = 128 },
    message = { x = 16, y = 152, width = 216, height = 32, framed = true },
    promptYes = { x = 208, y = 80, width = 48, height = 32, framed = true },
    promptNo = { x = 208, y = 112, width = 48, height = 32, framed = true },
  },
}

-- One 256x192 touch surface at 1x: a host point is already a logical point, so
-- the test names the source rectangles directly.
local function singleDisplay()
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
    signature = "move-relearner-pointer",
  }
end

---@return table graphics double the renderer draws through (nothing is asserted here)
local function graphicsDouble()
  local noop = function() end
  return {
    push = noop,
    pop = noop,
    origin = noop,
    translate = noop,
    scale = noop,
    intersectScissor = noop,
    setColor = noop,
    draw = noop,
  }
end

---@return table<string, unknown> renderer over the compiled geometry
local function renderer()
  local text = {
    windowBackgroundColor = function()
      return { 0, 0, 0 }
    end,
    drawTextWithPalette = function() end,
    drawFocusIndicator = function() end,
  }
  return MoveRelearnerRenderer.new({
    graphics = graphicsDouble(),
    manifest = MANIFEST,
    images = { main = {}, sub = {}, buttons = {}, portrait = {} },
    picture = { page = "portrait", frame = { x = 0, y = 0, width = 64, height = 64 } },
    measureDisplay = singleDisplay,
    text = text,
    window = nil,
    fontDef = {},
    frameIndex = 0,
  })
end

local CATALOG = {
  PIDGEY = { nativeId = 16, growthCurve = "medium_fast", name = "PIDGEY", genderRatio = 127 },
  TACKLE = { name = "Tackle", basePp = 35, moveType = "normal", category = "physical", power = 35, accuracy = 95, description = "A physical attack." },
  GUST = { name = "Gust", basePp = 35, moveType = "flying", category = "special", power = 40, accuracy = 100, description = "A gust of wind." },
  SAND_ATTACK = { name = "Sand-Attack", basePp = 15, moveType = "ground", category = "status", power = 0, accuracy = 100, description = "Lowers accuracy." },
}

local function catalog()
  local curve = {}
  for level = 1, 100 do
    curve[level] = level * level * level
  end
  return {
    species = function(_, key)
      return assert(CATALOG[key], "the fixture carries " .. tostring(key))
    end,
    form = function()
      return { levelUpMoves = {} }
    end,
    growthCurve = function()
      return curve
    end,
    move = function(_, key)
      return assert(CATALOG[key], "the fixture carries " .. tostring(key))
    end,
  }
end

---@param taught table[] recording list of the published lessons
---@return table state the application under test
local function state(taught)
  return MoveRelearnerState.new({
    request = {
      kind = "move_relearner",
      mode = "relearn",
      slot = 0,
      revision = 1,
      nickname = "PIDGEY",
      moves = { "TACKLE", "GUST" },
      known = { "SAND_ATTACK" },
      subject = { speciesKey = "PIDGEY", form = 0, gender = "male", shiny = false },
    },
    catalog = catalog(),
    audio = {
      play = function() end,
    },
    teach = function(move, target)
      taught[#taught + 1] = { move = move, target = target }
      return { kind = "changed" }
    end,
    openSummary = function()
      error("the pointer cases never open the replacement Summary", 0)
    end,
  })
end

---@return table[] no input edges for one tick
local function idle()
  return { pressedAction = false, pressedCancel = false }
end

---@param app table state
---@param ticks integer
local function advance(app, ticks)
  for _ = 1, ticks do
    app:updateFixed(idle())
  end
end

---@param app table state
---@param predicate fun(snapshot: table<string, unknown>): boolean
---@param label string
---@return table<string, unknown> the matching snapshot
local function advanceUntil(app, predicate, label)
  for _ = 1, 200 do
    local snapshot = app:snapshot()
    if predicate(snapshot) then
      return snapshot
    end
    app:updateFixed(idle())
  end
  error("the reminder never reached " .. label, 0)
end

---@param target table<string, unknown>? resolved source target
---@return boolean
local function isRow(target, index)
  return target ~= nil and target.kind == "row" and target.index == index
end

function T.tests.a_pointer_tap_focuses_the_source_list_row()
  local taught = {}
  local app = state(taught)
  local view = renderer()
  advance(app, 10)
  Assert.equal(app:snapshot().phase, "input", "the reminder accepts input after its entry fade")
  local target = view:mapPointer(
    { { type = "pointer_down", pointerId = "mouse:1", x = 72, y = 72 } },
    app:snapshot()
  )
  Assert.isTrue(isRow(target, 1), "the tap resolves the second source list row")
  app:handlePointer(target --[[@as table<string, unknown>]])
  Assert.equal(app:snapshot().cursor, 1, "the tapped row becomes the focused row")
  Assert.equal(app:snapshot().phase, "input", "a row tap never starts the lesson")
  Assert.equal(#taught, 0, "a row tap teaches nothing")
end

function T.tests.the_teach_button_asks_the_source_question()
  local taught = {}
  local app = state(taught)
  local view = renderer()
  advance(app, 10)
  local target = view:mapPointer(
    { { type = "pointer_down", pointerId = "mouse:1", x = 140, y = 175 } },
    app:snapshot()
  )
  Assert.equal(assert(target).kind, "teach", "the tap resolves the source teach button")
  app:handlePointer(target --[[@as table<string, unknown>]])
  Assert.equal(app:snapshot().phase, "button_flash", "the pressed button flashes first")
  local asked = advanceUntil(app, function(snapshot)
    return snapshot.question ~= nil
  end, "the teach question")
  Assert.equal(asked.question.kind, "teach", "the source asks its own teach question")
  Assert.equal(asked.message, 1, "the question prints the source's teach line")
end

function T.tests.a_prompt_answer_publishes_the_lesson_once()
  local taught = {}
  local app = state(taught)
  local view = renderer()
  advance(app, 10)
  app:handlePointer({ kind = "teach" })
  advanceUntil(app, function(snapshot)
    return snapshot.question ~= nil
  end, "the teach question")
  local target = view:mapPointer(
    { { type = "pointer_down", pointerId = "touch:1", x = 220, y = 90 } },
    app:snapshot()
  )
  Assert.equal(assert(target).kind, "answer", "the tap resolves the prompt's yes box")
  Assert.equal(assert(target).answer, "yes", "the first prompt box answers yes")
  app:handlePointer(target --[[@as table<string, unknown>]])
  advanceUntil(app, function(snapshot)
    return snapshot.done
  end, "the finished lesson")
  Assert.equal(#taught, 1, "the lesson publishes exactly one move")
  Assert.equal(taught[1].move, "TACKLE", "the focused move is the one taught")
  Assert.isTrue(app:result().learned, "the application reports the learned move")
end

function T.tests.a_prompt_no_answer_cancels_the_lesson()
  local taught = {}
  local app = state(taught)
  local view = renderer()
  advance(app, 10)
  app:handlePointer({ kind = "return" })
  advanceUntil(app, function(snapshot)
    return snapshot.question ~= nil
  end, "the give-up question")
  Assert.equal(app:snapshot().question.kind, "give_up", "the RETURN button asks the source give-up question")
  local target = view:mapPointer(
    { { type = "pointer_down", pointerId = "touch:1", x = 220, y = 120 } },
    app:snapshot()
  )
  Assert.equal(assert(target).answer, "no", "the second prompt box answers no")
  app:handlePointer(target --[[@as table<string, unknown>]])
  local resumed = advanceUntil(app, function(snapshot)
    return snapshot.phase == "input"
  end, "the resumed list")
  Assert.isNil(resumed.question, "declining the question closes it")
  Assert.equal(#taught, 0, "declining teaches nothing")
end

function T.tests.a_tap_outside_the_source_targets_resolves_nothing()
  local taught = {}
  local app = state(taught)
  local view = renderer()
  advance(app, 10)
  local target = view:mapPointer(
    { { type = "pointer_down", pointerId = "mouse:1", x = 8, y = 8 } },
    app:snapshot()
  )
  Assert.isNil(target, "a tap outside every source rectangle resolves no target")
  Assert.equal(app:snapshot().phase, "input", "the stray tap leaves the application untouched")
  Assert.equal(#taught, 0, "the stray tap teaches nothing")
end

return T
