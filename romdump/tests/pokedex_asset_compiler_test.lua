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

-- Producer contract: the page/layer source map covers every required
-- role with native pane/layer bindings, and the window inventory covers
-- every text slot the controller projects and presentation consumes. Both
-- tables are the sole native-identity owners; the manifest carries only
-- generated roles.
local CONTRACTED_WINDOWS = {
  "grid.seen-count",
  "grid.caught-count",
  "grid.selected-number",
  "grid.selected-name",
  "entry.species-name",
  "entry.dex-number",
  "entry.category",
  "entry.flavor",
  "entry.height",
  "entry.weight",
  "search.criteria",
  "search.feedback",
  "search.results",
  "area.time",
  "area.location",
  "size.title",
  "size.species-weight",
  "forms.selected",
  "forms.compare-left",
  "forms.compare-right",
  "return.title",
  "registration.header",
  "registration.dex-number",
  "registration.species-name",
  "registration.category",
  "registration.flavor",
  "registration.height",
  "registration.weight",
}

function T.producer_page_layers_cover_every_required_role()
  local PokedexSources = assert(require("romdump.src.config.PokedexSources"))
  Assert.notNil(PokedexSources.pageLayers, "the producer must publish its page/layer source map")
  for _, role in ipairs(REQUIRED_PAGES) do
    local layers = PokedexSources.pageLayers[role]
    Assert.notNil(layers, "the source map must bind the " .. role .. " page")
    Assert.isTrue(#layers > 0, "the " .. role .. " page must bind at least one layer")
    for _, entry in ipairs(layers) do
      Assert.isTrue(
        entry.pane == "information" or entry.pane == "controls",
        "the " .. role .. " layer must target a native pane"
      )
      Assert.isTrue(
        type(entry.layer) == "number" and entry.layer >= 0 and entry.layer <= 3,
        "the " .. role .. " layer must be a native BG layer"
      )
      Assert.isTrue(
        type(entry.char) == "number" and type(entry.palette) == "number",
        "the " .. role .. " layer must name its character and palette members"
      )
    end
  end
end

-- Native scroll state: the grid page depicts the scrolled entry view, where
-- SUB BG0 sits on its cleared half, so the grid information pane carries no
-- opaque layer-0 composition over the layer-1 text windows. The windowless
-- cover keeps the loaded dial art.
function T.producer_grid_information_layer_matches_scrolled_native_state()
  local PokedexSources = assert(require("romdump.src.config.PokedexSources"))
  local function bindsInformationLayer0(role)
    for _, entry in ipairs(assert(PokedexSources.pageLayers[role], "the source map must bind " .. role)) do
      if entry.pane == "information" and entry.layer == 0 then
        return true
      end
    end
    return false
  end
  Assert.isFalse(
    bindsInformationLayer0("grid"),
    "the grid information pane carries no foreground composition over its layer-1 text windows"
  )
  Assert.isTrue(
    bindsInformationLayer0("cover"),
    "the windowless cover keeps its native foreground art"
  )
end

-- Native area view: SetupScreen case 1 loads the area graphics and
-- installs SetAreaBgPriorities (MAIN 1/0/2/3, SUB 3/0/1/2), so the SUB
-- BG0 area map (char 87 + screen 86, staged on the 512-wide SUB BG0
-- scroll plane and panned to the -72/+104 settled region offsets)
-- composites behind the SUB BG1 entry windows (BG0 pri 3 back vs BG1
-- pri 0 front). The area information pane therefore binds the full
-- pannable map on layer 0 with the native area-view priority, never a
-- dropped layer or the list-browse priority that would bury the windows.
function T.producer_area_information_layer_carries_pannable_map_behind_windows()
  local PokedexSources = assert(require("romdump.src.config.PokedexSources"))
  local map = nil
  for _, entry in ipairs(assert(PokedexSources.pageLayers["entry.area"], "the source map must bind entry.area")) do
    if entry.pane == "information" and entry.layer == 0 then
      map = entry
    end
  end
  Assert.notNil(map, "the area information pane binds its layer-0 map composition")
  Assert.equal(map.char, 87, "the area map keeps its native character data")
  Assert.equal(map.screen, 86, "the area map keeps its native full-width scroll map")
  local priorities = assert(
    PokedexSources.pagePriorities and PokedexSources.pagePriorities["entry.area"],
    "the producer records the native area-view priorities"
  )
  Assert.equal(priorities.information[0], 3, "the area map renders behind its entry windows")
  Assert.equal(priorities.information[1], 0, "the area entry windows render in front of the map")
  Assert.equal(priorities.information[2], 1, "the area information layer 2 keeps its native priority")
  Assert.equal(priorities.information[3], 2, "the area information layer 3 keeps its native priority")
  Assert.equal(priorities.controls[0], 1, "the area controls layer 0 keeps its native priority")
  Assert.equal(priorities.controls[1], 0, "the area controls layer 1 keeps its native priority")
  Assert.equal(priorities.controls[2], 2, "the area controls layer 2 keeps its native priority")
  Assert.equal(priorities.controls[3], 3, "the area controls layer 3 keeps its native priority")
end

function T.producer_window_inventory_covers_contracted_text_slots()
  local PokedexSources = assert(require("romdump.src.config.PokedexSources"))
  Assert.notNil(PokedexSources.windows, "the producer must publish its window inventory")
  for _, key in ipairs(CONTRACTED_WINDOWS) do
    local record = PokedexSources.windows[key]
    Assert.notNil(record, "the window inventory must declare " .. key)
    Assert.isTrue(record.pane == "information" or record.pane == "controls", key .. " must target a native pane")
    Assert.isTrue(record.font == 0 or record.font == 4, key .. " must use the body or header font")
    Assert.isTrue(
      type(record.paletteGroup) == "string" and record.paletteGroup ~= "",
      key .. " must name a non-empty palette group"
    )
  end
end

-- Native window geometry: every contracted text slot carries the tile
-- coordinates (in logical pixels), BG layer, body/header font role,
-- alignment and text palette slot of the native window template that
-- draws it, not a placeholder rect.
local NATIVE_WINDOWS = {
  ["grid.seen-count"] = { pane = "controls", layer = 0, x = 88, y = 88, width = 24, height = 16, font = 0, align = "left", paletteGroup = "window-9" },
  ["grid.caught-count"] = { pane = "controls", layer = 0, x = 216, y = 88, width = 24, height = 16, font = 0, align = "left", paletteGroup = "window-9" },
  ["grid.selected-number"] = { pane = "information", layer = 1, x = 120, y = 24, width = 32, height = 16, font = 4, align = "left", paletteGroup = "window-0" },
  ["grid.selected-name"] = { pane = "information", layer = 1, x = 152, y = 24, width = 72, height = 16, font = 4, align = "left", paletteGroup = "window-0" },
  ["entry.species-name"] = { pane = "information", layer = 1, x = 0, y = 128, width = 72, height = 16, font = 0, align = "center", paletteGroup = "window-1" },
  ["entry.dex-number"] = { pane = "information", layer = 1, x = 120, y = 24, width = 32, height = 16, font = 4, align = "left", paletteGroup = "window-0" },
  ["entry.category"] = { pane = "information", layer = 1, x = 104, y = 40, width = 144, height = 16, font = 4, align = "right", paletteGroup = "window-0" },
  ["entry.flavor"] = { pane = "information", layer = 1, x = 16, y = 136, width = 224, height = 48, font = 0, align = "left", paletteGroup = "window-1" },
  ["entry.height"] = { pane = "information", layer = 1, x = 56, y = 168, width = 64, height = 16, font = 0, align = "center", paletteGroup = "window-2" },
  ["entry.weight"] = { pane = "controls", layer = 1, x = 56, y = 184, width = 64, height = 16, font = 0, align = "center", paletteGroup = "window-1" },
  ["search.criteria"] = { pane = "controls", layer = 0, x = 128, y = 8, width = 88, height = 16, font = 4, align = "center", paletteGroup = "window-2" },
  ["search.feedback"] = { pane = "information", layer = 1, x = 16, y = 152, width = 224, height = 40, font = 0, align = "center", paletteGroup = "window-2" },
  ["search.results"] = { pane = "information", layer = 1, x = 16, y = 0, width = 64, height = 16, font = 4, align = "left", paletteGroup = "window-2" },
  ["area.time"] = { pane = "information", layer = 1, x = 8, y = 24, width = 56, height = 16, font = 0, align = "center", paletteGroup = "window-1" },
  ["area.location"] = { pane = "controls", layer = 2, x = 80, y = 40, width = 144, height = 16, font = 4, align = "center", paletteGroup = "window-1" },
  ["size.title"] = { pane = "information", layer = 1, x = 16, y = 0, width = 72, height = 16, font = 4, align = "left", paletteGroup = "window-2" },
  ["size.species-weight"] = { pane = "controls", layer = 1, x = 56, y = 136, width = 64, height = 16, font = 0, align = "center", paletteGroup = "window-1" },
  ["forms.selected"] = { pane = "information", layer = 1, x = 104, y = 40, width = 120, height = 16, font = 0, align = "center", paletteGroup = "window-1" },
  ["forms.compare-left"] = { pane = "controls", layer = 1, x = 0, y = 96, width = 128, height = 16, font = 0, align = "center", paletteGroup = "window-1" },
  ["forms.compare-right"] = { pane = "controls", layer = 1, x = 128, y = 96, width = 128, height = 16, font = 0, align = "center", paletteGroup = "window-1" },
  ["return.title"] = { pane = "information", layer = 1, x = 16, y = 0, width = 72, height = 16, font = 4, align = "left", paletteGroup = "window-2" },
  ["registration.header"] = { pane = "information", layer = 1, x = 16, y = 0, width = 224, height = 16, font = 4, align = "center", paletteGroup = "window-2" },
  ["registration.dex-number"] = { pane = "information", layer = 1, x = 120, y = 24, width = 32, height = 16, font = 4, align = "left", paletteGroup = "window-0" },
  ["registration.species-name"] = { pane = "information", layer = 1, x = 152, y = 24, width = 72, height = 16, font = 4, align = "left", paletteGroup = "window-0" },
  ["registration.category"] = { pane = "information", layer = 1, x = 104, y = 40, width = 144, height = 16, font = 4, align = "right", paletteGroup = "window-0" },
  ["registration.flavor"] = { pane = "information", layer = 1, x = 16, y = 136, width = 224, height = 48, font = 0, align = "left", paletteGroup = "window-1" },
  ["registration.height"] = { pane = "information", layer = 1, x = 184, y = 88, width = 64, height = 16, font = 0, align = "left", paletteGroup = "window-1" },
  ["registration.weight"] = { pane = "information", layer = 1, x = 184, y = 104, width = 64, height = 16, font = 0, align = "left", paletteGroup = "window-1" },
}

function T.producer_windows_match_native_templates()
  local PokedexSources = assert(require("romdump.src.config.PokedexSources"))
  for _, key in ipairs(CONTRACTED_WINDOWS) do
    local record = assert(
      PokedexSources.windows[key],
      "the window inventory must declare " .. key
    )
    local expected = assert(NATIVE_WINDOWS[key], "the native oracle must cover " .. key)
    for _, field in ipairs(
      { "pane", "layer", "x", "y", "width", "height", "font", "align", "paletteGroup" }
    ) do
      Assert.equal(
        record[field],
        expected[field],
        key .. " carries the native template " .. field
      )
    end
  end
end

-- Native sprite bindings: every page binds exactly the OBJ cell/animation
-- families its screen setup loads, never a nearest-member approximation.
local NATIVE_PAGE_OBJS = {
  cover = {},
  grid = { { 13, 14 }, { 27, 28 }, { 30, 31 }, { 33, 34 }, { 54, 55 }, { 78, 79 } },
  results = { { 13, 14 }, { 24, 25 }, { 27, 28 }, { 30, 31 }, { 33, 34 }, { 54, 55 }, { 73, 74 }, { 78, 79 } },
  ["search.criteria"] = { { 13, 14 }, { 24, 25 }, { 54, 55 }, { 73, 74 } },
  ["search.order"] = { { 13, 14 }, { 24, 25 }, { 54, 55 }, { 73, 74 } },
  ["search.name"] = { { 13, 14 }, { 24, 25 }, { 54, 55 }, { 73, 74 } },
  ["search.type"] = { { 13, 14 }, { 24, 25 }, { 54, 55 }, { 73, 74 } },
  ["search.height"] = { { 13, 14 }, { 24, 25 }, { 54, 55 }, { 73, 74 } },
  ["search.weight"] = { { 13, 14 }, { 24, 25 }, { 54, 55 }, { 73, 74 } },
  ["search.area"] = { { 13, 14 }, { 24, 25 }, { 54, 55 }, { 73, 74 } },
  ["search.shape"] = { { 13, 14 }, { 24, 25 }, { 54, 55 }, { 73, 74 } },
  ["entry.area"] = { { 13, 14 }, { 116, 117 }, { 120, 121 } },
  ["entry.size"] = { { 13, 14 }, { 106, 107 }, { 112, 113 } },
  ["entry.forms"] = { { 13, 14 } },
  ["entry.compare"] = { { 13, 14 } },
  ["entry.return"] = { { 13, 14 } },
  registration = { { 30, 31 }, { 33, 34 }, { 78, 79 } },
}

function T.producer_page_objs_bind_exact_sprite_families()
  local PokedexSources = assert(require("romdump.src.config.PokedexSources"))
  Assert.notNil(PokedexSources.pageObjs, "the producer must publish its page OBJ map")
  for _, role in ipairs(REQUIRED_PAGES) do
    local pairs = assert(PokedexSources.pageObjs[role], "the OBJ map must bind the " .. role .. " page")
    local expected = assert(NATIVE_PAGE_OBJS[role], "the native oracle must cover the " .. role .. " page")
    Assert.equal(#pairs, #expected, "the " .. role .. " page binds its native OBJ family count")
    for index, pair in ipairs(expected) do
      Assert.equal(pairs[index].cells, pair[1], "the " .. role .. " page binds its native cell family")
      Assert.equal(pairs[index].anims, pair[2], "the " .. role .. " page binds its native animation family")
    end
  end
end

-- Native static OBJ anchors: per-page, per-animation-family, per-sequence
-- screen centers for sprites whose art, position, and page visibility
-- are all fixed (verified against the decomp sprite setup at the pinned
-- snapshot, not invented from cell extents). The shape choice grid shows
-- choice art k at grid slot k while the shape editor is open
-- (CreateSearchSprites body-type loop: x = 32 + 48 * (choice % 5),
-- y = 56 + 40 * (choice / 5) on the MAIN engine); the registration
-- banner emblem sits at (112, 32) on the popup card
-- (PokedexEntryPopup_CreateBannerSprite, staged on the information
-- surface). Every other page sprite stays origin-anchored: cursors,
-- arrows, scrollbars, tab cursors, digits, type/footprint/mon-picture art
-- and language icons all vary art, position, or visibility by live
-- state, so no static anchor can place them.
local NATIVE_SPRITE_ANCHORS = {
  ["search.shape"] = {
    [74] = {
      [1] = { x = 32, y = 56, pane = "controls" },
      [2] = { x = 80, y = 56, pane = "controls" },
      [3] = { x = 128, y = 56, pane = "controls" },
      [4] = { x = 176, y = 56, pane = "controls" },
      [5] = { x = 224, y = 56, pane = "controls" },
      [6] = { x = 32, y = 96, pane = "controls" },
      [7] = { x = 80, y = 96, pane = "controls" },
      [8] = { x = 128, y = 96, pane = "controls" },
      [9] = { x = 176, y = 96, pane = "controls" },
      [10] = { x = 224, y = 96, pane = "controls" },
      [11] = { x = 32, y = 136, pane = "controls" },
      [12] = { x = 80, y = 136, pane = "controls" },
      [13] = { x = 128, y = 136, pane = "controls" },
      [14] = { x = 176, y = 136, pane = "controls" },
    },
  },
  registration = {
    [31] = {
      [1] = { x = 112, y = 32, pane = "information" },
    },
  },
}

function T.producer_static_sprites_carry_authored_screen_anchors()
  local PokedexSources = assert(require("romdump.src.config.PokedexSources"))
  local anchors = assert(
    PokedexSources.spriteAnchors,
    "the producer must publish its static sprite anchor map"
  )
  for role, families in pairs(NATIVE_SPRITE_ANCHORS) do
    local bound = assert(anchors[role], "the anchor map must bind the " .. role .. " page")
    for member, sequences in pairs(families) do
      local boundSequences = assert(
        bound[member],
        "the anchor map must bind animation family " .. member .. " on " .. role
      )
      for index, expected in pairs(sequences) do
        local record = assert(
          boundSequences[index],
          "the anchor map must bind sequence " .. index .. " of family " .. member .. " on " .. role
        )
        Assert.equal(record.x, expected.x, role .. " sequence " .. index .. " keeps its native x")
        Assert.equal(record.y, expected.y, role .. " sequence " .. index .. " keeps its native y")
        Assert.equal(record.pane, expected.pane, role .. " sequence " .. index .. " keeps its native pane")
      end
    end
  end
  local anchored = 0
  for _, families in pairs(anchors) do
    for _, sequences in pairs(families) do
      for _, record in pairs(sequences) do
        anchored = anchored + 1
        Assert.isTrue(
          record.x ~= 0 or record.y ~= 0,
          "anchors never sit on the unplaced origin sentinel"
        )
      end
    end
  end
  local wanted = 0
  for _, families in pairs(NATIVE_SPRITE_ANCHORS) do
    for _, sequences in pairs(families) do
      for _ in pairs(sequences) do
        wanted = wanted + 1
      end
    end
  end
  Assert.equal(anchored, wanted, "the anchor map binds exactly the verified static subset")
end

return { tests = T }
