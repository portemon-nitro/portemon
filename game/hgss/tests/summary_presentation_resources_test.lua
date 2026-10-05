-- Field-owned Summary preparation lifetimes: one resource owner hands out
-- per-open demand leases over bounded portrait demand, isolates overlapping
-- leases by demand key and picture epoch, surfaces failures instead of
-- hanging, and releases every owned GPU object exactly once while borrowed
-- icon, queue, and text collaborators stay alive.

local Assert = require("tests.support.Assert")
local SummaryAcceptanceFixture = require("tests.support.SummaryAcceptanceFixture")
local SummaryModel = require("libs.hgss.src.ui.SummaryModel")

local T = {}

local MODULE = "game.hgss.src.field.SummaryPresentationResources"

---@return table<string, unknown> the field-owned Summary resource owner module
local function requireResources()
  local ok, owner = pcall(require, MODULE)
  Assert.isTrue(ok, "the field owns a Summary preparation owner with per-open leases: " .. tostring(owner))
  return assert(owner)
end

---@param versionId string
---@param failures table<string, boolean>
---@return table<string, unknown> owner collaborators over the real family
local function composition(versionId, failures)
  local _, manifest = SummaryAcceptanceFixture.loadSummaryManifest(versionId)
  local helper = SummaryAcceptanceFixture.preparationDoubles(failures)
  return {
    manifest = manifest,
    helper = helper,
    newOptions = function()
      return SummaryAcceptanceFixture.ownerOptions(versionId, helper)
    end,
  }
end

---@param versionId string
---@return table<string, unknown> live service with two gifted members
---@return table<string, unknown> explicit display context for the pair
---@return table<string, unknown> validated Summary family
local function twoMemberSetup(versionId)
  local _, manifest = SummaryAcceptanceFixture.loadSummaryManifest(versionId)
  local service = SummaryAcceptanceFixture.openService()
  SummaryAcceptanceFixture.gift(service, "CHIKORITA", 12)
  SummaryAcceptanceFixture.gift(service, "TOTODILE", 12)
  local context = SummaryAcceptanceFixture.displayContext(manifest, service:partyCount())
  return service, context, manifest
end

---@param service table<string, unknown>
---@param context table<string, unknown>
---@param manifest table<string, unknown>
---@param key string
---@param epoch integer
---@return table<string, unknown> lease demand for the current roster
local function demandFor(service, context, manifest, key, epoch)
  local selectors = {}
  for slot = 0, service:partyCount() - 1 do
    local facts = SummaryModel.build(service, slot, context, manifest)
    selectors[#selectors + 1] = assert(facts.pictureKey, "facts carry the picture selector")
  end
  local facts0 = SummaryModel.build(service, 0, context, manifest)
  local iconKeys = {}
  for _, row in ipairs(assert(facts0.roster, "facts carry the party roster")) do
    iconKeys[#iconKeys + 1] = assert(row.iconKey, "roster rows carry their icon key")
  end
  return {
    key = key,
    revision = service:partyRevision(),
    pictureEpoch = epoch,
    rosterPictureKeys = selectors,
    iconKeys = iconKeys,
  }
end

---@param lease table<string, unknown>
---@param demand table<string, unknown>
---@return table<string, unknown> terminal prepare outcome (never pending)
local function prepareUntilSettled(lease, demand)
  local outcome = nil
  for _ = 1, 12 do
    outcome = assert(lease.prepare(lease, demand), "prepare reports its lease state")
    Assert.isTrue(type(outcome.kind) == "string", "prepare outcomes name their kind")
    if outcome.kind ~= "pending" then
      return outcome
    end
  end
  error("preparation never settles for demand " .. tostring(demand.key), 0)
end

---@param pages { pageId: integer }[]
---@return integer[] sorted unique page ids
local function uniquePages(pages)
  local seen = {}
  for _, record in ipairs(pages) do
    seen[record.pageId] = true
  end
  local ids = {}
  for id in pairs(seen) do
    ids[#ids + 1] = id
  end
  table.sort(ids)
  return ids
end

function T.preparation_leases_bound_portrait_demand_and_release_exactly_once()
  local Resources = requireResources()
  local versions = SummaryAcceptanceFixture.readySummaryVersions()
  Assert.isTrue(#versions >= 1, "the prepared cache publishes the Summary family")
  for _, versionId in ipairs(versions) do
    local setup = composition(versionId, {})
    local service, context, manifest = twoMemberSetup(versionId)
    local owner = Resources.new(setup.newOptions())
    local first = owner:acquire()
    local second = owner:acquire()
    local demand = demandFor(service, context, manifest, "demand-bounded", 1)
    local ready = prepareUntilSettled(first, demand)
    Assert.equal(ready.kind, "ready", versionId .. " prepares the current roster demand")
    Assert.equal(ready.key, demand.key, versionId .. " qualifies readiness by the demand key")
    local unique = uniquePages(setup.helper.calls.portraitPages)
    Assert.isTrue(#unique >= 1, versionId .. " requests the roster portrait pages")
    Assert.isTrue(
      #unique <= service:partyCount(),
      versionId .. " never requests more portrait pages than roster members"
    )
    Assert.isTrue(#unique <= 6, versionId .. " caps portrait demand at the current party")
    local perPage = {}
    for _, record in ipairs(setup.helper.calls.portraitPages) do
      perPage[record.pageId] = (perPage[record.pageId] or 0) + 1
    end
    for pageId, count in pairs(perPage) do
      Assert.equal(count, 1, versionId .. " coalesces shared portrait page " .. pageId)
    end
    local shared = prepareUntilSettled(second, demandFor(service, context, manifest, "demand-bounded", 1))
    Assert.equal(shared.kind, "ready", versionId .. " shares the coalesced demand across leases")
    first:release()
    Assert.equal(
      setup.helper.calls.iconCancels,
      0,
      versionId .. " never cancels borrowed icon preparation while a replacement lease lives"
    )
    local again = prepareUntilSettled(second, demandFor(service, context, manifest, "demand-bounded", 1))
    Assert.equal(again.kind, "ready", versionId .. " keeps the surviving lease usable after the old release")
    second:release()
    second:release()
    local graphics = setup.helper.graphics
    for _, image in ipairs(graphics.images) do
      Assert.equal(image.releaseCount, 1, versionId .. " releases each owned image exactly once")
    end
    Assert.equal(setup.helper.calls.iconReleases, 0, versionId .. " never releases the borrowed icon provider")
    Assert.equal(setup.helper.calls.queueReleases, 0, versionId .. " never releases the borrowed image queue")
    owner:release()
  end
end

function T.stale_completions_and_injected_failures_stay_visible_and_cancellable()
  local Resources = requireResources()
  local versions = SummaryAcceptanceFixture.readySummaryVersions()
  Assert.isTrue(#versions >= 1, "the prepared cache publishes the Summary family")
  for _, versionId in ipairs(versions) do
    local setup = composition(versionId, {})
    local service, context, manifest = twoMemberSetup(versionId)
    local owner = Resources.new(setup.newOptions())
    local lease = owner:acquire()
    local oldDemand = demandFor(service, context, manifest, "demand-old", 1)
    local oldReady = prepareUntilSettled(lease, oldDemand)
    Assert.equal(oldReady.kind, "ready", versionId .. " prepares the first demand key")
    local newDemand = demandFor(service, context, manifest, "demand-new", 2)
    local settled = prepareUntilSettled(lease, newDemand)
    Assert.equal(settled.kind, "ready", versionId .. " prepares the replacement demand key")
    Assert.equal(settled.key, newDemand.key, versionId .. " never adopts the stale key as the selected picture")
    lease:release()
    owner:release()
  end
  for _, versionId in ipairs(versions) do
    local setup = composition(versionId, { portrait = true })
    local service, context, manifest = twoMemberSetup(versionId)
    local owner = Resources.new(setup.newOptions())
    local lease = owner:acquire()
    local failed = prepareUntilSettled(lease, demandFor(service, context, manifest, "demand-broken", 1))
    Assert.equal(failed.kind, "failed", versionId .. " surfaces compilation failure instead of hanging")
    Assert.isTrue(type(failed.error) == "string", versionId .. " names the preparation failure")
    lease:release()
    owner:release()
  end
end

function T.field_release_invalidates_leases_and_keeps_borrowed_owners_alive()
  local Resources = requireResources()
  local versions = SummaryAcceptanceFixture.readySummaryVersions()
  Assert.isTrue(#versions >= 1, "the prepared cache publishes the Summary family")
  for _, versionId in ipairs(versions) do
    local setup = composition(versionId, {})
    local service, context, manifest = twoMemberSetup(versionId)
    local owner = Resources.new(setup.newOptions())
    local lease = owner:acquire()
    local ready = prepareUntilSettled(lease, demandFor(service, context, manifest, "demand-release", 1))
    Assert.equal(ready.kind, "ready", versionId .. " prepares before the field release")
    owner:release()
    owner:release()
    local invalidated = pcall(lease.prepare, lease, demandFor(service, context, manifest, "demand-release", 1))
    Assert.isFalse(invalidated, versionId .. " invalidates remaining leases on field release")
    local graphics = setup.helper.graphics
    for _, image in ipairs(graphics.images) do
      Assert.equal(image.releaseCount, 1, versionId .. " disposes each owned GPU object once")
    end
    Assert.equal(setup.helper.calls.iconCancels, 0, versionId .. " never cancels the borrowed icon provider")
    Assert.equal(setup.helper.calls.iconReleases, 0, versionId .. " never releases the borrowed icon provider")
    Assert.equal(setup.helper.calls.queueReleases, 0, versionId .. " never releases the borrowed image queue")
  end
end

-- Lower-level preparation coverage over the synthetic family with real
-- portrait metadata: the owner coalesces, keys, fails, and releases
-- identically without a dump-derived summary family, and the runtime
-- binding stays identity-qualified.

local SummaryPresentationFixture = require("tests.support.SummaryPresentationFixture")

---@param failures table<string, boolean>?
---@return table<string, unknown> owner collaborators over the synthetic family
local function syntheticComposition(failures)
  local CacheFs = require("libs.storage.src.CacheFs")
  local manifest = SummaryPresentationFixture.manifest()
  local helper = SummaryAcceptanceFixture.preparationDoubles(failures)
  return {
    manifest = manifest,
    helper = helper,
    newOptions = function()
      return {
        cacheFs = CacheFs.forVersion("heartgold"),
        graphics = helper.graphics,
        text = helper.text,
        icons = helper.icons,
        preparationQueue = helper.preparationQueue,
        derivedAssets = helper.derivedAssets,
        manifest = manifest,
      }
    end,
  }
end

---@return table<string, unknown> lease demand for the synthetic pair
local function syntheticDemand(key, epoch)
  return {
    key = key,
    revision = 7,
    pictureEpoch = epoch,
    rosterPictureKeys = { "CHIKORITA", "TOTODILE" },
    iconKeys = { "CHIKORITA/f0", "TOTODILE/f0" },
  }
end

function T.synthetic_demand_coalesces_pages_and_shares_across_leases()
  local Resources = requireResources()
  local setup = syntheticComposition({})
  local owner = Resources.new(setup.newOptions())
  local first = owner:acquire()
  local second = owner:acquire()
  local ready = nil
  for _ = 1, 12 do
    ready = assert(first:prepare(syntheticDemand("syn-pair", 1)))
    if ready.kind ~= "pending" then
      break
    end
  end
  Assert.equal(ready.kind, "ready", "the synthetic pair prepares")
  Assert.equal(ready.key, "syn-pair", "readiness qualifies its demand key")
  local assets = assert(ready.assets, "ready preparation carries its bundle")
  Assert.equal(assets.manifest, setup.manifest, "the bundle carries the family")
  Assert.notNil(assets.portraits, "the bundle carries portrait accessors")
  local shared = nil
  for _ = 1, 12 do
    shared = assert(second:prepare(syntheticDemand("syn-pair", 1)))
    if shared.kind ~= "pending" then
      break
    end
  end
  Assert.equal(shared.kind, "ready", "the replacement lease shares the coalesced demand")
  local seen = {}
  for _, record in ipairs(setup.helper.calls.portraitPages) do
    seen[record.pageId] = (seen[record.pageId] or 0) + 1
  end
  local unique = 0
  for _, count in pairs(seen) do
    unique = unique + 1
    Assert.equal(count, 1, "shared portrait pages compile once")
  end
  Assert.isTrue(unique >= 1 and unique <= 2, "two roster members demand at most two pages")
  first:release()
  local again = assert(second:prepare(syntheticDemand("syn-pair", 1)))
  Assert.equal(again.kind, "ready", "the surviving lease stays usable after the old release")
  second:release()
  owner:release()
end

function T.constructor_and_demand_shapes_fail_loudly()
  local Resources = requireResources()
  local setup = syntheticComposition({})
  local options = setup.newOptions()
  local bad = {}
  for key, value in pairs(options) do
    bad[key] = value
  end
  bad.manifest = nil
  Assert.isFalse(pcall(Resources.new, bad), "the owner requires the summary family")
  bad = {}
  for key, value in pairs(options) do
    bad[key] = value
  end
  bad.preparationQueue = nil
  Assert.isFalse(pcall(Resources.new, bad), "the owner requires its image queue")
  local owner = Resources.new(setup.newOptions())
  local lease = owner:acquire()
  Assert.isFalse(
    pcall(lease.prepare, lease, { key = "", revision = 1, pictureEpoch = 0, rosterPictureKeys = {}, iconKeys = {} }),
    "demands carry a non-empty key"
  )
  local many = { "A", "B", "C", "D", "E", "F", "G" }
  Assert.isFalse(
    pcall(lease.prepare, lease, {
      key = "too-many",
      revision = 1,
      pictureEpoch = 0,
      rosterPictureKeys = many,
      iconKeys = {},
    }),
    "portrait demand stays within the current party"
  )
  Assert.isFalse(
    pcall(lease.prepare, lease, {
      key = "unknown-species",
      revision = 1,
      pictureEpoch = 0,
      rosterPictureKeys = { "MISSINGNO" },
      iconKeys = {},
    }),
    "unknown selectors fail instead of demanding blindly"
  )
  lease:release()
  owner:release()
end

function T.late_completions_land_quietly_after_lease_release()
  local Resources = requireResources()
  local setup = syntheticComposition({})
  local gate = { ready = false }
  local tokens = {}
  local queue = {
    request = function(_, kind, path, priority)
      local token = { id = #tokens + 1, kind = kind, path = path, priority = priority }
      tokens[#tokens + 1] = token
      return token
    end,
    poll = function(_, token)
      if gate.ready then
        return "ready"
      end
      return "pending"
    end,
    take = function(_, token)
      Assert.isTrue(gate.ready, "payloads transfer once ready")
      return { bytes = "late-image-bytes", path = token.path }
    end,
    cancel = function(_, _)
    end,
    release = function(_)
    end,
  }
  local options = setup.newOptions()
  options.preparationQueue = queue
  local owner = Resources.new(options)
  local first = owner:acquire()
  local outcome = assert(first:prepare(syntheticDemand("late", 1)))
  Assert.equal(outcome.kind, "pending", "gated decodes wait")
  first:release()
  first:release()
  gate.ready = true
  local second = owner:acquire()
  local ready = nil
  for _ = 1, 12 do
    ready = assert(second:prepare(syntheticDemand("late", 1)))
    if ready.kind ~= "pending" then
      break
    end
  end
  Assert.equal(ready.kind, "ready", "late worker results enter the owner cache for a live lease")
  Assert.equal(ready.key, "late", "late results qualify the live demand key")
  second:release()
  owner:release()
end

function T.runtime_summary_binding_is_identity_qualified()
  local FieldRuntime = require("game.hgss.src.field.FieldRuntime")
  local runtime = {}
  local first = FieldRuntime.bindSummaryPreparation(runtime, function()
    error("no lease in the binding contract", 0)
  end)
  Assert.isTrue(type(first) == "number", "binding answers its identity")
  Assert.isFalse(
    pcall(FieldRuntime.bindSummaryPreparation, runtime, function()
    end),
    "one binding owns the presented lifetime"
  )
  FieldRuntime.unbindSummaryPreparation(runtime, first + 1)
  Assert.notNil(runtime._summaryPreparation, "a stale unbind never drops the live binding")
  FieldRuntime.unbindSummaryPreparation(runtime, first)
  Assert.isNil(runtime._summaryPreparation, "the matching unbind clears the binding")
  local second = FieldRuntime.bindSummaryPreparation(runtime, function()
    error("no lease in the binding contract", 0)
  end)
  Assert.isTrue(second ~= first, "rebinding mints a fresh identity")
end

return {
  metadata = {
    capabilities = { "rom_dump", "derived_assets" },
    derivedAssets = { "summary:global" },
  },
  tests = T,
}
