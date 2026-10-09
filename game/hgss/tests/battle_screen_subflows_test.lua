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
local FakeGraphics = require("tests.support.FakeGraphics")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local HgssBagService = require("libs.hgss.src.items.HgssBagService")
local ItemFixture = require("libs.items.tests.item_fixture")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")
local ScreenTopology = require("libs.ui.src.ScreenTopology")

local T = {}
local TICK = 1 / 60

local CHILD_OWNER_MODULE = "game.hgss.src.battle.BattleSubflows"
local RUNTIME_MODULE = "game.hgss.src.battle.BattleRuntime"
local STATE_MODULE = "game.hgss.src.battle.BattleScreenState"
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
    windows = { calls = {} },
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
  function rig.windows.drawWindow(box, frameKey, background)
    rig.windows.calls[#rig.windows.calls + 1] = { box = box, frame = frameKey, background = background }
  end
  function rig.windows.drawApplicationFrame(box, frameIndex)
    rig.windows.calls[#rig.windows.calls + 1] = { applicationBox = box, frame = frameIndex }
  end
  function rig.audio.play(name)
    rig.audio.plays[#rig.audio.plays + 1] = name
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
      rig.assets.images[key] = { handle = key }
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
  local player = { trainerId = 99, trainerName = "MINT", language = "french" }
  local launch = nil
  local scenario = nil
  if opts.trainer == true then
    local trainerId = launchId .. "-rival"
    scenario = ScenarioFactory.fromTrainer({
      id = launchId .. "-scenario",
      trainers = {
        {
          id = trainerId,
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
    launchId = launchId,
    manifest = {
      schema = "test",
      version = { id = "t", language = "english" },
      verified = false,
      scenes = { { key = "general/plain/day" } },
    },
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
---@param mode string awaited controller mode under test driving
---@return table the screen status once the mode is reached
local function driveToMode(rig, mode)
  for _ = 1, 600 do
    rig.pump(1)
    local status = rig.screen:status()
    if status.mode == "failed" then
      error("the battle screen failed while driving to " .. mode .. ": " .. tostring(status.error), 0)
    end
    if status.mode == mode then
      return status
    end
  end
  error("the battle screen never reached " .. mode .. " (" .. rig.layout .. ")", 0)
end

---@param rig table live screen rig under test driving
---@param event table<string, unknown> semantic input batch under test driving
local function press(rig, event)
  rig.screen:input({ event })
  rig.pump(1)
end

---@param rig table live screen rig under test driving, resting on its command prompt
local function openPartyFromCommand(rig)
  press(rig, { type = "navigate", direction = "down" })
  press(rig, { type = "navigate", direction = "right" })
  press(rig, { type = "confirm" })
  Assert.equal(rig.screen:status().mode, "child", "the Pokemon command opens the party child (" .. rig.layout .. ")")
end

---@param rig table live screen rig under test driving, resting on its command prompt
local function openBagFromCommand(rig)
  press(rig, { type = "navigate", direction = "down" })
  press(rig, { type = "navigate", direction = "left" })
  press(rig, { type = "confirm" })
  Assert.equal(rig.screen:status().mode, "child", "the Bag command opens the bag child (" .. rig.layout .. ")")
end

-- Pocket tabs step through the pocket order with wraparound while the top
-- grid row reaches the active tab and a tab returns to the remembered
-- cell, so from the opening cell the medicine first cell is up, right,
-- down and the balls first cell is one more tab right.
---@param rig table live screen rig under test driving, resting on the open bag child
local function walkToMedicineFirstCell(rig)
  press(rig, { type = "navigate", direction = "up" })
  press(rig, { type = "navigate", direction = "right" })
  press(rig, { type = "navigate", direction = "down" })
end

---@param rig table live screen rig under test driving, resting on the open bag child
local function walkToBallsFirstCell(rig)
  press(rig, { type = "navigate", direction = "up" })
  press(rig, { type = "navigate", direction = "right" })
  press(rig, { type = "navigate", direction = "right" })
  press(rig, { type = "navigate", direction = "down" })
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
  return foundId --[[@as integer]], foundFragment --[[@as table<string, unknown>]]
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
  for _ = 1, 600 do
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

-- Choosing a reserve through the party child stays correct however the
-- child focuses: the only legal switch names the reserve, so a refusal
-- keeps the child open for one step down while a focused reserve seals
-- immediately. Either way at most one reply seals.
---@param rig table live screen rig under test driving, resting on the open party child
local function chooseReserveThroughChild(rig)
  press(rig, { type = "confirm" })
  if #rig.submits == 0 and rig.screen:status().mode == "child" then
    press(rig, { type = "navigate", direction = "down" })
    press(rig, { type = "confirm" })
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
      wiped.pump(20)
    end
    Assert.equal(wiped.battle:status().phase, "complete", "the wiped side settles the battle" .. tag)
    Assert.equal(wiped.battle:status().result, "loss", "the wiped side reports its loss" .. tag)
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
    press(healing, { type = "confirm" })
    Assert.equal(#healing.submits, 0, "staging the serving seals no reply" .. tag)
    Assert.equal(healing.screen:status().mode, "child", "staging keeps the child open" .. tag)
    press(healing, { type = "cancel" })
    Assert.equal(healing.screen:status().mode, "child", "target cancel returns to the retained bag" .. tag)
    Assert.equal(#healing.submits, 0, "target cancel seals no reply" .. tag)
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
    press(healing, { type = "confirm" })
    press(healing, { type = "confirm" })
    if #healing.submits == 0 and healing.screen:status().mode == "child" then
      press(healing, { type = "navigate", direction = "down" })
      press(healing, { type = "confirm" })
    end
    if #healing.submits == 0 and healing.screen:status().mode ~= "child" then
      openBagFromCommand(healing)
      walkToMedicineFirstCell(healing)
      press(healing, { type = "confirm" })
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
    press(capture, { type = "confirm" })
    Assert.equal(#capture.submits, 1, "throwing the ball seals exactly one reply" .. tag)
    Assert.deepEqual(capture.submits[1].choices[1], ballFragment, "the throw matches its native fragment" .. tag)
    -- Pump through the terminal narration.
    -- The capture narration needs about seven hundred fixed ticks; the
    -- authored budget stops mid-drain.
    for _ = 1, 800 do
      capture.pump(1)
      if capture.battle:status().phase == "complete" or capture.battle:status().phase == "failed" then
        break
      end
    end
    Assert.equal(capture.battle:status().phase, "complete", "the throw settles the battle" .. tag)
    Assert.equal(capture.battle:status().result, "capture", "the guaranteed ball reports its capture" .. tag)
    Assert.equal(capture.bag:quantity("MASTER_BALL"), 0, "the thrown ball publishes exactly once" .. tag)
    local replayed = capture.battle:submit(capture.submits[1])
    Assert.isFalse(replayed == true, "a repeated capture reply seals nothing more" .. tag)
    capture.screen:dispose()
    capture.battle:dispose()

    -- Trainer capture stays refused with its reason before any selection
    -- result could consume stock.
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
          Assert.isFalse(choice.enabled == true, "the trainer ball stays unavailable" .. tag)
          Assert.isTrue(type(choice.reason) == "string" and choice.reason ~= "", "the refusal names its reason" .. tag)
        end
      end
    end
    Assert.isTrue(ballChoices >= 1, "the trainer bag still lists its balls" .. tag)
    requireChildOwner("trainer capture refusal")
    openBagFromCommand(trainer)
    walkToBallsFirstCell(trainer)
    press(trainer, { type = "confirm" })
    Assert.equal(#trainer.submits, 0, "confirming a refused ball seals no reply" .. tag)
    Assert.equal(trainer.bag:quantity("POKE_BALL"), 5, "the refused ball takes no stock" .. tag)
    press(trainer, { type = "cancel" })
    press(trainer, { type = "cancel" })
    Assert.equal(#trainer.submits, 0, "leaving the refused bag seals no reply" .. tag)
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
    press(rig, { type = "navigate", direction = "left" })
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
    press(rig, { type = "confirm" })
    Assert.equal(#rig.submits, 0, "staging the target seals no reply" .. tag)
    press(rig, { type = "navigate", direction = "down" })
    press(rig, { type = "navigate", direction = "up" })
    Assert.equal(rig.screen:status().mode, "child", "the inert bag answers no input" .. tag)
    Assert.equal(#rig.submits, 0, "the inert bag seals no reply" .. tag)
    press(rig, { type = "cancel" })
    Assert.equal(rig.screen:status().mode, "child", "target cancel reactivates the bag" .. tag)
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
  Assert.isTrue(
    censusSize(after) >= censusSize(before) + 4,
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

-- Probes the open child with matched press/release taps across the
-- interaction surface until one tap seals a reply. A tap that closes a
-- cancellable child without sealing reopens it once and continues, so
-- a footer cancel never ends the probe early. Two passes cover rows
-- that focus on the first tap and seal on the second.
---@param rig table live screen rig under test driving
---@param yLo integer first host row under probing
---@param yHi integer last host row under probing
---@param reopen (fun(rig: table))? reopens a voluntary child after a cancel tap
---@return boolean sealed true once a tap sealed exactly one reply
local function tapSealsReply(rig, yLo, yHi, reopen)
  local taps = 0
  local cancelled = 0
  for pass = 1, 2 do
    local y = yLo
    while y <= yHi do
      local x = 8
      while x <= 248 do
        if rig.screen:status().mode ~= "child" then
          if #rig.submits > 0 then
            return true
          end
          if reopen == nil or cancelled >= 1 then
            return false
          end
          cancelled = cancelled + 1
          reopen(rig)
          if rig.screen:status().mode ~= "child" then
            return false
          end
        end
        taps = taps + 1
        local id = "touch:probe:" .. tostring(pass) .. ":" .. tostring(taps)
        rig.screen:input({ { type = "pointer_down", pointerId = id, x = x, y = y } })
        rig.screen:input({ { type = "pointer_up", pointerId = id, x = x, y = y } })
        rig.pump(1)
        if #rig.submits > 0 then
          return true
        end
        x = x + 16
      end
      y = y + 16
    end
  end
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

return { tests = T }
