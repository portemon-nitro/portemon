-- Authoritative validation for the generated Day Care care family: the source
-- PMS egg-species table, the personal egg-move list, the source incense pairs,
-- and the Frontier move-tutor inventory with its per-species compatibility
-- lists, plus the hatch application's own generated presentation (its
-- background, egg and reveal-bar animation frames, the compiled particle
-- emitters with their staged textures, the source shake tables it draws with,
-- and the message bank lines the scene prints). Both payloads carry normalized
-- semantic meaning only; native ids and archive offsets stay producer-side.
-- Runtime trusts published artifacts and must not duplicate this validation.
-- Unknown fields, dangling shells, and duplicated entries fail loudly.

local Contract = require("libs.assets.src.DerivedAssetContract")
local ModelAsset = require("libs.assets.src.model.ModelAsset")
local SchemaCheck = require("libs.assets.src.SchemaCheck")
local Validate = require("libs.assets.src.Validate")

---@class PokemonCareAssetSchema
local PokemonCareAssetSchema = {}

PokemonCareAssetSchema.CATALOG_SCHEMA = Contract.pokemonCare.catalogSchema
PokemonCareAssetSchema.HATCH_SCHEMA = Contract.pokemonCare.hatchSchema
PokemonCareAssetSchema.TRADE_SCHEMA = Contract.pokemonCare.tradeSchema
PokemonCareAssetSchema.REMINDER_SCHEMA = Contract.pokemonCare.reminderSchema

local CATALOG_ERROR = "POKEMON_CARE_CATALOG_INVALID"
local HATCH_ERROR = "POKEMON_CARE_HATCH_INVALID"
local TRADE_ERROR = "POKEMON_CARE_TRADE_INVALID"
local fail = SchemaCheck.fail

local CATALOG_FIELDS = {
  schema = true,
  eggSpecies = true,
  eggMoves = true,
  incense = true,
  trades = true,
  tutors = true,
}
local TUTORS_FIELDS = { moves = true, learnsets = true }
local TUTOR_MOVE_FIELDS = { move = true, cost = true, npc = true }
-- MOVE_TUTOR_NPC_* selectors as the semantic names the runtime asks for.
local TUTOR_NPCS = { top_left = true, top_right = true, bottom_right = true, headbutt = true }
local INCENSE_FIELDS = { baby = true, item = true, parent = true }
local TRADE_FIELDS = {
  offeredSpecies = true,
  requestedSpecies = true,
  personality = true,
  otId = true,
  ivs = true,
  contest = true,
  heldItem = true,
  otGender = true,
  language = true,
  nickname = true,
  otName = true,
  unusedFlag = true,
}
local TRADE_IV_FIELDS = {
  hp = true,
  attack = true,
  defense = true,
  speed = true,
  specialAttack = true,
  specialDefense = true,
}
local TRADE_CONTEST_FIELDS = { cool = true, beauty = true, cute = true, smart = true, tough = true }

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
---@param low integer
---@param high integer
local function requireIntegerField(value, what, low, high)
  if type(value) ~= "number" or value % 1 ~= 0 or value < low or value > high then
    fail(CATALOG_ERROR, what .. " must be an integer in " .. low .. ".." .. high, {})
  end
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

  -- The source NPC trade records in their own order: each row is one complete
  -- exchanged identity, so the runtime never consults a second table.
  local trades = requireArray(catalog.trades, "trades")
  if #trades == 0 then
    fail(CATALOG_ERROR, "trades must carry the source records", {})
  end
  for index, row in ipairs(trades) do
    local what = "trades[" .. index .. "]"
    requireRecord(row, what)
    assert(type(row) == "table")
    SchemaCheck.checkKeys(row, TRADE_FIELDS, context, CATALOG_ERROR, what)
    for _, field in ipairs({ "offeredSpecies", "requestedSpecies", "heldItem", "language", "nickname", "otName" }) do
      SchemaCheck.checkNonEmptyString(row[field], context, CATALOG_ERROR, what .. "." .. field)
    end
    requireIntegerField(row.personality, what .. ".personality", 0, 4294967295)
    requireIntegerField(row.otId, what .. ".otId", 0, 4294967295)
    requireIntegerField(row.otGender, what .. ".otGender", 0, 1)
    requireIntegerField(row.unusedFlag, what .. ".unusedFlag", 0, 65535)
    local ivs = requireRecord(row.ivs, what .. ".ivs")
    assert(type(ivs) == "table")
    SchemaCheck.checkKeys(ivs, TRADE_IV_FIELDS, context, CATALOG_ERROR, what .. ".ivs")
    for _, field in ipairs({ "hp", "attack", "defense", "speed", "specialAttack", "specialDefense" }) do
      requireIntegerField(ivs[field], what .. ".ivs." .. field, 0, 31)
    end
    local contest = requireRecord(row.contest, what .. ".contest")
    assert(type(contest) == "table")
    SchemaCheck.checkKeys(contest, TRADE_CONTEST_FIELDS, context, CATALOG_ERROR, what .. ".contest")
    for _, field in ipairs({ "cool", "beauty", "cute", "smart", "tough" }) do
      requireIntegerField(contest[field], what .. ".contest." .. field, 0, 255)
    end
  end
  -- The Frontier move tutor inventory in source order, each species' own
  -- compatible-move list per form, and nothing else: a page, a price or an
  -- eligibility answer never comes from a second table.
  local tutors = requireRecord(catalog.tutors, "tutors")
  assert(type(tutors) == "table")
  SchemaCheck.checkKeys(tutors, TUTORS_FIELDS, context, CATALOG_ERROR, "tutors")
  local tutorMoves = requireArray(tutors.moves, "tutors.moves")
  if #tutorMoves == 0 then
    fail(CATALOG_ERROR, "tutors.moves must carry the source inventory", {})
  end
  local seenMoves = {}
  for index, row in ipairs(tutorMoves) do
    local what = "tutors.moves[" .. index .. "]"
    requireRecord(row, what)
    assert(type(row) == "table")
    SchemaCheck.checkKeys(row, TUTOR_MOVE_FIELDS, context, CATALOG_ERROR, what)
    SchemaCheck.checkNonEmptyString(row.move, context, CATALOG_ERROR, what .. ".move")
    requireIntegerField(row.cost, what .. ".cost", 0, 255)
    if type(row.npc) ~= "string" or TUTOR_NPCS[row.npc] ~= true then
      fail(CATALOG_ERROR, what .. ".npc must name a source tutor", {})
    end
    if seenMoves[row.move] then
      fail(CATALOG_ERROR, what .. " repeats the move " .. row.move, {})
    end
    seenMoves[row.move] = true
  end
  local learnsets = requireRecord(tutors.learnsets, "tutors.learnsets")
  assert(type(learnsets) == "table")
  for speciesKey, forms in pairs(learnsets) do
    SchemaCheck.checkNonEmptyString(speciesKey, context, CATALOG_ERROR, "tutors.learnsets key")
    requireArray(forms, "tutors.learnsets." .. speciesKey)
    if #forms == 0 then
      fail(CATALOG_ERROR, "tutors.learnsets." .. speciesKey .. " must carry the species' own row", {})
    end
    for formIndex, moves in ipairs(forms) do
      requireArray(moves, "tutors.learnsets." .. speciesKey .. "[" .. formIndex .. "]")
      local seen = {}
      for _, moveKey in ipairs(moves) do
        if seenMoves[moveKey] ~= true then
          fail(
            CATALOG_ERROR,
            "tutors.learnsets." .. speciesKey .. " names a move outside the inventory",
            { move = moveKey }
          )
        end
        if seen[moveKey] then
          fail(CATALOG_ERROR, "tutors.learnsets." .. speciesKey .. " repeats the move " .. moveKey, {})
        end
        seen[moveKey] = true
      end
    end
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

-- The app71 trade presentation payload: the source message-window geometry,
-- every played scene's own source layers in draw order (each layer one composed
-- surface, or one surface per time-of-day colour bank), the two sprite sheets
-- the scenes animate with their per-frame timings, and the four bank-179 lines
-- the exchange prints. Images name staged paths; nothing here carries source
-- member indices or raw ROM bytes.
local TRADE_FIELDS = {
  schema = true,
  window = true,
  scenes = true,
  sprites = true,
  balloon = true,
  pictures = true,
  messages = true,
}
local TRADE_PHASES = {
  send = true,
  depart = true,
  recede = true,
  exchange = true,
  approach = true,
  arrive = true,
  receive = true,
}
local TRADE_SCENE_FIELDS = { layers = true }
local TRADE_LAYER_FIELDS = {
  image = true,
  width = true,
  height = true,
  affine = true,
  variants = true,
  indices = true,
}
local TRADE_VARIANT_FIELDS = { day = true, evening = true, night = true }
local TRADE_MESSAGE_KEYS = { "send", "farewell", "received", "takeCare" }
local TRADE_SPRITE_FIELDS = { effect = true }
local TRADE_SPRITE_SEQUENCE_FIELDS = { sequence = true, frames = true }
local TRADE_SPRITE_FRAME_FIELDS = { image = true, width = true, height = true, durationTicks = true, blank = true }

---@param value unknown
---@param what string
---@return table
local function requireTradeSpriteSequence(value, what)
  local record = requireRecord(value, what)
  assert(type(record) == "table")
  SchemaCheck.checkKeys(record, TRADE_SPRITE_SEQUENCE_FIELDS, {}, TRADE_ERROR, what)
  requireInteger(record.sequence, what .. ".sequence")
  local frames = requireArray(record.frames, what .. ".frames")
  if #frames == 0 then
    fail(TRADE_ERROR, what .. " must realize at least one frame", {})
  end
  for index, frame in ipairs(frames) do
    local frameWhere = what .. ".frames[" .. index .. "]"
    requireRecord(frame, frameWhere)
    assert(type(frame) == "table")
    SchemaCheck.checkKeys(frame, TRADE_SPRITE_FRAME_FIELDS, {}, TRADE_ERROR, frameWhere)
    if frame.blank ~= nil then
      -- A blank source frame shows nothing; it carries neither image nor size.
      if frame.blank ~= true then
        fail(TRADE_ERROR, frameWhere .. ".blank must be true when present", {})
      end
      if frame.image ~= nil or frame.width ~= nil or frame.height ~= nil then
        fail(TRADE_ERROR, frameWhere .. " carries either a blank mark or staged pixels", {})
      end
    else
      SchemaCheck.checkNonEmptyString(frame.image, {}, TRADE_ERROR, frameWhere .. ".image")
      requireInteger(frame.width, frameWhere .. ".width")
      requireInteger(frame.height, frameWhere .. ".height")
    end
    requireInteger(frame.durationTicks, frameWhere .. ".durationTicks")
  end
  return record
end

-- The trade scene's Poke Ball model is a compiled static model descriptor, so
-- the shared model-asset validator owns its whole shape.
---@param value unknown
local function requireTradeBalloon(value)
  local record = requireRecord(value, "balloon")
  assert(type(record) == "table")
  SchemaCheck.checkKeys(record, { model = true }, {}, TRADE_ERROR, "balloon")
  local ok, failure = pcall(ModelAsset.validate, record.model)
  if not ok then
    fail(TRADE_ERROR, "balloon.model is not a valid model descriptor: " .. tostring(failure), {})
  end
end

-- The mon pictures the send, receive and exchange scenes draw: the source
-- bottom anchor, the exchange layer tile columns, and the front picture height
-- of every portrait selector the mon family publishes.
---@param value unknown
local function requireTradePictures(value)
  local record = requireRecord(value, "pictures")
  assert(type(record) == "table")
  SchemaCheck.checkKeys(record, { baseY = true, sentTileX = true, receivedTileX = true, heights = true }, {}, TRADE_ERROR, "pictures")
  requireInteger(record.baseY, "pictures.baseY")
  requireInteger(record.sentTileX, "pictures.sentTileX")
  requireInteger(record.receivedTileX, "pictures.receivedTileX")
  local heights = requireRecord(record.heights, "pictures.heights")
  assert(type(heights) == "table")
  local count = 0
  for selector, height in pairs(heights) do
    SchemaCheck.checkNonEmptyString(selector, {}, TRADE_ERROR, "pictures.heights selector")
    if type(height) ~= "number" or height % 1 ~= 0 or height < 0 or height > 255 then
      fail(TRADE_ERROR, "pictures.heights." .. tostring(selector) .. " is a source byte", {})
    end
    count = count + 1
  end
  if count == 0 then
    fail(TRADE_ERROR, "the trade pictures carry their front picture heights", {})
  end
end

---@param value unknown
---@param what string
---@return table
local function requireTradeSpriteSheet(value, what)
  local record = requireRecord(value, what)
  assert(type(record) == "table")
  SchemaCheck.checkKeys(record, { sequences = true }, {}, TRADE_ERROR, what)
  local sequences = requireArray(record.sequences, what .. ".sequences")
  if #sequences == 0 then
    fail(TRADE_ERROR, what .. " must realize at least one animation sequence", {})
  end
  local seen = {}
  for index, sequence in ipairs(sequences) do
    local sequenceWhere = what .. ".sequences[" .. index .. "]"
    local typed = requireTradeSpriteSequence(sequence, sequenceWhere)
    local identity = assert(typed.sequence) --[[@as integer]]
    if seen[identity] then
      fail(TRADE_ERROR, sequenceWhere .. " repeats a source animation sequence", {})
    end
    seen[identity] = true
  end
  return record
end

---@param value unknown
---@param what string
---@return table
local function requireTradeImage(value, what)
  local record = requireRecord(value, what)
  assert(type(record) == "table")
  SchemaCheck.checkKeys(record, { image = true, width = true, height = true }, {}, TRADE_ERROR, what)
  SchemaCheck.checkNonEmptyString(record.image, {}, TRADE_ERROR, what .. ".image")
  requireInteger(record.width, what .. ".width")
  requireInteger(record.height, what .. ".height")
  return record
end

---@param manifest unknown
---@return boolean
-- The move reminder / singleton tutor presentation: the source's two screens
-- and its button tile sheet, the source window rectangles in pixels, and the
-- compiled message lines the application prints.
local REMINDER_FIELDS = {
  schema = true,
  windows = true,
  messages = true,
  main = true,
  sub = true,
  buttons = true,
}
local REMINDER_WINDOW_KEYS = {
  categoryLabel = true,
  powerLabel = true,
  accuracyLabel = true,
  power = true,
  accuracy = true,
  description = true,
  message = true,
  title = true,
  teach = true,
  returnButton = true,
  list = true,
  knownTitle = true,
  monName = true,
  promptYes = true,
  promptNo = true,
}
local REMINDER_WINDOW_FIELDS = { x = true, y = true, width = true, height = true, framed = true }

---@param value unknown
---@param what string
local function requireReminderSurface(value, what)
  local surface = requireRecord(value, what)
  assert(type(surface) == "table")
  SchemaCheck.checkKeys(surface, { image = true, width = true, height = true }, {}, HATCH_ERROR, what)
  SchemaCheck.checkNonEmptyString(surface.image, {}, HATCH_ERROR, what .. ".image")
  requireInteger(surface.width, what .. ".width")
  requireInteger(surface.height, what .. ".height")
end

---@param manifest table<string, unknown>
function PokemonCareAssetSchema.assertReminderManifest(manifest)
  requireRecord(manifest, "reminder manifest")
  SchemaCheck.checkKeys(manifest, REMINDER_FIELDS, {}, HATCH_ERROR, "reminder manifest")
  if manifest.schema ~= PokemonCareAssetSchema.REMINDER_SCHEMA then
    fail(HATCH_ERROR, "reminder manifest schema is not current", {})
  end
  requireReminderSurface(manifest.main, "reminder main screen")
  requireReminderSurface(manifest.sub, "reminder sub screen")
  requireReminderSurface(manifest.buttons, "reminder button tiles")
  local windows = requireRecord(manifest.windows, "reminder windows")
  assert(type(windows) == "table")
  SchemaCheck.checkKeys(windows, REMINDER_WINDOW_KEYS, {}, HATCH_ERROR, "reminder windows")
  for key in pairs(REMINDER_WINDOW_KEYS) do
    local box = requireRecord(windows[key], "reminder window " .. key)
    assert(type(box) == "table")
    SchemaCheck.checkKeys(box, REMINDER_WINDOW_FIELDS, {}, HATCH_ERROR, "reminder window " .. key)
    for _, field in ipairs({ "x", "y", "width", "height" }) do
      requireInteger(box[field], "reminder window " .. key .. "." .. field)
    end
    if box.width <= 0 or box.height <= 0 then
      fail(HATCH_ERROR, "reminder window " .. key .. " must cover at least one pixel", {})
    end
    if box.framed ~= nil and type(box.framed) ~= "boolean" then
      fail(HATCH_ERROR, "reminder window " .. key .. ".framed must be a boolean", {})
    end
  end
  local messages = requireArray(manifest.messages, "reminder messages")
  if #messages == 0 then
    fail(HATCH_ERROR, "the reminder presentation carries its source lines", {})
  end
  local seen = {}
  for index, line in ipairs(messages) do
    local where = "reminder messages[" .. index .. "]"
    requireRecord(line, where)
    assert(type(line) == "table")
    SchemaCheck.checkKeys(line, { id = true, text = true, align = true }, {}, HATCH_ERROR, where)
    requireInteger(line.id, where .. ".id")
    SchemaCheck.checkNonEmptyString(line.text, {}, HATCH_ERROR, where .. ".text")
    if line.align ~= nil and line.align ~= "center" and line.align ~= "right" then
      fail(HATCH_ERROR, where .. ".align must be absent, center, or right", {})
    end
    if seen[line.id] then
      fail(HATCH_ERROR, "the reminder presentation repeats source line " .. tostring(line.id), {})
    end
    seen[line.id] = true
  end
end

function PokemonCareAssetSchema.isValidReminderManifest(manifest)
  return pcall(PokemonCareAssetSchema.assertReminderManifest, manifest)
end

function PokemonCareAssetSchema.isValidTradeManifest(manifest)
  return pcall(PokemonCareAssetSchema.assertTradeManifest, manifest)
end

function PokemonCareAssetSchema.assertTradeManifest(manifest)
  local context = {}
  requireRecord(manifest, "trade manifest")
  SchemaCheck.checkKeys(manifest, TRADE_FIELDS, context, TRADE_ERROR, "trade manifest")
  if manifest.schema ~= PokemonCareAssetSchema.TRADE_SCHEMA then
    fail(TRADE_ERROR, "trade manifest schema is not current", {})
  end

  local window = requireRecord(manifest.window, "window")
  assert(type(window) == "table")
  SchemaCheck.checkKeys(window, WINDOW_FIELDS, context, TRADE_ERROR, "window")
  for _, field in ipairs({ "x", "y", "width", "height" }) do
    requireInteger(window[field], "window." .. field)
  end
  if window.width == 0 or window.height == 0 then
    fail(TRADE_ERROR, "the trade message window must cover at least one pixel", {})
  end

  local scenes = requireRecord(manifest.scenes, "scenes")
  assert(type(scenes) == "table")
  SchemaCheck.checkKeys(scenes, TRADE_PHASES, context, TRADE_ERROR, "scenes")
  for phase in pairs(TRADE_PHASES) do
    local where = "scenes." .. phase
    local scene = requireRecord(scenes[phase], where)
    assert(type(scene) == "table")
    SchemaCheck.checkKeys(scene, TRADE_SCENE_FIELDS, context, TRADE_ERROR, where)
    local layers = requireArray(scene.layers, where .. ".layers")
    if #layers == 0 then
      fail(TRADE_ERROR, where .. " must draw at least one source layer", {})
    end
    for index, layer in ipairs(layers) do
      local layerWhere = where .. ".layers[" .. index .. "]"
      requireRecord(layer, layerWhere)
      assert(type(layer) == "table")
      SchemaCheck.checkKeys(layer, TRADE_LAYER_FIELDS, context, TRADE_ERROR, layerWhere)
      if layer.affine ~= nil and type(layer.affine) ~= "boolean" then
        fail(TRADE_ERROR, layerWhere .. ".affine must be a boolean", {})
      end
      if layer.affine == true then
        -- The source's link pulses recolor this layer's own palette slots, so
        -- an affine layer publishes the index plane those slots resolve to.
        SchemaCheck.checkNonEmptyString(layer.indices, {}, TRADE_ERROR, layerWhere .. ".indices")
      elseif layer.indices ~= nil then
        fail(TRADE_ERROR, layerWhere .. " carries an index plane only for affine layers", {})
      end
      if layer.variants ~= nil then
        if layer.image ~= nil or layer.width ~= nil or layer.height ~= nil then
          fail(TRADE_ERROR, layerWhere .. " carries either one surface or its time-of-day banks", {})
        end
        local variants = requireRecord(layer.variants, layerWhere .. ".variants")
        assert(type(variants) == "table")
        SchemaCheck.checkKeys(variants, TRADE_VARIANT_FIELDS, context, TRADE_ERROR, layerWhere .. ".variants")
        for key in pairs(TRADE_VARIANT_FIELDS) do
          requireTradeImage(variants[key], layerWhere .. ".variants." .. key)
        end
      else
        requireTradeImage(layer, layerWhere)
      end
    end
  end

  local sprites = requireRecord(manifest.sprites, "sprites")
  assert(type(sprites) == "table")
  SchemaCheck.checkKeys(sprites, TRADE_SPRITE_FIELDS, context, TRADE_ERROR, "sprites")
  for sheet in pairs(TRADE_SPRITE_FIELDS) do
    requireTradeSpriteSheet(sprites[sheet], "sprites." .. sheet)
  end

  requireTradeBalloon(manifest.balloon)
  requireTradePictures(manifest.pictures)

  local messages = requireRecord(manifest.messages, "messages")
  assert(type(messages) == "table")
  local allowed = {}
  for _, key in ipairs(TRADE_MESSAGE_KEYS) do
    allowed[key] = true
  end
  SchemaCheck.checkKeys(messages, allowed, context, TRADE_ERROR, "messages")
  for _, key in ipairs(TRADE_MESSAGE_KEYS) do
    local line = requireRecord(messages[key], "messages." .. key)
    assert(type(line) == "table")
    SchemaCheck.checkKeys(line, MESSAGE_FIELDS, context, TRADE_ERROR, "messages." .. key)
    requireInteger(line.id, "messages." .. key .. ".id")
    SchemaCheck.checkNonEmptyString(line.text, context, TRADE_ERROR, "messages." .. key .. ".text")
    if line.align ~= nil and line.align ~= "center" and line.align ~= "right" then
      fail(TRADE_ERROR, "messages." .. key .. ".align must be absent, center, or right", {})
    end
  end
  return true
end

return PokemonCareAssetSchema