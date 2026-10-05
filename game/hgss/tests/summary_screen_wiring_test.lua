-- Summary composition over real collaborators: the live mon service,
-- a synthetic party manifest, and the measured display contract. The
-- wrapper borrows everything, publishes reorders through the owned
-- preparation path, and returns the displayed member on close.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local FakeGraphics = require("tests.support.FakeGraphics")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")
local ScreenTopology = require("libs.ui.src.ScreenTopology")
local SummaryAcceptanceFixture = require("tests.support.SummaryAcceptanceFixture")
local SummaryPresentationFixture = require("tests.support.SummaryPresentationFixture")
local SummaryScreenState = require("game.hgss.src.field.SummaryScreenState")

local T = {}

local function openService(catalog, seed)
  local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
  return HgssMonService.new({
    catalog = catalog,
    bucket = MonsSave.capture(Party.new():capture(), Lcrng.new(seed):capture(), catalog:fingerprint()),
    profile = CatalogFixture.profile(),
    game = "heartgold",
    language = "english",
    charmap = CatalogFixture.CHARMAP,
    games = CatalogFixture.GAMES,
    languages = CatalogFixture.LANGUAGES,
    items = CatalogFixture.ITEMS,
    balls = CatalogFixture.BALLS,
  })
end

local function gift(service, species, level)
  local added = service:giveMon({
    species = species,
    level = level or 5,
    heldItem = "NONE",
    form = 0,
    location = 7,
    date = CatalogFixture.metDate(),
  })
  Assert.isTrue(added, "setup gift must enter the party")
end

local function topology(width, height)
  return ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = width, height = height },
    touch = false,
    role = "world",
  })
end

local function composition(service, opts)
  opts = opts or {}
  local box = { width = 512, height = 384, topologyObject = topology(512, 384) }
  local family = SummaryPresentationFixture.manifest()
  local lease = {}
  function lease:prepare(demand)
    return { kind = "ready", key = demand.key, assets = { manifest = family } }
  end
  function lease:release()
  end
  return {
    mons = service,
    manifest = family,
    initialSlot = opts.initialSlot or 0,
    measureDisplay = function()
      return {
        width = box.width,
        height = box.height,
        topology = box.topologyObject,
        pixelRatio = 1,
        signature = "summary-screen-wiring-test:512x384",
      }
    end,
    mode = opts.mode or "summary",
    request = opts.request,
    context = function()
      return SummaryPresentationFixture.context(service:partyCount())
    end,
    readNavigation = function()
      return nil
    end,
    acquirePreparation = function()
      return lease
    end,
    playCry = opts.playCry,
  }
end

---@param state table<string, unknown> open wrapper
local function settle(state)
  for _ = 1, 12 do
    state:updateFixed({})
  end
end

function T.pages_turn_members_change_and_close_returns_the_displayed_slot()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0x77777777)
  gift(service, "CHIKORITA")
  gift(service, "TOTODILE")
  local state = SummaryScreenState.new(composition(service))
  settle(state)
  local status = state:status()
  Assert.isTrue(status.open, "the summary opens")
  Assert.equal(status.group, "info", "the summary opens on its first native group")
  Assert.equal(status.slot, 0, "the summary opens on the requested member")
  state:updateFixed({ { type = "navigate", direction = "right" } })
  Assert.equal(state:status().group, "skills", "navigation turns the group")
  state:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.equal(state:status().slot, 1, "navigation changes the member")
  state:updateFixed({ { type = "cancel" } })
  local result = assert(state:takeResult(), "a terminal gesture reports its result")
  Assert.equal(result.kind, "return", "closing reports a return")
  Assert.equal(result.slot, 1, "party resumes on the displayed member")
  state:dispose()
end

function T.overview_only_badges_and_masks_survive_navigation()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0x88888888)
  gift(service, "CHIKORITA")
  local revision = service:partyRevision()
  local copy = service:partyMon(0)
  copy.shinyLeaves = 21
  local preparation = assert(service:preparePartyChanges(revision, { { slot = 0, mon = copy } }))
  preparation.publish()
  local state = SummaryScreenState.new(composition(service))
  settle(state)
  local overview = state:status()
  local indicators = assert(overview.facts.indicators, "facts carry their indicators")
  Assert.isTrue(indicators.leaves[1], "mask 21 shows its first leaf")
  Assert.isTrue(indicators.leaves[3], "mask 21 shows its third leaf")
  Assert.isTrue(indicators.leaves[5], "mask 21 shows its fifth leaf")
  Assert.isFalse(indicators.crown, "mask 21 crowns nothing")
  state:updateFixed({ { type = "navigate", direction = "right" } })
  state:updateFixed({ { type = "navigate", direction = "right" } })
  local performance = state:status()
  Assert.equal(performance.group, "performance", "navigation reaches the third native group")
  Assert.deepEqual(
    performance.facts.indicators.leaves,
    indicators.leaves,
    "leaf visibility travels with the member across native groups"
  )
  Assert.equal(service:partyMon(0).shinyLeaves, 21, "navigation preserves the stored mask")
  state:dispose()
end

function T.reorder_publishes_whole_entries_and_preserves_the_rest()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0x99999999)
  gift(service, "CHIKORITA", 5)
  service:setMove(0, 0, "TACKLE")
  service:setMove(0, 1, "GROWL")
  local copy = service:partyMon(0)
  copy.moves[1].pp = 20
  copy.moves[2].ppUps = 2
  copy.moves[2].pp = 30
  copy.shinyLeaves = 13
  copy.heldItem = "SITRUS_BERRY"
  local preparation = assert(service:preparePartyChanges(service:partyRevision(), { { slot = 0, mon = copy } }))
  preparation.publish()
  local before = service:partyRevision()
  local state = SummaryScreenState.new(composition(service))
  settle(state)
  state:updateFixed({ { type = "navigate", direction = "right" } })
  state:updateFixed({ { type = "confirm" } })
  state:updateFixed({})
  state:updateFixed({})
  state:updateFixed({ { type = "confirm" } })
  state:updateFixed({ { type = "navigate", direction = "down" } })
  state:updateFixed({ { type = "confirm" } })
  Assert.equal(service:partyRevision(), before + 1, "one swap advances one revision")
  local after = service:partyMon(0)
  Assert.equal(after.moves[1].move, "GROWL", "the first entry travels to the front")
  Assert.equal(after.moves[1].pp, 30, "power points follow their move")
  Assert.equal(after.moves[1].ppUps, 2, "power-point ups follow their move")
  Assert.equal(after.moves[2].move, "TACKLE", "the second entry travels to the back")
  Assert.equal(after.moves[2].pp, 20, "the other entry keeps its power points")
  Assert.equal(after.shinyLeaves, 13, "leaves survive the reorder")
  Assert.equal(after.heldItem, "SITRUS_BERRY", "the held item survives the reorder")
  state:dispose()
end

function T.move_pick_returns_revision_qualified_selection()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0xAAAAAAAA)
  gift(service, "TOTODILE", 5)
  local state = SummaryScreenState.new(composition(service, {
    mode = "move_pick",
    request = { context = "pp_restore" },
  }))
  settle(state)
  Assert.equal(state:status().group, "skills", "the picker opens on its move rows")
  state:updateFixed({ { type = "navigate", direction = "down" } })
  state:updateFixed({ { type = "confirm" } })
  local result = assert(state:takeResult(), "a terminal gesture reports its result")
  Assert.equal(result.kind, "move_selected", "choice completes the pick")
  Assert.equal(result.slot, 0, "the pick carries its member")
  Assert.equal(result.partyRevision, service:partyRevision(), "the pick carries the live revision")
  state:dispose()
end

function T.delayed_cries_reach_audio_once_and_drop_after_disposal()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0xC11CA001)
  gift(service, "CHIKORITA")
  local cries = {}
  local sounded = SummaryScreenState.new(composition(service, {
    playCry = function(species, pattern)
      cries[#cries + 1] = { species = species, pattern = pattern }
    end,
  }))
  settle(sounded)
  for _ = 1, 12 do
    sounded:updateFixed({})
  end
  Assert.equal(#cries, 1, "the delayed entry cry reaches audio exactly once")
  Assert.equal(cries[1].species, 152, "the cry carries the displayed national species")
  Assert.equal(cries[1].pattern, 0, "the cry plays its default pattern")
  for _ = 1, 12 do
    sounded:updateFixed({})
  end
  Assert.equal(#cries, 1, "drained cries never replay")
  sounded:dispose()
  local dropped = {}
  local pending = SummaryScreenState.new(composition(service, {
    playCry = function(species, pattern)
      dropped[#dropped + 1] = { species = species, pattern = pattern }
    end,
  }))
  pending:updateFixed({})
  pending:dispose()
  Assert.equal(#dropped, 0, "disposal drops a pending cry before its drain")
end

function T.stale_reorder_aborts_without_publication()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0xBBBBBBBB)
  gift(service, "CHIKORITA", 5)
  service:setMove(0, 0, "TACKLE")
  service:setMove(0, 1, "GROWL")
  local state = SummaryScreenState.new(composition(service))
  settle(state)
  state:updateFixed({ { type = "navigate", direction = "right" } })
  state:updateFixed({ { type = "confirm" } })
  state:updateFixed({})
  state:updateFixed({})
  state:updateFixed({ { type = "confirm" } })
  service:setMove(0, 0, "SCRATCH")
  local drifted = service:partyRevision()
  settle(state)
  state:updateFixed({ { type = "navigate", direction = "down" } })
  state:updateFixed({ { type = "confirm" } })
  Assert.equal(service:partyRevision(), drifted, "a drifted gesture publishes nothing")
  Assert.isNil(state:takeResult(), "a drifted gesture reports no terminal result")
  state:dispose()
end

-- Native host-layout and production-wiring acceptance for the Summary
-- application. The wrapper is opened over the real derived Summary
-- family with an explicit display context and a counting preparation
-- lease, so every plan below proves native main/sub geometry and the
-- production dispatch path rather than a renderer-only substitute.

---@param class string one of dualDisplay, nativeLike, wide, tall
---@return table<string, unknown> measured display facts for the class
local function measurementFor(class)
  if class == "dualDisplay" then
    return {
      width = 512,
      height = 384,
      topology = ScreenTopology.dualDisplay({
        id = "world",
        rect = { x = 0, y = 0, width = 256, height = 192 },
        role = "world",
        touch = false,
      }, {
        id = "aux",
        rect = { x = 256, y = 0, width = 256, height = 192 },
        role = "auxiliary",
        touch = true,
      }),
      pixelRatio = 1,
      signature = "summary-native-acceptance:dual",
    }
  end
  if class == "wide" then
    -- Pairing needs both native panes at 1x plus their frames: 640 wide
    -- carries the pair, while 512 falls back to the nativeLike entry.
    return {
      width = 640,
      height = 384,
      topology = topology(640, 384),
      pixelRatio = 1,
      signature = "summary-native-acceptance:wide",
    }
  end
  if class == "tall" then
    return {
      width = 256,
      height = 384,
      topology = topology(256, 384),
      pixelRatio = 1,
      signature = "summary-native-acceptance:tall",
    }
  end
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
    signature = "summary-native-acceptance:nativeLike",
  }
end

---@param summaryManifest table<string, unknown> validated Summary family
---@return table<string, unknown> counting preparation lease double
---@return table<string, integer> lease call counters
local function leaseDouble(summaryManifest)
  local calls = { prepares = 0, releases = 0 }
  local lease = {}
  function lease:prepare(demand)
    calls.prepares = calls.prepares + 1
    if calls.prepares < 3 then
      return { kind = "pending" }
    end
    return { kind = "ready", key = demand.key, assets = { manifest = summaryManifest } }
  end
  function lease:release()
    calls.releases = calls.releases + 1
  end
  return lease, calls
end

---@param service table<string, unknown> live mon service
---@param summaryManifest table<string, unknown> validated Summary family
---@param context table<string, unknown> explicit display context
---@param class string host layout class under test
---@param opts table<string, unknown>? mode/request/slot overrides
---@return table<string, unknown> open wrapper
---@return table<string, integer> lease call counters
local function openNativeSummary(service, summaryManifest, context, class, opts)
  opts = opts or {}
  local measured = opts.measured or measurementFor(class)
  local lease, calls = leaseDouble(summaryManifest)
  local state = SummaryScreenState.new({
    mons = service,
    manifest = summaryManifest,
    initialSlot = opts.slot or 0,
    measureDisplay = function()
      return measured
    end,
    mode = opts.mode or "summary",
    request = opts.request,
    context = function()
      return context
    end,
    readNavigation = function()
      return nil
    end,
    acquirePreparation = function()
      return lease
    end,
  })
  return state, calls
end

---@param state table<string, unknown> open wrapper
---@param ticks integer empty fixed updates to run
local function settle(state, ticks)
  for _ = 1, ticks do
    state:updateFixed({})
  end
end

---@param state table<string, unknown> open wrapper
---@return table<string, unknown> interactive child status
local function activeStatus(state)
  settle(state, 24)
  local status = state:status()
  Assert.isTrue(
    status.open,
    "the Summary wrapper opens over current facts and its preparation lease instead of cancelling"
  )
  return status
end

---@param status table<string, unknown> wrapper status
---@return table<string, table<string, unknown>> panes by native id
local function panesById(status)
  local plan = assert(status.presentation, "the wrapper publishes its pane plan")
  Assert.equal(plan.inputKey, "summary", "native plans carry the Summary input role")
  local byId = {}
  for _, pane in ipairs(assert(plan.panes, "the plan carries its panes")) do
    byId[pane.id] = pane
  end
  return byId
end

---@param owner table<string, unknown> field-owned Summary resource owner
---@return table<string, unknown> lease acquired through the production owner
local function ownerLease(owner)
  local lease = assert(owner:acquire(), "the field owner hands out per-open leases")
  Assert.isTrue(type(lease.prepare) == "function", "leases prepare bounded demand")
  Assert.isTrue(type(lease.release) == "function", "leases release idempotently")
  return lease
end

local OWNER_MODULE = "game.hgss.src.field.SummaryPresentationResources"

---@param versionId string
---@param helper table<string, unknown> preparation doubles
---@return table<string, unknown> field-owned Summary resource owner
local function requireOwner(versionId, helper)
  local ok, Owner = pcall(require, OWNER_MODULE)
  Assert.isTrue(
    ok,
    "production parent flows prepare Summary through the field resource owner: " .. tostring(Owner)
  )
  return Owner.new(SummaryAcceptanceFixture.ownerOptions(versionId, helper))
end

---@param versionId string
---@param summaryManifest table<string, unknown> validated Summary family
---@return table<string, unknown> rig driving the production party flow
local function openProductionPartyFlow(versionId, summaryManifest)
  local PokemonMenuFlow = require("game.hgss.src.field.PokemonMenuFlow")
  local BagCursor = require("libs.hgss.src.items.BagCursor")
  local CacheFs = require("libs.storage.src.CacheFs")
  local HgssBagService = require("libs.hgss.src.items.HgssBagService")
  local ItemFixture = require("libs.items.tests.item_fixture")
  local PartyActions = require("libs.hgss.src.field.PartyActions")
  local PartyCache = require("libs.assets.src.PartyCache")
  local Owner = requireOwner(versionId, SummaryAcceptanceFixture.preparationDoubles({}))
  local service = SummaryAcceptanceFixture.openService()
  SummaryAcceptanceFixture.gift(service, "CHIKORITA", 12)
  SummaryAcceptanceFixture.gift(service, "TOTODILE", 12)
  local context = SummaryAcceptanceFixture.displayContext(summaryManifest, service:partyCount())
  local bag = HgssBagService.new({ catalog = ItemFixture.makeCatalog() })
  local effects = {}
  local leases = 0
  local Mailbox = require("libs.hgss.src.save.Mailbox")
  local MailActions = require("libs.hgss.src.field.MailActions")
  local PcPresentationFixture = require("tests.support.PcPresentationFixture")
  local mailbox = Mailbox.new()
  local pcManifest = PcPresentationFixture.manifest()
  local mailActions = MailActions.new({ mons = service, mailbox = mailbox, bag = bag, manifest = pcManifest })
  local flow = PokemonMenuFlow.new({
    root = "party",
    mons = service,
    bag = bag,
    bagCursor = BagCursor.new(),
    partyActions = PartyActions.new({ mons = service, bag = bag }),
    mailActions = mailActions,
    mailbox = mailbox,
    pcManifest = pcManifest,
    fieldMoves = {
      check = function(_)
        return { kind = "ok" }
      end,
    },
    assets = {
      bagManifest = {},
      partyManifest = PartyCache.loadManifest(CacheFs.forVersion(versionId)),
      summaryManifest = summaryManifest,
      uiManifest = FieldUiFixture.manifest(),
      monCatalog = {
        moveByNativeId = function()
          error("the return journey opens no move picker", 0)
        end,
      },
      itemCatalog = bag:catalog(),
      heroGender = "male",
    },
    measureDisplay = function()
      return measurementFor("nativeLike")
    end,
    prepareIcons = function(_)
      return true, nil
    end,
    cancelIconPreparation = function()
    end,
    effect = function(sequence)
      effects[#effects + 1] = sequence
    end,
    textPolicy = { interGlyphDelay = 0, glyphBudget = 512, abAcceleration = true },
    summaryContext = function()
      return context
    end,
    readSummaryNavigation = function()
      return nil
    end,
    acquireSummaryPreparation = function()
      leases = leases + 1
      return ownerLease(Owner)
    end,
  })
  return { flow = flow, service = service, bag = bag, effects = effects, owner = Owner, leases = function()
    return leases
  end }
end

---@param rig table<string, unknown> production flow rig
---@return table<string, unknown> live child status
local function flowChild(rig)
  local flow = assert(rig.flow, "the rig carries its production flow")
  local status = flow:status()
  Assert.isTrue(status.open, "the production menu flow stays open")
  return assert(status.child, "the production flow carries its live child")
end

---@param rig table<string, unknown> production flow rig
local function waitPartyInteractive(rig)
  for _ = 1, 30 do
    if flowChild(rig).phase == "interactive" then
      return
    end
    rig.flow:updateFixed({})
  end
  error("the production party never turns interactive", 0)
end

---@param rig table<string, unknown> production flow rig
---@return table<unknown, unknown>[] context menu entries for the focused member
local function openPartyContext(rig)
  waitPartyInteractive(rig)
  rig.flow:updateFixed({})
  rig.flow:updateFixed({})
  rig.flow:updateFixed({ { type = "confirm" } })
  local child = flowChild(rig)
  Assert.equal(child.state, "context", "confirming the focused member opens its context menu")
  return assert(child.menu, "the context menu stays open")
end

function T.host_layouts_present_native_main_and_sub_panes()
  local versions = SummaryAcceptanceFixture.readySummaryVersions()
  Assert.isTrue(#versions >= 1, "the prepared cache publishes the Summary family")
  local versionId = versions[1]
  local _, summaryManifest = SummaryAcceptanceFixture.loadSummaryManifest(versionId)
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0x5EED0001)
  gift(service, "CHIKORITA")
  gift(service, "TOTODILE")
  local context = SummaryAcceptanceFixture.displayContext(summaryManifest, service:partyCount())
  local contents = {}
  for _, class in ipairs({ "dualDisplay", "wide", "tall", "nativeLike" }) do
    local state = openNativeSummary(service, summaryManifest, context, class)
    local status = activeStatus(state)
    local panes = panesById(status)
    local main = assert(panes.main, class .. " exposes the native main pane")
    local sub = assert(panes.sub, class .. " exposes the native sub pane")
    Assert.isTrue(main.interactive ~= false or sub.interactive ~= false, class .. " keeps a native target")
    local mainPlacement = assert(main.placement, class .. " places its main pane")
    local subPlacement = assert(sub.placement, class .. " places its sub pane")
    if class == "wide" then
      Assert.isTrue(
        mainPlacement.x < subPlacement.x,
        "wide keeps the main pane left of the sub pane"
      )
    elseif class == "tall" then
      Assert.isTrue(
        mainPlacement.y < subPlacement.y,
        "tall keeps the main pane above the sub pane"
      )
    end
    contents[class] = status.presentation.content
    state:dispose()
  end
  Assert.deepEqual(contents.wide, contents.tall, "native content is identical before host placement")
  Assert.deepEqual(contents.tall, contents.nativeLike, "native content ignores the host aspect ratio")
  Assert.deepEqual(contents.nativeLike, contents.dualDisplay, "native content ignores the host topology")
  -- The too-small pair cannot keep 1x logical resolution, so it keeps
  -- the existing nativeLike fallback instead of distorting widgets.
  local small = {
    width = 512,
    height = 256,
    topology = topology(512, 256),
    pixelRatio = 1,
    signature = "summary-native-acceptance:wide-too-small",
  }
  local fallback = openNativeSummary(service, summaryManifest, context, "wide", { measured = small })
  local fallbackStatus = activeStatus(fallback)
  local fallbackPlan = assert(fallbackStatus.presentation, "the too-small wide wrapper publishes its pane plan")
  Assert.isTrue(
    fallbackPlan.nativeLike == true,
    "too-small wide falls back to the nativeLike entry"
  )
  local fallbackPanes = panesById(fallbackStatus)
  Assert.notNil(fallbackPanes.main, "the fallback still exposes the main pane")
  Assert.notNil(fallbackPanes.sub, "the fallback still exposes the sub pane")
  Assert.isTrue(
    fallbackPanes.sub.interactive ~= false,
    "the fallback keeps the sub pane interactive"
  )
  fallback:dispose()
end

function T.native_like_inspection_is_host_only_and_pointer_isolated()
  local versions = SummaryAcceptanceFixture.readySummaryVersions()
  Assert.isTrue(#versions >= 1, "the prepared cache publishes the Summary family")
  local versionId = versions[1]
  local _, summaryManifest = SummaryAcceptanceFixture.loadSummaryManifest(versionId)
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0x5EED0002)
  gift(service, "CHIKORITA")
  gift(service, "TOTODILE")
  local context = SummaryAcceptanceFixture.displayContext(summaryManifest, service:partyCount())
  local state = openNativeSummary(service, summaryManifest, context, "nativeLike")
  local before = activeStatus(state)
  Assert.equal(before.group, "info", "the Summary opens on its first native group")
  local epoch = before.pictureEpoch
  state:updateFixed({ { type = "pointer_down", x = 160, y = 178 } })
  local inspecting = state:status()
  local overlay = panesById(inspecting)
  Assert.notNil(overlay.main, "the gutter affordance opens the host main inspection")
  Assert.equal(inspecting.group, "info", "opening inspection changes no native group")
  Assert.equal(inspecting.pictureEpoch, epoch, "opening inspection restarts no picture")
  state:updateFixed({ { type = "pointer_down", x = 20, y = 30 } })
  local held = state:status()
  Assert.equal(held.group, "info", "pointer meant for the hidden sub pane never fires")
  Assert.equal(held.pictureEpoch, epoch, "hidden input advances no native clock")
  state:updateFixed({ { type = "cancel" } })
  local closed = state:status()
  Assert.equal(closed.group, "info", "cancel closes the overlay before native cancellation")
  Assert.isTrue(closed.open, "closing the overlay keeps the Summary open")
  Assert.isNil(state:takeResult(), "closing the overlay reports no terminal result")
  state:dispose()
end

-- Native touch over the real compiled family: every native target class
-- (tabs, exit, party icons, move rows, ribbon cells) activates through
-- the wrapper hit test built from the compiled hitboxes, and blank rows
-- and cells stay ineligible against the live facts.
function T.native_touches_follow_the_compiled_hitboxes()
  local versions = SummaryAcceptanceFixture.readySummaryVersions()
  Assert.isTrue(#versions >= 1, "the prepared cache publishes the Summary family")
  local versionId = versions[1]
  local _, summaryManifest = SummaryAcceptanceFixture.loadSummaryManifest(versionId)
  local touch = assert(summaryManifest.hitboxes, "the compiled family carries hitboxes").touch
  assert(type(touch) == "table", "the compiled family carries touch targets")
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0x5EED0003)
  gift(service, "CHIKORITA")
  gift(service, "TOTODILE")
  local entries = assert(summaryManifest.ribbons, "the compiled family carries ribbon definitions").entries
  local first = assert(entries[1], "the compiled family carries ribbon entries")
  local ribboned = service:partyMon(0)
  local field = assert(ribboned.ribbons, "stored mons carry ribbon fields")[first.bitGroup]
  Assert.equal(type(field), "number", "stored ribbon fields are integers")
  ribboned.ribbons[first.bitGroup] = field + 2 ^ assert(first.bit, "ribbon entries carry their bit")
  local preparation = assert(service:preparePartyChanges(service:partyRevision(), { { slot = 0, mon = ribboned } }))
  preparation.publish()
  local context = SummaryAcceptanceFixture.displayContext(summaryManifest, service:partyCount())
  local state = openNativeSummary(service, summaryManifest, context, "nativeLike")
  local opened = activeStatus(state)
  Assert.equal(opened.group, "info", "the Summary opens on its first native group")
  local moves = assert(opened.facts.moves, "facts carry their move rows")
  local occupiedRow, emptyRow = nil, nil
  for _, row in ipairs(moves) do
    if row.kind == "empty" and emptyRow == nil then
      emptyRow = row.moveSlot
    elseif row.kind ~= "empty" and occupiedRow == nil then
      occupiedRow = row.moveSlot
    end
  end
  Assert.notNil(occupiedRow, "setup gifts an occupied move row")
  Assert.notNil(emptyRow, "setup leaves an empty move row")
  local touchId = 0
  local function center(box)
    local right = box.right == 0 and 256 or box.right
    return math.floor((box.left + right) / 2), math.floor((box.top + box.bottom) / 2)
  end
  local function press(key)
    local box = assert(touch[key], "the compiled family carries " .. key)
    local x, y = center(box)
    touchId = touchId + 1
    local id = "touch:" .. touchId
    state:updateFixed({ { type = "pointer_down", pointerId = id, x = x, y = y } })
    state:updateFixed({ { type = "pointer_up", pointerId = id, x = x, y = y } })
  end
  press("tabSkills")
  Assert.equal(state:status().group, "skills", "touch selects the touched group")
  press("moveRow" .. occupiedRow)
  local opening = state:status()
  Assert.equal(opening.phase, "move_opening", "touch on an occupied row enters move detail")
  settle(state, 4)
  local detail = state:status()
  Assert.equal(detail.phase, "move_detail", "move detail settles on the touched row")
  Assert.equal(detail.moveSlot, occupiedRow, "move detail keeps the touched row")
  state:updateFixed({ { type = "cancel" } })
  local rooted = state:status()
  Assert.equal(rooted.phase, "root", "cancelling detail returns to browsing")
  Assert.equal(rooted.group, "skills", "cancelling detail keeps the skills group")
  press("moveRow" .. emptyRow)
  local blank = state:status()
  Assert.equal(blank.phase, "root", "touch on a blank row opens no detail")
  Assert.equal(blank.group, "skills", "touch on a blank row keeps the group")
  press("tabPerformance")
  Assert.equal(state:status().group, "performance", "touch reaches the ribbons group")
  press("ribbonCell0")
  settle(state, 4)
  local ribboned2 = state:status()
  Assert.equal(ribboned2.phase, "ribbon_detail", "touch on an earned cell opens ribbon detail")
  Assert.equal(ribboned2.ribbonIndex, 0, "ribbon detail keeps the touched cell")
  state:updateFixed({ { type = "cancel" } })
  Assert.equal(state:status().phase, "root", "cancelling ribbon detail returns to browsing")
  press("ribbonCell1")
  local blankCell = state:status()
  Assert.equal(blankCell.phase, "root", "touch on a blank cell opens no detail")
  press("member1")
  Assert.equal(state:status().slot, 1, "touch selects the touched eligible member")
  press("exitChrome")
  local result = assert(state:takeResult(), "touch on the exit control reports its result")
  Assert.equal(result.kind, "return", "touch exit closes with a return")
  Assert.equal(result.slot, 1, "touch exit resumes on the displayed member")
  state:dispose()
end

-- Production presenter dispatch through the real field presentation
-- owner: every constructor collaborator is doubled except the Summary
-- renderer itself, so any drawn Summary pixel must come from production
-- code. A test-only injected renderer cannot satisfy this scenario.
local FPR_MODULE = "game.hgss.src.field.FieldPresentationResources"

local FPR_CONSTRUCTOR_MODULES = {
  "libs.assets.src.BagCache",
  "libs.assets.src.PartyCache",
  "libs.hgss.src.presentation.BagHeroRenderer",
  "libs.hgss.src.ui.BagRenderer",
  "libs.hgss.src.ui.FieldDialogueRenderer",
  "libs.hgss.src.ui.FieldMenuRenderer",
  "libs.hgss.src.ui.FieldSignpostRenderer",
  "libs.hgss.src.ui.FieldTextRenderer",
  "libs.hgss.src.presentation.FieldStaticEffectRenderer",
  "libs.hgss.src.presentation.FieldActorEmoteRenderer",
  "libs.hgss.src.presentation.FieldTerrainEffectRenderer",
  "libs.hgss.src.presentation.GpuAssetPool",
  "libs.hgss.src.presentation.FieldRenderer",
  "libs.hgss.src.ui.FieldWindowRenderer",
  "libs.hgss.src.ui.StartMenuRenderer",
  "libs.hgss.src.ui.TrainerCardRenderer",
  "libs.hgss.src.ui.PartyScreenRenderer",
  "libs.hgss.src.ui.NamingScreenRenderer",
  "libs.hgss.src.presentation.MonIconAssetProvider",
  "libs.hgss.src.presentation.AssetPreparationQueue",
  "libs.hgss.src.presentation.ItemIconAssetProvider",
  "libs.hgss.src.presentation.FollowingMonTransitionRenderer",
}

---@return table<string, unknown> generic constructor double tolerating any borrowed use
local function genericInstance()
  local instance = {}
  setmetatable(instance, {
    __index = function(self, key)
      if key == "release" or key == "dispose" then
        local function forget(_)
        end
        self[key] = forget
        return forget
      end
      local function ignore(_)
        return nil
      end
      self[key] = ignore
      return ignore
    end,
  })
  return instance
end

---@param calls table<string, integer> construction counters
---@return table<string, table<string, unknown>> module doubles
local function fprDoubles(calls)
  local modules = {
    ["libs.assets.src.BagCache"] = {
      loadManifest = function(_)
        return { compiled = true }
      end,
    },
    ["libs.assets.src.PartyCache"] = {
      loadManifest = function(_)
        return { compiled = true }
      end,
    },
  }
  for _, name in ipairs(FPR_CONSTRUCTOR_MODULES) do
    if modules[name] == nil then
      modules[name] = {
        new = function(_)
          calls[name] = (calls[name] or 0) + 1
          return genericInstance()
        end,
      }
    end
  end
  return modules
end

---@param versionId string
---@return table<string, unknown> production-shaped presentation runtime over the real cache
local function fprRuntime(versionId)
  local CacheFs = require("libs.storage.src.CacheFs")
  local runtime = {
    cacheFs = CacheFs.forVersion(versionId),
    uiManifest = FieldUiFixture.manifest(),
    playerData = { options = { textFrame = 0 } },
    windowStyles = {},
    fieldEntranceIndicatorAsset = {
      model = {},
      effects = { surf_attachment = { presentation = {}, model = {} } },
    },
    fieldEmoteModels = {},
    fieldEffectAssets = {},
    fieldTerrainEffectController = {
      setModelFactory = function(_, _) end,
    },
  }
  runtime.derivedAssets = {}
  runtime.bindPartyIconPreparation = function(_, _, _)
    return 1
  end
  runtime.unbindPartyIconPreparation = function(_, _)
  end
  return runtime
end

-- Builds the real presentation owner with doubled constructors, swaps the
-- host graphics for a recording fake, and runs the callback. The Summary
-- renderer module itself is never doubled.
---@param versionId string
---@param graphics table<string, unknown> recording graphics namespace
---@param callback fun(resources: table<string, unknown>)
local function withRealPresenters(versionId, graphics, callback)
  local calls = {}
  local modules = fprDoubles(calls)
  local saved = {}
  for _, name in ipairs(FPR_CONSTRUCTOR_MODULES) do
    saved[name] = package.loaded[name]
    package.loaded[name] = modules[name]
  end
  package.loaded[FPR_MODULE] = nil
  local savedLove = rawget(_G, "love")
  -- Presentation construction reads manifests through the real filesystem
  -- backend; only graphics stay doubled.
  rawset(_G, "love", { graphics = graphics, filesystem = savedLove.filesystem })
  local ok, err = pcall(function()
    local FieldPresentationResources = require(FPR_MODULE)
    local resources = FieldPresentationResources.new(fprRuntime(versionId))
    callback(resources)
    resources:dispose()
  end)
  rawset(_G, "love", savedLove)
  for _, name in ipairs(FPR_CONSTRUCTOR_MODULES) do
    package.loaded[name] = saved[name]
  end
  package.loaded[FPR_MODULE] = nil
  if not ok then
    error(err, 0)
  end
end

function T.summary_entry_uses_the_source_fade_recurrence_once()
  local versions = SummaryAcceptanceFixture.readySummaryVersions()
  Assert.isTrue(#versions >= 1, "the prepared cache publishes the Summary family")
  local versionId = versions[1]
  local _, summaryManifest = SummaryAcceptanceFixture.loadSummaryManifest(versionId)
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0x5EED0004)
  gift(service, "CHIKORITA")
  local context = SummaryAcceptanceFixture.displayContext(summaryManifest, service:partyCount())
  local helper = SummaryAcceptanceFixture.preparationDoubles({})
  local owner = requireOwner(versionId, helper)
  local measured = measurementFor("nativeLike")
  local state = SummaryScreenState.new({
    mons = service,
    manifest = summaryManifest,
    initialSlot = 0,
    measureDisplay = function()
      return measured
    end,
    mode = "summary",
    context = function()
      return context
    end,
    readNavigation = function()
      return nil
    end,
    acquirePreparation = function()
      return ownerLease(owner)
    end,
  })
  local coefficients = {}
  for _ = 1, 16 do
    state:updateFixed({})
    local status = state:status()
    if status.entryFade ~= nil then
      coefficients[#coefficients + 1] = status.entryFade
    end
    if status.wrapperPhase == "active" then
      break
    end
  end
  Assert.deepEqual(coefficients, { 16, 14, 11, 9, 6, 3, 0 }, "entry fades the source coefficients exactly once")
  state:updateFixed({ { type = "confirm" } })
  Assert.isNil(state:takeResult(), "entry input never leaks into the first native batch")
  state:dispose()
  owner:release()
end

function T.parent_round_trips_restore_selection_with_both_pane_fades()
  local versions = SummaryAcceptanceFixture.readySummaryVersions()
  Assert.isTrue(#versions >= 1, "the prepared cache publishes the Summary family")
  local versionId = versions[1]
  local _, summaryManifest = SummaryAcceptanceFixture.loadSummaryManifest(versionId)
  local rig = openProductionPartyFlow(versionId, summaryManifest)
  local flow = rig.flow
  local partyRevision = rig.service:partyRevision()
  local bagRevision = rig.bag:revision()
  local menu = openPartyContext(rig)
  Assert.equal(menu[1].kind, "summary", "the source party menu lists the Summary first")
  flow:updateFixed({ { type = "navigate", direction = "down" } })
  flow:updateFixed({ { type = "navigate", direction = "up" } })
  flow:updateFixed({ { type = "confirm" } })
  -- The party press dispatch runs its locked multi-tick cadence before
  -- the exit stages: settle on the staged transition itself so the read
  -- below observes the same terminal dispatch, never an early nil.
  local staged = flow:status()
  for _ = 1, 12 do
    if staged.transition ~= nil then
      break
    end
    flow:updateFixed({})
    staged = flow:status()
  end
  Assert.notNil(staged.transition, "opening the Summary stages its exit transition")
  local firstCoefficient = assert(
    staged.transition.brightnessCoefficient,
    "the Summary exit carries its brightness coefficient"
  )
  local exitCoefficients = { firstCoefficient }
  for _ = 1, 24 do
    flow:updateFixed({ { type = "confirm" } })
    local status = flow:status()
    if status.transition == nil then
      break
    end
    exitCoefficients[#exitCoefficients + 1] = assert(
      status.transition.brightnessCoefficient,
      "the Summary exit carries its brightness coefficient"
    )
  end
  Assert.deepEqual(
    exitCoefficients,
    { 0, 2, 5, 7, 10, 13, 16 },
    "the Summary exit fades both panes without the sibling shutter"
  )
  Assert.equal(flow:status().page, "summary", "the nested Summary owns the replacement")
  local entryCoefficients = {}
  for _ = 1, 16 do
    flow:updateFixed({})
    local child = flowChild(rig)
    if child.entryFade ~= nil then
      entryCoefficients[#entryCoefficients + 1] = child.entryFade
    end
    if child.wrapperPhase == "active" then
      break
    end
  end
  Assert.deepEqual(entryCoefficients, { 16, 14, 11, 9, 6, 3, 0 }, "the nested entry keeps its source recurrence")
  flow:updateFixed({ { type = "navigate", direction = "right" } })
  Assert.equal(flowChild(rig).group, "skills", "the nested Summary reaches its second native group")
  flow:updateFixed({ { type = "confirm" } })
  for _ = 1, 6 do
    flow:updateFixed({})
  end
  Assert.equal(flowChild(rig).phase, "move_detail", "confirming a move row opens its detail")
  flow:updateFixed({ { type = "cancel" } })
  local rooted = flowChild(rig)
  Assert.equal(rooted.phase, "root", "detail cancellation returns to browsing")
  Assert.equal(rooted.group, "skills", "detail cancellation keeps its native group")
  Assert.isTrue(flow:status().open, "detail cancellation never exits the Summary")
  Assert.equal(rig.service:partyRevision(), partyRevision, "browsing publishes no reorder")
  flow:updateFixed({ { type = "cancel" } })
  for _ = 1, 24 do
    if flow:status().page == "party_browse" then
      break
    end
    flow:updateFixed({})
  end
  Assert.equal(flow:status().page, "party_browse", "closing the Summary returns to the party")
  -- The rebuilt party child reveals across its own ticks before its
  -- cursor publishes: settle on the restored cursor so the read below
  -- observes the same terminal selection, never an early reveal value.
  local resumed = flowChild(rig)
  for _ = 1, 12 do
    if resumed.cursorNode == 0 then
      break
    end
    flow:updateFixed({})
    resumed = flowChild(rig)
  end
  Assert.equal(resumed.cursorNode, 0, "the party resumes on the displayed member")
  Assert.isTrue(
    flowChild(rig).state ~= "context",
    "transition input never replays into the replacement child"
  )
  Assert.isNil(flow:takeResult(), "returning reports no terminal result")
  Assert.equal(rig.service:partyRevision(), partyRevision, "the return journey mutates no mon")
  Assert.equal(rig.bag:revision(), bagRevision, "the return journey touches no bag transaction")
  Assert.equal(rig.leases(), 1, "the journey holds one preparation lease for its Summary")
  flow:dispose()
  rig.owner:release()
end

function T.production_presenters_draw_summary_without_a_test_renderer()
  local versions = SummaryAcceptanceFixture.readySummaryVersions()
  Assert.isTrue(#versions >= 1, "the prepared cache publishes the Summary family")
  local versionId = versions[1]
  local _, summaryManifest = SummaryAcceptanceFixture.loadSummaryManifest(versionId)
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0x5EED0003)
  gift(service, "CHIKORITA")
  local context = SummaryAcceptanceFixture.displayContext(summaryManifest, service:partyCount())
  local state = openNativeSummary(service, summaryManifest, context, "nativeLike")
  local status = activeStatus(state)
  local graphics = FakeGraphics.new({})
  withRealPresenters(versionId, graphics, function(resources)
    local FieldApplicationIds = require("libs.hgss.src.field.FieldApplicationIds")
    local ok, err = pcall(resources.drawApplication, resources, FieldApplicationIds.POKEMON, status, {})
    Assert.isTrue(ok, "production presenters draw the native Summary: " .. tostring(err))
    Assert.isTrue(
      #graphics.rectangles + #graphics.draws > 0,
      "the real presenter leaves drawn Summary output behind"
    )
    local bagPlan = {
      panes = {},
      content = {},
      inputKey = "bag",
      render = function(_, _, _)
      end,
      mapInput = function()
        return nil
      end,
      frames = {},
    }
    local bagOk, bagErr = pcall(
      resources.drawApplication,
      resources,
      FieldApplicationIds.BAG,
      { presentation = bagPlan },
      {}
    )
    Assert.isTrue(bagOk, "the sibling Bag branch keeps its dispatch: " .. tostring(bagErr))
  end)
  state:dispose()
end

return {
  metadata = {
    capabilities = { "rom_dump", "derived_assets" },
    derivedAssets = { "summary:global", "party:global" },
  },
  tests = T,
}
