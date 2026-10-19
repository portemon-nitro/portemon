-- The bounded per-open resource owner behind the field Pokedex: demand
-- validation, whole-view publication over the shared image pool, stale
-- completion rejection, fixed current/pending bounds, incremental
-- preparation, failure unwinding, and exactly-once release. Icon-only
-- readiness never retires a visible page. The shared pool is faked at its
-- public borrow boundary; no renderer, GPU, ROM, or worker is touched.

local Assert = require("tests.support.Assert")
local Fixture = require("tests.support.PokedexPresentationFixture")
local SharedImagePoolFake = require("tests.support.SharedImagePoolFake")

local OWNER_MODULE = "game.hgss.src.pokedex.PokedexPresentationResources"

local T = {}

---@param behavior string missing resource behavior under test
---@return table the loaded per-open resource owner
local function requirePresent(behavior)
  local ok, loaded = pcall(require, OWNER_MODULE)
  Assert.isTrue(ok, "missing aggregate view-level resource owner: " .. behavior .. " (" .. OWNER_MODULE .. ")")
  assert(loaded ~= nil, "the resource owner module loads")
  return loaded --[[@as table]]
end

---@param pool table shared image pool double under test
---@return table owner construction arguments over synthetic catalogs
local function ownerArgs(pool)
  local monCatalog, catalog = Fixture.catalogs()
  local PokedexCache = require("libs.assets.src.PokedexCache")
  return {
    imagePool = pool,
    monCatalog = monCatalog,
    catalog = catalog,
    cacheFs = {
      loadLua = function(_)
        return { schema = PokedexCache.SCHEMA, animations = {}, chrome = {} }
      end,
    },
    derivedAssets = {
      requestPokedex = function(_)
        return true
      end,
    },
  }
end

---@param purpose string lease purpose under test
---@param key string demand generation key
---@return table demand one fully specified browser demand
local function browserDemand(purpose, key)
  local DexFixture = require("libs.hgss.tests.mons.pokedex_dex_fixture")
  local monCatalog, catalog = Fixture.catalogs()
  local owner = Fixture.ownerWithHistory(monCatalog, catalog)
  local specimen = owner:describe(DexFixture.makeMon(monCatalog, { species = "CHIKORITA", personality = 0 }))
  return {
    key = key,
    purpose = purpose,
    pageRole = "grid",
    dexMode = "johto",
    language = "native",
    iconKeys = { "CHIKORITA/f0" },
    pictures = {
      { slot = "selected", specimen = specimen, facing = "front", mode = "portrait" },
    },
    text = {},
  }
end

function T.browser_lease_holds_pending_until_the_whole_view_is_ready()
  local Owner = requirePresent("whole-view publication")
  local pool = SharedImagePoolFake.new()
  local owner = Owner.new(ownerArgs(pool))
  local lease = owner:acquire({ purpose = "browser" })
  local first = lease:prepare(browserDemand("browser", "page-a"))
  Assert.equal(first.kind, "pending", "an unprepared page stays pending")
  local committed = nil
  for _ = 1, 64 do
    local outcome = lease:prepare(browserDemand("browser", "page-b"))
    if outcome.kind == "ready" then
      committed = outcome
      break
    end
    Assert.equal(outcome.kind, "pending", "partial readiness never publishes")
  end
  Assert.notNil(committed, "bounded preparation converges on a complete bundle")
  Assert.equal(committed.key, "page-b", "the ready outcome carries its matching generation key")
  Assert.isTrue(
    committed.assets.animations == committed.assets.manifest.animations,
    "the ready bundle aliases one immutable animation table"
  )
  lease:release()
  owner:release()
end

function T.stale_completion_never_replaces_the_committed_view()
  local Owner = requirePresent("stale generation rejection")
  local pool = SharedImagePoolFake.new()
  local owner = Owner.new(ownerArgs(pool))
  local lease = owner:acquire({ purpose = "browser" })
  local ready = nil
  for _ = 1, 64 do
    local outcome = lease:prepare(browserDemand("browser", "page-b"))
    if outcome.kind == "ready" then
      ready = outcome
      break
    end
  end
  Assert.notNil(ready, "the replacement page becomes ready")
  local late = lease:prepare(browserDemand("browser", "page-a"))
  Assert.isTrue(
    late.kind == "pending" or late.key ~= "page-a" or late.assets == ready.assets,
    "a superseded generation never publishes over the committed view"
  )
  lease:release()
  owner:release()
end

function T.pending_union_stays_within_fixed_icon_and_picture_bounds()
  local Owner = requirePresent("current plus pending demand bounds")
  local pool = SharedImagePoolFake.new()
  local owner = Owner.new(ownerArgs(pool))
  local lease = owner:acquire({ purpose = "browser" })
  lease:prepare(browserDemand("browser", "page-a"))
  for _ = 1, 8 do
    lease:prepare(browserDemand("browser", "page-b"))
  end
  local stats = pool:stats()
  Assert.isTrue(
    stats.outstandingLeases <= 60,
    "committed plus pending icon interests stay within the arbitrary-replacement bound"
  )
  lease:release()
  owner:release()
  local settled = pool:stats()
  Assert.equal(settled.outstandingLeases, 0, "releasing the lease returns every borrowed interest")
end

function T.injected_portrait_failure_keeps_the_committed_view_and_its_cause()
  local Owner = requirePresent("attributed preparation failure")
  local pool = SharedImagePoolFake.new()
  pool:failAfterUploads(0, "synthetic portrait upload failure")
  local owner = Owner.new(ownerArgs(pool))
  local lease = owner:acquire({ purpose = "browser" })
  local outcome = lease:prepare(browserDemand("browser", "page-a"))
  Assert.equal(outcome.kind, "failed", "an unready required family fails the demand")
  Assert.isTrue(
    type(outcome.error) == "string" and outcome.error ~= "",
    "the failure carries its nonempty original cause"
  )
  pool:clearFailure()
  lease:release()
  owner:release()
  Assert.equal(pool:stats().outstandingLeases, 0, "failure unwinds every pending interest")
end

function T.registration_demand_prepares_before_any_battle_state_exists()
  local Owner = requirePresent("detached registration preparation")
  local pool = SharedImagePoolFake.new()
  local owner = Owner.new(ownerArgs(pool))
  local monCatalog, catalog = Fixture.catalogs()
  local dexOwner = Fixture.ownerWithHistory(monCatalog, catalog)
  local snapshot = Fixture.registrationSnapshot(dexOwner, monCatalog, "TOTODILE", 0)
  local lease = owner:acquire({ purpose = "registration" })
  local ready = nil
  for _ = 1, 64 do
    local outcome = lease:prepare(Fixture.registrationDemand(snapshot, "card-a"))
    if outcome.kind == "ready" then
      ready = outcome
      break
    elseif outcome.kind == "failed" then
      error("the detached registration demand must stay preparable: " .. tostring(outcome.error), 0)
    end
  end
  Assert.notNil(ready, "the detached card demand converges on a complete bundle")
  Assert.notNil(
    ready.assets.messages.registrationAnnouncement,
    "the ready card bundle carries its formatted announcement"
  )
  Assert.equal(ready.assets.renderer ~= nil, true, "the ready bundle borrows the one shared renderer")
  lease:release()
  lease:release()
  owner:release()
end

function T.owner_release_reclaims_children_before_borrowed_services()
  local Owner = requirePresent("child-first teardown ordering")
  local pool = SharedImagePoolFake.new()
  local owner = Owner.new(ownerArgs(pool))
  local first = owner:acquire({ purpose = "browser" })
  local second = owner:acquire({ purpose = "registration" })
  first:release()
  second:release()
  owner:release()
  owner:release()
  Assert.equal(pool:stats().outstandingLeases, 0, "owner release reclaims every child membership")
end

function T.surfaces_realize_across_separate_prepares_under_one_allowance()
  local Owner = requirePresent("finite serial surface ledger")
  local FakeGraphics = require("tests.support.FakeGraphics")
  local pool = SharedImagePoolFake.new()
  local graphics = FakeGraphics.new()
  local createdAt = {}
  local prepares = 0
  local originalCanvas = graphics.newCanvas
  graphics.newCanvas = function(width, height)
    createdAt[#createdAt + 1] = prepares
    return originalCanvas(width, height)
  end
  local args = ownerArgs(pool)
  args.graphics = graphics
  local owner = Owner.new(args)
  local lease = owner:acquire({ purpose = "browser" })
  local ready = nil
  for _ = 1, 64 do
    prepares = prepares + 1
    local outcome = lease:prepare(browserDemand("browser", "surface-page"))
    if outcome.kind == "ready" then
      ready = outcome
      break
    end
    Assert.equal(outcome.kind, "pending", "surface admission spans multiple prepares")
  end
  Assert.notNil(ready, "bounded preparation converges with host canvases")
  Assert.equal(#createdAt, 6, "the six serial surfaces realize exactly once")
  local distinct = {}
  for _, at in ipairs(createdAt) do
    distinct[at] = true
  end
  local distinctCount = 0
  for _ in pairs(distinct) do
    distinctCount = distinctCount + 1
  end
  Assert.equal(distinctCount, 6, "the six surfaces realize across separate prepare calls")
  local surfaces = assert(ready.assets.surfaces, "the ready bundle carries its serial surfaces")
  Assert.equal(#surfaces, 6, "the lease owns four BG planes plus OBJ color and metadata")
  for index, surface in ipairs(surfaces) do
    Assert.isTrue(surface.canvas ~= nil, "serial surface " .. index .. " realizes its canvas")
    Assert.equal(surface.width, 256, "serial surfaces stay 256 wide")
    Assert.equal(surface.height, 192, "serial surfaces stay 192 tall")
  end
  -- Headless draws against the recording seam stay covered where the
  -- compiled page roles exist; here the ledger owns the bound.
  lease:release()
  owner:release()
  for _, surface in ipairs(surfaces) do
    Assert.isTrue(surface.canvas == nil, "lease release returns every serial surface")
  end
end

return { tests = T }
