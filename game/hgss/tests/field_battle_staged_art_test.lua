-- Unit coverage for the presented battle envelope's staged menu and HUD
-- art resolution: every drawable key the battle renderers request
-- resolves to the exact staged path the verified manifest names, per-control
-- artwork without a staged counterpart resolves to nothing, and a planning
-- inventory stages nothing at all. Resolution is observed through the
-- shared image owner's requested paths.

local Assert = require("tests.support.Assert")
local BattlePresentationCache = require("libs.assets.src.battle.BattlePresentationCache")
local BattlePresentationSchema = require("libs.assets.src.battle.BattlePresentationSchema")
local ManifestFixture = require("tests.support.BattlePresentationManifestFixture")
local FieldBattlePresentation = require("game.hgss.src.field.FieldBattlePresentation")
local MoveIconCache = require("libs.assets.src.MoveIconCache")

local T = {}

local ART = "assets/generated/battle/"

---@param manifest table<string, unknown>
---@param path string
local function stageImage(manifest, path, width, height)
  manifest.menus.images[path] = { width = width or 256, height = height or 256 }
  return path
end

---@param name string stable synthetic asset stem
---@param width integer pixel width
---@param height integer pixel height
---@return table<string, unknown> source-index descriptor
local function sourceIndices(name, width, height)
  return {
    path = ART .. name .. ".source-index.rgba8",
    format = "source-index-rgba8",
    plane = "subBg",
    width = width,
    height = height,
  }
end

-- The shared fixture extended with every per-screen art family the
-- resolver indexes: distinct section and screen images, background and
-- touch variants (including a digit-bearing background name), pressed
-- feedback patches, and the four fight-menu move buttons.
---@return table<string, unknown> schema-valid staged manifest
local function stagedManifest()
  local manifest = ManifestFixture.manifest()
  for _, name in ipairs({ "command", "moves", "target", "twoOption" }) do
    local section = manifest.menus[name]
    section.image = stageImage(manifest, ART .. name .. "-section.png")
    section.screens[1].image = stageImage(manifest, ART .. name .. "-screen-1.png")
  end
  local command = manifest.menus.command.screens[1]
  command.backgrounds = {
    general = ART .. "command-screen-1-general.png",
    building_1 = ART .. "command-screen-1-building-1.png",
  }
  command.touchBackgrounds = { general = ART .. "command-screen-1-touch-general.png" }
  command.feedback = {
    fight = {
      pressed = {
        image = stageImage(manifest, ART .. "command-fight-pressed.png", 8, 8),
        x = 0,
        y = 0,
        width = 8,
        height = 8,
        sourceIndices = sourceIndices("command-fight-pressed", 8, 8),
      },
    },
  }
  local buttons = {}
  for slot = 1, 4 do
    local stem = "move-button-" .. slot
    buttons[slot] = {
      x = 0,
      y = 0,
      width = 8,
      height = 8,
      empty = stageImage(manifest, ART .. stem .. "-empty.png", 8, 8),
      types = {
        fire = {
          normal = stageImage(manifest, ART .. stem .. "-fire-normal.png", 8, 8),
          pressed = stageImage(manifest, ART .. stem .. "-fire-pressed.png", 8, 8),
        },
      },
      sourceIndices = {
        empty = sourceIndices(stem .. "-empty", 8, 8),
        types = {
          fire = {
            normal = sourceIndices(stem .. "-fire-normal", 8, 8),
            pressed = sourceIndices(stem .. "-fire-pressed", 8, 8),
          },
        },
      },
    }
  end
  manifest.menus.moves.screens[1].moveButtons = buttons
  BattlePresentationSchema.assertManifest(manifest)
  return manifest
end

---@param value unknown table to inspect
---@param path string staged source-index path to find
---@return table<string, unknown>? descriptor matching the path
local function findSourceIndices(value, path)
  if type(value) ~= "table" then
    return nil
  end
  if value.path == path and value.format == "source-index-rgba8" then
    return value
  end
  if value.format == "source-index-rgba8" and type(value.variants) == "table" then
    for _, variant in pairs(value.variants) do
      if type(variant) == "table" and variant.path == path then
        return { width = value.width, height = value.height }
      end
    end
  end
  for _, child in pairs(value) do
    local found = findSourceIndices(child, path)
    if found ~= nil then
      return found
    end
  end
  return nil
end

---@return table<string, unknown> shared image owner double recording requested paths by key
local function recordingPool()
  local pool = { paths = {}, acquired = {} }
  function pool:request(path, _, _)
    self.paths[#self.paths + 1] = path
    return path
  end
  function pool:poll(_)
    return "ready"
  end
  function pool:acquire(token)
    self.acquired[#self.acquired + 1] = token
    return { image = {}, path = token }
  end
  function pool:release(_) end
  return pool
end

---@param staged table<string, unknown>? staged manifest the cache answers, nil for the planning inventory
---@return FieldBattlePresentation
---@return table<string, unknown> recording pool
local function envelopeFor(staged, headless)
  local cacheFs = { versionId = "staged-art-probe" }
  function cacheFs:loadLua(path)
    if path == BattlePresentationCache.manifestPath() then
      return staged
    end
    if path == MoveIconCache.manifestPath() then
      return { schema = MoveIconCache.SCHEMA, types = {}, categories = {} }
    end
    return nil
  end
  function cacheFs:read(path)
    local source = staged ~= nil and findSourceIndices(staged, path) or nil
    if source ~= nil then
      return string.rep("\0", source.width * source.height * 4)
    end
    return "staged"
  end
  function cacheFs:exists(_, _)
    return true
  end
  local pool = recordingPool()
  local graphics = {}
  if headless then
    graphics = nil
  end
  local envelope = FieldBattlePresentation.new({
    cacheFs = cacheFs,
    windows = {},
    text = {},
    measureDisplay = function()
      return {}
    end,
    graphics = graphics,
    imagePool = pool,
  })
  return envelope, pool
end

---@param envelope FieldBattlePresentation
---@param pool table<string, unknown>
---@param key string drawable key under resolution
---@return string? staged path the key borrowed, nil when it resolved to nothing
local function resolvedPath(envelope, pool, key)
  local before = #pool.paths
  local handle, failure = envelope._services.drawable(key)
  Assert.isNil(failure, "staged art resolution never fails for " .. key)
  if #pool.paths == before then
    Assert.isNil(handle, "an unresolved key hands out no drawable: " .. key)
    return nil
  end
  Assert.notNil(handle, "a resolved key hands out its borrowed drawable: " .. key)
  return pool.paths[#pool.paths]
end

function T.staged_keys_resolve_to_their_verified_manifest_paths()
  local manifest = stagedManifest()
  local envelope, pool = envelopeFor(manifest)
  local hud, menus = manifest.hud, manifest.menus
  local command = menus.command.screens[1]
  local button = menus.moves.screens[1].moveButtons[2]
  local expected = {
    ["shadow"] = manifest.pictures.shadow.image,
    ["hud:enemy"] = hud.enemy.image,
    ["hud:player"] = hud.player.image,
    ["hud:player-left"] = hud.doubles.playerLeft.image,
    ["hud:player-right"] = hud.doubles.playerRight.image,
    ["hud:enemy-left"] = hud.doubles.enemyLeft.image,
    ["hud:enemy-right"] = hud.doubles.enemyRight.image,
    ["arrow"] = hud.arrow.image,
    ["cursor"] = hud.cursor.image,
    ["gauges:player"] = hud.partyGauges[2].image,
    ["gauges:enemy"] = hud.partyGauges[1].image,
    ["menu:command"] = menus.command.image,
    ["menu:moves"] = menus.moves.image,
    ["menu:target"] = menus.target.image,
    ["menu:pulse-mask"] = menus.lower.pulseMask,
    ["menu:command:screen:1"] = command.image,
    ["menu:command:screen:1@general"] = command.backgrounds.general,
    ["menu:command:screen:1@general:touch"] = command.touchBackgrounds.general,
    ["menu:command:screen:1@building_1"] = command.backgrounds.building_1,
    ["menu:command:screen:1@building_1:touch"] = command.backgrounds.building_1,
    ["menu:command:screen:1@forest"] = command.image,
    ["menu:command:screen:1@forest:touch"] = command.image,
    ["menu:moves:screen:1@general"] = menus.moves.screens[1].image,
    ["menu:target:screen:1@general:touch"] = menus.target.screens[1].image,
    ["menu:two-option:screen:1@general"] = menus.twoOption.screens[1].image,
    ["menu:command:feedback:fight:pressed"] = command.feedback.fight.pressed.image,
    ["menu:moves:move-button:1:empty"] = button.empty,
    ["menu:moves:move-button:1:fire:normal"] = button.types.fire.normal,
    ["menu:moves:move-button:1:fire:pressed"] = button.types.fire.pressed,
  }
  for key, path in pairs(expected) do
    Assert.equal(resolvedPath(envelope, pool, key), path, "staged key resolves its manifest path: " .. key)
  end
  for _, key in ipairs({
    "menu:command:fight",
    "menu:moves:move:0",
    "menu:two-option",
    "menu:command:screen:2@general",
    "menu:bogus:screen:1@general",
    "menu:command:feedback:fight:selected",
    "menu:command:feedback:run:pressed",
    "menu:target:feedback:fight:pressed",
    "menu:moves:move-button:4:empty",
    "menu:moves:move-button:1:water:normal",
    "hud:doubles",
    "gauges",
  }) do
    Assert.isNil(resolvedPath(envelope, pool, key), "key without staged art resolves to nothing: " .. key)
  end
  envelope:dispose()
end

function T.trainer_sequence_drawable_resolves_its_exact_staged_image()
  local selector = "back:PKMN_TRAINER_ETHAN"
  local record = ManifestFixture.trainerPictureRecord(selector)
  local staged = stagedManifest()
  local cacheFs = { versionId = "staged-art-leaf-probe" }
  function cacheFs:loadLua(path)
    if path == BattlePresentationCache.manifestPath() then
      return staged
    end
    if path == BattlePresentationCache.trainerPicturePath(selector) then
      return record
    end
    if path == MoveIconCache.manifestPath() then
      return { schema = MoveIconCache.SCHEMA, types = {}, categories = {} }
    end
    return nil
  end
  -- Validated source-index maps need their exact byte size, both from the
  -- staged core and from the demanded trainer leaf, while every other
  -- staged image answers with a non-empty placeholder like the probe pool.
  function cacheFs:read(path)
    local source = findSourceIndices(staged, path) or findSourceIndices(record, path)
    if source ~= nil then
      return string.rep("\0", source.width * source.height * 4)
    end
    return "staged"
  end
  function cacheFs:exists(_, _)
    return true
  end
  local pool = recordingPool()
  local host = { derivedAssets = {} }
  function host.derivedAssets.requestBattleTrainerPicture(_, _)
    return true, nil
  end
  local envelope = FieldBattlePresentation.new({
    cacheFs = cacheFs,
    windows = {},
    text = {},
    measureDisplay = function()
      return {}
    end,
    graphics = {},
    imagePool = pool,
    derivedAssets = host.derivedAssets,
  })
  -- A non-base source sequence proves sequence drawables resolve
  -- through the staged leaf, not just the base frame.
  local animation = assert(record.entry.animation, "the staged leaf carries trainer animation")
  local sequence = assert(animation.sequences[2], "the staged leaf carries a second source sequence")
  local sequenceFrame = assert(sequence.frames[1], "the second sequence carries its source frame")
  local ready, failure = envelope._services.prepare({
    launchId = "staged-art-leaf",
    scenes = {},
    pages = {},
    trainerPictures = { selector },
    battleBalls = {},
    iconKeys = {},
    audio = { roles = {}, banks = {}, cries = {} },
  })
  Assert.isTrue(ready, "all source-sequence images are enrolled before trainer drawing: " .. tostring(failure))
  local expectedImages = { [record.entry.image] = true }
  for _, stagedSequence in ipairs(animation.sequences) do
    for _, frame in ipairs(stagedSequence.frames) do
      expectedImages[frame.image] = true
    end
  end
  for image in pairs(expectedImages) do
    Assert.isTrue(
      table.concat(pool.paths, "\n"):find(image, 1, true) ~= nil,
      "source sequence images are enrolled before a renderer asks for them: " .. image
    )
  end
  local handle, drawableFailure = envelope._services.drawable(sequenceFrame.drawableKey)
  Assert.isNil(drawableFailure, "a valid source-sequence drawable resolves without failure")
  Assert.notNil(handle, "a valid source-sequence drawable hands out its image")
  local handleFields = {}
  for key, value in pairs(handle) do
    handleFields[#handleFields + 1] = tostring(key) .. "=" .. tostring(value)
  end
  Assert.isTrue(
    table.concat(pool.acquired, "\n"):find(sequenceFrame.image, 1, true) ~= nil,
    "sequence keys acquire their exact staged image: "
      .. table.concat(pool.acquired, ", ")
      .. " ("
      .. table.concat(handleFields, ", ")
      .. ")"
  )
  envelope:dispose()
end

function T.evolution_particle_drawable_resolves_without_core_sections_and_through_the_staged_leaf()
  local manifest = stagedManifest()
  Assert.isNil(manifest.evolutionParticles, "the strict shared core carries no evolution particle section")
  Assert.isNil(manifest.evolutionGraphics, "the strict shared core carries no evolution graphics section")
  local envelope, pool = envelopeFor(manifest)
  -- The core without evolution sections resolves the particle key to
  -- nothing instead of raising on the absent section.
  Assert.isNil(
    resolvedPath(envelope, pool, "battle:evolution-particle:0"),
    "an unstaged evolution particle resolves to nothing on a core without evolution sections"
  )
  envelope:dispose()

  -- Once the committed evolution stages its leaf, the same key resolves
  -- the staged leaf texture through the pool-backed drawables.
  local record = ManifestFixture.evolutionRecord()
  local cacheFs = { versionId = "staged-art-evolution-probe" }
  function cacheFs:loadLua(path)
    if path == BattlePresentationCache.manifestPath() then
      return manifest
    end
    if path == BattlePresentationCache.evolutionPath() then
      return record
    end
    if path == MoveIconCache.manifestPath() then
      return { schema = MoveIconCache.SCHEMA, types = {}, categories = {} }
    end
    return nil
  end
  function cacheFs:read(_)
    return "staged"
  end
  function cacheFs:exists(_, _)
    return true
  end
  local leafPool = recordingPool()
  local host = { derivedAssets = {} }
  function host.derivedAssets.requestBattleEvolution(_)
    return true, nil
  end
  local leafEnvelope = FieldBattlePresentation.new({
    cacheFs = cacheFs,
    windows = {},
    text = {},
    measureDisplay = function()
      return {}
    end,
    graphics = {},
    imagePool = leafPool,
    derivedAssets = host.derivedAssets,
  })
  local stored, evolutionErr = leafEnvelope._services.prepareEvolution()
  Assert.isNil(evolutionErr, "the staged evolution leaf prepares without failure")
  Assert.equal(stored, record, "the prepared evolution leaf is the staged record")
  Assert.equal(
    resolvedPath(leafEnvelope, leafPool, "battle:evolution-particle:0"),
    record.particles.textures[1].image,
    "a staged evolution particle resolves its leaf texture"
  )
  leafEnvelope:dispose()
end

local DEMAND_SCENE_KEY = "general/plain/day"

---@return table<string, unknown> minimal trusted scene record for exact-demand admission
local function demandSceneRecord()
  local function terrainSource(side, width, height)
    return {
      path = ART .. "terrain-" .. side .. ".source-index.rgba8",
      format = "source-index-rgba8",
      plane = "mainObj",
      width = width,
      height = height,
    }
  end
  return {
    key = DEMAND_SCENE_KEY,
    layers = {
      {
        characters = { path = ART .. "scene.characters", format = "indexed8" },
        baseCharacters = { path = ART .. "scene.base-characters", format = "indexed8" },
        map = { path = ART .. "scene.map" },
        palette = { path = ART .. "scene.palette" },
      },
    },
    introLayer = { image = ART .. "scene-intro.png", width = 256, height = 192 },
    terrainSprites = {
      player = {
        image = ART .. "terrain-player.png",
        width = 48,
        height = 24,
        origin = { x = 0, y = 0 },
        sourceIndices = terrainSource("player", 48, 24),
      },
      foe = {
        image = ART .. "terrain-foe.png",
        width = 40,
        height = 20,
        origin = { x = 0, y = 0 },
        sourceIndices = terrainSource("foe", 40, 20),
      },
    },
    encounterParticles = {},
    paletteSource = { path = ART .. "scene.palette-source" },
  }
end

---@param manifest table<string, unknown> staged manifest under admission
---@param record table<string, unknown> staged scene record under admission
---@param poison table<string, boolean> unreadable paths proving they stay closed
---@return table<string, unknown> counting cache double
local function countingCacheFs(manifest, record, poison)
  local cacheFs = { versionId = "exact-demand-probe", reads = {} }
  function cacheFs:loadLua(path)
    if path == BattlePresentationCache.manifestPath() then
      return manifest
    end
    if path == BattlePresentationCache.scenePath(DEMAND_SCENE_KEY) then
      return record
    end
    if path == record.layers[1].map.path then
      return { width = 512, height = 256, entries = {} }
    end
    if path == record.layers[1].palette.path then
      return { colors = {} }
    end
    if path == record.paletteSource.path then
      return {
        mainObjSources = {},
        subObjOpaque = { [1] = 0x001F },
        initialDisplayed = { subObj = { [1] = 0x001F } },
      }
    end
    if path == MoveIconCache.manifestPath() then
      return { schema = MoveIconCache.SCHEMA, types = {}, categories = {} }
    end
    return nil
  end
  function cacheFs:read(path)
    self.reads[path] = (self.reads[path] or 0) + 1
    if poison[path] then
      error("unreadable unused file: " .. path, 0)
    end
    local source = findSourceIndices(manifest, path)
    if source ~= nil then
      return string.rep("\0", source.width * source.height * 4)
    end
    if path == record.layers[1].characters.path then
      return string.rep("c", 64)
    end
    if path == record.layers[1].baseCharacters.path then
      return string.rep("b", 64)
    end
    if path == record.terrainSprites.player.sourceIndices.path then
      return string.rep("\0", 48 * 24 * 4)
    end
    if path == record.terrainSprites.foe.sourceIndices.path then
      return string.rep("\0", 40 * 20 * 4)
    end
    return "staged"
  end
  function cacheFs:exists(_, _)
    return true
  end
  return cacheFs
end

---@param manifest table<string, unknown> staged manifest under admission
---@param record table<string, unknown> staged scene record under admission
---@param poison table<string, boolean> unreadable paths proving they stay closed
---@return FieldBattlePresentation admitted envelope
---@return table<string, unknown> counting cache double
local function demandEnvelope(manifest, record, poison)
  local cacheFs = countingCacheFs(manifest, record, poison)
  local pool = recordingPool()
  local envelope = FieldBattlePresentation.new({
    cacheFs = cacheFs,
    windows = {},
    text = {},
    measureDisplay = function()
      return {}
    end,
    graphics = {},
    imagePool = pool,
  })
  envelope._manifest = manifest
  return envelope, cacheFs
end

---@param envelope FieldBattlePresentation admitted envelope under test
---@return table<string, unknown> admitted scene layer
local function admitCommandScene(envelope)
  local ready, failure = envelope._services.prepare({
    launchId = "command-admission",
    scenes = { DEMAND_SCENE_KEY },
    pages = {},
    trainerPictures = {},
    battleBalls = {},
    iconKeys = {},
    audio = { roles = {}, banks = {}, cries = {} },
  })
  Assert.isTrue(ready, "command admission never opens unused battle art: " .. tostring(failure))
  return assert(envelope._services.sceneLayer(), "admission stages its scene layer")
end

function T.command_admission_ignores_unreadable_unused_battle_art()
  local manifest = stagedManifest()
  local record = demandSceneRecord()
  local moves = manifest.menus.moves.screens[1]
  local unusedButton = moves.moveButtons[4]
  local poison = {
    [unusedButton.sourceIndices.types.fire.pressed.path] = true,
    [unusedButton.types.fire.pressed] = true,
    [manifest.hud.doubles.playerLeft.sourceIndices.path] = true,
    [manifest.messages.roles.menu.font] = true,
  }
  local envelope, cacheFs = demandEnvelope(manifest, record, poison)
  admitCommandScene(envelope)
  for path in pairs(poison) do
    Assert.equal(cacheFs.reads[path] or 0, 0, "unused battle art stays closed: " .. path)
  end
  envelope:dispose()
end

function T.visible_source_maps_read_once_and_unused_variants_stay_closed()
  local manifest = stagedManifest()
  local record = demandSceneRecord()
  local envelope, cacheFs = demandEnvelope(manifest, record, {})
  local layer = admitCommandScene(envelope)
  local commandSource = manifest.menus.command.screens[1].sourceIndices
  local first = layer.sourceMapFor(commandSource)
  Assert.deepEqual(
    { first.plane, first.width, first.height },
    { commandSource.plane, commandSource.width, commandSource.height },
    "the visible command map keeps its staged geometry"
  )
  Assert.equal(#first.pixels, commandSource.width * commandSource.height * 4, "the visible map reads its bytes")
  local second = layer.sourceMapFor(commandSource)
  Assert.isTrue(first == second, "repeated visible requests share one memoized read")
  Assert.equal(cacheFs.reads[commandSource.path], 1, "selected source bytes load exactly once")
  local moves = manifest.menus.moves.screens[1]
  local unusedVariant = moves.moveButtons[2].sourceIndices.types.fire.pressed.path
  Assert.equal(
    cacheFs.reads[unusedVariant] or 0,
    0,
    "requesting command art opens no unused move-variant file"
  )
  Assert.equal(
    cacheFs.reads[record.terrainSprites.player.sourceIndices.path] or 0,
    0,
    "terrain bytes wait for their first palette use"
  )
  envelope:dispose()
end

function T.planning_inventory_resolves_no_staged_art()
  local envelope, pool = envelopeFor(nil)
  for _, key in ipairs({
    "shadow",
    "hud:enemy",
    "hud:player-left",
    "cursor",
    "gauges:player",
    "menu:command",
    "menu:pulse-mask",
    "menu:command:screen:1@general",
    "menu:command:feedback:fight:pressed",
    "menu:moves:move-button:0:empty",
  }) do
    Assert.isNil(resolvedPath(envelope, pool, key), "a planning inventory stages nothing: " .. key)
  end
  envelope:dispose()
end

return { tests = T }
