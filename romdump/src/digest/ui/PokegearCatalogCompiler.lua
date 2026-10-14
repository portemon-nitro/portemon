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
local MapReference = require("romdump.src.reference.hgss.maps")
local PokegearMapReference = require("romdump.src.reference.hgss.pokegear_map")

local PokegearCatalogCompiler = {}

PokegearCatalogCompiler.ERROR = {
  PHONEBOOK_INVALID = "POKEGEAR_PHONEBOOK_INVALID",
  RESDAT_INVALID = "POKEGEAR_RESDAT_INVALID",
  DUPLICATE_CONTACT = "POKEGEAR_DUPLICATE_CONTACT",
  SOURCE_UNAVAILABLE = "POKEGEAR_SOURCE_UNAVAILABLE",
}

local SENTINEL_U32 = 4294967294
local PHONE_SCRIPT_COUNT = 455

local function compileRematchSets(romFs)
  local sources = PokegearSources.rematchTrainerSets
  assert(type(sources) == "table" and #sources == 63, "native rematch source has 63 groups")
  local trainerData, trainerErr = romFs:openNarc("trainer_data")
  if trainerData == nil then
    error(trainerErr, 0)
  end
  local TrainerCatalogCompiler = require("romdump.src.digest.battle.TrainerCatalogCompiler")
  local compiled = {}
  for index, source in ipairs(sources) do
    assert(source.group == index - 1, "native rematch groups preserve their source index")
    assert(type(source.trainers) == "table" and #source.trainers == 6, "native rematch groups have six source columns")
    local baseTrainerId = source.trainers[1]
    assert(type(baseTrainerId) == "number" and baseTrainerId > 0, "native rematch group has a base trainer")
    assert(compiled[baseTrainerId] == nil, "native rematch base trainers are unique")
    local trainers = {}
    local sentinel = false
    for column, trainerId in ipairs(source.trainers) do
      assert(type(trainerId) == "number" and trainerId % 1 == 0 and trainerId >= 0 and trainerId <= 0xFFFF)
      if trainerId == 0 then
        sentinel = true
      else
        assert(not sentinel, "native rematch entries end at the first sentinel")
        local bytes, readErr = trainerData:readMember(trainerId)
        if bytes == nil then
          error(readErr, 0)
        end
        local header, headerErr = TrainerCatalogCompiler.decodeHeader(trainerId --[[@as integer]], bytes)
        if header == nil then
          error(headerErr, 0)
        end
        assert(header.memberCount > 0, "native rematch identities have compiled trainer parties")
      end
      trainers[column] = trainerId
    end
    compiled[baseTrainerId] = { group = source.group, trainers = trainers }
  end
  return compiled
end

function PokegearCatalogCompiler.compileFriendMapPhrases()
  local sources = PokegearSources.friendMapPhraseSources
  assert(#sources == 73, "Friend source map phrases have 73 rows")
  local mapIdsBySymbol = {}
  for mapId, header in pairs(MapReference.byId) do
    assert(mapIdsBySymbol[header.symbol] == nil, "native map symbols are unique")
    mapIdsBySymbol[header.symbol] = mapId
  end
  local rows = {}
  for index, source in ipairs(sources) do
    local symbol, unlockGroup = source[1], source[2]
    local mapId = assert(mapIdsBySymbol[symbol], "Friend phrase map resolves: " .. symbol)
    assert(type(unlockGroup) == "number" and unlockGroup % 1 == 0 and unlockGroup >= 0 and unlockGroup <= 3)
    rows[index] = { mapId = mapId, sourceIndex = index - 1, unlockGroup = unlockGroup }
  end
  return rows
end

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

local function compileCallPermissions()
  assert(
    type(MapReference.count) == "number" and MapReference.count % 1 == 0 and MapReference.count > 0,
    "the native map reference has a finite map count"
  )
  local permissions = {}
  for mapId = 0, MapReference.count - 1 do
    local header = MapReference.byId[mapId]
    assert(type(header) == "table" and header.id == mapId, "native map headers are indexed by their map ID")
    assert(
      type(header.incomingCalls) == "boolean" and type(header.outgoingCalls) == "boolean",
      "native map headers carry strict phone permission flags"
    )
    permissions[mapId] = {
      incoming = header.incomingCalls,
      outgoing = header.outgoingCalls,
    }
  end
  return permissions
end

local function compileMomCallIntroParameters()
  local parameters = {}
  for mapId = 0, MapReference.count - 1 do
    local header = assert(MapReference.byId[mapId], "native map headers are indexed by their map ID")
    local parameter = assert(header.momCallIntroParam, "native map headers carry the Mom call introduction parameter")
    assert(type(parameter) == "number" and parameter % 1 == 0 and parameter >= 0)
    parameters[mapId] = parameter
  end
  return parameters
end

local function compileGenericCallHeaders(contactId)
  local source =
    assert(PokegearSources.genericPhoneHeaders[contactId], "trainer contacts have source generic-call header rows")
  local headers = {}
  for _, direction in ipairs({ "outgoing", "incoming" }) do
    local rows = assert(source[direction], "generic-call source rows carry both directions")
    local compiled = {}
    for index, row in ipairs(rows) do
      assert(type(row) == "table" and #row == 4, "generic-call header rows carry four native fields")
      compiled[index] = { type = row[1], chance = row[2], scriptType = row[3], scriptId = row[4] }
    end
    headers[direction] = compiled
  end
  return headers
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

local function compilePhoneTriggers(versionId, contacts)
  local contactsById = {}
  for _, contact in ipairs(contacts) do
    assert(type(contact.id) == "number", "compiled phonebook contacts carry their source ID")
    assert(contactsById[contact.id] == nil, "phonebook contact IDs uniquely own native triggers")
    contactsById[contact.id] = contact.key
  end
  local triggers = PokegearSources.phoneTriggerRecords(versionId)
  for _, trigger in ipairs(triggers) do
    local contactKey = contactsById[trigger.contactId]
    if type(contactKey) ~= "string" then
      Errors.raise(
        PokegearCatalogCompiler.ERROR.PHONEBOOK_INVALID,
        "native phone trigger references a missing phonebook contact ID",
        { slot = trigger.slot, contactId = trigger.contactId }
      )
    end
    trigger.contact = contactKey
    trigger.contactId = nil
  end
  return triggers
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
    local id = reader:u8(base)
    local entryType = reader:u8(base + 1)
    local unknown2 = reader:u8(base + 2)
    local trainerClass = reader:u8(base + 3)
    local trainerId = reader:u16le(base + 4)
    local mapId = reader:u16le(base + 6)
    local gift = reader:u16le(base + 8)
    local localScript = reader:u16le(base + 10)
    local unknown12 = reader:u8(base + 12)
    local rematchWeekday = reader:u8(base + 13)
    local rematchTime = reader:u8(base + 14)
    local unknown15 = reader:u8(base + 15)
    local weights = {
      reader:u8(base + 16),
      reader:u8(base + 17),
      reader:u8(base + 18),
      reader:u8(base + 19),
    }
    -- Native contact identity is the record's own trainer/map/contact
    -- triple; array position is retained only as the producer
    -- translation. A repeated triple is a genuine duplicate identity.
    -- The greeting number rides beside its message bank: the record id is
    -- the phonebook number the source GetPhoneMessageGmm switches on for
    -- the bank, while the greeting number itself is the source
    -- phone-script selector (PhoneBookEntry.phoneScriptIfLocal), resolved
    -- onto bank messages by the phone script table. An id outside the
    -- bank index is corrupt phonebook data, never an empty bank.
    local key = string.format("hg.trainer.%d.map.%d.contact.%d", trainerId, mapId, id)
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
    local contact = {
      key = key,
      sourceIndex = index,
      id = id,
      family = family,
      entryType = entryType,
      unknown2 = unknown2,
      trainerClass = trainerClass,
      trainer = trainerClass,
      trainerId = trainerId,
      mapId = mapId,
      map = mapId,
      gift = gift,
      localScript = localScript,
      greeting = localScript,
      messageBank = messageBank,
      name = { bank = messageBank, entry = 0 },
      class = phoneClassReference(trainerClass),
      rematchWeekday = rematchWeekday,
      rematchTime = rematchTime,
      unknown12 = unknown12,
      unknown15 = unknown15,
      sortWeights = weights,
      sortWeight = weights[1],
    }
    if family == "trainer" then
      contact.genericCallHeaders = compileGenericCallHeaders(id)
    end
    contacts[#contacts + 1] = contact
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
  local catalog = {
    contacts = decoded.contacts,
    contactOrder = decoded.contactOrder,
    callDefinitions = compilePhoneDefinitions(),
    safariAreaMessageBank = PokegearSources.safariAreaMessageBank,
    callPermissions = compileCallPermissions(),
    momCallIntroParameters = compileMomCallIntroParameters(),
    callTriggers = compilePhoneTriggers(versionId, decoded.contacts),
    friendMapPhrases = PokegearCatalogCompiler.compileFriendMapPhrases(),
    rematches = {},
    rematchSets = compileRematchSets(romFs),
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
      sourceHash = Hashing.hashLua({ catalog = catalog, classLabels = PokegearSources.phoneClassLabels }),
    },
  }
end

return PokegearCatalogCompiler
