-- Authoritative validation for the generated Day Care care family: the source
-- PMS egg-species table, the personal egg-move list, and the source incense
-- pairs, plus the hatch application's own generated presentation (its
-- background, egg and reveal-bar animation frames, the compiled particle
-- emitters with their staged textures, the source shake tables it draws with,
-- and the message bank lines the scene prints). Both payloads carry normalized
-- semantic meaning only; native ids and archive offsets stay producer-side.
-- Runtime trusts published artifacts and must not duplicate this validation.
-- Unknown fields, dangling shells, and duplicated entries fail loudly.

local Contract = require("libs.assets.src.DerivedAssetContract")
local SchemaCheck = require("libs.assets.src.SchemaCheck")
local Validate = require("libs.assets.src.Validate")

---@class PokemonCareAssetSchema
local PokemonCareAssetSchema = {}

PokemonCareAssetSchema.CATALOG_SCHEMA = Contract.pokemonCare.catalogSchema
PokemonCareAssetSchema.HATCH_SCHEMA = Contract.pokemonCare.hatchSchema

local CATALOG_ERROR = "POKEMON_CARE_CATALOG_INVALID"
local HATCH_ERROR = "POKEMON_CARE_HATCH_INVALID"
local fail = SchemaCheck.fail

local CATALOG_FIELDS = { schema = true, eggSpecies = true, eggMoves = true, incense = true }
local INCENSE_FIELDS = { baby = true, item = true, parent = true }

---@param value unknown
---@param what string
---@return table
local function requireRecord(value, what)
  if type(value) ~= "table" then
    fail(CATALOG_ERROR, what .. " must be a record", {})
  end
  assert(type(value) == "table")
  return value
end

---@param value unknown
---@param what string
---@param count integer?
---@return table
local function requireArray(value, what, count)
  if not Validate.isArray(value) or (count ~= nil and #value ~= count) then
    fail(
      CATALOG_ERROR,
      what .. (count and (" must contain exactly " .. count .. " entries") or " must be a contiguous array"),
      {}
    )
  end
  assert(type(value) == "table")
  return value
end

function PokemonCareAssetSchema.assertCatalog(catalog)
  local context = {}
  requireRecord(catalog, "care catalog")
  SchemaCheck.checkKeys(catalog, CATALOG_FIELDS, context, CATALOG_ERROR, "care catalog")
  if catalog.schema ~= PokemonCareAssetSchema.CATALOG_SCHEMA then
    fail(CATALOG_ERROR, "care catalog schema is not current", {})
  end

  local eggSpecies = requireRecord(catalog.eggSpecies, "eggSpecies")
  if next(eggSpecies) == nil then
    fail(CATALOG_ERROR, "eggSpecies must name at least one species", {})
  end
  for motherKey, eggKey in pairs(eggSpecies) do
    SchemaCheck.checkNonEmptyString(motherKey, context, CATALOG_ERROR, "eggSpecies key")
    SchemaCheck.checkNonEmptyString(eggKey, context, CATALOG_ERROR, "eggSpecies." .. tostring(motherKey))
  end

  -- The source breeding list is authoritative and repeats a move inside some
  -- species blocks, so the catalog keeps its exact order and duplicates; the
  -- runtime skips a move the offspring already knows.
  local eggMoves = requireRecord(catalog.eggMoves, "eggMoves")
  for speciesKey, moves in pairs(eggMoves) do
    SchemaCheck.checkNonEmptyString(speciesKey, context, CATALOG_ERROR, "eggMoves key")
    requireArray(moves, "eggMoves." .. speciesKey)
    if #moves == 0 then
      fail(CATALOG_ERROR, "eggMoves." .. speciesKey .. " must name at least one move", {})
    end
    for _, moveKey in ipairs(moves) do
      SchemaCheck.checkNonEmptyString(moveKey, context, CATALOG_ERROR, "eggMoves." .. speciesKey .. " move")
    end
  end

  local incense = requireArray(catalog.incense, "incense")
  if #incense == 0 then
    fail(CATALOG_ERROR, "incense must carry the source pairs", {})
  end
  local seenBabies = {}
  for index, row in ipairs(incense) do
    local what = "incense[" .. index .. "]"
    requireRecord(row, what)
    assert(type(row) == "table")
    SchemaCheck.checkKeys(row, INCENSE_FIELDS, context, CATALOG_ERROR, what)
    for _, field in ipairs({ "baby", "item", "parent" }) do
      SchemaCheck.checkNonEmptyString(row[field], context, CATALOG_ERROR, what .. "." .. field)
    end
    if seenBabies[row.baby] then
      fail(CATALOG_ERROR, what .. " repeats the baby " .. row.baby, {})
    end
    seenBabies[row.baby] = true
  end
  return true
end

---@param catalog unknown
---@return boolean
function PokemonCareAssetSchema.isValidCatalog(catalog)
  return pcall(PokemonCareAssetSchema.assertCatalog, catalog)
end

-- The hatch presentation payload: one composed background surface, the egg and
-- reveal-bar animation frames in source order, the compiled particle emitters
-- per scene variant with their staged textures, and the four message lines the
-- scene prints. Frames and textures name staged image paths; nothing here
-- carries raw ROM bytes or source member indices.
local HATCH_FIELDS = {
  schema = true,
  background = true,
  window = true,
  egg = true,
  bars = true,
  messages = true,
  particles = true,
}
local FRAME_FIELDS = { image = true, width = true, height = true, durationTicks = true }
local HATCH_GROUP_FIELDS = { frames = true }
local WINDOW_FIELDS = { x = true, y = true, width = true, height = true }
local MESSAGE_FIELDS = { id = true, text = true, align = true }
local MESSAGE_KEYS = { "hatched", "nicknameQuestion", "yes", "no" }
local PARTICLE_VARIANTS = { egg = true, manaphy = true }

---@param value unknown
---@param what string
---@return integer
local function requireInteger(value, what)
  if type(value) ~= "number" or value % 1 ~= 0 or value < 0 then
    fail(HATCH_ERROR, what .. " must be a non-negative integer", {})
  end
  return value --[[@as integer]]
end

-- One animation group: a contiguous frame array in source order, each frame a
-- staged image with its source extent and duration.
---@param value unknown
---@param what string
---@return table
local function requireFrameGroup(value, what)
  local group = requireRecord(value, what)
  SchemaCheck.checkKeys(group, HATCH_GROUP_FIELDS, {}, HATCH_ERROR, what)
  local frames = requireArray(group.frames, what .. ".frames")
  if #frames == 0 then
    fail(HATCH_ERROR, what .. " must carry at least one frame", {})
  end
  for index, frame in ipairs(frames) do
    local where = what .. ".frames[" .. index .. "]"
    requireRecord(frame, where)
    assert(type(frame) == "table")
    SchemaCheck.checkKeys(frame, FRAME_FIELDS, {}, HATCH_ERROR, where)
    SchemaCheck.checkNonEmptyString(frame.image, {}, HATCH_ERROR, where .. ".image")
    requireInteger(frame.width, where .. ".width")
    requireInteger(frame.height, where .. ".height")
    requireInteger(frame.durationTicks, where .. ".durationTicks")
  end
  return group
end

---@param catalog unknown
---@return boolean
function PokemonCareAssetSchema.isValidHatchManifest(catalog)
  return pcall(PokemonCareAssetSchema.assertHatchManifest, catalog)
end

function PokemonCareAssetSchema.assertHatchManifest(manifest)
  local context = {}
  requireRecord(manifest, "hatch manifest")
  SchemaCheck.checkKeys(manifest, HATCH_FIELDS, context, HATCH_ERROR, "hatch manifest")
  if manifest.schema ~= PokemonCareAssetSchema.HATCH_SCHEMA then
    fail(HATCH_ERROR, "hatch manifest schema is not current", {})
  end

  local background = requireRecord(manifest.background, "background")
  assert(type(background) == "table")
  SchemaCheck.checkKeys(background, { image = true, width = true, height = true }, context, HATCH_ERROR, "background")
  SchemaCheck.checkNonEmptyString(background.image, context, HATCH_ERROR, "background.image")
  requireInteger(background.width, "background.width")
  requireInteger(background.height, "background.height")

  local window = requireRecord(manifest.window, "window")
  assert(type(window) == "table")
  SchemaCheck.checkKeys(window, WINDOW_FIELDS, context, HATCH_ERROR, "window")
  for _, field in ipairs({ "x", "y", "width", "height" }) do
    requireInteger(window[field], "window." .. field)
  end
  if window.width == 0 or window.height == 0 then
    fail(HATCH_ERROR, "the message window must cover at least one pixel", {})
  end

  requireFrameGroup(manifest.egg, "egg")
  requireFrameGroup(manifest.bars, "bars")

  local messages = requireRecord(manifest.messages, "messages")
  assert(type(messages) == "table")
  SchemaCheck.checkKeys(messages, { hatched = true, nicknameQuestion = true, yes = true, no = true }, context,
    HATCH_ERROR, "messages")
  for _, key in ipairs(MESSAGE_KEYS) do
    local line = requireRecord(messages[key], "messages." .. key)
    assert(type(line) == "table")
    SchemaCheck.checkKeys(line, MESSAGE_FIELDS, context, HATCH_ERROR, "messages." .. key)
    requireInteger(line.id, "messages." .. key .. ".id")
    SchemaCheck.checkNonEmptyString(line.text, context, HATCH_ERROR, "messages." .. key .. ".text")
    if line.align ~= nil and line.align ~= "center" and line.align ~= "right" then
      fail(HATCH_ERROR, "messages." .. key .. ".align must be absent, center, or right", {})
    end
  end

  local particles = requireRecord(manifest.particles, "particles")
  assert(type(particles) == "table")
  SchemaCheck.checkKeys(particles, PARTICLE_VARIANTS, context, HATCH_ERROR, "particles")
  for _, variant in ipairs({ "egg", "manaphy" }) do
    local set = requireRecord(particles[variant], "particles." .. variant)
    assert(type(set) == "table")
    SchemaCheck.checkKeys(set, { emitters = true, textures = true }, context, HATCH_ERROR, "particles." .. variant)
    local emitters = requireArray(set.emitters, "particles." .. variant .. ".emitters")
    if #emitters == 0 then
      fail(HATCH_ERROR, "particles." .. variant .. " must name at least one emitter", {})
    end
    local textures = requireArray(set.textures, "particles." .. variant .. ".textures")
    if #textures == 0 then
      fail(HATCH_ERROR, "particles." .. variant .. " must carry at least one texture", {})
    end
    for index, texture in ipairs(textures) do
      local where = "particles." .. variant .. ".textures[" .. index .. "]"
      requireRecord(texture, where)
      assert(type(texture) == "table")
      SchemaCheck.checkNonEmptyString(texture.image, context, HATCH_ERROR, where .. ".image")
      requireInteger(texture.width, where .. ".width")
      requireInteger(texture.height, where .. ".height")
    end
  end
  return true
end

return PokemonCareAssetSchema
