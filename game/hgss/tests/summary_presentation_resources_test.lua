-- Field-owned Summary preparation lifetimes: one resource owner hands out
-- per-open demand leases over bounded portrait demand, isolates overlapping
-- leases by demand key and picture epoch, surfaces failures instead of
-- hanging, and releases every owned GPU object exactly once while borrowed
-- icon, queue, and text collaborators stay alive.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local MoveIconCache = require("libs.assets.src.MoveIconCache")
local MoveIconFixture = require("tests.support.MoveIconFixture")
local SummaryAcceptanceFixture = require("tests.support.SummaryAcceptanceFixture")
local SummaryModel = require("libs.hgss.src.ui.SummaryModel")
local MonCache = require("libs.assets.src.MonCache")
local SummaryCache = require("libs.assets.src.SummaryCache")

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
  local facts = SummaryModel.build(service, 0, context, manifest)
  local selectors = {}
  local iconKeys = {}
  local cryBanks = {}
  for _, row in ipairs(assert(facts.roster, "facts carry the party roster")) do
    iconKeys[#iconKeys + 1] = assert(row.iconKey, "roster rows carry their icon key")
    if row.isEgg ~= true then
      selectors[#selectors + 1] = assert(row.portraitSelector, "non-egg rows carry their portrait identity")
      cryBanks[#cryBanks + 1] = manifest.dexNumbers[row.species].national
    end
  end
  return {
    key = key,
    revision = service:partyRevision(),
    pictureEpoch = epoch,
    portraitSelectors = selectors,
    iconKeys = iconKeys,
    cryBanks = cryBanks,
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
    local poolInner = assert(setup.helper.poolInner, "the doubles carry the pool census")
    local chromeCount = #SummaryCache.referencedPaths(manifest)
      + #MoveIconCache.referencedPaths(MoveIconCache.loadManifest(CacheFs.forVersion(versionId)))
    Assert.equal(
      poolInner:stats().outstandingLeases,
      chromeCount,
      versionId .. " returns every portrait borrow on the last release while chrome stays pinned"
    )
    Assert.equal(
      poolInner:stats().physicalImages,
      chromeCount + #unique,
      versionId .. " keeps returned portrait pages idle instead of freeing them synchronously"
    )
    -- The shared idle limit bounds physical retention: the idle portrait
    -- pages free exactly once while pinned chrome stays resident.
    local trimmed = poolInner:prune()
    Assert.equal(trimmed, #unique, versionId .. " trims exactly the idle portrait pages")
    Assert.equal(
      poolInner:stats().physicalImages,
      chromeCount,
      versionId .. " keeps the family visuals resident across leases"
    )
    Assert.equal(setup.helper.calls.iconReleases, 0, versionId .. " never releases the borrowed icon provider")
    owner:release()
    Assert.equal(
      poolInner:stats().outstandingLeases,
      0,
      versionId .. " returns every remaining borrow on owner release"
    )
    local finalTrimmed = poolInner:prune()
    Assert.equal(finalTrimmed, chromeCount, versionId .. " trims every returned chrome visual")
    Assert.equal(
      poolInner:stats().physicalImages,
      0,
      versionId .. " reclaims every physical image exactly once with no double free"
    )
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
    local poolInner = assert(setup.helper.poolInner, "the doubles carry the pool census")
    Assert.equal(
      poolInner:stats().outstandingLeases,
      0,
      versionId .. " returns every borrow on field release"
    )
    local trimmed = poolInner:prune()
    Assert.isTrue(trimmed > 0, versionId .. " trims the returned physical images")
    Assert.equal(
      poolInner:stats().physicalImages,
      0,
      versionId .. " reclaims each borrowed GPU object once with no double free"
    )
    Assert.equal(setup.helper.calls.iconCancels, 0, versionId .. " never cancels the borrowed icon provider")
    Assert.equal(setup.helper.calls.iconReleases, 0, versionId .. " never releases the borrowed icon provider")
  end
end

-- Lower-level preparation coverage over the synthetic family with real
-- portrait metadata: the owner coalesces, keys, fails, and releases
-- identically without a dump-derived summary family, and the runtime
-- binding stays identity-qualified.

local SummaryPresentationFixture = require("tests.support.SummaryPresentationFixture")

---@param failures table<string, boolean>?
---@param versionId string ready game version supplying real portrait metadata
---@return table<string, unknown> owner collaborators over the synthetic family
local function syntheticComposition(failures, versionId)
  local CacheFs = require("libs.storage.src.CacheFs")
  local manifest = SummaryPresentationFixture.manifest()
  local helper = SummaryAcceptanceFixture.preparationDoubles(failures)
  return {
    manifest = manifest,
    helper = helper,
    newOptions = function()
      return {
        cacheFs = SummaryAcceptanceFixture.withSyntheticVisuals(CacheFs.forVersion(versionId)),
        graphics = helper.graphics,
        text = helper.text,
        icons = helper.icons,
        imagePool = assert(helper.imagePool, "the doubles carry the shared image owner"),
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
    portraitSelectors = {
      MonCache.portraitSelector("CHIKORITA", 0, "male", false),
      MonCache.portraitSelector("TOTODILE", 0, "male", false),
    },
    iconKeys = { "CHIKORITA/f0", "TOTODILE/f0" },
    cryBanks = { 152, 158 },
  }
end

function T.synthetic_demand_coalesces_pages_and_shares_across_leases()
  local Resources = requireResources()
  local versions = SummaryAcceptanceFixture.readySummaryVersions()
  Assert.isTrue(#versions >= 1, "the prepared cache publishes the Summary family")
  for _, versionId in ipairs(versions) do
    local setup = syntheticComposition({}, versionId)
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
    Assert.equal(ready.kind, "ready", versionId .. " prepares the synthetic pair")
    Assert.equal(ready.key, "syn-pair", versionId .. " qualifies readiness by its demand key")
    local assets = assert(ready.assets, versionId .. " carries its bundle on readiness")
    Assert.equal(assets.manifest, setup.manifest, versionId .. " carries the family")
    Assert.notNil(assets.portraits, versionId .. " carries portrait accessors")
    local shared = nil
    for _ = 1, 12 do
      shared = assert(second:prepare(syntheticDemand("syn-pair", 1)))
      if shared.kind ~= "pending" then
        break
      end
    end
    Assert.equal(shared.kind, "ready", versionId .. " shares the coalesced demand")
    local seen = {}
    for _, record in ipairs(setup.helper.calls.portraitPages) do
      seen[record.pageId] = (seen[record.pageId] or 0) + 1
    end
    local unique = 0
    for _, count in pairs(seen) do
      unique = unique + 1
      Assert.equal(count, 1, versionId .. " compiles shared portrait pages once")
    end
    Assert.isTrue(unique >= 1 and unique <= 2, versionId .. " demands at most two pages for two members")
    first:release()
    local again = assert(second:prepare(syntheticDemand("syn-pair", 1)))
    Assert.equal(again.kind, "ready", versionId .. " keeps the surviving lease usable after the old release")
    second:release()
    owner:release()
  end
end

function T.constructor_and_demand_shapes_fail_loudly()
  local Resources = requireResources()
  local versions = SummaryAcceptanceFixture.readySummaryVersions()
  Assert.isTrue(#versions >= 1, "the prepared cache publishes the Summary family")
  for _, versionId in ipairs(versions) do
    local setup = syntheticComposition({}, versionId)
    local options = setup.newOptions()
    local bad = {}
    for key, value in pairs(options) do
      bad[key] = value
    end
    bad.manifest = nil
    Assert.isFalse(pcall(Resources.new, bad), versionId .. " requires the summary family")
    bad = {}
    for key, value in pairs(options) do
      bad[key] = value
    end
    bad.imagePool = nil
    Assert.isFalse(pcall(Resources.new, bad), versionId .. " requires its shared image owner")
    local owner = Resources.new(setup.newOptions())
    local lease = owner:acquire()
    Assert.isFalse(
      pcall(
        lease.prepare,
        lease,
        { key = "", revision = 1, pictureEpoch = 0, portraitSelectors = {}, iconKeys = {}, cryBanks = {} }
      ),
      versionId .. " demands carry a non-empty key"
    )
    local many = { "A", "B", "C", "D", "E", "F", "G" }
    Assert.isFalse(
      pcall(lease.prepare, lease, {
        key = "too-many",
        revision = 1,
        pictureEpoch = 0,
        portraitSelectors = many,
        iconKeys = {},
        cryBanks = {},
      }),
      versionId .. " keeps portrait demand within the current party"
    )
    Assert.isFalse(
      pcall(lease.prepare, lease, {
        key = "unknown-species",
        revision = 1,
        pictureEpoch = 0,
        portraitSelectors = { "MISSINGNO" },
        iconKeys = {},
        cryBanks = {},
      }),
      versionId .. " fails unknown selectors instead of demanding blindly"
    )
    lease:release()
    owner:release()
  end
end

function T.late_completions_land_quietly_after_lease_release()
  local Resources = requireResources()
  local versions = SummaryAcceptanceFixture.readySummaryVersions()
  Assert.isTrue(#versions >= 1, "the prepared cache publishes the Summary family")
  for _, versionId in ipairs(versions) do
    local setup = syntheticComposition({}, versionId)
    local gate = { ready = false }
    local shared = assert(setup.helper.imagePool, "the doubles carry the shared image owner")
    local requested = {}
    local pool = {}
    function pool:request(path, sampler, priority)
      requested[#requested + 1] = path
      return shared:request(path, sampler, priority)
    end
    function pool:poll(token)
      if gate.ready then
        return shared:poll(token)
      end
      return "pending"
    end
    function pool:acquire(token)
      return shared:acquire(token)
    end
    function pool:release(lease)
      return shared:release(lease)
    end
    function pool:cancel(token)
      return shared:cancel(token)
    end
    function pool:prune()
      return shared:prune()
    end
    function pool:stats()
      return shared:stats()
    end
    local options = setup.newOptions()
    options.imagePool = pool
    local owner = Resources.new(options)
    local first = owner:acquire()
    local outcome = assert(first:prepare(syntheticDemand("late", 1)))
    Assert.equal(outcome.kind, "pending", versionId .. " waits on gated image requests")
    Assert.isTrue(#requested >= 1, versionId .. " enrolls portrait demand before the first pending answer")
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
    Assert.equal(ready.kind, "ready", versionId .. " lands late image results for a live lease")
    Assert.equal(ready.key, "late", versionId .. " qualifies late results by the live demand key")
    second:release()
    owner:release()
  end
end

-- Counts shared-owner image requests per cache-relative path from
-- installation onward: the returned table fills as preparation enrolls
-- demand, so callers install it before preparing and read per-path totals
-- after the demand settles.
---@param helper table<string, unknown> preparation doubles
---@return table<string, integer> live per-path request counts
local function countPoolRequests(helper)
  local counts = {}
  local pool = assert(helper.imagePool, "the doubles carry the shared image owner")
  local inner = assert(pool.request, "the image owner enrolls requests")
  pool.request = function(_, path, sampler, priority)
    counts[path] = (counts[path] or 0) + 1
    return inner(pool, path, sampler, priority)
  end
  return counts
end

-- Dynamic chrome flows through the existing preparation owner: every
-- animation frame image the synthetic family references is prepared once
-- through its canonical path and resolves on the ready bundle, without
-- introducing party art and without changing owner lifetime semantics.
function T.dynamic_frame_visuals_prepare_through_the_existing_owner()
  local Resources = requireResources()
  local versions = SummaryAcceptanceFixture.readySummaryVersions()
  Assert.isTrue(#versions >= 1, "the prepared cache publishes the Summary family")
  for _, versionId in ipairs(versions) do
    local setup = syntheticComposition({}, versionId)
    local manifest = setup.manifest
    Assert.equal(
      manifest.schema,
      "g4-summary-manifest-v4",
      versionId .. " tracks the generated schema in its synthetic family"
    )
    local sprites = assert(manifest.sprites, "the synthetic family carries dynamic chrome")
    for _, role in ipairs({ "animations", "primaryCursor", "secondaryMoveCursor", "performance", "leaves", "ribbons" }) do
      Assert.notNil(sprites[role], "the synthetic family carries " .. role)
    end
    local animations = assert(sprites.animations, "the synthetic family carries animation descriptors")
    local visuals = assert(manifest.visuals, "the synthetic family carries visuals")
    local frameImages = {}
    local seen = {}
    for name, descriptor in pairs(animations) do
      local frames = assert(descriptor.frames, "synthetic animation " .. tostring(name) .. " carries frames")
      Assert.isTrue(#frames > 0, "synthetic animation " .. tostring(name) .. " is nonempty")
      for _, frame in ipairs(frames) do
        local visualName = assert(frame.visual, "synthetic frames name their visual")
        local visual = assert(visuals[visualName], "synthetic frame resolves its visual")
        local image = assert(visual.image, "synthetic frame visuals carry image paths")
        Assert.equal(
          image:sub(1, #"assets/generated/summary/"),
          "assets/generated/summary/",
          "synthetic frames stay family-owned: " .. image
        )
        Assert.isTrue(image:find("party", 1, true) == nil, "synthetic frames never reuse party art")
        if seen[image] == nil then
          seen[image] = true
          frameImages[#frameImages + 1] = image
        end
      end
    end
    Assert.isTrue(#frameImages > 0, versionId .. " references frame images in its synthetic chrome")
    local owner = Resources.new(setup.newOptions())
    local counts = countPoolRequests(setup.helper)
    Assert.equal(
      setup.helper.poolInner:stats().physicalImages,
      0,
      versionId .. " stages no chrome image at construction"
    )
    local lease = owner:acquire()
    local outcome = nil
    for _ = 1, 12 do
      outcome = assert(lease:prepare(syntheticDemand("dynamic-chrome", 1)))
      if outcome.kind ~= "pending" then
        break
      end
    end
    Assert.equal(outcome.kind, "ready", versionId .. " prepares the dynamic chrome demand")
    local assets = assert(outcome.assets, versionId .. " carries its bundle on readiness")
    for _, image in ipairs(frameImages) do
      Assert.notNil(assets.imageForPath(image), versionId .. " resolves frame " .. image)
      Assert.equal(
        counts[image],
        1,
        versionId .. " pins frame " .. image .. " once on first demand, not per open"
      )
    end
    local repinned = assert(lease:prepare(syntheticDemand("dynamic-chrome", 1)))
    Assert.equal(repinned.kind, "ready", versionId .. " keeps the pinned chrome drawable")
    for _, image in ipairs(frameImages) do
      Assert.equal(counts[image], 1, versionId .. " never re-enrolls pinned frame " .. image)
    end
    lease:release()
    lease:release()
    owner:release()
  end
end

-- Exact-identity preparation below: the owner resolves full roster portrait
-- identities to their own generated pages, shares canonical images by
-- cache-relative path, and frees owned GPU state with the last live lease.
-- Every selector below is built through the portrait constructor so the
-- demand spelling always matches the roster portrait identity.

---@param pageId integer zero-based generated portrait page
---@return table<string, unknown> generated portrait entry stub
local function portraitEntry(pageId)
  return {
    pageId = pageId,
    frames = { { x = 0, y = 0, width = 8, height = 8 } },
    width = 8,
    height = 8,
  }
end

---@param entries table<string, table<string, unknown>> controlled portrait manifest entries
---@return table<string, unknown> cache reader serving only the portrait manifest
local function portraitCache(entries)
  local cache = {}
  function cache:loadLua(path)
    if path == MoveIconCache.manifestPath() then
      return MoveIconFixture.manifest()
    end
    Assert.equal(path, MonCache.portraitManifestPath(), "portrait reads name the portrait manifest")
    return { entries = entries }
  end
  function cache:read(path)
    return "synthetic visual " .. path
  end
  return cache
end

---@param entries table<string, table<string, unknown>> controlled portrait manifest entries
---@param manifest table<string, unknown>? summary family (defaults to the synthetic family)
---@return table<string, unknown> owner collaborators over the controlled portrait manifest
local function exactComposition(entries, manifest)
  local Resources = requireResources()
  local helper = SummaryAcceptanceFixture.preparationDoubles({})
  local family = manifest or SummaryPresentationFixture.manifest()
  local owner = Resources.new({
    cacheFs = portraitCache(entries),
    graphics = helper.graphics,
    text = helper.text,
    icons = helper.icons,
    imagePool = assert(helper.imagePool, "the doubles carry the shared image owner"),
    derivedAssets = helper.derivedAssets,
    manifest = family,
  })
  return { owner = owner, helper = helper, manifest = family }
end

---@param key string demand key
---@param selectors string[] full roster portrait identities in slot order
---@return table<string, unknown> lease demand over exact identities
local function exactDemand(key, selectors)
  local icons = {}
  for index, _ in ipairs(selectors) do
    icons[index] = "test-icon-" .. index
  end
  if #selectors == 0 then
    icons = { MonCache.iconSelector("EGG", 0, true) }
  end
  return {
    key = key,
    revision = 7,
    pictureEpoch = 1,
    portraitSelectors = selectors,
    iconKeys = icons,
    cryBanks = {},
  }
end

---@param helper table<string, unknown> preparation doubles
---@return table<string, integer> image request counts by cache-relative path
local function countPoolRequests(helper)
  local pool = assert(helper.imagePool, "the doubles carry the shared image owner")
  local inner = assert(pool.request, "the owner enrolls by path")
  local counts = {}
  pool.request = function(self, path, sampler, priority)
    counts[path] = (counts[path] or 0) + 1
    return inner(self, path, sampler, priority)
  end
  return counts
end

---@param lease table<string, unknown> live preparation lease
---@param demand table<string, unknown> current demand
---@return table<string, unknown> terminal prepare outcome (never pending)
local function prepareToTerminal(lease, demand)
  local outcome = nil
  for _ = 1, 12 do
    local ok, result = pcall(lease.prepare, lease, demand)
    Assert.isTrue(ok, "preparation answers instead of raising: " .. tostring(result))
    outcome = result
    Assert.isTrue(type(outcome.kind) == "string", "prepare outcomes name their kind")
    if outcome.kind ~= "pending" then
      return outcome
    end
  end
  error("preparation never settles for demand " .. tostring(demand.key), 0)
end

function T.exact_selectors_resolve_their_own_pages_and_absent_selectors_never_fall_back()
  local exact = MonCache.portraitSelector("CHIKORITA", 0, "female", true)
  local missing = MonCache.portraitSelector("CHIKORITA", 0, "male", true)
  local entries = {
    [MonCache.portraitSelector("CHIKORITA", 0, "male", false)] = portraitEntry(3),
    [MonCache.portraitSelector("CHIKORITA", 0, "female", false)] = portraitEntry(3),
    [exact] = portraitEntry(9),
  }
  local setup = exactComposition(entries)
  local lease = setup.owner:acquire()
  local ready = prepareToTerminal(lease, exactDemand("exact-alternate", { exact }))
  Assert.equal(ready.kind, "ready", "the exact alternate prepares")
  local requested = {}
  for _, record in ipairs(setup.helper.calls.portraitPages) do
    requested[#requested + 1] = record.pageId
  end
  Assert.deepEqual(requested, { 9 }, "only the exact identity page compiles")
  local assets = assert(ready.assets, "ready preparation carries its bundle")
  local portraits = assert(assets.portraits, "the bundle carries portrait accessors")
  Assert.notNil(portraits:image(exact), "the exact identity resolves its page image")
  Assert.notNil(portraits:quadFor(exact, 1), "the exact identity resolves its frame")
  lease:release()
  -- A well-formed identity with no generated entry must surface instead
  -- of silently adopting the same-species sibling page.
  local probeSetup = exactComposition(entries)
  local probe = probeSetup.owner:acquire()
  local refused = prepareToTerminal(probe, exactDemand("absent-identity", { missing }))
  Assert.equal(refused.kind, "failed", "identities without a generated page never adopt a sibling page")
  Assert.equal(#probeSetup.helper.calls.portraitPages, 0, "no sibling page compiles for the missing identity")
  probe:release()
  setup.owner:release()
  probeSetup.owner:release()
end

function T.cry_banks_compile_before_the_lease_turns_ready_and_failures_surface()
  local Resources = requireResources()
  local versions = SummaryAcceptanceFixture.readySummaryVersions()
  for _, versionId in ipairs(versions) do
    local setup = syntheticComposition({}, versionId)
    local owner = Resources.new(setup.newOptions())
    local lease = owner:acquire()
    local settled = prepareToTerminal(lease, syntheticDemand("syn-cry", 1))
    Assert.equal(settled.kind, "ready", versionId .. " prepares once its cry banks are ready")
    Assert.deepEqual(
      uniquePages(setup.helper.calls.cryBanks),
      { 152, 158 },
      versionId .. " requests exactly the demanded cry banks"
    )
    lease:release()
    owner:release()

    local failing = syntheticComposition({}, versionId)
    local options = failing.newOptions()
    options.derivedAssets = {
      requestMonPortraitPage = failing.helper.derivedAssets.requestMonPortraitPage,
      requestAudioBank = function()
        return nil, "test cry compilation is unavailable"
      end,
    }
    local failingOwner = Resources.new(options)
    local failingLease = failingOwner:acquire()
    local failed = prepareToTerminal(failingLease, syntheticDemand("syn-cry-fail", 1))
    Assert.equal(failed.kind, "failed", versionId .. " surfaces a cry bank failure")
    Assert.isTrue(tostring(failed.error):find("cry compilation", 1, true) ~= nil, versionId .. " names the cause")
    failingLease:release()
    failingOwner:release()
  end
end

-- An uncompiled portrait page has no generated PNG yet: the shared owner
-- fails its decode while the provisioner still reports pending, so the
-- lease must wait instead of surfacing the missing file. Once the page
-- compiles, the same lease settles without re-enrolling a failed decode.
function T.uncompiled_portrait_pages_wait_instead_of_failing_on_their_missing_file()
  local Resources = requireResources()
  local selector = MonCache.portraitSelector("CHIKORITA", 0, "male", false)
  local entries = { [selector] = portraitEntry(45) }
  local helper = SummaryAcceptanceFixture.preparationDoubles({})
  local family = SummaryPresentationFixture.manifest()
  local pagePath = MonCache.portraitPagePath(45)
  local compiled = false
  local portraitCalls = 0
  local derivedAssets = {
    requestMonPortraitPage = function(pageId, _)
      Assert.equal(pageId, 45, "portrait demand names its page")
      portraitCalls = portraitCalls + 1
      if not compiled then
        return false, nil
      end
      return true, nil
    end,
    requestAudioBank = function()
      return true, nil
    end,
  }
  local sharedPool = assert(helper.imagePool, "the doubles carry the shared image owner")
  local portraitPolls = 0
  -- Simulate the missing generated PNG while the page is uncompiled: any
  -- portrait decode polled before compilation reports the production
  -- unreadable-file failure instead of staging.
  local failingPool = {}
  function failingPool:request(path, sampler, priority)
    return sharedPool:request(path, sampler, priority)
  end
  function failingPool:poll(token)
    if not compiled then
      portraitPolls = portraitPolls + 1
      return "failed", "unreadable cache file: soulsilver/" .. pagePath
    end
    return sharedPool:poll(token)
  end
  function failingPool:acquire(token)
    return sharedPool:acquire(token)
  end
  function failingPool:release(lease)
    return sharedPool:release(lease)
  end
  function failingPool:cancel(token)
    return sharedPool:cancel(token)
  end
  function failingPool:prune()
    return sharedPool:prune()
  end
  function failingPool:stats()
    return sharedPool:stats()
  end
  local owner = Resources.new({
    cacheFs = portraitCache(entries),
    graphics = helper.graphics,
    text = helper.text,
    icons = helper.icons,
    imagePool = failingPool,
    derivedAssets = derivedAssets,
    manifest = family,
  })
  local lease = owner:acquire()
  local waiting = assert(lease:prepare(exactDemand("missing-page", { selector })))
  Assert.equal(waiting.kind, "pending", "an uncompiled page waits instead of failing on its missing file")
  Assert.equal(portraitPolls, 0, "no portrait decode polls while the page is uncompiled")
  Assert.isTrue(portraitCalls >= 1, "the uncompiled page still enrolls its compilation")
  compiled = true
  local ready = prepareToTerminal(lease, exactDemand("missing-page", { selector }))
  Assert.equal(ready.kind, "ready", "the lease settles once the page compiles")
  Assert.notNil(ready.assets.portraits:image(selector), "the compiled page resolves its image")
  lease:release()
  owner:release()
end

function T.shared_paths_resolve_one_canonical_image()
  local selector = MonCache.portraitSelector("CHIKORITA", 0, "male", false)
  local family = SummaryPresentationFixture.manifest()
  local shared = assert(family.bars.hp.empty.image, "the health bar carries its empty image")
  family.bars.hp.full = { image = shared, width = 8, height = 8 }
  family.visuals.namedPanel = { image = shared, width = 8, height = 8 }
  local setup = exactComposition({ [selector] = portraitEntry(3) }, family)
  local counts = countPoolRequests(setup.helper)
  local poolInner = assert(setup.helper.poolInner, "the doubles carry the pool census")
  Assert.equal(poolInner:stats().physicalImages, 0, "construction stages no image before the first demand")
  local lease = setup.owner:acquire()
  local ready = prepareToTerminal(lease, exactDemand("shared-path", { selector }))
  Assert.equal(ready.kind, "ready", "the shared-path demand prepares")
  Assert.equal(
    poolInner.uploads,
    #SummaryCache.referencedPaths(family) + #MoveIconCache.referencedPaths(MoveIconFixture.manifest()) + 1,
    "one path borrows one physical image no matter how many records name it, plus the portrait page"
  )
  local assets = assert(ready.assets, "ready preparation carries its bundle")
  Assert.isTrue(
    type(assets.imageForPath) == "function",
    "the bundle resolves canonical images by their cache-relative path"
  )
  local emptyImage = assets.imageForPath(assert(family.bars.hp.empty.image, "the bar carries its path"))
  local fullImage = assets.imageForPath(assert(family.bars.hp.full.image, "the bar carries its path"))
  Assert.notNil(emptyImage, "the shared path resolves its realized image")
  Assert.isTrue(emptyImage == fullImage, "two records over one path share one live image")
  Assert.isTrue(
    assets.visualImage("namedPanel") == emptyImage,
    "a semantic name resolves the same canonical image as its path"
  )
  Assert.isFalse(
    pcall(assets.visualImage, "absent-record"),
    "a missing semantic record asserts instead of returning nil"
  )
  Assert.isFalse(
    pcall(assets.imageForPath, "assets/generated/summary/absent.png"),
    "an unprepared path asserts instead of returning nil"
  )
  Assert.equal(counts[shared], 1, "family visuals borrow the shared owner once on first demand")
  local repinned = prepareToTerminal(lease, exactDemand("shared-path", { selector }))
  Assert.equal(repinned.kind, "ready", "the pinned demand stays ready")
  Assert.equal(counts[shared], 1, "family visuals never re-enroll per open")
  lease:release()
  setup.owner:release()
end

function T.last_lease_release_returns_pages_while_family_visuals_stay_pinned()
  local selector = MonCache.portraitSelector("CHIKORITA", 0, "male", false)
  local setup = exactComposition({ [selector] = portraitEntry(3) })
  local owner = setup.owner
  local poolInner = assert(setup.helper.poolInner, "the doubles carry the pool census")
  local chromeCount = #SummaryCache.referencedPaths(setup.manifest)
    + #MoveIconCache.referencedPaths(MoveIconFixture.manifest())
  Assert.equal(poolInner:stats().physicalImages, 0, "construction stages no image before the first demand")
  local first = owner:acquire()
  local second = owner:acquire()
  local demand = exactDemand("shared-lifetime", { selector })
  local ready = prepareToTerminal(first, demand)
  Assert.equal(ready.kind, "ready", "the first lease prepares")
  local shader = assert(ready.assets.shader, "ready preparation carries its picture shader")
  local page = ready.assets.portraits:image(selector)
  local firstQuad = ready.assets.portraits:quadFor(selector, 1)
  local chromeSample = ready.assets.visualImage("detailBacking")
  Assert.equal(
    poolInner.uploads,
    chromeCount + 1,
    "the first demand pins chrome plus exactly the portrait page"
  )
  local shared = prepareToTerminal(second, demand)
  Assert.equal(shared.kind, "ready", "the second lease shares the demand")
  Assert.equal(
    poolInner.uploads,
    chromeCount + 1,
    "the shared demand borrows no duplicate physical image"
  )
  first:release()
  local surviving = prepareToTerminal(second, demand)
  Assert.equal(surviving.kind, "ready", "the surviving lease stays usable after the old release")
  Assert.isTrue(
    surviving.assets.portraits:image(selector) == page,
    "the surviving lease keeps its portrait page"
  )
  Assert.equal(page.releaseCount, 0, "the watched page stays borrowed while a live lease watches it")
  second:release()
  Assert.equal(
    poolInner:stats().outstandingLeases,
    chromeCount,
    "the last release returns the portrait borrow while chrome stays pinned"
  )
  Assert.equal(page.releaseCount, 0, "the returned page rests idle instead of freeing synchronously")
  Assert.equal(chromeSample.releaseCount, 0, "the family visuals outlive their leases")
  -- The shared idle limit bounds physical retention: the idle portrait
  -- frees exactly once while pinned chrome stays resident regardless of
  -- idle age.
  poolInner:prune()
  Assert.equal(page.releaseCount, 1, "the idle trim frees the returned portrait page exactly once")
  Assert.equal(chromeSample.releaseCount, 0, "the trim keeps pinned chrome resident")
  Assert.isTrue(shader.released ~= true, "the picture shader outlives its leases")
  local third = owner:acquire()
  local rebuilt = prepareToTerminal(third, exactDemand("shared-lifetime", { selector }))
  Assert.equal(rebuilt.kind, "ready", "a later lease reacquires after the last release")
  Assert.equal(rebuilt.assets.shader, shader, "reacquisition reuses the resident picture shader")
  Assert.equal(poolInner.uploads, chromeCount + 2, "reacquisition borrows a fresh portrait page only")
  Assert.isTrue(
    rebuilt.assets.portraits:image(selector) ~= page,
    "reacquisition never revives the trimmed handle"
  )
  Assert.equal(page.releaseCount, 1, "reacquisition never touches trimmed handles")
  local rebuiltQuad = rebuilt.assets.portraits:quadFor(selector, 1)
  Assert.isTrue(rebuiltQuad ~= firstQuad, "the trimmed page rebuilds its quads instead of aliasing freed art")
  Assert.deepEqual(
    { x = rebuiltQuad.x, y = rebuiltQuad.y, w = rebuiltQuad.w, h = rebuiltQuad.h },
    { x = firstQuad.x, y = firstQuad.y, w = firstQuad.w, h = firstQuad.h },
    "rebuilt quads keep their geometry"
  )
  Assert.equal(setup.helper.calls.iconReleases, 0, "reacquisition never releases the borrowed icon provider")
  third:release()
  owner:release()
  Assert.equal(poolInner:stats().outstandingLeases, 0, "the owner release returns every remaining borrow")
  poolInner:prune()
  Assert.equal(poolInner:stats().physicalImages, 0, "the idle trim reclaims every returned physical image")
  Assert.equal(page.releaseCount, 1, "the owner release never double-frees the trimmed page")
  Assert.equal(chromeSample.releaseCount, 1, "the owner release frees every pinned visual exactly once")
end

function T.egg_only_demand_requests_no_portrait_page()
  local setup = exactComposition({})
  local lease = setup.owner:acquire()
  local ready = prepareToTerminal(lease, exactDemand("egg-only", {}))
  Assert.equal(ready.kind, "ready", "an egg-only roster still prepares its visuals")
  Assert.equal(#setup.helper.calls.portraitPages, 0, "eggs request zero portrait pages")
  Assert.notNil(ready.assets.shader, "egg-only preparation keeps its picture shader")
  lease:release()
  setup.owner:release()
end

function T.one_new_portrait_page_realizes_per_prepare_call()
  local one = MonCache.portraitSelector("CHIKORITA", 0, "male", false)
  local other = MonCache.portraitSelector("CHIKORITA", 0, "female", false)
  local setup = exactComposition({ [one] = portraitEntry(3), [other] = portraitEntry(9) })
  local lease = setup.owner:acquire()
  local demand = exactDemand("two-pages", { one, other })
  local outcome = assert(lease:prepare(demand), "prepare reports its lease state")
  Assert.equal(outcome.kind, "pending", "a cold two-page demand waits after one realization")
  local ready = prepareToTerminal(lease, demand)
  Assert.equal(ready.kind, "ready", "both pages settle")
  local seen = {}
  for _, record in ipairs(setup.helper.calls.portraitPages) do
    seen[record.pageId] = (seen[record.pageId] or 0) + 1
  end
  Assert.equal(seen[3], 1, "each demanded page compiles once")
  Assert.equal(seen[9], 1, "each demanded page compiles once")
  lease:release()
  setup.owner:release()
end

function T.absent_selector_failure_names_the_selector()
  local selector = MonCache.portraitSelector("CHIKORITA", 0, "male", false)
  local missing = MonCache.portraitSelector("TOTODILE", 0, "female", true)
  local setup = exactComposition({ [selector] = portraitEntry(3) })
  local lease = setup.owner:acquire()
  local refused = prepareToTerminal(lease, exactDemand("absent-cause", { missing }))
  Assert.equal(refused.kind, "failed", "identities without a generated page fail instead of falling back")
  Assert.isTrue(tostring(refused.error):find(missing, 1, true) ~= nil, "the failure names the missing identity")
  Assert.equal(#setup.helper.calls.portraitPages, 0, "no page compiles for the missing identity")
  lease:release()
  setup.owner:release()
end

function T.duplicate_selectors_coalesce_to_one_page()
  local selector = MonCache.portraitSelector("CHIKORITA", 0, "male", false)
  local setup = exactComposition({ [selector] = portraitEntry(3) })
  local counts = countPoolRequests(setup.helper)
  local lease = setup.owner:acquire()
  local ready = prepareToTerminal(lease, exactDemand("duplicates", { selector, selector }))
  Assert.equal(ready.kind, "ready", "duplicated identities prepare")
  Assert.equal(#setup.helper.calls.portraitPages, 1, "one shared page compiles once")
  Assert.equal(counts[MonCache.portraitPagePath(3)], 1, "one shared page borrows once")
  local assets = assert(ready.assets, "ready preparation carries its bundle")
  Assert.isTrue(
    assets.portraits:image(selector) == assets.portraits:image(selector),
    "duplicated identities share one page image"
  )
  lease:release()
  setup.owner:release()
end

-- Overlapping per-open picture epochs over one shared portrait page: two
-- leases prepare changing epochs, the first cancels, the survivor trims
-- and redraws. Every independent icon, portrait, and cry prerequisite is
-- enrolled before the first pending answer; the survivor keeps one common
-- physical portrait image with no late resurrection of the replaced page
-- and no double free, while the picture shader and shared quads outlive
-- the turnover. A later failing page cannot disturb the retained page.
function T.concurrent_picture_epochs_share_one_portrait_image_and_enroll_before_pending()
  local Resources = requireResources()
  local shared = MonCache.portraitSelector("CHIKORITA", 0, "male", false)
  local firstOnly = MonCache.portraitSelector("CHIKORITA", 0, "female", false)
  local secondOnly = MonCache.portraitSelector("TOTODILE", 0, "male", false)
  local entries = {
    [shared] = portraitEntry(3),
    [firstOnly] = portraitEntry(9),
    [secondOnly] = portraitEntry(12),
  }
  local helper = SummaryAcceptanceFixture.preparationDoubles({})
  local baseIcons = helper.icons
  local iconRounds = 0
  local icons = {
    image = baseIcons.image,
    quadFor = baseIcons.quadFor,
    dimensions = baseIcons.dimensions,
    cancelPreparation = baseIcons.cancelPreparation,
    release = baseIcons.release,
  }
  function icons.prepareKeys(_, keys)
    iconRounds = iconRounds + 1
    helper.calls.iconPrepares[#helper.calls.iconPrepares + 1] = keys
    if iconRounds <= 2 then
      return false, nil
    end
    return true, nil
  end
  local baseDerived = helper.derivedAssets
  local cryWaits = { [201] = 1 }
  local derivedAssets = {
    requestMonPortraitPage = function(pageId, priority)
      return baseDerived.requestMonPortraitPage(pageId, priority)
    end,
    requestAudioBank = function(bankId, priority)
      if cryWaits[bankId] ~= nil and cryWaits[bankId] > 0 then
        cryWaits[bankId] = cryWaits[bankId] - 1
        helper.calls.cryBanks[#helper.calls.cryBanks + 1] = { pageId = bankId }
        return false, nil
      end
      return baseDerived.requestAudioBank(bankId, priority)
    end,
  }
  local sharedPool = assert(helper.imagePool, "the doubles carry the shared image owner")
  local poolInner = assert(helper.poolInner, "the doubles carry the pool census")
  local decodeRequests = {}
  local pool = {}
  function pool:request(path, sampler, priority)
    decodeRequests[path] = (decodeRequests[path] or 0) + 1
    return sharedPool:request(path, sampler, priority)
  end
  function pool:poll(token)
    return sharedPool:poll(token)
  end
  function pool:acquire(token)
    return sharedPool:acquire(token)
  end
  function pool:release(lease)
    return sharedPool:release(lease)
  end
  function pool:cancel(token)
    return sharedPool:cancel(token)
  end
  function pool:prune()
    return sharedPool:prune()
  end
  function pool:stats()
    return sharedPool:stats()
  end
  local family = SummaryPresentationFixture.manifest()
  local owner = Resources.new({
    cacheFs = portraitCache(entries),
    graphics = helper.graphics,
    text = helper.text,
    icons = icons,
    imagePool = pool,
    derivedAssets = derivedAssets,
    manifest = family,
  })
  Assert.equal(poolInner:stats().physicalImages, 0, "construction stages no image before the first demand")
  Assert.equal(#helper.graphics.shaders, 1, "construction keeps the non-image picture shader resident")

  local function demand(key, epoch, selectors, banks)
    return {
      key = key,
      revision = 7,
      pictureEpoch = epoch,
      portraitSelectors = selectors,
      iconKeys = { "test-icon-a", "test-icon-b" },
      cryBanks = banks,
    }
  end
  local function requestedIds(records)
    local found = {}
    for _, record in ipairs(records) do
      found[record.pageId] = (found[record.pageId] or 0) + 1
    end
    return found
  end
  local sharedPath = MonCache.portraitPagePath(3)
  local firstPath = MonCache.portraitPagePath(9)

  local demandA = demand("first-picture", 1, { shared, firstOnly }, { 152, 158 })
  local first = owner:acquire()
  local waiting = assert(first:prepare(demandA), "prepare reports its lease state")
  Assert.equal(waiting.kind, "pending", "the first round waits on the icon pages")
  local enrolledPages = requestedIds(helper.calls.portraitPages)
  Assert.equal(enrolledPages[3], 1, "the shared portrait page enrolls before the first pending answer")
  Assert.equal(enrolledPages[9], 1, "the first-only portrait page enrolls before the first pending answer")
  local enrolledBanks = requestedIds(helper.calls.cryBanks)
  Assert.equal(enrolledBanks[152], 1, "the first cry bank enrolls before the first pending answer")
  Assert.equal(enrolledBanks[158], 1, "the second cry bank enrolls before the first pending answer")
  Assert.equal(decodeRequests[sharedPath], 1, "the shared page enrolls before the first pending answer")
  Assert.equal(decodeRequests[firstPath], 1, "the first-only page enrolls before the first pending answer")
  Assert.equal(
    poolInner:stats().outstandingLeases,
    1,
    "the first round adopts one portrait page while icons are still pending"
  )
  local waitingAgain = assert(first:prepare(demandA), "prepare reports its lease state")
  Assert.equal(waitingAgain.kind, "pending", "the second round still waits on the icon pages")
  Assert.equal(
    poolInner:stats().outstandingLeases,
    2,
    "both portrait leases land while icons are still pending"
  )
  local readyA = prepareToTerminal(first, demandA)
  Assert.equal(readyA.kind, "ready", "the first picture settles once its icons arrive")
  Assert.equal(readyA.key, "first-picture", "readiness carries the first demand key")
  local bundleA = assert(readyA.assets, "ready preparation carries its bundle")
  local sharedImage = bundleA.portraits:image(shared)
  local firstImage = bundleA.portraits:image(firstOnly)
  local sharedQuad = bundleA.portraits:quadFor(shared, 1)
  local firstQuad = bundleA.portraits:quadFor(firstOnly, 1)
  local shader = assert(bundleA.shader, "ready preparation carries its picture shader")
  local uploadsAfterA = poolInner.uploads

  local demandB = demand("second-picture", 2, { shared, secondOnly }, { 152, 158 })
  local second = owner:acquire()
  local readyB = prepareToTerminal(second, demandB)
  Assert.equal(readyB.kind, "ready", "the overlapping picture settles on its changed epoch")
  Assert.equal(readyB.key, "second-picture", "the replacement key never adopts the stale picture")
  local bundleB = assert(readyB.assets, "ready preparation carries its bundle")
  Assert.isTrue(bundleB.portraits:image(shared) == sharedImage, "overlapping leases share one physical portrait image")
  local settledPages = requestedIds(helper.calls.portraitPages)
  Assert.equal(settledPages[3], 1, "the shared page compiles once across overlapping leases")
  Assert.equal(settledPages[12], 1, "the second-only page compiles once")
  Assert.equal(
    poolInner.uploads - uploadsAfterA,
    1,
    "the overlapping picture borrows only its new second-only page"
  )
  local chromeCount = #SummaryCache.referencedPaths(family)
    + #MoveIconCache.referencedPaths(MoveIconFixture.manifest())
  Assert.equal(
    uploadsAfterA,
    chromeCount + 2,
    "the first picture pins chrome plus its two portrait pages with no duplicates"
  )

  first:release()
  local redrawn = prepareToTerminal(second, demandB)
  Assert.equal(redrawn.kind, "ready", "the surviving lease stays ready after the old release")
  Assert.equal(redrawn.key, "second-picture", "the surviving picture is unchanged by the trim")
  Assert.equal(firstImage.releaseCount, 0, "the returned page rests idle instead of freeing synchronously")
  -- The shared idle limit bounds physical retention: the explicit trim
  -- frees the replaced page exactly once while the shared page survives.
  local trimmed = poolInner:prune()
  Assert.equal(trimmed, 1, "the trim reclaims exactly the replaced portrait page")
  Assert.equal(firstImage.releaseCount, 1, "the replaced page frees exactly once on trim")
  Assert.equal(sharedImage.releaseCount, 0, "the shared page survives the trim")
  local bundleB2 = assert(redrawn.assets, "ready preparation carries its bundle")
  Assert.isTrue(bundleB2.portraits:image(shared) == sharedImage, "the second picture still draws the same image")
  Assert.isTrue(bundleB2.shader == shader, "the picture shader outlives the lease turnover")
  Assert.isTrue(bundleB2.portraits:quadFor(shared, 1) == sharedQuad, "shared quads stay resolved with their page")
  Assert.equal(requestedIds(helper.calls.portraitPages)[9], 1, "the cancelled page never resurrects")
  Assert.isFalse(pcall(first.prepare, first, demandA), "the cancelled lease never prepares again")
  local chromeSample = bundleB2.visualImage("detailBacking")

  local revived = owner:acquire()
  local readyAgain = prepareToTerminal(revived, demand("first-picture-again", 3, { firstOnly }, { 152 }))
  Assert.equal(readyAgain.kind, "ready", "a later lease reacquires the dropped page")
  local rebuilt = readyAgain.assets.portraits:quadFor(firstOnly, 1)
  Assert.isTrue(rebuilt ~= firstQuad, "the dropped page rebuilds its quads instead of aliasing freed art")
  Assert.deepEqual(
    { x = rebuilt.x, y = rebuilt.y, w = rebuilt.w, h = rebuilt.h },
    { x = firstQuad.x, y = firstQuad.y, w = firstQuad.w, h = firstQuad.h },
    "rebuilt quads keep their geometry"
  )
  revived:release()

  local demandC = demand("third-picture", 3, { shared }, { 201 })
  local cryWaiting = assert(second:prepare(demandC), "prepare reports its lease state")
  Assert.equal(cryWaiting.kind, "pending", "a pending cry bank waits even with its portrait cached")
  local waitedBanks = requestedIds(helper.calls.cryBanks)
  Assert.isTrue((waitedBanks[201] or 0) >= 1, "the cry bank enrolls even with its portrait cached")
  local readyC = prepareToTerminal(second, demandC)
  Assert.equal(readyC.kind, "ready", "the cached portrait settles once its cry bank arrives")
  Assert.equal(readyC.key, "third-picture", "readiness carries the third demand key")

  local missing = MonCache.portraitSelector("MEW", 0, "male", false)
  local uploadsBefore = poolInner.uploads
  local fourth = owner:acquire()
  local refused = prepareToTerminal(fourth, demand("fourth-picture", 4, { shared, missing }, { 152 }))
  Assert.equal(refused.kind, "failed", "a page without generated art fails instead of falling back")
  Assert.isTrue(
    tostring(refused.error):find(missing, 1, true) ~= nil,
    "the failure names the missing portrait identity"
  )
  Assert.equal(poolInner.uploads, uploadsBefore, "the failed page borrows no image")
  Assert.equal(sharedImage.releaseCount, 0, "the retained page survives the sibling failure")
  Assert.isTrue(bundleB2.portraits:image(shared) == sharedImage, "the live lease still draws after the sibling failure")
  fourth:release()

  second:release()
  owner:release()
  Assert.equal(poolInner:stats().outstandingLeases, 0, "the owner release returns every remaining borrow")
  poolInner:prune()
  Assert.equal(poolInner:stats().physicalImages, 0, "the idle trim reclaims every returned physical image")
  Assert.equal(sharedImage.releaseCount, 1, "the shared page frees exactly once with no double free")
  Assert.equal(firstImage.releaseCount, 1, "the replaced page stays freed exactly once")
  Assert.equal(chromeSample.releaseCount, 1, "the pinned chrome frees exactly once")
  Assert.equal(helper.calls.iconReleases, 0, "the borrowed icon provider outlives the owner")
end

function T.runtime_summary_binding_is_identity_qualified()
  local FieldRuntime = require("game.hgss.src.field.FieldRuntime")
  local runtime = {}
  local first = FieldRuntime.bindSummaryPreparation(runtime, function()
    error("no lease in the binding contract", 0)
  end)
  Assert.isTrue(type(first) == "number", "binding answers its identity")
  Assert.isFalse(
    pcall(FieldRuntime.bindSummaryPreparation, runtime, function() end),
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
    derivedAssets = { "move-icons:global", "summary:global" },
  },
  tests = T,
}
