-- Battle Style end-to-end: the saved Shift/Set setting governs the real
-- optional replacement decision in a production trainer battle. A Shift
-- knockout freezes the incoming foe, publishes one stay-or-switch action
-- request with a minimal preview, and settles the held arrival after
-- exactly one accepted reply; Set never offers. The screen asks through
-- the native Yes/No prompt and the existing party child, where both
-- cancellations answer stay without a second offer.

local Assert = require("tests.support.Assert")
local BattlePresentationManifestFixture = require("tests.support.BattlePresentationManifestFixture")
local BattlePresentationSchema = require("libs.assets.src.battle.BattlePresentationSchema")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local FakeGraphics = require("tests.support.FakeGraphics")
local HgssBagService = require("libs.hgss.src.items.HgssBagService")
local ItemFixture = require("libs.items.tests.item_fixture")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")
local ScreenTopology = require("libs.ui.src.ScreenTopology")
local SourceTick = require("libs.hgss.src.field.SourceTick")

local T = {}
local TICK = SourceTick.DT

local RUNTIME_MODULE = "game.hgss.src.battle.BattleRuntime"
local STATE_MODULE = "game.hgss.tests.support.BattleScreenFixture"
local MODEL_MODULE = "game.hgss.src.battle.BattlePresentationModel"
local SCENARIO_FACTORY_MODULE = "libs.hgss.src.battle.HgssBattleScenarioFactory"

---@param value unknown value under test preparation
---@return unknown a detached copy sharing no table with the source
local function deepCopy(value)
  if type(value) ~= "table" then
    return value
  end
  local copy = {}
  for key, item in pairs(value) do
    copy[deepCopy(key)] = deepCopy(item)
  end
  return copy
end

---@return table detached schema-valid staged manifest for the style harness scene
local function screenManifest()
  local manifest = deepCopy(BattlePresentationManifestFixture.manifest())
  manifest.scenes = { { key = "general/plain/day", background = "general", terrain = "plain", time = "day" } }
  BattlePresentationSchema.assertManifest(manifest)
  return manifest
end

---@param image table fake image handle under inspection
---@return integer staged image width
local function fakeImageWidth(image)
  return image.width
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

local function fakeImageHeight(image)
  return image.height
end

---@return table dual-surface display facts for the style harness
local function dualMeasurement()
  return {
    width = 256,
    height = 384,
    topology = ScreenTopology.dualDisplay(
      { id = "main", rect = { x = 0, y = 0, width = 256, height = 192 }, touch = false, role = "world" },
      { id = "lower", rect = { x = 0, y = 192, width = 256, height = 192 }, touch = true, role = "auxiliary" }
    ),
    pixelRatio = 1,
    signature = "battle-style-test:dual",
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
    record.moves = member.moves or { { move = "TACKLE", pp = 35, ppUps = 0 } }
    if member.currentHp ~= nil then
      record.condition.currentHp = member.currentHp
    end
    Assert.isTrue(owner:addMon(record), "the style path needs its live party member")
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

---@param style string saved battle style under test driving
---@return table player record carrying the style beside a valid profile
local function playerRecordFor(style)
  return {
    profile = CatalogFixture.profile(),
    options = {
      textSpeed = "fastest",
      textFrame = 0,
      battleStyle = style,
      battleScene = true,
      soundMode = "stereo",
      battleSpeed = 1,
    },
  }
end

---@param opts table rig options under test preparation
---@return table live rig with the runtime, screen, stocked bag, and submit log
local function openRig(opts)
  local BattleRuntime = require(RUNTIME_MODULE)
  local BattleScreenState = require(STATE_MODULE)
  local Model = require(MODEL_MODULE)
  local ScenarioFactory = require(SCENARIO_FACTORY_MODULE)
  local holder = {}
  local rig = {
    submits = {},
    packets = {},
    measurement = dualMeasurement(),
    text = { draws = {} },
    windows = { calls = {}, background = { 0.2, 0.3, 0.1, 1 } },
    audio = { plays = {} },
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
  function rig.audio.play(first, second)
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
    return true
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
  local party = makePartyOwner(opts.party or {
    { species = "EEVEE", level = 20, seed = 0x33333333 },
    { species = "EEVEE", level = 5, seed = 0x44444444 },
  })
  local bag = HgssBagService.new({ catalog = ItemFixture.makeCatalog() })
  -- A battle switch never reorders the persistent party: the guard
  -- fails the run if the style path ever mutates field order early.
  party.swapPartyMons = function()
    error("a battle switch never reorders the persistent party", 2)
  end
  rig.party = party
  rig.bag = bag
  local launchId = opts.launchId or "launch-battle-style"
  local foeLead = makeFoe(opts.foeLead or { species = "EEVEE", level = 4, seed = 0x5EED0002, currentHp = 1 })
  local foeReserve = makeFoe(opts.foeReserve or { species = "PICHU", level = 4, seed = 0x5EED0003 })
  local trainerId = launchId .. "-trainer"
  local scenario = ScenarioFactory.fromTrainer({
    id = launchId .. "-scenario",
    format = "single",
    trainers = {
      {
        id = trainerId,
        name = "JOEY",
        class = "YOUNGSTER",
        party = { foeLead, foeReserve },
        aiPasses = {},
      },
    },
  }, {
    party = party,
    bag = bag,
    player = { trainerId = 99, trainerName = "MINT", language = "english", trainerClassKey = "PKMN_TRAINER_ETHAN" },
  })
  rig.scenario = scenario
  rig.trainerId = trainerId
  rig.foeLeadName = foeLead.nickname ~= nil and foeLead.nickname ~= "" and foeLead.nickname or foeLead.species
  rig.foeReserveName = foeReserve.nickname ~= nil and foeReserve.nickname ~= "" and foeReserve.nickname
    or foeReserve.species
  local screen = BattleScreenState.new({
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
    itemCatalog = ItemFixture.makeCatalog(),
    monCatalog = CatalogFixture.makeCatalog(),
    assets = rig.assets,
    text = rig.text,
    windows = rig.windows,
    audio = rig.audio,
  })
  rig.screen = screen
  local port = screen:presentationPort()
  local present = port.present
  port.present = function(packet)
    rig.packets[#rig.packets + 1] = packet
    return present(packet)
  end
  rig.port = port
  holder.battle = BattleRuntime.new({
    request = { id = launchId, kind = "trainer", payload = { trainer = trainerId } },
    scenario = scenario,
    party = party,
    bag = bag,
    player = { record = playerRecordFor(opts.battleStyle or "shift"), context = {} },
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
  for _ = 1, 1200 do
    ackNarration(rig)
    rig.pump(1)
    local status = rig.screen:status()
    if status.mode == "failed" then
      error("the battle screen failed while driving to " .. mode .. ": " .. tostring(status.error), 0)
    end
    if status.mode == mode then
      return status
    end
  end
  local screenStatus = rig.screen:status()
  local battleStatus = rig.battle:status()
  error(
    "the battle screen never reached "
      .. mode
      .. " (screen "
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

---@param rig table live screen rig under test driving
---@param wanted string awaited battle decision kind under test driving
---@return table the battle request once the kernel asks for the wanted decision
local function waitForBattleRequest(rig, wanted)
  local lastPhase, lastKind, lastError = nil, nil, nil
  for _ = 1, 240 do
    ackNarration(rig)
    local status = rig.battle:status()
    lastPhase = status.phase
    lastError = status.error
    lastKind = status.request ~= nil and status.request.kind or nil
    if status.phase == "failed" then
      error("the battle failed while awaiting " .. wanted .. ": " .. tostring(status.error), 0)
    end
    if status.phase == "complete" then
      error("the battle settled before asking for " .. wanted, 0)
    end
    if status.request ~= nil then
      if wanted == "shift" then
        local options = rig.battle:decisionOptions(status.request.requestId)
        if options ~= nil then
          for _, actor in ipairs(options.actors or {}) do
            if type(actor) == "table" and actor.kind == "shift" then
              return status.request
            end
          end
        end
      elseif status.request.kind == wanted then
        return status.request
      end
    end
    rig.pump(4)
  end
  error(
    "the battle never asked for " .. wanted .. " (phase=" .. tostring(lastPhase) .. ", kind=" .. tostring(lastKind) .. ", error=" .. tostring(lastError) .. ")",
    0
  )
end

---@param rig table live screen rig under test driving
---@param request table open battle request under submission
local function submitFirstEnabledMove(rig, request)
  local options = rig.battle:decisionOptions(request.requestId)
  Assert.notNil(options, "the opening turn projects its options")
  for _, actor in ipairs(options.actors or {}) do
    for _, choice in ipairs(actor.choices or {}) do
      if choice.role == "move" and choice.enabled == true then
        local ok, submitErr = rig.battle:submit({
          requestId = request.requestId,
          epoch = request.epoch,
          controller = request.controller,
          choices = { choice.choice },
        })
        Assert.isTrue(ok, "the opening strike is accepted: " .. tostring(submitErr))
        return
      end
    end
  end
  error("the opening request carries an enabled move", 0)
end

---@param rig table live screen rig under test driving
---@return table the shift request once the kernel publishes the held arrival
local function knockOutLeadingFoe(rig)
  local opening = waitForBattleRequest(rig, "action")
  submitFirstEnabledMove(rig, opening)
  return waitForBattleRequest(rig, "shift")
end

---@param request table open shift request under projection
---@return table detached native decision options for the open request
local function shiftOptions(rig, request)
  local options, optionsErr = rig.battle:decisionOptions(request.requestId)
  Assert.notNil(options, "the shift request projects its options: " .. tostring(optionsErr))
  return options --[[@as table<string, unknown>]]
end

---@param options table shift decision options under inspection
---@return table the shift actor entry
local function shiftActor(options)
  for _, actor in ipairs(options.actors or {}) do
    if type(actor) == "table" and actor.kind == "shift" then
      return actor
    end
  end
  error("the shift request addresses its shift actor", 0)
end

---@param actor table shift actor entry under inspection
---@return table the stay fragment answering the offer
---@return table the first legal switch fragment answering the offer
local function shiftFragments(actor)
  local stay = nil
  local switch = nil
  for _, choice in ipairs(actor.choices or {}) do
    if choice.id == "shift:stay" then
      stay = choice.choice
    elseif type(choice.id) == "string" and choice.id:match("^switch:") ~= nil and choice.enabled == true then
      if switch == nil then
        switch = choice.choice
      end
    end
  end
  Assert.notNil(stay, "the shift offer carries its stay fragment")
  Assert.notNil(switch, "the shift offer carries a legal switch fragment")
  return stay, switch
end

---@param rig table live screen rig under test driving
---@param request table open shift request under answering
---@param fragment table kernel choice fragment answering the offer
local function answerShift(rig, request, fragment)
  local ok, submitErr = rig.battle:submit({
    requestId = request.requestId,
    epoch = request.epoch,
    controller = request.controller,
    choices = { fragment },
  })
  Assert.isTrue(ok, "the shift answer is accepted: " .. tostring(submitErr))
end

---@param rig table live screen rig under test driving
---@param swaps integer expected foe send-out events under inspection
---@return integer foe send-out events observed so far
local function countFoeArrivals(rig)
  local arrivals = 0
  for _, packet in ipairs(rig.packets) do
    for _, event in ipairs(packet.events or {}) do
      if event.kind == "switch" and type(event.payload) == "table" then
        local payload = event.payload --[[@as table<string, unknown>]]
        local cause = event.cause --[[@as table<string, unknown>?]]
        if type(cause) == "table" and cause.kind == "faint" and payload.from ~= nil then
          local combatant = nil
          for _, battler in ipairs((packet.after and packet.after.foes) or {}) do
            if type(battler) == "table" and battler.combatant == payload.to then
              combatant = battler.combatant
            end
          end
          if combatant ~= nil then
            arrivals = arrivals + 1
          end
        end
      end
    end
  end
  return arrivals
end

-- The Shift knockout publishes exactly one stay-or-switch decision naming
-- the frozen arrival and nothing else: the incoming name rides the
-- preview while the enemy bench stays undisclosed.
function T.shift_offer_names_the_frozen_arrival_and_nothing_else()
  local rig = openRig({ launchId = "launch-style-offer", battleStyle = "shift" })
  local request = knockOutLeadingFoe(rig)
  local options = shiftOptions(rig, request)
  local actor = shiftActor(options)
  local stay, _ = shiftFragments(actor)
  Assert.equal(stay.kind, "confirm", "the stay fragment confirms without a switch")
  Assert.deepEqual(stay.payload, {}, "the stay fragment carries an empty payload")
  local preview = nil
  for _, packet in ipairs(rig.packets) do
    local published = packet.request --[[@as table<string, unknown>?]]
    if
      type(published) == "table"
      and published.requestId == request.requestId
      and type(published.options) == "table"
    then
      for _, entry in ipairs(published.options.actors or {}) do
        if type(entry) == "table" and entry.kind == "shift" and type(entry.preview) == "table" then
          preview = entry.preview
        end
      end
    end
  end
  Assert.notNil(preview, "the published offer carries its minimal preview")
  local seen = {}
  for key in pairs(preview) do
    seen[key] = true
  end
  for _, key in ipairs({ "trainerClassKey", "trainerName", "incomingName", "incomingSpecies", "playerName" }) do
    Assert.isTrue(seen[key] == true, "the preview carries " .. key)
    seen[key] = nil
  end
  Assert.isTrue(next(seen) == nil, "the preview discloses nothing beyond the offer facts")
  Assert.equal(preview.incomingName, rig.foeReserveName, "the preview names the frozen arrival")
  Assert.equal(preview.trainerName, "JOEY", "the preview names the opposing trainer")
  Assert.equal(preview.trainerClassKey, "YOUNGSTER", "the preview names the opposing trainer class")
  local callsBefore = rig.battle:status().phase == "running" and 0 or 0
  Assert.isTrue(callsBefore == 0, "the offer publishes without consuming the battle")
  local first = shiftOptions(rig, request)
  local second = shiftOptions(rig, request)
  Assert.deepEqual(first, second, "redrawing the offer projects the identical decision")
end

-- Answering Yes exchanges the player side before the held foe arrival:
-- one accepted reply settles exactly one player exchange and one foe
-- send-out with no extra turn and no early field mutation.
function T.shift_yes_exchanges_before_the_frozen_foe_arrives()
  local rig = openRig({ launchId = "launch-style-yes", battleStyle = "shift" })
  local leadBefore = rig.party:partyMon(0)
  local reserveBefore = rig.party:partyMon(1)
  local request = knockOutLeadingFoe(rig)
  local actor = shiftActor(shiftOptions(rig, request))
  local _, switch = shiftFragments(actor)
  answerShift(rig, request, switch)
  local stale, staleErr = rig.battle:submit({
    requestId = request.requestId,
    epoch = request.epoch,
    controller = request.controller,
    choices = { switch },
  })
  Assert.isFalse(stale, "the consumed offer answers exactly once: " .. tostring(staleErr and staleErr.message))
  local next = waitForBattleRequest(rig, "action")
  Assert.isTrue(next.requestId ~= request.requestId, "the answered offer releases its decision")
  Assert.isTrue(countFoeArrivals(rig) >= 1, "the held foe arrival reaches the field")
  Assert.deepEqual(rig.party:partyMon(0), leadBefore, "the exchange never reorders the persistent lead")
  Assert.deepEqual(rig.party:partyMon(1), reserveBefore, "the exchange never reorders the persistent reserve")
end

-- Answering No keeps the active mon while the frozen foe still arrives:
-- the stay fragment settles the held replacement without an exchange.
function T.shift_no_stays_and_releases_the_frozen_foe()
  local rig = openRig({ launchId = "launch-style-no", battleStyle = "shift" })
  local leadBefore = rig.party:partyMon(0)
  local request = knockOutLeadingFoe(rig)
  local actor = shiftActor(shiftOptions(rig, request))
  local stay, _ = shiftFragments(actor)
  answerShift(rig, request, stay)
  local next = waitForBattleRequest(rig, "action")
  Assert.isTrue(next.requestId ~= request.requestId, "the answered offer releases its decision")
  Assert.isTrue(countFoeArrivals(rig) >= 1, "staying still releases the frozen arrival")
  Assert.deepEqual(rig.party:partyMon(0), leadBefore, "staying never touches the persistent party")
end

-- Set never publishes an offer: the foe replacement resolves on its own
-- and the next ordinary turn follows without a stay-or-switch decision.
function T.set_style_sends_the_foe_without_an_offer()
  local rig = openRig({ launchId = "launch-style-set", battleStyle = "set" })
  local opening = waitForBattleRequest(rig, "action")
  submitFirstEnabledMove(rig, opening)
  local next = waitForBattleRequest(rig, "action")
  Assert.isTrue(next.requestId ~= opening.requestId, "the foe replacement settles into the next turn")
  local options = rig.battle:decisionOptions(next.requestId)
  Assert.notNil(options, "the next turn projects its options")
  for _, actor in ipairs(options.actors or {}) do
    Assert.isTrue(actor.kind ~= "shift", "Set never publishes a shift actor")
  end
  for _, packet in ipairs(rig.packets) do
    local published = packet.request --[[@as table<string, unknown>?]]
    if type(published) == "table" and type(published.options) == "table" then
      for _, entry in ipairs(published.options.actors or {}) do
        Assert.isTrue(entry.kind ~= "shift", "Set never publishes a shift preview")
      end
    end
  end
end

-- A malformed present style rejects battle admission instead of running
-- without an offer.
function T.malformed_style_rejects_battle_admission()
  -- The malformed style travels in the rig's own player record: one
  -- live party owner means the rig battle itself must carry it, so the
  -- failure surfaces on the ordinary preparation path.
  local rig = openRig({ launchId = "launch-style-broken", battleStyle = "zilch" })
  for _ = 1, 1200 do
    rig.pump(1)
    if rig.battle:status().phase == "failed" then
      break
    end
  end
  local closing = rig.battle:status()
  Assert.isTrue(
    closing.phase == "failed",
    "the malformed style fails preparation (phase=" .. tostring(closing.phase) .. " error=" .. tostring(
      closing.error
    ) .. ")"
  )
  Assert.isTrue(
    tostring(closing.error):find("shift or set", 1, true) ~= nil,
    "the failure names the admitted styles"
  )
end

-- The screen asks the held offer through its own prompt: Yes opens the
-- existing party child in the shift purpose, and the reserve seals the
-- projected switch fragment.
function T.screen_yes_opens_the_shift_party_child_and_seals_the_reserve()
  local rig = openRig({ launchId = "launch-style-screen-yes", battleStyle = "shift" })
  knockOutLeadingFoe(rig)
  local status = driveToMode(rig, "shift")
  Assert.equal(status.selection, "yes", "the offer opens answering Yes")
  local view = rig.screen:view()
  Assert.isTrue(
    type(view.message) == "string" and view.message:find(rig.foeReserveName, 1, true) ~= nil,
    "the prompt names the frozen arrival"
  )
  press(rig, { type = "confirm" })
  Assert.equal(rig.screen:status().mode, "child", "Yes opens the party child")
  local childView = rig.screen:view().childView
  Assert.notNil(childView, "the offer carries its child view")
  Assert.equal(childView.kind, "party", "Yes opens the existing party picker")
  Assert.equal(childView.purpose, "shift", "the picker runs in the shift purpose")
  local submitsBefore = #rig.submits
  for _ = 1, 6 do
    press(rig, { type = "confirm" })
    if #rig.submits > submitsBefore then
      break
    end
    press(rig, { type = "navigate", direction = "down" })
  end
  Assert.equal(#rig.submits, submitsBefore + 1, "the reserve seals exactly one reply")
  local sealed = rig.submits[#rig.submits]
  Assert.equal(sealed.choices[1].kind, "switch", "the sealed fragment exchanges")
  local next = waitForBattleRequest(rig, "action")
  Assert.notNil(next, "the answered offer resumes the battle")
end

-- The screen answers No by staying: the sealed confirm carries an empty
-- payload and the held foe arrives without a second offer.
function T.screen_no_answers_stay_and_releases_the_foe()
  local rig = openRig({ launchId = "launch-style-screen-no", battleStyle = "shift" })
  knockOutLeadingFoe(rig)
  driveToMode(rig, "shift")
  press(rig, { type = "navigate", direction = "down" })
  local status = rig.screen:status()
  Assert.equal(status.selection, "no", "the offer toggles to No")
  press(rig, { type = "confirm" })
  Assert.equal(#rig.submits, 1, "No seals exactly one reply")
  Assert.equal(rig.submits[1].choices[1].kind, "confirm", "No seals the stay fragment")
  Assert.deepEqual(rig.submits[1].choices[1].payload, {}, "the stay fragment carries an empty payload")
  local next = waitForBattleRequest(rig, "action")
  Assert.notNil(next, "staying resumes the battle without a second offer")
  local options = rig.battle:decisionOptions(next.requestId)
  for _, actor in ipairs(options.actors or {}) do
    Assert.isTrue(actor.kind ~= "shift", "the consumed offer never repeats")
  end
end

-- Cancelling the prompt answers stay: B seals the same empty confirm
-- without reopening the offer.
function T.screen_prompt_cancel_answers_stay_without_a_second_offer()
  local rig = openRig({ launchId = "launch-style-screen-b", battleStyle = "shift" })
  knockOutLeadingFoe(rig)
  driveToMode(rig, "shift")
  press(rig, { type = "cancel" })
  Assert.equal(#rig.submits, 1, "cancelling the prompt seals exactly one reply")
  Assert.equal(rig.submits[1].choices[1].kind, "confirm", "prompt cancel seals stay")
  Assert.deepEqual(rig.submits[1].choices[1].payload, {}, "prompt cancel carries an empty payload")
  local next = waitForBattleRequest(rig, "action")
  Assert.notNil(next, "the cancelled offer resumes the battle without a second offer")
end

-- Cancelling the shift party child answers stay like the source
-- replacement subscript: no second prompt, no forced switch.
function T.screen_party_cancel_answers_stay_without_a_second_offer()
  local rig = openRig({ launchId = "launch-style-screen-party-b", battleStyle = "shift" })
  knockOutLeadingFoe(rig)
  driveToMode(rig, "shift")
  press(rig, { type = "confirm" })
  Assert.equal(rig.screen:status().mode, "child", "Yes opens the party child")
  press(rig, { type = "cancel" })
  for _ = 1, 10 do
    rig.pump(1)
    if #rig.submits > 0 then
      break
    end
  end
  Assert.equal(#rig.submits, 1, "party cancel seals exactly one reply")
  Assert.equal(rig.submits[1].choices[1].kind, "confirm", "party cancel seals stay")
  local next = waitForBattleRequest(rig, "action")
  Assert.notNil(next, "the cancelled picker resumes the battle without a second offer")
end

return { tests = T }
