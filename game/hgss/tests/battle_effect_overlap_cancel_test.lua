-- Overlapping native effects at the production task boundary: tasks
-- that change different targets and layers compose, cancelling one
-- releases exactly its own pictures, leases, and voices, replacing an
-- actor never lets a stale restore overwrite the new owner, and the next
-- valid occurrence still runs normally. Setup below holds today through
-- the real scene path; the execution gate drives the battle-private
-- program player together with the battle-private effect task factory
-- once both exist.
-- Native mechanism: occurrence-owned picture, background, palette, and
-- sound state with source overlap and priority rules
-- (pret/pokeheartgold@9d8b7591f09b65804da2fb2dfd56f320633e0d36).
-- Headless: synthetic command streams use the real producer lowering and
-- the shared program shape; the recorder doubles record only.

local Assert = require("tests.support.Assert")
local BattleAnimationCompiler = require("romdump.src.digest.battle.BattleAnimationCompiler")
local BattleAnimationSchema = require("libs.assets.src.battle.BattleAnimationSchema")
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

local function lowered(key, list)
  local program = assert(BattleAnimationCompiler.compile({ key = key, stream = streamOf(list) }))
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
    launchId = "overlap-cancel-probe",
    packetId = 1,
  })
  Assert.equal(packet.launchId, "overlap-cancel-probe", "the playback input carries its launch identity")
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

function T.effect_records_release_exactly_once_and_stay_silent_afterward()
  local scene = sceneWithPair()
  local first = scene:allocEffect("overlap-probe")
  local second = scene:allocEffect("overlap-probe")
  Assert.isTrue(second.id ~= first.id, "two overlapping effects hold distinct identities")
  scene:setEffectPicture(first.id, {
    assetKey = "staged-first",
    selector = "first",
    centerX = 64,
    centerY = 112,
    zCenter = 0,
    width = 64,
    height = 64,
    alpha = 1,
  })
  scene:releaseEffect(first.id)
  scene:releaseEffect(first.id)
  scene:releaseEffect(99999)
  local views = scene:effectViews()
  Assert.equal(#views, 1, "only the surviving effect still publishes")
  Assert.equal(views[1].id, second.id, "the survivor keeps its own identity")
  scene:release()
  scene:release()
  Assert.equal(#scene:effectViews(), 0, "launch release drops every owned record")
end

function T.picture_state_stays_keyed_by_activation_across_replacement()
  local scene = sceneWithPair()
  local outgoing = { combatant = 1, activation = 1 }
  local staying = { combatant = 3, activation = 3 }
  scene:applyPictureState(outgoing, { pictureXOffset2 = 40 })
  Assert.equal(
    scene:pictureState(outgoing).pictureXOffset2,
    40,
    "the outgoing activation carries its temporary change"
  )
  Assert.isNil(scene:pictureState(staying), "the untouched activation exposes no patched view")
  scene:remove(1, 1)
  Assert.isNil(scene:pictureState(outgoing), "the withdrawn activation leaves no patched view behind")
  Assert.isNil(scene:pictureState(staying), "withdrawing one activation never touches the other")
  scene:observe({ { combatant = 1, activation = 2, visible = true } })
  local incoming = { combatant = 1, activation = 2 }
  Assert.isNil(scene:pictureState(incoming), "the replacement starts without the old change")
  scene:restorePictureState(outgoing)
  Assert.isNil(scene:pictureState(incoming), "restoring the old activation never reaches the replacement")
end

function T.overlapping_tasks_cancel_and_replace_without_stale_restores()
  local firstProgram = lowered("overlap-first", { 51, 0, 27, 50, 4 })
  local secondProgram = lowered("overlap-second", { 51, 0, 27, 50, 4 })
  local Player = playerModule()
  local Factory = effectFactoryModule()
  local scene = sceneWithPair()
  local journals = {}
  local function collaborators(key)
    local journal = { acquired = {}, released = {}, played = {}, stopped = {} }
    journals[key] = journal
    local audio = {}
    function audio.play(name)
      journal.played[#journal.played + 1] = name
    end
    function audio.stop(name)
      journal.stopped[#journal.stopped + 1] = name
    end
    function audio.isFinished(_name)
      return true
    end
    local resources = {}
    function resources.resolve(name)
      journal.acquired[#journal.acquired + 1] = name
      local params = {}
      for index = 1, 42 do
        params[index] = 0
      end
      params[29], params[30], params[24], params[32] = 12, 12, 0, 1
      return {
        key = name,
        kind = "particle-emitter",
        payloadPath = "probe/particle-emitter",
        data = { features = { "alpha", "random" }, params = params },
      }
    end
    function resources.release(lease)
      journal.released[#journal.released + 1] = lease
    end
    return { audio = audio, resources = resources, journal = journal }
  end
  local first = collaborators("first")
  local runner = assert(Player.new({
    scene = scene,
    audio = first.audio,
    resources = first.resources,
    tasks = Factory,
  }))
  local surviving = assert(runner:start(playbackPacket(), firstProgram))
  local cancelled = assert(runner:start(playbackPacket(), secondProgram))
  runner:stepSourceTick({ tick = 1 })
  runner:cancel(cancelled, "overlap-superseded")
  Assert.equal(runner:status(cancelled), "cancelled", "the cancelled task lands on cancelled")
  Assert.isTrue(runner:status(surviving) ~= "cancelled", "the surviving task keeps its own state")
  scene:remove(1, 1)
  scene:observe({ { combatant = 1, activation = 2, visible = true } })
  for _ = 1, 60 do
    runner:stepSourceTick({ tick = 1 })
    if runner:status(surviving) == "complete" then
      break
    end
  end
  Assert.equal(runner:status(surviving), "complete", "the survivor completes after the replacement")
  Assert.isNil(
    scene:pictureState({ combatant = 1, activation = 2 }),
    "no stale restore overwrites the replacement owner"
  )
  local journal = assert(journals.first, "the occurrence journal is retained")
  Assert.equal(#journal.released, #journal.acquired, "the occurrence releases exactly its own leases")
  Assert.equal(#journal.stopped, #journal.played, "the occurrence stops exactly its own voices")
  local fresh = collaborators("fresh")
  local nextRunner = assert(Player.new({
    scene = scene,
    audio = fresh.audio,
    resources = fresh.resources,
    tasks = Factory,
  }))
  local nextHandle = assert(nextRunner:start(playbackPacket(), firstProgram))
  for _ = 1, 60 do
    nextRunner:stepSourceTick({ tick = 1 })
    if nextRunner:status(nextHandle) == "complete" then
      break
    end
  end
  Assert.equal(nextRunner:status(nextHandle), "complete", "the next valid occurrence still runs normally")
end

function T.pair_affine_transition_moves_both_activations_and_restores()
  local Factory = effectFactoryModule()
  local scene = BattleScene.new()
  local attacker = { combatant = 1, activation = 1 }
  local partner = { combatant = 3, activation = 3 }
  scene:observe({
    { combatant = 1, activation = 1, visible = true },
    { combatant = 3, activation = 3, visible = true },
  })
  local journal = { acquired = {}, released = {} }
  local resources = {}
  function resources.resolve(key)
    journal.acquired[#journal.acquired + 1] = key
    return { key = key, lease = key }
  end
  function resources.release(lease)
    journal.released[#journal.released + 1] = lease
  end
  local context = {
    launchId = "pair-affine-probe",
    visualSeed = 4242,
    random = function(bound)
      assert(type(bound) == "number" and bound >= 1, "visual draws name a positive bound")
      return 0
    end,
    topology = {
      attacker = { combatant = 1, activation = 1, slot = "solo-player", sideType = 0 },
      targets = { { combatant = 3, activation = 3, slot = "solo-enemy", sideType = 1 } },
    },
  }
  local services = { scene = scene, audio = {}, resources = resources }
  local task = assert(Factory.create("pokemon-picture-battler-pair-scale-transition", {
    battlerTarget = "attacker",
    activation = attacker,
    parameters = { durationTicks = 16, scaleStart = 256, scaleEnd = 384 },
  }, context, services))
  for _ = 1, 4 do
    task:stepSourceTick({ tick = 1 })
  end
  local attackerPatch = scene:pictureState(attacker)
  local partnerPatch = scene:pictureState(partner)
  Assert.notNil(attackerPatch, "the running pair transition moves the attacker")
  Assert.notNil(partnerPatch, "the running pair transition moves the pair partner too")
  Assert.isTrue(attackerPatch.scaleX ~= nil and partnerPatch.scaleX ~= nil, "both activations carry the affine scale")
  Assert.equal(attackerPatch.scaleX, partnerPatch.scaleX, "the pair scales together")
  for _ = 1, 12 do
    task:stepSourceTick({ tick = 1 })
  end
  Assert.equal(task:status(), "complete", "the pair transition completes at its duration")
  Assert.isNil(scene:pictureState(attacker), "completion restores the attacker")
  Assert.isNil(scene:pictureState(partner), "completion restores the partner")
  task:dispose()
  local cancelling = assert(Factory.create("pokemon-picture-battler-pair-scale-transition", {
    battlerTarget = "attacker",
    activation = attacker,
    parameters = { durationTicks = 16, scaleStart = 256, scaleEnd = 384 },
  }, context, services))
  cancelling:stepSourceTick({ tick = 1 })
  cancelling:stepSourceTick({ tick = 1 })
  cancelling:cancel("superseded")
  Assert.equal(cancelling:status(), "cancelled", "cancellation lands on cancelled")
  Assert.isNil(scene:pictureState(attacker), "cancellation restores the attacker")
  Assert.isNil(scene:pictureState(partner), "cancellation restores the partner without touching others")
  cancelling:dispose()
  Assert.equal(#journal.released, #journal.acquired, "the pair run leaks no lease")
end

-- Live-screen handle plumbing behind the parked and running probes: the
-- real screen over a staged-effect double, with portrait draws served
-- from memory so the occurrence map and the player stay observable.
---@param launchId string owning launch identity under test preparation
---@param staging table staged-effect fixture under test preparation
---@return table preparation services serving portraits plus the fixture services
local function overlapScreenServices(staging)
  local portraits = { images = {} }
  function portraits.prepare(_demand)
    return true
  end
  function portraits.drawable(key)
    if portraits.images[key] == nil then
      portraits.images[key] = {
        handle = key,
        width = 80,
        height = 80,
        getWidth = function()
          return 80
        end,
        getHeight = function()
          return 80
        end,
        getDimensions = function()
          return 80, 80
        end,
        setFilter = function() end,
      }
    end
    return portraits.images[key]
  end
  function portraits.release(_key) end
  local services = {}
  function services.prepare(demand)
    return portraits.prepare(demand)
  end
  function services.drawable(key)
    local staged = staging.services.drawable(key)
    if staged ~= nil then
      return staged
    end
    return portraits.drawable(key)
  end
  function services.release(key)
    portraits.release(key)
    return staging.services.release(key)
  end
  function services.requestEffect(key)
    return staging.services.requestEffect(key)
  end
  function services.loadEffect(key)
    return staging.services.loadEffect(key)
  end
  function services.resolveEffectResource(effect, resourceKey)
    return staging.services.resolveEffectResource(effect, resourceKey)
  end
  function services.releaseEffectResource(lease)
    return staging.services.releaseEffectResource(lease)
  end
  return services
end

---@param hp integer foe health under test driving
---@return table detached foe record under test driving
local function overlapFoeRecord(hp)
  return {
    combatant = 3,
    participant = 3,
    side = 2,
    controller = "wild",
    active = true,
    hp = hp,
    maxHp = 57,
    species = "EEVEE",
    form = 0,
    name = "FOE",
    level = 20,
    selector = "front",
  }
end

---@return table detached own lead record under test driving
local function overlapOwnRecord()
  return {
    combatant = 1,
    participant = 1,
    side = 1,
    controller = "player",
    active = true,
    hp = 52,
    maxHp = 52,
    species = "EEVEE",
    form = 0,
    name = "LEAD",
    level = 20,
    selector = "back",
    moves = { { move = "TACKLE", name = "Tackle", pp = 35, maxPp = 35 } },
  }
end

---@param foeHp integer foe health after the view under test driving
---@return table detached dynamic view under test driving
local function overlapView(foeHp)
  return { own = { overlapOwnRecord() }, foes = { overlapFoeRecord(foeHp) } }
end

---@param launchId string owning launch identity under test driving
---@param staging table staged-effect fixture under test driving
---@return table live screen behind the staged effect services
local function openOverlapScreen(launchId, staging)
  local BattleScreenState = require("game.hgss.src.battle.BattleScreenState")
  local Model = require("game.hgss.src.battle.BattlePresentationModel")
  local ManifestFixture = require("tests.support.BattlePresentationManifestFixture")
  local ScreenTopology = require("libs.ui.src.ScreenTopology")
  local manifest = ManifestFixture.manifest()
  manifest.scenes = { { key = "general/plain/day" } }
  local measurement = {
    width = 256,
    height = 384,
    topology = ScreenTopology.dualDisplay(
      { id = "main", rect = { x = 0, y = 0, width = 256, height = 192 }, touch = false, role = "world" },
      { id = "lower", rect = { x = 0, y = 192, width = 256, height = 192 }, touch = true, role = "auxiliary" }
    ),
    pixelRatio = 1,
    signature = "overlap-retire-probe:dual",
  }
  local text = {}
  function text.measure(content)
    return { width = 8 * #tostring(content), height = 16 }
  end
  function text.drawText(_content, _x, _y) end
  local windows = { calls = {} }
  function windows.drawWindow(box, frameKey, background)
    windows.calls[#windows.calls + 1] = { box = box, frame = frameKey, background = background }
  end
  local audio = { plays = {} }
  function audio.play(name)
    audio.plays[#audio.plays + 1] = name
    return true
  end
  return BattleScreenState.new({
    launchId = launchId,
    manifest = manifest,
    model = Model,
    submit = function(_reply)
      return true
    end,
    measureDisplay = function()
      return measurement
    end,
    assets = overlapScreenServices(staging),
    text = text,
    windows = windows,
    audio = audio,
  })
end

---@param screen table live screen under test driving
---@param launchId string owning launch identity under test driving
---@param packetId integer monotonic delivery identity under test driving
---@param strikes table[] strike events under test driving
local function presentOverlapStrikes(screen, launchId, packetId, strikes)
  local port = screen:presentationPort()
  port.present({
    launchId = launchId,
    packetId = packetId,
    events = strikes,
    before = overlapView(57),
    after = overlapView(43),
  })
end

---@param effectKey string semantic effect key under test driving
---@param actionId integer action identity under test driving
---@param sequence integer event sequence under test driving
---@return table production-shaped strike event
local function overlapStrike(effectKey, actionId, sequence)
  return {
    sequence = sequence,
    kind = "struck",
    cause = { key = effectKey },
    audience = "public",
    actors = { { combatant = 1 } },
    targets = { { combatant = 3 } },
    move = { executed = effectKey },
    actionId = actionId,
    hitIndex = sequence,
    effectKey = effectKey,
    payload = { target = 3, damage = 14, hitIndex = sequence },
    after = { hp = { [1] = 52, [3] = 43 } },
  }
end

---@param view table displayed screen view under inspection
---@return integer displayed foe health
local function overlapDisplayedFoeHp(view)
  for _, entry in ipairs(view.battlers or {}) do
    if entry.side == 2 then
      return entry.hp
    end
  end
  error("the displayed view names its foe", 0)
end

---@param map table native handle track map under inspection
---@return integer tracked entry count
local function trackCount(map)
  local total = 0
  for _ in pairs(map) do
    total = total + 1
  end
  return total
end

-- One parked token beside a running occurrence retires only at its own
-- completion: the parked cue stages nothing while the slow visual runs,
-- promotion keeps one stable track identity, the fast cue retires while
-- the slow one still runs, and repeated cancel and disposal stay silent
-- with balanced leases.
function T.parked_and_running_occurrences_retire_only_at_their_own_completion()
  local EffectStagingFixture = require("tests.support.EffectStagingFixture")
  local launchId = "launch-parked-beside-running"
  local staging = EffectStagingFixture.new({ launchId = launchId })
  local slowRecord = EffectStagingFixture.effectRecord("SLOW", {})
  slowRecord.program = {
    entry = "main",
    instructions = {
      { op = "interpreter-wait", values = { 30 } },
      { op = "reset-blend-alpha" },
    },
    subprograms = {},
    taskKinds = {},
  }
  staging:stageEffect("SLOW", slowRecord, {})
  local screen = openOverlapScreen(launchId, staging)
  local collaborator = screen._timeline._effects
  Assert.notNil(collaborator, "the screen routes native cues through its collaborator")
  presentOverlapStrikes(screen, launchId, 1, {})
  presentOverlapStrikes(screen, launchId, 2, { overlapStrike("SLOW", 62, 1) })
  local runningHandle = nil
  for _ = 1, 600 do
    screen:updateFixed(1 / 30)
    for _, track in pairs(screen._nativeHandles) do
      if track.effectKey == "SLOW" and track.handle ~= nil then
        runningHandle = track.handle
      end
    end
    if runningHandle ~= nil then
      break
    end
  end
  Assert.notNil(runningHandle, "the staged cue admits its handle")
  local phase = screen._player:status(runningHandle)
  Assert.isTrue(phase == "running" or phase == "waiting", "the running occurrence stays live: " .. tostring(phase))
  Assert.equal(#screen._player._occurrences, 1, "only the running cue steps")
  local parkedCue = {
    effectKey = "TACKLE",
    launchId = launchId,
    packetId = 99,
    eventSequence = 99,
    event = overlapStrike("TACKLE", 61, 99),
    visualSeed = 123,
    before = overlapView(57),
    after = overlapView(43),
  }
  local parkedToken = collaborator.start(parkedCue)
  Assert.notNil(parkedToken, "the unstaged cue parks behind its token")
  Assert.equal(collaborator.status(parkedToken), "pending", "the parked token reports pending")
  Assert.isNil(screen._nativeHandles[parkedToken].handle, "the parked token admits no handle yet")
  Assert.equal(#screen._player._occurrences, 1, "the parked token still stages nothing")
  local retiredSlow = false
  for _ = 1, 1500 do
    screen:updateFixed(1 / 30)
    if screen:status().mode == "failed" then
      break
    end
    if screen._nativeHandles[runningHandle] == nil then
      retiredSlow = true
      break
    end
  end
  Assert.isTrue(retiredSlow, "the slow cue retires at its consumption")
  Assert.isTrue(screen:status().mode ~= "failed", "completion never fails the launch")
  Assert.isNil(screen._player:status(runningHandle), "the retired slow handle answers nothing")
  Assert.notNil(screen._nativeHandles[parkedToken], "the parked token survives the slow retirement")
  Assert.isNil(screen._nativeHandles[parkedToken].handle, "the parked token still stages nothing")
  Assert.equal(#screen._player._occurrences, 0, "the retired slow cue leaves no occurrence record")
  for _ = 1, 600 do
    screen:updateFixed(1 / 30)
    if screen._timeline:settled() then
      break
    end
  end
  Assert.isTrue(screen._timeline:settled(), "the slow cue player drains fully")
  Assert.equal(overlapDisplayedFoeHp(screen:view()), 43, "the slow cue runs to its checkpoint")
  local tackleRecord = EffectStagingFixture.effectRecord("TACKLE", {})
  local tackleProgram = lowered("TACKLE", { 29, 50, 4 })
  tackleRecord.program = {
    entry = tackleProgram.entry,
    instructions = tackleProgram.instructions,
    subprograms = tackleProgram.subprograms,
    taskKinds = tackleProgram.taskKinds,
  }
  staging:stageEffect("TACKLE", tackleRecord, {})
  local fastHandle = nil
  for _ = 1, 600 do
    screen:updateFixed(1 / 30)
    if screen:status().mode == "failed" then
      break
    end
    local track = screen._nativeHandles[parkedToken]
    if track ~= nil and track.handle ~= nil then
      fastHandle = track.handle
      break
    end
  end
  Assert.notNil(fastHandle, "the staged token promotes to its handle")
  Assert.isTrue(screen._nativeHandles[parkedToken] ~= nil, "promotion keeps the stable token identity")
  for _ = 1, 1500 do
    screen:updateFixed(1 / 30)
    if collaborator.status(parkedToken) == "complete" then
      break
    end
  end
  Assert.equal(collaborator.status(parkedToken), "complete", "the promoted cue completes")
  Assert.isTrue(collaborator.retire(parkedToken) == true, "the consumer retires its completed cue")
  Assert.isNil(screen._nativeHandles[parkedToken], "the retired token leaves no track")
  Assert.isNil(screen._player:status(fastHandle), "the retired fast handle answers nothing")
  Assert.equal(#screen._player._occurrences, 0, "the retired fast cue leaves no occurrence record")
  Assert.isNil(screen._liveEffectHandle, "no live handle outlives its consumption")
  presentOverlapStrikes(screen, launchId, 3, { overlapStrike("TACKLE", 63, 3) })
  local seenHandles = {}
  for _ = 1, 1500 do
    screen:updateFixed(1 / 30)
    for _, track in pairs(screen._nativeHandles) do
      if track.handle ~= nil then
        seenHandles[track.handle] = true
      end
    end
    if screen._timeline:settled() then
      break
    end
  end
  Assert.isTrue(screen._timeline:settled(), "the timeline cue drains fully")
  Assert.isTrue(screen:status().mode ~= "failed", "the timeline cue never fails the launch")
  Assert.equal(trackCount(screen._nativeHandles), 0, "consumed cues leave no tracks")
  Assert.equal(#screen._player._occurrences, 0, "consumed cues leave no occurrence records")
  for handle in pairs(seenHandles) do
    Assert.isNil(screen._player:status(handle), "every consumed handle answers nothing")
  end
  collaborator.cancel(parkedToken, "late")
  collaborator.cancel(runningHandle, "late")
  collaborator.cancel(fastHandle, "late")
  Assert.isTrue(screen:status().mode ~= "failed", "repeated cancel stays silent")
  Assert.isNil(staging.failed, "no late failure latches")
  for _, left in pairs(staging.refcounts) do
    Assert.equal(left, 0, "every lease releases exactly once")
  end
  screen:dispose()
  screen:dispose()
  Assert.equal(trackCount(screen._nativeHandles), 0, "disposal leaves no tracks")
  Assert.equal(#screen._player._occurrences, 0, "disposal leaves no occurrence records")
end

return { tests = T }
