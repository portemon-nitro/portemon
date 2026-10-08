-- Native Summary parent round trips through the composed menu flow: party
-- browsing returns to the displayed member, move reordering swaps whole
-- entries with stale rejection, power-point and machine picks commit
-- through real services, and stale revisions rewind without consuming.
-- Real services, real cursor, real generated manifests, and real child
-- applications throughout; stops before GPU rendering like every
-- acceptance path.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local BagCache = require("libs.assets.src.BagCache")
local PartyActions = require("libs.hgss.src.field.PartyActions")
local PartyCache = require("libs.assets.src.PartyCache")

local FLOW_MODULE = "game.hgss.src.field.PokemonMenuFlow"

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = { "field-runtime", "audio-bank:730", "map-data:7", "map:7", "summary:global" },
    tags = { "summary", "party", "bag", "flow" },
  },
  tests = {},
}

local BAG_NEIGHBORS = {
  [0] = { up = 2, down = 2, left = 1, right = 1 },
  [1] = { up = 3, down = 3, left = 0, right = 0 },
  [2] = { up = 0, down = 0, left = 4, right = 3 },
  [3] = { up = 1, down = 1, left = 2, right = 4 },
  [4] = { up = 4, down = 4, left = 3, right = 2 },
}

local function withGame(fn)
  local game = AcceptanceHarness.new():boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = "MAP_BURNED_TOWER_1F",
    save = "fresh",
  })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    fn(game)
    Assert.equal(game:renderAttempts(), 0, "summary acceptance must stop before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

local function requireFlow()
  local ok, flowModule = pcall(require, FLOW_MODULE)
  Assert.isTrue(ok, "the menu flow owns Bag/Party/Summary round trips: " .. tostring(flowModule))
  return assert(flowModule)
end

local function heroGender(game)
  local avatar = assert(game.runtime.avatar, "field runtime owns the player avatar")
  assert(avatar.gender == 0 or avatar.gender == 1, "the hero gender is binary")
  return avatar.gender == 0 and "male" or "female"
end

local function recordingIcons()
  local calls = { prepared = {}, cancels = 0 }
  local function prepare(iconKeys)
    local snapshot = {}
    for index, key in ipairs(iconKeys) do
      snapshot[index] = key
    end
    calls.prepared[#calls.prepared + 1] = snapshot
    return true, nil
  end
  local function cancel()
    calls.cancels = calls.cancels + 1
  end
  return { prepare = prepare, cancel = cancel, calls = calls }
end

local function summaryContext(game)
  local SummaryCache = require("libs.assets.src.SummaryCache")
  local manifest = SummaryCache.loadManifest(assert(game.runtime.cacheFs, "the runtime owns its cache"))
  local performance = assert(manifest.performance, "the summary family carries performance rules")
  local zero = assert(performance.zeroAprijuice, "performance rules carry the zero modifiers")
  local initials = assert(
    manifest.ribbons.initialSpecialDescriptions,
    "ribbon definitions carry the source-initial special descriptions"
  )
  return function()
    local profile = assert(game.runtime.playerData.profile, "the runtime owns the player profile")
    local day = assert(game.runtime.localClock, "the runtime owns its clock"):nowLocal().day
    local count = assert(game.runtime.monService, "the runtime owns the mon service"):partyCount()
    local rows = {}
    for _ = 1, count do
      rows[#rows + 1] =
        { power = zero.power, stamina = zero.stamina, skill = zero.skill, jump = zero.jump, speed = zero.speed }
    end
    local specials = {}
    for slot = 1, 14 do
      local initial = initials[slot]
      if type(initial) == "string" and initial ~= "" then
        specials[slot] = initial
      else
        specials[slot] = "acceptance special-ribbon description " .. slot
      end
    end
    return {
      profile = { trainerId = profile.trainerId, name = profile.name, gender = profile.gender },
      dayOfMonth = day,
      dexMode = "regional",
      performanceEnabled = false,
      aprijuiceBySlot = rows,
      specialRibbonDescriptions = specials,
    }
  end
end

-- Headless summary leases resolve instantly with the validated family:
-- nothing draws (render attempts stay zero), so no portrait realizes.
---@param game table<string, unknown> booted acceptance game
---@return fun(): table<string, unknown> lease factory
local function acquireSummaryLease(game)
  local SummaryCache = require("libs.assets.src.SummaryCache")
  local manifest = SummaryCache.loadManifest(assert(game.runtime.cacheFs, "the runtime owns its cache"))
  return function()
    local lease = {}
    function lease:prepare(demand)
      return { kind = "ready", key = demand.key, assets = { manifest = manifest } }
    end
    function lease:release()
    end
    return lease
  end
end

local function openFlow(game, root)
  local Flow = requireFlow()
  local runtime = game.runtime
  local icons = recordingIcons()
  local mons = assert(runtime.monService, "field runtime owns the live mon service")
  local bag = assert(runtime.bagService, "field runtime owns the live bag service")
  local actions = PartyActions.new({ mons = mons, bag = bag })
  local cacheFs = assert(runtime.cacheFs, "field runtime owns its asset filesystem")
  local mailbox = assert(runtime.mailbox, "field runtime owns the live Mailbox")
  local MailActions = require("libs.hgss.src.field.MailActions")
  local pcManifest = require("libs.assets.src.PcCache").loadManifest(cacheFs)
  return Flow.new({
    root = root,
    mons = mons,
    bag = bag,
    bagCursor = assert(runtime.bagCursor, "field runtime owns the live bag cursor"),
    partyActions = actions,
    mailActions = MailActions.new({ mons = mons, mailbox = mailbox, bag = bag, manifest = pcManifest }),
    mailbox = mailbox,
    pcManifest = pcManifest,
    fieldMoves = {
      check = function(_)
        return { kind = "ok" }
      end,
    },
    assets = {
      bagManifest = BagCache.loadManifest(cacheFs),
      partyManifest = PartyCache.loadManifest(cacheFs),
      summaryManifest = require("libs.assets.src.SummaryCache").loadManifest(cacheFs),
      uiManifest = assert(runtime.uiManifest, "field runtime owns the field-UI manifest"),
      monCatalog = assert(runtime.monCatalog, "field runtime owns the mon catalog"),
      itemCatalog = assert(runtime.itemCatalog, "field runtime owns the item catalog"),
      heroGender = heroGender(game),
    },
    measureDisplay = function()
      return runtime.presentationDisplay
    end,
    prepareIcons = icons.prepare,
    cancelIconPreparation = icons.cancel,
    textPolicy = { interGlyphDelay = 0, glyphBudget = 512, abAcceleration = true },
    summaryContext = summaryContext(game),
    readSummaryNavigation = function()
      return nil
    end,
    acquireSummaryPreparation = acquireSummaryLease(game),
  })
end

local function givePair(game)
  local service = assert(game.runtime.monService, "field runtime owns the live mon service")
  Assert.isTrue(service:giveMon({ species = "CHIKORITA", level = 5 }), "setup gift must enter the party")
  Assert.isTrue(service:giveMon({ species = "TOTODILE", level = 5 }), "setup gift must enter the party")
end

local function flowStatus(flow)
  local status = flow:status()
  Assert.isTrue(status.open, "the flow stays open through the round trip")
  return status
end

local function drive(flow, events)
  local before = flowStatus(flow)
  if #events > 0 and before.child ~= nil and before.child.phase == "opening" then
    local ready = false
    for _ = 1, 18 do
      flow:updateFixed({})
      local current = flow:status()
      if current.child ~= nil and current.child.phase == "interactive" then
        ready = true
        break
      end
    end
    Assert.isTrue(ready, "the Bag reveal settles before driven input")
  end
  flow:updateFixed(events)
  for _ = 1, 6 do
    if flow:status().transition == nil then
      break
    end
    flow:updateFixed({})
  end
  return flowStatus(flow)
end

local function driveUntil(flow, label, maxSteps, predicate)
  for _ = 1, maxSteps do
    local status = flowStatus(flow)
    if predicate(status) then
      return status
    end
    flow:updateFixed({})
  end
  local status = flow:status()
  error(
    "the flow never reaches " .. label .. "; page=" .. tostring(status.page)
      .. "; child state=" .. tostring(status.child and status.child.state),
    0
  )
end

local function liveChild(status)
  return assert(status.child, "the active page carries its child status")
end

-- Fresh party children reveal before accepting input: after any arrival
-- on a party page, wait out the reveal plus its handover/settling ticks
-- so driven input acts. Bag pages return immediately.
local function settleParty(flow)
  local status = flowStatus(flow)
  if type(status.page) ~= "string" or status.page:sub(1, 5) ~= "party" then
    return status
  end
  status = driveUntil(flow, "the party reveal", 30, function(current)
    local child = current.child
    return child ~= nil and child.phase == "interactive"
  end)
  drive(flow, {})
  return drive(flow, {})
end

-- The Summary entry gate discards pre-active edges, so no navigation
-- drives at its controller until the wrapper turns active.
local function settleSummary(flow)
  return driveUntil(flow, "the active summary child", 30, function(current)
    local child = current.child
    return (current.page == "summary" or current.page == "move_pick") and child ~= nil and child.wrapperPhase == "active"
  end)
end

-- Controller ticks with no flow transition pending: child-native phases
-- (move detail opening, entry fades) advance one step per empty batch.
local function settleChild(flow, ticks)
  for _ = 1, ticks do
    flow:updateFixed({})
  end
  return flowStatus(flow)
end

local function summaryPhase(flow)
  return assert(liveChild(flowStatus(flow)).phase, "the summary child reports its native phase")
end

-- Confirming a browsed item parks in the source selection entry before
-- the stable action menu opens: settle the generated transition clock
-- before callers read the action state or its actions.
local function chooseBagAction(flow, id)
  local status = drive(flow, { { type = "confirm" } })
  status = driveUntil(flow, "the stable action menu", 30, function(current)
    return current.child ~= nil and current.child.state == "action_menu"
  end)
  local child = liveChild(status)
  Assert.equal(child.state, "action_menu", "confirming an item must open the action menu")
  local target = nil
  for _, action in ipairs(assert(child.actions, "the action menu lists its actions")) do
    if action.id == id then
      target = assert(action.slot, "menu actions carry their physical slot")
    end
  end
  Assert.notNil(target, "the action menu must offer " .. id)
  for _ = 1, 8 do
    status = flowStatus(flow)
    child = liveChild(status)
    if child.actionNode == target then
      drive(flow, { { type = "confirm" } })
      -- Activation latches behind feedback before the semantic transition
      -- runs, so settle until the menu leaves or the flow changes pages.
      return driveUntil(flow, "the chosen action", 30, function(current)
        return id == "toss" and current.child ~= nil and current.child.state == "toss_quantity"
          or current.page ~= "bag_browse"
      end)
    end
    local node = assert(child.actionNode, "the action menu exposes its node")
    local queue = { { node = node, path = {} } }
    local seen = { [node] = true }
    local path = nil
    local head = 1
    while head <= #queue and path == nil do
      local current = queue[head]
      head = head + 1
      for _, direction in ipairs({ "up", "down", "left", "right" }) do
        local nextNode = BAG_NEIGHBORS[current.node][direction]
        if not seen[nextNode] then
          local nextPath = {}
          for index, step in ipairs(current.path) do
            nextPath[index] = step
          end
          nextPath[#nextPath + 1] = direction
          if nextNode == target then
            path = nextPath
            break
          end
          seen[nextNode] = true
          queue[#queue + 1] = { node = nextNode, path = nextPath }
        end
      end
    end
    local direction = assert(path and path[1], "the action node must be reachable")
    status = drive(flow, { { type = "navigate", direction = direction } })
  end
  error("the action menu never selects " .. id, 0)
end

local function gotoPocket(flow, pocket)
  for _ = 1, 30 do
    local status = flowStatus(flow)
    local child = liveChild(status)
    if child.pocket == pocket and child.focus == "items" then
      return status
    end
    if child.focus == "tabs" then
      if child.tabFocusPocket == pocket then
        status = drive(flow, { { type = "confirm" } })
        status = drive(flow, { { type = "navigate", direction = "down" } })
      else
        status = drive(flow, { { type = "navigate", direction = "right" } })
      end
    else
      status = drive(flow, { { type = "navigate", direction = "up" } })
    end
  end
  error("the bag never reaches pocket " .. pocket, 0)
end

local PARTY_DIRECTIONS = { "right", "down", "left", "up" }

local function choosePartySlot(flow, slot)
  local probe = 1
  for _ = 1, 40 do
    local status = flowStatus(flow)
    local child = liveChild(status)
    if child.cursorNode == slot then
      local before = status.page
      status = drive(flow, { { type = "confirm" } })
      -- Target children arm their press behind a visual cadence before
      -- the single dispatch runs: tick until the flow leaves the page
      -- so callers read the routed state, never the armed press.
      for _ = 1, 12 do
        if status.page ~= before then
          break
        end
        flow:updateFixed({})
        status = flowStatus(flow)
      end
      return drive(flow, {})
    end
    local direction = PARTY_DIRECTIONS[probe]
    probe = probe % #PARTY_DIRECTIONS + 1
    drive(flow, { { type = "navigate", direction = direction } })
  end
  error("the party cursor never reaches slot " .. tostring(slot), 0)
end

local function choosePartyMenu(flow, kind)
  for _ = 1, 40 do
    local status = flowStatus(flow)
    local child = liveChild(status)
    local menu = assert(child.menu, "the party context menu must be open")
    local index = nil
    for position, entry in ipairs(menu) do
      if entry.kind == kind then
        index = position
      end
    end
    Assert.notNil(index, "the party menu must offer " .. kind)
    if child.menuIndex == index then
      -- Menu activation rides the visual press cadence before its single
      -- dispatch: settle the gate so callers read the dispatched submenu
      -- or intent state instead of the armed menu.
      drive(flow, { { type = "confirm" } })
      local dispatched = driveUntil(flow, "the gated menu dispatch", 10, function(current)
        local settled = liveChild(current)
        return settled.menuPress == nil and (settled.menu ~= menu or settled.state ~= "context")
      end)
      if kind == "give" or kind == "summary" then
        local page = kind == "give" and "bag_pick_held" or "summary"
        return driveUntil(flow, "the " .. page .. " page", 30, function(current)
          return current.page == page
        end)
      end
      return dispatched
    end
    local direction = child.menuIndex < index and "down" or "up"
    status = drive(flow, { { type = "navigate", direction = direction } })
  end
  error("the party menu never selects " .. kind, 0)
end

local function openPartySummary(flow, slot)
  local status = driveUntil(flow, "the party browse page", 30, function(current)
    return current.page == "party_browse"
  end)
  status = settleParty(flow)
  status = choosePartySlot(flow, slot)
  status = choosePartyMenu(flow, "summary")
  Assert.equal(status.page, "summary", "choosing Summary must open the summary page")
  return settleSummary(flow)
end

local function teachMoves(game, slot, keys)
  local service = assert(game.runtime.monService, "field runtime owns the live mon service")
  for index, key in ipairs(keys) do
    service:setMove(slot, index - 1, key)
  end
end

local function drainMovePp(game, slot, moveIndex, left)
  local service = assert(game.runtime.monService, "field runtime owns the live mon service")
  local mon = service:partyMon(slot)
  local entry = assert(mon.moves[moveIndex + 1], "the setup move must exist")
  Assert.isTrue(entry.pp > left, "the drained fixture needs headroom above the remainder")
  mon.moves[moveIndex + 1].pp = left
  local revision = service:partyRevision()
  local preparation, reason = service:preparePartyChanges(revision, { { slot = slot, mon = mon } })
  Assert.isNil(reason, "power-point staging must prepare cleanly")
  assert(preparation).publish()
end

-- First cataloged machine whose teaching needs a replacement pick on the
-- full setup moveset: derived from the live catalogs, never pinned, so
-- the picker always exercises the protected/prospective path.
local function findReplacementMachine(game, slot)
  local runtime = game.runtime
  local mons = assert(runtime.monService, "field runtime owns the live mon service")
  local bag = assert(runtime.bagService, "field runtime owns the live bag service")
  local itemCatalog = assert(runtime.itemCatalog, "field runtime owns the item catalog")
  local actions = PartyActions.new({ mons = mons, bag = bag })
  for nativeId = 328, 419 do
    local key = itemCatalog:itemKeyByNativeId(nativeId)
    if type(key) == "string" then
      -- Teaching previews need the disc on hand, so each candidate is
      -- stocked for its read-only preview and taken back unless it is
      -- the replacement pick the scenario keeps.
      Assert.isTrue(bag:add(key, 1), "the machine scan must stock " .. key)
      local decision = actions:preview({
        kind = "teach_move",
        slot = slot,
        partyRevision = mons:partyRevision(),
        bagRevision = bag:revision(),
        item = key,
      })
      if decision.kind == "needs_replacement" then
        return key
      end
      Assert.isTrue(bag:take(key, 1), "the machine scan must return " .. key)
    end
  end
  error("no cataloged machine needs a replacement pick on the setup moveset", 0)
end

local function moveKeyBehind(game, itemKey)
  local runtime = game.runtime
  local definition = assert(runtime.itemCatalog, "field runtime owns the item catalog"):item(itemKey)
  local nativeId = assert(definition.tmhmMoveNativeId, "machines carry their native move identity")
  return assert(runtime.monCatalog, "field runtime owns the mon catalog"):moveKeyByNativeId(nativeId)
end

-- One-based picker rows holding hidden-machine moves on the setup mon,
-- derived from the live catalogs the same selection the production flow
-- protects.
local function hmRows(game, slot)
  local runtime = game.runtime
  local mons = assert(runtime.monService, "field runtime owns the live mon service")
  local monCatalog = assert(runtime.monCatalog, "field runtime owns the mon catalog")
  local hmMoves = assert(runtime.itemCatalog, "field runtime owns the item catalog"):hmMoveNativeIds()
  local rows = {}
  for index, entry in ipairs(assert(mons:partyMon(slot).moves, "stored mons carry their moves")) do
    local nativeId = monCatalog:move(assert(entry.move, "entries name their move")).nativeId
    if hmMoves[nativeId] == true then
      rows[#rows + 1] = index
    end
  end
  return rows
end

function T.tests.summary_return_restores_the_displayed_member_without_mutating()
  withGame(function(game)
    givePair(game)
    local mons = assert(game.runtime.monService, "field runtime owns the live mon service")
    local bag = assert(game.runtime.bagService, "field runtime owns the live bag service")
    local monsBefore = mons:capture()
    local bagBefore = bag:capture()

    local flow = openFlow(game, "party")
    local status = openPartySummary(flow, 0)
    local child = liveChild(status)
    Assert.equal(child.slot, 0, "the summary opens on the requested member")
    Assert.equal(child.group, "info", "the summary opens on its first native group")
    local messageProvider = assert(game.runtime.messageProvider, "field runtime owns generated message banks")
    local sinjohBank, bankError = messageProvider:acquireBank(146)
    Assert.notNil(
      sinjohBank,
      "the Sinjoh stage message bank is available during the summary journey: " .. tostring(bankError)
    )
    messageProvider:releaseBank(146)

    status = drive(flow, { { type = "navigate", direction = "right" } })
    Assert.equal(liveChild(status).group, "skills", "moving right turns to the second group")
    status = drive(flow, { { type = "navigate", direction = "right" } })
    Assert.equal(liveChild(status).group, "performance", "moving right again turns to the third group")
    status = drive(flow, { { type = "navigate", direction = "down" } })
    child = liveChild(status)
    Assert.equal(child.slot, 1, "moving down displays the second mon")
    Assert.equal(child.group, "performance", "changing members keeps the native group")

    status = drive(flow, { { type = "cancel" } })
    status = driveUntil(flow, "the party browse page", 30, function(current)
      return current.page == "party_browse"
    end)
    status = settleParty(flow)
    Assert.equal(liveChild(status).cursorNode, 1, "the party resumes on the displayed mon")
    Assert.isNil(flow:takeResult(), "returning to the root reports no terminal result")
    Assert.deepEqual(mons:capture(), monsBefore, "browsing the summary mutates no mon state")
    Assert.deepEqual(bag:capture(), bagBefore, "browsing the summary touches no bag state")
    flow:dispose()
  end)
end

function T.tests.move_reorder_swaps_whole_entries_and_rejects_stale_gestures()
  withGame(function(game)
    givePair(game)
    teachMoves(game, 0, { "TACKLE", "GROWL" })
    drainMovePp(game, 0, 0, 20)
    local service = assert(game.runtime.monService, "field runtime owns the live mon service")
    local copy = service:partyMon(0)
    copy.moves[2].ppUps = 2
    copy.moves[2].pp = 30
    do
      local preparation = assert(service:preparePartyChanges(service:partyRevision(), { { slot = 0, mon = copy } }))
      preparation.publish()
    end
    local revisionBefore = service:partyRevision()

    local flow = openFlow(game, "party")
    local status = openPartySummary(flow, 0)
    status = drive(flow, { { type = "navigate", direction = "right" } })
    Assert.equal(liveChild(status).group, "skills", "reordering starts from the move rows")
    status = drive(flow, { { type = "confirm" } })
    Assert.equal(summaryPhase(flow), "move_opening", "confirming a move row opens its detail")
    status = settleChild(flow, 3)
    Assert.equal(summaryPhase(flow), "move_detail", "the detail settles after its transition")
    Assert.equal(liveChild(status).moveSlot, 0, "the detail opens on the first occupied row")

    status = drive(flow, { { type = "confirm" } })
    Assert.equal(summaryPhase(flow), "move_reorder", "confirming the detail arms the reorder")
    Assert.notNil(liveChild(status).reorderSource, "the armed reorder names its source row")
    status = drive(flow, { { type = "confirm" } })
    Assert.equal(summaryPhase(flow), "move_detail", "confirming the armed row disarms without swapping")
    Assert.isNil(liveChild(status).reorderSource, "disarming clears the source row")
    Assert.equal(service:partyRevision(), revisionBefore, "disarming publishes no revision")

    status = drive(flow, { { type = "confirm" } })
    Assert.equal(summaryPhase(flow), "move_reorder", "confirming the detail arms again")
    status = drive(flow, { { type = "navigate", direction = "down" } })
    Assert.equal(liveChild(status).moveSlot, 1, "the armed cursor reaches the second row")
    status = drive(flow, { { type = "confirm" } })
    Assert.equal(summaryPhase(flow), "move_detail", "completing the swap returns to the detail")
    Assert.equal(service:partyRevision(), revisionBefore + 1, "one swap publishes one revision")
    local after = service:partyMon(0)
    Assert.equal(after.moves[1].move, "GROWL", "the second entry travels to the front")
    Assert.equal(after.moves[1].pp, 30, "power points follow their move")
    Assert.equal(after.moves[1].ppUps, 2, "power-point ups follow their move")
    Assert.equal(after.moves[2].move, "TACKLE", "the first entry travels to the back")
    Assert.equal(after.moves[2].pp, 20, "the other entry keeps its power points")

    status = drive(flow, { { type = "confirm" } })
    Assert.equal(summaryPhase(flow), "move_reorder", "the swapped detail arms a third gesture")
    service:setMove(0, 0, "SCRATCH")
    local drifted = service:partyRevision()
    status = settleChild(flow, 2)
    local stale = liveChild(status)
    Assert.equal(stale.phase, "move_detail", "revision drift drops the armed gesture back to detail")
    Assert.equal(stale.notice and stale.notice.reason, "stale", "drift names its staleness")
    status = drive(flow, { { type = "navigate", direction = "down" } })
    status = drive(flow, { { type = "confirm" } })
    Assert.equal(service:partyRevision(), drifted, "a drifted gesture publishes nothing")
    Assert.isNil(flow:takeResult(), "a drifted gesture reports no terminal result")

    status = drive(flow, { { type = "cancel" } })
    status = driveUntil(flow, "the browsed root", 12, function(current)
      local child = current.child
      return child ~= nil and child.phase == "root"
    end)
    Assert.equal(summaryPhase(flow), "root", "detail cancellation returns to browsing")
    status = drive(flow, { { type = "cancel" } })
    status = driveUntil(flow, "the party browse page", 30, function(current)
      return current.page == "party_browse"
    end)
    status = settleParty(flow)
    Assert.equal(liveChild(status).cursorNode, 0, "nested cancellation returns to the displayed member")
    Assert.isNil(flow:takeResult(), "returning to the root reports no terminal result")
    flow:dispose()
  end)
end

function T.tests.pp_restore_selects_a_move_and_consumes_once()
  withGame(function(game)
    givePair(game)
    teachMoves(game, 0, { "TACKLE", "GROWL" })
    drainMovePp(game, 0, 0, 20)
    local mons = assert(game.runtime.monService, "field runtime owns the live mon service")
    local bag = assert(game.runtime.bagService, "field runtime owns the live bag service")
    Assert.isTrue(bag:add("ETHER", 1), "the power-point fixture must stock ether")
    local cursor = assert(game.runtime.bagCursor, "field runtime owns the live bag cursor")
    cursor:setPocket("medicine")
    cursor:setPosition("medicine", 0)
    cursor:setScroll("medicine", 0)
    local revisionBefore = mons:partyRevision()

    local flow = openFlow(game, "bag")
    local status = driveUntil(flow, "the bag browse page", 30, function(current)
      return current.page == "bag_browse"
    end)
    Assert.equal(
      liveChild(status).selected and liveChild(status).selected.item,
      "ETHER",
      "the borrowed cursor selects the stocked ether"
    )
    status = chooseBagAction(flow, "use")
    Assert.equal(status.page, "party_item_target", "choosing Use must open the party target page")
    status = settleParty(flow)
    status = choosePartySlot(flow, 0)
    do
      local child = status.child
      Assert.equal(
        status.page,
        "move_pick",
        "a power-point use must open the move picker; got page=" .. tostring(status.page)
          .. "; childState=" .. tostring(child and child.state)
      )
    end
    status = settleSummary(flow)
    Assert.equal(liveChild(status).moveSlot, 0, "the picker opens on the first move row")
    status = drive(flow, { { type = "confirm" } })
    status = driveUntil(flow, "the originating bag page", 30, function(current)
      return current.page == "bag_browse"
    end)
    Assert.isTrue(mons:partyMon(0).moves[1].pp > 20, "the selected move regains power points")
    Assert.equal(bag:quantity("ETHER"), 0, "exactly one ether is consumed")
    Assert.equal(mons:partyRevision(), revisionBefore + 1, "the restore publishes one revision")
    Assert.isNil(flow:takeResult(), "returning to the root reports no terminal result")

    -- A second ether declined at the picker consumes nothing. The first
    -- row is full now, so drain the second row before opening: the
    -- Effects path still detours through the picker.
    Assert.isTrue(bag:add("ETHER", 1), "the cancellation leg restocks ether")
    drainMovePp(game, 0, 1, 10)
    revisionBefore = mons:partyRevision()
    status = chooseBagAction(flow, "use")
    status = settleParty(flow)
    status = choosePartySlot(flow, 0)
    Assert.equal(status.page, "move_pick", "the retry reopens the move picker")
    status = settleSummary(flow)
    status = drive(flow, { { type = "cancel" } })
    status = driveUntil(flow, "the pending target page", 30, function(current)
      return current.page == "party_item_target"
    end)
    Assert.equal(bag:quantity("ETHER"), 1, "declining the picker consumes nothing")
    Assert.equal(mons:partyRevision(), revisionBefore, "declining the picker publishes no revision")
    Assert.isNil(flow:takeResult(), "declining reports no terminal result")
    flow:dispose()
  end)
end

function T.tests.machine_replace_protects_hm_previews_and_cancels()
  withGame(function(game)
    givePair(game)
    teachMoves(game, 0, { "TACKLE", "CUT", "GROWL", "SCRATCH" })
    local protected = hmRows(game, 0)
    Assert.isTrue(#protected >= 1, "the setup moveset must carry a hidden-machine row")
    local machine = findReplacementMachine(game, 0)
    local teaching = moveKeyBehind(game, machine)
    local mons = assert(game.runtime.monService, "field runtime owns the live mon service")
    local bag = assert(game.runtime.bagService, "field runtime owns the live bag service")
    Assert.equal(bag:quantity(machine), 1, "the machine scan leaves its disc stocked")
    local cursor = assert(game.runtime.bagCursor, "field runtime owns the live bag cursor")
    cursor:setPocket("tmhm")
    cursor:setPosition("tmhm", 0)
    cursor:setScroll("tmhm", 0)
    local revisionBefore = mons:partyRevision()

    local flow = openFlow(game, "bag")
    local status = driveUntil(flow, "the bag browse page", 30, function(current)
      return current.page == "bag_browse"
    end)
    Assert.equal(
      liveChild(status).selected and liveChild(status).selected.item,
      machine,
      "the borrowed cursor selects the stocked machine"
    )
    status = chooseBagAction(flow, "use")
    Assert.equal(status.page, "party_item_target", "choosing Use must open the party target page")
    status = settleParty(flow)
    status = choosePartySlot(flow, 0)
    Assert.equal(status.page, "move_pick", "a full moveset must open the replacement picker")
    status = settleSummary(flow)

    -- A protected hidden-machine row stays visible but unpickable: the
    -- notice names it and acknowledgement reports no result.
    local hmRow = protected[1] - 1
    for _ = 1, hmRow do
      status = drive(flow, { { type = "navigate", direction = "down" } })
    end
    Assert.equal(liveChild(status).moveSlot, hmRow, "the protected row is reachable")
    status = drive(flow, { { type = "confirm" } })
    local notice = liveChild(status).notice
    Assert.equal(notice and notice.reason, "hm", "confirming the protected row raises its notice")
    Assert.isNil(flow:takeResult(), "a protected row reports no terminal result")
    Assert.equal(mons:partyRevision(), revisionBefore, "the notice publishes no revision")
    status = drive(flow, { { type = "cancel" } })
    Assert.isNil(liveChild(status).notice, "acknowledging clears the notice")
    Assert.equal(status.page, "move_pick", "acknowledging keeps the picker open")
    Assert.isNil(flow:takeResult(), "acknowledging reports no terminal result")

    -- The prospective preview row never becomes a fifth owned move:
    -- moving past every owned row reaches it and confirming declines.
    for _ = 1, 6 do
      status = drive(flow, { { type = "navigate", direction = "down" } })
      if liveChild(status).moveSlot == 4 then
        break
      end
    end
    Assert.equal(liveChild(status).moveSlot, 4, "the preview sits past the four owned rows")
    status = drive(flow, { { type = "confirm" } })
    status = driveUntil(flow, "the pending target page", 30, function(current)
      return current.page == "party_item_target"
    end)
    Assert.equal(#mons:partyMon(0).moves, 4, "the preview never inserts a fifth owned move")
    local previewed = false
    for _, entry in ipairs(mons:partyMon(0).moves) do
      if entry.move == teaching then
        previewed = true
      end
    end
    Assert.isFalse(previewed, "declining the preview teaches nothing")
    Assert.equal(mons:partyRevision(), revisionBefore, "declining the preview publishes nothing")
    Assert.equal(bag:quantity(machine), 1, "declining the preview consumes nothing")

    -- An ordinary row teaches exactly once through the parent. The
    -- declined picker returns to its pending target, so the teaching
    -- re-enters through the supported bag journey from the root.
    for _ = 1, 3 do
      status = flowStatus(flow)
      if status.page == "bag_browse" then
        break
      end
      status = drive(flow, { { type = "cancel" } })
      status = settleChild(flow, 6)
    end
    status = driveUntil(flow, "the originating bag page", 30, function(current)
      return current.page == "bag_browse"
    end)
    Assert.equal(bag:quantity(machine), 1, "the declined journey keeps its disc")
    status = chooseBagAction(flow, "use")
    Assert.equal(status.page, "party_item_target", "re-entering Use must open the target page")
    status = settleParty(flow)
    status = choosePartySlot(flow, 0)
    Assert.equal(status.page, "move_pick", "reselecting the target reopens the picker")
    status = settleSummary(flow)
    status = drive(flow, { { type = "confirm" } })
    status = driveUntil(flow, "the originating bag page", 30, function(current)
      return current.page == "bag_browse"
    end)
    local learned = false
    for _, entry in ipairs(mons:partyMon(0).moves) do
      if entry.move == teaching then
        learned = true
      end
    end
    Assert.isTrue(learned, "the ordinary pick teaches the machine move")
    Assert.equal(bag:quantity(machine), 0, "exactly one disc is consumed")
    Assert.equal(mons:partyRevision(), revisionBefore + 1, "the teaching publishes one revision")
    Assert.isNil(flow:takeResult(), "returning to the root reports no terminal result")
    flow:dispose()
  end)
end

function T.tests.stale_parent_revisions_rewind_without_consuming()
  withGame(function(game)
    givePair(game)
    teachMoves(game, 0, { "TACKLE", "GROWL" })
    drainMovePp(game, 0, 0, 20)
    local mons = assert(game.runtime.monService, "field runtime owns the live mon service")
    local bag = assert(game.runtime.bagService, "field runtime owns the live bag service")
    Assert.isTrue(bag:add("ETHER", 1), "the stale fixture must stock ether")
    local cursor = assert(game.runtime.bagCursor, "field runtime owns the live bag cursor")
    cursor:setPocket("medicine")
    cursor:setPosition("medicine", 0)
    cursor:setScroll("medicine", 0)

    local flow = openFlow(game, "bag")
    local status = driveUntil(flow, "the bag browse page", 30, function(current)
      return current.page == "bag_browse"
    end)
    status = chooseBagAction(flow, "use")
    status = settleParty(flow)
    status = choosePartySlot(flow, 0)
    Assert.equal(status.page, "move_pick", "the power-point pick must open")
    status = settleSummary(flow)
    -- Drift the bag behind the captured continuation before confirming.
    Assert.isTrue(bag:add("ETHER", 1), "setup drift must advance the bag revision")
    local driftedQuantity = bag:quantity("ETHER")
    local revisionBefore = mons:partyRevision()
    status = drive(flow, { { type = "confirm" } })
    Assert.isTrue(status.open, "a stale pick must not crash the flow")
    Assert.equal(mons:partyMon(0).moves[1].pp, 20, "a stale pick restores no power points")
    Assert.equal(bag:quantity("ETHER"), driftedQuantity, "a stale pick consumes nothing")
    Assert.equal(mons:partyRevision(), revisionBefore, "a stale pick publishes no revision")
    Assert.isNil(flow:takeResult(), "a stale pick reports no terminal result")
    flow:dispose()
  end)
end

return T
