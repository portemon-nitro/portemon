-- Authoritative validation for the generated field-bag presentation class.
-- The manifest carries the upper-pane hero (gender backdrops, description
-- frame, gender hero models with pocket-indexed animation states, normalized
-- camera/transform/light facts, the eight-entry edge-color table) plus the
-- lower-pane controls (eight pocket
-- tabs with one 256x32 strip visual per active pocket, six item slots pairing
-- full touch rects with
-- text windows and explicit text anchors plus registration markers, the
-- semantic focus visuals with their canonical target points, the count
-- readout, Cancel with its text window and source-centered label area,
-- pocket-aware browse/action/quantity count backgrounds (seven realized
-- variants per pocket), pocket-aware move count/origin backgrounds, the
-- retained selected-item panel, short/tall lower-message geometry,
-- activation feedback timing with control visuals, unchanged/changed move
-- commit clips, original/candidate move target visuals, pocket-aware hero
-- framing records, semantic action
-- text/templates, and the action/quantity/move overlays with no standalone
-- confirmation surface). Every loader, producer
-- writer, and test calls these validators, so no second interpretation of
-- the shapes exists. Unknown fields, wrong pane sizes, out-of-bounds
-- geometry, wrong tab/slot cardinality, unresolvable animation states, and
-- leaked source identities fail loudly. Love-free and filesystem-free.

local Errors = require("libs.errors.src.Errors")
local Validate = require("libs.assets.src.Validate")
local SchemaCheck = require("libs.assets.src.SchemaCheck")
local ModelAsset = require("libs.assets.src.model.ModelAsset")

---@class BagAssetSchema
local BagAssetSchema = {}

BagAssetSchema.SCHEMA = "g4-bag-assets-v16"
BagAssetSchema.PANE_WIDTH = 256
BagAssetSchema.PANE_HEIGHT = 192
BagAssetSchema.TAB_COUNT = 8
BagAssetSchema.SLOT_COUNT = 6
BagAssetSchema.STATE_COUNT = 8

-- Source pocket keys in native order: hero animation states are selected by
-- this order.
BagAssetSchema.POCKETS = { "items", "medicine", "balls", "tmhm", "berries", "mail", "battle_items", "key_items" }

-- Pocket-key allowlist shared by every pocket-indexed manifest record.
local POCKET_SET = {}
for _, pocket in ipairs(BagAssetSchema.POCKETS) do
  POCKET_SET[pocket] = true
end

-- Producer-only identities that must never reach the runtime manifest.
local SOURCE_KEYS = {
  narcId = true,
  memberId = true,
  fileId = true,
  bgPriority = true,
  layer = true,
  cell = true,
  animIndex = true,
  paletteSlot = true,
  oam = true,
  template = true,
}

local function fail(message, context)
  SchemaCheck.fail("BAG_MANIFEST_INVALID", message, context)
end

local function checkKeys(record, allowed, context, what)
  SchemaCheck.checkKeys(record, allowed, context, "BAG_MANIFEST_INVALID", what)
end

-- One record guard for every manifest record: the value must be a table
-- carrying exactly the allowed keys. Adds no default empty tables.
local function checkRecord(value, allowed, context, what, noun)
  SchemaCheck.checkRecord(value, allowed, context, "BAG_MANIFEST_INVALID", what, noun)
end

-- One integer-range check shared by non-negative points/rectangles,
-- positive dimensions/cadences, and bounded channel fields. Signed offsets
-- and finite non-integral camera/model values keep their own domains.
local function checkInteger(value, context, what, minimum, maximum, expectation)
  SchemaCheck.checkInteger(value, context, "BAG_MANIFEST_INVALID", what, minimum, maximum, expectation)
end

-- One fixed-shape collection check for the manifest's exact-cardinality
-- arrays. The message keeps each site's distinct contract wording.
local function checkFixedArray(value, expected, context, message)
  if not Validate.isArray(value) or #value ~= expected then
    fail(message, context)
  end
end

local RECT_KEYS = { x = true, y = true, width = true, height = true }
local POINT_KEYS = { x = true, y = true }

local function checkRect(value, context, what)
  checkRecord(value, RECT_KEYS, context, what)
  for _, axis in ipairs({ "x", "y", "width", "height" }) do
    checkInteger(value[axis], context, what .. "." .. axis, 0, nil, "a non-negative integer")
  end
  if value.width == 0 or value.height == 0 then
    fail(what .. " must have positive dimensions", context)
  end
  if value.x + value.width > BagAssetSchema.PANE_WIDTH or value.y + value.height > BagAssetSchema.PANE_HEIGHT then
    fail(what .. " escapes the canonical pane", context)
  end
end

local function checkPoint(value, context, what)
  checkRecord(value, POINT_KEYS, context, what)
  for _, axis in ipairs({ "x", "y" }) do
    checkInteger(value[axis], context, what .. "." .. axis, 0, nil, "a non-negative integer")
  end
  if value.x > BagAssetSchema.PANE_WIDTH or value.y > BagAssetSchema.PANE_HEIGHT then
    fail(what .. " escapes the canonical pane", context)
  end
end

local IMAGE_KEYS = { image = true, width = true, height = true }
local VISUAL_KEYS = { image = true, width = true, height = true, offset = true }

-- Payload fields shared by exact image records and static visuals, checked
-- by borrowing the input table. The key domains stay distinct: only the
-- visual allowlist carries the optional offset.
local function checkImageFields(value, context, what)
  if type(value.image) ~= "string" or value.image == "" then
    fail(what .. ".image must be a non-empty path", context)
  end
  for _, axis in ipairs({ "width", "height" }) do
    checkInteger(value[axis], context, what .. "." .. axis, 1, nil, "a positive integer")
  end
end

local function checkImage(value, context, what)
  checkRecord(value, IMAGE_KEYS, context, what)
  checkImageFields(value, context, what)
end

local function checkOffset(value, context, what)
  checkRecord(value, POINT_KEYS, context, what)
  for _, axis in ipairs({ "x", "y" }) do
    if type(value[axis]) ~= "number" or value[axis] % 1 ~= 0 then
      fail(what .. "." .. axis .. " must be an integer", context)
    end
  end
end

-- Every runtime 2D visual is one static realized image with dimensions and
-- an optional blit offset. NANR selection happens producer-side; no frame
-- timeline, duration, or source identity reaches the manifest, except for
-- the Bag-local selection-entry sequence whose frames carry their source
-- durations under a dedicated validator below.
local function checkVisual(value, context, what)
  checkRecord(value, VISUAL_KEYS, context, what, "a semantic visual")
  checkImageFields(value, context, what)
  if value.offset ~= nil then
    checkOffset(value.offset, context, what .. ".offset")
  end
end

local function checkFinite(value, context, what)
  if type(value) ~= "number" or value ~= value or value >= math.huge or value <= -math.huge then
    fail(what .. " must be a finite number", context)
  end
end

---@alias BagTextSegment
---| { kind: "text", value: string }
---| { kind: "item" }
---| { kind: "quantity" }

-- Semantic action text and prompt templates. Labels are non-empty localized
-- strings keyed by runtime action; templates are non-empty contiguous
-- segment arrays over the closed text/item/quantity vocabulary. Adjacent
-- text segments must have been coalesced by the producer; only the toss
-- confirmation template may carry a quantity placeholder.
local TEXT_ACTIONS = {
  toss = true,
  move = true,
  register = true,
  unregister = true,
  cancel = true,
  confirm = true,
  use = true,
  give = true,
}

local function checkSegment(segment, context, what, allowedKinds)
  if type(segment) ~= "table" then
    fail(what .. " must be a record", context)
  end
  if type(segment.kind) ~= "string" or allowedKinds[segment.kind] ~= true then
    fail(what .. " carries an unsupported segment kind " .. tostring(segment.kind), context)
  end
  if segment.kind == "text" then
    checkKeys(segment, { kind = true, value = true }, context, what)
    if type(segment.value) ~= "string" or segment.value == "" then
      fail(what .. ".value must be a non-empty string", context)
    end
  else
    checkKeys(segment, { kind = true }, context, what)
  end
end

local TEMPLATE_KEYS = { segments = true }

local function checkTemplate(template, context, what, allowedKinds)
  checkRecord(template, TEMPLATE_KEYS, context, what)
  if not Validate.isArray(template.segments) or #template.segments == 0 then
    fail(what .. ".segments must be a non-empty contiguous array", context)
  end
  local sawItem, sawQuantity = false, false
  for index, segment in ipairs(template.segments) do
    checkSegment(segment, context, what .. ".segments[" .. index .. "]", allowedKinds)
    if segment.kind == "item" then
      sawItem = true
    elseif segment.kind == "quantity" then
      sawQuantity = true
    end
    if
      index > 1
      and segment.kind == "text"
      and type(template.segments[index - 1]) == "table"
      and template.segments[index - 1].kind == "text"
    then
      fail(what .. " carries adjacent text segments that must be coalesced", context)
    end
  end
  return sawItem, sawQuantity
end

-- The post-choice acknowledgement names the removed copies, so its template
-- must expand through both the picked amount and the selected item: a
-- text-only record cannot feed the acknowledgement presentation.
---@param template table<string, unknown>?
---@param context table<string, unknown>
local function checkTossResult(template, context)
  local quantityKinds = { text = true, item = true, quantity = true }
  local sawItem, sawQuantity = checkTemplate(template, context, "interactive.text.tossResult", quantityKinds)
  if not sawItem or not sawQuantity then
    fail("interactive.text.tossResult must name the removed item and quantity", context)
  end
end

local function checkText(text, context)
  checkRecord(text, {
    actions = true,
    movePrompt = true,
    tossConfirm = true,
    tossResult = true,
    selectedItem = true,
  }, context, "interactive.text")
  local actions = text.actions
  checkRecord(actions, TEXT_ACTIONS, context, "interactive.text.actions")
  for action in pairs(TEXT_ACTIONS) do
    if type(actions[action]) ~= "string" or actions[action] == "" then
      fail("interactive.text.actions." .. action .. " must be a non-empty label", context)
    end
  end
  local itemKinds = { text = true, item = true }
  local quantityKinds = { text = true, item = true, quantity = true }
  checkTemplate(text.movePrompt, context, "interactive.text.movePrompt", itemKinds)
  checkTemplate(text.tossConfirm, context, "interactive.text.tossConfirm", quantityKinds)
  checkTossResult(text.tossResult, context)
  checkTemplate(text.selectedItem, context, "interactive.text.selectedItem", itemKinds)
end

-- Registration-slot markers: two distinct 40x16 images with the slot-local
-- blit offset. The offset must keep the marker inside every canonical item
-- slot, so validation receives the already-checked slot records.
local REGISTRATION_WIDTH = 40
local REGISTRATION_HEIGHT = 16

local function checkRegistration(registration, slots, context)
  checkRecord(
    registration,
    { slot1 = true, slot2 = true, offset = true },
    context,
    "interactive.itemSlots.registration"
  )
  for _, slot in ipairs({ "slot1", "slot2" }) do
    checkImage(registration[slot], context, "interactive.itemSlots.registration." .. slot)
    if registration[slot].width ~= REGISTRATION_WIDTH or registration[slot].height ~= REGISTRATION_HEIGHT then
      fail("interactive.itemSlots.registration." .. slot .. " must be exactly 40x16", context)
    end
  end
  checkPoint(registration.offset, context, "interactive.itemSlots.registration.offset")
  for index, slot in ipairs(slots) do
    if
      registration.offset.x + REGISTRATION_WIDTH > slot.rect.width
      or registration.offset.y + REGISTRATION_HEIGHT > slot.rect.height
    then
      fail(
        "interactive.itemSlots.registration.offset escapes item slot " .. index .. " when applied slot-locally",
        context
      )
    end
  end
end

local function checkNoSourceIdentities(value, context, what)
  if type(value) ~= "table" then
    if type(value) == "string" and value:find("NARC_", 1, true) ~= nil then
      fail(what .. " carries a source archive symbol", context)
    end
    return
  end
  for key, item in pairs(value) do
    if SOURCE_KEYS[key] then
      fail(what .. " carries a source identity field " .. tostring(key), context)
    end
    checkNoSourceIdentities(item, context, what .. "." .. tostring(key))
  end
end

local function clipBySemantic(animations, semantic, context, what)
  local found = nil
  for _, clip in ipairs(animations) do
    if type(clip) == "table" and type(clip.semanticNames) == "table" then
      for _, name in ipairs(clip.semanticNames) do
        if name == semantic then
          if found ~= nil then
            fail(what .. " resolves to more than one clip", context)
          end
          found = clip
        end
      end
    end
  end
  if found == nil then
    fail(what .. " resolves to no clip", context)
  end
end

local function clipById(animations, id, context, what)
  for _, clip in ipairs(animations) do
    if type(clip) == "table" and clip.id == id then
      return
    end
  end
  fail(what .. " resolves to no clip", context)
end

local function checkModel(descriptor, context, what)
  local ok, err = pcall(ModelAsset.validate, descriptor)
  if not ok then
    if Errors.is(err) then
      fail(what .. " is invalid: " .. Errors.format(err), context)
    end
    error(err, 0)
  end
end

local function checkAnimations(animations, model, context)
  checkRecord(animations, { states = true, material = true }, context, "animations")
  checkFixedArray(
    animations.states,
    BagAssetSchema.STATE_COUNT,
    context,
    "animations.states must carry exactly eight pocket states"
  )
  local seen = {}
  for index, state in ipairs(animations.states) do
    local what = "animations.states[" .. index .. "]"
    checkRecord(state, { pocket = true, pose = true, pattern = true }, context, what)
    if type(state.pocket) ~= "string" or state.pocket == "" then
      fail(what .. ".pocket must be a non-empty key", context)
    end
    if seen[state.pocket] then
      fail("animations.states repeats pocket " .. state.pocket, context)
    end
    seen[state.pocket] = true
    if type(state.pose) ~= "string" or state.pose == "" then
      fail(what .. ".pose must be a non-empty clip name", context)
    end
    if type(state.pattern) ~= "string" or state.pattern == "" then
      fail(what .. ".pattern must be a non-empty clip name", context)
    end
    for _, gender in ipairs({ "male", "female" }) do
      local animationsList = model[gender].animations
      clipBySemantic(animationsList, state.pose, context, what .. ".pose for " .. gender)
      clipBySemantic(animationsList, state.pattern, context, what .. ".pattern for " .. gender)
    end
  end
  for _, pocket in ipairs(BagAssetSchema.POCKETS) do
    if not seen[pocket] then
      fail("animations.states is missing pocket " .. pocket, context)
    end
  end
  local material = animations.material
  checkRecord(material, { male = true, female = true }, context, "animations.material")
  for _, gender in ipairs({ "male", "female" }) do
    if type(material[gender]) ~= "string" or material[gender] == "" then
      fail("animations.material." .. gender .. " must be a non-empty clip id", context)
    end
    clipById(model[gender].animations, material[gender], context, "animations.material." .. gender)
  end
end

local function checkCamera(camera, context)
  checkRecord(camera, {
    target = true,
    distance = true,
    angleXDegrees = true,
    angleYDegrees = true,
    perspectiveType = true,
    perspectiveAngle = true,
    clipNear = true,
    clipFar = true,
  }, context, "presentation.camera")
  local target = camera.target
  checkRecord(target, { x = true, y = true, z = true }, context, "presentation.camera.target")
  checkFinite(target.x, context, "presentation.camera.target.x")
  checkFinite(target.y, context, "presentation.camera.target.y")
  checkFinite(target.z, context, "presentation.camera.target.z")
  checkFinite(camera.distance, context, "presentation.camera.distance")
  if camera.distance <= 0 then
    fail("presentation.camera.distance must be positive", context)
  end
  checkFinite(camera.angleXDegrees, context, "presentation.camera.angleXDegrees")
  checkFinite(camera.angleYDegrees, context, "presentation.camera.angleYDegrees")
  checkInteger(camera.perspectiveType, context, "presentation.camera.perspectiveType", 0, nil, "a non-negative integer")
  checkInteger(
    camera.perspectiveAngle,
    context,
    "presentation.camera.perspectiveAngle",
    0,
    nil,
    "a non-negative integer"
  )
  checkFinite(camera.clipNear, context, "presentation.camera.clipNear")
  checkFinite(camera.clipFar, context, "presentation.camera.clipFar")
  if camera.clipNear <= 0 or camera.clipFar <= camera.clipNear then
    fail("presentation.camera clipping range is invalid", context)
  end
end

local function checkTransform(transform, context)
  checkRecord(transform, { translation = true, rotation = true, scale = true }, context, "presentation.transform")
  for _, block in ipairs({ "translation", "scale" }) do
    if type(transform[block]) ~= "table" then
      fail("presentation.transform." .. block .. " must be a record", context)
    end
  end
  for _, axis in ipairs({ "x", "y", "z" }) do
    checkFinite(transform.translation[axis], context, "presentation.transform.translation." .. axis)
    checkFinite(transform.scale[axis], context, "presentation.transform.scale." .. axis)
  end
  checkFixedArray(transform.rotation, 9, context, "presentation.transform.rotation must carry nine matrix entries")
  for _, entry in ipairs(transform.rotation) do
    checkFinite(entry, context, "presentation.transform.rotation entry")
  end
end

local function checkLightVector(vector, context, what)
  checkRecord(vector, { x = true, y = true, z = true }, context, what)
  checkFinite(vector.x, context, what .. ".x")
  checkFinite(vector.y, context, what .. ".y")
  checkFinite(vector.z, context, what .. ".z")
end

local function checkLights(lights, context)
  checkRecord(lights, { count = true, color = true, vectors = true }, context, "hero.presentation.lights")
  if lights.count ~= 4 then
    fail("hero.presentation.lights.count must be exactly four", context)
  end
  if type(lights.color) ~= "table" then
    fail("hero.presentation.lights.color must be a record", context)
  end
  for _, channel in ipairs({ "r", "g", "b" }) do
    checkInteger(lights.color[channel], context, "hero.presentation.lights.color." .. channel, 0, 31, "0..31")
  end
  checkFixedArray(lights.vectors, 4, context, "hero.presentation.lights.vectors must carry exactly four light vectors")
  for index, vector in ipairs(lights.vectors) do
    checkLightVector(vector, context, "hero.presentation.lights.vectors[" .. index .. "]")
  end
end

local function checkMaterialRegister(register, context, what)
  checkRecord(register, { r = true, g = true, b = true }, context, what)
  for _, channel in ipairs({ "r", "g", "b" }) do
    checkInteger(register[channel], context, what .. "." .. channel, 0, 31, "0..31")
  end
end

local function checkMaterials(materials, context)
  checkRecord(materials, {
    diffuse = true,
    ambient = true,
    specular = true,
    emission = true,
  }, context, "hero.presentation.materials")
  for _, register in ipairs({ "diffuse", "ambient", "specular", "emission" }) do
    checkMaterialRegister(materials[register], context, "hero.presentation.materials." .. register)
  end
end

-- The retail hero edge-color table: exactly eight semantic 5-bit channel
-- records feeding the shared DS edge-marking renderer. Trailing black
-- entries are valid source data, not missing data.
local function checkEdgeColors(edgeColors, context)
  checkFixedArray(edgeColors, 8, context, "hero.presentation.edgeColors must carry exactly eight edge-color records")
  for index, record in ipairs(edgeColors) do
    checkMaterialRegister(record, context, "hero.presentation.edgeColors[" .. index .. "]")
  end
end

local function checkFramingRecord(record, context, what)
  checkRecord(record, { angleXDegrees = true, angleYDegrees = true, distance = true, modelY = true }, context, what)
  checkFinite(record.angleXDegrees, context, what .. ".angleXDegrees")
  checkFinite(record.angleYDegrees, context, what .. ".angleYDegrees")
  checkFinite(record.distance, context, what .. ".distance")
  checkFinite(record.modelY, context, what .. ".modelY")
end

-- Pocket-aware hero framing: the transition duration as plain pacing data,
-- one neutral baseline record per gender, and one record per canonical
-- pocket per gender. Transition progress stays runtime-owned; only these
-- immutable facts reach the manifest.
local function checkFraming(framing, context)
  checkRecord(
    framing,
    { transitionTicks = true, baseline = true, byGender = true },
    context,
    "hero.presentation.framing"
  )
  checkInteger(
    framing.transitionTicks,
    context,
    "hero.presentation.framing.transitionTicks",
    1,
    nil,
    "a positive integer"
  )
  local baseline = framing.baseline
  checkRecord(baseline, { male = true, female = true }, context, "hero.presentation.framing.baseline")
  local byGender = framing.byGender
  checkRecord(byGender, { male = true, female = true }, context, "hero.presentation.framing.byGender")
  for _, gender in ipairs({ "male", "female" }) do
    checkFramingRecord(baseline[gender], context, "hero.presentation.framing.baseline." .. gender)
    local pockets = byGender[gender]
    checkRecord(pockets, POCKET_SET, context, "hero.presentation.framing.byGender." .. gender, "a pocket record")
    for _, pocket in ipairs(BagAssetSchema.POCKETS) do
      checkFramingRecord(pockets[pocket], context, "hero.presentation.framing.byGender." .. gender .. "." .. pocket)
    end
  end
end

local function checkHero(hero, context)
  checkRecord(hero, {
    background = true,
    description = true,
    moveSummary = true,
    model = true,
    animations = true,
    presentation = true,
  }, context, "hero")
  local background = hero.background
  checkRecord(background, { male = true, female = true }, context, "hero.background")
  checkImage(background.male, context, "hero.background.male")
  checkImage(background.female, context, "hero.background.female")
  local description = hero.description
  checkRecord(description, { frame = true, textRect = true }, context, "hero.description")
  if type(description.frame) ~= "table" then
    fail("hero.description.frame must be a record", context)
  end
  checkKeys(description.frame, { image = true, rect = true }, context, "hero.description.frame")
  if type(description.frame.image) ~= "string" or description.frame.image == "" then
    fail("hero.description.frame.image must be a non-empty path", context)
  end
  checkRect(description.frame.rect, context, "hero.description.frame.rect")
  checkRect(description.textRect, context, "hero.description.textRect")
  local summary = hero.moveSummary
  checkRecord(summary, {
    background = true,
    labels = true,
    text = true,
    typeCenter = true,
    categoryCenter = true,
    typeIcons = true,
    categoryIcons = true,
  }, context, "hero.moveSummary")
  checkImage(summary.background, context, "hero.moveSummary.background")
  local labels = summary.labels
  checkRecord(labels, {
    type = true,
    pp = true,
    category = true,
    power = true,
    accuracy = true,
    unavailable = true,
  }, context, "hero.moveSummary.labels")
  for _, key in ipairs({ "type", "pp", "category", "power", "accuracy", "unavailable" }) do
    if type(labels[key]) ~= "string" or labels[key] == "" then
      fail("hero.moveSummary.labels." .. key .. " must be text", context)
    end
  end
  local text = summary.text
  checkRecord(text, {
    type = true,
    pp = true,
    category = true,
    power = true,
    accuracy = true,
    ppValue = true,
    powerValue = true,
    accuracyValue = true,
  }, context, "hero.moveSummary.text")
  for _, key in ipairs({ "type", "pp", "category", "power", "accuracy", "ppValue", "powerValue", "accuracyValue" }) do
    checkPoint(text[key], context, "hero.moveSummary.text." .. key)
  end
  checkPoint(summary.typeCenter, context, "hero.moveSummary.typeCenter")
  checkPoint(summary.categoryCenter, context, "hero.moveSummary.categoryCenter")
  local function checkIconMap(value, keys, what)
    if type(value) ~= "table" then
      fail(what .. " must be a record", context)
    end
    local allowed = {}
    for _, key in ipairs(keys) do
      allowed[key] = true
    end
    checkKeys(value, allowed, context, what)
    for _, key in ipairs(keys) do
      checkVisual(value[key], context, what .. "." .. key)
    end
  end
  checkIconMap(summary.typeIcons, {
    "normal",
    "fighting",
    "flying",
    "poison",
    "ground",
    "rock",
    "bug",
    "ghost",
    "steel",
    "mystery",
    "fire",
    "water",
    "grass",
    "electric",
    "psychic",
    "ice",
    "dragon",
    "dark",
  }, "hero.moveSummary.typeIcons")
  checkIconMap(summary.categoryIcons, { "physical", "special", "status" }, "hero.moveSummary.categoryIcons")
  local model = hero.model
  checkRecord(model, { male = true, female = true }, context, "hero.model")
  checkModel(model.male, context, "hero.model.male")
  checkModel(model.female, context, "hero.model.female")
  checkAnimations(hero.animations, model, context)
  local presentation = hero.presentation
  checkRecord(presentation, {
    camera = true,
    transform = true,
    lights = true,
    materials = true,
    framing = true,
    edgeColors = true,
  }, context, "hero.presentation")
  checkCamera(presentation.camera, context)
  checkTransform(presentation.transform, context)
  checkLights(presentation.lights, context)
  checkMaterials(presentation.materials, context)
  checkFraming(presentation.framing, context)
  checkEdgeColors(presentation.edgeColors, context)
end

local function checkLocalPoint(value, bounds, context, what)
  checkRecord(value, POINT_KEYS, context, what)
  for _, axis in ipairs({ "x", "y" }) do
    checkInteger(value[axis], context, what .. "." .. axis, 0, nil, "a non-negative integer")
  end
  local limit = { x = bounds.width, y = bounds.height }
  for _, axis in ipairs({ "x", "y" }) do
    if value[axis] > limit[axis] then
      fail(what .. "." .. axis .. " escapes its text window", context)
    end
  end
end

local function checkContained(inner, outer, context, what)
  if
    inner.x < outer.x
    or inner.y < outer.y
    or inner.x + inner.width > outer.x + outer.width
    or inner.y + inner.height > outer.y + outer.height
  then
    fail(what .. " escapes its containing rect", context)
  end
end

-- Semantic focus: one static source-derived visual per focus class with the
-- canonical target points the visual is drawn at. Tab/item/action classes
-- carry target arrays of exact cardinality; Cancel carries one target
-- point. No animation timeline or source identity reaches the manifest.
local function checkFocusTargets(targets, expected, context, what)
  checkFixedArray(targets, expected, context, what .. " must carry exactly " .. expected .. " target points")
  for index, target in ipairs(targets) do
    checkPoint(target, context, what .. "[" .. index .. "]")
  end
end

local function checkFocusClass(class, expected, context, what)
  checkRecord(class, { visual = true, targets = true }, context, what)
  checkVisual(class.visual, context, what .. ".visual")
  checkFocusTargets(class.targets, expected, context, what .. ".targets")
end

local function checkFocus(focus, context)
  checkRecord(focus, { tabs = true, items = true, cancel = true, actions = true }, context, "interactive.focus")
  checkFocusClass(focus.tabs, BagAssetSchema.TAB_COUNT, context, "interactive.focus.tabs")
  checkFocusClass(focus.items, BagAssetSchema.SLOT_COUNT, context, "interactive.focus.items")
  local cancel = focus.cancel
  checkRecord(cancel, { visual = true, target = true }, context, "interactive.focus.cancel")
  checkVisual(cancel.visual, context, "interactive.focus.cancel.visual")
  checkPoint(cancel.target, context, "interactive.focus.cancel.target")
  checkFocusClass(focus.actions, 4, context, "interactive.focus.actions")
end

-- The modal confirmation placement is plain layout data: the compact
-- prompt at a non-negative integral position with a supported initial
-- selection opens the destructive confirmation.
---@param prompt table<string, unknown>
---@param context table<string, unknown>
local function checkTossPrompt(prompt, context)
  checkRecord(
    prompt,
    { x = true, y = true, shape = true, initialSelection = true },
    context,
    "interactive.overlays.tossPrompt"
  )
  for _, axis in ipairs({ "x", "y" }) do
    checkInteger(prompt[axis], context, "interactive.overlays.tossPrompt." .. axis, 0, nil, "a non-negative integer")
  end
  if prompt.shape ~= "compact" then
    fail("interactive.overlays.tossPrompt must use the compact prompt shape", context)
  end
  if prompt.initialSelection ~= "yes" and prompt.initialSelection ~= "no" then
    fail("interactive.overlays.tossPrompt must preselect a supported choice", context)
  end
end

-- One realized count-variant background: a static visual using the
-- canonical pane size.
local function checkCountBackground(visual, visualWhat, context)
  checkVisual(visual, context, visualWhat)
  if visual.width ~= BagAssetSchema.PANE_WIDTH or visual.height ~= BagAssetSchema.PANE_HEIGHT then
    fail(visualWhat .. " must use the canonical pane size", context)
  end
end

local COUNT_KEYS = { [0] = true, [1] = true, [2] = true, [3] = true, [4] = true, [5] = true, [6] = true }

-- Lower-pane backgrounds: seven browse count variants per pocket (an
-- array), seven action and quantity count variants per pocket (keyed by
-- visible count 0..6), and seven move count variants per pocket each
-- carrying the origin-absent variant plus one variant per visible
-- original-item cell. No standalone confirmation surface survives.
local function checkPaneBackgrounds(backgrounds, context)
  checkRecord(backgrounds, {
    browse = true,
    action = true,
    quantity = true,
    move = true,
  }, context, "interactive.backgrounds")
  for _, state in ipairs({ "action", "quantity" }) do
    local pockets = backgrounds[state]
    local what = "interactive.backgrounds." .. state
    checkRecord(pockets, POCKET_SET, context, what, "a pocket record")
    for _, pocket in ipairs(BagAssetSchema.POCKETS) do
      local perPocket = pockets[pocket]
      local pocketWhat = what .. "." .. pocket
      checkRecord(perPocket, COUNT_KEYS, context, pocketWhat, "a visible-count record")
      for count = 0, 6 do
        checkCountBackground(perPocket[count], pocketWhat .. "[" .. count .. "]", context)
      end
    end
  end
  do
    local move = backgrounds.move
    local what = "interactive.backgrounds.move"
    checkRecord(move, POCKET_SET, context, what, "a pocket record")
    local originKeys =
      { none = true, ["0"] = true, ["1"] = true, ["2"] = true, ["3"] = true, ["4"] = true, ["5"] = true }
    for _, pocket in ipairs(BagAssetSchema.POCKETS) do
      local perPocket = move[pocket]
      local pocketWhat = what .. "." .. pocket
      checkRecord(perPocket, COUNT_KEYS, context, pocketWhat, "a visible-count record")
      for count = 0, 6 do
        local perCount = perPocket[count]
        local countWhat = pocketWhat .. "[" .. count .. "]"
        checkRecord(perCount, originKeys, context, countWhat, "a move-origin record")
        checkCountBackground(perCount.none, countWhat .. ".none", context)
        for _, origin in ipairs({ "0", "1", "2", "3", "4", "5" }) do
          checkCountBackground(perCount[origin], countWhat .. "[" .. origin .. "]", context)
        end
      end
    end
  end
  local browse = backgrounds.browse
  checkRecord(browse, POCKET_SET, context, "interactive.backgrounds.browse", "a pocket record")
  for _, pocket in ipairs(BagAssetSchema.POCKETS) do
    local what = "interactive.backgrounds.browse." .. pocket
    local variants = browse[pocket]
    checkFixedArray(variants, 7, context, what .. " must carry exactly seven count visuals")
    for index, visual in ipairs(variants) do
      checkVisual(visual, context, what .. "[" .. index .. "]")
      if visual.width ~= BagAssetSchema.PANE_WIDTH or visual.height ~= BagAssetSchema.PANE_HEIGHT then
        fail(what .. "[" .. index .. "] must use the canonical pane size", context)
      end
    end
  end
end

local function checkPocketTabs(pocketTabs, context)
  checkRecord(pocketTabs, { rects = true, strips = true }, context, "interactive.pocketTabs")
  checkFixedArray(
    pocketTabs.rects,
    BagAssetSchema.TAB_COUNT,
    context,
    "interactive.pocketTabs.rects must carry exactly eight tab rectangles"
  )
  for index, tab in ipairs(pocketTabs.rects) do
    checkRect(tab, context, "interactive.pocketTabs.rects[" .. index .. "]")
  end
  -- One final 256x32 strip visual per active pocket, carrying the persistent
  -- selected-pocket treatment independently of transient focus. Exactly the
  -- eight canonical pocket keys, no extras.
  checkRecord(pocketTabs.strips, POCKET_SET, context, "interactive.pocketTabs.strips", "a pocket record")
  for _, pocket in ipairs(BagAssetSchema.POCKETS) do
    local visual = pocketTabs.strips[pocket]
    local what = "interactive.pocketTabs.strips." .. pocket
    checkVisual(visual, context, what)
    if visual.width ~= 256 or visual.height ~= 32 then
      fail(what .. " must be exactly 256x32", context)
    end
  end
end

local function checkItemSlotList(itemSlots, context)
  checkRecord(itemSlots, { slots = true, registration = true }, context, "interactive.itemSlots")
  checkFixedArray(
    itemSlots.slots,
    BagAssetSchema.SLOT_COUNT,
    context,
    "interactive.itemSlots.slots must carry exactly six item slots"
  )
  for index, slot in ipairs(itemSlots.slots) do
    local what = "interactive.itemSlots.slots[" .. index .. "]"
    checkRecord(
      slot,
      { rect = true, textRect = true, iconCenter = true, nameAt = true, quantityAt = true },
      context,
      what
    )
    checkRect(slot.rect, context, what .. ".rect")
    checkRect(slot.textRect, context, what .. ".textRect")
    checkContained(slot.textRect, slot.rect, context, what .. ".textRect")
    checkPoint(slot.iconCenter, context, what .. ".iconCenter")
    checkLocalPoint(slot.nameAt, slot.textRect, context, what .. ".nameAt")
    checkLocalPoint(slot.quantityAt, slot.textRect, context, what .. ".quantityAt")
  end
end

-- Quantity stepper order fixed by the source layout: +100/+10/+1 then
-- -100/-10/-1.
local EXPECTED_QUANTITY_CONTROLS = {
  { delta = 100, role = "increment" },
  { delta = 10, role = "increment" },
  { delta = 1, role = "increment" },
  { delta = -100, role = "decrement" },
  { delta = -10, role = "decrement" },
  { delta = -1, role = "decrement" },
}

local function checkActionMenu(actionMenu, context)
  checkRecord(actionMenu, { face = true, slots = true }, context, "interactive.overlays.actionMenu")
  checkVisual(actionMenu.face, context, "interactive.overlays.actionMenu.face")
  checkFixedArray(
    actionMenu.slots,
    4,
    context,
    "interactive.overlays.actionMenu.slots must carry exactly four action slots"
  )
  for index, slot in ipairs(actionMenu.slots) do
    local what = "interactive.overlays.actionMenu.slots[" .. index .. "]"
    checkRecord(slot, { center = true, textRect = true, hitRect = true }, context, what)
    checkPoint(slot.center, context, what .. ".center")
    checkRect(slot.textRect, context, what .. ".textRect")
    checkRect(slot.hitRect, context, what .. ".hitRect")
  end
end

-- The browse-confirm selection entry: the Bag-local one-shot frame
-- sequence bridging browse confirmation and the stable action menu. Frame
-- count follows the source animation; each frame is one realized visual
-- with its positive source duration, playback stays once, and the total
-- is the exact duration sum the controller clock consumes.
local function checkSelectionEntry(entry, context)
  checkRecord(entry, { frames = true, playback = true, totalTicks = true }, context, "interactive.selectionEntry")
  if not Validate.isArray(entry.frames) or #entry.frames == 0 then
    fail("interactive.selectionEntry.frames must be a non-empty contiguous array", context)
  end
  if entry.playback ~= "once" then
    fail("interactive.selectionEntry.playback must be once", context)
  end
  local totalTicks = 0
  for index, frame in ipairs(entry.frames) do
    local what = "interactive.selectionEntry.frames[" .. index .. "]"
    if type(frame) ~= "table" then
      fail(what .. " must be a semantic visual", context)
    end
    checkRecord(
      frame,
      { image = true, width = true, height = true, offset = true, durationTicks = true },
      context,
      what
    )
    checkImageFields(frame, context, what)
    if frame.offset ~= nil then
      checkOffset(frame.offset, context, what .. ".offset")
    end
    checkInteger(frame.durationTicks, context, what .. ".durationTicks", 1, nil, "a positive integer")
    totalTicks = totalTicks + frame.durationTicks
  end
  checkInteger(entry.totalTicks, context, "interactive.selectionEntry.totalTicks", 1, nil, "a positive integer")
  if entry.totalTicks ~= totalTicks then
    fail("interactive.selectionEntry.totalTicks must equal its frame duration sum", context)
  end
end

local function checkQuantityOverlay(quantity, context)
  checkRecord(quantity, {
    digits = true,
    controls = true,
    visuals = true,
    pressTicks = true,
    confirm = true,
    cancel = true,
    cancelHitRect = true,
  }, context, "interactive.overlays.quantity")
  checkFixedArray(
    quantity.digits,
    3,
    context,
    "interactive.overlays.quantity.digits must carry exactly three digit rectangles"
  )
  for index, digit in ipairs(quantity.digits) do
    checkRect(digit, context, "interactive.overlays.quantity.digits[" .. index .. "]")
  end
  checkFixedArray(
    quantity.controls,
    #EXPECTED_QUANTITY_CONTROLS,
    context,
    "interactive.overlays.quantity.controls must carry exactly six controls"
  )
  for index, control in ipairs(quantity.controls) do
    local expected = EXPECTED_QUANTITY_CONTROLS[index]
    local what = "interactive.overlays.quantity.controls[" .. index .. "]"
    checkRecord(control, { delta = true, role = true, center = true, hitRect = true }, context, what)
    if control.delta ~= expected.delta or control.role ~= expected.role then
      fail(what .. " has the wrong source order", context)
    end
    checkPoint(control.center, context, what .. ".center")
    checkRect(control.hitRect, context, what .. ".hitRect")
  end
  checkRecord(
    quantity.visuals,
    { increment = true, decrement = true },
    context,
    "interactive.overlays.quantity.visuals"
  )
  for _, role in ipairs({ "increment", "decrement" }) do
    local visual = quantity.visuals[role]
    local what = "interactive.overlays.quantity.visuals." .. role
    checkRecord(visual, { normal = true, pressed = true }, context, what)
    checkVisual(visual.normal, context, what .. ".normal")
    checkVisual(visual.pressed, context, what .. ".pressed")
  end
  checkInteger(quantity.pressTicks, context, "interactive.overlays.quantity.pressTicks", 1, nil, "a positive integer")
  local confirm = quantity.confirm
  checkRecord(
    confirm,
    { visual = true, center = true, hitRect = true, labelAt = true },
    context,
    "interactive.overlays.quantity.confirm"
  )
  checkVisual(confirm.visual, context, "interactive.overlays.quantity.confirm.visual")
  checkPoint(confirm.center, context, "interactive.overlays.quantity.confirm.center")
  checkRect(confirm.hitRect, context, "interactive.overlays.quantity.confirm.hitRect")
  checkPoint(confirm.labelAt, context, "interactive.overlays.quantity.confirm.labelAt")
  local cancel = quantity.cancel
  checkRecord(cancel, { visual = true, center = true, labelAt = true }, context, "interactive.overlays.quantity.cancel")
  checkVisual(cancel.visual, context, "interactive.overlays.quantity.cancel.visual")
  checkPoint(cancel.center, context, "interactive.overlays.quantity.cancel.center")
  checkPoint(cancel.labelAt, context, "interactive.overlays.quantity.cancel.labelAt")
  checkRect(quantity.cancelHitRect, context, "interactive.overlays.quantity.cancelHitRect")
end

-- The retained selected-item panel: the selected icon center plus the
-- dedicated item text window with its explicit name/quantity anchors.
local function checkSelectedItem(panel, context)
  checkRecord(panel, {
    iconCenter = true,
    textRect = true,
    nameAt = true,
    quantityAt = true,
  }, context, "interactive.overlays.selectedItem")
  checkPoint(panel.iconCenter, context, "interactive.overlays.selectedItem.iconCenter")
  checkRect(panel.textRect, context, "interactive.overlays.selectedItem.textRect")
  checkLocalPoint(panel.nameAt, panel.textRect, context, "interactive.overlays.selectedItem.nameAt")
  checkLocalPoint(panel.quantityAt, panel.textRect, context, "interactive.overlays.selectedItem.quantityAt")
end

-- Lower-message geometry: the short framed window for action/move
-- messages and the tall framed window for toss confirmation/result.
local function checkMessages(messages, context)
  checkRecord(messages, { selected = true, modal = true }, context, "interactive.overlays.messages")
  for _, key in ipairs({ "selected", "modal" }) do
    local window = messages[key]
    local what = "interactive.overlays.messages." .. key
    checkRecord(window, { contentRect = true }, context, what)
    checkRect(window.contentRect, context, what .. ".contentRect")
  end
end

local function checkOverlays(overlays, context)
  checkRecord(overlays, {
    actionMenu = true,
    quantity = true,
    descriptionFallback = true,
    tossPrompt = true,
    selectedItem = true,
    messages = true,
  }, context, "interactive.overlays")
  checkTossPrompt(overlays.tossPrompt, context)
  checkActionMenu(overlays.actionMenu, context)
  checkQuantityOverlay(overlays.quantity, context)
  checkSelectedItem(overlays.selectedItem, context)
  checkMessages(overlays.messages, context)
  local fallback = overlays.descriptionFallback
  checkRecord(fallback, { frame = true, textRect = true }, context, "interactive.overlays.descriptionFallback")
  checkRect(fallback.frame, context, "interactive.overlays.descriptionFallback.frame")
  checkRect(fallback.textRect, context, "interactive.overlays.descriptionFallback.textRect")
end

-- Activation feedback: the generated palette-flash total plus the
-- normal/selected control visuals the renderer phases while latched.
local function checkFeedbackVisuals(visuals, context, what)
  checkRecord(visuals, { normal = true, selected = true }, context, what)
  checkVisual(visuals.normal, context, what .. ".normal")
  checkVisual(visuals.selected, context, what .. ".selected")
end

local function checkFeedback(feedback, context)
  checkRecord(feedback, {
    totalTicks = true,
    actionFace = true,
    cancelFace = true,
    quantityConfirm = true,
    quantityCancel = true,
  }, context, "interactive.feedback")
  checkInteger(feedback.totalTicks, context, "interactive.feedback.totalTicks", 1, nil, "a positive integer")
  checkFeedbackVisuals(feedback.actionFace, context, "interactive.feedback.actionFace")
  checkFeedbackVisuals(feedback.cancelFace, context, "interactive.feedback.cancelFace")
  checkFeedbackVisuals(feedback.quantityConfirm, context, "interactive.feedback.quantityConfirm")
  checkFeedbackVisuals(feedback.quantityCancel, context, "interactive.feedback.quantityCancel")
end

-- Move commit clips: one one-shot sequence per reorder kind reusing the
-- selection-entry sequence contract, plus the original/candidate target
-- cursor visuals.
local function checkMoveTransition(moveTransition, context)
  checkRecord(moveTransition, { unchanged = true, changed = true }, context, "interactive.moveTransition")
  checkSelectionEntry(moveTransition.unchanged, context)
  checkSelectionEntry(moveTransition.changed, context)
end

local function checkMoveCursor(moveCursor, context)
  checkRecord(moveCursor, { original = true, candidate = true }, context, "interactive.moveCursor")
  checkVisual(moveCursor.original, context, "interactive.moveCursor.original")
  checkVisual(moveCursor.candidate, context, "interactive.moveCursor.candidate")
end

local function checkInteractive(interactive, context)
  checkRecord(interactive, {
    backgrounds = true,
    pocketTabs = true,
    itemSlots = true,
    focus = true,
    pageIndicator = true,
    cancel = true,
    text = true,
    selectionEntry = true,
    overlays = true,
    feedback = true,
    moveTransition = true,
    moveCursor = true,
  }, context, "interactive")
  checkPaneBackgrounds(interactive.backgrounds, context)
  local pocketTabs = interactive.pocketTabs
  checkPocketTabs(pocketTabs, context)
  local itemSlots = interactive.itemSlots
  checkItemSlotList(itemSlots, context)
  checkFocus(interactive.focus, context)
  local pageIndicator = interactive.pageIndicator
  checkRecord(pageIndicator, { rect = true, textAt = true }, context, "interactive.pageIndicator")
  checkRect(pageIndicator.rect, context, "interactive.pageIndicator.rect")
  checkPoint(pageIndicator.textAt, context, "interactive.pageIndicator.textAt")
  local cancel = interactive.cancel
  checkRecord(cancel, { rect = true, textRect = true, labelRect = true }, context, "interactive.cancel")
  checkRect(cancel.rect, context, "interactive.cancel.rect")
  checkRect(cancel.textRect, context, "interactive.cancel.textRect")
  checkContained(cancel.textRect, cancel.rect, context, "interactive.cancel.textRect")
  checkRect(cancel.labelRect, context, "interactive.cancel.labelRect")
  checkContained(cancel.labelRect, cancel.rect, context, "interactive.cancel.labelRect")
  if cancel.labelRect.x * 2 + cancel.labelRect.width ~= cancel.rect.x * 2 + cancel.rect.width then
    fail("interactive.cancel.labelRect must be horizontally centered on the cancel control", context)
  end
  checkText(interactive.text, context)
  checkSelectionEntry(interactive.selectionEntry, context)
  checkFeedback(interactive.feedback, context)
  checkMoveTransition(interactive.moveTransition, context)
  checkMoveCursor(interactive.moveCursor, context)
  checkRegistration(itemSlots.registration, itemSlots.slots, context)
  checkOverlays(interactive.overlays, context)
end

-- Full manifest validation: shapes, canonical pane bounds, exact tab/slot/
-- state cardinality, animation-state resolution against both gender models,
-- and freedom from source identities. Raises BAG_MANIFEST_INVALID.
function BagAssetSchema.assertManifest(manifest)
  local context = {}
  checkRecord(manifest, { schema = true, logicalSize = true, hero = true, interactive = true }, context, "manifest")
  if manifest.schema ~= BagAssetSchema.SCHEMA then
    fail("manifest schema must be " .. BagAssetSchema.SCHEMA, context)
  end
  local logicalSize = manifest.logicalSize
  checkRecord(logicalSize, { width = true, height = true }, context, "manifest logicalSize")
  if logicalSize.width ~= BagAssetSchema.PANE_WIDTH or logicalSize.height ~= BagAssetSchema.PANE_HEIGHT then
    fail("manifest logicalSize must be 256x192", context)
  end
  checkHero(manifest.hero, context)
  checkInteractive(manifest.interactive, context)
  checkNoSourceIdentities(manifest, context, "manifest")
  return true
end

function BagAssetSchema.isValidManifest(manifest)
  return pcall(BagAssetSchema.assertManifest, manifest)
end

return BagAssetSchema
