-- Near-urgency warmup for the live party's compiled assets: one call walks
-- the current party and enrolls icon pages, portrait pages, cry banks,
-- and battle effects for every known move at near urgency. Warmup never
-- raises and never gates: missing manifests, missing host methods, eggs,
-- and unknown moves are skipped while the required display demands stay
-- the correctness path.

local Assert = require("tests.support.Assert")
local PartyAssetPrefetch = require("game.hgss.src.field.PartyAssetPrefetch")

local T = {}

local function manifest(schema, entries)
  local pages = { [0] = { pageId = 0, image = "assets/generated/mon/pages/0.png", width = 64, height = 64 } }
  local built = {
    schema = schema,
    version = { id = "test", language = "en" },
    pages = pages,
    pageIds = { 0 },
    entries = {},
    representative = {},
  }
  for selector, pageId in pairs(entries) do
    built.entries[selector] = {
      x = 0,
      y = 0,
      width = 16,
      height = 16,
      frames = { { x = 0, y = 0, width = 16, height = 16, duration = 1 } },
      pageId = pageId,
    }
    built.representative[#built.representative + 1] = selector
  end
  return built
end

local function mon(overrides)
  local record = {
    species = "PIKACHU",
    form = 0,
    personality = 7,
    isEgg = false,
    moves = { { move = "THUNDERBOLT", pp = 15, ppUps = 0 } },
    origin = { trainerId = 1000 },
    condition = {},
    heldItem = "NONE",
  }
  if overrides ~= nil then
    for key, value in pairs(overrides) do
      record[key] = value
    end
  end
  return record
end

local function catalogFake()
  return {
    species = function(_, key)
      assert(key == "PIKACHU", "the fake catalog only knows PIKACHU")
      return { nativeId = 25, genderRatio = 0 }
    end,
    form = function(_, speciesKey, form)
      assert(speciesKey == "PIKACHU" and form == 0, "the fake catalog only knows PIKACHU form 0")
      return { portrait = "PIKACHU/f0/male/plain" }
    end,
    iconSelection = function(_, _)
      return "PIKACHU/f0"
    end,
    move = function(_, key)
      if key == "THUNDERBOLT" then
        return { nativeId = 85 }
      end
      if key == "SPLASH" then
        return { nativeId = 150 }
      end
      error("unknown move " .. tostring(key), 0)
    end,
  }
end

local function optionsFor(overrides)
  local options = {
    monService = {
      partyCount = function()
        return 1
      end,
      partyRevision = function()
        return 3
      end,
      partyMon = function(_)
        return mon()
      end,
      catalog = function()
        return catalogFake()
      end,
    },
    catalog = catalogFake(),
    cacheFs = {
      loadLua = function(_)
        return nil
      end,
    },
    derivedAssets = {},
  }
  if overrides ~= nil then
    for key, value in pairs(overrides) do
      options[key] = value
    end
  end
  return options
end

local function loggingHost(log)
  local function record(kind)
    return function(id, urgency)
      log[#log + 1] = { kind = kind, id = id, urgency = urgency }
      return true
    end
  end
  return {
    requestIconPage = record("icon"),
    requestMonPortraitPage = record("portrait"),
    requestAudioBank = record("audio"),
    requestBattleEffect = record("effect"),
  }
end

local function cacheFsWith(iconManifest, portraitManifest)
  local MonCache = require("libs.assets.src.MonCache")
  return {
    loadLua = function(_, path)
      if path == MonCache.iconManifestPath() then
        return iconManifest
      end
      if path == MonCache.portraitManifestPath() then
        return portraitManifest
      end
      return nil
    end,
  }
end

local function kinds(log)
  local seen = {}
  for _, entry in ipairs(log) do
    seen[entry.kind .. ":" .. tostring(entry.id) .. ":" .. tostring(entry.urgency)] = true
  end
  return seen
end

function T.warms_party_pages_cries_and_move_effects_at_near_urgency()
  local log = {}
  local options = optionsFor({
    cacheFs = cacheFsWith(
      manifest("g4-mon-icon-manifest-v2", { ["PIKACHU/f0"] = 0 }),
      manifest("g4-mon-portrait-manifest-v2", { ["PIKACHU/f0/male/plain"] = 0 })
    ),
    derivedAssets = loggingHost(log),
  })
  local ok, reason = PartyAssetPrefetch.prefetch(options)
  Assert.isTrue(ok, "a fully resolvable party warms without deferring")
  Assert.isNil(reason)
  local seen = kinds(log)
  Assert.isTrue(seen["icon:0:near"] == true, "the party icon page enrolls as near")
  Assert.isTrue(seen["portrait:0:near"] == true, "the party portrait page enrolls as near")
  Assert.isTrue(seen["audio:25:near"] == true, "the party cry bank enrolls as near")
  Assert.isTrue(seen["effect:THUNDERBOLT:near"] == true, "a known move enrolls its battle effect as near")
end

function T.skips_portraits_and_cries_for_eggs()
  local log = {}
  local eggService = {
    partyCount = function()
      return 1
    end,
    partyRevision = function()
      return 3
    end,
    partyMon = function(_)
      return mon({ isEgg = true })
    end,
    catalog = function()
      return catalogFake()
    end,
  }
  local options = optionsFor({
    monService = eggService,
    cacheFs = cacheFsWith(
      manifest("g4-mon-icon-manifest-v2", { ["PIKACHU/egg"] = 0 }),
      manifest("g4-mon-portrait-manifest-v2", { ["PIKACHU/f0/male/plain"] = 0 })
    ),
    derivedAssets = loggingHost(log),
  })
  local ok, _ = PartyAssetPrefetch.prefetch(options)
  Assert.isTrue(ok, "an egg-only party still warms its icon page")
  local seen = kinds(log)
  Assert.isTrue(seen["icon:0:near"] == true, "the egg icon page enrolls as near")
  Assert.isNil(seen["portrait:0:near"], "eggs enroll no portrait page")
  Assert.isNil(seen["audio:25:near"], "eggs enroll no cry bank")
end

function T.skips_placeholder_and_unknown_moves()
  local log = {}
  local moveService = {
    partyCount = function()
      return 1
    end,
    partyRevision = function()
      return 3
    end,
    partyMon = function(_)
      return mon({
        moves = {
          { move = "NONE", pp = 0, ppUps = 0 },
          { move = "NOT_A_MOVE", pp = 5, ppUps = 0 },
          { move = "SPLASH", pp = 40, ppUps = 0 },
        },
      })
    end,
    catalog = function()
      return catalogFake()
    end,
  }
  local options = optionsFor({
    monService = moveService,
    cacheFs = cacheFsWith(
      manifest("g4-mon-icon-manifest-v2", { ["PIKACHU/f0"] = 0 }),
      manifest("g4-mon-portrait-manifest-v2", { ["PIKACHU/f0/male/plain"] = 0 })
    ),
    derivedAssets = loggingHost(log),
  })
  local ok, _ = PartyAssetPrefetch.prefetch(options)
  Assert.isTrue(ok, "unusable move entries never fail warmup")
  local seen = kinds(log)
  Assert.isNil(seen["effect:NONE:near"], "the placeholder move enrolls no battle effect")
  Assert.isNil(seen["effect:NOT_A_MOVE:near"], "an unknown move enrolls no battle effect")
  Assert.isTrue(seen["effect:SPLASH:near"] == true, "a known move still enrolls its battle effect")
end

function T.defers_when_manifests_are_unstaged()
  local log = {}
  local options = optionsFor({
    cacheFs = cacheFsWith(nil, nil),
    derivedAssets = loggingHost(log),
  })
  local ok, reason = PartyAssetPrefetch.prefetch(options)
  Assert.isFalse(ok, "missing manifests defer warmup instead of failing it")
  Assert.isTrue(type(reason) == "string", "the deferral names its cause")
  local seen = kinds(log)
  Assert.isNil(seen["icon:0:near"], "no icon page warms without its manifest")
  Assert.isNil(seen["portrait:0:near"], "no portrait page warms without its manifest")
  Assert.isTrue(seen["audio:25:near"] == true, "manifest-free cries still warm")
  Assert.isTrue(seen["effect:THUNDERBOLT:near"] == true, "manifest-free move effects still warm")
end

function T.empty_party_warms_nothing()
  local log = {}
  local emptyService = {
    partyCount = function()
      return 0
    end,
    partyRevision = function()
      return 0
    end,
    partyMon = function(_)
      error("an empty party reads no mons", 0)
    end,
    catalog = function()
      return catalogFake()
    end,
  }
  local options = optionsFor({ monService = emptyService, derivedAssets = loggingHost(log) })
  local ok, _ = PartyAssetPrefetch.prefetch(options)
  Assert.isTrue(ok, "an empty party is fully warmed by definition")
  Assert.equal(#log, 0, "an empty party enrolls nothing")
end

return { tests = T }
