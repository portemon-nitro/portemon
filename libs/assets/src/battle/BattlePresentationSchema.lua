-- Authoritative validation for the generated battle presentation class:
-- the staged global manifest, one composed scene record, and exact launch
-- demands. Runtime-facing records use semantic keys only: physical archive
-- and member identities are rejected at any depth. Love-free and
-- filesystem-free.

local SchemaCheck = require("libs.assets.src.SchemaCheck")
local Validate = require("libs.assets.src.Validate")

---@class BattlePresentationSchema
local BattlePresentationSchema = {}

BattlePresentationSchema.MANIFEST_SCHEMA = "g4-battle-presentation-v1"
BattlePresentationSchema.SCENE_SCHEMA = "g4-battle-scene-v1"

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

local function checkImagePath(value, context, code, field)
  checkString(value, context, code, field)
end

-- Producer identities never reach runtime records: any nested memberId,
-- fileId, or narcId key is malformed manifest data, not provenance.
local function checkNoNativeKeys(value, context, code, field)
  if type(value) ~= "table" then
    return
  end
  for key, nested in pairs(value) do
    if key == "memberId" or key == "fileId" or key == "narcId" then
      fail(code, field .. " leaks source detail '" .. tostring(key) .. "'", context)
    end
    checkNoNativeKeys(nested, context, code, field .. "." .. tostring(key))
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
  for index, screen in ipairs(section.screens) do
    local entry = field .. ".screens[" .. index .. "]"
    SchemaCheck.checkRecord(
      screen,
      { image = true, width = true, height = true, template = true, priority = true },
      context,
      code,
      entry
    )
    checkImagePath(screen.image, context, code, entry .. ".image")
    checkInt(screen.width, 8, nil, context, code, entry .. ".width")
    checkInt(screen.height, 8, nil, context, code, entry .. ".height")
    -- Template and priority ride along only where the source pins them
    -- (the command composition); other menus carry their screens alone.
    if screen.template ~= nil and screen.template ~= "unused" then
      checkInt(screen.template, 0, nil, context, code, entry .. ".template")
    end
    if screen.priority ~= nil then
      checkInt(screen.priority, 0, nil, context, code, entry .. ".priority")
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
  SchemaCheck.checkRecord(
    section,
    { image = true, cells = true, animation = true, animations = true, palette = true },
    context,
    code,
    field
  )
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

local function checkTextRoles(roles, context, code, field)
  SchemaCheck.checkRecord(roles, { narration = true, menu = true, hud = true }, context, code, field)
  for _, role in ipairs({ "narration", "menu", "hud" }) do
    local entry = field .. "." .. role
    local record = roles[role]
    SchemaCheck.checkRecord(record, { font = true, sourceFontId = true }, context, code, entry)
    checkString(record.font, context, code, entry .. ".font")
    if record.sourceFontId ~= nil then
      checkInt(record.sourceFontId, 0, nil, context, code, entry .. ".sourceFontId")
    end
  end
end

local function checkAudioRoles(roles, context, code, field)
  SchemaCheck.checkRecord(
    roles,
    { wild = true, trainer = true, rival = true, select = true, narrationBank = true, cries = true },
    context,
    code,
    field
  )
  for _, role in ipairs({ "wild", "trainer", "rival", "select" }) do
    checkString(roles[role], context, code, field .. "." .. role)
  end
  checkInt(roles.narrationBank, 0, nil, context, code, field .. ".narrationBank")
  checkString(roles.cries, context, code, field .. ".cries")
end

-- The staged global manifest: semantic menu/HUD definitions, frame and
-- animation metadata, the supported scene inventory, staged image
-- references, and text/audio roles. Every sprite descriptor preserves its
-- source cell geometry; no runtime consumer needs a native identity.
function BattlePresentationSchema.assertManifest(manifest)
  local context = {}
  SchemaCheck.checkRecord(manifest, {
    schema = true,
    version = true,
    verified = true,
    scenes = true,
    images = true,
    command = true,
    moves = true,
    target = true,
    twoOption = true,
    lower = true,
    playerHud = true,
    enemyHud = true,
    arrow = true,
    partyGauges = true,
    terrain = true,
    textRoles = true,
    audioRoles = true,
  }, context, CODE_MANIFEST, "manifest")
  if manifest.schema ~= BattlePresentationSchema.MANIFEST_SCHEMA then
    fail(CODE_MANIFEST, "manifest schema must be " .. BattlePresentationSchema.MANIFEST_SCHEMA, context)
  end
  SchemaCheck.checkRecord(manifest.version, { id = true, language = true }, context, CODE_MANIFEST, "manifest version")
  checkString(manifest.version.id, context, CODE_MANIFEST, "manifest version id")
  checkString(manifest.version.language, context, CODE_MANIFEST, "manifest version language")
  if manifest.verified ~= true then
    fail(CODE_MANIFEST, "a staged manifest carries its dump verification", context)
  end
  if not Validate.isArray(manifest.scenes) or #manifest.scenes == 0 then
    fail(CODE_MANIFEST, "manifest must inventory its supported scene keys", context)
  end
  for index, entry in ipairs(manifest.scenes) do
    checkSceneEntry(entry, context, CODE_MANIFEST, "manifest scenes[" .. index .. "]")
  end
  -- Every staged image is inventoried once with its pixel geometry, and
  -- every role/screen reference resolves inside that inventory.
  SchemaCheck.checkRecord(manifest.images, nil, context, CODE_MANIFEST, "manifest images")
  local imageCount = 0
  for path, geometry in pairs(manifest.images) do
    imageCount = imageCount + 1
    checkString(path, context, CODE_MANIFEST, "manifest image path")
    SchemaCheck.checkRecord(
      geometry,
      { width = true, height = true },
      context,
      CODE_MANIFEST,
      "manifest image " .. path
    )
    checkInt(geometry.width, 1, nil, context, CODE_MANIFEST, "manifest image " .. path .. " width")
    checkInt(geometry.height, 1, nil, context, CODE_MANIFEST, "manifest image " .. path .. " height")
  end
  if imageCount == 0 then
    fail(CODE_MANIFEST, "manifest must inventory its staged images", context)
  end
  local function checkImageRef(path, field)
    if manifest.images[path] == nil then
      fail(CODE_MANIFEST, field .. " references an unstaged image: " .. tostring(path), context)
    end
  end
  checkMenuSection(manifest.command, context, CODE_MANIFEST, "manifest command")
  checkMenuSection(manifest.moves, context, CODE_MANIFEST, "manifest moves")
  checkMenuSection(manifest.target, context, CODE_MANIFEST, "manifest target")
  checkMenuSection(manifest.twoOption, context, CODE_MANIFEST, "manifest twoOption")
  SchemaCheck.checkRecord(
    manifest.lower,
    { image = true, palette = true, variants = true },
    context,
    CODE_MANIFEST,
    "manifest lower"
  )
  checkImagePath(manifest.lower.image, context, CODE_MANIFEST, "manifest lower image")
  checkImageRef(manifest.lower.image, "manifest lower image")
  checkPalette(manifest.lower.palette, context, CODE_MANIFEST, "manifest lower palette")
  SchemaCheck.checkRecord(manifest.lower.variants, nil, context, CODE_MANIFEST, "manifest lower variants")
  local variantCount = 0
  for background, variant in pairs(manifest.lower.variants) do
    variantCount = variantCount + 1
    if BACKGROUNDS[background] == nil then
      fail(CODE_MANIFEST, "manifest lower variant carries an unknown background: " .. tostring(background), context)
    end
    local entry = "manifest lower variants " .. tostring(background)
    SchemaCheck.checkRecord(variant, { base = true, touch = true }, context, CODE_MANIFEST, entry)
    checkPalette(variant.base, context, CODE_MANIFEST, entry .. " base")
    checkPalette(variant.touch, context, CODE_MANIFEST, entry .. " touch")
  end
  if variantCount == 0 then
    fail(CODE_MANIFEST, "manifest lower must carry its background variants", context)
  end
  checkSpriteSection(manifest.playerHud, context, CODE_MANIFEST, "manifest playerHud")
  checkSpriteSection(manifest.enemyHud, context, CODE_MANIFEST, "manifest enemyHud")
  checkSpriteSection(manifest.arrow, context, CODE_MANIFEST, "manifest arrow")
  if not Validate.isArray(manifest.partyGauges) or #manifest.partyGauges ~= 2 then
    fail(CODE_MANIFEST, "manifest must carry both party gauge families", context)
  end
  for index, family in ipairs(manifest.partyGauges) do
    checkSpriteSection(family, context, CODE_MANIFEST, "manifest partyGauges[" .. index .. "]")
  end
  -- Terrain bake inputs are producer metadata, not staged sprites: the
  -- shared per-type cells and animation without an image or palette.
  SchemaCheck.checkRecord(manifest.terrain, { type0 = true, type1 = true }, context, CODE_MANIFEST, "manifest terrain")
  checkTerrainSection(manifest.terrain.type0, context, CODE_MANIFEST, "manifest terrain type0")
  checkTerrainSection(manifest.terrain.type1, context, CODE_MANIFEST, "manifest terrain type1")
  for _, field in ipairs({ "command", "moves", "target", "twoOption" }) do
    local section = manifest[field]
    checkImageRef(section.image, "manifest " .. field .. " image")
    for index, screen in ipairs(section.screens) do
      checkImageRef(screen.image, "manifest " .. field .. " screen " .. index)
    end
  end
  for _, field in ipairs({ "playerHud", "enemyHud", "arrow" }) do
    checkImageRef(manifest[field].image, "manifest " .. field .. " image")
  end
  for index, family in ipairs(manifest.partyGauges) do
    checkImageRef(family.image, "manifest partyGauges[" .. index .. "] image")
  end
  checkTextRoles(manifest.textRoles, context, CODE_MANIFEST, "manifest textRoles")
  checkAudioRoles(manifest.audioRoles, context, CODE_MANIFEST, "manifest audioRoles")
  checkNoNativeKeys(manifest, context, CODE_MANIFEST, "manifest")
  return true
end

function BattlePresentationSchema.isValidManifest(manifest)
  return pcall(BattlePresentationSchema.assertManifest, manifest)
end

-- One composed scene record: its semantic context, the source canvas size,
-- the visible-region mapping inside that canvas, and its staged image
-- reference. The key must agree with its axes; effect backgrounds are
-- never admitted.
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
  checkImagePath(scene.imagePath, context, CODE_SCENE, "scene imagePath")
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
