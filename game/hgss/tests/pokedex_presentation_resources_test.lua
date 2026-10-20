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
        -- The synthetic manifest mirrors the generated page contract:
        -- empty per-role inventories behind the exercised roles plus
        -- the producer text bindings, so strict page closure validates
        -- without staging any chrome.
        local emptyPage = function()
          return {
            backgrounds = { information = {}, controls = {} },
            cells = {},
            sprites = {},
            windows = {},
          }
        end
        return {
          schema = PokedexCache.SCHEMA,
          animations = {},
          chrome = {},
          cells = {},
          sprites = {},
          windows = {},
          pages = { grid = emptyPage(), registration = emptyPage() },
          text = {
            ui = { bankId = 802 },
            entryByLanguage = {
              native = { nameBankId = 237, categoryBankId = 816, flavorBankId = 803 },
            },
            measureByProfile = { base = { heightBankId = 815, weightBankId = 813 } },
            registrationAnnouncement = { bankId = 197, messageId = 871 },
          },
        }
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

-- Two disjoint authored page closures over the shared pool: every
-- background/cell/sprite role resolves to a distinct chrome path so the
-- admitted set proves page closure instead of whole-manifest borrowing.
local function closureManifest()
  local PokedexCache = require("libs.assets.src.PokedexCache")
  local function background(chrome)
    return { chrome = chrome, layer = 0, x = 0, y = 0, priority = 0, paletteGroup = "group" }
  end
  local function cell(chrome)
    return {
      bounds = { x = 0, y = 0, width = 8, height = 8 },
      parts = { { chrome = chrome, source = { x = 0, y = 0, width = 8, height = 8 }, x = 0, y = 0 } },
    }
  end
  local function sprite(animation)
    return {
      pane = "controls",
      animation = animation,
      x = 0,
      y = 0,
      priority = 0,
      drawPriority = 0,
      paletteGroup = "group",
    }
  end
  local function page(bgRole, cellRole, spriteRole)
    return {
      backdrop = {
        information = { r = 0, g = 0, b = 0, a = 255 },
        controls = { r = 0, g = 0, b = 0, a = 255 },
      },
      backgrounds = { information = { background(bgRole) }, controls = {} },
      cells = { cellRole },
      sprites = { spriteRole },
      windows = {},
    }
  end
  return {
    schema = PokedexCache.SCHEMA,
    fonts = { body = 0, header = 4 },
    chrome = {
      ["grid.bg"] = { path = "pokedex/chrome/grid-bg", width = 256, height = 192 },
      ["grid.cell.art"] = { path = "pokedex/chrome/grid-cell", width = 8, height = 8 },
      ["results.bg"] = { path = "pokedex/chrome/results-bg", width = 256, height = 192 },
      ["results.cell.art"] = { path = "pokedex/chrome/results-cell", width = 8, height = 8 },
    },
    cells = {
      ["grid.cursor"] = cell("grid.cell.art"),
      ["results.cursor"] = cell("results.cell.art"),
    },
    animations = {
      ["grid.cursor.anim"] = { frames = { { cell = "grid.cursor", duration = 1 } } },
      ["results.cursor.anim"] = { frames = { { cell = "results.cursor", duration = 1 } } },
    },
    sprites = {
      ["grid.cursor.sprite"] = sprite("grid.cursor.anim"),
      ["results.cursor.sprite"] = sprite("results.cursor.anim"),
    },
    windows = {},
    text = {
      ui = { bankId = 802 },
      entryByLanguage = { native = { nameBankId = 237, categoryBankId = 816, flavorBankId = 803 } },
      measureByProfile = { base = { heightBankId = 815, weightBankId = 813 } },
      registrationAnnouncement = { bankId = 197, messageId = 871 },
    },
    pages = {
      grid = page("grid.bg", "grid.cursor", "grid.cursor.sprite"),
      results = page("results.bg", "results.cursor", "results.cursor.sprite"),
    },
  }
end

---@param pool table shared image pool double under test
---@return table owner construction arguments over the two-page closure manifest
local function closureOwnerArgs(pool)
  local args = ownerArgs(pool)
  local manifest = closureManifest()
  args.cacheFs = {
    loadLua = function(_)
      return manifest
    end,
  }
  return args
end

---@param role string authored page role under test
---@param key string demand generation key
---@return table demand one imageless browser demand for the page role
local function pageDemand(role, key)
  return {
    key = key,
    purpose = "browser",
    pageRole = role,
    dexMode = "johto",
    language = "native",
    iconKeys = {},
    pictures = {},
    text = {},
  }
end

---@param chrome table<string, unknown> committed chrome mapping under test
---@return string[] sorted adopted chrome roles
local function chromeRoles(chrome)
  local roles = {}
  for role in pairs(chrome) do
    roles[#roles + 1] = role
  end
  table.sort(roles)
  return roles
end

-- Each new page holds only its current source asset closure. The
-- grid bundle adopts exactly the grid background/cell/sprite roles; a
-- pending replacement never mutates the displayed generation; after the
-- results generation publishes only its own roles remain adopted.
function T.page_change_adopts_only_the_current_source_closure()
  local Owner = requirePresent("page-closed chrome adoption")
  local pool = SharedImagePoolFake.new()
  local owner = Owner.new(closureOwnerArgs(pool))
  local lease = owner:acquire({ purpose = "browser" })
  local first = nil
  for _ = 1, 64 do
    local outcome = lease:prepare(pageDemand("grid", "pokedex-grid"))
    if outcome.kind == "ready" then
      first = outcome
      break
    end
    Assert.equal(outcome.kind, "pending", "partial page readiness never publishes")
  end
  Assert.notNil(first, "the current page converges on a complete bundle")
  Assert.deepEqual(
    chromeRoles(first.assets.chrome),
    { "grid.bg", "grid.cell.art" },
    "the grid bundle holds only the grid closure"
  )
  local stepped = lease:prepare(pageDemand("results", "pokedex-results"))
  Assert.equal(stepped.kind, "pending", "a fresh generation never adopts on its enrollment call")
  Assert.deepEqual(
    chromeRoles(first.assets.chrome),
    { "grid.bg", "grid.cell.art" },
    "pending work leaves the committed bundle untouched"
  )
  local second = nil
  for _ = 1, 64 do
    local outcome = lease:prepare(pageDemand("results", "pokedex-results"))
    if outcome.kind == "ready" then
      second = outcome
      break
    end
    Assert.equal(outcome.kind, "pending", "partial replacement never publishes")
  end
  Assert.notNil(second, "the replacement page converges on a complete bundle")
  Assert.deepEqual(
    chromeRoles(second.assets.chrome),
    { "results.bg", "results.cell.art" },
    "the results bundle holds only the results closure"
  )
  Assert.isTrue(second.assets ~= first.assets, "replacement publishes a new bundle identity")
  lease:release()
  lease:release()
  owner:release()
  Assert.equal(pool:stats().outstandingLeases, 0, "close returns every adopted image interest")
end

-- A replacement that fails after adopting its first image cannot
-- publish, the previous committed bundle survives byte-identical, and
-- failure plus repeated disposal return every owned interest exactly once.
function T.failed_replacement_preserves_the_committed_bundle()
  local Owner = requirePresent("failure-after-partial-acquisition rollback")
  local pool = SharedImagePoolFake.new()
  local owner = Owner.new(closureOwnerArgs(pool))
  local lease = owner:acquire({ purpose = "browser" })
  local first = nil
  for _ = 1, 64 do
    local outcome = lease:prepare(pageDemand("grid", "pokedex-grid"))
    if outcome.kind == "ready" then
      first = outcome
      break
    end
  end
  Assert.notNil(first, "the grid page commits before the failing replacement")
  pool:failAfterUploads(1, "synthetic chrome upload failure")
  local failed = nil
  local published = nil
  for _ = 1, 64 do
    local outcome = lease:prepare(pageDemand("results", "pokedex-results"))
    if outcome.kind == "failed" then
      failed = outcome
      break
    end
    if outcome.kind == "ready" then
      published = outcome
      break
    end
    Assert.equal(outcome.kind, "pending", "the doomed generation stays pending until its failure surfaces")
  end
  Assert.isNil(published, "a generation with an unready image never publishes")
  Assert.notNil(failed, "the replacement reports its attributed failure")
  Assert.isTrue(
    type(failed.error) == "string" and failed.error ~= "",
    "the failure carries its original cause"
  )
  Assert.deepEqual(
    chromeRoles(first.assets.chrome),
    { "grid.bg", "grid.cell.art" },
    "the failed generation never mutates the committed bundle"
  )
  pool:clearFailure()
  local again = lease:prepare(pageDemand("grid", "pokedex-grid"))
  Assert.equal(again.kind, "ready", "the committed generation answers without new work")
  Assert.isTrue(again.assets == first.assets, "the committed bundle survives the failed replacement")
  lease:release()
  lease:release()
  owner:release()
  Assert.equal(pool:stats().outstandingLeases, 0, "failure and disposal return every owned interest")
end

-- A scripted message bank double behind the borrowed provider seam: banks
-- resolve canned source strings by entry, every acquisition and release
-- is counted, and unknown banks fail instead of inventing text.
---@param canned table<integer, table<integer, string>> source strings by bank and entry
---@return table provider double with an acquisition census
local function stubMessageProvider(canned)
  local provider = { acquires = {}, releases = {}, banks = canned }
  function provider:acquireBank(bankId)
    self.acquires[bankId] = (self.acquires[bankId] or 0) + 1
    if self.banks[bankId] == nil then
      return nil, "message bank " .. tostring(bankId) .. " is unavailable in the generated cache"
    end
    return { bankId = bankId }
  end
  function provider:get(bankId, messageId)
    local bank = self.banks[bankId]
    if bank == nil then
      return nil, "message bank " .. tostring(bankId) .. " is not acquired"
    end
    local text = bank[messageId]
    if text == nil then
      return nil, "message " .. tostring(messageId) .. " not in bank " .. tostring(bankId)
    end
    return { bankId = bankId, messageId = messageId, text = text }
  end
  function provider:releaseBank(bankId)
    self.releases[bankId] = (self.releases[bankId] or 0) + 1
  end
  return provider
end

-- Browser text resolves through borrowed banks: species slots by stable
-- catalog identity, measures by the demanded profile, numerics verbatim;
-- every shared bank joins the membership exactly once and a replacement
-- that drops text returns its banks exactly once.
function T.browser_text_resolves_through_borrowed_banks_once_per_bank()
  local Owner = requirePresent("borrowed message bank ownership")
  local pool = SharedImagePoolFake.new()
  local monCatalog = Fixture.catalogs()
  local speciesRecord = assert(monCatalog:species("CHIKORITA"), "the fixture catalog names its species")
  local nativeId = assert(speciesRecord.nativeId, "the fixture species carries its numeric identity")
  assert(type(nativeId) == "number", "the fixture species identity resolves numerically")
  local provider = stubMessageProvider({
    [237] = { [nativeId] = "CHIKORITA" },
    [816] = { [nativeId] = "Leaf" },
    [815] = { [nativeId] = "0.9m" },
  })
  local args = closureOwnerArgs(pool)
  args.messages = provider
  local owner = Owner.new(args)
  local lease = owner:acquire({ purpose = "browser" })
  local demand = pageDemand("grid", "pokedex-text")
  demand.text = {
    { role = "grid.seen-count", kind = "numeric", value = "2" },
    { role = "grid.selected-name", kind = "species_name", species = "CHIKORITA", language = "native" },
    { role = "entry.category", kind = "category", species = "CHIKORITA", language = "native" },
    { role = "entry.height", kind = "height", species = "CHIKORITA" },
  }
  local ready = nil
  for _ = 1, 64 do
    local outcome = lease:prepare(demand)
    if outcome.kind == "ready" then
      ready = outcome
      break
    end
    Assert.isTrue(
      outcome.kind ~= "failed",
      "sourced text never fails its banks: " .. tostring(outcome.error)
    )
  end
  Assert.notNil(ready, "sourced text converges on a complete bundle")
  Assert.deepEqual(ready.assets.messages, {
    ["grid.seen-count"] = "2",
    ["grid.selected-name"] = "CHIKORITA",
    ["entry.category"] = "Leaf",
    ["entry.height"] = "0.9m",
  }, "every visible slot resolves its prepared string")
  for _, bankId in ipairs({ 237, 815, 816 }) do
    Assert.equal(provider.acquires[bankId], 1, "bank " .. bankId .. " joins the membership exactly once")
    Assert.isNil(provider.releases[bankId], "committed banks stay held while watched")
  end
  local second = nil
  for _ = 1, 64 do
    local outcome = lease:prepare(pageDemand("results", "pokedex-results-text"))
    if outcome.kind == "ready" then
      second = outcome
      break
    end
    Assert.isTrue(
      outcome.kind ~= "failed",
      "the textless replacement never fails: " .. tostring(outcome.error)
    )
  end
  Assert.notNil(second, "the textless replacement converges on a complete bundle")
  Assert.deepEqual(second.assets.messages, {}, "a demand without slots publishes no messages")
  for _, bankId in ipairs({ 237, 815, 816 }) do
    Assert.equal(provider.releases[bankId], 1, "a replacement with no slots returns bank " .. bankId .. " once")
  end
  lease:release()
  owner:release()
  Assert.equal(pool:stats().outstandingLeases, 0, "text and chrome return every image interest")
end

-- An unknown source text bank fails preparation instead of silently
-- substituting another language: the doomed generation publishes
-- nothing, acquires nothing, and returns every interest it staged.
function T.unknown_text_bank_fails_without_silent_fallback()
  local Owner = requirePresent("unknown text bank attribution")
  local pool = SharedImagePoolFake.new()
  local args = closureOwnerArgs(pool)
  local provider = stubMessageProvider({})
  args.messages = provider
  local owner = Owner.new(args)
  local lease = owner:acquire({ purpose = "browser" })
  local demand = pageDemand("grid", "pokedex-foreign")
  demand.text = {
    { role = "grid.selected-name", kind = "species_name", species = "CHIKORITA", language = "english" },
  }
  local failed = nil
  for _ = 1, 64 do
    local outcome = lease:prepare(demand)
    if outcome.kind == "failed" then
      failed = outcome
      break
    end
    Assert.isTrue(outcome.kind == "pending", "the doomed generation never publishes")
  end
  Assert.notNil(failed, "an unbound language bank cannot publish")
  Assert.isTrue(
    type(failed.error) == "string" and failed.error:find("english", 1, true) ~= nil,
    "the failure names its unknown language"
  )
  local acquired = 0
  for _ in pairs(provider.acquires) do
    acquired = acquired + 1
  end
  Assert.equal(acquired, 0, "a failed bank validation acquires nothing")
  Assert.equal(pool:stats().outstandingLeases, 0, "the failed generation returns its staged chrome")
  lease:release()
  owner:release()
  Assert.equal(pool:stats().outstandingLeases, 0, "failure and disposal return every owned interest")
end

-- A demanded header window attempts the owned font4 renderer instead of
-- silently borrowing body text: without host graphics the demand fails
-- with attribution and publishes nothing.
function T.header_font_demand_fails_without_host_graphics()
  local Owner = requirePresent("header font demand ownership")
  local pool = SharedImagePoolFake.new()
  local args = closureOwnerArgs(pool)
  local manifest = closureManifest()
  manifest.windows = { ["grid.selected-name"] = { font = 4 } }
  manifest.pages.grid.windows = { "grid.selected-name" }
  args.cacheFs = {
    loadLua = function(_)
      return manifest
    end,
  }
  local owner = Owner.new(args)
  local lease = owner:acquire({ purpose = "browser" })
  local failed = nil
  for _ = 1, 64 do
    local outcome = lease:prepare(pageDemand("grid", "pokedex-font"))
    if outcome.kind == "failed" then
      failed = outcome
      break
    end
    Assert.isTrue(outcome.kind == "pending", "font readiness never publishes a body-font bundle")
  end
  Assert.notNil(failed, "a font4 demand without host graphics cannot publish")
  Assert.isTrue(
    type(failed.error) == "string" and failed.error:find("header font", 1, true) ~= nil,
    "the failure names its header font cause"
  )
  lease:release()
  owner:release()
  Assert.equal(pool:stats().outstandingLeases, 0, "font failure returns every image interest")
end

-- Source formatter markers expand at prepare time from demand fields: the
-- UI bank entry carries the native `{STRVAR_1 selector, slot}` template
-- (soulsilver bank 802 entry 9) and the demand binds slot 0 to its
-- preformatted count, so the prepared string is source text, never raw.
function T.ui_text_expands_strvar_markers_from_demand_fields()
  local Owner = requirePresent("UI formatter substitution")
  local pool = SharedImagePoolFake.new()
  local provider = stubMessageProvider({ [802] = { [9] = "RESULTS {STRVAR_1 52, 0, 0}" } })
  local args = closureOwnerArgs(pool)
  args.messages = provider
  local owner = Owner.new(args)
  local lease = owner:acquire({ purpose = "browser" })
  local demand = pageDemand("grid", "pokedex-strvar")
  demand.text = {
    { role = "search.feedback", kind = "ui", messageId = 9, language = "native", fields = { [0] = "007" } },
  }
  local ready = nil
  for _ = 1, 64 do
    local outcome = lease:prepare(demand)
    if outcome.kind == "ready" then
      ready = outcome
      break
    end
    Assert.isTrue(
      outcome.kind ~= "failed",
      "sourced text never fails its banks: " .. tostring(outcome.error)
    )
  end
  Assert.notNil(ready, "field-bound text converges on a complete bundle")
  Assert.equal(ready.assets.messages["search.feedback"], "RESULTS 007", "the marker expands from its demand field")
  lease:release()
  owner:release()
  Assert.equal(pool:stats().outstandingLeases, 0, "substituted text returns every image interest")
end

-- A UI template whose marker slot has no demand field fails instead of
-- painting a raw control code: the doomed generation publishes nothing.
function T.ui_text_with_an_unbound_strvar_slot_fails_loudly()
  local Owner = requirePresent("unbound formatter attribution")
  local pool = SharedImagePoolFake.new()
  local provider = stubMessageProvider({ [802] = { [9] = "{STRVAR_1 52, 0, 0}" } })
  local args = closureOwnerArgs(pool)
  args.messages = provider
  local owner = Owner.new(args)
  local lease = owner:acquire({ purpose = "browser" })
  local demand = pageDemand("grid", "pokedex-unbound")
  demand.text = {
    { role = "search.feedback", kind = "ui", messageId = 9, language = "native" },
  }
  local failed = nil
  for _ = 1, 64 do
    local outcome = lease:prepare(demand)
    if outcome.kind == "failed" then
      failed = outcome
      break
    end
    Assert.isTrue(outcome.kind == "pending", "the doomed generation never publishes")
  end
  Assert.notNil(failed, "an unbound formatter slot cannot publish")
  Assert.isTrue(
    type(failed.error) == "string" and failed.error:find("search.feedback", 1, true) ~= nil,
    "the failure names its window role"
  )
  lease:release()
  owner:release()
  Assert.equal(pool:stats().outstandingLeases, 0, "the failed generation returns its staged chrome")
end

-- The registration announcement substitutes the capture name into the
-- native field-0 marker (soulsilver bank 197 entry 871:
-- "{STRVAR_1 1, 0, 0}'s data was added to the Pokédex."): the detached
-- display name is the battle field-0 fact, a wild first catch having no
-- nickname yet.
function T.registration_announcement_substitutes_the_capture_name()
  local Owner = requirePresent("registration formatter substitution")
  local pool = SharedImagePoolFake.new()
  local provider = stubMessageProvider({
    [197] = { [871] = "{STRVAR_1 1, 0, 0}'s data was added." },
    [237] = { [158] = "Totodile" },
    [816] = { [158] = "Big Jaw" },
    [803] = { [158] = "It bites." },
    [815] = { [158] = "0.6m" },
    [813] = { [158] = "9.5kg" },
  })
  local args = ownerArgs(pool)
  args.messages = provider
  local owner = Owner.new(args)
  local monCatalog, catalog = Fixture.catalogs()
  local dexOwner = Fixture.ownerWithHistory(monCatalog, catalog)
  local snapshot = Fixture.registrationSnapshot(dexOwner, monCatalog, "TOTODILE", 0)
  local lease = owner:acquire({ purpose = "registration" })
  local ready = nil
  for _ = 1, 64 do
    local outcome = lease:prepare(Fixture.registrationDemand(snapshot, "card-strvar"))
    if outcome.kind == "ready" then
      ready = outcome
      break
    end
    Assert.isTrue(
      outcome.kind ~= "failed",
      "the announcement never fails its bank: " .. tostring(outcome.error)
    )
  end
  Assert.notNil(ready, "the announcement converges on a complete bundle")
  Assert.equal(
    ready.assets.messages.registrationAnnouncement,
    "TOTODILE's data was added.",
    "the announcement carries the capture name instead of the raw marker"
  )
  lease:release()
  owner:release()
  Assert.equal(pool:stats().outstandingLeases, 0, "the announcement returns every image interest")
end

-- The registration card resolves its caught-specimen slots through the
-- borrowed banks: the dex number from the demanded order, the name,
-- category, flavor, height, and weight by stable catalog identity, plus
-- the producer-authoritative announcement.
function T.registration_slots_resolve_through_the_borrowed_banks()
  local Owner = requirePresent("registration species text slots")
  local pool = SharedImagePoolFake.new()
  local provider = stubMessageProvider({
    [197] = { [871] = "{STRVAR_1 1, 0, 0}'s data was added." },
    [237] = { [158] = "Totodile" },
    [816] = { [158] = "Big Jaw" },
    [803] = { [158] = "It bites." },
    [815] = { [158] = "0.6m" },
    [813] = { [158] = "9.5kg" },
  })
  local args = ownerArgs(pool)
  args.messages = provider
  local owner = Owner.new(args)
  local monCatalog, catalog = Fixture.catalogs()
  local dexOwner = Fixture.ownerWithHistory(monCatalog, catalog)
  local snapshot = Fixture.registrationSnapshot(dexOwner, monCatalog, "TOTODILE", 0)
  local expectedNumber = nil
  for index, key in ipairs(catalog.dexOrders[snapshot.dexMode]) do
    if key == "TOTODILE" then
      expectedNumber = string.format("%03d", index)
    end
  end
  Assert.notNil(expectedNumber, "the fixture catalog orders the caught species")
  local lease = owner:acquire({ purpose = "registration" })
  local ready = nil
  for _ = 1, 64 do
    local outcome = lease:prepare(Fixture.registrationDemand(snapshot, "card-slots"))
    if outcome.kind == "ready" then
      ready = outcome
      break
    end
    Assert.isTrue(
      outcome.kind ~= "failed",
      "sourced card text never fails its banks: " .. tostring(outcome.error)
    )
  end
  Assert.notNil(ready, "the card slots converge on a complete bundle")
  Assert.deepEqual(ready.assets.messages, {
    registrationAnnouncement = "TOTODILE's data was added.",
    ["registration.dex-number"] = expectedNumber,
    ["registration.species-name"] = "Totodile",
    ["registration.category"] = "Big Jaw",
    ["registration.flavor"] = "It bites.",
    ["registration.height"] = "0.6m",
    ["registration.weight"] = "9.5kg",
  }, "every card window resolves its prepared string")
  lease:release()
  owner:release()
  Assert.equal(pool:stats().outstandingLeases, 0, "card text returns every image interest")
end

-- A registration slot naming an unknown species fails instead of
-- substituting another entry: the doomed card publishes nothing.
function T.registration_slot_with_unknown_species_fails_loudly()
  local Owner = requirePresent("unknown registration species attribution")
  local pool = SharedImagePoolFake.new()
  local args = ownerArgs(pool)
  args.messages = stubMessageProvider({})
  local owner = Owner.new(args)
  local monCatalog, catalog = Fixture.catalogs()
  local dexOwner = Fixture.ownerWithHistory(monCatalog, catalog)
  local snapshot = Fixture.registrationSnapshot(dexOwner, monCatalog, "TOTODILE", 0)
  local demand = Fixture.registrationDemand(snapshot, "card-unknown")
  demand.text.slots = {
    { role = "registration.species-name", kind = "species_name", species = "MISSINGNO", language = "native" },
  }
  local lease = owner:acquire({ purpose = "registration" })
  local failed = nil
  for _ = 1, 64 do
    local outcome = lease:prepare(demand)
    if outcome.kind == "failed" then
      failed = outcome
      break
    end
    Assert.isTrue(outcome.kind == "pending", "the doomed card never publishes")
  end
  Assert.notNil(failed, "an unknown card species cannot publish")
  Assert.isTrue(
    type(failed.error) == "string" and failed.error:find("MISSINGNO", 1, true) ~= nil,
    "the failure names its unknown species"
  )
  lease:release()
  owner:release()
  Assert.equal(pool:stats().outstandingLeases, 0, "the failed card returns its staged chrome")
end

-- A page closure with genuinely placed sprites: page A stages one
-- two-part arrow plus a second role sharing its animation (so one
-- realized viewport serves both), page B stages its own two-part
-- arrow. Every part viewport fits the 64x32 fake pool images; the
-- arrow animation carries a second frame no static demand selects.
local function placedQuadManifest()
  local PokedexCache = require("libs.assets.src.PokedexCache")
  local function background(chrome)
    return { chrome = chrome, layer = 0, x = 0, y = 0, priority = 0, paletteGroup = "group" }
  end
  local function part(chrome, x, y, width, height, px, py)
    return {
      chrome = chrome,
      source = { x = x, y = y, width = width, height = height },
      x = px or 0,
      y = py or 0,
    }
  end
  local function cell(parts)
    return { bounds = { x = 0, y = 0, width = 32, height = 8 }, parts = parts }
  end
  local function sprite(animation, x, y)
    return {
      pane = "controls",
      animation = animation,
      x = x,
      y = y,
      priority = 0,
      drawPriority = 0,
      paletteGroup = "group",
    }
  end
  local function page(bgRole, spriteRoles)
    return {
      backdrop = {
        information = { r = 0, g = 0, b = 0, a = 255 },
        controls = { r = 0, g = 0, b = 0, a = 255 },
      },
      backgrounds = { information = { background(bgRole) }, controls = {} },
      cells = {},
      sprites = spriteRoles,
      windows = {},
    }
  end
  return {
    schema = PokedexCache.SCHEMA,
    fonts = { body = 0, header = 4 },
    chrome = {
      ["quad.a.bg"] = { path = "pokedex/chrome/quad-a-bg", width = 256, height = 192 },
      ["quad.a.art"] = { path = "pokedex/chrome/quad-a-art", width = 64, height = 32 },
      ["quad.b.bg"] = { path = "pokedex/chrome/quad-b-bg", width = 256, height = 192 },
      ["quad.b.art"] = { path = "pokedex/chrome/quad-b-art", width = 64, height = 32 },
    },
    cells = {
      ["quad.a.cell"] = cell({
        part("quad.a.art", 0, 0, 8, 8, 0, 0),
        part("quad.a.art", 8, 0, 8, 8, 8, 0),
      }),
      ["quad.a.cell.alt"] = cell({ part("quad.a.art", 16, 0, 8, 8, 0, 0) }),
      ["quad.b.cell"] = cell({
        part("quad.b.art", 0, 0, 8, 8, 0, 0),
        part("quad.b.art", 8, 0, 8, 8, 8, 0),
      }),
    },
    animations = {
      ["quad.a.anim"] = {
        frames = { { cell = "quad.a.cell", duration = 1 }, { cell = "quad.a.cell.alt", duration = 1 } },
      },
      ["quad.b.anim"] = { frames = { { cell = "quad.b.cell", duration = 1 } } },
    },
    sprites = {
      ["quad.a.arrow"] = sprite("quad.a.anim", 8, 8),
      ["quad.a.echo"] = sprite("quad.a.anim", 24, 8),
      ["quad.b.arrow"] = sprite("quad.b.anim", 8, 8),
    },
    windows = {},
    text = {
      ui = { bankId = 802 },
      entryByLanguage = { native = { nameBankId = 237, categoryBankId = 816, flavorBankId = 803 } },
      measureByProfile = { base = { heightBankId = 815, weightBankId = 813 } },
      registrationAnnouncement = { bankId = 197, messageId = 871 },
    },
    pages = {
      grid = page("quad.a.bg", { "quad.a.arrow", "quad.a.echo" }),
      results = page("quad.b.bg", { "quad.b.arrow" }),
    },
  }
end

---@param pool table shared image pool double under test
---@param graphics table fake graphics namespace behind viewport realization
---@param manifest table<string, unknown> placed-sprite page closure under test
---@return table owner construction arguments over the placed closure
local function quadOwnerArgs(pool, graphics, manifest)
  local args = ownerArgs(pool)
  args.graphics = graphics
  args.cacheFs = {
    loadLua = function(_)
      return manifest
    end,
  }
  return args
end

---@param role string authored page role under test
---@param key string demand generation key
---@return table demand one imageless browser demand with no dynamic sprite roles
local function quadDemand(role, key)
  local demand = pageDemand(role, key)
  demand.spriteRoles = {}
  return demand
end

-- A pending replacement that fails its viewport realization cannot
-- publish: the committed page keeps its identical prepared viewports,
-- the next page completes once the failure clears, and adoption retires
-- every viewport the displayed generation no longer watches. The lease
-- viewport ledger below is read only to prove exact-once retirement,
-- the ownership contract under test.
function T.pending_and_failed_sprite_viewport_preparation_preserves_the_committed_page()
  local Owner = requirePresent("page-local sprite viewport ownership")
  local FakeGraphics = require("tests.support.FakeGraphics")
  local pool = SharedImagePoolFake.new()
  local graphics = FakeGraphics.new()
  local quadAttempts = 0
  local failQuads = false
  local realQuad = graphics.newQuad
  graphics.newQuad = function(...)
    quadAttempts = quadAttempts + 1
    if failQuads then
      error("injected sprite viewport failure")
    end
    return realQuad(...)
  end
  local owner = Owner.new(quadOwnerArgs(pool, graphics, placedQuadManifest()))
  local lease = owner:acquire({ purpose = "browser" })
  local first = nil
  for _ = 1, 64 do
    local before = quadAttempts
    local outcome = lease:prepare(quadDemand("grid", "quad-a"))
    Assert.isTrue(quadAttempts - before <= 1, "one preparation admits at most one viewport")
    if outcome.kind == "ready" then
      first = outcome
      break
    end
    Assert.equal(outcome.kind, "pending", "partial sprite readiness never publishes")
  end
  Assert.notNil(first, "the placed page converges on a complete bundle")
  Assert.equal(quadAttempts, 2, "the shared animation realizes exactly its two resting viewports")
  local parts = assert(first.assets.spriteParts, "the ready bundle carries its sprite parts")
  local arrow = assert(parts["quad.a.arrow"], "the arrow role publishes its prepared frame")
  Assert.equal(#arrow, 1, "static roles prepare only their resting frame")
  Assert.equal(#arrow[1], 2, "the resting cell prepares both parts")
  Assert.isTrue(arrow[1][1].quad ~= nil, "the first resting part carries its realized viewport")
  Assert.isTrue(arrow[1][2].quad ~= nil, "the second resting part carries its realized viewport")
  Assert.isTrue(arrow[1][1].quad ~= arrow[1][2].quad, "distinct source rectangles realize distinct viewports")
  local echo = assert(parts["quad.a.echo"], "the echo role shares its animation closure")
  Assert.isTrue(echo[1][1].quad == arrow[1][1].quad, "identical chrome rectangles share one viewport")
  Assert.isTrue(echo[1][2].quad == arrow[1][2].quad, "shared parts stay identical across roles")
  local stepped = lease:prepare(quadDemand("results", "quad-b"))
  Assert.equal(stepped.kind, "pending", "a fresh key never adopts on its enrollment call")
  failQuads = true
  local failed = nil
  for _ = 1, 64 do
    local outcome = lease:prepare(quadDemand("results", "quad-b"))
    if outcome.kind == "failed" then
      failed = outcome
      break
    end
    Assert.equal(outcome.kind, "pending", "the doomed generation stays pending until its failure surfaces")
  end
  Assert.notNil(failed, "the failed viewport reports instead of publishing")
  Assert.isTrue(
    type(failed.error) == "string" and failed.error:find("quad.b.arrow", 1, true) ~= nil,
    "the failure names its sprite role"
  )
  local kept = lease:prepare(quadDemand("grid", "quad-a"))
  Assert.equal(kept.kind, "ready", "the committed generation answers without new work")
  Assert.isTrue(kept.assets == first.assets, "the failed generation never mutates the committed bundle")
  Assert.isTrue(
    kept.assets.spriteParts["quad.a.arrow"][1][1].quad == arrow[1][1].quad,
    "committed viewports survive the failed replacement"
  )
  failQuads = false
  local second = nil
  for _ = 1, 64 do
    local before = quadAttempts
    local outcome = lease:prepare(quadDemand("results", "quad-c"))
    Assert.isTrue(quadAttempts - before <= 1, "the replacement admits at most one viewport per call")
    if outcome.kind == "ready" then
      second = outcome
      break
    end
    Assert.isTrue(outcome.kind == "pending", "the replacement stays pending until its closure is whole")
  end
  Assert.notNil(second, "the replacement page converges once its failure clears")
  local card = assert(second.assets.spriteParts["quad.b.arrow"], "the replacement publishes its own arrow")
  Assert.equal(#card[1], 2, "the replacement prepares both of its parts")
  Assert.isTrue(card[1][1].quad ~= arrow[1][1].quad, "the replacement realizes its own viewports")
  local held = assert(lease._spritePartQuads, "the lease owns its viewport ledger")
  local heldCount, sawNew, sawOld = 0, false, false
  for _, quad in pairs(held) do
    heldCount = heldCount + 1
    if quad == card[1][1].quad or quad == card[1][2].quad then
      sawNew = true
    end
    if quad == arrow[1][1].quad then
      sawOld = true
    end
  end
  Assert.equal(heldCount, 2, "adoption retires every viewport the displayed page no longer watches")
  Assert.isTrue(sawNew, "the displayed viewports stay owned")
  Assert.isTrue(not sawOld, "the superseded arrow leaves the lease exactly once")
  lease:release()
  lease:release()
  owner:release()
  Assert.equal(pool:stats().outstandingLeases, 0, "disposal returns every borrowed image interest")
end

-- A part viewport outside its adopted image cannot publish: preparation
-- fails with the sprite role instead of realizing a malformed quad.
function T.out_of_bounds_sprite_viewports_fail_with_attribution()
  local Owner = requirePresent("attributed sprite viewport failure")
  local FakeGraphics = require("tests.support.FakeGraphics")
  local pool = SharedImagePoolFake.new()
  local graphics = FakeGraphics.new()
  local manifest = placedQuadManifest()
  manifest.cells["quad.a.cell"].parts[1].source = { x = 60, y = 0, width = 8, height = 8 }
  local owner = Owner.new(quadOwnerArgs(pool, graphics, manifest))
  local lease = owner:acquire({ purpose = "browser" })
  local failed = nil
  for _ = 1, 64 do
    local outcome = lease:prepare(quadDemand("grid", "quad-bad"))
    if outcome.kind == "failed" then
      failed = outcome
      break
    end
    Assert.equal(outcome.kind, "pending", "the invalid generation never publishes")
  end
  Assert.notNil(failed, "an out-of-bounds viewport cannot publish")
  Assert.isTrue(
    type(failed.error) == "string" and failed.error:find("quad.a.arrow", 1, true) ~= nil,
    "the failure names its sprite role"
  )
  lease:release()
  owner:release()
  Assert.equal(pool:stats().outstandingLeases, 0, "failure and disposal return every owned interest")
end

return { tests = T }
