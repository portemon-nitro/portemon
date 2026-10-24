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
local BattlePresentationManifestFixture = require("tests.support.BattlePresentationManifestFixture")
local MonCache = require("libs.assets.src.MonCache")
local ScreenTopology = require("libs.ui.src.ScreenTopology")

local T = {}
-- Staged HUD strips append their native component tiles after the
-- sprite characters: bar source tiles stay component-relative, so bar
-- quad origins ride the staged component base beside the icon tiles.
local COMPONENT_BASE = BattlePresentationManifestFixture.manifest().hud.player.componentBase
---@param x number recorded quad horizontal origin under inspection
---@return boolean barQuad true for the green, yellow, and red full-fill bar origins
local function isBarQuad(x)
  return x == (COMPONENT_BASE + 10) * 8 or x == (COMPONENT_BASE + 15) * 8 or x == (COMPONENT_BASE + 19) * 8
end
local function fakeArtSetFilter() end
local function fakeArtWidth()
  return 1648
end
local function fakeArtHeight()
  return 8
end

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
        portraitSelector = MonCache.portraitSelector("LEAD", 0, "male", false, "back"),
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
        portraitSelector = MonCache.portraitSelector("FOE", 0, "male", false),
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

---@return table recording text boundary behind one draw
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
  local requests = {}
  for _, key in ipairs(held or {}) do
    missing[key] = true
  end
  local manifest = BattlePresentationManifestFixture.manifest()
  local drawView = {}
  for key, value in pairs(view) do
    drawView[key] = value
  end
  drawView.hudSections = { player = manifest.hud.player, enemy = manifest.hud.enemy }
  drawView.hudPatchSpans = manifest.hud.patchSpans
  local resources = {
    graphics = graphics,
    text = text,
    windows = windows,
    assets = {
      drawable = function(_, key)
        requests[#requests + 1] = key
        if missing[key] then
          return nil
        end
        return {
          handle = key,
          setFilter = fakeArtSetFilter,
          getWidth = fakeArtWidth,
          getHeight = fakeArtHeight,
        }
      end,
    },
    frameKey = "compact-hud-test-frame",
    sceneImageKey = "scene:test",
  }
  ApplicationPresentation.draw(graphics, resources, drawView, plan)
  return { graphics = graphics, text = text, windows = windows, plan = plan, requests = requests }
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

-- The enemy composite samples its source artwork through quads at the
-- left/top anchor, never a whole strip.
function T.enemy_composite_draws_unscaled_at_left_top_bounds()
  local result = drawnHud(snapshot(), {})
  local content = assert(result.plan.content, "the compact plan carries its content")
  local bounds = assert(content.hud.enemy, "the plan carries the enemy bounds")
  Assert.equal(bounds.x, 4, "the enemy bounds keep their left anchor")
  Assert.equal(bounds.y, 4, "the enemy bounds keep their top anchor")
  local composites = {}
  for _, entry in ipairs(drawsOf(result.graphics, "hud:enemy")) do
    if type(entry.quad) == "table" and entry.quad.w == 64 and entry.quad.h == 8 then
      composites[#composites + 1] = entry
    end
  end
  Assert.equal(#composites, 16, "the enemy cell draws both native objects one scan row at a time")
  Assert.equal(composites[1].x, bounds.x + 12, "the enemy native cell stays centered in its aspect-fit bounds")
  Assert.equal(composites[1].y, bounds.y, "the enemy composite starts at the bounds top")
  Assert.equal(composites[1].sx, 0.5625, "the enemy cell preserves its source aspect ratio")
  Assert.equal(composites[1].sy, 0.5625, "the enemy cell preserves its source aspect ratio")
  Assert.notNil(
    composites[1].quad,
    "the enemy composite samples its source strip through quads, never a whole strip"
  )
end

-- The player composite samples its source artwork through quads with its
-- complete bounds right-aligned and above the dock, never a whole strip.
function T.player_composite_right_and_bottom_edges_hold_above_dock()
  local result = drawnHud(snapshot(), {})
  local content = assert(result.plan.content, "the compact plan carries its content")
  local bounds = assert(content.hud.player, "the plan carries the player bounds")
  Assert.equal(bounds.x + bounds.width, 252, "the player bounds keep their right edge")
  Assert.equal(bounds.y + bounds.height, 132, "the player bounds sit above the dock")
  local composites = {}
  for _, entry in ipairs(drawsOf(result.graphics, "hud:player")) do
    if type(entry.quad) == "table" and entry.quad.w ~= 8 then
      composites[#composites + 1] = entry
    end
  end
  Assert.equal(#composites, 16, "the player cell draws both native objects one scan row at a time")
  Assert.equal(composites[1].x, bounds.x + 4, "the player native cell is centered in its aspect-fit bounds")
  Assert.equal(composites[1].y, bounds.y, "the player composite starts at the bounds top")
  Assert.equal(composites[1].sx, 0.75, "the player cell preserves its source aspect ratio")
  Assert.equal(composites[1].sy, 0.75, "the player cell preserves its source aspect ratio")
  Assert.notNil(
    composites[1].quad,
    "the player composite samples its source strip through quads, never a whole strip"
  )
end

-- Every dynamic region resolves the snapshot values: names, levels,
-- conditions and health on both sides plus the player numeric health,
-- each inside its own side bounds. Experience draws as bar work, so the
-- experience region carries no numeric wording.
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
  Assert.equal(regionText(player, "exp"), "", "experience never prints its numeric total")
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

-- Health bars draw as native tile work with native quantization: full
-- health fills every tile from the green base, quarter health shows
-- yellow partial tiles, empty health shows fainted tiles. No painted
-- rectangles and no interim shades appear anywhere above the dock.
function T.damaged_and_empty_bars_keep_paired_fractions_and_shades()
  local function barTiles(view)
    local result = drawnHud(view, {})
    local tiles = {}
    for _, entry in ipairs(result.graphics.draws) do
      if
        type(entry.image) == "table"
        and type(entry.image.handle) == "string"
        and entry.image.handle:sub(1, 4) == "hud:"
        and type(entry.quad) == "table"
        and entry.quad.w == 8
        and entry.quad.h == 8
        and isBarQuad(entry.quad.x)
      then
        tiles[#tiles + 1] = math.floor(entry.quad.x / 8) - COMPONENT_BASE
      end
    end
    table.sort(tiles)
    return tiles, result
  end
  local function noSceneRectangles(result)
    for _, rectangle in ipairs(result.graphics.rectangles) do
      if rectangle.y < 136 then
        error("the battlefield draws no painted rectangle above the dock", 0)
      end
    end
  end
  local full, fullResult = barTiles(snapshot())
  Assert.deepEqual(
    full,
    { 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10 },
    "full health fills every tile from the green base on both sides"
  )
  noSceneRectangles(fullResult)
  local hurt, hurtResult = barTiles(snapshot({
    battlers = {
      { combatant = 1, side = 1, hp = 13, maxHp = 52, visible = true, name = "LEAD", level = 20, shakeDx = 0 },
      { combatant = 3, side = 2, hp = 57, maxHp = 57, visible = true, name = "FOE", level = 20, shakeDx = 0 },
    },
  }))
  Assert.deepEqual(
    hurt,
    { 10, 10, 10, 10, 10, 10, 15, 19 },
    "quarter health keeps its yellow partial tiles while the full side stays green"
  )
  noSceneRectangles(hurtResult)
  local empty, emptyResult = barTiles(snapshot({
    battlers = {
      { combatant = 1, side = 1, hp = 0, maxHp = 52, visible = true, name = "LEAD", level = 20, shakeDx = 0 },
      { combatant = 3, side = 2, hp = 57, maxHp = 57, visible = true, name = "FOE", level = 20, shakeDx = 0 },
    },
  }))
  Assert.deepEqual(
    empty,
    { 10, 10, 10, 10, 10, 10 },
    "empty health draws no bar tiles while the full side stays green"
  )
  noSceneRectangles(emptyResult)
end

-- A hidden battler draws neither artwork nor bar tiles: only the shown
-- side occupies the scene.
function T.hidden_battler_draws_no_artwork_or_bar()
  local view = snapshot({
    battlers = {
      { combatant = 1, side = 1, hp = 52, maxHp = 52, visible = true, name = "LEAD", level = 20, shakeDx = 0 },
      { combatant = 3, side = 2, hp = 57, maxHp = 57, visible = false, name = "FOE", level = 20, shakeDx = 0 },
    },
  })
  local result = drawnHud(view, {})
  Assert.equal(#drawsOf(result.graphics, "hud:enemy"), 0, "the hidden enemy draws no artwork")
  local composites, tiles = 0, 0
  for _, entry in ipairs(drawsOf(result.graphics, "hud:player")) do
    if type(entry.quad) == "table" and entry.quad.w == 8 and entry.quad.h == 8 then
      if isBarQuad(entry.quad.x) then
        tiles = tiles + 1
      end
    else
      composites = composites + 1
    end
  end
  Assert.equal(composites, 16, "the shown player still draws its native cell objects")
  Assert.equal(tiles, 6, "only the shown side draws its health tiles")
end

-- Missing artwork draws no bar tiles: health tiles sample the staged
-- strip, so without a resolvable image the side keeps its wording but
-- no tiles. A missing strip draws nothing, never a substitute.
function T.missing_artwork_draws_no_bar_tiles()
  local view = snapshot()
  local result = drawnHud(view, { "hud:enemy", "hud:player" })
  Assert.equal(#drawsOf(result.graphics, "hud:enemy"), 0, "missing enemy artwork draws nothing")
  Assert.equal(#drawsOf(result.graphics, "hud:player"), 0, "missing player artwork draws nothing")
  local drawn = {}
  for _, entry in ipairs(result.text.draws) do
    drawn[entry.content] = (drawn[entry.content] or 0) + 1
  end
  Assert.equal(drawn["LEAD"], 1, "the player name still draws without its artwork")
  Assert.equal(drawn["FOE"], 1, "the enemy name still draws without its artwork")
end

-- The auxiliary arrow and ball strips stay hidden: the compact scene owns
-- exactly the scene, the two battler pictures, the two sampled HUD
-- composites and their bar tiles.
function T.arrow_and_ball_strips_stay_hidden()
  local result = drawnHud(snapshot(), {})
  local handles = {}
  for _, entry in ipairs(result.graphics.draws) do
    if type(entry.image) == "table" and type(entry.image.handle) == "string" then
      handles[#handles + 1] = entry.image.handle
    end
  end
  table.sort(handles)
  local foeKey = "mon:" .. MonCache.portraitSelector("FOE", 0, "male", false)
  local leadKey = "mon:" .. MonCache.portraitSelector("LEAD", 0, "male", false, "back")
  for _, handle in ipairs(handles) do
    Assert.isTrue(
      handle == "scene:test" or handle == foeKey or handle == leadKey or handle == "hud:enemy" or handle == "hud:player",
      "the compact scene uses only its scene, battlers and native HUD cells"
    )
  end
  for _, entry in ipairs(result.graphics.draws) do
    local handle = type(entry.image) == "table" and entry.image.handle or ""
    Assert.isTrue(
      tostring(handle):sub(1, 6) ~= "arrow:",
      "the compact scene never paints the arrow strip"
    )
  end
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

---@return table internal semantic snapshot with two live leads and two live foes
local function doubledSnapshot(overrides)
  local view = snapshot({
    mode = "command",
    battlers = {
      {
        combatant = 1,
        side = 1,
        position = 1,
        activation = 11,
        hp = 40,
        maxHp = 40,
        visible = true,
        name = "LEFTY",
        level = 8,
        exp = 8000,
        condition = nil,
        portraitSelector = MonCache.portraitSelector("STARLY", 0, "male", false, "back"),
        shakeDx = 0,
      },
      {
        combatant = 2,
        side = 1,
        position = 2,
        activation = 12,
        hp = 35,
        maxHp = 38,
        visible = true,
        name = "RIGHTY",
        level = 9,
        exp = 8100,
        condition = nil,
        portraitSelector = MonCache.portraitSelector("SHINX", 0, "male", false, "back"),
        shakeDx = 0,
      },
      {
        combatant = 3,
        side = 2,
        position = 3,
        activation = 13,
        hp = 45,
        maxHp = 45,
        visible = true,
        name = "FOE-A",
        level = 4,
        exp = nil,
        condition = nil,
        portraitSelector = MonCache.portraitSelector("BIDOOF", 0, "male", false),
        shakeDx = 0,
      },
      {
        combatant = 4,
        side = 2,
        position = 4,
        activation = 14,
        hp = 30,
        maxHp = 33,
        visible = true,
        name = "FOE-B",
        level = 5,
        exp = nil,
        condition = nil,
        portraitSelector = MonCache.portraitSelector("PICHU", 0, "male", false),
        shakeDx = 0,
      },
    },
  })
  if overrides ~= nil then
    for key, value in pairs(overrides) do
      view[key] = value
    end
  end
  return view
end

---@param hud table plan hud content under inspection
---@return table[] anchored HUD boxes in top-to-bottom, left-to-right order
local function hudBoxes(hud)
  local boxes = {}
  local function visit(node)
    if type(node) ~= "table" then
      return
    end
    if
      type(node.x) == "number"
      and type(node.y) == "number"
      and type(node.width) == "number"
      and type(node.height) == "number"
    then
      if type(node.regions) == "table" then
        boxes[#boxes + 1] = node
      end
      return
    end
    for _, child in pairs(node) do
      visit(child)
    end
  end
  visit(hud)
  table.sort(boxes, function(a, b)
    if a.y ~= b.y then
      return a.y < b.y
    end
    return a.x < b.x
  end)
  return boxes
end

---@param drawn table graphics, text and plan behind one draw under inspection
---@return table[] health bars inside the scene viewport
local function sceneBars(drawn)
  local bars = {}
  for _, rectangle in ipairs(drawn.graphics.rectangles) do
    if rectangle.y < 136 and rectangle.h == 4 and rectangle.w <= 48 then
      bars[#bars + 1] = rectangle
    end
  end
  return bars
end

-- Both partners on each side draw their own portrait, HUD box and
-- wording inside the scene without touching the dock, and a wound
-- moves exactly one bar plus its own health wording.
function T.both_partners_draw_their_own_portrait_and_health_above_the_dock()
  local view = doubledSnapshot()
  local plan = resolve(singleMeasurement(256, 192, "compact-hud-test:doubles"), view)
  local content = assert(plan.content, "the compact plan carries its content")
  local boxes = hudBoxes(assert(content.hud, "the plan carries its hud"))
  Assert.equal(#boxes, 4, "both partners on both sides own a HUD box")
  for _, box in ipairs(boxes) do
    Assert.isTrue(box.x >= 0 and box.y >= 0, "every HUD box starts inside the scene")
    Assert.isTrue(box.x + box.width <= 256, "every HUD box ends inside the scene width")
    Assert.isTrue(box.y + box.height <= 136, "every HUD box stays above the dock")
  end
  for index = 1, #boxes do
    for other = index + 1, #boxes do
      local a = boxes[index]
      local b = boxes[other]
      local apart = a.x + a.width <= b.x or b.x + b.width <= a.x or a.y + a.height <= b.y or b.y + b.height <= a.y
      Assert.isTrue(apart, "partner HUD boxes never overlap")
    end
  end
  local result = drawnHud(view, {})
  local portraits = {
    "mon:" .. MonCache.portraitSelector("STARLY", 0, "male", false, "back"),
    "mon:" .. MonCache.portraitSelector("SHINX", 0, "male", false, "back"),
    "mon:" .. MonCache.portraitSelector("BIDOOF", 0, "male", false),
    "mon:" .. MonCache.portraitSelector("PICHU", 0, "male", false),
  }
  for _, key in ipairs(portraits) do
    Assert.equal(#drawsOf(result.graphics, key), 1, "each partner portrait draws exactly once")
  end
  Assert.equal(#sceneBars(result), 4, "all four partners draw their health bar")
  local expected = {}
  for _, box in ipairs(boxes) do
    for _, region in ipairs(box.regions) do
      if type(region.text) == "string" and region.text ~= "" then
        expected[#expected + 1] = region
      end
    end
  end
  Assert.isTrue(#expected >= 8, "four boxes publish their names and health")
  for _, region in ipairs(expected) do
    local found = 0
    for _, drawn in ipairs(result.text.draws) do
      if drawn.content == region.text and drawn.x == region.x and drawn.y == region.y then
        found = found + 1
      end
    end
    Assert.equal(found, 1, "the " .. region.id .. " wording draws once at its published origin")
  end
  local hurtView = doubledSnapshot()
  hurtView.battlers[4].hp = 17
  local hurtResult = drawnHud(hurtView, {})
  Assert.equal(#sceneBars(hurtResult), 4, "the wounded side still draws all four bars")
  local function widths(drawn)
    local out = {}
    for _, bar in ipairs(sceneBars(drawn)) do
      out[#out + 1] = bar.w
    end
    table.sort(out)
    return out
  end
  local full = widths(result)
  local hurt = widths(hurtResult)
  local kept = 0
  local dropped = nil
  local remaining = {}
  for _, width in ipairs(hurt) do
    remaining[#remaining + 1] = width
  end
  for _, width in ipairs(full) do
    local at = nil
    for index, value in ipairs(remaining) do
      if value == width then
        at = index
        break
      end
    end
    if at ~= nil then
      kept = kept + 1
      table.remove(remaining, at)
    else
      dropped = width
    end
  end
  Assert.equal(kept, 3, "three health bars keep their exact width")
  Assert.equal(#remaining, 1, "the wound resolves to one new width")
  Assert.isTrue(remaining[1] < (dropped or 49), "the wounded bar shrinks")
  local hurtWords = {}
  for _, drawn in ipairs(hurtResult.text.draws) do
    hurtWords[drawn.content] = (hurtWords[drawn.content] or 0) + 1
  end
  Assert.equal(hurtWords["17/33"], 1, "the wounded foe resolves its exact health wording")
  Assert.equal(hurtWords["45/45"], 1, "the partner foe keeps its health wording")
end

-- Compact doubles panels are authored with the current theme and local
-- graphics, while source HUD strips are never requested as finished art.
function T.doubles_panels_compose_fields_without_raw_hud_art()
  local view = doubledSnapshot()
  local result = drawnHud(view, {})
  local boxes = hudBoxes(assert(result.plan.content.hud, "the plan carries its hud"))
  Assert.equal(#boxes, 4, "four authored panels resolve")
  local insets = require("libs.hgss.src.ui.FieldDialogueTheme").applicationFrameInsets()
  local panelFrames = {}
  for _, frame in ipairs(result.windows.frames) do
    if frame.box.y < 120 then
      panelFrames[#panelFrames + 1] = frame
    end
  end
  Assert.equal(#panelFrames, 4, "each authored panel has an outline")
  for index, box in ipairs(boxes) do
    local frame = panelFrames[index].box
    Assert.deepEqual({ frame.x, frame.y, frame.width, frame.height }, {
      box.x + insets.left,
      box.y + insets.top + 1,
      120 - insets.left - insets.right,
      40 - insets.top - insets.bottom - 2,
    }, "the themed panel outline uses its authored bounds")
    local fill = false
    for _, rectangle in ipairs(result.graphics.rectangles) do
      if
        rectangle.mode == "fill"
        and rectangle.x == box.x
        and rectangle.y == box.y
        and rectangle.w == 120
        and rectangle.h == 40
      then
        fill = true
      end
    end
    Assert.isTrue(fill, "panel backgrounds fill only their authored bounds")
  end
  for _, key in ipairs(result.requests) do
    Assert.isTrue(key:sub(1, 4) ~= "hud:", "compact doubles never requests packed HUD art")
  end
  for _, draw in ipairs(result.graphics.draws) do
    local handle = type(draw.image) == "table" and draw.image.handle or ""
    Assert.isTrue(tostring(handle):sub(1, 4) ~= "hud:", "compact doubles never paints packed HUD art")
  end
  local expected = { "LEFTY", "Lv8", "RIGHTY", "Lv9", "FOE-A", "Lv4", "FOE-B", "Lv5" }
  local drawn = {}
  for _, entry in ipairs(result.text.draws) do
    drawn[entry.content] = (drawn[entry.content] or 0) + 1
  end
  for _, wording in ipairs(expected) do
    Assert.equal(drawn[wording], 1, wording .. " is drawn once in its own panel")
  end
  local bars = sceneBars(result)
  Assert.equal(#bars, 4, "each panel has its own health bar")
  local widths = {}
  for _, bar in ipairs(bars) do
    widths[bar.x .. ":" .. bar.y] = bar.w
  end
  Assert.equal(widths[8 .. ":" .. 115], 48, "the full-health ally keeps a full bar")
  Assert.equal(widths[8 .. ":" .. 35], 48, "the full-health foe keeps a full bar")
  Assert.equal(widths[136 .. ":" .. 115], 48 * (35 / 38), "the second ally keeps its own fraction")
  Assert.equal(widths[136 .. ":" .. 35], 48 * (30 / 33), "the second foe keeps its own fraction")
end

-- Doubles portraits use presentation-only half scale and recoil remains
-- clipped to each allocated picture cell at its maximum displacement.
function T.doubles_portraits_draw_half_scale_inside_their_cells()
  local view = doubledSnapshot()
  for _, battler in ipairs(view.battlers) do
    battler.shakeDx = 2
  end
  local result = drawnHud(view, {})
  local expected = {
    [1] = { x = 72, y = 40 },
    [2] = { x = 200, y = 40 },
    [3] = { x = 24, y = 40 },
    [4] = { x = 152, y = 40 },
  }
  local found = {}
  for _, entry in ipairs(result.graphics.draws) do
    local handle = type(entry.image) == "table" and entry.image.handle or ""
    if type(handle) == "string" and handle:sub(1, 4) == "mon:" then
      local positionByHandle = {
        ["mon:" .. MonCache.portraitSelector("STARLY", 0, "male", false, "back")] = 1,
        ["mon:" .. MonCache.portraitSelector("SHINX", 0, "male", false, "back")] = 2,
        ["mon:" .. MonCache.portraitSelector("BIDOOF", 0, "male", false)] = 3,
        ["mon:" .. MonCache.portraitSelector("PICHU", 0, "male", false)] = 4,
      }
      local position = assert(positionByHandle[handle], "each source portrait has its own slot")
      local cell = expected[position]
      Assert.equal(entry.x, cell.x + 1, "two recoil pixels move the half-scale portrait one screen pixel")
      Assert.equal(entry.y, cell.y, "the half-scale portrait keeps its vertical origin")
      Assert.equal(entry.sx, 0.5, "each compact doubles picture scales horizontally by one half")
      Assert.equal(entry.sy, 0.5, "each compact doubles picture scales vertically by one half")
      found[position] = true
    end
  end
  Assert.equal(#result.graphics.draws, 5, "the scene and four source portraits draw without substitute art")
  for position, cell in pairs(expected) do
    Assert.isTrue(found[position] == true, "position " .. position .. " has its distinct portrait")
    local clipped = false
    for _, intersection in ipairs(result.graphics.scissorIntersections) do
      local rect = intersection.requested
      if rect[1] == cell.x and rect[2] == cell.y and rect[3] == 40 and rect[4] == 40 then
        clipped = true
      end
    end
    Assert.isTrue(clipped, "position " .. position .. " recoil stays clipped to its 40x40 picture cell")
  end
end

-- Long dynamic fields pass through the live measurement adapter and
-- keep their glyph widths inside the finite field regions.
function T.doubles_panel_text_is_measured_to_each_field_width()
  local view = doubledSnapshot()
  view.battlers[1].name = string.rep("LONGNAME", 8)
  view.battlers[1].condition = string.rep("STATUS", 4)
  view.battlers[1].hp = 123456789
  view.battlers[1].maxHp = 987654321
  local result = drawnHud(view, {})
  for _, box in ipairs(hudBoxes(assert(result.plan.content.hud))) do
    for _, region in ipairs(box.regions) do
      if type(region.text) == "string" and region.text ~= "" then
        local matching = nil
        for _, draw in ipairs(result.text.draws) do
          if draw.x == region.x and draw.y == region.y then
            matching = draw
            break
          end
        end
        Assert.notNil(matching, "the " .. region.id .. " field is still visible")
        Assert.isTrue(
          result.text.measure(matching.content).width <= region.width,
          "the " .. region.id .. " glyphs fit their panel-local width"
        )
      end
    end
  end
end

-- The doubled compact pane keeps every control reachable: the command
-- cells still claim Fight, both foe target rows map to their own
-- candidate, and a below-1x host keeps integer mapping.
function T.doubled_compact_pane_keeps_every_control_reachable()
  local view = doubledSnapshot()
  local plan = resolve(singleMeasurement(256, 192, "compact-hud-test:doubles-controls"), view)
  local content = assert(plan.content, "the compact plan carries its content")
  Assert.deepEqual(
    { content.dock.x, content.dock.y, content.dock.width, content.dock.height },
    { 0, 136, 256, 56 },
    "the command dock keeps its documented bounds"
  )
  local fight = nil
  for _, cell in ipairs(assert(content.commands, "the plan carries its commands").cells) do
    if cell.id == "fight" then
      fight = cell
    end
  end
  Assert.notNil(fight, "the Fight cell resolves")
  local pressed =
    plan.mapInput({ type = "pointer_down", pointerId = "touch:0", x = fight.x + 2, y = fight.y + 2 }, view, plan)
  Assert.notNil(pressed, "the Fight cell claims its control")
  Assert.equal(pressed.control.id, "fight", "the Fight cell keeps its identity")
  local tiny = resolve(singleMeasurement(200, 150, "compact-hud-test:doubles-tiny"), view)
  local placement = assert(tiny.panes[1], "the tiny pane resolves").placement
  Assert.equal(placement.scale, 1, "a below-1x host keeps integer mapping")
  local aimed = doubledSnapshot({
    mode = "target",
    targetCandidates = {
      { id = "foe:3", position = 3, enabled = true, name = "FOE-A", level = 4 },
      { id = "foe:4", position = 4, enabled = true, name = "FOE-B", level = 5 },
    },
  })
  local aiming = resolve(singleMeasurement(256, 192, "compact-hud-test:doubles-target"), aimed)
  local aimingContent = assert(aiming.content, "the target plan carries its content")
  local wanted = { ["foe:3"] = true, ["foe:4"] = true }
  local foeRows = {}
  for _, row in ipairs(assert(aimingContent.targetRows, "the target plan carries its rows")) do
    if wanted[row.id] then
      foeRows[#foeRows + 1] = row
    end
  end
  Assert.equal(#foeRows, 2, "both foe slots stay choosable")
  for _, row in ipairs(foeRows) do
    local hit =
      aiming.mapInput({ type = "pointer_down", pointerId = "touch:1", x = row.x + 2, y = row.y + 2 }, aimed, aiming)
    Assert.notNil(hit, "the " .. row.id .. " row claims its control")
    Assert.equal(hit.control.id, row.id, "the target row keeps its candidate identity")
  end
end

-- A doubles transition keeps every survivor on its cell while a
-- partner hides: portraits never reindex onto the hidden slot, and
-- the hidden slot keeps its HUD box with no live owner to paint.
function T.hidden_transition_slots_keep_their_doubles_cells()
  local full = drawnHud(doubledSnapshot(), {})
  local gapped = doubledSnapshot()
  for _, battler in ipairs(gapped.battlers) do
    if battler.combatant == 4 then
      battler.visible = false
    end
  end
  local partial = drawnHud(gapped, {})
  local function origins(drawn)
    local found = {}
    for _, entry in ipairs(drawn.graphics.draws) do
      if type(entry.image) == "table" and type(entry.image.handle) == "string" then
        local handle = entry.image.handle --[[@as string]]
        if handle:sub(1, 4) == "mon:" then
          Assert.isNil(found[handle], "the " .. handle .. " picture draws exactly once")
          found[handle] = tostring(entry.x) .. ":" .. tostring(entry.y)
        end
      end
    end
    return found
  end
  local before, after = origins(full), origins(partial)
  local survivors = 0
  for handle, origin in pairs(before) do
    if after[handle] ~= nil then
      survivors = survivors + 1
      Assert.equal(after[handle], origin, "the " .. handle .. " survivor keeps its cell mid-transition")
    end
  end
  Assert.equal(survivors, 3, "three survivors keep drawing while one partner hides")
  local content = assert(partial.plan.content, "the compact plan carries its content")
  local boxes = hudBoxes(assert(content.hud, "the plan carries its hud"))
  Assert.equal(#boxes, 4, "the hidden slot keeps its HUD box with no live owner")
end

-- A single-side view draws identically whether or not its records
-- carry native slots: singles keep their documented anchors.
function T.single_sides_draw_identically_with_or_without_native_slots()
  local plain = snapshot()
  local slotted = snapshot()
  slotted.battlers[1].position = 1
  slotted.battlers[1].activation = 11
  slotted.battlers[2].position = 3
  slotted.battlers[2].activation = 13
  local first = drawnHud(plain, {})
  local second = drawnHud(slotted, {})
  Assert.deepEqual(second.graphics.draws, first.graphics.draws, "native slots never move single-side pictures")
  Assert.deepEqual(second.graphics.rectangles, first.graphics.rectangles, "native slots never move single-side bars")
  Assert.deepEqual(second.text.draws, first.text.draws, "native slots never move single-side wording")
end

return { tests = T }
