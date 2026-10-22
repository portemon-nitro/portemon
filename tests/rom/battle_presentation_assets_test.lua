-- Targeted dump-backed smokes for battle presentation: narrow reads of
-- the handful of source members behind the menu/HUD and scene contracts,
-- decoded through the production G2D and scene paths. The whole-catalog
-- compileGlobal (every species picture, audio bank, message bank,
-- transition, and effect) costs minutes per version, so these tests
-- deliberately avoid it; the full compile stays exercised by production
-- provisioning. Assertions are semantic keys, canvas geometry, and
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
  local Lz10 = requireBoundary(
    "romdump.src.digest.Lz10",
    versionId .. ": no LZ unwrapper opens compressed source members"
  )
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
  local Lz10 = requireBoundary(
    "romdump.src.digest.Lz10",
    versionId .. ": no LZ unwrapper opens compressed source members"
  )
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
  local generalChars =
    readSource(lower, Sources.baseCharMember(generalId), "general base characters", versionId, Lz10)
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

-- Admission is a static contract, not a decode result: the global bundle
-- publishes BattlePresentationCache.sceneInventory() verbatim, so this
-- test checks that inventory plus the production rejection path without
-- paying for a full dump compile (compileGlobal decodes the whole
-- presentation catalog and is covered by the dump-backed tests above).
function T.effect_backgrounds_are_not_admitted_as_persistent_scenes(romFs, versionId)
  local compiler, cache = presentationBoundary(romFs, versionId)
  Assert.isTrue(
    type(cache.sceneInventory) == "function",
    versionId .. ": the cache exposes its scene inventory"
  )
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

return RomSuite.fromFacts(T)
