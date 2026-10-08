-- Compact battlefield HUD: the enemy and player composites draw from the
-- selected source artwork at the plan bounds, with the dynamic name, level,
-- condition and health regions resolving the snapshot values and the health
-- bars keeping the paired fractions and shades. All fixtures are synthetic;
-- the real application session and the real battle interface set carry the
-- geometry and the drawing.

local Assert = require("tests.support.Assert")
local ApplicationPresentation = require("libs.ui.src.ApplicationPresentation")
local BattleScreenInterface = require("game.hgss.src.battle.BattleScreenInterface")
local FakeGraphics = require("tests.support.FakeGraphics")
local ScreenTopology = require("libs.ui.src.ScreenTopology")

local T = {}

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

---@param overrides table? snapshot fields replacing the healthy defaults
---@return table internal semantic snapshot for resolvers and renderers
local function snapshot(overrides)
  local view = {
    mode = "command",
    selection = "fight",
    armed = nil,
    requestId = 7,
    message = "What will MINT do?",
    messageId = 1,
    battlers = {
      {
        combatant = 1,
        side = 1,
        hp = 52,
        maxHp = 52,
        visible = true,
        name = "LEAD",
        level = 20,
        exp = 1234,
        condition = nil,
        shakeDx = 0,
      },
      {
        combatant = 3,
        side = 2,
        hp = 57,
        maxHp = 57,
        visible = true,
        name = "FOE",
        level = 20,
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
    moves = {},
    partyRoster = {
      { slot = 0, hp = 52, maxHp = 52 },
    },
    foeCount = 1,
    arrowFrame = 0,
    childIntent = nil,
  }
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

---@return table recording text boundary that must stay silent for HUD content
local function recordingText()
  local text = { draws = {}, measures = 0 }
  function text.measure(content)
    text.measures = text.measures + 1
    return { width = 8 * #tostring(content), height = 16 }
  end
  function text.drawText(content, x, y)
    text.draws[#text.draws + 1] = { content = tostring(content), x = x, y = y, palette = nil }
  end
  function text.drawTextWithPalette(content, x, y, palette)
    text.draws[#text.draws + 1] = { content = tostring(content), x = x, y = y, palette = palette }
  end
  return text
end

---@return table recording window boundary with a distinctive background
local function recordingWindows()
  local windows = { frames = {}, boxes = {}, background = { 0.2, 0.3, 0.1, 1 } }
  function windows.drawWindow(box, frameKey, background)
    windows.boxes[#windows.boxes + 1] = { box = box, frame = frameKey, background = background }
  end
  function windows.drawApplicationFrame(box, frameIndex)
    windows.frames[#windows.frames + 1] =
      { box = { x = box.x, y = box.y, width = box.width, height = box.height }, index = frameIndex }
  end
  return windows
end

---@param view table internal semantic snapshot under drawing
---@param held string[] artwork keys reporting unavailable
---@return table graphics, text, windows and stub resources behind one draw
local function drawnHud(view, held)
  local plan = resolve(singleMeasurement(256, 192, "compact-hud-test:draw"), view)
  local graphics = FakeGraphics.new({})
  local text = recordingText()
  local windows = recordingWindows()
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
    frameKey = "compact-hud-test-frame",
    sceneImageKey = "scene:test",
  }
  ApplicationPresentation.draw(graphics, resources, view, plan)
  return { graphics = graphics, text = text, windows = windows, plan = plan }
end

---@param graphics table recording graphics boundary under inspection
---@param handle string artwork identity under inspection
---@return table[] draws carrying that artwork identity
local function drawsOf(graphics, handle)
  local found = {}
  for _, entry in ipairs(graphics.draws) do
    if type(entry.image) == "table" and entry.image.handle == handle then
      found[#found + 1] = entry
    end
  end
  return found
end

-- The enemy composite draws unscaled from the selected enemy artwork with
-- its complete bounds at the left/top anchor.
function T.enemy_composite_draws_unscaled_at_left_top_bounds()
  local result = drawnHud(snapshot(), {})
  local content = assert(result.plan.content, "the compact plan carries its content")
  local bounds = assert(content.hud.enemy, "the plan carries the enemy bounds")
  Assert.equal(bounds.x, 4, "the enemy bounds keep their left anchor")
  Assert.equal(bounds.y, 4, "the enemy bounds keep their top anchor")
  local composites = drawsOf(result.graphics, "hud:enemy")
  Assert.equal(#composites, 1, "the enemy artwork draws exactly once")
  Assert.equal(composites[1].x, bounds.x, "the enemy composite starts at the bounds left")
  Assert.equal(composites[1].y, bounds.y, "the enemy composite starts at the bounds top")
  Assert.isTrue(
    composites[1].sx == nil or composites[1].sx == 1,
    "the enemy composite draws unscaled horizontally"
  )
  Assert.isTrue(composites[1].sy == nil or composites[1].sy == 1, "the enemy composite draws unscaled vertically")
  Assert.isNil(composites[1].quad, "the enemy composite draws whole, never a sub-cell")
end

-- The player composite draws unscaled from the selected player artwork
-- with its complete bounds right-aligned and above the dock.
function T.player_composite_right_and_bottom_edges_hold_above_dock()
  local result = drawnHud(snapshot(), {})
  local content = assert(result.plan.content, "the compact plan carries its content")
  local bounds = assert(content.hud.player, "the plan carries the player bounds")
  Assert.equal(bounds.x + bounds.width, 252, "the player bounds keep their right edge")
  Assert.equal(bounds.y + bounds.height, 132, "the player bounds sit above the dock")
  local composites = drawsOf(result.graphics, "hud:player")
  Assert.equal(#composites, 1, "the player artwork draws exactly once")
  Assert.equal(composites[1].x, bounds.x, "the player composite starts at the bounds left")
  Assert.equal(composites[1].y, bounds.y, "the player composite starts at the bounds top")
  Assert.isTrue(
    composites[1].sx == nil or composites[1].sx == 1,
    "the player composite draws unscaled horizontally"
  )
  Assert.isTrue(composites[1].sy == nil or composites[1].sy == 1, "the player composite draws unscaled vertically")
  Assert.isNil(composites[1].quad, "the player composite draws whole, never a sub-cell")
end

-- Every dynamic region resolves the snapshot values: names, levels,
-- conditions and health on both sides plus the player numeric health and
-- experience, each inside its own side bounds.
function T.hud_regions_carry_the_snapshot_values()
  local view = snapshot({
    battlers = {
      {
        combatant = 1,
        side = 1,
        hp = 13,
        maxHp = 52,
        visible = true,
        name = "MINTJR",
        level = 5,
        exp = 987,
        condition = "PSN",
        shakeDx = 0,
      },
      {
        combatant = 3,
        side = 2,
        hp = 40,
        maxHp = 57,
        visible = true,
        name = "WILDJR",
        level = 4,
        exp = nil,
        condition = nil,
        shakeDx = 0,
      },
    },
  })
  local plan = resolve(singleMeasurement(256, 192, "compact-hud-test:regions"), view)
  local content = assert(plan.content, "the compact plan carries its content")
  local function regionText(side, id)
    for _, region in ipairs(side.regions) do
      if region.id == id then
        return region.text
      end
    end
    error("the " .. id .. " region resolves", 0)
  end
  local function insideBounds(side, id)
    for _, region in ipairs(side.regions) do
      if region.id == id then
        Assert.isTrue(region.x >= side.x, id .. " starts inside its bounds")
        Assert.isTrue(region.y >= side.y, id .. " sits inside its bounds")
        Assert.isTrue(region.x + region.width <= side.x + side.width, id .. " ends inside its bounds")
        Assert.isTrue(region.y + region.height <= side.y + side.height, id .. " stays inside its bounds")
        return
      end
    end
    error("the " .. id .. " region resolves", 0)
  end
  local player = assert(content.hud.player, "the plan carries the player bounds")
  local enemy = assert(content.hud.enemy, "the plan carries the enemy bounds")
  Assert.equal(regionText(player, "name"), "MINTJR", "the player name resolves")
  Assert.equal(regionText(player, "level"), "Lv5", "the player level resolves")
  Assert.equal(regionText(player, "condition"), "PSN", "the player condition resolves")
  Assert.equal(regionText(player, "hp"), "13/52", "the player numeric health resolves")
  Assert.equal(regionText(player, "exp"), "987", "the player numeric experience resolves")
  Assert.equal(regionText(enemy, "name"), "WILDJR", "the enemy name resolves")
  Assert.equal(regionText(enemy, "level"), "Lv4", "the enemy level resolves")
  Assert.equal(regionText(enemy, "condition"), "", "a healthy combatant resolves no condition")
  Assert.equal(regionText(enemy, "hp"), "40/57", "the enemy health resolves")
  for _, id in ipairs({ "name", "level", "condition", "hp", "exp" }) do
    insideBounds(player, id)
  end
  for _, id in ipairs({ "name", "level", "condition", "hp" }) do
    insideBounds(enemy, id)
  end
end

-- Health bars keep the paired fractions and shades: full health fills the
-- bar green, quarter health fills a quarter yellow, empty health fills
-- nothing red.
function T.damaged_and_empty_bars_keep_paired_fractions_and_shades()
  local function barRects(view)
    local result = drawnHud(view, {})
    local bars = {}
    for _, rectangle in ipairs(result.graphics.rectangles) do
      if rectangle.y < 136 and rectangle.h == 4 and rectangle.w <= 48 then
        bars[#bars + 1] = rectangle
      end
    end
    return bars
  end
  local full = barRects(snapshot())
  Assert.equal(#full, 2, "both sides draw their health bar at full health")
  for _, bar in ipairs(full) do
    Assert.equal(bar.w, 48, "full health fills the whole bar")
    Assert.deepEqual(bar.color, { 0.2, 0.8, 0.2, 1 }, "full health keeps the healthy shade")
  end
  local hurt = barRects(snapshot({
    battlers = {
      { combatant = 1, side = 1, hp = 13, maxHp = 52, visible = true, name = "LEAD", level = 20, shakeDx = 0 },
      { combatant = 3, side = 2, hp = 57, maxHp = 57, visible = true, name = "FOE", level = 20, shakeDx = 0 },
    },
  }))
  Assert.equal(#hurt, 2, "both sides still draw their bar while hurt")
  local foundQuarter = false
  for _, bar in ipairs(hurt) do
    if bar.w == 12 then
      foundQuarter = true
      Assert.deepEqual(bar.color, { 0.9, 0.8, 0.2, 1 }, "quarter health keeps the warning shade")
    end
  end
  Assert.isTrue(foundQuarter, "quarter health fills a quarter of the bar")
  local empty = barRects(snapshot({
    battlers = {
      { combatant = 1, side = 1, hp = 0, maxHp = 52, visible = true, name = "LEAD", level = 20, shakeDx = 0 },
      { combatant = 3, side = 2, hp = 57, maxHp = 57, visible = true, name = "FOE", level = 20, shakeDx = 0 },
    },
  }))
  local foundEmpty = false
  for _, bar in ipairs(empty) do
    if bar.w == 0 then
      foundEmpty = true
      Assert.deepEqual(bar.color, { 0.9, 0.2, 0.2, 1 }, "empty health keeps the danger shade")
    end
  end
  Assert.isTrue(foundEmpty, "empty health fills nothing")
end

-- A hidden battler draws neither artwork nor bar: only the shown side
-- occupies the scene.
function T.hidden_battler_draws_no_artwork_or_bar()
  local view = snapshot({
    battlers = {
      { combatant = 1, side = 1, hp = 52, maxHp = 52, visible = true, name = "LEAD", level = 20, shakeDx = 0 },
      { combatant = 3, side = 2, hp = 57, maxHp = 57, visible = false, name = "FOE", level = 20, shakeDx = 0 },
    },
  })
  local result = drawnHud(view, {})
  Assert.equal(#drawsOf(result.graphics, "hud:enemy"), 0, "the hidden enemy draws no artwork")
  Assert.equal(#drawsOf(result.graphics, "hud:player"), 1, "the shown player still draws its artwork")
  local bars = 0
  for _, rectangle in ipairs(result.graphics.rectangles) do
    if rectangle.y < 136 and rectangle.h == 4 and rectangle.w <= 48 then
      bars = bars + 1
    end
  end
  Assert.equal(bars, 1, "only the shown side draws its health bar")
end

-- Missing artwork never hides actual health: without a resolvable image
-- the side still draws its bar at the anchored bounds.
function T.missing_artwork_keeps_health_bars()
  local view = snapshot()
  local result = drawnHud(view, { "hud:enemy", "hud:player" })
  Assert.equal(#drawsOf(result.graphics, "hud:enemy"), 0, "missing enemy artwork draws nothing")
  Assert.equal(#drawsOf(result.graphics, "hud:player"), 0, "missing player artwork draws nothing")
  local bars = 0
  for _, rectangle in ipairs(result.graphics.rectangles) do
    if rectangle.y < 136 and rectangle.h == 4 and rectangle.w <= 48 then
      bars = bars + 1
    end
  end
  Assert.equal(bars, 2, "both health bars still draw without their artwork")
end

-- The auxiliary arrow and ball strips stay hidden: the compact scene owns
-- exactly the scene, the two battler pictures and the two composites.
function T.arrow_and_ball_strips_stay_hidden()
  local result = drawnHud(snapshot(), {})
  local handles = {}
  for _, entry in ipairs(result.graphics.draws) do
    if type(entry.image) == "table" and type(entry.image.handle) == "string" then
      handles[#handles + 1] = entry.image.handle
    end
  end
  table.sort(handles)
  Assert.deepEqual(
    handles,
    { "hud:enemy", "hud:player", "mon:enemy:front", "mon:player:back", "scene:test" },
    "the compact scene draws only its scene, battlers and composites"
  )
end

-- Every HUD draw and bar stays inside the scene viewport under the scene
-- clip, and no HUD content reaches the dock bands.
function T.hud_draws_stay_inside_the_scene_clip()
  local result = drawnHud(snapshot(), {})
  local content = assert(result.plan.content, "the compact plan carries its content")
  local scene = assert(content.scene, "the plan carries its scene viewport")
  for _, entry in ipairs(result.graphics.draws) do
    if type(entry.image) == "table" and (entry.image.handle == "hud:enemy" or entry.image.handle == "hud:player") then
      Assert.isTrue(entry.x >= scene.x, "composites start inside the scene")
      Assert.isTrue(entry.y >= scene.y, "composites sit inside the scene")
    end
  end
  for _, rectangle in ipairs(result.graphics.rectangles) do
    if rectangle.h == 4 and rectangle.w <= 48 and rectangle.y < 136 then
      Assert.isTrue(rectangle.x >= scene.x, "bars start inside the scene")
      Assert.isTrue(rectangle.y >= scene.y, "bars sit inside the scene")
      Assert.isTrue(rectangle.x + rectangle.w <= scene.x + scene.width, "bars end inside the scene")
      Assert.isTrue(rectangle.y + rectangle.h <= scene.y + scene.height, "bars stay above the dock")
    end
  end
  local covered = false
  for _, clip in ipairs(result.graphics.scissorIntersections) do
    local request = clip.requested
    if request[1] <= 4 and request[2] <= 4 and request[1] + request[3] >= 252 and request[2] + request[4] >= 132 then
      covered = true
    end
  end
  Assert.isTrue(covered, "a scene clip covers both HUD bounds")
end

-- The paired presentation keeps its own anchors: native image centers and
-- native HUD anchors never move for the compact composition.
function T.paired_anchors_unchanged()
  local BattleRenderer = require("game.hgss.src.battle.BattleRenderer")
  Assert.equal(BattleRenderer.PLAYER_CENTER.x, 64, "the native player image center is unchanged")
  Assert.equal(BattleRenderer.PLAYER_CENTER.y, 112, "the native player image row is unchanged")
  Assert.equal(BattleRenderer.ENEMY_CENTER.x, 192, "the native enemy image center is unchanged")
  Assert.equal(BattleRenderer.ENEMY_CENTER.y, 56, "the native enemy image row is unchanged")
  Assert.equal(BattleRenderer.PLAYER_HUD.x, 192, "the native player HUD anchor is unchanged")
  Assert.equal(BattleRenderer.PLAYER_HUD.y, 116, "the native player HUD row is unchanged")
  Assert.equal(BattleRenderer.ENEMY_HUD.x, 58, "the native enemy HUD anchor is unchanged")
  Assert.equal(BattleRenderer.ENEMY_HUD.y, 36, "the native enemy HUD row is unchanged")
  local session = ApplicationPresentation.new(BattleScreenInterface.defaults(), nil)
  local dual = session:resolve({
    width = 256,
    height = 384,
    topology = ScreenTopology.dualDisplay(
      { id = "main", rect = { x = 0, y = 0, width = 256, height = 192 }, touch = false, role = "world" },
      { id = "lower", rect = { x = 0, y = 192, width = 256, height = 192 }, touch = true, role = "auxiliary" },
      "compact-hud-test:dual-native"
    ),
    pixelRatio = 1,
    signature = "compact-hud-test:dual-native",
  }, snapshot())
  Assert.equal(#dual.panes, 2, "the dual composition keeps both native panes")
  Assert.isTrue(dual.content.compact ~= true, "the paired plan carries no compact marker")
end

return { tests = T }
