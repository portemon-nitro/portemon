-- Targeted dump-backed smokes for battle presentation: narrow reads of
-- the handful of source members behind the menu/HUD and scene contracts,
-- decoded through the production G2D and scene paths, plus one global
-- catalog compile. Assertions are semantic keys, canvas geometry, and
-- readiness relationships, never catalog snapshots or committed
-- commercial payloads.

local Assert = require("tests.support.Assert")
local ArtifactState = require("romdump.src.build.ArtifactState")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}

---@param moduleName string
---@param why string
---@return table loaded module
local function requireBoundary(moduleName, why)
  local ok, module = pcall(require, moduleName)
  Assert.isTrue(ok and module ~= nil, why)
  assert(module ~= nil, "the boundary module loaded")
  return module
end

---@param romFs table
---@param versionId string
---@return table compiler, table cache
local function presentationBoundary(romFs, versionId)
  Assert.isTrue(
    ArtifactState.KINDS["battle-presentation"] == true,
    versionId .. ": the closed job table carries no battle presentation provider"
  )
  Assert.isTrue(
    ArtifactState.KINDS["battle-scene"] == true,
    versionId .. ": the closed job table carries no battle scene provider"
  )
  local compiler = requireBoundary(
    "romdump.src.digest.battle.BattlePresentationCompiler",
    versionId .. ": no battle presentation compiler turns the dump into menu and scene pixels"
  )
  local cache = requireBoundary(
    "libs.assets.src.battle.BattlePresentationCache",
    versionId .. ": no battle presentation cache carries staged scenes to the runtime"
  )
  Assert.notNil(romFs, "the dump stays open while the provider compiles")
  return compiler, cache
end

---@param archive table open NARC reader
---@param memberId integer zero-based source member
---@param label string diagnostic label
---@param versionId string
---@param Lz10 table LZ unwrapper
---@return string member bytes, LZ-unwrapped when wrapped
local function readSource(archive, memberId, label, versionId, Lz10)
  local bytes, readErr = archive:readMember(memberId)
  Assert.isTrue(
    bytes ~= nil,
    versionId .. ": " .. label .. " member " .. memberId .. " is readable (" .. tostring(readErr) .. ")"
  )
  assert(bytes ~= nil, "the source member is readable")
  if string.byte(bytes, 1) == 0x10 then
    local plain, lzErr = Lz10.decode(bytes)
    Assert.isTrue(
      plain ~= nil,
      versionId .. ": " .. label .. " member " .. memberId .. " unwraps (" .. tostring(lzErr) .. ")"
    )
    assert(plain ~= nil, "the source member unwraps")
    return plain
  end
  return bytes
end

-- Narrow dump smoke for the shared menu/HUD definitions: the handful of
-- source members behind the menu/HUD contract, decoded through the
-- production G2D path. Role shape comes from BattlePresentationSources;
-- geometry comes from the dump.
function T.shared_menu_and_hud_members_decode_from_the_dump(romFs, versionId)
  presentationBoundary(romFs, versionId)
  local Sources = requireBoundary(
    "romdump.src.config.BattlePresentationSources",
    versionId .. ": no battle presentation source catalog selects menu and HUD members"
  )
  local G2dDecoder = requireBoundary(
    "romdump.src.digest.ui.G2dDecoder",
    versionId .. ": no G2D decoder proves the menu and HUD members decode"
  )
  local Lz10 =
    requireBoundary("romdump.src.digest.Lz10", versionId .. ": no LZ unwrapper opens compressed source members")
  local roles = assert(Sources.ROLES, versionId .. ": the source catalog carries its member roles")
  Assert.equal(#roles.commandScreens, 3, versionId .. ": the command menu keeps its three screens")
  for _, tripleName in ipairs({ "playerHud", "enemyHud" }) do
    local triple =
      assert(roles[tripleName], versionId .. ": the source catalog carries its " .. tripleName .. " triple")
    for _, field in ipairs({ "nanr", "ncer", "ncgr" }) do
      Assert.isTrue(
        type(triple[field]) == "number",
        versionId .. ": " .. tripleName .. "." .. field .. " selects a member"
      )
    end
  end
  for _, slot in ipairs({
    "playerHudDoubleLeft",
    "playerHudDoubleRight",
    "enemyHudDoubleLeft",
    "enemyHudDoubleRight",
  }) do
    Assert.notNil(roles[slot], versionId .. ": the doubled family carries its " .. slot .. " triple")
  end
  local lower = assert(romFs:openNarc(Sources.LOWER_NARC), versionId .. ": the lower-screen archive opens")
  local sceneArchive = assert(romFs:openNarc(Sources.SCENE_NARC), versionId .. ": the battle scene archive opens")
  local lowerChars, lowerCharsErr = G2dDecoder.decodeChar(
    readSource(lower, roles.lowerChars, "shared lower characters", versionId, Lz10),
    { label = "shared lower characters" }
  )
  Assert.isTrue(
    lowerChars ~= nil,
    versionId .. ": the shared lower characters decode (" .. tostring(lowerCharsErr) .. ")"
  )
  assert(lowerChars ~= nil, "the shared lower characters decode")
  Assert.equal(lowerChars.depth, 3, versionId .. ": the shared lower characters are 4bpp")
  Assert.equal(#lowerChars.tiles, 32768, versionId .. ": the shared lower characters keep their tile region")
  local lowerPalette, lowerPaletteErr = G2dDecoder.decodePalette(
    readSource(lower, roles.lowerPalette, "base lower palette", versionId, Lz10),
    { label = "base lower palette" }
  )
  Assert.isTrue(
    lowerPalette ~= nil,
    versionId .. ": the base lower palette decodes (" .. tostring(lowerPaletteErr) .. ")"
  )
  Assert.equal(#assert(lowerPalette).colors, 256, versionId .. ": the base lower palette keeps 256 colors")
  local hudPalette, hudPaletteErr = G2dDecoder.decodePalette(
    readSource(sceneArchive, roles.hudPalette, "ordinary HUD palette", versionId, Lz10),
    { label = "ordinary HUD palette" }
  )
  Assert.isTrue(
    hudPalette ~= nil,
    versionId .. ": the ordinary HUD palette decodes (" .. tostring(hudPaletteErr) .. ")"
  )
  Assert.equal(#assert(hudPalette).colors, 16, versionId .. ": the ordinary HUD palette keeps 16 colors")
  local commandScreen, commandScreenErr = G2dDecoder.decodeScreen(
    readSource(lower, roles.commandScreens[1], "command screen", versionId, Lz10),
    { label = "command screen" }
  )
  Assert.isTrue(
    commandScreen ~= nil,
    versionId .. ": the command screen decodes (" .. tostring(commandScreenErr) .. ")"
  )
  assert(commandScreen ~= nil, "the command screen decodes")
  Assert.equal(commandScreen.width, 256, versionId .. ": the command screen keeps its 256-wide tilemap")
  Assert.equal(commandScreen.height, 256, versionId .. ": the command screen keeps its 256-high tilemap")
  for _, memberId in ipairs({ roles.commandScreens[2], roles.commandScreens[3] }) do
    Assert.isTrue(
      #readSource(lower, memberId, "command screen", versionId, Lz10) > 0,
      versionId .. ": command screen member " .. memberId .. " is non-empty"
    )
  end
  for _, tripleName in ipairs({ "playerHud", "enemyHud" }) do
    local cells, cellsErr = G2dDecoder.decodeCell(
      readSource(sceneArchive, roles[tripleName].ncer, tripleName .. " cells", versionId, Lz10),
      { label = tripleName .. " cells" }
    )
    Assert.isTrue(cells ~= nil, versionId .. ": " .. tripleName .. " cells decode (" .. tostring(cellsErr) .. ")")
    Assert.isTrue(#assert(cells).cells > 0, versionId .. ": " .. tripleName .. " keeps its source cells")
  end
  local doubleChars, doubleCharsErr = G2dDecoder.decodeChar(
    readSource(sceneArchive, roles.playerHudDoubleLeft.ncgr, "player left doubled HUD characters", versionId, Lz10),
    { label = "player left doubled HUD characters" }
  )
  Assert.isTrue(
    doubleChars ~= nil,
    versionId .. ": the doubled HUD characters decode (" .. tostring(doubleCharsErr) .. ")"
  )
  Assert.equal(assert(doubleChars).depth, 3, versionId .. ": the doubled HUD characters are 4bpp")
end

-- Narrow dump smoke for persistent scenes: one scene compile instead of
-- the whole-catalog compileGlobal plus six scene compiles. Time selection
-- and family separation are proven through the palette-variant formula
-- and member reads; geometry and determinism through one repeated scene
-- compile.
function T.persistent_scene_compiles_for_one_context(romFs, versionId)
  local compiler, cache = presentationBoundary(romFs, versionId)
  Assert.isTrue(type(compiler.compileScene) == "function", versionId .. ": the compiler exposes a scene entry point")
  local Sources = requireBoundary(
    "romdump.src.config.BattlePresentationSources",
    versionId .. ": no battle presentation source catalog selects scene members"
  )
  local Lz10 =
    requireBoundary("romdump.src.digest.Lz10", versionId .. ": no LZ unwrapper opens compressed source members")
  Assert.notNil(cache.parseSceneKey("general/grass/day"), versionId .. ": general/grass/day parses as a scene")
  Assert.isTrue(
    Sources.paletteVariant("general", "evening") ~= Sources.paletteVariant("general", "day"),
    versionId .. ": evening selection moves the outdoor palette"
  )
  Assert.isTrue(
    Sources.paletteVariant("general", "night") ~= Sources.paletteVariant("general", "day"),
    versionId .. ": night selection moves the outdoor palette"
  )
  Assert.equal(
    Sources.paletteVariant("cave_1", "evening"),
    Sources.paletteVariant("cave_1", "day"),
    versionId .. ": the indoor palette stays pinned across the time of day"
  )
  local lower = assert(romFs:openNarc(Sources.LOWER_NARC), versionId .. ": the lower-screen archive opens")
  local generalId = assert(Sources.backgroundId("general"), versionId .. ": general has a source background identity")
  local caveId = assert(Sources.backgroundId("cave_1"), versionId .. ": cave_1 has a source background identity")
  Assert.isTrue(caveId ~= generalId, versionId .. ": a second background family follows its own recipe")
  local dayPalette = readSource(
    lower,
    Sources.basePaletteMember(generalId, assert(Sources.paletteVariant("general", "day"))),
    "general day base palette",
    versionId,
    Lz10
  )
  local eveningPalette = readSource(
    lower,
    Sources.basePaletteMember(generalId, assert(Sources.paletteVariant("general", "evening"))),
    "general evening base palette",
    versionId,
    Lz10
  )
  Assert.isTrue(
    eveningPalette ~= dayPalette,
    versionId .. ": evening palette selection changes the composed scene input"
  )
  local generalChars = readSource(lower, Sources.baseCharMember(generalId), "general base characters", versionId, Lz10)
  local caveChars = readSource(lower, Sources.baseCharMember(caveId), "cave_1 base characters", versionId, Lz10)
  Assert.isTrue(caveChars ~= generalChars, versionId .. ": a second background family bakes its own characters")
  local day = assert(
    compiler.compileScene(romFs, { versionId = versionId }, "general/grass/day"),
    versionId .. ": general/grass/day compiles from the dump"
  )
  Assert.equal(day.key, "general/grass/day", versionId .. ": the scene record names its semantic key")
  Assert.equal(day.background, "general", versionId .. ": the scene record names its background")
  Assert.equal(day.canvasWidth, 512, versionId .. ": the persistent scene keeps its 512-wide source canvas")
  Assert.equal(day.canvasHeight, 256, versionId .. ": the persistent scene keeps its 256-high source canvas")
  Assert.notNil(day.image, versionId .. ": the scene record references its composed image")
  Assert.notNil(day.introImage, versionId .. ": the scene record includes its unbaked intro BG3 image")
  Assert.equal(day.introLayer.image, cache.sceneIntroImagePath(day.key))
  Assert.equal(day.introLayer.width, 512)
  Assert.equal(day.introLayer.height, 256)
  Assert.equal(day.terrainSprites.player.image, cache.sceneTerrainSpritePath(day.key, "player"))
  Assert.equal(day.terrainSprites.foe.image, cache.sceneTerrainSpritePath(day.key, "foe"))
  for _, side in ipairs({ "player", "foe" }) do
    local sprite = day.terrainSprites[side]
    Assert.equal(type(sprite.width), "number", versionId .. ": " .. side .. " terrain sprite has a raster width")
    Assert.equal(type(sprite.height), "number", versionId .. ": " .. side .. " terrain sprite has a raster height")
    Assert.equal(type(sprite.origin.x), "number", versionId .. ": " .. side .. " terrain sprite has an origin")
    Assert.equal(type(sprite.origin.y), "number", versionId .. ": " .. side .. " terrain sprite has an origin")
    Assert.equal(
      type(day.terrainSpritePixels[side]),
      "string",
      versionId .. ": " .. side .. " terrain pixels are staged"
    )
  end
  Assert.notNil(day.viewport, versionId .. ": the scene record maps its visible region")
  Assert.isTrue(
    day.viewport.x + day.viewport.width <= day.canvasWidth and day.viewport.y + day.viewport.height <= day.canvasHeight,
    versionId .. ": the visible region stays inside the source canvas"
  )
  local dayAgain = assert(
    compiler.compileScene(romFs, { versionId = versionId }, "general/grass/day"),
    versionId .. ": the scene recompiles from the dump"
  )
  Assert.equal(dayAgain.image, day.image, versionId .. ": scene compilation is deterministic")
end

-- The encounter animation plays two terrain particle sets chosen through the
-- retail gBattleEncounterTerrains table (grass 5, water 7, cave 17, sand 23,
-- building 11, great marsh 25), each as the member and its successor with
-- the retail per-member emitter counts. The compiled scene stages both sets
-- in start order with every texture image decoded to a PNG.
function T.encounter_particles_stage_the_terrain_member_pair_per_scene(romFs, versionId)
  local compiler, cache = presentationBoundary(romFs, versionId)
  local expected = {
    ["general/grass/day"] = { members = { 5, 6 }, emitters = { 5, 11 } },
    ["ocean/water/night"] = { members = { 7, 8 }, emitters = { 6, 7 } },
    ["cave_1/cave/day"] = { members = { 17, 18 }, emitters = { 2, 9 } },
    ["general/sand/evening"] = { members = { 23, 24 }, emitters = { 1, 1 } },
    ["building_1/building/day"] = { members = { 11, 12 }, emitters = { 2, 1 } },
    ["general/great_marsh/day"] = { members = { 25, 26 }, emitters = { 1, 1 } },
  }
  local sceneKeys = {}
  for sceneKey in pairs(expected) do
    sceneKeys[#sceneKeys + 1] = sceneKey
  end
  table.sort(sceneKeys)
  for _, sceneKey in ipairs(sceneKeys) do
    local want = expected[sceneKey]
    local scene = assert(
      compiler.compileScene(romFs, { versionId = versionId }, sceneKey),
      versionId .. ": " .. sceneKey .. " compiles from the dump"
    )
    Assert.equal(#scene.encounterParticles, 2, versionId .. ": " .. sceneKey .. " stages two emitter sets")
    for setIndex, set in ipairs(scene.encounterParticles) do
      local source = scene.buildMetadata.encounterParticles.sets[setIndex]
      Assert.equal(
        source.member,
        want.members[setIndex],
        versionId .. ": " .. sceneKey .. " set " .. setIndex .. " selects its retail member"
      )
      Assert.equal(
        #set.emitters,
        want.emitters[setIndex],
        versionId .. ": " .. sceneKey .. " set " .. setIndex .. " keeps the member emitter count"
      )
      Assert.equal(set.startTick, setIndex == 1 and 1 or 20, versionId .. ": the sets start in retail order")
      for _, texture in ipairs(set.textures) do
        Assert.equal(texture.image, cache.sceneParticleTexturePath(sceneKey, setIndex, texture.id))
        Assert.notNil(
          scene.encounterParticleImages[texture.image],
          versionId .. ": " .. sceneKey .. " stages " .. texture.image
        )
      end
    end
  end
end

-- Every ordinary scene terrain compiles its encounter particles through the
-- retail gBattleEncounterTerrains table (indexed by terrain ordinal; the
-- bytes are the ROM's 24-entry table) and stages every texture it names.
function T.every_scene_terrain_maps_to_its_retail_encounter_members(romFs, versionId)
  local compiler, cache = presentationBoundary(romFs, versionId)
  local retailTable = { 9, 23, 5, 19, 13, 17, 15, 7, 21, 11, 25, 11, 11, 11, 11, 11, 11, 21 }
  Assert.equal(#cache.TERRAINS, #retailTable, versionId .. ": the scene terrains match the retail ordinals")
  for ordinal, terrain in ipairs(cache.TERRAINS) do
    local sceneKey = cache.sceneKey("general", terrain, "day")
    local scene = assert(
      compiler.compileScene(romFs, { versionId = versionId }, sceneKey),
      versionId .. ": " .. sceneKey .. " compiles from the dump"
    )
    local members = scene.buildMetadata.encounterParticles.sets
    Assert.deepEqual(
      { members[1].member, members[2].member },
      { retailTable[ordinal], retailTable[ordinal] + 1 },
      versionId .. ": " .. terrain .. " plays the retail member pair"
    )
  end
end

-- Admission is a static contract, not a decode result: the global bundle
-- publishes BattlePresentationCache.sceneInventory() verbatim, so this
-- test checks that inventory plus the production rejection path.
function T.effect_backgrounds_are_not_admitted_as_persistent_scenes(romFs, versionId)
  local compiler, cache = presentationBoundary(romFs, versionId)
  Assert.isTrue(type(cache.sceneInventory) == "function", versionId .. ": the cache exposes its scene inventory")
  local inventory = cache.sceneInventory()
  Assert.isTrue(type(inventory) == "table", versionId .. ": the cache inventories its scene keys")
  local backgrounds = {}
  for _, entry in ipairs(inventory) do
    Assert.isTrue(type(entry.key) == "string" and entry.key ~= "", versionId .. ": every scene entry carries a key")
    backgrounds[entry.background] = true
  end
  local expected = {
    "general",
    "ocean",
    "city",
    "forest",
    "mountain",
    "snow",
    "building_1",
    "building_2",
    "building_3",
    "cave_1",
    "cave_2",
    "cave_3",
    "will",
    "koga",
    "bruno",
    "karen",
    "lance",
    "distortion_world",
  }
  local ordered = {}
  for _, name in ipairs(expected) do
    ordered[#ordered + 1] = name
  end
  table.sort(ordered)
  Assert.keySet(
    backgrounds,
    table.concat(ordered, ","),
    versionId .. ": only the ordinary persistent backgrounds are admitted"
  )
  Assert.isNil(
    cache.parseSceneKey("effect/flash/day"),
    versionId .. ": the cache key parser rejects effect backgrounds"
  )
  Assert.isFalse(
    cache.validateSceneKey("effect/flash/day"),
    versionId .. ": the cache key validator rejects effect backgrounds"
  )
  local scene, err = compiler.compileScene(romFs, { versionId = versionId }, "effect/flash/day")
  Assert.isNil(scene, versionId .. ": an effect background must not compile as a persistent scene")
  Assert.notNil(err, versionId .. ": the rejected effect background explains itself")
end

-- The global catalog sits on the first encounter's critical path, so it
-- closes over the shared menu/HUD/transition/message sections only: each
-- move or battle animation compiles in its own on-demand effect job, never
-- inside the global compile.
function T.global_catalog_compiles_without_per_effect_closures(romFs, versionId)
  local compiler = presentationBoundary(romFs, versionId)
  local Schema = requireBoundary(
    "libs.assets.src.battle.BattlePresentationSchema",
    versionId .. ": no battle presentation schema validates the staged manifest"
  )
  local compileEffect = compiler.compileEffect
  local effectCompiles = 0
  compiler.compileEffect = function(...)
    effectCompiles = effectCompiles + 1
    return compileEffect(...)
  end
  local ok, bundle, compileErr = pcall(compiler.compileGlobal, romFs, { versionId = versionId })
  compiler.compileEffect = compileEffect
  if not ok then
    error(bundle, 0)
  end
  Assert.equal(effectCompiles, 0, versionId .. ": the global catalog compiles no per-effect closure")
  Assert.notNil(bundle, versionId .. ": the global catalog compiles from the dump (" .. tostring(compileErr) .. ")")
  local valid, schemaErr = Schema.isValidManifest(bundle.manifest)
  Assert.isTrue(valid, versionId .. ": the global manifest validates (" .. tostring(schemaErr) .. ")")
  local function assertPatchSourceIndices(source, label)
    Assert.equal(source.format, "source-index-rgba8", versionId .. ": " .. label .. " declares raw indices")
    Assert.equal(source.plane, "subBg", versionId .. ": " .. label .. " retains its lower BG plane")
    local bytes = bundle.rawFiles[source.path]
    Assert.equal(
      #bytes,
      source.width * source.height * 4,
      versionId .. ": " .. label .. " stages a pixel-aligned source map"
    )
    for offset = 1, #bytes, 4 do
      Assert.equal(string.byte(bytes, offset + 1), 0, versionId .. ": " .. label .. " has a zero green channel")
      Assert.equal(string.byte(bytes, offset + 2), 0, versionId .. ": " .. label .. " has a zero blue channel")
      local alpha = string.byte(bytes, offset + 3)
      Assert.isTrue(alpha == 0 or alpha == 255, versionId .. ": " .. label .. " keeps binary source coverage")
    end
  end
  local feedbackPatch
  for _, screen in ipairs(bundle.manifest.menus.command.screens) do
    for _, states in pairs(screen.feedback or {}) do
      for _, patch in pairs(states) do
        feedbackPatch = patch
        break
      end
      if feedbackPatch ~= nil then
        break
      end
    end
    if feedbackPatch ~= nil then
      break
    end
  end
  Assert.notNil(feedbackPatch, versionId .. ": at least one independent menu feedback patch is staged")
  assertPatchSourceIndices(assert(feedbackPatch).sourceIndices, "feedback patch")
  for slot, button in ipairs(assert(bundle.manifest.menus.moves.screens[1]).moveButtons) do
    assertPatchSourceIndices(button.sourceIndices.empty, "empty move button " .. slot)
    for typeKey, states in pairs(button.sourceIndices.types) do
      for state, source in pairs(states) do
        assertPatchSourceIndices(source, typeKey .. " " .. state .. " move button " .. slot)
      end
    end
  end
  local keypadCursor = bundle.manifest.hud.cursor
  local topLeft = keypadCursor.animations[1].frames[2]
  Assert.deepEqual(
    { topLeft.x, topLeft.y },
    { -1, -1 },
    versionId .. ": the cursor compiler preserves its second-frame NANR translation"
  )
  local wildRoute = bundle.manifest.transitions.routes["fallback/plain/day/wild"]
  local orderKey = wildRoute.assetGroups.wildCellOrders
  local orderResource = bundle.manifest.resources[orderKey]
  local orderPayload = bundle.resourcePayloads[orderResource.path]
  Assert.equal(
    orderResource.kind,
    "transition-data",
    versionId .. ": wild cell orders are staged as semantic route data"
  )
  Assert.equal(orderPayload.rowsReverse[1], 0, versionId .. ": row transition uses the source reverse order")
  Assert.equal(orderPayload.diagonalsB[24], 46, versionId .. ": cave transition uses the final source diagonal index")
  -- The Elite Four intro replays both transition particle members through
  -- the shared emitter simulation: each stages as emitter records over RGBA
  -- texture pixels, with the emitter counts the intro creates.
  local introRoute
  for _, route in pairs(bundle.manifest.transitions.routes) do
    if route.role == "trainer-intro" then
      introRoute = route
      break
    end
  end
  Assert.notNil(introRoute, versionId .. ": the catalog carries an Elite Four intro route")
  for name, emitterCount in pairs({ intro = 3, followup = 4 }) do
    local descriptor = bundle.manifest.resources[assert(introRoute).assetGroups.particles[name]]
    Assert.equal(descriptor.kind, "particle", versionId .. ": the " .. name .. " member stages as a particle set")
    Assert.equal(descriptor.geometry.emitterCount, emitterCount, versionId .. ": the " .. name .. " emitter count")
    local set = bundle.resourcePayloads[descriptor.path]
    Assert.equal(#set.emitters, emitterCount, versionId .. ": the " .. name .. " set stages its emitters")
    for _, texture in ipairs(set.textures) do
      Assert.equal(
        #texture.pixels,
        texture.width * texture.height * 4,
        versionId .. ": the " .. name .. " texture " .. texture.id .. " stages RGBA pixels"
      )
    end
  end
  local arrowMiddle = bundle.manifest.hud.arrow.cells[4].objs
  Assert.equal(arrowMiddle[1].tile, 8, versionId .. ": arrow mapping-1 cell normalizes the first doubled tile index")
  Assert.equal(arrowMiddle[2].tile, 12, versionId .. ": arrow mapping-1 cell normalizes the second doubled tile index")
  for _, key in ipairs({ "battle/bide-release", "battle/bide-release/wild", "battle/bide-release/foe" }) do
    local release = bundle.manifest.messages.entries[key]
    Assert.notNil(release, versionId .. ": " .. key .. " is staged from the battle message bank")
    local substitutions = 0
    for _, token in ipairs(release.tokens) do
      if token.kind == "substitution" then
        substitutions = substitutions + 1
      end
    end
    Assert.equal(substitutions, 1, versionId .. ": " .. key .. " takes one battler name")
  end
end

-- Every ball whose retail seal and burst members the runtime reproduces
-- stages both sets with their textures; the unrepresented ball keeps only
-- its sprite, and its exclusion is still warranted.
function T.ball_particles_stage_for_every_reproducible_ball(romFs, versionId)
  local compiler = requireBoundary("romdump.src.digest.battle.BattlePresentationCompiler", "compiler loads")
  local Sources = requireBoundary("romdump.src.config.BattlePresentationSources", "sources load")
  local entries, pngs = {}, {}
  for itemKey in pairs(Sources.BALL_PARTICLES.entries) do
    local leaf = compiler.compileBallForSelector(romFs, { versionId = versionId }, "ball:" .. itemKey)
    entries[leaf.selector] = leaf.entry
    for image, png in pairs(leaf.pngImages) do
      pngs[image] = png
    end
  end
  for itemKey in pairs(Sources.BALL_PARTICLES.entries) do
    local entry = entries["ball:" .. itemKey]
    if Sources.BALL_PARTICLES.unrepresented[itemKey] ~= nil then
      Assert.isNil(entry.particles, versionId .. ": " .. itemKey .. " stages no particles")
    else
      local particles = entry.particles
      Assert.notNil(particles, versionId .. ": " .. itemKey .. " stages its particles")
      Assert.isTrue(particles.burstStartTick > 1, versionId .. ": " .. itemKey .. " waits for its opening frames")
      Assert.isTrue(particles.clickEmitter < #particles.burst.emitters, versionId .. ": the click emitter exists")
      for _, set in ipairs({ particles.seal, particles.burst }) do
        for _, texture in ipairs(set.textures) do
          Assert.notNil(pngs[texture.image], versionId .. ": " .. texture.image .. " stages")
        end
      end
    end
  end
  Assert.equal(
    entries["ball:POKE_BALL"].particles.burstStartTick,
    21,
    versionId .. ": ball opening is 20 ticks plus a step"
  )
end

-- Retail battle-bag screen (battle_bag_menu.c LoadBgGraphics plus the
-- overlay-8 window, hitbox, and entry-id tables): members decode through
-- the production G2D path, tables match their transcribed counts, and
-- the item-name template is msg 9 with twelve quantity slots.
function T.battle_bag_screen_decodes_from_source_members(romFs, versionId)
  local compiler = requireBoundary("romdump.src.digest.battle.BattlePresentationCompiler", "compiler loads")
  local ok, screen = pcall(compiler.compileBagScreen, romFs, { versionId = versionId })
  Assert.isTrue(ok, versionId .. ": the battle bag screen compiles (" .. tostring(screen) .. ")")
  assert(type(screen) == "table", "the battle bag screen compiled")
  Assert.equal(screen.rasterWidth, 512, versionId .. ": the bag screen tiles its three pages")
  Assert.equal(screen.rasterHeight, 512, versionId .. ": the bag screen tiles its three pages")
  Assert.isTrue(#screen.rasterPixels > 0, versionId .. ": the bag screen rasters pixels")
  Assert.isTrue(#screen.buttonTilemapBytes > 0, versionId .. ": the bag button tilemap stages")
  for key, count in pairs({ message = 1, useItem = 4, pocketMenu = 5, itemList = 26 }) do
    Assert.equal(#screen.windows[key], count, versionId .. ": bag window " .. key .. " keeps its count")
  end
  for key, count in pairs({ pocketMenu = 6, itemList = 9, useItem = 2 }) do
    Assert.equal(#screen.hitboxes[key], count, versionId .. ": bag hitbox " .. key .. " keeps its order")
  end
  Assert.deepEqual(screen.entryIds.name, { 9 }, versionId .. ": the item-name template is msg 9")
  Assert.equal(#screen.entryIds.quantity, 12, versionId .. ": twelve quantity slots stage")
  local first = screen.hitboxes.pocketMenu[1]
  Assert.deepEqual(
    { first.top, first.bottom, first.left, first.right },
    { 8, 79, 0, 127 },
    versionId .. ": the pocket-menu hit order matches retail"
  )
end

-- Counts the substitution slots in one staged message entry: template
-- keys expand exactly their source placeholders, labels carry none.
---@param entries table<string, table<string, unknown>> staged message entries under test
---@param key string semantic message key under test
---@return integer staged substitution slot count
local function stagedSubstitutions(entries, key)
  local entry = assert(entries[key], "the catalog stages " .. key)
  local tokens = assert(entry.tokens, key .. " carries its token stream") --[[@as table<integer, table<string, unknown>>]]
  local count = 0
  for _, token in ipairs(tokens) do
    if type(token) == "table" and token.kind == "substitution" then
      count = count + 1
    end
  end
  return count
end

-- Compiles the global catalog once for the message families below:
-- every wrapper key decodes from its staged result bank.
---@param romFs table open dump under test
---@param versionId string game version under test
---@return table<string, table<string, unknown>> staged message entries
local function partyMessageEntries(romFs, versionId)
  local compiler, _ = presentationBoundary(romFs, versionId)
  local ok, bundle, compileErr = pcall(compiler.compileGlobal, romFs, { versionId = versionId })
  Assert.isTrue(ok, versionId .. ": the global catalog compiles (" .. tostring(compileErr) .. ")")
  assert(bundle ~= nil, "the global catalog compiled")
  return assert(bundle.manifest.messages.entries, versionId .. ": the catalog stages message entries")
end

-- Retail battle-bag screen and its widgets stage together: three
-- SetPageBgOffset pages with staged images and provenance, the overlay-8
-- window/hitbox/entry-id tables, six list icon spots plus the fixed
-- last-used and use-item sprites, one tutorial finger spot per page with
-- its staged art, four cursor corners with advancing shimmer frames, one
-- button face per staged triple with inventoried dimensions, and the bag
-- and party printer palettes. One global compile proves the whole
-- browser bundle instead of one compile per widget.
function T.battle_bag_screen_and_widgets_stage_into_the_global_bundle(romFs, versionId)
  local compiler, _ = presentationBoundary(romFs, versionId)
  local Schema = requireBoundary(
    "libs.assets.src.battle.BattlePresentationSchema",
    versionId .. ": no battle presentation schema validates the staged manifest"
  )
  local Sources = requireBoundary(
    "romdump.src.config.BattlePresentationSources",
    versionId .. ": no battle sources name the bag tables"
  )
  local ok, bundle, compileErr = pcall(compiler.compileGlobal, romFs, { versionId = versionId })
  Assert.isTrue(ok, versionId .. ": the global catalog compiles (" .. tostring(compileErr) .. ")")
  assert(bundle ~= nil, "the global catalog compiled")
  local bag = assert(bundle.manifest.bag, versionId .. ": the global bundle stages the retail bag screen")
  local pages = assert(bag.pages, versionId .. ": the bag stages its pages")
  Assert.equal(#pages, 3, versionId .. ": the bag stages its three SetPageBgOffset pages")
  local images = assert(bundle.manifest.menus.images, versionId .. ": the catalog stages its menu image inventory")
  for index, page in ipairs(pages) do
    Assert.notNil(images[page.image], versionId .. ": bag page " .. index .. " stages its image")
  end
  for key, count in pairs({ message = 1, useItem = 4, pocketMenu = 5, itemList = 26 }) do
    Assert.equal(#(assert(bag.windows, "the bag stages its windows")[key]), count, versionId .. ": staged bag window " .. key .. " keeps its count")
  end
  for key, count in pairs({ pocketMenu = 6, itemList = 9, useItem = 2 }) do
    Assert.equal(#(assert(bag.hitboxes, "the bag stages its hitboxes")[key]), count, versionId .. ": staged bag hitbox " .. key .. " keeps its order")
  end
  Assert.deepEqual(assert(bag.entryIds, "the bag stages its entry ids").name, { 9 }, versionId .. ": the staged item-name template is msg 9")
  Assert.equal(#bag.entryIds.quantity, 12, versionId .. ": twelve staged quantity slots stage")
  local list = assert(assert(bag.icons, versionId .. ": the bag stages its item icon spots").list, versionId .. ": the bag stages its list icon spots")
  Assert.equal(#list, 6, versionId .. ": the bag stages six list icon spots")
  Assert.deepEqual({ list[1].x, list[1].y }, { 44, 45 }, versionId .. ": the first list icon spot matches retail")
  Assert.deepEqual({ list[6].x, list[6].y }, { 172, 141 }, versionId .. ": the last list icon spot matches retail")
  Assert.deepEqual({ bag.icons.lastUsed.x, bag.icons.lastUsed.y }, { 24, 178 }, versionId .. ": the last-used spot matches retail")
  Assert.deepEqual({ bag.icons.useItem.x, bag.icons.useItem.y }, { 40, 44 }, versionId .. ": the use-item spot matches retail")
  local fingers = assert(bag.tutorialFinger, versionId .. ": the bag stages its tutorial finger spots")
  Assert.equal(#fingers, 3, versionId .. ": the bag stages one finger spot per browser page")
  Assert.deepEqual({ fingers[1].x, fingers[1].y }, { 192, 24 }, versionId .. ": the pocket-menu finger spot matches retail")
  local finger = assert(bag.finger, versionId .. ": the global bundle stages the finger art")
  Assert.isTrue(type(finger.image) == "string", versionId .. ": the finger stages its image")
  Assert.notNil(images[finger.image], versionId .. ": the finger image is inventoried")
  local cursor = assert(bag.cursor, versionId .. ": the global bundle stages the cursor corners")
  for _, corner in ipairs({ "tl", "tr", "bl", "br" }) do
    local record = assert(cursor[corner], versionId .. ": the cursor stages its " .. corner .. " corner")
    Assert.notNil(images[record.image], versionId .. ": the " .. corner .. " corner image is inventoried")
    Assert.isTrue(#assert(record.frames, "the corner stages frames") >= 1, versionId .. ": the " .. corner .. " corner stages at least one frame")
  end
  local faces = assert(bag.buttons, versionId .. ": the bag stages its button faces")
  local expected = {}
  for _, staged in ipairs(Sources.BAG_BUTTON_FACES.staged) do
    for _, frame in ipairs(staged.frames) do
      for _, bank in ipairs(staged.banks) do
        expected[staged.button .. ":" .. frame .. ":" .. bank] = true
      end
    end
  end
  Assert.equal(#faces, 0 + (function()
    local n = 0
    for _ in pairs(expected) do
      n = n + 1
    end
    return n
  end)(), versionId .. ": every staged button face stages exactly once")
  local roles = assert(bundle.manifest.messages.roles, versionId .. ": the catalog stages its text roles")
  Assert.equal(#assert(roles.bag.palette.colors), 192, versionId .. ": the bag palette stages twelve sixteen-color banks")
  Assert.equal(#assert(roles.party.palette.colors), 16, versionId .. ": the party palette stages one sixteen-color bank")
  Assert.equal(bundle.provenance.bag.archive, "NARC_a_0_7_7", versionId .. ": the bag names its screen archive")
  local valid, schemaErr = Schema.isValidManifest(bundle.manifest)
  Assert.isTrue(valid, versionId .. ": the global manifest validates (" .. tostring(schemaErr) .. ")")
end

-- Retail battle-bag and battle-party words stage with their source
-- placeholders: pocket names, list headers, USE, page templates, every
-- TryUseItem refusal, and the party summary/move families. One global
-- compile proves the whole message bundle instead of one compile per
-- word family.
function T.battle_bag_and_party_messages_stage_with_source_placeholders(romFs, versionId)
  local entries = partyMessageEntries(romFs, versionId)
  for _, key in ipairs({
    "battle/bag/pocket/hp-pp",
    "battle/bag/use",
    "battle/bag/page/slash",
    "battle/bag/message/embargo",
    "battle/bag/message/no-stealing",
    "battle/party/stat/hp",
    "battle/party/move/pp",
    "battle/party/ability/name",
    "battle/party/item/name",
    "battle/party/stat/level-value",
    "battle/party/stat/exp-value",
    "battle/party/stat/hp-current",
    "battle/party/stat/attack-value",
    "battle/party/move/pp-current",
    "battle/party/move/power-value",
  }) do
    Assert.notNil(entries[key], versionId .. ": " .. key .. " stages from its source bank")
  end
  Assert.equal(stagedSubstitutions(entries, "battle/bag/message/no-aim-doubles"), 0, versionId .. ": doubles aim carries no placeholder")
  Assert.equal(stagedSubstitutions(entries, "battle/bag/message/embargo"), 2, versionId .. ": embargo names its move and mon")
  Assert.equal(stagedSubstitutions(entries, "battle/bag/message/no-stealing"), 1, versionId .. ": trainer escapes name the player")
  for slot = 0, 5 do
    Assert.equal(stagedSubstitutions(entries, "battle/party/mon-name/" .. slot), 1, versionId .. ": mon-name " .. slot .. " carries its nickname")
  end
  for slot = 0, 4 do
    Assert.equal(stagedSubstitutions(entries, "battle/party/move-name/" .. slot), 1, versionId .. ": move-name " .. slot .. " carries its name")
  end
  Assert.equal(stagedSubstitutions(entries, "battle/party/gender/male"), 0, versionId .. ": the male symbol carries no placeholder")
  Assert.equal(stagedSubstitutions(entries, "battle/party/stat/level"), 0, versionId .. ": the level label carries no placeholder")
  Assert.equal(stagedSubstitutions(entries, "battle/party/stat/hp-slash"), 0, versionId .. ": the HP slash carries no placeholder")
  Assert.equal(stagedSubstitutions(entries, "battle/party/move/pp-slash"), 0, versionId .. ": the PP slash carries no placeholder")
end

return RomSuite.fromFacts(T)
