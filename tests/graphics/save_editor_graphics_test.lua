-- Render and inspect the editor's canonical targets across measured topologies.

local Assert = require("tests.support.Assert")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local ApplicationPresentation = require("libs.ui.src.ApplicationPresentation")
local DisplayContext = require("libs.ui.src.DisplayContext")
local FieldTextRenderer = require("libs.hgss.src.ui.FieldTextRenderer")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local FieldUiAssetCache = require("libs.assets.src.field.FieldUiAssetCache")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local Interface = require("app.src.saveeditor.SaveEditorInterface")
local Layout = require("app.src.saveeditor.SaveEditorLayout")
local LayoutGeometry = require("libs.ui.src.LayoutGeometry")
local Renderer = require("app.src.saveeditor.SaveEditorRenderer")
local ValueEditor = require("app.src.saveeditor.SaveEditorValueEditor")
local ScreenTopology = require("libs.ui.src.ScreenTopology")

local T = {}
local LONG_FLAG_NAME = "FLAG_HIDE_GOLDENROD_DEPT_STORE_5F_RETURN_FRUSTRATION_LADY"
local LONG_FLAG_DISPLAY_NAME = LONG_FLAG_NAME:gsub("^FLAG_", "")

local function realTextMetrics(scope)
  local fieldText = scope:own(FieldTextRenderer.new({ cacheFs = FieldUiFixture.cacheWithFontAndFrames() }))
  return {
    lineHeight = fieldText.fontDef.lineHeight,
    measure = function(text)
      return fieldText:textWidth(text)
    end,
  }
end

local function fixture(scope, width, height, topology, section, variant, versionId)
  section = section or "Progress"
  local view = {
    status = "ready",
    versionId = versionId or "heartgold",
    saveId = "TEST-SAVE-42",
    section = section,
    ready = true,
    dirty = variant ~= "clean-status",
    focus = variant == "list-selected" and "party:slot:0"
      or variant == "long-flag" and ("flag:" .. LONG_FLAG_NAME)
      or "flag:FLAG_TEST",
    query = "",
    session = {
      playerName = "PLAYER",
      versionId = "HEARTGOLD",
      frameIndex = 0,
      flags = {},
      location = { fieldX = 32, fieldZ = 48 },
    },
    flagRows = {
      variant == "long-flag" and {
        name = LONG_FLAG_NAME,
        displayName = LONG_FLAG_DISPLAY_NAME,
        id = FieldScriptSymbols.flagsByName[LONG_FLAG_NAME],
        value = false,
      } or { name = "FLAG_TEST", displayName = "TEST", id = 1, value = false },
    },
    flagFilter = "Named",
    flagGroupLabel = "Named",
    scope = {
      id = "section:" .. section,
      epoch = 1,
      kind = "section",
      focusId = variant == "long-flag" and ("flag:" .. LONG_FLAG_NAME) or "flag:FLAG_TEST",
    },
    textMetrics = realTextMetrics(scope),
  }
  if section == "Player" and variant == "leave" then
    view.modal = "leave"
    view.scope = { id = "modal:leave", epoch = 2, kind = "decision", focusId = "cancel" }
  end
  if section == "Party" then
    view.partyPage = variant
    if variant == "draft-summary" or variant == "stats-table" then
      view.partyPage = "draft"
    elseif variant == "list-selected" then
      view.partyPage = "list"
    elseif variant == nil then
      view.partyPage = "list"
    end
    if view.partyPage == "list" then
      view.partyCanAdd = true
      view.partyMemberCount = 1
      view.partyCards = {
        { kind = "member", slot0 = 0, label = "Pikachu", species = "Pikachu", level = 25 },
        { kind = "add", slot0 = 1, label = "Add Pokemon" },
      }
    else
      view.partyDirty = true
      view.partyValid = false
      view.partySubpage = variant == "stats-table" and "Stats" or "Identity"
      view.partySubpages = { "Identity", "Training", "Stats", "Moves", "Origin" }
      view.partyRows = {
        {
          role = "named choice",
          targetId = "party:field:species",
          id = "species",
          label = "Species",
          value = "PIKACHU",
        },
        {
          role = "integer value",
          targetId = "party:field:personality",
          id = "personality",
          label = "Personality",
          value = 123456789,
        },
        {
          role = "read-only value",
          targetId = "party:readonly:nature",
          id = "nature",
          label = "Nature",
          value = "Hardy",
        },
        { role = "warning", targetId = "party:validation", label = "HP exceeds calculated maximum" },
      }
      if variant == "draft-summary" then
        view.partySummary = {
          label = "Chikorita",
          species = "Chikorita",
          level = 5,
          iconKey = "party/chikorita",
        }
      end
      if variant == "stats-table" then
        view.focus = "party:field:iv:attack"
        view.statsTable = { rows = {}, facts = {} }
        for index, pair in ipairs({
          { "hp", "HP" },
          { "attack", "Attack" },
          { "defense", "Defense" },
          { "speed", "Speed" },
          { "specialAttack", "Sp. Atk" },
          { "specialDefense", "Sp. Def" },
        }) do
          local key, label = pair[1], pair[2]
          view.statsTable.rows[index] = {
            key = key,
            label = label,
            iv = index,
            ivEditor = { targetId = "party:field:iv:" .. key, editor = { kind = "integer" } },
            ev = index * 2,
            evEditor = { targetId = "party:field:ev:" .. key, editor = { kind = "integer" } },
            derived = index * 10,
          }
        end
        view.statsTable.facts = {
          { id = "currentHp", label = "Current HP", value = 12, editor = { kind = "integer" } },
          { id = "status", label = "Status", value = 0, editor = { kind = "integer" } },
          { id = "ev-total", label = "EV total", value = 42 },
          { id = "ev-limit", label = "EV limit", value = "510" },
        }
      end
    end
  elseif section == "Bag" then
    view.focus = variant == "bag-cards" and "bag:item:POTION" or "bag:pocket:items"
    view.bagPocket = "items"
    view.bagSelectedItem = "POTION"
    view.bagSelectedQuantity = 2
    local keys = { "items", "medicine", "balls", "battle_items", "berries", "mail", "key_items", "machines" }
    view.bagPockets, view.bagPocketTabRects = {}, {}
    for index, key in ipairs(keys) do
      view.bagPockets[index] = { key = key }
      view.bagPocketTabRects[index] = { x = (index - 1) * 32, y = 0, width = 32, height = 32 }
    end
    view.bagPocketStrip = { image = "bag/items-strip" }
    view.bagRows = {
      {
        item = "POTION",
        iconKey = "POTION",
        label = variant == "bag-cards" and "Potion with an intentionally long display name" or "Potion",
        description = variant == "bag-cards"
            and "Restores a small amount of HP and remains useful for a much longer description OVERFLOW_SENTINEL"
          or "Restores a small amount of HP.",
        quantity = 2,
      },
    }
    if variant == "bag-cards" then
      view.bagRows[2] = { item = "ANTIDOTE", label = "Antidote", description = "Cures poison.", quantity = 1 }
    end
    if variant == "bag-pages" then
      for index = 2, 7 do
        view.bagRows[index] =
          { item = "ITEM_" .. index, label = "Item " .. index, description = "Item description.", quantity = 1 }
      end
    end
    view.bagPageRows = {}
    for index = 1, math.min(6, #view.bagRows) do
      view.bagPageRows[index] = view.bagRows[index]
    end
    view.bagPage0, view.bagPageCount, view.bagAddEnabled = 0, variant == "bag-pages" and 2 or 1, true
    view.bagItemFocusVisual = { image = "bag/item-focus", offset = { x = -9, y = -6 } }
    view.bagQuantityVisuals = {
      decrement = { normal = { image = "bag/dec-normal" }, pressed = { image = "bag/dec-pressed" } },
      increment = { normal = { image = "bag/inc-normal" }, pressed = { image = "bag/inc-pressed" } },
    }
    view.numberControlVisuals = view.bagQuantityVisuals
    view.numberControls = {
      { delta = 100, role = "increment", hitRect = { x = 120, y = 88, width = 32, height = 24 } },
      { delta = 10, role = "increment", hitRect = { x = 152, y = 88, width = 32, height = 24 } },
      { delta = 1, role = "increment", hitRect = { x = 184, y = 88, width = 32, height = 24 } },
      { delta = -100, role = "decrement", hitRect = { x = 120, y = 136, width = 32, height = 24 } },
      { delta = -10, role = "decrement", hitRect = { x = 152, y = 136, width = 32, height = 24 } },
      { delta = -1, role = "decrement", hitRect = { x = 184, y = 136, width = 32, height = 24 } },
    }
    if variant == "quantity-normal" or variant == "quantity-pressed" then
      view.valueEditor = { kind = "number", buffer = "2", parsedValue = 2, minimum = 1, maximum = 999 }
      view.focus = "number:delta:1"
      view.numberHoldTarget = variant == "quantity-pressed" and "number:delta:1" or nil
      view.scope = { id = "value:bag_quantity", epoch = 2, kind = "value", focusId = view.focus }
    end
  elseif section == "Location" then
    view.location = {
      mapId = 12,
      symbol = "MAP_AZALEA_ILEX_FOREST_GATEHOUSE",
      displayName = "AZALEA_ILEX_FOREST_GATEHOUSE",
      section = "TEST_SECTION",
      map = { symbol = "MAP_AZALEA_ILEX_FOREST_GATEHOUSE" },
      maps = {
        {
          mapId = 12,
          symbol = "MAP_AZALEA_ILEX_FOREST_GATEHOUSE",
          displayName = "AZALEA_ILEX_FOREST_GATEHOUSE",
          section = "TEST_SECTION",
        },
      },
      generation = 1,
      status = { state = "ready" },
      original = { fieldX = 31, fieldZ = 48 },
      draft = { fieldX = 32, fieldZ = 48 },
      tiles = {
        { fieldX = 32, fieldZ = 48, selectable = true },
        { fieldX = 33, fieldZ = 48, selectable = false, reason = "blocked" },
      },
      cursor = { fieldX = 33, fieldZ = 48 },
      original = { fieldX = 31, fieldZ = 48 },
      draft = { fieldX = 32, fieldZ = 48 },
      scale = 16,
    }
    view.locationNavigation = {
      page = (variant == "map-list" or (variant or ""):match("^map%-list%-long%-query") ~= nil) and "map-list"
        or "grid",
      contentFocus = (variant == "map-list" or (variant or ""):match("^map%-list%-long%-query") ~= nil) and "map-list"
        or "grid",
      mapId = 12,
      cursor = { fieldX = 33, fieldZ = 48 },
      center = { fieldX = 32, fieldZ = 48 },
      scale = 16,
      mapOffset = 0,
    }
    if (variant or ""):match("^map%-list%-long%-query") ~= nil then
      view.query = string.rep("very-long-search-query", 12)
      view.focus = variant == "map-list-long-query" and "location:map-picker"
        or variant == "map-list-long-query-back-focused" and "location:map-back"
        or "location:grid"
    end
    view.savedLocation = { mapId = 12, fieldX = 31, fieldZ = 48 }
    view.pendingLocation = { mapId = 12, fieldX = 32, fieldZ = 48 }
  end
  if variant == "choice-list" then
    local options = {}
    for index = 1, 12 do
      options[index] = { key = string.format("choice-%02d", index), label = "Choice " .. index }
    end
    view.focus = "choice:choice-01"
    view.valueEditor = {
      kind = "choice",
      purpose = "species",
      options = options,
      selectedKey = "choice-01",
      query = "",
    }
    view.scope = { id = "value:choice:species", epoch = 2, kind = "value", focusId = view.focus }
  elseif variant == "number-modal" then
    view.focus = "confirm"
    view.numberControls = {
      { delta = 100, role = "increment", hitRect = { x = 120, y = 88, width = 32, height = 24 } },
      { delta = 10, role = "increment", hitRect = { x = 152, y = 88, width = 32, height = 24 } },
      { delta = 1, role = "increment", hitRect = { x = 184, y = 88, width = 32, height = 24 } },
      { delta = -100, role = "decrement", hitRect = { x = 120, y = 136, width = 32, height = 24 } },
      { delta = -10, role = "decrement", hitRect = { x = 152, y = 136, width = 32, height = 24 } },
      { delta = -1, role = "decrement", hitRect = { x = 184, y = 136, width = 32, height = 24 } },
    }
    view.numberControlVisuals = {
      increment = { normal = { image = "bag/inc-normal" }, pressed = { image = "bag/inc-pressed" } },
      decrement = { normal = { image = "bag/dec-normal" }, pressed = { image = "bag/dec-pressed" } },
    }
    view.valueEditor = {
      kind = "number",
      buffer = "123",
      parsedValue = 123,
      minimum = 0,
      maximum = 999,
      base = "decimal",
    }
    view.scope = { id = "value:integer:money", epoch = 2, kind = "value", focusId = view.focus }
  end
  local context = DisplayContext.new({
    graphics = love.graphics,
    topologyProvider = function()
      return topology
    end,
  })
  local presentation = ApplicationPresentation.new(Interface.defaults())
  local plan = presentation:resolve(context:measure(width, height), view)
  view.presentation = plan
  view.layout = plan.content.layout
  return view, presentation, plan
end

local function draw(scope, width, height, topology, name, section, variant, versionId, beforeDraw)
  local graphics = love.graphics
  local view, presentation, plan = fixture(scope, width, height, topology, section, variant, versionId)
  local drawnText = {}
  local paletteCalls = {}
  local text = {
    fontDef = { lineHeight = 14 },
    textWidth = function(_, value)
      return view.textMetrics.measure(value)
    end,
    drawTextWithPalette = function(_, value, x, y, palette)
      drawnText[#drawnText + 1] = value
      paletteCalls[#paletteCalls + 1] = { value = value, x = x, y = y, palette = palette }
      graphics.print(value, x, y)
    end,
    drawText = function(_, value, x, y)
      drawnText[#drawnText + 1] = value
      paletteCalls[#paletteCalls + 1] = { value = value, x = x, y = y, palette = nil }
      graphics.print(value, x, y)
    end,
  }
  local renderer = Renderer.new({ text = text, versionId = view.versionId })
  local frameCache = FieldUiFixture.cacheWithFontAndFrames()
  renderer:preparePresentationAssets(frameCache, assert(frameCache:loadLua(FieldUiAssetCache.manifestPath())))
  local bagDrawn = {}
  local bagDrawOrder = {}
  if view.section == "Bag" then
    renderer._bagImages = {}
    for index, path in ipairs({
      "bag/items-strip",
      "bag/dec-normal",
      "bag/dec-pressed",
      "bag/inc-normal",
      "bag/inc-pressed",
      "bag/item-focus",
    }) do
      local imageData = love.image.newImageData(index == 1 and 256 or 12, index == 1 and 32 or 12)
      local image = graphics.newImage(imageData)
      renderer._bagImages[path] = image
    end
  end
  if view.valueEditor and view.valueEditor.kind == "number" and view.section ~= "Bag" then
    renderer._bagImages = {}
    local index = 0
    for _, role in ipairs({ "increment", "decrement" }) do
      for _, state in ipairs({ "normal", "pressed" }) do
        index = index + 1
        local visual = view.numberControlVisuals[role][state]
        renderer._bagImages[visual.image] = graphics.newImage(love.image.newImageData(12 + index, 12))
      end
    end
  end
  local canvas = scope:own(graphics.newCanvas(width, height))
  graphics.setCanvas(canvas)
  graphics.clear(0.94, 0.94, 0.94, 1)
  if beforeDraw then
    beforeDraw(renderer, view, plan)
  end
  local originalDraw = graphics.draw
  graphics.draw = function(drawable, ...)
    for path, image in pairs(renderer._bagImages) do
      if drawable == image then
        bagDrawn[path] = true
        bagDrawOrder[#bagDrawOrder + 1] = { path = path, args = { ... } }
      end
    end
    for iconKey, icon in pairs(renderer._icons) do
      if drawable == icon.image then
        bagDrawOrder[#bagDrawOrder + 1] = { path = "icon:" .. iconKey, args = { ... } }
      end
    end
    return originalDraw(drawable, ...)
  end
  ApplicationPresentation.draw(graphics, { renderer = renderer }, view, plan)
  graphics.draw = originalDraw
  graphics.setCanvas()
  local data = scope:own(canvas:newImageData())
  local output =
    io.open(love.filesystem.getSourceBaseDirectory() .. "/tmp/agents/captures/save-editor-" .. name .. ".png", "wb")
  if output then
    output:write(data:encode("png"):getString())
    output:close()
  end

  local layout = Layout.compute(view, plan.content.width, plan.content.height, view.textMetrics)
  local visibleActions = view.valueEditor and {}
    or (view.modal and { "save", "discard", "cancel" } or { "save", "discard", "back" })
  for _, targetId in ipairs(visibleActions) do
    local target = assert(layout.targets[targetId], name .. " must publish " .. targetId)
    local rect = target.rect
    Assert.isTrue(rect.x >= 0 and rect.y >= 0)
    Assert.isTrue(rect.x + rect.width <= plan.content.width + 0.01, name .. " " .. targetId .. " fits width")
    Assert.isTrue(rect.y + rect.height <= plan.content.height + 0.01, name .. " " .. targetId .. " fits height")
  end
  if view.section == "Progress" then
    local flagTargetId = "flag:" .. view.flagRows[1].name
    local row = assert(layout.targets[flagTargetId], name .. " must expose its flag target")
    local rect = row.rect
    Assert.isTrue(rect.y >= layout.content.y and rect.y + rect.height <= layout.content.y + layout.content.height)
  elseif view.section == "Party" then
    if view.partyPage == "list" then
      Assert.notNil(layout.targets["party:add"], name .. " keeps Add visible")
      Assert.notNil(layout.targets["party:slot:0"], name .. " exposes the occupied slot")
    elseif variant == "stats-table" then
      Assert.notNil(layout.partyStatsTable, name .. " paints the structured Stats table")
      Assert.equal(#layout.partyStatsTable.rows, 6)
      Assert.notNil(layout.targets["party:field:iv:attack"])
      Assert.notNil(layout.targets["party:field:ev:attack"])
      Assert.isNil(layout.targets["party:readonly:stat:attack"])
    elseif variant ~= "draft-summary" then
      Assert.notNil(layout.targets["party:field:personality"], name .. " exposes raw identity")
      local nature = false
      for _, row in ipairs(layout.rows) do
        if row.targetId == "party:readonly:nature" and row.role == "read-only value" then
          nature = true
        end
      end
      Assert.isTrue(nature, name .. " explains derived nature without making it focusable")
      if view.partyPage == "detail" then
        Assert.notNil(layout.targets["party:edit"], name .. " exposes the nested Edit decision")
        Assert.notNil(layout.targets["party:back"], name .. " exposes the nested Back decision")
      else
        Assert.notNil(layout.targets["party:apply"], name .. " exposes the nested Apply decision")
        Assert.notNil(layout.targets["party:cancel"], name .. " exposes the nested Cancel decision")
      end
    end
  elseif view.section == "Location" then
    Assert.notNil(layout.targets["location:map-picker"], name .. " exposes Change Map")
    Assert.isNil(layout.targets["location:zoom-in"], name .. " has no zoom-in target")
    Assert.isNil(layout.targets["location:zoom-out"], name .. " has no zoom-out target")
    if view.locationNavigation.page == "grid" then
      Assert.notNil(layout.locationGrid, name .. " publishes the canonical clipped tile grid")
      Assert.isTrue(layout.locationGrid.clip.width > 0 and layout.locationGrid.clip.height > 0)
      Assert.equal(layout.locationGrid.tileSize, 16, name .. " uses the fixed tile scale")
      Assert.isTrue(layout.locationGrid.clip.height >= 16, name .. " keeps at least one complete tile row")
    end
  elseif view.section == "Bag" then
    if view.valueEditor then
      Assert.notNil(layout.targets["number:delta:-1"], name .. " exposes the number decrement visual")
      Assert.notNil(layout.targets["number:delta:1"], name .. " exposes the number increment visual")
    else
      Assert.notNil(layout.targets["bag:item:POTION"], name .. " exposes the selected stack")
      Assert.isNil(layout.targets["bag:quantity"], name .. " keeps quantity in the item modal")
      Assert.notNil(layout.targets["bag:add"], name .. " exposes Add item")
      if width <= 280 then
        local card = assert(layout.bagGrid[1], name .. " exposes a compact item card")
        Assert.equal(card.textScale, 0.5, name .. " uses compact text that fits the card")
        Assert.isTrue(
          card.rect.height >= 2 * view.textMetrics.lineHeight * card.textScale,
          name .. " fits two readable compact text lines"
        )
        Assert.isTrue(card.iconRect.width >= 16 and card.iconRect.height >= 16, name .. " fits the provider icon")
        Assert.isTrue(
          card.textRect.height >= 2 * view.textMetrics.lineHeight * card.textScale,
          name .. " reserves two lines beside the icon"
        )
        Assert.isTrue(card.iconRect.x + card.iconRect.width <= card.rect.x + card.rect.width)
        Assert.isTrue(card.textRect.x + card.textRect.width <= card.rect.x + card.rect.width)
        Assert.isTrue(
          card.iconRect.y >= card.rect.y and card.iconRect.y + card.iconRect.height <= card.rect.y + card.rect.height
        )
        Assert.isTrue(
          card.textRect.y >= card.rect.y and card.textRect.y + card.textRect.height <= card.rect.y + card.rect.height
        )
      end
    end
  end
  local pane
  for _, candidate in ipairs(plan.panes) do
    if candidate.interactive then
      pane = candidate
    end
  end
  Assert.notNil(pane, name .. " must have an interactive pane")
  if name == "dual-touch" then
    Assert.isTrue(pane.placement.frame.y >= 192, "touch auxiliary owns the complete interactive editor")
  end

  local changed = 0
  for y = 0, height - 1, 4 do
    for x = 0, width - 1, 4 do
      local r, g, b = data:getPixel(x, y)
      if r < 0.9 or g < 0.9 or b < 0.9 then
        changed = changed + 1
      end
    end
  end
  Assert.isTrue(changed > 20, name .. " must render visible editor chrome")
  local renderedText = table.concat(drawnText, " ")
  if section == "Player" and variant ~= "leave" and variant ~= "choice-list" and variant ~= "number-modal" then
    Assert.isTrue(renderedText:find("PLAYER"), name .. " shows the player identity")
  end
  if view.section == "Progress" then
    Assert.isNil(layout.targets["group-previous"], name .. " has no flag group controls")
    Assert.isNil(layout.targets["group-next"], name .. " has no flag group controls")
    Assert.isFalse(renderedText:find("FLAG_", 1, true), name .. " displays the stripped flag name")
    Assert.isTrue(renderedText:find("Type to filter flags", 1, true), name .. " shows the visible search hint")
  end
  if view.section == "Location" then
    Assert.isFalse(renderedText:find("MAP_", 1, true), name .. " hides the map symbol prefix")
    Assert.isTrue(
      renderedText:find("AZALEA_ILEX", 1, true) ~= nil,
      name .. " shows the prefix-clean map name within the control bounds"
    )
    if plan.content.width >= 500 then
      Assert.isTrue(
        renderedText:find("X 32", 1, true) ~= nil and renderedText:find("Z 48", 1, true) ~= nil,
        name .. " shows staged coordinates when space permits"
      )
    end
    Assert.isFalse(renderedText:find("Physical only", 1, true), name .. " omits the disclaimer")
    Assert.isFalse(renderedText:find("blocked", 1, true), name .. " omits invalid-cell reason prose")
    Assert.isFalse(renderedText:find("Ready", 1, true), name .. " omits the ready label")
    Assert.isFalse(renderedText:find("Saved", 1, true), name .. " omits Saved/Pending comparison prose")
    Assert.isFalse(renderedText:find("Pending", 1, true), name .. " omits Saved/Pending comparison prose")
  end
  renderer:dispose()
  presentation:dispose()
  return data, renderedText, layout, bagDrawn, drawnText, view, renderer.skin.background, bagDrawOrder, paletteCalls
end

-- Local helpers for presentation-feedback coverage. They interpret recorded
-- palette/rectangle state in relational terms so no exact color constant is frozen.
local function foregroundAverage(palette)
  if palette == nil or palette.foreground == nil then
    return nil
  end
  local foreground = palette.foreground
  local r = foreground.r or foreground[1]
  local g = foreground.g or foreground[2]
  local b = foreground.b or foreground[3]
  if r == nil or g == nil or b == nil then
    return nil
  end
  return (r + g + b) / 3
end

local function shadowAverage(palette)
  if palette == nil or palette.shadow == nil then
    return nil
  end
  local shadow = palette.shadow
  local r = shadow.r or shadow[1]
  local g = shadow.g or shadow[2]
  local b = shadow.b or shadow[3]
  if r == nil or g == nil or b == nil then
    return nil
  end
  return (r + g + b) / 3
end

local function findPaletteCall(paletteCalls, pattern)
  for index = #paletteCalls, 1, -1 do
    local call = paletteCalls[index]
    if call.value ~= nil and call.value:find(pattern, 1, true) ~= nil and call.palette ~= nil then
      return call
    end
  end
  return nil
end

local function ordinaryContentGap(layout)
  local content = assert(layout.content)
  local occupied = {}
  for _, target in pairs(layout.targets or {}) do
    if target.rect ~= nil then
      occupied[#occupied + 1] = target.rect
    end
  end
  for _, surface in ipairs(layout.listSurfaces or {}) do
    occupied[#occupied + 1] = surface
  end
  if layout.decisionList ~= nil then
    occupied[#occupied + 1] = layout.decisionList.surface
  end
  if layout.valueModal ~= nil then
    occupied[#occupied + 1] = layout.valueModal
  end
  local y = content.y + content.height - 4
  while y > content.y + 2 do
    local x = content.x + content.width / 2
    local inside = false
    for _, rect in ipairs(occupied) do
      if x >= rect.x and x < rect.x + rect.width and y >= rect.y and y < rect.y + rect.height then
        inside = true
        break
      end
    end
    if not inside then
      return { x = x, y = y }
    end
    y = y - 4
  end
  return nil
end

function T.player_shell_renders_headerless_controls_and_a_dirty_leave_decision(scope)
  for _, size in ipairs({ { 256, 192 }, { 640, 480 } }) do
    local topology = ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = size[1], height = size[2] },
      touch = true,
      role = "world",
    })
    local _, renderedText, layout = draw(scope, size[1], size[2], topology, "player-shell", "Player", "leave")
    Assert.isFalse(renderedText:find("Save Editor", 1, true) ~= nil, "shell has no editor title header")
    Assert.isFalse(renderedText:find("TEST-SAVE-42", 1, true) ~= nil, "shell has no save identity header")
    Assert.isFalse(renderedText:find("HEARTGOLD", 1, true) ~= nil, "shell has no version identity header")
    for _, label in ipairs({ "Save", "Discard", "Cancel", "Save changes before leaving?" }) do
      Assert.isTrue(renderedText:find(label, 1, true) ~= nil, "leave decision renders " .. label)
    end
    Assert.isNil(layout.header, "shell publishes no header geometry")
  end
end

function T.choice_and_decision_lists_render_as_white_framed_surfaces(scope)
  local topology = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 640, height = 480 },
    touch = true,
    role = "world",
  })
  for _, scenario in ipairs({
    { section = "Player", variant = "leave", targetId = "save" },
    { section = "Player", variant = "choice-list", targetId = "choice:choice-01" },
  }) do
    local frames = {}
    local data, _, layout, _, _, view = draw(
      scope,
      640,
      480,
      topology,
      "framed-list-" .. scenario.variant,
      scenario.section,
      scenario.variant,
      nil,
      function(renderer)
        local windowRenderer = assert(renderer._windowRenderer)
        local drawApplicationFrame = windowRenderer.drawApplicationFrame
        windowRenderer.drawApplicationFrame = function(self, box, frameIndex)
          frames[#frames + 1] = frameIndex
          return drawApplicationFrame(self, box, frameIndex)
        end
      end
    )
    local row = assert(layout.targets[scenario.targetId], "the active list row is laid out")
    local rect = row.rect
    local pane = assert(view.presentation.panes[1])
    local x, y = LayoutGeometry.logicalToHost(pane.placement, rect.x + rect.width * 0.8, rect.y + rect.height / 2)
    local red, green, blue = data:getPixel(math.floor(x), math.floor(y))
    Assert.near(red, 1, 0.05, "list content has a white surface")
    Assert.near(green, 1, 0.05, "list content has a white surface")
    Assert.near(blue, 1, 0.05, "list content has a white surface")
    if scenario.variant == "choice-list" then
      local outlineX, outlineY = LayoutGeometry.logicalToHost(pane.placement, rect.x + rect.width * 0.8, rect.y + 1)
      local outlineRed, outlineGreen, outlineBlue = data:getPixel(math.floor(outlineX), math.floor(outlineY))
      Assert.isTrue(
        outlineRed > 0.7 and outlineGreen < 0.4 and outlineBlue < 0.4,
        "the selected list row has a thin red outline"
      )
    end
    Assert.isTrue(#frames > 0, "the list draws its application frame")
    for _, frameIndex in ipairs(frames) do
      Assert.equal(frameIndex, 0, "the framed list uses the selected staged frame")
    end
  end
end

function T.integer_editor_renders_as_a_white_staged_frame_modal(scope)
  local topology = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 640, height = 480 },
    touch = true,
    role = "world",
  })
  local frames = {}
  local data, _, layout, _, _, view = draw(
    scope,
    640,
    480,
    topology,
    "number-modal",
    "Player",
    "number-modal",
    nil,
    function(renderer)
      local windowRenderer = assert(renderer._windowRenderer)
      local drawApplicationFrame = windowRenderer.drawApplicationFrame
      windowRenderer.drawApplicationFrame = function(self, box, frameIndex)
        frames[#frames + 1] = frameIndex
        return drawApplicationFrame(self, box, frameIndex)
      end
    end
  )
  Assert.isTrue(#frames > 0, "the number modal draws its application frame")
  for _, frameIndex in ipairs(frames) do
    Assert.equal(frameIndex, 0, "the number modal uses the selected staged frame")
  end
  local modal = assert(layout.valueModal, "the number modal has framed content geometry")
  for _, targetId in ipairs({
    "number:delta:100",
    "number:delta:10",
    "number:delta:1",
    "number:delta:-100",
    "number:delta:-10",
    "number:delta:-1",
  }) do
    Assert.notNil(layout.targets[targetId], "the number modal exposes " .. targetId)
  end
  local pane = assert(view.presentation.panes[1])
  local x, y = LayoutGeometry.logicalToHost(pane.placement, modal.x + modal.width - 10, modal.y + modal.height / 2)
  local red, green, blue = data:getPixel(math.floor(x), math.floor(y))
  Assert.near(red, 1, 0.05, "number modal body is white")
  Assert.near(green, 1, 0.05, "number modal body is white")
  Assert.near(blue, 1, 0.05, "number modal body is white")
end

function T.game_skin_and_staged_frame_drive_the_framed_player_surface(scope)
  local topology = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 640, height = 480 },
    touch = true,
    role = "world",
  })
  local frameIndex
  local data, _, layout, _, _, view, heartGoldBackground = draw(
    scope,
    640,
    480,
    topology,
    "save-editor-frame-preview",
    "Player",
    "leave",
    "heartgold",
    function(renderer, view)
      view.framePreviewIndex = 1
      local windowRenderer = assert(renderer._windowRenderer)
      local drawApplicationFrame = windowRenderer.drawApplicationFrame
      windowRenderer.drawApplicationFrame = function(self, box, selectedFrame)
        frameIndex = selectedFrame
        return drawApplicationFrame(self, box, selectedFrame)
      end
    end
  )
  Assert.equal(frameIndex, 1, "the frame renderer receives the staged choice preview")
  local save = assert(layout.targets.save).rect
  local cancel = assert(layout.targets.cancel).rect
  local pane = assert(view.presentation.panes[1])
  local saveX, saveY = LayoutGeometry.logicalToHost(pane.placement, save.x + 3, save.y + 3)
  local cancelX, cancelY = LayoutGeometry.logicalToHost(pane.placement, cancel.x + 3, cancel.y + 3)
  local saveRed, saveGreen, saveBlue = data:getPixel(math.floor(saveX), math.floor(saveY))
  local cancelRed, cancelGreen, cancelBlue = data:getPixel(math.floor(cancelX), math.floor(cancelY))
  Assert.isTrue(
    saveRed ~= cancelRed or saveGreen ~= cancelGreen or saveBlue ~= cancelBlue,
    "primary Save and secondary Cancel use different semantic button colors"
  )

  local _, _, _, _, _, _, soulSilverBackground =
    draw(scope, 640, 480, topology, "save-editor-soul-silver-skin", "Player", "leave", "soulsilver")
  Assert.isTrue(
    heartGoldBackground[1] ~= soulSilverBackground[1]
      or heartGoldBackground[2] ~= soulSilverBackground[2]
      or heartGoldBackground[3] ~= soulSilverBackground[3],
    "the two game versions select different application backgrounds"
  )
end

function T.dirty_shell_has_no_persistent_status_prose(scope)
  local singleDisplay = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 640, height = 480 },
    touch = true,
    role = "world",
  })
  local dualDisplay = ScreenTopology.dualDisplay(
    { id = "upper", rect = { x = 0, y = 0, width = 256, height = 192 }, touch = false, role = "world" },
    { id = "lower", rect = { x = 0, y = 192, width = 256, height = 192 }, touch = true, role = "auxiliary" }
  )
  for _, case in ipairs({
    { topology = singleDisplay, width = 640, height = 480, name = "dirty-status-single", variant = "dirty-status" },
    { topology = dualDisplay, width = 256, height = 384, name = "dirty-status-dual", variant = "dirty-status" },
    { topology = singleDisplay, width = 640, height = 480, name = "clean-status-single", variant = "clean-status" },
    { topology = dualDisplay, width = 256, height = 384, name = "clean-status-dual", variant = "clean-status" },
  }) do
    local _, renderedText = draw(scope, case.width, case.height, case.topology, case.name, "Player", case.variant)
    Assert.isFalse(renderedText:find("Saved", 1, true) ~= nil, case.name .. " has no persistent saved status")
    Assert.isFalse(renderedText:find("Unsaved changes", 1, true) ~= nil, case.name .. " has no persistent dirty status")
  end
end

function T.layouts_render_reachable_actions_on_compact_wide_tall_and_dual_surfaces(scope)
  local compact = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 256, height = 192 },
    touch = false,
    role = "world",
  })
  draw(scope, 256, 192, compact, "compact")
  local wide = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 1280, height = 720 },
    touch = false,
    role = "world",
  })
  draw(scope, 1280, 720, wide, "wide")
  local tall = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 360, height = 640 },
    touch = true,
    role = "world",
  })
  draw(scope, 360, 640, tall, "tall")
  local dual = ScreenTopology.dualDisplay(
    { id = "upper", rect = { x = 0, y = 0, width = 256, height = 192 }, touch = false, role = "world" },
    { id = "lower", rect = { x = 0, y = 192, width = 256, height = 192 }, touch = true, role = "auxiliary" }
  )
  draw(scope, 256, 384, dual, "dual-touch")
end

function T.party_and_bag_render_on_compact_and_wide_surfaces(scope)
  local compact = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 256, height = 192 },
    touch = false,
    role = "world",
  })
  draw(scope, 256, 192, compact, "party-compact", "Party")
  draw(scope, 256, 192, compact, "bag-compact", "Bag")
  local wide = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 1280, height = 720 },
    touch = false,
    role = "world",
  })
  draw(scope, 1280, 720, wide, "party-wide", "Party")
  draw(scope, 1280, 720, wide, "party-raw-wide", "Party", "draft")
  draw(scope, 1280, 720, wide, "bag-wide", "Bag")
end

function T.party_member_card_uses_light_face_and_selected_border(scope)
  local width, height = 800, 600
  local topology = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = width, height = height },
    touch = true,
    role = "world",
  })
  local rectangleCalls, currentColor = {}, nil
  local oldSetColor, oldRectangle = love.graphics.setColor, love.graphics.rectangle
  love.graphics.setColor = function(r, g, b, a)
    currentColor = { r, g, b, a }
    return oldSetColor(r, g, b, a)
  end
  love.graphics.rectangle = function(mode, x, y, rectWidth, rectHeight, ...)
    rectangleCalls[#rectangleCalls + 1] = {
      mode = mode,
      x = x,
      y = y,
      width = rectWidth,
      height = rectHeight,
      color = currentColor,
    }
    return oldRectangle(mode, x, y, rectWidth, rectHeight, ...)
  end
  local ok, layout = xpcall(function()
    local _, _, renderedLayout = draw(scope, width, height, topology, "party-selected-card", "Party", "list-selected")
    return renderedLayout
  end, debug.traceback)
  love.graphics.setColor, love.graphics.rectangle = oldSetColor, oldRectangle
  if not ok then
    error(layout, 0)
  end

  local memberRect = assert(layout.targets["party:slot:0"]).rect
  local addRect = assert(layout.targets["party:add"]).rect
  local face, selectedBorder, primaryAddFace = false, false, false
  local skin = require("app.src.ui.ProductMenuSkin").forVersion("heartgold")
  for _, call in ipairs(rectangleCalls) do
    local exactMember = call.x == memberRect.x
      and call.y == memberRect.y
      and call.width == memberRect.width
      and call.height == memberRect.height
    if exactMember and call.mode == "fill" then
      face = call.color[1] == 1 and call.color[2] == 1 and call.color[3] == 1
    elseif exactMember and call.mode == "line" then
      local rim = skin.cards.normal.selectedRim
      selectedBorder = call.color[1] == rim[1] and call.color[2] == rim[2] and call.color[3] == rim[3]
    end
    local withinAdd = call.x >= addRect.x
      and call.y >= addRect.y
      and call.x + call.width <= addRect.x + addRect.width
      and call.y + call.height <= addRect.y + addRect.height
    if
      withinAdd
      and call.mode == "fill"
      and call.color[1] == 0.56
      and call.color[2] == 0.82
      and call.color[3] == 0.48
    then
      primaryAddFace = true
    end
  end
  Assert.isTrue(face, "member card has a light face")
  Assert.isTrue(selectedBorder, "focused member card has the selected border")
  Assert.isTrue(primaryAddFace, "Add card retains the primary action face")
end

function T.bag_quantity_uses_normal_and_pressed_generated_controls(scope)
  local topology = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 640, height = 480 },
    touch = true,
    role = "world",
  })
  local _, _, _, normal = draw(scope, 640, 480, topology, "bag-quantity-normal", "Bag", "quantity-normal")
  Assert.isTrue(normal["bag/dec-normal"], "unpressed decrement uses its normal generated image")
  Assert.isTrue(normal["bag/inc-normal"], "unpressed increment uses its normal generated image")
  Assert.isFalse(normal["bag/dec-pressed"] == true, "unpressed decrement does not use its pressed image")
  Assert.isFalse(normal["bag/inc-pressed"] == true, "unpressed increment does not use its pressed image")

  local _, _, _, pressed = draw(scope, 640, 480, topology, "bag-quantity-pressed", "Bag", "quantity-pressed")
  Assert.isTrue(pressed["bag/inc-pressed"], "held increment uses its pressed generated image")
  Assert.isTrue(pressed["bag/dec-normal"], "unheld decrement keeps its normal generated image")
  Assert.isTrue(pressed["bag/inc-normal"], "the other retail increments keep their normal image")
end

function T.bag_cards_use_bounded_description_and_wide_centered_geometry(scope)
  local width, height = 1280, 720
  local topology = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = width, height = height },
    touch = true,
    role = "world",
  })
  local _, renderedText, layout = draw(scope, width, height, topology, "bag-cards", "Bag", "bag-cards")
  local card = assert(layout.bagGrid[1])
  Assert.isTrue(
    (layout.bagGrid[2].rect.x + layout.bagGrid[2].rect.width) - card.rect.x < layout.content.width,
    "wide Bag cards keep a maximum width"
  )
  local gridLeft = card.rect.x
  local rightmost = card.rect.x + card.rect.width
  for _, candidate in ipairs(layout.bagGrid) do
    gridLeft = math.min(gridLeft, candidate.rect.x)
    rightmost = math.max(rightmost, candidate.rect.x + candidate.rect.width)
  end
  Assert.isTrue(
    math.abs((gridLeft - layout.content.x) - (layout.content.x + layout.content.width - rightmost)) < 1,
    "the bounded wide Bag grid has symmetric side padding"
  )
  Assert.isTrue(renderedText:find("Restores a small amount of HP", 1, true) ~= nil, "cards show item descriptions")
  Assert.isFalse(
    renderedText:find("OVERFLOW_SENTINEL", 1, true) ~= nil,
    "descriptions stop at the card's two-line limit"
  )
end

function T.bag_item_focus_uses_generated_visual_under_the_card_contents(scope)
  local width, height = 640, 480
  local topology = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = width, height = height },
    touch = true,
    role = "world",
  })
  local _, _, layout, drawn, _, _, _, drawOrder = draw(
    scope,
    width,
    height,
    topology,
    "bag-focus",
    "Bag",
    "bag-cards",
    nil,
    function(renderer)
      local iconImage = love.graphics.newImage(love.image.newImageData(16, 16))
      renderer._icons.POTION = { image = iconImage, dimensions = { width = 16, height = 16 } }
    end
  )
  local card = assert(layout.bagGrid[1])
  Assert.isTrue(drawn["bag/item-focus"], "the selected item draws the generated Bag focus visual")
  local focusIndex, iconIndex, focusArgs
  for index, entry in ipairs(drawOrder) do
    if entry.path == "bag/item-focus" then
      focusIndex, focusArgs = index, entry.args
    elseif entry.path == "icon:POTION" then
      iconIndex = index
    end
  end
  Assert.isTrue(
    focusIndex ~= nil and iconIndex ~= nil and focusIndex < iconIndex,
    "Bag focus art draws beneath the item icon"
  )
  local focusX, focusY = focusArgs[1], focusArgs[2]
  Assert.equal(focusX, card.rect.x + card.rect.width / 2 - 9, "focus preserves its generated horizontal offset")
  Assert.equal(focusY, card.rect.y + card.rect.height / 2 - 6, "focus preserves its generated vertical offset")
end

function T.bag_page_controls_draw_generated_arrow_art_without_text_labels(scope)
  local width, height = 640, 480
  local topology = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = width, height = height },
    touch = true,
    role = "world",
  })
  local _, renderedText, _, drawn = draw(scope, width, height, topology, "bag-pages", "Bag", "bag-pages")
  Assert.isTrue(drawn["bag/dec-normal"], "Previous uses the generated decrement arrow")
  Assert.isTrue(drawn["bag/inc-normal"], "Next uses the generated increment arrow")
  Assert.isFalse(renderedText:find("Previous", 1, true) ~= nil, "Previous is represented by arrow art")
  Assert.isFalse(renderedText:find("Next", 1, true) ~= nil, "Next is represented by arrow art")
end

function T.party_icons_center_from_distinct_provider_dimensions(scope)
  local size, height = 800, 600
  local topology = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = size, height = height },
    touch = true,
    role = "world",
  })
  local view, presentation, plan = fixture(scope, size, height, topology, "Party", "list")
  local RendererModule = require("app.src.saveeditor.SaveEditorRenderer")
  local MonIconAssetProvider = require("libs.hgss.src.presentation.MonIconAssetProvider")
  local AssetPreparationQueue = require("libs.hgss.src.presentation.AssetPreparationQueue")
  local image = scope:own(love.graphics.newImage(love.image.newImageData(64, 64)))
  local quad = scope:own(love.graphics.newQuad(0, 0, 1, 1, 64, 64))
  local dimensions = {
    small = { width = 14, height = 9 },
    large = { width = 23, height = 17 },
    oversized = { width = 32, height = 32 },
  }
  local provider = {
    prepareKeys = function()
      return true
    end,
    image = function()
      return image
    end,
    quadFor = function()
      return quad
    end,
    dimensions = function(_, key)
      return dimensions[key]
    end,
    release = function() end,
  }
  local oldProviderNew, oldQueueNew = MonIconAssetProvider.new, AssetPreparationQueue.new
  local oldDraw = love.graphics.draw
  local drawnText = {}
  local renderer = RendererModule.new({
    versionId = "heartgold",
    text = {
      fontDef = { lineHeight = view.textMetrics.lineHeight },
      textWidth = function(_, text)
        return view.textMetrics.measure(text)
      end,
      drawText = function(_, text, x, y)
        drawnText[#drawnText + 1] = text
        love.graphics.print(text, x, y)
      end,
      drawTextWithPalette = function(_, text, x, y)
        drawnText[#drawnText + 1] = text
        love.graphics.print(text, x, y)
      end,
    },
  })
  local frameCache = FieldUiFixture.cacheWithFontAndFrames()
  renderer:preparePresentationAssets(frameCache, assert(frameCache:loadLua(FieldUiAssetCache.manifestPath())))
  local iconRects, draws, iconColors = {}, {}, {}
  local ok, failure = xpcall(function()
    MonIconAssetProvider.new = function()
      return provider
    end
    AssetPreparationQueue.new = function()
      return { release = function() end }
    end
    local rowsById = {}
    for _, row in ipairs(plan.content.layout.rows) do
      rowsById[row.targetId] = row
    end
    plan.content.layout.partyGrid[1].value = "Neutral"
    local iconSpecs = {
      { targetId = "party:slot:0", key = "small", rect = { x = 20, y = 72, width = 28, height = 24 } },
      { targetId = "party:slot:0", key = "large", rect = { x = 86, y = 72, width = 32, height = 28 } },
    }
    for _, spec in ipairs(iconSpecs) do
      local row = assert(rowsById[spec.targetId], "Party layout exposes the card icon target " .. spec.targetId)
      row.iconKey = spec.key
      row.iconRect = spec.rect
      iconRects[spec.key] = spec.rect
      view.partyRows = { { role = "action", targetId = spec.targetId, label = spec.key } }
      renderer:prepareVisibleIcons(view, plan, {}, {})
      love.graphics.draw = function(drawable, drawQuad, x, y, ...)
        if drawable == image then
          draws[#draws + 1] = { x = x, y = y }
          iconColors[#iconColors + 1] = { love.graphics.getColor() }
        end
        return oldDraw(drawable, drawQuad, x, y, ...)
      end
      local canvas = scope:own(love.graphics.newCanvas(size, height))
      love.graphics.setCanvas(canvas)
      love.graphics.clear(1, 1, 1, 1)
      renderer:draw(view, plan)
      love.graphics.setCanvas()
    end
    local compact = ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = 256, height = 192 },
      touch = false,
      role = "world",
    })
    local compactView, compactPresentation, compactPlan = fixture(scope, 256, 192, compact, "Party", "list")
    local compactRow
    for _, row in ipairs(compactPlan.content.layout.rows) do
      if row.targetId == "party:slot:0" then
        compactRow = row
        row.iconKey = "oversized"
      end
    end
    compactRow = assert(compactRow, "compact Party layout exposes its occupied card")
    renderer:prepareVisibleIcons(compactView, compactPlan, {}, {})
    local compactDraw
    love.graphics.draw = function(drawable, drawQuad, x, y, _, scaleX, scaleY, ...)
      if drawable == image then
        compactDraw = { x = x, y = y, scaleX = scaleX, scaleY = scaleY }
      end
      return oldDraw(drawable, drawQuad, x, y, _, scaleX, scaleY, ...)
    end
    local compactCanvas = scope:own(love.graphics.newCanvas(256, 192))
    love.graphics.setCanvas(compactCanvas)
    love.graphics.clear(1, 1, 1, 1)
    renderer:draw(compactView, compactPlan)
    love.graphics.setCanvas()
    compactPresentation:dispose()
    iconRects.oversized = compactRow.iconRect
    iconRects.text = compactRow.labelRect
    draws.oversized = compactDraw
  end, debug.traceback)
  love.graphics.draw = oldDraw
  MonIconAssetProvider.new, AssetPreparationQueue.new = oldProviderNew, oldQueueNew
  renderer:dispose()
  presentation:dispose()
  if not ok then
    error(failure, 0)
  end

  Assert.equal(#draws, 2, "both occupied and Add cards draw their prepared icons")
  for _, color in ipairs(iconColors) do
    Assert.near(color[1], 1, 0.001, "party icon red tint is reset")
    Assert.near(color[2], 1, 0.001, "party icon green tint is reset")
    Assert.near(color[3], 1, 0.001, "party icon blue tint is reset")
    Assert.near(color[4], 1, 0.001, "party icon alpha tint is reset")
  end
  local expected = {}
  for _, key in ipairs({ "small", "large" }) do
    local rect, dimensionsForKey = iconRects[key], dimensions[key]
    expected[#expected + 1] = {
      x = rect.x + (rect.width - dimensionsForKey.width) / 2,
      y = rect.y + (rect.height - dimensionsForKey.height) / 2,
    }
  end
  for index, point in ipairs(expected) do
    Assert.near(draws[index].x, point.x, 0.01, "icon x uses provider-reported width and layout icon bounds")
    Assert.near(draws[index].y, point.y, 0.01, "icon y uses provider-reported height and layout icon bounds")
  end
  Assert.isTrue(
    table.concat(drawnText, " "):find("Neutral", 1, true) ~= nil,
    "grid-card painter renders the projected value string without domain formatting"
  )
  local compactDraw = assert(draws.oversized, "compact Party card draws its prepared icon")
  local compactBounds = iconRects.oversized
  Assert.isTrue(compactDraw.scaleX < 1 and compactDraw.scaleY < 1, "compact cards scale a full-size icon to fit")
  Assert.isTrue(
    compactDraw.x >= compactBounds.x
      and compactDraw.y >= compactBounds.y
      and compactDraw.x + dimensions.oversized.width * compactDraw.scaleX <= compactBounds.x + compactBounds.width
      and compactDraw.y + dimensions.oversized.height * compactDraw.scaleY <= compactBounds.y + compactBounds.height,
    "scaled icon stays inside its compact icon rectangle"
  )
  Assert.isTrue(
    compactDraw.x + dimensions.oversized.width * compactDraw.scaleX <= iconRects.text.x,
    "scaled icon stays beside the card label"
  )
end

function T.location_grid_shows_status_and_controls_on_compact_wide_tall_and_dual_touch(scope)
  local compact = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 256, height = 192 },
    touch = false,
    role = "world",
  })
  draw(scope, 256, 192, compact, "location-compact", "Location")
  local wide = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 1280, height = 720 },
    touch = false,
    role = "world",
  })
  draw(scope, 1280, 720, wide, "location-wide", "Location")
  local tall = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 360, height = 640 },
    touch = true,
    role = "world",
  })
  draw(scope, 360, 640, tall, "location-tall", "Location")
  local dual = ScreenTopology.dualDisplay(
    { id = "upper", rect = { x = 0, y = 0, width = 256, height = 192 }, touch = false, role = "world" },
    { id = "lower", rect = { x = 0, y = 192, width = 256, height = 192 }, touch = true, role = "auxiliary" }
  )
  draw(scope, 256, 384, dual, "location-dual-touch", "Location")
end

function T.location_grid_focus_cue_remains_visible_over_grid_tiles(scope)
  local topology = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 1280, height = 720 },
    touch = false,
    role = "world",
  })
  local data, _, layout, _, _, view = draw(scope, 1280, 720, topology, "location-grid-cue", "Location")
  local cue = assert(layout.locationFocusCue, "the active grid publishes its surface cue")
  local pane = assert(view.presentation.panes[1])
  local x, y = LayoutGeometry.logicalToHost(pane.placement, cue.x + cue.width / 2, cue.y)
  local red, green, blue = data:getPixel(math.floor(x), math.floor(y))
  Assert.isTrue(red > 0.7 and green < 0.4 and blue < 0.4, "the grid surface cue stays visible over its tiles")
end

function T.location_map_list_labels_fit_button_content_without_losing_map_identity(scope)
  local wide = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 1280, height = 720 },
    touch = false,
    role = "world",
  })
  local _, renderedText, layout = draw(scope, 1280, 720, wide, "location-map-list-labels", "Location", "map-list")
  local targetId = "location:map:12"
  local found
  for _, row in ipairs(layout.navigation) do
    if row.targetId == targetId then
      found = row
      break
    end
  end
  Assert.equal(found and found.label, "AZALEA_ILEX_FOREST_GATEHOUSE", "layout retains the complete map display name")
  Assert.isTrue(renderedText:find("AZALEA_ILEX", 1, true) ~= nil, "the painted map label remains recognizable")
end

function T.compact_progress_fits_a_real_long_flag_inside_separate_row_cells(scope)
  local width, height = 256, 192
  local compact = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = width, height = height },
    touch = false,
    role = "world",
  })
  local _, renderedText, layout, _, drawnText, view =
    draw(scope, width, height, compact, "progress-long-flag", "Progress", "long-flag")
  local targetId = "flag:" .. LONG_FLAG_NAME
  local row
  for _, candidate in ipairs(layout.rows) do
    if candidate.targetId == targetId then
      row = candidate
      break
    end
  end
  row = assert(row, "the real flag row is present in compact layout")
  local label = LONG_FLAG_DISPLAY_NAME
  Assert.isTrue(renderedText:find(label, 1, true) == nil, "the unbounded dynamic label is not drawn")
  Assert.isTrue(renderedText:find("OFF", 1, true) ~= nil, "the flag value remains visible")
  Assert.isTrue(row.labelRect.width > 0 and row.valueRect.width > 0, "layout reserves separate text cells")
  local fittedLabel
  for _, value in ipairs(drawnText) do
    if value:find("HIDE_GOLDENROD", 1, true) == 1 then
      fittedLabel = value
    end
  end
  Assert.notNil(fittedLabel, "the stripped flag label is still rendered")
  Assert.isTrue(view.textMetrics.measure(fittedLabel) <= row.labelRect.width, "the label fits its measured cell")
end

function T.add_draft_summary_is_rendered_in_its_reserved_party_region(scope)
  local width, height = 800, 600
  local wide = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = width, height = height },
    touch = false,
    role = "world",
  })
  local _, renderedText, layout = draw(scope, width, height, wide, "party-draft-summary", "Party", "draft-summary")
  Assert.notNil(layout.partySummary, "Party draft layout reserves a summary region")
  Assert.isTrue(renderedText:find("Chikorita", 1, true) ~= nil, "the draft summary renders its identity")
  Assert.isTrue(renderedText:find("Lv. 5", 1, true) ~= nil, "the draft summary renders its level")
end

function T.party_stats_table_renders_distinct_aligned_columns(scope)
  local width, height = 800, 600
  local topology = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = width, height = height },
    touch = true,
    role = "world",
  })
  local _, renderedText, layout, _, _, view =
    draw(scope, width, height, topology, "party-stats-table", "Party", "stats-table")
  Assert.isTrue(renderedText:find("Stat", 1, true) ~= nil, "the table names the stat column")
  Assert.isTrue(renderedText:find("IV", 1, true) ~= nil, "the table names the IV column")
  Assert.isTrue(renderedText:find("EV", 1, true) ~= nil, "the table names the EV column")
  Assert.isTrue(renderedText:find("Derived", 1, true) ~= nil, "the table distinguishes derived values")
  Assert.isTrue(renderedText:find("Attack", 1, true) ~= nil, "the stat label is rendered")
  Assert.isTrue(renderedText:find("HP", 1, true) ~= nil, "the compact editable HP fact remains visible")
  Assert.isTrue(renderedText:find("12", 1, true) ~= nil, "the editable HP value remains visible")
  Assert.notNil(layout.partyStatsTable)
  Assert.equal(view.focus, "party:field:iv:attack")

  local compactTopology = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 256, height = 192 },
    touch = true,
    role = "world",
  })
  local _, compactText, compactLayout =
    draw(scope, 256, 192, compactTopology, "party-stats-table-compact", "Party", "stats-table")
  for _, header in ipairs({ "Stat", "IV", "EV", "Derived" }) do
    Assert.isTrue(compactText:find(header, 1, true) ~= nil, "compact Stats retains " .. header)
  end
  local lastFact = compactLayout.partyStatsTable.facts[3].rect
  Assert.isTrue(
    lastFact.y + lastFact.height <= compactLayout.targets["party:apply"].rect.y,
    "compact facts do not overlap the draft actions"
  )
end

function T.location_map_search_uses_shaded_controls_and_bounds_long_queries(scope)
  local width, height = 256, 192
  local compact = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = width, height = height },
    touch = false,
    role = "world",
  })
  local normalImage, normalText, normalLayout, _, normalDrawnText, normalView =
    draw(scope, width, height, compact, "location-map-search-unfocused", "Location", "map-list-long-query-unfocused")
  local focusedImage, focusedText, focusedLayout, _, focusedDrawnText, focusedView =
    draw(scope, width, height, compact, "location-map-search-focused", "Location", "map-list-long-query")
  local backFocusedImage, _, backFocusedLayout =
    draw(scope, width, height, compact, "location-map-back-focused", "Location", "map-list-long-query-back-focused")
  local picker = assert(focusedLayout.targets["location:map-picker"]).rect
  local back = assert(focusedLayout.targets["location:map-back"]).rect
  local backSelected = assert(backFocusedLayout.targets["location:map-back"]).rect
  local unfocusedTarget = assert(normalLayout.targets["location:map-picker"]).rect
  Assert.equal(picker.x, unfocusedTarget.x, "focused and unfocused controls share geometry")
  Assert.equal(back.x, assert(normalLayout.targets["location:map-back"]).rect.x, "Back shares stable geometry")
  Assert.equal(back.x, backSelected.x, "focused Back shares geometry")
  local function assertShadedAndFocused(target, focusImage, id)
    local sampleX, sampleY = math.floor(target.x + 3), math.floor(target.y + target.height - 3)
    local outsideX = math.floor(target.x + target.width + 2)
    local backgroundR, backgroundG, backgroundB = normalImage:getPixel(outsideX, sampleY)
    local interiorR, interiorG, interiorB = normalImage:getPixel(sampleX, sampleY)
    Assert.isTrue(
      interiorR ~= backgroundR or interiorG ~= backgroundG or interiorB ~= backgroundB,
      id .. " fills its interior with shaded chrome rather than page background"
    )
    local differs = false
    for y = math.floor(target.y), math.floor(target.y + target.height - 1) do
      for x = math.floor(target.x), math.floor(target.x + target.width - 1) do
        local normalR, normalG, normalB = normalImage:getPixel(x, y)
        local focusR, focusG, focusB = focusImage:getPixel(x, y)
        differs = differs or normalR ~= focusR or normalG ~= focusG or normalB ~= focusB
      end
    end
    Assert.isTrue(differs, id .. " has a visibly distinct focused state")
  end
  assertShadedAndFocused(picker, focusedImage, "location:map-picker")
  assertShadedAndFocused(backSelected, backFocusedImage, "location:map-back")
  Assert.notNil(back, "Back remains a reachable target")
  Assert.isTrue(focusedText:find("Search maps:", 1, true) ~= nil, "the search control retains its label")
  Assert.isTrue(normalText:find("Search maps:", 1, true) ~= nil, "the unfocused search control retains its label")
  local longQuery = focusedView.query
  local fittedLabel
  for _, value in ipairs(focusedDrawnText) do
    if value:find("Search maps:", 1, true) then
      fittedLabel = value
    end
  end
  Assert.notNil(fittedLabel, "the focused map search label is emitted")
  Assert.isTrue(focusedView.textMetrics.measure(fittedLabel) <= picker.width - 16, "search text fits control content")
  Assert.isNil(focusedText:find(longQuery, 1, true), "the full query is not emitted")
  local unfocusedLabel
  for _, value in ipairs(normalDrawnText) do
    if value:find("Search maps:", 1, true) then
      unfocusedLabel = value
    end
  end
  Assert.notNil(unfocusedLabel, "the unfocused map search label is emitted")
  Assert.isTrue(normalView.textMetrics.measure(unfocusedLabel) <= picker.width - 16, "unfocused search text also fits")
end

function T.name_editor_renders_the_real_naming_snapshot_in_a_neutral_dialog(scope)
  local width, height = 256, 192
  local topology = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = width, height = height },
    touch = true,
    role = "world",
  })
  local view = {
    status = "ready",
    versionId = "heartgold",
    saveId = "TEST-SAVE-42",
    section = "Player",
    ready = true,
    dirty = false,
    session = { playerName = "PLAYER", versionId = "HEARTGOLD", frameIndex = 0 },
    scope = { id = "value:player-name:", epoch = 1, kind = "value", focusId = "2:1" },
    textMetrics = realTextMetrics(scope),
    valueEditor = ValueEditor.new({
      kind = "name",
      nameKind = "player",
      maxLength = 7,
      initialText = "A",
      charmap = { A = 1, B = 2 },
      subject = { kind = "player", gender = 0 },
    }):snapshot(),
  }
  local context = DisplayContext.new({
    graphics = love.graphics,
    topologyProvider = function()
      return topology
    end,
  })
  local presentation = ApplicationPresentation.new(Interface.defaults())
  local plan = presentation:resolve(context:measure(width, height), view)
  view.presentation, view.layout = plan, plan.content.layout
  local drawn = {}
  local text = {
    textWidth = function(_, value)
      return #value * 8
    end,
    drawTextWithPalette = function(_, value, x, y)
      drawn[#drawn + 1] = value
      love.graphics.print(value, x, y)
    end,
    drawText = function(_, value, x, y)
      drawn[#drawn + 1] = value
      love.graphics.print(value, x, y)
    end,
  }
  local renderer = Renderer.new({ text = text, versionId = "heartgold" })
  local frameCache = FieldUiFixture.cacheWithFontAndFrames()
  renderer:preparePresentationAssets(frameCache, assert(frameCache:loadLua(FieldUiAssetCache.manifestPath())))
  local canvas = scope:own(love.graphics.newCanvas(width, height))
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0.94, 0.94, 0.94, 1)
  ApplicationPresentation.draw(love.graphics, { renderer = renderer }, view, plan)
  love.graphics.setCanvas()
  local namingText = table.concat(drawn, " ")
  Assert.isTrue(namingText:find("Upper"), "the real naming page controls are rendered")
  Assert.isTrue(namingText:find("Symbols"), "the naming page selector is rendered")
  Assert.isTrue(namingText:find("OK"), "the naming submit control is rendered")
  Assert.notNil(view.layout.targets["2:1"], "the naming glyph grid has reachable cells")
  Assert.notNil(view.layout.targets.confirm, "name submit remains reachable")
  Assert.notNil(view.layout.targets.cancel, "name cancel remains reachable")
  renderer:dispose()
  presentation:dispose()
end

function T.ordinary_page_keeps_themed_background_without_extra_frame(scope)
  local width, height = 640, 480
  local topology = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = width, height = height },
    touch = true,
    role = "world",
  })
  local frames = {}
  local data, _, layout, _, _, view, background = draw(
    scope,
    width,
    height,
    topology,
    "ordinary-themed-page",
    "Player",
    "dirty-status",
    nil,
    function(renderer)
      local windowRenderer = assert(renderer._windowRenderer)
      local drawApplicationFrame = windowRenderer.drawApplicationFrame
      windowRenderer.drawApplicationFrame = function(self, box, frameIndex)
        frames[#frames + 1] = frameIndex
        return drawApplicationFrame(self, box, frameIndex)
      end
    end
  )
  local expectedFrames = #(layout.listSurfaces or {})
  if layout.decisionList ~= nil then
    expectedFrames = expectedFrames + 1
  end
  if layout.valueModal ~= nil then
    expectedFrames = expectedFrames + 1
  end
  Assert.equal(#frames, expectedFrames, "ordinary page draws only explicit application frames")
  local gap = assert(ordinaryContentGap(layout), "ordinary page has gap space inside its content")
  local pane = assert(view.presentation.panes[1])
  local hostX, hostY = LayoutGeometry.logicalToHost(pane.placement, gap.x, gap.y)
  local red, green, blue = data:getPixel(math.floor(hostX), math.floor(hostY))
  Assert.near(red, background[1], 0.02, "ordinary content gap uses the themed background red")
  Assert.near(green, background[2], 0.02, "ordinary content gap uses the themed background green")
  Assert.near(blue, background[3], 0.02, "ordinary content gap uses the themed background blue")
end

function T.surface_text_and_party_action_hierarchy_follow_surface_role(scope)
  local width, height = 640, 480
  local topology = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = width, height = height },
    touch = true,
    role = "world",
  })
  local oldSetColor, oldRectangle = love.graphics.setColor, love.graphics.rectangle
  local currentColor = { 1, 1, 1, 1 }
  local rectangleCalls = {}
  love.graphics.setColor = function(r, g, b, a)
    currentColor = { r, g, b, a }
    return oldSetColor(r, g, b, a)
  end
  love.graphics.rectangle = function(mode, x, y, rectWidth, rectHeight, ...)
    rectangleCalls[#rectangleCalls + 1] = {
      mode = mode,
      x = x,
      y = y,
      width = rectWidth,
      height = rectHeight,
      color = { currentColor[1], currentColor[2], currentColor[3], currentColor[4] },
    }
    return oldRectangle(mode, x, y, rectWidth, rectHeight, ...)
  end
  local ok, failure = xpcall(function()
    rectangleCalls = {}
    local _, _, playerLayout, _, _, _, _, _, playerPalettes =
      draw(scope, width, height, topology, "hierarchy-player", "Player", "dirty-status")
    local function assertWhiteRowFace(targetId)
      local rect = assert(playerLayout.targets[targetId], "player layout exposes " .. targetId).rect
      local found = false
      for _, call in ipairs(rectangleCalls) do
        if
          call.mode == "fill"
          and call.x == rect.x
          and call.y == rect.y
          and call.width == rect.width
          and call.height == rect.height
        then
          if call.color[1] == 1 and call.color[2] == 1 and call.color[3] == 1 then
            found = true
          end
        end
      end
      Assert.isTrue(found, targetId .. " uses the white selectable-row face")
    end
    assertWhiteRowFace("money")
    assertWhiteRowFace("dialogue-frame")
    local saveCall = assert(findPaletteCall(playerPalettes, "Save"), "enabled Save label records its palette")
    local saveAverage = assert(foregroundAverage(saveCall.palette), "enabled Save has a foreground")
    local saveShadow = assert(shadowAverage(saveCall.palette), "enabled Save has a shadow")
    Assert.isTrue(saveAverage > 150, "enabled colored control uses a light foreground")
    Assert.isTrue(saveShadow + 40 < saveAverage, "enabled colored control pairs light ink with a darker shadow")

    rectangleCalls = {}
    local _, _, _, _, _, _, _, _, disabledPalettes =
      draw(scope, width, height, topology, "hierarchy-player-clean", "Player", "clean-status")
    local disabledCall = assert(findPaletteCall(disabledPalettes, "Save"), "disabled Save label records its palette")
    local disabledAverage = assert(foregroundAverage(disabledCall.palette), "disabled Save has a foreground")
    Assert.isTrue(disabledAverage < saveAverage - 15, "disabled Save is visibly muted next to enabled Save")
    Assert.isTrue(disabledAverage > 80, "disabled Save remains legible")

    local wideTopology = ScreenTopology.oneDisplay({
      id = "hierarchy-wide",
      rect = { x = 0, y = 0, width = 1280, height = 720 },
      touch = true,
      role = "world",
    })
    -- Detail and draft pages are captured once each; every action on the same
    -- page shares its capture instead of re-rendering an identical page.
    local captures = {}
    local function assertActionFaceAndLabel(name, targetId, label)
      local variant = (targetId == "party:discard" or targetId == "party:apply") and "draft" or "detail"
      local cached = captures[variant]
      if cached == nil then
        rectangleCalls = {}
        local pageData, _, pageLayout, _, _, pageView, _, _, pagePalettes =
          draw(scope, 1280, 720, wideTopology, name, "Party", variant)
        cached = { data = pageData, layout = pageLayout, view = pageView, palettes = pagePalettes }
        captures[variant] = cached
      end
      local pageData, pageLayout, pageView, pagePalettes = cached.data, cached.layout, cached.view, cached.palettes
      local rect = assert(pageLayout.targets[targetId], name .. " exposes " .. targetId).rect
      local pane = assert(pageView.presentation.panes[1])
      local hostX, hostY = LayoutGeometry.logicalToHost(pane.placement, rect.x + 3, rect.y + 3)
      local red, green, blue = pageData:getPixel(math.floor(hostX), math.floor(hostY))
      Assert.isTrue(red < 0.95 or green < 0.95 or blue < 0.95, targetId .. " paints a colored semantic face")
      local labelCall = assert(findPaletteCall(pagePalettes, label), targetId .. " label records its palette")
      local average = assert(foregroundAverage(labelCall.palette), targetId .. " has a foreground")
      Assert.isTrue(average > 150, targetId .. " label uses light control ink")
      return { red, green, blue }
    end
    local editFace = assertActionFaceAndLabel("hierarchy-party-detail", "party:edit", "Edit")
    local removeFace = assertActionFaceAndLabel("hierarchy-party-detail", "party:remove", "Remove")
    local backFace = assertActionFaceAndLabel("hierarchy-party-detail", "party:back", "Back")
    Assert.isTrue(
      editFace[1] ~= removeFace[1] or editFace[2] ~= removeFace[2] or editFace[3] ~= removeFace[3],
      "primary edit and destructive remove use different faces"
    )
    Assert.isTrue(
      backFace[1] ~= removeFace[1] or backFace[2] ~= removeFace[2] or backFace[3] ~= removeFace[3],
      "secondary back and destructive remove use different faces"
    )
    local applyFace = assertActionFaceAndLabel("hierarchy-party-draft", "party:apply", "Apply")
    local discardFace = assertActionFaceAndLabel("hierarchy-party-draft", "party:discard", "Discard")
    Assert.isTrue(
      applyFace[1] ~= discardFace[1] or applyFace[2] ~= discardFace[2] or applyFace[3] ~= discardFace[3],
      "draft apply and discard use different faces"
    )

    rectangleCalls = {}
    local _, _, _, _, _, _, _, _, listPalettes = draw(scope, 800, 600, topology, "hierarchy-party-add", "Party", "list")
    local addCall = assert(findPaletteCall(listPalettes, "Add Pokemon"), "Add card label records its palette")
    Assert.isTrue(
      assert(foregroundAverage(addCall.palette), "Add card has a foreground") > 150,
      "Add card text is light on its primary face"
    )

    rectangleCalls = {}
    local _, _, _, _, _, _, _, _, bagPalettes =
      draw(scope, width, height, topology, "hierarchy-bag-page", "Bag", "bag-pages")
    local pageCall = nil
    for _, call in ipairs(bagPalettes) do
      if call.value ~= nil and call.value:find("/", 1, true) ~= nil and call.palette ~= nil then
        pageCall = call
      end
    end
    pageCall = assert(pageCall, "Bag page indicator records its palette")
    Assert.isTrue(
      assert(foregroundAverage(pageCall.palette), "page indicator has a foreground") > 150,
      "direct page text uses the light page palette"
    )
  end, debug.traceback)
  love.graphics.setColor, love.graphics.rectangle = oldSetColor, oldRectangle
  if not ok then
    error(failure, 0)
  end
end

function T.bag_page_arrows_expose_focus_press_and_muted_disabled(scope)
  local width, height = 640, 480
  local topology = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = width, height = height },
    touch = true,
    role = "world",
  })
  local skin = require("app.src.ui.ProductMenuSkin").forVersion("heartgold")
  local rim = skin.cards.normal.selectedRim
  local function renderArrowState(name, focusId, capturedTarget, page0)
    local oldDraw, oldRect, oldSet = love.graphics.draw, love.graphics.rectangle, love.graphics.setColor
    local current = { 1, 1, 1, 1 }
    local imageToPath, arrowDraws, rimCalls = {}, {}, {}
    local rendered
    local ok, result = xpcall(function()
      local _, text, layout = draw(
        scope,
        width,
        height,
        topology,
        name,
        "Bag",
        "bag-pages",
        nil,
        function(renderer, view)
          view.focus = focusId
          view.capturedTarget = capturedTarget
          view.bagPage0 = page0
          for path, image in pairs(renderer._bagImages) do
            imageToPath[image] = path
          end
          love.graphics.setColor = function(r, g, b, a)
            current = { r, g, b, a }
            return oldSet(r, g, b, a)
          end
          love.graphics.draw = function(drawable, ...)
            local path = imageToPath[drawable]
            if path ~= nil then
              arrowDraws[#arrowDraws + 1] = { path = path, color = { current[1], current[2], current[3], current[4] } }
            end
            return oldDraw(drawable, ...)
          end
          love.graphics.rectangle = function(mode, x, y, rectWidth, rectHeight, ...)
            rimCalls[#rimCalls + 1] = {
              mode = mode,
              x = x,
              y = y,
              width = rectWidth,
              height = rectHeight,
              color = { current[1], current[2], current[3], current[4] },
            }
            return oldRect(mode, x, y, rectWidth, rectHeight, ...)
          end
        end
      )
      rendered = { text = text, layout = layout }
    end, debug.traceback)
    love.graphics.draw, love.graphics.rectangle, love.graphics.setColor = oldDraw, oldRect, oldSet
    if not ok then
      error(result, 0)
    end
    return rendered.text, rendered.layout, arrowDraws, rimCalls
  end
  local function hasPath(arrowDraws, path)
    for _, entry in ipairs(arrowDraws) do
      if entry.path == path then
        return entry
      end
    end
    return nil
  end
  local function hasRimAt(rimCalls, rect)
    for _, call in ipairs(rimCalls) do
      if
        call.mode == "line"
        and call.x == rect.x
        and call.y == rect.y
        and call.width == rect.width
        and call.height == rect.height
      then
        if call.color[1] == rim[1] and call.color[2] == rim[2] and call.color[3] == rim[3] then
          return true
        end
      end
    end
    return false
  end
  local unfocusedText, unfocusedLayout, unfocusedDraws, unfocusedRims =
    renderArrowState("arrow-next-idle", "bag:pocket:items", nil, 0)
  local nextRect = assert(unfocusedLayout.targets["bag:page:next"]).rect
  Assert.notNil(hasPath(unfocusedDraws, "bag/inc-normal"), "idle Next draws its normal generated art")
  Assert.isNil(hasPath(unfocusedDraws, "bag/inc-pressed"), "idle Next does not draw pressed art")
  Assert.isFalse(hasRimAt(unfocusedRims, nextRect), "idle Next has no focus rim")
  Assert.isFalse(unfocusedText:find("Previous", 1, true) ~= nil, "Previous stays arrow art without text")
  Assert.isFalse(unfocusedText:find("Next", 1, true) ~= nil, "Next stays arrow art without text")

  local _, focusedLayout, focusedDraws, focusedRims = renderArrowState("arrow-next-focused", "bag:page:next", nil, 0)
  local focusedNext = assert(focusedLayout.targets["bag:page:next"]).rect
  Assert.notNil(hasPath(focusedDraws, "bag/inc-normal"), "focused Next keeps its normal generated art")
  Assert.isTrue(hasRimAt(focusedRims, focusedNext), "focused Next draws the selected rim")

  local _, _, pressedDraws, _ = renderArrowState("arrow-next-pressed", "bag:page:next", "bag:page:next", 0)
  Assert.notNil(hasPath(pressedDraws, "bag/inc-pressed"), "held Next draws its pressed generated art")

  local _, disabledLayout, disabledDraws, disabledRims =
    renderArrowState("arrow-previous-disabled", "bag:pocket:items", nil, 0)
  local previousRect = assert(disabledLayout.targets["bag:page:previous"]).rect
  local disabledDraw = assert(hasPath(disabledDraws, "bag/dec-normal"), "disabled Previous keeps normal art")
  local alpha = disabledDraw.color[4]
  Assert.isTrue(alpha ~= nil and alpha < 0.9, "disabled Previous renders at visibly reduced opacity")
  Assert.isFalse(hasRimAt(disabledRims, previousRect), "disabled Previous has no focus rim")
  local _, _, forcedDraws, forcedRims =
    renderArrowState("arrow-previous-disabled-forced", "bag:page:previous", "bag:page:previous", 0)
  local forcedDraw = assert(hasPath(forcedDraws, "bag/dec-normal"), "forced disabled Previous keeps normal art")
  Assert.isNil(hasPath(forcedDraws, "bag/dec-pressed"), "disabled Previous never uses pressed art")
  Assert.isTrue(forcedDraw.color[4] ~= nil and forcedDraw.color[4] < 0.9, "disabled wins over press with muted art")
  Assert.isFalse(hasRimAt(forcedRims, previousRect), "disabled wins over focus with no rim")
end

function T.long_bag_description_marks_truncation_with_ellipsis(scope)
  local width, height = 1280, 720
  local topology = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = width, height = height },
    touch = true,
    role = "world",
  })
  local _, renderedText, _, _, drawnText =
    draw(scope, width, height, topology, "bag-cards-ellipsis", "Bag", "bag-cards")
  Assert.isTrue(
    renderedText:find("Restores a small amount of HP", 1, true) ~= nil,
    "cards keep the visible description prefix"
  )
  Assert.isFalse(renderedText:find("OVERFLOW_SENTINEL", 1, true) ~= nil, "descriptions stop at the card two-line limit")
  local truncated = false
  for _, value in ipairs(drawnText) do
    local isDescription = value:find("Restores", 1, true) ~= nil
      or value:find("remains", 1, true) ~= nil
      or value:find("useful", 1, true) ~= nil
      or value:find("longer", 1, true) ~= nil
      or value:find("description", 1, true) ~= nil
    if isDescription and value:sub(-3) == "\226\128\166" then
      truncated = true
    end
  end
  Assert.isTrue(truncated, "a truncated description line ends with an ellipsis")
  local shortComplete = false
  for _, value in ipairs(drawnText) do
    if value == "Cures poison." then
      shortComplete = true
    end
  end
  Assert.isTrue(shortComplete, "a short description renders without an ellipsis")
end

return GraphicsSmoke.suite(T, { capabilities = { "graphics" } })
