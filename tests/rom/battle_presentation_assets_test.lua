-- Dump-backed composition for battle presentation: the real private dump
-- compiles the shared menu/HUD definitions and the requested persistent
-- scenes through the production compiler, every referenced output stages
-- through the existing publication path, and the cache boundary loads and
-- validates the result. Assertions are semantic keys, canvas geometry, and
-- readiness relationships, never catalog snapshots or committed
-- commercial payloads.

local Assert = require("tests.support.Assert")
local ArtifactState = require("romdump.src.build.ArtifactState")
local BattlePresentationCache = require("libs.assets.src.battle.BattlePresentationCache")
local BattlePresentationSources = require("romdump.src.config.BattlePresentationSources")
local MonSources = require("romdump.src.config.MonSources")
local Hashing = require("romdump.src.digest.Hashing")
local FieldFontCache = require("libs.assets.src.field.FieldFontCache")
local Lz10 = require("romdump.src.digest.Lz10")
local UiMessageBank = require("romdump.src.digest.ui.UiMessageBank")
local G2dDecoder = require("romdump.src.digest.ui.G2dDecoder")
local Spl = require("libs.nds.src.nitro.particle.Spl")
local charmap = require("romdump.src.catalog.hgss.charmap")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}

---@param values string[]
---@param expected string
---@return boolean whether the list contains the value
local function contains(values, expected)
  for _, value in ipairs(values) do
    if value == expected then
      return true
    end
  end
  return false
end


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

---@param compiler table
---@param romFs table
---@param versionId string
---@return table complete source-backed catalog bundle
local function compileGlobal(compiler, romFs, versionId)
  Assert.isTrue(type(compiler.compileGlobal) == "function", versionId .. ": the compiler exposes a global entry point")
  local bundle, reason = compiler.compileGlobal(romFs, { versionId = versionId })
  Assert.isNil(reason, versionId .. ": complete global routes compile without blockers: " .. tostring(reason))
  return assert(bundle, versionId .. ": complete global compilation publishes its bundle")
end

local REQUIRED_SECTIONS = {
  "battlefield",
  "catalogIdentity",
  "scenes",
  "layouts",
  "hud",
  "pictures",
  "menus",
  "messages",
  "transitions",
  "audioRoles",
  "resources",
}

---@param romFs table
---@param archiveSymbol string
---@param memberId integer
---@return string source member bytes
local function readSourceMember(romFs, archiveSymbol, memberId)
  local archive = assert(romFs:openNarc(archiveSymbol), "the source archive opens: " .. archiveSymbol)
  return assert(archive:readMember(memberId), "the source member is readable: " .. memberId)
end

---@param scene table compiled source-backed scene
---@param x integer source canvas pixel X
---@param y integer source canvas pixel Y
---@param label string diagnostic label
local function assertScenePixelMatchesBg3(scene, x, y, label)
  local payload = assert(scene.layerPayloads[1], label .. ": the scene carries BG3 source payload")
  local map = payload.map
  local entry = assert(map.entries[math.floor(y / 8) * (map.width / 8) + math.floor(x / 8) + 1])
  local sourceX = x % 8
  local sourceY = y % 8
  if entry.flipH then
    sourceX = 7 - sourceX
  end
  if entry.flipV then
    sourceY = 7 - sourceY
  end
  local tileByte = entry.tile * 64 + sourceY * 8 + sourceX + 1
  local paletteIndex = string.byte(payload.characters, tileByte) + 1
  local color = assert(payload.palette.colors[paletteIndex], label .. ": the BG3 palette covers the decoded pixel")
  local pixel = (y * scene.canvasWidth + x) * 4
  Assert.deepEqual(
    {
      string.byte(scene.image, pixel + 1),
      string.byte(scene.image, pixel + 2),
      string.byte(scene.image, pixel + 3),
      string.byte(scene.image, pixel + 4),
    },
    { color.r, color.g, color.b, 255 },
    label .. ": the composed scene pixel equals its decoded BG3 character/map/palette result"
  )
end

function T.persistent_scene_variants_match_their_decoded_bg3_pixels(romFs, versionId)
  local compiler = requireBoundary(
    "romdump.src.digest.battle.BattlePresentationCompiler",
    versionId .. ": scene pixels use the source producer"
  )
  for _, sceneKey in ipairs({
    "general/grass/day",
    "general/grass/evening",
    "general/grass/night",
    "cave_1/cave/day",
  }) do
    local scene = compileSourceScene(compiler, romFs, versionId, sceneKey)
    Assert.equal(scene.layers[1].characters.format, "indexed8", versionId .. ": persistent BG3 is 8bpp: " .. sceneKey)
    assertScenePixelMatchesBg3(scene, 0, 0, versionId .. ": " .. sceneKey)
    if sceneKey == "general/grass/day" then
      local BattleScene = requireBoundary(
        "libs.hgss.src.presentation.BattleScene",
        versionId .. ": staged BG3 pixels use the BattleScene layer owner"
      )
      local nativeScene = BattleScene.new()
      local payload = assert(scene.layerPayloads[1])
      nativeScene:installBackground({
        characters = payload.characters,
        map = payload.map,
        palette = payload.palette,
        colorMode = "8bpp",
      })
      local raster = nativeScene:backgroundRaster()
      local entry = payload.map.entries[1]
      local index = string.byte(payload.characters, entry.tile * 64 + 1)
      local color = payload.palette.colors[index + 1]
      Assert.deepEqual(
        { raster:pixel(0, 0) },
        { color.r, color.g, color.b, 255 },
        versionId .. ": BattleScene renders the actual decoded BG3 character, map, and palette"
      )
      nativeScene:patchBackgroundPalette(index, { r = 19, g = 23, b = 29 })
      Assert.deepEqual(
        { nativeScene:backgroundRaster():pixel(0, 0) },
        { 19, 23, 29, 255 },
        versionId .. ": a source-indexed palette operation changes the installed plane"
      )
      nativeScene:applyScrollPatch(5, 7)
      Assert.deepEqual(nativeScene:scroll(), { x = 5, y = 7 }, versionId .. ": native scroll remains mutable scene state")
    end
  end
end

function T.pokepic_shadow_atlas_decodes_from_the_pinned_source_members(romFs, versionId)
  local source = BattlePresentationSources.POKE_SHADOW
  local archive = assert(romFs:openNarc(source.archive), versionId .. ": Pokepic shadow archive opens")
  local characterBytes = assert(archive:readMember(source.characterMember), versionId .. ": NCGR 259 is present")
  local paletteBytes = assert(archive:readMember(source.paletteMember), versionId .. ": NCLR 260 is present")
  if string.byte(characterBytes, 1) == 0x10 then
    characterBytes = assert(Lz10.decode(characterBytes), versionId .. ": shadow NCGR unwraps")
  end
  if string.byte(paletteBytes, 1) == 0x10 then
    paletteBytes = assert(Lz10.decode(paletteBytes), versionId .. ": shadow NCLR unwraps")
  end
  local characters, characterErr = G2dDecoder.decodeChar(characterBytes, { label = "Pokepic shadow characters" })
  Assert.isNil(characterErr, versionId .. ": native shadow NCGR decodes")
  Assert.equal(#assert(characters).tiles, 6400, versionId .. ": native shadow source has 3,200 words")
  Assert.equal(assert(characters).depth, 3, versionId .. ": native shadow source is 4bpp")
  local palette, paletteErr = G2dDecoder.decodePalette(paletteBytes, { label = "Pokepic shadow palette" })
  Assert.isNil(paletteErr, versionId .. ": native shadow NCLR decodes")
  Assert.equal(#assert(palette).colors, 16, versionId .. ": native shadow palette has one 4bpp bank")
  local compiler = requireBoundary(
    "romdump.src.digest.battle.BattlePresentationCompiler",
    versionId .. ": shadow UVs use the battle presentation producer"
  )
  local atlas = compiler.compileShadowImage(assert(characters), assert(palette))
  Assert.deepEqual({ atlas.width, atlas.height }, { 64, 64 }, versionId .. ": four native shadow sizes stage as one atlas")
  Assert.equal(source.characterMember, 259, versionId .. ": character member matches PokepicManager_Create")
  Assert.equal(source.paletteMember, 260, versionId .. ": palette member matches PokepicManager_BufferPlttData")
  local bit = require("bit")
  local U32 = require("libs.codec.src.U32")
  local scanned = assert(characters).tiles
  local seed = string.byte(scanned, 1) + string.byte(scanned, 2) * 256
  local unscanned = {}
  for wordOffset = 0, 3199 do
    local byteOffset = wordOffset * 2
    local word = string.byte(scanned, byteOffset + 1) + string.byte(scanned, byteOffset + 2) * 256
    local plain = bit.bxor(word, seed % 65536)
    unscanned[#unscanned + 1] = string.char(plain % 256, math.floor(plain / 256))
    seed = U32.add(U32.mul(seed, 1103515245), 24691)
  end
  unscanned = table.concat(unscanned)
  local regionHashes = {}
  for index = 1, 4 do
    local first = (index - 1) * 64 * 16 * 4 + 1
    local last = index * 64 * 16 * 4
    local actual = atlas.pixels:sub(first, last)
    local expected = {}
    local source = BattlePresentationSources.POKE_SHADOW.regions[index]
    for y = 0, source.height - 1 do
      local sourceY = source.y - 160 + y
      for x = 0, source.width - 1 do
        local sourceX = source.x - 160 + x
        local packed = string.byte(unscanned, sourceY * 80 + math.floor(sourceX / 2) + 1)
        local colorIndex = sourceX % 2 == 0 and packed % 16 or math.floor(packed / 16)
        local color = assert(assert(palette).colors[colorIndex + 1], "pixel palette index is available")
        expected[#expected + 1] = string.char(color.r, color.g, color.b, colorIndex == 0 and 0 or 255)
      end
    end
    expected = table.concat(expected)
    Assert.equal(actual, expected, versionId .. ": staged UV rectangle matches the native copied texture pixels")
    regionHashes[index] = Hashing.sha1hex(actual)
  end
  Assert.equal(regionHashes[1], regionHashes[2], versionId .. ": native size one aliases size zero")
  for _, identity in ipairs(regionHashes) do
    Assert.isTrue(identity:match("^%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x$") ~= nil)
  end
end

function T.shared_menu_and_hud_definitions_compile_from_the_dump(romFs, versionId)
  local compiler, _ = presentationBoundary(romFs, versionId)
  local bundle = compileGlobal(compiler, romFs, versionId)
  local manifest = bundle.manifest
  Assert.isTrue(type(manifest) == "table", versionId .. ": the global compile yields source-backed catalog data")
  local shadow = assert(manifest.pictures.shadow, versionId .. ": Pokepic shadow art is part of global staging")
  Assert.deepEqual(
    { shadow.image, shadow.width, shadow.height },
    { BattlePresentationCache.globalImagePath("pokepic-shadow"), 64, 64 },
    versionId .. ": native shadow regions resolve through the staged global image"
  )
  Assert.deepEqual(
    { bundle.images["pokepic-shadow"].width, bundle.images["pokepic-shadow"].height },
    { shadow.width, shadow.height },
    versionId .. ": the global compiler stages the raster under the manifest image key"
  )
  Assert.equal(
    bundle.provenance.pokepicShadow.source.symbol,
    "PokepicManager_Create / PokepicManager_BufferPlttData / sPokepicShadowUVParams",
    versionId .. ": the shadow member selection and native UV provenance stay producer-side"
  )
  for _, section in ipairs(REQUIRED_SECTIONS) do
    Assert.notNil(manifest[section], versionId .. ": the catalog carries its " .. section .. " section")
  end
  Assert.deepEqual(
    manifest.battlefield.slots,
    BattlePresentationSources.SLOT_GEOMETRY,
    versionId .. ": the runtime manifest publishes only normalized native side-type geometry"
  )
  Assert.isTrue(
    type(manifest.menus.layouts) == "table" and type(manifest.menus.layouts.frontier) == "table",
    versionId .. ": Frontier menu composition keeps its source-selected tile, palette, and palette-animation resources"
  )
  Assert.deepEqual(manifest.menus.runtimeContexts.bugContest.inputs, {
    "caughtPokemonSpecies",
    "caughtPokemonForm",
    "caughtPokemonGender",
    "caughtPokemonLevel",
    "remainingSafariBalls",
  }, versionId .. ": Bug Contest requires its source-derived battle inputs")
  Assert.deepEqual(manifest.menus.runtimeContexts.targetSelection.inputs, {
    "targetCandidates",
    "selectedTarget",
    "targetHitMask",
    "nickname",
    "gender",
    "species",
    "form",
    "hpCondition",
    "statusAnimation",
  }, versionId .. ": target rendering declares native selection and battler facts")
  Assert.deepEqual(manifest.menus.runtimeContexts.moveSelection.inputs, {
    "moveIds",
    "currentPP",
    "maximumPP",
  }, versionId .. ": move rendering declares battle-local PP values")
  Assert.deepEqual(manifest.menus.runtimeContexts.frontierLayout.inputs, { "frontierBattle" })
  Assert.equal(manifest.menus.contexts.main.inputs.mode.type, "enum")
  Assert.equal(manifest.menus.contexts.bugContest.caughtPokemon.optional, true)
  Assert.deepEqual(manifest.menus.contexts.vsRecorder.inputs.playbackStatus.values, { "paused", "corrupted" })
  local initialRoute = assert(manifest.menus.routes["menu/main/initial"])
  Assert.isTrue(contains(initialRoute.messageEntries, "label/fight"))
  Assert.isTrue(contains(initialRoute.messageEntries, "label/run"))
  Assert.isTrue(contains(initialRoute.fontRoles, "menu"))
  Assert.isTrue(contains(initialRoute.requiredContext, "frontier"))
  local bugContestRoute = assert(manifest.menus.routes["menu/bug-contest/ordinary"])
  Assert.isTrue(contains(bugContestRoute.requiredContext, "bugContest"))
  Assert.isTrue(contains(bugContestRoute.assetRoles, "pokemonIcon"))
  Assert.equal("mon-icons", bugContestRoute.assetBindings.pokemonIcon.catalog)
  Assert.equal("species-form", bugContestRoute.assetBindings.pokemonIcon.selector)
  Assert.equal("bugContest.caughtPokemon.species", bugContestRoute.assetBindings.pokemonIcon.context[1])
  Assert.equal("bugContest.caughtPokemon.form", bugContestRoute.assetBindings.pokemonIcon.context[2])
  Assert.equal("caught-mon-present", bugContestRoute.assetBindings.pokemonIcon.when)
  Assert.isTrue(contains(bugContestRoute.fontRoles, "bugContest"))
  local bugContestCoverage = assert(manifest.coverage["menu/bug-contest/ordinary"])
  Assert.isTrue(contains(bugContestCoverage.resources, manifest.menus.layouts.bugContest.character))
  Assert.isTrue(contains(bugContestCoverage.resources, manifest.menus.layouts.bugContest.animation))
  local recorderRoute = assert(manifest.menus.routes["menu/vs-recorder"])
  Assert.isTrue(contains(recorderRoute.messageEntries, "label/recorder-stop"))
  Assert.isTrue(contains(recorderRoute.messageRoutes, "menu/vs-recorder-feedback"))
  Assert.isTrue(contains(recorderRoute.fontRoles, "recorderFeedback"))
  Assert.isTrue(contains(recorderRoute.requiredContext, "vsRecorder"))
  local recorderCoverage = assert(manifest.coverage["menu/vs-recorder"])
  for _, messageKey in ipairs({ "status/recorder-0", "status/recorder-1", "status/recorder-2", "status/recorder-3" }) do
    Assert.isTrue(contains(recorderCoverage.messageEntries, messageKey))
  end
  local moveCoverage = assert(manifest.coverage["menu/fight"])
  Assert.isTrue(contains(moveCoverage.assetRoles, "moveTypeIcon"))
  Assert.isTrue(contains(moveCoverage.requiredContext, "moveSelection"))
  local targetCoverage = assert(manifest.coverage["menu/target"])
  Assert.isTrue(contains(targetCoverage.assetRoles, "battleCondition"))
  Assert.isTrue(contains(targetCoverage.requiredContext, "targetSelection"))
  local scriptMessageCoverage = assert(manifest.coverage["battle/script-message"])
  for _, resourceKey in ipairs({
    "message-bank/species-placeholder",
    "message-bank/move-placeholder",
    "message-bank/item-placeholder",
    "message-bank/status-placeholder",
  }) do
    Assert.isTrue(contains(scriptMessageCoverage.resources, resourceKey))
  end
  local commandMessageCoverage = assert(manifest.coverage["battle/command-message"])
  Assert.isTrue(contains(commandMessageCoverage.messageRoutes, "captureShake"))
  Assert.isTrue(contains(commandMessageCoverage.messageRoutes, "metBillPCTransfer"))
  for _, messageKey in ipairs({ "battle/capture-shakes/0", "battle/capture-shakes/4", "battle/pc-transfer/box-full/bill" }) do
    Assert.isTrue(contains(commandMessageCoverage.messageEntries, messageKey))
  end
  local frontierSpeechCoverage = assert(manifest.coverage["battle/frontier-trainer-speech"])
  Assert.isTrue(contains(frontierSpeechCoverage.messageRoutes, "battle/frontier-trainer-mail"))
  Assert.isTrue(contains(frontierSpeechCoverage.resources, "message-bank/mail-text/a"))
  Assert.isTrue(contains(frontierSpeechCoverage.resources, "message-bank/easy-chat/union"))
  Assert.isTrue(
    type(manifest.menus.layouts.bugContest) == "table",
    versionId .. ": Bug Contest exposes its fixed source-selected sprite resources"
  )
  Assert.isTrue(
    type(manifest.menus.layouts.vsRecorder) == "table",
    versionId .. ": VS Recorder exposes its independently loaded menu tilemap"
  )
  for _, key in ipairs({
    "frontier.character",
    "frontier.palette",
    "frontier.tilemap",
    "vsRecorder.tilemap",
  }) do
    local route, slot = key:match("^([^.]+)%.(.+)$")
    local layout = assert(manifest.menus.layouts[route], versionId .. ": menu layout " .. route .. " is present")
    local resourceKey = assert(layout[slot], versionId .. ": menu layout resource " .. key .. " is source selected")
    local descriptor =
      assert(manifest.resources[resourceKey], versionId .. ": layout resource has a catalog descriptor")
    Assert.equal(descriptor.contentIdentity:len(), 40, versionId .. ": layout content identity is SHA-1")
    Assert.notNil(
      bundle.resourcePayloads[descriptor.path],
      versionId .. ": selected menu resource is decoded for staging"
    )
  end
  local touchPaletteKey = assert(manifest.menus.layouts.frontier.touchPalette)
  local touchPalette = assert(manifest.resources[touchPaletteKey])
  Assert.equal(touchPalette.kind, "palette", versionId .. ": Frontier member 350 is a decoded touch palette")
  Assert.equal(
    touchPalette.contentIdentity,
    Hashing.sha1hex(readSourceMember(romFs, BattlePresentationSources.LOWER_NARC, 350)),
    versionId .. ": Frontier touch palette hashes the pinned palette member"
  )
  for _, slot in ipairs({ "character", "palette", "cell", "animation" }) do
    local resourceKey = assert(manifest.menus.layouts.bugContest[slot])
    local descriptor = assert(manifest.resources[resourceKey])
    local source = BattlePresentationSources.MENU_LAYOUT_RESOURCES.bugContest[slot]
    Assert.equal(descriptor.kind, source.kind, versionId .. ": Bug Contest " .. slot .. " keeps its typed payload")
    Assert.equal(
      descriptor.contentIdentity,
      Hashing.sha1hex(readSourceMember(romFs, source.archive, source.memberId)),
      versionId .. ": Bug Contest " .. slot .. " hashes its source payload"
    )
    Assert.notNil(bundle.resourcePayloads[descriptor.path], versionId .. ": Bug Contest " .. slot .. " is staged")
  end
  Assert.deepEqual(manifest.menus.layouts.bugContest.sprites, {
    sportBall = { x = 208, y = 16, palette = 5, animation = 0 },
    bugNet = { x = 88, y = 8, palette = 4, animation = 1 },
  }, versionId .. ": Bug Contest publishes only its fixed source-established sprite attributes")
  Assert.equal(
    manifest.menus.selectors["menu/vs-recorder"].screenGroup,
    "vs-recorder",
    versionId .. ": selector 18 resolves to its dedicated source tilemap group"
  )
  Assert.deepEqual(manifest.messages.routes["menu/vs-recorder-feedback"].branches, {
    paused = { "status/recorder-0", "status/recorder-1" },
    corrupted = { "status/recorder-2", "status/recorder-3" },
  }, versionId .. ": feedback message pairs retain the source comments' branch meanings")
  Assert.equal(bundle.provenance.recorderFeedbackFlags[0], "paused")
  Assert.equal(bundle.provenance.recorderFeedbackFlags[1], "corrupted")
  Assert.equal(
    bundle.provenance.recorderFeedbackUnreachableFlags[2],
    "battleTooLong",
    versionId .. ": the pinned status-2 row is identified as unreachable from current callers"
  )
  Assert.equal(
    manifest.messages.roles.bugContest.font,
    FieldFontCache.defPath(BattlePresentationSources.BUG_CONTEST_FONT_ID),
    versionId .. ": Bug Contest text uses its source-selected font role"
  )
  for semanticKey, source in pairs(BattlePresentationSources.MENU_LAYOUT_RESOURCES.frontier) do
    if semanticKey ~= "touchPalette" then
      local resourceKey = manifest.menus.layouts.frontier[semanticKey]
      local descriptor =
        assert(manifest.resources[resourceKey], versionId .. ": Frontier " .. semanticKey .. " is cataloged")
      Assert.equal(
        descriptor.contentIdentity,
        Hashing.sha1hex(readSourceMember(romFs, BattlePresentationSources.LOWER_NARC, source.memberId)),
        versionId .. ": Frontier " .. semanticKey .. " hashes its pinned source bytes"
      )
      Assert.equal(
        bundle.provenance.menuLayouts[resourceKey].memberId,
        source.memberId,
        versionId .. ": Frontier member identity is producer provenance only"
      )
    end
  end
  Assert.isTrue(type(manifest.menus.command) == "table", versionId .. ": menu render data belongs under menus")
  Assert.isTrue(
    type(manifest.hud.player) == "table" and type(manifest.hud.enemy) == "table",
    versionId .. ": both single-battle health boxes resolve under hud"
  )
  Assert.isTrue(
    type(manifest.menus.roles) == "table" and next(manifest.menus.roles) ~= nil,
    versionId .. ": menu roles carry semantic links"
  )
  Assert.isTrue(
    type(manifest.menus.selectors) == "table" and next(manifest.menus.selectors) ~= nil,
    versionId .. ": menu selectors retain source route distinctions"
  )
  Assert.isTrue(
    type(manifest.menus.modeRules) == "table" and manifest.menus.modeRules.standard ~= nil,
    versionId .. ": battle-type label branches normalize into semantic menu mode rules"
  )
  Assert.isTrue(
    type(manifest.menus.modeRules["bug-contest"].dynamicFields) == "table",
    versionId .. ": Bug Contest declares its dynamic display fields"
  )
  Assert.deepEqual(
    manifest.menus.runtimeContexts.bugContest.inputs,
    {
      "caughtPokemonSpecies",
      "caughtPokemonForm",
      "caughtPokemonGender",
      "caughtPokemonLevel",
      "remainingSafariBalls",
    },
    versionId .. ": Bug Contest names its exact live battle-state inputs"
  )
  Assert.deepEqual(
    manifest.menus.runtimeContexts.frontierLayout.inputs,
    { "frontierBattle" },
    versionId .. ": Frontier selector requires the source predicate result"
  )
  for routeKey, route in pairs(BattlePresentationSources.MENU_ROUTES) do
    local selector =
      assert(manifest.menus.selectors[routeKey], versionId .. ": menu route " .. routeKey .. " is normalized")
    Assert.equal(selector.screenGroup, route.screenGroup, versionId .. ": menu selector keeps its source screen group")
    Assert.equal(selector.textSet, route.textSet, versionId .. ": menu selector keeps its source text set")
    Assert.equal(selector.mode, route.mode, versionId .. ": source menu mode stays semantic")
    Assert.equal(selector.phase, route.phase, versionId .. ": source menu phase stays semantic")
    Assert.isNil(selector.sourceSelector, versionId .. ": native menu selector IDs stay producer-side")
  end
  local lowerArchive = assert(
    romFs:openNarc(BattlePresentationSources.LOWER_NARC),
    versionId .. ": the lower-screen archive opens for map comparison"
  )
  for _, menuName in ipairs({ "command", "moves", "target", "twoOption" }) do
    for index, screen in ipairs(manifest.menus[menuName].screens) do
      local tilemapKey = assert(
        screen.tilemapKey,
        versionId .. ": " .. menuName .. " screen " .. index .. " retains its native tilemap resource"
      )
      local descriptor = assert(
        manifest.resources[tilemapKey],
        versionId .. ": each tilemap reference resolves to a source-backed resource"
      )
      Assert.equal(descriptor.kind, "map", versionId .. ": menu tilemaps retain their decoded resource kind")
      local payload = assert(
        bundle.resourcePayloads[descriptor.path],
        versionId .. ": menu tilemap bytes are staged as a decoded payload"
      )
      local sourceMember = assert(
        bundle.provenance.menuTilemaps[tilemapKey],
        versionId .. ": tilemap member identity stays in producer provenance"
      ).memberId
      local sourceBytes =
        assert(lowerArchive:readMember(sourceMember), versionId .. ": source tilemap member is readable")
      local decodedBytes = sourceBytes
      if string.byte(sourceBytes, 1) == 0x10 then
        decodedBytes = assert(Lz10.decode(sourceBytes), versionId .. ": source tilemap compression decodes")
      end
      Assert.equal(
        descriptor.contentIdentity,
        Hashing.sha1hex(sourceBytes),
        versionId .. ": menu tilemap identity hashes the exact selected member bytes"
      )
      local sourceMap = assert(
        G2dDecoder.decodeScreen(decodedBytes, { label = "menu tilemap source comparison" }),
        versionId .. ": source tilemap decodes through the shared Nintendo decoder"
      )
      Assert.deepEqual(payload, sourceMap, versionId .. ": normalized tilemap payload retains every source map entry")
    end
  end
  Assert.isTrue(
    type(manifest.layouts.menu.layers) == "table" and #manifest.layouts.menu.layers == 4,
    versionId .. ": the normalized menu layout has four source layers"
  )
  Assert.isTrue(
    type(manifest.hud.roles) == "table" and next(manifest.hud.roles) ~= nil,
    versionId .. ": HUD roles are source-backed"
  )
  Assert.isTrue(
    type(manifest.hud.selectors) == "table" and next(manifest.hud.selectors) ~= nil,
    versionId .. ": HUD selectors identify single and double compositions"
  )
  Assert.isTrue(
    type(manifest.pictures.selectors) == "table" and next(manifest.pictures.selectors) ~= nil,
    versionId .. ": picture selectors carry semantic keys"
  )
  Assert.isTrue(
    type(manifest.messages.entries) == "table" and next(manifest.messages.entries) ~= nil,
    versionId .. ": message records are normalized under messages"
  )
  Assert.deepEqual(manifest.messages.banks.scriptController, "message-bank/battle-script-controller")
  Assert.deepEqual(manifest.messages.banks.frontierTrainerProfileZero, "message-bank/trainer-profile-zero")
  Assert.deepEqual(
    manifest.messages.banks.frontierTrainerProfileFallback,
    "message-bank/trainer-profile-fallback"
  )
  Assert.deepEqual(manifest.messages.banks.trainerPairLookup, "message-bank/trainer-pair-lookup")
  Assert.deepEqual(manifest.messages.banks.tutorialAuthor, "message-bank/tutorial-author")
  for role, resourceKey in pairs(manifest.messages.banks) do
    local descriptor = assert(
      manifest.resources[resourceKey],
      versionId .. ": message bank role " .. role .. " references a staged resource"
    )
    Assert.equal(descriptor.kind, "message")
    Assert.notNil(bundle.resourcePayloads[descriptor.path])
    Assert.notNil(bundle.provenance.messageBanks[role].memberId)
  end
  Assert.deepEqual(manifest.messages.dynamicRoutes.captureShake, {
    bank = "message-bank/battle-script-controller",
    input = "captureShakeCount",
    firstRecord = "battle/capture-shakes/0",
    minimum = 0,
    maximum = 4,
    recordCount = 5,
  })
  Assert.deepEqual(manifest.messages.dynamicRoutes.metBillPCTransfer.inputs, { "metBill", "pcHasSpace" })
  Assert.equal(
    manifest.messages.roles.trainerNarration.font,
    FieldFontCache.defPath(BattlePresentationSources.BATTLE_FONT_ID),
    versionId .. ": battle narration retains its source FontID 1 role"
  )
  Assert.equal(
    manifest.messages.roles.hud.font,
    FieldFontCache.defPath(BattlePresentationSources.HUD_MESSAGE_FONT_ID),
    versionId .. ": battle HP and auxiliary text retain their source FontID 0 role"
  )
  local messageArchive = assert(
    romFs:openNarc(BattlePresentationSources.MENU_MESSAGE_BANK),
    versionId .. ": the source message archive opens"
  )
  local messageBank = assert(
    UiMessageBank.read(messageArchive, 197, "acceptance source comparison", {}, "battle-messages"),
    versionId .. ": the native battle message bank decodes"
  )
  for messageKey, messageId in pairs(BattlePresentationSources.MENU_MESSAGES) do
    local sourceTokens = assert(
      UiMessageBank.tokens(messageBank, 197, messageId, charmap),
      versionId .. ": source message " .. messageKey .. " tokenizes"
    )
    local entry =
      assert(manifest.messages.entries[messageKey], versionId .. ": source message has a semantic catalog key")
    Assert.deepEqual(entry.tokens, sourceTokens, versionId .. ": normalized message tokens match their source record")
  end
  Assert.isNil(manifest.messages.entries[924], versionId .. ": message IDs are not runtime catalog keys")
  Assert.equal(
    manifest.messages.roles.menu.font,
    "data/generated/field/font/font-4.lua",
    versionId .. ": menu text maps font ID 4 to its generated semantic definition"
  )
  Assert.isTrue(
    type(manifest.messages.routes) == "table" and manifest.messages.routes["menu/bug-contest-level"] ~= nil,
    versionId .. ": known placeholder-driven menu messages retain their semantic routes"
  )
  Assert.isTrue(
    type(manifest.transitions.selectors) == "table" and next(manifest.transitions.selectors) ~= nil,
    versionId .. ": transition routes retain their unresolved source conditions"
  )
  Assert.isFalse(
    manifest.transitions.selectors.trainerEncounter.resolved,
    versionId .. ": setup-dependent transition routes remain unresolved"
  )
  local fallback = manifest.transitions.selectors.setupFallback
  Assert.deepEqual(
    fallback.inputs,
    { "battleType", "terrain", "timeOfDay" },
    versionId .. ": fallback routes name their exact source context axes"
  )
  Assert.equal(fallback.terrainOffset.cave, 4, versionId .. ": cave selects the source fallback branch")
  Assert.equal(fallback.terrainOffset.water, 2, versionId .. ": water selects the source fallback branch")
  Assert.deepEqual(fallback.offsetTimes, { "night", "late" }, versionId .. ": fallback time branches are source-backed")
  local spriteSet = assert(
    manifest.transitions.resourceSets["transition/sprite-set/a"],
    versionId .. ": the source-confirmed transition sprite group is represented"
  )
  local paletteKey = assert(spriteSet.palette, versionId .. ": the transition group names its palette resource")
  local palette = assert(manifest.resources[paletteKey], versionId .. ": the palette has a normalized descriptor")
  Assert.equal(palette.kind, "palette", versionId .. ": the descriptor retains the loader resource kind")
  Assert.isTrue(
    type(palette.contentIdentity) == "string" and #palette.contentIdentity == 40,
    versionId .. ": the descriptor binds source bytes by content identity"
  )
  Assert.isNil(
    manifest.resources["transition/sprite-set/a"],
    versionId .. ": resource sets are not mislabeled as individual resources"
  )
  local transitionArchive = assert(
    romFs:openNarc(BattlePresentationSources.TRANSITION_ARCHIVE),
    versionId .. ": the source transition archive opens"
  )
  for _, sourceSet in ipairs(BattlePresentationSources.TRANSITION_RESOURCE_SETS) do
    for _, sourceResource in ipairs(sourceSet.resources) do
      local resourceKey = sourceSet.key .. "/" .. sourceResource.key
      local descriptor =
        assert(manifest.resources[resourceKey], versionId .. ": verified transition resource is cataloged")
      local sourceBytes = assert(
        transitionArchive:readMember(sourceResource.member),
        versionId .. ": source transition member is readable"
      )
      Assert.equal(descriptor.kind, sourceResource.kind, versionId .. ": transition loader kind is source-backed")
      Assert.equal(
        descriptor.contentIdentity,
        Hashing.sha1hex(sourceBytes),
        versionId .. ": transition content identity hashes the selected source bytes"
      )
      Assert.isTrue(
        type(descriptor.path) == "string" and descriptor.path:find("^data/generated/battle/resources/") ~= nil,
        versionId .. ": transition resources have owned cache payload paths"
      )
      local payload = assert(
        bundle.resourcePayloads[descriptor.path],
        versionId .. ": every source-confirmed transition resource is decoded into its staged payload"
      )
      if sourceResource.kind == "palette" then
        Assert.isTrue(
          type(payload.colors) == "table" and #payload.colors > 0,
          versionId .. ": palettes retain decoded colors"
        )
      elseif sourceResource.kind == "texture" then
        Assert.isTrue(
          (payload.depth == 3 or payload.depth == 4) and #payload.tiles > 0,
          versionId .. ": character resources retain decoded pixels and depth"
        )
      elseif sourceResource.kind == "cell" then
        Assert.isTrue(
          type(payload.cells) == "table" and #payload.cells > 0,
          versionId .. ": cell resources retain decoded OBJ geometry"
        )
      elseif sourceResource.kind == "animation" then
        Assert.isTrue(
          type(payload.anims) == "table" and #payload.anims > 0,
          versionId .. ": animation resources retain decoded frame programs"
        )
      else
        Assert.fail("transition resource kind has a decoder: " .. sourceResource.kind)
      end
      Assert.equal(
        bundle.provenance.transitionResources[resourceKey].memberId,
        sourceResource.member,
        versionId .. ": physical transition member identity stays in producer provenance"
      )
    end
  end
  Assert.isTrue(
    type(manifest.programs) == "table" and next(manifest.programs) ~= nil,
    versionId .. ": the global catalog closes its executable programs"
  )
  Assert.isTrue(
    type(manifest.coverage) == "table" and next(manifest.coverage) ~= nil,
    versionId .. ": the global catalog closes semantic root coverage"
  )

  local function scan(value, path)
    if type(value) ~= "table" then
      return
    end
    for key, nested in pairs(value) do
      Assert.isFalse(
        key == "memberId" or key == "fileId" or key == "narcId" or key == "sourceSelector",
        versionId .. ": the catalog leaks source detail '" .. tostring(key) .. "' at " .. path
      )
      scan(nested, path .. "." .. tostring(key))
    end
  end
  scan(manifest, "manifest")
end

function T.source_traced_transition_payloads_are_decoded_and_content_addressed(romFs, versionId)
  local compiler, _ = presentationBoundary(romFs, versionId)
  local bundle = compileGlobal(compiler, romFs, versionId)
  Assert.deepEqual(
    bundle.provenance.transitionSelectorFamilies,
    BattlePresentationSources.TRANSITION_SELECTOR_FAMILIES,
    versionId .. ": transition dispatch family evidence remains producer provenance"
  )
  local transitionKeys = {}
  for _, key in
    ipairs(assert(bundle.manifest.transitions.resources, versionId .. ": transition payload catalog is present"))
  do
    transitionKeys[key] = true
  end
  for _, source in ipairs(BattlePresentationSources.TRANSITION_TYPED_RESOURCES) do
    local provenanceKey = source.kind .. ":" .. source.memberId
    local key = assert(
      bundle.provenance.transitionSourceResources[provenanceKey],
      versionId .. ": source-selected transition payload " .. provenanceKey .. " was decoded"
    )
    local descriptor = assert(bundle.manifest.resources[key], versionId .. ": decoded transition resource is cataloged")
    Assert.isTrue(transitionKeys[key], versionId .. ": transition section references its decoded payload")
    Assert.equal(descriptor.kind, source.kind, versionId .. ": loader call determines decoded resource kind")
    Assert.equal(
      descriptor.contentIdentity,
      Hashing.sha1hex(readSourceMember(romFs, BattlePresentationSources.TRANSITION_ARCHIVE, source.memberId)),
      versionId .. ": transition resource identity hashes the selected HeartGold bytes"
    )
    Assert.notNil(bundle.resourcePayloads[descriptor.path], versionId .. ": decoded transition payload is stageable")
    Assert.notNil(
      bundle.provenance.transitionResourceMembers[key].members[source.memberId],
      versionId .. ": physical transition member remains in provenance"
    )
  end
  local transitionArchive = assert(romFs:openNarc(BattlePresentationSources.TRANSITION_ARCHIVE))
  for _, memberId in ipairs({ 0x97, 0x98 }) do
    local bytes = assert(transitionArchive:readMember(memberId))
    local decoded = assert(Spl.decode(bytes, { role = "overlay-115 transition particle" }))
    local particleKey = assert(
      bundle.provenance.transitionSourceResources["particle:" .. memberId],
      versionId .. ": SPL loader member is decoded and staged"
    )
    local descriptor = assert(bundle.manifest.resources[particleKey])
    Assert.equal(descriptor.kind, "particle")
    Assert.equal(descriptor.contentIdentity, Hashing.sha1hex(bytes))
    Assert.equal(#bundle.resourcePayloads[descriptor.path].resources, #decoded.resources)
    Assert.isFalse(
      bundle.provenance.transitionSourceResources["model:" .. memberId] ~= nil,
      versionId .. ": SPL payloads do not enter the model resource family"
    )
  end
  Assert.isFalse(
    bundle.manifest.transitions.selectors.trainerEncounter.resolved,
    versionId .. ": runtime route closure remains blocked"
  )
  Assert.deepEqual(
    bundle.manifest.transitions.messageRoutes.trainerName.inputs,
    { "trainerName" },
    versionId .. ": overlay115/117 trainer-name route has a typed runtime input"
  )
  Assert.deepEqual(
    bundle.manifest.transitions.messageRoutes.rivalName.inputs,
    { "rivalName" },
    versionId .. ": overlay115 rival-name route has a typed runtime input"
  )
  for _, routeName in ipairs({ "trainerName", "rivalName" }) do
    local route = bundle.manifest.transitions.messageRoutes[routeName]
    Assert.equal(route.message, "transition/trainer-name", versionId .. ": name route selects the staged bank-189 record")
    Assert.isTrue(#route.resources > 0, versionId .. ": source loader resources are linked to the name route")
    local routeResources = {}
    for _, key in ipairs(route.resources) do
      Assert.notNil(bundle.manifest.resources[key], versionId .. ": message route resource is semantic and staged")
      routeResources[key] = true
    end
    for _, selector in ipairs(BattlePresentationSources.TRANSITION_MESSAGE_SOURCE_ROUTES[routeName].selectors) do
      for _, source in ipairs(BattlePresentationSources.TRANSITION_TYPED_RESOURCES) do
        for _, sourceSelector in ipairs(source.selectors) do
          if selector == sourceSelector then
            local sourceKey = bundle.provenance.transitionSourceResources[source.kind .. ":" .. source.memberId]
            Assert.isTrue(routeResources[sourceKey], versionId .. ": route links every source-selected loader resource")
            break
          end
        end
      end
    end
  end
  local semanticTransitions = bundle.manifest.transitions.routes
  Assert.isTrue(type(semanticTransitions) == "table", versionId .. ": per-selector source routes are normalized")
  for _, sourceRoute in pairs(BattlePresentationSources.TRANSITION_SELECTOR_ROUTES) do
    local routeKey = assert(sourceRoute.key, "source route has a semantic key")
    local route = assert(semanticTransitions[routeKey], versionId .. ": transition route " .. routeKey .. " is emitted")
    Assert.equal(route.role, sourceRoute.role, versionId .. ": transition route role is source-normalized")
    Assert.isTrue(type(route.resources) == "table", versionId .. ": transition route carries staged resource references")
    for _, resourceKey in ipairs(route.resources) do
      Assert.notNil(bundle.manifest.resources[resourceKey], versionId .. ": transition route resource is staged")
      Assert.isTrue(type(resourceKey) == "string", versionId .. ": transition route resource keys are semantic")
    end
    Assert.isNil(route.sourceSelector, versionId .. ": native selector indexes stay producer-side")
  end
  for selector = 12, 27 do
    local sourceRoute = assert(BattlePresentationSources.TRANSITION_SELECTOR_ROUTES[selector])
    local route = assert(semanticTransitions[sourceRoute.key])
    Assert.deepEqual(
      route.messages,
      { "transition/trainer-name" },
      versionId .. ": trainer transition " .. sourceRoute.key .. " closes its name message"
    )
  end
  local rivalRoute = assert(semanticTransitions["trainer/rival-or-passerby"])
  Assert.deepEqual(
    rivalRoute.messages,
    { "transition/rival-name" },
    versionId .. ": selector 28 keeps the rival name route"
  )
  for selector = 29, 33 do
    local sourceRoute = assert(BattlePresentationSources.TRANSITION_SELECTOR_ROUTES[selector])
    local route = assert(semanticTransitions[sourceRoute.key])
    Assert.deepEqual(
      route.messages,
      { "transition/trainer-name" },
      versionId .. ": elite trainer transition closes the shared trainer-name template"
    )
    Assert.deepEqual(route.trainer, { key = sourceRoute.trainer.key })
    Assert.equal(
      bundle.provenance.transitionSelectorRoutes[selector].trainer.trainerId,
      sourceRoute.trainer.trainerId,
      versionId .. ": physical trainer selector remains producer provenance"
    )
    Assert.isTrue(
      route.requiredContext[#route.requiredContext] == "transitionTrainer",
      versionId .. ": elite trainer transition declares its semantic trainer selector"
    )
  end
  Assert.isTrue(
    type(semanticTransitions["trainer/red"].assetGroups.sprite) == "table",
    versionId .. ": Red transition route retains its typed sprite group"
  )
  local selection = bundle.manifest.transitions.selection
  for _, routeMap in ipairs({ selection.trainerClassRoutes, selection.wildSpeciesRoutes }) do
    for inputKey, routeKey in pairs(routeMap) do
      Assert.isTrue(type(inputKey) == "string", versionId .. ": transition inputs are semantic keys")
      Assert.isTrue(
        routeKey == "setup-fallback" or semanticTransitions[routeKey] ~= nil,
        versionId .. ": transition selection resolves to a semantic route"
      )
    end
  end
  Assert.isNil(selection.categoryRoutes, versionId .. ": native category indexes remain producer-side")
  Assert.equal(selection.trainerClassRoutes["trainer/red"], "trainer/red")
  Assert.equal(selection.wildSpeciesRoutes["wild/ho-oh"], "wild/ho-oh")
  Assert.equal(
    selection.trainerRules.specialBattle.doublesRoute,
    "wild/generic",
    versionId .. ": source special/doubles override resolves to a semantic route"
  )
  Assert.equal(#selection.fallbackRoutes, 12, versionId .. ": setup fallback covers every source context combination")
  local eliteIntro = assert(semanticTransitions["trainer/will"])
  Assert.deepEqual(
    eliteIntro.requiredContext,
    { "battleType", "playerTrainerGender", "trainerClass", "trainerName", "transitionTrainer" }
  )
  Assert.isTrue(type(eliteIntro.assetGroups.spriteVariants.male) == "table")
  Assert.isTrue(type(eliteIntro.assetGroups.spriteVariants.female) == "table")
  local hasParticle = false
  for _, resourceKey in ipairs(eliteIntro.resources) do
    hasParticle = hasParticle or bundle.manifest.resources[resourceKey].kind == "particle"
  end
  Assert.isTrue(hasParticle, versionId .. ": trainer intro route links its decoded particle definitions")
  Assert.isNil(semanticTransitions["trainer/team-rocket"].assetGroups.background)
  Assert.isTrue(
    type(semanticTransitions["trainer/petrel"].assetGroups.background) == "table",
    versionId .. ": selector 40 includes its loader-proven shared background group"
  )
  local redSprite = bundle.manifest.transitions.internalResources.sprite
  local sourceResources = BattlePresentationSources.TRANSITION_INTERNAL_RESOURCES.sprite
  local sourceKinds = { palette = "palette", character = "texture", cell = "cell", animation = "animation" }
  for role, memberId in pairs(sourceResources) do
    local key = redSprite[role]
    Assert.equal(key, bundle.provenance.transitionSourceResources[sourceKinds[role] .. ":" .. memberId])
    Assert.notNil(bundle.manifest.resources[key], versionId .. ": Red selector route references decoded resources")
  end
  local selector9 = { palette = 1, texture = 7, cell = 9, animation = 8 }
  for kind, memberId in pairs(selector9) do
    local resourceKey = assert(
      bundle.provenance.transitionSourceResources[kind .. ":" .. memberId],
      versionId .. ": selector 9 source-proven " .. kind .. " payload is decoded"
    )
    Assert.isTrue(
      bundle.provenance.transitionResourceMembers[resourceKey].members[memberId].selectors[9],
      versionId .. ": selector 9 " .. kind .. " route stays in producer provenance"
    )
    Assert.notNil(
      bundle.resourcePayloads[bundle.manifest.resources[resourceKey].path],
      versionId .. ": selector 9 " .. kind .. " payload is staged"
    )
  end
end

function T.transition_aps_members_are_decoded_and_embedded_payloads_are_staged(romFs, versionId)
  local archive = assert(romFs:openNarc(BattlePresentationSources.TRANSITION_ARCHIVE))
  Assert.deepEqual(BattlePresentationSources.TRANSITION_PARTICLE_MEMBERS, { 0x97, 0x98 })

  for _, memberId in ipairs(BattlePresentationSources.TRANSITION_PARTICLE_MEMBERS) do
    local bytes = assert(archive:readMember(memberId))
    local decoded, decodeFailure = Spl.decode(bytes)
    Assert.notNil(
      decoded,
      versionId .. ": APS member " .. memberId .. " decodes: " .. tostring(decodeFailure)
    )
  end
  local compiler = presentationBoundary(romFs, versionId)
  local bundle = compileGlobal(compiler, romFs, versionId)
  for _, memberId in ipairs(BattlePresentationSources.TRANSITION_PARTICLE_MEMBERS) do
    local bytes = assert(archive:readMember(memberId))
    local decoded = assert(Spl.decode(bytes))
    local resourceKey = assert(
      bundle.provenance.transitionSourceResources["particle:" .. memberId],
      versionId .. ": the SPL loader's APS member is retained as producer provenance"
    )
    local descriptor = assert(bundle.manifest.resources[resourceKey])
    Assert.equal(descriptor.kind, "particle", versionId .. ": APS data has a particle resource kind")
    Assert.equal(descriptor.format, "nitro-spl-aps-v1")
    Assert.equal(descriptor.contentIdentity, Hashing.sha1hex(bytes))
    local staged = assert(bundle.resourcePayloads[descriptor.path])
    Assert.equal(staged.format, "APS12_1")
    Assert.equal(#staged.emitters, #decoded.emitters)
    Assert.equal(#staged.resources, #decoded.resources)
    for _, entry in ipairs(staged.resources) do
      if entry.textureKey ~= nil then
        local texture = assert(bundle.manifest.resources[entry.textureKey])
        Assert.equal(texture.kind, "texture")
        Assert.notNil(bundle.resourcePayloads[texture.path])
      end
      if entry.paletteKey ~= nil then
        local palette = assert(bundle.manifest.resources[entry.paletteKey])
        Assert.equal(palette.kind, "palette")
        Assert.notNil(bundle.resourcePayloads[palette.path])
      end
    end
  end
end

function T.transition_name_expansion_message_is_source_loaded_and_normalized(romFs, versionId)
  local compiler, _ = presentationBoundary(romFs, versionId)
  local bundle = compileGlobal(compiler, romFs, versionId)
  local key = "transition/trainer-name"
  Assert.notNil(bundle.manifest.messages.entries[key], versionId .. ": transition name template is present")
  Assert.deepEqual(
    bundle.manifest.messages.routes["transition/trainer-name"],
    { template = key, inputs = { "trainerName" } },
    versionId .. ": transition message route retains its source-proven dynamic name input"
  )
  Assert.deepEqual(
    bundle.manifest.messages.routes["transition/rival-name"],
    { template = key, inputs = { "rivalName" } },
    versionId .. ": rival-name expansion stays a separate semantic route"
  )
  Assert.equal(
    bundle.provenance.transitionMessage.memberId,
    BattlePresentationSources.TRANSITION_MESSAGE_MEMBER,
    versionId .. ": physical transition message bank stays in provenance"
  )
  Assert.deepEqual(
    bundle.provenance.transitionMessageRoutes,
    BattlePresentationSources.TRANSITION_MESSAGE_SOURCE_ROUTES,
    versionId .. ": overlay 115/117 message call routing stays producer provenance"
  )
end

function T.picture_attributes_preserve_picture_height_and_animation_data(romFs, versionId)
  local compiler, _ = presentationBoundary(romFs, versionId)
  local manifest = compileGlobal(compiler, romFs, versionId).manifest
  local attributes = manifest.pictures.attributes
  local selectors = manifest.pictures.selectors
  Assert.isTrue(type(attributes) == "table", versionId .. ": the manifest carries picture attributes")
  Assert.isTrue(next(attributes) ~= nil, versionId .. ": the picture attribute catalog contains source records")
  local hasPositiveHeight = false
  local hasZeroHeight = false
  for pictureKey, record in pairs(attributes) do
    Assert.isTrue(type(pictureKey) == "string" and pictureKey ~= "", versionId .. ": picture records use semantic keys")
    Assert.isTrue(type(record) == "table", versionId .. ": each picture attribute record is structured")
    Assert.isTrue(
      type(record.height) == "number" and record.height >= 0 and record.height == math.floor(record.height),
      versionId .. ": " .. pictureKey .. " retains its source picture height (" .. tostring(record.height) .. ")"
    )
    hasPositiveHeight = hasPositiveHeight or record.height > 0
    hasZeroHeight = hasZeroHeight or record.height == 0
    Assert.isTrue(
      type(record.animation) == "table",
      versionId .. ": " .. pictureKey .. " retains its source animation attributes"
    )
    Assert.isTrue(
      type(record.animation.steps) == "table" and #record.animation.steps == 10,
      versionId .. ": " .. pictureKey .. " retains all ten ordered native animation entries"
    )
    for _, step in ipairs(record.animation.steps) do
      Assert.isTrue(
        type(step.next) == "number"
          and step.next == math.floor(step.next)
          and type(step.duration) == "number"
          and step.duration >= 0
          and step.duration <= 255
          and type(step.xOffset) == "number"
          and step.xOffset >= -128
          and step.xOffset <= 127
          and type(step.auxiliary) == "number"
          and step.auxiliary >= -128
          and step.auxiliary <= 127,
        versionId .. ": " .. pictureKey .. " retains each complete, range-valid animation entry"
      )
    end
  end
  Assert.isTrue(hasPositiveHeight, versionId .. ": the source catalog includes positive picture heights")
  Assert.isTrue(hasZeroHeight, versionId .. ": valid zero picture heights remain in the catalog")

  local speciesId = assert(MonSources.speciesId("CHIKORITA"), "the source catalog resolves CHIKORITA")
  local animationBytes = readSourceMember(
    romFs,
    BattlePresentationSources.PICTURE_ANIMATION_NARC,
    BattlePresentationSources.PICTURE_ANIMATION_MEMBER
  )
  for _, facing in ipairs({ "front", "back" }) do
    local pictureKey = "pokemon/CHIKORITA/form-0/male/" .. facing
    local record =
      assert(attributes[pictureKey], versionId .. ": CHIKORITA has its semantic " .. facing .. " animation record")
    Assert.deepEqual(selectors[pictureKey], {
      species = "CHIKORITA",
      form = 0,
      gender = "male",
      facing = facing,
      attributes = pictureKey,
    }, versionId .. ": picture selection is expressed in source-normalized axes")
    local facingOffset = facing == "front" and 0 or 43
    local recordOffset = speciesId * BattlePresentationSources.PICTURE_ANIMATION_RECORD_SIZE + facingOffset + 3
    for stepIndex = 0, 9 do
      local offset = recordOffset + stepIndex * 4
      local sourceNext = assert(string.byte(animationBytes, offset + 1), "source next byte exists")
      local sourceDuration = assert(string.byte(animationBytes, offset + 2), "source duration byte exists")
      local sourceXOffset = assert(string.byte(animationBytes, offset + 3), "source x-offset byte exists")
      local sourceAuxiliary = assert(string.byte(animationBytes, offset + 4), "source auxiliary byte exists")
      if sourceNext >= 128 then
        sourceNext = sourceNext - 256
      end
      if sourceXOffset >= 128 then
        sourceXOffset = sourceXOffset - 256
      end
      if sourceAuxiliary >= 128 then
        sourceAuxiliary = sourceAuxiliary - 256
      end
      local step = record.animation.steps[stepIndex + 1]
      Assert.equal(step.next, sourceNext, versionId .. ": source animation order retains the next byte")
      Assert.equal(step.duration, sourceDuration, versionId .. ": source animation order retains the duration byte")
      Assert.equal(step.xOffset, sourceXOffset, versionId .. ": source animation order retains the signed x offset")
      Assert.equal(step.auxiliary, sourceAuxiliary, versionId .. ": source animation order retains the fourth byte")
    end
  end
end

---@param manifest table
---@param background string
---@param terrain string
---@param time string
---@return string scene key
local function findSceneKey(manifest, background, terrain, time)
  Assert.isTrue(type(manifest.scenes) == "table", "the manifest inventories its supported scene keys")
  for _, entry in ipairs(manifest.scenes) do
    if entry.background == background and entry.terrain == terrain and entry.time == time then
      Assert.isTrue(type(entry.key) == "string" and entry.key ~= "", "the scene entry carries its key")
      return entry.key
    end
  end
  error("no scene key for " .. background .. "/" .. terrain .. "/" .. time .. " in the supported inventory", 0)
end

---@param compiler table
---@param romFs table
---@param versionId string
---@param manifest table
---@param background string
---@param terrain string
---@param time string
---@return table scene record
local function compileScene(compiler, romFs, versionId, manifest, background, terrain, time)
  Assert.isTrue(type(compiler.compileScene) == "function", versionId .. ": the compiler exposes a scene entry point")
  local key = findSceneKey(manifest, background, terrain, time)
  local scene = assert(
    compiler.compileScene(romFs, { versionId = versionId }, key),
    versionId .. ": scene " .. key .. " must compile from the dump"
  )
  return scene
end

---@param compiler table source scene compiler
---@param romFs table borrowed ROM filesystem
---@param versionId string selected source version
---@param sceneKey string canonical scene identity
---@return table decoded source scene
local function compileSourceScene(compiler, romFs, versionId, sceneKey)
  local scene, reason = compiler.compileScene(romFs, { versionId = versionId }, sceneKey)
  Assert.isNil(reason, versionId .. ": source scene compiles: " .. sceneKey)
  return assert(scene, versionId .. ": source scene exists: " .. sceneKey)
end

function T.persistent_scenes_compile_per_background_terrain_and_time(romFs, versionId)
  local compiler, _ = presentationBoundary(romFs, versionId)
  local bundle = compileGlobal(compiler, romFs, versionId)
  local manifest = bundle.manifest
  local day = compileScene(compiler, romFs, versionId, manifest, "general", "grass", "day")
  assertScenePixelMatchesBg3(day, 0, 0, versionId .. ": grass day")
  Assert.equal(day.canvasWidth, 512, versionId .. ": the persistent scene keeps its 512-wide source canvas")
  Assert.equal(day.canvasHeight, 256, versionId .. ": the persistent scene keeps its 256-high source canvas")
  Assert.notNil(day.image, versionId .. ": the scene record references its composed image")
  Assert.notNil(day.viewport, versionId .. ": the scene record maps its visible region")
  Assert.isTrue(
    day.viewport.x + day.viewport.width <= day.canvasWidth and day.viewport.y + day.viewport.height <= day.canvasHeight,
    versionId .. ": the visible region stays inside the source canvas"
  )
  Assert.equal(#day.layers, 1, versionId .. ": the scene carries its composed BG3 source plane")
  local layer = day.layers[1]
  Assert.equal(layer.key, "background", versionId .. ": the scene layer has a semantic key")
  Assert.equal(layer.backing.width, 512, versionId .. ": the BG3 backing retains its native pixel width")
  Assert.equal(layer.backing.height, 256, versionId .. ": the BG3 backing retains its native pixel height")
  Assert.equal(layer.backing.mapWidth, 64, versionId .. ": the BG3 map retains its native tile width")
  Assert.equal(layer.backing.mapHeight, 32, versionId .. ": the BG3 map retains its native tile height")
  Assert.equal(layer.viewport.width, 256, versionId .. ": the native viewport width is explicit")
  Assert.equal(layer.viewport.height, 192, versionId .. ": the native viewport height is explicit")
  Assert.equal(layer.scroll.x, 0, versionId .. ": source initialization places BG3 at horizontal origin")
  Assert.equal(layer.scroll.y, 0, versionId .. ": source initialization places BG3 at vertical origin")
  Assert.isTrue(
    layer.characters.path ~= nil and layer.map.path ~= nil and layer.palette.path ~= nil,
    versionId .. ": the BG3 closure names staged characters, map, and palette resources"
  )
  Assert.equal(
    #day.layerPayloads[1].characters,
    65536,
    versionId .. ": the layer closure carries the decoded 8bpp character tile bytes"
  )
  Assert.equal(day.layerPayloads[1].map.width, 512, versionId .. ": the BG3 map payload retains pixel width")
  Assert.equal(day.layerPayloads[1].map.height, 256, versionId .. ": the BG3 map payload retains pixel height")
  Assert.equal(#day.layerPayloads[1].map.entries, 2048, versionId .. ": the BG3 map payload carries all 64x32 entries")
  Assert.equal(
    #day.layerPayloads[1].palette.colors,
    256,
    versionId .. ": the patched background carries its full palette"
  )
  local plain = compileScene(compiler, romFs, versionId, manifest, "general", "plain", "day")
  assertScenePixelMatchesBg3(plain, 0, 0, versionId .. ": plain day")
  Assert.isTrue(
    plain.layerPayloads[1].characters ~= day.layerPayloads[1].characters,
    versionId .. ": terrain selection changes the native patched character payload"
  )
  Assert.equal(
    day.buildMetadata.background.archiveSymbol,
    "NARC_a_0_0_7",
    versionId .. ": background provenance names its source archive"
  )
  Assert.isTrue(
    type(day.buildMetadata.background.charactersMember) == "number",
    versionId .. ": background character provenance names its source member"
  )
  Assert.equal(
    day.buildMetadata.terrain.archiveSymbol,
    "NARC_a_0_0_8",
    versionId .. ": terrain source provenance is explicit"
  )
  Assert.equal(
    day.buildMetadata.palette.archiveSymbol,
    "NARC_a_0_0_7",
    versionId .. ": palette source provenance is explicit"
  )
  Assert.equal(
    day.buildMetadata.palette.selection,
    "day",
    versionId .. ": palette variant selection provenance is explicit"
  )
  Assert.isTrue(
    type(day.buildMetadata.terrain.paletteMember) == "number"
      and type(day.buildMetadata.terrain.type0Member) == "number"
      and type(day.buildMetadata.terrain.type1Member) == "number"
      and type(day.buildMetadata.palette.member) == "number",
    versionId .. ": terrain and palette provenance names the selected source members"
  )
  local evening = compileScene(compiler, romFs, versionId, manifest, "general", "grass", "evening")
  local night = compileScene(compiler, romFs, versionId, manifest, "general", "grass", "night")
  assertScenePixelMatchesBg3(evening, 0, 0, versionId .. ": grass evening")
  assertScenePixelMatchesBg3(night, 0, 0, versionId .. ": grass night")
  Assert.isTrue(evening.image ~= day.image, versionId .. ": evening palette selection changes the composed scene")
  Assert.isTrue(night.image ~= day.image, versionId .. ": night palette selection changes the composed scene")
  local cave = compileScene(compiler, romFs, versionId, manifest, "cave_1", "cave", "day")
  assertScenePixelMatchesBg3(cave, 0, 0, versionId .. ": indoor cave fixed-day")
  Assert.isTrue(cave.image ~= day.image, versionId .. ": a second background family follows its own recipe")
  local dayAgain = compileScene(compiler, romFs, versionId, manifest, "general", "grass", "day")
  assertScenePixelMatchesBg3(dayAgain, 0, 0, versionId .. ": grass day again")
  Assert.equal(dayAgain.image, day.image, versionId .. ": scene compilation is deterministic")
end

function T.persistent_scene_variants_match_their_decoded_bg3_pixels(romFs, versionId)
  local compiler, _ = presentationBoundary(romFs, versionId)
  local day = compileSourceScene(compiler, romFs, versionId, "general/grass/day")
  local evening = compileSourceScene(compiler, romFs, versionId, "general/grass/evening")
  local night = compileSourceScene(compiler, romFs, versionId, "general/grass/night")
  local indoor = compileSourceScene(compiler, romFs, versionId, "cave_1/cave/day")
  assertScenePixelMatchesBg3(day, 0, 0, versionId .. ": decoded grass day")
  assertScenePixelMatchesBg3(evening, 0, 0, versionId .. ": decoded grass evening")
  assertScenePixelMatchesBg3(night, 0, 0, versionId .. ": decoded grass night")
  assertScenePixelMatchesBg3(indoor, 0, 0, versionId .. ": decoded indoor cave")
  Assert.isTrue(day.image ~= evening.image, versionId .. ": the evening source palette changes output pixels")
  Assert.isTrue(day.image ~= night.image, versionId .. ": the night source palette changes output pixels")
  Assert.equal(indoor.buildMetadata.palette.selection, "fixed-day", versionId .. ": indoor scenes use the source fixed-day palette")
end

function T.effect_backgrounds_are_not_admitted_as_persistent_scenes(romFs, versionId)
  local compiler, _ = presentationBoundary(romFs, versionId)
  local bundle = compileGlobal(compiler, romFs, versionId)
  local manifest = bundle.manifest
  Assert.isTrue(type(manifest.scenes) == "table", versionId .. ": the manifest inventories its scene keys")
  local backgrounds = {}
  for _, entry in ipairs(manifest.scenes) do
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
  local scene, err = compiler.compileScene(romFs, { versionId = versionId }, "effect/flash/day")
  Assert.isNil(scene, versionId .. ": an effect background must not compile as a persistent scene")
  Assert.notNil(err, versionId .. ": the rejected effect background explains itself")
end

function T.arbitrary_effect_keys_are_not_published(romFs, versionId)
  local compiler = requireBoundary(
    "romdump.src.digest.battle.BattlePresentationCompiler",
    versionId .. ": no battle presentation compiler resolves effect selectors"
  )
  local unknown, unknownErr = compiler.compileEffect(romFs, { versionId = versionId }, "unmapped-effect-probe")
  Assert.isNil(unknown, versionId .. ": an arbitrary key cannot publish a made-up animation program")
  Assert.notNil(unknownErr, versionId .. ": an arbitrary key reports its unknown semantic route")
  Assert.equal(unknownErr.code, "BATTLE_EFFECT_UNKNOWN", versionId .. ": unknown semantic keys are rejected")
end

function T.move_effect_reads_its_source_selected_native_member(romFs, versionId)
  local compiler = requireBoundary(
    "romdump.src.digest.battle.BattlePresentationCompiler",
    versionId .. ": no battle presentation compiler resolves effect selectors"
  )
  local animationSources = require("romdump.src.config.BattleAnimationSources")
  local route = assert(animationSources.resolveSemanticRoute("TACKLE"), "TACKLE is a source move route")
  Assert.equal(route.kind, "move", versionId .. ": the semantic route selects the native move branch")
  Assert.equal(route.archiveSymbol, "NARC_a_0_1_0", versionId .. ": move animations use NARC ID 10 by symbol")
  Assert.equal(route.memberId, 33, versionId .. ": TACKLE selects its source move member")

  local archive = assert(romFs:openNarc(route.archiveSymbol), versionId .. ": the source move archive resolves")
  local stream, streamErr = archive:readMember(route.memberId)
  Assert.notNil(stream, versionId .. ": the source-selected TACKLE member is present: " .. tostring(streamErr))
  assert(stream ~= nil, "the source member is available to the compiler")
  Assert.isTrue(#stream > 0 and #stream % 4 == 0, versionId .. ": the selected member is a native command stream")

  local effect, err = compiler.compileEffect(romFs, { versionId = versionId }, "TACKLE")
  Assert.notNil(effect, versionId .. ": source-complete TACKLE effect compiles: " .. tostring(err))
  Assert.isNil(err, versionId .. ": successful effect compilation has no blocker")
  local repeated, repeatedErr = compiler.compileEffect(romFs, { versionId = versionId }, "TACKLE")
  Assert.notNil(repeated, versionId .. ": the same source stream compiles a second time: " .. tostring(repeatedErr))
  Assert.deepEqual(repeated.program, effect.program, versionId .. ": repeated source compilation is deterministic")
  Assert.deepEqual(repeated.dependencies, effect.dependencies, versionId .. ": resource closure order is deterministic")
  Assert.deepEqual(repeated.resources, effect.resources, versionId .. ": resource keys and content identities are deterministic")
  Assert.deepEqual(repeated.requiredContext, effect.requiredContext, versionId .. ": required context is deterministic")
  local animationSchema = require("libs.assets.src.battle.BattleAnimationSchema")
  Assert.isTrue(animationSchema.assertEffect({
    schema = effect.schema,
    key = effect.key,
    catalogIdentity = effect.catalogIdentity,
    program = effect.program,
    dependencies = effect.dependencies,
    resources = effect.resources,
    requiredContext = effect.requiredContext,
  }), versionId .. ": compiled effect matches the strict generated schema")
  local operations = {}
  for _, instruction in ipairs(effect.program.instructions) do
    operations[instruction.op] = true
  end
  for _, operation in ipairs({
    "create-managed-sprite-manager",
    "load-managed-sprite-resources",
    "create-pokemon-sprite",
    "invoke-battle-animation-callback",
    "create-battler-effect",
    "wait-interpreter-counter",
    "dispose-shared-sprite-manager",
    "delete-managed-sprite",
    "play-positioned-sound",
    "create-parameterized-battler-effect",
    "wait-for-battler-effects",
    "destroy-battler-effect",
    "reset-battle-presentation",
  }) do
    Assert.isTrue(operations[operation], versionId .. ": TACKLE preserves source operation " .. operation)
  end
  local positionedSound
  for _, instruction in ipairs(effect.program.instructions) do
    if instruction.op == "play-positioned-sound" then
      positionedSound = instruction.sound
      break
    end
  end
  Assert.equal(positionedSound, "audio/sequence/SEQ_SE_DP_050", versionId .. ": positioned sound resolves canonically")
  Assert.notNil(
    effect.resources["audio/sequence/SEQ_SE_DP_050"],
    versionId .. ": positioned sound is in the transitive resource closure"
  )
  Assert.notNil(
    effect.resources["battle/particle/tackle"],
    versionId .. ": TACKLE APS emitter data is in the transitive resource closure"
  )
  Assert.equal(effect.resources["battle/particle/tackle"].kind, "particle")
  local particlePayload = effect.resourcePayloads[effect.resources["battle/particle/tackle"].payload]
  Assert.equal(particlePayload.format, "APS12_1", versionId .. ": staged particle payload is decoded APS data")
  local particleAction
  for _, instruction in ipairs(effect.program.instructions) do
    if instruction.op == "create-parameterized-battler-effect" and instruction.resource ~= nil then
      particleAction = instruction
      break
    end
  end
  Assert.notNil(particleAction, versionId .. ": TACKLE resolves its selected APS emitter")
  local emitterDescriptor = effect.resources[particleAction.resource]
  Assert.notNil(emitterDescriptor, versionId .. ": the semantic emitter is part of the effect closure")
  Assert.equal(emitterDescriptor.kind, "particle-emitter")
  local emitterPayload = effect.resourcePayloads[emitterDescriptor.payload]
  Assert.isTrue(type(emitterPayload) == "table", versionId .. ": the selected emitter payload is staged")
  Assert.isTrue(type(emitterPayload.baseRecord) == "string", versionId .. ": the emitter is decoded semantic APS data")
  Assert.equal(
    table.concat(effect.dependencies, ","),
    table.concat((function()
      local keys = {}
      for key in pairs(effect.resources) do
        keys[#keys + 1] = key
      end
      table.sort(keys)
      return keys
    end)(), ","),
    versionId .. ": dependency receipt covers exactly the effect resource closure"
  )
  for key, descriptor in pairs(effect.resources) do
    Assert.equal(#descriptor.contentIdentity, 40, versionId .. ": resource has SHA-1 identity: " .. key)
    Assert.notNil(effect.resourcePayloads[descriptor.payload], versionId .. ": resource payload is staged: " .. key)
  end
  local audioBankCount, audioSampleCount = 0, 0
  for key in pairs(effect.resources) do
    if key:match("^audio/bank/") then
      audioBankCount = audioBankCount + 1
    elseif key:match("^audio/sample/") then
      audioSampleCount = audioSampleCount + 1
    end
  end
  Assert.isTrue(audioBankCount > 0, versionId .. ": positioned sound includes its compiled bank")
  Assert.isTrue(audioSampleCount > 0, versionId .. ": positioned sound includes its decoded sample closure")
  Assert.equal(effect.requiredContext.attackerPosition.type, "battler-position")
  Assert.equal(effect.requiredContext.targetPosition.type, "battler-position")

  local files, owned = {}, {}
  local artifact = {
    stageFs = function()
      return {
        write = function(_, path, bytes)
          files[path] = bytes
        end,
        writeLua = function(_, path, value)
          files[path] = value
        end,
      }
    end,
    addOwnedRoot = function(_, path)
      owned[path] = true
    end,
  }
  local marker = compiler.effectMarker(romFs:metadata().sha1, effect)
  compiler.stageEffect(artifact, effect, marker)
  local cacheFs = {
    read = function(_, path)
      return files[path]
    end,
    loadLua = function(_, path)
      return files[path]
    end,
    exists = function(_, path)
      return files[path] ~= nil
    end,
  }
  local presentationCache = require("libs.assets.src.battle.BattlePresentationCache")
  Assert.isTrue(
    presentationCache.isEffectReady(cacheFs, { key = effect.key, resources = effect.dependencies }),
    versionId .. ": publication carries the entire effect payload and dependency receipt"
  )
  local firstResource = effect.resources[effect.dependencies[1]]
  local removedPayload = files[firstResource.payload]
  files[firstResource.payload] = nil
  Assert.isFalse(
    presentationCache.isEffectReady(cacheFs, { key = effect.key, resources = effect.dependencies }),
    versionId .. ": readiness rejects a missing transitive payload"
  )
  files[firstResource.payload] = removedPayload
  Assert.isTrue(owned[firstResource.payload], versionId .. ": artifact cleanup owns each effect dependency")
end

-- FAKE_OUT's callback table entry is sourced from asm/overlay_07.s at
-- pret/pokeheartgold@9d8b7591f09b65804da2fb2dfd56f320633e0d36:
-- ov07_02236520[41] selects ov07_02230600.
function T.fake_out_display_window_palette_callback_lowers_to_a_named_task(romFs, versionId)
  Assert.equal(versionId, "heartgold", "the source callback trace is bounded to HeartGold")
  local compiler = requireBoundary(
    "romdump.src.digest.battle.BattlePresentationCompiler",
    "no battle presentation compiler resolves effect selectors"
  )
  local effect, err = compiler.compileEffect(romFs, { versionId = versionId }, "FAKE_OUT")
  Assert.notNil(effect, versionId .. ": source-backed FAKE_OUT effect compiles: " .. tostring(err))
  Assert.isNil(err, versionId .. ": successful effect compilation has no blocker")

  local callback
  for _, instruction in ipairs(effect.program.instructions) do
    if instruction.callback == "battle-display-window-palette-transition" then
      callback = instruction
      break
    end
  end
  Assert.notNil(callback, versionId .. ": FAKE_OUT preserves its asynchronous display and palette task")
  Assert.equal(callback.op, "invoke-battle-animation-callback", "the source behavior remains a scheduled task")
  Assert.equal(callback.taskKind, "battle-display-window-palette-transition")
  Assert.equal(callback.taskContext, "battle-display")
  Assert.deepEqual(callback.parameters, {}, "the native callback has no runtime parameters")
  Assert.isNil(callback.selector, "the native callback-table selector stays producer-only")
  Assert.isNil(callback.address, "the native callback address stays producer-only")
end

function T.sonic_boom_callback_selector_78_uses_the_callback_dispatch_namespace(romFs, versionId)
  local compiler = requireBoundary(
    "romdump.src.digest.battle.BattlePresentationCompiler",
    versionId .. ": no battle presentation compiler resolves effect selectors"
  )
  local effect, err = compiler.compileEffect(romFs, { versionId = versionId }, "SONIC_BOOM")
  Assert.notNil(effect, versionId .. ": SONIC_BOOM source callback selector 78 lowers: " .. tostring(err))
  local callback
  for _, instruction in ipairs(effect.program.instructions) do
    if instruction.callback == "managed-sprite-frame-loop" then
      callback = instruction
      break
    end
  end
  Assert.notNil(callback, versionId .. ": opcode45 callback selector 78 becomes the managed-sprite frame task")
  Assert.equal(callback.op, "invoke-battle-animation-callback")
  Assert.equal(callback.taskKind, "managed-sprite-draw-loop")
  Assert.equal(callback.parameters.frameTicks, 3, "source parameter zero selects the default three-frame duration")
  Assert.isNil(callback.selector, "runtime callback contains no native selector number")
  Assert.isNil(callback.resourceKeys, "the source callback plan does not invent a configured-sprite resource route")
  local sourceFrame
  for _, input in ipairs(effect.provenance.sourceInputs) do
    if input.role == "battle-animation-callback" and input.operands[1] == 78 then
      sourceFrame = input.operands
      break
    end
  end
  Assert.deepEqual(sourceFrame, { 78, 1, 0 }, "producer provenance retains the source callback frame")
end

function T.heal_block_callback_selector_74_compiles_its_semantic_palette_operation(romFs, versionId)
  local compiler = requireBoundary(
    "romdump.src.digest.battle.BattlePresentationCompiler",
    versionId .. ": no battle presentation compiler resolves effect selectors"
  )
  local effect, err = compiler.compileEffect(romFs, { versionId = versionId }, "HEAL_BLOCK")
  Assert.notNil(effect, versionId .. ": HEAL_BLOCK source callback selector 74 lowers: " .. tostring(err))
  local operation
  for _, instruction in ipairs(effect.program.instructions) do
    if instruction.op == "grayscale-main-background-fade-buffer" then
      operation = instruction
      break
    end
  end
  Assert.notNil(
    operation,
    versionId .. ": selector 74's nonzero source mode becomes the grayscale palette operation"
  )
  Assert.isNil(operation.selector, "the normalized direct operation contains no native selector number")
end

function T.body_slam_seq_none_is_omitted_from_effect_closure(romFs, versionId)
  local compiler = requireBoundary(
    "romdump.src.digest.battle.BattlePresentationCompiler",
    versionId .. ": no battle presentation compiler resolves effect selectors"
  )
  local sources = require("romdump.src.config.BattleAnimationSources")
  local route = assert(sources.resolveSemanticRoute("BODY_SLAM"), "BODY_SLAM has a semantic move route")
  Assert.equal(route.memberId, 34, "BODY_SLAM resolves to its audited native member")
  local effect, err = compiler.compileEffect(romFs, { versionId = versionId }, "BODY_SLAM")
  Assert.notNil(effect, versionId .. ": BODY_SLAM compiles: " .. tostring(err))
  assert(effect ~= nil, "the source-complete effect compiles")
  for _, instruction in ipairs(effect.program.instructions) do
    Assert.isFalse(instruction.sound == "audio/sequence/SEQ_NONE", "BODY_SLAM does not publish SEQ_NONE")
  end
  for resourceKey in pairs(effect.resources) do
    Assert.isFalse(resourceKey == "audio/sequence/SEQ_NONE", "BODY_SLAM stages no SEQ_NONE closure")
  end
end

function T.spider_web_seq_none_is_omitted_from_effect_closure(romFs, versionId)
  local compiler = requireBoundary(
    "romdump.src.digest.battle.BattlePresentationCompiler",
    versionId .. ": no battle presentation compiler resolves effect selectors"
  )
  local sources = require("romdump.src.config.BattleAnimationSources")
  local route = assert(sources.resolveSemanticRoute("SPIDER_WEB"), "SPIDER_WEB has a semantic move route")
  Assert.equal(route.memberId, 169, "SPIDER_WEB resolves to its audited native member")
  local effect, err = compiler.compileEffect(romFs, { versionId = versionId }, "SPIDER_WEB")
  Assert.notNil(effect, versionId .. ": SPIDER_WEB compiles: " .. tostring(err))
  assert(effect ~= nil, "the source-complete effect compiles")
  for _, instruction in ipairs(effect.program.instructions) do
    Assert.isFalse(instruction.sound == "audio/sequence/SEQ_NONE", "SPIDER_WEB does not publish SEQ_NONE")
  end
  for resourceKey in pairs(effect.resources) do
    Assert.isFalse(resourceKey == "audio/sequence/SEQ_NONE", "SPIDER_WEB stages no SEQ_NONE closure")
  end
end

function T.non_move_animation_root_compiles_as_a_semantic_effect(romFs, versionId)
  local compiler = require("romdump.src.digest.battle.BattlePresentationCompiler")
  local sources = require("romdump.src.config.BattleAnimationSources")
  local route = assert(sources.resolveSemanticRoute("BATTLE_ANIMATION_ASLEEP"))
  Assert.equal(route.kind, "battle-animation")
  Assert.equal(route.animationCategory, 1)
  local archive = assert(romFs:openNarc(route.archiveSymbol))
  local source = assert(archive:readMember(route.memberId))
  local selector = string.byte(source, 141)
    + string.byte(source, 142) * 0x100
    + string.byte(source, 143) * 0x10000
    + string.byte(source, 144) * 0x1000000
  local effect, err = compiler.compileEffect(romFs, { versionId = versionId }, route.key)
  Assert.notNil(
    effect,
    versionId .. ": source-selected non-move animation compiles (selector " .. selector .. "): " .. tostring(err)
  )
  Assert.equal(effect.key, route.key)
  Assert.equal(effect.provenance.memberId, route.memberId, "native member remains producer provenance")
end

function T.managed_sprite_template_references_staged_source_resources_and_omits_minus_one_roles(romFs, versionId)
  local Compiler = requireBoundary(
    "romdump.src.digest.battle.BattlePresentationCompiler",
    versionId .. ": no battle presentation compiler resolves effect selectors"
  )
  local animationCompilerPath = "romdump.src.digest.battle.BattleAnimationCompiler"
  local previousCompiler = package.loaded[animationCompilerPath]
  package.loaded[animationCompilerPath] = {
    compile = function(opts)
      local roles = {
        { "sprite-character", { 2, 19 } },
        { "sprite-palette", { 2, 23, 4 } },
        { "sprite-cell", { 2, 7 } },
        { "sprite-animation", { 2, 8 } },
      }
      for _, input in ipairs(roles) do
        assert(opts.resolveSourceInput(input[1], input[2]))
      end
      local missingOk, missingReason = pcall(opts.resolveSourceInput, "managed-sprite-template", {
        2,
        3,
        99,
        23,
        7,
        8,
        0xffffffff,
        0xffffffff,
      })
      assert(not missingOk and missingReason.code == "BATTLE_EFFECT_SOURCE_UNRESOLVED")
      local managed = opts.resolveSourceInput("managed-sprite-template", { 2, 3, 19, 23, 7, 8, 0xffffffff, 0xffffffff })
      return { instructions = { { op = "create-managed-sprite", resourceKeys = managed.resourceKeys } } }
    end,
  }
  local ok, effect, reason = pcall(Compiler.compileEffect, romFs, { versionId = versionId }, "TACKLE")
  package.loaded[animationCompilerPath] = previousCompiler
  Assert.isTrue(ok, versionId .. ": source resolver completes without programmer errors: " .. tostring(effect))
  Assert.isNil(effect, versionId .. ": incomplete transitive closure remains fail-closed")
  Assert.equal(
    reason.code,
    "BATTLE_EFFECT_CLOSURE_UNRESOLVED",
    versionId .. ": resolved resource identities reach closure gating"
  )
  local resolved = reason.context.resolvedSourceInputs
  local managed = assert(resolved[#resolved], versionId .. ": managed sprite source identities are retained")
  Assert.equal(managed.role, "managed-sprite-template")
  Assert.deepEqual(managed.resourceKeys, {
    character = resolved[1].resourceKeys.character,
    palette = resolved[2].resourceKeys.palette,
    cell = resolved[3].resourceKeys.cell,
    animation = resolved[4].resourceKeys.animation,
  }, "only previously decoded semantic keys enter the sprite template")
  for _, slot in ipairs({ "character", "palette", "cell", "animation" }) do
    local descriptor = assert(
      reason.context.resourceDescriptors[managed.resourceKeys[slot]],
      versionId .. ": " .. slot .. " descriptor has content identity"
    )
    Assert.isTrue(descriptor.contentIdentity:match("^[0-9a-f]+$") ~= nil, versionId .. ": identity is lowercase hex")
    Assert.equal(descriptor.contentIdentity:len(), 40, versionId .. ": identity is SHA-1")
    Assert.notNil(
      reason.context.resourcePayloads[descriptor.payload],
      versionId .. ": " .. slot .. " decoded candidate is available to stage"
    )
  end
  Assert.isNil(managed.resourceKeys.multiCell, "source -1 multi-cell role is omitted")
  Assert.isNil(managed.resourceKeys.multiAnimation, "source -1 multi-animation role is omitted")
end

function T.op47_particle_handler_resolves_its_emitter_and_continuation_slot(romFs, versionId)
  local compiler = requireBoundary(
    "romdump.src.digest.battle.BattlePresentationCompiler",
    versionId .. ": no battle presentation compiler resolves effect selectors"
  )
  local actualEffect, actualErr = compiler.compileEffect(romFs, { versionId = versionId }, "SUPERSONIC")
  Assert.notNil(actualEffect, versionId .. ": real SUPERSONIC reaches op47 after selector33: " .. tostring(actualErr))
  local actualAction
  for _, instruction in ipairs(actualEffect.program.instructions) do
    if instruction.op == "create-parameterized-battler-effect" and instruction.continuationSlot ~= nil then
      actualAction = instruction
      break
    end
  end
  Assert.notNil(actualAction, versionId .. ": real SUPERSONIC lowers its op47 source action")
  Assert.equal(actualEffect.resources[actualAction.resource].kind, "particle-emitter")
  local route = assert(
    require("romdump.src.config.BattleAnimationSources").resolveSemanticRoute("SUPERSONIC"),
    "SUPERSONIC remains the semantic source key for the op47 probe"
  )
  local function word(value)
    return string.char(
      value % 256,
      math.floor(value / 256) % 256,
      math.floor(value / 65536) % 256,
      math.floor(value / 16777216) % 256
    )
  end
  local stream = table.concat({ word(51), word(0), word(79), word(47), word(0), word(1), word(0), word(3), word(54) })
  local syntheticMoveArchive = {
    readMember = function(_, memberId)
      Assert.equal(memberId, route.memberId)
      return stream
    end,
  }
  local syntheticRomFs = {
    version = function()
      return versionId
    end,
    metadata = function()
      return romFs:metadata()
    end,
    openNarc = function(_, archiveSymbol)
      if archiveSymbol == route.archiveSymbol then
        return syntheticMoveArchive
      end
      return romFs:openNarc(archiveSymbol)
    end,
  }
  local effect, err = compiler.compileEffect(syntheticRomFs, { versionId = versionId }, "SUPERSONIC")
  Assert.notNil(effect, versionId .. ": the source-derived opcode51/op47 input path compiles: " .. tostring(err))
  Assert.isNil(err)
  local action
  for _, instruction in ipairs(effect.program.instructions) do
    if instruction.op == "create-parameterized-battler-effect" and instruction.continuationSlot ~= nil then
      action = instruction
      break
    end
  end
  Assert.notNil(action, versionId .. ": op47 retains its semantic continuation slot")
  Assert.equal(action.emitterPosition, "solo-player")
  Assert.isTrue(action.resource:find("battle/particle-emitter/", 1, true) == 1)
  Assert.equal(effect.resources[action.resource].kind, "particle-emitter")
  Assert.isNil(action.values, "native res_no and callback words do not enter the runtime instruction")
end

function T.effect_producer_decodes_and_normalizes_source_selected_background_resources(romFs, versionId)
  local compiler = requireBoundary(
    "romdump.src.digest.battle.BattlePresentationCompiler",
    versionId .. ": no battle presentation compiler resolves effect selectors"
  )
  local sources = require("romdump.src.config.BattleAnimationSources")
  local route = assert(sources.resolveSemanticRoute("TACKLE"), "TACKLE is a source move route")
  local function u32(value)
    return string.char(
      value % 256,
      math.floor(value / 256) % 256,
      math.floor(value / 65536) % 256,
      math.floor(value / 16777216) % 256
    )
  end
  local moveStream = u32(21) .. u32(0) .. u32(54)
  local syntheticMoveArchive = {
    readMember = function(_, memberId)
      Assert.equal(memberId, route.memberId, versionId .. ": producer asks for the resolved move member")
      return moveStream
    end,
  }
  local syntheticRomFs = {
    version = function()
      return versionId
    end,
    metadata = function()
      return romFs:metadata()
    end,
    openNarc = function(_, archiveSymbol)
      if archiveSymbol == route.archiveSymbol then
        return syntheticMoveArchive
      end
      return romFs:openNarc(archiveSymbol)
    end,
  }

  local effect, err = compiler.compileEffect(syntheticRomFs, { versionId = versionId }, "TACKLE")

  Assert.notNil(effect, versionId .. ": decoded source background and payload closure compile")
  Assert.isNil(err)
  local resolved = assert(effect.provenance.resolvedSourceInputs, "semantic resolver outputs remain producer-local")
  Assert.equal(#resolved, 1, versionId .. ": the single source background selection is normalized")
  Assert.equal(resolved[1].role, "battle-background", versionId .. ": normalized input names its semantic role")
  Assert.equal(
    resolved[1].runtimeSelection,
    "battle-background-screen-selection",
    versionId .. ": source-selected screen choice is a typed runtime enum"
  )
  Assert.equal(
    effect.provenance.sourceInputs[1].selections.character.memberId,
    59,
    versionId .. ": physical member selector remains only in producer provenance"
  )
  local resourceKeys = resolved[1].resourceKeys
  Assert.keySet(
    resourceKeys,
    "character,palette,screenAlternate,screenDefault",
    versionId .. ": producer returns semantic resource slots"
  )
  for _, key in pairs(resourceKeys) do
    Assert.isTrue(key:match("^battle/animation/battle%-background/") ~= nil, versionId .. ": key has no native ID")
    local descriptor = assert(effect.resources[key], "semantic key has a decoded resource descriptor")
    Assert.isTrue(
      descriptor.contentIdentity:match(
        "^%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x$"
      ) ~= nil,
      versionId .. ": resource descriptor is content addressed"
    )
    Assert.isTrue(
      descriptor.payload:match("^data/generated/battle/resources/") ~= nil,
      versionId .. ": semantic descriptor points at staged decoded content"
    )
  end
end

function T.effect_producer_decodes_source_confirmed_managed_sprite_resource_set(romFs, versionId)
  local compiler = requireBoundary(
    "romdump.src.digest.battle.BattlePresentationCompiler",
    versionId .. ": no battle presentation compiler resolves effect selectors"
  )
  local sources = require("romdump.src.config.BattleAnimationSources")
  local route = assert(sources.resolveSemanticRoute("TACKLE"), "TACKLE is a source move route")
  local function u32(value)
    return string.char(
      value % 256,
      math.floor(value / 256) % 256,
      math.floor(value / 65536) % 256,
      math.floor(value / 16777216) % 256
    )
  end
  local moveStream = u32(57) .. u32(0) .. u32(54)
  local syntheticMoveArchive = {
    readMember = function(_, memberId)
      Assert.equal(memberId, route.memberId, versionId .. ": producer asks for the resolved move member")
      return moveStream
    end,
  }
  local syntheticRomFs = {
    version = function()
      return versionId
    end,
    metadata = function()
      return romFs:metadata()
    end,
    openNarc = function(_, archiveSymbol)
      if archiveSymbol == route.archiveSymbol then
        return syntheticMoveArchive
      end
      return romFs:openNarc(archiveSymbol)
    end,
  }

  local effect, err = compiler.compileEffect(syntheticRomFs, { versionId = versionId }, "TACKLE")

  Assert.notNil(effect, versionId .. ": selected managed resources close the effect")
  Assert.isNil(err)
  local resolved = assert(effect.provenance.resolvedSourceInputs, "managed resources normalize before publication")
  Assert.equal(#resolved, 1, versionId .. ": one managed resource set is selected")
  Assert.equal(resolved[1].role, "managed-sprite-resource-set", versionId .. ": source role is semantic")
  Assert.equal(resolved[1].runtimeSelection, "battler-resource-selection", versionId .. ": battler selection is typed")
  Assert.keySet(
    resolved[1].resourceKeys,
    "animation,cell,character,palette",
    versionId .. ": every fixed source resource is represented"
  )
  local members = effect.provenance.sourceInputs[1].selections
  Assert.equal(members.character.memberId, 76, versionId .. ": pinned character member stays in provenance")
  Assert.equal(members.palette.memberId, 75, versionId .. ": pinned palette member stays in provenance")
  Assert.equal(members.cell.memberId, 77, versionId .. ": pinned cell member stays in provenance")
  Assert.equal(members.animation.memberId, 78, versionId .. ": pinned animation member stays in provenance")
end

function T.effect_producer_decodes_source_selected_sprite_character_member(romFs, versionId)
  local compiler = requireBoundary(
    "romdump.src.digest.battle.BattlePresentationCompiler",
    versionId .. ": no battle presentation compiler resolves effect selectors"
  )
  local sources = require("romdump.src.config.BattleAnimationSources")
  local route = assert(sources.resolveSemanticRoute("TACKLE"), "TACKLE is a source move route")
  local function u32(value)
    return string.char(
      value % 256,
      math.floor(value / 256) % 256,
      math.floor(value / 65536) % 256,
      math.floor(value / 16777216) % 256
    )
  end
  local moveStream = u32(74) .. u32(0) .. u32(0) .. u32(54)
  local syntheticMoveArchive = {
    readMember = function(_, memberId)
      Assert.equal(memberId, route.memberId, versionId .. ": producer asks for the resolved move member")
      return moveStream
    end,
  }
  local syntheticRomFs = {
    version = function()
      return versionId
    end,
    metadata = function()
      return romFs:metadata()
    end,
    openNarc = function(_, archiveSymbol)
      if archiveSymbol == route.archiveSymbol then
        return syntheticMoveArchive
      end
      return romFs:openNarc(archiveSymbol)
    end,
  }

  local effect, err = compiler.compileEffect(syntheticRomFs, { versionId = versionId }, "TACKLE")

  Assert.notNil(effect, versionId .. ": source-selected sprite data closes its resource dependency")
  Assert.isNil(err)
  local resolved = assert(effect.provenance.resolvedSourceInputs, "source-selected sprite data is normalized")
  Assert.equal(#resolved, 1, versionId .. ": one sprite resource is selected")
  Assert.equal(resolved[1].role, "sprite-character", versionId .. ": role names the source field")
  Assert.keySet(resolved[1].resourceKeys, "character", versionId .. ": runtime sees one semantic slot")
  Assert.equal(
    effect.provenance.sourceInputs[1].selections.character.archiveSymbol,
    "NARC_a_0_2_2",
    versionId .. ": source archive stays in producer provenance"
  )
  Assert.equal(
    effect.provenance.sourceInputs[1].selections.character.memberId,
    0,
    versionId .. ": selected NARC member stays in producer provenance"
  )
end

function T.muddy_water_uses_standard_sprite_data_without_unloaded_multicell_resources(romFs, versionId)
  local compiler = requireBoundary(
    "romdump.src.digest.battle.BattlePresentationCompiler",
    versionId .. ": no battle presentation compiler resolves managed sprites"
  )
  local effect, err = compiler.compileEffect(romFs, { versionId = versionId }, "MUDDY_WATER")
  Assert.notNil(effect, versionId .. ": absent optional MCEL/MANM uses the ordinary cell path: " .. tostring(err))
  Assert.isNil(err)
  local sprite
  for _, instruction in ipairs(effect.program.instructions) do
    if instruction.op == "create-managed-sprite" then
      sprite = instruction
      break
    end
  end
  Assert.notNil(sprite, versionId .. ": source creates its managed sprite")
  Assert.isNil(sprite.resourceKeys.multiCell, versionId .. ": no unloaded multiCell is staged")
  Assert.isNil(sprite.resourceKeys.multiAnimation, versionId .. ": no unloaded multiAnimation is staged")
end

function T.configured_sprite_omits_unused_multicell_roles_when_manager_disables_them(romFs, versionId)
  local compiler = requireBoundary(
    "romdump.src.digest.battle.BattlePresentationCompiler",
    versionId .. ": no battle presentation compiler resolves configured sprites"
  )
  local sources = require("romdump.src.config.BattleAnimationSources")
  local route = assert(sources.resolveSemanticRoute("TACKLE"), "TACKLE is a source move route")
  local function u32(value)
    return string.char(
      value % 256,
      math.floor(value / 256) % 256,
      math.floor(value / 65536) % 256,
      math.floor(value / 16777216) % 256
    )
  end
  local function configuredStream(multiCellCapacity, multiAnimationCapacity, includeManagerSetup, disposeBeforeCreate)
    local managerSetup = includeManagerSetup == false and {} or {
      u32(73), u32(0), u32(5), u32(5), u32(5), u32(5), u32(5),
      u32(multiCellCapacity), u32(multiAnimationCapacity),
    }
    local disposal = disposeBeforeCreate and { u32(80), u32(0) } or {}
    return table.concat({
      table.concat(managerSetup),
      u32(74), u32(0), u32(0),
      u32(75), u32(0), u32(0), u32(0),
      u32(76), u32(0), u32(0),
      u32(77), u32(0), u32(0),
      table.concat(disposal),
      u32(78), u32(0), u32(0), u32(0), u32(0), u32(0), u32(0), u32(0), u32(0), u32(0),
      u32(54),
    })
  end
  local moveStream = configuredStream(0, 0)
  local syntheticMoveArchive = {
    readMember = function(_, memberId)
      Assert.equal(memberId, route.memberId, versionId .. ": producer asks for the source-selected move member")
      return moveStream
    end,
  }
  local syntheticRomFs = {
    version = function()
      return versionId
    end,
    metadata = function()
      return romFs:metadata()
    end,
    openNarc = function(_, archiveSymbol)
      if archiveSymbol == route.archiveSymbol then
        return syntheticMoveArchive
      end
      return romFs:openNarc(archiveSymbol)
    end,
  }

  local effect, err = compiler.compileEffect(syntheticRomFs, { versionId = versionId }, "TACKLE")

  Assert.isNil(err, versionId .. ": unused MCEL/MANM template words do not block source closure: " .. tostring(err))
  Assert.notNil(effect, versionId .. ": configured sprite compiles with its four active resource roles")
  local capacityInput
  for _, input in ipairs(effect.provenance.sourceInputs) do
    if input.role == "managed-sprite-manager-capacities" then
      capacityInput = input
      break
    end
  end
  Assert.deepEqual(capacityInput.operands, { 0, 5, 5, 5, 5, 5, 0, 0 }, "opcode73 capacities remain producer-side source facts")
  local configuredSprite
  for _, instruction in ipairs(effect.program.instructions) do
    if instruction.op == "create-configured-sprite" then
      configuredSprite = instruction
      break
    end
  end
  Assert.notNil(configuredSprite, versionId .. ": source callback creates the configured sprite")
  local function resolvedResource(role)
    for _, input in ipairs(effect.provenance.resolvedSourceInputs) do
      if input.role == role then
        return input.resourceKeys
      end
    end
    return nil
  end
  Assert.equal(configuredSprite.resourceKeys.character, resolvedResource("sprite-character").character)
  Assert.equal(configuredSprite.resourceKeys.palette, resolvedResource("sprite-palette").palette)
  Assert.equal(configuredSprite.resourceKeys.cell, resolvedResource("sprite-cell").cell)
  Assert.equal(configuredSprite.resourceKeys.animation, resolvedResource("sprite-animation").animation)
  Assert.isNil(configuredSprite.resourceKeys.multiCell, "disabled MCEL manager has no semantic resource key")
  Assert.isNil(configuredSprite.resourceKeys.multiAnimation, "disabled MANM manager has no semantic resource key")

  moveStream = configuredStream(1, 1)
  local multiCapacityEffect, multiCapacityErr = compiler.compileEffect(syntheticRomFs, { versionId = versionId }, "TACKLE")
  Assert.notNil(multiCapacityEffect, "nonzero MCEL/MANM capacity does not imply a loaded resource: " .. tostring(multiCapacityErr))
  Assert.isNil(multiCapacityErr)
  local activeMultiSprite
  for _, instruction in ipairs(multiCapacityEffect.program.instructions) do
    if instruction.op == "create-configured-sprite" then
      activeMultiSprite = instruction
      break
    end
  end
  Assert.notNil(activeMultiSprite, "the configured sprite still lowers")
  Assert.isNil(activeMultiSprite.resourceKeys.multiCell, "an unloaded MCEL remains absent")
  Assert.isNil(activeMultiSprite.resourceKeys.multiAnimation, "an unloaded MANM remains absent")

  moveStream = configuredStream(0, 0, false)
  local missingManagerEffect, missingManagerErr = compiler.compileEffect(syntheticRomFs, { versionId = versionId }, "TACKLE")
  Assert.isNil(missingManagerEffect, "configured sprites require a prior manager capacity frame")
  Assert.isTrue(
    tostring(missingManagerErr):find("configured sprite manager has no active capacity record", 1, true) ~= nil,
    "missing capacity state is distinct from zero-capacity MCEL/MANM"
  )

  moveStream = configuredStream(0, 0, true, true)
  local disposedManagerEffect, disposedManagerErr = compiler.compileEffect(syntheticRomFs, { versionId = versionId }, "TACKLE")
  Assert.isNil(disposedManagerEffect, "disposed manager capacity state cannot be reused")
  Assert.isTrue(
    tostring(disposedManagerErr):find("configured sprite manager has no active capacity record", 1, true) ~= nil,
    "opcode80 disposal clears manager capability and resource identity state"
  )

  moveStream = configuredStream(0xffffffff, 0)
  local invalidManagerEffect, invalidManagerErr = compiler.compileEffect(syntheticRomFs, { versionId = versionId }, "TACKLE")
  Assert.isNil(invalidManagerEffect, "negative signed capacity words are rejected")
  Assert.isTrue(
    tostring(invalidManagerErr):find("sprite manager capacity is invalid", 1, true) ~= nil,
    "unsigned source words above signed capacity range fail closed"
  )
end

function T.semantic_callback_without_archive_resources_is_preserved_in_effect_compilation(romFs, versionId)
  local compiler = requireBoundary(
    "romdump.src.digest.battle.BattlePresentationCompiler",
    versionId .. ": no battle presentation compiler resolves animation callbacks"
  )
  local effect, err = compiler.compileEffect(romFs, { versionId = versionId }, "BATTLE_ANIMATION_ASLEEP")

  Assert.isNil(err, versionId .. ": a source-resolved semantic callback does not require a separate archive selection")
  Assert.notNil(effect, versionId .. ": callback-only semantic source plans compile into effects")
  local foundTypedCallback = false
  for _, instruction in ipairs(effect.program.instructions) do
    if instruction.callback ~= nil then
      foundTypedCallback = true
      Assert.isTrue(type(instruction.taskKind) == "string", "callback-only plan retains its semantic task kind")
      Assert.isTrue(type(instruction.taskContext) == "string", "callback-only plan retains its typed task context")
      Assert.isTrue(type(instruction.parameters) == "table", "callback-only plan retains normalized parameters")
    end
  end
  Assert.isTrue(foundTypedCallback, "the compiled program retains its source callback task")
end

function T.animation_source_tasks_declare_their_required_context(romFs, versionId)
  local compiler = requireBoundary(
    "romdump.src.digest.battle.BattlePresentationCompiler",
    versionId .. ": no battle presentation compiler resolves animation contexts"
  )
  local contexts = {
    BATTLE_ANIMATION_DAMAGE_MAGMA_STORM = { "battlerTopology", "spriteContextTable" },
    STOMP = { "battlerTopology" },
  }
  for effectKey, required in pairs(contexts) do
    local ok, effect, err = pcall(compiler.compileEffect, romFs, { versionId = versionId }, effectKey)
    Assert.isTrue(
      ok,
      versionId .. ": " .. effectKey .. " source context closes: " .. tostring(err and err.context and err.context.callback)
    )
    Assert.notNil(effect, versionId .. ": " .. effectKey .. " compiles")
    for _, contextKey in ipairs(required) do
      local expectedType = contextKey == "battlerTopology"
          and "battle-animation-battler-topology"
        or "battle-animation-sprite-context-table"
      Assert.equal(effect.requiredContext[contextKey].type, expectedType, effectKey .. " declares " .. contextKey)
    end
  end
end

function T.effect_producer_stages_fixed_and_context_selected_battler_particle_emitters(romFs, versionId)
  local compiler = requireBoundary(
    "romdump.src.digest.battle.BattlePresentationCompiler",
    versionId .. ": no battle presentation compiler resolves effect selectors"
  )
  local sources = require("romdump.src.config.BattleAnimationSources")
  local route = assert(sources.resolveSemanticRoute("TACKLE"), "TACKLE is a source move route")
  local function u32(value)
    return string.char(
      value % 256,
      math.floor(value / 256) % 256,
      math.floor(value / 65536) % 256,
      math.floor(value / 16777216) % 256
    )
  end
  local syntheticMoveArchive = {
    readMember = function(_, memberId)
      Assert.equal(memberId, route.memberId)
      return u32(46) .. u32(0) .. u32(1) .. u32(0)
    end,
  }
  local particleArchive = assert(romFs:openNarc("NARC_a_0_2_9"))
  local particleBytes = assert(particleArchive:readMember(64))
  local syntheticParticleArchive = {
    readMember = function(_, memberId)
      if memberId == 13 then
        return particleBytes
      end
      return particleArchive:readMember(memberId)
    end,
  }
  local syntheticRomFs = {
    version = function()
      return versionId
    end,
    metadata = function()
      return romFs:metadata()
    end,
    openNarc = function(_, archiveSymbol)
      if archiveSymbol == route.archiveSymbol then
        return syntheticMoveArchive
      end
      if archiveSymbol == "NARC_a_0_2_9" then
        return syntheticParticleArchive
      end
      return romFs:openNarc(archiveSymbol)
    end,
  }
  local compilerPath = "romdump.src.digest.battle.BattleAnimationCompiler"
  local previousCompiler = package.loaded[compilerPath]
  package.loaded[compilerPath] = {
    compile = function(options)
      local particle = options.resolveSourceInput("battler-particle-resource", { 0, 64 })
      Assert.equal(particle.resourceKeys.particle, "battle/particle/tackle")
      local sourceSelected = options.resolveSourceInput("battler-particle-resource", { 1, 13 })
      Assert.isTrue(sourceSelected.resourceKeys.particle:match("^battle/particle/content/[0-9a-f]+$") ~= nil)
      local action = options.resolveSourceInput("battler-particle-action", { 0, 0, 0 })
      Assert.equal(action.taskKind, "battler-effect-continuation")
      Assert.isTrue(type(action.actionProfile) == "string")
      Assert.isTrue(action.resource:find("battle/particle-emitter/", 1, true) == 1)
      local contextual = options.resolveSourceInput("battler-particle-action", { 0, 0, 0, 0, 0, 0, 0, 0 })
      Assert.equal(contextual.runtimeSelection, "battler-particle-position-pair")
      Assert.isTrue(type(contextual.resourceCases) == "table")
      return {
        entry = "main",
        instructions = {
          {
            op = "create-battler-effect",
            emitterPosition = "solo-player",
            resource = particle.resourceKeys.particle,
            taskKind = "battler-effect-continuation",
          },
          {
            op = "create-battler-effect",
            emitterPosition = "solo-enemy",
            resource = sourceSelected.resourceKeys.particle,
            taskKind = "battler-effect-continuation",
          },
          {
            op = "create-parameterized-battler-effect",
            emitterPosition = "solo-player",
            resource = action.resource,
            taskKind = action.taskKind,
            actionProfile = action.actionProfile,
          },
          {
            op = "create-parameterized-battler-effect",
            emitterPosition = "solo-player",
            resourceCases = contextual.resourceCases,
            runtimeSelection = contextual.runtimeSelection,
            taskKind = contextual.taskKind,
            actionProfile = contextual.actionProfile,
          },
        },
        subprograms = {},
        taskKinds = { "battler-effect-continuation" },
      }
    end,
  }

  local ok, effect, failure = pcall(compiler.compileEffect, syntheticRomFs, { versionId = versionId }, "TACKLE")
  package.loaded[compilerPath] = previousCompiler

  Assert.isTrue(ok, versionId .. ": a particle handler resolves its earlier APS resource selection: " .. tostring(effect))
  Assert.notNil(effect, versionId .. ": the particle source and selected emitter form a closed effect: " .. tostring(failure))
  Assert.isNil(failure)
  Assert.equal(#effect.provenance.resolvedSourceInputs, 4)
  local particle = effect.provenance.resolvedSourceInputs[1]
  Assert.equal(particle.role, "battler-particle-resource")
  Assert.equal(particle.resourceKeys.particle, "battle/particle/tackle")
  local genericParticle = effect.provenance.resolvedSourceInputs[2]
  Assert.equal(genericParticle.role, "battler-particle-resource")
  Assert.isTrue(genericParticle.resourceKeys.particle:find("battle/particle/content/", 1, true) == 1)
  Assert.notNil(effect.resources[genericParticle.resourceKeys.particle])
  Assert.equal(effect.resources[genericParticle.resourceKeys.particle].kind, "particle")
  local genericPayload = effect.resourcePayloads[effect.resources[genericParticle.resourceKeys.particle].payload]
  Assert.equal(genericPayload.format, "APS12_1")
  local genericSelection
  for _, input in ipairs(effect.provenance.sourceInputs) do
    if input.role == "battler-particle-resource" and input.operands[2] == 13 then
      genericSelection = input.selections.particle
      break
    end
  end
  Assert.equal(genericSelection.memberId, 13, "native selection remains in producer provenance")
  local action = effect.provenance.resolvedSourceInputs[3]
  Assert.equal(action.role, "battler-particle-action")
  Assert.isTrue(action.resource:find("battle/particle-emitter/", 1, true) == 1)
  Assert.isTrue(type(action.actionProfile) == "string")
  local contextual = effect.provenance.resolvedSourceInputs[4]
  Assert.equal(contextual.runtimeSelection, "battler-particle-position-pair")
  local caseCount = 0
  local assertionCount = 0
  for _, resourceKey in pairs(contextual.resourceCases) do
    caseCount = caseCount + 1
    if resourceKey == "source-assert" then
      assertionCount = assertionCount + 1
    else
      Assert.notNil(effect.resources[resourceKey], "each valid context case stages its semantic APS emitter")
    end
  end
  Assert.equal(caseCount, 36, "all source-defined semantic battler position pairs are represented")
  Assert.isTrue(assertionCount > 0, "source assertion branches stay explicit in the closed choice map")
  local fixedSource, genericSource
  for _, input in ipairs(effect.provenance.sourceInputs) do
    if input.role == "battler-particle-resource" then
      if input.operands[2] == 64 then
        fixedSource = input
      elseif input.operands[2] == 13 then
        genericSource = input
      end
    end
  end
  Assert.deepEqual(fixedSource.operands, { 0, 64 })
  Assert.deepEqual(genericSource.operands, { 1, 13 })
  Assert.notNil(effect.resources[action.resource], "the selected APS emitter has a staged descriptor")
  Assert.equal(effect.resources[action.resource].kind, "particle-emitter")
  Assert.equal(effect.provenance.sourceInputs[1].selections.particle.archiveSymbol, "NARC_a_0_2_9")
  Assert.equal(effect.provenance.sourceInputs[1].selections.particle.memberId, 64)
end

return RomSuite.fromFacts(T)
