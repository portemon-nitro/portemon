-- Authoritative validation for the generated battle presentation class:
-- the staged global manifest, one composed scene record, and exact launch
-- demands. Runtime-facing records use semantic keys only: physical archive
-- and member identities are rejected at any depth. Love-free and
-- filesystem-free.

local SchemaCheck = require("libs.assets.src.SchemaCheck")
local Validate = require("libs.assets.src.Validate")

---@class BattlePresentationSchema
local BattlePresentationSchema = {}

BattlePresentationSchema.MANIFEST_SCHEMA = "g4-battle-presentation-v4"
BattlePresentationSchema.SCENE_SCHEMA = "g4-battle-scene-v2"

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

-- Producer identities never reach runtime records at any depth.
local function checkNoNativeKeys(value, context, code, field)
  if type(value) ~= "table" then
    return
  end
  for key, nested in pairs(value) do
    local text = tostring(key)
    if
      text == "memberId"
      or text == "fileId"
      or text == "narcId"
      or text == "armAddress"
      or text == "callbackAddress"
      or text == "opcodeIndex"
      or text == "nativeOpcode"
    then
      fail(code, field .. " leaks source detail '" .. text .. "'", context)
    end
    checkNoNativeKeys(nested, context, code, field .. "." .. text)
  end
end

local RESOURCE_KINDS = {
  sound = true,
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
}

local function checkCatalogTable(value, context, code, field)
  if type(value) ~= "table" then
    fail(code, field .. " must be a record", context)
  end
  if next(value) == nil then
    fail(code, field .. " must carry source-backed entries", context)
  end
end

local function checkPrograms(programs, resources, context, code, field)
  checkCatalogTable(programs, context, code, field)
  for key, entry in pairs(programs) do
    checkString(key, context, code, field .. " key")
    local record = field .. "[" .. tostring(key) .. "]"
    SchemaCheck.checkRecord(
      entry,
      { entry = true, taskKinds = true, dependencies = true, requiredContext = true },
      context,
      code,
      record
    )
    checkString(entry.entry, context, code, record .. ".entry")
    if not Validate.isArray(entry.taskKinds) then
      fail(code, record .. " must carry its task kinds in order", context)
    end
    for index, kind in ipairs(entry.taskKinds) do
      checkString(kind, context, code, record .. ".taskKinds[" .. index .. "]")
    end
    if not Validate.isArray(entry.dependencies) then
      fail(code, record .. ".dependencies must list the complete resource closure", context)
    end
    local seen = {}
    for index, dependency in ipairs(entry.dependencies) do
      checkString(dependency, context, code, record .. ".dependencies[" .. index .. "]")
      if resources[dependency] == nil or seen[dependency] then
        fail(code, record .. ".dependencies contains an unstaged or repeated resource", context)
      end
      seen[dependency] = true
    end
    if type(entry.requiredContext) ~= "table" then
      fail(code, record .. ".requiredContext must declare typed runtime inputs", context)
    end
    for contextKey, descriptor in pairs(entry.requiredContext) do
      checkString(contextKey, context, code, record .. ".requiredContext key")
      if type(descriptor) ~= "table" or type(descriptor.type) ~= "string" or descriptor.type == "" then
        fail(code, record .. ".requiredContext entries must carry semantic types", context)
      end
    end
  end
end

local function checkCatalogResources(resources, context, code, field)
  checkCatalogTable(resources, context, code, field)
  for key, descriptor in pairs(resources) do
    checkString(key, context, code, field .. " key")
    local record = field .. "[" .. tostring(key) .. "]"
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
    if
      type(descriptor.contentIdentity) ~= "string"
      or not descriptor.contentIdentity:match(
        "^%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x$"
      )
    then
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
      SchemaCheck.checkRecord(
        descriptor.geometry,
        { emitterCount = true, resourceCount = true },
        context,
        code,
        record .. ".geometry"
      )
      checkInt(descriptor.geometry.emitterCount, 0, nil, context, code, record .. ".geometry.emitterCount")
      checkInt(descriptor.geometry.resourceCount, 0, nil, context, code, record .. ".geometry.resourceCount")
    elseif descriptor.format == "nitro-spl-texture-data-v1" or descriptor.format == "nitro-spl-palette-data-v1" then
      local expectedKind = descriptor.format == "nitro-spl-texture-data-v1" and "texture" or "palette"
      if descriptor.kind ~= expectedKind then
        fail(code, record .. " APS embedded payload has the wrong resource kind", context)
      end
      SchemaCheck.checkRecord(descriptor.geometry, { byteCount = true }, context, code, record .. ".geometry")
      checkInt(descriptor.geometry.byteCount, 1, nil, context, code, record .. ".geometry.byteCount")
    elseif descriptor.format == "hgss-message-bank-tokens-v1" then
      if descriptor.kind ~= "message" then
        fail(code, record .. " message bank has the wrong resource kind", context)
      end
      SchemaCheck.checkRecord(
        descriptor.geometry,
        { recordCount = true, tokenCount = true },
        context,
        code,
        record .. ".geometry"
      )
      checkInt(descriptor.geometry.recordCount, 1, nil, context, code, record .. ".geometry.recordCount")
      checkInt(descriptor.geometry.tokenCount, 0, nil, context, code, record .. ".geometry.tokenCount")
    elseif
      descriptor.format == "hgss-trainer-message-offsets-v1"
      or descriptor.format == "hgss-trainer-message-pairs-v1"
    then
      if descriptor.kind ~= "message" then
        fail(code, record .. " trainer message index has the wrong resource kind", context)
      end
      SchemaCheck.checkRecord(descriptor.geometry, { recordCount = true }, context, code, record .. ".geometry")
      checkInt(descriptor.geometry.recordCount, 1, nil, context, code, record .. ".geometry.recordCount")
    elseif descriptor.format == "nitro-palette-rgb888-v1" then
      SchemaCheck.checkRecord(descriptor.geometry, { colorCount = true }, context, code, record .. ".geometry")
      checkInt(descriptor.geometry.colorCount, 1, nil, context, code, record .. ".geometry.colorCount")
    elseif descriptor.format == "nitro-char-4bpp-v1" or descriptor.format == "nitro-char-8bpp-v1" then
      SchemaCheck.checkRecord(
        descriptor.geometry,
        { depth = true, tileCount = true },
        context,
        code,
        record .. ".geometry"
      )
      local expectedDepth = descriptor.format == "nitro-char-4bpp-v1" and 3 or 4
      checkInt(descriptor.geometry.depth, expectedDepth, expectedDepth, context, code, record .. ".geometry.depth")
      checkInt(descriptor.geometry.tileCount, 1, nil, context, code, record .. ".geometry.tileCount")
    elseif descriptor.format == "nitro-obj-cells-v1" then
      SchemaCheck.checkRecord(
        descriptor.geometry,
        { cellCount = true, bounds = true },
        context,
        code,
        record .. ".geometry"
      )
      checkInt(descriptor.geometry.cellCount, 1, nil, context, code, record .. ".geometry.cellCount")
      if
        not Validate.isArray(descriptor.geometry.bounds)
        or #descriptor.geometry.bounds ~= descriptor.geometry.cellCount
      then
        fail(code, record .. ".geometry.bounds must describe each decoded cell", context)
      end
      for index, bounds in ipairs(descriptor.geometry.bounds) do
        local boundsPath = record .. ".geometry.bounds[" .. index .. "]"
        SchemaCheck.checkRecord(bounds, { x = true, y = true, width = true, height = true }, context, code, boundsPath)
        checkInt(bounds.x, -32768, 32767, context, code, boundsPath .. ".x")
        checkInt(bounds.y, -32768, 32767, context, code, boundsPath .. ".y")
        checkInt(bounds.width, 0, 65535, context, code, boundsPath .. ".width")
        checkInt(bounds.height, 0, 65535, context, code, boundsPath .. ".height")
      end
    elseif descriptor.format == "nitro-obj-animation-v1" then
      SchemaCheck.checkRecord(
        descriptor.geometry,
        { animationCount = true, frameCount = true, durationUnit = true },
        context,
        code,
        record .. ".geometry"
      )
      checkInt(descriptor.geometry.animationCount, 1, nil, context, code, record .. ".geometry.animationCount")
      checkInt(descriptor.geometry.frameCount, 1, nil, context, code, record .. ".geometry.frameCount")
      if descriptor.geometry.durationUnit ~= "native-frame" then
        fail(code, record .. ".geometry.durationUnit must preserve native frame timing", context)
      end
    elseif descriptor.format == "nitro-bg-map-v1" then
      SchemaCheck.checkRecord(
        descriptor.geometry,
        { width = true, height = true, entryCount = true },
        context,
        code,
        record .. ".geometry"
      )
      checkInt(descriptor.geometry.width, 1, nil, context, code, record .. ".geometry.width")
      checkInt(descriptor.geometry.height, 1, nil, context, code, record .. ".geometry.height")
      checkInt(descriptor.geometry.entryCount, 1, nil, context, code, record .. ".geometry.entryCount")
    end
  end
end

local function checkPictureAttributes(attributes, context, code, field)
  checkCatalogTable(attributes, context, code, field)
  if next(attributes) == nil then
    fail(code, field .. " must contain source picture attributes", context)
  end
  for key, record in pairs(attributes) do
    checkString(key, context, code, field .. " key")
    local species, _, gender, facing = key:match("^pokemon/([A-Z0-9_]+)/form%-(%d+)/([a-z]+)/([a-z]+)$")
    if species == nil or gender ~= "male" and gender ~= "female" or facing ~= "front" and facing ~= "back" then
      fail(code, field .. " carries a malformed semantic key: " .. key, context)
    end
    local recordPath = field .. "[" .. key .. "]"
    SchemaCheck.checkRecord(record, { height = true, animation = true }, context, code, recordPath)
    checkInt(record.height, 0, 255, context, code, recordPath .. ".height")
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

local function checkBattleMessageProgramContext(
  programContext,
  route,
  sourceRoutes,
  tagSchemas,
  tagInputs,
  placeholdersCatalog,
  templateInputs,
  context,
  code,
  field
)
  if
    #route.inputs ~= 3
    or route.inputs[1] ~= "messageRecordReference"
    or route.inputs[2] ~= "messageTagSymbol"
    or route.inputs[3] ~= "tagTypedParameters"
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
  local record = programContext.record
  SchemaCheck.checkRecord(record, { input = true, bank = true, selection = true }, context, code, field .. ".record")
  if
    record.input ~= "messageRecordReference"
    or record.selection ~= "link-time-record-reference"
    or record.bank == nil
  then
    fail(code, field .. ".record must bind a link-time record reference to its semantic bank", context)
  end
  local hasRecordInput = false
  local hasRecordBank = false
  for _, input in ipairs(route.inputs) do
    hasRecordInput = hasRecordInput or input == record.input
  end
  for _, bank in ipairs(route.banks) do
    hasRecordBank = hasRecordBank or bank == record.bank
  end
  if not hasRecordInput or not hasRecordBank then
    fail(code, field .. ".record must use the route's declared input and staged bank", context)
  end

  local placeholders = programContext.placeholders
  SchemaCheck.checkRecord(placeholders, {
    tagInput = true,
    parametersInput = true,
    schemaCatalog = true,
    contextCatalog = true,
    placeholderCatalog = true,
    bufferCatalog = true,
    expansionRoute = true,
  }, context, code, field .. ".placeholders")
  if
    placeholders.tagInput ~= "messageTagSymbol"
    or placeholders.parametersInput ~= "tagTypedParameters"
    or placeholders.schemaCatalog ~= "tagSchemas"
    or placeholders.contextCatalog ~= "tagInputs"
    or placeholders.placeholderCatalog ~= "placeholders"
    or placeholders.bufferCatalog ~= "templateInputs"
  then
    fail(
      code,
      field .. ".placeholders must bind the source tag and parameter operands to their typed catalogs",
      context
    )
  end
  local hasTagInput = false
  local hasParametersInput = false
  for _, input in ipairs(route.inputs) do
    hasTagInput = hasTagInput or input == placeholders.tagInput
    hasParametersInput = hasParametersInput or input == placeholders.parametersInput
  end
  if not hasTagInput or not hasParametersInput then
    fail(code, field .. ".placeholders must use the route's declared tag and parameter inputs", context)
  end
  local expansionRoute = sourceRoutes[placeholders.expansionRoute]
  if expansionRoute == nil or expansionRoute.bufferPlan ~= "tagSelectedBuffers" then
    fail(code, field .. ".placeholders must link to the staged battle-message template route", context)
  end
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

local function checkCoverage(coverage, programs, transitions, menus, messages, resources, context, code, field)
  checkCatalogTable(coverage, context, code, field)
  for key, entry in pairs(coverage) do
    checkString(key, context, code, field .. " key")
    local record = field .. "[" .. tostring(key) .. "]"
    SchemaCheck.checkRecord(entry, {
      kind = true,
      program = true,
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
    }, context, code, record)
    if entry.kind == "animation-program" then
      checkString(entry.program, context, code, record .. ".program")
      if programs[entry.program] == nil or entry.route ~= nil then
        fail(code, record .. " references an unknown program or mixes route coverage", context)
        return
      end
      local program = programs[entry.program]
      local programDependencies = program.dependencies
      if not Validate.isArray(programDependencies) or #programDependencies ~= #entry.resources then
        fail(code, record .. ".resources must exactly match its program dependency closure", context)
      end
      for index, dependency in ipairs(programDependencies) do
        if entry.resources[index] ~= dependency then
          fail(code, record .. ".resources must follow the program's ordered dependency receipt", context)
        end
      end
    elseif entry.kind == "transition-route" then
      checkString(entry.route, context, code, record .. ".route")
      if transitions.routes[entry.route] == nil or entry.program ~= nil then
        fail(code, record .. " references an unknown transition route or mixes program coverage", context)
        return
      end
    elseif entry.kind == "menu-route" then
      checkString(entry.route, context, code, record .. ".route")
      local menuRoute = menus.routes[entry.route]
      if menus.selectors[entry.route] == nil or menuRoute == nil or entry.program ~= nil then
        fail(code, record .. " references an unknown menu route or mixes program coverage", context)
        return
      end
      for _, fieldName in ipairs({ "messageEntries", "messageRoutes", "fontRoles", "assetRoles", "requiredContext" }) do
        if not Validate.isArray(entry[fieldName]) then
          fail(code, record .. "." .. fieldName .. " must declare its source dependencies", context)
        end
      end
      SchemaCheck.checkRecord(entry.assetBindings, nil, context, code, record .. ".assetBindings")
      local bindingCount = 0
      for role, binding in pairs(menuRoute.assetBindings) do
        bindingCount = bindingCount + 1
        local coverageBinding = entry.assetBindings[role]
        if
          coverageBinding == nil
          or coverageBinding.catalog ~= binding.catalog
          or coverageBinding.selector ~= binding.selector
          or coverageBinding.when ~= binding.when
          or not Validate.isArray(coverageBinding.context)
          or #coverageBinding.context ~= #binding.context
        then
          fail(code, record .. ".assetBindings must exactly match its menu route closure", context)
          return
        end
        for index, contextField in ipairs(binding.context) do
          if coverageBinding.context[index] ~= contextField then
            fail(code, record .. ".assetBindings must exactly match its menu route closure", context)
          end
        end
      end
      local coverageBindingCount = 0
      for _ in pairs(entry.assetBindings) do
        coverageBindingCount = coverageBindingCount + 1
      end
      if coverageBindingCount ~= bindingCount then
        fail(code, record .. ".assetBindings must exactly match its menu route closure", context)
      end
      local expectedResources = {}
      for _, resourceKey in ipairs(menuRoute.resources) do
        expectedResources[resourceKey] = true
      end
      if #menuRoute.resources ~= #entry.resources then
        fail(code, record .. ".resources must exactly match its menu route closure", context)
      end
      for _, resourceKey in ipairs(entry.resources) do
        if expectedResources[resourceKey] ~= true then
          fail(code, record .. ".resources must exactly match its menu route closure", context)
        end
      end
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
      local coverageMessageEntries = {}
      for _, messageKey in ipairs(entry.messageEntries) do
        coverageMessageEntries[messageKey] = true
      end
      for _, messageKey in ipairs(menuRoute.messageEntries) do
        if coverageMessageEntries[messageKey] ~= true then
          fail(code, record .. ".messageEntries must include its direct menu text", context)
        end
      end
      for _, fieldName in ipairs({ "messageRoutes", "fontRoles", "assetRoles", "requiredContext" }) do
        if #entry[fieldName] < #menuRoute[fieldName] then
          fail(code, record .. "." .. fieldName .. " must include its menu route requirements", context)
        end
        local coverageValues = {}
        for _, value in ipairs(entry[fieldName]) do
          coverageValues[value] = true
        end
        for _, value in ipairs(menuRoute[fieldName]) do
          if coverageValues[value] ~= true then
            fail(code, record .. "." .. fieldName .. " must include its menu route requirements", context)
          end
        end
      end
    elseif entry.kind == "message-route" then
      checkString(entry.route, context, code, record .. ".route")
      if messages.sourceRoutes[entry.route] == nil and messages.routes[entry.route] == nil then
        fail(code, record .. " references an unknown message route or mixes program coverage", context)
        return
      end
      local sourceRoute = messages.sourceRoutes[entry.route]
      if sourceRoute ~= nil and sourceRoute.programContext ~= nil then
        local linked = entry.programContext
        if linked == nil then
          fail(code, record .. ".programContext must preserve its source message binding", context)
          return
        end
        checkBattleMessageProgramContext(
          linked,
          sourceRoute,
          messages.sourceRoutes,
          messages.tagSchemas,
          messages.tagInputs,
          messages.placeholders,
          messages.templateInputs,
          context,
          code,
          record .. ".programContext"
        )
        if not Validate.isArray(entry.messageRoutes) then
          fail(code, record .. ".messageRoutes must include placeholder expansion dependencies", context)
        end
        local expansionRouteKey = linked.placeholders.expansionRoute
        local hasExpansionRoute = false
        for _, routeKey in ipairs(entry.messageRoutes) do
          hasExpansionRoute = hasExpansionRoute or routeKey == expansionRouteKey
        end
        if not hasExpansionRoute then
          fail(code, record .. ".messageRoutes must include its linked placeholder expansion route", context)
        end
        local expansionRoute = messages.sourceRoutes[expansionRouteKey]
        for _, resourceKey in ipairs(sourceRoute.banks) do
          local included = false
          for _, selectedKey in ipairs(entry.resources) do
            included = included or selectedKey == resourceKey
          end
          if not included then
            fail(code, record .. ".resources omits its message record bank", context)
          end
        end
        for _, resourceKey in ipairs(expansionRoute.banks) do
          local included = false
          for _, selectedKey in ipairs(entry.resources) do
            included = included or selectedKey == resourceKey
          end
          if not included then
            fail(code, record .. ".resources omits a placeholder expansion bank", context)
          end
        end
        local sourceContext = sourceRoute.programContext
        if
          linked.program ~= sourceContext.program
          or linked.context ~= sourceContext.context
          or linked.record.input ~= sourceContext.record.input
          or linked.record.bank ~= sourceContext.record.bank
          or linked.record.selection ~= sourceContext.record.selection
          or linked.placeholders.tagInput ~= sourceContext.placeholders.tagInput
          or linked.placeholders.parametersInput ~= sourceContext.placeholders.parametersInput
          or linked.placeholders.schemaCatalog ~= sourceContext.placeholders.schemaCatalog
          or linked.placeholders.contextCatalog ~= sourceContext.placeholders.contextCatalog
          or linked.placeholders.placeholderCatalog ~= sourceContext.placeholders.placeholderCatalog
          or linked.placeholders.bufferCatalog ~= sourceContext.placeholders.bufferCatalog
          or linked.placeholders.expansionRoute ~= sourceContext.placeholders.expansionRoute
        then
          fail(code, record .. ".programContext must exactly match its normalized source route", context)
        end
      elseif entry.programContext ~= nil then
        fail(code, record .. ".programContext is only admitted when a source route declares it", context)
      end
    else
      fail(code, record .. ".kind must identify a source route or animation program", context)
    end
    if
      type(entry.closureIdentity) ~= "string"
      or not entry.closureIdentity:match(
        "^%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x$"
      )
    then
      fail(code, record .. ".closureIdentity must be a SHA-1 identity", context)
    end
    if not Validate.isArray(entry.resources) then
      fail(code, record .. ".resources must enumerate its decoded resource closure", context)
    end
    local seenResources = {}
    for index, resourceKey in ipairs(entry.resources) do
      checkString(resourceKey, context, code, record .. ".resources[" .. index .. "]")
      if resources[resourceKey] == nil or seenResources[resourceKey] then
        fail(code, record .. ".resources contains an unstaged or repeated key", context)
      end
      seenResources[resourceKey] = true
    end
    if entry.kind == "transition-route" then
      local route = transitions.routes[entry.route]
      if #entry.operations ~= 1 or entry.operations[1] ~= route.role or entry.program ~= nil then
        fail(
          code,
          record .. " must identify its source callback operation without inventing an animation program",
          context
        )
      end
      local routeResources = {}
      for _, resourceKey in ipairs(route.resources) do
        routeResources[resourceKey] = true
      end
      local resourceCount = 0
      for _ in pairs(routeResources) do
        resourceCount = resourceCount + 1
      end
      if resourceCount ~= #entry.resources then
        fail(code, record .. ".resources must exactly match its transition route closure", context)
      end
      for resourceKey in pairs(seenResources) do
        if routeResources[resourceKey] == nil then
          fail(code, record .. ".resources must exactly match its transition route closure", context)
        end
      end
    end
    if not Validate.isArray(entry.operations) or #entry.operations == 0 then
      fail(code, record .. " must carry its operations", context)
    end
    for index, operation in ipairs(entry.operations) do
      checkString(operation, context, code, record .. ".operations[" .. index .. "]")
    end
  end
  for routeKey in pairs(transitions.routes) do
    local coverageKey = "transition/" .. routeKey
    local entry = coverage[coverageKey]
    if entry == nil or entry.kind ~= "transition-route" or entry.route ~= routeKey then
      fail(code, field .. " omits transition route admission closure " .. routeKey, context)
    end
  end
  for programKey in pairs(programs) do
    local entry = coverage[programKey]
    local covered = entry ~= nil and entry.kind == "animation-program" and entry.program == programKey
    if not covered then
      fail(code, field .. " omits source program admission closure " .. programKey, context)
    end
  end
  for routeKey in pairs(menus.selectors) do
    local entry = coverage[routeKey]
    if entry == nil or entry.kind ~= "menu-route" or entry.route ~= routeKey then
      fail(code, field .. " omits menu route admission closure " .. routeKey, context)
    end
  end
  for routeKey in pairs(messages.sourceRoutes) do
    local entry = coverage[routeKey]
    if entry == nil or entry.kind ~= "message-route" or entry.route ~= routeKey then
      fail(code, field .. " omits message route admission closure " .. routeKey, context)
    end
  end
end

local function checkSceneEntry(entry, context, code, field)
  SchemaCheck.checkRecord(entry, { key = true, background = true, terrain = true, time = true }, context, code, field)
  checkString(entry.key, context, code, field .. ".key")
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

local function checkMenuSection(section, context, code, field)
  SchemaCheck.checkRecord(section, { image = true, screens = true }, context, code, field)
  checkImagePath(section.image, context, code, field .. ".image")
  if not Validate.isArray(section.screens) or #section.screens == 0 then
    fail(code, field .. " must carry its composed screens", context)
  end
  local planes = {}
  for index, screen in ipairs(section.screens) do
    local entry = field .. ".screens[" .. index .. "]"
    SchemaCheck.checkRecord(screen, {
      image = true,
      width = true,
      height = true,
      tilemapKey = true,
      plane = true,
      template = true,
      priority = true,
      feedback = true,
    }, context, code, entry)
    checkImagePath(screen.image, context, code, entry .. ".image")
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
    if screen.feedback ~= nil then
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
          checkInt(patch.x, 0, screen.width - 1, context, code, patchField .. ".x")
          checkInt(patch.y, 0, screen.height - 1, context, code, patchField .. ".y")
          checkInt(patch.width, 1, screen.width - patch.x, context, code, patchField .. ".width")
          checkInt(patch.height, 1, screen.height - patch.y, context, code, patchField .. ".height")
        end
      end
    end
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
    SchemaCheck.checkRecord(frame, { cell = true, duration = true }, context, code, entry)
    checkInt(frame.cell, 0, nil, context, code, entry .. ".cell")
    -- A legal zero duration holds its opening cell; durations are never
    -- negative or fractional.
    checkInt(frame.duration, 0, nil, context, code, entry .. ".duration")
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
  }, context, code, field)
  checkImagePath(section.image, context, code, field .. ".image")
  if not Validate.isArray(section.cells) or #section.cells == 0 then
    fail(code, field .. " must carry its cells", context)
  end
  for index, cell in ipairs(section.cells) do
    local entry = field .. ".cells[" .. index .. "]"
    SchemaCheck.checkRecord(cell, { objs = true }, context, code, entry)
    if not Validate.isArray(cell.objs) then
      fail(code, entry .. " must carry its objects in order", context)
    end
    for objIndex, obj in ipairs(cell.objs) do
      checkObj(obj, context, code, entry .. ".objs[" .. objIndex .. "]")
    end
  end
  checkAnimation(section.animation, context, code, field .. ".animation")
  if section.componentBase ~= nil then
    checkInt(section.componentBase, 0, 1023, context, code, field .. ".componentBase")
  end
  if section.componentCount ~= nil then
    checkInt(section.componentCount, 1, 256, context, code, field .. ".componentCount")
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
  if not Validate.isArray(section.cells) or #section.cells == 0 then
    fail(code, field .. " must carry its cells", context)
  end
  for index, cell in ipairs(section.cells) do
    local entry = field .. ".cells[" .. index .. "]"
    SchemaCheck.checkRecord(cell, { objs = true }, context, code, entry)
    if not Validate.isArray(cell.objs) then
      fail(code, entry .. " must carry its objects in order", context)
    end
    for objIndex, obj in ipairs(cell.objs) do
      checkObj(obj, context, code, entry .. ".objs[" .. objIndex .. "]")
    end
  end
  checkAnimation(section.animation, context, code, field .. ".animation")
end

local function checkHudPatchSpans(patchSpans, context, code, field)
  SchemaCheck.checkRecord(patchSpans, {
    hp = true,
    currentHp = true,
    maximumHp = true,
    experience = true,
    status = true,
    gender = true,
    caught = true,
    playerDoubleMode = true,
  }, context, code, field)
  if not Validate.isArray(patchSpans.hp) or #patchSpans.hp ~= 6 then
    fail(code, field .. ".hp must carry all six side types", context)
  end
  local sideTypes = {}
  for index, record in ipairs(patchSpans.hp) do
    local entry = field .. ".hp[" .. index .. "]"
    SchemaCheck.checkRecord(record, { sideType = true, spans = true }, context, code, entry)
    checkInt(record.sideType, 0, 5, context, code, entry .. ".sideType")
    if sideTypes[record.sideType] then
      fail(code, field .. ".hp side types must be unique", context)
    end
    sideTypes[record.sideType] = true
    if not Validate.isArray(record.spans) or #record.spans ~= 2 then
      fail(code, entry .. ".spans must carry both source patch ranges", context)
    end
    local count = 0
    local occupied = {}
    for spanIndex, span in ipairs(record.spans) do
      local spanField = entry .. ".spans[" .. spanIndex .. "]"
      SchemaCheck.checkRecord(span, { tile = true, count = true }, context, code, spanField)
      checkInt(span.tile, 0, 1023, context, code, spanField .. ".tile")
      checkInt(span.count, 0, 12, context, code, spanField .. ".count")
      if span.tile + span.count > 1024 then
        fail(code, spanField .. " exceeds the character tile index range", context)
      end
      for tile = span.tile, span.tile + span.count - 1 do
        if occupied[tile] then
          fail(code, entry .. " patch spans overlap", context)
        end
        occupied[tile] = true
      end
      count = count + span.count
    end
    if count ~= 6 then
      fail(code, entry .. " spans must cover six health tiles", context)
    end
  end
  for _, sideType in ipairs({ 0, 1, 2, 3, 4, 5 }) do
    if not sideTypes[sideType] then
      fail(code, field .. ".hp must cover every side type", context)
    end
  end
  if not Validate.isArray(patchSpans.experience) or #patchSpans.experience ~= 2 then
    fail(code, field .. ".experience must carry its two source patch ranges", context)
  end
  local experienceCount = 0
  local occupiedExperience = {}
  for index, span in ipairs(patchSpans.experience) do
    local entry = field .. ".experience[" .. index .. "]"
    SchemaCheck.checkRecord(span, { tile = true, count = true }, context, code, entry)
    checkInt(span.tile, 0, 1023, context, code, entry .. ".tile")
    checkInt(span.count, 0, 12, context, code, entry .. ".count")
    if span.tile + span.count > 1024 then
      fail(code, entry .. " exceeds the character tile index range", context)
    end
    for tile = span.tile, span.tile + span.count - 1 do
      if occupiedExperience[tile] then
        fail(code, field .. ".experience patch spans overlap", context)
      end
      occupiedExperience[tile] = true
    end
    experienceCount = experienceCount + span.count
  end
  if experienceCount ~= 12 then
    fail(code, field .. ".experience spans must cover twelve experience tiles", context)
  end
  for category, spanCounts in pairs({
    currentHp = { 3 },
    maximumHp = { 3 },
    status = { 3 },
    gender = { 2, 2 },
    caught = { 1 },
  }) do
    local records = patchSpans[category]
    if not Validate.isArray(records) or #records ~= 6 then
      fail(code, field .. "." .. category .. " must cover all six native side types", context)
    end
    local covered = {}
    for index, record in ipairs(records) do
      local entry = field .. "." .. category .. "[" .. index .. "]"
      SchemaCheck.checkRecord(
        record,
        { sideType = true, tile = true, count = true, spans = true },
        context,
        code,
        entry
      )
      checkInt(record.sideType, 0, 5, context, code, entry .. ".sideType")
      if covered[record.sideType] then
        fail(code, field .. "." .. category .. " side types must be unique", context)
      end
      covered[record.sideType] = true
      local spans = record.spans or { { tile = record.tile, count = record.count } }
      if not Validate.isArray(spans) or #spans ~= #spanCounts then
        fail(code, entry .. ".spans must match the native character writes", context)
      end
      for spanIndex, span in ipairs(spans) do
        local spanField = entry .. ".spans[" .. spanIndex .. "]"
        SchemaCheck.checkRecord(span, { tile = true, count = true }, context, code, spanField)
        checkInt(span.tile, 0, 1023, context, code, spanField .. ".tile")
        checkInt(span.count, spanCounts[spanIndex], spanCounts[spanIndex], context, code, spanField .. ".count")
        if span.tile + span.count > 1024 then
          fail(code, spanField .. " exceeds the character tile index range", context)
        end
      end
    end
    for sideType = 0, 5 do
      if not covered[sideType] then
        fail(code, field .. "." .. category .. " must cover all six native side types", context)
      end
    end
  end
  if not Validate.isArray(patchSpans.playerDoubleMode) or #patchSpans.playerDoubleMode ~= 2 then
    fail(code, field .. ".playerDoubleMode must cover both double-player rows", context)
  end
  local doubleSides = {}
  for index, record in ipairs(patchSpans.playerDoubleMode) do
    local entry = field .. ".playerDoubleMode[" .. index .. "]"
    SchemaCheck.checkRecord(record, { sideType = true, gauge = true, numbers = true }, context, code, entry)
    if record.sideType ~= 2 and record.sideType ~= 4 then
      fail(code, entry .. ".sideType must name a double-player row", context)
    end
    if doubleSides[record.sideType] then
      fail(code, field .. ".playerDoubleMode side types must be unique", context)
    end
    doubleSides[record.sideType] = true
    for modeName, expectedCount in pairs({ gauge = 4, numbers = 3 }) do
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
    fail(code, field .. ".playerDoubleMode must cover side types 2 and 4", context)
  end
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
    SchemaCheck.checkRecord(record, { font = true }, context, code, entry)
    checkString(record.font, context, code, entry .. ".font")
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

local function checkMenuContexts(contexts, entries, routes, context, code, field)
  local expected =
    { main = true, bugContest = true, frontier = true, moveSelection = true, targetSelection = true, vsRecorder = true }
  SchemaCheck.checkRecord(contexts, expected, context, code, field)
  for key in pairs(expected) do
    if contexts[key] == nil then
      fail(code, field .. " is missing typed source context " .. key, context)
    end
  end

  local main = contexts.main
  SchemaCheck.checkRecord(main, { inputs = true, modes = true }, context, code, field .. ".main")
  SchemaCheck.checkRecord(
    main.inputs,
    { mode = true, cancelRun = true, frontier = true },
    context,
    code,
    field .. ".main.inputs"
  )
  SchemaCheck.checkRecord(main.inputs.mode, { type = true, values = true }, context, code, field .. ".main.inputs.mode")
  if main.inputs.mode.type ~= "enum" or not Validate.isArray(main.inputs.mode.values) then
    fail(code, field .. ".main.inputs.mode must be a typed enum", context)
  end
  checkStringArray(main.inputs.mode.values, context, code, field .. ".main.inputs.mode.values")
  checkBooleanInput(main.inputs.cancelRun, context, code, field .. ".main.inputs.cancelRun")
  checkBooleanInput(main.inputs.frontier, context, code, field .. ".main.inputs.frontier")
  if not Validate.isArray(main.modes) then
    fail(code, field .. ".main.modes must preserve supported mode order", context)
  end
  checkStringArray(main.modes, context, code, field .. ".main.modes")

  local bugContest = contexts.bugContest
  SchemaCheck.checkRecord(
    bugContest,
    { caughtPokemon = true, remainingSafariBalls = true, sprites = true },
    context,
    code,
    field .. ".bugContest"
  )
  SchemaCheck.checkRecord(
    bugContest.caughtPokemon,
    { optional = true, fields = true, absentSpecies = true },
    context,
    code,
    field .. ".bugContest.caughtPokemon"
  )
  if bugContest.caughtPokemon.optional ~= true or bugContest.caughtPokemon.absentSpecies ~= "species/none" then
    fail(code, field .. ".bugContest.caughtPokemon must preserve the optional absent-species case", context)
  end
  SchemaCheck.checkRecord(
    bugContest.caughtPokemon.fields,
    { species = true, form = true, gender = true, level = true },
    context,
    code,
    field .. ".bugContest.caughtPokemon.fields"
  )
  for _, role in ipairs({ "species", "form", "level" }) do
    checkString(
      bugContest.caughtPokemon.fields[role],
      context,
      code,
      field .. ".bugContest.caughtPokemon.fields." .. role
    )
  end
  SchemaCheck.checkRecord(
    bugContest.caughtPokemon.fields.gender,
    { type = true, values = true },
    context,
    code,
    field .. ".bugContest.caughtPokemon.fields.gender"
  )
  if
    bugContest.caughtPokemon.fields.gender.type ~= "enum"
    or not Validate.isArray(bugContest.caughtPokemon.fields.gender.values)
  then
    fail(code, field .. ".bugContest.caughtPokemon.fields.gender must be a typed enum", context)
  end
  checkStringArray(
    bugContest.caughtPokemon.fields.gender.values,
    context,
    code,
    field .. ".bugContest.caughtPokemon.fields.gender.values"
  )
  if
    #bugContest.caughtPokemon.fields.gender.values ~= 3
    or bugContest.caughtPokemon.fields.gender.values[3] ~= "genderless"
  then
    fail(code, field .. ".bugContest.caughtPokemon.fields.gender must include genderless", context)
  end
  checkString(bugContest.remainingSafariBalls, context, code, field .. ".bugContest.remainingSafariBalls")
  checkString(bugContest.sprites, context, code, field .. ".bugContest.sprites")

  local frontier = contexts.frontier
  SchemaCheck.checkRecord(frontier, { input = true, overrides = true }, context, code, field .. ".frontier")
  checkString(frontier.input, context, code, field .. ".frontier.input")
  checkString(frontier.overrides, context, code, field .. ".frontier.overrides")

  local move = contexts.moveSelection
  SchemaCheck.checkRecord(move, { slotCount = true, slots = true }, context, code, field .. ".moveSelection")
  checkInt(move.slotCount, 4, 4, context, code, field .. ".moveSelection.slotCount")
  SchemaCheck.checkRecord(
    move.slots,
    { move = true, currentPP = true, maximumPP = true, derived = true, emptyMove = true },
    context,
    code,
    field .. ".moveSelection.slots"
  )
  for _, role in ipairs({ "move", "currentPP", "maximumPP", "emptyMove" }) do
    checkString(move.slots[role], context, code, field .. ".moveSelection.slots." .. role)
  end
  SchemaCheck.checkRecord(
    move.slots.derived,
    { moveName = true, moveType = true, typeIcon = true },
    context,
    code,
    field .. ".moveSelection.slots.derived"
  )
  for _, role in ipairs({ "moveName", "moveType", "typeIcon" }) do
    checkString(move.slots.derived[role], context, code, field .. ".moveSelection.slots.derived." .. role)
  end

  local target = contexts.targetSelection
  SchemaCheck.checkRecord(
    target,
    { slotCount = true, order = true, hitMask = true, visibility = true, candidate = true, iconAssetRoles = true },
    context,
    code,
    field .. ".targetSelection"
  )
  checkInt(target.slotCount, 4, 4, context, code, field .. ".targetSelection.slotCount")
  checkString(target.order, context, code, field .. ".targetSelection.order")
  checkString(target.hitMask, context, code, field .. ".targetSelection.hitMask")
  SchemaCheck.checkRecord(
    target.visibility,
    { candidateFlag = true, requiredValue = true, hitRequired = true },
    context,
    code,
    field .. ".targetSelection.visibility"
  )
  checkString(target.visibility.candidateFlag, context, code, field .. ".targetSelection.visibility.candidateFlag")
  if target.visibility.requiredValue ~= true or target.visibility.hitRequired ~= true then
    fail(code, field .. ".targetSelection.visibility must require visible hit candidates", context)
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
  }, context, code, field .. ".targetSelection.candidate")
  for role, value in pairs(target.candidate) do
    checkString(value, context, code, field .. ".targetSelection.candidate." .. role)
  end
  checkStringArray(target.iconAssetRoles, context, code, field .. ".targetSelection.iconAssetRoles")

  local recorder = contexts.vsRecorder
  SchemaCheck.checkRecord(
    recorder,
    { inputs = true, screenRole = true, stopMessage = true, feedbackRoute = true },
    context,
    code,
    field .. ".vsRecorder"
  )
  SchemaCheck.checkRecord(recorder.inputs, { playbackStatus = true }, context, code, field .. ".vsRecorder.inputs")
  SchemaCheck.checkRecord(
    recorder.inputs.playbackStatus,
    { type = true, values = true },
    context,
    code,
    field .. ".vsRecorder.inputs.playbackStatus"
  )
  if recorder.inputs.playbackStatus.type ~= "enum" or not Validate.isArray(recorder.inputs.playbackStatus.values) then
    fail(code, field .. ".vsRecorder.inputs.playbackStatus must be a typed enum", context)
  end
  checkStringArray(
    recorder.inputs.playbackStatus.values,
    context,
    code,
    field .. ".vsRecorder.inputs.playbackStatus.values"
  )
  checkString(recorder.screenRole, context, code, field .. ".vsRecorder.screenRole")
  checkString(recorder.stopMessage, context, code, field .. ".vsRecorder.stopMessage")
  checkString(recorder.feedbackRoute, context, code, field .. ".vsRecorder.feedbackRoute")
  if entries[recorder.stopMessage] == nil or routes[recorder.feedbackRoute] == nil then
    fail(code, field .. ".vsRecorder must link its staged stop message and feedback route", context)
  end
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

local function checkTransitionRouteResources(routes, messageEntries, resources, context, code, field)
  SchemaCheck.checkRecord(routes, { trainerName = true, rivalName = true }, context, code, field)
  for routeName, expectedInput in pairs({ trainerName = "trainerName", rivalName = "rivalName" }) do
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

local function checkTransitionRoutes(routes, messageEntries, messageRoutes, resources, context, code, field)
  checkCatalogTable(routes, context, code, field)
  local contextNames = {
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
  local transitionTrainerKeys = { will = true, koga = true, bruno = true, karen = true, lance = true, red = true }
  for key, route in pairs(routes) do
    checkString(key, context, code, field .. " key")
    local entry = field .. "[" .. key .. "]"
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
      if contextNames[input] ~= true or seenInputs[input] then
        fail(code, entry .. ".requiredContext carries an unknown or repeated input", context)
      end
      seenInputs[input] = true
    end
    if not Validate.isArray(route.resources) then
      fail(code, entry .. ".resources must be an ordered semantic resource list", context)
    end
    local routeResources = {}
    for index, resourceKey in ipairs(route.resources) do
      checkString(resourceKey, context, code, entry .. ".resources[" .. index .. "]")
      if resources[resourceKey] == nil then
        fail(code, entry .. ".resources references an unstaged resource", context)
      end
      routeResources[resourceKey] = true
    end
    if type(route.assetGroups) ~= "table" then
      fail(code, entry .. ".assetGroups must preserve source loader groupings", context)
    end
    local function checkResourceGroup(value, groupField)
      if type(value) == "string" then
        if resources[value] == nil or not routeResources[value] then
          fail(code, groupField .. " references a resource outside its route", context)
        end
      elseif type(value) == "table" then
        for _, nested in pairs(value) do
          checkResourceGroup(nested, groupField)
        end
      else
        fail(code, groupField .. " must contain only semantic resource references", context)
      end
    end
    checkResourceGroup(route.assetGroups, entry .. ".assetGroups")
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
      if transitionTrainerKeys[route.trainer.key] ~= true or not seenInputs.transitionTrainer then
        fail(code, entry .. ".trainer must bind a semantic trainer identity through transitionTrainer context", context)
      end
    elseif seenInputs.transitionTrainer then
      fail(code, entry .. " declares transitionTrainer without a semantic trainer identity", context)
    end
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
  for _, routeMapName in ipairs({ "trainerClassRoutes", "wildSpeciesRoutes" }) do
    local routeMap = selection[routeMapName]
    checkCatalogTable(routeMap, context, code, field .. "." .. routeMapName)
    for inputKey, routeKey in pairs(routeMap) do
      checkString(inputKey, context, code, field .. "." .. routeMapName .. " key")
      checkString(routeKey, context, code, field .. "." .. routeMapName .. " value")
      if routeKey ~= "setup-fallback" and routes[routeKey] == nil then
        fail(code, field .. "." .. routeMapName .. " references an unknown semantic route", context)
      end
    end
  end
  for _, musicMapName in ipairs({ "trainerClassMusicRoles", "wildSpeciesMusicRoles" }) do
    local musicRoles = selection[musicMapName]
    checkCatalogTable(musicRoles, context, code, field .. "." .. musicMapName)
    for inputKey, musicRole in pairs(musicRoles) do
      checkString(inputKey, context, code, field .. "." .. musicMapName .. " key")
      checkString(musicRole, context, code, field .. "." .. musicMapName .. " role")
      local routeMapName = musicMapName == "trainerClassMusicRoles" and "trainerClassRoutes" or "wildSpeciesRoutes"
      if selection[routeMapName][inputKey] == nil then
        fail(code, field .. "." .. musicMapName .. " contains an input without a semantic route", context)
      end
    end
  end
  local trainer = selection.trainerRules
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
  if
    not Validate.isArray(trainer.inputs)
    or #trainer.inputs ~= 2
    or trainer.inputs[1] ~= "trainerClass"
    or trainer.inputs[2] ~= "battleType"
  then
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
  for _, routeKey in ipairs({
    special.preserveRoute,
    special.defaultRoute,
    special.doublesRoute,
    trainer.unknownRoute,
    trainer.doublesRoute,
    trainer.alternateTransitionRoute,
  }) do
    checkString(routeKey, context, code, field .. ".trainerRules route")
    if routeKey ~= "setup-fallback" and routes[routeKey] == nil then
      fail(code, field .. ".trainerRules references an unknown semantic route", context)
    end
  end
  for _, routeKey in ipairs(trainer.preserveRoutes) do
    checkString(routeKey, context, code, field .. ".trainerRules.preserveRoutes")
    if routeKey ~= "setup-fallback" and routes[routeKey] == nil then
      fail(code, field .. ".trainerRules.preserveRoutes references an unknown semantic route", context)
    end
  end
  for _, musicRole in ipairs({
    special.preserveMusicRole,
    special.defaultMusicRole,
    special.doublesMusicRole,
    trainer.unknownMusicRole,
    trainer.doublesMusicRole,
    trainer.alternateMusicRole,
  }) do
    checkString(musicRole, context, code, field .. ".trainerRules music role")
  end
  local wild = selection.wildRules
  SchemaCheck.checkRecord(wild, {
    inputs = true,
    specialMode = true,
    fallbackRoute = true,
    fallbackMusicRole = true,
    doublesRoute = true,
    doublesMusicRole = true,
  }, context, code, field .. ".wildRules")
  if
    not Validate.isArray(wild.inputs)
    or #wild.inputs ~= 3
    or wild.inputs[1] ~= "wildSpecies"
    or wild.inputs[2] ~= "battleType"
    or wild.inputs[3] ~= "transitionMode"
  then
    fail(code, field .. ".wildRules must declare species, battle type, and transition mode inputs", context)
  end
  checkString(wild.specialMode, context, code, field .. ".wildRules.specialMode")
  for _, routeKey in ipairs({ wild.fallbackRoute, wild.doublesRoute }) do
    checkString(routeKey, context, code, field .. ".wildRules route")
    if routeKey ~= "setup-fallback" and routes[routeKey] == nil then
      fail(code, field .. ".wildRules references an unknown semantic route", context)
    end
  end
  checkString(wild.fallbackMusicRole, context, code, field .. ".wildRules.fallbackMusicRole")
  checkString(wild.doublesMusicRole, context, code, field .. ".wildRules.doublesMusicRole")
  if not Validate.isArray(selection.fallbackRoutes) or #selection.fallbackRoutes ~= 12 then
    fail(code, field .. ".fallbackRoutes must enumerate every semantic setup fallback", context)
  end
  local fallbackContexts = {}
  for index, fallback in ipairs(selection.fallbackRoutes) do
    local entry = field .. ".fallbackRoutes[" .. index .. "]"
    SchemaCheck.checkRecord(
      fallback,
      { route = true, terrain = true, timeOfDay = true, battleKind = true },
      context,
      code,
      entry
    )
    checkString(fallback.route, context, code, entry .. ".route")
    if not ({ plain = true, water = true, cave = true })[fallback.terrain] then
      fail(code, entry .. ".terrain must be a source-backed semantic terrain", context)
    end
    if not ({ day = true, late = true })[fallback.timeOfDay] then
      fail(code, entry .. ".timeOfDay must be day or late", context)
    end
    if routes[fallback.route] == nil or (fallback.battleKind ~= "trainer" and fallback.battleKind ~= "wild") then
      fail(code, entry .. " must reference its semantic fallback route and battle kind", context)
    end
    local contextKey = fallback.terrain .. "/" .. fallback.timeOfDay .. "/" .. fallback.battleKind
    if fallbackContexts[contextKey] then
      fail(code, field .. ".fallbackRoutes repeats a setup context", context)
    end
    fallbackContexts[contextKey] = true
  end
end

local function checkTransitionInternalResources(routes, resources, context, code, field)
  SchemaCheck.checkRecord(routes, { sprite = true }, context, code, field)
  local sprite = routes.sprite
  local expectedKinds = { palette = "palette", character = "texture", cell = "cell", animation = "animation" }
  SchemaCheck.checkRecord(sprite, expectedKinds, context, code, field .. ".sprite")
  for role, expectedKind in pairs(expectedKinds) do
    local descriptor = resources[sprite[role]]
    if descriptor == nil or descriptor.kind ~= expectedKind then
      fail(code, field .. ".sprite." .. role .. " must reference a decoded " .. expectedKind .. " resource", context)
    end
  end
end

local function checkMessageDynamicRoutes(routes, banks, entries, resources, context, code, field)
  if type(resources) ~= "table" then
    fail(code, field .. " requires the decoded global resource catalog", context)
  end
  SchemaCheck.checkRecord(routes, {
    captureShake = true,
    metBillPCTransfer = true,
    frontierTrainerSpeech = true,
    trainerPairSpeech = true,
    tutorialAuthor = true,
  }, context, code, field)
  local capture = routes.captureShake
  SchemaCheck.checkRecord(
    capture,
    { bank = true, input = true, firstRecord = true, minimum = true, maximum = true, recordCount = true },
    context,
    code,
    field .. ".captureShake"
  )
  if banks.scriptController ~= capture.bank or capture.input ~= "captureShakeCount" then
    fail(code, field .. ".captureShake must use the script-controller bank and capture count", context)
  end
  checkInt(capture.minimum, 0, 0, context, code, field .. ".captureShake.minimum")
  checkInt(capture.maximum, 4, 4, context, code, field .. ".captureShake.maximum")
  checkInt(capture.recordCount, 5, 5, context, code, field .. ".captureShake.recordCount")
  checkString(capture.firstRecord, context, code, field .. ".captureShake.firstRecord")
  local recordPrefix, firstOffset = capture.firstRecord:match("^(.*)/(%d+)$")
  if recordPrefix == nil or firstOffset ~= "0" then
    fail(code, field .. ".captureShake.firstRecord must identify the zero-offset record", context)
  end
  for offset = 0, 4 do
    if entries[recordPrefix .. "/" .. offset] == nil then
      fail(code, field .. ".captureShake omits source record offset " .. offset, context)
    end
  end

  local metBill = routes.metBillPCTransfer
  SchemaCheck.checkRecord(
    metBill,
    { banks = true, inputs = true, cases = true },
    context,
    code,
    field .. ".metBillPCTransfer"
  )
  if not Validate.isArray(metBill.banks) or #metBill.banks ~= 1 or metBill.banks[1] ~= banks.scriptController then
    fail(code, field .. ".metBillPCTransfer must use the script-controller bank", context)
  end
  if
    not Validate.isArray(metBill.inputs)
    or #metBill.inputs ~= 2
    or metBill.inputs[1] ~= "metBill"
    or metBill.inputs[2] ~= "pcHasSpace"
  then
    fail(code, field .. ".metBillPCTransfer must retain its two source inputs", context)
  end
  if not Validate.isArray(metBill.cases) or #metBill.cases ~= 4 then
    fail(code, field .. ".metBillPCTransfer must map its four boolean cases", context)
  end
  for index, case in ipairs(metBill.cases) do
    local caseField = field .. ".metBillPCTransfer.cases[" .. index .. "]"
    SchemaCheck.checkRecord(case, { key = true, metBill = true, pcHasSpace = true }, context, code, caseField)
    checkString(case.key, context, code, caseField .. ".key")
    if entries[case.key] == nil or type(case.metBill) ~= "boolean" or type(case.pcHasSpace) ~= "boolean" then
      fail(code, caseField .. " must select a source-backed message by boolean inputs", context)
    end
  end

  local frontier = routes.frontierTrainerSpeech
  SchemaCheck.checkRecord(
    frontier,
    { banks = true, inputs = true, profilePredicate = true, recordFormula = true },
    context,
    code,
    field .. ".frontierTrainerSpeech"
  )
  if
    not Validate.isArray(frontier.banks)
    or #frontier.banks ~= 2
    or frontier.banks[1] ~= banks.frontierTrainerProfileZero
    or frontier.banks[2] ~= banks.frontierTrainerProfileFallback
    or frontier.profilePredicate ~= "anyPlayerProfileVersionZero"
  then
    fail(code, field .. ".frontierTrainerSpeech must preserve the source profile-bank selection", context)
  end
  if not Validate.isArray(frontier.inputs) or #frontier.inputs ~= 3 then
    fail(code, field .. ".frontierTrainerSpeech must preserve trainer, outcome, and profile inputs", context)
  end
  SchemaCheck.checkRecord(frontier.recordFormula, {
    trainerIndexMultiplier = true,
    winOffset = true,
    lossOffset = true,
  }, context, code, field .. ".frontierTrainerSpeech.recordFormula")
  checkInt(
    frontier.recordFormula.trainerIndexMultiplier,
    3,
    3,
    context,
    code,
    field .. ".frontierTrainerSpeech.recordFormula.trainerIndexMultiplier"
  )
  checkInt(
    frontier.recordFormula.winOffset,
    1,
    1,
    context,
    code,
    field .. ".frontierTrainerSpeech.recordFormula.winOffset"
  )
  checkInt(
    frontier.recordFormula.lossOffset,
    2,
    2,
    context,
    code,
    field .. ".frontierTrainerSpeech.recordFormula.lossOffset"
  )

  local pairSpeech = routes.trainerPairSpeech
  SchemaCheck.checkRecord(
    pairSpeech,
    { bank = true, inputs = true, selection = true },
    context,
    code,
    field .. ".trainerPairSpeech"
  )
  if pairSpeech.bank ~= banks.trainerPairLookup then
    fail(code, field .. ".trainerPairSpeech must use the source pair-table selection", context)
  end
  if
    not Validate.isArray(pairSpeech.inputs)
    or #pairSpeech.inputs ~= 2
    or pairSpeech.inputs[1] ~= "trainerIndex"
    or pairSpeech.inputs[2] ~= "trainerMessageKind"
  then
    fail(code, field .. ".trainerPairSpeech must retain trainer and message-kind inputs", context)
  end
  local pairSelection = pairSpeech.selection
  SchemaCheck.checkRecord(
    pairSelection,
    { lookup = true, offsetsResource = true, pairsResource = true, offsetSelection = true, pairSelection = true },
    context,
    code,
    field .. ".trainerPairSpeech.selection"
  )
  if pairSelection.lookup ~= "trainer-message-index" then
    fail(code, field .. ".trainerPairSpeech.selection must use the decoded trainer-message index", context)
  end
  for _, tableRole in ipairs({ "offsets", "pairs" }) do
    local resourceKey = pairSelection[tableRole .. "Resource"]
    local descriptor = resources[resourceKey]
    local expectedFormat = tableRole == "offsets" and "hgss-trainer-message-offsets-v1"
      or "hgss-trainer-message-pairs-v1"
    if descriptor == nil or descriptor.kind ~= "message" or descriptor.format ~= expectedFormat then
      fail(code, field .. ".trainerPairSpeech.selection must reference its decoded " .. tableRole .. " table", context)
    end
  end
  local offsetSelection = pairSelection.offsetSelection
  SchemaCheck.checkRecord(
    offsetSelection,
    { input = true, elementStrideBytes = true, valueWidthBytes = true, result = true },
    context,
    code,
    field .. ".trainerPairSpeech.selection.offsetSelection"
  )
  if
    offsetSelection.input ~= "trainerIndex"
    or offsetSelection.elementStrideBytes ~= 2
    or offsetSelection.valueWidthBytes ~= 2
    or offsetSelection.result ~= "pair-record-byte-offset"
  then
    fail(code, field .. ".trainerPairSpeech.selection must preserve the source offset-table layout", context)
  end
  local pairTableSelection = pairSelection.pairSelection
  SchemaCheck.checkRecord(
    pairTableSelection,
    { inputs = true, recordStrideBytes = true, match = true, result = true },
    context,
    code,
    field .. ".trainerPairSpeech.selection.pairSelection"
  )
  if
    not Validate.isArray(pairTableSelection.inputs)
    or #pairTableSelection.inputs ~= 2
    or pairTableSelection.inputs[1] ~= "trainerIndex"
    or pairTableSelection.inputs[2] ~= "trainerMessageKind"
    or pairTableSelection.recordStrideBytes ~= 4
    or pairTableSelection.match ~= "trainer-and-message-kind"
    or pairTableSelection.result ~= "messageRecordReference"
  then
    fail(code, field .. ".trainerPairSpeech.selection must preserve the source pair-record layout", context)
  end

  local tutorial = routes.tutorialAuthor
  SchemaCheck.checkRecord(
    tutorial,
    { bank = true, input = true, variants = true },
    context,
    code,
    field .. ".tutorialAuthor"
  )
  if tutorial.bank ~= banks.tutorialAuthor or tutorial.input ~= "playerGender" then
    fail(code, field .. ".tutorialAuthor must use the gender-selected tutorial bank", context)
  end
  SchemaCheck.checkRecord(
    tutorial.variants,
    { malePlayer = true, femalePlayer = true },
    context,
    code,
    field .. ".tutorialAuthor.variants"
  )
  for _, variant in pairs(tutorial.variants) do
    checkString(variant, context, code, field .. ".tutorialAuthor.variants")
    if entries[variant] == nil then
      fail(code, field .. ".tutorialAuthor references a missing message record", context)
    end
  end
end

local function checkMessageSourceRoutes(
  routes,
  banks,
  dynamicRoutes,
  messageRoutes,
  resources,
  tagSchemas,
  tagInputs,
  placeholdersCatalog,
  templateInputs,
  context,
  code,
  field
)
  checkCatalogTable(routes, context, code, field)
  for routeKey, route in pairs(routes) do
    checkString(routeKey, context, code, field .. " key")
    local entry = field .. "[" .. routeKey .. "]"
    SchemaCheck.checkRecord(route, {
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
    }, context, code, entry)
    if not Validate.isArray(route.banks) or not Validate.isArray(route.inputs) then
      fail(code, entry .. " must carry ordered semantic banks and runtime inputs", context)
    end
    if routeKey == "battle/script-message" or routeKey == "battle/global-script-message" then
      checkBattleMessageProgramContext(
        route.programContext,
        route,
        routes,
        tagSchemas,
        tagInputs,
        placeholdersCatalog,
        templateInputs,
        context,
        code,
        entry .. ".programContext"
      )
      local expectedDelivery = routeKey == "battle/script-message" and "message-scope-local" or "message-scope-global"
      if route.programContext.delivery ~= expectedDelivery then
        fail(code, entry .. ".programContext.delivery must preserve its source message scope", context)
      end
    elseif route.programContext ~= nil then
      fail(code, entry .. ".programContext is only defined for the battle script-message route", context)
    end
    for index, bank in ipairs(route.banks) do
      checkString(bank, context, code, entry .. ".banks[" .. index .. "]")
      local known = false
      for _, bankKey in pairs(banks) do
        if bank == bankKey then
          known = true
          break
        end
      end
      if not known then
        fail(code, entry .. " references an unknown staged message bank", context)
      end
    end
    for index, input in ipairs(route.inputs) do
      checkString(input, context, code, entry .. ".inputs[" .. index .. "]")
    end
    for _, fieldName in ipairs({
      "placeholderPlan",
      "expansion",
      "selectionCase",
      "placeholderInputs",
      "bufferPlan",
      "selection",
      "recordSelection",
      "profilePredicate",
    }) do
      if route[fieldName] ~= nil then
        checkString(route[fieldName], context, code, entry .. "." .. fieldName)
      end
    end
    if route.recordFormula ~= nil then
      SchemaCheck.checkRecord(
        route.recordFormula,
        { trainerIndexMultiplier = true, winOffset = true, lossOffset = true },
        context,
        code,
        entry .. ".recordFormula"
      )
      checkInt(
        route.recordFormula.trainerIndexMultiplier,
        1,
        nil,
        context,
        code,
        entry .. ".recordFormula.trainerIndexMultiplier"
      )
      checkInt(route.recordFormula.winOffset, 0, nil, context, code, entry .. ".recordFormula.winOffset")
      checkInt(route.recordFormula.lossOffset, 0, nil, context, code, entry .. ".recordFormula.lossOffset")
    end
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
        if dynamicRoutes[messageRouteKey] == nil and messageRoutes[messageRouteKey] == nil then
          fail(code, entry .. " references an unknown normalized message route", context)
        end
      end
    end
    for _, casesField in ipairs({ "reachableCases", "unresolvedCases" }) do
      local cases = route[casesField]
      if cases ~= nil then
        if not Validate.isArray(cases) then
          fail(code, entry .. "." .. casesField .. " must be an ordered case list", context)
        end
        for index, case in ipairs(cases) do
          checkString(case, context, code, entry .. "." .. casesField .. "[" .. index .. "]")
        end
      end
    end
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

  local closureField = field .. ".sequenceClosures"
  SchemaCheck.checkRecord(introMusic.sequenceClosures, nil, context, code, closureField)
  local function checkSequenceKey(sequenceKey, record)
    checkString(sequenceKey, context, code, record)
    if not sequenceKey:match("^audio/sequence/[a-zA-Z0-9_%-]+$") then
      fail(code, record .. " must use a semantic sequence key", context)
    end
    local closure = introMusic.sequenceClosures[sequenceKey]
    if closure == nil then
      fail(code, record .. " has no compiled sequence closure", context)
    end
    return closure
  end
  local function checkClosure(sequenceKey, closure)
    local record = closureField .. "." .. sequenceKey
    SchemaCheck.checkRecord(
      closure,
      { bankKey = true, player = true, sampleKeys = true, closureIdentity = true },
      context,
      code,
      record
    )
    if
      type(closure.bankKey) ~= "string"
      or not closure.bankKey:match(
        "^audio/bank/content/%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x$"
      )
    then
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
      if
        not sampleKey:match(
          "^audio/sample/content/%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x$"
        )
      then
        fail(code, record .. ".sampleKeys[" .. index .. "] must be a content-addressed sample key", context)
      end
    end
    if
      type(closure.closureIdentity) ~= "string"
      or not closure.closureIdentity:match(
        "^%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x$"
      )
    then
      fail(code, record .. ".closureIdentity must be a SHA-1 identity", context)
    end
    return closure
  end
  for sequenceKey, closure in pairs(introMusic.sequenceClosures) do
    checkSequenceKey(sequenceKey, closureField .. " key")
    checkClosure(sequenceKey, closure)
  end

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
    checkSequenceKey(route.sequenceKey, record .. ".sequenceKey")
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
    checkSequenceKey(route.sequenceKey, record .. ".sequenceKey")
    if routes[route.routeKey] ~= true or type(route.transitionFallback) ~= "boolean" then
      fail(code, record .. " must link to a semantic route and preserve fallback selection", context)
    end
  end
  checkStringArray(introMusic.kantoOverrides, context, code, field .. ".kantoOverrides")
  SchemaCheck.checkRecord(
    introMusic.kantoSelection,
    { predicate = true, appliesAfterCategorySelection = true, routes = true },
    context,
    code,
    field .. ".kantoSelection"
  )
  checkStringArray(introMusic.kantoSelection.predicate, context, code, field .. ".kantoSelection.predicate")
  if introMusic.kantoSelection.appliesAfterCategorySelection ~= true then
    fail(code, field .. ".kantoSelection must preserve post-category override order", context)
  end
  SchemaCheck.checkRecord(introMusic.kantoSelection.routes, nil, context, code, field .. ".kantoSelection.routes")
  for _, route in pairs(introMusic.kantoSelection.routes) do
    checkString(route, context, code, field .. ".kantoSelection.routes")
  end
  SchemaCheck.checkRecord(
    introMusic.selectionRules,
    { trainer = true, wild = true },
    context,
    code,
    field .. ".selectionRules"
  )
  SchemaCheck.checkRecord(
    introMusic.selectionRules.trainer,
    { predicate = true, classSource = true, categorySource = true, modifiers = true },
    context,
    code,
    field .. ".selectionRules.trainer"
  )
  SchemaCheck.checkRecord(
    introMusic.selectionRules.wild,
    { predicate = true, speciesSource = true, specialSetupCase = true, modifier = true },
    context,
    code,
    field .. ".selectionRules.wild"
  )
  checkStringArray(
    introMusic.selectionRules.trainer.modifiers,
    context,
    code,
    field .. ".selectionRules.trainer.modifiers"
  )
  for _, rule in ipairs({
    introMusic.selectionRules.trainer.predicate,
    introMusic.selectionRules.trainer.classSource,
    introMusic.selectionRules.trainer.categorySource,
    introMusic.selectionRules.wild.predicate,
    introMusic.selectionRules.wild.speciesSource,
    introMusic.selectionRules.wild.specialSetupCase,
    introMusic.selectionRules.wild.modifier,
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
  checkSequenceKey(selection.sequenceKey, field .. ".selectionSound.sequenceKey")
end

local function checkAudioRoles(roles, context, code, field)
  SchemaCheck.checkRecord(roles, {
    wild = true,
    trainer = true,
    rival = true,
    select = true,
    gymLeader = true,
    rocket = true,
    suicune = true,
    entei = true,
    raikou = true,
    champion = true,
    kantoWild = true,
    kantoTrainer = true,
    kantoGymLeader = true,
    cries = true,
    introMusic = true,
  }, context, code, field)
  for _, role in ipairs({
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
  }) do
    checkString(roles[role], context, code, field .. "." .. role)
  end
  checkString(roles.cries, context, code, field .. ".cries")
  checkIntroMusic(roles.introMusic, context, code, field .. ".introMusic")
end

-- The staged global manifest: source-normalized catalogs grouped by the
-- runtime owner that consumes each role. Physical IDs stay producer-only.
function BattlePresentationSchema.assertManifest(manifest)
  local context = {}
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
    menus = true,
    messages = true,
    transitions = true,
    audioRoles = true,
    programs = true,
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
  for _, section in ipairs({ "layouts", "messages", "transitions" }) do
    checkCatalogTable(manifest[section], context, CODE_MANIFEST, "manifest " .. section)
    if next(manifest[section]) == nil then
      fail(CODE_MANIFEST, "manifest " .. section .. " must carry source-backed entries", context)
    end
  end
  checkNoNativeKeys(manifest.layouts, context, CODE_MANIFEST, "manifest layouts")

  SchemaCheck.checkRecord(manifest.menus, {
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
  checkCatalogTable(manifest.menus.routes, context, CODE_MANIFEST, "manifest menus.routes")
  for routeKey, route in pairs(manifest.menus.routes) do
    local field = "manifest menus.routes[" .. routeKey .. "]"
    SchemaCheck.checkRecord(route, {
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
    }, context, CODE_MANIFEST, field)
    for _, listName in ipairs({
      "messageEntries",
      "messageRoutes",
      "fontRoles",
      "assetRoles",
      "requiredContext",
      "resources",
    }) do
      checkStringArray(route[listName], context, CODE_MANIFEST, field .. "." .. listName)
    end
    SchemaCheck.checkRecord(route.assetBindings, nil, context, CODE_MANIFEST, field .. ".assetBindings")
    for role, binding in pairs(route.assetBindings) do
      local roleDeclared = false
      for _, assetRole in ipairs(route.assetRoles) do
        roleDeclared = roleDeclared or assetRole == role
      end
      if not roleDeclared then
        fail(CODE_MANIFEST, field .. ".assetBindings contains an undeclared asset role", context)
      end
      SchemaCheck.checkRecord(
        binding,
        { catalog = true, selector = true, context = true, when = true },
        context,
        CODE_MANIFEST,
        field .. ".assetBindings[" .. role .. "]"
      )
      if role ~= "pokemonIcon" or binding.catalog ~= "mon-icons" or binding.selector ~= "species-form" then
        fail(CODE_MANIFEST, field .. ".assetBindings contains an unsupported dynamic asset selector", context)
      end
      checkStringArray(binding.context, context, CODE_MANIFEST, field .. ".assetBindings[" .. role .. "].context")
      if #binding.context ~= 2 then
        fail(CODE_MANIFEST, field .. ".assetBindings[" .. role .. "] must select by species and form", context)
      end
      for _, contextField in ipairs(binding.context) do
        checkString(contextField, context, CODE_MANIFEST, field .. ".assetBindings[" .. role .. "].context")
      end
      checkString(binding.when, context, CODE_MANIFEST, field .. ".assetBindings[" .. role .. "].when")
      if
        (binding.context[1] == "bugContest.caughtPokemon.species" and binding.when ~= "caught-mon-present")
        or (binding.context[1] == "targetSelection.candidate.species" and binding.when ~= "candidate-enabled-and-hit")
      then
        fail(CODE_MANIFEST, field .. ".assetBindings has a mismatched source context", context)
      end
    end
    for _, role in ipairs(route.assetRoles) do
      if role == "pokemonIcon" and route.assetBindings[role] == nil then
        fail(CODE_MANIFEST, field .. ".assetRoles requires a semantic pokemonIcon binding", context)
      end
    end
    for _, messageKey in ipairs(route.messageEntries) do
      if manifest.messages.entries[messageKey] == nil then
        fail(CODE_MANIFEST, field .. ".messageEntries references no staged message", context)
      end
    end
    for _, messageRoute in ipairs(route.messageRoutes) do
      if
        manifest.messages.routes[messageRoute] == nil
        and manifest.messages.sourceRoutes[messageRoute] == nil
        and manifest.messages.dynamicRoutes[messageRoute] == nil
      then
        fail(CODE_MANIFEST, field .. ".messageRoutes references no source route", context)
      end
    end
    for _, fontRole in ipairs(route.fontRoles) do
      if manifest.messages.roles[fontRole] == nil then
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
  for routeKey in pairs(manifest.menus.selectors) do
    if manifest.menus.routes[routeKey] == nil then
      fail(CODE_MANIFEST, "manifest menus.routes is missing selector route " .. routeKey, context)
    end
  end
  SchemaCheck.checkRecord(manifest.menus.images, nil, context, CODE_MANIFEST, "manifest menus.images")
  if next(manifest.menus.images) == nil then
    fail(CODE_MANIFEST, "manifest menus.images must inventory staged image payloads", context)
  end
  SchemaCheck.checkRecord(
    manifest.menus.layouts,
    { frontier = true, vsRecorder = true, bugContest = true },
    context,
    CODE_MANIFEST,
    "manifest menus.layouts"
  )
  SchemaCheck.checkRecord(
    manifest.menus.layouts.frontier,
    { image = true, character = true, palette = true, tilemap = true, touchPalette = true },
    context,
    CODE_MANIFEST,
    "manifest menus.layouts.frontier"
  )
  checkImagePath(manifest.menus.layouts.frontier.image, context, CODE_MANIFEST, "manifest menus.layouts.frontier.image")
  SchemaCheck.checkRecord(
    manifest.menus.layouts.vsRecorder,
    { image = true, tilemap = true },
    context,
    CODE_MANIFEST,
    "manifest menus.layouts.vsRecorder"
  )
  checkImagePath(
    manifest.menus.layouts.vsRecorder.image,
    context,
    CODE_MANIFEST,
    "manifest menus.layouts.vsRecorder.image"
  )
  for _, layout in ipairs({ manifest.menus.layouts.frontier, manifest.menus.layouts.vsRecorder }) do
    checkString(layout.tilemap, context, CODE_MANIFEST, "manifest menu layout tilemap key")
    if manifest.resources[layout.tilemap] == nil or manifest.resources[layout.tilemap].kind ~= "map" then
      fail(CODE_MANIFEST, "manifest menu layout references no source-decoded tilemap", context)
    end
  end
  for _, slot in ipairs({ "character", "palette" }) do
    local resourceKey = manifest.menus.layouts.frontier[slot]
    checkString(resourceKey, context, CODE_MANIFEST, "manifest Frontier " .. slot .. " key")
    if
      manifest.resources[resourceKey] == nil
      or manifest.resources[resourceKey].kind ~= (slot == "character" and "texture" or "palette")
    then
      fail(CODE_MANIFEST, "manifest Frontier layout references no source-decoded " .. slot, context)
    end
  end
  checkString(
    manifest.menus.layouts.frontier.touchPalette,
    context,
    CODE_MANIFEST,
    "manifest Frontier touch palette key"
  )
  if
    manifest.resources[manifest.menus.layouts.frontier.touchPalette] == nil
    or manifest.resources[manifest.menus.layouts.frontier.touchPalette].kind ~= "palette"
  then
    fail(CODE_MANIFEST, "manifest Frontier layout references no decoded touch palette", context)
  end
  local bugContest = manifest.menus.layouts.bugContest
  SchemaCheck.checkRecord(
    bugContest,
    { character = true, palette = true, cell = true, animation = true, sprites = true },
    context,
    CODE_MANIFEST,
    "manifest menus.layouts.bugContest"
  )
  for slot, kind in pairs({ character = "texture", palette = "palette", cell = "cell", animation = "animation" }) do
    checkString(bugContest[slot], context, CODE_MANIFEST, "manifest Bug Contest " .. slot .. " key")
    if manifest.resources[bugContest[slot]] == nil or manifest.resources[bugContest[slot]].kind ~= kind then
      fail(CODE_MANIFEST, "manifest Bug Contest layout references no decoded " .. slot, context)
    end
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
    SchemaCheck.checkRecord(
      sprite,
      { x = true, y = true, palette = true, animation = true },
      context,
      CODE_MANIFEST,
      "manifest Bug Contest " .. role
    )
    checkInt(sprite.x, 0, 255, context, CODE_MANIFEST, "manifest Bug Contest " .. role .. ".x")
    checkInt(sprite.y, 0, 191, context, CODE_MANIFEST, "manifest Bug Contest " .. role .. ".y")
    checkInt(sprite.palette, 0, 15, context, CODE_MANIFEST, "manifest Bug Contest " .. role .. ".palette")
    checkInt(sprite.animation, 0, nil, context, CODE_MANIFEST, "manifest Bug Contest " .. role .. ".animation")
  end
  for _, field in ipairs({ "roles", "selectors" }) do
    checkCatalogTable(manifest.menus[field], context, CODE_MANIFEST, "manifest menus." .. field)
    if next(manifest.menus[field]) == nil then
      fail(CODE_MANIFEST, "manifest menus." .. field .. " must carry source-backed entries", context)
    end
  end
  checkMenuModeRules(
    manifest.menus.modeRules,
    manifest.messages.entries,
    context,
    CODE_MANIFEST,
    "manifest menus.modeRules"
  )
  checkMenuRuntimeContexts(manifest.menus.runtimeContexts, context, CODE_MANIFEST, "manifest menus.runtimeContexts")
  checkMenuContexts(
    manifest.menus.contexts,
    manifest.messages.entries,
    manifest.messages.routes,
    context,
    CODE_MANIFEST,
    "manifest menus.contexts"
  )
  SchemaCheck.checkRecord(
    manifest.menus.runLabelSelector,
    { cancel = true, ordinary = true },
    context,
    CODE_MANIFEST,
    "manifest menus.runLabelSelector"
  )
  for _, key in pairs(manifest.menus.runLabelSelector) do
    checkString(key, context, CODE_MANIFEST, "manifest menus.runLabelSelector key")
    if manifest.messages.entries[key] == nil then
      fail(CODE_MANIFEST, "manifest menus.runLabelSelector references no message record", context)
    end
  end
  for path, geometry in pairs(manifest.menus.images) do
    checkString(path, context, CODE_MANIFEST, "manifest menus image path")
    SchemaCheck.checkRecord(
      geometry,
      { width = true, height = true },
      context,
      CODE_MANIFEST,
      "manifest menus image " .. path
    )
    checkInt(geometry.width, 1, nil, context, CODE_MANIFEST, "manifest menus image " .. path .. " width")
    checkInt(geometry.height, 1, nil, context, CODE_MANIFEST, "manifest menus image " .. path .. " height")
  end
  local function checkImageRef(path, field)
    if manifest.menus.images[path] == nil then
      fail(CODE_MANIFEST, field .. " references an unstaged image: " .. tostring(path), context)
    end
  end
  for _, layout in ipairs({ manifest.menus.layouts.frontier, manifest.menus.layouts.vsRecorder }) do
    checkImageRef(layout.image, "manifest menu layout image")
  end
  for _, field in ipairs({ "command", "moves", "target", "twoOption" }) do
    checkMenuSection(manifest.menus[field], context, CODE_MANIFEST, "manifest menus." .. field)
  end
  SchemaCheck.checkRecord(
    manifest.menus.lower,
    { image = true, palette = true, variants = true },
    context,
    CODE_MANIFEST,
    "manifest menus.lower"
  )
  checkImagePath(manifest.menus.lower.image, context, CODE_MANIFEST, "manifest menus.lower image")
  checkImageRef(manifest.menus.lower.image, "manifest menus.lower image")
  checkPalette(manifest.menus.lower.palette, context, CODE_MANIFEST, "manifest menus.lower palette")
  SchemaCheck.checkRecord(manifest.menus.lower.variants, nil, context, CODE_MANIFEST, "manifest menus.lower variants")
  local variantCount = 0
  for background, variant in pairs(manifest.menus.lower.variants) do
    variantCount = variantCount + 1
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
  if variantCount == 0 then
    fail(CODE_MANIFEST, "manifest menus.lower must carry its background variants", context)
  end
  SchemaCheck.checkRecord(manifest.hud, {
    player = true,
    enemy = true,
    doubles = true,
    arrow = true,
    partyGauges = true,
    terrain = true,
    roles = true,
    selectors = true,
    patchSpans = true,
  }, context, CODE_MANIFEST, "manifest hud")
  checkHudPatchSpans(manifest.hud.patchSpans, context, CODE_MANIFEST, "manifest hud.patchSpans")
  checkSpriteSection(manifest.hud.player, context, CODE_MANIFEST, "manifest hud.player")
  checkSpriteSection(manifest.hud.enemy, context, CODE_MANIFEST, "manifest hud.enemy")
  local function checkHudComponents(section, field)
    if section.componentBase == nil or section.componentCount ~= 78 then
      fail(CODE_MANIFEST, field .. " must append the 78 source health-box components", context)
    end
  end
  checkHudComponents(manifest.hud.player, "manifest hud.player")
  checkHudComponents(manifest.hud.enemy, "manifest hud.enemy")
  SchemaCheck.checkRecord(
    manifest.hud.doubles,
    { playerLeft = true, playerRight = true, enemyLeft = true, enemyRight = true },
    context,
    CODE_MANIFEST,
    "manifest hud.doubles"
  )
  for _, slot in ipairs({ "playerLeft", "playerRight", "enemyLeft", "enemyRight" }) do
    checkSpriteSection(manifest.hud.doubles[slot], context, CODE_MANIFEST, "manifest hud.doubles " .. slot)
    checkHudComponents(manifest.hud.doubles[slot], "manifest hud.doubles " .. slot)
  end
  checkSpriteSection(manifest.hud.arrow, context, CODE_MANIFEST, "manifest hud.arrow")
  for _, field in ipairs({ "roles", "selectors" }) do
    checkCatalogTable(manifest.hud[field], context, CODE_MANIFEST, "manifest hud." .. field)
    if next(manifest.hud[field]) == nil then
      fail(CODE_MANIFEST, "manifest hud." .. field .. " must carry source-backed entries", context)
    end
  end
  if not Validate.isArray(manifest.hud.partyGauges) or #manifest.hud.partyGauges ~= 2 then
    fail(CODE_MANIFEST, "manifest must carry both party gauge families", context)
  end
  for index, family in ipairs(manifest.hud.partyGauges) do
    checkSpriteSection(family, context, CODE_MANIFEST, "manifest hud.partyGauges[" .. index .. "]")
  end
  -- Terrain bake inputs are producer metadata, not staged sprites: the
  -- shared per-type cells and animation without an image or palette.
  SchemaCheck.checkRecord(
    manifest.hud.terrain,
    { type0 = true, type1 = true },
    context,
    CODE_MANIFEST,
    "manifest hud.terrain"
  )
  checkTerrainSection(manifest.hud.terrain.type0, context, CODE_MANIFEST, "manifest hud.terrain type0")
  checkTerrainSection(manifest.hud.terrain.type1, context, CODE_MANIFEST, "manifest hud.terrain type1")
  for _, field in ipairs({ "command", "moves", "target", "twoOption" }) do
    local section = manifest.menus[field]
    checkImageRef(section.image, "manifest menus." .. field .. " image")
    for index, screen in ipairs(section.screens) do
      checkImageRef(screen.image, "manifest menus." .. field .. " screen " .. index)
    end
  end
  for _, field in ipairs({ "player", "enemy", "arrow" }) do
    checkImageRef(manifest.hud[field].image, "manifest hud." .. field .. " image")
  end
  for _, slot in ipairs({ "playerLeft", "playerRight", "enemyLeft", "enemyRight" }) do
    checkImageRef(manifest.hud.doubles[slot].image, "manifest hud.doubles " .. slot .. " image")
  end
  for index, family in ipairs(manifest.hud.partyGauges) do
    checkImageRef(family.image, "manifest hud.partyGauges[" .. index .. "] image")
  end

  SchemaCheck.checkRecord(
    manifest.pictures,
    { attributes = true, selectors = true, shadow = true },
    context,
    CODE_MANIFEST,
    "manifest pictures"
  )
  checkPictureAttributes(manifest.pictures.attributes, context, CODE_MANIFEST, "manifest pictures.attributes")
  checkCatalogTable(manifest.pictures.selectors, context, CODE_MANIFEST, "manifest pictures.selectors")
  if next(manifest.pictures.selectors) == nil then
    fail(CODE_MANIFEST, "manifest pictures.selectors must carry source-backed entries", context)
  end
  SchemaCheck.checkRecord(
    manifest.pictures.shadow,
    { image = true, width = true, height = true, regions = true },
    context,
    CODE_MANIFEST,
    "manifest pictures.shadow"
  )
  checkImageRef(manifest.pictures.shadow.image, "manifest pictures.shadow image")
  local shadowImage = manifest.menus.images[manifest.pictures.shadow.image]
  if manifest.pictures.shadow.width ~= 64 or manifest.pictures.shadow.height ~= 64 then
    fail(CODE_MANIFEST, "manifest pictures.shadow must preserve the native 64x64 selector atlas", context)
  end
  if shadowImage.width ~= manifest.pictures.shadow.width or shadowImage.height ~= manifest.pictures.shadow.height then
    fail(CODE_MANIFEST, "manifest pictures.shadow geometry must match its staged image", context)
  end
  if not Validate.isArray(manifest.pictures.shadow.regions) or #manifest.pictures.shadow.regions ~= 4 then
    fail(CODE_MANIFEST, "manifest pictures.shadow.regions must contain four source size selections", context)
  end
  local shadowSizes = {}
  for index, region in ipairs(manifest.pictures.shadow.regions) do
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
  SchemaCheck.checkRecord(manifest.messages, {
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
  checkTextRoles(manifest.messages.roles, context, CODE_MANIFEST, "manifest messages.roles")
  checkCatalogTable(manifest.messages.entries, context, CODE_MANIFEST, "manifest messages.entries")
  if next(manifest.messages.entries) == nil then
    fail(CODE_MANIFEST, "manifest messages.entries must carry source-backed records", context)
  end
  checkMessageRoutes(
    manifest.messages.routes,
    manifest.messages.entries,
    context,
    CODE_MANIFEST,
    "manifest messages.routes"
  )
  checkMessageBankReferences(
    manifest.messages.banks,
    manifest.resources,
    context,
    CODE_MANIFEST,
    "manifest messages.banks"
  )
  checkMessageDynamicRoutes(
    manifest.messages.dynamicRoutes,
    manifest.messages.banks,
    manifest.messages.entries,
    manifest.resources,
    context,
    CODE_MANIFEST,
    "manifest messages.dynamicRoutes"
  )
  checkMessageBankReferences(
    manifest.messages.placeholderBanks,
    manifest.resources,
    context,
    CODE_MANIFEST,
    "manifest messages.placeholderBanks"
  )
  checkMessageSourceRoutes(
    manifest.messages.sourceRoutes,
    manifest.messages.banks,
    manifest.messages.dynamicRoutes,
    manifest.messages.routes,
    manifest.resources,
    manifest.messages.tagSchemas,
    manifest.messages.tagInputs,
    manifest.messages.placeholders,
    manifest.messages.templateInputs,
    context,
    CODE_MANIFEST,
    "manifest messages.sourceRoutes"
  )
  checkMessagePlaceholders(
    manifest.messages.placeholders,
    manifest.messages.placeholderBanks,
    context,
    CODE_MANIFEST,
    "manifest messages.placeholders"
  )
  checkCatalogTable(manifest.messages.tagSchemas, context, CODE_MANIFEST, "manifest messages.tagSchemas")
  for tag, slots in pairs(manifest.messages.tagSchemas) do
    checkString(tag, context, CODE_MANIFEST, "manifest messages.tagSchemas key")
    if tag:match("^TAG_") or not Validate.isArray(slots) then
      fail(CODE_MANIFEST, "manifest messages.tagSchemas must use normalized semantic tags and ordered slots", context)
    end
    for index, slot in ipairs(slots) do
      checkString(slot, context, CODE_MANIFEST, "manifest messages.tagSchemas[" .. tag .. "][" .. index .. "]")
    end
  end
  checkCatalogTable(manifest.messages.tagInputs, context, CODE_MANIFEST, "manifest messages.tagInputs")
  for role, input in pairs(manifest.messages.tagInputs) do
    SchemaCheck.checkRecord(
      input,
      { input = true, output = true, selection = true },
      context,
      CODE_MANIFEST,
      "manifest messages.tagInputs." .. role
    )
    checkString(role, context, CODE_MANIFEST, "manifest messages.tagInputs role")
    checkString(input.input, context, CODE_MANIFEST, "manifest messages.tagInputs." .. role .. ".input")
    checkString(input.output, context, CODE_MANIFEST, "manifest messages.tagInputs." .. role .. ".output")
    if input.selection ~= nil then
      if not Validate.isArray(input.selection) then
        fail(CODE_MANIFEST, "manifest messages.tagInputs selection must be ordered", context)
      end
      for index, selected in ipairs(input.selection) do
        checkString(
          selected,
          context,
          CODE_MANIFEST,
          "manifest messages.tagInputs." .. role .. ".selection[" .. index .. "]"
        )
      end
    end
  end
  checkCatalogTable(manifest.messages.templateInputs, context, CODE_MANIFEST, "manifest messages.templateInputs")
  for role, input in pairs(manifest.messages.templateInputs) do
    SchemaCheck.checkRecord(
      input,
      { input = true, dependency = true, supported = true, reason = true },
      context,
      CODE_MANIFEST,
      "manifest messages.templateInputs." .. role
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
      checkString(input.input, context, CODE_MANIFEST, "manifest messages.templateInputs." .. role .. ".input")
    end
    if input.dependency ~= nil then
      checkString(
        input.dependency,
        context,
        CODE_MANIFEST,
        "manifest messages.templateInputs." .. role .. ".dependency"
      )
    end
    if input.supported ~= nil and type(input.supported) ~= "boolean" then
      fail(CODE_MANIFEST, "manifest messages.templateInputs supported flag must be boolean", context)
    end
    if input.reason ~= nil then
      checkString(input.reason, context, CODE_MANIFEST, "manifest messages.templateInputs." .. role .. ".reason")
    end
  end
  SchemaCheck.checkRecord(
    manifest.messages.templateExpansion,
    { input = true },
    context,
    CODE_MANIFEST,
    "manifest messages.templateExpansion"
  )
  checkString(
    manifest.messages.templateExpansion.input,
    context,
    CODE_MANIFEST,
    "manifest messages.templateExpansion.input"
  )
  SchemaCheck.checkRecord(manifest.transitions, {
    selectors = true,
    resourceSets = true,
    resources = true,
    messageRoutes = true,
    internalResources = true,
    routes = true,
    selection = true,
  }, context, CODE_MANIFEST, "manifest transitions")
  checkCatalogTable(manifest.transitions, context, CODE_MANIFEST, "manifest transitions")
  if next(manifest.transitions) == nil then
    fail(CODE_MANIFEST, "manifest transitions must carry source-backed entries", context)
  end
  checkCatalogTable(manifest.transitions.selectors, context, CODE_MANIFEST, "manifest transitions.selectors")
  if next(manifest.transitions.selectors) == nil then
    fail(CODE_MANIFEST, "manifest transitions.selectors must carry source-backed routes", context)
  end
  checkTransitionRouteResources(
    manifest.transitions.messageRoutes,
    manifest.messages.entries,
    manifest.resources,
    context,
    CODE_MANIFEST,
    "manifest transitions.messageRoutes"
  )
  checkTransitionRoutes(
    manifest.transitions.routes,
    manifest.messages.entries,
    manifest.messages.routes,
    manifest.resources,
    context,
    CODE_MANIFEST,
    "manifest transitions.routes"
  )
  checkTransitionSelection(
    manifest.transitions.selection,
    manifest.transitions.routes,
    context,
    CODE_MANIFEST,
    "manifest transitions.selection"
  )
  checkTransitionInternalResources(
    manifest.transitions.internalResources,
    manifest.resources,
    context,
    CODE_MANIFEST,
    "manifest transitions.internalResources"
  )
  local fallback = manifest.transitions.selectors.setupFallback
  if fallback ~= nil then
    SchemaCheck.checkRecord(
      fallback,
      { inputs = true, terrainOffset = true, offsetTimes = true, trainerOffset = true, resolved = true },
      context,
      CODE_MANIFEST,
      "manifest transitions.selectors.setupFallback"
    )
    if
      not Validate.isArray(fallback.inputs)
      or #fallback.inputs ~= 3
      or fallback.inputs[1] ~= "battleType"
      or fallback.inputs[2] ~= "terrain"
      or fallback.inputs[3] ~= "timeOfDay"
    then
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
    if
      not Validate.isArray(fallback.offsetTimes)
      or #fallback.offsetTimes ~= 2
      or fallback.offsetTimes[1] ~= "night"
      or fallback.offsetTimes[2] ~= "late"
    then
      fail(CODE_MANIFEST, "setup fallback must preserve its night and late offsets", context)
    end
    checkInt(fallback.trainerOffset, 6, 6, context, CODE_MANIFEST, "setup fallback trainer offset")
    if fallback.resolved ~= false then
      fail(CODE_MANIFEST, "setup fallback stays unresolved until selector routes are closed", context)
    end
  end
  checkAudioRoles(manifest.audioRoles, context, CODE_MANIFEST, "manifest audioRoles")
  checkPrograms(manifest.programs, manifest.resources, context, CODE_MANIFEST, "manifest programs")
  checkCatalogResources(manifest.resources, context, CODE_MANIFEST, "manifest resources")
  for _, menuName in ipairs({ "command", "moves", "target", "twoOption" }) do
    for index, screen in ipairs(manifest.menus[menuName].screens) do
      local resource = manifest.resources[screen.tilemapKey]
      if resource == nil or resource.kind ~= "map" or resource.format ~= "nitro-bg-map-v1" then
        fail(
          CODE_MANIFEST,
          "manifest menus." .. menuName .. ".screens[" .. index .. "] references no decoded tilemap resource",
          context
        )
      end
    end
  end
  checkCoverage(
    manifest.coverage,
    manifest.programs,
    manifest.transitions,
    manifest.menus,
    manifest.messages,
    manifest.resources,
    context,
    CODE_MANIFEST,
    "manifest coverage"
  )
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
  }, context, CODE_SCENE, "scene")
  if scene.schema ~= BattlePresentationSchema.SCENE_SCHEMA then
    fail(CODE_SCENE, "scene schema must be " .. BattlePresentationSchema.SCENE_SCHEMA, context)
  end
  checkString(scene.key, context, CODE_SCENE, "scene key")
  if BACKGROUNDS[scene.background] == nil then
    fail(CODE_SCENE, "scene carries an unknown background: " .. tostring(scene.background), context)
  end
  if TERRAINS[scene.terrain] == nil then
    fail(CODE_SCENE, "scene carries an unknown terrain: " .. tostring(scene.terrain), context)
  end
  if TIMES[scene.time] == nil then
    fail(CODE_SCENE, "scene carries an unknown time: " .. tostring(scene.time), context)
  end
  if scene.key ~= scene.background .. "/" .. scene.terrain .. "/" .. scene.time then
    fail(CODE_SCENE, "scene key disagrees with its axes: " .. tostring(scene.key), context)
  end
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
  SchemaCheck.checkRecord(demand, { scenes = true, pages = true, audio = true }, context, CODE_DEMAND, "demand")
  checkStringList(demand.scenes, context, CODE_DEMAND, "demand scenes", false)
  for _, key in ipairs(demand.scenes) do
    local background, terrain, time = key:match("^([^/]+)/([^/]+)/([^/]+)$")
    if background == nil or BACKGROUNDS[background] == nil or TERRAINS[terrain] == nil or TIMES[time] == nil then
      fail(CODE_DEMAND, "demand carries an unknown scene key: " .. key, context)
    end
  end
  checkStringList(demand.pages, context, CODE_DEMAND, "demand pages", true)
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
