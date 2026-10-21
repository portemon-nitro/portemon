-- Native effect failure containment at the production task boundary:
-- truncated streams, out-of-table words, and jumps into operand bytes
-- fail lowering with their own program and byte detail, while a
-- mid-run texture or voice failure reports its occurrence and
-- instruction detail, releases its partial acquisitions exactly once,
-- leaves the host scene live, and never completes as an invisible
-- animation. Setup below holds today through the real producer and
-- scene paths; the runtime gate drives the battle-private program
-- player together with the battle-private effect task factory once both
-- exist.
-- Native mechanism: the overlay-7 resource-opening teardown live-state
-- check and the animation word framing rules
-- (pret/pokeheartgold@9d8b7591f09b65804da2fb2dfd56f320633e0d36).
-- Headless: synthetic command streams use the real producer lowering and
-- the shared program shape; the failing doubles record only.

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

local function sceneWithSolo()
  local scene = BattleScene.new()
  scene:observe({
    { combatant = 1, activation = 1, visible = true },
  })
  return scene
end

local function playbackPacket()
  local packet = BattlePresentationModel.packet({}, { events = {} }, {}, {
    launchId = "failure-containment-probe",
    packetId = 1,
  })
  Assert.equal(packet.launchId, "failure-containment-probe", "the playback input carries its launch identity")
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

function T.truncated_and_out_of_table_streams_fail_with_native_detail()
  local truncated = Assert.throws(function()
    BattleAnimationCompiler.compile({ key = "truncated-probe", stream = "abc" })
  end, "a partial word never lowers")
  Assert.isTrue(
    string.find(tostring(truncated), "truncated-probe", 1, true) ~= nil,
    "the truncation names the program under lowering"
  )
  local outOfTable = Assert.throws(function()
    BattleAnimationCompiler.compile({ key = "past-the-table", stream = streamOf({ 88 }) })
  end, "a word past the table end never lowers")
  Assert.isTrue(
    string.find(tostring(outOfTable), "unknown dispatch opcode", 1, true) ~= nil,
    "the rejection names the out-of-table word"
  )
  local overrun = Assert.throws(function()
    BattleAnimationCompiler.compile({ key = "skip-past-the-end", stream = streamOf({ 15, 5 }) })
  end, "a word-count skip past the program end never lowers")
  Assert.isTrue(
    string.find(tostring(overrun), "skip-past-the-end", 1, true) ~= nil,
    "the overrun names the program under lowering"
  )
end

function T.jumps_into_operand_bytes_never_lower()
  local err = Assert.throws(function()
    BattleAnimationCompiler.compile({ key = "into-operands", stream = streamOf({ 30, 1, 5, 6, 9 }) })
  end, "a branch target inside operand bytes never lowers")
  Assert.isTrue(
    string.find(tostring(err), "into-operands", 1, true) ~= nil,
    "the operand-byte jump names the program under lowering"
  )
end

function T.mid_run_resource_and_voice_failures_fail_loudly_and_stay_live()
  -- Particle tasks are the only family staging dependency leases now
  -- that visual, blend, and picture bodies run imageless, so the
  -- mid-run resource failure is proven through the particle staging
  -- path: the first acquisition attempt fails and rolls back exactly
  -- once instead of completing silently.
  local program = lowered("run-failing-effect", { 51, 0, 27, 50, 4 })
  Assert.equal(program.instructions[1].op, "create-battler-effect", "the failing run stages its work first")
  Assert.equal(program.instructions[2].op, "wait-for-battler-effects", "an effects wait follows the staged work")
  local Player = playerModule()
  local Factory = effectFactoryModule()
  Assert.isTrue(Factory ~= nil, "the production factory joins the failing run")
  local scene = sceneWithSolo()
  local journal = { acquired = {}, released = {}, played = {}, stopped = {} }
  local audio = { stuck = true }
  function audio.play(name)
    journal.played[#journal.played + 1] = name
  end
  function audio.stop(name)
    journal.stopped[#journal.stopped + 1] = name
  end
  function audio.isFinished(_name)
    return not audio.stuck
  end
  local resources = {}
  function resources.resolve(key)
    journal.acquired[#journal.acquired + 1] = key
    if key == "battle/particle/asleep" then
      local params = {}
      for index = 1, 42 do
        params[index] = 0
      end
      params[29], params[30], params[24], params[32] = 12, 12, 0, 1
      return {
        key = key,
        kind = "particle",
        payloadPath = "probe/particle-asleep",
        data = {
          emitters = {
            { features = { "alpha" }, params = params, textureKey = "battle/particle/texture/missing" },
          },
        },
      }
    end
    error({ code = "TEXTURE_MISSING", key = key }, 0)
  end
  function resources.release(lease)
    journal.released[#journal.released + 1] = lease
  end
  local player = assert(Player.new({
    scene = scene,
    audio = audio,
    resources = resources,
    tasks = Factory,
  }))
  local handle = assert(player:start(playbackPacket(), program))
  local failure = nil
  for _ = 1, 30 do
    local ok, err = pcall(player.stepSourceTick, player, { tick = 1 })
    if not ok then
      failure = err
      break
    end
    if player:status(handle) == "failed" then
      failure = player:status(handle)
      break
    end
    if player:status(handle) == "complete" then
      break
    end
  end
  Assert.notNil(failure, "the mid-run failure surfaces instead of completing silently")
  Assert.isTrue(
    player:status(handle) ~= "complete",
    "the failed effect never counts as a completed invisible animation"
  )
  Assert.equal(#journal.released, #journal.acquired, "partial acquisitions release exactly once")
  local live = scene:observe({ { combatant = 1, activation = 1, visible = true } })
  Assert.isNil(live, "the host scene stays live after the failure")
  scene:stepSourceTick()
  Assert.equal(#scene:effectViews(), 0, "no failed effect record lingers in the live scene")
end

-- Live-screen failure containment for selected native effects: a
-- terminal worker/producer failure and a mid-closure image upload failure
-- each fail the screen with launch/effect/packet provenance, apply no
-- health early, expose no new decision, leave no orphaned scene record,
-- and stay failed across disposal and stale deliveries.
-- Native mechanism: the overlay-7 resource-opening teardown live-state
-- check stays terminal through the screen envelope, and partial
-- acquisitions release exactly once.
-- Headless: the real screen, timeline, holder, and scene over a failing
-- staged-effect double; no dump capability is needed.

---@param launchId string owning launch identity under test preparation
---@return table preparation services serving portraits plus the fixture services
local function failingScreenServices(staging)
  local portraits = {
    images = {},
  }
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
local function failingFoeRecord(hp)
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
local function failingOwnRecord()
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
local function failingView(foeHp)
  return { own = { failingOwnRecord() }, foes = { failingFoeRecord(foeHp) } }
end

---@param launchId string owning launch identity under test driving
---@param staging table staged-effect fixture under test driving
---@return table live screen behind the failing effect services plus its port
local function openFailingScreen(launchId, staging)
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
    signature = "failure-containment:dual",
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
  local screen = BattleScreenState.new({
    launchId = launchId,
    manifest = manifest,
    model = Model,
    submit = function(_reply)
      return true
    end,
    measureDisplay = function()
      return measurement
    end,
    assets = failingScreenServices(staging),
    text = text,
    windows = windows,
    audio = audio,
  })
  return screen
end

---@param screen table live screen under test driving
---@param launchId string owning launch identity under test driving
local function presentFailingStrike(screen, launchId)
  local port = screen:presentationPort()
  port.present({
    launchId = launchId,
    packetId = 1,
    events = {},
    before = failingView(57),
    after = failingView(57),
  })
  port.present({
    launchId = launchId,
    packetId = 2,
    events = {
      {
        sequence = 1,
        kind = "struck",
        cause = { key = "TACKLE" },
        audience = "public",
        actors = { { combatant = 1 } },
        targets = { { combatant = 3 } },
        move = { executed = "TACKLE" },
        actionId = 61,
        hitIndex = 1,
        effectKey = "TACKLE",
        payload = { target = 3, damage = 14, hitIndex = 1 },
        after = { hp = { [1] = 52, [3] = 43 } },
      },
    },
    before = failingView(57),
    after = failingView(43),
  })
end

---@param view table displayed screen view under inspection
---@return integer displayed foe health
local function failingDisplayedFoeHp(view)
  for _, entry in ipairs(view.battlers or {}) do
    if entry.side == 2 then
      return entry.hp
    end
  end
  error("the displayed view names its foe", 0)
end

-- A terminal worker failure for the selected effect fails the live
-- screen with provenance instead of settling a generic hit: the failed
-- state names the launch and effect, applies no health early, exposes
-- no new decision, and stays failed across disposal and stale
-- deliveries.
function T.missing_native_effect_request_fails_the_live_screen_with_provenance()
  local EffectStagingFixture = require("tests.support.EffectStagingFixture")
  local launchId = "launch-effect-worker-failure"
  local staging = EffectStagingFixture.new({ launchId = launchId })
  staging:failEffect("TACKLE", "worker exploded")
  local screen = openFailingScreen(launchId, staging)
  presentFailingStrike(screen, launchId)
  for _ = 1, 600 do
    screen:updateFixed(1 / 30)
  end
  local status = screen:status()
  Assert.equal(status.mode, "failed", "the missing native dependency fails the screen, never a silent hit")
  Assert.isTrue(
    tostring(status.error):find("TACKLE", 1, true) ~= nil,
    "the failure names its selected effect: " .. tostring(status.error)
  )
  Assert.isTrue(
    tostring(status.error):find(launchId, 1, true) ~= nil,
    "the failure names its launch: " .. tostring(status.error)
  )
  Assert.equal(
    failingDisplayedFoeHp(screen:view()),
    57,
    "the failed cue applies no health early"
  )
  Assert.isNil(status.request, "the failed screen exposes no new decision")
  Assert.isFalse(status.ready, "the failed screen reports unready, never settled")
  Assert.equal(#screen:view().effectInstances, 0, "no failed effect record lingers in the live scene")
  screen:dispose()
  Assert.equal(screen:status().mode, "failed", "disposal keeps the diagnosed failure")
  local ok = pcall(presentFailingStrike, screen, launchId)
  Assert.isTrue(ok, "a stale delivery after disposal raises nothing")
  Assert.equal(screen:status().mode, "failed", "a stale delivery never revives the failed screen")
end

-- A program staging a key its live effect closure never declared fails
-- the live screen at admission with instruction and resource provenance:
-- the schema closure check rejects undeclared references before anything
-- stages, so the screen adapter never needs to mint a synthetic journal
-- token for them. A particle creation names the undeclared semantic
-- resource so the failure below names it.
function T.undeclared_program_resources_fail_the_live_screen_with_provenance()
  local EffectStagingFixture = require("tests.support.EffectStagingFixture")
  local launchId = "launch-undeclared-resource"
  local staging = EffectStagingFixture.new({ launchId = launchId })
  local program = lowered("undeclared-lease-probe", { 51, 1, 64, 50, 4 })
  Assert.equal(
    program.instructions[1].resource,
    "battle/particle/tackle",
    "the probe stages its semantic particle resource"
  )
  local record = EffectStagingFixture.effectRecord("TACKLE", {})
  record.program = {
    entry = program.entry,
    instructions = program.instructions,
    subprograms = program.subprograms,
    taskKinds = program.taskKinds,
  }
  staging:stageEffect("TACKLE", record, {})
  local screen = openFailingScreen(launchId, staging)
  presentFailingStrike(screen, launchId)
  for _ = 1, 600 do
    screen:updateFixed(1 / 30)
  end
  local status = screen:status()
  Assert.equal(status.mode, "failed", "the undeclared reference fails the screen, never a silent hit")
  Assert.isTrue(
    tostring(status.error):find("references an unstaged resource", 1, true) ~= nil,
    "the failure names the closure violation: " .. tostring(status.error)
  )
  Assert.isTrue(
    tostring(status.error):find("battle/particle/tackle", 1, true) ~= nil,
    "the failure names its undeclared resource: " .. tostring(status.error)
  )
  Assert.isTrue(
    tostring(status.error):find(launchId, 1, true) ~= nil,
    "the failure names its launch: " .. tostring(status.error)
  )
  screen:dispose()
  Assert.equal(screen:status().mode, "failed", "disposal keeps the diagnosed failure")
end

-- A terminal image upload inside the selected effect closure fails the
-- live screen without orphans: partial acquisitions release exactly
-- once, no failed picture lingers, and no health is applied early.
function T.failed_effect_image_upload_releases_partial_leases_without_orphans()
  local EffectStagingFixture = require("tests.support.EffectStagingFixture")
  local Hashing = require("romdump.src.digest.Hashing")
  local launchId = "launch-effect-upload-failure"
  local staging = EffectStagingFixture.new({ launchId = launchId })
  local textureBytes = EffectStagingFixture.rgba(4, 4)
  staging:stageEffect(
    "TACKLE",
    EffectStagingFixture.effectRecord("TACKLE", {
      { key = "probe-spark", kind = "texture", payload = "effects/probe-spark.lua", contentIdentity = Hashing.sha1hex(textureBytes) },
    }),
    { ["effects/probe-spark.lua"] = { width = 4, height = 4, rgba8888 = textureBytes } }
  )
  staging:failUploadFor("probe-spark", "gpu exploded")
  local screen = openFailingScreen(launchId, staging)
  presentFailingStrike(screen, launchId)
  for _ = 1, 600 do
    screen:updateFixed(1 / 30)
  end
  local status = screen:status()
  Assert.equal(status.mode, "failed", "the upload failure fails the screen, never a silent hit")
  Assert.isTrue(
    tostring(status.error):find("probe-spark", 1, true) ~= nil,
    "the failure names its resource: " .. tostring(status.error)
  )
  Assert.equal(
    failingDisplayedFoeHp(screen:view()),
    57,
    "the failed closure applies no health early"
  )
  Assert.isNil(status.request, "the failed screen exposes no new decision")
  Assert.equal(#screen:view().effectInstances, 0, "no failed effect record lingers in the live scene")
  screen:dispose()
  Assert.equal(screen:status().mode, "failed", "disposal keeps the diagnosed failure")
end

-- A program naming a task kind without a real factory body never
-- starts: the live screen fails with launch, effect, and kind
-- provenance instead of admitting an unrunnable occurrence.
function T.unknown_program_task_kind_fails_the_live_screen_with_provenance()
  local EffectStagingFixture = require("tests.support.EffectStagingFixture")
  local launchId = "launch-effect-unknown-kind"
  local staging = EffectStagingFixture.new({ launchId = launchId })
  local record = EffectStagingFixture.effectRecord("TACKLE", {})
  local probe = lowered("TACKLE", { 34, 1, 2, 3, 29, 50, 4 })
  record.program = {
    entry = probe.entry,
    instructions = probe.instructions,
    subprograms = probe.subprograms,
    taskKinds = { "bogus-kind" },
  }
  staging:stageEffect("TACKLE", record, {})
  local screen = openFailingScreen(launchId, staging)
  presentFailingStrike(screen, launchId)
  for _ = 1, 600 do
    screen:updateFixed(1 / 30)
  end
  local status = screen:status()
  Assert.equal(status.mode, "failed", "the unrunnable program fails the screen, never a silent hit")
  Assert.isTrue(
    tostring(status.error):find("bogus-kind", 1, true) ~= nil,
    "the failure names its task kind: " .. tostring(status.error)
  )
  Assert.isTrue(
    tostring(status.error):find("TACKLE", 1, true) ~= nil,
    "the failure names its selected effect: " .. tostring(status.error)
  )
  Assert.isTrue(
    tostring(status.error):find(launchId, 1, true) ~= nil,
    "the failure names its launch: " .. tostring(status.error)
  )
  Assert.equal(failingDisplayedFoeHp(screen:view()), 57, "the rejected program applies no health early")
  Assert.isNil(status.request, "the failed screen exposes no new decision")
  Assert.isFalse(status.ready, "the failed screen reports unready, never settled")
  Assert.equal(#screen:view().effectInstances, 0, "no rejected effect record lingers in the live scene")
  screen:dispose()
  Assert.equal(screen:status().mode, "failed", "disposal keeps the diagnosed failure")
end

-- A selected effect declaring resolved move power refuses admission
-- while the cue carries no usable value: a missing, fractional, or
-- out-of-range fact each fail the screen with launch, effect, and power
-- provenance before anything starts, while a matching resolved value
-- admits and runs to its checkpoint with no failure.
---@param screen table live screen under test driving
---@param launchId string owning launch identity under test driving
---@param move table<string, unknown> playback move fact under test driving
local function presentStrikeCarryingMove(screen, launchId, move)
  local port = screen:presentationPort()
  port.present({
    launchId = launchId,
    packetId = 1,
    events = {},
    before = failingView(57),
    after = failingView(57),
  })
  port.present({
    launchId = launchId,
    packetId = 2,
    events = {
      {
        sequence = 1,
        kind = "struck",
        cause = { key = "MAGNITUDE" },
        audience = "public",
        actors = { { combatant = 1 } },
        targets = { { combatant = 3 } },
        move = move,
        actionId = 61,
        hitIndex = 1,
        effectKey = "MAGNITUDE",
        payload = { target = 3, damage = 14, hitIndex = 1 },
        after = { hp = { [1] = 52, [3] = 43 } },
      },
    },
    before = failingView(57),
    after = failingView(43),
  })
end

---@return table staged-effect fixture demanding resolved move power
local function powerDemandingStaging(launchId)
  local EffectStagingFixture = require("tests.support.EffectStagingFixture")
  local staging = EffectStagingFixture.new({ launchId = launchId })
  local program = lowered("MAGNITUDE", { 34, 1, 2, 3, 29, 50, 4 })
  local record = EffectStagingFixture.effectRecord("MAGNITUDE", {})
  record.program = {
    entry = program.entry,
    instructions = program.instructions,
    subprograms = program.subprograms,
    taskKinds = program.taskKinds,
  }
  record.requiredContext = { movePower = { type = "battle-animation-move-power-u16" } }
  staging:stageEffect("MAGNITUDE", record, {})
  return staging
end

function T.missing_or_malformed_move_power_refuses_admission_before_playback()
  for _, move in ipairs({
    { selected = "MAGNITUDE", executed = "MAGNITUDE", phase = "direct" },
    { selected = "MAGNITUDE", executed = "MAGNITUDE", phase = "direct", power = 90.5 },
    { selected = "MAGNITUDE", executed = "MAGNITUDE", phase = "direct", power = 70000 },
  }) do
    local launchId = "launch-move-power-refused-" .. tostring(move.power)
    local screen = openFailingScreen(launchId, powerDemandingStaging(launchId))
    presentStrikeCarryingMove(screen, launchId, move)
    for _ = 1, 600 do
      screen:updateFixed(1 / 30)
    end
    local status = screen:status()
    Assert.equal(status.mode, "failed", "the missing value fails admission, never a silent hit")
    Assert.isTrue(
      tostring(status.error):find("MAGNITUDE", 1, true) ~= nil,
      "the failure names its selected effect: " .. tostring(status.error)
    )
    Assert.isTrue(
      tostring(status.error):find(launchId, 1, true) ~= nil,
      "the failure names its launch: " .. tostring(status.error)
    )
    Assert.isTrue(
      tostring(status.error):find("movePower", 1, true) ~= nil,
      "the failure names the missing context: " .. tostring(status.error)
    )
    Assert.equal(failingDisplayedFoeHp(screen:view()), 57, "the refused cue applies no health early")
    Assert.isNil(status.request, "the failed screen exposes no new decision")
    Assert.equal(#screen:view().effectInstances, 0, "no refused effect record lingers in the live scene")
    screen:dispose()
    Assert.equal(screen:status().mode, "failed", "disposal keeps the diagnosed failure")
  end
end

function T.matching_resolved_move_power_admits_and_runs_to_its_checkpoint()
  local launchId = "launch-move-power-admitted"
  local screen = openFailingScreen(launchId, powerDemandingStaging(launchId))
  presentStrikeCarryingMove(screen, launchId, {
    selected = "MAGNITUDE",
    executed = "MAGNITUDE",
    phase = "direct",
    power = 90,
  })
  local settledHp = nil
  for _ = 1, 1200 do
    screen:updateFixed(1 / 30)
    if screen:status().mode == "failed" then
      break
    end
    if failingDisplayedFoeHp(screen:view()) == 43 and screen:status().ready then
      settledHp = 43
      break
    end
  end
  Assert.equal(screen:status().mode ~= "failed", true, "the matching value passes admission")
  Assert.equal(settledHp, 43, "the admitted effect runs to its checkpoint")
  screen:dispose()
end

-- A still-staging effect parks instead of failing or settling: once the
-- worker closure validates, the same cue admits and runs its program
-- to the exact checkpoint with no new decision sealed.
function T.pending_effect_stages_and_runs_once_ready_without_new_demands()
  local EffectStagingFixture = require("tests.support.EffectStagingFixture")
  local launchId = "launch-effect-pending-promotion"
  local staging = EffectStagingFixture.new({ launchId = launchId })
  local screen = openFailingScreen(launchId, staging)
  presentFailingStrike(screen, launchId)
  for _ = 1, 30 do
    screen:updateFixed(1 / 30)
  end
  Assert.isTrue(screen:status().mode ~= "failed", "pending staging never fails fast")
  Assert.equal(failingDisplayedFoeHp(screen:view()), 57, "the parked cue applies no health early")
  Assert.isFalse(screen:status().ready, "the parked cue reports unready, never settled")
  local program = lowered("TACKLE", { 34, 1, 2, 3, 29, 50, 4 })
  local record = EffectStagingFixture.effectRecord("TACKLE", {})
  record.program = {
    entry = program.entry,
    instructions = program.instructions,
    subprograms = program.subprograms,
    taskKinds = program.taskKinds,
  }
  staging:stageEffect("TACKLE", record, {})
  local settledHp = nil
  for _ = 1, 1200 do
    screen:updateFixed(1 / 30)
    if failingDisplayedFoeHp(screen:view()) == 43 and screen:status().ready then
      settledHp = 43
      break
    end
  end
  Assert.equal(settledHp, 43, "the staged effect runs to its checkpoint once ready")
  Assert.isTrue(#staging.requests >= 1, "the selected effect is demanded")
  for _, key in ipairs(staging.requests) do
    Assert.equal(key, "TACKLE", "promotion demands nothing beyond the selected effect")
  end
  screen:dispose()
  for _, key in ipairs(staging.requests) do
    Assert.equal(key, "TACKLE", "disposal starts no late effect work")
  end
end

return { tests = T }
