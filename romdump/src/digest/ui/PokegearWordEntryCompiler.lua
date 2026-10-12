-- Compiles the single-word Easy Chat selector family: the closed sprite
-- members of graphics archive a/0/7/6 into source-neutral cursor frames
-- plus the category data behind the eleven word groups. Word strings stay
-- with the PC dictionary and the message banks; this family publishes only
-- identities, order, geometry, and input facts. Selectors follow
-- romdump/src/config/PokegearWordEntrySources.lua. The compiler returns
-- staged records only; generation staging belongs to the artifact job.

local Errors = require("libs.errors.src.Errors")
local FieldMessageBank = require("romdump.src.digest.ui.FieldMessageBank")
local G2dDecoder = require("romdump.src.digest.ui.G2dDecoder")
local G2dRasterizer = require("romdump.src.digest.ui.G2dRasterizer")
local Hashing = require("romdump.src.digest.Hashing")
local Lz10 = require("romdump.src.digest.Lz10")
local PngWriter = require("libs.assets.src.PngWriter")
local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
local PokegearCache = require("libs.assets.src.PokegearCache")
local PokegearWordEntrySources = require("romdump.src.config.PokegearWordEntrySources")

local PokegearWordEntryCompiler = {}

local function unpackMember(archive, memberId, label)
  local bytes, err = archive:readMember(memberId)
  if not bytes then
    error(err or ("word-entry source member " .. memberId .. " is unavailable: " .. label), 0)
  end
  if string.byte(bytes, 1) == 0x10 then
    local plain, decodeError = Lz10.decode(bytes)
    if not plain then
      error(decodeError, 0)
    end
    return plain, Hashing.sha1hex(bytes)
  end
  return bytes, Hashing.sha1hex(bytes)
end

local function decode(kind, bytes, role)
  local record, err = G2dDecoder[kind](bytes, { label = "word-entry:" .. role })
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

local function openGraphics(romFs, entries)
  local spec = PokegearWordEntrySources.graphics
  local bytes, err = romFs:readSourcePath(spec.path)
  if not bytes then
    error(err or ("word-entry source archive is unavailable: " .. spec.path), 0)
  end
  local Narc = require("libs.nds.src.nitro.Narc")
  local archive, narcErr = Narc.open(assert(bytes), spec.path)
  if not archive then
    error(narcErr, 0)
  end
  if archive:memberCount() ~= spec.memberCount then
    error(
      "word-entry source archive has an unexpected member count: " .. spec.path .. " (" .. archive:memberCount() .. ")",
      0
    )
  end
  for memberId = 0, spec.memberCount - 1 do
    local member, memberErr = archive:readMember(memberId)
    if not member then
      error(memberErr or ("word-entry source member is unavailable: " .. spec.path .. ":" .. memberId), 0)
    end
    entries[#entries + 1] = { path = spec.path, member = memberId, sha1 = Hashing.sha1hex(member) }
  end
  return archive
end

local function openMessages(romFs)
  local archive, err = romFs:openNarc("messages")
  if not archive then
    error(err or "word-entry message archive is unavailable", 0)
  end
  return archive
end

-- Realizes every cursor sequence with source durations. Like the browse
-- selection blink, frames whose source cell carries no objects are cursor
-- hide phases: they stage as a fully transparent visual so renderer frame
-- indexing stays uniform instead of dropping the phase.
local function compileCursor(archive, assets)
  local members = PokegearWordEntrySources.graphics.members
  local charBytes = unpackMember(archive, members.mapping, "cursor.mapping")
  local paletteBytes = unpackMember(archive, members.palette, "cursor.palette")
  local cellBytes = unpackMember(archive, members.cell, "cursor.cell")
  local animBytes = unpackMember(archive, members.animation, "cursor.animation")
  local character = decode("decodeChar", charBytes, "cursor.mapping")
  local palette = decode("decodePalette", paletteBytes, "cursor.palette")
  local cells = decode("decodeCell", cellBytes, "cursor.cell")
  local animation = decode("decodeAnimation", animBytes, "cursor.animation")
  if #animation.anims == 0 then
    error("word-entry cursor animation carries no source sequence", 0)
  end
  local sequences = {}
  for animationId, sourceSequence in ipairs(animation.anims) do
    local frames = {}
    for frameIndex, frame in ipairs(sourceSequence.frames) do
      if type(frame.duration) ~= "number" or frame.duration <= 0 or frame.duration % 1 ~= 0 then
        error("word-entry cursor sequence carries non-integral frame timing", 0)
      end
      local path = PokegearCache.assetDir() .. "/word-entry-cursor-" .. animationId .. "-" .. frameIndex .. ".png"
      local cell = type(frame.cell) == "number" and cells.cells[frame.cell + 1] or nil
      if cell ~= nil and type(cell.objs) == "table" and #cell.objs == 0 then
        assets[path] = PngWriter.encode(1, 1, string.char(0, 0, 0, 0))
        frames[frameIndex] =
          { image = path, width = 1, height = 1, anchorX = 0, anchorY = 0, duration = frame.duration }
      else
        local rendered = G2dRasterizer.renderAnimationFrame(
          character,
          palette,
          cells,
          sourceSequence,
          frameIndex,
          { role = "word-entry.cursor." .. animationId, frame = frameIndex - 1 }
        )
        assets[path] = PngWriter.encode(rendered.width, rendered.height, rendered.pixels)
        frames[frameIndex] = {
          image = path,
          width = rendered.width,
          height = rendered.height,
          anchorX = rendered.offset.x,
          anchorY = rendered.offset.y,
          duration = frame.duration,
        }
      end
    end
    sequences[animationId] = {
      frames = frames,
      playMode = sourceSequence.playMode,
      loopStartFrameIdx = sourceSequence.loopStartFrameIdx,
    }
  end
  return { sequences = sequences }
end

local function compileGroups(versionId, romFs, dependencies)
  local archive = openMessages(romFs)
  local banks = PokegearWordEntrySources.wordBankRecords(versionId)
  local groups = {}
  for index, entry in ipairs(banks) do
    local bytes, memberError = archive:readMember(entry.messageBank)
    if not bytes then
      error(memberError or ("word-entry message bank is unavailable: " .. entry.messageBank), 0)
    end
    dependencies[#dependencies + 1] = { role = "message-bank-" .. entry.messageBank, sha1 = Hashing.sha1hex(bytes) }
    local bank, decodeError = FieldMessageBank.decode(bytes, { label = "word-entry-bank-" .. entry.messageBank })
    if not bank then
      error(decodeError, 0)
    end
    if #bank.messages ~= entry.wordCount then
      error(
        "word-entry source bank "
          .. entry.messageBank
          .. " has "
          .. #bank.messages
          .. " entries; expected "
          .. entry.wordCount,
        0
      )
    end
    groups[index] =
      { group = index - 1, bank = entry.messageBank, count = entry.wordCount, firstWordId = entry.firstWordId }
  end
  return groups
end

local function compileInterface(romFs, dependencies)
  local archive = openMessages(romFs)
  local counts = {}
  for _, bankId in ipairs(PokegearWordEntrySources.messages.interfaceBanks) do
    local bytes, memberError = archive:readMember(bankId)
    if not bytes then
      error(memberError or ("word-entry interface bank is unavailable: " .. bankId), 0)
    end
    if #bytes == 0 then
      error("word-entry interface bank is empty: " .. bankId, 0)
    end
    dependencies[#dependencies + 1] = { role = "message-bank-" .. bankId, sha1 = Hashing.sha1hex(bytes) }
    local bank, decodeError = FieldMessageBank.decode(bytes, { label = "word-entry-interface-" .. bankId })
    if not bank then
      error(decodeError, 0)
    end
    counts[#counts + 1] = #bank.messages
  end
  return counts
end

local function _compile(romFs, versionId)
  assert(romFs and romFs.readSourcePath and romFs.openNarc and romFs.metadata, "compile requires a RomFs")
  assert(type(versionId) == "string" and versionId ~= "", "compile requires a version")
  PokegearWordEntrySources.checkVersion(versionId)
  local metadata = assert(romFs:metadata())
  assert(type(metadata.sha1) == "string", "ROM metadata carries its SHA-1")
  local entries = {}
  local assets = {}
  local dependencies = { PokegearCache.FORMAT .. ":" .. PokegearCache.SCHEMA }

  local archive = openGraphics(romFs, entries)
  local cursor = compileCursor(archive, assets)
  local groups = compileGroups(versionId, romFs, dependencies)
  local interfaceCounts = compileInterface(romFs, dependencies)

  local background = PokegearWordEntrySources.graphics.background
  local section = {
    groups = groups,
    cursor = cursor,
    background = {
      screenMember = background.screenMember,
      charMember = background.charMember,
      layers = { background.layers[1], background.layers[2] },
    },
    text = { interfaceBanks = { 282, 283, 284 }, interfaceCounts = interfaceCounts },
    input = {
      hitboxes = PokegearWordEntrySources.input.hitboxes,
      touchYMin = PokegearWordEntrySources.input.touchYMin,
      touchYMax = PokegearWordEntrySources.input.touchYMax,
      confirmSound = PokegearWordEntrySources.input.confirmSound,
    },
  }
  local validated, schemaErr = PokegearAssetSchema.validateWordEntry(section)
  if validated == nil then
    error(schemaErr, 0)
  end
  local provenance = {
    schema = PokegearCache.SCHEMA,
    cacheFormat = PokegearCache.FORMAT,
    family = "pokegear-word-entry",
    versionId = versionId,
    versionRomSha1 = metadata.sha1,
    source = PokegearWordEntrySources.provenance,
    selections = {
      overlay = PokegearWordEntrySources.overlay,
      graphics = PokegearWordEntrySources.graphics,
      messages = PokegearWordEntrySources.messages,
      input = PokegearWordEntrySources.input,
      presentation = PokegearWordEntrySources.presentation,
    },
    entries = entries,
    dependencies = dependencies,
  }
  local dependencyHash = Hashing.hashLua(provenance)
  provenance.dependencyHash = dependencyHash
  local marker = PokegearCache.wordEntryMarker(metadata.sha1, dependencyHash)
  return {
    section = section,
    manifest = section,
    assets = assets,
    files = assets,
    provenance = provenance,
    dependencyHash = dependencyHash,
    marker = marker,
  }
end

---@param romFs table<string, unknown> RomFs-shaped source filesystem
---@param versionId string
---@return table<string, unknown>|nil bundle
---@return Errors.Error?
function PokegearWordEntryCompiler.compile(romFs, versionId)
  local ok, result = xpcall(_compile, function(err)
    if Errors.is(err) then
      return err
    end
    return { raw = err, trace = debug.traceback("", 2) }
  end, romFs, versionId)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result --[[@as Errors.Error]]
  end
  if type(result) == "table" and result.trace then
    error(result.raw, 0)
  end
  error(result, 0)
end

return PokegearWordEntryCompiler
