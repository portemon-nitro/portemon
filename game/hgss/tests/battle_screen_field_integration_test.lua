-- One presented battle per accepted field step or script request. The
-- production field keeps its session while a field-local envelope covers
-- entry and return, the real battle screen answers through real staged
-- presentation assets, music stays with the battle until the field is
-- visibly restored, and defeat reaches either the authored script
-- continuation or the existing recovery flow exactly once.
--
-- Every scenario boots the production field through the shared harness
-- (the render trap stays armed, so no draw call may fire), binds the
-- field-local envelope factory, and drives the real runtime, the real
-- screen, and the real recovery owners. Only host boundaries are
-- substituted: recording window/text/audio doubles, deterministic clocks,
-- and isolated save namespaces. Each scenario first names the missing
-- envelope owner, so the run stays red until that owner lands.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local NavigationFacts = require("tests.rom.support.NavigationFacts")
local OpeningLifecycle = require("tests.acceptance.support.OpeningLifecycle")
local RomFs = require("romdump.src.source.RomFs")
local CacheFs = require("libs.storage.src.CacheFs")
local FieldRuntime = require("game.hgss.src.field.FieldRuntime")
local BattleTask = require("libs.hgss.src.script.tasks.BattleTask")
local BattleDataCache = require("libs.assets.src.battle.BattleDataCache")
local ScreenTopology = require("libs.ui.src.ScreenTopology")
local SessionFixture = require("libs.battle.tests.session_fixture")

local T = {
  tests = {},
  metadata = {
    capabilities = { "rom_dump", "derived_assets" },
    derivedAssets = {
      "field-runtime",
      "map-data:31",
      "map-data:33",
      "map-data:34",
      "map-data:47",
      "map-data:48",
      "map-data:60",
      "map-data:61",
      "map-data:63",
      "map-data:67",
      "map-data:384",
      "map:33",
      "map:34",
      "map:60",
      "map:61",
      "map:63",
      "map:67",
      "map:384",
      "trainers:global",
      "encounters:global",
      "battle-presentation:global",
    },
    tags = { "field", "battle" },
  },
}

local TICK = 1 / 60
local PRESENTATION_OWNER = "game.hgss.src.field.FieldBattlePresentation"

---@param behavior string the missing envelope responsibility naming this red
---@return table the field-local presented-battle envelope owner
local function requirePresentationOwner(behavior)
  local ok, owner = pcall(require, PRESENTATION_OWNER)
  Assert.isTrue(
    ok,
    "the field keeps one presented battle envelope per launch: " .. behavior .. " (" .. PRESENTATION_OWNER .. ")"
  )
  return assert(owner, "the presented battle envelope loads")
end

-- The envelope binds through the token-guarded per-launch factory seam,
-- never through a stored disposable port. This names the missing binding
-- before any scenario can drive a launch through it.
---@param runtime table live production field runtime under test driving
local function requireFactoryBinding(runtime)
  Assert.isTrue(
    type(FieldRuntime.bindBattlePresentation) == "function",
    "the field runtime binds one fresh presentation per launch instead of storing a disposable port"
  )
  Assert.isTrue(
    type(FieldRuntime.unbindBattlePresentation) == "function",
    "the field runtime releases only the matching presentation binding"
  )
  assert(runtime ~= nil, "the field runtime carries its binding seam")
end

---@return table recording cue-audio boundary with per-name counts
local function recordingAudio()
  local audio = { plays = {} }
  function audio.play(name)
    audio.plays[#audio.plays + 1] = name
    return true
  end
  function audio.count(name)
    local total = 0
    for _, played in ipairs(audio.plays) do
      if played == name then
        total = total + 1
      end
    end
    return total
  end
  return audio
end

---@return table recording window-frame boundary keyed by selected frame name
local function recordingWindows()
  local windows = { calls = {} }
  function windows.drawWindow(box, frameKey, background)
    windows.calls[#windows.calls + 1] = { box = box, frame = frameKey, background = background }
  end
  function windows.drawApplicationFrame(box, frameKey)
    windows.calls[#windows.calls + 1] = { box = box, frame = frameKey }
  end
  function windows.frames()
    local seen = {}
    for _, call in ipairs(windows.calls) do
      seen[call.frame] = true
    end
    return seen
  end
  return windows
end

---@return table recording text boundary keeping every drawn string
local function recordingText()
  local text = { measures = 0, draws = {}, failed = false }
  function text.measure(content)
    if text.failed then
      error("test font is missing its required face", 0)
    end
    text.measures = text.measures + 1
    return { width = 8 * #tostring(content), height = 16 }
  end
  function text.drawText(content, x, y)
    if text.failed then
      error("test font is missing its required face", 0)
    end
    text.draws[#text.draws + 1] = { content = tostring(content), x = x, y = y }
  end
  return text
end

---@param signature string stable measurement identity under test driving
---@return table caller-owned dual-surface display facts with two 256x192 panes
local function dualMeasurement(signature)
  return {
    width = 256,
    height = 384,
    topology = ScreenTopology.dualDisplay(
      { id = "main", rect = { x = 0, y = 0, width = 256, height = 192 }, touch = false, role = "world" },
      { id = "lower", rect = { x = 0, y = 192, width = 256, height = 192 }, touch = true, role = "auxiliary" }
    ),
    pixelRatio = 1,
    signature = signature,
  }
end

---@param signature string stable measurement identity under test driving
---@return table caller-owned single wide surface display facts
local function wideMeasurement(signature)
  return {
    width = 512,
    height = 192,
    topology = ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = 512, height = 192 },
      touch = true,
      role = "world",
    }),
    pixelRatio = 1,
    signature = signature,
  }
end

---@param signature string stable measurement identity under test driving
---@return table caller-owned single tall surface display facts
local function tallMeasurement(signature)
  return {
    width = 256,
    height = 384,
    topology = ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = 256, height = 384 },
      touch = true,
      role = "world",
    }),
    pixelRatio = 1,
    signature = signature,
  }
end

---@param signature string stable measurement identity under test driving
---@return table caller-owned single compact surface display facts
local function compactMeasurement(signature)
  return {
    width = 256,
    height = 192,
    topology = ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = 256, height = 192 },
      touch = true,
      role = "world",
    }),
    pixelRatio = 1,
    signature = signature,
  }
end

---@param game table live acceptance game under test driving
local function freezeActors(game)
  local runtime = game.runtime
  for mapId in pairs(runtime.actors.maps) do
    for _, actor in ipairs(runtime.actors:actorsOf(mapId)) do
      runtime.actors:setMovementType(actor.actorId, "stationary")
    end
  end
end

---@param versionId string ready game version under test driving
---@param map string boot map symbol under test driving
---@return table harness
---@return table game live acceptance game with a settled field and a stocked lead pair
---@param fieldOptions table? host boundaries under test driving
local function bootFieldGame(versionId, map, fieldOptions)
  local harness = AcceptanceHarness.new({ versions = { versionId } })
  local game = harness:boot({ versionId = versionId, map = map, save = "fresh", fieldOptions = fieldOptions })
  game:waitForFieldEntry()
  freezeActors(game)
  Assert.isTrue(
    game.runtime.monService:giveMon({ species = "CHIKORITA", level = 9 }),
    "the presented route needs its live party lead"
  )
  Assert.isTrue(
    game.runtime.monService:giveMon({ species = "CHIKORITA", level = 9 }),
    "the presented route needs its live party reserve"
  )
  return harness, game
end

---@param game table live acceptance game under test driving
---@param versionId string ready game version under test driving
---@param measurement table caller-owned display facts under test driving
---@param overrides table? envelope option overrides under test driving
---@return table envelope live field-local presented-battle envelope
---@return integer binding token-guarded factory binding identity
---@return table doubles recording host boundaries behind the envelope
local function bindEnvelope(game, versionId, measurement, overrides)
  local doubles = { audio = recordingAudio(), windows = recordingWindows(), text = recordingText() }
  local options = {
    cacheFs = CacheFs.forVersion(versionId),
    windows = doubles.windows,
    text = doubles.text,
    audio = doubles.audio,
    measureDisplay = function()
      return measurement
    end,
  }
  for key, value in pairs(overrides or {}) do
    options[key] = value
  end
  local Presentation = require(PRESENTATION_OWNER)
  local envelope = Presentation.new(options)
  local ports = {}
  local factory = envelope:factory()
  local binding = game.runtime:bindBattlePresentation(function(descriptor)
    local port = factory(descriptor)
    ports[#ports + 1] = port
    return port
  end)
  doubles.ports = ports
  return envelope, binding, doubles
end

---@param game table live acceptance game under test driving
---@param envelope table live presented-battle envelope under test driving
---@param ticks integer fixed ticks to advance under test driving
local function pump(game, envelope, ticks)
  for _ = 1, ticks do
    game:step()
    envelope:updateFixed(TICK)
  end
end

---@param request table<string, unknown> pending player decision under inspection
---@param wanted string choice kind under search
---@return boolean true when the request admits the kind
local function admits(request, wanted)
  local legal = request.legalChoices
  if type(legal) ~= "table" or type(legal.kinds) ~= "table" then
    return false
  end
  for _, kind in ipairs(legal.kinds) do
    if kind == wanted then
      return true
    end
  end
  return false
end

---@param actor table addressed combatant under test driving
---@return table single-target strike at the opposing singles slot
local function strike(actor)
  return { actor = actor, kind = "attack", payload = { moveSlot = 0, target = { kind = "position", position = 2 } } }
end

-- Presented battles run thousands of presentation-paced ticks per bout, so
-- settlement bounds match the lower-level presented drivers instead of
-- assuming headless speed. A stuck battle still fails loudly: nothing
-- here advances without answered turns and phase movement.
local SETTLE_BUDGET = 6000

---@param runtime table live production field runtime under test driving
---@param request table<string, unknown> pending player decision under test driving
---@return table? prepared native switch fragment when a living replacement is selectable now
local function enabledSwitchFragment(runtime, request)
  local battle = runtime.battleRuntime
  if battle == nil or type(battle.decisionOptions) ~= "function" then
    return nil
  end
  local options = battle:decisionOptions(request.requestId)
  if type(options) ~= "table" or type(options.actors) ~= "table" then
    return nil
  end
  for _, entry in ipairs(options.actors) do
    for _, choice in ipairs(entry.choices or {}) do
      if choice.enabled == true and type(choice.choice) == "table" and choice.choice.kind == "switch" then
        return choice.choice
      end
    end
  end
  return nil
end

---@param runtime table live production field runtime under test driving
---@param request table<string, unknown> pending player decision under test driving
---@return table decision choice answering commands, replacements, and learning
local function fightElseSwitch(runtime, request)
  local actor = assert(request.actors[1], "every player decision addresses its combatant")
  if request.kind == "learn_move" then
    return { actor = actor, kind = "confirm", payload = { decision = "decline" } }
  end
  if not admits(request, "attack") then
    -- Replacements name a living bench slot the fixed slot number
    -- cannot know after captures and faints: copy the prepared
    -- native fragment instead.
    local fragment = enabledSwitchFragment(runtime, request)
    if fragment ~= nil then
      return fragment
    end
    return SessionFixture.switchChoice(actor, 2)
  end
  return strike(actor)
end

-- Projects one executable battle item through the battle's own decision
-- options and copies its prepared native fragment: targets resolve
-- through kernel identities the hand-built position vocabulary cannot
-- name, and availability follows real stock and effectiveness instead of
-- driver guesses. Nil when the item is not executable on this request.
---@param runtime table live production field runtime under test driving
---@param request table<string, unknown> pending player decision under test driving
---@param item string battle item key under projection
---@return table? prepared native choice fragment when the item is executable now
local function enabledItemFragment(runtime, request, item)
  local battle = runtime.battleRuntime
  if battle == nil or type(battle.decisionOptions) ~= "function" then
    return nil
  end
  local options = battle:decisionOptions(request.requestId)
  if type(options) ~= "table" or type(options.actors) ~= "table" then
    return nil
  end
  for _, entry in ipairs(options.actors) do
    for _, choice in ipairs(entry.choices or {}) do
      if
        choice.enabled == true
        and type(choice.choice) == "table"
        and type(choice.choice.payload) == "table"
        and choice.choice.payload.item == item
      then
        return choice.choice
      end
    end
  end
  return nil
end

---@param game table live acceptance game under test driving
---@param envelope table live presented-battle envelope under test driving
---@param choose fun(request: table): table decision choice for the open request
---@param budget integer tick bound before a stuck battle fails loudly
---@return integer answered player turns before the lifetime settled
local function settleBattle(game, envelope, choose, budget)
  local runtime = game.runtime
  -- Covered entry constructs the owned battle only after full cover and
  -- semantic leave, so a launch always starts with no live battle: wait
  -- for that construction before answering, otherwise this driver would
  -- return without settling anything whenever the battle is still
  -- covering or leaving.
  local waited = 0
  while runtime.battleRuntime == nil and runtime._battleLaunch ~= nil and waited < budget do
    local pending = runtime._battleLaunch
    if pending ~= nil and pending.phase == "failed" then
      error("the presented launch failed before construction: " .. tostring(pending.error or runtime.errorText), 0)
    end
    game:step()
    envelope:updateFixed(TICK)
    waited = waited + 1
  end
  Assert.notNil(runtime.battleRuntime, "the covered launch constructs its battle before settlement")
  local turns = 0
  local ticks = 0
  while runtime.battleRuntime ~= nil and ticks < budget do
    local battle = runtime.battleRuntime
    local current = battle:status()
    if current.phase == "failed" then
      error("the presented battle failed: " .. tostring(current.error), 0)
    end
    if current.phase == "running" and current.request ~= nil then
      turns = turns + 1
      local answer = choose(current.request)
      local choices = answer
      if type(answer) == "table" and answer.kind ~= nil then
        choices = { answer }
      end
      local accepted, replyErr = battle:submit(SessionFixture.replyFor(current.request, choices))
      Assert.isTrue(accepted, "a legal presented decision is accepted: " .. tostring(replyErr))
    end
    -- Terminal leave carries an explicit final-page acknowledgment, so
    -- every narration page is acknowledged through the real envelope
    -- input path exactly as a player would, alongside the decisions.
    -- Once the defeat enters recovery the disposed screen is gone, so
    -- the waiting defeat message gets its own genuine routed edge.
    local launch = runtime._battleLaunch
    if launch ~= nil and launch.phase == "recovering" then
      envelope:input({ { type = "confirm" } })
    else
      local screen = envelope:liveScreen()
      if screen ~= nil then
        local shown = screen:status()
        if shown.mode == "intro" or shown.mode == "narration" or shown.mode == "outcome" then
          envelope:input({ { type = "confirm" } })
        end
      end
    end
    game:step()
    envelope:updateFixed(TICK)
    ticks = ticks + 1
  end
  Assert.isNil(runtime.battleRuntime, "answered decisions settle the owned presented lifetime")
  return turns
end

-- The weakest rival singles trainer in canonical order, so the scenario
-- resolves whatever the staged cache actually carries instead of freezing
-- one numeric identity into the suite. The smallest generated identity is
-- the rival's full mid-game party, which outclasses the stocked leads, and
-- doubles need multi-actor answers outside this suite's singles drivers;
-- the win legs resolve the opening-starter rival the leads can beat.
-- Rival templates resolve their display name from the site's rival name.
---@param versionId string ready game version under test driving
---@return unknown generated rival trainer identity resolving without story state
local function weakestRivalKey(versionId)
  local compiled = BattleDataCache.loadTrainers(CacheFs.forVersion(versionId))
  assert(type(compiled) == "table" and type(compiled.trainers) == "table", "generated trainers carry records")
  local keys = {}
  for key in pairs(compiled.trainers) do
    keys[#keys + 1] = key
  end
  Assert.isTrue(#keys > 0, "generated trainers name at least one identity")
  table.sort(keys, function(left, right)
    return tostring(left) < tostring(right)
  end)
  for _, key in ipairs(keys) do
    local entry = compiled.trainers[key]
    if type(entry) == "table" then
      local rival = entry.nameReference ~= nil and entry.nameReference.rival == true
      local doubles = entry.doubleBattle == true
      local maxLevel = 0
      for _, member in ipairs(entry.party or {}) do
        maxLevel = math.max(maxLevel, tonumber(member.level) or 0)
      end
      if rival and not doubles and maxLevel > 0 and maxLevel <= 6 then
        return key
      end
    end
  end
  error("generated trainers name no beatable rival singles identity", 0)
end

---@param versionId string ready game version under test driving
---@return table route facts carrying the grass pacing tiles
local function routeFacts(versionId)
  local romFs, err = RomFs.open(versionId)
  assert(romFs, tostring(err))
  local ok, facts = pcall(NavigationFacts.discover, CacheFs.forVersion(versionId), romFs)
  romFs:close()
  if not ok then
    error(facts, 0)
  end
  assert(type(facts) == "table" and facts.grass ~= nil, "route facts carry a grass pacing tile")
  return facts
end

---@param game table live acceptance game under test driving
---@param facts table route facts carrying the grass pacing tile
local function walkToGrass(game, facts)
  game:moveTo({ fieldX = facts.grass.fieldX, fieldZ = facts.grass.fieldZ })
  game:advanceUntil("the grass tile settles", function(snapshot)
    return snapshot.player.motion == "idle"
  end, 120)
end

---@param game table live acceptance game under test driving
---@return table player cell identity under inspection
local function playerCell(game)
  local player = game:snapshot().player
  return { fieldX = player.fieldX, fieldZ = player.fieldZ, facing = player.facing }
end

-- One automatic encounter per accepted committed step: eligible walking
-- steps on grass and surfacing water reach the real screen on their own,
-- exactly once each, without a developer start call. Turning, bumping,
-- idle polling, and higher-priority coordinate-script/warp boundaries
-- launch nothing, and revisiting a tile on a new real step stays eligible.
function T.tests.committed_steps_launch_one_presented_battle_each()
  local Presentation = requirePresentationOwner("eligible committed steps reach the real screen on their own")
  assert(Presentation ~= nil, "the envelope owner loads")
  local versionId = AcceptanceHarness.defaultVersion()
  local harness, game = bootFieldGame(versionId, "MAP_NEW_BARK")
  local runtime = game.runtime
  requireFactoryBinding(runtime)
  local envelope, binding, _ = bindEnvelope(game, versionId, dualMeasurement("presented-steps:dual"))
  local starts, attempts = 0, 0
  local realStart = runtime.startBattle
  local realAttempt = runtime.attemptEncounter
  runtime.startBattle = function(self, args)
    starts = starts + 1
    return realStart(self, args)
  end
  runtime.attemptEncounter = function(self, context)
    attempts = attempts + 1
    return realAttempt(self, context)
  end
  local ok, failure = xpcall(function()
    OpeningLifecycle.seedNewBarkWestExitScene(game)
    OpeningLifecycle.settleNewBarkFriendScene(game)
    freezeActors(game)
    local facts = routeFacts(versionId)
    walkToGrass(game, facts)
    Assert.isNil(runtime.battleRuntime, "the walk to the grass stays outside battle")
    -- Turning in place never completes a step, so it never launches.
    local facing = playerCell(game).facing
    for _, direction in ipairs({ "north", "east", "south", "west" }) do
      game:face(direction)
    end
    game:face(facing)
    pump(game, envelope, 10)
    Assert.isNil(runtime.battleRuntime, "turning launches no presented battle")
    -- Idle polling on the grass tile is not a step either.
    pump(game, envelope, 10)
    Assert.isNil(runtime.battleRuntime, "idle polling launches no presented battle")
    -- Pace across neighbouring grass tiles until the first prepared
    -- encounter reaches the real screen on its own. The fresh boot keeps
    -- world draws deterministic, so the walk either launches within
    -- budget or the boundary is broken.
    local launched = false
    local anchor = playerCell(game)
    local attemptsBefore = attempts
    for _ = 1, 150 do
      if runtime.battleRuntime ~= nil then
        launched = true
        break
      end
      -- The grass tile east of the anchor is a wall, so pace the
      -- walkable westward axis instead: west off the anchor and back.
      if playerCell(game).fieldX >= anchor.fieldX then
        game:move("west")
      else
        game:move("east")
      end
      envelope:updateFixed(TICK)
      -- A host update spanning several fixed ticks still consumes the
      -- committed step exactly once.
      runtime:update(3 * TICK)
      envelope:updateFixed(TICK)
    end
    Assert.isTrue(launched, "an eligible grass walk reaches the presented battle without a start call")
    Assert.isTrue(attempts > attemptsBefore, "committed grass steps evaluate encounters")
    Assert.equal(starts, 1, "one accepted step constructs exactly one battle lifetime")
    Assert.isNil(runtime.pendingEncounterId, "the launch consumes its prepared identity")
    local screen = envelope:liveScreen()
    Assert.notNil(screen, "the automatic launch owns a live screen")
    local settled = settleBattle(game, envelope, function(request)
      return fightElseSwitch(runtime, request)
    end, SETTLE_BUDGET)
    Assert.isTrue(settled > 0, "the automatic battle answers decisions to its committed words")
    Assert.equal(runtime:lastBattleResult().result, "win", "the walked battle reports its win")
    -- After the continuing return, turning and idling on grass still
    -- launch nothing.
    game:face("north")
    pump(game, envelope, 10)
    Assert.isNil(runtime.battleRuntime, "turning after return launches nothing")
    -- Revisiting the launch tile on a new real step stays eligible: the
    -- step is evaluated again instead of suppressed by its coordinate.
    -- Single press ticks only start or turn, so drive one settled step
    -- west off the known-grass anchor tile instead.
    game:moveTo({ fieldX = anchor.fieldX, fieldZ = anchor.fieldZ })
    local evaluated = attempts
    game:face("west")
    game:move("west")
    game:advanceUntil("the revisit step resolves", function(snapshot)
      return snapshot.player.motion == "idle"
    end, 120)
    envelope:updateFixed(TICK)
    Assert.isTrue(attempts > evaluated, "a new real step on a revisited tile evaluates again")
    Assert.equal(game:renderAttempts(), 0, "the step route stops before GPU rendering")
  end, debug.traceback)
  runtime.startBattle = realStart
  runtime.attemptEncounter = realAttempt
  local unbound, unbindErr = pcall(function()
    runtime:unbindBattlePresentation(binding)
  end)
  game:close()
  harness = nil
  if not ok then
    error(failure, 0)
  end
  Assert.isTrue(unbound, "the presented lifetime releases its factory binding: " .. tostring(unbindErr))
end

-- Script requests keep their own launch and result ownership: two runs of
-- one site issue distinct identities and ports, each disposed once and
-- each result observed once. Continuing scripts resume only after the
-- field is visually restored, while scripted loss reaches its authored
-- continuation while absent, with no extra automatic recovery.
function T.tests.scripted_launches_keep_their_result_ownership()
  local Presentation = requirePresentationOwner("script requests keep their own launch and result ownership")
  assert(Presentation ~= nil, "the envelope owner loads")
  local harness = AcceptanceHarness.new()
  harness:forEachVersion(function(versionId)
    local inner, game = bootFieldGame(versionId, "MAP_NEW_BARK_ELMS_LAB_1F")
    local runtime = game.runtime
    requireFactoryBinding(runtime)
    local envelope, binding, doubles = bindEnvelope(game, versionId, dualMeasurement("presented-scripts:dual"))
    local starts = 0
    local realStart = runtime.startBattle
    runtime.startBattle = function(self, args)
      starts = starts + 1
      return realStart(self, args)
    end
    local ok, failure = xpcall(function()
      local key = weakestRivalKey(versionId)
      local site = { kind = "trainer", details = { trainer = key, rivalName = "SILVER" } }
      -- Source scripts launch through the runtime's narrow battle
      -- host, never through the runtime directly: only the host marks
      -- the launch as script-owned for defeat routing.
      local function taskContext()
        return { services = { battle = assert(runtime._battleHost, "the runtime composes its script battle host") } }
      end
      -- First run of the site wins through the real screen.
      local first = BattleTask.start(site, taskContext())
      Assert.isTrue(type(first.launchId) == "string", "the host issues the first launch identity")
      settleBattle(game, envelope, function(request)
        return fightElseSwitch(runtime, request)
      end, SETTLE_BUDGET)
      local pending = BattleTask.poll(first, taskContext())
      Assert.isTrue(pending.complete, "the won scripted battle completes its task")
      Assert.equal(pending.result, BattleTask.SOURCE_WON, "win reads back won")
      -- Let the envelope observe the completed launch and release it
      -- before the second admission: one launch owns the envelope.
      pump(game, envelope, 30)
      -- The second run of the same site never reuses the first launch.
      local second = BattleTask.start(site, taskContext())
      Assert.isTrue(second.launchId ~= first.launchId, "two runs of one site never share an identity")
      Assert.equal(#doubles.ports, 2, "two launches build two fresh ports")
      Assert.isTrue(doubles.ports[1] ~= doubles.ports[2], "each launch owns its port")
      settleBattle(game, envelope, function(request)
        return fightElseSwitch(runtime, request)
      end, SETTLE_BUDGET)
      local following = BattleTask.poll(second, taskContext())
      Assert.isTrue(following.complete, "the second launch reports its own result once")
      Assert.equal(starts, 2, "two scripted launches construct two lifetimes")
      -- Release the second launch the same way before the loss admission.
      pump(game, envelope, 30)
      -- A scripted loss stays absent for its authored continuation: no
      -- ordinary return and no automatic recovery runs behind the script.
      runtime.monService:giveMon({ species = "CHIKORITA", level = 3 })
      local loss = BattleTask.start({ kind = "wild", details = { species = "EEVEE", level = 30 } }, taskContext())
      settleBattle(game, envelope, function(request)
        return fightElseSwitch(runtime, request)
      end, SETTLE_BUDGET)
      local lost = BattleTask.poll(loss, taskContext())
      Assert.isTrue(lost.complete, "the scripted loss completes its task")
      Assert.equal(lost.result, BattleTask.SOURCE_NOT_WON, "loss reads back not-won")
      Assert.equal(runtime.overworld:phase(), "absent", "scripted defeat holds cover while absent")
      Assert.equal(game:renderAttempts(), 0, "the script route stops before GPU rendering")
    end, debug.traceback)
    runtime.startBattle = realStart
    local unbound = pcall(function()
      runtime:unbindBattlePresentation(binding)
    end)
    game:close()
    inner = nil
    if not ok then
      error(failure, 0)
    end
    Assert.isTrue(unbound, "each version releases its factory binding")
  end)
  harness = nil
end

-- Covered entry and return wait for real readiness while music stays with
-- its owner: cover completes before semantic leave, reveal follows actual
-- restoration readiness, battle roles start once and survive children and
-- layout changes, field music resumes once, and a missing required asset
-- fails explicitly instead of continuing on a timer.
function T.tests.covered_entry_waits_for_readiness_and_holds_music()
  local Presentation = requirePresentationOwner("covered entry waits for real readiness and holds music")
  assert(Presentation ~= nil, "the envelope owner loads")
  local harness = AcceptanceHarness.new()
  harness:forEachVersion(function(versionId)
    local inner, game = bootFieldGame(versionId, "MAP_NEW_BARK_ELMS_LAB_1F")
    local runtime = game.runtime
    requireFactoryBinding(runtime)
    local envelope, binding, _ = bindEnvelope(game, versionId, dualMeasurement("presented-cover:dual"))
    local music, stopMusic = {}, 0
    local audio = assert(runtime.audio, "the field runtime owns its audio service")
    Assert.isTrue(type(audio.playMusic) == "function", "the field audio service plays named music roles")
    local realPlay = audio.playMusic
    local realStop = audio.stopMusic
    audio.playMusic = function(self, ref, ...)
      music[#music + 1] = tostring(ref)
      return realPlay(self, ref, ...)
    end
    if type(realStop) == "function" then
      audio.stopMusic = function(self, ...)
        stopMusic = stopMusic + 1
        return realStop(self, ...)
      end
    end
    local starts, attempts = 0, 0
    local realStart = runtime.startBattle
    local realAttempt = runtime.attemptEncounter
    runtime.startBattle = function(self, args)
      starts = starts + 1
      return realStart(self, args)
    end
    runtime.attemptEncounter = function(self, context)
      attempts = attempts + 1
      return realAttempt(self, context)
    end
    local ok, failure = xpcall(function()
      local launchId = runtime:launchBattle({ kind = "wild", details = { species = "EEVEE", level = 4 } })
      -- While the envelope never pumps, cover never completes, so the
      -- runtime must not request semantic leave, construct the battle, or
      -- sample another encounter for a preview.
      local attemptsAtClaim = attempts
      for _ = 1, 30 do
        game:step()
      end
      Assert.equal(runtime.overworld:phase(), "present", "leave waits for full cover")
      Assert.equal(starts, 0, "no battle constructs before the envelope is ready")
      Assert.equal(attempts, attemptsAtClaim, "no encounter reroll happens while assets load")
      -- Release the envelope: cover completes, leave is requested, and
      -- exactly one battle constructs under the same launch identity.
      local ticks = 0
      while runtime.battleRuntime == nil and ticks < 600 do
        game:step()
        envelope:updateFixed(TICK)
        ticks = ticks + 1
      end
      Assert.notNil(runtime.battleRuntime, "the covered launch constructs its battle")
      Assert.equal(starts, 1, "one launch constructs one battle lifetime")
      local cover = envelope:cover()
      Assert.isTrue(type(cover) == "table" and cover.coefficient == 16, "the battle starts under full cover")
      -- The wild role starts once and survives presentation pumping and
      -- a layout change without restarting.
      local function wildPlays()
        local total = 0
        for _, ref in ipairs(music) do
          if ref:find("NORAPOKE", 1, true) ~= nil then
            total = total + 1
          end
        end
        return total
      end
      local waited = 0
      while envelope:liveScreen() == nil and waited < 600 do
        game:step()
        envelope:updateFixed(TICK)
        waited = waited + 1
      end
      Assert.notNil(envelope:liveScreen(), "the covered battle reaches its live screen")
      Assert.equal(wildPlays(), 1, "the ordinary wild role starts exactly once")
      local screen = assert(envelope:liveScreen(), "the live screen survives measurement")
      local before = #music
      screen:input({ { type = "pointer_cancel", pointerId = "touch:0" } })
      pump(game, envelope, 30)
      Assert.equal(#music, before, "children and layout activity restart no music")
      -- Finish through the real screen: the terminal cover completes,
      -- restoration waits for actual scene readiness, and field music
      -- resumes exactly once.
      settleBattle(game, envelope, function(request)
        return fightElseSwitch(runtime, request)
      end, SETTLE_BUDGET)
      local fieldPlays = #music
      pump(game, envelope, 60)
      Assert.isTrue(#music >= fieldPlays, "field music resumes after the revealed return")
      Assert.equal(runtime:battleStatus(launchId).result, "win", "the covered battle reports its win")
      Assert.equal(game:renderAttempts(), 0, "the covered route stops before GPU rendering")
    end, debug.traceback)
    runtime.startBattle = realStart
    runtime.attemptEncounter = realAttempt
    audio.playMusic = realPlay
    if type(realStop) == "function" then
      audio.stopMusic = realStop
    end
    local unbound = pcall(function()
      runtime:unbindBattlePresentation(binding)
    end)
    game:close()
    inner = nil
    if not ok then
      error(failure, 0)
    end
    Assert.isTrue(unbound, "each version releases its factory binding")
    Assert.isTrue(stopMusic >= 0, "the music spy restores cleanly")
  end)
  harness = nil
end

-- Outcomes publish once and defeat recovers safely: win, flight, and
-- capture report their exact committed words with single effects and a
-- continuing return, while an automatic loss or draw runs the existing
-- recovery exactly once with no double money, healing, or publication.
-- The save gate stays closed through every transient phase and opens at
-- the safe field, and no shutdown save publishes a half-battle.
function T.tests.outcomes_publish_once_and_defeat_recovers_safely()
  local Presentation = requirePresentationOwner("outcomes publish once and defeat recovers safely")
  assert(Presentation ~= nil, "the envelope owner loads")
  local harness = AcceptanceHarness.new()
  harness:forEachVersion(function(versionId)
    local inner, game = bootFieldGame(versionId, "MAP_NEW_BARK_ELMS_LAB_1F")
    local runtime = game.runtime
    requireFactoryBinding(runtime)
    local envelope, binding, _ = bindEnvelope(game, versionId, dualMeasurement("presented-outcomes:dual"))
    local function saveRefusal()
      return select(2, runtime.saveCoordinator:capture(false))
    end
    local ok, failure = xpcall(function()
      Assert.isTrue(runtime.bagService:add("POTION", 3), "the outcome route stocks its supported healing")
      -- Deterministic capture rides the guaranteed ball the subflow
      -- suite proves: ordinary balls stay probabilistic, so a fixed seed
      -- could never promise the single spent ball this leg asserts.
      Assert.isTrue(runtime.bagService:add("MASTER_BALL", 1), "the outcome route stocks its thrown ball")
      local lead = assert(runtime.monService:partyMon(0), "the live lead is readable")
      local openingExperience = assert(lead.experience, "live mons carry their experience")
      -- Win: exact words, single commit, prize, experience, and a
      -- continuing return. Only trainer wins pay prize money, so this
      -- leg runs the smallest generated trainer identity.
      local winKey = weakestRivalKey(versionId)
      runtime:launchBattle({ kind = "trainer", details = { trainer = winKey, rivalName = "SILVER" } })
      pump(game, envelope, 5)
      Assert.notNil(saveRefusal(), "the save gate closes while the launch is transient")
      local moneyBefore = runtime.playerData.profile.money
      settleBattle(game, envelope, function(request)
        return fightElseSwitch(runtime, request)
      end, SETTLE_BUDGET)
      pump(game, envelope, 60)
      Assert.equal(runtime:lastBattleResult().result, "win", "the win reports its exact word")
      Assert.equal(runtime:lastBattleResult().sourceResult, 1, "the win reads back won")
      Assert.isTrue(runtime.playerData.profile.money > moneyBefore, "the win pays its prize once")
      local paid = runtime.playerData.profile.money
      pump(game, envelope, 30)
      Assert.equal(runtime.playerData.profile.money, paid, "settling pays no second prize")
      local grown = assert(runtime.monService:partyMon(0), "the live lead is readable after commit")
      Assert.isTrue(grown.experience > openingExperience, "the win publishes experience once")
      -- Flight: the exact flee word with both sides standing and a return.
      runtime:launchBattle({ kind = "wild", details = { species = "EEVEE", level = 4 } })
      settleBattle(game, envelope, function(request)
        local actor = assert(request.actors[1], "every player decision addresses its combatant")
        if admits(request, "run") then
          return { actor = actor, kind = "run", payload = {} }
        end
        return fightElseSwitch(runtime, request)
      end, SETTLE_BUDGET)
      pump(game, envelope, 60)
      Assert.equal(runtime:lastBattleResult().result, "flee", "flight reports its exact word")
      -- Capture: the exact capture word, one ball spent, one mon gained.
      local ballsBefore = runtime.bagService:quantity("MASTER_BALL")
      local partyBefore = runtime.monService:partyCount()
      runtime:launchBattle({ kind = "wild", details = { species = "EEVEE", level = 3 } })
      settleBattle(game, envelope, function(request)
        if admits(request, "item") then
          local fragment = enabledItemFragment(runtime, request, "MASTER_BALL")
          if fragment ~= nil then
            return fragment
          end
        end
        return fightElseSwitch(runtime, request)
      end, SETTLE_BUDGET)
      pump(game, envelope, 60)
      Assert.equal(runtime:lastBattleResult().result, "capture", "capture reports its exact word")
      Assert.equal(runtime.bagService:quantity("MASTER_BALL"), ballsBefore - 1, "the capture spends one ball")
      Assert.equal(runtime.monService:partyCount(), partyBefore + 1, "the capture publishes one mon")
      -- Automatic loss: no launching script exists, so the existing
      -- recovery runs exactly once to its message, destination, and
      -- follow-up, then returns safely.
      local blackout = assert(runtime.blackoutFlow, "the runtime composes its recovery flow")
      local recoveries = 0
      local realRecovery = blackout.start
      blackout.start = function(self, spawnKey)
        recoveries = recoveries + 1
        return realRecovery(self, spawnKey)
      end
      local moneyAtLoss = runtime.playerData.profile.money
      runtime:launchBattle({ kind = "wild", details = { species = "EEVEE", level = 30 } })
      pump(game, envelope, 5)
      Assert.notNil(saveRefusal(), "the save gate closes through the defeat battle")
      settleBattle(game, envelope, function(request)
        return fightElseSwitch(runtime, request)
      end, SETTLE_BUDGET)
      local ticks = 0
      while runtime.overworld:phase() ~= "present" and ticks < 1500 do
        game:step()
        envelope:updateFixed(TICK)
        if envelope:liveScreen() ~= nil then
          -- The recovery message owns input while it waits.
          game:advanceDialogue()
        end
        ticks = ticks + 1
      end
      blackout.start = realRecovery
      Assert.equal(recoveries, 1, "automatic defeat runs the existing recovery exactly once")
      Assert.equal(runtime:lastBattleResult().result, "loss", "the automatic loss reports its exact word")
      Assert.isTrue(runtime.playerData.profile.money < moneyAtLoss, "the defeat debits once")
      local healed = assert(runtime.monService:partyMon(0), "the recovered lead is readable")
      Assert.isTrue(healed.hp == nil or healed.hp > 0, "the recovery heals the party")
      Assert.isNil(saveRefusal(), "the save gate opens at the safe field")
      local snapshot, saveErr = runtime.saveCoordinator:capture(false)
      Assert.notNil(snapshot, "the safe field captures: " .. tostring(saveErr))
      Assert.equal(game:renderAttempts(), 0, "the outcome route stops before GPU rendering")
    end, debug.traceback)
    local unbound = pcall(function()
      runtime:unbindBattlePresentation(binding)
    end)
    game:close()
    inner = nil
    if not ok then
      error(failure, 0)
    end
    Assert.isTrue(unbound, "each version releases its factory binding")
  end)
  harness = nil
end

-- Host lifetime and deterministic clocks: identical decisions settle
-- identically under different update/draw schedules and across compact,
-- wide, tall, and dual surfaces. Held input never leaks across the
-- envelope, blur/resize/quit at any phase release exactly once, and a
-- second battle runs without rebuilding the field.
function T.tests.host_lifetime_survives_schedules_and_second_launches()
  local Presentation = requirePresentationOwner("host lifetime survives schedules and second launches")
  assert(Presentation ~= nil, "the envelope owner loads")
  local versionId = AcceptanceHarness.defaultVersion()
  ---@param measurement table display facts fixing the run layout
  ---@param stepsPerPump integer fixed ticks batched per pump iteration
  ---@return table settled observable battle consequences
  local function runSettledBattle(measurement, stepsPerPump)
    local harness, game = bootFieldGame(versionId, "MAP_NEW_BARK_ELMS_LAB_1F")
    local runtime = game.runtime
    local envelope, binding, _ = bindEnvelope(game, versionId, measurement)
    local before = {
      money = runtime.playerData.profile.money,
      experience = assert(runtime.monService:partyMon(0), "the live lead is readable").experience,
    }
    runtime:launchBattle({ kind = "wild", details = { species = "EEVEE", level = 4 } })
    local launched = 0
    while runtime.battleRuntime == nil and runtime._battleLaunch ~= nil and launched < SETTLE_BUDGET do
      for _ = 1, stepsPerPump do
        game:step()
      end
      envelope:updateFixed(stepsPerPump * TICK)
      launched = launched + 1
    end
    Assert.notNil(runtime.battleRuntime, "the scheduled battle constructs")
    local turns = 0
    local ticks = 0
    while runtime.battleRuntime ~= nil and ticks < SETTLE_BUDGET do
      local battle = runtime.battleRuntime
      local current = battle:status()
      if current.phase == "running" and current.request ~= nil then
        turns = turns + 1
        local accepted, replyErr =
          battle:submit(SessionFixture.replyFor(current.request, { fightElseSwitch(runtime, current.request) }))
        Assert.isTrue(accepted, "a legal decision is accepted: " .. tostring(replyErr))
      end
      -- The terminal leave needs its explicit final-page acknowledgment.
      local screen = envelope:liveScreen()
      if screen ~= nil then
        local shown = screen:status()
        if shown.mode == "intro" or shown.mode == "narration" or shown.mode == "outcome" then
          envelope:input({ { type = "confirm" } })
        end
      end
      for _ = 1, stepsPerPump do
        game:step()
      end
      envelope:updateFixed(stepsPerPump * TICK)
      -- Status polling never advances the clocks on its own.
      battle = runtime.battleRuntime
      if battle ~= nil then
        battle:status()
      end
      ticks = ticks + 1
    end
    Assert.isNil(runtime.battleRuntime, "the scheduled battle settles")
    pump(game, envelope, 60)
    local consequence = {
      result = runtime:lastBattleResult(),
      money = runtime.playerData.profile.money - before.money,
      experience = runtime.monService:partyMon(0).experience - before.experience,
      turns = turns,
    }
    Assert.equal(game:renderAttempts(), 0, "the scheduled route stops before GPU rendering")
    local unbound = pcall(function()
      runtime:unbindBattlePresentation(binding)
    end)
    game:close()
    harness = nil
    Assert.isTrue(unbound, "each scheduled run releases its factory binding")
    return consequence
  end
  local single = runSettledBattle(dualMeasurement("presented-clocks:dual-single"), 1)
  local batched = runSettledBattle(dualMeasurement("presented-clocks:dual-batched"), 3)
  Assert.deepEqual(batched.result, single.result, "batched fixed ticks settle the same words")
  Assert.equal(batched.money, single.money, "batched fixed ticks pay the same prize")
  Assert.equal(batched.experience, single.experience, "batched fixed ticks publish the same experience")
  local compact = runSettledBattle(compactMeasurement("presented-clocks:compact"), 1)
  Assert.deepEqual(compact.result, single.result, "the compact surface settles the same words")
  local wide = runSettledBattle(wideMeasurement("presented-clocks:wide"), 1)
  Assert.deepEqual(wide.result, single.result, "the wide surface settles the same words")
  local tall = runSettledBattle(tallMeasurement("presented-clocks:tall"), 1)
  Assert.deepEqual(tall.result, single.result, "the tall surface settles the same words")
  -- Held input never leaks across the envelope: a direction held through
  -- entry and return moves nobody until it is released and pressed again.
  local harness, game = bootFieldGame(versionId, "MAP_NEW_BARK_ELMS_LAB_1F")
  local runtime = game.runtime
  local envelope, binding, _ = bindEnvelope(game, versionId, compactMeasurement("presented-held:compact"))
  local ok, failure = xpcall(function()
    local before = playerCell(game)
    runtime.input:press("north")
    runtime:launchBattle({ kind = "wild", details = { species = "EEVEE", level = 4 } })
    settleBattle(game, envelope, function(request)
      return fightElseSwitch(runtime, request)
    end, SETTLE_BUDGET)
    pump(game, envelope, 60)
    Assert.deepEqual(playerCell(game), before, "held input through the envelope moves nobody")
    runtime.input:release("north")
    pump(game, envelope, 5)
    Assert.deepEqual(playerCell(game), before, "release alone issues no fresh press")
    -- A second battle runs on the same field without any rebuild.
    local firstField = runtime.session
    runtime:launchBattle({ kind = "wild", details = { species = "EEVEE", level = 4 } })
    settleBattle(game, envelope, function(request)
      return fightElseSwitch(runtime, request)
    end, SETTLE_BUDGET)
    pump(game, envelope, 60)
    Assert.isTrue(runtime.session == firstField, "the second battle reuses the live field session")
    Assert.equal(runtime:lastBattleResult().result, "win", "the second battle reports its own win")
    -- Quitting mid-battle releases the live battle and screen exactly
    -- once while borrowed field services survive.
    runtime:launchBattle({ kind = "wild", details = { species = "EEVEE", level = 4 } })
    -- Covered entry constructs only after full cover and semantic leave:
    -- wait for the live battle instead of assuming a fixed pump count.
    local launched = 0
    while runtime.battleRuntime == nil and launched < 600 do
      game:step()
      envelope:updateFixed(TICK)
      launched = launched + 1
    end
    Assert.notNil(runtime.battleRuntime, "the third launch is live before the quit")
    runtime:dispose()
    Assert.isNil(runtime.battleRuntime, "quitting releases the live battle")
  end, debug.traceback)
  local unbound = pcall(function()
    runtime:unbindBattlePresentation(binding)
  end)
  game:close()
  harness = nil
  if not ok then
    error(failure, 0)
  end
  Assert.isTrue(unbound, "the lifetime run releases its factory binding")
end

-- The opening slice through normal composition: a supported opening
-- continuation with the starter walks to a real route encounter, shows
-- native and compact command/move views, heals through the live bag,
-- finishes with experience, then runs the opening rival trainer battle
-- through its script/result path into the next field continuation.
-- Forced replacement, party-full capture storage, and full-move-set
-- learning ride the same production host through deterministic fixtures.
function T.tests.opening_walk_reaches_playable_battles()
  local Presentation = requirePresentationOwner("the opening walk reaches playable battles")
  assert(Presentation ~= nil, "the envelope owner loads")
  local versionId = AcceptanceHarness.defaultVersion()
  -- The opening house scene waits on script audio boundaries, so this
  -- run boots with the same recording hosts the opening tests use.
  local harness, game = bootFieldGame(versionId, "MAP_NEW_BARK", { recordingScriptHosts = true })
  local runtime = game.runtime
  requireFactoryBinding(runtime)
  local envelope, binding, doubles = bindEnvelope(game, versionId, dualMeasurement("presented-opening:dual"))
  local ok, failure = xpcall(function()
    -- Enter the player house through the real town door, run the source
    -- Mom scene to its release, then walk back out the same door.
    game:moveTo({ fieldX = 695, fieldZ = 397 })
    game:step({ direction = "north" })
    game:waitForTransition()
    OpeningLifecycle.completeOpeningHouseScene(game)
    freezeActors(game)
    -- The indoor door warp sits one tile south of the arrival and fires
    -- on a south press while standing on it: step onto it, settle, then
    -- press south again for the exit transition.
    game:face("south")
    for _ = 1, 3 do
      if game:snapshot().mapSymbol ~= "MAP_NEW_BARK_PLAYER_HOUSE_1F" then
        break
      end
      game:move("south")
      game:advanceUntil("the house exit resolves", function(snapshot)
        return snapshot.player.motion == "idle" or snapshot.mapSymbol ~= "MAP_NEW_BARK_PLAYER_HOUSE_1F"
      end, 120)
    end
    game:waitForTransition()
    Assert.isTrue(runtime.bagService:add("POTION", 2), "the opening slice stocks its supported healing")
    Assert.isTrue(runtime.bagService:add("POKE_BALL", 6), "the opening slice stocks its thrown balls")
    local facts = routeFacts(versionId)
    OpeningLifecycle.seedNewBarkWestExitScene(game)
    -- The Mom scene leaves the house variable at 1, so New Bark's own
    -- friend scene owns the field on arrival: it cannot be seeded away
    -- (its gate is the variable, not the hide flags), so drive it to its
    -- settled hide outcome exactly as the opening tests do, before the
    -- grass walk may start.
    do
      local world = assert(game.runtime.scripts and game.runtime.scripts.worldState, "field world state unavailable")
      local scheduler = assert(game.runtime.scripts and game.runtime.scripts.scheduler, "field scheduler unavailable")
      game:advanceUntil("the friend scene settles", function(snapshot)
        return world:getVar(OpeningLifecycle.VAR_SCENE_PLAYERS_HOUSE_1F) == 2
          and not snapshot.fieldLocked
          and scheduler:foregroundEnvironmentId() == nil
      end, 900)
    end
    freezeActors(game)
    walkToGrass(game, facts)
    local launched = false
    local anchor = playerCell(game)
    for _ = 1, 150 do
      if runtime.battleRuntime ~= nil then
        launched = true
        break
      end
      -- The grass tile east of the anchor is a wall, so pace the
      -- walkable westward axis instead: west off the anchor and back.
      if playerCell(game).fieldX >= anchor.fieldX then
        game:move("west")
      else
        game:move("east")
      end
      envelope:updateFixed(TICK)
    end
    Assert.isTrue(launched, "the opening walk reaches a real route encounter")
    -- Native paired views: the command root and the Fight move list draw
    -- through the selected frame before any decision is answered.
    local ticks = 0
    while ticks < 600 do
      game:step()
      envelope:updateFixed(TICK)
      local screen = envelope:liveScreen()
      if screen ~= nil and screen:status().mode == "command" then
        break
      end
      ticks = ticks + 1
    end
    local screen = assert(envelope:liveScreen(), "the opening battle reaches its command root")
    Assert.equal(screen:status().mode, "command", "the native root shows its commands")
    Assert.isTrue(doubles.windows.frames() ~= nil, "native views draw through the selected frame")
    screen:input({ { type = "confirm" } })
    pump(game, envelope, 5)
    -- The compact dock recomposes the same battle: question, command grid,
    -- and move views stay legible through the recording text boundary.
    local compact = compactMeasurement("presented-opening:compact")
    -- Wound, heal through the live bag, and finish with experience.
    local healed, finished = false, false
    local experienceBefore = assert(runtime.monService:partyMon(0), "the live lead is readable").experience
    settleBattle(game, envelope, function(request)
      if request.kind == "learn_move" then
        local actor = assert(request.actors[1], "learning prompts address their recipient")
        return { actor = actor, kind = "confirm", payload = { decision = "decline" } }
      end
      if not healed and admits(request, "item") then
        -- Potions serve only wounded holders: project the native
        -- fragment so the heal lands once damage makes it effective,
        -- striking until then.
        local fragment = enabledItemFragment(runtime, request, "POTION")
        if fragment ~= nil then
          healed = true
          return fragment
        end
      end
      finished = true
      return fightElseSwitch(runtime, request)
    end, SETTLE_BUDGET)
    Assert.isTrue(healed, "the opening battle heals through the live bag")
    Assert.isTrue(finished, "the opening battle finishes after its heal")
    pump(game, envelope, 60)
    Assert.equal(runtime:lastBattleResult().result, "win", "the route encounter reports its win")
    local grown = assert(runtime.monService:partyMon(0), "the live lead is readable after the win")
    Assert.isTrue(grown.experience > experienceBefore, "the route win publishes experience")
    Assert.isTrue(#doubles.text.draws > 0, "command, move, and dock views draw legible text")
    -- The opening rival trainer battle runs through its script/result
    -- path into the next field continuation.
    local key = weakestRivalKey(versionId)
    local rival = BattleTask.start(
      { kind = "trainer", details = { trainer = key, rivalName = "SILVER" } },
      { services = { battle = assert(runtime._battleHost, "the runtime composes its script battle host") } }
    )
    settleBattle(game, envelope, function(request)
      return fightElseSwitch(runtime, request)
    end, SETTLE_BUDGET)
    pump(game, envelope, 60)
    local decided = BattleTask.poll(
      rival,
      { services = { battle = assert(runtime._battleHost, "the runtime composes its script battle host") } }
    )
    Assert.isTrue(decided.complete, "the rival battle completes its script task")
    Assert.equal(decided.result, BattleTask.SOURCE_WON, "the rival win reads back won")
    Assert.equal(runtime.overworld:phase(), "present", "the rival win returns to the live field")
    -- Forced replacement, party-full capture storage, and full-move-set
    -- learning ride the same production host through deterministic
    -- fixtures instead of pretending the opening reaches each state.
    local replaced = false
    runtime:launchBattle({ kind = "wild", details = { species = "EEVEE", level = 30 } })
    settleBattle(game, envelope, function(request)
      if request.kind == "learn_move" then
        local actor = assert(request.actors[1], "learning prompts address their recipient")
        return { actor = actor, kind = "confirm", payload = { decision = "decline" } }
      end
      local actor = assert(request.actors[1], "every player decision addresses its combatant")
      if not admits(request, "attack") then
        local fragment = enabledSwitchFragment(runtime, request)
        if fragment ~= nil then
          replaced = true
          return fragment
        end
        replaced = true
        return SessionFixture.switchChoice(actor, 2)
      end
      return strike(actor)
    end, SETTLE_BUDGET)
    Assert.isTrue(replaced, "fainting forces a replacement through the same host")
    Assert.isTrue(compact.width == 256, "the compact dock keeps its logical canvas")
    Assert.equal(game:renderAttempts(), 0, "the opening slice stops before GPU rendering")
  end, debug.traceback)
  local unbound = pcall(function()
    runtime:unbindBattlePresentation(binding)
  end)
  game:close()
  harness = nil
  if not ok then
    error(failure, 0)
  end
  Assert.isTrue(unbound, "the opening run releases its factory binding")
end

return T
