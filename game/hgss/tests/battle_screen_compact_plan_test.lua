-- Single-pane plan, pointer and dock-drawing contracts for the compact
-- battle composition: fixed dock boxes derived from the real theme
-- insets, half-open hit cells, in-cell label regions, shared-frame
-- composition and integer addressability on tiny pair fallbacks. All
-- fixtures are synthetic; the real application session, the real battle
-- interface set and the real dialogue theme carry the geometry.

local Assert = require("tests.support.Assert")
local ApplicationPresentation = require("libs.ui.src.ApplicationPresentation")
local BattleScreenInterface = require("game.hgss.src.battle.BattleScreenInterface")
local FakeGraphics = require("tests.support.FakeGraphics")
local FieldDialogueTheme = require("libs.hgss.src.ui.FieldDialogueTheme")
local ScreenTopology = require("libs.ui.src.ScreenTopology")

local T = {}

local COMPACT_MODULE = "game.hgss.src.battle.BattleCompactInterface"

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
local function resolve(measurement, view)
  local session = ApplicationPresentation.new(BattleScreenInterface.defaults(), nil)
  return session:resolve(measurement, view)
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

-- The command dock boxes match the fixed single-pane geometry and derive
-- from the outer allocations through the real theme insets with
-- 8-pixel-compatible content.
function T.command_dock_derives_from_real_theme_insets()
  require(COMPACT_MODULE)
  local plan = resolve(singleMeasurement(256, 192, "compact-plan-test:command"), snapshot("command"))
  local content = assert(plan.content, "the compact plan carries its content")
  Assert.isTrue(content.compact == true, "the resolved plan is the compact composition")
  assertRect(content.scene, { x = 0, y = 0, width = 256, height = 136 }, "the scene viewport")
  assertRect(content.dock, { x = 0, y = 136, width = 256, height = 56 }, "the ordinary dock")
  assertRect(content.prompt.outer, { x = 0, y = 136, width = 112, height = 56 }, "the prompt outer allocation")
  assertRect(content.prompt.content, { x = 8, y = 144, width = 96, height = 40 }, "the prompt frame content")
  assertRect(content.commands.outer, { x = 112, y = 136, width = 144, height = 56 }, "the command outer allocation")
  assertRect(content.commands.content, { x = 120, y = 144, width = 128, height = 40 }, "the command frame content")
  local insets = FieldDialogueTheme.applicationFrameInsets()
  for _, named in ipairs({ { "prompt", content.prompt }, { "commands", content.commands } }) do
    local outer = named[2].outer
    local box = named[2].content
    Assert.equal(box.x, outer.x + insets.left, named[1] .. " content starts at the real horizontal inset")
    Assert.equal(box.width, outer.width - insets.left - insets.right, named[1] .. " content removes both insets")
    Assert.equal(box.y, outer.y + insets.top + 1, named[1] .. " content starts below the top cap strip")
    Assert.equal(
      box.height,
      outer.height - insets.top - insets.bottom - 2,
      named[1] .. " content height removes both cap strips"
    )
    Assert.equal(box.width % 8, 0, named[1] .. " content width stays 8-pixel compatible")
    Assert.equal(box.height % 8, 0, named[1] .. " content height stays 8-pixel compatible")
  end
  Assert.equal(#content.commands.cells, 4, "the command grid carries four hit cells")
  Assert.equal(#content.commands.cursors, 4, "every command cell carries its cursor origin")
end

-- The move dock uses the taller allocation with the fixed grid
-- constants, an operable Back cell and a measured information panel.
function T.move_dock_grid_back_and_info()
  require(COMPACT_MODULE)
  local plan = resolve(singleMeasurement(256, 192, "compact-plan-test:moves"), snapshot("moves"))
  local content = assert(plan.content, "the move plan carries its content")
  Assert.isTrue(content.compact == true, "the move plan is the compact composition")
  assertRect(content.dock, { x = 0, y = 120, width = 256, height = 72 }, "moves use the taller dock")
  assertRect(content.movePanels.left, { x = 8, y = 128, width = 176, height = 56 }, "the move grid content")
  assertRect(content.movePanels.right, { x = 200, y = 128, width = 48, height = 56 }, "the information content")
  Assert.equal(content.moveGrid.x, 8, "the grid starts at the left content edge")
  Assert.equal(content.moveGrid.columnWidth, 88, "grid columns split the left content evenly")
  Assert.equal(content.moveGrid.rowHeight, 28, "grid rows split the left content evenly")
  assertRect(content.moveBack.rect, { x = 200, y = 164, width = 48, height = 20 }, "Back keeps its own cell")
  Assert.equal(content.moveBack.label.x, 204, "the Back label keeps its column")
  Assert.equal(content.moveBack.label.y, 166, "the Back label keeps its row")
  Assert.equal(content.moveInfo.typeRowY, 130, "the type row keeps its origin")
  Assert.equal(content.moveInfo.ppRowY, 148, "the PP row keeps its origin")
  Assert.isTrue(content.moveInfo.typeWidth <= 44, "the type representation fits the information panel")
  Assert.isTrue(content.moveInfo.ppWidth <= 44, "the PP representation fits the information panel")
  Assert.equal(#content.moveLabels, 4, "every slot keeps a label region")
  for index, region in ipairs(content.moveLabels) do
    local column = (index - 1) % 2
    local row = math.floor((index - 1) / 2)
    local cellX = 8 + column * 88
    local cellY = 128 + row * 28
    Assert.equal(region.x, cellX + 8, "slot labels begin eight pixels right of their cursor column")
    Assert.isTrue(region.x + region.width <= cellX + 88 - 1, "slot label regions never cross their cell edge")
    Assert.isTrue(region.y >= cellY and region.y + 16 <= cellY + 28, "slot label rows stay inside their cell")
  end
end

-- Target rows derive from the admitted rows with a Back row beneath, and
-- narration owns the full-width ordinary dock alone.
function T.target_rows_and_narration_boxes()
  require(COMPACT_MODULE)
  local aimed = resolve(singleMeasurement(256, 192, "compact-plan-test:target"), snapshot("target"))
  local aimContent = assert(aimed.content, "the target plan carries its content")
  assertRect(aimContent.targetBox, { x = 8, y = 128, width = 240, height = 56 }, "targets use the full taller dock")
  Assert.isTrue(#aimContent.targetRows >= 2, "admitted rows plus a Back row resolve")
  local last = aimContent.targetRows[#aimContent.targetRows]
  Assert.equal(last.id, "cancel", "the final target row carries the shared cancel identity")
  for _, row in ipairs(aimContent.targetRows) do
    Assert.equal(row.height, 16, "target rows stay one line high")
  end
  Assert.equal(aimContent.targetRows[1].y, 130, "target rows start at the first line")
  local view = snapshot("target")
  for _, row in ipairs(aimContent.targetRows) do
    local mapped = aimed.mapInput(
      { type = "pointer_down", pointerId = "touch:0", x = row.x + math.floor(row.width / 2), y = row.y + 8 },
      view,
      aimed
    )
    Assert.notNil(mapped, "each exposed row claims its own control")
    Assert.equal(mapped.control.id, row.id, "pointer regions derive from the same rows as the drawing")
  end
  local narration = resolve(
    singleMeasurement(256, 192, "compact-plan-test:narration"),
    snapshot("narration", { selection = nil })
  )
  local narrated = assert(narration.content, "the narration plan carries its content")
  assertRect(narrated.narration.content, { x = 8, y = 144, width = 240, height = 40 }, "narration fills the dock")
  Assert.equal(narrated.narration.origin.x, 12, "narration keeps its text origin")
  Assert.equal(narrated.narration.origin.y, 146, "narration keeps its text row")
  Assert.equal(narrated.narration.width, 232, "narration keeps its text width")
  local quiet = snapshot("narration", { selection = nil })
  local down = narration.mapInput(
    { type = "pointer_down", pointerId = "touch:0", x = 152, y = 154 },
    quiet,
    narration
  )
  Assert.notNil(down, "the narration dock answers taps")
  local up = narration.mapInput(
    { type = "pointer_up", pointerId = "touch:0", x = 152, y = 154 },
    quiet,
    narration
  )
  Assert.notNil(up, "the narration tap completes")
  local confirms = up.type == "confirm"
    or (up.type == "battle_activate" and type(up.control) == "table" and up.control.scope == "narration")
  Assert.isTrue(confirms, "the narration tap carries confirm semantics")
end

-- Pointer edges are half-open with a single host-to-logical transform:
-- shared edges belong to the right and lower cells, and a fitted pane
-- inverts host coordinates exactly once through its own placement.
function T.half_open_edges_and_single_session_transform()
  require(COMPACT_MODULE)
  local plan = resolve(singleMeasurement(256, 192, "compact-plan-test:edges"), snapshot("command"))
  local content = assert(plan.content, "the command plan carries its content")
  local view = snapshot("command")
  local first = content.commands.cells[1]
  local edge = plan.mapInput(
    { type = "pointer_down", pointerId = "touch:0", x = first.x + first.width, y = first.y + 2 },
    view,
    plan
  )
  Assert.notNil(edge, "the shared vertical edge still claims a control")
  Assert.equal(edge.control.id, "bag", "half-open intervals give the shared edge to the right cell")
  local lower = plan.mapInput(
    { type = "pointer_down", pointerId = "touch:0", x = first.x + 2, y = first.y + first.height },
    view,
    plan
  )
  Assert.notNil(lower, "the shared horizontal edge still claims a control")
  Assert.equal(lower.control.id, "pokemon", "half-open intervals give the shared edge to the lower cell")
  Assert.isNil(
    plan.mapInput({ type = "pointer_down", pointerId = "touch:0", x = 60, y = 140 }, view, plan),
    "the cap strip above the dock claims nothing"
  )
  local session = ApplicationPresentation.new(BattleScreenInterface.defaults(), nil)
  local fitted = session:resolve(singleMeasurement(320, 240, "compact-plan-test:fitted"), snapshot("command"))
  local placement = assert(fitted.panes[1], "the fitted pane resolves").placement
  local hostX = placement.origin.x + 152 * placement.scale
  local hostY = placement.origin.y + 154 * placement.scale
  local before = session:plan()
  Assert.equal(before.inputKey, fitted.inputKey, "the fitted resolve publishes its plan")
  local mapped = (session:plan().mapInput ~= nil) and fitted or nil
  Assert.notNil(mapped, "the fitted plan carries its mapper")
  local LayoutGeometry = require("libs.ui.src.LayoutGeometry")
  local logicalX, logicalY = LayoutGeometry.hostToLogical(placement, hostX, hostY)
  Assert.notNil(logicalX, "the fitted placement inverts the host point")
  local pressed = fitted.mapInput(
    { type = "pointer_down", pointerId = "touch:0", x = logicalX, y = logicalY },
    view,
    fitted
  )
  Assert.notNil(pressed, "the once-inverted point claims its control")
  Assert.equal(pressed.control.id, "fight", "the fitted pane answers the same Fight cell")
end

-- Releasing over an already-focused move or target slot confirms
-- through the shared confirm semantic, while other releases keep the
-- press convention and the command grid is unaffected.
function T.focused_slot_release_confirms_through_shared_confirm()
  require(COMPACT_MODULE)
  local plan = resolve(singleMeasurement(256, 192, "compact-plan-test:confirm"), snapshot("moves"))
  local focused = snapshot("moves")
  local confirm = plan.mapInput(
    { type = "pointer_up", pointerId = "touch:0", x = 52, y = 142 },
    focused,
    plan
  )
  Assert.notNil(confirm, "releasing over the focused slot answers")
  Assert.equal(confirm.type, "confirm", "the focused slot submits through the shared confirm semantic")
  local unfocused = snapshot("moves", { selection = "move:1" })
  local activate = plan.mapInput(
    { type = "pointer_up", pointerId = "touch:0", x = 52, y = 142 },
    unfocused,
    plan
  )
  Assert.notNil(activate, "releasing over an unfocused slot answers")
  Assert.equal(activate.type, "battle_activate", "unfocused releases keep the press convention")
  Assert.equal(activate.control.id, "move:0", "the release still names its own slot")
  local commandPlan =
    resolve(singleMeasurement(256, 192, "compact-plan-test:confirm-command"), snapshot("command"))
  local commandRelease = commandPlan.mapInput(
    { type = "pointer_up", pointerId = "touch:0", x = 152, y = 154 },
    snapshot("command"),
    commandPlan
  )
  Assert.notNil(commandRelease, "command releases answer")
  Assert.equal(commandRelease.type, "battle_activate", "the command grid keeps the press convention")
  local aimed = resolve(singleMeasurement(256, 192, "compact-plan-test:confirm-target"), snapshot("target"))
  local aimRelease = aimed.mapInput(
    { type = "pointer_up", pointerId = "touch:0", x = 128, y = 138 },
    snapshot("target"),
    aimed
  )
  Assert.notNil(aimRelease, "releasing over the focused target answers")
  Assert.equal(aimRelease.type, "confirm", "the focused target submits through the shared confirm semantic")
end

-- Disabled options stay focusable while empty slots stay blank: the grid
-- never drops a slot identity, and the empty cell draws no name.
function T.disabled_focusable_absent_blank()
  require(COMPACT_MODULE)
  local plan = resolve(singleMeasurement(256, 192, "compact-plan-test:disabled"), snapshot("moves"))
  local content = assert(plan.content, "the move plan carries its content")
  local view = snapshot("moves")
  local spent = plan.mapInput({ type = "pointer_down", pointerId = "touch:0", x = 52, y = 170 }, view, plan)
  Assert.notNil(spent, "the depleted cell claims its slot")
  Assert.equal(spent.control.id, "move:2", "the depleted slot keeps its identity for its reason")
  Assert.equal(spent.type, "battle_press", "disabled presses arm through the shared press convention")
  local empty = plan.mapInput({ type = "pointer_down", pointerId = "touch:0", x = 140, y = 170 }, view, plan)
  Assert.notNil(empty, "the empty fourth cell claims its slot")
  Assert.equal(empty.control.id, "move:3", "the empty slot keeps its identity instead of vanishing")
  local graphics = FakeGraphics.new({})
  local order = {}
  local resources = {
    graphics = graphics,
    text = recordingText(order),
    windows = recordingWindows(order),
    assets = {
      drawable = function(_, key)
        return { handle = key }
      end,
    },
    frameKey = "compact-plan-test-frame",
    sceneImageKey = "scene:test",
  }
  ApplicationPresentation.draw(graphics, resources, snapshot("moves"), plan)
  local drawn = resources.text.draws
  local named = 0
  for _, entry in ipairs(drawn) do
    if entry.content:find("TACKLE", 1, true) ~= nil or entry.content == "GROWL" or entry.content:find("TAIL WHIP", 1, true) ~= nil then
      named = named + 1
    end
  end
  Assert.isTrue(named >= 2, "usable move names draw inside their cells")
  local blankOrigin = content.moveLabels[4]
  for _, entry in ipairs(drawn) do
    Assert.isTrue(
      not (entry.x == blankOrigin.x and entry.y == blankOrigin.y),
      "the empty fourth slot draws no name at its label origin"
    )
  end
end

-- Long and wide names stay inside their own cells: label regions never
-- cross a cell edge and drawn text fits the measured region.
function T.label_clip_regions_bound_drawn_text()
  require(COMPACT_MODULE)
  local wide = snapshot("moves", {
    moves = {
      { slot = 0, name = "A davastatingly long technique name", pp = 35, maxPp = 35, moveType = "DRAGON", enabled = true },
      { slot = 1, name = "つるぎのまいかぜおこし", pp = 20, maxPp = 20, moveType = "FLYING", enabled = true },
      { slot = 2, name = "SPLASH", pp = 0, maxPp = 40, moveType = "NORMAL", enabled = false, reason = "no PP left" },
      { slot = 3, enabled = false, reason = "empty" },
    },
  })
  local plan = resolve(singleMeasurement(256, 192, "compact-plan-test:labels"), wide)
  local content = assert(plan.content, "the wide move plan carries its content")
  Assert.equal(#content.moveLabels, 4, "long names never collapse the slot list")
  for index, region in ipairs(content.moveLabels) do
    local column = (index - 1) % 2
    local cellX = 8 + column * 88
    Assert.isTrue(
      region.x + region.width <= cellX + 88 - 1,
      "even the longest label region stays inside its own cell"
    )
  end
  local graphics = FakeGraphics.new({})
  local order = {}
  local text = recordingText(order)
  ApplicationPresentation.draw(graphics, {
    graphics = graphics,
    text = text,
    windows = recordingWindows(order),
    assets = {
      drawable = function(_, key)
        return { handle = key }
      end,
    },
    frameKey = "compact-plan-test-frame",
    sceneImageKey = "scene:test",
  }, wide, plan)
  for _, entry in ipairs(text.draws) do
    local width = text.measure(entry.content).width
    local insideGrid = entry.y == 134 or entry.y == 162
    if insideGrid and (entry.x == 16 or entry.x == 104) then
      Assert.isTrue(width <= 79, "drawn move names fit their measured cell region: " .. entry.content)
    end
  end
  local promptPlan = resolve(
    singleMeasurement(256, 192, "compact-plan-test:prompt-page"),
    snapshot("command", { message = string.rep("Abcdefghij ", 20) })
  )
  local promptGraphics = FakeGraphics.new({})
  local promptOrder = {}
  local promptText = recordingText(promptOrder)
  ApplicationPresentation.draw(promptGraphics, {
    graphics = promptGraphics,
    text = promptText,
    windows = recordingWindows(promptOrder),
    assets = {
      drawable = function(_, key)
        return { handle = key }
      end,
    },
    frameKey = "compact-plan-test-frame",
    sceneImageKey = "scene:test",
  }, snapshot("command", { message = string.rep("Abcdefghij ", 20) }), promptPlan)
  local promptBox = assert(promptPlan.content.prompt, "the prompt plan carries its prompt").content
  local promptHud = assert(promptPlan.content.hud, "the prompt plan carries its HUD bounds")
  local promptHudRegions = {}
  for _, side in ipairs({ promptHud.enemy, promptHud.player }) do
    for _, region in ipairs(side.regions) do
      if type(region.text) == "string" and region.text ~= "" then
        promptHudRegions[#promptHudRegions + 1] = region
      end
    end
  end
  for _, entry in ipairs(promptText.draws) do
    local hudScoped = false
    for _, region in ipairs(promptHudRegions) do
      if entry.content == region.text and entry.x == region.x and entry.y == region.y then
        hudScoped = true
        break
      end
    end
    if not hudScoped and entry.x < 112 then
      Assert.isTrue(entry.y >= promptBox.y + 2, "wrapped prompt text stays below the cap-overlap row")
      Assert.isTrue(
        entry.y + 16 <= promptBox.y + promptBox.height - 1,
        "wrapped prompt text stays above the bottom cap row"
      )
      Assert.isTrue(
        promptText.measure(entry.content).width <= 88,
        "wrapped prompt lines fit the prompt width: " .. entry.content
      )
    end
  end
end

-- Compact HUD anchors follow the visible-bounds policy while the paired
-- native anchors stay exactly where the source geometry puts them.
function T.hud_anchors_and_native_defaults_unaffected()
  require(COMPACT_MODULE)
  local BattleRenderer = require("game.hgss.src.battle.BattleRenderer")
  local plan = resolve(singleMeasurement(256, 192, "compact-plan-test:hud"), snapshot("command"))
  local content = assert(plan.content, "the compact plan carries its content")
  Assert.equal(content.hud.enemy.x, 4, "the enemy bounds keep their left anchor")
  Assert.equal(content.hud.enemy.y, 4, "the enemy bounds keep their top anchor")
  Assert.equal(content.hud.player.rightEdge, 252, "the player bounds keep their right edge")
  Assert.equal(content.hud.player.bottomEdge, 132, "the player bounds sit above the dock")
  Assert.equal(content.playerCenter.x, 60, "the player image keeps its interim center column")
  Assert.equal(content.playerCenter.y, 96, "the player image keeps its interim center row")
  Assert.equal(content.enemyCenter.x, 196, "the enemy image keeps its interim center column")
  Assert.equal(content.enemyCenter.y, 44, "the enemy image keeps its interim center row")
  Assert.equal(BattleRenderer.PLAYER_CENTER.x, 64, "the native player image center is unchanged")
  Assert.equal(BattleRenderer.ENEMY_CENTER.x, 192, "the native enemy image center is unchanged")
  Assert.equal(BattleRenderer.PLAYER_HUD.x, 192, "the native player HUD anchor is unchanged")
  Assert.equal(BattleRenderer.ENEMY_HUD.x, 58, "the native enemy HUD anchor is unchanged")
  local session = ApplicationPresentation.new(BattleScreenInterface.defaults(), nil)
  local dual = session:resolve({
    width = 256,
    height = 384,
    topology = ScreenTopology.dualDisplay(
      { id = "main", rect = { x = 0, y = 0, width = 256, height = 192 }, touch = false, role = "world" },
      { id = "lower", rect = { x = 0, y = 192, width = 256, height = 192 }, touch = true, role = "auxiliary" },
      "compact-plan-test:dual-native"
    ),
    pixelRatio = 1,
    signature = "compact-plan-test:dual-native",
  }, snapshot("command"))
  Assert.equal(#dual.panes, 2, "the dual composition keeps both native panes")
  Assert.isTrue(dual.content.compact ~= true, "the paired plan carries no compact marker")
  local native = dual.mapInput({ type = "pointer_down", pointerId = "touch:0", x = 128, y = 83 }, snapshot("command"), dual)
  Assert.notNil(native, "the native Fight anchor still claims its control")
  Assert.equal(native.control.id, "fight", "the native Fight anchor keeps its identity")
end

-- The input key is stable across equivalent resolutions, turns on
-- semantic changes, and never turns on a held press alone.
function T.input_key_semantics()
  require(COMPACT_MODULE)
  local measurement = singleMeasurement(256, 192, "compact-plan-test:key")
  local key = resolve(measurement, snapshot("command")).inputKey
  Assert.equal(resolve(measurement, snapshot("command")).inputKey, key, "equivalent resolutions keep the key")
  Assert.isTrue(
    resolve(measurement, snapshot("command", { selection = "bag" })).inputKey ~= key,
    "a semantic selection change turns the key"
  )
  Assert.isTrue(
    resolve(measurement, snapshot("moves")).inputKey ~= key,
    "a mode change turns the key"
  )
  Assert.isTrue(
    resolve(measurement, snapshot("command", { requestId = 9 })).inputKey ~= key,
    "a request change turns the key"
  )
  Assert.equal(
    resolve(measurement, snapshot("command", { armed = { scope = "command", id = "fight" } })).inputKey,
    key,
    "a held press alone never turns the key"
  )
end

-- Every framed content box satisfies the real frame geometry: the theme
-- computes tile placements for each box, and dock text origins stay
-- clear of the cap-overlap rows inside their own panel bands.
function T.content_boxes_satisfy_real_frame_geometry()
  require(COMPACT_MODULE)
  local plan = resolve(singleMeasurement(256, 192, "compact-plan-test:frames"), snapshot("command"))
  local content = assert(plan.content, "the compact plan carries its content")
  local boxes = {
    { name = "prompt", outer = content.prompt.outer, box = content.prompt.content },
    { name = "commands", outer = content.commands.outer, box = content.commands.content },
    { name = "moves", outer = { x = 0, y = 120, width = 192, height = 72 }, box = content.movePanels.left },
    { name = "move-info", outer = { x = 192, y = 120, width = 64, height = 72 }, box = content.movePanels.right },
    { name = "target", outer = { x = 0, y = 120, width = 256, height = 72 }, box = content.targetBox },
    { name = "narration", outer = { x = 0, y = 136, width = 256, height = 56 }, box = content.narration.content },
  }
  local origins = {
    { x = 12, y = 146, box = "prompt" },
    { x = 128, y = 146, box = "commands" },
    { x = 192, y = 166, box = "commands" },
    { x = 16, y = 134, box = "moves" },
    { x = 202, y = 130, box = "move-info" },
    { x = 12, y = 146, box = "narration" },
  }
  local byName = {}
  for _, dock in ipairs(boxes) do
    byName[dock.name] = dock.box
    local placements = FieldDialogueTheme.applicationFrameTilePlacements(dock.box)
    for _, group in ipairs({ placements.top, placements.sides, placements.bottom }) do
      for _, placement in ipairs(group) do
        Assert.isTrue(
          placement.x >= dock.outer.x - 8 and placement.x + 8 <= dock.outer.x + dock.outer.width + 8,
          dock.name .. " border tiles stay on their own panel band"
        )
        Assert.isTrue(
          placement.y >= dock.outer.y - 8 and placement.y + 8 <= dock.outer.y + dock.outer.height + 8,
          dock.name .. " cap tiles stay on their own dock band"
        )
      end
    end
  end
  for _, origin in ipairs(origins) do
    local box = assert(byName[origin.box], "the text origin names its dock box")
    Assert.isTrue(origin.y >= box.y + 2, "text stays two pixels below the cap-overlap row")
    Assert.isTrue(origin.y + 16 <= box.y + box.height - 1, "text stays above the bottom cap-overlap row")
  end
end

-- A pair without room takes the addressable compact pane: the tiny host
-- keeps integer mapping so every cell stays pointer-operable, while
-- coordinates outside the application do nothing.
function T.pair_fallback_is_compact_integer_addressable()
  require(COMPACT_MODULE)
  local session = ApplicationPresentation.new(BattleScreenInterface.defaults(), nil)
  local plan = session:resolve(singleMeasurement(100, 60, "compact-plan-test:pair-too-small"), snapshot("command"))
  Assert.isNil(plan.content.pendingAdapter, "the fallback is the compact composition, not the pending adapter")
  Assert.isNil(plan.content.tooSmall, "the fallback fits its one pane, it is not too small")
  Assert.isTrue(plan.content.compact == true, "the fallback plan says it is the compact composition")
  assertRect(
    plan.content.commands.content,
    { x = 120, y = 144, width = 128, height = 40 },
    "the fallback keeps the exact command content box"
  )
  local placement = assert(plan.panes[1], "the fallback pane resolves").placement
  Assert.equal(placement.scale, 1, "the fallback keeps integer mapping so cells stay operable")
  Assert.equal(placement.logicalWidth, 256, "the fallback covers the whole logical width")
  Assert.equal(placement.logicalHeight, 192, "the fallback covers the whole logical height")
  local view = snapshot("command")
  local run = plan.mapInput({ type = "pointer_down", pointerId = "touch:0", x = 216, y = 174 }, view, plan)
  Assert.notNil(run, "the fallback Run cell claims its control")
  Assert.equal(run.control.id, "run", "the fallback keeps the Run identity")
  Assert.isNil(
    plan.mapInput({ type = "pointer_down", pointerId = "touch:0", outside = true }, view, plan),
    "coordinates outside the application do nothing"
  )
end

-- A below-1x native-like host keeps integer mapping at the logical
-- origin: the logical boxes stay identical while the placement carries
-- the complete pane at the one-times floor so every cell stays
-- pointer-operable.
function T.tiny_native_like_keeps_integer_mapping_at_origin()
  require(COMPACT_MODULE)
  local plan = resolve(singleMeasurement(200, 150, "compact-plan-test:downfit"), snapshot("command"))
  local content = assert(plan.content, "the tiny plan carries its content")
  Assert.isTrue(content.compact == true, "the tiny plan is the compact composition")
  assertRect(
    content.commands.content,
    { x = 120, y = 144, width = 128, height = 40 },
    "the tiny host keeps the identical logical command box"
  )
  local placement = assert(plan.panes[1], "the tiny pane resolves").placement
  Assert.equal(placement.scale, 1, "the tiny host keeps integer mapping so cells stay operable")
  Assert.equal(placement.logicalWidth, 256, "the tiny host still covers the whole logical width")
  Assert.equal(placement.logicalHeight, 192, "the tiny host still covers the whole logical height")
end

-- Dock drawing establishes the shared window background, draws text,
-- then borders both content boxes with the one selected frame; fills
-- use the shared background, never black or hard-coded white.
function T.dock_draw_uses_shared_background_and_shared_frame()
  require(COMPACT_MODULE)
  local plan = resolve(singleMeasurement(256, 192, "compact-plan-test:draw"), snapshot("command"))
  local graphics = FakeGraphics.new({})
  local order = {}
  local windows = recordingWindows(order)
  local resources = {
    graphics = graphics,
    text = recordingText(order),
    windows = windows,
    assets = {
      drawable = function(_, key)
        return { handle = key }
      end,
    },
    frameKey = "compact-plan-test-frame",
    sceneImageKey = "scene:test",
  }
  ApplicationPresentation.draw(graphics, resources, snapshot("command"), plan)
  Assert.equal(#windows.frames, 2, "both dock panels take a shared application border")
  Assert.equal(windows.frames[1].index, windows.frames[2].index, "both panels share the one selected frame")
  local fills = 0
  for _, rectangle in ipairs(graphics.rectangles) do
    if rectangle.y >= 136 then
      fills = fills + 1
      Assert.deepEqual(rectangle.color, windows.background, "dock fills use the shared window background")
      Assert.isTrue(
        rectangle.color[1] ~= 0 or rectangle.color[2] ~= 0 or rectangle.color[3] ~= 0,
        "dock fills are never black"
      )
    end
  end
  Assert.isTrue(fills >= 2, "both dock panels establish their background fills")
end

return { tests = T }
