-- Near-urgency warmup for the live party's compiled assets. One call walks
-- the current party and enrolls icon pages, portrait pages, cry banks,
-- and battle effects for every known move at near urgency so opening the
-- party, summary, or bag, hearing a cry, or entering battle never pays
-- the first-compilation stall. Warmup never raises and never gates: the
-- required display demands stay the correctness path, while missing
-- manifests, missing host methods, eggs, and unusable moves only narrow
-- the warmed set. A false return names a transient staging gap the caller
-- should retry once staged; per-mon derivation skips never fail the walk
-- because the opening screens surface corrupt party data loudly on their
-- own required path.

local MonCache = require("libs.assets.src.MonCache")
local MonAssetSchema = require("libs.assets.src.MonAssetSchema")
local CryPlayer = require("libs.hgss.src.audio.CryPlayer")
local PartyScreenModel = require("libs.hgss.src.ui.PartyScreenModel")
local SummaryModel = require("libs.hgss.src.ui.SummaryModel")

local PartyAssetPrefetch = {}

-- Placeholder and unmapped move entries never name a compiled effect:
-- NONE fills empty slots and unknown keys fail the worker loudly, and a
-- speculative near demand would latch that failure onto the later
-- required battle demand for the same key.
local SKIPPED_MOVES = { NONE = true }

---@param manifest table<string, unknown>? loaded selector manifest
---@param selector string canonical icon or portrait selector
---@return integer? page id behind the selector, nil when unresolvable
local function pageFor(manifest, selector)
  if type(manifest) ~= "table" or type(manifest.entries) ~= "table" then
    return nil
  end
  local entry = manifest.entries[selector]
  if type(entry) ~= "table" then
    return nil
  end
  local pageId = entry.pageId
  if type(pageId) ~= "number" or pageId % 1 ~= 0 or pageId < 0 then
    return nil
  end
  return pageId --[[@as integer]]
end

---@param host table<string, function> borrowed semantic derived-asset host
---@param method string host demand method behind one asset class
---@param id integer|string staged asset identity behind the method
---@param warmed table<string, boolean> identities already enrolled this call
---@return boolean enrolled or deduplicated, false when the host lacks the class or refused it
local function enroll(host, method, id, warmed)
  local demand = host[method]
  if type(demand) ~= "function" then
    return false
  end
  local key = method .. ":" .. tostring(id)
  if warmed[key] then
    return true
  end
  warmed[key] = true
  -- A retired provisioner raises instead of enrolling: warmup treats the
  -- lost enrollment like a skipped class, since selection teardown owns
  -- the retirement and the walk itself must never fail the field update.
  local ok = pcall(demand, id, "near")
  if not ok then
    warmed[key] = nil
    return false
  end
  return true
end

---@param catalog table<string, unknown> live mon catalog
---@param moveKey unknown candidate battle-effect key from a party move entry
---@return string? valid flat effect key, nil for placeholders and unknown moves
local function effectKeyFor(catalog, moveKey)
  if type(moveKey) ~= "string" or moveKey == "" or moveKey:find("/", 1, true) ~= nil then
    return nil
  end
  if SKIPPED_MOVES[moveKey] then
    return nil
  end
  local ok, definition = pcall(function()
    return catalog:move(moveKey)
  end)
  if not ok or type(definition) ~= "table" then
    return nil
  end
  -- moveKeys[0] ("NONE") is explicitly excluded from the source effect
  -- routes, so a zero native id never names a compiled animation.
  if type(definition.nativeId) ~= "number" or definition.nativeId == 0 then
    return nil
  end
  return moveKey
end

---@param service table<string, function> live mon service reads
---@param catalog table<string, unknown> live mon catalog
---@param mon table<string, unknown> owned party mon copy
---@param manifests { icons: table<string, unknown>?, portraits: table<string, unknown>? } staged selector manifests
---@param host table<string, function> borrowed semantic derived-asset host
---@param warmed table<string, boolean> identities already enrolled this call
local function warmMon(service, catalog, mon, manifests, host, warmed)
  local iconKey = PartyScreenModel.iconKeyFor(service, mon)
  local iconPage = pageFor(manifests.icons, iconKey)
  if iconPage ~= nil then
    enroll(host, "requestIconPage", iconPage, warmed)
  end
  if mon.isEgg == true then
    return
  end
  local portraitSelector = SummaryModel.portraitSelectorFor(catalog, mon)
  local portraitPage = pageFor(manifests.portraits, portraitSelector)
  if portraitPage ~= nil then
    enroll(host, "requestMonPortraitPage", portraitPage, warmed)
  end
  local species = catalog:species(mon.species)
  enroll(
    host,
    "requestAudioBank",
    CryPlayer.bankFor(assert(species.nativeId, "catalog species carry a native id"), mon.form),
    warmed
  )
  local moves = mon.moves
  if type(moves) ~= "table" then
    return
  end
  for _, entry in ipairs(moves) do
    if type(entry) == "table" then
      local effectKey = effectKeyFor(catalog, entry.move)
      if effectKey ~= nil then
        enroll(host, "requestBattleEffect", effectKey, warmed)
      end
    end
  end
end

---@param cacheFs table<string, unknown> version cache filesystem
---@return { icons: table<string, unknown>?, portraits: table<string, unknown>? } staged selector manifests, nil per missing class
local function loadManifests(cacheFs)
  local manifests = {}
  local icons = cacheFs:loadLua(MonCache.iconManifestPath())
  if MonAssetSchema.isValidIconManifest(icons) then
    manifests.icons = icons
  end
  local portraits = cacheFs:loadLua(MonCache.portraitManifestPath())
  if MonAssetSchema.isValidPortraitManifest(portraits) then
    manifests.portraits = portraits
  end
  return manifests
end

---@param options { monService: table<string, unknown>, cacheFs: table<string, unknown>, derivedAssets: table<string, function> }
---@return boolean warmed or nothing to do; false names a transient staging gap to retry
---@return string? deferral cause when false, nil otherwise
function PartyAssetPrefetch.prefetch(options)
  assert(type(options) == "table", "party warmup requires its composition")
  local service = assert(options.monService, "party warmup requires the live mon service")
  local cacheFs = assert(options.cacheFs, "party warmup requires the version cache filesystem")
  local host = assert(options.derivedAssets, "party warmup requires the semantic derived-asset host")
  assert(type(service.partyCount) == "function", "party warmup reads the party count")
  assert(type(service.partyMon) == "function", "party warmup reads party mons")
  assert(type(service.catalog) == "function", "party warmup reads the mon catalog")
  assert(type(cacheFs.loadLua) == "function", "party warmup reads selector manifests")
  local count = service:partyCount()
  if count == 0 then
    return true
  end
  local catalog = service:catalog()
  local manifests = loadManifests(cacheFs)
  local warmed = {}
  for slot0 = 0, count - 1 do
    -- One corrupt mon never cancels warmup for the rest of the party:
    -- the opening screens fail loudly on their required path while the
    -- healthy members still enroll here.
    local monOk, monOrError = pcall(function()
      return service:partyMon(slot0)
    end)
    if monOk and type(monOrError) == "table" then
      pcall(warmMon, service, catalog, monOrError, manifests, host, warmed)
    end
  end
  if manifests.icons == nil or manifests.portraits == nil then
    return false, "party warmup deferred until the mon selector manifests stage"
  end
  return true
end

return PartyAssetPrefetch
