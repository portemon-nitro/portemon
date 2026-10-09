-- Single-pane battle composition over the shared application frames: one
-- 256x192 logical surface carries the scene above a 56-pixel dock with the
-- framed question on the left and the framed two-by-two command grid on the
-- right, using the same semantic controls as the paired panes. Move, target
-- and narration states reuse the dock space with their own framed boxes, a
-- genuinely small host downfits the whole pane instead of clipping it, and a
-- layout change keeps the open decision while dropping stale pointer holds.
--
-- These scenarios resolve through the real application presentation session
-- and the real battle interface set with synthetic screen snapshots, plus
-- two full runtime pairings for decision parity. Fixtures are synthetic
-- only, so the run needs no dump capabilities. Each scenario first names
-- the missing single-pane behavior, so the run stays red until that
-- behavior lands.

local Assert = require("tests.support.Assert")
local ApplicationPresentation = require("libs.ui.src.ApplicationPresentation")
local BattleScreenInterface = require("game.hgss.src.battle.BattleScreenInterface")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local FakeGraphics = require("tests.support.FakeGraphics")
local FieldDialogueTheme = require("libs.hgss.src.ui.FieldDialogueTheme")
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

-- Fixed single-pane command geometry: scene above, prompt-left and
-- command-right dock below. All rect intervals are half-open.
local SCENE = { x = 0, y = 0, width = 256, height = 136 }
local PROMPT_OUTER = { x = 0, y = 136, width = 112, height = 56 }
local PROMPT_CONTENT = { x = 8, y = 144, width = 96, height = 40 }
local COMMAND_OUTER = { x = 112, y = 136, width = 144, height = 56 }
local COMMAND_CONTENT = { x = 120, y = 144, width = 128, height = 40 }
local COMMAND_CELLS = {
  { id = "fight", x = 120, y = 144, width = 64, height = 20 },
  { id = "bag", x = 184, y = 144, width = 64, height = 20 },
  { id = "pokemon", x = 120, y = 164, width = 64, height = 20 },
  { id = "run", x = 184, y = 164, width = 64, height = 20 },
}
local COMMAND_CURSORS = {
  { x = 120, y = 146 },
  { x = 184, y = 146 },
  { x = 120, y = 166 },
  { x = 184, y = 166 },
}
local PROMPT_ORIGIN = { x = 12, y = 146, maxWidth = 88 }

-- Fixed move-dock geometry: a taller 72-pixel dock with the slot grid on
-- the left and the type/PP panel plus Back on the right.
local MOVE_DOCK = { x = 0, y = 120, width = 256, height = 72 }
local MOVE_LEFT = { x = 8, y = 128, width = 176, height = 56 }
local MOVE_RIGHT = { x = 200, y = 128, width = 48, height = 56 }
local MOVE_BACK = { x = 200, y = 164, width = 48, height = 20 }
local MOVE_BACK_LABEL = { x = 204, y = 166 }

-- Fixed full-width target/narration boxes.
local TARGET_CONTENT = { x = 8, y = 128, width = 240, height = 56 }
local NARRATION_CONTENT = { x = 8, y = 144, width = 240, height = 40 }
local NARRATION_ORIGIN = { x = 12, y = 146, width = 232 }

-- Fixed compact battlefield anchors: complete enemy bounds at the top
-- left, complete player bounds against the right edge above the dock.
local HUD_ENEMY = { x = 4, y = 4 }
local HUD_PLAYER_RIGHT = 252
local HUD_PLAYER_BOTTOM = 132
local PLAYER_CENTER = { x = 60, y = 96 }
local ENEMY_CENTER = { x = 196, y = 44 }

---@param width integer host width under test driving
---@param height integer host height under test driving
---@param signature string stable measurement identity under test driving
---@return table caller-owned single-surface display facts
local function singleMeasurement(width, height, signature)
  return {
    width = width,
    height = height,
    topology = ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = width, height = height },
      touch = true,
      role = "world",
    }),
    pixelRatio = 1,
    signature = signature,
  }
end

---@return table caller-owned 256x192 single-surface display facts
local function compactMeasurement()
  return singleMeasurement(256, 192, "single-pane-test:compact")
end

---@return table caller-owned dual-surface display facts with a 256x192 detail pane over a 256x192 interaction pane
local function dualMeasurement()
  return {
    width = 256,
    height = 384,
    topology = ScreenTopology.dualDisplay(
      { id = "main", rect = { x = 0, y = 0, width = 256, height = 192 }, touch = false, role = "world" },
      { id = "lower", rect = { x = 0, y = 192, width = 256, height = 192 }, touch = true, role = "auxiliary" },
      "single-pane-test:dual"
    ),
    pixelRatio = 1,
    signature = "single-pane-test:dual",
  }
end

---@param mode string controller mode under test driving
---@param overrides table? snapshot fields replacing the command defaults
---@return table internal semantic snapshot for resolvers and renderers
local function snapshot(mode, overrides)
  local view = {
    mode = mode,
    selection = "fight",
    armed = nil,
    requestId = 7,
    message = "What will MINT do?",
    messageId = 1,
    battlers = {
      { combatant = 1, side = 1, hp = 52, maxHp = 52, visible = true, name = "LEAD", level = 20, shakeDx = 0 },
      { combatant = 3, side = 2, hp = 57, maxHp = 57, visible = true, name = "FOE", level = 20, shakeDx = 0 },
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
      { slot = 2, name = "TAIL WHIP", pp = 0, maxPp = 30, moveType = "NORMAL", enabled = false, reason = "no PP left" },
      { slot = 3, enabled = false, reason = "empty" },
    },
    partyRoster = {
      { slot = 0, hp = 52, maxHp = 52 },
      { slot = 1, hp = 21, maxHp = 21 },
    },
    foeCount = 1,
    arrowFrame = 0,
    childIntent = nil,
  }
  if mode == "moves" then
    view.selection = "move:0"
  elseif mode == "target" then
    view.selection = "target:0"
  end
  if overrides ~= nil then
    for key, value in pairs(overrides) do
      view[key] = value
    end
  end
  return view
end

---@param measurement table display facts under test driving
---@param view table internal semantic snapshot under test driving
---@return table resolved complete plan
---@return table presentation session carrying the plan
local function resolve(measurement, view)
  local session = ApplicationPresentation.new(BattleScreenInterface.defaults(), nil)
  return session:resolve(measurement, view), session
end

---@param plan table resolved complete plan under inspection
---@return table the single-pane geometry the plan publishes
local function singlePaneContent(plan)
  Assert.isNil(
    plan.content.pendingAdapter,
    "the single-surface battle needs its single-pane composition, not the pending adapter"
  )
  Assert.isNil(plan.content.tooSmall, "the single-surface battle fits its one pane, it is not too small")
  Assert.isTrue(plan.content.compact == true, "the single-surface plan says it is the compact composition")
  return plan.content
end

---@param actual table<string, unknown> resolved rect under comparison
---@param expected table<string, unknown> fixed compact rect under comparison
---@param what string rect role under comparison
local function assertRect(actual, expected, what)
  Assert.equal(actual.x, expected.x, what .. " keeps its left edge")
  Assert.equal(actual.y, expected.y, what .. " keeps its top edge")
  Assert.equal(actual.width, expected.width, what .. " keeps its width")
  Assert.equal(actual.height, expected.height, what .. " keeps its height")
end

---@param order table shared sequence log under recording
---@return table recording text boundary with a shared order log
local function recordingText(order)
  local text = { draws = {}, measures = 0 }
  function text.measure(content)
    text.measures = text.measures + 1
    return { width = 8 * #tostring(content), height = 16 }
  end
  function text.drawText(content, x, y)
    order[#order + 1] = "text"
    text.draws[#text.draws + 1] = { content = tostring(content), x = x, y = y, palette = nil }
  end
  function text.drawTextWithPalette(content, x, y, palette)
    order[#order + 1] = "text"
    text.draws[#text.draws + 1] = { content = tostring(content), x = x, y = y, palette = palette }
  end
  return text
end

---@param order table shared sequence log under recording
---@return table recording window boundary with a shared order log and a distinctive background
local function recordingWindows(order)
  local windows = { frames = {}, boxes = {}, background = { 0.2, 0.3, 0.1, 1 } }
  function windows.drawWindow(box, frameKey, background)
    windows.boxes[#windows.boxes + 1] = { box = box, frame = frameKey, background = background }
  end
  function windows.drawApplicationFrame(box, frameIndex)
    order[#order + 1] = "frame"
    windows.frames[#windows.frames + 1] =
      { box = { x = box.x, y = box.y, width = box.width, height = box.height }, index = frameIndex }
  end
  return windows
end

---@param plan table resolved complete plan under mapping
---@param view table internal semantic snapshot under mapping
---@param x number logical horizontal position under test driving
---@param y number logical vertical position under test driving
---@return table? semantic battle input, nil when the pane claims no control
local function mappedAt(plan, view, x, y)
  return plan.mapInput({ type = "pointer_down", pointerId = "touch:0", x = x, y = y }, view, plan)
end

---@param cell table<string, unknown> half-open hit cell under probing
---@return integer, integer the cell center
local function centerOf(cell)
  local box = cell --[[@as table<string, unknown>]]
  return box.x --[[@as number]] + math.floor(box.width --[[@as number]] / 2),
    box.y --[[@as number]] + math.floor(box.height --[[@as number]] / 2)
end

-- The command dock divides the lower 56 pixels into a 112-pixel prompt
-- panel and a 144-pixel command panel with the fixed shared-frame content
-- boxes derived from the real theme insets; the scene keeps the upper
-- 136 pixels and the whole composition stays one 256x192 pane.
function T.single_pane_command_dock_frames_prompt_and_options()
  local plan = resolve(compactMeasurement(), snapshot("command"))
  local content = singlePaneContent(plan)
  Assert.equal(#plan.panes, 1, "the single-pane composition resolves one pane, not two shrunken screens")
  local pane = assert(plan.panes[1], "the single pane resolves")
  Assert.equal(pane.placement.logicalWidth, 256, "the one pane spans the compact width")
  Assert.equal(pane.placement.logicalHeight, 192, "the one pane spans the compact height")
  assertRect(content.scene, SCENE, "the scene viewport")
  assertRect(content.dock, { x = 0, y = 136, width = 256, height = 56 }, "the ordinary dock")
  assertRect(content.prompt.outer, PROMPT_OUTER, "the prompt outer allocation")
  assertRect(content.prompt.content, PROMPT_CONTENT, "the prompt frame content")
  assertRect(content.commands.outer, COMMAND_OUTER, "the command outer allocation")
  assertRect(content.commands.content, COMMAND_CONTENT, "the command frame content")
  Assert.equal(
    content.prompt.outer.x + content.prompt.outer.width,
    content.commands.outer.x,
    "the two outer allocations abut with no layout gap"
  )
  local insets = FieldDialogueTheme.applicationFrameInsets()
  for _, named in ipairs({ { "prompt", content.prompt }, { "commands", content.commands } }) do
    local panel = named[2] --[[@as table<string, unknown>]]
    local outer = panel.outer --[[@as table<string, unknown>]]
    local box = panel.content --[[@as table<string, unknown>]]
    Assert.equal(
      box.x,
      outer.x --[[@as number]] + insets.left --[[@as number]],
      named[1] .. " content starts at the real horizontal inset"
    )
    Assert.equal(
      box.width,
      outer.width --[[@as number]] - insets.left --[[@as number]] - insets.right --[[@as number]],
      named[1] .. " content width removes both real horizontal insets"
    )
    -- The allocated dock leaves one background-colored logical pixel
    -- outside each exterior cap, so the vertical inset gains one pixel
    -- per side beyond the theme's exterior room.
    Assert.equal(
      box.y,
      outer.y --[[@as number]] + insets.top --[[@as number]] + 1,
      named[1] .. " content starts below the top cap strip"
    )
    Assert.equal(
      box.height,
      outer.height --[[@as number]] - insets.top --[[@as number]] - insets.bottom --[[@as number]] - 2,
      named[1] .. " content height removes both cap strips"
    )
    Assert.equal(box.width --[[@as number]] % 8, 0, named[1] .. " content width stays 8-pixel compatible")
    Assert.equal(box.height --[[@as number]] % 8, 0, named[1] .. " content height stays 8-pixel compatible")
    Assert.isTrue(box.height --[[@as number]] ~= 34, named[1] .. " never uses the invalid 34-pixel content box")
  end
  Assert.equal(content.promptOrigin.x, PROMPT_ORIGIN.x, "the prompt text keeps its left origin")
  Assert.equal(content.promptOrigin.y, PROMPT_ORIGIN.y, "the prompt text keeps its top origin")
  Assert.equal(#content.commands.cells, 4, "the command grid carries four hit cells")
  for index, cell in ipairs(content.commands.cells) do
    assertRect(
      cell --[[@as table<string, unknown>]],
      COMMAND_CELLS[index] --[[@as table<string, unknown>]],
      "command cell " .. tostring(index)
    )
  end
  for index, cursor in ipairs(content.commands.cursors) do
    local point = cursor --[[@as table<string, unknown>]]
    Assert.equal(point.x, COMMAND_CURSORS[index].x, "cursor " .. tostring(index) .. " keeps its column")
    Assert.equal(point.y, COMMAND_CURSORS[index].y, "cursor " .. tostring(index) .. " keeps its row")
    local cell = COMMAND_CELLS[index] --[[@as table<string, unknown>]]
    Assert.equal(point.x, cell.x, "the cursor hugs its own cell edge")
    Assert.equal(point.y, cell.y --[[@as number]] + 2, "the cursor sits two pixels inside its cell top")
  end
  Assert.equal(content.hud.enemy.x, HUD_ENEMY.x, "the enemy bounds keep their left anchor")
  Assert.equal(content.hud.enemy.y, HUD_ENEMY.y, "the enemy bounds keep their top anchor")
  Assert.equal(content.hud.player.rightEdge, HUD_PLAYER_RIGHT, "the player bounds keep their right edge")
  Assert.equal(content.hud.player.bottomEdge, HUD_PLAYER_BOTTOM, "the player bounds sit above the dock")
  local key = plan.inputKey
  local again = resolve(compactMeasurement(), snapshot("command"))
  Assert.equal(again.inputKey, key, "equivalent re-resolution keeps its input identity")
  local moved = resolve(compactMeasurement(), snapshot("command", { selection = "bag" }))
  Assert.isTrue(moved.inputKey ~= key, "a semantic selection change turns the input key")
end

-- Pointer cells follow the drawn two-by-two grid in row-major Fight, Bag,
-- Pokemon, Run order with half-open edges; the question area and the scene
-- claim no command, so there is no invisible full-screen Fight hotspot.
function T.command_pointer_cells_match_drawn_regions()
  local plan = resolve(compactMeasurement(), snapshot("command"))
  local content = singlePaneContent(plan)
  local view = snapshot("command")
  local order = {}
  for _, cell in ipairs(content.commands.cells) do
    local box = cell --[[@as table<string, unknown>]]
    local cx, cy = centerOf(box)
    local mapped = mappedAt(plan, view, cx, cy)
    Assert.notNil(mapped, "the cell center claims its control")
    Assert.equal(mapped.type, "battle_press", "cell presses arm through the shared press convention")
    Assert.equal(mapped.control.scope, "command", "command cells carry the command scope")
    order[#order + 1] = mapped.control.id
  end
  Assert.deepEqual(order, { "fight", "bag", "pokemon", "run" }, "the grid reads row-major Fight, Bag, Pokemon, Run")
  local first = content.commands.cells[1] --[[@as table<string, unknown>]]
  local edge =
    mappedAt(plan, view, first.x --[[@as number]] + first.width --[[@as number]], first.y --[[@as number]] + 2)
  Assert.notNil(edge, "the shared vertical edge still claims a control")
  Assert.equal(edge.control.id, "bag", "half-open intervals give the shared edge to the right cell")
  local firstRow = content.commands.cells[1] --[[@as table<string, unknown>]]
  local rowEdge =
    mappedAt(plan, view, firstRow.x --[[@as number]] + 2, firstRow.y --[[@as number]] + firstRow.height --[[@as number]])
  Assert.notNil(rowEdge, "the shared horizontal edge still claims a control")
  Assert.equal(rowEdge.control.id, "pokemon", "half-open intervals give the shared edge to the lower cell")
  Assert.isNil(mappedAt(plan, view, 12, 146), "the question origin claims no command")
  Assert.isNil(mappedAt(plan, view, 100, 170), "the question body claims no command")
  Assert.isNil(mappedAt(plan, view, 128, 60), "the scene claims no command")
  Assert.isNil(mappedAt(plan, view, 60, 140), "the strip above the dock claims no command")
  Assert.isNil(
    plan.mapInput({ type = "pointer_down", pointerId = "touch:0", outside = true }, view, plan),
    "outside presses never dismiss a battle"
  )
  local slide = plan.mapInput({ type = "pointer_move", pointerId = "touch:0", x = 152, y = 154 }, view, plan)
  Assert.notNil(slide, "hover tracks the focused cell")
  Assert.equal(slide.type, "battle_slide", "hover never seals, it only tracks")
  Assert.equal(slide.control.id, "fight", "hover tracks the first cell")
  local up = plan.mapInput({ type = "pointer_up", pointerId = "touch:0", x = 152, y = 154 }, view, plan)
  Assert.notNil(up, "release completes the shared press convention")
  Assert.equal(up.type, "battle_activate", "release completes the shared press convention")
  Assert.equal(up.control.id, "fight", "release on the pressed cell confirms it")
end

-- Dock drawing establishes the shared window background under both panels,
-- draws prompt and command text, then borders both content boxes with the
-- one selected frame; text stays clear of the cap-overlap rows and no dock
-- fill is black or a new hard-coded white. HUD name, level and health
-- wording draws through the same text boundary at the published HUD region
-- origins inside the scene viewport.
function T.dock_draws_background_text_before_shared_borders()
  local plan = resolve(compactMeasurement(), snapshot("command"))
  local content = singlePaneContent(plan)
  local graphics = FakeGraphics.new({})
  local order = {}
  local text = recordingText(order)
  local windows = recordingWindows(order)
  local resources = {
    graphics = graphics,
    text = text,
    windows = windows,
    assets = {
      drawable = function(_, key)
        return { handle = key }
      end,
    },
    frameKey = "single-pane-test-frame",
    sceneImageKey = "scene:test",
  }
  ApplicationPresentation.draw(graphics, resources, snapshot("command"), plan)
  Assert.equal(#windows.frames, 2, "both dock panels take a shared application border")
  assertRect(
    windows.frames[1].box,
    PROMPT_CONTENT,
    "the prompt border wraps the prompt content box, not its outer allocation"
  )
  assertRect(
    windows.frames[2].box,
    COMMAND_CONTENT,
    "the command border wraps the command content box, not its outer allocation"
  )
  Assert.equal(windows.frames[1].index, windows.frames[2].index, "both panels share the one selected frame")
  Assert.isTrue(#text.draws >= 5, "the prompt and the four command labels all draw")
  local firstFrame = nil
  for index, entry in ipairs(order) do
    if entry == "frame" then
      firstFrame = index
      break
    end
  end
  Assert.notNil(firstFrame, "the borders draw")
  local textsBefore = 0
  for index = 1, firstFrame --[[@as number]] - 1 do
    if order[index] == "text" then
      textsBefore = textsBefore + 1
    end
  end
  Assert.isTrue(textsBefore > 0, "text draws before the border draws, never underneath it")
  local promptBox = content.prompt.content --[[@as table<string, unknown>]]
  local commandBox = content.commands.content --[[@as table<string, unknown>]]
  local hud = content.hud --[[@as table<string, unknown>]]
  local scene = content.scene --[[@as table<string, unknown>]]
  -- HUD wording draws through the same text boundary at the published
  -- region origins, so the dock checks below scope to every other draw: a
  -- draw counts as HUD-scoped exactly when its wording and origin match a
  -- published non-empty HUD region.
  local expectedHud = {}
  for _, side in ipairs({ hud.enemy, hud.player }) do
    for _, region in ipairs(side.regions) do
      if type(region.text) == "string" and region.text ~= "" then
        expectedHud[#expectedHud + 1] = region
      end
    end
  end
  local function hudRegionOf(drawn)
    for _, region in ipairs(expectedHud) do
      if drawn.content == region.text and drawn.x == region.x and drawn.y == region.y then
        return region
      end
    end
    return nil
  end
  local dockDraws, hudDraws = {}, {}
  for _, drawn in ipairs(text.draws) do
    if hudRegionOf(drawn) ~= nil then
      hudDraws[#hudDraws + 1] = drawn
    else
      dockDraws[#dockDraws + 1] = drawn
    end
  end
  for _, drawn in ipairs(dockDraws) do
    local box = drawn.x < COMMAND_OUTER.x and promptBox or commandBox
    Assert.isTrue(
      drawn.y >= box.y --[[@as number]] + 2,
      "drawn text stays two pixels below the cap-overlap row: " .. drawn.content
    )
    Assert.isTrue(
      drawn.y + 16 <= box.y --[[@as number]] + box.height --[[@as number]] - 1,
      "drawn text stays above the bottom cap-overlap row: " .. drawn.content
    )
  end
  local labels = {}
  for _, drawn in ipairs(dockDraws) do
    if drawn.x >= COMMAND_OUTER.x then
      labels[#labels + 1] = drawn.x
    end
  end
  Assert.isTrue(#labels >= 4, "all four command labels draw inside the command panel")
  for _, x in ipairs(labels) do
    local onGrid = x == 128 or x == 192
    Assert.isTrue(onGrid, "command labels begin eight pixels right of their cursor column")
  end
  -- HUD-scoped bounds: every published wording draws exactly once at its
  -- own origin, inside its side bounds and the scene viewport at unit
  -- scale.
  Assert.equal(#hudDraws, #expectedHud, "every published HUD wording draws exactly once")
  for _, region in ipairs(expectedHud) do
    local found = 0
    for _, drawn in ipairs(hudDraws) do
      if drawn.content == region.text and drawn.x == region.x and drawn.y == region.y then
        found = found + 1
      end
    end
    Assert.equal(found, 1, "the " .. region.id .. " wording draws once at its published origin")
  end
  for _, side in ipairs({ hud.enemy, hud.player }) do
    for _, region in ipairs(side.regions) do
      if type(region.text) == "string" and region.text ~= "" then
        Assert.isTrue(region.x >= side.x, region.id .. " starts inside its side bounds")
        Assert.isTrue(region.y >= side.y, region.id .. " sits inside its side bounds")
        Assert.isTrue(
          region.x + region.width <= side.x + side.width,
          region.id .. " ends inside its side bounds"
        )
        Assert.isTrue(
          region.y + region.height <= side.y + side.height,
          region.id .. " stays inside its side bounds"
        )
        Assert.isTrue(region.x >= scene.x, region.id .. " starts inside the scene viewport")
        Assert.isTrue(region.y >= scene.y, region.id .. " sits inside the scene viewport")
        Assert.isTrue(
          region.x + region.width <= scene.x + scene.width,
          region.id .. " ends inside the scene viewport"
        )
        Assert.isTrue(
          region.y + region.height <= scene.y + scene.height,
          region.id .. " stays inside the scene viewport"
        )
      end
    end
  end
  local fills = 0
  for _, rectangle in ipairs(graphics.rectangles) do
    if rectangle.y >= PROMPT_OUTER.y then
      fills = fills + 1
      Assert.deepEqual(rectangle.color, windows.background, "dock fills use the shared window background")
    end
  end
  Assert.isTrue(fills > 0, "the dock panels establish their background fills")
end

-- Move selection keeps the four fixed slot identities beside a right-hand
-- information panel and a genuinely clickable Back: the grid never
-- compresses to the known moves, missing slots stay blank, and depleted
-- slots keep their identity for their reason.
function T.move_dock_splits_grid_and_information_with_back()
  local plan = resolve(compactMeasurement(), snapshot("moves"))
  local content = singlePaneContent(plan)
  Assert.equal(content.layout, "moves", "the move plan carries the move scope")
  assertRect(content.dock, MOVE_DOCK, "moves use the taller dock so type, PP and Back fit")
  assertRect(content.movePanels.left, MOVE_LEFT, "the move grid keeps its left frame content")
  assertRect(content.movePanels.right, MOVE_RIGHT, "the information panel keeps its right frame content")
  Assert.equal(content.moveGrid.x, 8, "the grid starts at the left content edge")
  Assert.equal(content.moveGrid.columnWidth, 88, "grid columns split the left content evenly")
  Assert.equal(content.moveGrid.rowHeight, 28, "grid rows split the left content evenly")
  assertRect(content.moveBack.rect, MOVE_BACK, "Back occupies its own pointer-operable cell")
  Assert.equal(content.moveBack.label.x, MOVE_BACK_LABEL.x, "the Back label keeps its origin")
  Assert.equal(content.moveBack.label.y, MOVE_BACK_LABEL.y, "the Back label keeps its row")
  Assert.equal(content.moveInfo.typeRowY, 130, "the type row keeps its origin")
  Assert.equal(content.moveInfo.ppRowY, 148, "the PP row keeps its origin")
  local view = snapshot("moves")
  local first = mappedAt(plan, view, 52, 142)
  Assert.notNil(first, "the upper-left grid cell claims its slot")
  Assert.equal(first.control.id, "move:0", "grid slots keep their fixed identities")
  local upperRight = mappedAt(plan, view, 140, 142)
  Assert.notNil(upperRight, "the upper-right grid cell claims its slot")
  Assert.equal(upperRight.control.id, "move:1", "the upper-right cell keeps the second slot")
  local lowerLeft = mappedAt(plan, view, 52, 170)
  Assert.notNil(lowerLeft, "the lower-left grid cell claims its slot")
  Assert.equal(lowerLeft.control.id, "move:2", "the lower-left cell keeps the third slot")
  local lowerRight = mappedAt(plan, view, 140, 170)
  Assert.notNil(lowerRight, "the lower-right grid cell claims its slot")
  Assert.equal(lowerRight.control.id, "move:3", "the lower-right cell keeps the fourth slot")
  local back = mappedAt(plan, view, 224, 174)
  Assert.notNil(back, "Back is actually clickable")
  Assert.equal(back.type, "battle_press", "Back arms through the shared press convention")
  Assert.equal(back.control.scope, "moves", "Back carries the move scope")
  Assert.equal(back.control.id, "cancel", "Back carries the shared cancel identity")
  Assert.equal(#content.moveLabels, 4, "every slot keeps a label region, present or blank")
  for index, region in ipairs(content.moveLabels) do
    local clip = region --[[@as table<string, unknown>]]
    local column = (index - 1) % 2
    local cellX = 8 + column * 88
    Assert.equal(clip.x, cellX + 8, "slot labels begin eight pixels right of their cursor column")
    Assert.isTrue(
      clip.x --[[@as number]] + clip.width --[[@as number]] <= cellX + 88 - 1,
      "slot label regions never cross their cell edge"
    )
  end
end

-- Target and narration states take full-width docks: target rows derive
-- from the admitted rows with a Back row beneath, while narration owns
-- input alone so the hidden command grid cannot be triggered.
function T.target_and_narration_take_full_width_docks()
  local aimed = resolve(compactMeasurement(), snapshot("target"))
  local aimContent = singlePaneContent(aimed)
  Assert.equal(aimContent.layout, "target", "the target plan carries the target scope")
  assertRect(aimContent.targetBox, TARGET_CONTENT, "explicit targets use the full-width taller dock")
  Assert.isTrue(#aimContent.targetRows >= 2, "admitted target rows plus a Back row resolve")
  local aimView = snapshot("target")
  for _, row in ipairs(aimContent.targetRows) do
    local box = row --[[@as table<string, unknown>]]
    local cx, cy = centerOf(box)
    local mapped = mappedAt(aimed, aimView, cx, cy)
    Assert.notNil(mapped, "each exposed row claims its own control")
    Assert.equal(mapped.control.id, box.id, "pointer regions derive from the same rows as the drawing")
    Assert.equal(box.height --[[@as number]], 16, "target rows stay one line high")
  end
  local narration = resolve(compactMeasurement(), snapshot("narration", { selection = nil }))
  local narrated = singlePaneContent(narration)
  assertRect(narrated.narration.content, NARRATION_CONTENT, "narration uses the full-width ordinary dock")
  Assert.equal(narrated.narration.origin.x, NARRATION_ORIGIN.x, "narration keeps its text origin")
  Assert.equal(narrated.narration.origin.y, NARRATION_ORIGIN.y, "narration keeps its text row")
  local quiet = snapshot("narration", { selection = nil })
  local down = mappedAt(narration, quiet, 152, 154)
  Assert.notNil(down, "the narration dock answers taps")
  local up = narration.mapInput({ type = "pointer_up", pointerId = "touch:0", x = 152, y = 154 }, quiet, narration)
  Assert.notNil(up, "the narration tap completes")
  local confirms = up.type == "confirm"
    or (up.type == "battle_activate" and type(up.control) == "table" and up.control.scope == "narration")
  Assert.isTrue(confirms, "the narration tap carries confirm semantics")
  local sceneDown = mappedAt(narration, quiet, 128, 60)
  Assert.notNil(sceneDown, "the narration surface answers taps")
  local sceneUp = narration.mapInput({ type = "pointer_up", pointerId = "touch:0", x = 128, y = 60 }, quiet, narration)
  Assert.notNil(sceneUp, "the narration scene tap completes")
  local sceneConfirms = sceneUp.type == "confirm"
    or (sceneUp.type == "battle_activate" and type(sceneUp.control) == "table" and sceneUp.control.scope == "narration")
  Assert.isTrue(sceneConfirms, "the narration scene tap carries confirm semantics")
  Assert.isNil(
    narration.mapInput({ type = "pointer_down", pointerId = "touch:0", outside = true }, quiet, narration),
    "outside presses never dismiss narration"
  )
end

-- Other single-surface sizes keep every control reachable: 320x240 takes
-- the same compact pane, a below-1x host downfits the whole logical
-- canvas instead of cropping, and a surface that fits a native pair keeps
-- its complete paired composition with nothing cropped away.
function T.small_hosts_keep_every_control_reachable()
  local medium = resolve(singleMeasurement(320, 240, "single-pane-test:320x240"), snapshot("command"))
  local mediumContent = singlePaneContent(medium)
  assertRect(mediumContent.commands.content, COMMAND_CONTENT, "320x240 keeps the identical compact command box")
  assertRect(mediumContent.prompt.content, PROMPT_CONTENT, "320x240 keeps the identical compact prompt box")
  Assert.equal(#medium.panes, 1, "320x240 stays one fitted pane")
  local tinyHost = resolve(singleMeasurement(200, 150, "single-pane-test:200x150"), snapshot("command"))
  local tinyContent = singlePaneContent(tinyHost)
  assertRect(tinyContent.commands.content, COMMAND_CONTENT, "a below-1x host keeps the identical logical command box")
  local placement = assert(tinyHost.panes[1], "the downfit pane resolves").placement
  Assert.isTrue(placement.logicalWidth == 256, "the downfit still covers the whole logical pane")
  Assert.isTrue(placement.logicalHeight == 192, "the downfit still covers the whole logical height")
  local roomy = resolve(singleMeasurement(512, 384, "single-pane-test:512x384"), snapshot("command"))
  local roomyView = snapshot("command")
  if roomy.content.compact == true then
    assertRect(roomy.content.commands.content, COMMAND_CONTENT, "a roomy host may keep the compact pane intact")
  else
    Assert.equal(#roomy.panes, 2, "a roomy host that pairs keeps both native panes")
    local anchors = { { 128, 83, "fight" }, { 40, 168, "bag" }, { 216, 168, "pokemon" }, { 128, 172, "run" } }
    for _, anchor in ipairs(anchors) do
      local mapped = mappedAt(roomy, roomyView, anchor[1], anchor[2])
      Assert.notNil(mapped, "the paired composition keeps its anchor reachable")
      Assert.equal(mapped.control.id, anchor[3], "the paired composition keeps its command identity")
    end
  end
  Assert.isNil(
    medium.mapInput({ type = "pointer_down", pointerId = "touch:0", outside = true }, roomyView, medium),
    "letterboxed coordinates outside the fitted pane do nothing"
  )
end

-- Long and wide move names never change slot identities and never spill
-- past their cell: every slot keeps a measured label region inside its
-- own cell while the information panel keeps the short type and PP text.
function T.long_labels_stay_inside_their_cells()
  local wide = snapshot("moves", {
    moves = {
      {
        slot = 0,
        name = "A davastatingly long technique name",
        pp = 35,
        maxPp = 35,
        moveType = "DRAGON",
        enabled = true,
      },
      {
        slot = 1,
        name = "つるぎのまいかぜおこし",
        pp = 20,
        maxPp = 20,
        moveType = "FLYING",
        enabled = true,
      },
      { slot = 2, name = "SPLASH", pp = 0, maxPp = 40, moveType = "NORMAL", enabled = false, reason = "no PP left" },
      { slot = 3, enabled = false, reason = "empty" },
    },
  })
  local plan = resolve(compactMeasurement(), wide)
  local content = singlePaneContent(plan)
  Assert.equal(#content.moveLabels, 4, "long names never collapse the slot list")
  for index, region in ipairs(content.moveLabels) do
    local clip = region --[[@as table<string, unknown>]]
    local column = (index - 1) % 2
    local cellX = 8 + column * 88
    Assert.isTrue(
      clip.x --[[@as number]] + clip.width --[[@as number]] <= cellX + 88 - 1,
      "even the longest label region stays inside its own cell"
    )
  end
  local view = snapshot("moves")
  local upperLeft = mappedAt(plan, view, 52, 142)
  Assert.notNil(upperLeft, "the upper-left grid cell claims its slot")
  Assert.equal(upperLeft.control.id, "move:0", "long names keep the first slot identity")
  local empty = mappedAt(plan, view, 140, 170)
  Assert.notNil(empty, "the empty fourth cell claims its slot")
  Assert.equal(empty.control.id, "move:3", "the empty fourth slot keeps its identity")
  Assert.isTrue(content.moveInfo.typeWidth <= 44, "the type representation fits the information panel")
  Assert.isTrue(content.moveInfo.ppWidth <= 44, "the PP representation fits the information panel")
end

---@param species string foe species under test driving
---@param level integer foe level under test driving
---@param seed integer deterministic factory seed under test driving
---@return table full mon-domain record with a single known move
local function foeRecord(species, level, seed)
  local catalog = CatalogFixture.makeCatalog()
  local factory = CatalogFixture.makeFactory(seed, catalog)
  local record = factory:createNormal(CatalogFixture.normalRequest({ species = species, level = level }))
  record.moves = { { move = "TACKLE", pp = 35, ppUps = 0 } }
  return record
end

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
    local record =
      factory:createNormal(CatalogFixture.normalRequest({ species = member.species, level = member.level }))
    record.moves = { { move = "TACKLE", pp = 35, ppUps = 0 } }
    Assert.isTrue(owner:addMon(record), "the parity battle needs its live party member")
  end
  return owner
end

---@param opts table? rig options: launchId, measurement, seed
---@return table live rig with the runtime, screen, port tap, and submit log
local function openRig(opts)
  opts = opts or {}
  local BattleRuntime = require(RUNTIME_MODULE)
  local BattleScreenState = require(STATE_MODULE)
  local Model = require(MODEL_MODULE)
  local holder = {}
  local rig = { submits = {}, measurement = opts.measurement or dualMeasurement() }
  rig.text = {
    draws = {},
    measure = function(content)
      return { width = 8 * #tostring(content), height = 16 }
    end,
    drawText = function(content, x, y)
      rig.text.draws[#rig.text.draws + 1] = { content = content, x = x, y = y }
    end,
  }
  rig.windows = { calls = {} }
  function rig.windows.drawWindow(box, frameKey, background)
    rig.windows.calls[#rig.windows.calls + 1] = { box = box, frame = frameKey, background = background }
  end
  function rig.windows.drawApplicationFrame(box, frameIndex)
    rig.windows.calls[#rig.windows.calls + 1] = { applicationBox = box, frame = frameIndex }
  end
  rig.audio = { plays = {} }
  function rig.audio.play(name)
    rig.audio.plays[#rig.audio.plays + 1] = name
    return true
  end
  rig.assets = { images = {}, prepared = {}, released = {} }
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
  local launchId = opts.launchId or "launch-single-pane"
  local launch = {
    id = launchId,
    kind = "wild",
    payload = {
      attemptId = launchId .. "-attempt",
      species = "EEVEE",
      form = 0,
      level = 4,
      personality = 1,
      ability = "RUN_AWAY",
    },
  }
  local ScenarioFactory = require(SCENARIO_FACTORY_MODULE)
  local scenario = ScenarioFactory.fromEncounter(
    { attemptId = launchId .. "-attempt", mon = foeRecord("EEVEE", 20, 0x5EED0002) },
    { party = party, bag = bag, player = { trainerId = 99, trainerName = "MINT", language = "french" } }
  )
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
local function driveToMode(rig, mode)
  for _ = 1, 600 do
    rig.pump(1)
    local status = rig.screen:status()
    if status.mode == "failed" then
      error("the battle screen failed while driving to " .. mode .. ": " .. tostring(status.error), 0)
    end
    if status.mode == mode then
      return
    end
  end
  error("the battle screen never reached " .. mode, 0)
end

---@param rig table live screen rig under test driving
---@param event table<string, unknown> semantic input batch under test driving
local function press(rig, event)
  rig.screen:input({ event })
  rig.pump(1)
end

---@param rig table live screen rig under test driving
---@param x number display horizontal pointer position under test driving
---@param y number display vertical pointer position under test driving
local function tap(rig, x, y)
  rig.screen:input({ { type = "pointer_down", pointerId = "touch:0", x = x, y = y } })
  rig.screen:input({ { type = "pointer_up", pointerId = "touch:0", x = x, y = y } })
end

---@param request table battle request under inspection
---@return string the decision kind carried by the request
local function requestKind(request)
  if type(request.kind) == "string" and request.kind ~= "action" then
    return request.kind --[[@as string]]
  end
  if type(request.legalChoices) == "table" and type(request.legalChoices.kinds) == "table" then
    local attack = false
    local switch = false
    for _, kind in ipairs(request.legalChoices.kinds) do
      if kind == "attack" then
        attack = true
      end
      if kind == "switch" then
        switch = true
      end
    end
    if switch and not attack then
      return "replacement"
    end
  end
  if type(request.kind) == "string" then
    return request.kind --[[@as string]]
  end
  return "action"
end

---@param rig table live screen rig under test driving
---@param request table open request under projection
---@return table detached native decision options for the open request
local function optionsFor(rig, request)
  local options, optionsErr = rig.battle:decisionOptions(request.requestId)
  Assert.notNil(options, "the runtime projects options for the open request: " .. tostring(optionsErr))
  return options --[[@as table<string, unknown>]]
end

---@param rig table live screen rig under test driving
---@param wanted string awaited battle decision kind under test driving
---@return table the battle request once the kernel asks for the wanted decision
local function waitForBattleDecision(rig, wanted)
  for _ = 1, 60 do
    for _ = 1, 40 do
      rig.pump(1)
      local status = rig.battle:status()
      if status.phase == "failed" then
        error("the battle failed while awaiting " .. wanted .. ": " .. tostring(status.error), 0)
      end
      if status.phase == "complete" then
        error("the battle settled before asking for " .. wanted, 0)
      end
      if status.phase ~= "running" then
        break
      end
      if status.request ~= nil and requestKind(status.request) ~= "action" then
        if requestKind(status.request) == wanted then
          return status.request
        end
        error("the battle asked for " .. requestKind(status.request) .. " instead of " .. wanted, 0)
      end
    end
    local current = rig.battle:status()
    if current.request ~= nil and requestKind(current.request) == "action" then
      local fragment = nil
      for _, actor in ipairs(optionsFor(rig, current.request).actors) do
        for _, choice in ipairs(actor.choices) do
          if choice.role == "move" and choice.enabled == true then
            fragment = fragment or choice.choice
          end
        end
      end
      Assert.notNil(fragment, "the action request carries an enabled move")
      local ok, submitErr = rig.battle:submit({
        requestId = current.request.requestId,
        epoch = current.request.epoch,
        controller = current.request.controller,
        choices = { fragment },
      })
      Assert.isTrue(ok, "the kernel accepts the projected move: " .. tostring(submitErr))
    end
  end
  error("the battle never asked for " .. wanted, 0)
end

---@param rig table live screen rig under test driving
---@param wanted string awaited battle decision kind under test driving
---@return table the mirrored screen request once the screen catches up
local function waitForScreenDecision(rig, wanted)
  for _ = 1, 600 do
    rig.pump(1)
    local status = rig.screen:status()
    if status.mode == "failed" then
      error("the screen failed while awaiting " .. wanted .. ": " .. tostring(status.error), 0)
    end
    if status.request ~= nil and requestKind(status.request) == wanted then
      local current = rig.battle:status()
      if current.request == nil or current.request.requestId == status.request.requestId then
        return status.request
      end
    end
  end
  error("the screen never mirrored " .. wanted, 0)
end

---@param layout string "paired" or "compact" surface arrangement under test driving
---@return table live rig with a learning battle one knockout away
local function openLearnRig(layout)
  local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
  local fullSet = {
    { move = "TACKLE", pp = 35, ppUps = 0 },
    { move = "TAIL_WHIP", pp = 30, ppUps = 0 },
    { move = "GROWL", pp = 40, ppUps = 0 },
    { move = "LEER", pp = 30, ppUps = 0 },
  }
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
  local specs = {
    { species = "EEVEE", level = 7, seed = 0x33333333, experience = 511 },
    {
      species = "EEVEE",
      level = 7,
      seed = 0x44444444,
      ability = "RUN_AWAY",
      experience = 511,
      heldItem = "EXP__SHARE",
    },
  }
  for _, member in ipairs(specs) do
    local factory = CatalogFixture.makeFactory(member.seed, catalog)
    local record =
      factory:createNormal(CatalogFixture.normalRequest({ species = member.species, level = member.level }))
    record.moves = fullSet
    record.experience = member.experience
    if member.heldItem ~= nil then
      record.heldItem = member.heldItem
    end
    Assert.isTrue(owner:addMon(record), "the learning battle needs its live party member")
  end
  local foeFactory = CatalogFixture.makeFactory(0x5EED0002, catalog)
  local foe = foeFactory:createNormal(CatalogFixture.normalRequest({ species = "EEVEE", level = 8 }))
  foe.moves = { { move = "GROWL", pp = 40, ppUps = 0 } }
  foe.condition.currentHp = 1
  local measurement = dualMeasurement()
  if layout == "compact" then
    measurement = compactMeasurement()
  end
  local BattleRuntime = require(RUNTIME_MODULE)
  local BattleScreenState = require(STATE_MODULE)
  local Model = require(MODEL_MODULE)
  local ScenarioFactory = require(SCENARIO_FACTORY_MODULE)
  local holder = {}
  local launchId = "launch-visible-learn-" .. layout
  local rig = { submits = {}, measurement = measurement, layout = layout }
  rig.text = {
    draws = {},
    measure = function(content)
      return { width = 8 * #tostring(content), height = 16 }
    end,
    drawText = function(content, x, y)
      rig.text.draws[#rig.text.draws + 1] = { content = content, x = x, y = y }
    end,
  }
  rig.windows = { calls = {} }
  function rig.windows.drawWindow(box, frameKey, background)
    rig.windows.calls[#rig.windows.calls + 1] = { box = box, frame = frameKey, background = background }
  end
  function rig.windows.drawApplicationFrame(box, frameIndex)
    rig.windows.calls[#rig.windows.calls + 1] = { applicationBox = box, frame = frameIndex }
  end
  rig.audio = { plays = {} }
  function rig.audio.play(name)
    rig.audio.plays[#rig.audio.plays + 1] = name
    return true
  end
  rig.assets = { images = {}, prepared = {}, released = {} }
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
  local bag = HgssBagService.new({ catalog = ItemFixture.makeCatalog() })
  local scenario = ScenarioFactory.fromEncounter(
    { attemptId = launchId .. "-attempt", mon = foe },
    { party = owner, bag = bag, player = { trainerId = 99, trainerName = "MINT", language = "french" } }
  )
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
  holder.battle = BattleRuntime.new({
    request = {
      id = launchId,
      kind = "wild",
      payload = {
        attemptId = launchId .. "-attempt",
        species = "EEVEE",
        form = 0,
        level = 8,
        personality = 1,
        ability = "RUN_AWAY",
      },
    },
    scenario = scenario,
    party = owner,
    bag = bag,
    presentation = screen:presentationPort(),
    seed = 0x12345678,
  })
  rig.battle = holder.battle
  rig.party = owner
  rig.scenario = scenario
  function rig.pump(ticks, dt)
    for _ = 1, ticks or 1 do
      rig.battle:update()
      rig.screen:updateFixed(dt or TICK)
    end
  end
  return rig
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

-- Probes the open learning prompt with matched press/release taps
-- across the interaction surface until one tap seals a reply. Two
-- passes cover entries that focus on the first tap and seal on the
-- second; learning never dismisses outward, so no reopen applies.
---@param rig table live screen rig under test driving
---@param yLo integer first host row under probing
---@param yHi integer last host row under probing
---@return boolean sealed true once a tap sealed exactly one reply
local function tapSealsLearnReply(rig, yLo, yHi)
  local taps = 0
  for pass = 1, 2 do
    local y = yLo
    while y <= yHi do
      local x = 8
      while x <= 248 do
        if rig.screen:status().mode ~= "child" then
          return #rig.submits > 0
        end
        taps = taps + 1
        local id = "touch:learn:" .. tostring(pass) .. ":" .. tostring(taps)
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

-- Taps the dialogue dock through the live plan with a narration and an
-- outcome probe: both must answer with confirm semantics and never
-- dismiss outward, while keyboard input keeps passing through.
---@param rig table live screen rig under test driving
---@param what string layout description under probing
local function assertDialogueTapConfirms(rig, what)
  local plan = rig.screen:status().presentation
  Assert.notNil(plan, "the screen publishes its plan" .. what)
  for _, mode in ipairs({ "narration", "outcome" }) do
    local probe = snapshot(mode, { selection = nil })
    local down = plan.mapInput(
      { type = "pointer_down", pointerId = "touch:dialogue", x = 128, y = 164 },
      probe,
      plan
    )
    Assert.notNil(down, "the " .. mode .. " dialogue answers taps" .. what)
    local up = plan.mapInput(
      { type = "pointer_up", pointerId = "touch:dialogue", x = 128, y = 164 },
      probe,
      plan
    )
    Assert.notNil(up, "the " .. mode .. " dialogue completes taps" .. what)
    local confirms = up.type == "confirm"
      or (up.type == "battle_activate" and type(up.control) == "table" and up.control.scope == mode)
    Assert.isTrue(confirms, "the " .. mode .. " tap carries confirm semantics" .. what)
  end
end

-- The learning prompt lists the four held moves with the incoming move
-- and its five decisions on both display cases, a tap seals exactly
-- one projected learning fragment, the remaining recipient still
-- decides through explicit confirmation, and dialogue taps confirm
-- without reaching the field.
function T.learning_prompt_lists_choices_and_tap_seals_one_fragment()
  for _, layout in ipairs({ "paired", "compact" }) do
    local tag = " (" .. layout .. ")"
    local yLo, yHi = 8, 184
    if layout == "paired" then
      yLo, yHi = 200, 376
    end
    local rig = openLearnRig(layout)
    local leadId = nil
    for _ = 1, 60 do
      local peeked = nil
      for _ = 1, 40 do
        rig.pump(1)
        local status = rig.battle:status()
        if status.phase == "failed" then
          error("the battle failed before learning: " .. tostring(status.error), 0)
        end
        if status.phase == "complete" then
          error("the battle settled before learning", 0)
        end
        if status.request ~= nil then
          peeked = status.request
          break
        end
      end
      if peeked ~= nil then
        if requestKind(peeked) == "action" then
          if leadId == nil then
            leadId = peeked.actors[1].combatant
          end
          local fragment = nil
          for _, actor in ipairs(optionsFor(rig, peeked).actors) do
            for _, choice in ipairs(actor.choices) do
              if choice.role == "move" and choice.enabled == true then
                fragment = fragment or choice.choice
              end
            end
          end
          Assert.notNil(fragment, "the opener carries an enabled move" .. tag)
          local ok, submitErr = rig.battle:submit({
            requestId = peeked.requestId,
            epoch = peeked.epoch,
            controller = peeked.controller,
            choices = { fragment },
          })
          Assert.isTrue(ok, "the kernel accepts the projected move: " .. tostring(submitErr))
        else
          break
        end
      end
    end
    Assert.notNil(leadId, "the opener fights the learning battle" .. tag)
    waitForBattleDecision(rig, "learn_move")
    local firstPrompt = waitForScreenDecision(rig, "learn_move")
    Assert.equal(rig.screen:status().mode, "child", "the learning prompt opens its child" .. tag)
    Assert.isTrue(type(firstPrompt.incomingMove) == "string", "the prompt names its incoming move" .. tag)
    local incomingStem = tostring(firstPrompt.incomingMove):sub(1, 4):lower()
    local ink = renderedContents(rig)
    local namesIncoming = false
    local namesHeld = false
    for content, _ in pairs(ink) do
      local lowered = tostring(content):lower()
      if lowered:find(incomingStem, 1, true) ~= nil then
        namesIncoming = true
      end
      if lowered:find("growl", 1, true) ~= nil then
        namesHeld = true
      end
    end
    Assert.isTrue(namesIncoming, "the prompt shows its incoming move" .. tag)
    Assert.isTrue(namesHeld, "the prompt shows its held moves" .. tag)
    local firstOptions = optionsFor(rig, firstPrompt)
    Assert.equal(firstOptions.actors[1].kind, "learn_move", "learning options mirror the prompt" .. tag)
    local starterSubmits = #rig.submits
    Assert.isTrue(tapSealsLearnReply(rig, yLo, yHi), "a tap on the learning list seals one reply" .. tag)
    Assert.equal(#rig.submits, starterSubmits + 1, "the tap seals exactly one learning reply" .. tag)
    local sealed = rig.submits[#rig.submits].choices[1]
    local sealedId = nil
    for _, choice in ipairs(firstOptions.actors[1].choices) do
      local ok = pcall(Assert.deepEqual, sealed, choice.choice, "the tap matches its fragment" .. tag)
      if ok then
        sealedId = choice.id
      end
    end
    Assert.notNil(sealedId, "the tap seals a projected learning fragment" .. tag)
    local firstRecipient = firstPrompt.actors[1].combatant
    waitForBattleDecision(rig, "learn_move")
    local secondPrompt = waitForScreenDecision(rig, "learn_move")
    Assert.isTrue(secondPrompt.requestId ~= firstPrompt.requestId, "the consecutive prompt is genuinely new" .. tag)
    local secondOptions = optionsFor(rig, secondPrompt)
    local declineFragment = nil
    for _, choice in ipairs(secondOptions.actors[1].choices) do
      if choice.id == "learn:decline" then
        declineFragment = choice.choice
      end
    end
    Assert.notNil(declineFragment, "the second prompt stays declinable" .. tag)
    press(rig, { type = "navigate", direction = "down" })
    press(rig, { type = "navigate", direction = "down" })
    press(rig, { type = "navigate", direction = "down" })
    press(rig, { type = "navigate", direction = "down" })
    press(rig, { type = "confirm" })
    Assert.equal(#rig.submits, starterSubmits + 1, "selecting a row seals no reply" .. tag)
    press(rig, { type = "confirm" })
    Assert.equal(#rig.submits, starterSubmits + 2, "confirming the decline seals one reply" .. tag)
    Assert.deepEqual(
      rig.submits[#rig.submits].choices[1],
      declineFragment,
      "the decline matches its fragment" .. tag
    )
    assertDialogueTapConfirms(rig, tag)
    press(rig, { type = "cancel" })
    Assert.isTrue(#rig.submits <= starterSubmits + 2, "keyboard input passes through without extra seals" .. tag)
    for _ = 1, 400 do
      rig.pump(1)
      if rig.battle:status().phase == "complete" or rig.battle:status().phase == "failed" then
        break
      end
      local current = rig.battle:status()
      if current.request ~= nil and requestKind(current.request) == "action" then
        local fragment = nil
        for _, actor in ipairs(optionsFor(rig, current.request).actors) do
          for _, choice in ipairs(actor.choices) do
            if choice.role == "move" and choice.enabled == true then
              fragment = fragment or choice.choice
            end
          end
        end
        if fragment ~= nil then
          rig.battle:submit({
            requestId = current.request.requestId,
            epoch = current.request.epoch,
            controller = current.request.controller,
            choices = { fragment },
          })
        end
      end
    end
    Assert.equal(rig.battle:status().phase, "complete", "the answered prompts settle the battle" .. tag)
    if firstRecipient == leadId and sealedId ~= "learn:decline" then
      local leadMoves = rig.party:partyMon(0).moves
      Assert.equal(leadMoves[3].move, "SAND_ATTACK", "the tap replace commits through the kernel" .. tag)
    end
    local reserveMoves = rig.party:partyMon(1).moves
    Assert.equal(#reserveMoves, 4, "the declined set keeps its four moves" .. tag)
    rig.screen:dispose()
    rig.battle:dispose()
  end
end

---@param reply table<string, unknown> sealed decision reply under comparison
---@return string serialized comparable shape without functions
local function replyShape(reply)
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
    local keys = {}
    for key in
      pairs(node --[[@as table<unknown, unknown>]])
    do
      keys[#keys + 1] = key
    end
    table.sort(keys, function(left, right)
      return tostring(left) < tostring(right)
    end)
    for index, key in ipairs(keys) do
      if index > 1 then
        parts[#parts + 1] = ","
      end
      parts[#parts + 1] = tostring(key) .. "="
      walk((node --[[@as table<unknown, unknown>]])[key], depth + 1)
    end
    parts[#parts + 1] = "}"
  end
  walk(reply.choices, 0)
  return table.concat(parts, "|") .. "#" .. tostring(reply.epoch) .. "#" .. tostring(reply.controller)
end

-- The same semantic choice seals the same decision on both compositions:
-- a paired keyboard walk and single-pane pointer taps submit identical
-- reply fragments, and one resolved turn leaves identical battler health
-- under the same seed, so compact rendering never changes mechanics or
-- random draws.
function T.paired_and_compact_sequences_seal_the_same_reply()
  local seed = 0x5EED1111
  local paired = openRig({ launchId = "launch-pane-parity-paired", measurement = dualMeasurement(), seed = seed })
  local compact = openRig({ launchId = "launch-pane-parity-compact", measurement = compactMeasurement(), seed = seed })
  driveToMode(paired, "command")
  driveToMode(compact, "command")
  paired.screen:input({ { type = "confirm" } })
  paired.pump(1)
  Assert.equal(paired.screen:status().mode, "moves", "the paired walk opens move selection")
  paired.screen:input({ { type = "confirm" } })
  paired.pump(1)
  Assert.equal(#paired.submits, 1, "the paired walk seals exactly one reply")
  tap(compact, 152, 154)
  compact.pump(1)
  Assert.equal(compact.screen:status().mode, "moves", "tapping the single-pane Fight cell opens move selection")
  tap(compact, 52, 142)
  compact.pump(1)
  Assert.equal(#compact.submits, 1, "tapping the single-pane first slot seals exactly one reply")
  Assert.equal(
    replyShape(compact.submits[1]),
    replyShape(paired.submits[1]),
    "both compositions submit the identical reply fragment"
  )
  paired.pump(120)
  compact.pump(120)
  Assert.deepEqual(
    compact.screen:view().battlers,
    paired.screen:view().battlers,
    "one resolved turn leaves identical battler health on both compositions"
  )
  paired.screen:dispose()
  paired.battle:dispose()
  compact.screen:dispose()
  compact.battle:dispose()
end

-- Re-resolving across display classes keeps the open decision but drops
-- stale pointer state: request identity, semantic selection and cue
-- progress survive the switch, a release on the old coordinates activates
-- nothing, and the new pane answers its own cells.
function T.relayout_keeps_the_decision_and_cancels_the_held_pointer()
  local rig = openRig({ launchId = "launch-pane-relayout", measurement = dualMeasurement() })
  driveToMode(rig, "command")
  local requestId = assert(rig.screen:status().request, "the prompt mirrors its request").requestId
  rig.screen:input({ { type = "pointer_down", pointerId = "touch:0", x = 128, y = 275 } })
  rig.pump(1)
  Assert.equal(rig.screen:view().selection, "fight", "the paired press focuses the first command")
  local before = assert(rig.screen:status().presentation, "the paired plan publishes").inputKey
  rig.measurement = compactMeasurement()
  rig.pump(2)
  local status = rig.screen:status()
  Assert.equal(status.request.requestId, requestId, "the open request survives the layout switch")
  Assert.equal(rig.screen:view().selection, "fight", "the semantic selection survives the layout switch")
  Assert.isTrue(status.presentation.inputKey ~= before, "the layout switch turns the input key")
  local content = singlePaneContent(status.presentation)
  assertRect(content.commands.content, COMMAND_CONTENT, "the re-resolved pane is the compact command composition")
  rig.screen:input({ { type = "pointer_up", pointerId = "touch:0", x = 128, y = 275 } })
  rig.pump(1)
  Assert.equal(#rig.submits, 0, "a release on the stale coordinates activates nothing")
  Assert.equal(rig.screen:status().mode, "command", "the stale release leaves the decision open")
  tap(rig, 152, 154)
  rig.pump(1)
  Assert.equal(rig.screen:status().mode, "moves", "the new pane answers its own Fight cell")
  rig.screen:dispose()
  rig.battle:dispose()
end

-- A pair that cannot fit at least 1x takes the compact pane instead of
-- reporting too-small: the full command composition stays reachable and
-- pointer-operable on the tiny host.
function T.pairs_without_room_take_the_compact_pane()
  local rig = openRig({
    launchId = "launch-pane-fallback",
    measurement = singleMeasurement(100, 60, "single-pane-test:pair-too-small"),
  })
  driveToMode(rig, "command")
  local content = singlePaneContent(rig.screen:status().presentation)
  assertRect(content.commands.content, COMMAND_CONTENT, "the fallback pane keeps the exact command content box")
  assertRect(content.prompt.content, PROMPT_CONTENT, "the fallback pane keeps the exact prompt content box")
  tap(rig, 216, 174)
  rig.pump(1)
  Assert.equal(rig.screen:view().selection, "run", "the fallback pane focuses through its own cells")
  rig.screen:dispose()
  rig.battle:dispose()
end

return { tests = T }
