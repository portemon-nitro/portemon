-- Source-configured sprite ownership at the interpreter-to-task seam: the
-- opcode-78 instruction map must reach the spawned configured-sprite body
-- unchanged, the body alone stages its decoded cell/animation/palette/texture
-- leases, authored NANR frames select NCER objects that publish real transient
-- pictures through the existing scene/renderer path, and cancellation
-- releases every owned record without touching the persistent battler scene.
-- Synthetic normalized cell/animation fixtures mirror the shared decoder
-- record shapes; no ROM bytes.

local Assert = require("tests.support.Assert")
local BattlePresentationFlow = require("game.hgss.src.battle.BattlePresentationFlow")
local BattleScene = require("libs.hgss.src.presentation.BattleScene")
local ManifestFixture = require("tests.support.BattlePresentationManifestFixture")

local T = {}

-- BattleAnimSpriteFunc_MoveSpriteAndAnimate: the configured body with the
-- smallest machine, used here to prove the shared staging, frame walk, and
-- transient picture publication.
local TASK_KIND = "sprite-offset-animate"
local TASK_CONTEXT = "battle-sprite"

-- The solo-enemy battler picture center the configured slots stage through.
-- Every expected center below adds the authored object offset and the
-- centering rule (x + floor(w/2), y + band * 8 + 4) to it.
local DEFENDER_ANCHOR = { x = 192, y = 50 }

local CHARACTER_KEY = "probe-sprite-character"
local PALETTE_KEY = "probe-sprite-palette"
local CELL_KEY = "probe-sprite-cell"
local ANIMATION_KEY = "probe-sprite-animation"

local function flatPalette()
  local colors = {}
  for _ = 1, 16 do
    colors[#colors + 1] = { r = 8, g = 16, b = 24 }
  end
  return colors
end

local function cellObject(overrides)
  local obj = {
    x = 0,
    y = 0,
    tile = 0,
    flipH = false,
    flipV = false,
    palette = 0,
    shape = 0,
    size = 0,
    width = 8,
    height = 8,
    affine = false,
    disabled = false,
    objMode = "normal",
    mosaic = false,
    colorMode = "16-color",
    priority = 0,
  }
  for key, value in pairs(overrides or {}) do
    obj[key] = value
  end
  return obj
end

local function twoCellFixture()
  return {
    cells = {
      {
        objs = {
          cellObject({ x = 4, y = 6, tile = 0, width = 16, height = 8, priority = 1 }),
          cellObject({ x = 32, y = 16, tile = 2, width = 8, height = 8, priority = 0, flipH = true }),
        },
      },
      {
        objs = {
          cellObject({ x = 8, y = 8, tile = 8, width = 8, height = 16, priority = 0 }),
          cellObject({ x = 0, y = 0, tile = 0, width = 8, height = 8, disabled = true }),
        },
      },
    },
  }
end

local function frame(cell, duration)
  return {
    cell = cell,
    duration = duration,
    element = "cell",
    translateX = 0,
    translateY = 0,
    scaleX = 1,
    scaleY = 1,
    rotation = 0,
  }
end

local function twoFrameFixture()
  return {
    anims = {
      {
        frames = { frame(0, 2), frame(1, 3) },
        playMode = "forward",
        loopStartFrameIdx = 0,
      },
    },
  }
end

local function stripBytes(width, height)
  local parts = {}
  for _ = 1, width * height do
    parts[#parts + 1] = string.char(200, 40, 40, 255)
  end
  return table.concat(parts)
end

local function leaseStore(overrides)
  local store = {
    [CHARACTER_KEY] = {
      key = CHARACTER_KEY,
      kind = "texture",
      width = 128,
      height = 8,
      rgba8888 = stripBytes(128, 8),
      handle = { sprite = "strip-handle" },
    },
    [PALETTE_KEY] = {
      key = PALETTE_KEY,
      kind = "palette",
      payloadPath = "probe/sprite-palette.lua",
      data = { colors = flatPalette() },
    },
    [CELL_KEY] = {
      key = CELL_KEY,
      kind = "cells",
      payloadPath = "probe/sprite-cell.lua",
      data = twoCellFixture(),
    },
    [ANIMATION_KEY] = {
      key = ANIMATION_KEY,
      kind = "animation",
      payloadPath = "probe/sprite-animation.lua",
      data = twoFrameFixture(),
    },
  }
  for key, value in pairs(overrides or {}) do
    store[key] = value
  end
  return store
end

local function journalResources(journal, store)
  local resources = {}
  function resources.resolve(key)
    journal.acquired[#journal.acquired + 1] = key
    local lease = store[key]
    assert(lease ~= nil, "staged resource is missing for key " .. tostring(key))
    return lease
  end
  function resources.release(lease)
    local key = type(lease) == "table" and lease.key or lease
    journal.released[#journal.released + 1] = key
  end
  return resources
end

local function sceneWithPair()
  local scene = BattleScene.new()
  scene:observe({
    { combatant = 1, activation = 1, visible = true },
    { combatant = 3, activation = 3, visible = true },
  })
  return scene
end

local function controllableAudio()
  local audio = { played = {} }
  function audio.play(name)
    audio.played[#audio.played + 1] = name
  end
  function audio.stop(_name) end
  function audio.isFinished(_name)
    return true
  end
  return audio
end

local function configuredProgram()
  return {
    key = "probe-configured-sprite",
    entry = "main",
    instructions = {
      {
        op = "create-configured-sprite",
        taskKind = TASK_KIND,
        taskContext = TASK_CONTEXT,
        parameters = { offsetX = 0, offsetY = 0 },
        resourceKeys = {
          character = CHARACTER_KEY,
          palette = PALETTE_KEY,
          cell = CELL_KEY,
          animation = ANIMATION_KEY,
        },
      },
      { op = "wait-for-battler-effects", cursorRule = "advance-when-effects-finish" },
    },
    subprograms = {},
    taskKinds = { TASK_KIND },
  }
end

local function topologyPlayback(key)
  local views = {
    own = { { combatant = 1, activation = 1, side = 1, position = 1 } },
    foes = { { combatant = 3, activation = 3, side = 2, position = 2 } },
  }
  local packet = {
    launchId = "configured-sprite-probe",
    packetId = 1,
    before = views,
    after = views,
  }
  local event = {
    sequence = 1,
    kind = "struck",
    cause = { kind = "move", key = key },
    actionId = 1,
    hitIndex = 1,
    actors = { { combatant = 1, activation = 1 } },
    targets = { { combatant = 3, activation = 3 } },
    move = { selected = key, executed = key, phase = "direct" },
    payload = { target = 3, hitIndex = 1, damage = 1, calculated = 1 },
    visualSeed = 4242,
    presentation = {
      context = {},
      execution = {
        selectedMove = key,
        executedMove = key,
        moment = "use",
        branch = "default",
        attacker = { combatant = 1, activation = 1 },
        defender = { combatant = 3, activation = 3 },
        targets = { { combatant = 3, activation = 3 } },
        damage = -1,
        power = 0,
        friendship = 0,
        hitOrdinal = 1,
        hitCount = 1,
        hitCycle = 1,
      },
    },
  }
  local geometry = ManifestFixture.manifest().battlefield.slots
  local requests = BattlePresentationFlow.animationPlayback(packet, event, geometry)
  local request = assert(requests[1], "the selector publishes its frozen request")
  Assert.equal(request.disposition, "admit", "the connected probe hit admits its request")
  return {
    launchId = packet.launchId,
    packetId = packet.packetId,
    event = event,
    visualSeed = event.visualSeed,
    topology = request.playback.topology,
    context = request.playback.context,
  }
end

local function playerWith(scene, journal, store)
  local Player = require("libs.hgss.src.presentation.BattleAnimationPlayer")
  local Factory = require("libs.hgss.src.presentation.BattleEffectTasks")
  return assert(Player.new({
    scene = scene,
    audio = controllableAudio(),
    resources = journalResources(journal, store),
    tasks = Factory,
    services = { onNativeFrame = function() end },
  }))
end

local function runUntil(player, handle, wants, limit)
  for _ = 1, limit or 60 do
    local status = player:status(handle)
    if status == wants or status == "failed" then
      return status
    end
    player:stepSourceTick({ tick = 1 })
  end
  return player:status(handle)
end

local function acquiredCounts(journal)
  local counts = {}
  for _, key in ipairs(journal.acquired) do
    counts[key] = (counts[key] or 0) + 1
  end
  return counts
end

local function assertBalanced(journal, what)
  local acquired = acquiredCounts(journal)
  local released = {}
  for _, key in ipairs(journal.released) do
    released[key] = (released[key] or 0) + 1
  end
  for key, count in pairs(acquired) do
    Assert.equal(released[key] or 0, count, what .. " returns its lease exactly once: " .. key)
  end
  for key in pairs(released) do
    Assert.notNil(acquired[key], what .. " never releases what it did not acquire: " .. key)
  end
end

local function pictureByAsset(views)
  local found = {}
  for _, view in ipairs(views) do
    if view.picture ~= nil then
      found[#found + 1] = view.picture
    end
  end
  return found
end

function T.configured_sprite_instruction_stages_each_owned_role_once_and_cancels_cleanly()
  local scene = sceneWithPair()
  local journal = { acquired = {}, released = {} }
  local player = playerWith(scene, journal, leaseStore())
  local handle = assert(player:start(topologyPlayback("probe-configured-sprite"), configuredProgram()))
  player:stepSourceTick({ tick = 1 })
  local counts = acquiredCounts(journal)
  player:stepSourceTick({ tick = 1 })
  for _, key in ipairs({ CHARACTER_KEY, PALETTE_KEY, CELL_KEY, ANIMATION_KEY }) do
    Assert.equal(counts[key], 1, "the spawned body stages its owned role once: " .. key)
  end
  Assert.isTrue(#scene:effectViews() > 0, "the first tick publishes staged sprite geometry")
  Assert.equal(runUntil(player, handle, "complete"), "complete", "the configured sprite run completes")
  Assert.equal(#scene:effectViews(), 0, "completion releases every transient record")
  assertBalanced(journal, "the configured sprite run")

  local cancelledHandle = assert(player:start(topologyPlayback("probe-configured-sprite"), configuredProgram()))
  player:stepSourceTick({ tick = 1 })
  player:stepSourceTick({ tick = 1 })
  Assert.isTrue(#scene:effectViews() > 0, "the running body owns transient records")
  player:cancel(cancelledHandle, "superseded")
  Assert.equal(player:status(cancelledHandle), "cancelled", "cancellation lands on cancelled")
  Assert.equal(#scene:effectViews(), 0, "cancellation releases every transient record")
  assertBalanced(journal, "the cancelled run")
  player:dispose()
end

function T.authored_frames_draw_distinct_geometry_and_carry_the_picture_seam()
  local scene = sceneWithPair()
  local journal = { acquired = {}, released = {} }
  local player = playerWith(scene, journal, leaseStore())
  local handle = assert(player:start(topologyPlayback("probe-configured-sprite"), configuredProgram()))
  player:stepSourceTick({ tick = 1 })
  player:stepSourceTick({ tick = 1 })
  local firstFrame = pictureByAsset(scene:effectViews())
  Assert.equal(#firstFrame, 2, "frame 0 publishes both enabled objects")
  for index, picture in ipairs(firstFrame) do
    local what = "picture " .. index
    Assert.equal(picture.selector:find("/cell-0/", 1, true) ~= nil, true, what .. " paints the first authored cell")
    Assert.equal(picture.assetKey, CHARACTER_KEY, what .. " carries its staged drawable key")
    Assert.isTrue(type(picture.centerX) == "number", what .. " carries native X")
    Assert.isTrue(type(picture.zCenter) == "number", what .. " carries native depth")
    Assert.isTrue(picture.xOffset2 ~= nil or picture.yOffset2 ~= nil, what .. " crops its viewport")
  end
  player:stepSourceTick({ tick = 1 })
  local secondFrame = pictureByAsset(scene:effectViews())
  Assert.isTrue(#secondFrame > 0, "frame 1 publishes its enabled object bands")
  for _, picture in ipairs(secondFrame) do
    Assert.isTrue(picture.selector:find("/cell-1/", 1, true) ~= nil, "the second authored cell paints")
    Assert.isTrue(picture.selector:find("/obj-2/", 1, true) == nil, "the disabled cell object never publishes")
  end
  Assert.isTrue(
    secondFrame[1].centerX ~= firstFrame[1].centerX or secondFrame[1].centerY ~= firstFrame[1].centerY,
    "the authored cells draw distinct geometry"
  )
  Assert.equal(runUntil(player, handle, "complete"), "complete", "the walk retires at its authored boundary")
  Assert.equal(#scene:effectViews(), 0, "retirement releases every transient record")
  assertBalanced(journal, "the two-frame run")
  player:dispose()
end

function T.zero_duration_frames_skip_without_invented_timing()
  local scene = sceneWithPair()
  local journal = { acquired = {}, released = {} }
  local store = leaseStore()
  store[ANIMATION_KEY] = {
    key = ANIMATION_KEY,
    kind = "animation",
    payloadPath = "probe/sprite-animation.lua",
    data = { anims = { { frames = { frame(0, 0), frame(1, 2) }, playMode = "forward", loopStartFrameIdx = 0 } } },
  }
  local player = playerWith(scene, journal, store)
  local handle = assert(player:start(topologyPlayback("probe-configured-sprite"), configuredProgram()))
  player:stepSourceTick({ tick = 1 })
  player:stepSourceTick({ tick = 1 })
  local pictures = pictureByAsset(scene:effectViews())
  Assert.isTrue(#pictures > 0, "the steady walk publishes after skipping the zero frame")
  Assert.equal(
    pictures[1].centerX,
    DEFENDER_ANCHOR.x + 8 + 4,
    "the zero-duration frame never paints: the second cell shows first"
  )
  Assert.equal(runUntil(player, handle, "complete"), "complete", "the walk retires at the authored nonzero boundary")
  assertBalanced(journal, "the zero-skipping run")
  player:dispose()
end

function T.unsupported_cells_fail_closed_without_publishing()
  local cases = {
    {
      what = "an unknown authored cell",
      store = function()
        local store = leaseStore()
        store[ANIMATION_KEY] = {
          key = ANIMATION_KEY,
          kind = "animation",
          payloadPath = "probe/sprite-animation.lua",
          data = { anims = { { frames = { frame(9, 2) }, playMode = "forward", loopStartFrameIdx = 0 } } },
        }
        return store
      end,
    },
    {
      what = "an enabled affine cell object",
      store = function()
        local store = leaseStore()
        local cells = twoCellFixture()
        cells.cells[1].objs[1].affine = true
        store[CELL_KEY] = { key = CELL_KEY, kind = "cells", payloadPath = "probe/sprite-cell.lua", data = cells }
        return store
      end,
    },
  }
  for _, case in ipairs(cases) do
    local scene = sceneWithPair()
    local journal = { acquired = {}, released = {} }
    local player = playerWith(scene, journal, case.store())
    local handle = assert(player:start(topologyPlayback("probe-configured-sprite"), configuredProgram()))
    Assert.equal(runUntil(player, handle, "complete"), "failed", case.what .. " fails the occurrence")
    local failure = player:failure(handle)
    local reason = tostring((type(failure) == "table" and failure.reason) or failure)
    Assert.isTrue(reason:find(TASK_KIND, 1, true) ~= nil, case.what .. " names its task kind: " .. reason)
    Assert.equal(#scene:effectViews(), 0, case.what .. " publishes no substitute picture")
    assertBalanced(journal, case.what)
    player:dispose()
  end
end

return { tests = T }
