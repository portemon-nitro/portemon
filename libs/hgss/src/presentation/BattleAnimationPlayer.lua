-- Battle-private normalized battle-animation interpreter. Native
-- mechanism: src/battle/battle_anim_system.c
-- BattleAnimSystem_ExecuteCommands runs immediate instructions in one
-- source quantum until a delay parks it, and the dispatch extent is the
-- 88-entry asm/battle_anim_data.s sBattleAnimScriptCmdTable. This
-- interpreter preserves that order: immediate instructions run in the
-- same source quantum until a native yield, wait, or completion; child
-- tasks step at the task phase in admission order; completion is the
-- stream-end boundary with the source-condition verify, never the bare
-- end of the instruction array while required work remains.
-- The interpreter owns occurrence state, task retirement, both native
-- task counters, voice and lease journals, and deterministic visual
-- randomness. Visual bodies belong to the injected task collaborator
-- (the production factory joins in its own lane); the player never
-- imports it eagerly and performs no scene mutation in this lane.

local BattleAnimationSchema = require("libs.assets.src.battle.BattleAnimationSchema")
local BattleAnimationCommands = require("libs.hgss.src.presentation.BattleAnimationCommands")

---@class BattleAnimationPlayer
---@field _scene table<string, unknown> presentation scene reserved for later visual application
---@field _audio table<string, unknown> narrow voice collaborator behind play, stop, isFinished
---@field _resources table<string, unknown> launch-owned lease collaborator behind resolve, release
---@field _tasks table<string, unknown> task-construction collaborator behind create
---@field _occurrences table<integer, BattleAnimationOccurrence> occurrences in admission order
---@field _byId table<integer, BattleAnimationOccurrence> occurrences behind opaque handles
---@field _nextId integer next occurrence identity
---@field _disposed boolean release has run
local BattleAnimationPlayer = {}
BattleAnimationPlayer.__index = BattleAnimationPlayer

-- Narrow player-to-factory contract kind for the voice monitor behind
-- sound waits. The factory carries the same spelling on its
-- VOICE_MONITOR_KIND; the player owns the contract string because it is
-- the sole constructor-side consumer.
BattleAnimationPlayer.VOICE_TASK_KIND = "voice-completion-monitor"

local LIVE_PHASES = { preparing = true, running = true, waiting = true }
local TASK_STATES = { pending = true, running = true, complete = true, cancelled = true, failed = true }
-- Task ownership groups echoing the native counters: general tasks feed
-- the interpreter counter wait, sound actions feed the sound wait, enemy
-- particle work feeds the battler-effects wait, and raw visual work runs
-- outside every counter exactly like the native direct sys tasks.
local TASK_GROUPS = { general = true, sound = true, particle = true, raw = true }
local VOICE_ESCAPE_TICKS = 90

---@class BattleAnimationOccurrence
---@field id integer stable admission identity behind the opaque handle
---@field launchId string playback launch identity under diagnosis
---@field packetId integer per-launch playback identity under diagnosis
---@field programKey string normalized program identity under diagnosis
---@field program table<string, unknown> admitted normalized program under execution
---@field phase string preparing, running, waiting, complete, cancelled, or failed
---@field pc integer one-based instruction position under execution
---@field scratch table<integer, integer> ten-slot source parameter context
---@field callStack integer[] return destinations behind subprogram calls
---@field loopSlots table<integer, table<string, unknown>> three native loop slots
---@field owned table<integer, table<string, unknown>> factory tasks in construction order
---@field voices table<integer, table<string, unknown>> staged voices in play order
---@field leases table<integer, table<string, unknown>> staged resource leases in stage order
---@field journal table<integer, table<string, unknown>> visual intents under ownership
---@field wait table<string, unknown>? parked wait under re-evaluation
---@field endPhase integer stream-end verify phase behind completion
---@field endPark integer stream-end voice holds behind the native escape
---@field cycleFault table<string, unknown>? static zero-time cycle finding
---@field fault table<string, unknown>? failure detail behind failed
---@field cancelReason string? last cancellation cause under diagnosis
---@field voiceSeq integer staged voice counter behind deterministic voice keys
---@field rawProgress boolean true once a raw task retired through completion
---@field seed integer latched visual seed behind the occurrence-local stream
---@field seedLatched boolean visual seed has been captured
---@field randomState integer occurrence-local visual random state
---@field packet table<string, unknown> immutable playback packet behind identity and context

---@param collaborators table<string, unknown> required scene, audio, resources, tasks narrow seam
---@return BattleAnimationPlayer runnable battle-private animation player
function BattleAnimationPlayer.new(collaborators)
  assert(type(collaborators) == "table", "the animation player requires its collaborators")
  assert(type(collaborators.scene) == "table", "the animation player requires its scene")
  assert(type(collaborators.audio) == "table", "the animation player requires its audio voices")
  assert(type(collaborators.audio.play) == "function", "player audio voices play by name")
  assert(type(collaborators.audio.stop) == "function", "player audio voices stop by name")
  assert(type(collaborators.audio.isFinished) == "function", "player audio voices report completion")
  assert(type(collaborators.resources) == "table", "the animation player requires its resources")
  assert(type(collaborators.resources.resolve) == "function", "player resources resolve by key")
  assert(type(collaborators.resources.release) == "function", "player resources release by lease")
  assert(type(collaborators.tasks) == "table", "the animation player requires its task factory")
  assert(type(collaborators.tasks.create) == "function", "player tasks construct by kind")
  return setmetatable({
    _scene = collaborators.scene,
    _audio = collaborators.audio,
    _resources = collaborators.resources,
    _tasks = collaborators.tasks,
    _occurrences = {},
    _byId = {},
    _nextId = 1,
    _disposed = false,
  }, BattleAnimationPlayer)
end

---@param program table<string, unknown> normalized program under admission
---@return table<string, unknown> validation view behind the shared program shape
local function validationView(program)
  local view = {
    entry = program.entry,
    instructions = {},
    subprograms = program.subprograms,
    taskKinds = program.taskKinds,
  }
  local instructions = program.instructions --[[@as table<integer, table<string, unknown>>]]
  for index, instruction in ipairs(instructions) do
    local copy = {}
    for field, value in pairs(instruction) do
      copy[field] = value
    end
    copy.taskInputRule = nil
    copy.taskStartRule = nil
    view.instructions[index] = copy
  end
  return view
end

---@param playback unknown playback packet carrying launch and packet identity
---@return boolean admitted true for a packet the player can bind
local function validPlayback(playback)
  if type(playback) ~= "table" then
    return false
  end
  local packet = playback --[[@as table<string, unknown>]]
  if type(packet.launchId) ~= "string" or packet.launchId == "" then
    return false
  end
  return type(packet.packetId) == "number" and packet.packetId % 1 == 0 and packet.packetId >= 1
end

-- Starts one occurrence bound to an immutable playback packet and a
-- complete normalized program. Structural failures refuse admission
-- with nil and never raise; a statically detected zero-time control
-- cycle is recorded and fails on the first source tick instead.
---@param self BattleAnimationPlayer
---@param playback table<string, unknown> immutable occurrence context and identity
---@param program table<string, unknown> complete normalized program under execution
---@return table<string, unknown>? handle opaque occurrence handle, when admitted
function BattleAnimationPlayer:start(playback, program)
  if self._disposed or not validPlayback(playback) or type(program) ~= "table" then
    return nil
  end
  local probe = program --[[@as table<string, unknown>]]
  -- The shared shape validates every structural field; the input and
  -- start rules stay opaque passthrough strings at this boundary (the
  -- producer owns their vocabulary and the factory receives them
  -- verbatim), so hand-built and compiler-lowered programs validate
  -- alike while unknown operations still fail admission.
  local ok, _ = pcall(BattleAnimationSchema.assertProgram, validationView(probe))
  if not ok then
    return nil
  end
  local instructions = probe.instructions --[[@as table<integer, table<string, unknown>>]]
  for index, instruction in ipairs(instructions) do
    local admitted, _ = BattleAnimationCommands.admit(instruction, index, #instructions)
    if not admitted then
      return nil
    end
  end
  local scratch = {}
  for _ = 1, 10 do
    scratch[#scratch + 1] = 0
  end
  local loopSlots = {}
  for _ = 1, 3 do
    loopSlots[#loopSlots + 1] = { active = false }
  end
  local packet = playback --[[@as table<string, unknown>]]
  local id = self._nextId
  self._nextId = id + 1
  local occurrence = {
    id = id,
    launchId = packet.launchId,
    packetId = packet.packetId,
    programKey = probe.key,
    program = program,
    phase = "preparing",
    pc = 1,
    scratch = scratch,
    callStack = {},
    loopSlots = loopSlots,
    owned = {},
    voices = {},
    leases = {},
    journal = {},
    wait = nil,
    endPhase = 0,
    endPark = 0,
    cycleFault = BattleAnimationCommands.checkCycles(instructions),
    packet = playback,
    fault = nil,
    cancelReason = nil,
    voiceSeq = 0,
    rawProgress = false,
    seed = 0,
    seedLatched = false,
    randomState = 0,
  }
  self._occurrences[#self._occurrences + 1] = occurrence
  self._byId[id] = occurrence
  return { id = id }
end

---@param self BattleAnimationPlayer
---@param handle table<string, unknown>? opaque occurrence handle under query
---@return table<string, unknown>? occurrence behind one handle
function BattleAnimationPlayer:_occurrence(handle)
  if type(handle) ~= "table" then
    return nil
  end
  return self._byId[handle.id]
end

-- Reports one occurrence phase without advancing anything: preparing,
-- running, waiting, complete, cancelled, or failed.
---@param self BattleAnimationPlayer
---@param handle table<string, unknown> opaque occurrence handle under query
---@return string? phase run state behind one handle
function BattleAnimationPlayer:status(handle)
  local occurrence = self:_occurrence(handle)
  if occurrence == nil then
    return nil
  end
  return occurrence.phase
end

-- Returns the failure detail behind a failed occurrence: launch and
-- packet identity with program, instruction, operation, and reason.
---@param self BattleAnimationPlayer
---@param handle table<string, unknown> opaque occurrence handle under query
---@return table<string, unknown>? detail failure provenance, when failed
function BattleAnimationPlayer:failure(handle)
  local occurrence = self:_occurrence(handle)
  if occurrence == nil then
    return nil
  end
  return occurrence.fault
end

---@param self BattleAnimationPlayer
---@param occurrence BattleAnimationOccurrence occurrence under teardown
local function releaseLeases(self, occurrence)
  for _, record in ipairs(occurrence.leases) do
    if not record.released then
      record.released = true
      pcall(self._resources.release, record.lease)
    end
  end
end

---@param self BattleAnimationPlayer
---@param occurrence BattleAnimationOccurrence occurrence under teardown
local function stopVoices(self, occurrence)
  for _, voice in ipairs(occurrence.voices) do
    if not voice.stopped then
      voice.stopped = true
      pcall(self._audio.stop, voice.key)
    end
  end
end

---@param record table<string, unknown> owned task under retirement
local function retireRecord(record)
  if record.retired then
    return
  end
  record.retired = true
  pcall(record.task.dispose, record.task)
end

---@param occurrence BattleAnimationOccurrence occurrence under teardown
---@param reason string cancellation cause under diagnosis
local function retireTasks(occurrence, reason)
  for _, record in ipairs(occurrence.owned) do
    if not record.retired then
      record.retired = true
      pcall(record.task.cancel, record.task, reason)
      pcall(record.task.dispose, record.task)
    end
  end
end

---@param self BattleAnimationPlayer
---@param occurrence BattleAnimationOccurrence occurrence entering a terminal state
---@param phase string cancelled, failed, or complete
---@param fault table<string, unknown>? failure detail behind failed
local function settle(self, occurrence, phase, fault)
  if LIVE_PHASES[occurrence.phase] ~= true then
    return
  end
  occurrence.wait = nil
  if phase == "complete" then
    stopVoices(self, occurrence)
    releaseLeases(self, occurrence)
  else
    retireTasks(occurrence, occurrence.cancelReason or "animation occurrence ends")
    stopVoices(self, occurrence)
    releaseLeases(self, occurrence)
  end
  occurrence.phase = phase
  occurrence.fault = fault
end

---@param self BattleAnimationPlayer
---@param occurrence BattleAnimationOccurrence occurrence under failure
---@param reason string failure cause under diagnosis
local function failOccurrence(self, occurrence, reason)
  if LIVE_PHASES[occurrence.phase] ~= true then
    return
  end
  local program = occurrence.program --[[@as table<string, unknown>]]
  local instructions = program.instructions --[[@as table<integer, table<string, unknown>>]]
  local current = instructions[occurrence.pc]
  local op = type(current) == "table" and current.op or nil
  settle(self, occurrence, "failed", {
    launchId = occurrence.launchId,
    packetId = occurrence.packetId,
    programKey = occurrence.programKey,
    instructionIndex = occurrence.pc,
    op = op,
    reason = reason,
  })
end

---@param occurrence BattleAnimationOccurrence occurrence behind task construction
---@return table<string, unknown> occurrence-bound factory context
local function taskContext(occurrence)
  local packet = occurrence.packet --[[@as table<string, unknown>]]
  local topology = nil ---@type table<string, unknown>?
  local event = nil ---@type table<string, unknown>?
  local visualSeed = nil ---@type integer?
  if type(packet) == "table" then
    if type(packet.topology) == "table" then
      topology = packet.topology --[[@as table<string, unknown>]]
    end
    if type(packet.event) == "table" then
      event = packet.event --[[@as table<string, unknown>]]
    end
    if type(packet.visualSeed) == "number" then
      visualSeed = packet.visualSeed --[[@as integer]]
    end
  end
  local function occurrenceRandom(bound)
    assert(type(bound) == "number" and bound >= 1, "visual draws name a positive bound")
    occurrence.randomState = (occurrence.randomState * 1103515245 + 12345) % 2147483648
    return occurrence.randomState % math.floor(bound)
  end
  return {
    launchId = occurrence.launchId,
    packetId = occurrence.packetId,
    programKey = occurrence.programKey,
    seed = occurrence.seed,
    random = occurrenceRandom,
    topology = topology,
    event = event,
    visualSeed = visualSeed,
  }
end

-- Builds the narrow capability facade one occurrence executes through.
-- Every collaborator call is validated and construction failures fail
-- the occurrence with instruction provenance instead of leaking.
---@param self BattleAnimationPlayer
---@param occurrence BattleAnimationOccurrence occurrence behind execution
---@return BattleAnimationExec facade behind BattleAnimationCommands
function BattleAnimationPlayer:_exec(occurrence)
  local player = self
  local program = occurrence.program --[[@as table<string, unknown>]]
  local instructions = program.instructions --[[@as table<integer, table<string, unknown>>]]
  local count = #instructions
  local exec = {}
  function exec.advance()
    occurrence.pc = occurrence.pc + 1
  end
  function exec.jump(target)
    if type(target) ~= "number" or target % 1 ~= 0 or target < 1 or target > count + 1 then
      player:_failWith(occurrence, "control destination leaves the instruction stream")
      return
    end
    occurrence.pc = target
  end
  function exec.park(wait)
    occurrence.wait = wait
    occurrence.phase = "waiting"
    return "park"
  end
  function exec.wait()
    return occurrence.wait
  end
  function exec.setWait(wait)
    occurrence.wait = wait
  end
  function exec.clearWait()
    occurrence.wait = nil
  end
  function exec.fail(reason)
    failOccurrence(player, occurrence, reason)
  end
  function exec.spawn(kind, group, args)
    if type(kind) ~= "string" or kind == "" then
      failOccurrence(player, occurrence, "task construction names no task kind")
      return nil
    end
    if TASK_GROUPS[group] ~= true or type(args) ~= "table" then
      failOccurrence(player, occurrence, "task construction carries no valid group and arguments")
      return nil
    end
    local ok, task = pcall(player._tasks.create, kind, args, taskContext(occurrence), {
      scene = player._scene,
      audio = player._audio,
      resources = player._resources,
    })
    if not ok then
      failOccurrence(player, occurrence, "child construction failure: " .. tostring(task))
      return nil
    end
    if
      type(task) ~= "table"
      or type(task.stepSourceTick) ~= "function"
      or type(task.status) ~= "function"
      or type(task.cancel) ~= "function"
      or type(task.dispose) ~= "function"
    then
      failOccurrence(player, occurrence, "task construction returned no runnable task for kind " .. kind)
      return nil
    end
    local record = { kind = kind, task = task, group = group, args = args, retired = false }
    occurrence.owned[#occurrence.owned + 1] = record
    return record
  end
  function exec.lease(key)
    if type(key) ~= "string" or key == "" then
      failOccurrence(player, occurrence, "resource staging names no resource key")
      return nil
    end
    local ok, lease = pcall(player._resources.resolve, key)
    if not ok then
      failOccurrence(player, occurrence, "required resource failure: " .. tostring(lease))
      return nil
    end
    -- An empty acquisition stages nothing: only a genuine lease joins
    -- the occurrence journal, so there is nothing to release later.
    if lease == nil then
      failOccurrence(player, occurrence, "required resource failure: no lease staged for key " .. key)
      return nil
    end
    local record = { key = key, lease = lease, released = false }
    occurrence.leases[#occurrence.leases + 1] = record
    return record
  end
  function exec.play(key, extra)
    if type(key) ~= "string" or key == "" then
      failOccurrence(player, occurrence, "voice playback names no voice")
      return nil
    end
    local ok, err = pcall(player._audio.play, key, extra)
    if not ok then
      failOccurrence(player, occurrence, "voice playback failure: " .. tostring(err))
      return nil
    end
    occurrence.voices[#occurrence.voices + 1] = { key = key, tag = "sound", stopped = false, finished = false }
    return key
  end
  function exec.playCry(values)
    if type(values) ~= "table" then
      failOccurrence(player, occurrence, "cry playback carries no voice facts")
      return nil
    end
    local key = "battle-animation-cry-"
      .. tostring(values[1])
      .. "-"
      .. tostring(values[2])
      .. "-"
      .. tostring(values[3])
    local ok, err = pcall(player._audio.play, key)
    if not ok then
      failOccurrence(player, occurrence, "cry playback failure: " .. tostring(err))
      return nil
    end
    occurrence.voices[#occurrence.voices + 1] = { key = key, tag = "cry", stopped = false, finished = false }
    return key
  end
  function exec.stopSound(sound)
    for _, voice in ipairs(occurrence.voices) do
      if voice.key == sound and not voice.stopped then
        voice.stopped = true
        pcall(player._audio.stop, voice.key)
      end
    end
  end
  local function queryFinished(voice)
    if voice.stopped or voice.finished then
      return true
    end
    local ok, done = pcall(player._audio.isFinished, voice.key)
    if not ok then
      failOccurrence(player, occurrence, "voice completion query failure: " .. tostring(done))
      return nil
    end
    if done then
      voice.finished = true
    end
    return done == true
  end
  function exec.voiceFinished(key)
    for index = #occurrence.voices, 1, -1 do
      if occurrence.voices[index].key == key then
        return queryFinished(occurrence.voices[index])
      end
    end
    failOccurrence(player, occurrence, "voice completion queries a voice this occurrence never staged")
    return nil
  end
  function exec.unfinishedVoice()
    for index = #occurrence.voices, 1, -1 do
      local voice = occurrence.voices[index]
      if voice.tag == "sound" and not voice.stopped and not voice.finished then
        return voice.key
      end
    end
    return nil
  end
  function exec.unfinishedCry()
    for index = #occurrence.voices, 1, -1 do
      local voice = occurrence.voices[index]
      if voice.tag == "cry" and not voice.stopped and not voice.finished then
        return voice.key
      end
    end
    return nil
  end
  function exec.cryFinished()
    local key = exec.unfinishedCry()
    if key == nil then
      return true
    end
    return exec.voiceFinished(key)
  end
  function exec.stageVoice(index)
    occurrence.voiceSeq = occurrence.voiceSeq + 1
    local key = "battle-animation-wait-voice-" .. index .. "-" .. occurrence.voiceSeq
    if exec.lease(key) == nil then
      return nil
    end
    if exec.play(key) == nil then
      return nil
    end
    local monitor = exec.spawn(player.VOICE_TASK_KIND, "raw", { voice = key })
    if monitor == nil then
      return nil
    end
    return key
  end
  function exec.retireVoiceMonitor(voice)
    for _, record in ipairs(occurrence.owned) do
      if
        not record.retired
        and record.kind == player.VOICE_TASK_KIND
        and type(record.args) == "table"
        and record.args.voice == voice
      then
        retireRecord(record)
      end
    end
  end
  function exec.count(group)
    local total = 0
    for _, record in ipairs(occurrence.owned) do
      if not record.retired and record.group == group then
        total = total + 1
      end
    end
    return total
  end
  function exec.rawCompleted()
    return occurrence.rawProgress
  end
  function exec.getParam(slot)
    return occurrence.scratch[slot + 1]
  end
  function exec.setParam(slot, value)
    occurrence.scratch[slot + 1] = value
  end
  function exec.zeroParams()
    for index = 1, 10 do
      occurrence.scratch[index] = 0
    end
  end
  function exec.callDepth()
    return #occurrence.callStack
  end
  function exec.pushCall(target)
    occurrence.callStack[#occurrence.callStack + 1] = target
  end
  function exec.popCall()
    if #occurrence.callStack == 0 then
      return nil
    end
    return table.remove(occurrence.callStack)
  end
  function exec.loopBegin(loopCount, start)
    for _, slot in ipairs(occurrence.loopSlots) do
      if not slot.active then
        slot.active = true
        slot.count = loopCount
        slot.counter = 0
        slot.start = start
        return true
      end
    end
    return false
  end
  function exec.loopAdvance()
    for index = #occurrence.loopSlots, 1, -1 do
      local slot = occurrence.loopSlots[index]
      if slot.active then
        slot.counter = slot.counter + 1
        if slot.counter == slot.count then
          slot.active = false
          return "finished"
        end
        return "rewound"
      end
    end
    return "none"
  end
  function exec.loopStart()
    for index = #occurrence.loopSlots, 1, -1 do
      local slot = occurrence.loopSlots[index]
      if slot.active then
        return slot.start
      end
    end
    return occurrence.pc + 1
  end
  function exec.topology()
    local packet = occurrence.packet
    if type(packet) == "table" and type(packet.topology) == "table" then
      return packet.topology
    end
    return nil
  end
  function exec.eventIdentity()
    local packet = occurrence.packet
    if type(packet) == "table" and type(packet.event) == "table" then
      return packet.event
    end
    return nil
  end
  -- Reports the admitted occurrence move phase behind charge/strike
  -- dispatch. Only the two kernel-emitted phases select a half; a
  -- missing move record or any other phase value stays unresolved so
  -- the caller fails closed instead of guessing a presentation path.
  function exec.movePhase()
    local packet = occurrence.packet
    if type(packet) ~= "table" or type(packet.event) ~= "table" then
      return nil
    end
    local move = packet.event.move --[[@as unknown]]
    if type(move) ~= "table" then
      return nil
    end
    local phase = (move --[[@as table<string, unknown>]]).phase
    if phase ~= "charge" and phase ~= "direct" then
      return nil
    end
    return phase --[[@as string]]
  end
  function exec.activationFor(selector)
    if type(selector) ~= "number" or selector % 1 ~= 0 or selector < 0 then
      return nil
    end
    local packet = occurrence.packet
    if type(packet) ~= "table" or type(packet.topology) ~= "table" then
      return nil
    end
    local topology = packet.topology --[[@as table<string, unknown>]]
    -- Selector zero names the event attacker; any other selector names
    -- the event target at that ordinal. Anything unaddressed stays
    -- unresolved instead of guessing from scene entries.
    if selector == 0 then
      local attacker = topology.attacker --[[@as table<string, unknown>?]]
      if type(attacker) == "table" and type(attacker.combatant) == "number" and attacker.activation ~= nil then
        return { combatant = attacker.combatant, activation = attacker.activation }
      end
      return nil
    end
    local targets = topology.targets --[[@as table<integer, table<string, unknown>>?]]
    if type(targets) == "table" then
      local target = targets[selector] --[[@as table<string, unknown>?]]
      if type(target) == "table" and type(target.combatant) == "number" and target.activation ~= nil then
        return { combatant = target.combatant, activation = target.activation }
      end
    end
    return nil
  end
  function exec.note(entry)
    occurrence.journal[#occurrence.journal + 1] = entry
  end
  return exec
end

---@param self BattleAnimationPlayer
---@param occurrence BattleAnimationOccurrence occurrence under failure
---@param reason string failure cause under diagnosis
function BattleAnimationPlayer:_failWith(occurrence, reason)
  failOccurrence(self, occurrence, reason)
end

---@param self BattleAnimationPlayer
---@param occurrence BattleAnimationOccurrence occurrence under task stepping
---@param tick table<string, unknown> source tick under advancement
---@return boolean live true while the occurrence stays under execution
function BattleAnimationPlayer:_stepTasks(occurrence, tick)
  for _, record in ipairs({ (table.unpack or unpack)(occurrence.owned) }) do
    if not record.retired then
      local ok, err = pcall(record.task.stepSourceTick, record.task, tick)
      if not ok then
        failOccurrence(
          self,
          occurrence,
          "child task failure for kind " .. tostring(record.kind) .. ": " .. tostring(err)
        )
        return false
      end
      local pok, state = pcall(record.task.status, record.task)
      if not pok then
        failOccurrence(self, occurrence, "child task status failure for kind " .. tostring(record.kind))
        return false
      end
      if state == "complete" then
        if record.group == "raw" then
          occurrence.rawProgress = true
        end
        retireRecord(record)
      elseif state == "failed" then
        failOccurrence(self, occurrence, "child task reported failure for kind " .. tostring(record.kind))
        return false
      elseif TASK_STATES[state] ~= true then
        failOccurrence(self, occurrence, "child task reported an unknown state for kind " .. tostring(record.kind))
        return false
      end
    end
    if LIVE_PHASES[occurrence.phase] ~= true then
      return false
    end
  end
  return LIVE_PHASES[occurrence.phase] == true
end

---@param self BattleAnimationPlayer
---@param occurrence BattleAnimationOccurrence occurrence behind completion
---@return boolean verified true once the source completion condition holds
---@return string? hold tasks or voices behind the remaining hold, when unverified
local function verifyCompletion(self, occurrence)
  local execCount = { general = 0, sound = 0, particle = 0 }
  for _, record in ipairs(occurrence.owned) do
    if not record.retired and execCount[record.group] ~= nil then
      execCount[record.group] = execCount[record.group] + 1
    end
  end
  if execCount.general ~= 0 or execCount.sound ~= 0 or execCount.particle ~= 0 then
    return false, "tasks"
  end
  for _, voice in ipairs(occurrence.voices) do
    if not voice.stopped and not voice.finished then
      local ok, done = pcall(self._audio.isFinished, voice.key)
      if not ok then
        failOccurrence(self, occurrence, "voice completion query failure: " .. tostring(done))
        return false, nil
      end
      if done then
        voice.finished = true
      else
        return false, "voices"
      end
    end
  end
  return true, nil
end

---@param self BattleAnimationPlayer
---@param occurrence BattleAnimationOccurrence occurrence behind stream-end handling
local function streamEnd(self, occurrence)
  if occurrence.endPhase == 0 then
    occurrence.endPhase = 1
    occurrence.phase = "waiting"
    return
  end
  local verified, hold = verifyCompletion(self, occurrence)
  if verified then
    settle(self, occurrence, "complete", nil)
    return
  end
  if LIVE_PHASES[occurrence.phase] ~= true then
    return
  end
  if hold == "voices" then
    occurrence.endPark = occurrence.endPark + 1
    if occurrence.endPark > VOICE_ESCAPE_TICKS then
      settle(self, occurrence, "complete", nil)
      return
    end
  end
  occurrence.phase = "waiting"
end

-- Per-tick immediate-chain budget behind the residual cycles static
-- analysis cannot see (return destinations resolve on the dynamic call
-- stack). Admitted loops provably terminate on their counts and
-- subprogram nesting is depth-guarded, so only a pathological program
-- reaches the budget, and it fails with provenance instead of hanging.
local CHAIN_BUDGET_PER_TICK = 65536

---@param self BattleAnimationPlayer
---@param occurrence BattleAnimationOccurrence occurrence under advancement
---@param tick table<string, unknown> source tick under advancement
local function runChain(self, occurrence, tick)
  local _ = tick
  local program = occurrence.program --[[@as table<string, unknown>]]
  local instructions = program.instructions --[[@as table<integer, table<string, unknown>>]]
  local exec = self:_exec(occurrence)
  local budget = CHAIN_BUDGET_PER_TICK
  while true do
    if LIVE_PHASES[occurrence.phase] ~= true then
      return
    end
    budget = budget - 1
    if budget <= 0 then
      failOccurrence(self, occurrence, "immediate chain exceeded its per-tick budget")
      return
    end
    local instruction = instructions[occurrence.pc]
    if instruction == nil then
      streamEnd(self, occurrence)
      return
    end
    local ok, disposition = pcall(BattleAnimationCommands.execute, exec, instruction, occurrence.pc)
    if not ok then
      failOccurrence(self, occurrence, "command execution failure: " .. tostring(disposition))
      return
    end
    if disposition ~= "continue" then
      if disposition ~= "park" and disposition ~= "done" then
        failOccurrence(self, occurrence, "command reported an unknown disposition")
      end
      return
    end
  end
end

---@param self BattleAnimationPlayer
---@param occurrence BattleAnimationOccurrence occurrence under advancement
---@param tick table<string, unknown> source tick under advancement
local function runOccurrence(self, occurrence, tick)
  if occurrence.phase == "preparing" then
    occurrence.phase = "running"
    if occurrence.cycleFault ~= nil then
      local fault = occurrence.cycleFault --[[@as table<string, unknown>]]
      occurrence.pc = fault.index --[[@as integer]]
      failOccurrence(self, occurrence, tostring(fault.reason))
      return
    end
  else
    occurrence.phase = "running"
  end
  if not self:_stepTasks(occurrence, tick) then
    return
  end
  runChain(self, occurrence, tick)
end

-- Advances each admitted live occurrence once in stable admission order
-- on one source tick. Reads and draws never advance: only this entry
-- point steps tasks and runs immediate chains.
---@param self BattleAnimationPlayer
---@param tick table<string, unknown>? source tick carrying tick identity and visual seed
function BattleAnimationPlayer:stepSourceTick(tick)
  if self._disposed then
    return
  end
  local quantum = tick
  if type(quantum) ~= "table" then
    quantum = {}
  end
  for _, occurrence in ipairs(self._occurrences) do
    if LIVE_PHASES[occurrence.phase] == true then
      if not occurrence.seedLatched then
        occurrence.seedLatched = true
        if type(quantum.seed) == "number" then
          occurrence.seed = math.floor(quantum.seed)
        end
        occurrence.randomState = occurrence.seed % 2147483648
      end
      runOccurrence(self, occurrence, quantum)
    end
  end
end

-- Cancels one occurrence with a reason: children are retired, owned
-- awaited voices stop where the abort policy requires it, leases
-- release, and only journaled state still owned is restored. Cancelling
-- a terminal occurrence is silent, and a cancelled occurrence can never
-- acquire resources or mutate another occurrence again.
---@param self BattleAnimationPlayer
---@param handle table<string, unknown> opaque occurrence handle under cancellation
---@param reason string cancellation cause under diagnosis
function BattleAnimationPlayer:cancel(handle, reason)
  local occurrence = self:_occurrence(handle)
  if occurrence == nil or LIVE_PHASES[occurrence.phase] ~= true then
    return
  end
  occurrence.cancelReason = reason
  settle(self, occurrence, "cancelled", nil)
end

-- Releases every owned visual, voice, lease, and task exactly once. The
-- call is idempotent and never changes a terminal occurrence phase.
function BattleAnimationPlayer:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  for _, occurrence in ipairs(self._occurrences) do
    if LIVE_PHASES[occurrence.phase] == true then
      occurrence.cancelReason = occurrence.cancelReason or "player released"
      settle(self, occurrence, "cancelled", nil)
    else
      releaseLeases(self, occurrence)
      stopVoices(self, occurrence)
      retireTasks(occurrence, "player released")
    end
  end
end

return BattleAnimationPlayer
