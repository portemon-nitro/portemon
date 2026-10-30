-- The bounded per-open resource owner behind the field Pokedex: demand
-- validation, whole-view publication over the shared image pool, stale
-- completion rejection, fixed current/pending bounds, incremental
-- preparation, failure unwinding, and exactly-once release. Icon-only
-- readiness never retires a visible page. The shared pool is faked at its
-- public borrow boundary; no renderer, GPU, ROM, or worker is touched.

local Assert = require("tests.support.Assert")
local Fixture = require("tests.support.PokedexPresentationFixture")
local PokedexSources = require("romdump.src.config.PokedexSources")
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

function T.surfaces_realize_promptly_under_a_generous_allowance()
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
  for _, at in ipairs(createdAt) do
    Assert.equal(at, 1, "the generous budget realizes every surface on the first prepare")
  end
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
  Assert.isTrue(type(failed.error) == "string" and failed.error ~= "", "the failure carries its original cause")
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
    Assert.isTrue(outcome.kind ~= "failed", "sourced text never fails its banks: " .. tostring(outcome.error))
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
    Assert.isTrue(outcome.kind ~= "failed", "the textless replacement never fails: " .. tostring(outcome.error))
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
    Assert.isTrue(outcome.kind ~= "failed", "sourced text never fails its banks: " .. tostring(outcome.error))
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
    Assert.isTrue(outcome.kind ~= "failed", "the announcement never fails its bank: " .. tostring(outcome.error))
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
    Assert.isTrue(outcome.kind ~= "failed", "sourced card text never fails its banks: " .. tostring(outcome.error))
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
    local outcome = lease:prepare(quadDemand("grid", "quad-a"))
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
  -- Batch admission would otherwise settle a fresh key before a failure
  -- can be armed mid-flight, so pool readiness gates the replacement
  -- generation: it enrolls everything on its first call while adoption
  -- waits for the gate.
  local rawPoll = pool.poll
  local gateOpen = true
  function pool:poll(token)
    if gateOpen then
      return rawPoll(self, token)
    end
    return "pending"
  end
  gateOpen = false
  local stepped = lease:prepare(quadDemand("results", "quad-b"))
  Assert.equal(stepped.kind, "pending", "a fresh key never adopts on its enrollment call")
  failQuads = true
  gateOpen = true
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
    local outcome = lease:prepare(quadDemand("results", "quad-c"))
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

-- A criteria-shaped demand whose native UI bank is unavailable fails
-- closed: the error attributes the exact role and bank, the previously
-- committed grid bundle stays intact, and the following grid generation
-- still converges, so a missing bank can never publish an unlabeled page.
function T.search_criteria_demand_without_its_ui_bank_keeps_the_committed_view()
  local Owner = requirePresent("search text fail-closed preservation")
  local pool = SharedImagePoolFake.new()
  local monCatalog = Fixture.catalogs()
  local speciesRecord = assert(monCatalog:species("CHIKORITA"), "the fixture catalog names its species")
  local nativeId = assert(speciesRecord.nativeId, "the fixture species carries its numeric identity")
  assert(type(nativeId) == "number", "the fixture species identity resolves numerically")
  local provider = stubMessageProvider({
    [237] = { [nativeId] = "CHIKORITA" },
  })
  local args = closureOwnerArgs(pool)
  args.messages = provider
  local manifest = closureManifest()
  manifest.pages["search.criteria"] =
    { backgrounds = { information = {}, controls = {} }, cells = {}, sprites = {}, windows = {} }
  args.cacheFs = {
    loadLua = function(_)
      return manifest
    end,
  }
  local owner = Owner.new(args)
  local lease = owner:acquire({ purpose = "browser" })
  local demand = pageDemand("grid", "pokedex-grid-text")
  demand.text = {
    { role = "grid.seen-count", kind = "numeric", value = "2" },
    { role = "grid.selected-name", kind = "species_name", species = "CHIKORITA", language = "native" },
  }
  local ready = nil
  for _ = 1, 64 do
    local outcome = lease:prepare(demand)
    if outcome.kind == "ready" then
      ready = outcome
      break
    end
    Assert.isTrue(outcome.kind ~= "failed", "the grid text converges: " .. tostring(outcome.error))
  end
  Assert.notNil(ready, "the grid bundle commits before the doomed criteria demand")
  local doomed = pageDemand("search.criteria", "pokedex-criteria-text")
  doomed.text = {
    { role = "search.caption-order", kind = "ui", messageId = 26 },
    { role = "search.button-run", kind = "ui", messageId = 36 },
  }
  local failed = nil
  for _ = 1, 64 do
    local outcome = lease:prepare(doomed)
    if outcome.kind == "failed" then
      failed = outcome
      break
    end
    Assert.isTrue(outcome.kind == "pending", "the doomed criteria generation never publishes")
  end
  Assert.notNil(failed, "an unavailable UI bank cannot publish the criteria page")
  Assert.isTrue(
    type(failed.error) == "string" and failed.error:find("search.caption-order", 1, true) ~= nil,
    "the failure names its exact text role"
  )
  Assert.isTrue(
    type(failed.error) == "string" and failed.error:find("802", 1, true) ~= nil,
    "the failure names its missing bank"
  )
  -- A textless demand publishes no messages by contract, so the follow-up
  -- grid generation re-demands the committed text: this proves the doomed
  -- criteria generation left the committed bundle intact.
  local againDemand = pageDemand("grid", "pokedex-grid-again")
  againDemand.text = {
    { role = "grid.seen-count", kind = "numeric", value = "2" },
    { role = "grid.selected-name", kind = "species_name", species = "CHIKORITA", language = "native" },
  }
  local again = nil
  for _ = 1, 64 do
    local outcome = lease:prepare(againDemand)
    if outcome.kind == "ready" then
      again = outcome
      break
    end
    Assert.isTrue(outcome.kind ~= "failed", "the grid still converges: " .. tostring(outcome.error))
  end
  Assert.notNil(again, "the committed view survives the doomed criteria generation")
  Assert.deepEqual(again.assets.messages, {
    ["grid.seen-count"] = "2",
    ["grid.selected-name"] = "CHIKORITA",
  }, "the surviving bundle keeps its prepared strings")
  lease:release()
  owner:release()
  Assert.equal(pool:stats().outstandingLeases, 0, "failure and disposal return every owned interest")
end

-- The live source page inventory mirrored into a lease manifest: every
-- subject/choice the producer declares for the requested roles resolves
-- to a distinct resting sprite role, so the lease validates the
-- controller's real demanded membership instead of a hand-written
-- permissive list. Footprint intents ride shared atlas entries behind
-- an already-bound chrome role.
---@param roles string[] page roles to close from the live source inventory
---@param objects table[] real controller sprite intents behind the demands
---@return table manifest lease manifest closing exactly the sourced subjects
local function sourceClosureManifest(roles, objects)
  local PokedexCache = require("libs.assets.src.PokedexCache")
  local PokedexSources = require("romdump.src.config.PokedexSources")
  local chrome, cells, animations, sprites, pages = {}, {}, {}, {}, {}
  local firstChrome = nil
  for _, role in ipairs(roles) do
    local subjects = assert(PokedexSources.nativeSpriteSubjects[role], "the source inventory closes " .. role)
    local bound = {}
    for subject, choices in pairs(subjects) do
      local boundChoices = {}
      for choice, entry in pairs(choices) do
        assert(type(entry) == "table", role .. " binds " .. subject .. "/" .. choice)
        local pane = entry.pane
        assert(pane == "controls" or pane == "information", role .. " panes " .. subject)
        local art = "test-" .. role .. "-" .. subject .. "-" .. choice
        chrome[art .. ".art"] = { path = "pokedex/test/" .. art, width = 8, height = 8 }
        if firstChrome == nil then
          firstChrome = art .. ".art"
        end
        cells[art .. ".cell"] = {
          bounds = { x = 0, y = 0, width = 8, height = 8 },
          parts = {
            { chrome = art .. ".art", source = { x = 0, y = 0, width = 8, height = 8 }, x = 0, y = 0 },
          },
        }
        animations[art .. ".anim"] = { frames = { { cell = art .. ".cell", duration = 1 } } }
        sprites[art] = {
          pane = pane,
          animation = art .. ".anim",
          x = 0,
          y = 0,
          priority = 0,
          drawPriority = 0,
          paletteGroup = "group",
        }
        boundChoices[choice] = { sprite = art, pane = pane }
      end
      bound[subject] = boundChoices
    end
    pages[role] = {
      backgrounds = { information = {}, controls = {} },
      cells = {},
      sprites = {},
      windows = {},
      spriteSubjects = bound,
    }
  end
  local footprints = {}
  for _, intent in ipairs(objects or {}) do
    if type(intent) == "table" and intent.subject == "footprint" and type(intent.choice) == "string" then
      footprints[intent.choice] = { chrome = assert(firstChrome, "sourced pages bind chrome") }
    end
  end
  return {
    schema = PokedexCache.SCHEMA,
    chrome = chrome,
    cells = cells,
    animations = animations,
    sprites = sprites,
    windows = {},
    text = {
      ui = { bankId = 802 },
      entryByLanguage = { native = { nameBankId = 237, categoryBankId = 816, flavorBankId = 803 } },
      measureByProfile = { base = { heightBankId = 815, weightBankId = 813 } },
      registrationAnnouncement = { bankId = 197, messageId = 871 },
    },
    pages = pages,
    footprints = footprints,
  }
end

---@param pool table shared image pool double under test
---@param manifest table<string, unknown> sourced page closure under test
---@return table owner construction arguments over the sourced closure
local function sourcedOwnerArgs(pool, manifest)
  local args = ownerArgs(pool)
  args.cacheFs = {
    loadLua = function(_)
      return manifest
    end,
  }
  return args
end

-- Pumps one browser demand to its ready bundle: pending generations never
-- publish, and a failed generation reports its attributed cause instead
-- of silently converging.
---@param lease table acquired per-open preparation lease under test
---@param demand table<string, unknown> validated browser demand under preparation
---@return table ready outcome behind the committed bundle
local function pumpReady(lease, demand)
  local ready = nil
  for _ = 1, 64 do
    local outcome = lease:prepare(demand)
    if outcome.kind == "ready" then
      ready = outcome
      break
    end
    Assert.isTrue(outcome.kind == "pending", "preparation never fails a sourced demand: " .. tostring(outcome.error))
  end
  Assert.notNil(ready, "bounded preparation converges on the sourced bundle")
  assert(ready ~= nil, "bounded preparation converges")
  return ready
end

---@param controller table live browser controller under test
---@param count integer fixed updates without input
local function settle(controller, count)
  for _ = 1, count do
    Fixture.tick(controller, {})
  end
end

---@param controller table live browser controller under test
---@param events table semantic batch for one fixed update
local function drive(controller, events)
  Fixture.tick(controller, events)
end

---@param controller table live browser controller under test
---@param species string selected species key
local function walkTo(controller, species)
  for _ = 1, 40 do
    if controller:view().selection.species == species then
      return
    end
    drive(controller, { { type = "navigate", direction = "right" } })
  end
  Assert.equal(controller:view().selection.species, species, "the walk reaches " .. species)
end

-- A caught search result carries the same mark art as its grid sibling:
-- the real results demand, with its verbatim controller intents,
-- prepares to ready against the sourced page closure, while a
-- seen-only result demands no protected mark.
function T.caught_search_results_prepare_their_full_page_closure()
  local Owner = requirePresent("sourced results closure preparation")
  local pool = SharedImagePoolFake.new()
  local monCatalog, catalog = Fixture.catalogs()
  local controller = Fixture.openController(Fixture.ownerWithHistory(monCatalog, catalog), monCatalog, catalog)
  drive(controller, { { type = "drag", target = "cover", phase = "begin", value = 0 } })
  drive(controller, { { type = "drag", target = "cover", phase = "move", value = 200 } })
  drive(controller, { { type = "drag", target = "cover", phase = "end", value = 64 } })
  settle(controller, 40)
  Assert.equal(controller:view().page, "grid", "the cover drag reaches the grid")
  drive(controller, { { type = "y" } })
  drive(controller, { { type = "start" } })
  settle(controller, 200)
  Assert.equal(controller:view().page, "results", "the completed search lands on the result grid")
  walkTo(controller, "TOTODILE")
  local view = controller:view()
  local mark = nil
  for _, intent in ipairs(assert(view.objects, "the results projection carries its sprite intents")) do
    if type(intent) == "table" and intent.subject == "caught-mark" then
      mark = intent
    end
  end
  Assert.notNil(mark, "the caught result projects its mark")
  Assert.equal(mark.choice, "shown", "the result mark uses the shown choice")
  local manifest = sourceClosureManifest({ "results" }, view.objects)
  local owner = Owner.new(sourcedOwnerArgs(pool, manifest))
  local lease = owner:acquire({ purpose = "browser" })
  local demand = {
    key = "results-caught",
    purpose = "browser",
    pageRole = "results",
    dexMode = "johto",
    language = "native",
    iconKeys = {},
    pictures = {},
    text = {},
    objects = view.objects,
  }
  local ready = pumpReady(lease, demand)
  Assert.equal(ready.key, "results-caught", "the ready outcome carries its matching generation key")
  lease:release()
  walkTo(controller, "CHIKORITA")
  local seenView = controller:view()
  Assert.equal(seenView.selection.species, "CHIKORITA", "the walk reaches the seen-only result")
  for _, intent in ipairs(assert(seenView.objects, "the seen-only projection carries its intents")) do
    Assert.isTrue(
      type(intent) ~= "table" or intent.subject ~= "caught-mark",
      "a seen-only result demands no protected mark"
    )
  end
  controller:dispose()
  owner:release()
  Assert.equal(pool:stats().outstandingLeases, 0, "the results journey returns every borrowed interest")
end

-- Valid shape-filtered search pages prepare across navigation while an
-- explicitly invalid subject still fails with attribution: the root and
-- the shape editor converge, a demand naming the hidden icon on an
-- unrelated editor fails naming its subject, the committed bundle
-- survives, and close plus reopen plateaus at no outstanding interest.
-- Attaches the published editor order arrays to a synthetic catalog so
-- shape/type editors resolve each position exactly like they do against
-- generated data.
---@param catalog table synthetic generated dex catalog
local function withPublishedOptionOrder(catalog)
  local criteria = assert(catalog.criteria, "the synthetic catalog carries its search criteria")
  local typeOrder = {}
  for _, name in ipairs(PokedexSources.typeOrder) do
    typeOrder[#typeOrder + 1] = name
  end
  typeOrder[#typeOrder + 1] = "unrestricted"
  criteria.typeOptionOrder = typeOrder
  local shapeOrder = {}
  for _, name in ipairs(PokedexSources.shapeOrder) do
    shapeOrder[#shapeOrder + 1] = name
  end
  shapeOrder[#shapeOrder + 1] = "unrestricted"
  criteria.shapeOptionOrder = shapeOrder
  return catalog
end

function T.shape_pages_prepare_while_invalid_subjects_still_fail()
  local Owner = requirePresent("sourced search closure and strict validation")
  local pool = SharedImagePoolFake.new()
  local monCatalog, catalog = Fixture.catalogs()
  withPublishedOptionOrder(catalog)
  local controller = Fixture.openController(Fixture.ownerWithHistory(monCatalog, catalog), monCatalog, catalog)
  drive(controller, { { type = "drag", target = "cover", phase = "begin", value = 0 } })
  drive(controller, { { type = "drag", target = "cover", phase = "move", value = 200 } })
  drive(controller, { { type = "drag", target = "cover", phase = "end", value = 64 } })
  settle(controller, 40)
  drive(controller, { { type = "y" } })
  Assert.equal(controller:view().page, "search", "grid Y reaches the criteria root")
  drive(controller, { { type = "activate", action = "criterion", value = "shape" } })
  drive(controller, { { type = "activate", action = "editor-choice", value = "quadruped" } })
  drive(controller, { { type = "activate", action = "editor-ok" } })
  Assert.isNil(controller:view().search.editor, "confirming the shape choice returns to the root")
  local rootObjects = assert(controller:view().objects, "the root projects its sprite intents")
  drive(controller, { { type = "activate", action = "criterion", value = "shape" } })
  Assert.notNil(controller:view().search.editor, "the shape editor opens")
  local shapeObjects = assert(controller:view().objects, "the shape editor projects its sprite intents")
  drive(controller, { { type = "cancel" } })
  local manifest = sourceClosureManifest({ "search.criteria", "search.shape", "search.type" }, rootObjects)
  local owner = Owner.new(sourcedOwnerArgs(pool, manifest))
  local lease = owner:acquire({ purpose = "browser" })
  ---@param role string demanded page role
  ---@param key string demand generation key
  ---@param objects table[] real controller sprite intents
  local function demandFor(role, key, objects)
    return {
      key = key,
      purpose = "browser",
      pageRole = role,
      dexMode = "johto",
      language = "native",
      iconKeys = {},
      pictures = {},
      text = {},
      objects = objects,
    }
  end
  local shapeReady = pumpReady(lease, demandFor("search.shape", "shape-editor", shapeObjects))
  local rootReady = pumpReady(lease, demandFor("search.criteria", "criteria-root", rootObjects))
  Assert.isTrue(rootReady.assets ~= shapeReady.assets, "replacement publishes a new bundle identity")
  local failed = nil
  for _ = 1, 64 do
    local outcome = lease:prepare(demandFor("search.type", "type-editor", shapeObjects))
    if outcome.kind == "failed" then
      failed = outcome
      break
    end
    Assert.equal(outcome.kind, "pending", "the invalid generation never publishes")
  end
  Assert.notNil(failed, "an unrelated editor cannot borrow the hidden icon")
  Assert.isTrue(
    type(failed.error) == "string" and failed.error:find("body-icon", 1, true) ~= nil,
    "the failure names its hidden subject"
  )
  local kept = lease:prepare(demandFor("search.criteria", "criteria-root", rootObjects))
  Assert.equal(kept.kind, "ready", "the committed generation answers without new work")
  Assert.isTrue(kept.assets == rootReady.assets, "the failed generation never mutates the committed bundle")
  lease:release()
  lease:release()
  local reopened = owner:acquire({ purpose = "browser" })
  local again = pumpReady(reopened, demandFor("search.shape", "shape-reopen", shapeObjects))
  Assert.notNil(again.assets, "reopening prepares the valid page again")
  reopened:release()
  reopened:release()
  owner:release()
  controller:dispose()
  Assert.equal(pool:stats().outstandingLeases, 0, "failure and reopening return every owned interest")
end

-- Staged slider quantities resolve through the borrowed height and weight
-- templates: the live browser projects physical source values with two
-- preformatted fields, and preparation expands both markers without
-- leaving step indexes or raw control codes in the prepared strings.
function T.staged_slider_quantities_expand_through_their_borrowed_templates()
  local Owner = requirePresent("borrowed measurement template expansion")
  local pool = SharedImagePoolFake.new()
  local monCatalog, catalog = Fixture.catalogs()
  local dexOwner = Fixture.ownerWithHistory(monCatalog, catalog)
  local controller = Fixture.openController(dexOwner, monCatalog, catalog)
  drive(controller, { { type = "drag", target = "cover", phase = "begin", value = 0 } })
  drive(controller, { { type = "drag", target = "cover", phase = "move", value = 200 } })
  drive(controller, { { type = "drag", target = "cover", phase = "end", value = 64 } })
  settle(controller, 40)
  Assert.equal(controller:view().page, "grid", "the cover drag reaches the grid")
  drive(controller, { { type = "y" } })
  settle(controller, 2)
  Assert.equal(controller:view().page, "search", "grid Y reaches the search criteria")
  local staged = {}
  for _, slot in ipairs(controller:view().text) do
    if slot.role == "search.value-height-min" or slot.role == "search.value-height-max" then
      staged[slot.role] = slot
    end
    if slot.role == "search.value-weight-min" or slot.role == "search.value-weight-max" then
      staged[slot.role] = slot
    end
  end
  Assert.notNil(staged["search.value-height-min"], "the criteria stages its height floor")
  Assert.equal(staged["search.value-height-min"].kind, "ui", "staged quantities ride the native bank")
  Assert.equal(staged["search.value-height-min"].messageId, 175, "the height floor uses its source template")
  Assert.equal(staged["search.value-height-min"].fields[0], "0", "the height floor converts its major unit")
  Assert.equal(staged["search.value-height-min"].fields[1], "00", "the height floor converts its minor unit")
  Assert.equal(staged["search.value-height-max"].messageId, 175, "the height ceiling uses its source template")
  Assert.equal(staged["search.value-height-max"].fields[0], "99", "the sentinel converts its major unit")
  Assert.equal(staged["search.value-height-max"].fields[1], "00", "the sentinel converts its minor unit")
  Assert.equal(staged["search.value-weight-min"].messageId, 38, "the weight floor uses its source template")
  Assert.equal(staged["search.value-weight-min"].fields[0], "0", "the weight floor converts its major unit")
  Assert.equal(staged["search.value-weight-max"].messageId, 38, "the weight ceiling uses its source template")
  Assert.equal(staged["search.value-weight-max"].fields[0], "9999", "the sentinel converts its major unit")
  local provider = stubMessageProvider({
    [802] = {
      [175] = "HT {STRVAR_1 52, 0, 0}ft {STRVAR_1 52, 1, 0}in",
      [38] = "WT {STRVAR_1 52, 0, 0}.{STRVAR_1 52, 1, 0}lbs",
    },
  })
  local args = closureOwnerArgs(pool)
  args.messages = provider
  local manifest = closureManifest()
  manifest.pages["search.criteria"] =
    { backgrounds = { information = {}, controls = {} }, cells = {}, sprites = {}, windows = {} }
  args.cacheFs = {
    loadLua = function(_)
      return manifest
    end,
  }
  local owner = Owner.new(args)
  local lease = owner:acquire({ purpose = "browser" })
  local demand = pageDemand("search.criteria", "pokedex-measure-templates")
  demand.text = {
    staged["search.value-height-min"],
    staged["search.value-height-max"],
    staged["search.value-weight-min"],
    staged["search.value-weight-max"],
  }
  local ready = pumpReady(lease, demand)
  Assert.equal(ready.assets.messages["search.value-height-min"], "HT 0ft 00in", "the floor expands both height fields")
  Assert.equal(
    ready.assets.messages["search.value-height-max"],
    "HT 99ft 00in",
    "the ceiling expands its sentinel fields"
  )
  Assert.equal(ready.assets.messages["search.value-weight-min"], "WT 0.0lbs", "the floor expands both weight fields")
  Assert.equal(
    ready.assets.messages["search.value-weight-max"],
    "WT 9999.0lbs",
    "the ceiling expands its sentinel fields"
  )
  for _, role in ipairs({ "search.value-height-min", "search.value-weight-min" }) do
    local prepared = assert(ready.assets.messages[role], "the prepared window exists")
    Assert.isTrue(prepared:find("{STRVAR", 1, true) == nil, "no raw marker survives preparation")
    Assert.isTrue(prepared:find("152", 1, true) == nil, "no raw step index poses as a unit")
  end
  lease:release()
  owner:release()
  controller:dispose()
  Assert.equal(pool:stats().outstandingLeases, 0, "measurement text returns every image interest")
end

-- Idle warmup stages exactly the long-lived common page roles behind one
-- reusable six-canvas group: each staged page carries a single authored
-- background so the staged set proves role closure without inventing page
-- art, and the first real browser lease reuses warmed canvases and chrome
-- instead of rebuilding them.
local function idleClosureManifest()
  local PokedexCache = require("libs.assets.src.PokedexCache")
  local function background(chrome)
    return { chrome = chrome, layer = 0, x = 0, y = 0, priority = 0, paletteGroup = "group" }
  end
  local function page(bgRole)
    return {
      backdrop = {
        information = { r = 0, g = 0, b = 0, a = 255 },
        controls = { r = 0, g = 0, b = 0, a = 255 },
      },
      backgrounds = { information = { background(bgRole) }, controls = {} },
      cells = {},
      sprites = {},
      windows = {},
    }
  end
  return {
    schema = PokedexCache.SCHEMA,
    fonts = { body = 0, header = 4 },
    chrome = {
      ["cover.bg"] = { path = "pokedex/chrome/cover-bg", width = 256, height = 192 },
      ["grid.bg"] = { path = "pokedex/chrome/grid-bg", width = 256, height = 192 },
      ["registration.bg"] = { path = "pokedex/chrome/registration-bg", width = 256, height = 192 },
    },
    cells = {},
    animations = {},
    sprites = {},
    windows = {},
    text = {
      ui = { bankId = 802 },
      entryByLanguage = { native = { nameBankId = 237, categoryBankId = 816, flavorBankId = 803 } },
      measureByProfile = { base = { heightBankId = 815, weightBankId = 813 } },
      registrationAnnouncement = { bankId = 197, messageId = 871 },
    },
    pages = {
      cover = page("cover.bg"),
      grid = page("grid.bg"),
      registration = page("registration.bg"),
    },
  }
end

---@param pool table shared image pool double under test
---@param graphics table fake graphics namespace recording canvas construction
---@return table owner construction arguments over the common-role closure
local function idleOwnerArgs(pool, graphics)
  local args = ownerArgs(pool)
  local manifest = idleClosureManifest()
  args.cacheFs = {
    loadLua = function(_)
      return manifest
    end,
  }
  args.graphics = graphics
  return args
end

---@param owner table per-open resource owner under test
---@param allowance integer remaining speculative GPU realizations for the call
---@return boolean whether speculative work remains after the call
local function settleWarmup(owner, allowance)
  local settled = false
  for _ = 1, 128 do
    local used, failure = owner:advanceWarmup(allowance)
    Assert.isNil(failure, "idle staging reports no failure on synthetic chrome")
    if used == false then
      settled = true
      break
    end
  end
  Assert.isTrue(settled, "idle rounds finish the common chrome and canvas group work")
  return settled
end

-- Common role art and exactly one six-canvas compositor group are staged
-- across idle rounds; the first browser lease reuses them without new
-- canvas construction or chrome re-upload, held zero-allowance updates
-- while the lease is live displace nothing, and a repeated open reuses
-- the returned group again while page state still waits on its own
-- dynamic content.
function T.idle_rounds_stage_common_chrome_and_the_canvas_group_for_first_open()
  local Owner = requirePresent("idle common chrome and canvas staging")
  local FakeGraphics = require("tests.support.FakeGraphics")
  local pool = SharedImagePoolFake.new()
  local graphics = FakeGraphics.new()
  local owner = Owner.new(idleOwnerArgs(pool, graphics))
  Assert.isTrue(
    type(owner.advanceWarmup) == "function",
    "the dex owner stages its common chrome and canvas group across idle rounds"
  )
  -- A real foreground demand establishes the presentation first; idle
  -- staging then warms the shared chrome and canvas group from it.
  local primer = owner:acquire({ purpose = "browser" })
  primer:prepare(pageDemand("grid", "idle-prime"))
  primer:release()
  local maxDelta = 0
  local before = pool.uploads + #graphics.canvases
  local settled = false
  for _ = 1, 128 do
    local used, failure = owner:advanceWarmup(1)
    Assert.isNil(failure, "idle staging reports no failure on synthetic chrome")
    local delta = (pool.uploads + #graphics.canvases) - before
    before = pool.uploads + #graphics.canvases
    if delta > maxDelta then
      maxDelta = delta
    end
    if used == false then
      settled = true
      break
    end
  end
  Assert.isTrue(settled, "idle rounds finish the common chrome and canvas group work")
  Assert.equal(#graphics.canvases, 6, "idle rounds prepare exactly one reusable six-canvas group")
  Assert.isTrue(maxDelta <= 1, "one idle round realizes at most one image pair or canvas")
  local warmed = {}
  for _, canvas in ipairs(graphics.canvases) do
    warmed[canvas] = true
  end
  local lease = owner:acquire({ purpose = "browser" })
  local ready = pumpReady(lease, pageDemand("grid", "idle-grid"))
  Assert.equal(#graphics.canvases, 6, "the first open creates no new canvases")
  local surfaces = assert(ready.assets.surfaces, "the ready bundle carries its serial surfaces")
  Assert.equal(#surfaces, 6, "the lease owns four BG planes plus OBJ color and metadata")
  for index, surface in ipairs(surfaces) do
    Assert.isTrue(surface.canvas ~= nil, "first-open surface " .. index .. " realizes its canvas")
    Assert.isTrue(warmed[surface.canvas], "first-open surface " .. index .. " reuses the warmed canvas group")
    Assert.equal(surface.width, 256, "warmed surfaces stay 256 wide")
    Assert.equal(surface.height, 192, "warmed surfaces stay 192 tall")
  end
  local firstCanvases = {}
  for _, surface in ipairs(surfaces) do
    firstCanvases[#firstCanvases + 1] = surface.canvas
  end
  -- A held modal update offers no speculative GPU slot while the loaned
  -- group is live: staging may observe readiness but must neither build
  -- a replacement group nor realize a canvas. An admitted update while
  -- the lease is live likewise realizes nothing without a spare slot.
  for _ = 1, 3 do
    local used, failure = owner:advanceWarmup(0)
    Assert.isNil(failure, "held staging reports no failure on synthetic chrome")
    Assert.equal(used, false, "a held update with no GPU slot admits nothing")
  end
  Assert.equal(#graphics.canvases, 6, "held updates while a lease is live create no canvases")
  for _ = 1, 3 do
    local used, failure = owner:advanceWarmup(1)
    Assert.isNil(failure, "admitted staging reports no failure while a lease is live")
    Assert.equal(used, false, "an admitted update with no spare slot realizes nothing")
  end
  Assert.equal(#graphics.canvases, 6, "admitted updates while a lease is live create no spare group")
  local uploadsAfterOpen = pool.uploads
  lease:release()
  for index, canvas in ipairs(firstCanvases) do
    Assert.equal(
      canvas.releaseCount,
      0,
      "closing the first open returns canvas " .. index .. " instead of releasing it"
    )
  end
  local second = owner:acquire({ purpose = "browser" })
  local reopened = pumpReady(second, pageDemand("grid", "idle-grid-again"))
  Assert.equal(#graphics.canvases, 6, "a repeated open creates no new canvases")
  local reopenedSurfaces = assert(reopened.assets.surfaces, "the reopened bundle carries its serial surfaces")
  Assert.equal(#reopenedSurfaces, 6, "the reopened lease owns its six surfaces")
  local reused = {}
  for _, canvas in ipairs(firstCanvases) do
    reused[canvas] = true
  end
  for index, surface in ipairs(reopenedSurfaces) do
    Assert.isTrue(reused[surface.canvas], "reopened surface " .. index .. " reuses the returned canvas group")
  end
  Assert.equal(pool.uploads, uploadsAfterOpen, "a repeated open re-uploads no common chrome")
  second:release()
  second:release()
  owner:release()
  for index, canvas in ipairs(graphics.canvases) do
    Assert.equal(canvas.releaseCount, 1, "owner teardown releases canvas " .. index .. " exactly once")
  end
  Assert.equal(pool:stats().outstandingLeases, 0, "close returns every adopted image interest")
end

-- Independent browser and registration leases never draw into the same
-- canvas group: the first takes the warmed spare, the second builds its
-- own, held zero-allowance updates while both are live create no spare,
-- each group is released or returned exactly once, and a later open
-- reuses the surviving spare without new construction.
function T.overlapping_leases_hold_independent_canvas_groups()
  local Owner = requirePresent("independent per-lease canvas ownership")
  local FakeGraphics = require("tests.support.FakeGraphics")
  local pool = SharedImagePoolFake.new()
  local graphics = FakeGraphics.new()
  local owner = Owner.new(idleOwnerArgs(pool, graphics))
  Assert.isTrue(
    type(owner.advanceWarmup) == "function",
    "the dex owner loans its warmed canvas group to exactly one lease"
  )
  -- A real foreground demand establishes the presentation first; idle
  -- staging then warms the shared chrome and canvas group from it.
  local primer = owner:acquire({ purpose = "browser" })
  primer:prepare(pageDemand("grid", "overlap-prime"))
  primer:release()
  settleWarmup(owner, 1)
  Assert.equal(#graphics.canvases, 6, "idle rounds prepare exactly one spare group")
  local first = owner:acquire({ purpose = "browser" })
  local second = owner:acquire({ purpose = "registration" })
  local readyFirst = pumpReady(first, pageDemand("grid", "overlap-grid"))
  local monCatalog, catalog = Fixture.catalogs()
  local dexOwner = Fixture.ownerWithHistory(monCatalog, catalog)
  local snapshot = Fixture.registrationSnapshot(dexOwner, monCatalog, "TOTODILE", 0)
  local readySecond = pumpReady(second, Fixture.registrationDemand(snapshot, "overlap-card"))
  local firstCanvases = assert(readyFirst.assets.surfaces, "the browser bundle carries its surfaces")
  local secondCanvases = assert(readySecond.assets.surfaces, "the card bundle carries its surfaces")
  Assert.equal(#firstCanvases, 6, "the browser lease owns its six surfaces")
  Assert.equal(#secondCanvases, 6, "the registration lease owns its six surfaces")
  Assert.equal(#graphics.canvases, 12, "the second live lease builds its own group")
  for firstIndex, firstSurface in ipairs(firstCanvases) do
    for secondIndex, secondSurface in ipairs(secondCanvases) do
      Assert.isTrue(
        firstSurface.canvas ~= secondSurface.canvas,
        "no canvas is shared between live leases: browser surface "
          .. firstIndex
          .. " registration surface "
          .. secondIndex
      )
    end
  end
  local seen = {}
  for _, surface in ipairs(firstCanvases) do
    Assert.isNil(seen[surface.canvas], "the browser group holds six distinct canvases")
    seen[surface.canvas] = true
  end
  for _, surface in ipairs(secondCanvases) do
    Assert.isNil(seen[surface.canvas], "the registration group holds six distinct canvases")
    seen[surface.canvas] = true
  end
  -- Held modal updates while both leases are live must not occupy the
  -- vacant spare slot with an empty group: staging observes readiness
  -- only and creates no canvases. Admitted updates likewise realize
  -- nothing while no spare slot is vacant.
  for _ = 1, 3 do
    local used, failure = owner:advanceWarmup(0)
    Assert.isNil(failure, "held staging reports no failure on synthetic chrome")
    Assert.equal(used, false, "a held update with no GPU slot admits nothing")
  end
  Assert.equal(#graphics.canvases, 12, "held updates while leases are live create no canvases")
  for _ = 1, 3 do
    local used, failure = owner:advanceWarmup(1)
    Assert.isNil(failure, "admitted staging reports no failure while leases are live")
    Assert.equal(used, false, "an admitted update with no spare slot realizes nothing")
  end
  Assert.equal(#graphics.canvases, 12, "admitted updates while leases are live create no spare group")
  local secondGroup = {}
  for _, surface in ipairs(secondCanvases) do
    secondGroup[#secondGroup + 1] = surface.canvas
  end
  second:release()
  first:release()
  local spare = 0
  for _, canvas in ipairs(graphics.canvases) do
    Assert.isTrue(canvas.releaseCount <= 1, "every canvas is released or returned at most once")
    if canvas.releaseCount == 0 then
      spare = spare + 1
    end
  end
  Assert.equal(spare, 6, "the first returned group survives as the sole spare")
  local third = owner:acquire({ purpose = "browser" })
  local readyThird = pumpReady(third, pageDemand("grid", "overlap-grid-again"))
  Assert.equal(#graphics.canvases, 12, "a later open reuses the surviving spare without new canvases")
  local thirdSurfaces = assert(readyThird.assets.surfaces, "the later bundle carries its surfaces")
  local kept = {}
  for _, canvas in ipairs(secondGroup) do
    kept[canvas] = true
  end
  for index, surface in ipairs(thirdSurfaces) do
    Assert.isTrue(kept[surface.canvas], "later surface " .. index .. " reuses the surviving spare group")
  end
  third:release()
  owner:release()
  for _, canvas in ipairs(graphics.canvases) do
    Assert.equal(canvas.releaseCount, 1, "owner teardown releases every canvas exactly once")
  end
  Assert.equal(pool:stats().outstandingLeases, 0, "overlapping close returns every image interest")
end

-- When one canvas construction raises, only the failed round unwinds: the
-- previously completed warm chrome and canvases stay usable, no created
-- canvas is released twice, and the later foreground preparation still
-- reports the authoritative failure instead of publishing.
function T.failed_canvas_round_keeps_completed_chrome_and_reports_authoritatively()
  local Owner = requirePresent("partial canvas failure ownership")
  local FakeGraphics = require("tests.support.FakeGraphics")
  local pool = SharedImagePoolFake.new()
  -- A persistent outage from the third canvas construction on: the idle
  -- round surfaces it, and the later foreground completion re-hits it
  -- when filling the remaining group slots instead of publishing.
  local graphics = FakeGraphics.new()
  local canvasCalls = 0
  local realNewCanvas = graphics.newCanvas
  graphics.newCanvas = function(width, height)
    canvasCalls = canvasCalls + 1
    if canvasCalls >= 3 then
      error("injected newCanvas failure")
    end
    return realNewCanvas(width, height)
  end
  local owner = Owner.new(idleOwnerArgs(pool, graphics))
  Assert.isTrue(
    type(owner.advanceWarmup) == "function",
    "the dex owner isolates a failed canvas round from completed warm work"
  )
  -- A real foreground demand establishes the presentation first, even
  -- though its own surfaces hit the same outage; idle staging then runs
  -- against the established manifest.
  local primer = owner:acquire({ purpose = "browser" })
  primer:prepare(pageDemand("grid", "failed-canvas-prime"))
  primer:release()
  local sawFailure = nil
  for _ = 1, 128 do
    local used, failure = owner:advanceWarmup(1)
    if failure ~= nil then
      Assert.isTrue(type(failure) == "string" and failure ~= "", "the failed round names its cause")
      sawFailure = failure
      break
    end
    if used == false then
      break
    end
  end
  Assert.notNil(sawFailure, "the failed canvas round surfaces instead of publishing")
  for _, canvas in ipairs(graphics.canvases) do
    Assert.isTrue(canvas.releaseCount <= 1, "no canvas is released twice by the failed round")
  end
  local lease = owner:acquire({ purpose = "browser" })
  local failed = nil
  for _ = 1, 64 do
    local outcome = lease:prepare(pageDemand("grid", "failed-canvas-grid"))
    if outcome.kind == "failed" then
      failed = outcome
      break
    end
    Assert.isTrue(outcome.kind == "pending", "the doomed generation never publishes")
  end
  Assert.notNil(failed, "foreground preparation still reports the authoritative canvas failure")
  Assert.isTrue(
    type(failed.error) == "string" and failed.error ~= "",
    "the authoritative failure carries its original cause"
  )
  lease:release()
  owner:release()
  for _, canvas in ipairs(graphics.canvases) do
    Assert.isTrue(canvas.releaseCount <= 1, "teardown never double-frees a canvas")
  end
  Assert.equal(pool:stats().outstandingLeases, 0, "failure and disposal return every image interest")
end

-- Cold idle issues no producer demand; the first real browser open
-- resolves through its ordinary required path, and a refused required
-- request surfaces its original cause on a registration open instead of
-- a synthetic answer.
function T.cold_idle_issues_no_demand_while_first_open_uses_required_readiness()
  local Owner = requirePresent("cold idle demand ownership")
  local FakeGraphics = require("tests.support.FakeGraphics")
  local pool = SharedImagePoolFake.new()
  local graphics = FakeGraphics.new()
  local demands = {}
  local gate = { ready = false }
  local args = idleOwnerArgs(pool, graphics)
  args.derivedAssets = {
    requestPokedex = function(urgency)
      demands[#demands + 1] = urgency
      if gate.ready then
        return true, nil
      end
      return false, nil
    end,
  }
  local owner = Owner.new(args)
  local used, failure = owner:advanceWarmup(1)
  Assert.equal(used, false, "cold idle admits no GPU realization")
  Assert.equal(#demands, 0, "cold idle issues no producer demand before any foreground open")
  Assert.isNil(failure, "cold idle reports no failure on an unopened presentation")
  local lease = owner:acquire({ purpose = "browser" })
  local stalled = lease:prepare(pageDemand("grid", "first-grid"))
  Assert.equal(stalled.kind, "pending", "an unready foreground demand stays pending")
  Assert.equal(#demands, 1, "the first foreground demand enrolls exactly once")
  Assert.equal(demands[1], "required", "the first foreground demand uses required readiness")
  gate.ready = true
  local ready = pumpReady(lease, pageDemand("grid", "first-grid"))
  Assert.equal(ready.key, "first-grid", "the ready outcome carries its matching generation key")
  for _, urgency in ipairs(demands) do
    Assert.equal(urgency, "required", "no idle turn enrolls producer work around the first open")
  end
  lease:release()
  owner:release()
  Assert.equal(pool:stats().outstandingLeases, 0, "the first open returns every borrowed interest")
  local failedPool = SharedImagePoolFake.new()
  local failedGraphics = FakeGraphics.new()
  local failedDemands = {}
  local failedArgs = idleOwnerArgs(failedPool, failedGraphics)
  failedArgs.derivedAssets = {
    requestPokedex = function(urgency)
      failedDemands[#failedDemands + 1] = urgency
      return nil, "synthetic required failure"
    end,
  }
  local failedOwner = Owner.new(failedArgs)
  local failedUsed, failedIdle = failedOwner:advanceWarmup(1)
  Assert.equal(failedUsed, false, "cold idle admits no GPU realization")
  Assert.equal(#failedDemands, 0, "cold idle issues no producer demand before any foreground open")
  Assert.isNil(failedIdle, "cold idle reports no failure on an unopened presentation")
  local registration = failedOwner:acquire({ purpose = "registration" })
  local monCatalog, catalog = Fixture.catalogs()
  local dexOwner = Fixture.ownerWithHistory(monCatalog, catalog)
  local snapshot = Fixture.registrationSnapshot(dexOwner, monCatalog, "TOTODILE", 0)
  local failed = nil
  for _ = 1, 64 do
    local outcome = registration:prepare(Fixture.registrationDemand(snapshot, "first-card"))
    if outcome.kind == "failed" then
      failed = outcome
      break
    end
    Assert.equal(outcome.kind, "pending", "the doomed card never publishes")
  end
  Assert.notNil(failed, "a refused foreground demand cannot publish")
  Assert.isTrue(
    type(failed.error) == "string" and failed.error:find("synthetic required failure", 1, true) ~= nil,
    "the failure carries its original required cause"
  )
  for _, urgency in ipairs(failedDemands) do
    Assert.equal(urgency, "required", "no idle turn enrolls producer work around the refused open")
  end
  registration:release()
  failedOwner:release()
  Assert.equal(failedPool:stats().outstandingLeases, 0, "the refused open returns every borrowed interest")
end

-- Settled idle work rests: after the static closure and the canvas group
-- are complete, mixed-allowance rounds admit nothing and issue no new
-- image interest, canvases, producer demand, cache loads, or manifest
-- reads.
function T.settled_idle_work_rests_without_new_interest_or_reads()
  local Owner = requirePresent("settled idle rest")
  local FakeGraphics = require("tests.support.FakeGraphics")
  local pool = SharedImagePoolFake.new()
  local graphics = FakeGraphics.new()
  local tallies = { request = 0, poll = 0, acquire = 0 }
  local rawRequest, rawPoll, rawAcquire = pool.request, pool.poll, pool.acquire
  function pool:request(path, sampler, priority)
    tallies.request = tallies.request + 1
    return rawRequest(self, path, sampler, priority)
  end
  function pool:poll(token)
    tallies.poll = tallies.poll + 1
    return rawPoll(self, token)
  end
  function pool:acquire(token)
    tallies.acquire = tallies.acquire + 1
    return rawAcquire(self, token)
  end
  local rawManifest = idleClosureManifest()
  local manifestReads = { count = 0 }
  local manifestView = setmetatable({}, {
    __index = function(_, key)
      manifestReads.count = manifestReads.count + 1
      return rawManifest[key]
    end,
  })
  local cacheLoads = { count = 0 }
  local producerCalls = { count = 0 }
  local gate = { ready = false }
  local args = ownerArgs(pool)
  args.graphics = graphics
  args.cacheFs = {
    loadLua = function(_)
      cacheLoads.count = cacheLoads.count + 1
      return manifestView
    end,
  }
  args.derivedAssets = {
    requestPokedex = function(_)
      producerCalls.count = producerCalls.count + 1
      if gate.ready then
        return true, nil
      end
      return false, nil
    end,
  }
  local owner = Owner.new(args)
  local opener = owner:acquire({ purpose = "browser" })
  local stalled = opener:prepare(pageDemand("grid", "settled-grid"))
  Assert.equal(stalled.kind, "pending", "an unready foreground demand stays pending")
  gate.ready = true
  local activated = pumpReady(opener, pageDemand("grid", "settled-grid"))
  Assert.notNil(activated, "the foreground open establishes the presentation")
  opener:release()
  local before = pool.uploads + #graphics.canvases
  local settled = false
  for _ = 1, 128 do
    local used, failure = owner:advanceWarmup(1)
    Assert.isNil(failure, "idle staging reports no failure on synthetic chrome")
    local delta = (pool.uploads + #graphics.canvases) - before
    before = pool.uploads + #graphics.canvases
    Assert.isTrue(delta <= 1, "one idle round realizes at most one image pair or canvas")
    if used == false then
      settled = true
      break
    end
  end
  Assert.isTrue(settled, "idle rounds finish the static closure and canvas group work")
  local snapshot = {
    request = tallies.request,
    poll = tallies.poll,
    acquire = tallies.acquire,
    canvases = #graphics.canvases,
    uploads = pool.uploads,
    manifest = manifestReads.count,
    loads = cacheLoads.count,
    producer = producerCalls.count,
  }
  for round = 1, 150 do
    local allowance = (round % 2 == 0) and 0 or 1
    local used, failure = owner:advanceWarmup(allowance)
    Assert.equal(used, false, "settled idle work admits no GPU realization")
    Assert.isNil(failure, "settled idle work reports no failure")
  end
  Assert.equal(tallies.request, snapshot.request, "settled idle issues no new image requests")
  Assert.equal(tallies.poll, snapshot.poll, "settled idle polls nothing again")
  Assert.equal(tallies.acquire, snapshot.acquire, "settled idle acquires nothing again")
  Assert.equal(#graphics.canvases, snapshot.canvases, "settled idle constructs no canvases")
  Assert.equal(pool.uploads, snapshot.uploads, "settled idle uploads no new images")
  Assert.equal(producerCalls.count, snapshot.producer, "settled idle reissues no producer demand")
  Assert.equal(cacheLoads.count, snapshot.loads, "settled idle reloads no manifests")
  Assert.equal(
    manifestReads.count,
    snapshot.manifest,
    "settled idle re-reads no static manifest state"
  )
  owner:release()
  Assert.equal(pool:stats().outstandingLeases, 0, "close returns every adopted image interest")
end

return { tests = T }
