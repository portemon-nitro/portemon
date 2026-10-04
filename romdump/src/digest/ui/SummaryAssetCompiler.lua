-- Compiles the generated summary presentation class: canonical group
-- background variants, semantic windows, background/stamp/ribbon/egg
-- visuals, lowered text, palette roles, picture timelines, ribbon
-- definitions, performance tables, dex mapping, and memo records. Source
-- member selection and geometry live in
-- romdump/src/config/SummarySources.lua; this module owns the decode,
-- rasterization, and the normalized bundle. 2D mechanics reuse
-- G2dDecoder/G2dRasterizer/PngWriter; front-picture pixels resolve
-- through the existing mon presentation helper and are never repacked
-- here; species portraits stay in the mon class and are referenced, never
-- copied. The runtime consumes only the manifest and the generated
-- files, never this module. Pure module: no love dependency.
-- Source basis: pret/pokeheartgold@9d8b7591f09b65804da2fb2dfd56f320633e0d36
-- (see SummarySources for the per-table provenance).

local Errors = require("libs.errors.src.Errors")
local Hashing = require("romdump.src.digest.Hashing")
local PngWriter = require("libs.assets.src.PngWriter")
local G2dDecoder = require("romdump.src.digest.ui.G2dDecoder")
local G2dRasterizer = require("romdump.src.digest.ui.G2dRasterizer")
local SummaryAssetSchema = require("libs.assets.src.SummaryAssetSchema")
local SummaryCache = require("libs.assets.src.SummaryCache")
local SummarySources = require("romdump.src.config.SummarySources")
local SummaryPictureCompiler = require("romdump.src.digest.ui.SummaryPictureCompiler")
local MonSources = require("romdump.src.config.MonSources")
local MonPresentationCompiler = require("romdump.src.digest.mons.MonPresentationCompiler")
local FieldMessageBank = require("romdump.src.digest.ui.FieldMessageBank")
local FieldMessageTokenizer = require("romdump.src.digest.ui.FieldMessageTokenizer")
local charmap = require("romdump.src.reference.hgss.charmap")

---@class SummaryAssetCompiler
local SummaryAssetCompiler = {}

-- Named ownership of the compiler protocol error code; tests assert the
-- constant, never the raw string.
SummaryAssetCompiler.ERROR = {
  SOURCE_INVALID = "SUMMARY_SOURCE_INVALID",
}

---@noreturn
local function sourceError(message, context)
  error(Errors.new(SummaryAssetCompiler.ERROR.SOURCE_INVALID, "summary " .. message, context or {}), 0)
end

local function openArchive(romFs, symbol, role)
  local archive, err = romFs:openNarc(symbol)
  if not archive then
    sourceError("the " .. role .. " archive does not open: " .. Errors.format(err), {})
  end
  assert(archive ~= nil, "unopenable archives fail above")
  return archive
end

local function readMember(archive, memberId, role, dependencies, archiveLabel)
  local member, err = archive:readMember(memberId)
  if not member then
    sourceError("member " .. memberId .. " is unreadable: " .. Errors.format(err), { role = role, memberId = memberId })
  end
  assert(member ~= nil, "unreadable members fail above")
  dependencies[#dependencies + 1] =
    { name = (archiveLabel or "summary") .. ":member:" .. memberId, role = role, sha1 = Hashing.sha1hex(member) }
  return member
end

local function decode(kind, bytes, role)
  local record, err = G2dDecoder[kind](bytes, { label = "summary:" .. role })
  if not record then
    assert(err)
    sourceError(role .. " does not decode: " .. err.message, { role = role, cause = err.code })
  end
  return record
end

local function paletteSlice(colors, bank, role)
  if bank < 0 or (bank + 1) * 16 > #colors then
    sourceError(role .. " palette bank is unavailable", { bank = bank, available = #colors })
  end
  local slice = {}
  for index = 1, 16 do
    slice[index] = colors[bank * 16 + index]
  end
  return slice
end

local function writePng(rendered, path, assets)
  assets[path] = PngWriter.encode(rendered.width, rendered.height, rendered.pixels)
  return { image = path, width = rendered.width, height = rendered.height }
end

local function rasterizeScreen(charData, paletteColors, screen, role)
  local ok, image = pcall(G2dRasterizer.renderScreen, charData, { colors = paletteColors }, screen, { role = role })
  if not ok then
    if Errors.is(image) then
      ---@cast image Errors.Error
      sourceError(role .. " does not rasterize: " .. image.message, { role = role, cause = image.code })
    end
    error(image, 0)
  end
  assert(type(image) == "table", "screen rasterization returns an image")
  return image
end

-- The 302 message names in bank order. Every non-blank message of the
-- summary bank carries exactly one of these roles; blank window fillers
-- carry no text and are skipped by the lowering below.
local SUMMARY_NAMES = {
  "nickname",
  "genderMale",
  "genderFemale",
  "levelNumber",
  "itemLabel",
  "itemName",
  "noItem",
  "info",
  "dexNoLabel",
  "dexNumber",
  "nameLabel",
  "speciesName",
  "typeLabel",
  "otLabel",
  "otName",
  "idNoLabel",
  "idNumber",
  "expPointsLabel",
  "expPoints",
  "toNextLabel",
  nil,
  "expToNext",
  "unknownValue",
  "trainerMemo",
  "natureHardy",
  "natureLonely",
  "natureBrave",
  "natureAdamant",
  "natureNaughty",
  "natureBold",
  "natureDocile",
  "natureRelaxed",
  "natureImpish",
  "natureLax",
  "natureTimid",
  "natureHasty",
  "natureSerious",
  "natureJolly",
  "natureNaive",
  "natureModest",
  "natureMild",
  "natureQuiet",
  "natureBashful",
  "natureRash",
  "natureCalm",
  "natureGentle",
  "natureSassy",
  "natureCareful",
  "natureQuirky",
  "memoWildEncounter",
  "memoWildEncounterTraded",
  "memoWildGift",
  "memoEggHatched",
  "memoEggHatchedTraded",
  "memoEggHatchedGift",
  "memoEggHatchedGiftTraded",
  "memoFatefulEncounter",
  "memoFatefulEncounterTraded",
  "memoFatefulEggHatched",
  "memoFatefulEggHatchedTraded",
  "memoFatefulEggHatchedArrived",
  "memoFatefulEggHatchedArrivedTraded",
  "memoFatefulEggHatchedGift",
  "memoFatefulEggHatchedGiftTraded",
  "memoMigrated",
  "flavorSpicy",
  "flavorDry",
  "flavorSweet",
  "flavorBitter",
  "flavorSour",
  "characteristicBase",
  "characteristicHp0",
  "characteristicHp1",
  "characteristicHp2",
  "characteristicHp3",
  "characteristicHp4",
  "characteristicAttack0",
  "characteristicAttack1",
  "characteristicAttack2",
  "characteristicAttack3",
  "characteristicAttack4",
  "characteristicDefense0",
  "characteristicDefense1",
  "characteristicDefense2",
  "characteristicDefense3",
  "characteristicDefense4",
  "characteristicSpeed0",
  "characteristicSpeed1",
  "characteristicSpeed2",
  "characteristicSpeed3",
  "characteristicSpeed4",
  "characteristicSpAttack0",
  "characteristicSpAttack1",
  "characteristicSpAttack2",
  "characteristicSpAttack3",
  "characteristicSpAttack4",
  "characteristicSpDefense0",
  "characteristicSpDefense1",
  "characteristicSpDefense2",
  "characteristicSpDefense3",
  "characteristicSpDefense4",
  "memoEgg",
  "memoEggTraded",
  "memoFatefulEgg",
  "memoFatefulEggArrived",
  "eggWatchSoon",
  "eggWatchClose",
  "eggWatchDistant",
  "eggWatchFar",
  "skills",
  "hpLabel",
  "attackLabel",
  "defenseLabel",
  "spAttackLabel",
  "spDefenseLabel",
  "speedLabel",
  "abilityLabel",
  "slashSeparator",
  "hpCurrent",
  "hpMax",
  "attackValue",
  "defenseValue",
  "spAttackValue",
  "spDefenseValue",
  "speedValue",
  "abilityName",
  nil,
  nil,
  "battleMoves",
  nil,
  "moveName0",
  "moveName1",
  "moveName2",
  "moveName3",
  "ppNumber0",
  "ppLabel",
  "ppNumber1",
  "ppNumber2",
  "ppNumber3",
  "ppNumber4",
  "ppNumber5",
  "ppNumber6",
  "ppNumber7",
  "ppNumber8",
  "ppNumber9",
  "ppNumber10",
  "cancelButton",
  "powerLabel",
  "accuracyLabel",
  "categoryLabel",
  "powerValue",
  "accuracyValue",
  "switchButton",
  "dashes",
  "dashesLong",
  nil,
  "hmWarning",
  "performance",
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  "ribbons",
  nil,
  nil,
  "ribbonsCountLabel",
  "ribbonsCount",
  nil,
  nil,
  nil,
  "speedName",
  "powerName",
  "skillName",
  "staminaName",
  "jumpName",
  "shinyLeaf",
  "forgetButton",
  "switchMoveButton",
}

-- Lowers one tokenized message into label text or template segments.
-- Glyph runs become text; control records keep their source color slots,
-- alignment, and substitution roles. Any other source control is
-- malformed input, never a skipped operation.
---@param tokens table[]
---@param bankId integer
---@param index integer
---@return table<string, unknown>|nil record
---@return string|nil alignment
local function lowerMessage(tokens, bankId, index)
  local role = "template:message:" .. bankId .. ":" .. index
  local segments = {}
  local pending = {}
  local alignment = nil
  local function flush()
    if #pending > 0 then
      segments[#segments + 1] = { kind = "text", value = table.concat(pending) }
      pending = {}
    end
  end
  for position, token in ipairs(tokens) do
    if token.kind == "eos" then
      break
    elseif token.kind == "glyph" then
      pending[#pending + 1] = token.text
    elseif token.kind == "line_break" then
      flush()
      segments[#segments + 1] = { kind = "lineBreak" }
    elseif token.kind == "prompt_break" then
      flush()
      segments[#segments + 1] = { kind = "lineBreak", flow = "prompt" }
    elseif token.kind == "page_break" then
      flush()
      segments[#segments + 1] = { kind = "lineBreak", flow = "page" }
    elseif token.kind == "substitution" then
      local selection = SummarySources.substitutions[token.control]
      if selection == nil then
        sourceError("summary text carries an unmapped substitution " .. tostring(token.control), {
          role = role,
          bank = bankId,
          index = index,
          control = token.control,
        })
      end
      assert(selection ~= nil, "unmapped substitutions fail above")
      flush()
      local field = 0
      if token.args ~= nil and token.args[1] ~= nil then
        field = token.args[1]
      end
      segments[#segments + 1] = { kind = selection.role, field = field }
    elseif token.kind == "style" then
      if token.control == 0xFF00 and token.args ~= nil and #token.args == 1 then
        flush()
        segments[#segments + 1] = { kind = "color", color = token.args[1] }
      else
        sourceError("summary text carries an unsupported style " .. tostring(token.control), {
          role = role,
          bank = bankId,
          index = index,
        })
      end
    elseif token.kind == "unsupported_control" and token.control == 0x0205 then
      if position ~= 1 or alignment ~= nil then
        sourceError("summary text carries a misplaced alignment control", { role = role, bank = bankId, index = index })
      end
      alignment = "center"
    else
      sourceError("summary text carries an unsupported token " .. tostring(token.kind), {
        role = role,
        bank = bankId,
        index = index,
        kind = token.kind,
        control = token.control,
      })
    end
  end
  flush()
  if #segments == 0 then
    return nil, nil
  end
  if #segments == 1 and segments[1].kind == "text" and alignment == nil then
    return { label = segments[1].value }, nil
  end
  return { template = { segments = segments, alignment = alignment } }, alignment
end

local function readMessageBank(archive, bankId, role, dependencies)
  local bytes, err = archive:readMember(bankId)
  if not bytes then
    sourceError("message bank " .. bankId .. " is unreadable: " .. Errors.format(err), { role = role, bank = bankId })
  end
  assert(bytes ~= nil, "unreadable message banks fail above")
  dependencies[#dependencies + 1] = { name = "messages:member:" .. bankId, role = role, sha1 = Hashing.sha1hex(bytes) }
  local bank, bankErr = FieldMessageBank.decode(bytes, { label = "summary-message-bank-" .. bankId })
  if not bank then
    assert(bankErr)
    sourceError("message bank " .. bankId .. " does not decode: " .. bankErr.message, {
      role = role,
      bank = bankId,
      cause = bankErr.code,
    })
  end
  return bank
end

local function tokenizeBank(bank, bankId, role)
  ---@type table[][] one token stream per bank message
  local tokens = {}
  for index = 0, #bank.messages - 1 do
    local message = bank.messages[index + 1]
    local stream, err = FieldMessageTokenizer.tokenize(message.raw, charmap, { bankId = bankId, messageId = index })
    if not stream then
      assert(err)
      sourceError("summary message does not tokenize: " .. err.message, { role = role, bank = bankId, index = index })
    end
    assert(stream ~= nil, "untokenizable summary messages fail above")
    tokens[index + 1] = stream
  end
  return tokens
end

local function isBlankRecord(record)
  if record.label ~= nil then
    return record.label:match("^%s*$") ~= nil
  end
  local template = record.template
  if template == nil then
    return true
  end
  for _, segment in ipairs(template.segments) do
    if segment.kind == "text" then
      if segment.value:match("%S") ~= nil then
        return false
      end
    else
      return false
    end
  end
  return true
end

local function compileSummaryText(messageArchive, dependencies)
  local bank = readMessageBank(messageArchive, SummarySources.textBanks.summary, "message-bank-302", dependencies)
  local tokens = tokenizeBank(bank, SummarySources.textBanks.summary, "message-bank-302")
  if SUMMARY_NAMES[#tokens + 1] ~= nil then
    sourceError("the summary bank carries an unexpected message census", { messages = #tokens })
  end
  local labels, templates = {}, {}
  for index, stream in ipairs(tokens) do
    local name = SUMMARY_NAMES[index]
    local record, _ = lowerMessage(stream, SummarySources.textBanks.summary, index - 1)
    if record == nil or isBlankRecord(record) then
      if name ~= nil then
        sourceError("the named summary message carries no text", { name = name, index = index - 1 })
      end
    elseif name == nil then
      sourceError("the summary bank carries an unnamed text message", { index = index - 1 })
    elseif record.label ~= nil then
      labels[name] = record.label
    elseif record.template ~= nil then
      templates[name] = record.template
    end
  end
  return { labels = labels, templates = templates, count = #tokens }
end

local function joinDisplayText(record, what)
  if record == nil then
    sourceError(what .. " carries no text", {})
  end
  assert(record ~= nil, "missing text fails above")
  if record.label ~= nil then
    return record.label
  end
  if record.template == nil then
    sourceError(what .. " carries no text", {})
  end
  assert(record.template ~= nil, "missing text fails above")
  local parts = {}
  for _, segment in ipairs(record.template.segments) do
    if segment.kind == "text" then
      parts[#parts + 1] = segment.value
    elseif segment.kind == "lineBreak" and segment.flow == nil then
      parts[#parts + 1] = "\n"
    else
      sourceError(what .. " carries a non-display segment", { kind = segment.kind })
    end
  end
  return table.concat(parts)
end

local function compileRibbonText(messageArchive, dependencies)
  local bankId = SummarySources.textBanks.ribbons
  local bank = readMessageBank(messageArchive, bankId, "message-bank-424", dependencies)
  local tokens = tokenizeBank(bank, bankId, "message-bank-424")
  local labels = {}
  for _, entry in ipairs(SummarySources.ribbons) do
    local stream = tokens[entry.name + 1]
    if stream == nil then
      sourceError("the ribbon bank carries no name message", { ribbon = entry.key, index = entry.name })
    end
    assert(stream ~= nil, "missing ribbon names fail above")
    local record, _ = lowerMessage(stream, bankId, entry.name)
    labels["ribbonName_" .. entry.key] = joinDisplayText(record, "the ribbon name")
    if entry.description ~= nil then
      local descriptionStream = tokens[entry.description + 1]
      if descriptionStream == nil then
        sourceError("the ribbon bank carries no description message", { ribbon = entry.key })
      end
      assert(descriptionStream ~= nil, "missing ribbon descriptions fail above")
      local description, _ = lowerMessage(descriptionStream, bankId, entry.description)
      labels["ribbonDescription_" .. entry.key] = joinDisplayText(description, "the ribbon description")
    else
      local fallback = tokens[SummarySources.ribbonSpecials.base + 1]
      if fallback == nil then
        sourceError("the ribbon bank carries no special base message", {})
      end
      assert(fallback ~= nil, "missing special base messages fail above")
      local description, _ = lowerMessage(fallback, bankId, SummarySources.ribbonSpecials.base)
      labels["ribbonDescription_" .. entry.key] = joinDisplayText(description, "the ribbon special base")
    end
  end
  return labels
end

local function compileMonthText(messageArchive, dependencies)
  local bankId = SummarySources.textBanks.months
  local bank = readMessageBank(messageArchive, bankId, "message-bank-239", dependencies)
  local tokens = tokenizeBank(bank, bankId, "message-bank-239")
  if #tokens ~= 12 then
    sourceError("the month bank carries an unexpected message census", { messages = #tokens })
  end
  local months = {}
  for index, stream in ipairs(tokens) do
    local record, _ = lowerMessage(stream, bankId, index - 1)
    months[index] = joinDisplayText(record, "the month bank")
  end
  return months
end

local function compileLandmarkText(messageArchive, dependencies)
  local groups = {
    { bank = SummarySources.textBanks.landmarks, role = "landmark-bank-279", prefix = "landmarkNormal" },
    { bank = SummarySources.textBanks.giftLandmarks, role = "landmark-bank-281", prefix = "landmarkGift" },
    { bank = SummarySources.textBanks.externalLandmarks, role = "landmark-bank-280", prefix = "landmarkExternal" },
  }
  local landmarks = {}
  for _, group in ipairs(groups) do
    local bank = readMessageBank(messageArchive, group.bank, group.role, dependencies)
    local tokens = tokenizeBank(bank, group.bank, group.role)
    local names, list = {}, {}
    for index, stream in ipairs(tokens) do
      local record, _ = lowerMessage(stream, group.bank, index - 1)
      local name = group.prefix .. "_" .. (index - 1)
      names[#names + 1] = name
      list[#list + 1] = joinDisplayText(record, group.role)
    end
    landmarks[group.prefix] = { names = names, list = list }
  end
  return landmarks
end

local function compileGroups()
  local groups = {}
  for _, name in ipairs({ "info", "skills", "performance" }) do
    local selection = SummarySources.groupMaps[name]
    if name == "performance" then
      groups[name] = {
        main = { map = selection.main, locked = selection.lockedMain },
        sub = { normal = selection.sub },
      }
    else
      groups[name] = {
        main = { map = selection.main },
        sub = {
          normal = selection.sub,
          restricted = selection.restricted,
          noPerformance = selection.performanceExcludedSub,
        },
      }
    end
  end
  return groups
end

local function compileWindows()
  local windows = {}
  local subCount, mainCount = 0, 0
  for _, row in ipairs(SummarySources.windows) do
    local name = nil
    if row.bg == "bg4" then
      subCount = subCount + 1
      name = string.format("sub%02d", subCount)
    elseif row.bg == "bg1" then
      mainCount = mainCount + 1
      name = string.format("main%02d", mainCount)
    else
      sourceError("the window template names no background engine", { bg = row.bg })
    end
    assert(name ~= nil, "unnamed window engines fail above")
    windows[name] = {
      pane = row.bg == "bg4" and "sub" or "main",
      rect = { x = row.x * 8, y = row.y * 8, width = row.width * 8, height = row.height * 8 },
      palette = row.palette,
    }
  end
  return windows
end

-- Resolves the producer window-text role slots to RGBA role tables while
-- the background palette is available. Records carry detached byte
-- channels, never palette indices. Text prints over filled windows and
-- realized chrome, so the background class stays transparent in the
-- flattened runtime compositor while foreground and shadow stay opaque.
-- Every numeric window palette slot the templates use must bind through
-- the source slot table; a used slot without a binding fails loudly
-- instead of publishing an unresolvable family.
local function compileTextRoles(palette, windows)
  local config = SummarySources.textRoles
  local bank = paletteSlice(palette.colors, config.bank, "summary text")
  local function role(slots, name)
    local picked = slots --[[@as integer[] ]]
    if type(picked) ~= "table" or #picked ~= 3 then
      sourceError("the summary text role keeps a foreground/shadow/background triple", { role = name })
    end
    local colors = {}
    for position, slot in ipairs(picked) do
      local color = bank[slot + 1]
      if color == nil then
        sourceError("summary text role slot is unavailable", { role = name, slot = slot })
      end
      assert(color ~= nil, "missing text role entries fail above")
      local alpha = position == 3 and 0 or 255
      colors[position] = { r = color.r, g = color.g, b = color.b, a = alpha }
    end
    return { foreground = colors[1], shadow = colors[2], background = colors[3] }
  end
  local roles = {}
  for name, slots in pairs(config.inks) do
    roles[name] = role(slots, name)
  end
  for slot, ink in pairs(config.windowSlots) do
    if roles[ink] == nil then
      sourceError("the summary window slot binds an unknown ink", { slot = slot, ink = ink })
    end
    roles["slot" .. slot] = roles[ink]
  end
  for _, window in pairs(windows) do
    if roles["slot" .. window.palette] == nil then
      sourceError("the summary window palette slot resolves through no text role", {
        palette = window.palette,
      })
    end
  end
  return roles
end

local function compileBackgrounds(archive, dependencies, assets)
  local charMain = decode(
    "decodeChar",
    readMember(archive, SummarySources.backgrounds.mainChar, "main-char", dependencies),
    "main-char"
  )
  local charSub =
    decode("decodeChar", readMember(archive, SummarySources.backgrounds.subChar, "sub-char", dependencies), "sub-char")
  local palette = decode(
    "decodePalette",
    readMember(archive, SummarySources.backgrounds.palette, "main-palette", dependencies),
    "main-palette"
  )
  local charMove = decode(
    "decodeChar",
    readMember(archive, SummarySources.backgrounds.moveChar, "move-char", dependencies),
    "move-char"
  )
  local visuals = {}
  local seen = {}
  for _, name in ipairs({ "info", "skills", "performance" }) do
    local selection = SummarySources.groupMaps[name]
    local maps = { selection.main, selection.sub }
    if selection.restricted ~= nil then
      maps[#maps + 1] = selection.restricted
    end
    if selection.lockedMain ~= nil then
      maps[#maps + 1] = selection.lockedMain
    end
    if selection.performanceExcludedSub ~= nil then
      maps[#maps + 1] = selection.performanceExcludedSub
    end
    for _, map in ipairs(maps) do
      if seen[map] == nil then
        seen[map] = true
        local screen =
          decode("decodeScreen", readMember(archive, map, "backdrop-" .. map, dependencies), "backdrop-" .. map)
        local image = nil
        if map == selection.main or (name == "performance" and map == selection.lockedMain) then
          image = rasterizeScreen(charMain, palette.colors, screen, "backdrop-" .. map)
        else
          image = rasterizeScreen(charSub, palette.colors, screen, "backdrop-" .. map)
        end
        local path = SummaryCache.assetDir() .. "/backdrop-" .. map .. ".png"
        visuals["backdrop" .. map] = writePng(image, path, assets)
      end
    end
  end
  local backing = decode(
    "decodeScreen",
    readMember(archive, SummarySources.backgrounds.moveBacking, "move-backing", dependencies),
    "move-backing"
  )
  local backingImage = rasterizeScreen(charMove, palette.colors, backing, "move-backing")
  visuals.moveBacking = writePng(backingImage, SummaryCache.assetDir() .. "/move-backing.png", assets)
  return visuals, palette, charMain, charSub
end

local function compileStamps(archive, charSub, paletteColors, dependencies, assets)
  local visuals = {}
  for _, stamp in ipairs(SummarySources.stamps) do
    local screen = decode(
      "decodeScreen",
      readMember(archive, stamp.member, "stamp-" .. stamp.member, dependencies),
      "stamp-" .. stamp.member
    )
    local columns, rows = stamp.width / 8, stamp.height / 8
    if screen.width / 8 < columns or screen.height / 8 < rows then
      sourceError("the stamp fragment escapes its screen", { member = stamp.member })
    end
    local entries = {}
    for row = 0, rows - 1 do
      for column = 0, columns - 1 do
        entries[#entries + 1] = screen.entries[row * (screen.width / 8) + column + 1]
      end
    end
    local cropped = { width = stamp.width, height = stamp.height, entries = entries }
    local image = rasterizeScreen(charSub, paletteColors, cropped, "stamp-" .. stamp.member)
    visuals["stamp" .. stamp.member] =
      writePng(image, SummaryCache.assetDir() .. "/stamp-" .. stamp.member .. ".png", assets)
  end
  return visuals
end

local function opaquePixelCount(rgba)
  local count = 0
  for offset = 4, #rgba, 4 do
    if string.byte(rgba, offset) ~= 0 then
      count = count + 1
    end
  end
  return count
end

local function compileRibbonArt(sharedArchive, dependencies, assets)
  local paletteMember = readMember(sharedArchive, 136, "ribbon-palette", dependencies, "shared")
  local paletteData = decode("decodePalette", paletteMember, "ribbon-palette")
  local visuals = {}
  for _, entry in ipairs(SummarySources.ribbons) do
    local charMember = readMember(sharedArchive, entry.art, "ribbon-" .. entry.key, dependencies, "shared")
    local charData = decode("decodeChar", charMember, "ribbon-" .. entry.key)
    if charData.depth ~= 3 then
      sourceError("ribbon art is not 4bpp", { ribbon = entry.key, depth = charData.depth })
    end
    if math.floor(#charData.tiles / 32) ~= 16 then
      sourceError("ribbon art carries an unexpected tile census", { ribbon = entry.key, tiles = #charData.tiles / 32 })
    end
    local bank = paletteSlice(paletteData.colors, entry.palette, "ribbon " .. entry.key)
    local entries = {}
    for tile = 0, 15 do
      entries[#entries + 1] = { tile = tile, flipH = false, flipV = false, palette = 0 }
    end
    local screen = { width = 32, height = 32, entries = entries }
    local image = rasterizeScreen(charData, bank, screen, "ribbon-" .. entry.key)
    if opaquePixelCount(image.pixels) == 0 then
      sourceError("ribbon art addresses no visible pixels", { ribbon = entry.key })
    end
    local path = SummaryCache.assetDir() .. "/ribbon-" .. entry.key .. ".png"
    visuals[entry.key] = writePng(image, path, assets)
  end
  return visuals
end

-- Lowers one gauge run to its empty/full track strips plus the 8-pixel
-- tiles the runtime composes partial fill from. The strips rasterize the
-- exact source tiles (empty tile repeated across the track, full tile
-- repeated across the track), never redrawn pixels: the empty strip is
-- what the source draws at zero fill and the full strip is what it draws
-- at full fill. Colors resolve the state ink slots of the run's palette
-- bank; the health rule carries its threshold inks while the experience
-- rule repeats its single blue ink across all three state keys.
local function barRunTiles(charData, bank, base, columns, role)
  local tileCount = math.floor(#charData.tiles / 32)
  if base < 0 or base + 8 >= tileCount then
    sourceError(role .. " tile run escapes its character block", { base = base, tiles = tileCount })
  end
  local function strip(tile, width, name)
    local entries = {}
    for _ = 1, width do
      entries[#entries + 1] = { tile = tile, flipH = false, flipV = false, palette = 0 }
    end
    return rasterizeScreen(charData, bank, { width = width * 8, height = 8, entries = entries }, name)
  end
  return strip(base, columns, role .. "-empty"),
    strip(base + 8, columns, role .. "-full"),
    strip(base, 1, role .. "-tile-empty"),
    strip(base + 8, 1, role .. "-tile-full")
end

local function bankInk(palette, bank, slot, role)
  local slice = paletteSlice(palette.colors, bank, role)
  local color = slice[slot + 1]
  if color == nil then
    sourceError(role .. " ink slot is unavailable", { bank = bank, slot = slot })
  end
  assert(color ~= nil, "missing bar inks fail above")
  return { r = color.r, g = color.g, b = color.b }
end

local function compileBars(charMain, charSub, palette, assets)
  local specs = SummarySources.bars
  if type(specs) ~= "table" or type(specs.hp) ~= "table" or type(specs.exp) ~= "table" then
    sourceError("the bar rule selection carries no health and experience tracks", {})
  end
  local blocks = { mainChar = charMain, subChar = charSub }
  local visuals = {}
  local bars = {}
  local function compileRule(name, tileName)
    local spec = specs[name]
    local charData = blocks[spec.charBlock]
    if charData == nil then
      sourceError("the " .. name .. " track names no decoded character block", { block = spec.charBlock })
    end
    assert(charData ~= nil, "missing bar character blocks fail above")
    local memberId = SummarySources.backgrounds[spec.charBlock]
    local bank = paletteSlice(palette.colors, spec.paletteBank, name .. " bar")
    local runs = assert(spec.runs, "the " .. name .. " track carries its tile runs")
    local emptyBase = name == "hp" and assert(runs.high, "the health track carries its high run")
      or assert(runs.fill, "the experience track carries its fill run")
    local emptyImage, fullImage, emptyTile, fullTile =
      barRunTiles(charData, bank, emptyBase, spec.columns, name .. " bar")
    if opaquePixelCount(emptyImage.pixels) == 0 then
      sourceError("the " .. name .. " empty track addresses no visible pixels", { member = memberId })
    end
    if opaquePixelCount(fullImage.pixels) == 0 then
      sourceError("the " .. name .. " full track addresses no visible pixels", { member = memberId })
    end
    local dir = SummaryCache.assetDir()
    visuals[tileName .. "-empty"] = writePng(emptyTile, dir .. "/" .. tileName .. "-empty.png", assets)
    visuals[tileName .. "-full"] = writePng(fullTile, dir .. "/" .. tileName .. "-full.png", assets)
    local colors = nil
    if name == "hp" then
      colors = {
        high = bankInk(palette, spec.paletteBank, spec.inkSlots.high, "healthy"),
        low = bankInk(palette, spec.paletteBank, spec.inkSlots.low, "weakened"),
        critical = bankInk(palette, spec.paletteBank, spec.inkSlots.critical, "critical"),
      }
    else
      local fill = bankInk(palette, spec.paletteBank, spec.inkSlots.fill, "experience")
      colors = {
        high = { r = fill.r, g = fill.g, b = fill.b },
        low = { r = fill.r, g = fill.g, b = fill.b },
        critical = { r = fill.r, g = fill.g, b = fill.b },
      }
    end
    bars[name] = {
      length = spec.length,
      colors = colors,
      empty = writePng(emptyImage, dir .. "/" .. tileName .. "-track-empty.png", assets),
      full = writePng(fullImage, dir .. "/" .. tileName .. "-track-full.png", assets),
    }
  end
  compileRule("hp", "hp")
  compileRule("exp", "exp")
  return visuals, bars
end

-- Lowers the transcribed touch inventory to the runtime hitbox set. Keys
-- and rects transfer verbatim in source order; blank-cell eligibility
-- stays representable because rows and cells remain separate boxes for
-- the consumer to qualify against its facts.
local function compileTouch()
  local touch = {}
  for position, entry in ipairs(SummarySources.touch) do
    if type(entry.key) ~= "string" or entry.key == "" then
      sourceError("the touch inventory carries an unnamed entry", { position = position })
    end
    if touch[entry.key] ~= nil then
      sourceError("the touch inventory carries a duplicate key", { key = entry.key })
    end
    for _, edge in ipairs({ "top", "bottom", "left", "right" }) do
      if type(entry[edge]) ~= "number" or entry[edge] % 1 ~= 0 then
        sourceError("the touch entry carries a non-integral edge", { key = entry.key, edge = edge })
      end
    end
    touch[entry.key] = { top = entry.top, bottom = entry.bottom, left = entry.left, right = entry.right }
  end
  if next(touch) == nil then
    sourceError("the touch inventory compiles to no hitbox", {})
  end
  return touch
end

local function pictureSelections(catalog)
  local selections = {}
  for speciesKey in pairs(catalog.species) do
    if speciesKey ~= "EGG" and speciesKey ~= "BAD_EGG" and speciesKey ~= "NONE" then
      local speciesId = MonSources.speciesId(speciesKey)
      if speciesId == nil then
        sourceError("the catalog carries an unknown species", { species = speciesKey })
      end
      assert(speciesId ~= nil, "unknown catalog species fail above")
      selections[#selections + 1] = { key = speciesKey, species = speciesId }
    end
  end
  selections[#selections + 1] = { key = "EGG", egg = true, form = 0 }
  selections[#selections + 1] = { key = "EGG/f1", egg = true, form = 1 }
  table.sort(selections, function(a, b)
    return a.key < b.key
  end)
  return selections
end

local function representativePortrait(portraitManifest, speciesKey)
  if type(portraitManifest) ~= "table" or type(portraitManifest.entries) ~= "table" then
    sourceError("the portrait manifest carries no entries", {})
  end
  local entries = portraitManifest.entries
  local direct = entries[speciesKey .. "/f0/male/plain"] ~= nil
  if direct then
    return speciesKey .. "/f0/male/plain"
  end
  if entries[speciesKey .. "/f0/female/plain"] ~= nil then
    return speciesKey .. "/f0/female/plain"
  end
  local fallback = nil
  for selector in pairs(entries) do
    if selector:sub(1, #speciesKey + 1) == speciesKey .. "/" then
      if fallback == nil or selector < fallback then
        fallback = selector
      end
    end
  end
  if fallback == nil then
    sourceError("the portrait manifest carries no portrait", { species = speciesKey })
  end
  assert(fallback ~= nil, "missing portraits fail above")
  return fallback
end

local function writeEggVisual(romFs, form, dependencies, assets)
  local eggId = MonSources.speciesId("EGG")
  if eggId == nil then
    sourceError("the mon sources carry no egg species", {})
  end
  assert(eggId ~= nil, "missing egg species fail above")
  local frames, err = MonPresentationCompiler.compileFrontFrames(romFs, eggId, form, "male", false)
  if frames == nil then
    assert(err)
    sourceError("egg art does not decode: " .. err.message, { form = form, cause = err.code })
  end
  assert(frames ~= nil, "undecodable egg art fails above")
  local rgba = frames.frames[1]
  if type(rgba) ~= "string" or #rgba ~= 80 * 80 * 4 then
    sourceError("egg art has an unexpected shape", { form = form, bytes = type(rgba) == "string" and #rgba or 0 })
  end
  if opaquePixelCount(rgba) == 0 then
    sourceError("egg art addresses no visible pixels", { form = form })
  end
  dependencies[#dependencies + 1] = { name = "egg:front:" .. form, role = "egg art" }
  local path = SummaryCache.assetDir() .. "/egg-f" .. form .. ".png"
  assets[path] = PngWriter.encode(80, 80, rgba)
  return { image = path, width = 80, height = 80 }
end

local function compilePictures(romFs, catalog, portraitManifest, dependencies, assets)
  local selections = pictureSelections(catalog)
  local compiled, err = SummaryPictureCompiler.compile(romFs, selections)
  if compiled == nil then
    assert(err)
    sourceError("picture timelines do not compile: " .. Errors.format(err), {})
  end
  assert(compiled ~= nil, "uncompilable picture timelines fail above")
  for _, dependency in ipairs(compiled.dependencies) do
    dependencies[#dependencies + 1] = dependency
  end
  local pictures = {}
  for _, selection in ipairs(selections) do
    local track = compiled.tracks[selection.key]
    if track == nil then
      sourceError("the picture closure drops its selection", { key = selection.key })
    end
    assert(track ~= nil, "dropped picture selections fail above")
    if selection.egg == true then
      local visual = writeEggVisual(romFs, selection.form, dependencies, assets)
      pictures[selection.key] = {
        visual = visual.image,
        cryDelayTicks = track.cryDelayTicks,
        samples = track.samples,
        placement = track.placement,
      }
      if track.terminal ~= nil then
        pictures[selection.key].terminal = track.terminal
      else
        pictures[selection.key].loopFrom = track.loopFrom
      end
    else
      pictures[selection.key] = {
        portrait = representativePortrait(portraitManifest, selection.key),
        cryDelayTicks = track.cryDelayTicks,
        samples = track.samples,
        placement = track.placement,
      }
      if track.terminal ~= nil then
        pictures[selection.key].terminal = track.terminal
      else
        pictures[selection.key].loopFrom = track.loopFrom
      end
    end
    if pictures[selection.key].terminal == nil and pictures[selection.key].loopFrom == nil then
      sourceError("the picture track ends nowhere", { key = selection.key })
    end
  end
  return pictures, compiled.programs
end

local function compileRibbons(ribbonVisuals)
  local entries = {}
  for index, entry in ipairs(SummarySources.ribbons) do
    local visual = ribbonVisuals[entry.key]
    if visual == nil then
      sourceError("ribbon art is missing its visual", { ribbon = entry.key })
    end
    assert(visual ~= nil, "missing ribbon visuals fail above")
    local record = {
      key = entry.key,
      bitGroup = entry.bitGroup,
      bit = entry.bit,
      name = "ribbonName_" .. entry.key,
      description = "ribbonDescription_" .. entry.key,
      art = { image = visual.image, width = visual.width, height = visual.height, palette = entry.palette },
    }
    -- Special slots arrive zero-based from the source description table
    -- while the display context is a one-based slot array, so the entry
    -- carries the normalized index the consumer resolves directly. The raw
    -- source slots stay visible under descriptionChoices for bank math.
    if entry.special ~= nil then
      if type(entry.special) ~= "number" or entry.special % 1 ~= 0 or entry.special < 0 or entry.special > 13 then
        sourceError("the special ribbon slot is outside the context array", { ribbon = entry.key })
      end
      record.special = entry.special + 1
    end
    entries[index] = record
  end
  local initial = {}
  for _ = 1, 14 do
    initial[#initial + 1] = 0
  end
  return {
    entries = entries,
    initialSpecialDescriptions = initial,
    descriptionChoices = { base = SummarySources.ribbonSpecials.base, slots = SummarySources.ribbonSpecials.slots },
  }
end

local function compilePerformance(performanceArchive, catalog, dependencies)
  local forms = {}
  local names = {}
  for speciesKey, species in pairs(catalog.species) do
    if
      speciesKey ~= "EGG"
      and speciesKey ~= "BAD_EGG"
      and speciesKey ~= "NONE"
      and type(species) == "table"
      and type(species.forms) == "table"
    then
      local speciesId = MonSources.speciesId(speciesKey)
      if speciesId == nil or SummarySources.performanceArcIdxs[speciesId + 1] == nil then
        sourceError("performance covers no species", { species = speciesKey })
      end
      assert(speciesId ~= nil, "unknown catalog species fail above")
      local baseMember = SummarySources.performanceArcIdxs[speciesId + 1]
      for formId in pairs(species.forms) do
        if type(formId) ~= "number" or formId % 1 ~= 0 or formId < 0 then
          sourceError("performance covers no form", { species = speciesKey, form = formId })
        end
        local memberId = baseMember + formId
        local member =
          readMember(performanceArchive, memberId, "performance " .. speciesKey, dependencies, "performance")
        if #member ~= 20 then
          sourceError("the performance record has an unexpected size", { species = speciesKey, bytes = #member })
        end
        local bytes = { string.byte(member, 1, 20) }
        local rows = {}
        local named = { power = bytes[1], stamina = bytes[2], jump = bytes[3], skill = bytes[4], speed = bytes[5] }
        local bounds = {
          power = { lo = bytes[10], hi = bytes[11] },
          stamina = { lo = bytes[12], hi = bytes[13] },
          jump = { lo = bytes[14], hi = bytes[15] },
          skill = { lo = bytes[16], hi = bytes[17] },
          speed = { lo = bytes[18], hi = bytes[19] },
        }
        for _, stat in ipairs({ "power", "stamina", "skill", "jump", "speed" }) do
          local bound = bounds[stat]
          if not (bound.lo <= named[stat] and named[stat] <= bound.hi) then
            sourceError("the performance record breaks its bounds", { species = speciesKey, stat = stat })
          end
          rows[stat] = { base = named[stat], lo = bound.lo, hi = bound.hi }
        end
        local key = speciesKey .. "/f" .. formId
        forms[key] = rows
        names[#names + 1] = key
      end
    end
  end
  table.sort(names)
  local ordered = {}
  for _, key in ipairs(names) do
    ordered[key] = forms[key]
  end
  local modifiers = {}
  for _, row in ipairs(SummarySources.performanceNatureMods) do
    modifiers[#modifiers + 1] = { power = row[1], skill = row[2], speed = row[3], jump = row[4], stamina = row[5] }
  end
  return {
    forms = ordered,
    natureModifiers = modifiers,
    zeroAprijuice = { power = 0, stamina = 0, skill = 0, jump = 0, speed = 0 },
  }
end

local function compileDexNumbers(dexArchive, catalog, dependencies)
  local member = readMember(dexArchive, 0, "dex order", dependencies, "dexOrder")
  if #member ~= 494 * 2 then
    sourceError("the dex order has an unexpected size", { bytes = #member })
  end
  local regional = {}
  for species = 0, 493 do
    regional[species] = string.byte(member, species * 2 + 1) + string.byte(member, species * 2 + 2) * 256
  end
  local numbers = {}
  for speciesKey in pairs(catalog.species) do
    if speciesKey ~= "EGG" and speciesKey ~= "BAD_EGG" and speciesKey ~= "NONE" then
      local speciesId = MonSources.speciesId(speciesKey)
      if speciesId == nil or speciesId < 1 or speciesId > 493 then
        sourceError("dex mapping covers no species", { species = speciesKey })
      end
      assert(speciesId ~= nil, "unknown catalog species fail above")
      numbers[speciesKey] = { national = speciesId, regional = regional[speciesId] or 0 }
    end
  end
  return numbers
end

local function templateNameByMsgId(count)
  local names = {}
  for index = 1, count do
    local name = SUMMARY_NAMES[index]
    if name ~= nil then
      names[index - 1] = name
    end
  end
  if SUMMARY_NAMES[count + 1] ~= nil then
    sourceError("the summary names carry an unexpected message census", { messages = count })
  end
  return names
end

-- Substitution segment kinds the branch headers skip: the consumer binds
-- slot values through its own date block, so a header label carries only
-- the template's static text runs verbatim. Color controls are skipped for
-- the same reason; the full runs stay available under text.templates.
local HEADER_SKIPPED_SEGMENTS = {
  species = true,
  nickname = true,
  otName = true,
  landmark = true,
  ability = true,
  move = true,
  item = true,
  month = true,
  number = true,
  idNumber = true,
  expToNext = true,
  expPoints = true,
  color = true,
}

-- Renders one compiled template as its branch-header label: static text
-- preserved exactly, plain line breaks kept, bound slots and colors left
-- to the template and the consumer. Anything else is malformed input,
-- never a silently dropped operation.
---@param name string
---@param template table<string, unknown>
---@return string
local function headerText(name, template)
  local segments = assert(template.segments, "memo headers carry segments")
  assert(type(segments) == "table", "memo header segments are an array")
  local parts = {}
  for _, segment in ipairs(segments) do
    assert(type(segment) == "table", "memo header segments are records")
    if segment.kind == "text" then
      assert(type(segment.value) == "string", "memo header text carries its wording")
      parts[#parts + 1] = segment.value
    elseif segment.kind == "lineBreak" then
      if segment.flow ~= nil then
        sourceError("the memo header carries a paged break", { name = name, flow = segment.flow })
      end
      parts[#parts + 1] = "\n"
    elseif HEADER_SKIPPED_SEGMENTS[segment.kind] == true then
      -- Bound through the template or the consumer date block; no label text.
    else
      sourceError("the memo header carries an unsupported segment", { name = name, kind = segment.kind })
    end
  end
  local joined = table.concat(parts)
  if joined == "" then
    sourceError("the memo header carries no display text", { name = name })
  end
  return joined
end

-- Publishes a plain header label for every memo condition template plus
-- the flavor and egg-watch templates, which likewise carry color or break
-- controls the label shape cannot hold. Messages that already lower to
-- plain labels need no header. Labels are exact static runs, never
-- paraphrases; slot values resolve through the templates.
---@param summaryText { labels: table<string, string>, templates: table<string, unknown>, count: integer }
---@return table<string, string>
local function compileHeaderLabels(summaryText)
  local namesByMsg = templateNameByMsgId(summaryText.count)
  local wanted = {}
  local function want(msgId)
    local name = namesByMsg[msgId]
    if name == nil then
      sourceError("the memo header selects no named template", { index = msgId })
    end
    assert(name ~= nil, "missing header templates fail above")
    wanted[#wanted + 1] = name
  end
  for _, source in ipairs(SummarySources.memoConditions) do
    want(source.template)
  end
  for _, msgId in ipairs(SummarySources.memoFlavors.byFlavor) do
    want(msgId)
  end
  for _, msgId in ipairs(SummarySources.memoEggWatch.templates) do
    want(msgId)
  end
  local headers = {}
  for _, name in ipairs(wanted) do
    if summaryText.labels[name] == nil and headers[name] == nil then
      local template = summaryText.templates[name]
      if template == nil then
        sourceError("the memo header has no compiled template", { name = name })
      end
      assert(template ~= nil, "missing header templates fail above")
      headers[name] = headerText(name, template)
    end
  end
  return headers
end

-- Resolves packed locations to their landmark labels the way the source
-- landmark reader does: normal ids read the normal bank directly, gift
-- and external ids read their own banks, and anything unmapped reads the
-- source out-of-range fallback (external bank message 2). The consumer
-- gift range keys the gift bank in source order beside the packed ids.
---@param landmarks table<string, { names: string[], list: string[] }>
---@return table<string, unknown>
local function compileLandmarkMaps(landmarks)
  local bases = SummarySources.memoLocationBases
  local normal = assert(landmarks.landmarkNormal, "the landmark closure carries the normal bank")
  local gift = assert(landmarks.landmarkGift, "the landmark closure carries the gift bank")
  local external = assert(landmarks.landmarkExternal, "the landmark closure carries the external bank")
  local wildByLocation = {}
  for position, name in ipairs(normal.names) do
    wildByLocation[bases.normal + position - 1] = name
  end
  local giftByLocation = {}
  for offset, name in ipairs(gift.names) do
    giftByLocation[4000 + offset - 1] = name
    wildByLocation[bases.gift + offset - 1] = name
  end
  for offset, name in ipairs(external.names) do
    wildByLocation[bases.external + offset - 1] = name
  end
  local fallback = external.names[3]
  if type(fallback) ~= "string" or fallback == "" then
    sourceError("the external bank carries no out-of-range fallback", {})
  end
  assert(type(fallback) == "string" and fallback ~= "", "missing landmark fallbacks fail above")
  return { wildByLocation = wildByLocation, giftByLocation = giftByLocation, fallback = fallback }
end

local function compileMemo(summaryText, months, landmarks)
  local namesByMsg = templateNameByMsgId(summaryText.count)
  local compiled = {}
  for _, source in ipairs(SummarySources.memoConditions) do
    local name = namesByMsg[source.template]
    if name == nil then
      sourceError("the memo condition selects no named template", { key = source.key, index = source.template })
    end
    assert(name ~= nil, "missing memo templates fail above")
    compiled[source.key] = {
      template = name,
      nature = source.nature,
      date = source.date,
      characteristic = source.characteristic,
      flavor = source.flavor,
      eggWatch = source.eggWatch,
    }
  end
  local statNames = { "Hp", "Attack", "Defense", "Speed", "SpAttack", "SpDefense" }
  local characteristics = {}
  for stat = 1, 6 do
    characteristics[stat] = {}
    for mod = 0, 4 do
      characteristics[stat][mod + 1] = "characteristic" .. statNames[stat] .. mod
    end
  end
  local flavorNames = { "flavorSpicy", "flavorDry", "flavorSweet", "flavorBitter", "flavorSour" }
  local flavors = { default = "characteristicBase", byFlavor = flavorNames }
  local eggWatchNames = { "eggWatchSoon", "eggWatchClose", "eggWatchDistant", "eggWatchFar" }
  local eggWatch = { thresholds = SummarySources.memoEggWatch.thresholds, templates = eggWatchNames }
  local monthNames = {}
  for index in ipairs(months) do
    monthNames[index] = "month" .. string.format("%02d", index)
  end
  return {
    conditions = compiled,
    months = monthNames,
    landmarks = compileLandmarkMaps(landmarks),
    characteristics = characteristics,
    flavors = flavors,
    eggWatch = eggWatch,
  }
end

local function _compile(romFs, catalog, portraitManifest)
  if
    romFs == nil
    or type(romFs.metadata) ~= "function"
    or type(romFs.openNarc) ~= "function"
    or type(romFs.resolvedNarc) ~= "function"
  then
    sourceError("summary compilation requires source metadata and archive reader", {})
  end
  if type(catalog) ~= "table" or type(catalog.species) ~= "table" then
    sourceError("summary compilation requires the mon catalog", {})
  end
  local metadata = romFs:metadata()
  assert(type(metadata) == "table" and type(metadata.sha1) == "string", "summary source metadata must carry sha1")
  local dependencies = {
    { name = "assetContract", sha1 = SummaryCache.FORMAT .. ":" .. SummaryCache.SCHEMA },
  }
  local archive = openArchive(romFs, SummarySources.archives.ui.symbol, "summary ui")
  if archive:memberCount() ~= SummarySources.archives.ui.members then
    sourceError("the summary archive carries an unexpected member census", { members = archive:memberCount() })
  end
  local sharedArchive = openArchive(romFs, SummarySources.archives.shared.symbol, "shared graphics")
  local messageArchive = openArchive(romFs, SummarySources.archives.messages.symbol, "messages")
  local performanceArchive = openArchive(romFs, SummarySources.archives.performance.symbol, "performance")
  local dexArchive = openArchive(romFs, SummarySources.archives.dexOrder.symbol, "dex order")
  local assets = {}
  local groups = compileGroups()
  local windows = compileWindows()
  local backdropVisuals, palette, charMain, charBlocksSub = compileBackgrounds(archive, dependencies, assets)
  local charSub =
    decode("decodeChar", readMember(archive, SummarySources.backgrounds.subChar, "sub-char", dependencies), "sub-char")
  local stampVisuals = compileStamps(archive, charSub, palette.colors, dependencies, assets)
  local ribbonVisuals = compileRibbonArt(sharedArchive, dependencies, assets)
  local barVisuals, bars = compileBars(charMain, charBlocksSub, palette, assets)
  local visuals = {}
  for name, visual in pairs(backdropVisuals) do
    visuals[name] = visual
  end
  for name, visual in pairs(barVisuals) do
    visuals[name] = visual
  end
  for name, visual in pairs(stampVisuals) do
    visuals[name] = visual
  end
  for name, visual in pairs(ribbonVisuals) do
    visuals["ribbonArt_" .. name] = visual
  end
  local summaryText = compileSummaryText(messageArchive, dependencies)
  local ribbonLabels = compileRibbonText(messageArchive, dependencies)
  local months = compileMonthText(messageArchive, dependencies)
  local landmarks = compileLandmarkText(messageArchive, dependencies)
  local labels = {}
  for name, value in pairs(summaryText.labels) do
    labels[name] = value
  end
  for name, value in pairs(ribbonLabels) do
    labels[name] = value
  end
  for index, value in ipairs(months) do
    labels["month" .. string.format("%02d", index)] = value
  end
  for _, group in ipairs({ "landmarkNormal", "landmarkGift", "landmarkExternal" }) do
    local records = landmarks[group]
    for position, value in ipairs(records.list) do
      labels[records.names[position]] = value
    end
  end
  for name, value in pairs(compileHeaderLabels(summaryText)) do
    labels[name] = value
  end
  local text = { labels = labels, templates = summaryText.templates, roles = compileTextRoles(palette, windows) }
  local palettes = { banks = {} }
  for bank = 0, 15 do
    local colors = {}
    for index = 1, 16 do
      local color = palette.colors[bank * 16 + index]
      colors[#colors + 1] = { r = color.r, g = color.g, b = color.b, a = 255 }
    end
    palettes.banks["bg" .. bank] = colors
  end
  local pictures, usedPrograms = compilePictures(romFs, catalog, portraitManifest, dependencies, assets)
  local ribbons = compileRibbons(ribbonVisuals)
  local performance = compilePerformance(performanceArchive, catalog, dependencies)
  local dexNumbers = compileDexNumbers(dexArchive, catalog, dependencies)
  local memo = compileMemo(summaryText, months, landmarks)
  local manifest = {
    schema = SummaryAssetSchema.SCHEMA,
    paneSize = { width = SummaryAssetSchema.PANE_WIDTH, height = SummaryAssetSchema.PANE_HEIGHT },
    groups = groups,
    windows = windows,
    visuals = visuals,
    sprites = {},
    hitboxes = { touch = compileTouch() },
    text = text,
    palettes = palettes,
    bars = bars,
    pictures = pictures,
    ribbons = ribbons,
    performance = performance,
    dexNumbers = dexNumbers,
    memo = memo,
    -- Sounds and transition tracks stay empty by calibration: the
    -- overlay resolves both at its state call sites and no
    -- generated-family consumer reads these sections (see
    -- SummarySources.absences). The closed keys and their shape
    -- validators remain so a future populated section validates.
    sounds = {},
    transitions = {},
  }
  local ok, err = pcall(SummaryAssetSchema.assertManifest, manifest)
  if not ok then
    sourceError("compiled summary manifest is invalid: " .. Errors.format(err), {})
  end
  local dependencyRecord = {
    cacheFormat = SummaryCache.FORMAT,
    schema = SummaryCache.SCHEMA,
    versionRomSha1 = metadata.sha1,
    source = SummarySources.provenance,
    selection = SummarySources,
    dependencies = dependencies,
    closure = { programs = usedPrograms },
  }
  return {
    marker = SummaryCache.marker(metadata.sha1, Hashing.hashLua(dependencyRecord)),
    manifest = manifest,
    dependencies = dependencyRecord,
    assets = assets,
  }
end

---@param romFs RomFs
---@param catalog table<string, unknown>
---@param portraitManifest table<string, unknown>
---@return table<string, unknown>|nil bundle
---@return Errors.Error?
function SummaryAssetCompiler.compile(romFs, catalog, portraitManifest)
  assert(romFs and romFs.read and romFs.openNarc and romFs.resolvedNarc, "compile requires a RomFs-shaped object")
  local ok, result = xpcall(function()
    return _compile(romFs, catalog, portraitManifest)
  end, function(e)
    if Errors.is(e) then
      return e
    end
    return { raw = e, trace = debug.traceback("", 2) }
  end)
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

return SummaryAssetCompiler
