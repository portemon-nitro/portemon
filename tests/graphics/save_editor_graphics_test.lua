-- Render and inspect the editor's canonical targets across measured topologies.

local Assert = require("tests.support.Assert")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local ApplicationPresentation = require("libs.ui.src.ApplicationPresentation")
local ApplicationLayout = require("libs.ui.src.ApplicationLayout")
local DisplayContext = require("libs.ui.src.DisplayContext")
local FieldTextRenderer = require("libs.hgss.src.ui.FieldTextRenderer")
local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local FieldUiAssetCache = require("libs.assets.src.field.FieldUiAssetCache")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local Interface = require("app.src.saveeditor.SaveEditorInterface")
local LocationService = require("app.src.saveeditor.SaveEditorLocationService")
local Layout = require("app.src.saveeditor.SaveEditorLayout")
local LayoutGeometry = require("libs.ui.src.LayoutGeometry")
local Renderer = require("app.src.saveeditor.SaveEditorRenderer")
local ValueEditor = require("app.src.saveeditor.SaveEditorValueEditor")
local ScreenTopology = require("libs.ui.src.ScreenTopology")

local T = {}
local LONG_FLAG_NAME = "FLAG_HIDE_GOLDENROD_DEPT_STORE_5F_RETURN_FRUSTRATION_LADY"
local LONG_FLAG_DISPLAY_NAME = LONG_FLAG_NAME:gsub("^FLAG_", "")
local DISPLAY_CHARMAP = {}
for code = 32, 126 do
  DISPLAY_CHARMAP[string.char(code)] = code
end

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
  local view
  view = {
    status = "ready",
    versionId = versionId or "heartgold",
    saveId = "TEST-SAVE-42",
    section = section,
    ready = true,
    dirty = variant ~= "clean-status",
    focus = variant == "list-selected" and "party:slot:0"
      or variant == "long-flag" and ("flag:" .. LONG_FLAG_NAME)
      or "flag:FLAG_TEST",
    focusVisible = true,
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
    flagRowAt = function(index)
      return view.flagRows[index]
    end,
    flagRowTargets = {
      variant == "long-flag" and ("flag:" .. LONG_FLAG_NAME) or "flag:FLAG_TEST",
    },
    flagIndexByTarget = {
      [variant == "long-flag" and ("flag:" .. LONG_FLAG_NAME) or "flag:FLAG_TEST"] = 1,
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
    local tab = variant == "Moves" and "Moves" or variant == "Details" and "Details" or "Stats"
    local empty = variant == "empty"
    view.partyTab = tab
    view.bagQuantityVisuals = {
      decrement = {
        normal = { image = "bag/dec-normal" },
        pressed = { image = "bag/dec-pressed" },
      },
      increment = {
        normal = { image = "bag/inc-normal" },
        pressed = { image = "bag/inc-pressed" },
      },
    }
    view.partySlot0 = empty and nil or 0
    view.focus = variant == "Moves" and "party:move:0"
      or variant == "party-move" and "party-move:move"
      or empty and "party:add"
      or "party:slot:0"
    view.focusVisible = true
    view.query = ""
    local slots
    if empty then
      slots = { { kind = "add", slot0 = 0 } }
      for _ = 2, 6 do
        slots[#slots + 1] = { kind = "empty" }
      end
    else
      slots = {
        { kind = "member", slot0 = 0, iconKey = "party/chikorita", label = "Chikorita", level = 5, active = true },
        { kind = "member", slot0 = 1, iconKey = "party/totodile", label = "Totodile", level = 7, active = false },
        { kind = "add", slot0 = 2 },
        { kind = "empty" },
        { kind = "empty" },
        { kind = "empty" },
      }
    end
    view.partySelector = { slots = slots }
    view.partyMemberCount = empty and 0 or 2
    view.partyEmpty = empty
    if not empty then
      view.partyStats = {
        header = {
          {
            id = "level",
            label = "Level",
            value = 5,
            targetId = "party:field:level",
            editor = { kind = "integer" },
          },
          {
            id = "experience",
            label = "Exp",
            value = 135,
            targetId = "party:field:experience",
            editor = { kind = "integer" },
          },
          {
            id = "friendship",
            label = "Friendship",
            value = 70,
            targetId = "party:field:friendship",
            editor = { kind = "integer" },
          },
          {
            id = "currentHp",
            label = "HP",
            value = variant == "fainted" and 0 or 12,
            display = variant == "fainted" and "0/19" or "12/19",
            maxHp = 19,
            targetId = "party:field:currentHp",
            editor = { kind = "integer" },
          },
          {
            id = "status",
            label = "Status",
            value = variant == "fainted" and "FNT" or "OK",
            targetId = "party:readonly:status",
          },
        },
        rows = {},
      }
      for _, pair in ipairs({
        { "hp", "HP" },
        { "attack", "Attack" },
        { "defense", "Defense" },
        { "speed", "Speed" },
        { "specialAttack", "Sp. Atk" },
        { "specialDefense", "Sp. Def" },
      }) do
        local key, label = pair[1], pair[2]
        view.partyStats.rows[#view.partyStats.rows + 1] = {
          key = key,
          label = label,
          iv = 1,
          ivEditor = { targetId = "party:field:iv:" .. key, editor = { kind = "integer" } },
          ev = 2,
          evEditor = { targetId = "party:field:ev:" .. key, editor = { kind = "integer" } },
        }
      end
      view.partyMoves = {
        slots = {
          { kind = "move", slot0 = 0, label = "Tackle 35/35", targetId = "party:move:0" },
          { kind = "move", slot0 = 1, label = "Growl 40/40", targetId = "party:move:1" },
          { kind = "add", label = "+ Add", targetId = "party:move:add" },
          { kind = "empty" },
        },
      }
      view.partyDetails = {
        rows = {
          {
            role = "named choice",
            targetId = "party:field:species",
            id = "species",
            label = "Species",
            value = "CHIKORITA",
            editor = { kind = "choice" },
            enabled = true,
          },
          {
            role = "action",
            targetId = "party:field:nickname",
            id = "nickname",
            label = "Nickname",
            value = "Chikorita",
            editor = { kind = "name" },
            enabled = true,
          },
          {
            role = "action",
            targetId = "party:use-species-name",
            id = "use-species-name",
            label = "Use species name",
            enabled = true,
          },
          {
            role = "read-only value",
            targetId = "party:readonly:nature",
            id = "nature",
            label = "Nature",
            value = "Hardy",
          },
        },
      }
    end
    view.scope = { id = "section:Party", epoch = 1, kind = "section", focusId = view.focus }
    view.textMetrics = realTextMetrics(scope)
    if variant == "party-move" then
      view.modal = "party-move"
      view.modalTitle = "Edit move: Tackle"
      view.scope = { id = "decision:party-move", epoch = 2, kind = "decision", focusId = view.focus }
    elseif variant == "party-move-child" then
      view.numberControls = {
        { delta = 100, role = "increment", hitRect = { x = 120, y = 88, width = 32, height = 24 } },
        { delta = 10, role = "increment", hitRect = { x = 152, y = 88, width = 32, height = 24 } },
        { delta = 1, role = "increment", hitRect = { x = 184, y = 88, width = 32, height = 24 } },
        { delta = -100, role = "decrement", hitRect = { x = 120, y = 136, width = 32, height = 24 } },
        { delta = -10, role = "decrement", hitRect = { x = 152, y = 136, width = 32, height = 24 } },
        { delta = -1, role = "decrement", hitRect = { x = 184, y = 136, width = 32, height = 24 } },
      }
    view.numberControlVisuals = {
      increment = {
        normal = { image = "bag/inc-normal", width = 12, height = 12 },
        pressed = { image = "bag/inc-pressed", width = 12, height = 12 },
      },
      decrement = {
        normal = { image = "bag/dec-normal", width = 12, height = 12 },
        pressed = { image = "bag/dec-pressed", width = 12, height = 12 },
      },
    }
      view.valueEditor = {
        kind = "number",
        buffer = "12",
        parsedValue = 12,
        minimum = 0,
        maximum = 99,
        radix = 10,
        digitCount = 2,
        digits = { "1", "2" },
        selectedPlace = 0,
      }
      view.focus = "confirm"
      view.scope = { id = "value:move-pp", epoch = 3, kind = "value", focusId = view.focus }
      view.modalLayers = {
        { id = "move:0", kind = "move", payload = { title = "Edit move: Tackle" } },
        { id = "number:move-pp", kind = "number", payload = { purpose = "move_pp", snapshot = view.valueEditor } },
      }
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
      decrement = {
        normal = { image = "bag/dec-normal", width = 12, height = 12 },
        pressed = { image = "bag/dec-pressed", width = 12, height = 12 },
      },
      increment = {
        normal = { image = "bag/inc-normal", width = 12, height = 12 },
        pressed = { image = "bag/inc-pressed", width = 12, height = 12 },
      },
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
      view.valueEditor = {
        kind = "number",
        buffer = "002",
        parsedValue = 2,
        minimum = 1,
        maximum = 999,
        radix = 10,
        digitCount = 3,
        digits = { "0", "0", "2" },
        selectedPlace = 0,
      }
      view.focus = "number:place:0:up"
      view.numberHoldTarget = variant == "quantity-pressed" and "number:place:0:up" or nil
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
      mapRowTargets = { "location:map:12" },
      mapIndexByTarget = { ["location:map:12"] = 1 },
      mapListId = "location:group:1",
      breadcrumb = "TEST_SECTION",
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
      page = (variant == "map-list" or (variant or ""):match("^map%-list%-long%-query") ~= nil) and "group"
        or "grid",
      groupId = "location:group:1",
      contentFocus = (variant == "map-list" or (variant or ""):match("^map%-list%-long%-query") ~= nil) and "map-list"
        or "grid",
      mapId = 12,
      cursor = { fieldX = 33, fieldZ = 48 },
      center = { fieldX = 32, fieldZ = 48 },
      scale = 16,
      mapOffset = 0,
    }
    if variant == "location-long-blocked-header"
      or variant == "location-literal-error"
      or variant == "location-policy-event"
      or variant == "location-policy-actor"
      or variant == "location-policy-surface"
      or variant == "location-pending-after-blocked"
    then
      view.location.symbol = "A_VERY_LONG_SOURCE_MAP_NAME_WITH_A_VISIBLE_POLICY_REASON"
      view.location.map.symbol = "MAP_A_VERY_LONG_SOURCE_MAP_NAME_WITH_A_VISIBLE_POLICY_REASON"
      view.location.displayName = "A_VERY_LONG_SOURCE_MAP_NAME_WITH_A_VISIBLE_POLICY_REASON"
    end
    if variant == "location-literal-error" then
      view.location.symbol = "A_VERY_LONG_SOURCE_{unknown}_MAP_NAME"
      view.location.map.symbol = "MAP_A_VERY_LONG_SOURCE_{unknown}_MAP_NAME"
      view.location.displayName = "A_VERY_LONG_SOURCE_{unknown}_MAP_NAME"
      view.session.playerName = "PLAYER{A}"
    end
    if variant == "location-policy-event" then
      view.location.cursor = { fieldX = 32, fieldZ = 48 }
      view.location.tiles = {
        { fieldX = 32, fieldZ = 48, selectable = false, reason = "coordinate_trigger" },
        { fieldX = 33, fieldZ = 48, selectable = false, reason = "blocked" },
      }
      view.locationNavigation.cursor = { fieldX = 32, fieldZ = 48 }
    elseif variant == "location-policy-actor" then
      view.location.tiles[1] = { fieldX = 32, fieldZ = 48, selectable = false, reason = "possible_actor" }
      view.location.cursor = { fieldX = 32, fieldZ = 48 }
      view.locationNavigation.cursor = { fieldX = 32, fieldZ = 48 }
    elseif variant == "location-policy-surface" then
      view.location.tiles[1] = { fieldX = 32, fieldZ = 48, selectable = false, reason = "no_surface" }
      view.location.cursor = { fieldX = 32, fieldZ = 48 }
      view.locationNavigation.cursor = { fieldX = 32, fieldZ = 48 }
    elseif variant == "location-pending-after-blocked" then
      view.location.tiles = {
        { fieldX = 32, fieldZ = 48, selectable = false, reason = "blocked" },
      }
      view.location.status = { state = "preparing" }
      view.location.cursor = { fieldX = 34, fieldZ = 48 }
      view.locationNavigation.cursor = { fieldX = 34, fieldZ = 48 }
    elseif variant == "location-pending" then
      view.location.status = { state = "preparing" }
      view.location.tiles = {}
      view.location.cursor = { fieldX = 32, fieldZ = 48 }
      view.locationNavigation.cursor = { fieldX = 32, fieldZ = 48 }
    end
    if (variant or ""):match("^map%-list%-long%-query") ~= nil then
      view.query = string.rep("very-long-search-query", 12)
      view.focus = variant == "map-list-long-query" and "location:map:12" or "list:location:group:1"
      view.focusVisible = variant ~= "map-list-long-query-unfocused"
    end
    view.savedLocation = { mapId = 12, fieldX = 31, fieldZ = 48 }
    view.pendingLocation = { mapId = 12, fieldX = 32, fieldZ = 48 }
    if variant == "location-literal-error" then
      view.savedLocation = nil
    end
  end
  if variant == "choice-list" then
    local options = {}
    local rowTargets = {}
    local indexByTarget = {}
    for index = 1, 12 do
      options[index] = { key = string.format("choice-%02d", index), label = "Choice " .. index }
      rowTargets[index] = "choice:" .. options[index].key
      indexByTarget["choice:" .. options[index].key] = index
    end
    view.focus = "choice:choice-01"
    view.valueEditor = {
      kind = "choice",
      count = #options,
      idAt = function(index)
        return rowTargets[index]
      end,
      indexOf = function(targetId)
        return indexByTarget[targetId]
      end,
      rowAt = function(index)
        return options[index]
      end,
      purpose = "species",
      options = options,
      rowTargets = rowTargets,
      indexByTarget = indexByTarget,
      index = 1,
      selectedKey = "choice-01",
      query = "",
    }
    view.scope = { id = "value:choice:species", epoch = 2, kind = "value", focusId = view.focus }
  elseif
    variant == "number-modal"
    or variant == "number-modal-ten-digit"
    or variant == "number-modal-too-small"
  then
    view.focus = variant == "number-modal-too-small" and "cancel" or "confirm"
    local digitCount = variant == "number-modal-ten-digit" and 10 or 3
    local arrowSize = variant == "number-modal-too-small" and 512 or 12
    local numberControls = {}
    for index = 1, digitCount do
      local placeValue = 10 ^ (digitCount - index)
      local x = 120 + (index - 1) * 14
      numberControls[#numberControls + 1] = {
        delta = placeValue,
        place = digitCount - index,
        role = "increment",
        hitRect = { x = x, y = 88, width = 12, height = 12 },
      }
      numberControls[#numberControls + 1] = {
        delta = -placeValue,
        place = digitCount - index,
        role = "decrement",
        hitRect = { x = x, y = 128, width = 12, height = 12 },
      }
    end
    view.numberControls = numberControls
    view.numberControlVisuals = {
      increment = {
        normal = { image = "bag/inc-normal", width = arrowSize, height = arrowSize },
        pressed = { image = "bag/inc-pressed", width = arrowSize, height = arrowSize },
      },
      decrement = {
        normal = { image = "bag/dec-normal", width = arrowSize, height = arrowSize },
        pressed = { image = "bag/dec-pressed", width = arrowSize, height = arrowSize },
      },
    }
    view.valueEditor = {
      kind = "number",
      buffer = variant == "number-modal-ten-digit" and "0000000001" or "123",
      parsedValue = variant == "number-modal-ten-digit" and 1 or 123,
      minimum = 0,
      maximum = variant == "number-modal-ten-digit" and 0xFFFFFFFF or 999,
      base = "decimal",
      digitCount = digitCount,
      digits = variant == "number-modal-ten-digit" and { "0", "0", "0", "0", "0", "0", "0", "0", "0", "1" }
        or { "1", "2", "3" },
      selectedPlace = 0,
    }
    view.scope = { id = "value:integer:money", epoch = 2, kind = "value", focusId = view.focus }
  end
  if section == "Progress" then
    local rowTargets, indexByTarget = view.flagRowTargets, view.flagIndexByTarget
    view.flagModel = {
      revision = 1,
      queryRevision = 0,
      pending = false,
      count = #rowTargets,
      rowTargets = rowTargets,
      indexByTarget = indexByTarget,
      idAt = function(index)
        return rowTargets[index]
      end,
      indexOf = function(targetId)
        return indexByTarget[targetId]
      end,
      rowAt = view.flagRowAt,
    }
  end
  if section == "Location" and (view.locationNavigation.page == "root" or view.locationNavigation.page == "group") then
    local maps, rowTargets, indexByTarget =
      view.location.maps, view.location.mapRowTargets, view.location.mapIndexByTarget
    view.location.mapModel = {
      revision = 1,
      queryRevision = 0,
      pending = false,
      count = #rowTargets,
      rowTargets = rowTargets,
      indexByTarget = indexByTarget,
      idAt = function(index)
        return rowTargets[index]
      end,
      indexOf = function(targetId)
        return indexByTarget[targetId]
      end,
      rowAt = function(index)
        return maps[index]
      end,
    }
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

-- Caller graphics-state guard for the interactive pane paint passes. The pane
-- paints inside the shared placement/host scopes, so a successful
-- presentation draw must hand the caller's color, blend, line width, scissor,
-- and shader back untouched. Captured around the presentation draw inside
-- `draw`, so every synthetic render checks restoration, not just the
-- dedicated restoration test below.
---@param graphics love.graphics
---@return table
local function captureCallerGraphicsState(graphics)
  local red, green, blue, alpha = graphics.getColor()
  local blendMode, blendAlpha = graphics.getBlendMode()
  local scissorX, scissorY, scissorWidth, scissorHeight = graphics.getScissor()
  return {
    color = { red, green, blue, alpha },
    blend = { blendMode, blendAlpha },
    lineWidth = graphics.getLineWidth(),
    scissor = { scissorX, scissorY, scissorWidth, scissorHeight },
    shader = graphics.getShader(),
  }
end

---@param graphics love.graphics
---@param before table
---@param name string
local function assertCallerGraphicsStateRestored(graphics, before, name)
  local red, green, blue, alpha = graphics.getColor()
  Assert.near(red, before.color[1], 1e-6, name .. " restores the caller red channel")
  Assert.near(green, before.color[2], 1e-6, name .. " restores the caller green channel")
  Assert.near(blue, before.color[3], 1e-6, name .. " restores the caller blue channel")
  Assert.near(alpha, before.color[4], 1e-6, name .. " restores the caller alpha channel")
  local blendMode, blendAlpha = graphics.getBlendMode()
  Assert.equal(blendMode, before.blend[1], name .. " restores the caller blend mode")
  Assert.equal(blendAlpha, before.blend[2], name .. " restores the caller blend alpha mode")
  Assert.equal(graphics.getLineWidth(), before.lineWidth, name .. " restores the caller line width")
  local scissorX, scissorY, scissorWidth, scissorHeight = graphics.getScissor()
  Assert.equal(scissorX, before.scissor[1], name .. " restores the caller scissor x")
  Assert.equal(scissorY, before.scissor[2], name .. " restores the caller scissor y")
  Assert.equal(scissorWidth, before.scissor[3], name .. " restores the caller scissor width")
  Assert.equal(scissorHeight, before.scissor[4], name .. " restores the caller scissor height")
  Assert.equal(graphics.getShader(), before.shader, name .. " restores the caller shader")
end

local function draw(scope, width, height, topology, name, section, variant, versionId, beforeDraw)
  local graphics = love.graphics
  local view, presentation, plan = fixture(scope, width, height, topology, section, variant, versionId)
  local drawnText = {}
  local paletteCalls = {}
  local text = {
    fontDef = { lineHeight = 14, charmap = DISPLAY_CHARMAP },
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
  elseif view.section == "Party" then
    renderer._bagImages = {}
    for index, path in ipairs({ "bag/dec-normal", "bag/dec-pressed", "bag/inc-normal", "bag/inc-pressed" }) do
      local imageData = love.image.newImageData(12 + index, 12 + index)
      renderer._bagImages[path] = graphics.newImage(imageData)
    end
  end
  if view.valueEditor and view.valueEditor.kind == "number" and view.section ~= "Bag" then
    renderer._bagImages = {}
    for _, role in ipairs({ "increment", "decrement" }) do
      for _, state in ipairs({ "normal", "pressed" }) do
        local visual = view.numberControlVisuals[role][state]
        renderer._bagImages[visual.image] = graphics.newImage(love.image.newImageData(visual.width, visual.height))
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
  local callerState = captureCallerGraphicsState(graphics)
  ApplicationPresentation.draw(graphics, { renderer = renderer }, view, plan)
  assertCallerGraphicsStateRestored(graphics, callerState, name)
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
    or (
      view.modal == "party-move" and { "party-move:move", "party-move:pp", "party-move:pp-ups", "cancel" }
      or view.modal and { "save", "discard", "cancel" }
      or { "save", "discard", "back" }
    )
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
    Assert.notNil(layout.partyStrip, name .. " publishes its member strip")
    Assert.equal(#layout.partyStrip.slots, 6, name .. " spans six strip positions")
    if variant == "party-move" then
      -- A decision scope prunes background targets; only the overlay stays.
      for _, targetId in ipairs({ "party-move:move", "party-move:pp", "party-move:pp-ups", "cancel" }) do
        Assert.notNil(layout.targets[targetId], name .. " exposes its move overlay action " .. targetId)
      end
    elseif variant == "party-move-child" then
      Assert.notNil(layout.targets.confirm, name .. " exposes the child editor action")
      Assert.notNil(layout.targets.cancel, name .. " exposes the child cancel action")
    else
      if variant ~= "empty" then
        Assert.notNil(layout.targets["party:slot:0"], name .. " exposes the occupied slot")
      end
      Assert.notNil(layout.targets["party:add"], name .. " keeps Add visible")
      Assert.notNil(layout.targets["party:page:previous"], name .. " publishes its pager")
      Assert.notNil(layout.targets["party:page:next"], name .. " publishes its pager")
      Assert.notNil(layout.partyPageLabel, name .. " names its current page")
      if variant == "empty" then
        Assert.isNil(layout.targets["party:slot:0"], name .. " selects no member while empty")
      elseif variant == "Moves" then
        Assert.notNil(layout.targets["party:move:0"], name .. " exposes its occupied move slots")
        Assert.notNil(layout.targets["party:move:add"], name .. " exposes its move Add slot")
      elseif variant == "Details" then
        Assert.notNil(layout.targets["party:field:species"], name .. " exposes its Details fields")
      elseif plan.content.height >= 340 then
        Assert.notNil(layout.partyStatsTable, name .. " paints the structured Stats table")
        Assert.equal(#layout.partyStatsTable.rows, 6)
        Assert.notNil(layout.targets["party:field:level"], name .. " exposes its level editor")
        Assert.notNil(layout.targets["party:field:iv:attack"])
        Assert.notNil(layout.targets["party:field:ev:attack"])
      else
        Assert.notNil(layout.viewports.party, name .. " scrolls its compact Stats body")
      end
    end
  elseif view.section == "Location" then
    Assert.isNil(layout.targets["location:map-picker"], name .. " has no picker control")
    Assert.isNil(layout.targets["location:map-back"], name .. " has no nested Back")
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
      Assert.notNil(layout.targets["number:place:0:down"], name .. " exposes the least-significant decrement")
      Assert.notNil(layout.targets["number:place:0:up"], name .. " exposes the least-significant increment")
    else
      Assert.notNil(layout.targets["bag:item:POTION"], name .. " exposes the selected stack")
      Assert.isNil(layout.targets["bag:quantity"], name .. " keeps quantity in the item modal")
      Assert.notNil(layout.targets["bag:add"], name .. " exposes Add item")
      if width <= 280 then
        local card = assert(layout.bagGrid[1], name .. " exposes a compact item card")
        Assert.equal(card.textScale, 0.5, name .. " uses compact text that fits the card")
        Assert.isTrue(
          card.rect.height >= view.textMetrics.lineHeight * card.textScale,
          name .. " fits one readable compact text line"
        )
        Assert.isTrue(card.iconRect.width >= 16 and card.iconRect.height >= 16, name .. " fits the provider icon")
        for _, key in ipairs({ "iconRect", "nameRect", "quantityRect" }) do
          local region = assert(card[key], name .. " exposes a compact " .. key)
          Assert.isTrue(region.x + region.width <= card.rect.x + card.rect.width, name .. " " .. key .. " fits width")
          Assert.isTrue(
            region.y >= card.rect.y and region.y + region.height <= card.rect.y + card.rect.height,
            name .. " " .. key .. " fits height"
          )
        end
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
    local hintFound = false
    for _, value in ipairs(drawnText) do
      if value == "Type to filter" then
        hintFound = true
      end
    end
    Assert.isTrue(hintFound, name .. " shows the visible search hint")
  end
  if view.section == "Location" then
    local hasLongHeader = variant == "location-long-blocked-header"
      or variant == "location-literal-error"
      or variant == "location-policy-event"
      or variant == "location-policy-actor"
      or variant == "location-policy-surface"
      or variant == "location-pending-after-blocked"
    if hasLongHeader then
      Assert.isTrue(renderedText:find("A_VERY_LONG_SOURCE", 1, true) ~= nil)
    else
      Assert.isFalse(renderedText:find("MAP_", 1, true), name .. " hides the map symbol prefix")
      Assert.isTrue(
        renderedText:find("AZALEA_ILEX", 1, true) ~= nil,
        name .. " shows the prefix-clean map name within the control bounds"
      )
    end
    if view.locationNavigation.page == "grid" then
      Assert.isFalse(renderedText:find("Physical only", 1, true), name .. " omits the disclaimer")
      if plan.content.width >= 500 then
        local cursor = view.locationNavigation.cursor
        Assert.isTrue(
          renderedText:find("X " .. cursor.fieldX, 1, true) ~= nil
            and renderedText:find("Z " .. cursor.fieldZ, 1, true) ~= nil,
          name .. " shows cursor coordinates when space permits"
        )
      end
      local header = assert(layout.locationHeader)
      local longIdentity = variant == "location-long-blocked-header"
        or variant == "location-literal-error"
        or variant == "location-policy-event"
        or variant == "location-policy-actor"
        or variant == "location-policy-surface"
        or variant == "location-pending-after-blocked"
      local identity = longIdentity and "A_VERY_LONG" or "AZALEA_ILEX"
      local mapNameDrawn = false
      local coordinatesDrawn = false
      for _, value in ipairs(drawnText) do
        mapNameDrawn = mapNameDrawn or value:find(identity, 1, true) ~= nil
        coordinatesDrawn = coordinatesDrawn
          or value:find("X " .. view.locationNavigation.cursor.fieldX, 1, true) ~= nil
            and value:find("Z " .. view.locationNavigation.cursor.fieldZ, 1, true) ~= nil
      end
      Assert.isTrue(mapNameDrawn, name .. " draws the map name")
      Assert.isTrue(coordinatesDrawn, name .. " preserves cursor coordinates separately")
      Assert.isTrue(
        header.coordinatesText:find("X " .. view.locationNavigation.cursor.fieldX, 1, true) ~= nil,
        name .. " publishes separate cursor coordinates"
      )
    else
      Assert.isFalse(renderedText:find("blocked", 1, true), name .. " shows no blocked prose while selecting a map")
    end
    Assert.isFalse(renderedText:find("Ready", 1, true), name .. " omits the ready label")
    Assert.isFalse(renderedText:find("Saved", 1, true), name .. " omits Saved/Pending comparison prose")
    Assert.isFalse(renderedText:find("Pending", 1, true), name .. " omits Saved/Pending comparison prose")
  end
  renderer:dispose()
  presentation:dispose()
  return data,
    renderedText,
    layout,
    bagDrawn,
    drawnText,
    view,
    renderer.skin.background,
    bagDrawOrder,
    paletteCalls,
    plan
end

local function pixelAtLogical(data, plan, x, y)
  local pane
  for _, candidate in ipairs(plan.panes) do
    if candidate.interactive then
      pane = candidate
      break
    end
  end
  local hostX, hostY = LayoutGeometry.logicalToHost(assert(pane).placement, x, y)
  return data:getPixel(math.floor(hostX), math.floor(hostY))
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
    for _, label in ipairs({ "Save & exit", "Discard all", "Cancel", "Save every section before leaving?" }) do
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
    local pane = assert(view.presentation.panes[1])
    if scenario.variant == "choice-list" then
      local row = assert(layout.targets[scenario.targetId], "the active list row is laid out")
      local rect = row.rect
      local x, y = LayoutGeometry.logicalToHost(pane.placement, rect.x + rect.width * 0.8, rect.y + rect.height / 2)
      local red, green, blue = data:getPixel(math.floor(x), math.floor(y))
      Assert.near(red, 1, 0.05, "list content has a white surface")
      Assert.near(green, 1, 0.05, "list content has a white surface")
      Assert.near(blue, 1, 0.05, "list content has a white surface")
      local outlineX, outlineY = LayoutGeometry.logicalToHost(pane.placement, rect.x + rect.width / 2, rect.y + 3)
      local outlineRed, outlineGreen, outlineBlue = data:getPixel(math.floor(outlineX), math.floor(outlineY))
      Assert.isTrue(
        outlineRed > 0.7 and outlineGreen < 0.4 and outlineBlue < 0.4,
        "the active row marker is inset from its edges"
      )
    else
      local decision = assert(layout.decisionList, "the leave decision publishes its framed surface")
      local firstRow = assert(decision.rows[1], "the leave decision exposes its actions").rect
      local x, y = LayoutGeometry.logicalToHost(pane.placement, firstRow.x - 6, firstRow.y + firstRow.height / 2)
      local red, green, blue = data:getPixel(math.floor(x), math.floor(y))
      Assert.near(red, 1, 0.05, "modal content has a white surface beside its action buttons")
      Assert.near(green, 1, 0.05, "modal content has a white surface beside its action buttons")
      Assert.near(blue, 1, 0.05, "modal content has a white surface beside its action buttons")
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
    "number:place:2:up",
    "number:place:1:up",
    "number:place:0:up",
    "number:place:2:down",
    "number:place:1:down",
    "number:place:0:down",
  }) do
    Assert.notNil(layout.targets[targetId], "the number modal exposes " .. targetId)
  end
  local pane = assert(view.presentation.panes[1])
  local x, y = LayoutGeometry.logicalToHost(pane.placement, modal.x + 4, modal.y + 4)
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
  draw(scope, 256, 192, compact, "party-compact-empty", "Party", "empty")
  draw(scope, 256, 192, compact, "bag-compact", "Bag")
  local wide = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 1280, height = 720 },
    touch = false,
    role = "world",
  })
  draw(scope, 1280, 720, wide, "party-wide", "Party")
  draw(scope, 1280, 720, wide, "party-moves-wide", "Party", "Moves")
  draw(scope, 1280, 720, wide, "party-details-wide", "Party", "Details")
  draw(scope, 1280, 720, wide, "party-move-overlay", "Party", "party-move")
  draw(scope, 1280, 720, wide, "bag-wide", "Bag")
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

function T.bag_cards_use_generic_buttons_with_name_and_quantity(scope)
  local width, height = 1280, 720
  local topology = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = width, height = height },
    touch = true,
    role = "world",
  })
  local _, renderedText, layout, drawn, drawnText =
    draw(scope, width, height, topology, "bag-cards", "Bag", "bag-cards")
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
  local named, counted = false, false
  for _, value in ipairs(drawnText) do
    if value:find("Potion", 1, true) ~= nil then
      named = true
    end
    if value == "x2" then
      counted = true
    end
  end
  Assert.isTrue(named, "cards show the item name")
  Assert.isTrue(counted, "cards show the item quantity")
  Assert.isFalse(renderedText:find("Restores a small amount", 1, true) ~= nil, "cards omit item descriptions")
  Assert.isFalse(renderedText:find("OVERFLOW_SENTINEL", 1, true) ~= nil, "long descriptions never reach the card")
  Assert.isFalse(renderedText:find("Cures poison.", 1, true) ~= nil, "short descriptions are omitted too")
  Assert.isNil(drawn["bag/item-focus"], "cards draw no native focus visual")
  Assert.isTrue(drawn["bag/items-strip"], "the pocket strip keeps its generated art")
  Assert.isTrue(drawn["bag/dec-normal"], "Previous keeps its generated arrow")
  Assert.isTrue(drawn["bag/inc-normal"], "Next keeps its generated arrow")
end

function T.bag_selected_cards_draw_no_native_focus_visual(scope)
  local width, height = 640, 480
  local topology = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = width, height = height },
    touch = true,
    role = "world",
  })
  local _, _, _, drawn, _, _, _, drawOrder = draw(
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
  Assert.isNil(drawn["bag/item-focus"], "the selected item draws no native Bag focus visual")
  local iconSeen = false
  for _, entry in ipairs(drawOrder) do
    if entry.path == "icon:POTION" then
      iconSeen = true
    end
  end
  Assert.isTrue(iconSeen, "the selected card still draws its item sprite")
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

function T.party_pager_reuses_bag_arrow_art_for_normal_and_pressed_feedback(scope)
  local topology = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 640, height = 480 },
    touch = true,
    role = "world",
  })
  local _, partyText, _, partyDrawn = draw(scope, 640, 480, topology, "party-pager-art", "Party", "Stats")
  local _, bagText, _, bagDrawn = draw(scope, 640, 480, topology, "bag-pager-art", "Bag", "bag-pages")
  for _, path in ipairs({ "bag/dec-normal", "bag/inc-normal" }) do
    Assert.isTrue(partyDrawn[path], "Party pager uses Bag source art " .. path)
    Assert.isTrue(bagDrawn[path], "Bag pager keeps its source art " .. path)
  end
  Assert.isFalse(partyText:find("<", 1, true) ~= nil, "Party arrows are images rather than text glyphs")
  Assert.isFalse(partyText:find(">", 1, true) ~= nil, "Party arrows are images rather than text glyphs")
  Assert.isFalse(bagText:find("Previous", 1, true) ~= nil, "Bag arrow labels remain absent")
  Assert.isFalse(bagText:find("Next", 1, true) ~= nil, "Bag arrow labels remain absent")

  local _, _, _, pressed = draw(
    scope,
    640,
    480,
    topology,
    "party-pager-pressed",
    "Party",
    "Stats",
    nil,
    function(_, view)
      view.capturedTarget = "party:page:next"
    end
  )
  Assert.isTrue(pressed["bag/inc-pressed"], "Party uses the same pressed increment image")
end

function T.party_icons_center_from_distinct_provider_dimensions(scope)
  local size, height = 1280, 720
  local topology = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = size, height = height },
    touch = true,
    role = "world",
  })
  local view, presentation, plan = fixture(scope, size, height, topology, "Party", "Stats")
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
  renderer._bagImages = {
    ["bag/dec-normal"] = scope:own(love.graphics.newImage(love.image.newImageData(12, 12))),
    ["bag/dec-pressed"] = scope:own(love.graphics.newImage(love.image.newImageData(12, 12))),
    ["bag/inc-normal"] = scope:own(love.graphics.newImage(love.image.newImageData(12, 12))),
    ["bag/inc-pressed"] = scope:own(love.graphics.newImage(love.image.newImageData(12, 12))),
  }
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
    local strip = assert(plan.content.layout.partyStrip, "Party layout publishes its member strip")
    for _, slot in ipairs(strip.slots) do
      slot.iconKey = nil
    end
    strip.slots[1].descriptiveLabel = "An exceptionally long nickname that must stay hidden"
    local iconSpecs = {
      { slot = 1, key = "small", rect = { x = 20, y = 72, width = 28, height = 24 } },
      { slot = 1, key = "large", rect = { x = 86, y = 72, width = 32, height = 28 } },
    }
    for _, spec in ipairs(iconSpecs) do
      local slot = assert(strip.slots[spec.slot], "the strip exposes its member position " .. spec.slot)
      slot.iconKey = spec.key
      slot.iconRect = spec.rect
      iconRects[spec.key] = spec.rect
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
    local compactView, compactPresentation, compactPlan = fixture(scope, 256, 192, compact, "Party", "Stats")
    local compactStrip = assert(compactPlan.content.layout.partyStrip)
    for _, slot in ipairs(compactStrip.slots) do
      slot.iconKey = nil
    end
    local compactSlot = assert(compactStrip.slots[1])
    compactSlot.iconKey = "oversized"
    Assert.isNil(compactSlot.textRect, "compact strip has no member text bounds")
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
    iconRects.oversized = compactSlot.iconRect
    iconRects.text = compactSlot.textRect
    draws.oversized = compactDraw
  end, debug.traceback)
  love.graphics.draw = oldDraw
  MonIconAssetProvider.new, AssetPreparationQueue.new = oldProviderNew, oldQueueNew
  renderer:dispose()
  presentation:dispose()
  if not ok then
    error(failure, 0)
  end

  Assert.equal(#draws, 2, "both strip members draw their prepared icons")
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
    table.concat(drawnText, " "):find("Chikorita", 1, true) == nil,
    "strip slots do not render their member identity"
  )
  Assert.isTrue(
    table.concat(drawnText, " "):find("Lv. 5", 1, true) == nil,
    "strip slots do not render the member level"
  )
  Assert.isTrue(
    table.concat(drawnText, " "):find("exceptionally long nickname", 1, true) == nil,
    "long descriptive labels remain metadata and never reach the strip"
  )
  local compactDraw = assert(draws.oversized, "compact strip draws its prepared icon")
  local compactBounds = iconRects.oversized
  Assert.isTrue(compactDraw.scaleX < 1 and compactDraw.scaleY < 1, "compact slots scale a full-size icon to fit")
  Assert.isTrue(
    compactDraw.x >= compactBounds.x
      and compactDraw.y >= compactBounds.y
      and compactDraw.x + dimensions.oversized.width * compactDraw.scaleX <= compactBounds.x + compactBounds.width
      and compactDraw.y + dimensions.oversized.height * compactDraw.scaleY <= compactBounds.y + compactBounds.height,
    "scaled icon stays inside its compact icon rectangle"
  )
  Assert.near(
    compactDraw.x,
    compactBounds.x + (compactBounds.width - dimensions.oversized.width * compactDraw.scaleX) / 2,
    0.01,
    "scaled icon stays centered in its target"
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

function T.typed_location_failure_from_service_renders_with_map_identity_and_context(scope)
  local topology = ScreenTopology.dualDisplay(
    { id = "upper", rect = { x = 0, y = 0, width = 256, height = 192 }, touch = false, role = "world" },
    { id = "lower", rect = { x = 0, y = 192, width = 256, height = 192 }, touch = true, role = "auxiliary" }
  )
  local failure = Errors.new(
    FieldErrors.MAP_PROP_UNCOVERED_DOOR,
    "door tile (9,1) nearest placement is 9.01387818866 tiles away (beyond 5)",
    { x = 9, z = 1, nearestDistance = 9.01387818866 }
  )
  local service = LocationService.new({
    cacheFs = { loadLua = function() return nil end },
    world = {
      schema = MapAssetCache.WORLD_SCHEMA,
      maps = {
        {
          id = 12,
          symbol = "MAP_A_VERY_LONG_SOURCE_MAP_NAME_WITH_A_VISIBLE_POLICY_REASON",
          mapSection = "TEST_SECTION",
          mapSectionNativeId = 1,
          followMode = "ALLOW",
          worldOriginX = 16,
          worldOriginZ = 16,
          matrix = { memberId = 0 },
        },
      },
      byId = { [12] = 1 },
      bySymbol = { MAP_A_VERY_LONG_SOURCE_MAP_NAME_WITH_A_VISIBLE_POLICY_REASON = 12 },
      analysis = { mapHeaderCount = 1, excluded = {} },
    },
    derivedAssets = {},
    savedObjects = { actors = {} },
  })
  scope:own({ release = function() service:dispose() end })
  service.loader = {
    requestMapAssets = function() return true end,
    beginLoad = function()
      return {
        advance = function() error(failure, 0) end,
        isReady = function() return false end,
        release = function() end,
      }
    end,
    release = function() end,
  }
  service:openMap(12)
  service:update()
  local failedLocation = service:snapshot()
  local reason = Errors.format(failure)
  Assert.equal(failedLocation.mapId, 12, "the failed service snapshot retains its requested map identity")
  Assert.equal(failedLocation.status.state, "failed", "the typed loader failure reaches failed status")
  Assert.equal(failedLocation.status.reason, reason, "failed status preserves the typed cause and context")
  Assert.isTrue(reason:find(FieldErrors.MAP_PROP_UNCOVERED_DOOR, 1, true) ~= nil)
  Assert.isTrue(reason:find("nearestDistance=9.01387818866", 1, true) ~= nil)

  local _, renderedText, _, _, _, view = draw(
    scope,
    256,
    384,
    topology,
    "location-literal-error",
    "Location",
    "location-literal-error",
    nil,
    function(_, preparedView)
      preparedView.location.status = failedLocation.status
      preparedView.location.mapId = failedLocation.mapId
    end
  )

  Assert.equal(view.location.mapId, 12, "the renderer receives the service's failed map identity")
  Assert.equal(view.location.status.state, "failed", "the loader failure remains visible in the view")
  Assert.equal(view.location.status.reason, reason, "the structured failure reason remains unchanged")
  Assert.isTrue(renderedText:find("PLAYER{A}", 1, true) ~= nil, "the user name is rendered literally")
  Assert.isTrue(renderedText:find("A_VERY_LONG_SOURCE_{unknown}", 1, true) ~= nil, "the map header keeps its braces literal")
  Assert.isTrue(renderedText:find("MAP_PROP_UNCOVERED_DOOR", 1, true) ~= nil, "the failed Map cause remains displayed")
  Assert.isTrue(renderedText:find("nearestDistance=9.01387818866", 1, true) ~= nil, "the failed Map context remains displayed")
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

function T.location_grid_reserves_room_for_the_current_policy_reason(scope)
  local topology = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 256, height = 192 },
    touch = false,
    role = "world",
  })
  local _, renderedText, layout, _, _, view = draw(
    scope,
    256,
    192,
    topology,
    "location-long-blocked-header",
    "Location",
    "location-long-blocked-header"
  )
  local header = assert(layout.locationHeader)
  Assert.equal(header.rightText, "Impassable tile", "collision policy is explained in plain language")
  Assert.isTrue(header.rightRect.width > 0, "the compact header reserves space for the actual reason")
  Assert.isTrue(header.leftText:find("X 33", 1, true) ~= nil, "coordinates remain visible before map-name truncation")
  Assert.isTrue(header.leftText:find("Z 48", 1, true) ~= nil, "both coordinates remain visible")
  Assert.isTrue(renderedText:find("Impassable tile", 1, true) ~= nil)
  Assert.isTrue(view.location.map.symbol:find("VERY_LONG", 1, true) ~= nil, "the fixture has a long map identity")
end

function T.location_header_explains_focused_policy_causes_and_clears_stale_reason(scope)
  local topology = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 1280, height = 720 },
    touch = false,
    role = "world",
  })
  for _, scenario in ipairs({
    { variant = "location-policy-event", reason = "Event tile" },
    { variant = "location-policy-actor", reason = "Possible actor" },
    { variant = "location-policy-surface", reason = "No walkable surface" },
    { variant = "location-pending-after-blocked", reason = "Preparing…" },
  }) do
    local _, renderedText, layout = draw(
      scope,
      1280,
      720,
      topology,
      scenario.variant,
      "Location",
      scenario.variant
    )
    local header = assert(layout.locationHeader)
    Assert.equal(header.rightText, scenario.reason, scenario.variant .. " maps the focused tile cause")
    Assert.isTrue(renderedText:find(scenario.reason, 1, true) ~= nil)
    if scenario.variant == "location-pending-after-blocked" then
      Assert.isFalse(renderedText:find("Impassable tile", 1, true), "pending focus clears the previous collision reason")
    end
    Assert.isTrue(header.coordinatesText:find("X ", 1, true) ~= nil, "reason changes preserve the coordinates")
  end
end

function T.location_pending_grid_is_flat_gray_without_internal_tile_borders(scope)
  local topology = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 1280, height = 720 },
    touch = false,
    role = "world",
  })
  local data, _, layout, _, _, view, _, _, _, plan = draw(
    scope,
    1280,
    720,
    topology,
    "location-pending-grid",
    "Location",
    "location-pending"
  )
  Assert.equal(view.location.status.state, "preparing", "the fixture represents an unfinished map")
  local grid = assert(layout.locationGrid)
  local boundaryX = grid.originX + grid.tileSize
  local sampleY = grid.originY + math.floor(grid.tileSize / 2)
  local leftR, leftG, leftB = pixelAtLogical(data, plan, boundaryX - 2, sampleY)
  local edgeR, edgeG, edgeB = pixelAtLogical(data, plan, boundaryX, sampleY)
  local rightR, rightG, rightB = pixelAtLogical(data, plan, boundaryX + 2, sampleY)
  for _, channel in ipairs({ { leftR, leftG, leftB }, { edgeR, edgeG, edgeB }, { rightR, rightG, rightB } }) do
    Assert.near(channel[1], 168 / 255, 0.015, "pending terrain is solid neutral gray")
    Assert.near(channel[2], 168 / 255, 0.015, "pending terrain has no internal horizontal stroke")
    Assert.near(channel[3], 168 / 255, 0.015, "pending terrain has no internal vertical stroke")
  end

  local mixedData, _, mixedLayout, _, _, mixedView, _, _, _, mixedPlan = draw(
    scope,
    1280,
    720,
    topology,
    "location-mixed-known-pending",
    "Location"
  )
  local mixedGrid = assert(mixedLayout.locationGrid)
  local knownColumn = 33 - mixedGrid.firstFieldX
  local pendingColumn = 34 - mixedGrid.firstFieldX
  local centerRow = 48 - mixedGrid.firstFieldZ
  local knownRed, knownGreen, knownBlue = pixelAtLogical(
    mixedData,
    mixedPlan,
    mixedGrid.originX + knownColumn * mixedGrid.tileSize + 4,
    mixedGrid.originY + centerRow * mixedGrid.tileSize + 6
  )
  Assert.near(knownRed, 0.73, 0.02, "known blocked terrain keeps its distinct fill")
  Assert.near(knownGreen, 0.75, 0.02, "known blocked terrain keeps its distinct fill")
  Assert.near(knownBlue, 0.75, 0.02, "known blocked terrain keeps its distinct fill")
  local pendingRed, pendingGreen, pendingBlue = pixelAtLogical(
    mixedData,
    mixedPlan,
    mixedGrid.originX + pendingColumn * mixedGrid.tileSize + 4,
    mixedGrid.originY + centerRow * mixedGrid.tileSize + 6
  )
  Assert.near(pendingRed, 168 / 255, 0.015, "unrepresented cells remain neutral gray beside known cells")
  Assert.near(pendingGreen, 168 / 255, 0.015, "unrepresented cells have no fill inferred from neighbors")
  Assert.near(pendingBlue, 168 / 255, 0.015, "unrepresented cells remain distinct from blocked terrain")
  Assert.equal(mixedView.location.tiles[2].reason, "blocked", "fixture includes known and pending cells")
end

function T.location_grid_header_uses_black_single_line_chrome(scope)
  local topology = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 1280, height = 720 },
    touch = false,
    role = "world",
  })
  local _, _, layout, _, _, view, _, _, paletteCalls =
    draw(scope, 1280, 720, topology, "location-grid-header", "Location")
  local header = assert(layout.locationHeader, "the grid publishes one header record")
  local leftCall = assert(findPaletteCall(paletteCalls, "AZALEA_ILEX"), "the header draws its identity line")
  local rightCall = assert(findPaletteCall(paletteCalls, "Impassable tile"), "the header draws its collision reason")
  Assert.equal(leftCall.y, rightCall.y, "identity and disclaimer share one header line")
  Assert.equal(foregroundAverage(leftCall.palette), 0, "the header identity uses a black face")
  Assert.equal(foregroundAverage(rightCall.palette), 0, "the header disclaimer uses a black face")
  Assert.isTrue(
    rightCall.x + view.textMetrics.measure("Impassable tile") <= header.lineRect.x + header.lineRect.width + 0.01,
    "the disclaimer stays inside the header line"
  )
  Assert.isTrue(rightCall.x >= header.leftRect.x + header.leftRect.width, "the disclaimer never overlaps the identity")
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
  for _, row in ipairs(layout.rows) do
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
  Assert.isTrue(renderedText:find("OFF", 1, true) ~= nil, "the flag value remains visible")
  Assert.isTrue(row.labelRect.width > 0 and row.valueRect.width > 0, "layout reserves separate text cells")
  local fittedLabel
  for _, value in ipairs(drawnText) do
    if value:find("HIDE_GOLDENROD", 1, true) == 1 then
      fittedLabel = value
    end
  end
  fittedLabel = assert(fittedLabel, "the stripped flag label is still rendered")
  Assert.isTrue(
    view.textMetrics.measure(fittedLabel) * 0.75 <= row.labelRect.width + 0.01,
    "the label fits its measured cell at body scale"
  )
end

function T.selected_member_renders_identity_in_strip_and_stats_header(scope)
  local width, height = 1280, 720
  local wide = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = width, height = height },
    touch = false,
    role = "world",
  })
  local _, renderedText, layout = draw(scope, width, height, wide, "party-selected-member", "Party", "Stats")
  local strip = assert(layout.partyStrip, "the Party layout publishes its member strip")
  Assert.equal(#strip.slots, 6, "the strip spans six positions")
  Assert.isTrue(strip.slots[1].active, "the first member stays selected")
  Assert.isFalse(renderedText:find("Chikorita", 1, true) ~= nil, "the strip omits member identity text")
  Assert.isFalse(renderedText:find("Lv. 5", 1, true) ~= nil, "the strip omits member level text")
  Assert.isTrue(renderedText:find("Level", 1, true) ~= nil, "the Stats header renders its level fact")
  Assert.isTrue(renderedText:find("Stats", 1, true) ~= nil, "the pager names the current page")
end
function T.party_stats_table_renders_distinct_aligned_columns(scope)
  local width, height = 1280, 720
  local topology = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = width, height = height },
    touch = true,
    role = "world",
  })
  local _, renderedText, layout, _, _, view =
    draw(scope, width, height, topology, "party-stats-table", "Party", "Stats")
  Assert.isTrue(renderedText:find("Stat", 1, true) ~= nil, "the table names the stat column")
  Assert.isTrue(renderedText:find("IV", 1, true) ~= nil, "the table names the IV column")
  Assert.isTrue(renderedText:find("EV", 1, true) ~= nil, "the table names the EV column")
  Assert.isNil(renderedText:find("Derived", 1, true), "computed stat values are omitted")
  Assert.isTrue(renderedText:find("Attack", 1, true) ~= nil, "the stat label is rendered")
  Assert.isTrue(renderedText:find("HP", 1, true) ~= nil, "the header HP fact remains visible")
  Assert.isTrue(renderedText:find("12/19", 1, true) ~= nil, "the header shows current and maximum HP")
  Assert.notNil(layout.partyStatsTable)
  Assert.equal(#layout.partyStatsTable.headers, 3, "the table keeps exactly Stat/IV/EV columns")
  Assert.equal(view.focus, "party:slot:0")

  local compactTopology = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 256, height = 192 },
    touch = true,
    role = "world",
  })
  local _, compactText, compactLayout =
    draw(scope, 256, 192, compactTopology, "party-stats-table-compact", "Party", "Stats")
  Assert.isTrue(compactText:find("Level", 1, true) ~= nil, "compact Stats keeps its header facts")
  Assert.notNil(compactLayout.viewports.party, "compact Stats keeps its scroll viewport")
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
  local rowTarget = assert(focusedLayout.targets["location:map:12"]).rect
  local unfocusedRow = assert(normalLayout.targets["location:map:12"]).rect
  Assert.equal(rowTarget.x, unfocusedRow.x, "focused and unfocused rows share geometry")
  Assert.equal(rowTarget.y, unfocusedRow.y, "focused and unfocused rows share geometry")
  local function assertRowFocusDistinct(target, focusImage, id)
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
  assertRowFocusDistinct(rowTarget, focusedImage, "location:map:12")
  Assert.isNil(focusedLayout.targets["location:map-picker"], "map selection offers no picker control")
  Assert.isNil(focusedLayout.targets["location:map-back"], "map selection offers no nested Back")
  Assert.isNil(focusedText:find("Change Map", 1, true), "no picker label is drawn")
  Assert.isNil(normalText:find("Change Map", 1, true), "no unfocused picker label is drawn")
  local longQuery = focusedView.query
  local fittedHint
  for _, value in ipairs(focusedDrawnText) do
    if value:find("Filter:", 1, true) ~= nil then
      fittedHint = value
    end
  end
  Assert.notNil(fittedHint, "the focused map list renders its inline filter hint")
  local hintRect = assert(focusedLayout.lists["location:group:1"].hintRect, "the map list reserves its hint line")
  Assert.isTrue(
    focusedView.textMetrics.measure(fittedHint) * 0.75 <= hintRect.width + 0.01,
    "hint text fits the reserved line at body scale"
  )
  Assert.isNil(focusedText:find(longQuery, 1, true), "the full query is not emitted")
  local unfocusedHint
  for _, value in ipairs(normalDrawnText) do
    if value:find("Filter:", 1, true) ~= nil then
      unfocusedHint = value
    end
  end
  Assert.notNil(unfocusedHint, "the unfocused map list renders its inline filter hint")
  local normalHintRect = assert(normalLayout.lists["location:group:1"].hintRect)
  Assert.isTrue(
    normalView.textMetrics.measure(unfocusedHint) * 0.75 <= normalHintRect.width + 0.01,
    "unfocused hint text also fits"
  )
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
    fontDef = { lineHeight = 14 },
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
  local frameBoxes, events, fills = {}, {}, {}
  local oldPrint = love.graphics.print
  local oldSetColor, oldRectangle = love.graphics.setColor, love.graphics.rectangle
  local current = { 1, 1, 1, 1 }
  love.graphics.setColor = function(r, g, b, a)
    current = { r, g, b, a }
    return oldSetColor(r, g, b, a)
  end
  love.graphics.rectangle = function(mode, x, y, rectWidth, rectHeight, ...)
    fills[#fills + 1] = {
      mode = mode,
      x = x,
      y = y,
      width = rectWidth,
      height = rectHeight,
      color = { current[1], current[2], current[3], current[4] },
    }
    return oldRectangle(mode, x, y, rectWidth, rectHeight, ...)
  end
  love.graphics.print = function(...)
    events[#events + 1] = "text"
    return oldPrint(...)
  end
  local captured
  local ok, failure = xpcall(function()
    local _, _, layout, _, _, view, background = draw(
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
          events[#events + 1] = "frame"
          frameBoxes[#frameBoxes + 1] = { x = box.x, y = box.y, width = box.width, height = box.height }
          return drawApplicationFrame(self, box, frameIndex)
        end
      end
    )
    captured = { layout = layout, view = view, background = background }
  end, debug.traceback)
  love.graphics.print, love.graphics.setColor, love.graphics.rectangle = oldPrint, oldSetColor, oldRectangle
  if not ok then
    error(failure, 0)
  end
  local layout, background = captured.layout, captured.background
  local pane = assert(captured.view.presentation.panes[1])
  local paintedBackground = false
  for _, fill in ipairs(fills) do
    if
      fill.mode == "fill"
      and fill.x == 0
      and fill.y == 0
      and fill.width == pane.placement.logicalWidth
      and fill.height == pane.placement.logicalHeight
      and math.abs(fill.color[1] - background[1]) < 0.02
      and math.abs(fill.color[2] - background[2]) < 0.02
      and math.abs(fill.color[3] - background[3]) < 0.02
    then
      paintedBackground = true
    end
  end
  Assert.isTrue(paintedBackground, "the ordinary page paints its themed page background")
  local explicit = {}
  for _, surface in ipairs(layout.listSurfaces or {}) do
    explicit[#explicit + 1] = surface
  end
  if layout.decisionList ~= nil then
    explicit[#explicit + 1] = layout.decisionList.surface
  end
  if layout.valueModal ~= nil then
    explicit[#explicit + 1] = layout.valueModal
  end
  for _, frame in ipairs(frameBoxes) do
    local owned = false
    for _, surface in ipairs(explicit) do
      local frameWidth = math.floor(surface.width / 8) * 8
      local frameHeight = math.floor(surface.height / 8) * 8
      local frameX = math.floor(surface.x + (surface.width - frameWidth) / 2 + 0.5)
      local frameY = math.floor(surface.y + (surface.height - frameHeight) / 2 + 0.5)
      if frame.x == frameX and frame.y == frameY and frame.width == frameWidth and frame.height == frameHeight then
        owned = true
      end
    end
    Assert.isTrue(owned, "every application frame belongs to an explicit list or modal surface")
  end
  if #explicit == 0 then
    Assert.equal(#frameBoxes, 0, "the ordinary page draws no blanket content frame")
  else
    local lastText, lastFrame = 0, 0
    for index, event in ipairs(events) do
      if event == "text" then
        lastText = index
      else
        lastFrame = index
      end
    end
    Assert.isTrue(lastFrame > lastText, "explicit frames overlay the content they surround")
  end
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
    local function assertBorderlessRow(targetId)
      local rect = assert(playerLayout.targets[targetId], "player layout exposes " .. targetId).rect
      for _, call in ipairs(rectangleCalls) do
        if
          call.mode == "fill"
          and call.x == rect.x
          and call.y == rect.y
          and call.width == rect.width
          and call.height == rect.height
        then
          Assert.isFalse(
            call.color[1] == 1 and call.color[2] == 1 and call.color[3] == 1,
            targetId .. " paints no synthetic per-row background"
          )
        end
        if
          call.mode == "line"
          and call.x == rect.x
          and call.y == rect.y
          and call.width == rect.width
          and call.height == rect.height
        then
          error(targetId .. " paints no synthetic per-row border", 0)
        end
      end
    end
    assertBorderlessRow("money")
    assertBorderlessRow("dialogue-frame")
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
    -- Party pages are captured once each; every action on the same page
    -- shares its capture instead of re-rendering an identical page.
    local captures = {}
    local function assertActionFaceAndLabel(name, targetId, label)
      local variant = targetId == "party:move:add" and "Moves" or "Details"
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
    local addFace = assertActionFaceAndLabel("hierarchy-party-moves", "party:move:add", "+ Add")
    local clearFace = assertActionFaceAndLabel("hierarchy-party-details", "party:use-species-name", "Use species name")
    Assert.isTrue(
      addFace[1] ~= clearFace[1] or addFace[2] ~= clearFace[2] or addFace[3] ~= clearFace[3],
      "primary add and destructive species-name reset use different faces"
    )

    rectangleCalls = {}
    local _, _, _, _, _, _, _, _, listPalettes =
      draw(scope, 800, 600, topology, "hierarchy-party-add", "Party", "Stats")
    local addCall = assert(findPaletteCall(listPalettes, "+ Add"), "Add button label records its palette")
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

local function singleDisplay(width, height)
  return ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = width, height = height },
    touch = true,
    role = "world",
  })
end

local function recordRectangles(drawFn)
  local oldSetColor, oldRectangle = love.graphics.setColor, love.graphics.rectangle
  local currentColor = { 1, 1, 1, 1 }
  local calls = {}
  love.graphics.setColor = function(r, g, b, a)
    currentColor = { r, g, b, a }
    return oldSetColor(r, g, b, a)
  end
  love.graphics.rectangle = function(mode, x, y, rectWidth, rectHeight, radiusX, radiusY)
    calls[#calls + 1] = {
      mode = mode,
      x = x,
      y = y,
      width = rectWidth,
      height = rectHeight,
      radiusX = radiusX,
      radiusY = radiusY,
      color = { currentColor[1], currentColor[2], currentColor[3], currentColor[4] },
    }
    return oldRectangle(mode, x, y, rectWidth, rectHeight, radiusX, radiusY)
  end
  local ok, result = xpcall(drawFn, debug.traceback)
  love.graphics.setColor, love.graphics.rectangle = oldSetColor, oldRectangle
  if not ok then
    error(result, 0)
  end
  return calls
end

local function surrounds(outer, inner, tolerance)
  return math.abs(outer.x - inner.x) <= tolerance
    and math.abs(outer.y - inner.y) <= tolerance
    and math.abs(outer.x + outer.width - (inner.x + inner.width)) <= tolerance
    and math.abs(outer.y + outer.height - (inner.y + inner.height)) <= tolerance
end

function T.choice_list_marks_the_remembered_row_without_outlining_its_surface(scope)
  local topology = singleDisplay(640, 480)
  local function render(name, focusId, focusVisible)
    local rendered = nil
    local calls = recordRectangles(function()
      local _, _, layout = draw(scope, 640, 480, topology, name, "Player", "choice-list", nil, function(_, view)
        view.focus = focusId
        view.focusVisible = focusVisible
      end)
      rendered = layout
    end)
    return rendered, calls
  end
  local function markerAround(rect, calls)
    local matches = 0
    for _, call in ipairs(calls) do
      if
        call.mode == "line"
        and call.x >= rect.x + 5
        and call.x <= rect.x + 7
        and math.abs(call.width - (rect.width - 12)) <= 2
        and call.radiusX ~= nil
        and call.radiusX > 0
      then
        matches = matches + 1
      end
    end
    return matches
  end

  local containerLayout, containerCalls = render("choice-container", "list:value:choice", true)
  local surface = assert(containerLayout.listSurfaces[1], "the choice list owns one surface")
  local remembered = assert(containerLayout.targets["choice:choice-01"]).rect
  Assert.equal(markerAround(remembered, containerCalls), 1, "the remembered row keeps a rounded inset marker")
  local marker = assert(containerLayout.rowMarkers["choice:choice-01"])
  local label = assert(containerLayout.rowLabelRects["choice:choice-01"])
  Assert.isTrue(label.x - (marker.x + 1) >= 3, "choice glyph bounds clear the marker stroke by at least three pixels")
  for _, call in ipairs(containerCalls) do
    Assert.isFalse(call.mode == "line" and surrounds(call, surface, 3), "the list surface has no focus ring")
  end

  local pointerLayout, pointerCalls = render("choice-pointer", "choice:choice-01", false)
  local pointerRow = assert(pointerLayout.targets["choice:choice-01"]).rect
  Assert.equal(markerAround(pointerRow, pointerCalls), 1, "pointer modality keeps the row marker visible")
end

function T.filterable_lists_render_an_inline_hint_without_search_controls(scope)
  local _, choiceText = draw(scope, 640, 480, singleDisplay(640, 480), "hint-choice", "Player", "choice-list")
  Assert.isNil(choiceText:find("Search", 1, true), "the choice list has no separate search label")
  Assert.isTrue(
    choiceText:find("Type to filter", 1, true) ~= nil or choiceText:find("Filter:", 1, true) ~= nil,
    "the choice list renders its inline filter hint"
  )

  local _, mapText = draw(scope, 256, 192, singleDisplay(256, 192), "hint-map-list", "Location", "map-list")
  Assert.isNil(mapText:find("Search", 1, true), "the map list has no separate search label")
  Assert.isTrue(
    mapText:find("Type to filter", 1, true) ~= nil or mapText:find("Filter:", 1, true) ~= nil,
    "the map list renders its inline filter hint"
  )
end

function T.buttons_use_full_size_labels_with_coherent_middle_tones(scope)
  local TextButton = require("libs.ui.src.TextButton")
  local oldResolve, oldDraw = TextButton.resolve, TextButton.draw
  local scales, palettes = {}, {}
  TextButton.resolve = function(options)
    scales[#scales + 1] = options.scale
    return oldResolve(options)
  end
  TextButton.draw = function(graphics, button, options)
    palettes[#palettes + 1] = options.colors
    return oldDraw(graphics, button, options)
  end
  local ok, failure = xpcall(function()
    draw(scope, 640, 480, singleDisplay(640, 480), "button-shading", "Player", "leave")
  end, debug.traceback)
  TextButton.resolve, TextButton.draw = oldResolve, oldDraw
  if not ok then
    error(failure, 0)
  end
  Assert.isTrue(#scales > 0, "the editor draws its buttons through the shared button seam")
  for _, scale in ipairs(scales) do
    Assert.equal(scale, 1, "buttons never shrink the dialogue label with their rectangle")
  end
  Assert.isTrue(#palettes > 0, "button painting records its semantic palettes")
  for _, colors in ipairs(palettes) do
    for channel = 1, 3 do
      Assert.near(
        colors.innerBorder[channel],
        (colors.faceTop[channel] + colors.faceBottom[channel]) / 2,
        0.01,
        "the button middle tone is the midpoint of its faces"
      )
    end
  end
end

function T.wide_host_resizes_keep_the_content_column_clamped_and_hits_inside_it(scope)
  local cases = {
    { width = 256, height = 192, wide = false },
    { width = 360, height = 640, wide = false },
    { width = 800, height = 600, wide = true },
    { width = 1280, height = 720, wide = true },
    { width = 2560, height = 1080, wide = true },
  }
  for _, case in ipairs(cases) do
    local topology = singleDisplay(case.width, case.height)
    local _, _, layout, _, _, view =
      draw(scope, case.width, case.height, topology, "shell-host-" .. case.width, "Player", nil)
    local pane = assert(view.presentation.panes[1], "the host publishes its interactive pane")
    local placement = assert(pane.placement, "the pane carries the resolved host transform")
    local plan = assert(view.presentation)
    local content = layout.content
    if case.wide then
      local rail = assert(layout.targets["section:Location"], "wide mode publishes the section rail").rect
      Assert.isTrue(content.width <= 384, case.width .. "-pixel host keeps the content at or below 384 logical pixels")
      Assert.isTrue(
        rail.x + rail.width <= content.x,
        "the rail stays left of the content (rail right "
          .. tostring(rail.x + rail.width)
          .. ", content left "
          .. tostring(content.x)
          .. ")"
      )
      Assert.isTrue(content.x >= 8, "wide content keeps its outer left margin")
      Assert.isTrue(
        content.x + content.width <= plan.content.width - 8,
        "wide content keeps its logical outer right margin"
      )
    else
      Assert.notNil(layout.targets["section:Location"], "compact host keeps direct section navigation")
      local section = assert(layout.targets["section:Location"]).rect
      Assert.isTrue(content.y >= section.y + section.height + 2, "compact body begins after top navigation")
    end
    local hostLeft = LayoutGeometry.logicalToHost(placement, content.x, content.y)
    local hostRight = LayoutGeometry.logicalToHost(placement, content.x + content.width, content.y)
    Assert.isTrue(hostRight > hostLeft, "content has a visible host-space width")
    local hostContent = LayoutGeometry.logicalRectToHost(placement, content)
    local hostBounds = placement.frame
    Assert.isTrue(hostContent.x >= hostBounds.x, "content stays inside the resolved host frame")
    Assert.isTrue(
      hostContent.x + hostContent.width <= hostBounds.x + hostBounds.width,
      "content stays inside the resolved host frame after scaling"
    )
    local navigationRect = assert(layout.targets["section:Location"]).rect
    local hitX, hitY = LayoutGeometry.logicalToHost(
      placement,
      navigationRect.x + navigationRect.width / 2,
      navigationRect.y + navigationRect.height / 2
    )
    local logicalX, logicalY = LayoutGeometry.hostToLogical(placement, hitX, hitY)
    local mapped =
      assert(plan.mapInput({ type = "pointer_down", pointerId = "d04", x = logicalX, y = logicalY }, view, plan))
    Assert.equal(mapped.targetId, "section:Location", "the transformed host point resolves to the same section target")
    local footer = assert(layout.targets.back, "the host publishes the Back hit target").rect
    Assert.isTrue(footer.x >= content.x, "the Back hit target stays inside the content column")
    Assert.isTrue(
      footer.x + footer.width <= content.x + content.width,
      "the Back hit target is not stretched beyond content"
    )
  end
end

function T.section_labels_reuse_party_game_font_and_body_scale(scope)
  for _, size in ipairs({ { width = 256, height = 192 }, { width = 1280, height = 720 } }) do
    local width, height = size.width, size.height
    local view, _, plan = fixture(scope, width, height, singleDisplay(width, height), "Party", "Stats")
    local cache = FieldUiFixture.cacheWithFontAndFrames()
    local text = scope:own(FieldTextRenderer.new({ cacheFs = cache, graphics = love.graphics }))
    local renderer = Renderer.new({ text = text, versionId = view.versionId })
    renderer._bagImages = {}
    for _, path in ipairs({ "bag/dec-normal", "bag/dec-pressed", "bag/inc-normal", "bag/inc-pressed" }) do
      renderer._bagImages[path] = scope:own(love.graphics.newImage(love.image.newImageData(12, 12)))
    end
    renderer:preparePresentationAssets(cache, assert(cache:loadLua(FieldUiAssetCache.manifestPath())))
    local calls, currentScale = {}, 1
    local oldScale = love.graphics.scale
    local oldDraw = text.drawTextWithPalette
    love.graphics.scale = function(x, y)
      currentScale = x
      return oldScale(x, y)
    end
    text.drawTextWithPalette = function(self, value, x, y, palette)
      if value == "Map" or value == "Flags" or value == "Party" or value == "Chikorita" then
        calls[value] = { scale = currentScale, width = self:textWidth(value), palette = palette }
      end
      return oldDraw(self, value, x, y, palette)
    end
    local ok, failure = xpcall(function()
      local canvas = scope:own(love.graphics.newCanvas(width, height))
      love.graphics.setCanvas(canvas)
      love.graphics.clear(1, 1, 1, 1)
      ApplicationPresentation.draw(love.graphics, { renderer = renderer, text = text }, view, plan)
    end, debug.traceback)
    love.graphics.setCanvas()
    love.graphics.scale = oldScale
    text.drawTextWithPalette = oldDraw
    local normal = renderer.skin.text.normal
    renderer:dispose()
    if not ok then
      error(failure, 0)
    end
    for _, label in ipairs({ "Map", "Flags" }) do
      local call = assert(calls[label], label .. " uses the field-text renderer")
      Assert.equal(call.scale, 0.75, label .. " uses the list body-label scale at " .. width .. "x" .. height)
      Assert.equal(call.width, view.textMetrics.measure(label), label .. " uses the field-text metric adapter")
      Assert.equal(call.palette.foreground.r, normal.foreground.r, label .. " uses the normal body foreground")
      Assert.equal(call.palette.foreground.g, normal.foreground.g, label .. " uses the normal body foreground")
      Assert.equal(call.palette.foreground.b, normal.foreground.b, label .. " uses the normal body foreground")
      Assert.equal(call.palette.shadow.r, normal.shadow.r, label .. " uses the normal body shadow")
      Assert.equal(call.palette.shadow.g, normal.shadow.g, label .. " uses the normal body shadow")
      Assert.equal(call.palette.shadow.b, normal.shadow.b, label .. " uses the normal body shadow")
    end
    local active = assert(calls.Party, "the active Party section label uses field text")
    Assert.isTrue(
      foregroundAverage(active.palette) > foregroundAverage(assert(calls.Map).palette),
      "the active section remains visually distinct from neutral inactive sections"
    )
    Assert.isNil(calls.Chikorita, "occupied Party slots do not paint their descriptive labels")
  end
end

function T.map_and_flags_use_game_label_treatment_and_clear_painted_frames(scope)
  for _, size in ipairs({ { 256, 192 }, { 360, 640 } }) do
    for _, section in ipairs({ "Location", "Progress" }) do
      local frameBoxes = {}
      local labelCalls = {}
      local _, text, layout = draw(
        scope,
        size[1],
        size[2],
        singleDisplay(size[1], size[2]),
        "section-clearance-" .. section .. "-" .. size[1],
        section,
        section == "Location" and "map-list" or nil,
        nil,
        function(renderer)
          local textRenderer = assert(renderer.text)
          local drawWithPalette = textRenderer.drawTextWithPalette
          textRenderer.drawTextWithPalette = function(self, value, x, y, palette)
            labelCalls[#labelCalls + 1] = { value = value, palette = palette }
            return drawWithPalette(self, value, x, y, palette)
          end
          local windowRenderer = assert(renderer._windowRenderer)
          local drawApplicationFrame = windowRenderer.drawApplicationFrame
          windowRenderer.drawApplicationFrame = function(self, box, frameIndex)
            frameBoxes[#frameBoxes + 1] = box
            return drawApplicationFrame(self, box, frameIndex)
          end
        end
      )
      local expected = section == "Location" and "Map" or "Flags"
      Assert.isTrue(text:find(expected, 1, true) ~= nil, expected .. " is the visible section name")
      local navigationLabel = nil
      for _, item in ipairs(layout.navigation) do
        if item.targetId == "section:" .. section then
          navigationLabel = item.label
        end
      end
      Assert.equal(navigationLabel, expected, "display label changes while the internal target identity stays stable")
      local usedGameText = false
      for _, call in ipairs(labelCalls) do
        if call.value == expected and call.palette ~= nil then
          usedGameText = true
        end
      end
      Assert.isTrue(usedGameText, expected .. " is rendered through the palette-aware game text adapter")
      local stripBottom = 0
      for _, item in ipairs(layout.navigation) do
        if item.targetId:match("^section:") then
          local button = assert(layout.targets[item.targetId]).rect
          stripBottom = math.max(stripBottom, button.y + button.height)
        end
      end
      Assert.isTrue(#frameBoxes > 0, "the section draws its staged application frame")
      local nearestPaintedFrameTop = math.huge
      local frameTopInset = ApplicationLayout.applicationFrameInsets().top
      for _, box in ipairs(frameBoxes) do
        nearestPaintedFrameTop = math.min(nearestPaintedFrameTop, box.y - frameTopInset)
      end
      Assert.isTrue(
        nearestPaintedFrameTop - stripBottom >= 8,
        "top buttons clear the painted frame by at least eight logical pixels"
      )
    end
  end
end

function T.action_buttons_use_reference_faces_and_resolved_focus_radius(scope)
  local Button = require("libs.ui.src.Button")
  local expected = {
    save = { 32, 186, 162 },
    back = { 97, 138, 251 },
    confirm = { 32, 186, 162 },
    cancel = { 97, 138, 251 },
  }
  local cases = {
    { section = "Player", variant = "dirty-status", id = "save", label = "Save" },
    { section = "Player", variant = nil, id = "back", label = "Back" },
    { section = "Player", variant = "number-modal", id = "confirm", label = "Confirm" },
    { section = "Player", variant = "number-modal", id = "cancel", label = "Cancel" },
  }
  for _, case in ipairs(cases) do
    local oldSetColor, oldRectangle = love.graphics.setColor, love.graphics.rectangle
    local currentColor, rings = { 1, 1, 1, 1 }, {}
    love.graphics.setColor = function(r, g, b, a)
      currentColor = { r, g, b, a }
      return oldSetColor(r, g, b, a)
    end
    love.graphics.rectangle = function(mode, x, y, width, height, radiusX, radiusY, ...)
      rings[#rings + 1] = {
        mode = mode,
        x = x,
        y = y,
        width = width,
        height = height,
        radiusX = radiusX,
        radiusY = radiusY,
        color = currentColor,
      }
      return oldRectangle(mode, x, y, width, height, radiusX, radiusY, ...)
    end
    local data, _, layout, _, _, view = draw(
      scope,
      640,
      480,
      singleDisplay(640, 480),
      "action-face-" .. case.id,
      case.section,
      case.variant,
      nil,
      function(_, view)
        view.focus = case.id
        view.focusVisible = true
      end
    )
    love.graphics.setColor, love.graphics.rectangle = oldSetColor, oldRectangle
    local rect = assert(layout.targets[case.id], case.label .. " is a visible action").rect
    local placement = assert(view.presentation.panes[1]).placement
    local lower = (case.id == "save" or case.id == "confirm") and { 40, 121, 113 } or { 48, 89, 195 }
    for _, point in ipairs({
      { y = rect.y + 4, color = expected[case.id], name = "upper" },
      {
        y = rect.y + rect.height / 2,
        color = {
          (expected[case.id][1] + ((case.id == "save" or case.id == "confirm") and 40 or 48)) / 2,
          (expected[case.id][2] + ((case.id == "save" or case.id == "confirm") and 121 or 89)) / 2,
          (expected[case.id][3] + ((case.id == "save" or case.id == "confirm") and 113 or 195)) / 2,
        },
        name = "middle",
      },
      { y = rect.y + rect.height - 4, color = lower, name = "lower" },
    }) do
      local _, hostY = LayoutGeometry.logicalToHost(placement, rect.x, point.y)
      local matched = false
      for logicalX = rect.x + 5, rect.x + rect.width - 5 do
        local hostX = LayoutGeometry.logicalToHost(placement, logicalX, point.y)
        local red, green, blue = data:getPixel(math.floor(hostX), math.floor(hostY))
        local close = true
        for channel, actual in ipairs({ red, green, blue }) do
          if math.abs(actual * 255 - point.color[channel]) > 2 then
            close = false
            break
          end
        end
        if close then
          matched = true
          break
        end
      end
      Assert.isTrue(matched, case.label .. " renders its sampled " .. point.name .. " face color")
    end
    local ringsForAction = {}
    for _, call in ipairs(rings) do
      if
        call.mode == "line"
        and call.x == rect.x + 1
        and call.y == rect.y + 1
        and call.width == rect.width - 2
        and call.height == rect.height - 2
      then
        ringsForAction[#ringsForAction + 1] = call
      end
    end
    Assert.equal(#ringsForAction, 1, case.label .. " has one keyboard focus outline")
    local resolved = Button.resolve({
      rect = rect,
      borderWidth = 1,
      rimWidth = 1,
      innerBorderWidth = 1,
      cornerRadius = 2,
      faceSplit = 0.5,
      contentInsetX = 4,
      contentInsetY = 2,
    })
    local radius = math.max(0, assert(resolved.border.cornerRadius) - 1)
    Assert.equal(ringsForAction[1].radiusX, radius, case.label .. " focus radius follows its resolved button")
    Assert.equal(ringsForAction[1].radiusY, radius, case.label .. " focus radius follows its resolved button")
  end
end

function T.explicit_frames_use_integer_aligned_geometry(scope)
  local boxes = {}
  local function captureBoxes(name, width, height)
    draw(scope, width, height, singleDisplay(width, height), name, "Player", "choice-list", nil, function(renderer)
      local windowRenderer = assert(renderer._windowRenderer)
      local drawApplicationFrame = windowRenderer.drawApplicationFrame
      windowRenderer.drawApplicationFrame = function(self, box, frameIndex)
        boxes[#boxes + 1] = box
        return drawApplicationFrame(self, box, frameIndex)
      end
    end)
  end
  captureBoxes("integer-frame-odd", 255, 191)
  captureBoxes("integer-frame-large", 641, 481)
  Assert.isTrue(#boxes > 0, "the framed list draws its application frame")
  for _, box in ipairs(boxes) do
    Assert.equal(box.x % 1, 0, "frame origins never split a logical pixel")
    Assert.equal(box.y % 1, 0, "frame origins never split a logical pixel")
    Assert.equal(box.width % 8, 0, "frame widths align to the frame tile grid")
    Assert.equal(box.height % 8, 0, "frame heights align to the frame tile grid")
  end
end

function T.party_strip_uses_generic_chrome_without_retail_panels(scope)
  local topology = singleDisplay(800, 600)
  local _, renderedText, layout = draw(scope, 800, 600, topology, "party-strip", "Party", "Stats")
  local member = assert(layout.targets["party:slot:0"]).rect
  local painted = false
  local fills = recordRectangles(function()
    draw(scope, 800, 600, topology, "party-strip-record", "Party", "Stats")
  end)
  for _, call in ipairs(fills) do
    if call.mode == "fill" then
      painted = true
    end
  end
  Assert.isTrue(painted, "member cells paint generic button chrome instead of retail panel art")
  Assert.isTrue(renderedText:find("+ Add", 1, true) ~= nil, "the Add action is a small labeled button")
  Assert.isTrue(
    member.width <= layout.content.width / 6 + 1,
    "strip positions share the strip width instead of card panels"
  )
end
function T.overflowing_viewports_show_a_scroll_cue_and_quiet_ones_do_not(scope)
  local _, _, longLayout = draw(scope, 256, 192, singleDisplay(256, 192), "scroll-overflow", "Player", "choice-list")
  local viewport = assert(longLayout.viewports["value:choice"], "the long choice list publishes its scroll viewport")
  Assert.isTrue(viewport.contentExtent > viewport.clip.height, "the long list overflows its viewport")
  local clip = viewport.clip
  local fills = recordRectangles(function()
    draw(scope, 256, 192, singleDisplay(256, 192), "scroll-overflow-record", "Player", "choice-list")
  end)
  local function thinCueIn(call)
    return call.mode == "fill"
      and call.width <= 3
      and call.x + call.width >= clip.x + clip.width - 4
      and call.x >= clip.x
      and call.y >= clip.y - 1
      and call.y + call.height <= clip.y + clip.height + 1
  end
  local cue = nil
  for _, call in ipairs(fills) do
    if thinCueIn(call) then
      cue = call
    end
  end
  Assert.notNil(cue, "an overflowing viewport draws its scrollbar inside the clip edge")
  Assert.isTrue(cue.height >= 8, "the scrollbar thumb stays visible at minimum size")
  Assert.isTrue(cue.height <= clip.height, "the scrollbar thumb never exceeds its track")

  local _, _, quietLayout = draw(scope, 256, 192, singleDisplay(256, 192), "scroll-quiet", "Location", "map-list")
  local quiet = assert(quietLayout.viewports["location:group:1"], "the short map list publishes its viewport")
  Assert.isFalse(quiet.contentExtent > quiet.clip.height, "the single-map list fits without scrolling")
  local quietClip = quiet.clip
  local quietFills = recordRectangles(function()
    draw(scope, 256, 192, singleDisplay(256, 192), "scroll-quiet-record", "Location", "map-list")
  end)
  for _, call in ipairs(quietFills) do
    Assert.isFalse(
      call.mode == "fill"
        and call.width <= 3
        and call.x + call.width >= quietClip.x + quietClip.width - 4
        and call.x >= quietClip.x
        and call.y >= quietClip.y - 1
        and call.y + call.height <= quietClip.y + quietClip.height + 1,
      "a viewport that fits draws no scrollbar"
    )
  end
end

function T.number_modal_omits_range_and_step_labels(scope)
  local _, renderedText = draw(scope, 640, 480, singleDisplay(640, 480), "number-compact", "Player", "number-modal")
  Assert.isNil(renderedText:find("Range", 1, true), "the compact modal omits range prose")
  for _, step in ipairs({ "+100", "+10", "+1", "-100", "-10", "-1" }) do
    Assert.isNil(renderedText:find(step, 1, true), "the compact modal omits step labels: " .. step)
  end
  for _, digit in ipairs({ "1", "2", "3" }) do
    Assert.isTrue(renderedText:find(digit, 1, true) ~= nil, "each digit is rendered in its own column")
  end
end

function T.pointer_selected_place_stays_visible_after_press_feedback_ends(scope)
  local data, _, layout, _, _, _, _, _, _, plan = draw(
    scope,
    256,
    192,
    singleDisplay(256, 192),
    "number-modal-pointer-place",
    "Player",
    "number-modal",
    nil,
    function(_, view)
      view.focus = "number:place:1:down"
      view.focusVisible = false
      view.valueEditor.selectedPlace = 1
      view.numberHoldTarget = nil
    end
  )
  local number = assert(layout.numberLayout)
  local selected = number.columns[2].digitRect
  local unselected = number.columns[1].digitRect
  local selectedRed = pixelAtLogical(data, plan, selected.x + 1, selected.y + 1)
  local unselectedRed = pixelAtLogical(data, plan, unselected.x + 1, unselected.y + 1)
  Assert.isTrue(selectedRed > unselectedRed + 0.05, "the selected place keeps a visible marker without keyboard focus or a held press")
end

function T.ten_digit_editor_renders_individual_source_arrow_columns(scope)
  for _, size in ipairs({ { 256, 192 }, { 640, 480 } }) do
    local topology = singleDisplay(size[1], size[2])
    local _, renderedText, layout, bagDrawn, drawnText = draw(
      scope,
      size[1],
      size[2],
      topology,
      "number-modal-ten-digit",
      "Player",
      "number-modal-ten-digit"
    )
    local numericLayout = assert(layout.numberLayout, "number layout publishes the shared column geometry")
    Assert.equal(#numericLayout.columns, 10, "unsigned decimal values use ten columns")
    Assert.equal(table.concat((function()
      local digits = {}
      for index, column in ipairs(numericLayout.columns) do
        digits[index] = column.digit
      end
      return digits
    end)()), "0000000001", "leading zeroes remain visible as separate digits")
    Assert.isNil(renderedText:find("0000000001", 1, true), "the renderer does not add an aggregate number label")
    local drawnZeros, drawnOnes = 0, 0
    for _, value in ipairs(drawnText) do
      if value == "0" then
        drawnZeros = drawnZeros + 1
      elseif value == "1" then
        drawnOnes = drawnOnes + 1
      end
    end
    Assert.equal(drawnZeros, 9, "each leading zero is drawn in its own column")
    Assert.equal(drawnOnes, 1, "the least-significant digit is drawn in its own column")
    for _, path in ipairs({ "bag/inc-normal", "bag/dec-normal" }) do
      Assert.isTrue(bagDrawn[path], "numeric columns reuse Bag arrow art: " .. path)
    end
    local _, _, _, pressedUp = draw(
      scope,
      size[1],
      size[2],
      topology,
      "number-modal-ten-digit-pressed-up",
      "Player",
      "number-modal-ten-digit",
      nil,
      function(_, view)
        view.numberHoldTarget = "number:place:0:up"
      end
    )
    Assert.isTrue(pressedUp["bag/inc-pressed"], "held columns use pressed increment art")
    local _, _, _, pressedDown = draw(
      scope,
      size[1],
      size[2],
      topology,
      "number-modal-ten-digit-pressed-down",
      "Player",
      "number-modal-ten-digit",
      nil,
      function(_, view)
        view.numberHoldTarget = "number:place:0:down"
      end
    )
    Assert.isTrue(pressedDown["bag/dec-pressed"], "held columns use pressed decrement art")
  end
end

function T.bag_cards_draw_generic_chrome_without_browse_backgrounds(scope)
  local topology = singleDisplay(640, 480)
  local fake = love.graphics.newImage(love.image.newImageData(256, 192))
  local drawnFake = false
  local oldDraw = love.graphics.draw
  local _, _, layout = draw(scope, 640, 480, topology, "bag-browse", "Bag", "bag-cards", nil, function(renderer, view)
    view.bagBrowseBackground = { image = "synthetic/browse-3" }
    view.bagItemSlots = { { x = 0, y = 0, width = 128, height = 32 } }
    renderer._bagImages["synthetic/browse-3"] = fake
    love.graphics.draw = function(drawable, ...)
      if drawable == fake then
        drawnFake = true
      end
      return oldDraw(drawable, ...)
    end
  end)
  love.graphics.draw = oldDraw
  Assert.isFalse(drawnFake, "item cards never draw the pocket browse background")
  local card = assert(layout.bagGrid[1])
  Assert.notNil(card.nameRect, "cards keep their generic name region without browse geometry")
  Assert.notNil(card.quantityRect, "cards keep their generic quantity region without browse geometry")
end

function T.bag_page_arrows_point_in_opposite_directions(scope)
  local _, _, _, _, _, _, _, drawOrder =
    draw(scope, 640, 480, singleDisplay(640, 480), "bag-arrow-direction", "Bag", "bag-pages")
  local previous, next = nil, nil
  for _, entry in ipairs(drawOrder) do
    if entry.path == "bag/dec-normal" then
      previous = entry.args[3]
    elseif entry.path == "bag/inc-normal" then
      next = entry.args[3]
    end
  end
  Assert.notNil(previous, "the Previous arrow draws its decrement art")
  Assert.notNil(next, "the Next arrow draws its increment art")
  Assert.near(previous, math.pi / 2, 0.01, "Previous points left")
  Assert.near(next, math.pi / 2, 0.01, "Next points right from the opposite source art")
end

function T.framed_lists_draw_their_frame_after_their_content(scope)
  local events = {}
  local oldPrint = love.graphics.print
  love.graphics.print = function(...)
    events[#events + 1] = "text"
    return oldPrint(...)
  end
  local ok, failure = xpcall(function()
    draw(scope, 640, 480, singleDisplay(640, 480), "frame-order", "Player", "choice-list", nil, function(renderer)
      local windowRenderer = assert(renderer._windowRenderer)
      local drawApplicationFrame = windowRenderer.drawApplicationFrame
      windowRenderer.drawApplicationFrame = function(self, box, frameIndex)
        events[#events + 1] = "frame"
        return drawApplicationFrame(self, box, frameIndex)
      end
    end)
  end, debug.traceback)
  love.graphics.print = oldPrint
  if not ok then
    error(failure, 0)
  end
  local lastText, lastFrame = 0, 0
  for index, event in ipairs(events) do
    if event == "text" then
      lastText = index
    else
      lastFrame = index
    end
  end
  Assert.isTrue(lastFrame > 0, "the framed list draws its application frame")
  Assert.isTrue(lastText > 0, "the framed list draws its content")
  Assert.isTrue(lastFrame > lastText, "the application frame overlays the content it surrounds")
end

function T.nested_party_actions_use_semantic_button_faces(scope)
  local width, height = 1280, 720
  local topology = singleDisplay(width, height)
  local _, renderedText, layout, _, _, _, _, _, palettes =
    draw(scope, width, height, topology, "nested-actions", "Party", "Moves")
  Assert.notNil(layout.targets["party:move:add"], "the first empty move slot stays activatable")
  local addCall = assert(findPaletteCall(palettes, "+ Add"), "the move Add label records its palette")
  Assert.isTrue(
    assert(foregroundAverage(addCall.palette), "move Add has a foreground") > 150,
    "adding a move uses light primary ink"
  )
  local _, overlayText, overlayLayout = draw(scope, width, height, topology, "nested-overlay", "Party", "party-move")
  for _, label in ipairs({ "Move", "Current PP", "PP Ups" }) do
    Assert.isTrue(overlayText:find(label, 1, true) ~= nil, "the move overlay exposes " .. label)
  end
  for _, targetId in ipairs({ "party-move:move", "party-move:pp", "party-move:pp-ups" }) do
    Assert.notNil(overlayLayout.targets[targetId], "the overlay keeps " .. targetId .. " activatable")
  end
  Assert.isTrue(overlayText:find("Remove", 1, true) == nil, "the move overlay offers no removal action")
  Assert.isTrue(renderedText:find("Remove", 1, true) == nil, "the Moves page offers no removal action")
end

function T.party_move_dialog_keeps_the_page_and_uses_its_own_title(scope)
  local width, height = 640, 480
  local _, renderedText =
    draw(scope, width, height, singleDisplay(width, height), "party-move-layer", "Party", "party-move")
  Assert.isTrue(
    renderedText:find("Edit move: Tackle", 1, true) ~= nil,
    "the move dialog title names the selected move instead of showing the leave prompt"
  )
  for _, label in ipairs({ "Move", "Current PP", "PP Ups", "Back" }) do
    Assert.isTrue(renderedText:find(label, 1, true) ~= nil, "the move dialog shows " .. label)
  end
  Assert.isNil(renderedText:find("Save every section before leaving", 1, true))
end

function T.party_move_dialog_retains_and_composites_the_page(scope)
  local width, height = 640, 480
  local baseData, _, baseLayout, _, _, _, _, _, _, basePlan =
    draw(scope, width, height, singleDisplay(width, height), "party-move-base", "Party", "Moves")
  local data, _, layout, _, _, _, _, _, _, plan =
    draw(scope, width, height, singleDisplay(width, height), "party-move-layers", "Party", "party-move")
  local uncovered = assert(baseLayout.partyStrip and baseLayout.partyStrip.slots[1]).rect
  local modal = assert(layout.decisionList and layout.decisionList.surface)
  local foundOpaque = false
  for y = modal.y + 4, modal.y + modal.height - 4, 4 do
    for x = modal.x + 4, modal.x + modal.width - 4, 4 do
      local red, green, blue = pixelAtLogical(data, plan, x, y)
      foundOpaque = foundOpaque or (red > 0.95 and green > 0.95 and blue > 0.95)
    end
  end
  Assert.isTrue(foundOpaque, "the modal interior paints an opaque fill over the Party page")

  local dimmedPagePixel = false
  for y = uncovered.y + 2, uncovered.y + uncovered.height - 2, 3 do
    for x = uncovered.x + 2, uncovered.x + uncovered.width - 2, 3 do
      local baseR, baseG, baseB = pixelAtLogical(baseData, basePlan, x, y)
      local modalR, modalG, modalB = pixelAtLogical(data, plan, x, y)
      if baseR + baseG + baseB - modalR - modalG - modalB > 0.08 then
        dimmedPagePixel = true
      end
    end
  end
  Assert.isTrue(dimmedPagePixel, "at least one painted member-strip pixel is dimmed outside the move dialog")
  Assert.isTrue(
    type(layout.renderLayers) == "table" and #layout.renderLayers >= 2,
    "the layout retains both the Party page and the move dialog as render layers"
  )

  local nestedData, _, nestedLayout, _, _, _, _, _, _, nestedPlan =
    draw(scope, width, height, singleDisplay(width, height), "party-move-child-layers", "Party", "party-move-child")
  local parentLayer = assert(nestedLayout.renderLayers[2])
  local childLayer = assert(nestedLayout.renderLayers[3])
  local parentSurface = assert(parentLayer.layout.decisionList).surface
  local childSurface = assert(childLayer.layout.valueModal)
  Assert.equal(parentLayer.kind, "move", "the move stays below its nested editor")
  Assert.equal(childLayer.kind, "number", "the nested number editor stays on top")
  local occludedParentText = false
  for y = parentSurface.y, parentSurface.y + parentSurface.height do
    for x = parentSurface.x, parentSurface.x + parentSurface.width do
      if
        x >= childSurface.x
        and x < childSurface.x + childSurface.width
        and y >= childSurface.y
        and y < childSurface.y + childSurface.height
      then
        local parentR, parentG, parentB = pixelAtLogical(data, plan, x, y)
        local childR, childG, childB = pixelAtLogical(nestedData, nestedPlan, x, y)
        if parentR + parentG + parentB < 2.7 and childR > 0.95 and childG > 0.95 and childB > 0.95 then
          occludedParentText = true
        end
      end
    end
  end
  Assert.isTrue(occludedParentText, "the nested editor covers parent title pixels with its opaque surface")
  local exposedParent = false
  for y = parentSurface.y + 2, parentSurface.y + parentSurface.height - 2, 2 do
    for x = parentSurface.x + 2, parentSurface.x + parentSurface.width - 2, 2 do
      local outsideChild = x < childSurface.x
        or x >= childSurface.x + childSurface.width
        or y < childSurface.y
        or y >= childSurface.y + childSurface.height
      if outsideChild then
        local parentR, parentG, parentB = pixelAtLogical(data, plan, x, y)
        local nestedR, nestedG, nestedB = pixelAtLogical(nestedData, nestedPlan, x, y)
        local baseR, baseG, baseB = pixelAtLogical(baseData, basePlan, x, y)
        exposedParent = exposedParent
          or parentR > 0.95
            and parentG > 0.95
            and parentB > 0.95
            and nestedR < 0.8
            and nestedG < 0.8
            and nestedB < 0.8
            and nestedR + nestedG + nestedB > baseR + baseG + baseB + 0.1
      end
    end
  end
  Assert.isTrue(exposedParent, "uncovered parent modal content remains visible under the child")
end
function T.number_editor_dims_the_retained_page(scope)
  local width, height = 640, 480
  local baseData, _, baseLayout, _, _, _, _, _, _, basePlan =
    draw(scope, width, height, singleDisplay(width, height), "number-base", "Player", nil)
  local modalData, _, layout, _, _, _, _, _, _, modalPlan =
    draw(scope, width, height, singleDisplay(width, height), "number-modal", "Player", "number-modal")
  local modal = assert(layout.valueModal)
  local content = assert(baseLayout.content)
  local dimmedPage = false
  for y = content.y + 2, content.y + content.height - 2, 3 do
    for x = content.x + 2, content.x + content.width - 2, 3 do
      local outsideModal = x < modal.x
        or x >= modal.x + modal.width
        or y < modal.y
        or y >= modal.y + modal.height
      if outsideModal then
        local baseR, baseG, baseB = pixelAtLogical(baseData, basePlan, x, y)
        local modalR, modalG, modalB = pixelAtLogical(modalData, modalPlan, x, y)
        local expectedR, expectedG, expectedB = baseR * 0.58, baseG * 0.58, baseB * 0.58
        if
          baseR + baseG + baseB > 0.6
          and math.abs(modalR - expectedR) < 0.04
          and math.abs(modalG - expectedG) < 0.04
          and math.abs(modalB - expectedB) < 0.04
        then
          dimmedPage = true
        end
      end
    end
  end
  Assert.isTrue(dimmedPage, "the number layer dims retained page pixels outside its opaque body")
end

function T.framed_modals_draw_their_frame_after_their_content(scope)
  local events = {}
  local oldPrint = love.graphics.print
  love.graphics.print = function(...)
    events[#events + 1] = "text"
    return oldPrint(...)
  end
  local modal = nil
  local ok, failure = xpcall(function()
    local _, _, layout = draw(
      scope,
      640,
      480,
      singleDisplay(640, 480),
      "frame-order-modal",
      "Player",
      "leave",
      nil,
      function(renderer)
        local windowRenderer = assert(renderer._windowRenderer)
        local drawApplicationFrame = windowRenderer.drawApplicationFrame
        windowRenderer.drawApplicationFrame = function(self, box, frameIndex)
          events[#events + 1] = "frame"
          return drawApplicationFrame(self, box, frameIndex)
        end
      end
    )
    modal = layout.decisionList
  end, debug.traceback)
  love.graphics.print = oldPrint
  if not ok then
    error(failure, 0)
  end
  local lastText, frameCount = 0, 0
  for index, event in ipairs(events) do
    if event == "text" then
      lastText = index
    else
      frameCount = frameCount + 1
    end
  end
  Assert.isTrue(frameCount >= 1, "the modal draws its application frame without pinning an exact total")
  Assert.isTrue(lastText > 0, "the modal draws its content")
  local framePositions = {}
  for index, event in ipairs(events) do
    if event == "frame" then
      framePositions[#framePositions + 1] = index
    end
  end
  Assert.isTrue(framePositions[#framePositions] > lastText, "the modal frame overlays the content it surrounds")
  Assert.notNil(modal, "the leave decision publishes its framed surface")
end

local function solidPanel(scope, red, green, blue)
  local data = scope:own(love.image.newImageData(128, 48))
  data:mapPixel(function()
    return red, green, blue, 1
  end)
  return love.graphics.newImage(data)
end

function T.selected_member_marks_active_chrome_without_focus_ring(scope)
  local topology = singleDisplay(800, 600)
  draw(scope, 800, 600, topology, "party-strip-focused", "Party", "Stats")
  local member = nil
  local fills = recordRectangles(function()
    local _, _, layout = draw(scope, 800, 600, topology, "party-strip-focused-record", "Party", "Stats")
    member = assert(layout.targets["party:slot:0"]).rect
  end)
  local function ringAt(calls)
    for _, call in ipairs(calls) do
      if
        call.mode == "line"
        and call.x == member.x + 1
        and call.y == member.y + 1
        and call.width == member.width - 2
        and call.height == member.height - 2
      then
        return true
      end
    end
    return false
  end
  Assert.isTrue(ringAt(fills), "keyboard focus draws its ring around the focused strip member")

  local quietFills = recordRectangles(function()
    draw(scope, 800, 600, topology, "party-strip-quiet-record", "Party", "Stats", nil, function(_, view)
      view.focus = "party:add"
    end)
  end)
  Assert.isFalse(ringAt(quietFills), "the selected member draws no focus ring while another control has focus")
end
function T.fainted_party_members_show_fainted_status(scope)
  local topology = singleDisplay(1280, 720)
  local _, renderedText, layout = draw(scope, 1280, 720, topology, "party-fainted-status", "Party", "fainted")
  Assert.notNil(layout.targets["party:field:currentHp"], "a fainted member keeps its HP editor")
  Assert.isTrue(renderedText:find("0/19", 1, true) ~= nil, "a fainted member shows zero current HP")
  Assert.isTrue(renderedText:find("FNT", 1, true) ~= nil, "a fainted member shows its fainted status")
end

function T.bag_icon_preparation_needs_no_browse_or_focus_art(scope)
  local RendererModule = require("app.src.saveeditor.SaveEditorRenderer")
  local iconImage = scope:own(love.graphics.newImage(love.image.newImageData(16, 16)))
  local iconQuad = scope:own(love.graphics.newQuad(0, 0, 16, 16, 16, 16))
  local renderer = RendererModule.new({
    versionId = "heartgold",
    text = {
      fontDef = { lineHeight = 14 },
      textWidth = function()
        return 0
      end,
      drawText = function() end,
      drawTextWithPalette = function() end,
    },
  })
  local visuals = {
    decrement = { normal = { image = "bag/dec-normal" }, pressed = { image = "bag/dec-pressed" } },
    increment = { normal = { image = "bag/inc-normal" }, pressed = { image = "bag/inc-pressed" } },
  }
  for _, direction in ipairs({ "decrement", "increment" }) do
    for _, pressed in ipairs({ "normal", "pressed" }) do
      renderer._bagImages[visuals[direction][pressed].image] =
        scope:own(love.graphics.newImage(love.image.newImageData(12, 12)))
    end
  end
  renderer._bagImages["bag/items-strip"] = scope:own(love.graphics.newImage(love.image.newImageData(256, 32)))
  renderer._itemIconProvider = {
    image = function()
      return iconImage
    end,
    quadFor = function()
      return iconQuad
    end,
    dimensions = function()
      return { width = 16, height = 16 }
    end,
    release = function() end,
  }
  local view = {
    section = "Bag",
    bagPocketStrip = { image = "bag/items-strip" },
    bagQuantityVisuals = visuals,
  }
  local plan = { content = { layout = { bagGrid = { { iconKey = "POTION" } } } } }
  local cacheFs = {
    read = function(_, path)
      error("unexpected Bag asset read: " .. tostring(path), 2)
    end,
  }
  local ok, failure = pcall(function()
    renderer:prepareVisibleIcons(view, plan, cacheFs, {})
  end)
  Assert.isTrue(ok, "preparation succeeds without browse or focus art")
  if not ok then
    error(tostring(failure), 0)
  end
  Assert.notNil(renderer._icons.POTION, "visible item icons are still prepared")
  Assert.equal(renderer.iconStatus, "ready", "icon status still resolves")
  Assert.isNil(renderer._bagQuads, "browse slot quads are gone with the native card")
  renderer:dispose()
end

local function recordOutlinedRectangles()
  local oldSetColor, oldRectangle = love.graphics.setColor, love.graphics.rectangle
  local currentColor = { 1, 1, 1, 1 }
  local calls = {}
  love.graphics.setColor = function(r, g, b, a)
    currentColor = { r, g, b, a }
    return oldSetColor(r, g, b, a)
  end
  love.graphics.rectangle = function(mode, x, y, rectWidth, rectHeight, radiusX, radiusY, ...)
    if mode == "line" then
      calls[#calls + 1] = {
        x = x,
        y = y,
        width = rectWidth,
        height = rectHeight,
        radiusX = radiusX,
        radiusY = radiusY,
        color = { currentColor[1], currentColor[2], currentColor[3], currentColor[4] },
      }
    end
    return oldRectangle(mode, x, y, rectWidth, rectHeight, radiusX, radiusY, ...)
  end
  return calls, function()
    love.graphics.setColor, love.graphics.rectangle = oldSetColor, oldRectangle
  end
end

local function ringsSurrounding(calls, rect, tolerance)
  local matches = {}
  for _, call in ipairs(calls) do
    if surrounds(call, rect, tolerance) then
      matches[#matches + 1] = call
    end
  end
  return matches
end

function T.numeric_focus_ring_surrounds_the_digit_and_not_its_arrows(scope)
  local topology = singleDisplay(640, 480)
  local calls, restore = recordOutlinedRectangles()
  local layout, bagDrawn
  local ok, failure = xpcall(function()
    local _, _, resolved, drawnBag = draw(
      scope,
      640,
      480,
      topology,
      "number-modal-digit-focus-ring",
      "Player",
      "number-modal",
      nil,
      function(_, view)
        view.focus = "number:place:1:up"
        view.focusVisible = true
        view.valueEditor.selectedPlace = 1
        view.numberHoldTarget = "number:place:1:up"
      end
    )
    layout, bagDrawn = resolved, drawnBag
  end, debug.traceback)
  restore()
  if not ok then
    error(failure, 0)
  end

  local columns = assert(layout.numberLayout).columns
  local selectedDigit = columns[2].digitRect
  Assert.equal(#ringsSurrounding(calls, selectedDigit, 3), 1, "one outline surrounds the focused digit")
  for _, column in ipairs(columns) do
    Assert.equal(#ringsSurrounding(calls, column.upRect, 3), 0, "digit focus draws no ring around an increment arrow")
    Assert.equal(#ringsSurrounding(calls, column.downRect, 3), 0, "digit focus draws no ring around a decrement arrow")
  end
  Assert.isTrue(bagDrawn["bag/inc-pressed"], "the focused column keeps its pressed arrow art")
end

function T.bag_focused_cards_draw_exactly_one_keyboard_ring(scope)
  local topology = singleDisplay(640, 480)
  local function render(name, focusVisible)
    local calls, restore = recordOutlinedRectangles()
    local _, _, layout
    local ok, failure = xpcall(function()
      _, _, layout = draw(scope, 640, 480, topology, name, "Bag", "bag-cards", nil, function(_, view)
        view.focus = "bag:item:POTION"
        view.focusVisible = focusVisible
      end)
    end, debug.traceback)
    restore()
    if not ok then
      error(failure, 0)
    end
    return layout, calls
  end
  local layout, calls = render("bag-ring-visible", true)
  local card = assert(layout.bagGrid[1]).rect
  Assert.equal(#ringsSurrounding(calls, card, 3), 1, "exactly one outline surrounds the keyboard-focused card")
  local hiddenLayout, hiddenCalls = render("bag-ring-hidden", false)
  local hiddenCard = assert(hiddenLayout.bagGrid[1]).rect
  Assert.equal(#ringsSurrounding(hiddenCalls, hiddenCard, 3), 0, "pointer modality draws no outline around the card")
end

function T.focused_buttons_draw_geometry_matched_outlines_only_while_navigation_is_visible(scope)
  local Button = require("libs.ui.src.Button")
  local topology = singleDisplay(640, 480)
  local function render(focusVisible)
    local calls, restore = recordOutlinedRectangles()
    local _, _, layout
    local ok, failure = xpcall(function()
      _, _, layout = draw(
        scope,
        640,
        480,
        topology,
        focusVisible and "ring-visible" or "ring-hidden",
        "Player",
        nil,
        nil,
        function(_, view)
          view.focus = "back"
          view.focusVisible = focusVisible
        end
      )
    end, debug.traceback)
    restore()
    if not ok then
      error(failure, 0)
    end
    return layout, calls
  end
  local layout, calls = render(true)
  local back = assert(layout.targets["back"], "the footer publishes its back target").rect
  local rings = ringsSurrounding(calls, back, 3)
  Assert.equal(#rings, 1, "exactly one outline surrounds the focused button")
  local resolved = Button.resolve({
    rect = back,
    borderWidth = 1,
    rimWidth = 1,
    innerBorderWidth = 1,
    cornerRadius = 2,
    faceSplit = 0.5,
    contentInsetX = 4,
    contentInsetY = 2,
  })
  local expectedRadius = math.max(0, assert(resolved.border.cornerRadius) - 1)
  Assert.equal(rings[1].radiusX, expectedRadius, "the outline radius follows the resolved border geometry")
  Assert.equal(rings[1].radiusY, expectedRadius, "the outline radius follows the resolved border geometry")

  local hiddenLayout, hiddenCalls = render(false)
  local hiddenBack = assert(hiddenLayout.targets["back"], "the footer publishes its back target").rect
  Assert.equal(
    #ringsSurrounding(hiddenCalls, hiddenBack, 3),
    0,
    "pointer modality draws no outline around the focused button"
  )
end

function T.active_section_chrome_survives_focus_movement(scope)
  local Button = require("libs.ui.src.Button")
  local oldDraw = Button.draw
  local painted = {}
  Button.draw = function(graphics, button, palette)
    painted[#painted + 1] = palette
    return oldDraw(graphics, button, palette)
  end
  local calls, restoreRectangles = recordOutlinedRectangles()
  local layout
  local ok, failure = xpcall(function()
    _, _, layout = draw(
      scope,
      1280,
      1080,
      singleDisplay(1280, 1080),
      "active-chrome",
      "Player",
      nil,
      nil,
      function(_, view)
        view.focus = "money"
        view.focusVisible = true
      end
    )
  end, debug.traceback)
  restoreRectangles()
  Button.draw = oldDraw
  if not ok then
    error(failure, 0)
  end
  Assert.notNil(layout.targets["section:Player"], "the wide layout keeps its section rail")
  local function faceAverage(colors)
    return (
      (colors.faceTop[1] + colors.faceBottom[1]) / 2
      + (colors.faceTop[2] + colors.faceBottom[2]) / 2
      + (colors.faceTop[3] + colors.faceBottom[3]) / 2
    ) / 3
  end
  local activeSection, inactiveSections = painted[2], { painted[1], painted[3], painted[4], painted[5] }
  Assert.notNil(activeSection, "the active section paints its option chrome")
  Assert.isTrue(faceAverage(activeSection) < 0.9, "the active section keeps its colored face")
  for _, palette in ipairs(inactiveSections) do
    Assert.isTrue(
      faceAverage(assert(palette)) > 0.9,
      "inactive sections use a near-white face while another control has focus"
    )
  end
  local money = assert(layout.targets["money"], "the content publishes its focused row").rect
  Assert.equal(#ringsSurrounding(calls, money, 3), 1, "only the truly focused row owns an outline")
  for _, targetId in ipairs({ "section:Player", "section:Party", "section:Bag" }) do
    local rect = assert(layout.targets[targetId], "the rail publishes " .. targetId).rect
    Assert.equal(#ringsSurrounding(calls, rect, 3), 0, targetId .. " owns no outline while unfocused")
  end
end

function T.compact_number_fallback_draws_a_cancelable_notice(scope)
  local topology = singleDisplay(256, 192)
  local _, _, layout, _, drawnText = draw(
    scope,
    256,
    192,
    topology,
    "number-modal-too-small",
    "Player",
    "number-modal-too-small"
  )

  Assert.isTrue(layout.numberTooSmall, "a compact host with insufficient active content publishes fallback mode")
  Assert.isNil(layout.numberLayout, "the fallback draws no invisible numeric geometry")
  Assert.isNil(layout.targets.confirm, "the fallback has no hidden Confirm target")
  Assert.notNil(layout.targets.cancel, "the fallback retains a visible Back target")
  local fallbackText = table.concat(drawnText, " ")
  Assert.isTrue(fallbackText:find("Back", 1, true) ~= nil, "the visible cancel action is labeled Back")
  Assert.isNil(fallbackText:find("Cancel", 1, true), "the fallback does not draw the obsolete Cancel label")
  Assert.isTrue(
    table.concat(drawnText, " "):find("Expand window", 1, true) ~= nil,
    "the renderer paints the unavailable-state notice"
  )
end

function T.graphics_state_is_restored_after_rings_and_scaled_text(scope)
  local topology = singleDisplay(640, 480)
  draw(scope, 640, 480, topology, "state-restore-choice", "Player", "choice-list")
  Assert.equal(love.graphics.getLineWidth(), 1, "focus rings restore the line width")
  draw(scope, 800, 600, topology, "state-restore-party", "Party", "draft")
  Assert.equal(love.graphics.getLineWidth(), 1, "detail pages restore the line width")
  -- A non-default caller state keeps the draw-helper comparison honest:
  -- painters that reset graphics state to defaults instead of restoring the
  -- caller would pass a default-state comparison but fail here. The scissor
  -- covers the full canvas so no tested content is clipped away.
  draw(scope, 640, 480, topology, "state-restore-bag-sentinel", "Bag", "bag-cards", nil, function()
    love.graphics.setColor(0.2, 0.4, 0.6, 0.8)
    love.graphics.setBlendMode("replace")
    love.graphics.setLineWidth(3)
    love.graphics.setScissor(0, 0, 640, 480)
  end)
  Assert.equal(love.graphics.getLineWidth(), 3, "bag cards restore the non-default caller line width")
end

return GraphicsSmoke.suite(T, { capabilities = { "graphics" } })
