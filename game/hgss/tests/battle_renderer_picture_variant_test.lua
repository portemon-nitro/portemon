-- Renderer ownership for managed battler-sprite copies and the
-- ChangeBattlerPic picture variant: a bound copy resolves the
-- creation-time portrait selector's first frame instead of the live
-- battler texture, so later frame, palette, selector, or visibility
-- mutations move only the source-defined follow transform; and the
-- attacker layout selector mirrors the picture for the opposite-facing
-- mode while the restore returns the base. All fixtures are synthetic
-- with recording doubles; the real battle renderer carries the drawing.

local Assert = require("tests.support.Assert")
local BattleRenderer = require("game.hgss.src.battle.BattleRenderer")
local CompositionFrameDrain = require("tests.support.CompositionFrameDrain")
local FakeGraphics = require("tests.support.FakeGraphics")
local ManifestFixture = require("tests.support.BattlePresentationManifestFixture")

local T = {}

local FROZEN_SELECTOR = "LEAD/0/male/plain/back"
local OTHER_SELECTOR = "FOE/9/male/plain/front"

local function stagedDrawable(key)
  local image = { handle = key, width = 80, height = 80 }
  function image:getWidth()
    return image.width
  end
  function image:getHeight()
    return image.height
  end
  function image:getDimensions()
    return image.width, image.height
  end
  function image:setFilter() end
  return image
end

---@param handle string staged image identity behind the frozen frame
---@return table<string, unknown> indexed portrait cell behind the frame
local function portraitCell(handle)
  return stagedDrawable(handle)
end

---@param overrides table? battler fields replacing the healthy defaults
---@return table displayed battler facts for renderer draws
local function battler(overrides)
  local record = {
    combatant = 1,
    activation = 1,
    side = 1,
    hp = 30,
    maxHp = 30,
    visible = true,
    active = true,
    name = "LEAD",
    level = 9,
    portraitSelector = FROZEN_SELECTOR,
    pictureFrame = 0,
    sourceHeight = 0,
    shakeDx = 0,
    shadowSize = 1,
  }
  if overrides ~= nil then
    for key, value in pairs(overrides) do
      record[key] = value
    end
  end
  return record
end

local function foeBattler()
  return battler({
    combatant = 2,
    activation = 2,
    side = 2,
    name = "FOE",
    portraitSelector = "FOE/0/male/plain/front",
  })
end

---@param section table<string, unknown> staged HUD section behind cell sourcing
---@param y integer cell row behind the probe vectors
---@return table<string, unknown> sourced HUD section with one looping cell
local function sourceCell(section, y)
  section.cells = {
    {
      objs = {
        {
          x = -64,
          y = y,
          tile = 0,
          width = 64,
          height = 64,
          palette = 0,
          priority = 0,
          affine = false,
          flipH = false,
          flipV = false,
          disabled = false,
          objMode = "normal",
          mosaic = false,
          colorMode = "16-color",
        },
        {
          x = 0,
          y = y,
          tile = 64,
          width = 64,
          height = 64,
          palette = 0,
          priority = 0,
          affine = false,
          flipH = false,
          flipV = false,
          disabled = false,
          objMode = "normal",
          mosaic = false,
          colorMode = "16-color",
        },
      },
    },
  }
  section.animation = { playMode = "forward_loop", loopStartFrameIdx = 0, frames = { { cell = 0, duration = 0 } } }
  return section
end

---@param battlers table<string, unknown>[] displayed battlers behind the draw
---@param effectInstances table<string, unknown>[] transient effect instances behind the draw
---@return table internal semantic snapshot for renderer draws
local function snapshot(battlers, effectInstances)
  local manifest = ManifestFixture.manifest()
  local doubles = {
    playerLeft = sourceCell(manifest.hud.doubles.playerLeft, -32),
    playerRight = sourceCell(manifest.hud.doubles.playerRight, -32),
    enemyLeft = sourceCell(manifest.hud.doubles.enemyLeft, -28),
    enemyRight = sourceCell(manifest.hud.doubles.enemyRight, -28),
  }
  return {
    slotGeometry = manifest.battlefield.slots,
    hudSections = {
      player = sourceCell(manifest.hud.player, -32),
      enemy = sourceCell(manifest.hud.enemy, -28),
      doubles = doubles,
    },
    hudPatchSpans = manifest.hud.patchSpans,
    textPalettes = {
      narration = manifest.messages.roles.narration.palette,
      hud = manifest.messages.roles.hud.palette,
      menu = manifest.messages.roles.menu.palette,
    },
    menuText = { pp = "PP", cancel = "CANCEL" },
    mode = "command",
    selection = "fight",
    armed = nil,
    requestId = 7,
    message = "",
    battlers = battlers,
    commands = {},
    moves = {},
    partyRoster = {},
    foeCount = 1,
    arrowFrame = 0,
    effectInstances = effectInstances,
    childIntent = nil,
  }
end

---@param graphics table fake drawing API
---@param opts table? test image records behind the draw
---@return fun(self: table, drawGraphics: table, frame: table): table picture-layer handle
local function pictureRenderer(graphics, opts)
  return function(_, drawGraphics, frame)
    local primitives = assert(frame.primitives, "production renders its typed composition frame")
    graphics.pictureItems = primitives
    if opts ~= nil then
      opts.pictureItems = primitives
    end
    CompositionFrameDrain.drain(drawGraphics, frame)
    for _, primitive in ipairs(primitives) do
      local handle = primitive.image or primitive.material
      local image = type(handle) == "table" and (handle.image or handle) or handle
      drawGraphics.draw(image, nil, 0, 0)
    end
    return { handle = "picture-depth-layer" }
  end
end

---@param view table internal semantic snapshot under drawing
---@param opts table? frame overrides and recorded output
---@return table graphics behind one detail draw
local function drawnDetail(view, opts)
  opts = opts or {}
  local graphics = FakeGraphics.new({})
  local frozenFrames = opts.frozenFrames
  local resources = {
    graphics = graphics,
    text = { drawText = function() end, measure = function()
      return { width = 0, height = 0 }
    end },
    windows = {
      background = { 0, 0, 0, 1 },
      drawWindow = function() end,
      drawApplicationFrame = function() end,
    },
    doublesHud = {},
    assets = {
      drawable = function(_, key)
        if key == "mon:" .. FROZEN_SELECTOR and frozenFrames ~= nil then
          return { frames = frozenFrames }
        end
        return stagedDrawable(key)
      end,
      background = function()
        return { handle = "composed-bg3" }
      end,
      shadowRegion = function(_, size)
        return { size = size, x = 0, y = size * 16, width = 64, height = 16 }
      end,
      release = function(_, _) end,
    },
    frameKey = "composition-frame",
    sceneImageKey = "scene:test",
  }
  resources.assets.renderPictures = pictureRenderer(graphics, opts)
  BattleRenderer.drawPane(resources, view, "detail", {})
  return graphics
end

---@param items table<string, unknown>[] composed frame primitives under filtering
---@return table<string, unknown>[] battler picture primitives in submission order
local function battlerPictures(items)
  local found = {}
  for _, primitive in ipairs(items or {}) do
    if primitive.kind == "picture" then
      found[#found + 1] = primitive
    end
  end
  return found
end

---@param items table<string, unknown>[] composed frame primitives under filtering
---@param handle string staged image identity under matching
---@return table<string, unknown>[] battler pictures sampling the staged image
local function picturesOf(items, handle)
  local found = {}
  for _, primitive in ipairs(battlerPictures(items)) do
    local image = primitive.image
    local staged = type(image) == "table" and (image.image or image) or image
    if type(staged) == "table" and staged.handle == handle then
      found[#found + 1] = primitive
    end
  end
  return found
end

---@param activation table<string, unknown> source activation behind the slot
---@param follow boolean source follow flag behind the slot
---@return table<string, unknown> bound battler-sprite slot instance
local function copyInstance(activation, follow)
  return {
    picture = {
      spriteSlot = 0,
      battlerActivation = { combatant = activation.combatant, activation = activation.activation },
      follow = follow,
      sourceChar = string.rep("c", 3200),
      sourcePalette = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 },
      frozenSelector = FROZEN_SELECTOR,
    },
  }
end

function T.bound_copies_resolve_the_frozen_first_frame()
  local frozenFrames = { portraitCell("frozen-frame-0"), portraitCell("frozen-frame-1") }
  local player = battler({ activation = 1 })
  local view = snapshot({ player, foeBattler() }, { copyInstance(player, true) })
  local graphics = drawnDetail(view, { frozenFrames = frozenFrames })
  Assert.equal(#picturesOf(graphics.pictureItems, "frozen-frame-0"), 2, "live and copy share the frozen first frame")
end

function T.bound_copies_ignore_later_live_mutations_but_follow_the_transform()
  local frozenFrames = { portraitCell("frozen-frame-0"), portraitCell("frozen-frame-1") }
  local player = battler({ activation = 1 })
  local view = snapshot({ player, foeBattler() }, { copyInstance(player, true) })
  local before = drawnDetail(view, { frozenFrames = frozenFrames })
  local baseCenterX = picturesOf(before.pictureItems, "frozen-frame-0")[1].centerX
  -- The live battler changes frame, portrait, tint, and position: the
  -- copy keeps the frozen first frame while its center follows live.
  player.portraitSelector = OTHER_SELECTOR
  player.pictureFrame = 1
  player.pictureTint = { r = 0, g = 0, b = 0, a = 1 }
  player.entryDx = 12
  local graphics = drawnDetail(view, { frozenFrames = frozenFrames })
  local copies = picturesOf(graphics.pictureItems, "frozen-frame-0")
  Assert.equal(#copies, 1, "exactly the copy keeps the frozen first frame")
  local live = picturesOf(graphics.pictureItems, "mon:" .. OTHER_SELECTOR)
  Assert.equal(#live, 1, "the live battler moves to its new portrait")
  Assert.equal(
    copies[1].centerX,
    live[1].centerX,
    "the follow-mode copy centers on the live transform"
  )
  Assert.equal(
    copies[1].centerX,
    baseCenterX + 12,
    "the follow-mode copy moves its snapshot with the live entry shift"
  )
end

function T.bound_copies_survive_live_visibility_changes()
  local frozenFrames = { portraitCell("frozen-frame-0"), portraitCell("frozen-frame-1") }
  local player = battler({ activation = 1 })
  local view = snapshot({ player, foeBattler() }, { copyInstance(player, true) })
  player.visible = false
  local graphics = drawnDetail(view, { frozenFrames = frozenFrames })
  Assert.equal(#picturesOf(graphics.pictureItems, "frozen-frame-0"), 1, "the hidden live battler keeps its copy")
end

function T.opposite_facing_layout_mirrors_the_attacker_picture()
  local frozenFrames = { portraitCell("frozen-frame-0"), portraitCell("frozen-frame-1") }
  local view = snapshot({ battler({ activation = 1 }), foeBattler() }, {})
  local base = drawnDetail(view, { frozenFrames = frozenFrames })
  local basePicture = picturesOf(base.pictureItems, "frozen-frame-0")[1]
  Assert.notNil(basePicture, "the base attacker picture submits")
  view.battlers[1].layoutMode = 3
  local mirrored = drawnDetail(view, { frozenFrames = frozenFrames })
  local flipped = picturesOf(mirrored.pictureItems, "frozen-frame-0")[1]
  Assert.notNil(flipped, "the opposite-facing picture submits")
  local function uPair(primitive)
    return { primitive.vertices[1].u, primitive.vertices[2].u }
  end
  local before, after = uPair(basePicture), uPair(flipped)
  Assert.isTrue(before[1] ~= after[1] and before[2] ~= after[2], "the layout mirrors the sampled texels")
  Assert.equal(after[1], before[2], "the mirror swaps the horizontal window")
  Assert.equal(after[2], before[1], "the mirror swaps the horizontal window")
  -- The restore drops the selector back to the base picture.
  view.battlers[1].layoutMode = nil
  local restored = drawnDetail(view, { frozenFrames = frozenFrames })
  local plain = picturesOf(restored.pictureItems, "frozen-frame-0")[1]
  Assert.deepEqual(uPair(plain), before, "the restore returns the base sampling")
end

function T.other_layout_modes_reload_the_same_facing_mon()
  -- Native ChangeBattlerPic falls through to the same-facing load for
  -- any mode outside 2 and 3; only mode 3 mirrors.
  local frozenFrames = { portraitCell("frozen-frame-0"), portraitCell("frozen-frame-1") }
  local view = snapshot({ battler({ activation = 1, layoutMode = 7 }), foeBattler() }, {})
  local graphics = drawnDetail(view, { frozenFrames = frozenFrames })
  local picture = picturesOf(graphics.pictureItems, "frozen-frame-0")[1]
  Assert.notNil(picture, "an out-of-range mode still submits the base picture")
  Assert.equal(picture.vertices[1].u, 0, "an out-of-range mode keeps the base sampling")
  Assert.equal(picture.vertices[2].u, 1, "an out-of-range mode keeps the base sampling")
  view.battlers[1].layoutMode = 2
  local doll = drawnDetail(view, { frozenFrames = frozenFrames })
  local same = picturesOf(doll.pictureItems, "frozen-frame-0")[1]
  Assert.notNil(same, "the substitute mode without a substitute flag keeps the base picture")
end

return { tests = T }
