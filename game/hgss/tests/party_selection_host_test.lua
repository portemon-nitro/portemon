-- Script-owned party selection host: one visible PartyScreenState in
-- pick context per open, driven by scheduler UI events only. Covers the
-- open/step/result/focus/close/status protocol against the real screen,
-- real manifest, and real mon service: pad and pointer selection, cancel
-- focus persistence, the empty shell, one-shot results, lifecycle
-- failures, and resume rebuilds from value-only focus.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local Errors = require("libs.errors.src.Errors")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local GameVersion = require("romdump.src.source.GameVersion")
local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")
local PartyCache = require("libs.assets.src.PartyCache")
local PartyScreenLayout = require("libs.hgss.src.ui.PartyScreenLayout")
local RomImporter = require("romdump.src.source.RomImporter")
local ScreenTopology = require("libs.hgss.src.ui.ScreenTopology")
local ScriptErrors = require("libs.script.src.errors")

local HOST_MODULE = "game.hgss.src.field.PartySelectionHost"

local T = {}

local function requireHost()
  local ok, host = pcall(require, HOST_MODULE)
  Assert.isTrue(ok, "the script party host owns one open selection: " .. tostring(host))
  return assert(host)
end

local function readyVersions()
  local versions = {}
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      local cacheFs = CacheFs.forVersion(versionId)
      local marker = cacheFs:read(PartyCache.markerPath())
      if marker ~= nil and PartyCache.isReady(cacheFs, marker) then
        versions[#versions + 1] = versionId
      end
    end
  end
  return versions
end

local function openService()
  local catalog = CatalogFixture.makeCatalog()
  return HgssMonService.new({
    catalog = catalog,
    bucket = MonsSave.capture(Party.new():capture(), Lcrng.new(0xBBBBBBBB):capture(), catalog:fingerprint()),
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

local function give(service, species)
  Assert.isTrue(
    service:giveMon({
      species = species,
      level = 5,
      heldItem = "NONE",
      form = 0,
      location = 7,
      date = CatalogFixture.metDate(),
    }),
    "setup gift must enter the party"
  )
end

local function stubMeasurement(width, height)
  return {
    width = width,
    height = height,
    topology = ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = width, height = height },
      role = "world",
      touch = true,
    }),
    pixelRatio = 1,
    signature = "stub:" .. width .. "x" .. height,
  }
end

local function openHost(versionId, service, request)
  local Host = requireHost()
  local cacheFs = CacheFs.forVersion(versionId)
  local manifest = PartyCache.loadManifest(cacheFs)
  local host = Host.new({
    service = service,
    manifest = manifest,
    measureDisplay = function()
      return stubMeasurement(256, 192)
    end,
    uiManifest = FieldUiFixture.manifest(),
  })
  local handle = host:open(request or { focus = 0, allowCancel = true, policy = "occupied" })
  return host, handle
end

for _, versionId in ipairs(readyVersions()) do
  local function padSelectsTheSecondSlot()
    local service = openService()
    give(service, "CHIKORITA")
    give(service, "TOTODILE")
    give(service, "EEVEE")
    local host, handle = openHost(versionId, service)
    Assert.isTrue(host:status().open, "opening shows the native party")
    Assert.notNil(host:status().presentation, "the open selection carries a visible plan")
    local status = host:step(handle, { { type = "navigate", direction = "down" } })
    Assert.equal(host:focus(handle), status.cursorNode, "host focus tracks the live cursor")
    host:step(handle, { { type = "confirm" } })
    local result = host:result(handle)
    Assert.notNil(result, "confirming a slot answers exactly once")
    Assert.equal(result.kind, "selected")
    Assert.equal(type(result.slot), "number")
    Assert.isNil(host:result(handle), "the answer is one-shot")
  end
  T["pad_selects_a_slot_exactly_once:" .. versionId] = padSelectsTheSecondSlot

  local function pointerSelectsASlot()
    local service = openService()
    give(service, "CHIKORITA")
    give(service, "TOTODILE")
    local host, handle = openHost(versionId, service)
    local status = assert(host:status(), "an open selection carries its status")
    local plan = assert(status.presentation, "an open selection carries its plan")
    local pane = assert(plan.panes and plan.panes[1], "the native pane is placed")
    local LayoutGeometry = require("libs.ui.src.LayoutGeometry")
    local cacheFs = CacheFs.forVersion(versionId)
    local layout = PartyScreenLayout.resolve({ manifest = PartyCache.loadManifest(cacheFs), cancellable = true })
    local rect = assert(layout.slotRects[2], "the production layout carries the second slot rect")
    local hx, hy = LayoutGeometry.logicalToHost(
      pane.placement,
      rect.x + math.floor(rect.width / 2),
      rect.y + math.floor(rect.height / 2)
    )
    Assert.notNil(hx, "the slot center inverts to host coordinates")
    host:step(handle, { { type = "pointer_down", pointerId = "touch:1", x = hx, y = hy } })
    host:step(handle, { { type = "pointer_up", pointerId = "touch:1", x = hx, y = hy } })
    local result = host:result(handle)
    Assert.notNil(result, "tapping a slot answers exactly once")
    Assert.equal(result.kind, "selected")
    Assert.equal(result.slot, 1, "the tap resolves through production hit geometry")
  end
  T["pointer_selects_through_hit_geometry:" .. versionId] = pointerSelectsASlot

  local function cancelFocusPersists()
    local service = openService()
    give(service, "CHIKORITA")
    local host, handle = openHost(versionId, service)
    for _ = 1, 8 do
      host:step(handle, { { type = "navigate", direction = "down" } })
      if host:focus(handle) == "cancel" then
        break
      end
    end
    Assert.equal(host:focus(handle), "cancel", "navigation reaches the cancel affordance")
    host:step(handle, {})
    host:step(handle, {})
    Assert.equal(host:focus(handle), "cancel", "empty ticks keep cancel focus")
    host:step(handle, { { type = "confirm" } })
    local result = host:result(handle)
    Assert.notNil(result)
    Assert.equal(result.kind, "cancelled")
  end
  T["cancel_focus_persists:" .. versionId] = cancelFocusPersists

  local function emptyPartyShowsCancelShell()
    local service = openService()
    local host, handle = openHost(versionId, service, { focus = 0, allowCancel = true, policy = "occupied" })
    local status = host:status()
    Assert.isTrue(status.open, "the empty shell stays open")
    Assert.equal(host:focus(handle), "cancel", "an empty party focuses cancel")
    host:step(handle, { { type = "confirm" } })
    local result = host:result(handle)
    Assert.notNil(result)
    Assert.equal(result.kind, "cancelled")
    host:close(handle)
  end
  T["empty_party_shows_the_cancel_shell:" .. versionId] = emptyPartyShowsCancelShell

  local function emptyPartyWithoutCancelIsInvalid()
    local service = openService()
    local Host = requireHost()
    local cacheFs = CacheFs.forVersion(versionId)
    local host = Host.new({
      service = service,
      manifest = PartyCache.loadManifest(cacheFs),
      measureDisplay = function()
        return stubMeasurement(256, 192)
      end,
    })
    local ok, err = pcall(function()
      host:open({ focus = 0, allowCancel = false, policy = "occupied" })
    end)
    Assert.isFalse(ok, "no selectable slot without cancel is a typed invalid request")
    Assert.isTrue(Errors.is(err))
    Assert.equal((err --[[@as Errors.Error]]).code, ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE)
    Assert.isNil(host:status(), "a refused open owns nothing")
  end
  T["empty_party_without_cancel_is_invalid:" .. versionId] = emptyPartyWithoutCancelIsInvalid

  local function activityMirrorsTheOpenSelection()
    local service = openService()
    give(service, "CHIKORITA")
    local host, handle = openHost(versionId, service)
    Assert.isTrue(host:isActive(), "an open selection owns the script modal lane")
    host:close(handle)
    Assert.isFalse(host:isActive(), "close releases the lane")
  end
  T["activity_mirrors_the_open_selection:" .. versionId] = activityMirrorsTheOpenSelection

  local function lifecycleFailuresAreLoud()
    local service = openService()
    give(service, "CHIKORITA")
    local host, handle = openHost(versionId, service)
    local ok, _ = pcall(function()
      host:open({ focus = 0, allowCancel = true, policy = "occupied" })
    end)
    Assert.isFalse(ok, "a second open is a composition error")
    host:close(handle)
    Assert.isNil(host:status(), "close releases the selection")
    local okClose, _ = pcall(function()
      host:close(handle)
    end)
    Assert.isFalse(okClose, "closing an idle handle fails loudly")
    local okStep, _ = pcall(function()
      host:step(handle, {})
    end)
    Assert.isFalse(okStep, "stepping an idle handle fails loudly")
  end
  T["lifecycle_failures_are_loud:" .. versionId] = lifecycleFailuresAreLoud

  local function resumeRebuildsFromValueFocus()
    local service = openService()
    give(service, "CHIKORITA")
    give(service, "TOTODILE")
    local host, handle = openHost(versionId, service, { focus = "cancel", allowCancel = true, policy = "occupied" })
    Assert.equal(host:focus(handle), "cancel", "a saved cancel focus rebuilds onto cancel")
    host:close(handle)
    local host2, handle2 = openHost(versionId, service, { focus = 5, allowCancel = true, policy = "occupied" })
    Assert.equal(host2:focus(handle2), 0, "an out-of-range saved slot reconciles instead of sticking")
    host2:close(handle2)
  end
  T["resume_rebuilds_from_value_focus:" .. versionId] = resumeRebuildsFromValueFocus
end

return { tests = T }
