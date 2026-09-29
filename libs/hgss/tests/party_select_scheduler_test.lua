-- Script-driven party selection through the real scheduler: a script
-- graph with the launch and companion result nodes runs against the
-- registered current task, the real script-owned host, the real pick
-- screen and manifest, and the live mon service. Covers selecting a
-- slot with continuation, cancel focus into the source value, resume
-- from a captured bucket with a reread live party, and rejection of a
-- stale task shape. ROM-backed manifest; no GPU rendering.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local Composition = require("libs.script.src.Composition")
local Errors = require("libs.errors.src.Errors")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local GameVersion = require("romdump.src.source.GameVersion")
local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")
local PartyCache = require("libs.assets.src.PartyCache")
local PartySelectTask = require("libs.hgss.src.script.tasks.PartySelectTask")
local Registry = require("libs.script.src.Registry")
local RomImporter = require("romdump.src.source.RomImporter")
local S = require("gen4.script")
local Scheduler = require("libs.script.src.Scheduler")
local ScriptSave = require("libs.script.src.ScriptSave")
local ScreenTopology = require("libs.hgss.src.ui.ScreenTopology")
local RuntimeValues = require("libs.hgss.src.script.RuntimeValues")
local TaskRegistry = require("libs.script.src.TaskRegistry")

local HOST_MODULE = "game.hgss.src.field.PartySelectionHost"

local T = { metadata = { capabilities = { "rom_dump", "derived_assets" }, derivedAssets = { "party:global" } }, tests = {} }

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
    bucket = MonsSave.capture(Party.new():capture(), Lcrng.new(0xCCCCCCCC):capture(), catalog:fingerprint()),
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

local function stubMeasurement()
  return {
    width = 256,
    height = 192,
    topology = ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = 256, height = 192 },
      role = "world",
      touch = true,
    }),
    pixelRatio = 1,
    signature = "stub:256x192",
  }
end

local function openHost(versionId, service)
  local Host = assert(require(HOST_MODULE))
  local cacheFs = CacheFs.forVersion(versionId)
  return Host.new({
    service = service,
    manifest = PartyCache.loadManifest(cacheFs),
    measureDisplay = stubMeasurement,
    uiManifest = FieldUiFixture.manifest(),
    prepareIcons = function(_)
      return true
    end,
    cancelIconPreparation = function() end,
  })
end

local function harness(versionId, service)
  local world = { variables = {} }
  function world:getVar(id)
    return self.variables[id] or 0
  end
  function world:setVar(id, value)
    self.variables[id] = value
  end
  local services = {
    mons = service,
    partySelection = openHost(versionId, service),
    world = world,
  }
  local registry = Registry.new()
  local composition = Composition.new(registry)
  local taskRegistry = TaskRegistry.new()
  taskRegistry:register(PartySelectTask.type, PartySelectTask.version, PartySelectTask)
  local scheduler = Scheduler.new({
    semantics = RuntimeValues,
    services = services,
    taskRegistry = taskRegistry,
    resolveComposition = function(id)
      return composition:effective(id)
    end,
  })
  return {
    services = services,
    registry = registry,
    composition = composition,
    scheduler = scheduler,
  }
end

local function selectionScript(id)
  return S.script({
    api = 1,
    id = id,
    steps = {
      S.partySelect({}),
      S.partySelectResult({ result = S.var("VAR_PICK") }),
      S.setVar({ variable = "VAR_AFTER", value = 1 }),
      S.stop(),
    },
  })
end

local DRIVE_DIRECTIONS = { "down", "right", "down", "left", "up", "right" }

local function driveToSlot(h, tick, slot)
  local dirIndex = 0
  for _ = 1, 24 do
    local handle = h.services.partySelection:activeHandle()
    if handle ~= nil and h.services.partySelection:focus(handle) == slot then
      return tick
    end
    dirIndex = dirIndex + 1
    local direction = DRIVE_DIRECTIONS[(dirIndex - 1) % #DRIVE_DIRECTIONS + 1]
    tick = tick + 1
    h.scheduler:step(tick, { uiEvents = { { type = "navigate", direction = direction } } })
  end
  error("the script selection never focused slot " .. tostring(slot), 0)
  return tick
end

function T.tests.select_slot_completes_once_and_resumes(context)
  local versions = readyVersions()
  if #versions == 0 then
    if context ~= nil and type(context.hasCapability) == "function" then
      context:skip("requires rom_dump and prepared assets")
    end
    error("script party selection needs a ready versioned cache", 0)
  end
  for _, versionId in ipairs(versions) do
    local service = openService()
    give(service, "CHIKORITA")
    give(service, "TOTODILE")
    give(service, "EEVEE")
    local h = harness(versionId, service)
    local script = selectionScript("test.selection_completes")
    h.registry:installBase(script.id, script, "generated")
    h.scheduler:createForeground(assert(h.composition:effective(script.id)), nil, 100)
    h.scheduler:step(100, {})
    local tick = driveToSlot(h, 100, 2)
    tick = tick + 1
    h.scheduler:step(tick, { uiEvents = { { type = "confirm" } } })
    tick = tick + 1
    h.scheduler:step(tick, {})
    Assert.equal(h.services.world:getVar("VAR_PICK"), 2, "confirming the second slot parks two")
    Assert.equal(h.services.world:getVar("VAR_AFTER"), 1, "the script continues past the result node")
    h.scheduler:step(tick + 1, { uiEvents = { { type = "confirm" } } })
    Assert.equal(h.services.world:getVar("VAR_PICK"), 2, "a settled selection never recompletes")
  end
end

function T.tests.cancel_focus_yields_the_source_value(context)
  local versions = readyVersions()
  if #versions == 0 then
    if context ~= nil and type(context.hasCapability) == "function" then
      context:skip("requires rom_dump and prepared assets")
    end
    error("script party selection needs a ready versioned cache", 0)
  end
  for _, versionId in ipairs(versions) do
    local service = openService()
    give(service, "CHIKORITA")
    local h = harness(versionId, service)
    local script = selectionScript("test.selection_cancel")
    h.registry:installBase(script.id, script, "generated")
    h.scheduler:createForeground(assert(h.composition:effective(script.id)), nil, 100)
    h.scheduler:step(100, {})
    local tick = driveToSlot(h, 100, "cancel")
    tick = tick + 1
    h.scheduler:step(tick, {})
    tick = tick + 1
    h.scheduler:step(tick, {})
    tick = tick + 1
    h.scheduler:step(tick, { uiEvents = { { type = "confirm" } } })
    tick = tick + 1
    h.scheduler:step(tick, {})
    Assert.equal(h.services.world:getVar("VAR_PICK"), 255, "confirming cancel parks the source value")
    Assert.equal(h.services.world:getVar("VAR_AFTER"), 1, "cancellation still resumes the script")
  end
end

function T.tests.resume_rereads_the_live_party(context)
  local versions = readyVersions()
  if #versions == 0 then
    if context ~= nil and type(context.hasCapability) == "function" then
      context:skip("requires rom_dump and prepared assets")
    end
    error("script party selection needs a ready versioned cache", 0)
  end
  for _, versionId in ipairs(versions) do
    local service = openService()
    give(service, "CHIKORITA")
    give(service, "TOTODILE")
    local h = harness(versionId, service)
    local script = selectionScript("test.selection_resume")
    h.registry:installBase(script.id, script, "generated")
    h.scheduler:createForeground(assert(h.composition:effective(script.id)), nil, 100)
    h.scheduler:step(100, {})
    local tick = driveToSlot(h, 100, 1)
    local bucket = ScriptSave.capture(h.scheduler, tick, { registryFingerprint = h.registry:fingerprint() })
    Assert.equal(#bucket.tasks, 1, "the blocked selection captures one task")
    Assert.equal(bucket.tasks[1].taskType, "party_select")
    -- The live party grows between capture and restore: resume must
    -- reread it instead of replaying a stale snapshot.
    give(service, "EEVEE")
    local h2 = harness(versionId, service)
    h2.registry:installBase(script.id, script, "generated")
    ScriptSave.restore(bucket, h2.scheduler, tick, {})
    tick = tick + 1
    h2.scheduler:step(tick, {})
    Assert.equal(service:partyCount(), 3, "restore publishes nothing early")
    tick = tick + 1
    h2.scheduler:step(tick, { uiEvents = { { type = "confirm" } } })
    tick = tick + 1
    h2.scheduler:step(tick, {})
    Assert.equal(h2.services.world:getVar("VAR_PICK"), 1, "the resumed selection keeps its cursor")
    Assert.equal(h2.services.world:getVar("VAR_AFTER"), 1)
  end
end

function T.tests.stale_shape_is_rejected(context)
  local versions = readyVersions()
  if #versions == 0 then
    if context ~= nil and type(context.hasCapability) == "function" then
      context:skip("requires rom_dump and prepared assets")
    end
    error("script party selection needs a ready versioned cache", 0)
  end
  for _, versionId in ipairs(versions) do
    local service = openService()
    give(service, "CHIKORITA")
    local h = harness(versionId, service)
    local script = selectionScript("test.selection_stale")
    h.registry:installBase(script.id, script, "generated")
    h.scheduler:createForeground(assert(h.composition:effective(script.id)), nil, 100)
    h.scheduler:step(100, {})
    local bucket = ScriptSave.capture(h.scheduler, 100, { registryFingerprint = h.registry:fingerprint() })
    Assert.equal(#bucket.tasks, 1)
    local record = assert(bucket.tasks[1], "the blocked selection captures its task")
    Assert.equal(record.taskVersion, 2, "the capture carries the current shape")
    record.taskVersion = 1
    local h2 = harness(versionId, service)
    h2.registry:installBase(script.id, script, "generated")
    local ok, err = pcall(function()
      ScriptSave.restore(bucket, h2.scheduler, 100, {})
    end)
    Assert.isFalse(ok, "an older task shape never resumes silently")
    Assert.isTrue(Errors.is(err), "rejection carries a typed error")
  end
end

return T
