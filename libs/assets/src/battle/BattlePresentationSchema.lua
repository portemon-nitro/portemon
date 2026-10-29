-- Authoritative validation for the generated battle presentation class:
-- the staged global manifest, one composed scene record, and exact launch
-- demands. Runtime-facing records use semantic keys only: physical archive
-- and member identities are rejected at any depth. Love-free and
-- filesystem-free.

local SchemaCheck = require("libs.assets.src.SchemaCheck")
local Validate = require("libs.assets.src.Validate")

---@class BattlePresentationSchema
local BattlePresentationSchema = {}

BattlePresentationSchema.MANIFEST_SCHEMA = "g4-battle-presentation-v8"
BattlePresentationSchema.SCENE_SCHEMA = "g4-battle-scene-v3"

local fail = SchemaCheck.fail

local CODE_MANIFEST = "BATTLE_PRESENTATION_INVALID"
local CODE_SCENE = "BATTLE_SCENE_INVALID"
local CODE_DEMAND = "BATTLE_DEMAND_INVALID"

-- Scene axes behind semantic keys. These are the runtime/mod-facing scene
-- selectors; the producer owns the member mapping behind them.
local BACKGROUNDS = {
  general = true,
  ocean = true,
  city = true,
  forest = true,
  mountain = true,
  snow = true,
  building_1 = true,
  building_2 = true,
  building_3 = true,
  cave_1 = true,
  cave_2 = true,
  cave_3 = true,
  will = true,
  koga = true,
  bruno = true,
  karen = true,
  lance = true,
  distortion_world = true,
}

local TERRAINS = {
  plain = true,
  sand = true,
  grass = true,
  puddle = true,
  mountain = true,
  cave = true,
  snow = true,
  water = true,
  ice = true,
  building = true,
  great_marsh = true,
  unknown = true,
  will = true,
  koga = true,
  bruno = true,
  karen = true,
  lance = true,
  distortion_world = true,
}

local TIMES = { day = true, evening = true, night = true }

local function checkInt(value, lower, upper, context, code, field)
  SchemaCheck.checkInteger(value, context, code, field, lower, upper)
end

local function checkString(value, context, code, field)
  SchemaCheck.checkNonEmptyString(value, context, code, field)
end

local function checkStringArray(values, context, code, field)
  if not Validate.isArray(values) then
    fail(code, field .. " must be an ordered string list", context)
  end
  for index, value in ipairs(values) do
    checkString(value, context, code, field .. "[" .. index .. "]")
  end
end

local function checkImagePath(value, context, code, field)
  checkString(value, context, code, field)
end

local SHA1_TEXT = "^" .. ("%x"):rep(40) .. "$"

local function isSha1Text(value)
  return type(value) == "string" and value:match(SHA1_TEXT) ~= nil
end

local function contains(values, wanted)
  for _, value in ipairs(values) do
    if value == wanted then
      return true
    end
  end
  return false
end

local function valueSet(values)
  local set = {}
  for _, value in ipairs(values) do
    set[value] = true
  end
  return set
end

local function countKeys(record)
  local count = 0
  for _ in pairs(record) do
    count = count + 1
  end
  return count
end

-- True when `values` is exactly the ordered literal list `expected`.
local function isExactList(values, expected)
  if not Validate.isArray(values) or #values ~= #expected then
    return false
  end
  for index, value in ipairs(expected) do
    if values[index] ~= value then
      return false
    end
  end
  return true
end

local function checkSlotGeometry(battlefield, context, code)
  SchemaCheck.checkRecord(battlefield, { slots = true }, context, code, "manifest battlefield")
  if not Validate.isArray(battlefield.slots) or #battlefield.slots ~= 6 then
    fail(code, "manifest battlefield must publish six native slot records", context)
  end
  local sideTypes = {}
  for index, row in ipairs(battlefield.slots) do
    local field = "manifest battlefield.slots[" .. index .. "]"
    SchemaCheck.checkRecord(row, {
      sideType = true,
      settledX = true,
      settledY = true,
      entryX = true,
      entryY = true,
      depth = true,
      hudX = true,
      hudY = true,
      hudPriority = true,
      hudBgPriority = true,
    }, context, code, field)
    checkInt(row.sideType, 0, 5, context, code, field .. ".sideType")
    if sideTypes[row.sideType] then
      fail(code, "manifest battlefield slot side types must be unique", context)
    end
    sideTypes[row.sideType] = true
    for _, coordinate in ipairs({ "settledX", "settledY", "entryX", "entryY", "depth", "hudX", "hudY" }) do
      checkInt(row[coordinate], -2048, 2047, context, code, field .. "." .. coordinate)
    end
    checkInt(row.hudPriority, 0, 31, context, code, field .. ".hudPriority")
    checkInt(row.hudBgPriority, 0, 3, context, code, field .. ".hudBgPriority")
  end
  for _, sideType in ipairs({ 0, 1, 2, 3, 4, 5 }) do
    if not sideTypes[sideType] then
      fail(code, "manifest battlefield slot geometry must cover every side type", context)
    end
  end
end

local NATIVE_KEYS = {
  memberId = true,
  fileId = true,
  narcId = true,
  armAddress = true,
  callbackAddress = true,
  opcodeIndex = true,
  nativeOpcode = true,
}

-- Producer identities never reach runtime records at any depth.
local function checkNoNativeKeys(value, context, code, field)
  if type(value) ~= "table" then
    return
  end
  for key, nested in pairs(value) do
    local text = tostring(key)
    if NATIVE_KEYS[text] then
      fail(code, field .. " leaks source detail '" .. text .. "'", context)
    end
    checkNoNativeKeys(nested, context, code, field .. "." .. text)
  end
end

local RESOURCE_KINDS = {
  map = true,
  texture = true,
  model = true,
  palette = true,
  cell = true,
  animation = true,
  message = true,
  particle = true,
  ["particle-emitter"] = true,
  ["multi-cell"] = true,
  ["multi-cell-animation"] = true,
  ["transition-data"] = true,
}

local function checkCatalogTable(value, context, code, field)
  if type(value) ~= "table" then
    fail(code, field .. " must be a record", context)
  end
  if next(value) == nil then
    fail(code, field .. " must carry source-backed entries", context)
  end
end

local function checkCellBounds(geometry, context, code, record)
  if not Validate.isArray(geometry.bounds) or #geometry.bounds ~= geometry.cellCount then
    fail(code, record .. ".geometry.bounds must describe each decoded cell", context)
  end
  for index, bounds in ipairs(geometry.bounds) do
    local boundsPath = record .. ".geometry.bounds[" .. index .. "]"
    SchemaCheck.checkRecord(bounds, { x = true, y = true, width = true, height = true }, context, code, boundsPath)
    checkInt(bounds.x, -32768, 32767, context, code, boundsPath .. ".x")
    checkInt(bounds.y, -32768, 32767, context, code, boundsPath .. ".y")
    checkInt(bounds.width, 0, 65535, context, code, boundsPath .. ".width")
    checkInt(bounds.height, 0, 65535, context, code, boundsPath .. ".height")
  end
end

local function checkAnimationDurationUnit(geometry, context, code, record)
  if geometry.durationUnit ~= "native-frame" then
    fail(code, record .. ".geometry.durationUnit must preserve native frame timing", context)
  end
end

-- Decoded geometry per resource format: the exact geometry fields with
-- their integer bounds, the resource kind a format pins (with the noun its
-- mismatch names), and any non-integer geometry rule.
local PARTICLE_GEOMETRY = { fields = { { "emitterCount", 0 }, { "resourceCount", 0 } } }
local APS_PAYLOAD_GEOMETRY = { fields = { { "byteCount", 1 } } }
local TRAINER_INDEX_GEOMETRY =
  { kind = "message", kindNoun = "trainer message index", fields = { { "recordCount", 1 } } }
local RESOURCE_GEOMETRY_BY_FORMAT = {
  ["nitro-spl-texture-data-v1"] = {
    kind = "texture",
    kindNoun = "APS embedded payload",
    fields = APS_PAYLOAD_GEOMETRY.fields,
  },
  ["nitro-spl-palette-data-v1"] = {
    kind = "palette",
    kindNoun = "APS embedded payload",
    fields = APS_PAYLOAD_GEOMETRY.fields,
  },
  ["hgss-message-bank-tokens-v1"] = {
    kind = "message",
    kindNoun = "message bank",
    fields = { { "recordCount", 1 }, { "tokenCount", 0 } },
  },
  ["hgss-trainer-message-offsets-v1"] = TRAINER_INDEX_GEOMETRY,
  ["hgss-trainer-message-pairs-v1"] = TRAINER_INDEX_GEOMETRY,
  ["nitro-palette-rgb888-v1"] = { fields = { { "colorCount", 1 } } },
  ["nitro-char-4bpp-v1"] = { fields = { { "depth", 3, 3 }, { "tileCount", 1 } } },
  ["nitro-char-8bpp-v1"] = { fields = { { "depth", 4, 4 }, { "tileCount", 1 } } },
  ["nitro-obj-cells-v1"] = { fields = { { "cellCount", 1 } }, extra = "bounds", check = checkCellBounds },
  ["nitro-obj-animation-v1"] = {
    fields = { { "animationCount", 1 }, { "frameCount", 1 } },
    extra = "durationUnit",
    check = checkAnimationDurationUnit,
  },
  ["nitro-bg-map-v1"] = { fields = { { "width", 1 }, { "height", 1 }, { "entryCount", 1 } } },
}

local function geometryKeys(spec)
  local keys = {}
  for _, rule in ipairs(spec.fields) do
    keys[rule[1]] = true
  end
  if spec.extra ~= nil then
    keys[spec.extra] = true
  end
  spec.keys = keys
end
geometryKeys(PARTICLE_GEOMETRY)
for _, spec in pairs(RESOURCE_GEOMETRY_BY_FORMAT) do
  if spec.keys == nil then
    geometryKeys(spec)
  end
end

local function checkResourceGeometry(descriptor, spec, context, code, record)
  if spec.kind ~= nil and descriptor.kind ~= spec.kind then
    fail(code, record .. " " .. spec.kindNoun .. " has the wrong resource kind", context)
  end
  local geometry = descriptor.geometry
  SchemaCheck.checkRecord(geometry, spec.keys, context, code, record .. ".geometry")
  for _, rule in ipairs(spec.fields) do
    checkInt(geometry[rule[1]], rule[2], rule[3], context, code, record .. ".geometry." .. rule[1])
  end
  if spec.check ~= nil then
    spec.check(geometry, context, code, record)
  end
end

local function checkResourceDescriptor(descriptor, context, code, record)
  if type(descriptor) ~= "table" then
    fail(code, record .. " must be a record", context)
  end
  SchemaCheck.checkRecord(
    descriptor,
    { kind = true, contentIdentity = true, format = true, geometry = true, path = true },
    context,
    code,
    record
  )
  if type(descriptor.kind) ~= "string" or descriptor.kind == "" then
    fail(code, record .. " carries no kind", context)
  end
  if RESOURCE_KINDS[descriptor.kind] == nil then
    fail(code, record .. " carries an unknown kind: " .. tostring(descriptor.kind), context)
  end
  if not isSha1Text(descriptor.contentIdentity) then
    fail(code, record .. " carries no SHA-1 content identity", context)
  end
  checkString(descriptor.format, context, code, record .. ".format")
  checkString(descriptor.path, context, code, record .. ".path")
  if
    descriptor.path:find("..", 1, true)
    or descriptor.path:sub(1, 1) == "/"
    or descriptor.path:find("^data/generated/battle/resources/") == nil
  then
    fail(code, record .. ".path must be a cache-relative decoded resource path", context)
  end
  if type(descriptor.geometry) ~= "table" then
    fail(code, record .. " carries no decoded geometry", context)
  end
  if descriptor.kind == "particle" then
    if descriptor.format ~= "nitro-spl-aps-v1" then
      fail(code, record .. " particle format must be nitro-spl-aps-v1", context)
    end
    checkResourceGeometry(descriptor, PARTICLE_GEOMETRY, context, code, record)
  elseif descriptor.kind == "transition-data" then
    if descriptor.format ~= "hgss-wild-cell-grid-orders-v1" then
      fail(code, record .. " transition data has an unknown format", context)
    end
    local geometry = descriptor.geometry
    SchemaCheck.checkRecord(
      geometry,
      { gridWidth = true, gridHeight = true, orderCount = true },
      context,
      code,
      record .. ".geometry"
    )
    if geometry.gridWidth ~= 8 or geometry.gridHeight ~= 6 or geometry.orderCount ~= 24 then
      fail(code, record .. " wild cell order geometry must describe the 8 by 6 retail grid", context)
    end
  elseif RESOURCE_GEOMETRY_BY_FORMAT[descriptor.format] ~= nil then
    checkResourceGeometry(descriptor, RESOURCE_GEOMETRY_BY_FORMAT[descriptor.format], context, code, record)
  end
end

local function checkCatalogResources(resources, context, code, field)
  checkCatalogTable(resources, context, code, field)
  for key, descriptor in pairs(resources) do
    checkString(key, context, code, field .. " key")
    checkResourceDescriptor(descriptor, context, code, field .. "[" .. tostring(key) .. "]")
  end
end

local function checkPictureAttributes(attributes, context, code, field)
  checkCatalogTable(attributes, context, code, field)
  for key, record in pairs(attributes) do
    checkString(key, context, code, field .. " key")
    local species, _, gender, facing = key:match("^pokemon/([A-Z0-9_]+)/form%-(%d+)/([a-z]+)/([a-z]+)$")
    if species == nil or gender ~= "male" and gender ~= "female" or facing ~= "front" and facing ~= "back" then
      fail(code, field .. " carries a malformed semantic key: " .. key, context)
    end
    local recordPath = field .. "[" .. key .. "]"
    SchemaCheck.checkRecord(record, { height = true, animation = true, shadow = true }, context, code, recordPath)
    checkInt(record.height, 0, 255, context, code, recordPath .. ".height")
    -- Front pictures carry the species shadow geometry the opponent-side
    -- Pokepic applies; back pictures never draw a shadow.
    if facing == "front" then
      SchemaCheck.checkRecord(
        record.shadow,
        { height = true, xOffset = true, size = true },
        context,
        code,
        recordPath .. ".shadow"
      )
      checkInt(record.shadow.height, -128, 127, context, code, recordPath .. ".shadow.height")
      checkInt(record.shadow.xOffset, -128, 127, context, code, recordPath .. ".shadow.xOffset")
      checkInt(record.shadow.size, 0, 3, context, code, recordPath .. ".shadow.size")
    elseif record.shadow ~= nil then
      fail(code, recordPath .. ".shadow belongs to front pictures only", context)
    end
    SchemaCheck.checkRecord(record.animation, { steps = true }, context, code, recordPath .. ".animation")
    if not Validate.isArray(record.animation.steps) or #record.animation.steps ~= 10 then
      fail(code, recordPath .. ".animation.steps must contain ten ordered entries", context)
    end
    for index, step in ipairs(record.animation.steps) do
      local stepPath = recordPath .. ".animation.steps[" .. index .. "]"
      SchemaCheck.checkRecord(
        step,
        { next = true, duration = true, xOffset = true, auxiliary = true },
        context,
        code,
        stepPath
      )
      checkInt(step.next, -11, 1, context, code, stepPath .. ".next")
      checkInt(step.duration, 0, 255, context, code, stepPath .. ".duration")
      checkInt(step.xOffset, -128, 127, context, code, stepPath .. ".xOffset")
      checkInt(step.auxiliary, -128, 127, context, code, stepPath .. ".auxiliary")
    end
  end
end

local function checkSceneResource(resource, context, field)
  SchemaCheck.checkRecord(resource, { key = true, path = true, format = true }, context, CODE_SCENE, field)
  checkString(resource.key, context, CODE_SCENE, field .. ".key")
  checkString(resource.path, context, CODE_SCENE, field .. ".path")
  checkString(resource.format, context, CODE_SCENE, field .. ".format")
  if
    resource.path:find("..", 1, true)
    or resource.path:sub(1, 1) == "/"
    or resource.path:sub(1, 29) ~= "data/generated/battle/scenes/"
  then
    fail(CODE_SCENE, field .. ".path must be a cache-relative scene resource", context)
  end
  if resource.key:sub(1, 13) ~= "battle-scene/" then
    fail(CODE_SCENE, field .. ".key must be a semantic battle scene resource key", context)
  end
end

local function checkSceneLayer(layer, context, field)
  SchemaCheck.checkRecord(
    layer,
    { key = true, backing = true, viewport = true, scroll = true, characters = true, map = true, palette = true },
    context,
    CODE_SCENE,
    field
  )
  if layer.key ~= "background" then
    fail(CODE_SCENE, field .. " must identify the semantic battle background layer", context)
  end
  SchemaCheck.checkRecord(
    layer.backing,
    { width = true, height = true, mapWidth = true, mapHeight = true },
    context,
    CODE_SCENE,
    field .. ".backing"
  )
  if
    layer.backing.width ~= 512
    or layer.backing.height ~= 256
    or layer.backing.mapWidth ~= 64
    or layer.backing.mapHeight ~= 32
  then
    fail(CODE_SCENE, field .. ".backing must preserve the native 512x256, 64x32 BG map", context)
  end
  SchemaCheck.checkRecord(
    layer.viewport,
    { x = true, y = true, width = true, height = true },
    context,
    CODE_SCENE,
    field .. ".viewport"
  )
  checkInt(layer.viewport.x, 0, nil, context, CODE_SCENE, field .. ".viewport.x")
  checkInt(layer.viewport.y, 0, nil, context, CODE_SCENE, field .. ".viewport.y")
  checkInt(layer.viewport.width, 1, nil, context, CODE_SCENE, field .. ".viewport.width")
  checkInt(layer.viewport.height, 1, nil, context, CODE_SCENE, field .. ".viewport.height")
  if layer.viewport.x ~= 0 or layer.viewport.y ~= 0 or layer.viewport.width ~= 256 or layer.viewport.height ~= 192 then
    fail(CODE_SCENE, field .. ".viewport must preserve the native 256x192 origin view", context)
  end
  if
    layer.viewport.x + layer.viewport.width > layer.backing.width
    or layer.viewport.y + layer.viewport.height > layer.backing.height
  then
    fail(CODE_SCENE, field .. ".viewport escapes its native backing", context)
  end
  SchemaCheck.checkRecord(layer.scroll, { x = true, y = true }, context, CODE_SCENE, field .. ".scroll")
  checkInt(layer.scroll.x, 0, nil, context, CODE_SCENE, field .. ".scroll.x")
  checkInt(layer.scroll.y, 0, nil, context, CODE_SCENE, field .. ".scroll.y")
  if layer.scroll.x ~= 0 or layer.scroll.y ~= 0 then
    fail(CODE_SCENE, field .. ".scroll must preserve the source initial BG3 position", context)
  end
  checkSceneResource(layer.characters, context, field .. ".characters")
  checkSceneResource(layer.map, context, field .. ".map")
  checkSceneResource(layer.palette, context, field .. ".palette")
  if layer.characters.format ~= "indexed8" or layer.map.format ~= "tilemap" or layer.palette.format ~= "rgb888" then
    fail(CODE_SCENE, field .. " resources must use normalized indexed8, tilemap, and rgb888 formats", context)
  end
end

local function checkScenePngImage(image, width, height, context, field)
  checkImagePath(image, context, CODE_SCENE, field .. ".image")
  local prefix = "assets/generated/battle/scenes/"
  if image:sub(1, #prefix) ~= prefix or image:find("..", 1, true) ~= nil or image:sub(-4) ~= ".png" then
    fail(CODE_SCENE, field .. ".image must reference a staged battle scene PNG", context)
  end
  checkInt(width, 1, 512, context, CODE_SCENE, field .. ".width")
  checkInt(height, 1, 256, context, CODE_SCENE, field .. ".height")
end

local function checkIntroLayer(layer, context)
  SchemaCheck.checkRecord(layer, { image = true, width = true, height = true }, context, CODE_SCENE, "scene introLayer")
  checkScenePngImage(layer.image, layer.width, layer.height, context, "scene introLayer")
  if layer.width ~= 512 or layer.height ~= 256 then
    fail(CODE_SCENE, "scene introLayer must preserve the native unbaked 512x256 BG3 canvas", context)
  end
end

local function checkTerrainSprites(sprites, context)
  SchemaCheck.checkRecord(sprites, { player = true, foe = true }, context, CODE_SCENE, "scene terrainSprites")
  for _, side in ipairs({ "player", "foe" }) do
    local field = "scene terrainSprites." .. side
    local sprite = sprites[side]
    SchemaCheck.checkRecord(
      sprite,
      { image = true, width = true, height = true, origin = true },
      context,
      CODE_SCENE,
      field
    )
    checkScenePngImage(sprite.image, sprite.width, sprite.height, context, field)
    SchemaCheck.checkRecord(sprite.origin, { x = true, y = true }, context, CODE_SCENE, field .. ".origin")
    checkInt(sprite.origin.x, -256, 255, context, CODE_SCENE, field .. ".origin.x")
    checkInt(sprite.origin.y, -256, 255, context, CODE_SCENE, field .. ".origin.y")
  end
end

local SCRIPT_MESSAGE_INPUTS = { "messageRecordReference", "messageTagSymbol", "tagTypedParameters" }

-- Each program-context placeholder slot and the catalog/operand it binds.
local PLACEHOLDER_BINDINGS = {
  { "tagInput", "messageTagSymbol" },
  { "parametersInput", "tagTypedParameters" },
  { "schemaCatalog", "tagSchemas" },
  { "contextCatalog", "tagInputs" },
  { "placeholderCatalog", "placeholders" },
  { "bufferCatalog", "templateInputs" },
}

-- The normalized program-context fields a coverage link must copy exactly.
local PROGRAM_CONTEXT_LINK_FIELDS = {
  record = { "input", "bank", "selection" },
  placeholders = {
    "tagInput",
    "parametersInput",
    "schemaCatalog",
    "contextCatalog",
    "placeholderCatalog",
    "bufferCatalog",
    "expansionRoute",
  },
}

local function checkProgramContextRecord(record, route, context, code, field)
  SchemaCheck.checkRecord(record, { input = true, bank = true, selection = true }, context, code, field .. ".record")
  if
    record.input ~= "messageRecordReference"
    or record.selection ~= "link-time-record-reference"
    or record.bank == nil
  then
    fail(code, field .. ".record must bind a link-time record reference to its semantic bank", context)
  end
  if not contains(route.inputs, record.input) or not contains(route.banks, record.bank) then
    fail(code, field .. ".record must use the route's declared input and staged bank", context)
  end
end

local function checkProgramContextPlaceholders(placeholders, route, messages, context, code, field)
  SchemaCheck.checkRecord(placeholders, {
    tagInput = true,
    parametersInput = true,
    schemaCatalog = true,
    contextCatalog = true,
    placeholderCatalog = true,
    bufferCatalog = true,
    expansionRoute = true,
  }, context, code, field .. ".placeholders")
  for _, binding in ipairs(PLACEHOLDER_BINDINGS) do
    if placeholders[binding[1]] ~= binding[2] then
      fail(
        code,
        field .. ".placeholders must bind the source tag and parameter operands to their typed catalogs",
        context
      )
    end
  end
  if not contains(route.inputs, placeholders.tagInput) or not contains(route.inputs, placeholders.parametersInput) then
    fail(code, field .. ".placeholders must use the route's declared tag and parameter inputs", context)
  end
  local expansionRoute = messages.sourceRoutes[placeholders.expansionRoute]
  if expansionRoute == nil or expansionRoute.bufferPlan ~= "tagSelectedBuffers" then
    fail(code, field .. ".placeholders must link to the staged battle-message template route", context)
  end
  local tagSchemas, tagInputs = messages.tagSchemas, messages.tagInputs
  local placeholdersCatalog, templateInputs = messages.placeholders, messages.templateInputs
  if
    next(tagSchemas) == nil
    or next(tagInputs) == nil
    or next(placeholdersCatalog) == nil
    or next(templateInputs) == nil
  then
    fail(code, field .. ".placeholders must link nonempty tag, context, placeholder, and template catalogs", context)
  end
  for tag, slots in pairs(tagSchemas) do
    for _, slot in ipairs(slots) do
      if tagInputs[slot] == nil then
        fail(code, field .. ".placeholders has no source context resolver for " .. slot .. " in tag " .. tag, context)
      end
      if placeholdersCatalog[slot] == nil and templateInputs[slot] == nil then
        fail(code, field .. ".placeholders has no staged buffer contract for " .. slot .. " in tag " .. tag, context)
      end
    end
  end
end

-- `messages` supplies the source routes and typed tag/placeholder catalogs
-- the program context links to.
local function checkBattleMessageProgramContext(programContext, route, messages, context, code, field)
  if
    #route.inputs ~= 3
    or route.inputs[1] ~= SCRIPT_MESSAGE_INPUTS[1]
    or route.inputs[2] ~= SCRIPT_MESSAGE_INPUTS[2]
    or route.inputs[3] ~= SCRIPT_MESSAGE_INPUTS[3]
    or route.recordSelection ~= "literal-at-script-callsite"
    or route.placeholderPlan ~= "battleMessageTags"
  then
    fail(code, field .. " requires the source PrintMessage record, tag, and ordered parameter operands", context)
  end
  SchemaCheck.checkRecord(
    programContext,
    { program = true, context = true, delivery = true, record = true, placeholders = true },
    context,
    code,
    field
  )
  if
    programContext.program ~= "battle-script"
    or programContext.context ~= "battle-message"
    or (programContext.delivery ~= "message-scope-local" and programContext.delivery ~= "message-scope-global")
  then
    fail(code, field .. " must identify the source battle-script message context", context)
  end
  checkProgramContextRecord(programContext.record, route, context, code, field)
  checkProgramContextPlaceholders(programContext.placeholders, route, messages, context, code, field)
end

local MENU_COVERAGE_LISTS = { "messageEntries", "messageRoutes", "fontRoles", "assetRoles", "requiredContext" }
local MENU_COVERAGE_REQUIREMENT_LISTS = { "messageRoutes", "fontRoles", "assetRoles", "requiredContext" }

local function checkMenuCoverageBindings(entry, menuRoute, context, code, record)
  SchemaCheck.checkRecord(entry.assetBindings, nil, context, code, record .. ".assetBindings")
  local mismatch = record .. ".assetBindings must exactly match its menu route closure"
  for role, binding in pairs(menuRoute.assetBindings) do
    local coverageBinding = entry.assetBindings[role]
    if
      coverageBinding == nil
      or coverageBinding.catalog ~= binding.catalog
      or coverageBinding.selector ~= binding.selector
      or coverageBinding.when ~= binding.when
      or not Validate.isArray(coverageBinding.context)
      or #coverageBinding.context ~= #binding.context
    then
      fail(code, mismatch, context)
      return
    end
    for index, contextField in ipairs(binding.context) do
      if coverageBinding.context[index] ~= contextField then
        fail(code, mismatch, context)
      end
    end
  end
  if countKeys(entry.assetBindings) ~= countKeys(menuRoute.assetBindings) then
    fail(code, mismatch, context)
  end
end

local function checkMenuCoverageReferences(entry, menus, messages, context, code, record)
  for _, messageKey in ipairs(entry.messageEntries) do
    if messages.entries[messageKey] == nil then
      fail(code, record .. ".messageEntries contains an unstaged message", context)
    end
  end
  for _, messageRoute in ipairs(entry.messageRoutes) do
    if
      messages.routes[messageRoute] == nil
      and messages.sourceRoutes[messageRoute] == nil
      and messages.dynamicRoutes[messageRoute] == nil
    then
      fail(code, record .. ".messageRoutes contains an unknown route", context)
    end
  end
  for _, role in ipairs(entry.fontRoles) do
    if messages.roles[role] == nil then
      fail(code, record .. ".fontRoles contains an unknown font role", context)
    end
  end
  for _, contextKey in ipairs(entry.requiredContext) do
    if menus.contexts[contextKey] == nil then
      fail(code, record .. ".requiredContext contains an unknown menu context", context)
    end
  end
end

-- A menu-route coverage entry closes exactly its route's resources and
-- asset bindings and includes at least its route's direct requirements.
local function checkMenuRouteCoverage(entry, menus, messages, context, code, record)
  checkString(entry.route, context, code, record .. ".route")
  local menuRoute = menus.routes[entry.route]
  if menus.selectors[entry.route] == nil or menuRoute == nil then
    fail(code, record .. " references an unknown menu route", context)
    return
  end
  for _, fieldName in ipairs(MENU_COVERAGE_LISTS) do
    if not Validate.isArray(entry[fieldName]) then
      fail(code, record .. "." .. fieldName .. " must declare its source dependencies", context)
    end
  end
  checkMenuCoverageBindings(entry, menuRoute, context, code, record)
  local expectedResources = valueSet(menuRoute.resources)
  if #menuRoute.resources ~= #entry.resources then
    fail(code, record .. ".resources must exactly match its menu route closure", context)
  end
  for _, resourceKey in ipairs(entry.resources) do
    if expectedResources[resourceKey] ~= true then
      fail(code, record .. ".resources must exactly match its menu route closure", context)
    end
  end
  checkMenuCoverageReferences(entry, menus, messages, context, code, record)
  local coverageMessageEntries = valueSet(entry.messageEntries)
  for _, messageKey in ipairs(menuRoute.messageEntries) do
    if coverageMessageEntries[messageKey] ~= true then
      fail(code, record .. ".messageEntries must include its direct menu text", context)
    end
  end
  for _, fieldName in ipairs(MENU_COVERAGE_REQUIREMENT_LISTS) do
    if #entry[fieldName] < #menuRoute[fieldName] then
      fail(code, record .. "." .. fieldName .. " must include its menu route requirements", context)
    end
    local coverageValues = valueSet(entry[fieldName])
    for _, value in ipairs(menuRoute[fieldName]) do
      if coverageValues[value] ~= true then
        fail(code, record .. "." .. fieldName .. " must include its menu route requirements", context)
      end
    end
  end
end

-- A coverage entry for a source route with a battle-script program context
-- links that context verbatim and closes its record and expansion banks.
local function checkLinkedProgramContext(entry, sourceRoute, messages, context, code, record)
  local linked = entry.programContext
  if linked == nil then
    fail(code, record .. ".programContext must preserve its source message binding", context)
    return
  end
  checkBattleMessageProgramContext(linked, sourceRoute, messages, context, code, record .. ".programContext")
  if not Validate.isArray(entry.messageRoutes) then
    fail(code, record .. ".messageRoutes must include placeholder expansion dependencies", context)
  end
  local expansionRouteKey = linked.placeholders.expansionRoute
  if not contains(entry.messageRoutes, expansionRouteKey) then
    fail(code, record .. ".messageRoutes must include its linked placeholder expansion route", context)
  end
  for _, resourceKey in ipairs(sourceRoute.banks) do
    if not contains(entry.resources, resourceKey) then
      fail(code, record .. ".resources omits its message record bank", context)
    end
  end
  for _, resourceKey in ipairs(messages.sourceRoutes[expansionRouteKey].banks) do
    if not contains(entry.resources, resourceKey) then
      fail(code, record .. ".resources omits a placeholder expansion bank", context)
    end
  end
  local sourceContext = sourceRoute.programContext
  local matches = linked.program == sourceContext.program and linked.context == sourceContext.context
  for part, fieldNames in pairs(PROGRAM_CONTEXT_LINK_FIELDS) do
    for _, fieldName in ipairs(fieldNames) do
      matches = matches and linked[part][fieldName] == sourceContext[part][fieldName]
    end
  end
  if not matches then
    fail(code, record .. ".programContext must exactly match its normalized source route", context)
  end
end

local function checkMessageRouteCoverage(entry, messages, context, code, record)
  checkString(entry.route, context, code, record .. ".route")
  if messages.sourceRoutes[entry.route] == nil and messages.routes[entry.route] == nil then
    fail(code, record .. " references an unknown message route or mixes program coverage", context)
  end
  local sourceRoute = messages.sourceRoutes[entry.route]
  if sourceRoute ~= nil and sourceRoute.programContext ~= nil then
    checkLinkedProgramContext(entry, sourceRoute, messages, context, code, record)
  elseif entry.programContext ~= nil then
    fail(code, record .. ".programContext is only admitted when a source route declares it", context)
  end
end

local function checkTransitionRouteCoverage(entry, route, seenResources, context, code, record)
  if #entry.operations ~= 1 or entry.operations[1] ~= route.role then
    fail(code, record .. " must identify its source callback operation", context)
  end
  local routeResources = valueSet(route.resources)
  if countKeys(routeResources) ~= #entry.resources then
    fail(code, record .. ".resources must exactly match its transition route closure", context)
  end
  for resourceKey in pairs(seenResources) do
    if routeResources[resourceKey] == nil then
      fail(code, record .. ".resources must exactly match its transition route closure", context)
    end
  end
end

local COVERAGE_ENTRY_FIELDS = {
  kind = true,
  route = true,
  closureIdentity = true,
  resources = true,
  operations = true,
  messageEntries = true,
  messageRoutes = true,
  fontRoles = true,
  assetRoles = true,
  assetBindings = true,
  requiredContext = true,
  programContext = true,
}

local function checkCoverageEntry(entry, manifest, context, code, record)
  SchemaCheck.checkRecord(entry, COVERAGE_ENTRY_FIELDS, context, code, record)
  local transitions = manifest.transitions
  if entry.kind == "transition-route" then
    checkString(entry.route, context, code, record .. ".route")
    if transitions.routes[entry.route] == nil then
      fail(code, record .. " references an unknown transition route", context)
    end
  elseif entry.kind == "menu-route" then
    checkMenuRouteCoverage(entry, manifest.menus, manifest.messages, context, code, record)
  elseif entry.kind == "message-route" then
    checkMessageRouteCoverage(entry, manifest.messages, context, code, record)
  else
    fail(code, record .. ".kind must identify a source route or animation program", context)
  end
  if not isSha1Text(entry.closureIdentity) then
    fail(code, record .. ".closureIdentity must be a SHA-1 identity", context)
  end
  if not Validate.isArray(entry.resources) then
    fail(code, record .. ".resources must enumerate its decoded resource closure", context)
  end
  local seenResources = {}
  for index, resourceKey in ipairs(entry.resources) do
    checkString(resourceKey, context, code, record .. ".resources[" .. index .. "]")
    if manifest.resources[resourceKey] == nil or seenResources[resourceKey] then
      fail(code, record .. ".resources contains an unstaged or repeated key", context)
    end
    seenResources[resourceKey] = true
  end
  if entry.kind == "transition-route" then
    checkTransitionRouteCoverage(entry, transitions.routes[entry.route], seenResources, context, code, record)
  end
  if not Validate.isArray(entry.operations) or #entry.operations == 0 then
    fail(code, record .. " must carry its operations", context)
  end
  for index, operation in ipairs(entry.operations) do
    checkString(operation, context, code, record .. ".operations[" .. index .. "]")
  end
end

-- Every admitted route owns a coverage closure under its expected key.
local function checkCoverageAdmission(coverage, manifest, context, code, field)
  for routeKey in pairs(manifest.transitions.routes) do
    local entry = coverage["transition/" .. routeKey]
    if entry == nil or entry.kind ~= "transition-route" or entry.route ~= routeKey then
      fail(code, field .. " omits transition route admission closure " .. routeKey, context)
    end
  end
  for routeKey in pairs(manifest.menus.selectors) do
    local entry = coverage[routeKey]
    if entry == nil or entry.kind ~= "menu-route" or entry.route ~= routeKey then
      fail(code, field .. " omits menu route admission closure " .. routeKey, context)
    end
  end
  for routeKey in pairs(manifest.messages.sourceRoutes) do
    local entry = coverage[routeKey]
    if entry == nil or entry.kind ~= "message-route" or entry.route ~= routeKey then
      fail(code, field .. " omits message route admission closure " .. routeKey, context)
    end
  end
end

local function checkCoverage(manifest, context, code, field)
  local coverage = manifest.coverage
  checkCatalogTable(coverage, context, code, field)
  for key, entry in pairs(coverage) do
    checkString(key, context, code, field .. " key")
    checkCoverageEntry(entry, manifest, context, code, field .. "[" .. tostring(key) .. "]")
  end
  checkCoverageAdmission(coverage, manifest, context, code, field)
end

-- A scene's semantic axes and the key they compose.
local function checkSceneAxes(entry, context, code, field)
  if BACKGROUNDS[entry.background] == nil then
    fail(code, field .. " carries an unknown background: " .. tostring(entry.background), context)
  end
  if TERRAINS[entry.terrain] == nil then
    fail(code, field .. " carries an unknown terrain: " .. tostring(entry.terrain), context)
  end
  if TIMES[entry.time] == nil then
    fail(code, field .. " carries an unknown time: " .. tostring(entry.time), context)
  end
  if entry.key ~= entry.background .. "/" .. entry.terrain .. "/" .. entry.time then
    fail(code, field .. " key disagrees with its axes: " .. tostring(entry.key), context)
  end
end

local function checkSceneEntry(entry, context, code, field)
  SchemaCheck.checkRecord(entry, { key = true, background = true, terrain = true, time = true }, context, code, field)
  checkString(entry.key, context, code, field .. ".key")
  checkSceneAxes(entry, context, code, field)
end

-- A rectangle that must sit inside its screen.
local function checkScreenRect(rect, screen, context, code, field)
  checkInt(rect.x, 0, screen.width - 1, context, code, field .. ".x")
  checkInt(rect.y, 0, screen.height - 1, context, code, field .. ".y")
  checkInt(rect.width, 1, screen.width - rect.x, context, code, field .. ".width")
  checkInt(rect.height, 1, screen.height - rect.y, context, code, field .. ".height")
end

-- Screens drawing the background-dependent lower palette carry one staged
-- image per battle background that changes their pixels.
local function checkBackgroundImages(images, context, code, field)
  if images == nil then
    return
  end
  SchemaCheck.checkRecord(images, nil, context, code, field)
  for background, image in pairs(images) do
    checkString(background, context, code, field .. " key")
    checkImagePath(image, context, code, field .. "[" .. tostring(background) .. "]")
  end
end

-- The fight menu's move buttons by slot: per-type normal and pressed
-- renders plus the blank button an empty slot shows.
local function checkMoveButtons(screen, context, code, entry)
  if not Validate.isArray(screen.moveButtons) or #screen.moveButtons ~= 4 then
    fail(code, entry .. ".moveButtons must carry the four move slots", context)
  end
  for slot, button in ipairs(screen.moveButtons) do
    local buttonField = entry .. ".moveButtons[" .. slot .. "]"
    SchemaCheck.checkRecord(
      button,
      { x = true, y = true, width = true, height = true, types = true, empty = true },
      context,
      code,
      buttonField
    )
    checkScreenRect(button, screen, context, code, buttonField)
    checkImagePath(button.empty, context, code, buttonField .. ".empty")
    SchemaCheck.checkRecord(button.types, nil, context, code, buttonField .. ".types")
    if next(button.types) == nil then
      fail(code, buttonField .. ".types must carry the move type renders", context)
    end
    for typeKey, states in pairs(button.types) do
      local typeField = buttonField .. ".types[" .. tostring(typeKey) .. "]"
      checkString(typeKey, context, code, typeField .. " key")
      SchemaCheck.checkRecord(states, { normal = true, pressed = true }, context, code, typeField)
      checkImagePath(states.normal, context, code, typeField .. ".normal")
      checkImagePath(states.pressed, context, code, typeField .. ".pressed")
    end
  end
end

local function checkScreenFeedback(screen, context, code, entry)
  SchemaCheck.checkRecord(screen.feedback, nil, context, code, entry .. ".feedback")
  for controlId, states in pairs(screen.feedback) do
    local controlField = entry .. ".feedback[" .. tostring(controlId) .. "]"
    checkString(controlId, context, code, controlField .. " control id")
    SchemaCheck.checkRecord(states, { selected = true, pressed = true }, context, code, controlField)
    if next(states) == nil then
      fail(code, controlField .. " must carry a selected or pressed patch", context)
    end
    for state, patch in pairs(states) do
      local patchField = controlField .. "." .. tostring(state)
      SchemaCheck.checkRecord(
        patch,
        { image = true, x = true, y = true, width = true, height = true },
        context,
        code,
        patchField
      )
      checkImagePath(patch.image, context, code, patchField .. ".image")
      checkScreenRect(patch, screen, context, code, patchField)
    end
  end
end

local MENU_SCREEN_FIELDS = {
  image = true,
  width = true,
  height = true,
  tilemapKey = true,
  plane = true,
  template = true,
  priority = true,
  feedback = true,
  backgrounds = true,
  touchBackgrounds = true,
  moveButtons = true,
  pulse = true,
}

local function checkMenuScreen(screen, planes, context, code, field, entry)
  SchemaCheck.checkRecord(screen, MENU_SCREEN_FIELDS, context, code, entry)
  checkImagePath(screen.image, context, code, entry .. ".image")
  if screen.pulse ~= nil and type(screen.pulse) ~= "boolean" then
    fail(code, entry .. ".pulse must be a boolean", context)
  end
  checkBackgroundImages(screen.backgrounds, context, code, entry .. ".backgrounds")
  checkBackgroundImages(screen.touchBackgrounds, context, code, entry .. ".touchBackgrounds")
  checkInt(screen.width, 8, nil, context, code, entry .. ".width")
  checkInt(screen.height, 8, nil, context, code, entry .. ".height")
  checkString(screen.tilemapKey, context, code, entry .. ".tilemapKey")
  checkInt(screen.plane, 0, 3, context, code, entry .. ".plane")
  if planes[screen.plane] then
    fail(code, field .. " assigns more than one screen to the same physical BG plane", context)
  end
  planes[screen.plane] = true
  -- Template and priority ride along only where the source pins them
  -- (the command composition); other menus carry their screens alone.
  if screen.template ~= nil and screen.template ~= "unused" then
    checkInt(screen.template, 0, nil, context, code, entry .. ".template")
  end
  if screen.priority ~= nil then
    checkInt(screen.priority, 0, nil, context, code, entry .. ".priority")
  end
  if screen.moveButtons ~= nil then
    checkMoveButtons(screen, context, code, entry)
  end
  if screen.feedback ~= nil then
    checkScreenFeedback(screen, context, code, entry)
  end
end

local function checkMenuSection(section, context, code, field)
  SchemaCheck.checkRecord(section, { image = true, screens = true }, context, code, field)
  checkImagePath(section.image, context, code, field .. ".image")
  if not Validate.isArray(section.screens) or #section.screens == 0 then
    fail(code, field .. " must carry its composed screens", context)
  end
  local planes = {}
  for index, screen in ipairs(section.screens) do
    checkMenuScreen(screen, planes, context, code, field, field .. ".screens[" .. index .. "]")
  end
end

local OBJ_FIELDS = {
  x = true,
  y = true,
  tile = true,
  flipH = true,
  flipV = true,
  palette = true,
  shape = true,
  size = true,
  width = true,
  height = true,
  affine = true,
  disabled = true,
  objMode = true,
  mosaic = true,
  colorMode = true,
  priority = true,
}

local function checkObj(obj, context, code, field)
  SchemaCheck.checkRecord(obj, OBJ_FIELDS, context, code, field)
  -- Cell offsets are signed OAM origins; dimensions and indices are not.
  checkInt(obj.x, -512, 512, context, code, field .. ".x")
  checkInt(obj.y, -512, 512, context, code, field .. ".y")
  checkInt(obj.tile, 0, nil, context, code, field .. ".tile")
  if type(obj.flipH) ~= "boolean" or type(obj.flipV) ~= "boolean" then
    fail(code, field .. " flips must be booleans", context)
  end
  checkInt(obj.palette, 0, nil, context, code, field .. ".palette")
  checkInt(obj.shape, 0, 2, context, code, field .. ".shape")
  checkInt(obj.size, 0, 3, context, code, field .. ".size")
  checkInt(obj.width, 1, nil, context, code, field .. ".width")
  checkInt(obj.height, 1, nil, context, code, field .. ".height")
  if type(obj.affine) ~= "boolean" or type(obj.disabled) ~= "boolean" or type(obj.mosaic) ~= "boolean" then
    fail(code, field .. " flags must be booleans", context)
  end
  checkString(obj.objMode, context, code, field .. ".objMode")
  checkString(obj.colorMode, context, code, field .. ".colorMode")
  checkInt(obj.priority, 0, 3, context, code, field .. ".priority")
end

local function checkPalette(palette, context, code, field)
  SchemaCheck.checkRecord(palette, { colors = true }, context, code, field)
  if not Validate.isArray(palette.colors) or #palette.colors == 0 then
    fail(code, field .. " must carry its colors", context)
  end
  for index, color in ipairs(palette.colors) do
    local entry = field .. ".colors[" .. index .. "]"
    SchemaCheck.checkRecord(color, { r = true, g = true, b = true }, context, code, entry)
    checkInt(color.r, 0, 255, context, code, entry .. ".r")
    checkInt(color.g, 0, 255, context, code, entry .. ".g")
    checkInt(color.b, 0, 255, context, code, entry .. ".b")
  end
end

local function checkAnimation(animation, context, code, field)
  SchemaCheck.checkRecord(animation, { playMode = true, loopStartFrameIdx = true, frames = true }, context, code, field)
  checkString(animation.playMode, context, code, field .. ".playMode")
  checkInt(animation.loopStartFrameIdx, 0, nil, context, code, field .. ".loopStartFrameIdx")
  if not Validate.isArray(animation.frames) or #animation.frames == 0 then
    fail(code, field .. " must carry its frames", context)
  end
  for index, frame in ipairs(animation.frames) do
    local entry = field .. ".frames[" .. index .. "]"
    SchemaCheck.checkRecord(frame, { cell = true, duration = true, x = true, y = true }, context, code, entry)
    checkInt(frame.cell, 0, nil, context, code, entry .. ".cell")
    -- A legal zero duration holds its opening cell; durations are never
    -- negative or fractional.
    checkInt(frame.duration, 0, nil, context, code, entry .. ".duration")
    checkInt(frame.x, -32768, 32767, context, code, entry .. ".x")
    checkInt(frame.y, -32768, 32767, context, code, entry .. ".y")
  end
end

local function checkCells(cells, context, code, field)
  if not Validate.isArray(cells) or #cells == 0 then
    fail(code, field .. " must carry its cells", context)
  end
  for index, cell in ipairs(cells) do
    local entry = field .. ".cells[" .. index .. "]"
    SchemaCheck.checkRecord(cell, { objs = true }, context, code, entry)
    if not Validate.isArray(cell.objs) then
      fail(code, entry .. " must carry its objects in order", context)
    end
    for objIndex, obj in ipairs(cell.objs) do
      checkObj(obj, context, code, entry .. ".objs[" .. objIndex .. "]")
    end
  end
end

local function checkSpriteSection(section, context, code, field)
  SchemaCheck.checkRecord(section, {
    image = true,
    cells = true,
    animation = true,
    animations = true,
    palette = true,
    componentBase = true,
    componentCount = true,
    digitBase = true,
  }, context, code, field)
  checkImagePath(section.image, context, code, field .. ".image")
  checkCells(section.cells, context, code, field)
  checkAnimation(section.animation, context, code, field .. ".animation")
  if section.componentBase ~= nil then
    checkInt(section.componentBase, 0, 1023, context, code, field .. ".componentBase")
  end
  if section.componentCount ~= nil then
    checkInt(section.componentCount, 1, 256, context, code, field .. ".componentCount")
  end
  -- Health-box strips append the number printer's ten digits and its fill
  -- tile right after the native components.
  if (section.componentBase ~= nil) ~= (section.digitBase ~= nil) then
    fail(code, field .. " publishes printer digits exactly with its native components", context)
  end
  if section.digitBase ~= nil then
    checkInt(section.digitBase, 0, 1023, context, code, field .. ".digitBase")
  end
  -- Gauge families keep every per-state animation alongside the selected
  -- one; single-animation sprites omit the extension.
  if section.animations ~= nil then
    if not Validate.isArray(section.animations) or #section.animations == 0 then
      fail(code, field .. " animations must carry its sequences", context)
    end
    for index, animation in ipairs(section.animations) do
      checkAnimation(animation, context, code, field .. ".animations[" .. index .. "]")
    end
  end
  checkPalette(section.palette, context, code, field .. ".palette")
end

---@param section { cells: table<integer, table<string, unknown>>, animation: table<string, unknown> } shared per-type terrain bake metadata
---@param context table<string, unknown> error context
---@param code string error code
---@param field string field path for diagnostics
local function checkTerrainSection(section, context, code, field)
  SchemaCheck.checkRecord(section, { cells = true, animation = true }, context, code, field)
  checkCells(section.cells, context, code, field)
  checkAnimation(section.animation, context, code, field .. ".animation")
end

-- One character-tile write range: a tile index plus a bounded count that
-- must stay inside the 1024-tile character space.
local function checkTileSpan(span, countLower, countUpper, context, code, field)
  SchemaCheck.checkRecord(span, { tile = true, count = true }, context, code, field)
  checkInt(span.tile, 0, 1023, context, code, field .. ".tile")
  checkInt(span.count, countLower, countUpper, context, code, field .. ".count")
  if span.tile + span.count > 1024 then
    fail(code, field .. " exceeds the character tile index range", context)
  end
end

-- Claims `record.sideType` in `seen`; `owner` names the per-side list.
local function claimSideType(record, seen, context, code, owner, entry)
  checkInt(record.sideType, 0, 5, context, code, entry .. ".sideType")
  if seen[record.sideType] then
    fail(code, owner .. " side types must be unique", context)
  end
  seen[record.sideType] = true
end

-- Disjoint health/experience spans; returns how many tiles they cover.
local function checkDisjointSpans(spans, overlapMessage, context, code, field)
  local count = 0
  local occupied = {}
  for spanIndex, span in ipairs(spans) do
    local spanField = field .. "[" .. spanIndex .. "]"
    checkTileSpan(span, 0, 12, context, code, spanField)
    for tile = span.tile, span.tile + span.count - 1 do
      if occupied[tile] then
        fail(code, overlapMessage, context)
      end
      occupied[tile] = true
    end
    count = count + span.count
  end
  return count
end

local function checkHpPatchSpans(records, context, code, field)
  if not Validate.isArray(records) or #records ~= 6 then
    fail(code, field .. " must carry all six side types", context)
  end
  local sideTypes = {}
  for index, record in ipairs(records) do
    local entry = field .. "[" .. index .. "]"
    SchemaCheck.checkRecord(record, { sideType = true, spans = true }, context, code, entry)
    claimSideType(record, sideTypes, context, code, field, entry)
    if not Validate.isArray(record.spans) or #record.spans ~= 2 then
      fail(code, entry .. ".spans must carry both source patch ranges", context)
    end
    if checkDisjointSpans(record.spans, entry .. " patch spans overlap", context, code, entry .. ".spans") ~= 6 then
      fail(code, entry .. " spans must cover six health tiles", context)
    end
  end
  for sideType = 0, 5 do
    if not sideTypes[sideType] then
      fail(code, field .. " must cover every side type", context)
    end
  end
end

local function checkExperiencePatchSpans(spans, context, code, field)
  if not Validate.isArray(spans) or #spans ~= 2 then
    fail(code, field .. " must carry its two source patch ranges", context)
  end
  if checkDisjointSpans(spans, field .. " patch spans overlap", context, code, field) ~= 12 then
    fail(code, field .. " spans must cover twelve experience tiles", context)
  end
end

-- Fixed-width per-side writes: each category's native span counts.
local HUD_FIXED_SPAN_COUNTS = {
  currentHp = { 3 },
  maximumHp = { 3 },
  status = { 3 },
  gender = { 2, 2 },
  level = { 3, 3 },
  caught = { 1 },
}

local function checkFixedPatchSpans(records, spanCounts, context, code, field)
  if not Validate.isArray(records) or #records ~= 6 then
    fail(code, field .. " must cover all six native side types", context)
  end
  local covered = {}
  for index, record in ipairs(records) do
    local entry = field .. "[" .. index .. "]"
    SchemaCheck.checkRecord(record, { sideType = true, tile = true, count = true, spans = true }, context, code, entry)
    claimSideType(record, covered, context, code, field, entry)
    local spans = record.spans or { { tile = record.tile, count = record.count } }
    if not Validate.isArray(spans) or #spans ~= #spanCounts then
      fail(code, entry .. ".spans must match the native character writes", context)
    end
    for spanIndex, span in ipairs(spans) do
      local expected = spanCounts[spanIndex]
      checkTileSpan(span, expected, expected, context, code, entry .. ".spans[" .. spanIndex .. "]")
    end
  end
  for sideType = 0, 5 do
    if not covered[sideType] then
      fail(code, field .. " must cover all six native side types", context)
    end
  end
end

-- Nickname windows are eight tiles wide on two rows: each row's leading
-- span and its remainder together cover the window.
local function checkNicknamePatchSpans(records, context, code, field)
  if not Validate.isArray(records) or #records ~= 6 then
    fail(code, field .. " must cover all six native side types", context)
  end
  local sides = {}
  for index, record in ipairs(records) do
    local entry = field .. "[" .. index .. "]"
    SchemaCheck.checkRecord(record, { sideType = true, spans = true }, context, code, entry)
    claimSideType(record, sides, context, code, field, entry)
    local spans = record.spans
    if not Validate.isArray(spans) or #spans ~= 4 then
      fail(code, entry .. ".spans must carry both rows' leading and trailing tiles", context)
    end
    for spanIndex, span in ipairs(spans) do
      local spanField = entry .. ".spans[" .. spanIndex .. "]"
      SchemaCheck.checkRecord(span, { tile = true, count = true }, context, code, spanField)
      checkInt(span.tile, 0, 1023, context, code, spanField .. ".tile")
      checkInt(span.count, 1, 8, context, code, spanField .. ".count")
    end
    if spans[1].count ~= spans[2].count or spans[3].count ~= spans[4].count or spans[1].count + spans[3].count ~= 8 then
      fail(code, entry .. ".spans must cover the eight-tile window rows", context)
    end
  end
end

local DOUBLE_MODE_PATCH_COUNTS = { gauge = 4, numbers = 3 }

local function checkPlayerDoubleModePatchSpans(records, context, code, field)
  if not Validate.isArray(records) or #records ~= 2 then
    fail(code, field .. " must cover both double-player rows", context)
  end
  local doubleSides = {}
  for index, record in ipairs(records) do
    local entry = field .. "[" .. index .. "]"
    SchemaCheck.checkRecord(record, { sideType = true, gauge = true, numbers = true }, context, code, entry)
    if record.sideType ~= 2 and record.sideType ~= 4 then
      fail(code, entry .. ".sideType must name a double-player row", context)
    end
    if doubleSides[record.sideType] then
      fail(code, field .. " side types must be unique", context)
    end
    doubleSides[record.sideType] = true
    for modeName, expectedCount in pairs(DOUBLE_MODE_PATCH_COUNTS) do
      local patches = record[modeName]
      local modeField = entry .. "." .. modeName
      if not Validate.isArray(patches) or #patches ~= expectedCount then
        fail(code, modeField .. " must carry every native mode tile", context)
      end
      local destinations = {}
      for patchIndex, patch in ipairs(patches) do
        local patchField = modeField .. "[" .. patchIndex .. "]"
        SchemaCheck.checkRecord(patch, { tile = true, sourceTile = true }, context, code, patchField)
        checkInt(patch.tile, 0, 1023, context, code, patchField .. ".tile")
        checkInt(patch.sourceTile, 0, 77, context, code, patchField .. ".sourceTile")
        if destinations[patch.tile] then
          fail(code, modeField .. " destination tiles must be unique", context)
        end
        destinations[patch.tile] = true
      end
    end
  end
  if not doubleSides[2] or not doubleSides[4] then
    fail(code, field .. " must cover side types 2 and 4", context)
  end
end

local function checkHudPatchSpans(patchSpans, context, code, field)
  SchemaCheck.checkRecord(patchSpans, {
    hp = true,
    currentHp = true,
    maximumHp = true,
    experience = true,
    status = true,
    gender = true,
    nickname = true,
    level = true,
    caught = true,
    playerDoubleMode = true,
  }, context, code, field)
  checkHpPatchSpans(patchSpans.hp, context, code, field .. ".hp")
  checkExperiencePatchSpans(patchSpans.experience, context, code, field .. ".experience")
  for category, spanCounts in pairs(HUD_FIXED_SPAN_COUNTS) do
    checkFixedPatchSpans(patchSpans[category], spanCounts, context, code, field .. "." .. category)
  end
  checkNicknamePatchSpans(patchSpans.nickname, context, code, field .. ".nickname")
  checkPlayerDoubleModePatchSpans(patchSpans.playerDoubleMode, context, code, field .. ".playerDoubleMode")
end

local function checkTextRoles(roles, context, code, field)
  SchemaCheck.checkRecord(roles, {
    narration = true,
    trainerNarration = true,
    menu = true,
    hud = true,
    bugContest = true,
    recorderFeedback = true,
  }, context, code, field)
  if roles.narration == nil then
    fail(code, field .. " must identify the narration font", context)
  end
  for role, record in pairs(roles) do
    local entry = field .. "." .. role
    SchemaCheck.checkRecord(record, { font = true, palette = true }, context, code, entry)
    checkString(record.font, context, code, entry .. ".font")
    -- Printer palettes are whole sixteen-color source banks; roles drawn
    -- by consumers outside the ordinary battle screen carry only their font.
    if record.palette ~= nil then
      checkPalette(record.palette, context, code, entry .. ".palette")
      if #record.palette.colors % 16 ~= 0 then
        fail(code, entry .. ".palette must carry whole sixteen-color banks", context)
      end
    end
  end
  for _, role in ipairs({ "narration", "menu", "hud" }) do
    if roles[role] ~= nil and roles[role].palette == nil then
      fail(code, field .. "." .. role .. " must carry its printer palette", context)
    end
  end
end

local MENU_MODES = { standard = true, safari = true, ["pal-park"] = true, ["bug-contest"] = true }
local MENU_RUNTIME_CONTEXTS = {
  bugContest = true,
  targetSelection = true,
  moveSelection = true,
  frontierLayout = true,
}

local function checkMenuModeRules(rules, entries, context, code, field)
  SchemaCheck.checkRecord(rules, nil, context, code, field)
  for mode, rule in pairs(rules) do
    if MENU_MODES[mode] ~= true then
      fail(code, field .. " carries an unknown mode: " .. tostring(mode), context)
    end
    local entry = field .. "." .. mode
    SchemaCheck.checkRecord(rule, { labels = true, dynamicFields = true }, context, code, entry)
    SchemaCheck.checkRecord(
      rule.labels,
      { fight = true, bag = true, pokemon = true },
      context,
      code,
      entry .. ".labels"
    )
    for _, slot in ipairs({ "fight", "bag", "pokemon" }) do
      local key = rule.labels[slot]
      if key ~= nil then
        checkString(key, context, code, entry .. ".labels." .. slot)
        if entries[key] == nil then
          fail(code, entry .. ".labels." .. slot .. " references no message record", context)
        end
      end
    end
    if not Validate.isArray(rule.dynamicFields) then
      fail(code, entry .. ".dynamicFields must preserve its source field order", context)
    end
    for index, name in ipairs(rule.dynamicFields) do
      checkString(name, context, code, entry .. ".dynamicFields[" .. index .. "]")
    end
  end
  for mode in pairs(MENU_MODES) do
    if rules[mode] == nil then
      fail(code, field .. " is missing supported mode " .. mode, context)
    end
  end
end

local function checkMenuRuntimeContexts(routes, context, code, field)
  SchemaCheck.checkRecord(routes, nil, context, code, field)
  for key, route in pairs(routes) do
    if MENU_RUNTIME_CONTEXTS[key] ~= true then
      fail(code, field .. " carries an unknown runtime context: " .. tostring(key), context)
    end
    local entry = field .. "." .. key
    SchemaCheck.checkRecord(route, { inputs = true, assetRoles = true }, context, code, entry)
    for _, list in ipairs({ "inputs", "assetRoles" }) do
      local values = route[list]
      if not Validate.isArray(values) or #values == 0 then
        fail(code, entry .. "." .. list .. " must identify its source-backed requirements", context)
      end
      for index, value in ipairs(values) do
        checkString(value, context, code, entry .. "." .. list .. "[" .. index .. "]")
      end
    end
  end
  for key in pairs(MENU_RUNTIME_CONTEXTS) do
    if routes[key] == nil then
      fail(code, field .. " is missing source-backed runtime context " .. key, context)
    end
  end
end

local function checkBooleanInput(input, context, code, field)
  SchemaCheck.checkRecord(input, { type = true }, context, code, field)
  if input.type ~= "boolean" then
    fail(code, field .. " must declare a boolean input", context)
  end
end

local function checkEnumInput(input, context, code, field)
  SchemaCheck.checkRecord(input, { type = true, values = true }, context, code, field)
  if input.type ~= "enum" or not Validate.isArray(input.values) then
    fail(code, field .. " must be a typed enum", context)
  end
  checkStringArray(input.values, context, code, field .. ".values")
end

local function checkStringFields(record, names, context, code, field)
  for _, name in ipairs(names) do
    checkString(record[name], context, code, field .. "." .. name)
  end
end

local function checkMainMenuContext(main, context, code, field)
  SchemaCheck.checkRecord(main, { inputs = true, modes = true }, context, code, field)
  SchemaCheck.checkRecord(
    main.inputs,
    { mode = true, cancelRun = true, frontier = true },
    context,
    code,
    field .. ".inputs"
  )
  checkEnumInput(main.inputs.mode, context, code, field .. ".inputs.mode")
  checkBooleanInput(main.inputs.cancelRun, context, code, field .. ".inputs.cancelRun")
  checkBooleanInput(main.inputs.frontier, context, code, field .. ".inputs.frontier")
  if not Validate.isArray(main.modes) then
    fail(code, field .. ".modes must preserve supported mode order", context)
  end
  checkStringArray(main.modes, context, code, field .. ".modes")
end

local function checkBugContestMenuContext(bugContest, context, code, field)
  SchemaCheck.checkRecord(
    bugContest,
    { caughtPokemon = true, remainingSafariBalls = true, sprites = true },
    context,
    code,
    field
  )
  local caught = bugContest.caughtPokemon
  local caughtField = field .. ".caughtPokemon"
  SchemaCheck.checkRecord(caught, { optional = true, fields = true, absentSpecies = true }, context, code, caughtField)
  if caught.optional ~= true or caught.absentSpecies ~= "species/none" then
    fail(code, caughtField .. " must preserve the optional absent-species case", context)
  end
  SchemaCheck.checkRecord(
    caught.fields,
    { species = true, form = true, gender = true, level = true },
    context,
    code,
    caughtField .. ".fields"
  )
  checkStringFields(caught.fields, { "species", "form", "level" }, context, code, caughtField .. ".fields")
  local gender = caught.fields.gender
  checkEnumInput(gender, context, code, caughtField .. ".fields.gender")
  if #gender.values ~= 3 or gender.values[3] ~= "genderless" then
    fail(code, caughtField .. ".fields.gender must include genderless", context)
  end
  checkString(bugContest.remainingSafariBalls, context, code, field .. ".remainingSafariBalls")
  checkString(bugContest.sprites, context, code, field .. ".sprites")
end

local function checkMoveSelectionContext(move, context, code, field)
  SchemaCheck.checkRecord(move, { slotCount = true, slots = true }, context, code, field)
  checkInt(move.slotCount, 4, 4, context, code, field .. ".slotCount")
  SchemaCheck.checkRecord(
    move.slots,
    { move = true, currentPP = true, maximumPP = true, derived = true, emptyMove = true },
    context,
    code,
    field .. ".slots"
  )
  checkStringFields(move.slots, { "move", "currentPP", "maximumPP", "emptyMove" }, context, code, field .. ".slots")
  SchemaCheck.checkRecord(
    move.slots.derived,
    { moveName = true, moveType = true, typeIcon = true },
    context,
    code,
    field .. ".slots.derived"
  )
  checkStringFields(
    move.slots.derived,
    { "moveName", "moveType", "typeIcon" },
    context,
    code,
    field .. ".slots.derived"
  )
end

local function checkTargetSelectionContext(target, context, code, field)
  SchemaCheck.checkRecord(
    target,
    { slotCount = true, order = true, hitMask = true, visibility = true, candidate = true, iconAssetRoles = true },
    context,
    code,
    field
  )
  checkInt(target.slotCount, 4, 4, context, code, field .. ".slotCount")
  checkString(target.order, context, code, field .. ".order")
  checkString(target.hitMask, context, code, field .. ".hitMask")
  SchemaCheck.checkRecord(
    target.visibility,
    { candidateFlag = true, requiredValue = true, hitRequired = true },
    context,
    code,
    field .. ".visibility"
  )
  checkString(target.visibility.candidateFlag, context, code, field .. ".visibility.candidateFlag")
  if target.visibility.requiredValue ~= true or target.visibility.hitRequired ~= true then
    fail(code, field .. ".visibility must require visible hit candidates", context)
  end
  SchemaCheck.checkRecord(target.candidate, {
    battler = true,
    gender = true,
    selectedPartyMon = true,
    hp = true,
    maximumHP = true,
    status = true,
    nickname = true,
    species = true,
    form = true,
  }, context, code, field .. ".candidate")
  for role, value in pairs(target.candidate) do
    checkString(value, context, code, field .. ".candidate." .. role)
  end
  checkStringArray(target.iconAssetRoles, context, code, field .. ".iconAssetRoles")
end

local function checkVsRecorderContext(recorder, entries, routes, context, code, field)
  SchemaCheck.checkRecord(
    recorder,
    { inputs = true, screenRole = true, stopMessage = true, feedbackRoute = true },
    context,
    code,
    field
  )
  SchemaCheck.checkRecord(recorder.inputs, { playbackStatus = true }, context, code, field .. ".inputs")
  checkEnumInput(recorder.inputs.playbackStatus, context, code, field .. ".inputs.playbackStatus")
  checkStringFields(recorder, { "screenRole", "stopMessage", "feedbackRoute" }, context, code, field)
  if entries[recorder.stopMessage] == nil or routes[recorder.feedbackRoute] == nil then
    fail(code, field .. " must link its staged stop message and feedback route", context)
  end
end

local MENU_CONTEXTS = {
  main = true,
  bugContest = true,
  frontier = true,
  moveSelection = true,
  targetSelection = true,
  vsRecorder = true,
}

local function checkMenuContexts(contexts, entries, routes, context, code, field)
  SchemaCheck.checkRecord(contexts, MENU_CONTEXTS, context, code, field)
  for key in pairs(MENU_CONTEXTS) do
    if contexts[key] == nil then
      fail(code, field .. " is missing typed source context " .. key, context)
    end
  end
  checkMainMenuContext(contexts.main, context, code, field .. ".main")
  checkBugContestMenuContext(contexts.bugContest, context, code, field .. ".bugContest")
  local frontier = contexts.frontier
  SchemaCheck.checkRecord(frontier, { input = true, overrides = true }, context, code, field .. ".frontier")
  checkStringFields(frontier, { "input", "overrides" }, context, code, field .. ".frontier")
  checkMoveSelectionContext(contexts.moveSelection, context, code, field .. ".moveSelection")
  checkTargetSelectionContext(contexts.targetSelection, context, code, field .. ".targetSelection")
  checkVsRecorderContext(contexts.vsRecorder, entries, routes, context, code, field .. ".vsRecorder")
end

local function checkMessageRoutes(routes, entries, context, code, field)
  checkCatalogTable(routes, context, code, field)
  for key, route in pairs(routes) do
    checkString(key, context, code, field .. " key")
    local entry = field .. "[" .. key .. "]"
    SchemaCheck.checkRecord(
      route,
      { template = true, templates = true, variants = true, inputs = true, branches = true },
      context,
      code,
      entry
    )
    if not Validate.isArray(route.inputs) then
      fail(code, entry .. ".inputs must identify its dynamic values", context)
    end
    for index, input in ipairs(route.inputs) do
      checkString(input, context, code, entry .. ".inputs[" .. index .. "]")
    end
    local references = {}
    if route.template ~= nil then
      references[1] = route.template
    elseif route.templates ~= nil then
      if not Validate.isArray(route.templates) then
        fail(code, entry .. ".templates must be ordered", context)
      end
      references = route.templates
    elseif route.variants ~= nil then
      if not Validate.isArray(route.variants) then
        fail(code, entry .. ".variants must be ordered", context)
      end
      references = route.variants
    else
      fail(code, entry .. " must reference source message templates", context)
    end
    for index, reference in ipairs(references) do
      checkString(reference, context, code, entry .. " template[" .. index .. "]")
      if entries[reference] == nil then
        fail(code, entry .. " references no message record: " .. reference, context)
      end
    end
    if route.branches ~= nil then
      SchemaCheck.checkRecord(route.branches, nil, context, code, entry .. ".branches")
      for branch, branchReferences in pairs(route.branches) do
        checkString(branch, context, code, entry .. ".branches key")
        if not Validate.isArray(branchReferences) or #branchReferences ~= 2 then
          fail(code, entry .. ".branches." .. branch .. " must contain its two ordered message lines", context)
        end
        for index, reference in ipairs(branchReferences) do
          checkString(reference, context, code, entry .. ".branches." .. branch .. "[" .. index .. "]")
          if entries[reference] == nil then
            fail(code, entry .. ".branches." .. branch .. " references no message record: " .. reference, context)
          end
        end
      end
    end
  end
end

local function checkMessageBankReferences(banks, resources, context, code, field)
  checkCatalogTable(banks, context, code, field)
  for role, resourceKey in pairs(banks) do
    checkString(role, context, code, field .. " role")
    checkString(resourceKey, context, code, field .. "." .. role)
    local resource = resources[resourceKey]
    if resource == nil or resource.kind ~= "message" then
      fail(code, field .. "." .. role .. " must reference a staged message-bank resource", context)
    end
  end
end

-- Transition name routes and the source-selected input each one reads.
local TRANSITION_NAME_ROUTE_INPUTS = { trainerName = "trainerName", rivalName = "rivalName" }

local function checkTransitionRouteResources(routes, messageEntries, resources, context, code, field)
  SchemaCheck.checkRecord(routes, { trainerName = true, rivalName = true }, context, code, field)
  for routeName, expectedInput in pairs(TRANSITION_NAME_ROUTE_INPUTS) do
    local route = routes[routeName]
    local routeField = field .. "." .. routeName
    SchemaCheck.checkRecord(route, { message = true, inputs = true, resources = true }, context, code, routeField)
    if route.message ~= "transition/trainer-name" or messageEntries[route.message] == nil then
      fail(code, routeField .. " must reference the staged transition name template", context)
    end
    if not Validate.isArray(route.inputs) or #route.inputs ~= 1 or route.inputs[1] ~= expectedInput then
      fail(code, routeField .. " must declare its source-selected name input", context)
    end
    if not Validate.isArray(route.resources) or #route.resources == 0 then
      fail(code, routeField .. " must link its source-loaded resources", context)
    end
    for index, resourceKey in ipairs(route.resources) do
      checkString(resourceKey, context, code, routeField .. ".resources[" .. index .. "]")
      if resources[resourceKey] == nil then
        fail(code, routeField .. " references an unstaged transition resource", context)
      end
    end
  end
end

local function checkTransitionTask(task, context, code, field)
  SchemaCheck.checkRecord(task, { kind = true, parameters = true }, context, code, field)
  checkString(task.kind, context, code, field .. ".kind")
  local parameters = task.parameters
  if task.kind == "field-camera-pose-sequence" then
    SchemaCheck.checkRecord(
      parameters,
      { poses = true, fadeTicks = true, graphicsMode = true },
      context,
      code,
      field .. ".parameters"
    )
    if not Validate.isArray(parameters.poses) or #parameters.poses ~= 16 then
      fail(code, field .. ".parameters.poses must carry all sixteen source camera poses", context)
    end
    for index, pose in ipairs(parameters.poses) do
      local poseField = field .. ".parameters.poses[" .. index .. "]"
      SchemaCheck.checkRecord(
        pose,
        { distanceFx32 = true, angleXRaw = true, angleYRaw = true, perspectiveRaw = true, waitTicks = true },
        context,
        code,
        poseField
      )
      checkInt(pose.distanceFx32, 1, 0x7fffffff, context, code, poseField .. ".distanceFx32")
      checkInt(pose.angleXRaw, 0, 0xffff, context, code, poseField .. ".angleXRaw")
      checkInt(pose.angleYRaw, 0, 0xffff, context, code, poseField .. ".angleYRaw")
      checkInt(pose.perspectiveRaw, 0, 0xffff, context, code, poseField .. ".perspectiveRaw")
      checkInt(pose.waitTicks, 1, 255, context, code, poseField .. ".waitTicks")
    end
    checkInt(parameters.fadeTicks, 1, 255, context, code, field .. ".parameters.fadeTicks")
  elseif task.kind == "field-camera-perspective-distance-fade" then
    SchemaCheck.checkRecord(parameters, {
      perspectiveDeltaRaw = true,
      perspectiveTicks = true,
      waitTicks = true,
      distanceDeltaFx32 = true,
      distanceVelocityFx32 = true,
      distanceTicks = true,
      fadeTicks = true,
      graphicsMode = true,
    }, context, code, field .. ".parameters")
    checkInt(parameters.perspectiveDeltaRaw, -0xffff, 0xffff, context, code, field .. ".parameters.perspectiveDeltaRaw")
    checkInt(parameters.perspectiveTicks, 1, 255, context, code, field .. ".parameters.perspectiveTicks")
    checkInt(parameters.waitTicks, 1, 255, context, code, field .. ".parameters.waitTicks")
    checkInt(
      parameters.distanceDeltaFx32,
      -0x80000000,
      0x7fffffff,
      context,
      code,
      field .. ".parameters.distanceDeltaFx32"
    )
    checkInt(
      parameters.distanceVelocityFx32,
      -0x80000000,
      0x7fffffff,
      context,
      code,
      field .. ".parameters.distanceVelocityFx32"
    )
    checkInt(parameters.distanceTicks, 1, 255, context, code, field .. ".parameters.distanceTicks")
    checkInt(parameters.fadeTicks, 1, 255, context, code, field .. ".parameters.fadeTicks")
  elseif task.kind == "overlay115-gym-rival-intro" then
    SchemaCheck.checkRecord(parameters, { endXFx32 = true }, context, code, field .. ".parameters")
    checkInt(parameters.endXFx32, -0x80000000, 0x7fffffff, context, code, field .. ".parameters.endXFx32")
    if parameters.endXFx32 ~= 876544 then
      fail(code, field .. ".parameters.endXFx32 must retain the source Q12 endpoint", context)
    end
    return
  elseif task.kind == "overlay115-elite-intro" then
    SchemaCheck.checkRecord(parameters, { shakeTicks = true }, context, code, field .. ".parameters")
    checkInt(parameters.shakeTicks, 1, 0xffff, context, code, field .. ".parameters.shakeTicks")
    return
  else
    fail(code, field .. ".kind is not a supported normalized transition task", context)
  end
  SchemaCheck.checkRecord(
    parameters.graphicsMode,
    { mode = true, bank = true },
    context,
    code,
    field .. ".parameters.graphicsMode"
  )
  checkInt(parameters.graphicsMode.mode, 0, 0xffff, context, code, field .. ".parameters.graphicsMode.mode")
  checkInt(parameters.graphicsMode.bank, 0, 0xffff, context, code, field .. ".parameters.graphicsMode.bank")
end

local TRANSITION_CONTEXT_INPUTS = {
  battleType = true,
  terrain = true,
  timeOfDay = true,
  trainerClass = true,
  wildSpecies = true,
  playerGender = true,
  trainerName = true,
  rivalName = true,
  transitionTrainer = true,
}
local TRANSITION_TRAINER_KEYS = { will = true, koga = true, bruno = true, karen = true, lance = true, red = true }

-- Source loader groupings nest arbitrarily but only ever name resources
-- the route itself loads.
local function checkResourceGroup(value, resources, routeResources, context, code, field)
  if type(value) == "string" then
    if resources[value] == nil or not routeResources[value] then
      fail(code, field .. " references a resource outside its route", context)
    end
  elseif type(value) == "table" then
    for _, nested in pairs(value) do
      checkResourceGroup(nested, resources, routeResources, context, code, field)
    end
  else
    fail(code, field .. " must contain only semantic resource references", context)
  end
end

local function checkTransitionRoute(route, messageEntries, messageRoutes, resources, context, code, entry)
  SchemaCheck.checkRecord(route, {
    role = true,
    requiredContext = true,
    resources = true,
    assetGroups = true,
    messages = true,
    trainer = true,
    task = true,
  }, context, code, entry)
  checkString(route.role, context, code, entry .. ".role")
  if route.task ~= nil then
    checkTransitionTask(route.task, context, code, entry .. ".task")
  end
  if not Validate.isArray(route.requiredContext) then
    fail(code, entry .. ".requiredContext must list its source-derived inputs", context)
  end
  local seenInputs = {}
  for index, input in ipairs(route.requiredContext) do
    checkString(input, context, code, entry .. ".requiredContext[" .. index .. "]")
    if TRANSITION_CONTEXT_INPUTS[input] ~= true or seenInputs[input] then
      fail(code, entry .. ".requiredContext carries an unknown or repeated input", context)
    end
    seenInputs[input] = true
  end
  if not Validate.isArray(route.resources) then
    fail(code, entry .. ".resources must be an ordered semantic resource list", context)
  end
  for index, resourceKey in ipairs(route.resources) do
    checkString(resourceKey, context, code, entry .. ".resources[" .. index .. "]")
    if resources[resourceKey] == nil then
      fail(code, entry .. ".resources references an unstaged resource", context)
    end
  end
  if type(route.assetGroups) ~= "table" then
    fail(code, entry .. ".assetGroups must preserve source loader groupings", context)
  end
  checkResourceGroup(route.assetGroups, resources, valueSet(route.resources), context, code, entry .. ".assetGroups")
  if
    route.role == "plain-wild-fallback"
    or route.role == "water-wild-fallback"
    or route.role == "cave-wild-fallback"
  then
    local orderKey = route.assetGroups.wildCellOrders
    local order = type(orderKey) == "string" and resources[orderKey] or nil
    if type(order) ~= "table" or order.kind ~= "transition-data" or order.format ~= "hgss-wild-cell-grid-orders-v1" then
      fail(code, entry .. " wild transition routes require staged retail cell grid orders", context)
    end
  end
  if route.messages ~= nil then
    if not Validate.isArray(route.messages) then
      fail(code, entry .. ".messages must be an ordered list of message routes", context)
    end
    for index, messageKey in ipairs(route.messages) do
      checkString(messageKey, context, code, entry .. ".messages[" .. index .. "]")
      if messageEntries[messageKey] == nil and messageRoutes[messageKey] == nil then
        fail(code, entry .. ".messages references an unstaged semantic message route", context)
      end
    end
  end
  if route.trainer ~= nil then
    SchemaCheck.checkRecord(route.trainer, { key = true }, context, code, entry .. ".trainer")
    if TRANSITION_TRAINER_KEYS[route.trainer.key] ~= true or not seenInputs.transitionTrainer then
      fail(code, entry .. ".trainer must bind a semantic trainer identity through transitionTrainer context", context)
    end
  elseif seenInputs.transitionTrainer then
    fail(code, entry .. " declares transitionTrainer without a semantic trainer identity", context)
  end
end

local function checkTransitionRoutes(routes, messageEntries, messageRoutes, resources, context, code, field)
  checkCatalogTable(routes, context, code, field)
  for key, route in pairs(routes) do
    checkString(key, context, code, field .. " key")
    checkTransitionRoute(route, messageEntries, messageRoutes, resources, context, code, field .. "[" .. key .. "]")
  end
end

-- A selected route is a staged semantic route or the setup fallback.
local function checkSelectedRoute(routeKey, routes, context, code, keyField, owner)
  checkString(routeKey, context, code, keyField)
  if routeKey ~= "setup-fallback" and routes[routeKey] == nil then
    fail(code, owner .. " references an unknown semantic route", context)
  end
end

local TRANSITION_SELECTION_MAPS = {
  { routes = "trainerClassRoutes", musicRoles = "trainerClassMusicRoles" },
  { routes = "wildSpeciesRoutes", musicRoles = "wildSpeciesMusicRoles" },
}

local function checkTransitionSelectionMaps(selection, routes, context, code, field)
  for _, maps in ipairs(TRANSITION_SELECTION_MAPS) do
    local routeField = field .. "." .. maps.routes
    checkCatalogTable(selection[maps.routes], context, code, routeField)
    for inputKey, routeKey in pairs(selection[maps.routes]) do
      checkString(inputKey, context, code, routeField .. " key")
      checkSelectedRoute(routeKey, routes, context, code, routeField .. " value", routeField)
    end
  end
  for _, maps in ipairs(TRANSITION_SELECTION_MAPS) do
    local musicField = field .. "." .. maps.musicRoles
    checkCatalogTable(selection[maps.musicRoles], context, code, musicField)
    for inputKey, musicRole in pairs(selection[maps.musicRoles]) do
      checkString(inputKey, context, code, musicField .. " key")
      checkString(musicRole, context, code, musicField .. " role")
      if selection[maps.routes][inputKey] == nil then
        fail(code, musicField .. " contains an input without a semantic route", context)
      end
    end
  end
end

local function checkTrainerSelectionRules(trainer, routes, context, code, field)
  SchemaCheck.checkRecord(trainer, {
    inputs = true,
    specialBattle = true,
    preserveRoutes = true,
    doublesRoute = true,
    alternateTransitionRoute = true,
    unknownRoute = true,
    unknownMusicRole = true,
    doublesMusicRole = true,
    alternateMusicRole = true,
  }, context, code, field .. ".trainerRules")
  if not isExactList(trainer.inputs, { "trainerClass", "battleType" }) then
    fail(code, field .. ".trainerRules must declare trainer and battle type inputs", context)
  end
  local special = trainer.specialBattle
  SchemaCheck.checkRecord(special, {
    preserveRoute = true,
    preserveMusicRole = true,
    defaultRoute = true,
    defaultMusicRole = true,
    doublesRoute = true,
    doublesMusicRole = true,
  }, context, code, field)
  if not Validate.isArray(trainer.preserveRoutes) or #trainer.preserveRoutes == 0 then
    fail(code, field .. ".trainerRules must retain source-preserved semantic routes", context)
  end
  local rulesField = field .. ".trainerRules"
  for _, routeKey in ipairs({
    special.preserveRoute,
    special.defaultRoute,
    special.doublesRoute,
    trainer.unknownRoute,
    trainer.doublesRoute,
    trainer.alternateTransitionRoute,
  }) do
    checkSelectedRoute(routeKey, routes, context, code, rulesField .. " route", rulesField)
  end
  for _, routeKey in ipairs(trainer.preserveRoutes) do
    checkSelectedRoute(
      routeKey,
      routes,
      context,
      code,
      rulesField .. ".preserveRoutes",
      rulesField .. ".preserveRoutes"
    )
  end
  for _, musicRole in ipairs({
    special.preserveMusicRole,
    special.defaultMusicRole,
    special.doublesMusicRole,
    trainer.unknownMusicRole,
    trainer.doublesMusicRole,
    trainer.alternateMusicRole,
  }) do
    checkString(musicRole, context, code, rulesField .. " music role")
  end
end

local function checkWildSelectionRules(wild, routes, context, code, field)
  local rulesField = field .. ".wildRules"
  SchemaCheck.checkRecord(wild, {
    inputs = true,
    specialMode = true,
    fallbackRoute = true,
    fallbackMusicRole = true,
    doublesRoute = true,
    doublesMusicRole = true,
  }, context, code, rulesField)
  if not isExactList(wild.inputs, { "wildSpecies", "battleType", "transitionMode" }) then
    fail(code, rulesField .. " must declare species, battle type, and transition mode inputs", context)
  end
  checkString(wild.specialMode, context, code, rulesField .. ".specialMode")
  for _, routeKey in ipairs({ wild.fallbackRoute, wild.doublesRoute }) do
    checkSelectedRoute(routeKey, routes, context, code, rulesField .. " route", rulesField)
  end
  checkString(wild.fallbackMusicRole, context, code, rulesField .. ".fallbackMusicRole")
  checkString(wild.doublesMusicRole, context, code, rulesField .. ".doublesMusicRole")
end

local FALLBACK_TERRAINS = { plain = true, water = true, cave = true }
local FALLBACK_TIMES = { day = true, late = true }

local function checkFallbackRoutes(fallbackRoutes, routes, context, code, field)
  if not Validate.isArray(fallbackRoutes) or #fallbackRoutes ~= 12 then
    fail(code, field .. " must enumerate every semantic setup fallback", context)
  end
  local fallbackContexts = {}
  for index, fallback in ipairs(fallbackRoutes) do
    local entry = field .. "[" .. index .. "]"
    SchemaCheck.checkRecord(
      fallback,
      { route = true, terrain = true, timeOfDay = true, battleKind = true },
      context,
      code,
      entry
    )
    checkString(fallback.route, context, code, entry .. ".route")
    if not FALLBACK_TERRAINS[fallback.terrain] then
      fail(code, entry .. ".terrain must be a source-backed semantic terrain", context)
    end
    if not FALLBACK_TIMES[fallback.timeOfDay] then
      fail(code, entry .. ".timeOfDay must be day or late", context)
    end
    if routes[fallback.route] == nil or (fallback.battleKind ~= "trainer" and fallback.battleKind ~= "wild") then
      fail(code, entry .. " must reference its semantic fallback route and battle kind", context)
    end
    local contextKey = fallback.terrain .. "/" .. fallback.timeOfDay .. "/" .. fallback.battleKind
    if fallbackContexts[contextKey] then
      fail(code, field .. " repeats a setup context", context)
    end
    fallbackContexts[contextKey] = true
  end
end

local function checkTransitionSelection(selection, routes, context, code, field)
  SchemaCheck.checkRecord(selection, {
    trainerClassRoutes = true,
    wildSpeciesRoutes = true,
    trainerClassMusicRoles = true,
    wildSpeciesMusicRoles = true,
    trainerRules = true,
    wildRules = true,
    fallbackRoutes = true,
  }, context, code, field)
  checkTransitionSelectionMaps(selection, routes, context, code, field)
  checkTrainerSelectionRules(selection.trainerRules, routes, context, code, field)
  checkWildSelectionRules(selection.wildRules, routes, context, code, field)
  checkFallbackRoutes(selection.fallbackRoutes, routes, context, code, field .. ".fallbackRoutes")
end

local TRANSITION_SPRITE_KINDS = { palette = "palette", character = "texture", cell = "cell", animation = "animation" }

local function checkTransitionInternalResources(routes, resources, context, code, field)
  SchemaCheck.checkRecord(routes, { sprite = true }, context, code, field)
  local sprite = routes.sprite
  SchemaCheck.checkRecord(sprite, TRANSITION_SPRITE_KINDS, context, code, field .. ".sprite")
  for role, expectedKind in pairs(TRANSITION_SPRITE_KINDS) do
    local descriptor = resources[sprite[role]]
    if descriptor == nil or descriptor.kind ~= expectedKind then
      fail(code, field .. ".sprite." .. role .. " must reference a decoded " .. expectedKind .. " resource", context)
    end
  end
end

local function checkCaptureShakeRoute(capture, banks, entries, context, code, field)
  SchemaCheck.checkRecord(
    capture,
    { bank = true, input = true, firstRecord = true, minimum = true, maximum = true, recordCount = true },
    context,
    code,
    field
  )
  if banks.scriptController ~= capture.bank or capture.input ~= "captureShakeCount" then
    fail(code, field .. " must use the script-controller bank and capture count", context)
  end
  checkInt(capture.minimum, 0, 0, context, code, field .. ".minimum")
  checkInt(capture.maximum, 4, 4, context, code, field .. ".maximum")
  checkInt(capture.recordCount, 5, 5, context, code, field .. ".recordCount")
  checkString(capture.firstRecord, context, code, field .. ".firstRecord")
  local recordPrefix, firstOffset = capture.firstRecord:match("^(.*)/(%d+)$")
  if recordPrefix == nil or firstOffset ~= "0" then
    fail(code, field .. ".firstRecord must identify the zero-offset record", context)
  end
  for offset = 0, 4 do
    if entries[recordPrefix .. "/" .. offset] == nil then
      fail(code, field .. " omits source record offset " .. offset, context)
    end
  end
end

local function checkMetBillRoute(metBill, banks, entries, context, code, field)
  SchemaCheck.checkRecord(metBill, { banks = true, inputs = true, cases = true }, context, code, field)
  if not Validate.isArray(metBill.banks) or #metBill.banks ~= 1 or metBill.banks[1] ~= banks.scriptController then
    fail(code, field .. " must use the script-controller bank", context)
  end
  if not isExactList(metBill.inputs, { "metBill", "pcHasSpace" }) then
    fail(code, field .. " must retain its two source inputs", context)
  end
  if not Validate.isArray(metBill.cases) or #metBill.cases ~= 4 then
    fail(code, field .. " must map its four boolean cases", context)
  end
  for index, case in ipairs(metBill.cases) do
    local caseField = field .. ".cases[" .. index .. "]"
    SchemaCheck.checkRecord(case, { key = true, metBill = true, pcHasSpace = true }, context, code, caseField)
    checkString(case.key, context, code, caseField .. ".key")
    if entries[case.key] == nil or type(case.metBill) ~= "boolean" or type(case.pcHasSpace) ~= "boolean" then
      fail(code, caseField .. " must select a source-backed message by boolean inputs", context)
    end
  end
end

local function checkFrontierSpeechRoute(frontier, banks, context, code, field)
  SchemaCheck.checkRecord(
    frontier,
    { banks = true, inputs = true, profilePredicate = true, recordFormula = true },
    context,
    code,
    field
  )
  if
    not Validate.isArray(frontier.banks)
    or #frontier.banks ~= 2
    or frontier.banks[1] ~= banks.frontierTrainerProfileZero
    or frontier.banks[2] ~= banks.frontierTrainerProfileFallback
    or frontier.profilePredicate ~= "anyPlayerProfileVersionZero"
  then
    fail(code, field .. " must preserve the source profile-bank selection", context)
  end
  if not Validate.isArray(frontier.inputs) or #frontier.inputs ~= 3 then
    fail(code, field .. " must preserve trainer, outcome, and profile inputs", context)
  end
  local formula = frontier.recordFormula
  local formulaField = field .. ".recordFormula"
  SchemaCheck.checkRecord(
    formula,
    { trainerIndexMultiplier = true, winOffset = true, lossOffset = true },
    context,
    code,
    formulaField
  )
  checkInt(formula.trainerIndexMultiplier, 3, 3, context, code, formulaField .. ".trainerIndexMultiplier")
  checkInt(formula.winOffset, 1, 1, context, code, formulaField .. ".winOffset")
  checkInt(formula.lossOffset, 2, 2, context, code, formulaField .. ".lossOffset")
end

-- Decoded trainer-message index tables by selection role.
local TRAINER_MESSAGE_INDEX_FORMATS = {
  { role = "offsets", format = "hgss-trainer-message-offsets-v1" },
  { role = "pairs", format = "hgss-trainer-message-pairs-v1" },
}

local function checkTrainerPairSelection(selection, resources, context, code, field)
  SchemaCheck.checkRecord(
    selection,
    { lookup = true, offsetsResource = true, pairsResource = true, offsetSelection = true, pairSelection = true },
    context,
    code,
    field
  )
  if selection.lookup ~= "trainer-message-index" then
    fail(code, field .. " must use the decoded trainer-message index", context)
  end
  for _, indexTable in ipairs(TRAINER_MESSAGE_INDEX_FORMATS) do
    local descriptor = resources[selection[indexTable.role .. "Resource"]]
    if descriptor == nil or descriptor.kind ~= "message" or descriptor.format ~= indexTable.format then
      fail(code, field .. " must reference its decoded " .. indexTable.role .. " table", context)
    end
  end
  local offsetSelection = selection.offsetSelection
  SchemaCheck.checkRecord(
    offsetSelection,
    { input = true, elementStrideBytes = true, valueWidthBytes = true, result = true },
    context,
    code,
    field .. ".offsetSelection"
  )
  if
    offsetSelection.input ~= "trainerIndex"
    or offsetSelection.elementStrideBytes ~= 2
    or offsetSelection.valueWidthBytes ~= 2
    or offsetSelection.result ~= "pair-record-byte-offset"
  then
    fail(code, field .. " must preserve the source offset-table layout", context)
  end
  local pairSelection = selection.pairSelection
  SchemaCheck.checkRecord(
    pairSelection,
    { inputs = true, recordStrideBytes = true, match = true, result = true },
    context,
    code,
    field .. ".pairSelection"
  )
  if
    not isExactList(pairSelection.inputs, { "trainerIndex", "trainerMessageKind" })
    or pairSelection.recordStrideBytes ~= 4
    or pairSelection.match ~= "trainer-and-message-kind"
    or pairSelection.result ~= "messageRecordReference"
  then
    fail(code, field .. " must preserve the source pair-record layout", context)
  end
end

local function checkTrainerPairSpeechRoute(pairSpeech, banks, resources, context, code, field)
  SchemaCheck.checkRecord(pairSpeech, { bank = true, inputs = true, selection = true }, context, code, field)
  if pairSpeech.bank ~= banks.trainerPairLookup then
    fail(code, field .. " must use the source pair-table selection", context)
  end
  if not isExactList(pairSpeech.inputs, { "trainerIndex", "trainerMessageKind" }) then
    fail(code, field .. " must retain trainer and message-kind inputs", context)
  end
  checkTrainerPairSelection(pairSpeech.selection, resources, context, code, field .. ".selection")
end

local function checkTutorialAuthorRoute(tutorial, banks, entries, context, code, field)
  SchemaCheck.checkRecord(tutorial, { bank = true, input = true, variants = true }, context, code, field)
  if tutorial.bank ~= banks.tutorialAuthor or tutorial.input ~= "playerGender" then
    fail(code, field .. " must use the gender-selected tutorial bank", context)
  end
  SchemaCheck.checkRecord(
    tutorial.variants,
    { malePlayer = true, femalePlayer = true },
    context,
    code,
    field .. ".variants"
  )
  for _, variant in pairs(tutorial.variants) do
    checkString(variant, context, code, field .. ".variants")
    if entries[variant] == nil then
      fail(code, field .. " references a missing message record", context)
    end
  end
end

local function checkMessageDynamicRoutes(messages, resources, context, code, field)
  if type(resources) ~= "table" then
    fail(code, field .. " requires the decoded global resource catalog", context)
  end
  local routes, banks, entries = messages.dynamicRoutes, messages.banks, messages.entries
  SchemaCheck.checkRecord(routes, {
    captureShake = true,
    metBillPCTransfer = true,
    frontierTrainerSpeech = true,
    trainerPairSpeech = true,
    tutorialAuthor = true,
  }, context, code, field)
  checkCaptureShakeRoute(routes.captureShake, banks, entries, context, code, field .. ".captureShake")
  checkMetBillRoute(routes.metBillPCTransfer, banks, entries, context, code, field .. ".metBillPCTransfer")
  checkFrontierSpeechRoute(routes.frontierTrainerSpeech, banks, context, code, field .. ".frontierTrainerSpeech")
  checkTrainerPairSpeechRoute(routes.trainerPairSpeech, banks, resources, context, code, field .. ".trainerPairSpeech")
  checkTutorialAuthorRoute(routes.tutorialAuthor, banks, entries, context, code, field .. ".tutorialAuthor")
end

-- Optional string-valued source route descriptors.
local SOURCE_ROUTE_STRING_FIELDS = {
  "placeholderPlan",
  "expansion",
  "selectionCase",
  "placeholderInputs",
  "bufferPlan",
  "selection",
  "recordSelection",
  "profilePredicate",
}

-- Battle-script message routes and the message scope each one delivers to.
local SCRIPT_MESSAGE_ROUTE_DELIVERY = {
  ["battle/script-message"] = "message-scope-local",
  ["battle/global-script-message"] = "message-scope-global",
}

local SOURCE_ROUTE_FIELDS = {
  banks = true,
  inputs = true,
  placeholderPlan = true,
  expansion = true,
  selectionCase = true,
  placeholderInputs = true,
  bufferPlan = true,
  selection = true,
  recordSelection = true,
  recordFormula = true,
  profilePredicate = true,
  resources = true,
  routes = true,
  reachableCases = true,
  unresolvedCases = true,
  programContext = true,
}

-- An optional ordered list; `arrayMessage` names its required order.
local function checkOptionalStringList(values, arrayMessage, context, code, field)
  if values == nil then
    return
  end
  if not Validate.isArray(values) then
    fail(code, field .. arrayMessage, context)
  end
  for index, value in ipairs(values) do
    checkString(value, context, code, field .. "[" .. index .. "]")
  end
end

local function checkSourceRouteLinks(route, messages, resources, context, code, entry)
  if route.resources ~= nil then
    if not Validate.isArray(route.resources) then
      fail(code, entry .. ".resources must list semantic dependencies", context)
    end
    for index, resourceKey in ipairs(route.resources) do
      checkString(resourceKey, context, code, entry .. ".resources[" .. index .. "]")
      if resources[resourceKey] == nil then
        fail(code, entry .. " references an unstaged semantic dependency", context)
      end
    end
  end
  if route.routes ~= nil then
    if not Validate.isArray(route.routes) then
      fail(code, entry .. ".routes must list normalized message routes", context)
    end
    for index, messageRouteKey in ipairs(route.routes) do
      checkString(messageRouteKey, context, code, entry .. ".routes[" .. index .. "]")
      if messages.dynamicRoutes[messageRouteKey] == nil and messages.routes[messageRouteKey] == nil then
        fail(code, entry .. " references an unknown normalized message route", context)
      end
    end
  end
end

local function checkMessageSourceRoute(routeKey, route, messages, resources, context, code, entry)
  SchemaCheck.checkRecord(route, SOURCE_ROUTE_FIELDS, context, code, entry)
  if not Validate.isArray(route.banks) or not Validate.isArray(route.inputs) then
    fail(code, entry .. " must carry ordered semantic banks and runtime inputs", context)
  end
  local expectedDelivery = SCRIPT_MESSAGE_ROUTE_DELIVERY[routeKey]
  if expectedDelivery ~= nil then
    checkBattleMessageProgramContext(route.programContext, route, messages, context, code, entry .. ".programContext")
    if route.programContext.delivery ~= expectedDelivery then
      fail(code, entry .. ".programContext.delivery must preserve its source message scope", context)
    end
  elseif route.programContext ~= nil then
    fail(code, entry .. ".programContext is only defined for the battle script-message route", context)
  end
  local stagedBanks = {}
  for _, bankKey in pairs(messages.banks) do
    stagedBanks[bankKey] = true
  end
  for index, bank in ipairs(route.banks) do
    checkString(bank, context, code, entry .. ".banks[" .. index .. "]")
    if not stagedBanks[bank] then
      fail(code, entry .. " references an unknown staged message bank", context)
    end
  end
  for index, input in ipairs(route.inputs) do
    checkString(input, context, code, entry .. ".inputs[" .. index .. "]")
  end
  for _, fieldName in ipairs(SOURCE_ROUTE_STRING_FIELDS) do
    if route[fieldName] ~= nil then
      checkString(route[fieldName], context, code, entry .. "." .. fieldName)
    end
  end
  local formula = route.recordFormula
  if formula ~= nil then
    local formulaField = entry .. ".recordFormula"
    SchemaCheck.checkRecord(
      formula,
      { trainerIndexMultiplier = true, winOffset = true, lossOffset = true },
      context,
      code,
      formulaField
    )
    checkInt(formula.trainerIndexMultiplier, 1, nil, context, code, formulaField .. ".trainerIndexMultiplier")
    checkInt(formula.winOffset, 0, nil, context, code, formulaField .. ".winOffset")
    checkInt(formula.lossOffset, 0, nil, context, code, formulaField .. ".lossOffset")
  end
  checkSourceRouteLinks(route, messages, resources, context, code, entry)
  checkOptionalStringList(
    route.reachableCases,
    " must be an ordered case list",
    context,
    code,
    entry .. ".reachableCases"
  )
  checkOptionalStringList(
    route.unresolvedCases,
    " must be an ordered case list",
    context,
    code,
    entry .. ".unresolvedCases"
  )
end

local function checkMessageSourceRoutes(messages, resources, context, code, field)
  local routes = messages.sourceRoutes
  checkCatalogTable(routes, context, code, field)
  for routeKey, route in pairs(routes) do
    checkString(routeKey, context, code, field .. " key")
    checkMessageSourceRoute(routeKey, route, messages, resources, context, code, field .. "[" .. routeKey .. "]")
  end
end

local function checkMessagePlaceholders(placeholders, placeholderBanks, context, code, field)
  checkCatalogTable(placeholders, context, code, field)
  for role, descriptor in pairs(placeholders) do
    checkString(role, context, code, field .. " key")
    local entry = field .. "[" .. role .. "]"
    SchemaCheck.checkRecord(descriptor, { bank = true, input = true }, context, code, entry)
    checkString(descriptor.bank, context, code, entry .. ".bank")
    checkString(descriptor.input, context, code, entry .. ".input")
    if placeholderBanks[role] ~= descriptor.bank then
      fail(code, entry .. " must reference its staged role bank", context)
    end
  end
end

local AUDIO_BANK_KEY = "^audio/bank/content/" .. ("%x"):rep(40) .. "$"
local AUDIO_SAMPLE_KEY = "^audio/sample/content/" .. ("%x"):rep(40) .. "$"

-- Resolves a semantic sequence key to its compiled closure.
local function checkSequenceKey(sequenceKey, closures, context, code, field)
  checkString(sequenceKey, context, code, field)
  if not sequenceKey:match("^audio/sequence/[a-zA-Z0-9_%-]+$") then
    fail(code, field .. " must use a semantic sequence key", context)
  end
  if closures[sequenceKey] == nil then
    fail(code, field .. " has no compiled sequence closure", context)
  end
end

local function checkSequenceClosure(closure, context, code, record)
  SchemaCheck.checkRecord(
    closure,
    { bankKey = true, player = true, sampleKeys = true, closureIdentity = true },
    context,
    code,
    record
  )
  if type(closure.bankKey) ~= "string" or not closure.bankKey:match(AUDIO_BANK_KEY) then
    fail(code, record .. ".bankKey must name content-addressed compiled audio", context)
  end
  SchemaCheck.checkRecord(
    closure.player,
    { volume = true, channelPriority = true, playerPriority = true },
    context,
    code,
    record .. ".player"
  )
  checkInt(closure.player.volume, 0, 127, context, code, record .. ".player.volume")
  checkInt(closure.player.channelPriority, 0, 127, context, code, record .. ".player.channelPriority")
  checkInt(closure.player.playerPriority, 0, 127, context, code, record .. ".player.playerPriority")
  checkStringArray(closure.sampleKeys, context, code, record .. ".sampleKeys")
  if #closure.sampleKeys == 0 then
    fail(code, record .. ".sampleKeys must close the selected bank resources", context)
  end
  for index, sampleKey in ipairs(closure.sampleKeys) do
    if not sampleKey:match(AUDIO_SAMPLE_KEY) then
      fail(code, record .. ".sampleKeys[" .. index .. "] must be a content-addressed sample key", context)
    end
  end
  if not isSha1Text(closure.closureIdentity) then
    fail(code, record .. ".closureIdentity must be a SHA-1 identity", context)
  end
end

-- Returns the set of declared semantic route keys.
local function checkIntroMusicRoutes(introMusic, inputSet, context, code, field)
  local closures = introMusic.sequenceClosures
  if not Validate.isArray(introMusic.routes) or #introMusic.routes == 0 then
    fail(code, field .. ".routes must include source-normalized music routes", context)
  end
  local routes = {}
  for index, route in ipairs(introMusic.routes) do
    local record = field .. ".routes[" .. index .. "]"
    SchemaCheck.checkRecord(route, { key = true, sequenceKey = true, context = true }, context, code, record)
    checkString(route.key, context, code, record .. ".key")
    if routes[route.key] then
      fail(code, record .. ".key is duplicated", context)
    end
    routes[route.key] = true
    checkSequenceKey(route.sequenceKey, closures, context, code, record .. ".sequenceKey")
    checkStringArray(route.context, context, code, record .. ".context")
    if #route.context == 0 then
      fail(code, record .. ".context must declare the source selection inputs", context)
    end
    for _, input in ipairs(route.context) do
      if inputSet[input] ~= true then
        fail(code, record .. ".context references an undeclared input", context)
      end
    end
  end
  if not Validate.isArray(introMusic.sourceRoutes) or #introMusic.sourceRoutes == 0 then
    fail(code, field .. ".sourceRoutes must retain the pinned music selection rows", context)
  end
  for index, route in ipairs(introMusic.sourceRoutes) do
    local record = field .. ".sourceRoutes[" .. index .. "]"
    SchemaCheck.checkRecord(
      route,
      { sequenceSymbol = true, routeKey = true, sequenceKey = true, transitionFallback = true },
      context,
      code,
      record
    )
    checkString(route.sequenceSymbol, context, code, record .. ".sequenceSymbol")
    checkString(route.routeKey, context, code, record .. ".routeKey")
    checkSequenceKey(route.sequenceKey, closures, context, code, record .. ".sequenceKey")
    if routes[route.routeKey] ~= true or type(route.transitionFallback) ~= "boolean" then
      fail(code, record .. " must link to a semantic route and preserve fallback selection", context)
    end
  end
end

local function checkIntroMusicSelection(introMusic, context, code, field)
  checkStringArray(introMusic.kantoOverrides, context, code, field .. ".kantoOverrides")
  local kanto = introMusic.kantoSelection
  SchemaCheck.checkRecord(
    kanto,
    { predicate = true, appliesAfterCategorySelection = true, routes = true },
    context,
    code,
    field .. ".kantoSelection"
  )
  checkStringArray(kanto.predicate, context, code, field .. ".kantoSelection.predicate")
  if kanto.appliesAfterCategorySelection ~= true then
    fail(code, field .. ".kantoSelection must preserve post-category override order", context)
  end
  SchemaCheck.checkRecord(kanto.routes, nil, context, code, field .. ".kantoSelection.routes")
  for _, route in pairs(kanto.routes) do
    checkString(route, context, code, field .. ".kantoSelection.routes")
  end
  local rules = introMusic.selectionRules
  SchemaCheck.checkRecord(rules, { trainer = true, wild = true }, context, code, field .. ".selectionRules")
  SchemaCheck.checkRecord(
    rules.trainer,
    { predicate = true, classSource = true, categorySource = true, modifiers = true },
    context,
    code,
    field .. ".selectionRules.trainer"
  )
  SchemaCheck.checkRecord(
    rules.wild,
    { predicate = true, speciesSource = true, specialSetupCase = true, modifier = true },
    context,
    code,
    field .. ".selectionRules.wild"
  )
  checkStringArray(rules.trainer.modifiers, context, code, field .. ".selectionRules.trainer.modifiers")
  for _, rule in ipairs({
    rules.trainer.predicate,
    rules.trainer.classSource,
    rules.trainer.categorySource,
    rules.wild.predicate,
    rules.wild.speciesSource,
    rules.wild.specialSetupCase,
    rules.wild.modifier,
  }) do
    checkString(rule, context, code, field .. ".selectionRules")
  end
  if introMusic.transitionFallbackIndependent ~= true then
    fail(code, field .. ".transitionFallbackIndependent must retain independent music selection", context)
  end
  local selection = introMusic.selectionSound
  SchemaCheck.checkRecord(
    selection,
    { key = true, eventInput = true, sequenceKey = true },
    context,
    code,
    field .. ".selectionSound"
  )
  checkString(selection.key, context, code, field .. ".selectionSound.key")
  checkString(selection.eventInput, context, code, field .. ".selectionSound.eventInput")
  checkSequenceKey(
    selection.sequenceKey,
    introMusic.sequenceClosures,
    context,
    code,
    field .. ".selectionSound.sequenceKey"
  )
end

local function checkIntroMusic(introMusic, context, code, field)
  SchemaCheck.checkRecord(introMusic, {
    inputs = true,
    inputTypes = true,
    routes = true,
    sourceRoutes = true,
    kantoOverrides = true,
    kantoSelection = true,
    selectionRules = true,
    transitionFallbackIndependent = true,
    selectionSound = true,
    sequenceClosures = true,
  }, context, code, field)
  checkStringArray(introMusic.inputs, context, code, field .. ".inputs")
  SchemaCheck.checkRecord(introMusic.inputTypes, nil, context, code, field .. ".inputTypes")
  local inputSet = {}
  for _, input in ipairs(introMusic.inputs) do
    inputSet[input] = true
    checkString(introMusic.inputTypes[input], context, code, field .. ".inputTypes." .. input)
  end
  for input in pairs(introMusic.inputTypes) do
    if inputSet[input] ~= true then
      fail(code, field .. ".inputTypes contains an undeclared input", context)
    end
  end
  local closures = introMusic.sequenceClosures
  local closureField = field .. ".sequenceClosures"
  SchemaCheck.checkRecord(closures, nil, context, code, closureField)
  for sequenceKey, closure in pairs(closures) do
    checkSequenceKey(sequenceKey, closures, context, code, closureField .. " key")
    checkSequenceClosure(closure, context, code, closureField .. "." .. sequenceKey)
  end
  checkIntroMusicRoutes(introMusic, inputSet, context, code, field)
  checkIntroMusicSelection(introMusic, context, code, field)
end

-- Semantic audio roles naming one selected sequence each.
local AUDIO_SEQUENCE_ROLES = {
  "wild",
  "trainer",
  "rival",
  "select",
  "gymLeader",
  "rocket",
  "suicune",
  "entei",
  "raikou",
  "champion",
  "kantoWild",
  "kantoTrainer",
  "kantoGymLeader",
}
local AUDIO_ROLE_FIELDS = valueSet(AUDIO_SEQUENCE_ROLES)
AUDIO_ROLE_FIELDS.cries = true
AUDIO_ROLE_FIELDS.introMusic = true

local function checkAudioRoles(roles, context, code, field)
  SchemaCheck.checkRecord(roles, AUDIO_ROLE_FIELDS, context, code, field)
  checkStringFields(roles, AUDIO_SEQUENCE_ROLES, context, code, field)
  checkString(roles.cries, context, code, field .. ".cries")
  checkIntroMusic(roles.introMusic, context, code, field .. ".introMusic")
end

local MENU_SECTIONS = { "command", "moves", "target", "twoOption" }
local HUD_DOUBLES_SLOTS = { "playerLeft", "playerRight", "enemyLeft", "enemyRight" }
local BUG_CONTEST_LAYOUT_KINDS = { character = "texture", palette = "palette", cell = "cell", animation = "animation" }

local function checkImageRef(images, path, context, field)
  if images[path] == nil then
    fail(CODE_MANIFEST, field .. " references an unstaged image: " .. tostring(path), context)
  end
end

-- A catalog section must be a nonempty record.
local function checkCatalogSections(owner, names, context, field)
  for _, name in ipairs(names) do
    checkCatalogTable(owner[name], context, CODE_MANIFEST, field .. name)
  end
end

local function checkManifestHeader(manifest, context)
  SchemaCheck.checkRecord(manifest, {
    schema = true,
    version = true,
    catalogIdentity = true,
    verified = true,
    scenes = true,
    layouts = true,
    battlefield = true,
    hud = true,
    pictures = true,
    trainerPictures = true,
    battleBalls = true,
    menus = true,
    messages = true,
    transitions = true,
    audioRoles = true,
    resources = true,
    coverage = true,
  }, context, CODE_MANIFEST, "manifest")
  if manifest.schema ~= BattlePresentationSchema.MANIFEST_SCHEMA then
    fail(CODE_MANIFEST, "manifest schema must be " .. BattlePresentationSchema.MANIFEST_SCHEMA, context)
  end
  SchemaCheck.checkRecord(manifest.version, { id = true, language = true }, context, CODE_MANIFEST, "manifest version")
  checkString(manifest.version.id, context, CODE_MANIFEST, "manifest version id")
  checkString(manifest.version.language, context, CODE_MANIFEST, "manifest version language")
  checkString(manifest.catalogIdentity, context, CODE_MANIFEST, "manifest catalogIdentity")
  checkSlotGeometry(manifest.battlefield, context, CODE_MANIFEST)
  if not Validate.isArray(manifest.scenes) or #manifest.scenes == 0 then
    fail(CODE_MANIFEST, "manifest must inventory its supported scene keys", context)
  end
  for index, entry in ipairs(manifest.scenes) do
    checkSceneEntry(entry, context, CODE_MANIFEST, "manifest scenes[" .. index .. "]")
  end
  -- Each section is required evidence, not an optional placeholder bucket.
  checkCatalogSections(manifest, { "layouts", "messages", "transitions" }, context, "manifest ")
  checkNoNativeKeys(manifest.layouts, context, CODE_MANIFEST, "manifest layouts")
end

local MENU_ROUTE_FIELDS = {
  screenGroup = true,
  textSet = true,
  mode = true,
  phase = true,
  messageEntries = true,
  messageRoutes = true,
  fontRoles = true,
  assetRoles = true,
  assetBindings = true,
  requiredContext = true,
  resources = true,
}
local MENU_ROUTE_LISTS =
  { "messageEntries", "messageRoutes", "fontRoles", "assetRoles", "requiredContext", "resources" }

-- The only dynamic menu asset: a species/form icon selected from a typed
-- source context.
local function checkMenuAssetBinding(route, role, binding, context, field)
  if not contains(route.assetRoles, role) then
    fail(CODE_MANIFEST, field .. ".assetBindings contains an undeclared asset role", context)
  end
  local bindingField = field .. ".assetBindings[" .. role .. "]"
  SchemaCheck.checkRecord(
    binding,
    { catalog = true, selector = true, context = true, when = true },
    context,
    CODE_MANIFEST,
    bindingField
  )
  if role ~= "pokemonIcon" or binding.catalog ~= "mon-icons" or binding.selector ~= "species-form" then
    fail(CODE_MANIFEST, field .. ".assetBindings contains an unsupported dynamic asset selector", context)
  end
  checkStringArray(binding.context, context, CODE_MANIFEST, bindingField .. ".context")
  if #binding.context ~= 2 then
    fail(CODE_MANIFEST, bindingField .. " must select by species and form", context)
  end
  checkString(binding.when, context, CODE_MANIFEST, bindingField .. ".when")
  if
    (binding.context[1] == "bugContest.caughtPokemon.species" and binding.when ~= "caught-mon-present")
    or (binding.context[1] == "targetSelection.candidate.species" and binding.when ~= "candidate-enabled-and-hit")
  then
    fail(CODE_MANIFEST, field .. ".assetBindings has a mismatched source context", context)
  end
end

local function checkMenuRouteReferences(route, manifest, context, field)
  local messages = manifest.messages
  for _, messageKey in ipairs(route.messageEntries) do
    if messages.entries[messageKey] == nil then
      fail(CODE_MANIFEST, field .. ".messageEntries references no staged message", context)
    end
  end
  for _, messageRoute in ipairs(route.messageRoutes) do
    if
      messages.routes[messageRoute] == nil
      and messages.sourceRoutes[messageRoute] == nil
      and messages.dynamicRoutes[messageRoute] == nil
    then
      fail(CODE_MANIFEST, field .. ".messageRoutes references no source route", context)
    end
  end
  for _, fontRole in ipairs(route.fontRoles) do
    if messages.roles[fontRole] == nil then
      fail(CODE_MANIFEST, field .. ".fontRoles references no staged font role", context)
    end
  end
  for _, contextKey in ipairs(route.requiredContext) do
    if manifest.menus.contexts[contextKey] == nil then
      fail(CODE_MANIFEST, field .. ".requiredContext references no typed context", context)
    end
  end
  for _, resourceKey in ipairs(route.resources) do
    if manifest.resources[resourceKey] == nil then
      fail(CODE_MANIFEST, field .. ".resources references no staged resource", context)
    end
  end
end

local function checkMenuRoutes(manifest, context)
  local menus = manifest.menus
  checkCatalogTable(menus.routes, context, CODE_MANIFEST, "manifest menus.routes")
  for routeKey, route in pairs(menus.routes) do
    local field = "manifest menus.routes[" .. routeKey .. "]"
    SchemaCheck.checkRecord(route, MENU_ROUTE_FIELDS, context, CODE_MANIFEST, field)
    for _, listName in ipairs(MENU_ROUTE_LISTS) do
      checkStringArray(route[listName], context, CODE_MANIFEST, field .. "." .. listName)
    end
    SchemaCheck.checkRecord(route.assetBindings, nil, context, CODE_MANIFEST, field .. ".assetBindings")
    for role, binding in pairs(route.assetBindings) do
      checkMenuAssetBinding(route, role, binding, context, field)
    end
    for _, role in ipairs(route.assetRoles) do
      if role == "pokemonIcon" and route.assetBindings[role] == nil then
        fail(CODE_MANIFEST, field .. ".assetRoles requires a semantic pokemonIcon binding", context)
      end
    end
    checkMenuRouteReferences(route, manifest, context, field)
  end
  for routeKey in pairs(menus.selectors) do
    if menus.routes[routeKey] == nil then
      fail(CODE_MANIFEST, "manifest menus.routes is missing selector route " .. routeKey, context)
    end
  end
end

local function checkLayoutResource(resources, resourceKey, kind, context, keyField, failure)
  checkString(resourceKey, context, CODE_MANIFEST, keyField)
  if resources[resourceKey] == nil or resources[resourceKey].kind ~= kind then
    fail(CODE_MANIFEST, failure, context)
  end
end

local function checkBugContestLayout(bugContest, resources, context)
  SchemaCheck.checkRecord(
    bugContest,
    { character = true, palette = true, cell = true, animation = true, sprites = true },
    context,
    CODE_MANIFEST,
    "manifest menus.layouts.bugContest"
  )
  for slot, kind in pairs(BUG_CONTEST_LAYOUT_KINDS) do
    checkLayoutResource(
      resources,
      bugContest[slot],
      kind,
      context,
      "manifest Bug Contest " .. slot .. " key",
      "manifest Bug Contest layout references no decoded " .. slot
    )
  end
  SchemaCheck.checkRecord(
    bugContest.sprites,
    { sportBall = true, bugNet = true },
    context,
    CODE_MANIFEST,
    "manifest Bug Contest sprites"
  )
  for _, role in ipairs({ "sportBall", "bugNet" }) do
    local sprite = bugContest.sprites[role]
    local field = "manifest Bug Contest " .. role
    SchemaCheck.checkRecord(
      sprite,
      { x = true, y = true, palette = true, animation = true },
      context,
      CODE_MANIFEST,
      field
    )
    checkInt(sprite.x, 0, 255, context, CODE_MANIFEST, field .. ".x")
    checkInt(sprite.y, 0, 191, context, CODE_MANIFEST, field .. ".y")
    checkInt(sprite.palette, 0, 15, context, CODE_MANIFEST, field .. ".palette")
    checkInt(sprite.animation, 0, nil, context, CODE_MANIFEST, field .. ".animation")
  end
end

local function checkMenuLayouts(layouts, resources, context)
  SchemaCheck.checkRecord(
    layouts,
    { frontier = true, vsRecorder = true, bugContest = true },
    context,
    CODE_MANIFEST,
    "manifest menus.layouts"
  )
  local frontier, vsRecorder = layouts.frontier, layouts.vsRecorder
  SchemaCheck.checkRecord(
    frontier,
    { image = true, character = true, palette = true, tilemap = true, touchPalette = true },
    context,
    CODE_MANIFEST,
    "manifest menus.layouts.frontier"
  )
  checkImagePath(frontier.image, context, CODE_MANIFEST, "manifest menus.layouts.frontier.image")
  SchemaCheck.checkRecord(
    vsRecorder,
    { image = true, tilemap = true },
    context,
    CODE_MANIFEST,
    "manifest menus.layouts.vsRecorder"
  )
  checkImagePath(vsRecorder.image, context, CODE_MANIFEST, "manifest menus.layouts.vsRecorder.image")
  for _, layout in ipairs({ frontier, vsRecorder }) do
    checkLayoutResource(
      resources,
      layout.tilemap,
      "map",
      context,
      "manifest menu layout tilemap key",
      "manifest menu layout references no source-decoded tilemap"
    )
  end
  for _, slot in ipairs({ "character", "palette" }) do
    checkLayoutResource(
      resources,
      frontier[slot],
      slot == "character" and "texture" or "palette",
      context,
      "manifest Frontier " .. slot .. " key",
      "manifest Frontier layout references no source-decoded " .. slot
    )
  end
  checkLayoutResource(
    resources,
    frontier.touchPalette,
    "palette",
    context,
    "manifest Frontier touch palette key",
    "manifest Frontier layout references no decoded touch palette"
  )
  checkBugContestLayout(layouts.bugContest, resources, context)
end

local function checkMenuImages(images, context)
  for path, geometry in pairs(images) do
    checkString(path, context, CODE_MANIFEST, "manifest menus image path")
    local field = "manifest menus image " .. path
    SchemaCheck.checkRecord(geometry, { width = true, height = true }, context, CODE_MANIFEST, field)
    checkInt(geometry.width, 1, nil, context, CODE_MANIFEST, field .. " width")
    checkInt(geometry.height, 1, nil, context, CODE_MANIFEST, field .. " height")
  end
end

local function checkMenuSelectionRules(manifest, context)
  local menus, messages = manifest.menus, manifest.messages
  checkMenuModeRules(menus.modeRules, messages.entries, context, CODE_MANIFEST, "manifest menus.modeRules")
  checkMenuRuntimeContexts(menus.runtimeContexts, context, CODE_MANIFEST, "manifest menus.runtimeContexts")
  checkMenuContexts(
    menus.contexts,
    messages.entries,
    messages.routes,
    context,
    CODE_MANIFEST,
    "manifest menus.contexts"
  )
  SchemaCheck.checkRecord(
    menus.runLabelSelector,
    { cancel = true, ordinary = true },
    context,
    CODE_MANIFEST,
    "manifest menus.runLabelSelector"
  )
  for _, key in pairs(menus.runLabelSelector) do
    checkString(key, context, CODE_MANIFEST, "manifest menus.runLabelSelector key")
    if messages.entries[key] == nil then
      fail(CODE_MANIFEST, "manifest menus.runLabelSelector references no message record", context)
    end
  end
end

local function checkLowerMenu(lower, images, context)
  SchemaCheck.checkRecord(
    lower,
    { image = true, palette = true, variants = true, pulseMask = true },
    context,
    CODE_MANIFEST,
    "manifest menus.lower"
  )
  checkImagePath(lower.image, context, CODE_MANIFEST, "manifest menus.lower image")
  checkImageRef(images, lower.image, context, "manifest menus.lower image")
  checkImagePath(lower.pulseMask, context, CODE_MANIFEST, "manifest menus.lower pulseMask")
  checkImageRef(images, lower.pulseMask, context, "manifest menus.lower pulseMask")
  checkPalette(lower.palette, context, CODE_MANIFEST, "manifest menus.lower palette")
  SchemaCheck.checkRecord(lower.variants, nil, context, CODE_MANIFEST, "manifest menus.lower variants")
  for background, variant in pairs(lower.variants) do
    if BACKGROUNDS[background] == nil then
      fail(
        CODE_MANIFEST,
        "manifest menus.lower variant carries an unknown background: " .. tostring(background),
        context
      )
    end
    local entry = "manifest menus.lower variants " .. tostring(background)
    SchemaCheck.checkRecord(variant, { base = true, touch = true }, context, CODE_MANIFEST, entry)
    checkPalette(variant.base, context, CODE_MANIFEST, entry .. " base")
    checkPalette(variant.touch, context, CODE_MANIFEST, entry .. " touch")
  end
  if next(lower.variants) == nil then
    fail(CODE_MANIFEST, "manifest menus.lower must carry its background variants", context)
  end
end

local function checkMenus(manifest, context)
  local menus = manifest.menus
  SchemaCheck.checkRecord(menus, {
    images = true,
    layouts = true,
    routes = true,
    command = true,
    moves = true,
    target = true,
    twoOption = true,
    lower = true,
    roles = true,
    selectors = true,
    modeRules = true,
    runLabelSelector = true,
    runtimeContexts = true,
    contexts = true,
  }, context, CODE_MANIFEST, "manifest menus")
  checkMenuRoutes(manifest, context)
  SchemaCheck.checkRecord(menus.images, nil, context, CODE_MANIFEST, "manifest menus.images")
  if next(menus.images) == nil then
    fail(CODE_MANIFEST, "manifest menus.images must inventory staged image payloads", context)
  end
  checkMenuLayouts(menus.layouts, manifest.resources, context)
  checkCatalogSections(menus, { "roles", "selectors" }, context, "manifest menus.")
  checkMenuSelectionRules(manifest, context)
  checkMenuImages(menus.images, context)
  checkImageRef(menus.images, menus.layouts.frontier.image, context, "manifest menu layout image")
  checkImageRef(menus.images, menus.layouts.vsRecorder.image, context, "manifest menu layout image")
  for _, name in ipairs(MENU_SECTIONS) do
    checkMenuSection(menus[name], context, CODE_MANIFEST, "manifest menus." .. name)
  end
  checkLowerMenu(menus.lower, menus.images, context)
end

local function checkHealthBox(section, context, field)
  checkSpriteSection(section, context, CODE_MANIFEST, field)
  if section.componentBase == nil or section.componentCount ~= 78 then
    fail(CODE_MANIFEST, field .. " must append the 78 source health-box components", context)
  end
end

local function checkHud(manifest, context)
  local hud = manifest.hud
  SchemaCheck.checkRecord(hud, {
    player = true,
    enemy = true,
    doubles = true,
    arrow = true,
    cursor = true,
    partyGauges = true,
    terrain = true,
    roles = true,
    selectors = true,
    patchSpans = true,
  }, context, CODE_MANIFEST, "manifest hud")
  checkHudPatchSpans(hud.patchSpans, context, CODE_MANIFEST, "manifest hud.patchSpans")
  checkHealthBox(hud.player, context, "manifest hud.player")
  checkHealthBox(hud.enemy, context, "manifest hud.enemy")
  SchemaCheck.checkRecord(
    hud.doubles,
    { playerLeft = true, playerRight = true, enemyLeft = true, enemyRight = true },
    context,
    CODE_MANIFEST,
    "manifest hud.doubles"
  )
  for _, slot in ipairs(HUD_DOUBLES_SLOTS) do
    checkHealthBox(hud.doubles[slot], context, "manifest hud.doubles " .. slot)
  end
  checkSpriteSection(hud.arrow, context, CODE_MANIFEST, "manifest hud.arrow")
  checkSpriteSection(hud.cursor, context, CODE_MANIFEST, "manifest hud.cursor")
  if #hud.cursor.animations < 4 then
    fail(CODE_MANIFEST, "manifest hud.cursor carries four corner animations", context)
  end
  checkCatalogSections(hud, { "roles", "selectors" }, context, "manifest hud.")
  if not Validate.isArray(hud.partyGauges) or #hud.partyGauges ~= 2 then
    fail(CODE_MANIFEST, "manifest must carry both party gauge families", context)
  end
  for index, family in ipairs(hud.partyGauges) do
    checkSpriteSection(family, context, CODE_MANIFEST, "manifest hud.partyGauges[" .. index .. "]")
  end
  -- Terrain bake inputs are producer metadata, not staged sprites: the
  -- shared per-type cells and animation without an image or palette.
  SchemaCheck.checkRecord(hud.terrain, { type0 = true, type1 = true }, context, CODE_MANIFEST, "manifest hud.terrain")
  checkTerrainSection(hud.terrain.type0, context, CODE_MANIFEST, "manifest hud.terrain type0")
  checkTerrainSection(hud.terrain.type1, context, CODE_MANIFEST, "manifest hud.terrain type1")
end

-- Menu screens and HUD sprites draw only images staged in the menu image
-- inventory.
local function checkScreenImageRefs(manifest, context)
  local images, menus, hud = manifest.menus.images, manifest.menus, manifest.hud
  for _, name in ipairs(MENU_SECTIONS) do
    local section = menus[name]
    checkImageRef(images, section.image, context, "manifest menus." .. name .. " image")
    for index, screen in ipairs(section.screens) do
      checkImageRef(images, screen.image, context, "manifest menus." .. name .. " screen " .. index)
    end
  end
  for _, name in ipairs({ "player", "enemy", "arrow", "cursor" }) do
    checkImageRef(images, hud[name].image, context, "manifest hud." .. name .. " image")
  end
  for _, slot in ipairs(HUD_DOUBLES_SLOTS) do
    checkImageRef(images, hud.doubles[slot].image, context, "manifest hud.doubles " .. slot .. " image")
  end
  for index, family in ipairs(hud.partyGauges) do
    checkImageRef(images, family.image, context, "manifest hud.partyGauges[" .. index .. "] image")
  end
end

local function checkPictureShadow(shadow, images, context)
  SchemaCheck.checkRecord(
    shadow,
    { image = true, width = true, height = true, regions = true },
    context,
    CODE_MANIFEST,
    "manifest pictures.shadow"
  )
  checkImageRef(images, shadow.image, context, "manifest pictures.shadow image")
  local shadowImage = images[shadow.image]
  if shadow.width ~= 64 or shadow.height ~= 64 then
    fail(CODE_MANIFEST, "manifest pictures.shadow must preserve the native 64x64 selector atlas", context)
  end
  if shadowImage.width ~= shadow.width or shadowImage.height ~= shadow.height then
    fail(CODE_MANIFEST, "manifest pictures.shadow geometry must match its staged image", context)
  end
  if not Validate.isArray(shadow.regions) or #shadow.regions ~= 4 then
    fail(CODE_MANIFEST, "manifest pictures.shadow.regions must contain four source size selections", context)
  end
  local shadowSizes = {}
  for index, region in ipairs(shadow.regions) do
    local field = "manifest pictures.shadow.regions[" .. index .. "]"
    SchemaCheck.checkRecord(
      region,
      { size = true, x = true, y = true, width = true, height = true },
      context,
      CODE_MANIFEST,
      field
    )
    checkInt(region.size, 0, 3, context, CODE_MANIFEST, field .. ".size")
    checkInt(region.x, 0, 63, context, CODE_MANIFEST, field .. ".x")
    checkInt(region.y, 0, 63, context, CODE_MANIFEST, field .. ".y")
    checkInt(region.width, 1, 64, context, CODE_MANIFEST, field .. ".width")
    checkInt(region.height, 1, 64, context, CODE_MANIFEST, field .. ".height")
    if region.x + region.width > 64 or region.y + region.height > 64 then
      fail(CODE_MANIFEST, field .. " escapes the staged shadow atlas", context)
    end
    if region.width ~= 64 or region.height ~= 16 then
      fail(CODE_MANIFEST, field .. " must retain the 64x16 native shadow geometry", context)
    end
    if shadowSizes[region.size] then
      fail(CODE_MANIFEST, "manifest pictures.shadow repeats a native size selector", context)
    end
    shadowSizes[region.size] = true
  end
  for size = 0, 3 do
    if not shadowSizes[size] then
      fail(CODE_MANIFEST, "manifest pictures.shadow omits native size " .. size, context)
    end
  end
end

local function checkPictures(manifest, context)
  local pictures = manifest.pictures
  SchemaCheck.checkRecord(
    pictures,
    { attributes = true, selectors = true, shadow = true },
    context,
    CODE_MANIFEST,
    "manifest pictures"
  )
  checkPictureAttributes(pictures.attributes, context, CODE_MANIFEST, "manifest pictures.attributes")
  checkCatalogTable(pictures.selectors, context, CODE_MANIFEST, "manifest pictures.selectors")
  checkPictureShadow(pictures.shadow, manifest.menus.images, context)
end

local function checkTrainerPictures(manifest, context)
  local section = manifest.trainerPictures
  SchemaCheck.checkRecord(section, { entries = true }, context, CODE_MANIFEST, "manifest trainerPictures")
  SchemaCheck.checkRecord(section.entries, nil, context, CODE_MANIFEST, "manifest trainerPictures.entries")
  if next(section.entries) == nil then
    fail(CODE_MANIFEST, "manifest trainerPictures.entries must inventory source trainer art", context)
  end
  for selector, record in pairs(section.entries) do
    local validFront = type(selector) == "string" and selector:match("^front:[A-Z][A-Z0-9_]*$") ~= nil
    local validBack = selector == "back:PKMN_TRAINER_ETHAN" or selector == "back:PKMN_TRAINER_LYRA"
    if not validFront and not validBack then
      fail(CODE_MANIFEST, "manifest trainer picture selector is not semantic", context)
    end
    local field = "manifest trainerPictures.entries[" .. selector .. "]"
    SchemaCheck.checkRecord(
      record,
      { drawableKey = true, image = true, width = true, height = true, rasterOffset = true },
      context,
      CODE_MANIFEST,
      field
    )
    if record.drawableKey ~= "trainer:" .. selector then
      fail(CODE_MANIFEST, field .. ".drawableKey must match its role selector", context)
    end
    checkImagePath(record.image, context, CODE_MANIFEST, field .. ".image")
    checkInt(record.width, 1, 128, context, CODE_MANIFEST, field .. ".width")
    checkInt(record.height, 1, 128, context, CODE_MANIFEST, field .. ".height")
    SchemaCheck.checkRecord(
      record.rasterOffset,
      { x = true, y = true },
      context,
      CODE_MANIFEST,
      field .. ".rasterOffset"
    )
    checkInt(record.rasterOffset.x, -128, 127, context, CODE_MANIFEST, field .. ".rasterOffset.x")
    checkInt(record.rasterOffset.y, -128, 127, context, CODE_MANIFEST, field .. ".rasterOffset.y")
    checkImageRef(manifest.menus.images, record.image, context, field .. ".image")
  end
end

local function checkBattleBalls(manifest, context)
  local section = manifest.battleBalls
  SchemaCheck.checkRecord(section, { entries = true }, context, CODE_MANIFEST, "manifest battleBalls")
  SchemaCheck.checkRecord(section.entries, nil, context, CODE_MANIFEST, "manifest battleBalls.entries")
  if next(section.entries) == nil then
    fail(CODE_MANIFEST, "manifest battleBalls.entries must inventory source ball art", context)
  end
  for selector, record in pairs(section.entries) do
    if type(selector) ~= "string" or selector:match("^ball:[A-Z][A-Z0-9_]*$") == nil then
      fail(CODE_MANIFEST, "manifest battle ball selector is not semantic", context)
    end
    local field = "manifest battleBalls.entries[" .. selector .. "]"
    SchemaCheck.checkRecord(record, { frames = true, fadeColor = true }, context, CODE_MANIFEST, field)
    checkInt(record.fadeColor, 0, 0x7FFF, context, CODE_MANIFEST, field .. ".fadeColor")
    if not Validate.isArray(record.frames) or #record.frames == 0 then
      fail(CODE_MANIFEST, field .. ".frames must carry ordered animation frames", context)
    end
    for frameIndex, frame in ipairs(record.frames) do
      local frameField = field .. ".frames[" .. frameIndex .. "]"
      SchemaCheck.checkRecord(
        frame,
        { drawableKey = true, image = true, width = true, height = true },
        context,
        CODE_MANIFEST,
        frameField
      )
      local itemKey = selector:sub(6)
      if frame.drawableKey ~= "battle-ball:" .. itemKey .. ":" .. (frameIndex - 1) then
        fail(CODE_MANIFEST, frameField .. ".drawableKey must match its ordered animation frame", context)
      end
      checkImagePath(frame.image, context, CODE_MANIFEST, frameField .. ".image")
      checkInt(frame.width, 1, 128, context, CODE_MANIFEST, frameField .. ".width")
      checkInt(frame.height, 1, 128, context, CODE_MANIFEST, frameField .. ".height")
      checkImageRef(manifest.menus.images, frame.image, context, frameField .. ".image")
    end
  end
end

local function checkTagSchemas(tagSchemas, context)
  checkCatalogTable(tagSchemas, context, CODE_MANIFEST, "manifest messages.tagSchemas")
  for tag, slots in pairs(tagSchemas) do
    checkString(tag, context, CODE_MANIFEST, "manifest messages.tagSchemas key")
    if tag:match("^TAG_") or not Validate.isArray(slots) then
      fail(CODE_MANIFEST, "manifest messages.tagSchemas must use normalized semantic tags and ordered slots", context)
    end
    for index, slot in ipairs(slots) do
      checkString(slot, context, CODE_MANIFEST, "manifest messages.tagSchemas[" .. tag .. "][" .. index .. "]")
    end
  end
end

local function checkTagInputs(tagInputs, context)
  checkCatalogTable(tagInputs, context, CODE_MANIFEST, "manifest messages.tagInputs")
  for role, input in pairs(tagInputs) do
    local field = "manifest messages.tagInputs." .. role
    SchemaCheck.checkRecord(input, { input = true, output = true, selection = true }, context, CODE_MANIFEST, field)
    checkString(role, context, CODE_MANIFEST, "manifest messages.tagInputs role")
    checkString(input.input, context, CODE_MANIFEST, field .. ".input")
    checkString(input.output, context, CODE_MANIFEST, field .. ".output")
    if input.selection ~= nil then
      if not Validate.isArray(input.selection) then
        fail(CODE_MANIFEST, "manifest messages.tagInputs selection must be ordered", context)
      end
      for index, selected in ipairs(input.selection) do
        checkString(selected, context, CODE_MANIFEST, field .. ".selection[" .. index .. "]")
      end
    end
  end
end

local function checkTemplateInputs(templateInputs, context)
  checkCatalogTable(templateInputs, context, CODE_MANIFEST, "manifest messages.templateInputs")
  for role, input in pairs(templateInputs) do
    local field = "manifest messages.templateInputs." .. role
    SchemaCheck.checkRecord(
      input,
      { input = true, dependency = true, supported = true, reason = true },
      context,
      CODE_MANIFEST,
      field
    )
    checkString(role, context, CODE_MANIFEST, "manifest messages.templateInputs role")
    if input.supported == false then
      if input.input ~= nil or input.dependency ~= nil then
        fail(CODE_MANIFEST, "unsupported template input cannot declare runtime inputs or dependencies", context)
      end
      if type(input.reason) ~= "string" or input.reason == "" then
        fail(CODE_MANIFEST, "unsupported template input requires a source reason", context)
      end
    else
      checkString(input.input, context, CODE_MANIFEST, field .. ".input")
    end
    if input.dependency ~= nil then
      checkString(input.dependency, context, CODE_MANIFEST, field .. ".dependency")
    end
    if input.supported ~= nil and type(input.supported) ~= "boolean" then
      fail(CODE_MANIFEST, "manifest messages.templateInputs supported flag must be boolean", context)
    end
    if input.reason ~= nil then
      checkString(input.reason, context, CODE_MANIFEST, field .. ".reason")
    end
  end
end

local function checkMessages(manifest, context)
  local messages, resources = manifest.messages, manifest.resources
  SchemaCheck.checkRecord(messages, {
    roles = true,
    entries = true,
    routes = true,
    banks = true,
    dynamicRoutes = true,
    placeholderBanks = true,
    sourceRoutes = true,
    placeholders = true,
    tagSchemas = true,
    tagInputs = true,
    templateInputs = true,
    templateExpansion = true,
  }, context, CODE_MANIFEST, "manifest messages")
  checkTextRoles(messages.roles, context, CODE_MANIFEST, "manifest messages.roles")
  checkCatalogTable(messages.entries, context, CODE_MANIFEST, "manifest messages.entries")
  checkMessageRoutes(messages.routes, messages.entries, context, CODE_MANIFEST, "manifest messages.routes")
  checkMessageBankReferences(messages.banks, resources, context, CODE_MANIFEST, "manifest messages.banks")
  checkMessageDynamicRoutes(messages, resources, context, CODE_MANIFEST, "manifest messages.dynamicRoutes")
  checkMessageBankReferences(
    messages.placeholderBanks,
    resources,
    context,
    CODE_MANIFEST,
    "manifest messages.placeholderBanks"
  )
  checkMessageSourceRoutes(messages, resources, context, CODE_MANIFEST, "manifest messages.sourceRoutes")
  checkMessagePlaceholders(
    messages.placeholders,
    messages.placeholderBanks,
    context,
    CODE_MANIFEST,
    "manifest messages.placeholders"
  )
  checkTagSchemas(messages.tagSchemas, context)
  checkTagInputs(messages.tagInputs, context)
  checkTemplateInputs(messages.templateInputs, context)
  SchemaCheck.checkRecord(
    messages.templateExpansion,
    { input = true },
    context,
    CODE_MANIFEST,
    "manifest messages.templateExpansion"
  )
  checkString(messages.templateExpansion.input, context, CODE_MANIFEST, "manifest messages.templateExpansion.input")
end

local function checkSetupFallbackSelector(fallback, context)
  SchemaCheck.checkRecord(
    fallback,
    { inputs = true, terrainOffset = true, offsetTimes = true, trainerOffset = true, resolved = true },
    context,
    CODE_MANIFEST,
    "manifest transitions.selectors.setupFallback"
  )
  if not isExactList(fallback.inputs, { "battleType", "terrain", "timeOfDay" }) then
    fail(CODE_MANIFEST, "setup fallback must retain battle type, terrain, and time context", context)
  end
  SchemaCheck.checkRecord(
    fallback.terrainOffset,
    { cave = true, water = true },
    context,
    CODE_MANIFEST,
    "setup fallback terrain offsets"
  )
  checkInt(fallback.terrainOffset.cave, 4, 4, context, CODE_MANIFEST, "setup fallback cave offset")
  checkInt(fallback.terrainOffset.water, 2, 2, context, CODE_MANIFEST, "setup fallback water offset")
  if not isExactList(fallback.offsetTimes, { "night", "late" }) then
    fail(CODE_MANIFEST, "setup fallback must preserve its night and late offsets", context)
  end
  checkInt(fallback.trainerOffset, 6, 6, context, CODE_MANIFEST, "setup fallback trainer offset")
  if fallback.resolved ~= false then
    fail(CODE_MANIFEST, "setup fallback stays unresolved until selector routes are closed", context)
  end
end

local function checkTransitions(manifest, context)
  local transitions, messages, resources = manifest.transitions, manifest.messages, manifest.resources
  SchemaCheck.checkRecord(transitions, {
    selectors = true,
    resourceSets = true,
    resources = true,
    messageRoutes = true,
    internalResources = true,
    routes = true,
    selection = true,
  }, context, CODE_MANIFEST, "manifest transitions")
  checkCatalogTable(transitions.selectors, context, CODE_MANIFEST, "manifest transitions.selectors")
  checkTransitionRouteResources(
    transitions.messageRoutes,
    messages.entries,
    resources,
    context,
    CODE_MANIFEST,
    "manifest transitions.messageRoutes"
  )
  checkTransitionRoutes(
    transitions.routes,
    messages.entries,
    messages.routes,
    resources,
    context,
    CODE_MANIFEST,
    "manifest transitions.routes"
  )
  checkTransitionSelection(
    transitions.selection,
    transitions.routes,
    context,
    CODE_MANIFEST,
    "manifest transitions.selection"
  )
  checkTransitionInternalResources(
    transitions.internalResources,
    resources,
    context,
    CODE_MANIFEST,
    "manifest transitions.internalResources"
  )
  if transitions.selectors.setupFallback ~= nil then
    checkSetupFallbackSelector(transitions.selectors.setupFallback, context)
  end
end

-- Resolved after the resource catalog validates: each menu screen's
-- tilemap key names a decoded BG map.
local function checkMenuTilemapResources(manifest, context)
  for _, name in ipairs(MENU_SECTIONS) do
    for index, screen in ipairs(manifest.menus[name].screens) do
      local resource = manifest.resources[screen.tilemapKey]
      if resource == nil or resource.kind ~= "map" or resource.format ~= "nitro-bg-map-v1" then
        fail(
          CODE_MANIFEST,
          "manifest menus." .. name .. ".screens[" .. index .. "] references no decoded tilemap resource",
          context
        )
      end
    end
  end
end

-- The staged global manifest: source-normalized catalogs grouped by the
-- runtime owner that consumes each role. Physical IDs stay producer-only.
-- Sections validate in dependency order; cross-section references resolve
-- against catalogs that earlier sections have already proven.
function BattlePresentationSchema.assertManifest(manifest)
  local context = {}
  checkManifestHeader(manifest, context)
  checkMenus(manifest, context)
  checkHud(manifest, context)
  checkScreenImageRefs(manifest, context)
  checkPictures(manifest, context)
  checkTrainerPictures(manifest, context)
  checkBattleBalls(manifest, context)
  checkMessages(manifest, context)
  checkTransitions(manifest, context)
  checkAudioRoles(manifest.audioRoles, context, CODE_MANIFEST, "manifest audioRoles")
  checkCatalogResources(manifest.resources, context, CODE_MANIFEST, "manifest resources")
  checkMenuTilemapResources(manifest, context)
  checkCoverage(manifest, context, CODE_MANIFEST, "manifest coverage")
  checkNoNativeKeys(manifest, context, CODE_MANIFEST, "manifest")
  return true
end

function BattlePresentationSchema.isValidManifest(manifest)
  return pcall(BattlePresentationSchema.assertManifest, manifest)
end

-- One composed scene record: its semantic context, native source layers,
-- canvas and viewport geometry, and staged image reference. The key must
-- agree with its axes; effect backgrounds are never admitted.
function BattlePresentationSchema.assertScene(scene)
  local context = {}
  SchemaCheck.checkRecord(scene, {
    schema = true,
    key = true,
    background = true,
    terrain = true,
    time = true,
    canvasWidth = true,
    canvasHeight = true,
    viewport = true,
    layers = true,
    imagePath = true,
    introLayer = true,
    terrainSprites = true,
  }, context, CODE_SCENE, "scene")
  if scene.schema ~= BattlePresentationSchema.SCENE_SCHEMA then
    fail(CODE_SCENE, "scene schema must be " .. BattlePresentationSchema.SCENE_SCHEMA, context)
  end
  checkString(scene.key, context, CODE_SCENE, "scene key")
  checkSceneAxes(scene, context, CODE_SCENE, "scene")
  checkInt(scene.canvasWidth, 1, nil, context, CODE_SCENE, "scene canvasWidth")
  checkInt(scene.canvasHeight, 1, nil, context, CODE_SCENE, "scene canvasHeight")
  if scene.canvasWidth ~= 512 or scene.canvasHeight ~= 256 then
    fail(CODE_SCENE, "scene canvas must preserve the native 512x256 BG3 backing", context)
  end
  SchemaCheck.checkRecord(
    scene.viewport,
    { x = true, y = true, width = true, height = true },
    context,
    CODE_SCENE,
    "scene viewport"
  )
  checkInt(scene.viewport.x, 0, nil, context, CODE_SCENE, "scene viewport x")
  checkInt(scene.viewport.y, 0, nil, context, CODE_SCENE, "scene viewport y")
  checkInt(scene.viewport.width, 1, nil, context, CODE_SCENE, "scene viewport width")
  checkInt(scene.viewport.height, 1, nil, context, CODE_SCENE, "scene viewport height")
  if scene.viewport.x + scene.viewport.width > scene.canvasWidth then
    fail(CODE_SCENE, "scene viewport escapes its canvas width", context)
  end
  if scene.viewport.y + scene.viewport.height > scene.canvasHeight then
    fail(CODE_SCENE, "scene viewport escapes its canvas height", context)
  end
  if scene.viewport.x ~= 0 or scene.viewport.y ~= 0 or scene.viewport.width ~= 256 or scene.viewport.height ~= 192 then
    fail(CODE_SCENE, "scene viewport must preserve the native 256x192 origin view", context)
  end
  if not Validate.isArray(scene.layers) or #scene.layers ~= 1 then
    fail(CODE_SCENE, "scene must carry its single native battle background layer", context)
  end
  local layerKeys = {}
  for index, layer in ipairs(scene.layers) do
    local field = "scene layers[" .. index .. "]"
    checkSceneLayer(layer, context, field)
    if
      layer.viewport.x ~= scene.viewport.x
      or layer.viewport.y ~= scene.viewport.y
      or layer.viewport.width ~= scene.viewport.width
      or layer.viewport.height ~= scene.viewport.height
    then
      fail(CODE_SCENE, field .. " viewport disagrees with the scene viewport", context)
    end
    if layerKeys[layer.key] then
      fail(CODE_SCENE, "scene layers carry duplicate key " .. layer.key, context)
    end
    layerKeys[layer.key] = true
  end
  checkImagePath(scene.imagePath, context, CODE_SCENE, "scene imagePath")
  checkIntroLayer(scene.introLayer, context)
  checkTerrainSprites(scene.terrainSprites, context)
  checkNoNativeKeys(scene, context, CODE_SCENE, "scene")
  return true
end

function BattlePresentationSchema.isValidScene(scene)
  return pcall(BattlePresentationSchema.assertScene, scene)
end

local function checkStringList(values, context, code, field, allowEmpty)
  if not Validate.isArray(values) or (#values == 0 and not allowEmpty) then
    fail(code, field .. " must carry its members", context)
  end
  local seen = {}
  for _, value in ipairs(values) do
    checkString(value, context, code, field)
    if seen[value] then
      fail(code, field .. " carries a duplicate member " .. value, context)
    end
    seen[value] = true
  end
end

-- One exact launch demand: a single scene, deduplicated portrait page
-- selectors, and the audio roles/banks/cries the launch reaches. Empty and
-- duplicated demands never validate.
function BattlePresentationSchema.assertDemand(demand)
  local context = {}
  SchemaCheck.checkRecord(
    demand,
    { scenes = true, pages = true, audio = true, trainerPictures = true, battleBalls = true, iconKeys = true },
    context,
    CODE_DEMAND,
    "demand"
  )
  checkStringList(demand.scenes, context, CODE_DEMAND, "demand scenes", false)
  for _, key in ipairs(demand.scenes) do
    local background, terrain, time = key:match("^([^/]+)/([^/]+)/([^/]+)$")
    if background == nil or BACKGROUNDS[background] == nil or TERRAINS[terrain] == nil or TIMES[time] == nil then
      fail(CODE_DEMAND, "demand carries an unknown scene key: " .. key, context)
    end
  end
  checkStringList(demand.pages, context, CODE_DEMAND, "demand pages", true)
  checkStringList(demand.trainerPictures, context, CODE_DEMAND, "demand trainerPictures", true)
  for _, selector in ipairs(demand.trainerPictures) do
    local validFront = selector:match("^front:[A-Z][A-Z0-9_]*$") ~= nil
    local validBack = selector == "back:PKMN_TRAINER_ETHAN" or selector == "back:PKMN_TRAINER_LYRA"
    if not validFront and not validBack then
      fail(CODE_DEMAND, "demand trainer picture selector is not semantic: " .. selector, context)
    end
  end
  checkStringList(demand.battleBalls, context, CODE_DEMAND, "demand battleBalls", true)
  for _, selector in ipairs(demand.battleBalls) do
    if selector:match("^ball:[A-Z][A-Z0-9_]*$") == nil then
      fail(CODE_DEMAND, "demand battle ball selector is not semantic", context)
    end
  end
  checkStringList(demand.iconKeys, context, CODE_DEMAND, "demand iconKeys", true)
  SchemaCheck.checkRecord(
    demand.audio,
    { roles = true, banks = true, cries = true },
    context,
    CODE_DEMAND,
    "demand audio"
  )
  checkStringList(demand.audio.roles, context, CODE_DEMAND, "demand audio roles", true)
  if not Validate.isArray(demand.audio.banks) then
    fail(CODE_DEMAND, "demand audio banks must be an array", context)
  end
  for _, bank in ipairs(demand.audio.banks) do
    checkInt(bank, 0, nil, context, CODE_DEMAND, "demand audio bank")
  end
  checkStringList(demand.audio.cries, context, CODE_DEMAND, "demand audio cries", true)
  return true
end

function BattlePresentationSchema.isValidDemand(demand)
  return pcall(BattlePresentationSchema.assertDemand, demand)
end

return BattlePresentationSchema
