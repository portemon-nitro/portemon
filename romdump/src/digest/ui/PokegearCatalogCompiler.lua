-- Decodes the Pokegear semantic catalog from source bytes: the phonebook
-- contact table and the sprite resource descriptor bindings. Table readers
-- stay private; the asset compiler feeds this module raw member bytes and
-- receives semantic records plus producer provenance. Structural failures
-- raise attributed errors; a missing dependency is never a plausible empty
-- catalog.

local BinaryReader = require("libs.codec.src.BinaryReader")
local Errors = require("libs.errors.src.Errors")
local Hashing = require("romdump.src.digest.Hashing")
local PokegearSources = require("romdump.src.config.PokegearSources")
local PokegearPhoneScriptSources = require("romdump.src.config.PokegearPhoneScriptSources")
local MapReference = require("romdump.src.catalog.hgss.maps")
local PokegearMapReference = require("romdump.src.catalog.hgss.pokegear_map")

local PokegearCatalogCompiler = {}

PokegearCatalogCompiler.ERROR = {
  PHONEBOOK_INVALID = "POKEGEAR_PHONEBOOK_INVALID",
  RESDAT_INVALID = "POKEGEAR_RESDAT_INVALID",
  DUPLICATE_CONTACT = "POKEGEAR_DUPLICATE_CONTACT",
  REMATCH_INVALID = "POKEGEAR_REMATCH_INVALID",
  SOURCE_UNAVAILABLE = "POKEGEAR_SOURCE_UNAVAILABLE",
}

local SENTINEL_U32 = 4294967294
local PHONE_SCRIPT_COUNT = 455

local function phoneClassReference(trainerClass)
  local source = PokegearSources.phoneClassLabels
  if trainerClass == source.motherClass then
    return { kind = "blank" }
  end
  if trainerClass >= source.professorClass then
    return {
      kind = "message",
      bank = source.specialBank,
      entry = trainerClass - source.professorClass + source.specialFirstEntry,
    }
  end
  return { kind = "message", bank = source.trainerBank, entry = trainerClass }
end

local function compilePhoneDefinitions()
  local definitions = PokegearPhoneScriptSources.definitions
  assert(type(definitions) == "table" and #definitions == PHONE_SCRIPT_COUNT, "native phone script table is complete")
  local out = {}
  for index, source in ipairs(definitions) do
    assert(type(source) == "table" and source.id == index, "native phone script IDs are contiguous")
    for _, gender in ipairs({ "male", "female" }) do
      local ref = source[gender]
      assert(type(ref) == "table" and type(ref.bank) == "number" and type(ref.entry) == "number")
      assert(
        ref.bank >= 641 and ref.bank <= 716 and ref.entry >= 0,
        "phone script message references a phone bank entry"
      )
    end
    assert(source.male.bank == source.female.bank, "gendered phone lines stay in one caller bank")
    assert(
      source.kind == "none"
        or source.kind == "flag"
        or source.kind == "rematch"
        or source.kind == "item"
        or source.kind == "word",
      "native phone script types use the source enum"
    )
    out[index] = {
      id = source.id,
      male = { bank = source.male.bank, entry = source.male.entry },
      female = { bank = source.female.bank, entry = source.female.entry },
      kind = source.kind,
      param0 = source.param0,
      param1 = source.param1,
    }
  end
  return out
end

-- Native rematch sets keyed by the base trainer a phonebook entry names, in
-- source entry order (src/trainer_rematch.c::sTrainerRematchSets). Every
-- referenced trainer must exist in the dump's trainer archive, so a mistyped
-- or stale source row fails the build instead of reaching a script.
---@param romFs table<string, unknown> RomFs-shaped source filesystem
---@return { rows: table<integer, integer[]>, trainerCount: integer }|nil
---@return Errors.Error|nil
function PokegearCatalogCompiler.compileRematchSets(romFs)
  local openNarc = romFs.openNarc
  if type(openNarc) ~= "function" then
    return nil, Errors.new(PokegearCatalogCompiler.ERROR.SOURCE_UNAVAILABLE, "rematch validation needs a RomFs", {})
  end
  local trainers, trainersErr = openNarc(romFs, "trainer_data")
  if trainers == nil then
    return nil,
      Errors.new(
        PokegearCatalogCompiler.ERROR.SOURCE_UNAVAILABLE,
        "the trainer archive is unavailable for rematch validation: "
          .. tostring(trainersErr and trainersErr.message or trainersErr),
        {}
      )
  end
  local trainerCount = trainers:memberCount()
  local rows = {}
  for index, row in ipairs(PokegearSources.trainerRematchSets) do
    local label = "trainer rematch row " .. index
    if type(row) ~= "table" or #row ~= 6 then
      return nil,
        Errors.new(PokegearCatalogCompiler.ERROR.REMATCH_INVALID, label .. " must carry six source entries", {
          row = index,
        })
    end
    local base = row[1]
    if type(base) ~= "number" or base % 1 ~= 0 or base < 1 then
      return nil,
        Errors.new(
          PokegearCatalogCompiler.ERROR.REMATCH_INVALID,
          label .. " must name its base trainer",
          { row = index }
        )
    end
    if rows[base] ~= nil then
      return nil,
        Errors.new(
          PokegearCatalogCompiler.ERROR.REMATCH_INVALID,
          label .. " repeats base trainer " .. base,
          { row = index, trainer = base }
        )
    end
    local entries = {}
    for position = 1, 6 do
      local trainer = row[position]
      local sentinel = trainer == 0 or trainer == 0xFFFF
      if
        type(trainer) ~= "number"
        or trainer % 1 ~= 0
        or trainer < 0
        or trainer > 0xFFFF
        or (not sentinel and trainer >= trainerCount)
      then
        return nil,
          Errors.new(
            PokegearCatalogCompiler.ERROR.REMATCH_INVALID,
            label .. " references missing trainer " .. tostring(trainer),
            { row = index, position = position, trainer = trainer }
          )
      end
      entries[position] = trainer
    end
    rows[base] = entries
  end
  if next(rows) == nil then
    return nil, Errors.new(PokegearCatalogCompiler.ERROR.REMATCH_INVALID, "the source rematch table is empty", {})
  end
  return { rows = rows, trainerCount = trainerCount }
end

local function copyOverlay(overlay, keys)
  local out = {}
  for _, key in ipairs(keys) do
    out[key] = overlay[key]
  end
  return out
end

-- The landmark-name message entry of a map header: its map section.
---@param mapId integer
---@return integer
local function sectionEntry(mapId)
  local header = assert(MapReference.byId[mapId], "the region map names a known map header: " .. tostring(mapId))
  return assert(header.mapSectionNativeId, "map headers carry their section identity")
end

local function compileRegionMap()
  local locations = {}
  for index, source in ipairs(PokegearMapReference.locations) do
    locations[index] = {
      mapId = source.mapId,
      mapSymbol = source.mapSymbol,
      x = source.x,
      y = source.y,
      width = source.width,
      height = source.height,
      objXOffset = source.objXOffset,
      objYOffset = source.objYOffset,
      flavorEntry = source.flavorEntry,
      previewBlock = source.previewBlock,
      sectionEntry = sectionEntry(source.mapId),
      overlay = copyOverlay(source.overlay, { "srcX", "srcY", "width", "height" }),
    }
  end
  local flypoints = {}
  for index, source in ipairs(PokegearMapReference.flypoints) do
    flypoints[index] = {
      nameMapId = source.nameMapId,
      nameSectionEntry = sectionEntry(source.nameMapId),
      warpMapId = source.warpMapId,
      flypoint = source.flypoint,
      x = source.x,
      y = source.y,
      width = source.width,
      height = source.height,
      overlay = copyOverlay(source.overlay, { "srcX", "srcY", "destX", "destY", "width", "height" }),
    }
  end
  return { locations = locations, flypoints = flypoints }
end

local function readU32Field(reader, offset, label)
  local ok, value = pcall(reader.u32le, reader, offset)
  if not ok then
    Errors.raise(
      PokegearCatalogCompiler.ERROR.PHONEBOOK_INVALID,
      "phonebook " .. label .. " exceeds its payload",
      { offset = offset }
    )
  end
  return value
end

---@param id integer native phonebook contact number
---@return table<string, table<integer, table<integer, integer>>>? detached header tables, nil without gated rows
local function copyGenericHeaders(id)
  local source = PokegearSources.phoneGenericHeaders[id]
  if type(source) ~= "table" then
    return nil
  end
  local out = {}
  for _, half in ipairs({ "outgoing", "incoming" }) do
    local rows = source[half]
    assert(type(rows) == "table" and #rows == 8, "generic header tables carry eight rows per direction")
    local copied = {}
    for index, row in ipairs(rows) do
      assert(type(row) == "table" and #row == 4, "generic header rows carry type, chance, script type, and script")
      copied[index] = { row[1], row[2], row[3], row[4] }
    end
    out[half] = copied
  end
  return out
end

---@param bytes string whole phonebook file bytes
---@return { count: integer, contacts: table[], contactOrder: string[] }|nil
---@return Errors.Error|nil
function PokegearCatalogCompiler.decodePhonebook(bytes)
  if type(bytes) ~= "string" or #bytes < 4 then
    return nil,
      Errors.new(PokegearCatalogCompiler.ERROR.PHONEBOOK_INVALID, "phonebook payload is shorter than its count", {
        size = type(bytes) == "string" and #bytes or nil,
      })
  end
  local reader = BinaryReader.new(bytes, "pokegear-phonebook")
  local count = readU32Field(reader, 0, "count")
  if 4 + count * PokegearSources.phonebook.recordBytes ~= #bytes then
    return nil,
      Errors.new(
        PokegearCatalogCompiler.ERROR.PHONEBOOK_INVALID,
        "phonebook count does not match its payload length",
        { count = count, size = #bytes }
      )
  end
  local contacts, contactOrder, seen = {}, {}, {}
  for index = 0, count - 1 do
    local base = 4 + index * PokegearSources.phonebook.recordBytes
    -- The record follows the native PhoneBookEntry struct exactly: id,
    -- entry type, an unused byte, trainer class, trainer id, map id,
    -- gift item, local phone-script selector, greeting set, rematch
    -- weekday, rematch time of day, random-call group, and four sort
    -- bytes. Earlier layouts misread every field from the trainer id
    -- onward by one halfword, which corrupted local-map checks,
    -- same-map suppression, gift items, rematch windows, sort weights,
    -- and the random-call pool.
    local id = reader:u8(base)
    local entryType = reader:u8(base + 1)
    local trainerClass = reader:u8(base + 3)
    local trainerId = reader:u16le(base + 4)
    local mapId = reader:u16le(base + 6)
    local gift = reader:u16le(base + 8)
    local phoneScriptIfLocal = reader:u16le(base + 10)
    local greetingMsgSet = reader:u8(base + 12)
    local rematchWeekday = reader:u8(base + 13)
    local rematchTimeOfDay = reader:u8(base + 14)
    local randomCallGroup = reader:u8(base + 15)
    local weights = {
      reader:u8(base + 16),
      reader:u8(base + 17),
      reader:u8(base + 18),
      reader:u8(base + 19),
    }
    -- Native contact identity is the record's own trainer-class,
    -- trainer-id, and contact triple; array position is retained only
    -- as the producer translation. A repeated triple is a genuine
    -- duplicate identity. The local phone-script selector rides beside
    -- its message bank: the record id is the phonebook number the
    -- source GetPhoneMessageGmm switches on for the bank, while the
    -- selector itself (PhoneBookEntry.phoneScriptIfLocal) resolves onto
    -- bank messages through the phone script table. An id outside the
    -- bank index is corrupt phonebook data, never an empty bank. Keys
    -- keep the historical trainer.map.contact shape over the class and
    -- trainer bytes so previously persisted contact references survive
    -- the rename.
    local key = string.format("hg.trainer.%d.map.%d.contact.%d", trainerClass, trainerId, id)
    local family = PokegearSources.phoneContactFamilies[id + 1]
    if type(family) ~= "string" or family == "" then
      return nil,
        Errors.new(
          PokegearCatalogCompiler.ERROR.PHONEBOOK_INVALID,
          "phonebook contact id names no conversation family",
          { id = id, sourceIndex = index }
        )
    end
    local messageBank = PokegearSources.phoneMessageBanks[id + 1]
    if type(messageBank) ~= "number" then
      return nil,
        Errors.new(
          PokegearCatalogCompiler.ERROR.PHONEBOOK_INVALID,
          "phonebook contact id names no message bank",
          { id = id, sourceIndex = index }
        )
    end
    if seen[key] then
      return nil,
        Errors.new(
          PokegearCatalogCompiler.ERROR.DUPLICATE_CONTACT,
          "duplicate contact identity " .. key,
          { key = key, sourceIndex = index }
        )
    end
    seen[key] = true
    contacts[#contacts + 1] = {
      key = key,
      sourceIndex = index,
      id = id,
      family = family,
      entryType = entryType,
      trainerClass = trainerClass,
      trainerId = trainerId,
      mapId = mapId,
      gift = gift,
      phoneScriptIfLocal = phoneScriptIfLocal,
      greetingMsgSet = greetingMsgSet,
      messageBank = messageBank,
      name = { bank = messageBank, entry = 0 },
      class = phoneClassReference(trainerClass),
      rematchWeekday = rematchWeekday,
      rematchTimeOfDay = rematchTimeOfDay,
      randomCallGroup = randomCallGroup,
      sortWeights = weights,
      sortWeight = weights[1],
      genericHeaders = copyGenericHeaders(id),
    }
    contactOrder[#contactOrder + 1] = key
  end
  return { count = count, contacts = contacts, contactOrder = contactOrder }
end

local function checkAligned(bytes, stride, label)
  if #bytes < stride or #bytes % stride ~= 0 then
    Errors.raise(
      PokegearCatalogCompiler.ERROR.RESDAT_INVALID,
      label .. " has an unaligned payload",
      { size = #bytes, stride = stride }
    )
  end
end

---@param bytes string resource-list descriptor bytes
---@param label string diagnostic label
---@return { resourceType: integer, records: table[] }|nil
---@return Errors.Error|nil
function PokegearCatalogCompiler.validateResdatList(bytes, label)
  if type(bytes) ~= "string" then
    return nil,
      Errors.new(PokegearCatalogCompiler.ERROR.RESDAT_INVALID, label .. " carries no bytes", { label = label })
  end
  local ok, parsed = pcall(function()
    checkAligned(bytes, 4, label)
    local reader = BinaryReader.new(bytes, label)
    if #bytes < 4 + PokegearSources.resdatListWords * 4 then
      Errors.raise(
        PokegearCatalogCompiler.ERROR.RESDAT_INVALID,
        label .. " is shorter than one record plus its sentinel",
        { size = #bytes }
      )
    end
    if (#bytes - 4) % (PokegearSources.resdatListWords * 4) ~= 0 then
      Errors.raise(
        PokegearCatalogCompiler.ERROR.RESDAT_INVALID,
        label .. " records do not fill whole six-word rows",
        { size = #bytes }
      )
    end
    local resourceType = reader:u32le(0)
    local records = {}
    local rowCount = (#bytes - 4) / (PokegearSources.resdatListWords * 4)
    for row = 1, rowCount - 1 do
      local record = {}
      for word = 1, PokegearSources.resdatListWords do
        record[word] = reader:u32le(4 + (row - 1) * PokegearSources.resdatListWords * 4 + (word - 1) * 4)
      end
      records[#records + 1] = {
        narcId = record[1],
        memberId = record[2],
        compressed = record[3],
        resourceId = record[4],
        extra0 = record[5],
        extra1 = record[6],
      }
    end
    local sentinelBase = #bytes - PokegearSources.resdatListWords * 4
    for word = 1, PokegearSources.resdatListWords do
      local value = reader:u32le(sentinelBase + (word - 1) * 4)
      if value ~= SENTINEL_U32 then
        Errors.raise(
          PokegearCatalogCompiler.ERROR.RESDAT_INVALID,
          label .. " misses its six-word sentinel termination",
          { word = word, value = value }
        )
      end
    end
    return { resourceType = resourceType, records = records }
  end)
  if ok then
    return parsed
  end
  if Errors.is(parsed) then
    return nil, parsed --[[@as Errors.Error]]
  end
  error(parsed, 0)
end

---@param bytes string header-set descriptor bytes
---@param label string diagnostic label
---@return table[]|nil header records
---@return Errors.Error|nil
function PokegearCatalogCompiler.validateResdatHeaders(bytes, label)
  if type(bytes) ~= "string" then
    return nil,
      Errors.new(PokegearCatalogCompiler.ERROR.RESDAT_INVALID, label .. " carries no bytes", { label = label })
  end
  local ok, parsed = pcall(function()
    checkAligned(bytes, 4, label)
    if #bytes < PokegearSources.resdatHeaderWords * 8 then
      Errors.raise(
        PokegearCatalogCompiler.ERROR.RESDAT_INVALID,
        label .. " is shorter than one header plus its sentinel",
        { size = #bytes }
      )
    end
    if #bytes % (PokegearSources.resdatHeaderWords * 4) ~= 0 then
      Errors.raise(
        PokegearCatalogCompiler.ERROR.RESDAT_INVALID,
        label .. " headers do not fill whole eight-word rows",
        { size = #bytes }
      )
    end
    local reader = BinaryReader.new(bytes, label)
    local rowCount = #bytes / (PokegearSources.resdatHeaderWords * 4)
    local records = {}
    for row = 1, rowCount - 1 do
      local base = (row - 1) * PokegearSources.resdatHeaderWords * 4
      local record = {
        char = reader:u32le(base),
        palette = reader:u32le(base + 4),
        cell = reader:u32le(base + 8),
        animation = reader:u32le(base + 12),
        multicell = reader:u32le(base + 16),
        multianimation = reader:u32le(base + 20),
        transfer = reader:u32le(base + 24),
        priority = reader:u32le(base + 28),
      }
      if not PokegearSources.supportedTransferModes[record.transfer] then
        Errors.raise(
          PokegearCatalogCompiler.ERROR.RESDAT_INVALID,
          label .. " carries an unsupported transfer mode",
          { transfer = record.transfer, row = row }
        )
      end
      records[#records + 1] = record
    end
    local sentinelBase = #bytes - PokegearSources.resdatHeaderWords * 4
    for word = 1, PokegearSources.resdatHeaderWords do
      local value = reader:u32le(sentinelBase + (word - 1) * 4)
      if value ~= SENTINEL_U32 then
        Errors.raise(
          PokegearCatalogCompiler.ERROR.RESDAT_INVALID,
          label .. " misses its eight-word sentinel termination",
          { word = word, value = value }
        )
      end
    end
    return records
  end)
  if ok then
    return parsed
  end
  if Errors.is(parsed) then
    return nil, parsed --[[@as Errors.Error]]
  end
  error(parsed, 0)
end

---@param romFs table<string, unknown> RomFs-shaped source filesystem
---@param versionId string
---@return table<string, unknown>|nil catalog bundle
---@return Errors.Error|nil
function PokegearCatalogCompiler.compile(romFs, versionId)
  assert(romFs and romFs.readSourcePath, "catalog compilation requires a RomFs-shaped object")
  assert(type(versionId) == "string" and versionId ~= "", "catalog compilation requires a version")
  local phonebookBytes, phonebookErr = romFs:readSourcePath(PokegearSources.phonebook.path)
  if phonebookBytes == nil then
    return nil,
      Errors.new(
        PokegearCatalogCompiler.ERROR.SOURCE_UNAVAILABLE,
        "the phonebook source is unavailable: " .. tostring(phonebookErr and phonebookErr.message or phonebookErr),
        { path = PokegearSources.phonebook.path }
      )
  end
  ---@cast phonebookBytes string
  local decoded, decodeErr = PokegearCatalogCompiler.decodePhonebook(phonebookBytes)
  if decoded == nil then
    return nil, decodeErr
  end
  local Narc = require("libs.nds.src.nitro.Narc")
  local spriteBytes, spriteErr = romFs:readSourcePath(PokegearSources.spriteArchive.path)
  if spriteBytes == nil then
    return nil,
      Errors.new(
        PokegearCatalogCompiler.ERROR.SOURCE_UNAVAILABLE,
        "the sprite descriptor source is unavailable: " .. tostring(spriteErr and spriteErr.message or spriteErr),
        { path = PokegearSources.spriteArchive.path }
      )
  end
  local archive, narcErr = Narc.open(assert(spriteBytes), PokegearSources.spriteArchive.path)
  if archive == nil then
    return nil, narcErr
  end
  local bindings = {}
  for setName, binding in pairs(PokegearSources.spriteBindings) do
    local lists = {}
    for _, role in ipairs({ "char", "palette", "cell", "anim" }) do
      local memberId = binding[role]
      local bytes, memberErr = archive:readMember(memberId)
      if bytes == nil then
        return nil,
          Errors.new(
            PokegearCatalogCompiler.ERROR.SOURCE_UNAVAILABLE,
            "sprite descriptor member " .. memberId .. " is unavailable: " .. tostring(memberErr),
            { member = memberId }
          )
      end
      local parsed, parseErr =
        PokegearCatalogCompiler.validateResdatList(bytes, "pokegear-sprite-" .. setName .. "-" .. role)
      if parsed == nil then
        return nil, parseErr
      end
      lists[role] = parsed
    end
    local headerBytes, headerErr = archive:readMember(binding.header)
    if headerBytes == nil then
      return nil,
        Errors.new(
          PokegearCatalogCompiler.ERROR.SOURCE_UNAVAILABLE,
          "sprite header member " .. binding.header .. " is unavailable: " .. tostring(headerErr),
          { member = binding.header }
        )
    end
    local headers, headersErr =
      PokegearCatalogCompiler.validateResdatHeaders(headerBytes, "pokegear-sprite-" .. setName .. "-header")
    if headers == nil then
      return nil, headersErr
    end
    bindings[setName] = { lists = lists, headers = headers }
  end
  local rematchSets, rematchErr = PokegearCatalogCompiler.compileRematchSets(romFs)
  if rematchSets == nil then
    return nil, rematchErr
  end
  local catalog = {
    contacts = decoded.contacts,
    contactOrder = decoded.contactOrder,
    callDefinitions = compilePhoneDefinitions(),
    callTriggers = PokegearSources.phoneTriggerRecords(versionId),
    rematches = rematchSets.rows,
    gifts = {},
    momPurchases = PokegearSources.momPurchaseRecords(versionId),
    locations = PokegearSources.mapLocationRecords(versionId),
    flypoints = PokegearSources.mapFlypointRecords(versionId),
    regionMap = compileRegionMap(),
    reception = PokegearSources.radioReceptionRecords(versionId),
    shows = PokegearSources.broadcastShowRecords(versionId),
    radioEffects = {},
    landmarkLabels = {
      bank = PokegearSources.phoneClassLabels.landmarkBank,
      fallbackBank = PokegearSources.phoneClassLabels.landmarkFallbackBank,
      fallbackEntry = PokegearSources.phoneClassLabels.landmarkFallbackEntry,
    },
  }
  return {
    catalog = catalog,
    text = {},
    bindings = bindings,
    phonebook = {
      sha1 = Hashing.sha1hex(phonebookBytes),
      size = #phonebookBytes,
      sourceHash = Hashing.hashLua({
        catalog = catalog,
        classLabels = PokegearSources.phoneClassLabels,
        rematchTrainerCount = rematchSets.trainerCount,
      }),
    },
  }
end

return PokegearCatalogCompiler
