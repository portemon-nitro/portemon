-- Field-owned Summary preparation lifetimes: one resource owner hands out
-- per-open demand leases over bounded portrait demand, isolates overlapping
-- leases by demand key and picture epoch, surfaces failures instead of
-- hanging, and releases every owned GPU object exactly once while borrowed
-- icon, queue, and text collaborators stay alive.

local Assert = require("tests.support.Assert")
local SummaryAcceptanceFixture = require("tests.support.SummaryAcceptanceFixture")
local SummaryModel = require("libs.hgss.src.ui.SummaryModel")
local MonCache = require("libs.assets.src.MonCache")

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
  for _, row in ipairs(assert(facts.roster, "facts carry the party roster")) do
    iconKeys[#iconKeys + 1] = assert(row.iconKey, "roster rows carry their icon key")
    if row.isEgg ~= true then
      selectors[#selectors + 1] = assert(row.portraitSelector, "non-egg rows carry their portrait identity")
    end
  end
  return {
    key = key,
    revision = service:partyRevision(),
    pictureEpoch = epoch,
    portraitSelectors = selectors,
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
        cacheFs = CacheFs.forVersion(versionId),
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
    portraitSelectors = {
      MonCache.portraitSelector("CHIKORITA", 0, "male", false),
      MonCache.portraitSelector("TOTODILE", 0, "male", false),
    },
    iconKeys = { "CHIKORITA/f0", "TOTODILE/f0" },
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
    bad.preparationQueue = nil
    Assert.isFalse(pcall(Resources.new, bad), versionId .. " requires its image queue")
    local owner = Resources.new(setup.newOptions())
    local lease = owner:acquire()
    Assert.isFalse(
      pcall(lease.prepare, lease, { key = "", revision = 1, pictureEpoch = 0, portraitSelectors = {}, iconKeys = {} }),
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
    Assert.equal(outcome.kind, "pending", versionId .. " waits on gated decodes")
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
    Assert.equal(ready.kind, "ready", versionId .. " lands late worker results for a live lease")
    Assert.equal(ready.key, "late", versionId .. " qualifies late results by the live demand key")
    second:release()
    owner:release()
  end
end

-- Counts image-queue requests per cache-relative path from installation
-- onward: the returned table fills as preparation issues requests, so
-- callers install it before preparing and read per-path totals after
-- the demand settles.
---@param helper table<string, unknown> preparation doubles
---@return table<string, integer> live per-path request counts
local function countQueueRequests(helper)
  local counts = {}
  local queue = assert(helper.preparationQueue, "the doubles carry the image queue")
  local inner = assert(queue.request, "the image queue issues requests")
  queue.request = function(_, kind, path, priority)
    counts[path] = (counts[path] or 0) + 1
    return inner(_, kind, path, priority)
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
    local counts = countQueueRequests(setup.helper)
    local owner = Resources.new(setup.newOptions())
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
      Assert.equal(counts[image], 1, versionId .. " decodes frame " .. image .. " once through its canonical path")
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
    Assert.equal(path, MonCache.portraitManifestPath(), "portrait reads name the portrait manifest")
    return { entries = entries }
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
    preparationQueue = helper.preparationQueue,
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
  }
end

---@param helper table<string, unknown> preparation doubles
---@return table<string, integer> decode request counts by cache-relative path
local function countQueueRequests(helper)
  local queue = assert(helper.preparationQueue, "the doubles carry the image queue")
  local inner = assert(queue.request, "the queue requests by path")
  local counts = {}
  queue.request = function(self, kind, path, priority)
    counts[path] = (counts[path] or 0) + 1
    return inner(self, kind, path, priority)
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
  Assert.equal(
    #probeSetup.helper.calls.portraitPages,
    0,
    "no sibling page compiles for the missing identity"
  )
  probe:release()
  setup.owner:release()
  probeSetup.owner:release()
end

function T.shared_paths_resolve_one_canonical_image()
  local selector = MonCache.portraitSelector("CHIKORITA", 0, "male", false)
  local family = SummaryPresentationFixture.manifest()
  local shared = assert(family.bars.hp.empty.image, "the health bar carries its empty image")
  family.bars.hp.full = { image = shared, width = 8, height = 8 }
  family.visuals.namedPanel = { image = shared, width = 8, height = 8 }
  local setup = exactComposition({ [selector] = portraitEntry(3) }, family)
  local counts = countQueueRequests(setup.helper)
  local lease = setup.owner:acquire()
  local ready = prepareToTerminal(lease, exactDemand("shared-path", { selector }))
  Assert.equal(ready.kind, "ready", "the shared-path demand prepares")
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
  Assert.equal(counts[shared], 1, "one path decodes once no matter how many records name it")
  lease:release()
  setup.owner:release()
end

function T.last_lease_release_frees_and_reacquire_rebuilds()
  local selector = MonCache.portraitSelector("CHIKORITA", 0, "male", false)
  local setup = exactComposition({ [selector] = portraitEntry(3) })
  local owner = setup.owner
  local graphics = setup.helper.graphics
  local first = owner:acquire()
  local second = owner:acquire()
  local demand = exactDemand("shared-lifetime", { selector })
  local ready = prepareToTerminal(first, demand)
  Assert.equal(ready.kind, "ready", "the first lease prepares")
  local firstShader = assert(ready.assets.shader, "ready preparation carries its picture shader")
  local shared = prepareToTerminal(second, demand)
  Assert.equal(shared.kind, "ready", "the second lease shares the demand")
  first:release()
  local surviving = prepareToTerminal(second, demand)
  Assert.equal(surviving.kind, "ready", "the surviving lease stays usable after the old release")
  Assert.notNil(
    surviving.assets.portraits:image(selector),
    "the surviving lease keeps its portrait page"
  )
  Assert.isTrue(#graphics.images >= 1, "preparation realizes owned images")
  local realized = #graphics.images
  second:release()
  for index = 1, realized do
    Assert.equal(graphics.images[index].releaseCount, 1, "the last release frees each owned image exactly once")
  end
  Assert.isTrue(firstShader.released == true, "the last release frees the owned picture shader")
  local shaderCount = #graphics.shaders
  local third = owner:acquire()
  local rebuilt = prepareToTerminal(third, exactDemand("shared-lifetime", { selector }))
  Assert.equal(rebuilt.kind, "ready", "a later lease reacquires after the last release")
  Assert.isTrue(rebuilt.assets.shader ~= firstShader, "reacquisition rebuilds the picture shader")
  Assert.equal(#graphics.shaders, shaderCount + 1, "reacquisition compiles its shader again")
  Assert.isTrue(#graphics.images > realized, "reacquisition realizes fresh images")
  for index = 1, realized do
    Assert.equal(graphics.images[index].releaseCount, 1, "reacquisition never touches released handles")
  end
  Assert.equal(setup.helper.calls.iconReleases, 0, "reacquisition never releases the borrowed icon provider")
  Assert.equal(setup.helper.calls.queueReleases, 0, "reacquisition never releases the borrowed image queue")
  third:release()
  owner:release()
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
  Assert.isTrue(
    tostring(refused.error):find(missing, 1, true) ~= nil,
    "the failure names the missing identity"
  )
  Assert.equal(#setup.helper.calls.portraitPages, 0, "no page compiles for the missing identity")
  lease:release()
  setup.owner:release()
end

function T.duplicate_selectors_coalesce_to_one_page()
  local selector = MonCache.portraitSelector("CHIKORITA", 0, "male", false)
  local setup = exactComposition({ [selector] = portraitEntry(3) })
  local counts = countQueueRequests(setup.helper)
  local lease = setup.owner:acquire()
  local ready = prepareToTerminal(lease, exactDemand("duplicates", { selector, selector }))
  Assert.equal(ready.kind, "ready", "duplicated identities prepare")
  Assert.equal(#setup.helper.calls.portraitPages, 1, "one shared page compiles once")
  Assert.equal(counts[MonCache.portraitPagePath(3)], 1, "one shared page decodes once")
  local assets = assert(ready.assets, "ready preparation carries its bundle")
  Assert.isTrue(
    assets.portraits:image(selector) == assets.portraits:image(selector),
    "duplicated identities share one page image"
  )
  lease:release()
  setup.owner:release()
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
