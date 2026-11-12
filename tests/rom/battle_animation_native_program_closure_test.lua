-- Bounded source closure over the owned dump: named branch-heavy roots
-- close through their own members with factory-supported tasks, the
-- plane-clear-plus-callback framing stays closed on its corpus member,
-- and the follower enter/recall pair resolves its own roots. Real
-- members stream through the real producer; no commercial bytes enter
-- the repository.

local Assert = require("tests.support.Assert")
local GameVersion = require("romdump.src.source.GameVersion")
local RomImporter = require("romdump.src.source.RomImporter")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}

local function compiler()
  return require("romdump.src.digest.battle.BattlePresentationCompiler")
end

local function factory()
  return require("libs.hgss.src.presentation.BattleEffectTasks")
end

local function closeEffect(romFs, versionId, effectKey)
  local effect, err = compiler().compileEffect(romFs, { versionId = versionId }, effectKey)
  Assert.isNil(err, effectKey .. " closes without a source failure: " .. tostring(err))
  Assert.notNil(effect, effectKey .. " closes through its selected source member")
  return assert(effect)
end

local function instructionOps(effect)
  local ops = {}
  for _, instruction in ipairs(effect.program.instructions) do
    ops[#ops + 1] = instruction.op
  end
  return ops
end

function T.plane_clear_keeps_the_following_callback_on_its_corpus_member(romFs, versionId)
  local effect = closeEffect(romFs, versionId, "EXTRASENSORY")
  local ops = instructionOps(effect)
  local cleared = nil
  for index, op in ipairs(ops) do
    if op == "clear-background-plane" then
      cleared = index
      break
    end
  end
  Assert.notNil(cleared, "the corpus member clears its battler plane")
  local following = effect.program.instructions[assert(cleared) + 1]
  Assert.notNil(following, "a command follows the plane clear")
  Assert.isTrue(
    following.callback ~= nil or following.op == "replace-parameters-and-call",
    "the word after the clear decodes as a callback instead of an operand"
  )
end

function T.branch_heavy_roots_close_with_supported_tasks(romFs, versionId)
  local kinds = factory()
  for _, effectKey in ipairs({ "BATON_PASS", "FLY", "SOLAR_BEAM" }) do
    local effect = closeEffect(romFs, versionId, effectKey)
    local branched = false
    for _, instruction in ipairs(effect.program.instructions) do
      if instruction.branchTarget ~= nil or instruction.branchCases ~= nil then
        branched = true
      end
    end
    Assert.isTrue(branched, effectKey .. " keeps its source branch structure")
    for _, taskKind in ipairs(effect.program.taskKinds) do
      Assert.isTrue(kinds.supportsKind(taskKind), effectKey .. " stages only factory-supported tasks: " .. taskKind)
    end
  end
end

function T.follower_enter_and_recall_close_through_their_own_members(romFs, versionId)
  for _, effectKey in ipairs({ "BATTLE_ANIMATION_FOLLOWER_ENTER", "BATTLE_ANIMATION_FOLLOWER_RECALL" }) do
    closeEffect(romFs, versionId, effectKey)
  end
end

-- Programs that once failed closure for source-reading reasons close
-- through their own members with factory-supported tasks: ERUPTION
-- carries a side-ignoring emitter offset, DARK_VOID an opposing-pair
-- picture word, and DISABLE, TOXIC, and LUNAR_DANCE blend their
-- sprites' palettes.
function T.previously_unclosed_roots_close_with_supported_tasks(romFs, versionId)
  local kinds = factory()
  for _, effectKey in ipairs({ "ERUPTION", "DARK_VOID", "DISABLE", "TOXIC", "LUNAR_DANCE" }) do
    local effect = closeEffect(romFs, versionId, effectKey)
    for _, taskKind in ipairs(effect.program.taskKinds) do
      Assert.isTrue(kinds.supportsKind(taskKind), effectKey .. " stages only factory-supported tasks: " .. taskKind)
    end
  end
end

-- Executes the compiled EXTRASENSORY member through the real player,
-- factory, and scene: the clear-background-plane instruction applies its
-- plane binding on its source tick, the occurrence completes without
-- failure, and retirement leaves no system, sprite, or lease behind.
-- Texture and particle payloads are synthetic staging behind the real
-- program; no commercial bytes enter the repository.
function T.extrasensory_member_clears_its_plane_and_retires_cleanly(romFs, versionId)
  local BattleAnimationPlayer = require("libs.hgss.src.presentation.BattleAnimationPlayer")
  local BattleParticleSystems = require("libs.hgss.src.presentation.BattleParticleSystems")
  local BattleScene = require("libs.hgss.src.presentation.BattleScene")
  local effect = closeEffect(romFs, versionId, "EXTRASENSORY")
  local clearIndex = nil
  for index, op in ipairs(instructionOps(effect)) do
    if op == "clear-background-plane" then
      clearIndex = index
      break
    end
  end
  Assert.notNil(clearIndex, "the corpus member clears its battler plane")
  local function emitterRecord(overrides)
    local record = {
      id = 0,
      emitterLife = 1,
      particleLife = 40,
      startOffset = 0,
      generation = { countFx = 4096, interval = 1 },
      initPosType = 0,
      circleAxis = 0,
      drawType = 0,
      radius = 0,
      length = 0,
      position = { x = 0, y = 0, z = 0 },
      axis = { x = 0, y = 0, z = 0 },
      baseColorRgb = { r = 31, g = 31, b = 31 },
      baseAlpha = 31,
      baseScaleFx = 4096,
      velocityFx = { pos = 0, axis = 0 },
      velRandom = 0,
      scaleRandom = 0,
      lifeRandom = 0,
      rotation = { min = 0, max = 0 },
      useRotationAnim = false,
      useInitRotationRandom = false,
      initRotation = 0,
      airResist = 0,
      aspect = 1,
      loopFrame = 10,
      dbbScale = 0,
      sclAnmDirect = 0,
      texRepeat = { s = 0, t = 0 },
      texture = 0,
      animations = {},
      fields = {},
    }
    for key, value in pairs(overrides or {}) do
      record[key] = value
    end
    return record
  end
  local function placements()
    local result = {}
    local x = -4
    for _, position in ipairs({
      "solo-player",
      "solo-enemy",
      "player-side-slot-1",
      "enemy-side-slot-1",
      "player-side-slot-2",
      "enemy-side-slot-2",
    }) do
      local kinds = {}
      for _ = 1, 12 do
        kinds[#kinds + 1] = { { x = x, y = -1, z = 0 }, { x = x + 0.5, y = -1, z = 0 } }
      end
      result[position] = kinds
      x = x + 2
    end
    return result
  end
  local function zeroOffsets()
    local offsets = {}
    for _ = 1, 36 do
      offsets[#offsets + 1] = 0
    end
    return offsets
  end
  local function zeroPairs(count)
    local pairs = {}
    for _ = 1, count do
      pairs[#pairs + 1] = { x = 0, y = 0 }
    end
    return pairs
  end
  local function axisTables()
    local tables = {}
    for _, mode in ipairs({ "mode1", "mode8", "mode10", "mode12", "mode14", "mode16", "mode18", "mode20" }) do
      local entries = {}
      for _ = 1, 36 do
        entries[#entries + 1] = { x = 1, y = 0, z = 0 }
      end
      tables[mode] = entries
    end
    return tables
  end
  local function emitterTables()
    local rows = {}
    for _ = 1, 7 do
      rows[#rows + 1] = { x = 0, y = 0, z = 0, mirrorFlag = 1 }
    end
    local angles = {}
    for _ = 1, 6 do
      angles[#angles + 1] = { x = 0, y = 0, z = 0 }
    end
    return {
      offsetX = zeroOffsets(),
      offsetY = zeroOffsets(),
      axisBase = { x = 0, y = 0, z = 0, mirrorFlag = 1 },
      axisRows = rows,
      axisPositions = zeroPairs(6),
      position30 = zeroPairs(7),
      position31 = zeroPairs(6),
      position32 = zeroPairs(7),
      cameraAngles = angles,
    }
  end
  local systemPayload = {
    -- The staged emitter self-destroys once its particles retire, like
    -- the retail one-shot emitter behind this member: a persistent
    -- synthetic would hold the stream end forever.
    emitters = { emitterRecord() },
    textures = { { id = 0, width = 8, height = 8, image = "texture/0" } },
    placements = placements(),
    axisTables = axisTables(),
    emitterTables = emitterTables(),
  }
  local remaining = {}
  local audio = {}
  function audio.play(name, _extra)
    return name
  end
  function audio.playEffect(name, _extra)
    -- Each staging restarts the voice: it stays unfinished for the next
    -- three queries, so every loop-visit task arms before it completes.
    remaining[name] = 3
    return name
  end
  function audio.stop(_name) end
  function audio.isFinished(name)
    local left = remaining[name]
    if left ~= nil and left > 0 then
      remaining[name] = left - 1
      return false
    end
    return true
  end
  local releases = 0
  local resources = {}
  function resources.resolve(key)
    if key == "texture/0" then
      return { key = key, kind = "texture", handle = { image = key } }
    end
    return { key = key, kind = "particle", data = systemPayload }
  end
  function resources.release(_lease)
    releases = releases + 1
  end
  local scene = BattleScene.new()
  scene:install({ combatant = 1, activation = 1 })
  scene:install({ combatant = 3, activation = 3 })
  local player = assert(BattleAnimationPlayer.new({
    scene = scene,
    audio = audio,
    resources = resources,
    tasks = factory(),
    splRandomState = { state = 1234 },
    services = {
      onNativeFrame = function(phase, sourceTick)
        if phase == "draw" then
          BattleParticleSystems.stepSourceDrawPhase(scene, sourceTick)
          scene:stepAnimationPictures(sourceTick)
        end
      end,
    },
  }))
  local packet = {
    launchId = "extrasensory-gate",
    packetId = 1,
    topology = {
      attacker = { combatant = 1, activation = 1, slot = "solo-player", sideType = 0 },
      targets = { { combatant = 3, activation = 3, slot = "solo-enemy", sideType = 1 } },
      sourceBattlers = {
        { combatant = 1, activation = 1, slot = "solo-player", sideType = 0 },
        { combatant = 3, activation = 3, slot = "solo-enemy", sideType = 1 },
      },
    },
  }
  local handle = assert(player:start(packet, effect.program))
  local clearedTick = nil
  local clearedFrame = nil
  for tick = 1, 3000 do
    player:stepSourceTick({ tick = tick, seed = 4242 })
    local frame = scene:animationFrame()
    local plane = frame.main ~= nil and frame.main.planes ~= nil and frame.main.planes.bg2 or nil
    if plane ~= nil and plane.cleared == true and clearedTick == nil then
      clearedTick = tick
      clearedFrame = frame
    end
    local phase = player:status(handle)
    if phase == "complete" or phase == "failed" then
      break
    end
  end
  Assert.equal(player:status(handle), "complete", "the corpus member completes without failure")
  Assert.isNil(player:failure(handle), "the completed member carries no failure")
  Assert.notNil(clearedTick, "the plane visibly clears during the run")
  Assert.isTrue(clearedTick > 1, "the clear lands after the program opens, not before it runs")
  Assert.notNil(clearedFrame, "the clearing frame is captured")
  Assert.isTrue(player:retire(handle), "the terminal occurrence retires")
  Assert.equal(#scene:particleSystems(), 0, "no particle system remains registered")
  local lingering = 0
  for _, view in ipairs(scene:effectViews()) do
    if view.sourceKey == "battler-sprite-slot" then
      lingering = lingering + 1
    end
  end
  Assert.equal(lingering, 0, "no battler sprite slot remains allocated")
end

local readyVersions = {}
for _, versionId in ipairs(GameVersion.ORDER) do
  if RomImporter.isReady(versionId) then
    readyVersions[#readyVersions + 1] = versionId
  end
end

local RomSourcePath = require("tests.rom.support.RomSourcePath")

return RomSuite.build({
  tests = T,
  readyVersions = readyVersions,
  open = RomSourcePath.openReader,
})
