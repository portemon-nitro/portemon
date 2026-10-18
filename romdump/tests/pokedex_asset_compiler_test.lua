-- The Pokedex presentation projection closes every advertised page and
-- registration role before any UI is constructed: a complete manifest
-- validates, every omitted role fails publication, source animation
-- dwell survives normalization while empty loops are rejected, the new
-- indexed front export agrees byte for byte with the existing RGBA
-- export, and Spinda personalization stays in semantic slots with no
-- PID-keyed residue.

local Assert = require("tests.support.Assert")
local MonCache = require("libs.assets.src.MonCache")
local MonSources = require("romdump.src.config.MonSources")

local bit = require("bit")

local T = {}

local function void(_) end

local FRONT_FACING = 2

local function requireProduction()
  local loadedSchema, PokedexAssetSchema = pcall(require, "libs.assets.src.PokedexAssetSchema")
  Assert.isTrue(loadedSchema, "the pokedex asset schema must be published before role closure can be proven")
  return assert(PokedexAssetSchema)
end

local function requireCompiler()
  local loaded, PokedexAssetCompiler = pcall(require, "romdump.src.digest.ui.PokedexAssetCompiler")
  Assert.isTrue(loaded, "the pokedex asset compiler must be published before the presentation projection can be proven")
  return assert(PokedexAssetCompiler)
end

local REQUIRED_PAGES = {
  "cover",
  "grid",
  "results",
  "search.criteria",
  "search.order",
  "search.name",
  "search.type",
  "search.height",
  "search.weight",
  "search.area",
  "search.shape",
  "entry.area",
  "entry.size",
  "entry.forms",
  "entry.compare",
  "entry.return",
  "registration",
}

local function rgba(r, g, b, a)
  return { r = r, g = g, b = b, a = a }
end

local function textBindings()
  return {
    ui = { bankId = 802 },
    entryByLanguage = {
      native = { nameBankId = 237, categoryBankId = 816, flavorBankId = 803 },
      japanese = { nameBankId = 822, categoryBankId = 828, flavorBankId = 810 },
      english = { nameBankId = 817, categoryBankId = 823, flavorBankId = 805 },
      french = { nameBankId = 818, categoryBankId = 824, flavorBankId = 806 },
      german = { nameBankId = 819, categoryBankId = 825, flavorBankId = 807 },
      italian = { nameBankId = 820, categoryBankId = 826, flavorBankId = 808 },
      spanish = { nameBankId = 821, categoryBankId = 827, flavorBankId = 809 },
    },
    measureByProfile = {
      base = { heightBankId = 815, weightBankId = 813 },
      giratina_origin = { heightBankId = 814, weightBankId = 812 },
    },
    registrationAnnouncement = { bankId = 197, messageId = 871 },
  }
end

local function fixtureCatalog()
  return {
    schema = "g4-pokedex-catalog-v1",
    versionId = "heartgold",
    nativeLanguage = "english",
    textBindings = textBindings(),
  }
end

local function spindaRows()
  local rows = {}
  for _ = 1, 80 do
    rows[#rows + 1] = string.rep("0", 79) .. "1"
  end
  return rows
end

local function fixtureManifest(catalog)
  local pages = {}
  for _, role in ipairs(REQUIRED_PAGES) do
    pages[role] = {
      backdrop = { information = rgba(0, 0, 0, 255), controls = rgba(16, 16, 16, 255) },
      backgrounds = {
        information = { { chrome = "panel", layer = 0, x = 0, y = 0, priority = 0, paletteGroup = "panel" } },
        controls = {},
      },
      cells = { "panel-cell" },
      sprites = { "panel-sprite" },
      windows = { "body-window" },
    }
  end
  pages.results.sprites = { "panel-sprite", "pressed-sprite" }
  local pictures = { backYOffset = {} }
  pictures.backYOffset[MonCache.portraitSelector("custom.alpha", 0, "male", false, "back")] = 4
  return {
    schema = "g4-pokedex-assets-v1",
    versionId = "heartgold",
    fonts = { body = 0, header = 4 },
    pages = pages,
    chrome = { panel = { path = "assets/generated/pokedex/panel.png", width = 64, height = 64 } },
    cells = {
      ["panel-cell"] = {
        bounds = { x = 0, y = 0, width = 16, height = 16 },
        parts = {
          {
            chrome = "panel",
            source = { x = 0, y = 0, width = 16, height = 16 },
            x = 0,
            y = 0,
            flipX = false,
            flipY = false,
            priority = 0,
            paletteGroup = "panel",
          },
        },
      },
    },
    animations = {
      ["panel-idle"] = {
        frames = {
          { cell = "panel-cell", duration = 4, offsetX = 0, offsetY = 0, rotation = 0, scaleX = 1, scaleY = 1 },
        },
        loopFrom = 1,
        direction = "forward",
        once = false,
      },
      ["pressed-slider"] = {
        frames = {
          { cell = "panel-cell", duration = 4, offsetX = 4, offsetY = 0, rotation = 0, scaleX = 1, scaleY = 1 },
          { cell = "panel-cell", duration = 0, offsetX = 0, offsetY = 0, rotation = 0, scaleX = 1, scaleY = 1 },
        },
        loopFrom = 1,
        direction = "forward",
        once = false,
      },
    },
    windows = {
      ["body-window"] = {
        pane = "information",
        layer = 0,
        x = 0,
        y = 0,
        width = 128,
        height = 64,
        font = 0,
        foreground = rgba(255, 255, 255, 255),
        shadow = rgba(0, 0, 0, 255),
        background = rgba(0, 0, 0, 0),
        align = "left",
        paletteGroup = "panel",
      },
      ["header-window"] = {
        pane = "information",
        layer = 1,
        x = 0,
        y = 0,
        width = 128,
        height = 16,
        font = 4,
        foreground = rgba(255, 255, 255, 255),
        shadow = rgba(0, 0, 0, 255),
        background = rgba(0, 0, 0, 0),
        align = "center",
        paletteGroup = "panel",
      },
    },
    sprites = {
      ["panel-sprite"] = {
        pane = "information",
        animation = "panel-idle",
        x = 0,
        y = 0,
        priority = 0,
        drawPriority = 0,
        paletteGroup = "panel",
      },
      ["pressed-sprite"] = {
        pane = "information",
        animation = "pressed-slider",
        x = 8,
        y = 8,
        priority = 0,
        drawPriority = 1,
        paletteGroup = "panel",
      },
    },
    pictures = pictures,
    footprints = { ["custom.alpha"] = { chrome = "panel", source = { x = 0, y = 0, width = 16, height = 16 } } },
    areaMaps = {
      johto = {
        role = "map",
        extent = { x = 0, y = 0, width = 256, height = 192 },
        scrollBounds = { x = 0, y = 0, width = 256, height = 192 },
        crop = { x = 56, y = 40, width = 200, height = 136 },
      },
      kanto = {
        role = "map",
        extent = { x = 0, y = 0, width = 256, height = 192 },
        scrollBounds = { x = 0, y = 0, width = 256, height = 192 },
        crop = { x = 56, y = 40, width = 200, height = 136 },
      },
    },
    spinda = {
      eligibility = { male = { frames = { spindaRows(), spindaRows() } } },
      replacementColors = {
        normal = { rgba(255, 0, 0, 255), rgba(0, 255, 0, 255), rgba(0, 0, 255, 255) },
        shiny = { rgba(255, 255, 0, 255), rgba(0, 255, 255, 255), rgba(255, 0, 255, 255) },
      },
      spots = { { x = 1, y = 2 }, { x = 3, y = 4 }, { x = 5, y = 6 }, { x = 7, y = 8 } },
      secondFrameXOffset = -14,
    },
    text = catalog.textBindings,
  }
end

function T.complete_manifest_resolves_every_required_page_role()
  local PokedexAssetSchema = requireProduction()
  local catalog = fixtureCatalog()
  local manifest = fixtureManifest(catalog)
  local record, err = PokedexAssetSchema.validateManifest(manifest, catalog)
  Assert.notNil(record, "the complete manifest must validate")
  Assert.isNil(err, "the complete manifest carries no error")
  for _, role in ipairs(REQUIRED_PAGES) do
    Assert.notNil(record.pages[role], "the validated manifest keeps the " .. role .. " page")
  end
  Assert.equal(
    record.text.registrationAnnouncement.bankId,
    197,
    "the validated manifest keeps the registration announcement binding"
  )
end

function T.missing_cell_header_font_map_and_binding_fail_publication()
  local PokedexAssetSchema = requireProduction()
  local catalog = fixtureCatalog()

  local noCell = fixtureManifest(catalog)
  noCell.cells["panel-cell"] = nil
  Assert.isNil(PokedexAssetSchema.validateManifest(noCell, catalog), "a manifest missing a used cell must not validate")

  local noHeaderFont = fixtureManifest(catalog)
  noHeaderFont.fonts.header = nil
  Assert.isNil(
    PokedexAssetSchema.validateManifest(noHeaderFont, catalog),
    "a manifest missing the header font reference must not validate"
  )

  local noMap = fixtureManifest(catalog)
  noMap.areaMaps.kanto = nil
  Assert.isNil(
    PokedexAssetSchema.validateManifest(noMap, catalog),
    "a manifest missing a regional map must not validate"
  )

  local noBinding = fixtureManifest(catalog)
  noBinding.text = {}
  for key, value in pairs(catalog.textBindings) do
    noBinding.text[key] = value
  end
  noBinding.text.registrationAnnouncement = nil
  local rejected, bindingErr = PokedexAssetSchema.validateManifest(noBinding, catalog)
  Assert.isNil(rejected, "a manifest missing a translated binding must not validate")
  Assert.notNil(bindingErr, "a missing translated binding must carry an error")
end

function T.source_animation_timing_preserves_dwell_and_rejects_empty_loops()
  local PokedexAssetSchema = requireProduction()
  local catalog = fixtureCatalog()
  local manifest = fixtureManifest(catalog)
  local record = assert(PokedexAssetSchema.validateManifest(manifest, catalog))
  local pressed =
    assert(record.animations["pressed-slider"], "the validated manifest keeps the pressed slider sequence")
  Assert.equal(#pressed.frames, 2, "the pressed sequence keeps both authored frames")
  Assert.equal(pressed.frames[1].duration, 4, "the pressed sequence keeps its dwell frame")
  Assert.equal(pressed.frames[2].duration, 0, "the pressed sequence keeps its zero-duration frame")
  Assert.equal(pressed.frames[1].offsetX, 4, "the pressed sequence keeps its source translation transform")
  Assert.equal(pressed.loopFrom, 1, "the pressed sequence keeps its loop index")

  local emptyLoop = fixtureManifest(catalog)
  emptyLoop.animations["pressed-slider"] = {
    frames = {
      { cell = "panel-cell", duration = 0, offsetX = 0, offsetY = 0, rotation = 0, scaleX = 1, scaleY = 1 },
    },
    loopFrom = 1,
    direction = "forward",
    once = false,
  }
  Assert.isNil(PokedexAssetSchema.validateManifest(emptyLoop, catalog), "a reachable zero-only loop must not validate")
end

-- Indexed portrait fixtures: the retail unscan is a 32-bit LCRNG seeded
-- from the first stored word, so the test scans chosen plain nibbles with
-- the algebraic inverse of that recurrence. Relation assertions below
-- never depend on these constants: they compare the two production
-- exports against each other and the shared palette.

local function u16(value)
  value = value % 65536
  return string.char(value % 256, math.floor(value / 256) % 256)
end

local function u32(value)
  value = value % 4294967296
  local b0 = value % 256
  local b1 = math.floor(value / 256) % 256
  local b2 = math.floor(value / 65536) % 256
  local b3 = math.floor(value / 16777216) % 256
  return string.char(b0, b1, b2, b3)
end

local function container(magic, blocks)
  local body = {}
  local size = 0x10
  for _, blk in ipairs(blocks) do
    body[#body + 1] = blk
    size = size + #blk
  end
  return magic .. string.char(0xFF, 0xFE) .. u16(0x0100) .. u32(size) .. u16(0x10) .. u16(#blocks) .. table.concat(body)
end

local function block(magic, payload)
  return magic:reverse() .. u32(8 + #payload) .. payload
end

local function scanWords(desired, seed0)
  local aLo, aHi = 20077, 16838
  local seed = seed0
  local out = {}
  for _, word in ipairs(desired) do
    out[#out + 1] = bit.bxor(word, seed % 65536)
    local sLo = seed % 65536
    local sHi = math.floor(seed / 65536)
    seed = (sLo * aLo + ((sLo * aHi + sHi * aLo) % 65536) * 65536 + 24691) % 4294967296
  end
  return out
end

local function wordsToBytes(words)
  local parts = {}
  for _, word in ipairs(words) do
    parts[#parts + 1] = string.char(word % 256, math.floor(word / 256) % 256)
  end
  return table.concat(parts)
end

local function charContainer(tiles)
  local payload = u16(8) .. u16(0x20) .. u32(3) .. u16(0) .. u16(0) .. u32(0) .. u32(#tiles) .. u32(0x18) .. tiles
  return container("RGCN", { block("CHAR", payload) })
end

local function paletteContainer(words)
  local body = {}
  for _, word in ipairs(words) do
    body[#body + 1] = u16(word)
  end
  return container(
    "NCLR",
    { block("PLTT", string.char(3, 0) .. u16(#words) .. u32(0) .. u32(12) .. table.concat(body)) }
  )
end

local function paletteWords()
  return {
    0x0000,
    0x001F,
    0x03E0,
    0x7C00,
    0x7FFF,
    0x03FF,
    0x7C1F,
    0x7FE0,
    0x4210,
    0x2240,
    0x4000,
    0x0010,
    0x5294,
    0x1CE7,
    0x6318,
    0x0E73,
  }
end

-- Plain unscanned bytes for one 80x80 surface: the left half carries one
-- authored frame, the right half the other, and both halves use native
-- indices 0,1,2,3,6,7,8 so indexed/RGBA agreement and the Spinda source
-- slots are exercised in every row band.
local function plainPortraitBytes()
  local nibbles = { 0, 1, 2, 3, 6, 7, 8, 0 }
  local rows = {}
  for y = 0, 79 do
    local left = {}
    local right = {}
    for x = 0, 39 do
      local lo = nibbles[(x + y) % #nibbles + 1]
      local hi = nibbles[(x + y + 3) % #nibbles + 1]
      left[#left + 1] = string.char(lo + hi * 16)
      local rlo = nibbles[(x + y + 5) % #nibbles + 1]
      local rhi = nibbles[(x + y + 1) % #nibbles + 1]
      right[#right + 1] = string.char(rlo + rhi * 16)
    end
    rows[#rows + 1] = table.concat(left) .. table.concat(right)
  end
  return table.concat(rows)
end

local function portraitRomFs(charBytes, paletteBytes)
  local perNarc = {}
  local speciesId = MonSources.speciesId("CHIKORITA")
  for _, gender in ipairs({ "male", "female" }) do
    for _, facing in ipairs({ FRONT_FACING, 0 }) do
      local ids = MonSources.portraitIds(speciesId, gender, facing, false, 0)
      local store = perNarc[ids.narc] or {}
      perNarc[ids.narc] = store
      store[ids.charMemberId] = charBytes
    end
    for _, shiny in ipairs({ false, true }) do
      local shinyIds = MonSources.portraitIds(speciesId, gender, FRONT_FACING, shiny, 0)
      local store = perNarc[shinyIds.narc] or {}
      perNarc[shinyIds.narc] = store
      store[shinyIds.palMemberId] = paletteBytes
    end
  end
  return {
    openNarc = function(_, alias)
      local members = perNarc[alias] or {}
      return {
        readMember = function(_, memberId)
          return members[memberId]
        end,
      }
    end,
  }
end

local function entryToBytes(entry)
  if type(entry) == "string" then
    return entry
  end
  assert(type(entry) == "table", "palette entries decode to bytes or rgba tables")
  if entry.r ~= nil then
    return string.char(entry.r, entry.g, entry.b, entry.a or 255)
  end
  return string.char(entry[1], entry[2], entry[3], entry[4] or 255)
end

function T.indexed_front_frames_agree_with_rgba_bytes()
  local MonPresentationCompiler = require("romdump.src.digest.mons.MonPresentationCompiler")
  local loadedIndexed = pcall(function()
    assert(type(MonPresentationCompiler.compileFrontIndexedFrames) == "function")
  end)
  Assert.isTrue(
    loadedIndexed,
    "the producer-only indexed front export must be published before pixel agreement can be proven"
  )
  local plain = plainPortraitBytes()
  Assert.equal(#plain, 6400, "the plain surface covers both 80x80 frames")
  local desired = {}
  for i = 1, #plain, 2 do
    desired[#desired + 1] = string.byte(plain, i) + string.byte(plain, i + 1) * 256
  end
  local charBytes = charContainer(wordsToBytes(scanWords(desired, 0x1234)))
  local fs = portraitRomFs(charBytes, paletteContainer(paletteWords()))

  local rgba, rgbaErr = MonPresentationCompiler.compileFrontFrames(fs, 152, 0, "male", false)
  Assert.notNil(rgba, "the existing RGBA export must compile the synthetic frames")
  Assert.isNil(rgbaErr, "the existing RGBA export carries no error")
  Assert.equal(#rgba.frames, 2, "the RGBA export carries both authored frames")

  local indexed, indexedErr = MonPresentationCompiler.compileFrontIndexedFrames(fs, 152, 0, "male", false)
  Assert.notNil(indexed, "the indexed export must compile the same synthetic frames")
  Assert.isNil(indexedErr, "the indexed export carries no error")
  Assert.equal(#indexed.frames, 2, "the indexed export carries both authored frames")
  Assert.equal(#indexed.frames[1], 6400, "each indexed plane covers its 80x80 frame")
  Assert.equal(#indexed.frames[2], 6400, "each indexed plane covers its 80x80 frame")
  Assert.isTrue(indexed.frames[1] ~= indexed.frames[2], "the two authored frames stay distinct")
  Assert.equal(#indexed.palette, 16, "the indexed export decodes all sixteen colors")
  Assert.isTrue(type(indexed.dependencies) == "table", "the indexed export identifies its raw inputs")
  Assert.notNil(next(indexed.dependencies), "the indexed export names at least one raw input")

  local paletteBytes = {}
  for index = 1, 16 do
    paletteBytes[index] = entryToBytes(indexed.palette[index])
    Assert.equal(#paletteBytes[index], 4, "each decoded color carries four bytes")
  end
  local seen = {}
  for frame = 1, 2 do
    local plane, rgbaFrame = indexed.frames[frame], rgba.frames[frame]
    Assert.equal(#rgbaFrame, 25600, "each RGBA frame covers 80x80 pixels")
    for y = 0, 79 do
      for x = 0, 79 do
        local index = string.byte(plane, y * 80 + x + 1)
        seen[index] = true
        local base = (y * 80 + x) * 4 + 1
        local pixel = string.sub(rgbaFrame, base, base + 3)
        if index == 0 then
          Assert.equal(pixel, "\0\0\0\0", "index zero stays transparent at " .. x .. "," .. y)
        else
          Assert.equal(
            pixel,
            paletteBytes[index + 1],
            "the RGBA export matches the indexed plane through the shared palette at " .. x .. "," .. y
          )
        end
      end
    end
  end
  for _, native in ipairs({ 1, 2, 3, 6, 7, 8 }) do
    Assert.isTrue(seen[native], "native index " .. native .. " survives in the indexed planes")
  end
  Assert.isTrue(
    paletteBytes[7] ~= paletteBytes[8] and paletteBytes[8] ~= paletteBytes[9],
    "the native 6..8 replacement colors stay distinct"
  )
end

function T.spinda_masks_accept_semantic_slots_and_reject_native_residue()
  local PokedexAssetSchema = requireProduction()
  requireCompiler()
  local catalog = fixtureCatalog()
  local manifest = fixtureManifest(catalog)
  local record = assert(PokedexAssetSchema.validateManifest(manifest, catalog))
  local spinda = assert(record.spinda, "the validated manifest keeps the spinda section")
  Assert.equal(spinda.secondFrameXOffset, -14, "the validated manifest keeps the second-frame offset")
  Assert.equal(#spinda.spots, 4, "the validated manifest keeps all four spot records")
  Assert.equal(#spinda.replacementColors.normal, 3, "the validated manifest keeps three normal colors")
  Assert.equal(#spinda.replacementColors.shiny, 3, "the validated manifest keeps three shiny colors")
  for gender, eligibility in pairs(spinda.eligibility) do
    void(gender)
    for _, frame in ipairs(eligibility.frames) do
      Assert.equal(#frame, 80, "every eligibility frame carries eighty rows")
      for _, row in ipairs(frame) do
        Assert.equal(#row, 80, "every eligibility row carries eighty slots")
      end
    end
  end

  local badIndex = fixtureManifest(catalog)
  badIndex.spinda.eligibility.male.frames[1][1] = string.rep("0", 79) .. "4"
  Assert.isNil(PokedexAssetSchema.validateManifest(badIndex, catalog), "native residue outside 0..3 must not validate")

  local shortRow = fixtureManifest(catalog)
  shortRow.spinda.eligibility.male.frames[2][1] = string.rep("1", 79)
  Assert.isNil(PokedexAssetSchema.validateManifest(shortRow, catalog), "a short eligibility row must not validate")

  local function walkKeys(node, seen)
    if type(node) ~= "table" then
      if type(node) == "string" and node:lower():find("pid", 1, true) then
        seen[#seen + 1] = node
      end
      return
    end
    for key, value in pairs(node) do
      if type(key) == "string" and key:lower():find("pid", 1, true) then
        seen[#seen + 1] = key
      end
      walkKeys(value, seen)
    end
  end
  local residue = {}
  walkKeys(record.spinda, residue)
  Assert.equal(#residue, 0, "the semantic spinda record carries no PID-keyed residue")
end

return { tests = T }
