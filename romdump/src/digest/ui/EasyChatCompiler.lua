-- Compiles the shared Easy Chat family from the retail dump: the exact
-- dictionary, menu, template, interface, and consumer tables (data scope)
-- plus the standalone editor presentation (graphics scope). Two entry
-- points share one source reader: compileData joins the curated species
-- identities to the resolved mon catalog, compilePresentation rasterizes
-- the editor archive through the shared Nitro/message primitives.
-- The compiler returns staged records only; generation staging belongs
-- to the cache writer. Selector tables follow
-- romdump/src/config/EasyChatSources.lua.

local Errors = require("libs.errors.src.Errors")
local FieldMessageBank = require("romdump.src.digest.ui.FieldMessageBank")
local FieldMessageTokenizer = require("romdump.src.digest.ui.FieldMessageTokenizer")
local G2dDecoder = require("romdump.src.digest.ui.G2dDecoder")
local G2dRasterizer = require("romdump.src.digest.ui.G2dRasterizer")
local Hashing = require("romdump.src.digest.Hashing")
local Lz10 = require("romdump.src.digest.Lz10")
local PngEncoder = require("romdump.src.digest.PngEncoder")
local EasyChatAssetSchema = require("libs.assets.src.EasyChatAssetSchema")
local EasyChatCache = require("libs.assets.src.EasyChatCache")
local EasyChatSources = require("romdump.src.config.EasyChatSources")

local EasyChatCompiler = {}

local charmap = require("romdump.src.catalog.hgss.charmap")

-- Members of the editor graphics archive that arrive LZ10-compressed;
-- the rest decode directly (overlay102 source packing).
local LZ10_MEMBERS = {
  [0] = true,
  [1] = true,
  [2] = true,
  [3] = true,
  [4] = true,
  [5] = true,
  [7] = true,
  [8] = true,
  [9] = true,
  [11] = true,
  [12] = true,
}

-- Semantic roles for the compiled sprite sequences, keyed by the source
-- animation index (src/application/easy_chat_app_panels.c cursor setup).
local SEQUENCE_ROLES = {
  [0] = "wordSlotCursorActive",
  [1] = "wordSlotCursorInactive",
  [2] = "mainButtonCursorActive",
  [3] = "mainButtonCursorInactive",
  [4] = "categoryCursorActive",
  [5] = "categoryCursorInactive",
  [6] = "initialCursorActive",
  [7] = "initialCursorInactive",
  [8] = "listWordCursorActive",
  [9] = "listWordCursorInactive",
  [14] = "sentenceCursorActive",
  [15] = "sentenceCursorInactive",
  [16] = "listCursorHidden",
  [17] = "listCursorHiddenInactive",
  [18] = "sliderThumb",
  [19] = "templateArrowLeft",
  [21] = "templateArrowRight",
  [23] = "sliderBar",
  [24] = "listArrowUp",
  [26] = "listArrowDown",
}

local LAYER_ROLES = {
  { role = "compositionMain", screenMember = 0, charMember = 1, paletteMember = 16 },
  { role = "categories", screenMember = 2, charMember = 3, paletteMember = 6 },
  { role = "backdrop", screenMember = 4, charMember = 5, paletteMember = 6 },
  { role = "compositionSub", screenMember = 11, charMember = 12, paletteMember = 13 },
  { role = "buttons", screenMember = 14, charMember = 1, paletteMember = 16 },
  { role = "modeStates", screenMember = 15, charMember = 5, paletteMember = 6 },
}

---@param romFs table<string, unknown> RomFs-shaped source filesystem
---@param versionId string
local function checkReader(romFs, versionId)
  assert(romFs and romFs.readSourcePath and romFs.openNarc and romFs.metadata, "compile requires a RomFs")
  assert(type(versionId) == "string" and versionId ~= "", "compile requires a version")
  EasyChatSources.checkVersion(versionId)
end

---@param archive table<string, unknown>
---@param memberId integer
---@param label string
---@return string bytes
---@return string sha1
local function unpackMember(archive, memberId, label)
  local bytes, err = archive:readMember(memberId)
  if not bytes then
    error(err or ("word editor source member is unavailable: " .. memberId .. ": " .. label), 0)
  end
  local raw = assert(bytes)
  if LZ10_MEMBERS[memberId] then
    local plain, decodeError = Lz10.decode(raw)
    if not plain then
      error(decodeError, 0)
    end
    return plain, Hashing.sha1hex(raw)
  end
  return raw, Hashing.sha1hex(raw)
end

---@param bank table<string, unknown>
---@param messageId integer
---@param label string
---@return table<integer, table<string, unknown>> tokens
local function tokenizeEntry(bank, messageId, label)
  local message = bank.messages[messageId + 1]
  if message == nil then
    error(label .. " message " .. messageId .. " is missing", 0)
  end
  local tokens, tokenizeError =
    FieldMessageTokenizer.tokenize(message.raw, charmap, { bankId = label, messageId = messageId })
  if not tokens then
    error(tokenizeError, 0)
  end
  return tokens
end

---@param wordId integer
---@return boolean
local function isForeignGreeting(wordId)
  return wordId >= EasyChatSources.greetingBase
    and wordId < EasyChatSources.greetingBase + EasyChatSources.greetingCount
end

---@param wordId integer
---@return boolean
local function isTrendyWord(wordId)
  return wordId >= EasyChatSources.trendyBase and wordId < EasyChatSources.trendyBase + EasyChatSources.trendyCount
end

---@param monCatalog table<string, unknown> resolved mon catalog or raw mon root
---@return fun(nativeId: integer): string species key resolver
local function speciesKeyResolver(monCatalog)
  assert(type(monCatalog) == "table", "data compile joins the resolved mon catalog")
  if type(monCatalog.speciesKeyByNativeId) == "function" then
    local function resolveByMethod(nativeId)
      return monCatalog:speciesKeyByNativeId(nativeId)
    end
    return resolveByMethod
  end
  local byNative = {}
  for key, record in pairs(assert(monCatalog.species, "raw mon roots carry their species")) do
    if type(record) == "table" and type(record.nativeId) == "number" then
      byNative[record.nativeId] = key
    end
  end
  local function resolveByNative(nativeId)
    local key = byNative[nativeId]
    if key == nil then
      error("unknown native species identity " .. nativeId, 0)
    end
    return key
  end
  return resolveByNative
end

---@param wordId integer
---@param resolveSpecies fun(nativeId: integer): string
---@return table<string, unknown> eligibility
local function eligibilityFor(wordId, resolveSpecies)
  if wordId <= 495 then
    local speciesKey = resolveSpecies(wordId)
    assert(type(speciesKey) == "string", "curated species resolve through the mon catalog")
    return { kind = "seen", speciesKey = speciesKey }
  end
  if wordId <= 963 then
    return { kind = "gameClear" }
  end
  if isForeignGreeting(wordId) then
    return { kind = "greeting", bit = wordId - EasyChatSources.greetingBase }
  end
  if isTrendyWord(wordId) then
    return { kind = "trendy", bit = wordId - EasyChatSources.trendyBase }
  end
  return { kind = "always" }
end

---@param romFs table<string, unknown>
---@return table<string, unknown> archive
---@return string sha1
local function openMessages(romFs)
  local Narc = require("libs.nds.src.nitro.Narc")
  local bytes, err = romFs:readSourcePath("a/0/2/7")
  if not bytes then
    error(err or "word editor message archive is unavailable: a/0/2/7", 0)
  end
  local archive, narcErr = Narc.open(assert(bytes), "a/0/2/7")
  if not archive then
    error(narcErr, 0)
  end
  return archive, Hashing.sha1hex(assert(bytes))
end

---@param archive table<string, unknown>
---@param memberId integer
---@param expectedCount integer?
---@param dependencies table<integer, table<string, unknown>>
---@return table<string, unknown> bank
local function decodeMessageBank(archive, memberId, expectedCount, dependencies)
  local bytes = assert(archive:readMember(memberId))
  dependencies[#dependencies + 1] = { role = "message-bank-" .. memberId, sha1 = Hashing.sha1hex(bytes) }
  local bank, decodeError = FieldMessageBank.decode(bytes, { label = "word-editor-bank-" .. memberId })
  if not bank then
    error(decodeError, 0)
  end
  if expectedCount ~= nil and #bank.messages ~= expectedCount then
    error(
      "word editor source bank " .. memberId .. " has " .. #bank.messages .. " entries; expected " .. expectedCount,
      0
    )
  end
  return bank
end

local function _compileData(romFs, versionId, monCatalog)
  checkReader(romFs, versionId)
  local resolveSpecies = speciesKeyResolver(monCatalog)
  local metadata = assert(romFs:metadata())
  assert(type(metadata.sha1) == "string", "ROM metadata carries its SHA-1")
  ---@type table<integer, unknown> mixed tag plus referenced-archive records
  local dependencies = { EasyChatCache.FORMAT .. ":" .. EasyChatCache.CATALOG_SCHEMA }

  local messages, messagesSha1 = openMessages(romFs)
  dependencies[#dependencies + 1] = { role = "message-archive", sha1 = messagesSha1 }

  local words = {}
  for _, entry in ipairs(EasyChatSources.wordBanks) do
    local bank = decodeMessageBank(messages, entry.messageBank, entry.wordCount, dependencies)
    for offset = 0, entry.wordCount - 1 do
      local wordId = entry.firstWordId + offset
      local tokens = tokenizeEntry(bank, offset, "word-bank-" .. entry.messageBank)
      assert(words[wordId + 1] == nil, "word editor dictionary repeats identity " .. wordId)
      words[wordId + 1] = { id = wordId, tokens = tokens, eligibility = eligibilityFor(wordId, resolveSpecies) }
    end
  end
  assert(#words == 1495, "word editor dictionary has " .. #words .. " rows; expected 1495")

  local templates = {}
  for logicalBank = 0, 4 do
    local physical = EasyChatSources.logicalTemplateBanks[logicalBank + 1]
    local bank = decodeMessageBank(messages, physical, 20, dependencies)
    for number = 0, 19 do
      local tokens = tokenizeEntry(bank, number, "template-bank-" .. physical)
      local slots = 0
      for _, token in ipairs(tokens) do
        if token.kind == "substitution" then
          slots = slots + 1
        end
      end
      if slots > 2 then
        error("word editor template bank " .. logicalBank .. " number " .. number .. " has " .. slots .. " slots", 0)
      end
      templates[logicalBank * 20 + number + 1] =
        { bank = logicalBank, number = number, wordCount = slots, tokens = tokens }
    end
  end

  local bank282 = decodeMessageBank(messages, 282, nil, dependencies)
  local bank283 = decodeMessageBank(messages, 283, nil, dependencies)
  local bank284 = decodeMessageBank(messages, 284, nil, dependencies)

  local groups = {}
  for index, spec in ipairs(EasyChatSources.groups) do
    local wordIds = {}
    local cursor = 1
    local raw = spec.words
    while cursor <= #raw do
      local value = raw[cursor]
      if value == 0xFFFE then
        local size = raw[cursor + 1]
        assert(type(size) == "number" and size >= 1, "category alternative group carries its size")
        wordIds[#wordIds + 1] = raw[cursor + 2]
        cursor = cursor + 2 + size
      else
        wordIds[#wordIds + 1] = value
        cursor = cursor + 1
      end
    end
    groups[index] =
      { key = spec.key, labelTokens = tokenizeEntry(bank282, index - 1, "interface-bank-282"), wordIds = wordIds }
  end

  local initials = {}
  for index, spec in ipairs(EasyChatSources.initials) do
    local cell = assert(EasyChatSources.gridCells[index], "initial list " .. index .. " maps its grid letter")
    local glyph = charmap.glyphs[cell.char]
    if glyph == nil then
      error("initial grid letter 0x" .. string.format("%04X", cell.char) .. " has no charmap glyph", 0)
    end
    local candidates = {}
    for _, candidate in ipairs(spec.candidates) do
      candidates[#candidates + 1] = candidate
    end
    initials[index] = {
      key = spec.key,
      labelTokens = { { kind = "glyph", code = cell.char, text = glyph, raw = { cell.char } } },
      candidates = candidates,
    }
  end

  local interface = {
    categoryEmpty = tokenizeEntry(bank282, 12, "interface-bank-282"),
    tabs = {
      tokenizeEntry(bank283, 11, "interface-bank-283"),
      tokenizeEntry(bank283, 12, "interface-bank-283"),
    },
    buttons = {
      tokenizeEntry(bank284, 0, "interface-bank-284"),
      tokenizeEntry(bank284, 1, "interface-bank-284"),
      tokenizeEntry(bank284, 2, "interface-bank-284"),
    },
    prompts = {
      answer = tokenizeEntry(bank283, 6, "interface-bank-283"),
      incomplete = tokenizeEntry(bank283, 7, "interface-bank-283"),
      quit = tokenizeEntry(bank283, 8, "interface-bank-283"),
    },
    ordinary = tokenizeEntry(bank283, 0, "interface-bank-283"),
  }

  local primoWords = {}
  for _, wordId in ipairs(EasyChatSources.primoWords) do
    primoWords[#primoWords + 1] = wordId
  end
  local gridCells = {}
  for _, cell in ipairs(EasyChatSources.gridCells) do
    gridCells[#gridCells + 1] = {
      char = cell.char,
      x = cell.x,
      y = cell.y,
      up = cell.up,
      down = cell.down,
      left = cell.left,
      right = cell.right,
      belowBack = cell.belowBack,
      aboveBack = cell.aboveBack,
    }
  end
  local unionAvatars = { choices = EasyChatSources.avatarChoices, rows = {} }
  for _, row in ipairs(EasyChatSources.avatarAttributes) do
    unionAvatars.rows[#unionAvatars.rows + 1] = { spriteId = row.spriteId, classId = row.classId }
  end

  local data = {
    schema = EasyChatCache.CATALOG_SCHEMA,
    versionId = versionId,
    words = words,
    templates = templates,
    groups = groups,
    initials = initials,
    interface = interface,
    primoWords = primoWords,
    unionAvatars = unionAvatars,
    gridCells = gridCells,
  }
  local validated, schemaErr = EasyChatAssetSchema.validateCatalog(data)
  if validated == nil then
    error(schemaErr, 0)
  end
  local provenance = {
    schema = EasyChatCache.CATALOG_SCHEMA,
    cacheFormat = EasyChatCache.FORMAT,
    family = "easy-chat-data",
    versionId = versionId,
    versionRomSha1 = metadata.sha1,
    source = EasyChatSources.provenance,
    dependencies = dependencies,
  }
  local dependencyHash = Hashing.hashLua(provenance)
  provenance.dependencyHash = dependencyHash
  data.provenance = provenance
  data.dependencyHash = dependencyHash
  data.marker = EasyChatCache.dataMarker(metadata.sha1, dependencyHash)
  return data
end

---@param romFs table<string, unknown>
---@return table<string, unknown> archive
---@return string sha1
local function openGraphics(romFs)
  local Narc = require("libs.nds.src.nitro.Narc")
  local spec = EasyChatSources.graphics
  local bytes, err = romFs:readSourcePath(spec.path)
  if not bytes then
    error(err or ("word editor source archive is unavailable: " .. spec.path), 0)
  end
  local archive, narcErr = Narc.open(assert(bytes), spec.path)
  if not archive then
    error(narcErr, 0)
  end
  if archive:memberCount() ~= spec.memberCount then
    error(
      "word editor source archive has an unexpected member count: " .. spec.path .. " (" .. archive:memberCount() .. ")",
      0
    )
  end
  return archive, Hashing.sha1hex(assert(bytes))
end

---@param record unknown
---@param role string
---@return table<string, unknown> decoded record or raises
local function mustDecode(record, role)
  if record == nil then
    error("word editor source member failed to decode: " .. role, 0)
  end
  return record --[[@as table]]
end

local function _compilePresentation(romFs, versionId, data)
  checkReader(romFs, versionId)
  assert(type(data) == "table", "presentation compile reads the compiled data closure")
  local metadata = assert(romFs:metadata())
  assert(type(metadata.sha1) == "string", "ROM metadata carries its SHA-1")
  ---@type table<integer, unknown> mixed tag plus referenced-archive records
  local dependencies = { EasyChatCache.FORMAT .. ":" .. EasyChatCache.SCHEMA }

  local archive, archiveSha1 = openGraphics(romFs)
  local entries = { { path = EasyChatSources.graphics.path, sha1 = archiveSha1 } }
  dependencies[#dependencies + 1] = { role = "graphics-archive", sha1 = archiveSha1 }

  local members = {}
  for memberId = 0, 16 do
    members[memberId] = { unpackMember(archive, memberId, "member-" .. memberId) }
  end

  local function decode(kind, memberId, role)
    local record, err = G2dDecoder[kind](members[memberId][1], { label = "word-editor:" .. role })
    if not record then
      if Errors.is(err) then
        local attributed = err --[[@as Errors.Error]]
        attributed.context.role = role
        error(attributed, 0)
      end
      error(err, 0)
    end
    return record
  end

  local chars, palettes, screens = {}, {}, {}
  for _, memberId in ipairs({ 1, 3, 5, 9, 12 }) do
    chars[memberId] = decode("decodeChar", memberId, "chars-" .. memberId)
  end
  for _, memberId in ipairs({ 6, 10, 13, 16 }) do
    palettes[memberId] = decode("decodePalette", memberId, "palette-" .. memberId)
  end
  for _, memberId in ipairs({ 0, 2, 4, 11, 14, 15 }) do
    screens[memberId] = decode("decodeScreen", memberId, "screen-" .. memberId)
  end
  local cells = decode("decodeCell", 7, "cells")
  local animation = decode("decodeAnimation", 8, "animation")
  if #animation.anims == 0 then
    error("word editor cursor animation carries no source sequence", 0)
  end
  if #animation.anims ~= 28 then
    error("word editor animation carries " .. #animation.anims .. " sequences; expected 28", 0)
  end

  local assets = {}
  local layers = {}
  for _, layer in ipairs(LAYER_ROLES) do
    local path = EasyChatCache.assetDir() .. "/layer-" .. layer.role .. ".png"
    local rendered = G2dRasterizer.renderScreen(
      mustDecode(chars[layer.charMember], "chars"),
      mustDecode(palettes[layer.paletteMember], "palette"),
      mustDecode(screens[layer.screenMember], "screen"),
      { role = "word-editor.layer." .. layer.role },
      {}
    )
    assets[path] = PngEncoder.encode(rendered.width, rendered.height, rendered.pixels)
    layers[#layers + 1] = {
      role = layer.role,
      image = path,
      width = rendered.width,
      height = rendered.height,
      palette = layer.paletteMember,
      drawRole = "background",
    }
  end

  local function cellBounds(cell)
    local first = assert(cell.objs[1], "sprite cell carries its objects")
    local minX, minY = first.x, first.y
    local maxX, maxY = first.x + first.width, first.y + first.height
    for i = 2, #cell.objs do
      local obj = cell.objs[i]
      minX = math.min(minX, obj.x)
      minY = math.min(minY, obj.y)
      maxX = math.max(maxX, obj.x + obj.width)
      maxY = math.max(maxY, obj.y + obj.height)
    end
    return minX, minY, maxX, maxY
  end

  local sequences = {}
  for animationId, sourceSequence in ipairs(animation.anims) do
    local frames = {}
    for frameIndex, frame in ipairs(sourceSequence.frames) do
      if type(frame.duration) ~= "number" or frame.duration <= 0 or frame.duration % 1 ~= 0 then
        error("word editor sequence carries non-integral frame timing", 0)
      end
      local path = EasyChatCache.assetDir() .. "/sequence-" .. animationId .. "-" .. frameIndex .. ".png"
      local cell = type(frame.cell) == "number" and cells.cells[frame.cell + 1] or nil
      local minX, minY = 0, 0
      if cell ~= nil and type(cell.objs) == "table" and #cell.objs == 0 then
        assets[path] = PngEncoder.encode(1, 1, string.char(0, 0, 0, 0))
      else
        local rendered = G2dRasterizer.renderAnimationFrame(
          mustDecode(chars[9], "chars"),
          mustDecode(palettes[10], "palette"),
          cells,
          sourceSequence,
          frameIndex,
          { role = "word-editor.sequence." .. animationId, frame = frameIndex - 1 }
        )
        assets[path] = PngEncoder.encode(rendered.width, rendered.height, rendered.pixels)
        local sourceCell = cells.cells[frame.cell + 1]
        if sourceCell ~= nil then
          minX, minY = cellBounds(sourceCell)
        end
      end
      local priority = 0
      if cell ~= nil and cell.objs ~= nil and cell.objs[1] ~= nil and cell.objs[1].priority ~= nil then
        priority = cell.objs[1].priority
      end
      frames[frameIndex] = {
        image = path,
        duration = frame.duration,
        originX = minX,
        originY = minY,
        priority = priority,
      }
    end
    sequences[animationId] = {
      role = SEQUENCE_ROLES[animationId - 1] or ("sequence-" .. animationId),
      sourceIndex = animationId - 1,
      playMode = sourceSequence.playMode,
      loopStartFrameIdx = sourceSequence.loopStartFrameIdx,
      frames = frames,
    }
  end

  local paletteRoles = {}
  for _, memberId in ipairs({ 6, 10, 13, 16 }) do
    paletteRoles[#paletteRoles + 1] = { role = "palette-" .. memberId, colors = palettes[memberId].colors }
  end

  local manifest = {
    schema = EasyChatCache.SCHEMA,
    versionId = versionId,
    layers = layers,
    buttons = {
      { role = "confirm" },
      { role = "cancel" },
      { role = "quit" },
    },
    sequences = sequences,
    palettes = paletteRoles,
  }
  local validated, schemaErr = EasyChatAssetSchema.validateManifest(manifest)
  if validated == nil then
    error(schemaErr, 0)
  end
  for _, path in ipairs(EasyChatCache.referencedPaths(manifest)) do
    if assets[path] == nil then
      error("word editor bundle is missing referenced asset " .. path, 0)
    end
  end
  local provenance = {
    schema = EasyChatCache.SCHEMA,
    cacheFormat = EasyChatCache.FORMAT,
    family = "easy-chat",
    versionId = versionId,
    versionRomSha1 = metadata.sha1,
    source = EasyChatSources.provenance,
    entries = entries,
    dependencies = dependencies,
  }
  local dependencyHash = Hashing.hashLua(provenance)
  provenance.dependencyHash = dependencyHash
  return {
    manifest = manifest,
    assets = assets,
    files = assets,
    provenance = provenance,
    dependencyHash = dependencyHash,
    marker = EasyChatCache.marker(metadata.sha1, dependencyHash),
  }
end

---@param romFs table<string, unknown> RomFs-shaped source filesystem
---@param versionId string
---@param monCatalog table<string, unknown> resolved mon catalog for the species join
---@return table<string, unknown>|nil bundle
---@return Errors.Error?
function EasyChatCompiler.compileData(romFs, versionId, monCatalog)
  local ok, result = xpcall(_compileData, function(err)
    if Errors.is(err) then
      return err
    end
    return { raw = err, trace = debug.traceback("", 2) }
  end, romFs, versionId, monCatalog)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result --[[@as Errors.Error]]
  end
  if type(result) == "table" then
    return nil, result.raw
  end
  return nil, result
end

---@param romFs table<string, unknown> RomFs-shaped source filesystem
---@param versionId string
---@param data table<string, unknown> compiled data bundle
---@return table<string, unknown>|nil bundle
---@return Errors.Error?
function EasyChatCompiler.compilePresentation(romFs, versionId, data)
  local ok, result = xpcall(_compilePresentation, function(err)
    if Errors.is(err) then
      return err
    end
    return { raw = err, trace = debug.traceback("", 2) }
  end, romFs, versionId, data)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result --[[@as Errors.Error]]
  end
  if type(result) == "table" then
    return nil, result.raw
  end
  return nil, result
end

return EasyChatCompiler
