-- Native effect inventory closure at the production task boundary: the
-- pinned dispatch table spans its full native extent, every semantic
-- program root is finite and resolvable without dump bytes, handlers that
-- need runtime source detail fail closed with native byte detail, and no
-- timer-only stand-in may satisfy an unknown task kind. Setup below holds
-- today through the real producer path; the execution gate drives the
-- battle-private program player together with the battle-private effect
-- task factory once both exist.
-- Native mechanism: asm/overlay_07.s ov07_02234DE8 dispatch and the
-- overlay-7 effect resource families
-- (pret/pokeheartgold@9d8b7591f09b65804da2fb2dfd56f320633e0d36).
-- Headless: synthetic command streams use the real producer lowering and
-- the shared program shape; the recorder doubles record only.

local Assert = require("tests.support.Assert")
local BattleAnimationCompiler = require("romdump.src.digest.battle.BattleAnimationCompiler")
local BattleAnimationSchema = require("libs.assets.src.battle.BattleAnimationSchema")
local BattleAnimationSources = require("romdump.src.config.BattleAnimationSources")
local BattlePresentationModel = require("game.hgss.src.battle.BattlePresentationModel")
local BattleScene = require("libs.hgss.src.presentation.BattleScene")

local T = {}

local function u32(value)
  return string.char(
    value % 256,
    math.floor(value / 256) % 256,
    math.floor(value / 65536) % 256,
    math.floor(value / 16777216) % 256
  )
end

local function streamOf(list)
  local parts = {}
  for _, word in ipairs(list) do
    parts[#parts + 1] = u32(word)
  end
  return table.concat(parts)
end

local function lowered(key, list, extra)
  local probe = { key = key, stream = streamOf(list) }
  if extra ~= nil then
    for field, value in pairs(extra) do
      probe[field] = value
    end
  end
  local program = assert(BattleAnimationCompiler.compile(probe))
  Assert.isTrue(
    BattleAnimationSchema.assertProgram({
      entry = program.entry,
      instructions = program.instructions,
      subprograms = program.subprograms,
      taskKinds = program.taskKinds,
    }),
    "the lowered program validates against the shared program shape"
  )
  return program
end

local function sceneWithPair()
  local scene = BattleScene.new()
  scene:observe({
    { combatant = 1, activation = 1, visible = true },
    { combatant = 3, activation = 3, visible = true },
  })
  return scene
end

local function playbackPacket()
  local packet = BattlePresentationModel.packet({}, { events = {} }, {}, {
    launchId = "inventory-closure-probe",
    packetId = 1,
  })
  Assert.equal(packet.launchId, "inventory-closure-probe", "the playback input carries its launch identity")
  return packet
end

local function playerModule()
  local ok, Player = pcall(require, "libs.hgss.src.presentation.BattleAnimationPlayer")
  Assert.isTrue(ok, "the battle-private animation player resolves through the presentation boundary")
  Assert.equal(type(Player.new), "function", "the player exposes its construction entry point")
  return Player
end

local function effectFactoryModule()
  local ok, Factory = pcall(require, "libs.hgss.src.presentation.BattleEffectTasks")
  Assert.isTrue(ok, "the battle-private effect task factory resolves through the presentation boundary")
  Assert.equal(type(Factory.create), "function", "the factory exposes its task construction entry point")
  return Factory
end

function T.dispatch_table_spans_the_full_native_extent()
  Assert.equal(BattleAnimationSources.handlerCount(), 88, "the dispatch holds every native handler")
  Assert.equal(
    BattleAnimationSources.DISPATCH_ENTRIES,
    88,
    "the pinned entry count matches the handler inventory"
  )
  local first = BattleAnimationSources.handlerLabel(0)
  Assert.isTrue(type(first) == "string" and first ~= "", "the first dispatch word names its handler")
  local last = BattleAnimationSources.handlerLabel(87)
  Assert.isTrue(type(last) == "string" and last ~= "", "the final dispatch word names its handler")
  Assert.isNil(BattleAnimationSources.handlerLabel(88), "words past the table end name no handler")
  Assert.isTrue(BattleAnimationSources.isSourceNoop(6), "the documented no-op word stays a no-op")
  Assert.isFalse(BattleAnimationSources.isSourceNoop(34), "the task-spawn word is never a no-op")
end

function T.semantic_roots_are_finite_and_resolvable_without_dump_bytes()
  local roots = BattleAnimationSources.listSemanticRoots()
  local moves, named = 0, 0
  local seen = {}
  local previousKind, previousId = nil, nil
  for _, root in ipairs(roots) do
    Assert.isTrue(root.kind == "move" or root.kind == "battle-animation", "every root names its program family")
    Assert.isTrue(type(root.key) == "string" and root.key ~= "", "every root carries a semantic key")
    Assert.isTrue(type(root.archiveSymbol) == "string", "every root names its source archive")
    Assert.isTrue(type(root.memberId) == "number", "every root names its source member")
    Assert.isNil(seen[root.key], "semantic roots carry no duplicates")
    seen[root.key] = true
    local id = root.moveId or root.animationCategory
    if previousKind == root.kind then
      Assert.isTrue(previousId < id, "roots of one family stay in source-member order")
    end
    previousKind, previousId = root.kind, id
    if root.kind == "move" then
      moves = moves + 1
    else
      named = named + 1
    end
  end
  Assert.equal(moves, 467, "the move inventory spans the full pinned move range")
  Assert.isTrue(named > 0, "named non-move programs join the same finite inventory")
  local pound = BattleAnimationSources.resolveSemanticRoute("POUND")
  Assert.notNil(pound, "a representative striking move resolves to its source member")
  Assert.equal(pound.kind, "move", "the striking move keeps its program family")
  local frozen = BattleAnimationSources.resolveSemanticRoute("BATTLE_ANIMATION_FROZEN")
  Assert.notNil(frozen, "a representative status program resolves to its source member")
  Assert.equal(frozen.kind, "battle-animation", "the status program keeps its program family")
end

function T.handlers_needing_runtime_detail_fail_closed_with_native_detail()
  local particleErr = Assert.throws(function()
    BattleAnimationCompiler.compile({ key = "particle-without-profile", stream = streamOf({ 46, 0, 0, 0 }) })
  end, "a particle word without its source profile never lowers")
  Assert.isTrue(
    string.find(tostring(particleErr), "particle-without-profile", 1, true) ~= nil,
    "the rejection names the program under lowering"
  )
  Assert.isTrue(
    string.find(tostring(particleErr), "unresolved particle action profile", 1, true) ~= nil,
    "the rejection names the missing source detail"
  )
  local backgroundErr = Assert.throws(function()
    BattleAnimationCompiler.compile({ key = "background-without-profile", stream = streamOf({ 21, 3 }) })
  end, "a background word without its source profile never lowers")
  Assert.isTrue(
    string.find(tostring(backgroundErr), "unresolved battle background resource", 1, true) ~= nil,
    "the background rejection names the missing source detail"
  )
end

function T.reachable_task_kinds_construct_through_the_production_factory()
  local contact = lowered("closure-contact-shape", { 34, 1, 2, 3, 50, 4 })
  local projectile = lowered("closure-projectile-shape", { 51, 1, 64, 50, 4 })
  local kinds = {}
  local seen = {}
  for _, program in ipairs({ contact, projectile }) do
    for _, kind in ipairs(program.taskKinds) do
      if not seen[kind] then
        seen[kind] = true
        kinds[#kinds + 1] = kind
      end
    end
  end
  Assert.isTrue(#kinds >= 2, "the representative shapes reach more than one task kind")

  local Player = playerModule()
  local Factory = effectFactoryModule()
  local scene = sceneWithPair()
  local audio = { played = {}, stopped = {} }
  function audio.play(name)
    audio.played[#audio.played + 1] = name
  end
  function audio.stop(name)
    audio.stopped[#audio.stopped + 1] = name
  end
  function audio.isFinished(_name)
    return true
  end
  local resources = {}
  function resources.resolve(key)
    return { key = key, lease = key }
  end
  function resources.release(_lease) end
  local context = {
    actors = { attacker = 1, target = 3 },
    seed = 1234,
  }
  local services = { scene = scene, audio = audio, resources = resources }
  local built = {}
  for _, kind in ipairs(kinds) do
    local args = {}
    if kind == Factory.PARTICLE_CONTINUATION_KIND then
      args = { resource = "battle/particle/tackle", emitterPosition = "solo-enemy" }
    end
    local task = assert(
      Factory.create(kind, args, context, services),
      "the production factory constructs the reachable kind " .. kind
    )
    Assert.equal(type(task.stepSourceTick), "function", kind .. " advances on the source tick")
    Assert.equal(type(task.status), "function", kind .. " reports its run state")
    Assert.equal(type(task.cancel), "function", kind .. " accepts cancellation")
    Assert.equal(type(task.dispose), "function", kind .. " releases its holdings")
    built[#built + 1] = task
  end
  local player = assert(Player.new({
    scene = scene,
    audio = audio,
    resources = resources,
    tasks = Factory,
  }))
  for _, program in ipairs({ contact, projectile }) do
    local handle = assert(player:start(playbackPacket(), program))
    for _ = 1, 60 do
      player:stepSourceTick({ tick = 1 })
      if player:status(handle) == "complete" then
        break
      end
    end
    Assert.equal(player:status(handle), "complete", program.key .. " runs to its completion boundary")
  end
  for _, task in ipairs(built) do
    task:dispose()
  end
end

function T.timer_only_stand_in_for_an_unknown_kind_is_rejected()
  local Factory = effectFactoryModule()
  local scene = sceneWithPair()
  local services = { scene = scene, audio = {}, resources = {} }
  local ok, result = pcall(Factory.create, "no-such-native-kind", {}, {}, services)
  Assert.isFalse(ok and type(result) == "table" and type(result.stepSourceTick) == "function", "an unknown kind never yields a runnable task")
  Assert.isTrue(not ok or result == nil, "the unknown kind fails instead of returning a silent timer")
end

return { tests = T }
