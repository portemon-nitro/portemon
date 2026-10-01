-- Compiles the generated party presentation class: canonical backdrops,
-- panel templates, cursor/ball/button/held/status/feedback sprite frames,
-- exact icon animation timelines, text palette roles with gender labels,
-- window-relative numeric placement, semantic message windows, source-shaped
-- context-menu layouts with generated frame visuals, navigation tables,
-- lowered bank-300 text, source numeric glyphs, and Shiny Leaf/crown badge
-- frames. Source
-- member selection and geometry live in romdump/src/config/PartySources.lua;
-- this module owns the decode, rasterization, and the normalized bundle. 2D
-- mechanics reuse G2dDecoder/G2dRasterizer/PngWriter; species icon
-- graphics resolve through the existing mon class and are never read here.
-- The runtime consumes only the manifest and the generated files, never
-- this module. Pure module: no love dependency.
-- Source basis: pret/pokeheartgold@0985e8718df4f25e64d6507d89c0c97c0d288981
-- src/party_menu.c, src/party_menu_sprites.c, src/party_context_menu.c.

local Errors = require("libs.errors.src.Errors")
local Hashing = require("romdump.src.digest.Hashing")
local PngWriter = require("libs.assets.src.PngWriter")
local Lz10 = require("romdump.src.digest.Lz10")
local G2dDecoder = require("romdump.src.digest.ui.G2dDecoder")
local G2dRasterizer = require("romdump.src.digest.ui.G2dRasterizer")
local PartyAssetSchema = require("libs.assets.src.PartyAssetSchema")
local PartyCache = require("libs.assets.src.PartyCache")
local PartySources = require("romdump.src.config.PartySources")
local FieldMessageBank = require("romdump.src.digest.ui.FieldMessageBank")
local FieldMessageTokenizer = require("romdump.src.digest.ui.FieldMessageTokenizer")
local FieldMessageText = require("libs.assets.src.field.FieldMessageText")
local charmap = require("romdump.src.reference.hgss.charmap")

---@class PartyAssetCompiler
local PartyAssetCompiler = {}

-- Named ownership of the compiler protocol error code; tests assert the
-- constant, never the raw string.
PartyAssetCompiler.ERROR = {
  SOURCE_INVALID = "PARTY_SOURCE_INVALID",
}

-- Closed bank-300 substitution vocabulary for the party presentation. The
-- nickname field feeds name records, the move field feeds move records,
-- and the quantity field feeds quantity records. Every other substitution
-- or control is malformed source, never a runtime marker to interpret.
local NAME_SUBSTITUTION = FieldMessageText.STRVAR_1 + 1
local MOVE_SUBSTITUTION = FieldMessageText.STRVAR_1 + 6
local QUANTITY_SUBSTITUTION = FieldMessageText.STRVAR_1 + 52

local function sourceError(message, context)
  error(Errors.new(PartyAssetCompiler.ERROR.SOURCE_INVALID, "party " .. message, context or {}), 0)
end

local function readMember(archive, memberId, role, dependencies, archiveLabel)
  local member, err = archive:readMember(memberId)
  if not member then
    sourceError("member " .. memberId .. " is unreadable: " .. Errors.format(err), { role = role, memberId = memberId })
  end
  assert(member ~= nil, "unreadable members fail above")
  dependencies[#dependencies + 1] =
    { name = (archiveLabel or "party") .. ":member:" .. memberId, role = role, sha1 = Hashing.sha1hex(member) }
  if string.byte(member, 1) == 0x10 then
    local plain, lzErr = Lz10.decode(member)
    if not plain then
      error(lzErr, 0)
    end
    member = plain
  end
  return member
end

local function decode(kind, bytes, role)
  local record, err = G2dDecoder[kind](bytes, { label = "party:" .. role })
  if not record then
    assert(err)
    sourceError(role .. " does not decode: " .. err.message, { role = role, cause = err.code })
  end
  return record
end

-- Lowers the producer context-button inventory into source-independent
-- count-keyed layouts. Tile units become pixels; zero-based source
-- selections become one-based entry indices; touch rectangles copy the source
-- hitbox touched by each entry; the cancel button keeps its native cancel
-- shape while every other entry keeps the standard shape. A -1 up/down
-- neighbor stays absent; a -1 lateral relation lowers to the entry itself,
-- which preserves the source no-move behavior without inventing a
-- cross-entry jump. Pure and ROM-free like the rest of this lowering.
---@param buttons table<string, unknown>
---@return table<string, unknown>
local function lowerContextMenus(buttons)
  local inventory = buttons --[[@as table<string, unknown>]]
  local textWindows = inventory.textWindows --[[@as table[] ]]
  local frames = inventory.frames --[[@as table[] ]]
  local windowIds = inventory.windowIds --[[@as table<string, table<integer, integer[]>> ]]
  local navTop = inventory.navTopLevel --[[@as table<integer, integer[][]> ]]
  local navSub = inventory.navSubcontext --[[@as table<integer, integer[][]> ]]
  local hitboxes = inventory.hitboxes --[[@as table[] ]]
  local subHitboxes = inventory.subHitboxes --[[@as table[] ]]
  local function tileRect(tile)
    local typed = tile --[[@as table<string, integer>]]
    return { x = typed.x * 8, y = typed.y * 8, width = typed.width * 8, height = typed.height * 8 }
  end
  local function touchCopy(box)
    local typed = box --[[@as table<string, integer>]]
    return { top = typed.top, bottom = typed.bottom, left = typed.left, right = typed.right }
  end
  local function neighbor(value, count, role)
    if value == nil or value == -1 then
      return nil
    end
    if type(value) ~= "number" or value % 1 ~= 0 or value < 0 or value >= count then
      sourceError("context menu neighbor escapes its layout", { role = role, neighbor = value, count = count })
    end
    return value + 1
  end
  local topLevel = {}
  for count = 2, 8 do
    local ids = windowIds.top[count]
    local nav = navTop[count]
    if type(ids) ~= "table" or #ids ~= count or type(nav) ~= "table" or #nav ~= count then
      sourceError("top-level menu lacks a complete source mapping", { count = count })
    end
    local layout = {}
    for index = 1, count do
      local buttonId = ids[index]
      if type(buttonId) ~= "number" or buttonId < 0 or buttonId >= 12 then
        sourceError("top-level entry selects no source button", { count = count, entry = index })
      end
      local navRow = nav[index] --[[@as integer[] ]]
      local lateral = navRow[3]
      if lateral ~= nil and lateral ~= -1 then
        if lateral < 0 or lateral >= count then
          sourceError("top-level lateral escapes its layout", { count = count, entry = index })
        end
      end
      local across = (lateral == nil or lateral == -1) and index or (lateral + 1)
      layout[index] = {
        textRect = tileRect(textWindows[buttonId + 1]),
        frameRect = tileRect(frames[buttonId + 1]),
        frameShape = buttonId == 7 and "cancel" or "standard",
        style = buttonId == 7 and "cancel" or ((index - 1) < 4 and "command" or "field"),
        touch = touchCopy(hitboxes[buttonId + 1]),
        up = neighbor(navRow[1], count, "up"),
        down = neighbor(navRow[2], count, "down"),
        left = across,
        right = across,
      }
    end
    topLevel[count] = layout
  end
  local subcontext = {}
  for count = 2, 5 do
    local ids = windowIds.sub[count]
    local nav = navSub[count]
    if type(ids) ~= "table" or #ids ~= count or type(nav) ~= "table" or #nav ~= count then
      sourceError("subcontext menu lacks a complete source mapping", { count = count })
    end
    local layout = {}
    for index = 1, count do
      local buttonId = ids[index]
      if type(buttonId) ~= "number" or buttonId < 0 or buttonId >= 12 then
        sourceError("subcontext entry selects no source button", { count = count, entry = index })
      end
      local navRow = nav[index] --[[@as integer[] ]]
      local touch = buttonId == 7 and subHitboxes[5] or subHitboxes[index]
      if touch == nil then
        sourceError("subcontext entry has no source touch mapping", { count = count, entry = index })
      end
      layout[index] = {
        textRect = tileRect(textWindows[buttonId + 1]),
        frameRect = tileRect(frames[buttonId + 1]),
        frameShape = buttonId == 7 and "cancel" or "standard",
        style = buttonId == 7 and "cancel" or ((index - 1) < 4 and "command" or "field"),
        touch = touchCopy(touch),
        up = neighbor(navRow[1], count, "up"),
        down = neighbor(navRow[2], count, "down"),
      }
    end
    subcontext[count] = layout
  end
  return { topLevel = topLevel, subcontext = subcontext }
end

-- Lowers the producer gender-mark offset to a panel-absolute point: the
-- mark prints at a fixed name-window-local position, so each panel
-- resolves its name-subrect origin plus the producer offset. The point is
-- required on every panel; placement never follows the drawn name.
---@param offset { x: integer, y: integer }
---@param nameRect table<string, unknown>
---@return table<string, integer>
local function lowerGenderOrigin(offset, nameRect)
  assert(type(offset) == "table", "party geometry requires the gender offset")
  local typed = nameRect --[[@as table<string, integer>]]
  return { x = typed.x + offset.x, y = typed.y + offset.y }
end

-- Pure geometry lowering over the producer inventory: slot panels with
-- source-derived anchors and audited text/HP/compat subrectangles, the
-- navigation tables, the touch hitboxes, the semantic context-menu layouts,
-- and the badge expectations. Pixel realization happens in _compile; this
-- stays ROM-free.
---@param sources table<string, unknown>
---@return table<string, unknown>
function PartyAssetCompiler.compileGeometry(sources)
  assert(type(sources) == "table", "party geometry requires the producer inventory")
  local geometry = sources.geometry --[[@as table<string, unknown>]]
  local panelWindows = sources.panelWindows --[[@as table<string, unknown>]]
  local genderOffset = sources.genderOffset --[[@as table<string, integer>]]
  assert(type(geometry) == "table" and type(panelWindows) == "table", "party geometry requires panels and windows")
  local controls = geometry.controls --[[@as table<string, unknown>]]
  local placements = geometry.panels --[[@as table[] ]]
  assert(#placements == 6, "party geometry carries six slot placements")
  local indicatorOffsets = geometry.indicatorOffsets --[[@as table<string, table<string, integer>>]]
  local heldFromIcon = indicatorOffsets.heldFromIcon
  local capsuleFromHeld = indicatorOffsets.capsuleFromHeld
  local cancelSource = controls.cancel --[[@as table<string, table<string, integer>>]]
  local function shift(rect, origin)
    local typed = rect --[[@as table<string, unknown>]]
    return {
      x = origin.x + typed.x,
      y = origin.y + typed.y,
      width = typed.width,
      height = typed.height,
    }
  end
  local panels = {}
  local cursorSelectors = geometry.cursorSequenceSelectors --[[@as integer[] ]]
  for slot, placement in ipairs(placements) do
    local record = placement --[[@as table<string, unknown>]]
    local origin = record.origin --[[@as table<string, integer>]]
    local selector = cursorSelectors[slot]
    assert(selector ~= nil, "every slot has a source cursor sequence")
    local iconAnchor = geometry.monAnchors[slot] --[[@as table<string, integer>]]
    local heldAnchor = { x = iconAnchor.x + heldFromIcon.x, y = iconAnchor.y + heldFromIcon.y }
    local nameRect = shift(panelWindows.name, origin)
    panels[slot] = {
      origin = { x = origin.x, y = origin.y },
      size = { width = 128, height = 48 },
      iconAnchor = iconAnchor,
      ballAnchor = geometry.ballAnchors[slot],
      heldAnchor = heldAnchor,
      capsuleAnchor = { x = heldAnchor.x + capsuleFromHeld.x, y = heldAnchor.y + capsuleFromHeld.y },
      statusRect = geometry.statusRects[slot],
      cursorSequence = selector + 1,
      text = {
        name = nameRect,
        level = shift(panelWindows.level, origin),
        gender = lowerGenderOrigin(genderOffset, nameRect),
      },
      hp = {
        bar = shift(panelWindows.bar, origin),
        number = shift(panelWindows.number, origin),
      },
      compat = shift(panelWindows.compat, origin),
    }
  end
  local cancelTextRect = cancelSource.textRect --[[@as table<string, integer>]]
  return {
    panels = panels,
    controls = {
      cancel = {
        anchor = {
          x = cancelSource.templateAnchor.x + cancelSource.normalSetupOffset.x,
          y = cancelSource.templateAnchor.y + cancelSource.normalSetupOffset.y,
        },
        textRect = {
          x = cancelTextRect.x,
          y = cancelTextRect.y,
          width = cancelTextRect.width,
          height = cancelTextRect.height,
        },
        align = cancelSource.align,
      },
    },
    detail = geometry.detail,
    navigation = geometry.navigation,
    hitboxes = geometry.hitboxes,
    contextMenu = lowerContextMenus(sources.contextButtons),
    badgeAnchors = {
      anchors = sources
        .badges --[[@as table<string, unknown>]]
        .leafAnchors,
      crownAnchor = sources
        .badges --[[@as table<string, unknown>]]
        .crownAnchor,
      leafSequence = sources
        .badges --[[@as table<string, unknown>]]
        .leafSequence,
      crownSequence = sources
        .badges --[[@as table<string, unknown>]]
        .crownSequence,
      paletteBank = sources
        .badges --[[@as table<string, unknown>]]
        .paletteBank,
    },
  }
end

local function renderFrame(charData, paletteColors, cellData, sequence, frameIndex, role, slot)
  local ok, rendered = pcall(
    G2dRasterizer.renderAnimationFrame,
    charData,
    { colors = paletteColors },
    cellData,
    sequence,
    frameIndex,
    { role = role, frame = frameIndex - 1 },
    slot
  )
  if not ok then
    if Errors.is(rendered) then
      ---@cast rendered Errors.Error
      sourceError(role .. " does not rasterize: " .. rendered.message, { role = role, cause = rendered.code })
    end
    error(rendered, 0)
  end
  assert(type(rendered) == "table", "sprite rasterization returns an image")
  return rendered --[[@as { width: integer, height: integer, pixels: string, offset: { x: integer, y: integer } }]]
end

local PLAYBACKS = { forward = "once", forward_loop = "loop", reverse = "once", reverse_loop = "loop" }

local function writeFrame(rendered, durationTicks, path, assets)
  assets[path] = PngWriter.encode(rendered.width, rendered.height, rendered.pixels)
  local visual = { image = path, width = rendered.width, height = rendered.height, durationTicks = durationTicks }
  if rendered.offset.x ~= 0 or rendered.offset.y ~= 0 then
    visual.offset = rendered.offset
  end
  return visual
end

-- Realizes every frame of one animation sequence, retaining source timing,
-- loop origin, and playback. Single-frame sequences publish static
-- playback; the caller selects which sequences enter the manifest.
local function compileSequence(charData, paletteColors, cellData, animation, sequenceNo, role, assets, prefix, slot)
  local sequence = animation.anims[sequenceNo + 1]
  if sequence == nil then
    sourceError(role .. " selects a missing animation sequence", { sequence = sequenceNo })
  end
  assert(sequence ~= nil, "missing animation sequences fail above")
  local playback = PLAYBACKS[sequence.playMode]
  if playback == nil then
    sourceError(role .. " carries an unsupported play mode", { sequence = sequenceNo, playMode = sequence.playMode })
  end
  if #sequence.frames == 1 then
    playback = "static"
  end
  local frames = {}
  for frameIndex, frame in ipairs(sequence.frames) do
    if type(frame.duration) ~= "number" or frame.duration <= 0 or frame.duration % 1 ~= 0 then
      sourceError(role .. " carries non-integral frame timing", { sequence = sequenceNo, frame = frameIndex - 1 })
    end
    local rendered = renderFrame(charData, paletteColors, cellData, sequence, frameIndex, role, slot)
    frames[frameIndex] = writeFrame(
      rendered,
      frame.duration,
      PartyCache.assetDir() .. "/" .. prefix .. "-" .. (frameIndex - 1) .. ".png",
      assets
    )
  end
  return { frames = frames, loopFrom = sequence.loopStartFrameIdx + 1, playback = playback }
end

-- Realizes one sprite group: every listed sequence keeps all its frames.
-- Palette slots come from the audited sprite templates (cursor 0, status 2,
-- held 6); every group reuses its adjacent palette bank member.
local function compileSpriteGroup(archive, group, slot, role, dependencies, assets, prefix, archiveLabel)
  local charData =
    decode("decodeChar", readMember(archive, group.char, role .. "-char", dependencies, archiveLabel), role .. "-char")
  local paletteData = decode(
    "decodePalette",
    readMember(archive, group.palette, role .. "-palette", dependencies, archiveLabel),
    role .. "-palette"
  )
  local cellData =
    decode("decodeCell", readMember(archive, group.cell, role .. "-cell", dependencies, archiveLabel), role .. "-cell")
  local animation = decode(
    "decodeAnimation",
    readMember(archive, group.anim, role .. "-anim", dependencies, archiveLabel),
    role .. "-anim"
  )
  local sequences = {}
  for _, sequenceNo in ipairs(group.sequences) do
    sequences[#sequences + 1] = compileSequence(
      charData,
      paletteData.colors,
      cellData,
      animation,
      sequenceNo,
      role,
      assets,
      prefix .. "-" .. sequenceNo,
      slot
    )
  end
  return { sequences = sequences }
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
  return image
end

local function compileScreens(archive, dependencies, assets)
  local mainChar = decode("decodeChar", readMember(archive, 15, "main-char", dependencies), "main-char")
  local mainPalette = decode("decodePalette", readMember(archive, 16, "main-palette", dependencies), "main-palette")
  local subChar = decode("decodeChar", readMember(archive, 12, "sub-char", dependencies), "sub-char")
  local subPalette = decode("decodePalette", readMember(archive, 13, "sub-palette", dependencies), "sub-palette")
  local detailChar = decode("decodeChar", readMember(archive, 24, "detail-char", dependencies), "detail-char")
  local function realize(memberId, charData, paletteColors, role)
    local screen = decode("decodeScreen", readMember(archive, memberId, role, dependencies), role)
    local image = rasterizeScreen(charData, paletteColors, screen, role)
    local path = PartyCache.assetDir() .. "/" .. role .. ".png"
    assets[path] = PngWriter.encode(image.width, image.height, image.pixels)
    return { image = path, width = image.width, height = image.height }, image
  end
  local backdropMain = realize(17, mainChar, mainPalette.colors, "backdrop-main")
  local backdropSub = realize(14, subChar, subPalette.colors, "backdrop-sub")
  local detailSub = realize(25, detailChar, subPalette.colors, "detail-sub")
  local panelScreen = decode("decodeScreen", readMember(archive, 22, "panel-screen", dependencies), "panel-screen")
  return {
    backdropMain = backdropMain,
    backdropSub = backdropSub,
    detailSub = detailSub,
    panelChar = mainChar,
    panelScreen = panelScreen,
    mainPalette = mainPalette.colors,
  }
end

local function paletteSlice(colors, startColor, count, role)
  if startColor < 0 or count <= 0 or startColor + count > #colors then
    sourceError(role .. " palette range is unavailable", {
      startColor = startColor,
      count = count,
      available = #colors,
    })
  end
  local slice = {}
  for index = 1, count do
    slice[index] = colors[startColor + index]
  end
  return slice
end

local function templateScreen(screen, tileRow, role)
  local columns = screen.width / 8
  local rows = screen.height / 8
  local tilesWide = PartySources.panelTemplates.tilesWide
  local tilesHigh = PartySources.panelTemplates.tilesHigh
  if
    screen.width % 8 ~= 0
    or screen.height % 8 ~= 0
    or columns < tilesWide
    or tileRow < 0
    or tileRow + tilesHigh > rows
    or #screen.entries ~= columns * rows
  then
    sourceError(role .. " panel template geometry is malformed", { width = screen.width, height = screen.height })
  end
  local entries = {}
  for row = 0, tilesHigh - 1 do
    for column = 0, tilesWide - 1 do
      local source = screen.entries[(tileRow + row) * columns + column + 1]
      entries[#entries + 1] = {
        tile = source.tile,
        flipH = source.flipH,
        flipV = source.flipV,
        palette = 0,
      }
    end
  end
  return { width = tilesWide * 8, height = tilesHigh * 8, entries = entries }
end

local function compileHpBars(mainPalette, assets)
  local config = PartySources.panelPalette
  local bars = {}
  for name, selection in pairs(config.hpBars) do
    local colors = paletteSlice(mainPalette, config.firstColor + selection.bank * 16, 16, "HP " .. name)
    local edge, body = colors[selection.edge + 1], colors[selection.body + 1]
    if edge == nil or body == nil then
      sourceError("HP strip palette entries are unavailable", { color = name })
    end
    assert(edge ~= nil and body ~= nil, "missing HP palette entries fail above")
    local edgePixel = string.char(edge.r, edge.g, edge.b, 255)
    local bodyPixel = string.char(body.r, body.g, body.b, 255)
    local pixels = string.rep(edgePixel, 48)
      .. string.rep(bodyPixel, 48)
      .. string.rep(bodyPixel, 48)
      .. string.rep(edgePixel, 48)
    local path = PartyCache.assetDir() .. "/hp-" .. name .. ".png"
    assets[path] = PngWriter.encode(48, 4, pixels)
    bars[name] = { image = path, width = 48, height = 4 }
  end
  return bars
end

local function compilePanels(panelChar, panelScreen, mainPalette, geometry, assets)
  local templates = {}
  local paletteConfig = PartySources.panelPalette
  for _, row in ipairs(PartySources.panelTemplates.rows) do
    if row.use == "aux" then
      local emptyColors = paletteSlice(mainPalette, paletteConfig.emptyBank * 16, 16, "empty panel")
      local screen = templateScreen(panelScreen, row.tileRow, "empty")
      local image = rasterizeScreen(panelChar, emptyColors, screen, "panel-empty")
      local path = PartyCache.assetDir() .. "/panel-aux.png"
      assets[path] = PngWriter.encode(image.width, image.height, image.pixels)
      templates.aux = { image = path, width = image.width, height = image.height }
    else
      local variants = {}
      local screen = templateScreen(panelScreen, row.tileRow, "panel-" .. row.use)
      for state, relativeBank in pairs(paletteConfig.stateBanks) do
        local colors = paletteSlice(
          mainPalette,
          paletteConfig.firstColor + relativeBank * 16,
          16,
          "panel " .. row.use .. " " .. state
        )
        local image = rasterizeScreen(panelChar, colors, screen, "panel-" .. row.use .. "-" .. state)
        local path = PartyCache.assetDir() .. "/panel-" .. row.use .. "-" .. state .. ".png"
        assets[path] = PngWriter.encode(image.width, image.height, image.pixels)
        variants[state] = { image = path, width = image.width, height = image.height }
      end
      templates[row.use] = variants
    end
  end
  local panels = {}
  for slot, panel in ipairs(geometry.panels) do
    local record = panel --[[@as table<string, unknown>]]
    local templateRole = PartySources.geometry.panels[slot].template
    local chrome = templates[templateRole]
    if chrome == nil then
      sourceError("panel template is missing", { slot = slot, template = templateRole })
    end
    panels[slot] = {
      origin = record.origin,
      size = { width = 128, height = 48 },
      iconAnchor = record.iconAnchor,
      ballAnchor = record.ballAnchor,
      heldAnchor = record.heldAnchor,
      capsuleAnchor = record.capsuleAnchor,
      statusRect = record.statusRect,
      cursorSequence = record.cursorSequence,
      chrome = chrome,
      text = record.text,
      hp = record.hp,
      compat = record.compat,
    }
  end
  return panels, templates.aux
end

local function bakeGlyphTile(tiles, tileIndex, widthTiles, fg, shadow)
  local out = {}
  for y = 0, 7 do
    for tile = 0, widthTiles - 1 do
      for x = 0, 7 do
        local byte = string.byte(tiles, (tileIndex + tile) * 32 + y * 4 + math.floor(x / 2) + 1)
        local value = x % 2 == 0 and byte % 16 or math.floor(byte / 16)
        if value == 1 then
          out[#out + 1] = string.char(fg.r, fg.g, fg.b, 255)
        elseif value == 2 then
          out[#out + 1] = string.char(shadow.r, shadow.g, shadow.b, 255)
        else
          out[#out + 1] = string.char(0, 0, 0, 0)
        end
      end
    end
  end
  return table.concat(out)
end

-- Recolors the fixed numeric glyph masks through the resolved party text
-- ink (roles carries the foreground/shadow pair): every opaque digit/slash/
-- level pixel belongs to the ordinary nickname role, matching the source
-- party message printer.
local function compileNumeric(fontArchive, dependencies, assets, roles)
  assert(
    type(roles) == "table" and type(roles.foreground) == "table" and type(roles.shadow) == "table",
    "numeric glyphs require the resolved party text ink"
  )
  local member = readMember(fontArchive, PartySources.numeric.member, "numeric-font", dependencies, "font")
  local font = decode("decodeChar", member, "numeric-font")
  if font.depth ~= 3 then
    sourceError("numeric font is not 4bpp", { depth = font.depth })
  end
  local tileCount = math.floor(#font.tiles / 32)
  if tileCount < 13 then
    sourceError("numeric font carries too few cells", { tiles = tileCount })
  end
  local fg, shadow = roles.foreground, roles.shadow
  local digits = {}
  for digit = 0, 9 do
    local pixels = bakeGlyphTile(font.tiles, digit, 1, fg, shadow)
    local path = PartyCache.assetDir() .. "/digit-" .. digit .. ".png"
    assets[path] = PngWriter.encode(8, 8, pixels)
    digits[digit + 1] = { image = path, width = 8, height = 8 }
  end
  local slashPath = PartyCache.assetDir() .. "/slash.png"
  assets[slashPath] = PngWriter.encode(8, 8, bakeGlyphTile(font.tiles, 10, 1, fg, shadow))
  local levelPath = PartyCache.assetDir() .. "/level.png"
  assets[levelPath] = PngWriter.encode(16, 8, bakeGlyphTile(font.tiles, 11, 2, fg, shadow))
  return {
    advance = PartySources.numeric.digitWidth,
    height = PartySources.numeric.digitHeight,
    digits = digits,
    slash = { image = slashPath, width = 8, height = 8 },
    level = { image = levelPath, width = 16, height = 8 },
    placement = {
      level = {
        x = PartySources.numeric.placement.level.x,
        y = PartySources.numeric.placement.level.y,
      },
      current = {
        x = PartySources.numeric.placement.current.x,
        y = PartySources.numeric.placement.current.y,
      },
      slash = {
        x = PartySources.numeric.placement.slash.x,
        y = PartySources.numeric.placement.slash.y,
      },
      max = { x = PartySources.numeric.placement.max.x, y = PartySources.numeric.placement.max.y },
    },
  }
end

-- Lowers the six shared icon animation sequences into runtime timelines.
-- Each source frame keeps its duration and translation while its cell
-- selects one of the two icon atlas frames; any other cell fails instead of
-- clamping, and every sequence keeps its loop origin and playback.
local function compileIconAnimations(iconArchive, dependencies)
  local animation = decode(
    "decodeAnimation",
    readMember(iconArchive, PartySources.iconShared.animationMember, "icon-animation", dependencies, "icons"),
    "icon-animation"
  )
  if #animation.anims ~= 6 then
    sourceError("icon animation carries an unexpected sequence census", { sequences = #animation.anims })
  end
  local sequences = {}
  for sequenceNo = 1, 6 do
    local source = animation.anims[sequenceNo]
    local total = 0
    local timeline = {}
    for frameIndex, frame in ipairs(source.frames) do
      if frame.cell ~= 0 and frame.cell ~= 1 then
        sourceError("icon animation selects a cell outside the two-frame contract", {
          sequence = sequenceNo - 1,
          frame = frameIndex - 1,
          cell = frame.cell,
        })
      end
      if type(frame.duration) ~= "number" or frame.duration <= 0 or frame.duration % 1 ~= 0 then
        sourceError("icon animation carries non-integral frame timing", {
          sequence = sequenceNo - 1,
          frame = frameIndex - 1,
        })
      end
      for _, axis in ipairs({ "translateX", "translateY" }) do
        if type(frame[axis]) ~= "number" or frame[axis] % 1 ~= 0 then
          sourceError("icon animation carries non-integral translation", {
            sequence = sequenceNo - 1,
            frame = frameIndex - 1,
          })
        end
      end
      total = total + frame.duration
      timeline[frameIndex] = {
        iconFrame = frame.cell + 1,
        durationTicks = frame.duration,
        translateX = frame.translateX,
        translateY = frame.translateY,
      }
    end
    if total ~= PartySources.iconPeriods[sequenceNo] then
      sourceError("icon animation breaks its audited period", {
        sequence = sequenceNo - 1,
        ticks = total,
        expected = PartySources.iconPeriods[sequenceNo],
      })
    end
    local playback = PLAYBACKS[source.playMode]
    if playback == nil then
      sourceError("icon animation carries an unsupported play mode", {
        sequence = sequenceNo - 1,
        playMode = source.playMode,
      })
    end
    if #source.frames == 1 then
      playback = "static"
    end
    if source.loopStartFrameIdx < 0 or source.loopStartFrameIdx >= #source.frames then
      sourceError("icon animation carries an unreachable loop origin", { sequence = sequenceNo - 1 })
    end
    timeline.loopFrom = source.loopStartFrameIdx + 1
    timeline.playback = playback
    sequences[sequenceNo] = timeline
  end
  return sequences
end

-- Resolves the producer text-role slots to RGBA role tables while the party
-- window palette is available. Records carry detached byte channels, never
-- palette indices.
local function resolveTextRoles(mainPalette)
  local config = PartySources.textRoles --[[@as table<string, unknown>]]
  local bank = paletteSlice(mainPalette, config.bank --[[@as integer]] * 16, 16, "party text")
  local function role(slots, name)
    local picked = slots --[[@as integer[] ]]
    local colors = {}
    for position, slot in ipairs(picked) do
      local color = bank[slot + 1]
      if color == nil then
        sourceError("party text role slot is unavailable", { role = name, slot = slot })
      end
      assert(color ~= nil, "missing text role entries fail above")
      colors[position] = { r = color.r, g = color.g, b = color.b, a = 255 }
    end
    return { foreground = colors[1], shadow = colors[2], background = colors[3] }
  end
  return {
    ordinary = role(config.ordinary, "ordinary"),
    male = role(config.male, "male"),
    female = role(config.female, "female"),
  }
end

-- Resolves the context-button text roles against the button-window
-- palette bank. Command and cancel entries share the bright ink pair
-- while field entries keep their own ink; every role keeps its
-- raised/depressed foreground/shadow/background triple. Records carry
-- detached byte channels, never palette indices.
local function resolveContextPalettes(mainPalette)
  local config = PartySources.contextRoles --[[@as table<string, unknown>]]
  local bank = paletteSlice(mainPalette, config.bank --[[@as integer]] * 16, 16, "context buttons")
  local function pick(slot, name)
    local color = bank[slot + 1]
    if color == nil then
      sourceError("context button role slot is unavailable", { role = name, slot = slot })
    end
    assert(color ~= nil, "missing button role entries fail above")
    return { r = color.r, g = color.g, b = color.b, a = 255 }
  end
  local function role(triples, name)
    local states = triples --[[@as table<string, integer[]>]]
    local resolved = {}
    for _, state in ipairs({ "raised", "depressed" }) do
      local slots = states[state]
      if type(slots) ~= "table" or #slots ~= 3 then
        sourceError("context button role keeps a foreground/shadow/background triple", { role = name, state = state })
      end
      resolved[state] = {
        foreground = pick(slots[1], name .. ".foreground"),
        shadow = pick(slots[2], name .. ".shadow"),
        background = pick(slots[3], name .. ".background"),
      }
    end
    return resolved
  end
  return {
    textRoles = {
      command = role(config.command, "command"),
      field = role(config.field, "field"),
      cancel = role(config.cancel, "cancel"),
    },
  }
end

-- Composes one context-frame image from member-26 source tiles: the corner
-- tiles pin the corners while the edge tiles repeat along each side, so
-- pixel art never scales. The interior stays transparent for the runtime
-- window fill and text. Every decoded source pixel is preserved one-to-one:
-- transparent source margins stay transparent and no new color appears.
local function composeContextFrame(tiles, tileIds, bank, width, height, role)
  local cells = {}
  local function setPixel(x, y, value)
    if value == 0 then
      cells[y * width + x + 1] = string.char(0, 0, 0, 0)
    else
      local color = bank[value + 1]
      if color == nil then
        sourceError(role .. " references a missing palette entry", { value = value })
      end
      assert(color ~= nil, "missing frame palette entries fail above")
      cells[y * width + x + 1] = string.char(color.r, color.g, color.b, 255)
    end
  end
  local function tileValue(tileIndex, x, y)
    local byte = string.byte(tiles, tileIndex * 32 + y * 4 + math.floor(x / 2) + 1)
    if x % 2 == 0 then
      return byte % 16
    end
    return math.floor(byte / 16)
  end
  local tilesWide, tilesHigh = width / 8, height / 8
  for ty = 0, tilesHigh - 1 do
    for tx = 0, tilesWide - 1 do
      local tile = nil
      if ty == 0 and tx == 0 then
        tile = tileIds[1]
      elseif ty == 0 and tx == tilesWide - 1 then
        tile = tileIds[2]
      elseif ty == tilesHigh - 1 and tx == 0 then
        tile = tileIds[3]
      elseif ty == tilesHigh - 1 and tx == tilesWide - 1 then
        tile = tileIds[4]
      elseif tx == 0 then
        tile = tileIds[5]
      elseif tx == tilesWide - 1 then
        tile = tileIds[6]
      elseif ty == 0 then
        tile = tileIds[7]
      elseif ty == tilesHigh - 1 then
        tile = tileIds[8]
      end
      if tile ~= nil then
        for y = 0, 7 do
          for x = 0, 7 do
            setPixel(tx * 8 + x, ty * 8 + y, tileValue(tile, x, y))
          end
        end
      end
    end
  end
  local out = {}
  for index = 1, width * height do
    out[index] = cells[index] or string.char(0, 0, 0, 0)
  end
  return table.concat(out)
end

-- Realizes the six context-frame visuals: the standard 128x32 and cancel
-- 56x40 geometries in the raised, selected, and pressed source states.
local function compileContextFrames(archive, mainPalette, dependencies, assets)
  local config = PartySources.contextFrames --[[@as table<string, unknown>]]
  local charData = decode(
    "decodeChar",
    readMember(archive, config.member --[[@as integer]], "context-frame-char", dependencies),
    "context-frame-char"
  )
  if charData.depth ~= 3 then
    sourceError("context frames are not 4bpp", { depth = charData.depth })
  end
  local tileCount = math.floor(#charData.tiles / 32)
  local bank = paletteSlice(mainPalette, config.paletteBank --[[@as integer]] * 16, 16, "context frames")
  local bases = config.tileBases --[[@as table<string, integer>]]
  local offsets = config.tileOffsets --[[@as integer[] ]]
  local frames = {}
  for _, shape in ipairs({ "standard", "cancel" }) do
    local width = shape == "standard" and 128 or 56
    local height = shape == "standard" and 32 or 40
    local group = {}
    for _, state in ipairs({ "raised", "selected", "pressed" }) do
      local tileIds = {}
      for position, offset in ipairs(offsets) do
        local tileIndex = bases[state] + offset
        if tileIndex < 0 or tileIndex >= tileCount then
          sourceError("context frame escapes its source tiles", { shape = shape, state = state })
        end
        tileIds[position] = tileIndex
      end
      local pixels = composeContextFrame(charData.tiles, tileIds, bank, width, height, shape .. " " .. state)
      local path = PartyCache.assetDir() .. "/context-" .. shape .. "-" .. state .. ".png"
      assets[path] = PngWriter.encode(width, height, pixels)
      group[state] = { image = path, width = width, height = height }
    end
    frames[shape] = group
  end
  return frames
end

local function compileBadges(badgeArchive, dependencies, assets)
  local paletteData = decode(
    "decodePalette",
    readMember(badgeArchive, PartySources.badges.paletteMember, "badge-palette", dependencies, "badges"),
    "badge-palette"
  )
  local charData = decode(
    "decodeChar",
    readMember(badgeArchive, PartySources.badges.charMember, "badge-char", dependencies, "badges"),
    "badge-char"
  )
  local cellData = decode(
    "decodeCell",
    readMember(badgeArchive, PartySources.badges.cellMember, "badge-cell", dependencies, "badges"),
    "badge-cell"
  )
  local animation = decode(
    "decodeAnimation",
    readMember(badgeArchive, PartySources.badges.animationMember, "badge-anim", dependencies, "badges"),
    "badge-anim"
  )
  local leaves = compileSequence(
    charData,
    paletteData.colors,
    cellData,
    animation,
    PartySources.badges.leafSequence,
    "leaf",
    assets,
    "leaf",
    PartySources.badges.paletteBank
  )
  local crown = compileSequence(
    charData,
    paletteData.colors,
    cellData,
    animation,
    PartySources.badges.crownSequence,
    "crown",
    assets,
    "crown",
    PartySources.badges.paletteBank
  )
  return {
    anchors = PartySources.badges.leafAnchors,
    crownAnchor = PartySources.badges.crownAnchor,
    leafSequence = PartySources.badges.leafSequence,
    crownSequence = PartySources.badges.crownSequence,
    paletteBank = PartySources.badges.paletteBank,
    leaves = leaves,
    crown = crown,
  }
end

local function readMessageBank(archive, bankId, role, dependencies)
  local bytes, err = archive:readMember(bankId)
  if not bytes then
    sourceError("message bank " .. bankId .. " is unreadable: " .. Errors.format(err), { role = role, bank = bankId })
  end
  assert(bytes ~= nil, "unreadable message banks fail above")
  dependencies[#dependencies + 1] = { name = "messages:member:" .. bankId, role = role, sha1 = Hashing.sha1hex(bytes) }
  local bank, bankErr = FieldMessageBank.decode(bytes, { label = "party-message-bank-" .. bankId })
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

local function messageTokens(bank, bankId, index, role)
  local message = bank.messages[index + 1]
  if not message then
    sourceError(
      "message bank " .. bankId .. " carries no message " .. index,
      { role = role, bank = bankId, index = index }
    )
  end
  local tokens, err = FieldMessageTokenizer.tokenize(message.raw, charmap, { bankId = bankId, messageId = index })
  if not tokens then
    assert(err)
    sourceError("party message does not tokenize: " .. err.message, { role = role, bank = bankId, index = index })
  end
  assert(tokens ~= nil, "untokenizable party messages fail above")
  return tokens
end

local function lowerSegments(bank, bankId, index, role, allowFlow)
  local segments = {}
  local pending = {}
  local function flush()
    if #pending > 0 then
      segments[#segments + 1] = { kind = "text", value = table.concat(pending) }
      pending = {}
    end
  end
  local function lineBreak(flow)
    flush()
    if allowFlow then
      segments[#segments + 1] = { kind = "lineBreak", flow = flow }
    else
      segments[#segments + 1] = { kind = "text", value = "\n" }
    end
  end
  for _, token in ipairs(messageTokens(bank, bankId, index, role)) do
    if token.kind == "eos" then
      break
    elseif token.kind == "glyph" then
      pending[#pending + 1] = token.text
    elseif token.kind == "line_break" then
      lineBreak(nil)
    elseif token.kind == "prompt_break" then
      lineBreak("prompt")
    elseif token.kind == "page_break" then
      lineBreak("page")
    elseif token.kind == "substitution" and token.control == NAME_SUBSTITUTION then
      flush()
      segments[#segments + 1] = { kind = "name" }
    elseif token.kind == "substitution" and token.control == MOVE_SUBSTITUTION then
      flush()
      segments[#segments + 1] = { kind = "move" }
    elseif token.kind == "substitution" and token.control == QUANTITY_SUBSTITUTION then
      flush()
      segments[#segments + 1] = { kind = "quantity" }
    else
      sourceError("party text carries an unsupported token " .. tostring(token.kind), {
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
    sourceError("party text has no segments", { role = role, bank = bankId, index = index })
  end
  return { segments = segments }
end

local function compileText(messageArchive, dependencies)
  local bank = readMessageBank(messageArchive, PartySources.messages.bank, "message-bank-300", dependencies)
  local labels = {}
  for name, selector in pairs(PartySources.messages.labels) do
    local lowered = lowerSegments(bank, selector.bank, selector.index, "label:" .. name, false)
    if #lowered.segments ~= 1 or lowered.segments[1].kind ~= "text" then
      sourceError("party label carries a non-display segment", { label = name })
    end
    labels[name] = lowered.segments[1].value
  end
  local templates = {}
  for name, selector in pairs(PartySources.messages.templates) do
    templates[name] = lowerSegments(bank, selector.bank, selector.index, "template:" .. name, true)
  end
  return { labels = labels, templates = templates }
end

local function verifyHeaders(headerArchive, dependencies)
  local tables = {
    { member = PartySources.headers.animation, records = 16 },
    { member = PartySources.headers.cell, records = 16 },
    { member = PartySources.headers.char, records = 26 },
    { member = PartySources.headers.palette, records = 12 },
  }
  for _, spec in ipairs(tables) do
    local bytes = readMember(headerArchive, spec.member, "header-" .. spec.member, dependencies, "headers")
    if #bytes ~= 4 + spec.records * 12 then
      sourceError("resource header carries an unexpected record census", { member = spec.member, bytes = #bytes })
    end
  end
  local graphics = readMember(headerArchive, PartySources.headers.graphics, "header-graphics", dependencies, "headers")
  if #graphics ~= 416 then
    sourceError("graphics header carries an unexpected size", { bytes = #graphics })
  end
end

local function compileDecoration(archive, mainPaletteColors, dependencies, assets)
  local charData = decode("decodeChar", readMember(archive, 26, "decoration-char", dependencies), "decoration-char")
  local tileCount = math.floor(#charData.tiles / 32)
  if tileCount == 0 then
    sourceError("decoration carries no tiles", {})
  end
  local stride = math.min(tileCount, 16)
  local rows = math.ceil(tileCount / 16)
  local out = {}
  for row = 0, rows - 1 do
    for y = 0, 7 do
      for col = 0, stride - 1 do
        local tile = row * 16 + col
        for x = 0, 7 do
          if tile < tileCount then
            local byte = string.byte(charData.tiles, tile * 32 + y * 4 + math.floor(x / 2) + 1)
            local value = x % 2 == 0 and byte % 16 or math.floor(byte / 16)
            if value == 0 then
              out[#out + 1] = string.char(0, 0, 0, 0)
            else
              local color = mainPaletteColors[value + 1]
              if color == nil then
                sourceError("decoration references a missing palette entry", { value = value })
              end
              assert(color ~= nil, "missing decoration palette entries fail above")
              out[#out + 1] = string.char(color.r, color.g, color.b, 255)
            end
          else
            out[#out + 1] = string.char(0, 0, 0, 0)
          end
        end
      end
    end
  end
  local path = PartyCache.assetDir() .. "/decoration.png"
  assets[path] = PngWriter.encode(stride * 8, rows * 8, table.concat(out))
  return { image = path, width = stride * 8, height = rows * 8 }
end

local function openArchive(romFs, symbol, role)
  local archive, err = romFs:openNarc(symbol)
  if not archive then
    sourceError("the " .. role .. " archive does not open: " .. Errors.format(err), {})
  end
  assert(archive ~= nil, "unopenable archives fail above")
  return archive
end

local function _compile(romFs)
  if
    romFs == nil
    or type(romFs.metadata) ~= "function"
    or type(romFs.openNarc) ~= "function"
    or type(romFs.resolvedNarc) ~= "function"
  then
    sourceError("party compilation requires source metadata and archive reader", {})
  end
  local metadata = romFs:metadata()
  assert(type(metadata) == "table" and type(metadata.sha1) == "string", "party source metadata must carry sha1")
  local dependencies = {
    { name = "assetContract", sha1 = PartyCache.FORMAT .. ":" .. PartyCache.SCHEMA },
  }
  local archive = openArchive(romFs, PartySources.archive.symbol, "party")
  if archive:memberCount() ~= PartySources.archive.memberCount then
    sourceError("the party archive carries an unexpected member census", { members = archive:memberCount() })
  end
  local headerArchive = openArchive(romFs, PartySources.headerArchive.symbol, "resource header")
  verifyHeaders(headerArchive, dependencies)
  local messageArchive = openArchive(romFs, PartySources.messages.archiveSymbol, "message")
  local fontArchive = openArchive(romFs, PartySources.numeric.fontSymbol, "font")
  local statusArchive = openArchive(romFs, PartySources.statusArchive.symbol, "status")
  local feedbackArchive = openArchive(romFs, PartySources.feedbackArchive.symbol, "feedback")
  local badgeArchive = openArchive(romFs, PartySources.badges.archiveSymbol, "badge")
  local assets = {}
  local geometry = PartyAssetCompiler.compileGeometry(PartySources)
  local screens = compileScreens(archive, dependencies, assets)
  local panels, auxPanel = compilePanels(screens.panelChar, screens.panelScreen, screens.mainPalette, geometry, assets)
  local hpBars = compileHpBars(screens.mainPalette, assets)
  local ballGroup = { char = 2, palette = 8, cell = 1, anim = 0, sequences = { 0, 1 } }
  local cursorGroup = { char = 7, palette = 8, cell = 6, anim = 5, sequences = { 0, 1, 2, 3 } }
  local buttonGroup = { char = 11, palette = 8, cell = 10, anim = 9, sequences = { 0, 1, 2, 3 } }
  local heldGroup = { char = 20, palette = 21, cell = 19, anim = 18, sequences = { 0, 1, 2 } }
  local balls = compileSpriteGroup(archive, ballGroup, 0, "ball", dependencies, assets, "ball")
  local cursor = compileSpriteGroup(archive, cursorGroup, 0, "cursor", dependencies, assets, "cursor")
  local buttons = compileSpriteGroup(archive, buttonGroup, 0, "button", dependencies, assets, "button")
  local held = compileSpriteGroup(archive, heldGroup, 6, "held", dependencies, assets, "held")
  local statusChar = decode(
    "decodeChar",
    readMember(statusArchive, PartySources.status.charMember, "status-char", dependencies, "status"),
    "status-char"
  )
  local statusPalette = decode(
    "decodePalette",
    readMember(statusArchive, PartySources.status.paletteMember, "status-palette", dependencies, "status"),
    "status-palette"
  )
  local statusCell = decode(
    "decodeCell",
    readMember(statusArchive, PartySources.status.cellMember, "status-cell", dependencies, "status"),
    "status-cell"
  )
  local statusAnimation = decode(
    "decodeAnimation",
    readMember(statusArchive, PartySources.status.animationMember, "status-anim", dependencies, "status"),
    "status-anim"
  )
  if #statusAnimation.anims ~= 7 then
    sourceError("status carries an unexpected sequence census", { sequences = #statusAnimation.anims })
  end
  local statusVisuals = {}
  for _, statusRecord in ipairs(PartySources.status.semanticSequences) do
    local semanticKey = statusRecord.key
    local sequenceNo = statusRecord.sequence
    local compiled = compileSequence(
      statusChar,
      statusPalette.colors,
      statusCell,
      statusAnimation,
      sequenceNo,
      "status",
      assets,
      "status-" .. semanticKey,
      2
    )
    if #compiled.frames ~= 1 then
      sourceError("status carries an animated sequence", { sequence = sequenceNo })
    end
    local frame = compiled.frames[1]
    if frame.width ~= 24 or frame.height ~= 8 then
      sourceError("status label escapes 24x8", { sequence = sequenceNo, width = frame.width, height = frame.height })
    end
    statusVisuals[semanticKey] = { image = frame.image, width = frame.width, height = frame.height }
  end
  local feedbackChar = decode(
    "decodeChar",
    readMember(feedbackArchive, PartySources.feedback.charMember, "feedback-char", dependencies, "feedback"),
    "feedback-char"
  )
  local feedbackPalette = decode(
    "decodePalette",
    readMember(archive, PartySources.feedback.paletteMember, "feedback-palette", dependencies),
    "feedback-palette"
  )
  local feedbackCell = decode(
    "decodeCell",
    readMember(feedbackArchive, PartySources.feedback.cellMember, "feedback-cell", dependencies, "feedback"),
    "feedback-cell"
  )
  local feedbackAnimation = decode(
    "decodeAnimation",
    readMember(feedbackArchive, PartySources.feedback.animationMember, "feedback-anim", dependencies, "feedback"),
    "feedback-anim"
  )
  local feedbackSequence = feedbackAnimation.anims[PartySources.feedback.sequence + 1]
  if feedbackSequence == nil then
    sourceError("feedback selects a missing sequence", { sequence = PartySources.feedback.sequence })
  end
  assert(feedbackSequence ~= nil, "missing feedback sequences fail above")
  for index, want in ipairs(PartySources.feedback.durations) do
    local frame = feedbackSequence.frames[index]
    if frame == nil or frame.duration ~= want then
      sourceError("feedback breaks its 3/2/1 cadence", { frame = index - 1 })
    end
  end
  local feedbackFrames = {}
  for frameIndex = 1, 2 do
    local rendered =
      renderFrame(feedbackChar, feedbackPalette.colors, feedbackCell, feedbackSequence, frameIndex, "feedback", 0)
    feedbackFrames[frameIndex] = writeFrame(
      rendered,
      feedbackSequence.frames[frameIndex].duration,
      PartyCache.assetDir() .. "/feedback-" .. (frameIndex - 1) .. ".png",
      assets
    )
  end
  local iconArchive = openArchive(romFs, PartySources.iconShared.archive, "icon")
  local iconSequences = compileIconAnimations(iconArchive, dependencies)
  local textRoles = resolveTextRoles(screens.mainPalette)
  local contextPalettes = resolveContextPalettes(screens.mainPalette)
  local contextFrames = compileContextFrames(archive, screens.mainPalette, dependencies, assets)
  local numberGlyphs = compileNumeric(fontArchive, dependencies, assets, textRoles.ordinary)
  local shinyLeaves = compileBadges(badgeArchive, dependencies, assets)
  local text = compileText(messageArchive, dependencies)
  text.roles = textRoles
  local decoration = compileDecoration(archive, screens.mainPalette, dependencies, assets)
  local controlsGeometry = geometry.controls --[[@as table<string, unknown>]]
  local cancelGeometry = controlsGeometry.cancel --[[@as table<string, unknown>]]
  local menuGeometry = geometry.contextMenu --[[@as table<string, unknown>]]
  local controls = {
    cancel = {
      anchor = cancelGeometry.anchor,
      label = text.labels.cancel,
      textRect = cancelGeometry.textRect,
      align = cancelGeometry.align,
    },
  }
  local manifest = {
    schema = PartyAssetSchema.SCHEMA,
    panes = {
      main = { width = PartyAssetSchema.PANE_WIDTH, height = PartyAssetSchema.PANE_HEIGHT },
      sub = { width = PartyAssetSchema.PANE_WIDTH, height = PartyAssetSchema.PANE_HEIGHT },
    },
    panels = panels,
    controls = controls,
    detail = geometry.detail,
    windows = PartySources.windows,
    visuals = {
      cursor = cursor,
      balls = balls,
      buttons = buttons,
      held = held,
      status = statusVisuals,
      feedback = { frames = feedbackFrames, loopFrom = 1, playback = "once", hideAtFrame = 3 },
      hpBars = hpBars,
      backdropMain = screens.backdropMain,
      backdropSub = screens.backdropSub,
      detailSub = screens.detailSub,
      decoration = decoration,
      auxPanel = auxPanel,
    },
    iconAnimations = { sequences = iconSequences },
    contextMenu = {
      topLevel = menuGeometry.topLevel,
      subcontext = menuGeometry.subcontext,
      textRoles = contextPalettes.textRoles,
      frames = contextFrames,
    },
    navigation = { dpad = PartySources.geometry.dpad },
    hitboxes = { touch = PartySources.geometry.touch },
    text = text,
    numberGlyphs = numberGlyphs,
    shinyLeaves = shinyLeaves,
  }
  local ok, err = pcall(PartyAssetSchema.assertManifest, manifest)
  if not ok then
    sourceError("compiled party manifest is invalid: " .. Errors.format(err), {})
  end
  local dependencyRecord = {
    cacheFormat = PartyCache.FORMAT,
    schema = PartyCache.SCHEMA,
    versionRomSha1 = metadata.sha1,
    source = PartySources.provenance,
    selection = PartySources,
    dependencies = dependencies,
  }
  return {
    marker = PartyCache.marker(metadata.sha1, Hashing.hashLua(dependencyRecord)),
    manifest = manifest,
    dependencies = dependencyRecord,
    assets = assets,
  }
end

---@param romFs RomFs
---@return table<string, unknown>|nil bundle
---@return Errors.Error?
function PartyAssetCompiler.compile(romFs)
  assert(romFs and romFs.read and romFs.openNarc and romFs.resolvedNarc, "compile requires a RomFs-shaped object")
  local ok, result = xpcall(_compile, function(e)
    if Errors.is(e) then
      return e
    end
    return { raw = e, trace = debug.traceback("", 2) }
  end, romFs)
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

return PartyAssetCompiler
