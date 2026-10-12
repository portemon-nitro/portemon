-- Paired-lead battle decisions through the real screen and the real
-- runtime: two addressed leads stage one fragment each and answer with a
-- single two-choice reply, staged resources stay unique across actors, and
-- forced replacements never publish a partial reply. Synthetic parties and
-- generated trainer records only; no dump capability is required.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local HgssBagService = require("libs.hgss.src.items.HgssBagService")
local ItemFixture = require("libs.items.tests.item_fixture")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")
local ScreenTopology = require("libs.ui.src.ScreenTopology")

local T = {}
local TICK = 1 / 60

local RUNTIME_MODULE = "game.hgss.src.battle.BattleRuntime"
local STATE_MODULE = "game.hgss.src.battle.BattleScreenState"
local MODEL_MODULE = "game.hgss.src.battle.BattlePresentationModel"
local SCENARIO_FACTORY_MODULE = "libs.hgss.src.battle.HgssBattleScenarioFactory"

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
      signature = "battle-double-batch-test:compact",
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
    signature = "battle-double-batch-test:paired",
  }
end

---@param catalog table mon catalog under record creation
---@param seed integer fixed generator state under record creation
---@param species string
---@param level integer
---@param moves table[] battle-local move entries under record creation
---@param currentHp integer? wounded health under record creation, nil for full health
---@return table full mon-domain record
local function leadRecord(catalog, seed, species, level, moves, currentHp)
  local factory = CatalogFixture.makeFactory(seed, catalog)
  local record = factory:createNormal(CatalogFixture.normalRequest({ species = species, level = level }))
  record.moves = moves
  if currentHp ~= nil then
    record.condition.currentHp = currentHp
  end
  return record
end

---@param opts table rig options under test preparation
---@return table live rig with the double runtime, screen, and submit log
local function openDoubleRig(opts)
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
  function rig.audio.play(name)
    rig.audio.plays[#rig.audio.plays + 1] = name
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
      rig.assets.images[key] = { handle = key }
    end
    return rig.assets.images[key]
  end
  function rig.assets.release(key)
    rig.assets.released[key] = (rig.assets.released[key] or 0) + 1
  end
  local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
  local catalog = CatalogFixture.makeCatalog()
  local wounded = opts.wounded == true
  local function hp()
    return wounded and 10 or nil
  end
  local party = HgssMonService.new({
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
  local firstLeadMoves = opts.firstLeadMoves or { { move = "TACKLE", pp = 35, ppUps = 0 } }
  local secondLeadMoves = opts.secondLeadMoves or { { move = "GROWL", pp = 40, ppUps = 0 } }
  Assert.isTrue(
    party:addMon(leadRecord(catalog, 0x33333333, "EEVEE", 8, firstLeadMoves, hp())),
    "the first lead enters the live party"
  )
  Assert.isTrue(
    party:addMon(leadRecord(catalog, 0x44444444, "EEVEE", 8, secondLeadMoves, hp())),
    "the second lead enters the live party"
  )
  Assert.isTrue(
    party:addMon(leadRecord(catalog, 0x55555555, "EEVEE", 8, { { move = "TACKLE", pp = 35, ppUps = 0 } }, nil)),
    "the benched reserve enters the live party"
  )
  Assert.isTrue(
    party:addMon(leadRecord(catalog, 0x66666666, "EEVEE", 8, { { move = "TACKLE", pp = 35, ppUps = 0 } }, nil)),
    "the second benched reserve enters the live party"
  )
  local bag = HgssBagService.new({ catalog = ItemFixture.makeCatalog() })
  Assert.isTrue(bag:add("POTION", 1), "the double path stocks its single serving")
  for _, key in ipairs({ "take", "move", "tryRegister", "unregister" }) do
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
  local launchId = opts.launchId or "launch-double-batch"
  local foeCatalog = CatalogFixture.makeCatalog()
  local function foeRecord(species, seed)
    local factory = CatalogFixture.makeFactory(seed, foeCatalog)
    local record = factory:createNormal(CatalogFixture.normalRequest({ species = species, level = 4 }))
    record.moves = { { move = "TACKLE", pp = 35, ppUps = 0 } }
    return record
  end
  local trainerId = launchId .. "-rival"
  local scenario = ScenarioFactory.fromTrainer({
    id = launchId .. "-scenario",
    trainers = {
      {
        id = trainerId,
        class = 2,
        party = { foeRecord("EEVEE", 0x5EED0001), foeRecord("EEVEE", 0x5EED0002) },
        partyLevels = { 4, 4 },
        prizeMoney = { trainerClass = 2, classRate = 4 },
        aiPasses = {},
        doubleBattle = true,
      },
    },
  }, { party = party, bag = bag, player = { trainerId = 99, trainerName = "MINT", language = "french" } })
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
    itemCatalog = ItemFixture.makeCatalog(),
    assets = rig.assets,
    text = rig.text,
    windows = rig.windows,
    audio = rig.audio,
  })
  rig.screen = screen
  rig.port = screen:presentationPort()
  holder.battle = BattleRuntime.new({
    request = { id = launchId, kind = "trainer", payload = { trainer = trainerId } },
    scenario = scenario,
    party = party,
    bag = bag,
    presentation = rig.port,
    seed = 0x12345678,
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
---@param event table<string, unknown> semantic input under test driving
local function press(rig, event)
  rig.screen:input({ event })
  rig.pump(1)
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

-- Both leads strike different foes through one shared reply: the first
-- staged strike submits nothing, the completed pair submits once with
-- two distinct actor tokens and two distinct foe positions in request
-- order, and the kernel accepts the batch so the turn progresses.
function T.two_leads_answer_different_foes_in_one_reply()
  local rig = openDoubleRig({ launchId = "launch-double-strikes", layout = "paired" })
  driveToMode(rig, "command")
  local request = openScreenRequest(rig)
  Assert.equal(#request.actors, 2, "the doubled turn addresses both leads together")
  local options = optionsFor(rig, request)
  Assert.equal(#options.actors, 2, "the projection addresses both leads together")
  -- The first lead opens target selection with both projected foe
  -- positions; choosing the second foe stages only the first fragment.
  press(rig, { type = "confirm" })
  Assert.equal(rig.screen:status().mode, "moves", "confirming Fight opens move selection")
  press(rig, { type = "confirm" })
  Assert.equal(rig.screen:status().mode, "target", "a move with two foes opens target selection")
  local targets = rig.screen:view().targets
  Assert.notNil(targets, "the target list stays observable")
  Assert.equal(#targets, 2, "both projected foe positions stay selectable")
  local acting = rig.screen:view().actor
  Assert.notNil(acting, "the acting lead stays observable")
  Assert.equal(acting.index, 1, "the first lead decides first")
  press(rig, { type = "navigate", direction = "down" })
  press(rig, { type = "confirm" })
  Assert.equal(#rig.submits, 0, "the first staged strike submits nothing")
  acting = rig.screen:view().actor
  Assert.notNil(acting, "the acting lead stays observable after staging")
  Assert.equal(acting.index, 2, "staging advances to the second lead")
  Assert.equal(#rig.screen:view().staged, 1, "the first fragment stays staged")
  -- The second lead strikes the other foe position, and the completed
  -- pair submits once with both actor tokens in request order.
  press(rig, { type = "confirm" })
  Assert.equal(rig.screen:status().mode, "moves", "the second lead opens its own move selection")
  press(rig, { type = "confirm" })
  Assert.equal(rig.screen:status().mode, "target", "the second strike opens target selection")
  press(rig, { type = "confirm" })
  Assert.equal(#rig.submits, 1, "the completed pair submits exactly once")
  local sealed = assert(rig.submits[1], "the paired reply is recorded")
  Assert.equal(sealed.requestId, request.requestId, "the reply answers the open request")
  Assert.equal(sealed.epoch, request.epoch, "the reply carries the open epoch")
  Assert.equal(sealed.controller, request.controller, "the reply carries the open controller")
  Assert.equal(#sealed.choices, 2, "the reply answers every addressed lead exactly once")
  local first = assert(sealed.choices[1], "the reply names its first lead")
  local second = assert(sealed.choices[2], "the reply names its second lead")
  Assert.equal(first.actor.combatant, request.actors[1].combatant, "the first fragment answers the first lead")
  Assert.equal(second.actor.combatant, request.actors[2].combatant, "the second fragment answers the second lead")
  Assert.isTrue(first.actor.combatant ~= second.actor.combatant, "the paired reply fields two distinct leads")
  local firstTarget = first.payload.target
  local secondTarget = second.payload.target
  Assert.equal(firstTarget.kind, "position", "the first strike names its foe position")
  Assert.equal(secondTarget.kind, "position", "the second strike names its foe position")
  Assert.isTrue(firstTarget.position ~= secondTarget.position, "the two strikes answer different foe positions")
  Assert.equal(
    rig.screen:status().mode,
    "awaiting_resolution",
    "the kernel accepts the paired batch and the turn progresses"
  )
  rig.screen:dispose()
  rig.battle:dispose()
end

---@param rig table live screen rig under test driving, resting on the open bag child
local function walkToMedicineFirstCell(rig)
  press(rig, { type = "navigate", direction = "up" })
  press(rig, { type = "navigate", direction = "right" })
  press(rig, { type = "navigate", direction = "down" })
end

---@param rig table live screen rig under test driving
---@param id string child row identity under lookup
---@return table? the detached child row, nil when absent
local function childRow(rig, id)
  local snapshot = rig.screen:_snapshot()
  local child = snapshot.childView
  if type(child) ~= "table" or type(child.rows) ~= "table" then
    return nil
  end
  for _, row in ipairs(child.rows) do
    if type(row) == "table" and row.id == id then
      return row
    end
  end
  return nil
end

-- Picks focused enabled child rows until the child closes: focus moves
-- across ineligible rows, Back steps away from the dismiss control, and
-- every confirmation seals at most one staged fragment.
---@param rig table live screen rig under test driving
local function chooseEnabledChildRow(rig)
  for _ = 1, 16 do
    local snapshot = rig.screen:_snapshot()
    if snapshot.mode ~= "child" then
      return
    end
    local child = snapshot.childView
    Assert.notNil(child, "the child stays observable")
    local focus = child.focusId
    local focused = nil
    for _, row in ipairs(child.rows or {}) do
      if type(row) == "table" and row.id == focus then
        focused = row
      end
    end
    if focused ~= nil and focused.enabled == true then
      press(rig, { type = "confirm" })
    elseif focus == "back" then
      press(rig, { type = "navigate", direction = "up" })
    else
      press(rig, { type = "navigate", direction = "down" })
    end
  end
end

---@param rig table live screen rig under test driving
local function openBagFromCommand(rig)
  press(rig, { type = "navigate", direction = "down" })
  press(rig, { type = "navigate", direction = "left" })
  press(rig, { type = "confirm" })
  Assert.equal(rig.screen:status().mode, "child", "the Bag command opens the bag child")
end

---@param rig table live screen rig under test driving
local function openPartyFromCommand(rig)
  press(rig, { type = "navigate", direction = "down" })
  press(rig, { type = "navigate", direction = "right" })
  press(rig, { type = "confirm" })
  local status = rig.screen:status()
  local snapshot = rig.screen:_snapshot()
  Assert.equal(
    status.mode,
    "child",
    "the Pokemon command opens the party child (mode="
      .. tostring(status.mode)
      .. " selection="
      .. tostring(snapshot.selection)
      .. " notice="
      .. tostring(snapshot.message)
      .. " actor="
      .. tostring(snapshot.actor and snapshot.actor.index)
      .. ")"
  )
end

---@param rig table live screen rig under test driving
local function cancelChildToCommand(rig)
  for _ = 1, 3 do
    if rig.screen:status().mode == "command" then
      return
    end
    press(rig, { type = "cancel" })
  end
  Assert.equal(rig.screen:status().mode, "command", "cancelling the child returns to command")
end

-- One stocked serving and one reserve exchange share a single reply:
-- the staged serving spends no stock, the staged reserve stays unique
-- across leads, stepping back keeps the staged choices editable, and the kernel
-- accepts the completed pair exactly once.
function T.one_serving_and_one_exchange_share_a_single_reply()
  local rig = openDoubleRig({ launchId = "launch-double-serving", layout = "paired", wounded = true })
  driveToMode(rig, "command")
  local request = openScreenRequest(rig)
  Assert.equal(#request.actors, 2, "the doubled turn addresses both leads together")
  -- The first lead opens the bag with the single serving selectable,
  -- then stages it: nothing reaches the kernel and no stock moves.
  openBagFromCommand(rig)
  walkToMedicineFirstCell(rig)
  local servingRow = nil
  for _, row in ipairs((rig.screen:_snapshot().childView or {}).rows or {}) do
    if type(row) == "table" and row.enabled == true and row.empty ~= true then
      Assert.isNil(servingRow, "the single serving occupies one selectable row")
      servingRow = row
    end
  end
  Assert.notNil(servingRow, "the stocked serving stays selectable")
  local servingId = servingRow.id --[[@as string]]
  chooseEnabledChildRow(rig)
  Assert.equal(rig.screen:status().mode, "command", "staging the serving returns for the second lead")
  Assert.equal(#rig.submits, 0, "the staged serving submits nothing")
  Assert.equal(rig.bag:quantity("POTION"), 1, "staging the serving spends no stock")
  local staged = rig.screen:view().staged
  Assert.notNil(staged, "the staged choices stay observable")
  Assert.equal(#staged, 1, "the first fragment stays staged")
  Assert.equal(staged[1].kind, "item", "the staged fragment serves the stocked item")
  Assert.equal(rig.screen:view().actor.index, 2, "staging advances to the second lead")
  -- The second lead finds the same serving unavailable while every
  -- other choice stays open; leaving the bag spends no turn.
  openBagFromCommand(rig)
  walkToMedicineFirstCell(rig)
  local masked = childRow(rig, servingId)
  Assert.notNil(masked, "the serving row stays listed")
  Assert.isFalse(masked.enabled == true, "the already staged serving stays unavailable")
  cancelChildToCommand(rig)
  Assert.equal(#rig.submits, 0, "leaving the bag submits nothing")
  Assert.equal(rig.screen:view().actor.index, 2, "the second lead still owes its decision")
  -- Stepping back returns to the first lead with its staged serving
  -- intact; replacing it with a reserve exchange keeps the request.
  press(rig, { type = "cancel" })
  Assert.equal(rig.screen:view().actor.index, 1, "stepping back returns to the first lead")
  staged = rig.screen:view().staged
  Assert.equal(#staged, 1, "the staged serving survives the step back")
  Assert.equal(staged[1].kind, "item", "the surviving staged choice keeps its serving")
  openPartyFromCommand(rig)
  local bench = childRow(rig, "party:2")
  Assert.notNil(bench, "the benched reserve stays listed")
  Assert.isTrue(bench.enabled == true, "the benched reserve stays selectable")
  chooseEnabledChildRow(rig)
  Assert.equal(rig.screen:status().mode, "command", "staging the exchange returns for the second lead")
  Assert.equal(#rig.submits, 0, "the staged exchange submits nothing")
  staged = rig.screen:view().staged
  Assert.equal(#staged, 1, "the replaced fragment stays staged")
  Assert.equal(staged[1].kind, "switch", "the first lead now exchanges")
  -- The second lead finds the staged reserve unavailable, then strikes:
  -- the completed pair submits once and the kernel accepts it.
  openPartyFromCommand(rig)
  bench = childRow(rig, "party:2")
  Assert.notNil(bench, "the benched reserve stays listed")
  Assert.isFalse(bench.enabled == true, "the already staged reserve stays unavailable")
  cancelChildToCommand(rig)
  Assert.equal(#rig.submits, 0, "leaving the party submits nothing")
  press(rig, { type = "navigate", direction = "up" })
  press(rig, { type = "confirm" })
  press(rig, { type = "confirm" })
  Assert.equal(rig.screen:status().mode, "target", "the second strike opens target selection")
  press(rig, { type = "confirm" })
  Assert.equal(#rig.submits, 1, "the completed exchange and strike submit exactly once")
  local sealed = assert(rig.submits[1], "the mixed reply is recorded")
  Assert.equal(sealed.requestId, request.requestId, "the reply answers the open request")
  Assert.equal(#sealed.choices, 2, "the reply answers every addressed lead exactly once")
  Assert.equal(sealed.choices[1].kind, "switch", "the first lead exchanges")
  Assert.equal(sealed.choices[2].kind, "attack", "the second lead strikes")
  Assert.equal(sealed.choices[1].actor.combatant, request.actors[1].combatant, "the exchange answers the first lead")
  Assert.equal(sealed.choices[2].actor.combatant, request.actors[2].combatant, "the strike answers the second lead")
  Assert.equal(
    rig.screen:status().mode,
    "awaiting_resolution",
    "the kernel accepts the mixed batch and the turn progresses"
  )
  rig.screen:dispose()
  rig.battle:dispose()
end

-- Picks one enabled child row and stops once the acting entry advances
-- or the child closes, so a forced picker never stages two entries.
---@param rig table live screen rig under test driving
local function stageOneChildChoice(rig)
  local before = rig.screen:view().actor
  local startIndex = before ~= nil and before.index or nil
  for _ = 1, 16 do
    local snapshot = rig.screen:_snapshot()
    if snapshot.mode ~= "child" then
      return
    end
    local now = snapshot.actor
    if startIndex ~= nil and now ~= nil and now.index ~= startIndex then
      return
    end
    local child = snapshot.childView
    Assert.notNil(child, "the child stays observable")
    local focus = child.focusId
    local focused = nil
    for _, row in ipairs(child.rows or {}) do
      if type(row) == "table" and row.id == focus then
        focused = row
      end
    end
    if focused ~= nil and focused.enabled == true then
      press(rig, { type = "confirm" })
    elseif focus == "back" then
      press(rig, { type = "navigate", direction = "up" })
    else
      press(rig, { type = "navigate", direction = "down" })
    end
  end
  error("the child never staged its choice", 0)
end

-- Two fainted leads are replaced without any partial publication: the
-- first staged replacement submits nothing, stepping back keeps the
-- staged choice editable, a stale pointer after a resize seals nothing,
-- and the completed pair submits once with two unique reserves while
-- the first picker refuses cancellation.
function T.two_fainted_leads_are_replaced_without_partial_submit()
  local BattleScreenState = require(STATE_MODULE)
  local Model = require(MODEL_MODULE)
  local BattleProtocol = require("libs.battle.src.BattleProtocol")
  local launchId = "launch-double-replacement"
  local rig = {
    submits = {},
    measurement = measurementFor("compact"),
    layout = "compact",
    text = { draws = {} },
    windows = { calls = {} },
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
  function rig.audio.play(name)
    rig.audio.plays[#rig.audio.plays + 1] = name
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
      rig.assets.images[key] = { handle = key }
    end
    return rig.assets.images[key]
  end
  function rig.assets.release(key)
    rig.assets.released[key] = (rig.assets.released[key] or 0) + 1
  end
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
      local ok, err = pcall(BattleProtocol.validateReply, reply, "action")
      Assert.isTrue(ok, "the paired reply validates through the protocol: " .. tostring(err))
      rig.submits[#rig.submits + 1] = reply
      return true
    end,
    measureDisplay = function()
      return rig.measurement
    end,
    itemCatalog = ItemFixture.makeCatalog(),
    assets = rig.assets,
    text = rig.text,
    windows = rig.windows,
    audio = rig.audio,
  })
  rig.screen = screen
  rig.port = screen:presentationPort()
  function rig.pump(ticks)
    for _ = 1, ticks or 1 do
      rig.screen:updateFixed(TICK)
    end
  end
  local function switchChoice(combatant, activation, replacement)
    local choice = {
      actor = { combatant = combatant, activation = activation },
      kind = "switch",
      payload = { replacement = replacement },
    }
    BattleProtocol.validateChoice(choice, "action")
    return {
      id = "switch:" .. tostring(replacement),
      role = "switch",
      display = { combatant = replacement },
      enabled = true,
      choice = choice,
    }
  end
  local actors = {
    {
      combatant = 1,
      activation = 7,
      kind = "replacement",
      choices = { switchChoice(1, 7, 3), switchChoice(1, 7, 4) },
    },
    {
      combatant = 2,
      activation = 8,
      kind = "replacement",
      choices = { switchChoice(2, 8, 3), switchChoice(2, 8, 4) },
    },
  }
  local decision = {
    requestId = 7101,
    epoch = 1,
    controller = "player",
    kind = "action",
    actors = actors,
  }
  decision.options = {
    requestId = 7101,
    epoch = 1,
    controller = "player",
    kind = "action",
    actors = actors,
  }
  local function ownRecord(combatant, hp)
    return {
      combatant = combatant,
      participant = 1,
      side = 1,
      controller = "player",
      active = true,
      hp = hp,
      maxHp = 20,
      species = "EEVEE",
      form = 0,
      name = "MON" .. tostring(combatant),
      level = 8,
      selector = "back",
      moves = { { move = "TACKLE", name = "Tackle", pp = 35, maxPp = 35 } },
    }
  end
  local foeRecordEntry = {
    combatant = 5,
    participant = 2,
    side = 2,
    controller = "wild",
    active = true,
    hp = 20,
    maxHp = 20,
    species = "EEVEE",
    form = 0,
    name = "FOE",
    level = 8,
    selector = "front",
  }
  local function partyRecord(combatant, slot, hp)
    return {
      combatant = combatant,
      slot = slot,
      species = "EEVEE",
      form = 0,
      name = "MON" .. tostring(combatant),
      level = 8,
      hp = hp,
      maxHp = 20,
      heldItem = "NONE",
      moves = { { move = "TACKLE", pp = 35 } },
    }
  end
  rig.port.present({
    launchId = launchId,
    packetId = 4242,
    events = {},
    before = {
      own = { ownRecord(1, 0), ownRecord(2, 0), ownRecord(3, 20), ownRecord(4, 20) },
      foes = { foeRecordEntry },
    },
    after = {
      own = { ownRecord(1, 0), ownRecord(2, 0), ownRecord(3, 20), ownRecord(4, 20) },
      foes = { foeRecordEntry },
    },
    request = decision,
    party = { partyRecord(1, 0, 0), partyRecord(2, 1, 0), partyRecord(3, 2, 20), partyRecord(4, 3, 20) },
    inventory = {},
    result = nil,
  })
  for _ = 1, 600 do
    rig.pump(1)
    local status = rig.screen:status()
    if status.mode == "failed" then
      error("the replacement screen failed while opening: " .. tostring(status.error), 0)
    end
    if status.mode == "child" and status.request ~= nil and status.request.requestId == 7101 then
      break
    end
  end
  local request = openScreenRequest(rig)
  Assert.equal(#request.actors, 2, "the replacement addresses both fainted leads together")
  Assert.equal(rig.screen:view().actor.index, 1, "the first lead decides first")
  -- The first picker cannot dismiss the forced request.
  press(rig, { type = "cancel" })
  Assert.equal(rig.screen:status().mode, "child", "cancelling the forced picker keeps the request")
  Assert.equal(#rig.submits, 0, "the refused cancel submits nothing")
  -- Staging the first replacement opens the second picker with nothing
  -- submitted.
  stageOneChildChoice(rig)
  Assert.equal(#rig.submits, 0, "the first staged replacement submits nothing")
  Assert.equal(rig.screen:status().mode, "child", "the second picker opens for the second lead")
  Assert.equal(rig.screen:view().actor.index, 2, "staging advances to the second lead")
  Assert.equal(#rig.screen:view().staged, 1, "the first fragment stays staged")
  -- A resize mid-choice drops the held pointer without discarding the
  -- staged choices, and the stale release seals nothing.
  local focus = (rig.screen:_snapshot().childView or {}).focusId
  Assert.isTrue(type(focus) == "string", "the second picker holds its focus")
  local slot = tonumber(tostring(focus):match("^party:(%d+)$") or "")
  Assert.notNil(slot, "the focused row addresses its roster slot")
  local point = { x = 128, y = 32 + slot * 20 + 10 }
  rig.screen:input({ { type = "pointer_down", pointerId = "touch:stale", x = point.x, y = point.y } })
  rig.pump(1)
  Assert.notNil(rig.screen:_snapshot().armed, "the press arms its control")
  rig.measurement = {
    width = 256,
    height = 192,
    topology = rig.measurement.topology,
    pixelRatio = 1,
    signature = "battle-double-batch-test:compact:resized",
  }
  rig.pump(1)
  Assert.isNil(rig.screen:_snapshot().armed, "the resize drops the held pointer")
  rig.screen:input({ { type = "pointer_up", pointerId = "touch:stale", x = point.x, y = point.y } })
  rig.pump(1)
  Assert.equal(#rig.submits, 0, "the stale release seals nothing")
  Assert.equal(#rig.screen:view().staged, 1, "the staged choices survive the resize")
  -- Stepping back returns to the first lead with its staged choice
  -- intact; replacing it keeps the request and still submits nothing.
  press(rig, { type = "cancel" })
  Assert.equal(rig.screen:view().actor.index, 1, "stepping back returns to the first lead")
  Assert.equal(#rig.screen:view().staged, 1, "the staged replacement survives the step back")
  Assert.equal(#rig.submits, 0, "stepping back submits nothing")
  press(rig, { type = "navigate", direction = "down" })
  stageOneChildChoice(rig)
  Assert.equal(#rig.submits, 0, "replacing the first choice submits nothing")
  Assert.equal(rig.screen:view().actor.index, 2, "the second picker reopens for the second lead")
  -- The completed pair submits once with two unique reserves in
  -- request order through the validated protocol shape.
  stageOneChildChoice(rig)
  Assert.equal(#rig.submits, 1, "the completed pair submits exactly once")
  local sealed = assert(rig.submits[1], "the paired reply is recorded")
  Assert.equal(sealed.requestId, 7101, "the reply answers the open request")
  Assert.equal(#sealed.choices, 2, "the reply answers every addressed lead exactly once")
  local first = assert(sealed.choices[1], "the reply names its first lead")
  local second = assert(sealed.choices[2], "the reply names its second lead")
  Assert.equal(first.actor.combatant, 1, "the first fragment answers the first lead")
  Assert.equal(first.actor.activation, 7, "the first fragment keeps its entry token")
  Assert.equal(second.actor.combatant, 2, "the second fragment answers the second lead")
  Assert.equal(second.actor.activation, 8, "the second fragment keeps its entry token")
  Assert.equal(first.kind, "switch", "the first lead exchanges")
  Assert.equal(second.kind, "switch", "the second lead exchanges")
  Assert.isTrue(first.payload.replacement ~= second.payload.replacement, "the paired reply fields two unique reserves")
  Assert.equal(rig.screen:status().mode, "awaiting_resolution", "the accepted batch waits for resolution")
  rig.screen:dispose()
end

---@param rig table live screen rig under test driving
---@param request table open request under projection
---@param position integer 1-based addressed actor position under projection
---@return table the enabled kernel struggle option for the addressed lead
local function struggleOptionForActor(rig, request, position)
  local options = optionsFor(rig, request)
  local addressed = assert(request.actors[position], "the doubled turn addresses its lead")
  for _, entry in ipairs(options.actors) do
    if type(entry) == "table" and entry.combatant == addressed.combatant and entry.activation == addressed.activation then
      for _, choice in ipairs(entry.choices) do
        if type(choice) == "table" and choice.id == "move:struggle" then
          return choice --[[@as table<string, unknown>]]
        end
      end
    end
  end
  error("the addressed lead projects no struggle option", 0)
end

-- An exhausted doubled lead reaches its projected struggle through
-- Fight: the two-foe projection opens the target picker directly,
-- backing out returns to the Fight command instead of the spent move
-- list, the other foe seals the exact candidate fragment, and the
-- finished pair answers with one atomic reply through key and pointer
-- edges alike.
function T.exhausted_doubled_lead_reaches_struggle_targets_and_batches_atomically()
  local spentLead = { { move = "TACKLE", pp = 0, ppUps = 0 } }
  local rig = openDoubleRig({ launchId = "launch-double-struggle-keys", layout = "paired", firstLeadMoves = spentLead })
  driveToMode(rig, "command")
  local request = openScreenRequest(rig)
  Assert.equal(#request.actors, 2, "the doubled turn addresses both leads together")
  local struggle = struggleOptionForActor(rig, request, 1)
  Assert.isTrue(struggle.enabled == true, "the exhausted lead keeps its projected struggle")
  local variants = assert(struggle.targets, "the two-foe struggle projects its target picker")
  Assert.equal(#variants, 2, "both projected foe positions stay selectable")
  local otherFoe = assert(variants[2], "the other foe stays projected")
  Assert.equal(otherFoe.id, "target:1", "the other foe keeps its projected identity")
  press(rig, { type = "confirm" })
  Assert.equal(rig.screen:status().mode, "target", "Fight opens the projected targets without the spent move list")
  local targets = assert(rig.screen:view().targets, "the target list stays observable")
  Assert.equal(#targets, 2, "both projected foe positions stay listed")
  press(rig, { type = "cancel" })
  Assert.equal(rig.screen:status().mode, "command", "backing out of the struggle picker returns to command")
  Assert.equal(rig.screen:view().selection, "fight", "the cancelled picker refocuses Fight")
  Assert.equal(rig.screen:view().actor.index, 1, "the cancelled picker keeps the acting lead")
  press(rig, { type = "confirm" })
  Assert.equal(rig.screen:status().mode, "target", "Fight reopens the projected targets")
  press(rig, { type = "navigate", direction = "down" })
  Assert.equal(rig.screen:view().selection, "target:1", "the picker reaches the other foe")
  press(rig, { type = "confirm" })
  Assert.equal(#rig.submits, 0, "the first staged struggle submits nothing")
  Assert.equal(rig.screen:view().actor.index, 2, "staging advances to the second lead")
  press(rig, { type = "confirm" })
  Assert.equal(rig.screen:status().mode, "moves", "the second lead opens its own move selection")
  press(rig, { type = "confirm" })
  Assert.equal(rig.screen:status().mode, "target", "the second strike opens target selection")
  press(rig, { type = "confirm" })
  Assert.equal(#rig.submits, 1, "the completed pair submits exactly once")
  local sealed = assert(rig.submits[1], "the paired reply is recorded")
  Assert.equal(#sealed.choices, 2, "the reply answers every addressed lead exactly once")
  Assert.deepEqual(sealed.choices[1], otherFoe.choice, "the first fragment keeps the other foe candidate")
  Assert.equal(
    sealed.choices[2].actor.combatant,
    request.actors[2].combatant,
    "the second fragment answers the second lead"
  )
  Assert.equal(
    rig.screen:status().mode,
    "awaiting_resolution",
    "the kernel accepts the paired batch and the turn progresses"
  )
  rig.screen:dispose()
  rig.battle:dispose()
  local touch = openDoubleRig({
    launchId = "launch-double-struggle-touch",
    layout = "paired",
    firstLeadMoves = { { move = "TACKLE", pp = 0, ppUps = 0 } },
  })
  driveToMode(touch, "command")
  local touchRequest = openScreenRequest(touch)
  local touchStruggle = struggleOptionForActor(touch, touchRequest, 1)
  Assert.isTrue(touchStruggle.enabled == true, "the touch run keeps its projected struggle")
  Assert.equal(#touchStruggle.targets, 2, "the touch run projects both foe positions")
  local function tap(id, x, y)
    touch.screen:input({ { type = "pointer_down", pointerId = id, x = x, y = y } })
    touch.screen:input({ { type = "pointer_up", pointerId = id, x = x, y = y } })
    touch.pump(1)
  end
  tap("touch:fight", 128, 276)
  Assert.equal(touch.screen:status().mode, "target", "tapping Fight opens the projected targets")
  tap("touch:cancel", 128, 364)
  Assert.equal(touch.screen:status().mode, "command", "tapping Back returns to command")
  Assert.equal(touch.screen:view().selection, "fight", "the tapped Back refocuses Fight")
  tap("touch:fight", 128, 276)
  Assert.equal(touch.screen:status().mode, "target", "tapping Fight reopens the projected targets")
  tap("touch:other-foe", 196, 224)
  Assert.equal(#touch.submits, 0, "the tapped struggle stages without submitting")
  Assert.equal(touch.screen:view().actor.index, 2, "the tapped pick advances to the second lead")
  press(touch, { type = "confirm" })
  press(touch, { type = "confirm" })
  press(touch, { type = "confirm" })
  Assert.equal(#touch.submits, 1, "the touched pair submits exactly once")
  local touchSealed = assert(touch.submits[1], "the touched reply is recorded")
  Assert.deepEqual(touchSealed.choices, sealed.choices, "touch and key edges seal identical candidate fragments")
  Assert.equal(touch.screen:status().mode, "awaiting_resolution", "the touched batch waits for resolution")
  touch.screen:dispose()
  touch.battle:dispose()
end

---@param layout string "paired" or "compact" surface arrangement under test driving
---@param launchId string owning launch identity under test driving
---@param requestId integer synthetic request identity under test driving
---@return table live screen-only rig with own-side and foe-side target projections
local function openTargetLabelRig(layout, launchId, requestId)
  local BattleScreenState = require(STATE_MODULE)
  local Model = require(MODEL_MODULE)
  local BattleProtocol = require("libs.battle.src.BattleProtocol")
  local rig = {
    submits = {},
    measurement = measurementFor(layout),
    layout = layout,
    text = { draws = {} },
    windows = { calls = {} },
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
  function rig.audio.play(name)
    rig.audio.plays[#rig.audio.plays + 1] = name
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
      rig.assets.images[key] = { handle = key }
    end
    return rig.assets.images[key]
  end
  function rig.assets.release(key)
    rig.assets.released[key] = (rig.assets.released[key] or 0) + 1
  end
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
      local ok, err = pcall(BattleProtocol.validateReply, reply, "action")
      Assert.isTrue(ok, "the paired reply validates through the protocol: " .. tostring(err))
      rig.submits[#rig.submits + 1] = reply
      return true
    end,
    measureDisplay = function()
      return rig.measurement
    end,
    assets = rig.assets,
    text = rig.text,
    windows = rig.windows,
    audio = rig.audio,
  })
  rig.screen = screen
  rig.port = screen:presentationPort()
  function rig.pump(ticks)
    for _ = 1, ticks or 1 do
      rig.screen:updateFixed(TICK)
    end
  end
  ---@param combatant integer striking combatant under fragment creation
  ---@param position integer struck position under fragment creation
  ---@return table validated native attack fragment under fragment creation
  local function attackChoice(combatant, position)
    local choice = {
      actor = { combatant = combatant, activation = 1 },
      kind = "attack",
      payload = { moveSlot = 0, target = { kind = "position", position = position } },
    }
    BattleProtocol.validateChoice(choice, "action")
    return choice
  end
  local ownSideTargets = {
    { id = "target:0", position = 1, combatant = 1, enabled = true, choice = attackChoice(1, 1) },
    { id = "target:1", position = 2, combatant = 2, enabled = true, choice = attackChoice(1, 2) },
    { id = "target:2", position = 2, combatant = 2, enabled = false, reason = "disallowed", choice = attackChoice(1, 2) },
  }
  local foeSideTargets = {
    { id = "target:0", position = 3, combatant = 5, enabled = true, choice = attackChoice(2, 3) },
    { id = "target:1", position = 4, combatant = 6, enabled = true, choice = attackChoice(2, 4) },
  }
  rig.projected = { partner = ownSideTargets[2].choice, foe = foeSideTargets[1].choice }
  local actors = {
    {
      combatant = 1,
      activation = 1,
      kind = "action",
      choices = {
        {
          id = "move:0",
          role = "move",
          display = { move = "TACKLE", name = "Tackle", pp = 35, maxPp = 35, type = "NORMAL" },
          enabled = true,
          choice = attackChoice(1, 1),
          targets = ownSideTargets,
        },
      },
    },
    {
      combatant = 2,
      activation = 1,
      kind = "action",
      choices = {
        {
          id = "move:0",
          role = "move",
          display = { move = "TACKLE", name = "Tackle", pp = 35, maxPp = 35, type = "NORMAL" },
          enabled = true,
          choice = attackChoice(2, 3),
          targets = foeSideTargets,
        },
      },
    },
  }
  local decision = {
    requestId = requestId,
    epoch = 1,
    controller = "player",
    kind = "action",
    actors = actors,
  }
  decision.options = {
    requestId = requestId,
    epoch = 1,
    controller = "player",
    kind = "action",
    actors = actors,
  }
  local function ownRecord(combatant, name)
    return {
      combatant = combatant,
      participant = 1,
      side = 1,
      controller = "player",
      active = true,
      hp = 20,
      maxHp = 20,
      species = "EEVEE",
      form = 0,
      name = name,
      level = 8,
      selector = "back",
      moves = { { move = "TACKLE", name = "Tackle", pp = 35, maxPp = 35 } },
    }
  end
  local foeRecordEntry = {
    combatant = 5,
    participant = 2,
    side = 2,
    controller = "wild",
    active = true,
    hp = 20,
    maxHp = 20,
    species = "EEVEE",
    form = 0,
    name = "FOEONE",
    level = 8,
    selector = "front",
  }
  rig.port.present({
    launchId = launchId,
    packetId = 4242,
    events = {},
    before = { own = { ownRecord(1, "ALPHA"), ownRecord(2, "BRAVO") }, foes = { foeRecordEntry } },
    after = { own = { ownRecord(1, "ALPHA"), ownRecord(2, "BRAVO") }, foes = { foeRecordEntry } },
    request = decision,
    result = nil,
  })
  for _ = 1, 600 do
    rig.pump(1)
    local status = rig.screen:status()
    if status.mode == "failed" then
      error("the target label screen failed while opening: " .. tostring(status.error), 0)
    end
    if status.mode == "command" and status.request ~= nil and status.request.requestId == requestId then
      return rig
    end
  end
  error("the target label screen never reached its command decision", 0)
end

-- Own-side and foe-side target pickers name their projected recipients:
-- the user and the partner keep their displayed names, an unlisted
-- recipient falls back to a neutral label instead of a foe claim, only
-- admitted candidates seal, and both layouts settle the identical
-- candidate fragments through key and pointer edges.
function T.target_pickers_name_projected_recipients_on_both_layouts()
  local rig = openTargetLabelRig("paired", "launch-target-labels-keys", 7201)
  local request = openScreenRequest(rig)
  Assert.equal(#request.actors, 2, "the labelled turn addresses both leads together")
  press(rig, { type = "confirm" })
  Assert.equal(rig.screen:status().mode, "moves", "Fight opens move selection")
  press(rig, { type = "confirm" })
  Assert.equal(rig.screen:status().mode, "target", "the own-side move opens its target picker")
  local targets = assert(rig.screen:view().targets, "the own-side targets stay observable")
  Assert.equal(#targets, 3, "the picker lists every projected candidate")
  Assert.equal(targets[1].name, "ALPHA", "the user keeps its displayed name")
  Assert.equal(targets[2].name, "BRAVO", "the partner keeps its displayed name")
  Assert.isTrue(targets[1].name ~= "Foe" and targets[2].name ~= "Foe", "allied candidates never claim the foe label")
  Assert.isFalse(targets[3].enabled, "the unadmitted candidate stays refused")
  press(rig, { type = "navigate", direction = "down" })
  Assert.equal(rig.screen:view().selection, "target:1", "the picker reaches the partner")
  press(rig, { type = "navigate", direction = "down" })
  Assert.equal(rig.screen:view().selection, "cancel", "navigation skips the unadmitted candidate")
  press(rig, { type = "navigate", direction = "up" })
  press(rig, { type = "confirm" })
  Assert.equal(#rig.submits, 0, "the first staged pick submits nothing")
  Assert.equal(rig.screen:view().actor.index, 2, "staging advances to the second lead")
  press(rig, { type = "confirm" })
  press(rig, { type = "confirm" })
  Assert.equal(rig.screen:status().mode, "target", "the foe-side move opens its target picker")
  local foes = assert(rig.screen:view().targets, "the foe-side targets stay observable")
  Assert.equal(#foes, 2, "both projected foe positions stay listed")
  Assert.equal(foes[1].name, "FOEONE", "the listed foe keeps its displayed name")
  Assert.equal(foes[2].name, "Target", "the unlisted recipient falls back to a neutral label")
  Assert.isTrue(foes[2].name ~= "Foe", "the fallback never claims the foe category")
  press(rig, { type = "confirm" })
  Assert.equal(#rig.submits, 1, "the completed pair submits exactly once")
  local sealed = assert(rig.submits[1], "the labelled reply is recorded")
  Assert.equal(#sealed.choices, 2, "the reply answers every addressed lead exactly once")
  Assert.deepEqual(sealed.choices[1], rig.projected.partner, "the first fragment keeps the partner candidate")
  Assert.deepEqual(sealed.choices[2], rig.projected.foe, "the second fragment keeps the foe candidate")
  Assert.equal(rig.screen:status().mode, "awaiting_resolution", "the accepted batch waits for resolution")
  rig.screen:dispose()
  local pointers = {
    {
      layout = "paired",
      launchId = "launch-target-labels-paired",
      requestId = 7202,
      fight = { x = 128, y = 276 },
      move = { x = 64, y = 237 },
      partner = { x = 196, y = 224 },
      foe = { x = 60, y = 308 },
      barred = { x = 196, y = 308 },
    },
    {
      layout = "compact",
      launchId = "launch-target-labels-compact",
      requestId = 7203,
      fight = { x = 152, y = 154 },
      move = { x = 52, y = 142 },
      partner = { x = 128, y = 154 },
      foe = { x = 128, y = 138 },
    },
  }
  for _, touch in ipairs(pointers) do
    local tapRig = openTargetLabelRig(touch.layout, touch.launchId, touch.requestId)
    openScreenRequest(tapRig)
    local function tap(id, point)
      tapRig.screen:input({ { type = "pointer_down", pointerId = id, x = point.x, y = point.y } })
      tapRig.screen:input({ { type = "pointer_up", pointerId = id, x = point.x, y = point.y } })
      tapRig.pump(1)
    end
    tap("touch:fight", touch.fight)
    Assert.equal(tapRig.screen:status().mode, "moves", "tapping Fight opens move selection (" .. touch.layout .. ")")
    tap("touch:move", touch.move)
    Assert.equal(tapRig.screen:status().mode, "target", "tapping the move opens its picker (" .. touch.layout .. ")")
    if touch.barred ~= nil then
      local before = tapRig.screen:view().selection
      tap("touch:barred", touch.barred)
      Assert.equal(
        tapRig.screen:view().selection,
        before,
        "the unadmitted candidate has no hit region (" .. touch.layout .. ")"
      )
      Assert.equal(#tapRig.submits, 0, "the barred tap seals nothing (" .. touch.layout .. ")")
    end
    tap("touch:partner", touch.partner)
    Assert.equal(#tapRig.submits, 0, "the tapped partner stages without submitting (" .. touch.layout .. ")")
    Assert.equal(
      tapRig.screen:view().actor.index,
      2,
      "the tapped pick advances to the second lead (" .. touch.layout .. ")"
    )
    tap("touch:fight", touch.fight)
    tap("touch:move", touch.move)
    Assert.equal(tapRig.screen:status().mode, "target", "the tapped foe move opens its picker (" .. touch.layout .. ")")
    tap("touch:foe", touch.foe)
    Assert.equal(#tapRig.submits, 1, "the tapped pair submits exactly once (" .. touch.layout .. ")")
    local tapSealed = assert(tapRig.submits[1], "the tapped reply is recorded (" .. touch.layout .. ")")
    Assert.deepEqual(
      tapSealed.choices,
      sealed.choices,
      "both layouts settle identical candidate fragments (" .. touch.layout .. ")"
    )
    tapRig.screen:dispose()
  end
end

return { tests = T }
