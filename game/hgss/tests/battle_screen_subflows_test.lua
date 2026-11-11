-- Screen-level coverage for the battle child flows: voluntary and forced
-- party selection without persistent reordering, battle bag selection with
-- consumption owned only by native execution and capture, held-recipient
-- move learning with explicit replace and decline confirmations, and child
-- input and lifetime isolation.
--
-- Every flow drives the real battle lifetime (real scenario factory, real
-- native session, real committer) through the real screen and its
-- presentation port, with paired and compact display facts and recording
-- graphics and audio doubles. Fixtures stay synthetic, so the run needs no
-- dump capability. Each flow first reaches its decision point through
-- production composition, then requires the dedicated party, bag, and
-- learning child owner, so the run stays red until that owner lands.

local Assert = require("tests.support.Assert")
local BattlePresentationManifestFixture = require("tests.support.BattlePresentationManifestFixture")
local FakeGraphics = require("tests.support.FakeGraphics")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local HgssBagService = require("libs.hgss.src.items.HgssBagService")
local ItemFixture = require("libs.items.tests.item_fixture")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")
local ScreenTopology = require("libs.ui.src.ScreenTopology")
local SourceTick = require("libs.hgss.src.field.SourceTick")

local T = {}
local TICK = SourceTick.DT

local CHILD_OWNER_MODULE = "game.hgss.src.battle.BattleSubflows"
local RUNTIME_MODULE = "game.hgss.src.battle.BattleRuntime"
local STATE_MODULE = "game.hgss.tests.support.BattleScreenFixture"
local MODEL_MODULE = "game.hgss.src.battle.BattlePresentationModel"
local SCENARIO_FACTORY_MODULE = "libs.hgss.src.battle.HgssBattleScenarioFactory"

---@param behavior string the missing child responsibility naming this red
local function requireChildOwner(behavior)
  local ok, owner = pcall(require, CHILD_OWNER_MODULE)
  Assert.isTrue(
    ok,
    "the battle screen owns its party, bag, and learning children: " .. behavior .. " (" .. CHILD_OWNER_MODULE .. ")"
  )
  assert(owner ~= nil, "the battle child owner loads")
end

---@return table per-launch battle view over the shared core for the child harness scene
local function screenManifest()
  -- The child binds one launch view, never the global inventory: the
  -- exact backpic, trainer fronts, and ball behind these rigs stage as
  -- launch entries (numeric trainer class 2 resolves to YOUNGSTER).
  local manifest = BattlePresentationManifestFixture.launchView(
    { "back:PKMN_TRAINER_ETHAN", "front:YOUNGSTER" },
    { "ball:POKE_BALL" }
  )
  manifest.scenes = { { key = "general/plain/day", background = "general", terrain = "plain", time = "day" } }
  return manifest
end

---@param image table fake image handle under inspection
---@return integer staged image width
local function fakeImageWidth(image)
  return image.width
end

---@param image table fake image handle under inspection
---@return integer staged image height
local function fakeImageHeight(image)
  return image.height
end

---@param image table fake image handle under inspection
---@return integer, integer staged image dimensions
local function fakeImageDimensions(image)
  return image.width, image.height
end

local function fakeImageSetFilter() end

---@param key string image identity under test preparation
---@return table fake image handle carrying the renderer-required dimensions
local function fakeDrawable(key)
  local hudImage = key:match("^hud:") ~= nil
  return {
    handle = key,
    width = hudImage and 1648 or 80,
    height = hudImage and 8 or 80,
    getWidth = fakeImageWidth,
    getHeight = fakeImageHeight,
    getDimensions = fakeImageDimensions,
    setFilter = fakeImageSetFilter,
  }
end

---@param layout string "paired" or "compact" surface arrangement under test driving
---@return table caller-owned display facts for the layout
local function measurementFor(layout)
  if layout == "compact" then
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
      signature = "battle-child-test:compact",
    }
  end
  return {
    width = 256,
    height = 384,
    topology = ScreenTopology.dualDisplay(
      { id = "main", rect = { x = 0, y = 0, width = 256, height = 192 }, touch = false, role = "world" },
      { id = "lower", rect = { x = 0, y = 192, width = 256, height = 192 }, touch = true, role = "auxiliary" }
    ),
    pixelRatio = 1,
    signature = "battle-child-test:paired",
  }
end

---@param specs table lead/reserve descriptions under test preparation
---@return table live party owner holding the described members in order
local function makePartyOwner(specs)
  local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
  local catalog = CatalogFixture.makeCatalog()
  local owner = HgssMonService.new({
    catalog = catalog,
    bucket = MonsSave.capture(Party.new():capture(), Lcrng.new(0x22222222):capture()),
    profile = CatalogFixture.profile(),
    game = "heartgold",
    language = "english",
    charmap = CatalogFixture.CHARMAP,
    games = CatalogFixture.GAMES,
    languages = CatalogFixture.LANGUAGES,
    items = CatalogFixture.ITEMS,
    balls = CatalogFixture.BALLS,
    mapSection = 7,
    date = CatalogFixture.metDate(),
  })
  for _, member in ipairs(specs) do
    local factory = CatalogFixture.makeFactory(member.seed, catalog)
    local req = { species = member.species, level = member.level }
    if member.ability ~= nil then
      req.ability = member.ability
    end
    local record = factory:createNormal(CatalogFixture.normalRequest(req))
    if member.moves ~= nil then
      record.moves = member.moves
    end
    if member.experience ~= nil then
      record.experience = member.experience
    end
    if member.currentHp ~= nil then
      record.condition.currentHp = member.currentHp
    end
    if member.heldItem ~= nil then
      record.heldItem = member.heldItem
    end
    Assert.isTrue(owner:addMon(record), "the child path needs its live party member")
  end
  return owner
end

---@param spec table foe description under test preparation
---@return table full mon-domain record for the enemy side
local function makeFoe(spec)
  local catalog = CatalogFixture.makeCatalog()
  local factory = CatalogFixture.makeFactory(spec.seed, catalog)
  local record = factory:createNormal(CatalogFixture.normalRequest({ species = spec.species, level = spec.level }))
  record.moves = spec.moves or { { move = "TACKLE", pp = 35, ppUps = 0 } }
  if spec.currentHp ~= nil then
    record.condition.currentHp = spec.currentHp
  end
  return record
end

---@param opts table rig options under test preparation
---@return table live rig with the runtime, screen, stocked bag, and submit log
local function openRig(opts)
  local BattleRuntime = require(RUNTIME_MODULE)
  local BattleScreenState = require(STATE_MODULE)
  local Model = require(MODEL_MODULE)
  local ScenarioFactory = require(SCENARIO_FACTORY_MODULE)
  local holder = {}
  local layout = opts.layout or "paired"
  local rig = {
    submits = {},
    measurement = measurementFor(layout),
    layout = layout,
    text = { draws = {} },
    windows = { calls = {}, background = { 0.2, 0.3, 0.1, 1 } },
    audio = { plays = {} },
    assetsReady = opts.pendingAssets ~= true,
    assets = { prepared = {}, released = {} },
  }
  function rig.text.measure(content)
    return { width = 8 * #tostring(content), height = 16 }
  end
  function rig.text.drawText(content, x, y)
    rig.text.draws[#rig.text.draws + 1] = { content = tostring(content), x = x, y = y }
  end
  function rig.text.drawTextForRole(role, content, x, y, palette)
    rig.text.draws[#rig.text.draws + 1] =
      { role = tostring(role), content = tostring(content), x = x, y = y, palette = palette }
  end
  function rig.windows.drawWindow(box, frameKey, background)
    rig.windows.calls[#rig.windows.calls + 1] = { box = box, frame = frameKey, background = background }
  end
  function rig.windows.drawApplicationFrame(box, frameIndex)
    rig.windows.calls[#rig.windows.calls + 1] = { applicationBox = box, frame = frameIndex }
  end
  function rig.audio.play(first, second)
    -- The production voice subsystem dispatches sink ports colon-style,
    -- so the recorded semantic cue is the second argument when present.
    rig.audio.plays[#rig.audio.plays + 1] = second ~= nil and second or first
    return true
  end
  function rig.audio.playPanned(_, symbol, pan)
    rig.audio.plays[#rig.audio.plays + 1] = symbol
    rig.audio.pans = rig.audio.pans or {}
    rig.audio.pans[#rig.audio.pans + 1] = pan
    return true
  end
  function rig.audio.playFanfare(_, symbol)
    rig.audio.plays[#rig.audio.plays + 1] = symbol
    return true
  end
  function rig.audio.stop(_, symbol)
    rig.audio.stops = rig.audio.stops or {}
    rig.audio.stops[#rig.audio.stops + 1] = symbol
    return true
  end
  function rig.assets.prepare(demand)
    rig.assets.prepared[#rig.assets.prepared + 1] = demand
    return rig.assetsReady
  end
  function rig.assets.drawable(key)
    if rig.assets.images == nil then
      rig.assets.images = {}
    end
    if rig.assets.images[key] == nil then
      rig.assets.images[key] = fakeDrawable(key)
    end
    return rig.assets.images[key]
  end
  function rig.assets.release(key)
    rig.assets.released[key] = (rig.assets.released[key] or 0) + 1
  end
  local party = makePartyOwner(opts.party)
  local bag = HgssBagService.new({ catalog = ItemFixture.makeCatalog() })
  for _, stocked in ipairs(opts.bag or {}) do
    Assert.isTrue(bag:add(stocked.key, stocked.qty), "the child path stocks its " .. stocked.key)
  end
  -- Battle children select only: the persistent reorder, healing, and
  -- inventory write entries stay guarded and throw if reached. Genuine
  -- consumption publishes through staged battle candidates instead, so
  -- these guards stay silent on the correct path.
  for _, key in ipairs({ "take", "move", "tryRegister", "unregister" }) do
    local entry = bag[key]
    assert(entry ~= nil, "the bag carries its " .. key .. " entry under guard")
    bag[key] = function()
      error("the battle child never calls bag " .. key, 2)
    end
  end
  party.swapPartyMons = function()
    error("a battle switch never reorders the persistent party", 2)
  end
  party.healParty = function()
    error("a battle item never heals through the field service", 2)
  end
  rig.party = party
  rig.bag = bag
  local launchId = opts.launchId or "launch-battle-child"
  local foeSpec = opts.foe or { species = "EEVEE", level = 4, seed = 0x5EED0002 }
  local foe = makeFoe(foeSpec)
  local player = { trainerId = 99, trainerName = "MINT", language = "french", trainerClassKey = "PKMN_TRAINER_ETHAN" }
  local launch = nil
  local scenario = nil
  if opts.trainer == true then
    local trainerId = launchId .. "-rival"
    scenario = ScenarioFactory.fromTrainer({
      id = launchId .. "-scenario",
      trainers = {
        {
          id = trainerId,
          name = "WHITNEY",
          class = 2,
          party = { foe },
          partyLevels = { foeSpec.level },
          prizeMoney = { trainerClass = 2, classRate = 4 },
          program = { key = "rival_opening", revision = "native-1", instructions = {}, entryPoints = {} },
          aiPasses = {},
        },
      },
    }, { party = party, bag = bag, player = player })
    launch = { id = launchId, kind = "trainer", payload = { trainer = trainerId } }
  else
    scenario = ScenarioFactory.fromEncounter(
      { attemptId = launchId .. "-attempt", mon = foe },
      { party = party, bag = bag, player = player }
    )
    launch = {
      id = launchId,
      kind = "wild",
      payload = {
        attemptId = launchId .. "-attempt",
        species = foeSpec.species,
        form = 0,
        level = foeSpec.level,
        personality = 1,
        ability = "RUN_AWAY",
      },
    }
  end
  rig.scenario = scenario
  local screen = BattleScreenState.new({
    splRandomState = { state = 0 },
    launchId = launchId,
    manifest = screenManifest(),
    model = Model,
    submit = function(reply)
      rig.submits[#rig.submits + 1] = reply
      return holder.battle:submit(reply)
    end,
    measureDisplay = function()
      return rig.measurement
    end,
    -- The battle screen borrows the immutable
    -- item catalog so its bag child can group stocked items by pocket.
    itemCatalog = ItemFixture.makeCatalog(),
    monCatalog = CatalogFixture.makeCatalog(),
    bagCursor = opts.bagCursor,
    assets = rig.assets,
    text = rig.text,
    windows = rig.windows,
    audio = rig.audio,
  })
  rig.screen = screen
  rig.port = screen:presentationPort()
  holder.battle = BattleRuntime.new({
    request = launch,
    scenario = scenario,
    party = party,
    bag = bag,
    presentation = rig.port,
    seed = opts.seedNum or 0x12345678,
  })
  rig.battle = holder.battle
  function rig.pump(ticks)
    for _ = 1, ticks or 1 do
      rig.battle:update()
      rig.screen:updateFixed(TICK)
    end
  end
  return rig
end

---@param rig table live screen rig under test driving
-- Advances one currently visible narration wait through real screen input.
local function ackNarration(rig)
  local mode = rig.screen:status().mode
  if
    mode == "intro"
    or mode == "narration"
    or mode == "outcome"
    or rig.screen._timeline:messageActive()
    or rig.screen._timeline:levelUpStats() ~= nil
  then
    rig.screen:input({ { type = "confirm" } })
  end
end

---@param rig table live screen rig under test driving
---@param mode string awaited controller mode under test driving
---@return table the screen status once the mode is reached
local function driveToMode(rig, mode)
  for _ = 1, 600 do
    ackNarration(rig)
    rig.pump(1)
    local status = rig.screen:status()
    if status.mode == "failed" then
      error("the battle screen failed while driving to " .. mode .. ": " .. tostring(status.error), 0)
    end
    if status.mode == mode and (mode ~= "command" and mode ~= "moves" or rig.screen:view().menuInputEnabled) then
      return status
    end
  end
  local screenStatus = rig.screen:status()
  local battleStatus = rig.battle:status()
  error(
    "the battle screen never reached "
      .. mode
      .. " ("
      .. rig.layout
      .. ", screen "
      .. tostring(screenStatus.mode)
      .. ", battle "
      .. tostring(battleStatus.phase)
      .. ", "
      .. tostring(battleStatus.error)
      .. ")",
    0
  )
end

---@param rig table live screen rig under test driving
---@param event table<string, unknown> semantic input batch under test driving
local function press(rig, event)
  rig.screen:input({ event })
  rig.pump(1)
end

-- Settles one gated bag press (WaitButtonAnim): frame 1 rebounds to
-- frame 2, then the deferred page transition applies.
---@param rig table live screen rig under test driving
local function settlePress(rig)
  rig.pump(2)
end

---@param rig table live screen rig under test driving
local function useNativeBattleBagItem(rig)
  press(rig, { type = "confirm" })
  settlePress(rig)
  press(rig, { type = "confirm" })
  rig.pump(8)
end

---@param rig table live screen rig under test driving, resting on its command prompt
local function waitForMenuInput(rig)
  -- Each entry to the command prompt reveals before it arms: menu
  -- presses wait for the production input gate instead of racing it.
  for _ = 1, 30 do
    if rig.screen:status().mode ~= "command" or rig.screen:view().menuInputEnabled then
      break
    end
    rig.pump(1)
  end
end

---@param rig table live screen rig under test driving, resting on its command prompt
local function openPartyFromCommand(rig)
  waitForMenuInput(rig)
  -- Source 3x2 cursor grid: Fight spans the upper row while Bag, Run,
  -- and Pokemon fill the lower row, so Pokemon takes down, right, right.
  press(rig, { type = "navigate", direction = "down" })
  press(rig, { type = "navigate", direction = "right" })
  press(rig, { type = "navigate", direction = "right" })
  press(rig, { type = "confirm" })
  local status = rig.screen:status()
  Assert.equal(
    status.mode,
    "child",
    "the Pokemon command opens the party child ("
      .. rig.layout
      .. ", mode "
      .. tostring(status.mode)
      .. ", error "
      .. tostring(status.error)
      .. ")"
  )
end

---@param rig table live screen rig under test driving, resting on its command prompt
local function openBagFromCommand(rig)
  waitForMenuInput(rig)
  press(rig, { type = "navigate", direction = "down" })
  press(rig, { type = "navigate", direction = "left" })
  press(rig, { type = "confirm" })
  Assert.equal(rig.screen:status().mode, "child", "the Bag command opens the bag child (" .. rig.layout .. ")")
end

-- The pocket menu opens on HP/PP; BALLS sits one step right in the top
-- row. Confirming a pocket opens its item list on the remembered cell.
---@param rig table live screen rig under test driving, resting on the open bag child
local function walkToMedicineFirstCell(rig)
  press(rig, { type = "confirm" })
  settlePress(rig)
end

---@param rig table live screen rig under test driving, resting on the open bag child
local function walkToBallsFirstCell(rig)
  press(rig, { type = "navigate", direction = "right" })
  press(rig, { type = "confirm" })
  settlePress(rig)
end

---@param rig table live screen rig under test driving
---@return table the mirrored open request under test driving
local function openScreenRequest(rig)
  local request = rig.screen:status().request
  Assert.notNil(request, "the prompt mirrors its request (" .. rig.layout .. ")")
  return request --[[@as table<string, unknown>]]
end

---@param rig table live screen rig under test driving
---@param request table open request under projection
---@return table detached native decision options for the open request
local function optionsFor(rig, request)
  local options, optionsErr = rig.battle:decisionOptions(request.requestId)
  Assert.notNil(options, "the runtime projects options for the open request: " .. tostring(optionsErr))
  return options --[[@as table<string, unknown>]]
end

-- The projected voluntary and replacement switches name exactly one
-- reserve by its stable combatant identity, so any sealed reply must
-- match it; a displayed slot can never stand in for the combatant.
---@param rig table live screen rig under test driving
---@param request table open request under projection
---@return integer stable combatant identity of the eligible reserve
---@return table the projected switch fragment naming the reserve
local function projectedReserveSwitch(rig, request)
  local options = optionsFor(rig, request)
  local foundId = nil
  local foundFragment = nil
  for _, actor in ipairs(options.actors) do
    for _, choice in ipairs(actor.choices) do
      if type(choice.id) == "string" and choice.id:match("^switch:") ~= nil then
        Assert.isNil(foundId, "one reserve switch is projected (" .. rig.layout .. ")")
        Assert.isTrue(choice.enabled, "the living reserve stays selectable (" .. rig.layout .. ")")
        foundId = tonumber(choice.id:match("^switch:(%d+)$"))
        foundFragment = choice.choice
      end
    end
  end
  Assert.notNil(foundId, "the eligible reserve is projected (" .. rig.layout .. ")")
  return foundId, --[[@as integer]]
    foundFragment --[[@as table<string, unknown>]]
end

---@param rig table live screen rig under test driving
---@param request table open action request under projection
---@return table the first enabled move fragment, still unsubmitted
local function firstEnabledMoveFragment(rig, request)
  local options = optionsFor(rig, request)
  for _, actor in ipairs(options.actors) do
    for _, choice in ipairs(actor.choices) do
      if choice.role == "move" and choice.enabled == true then
        return choice.choice
      end
    end
  end
  error("the action request carries an enabled move (" .. rig.layout .. ")", 0)
end

---@param rig table live screen rig under test driving
---@param request table open action request under submission
local function submitFirstEnabledMove(rig, request)
  local fragment = firstEnabledMoveFragment(rig, request)
  local ok, submitErr = rig.battle:submit({
    requestId = request.requestId,
    epoch = request.epoch,
    controller = request.controller,
    choices = { fragment },
  })
  Assert.isTrue(ok, "the kernel accepts the projected move: " .. tostring(submitErr))
end

---@param request table battle request under inspection
---@return string the decision kind carried by the request
local function requestKind(request)
  -- A faint replacement arrives as a
  -- switch-only action decision; the admitted vocabulary carries it, as
  -- the runtime suite pins, while the request kind alone never names it.
  if type(request.kind) == "string" and request.kind ~= "action" then
    return request.kind --[[@as string]]
  end
  if type(request.legalChoices) == "table" and type(request.legalChoices.kinds) == "table" then
    local attack = false
    local switch = false
    for _, kind in ipairs(request.legalChoices.kinds) do
      if kind == "attack" then
        attack = true
      end
      if kind == "switch" then
        switch = true
      end
    end
    if switch and not attack then
      return "replacement"
    end
  end
  if type(request.kind) == "string" then
    return request.kind --[[@as string]]
  end
  if type(request.actors) == "table" and type(request.actors[1]) == "table" then
    return request.actors[1].kind --[[@as string]]
  end
  return ""
end

---@param rig table live screen rig under test driving
---@param wanted string awaited battle decision kind under test driving
---@return table the battle request once the kernel asks for the wanted decision
local function waitForBattleDecision(rig, wanted)
  for _ = 1, 60 do
    for _ = 1, 40 do
      ackNarration(rig)
      rig.pump(1)
      local status = rig.battle:status()
      if status.phase == "failed" then
        error("the battle failed while awaiting " .. wanted .. ": " .. tostring(status.error), 0)
      end
      if status.phase == "complete" then
        error("the battle settled before asking for " .. wanted, 0)
      end
      if status.phase ~= "running" then
        break
      end
      if status.request ~= nil and requestKind(status.request) ~= "action" then
        if requestKind(status.request) == wanted then
          return status.request
        end
        error("the battle asked for " .. requestKind(status.request) .. " instead of " .. wanted, 0)
      end
    end
    local current = rig.battle:status()
    if current.request ~= nil and requestKind(current.request) == "action" then
      submitFirstEnabledMove(rig, current.request)
    end
  end
  error("the battle never asked for " .. wanted .. " (" .. rig.layout .. ")", 0)
end

---@param rig table live screen rig under test driving
---@param wanted string awaited battle decision kind under test driving
---@return table the mirrored screen request once the screen catches up
local function waitForScreenDecision(rig, wanted)
  -- Match the live battle request, not a
  -- retired decision of the same kind the screen has not drained yet.
  for _ = 1, 1200 do
    ackNarration(rig)
    rig.pump(1)
    local status = rig.screen:status()
    if status.mode == "failed" then
      error("the screen failed while awaiting " .. wanted .. ": " .. tostring(status.error), 0)
    end
    if status.request ~= nil and requestKind(status.request) == wanted then
      local current = rig.battle:status()
      if current.request == nil or current.request.requestId == status.request.requestId then
        return status.request
      end
    end
  end
  error("the screen never mirrored " .. wanted .. " (" .. rig.layout .. ")", 0)
end

-- Choosing a reserve through the party child stays correct: the native
-- Switch menu refuses the lead, then the reserve seals the projected
-- fragment. At most one reply seals.
---@param rig table live screen rig under test driving, resting on the open party child
local function chooseReserveThroughChild(rig)
  press(rig, { type = "confirm" })
  if #rig.submits == 0 and rig.screen:status().mode == "child" then
    press(rig, { type = "confirm" })
    rig.pump(5)
  end
  if #rig.submits == 0 and rig.screen:status().mode == "child" then
    press(rig, { type = "navigate", direction = "down" })
    press(rig, { type = "confirm" })
    press(rig, { type = "confirm" })
    rig.pump(5)
  end
  if #rig.submits == 0 and rig.screen:status().mode ~= "child" then
    openPartyFromCommand(rig)
    press(rig, { type = "navigate", direction = "down" })
    press(rig, { type = "confirm" })
  end
end

---@param submitted table sealed choice fragment under comparison
---@param candidates table<integer, table<string, unknown>> projected enabled fragments under comparison
---@param message string failure context under comparison
local function assertChoiceAmong(submitted, candidates, message)
  for _, candidate in ipairs(candidates) do
    local ok = pcall(Assert.deepEqual, submitted, candidate, message)
    if ok then
      return
    end
  end
  error(message .. " (no projected choice matched)", 0)
end

-- Voluntary selection submits the correct replacement combatant through
-- the kernel, leaves the persistent order untouched, and spends nothing
-- on cancel; after a real faint every cancel and outside path stays
-- blocked until the eligible reserve is chosen. Both same-species slots
-- share one species, so only the stable combatant identity can
-- distinguish the reply.
function T.voluntary_switch_and_forced_replacement_keep_field_order()
  for _, layout in ipairs({ "paired", "compact" }) do
    local tag = " (" .. layout .. ")"
    local rig = openRig({
      layout = layout,
      launchId = "launch-child-switch-" .. layout,
      party = {
        { species = "EEVEE", level = 20, seed = 0x33333333 },
        { species = "EEVEE", level = 5, seed = 0x44444444, ability = "RUN_AWAY" },
      },
      bag = {},
    })
    local first = rig.party:partyMon(0)
    local second = rig.party:partyMon(1)
    driveToMode(rig, "command")
    local commandRequest = openScreenRequest(rig)
    local reserveId, expectedSwitch = projectedReserveSwitch(rig, commandRequest)
    requireChildOwner("voluntary party selection")
    -- Cancel spends no turn: the same command request stays open with no
    -- reply, and focus rests on the Pokemon command.
    openPartyFromCommand(rig)
    press(rig, { type = "cancel" })
    Assert.equal(rig.screen:status().mode, "command", "cancel from party returns to command" .. tag)
    Assert.equal(
      openScreenRequest(rig).requestId,
      commandRequest.requestId,
      "cancel from party keeps the same command request" .. tag
    )
    Assert.equal(#rig.submits, 0, "cancel from party spends no turn" .. tag)
    Assert.equal(rig.screen:view().selection, "pokemon", "cancel from party keeps its command focus" .. tag)
    -- Choosing the reserve seals exactly one reply that matches the
    -- projected fragment for the stable reserve identity.
    openPartyFromCommand(rig)
    chooseReserveThroughChild(rig)
    Assert.equal(#rig.submits, 1, "choosing the reserve seals exactly one reply" .. tag)
    local sealed = rig.submits[1]
    Assert.equal(sealed.requestId, commandRequest.requestId, "the reply answers the open request" .. tag)
    Assert.equal(sealed.epoch, commandRequest.epoch, "the reply carries the open epoch" .. tag)
    Assert.equal(sealed.controller, commandRequest.controller, "the reply carries the open controller" .. tag)
    Assert.deepEqual(sealed.choices[1], expectedSwitch, "the reply names the stable reserve combatant" .. tag)
    -- partyMon returns detached copies, so
    -- order preservation compares content instead of object identity.
    Assert.deepEqual(rig.party:partyMon(0), first, "the switch never reorders the persistent lead" .. tag)
    Assert.deepEqual(rig.party:partyMon(1), second, "the switch never reorders the persistent reserve" .. tag)
    -- The kernel changes the active battler: the next action decision
    -- addresses the reserve combatant.
    local nextRequest = nil
    for _ = 1, 800 do
      rig.pump(1)
      local status = rig.battle:status()
      if status.phase == "failed" then
        error("the battle failed after the switch", 0)
      end
      if status.phase ~= "running" then
        break
      end
      if status.request ~= nil and requestKind(status.request) == "action" then
        nextRequest = status.request
        break
      end
    end
    Assert.notNil(nextRequest, "the switched turn reaches its next decision" .. tag)
    Assert.equal(
      nextRequest.actors[1].combatant,
      reserveId,
      "the reserve combatant holds the field after the switch" .. tag
    )
    rig.screen:dispose()
    rig.battle:dispose()

    -- Forced replacement after a real faint: no cancel or outside path
    -- escapes, and only the eligible reserve leaves the state.
    local forced = openRig({
      layout = layout,
      launchId = "launch-child-forced-" .. layout,
      party = {
        { species = "EEVEE", level = 5, seed = 0x55555555 },
        { species = "EEVEE", level = 5, seed = 0x66666666 },
      },
      bag = {},
      foe = { species = "EEVEE", level = 30, seed = 0x5EED0002 },
    })
    local forcedFirst = forced.party:partyMon(0)
    local forcedSecond = forced.party:partyMon(1)
    waitForBattleDecision(forced, "replacement")
    local replacementRequest = waitForScreenDecision(forced, "replacement")
    Assert.equal(forced.screen:status().mode, "child", "the faint opens the replacement child" .. tag)
    local _, expectedReplacement = projectedReserveSwitch(forced, replacementRequest)
    requireChildOwner("forced party replacement")
    press(forced, { type = "cancel" })
    Assert.equal(forced.screen:status().mode, "child", "keyboard cancel never leaves forced replacement" .. tag)
    Assert.equal(#forced.submits, 0, "keyboard cancel seals no replacement reply" .. tag)
    forced.screen:input({
      { type = "pointer_down", pointerId = "probe:out", x = 10000, y = 10000 },
      { type = "pointer_up", pointerId = "probe:out", x = 10000, y = 10000 },
    })
    forced.pump(1)
    Assert.equal(forced.screen:status().mode, "child", "an outside press never leaves forced replacement" .. tag)
    Assert.equal(#forced.submits, 0, "an outside press seals no replacement reply" .. tag)
    chooseReserveThroughChild(forced)
    Assert.equal(#forced.submits, 1, "the replacement seals exactly one reply" .. tag)
    Assert.deepEqual(
      forced.submits[1].choices[1],
      expectedReplacement,
      "the replacement names the stable reserve combatant" .. tag
    )
    -- See the voluntary order note above: partyMon returns detached
    -- copies, so order preservation compares content instead of identity.
    Assert.deepEqual(forced.party:partyMon(0), forcedFirst, "the replacement never reorders the lead" .. tag)
    Assert.deepEqual(forced.party:partyMon(1), forcedSecond, "the replacement never reorders the reserve" .. tag)
    forced.screen:dispose()
    forced.battle:dispose()

    -- With no living reserve the kernel settles the terminal outcome
    -- instead of the child inventing a replacement.
    local wiped = openRig({
      layout = layout,
      launchId = "launch-child-noreserve-" .. layout,
      party = {
        { species = "EEVEE", level = 5, seed = 0x77777777 },
      },
      bag = {},
      foe = { species = "EEVEE", level = 30, seed = 0x5EED0003 },
    })
    for _ = 1, 120 do
      local current = wiped.battle:status()
      if current.phase == "complete" or current.phase == "failed" then
        break
      end
      if current.request ~= nil and requestKind(current.request) == "action" then
        submitFirstEnabledMove(wiped, current.request)
      end
      if wiped.screen:status().mode ~= "outcome" then
        ackNarration(wiped)
      end
      wiped.pump(20)
    end
    Assert.equal(wiped.battle:status().phase, "complete", "the wiped side settles the battle" .. tag)
    Assert.equal(wiped.battle:status().result, "loss", "the wiped side reports its loss" .. tag)
    Assert.isTrue(wiped.screen:_portLeave({}), "the loss completes its timed outcome without an acknowledgment" .. tag)
    Assert.equal(#wiped.submits, 0, "no invented reserve reply ever seals" .. tag)
    wiped.screen:dispose()
    wiped.battle:dispose()
  end
end

-- Bag selection consumes nothing by itself: opening, staging, and every
-- cancel path leave live stock untouched with the field write entries
-- silent. Only the accepted native execution consumes exactly once, a
-- target cancel returns to the retained bag, trainer capture stays
-- refused with its reason, and an unsupported entry never spends.
function T.bag_selection_consumes_only_through_native_execution()
  for _, layout in ipairs({ "paired", "compact" }) do
    local tag = " (" .. layout .. ")"
    -- Supported healing: the staged target cancels back to the retained
    -- bag, and the accepted serving consumes exactly once on commit.
    local healing = openRig({
      layout = layout,
      launchId = "launch-child-heal-" .. layout,
      party = {
        { species = "EEVEE", level = 20, seed = 0x33333333, currentHp = 10 },
        { species = "EEVEE", level = 5, seed = 0x44444444, ability = "RUN_AWAY", currentHp = 10 },
      },
      bag = {
        { key = "POTION", qty = 5 },
        { key = "POKE_BALL", qty = 5 },
        { key = "SOOTHE_BELL", qty = 1 },
      },
    })
    driveToMode(healing, "command")
    local healRequest = openScreenRequest(healing)
    local healRevision = healing.bag:revision()
    local healOptions = optionsFor(healing, healRequest)
    local enabledPotions = {}
    local bellChoices = 0
    for _, actor in ipairs(healOptions.actors) do
      for _, choice in ipairs(actor.choices) do
        if type(choice.id) == "string" and choice.id:match("^item:POTION:") ~= nil then
          if choice.enabled == true then
            enabledPotions[#enabledPotions + 1] = choice.choice
          end
        end
        if type(choice.id) == "string" and choice.id:match("^item:SOOTHE_BELL:") ~= nil then
          bellChoices = bellChoices + 1
        end
        if choice.enabled ~= true then
          Assert.isTrue(
            type(choice.reason) == "string" and choice.reason ~= "",
            "every refused choice names its reason" .. tag
          )
        end
      end
    end
    Assert.isTrue(#enabledPotions >= 1, "the supported healing stays selectable" .. tag)
    Assert.isTrue(bellChoices >= 1, "the bag stock reaches the native options" .. tag)
    requireChildOwner("battle bag selection")
    -- Staging then cancelling the target returns to the retained bag:
    -- two cancels reach command, with no reply and no stock movement.
    openBagFromCommand(healing)
    walkToMedicineFirstCell(healing)
    useNativeBattleBagItem(healing)
    Assert.equal(#healing.submits, 0, "staging the serving seals no reply" .. tag)
    Assert.equal(healing.screen:status().mode, "child", "staging keeps the child open" .. tag)
    press(healing, { type = "cancel" })
    Assert.equal(healing.screen:status().mode, "child", "target cancel returns to the retained bag" .. tag)
    Assert.equal(#healing.submits, 0, "target cancel seals no reply" .. tag)
    press(healing, { type = "cancel" })
    Assert.equal(healing.screen:status().mode, "child", "list cancel returns to the pocket menu" .. tag)
    settlePress(healing)
    press(healing, { type = "cancel" })
    Assert.equal(healing.screen:status().mode, "command", "bag cancel returns to command" .. tag)
    Assert.equal(
      openScreenRequest(healing).requestId,
      healRequest.requestId,
      "bag cancel keeps the same command request" .. tag
    )
    Assert.equal(healing.bag:revision(), healRevision, "bag browsing moves no stock" .. tag)
    Assert.equal(healing.bag:quantity("POTION"), 5, "staging a serving takes no stock" .. tag)
    -- Accepting the serving seals one native fragment; the live stock
    -- stays put mid-battle and publishes exactly once on commit.
    openBagFromCommand(healing)
    walkToMedicineFirstCell(healing)
    useNativeBattleBagItem(healing)
    if #healing.submits == 0 and healing.screen:status().mode == "child" then
      press(healing, { type = "confirm" })
    end
    if #healing.submits == 0 and healing.screen:status().mode ~= "child" then
      openBagFromCommand(healing)
      walkToMedicineFirstCell(healing)
      useNativeBattleBagItem(healing)
      press(healing, { type = "confirm" })
    end
    Assert.equal(#healing.submits, 1, "accepting the serving seals exactly one reply" .. tag)
    assertChoiceAmong(healing.submits[1].choices[1], enabledPotions, "the serving matches its native fragment" .. tag)
    Assert.equal(healing.bag:quantity("POTION"), 5, "native execution takes no field stock mid-battle" .. tag)
    -- Pump through the terminal narration
    -- instead of stopping at the first non-running phase.
    for _ = 1, 60 do
      local current = healing.battle:status()
      if current.phase == "complete" or current.phase == "failed" then
        break
      end
      if current.request ~= nil and requestKind(current.request) == "action" then
        submitFirstEnabledMove(healing, current.request)
      end
      ackNarration(healing)
      healing.pump(20)
    end
    Assert.equal(healing.battle:status().phase, "complete", "the serving battle settles" .. tag)
    Assert.equal(healing.bag:quantity("POTION"), 4, "the accepted serving publishes exactly once" .. tag)
    Assert.equal(healing.bag:quantity("POKE_BALL"), 5, "no ball leaves the bag" .. tag)
    healing.screen:dispose()
    healing.battle:dispose()

    -- Wild capture: the thrown ball is the stocked one and publishes
    -- exactly once, with no second consumption on a repeated reply.
    local capture = openRig({
      layout = layout,
      launchId = "launch-child-catch-" .. layout,
      party = {
        { species = "EEVEE", level = 20, seed = 0x33333333 },
        { species = "EEVEE", level = 5, seed = 0x44444444, ability = "RUN_AWAY" },
      },
      bag = {
        { key = "MASTER_BALL", qty = 1 },
        { key = "SOOTHE_BELL", qty = 1 },
      },
    })
    driveToMode(capture, "command")
    local catchRequest = openScreenRequest(capture)
    local catchOptions = optionsFor(capture, catchRequest)
    local ballFragment = nil
    for _, actor in ipairs(catchOptions.actors) do
      for _, choice in ipairs(actor.choices) do
        -- The native fragment carries the
        -- payload; the option itself carries identity and legality.
        if
          type(choice.choice) == "table"
          and type(choice.choice.payload) == "table"
          and choice.choice.payload.item == "MASTER_BALL"
        then
          if choice.enabled == true then
            ballFragment = choice.choice
          end
        end
      end
    end
    Assert.notNil(ballFragment, "the wild ball stays throwable" .. tag)
    requireChildOwner("wild capture selection")
    openBagFromCommand(capture)
    walkToBallsFirstCell(capture)
    useNativeBattleBagItem(capture)
    Assert.equal(#capture.submits, 1, "throwing the ball seals exactly one reply" .. tag)
    Assert.deepEqual(capture.submits[1].choices[1], ballFragment, "the throw matches its native fragment" .. tag)
    -- Pump through the terminal narration and decline the optional
    -- nickname question so the launch reaches its terminal result.
    for _ = 1, 1200 do
      ackNarration(capture)
      capture.pump(1)
      local completion = capture.screen:status().completion
      if completion ~= nil and completion.kind == "capture_nickname" and completion.stage == "question" then
        capture.screen:input({ { type = "navigate", direction = "down" } })
        capture.screen:input({ { type = "confirm" } })
      end
      if capture.battle:status().phase == "complete" or capture.battle:status().phase == "failed" then
        break
      end
    end
    local settledStatus = capture.battle:status()
    Assert.equal(
      settledStatus.phase,
      "complete",
      "the throw settles the battle"
        .. tag
        .. " ("
        .. tostring(settledStatus.error)
        .. ", request "
        .. tostring(settledStatus.request and requestKind(settledStatus.request))
        .. ", screen "
        .. tostring(capture.screen:status().mode)
        .. ", completion "
        .. tostring(capture.screen:status().completion and capture.screen:status().completion.stage)
        .. ")"
    )
    Assert.equal(capture.battle:status().result, "capture", "the guaranteed ball reports its capture" .. tag)
    Assert.equal(capture.bag:quantity("MASTER_BALL"), 0, "the thrown ball publishes exactly once" .. tag)
    local replayed = capture.battle:submit(capture.submits[1])
    Assert.isFalse(replayed == true, "a repeated capture reply seals nothing more" .. tag)
    capture.screen:dispose()
    capture.battle:dispose()

    -- Trainer battles keep the ball selectable: retail deflects the throw
    -- without consuming stock.
    local trainer = openRig({
      layout = layout,
      launchId = "launch-child-trainerball-" .. layout,
      party = {
        { species = "EEVEE", level = 20, seed = 0x33333333 },
        { species = "EEVEE", level = 5, seed = 0x44444444, ability = "RUN_AWAY" },
      },
      bag = {
        { key = "POKE_BALL", qty = 5 },
        { key = "POTION", qty = 3 },
        { key = "SOOTHE_BELL", qty = 1 },
      },
      foe = { species = "TOTODILE", level = 4, seed = 0x5EED0001 },
      trainer = true,
    })
    driveToMode(trainer, "command")
    local trainerRequest = openScreenRequest(trainer)
    local trainerOptions = optionsFor(trainer, trainerRequest)
    local ballChoices = 0
    for _, actor in ipairs(trainerOptions.actors) do
      for _, choice in ipairs(actor.choices) do
        -- See the wild ball note above: the native fragment carries the
        -- payload while the option itself carries identity and legality.
        if
          type(choice.choice) == "table"
          and type(choice.choice.payload) == "table"
          and choice.choice.payload.item == "POKE_BALL"
        then
          ballChoices = ballChoices + 1
          Assert.isTrue(choice.enabled == true, "the trainer ball stays selectable" .. tag)
        end
      end
    end
    Assert.isTrue(ballChoices >= 1, "the trainer bag still lists its balls" .. tag)
    requireChildOwner("trainer ball deflection")
    openBagFromCommand(trainer)
    walkToBallsFirstCell(trainer)
    useNativeBattleBagItem(trainer)
    Assert.equal(#trainer.submits, 1, "throwing at a trainer seals exactly one reply" .. tag)
    Assert.equal(trainer.bag:quantity("POKE_BALL"), 5, "the deflected ball takes no stock" .. tag)
    trainer.screen:dispose()
    trainer.battle:dispose()
  end
end

-- Real reward learning for held recipients: the prompt carries the held
-- move set and the incoming move with no entry token, replacing asks an
-- explicit confirmation, declining passes its own confirmation, and
-- neither cancel path, resize, nor a second prompt silently decides. One
-- journey covers an active replace and a benched decline in arrival
-- order: the list opens on its first row and a rejected confirmation
-- keeps the list focus.
function T.move_learning_confirms_replace_or_decline_for_held_recipients()
  for _, layout in ipairs({ "paired", "compact" }) do
    local tag = " (" .. layout .. ")"
    -- Medium-fast experience reaches level eight at 512, so both pinned
    -- members level exactly once from one knockout without doubling.
    local fullSet = {
      { move = "TACKLE", pp = 35, ppUps = 0 },
      { move = "TAIL_WHIP", pp = 30, ppUps = 0 },
      { move = "GROWL", pp = 40, ppUps = 0 },
      { move = "LEER", pp = 30, ppUps = 0 },
    }
    local rig = openRig({
      layout = layout,
      launchId = "launch-child-learn-" .. layout,
      party = {
        { species = "EEVEE", level = 7, seed = 0x33333333, moves = fullSet, experience = 511 },
        {
          species = "EEVEE",
          level = 7,
          seed = 0x44444444,
          ability = "RUN_AWAY",
          moves = fullSet,
          experience = 511,
          heldItem = "EXP__SHARE",
        },
      },
      bag = {},
      foe = {
        species = "EEVEE",
        level = 8,
        seed = 0x5EED0002,
        moves = { { move = "GROWL", pp = 40, ppUps = 0 } },
        currentHp = 1,
      },
    })
    -- The opener fights while the share hold feeds the benched reserve,
    -- so the first action actor names the active recipient.
    local leadId = nil
    for _ = 1, 60 do
      local peeked = nil
      for _ = 1, 40 do
        rig.pump(1)
        local status = rig.battle:status()
        if status.phase == "failed" then
          error("the battle failed before learning: " .. tostring(status.error), 0)
        end
        if status.phase == "complete" then
          error("the battle settled before learning", 0)
        end
        if status.request ~= nil then
          peeked = status.request
          break
        end
      end
      if peeked ~= nil then
        if requestKind(peeked) == "action" then
          if leadId == nil then
            leadId = peeked.actors[1].combatant
          end
          submitFirstEnabledMove(rig, peeked)
        else
          break
        end
      end
    end
    Assert.notNil(leadId, "the opener fights the learning battle" .. tag)
    local reserveId = nil
    for _, seed in ipairs(rig.scenario.participants[1].roster) do
      if seed.id ~= leadId then
        reserveId = seed.id
      end
    end
    Assert.notNil(reserveId, "the production roster carries its benched reserve" .. tag)
    waitForBattleDecision(rig, "learn_move")
    local firstPrompt = waitForScreenDecision(rig, "learn_move")
    Assert.equal(rig.screen:status().mode, "child", "the learning prompt opens its child" .. tag)
    Assert.isTrue(type(firstPrompt.incomingMove) == "string", "the prompt names its incoming move" .. tag)
    Assert.isTrue(
      type(firstPrompt.currentMoves) == "table" and #firstPrompt.currentMoves == 4,
      "the prompt carries its held move set" .. tag
    )
    requireChildOwner("held-recipient move learning")
    local seenRecipients = {}
    local learningSubmits = 0
    for round = 1, 2 do
      local prompt = nil
      if round == 1 then
        prompt = firstPrompt
      else
        waitForBattleDecision(rig, "learn_move")
        prompt = waitForScreenDecision(rig, "learn_move")
        Assert.isTrue(prompt.requestId ~= firstPrompt.requestId, "the consecutive prompt is genuinely new" .. tag)
      end
      local recipient = prompt.actors[1].combatant
      Assert.isTrue(recipient == leadId or recipient == reserveId, "the prompt addresses its recipient" .. tag)
      Assert.isNil(prompt.actors[1].activation, "learning answers carry no entry token" .. tag)
      seenRecipients[#seenRecipients + 1] = recipient
      local promptOptions = optionsFor(rig, prompt)
      Assert.equal(promptOptions.actors[1].kind, "learn_move", "learning options mirror the prompt" .. tag)
      if recipient == leadId then
        -- Active replace: selecting a row only stages its confirmation,
        -- resize and rejection return to the list, and confirming emits
        -- the exact roster-bound choice.
        local replaceSlot = 2
        local replaceFragment = nil
        for _, choice in ipairs(promptOptions.actors[1].choices) do
          if choice.id == "learn:replace:" .. tostring(replaceSlot) then
            Assert.isTrue(choice.enabled, "the held slot stays replaceable" .. tag)
            replaceFragment = choice.choice
          end
        end
        Assert.notNil(replaceFragment, "the projected replace fragment exists" .. tag)
        press(rig, { type = "navigate", direction = "down" })
        press(rig, { type = "navigate", direction = "down" })
        press(rig, { type = "confirm" })
        Assert.equal(#rig.submits, learningSubmits, "selecting a row seals no reply" .. tag)
        Assert.equal(rig.screen:status().mode, "child", "selecting a row stays on its confirmation" .. tag)
        rig.measurement = measurementFor(rig.layout == "paired" and "compact" or "paired")
        rig.pump(2)
        Assert.equal(#rig.submits, learningSubmits, "a resize during confirmation seals no reply" .. tag)
        Assert.equal(rig.screen:status().mode, "child", "a resize during confirmation keeps the child" .. tag)
        press(rig, { type = "cancel" })
        Assert.equal(#rig.submits, learningSubmits, "rejecting the confirmation seals no reply" .. tag)
        Assert.equal(rig.screen:status().mode, "child", "rejecting the confirmation returns to the list" .. tag)
        press(rig, { type = "confirm" })
        press(rig, { type = "confirm" })
        Assert.equal(#rig.submits, learningSubmits + 1, "confirming the replace seals one reply" .. tag)
        learningSubmits = learningSubmits + 1
        Assert.deepEqual(
          rig.submits[#rig.submits].choices[1],
          replaceFragment,
          "the replace matches its fragment" .. tag
        )
        Assert.deepEqual(
          rig.submits[#rig.submits].choices[1].actor,
          { combatant = leadId },
          "the replace binds the roster record without a token" .. tag
        )
      else
        -- Benched decline: backing out of the list opens the explicit
        -- stop confirmation instead of declining, and confirming the
        -- decline action emits the decline fragment.
        local declineFragment = nil
        for _, choice in ipairs(promptOptions.actors[1].choices) do
          if choice.id == "learn:decline" then
            Assert.isTrue(choice.enabled, "the prompt stays declinable" .. tag)
            declineFragment = choice.choice
          end
        end
        Assert.notNil(declineFragment, "the projected decline fragment exists" .. tag)
        press(rig, { type = "cancel" })
        Assert.equal(#rig.submits, learningSubmits, "backing out of the list never auto-declines" .. tag)
        Assert.equal(rig.screen:status().mode, "child", "backing out asks its stop confirmation" .. tag)
        press(rig, { type = "cancel" })
        Assert.equal(#rig.submits, learningSubmits, "rejecting the stop confirmation seals no reply" .. tag)
        Assert.equal(rig.screen:status().mode, "child", "rejecting the stop confirmation returns to the list" .. tag)
        press(rig, { type = "navigate", direction = "down" })
        press(rig, { type = "navigate", direction = "down" })
        press(rig, { type = "navigate", direction = "down" })
        press(rig, { type = "navigate", direction = "down" })
        press(rig, { type = "confirm" })
        press(rig, { type = "confirm" })
        Assert.equal(#rig.submits, learningSubmits + 1, "confirming the decline seals one reply" .. tag)
        learningSubmits = learningSubmits + 1
        Assert.deepEqual(
          rig.submits[#rig.submits].choices[1],
          declineFragment,
          "the decline matches its fragment" .. tag
        )
      end
    end
    local sawLead = false
    local sawReserve = false
    for _, recipient in ipairs(seenRecipients) do
      if recipient == leadId then
        sawLead = true
      end
      if recipient == reserveId then
        sawReserve = true
      end
    end
    Assert.isTrue(sawLead and sawReserve, "both the active and the benched recipient decide" .. tag)
    -- Pump through the terminal narration.
    for _ = 1, 400 do
      rig.pump(1)
      if rig.battle:status().phase == "complete" or rig.battle:status().phase == "failed" then
        break
      end
      local current = rig.battle:status()
      if current.request ~= nil and requestKind(current.request) == "action" then
        submitFirstEnabledMove(rig, current.request)
      end
      ackNarration(rig)
    end
    Assert.equal(rig.battle:status().phase, "complete", "the answered prompts settle the battle" .. tag)
    local leadMoves = rig.party:partyMon(0).moves
    Assert.equal(leadMoves[3].move, "SAND_ATTACK", "the replace commits through the kernel" .. tag)
    local reserveMoves = rig.party:partyMon(1).moves
    Assert.equal(#reserveMoves, 4, "the declined set keeps its four moves" .. tag)
    Assert.equal(reserveMoves[3].move, "GROWL", "the declined set keeps its third move" .. tag)
    rig.screen:dispose()
    rig.battle:dispose()
  end
end

-- Children own the input lane exclusively and release exactly once: only
-- the active child answers, a stale request identity never seals, layout
-- changes keep the stored identity, and disposal during pending
-- preparation never resurrects while owned leases release singly and
-- borrowed owners stay usable.
function T.children_keep_exclusive_input_and_release_once()
  for _, layout in ipairs({ "paired", "compact" }) do
    local tag = " (" .. layout .. ")"
    local rig = openRig({
      layout = layout,
      launchId = "launch-child-isolation-" .. layout,
      party = {
        { species = "EEVEE", level = 20, seed = 0x33333333, currentHp = 10 },
        { species = "EEVEE", level = 5, seed = 0x44444444, ability = "RUN_AWAY" },
      },
      bag = {
        { key = "POTION", qty = 5 },
        { key = "POKE_BALL", qty = 5 },
        { key = "SOOTHE_BELL", qty = 1 },
      },
    })
    driveToMode(rig, "command")
    local firstRequest = openScreenRequest(rig)
    requireChildOwner("child input and lifetime isolation")
    -- Only the active child answers: stray navigation seals nothing and
    -- keeps the stored request.
    openBagFromCommand(rig)
    press(rig, { type = "navigate", direction = "up" })
    press(rig, { type = "navigate", direction = "down" })
    press(rig, { type = "navigate", direction = "up" })
    Assert.equal(rig.screen:status().mode, "child", "stray navigation never leaves the active child" .. tag)
    Assert.equal(#rig.submits, 0, "stray navigation seals no reply" .. tag)
    Assert.equal(
      openScreenRequest(rig).requestId,
      firstRequest.requestId,
      "stray navigation keeps the stored request" .. tag
    )
    -- The staged target keeps the bag retained and inert behind it: one
    -- cancel reactivates the bag, the next reaches command.
    walkToMedicineFirstCell(rig)
    useNativeBattleBagItem(rig)
    Assert.equal(#rig.submits, 0, "staging the target seals no reply" .. tag)
    press(rig, { type = "navigate", direction = "down" })
    press(rig, { type = "navigate", direction = "up" })
    Assert.equal(rig.screen:status().mode, "child", "the inert bag answers no input" .. tag)
    Assert.equal(#rig.submits, 0, "the inert bag seals no reply" .. tag)
    press(rig, { type = "cancel" })
    Assert.equal(rig.screen:status().mode, "child", "target cancel reactivates the bag" .. tag)
    press(rig, { type = "cancel" })
    Assert.equal(rig.screen:status().mode, "child", "list cancel returns to the pocket menu" .. tag)
    settlePress(rig)
    press(rig, { type = "cancel" })
    Assert.equal(rig.screen:status().mode, "command", "bag cancel returns to command" .. tag)
    Assert.equal(#rig.submits, 0, "leaving the nested children seals no reply" .. tag)
    -- A new turn retires the old identity: answering it again fails
    -- without touching the battle.
    local staleFragment = firstEnabledMoveFragment(rig, firstRequest)
    -- Open with a status move so the turn
    -- cannot end the battle; the stale fragment above stays the tackle.
    do
      local statusFragment = nil
      for _, actor in ipairs(optionsFor(rig, firstRequest).actors) do
        for _, choice in ipairs(actor.choices) do
          if
            choice.role == "move"
            and choice.enabled == true
            and type(choice.display) == "table"
            and choice.display.category == "status"
          then
            statusFragment = statusFragment or choice.choice
          end
        end
      end
      Assert.notNil(statusFragment, "the opener carries a status move" .. tag)
      local ok, submitErr = rig.battle:submit({
        requestId = firstRequest.requestId,
        epoch = firstRequest.epoch,
        controller = firstRequest.controller,
        choices = { statusFragment },
      })
      Assert.isTrue(ok, "the kernel accepts the status move: " .. tostring(submitErr))
    end
    local attackRequest = nil
    for _ = 1, 800 do
      rig.pump(1)
      local status = rig.battle:status()
      if status.phase ~= "running" then
        break
      end
      if status.request ~= nil and requestKind(status.request) == "action" then
        attackRequest = status.request
        break
      end
    end
    Assert.notNil(attackRequest, "the turn reaches its next decision" .. tag)
    Assert.isTrue(attackRequest.requestId ~= firstRequest.requestId, "the new turn carries a new identity" .. tag)
    local staleReply = {
      requestId = firstRequest.requestId,
      epoch = firstRequest.epoch,
      controller = firstRequest.controller,
      choices = { staleFragment },
    }
    local staleBefore = #rig.submits
    local accepted = rig.battle:submit(staleReply)
    Assert.isFalse(accepted == true, "the stale identity never seals" .. tag)
    Assert.equal(#rig.submits, staleBefore, "the stale identity seals no screen reply" .. tag)
    rig.pump(5)
    Assert.isTrue(rig.screen:status().mode ~= "failed", "the stale identity never fails the screen" .. tag)
    -- A layout change re-resolves without touching the stored identity
    -- or sealing anything.
    waitForScreenDecision(rig, "action")
    openBagFromCommand(rig)
    rig.measurement = measurementFor(rig.layout == "paired" and "compact" or "paired")
    rig.pump(3)
    Assert.equal(rig.screen:status().mode, "child", "the layout change keeps the child" .. tag)
    Assert.equal(
      openScreenRequest(rig).requestId,
      attackRequest.requestId,
      "the layout change keeps the stored identity" .. tag
    )
    Assert.equal(#rig.submits, staleBefore, "the layout change seals no reply" .. tag)
    -- Disposal releases owned preparation leases exactly once while the
    -- borrowed text boundary stays usable.
    rig.screen:dispose()
    rig.screen:dispose()
    rig.pump(2)
    Assert.equal(rig.screen:status().mode, "disposed", "parent disposal settles the lifetime" .. tag)
    for key, count in pairs(rig.assets.released) do
      Assert.equal(count, 1, "the owned lease releases exactly once: " .. tostring(key) .. tag)
    end
    local measured = rig.text.measure("probe")
    Assert.isTrue(measured.width > 0, "the borrowed text boundary stays usable" .. tag)
    rig.battle:dispose()

    -- Disposal during pending preparation never resurrects: a late
    -- readiness still leaves the lifetime disposed with no reply.
    local pending = openRig({
      layout = layout,
      launchId = "launch-child-pending-" .. layout,
      party = {
        { species = "EEVEE", level = 20, seed = 0x33333333 },
        { species = "EEVEE", level = 5, seed = 0x44444444, ability = "RUN_AWAY" },
      },
      bag = {},
      pendingAssets = true,
    })
    pending.pump(5)
    Assert.isTrue(pending.screen:status().mode ~= "failed", "pending preparation never fails the screen" .. tag)
    pending.screen:dispose()
    pending.assetsReady = true
    pending.pump(10)
    Assert.equal(pending.screen:status().mode, "disposed", "late readiness never resurrects the child" .. tag)
    Assert.equal(#pending.submits, 0, "late readiness seals no reply" .. tag)
    pending.battle:dispose()
  end
end

-- The child overlay shares the battle screen's captured control identity:
-- a second pointer cannot complete a party-row press, while a matched tap
-- opens the native menu and Switch submits the projected choice.
function T.child_party_tap_requires_the_matching_pointer()
  for _, layout in ipairs({ "paired", "compact" }) do
    local rig = openRig({
      layout = layout,
      launchId = "launch-child-pointer-identity-" .. layout,
      party = {
        { species = "EEVEE", level = 20, seed = 0x33333333 },
        { species = "EEVEE", level = 5, seed = 0x44444444, ability = "RUN_AWAY" },
      },
      bag = {},
    })
    driveToMode(rig, "command")
    openPartyFromCommand(rig)

    local x = 100
    local y = layout == "paired" and 244 or 52
    rig.screen:input({ { type = "pointer_down", pointerId = "touch:A", x = x, y = y } })
    rig.screen:input({ { type = "pointer_up", pointerId = "touch:B", x = x, y = y } })
    rig.pump(1)
    Assert.equal(
      rig.screen:status().mode,
      "child",
      "a foreign pointer cannot activate the party row (" .. layout .. ")"
    )
    Assert.equal(#rig.submits, 0, "a foreign pointer seals no party choice (" .. layout .. ")")

    rig.screen:input({ { type = "pointer_down", pointerId = "touch:A", x = x, y = y } })
    rig.screen:input({ { type = "pointer_up", pointerId = "touch:A", x = x, y = y } })
    rig.pump(1)
    press(rig, { type = "confirm" })
    press(rig, { type = "confirm" })
    rig.pump(5)
    rig.pump(5)
    Assert.equal(#rig.submits, 1, "a matched pointer submits the party choice once (" .. layout .. ")")
    rig.screen:dispose()
    rig.battle:dispose()
  end
end

-- Renders one frame through the recording text boundary and censuses
-- drawn text by content, so row visibility reads exactly what the
-- battle puts on screen.
---@param rig table live screen rig under test driving
---@return table<string, integer> drawn text census keyed by content
local function renderedContents(rig)
  rig.text.draws = {}
  rig.screen:draw({ graphics = FakeGraphics.new({}) })
  local census = {}
  for _, drawn in ipairs(rig.text.draws) do
    local content = tostring(drawn.content)
    census[content] = (census[content] or 0) + 1
  end
  return census
end

---@param census table<string, integer> rendered text census under inspection
---@return integer distinct drawn contents
local function censusSize(census)
  local total = 0
  for _, _ in pairs(census) do
    total = total + 1
  end
  return total
end

-- The open child paints its own rows instead of the command fallback:
-- strictly more text appears and at least one entry carries the given
-- marker that the command view never prints.
---@param before table<string, integer> command text census under comparison
---@param after table<string, integer> child text census under comparison
---@param marker string required new visible marker under comparison
---@param what string child description under comparison
local function assertPaintsOwnRows(before, after, marker, what)
  -- The compact composition truncates shared wordings to fit ("What
  -- will", "EEVEE do?"), so distinct contingent strings can collide
  -- there; three net-new distinct contents still prove the child paints
  -- its own rows instead of the command fallback.
  Assert.isTrue(
    censusSize(after) >= censusSize(before) + 3,
    "the open " .. what .. " paints its own rows instead of the command fallback"
  )
  local seen = false
  for content, _ in pairs(after) do
    if before[content] == nil and tostring(content):find(marker, 1, true) ~= nil then
      seen = true
    end
  end
  Assert.isTrue(seen, "the open " .. what .. " labels its entries (" .. marker .. ")")
end

-- Taps each native party row, then confirms Switch through its action
-- menu. Ineligible rows refuse and return to the roster before the next
-- candidate is tapped.
---@param rig table live screen rig under test driving
---@param yLo integer first host row under probing
---@param yHi integer last host row under probing
---@param reopen (fun(rig: table))? reopens a voluntary child after a cancel tap
---@return boolean sealed true once a tap sealed exactly one reply
local function tapSealsReply(rig, yLo, yHi, reopen)
  if rig.screen:status().mode ~= "child" then
    if #rig.submits > 0 or reopen == nil then
      return #rig.submits > 0
    end
    reopen(rig)
  end
  local id = "touch:party-reserve"
  local x = 100
  local y = yLo + 44
  if y > yHi then
    return false
  end
  rig.screen:input({ { type = "pointer_down", pointerId = id, x = x, y = y } })
  rig.screen:input({ { type = "pointer_up", pointerId = id, x = x, y = y } })
  rig.pump(1)
  press(rig, { type = "confirm" })
  press(rig, { type = "confirm" })
  rig.pump(5)
  return #rig.submits > 0
end

-- Voluntary selection lists every roster slot with its health and
-- eligibility on both display cases, and a tap on the visible reserve
-- seals the same stable combatant the kernel projected. Forced
-- replacement paints the same roster and only the eligible reserve
-- leaves it, with no executable way out.
function T.voluntary_party_child_lists_focused_roster_and_pointer_seals_reserve()
  for _, layout in ipairs({ "paired", "compact" }) do
    local tag = " (" .. layout .. ")"
    local yLo, yHi = 8, 184
    if layout == "paired" then
      yLo, yHi = 200, 376
    end
    local rig = openRig({
      layout = layout,
      launchId = "launch-visible-party-" .. layout,
      party = {
        { species = "EEVEE", level = 20, seed = 0x33333333 },
        { species = "EEVEE", level = 5, seed = 0x44444444, ability = "RUN_AWAY" },
      },
      bag = {},
    })
    driveToMode(rig, "command")
    local commandRequest = openScreenRequest(rig)
    local _, expectedSwitch = projectedReserveSwitch(rig, commandRequest)
    local commandInk = renderedContents(rig)
    openPartyFromCommand(rig)
    local partyInk = renderedContents(rig)
    assertPaintsOwnRows(commandInk, partyInk, "5", "party roster" .. tag)
    local function reopen()
      openPartyFromCommand(rig)
    end
    Assert.isTrue(tapSealsReply(rig, yLo, yHi, reopen), "a tap on the visible reserve seals its switch" .. tag)
    Assert.equal(#rig.submits, 1, "the pointer seals exactly one reply" .. tag)
    Assert.deepEqual(rig.submits[1].choices[1], expectedSwitch, "the tap names the stable reserve combatant" .. tag)
    rig.screen:dispose()
    rig.battle:dispose()

    local forced = openRig({
      layout = layout,
      launchId = "launch-visible-forced-" .. layout,
      party = {
        { species = "EEVEE", level = 5, seed = 0x55555555 },
        { species = "EEVEE", level = 5, seed = 0x66666666 },
      },
      bag = {},
      foe = { species = "EEVEE", level = 30, seed = 0x5EED0002 },
    })
    driveToMode(forced, "command")
    local forcedCommandInk = renderedContents(forced)
    waitForBattleDecision(forced, "replacement")
    local replacementRequest = waitForScreenDecision(forced, "replacement")
    Assert.equal(forced.screen:status().mode, "child", "the faint opens the replacement child" .. tag)
    local _, expectedReplacement = projectedReserveSwitch(forced, replacementRequest)
    assertPaintsOwnRows(forcedCommandInk, renderedContents(forced), "5", "forced replacement roster" .. tag)
    chooseReserveThroughChild(forced)
    Assert.equal(#forced.submits, 1, "the replacement seals exactly one reply" .. tag)
    Assert.deepEqual(
      forced.submits[1].choices[1],
      expectedReplacement,
      "the replacement names the stable reserve combatant" .. tag
    )
    forced.screen:dispose()
    forced.battle:dispose()
  end
end

---@param layout string "paired" or "compact" surface arrangement under test preparation
---@return table<integer, table<string, unknown>> six-member party descriptions under test preparation
local function sixMemberParty()
  -- One lead, one living reserve, four fainted bench slots: the kernel
  -- projects exactly one reserve switch while all six slots still list.
  return {
    { species = "EEVEE", level = 20, seed = 0x33333331 },
    { species = "EEVEE", level = 19, seed = 0x33333332, ability = "RUN_AWAY" },
    { species = "EEVEE", level = 18, seed = 0x33333333, currentHp = 0 },
    { species = "EEVEE", level = 17, seed = 0x33333334, currentHp = 0 },
    { species = "EEVEE", level = 16, seed = 0x33333335, currentHp = 0 },
    { species = "EEVEE", level = 15, seed = 0x33333336, currentHp = 0 },
  }
end

---@param rig table live screen rig under inspection
---@return string? bag header drawn by the open child under inspection
local function drawnBagHeader(rig)
  local ink = renderedContents(rig)
  for content, _ in pairs(ink) do
    if tostring(content):match("^BAG: ") ~= nil then
      return tostring(content)
    end
  end
  return nil
end

-- The open bag composites its staged retail page behind its rows: the
-- SetPageBgOffset slice for the visible browser page draws once per
-- frame. Rows without their plane would prove the simplified backdrop,
-- never the staged raster.
---@param rig table live screen rig under test driving
---@return string? staged bag page key drawn behind the open browser
local function drawnBagBackdrop(rig)
  local graphics = FakeGraphics.new({})
  rig.screen:draw({ graphics = graphics })
  for _, drawn in ipairs(graphics.draws) do
    local image = drawn.image
    if type(image) == "table" and type(image.handle) == "string" then
      if image.handle:match("^bag:screen:[123]$") ~= nil then
        return image.handle
      end
    end
  end
  return nil
end

-- The open bag draws one shared-atlas icon per stocked visible cell:
-- list cells ride their retail spots, the use-item page its fixed spot.
-- Icons prove the shared item atlas reaches the browser, never a second
-- battle atlas.
---@param rig table live screen rig under test driving
---@return string[] requested shared item icon keys in draw order
local function drawnBagIcons(rig)
  local graphics = FakeGraphics.new({})
  rig.screen:draw({ graphics = graphics })
  local keys = {}
  for _, drawn in ipairs(graphics.draws) do
    local image = drawn.image
    if type(image) == "table" and type(image.handle) == "string" then
      local key = image.handle:match("^battle:item%-icon:(.+)$")
      if key ~= nil then
        keys[#keys + 1] = key
      end
    end
  end
  return keys
end

-- Battle-bag rows print through their retail fonts and window colors:
-- list names ride font 4 MAKE_TEXT_COLOR(3,2,1) with quantities in font
-- 0 MAKE_TEXT_COLOR(1,2,0) out of the staged bag bank behind the visible
-- page, the quantity riding its template slot right of the icon. The
-- compact modal keeps its adapted dialogue treatment, so this pins the
-- retail paired layout only.
function T.bag_rows_print_their_retail_fonts_and_window_colors()
  local tag = " (paired)"
  requireChildOwner("battle bag selection")
  local rig = openRig({
    layout = "paired",
    launchId = "launch-local-bag-ink-paired",
    party = {
      { species = "EEVEE", level = 20, seed = 0x33333333, currentHp = 10 },
      { species = "EEVEE", level = 5, seed = 0x44444444, ability = "RUN_AWAY", currentHp = 10 },
    },
    bag = {
      { key = "POTION", qty = 5 },
      { key = "POKE_BALL", qty = 5 },
    },
  })
  driveToMode(rig, "command")
  openBagFromCommand(rig)
  walkToMedicineFirstCell(rig)
  renderedContents(rig)
  local function findDraw(match)
    for _, drawn in ipairs(rig.text.draws) do
      if match(drawn) then
        return drawn
      end
    end
    return nil
  end
  -- printerPalette(12): colors[i] = { r = i % 256, g = (7i) % 256, b = (13i) % 256 }.
  local function bankSlot(bank, slot)
    local index = bank * 16 + slot + 1
    return { r = index % 256, g = (index * 7) % 256, b = (index * 13) % 256 }
  end
  local name = findDraw(function(drawn)
    return drawn.role == "menu" and tostring(drawn.content):upper():find("PO", 1, true) ~= nil
  end)
  Assert.notNil(name, "the stocked name prints through the name font" .. tag)
  assert(name ~= nil, "the name draw resolved")
  Assert.deepEqual(name.palette.foreground, bankSlot(0, 3), "names ride slot 3" .. tag)
  Assert.deepEqual(name.palette.shadow, bankSlot(0, 2), "names ride slot 2" .. tag)
  Assert.deepEqual(name.palette.background, bankSlot(0, 1), "names ride slot 1" .. tag)
  -- Retail name windows are 112px wide (14 tiles): the staged name
  -- paints whole, centered in its window. The rig measures eight
  -- pixels per glyph; production measures through its staged font.
  Assert.equal(tostring(name.content):upper(), "POTION", "names paint whole in their 112px window" .. tag)
  Assert.equal(
    name.x,
    0 + 64 - math.floor((#name.content * 8) / 2),
    "names center on their template" .. tag
  )
  Assert.equal(name.y, 8 + 7, "names ride their template row" .. tag)
  local quantity = findDraw(function(drawn)
    return drawn.role == "hud" and drawn.content == "x5"
  end)
  Assert.notNil(quantity, "the quantity prints through the quantity font" .. tag)
  assert(quantity ~= nil, "the quantity draw resolved")
  Assert.deepEqual(quantity.palette.foreground, bankSlot(4, 1), "quantities ride slot 1 out of bank 4" .. tag)
  Assert.deepEqual(quantity.palette.shadow, bankSlot(4, 2), "quantities ride slot 2 out of bank 4" .. tag)
  Assert.deepEqual(
    quantity.palette.background,
    { r = 0, g = 0, b = 0, a = 0 },
    "quantities ride transparent slot 0" .. tag
  )
  Assert.equal(quantity.x, 0 + 64, "quantities ride their template slot" .. tag)
  Assert.equal(quantity.y, 8 + 28, "quantities ride their template row" .. tag)
  -- Retail bottom bar (PrintPocketName + PrintPageNumber): the pocket
  -- title rides window 24 in the quantity ink, the page counter rides
  -- window 25 beside it.
  local title = findDraw(function(drawn)
    return drawn.role == "hud" and drawn.y == 152 + 4
  end)
  Assert.notNil(title, "the pocket title prints through the quantity ink" .. tag)
  assert(title ~= nil, "the title draw resolved")
  Assert.deepEqual(title.palette.foreground, bankSlot(4, 1), "titles ride slot 1 out of bank 4" .. tag)
  Assert.equal(title.x, 88 + math.floor((80 - #title.content * 8) / 2), "titles center in their window" .. tag)
  -- Retail page counter (PrintPageNumber window 25 at (176,160) 32
  -- wide): the slash centers at y+4 with current right-aligned
  -- before it and last left-aligned after it.
  local slash = findDraw(function(drawn)
    return drawn.role == "hud" and drawn.y == 160 + 4 and tostring(drawn.content) == "/"
  end)
  Assert.notNil(slash, "the page slash centers in its window" .. tag)
  assert(slash ~= nil, "the slash draw resolved")
  local slashWidth = #slash.content * 8
  Assert.equal(slash.x, 176 + math.floor((32 - slashWidth) / 2), "slashes center in their window" .. tag)
  Assert.deepEqual(slash.palette.foreground, bankSlot(4, 1), "slashes ride slot 1 out of bank 4" .. tag)
  local current = findDraw(function(drawn)
    return drawn.role == "hud" and drawn.y == 160 + 4 and drawn.x == slash.x - 8
  end)
  Assert.notNil(current, "the current page rides before the slash" .. tag)
  local last = findDraw(function(drawn)
    return drawn.role == "hud" and drawn.y == 160 + 4 and drawn.x == slash.x + slashWidth
  end)
  Assert.notNil(last, "the last page rides after the slash" .. tag)
  rig.screen:dispose()
  rig.battle:dispose()
end

-- Drives the paired party list to the reserve mon's summary page: taps
-- the reserve row in the lower interaction pane, steps the mon menu to
-- SUMMARY, confirms through the native press gate, and settles on the
-- wrapper page.
---@param rig table live screen rig under test driving
local function openReserveSummary(rig)
  openPartyFromCommand(rig)
  -- Canonical modal rows paint at y = 32 + (index - 1) * 20 inside the
  -- lower 256x192 pane; the reserve is the second row.
  rig.screen:input({ { type = "pointer_down", pointerId = "touch:summary", x = 128, y = 254 } })
  rig.screen:input({ { type = "pointer_up", pointerId = "touch:summary", x = 128, y = 254 } })
  rig.pump(1)
  press(rig, { type = "navigate", direction = "down" })
  press(rig, { type = "confirm" })
  rig.pump(8)
  Assert.equal(
    rig.screen:status().mode,
    "child",
    "SUMMARY keeps the party child (" .. rig.layout .. ")"
  )
end

-- The summary page shows its staged words and live facts on the paired
-- layout: the mon name, level, remaining experience, HP, battle stats,
-- ability, and held item resolve through their msg 0006 keys with the
-- live roster's numbers.
function T.party_summary_shows_its_staged_words_and_facts()
  local tag = " (paired)"
  requireChildOwner("battle party summary")
  local rig = openRig({
    layout = "paired",
    launchId = "launch-local-summary-paired",
    party = {
      { species = "EEVEE", level = 20, seed = 0x33333333 },
      { species = "EEVEE", level = 5, seed = 0x44444444, ability = "RUN_AWAY", heldItem = "POTION" },
    },
    bag = {},
  })
  driveToMode(rig, "command")
  openReserveSummary(rig)
  local ink = renderedContents(rig)
  -- Wrapper labels paint with their focus marker; strip it so the
  -- assertions pin the staged wording underneath.
  local words = {}
  for content, _ in pairs(ink) do
    local text = tostring(content):gsub("^[> ] ", "")
    words[text] = true
  end
  local catalog = CatalogFixture.makeCatalog()
  local live = rig.party:partyMon(1)
  local Mon = require("libs.mons.src.Mon")
  local displayName = Mon.displayName(live, catalog)
  Assert.isTrue(
    words[displayName] == true or words[displayName .. " ♂"] == true or words[displayName .. " ♀"] == true,
    "the summary names its mon" .. tag
  )
  local MonStats = require("libs.mons.src.gen4.MonStats")
  local derived = MonStats.derive(live, catalog)
  local Experience = require("libs.mons.src.gen4.Experience")
  local species = catalog:species("EEVEE")
  local curve = assert(catalog:growthCurve(species.growthCurve), "the catalog carries its growth curve")
  local level = Experience.level(curve, live.experience)
  -- The paired modal paints the first six rows; the remaining stat
  -- block rows prove through the projection suites and the move pages
  -- below.
  local expected = {
    ["Lv."] = true,
    ["NEXT LV"] = true,
    ["HP"] = true,
    ["ATTACK"] = true,
    ["DEFENSE"] = true,
    [tostring(level)] = true,
    [tostring(Experience.expFor(curve, level + 1) - live.experience)] = true,
    [tostring(live.condition.currentHp) .. "/" .. tostring(derived.maxHp)] = true,
    [tostring(derived.attack)] = true,
    [tostring(derived.defense)] = true,
  }
  for wording, _ in pairs(expected) do
    Assert.notNil(words[wording], "the summary paints " .. tostring(wording) .. tag)
  end
  -- Representative ink: stat labels ride the label slots while values
  -- ride the value slots out of the staged party bank.
  local inks = {}
  for _, drawn in ipairs(rig.text.draws) do
    inks[tostring(drawn.content):gsub("^[> ] ", "")] = drawn
  end
  local attackLabel = inks["ATTACK"]
  Assert.notNil(attackLabel, "the attack label prints" .. tag)
  if attackLabel ~= nil then
    Assert.equal(attackLabel.role, "hud", "the attack label rides its retail font" .. tag)
  end
  local attackValue = inks[tostring(derived.attack)]
  Assert.notNil(attackValue, "the attack value prints" .. tag)
  rig.screen:dispose()
  rig.battle:dispose()
end

-- Pocket-menu names and the USE row center vertically in their retail
-- hit regions on the paired layout: the retail printers paint at
-- window-relative rows (battle_bag_menu.c PrintCenteredText y=7/23/5),
-- not at the region top, so the rows ride the region center instead of
-- the established top offset. Every other row keeps its origin.
function T.bag_pocket_menu_and_use_rows_center_in_their_regions()
  local tag = " (paired)"
  requireChildOwner("battle bag row centering")
  local rig = openRig({
    layout = "paired",
    launchId = "launch-local-bag-center-paired",
    party = {
      { species = "EEVEE", level = 20, seed = 0x33333333, currentHp = 10 },
      { species = "EEVEE", level = 5, seed = 0x44444444, ability = "RUN_AWAY", currentHp = 10 },
    },
    bag = {
      { key = "POTION", qty = 5 },
      { key = "POKE_BALL", qty = 5 },
    },
  })
  driveToMode(rig, "command")
  openBagFromCommand(rig)
  renderedContents(rig)
  local function findDraw(match)
    for _, drawn in ipairs(rig.text.draws) do
      if match(drawn) then
        return drawn
      end
    end
    return nil
  end
  -- Retail pocket windows are 96px wide: names paint whole,
  -- centered in their window. The match pins the staged wording;
  -- the origins and ink carry the contract.
  local pocket = findDraw(function(drawn)
    return drawn.role == "menu" and tostring(drawn.content):find("HP", 1, true) ~= nil
  end)
  Assert.notNil(pocket, "the pocket name prints" .. tag)
  assert(pocket ~= nil, "the pocket draw resolved")
  -- Retail centers the pocket title in its window (PrintCenteredText
  -- y=7 over window 0 at (16,32) 96 wide): HP/PP titles ride y=39.
  -- No text marker frames the focus: the staged cursor corners do.
  Assert.equal(pocket.y, 32 + 7, "pocket names ride their window row" .. tag)
  Assert.equal(
    pocket.x,
    16 + math.floor((96 - #pocket.content * 8) / 2),
    "pocket names center in their window" .. tag
  )
  Assert.isTrue(tostring(pocket.content):sub(1, 1) ~= ">", "pocket names paint no marker" .. tag)
  local function bankSlot(bank, slot)
    local index = bank * 16 + slot + 1
    return { r = index % 256, g = (index * 7) % 256, b = (index * 13) % 256 }
  end
  Assert.deepEqual(pocket.palette.foreground, bankSlot(0, 3), "pocket names ride slot 3 out of bank 0" .. tag)
  walkToMedicineFirstCell(rig)
  press(rig, { type = "confirm" })
  rig.pump(8)
  Assert.equal(
    drawnBagBackdrop(rig),
    "bag:screen:3",
    "the use-item page composites its staged slice" .. tag
  )
  renderedContents(rig)
  local use = findDraw(function(drawn)
    return drawn.role == "menu" and drawn.y == 160 + 5
  end)
  if use == nil then
    local dump = {}
    for _, drawn in ipairs(rig.text.draws) do
      dump[#dump + 1] = tostring(drawn.role) .. "@" .. tostring(drawn.x) .. "," .. tostring(drawn.y) .. ":" .. tostring(drawn.content)
    end
    Assert.notNil(use, "the USE row prints (draws: " .. table.concat(dump, " | ") .. ")" .. tag)
  end
  assert(use ~= nil, "the USE draw resolved")
  -- Retail centers USE in window 3 (PrintCenteredText y=5 over
  -- window 3 at (64,160) 80 wide): y=165.
  Assert.equal(use.y, 160 + 5, "the USE row rides its window row" .. tag)
  Assert.equal(
    use.x,
    64 + math.floor((80 - #use.content * 8) / 2),
    "the USE row centers in its window" .. tag
  )
  rig.screen:dispose()
  rig.battle:dispose()
end

-- Retail use-item windows (battle_bag_menu.c PrintUseItemPage): the
-- item name rides window 0 (56,32) left-aligned, the quantity rides
-- window 1 (160,32), the description rides window 2 (20,72 with x+4),
-- and USE centers in window 3 (64,160 80 wide) at y=165. The pocket
-- shortcut prints left-aligned at (40,165) in window 4 (40,160 160
-- wide), never centered. The message page prints at (16,152) in the
-- palette-15 message window (16,152 216 wide), never at the modal
-- notice origin. The bag carries no modal title, occupancy, Stock, or
-- footer notice: the page art and its windows own the titles.
function T.bag_use_page_paints_through_its_retail_windows()
  local tag = " (paired)"
  requireChildOwner("battle bag retail windows")
  local rig = openRig({
    layout = "paired",
    launchId = "launch-local-bag-windows-paired",
    party = {
      { species = "EEVEE", level = 20, seed = 0x33333333, currentHp = 10 },
      { species = "EEVEE", level = 5, seed = 0x44444444, ability = "RUN_AWAY", currentHp = 10 },
    },
    bag = {
      { key = "POTION", qty = 5 },
      { key = "POKE_BALL", qty = 5 },
    },
  })
  driveToMode(rig, "command")
  openBagFromCommand(rig)
  walkToMedicineFirstCell(rig)
  press(rig, { type = "confirm" })
  rig.pump(8)
  local opened = rig.screen:view().childView
  Assert.notNil(opened, "confirming a stocked cell keeps the child" .. tag)
  assert(opened ~= nil, "the use page resolved")
  Assert.equal(opened.bagPage, "use_item", "confirming a stocked cell opens the use page" .. tag)
  renderedContents(rig)
  local function findDraw(match)
    for _, drawn in ipairs(rig.text.draws) do
      if match(drawn) then
        return drawn
      end
    end
    return nil
  end
  local infoName = findDraw(function(drawn)
    return drawn.role == "hud" and drawn.x == 56 and drawn.y == 32
  end)
  Assert.notNil(infoName, "the use-item name rides window 0 at (56,32)" .. tag)
  local infoQty = findDraw(function(drawn)
    return drawn.role == "hud" and drawn.x == 160 and drawn.y == 32
  end)
  Assert.notNil(infoQty, "the use-item quantity rides window 1 at (160,32)" .. tag)
  local infoDesc = findDraw(function(drawn)
    return drawn.role == "hud" and drawn.x == 20 and drawn.y == 72
  end)
  Assert.notNil(infoDesc, "the use-item description rides window 2 at (20,72)" .. tag)
  local function bankSlot(bank, slot)
    local index = bank * 16 + slot + 1
    return { r = index % 256, g = (index * 7) % 256, b = (index * 13) % 256 }
  end
  assert(infoName ~= nil, "the info name resolved")
  Assert.deepEqual(infoName.palette.foreground, bankSlot(4, 1), "use names ride slot 1 out of bank 4" .. tag)
  assert(infoDesc ~= nil, "the info description resolved")
  Assert.deepEqual(infoDesc.palette.foreground, bankSlot(4, 1), "descriptions ride slot 1 out of bank 4" .. tag)
  local use = findDraw(function(drawn)
    return drawn.role == "menu" and drawn.y == 160 + 5
  end)
  Assert.notNil(use, "USE rides window 3 at y=165" .. tag)
  assert(use ~= nil, "the USE draw resolved")
  Assert.equal(use.x, 64 + math.floor((80 - #use.content * 8) / 2), "USE centers in its 80px window" .. tag)
  Assert.deepEqual(use.palette.foreground, bankSlot(0, 3), "USE rides slot 3 out of bank 0" .. tag)
  Assert.deepEqual(use.palette.shadow, bankSlot(0, 2), "USE rides slot 2 out of bank 0" .. tag)
  Assert.deepEqual(use.palette.background, bankSlot(0, 1), "USE rides slot 1 out of bank 0" .. tag)
  local ink = renderedContents(rig)
  for content, _ in pairs(ink) do
    local text = tostring(content)
    Assert.isFalse(text:match("^BAG: ") ~= nil, "the bag paints no modal title" .. tag)
    Assert.isFalse(text:match("^Stock:") ~= nil, "the bag paints no Stock caption" .. tag)
  end
  rig.screen:dispose()
  rig.battle:dispose()
end

-- Retail d-pad cursor (BattleDpadCursor_SetRect): four staged corners
-- frame the focused box while the cursor is active. Fresh browsers
-- hide it; the first key shows it; touch clears it again.
function T.bag_cursor_corners_frame_the_focused_box()
  local tag = " (paired)"
  requireChildOwner("battle bag cursor")
  local rig = openRig({
    layout = "paired",
    launchId = "launch-local-cursor-paired",
    party = {
      { species = "EEVEE", level = 20, seed = 0x33333333, currentHp = 10 },
      { species = "EEVEE", level = 5, seed = 0x44444444, ability = "RUN_AWAY", currentHp = 10 },
    },
    bag = {
      { key = "POTION", qty = 5 },
      { key = "POKE_BALL", qty = 5 },
    },
  })
  local function cursorDraws()
    local graphics = FakeGraphics.new({})
    rig.screen:draw({ graphics = graphics })
    local found = {}
    for _, drawn in ipairs(graphics.draws) do
      local image = drawn.image
      if type(image) == "table" and type(image.handle) == "string" and image.handle:match("^battle:cursor%-") ~= nil then
        found[#found + 1] = { handle = image.handle, x = drawn.x, y = drawn.y }
      end
    end
    return found
  end
  driveToMode(rig, "command")
  openBagFromCommand(rig)
  Assert.equal(#cursorDraws(), 0, "fresh browsers hide the cursor" .. tag)
  press(rig, { type = "navigate", direction = "right" })
  local corners = cursorDraws()
  Assert.equal(#corners, 4, "the first key frames the focused box" .. tag)
  -- Right from pocket 0 focuses the balls box (136,16,112,56); the
  -- rig fakes 80x80 corners, so each centers 40 above-left of its spot.
  Assert.deepEqual(corners[1], { handle = "battle:cursor-tl", x = 136 - 40, y = 16 - 40 })
  Assert.deepEqual(corners[2], { handle = "battle:cursor-tr", x = 248 - 40, y = 16 - 40 })
  Assert.deepEqual(corners[3], { handle = "battle:cursor-bl", x = 136 - 40, y = 72 - 40 })
  Assert.deepEqual(corners[4], { handle = "battle:cursor-br", x = 248 - 40, y = 72 - 40 })
  rig.screen:dispose()
  rig.battle:dispose()
end

-- Retail disabled faces (DrawPageButtons frame 3): the pocket shortcut
-- with no last-used item, empty item cells, and steppers on a single
-- page repaint through the disabled bank.
function T.bag_disabled_faces_repaint_empty_controls()
  local tag = " (paired)"
  requireChildOwner("battle bag disabled faces")
  local rig = openRig({
    layout = "paired",
    launchId = "launch-local-disabled-paired",
    party = {
      { species = "EEVEE", level = 20, seed = 0x33333333, currentHp = 10 },
      { species = "EEVEE", level = 5, seed = 0x44444444, ability = "RUN_AWAY", currentHp = 10 },
    },
    bag = {
      { key = "POTION", qty = 5 },
    },
  })
  local function faceDraws()
    local graphics = FakeGraphics.new({})
    rig.screen:draw({ graphics = graphics })
    local found = {}
    for _, drawn in ipairs(graphics.draws) do
      local image = drawn.image
      if type(image) == "table" and type(image.handle) == "string" and image.handle:match("^bag:button:") ~= nil then
        found[#found + 1] = { handle = image.handle, x = drawn.x, y = drawn.y }
      end
    end
    return found
  end
  local function hasFace(faces, handle, x, y)
    for _, face in ipairs(faces) do
      if face.handle == handle and face.x == x and face.y == y then
        return true
      end
    end
    return false
  end
  driveToMode(rig, "command")
  openBagFromCommand(rig)
  local pocketFaces = faceDraws()
  Assert.isTrue(
    hasFace(pocketFaces, "bag:button:4:3:5", 0, 152),
    "the shortcut paints disabled with no last-used item" .. tag
  )
  walkToMedicineFirstCell(rig)
  local listFaces = faceDraws()
  Assert.isTrue(
    hasFace(listFaces, "bag:button:7:3:5", 128, 8),
    "empty cells repaint through the disabled bank" .. tag
  )
  Assert.isTrue(
    hasFace(listFaces, "bag:button:12:3:5", 0, 152),
    "single-page steppers repaint disabled" .. tag
  )
  Assert.isTrue(
    hasFace(listFaces, "bag:button:13:3:5", 40, 152),
    "both steppers repaint disabled" .. tag
  )
  Assert.isFalse(
    hasFace(listFaces, "bag:button:6:3:8", 0, 8),
    "the stocked cell keeps its enabled face" .. tag
  )
  rig.screen:dispose()
  rig.battle:dispose()
end

-- Retail empty pockets still composite their item-list page: six
-- cleared cells with disabled faces, the pocket title, and the 1/1
-- counter — never a pitch-black modal. A pocket holding nothing
-- stages no selection, but Back still cancels to the pocket menu.
function T.bag_empty_pocket_renders_its_list_page()
  local tag = " (paired)"
  requireChildOwner("battle bag empty pocket")
  local rig = openRig({
    layout = "paired",
    launchId = "launch-local-empty-pocket-paired",
    party = {
      { species = "EEVEE", level = 20, seed = 0x33333333, currentHp = 10 },
      { species = "EEVEE", level = 5, seed = 0x44444444, ability = "RUN_AWAY", currentHp = 10 },
    },
    bag = {
      { key = "POTION", qty = 5 },
    },
  })
  driveToMode(rig, "command")
  openBagFromCommand(rig)
  walkToBallsFirstCell(rig)
  local childView = rig.screen:view().childView
  Assert.notNil(childView, "the empty pocket keeps the child" .. tag)
  assert(childView ~= nil, "the empty view resolved")
  Assert.equal(childView.bagPage, "item_list", "the empty pocket lists its page" .. tag)
  Assert.isNil(childView.empty, "the empty pocket is not a black modal" .. tag)
  Assert.equal(drawnBagBackdrop(rig), "bag:screen:2", "the empty list composites its staged page" .. tag)
  renderedContents(rig)
  local title = nil
  for _, drawn in ipairs(rig.text.draws) do
    -- Single-line pockets (BALLS) ride y=152+12; two-line pockets
    -- ride y=152+4/152+20. Either proves the bottom bar survived.
    if drawn.role == "hud" and (drawn.y == 152 + 12 or drawn.y == 152 + 4 or drawn.y == 152 + 20) then
      title = drawn
      break
    end
  end
  Assert.notNil(title, "the empty list still prints its pocket title" .. tag)
  local graphics = FakeGraphics.new({})
  rig.screen:draw({ graphics = graphics })
  local disabled = 0
  for _, drawn in ipairs(graphics.draws) do
    local image = drawn.image
    if type(image) == "table" and type(image.handle) == "string" and image.handle:match("^bag:button:%d+:3:5$") ~= nil then
      disabled = disabled + 1
    end
  end
  Assert.isTrue(disabled >= 6, "empty cells repaint disabled, never black" .. tag)
  press(rig, { type = "cancel" })
  settlePress(rig)
  Assert.equal(rig.screen:status().mode, "child", "list cancel returns to the pocket menu" .. tag)
  Assert.equal(rig.screen:view().childView.bagPage, "pocket_menu", "Back leaves the empty list" .. tag)
  rig.screen:dispose()
  rig.battle:dispose()
end

-- Consuming a battle item arms the last-used shortcut: using a potion
-- through the native serving, target, and execution flow records it,
-- and reopening the bag offers it back with its icon on the paired
-- layout. The shortcut stays disabled until a real battle consume.
function T.battle_last_used_shortcut_reopens_the_consumed_item()
  local tag = " (paired)"
  requireChildOwner("battle last-used shortcut")
  local BagCursor = require("libs.hgss.src.items.BagCursor")
  local rig = openRig({
    layout = "paired",
    launchId = "launch-local-last-used-paired",
    bagCursor = BagCursor.new(),
    party = {
      { species = "EEVEE", level = 20, seed = 0x33333333, currentHp = 10 },
      { species = "EEVEE", level = 5, seed = 0x44444444, ability = "RUN_AWAY" },
    },
    bag = {
      { key = "POTION", qty = 5 },
      { key = "POKE_BALL", qty = 5 },
    },
  })
  driveToMode(rig, "command")
  openBagFromCommand(rig)
  walkToMedicineFirstCell(rig)
  useNativeBattleBagItem(rig)
  if #rig.submits == 0 and rig.screen:status().mode == "child" then
    press(rig, { type = "confirm" })
  end
  Assert.equal(#rig.submits, 1, "accepting the serving seals exactly one reply" .. tag)
  driveToMode(rig, "command")
  openBagFromCommand(rig)
  Assert.deepEqual(
    drawnBagIcons(rig),
    { "POTION" },
    "the reopened bag shortcuts the consumed item" .. tag
  )
  renderedContents(rig)
  local shortcut = nil
  for _, drawn in ipairs(rig.text.draws) do
    -- Retail last-used shortcut (PrintPocketMenuPage window 4 at
    -- (40,160) 160 wide): left-aligned at x=40 y=165, never
    -- centered. (The rig truncates the label to its 30-pixel fit,
    -- so the match pins the row position rather than full wording.)
    if drawn.role == "menu" and drawn.y == 160 + 5 and drawn.x == 40 then
      shortcut = drawn
    end
  end
  Assert.notNil(shortcut, "the last-used row left-aligns in its window" .. tag)
  rig.screen:dispose()
  rig.battle:dispose()
end

-- Six-slot voluntary party plus multi-pocket bag stay identical across
-- keyboard and pointer on both display cases: stable row identities,
-- cancel and reopen over the same request, one sealed native fragment
-- per flow, and rows already interactive the moment the child opens.
function T.six_slot_party_and_bag_answer_at_once_on_both_displays()
  for _, layout in ipairs({ "paired", "compact" }) do
    local tag = " (" .. layout .. ")"
    requireChildOwner("battle party and bag selection")
    local rig = openRig({
      layout = layout,
      launchId = "launch-local-party-" .. layout,
      party = sixMemberParty(),
      bag = {
        { key = "POTION", qty = 5 },
        { key = "POKE_BALL", qty = 5 },
        { key = "SOOTHE_BELL", qty = 1 },
        { key = "CHERI_BERRY", qty = 2 },
      },
    })
    driveToMode(rig, "command")
    local commandRequest = openScreenRequest(rig)
    local _, expectedSwitch = projectedReserveSwitch(rig, commandRequest)
    local commandInk = renderedContents(rig)
    openPartyFromCommand(rig)
    -- No pump ran since the child opened: its own rows already paint.
    local partyInk = renderedContents(rig)
    -- The compact modal drops row sub-facts, so the level marker only
    -- paints on paired; compact proves the same entries through the
    -- painted roster occupancy instead. Both markers read already-painted
    -- vocabulary, never new paint expectations.
    local partyMarker = "19"
    if layout == "compact" then
      partyMarker = "6/6"
    end
    assertPaintsOwnRows(commandInk, partyInk, partyMarker, "party roster" .. tag)
    press(rig, { type = "cancel" })
    Assert.equal(rig.screen:status().mode, "command", "party cancel returns to command" .. tag)
    Assert.equal(openScreenRequest(rig).requestId, commandRequest.requestId, "cancel keeps the command request" .. tag)
    openPartyFromCommand(rig)
    Assert.deepEqual(renderedContents(rig), partyInk, "reopen paints the same roster" .. tag)
    chooseReserveThroughChild(rig)
    Assert.equal(#rig.submits, 1, "keys seal exactly one reply" .. tag)
    Assert.deepEqual(rig.submits[1].choices[1], expectedSwitch, "keys name the stable reserve" .. tag)
    rig.screen:dispose()
    rig.battle:dispose()
    -- Pointer seals the same projected reserve on a fresh rig.
    local yLo, yHi = 8, 184
    if layout == "paired" then
      yLo, yHi = 200, 376
    end
    local tapped = openRig({
      layout = layout,
      launchId = "launch-local-tap-" .. layout,
      party = sixMemberParty(),
      bag = {},
    })
    driveToMode(tapped, "command")
    local tapRequest = openScreenRequest(tapped)
    local _, tapExpected = projectedReserveSwitch(tapped, tapRequest)
    openPartyFromCommand(tapped)
    local function reopen()
      openPartyFromCommand(tapped)
    end
    Assert.isTrue(tapSealsReply(tapped, yLo, yHi, reopen), "a tap seals the reserve" .. tag)
    Assert.equal(#tapped.submits, 1, "the tap seals exactly one reply" .. tag)
    Assert.deepEqual(tapped.submits[1].choices[1], tapExpected, "the tap names the stable reserve" .. tag)
    tapped.screen:dispose()
    tapped.battle:dispose()
    -- Bag browses by keys across pockets and spends nothing to stage.
    local bagged = openRig({
      layout = layout,
      launchId = "launch-local-bag-" .. layout,
      party = {
        { species = "EEVEE", level = 20, seed = 0x33333333, currentHp = 10 },
        { species = "EEVEE", level = 5, seed = 0x44444444, ability = "RUN_AWAY", currentHp = 10 },
      },
      bag = {
        { key = "POTION", qty = 5 },
        { key = "POKE_BALL", qty = 5 },
        { key = "SOOTHE_BELL", qty = 1 },
      },
    })
    driveToMode(bagged, "command")
    local bagRequest = openScreenRequest(bagged)
    local bagOptions = optionsFor(bagged, bagRequest)
    local enabledPotions = {}
    for _, actor in ipairs(bagOptions.actors) do
      for _, choice in ipairs(actor.choices) do
        if type(choice.id) == "string" and choice.id:match("^item:POTION:") ~= nil then
          if choice.enabled == true then
            enabledPotions[#enabledPotions + 1] = choice.choice
          end
        end
      end
    end
    Assert.isTrue(#enabledPotions >= 1, "the serving stays selectable" .. tag)
    local revision = bagged.bag:revision()
    openBagFromCommand(bagged)
    local openingHeader = drawnBagHeader(bagged)
    if layout == "paired" then
      -- Retail pocket menu carries no modal title: the page art and
      -- its windows own the pocket names.
      Assert.isNil(openingHeader, "the paired bag paints no modal title" .. tag)
    else
      Assert.isTrue(
        type(openingHeader) == "string" and openingHeader:match("^BAG: %S+ 1/1$") ~= nil,
        "the bag names its pocket and page" .. tag
      )
    end
    Assert.equal(
      drawnBagBackdrop(bagged),
      "bag:screen:1",
      "the open pocket menu composites its staged page" .. tag
    )
    walkToMedicineFirstCell(bagged)
    if layout == "paired" then
      Assert.isNil(drawnBagHeader(bagged), "the paired list paints no modal title" .. tag)
    else
      Assert.equal(drawnBagHeader(bagged), "BAG: hp_pp 1/1", "keys reach the serving pocket" .. tag)
    end
    Assert.equal(
      drawnBagBackdrop(bagged),
      "bag:screen:2",
      "the open item list composites its staged page" .. tag
    )
    Assert.deepEqual(
      drawnBagIcons(bagged),
      { "POTION" },
      "stocked list cells draw their shared atlas icons" .. tag
    )
    press(bagged, { type = "confirm" })
    settlePress(bagged)
    bagged.pump(1)
    Assert.equal(
      drawnBagBackdrop(bagged),
      "bag:screen:3",
      "the use-item page composites its staged page" .. tag
    )
    Assert.deepEqual(
      drawnBagIcons(bagged),
      { "POTION" },
      "the use-item page keeps the chosen icon" .. tag
    )
    press(bagged, { type = "confirm" })
    bagged.pump(8)
    Assert.equal(#bagged.submits, 0, "staging seals no reply" .. tag)
    Assert.equal(bagged.screen:status().mode, "child", "staging keeps the child" .. tag)
    press(bagged, { type = "cancel" })
    Assert.equal(bagged.screen:status().mode, "child", "target cancel returns to the bag" .. tag)
    press(bagged, { type = "cancel" })
    Assert.equal(bagged.screen:status().mode, "child", "list cancel returns to the pocket menu" .. tag)
    settlePress(bagged)
    press(bagged, { type = "cancel" })
    Assert.equal(bagged.screen:status().mode, "command", "bag cancel returns to command" .. tag)
    Assert.equal(bagged.bag:revision(), revision, "browsing moves no stock" .. tag)
    Assert.equal(bagged.bag:quantity("POTION"), 5, "staging takes no stock" .. tag)
    openBagFromCommand(bagged)
    walkToMedicineFirstCell(bagged)
    useNativeBattleBagItem(bagged)
    if #bagged.submits == 0 and bagged.screen:status().mode == "child" then
      press(bagged, { type = "confirm" })
    end
    Assert.equal(#bagged.submits, 1, "accepting seals exactly one reply" .. tag)
    assertChoiceAmong(bagged.submits[1].choices[1], enabledPotions, "the serving matches its fragment" .. tag)
    Assert.equal(bagged.bag:quantity("POTION"), 5, "the battle path spends no field stock" .. tag)
    bagged.screen:dispose()
    bagged.battle:dispose()
  end
end

-- A crowded pocket pages by keys, a cancelled serving restores the exact
-- resting browse, and refused or empty browsing closes without spending.
function T.crowded_browse_pages_and_restores_after_target_cancel()
  for _, layout in ipairs({ "paired", "compact" }) do
    local tag = " (" .. layout .. ")"
    requireChildOwner("battle bag paging and restore")
    local scroller = openRig({
      layout = layout,
      launchId = "launch-local-pages-" .. layout,
      party = {
        { species = "EEVEE", level = 20, seed = 0x33333333, currentHp = 10 },
        { species = "EEVEE", level = 5, seed = 0x44444444, ability = "RUN_AWAY", currentHp = 10 },
      },
      bag = {
        { key = "POTION", qty = 5 },
        { key = "ITEM_1", qty = 1 },
        { key = "ITEM_13", qty = 1 },
        { key = "ITEM_19", qty = 1 },
        { key = "ITEM_25", qty = 1 },
        { key = "ITEM_31", qty = 1 },
        { key = "ITEM_37", qty = 1 },
        { key = "ITEM_43", qty = 1 },
      },
    })
    driveToMode(scroller, "command")
    openBagFromCommand(scroller)
    -- The HP/PP pocket holds the crowded stock; confirm it from the menu.
    press(scroller, { type = "confirm" })
    settlePress(scroller)
    if layout == "paired" then
      local crowdedView = scroller.screen:view().childView
      Assert.notNil(crowdedView, "the crowded pocket opens" .. tag)
      assert(crowdedView ~= nil, "the crowded view resolved")
      Assert.equal(crowdedView.page.current, 1, "the crowded pocket opens on page 1" .. tag)
      Assert.equal(crowdedView.page.count, 2, "the crowded pocket spans two pages" .. tag)
    else
      local crowdedHeader = drawnBagHeader(scroller)
      Assert.isTrue(
        type(crowdedHeader) == "string" and crowdedHeader:match("hp_pp 1/2$") ~= nil,
        "the crowded pocket spans two pages" .. tag
      )
    end
    press(scroller, { type = "navigate", direction = "right" })
    press(scroller, { type = "navigate", direction = "right" })
    settlePress(scroller)
    if layout == "paired" then
      local scrolledView = scroller.screen:view().childView
      Assert.notNil(scrolledView, "the turned pocket stays open" .. tag)
      assert(scrolledView ~= nil, "the scrolled view resolved")
      Assert.equal(scrolledView.page.current, 2, "keys turn onto the second page" .. tag)
    else
      local scrolledHeader = drawnBagHeader(scroller)
      Assert.isTrue(
        type(scrolledHeader) == "string" and scrolledHeader:match(" 2/2$") ~= nil,
        "keys turn onto the second page" .. tag
      )
    end
    press(scroller, { type = "cancel" })
    settlePress(scroller)
    press(scroller, { type = "cancel" })
    Assert.equal(scroller.screen:status().mode, "command", "paging cancel returns to command" .. tag)
    scroller.screen:dispose()
    scroller.battle:dispose()
    -- A staged serving cancels back to the exact resting browse.
    local healing = openRig({
      layout = layout,
      launchId = "launch-local-restore-" .. layout,
      party = {
        { species = "EEVEE", level = 20, seed = 0x33333333, currentHp = 10 },
        { species = "EEVEE", level = 5, seed = 0x44444444, ability = "RUN_AWAY", currentHp = 10 },
      },
      bag = {
        { key = "POTION", qty = 5 },
        { key = "POKE_BALL", qty = 5 },
      },
    })
    driveToMode(healing, "command")
    local healRequest = openScreenRequest(healing)
    local healOptions = optionsFor(healing, healRequest)
    local enabledPotions = {}
    for _, actor in ipairs(healOptions.actors) do
      for _, choice in ipairs(actor.choices) do
        if type(choice.id) == "string" and choice.id:match("^item:POTION:") ~= nil then
          if choice.enabled == true then
            enabledPotions[#enabledPotions + 1] = choice.choice
          end
        end
      end
    end
    Assert.isTrue(#enabledPotions >= 1, "the serving stays selectable" .. tag)
    local revision = healing.bag:revision()
    openBagFromCommand(healing)
    walkToMedicineFirstCell(healing)
    local restingHeader = drawnBagHeader(healing)
    if layout == "paired" then
      Assert.isNil(restingHeader, "the paired browse paints no modal title" .. tag)
    else
      Assert.equal(restingHeader, "BAG: hp_pp 1/1", "the browse rests on the serving page" .. tag)
    end
    useNativeBattleBagItem(healing)
    Assert.equal(#healing.submits, 0, "staging seals no reply" .. tag)
    press(healing, { type = "cancel" })
    Assert.equal(healing.screen:status().mode, "child", "target cancel returns to the bag" .. tag)
    Assert.equal(drawnBagHeader(healing), restingHeader, "cancel restores the resting page" .. tag)
    -- Confirming with no further navigation stages again, so the
    -- cancelled browse kept its focus on the serving cell.
    useNativeBattleBagItem(healing)
    Assert.equal(#healing.submits, 0, "the kept focus stages no reply" .. tag)
    Assert.equal(healing.screen:status().mode, "child", "the kept focus stays on its target" .. tag)
    press(healing, { type = "cancel" })
    Assert.equal(healing.screen:status().mode, "child", "the second cancel returns to the bag" .. tag)
    Assert.equal(healing.bag:revision(), revision, "the cancelled serving moves no stock" .. tag)
    useNativeBattleBagItem(healing)
    if #healing.submits == 0 and healing.screen:status().mode == "child" then
      press(healing, { type = "confirm" })
    end
    Assert.equal(#healing.submits, 1, "accepting seals exactly one reply" .. tag)
    assertChoiceAmong(healing.submits[1].choices[1], enabledPotions, "the serving matches its fragment" .. tag)
    healing.screen:dispose()
    healing.battle:dispose()
    -- A trainer throw stays refused and an empty browse closes cleanly.
    local trainer = openRig({
      layout = layout,
      launchId = "launch-local-trainer-" .. layout,
      party = {
        { species = "EEVEE", level = 20, seed = 0x33333333 },
        { species = "EEVEE", level = 5, seed = 0x44444444, ability = "RUN_AWAY" },
      },
      bag = {
        { key = "POKE_BALL", qty = 5 },
      },
      trainer = true,
    })
    driveToMode(trainer, "command")
    openBagFromCommand(trainer)
    walkToBallsFirstCell(trainer)
    press(trainer, { type = "confirm" })
    Assert.equal(#trainer.submits, 0, "the refused throw seals no reply" .. tag)
    Assert.equal(trainer.screen:status().mode, "child", "the refusal keeps the child" .. tag)
    trainer.screen:dispose()
    trainer.battle:dispose()
    local empty = openRig({
      layout = layout,
      launchId = "launch-local-empty-" .. layout,
      party = {
        { species = "EEVEE", level = 20, seed = 0x33333333 },
        { species = "EEVEE", level = 5, seed = 0x44444444, ability = "RUN_AWAY" },
      },
      bag = {},
    })
    driveToMode(empty, "command")
    press(empty, { type = "navigate", direction = "down" })
    press(empty, { type = "navigate", direction = "left" })
    press(empty, { type = "confirm" })
    if empty.screen:status().mode == "child" then
      press(empty, { type = "cancel" })
      Assert.equal(empty.screen:status().mode, "command", "empty cancel returns to command" .. tag)
    else
      Assert.equal(empty.screen:status().mode, "command", "the empty browse never traps" .. tag)
    end
    Assert.equal(#empty.submits, 0, "the empty browse seals nothing" .. tag)
    empty.screen:dispose()
    empty.battle:dispose()
  end
end

-- A real faint opens forced replacement with cancel held shut until the
-- one eligible reserve seals exactly one whole native reply.
function T.forced_replacement_holds_cancel_and_seals_one_reply()
  for _, layout in ipairs({ "paired", "compact" }) do
    local tag = " (" .. layout .. ")"
    requireChildOwner("battle forced replacement")
    local rig = openRig({
      layout = layout,
      launchId = "launch-local-forced-" .. layout,
      party = {
        { species = "EEVEE", level = 5, seed = 0x55555555 },
        { species = "EEVEE", level = 5, seed = 0x66666666 },
      },
      bag = {},
      foe = { species = "EEVEE", level = 30, seed = 0x5EED0002 },
    })
    driveToMode(rig, "command")
    waitForBattleDecision(rig, "replacement")
    local replacementRequest = waitForScreenDecision(rig, "replacement")
    Assert.equal(rig.screen:status().mode, "child", "the faint opens the replacement child" .. tag)
    local _, expectedReplacement = projectedReserveSwitch(rig, replacementRequest)
    local replacementInk = renderedContents(rig)
    Assert.isTrue(replacementInk["Choose a Pokémon."] ~= nil, "replacement titles its modal" .. tag)
    Assert.isTrue(replacementInk["2/6"] ~= nil, "replacement lists both roster slots" .. tag)
    press(rig, { type = "cancel" })
    Assert.equal(#rig.submits, 0, "forced cancel seals nothing" .. tag)
    Assert.equal(rig.screen:status().mode, "child", "forced cancel keeps the child" .. tag)
    chooseReserveThroughChild(rig)
    Assert.equal(#rig.submits, 1, "replacement seals exactly one reply" .. tag)
    Assert.deepEqual(rig.submits[1].choices[1], expectedReplacement, "replacement names the stable reserve" .. tag)
    rig.screen:dispose()
    rig.battle:dispose()
  end
end
-- its own modal geometry: compact stays a fullscreen modal and the
-- paired screen keeps its lower-pane modal, both focus the same
-- reserve with the same guidance and roster count, and cancelling
-- from either returns to the command prompt without sealing a reply.
---@param ink table<string, integer> drawn text census under inspection
---@return integer? focused child row number under inspection
local function focusedChildRow(ink)
  for content, _ in pairs(ink) do
    local standard = tostring(content):match("^> (%d+)%.$")
    if standard ~= nil then
      return tonumber(standard)
    end
    local compact = tostring(content):match("^\226\128\163 (%d+)%.$")
    if compact ~= nil then
      return tonumber(compact)
    end
  end
  return nil
end

---@param rig table live screen rig under test driving
---@return table<string, integer> drawn text census for one rendered frame
local function drawnInk(rig)
  rig.text.draws = {}
  rig.screen:draw({ graphics = FakeGraphics.new({}) })
  local ink = {}
  for _, drawn in ipairs(rig.text.draws) do
    local content = tostring(drawn.content)
    ink[content] = (ink[content] or 0) + 1
  end
  return ink
end
function T.same_party_child_shares_wording_across_layouts_while_keeping_its_own_modal()
  local captured = {}
  for _, layout in ipairs({ "paired", "compact" }) do
    local tag = " (" .. layout .. ")"
    local rig = openRig({
      layout = layout,
      launchId = "launch-shared-child-modal-" .. layout,
      party = {
        { species = "EEVEE", level = 20, seed = 0x33333333 },
        { species = "EEVEE", level = 5, seed = 0x44444444, ability = "RUN_AWAY" },
      },
      bag = {},
    })
    driveToMode(rig, "command")
    openPartyFromCommand(rig)
    Assert.equal(rig.screen:status().mode, "child", "the Pokemon command opens the party child" .. tag)
    rig.windows.calls = {}
    local openedInk = drawnInk(rig)
    local openedFocus = focusedChildRow(openedInk)
    Assert.notNil(openedFocus, "the open child focuses its reserve" .. tag)
    local frames = {}
    for _, call in ipairs(rig.windows.calls) do
      frames[#frames + 1] = call
    end
    captured[layout] = { ink = openedInk, frames = frames, focus = openedFocus }
    press(rig, { type = "navigate", direction = "down" })
    Assert.equal(rig.screen:status().mode, "child", "navigation keeps the party child" .. tag)
    captured[layout].movedFocus = focusedChildRow(drawnInk(rig))
    press(rig, { type = "cancel" })
    Assert.equal(rig.screen:status().mode, "command", "cancelling the party child returns to command" .. tag)
    Assert.equal(#rig.submits, 0, "cancelling the party child seals no reply" .. tag)
    rig.screen:dispose()
    rig.battle:dispose()
  end
  Assert.equal(captured.paired.focus, captured.compact.focus, "both layouts focus the same reserve")
  Assert.equal(
    captured.paired.movedFocus,
    captured.compact.movedFocus,
    "navigation moves both layouts to the same reserve"
  )
  Assert.isTrue(captured.paired.ink["Select a reserve."] ~= nil, "the paired modal guides its voluntary party child")
  Assert.isTrue(
    captured.compact.ink["Select a reserve."] ~= nil,
    "the compact modal guides its voluntary party child identically"
  )
  local shared = {}
  for content, _ in pairs(captured.compact.ink) do
    if content:match("^%d+/%d+$") ~= nil then
      shared[#shared + 1] = content
    end
  end
  Assert.isTrue(#shared >= 1, "the compact modal counts its occupied roster")
  for _, fraction in ipairs(shared) do
    Assert.isTrue(
      captured.paired.ink[fraction] ~= nil,
      "the paired modal counts its occupied roster identically: " .. fraction
    )
  end
  local compactFrame = nil
  for _, call in ipairs(captured.compact.frames) do
    if type(call.applicationBox) == "table" then
      compactFrame = call.applicationBox
    end
  end
  Assert.notNil(compactFrame, "the compact child frames its fullscreen modal")
  Assert.deepEqual(
    { x = compactFrame.x, y = compactFrame.y, width = compactFrame.width, height = compactFrame.height },
    { x = 8, y = 8, width = 240, height = 176 },
    "the compact child keeps its fullscreen modal frame"
  )
  local pairedModal = false
  for _, call in ipairs(captured.paired.frames) do
    Assert.isNil(call.applicationBox, "the paired child keeps its lower-pane modal")
    if type(call.box) == "table" then
      local box = call.box
      if box.x == 0 and box.y == 0 and box.width == 256 and box.height == 192 then
        pairedModal = true
      end
    end
  end
  Assert.isTrue(pairedModal, "the paired child draws its lower-pane modal window")
end

-- Native focus authority for voluntary and forced party selection: keyboard
-- edges wait for the accepted source tick instead of moving focus inside
-- the input call, the accepted tick applies the buffered batch exactly
-- once, and both keyboard and touch seal exactly the projected reserve
-- fragment while a forced first Back stays denied.
function T.native_party_focus_and_fragment_authority()
  for _, layout in ipairs({ "paired", "compact" }) do
    local tag = " (" .. layout .. ")"
    -- Child rows paint from the same canonical row band the session
    -- hit-tests, offset into the interaction pane per display case.
    local yBase = layout == "paired" and 200 or 8
    local rig = openRig({
      layout = layout,
      launchId = "launch-native-party-" .. layout,
      party = {
        { species = "EEVEE", level = 20, seed = 0x33333333 },
        { species = "EEVEE", level = 5, seed = 0x44444444, ability = "RUN_AWAY" },
      },
      bag = {},
    })
    driveToMode(rig, "command")
    local commandRequest = openScreenRequest(rig)
    local _, expectedSwitch = projectedReserveSwitch(rig, commandRequest)
    requireChildOwner("native party focus authority")
    openPartyFromCommand(rig)
    -- Native focus starts on the lead; the reserve is the next source row.
    Assert.equal(focusedChildRow(drawnInk(rig)), 1, "the native focus starts on the lead" .. tag)
    -- A bare input moves no focus: edges wait for the accepted tick.
    rig.screen:input({ { type = "navigate", direction = "down" } })
    Assert.equal(focusedChildRow(drawnInk(rig)), 1, "the navigation edge waits for the accepted source tick" .. tag)
    rig.pump(1)
    Assert.equal(focusedChildRow(drawnInk(rig)), 2, "the accepted tick applies the buffered edge once" .. tag)
    rig.screen:input({ { type = "navigate", direction = "up" } })
    Assert.equal(focusedChildRow(drawnInk(rig)), 2, "the return edge waits for the accepted source tick" .. tag)
    rig.pump(1)
    Assert.equal(focusedChildRow(drawnInk(rig)), 1, "the accepted tick restores the lead focus" .. tag)
    -- A matched tap on the reserve row seals its projected fragment.
    local reserveY = yBase + 44
    rig.screen:input({ { type = "pointer_down", pointerId = "tap:reserve", x = 128, y = reserveY } })
    rig.screen:input({ { type = "pointer_up", pointerId = "tap:reserve", x = 128, y = reserveY } })
    rig.pump(1)
    press(rig, { type = "confirm" })
    press(rig, { type = "confirm" })
    rig.pump(5)
    Assert.equal(#rig.submits, 1, "the tap seals exactly one reply" .. tag)
    Assert.deepEqual(rig.submits[1].choices[1], expectedSwitch, "the tap names the stable reserve" .. tag)
    rig.screen:dispose()
    rig.battle:dispose()
    -- Forced replacement denies the first Back and seals the reserve.
    local forced = openRig({
      layout = layout,
      launchId = "launch-native-forced-" .. layout,
      party = {
        { species = "EEVEE", level = 5, seed = 0x55555555 },
        { species = "EEVEE", level = 5, seed = 0x66666666 },
      },
      bag = {},
      foe = { species = "EEVEE", level = 30, seed = 0x5EED0002 },
    })
    driveToMode(forced, "command")
    waitForBattleDecision(forced, "replacement")
    local replacementRequest = waitForScreenDecision(forced, "replacement")
    local _, expectedReplacement = projectedReserveSwitch(forced, replacementRequest)
    requireChildOwner("native forced replacement authority")
    Assert.equal(focusedChildRow(drawnInk(forced)), 2, "the forced child focuses its eligible reserve" .. tag)
    press(forced, { type = "cancel" })
    Assert.equal(#forced.submits, 0, "forced cancel seals nothing" .. tag)
    Assert.equal(forced.screen:status().mode, "child", "forced cancel keeps the child" .. tag)
    chooseReserveThroughChild(forced)
    Assert.equal(#forced.submits, 1, "replacement seals exactly one reply" .. tag)
    Assert.deepEqual(forced.submits[1].choices[1], expectedReplacement, "replacement names the stable reserve" .. tag)
    forced.screen:dispose()
    forced.battle:dispose()
  end
end

-- The trainer doll refusal reaches its staged message page through the
-- live kernel: a trainer battle refuses the escape doll with Oak's
-- rebuke on the message page, seals no reply, and paints the notice
-- through the narration role in the palette-15 message window
-- (battle_bag_menu.c ShowMessage window at (16,152)).
function T.trainer_doll_refusal_shows_its_staged_message_page()
  local tag = " (paired)"
  requireChildOwner("battle bag refusal")
  local rig = openRig({
    layout = "paired",
    launchId = "launch-refusal-doll-paired",
    party = {
      { species = "EEVEE", level = 20, seed = 0x33333333 },
      { species = "EEVEE", level = 5, seed = 0x44444444, ability = "RUN_AWAY" },
    },
    bag = {
      { key = "POKE_DOLL", qty = 1 },
    },
    trainer = true,
  })
  driveToMode(rig, "command")
  openBagFromCommand(rig)
  -- Pocket menu opens on HP/PP; BATTLE ITEMS sits right-down in the
  -- grid, so right then down focuses it before confirming its list.
  press(rig, { type = "navigate", direction = "right" })
  press(rig, { type = "navigate", direction = "down" })
  press(rig, { type = "confirm" })
  settlePress(rig)
  rig.pump(1)
  useNativeBattleBagItem(rig)
  Assert.equal(#rig.submits, 0, "the refused doll seals no reply" .. tag)
  local childView = rig.screen:view().childView
  Assert.notNil(childView, "the refusal keeps the child" .. tag)
  assert(childView ~= nil, "the refusal keeps its child view")
  Assert.equal(childView.bagPage, "message", "the refused doll opens the message page" .. tag)
  Assert.isTrue(
    tostring(childView.notice):find("MINT", 1, true) ~= nil,
    "the rebuke names the player" .. tag
  )
  renderedContents(rig)
  local inked = nil
  for _, drawn in ipairs(rig.text.draws) do
    if drawn.role == "narration" and tostring(drawn.content):find("MINT", 1, true) ~= nil then
      inked = drawn
      break
    end
  end
  Assert.notNil(inked, "the message paints through the narration role" .. tag)
  assert(inked ~= nil, "the narration draw resolved")
  Assert.equal(inked.x, 16, "the message rides its window column" .. tag)
  Assert.equal(inked.y, 152, "the message rides its window row" .. tag)
  rig.screen:dispose()
  rig.battle:dispose()
end
return { tests = T }
