-- Synthetic encounter fixtures for the wild-encounter suites: hand-built
-- encounter tables honoring the compiled catalog schema, deterministic
-- labeled random spies over the native battle stream, semantic attempt
-- contexts, and roamer/save reference sets. Every literal below is fixed
-- here from the native selection branches (per-method slot ladders and
-- replacement targets in romdump battle sources, opportunity/level windows
-- from the field encounter check); nothing is produced by the encounter
-- modules under test. The fixture requires only established owners, so it
-- loads whether or not the encounter modules exist.

local Assert = require("tests.support.Assert")
local BattleRng = require("libs.battle.src.gen4.BattleRng")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local ItemFixture = require("libs.items.tests.item_fixture")

local EncounterFixture = {}

--- Loads an encounter module, failing with the behavior it provides
--- instead of a bare loader error.
---@param name string
---@param behavior string
---@return table
function EncounterFixture.requirePresent(name, behavior)
  local ok, loaded = pcall(require, name)
  Assert.isTrue(ok, "missing encounter owner: " .. behavior .. " (" .. name .. ")")
  assert(loaded ~= nil, "the encounter module loads")
  return loaded --[[@as table]]
end

--- A labeled native stream that records every draw site while replaying
--- the exact generator outputs for its seed.
---@param seed integer
---@return table spy stream with calls/labels readers
function EncounterFixture.spyStream(seed)
  local inner = BattleRng.new(seed)
  local trace = {}
  local stream = {}
  function stream:nextU16(label, cause)
    trace[#trace + 1] = { label = label, cause = cause }
    return inner:nextU16(label, cause)
  end
  function stream:capture()
    return inner:capture()
  end
  function stream:calls()
    return inner:capture().calls
  end
  function stream:labels()
    local names = {}
    for _, entry in ipairs(trace) do
      names[#names + 1] = entry.label
    end
    return names
  end
  function stream:causes()
    local causes = {}
    for _, entry in ipairs(trace) do
      causes[#causes + 1] = entry.cause
    end
    return causes
  end
  return stream
end

---@param species string
---@param minLevel integer
---@param maxLevel integer
---@param weight integer
---@return table<string, unknown> schema-valid encounter slot
local function slot(species, minLevel, maxLevel, weight)
  return { species = species, form = 0, minLevel = minLevel, maxLevel = maxLevel, weight = weight }
end

-- The twelve ordered land slots shared by the vector tables. Two leading
-- duplicate species slots prove ordered intervals never merge.
local function meadowDay()
  return {
    slot("CHIKORITA", 4, 4, 20),
    slot("CHIKORITA", 4, 4, 20),
    slot("TOTODILE", 5, 5, 10),
    slot("TOTODILE", 6, 6, 10),
    slot("EEVEE", 7, 7, 10),
    slot("EEVEE", 8, 8, 10),
    slot("SHEDINJA", 9, 9, 5),
    slot("CHIKORITA", 10, 10, 5),
    slot("TOTODILE", 11, 11, 4),
    slot("EEVEE", 12, 12, 4),
    slot("SHEDINJA", 13, 13, 1),
    slot("CHIKORITA", 14, 14, 1),
  }
end

local function waterSlots(species, minLevel, maxLevel)
  return {
    slot(species, minLevel, maxLevel, 60),
    slot(species, minLevel, maxLevel, 30),
    slot(species, minLevel, maxLevel, 5),
    slot(species, minLevel, maxLevel, 4),
    slot(species, minLevel, maxLevel, 1),
  }
end

local function rodSlots()
  return {
    slot("CHIKORITA", 3, 5, 40),
    slot("TOTODILE", 4, 6, 30),
    slot("CHIKORITA", 5, 9, 15),
    slot("EEVEE", 6, 8, 10),
    slot("TOTODILE", 7, 10, 5),
  }
end

---@param species string
---@param nativeSlot integer
---@param game string
---@return table<string, unknown> replacement record
local function replacement(species, nativeSlot, game)
  return { species = species, slot = nativeSlot, game = game }
end

local function replacements(game)
  return {
    landSwarm = replacement("EEVEE", 0, game),
    surfSwarm = replacement("TOTODILE", 0, game),
    nightFish = replacement("EEVEE", 3, game),
    fishSwarm = replacement("SHEDINJA", 2, game),
    radioHoenn = replacement("SHEDINJA", 2, game),
    radioHoennAlt = replacement("TOTODILE", 4, game),
    radioSinnoh = replacement("EEVEE", 2, game),
    radioSinnohAlt = replacement("CHIKORITA", 4, game),
  }
end

local function special(game)
  return {
    safari = { context = "safari", version = game },
    bugContest = { context = "bug_contest", version = game },
    unown = { context = "unown", version = game },
    roaming = { context = "roaming", version = game },
  }
end

---@param day table
---@param rates table<string, integer>
---@param game string
---@return table<string, unknown> schema-valid map member table
local function memberTable(day, rates, game)
  return {
    rates = rates,
    land = { morning = meadowDay(), day = day, night = meadowDay() },
    surf = waterSlots("CHIKORITA", 10, 12),
    rockSmash = { slot("TOTODILE", 15, 20, 80), slot("CHIKORITA", 18, 22, 20) },
    oldRod = rodSlots(),
    goodRod = rodSlots(),
    superRod = rodSlots(),
    replacements = replacements(game),
    special = special(game),
  }
end

local function rates(walking, surfing, rockSmash, oldRod, goodRod, superRod)
  return {
    walking = walking,
    surfing = surfing,
    rockSmash = rockSmash,
    oldRod = oldRod,
    goodRod = goodRod,
    superRod = superRod,
  }
end

-- Member identities used across the suites: 11 always triggers on grass,
-- 12 never triggers anywhere, 13 carries a mid grass rate for modifier
-- boundaries, 14 always bites on the old rod with leveled water slots.
function EncounterFixture.vectorCatalog()
  local compiled = {
    schema = "vector-encounter-v1",
    version = { id = "soulsilver" },
    tables = {
      [11] = memberTable(meadowDay(), rates(100, 0, 0, 0, 0, 0), "soulsilver"),
      [12] = memberTable(meadowDay(), rates(0, 0, 0, 0, 0, 0), "soulsilver"),
      [13] = memberTable(meadowDay(), rates(30, 0, 0, 0, 0, 0), "soulsilver"),
      [14] = memberTable(meadowDay(), rates(0, 0, 0, 100, 0, 0), "soulsilver"),
    },
  }
  local BattleDataSchema = require("libs.assets.src.battle.BattleDataSchema")
  assert(BattleDataSchema.assertEncounterCatalog(compiled), "the vector catalog honors the compiled schema")
  return compiled
end

--- A mon catalog where the two-ability species carries observable held
--- item entries, for the wild held-item branches.
---@return { catalog: table, items: table }
function EncounterFixture.berryCatalogs()
  local function deepCopy(value, seen)
    seen = seen or {}
    if type(value) ~= "table" then
      return value
    end
    if seen[value] ~= nil then
      return seen[value]
    end
    local out = {}
    seen[value] = out
    for key, item in pairs(value) do
      out[deepCopy(key, seen)] = deepCopy(item, seen)
    end
    return out
  end
  local root = deepCopy(CatalogFixture.buildAssetRoot())
  root.species.EEVEE.heldItems.common = { item = "SITRUS_BERRY", nativeId = 158 }
  root.species.EEVEE.heldItems.rare = { item = "CHERI_BERRY", nativeId = 149 }
  local items = ItemFixture.makeCatalog()
  local Catalog = require("libs.mons.src.MonCatalog")
  return { catalog = Catalog.new(root, items), items = items }
end

---@param overrides table<string, unknown>|nil
---@return table semantic attempt context with neutral defaults
function EncounterFixture.context(overrides)
  local context = {
    eventId = 1,
    mapId = 11,
    worldX = 0,
    worldZ = 0,
    method = "grass",
    movement = "step",
    terrain = "grass",
    timeOfDay = "day",
    playerProfile = CatalogFixture.profile(),
    lead = nil,
    modifiers = {
      repel = false,
      swarm = false,
      radio = "none",
      rod = nil,
      static = nil,
      roamerKey = nil,
      leadAbility = nil,
      leadNature = nil,
    },
    environment = { weather = "none" },
  }
  for key, value in pairs(overrides or {}) do
    context[key] = value
  end
  return context
end

---@param overrides table<string, unknown>|nil
---@return table modifier set with neutral defaults
function EncounterFixture.modifiers(overrides)
  local modifiers = {
    repel = false,
    swarm = false,
    radio = "none",
    rod = nil,
    static = nil,
    roamerKey = nil,
    leadAbility = nil,
    leadNature = nil,
  }
  for key, value in pairs(overrides or {}) do
    modifiers[key] = value
  end
  return modifiers
end

---@return { species: table<string, boolean>, maps: table<integer, boolean> } selected-reference sets
function EncounterFixture.refs()
  return {
    species = { CHIKORITA = true, TOTODILE = true, EEVEE = true, SHEDINJA = true },
    maps = { [11] = true, [12] = true, [22] = true },
  }
end

---@param species string
---@param level integer
---@param seed integer
---@return table persistent mon record from the mon domain owner
function EncounterFixture.mon(species, level, seed)
  local factory = CatalogFixture.makeFactory(seed, CatalogFixture.makeCatalog())
  return factory:createNormal(CatalogFixture.normalRequest({ species = species, level = level }))
end

---@return table damaged roaming mon with a status marker
function EncounterFixture.roamerMon()
  local mon = EncounterFixture.mon("EEVEE", 20, 77)
  mon.condition.currentHp = 12
  mon.condition.effects = { { key = "burn" } }
  return mon
end

---@param mon table
---@param location integer
---@param lifecycle string
---@param revision integer
---@return table roamer record with the given lifecycle state
function EncounterFixture.roamerRecord(mon, location, lifecycle, revision)
  return {
    key = "roamer-eevee",
    stateVersion = 1,
    mon = mon,
    location = location,
    lifecycle = lifecycle,
    revision = revision,
  }
end

return EncounterFixture
