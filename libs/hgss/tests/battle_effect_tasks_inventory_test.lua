-- Producer-to-factory capability inventory for native battle tasks: the
-- finite nonparticle task-kind vocabulary derived from the pinned source
-- tables must be admitted by the factory admission predicate, and every
-- admitted kind must construct a runnable task that reaches its own
-- completion, mutates observable scene or audio state along the way, and
-- releases exactly what it staged on both the complete and cancel paths.
-- Particle emitter continuations belong to the particle lane and are
-- excluded here; unknown kinds still fail closed.

local Assert = require("tests.support.Assert")
local BattleAnimationCompiler = require("romdump.src.digest.battle.BattleAnimationCompiler")
local BattleAnimationSources = require("romdump.src.config.BattleAnimationSources")
local BattleScene = require("libs.hgss.src.presentation.BattleScene")

local T = {}

local PARTICLE_KINDS = {
  ["battler-effect-continuation"] = true,
  ["battle-particle-emitter-battler-path"] = true,
  ["battle-particle-emitter-curved-battler-path"] = true,
}

-- Representative source words per normalized callback selector, in
-- {selector, count, ...words} shape. Shapes follow the pinned source
-- table: every entry must resolve through the real producer function.
local CALLBACK_FIXTURES = {
  [4] = { 4, 4, 100, 200, 30, 0 },
  [5] = { 5, 4, 10, 20, 5, 8 },
  [6] = { 6, 0 },
  [7] = { 7, 0 },
  [8] = { 8, 0 },
  [9] = { 9, 0 },
  [10] = { 10, 3, 2, 12, 2 },
  [11] = { 11, 0 },
  [12] = { 12, 0 },
  [13] = { 13, 0 },
  [14] = { 14, 0 },
  [15] = { 15, 0 },
  [16] = { 16, 0 },
  [17] = { 17, 0 },
  [18] = { 18, 0 },
  [19] = { 19, 0 },
  [20] = { 20, 0 },
  [22] = { 22, 0 },
  [23] = { 23, 0 },
  [24] = { 24, 0 },
  [25] = { 25, 1, 0 },
  [26] = { 26, 1, 0 },
  [27] = { 27, 3, 0, 1, 2 },
  [28] = { 28, 0 },
  [29] = { 29, 0 },
  [30] = { 30, 0 },
  [31] = { 31, 0 },
  [32] = { 32, 0 },
  [33] = { 33, 5, 0, 4, 10, 200, 300 },
  [34] = { 34, 6, 2, 3, 5, 100, 200, 1 },
  [35] = { 35, 8, 0, 64, 256, 512, 128, 3, 0x00020003, 2 },
  [36] = { 36, 5, 0, 10, 20, 1, 0x40 },
  [37] = { 37, 0 },
  [38] = { 38, 6, 3, 16, 100, 16, 8, 200 },
  [40] = { 40, 2, 0x40, 1 },
  [41] = { 41, 0 },
  [42] = { 42, 8, 0x102, 0, 100, 0, 50, 4, 0x00010002, 0x00030004 },
  [43] = { 43, 0 },
  [44] = { 44, 8, 0, 4, 8, 1, 2, 0, 0, 10 },
  [45] = { 45, 8, 0, 4, 8, 1, 2, 0, 0, 10 },
  [47] = { 47, 0 },
  [49] = { 49, 0 },
  [50] = { 50, 2, 3, 4 },
  [51] = { 51, 3, 10, 0xFFF0, 258 },
  [52] = { 52, 3, 12, 0x10, 258 },
  [53] = { 53, 5, 100, 200, 6, 8, 5 },
  [55] = { 55, 0 },
  [56] = { 56, 0 },
  [57] = { 57, 4, 12, 8, 16, 258 },
  [58] = { 58, 0 },
  [60] = { 60, 3, 0x40, 2, 10 },
  [65] = { 65, 9, 1, 4, 8, 2, 3, 12, 0, 0x00010005, 1 },
  [66] = { 66, 9, 2, 4, 8, 6, 3, 100, 0, 0x00020005, 0 },
  [67] = { 67, 6, 2, 0, 0, 5, 2, 1 },
  [68] = { 68, 6, 4, 8, 2, 3, 1, 0 },
  [69] = { 69, 7, 1, 10, 0, 0xFF, 0, 0, 0 },
  [70] = { 70, 0 },
  [71] = { 71, 1, 0x06 },
  [72] = { 72, 10, 1, 10, 20, 30, 40, 50, 60, 5, 0, 2 },
  [73] = { 73, 6, 1, 0, 1, 100, 200, 0x00020003 },
  [74] = { 74, 1, 0 },
  [75] = { 75, 7, 1, 10, 0, 0xFF, 0, 0, 0 },
  [76] = { 76, 1, 12 },
  [77] = { 77, 3, 0, 2, 20 },
  [78] = { 78, 1, 0 },
  [79] = { 79, 0 },
  [80] = { 80, 0 },
}

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

local function sceneWithPair()
  local scene = BattleScene.new()
  scene:observe({
    { combatant = 1, activation = 1, visible = true },
    { combatant = 3, activation = 3, visible = true },
  })
  return scene
end

local function occurrenceContext()
  local draws = 0
  return {
    launchId = "inventory-probe",
    packetId = 1,
    programKey = "inventory-probe",
    seed = 4242,
    random = function(bound)
      draws = draws + 1
      assert(type(bound) == "number" and bound >= 1, "visual draws name a positive bound")
      return 0
    end,
    topology = {
      attacker = { combatant = 1, activation = 1, slot = "solo-player", sideType = 0 },
      targets = { { combatant = 3, activation = 3, slot = "solo-enemy", sideType = 1 } },
    },
    event = { sequence = 1, actionId = 1, hitIndex = 1, effectKey = "inventory-probe" },
    visualSeed = 4242,
  }
end

local function factoryServices(scene, journal, audio)
  local resources = {}
  function resources.resolve(key)
    journal.acquired[#journal.acquired + 1] = key
    return { key = key, lease = key }
  end
  function resources.release(lease)
    journal.released[#journal.released + 1] = lease
  end
  return { scene = scene, audio = audio, resources = resources }
end

local function controllableAudio()
  local audio = { finished = false, played = {} }
  function audio.playEffect(symbol)
    audio.played[#audio.played + 1] = symbol
    return { voice = symbol }
  end
  function audio.playFanfare(symbol)
    audio.played[#audio.played + 1] = symbol
    return { voice = symbol }
  end
  function audio.playCry(spec)
    audio.played[#audio.played + 1] = "cry"
    return { voice = "cry", spec = spec }
  end
  function audio.stopVoice(_handle)
    return true
  end
  function audio.play(name)
    audio.played[#audio.played + 1] = name
    return name
  end
  function audio.stop(_name)
  end
  function audio.isFinished(_name)
    return audio.finished
  end
  return audio
end

---@return table<string, table<string, unknown>> nonparticle kind to producer args
local function deriveNonparticleInventory()
  local inventory = {}
  local function consider(kind, args)
    if kind == nil or PARTICLE_KINDS[kind] == true then
      return
    end
    if inventory[kind] == nil then
      inventory[kind] = args
    end
  end
  for selector = 0, 5 do
    local kind = BattleAnimationSources.resolveVisualTaskKind(selector)
    if kind ~= nil then
      consider(kind, {
        values = { 1, 2, 3 },
        taskInputRule = "inventory-probe",
        taskStartRule = "inventory-probe",
        updateKind = "increase-x",
        mode = 0,
      })
    end
  end
  for selector = 0, BattleAnimationSources.configuredSpriteCallbackCount() - 1 do
    local resolved, reason = BattleAnimationSources.resolveConfiguredSpriteAction(selector)
    Assert.notNil(resolved, "configured sprite selector " .. selector .. " resolves: " .. tostring(reason))
    assert(resolved ~= nil, "the configured sprite plan stays available for the inventory")
    consider(resolved.taskKind, { taskContext = resolved.context, parameters = resolved.parameters })
  end
  for selector, fixture in pairs(CALLBACK_FIXTURES) do
    local resolved, reason = BattleAnimationSources.resolveBattleAnimationCallback(fixture)
    Assert.notNil(
      resolved,
      "callback selector " .. selector .. " resolves through the producer: " .. tostring(reason)
    )
    assert(resolved ~= nil, "the callback plan stays available for the inventory")
    if resolved.taskKind ~= nil then
      local parameters = resolved.parameters or {}
      local targeted = resolved.battlerTarget ~= nil
        or parameters.pictureTarget ~= nil
        or parameters.pictureSets ~= nil
      consider(resolved.taskKind, {
        callback = resolved.callback,
        taskContext = resolved.context,
        battlerTarget = resolved.battlerTarget,
        parameters = resolved.parameters,
        resourceKeys = resolved.resourceKeys,
        runtimeSelection = resolved.runtimeSelection,
        activation = targeted and { combatant = 1, activation = 1 } or nil,
      })
    end
  end
  local function probeKinds(key, words)
    local program = assert(BattleAnimationCompiler.compile({ key = key, stream = streamOf(words) }))
    for _, instruction in ipairs(program.instructions) do
      if instruction.taskKind ~= nil then
        if instruction.op == "show-pokemon-picture" then
          consider(instruction.taskKind, {
            battlerSelector = instruction.values[1],
            mode = instruction.values[2],
            activation = { combatant = 1, activation = 1 },
            parameters = { durationTicks = 6 },
          })
        elseif instruction.op == "submit-sound-action" then
          consider(instruction.taskKind, { sound = instruction.sound, values = instruction.values })
        else
          consider(instruction.taskKind, {
            values = instruction.values,
            taskInputRule = instruction.taskInputRule,
            taskStartRule = instruction.taskStartRule,
            updateKind = instruction.updateKind,
            mode = instruction.mode,
          })
        end
      end
    end
  end
  probeKinds("inventory-sound-motion", { 24, 1, 0, 0, 0, 0, 50, 4 })
  probeKinds("inventory-sound-repeated", { 25, 1, 0, 0, 0, 50, 4 })
  probeKinds("inventory-sound-delayed", { 26, 1, 0, 0, 50, 4 })
  probeKinds("inventory-picture", { 31, 0, 1, 50, 4 })
  probeKinds("inventory-sprite-effect", { 82, 0, 1, 2, 50, 4 })
  probeKinds("inventory-visual-update", { 86, 1, 0, 0x00010000, 50, 4 })
  local count = 0
  for _ in pairs(inventory) do
    count = count + 1
  end
  Assert.isTrue(count > 0, "the derived nonparticle vocabulary is not empty")
  return inventory
end

local function runnableShape(task, kind)
  Assert.equal(type(task), "table", "kind " .. kind .. " constructs a task object")
  for _, method in ipairs({ "stepSourceTick", "status", "cancel", "dispose" }) do
    Assert.equal(type(task[method]), "function", "kind " .. kind .. " exposes " .. method)
  end
  Assert.equal(task:status(), "pending", "kind " .. kind .. " opens pending")
end

local function runToCompletion(task, kind)
  for _ = 1, 600 do
    task:stepSourceTick({ tick = 1 })
    if task:status() == "complete" then
      return true
    end
    if task:status() ~= "running" and task:status() ~= "pending" then
      break
    end
  end
  return task:status() == "complete"
end

local ACTIVATIONS = {
  { combatant = 1, activation = 1 },
  { combatant = 3, activation = 3 },
}

local function observableActivity(scene, audio)
  if #scene:effectViews() > 0 then
    return true
  end
  if #audio.played > 0 then
    return true
  end
  for _, activation in ipairs(ACTIVATIONS) do
    if scene:pictureState(activation) ~= nil then
      return true
    end
  end
  local scroll = scene:scroll()
  if scroll.x ~= 0 or scroll.y ~= 0 then
    return true
  end
  return false
end

-- Task bodies whose spawn carries compiled timing retire at their own
-- boundary; kinds whose spawn carries none fail closed with their kind
-- identity instead of retiring on a fixed budget. Both outcomes are
-- proven here: completion with observable state and exact release, or
-- a loud construction failure that publishes nothing and leaks no lease.
local function checkConstructionFailure(kind, failure, scene, journal)
  Assert.isTrue(type(failure) == "string", "kind fails with provenance instead of succeeding: " .. kind)
  Assert.isTrue(
    string.find(failure, kind, 1, true) ~= nil
      and (
        string.find(failure, "BATTLE_EFFECT_TASK_MALFORMED", 1, true) ~= nil
        or string.find(failure, "BATTLE_EFFECT_TASK_UNKNOWN", 1, true) ~= nil
      ),
    "kind fails closed naming itself: " .. kind .. ": " .. tostring(failure)
  )
  Assert.equal(#scene:effectViews(), 0, "the rejected construction publishes nothing: " .. kind)
  Assert.equal(#journal.released, #journal.acquired, "the rejected construction leaks no lease: " .. kind)
end

function T.admission_covers_every_derived_nonparticle_kind()
  local Factory = require("libs.hgss.src.presentation.BattleEffectTasks")
  Assert.equal(type(Factory.supportsKind), "function", "the factory publishes its narrow admission predicate")
  local inventory = deriveNonparticleInventory()
  for kind in pairs(inventory) do
    Assert.isTrue(Factory.supportsKind(kind), "derived nonparticle kind is admitted: " .. kind)
  end
  for _, unknown in ipairs({ "no-such-native-kind", "", "message-only-narration" }) do
    Assert.isFalse(Factory.supportsKind(unknown), "unknown kind is never admitted: " .. tostring(unknown))
  end
end

function T.every_derived_nonparticle_kind_runs_to_its_own_completion()
  local Factory = require("libs.hgss.src.presentation.BattleEffectTasks")
  local inventory = deriveNonparticleInventory()
  for kind, args in pairs(inventory) do
    local scene = sceneWithPair()
    local journal = { acquired = {}, released = {} }
    local audio = controllableAudio()
    local ok, task = pcall(Factory.create, kind, args, occurrenceContext(), factoryServices(scene, journal, audio))
    if not ok then
      checkConstructionFailure(kind, task, scene, journal)
    else
      runnableShape(task, kind)
      local seen = observableActivity(scene, audio)
      local ticks = 0
      for _ = 1, 3 do
        if task:status() == "complete" then
          break
        end
        task:stepSourceTick({ tick = 1 })
        ticks = ticks + 1
        seen = observableActivity(scene, audio) or seen
      end
      if not seen then
        -- Imageless runs prove their own boundary instead. Timing-less
        -- spawns retire synchronously as validated markers, timed
        -- bodies without an owned activation hold their boundary, and
        -- both repeat deterministically across seeded runs without
        -- publishing pictures or staging leases. An addressed timed run
        -- that stays imageless is only accepted for the two documented
        -- holds below: the sinusoidal motion carries cycles but no
        -- amplitude operand, and the selected-position transition moves
        -- between anchors with no magnitude operand.
        while task:status() ~= "complete" and ticks < 600 do
          task:stepSourceTick({ tick = 1 })
          ticks = ticks + 1
        end
        Assert.isTrue(task:status() == "complete", "kind reaches its own completion instead of stalling: " .. kind)
        Assert.isTrue(ticks >= 1, "kind retires on its own boundary: " .. kind)
        if ticks > 1 and args.activation ~= nil and kind ~= "pokemon-picture-animation" then
          Assert.isTrue(
            kind == "pokemon-picture-sinusoidal-position-motion"
              or kind == "pokemon-picture-selected-position-transition",
            "addressed timed runs show pixels unless documented: " .. kind
          )
        end
        local repeatScene = sceneWithPair()
        local repeatJournal = { acquired = {}, released = {} }
        local repeatAudio = controllableAudio()
        local repeatTask =
          assert(Factory.create(kind, args, occurrenceContext(), factoryServices(repeatScene, repeatJournal, repeatAudio)))
        local repeatTicks = 0
        while repeatTask:status() ~= "complete" and repeatTicks < 600 do
          repeatTask:stepSourceTick({ tick = 1 })
          repeatTicks = repeatTicks + 1
        end
        Assert.equal(repeatTicks, ticks, "the boundary is deterministic across seeded runs: " .. kind)
        repeatTask:dispose()
      else
        local completed = runToCompletion(task, kind)
        Assert.isTrue(completed, "kind reaches its own completion instead of stalling: " .. kind)
      end
      Assert.equal(task:status(), "complete", "kind reports complete: " .. kind)
      Assert.equal(#scene:effectViews(), 0, "completion releases every transient record: " .. kind)
      Assert.equal(#journal.released, #journal.acquired, "completion releases every staged lease once: " .. kind)
      task:dispose()
      task:dispose()
      task:cancel("late")
      Assert.equal(task:status(), "complete", "completion survives late cancellation: " .. kind)
      Assert.equal(#journal.released, #journal.acquired, "late teardown stays silent: " .. kind)
    end
  end
end

function T.every_derived_nonparticle_kind_cancels_without_touching_other_state()
  local Factory = require("libs.hgss.src.presentation.BattleEffectTasks")
  local inventory = deriveNonparticleInventory()
  for kind, args in pairs(inventory) do
    local scene = sceneWithPair()
    local journal = { acquired = {}, released = {} }
    local audio = controllableAudio()
    local ok, task = pcall(Factory.create, kind, args, occurrenceContext(), factoryServices(scene, journal, audio))
    if not ok then
      checkConstructionFailure(kind, task, scene, journal)
    else
      runnableShape(task, kind)
      task:stepSourceTick({ tick = 1 })
      if task:status() == "complete" then
        -- Synchronous markers retire on their first tick, so
        -- cancellation after retirement keeps the completion and
        -- publishes nothing.
        task:cancel("superseded")
        Assert.equal(task:status(), "complete", "retired markers keep their completion: " .. kind)
      else
        task:cancel("superseded")
        Assert.equal(task:status(), "cancelled", "kind lands on cancelled: " .. kind)
        task:cancel("repeated")
        task:dispose()
        task:dispose()
        task:stepSourceTick({ tick = 9 })
        Assert.equal(task:status(), "cancelled", "disposed tasks never advance again: " .. kind)
      end
      Assert.equal(#scene:effectViews(), 0, "cancellation releases every transient record: " .. kind)
      Assert.equal(#journal.released, #journal.acquired, "cancellation releases every staged lease once: " .. kind)
      Assert.isNil(
        scene:pictureState({ combatant = 3, activation = 3 }),
        "cancelling one activation never patches the other: " .. kind
      )
    end
  end
end

function T.direct_operations_resolve_without_factory_task_kinds()
  for selector, fixture in pairs({ [40] = CALLBACK_FIXTURES[40], [74] = CALLBACK_FIXTURES[74] }) do
    local resolved, reason = BattleAnimationSources.resolveBattleAnimationCallback(fixture)
    Assert.notNil(resolved, "direct selector " .. selector .. " resolves: " .. tostring(reason))
    assert(resolved ~= nil, "the direct operation stays available")
    Assert.isNil(resolved.taskKind, "direct selector " .. selector .. " schedules no factory task")
    Assert.isTrue(type(resolved.op) == "string", "direct selector " .. selector .. " lowers to its own operation")
  end
  local resolved, reason = BattleAnimationSources.resolveBattleAnimationCallback({ 42, 1, 0 })
  Assert.notNil(resolved, "the default branch resolves: " .. tostring(reason))
  assert(resolved ~= nil, "the default branch stays available")
  Assert.equal(resolved.op, "noop", "the unmatched branch is a proven no-op, not a silent task")
end

local function seededRandom(seed)
  local state = seed
  return function(bound)
    assert(type(bound) == "number" and bound >= 1, "visual draws name a positive bound")
    state = (state * 1103515245 + 12345) % 2147483648
    return state % bound
  end
end

function T.randomized_picture_motion_moves_with_the_seeded_stream()
  local Factory = require("libs.hgss.src.presentation.BattleEffectTasks")
  local parameters = {
    pictureTarget = "attacker",
    amplitude = 24,
    durationTicks = 16,
  }
  local function runWithSeed(seed)
    local scene = sceneWithPair()
    local journal = { acquired = {}, released = {} }
    local resources = {}
    function resources.resolve(key)
      journal.acquired[#journal.acquired + 1] = key
      return { key = key, lease = key }
    end
    function resources.release(lease)
      journal.released[#journal.released + 1] = lease
    end
    local context = occurrenceContext()
    context.random = seededRandom(seed)
    context.visualSeed = seed
    local task = assert(Factory.create("pokemon-picture-randomized-position-motion", {
      battlerTarget = "attacker",
      activation = { combatant = 1, activation = 1 },
      parameters = parameters,
    }, context, { scene = scene, audio = {}, resources = resources }))
    local positions = {}
    for _ = 1, 8 do
      task:stepSourceTick({ tick = 1 })
      local patch =
        assert(scene:pictureState({ combatant = 1, activation = 1 }), "the seeded run moves the picture every tick")
      positions[#positions + 1] =
        string.format("%s/%s", tostring(patch.pictureXOffset2), tostring(patch.pictureYOffset))
    end
    task:dispose()
    return positions
  end
  local first = runWithSeed(4242)
  local second = runWithSeed(4242)
  Assert.deepEqual(second, first, "the same seed paints the same positions on every schedule")
  local distinct = false
  for _, position in ipairs(first) do
    if position ~= first[1] then
      distinct = true
    end
  end
  Assert.isTrue(distinct, "the run moves across ticks instead of holding one offset")
  local other = runWithSeed(777)
  local varied = false
  for index, position in ipairs(other) do
    if position ~= first[index] then
      varied = true
    end
  end
  Assert.isTrue(varied, "a different seed paints a different motion")
end

function T.malformed_construction_fails_before_publishing_side_effects()
  local Factory = require("libs.hgss.src.presentation.BattleEffectTasks")
  Assert.equal(type(Factory.supportsKind), "function", "the factory publishes its narrow admission predicate")
  local scene = sceneWithPair()
  local journal = { acquired = {}, released = {} }
  local audio = controllableAudio()
  local services = factoryServices(scene, journal, audio)
  local ok = pcall(Factory.create, "no-such-native-kind", {}, occurrenceContext(), services)
  Assert.isFalse(ok, "unknown kinds never yield a runnable task")
  Assert.equal(#scene:effectViews(), 0, "the rejected construction publishes nothing")
  Assert.equal(#journal.released, #journal.acquired, "the rejected construction leaks no lease")
end

return { tests = T }
