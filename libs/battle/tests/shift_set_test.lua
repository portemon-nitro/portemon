-- The KO-response style is a mechanics decision carried explicitly:
-- only the shift style in an eligible singles format requests the optional
-- exchange through the decision protocol with exactly the permitted
-- information about the arrival, the set style and ineligible formats
-- continue without any prompt, the style travels as an explicit option,
-- and a required replacement ignores trapping without counting as a
-- voluntary exchange.

local Assert = require("tests.support.Assert")
local SessionFixture = require("libs.battle.tests.session_fixture")
local BattleErrors = require("libs.battle.src.errors")

local T = {}

---@param behavior string missing owner under test
---@return table the loaded exchange-continuation owner
local function switchingOwner(behavior)
  return SessionFixture.requirePresent("libs.battle.src.gen4.Switching", behavior)
end

---@param style string KO-response style under test
---@param activeSlots integer active positions per side under test
---@return table eligibility query for the optional exchange
local function shiftQuery(style, activeSlots)
  return {
    position = 1,
    incoming = 2,
    reason = "shift",
    style = style,
    topology = { activePerSide = activeSlots },
    trap = { held = false },
    reserves = { 2, 3 },
  }
end

-- Only the shift style requests the optional exchange: the prompt vocabulary
-- exists in the decision protocol, eligibility holds, and the preview
-- carries exactly the permitted arrival identity.
function T.only_shift_style_requests_the_optional_exchange()
  local Switching = switchingOwner("the source exchange continuation owns switch sequencing")
  local Protocol = SessionFixture.requirePresent(
    "libs.battle.src.BattleProtocol",
    "the typed decision protocol owns prompt vocabulary"
  )
  Assert.isTrue(Protocol.isDecisionKind("shift"), "the optional exchange flows through the decision protocol")
  local accepted =
    Protocol.validateChoice({ actor = { combatant = 1 }, kind = "switch", payload = { replacement = 2 } }, "shift")
  Assert.equal(accepted.kind, "switch", "the shift prompt accepts the exchange choice")
  local verdict = Switching.eligible(shiftQuery("shift", 1))
  Assert.isTrue(verdict.ok, "the shift style in singles requests the optional exchange")
  local frame = Switching.validateFrame(Switching.start({
    position = 1,
    outgoing = { combatant = 1, activation = 7 },
    incoming = 2,
    reason = "shift",
    style = "shift",
    topology = { activePerSide = 1 },
    trap = { held = false },
    reserves = { 2, 3 },
  }))
  Assert.equal(frame.reason, "shift", "the frame keeps its exchange reason")
  Assert.keySet(frame.preview, "incoming", "the prompt carries exactly the permitted information")
  Assert.equal(frame.preview.incoming, 2, "the preview names the arrival and nothing else")
end

-- The set style continues without a prompt: eligibility fails and starting
-- the optional exchange is rejected as invalid input.
function T.set_style_continues_without_a_prompt()
  local Switching = switchingOwner("the source exchange continuation owns switch sequencing")
  local verdict = Switching.eligible(shiftQuery("set", 1))
  Assert.isFalse(verdict.ok, "the set style never requests the optional exchange")
  Assert.notNil(verdict.reason, "the refusal names its reason")
  local failure = Assert.throws(function()
    Switching.start({
      position = 1,
      outgoing = { combatant = 1, activation = 7 },
      incoming = 2,
      reason = "shift",
      style = "set",
      topology = { activePerSide = 1 },
      trap = { held = false },
      reserves = { 2, 3 },
    })
  end)
  Assert.isTrue(
    type(failure) == "table" and failure.code == BattleErrors.INPUT,
    "a shift exchange under the set style fails as invalid input"
  )
end

-- Ineligible formats never offer the prompt even when the style is shift:
-- only single-position sides are asked.
function T.ineligible_formats_never_offer_the_prompt()
  local Switching = switchingOwner("the source exchange continuation owns switch sequencing")
  local doubles = Switching.eligible(shiftQuery("shift", 2))
  Assert.isFalse(doubles.ok, "multi-position formats never request the optional exchange")
  local multi = Switching.eligible({
    position = 1,
    incoming = 2,
    reason = "shift",
    style = "shift",
    topology = { activePerSide = 1, partners = true },
    trap = { held = false },
    reserves = { 2, 3 },
  })
  Assert.isFalse(multi.ok, "partner formats never request the optional exchange")
end

-- A required replacement ignores trapping and is not a voluntary exchange:
-- every documented reason validates, and only the voluntary reason counts
-- as voluntary.
function T.required_replacement_ignores_trapping_and_is_not_voluntary()
  local Switching = switchingOwner("the source exchange continuation owns switch sequencing")
  local verdict = Switching.eligible({
    position = 1,
    incoming = 2,
    reason = "faint",
    trap = { held = true },
    reserves = { 2, 3 },
  })
  Assert.isTrue(verdict.ok, "a required replacement answers despite the trap")
  local frame = Switching.validateFrame(Switching.start({
    position = 1,
    outgoing = { combatant = 1, activation = 7 },
    incoming = 2,
    reason = "faint",
    trap = { held = true },
    reserves = { 2, 3 },
  }))
  Assert.isFalse(frame.voluntary, "a required replacement is not a voluntary exchange")
  for _, reason in ipairs({ "voluntary", "forced", "faint", "u_turn", "baton_pass", "shift" }) do
    local candidate = Switching.validateFrame({
      position = 1,
      outgoing = { combatant = 1, activation = 7 },
      incoming = 2,
      reason = reason,
      voluntary = reason == "voluntary",
      activation = 11,
      cursor = "start",
      transferredEffects = {},
    })
    Assert.equal(candidate.reason, reason, "the documented reason validates: " .. reason)
  end
end

-- The style travels as an explicit option: identical queries differing only
-- in the style field decide differently, so no hidden preference is read.
function T.style_travels_as_an_explicit_option()
  local Switching = switchingOwner("the source exchange continuation owns switch sequencing")
  local shifted = Switching.eligible(shiftQuery("shift", 1))
  local settled = Switching.eligible(shiftQuery("set", 1))
  Assert.isTrue(shifted.ok, "the explicit shift option requests the exchange")
  Assert.isFalse(settled.ok, "the explicit set option withholds the exchange")
end

-- Serialized replacement continuations below: the Shift offer is a
-- serializable replacement occurrence owned by the HGSS executor, not a
-- visual shortcut. Every scenario seats a player side against one
-- opposing trainer in singles; only the noted style, format, and roster
-- facts vary per case.

local NATIVE_SEED = 0x1BADB002

---@return table loaded native session owner
local function executorOwner()
  return SessionFixture.requirePresent(
    "libs.battle.src.gen4.HgssSessionExecutor",
    "the private native lifecycle owns HGSS ruleset sessions"
  )
end

---@return table frozen battle content carrying the native ruleset binding
local function nativeContent()
  local ContentBuilder = require("libs.content.src.ContentBuilder")
  local BattleBehaviorBuilder = require("libs.battle.src.BattleBehaviorBuilder")
  local BattleContent = require("libs.battle.src.BattleContent")
  local NativeTypeChart = require("libs.battle.src.gen4.NativeTypeChart")
  local Executor = executorOwner()
  local builder = ContentBuilder.new()
  NativeTypeChart.install(builder, "shift-offer-tests")
  local behaviors = BattleBehaviorBuilder.new()
  behaviors:registerRuleset(
    Executor.RULESET,
    { key = Executor.RULESET, chart = Executor.RULESET },
    "shift-offer-tests"
  )
  return BattleContent.new(builder:freeze(), behaviors:freeze())
end

---@param id integer nonreused positive combatant identity
---@param seed integer fixed generator state for the underlying mon
---@param species string catalog species key
---@return table combatant seed striking with a single known move entry
local function tackleSeed(id, seed, species)
  local CatalogFixture = require("libs.mons.tests.catalog_fixture")
  local catalog = CatalogFixture.makeCatalog()
  local factory = CatalogFixture.makeFactory(seed, catalog)
  local record = factory:createNormal(CatalogFixture.normalRequest({ species = species, level = 9 }))
  record.moves = { { move = "TACKLE", pp = 35, ppUps = 0 } }
  return { id = id, mon = record }
end

---@param seeds table<integer, table<string, unknown>> combatant seeds under fact resolution
---@return table<string, table<string, unknown>> immutable move facts for the fixture strikes
local function tacticMoveFacts(seeds)
  local CatalogFixture = require("libs.mons.tests.catalog_fixture")
  local catalog = CatalogFixture.makeCatalog()
  local facts = {
    TACKLE = catalog:move("TACKLE"),
    STRUGGLE = { power = 50, accuracy = 100, category = "physical", moveType = "normal", priority = 0 },
  }
  for _, seed in ipairs(seeds) do
    local learned = seed.mon --[[@as table<string, unknown>]]
    for _, entry in
      ipairs(learned.moves --[[@as table<integer, table<string, unknown>>]])
    do
      if type(entry) == "table" and type(entry.move) == "string" and facts[entry.move] == nil then
        if entry.move == "SPIKES" then
          local shaped = {}
          for key, value in pairs(catalog:move("GROWL")) do
            shaped[key] = value
          end
          shaped.moveType = "ground"
          facts.SPIKES = shaped
        else
          facts[entry.move] = catalog:move(entry.move)
        end
      end
    end
    local form = catalog:form(learned.species --[[@as string]], learned.form --[[@as integer]])
    for _, chance in ipairs(form.levelUpMoves) do
      if facts[chance.move] == nil then
        facts[chance.move] = catalog:move(chance.move)
      end
    end
  end
  return facts
end

---@param seeds table<integer, table<string, unknown>> combatant seeds under fact resolution
---@return table<string, table<string, unknown>> static species facts for the fixture combatants
local function tacticSpeciesFacts(seeds)
  local CatalogFixture = require("libs.mons.tests.catalog_fixture")
  local catalog = CatalogFixture.makeCatalog()
  local facts = {}
  for _, seed in ipairs(seeds) do
    local mon = seed.mon --[[@as table<string, unknown>]]
    local species = mon.species --[[@as string]]
    local form = mon.form --[[@as integer]]
    local bucket = facts[species]
    if bucket == nil then
      bucket = {}
      facts[species] = bucket
    end
    local formRecord = catalog:form(species, form)
    local types = {}
    for _, key in ipairs(formRecord.types --[[@as string[] ]]) do
      types[#types + 1] = key
    end
    bucket[form] = {
      baseStats = formRecord.baseStats,
      growthCurve = catalog:growthCurve(catalog:species(species).growthCurve --[[@as string]]),
      types = types,
      levelUpMoves = formRecord.levelUpMoves,
      baseExpYield = catalog:species(species).baseExpYield,
      evYield = catalog:species(species).evYield,
    }
  end
  return facts
end

---@param opts table scenario options under construction
---@return table detached native trainer-singles setup record
local function trainerSinglesScenario(opts)
  local Executor = executorOwner()
  local playerLead = tackleSeed(1, 11, "CHIKORITA")
  local playerReserve = tackleSeed(3, 31, "EEVEE")
  local foeLead = tackleSeed(2, 23, "EEVEE")
  foeLead.mon.condition.currentHp = 1
  local foeReserve = tackleSeed(4, 41, "PICHU")
  local seeds = { playerLead, playerReserve, foeLead, foeReserve }
  if opts.foeLeadHp ~= nil then
    foeLead.mon.condition.currentHp = opts.foeLeadHp
  end
  local playerContext = {}
  if opts.style ~= nil then
    playerContext.battleStyle = opts.style
  end
  local foeRoster = { foeLead, foeReserve }
  if opts.foeReserves == false then
    foeRoster = { foeLead }
    seeds = { playerLead, playerReserve, foeLead }
  end
  local playerParticipant = SessionFixture.participant(1, 1, "player", { playerLead, playerReserve })
  playerParticipant.context = playerContext
  return {
    ruleset = Executor.RULESET,
    format = opts.format or "singles",
    kind = opts.kind or "trainer",
    sides = { SessionFixture.side(1, { 1 }), SessionFixture.side(2, { 2 }) },
    participants = {
      playerParticipant,
      SessionFixture.participant(2, 2, "trainer:probe", foeRoster),
    },
    positions = {
      SessionFixture.position(1, 1, { 1 }, 1),
      SessionFixture.position(2, 2, { 2 }, 2),
    },
    inventories = {},
    environment = { weather = "none" },
    random = { seed = NATIVE_SEED },
    formatState = {},
    moveFacts = tacticMoveFacts(seeds),
    speciesFacts = tacticSpeciesFacts(seeds),
  }
end

---@param contracts table session contracts under the live session
---@param scenario table detached native battle setup under construction
---@return table live headless native session
local function openNative(contracts, scenario)
  local session = contracts.Battle.newSession(scenario, nativeContent())
  Assert.notNil(session, "the native session admits its trainer singles")
  return session
end

---@param session table live headless session under test driving
---@param playerSlot integer zero-based player move slot under submission
---@param foeSlot integer zero-based foe move slot under submission
---@return table boundary frame at the next atomic boundary
local function answerTurn(session, playerSlot, foeSlot)
  local frame = SessionFixture.driveUntilSettled(session)
  Assert.equal(frame.status, "waiting", "open turns wait for decisions")
  for _, request in ipairs(frame.request.requests) do
    local choices = {}
    for _, actor in ipairs(request.actors) do
      local slot = request.controller == "player" and playerSlot or foeSlot
      local opposing = request.controller == "player" and 2 or 1
      choices[#choices + 1] = SessionFixture.attackChoice(actor, slot, SessionFixture.positionTarget(opposing))
    end
    local ok, replyErr = session:submit(SessionFixture.replyFor(request, choices))
    Assert.isTrue(ok, "scripted answers to open requests are accepted: " .. tostring(replyErr))
  end
  return session:advance(1024)
end

---@param session table live headless session under inspection
---@param frame table boundary frame under inspection
---@return table? the open shift request, nil without one
local function findShiftRequest(session, frame)
  if frame.status ~= "waiting" or frame.request == nil then
    return nil
  end
  for _, request in ipairs(frame.request.requests) do
    local options = session:decisionOptions(request.requestId)
    if options ~= nil then
      for _, actor in ipairs(options.actors or {}) do
        if type(actor) == "table" and actor.kind == "shift" then
          return request
        end
      end
    end
  end
  return nil
end

---@param session table live headless session under inspection
---@param request table open shift request under projection
---@return table the shift actor entry
local function shiftActorOf(session, request)
  local options = session:decisionOptions(request.requestId)
  Assert.notNil(options, "the shift request projects its options")
  for _, actor in ipairs(options.actors or {}) do
    if type(actor) == "table" and actor.kind == "shift" then
      return actor
    end
  end
  error("the shift request addresses its shift actor", 0)
end

-- The Shift style freezes the foe arrival behind exactly one offer: the
-- decision names the frozen reserve and a stay fragment, and staying
-- releases the held arrival without an exchange.
function T.shift_style_freezes_the_foe_arrival_behind_one_offer()
  local contracts = SessionFixture.sessionContracts()
  local session = openNative(contracts, trainerSinglesScenario({ style = "shift" }))
  local knockout = answerTurn(session, 0, 0)
  Assert.equal(knockout.status, "waiting", "the knockout suspends on the held arrival")
  local request = findShiftRequest(session, knockout)
  Assert.notNil(request, "Shift publishes its optional decision")
  local actor = shiftActorOf(session, request --[[@as table]])
  Assert.equal(actor.incoming, 4, "the offer freezes the next opposing reserve")
  local stay = nil
  local switches = 0
  for _, choice in ipairs(actor.choices or {}) do
    if choice.id == "shift:stay" then
      stay = choice.choice
    elseif type(choice.id) == "string" and choice.id:match("^switch:") ~= nil then
      switches = switches + 1
    end
  end
  Assert.notNil(stay, "the offer carries its stay fragment")
  Assert.isTrue(switches >= 1, "the offer carries its legal switches")
  Assert.equal((stay --[[@as table<string, unknown>]]).kind, "confirm", "staying confirms")
  Assert.deepEqual(
    (stay --[[@as table<string, unknown>]]).payload,
    {},
    "staying carries an empty payload"
  )
  local reply = SessionFixture.replyFor(request --[[@as table]], { stay })
  local ok, replyErr = session:submit(reply)
  Assert.isTrue(ok, "the stay is accepted: " .. tostring(replyErr))
  local refused, refusedErr = session:submit(reply)
  Assert.isFalse(refused, "the consumed offer answers exactly once")
  Assert.notNil(refusedErr, "the duplicate reply names its refusal")
  local resumed = session:advance(1024)
  Assert.isTrue(resumed.status == "waiting" or resumed.status == "ended", "staying resumes the battle")
  Assert.isNil(findShiftRequest(session, resumed), "the consumed offer never repeats")
  session:dispose()
end

-- The Set style sends the foe without an offer: the frozen selection
-- still enters through the existing reserve owner, then the next
-- ordinary turn follows.
function T.set_style_sends_the_foe_without_an_offer()
  local contracts = SessionFixture.sessionContracts()
  local session = openNative(contracts, trainerSinglesScenario({ style = "set" }))
  local knockout = answerTurn(session, 0, 0)
  Assert.equal(knockout.status, "waiting", "the knockout settles into the next decision")
  Assert.isNil(findShiftRequest(session, knockout), "Set never publishes a shift actor")
  session:dispose()
end

-- Wild encounters never offer the switch even under Shift: the
-- replacement resolves through the existing owner.
function T.wild_battles_never_offer_the_switch()
  local contracts = SessionFixture.sessionContracts()
  local session = openNative(contracts, trainerSinglesScenario({ style = "shift", kind = "wild" }))
  local knockout = answerTurn(session, 0, 0)
  Assert.equal(knockout.status, "waiting", "the wild knockout settles into the next decision")
  Assert.isNil(findShiftRequest(session, knockout), "wild battles never publish a shift actor")
  session:dispose()
end

-- Style-absent low-level contexts keep the predecessor no-offer
-- behavior instead of reading a hidden preference.
function T.style_absent_contexts_keep_no_offer_behavior()
  local contracts = SessionFixture.sessionContracts()
  local session = openNative(contracts, trainerSinglesScenario({}))
  local knockout = answerTurn(session, 0, 0)
  Assert.equal(knockout.status, "waiting", "the knockout settles into the next decision")
  Assert.isNil(findShiftRequest(session, knockout), "absent styles never publish a shift actor")
  session:dispose()
end

-- A malformed present style rejects admission instead of running
-- without an offer.
function T.malformed_styles_reject_admission()
  local contracts = SessionFixture.sessionContracts()
  local scenario = trainerSinglesScenario({ style = "shift" })
  scenario.participants[1].context = { battleStyle = "auto" }
  local ok = pcall(contracts.Battle.newSession, scenario, nativeContent())
  Assert.isFalse(ok, "the malformed style fails admission")
end

-- An exhausted foe bench ends the battle without an offer: there is no
-- frozen arrival to hold.
function T.exhausted_foe_bench_ends_the_battle_without_an_offer()
  local contracts = SessionFixture.sessionContracts()
  local session = openNative(contracts, trainerSinglesScenario({ style = "shift", foeReserves = false }))
  local settled = SessionFixture.driveToEnd(session, 1024, function(request)
    local choices = {}
    for _, actor in ipairs(request.actors) do
      local opposing = request.controller == "player" and 2 or 1
      choices[#choices + 1] = SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(opposing))
    end
    return choices
  end)
  Assert.isTrue(#settled > 0, "the terminal battle emits its events")
  session:dispose()
end

-- Doubles never offer the switch even under Shift: only single-position
-- sides are asked.
function T.doubles_battles_never_offer_the_switch()
  local contracts = SessionFixture.sessionContracts()
  local Executor = executorOwner()
  local playerLead = tackleSeed(1, 11, "CHIKORITA")
  local playerAlly = tackleSeed(3, 31, "EEVEE")
  local foeLead = tackleSeed(2, 23, "EEVEE")
  foeLead.mon.condition.currentHp = 1
  local foeAlly = tackleSeed(4, 41, "PICHU")
  local seeds = { playerLead, playerAlly, foeLead, foeAlly }
  local playerParticipant = SessionFixture.participant(1, 1, "player", { playerLead, playerAlly })
  playerParticipant.context = { battleStyle = "shift" }
  local scenario = {
    ruleset = Executor.RULESET,
    format = "doubles",
    kind = "trainer",
    sides = { SessionFixture.side(1, { 1 }), SessionFixture.side(2, { 2 }) },
    participants = {
      playerParticipant,
      SessionFixture.participant(2, 2, "trainer:probe", { foeLead, foeAlly }),
    },
    positions = {
      SessionFixture.position(1, 1, { 1 }, 1),
      SessionFixture.position(2, 1, { 1 }, 3),
      SessionFixture.position(3, 2, { 2 }, 2),
      SessionFixture.position(4, 2, { 2 }, 4),
    },
    inventories = {},
    environment = { weather = "none" },
    random = { seed = NATIVE_SEED },
    formatState = {},
    moveFacts = tacticMoveFacts(seeds),
    speciesFacts = tacticSpeciesFacts(seeds),
  }
  local session = openNative(contracts, scenario)
  local frame = SessionFixture.driveUntilSettled(session)
  Assert.equal(frame.status, "waiting", "the doubles opener waits for decisions")
  for _, request in ipairs(frame.request.requests) do
    local choices = {}
    for _, actor in ipairs(request.actors) do
      local opposing = request.controller == "player" and 3 or 1
      choices[#choices + 1] = SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(opposing))
    end
    local ok, replyErr = session:submit(SessionFixture.replyFor(request, choices))
    Assert.isTrue(ok, "doubles answers are accepted: " .. tostring(replyErr))
  end
  local knockout = session:advance(1024)
  Assert.equal(knockout.status, "waiting", "the doubles knockout settles into the next decision")
  Assert.isNil(findShiftRequest(session, knockout), "doubles never publish a shift actor")
  session:dispose()
end

-- A simultaneous knockout replaces the player first: the mandatory
-- replacement precedes the optional offer, and the offer follows once
-- the player side stands again.
function T.simultaneous_knockout_replaces_the_player_first_then_offers()
  local contracts = SessionFixture.sessionContracts()
  local Executor = executorOwner()
  local playerLead = { id = 1, mon = SessionFixture.makeMon(11) }
  playerLead.mon.moves = {}
  playerLead.mon.condition.currentHp = 1
  local playerReserve = tackleSeed(3, 31, "EEVEE")
  local playerAnchor = tackleSeed(5, 51, "TOTODILE")
  local foeLead = tackleSeed(2, 23, "EEVEE")
  foeLead.mon.condition.currentHp = 1
  foeLead.mon.heldItem = "LAGGING_TAIL"
  local foeReserve = tackleSeed(4, 41, "PICHU")
  local seeds = { playerLead, playerReserve, playerAnchor, foeLead, foeReserve }
  local playerParticipant = SessionFixture.participant(1, 1, "player", { playerLead, playerReserve, playerAnchor })
  playerParticipant.context = { battleStyle = "shift" }
  local scenario = {
    ruleset = Executor.RULESET,
    format = "singles",
    kind = "trainer",
    sides = { SessionFixture.side(1, { 1 }), SessionFixture.side(2, { 2 }) },
    participants = {
      playerParticipant,
      SessionFixture.participant(2, 2, "trainer:probe", { foeLead, foeReserve }),
    },
    positions = {
      SessionFixture.position(1, 1, { 1 }, 1),
      SessionFixture.position(2, 2, { 2 }, 2),
    },
    inventories = {},
    environment = { weather = "none" },
    random = { seed = NATIVE_SEED },
    formatState = {},
    moveFacts = tacticMoveFacts(seeds),
    speciesFacts = tacticSpeciesFacts(seeds),
  }
  local session = openNative(contracts, scenario)
  local frame = SessionFixture.driveUntilSettled(session)
  for _, request in ipairs(frame.request.requests) do
    local choices = {}
    for _, actor in ipairs(request.actors) do
      local opposing = request.controller == "player" and 2 or 1
      choices[#choices + 1] = SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(opposing))
    end
    local ok, replyErr = session:submit(SessionFixture.replyFor(request, choices))
    Assert.isTrue(ok, "mutual knockout answers are accepted: " .. tostring(replyErr))
  end
  local waiting = session:advance(1024)
  Assert.equal(waiting.status, "waiting", "the mutual knockout suspends on replacement")
  Assert.isNil(findShiftRequest(session, waiting), "a fainted player side is never offered a switch")
  local mandatory = nil
  for _, request in ipairs(waiting.request.requests) do
    local options = session:decisionOptions(request.requestId)
    for _, actor in ipairs(options.actors or {}) do
      if type(actor) == "table" and actor.kind == "replacement" then
        mandatory = request
      end
    end
  end
  Assert.notNil(mandatory, "the mandatory player replacement precedes the offer")
  local options = session:decisionOptions((mandatory --[[@as table]]).requestId)
  local fragment = nil
  for _, actor in ipairs(options.actors or {}) do
    for _, choice in ipairs(actor.choices or {}) do
      if type(choice.id) == "string" and choice.id:match("^switch:") ~= nil and fragment == nil then
        fragment = choice.choice
      end
    end
  end
  Assert.notNil(fragment, "the mandatory replacement names its reserve")
  local ok, replyErr = session:submit(SessionFixture.replyFor(mandatory --[[@as table]], { fragment }))
  Assert.isTrue(ok, "the mandatory replacement is accepted: " .. tostring(replyErr))
  local offered = session:advance(1024)
  Assert.equal(offered.status, "waiting", "the held foe replacement suspends on the offer")
  Assert.notNil(findShiftRequest(session, offered), "the standing player side is offered the switch")
  session:dispose()
end

-- Move learning returns to the held replacement: the learning prompt
-- suspends first, and the offer follows once the lesson settles.
function T.move_learning_returns_to_the_held_replacement()
  local contracts = SessionFixture.sessionContracts()
  local Executor = executorOwner()
  local CatalogFixture = require("libs.mons.tests.catalog_fixture")
  local catalog = CatalogFixture.makeCatalog()
  local factory = CatalogFixture.makeFactory(11, catalog)
  local recipient = factory:createNormal(CatalogFixture.normalRequest({ species = "CHIKORITA", level = 11 }))
  recipient.experience = 972
  recipient.moves = {
    { move = "TACKLE", pp = 35, ppUps = 0 },
    { move = "GROWL", pp = 40, ppUps = 0 },
    { move = "RAZOR_LEAF", pp = 25, ppUps = 0 },
    { move = "POISONPOWDER", pp = 30, ppUps = 0 },
  }
  local lead = { id = 1, mon = recipient }
  local playerReserve = tackleSeed(3, 31, "EEVEE")
  local foeLead = tackleSeed(2, 23, "EEVEE")
  foeLead.mon.condition.currentHp = 1
  local foeReserve = tackleSeed(4, 41, "PICHU")
  local seeds = { lead, playerReserve, foeLead, foeReserve }
  local playerParticipant = SessionFixture.participant(1, 1, "player", { lead, playerReserve })
  playerParticipant.context = { battleStyle = "shift" }
  local scenario = {
    ruleset = Executor.RULESET,
    format = "singles",
    kind = "trainer",
    sides = { SessionFixture.side(1, { 1 }), SessionFixture.side(2, { 2 }) },
    participants = {
      playerParticipant,
      SessionFixture.participant(2, 2, "trainer:probe", { foeLead, foeReserve }),
    },
    positions = {
      SessionFixture.position(1, 1, { 1 }, 1),
      SessionFixture.position(2, 2, { 2 }, 2),
    },
    inventories = {},
    environment = { weather = "none" },
    random = { seed = NATIVE_SEED },
    formatState = {},
    moveFacts = tacticMoveFacts(seeds),
    speciesFacts = tacticSpeciesFacts(seeds),
  }
  local session = openNative(contracts, scenario)
  local knockout = answerTurn(session, 0, 0)
  Assert.equal(knockout.status, "waiting", "the knockout suspends on the lesson")
  Assert.isNil(findShiftRequest(session, knockout), "learning suspends before the offer")
  local learning = nil
  for _, request in ipairs(knockout.request.requests) do
    if request.kind == "learn_move" then
      learning = request
    end
  end
  Assert.notNil(learning, "the full move set suspends on its learning prompt")
  local actor = (learning --[[@as table]]).actors[1]
  local decline = { actor = actor, kind = "confirm", payload = { decision = "decline" } }
  local ok, replyErr = session:submit(SessionFixture.replyFor(learning --[[@as table]], { decline }))
  Assert.isTrue(ok, "declining the lesson is accepted: " .. tostring(replyErr))
  local offered = session:advance(1024)
  Assert.equal(offered.status, "waiting", "the held replacement suspends on the offer")
  local request = findShiftRequest(session, offered)
  Assert.notNil(request, "the lesson returns to the held offer")
  local shift = shiftActorOf(session, request --[[@as table]])
  Assert.equal(shift.incoming, 4, "the held offer keeps its frozen arrival")
  session:dispose()
end

-- An arrival felled by entry hazards re-enters settlement: the
-- shift exchange runs first, then the hazard knockout replaces the
-- arrival mandatorily while the held foe still arrives.
function T.hazard_felled_arrivals_reenter_settlement()
  local contracts = SessionFixture.sessionContracts()
  local Executor = executorOwner()
  local CatalogFixture = require("libs.mons.tests.catalog_fixture")
  local catalog = CatalogFixture.makeCatalog()
  local playerLead = tackleSeed(1, 11, "CHIKORITA")
  playerLead.mon.heldItem = "LAGGING_TAIL"
  local frail = tackleSeed(3, 31, "EEVEE")
  frail.mon.condition.currentHp = 1
  local anchor = tackleSeed(5, 51, "PICHU")
  local foeLead = tackleSeed(2, 23, "TOTODILE")
  foeLead.mon.condition.currentHp = 1
  do
    local factory = CatalogFixture.makeFactory(23, catalog)
    local record = factory:createNormal(CatalogFixture.normalRequest({ species = "TOTODILE", level = 9 }))
    record.moves = { { move = "SPIKES", pp = 20, ppUps = 0 }, { move = "TACKLE", pp = 35, ppUps = 0 } }
    record.condition.currentHp = 1
    foeLead = { id = 2, mon = record }
  end
  local foeReserve = tackleSeed(4, 41, "PICHU")
  local seeds = { playerLead, frail, anchor, foeLead, foeReserve }
  local playerParticipant = SessionFixture.participant(1, 1, "player", { playerLead, frail, anchor })
  playerParticipant.context = { battleStyle = "shift" }
  local scenario = {
    ruleset = Executor.RULESET,
    format = "singles",
    kind = "trainer",
    sides = { SessionFixture.side(1, { 1 }), SessionFixture.side(2, { 2 }) },
    participants = {
      playerParticipant,
      SessionFixture.participant(2, 2, "trainer:probe", { foeLead, foeReserve }),
    },
    positions = {
      SessionFixture.position(1, 1, { 1 }, 1),
      SessionFixture.position(2, 2, { 2 }, 2),
    },
    inventories = {},
    environment = { weather = "none" },
    random = { seed = NATIVE_SEED },
    formatState = {},
    moveFacts = tacticMoveFacts(seeds),
    speciesFacts = tacticSpeciesFacts(seeds),
  }
  local session = openNative(contracts, scenario)
  local frame = SessionFixture.driveUntilSettled(session)
  for _, request in ipairs(frame.request.requests) do
    local choices = {}
    for _, actor in ipairs(request.actors) do
      if request.controller == "player" then
        choices[#choices + 1] = SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(2))
      else
        choices[#choices + 1] = SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(1))
      end
    end
    local ok, replyErr = session:submit(SessionFixture.replyFor(request, choices))
    Assert.isTrue(ok, "the spikes turn is accepted: " .. tostring(replyErr))
  end
  local waiting = session:advance(1024)
  Assert.equal(waiting.status, "waiting", "the spikes turn suspends on the offer")
  local request = findShiftRequest(session, waiting)
  Assert.notNil(request, "the layered field still offers the switch")
  local actor = shiftActorOf(session, request --[[@as table]])
  local frailFragment = nil
  for _, choice in ipairs(actor.choices or {}) do
    if choice.id == "switch:3" then
      frailFragment = choice.choice
    end
  end
  Assert.notNil(frailFragment, "the frail reserve stays selectable")
  local ok, replyErr = session:submit(SessionFixture.replyFor(request --[[@as table]], { frailFragment }))
  Assert.isTrue(ok, "the frail exchange is accepted: " .. tostring(replyErr))
  local settled = session:advance(1024)
  Assert.equal(settled.status, "waiting", "the hazard knockout suspends on replacement")
  Assert.isNil(findShiftRequest(session, settled), "the hazard knockout is mandatory, not optional")
  local mandatory = nil
  for _, pending in ipairs(settled.request.requests) do
    local options = session:decisionOptions(pending.requestId)
    for _, entry in ipairs(options.actors or {}) do
      if type(entry) == "table" and entry.kind == "replacement" then
        mandatory = pending
      end
    end
  end
  Assert.notNil(mandatory, "the felled arrival is replaced mandatorily")
  session:dispose()
end

-- Restored offers keep their frozen identity: capture and restore at
-- the open decision replays the same arrival, while snapshots taken
-- before the offer stay readable and offer-free.
function T.restored_offers_keep_their_frozen_identity()
  local contracts = SessionFixture.sessionContracts()
  local Executor = executorOwner()
  local session = openNative(contracts, trainerSinglesScenario({ style = "shift" }))
  local knockout = answerTurn(session, 0, 0)
  local request = findShiftRequest(session, knockout)
  Assert.notNil(request, "the offer opens before the capture")
  local held = session:capture()
  SessionFixture.assertPlainData(held, "pending.shift")
  local rngCalls = held.rng.calls
  local revived = Executor.restore(held, nativeContent())
  local resumed = revived:advance(1024)
  Assert.equal(resumed.status, "waiting", "the restored offer waits for its answer")
  local restored = nil
  for _, pending in ipairs(resumed.request.requests) do
    local options = revived:decisionOptions(pending.requestId)
    for _, actor in ipairs(options.actors or {}) do
      if type(actor) == "table" and actor.kind == "shift" then
        restored = pending
        Assert.equal(actor.incoming, 4, "the restored offer keeps its frozen arrival")
      end
    end
  end
  Assert.notNil(restored, "the restored session replays the same offer")
  Assert.equal(revived:capture().rng.calls, rngCalls, "restoring draws no replacement roll")
  local actor = nil
  do
    local options = revived:decisionOptions((restored --[[@as table]]).requestId)
    for _, entry in ipairs(options.actors or {}) do
      if type(entry) == "table" and entry.kind == "shift" then
        actor = entry
      end
    end
  end
  local stay = nil
  for _, choice in ipairs(actor.choices or {}) do
    if choice.id == "shift:stay" then
      stay = choice.choice
    end
  end
  Assert.notNil(stay, "the restored offer carries its stay fragment")
  local ok, replyErr = revived:submit(SessionFixture.replyFor(restored --[[@as table]], { stay }))
  Assert.isTrue(ok, "the restored stay is accepted: " .. tostring(replyErr))
  local settled = revived:advance(1024)
  Assert.isTrue(settled.status == "waiting" or settled.status == "ended", "the restored stay resumes")
  session:dispose()
  revived:dispose()
end

-- Stale and illegal replies fail without partial state: a second answer
-- to the consumed offer, a wrong epoch, an illegal reserve, and a
-- wrong choice kind all refuse while the held arrival stays frozen.
function T.stale_and_illegal_replies_fail_without_partial_state()
  local contracts = SessionFixture.sessionContracts()
  local session = openNative(contracts, trainerSinglesScenario({ style = "shift" }))
  local knockout = answerTurn(session, 0, 0)
  local request = findShiftRequest(session, knockout)
  Assert.notNil(request, "the offer opens before the illegal replies")
  local before = session:capture()
  local actor = shiftActorOf(session, request --[[@as table]])
  local stay = nil
  for _, choice in ipairs(actor.choices or {}) do
    if choice.id == "shift:stay" then
      stay = choice.choice
    end
  end
  Assert.notNil(stay, "the offer carries its stay fragment")
  local wrongEpoch = {
    requestId = (request --[[@as table]]).requestId,
    epoch = (request --[[@as table]]).epoch + 7,
    controller = (request --[[@as table]]).controller,
    choices = { stay },
  }
  local okEpoch, errEpoch = session:submit(wrongEpoch)
  Assert.isFalse(okEpoch, "the wrong epoch is rejected")
  Assert.notNil(errEpoch, "the wrong epoch names its refusal")
  local illegalReserve = {
    actor = (stay --[[@as table<string, unknown>]]).actor,
    kind = "switch",
    payload = { replacement = 2 },
  }
  local okReserve, errReserve = session:submit(SessionFixture.replyFor(request --[[@as table]], { illegalReserve }))
  Assert.isFalse(okReserve, "the fainted foe reserve is rejected")
  Assert.notNil(errReserve, "the illegal reserve names its refusal")
  local wrongKind = {
    actor = (stay --[[@as table<string, unknown>]]).actor,
    kind = "attack",
    payload = { moveSlot = 0, target = SessionFixture.positionTarget(2) },
  }
  local okKind, errKind = session:submit(SessionFixture.replyFor(request --[[@as table]], { wrongKind }))
  Assert.isFalse(okKind, "the wrong choice kind is rejected")
  Assert.notNil(errKind, "the wrong kind names its refusal")
  local after = session:capture()
  Assert.deepEqual(after.pending, before.pending, "refused replies keep the held continuation")
  local ok, replyErr = session:submit(SessionFixture.replyFor(request --[[@as table]], { stay }))
  Assert.isTrue(ok, "the valid stay still answers: " .. tostring(replyErr))
  session:dispose()
end

return { tests = T }
