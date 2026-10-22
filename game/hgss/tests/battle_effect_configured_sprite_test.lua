-- Source-configured sprite ownership at the interpreter-to-task seam:
-- the opcode-78 instruction map must reach the spawned task unchanged,
-- the task alone stages its decoded cell/animation/palette/texture
-- leases, authored NANR frames select NCER objects that publish real
-- transient pictures through the existing scene/renderer path, and
-- cancellation releases every owned record without touching the
-- persistent battler scene. Synthetic normalized cell/animation
-- fixtures mirror the shared decoder record shapes; no ROM bytes.

local Assert = require("tests.support.Assert")
local BattlePresentationFlow = require("game.hgss.src.battle.BattlePresentationFlow")
local BattleScene = require("libs.hgss.src.presentation.BattleScene")
local ManifestFixture = require("tests.support.BattlePresentationManifestFixture")

local T = {}

local TASK_KIND = "sprite-animation-position-transition"
local TASK_CONTEXT = "battle-sprite"

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

local function twoFrameFixture()
  return {
    anims = {
      {
        frames = {
          {
            cell = 0,
            duration = 2,
            element = "cell",
            translateX = 0,
            translateY = 0,
            scaleX = 1,
            scaleY = 1,
            rotation = 0,
          },
          {
            cell = 1,
            duration = 3,
            element = "cell",
            translateX = 0,
            translateY = 0,
            scaleX = 1,
            scaleY = 1,
            rotation = 0,
          },
        },
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
      kind = "cell",
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
        parameters = {},
        resourceKeys = {
          character = CHARACTER_KEY,
          palette = PALETTE_KEY,
          cell = CELL_KEY,
          animation = ANIMATION_KEY,
        },
      },
      -- The native effects wait holds the occurrence on its raw sprite
      -- task exactly like a staged source program does.
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
    actionId = 1,
    hitIndex = 1,
    effectKey = key,
    actors = { { combatant = 1, activation = 1 } },
    targets = { { combatant = 3, activation = 3 } },
    visualSeed = 4242,
  }
  local geometry = ManifestFixture.manifest().battlefield.slots
  local playback = BattlePresentationFlow.animationPlayback(packet, event, geometry)
  Assert.equal(playback.launchId, "configured-sprite-probe", "the playback input carries its launch identity")
  return playback
end

local function playerWith(scene, journal, store)
  local Player = require("libs.hgss.src.presentation.BattleAnimationPlayer")
  local Factory = require("libs.hgss.src.presentation.BattleEffectTasks")
  return assert(Player.new({
    scene = scene,
    audio = controllableAudio(),
    resources = journalResources(journal, store),
    tasks = Factory,
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

-- The opcode-78 role map reaches the spawned task with no key lost and
-- no hidden second owner: each role is acquired exactly once and
-- returned exactly once, and the first tick already shows staged
-- sprite geometry instead of an imageless generic run.
function T.configured_sprite_instruction_stages_each_owned_role_exactly_once()
  local scene = sceneWithPair()
  local journal = { acquired = {}, released = {} }
  local player = playerWith(scene, journal, leaseStore())
  local handle = assert(player:start(topologyPlayback("probe-configured-sprite"), configuredProgram()))
  player:stepSourceTick({ tick = 1 })
  local counts = acquiredCounts(journal)
  for _, key in ipairs({ CHARACTER_KEY, PALETTE_KEY, CELL_KEY, ANIMATION_KEY }) do
    Assert.equal(counts[key], 1, "the spawned task stages its owned role once: " .. key)
  end
  local total = 0
  for _ in pairs(counts) do
    total = total + 1
  end
  Assert.equal(total, 4, "no hidden second owner stages a duplicate lease")
  player:stepSourceTick({ tick = 1 })
  Assert.isTrue(#scene:effectViews() > 0, "the first tick publishes staged sprite geometry")
  Assert.equal(runUntil(player, handle, "complete"), "complete", "the configured sprite run completes")
  Assert.equal(#scene:effectViews(), 0, "completion releases every transient record")
  assertBalanced(journal, "the configured sprite run")
  player:dispose()
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

-- Two authored frames draw distinct staged geometry at their source
-- boundary and retire to an empty draw list: frame 0 shows both
-- enabled objects with native offsets, flips, and depths, frame 1
-- shows the second cell while the disabled object never publishes.
function T.cell_animation_frames_draw_distinct_geometry_then_retire()
  local scene = sceneWithPair()
  local journal = { acquired = {}, released = {} }
  local player = playerWith(scene, journal, leaseStore())
  local handle = assert(player:start(topologyPlayback("probe-configured-sprite"), configuredProgram()))
  player:stepSourceTick({ tick = 1 })
  player:stepSourceTick({ tick = 1 })
  local first = pictureByAsset(scene:effectViews())
  Assert.equal(#first, 2, "frame 0 publishes exactly its two enabled objects")
  Assert.equal(first[1].assetKey, CHARACTER_KEY, "pictures draw from the staged texture role")
  Assert.equal(first[1].centerX, 68, "the first object centers on the attacker anchor plus its native x")
  Assert.equal(first[1].centerY, 86, "the first object centers on the attacker anchor plus its native y")
  Assert.equal(first[1].width, 16, "the first object keeps its native width")
  Assert.equal(first[1].height, 8, "the first object keeps its native height")
  Assert.equal(first[1].xOffset2, 0, "the first band crops at its staged tile origin")
  Assert.equal(first[1].yOffset2, 0, "bands crop from the single staged strip row")
  Assert.equal(first[1].zCenter, -1, "lower native priority rests further back")
  Assert.equal(first[2].centerX, 96, "the second object keeps its own native offset")
  Assert.equal(first[2].flipH, true, "the authored horizontal flip is carried, not ignored")
  Assert.equal(first[2].zCenter, 0, "the top native priority draws nearest")
  player:stepSourceTick({ tick = 1 })
  local held = pictureByAsset(scene:effectViews())
  Assert.equal(#held, 2, "frame 0 holds through its authored two-tick duration")
  player:stepSourceTick({ tick = 1 })
  local second = pictureByAsset(scene:effectViews())
  Assert.equal(#second, 2, "frame 1 publishes one object over two strip bands")
  Assert.equal(second[1].centerX, 72, "frame 1 centers on the attacker anchor plus its native offset")
  Assert.equal(second[1].centerY, 88, "frame 1 keeps its native y on the first band")
  Assert.equal(second[1].xOffset2, 64, "the first band crops at the staged tile origin")
  Assert.equal(second[2].centerY, 96, "the second band steps one object row down")
  Assert.equal(second[2].xOffset2, 72, "the second band crops at the next staged tile")
  Assert.equal(second[2].height, 8, "bands keep the staged strip row height")
  Assert.equal(runUntil(player, handle, "complete"), "complete", "the run retires at its authored five-tick boundary")
  Assert.equal(#scene:effectViews(), 0, "no transient picture survives retirement")
  assertBalanced(journal, "the frame run")
  player:dispose()
end

-- Cancelling after the first frame releases both owned object records
-- and every staged lease while the persistent battler scene is
-- untouched; repeated cancel and dispose stay silent.
function T.multi_object_cell_cancels_without_touching_persistent_scene()
  local scene = sceneWithPair()
  local journal = { acquired = {}, released = {} }
  local player = playerWith(scene, journal, leaseStore())
  local handle = assert(player:start(topologyPlayback("probe-configured-sprite"), configuredProgram()))
  player:stepSourceTick({ tick = 1 })
  player:stepSourceTick({ tick = 1 })
  Assert.equal(#pictureByAsset(scene:effectViews()), 2, "both authored objects paint before cancellation")
  player:cancel(handle, "superseded")
  Assert.equal(player:status(handle), "cancelled", "the sprite run lands on cancelled")
  Assert.equal(#scene:effectViews(), 0, "cancellation releases every owned object record")
  assertBalanced(journal, "the cancelled run")
  Assert.isNil(
    scene:pictureState({ combatant = 3, activation = 3 }),
    "cancelling one side never patches the other battler"
  )
  local scroll = scene:scroll()
  Assert.equal(scroll.x, 0, "cancellation never moves the viewport")
  Assert.equal(scroll.y, 0, "cancellation never moves the viewport vertically")
  player:cancel(handle, "repeated")
  player:dispose()
  player:dispose()
  player:stepSourceTick({ tick = 9 })
  Assert.equal(player:status(handle), "cancelled", "the disposed run never advances again")
  Assert.equal(#scene:effectViews(), 0, "late teardown publishes nothing")
  assertBalanced(journal, "the late teardown")
end

-- A frame naming a cell the normalized record does not carry fails the
-- occurrence with kind and key provenance instead of drawing a
-- substitute or retiring as a silent success.
function T.unknown_cell_reference_fails_closed()
  local scene = sceneWithPair()
  local journal = { acquired = {}, released = {} }
  local store = leaseStore()
  store[ANIMATION_KEY] = {
    key = ANIMATION_KEY,
    kind = "animation",
    payloadPath = "probe/sprite-animation.lua",
    data = {
      anims = {
        {
          frames = {
            {
              cell = 9,
              duration = 2,
              element = "cell",
              translateX = 0,
              translateY = 0,
              scaleX = 1,
              scaleY = 1,
              rotation = 0,
            },
          },
          playMode = "forward",
          loopStartFrameIdx = 0,
        },
      },
    },
  }
  local player = playerWith(scene, journal, store)
  local handle = assert(player:start(topologyPlayback("probe-configured-sprite"), configuredProgram()))
  Assert.equal(runUntil(player, handle, "complete"), "failed", "the unknown cell fails the occurrence")
  local failure = player:failure(handle)
  Assert.notNil(failure, "the failure carries its diagnosis")
  local reason = tostring((type(failure) == "table" and failure.reason) or failure)
  Assert.isTrue(reason:find(TASK_KIND, 1, true) ~= nil, "the failure names its task kind: " .. reason)
  Assert.equal(#scene:effectViews(), 0, "the rejected run publishes no substitute picture")
  assertBalanced(journal, "the rejected run")
  player:dispose()
end

-- Source affine objects have no picture-pass support in this lane, so
-- an enabled affine object fails closed at construction instead of
-- drawing an unrotated stand-in.
function T.affine_cell_objects_fail_closed()
  local scene = sceneWithPair()
  local journal = { acquired = {}, released = {} }
  local store = leaseStore()
  local cells = twoCellFixture()
  cells.cells[1].objs[1].affine = true
  store[CELL_KEY] = { key = CELL_KEY, kind = "cell", payloadPath = "probe/sprite-cell.lua", data = cells }
  local player = playerWith(scene, journal, store)
  local handle = assert(player:start(topologyPlayback("probe-configured-sprite"), configuredProgram()))
  Assert.equal(runUntil(player, handle, "complete"), "failed", "the affine object fails the occurrence")
  Assert.equal(#scene:effectViews(), 0, "the rejected run publishes no unrotated stand-in")
  assertBalanced(journal, "the affine rejection")
  player:dispose()
end

-- Zero-duration frames are skipped in the steady walk without
-- inventing a fixed budget: a leading authored zero never paints, and
-- an all-zero animation shows its first frame for exactly one tick.
function T.zero_duration_frames_skip_without_invented_timing()
  local scene = sceneWithPair()
  local journal = { acquired = {}, released = {} }
  local store = leaseStore()
  store[ANIMATION_KEY] = {
    key = ANIMATION_KEY,
    kind = "animation",
    payloadPath = "probe/sprite-animation.lua",
    data = {
      anims = {
        {
          frames = {
            {
              cell = 0,
              duration = 0,
              element = "cell",
              translateX = 0,
              translateY = 0,
              scaleX = 1,
              scaleY = 1,
              rotation = 0,
            },
            {
              cell = 1,
              duration = 2,
              element = "cell",
              translateX = 0,
              translateY = 0,
              scaleX = 1,
              scaleY = 1,
              rotation = 0,
            },
          },
          playMode = "forward",
          loopStartFrameIdx = 0,
        },
      },
    },
  }
  local player = playerWith(scene, journal, store)
  local handle = assert(player:start(topologyPlayback("probe-configured-sprite"), configuredProgram()))
  player:stepSourceTick({ tick = 1 })
  player:stepSourceTick({ tick = 1 })
  local pictures = pictureByAsset(scene:effectViews())
  Assert.isTrue(#pictures > 0, "the steady walk still publishes after skipping the zero frame")
  Assert.equal(pictures[1].centerX, 72, "the zero-duration frame never paints: the second cell shows first")
  player:stepSourceTick({ tick = 1 })
  Assert.equal(runUntil(player, handle, "complete"), "complete", "the walk retires at the authored nonzero boundary")
  assertBalanced(journal, "the zero-skipping run")
  player:dispose()
  local flatScene = sceneWithPair()
  local flatJournal = { acquired = {}, released = {} }
  local flatStore = leaseStore()
  flatStore[ANIMATION_KEY] = {
    key = ANIMATION_KEY,
    kind = "animation",
    payloadPath = "probe/sprite-animation.lua",
    data = {
      anims = {
        {
          frames = {
            {
              cell = 0,
              duration = 0,
              element = "cell",
              translateX = 0,
              translateY = 0,
              scaleX = 1,
              scaleY = 1,
              rotation = 0,
            },
          },
          playMode = "forward",
          loopStartFrameIdx = 0,
        },
      },
    },
  }
  local flatPlayer = playerWith(flatScene, flatJournal, flatStore)
  local flatHandle = assert(flatPlayer:start(topologyPlayback("probe-configured-sprite"), configuredProgram()))
  flatPlayer:stepSourceTick({ tick = 1 })
  flatPlayer:stepSourceTick({ tick = 1 })
  Assert.equal(
    runUntil(flatPlayer, flatHandle, "complete"),
    "complete",
    "the all-zero animation retires on its first task tick"
  )
  Assert.equal(#flatScene:effectViews(), 0, "retirement releases the single shown frame")
  assertBalanced(flatJournal, "the all-zero run")
  flatPlayer:dispose()
end

-- The staged sprite pictures travel through the production renderer:
-- asset key, native geometry, crop origin, flip, and depth all reach
-- the picture layer instead of stalling at the scene boundary.
function T.staged_sprite_pictures_reach_the_production_renderer()
  local BattleRenderer = require("game.hgss.src.battle.BattleRenderer")
  local FakeGraphics = require("tests.support.FakeGraphics")
  local scene = sceneWithPair()
  local journal = { acquired = {}, released = {} }
  local player = playerWith(scene, journal, leaseStore())
  local handle = assert(player:start(topologyPlayback("probe-configured-sprite"), configuredProgram()))
  player:stepSourceTick({ tick = 1 })
  player:stepSourceTick({ tick = 1 })
  local submitted = nil
  local assets = {
    handles = { [CHARACTER_KEY] = { image = CHARACTER_KEY } },
  }
  function assets.drawable(_self, key)
    return assets.handles[key]
  end
  function assets.renderPictures(_self, _graphics, pictures)
    submitted = pictures
    return { layer = "probe-layer" }
  end
  local graphics = FakeGraphics.new()
  BattleRenderer.drawPane({
    graphics = graphics,
    text = {},
    windows = {},
    assets = assets,
    frameKey = "default",
    sceneImageKey = "scene:probe",
  }, {
    battlers = {},
    effectInstances = scene:effectViews(),
    hudPatchSpans = {},
    hudSections = {},
  }, "detail", {})
  Assert.notNil(submitted, "the effect pictures submit to the picture layer")
  assert(submitted ~= nil, "the submission stays available")
  Assert.equal(#submitted, 2, "both authored objects submit")
  Assert.equal(submitted[1].centerX, 68, "native geometry survives to the picture layer")
  Assert.equal(submitted[1].xOffset2, 0, "the crop origin survives to the picture layer")
  Assert.equal(submitted[2].flipH, true, "the authored flip survives to the picture layer")
  Assert.isTrue(submitted[1].pictureVisible, "sprite crops mark their picture-layer crop")
  Assert.equal(#graphics.draws >= 1, true, "the composed layer draws")
  player:dispose()
end

return { tests = T }
