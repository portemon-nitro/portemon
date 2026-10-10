-- Dump-backed composition for battle presentation: the real private dump
-- compiles the shared menu/HUD definitions and the requested persistent
-- scenes through the production compiler, every referenced output stages
-- through the existing publication path, and the cache boundary loads and
-- validates the result. Assertions are semantic keys, canvas geometry, and
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

---@param compiler table
---@param romFs table
---@param versionId string
---@return table staged global bundle
local function compileGlobal(compiler, romFs, versionId)
  Assert.isTrue(type(compiler.compileGlobal) == "function", versionId .. ": the compiler exposes a global entry point")
  local bundle = assert(
    compiler.compileGlobal(romFs, { versionId = versionId }),
    versionId .. ": the dump must compile its shared battle menu and HUD definitions"
  )
  return bundle
end

local REQUIRED_SECTIONS = {
  "command",
  "moves",
  "playerHud",
  "enemyHud",
  "arrow",
  "partyGauges",
  "textRoles",
  "audioRoles",
}

function T.shared_menu_and_hud_definitions_compile_from_the_dump(romFs, versionId)
  local compiler, _ = presentationBoundary(romFs, versionId)
  local bundle = compileGlobal(compiler, romFs, versionId)
  Assert.isTrue(type(bundle.manifest) == "table", versionId .. ": the global compile yields a manifest")
  for _, section in ipairs(REQUIRED_SECTIONS) do
    Assert.notNil(bundle.manifest[section], versionId .. ": the manifest carries its " .. section .. " section")
  end
  Assert.isTrue(
    type(bundle.manifest.command) == "table" and bundle.manifest.command.image ~= nil,
    versionId .. ": the command menu resolves a staged image, not a bare recipe"
  )
  Assert.isTrue(
    type(bundle.manifest.playerHud) == "table" and type(bundle.manifest.enemyHud) == "table",
    versionId .. ": both single-battle health boxes resolve"
  )
  local flat = bundle.manifest
  local function scan(value, path)
    if type(value) ~= "table" then
      return
    end
    for key, nested in pairs(value) do
      Assert.isFalse(
        key == "memberId" or key == "fileId" or key == "narcId",
        versionId .. ": the runtime manifest leaks source detail '" .. tostring(key) .. "' at " .. path
      )
      scan(nested, path .. "." .. tostring(key))
    end
  end
  scan(flat, "manifest")
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

function T.persistent_scenes_compile_per_background_terrain_and_time(romFs, versionId)
  local compiler, _ = presentationBoundary(romFs, versionId)
  local bundle = compileGlobal(compiler, romFs, versionId)
  local manifest = bundle.manifest
  local day = compileScene(compiler, romFs, versionId, manifest, "general", "grass", "day")
  Assert.equal(day.canvasWidth, 512, versionId .. ": the persistent scene keeps its 512-wide source canvas")
  Assert.equal(day.canvasHeight, 256, versionId .. ": the persistent scene keeps its 256-high source canvas")
  Assert.notNil(day.image, versionId .. ": the scene record references its composed image")
  Assert.notNil(day.viewport, versionId .. ": the scene record maps its visible region")
  Assert.isTrue(
    day.viewport.x + day.viewport.width <= day.canvasWidth and day.viewport.y + day.viewport.height <= day.canvasHeight,
    versionId .. ": the visible region stays inside the source canvas"
  )
  local evening = compileScene(compiler, romFs, versionId, manifest, "general", "grass", "evening")
  local night = compileScene(compiler, romFs, versionId, manifest, "general", "grass", "night")
  Assert.isTrue(evening.image ~= day.image, versionId .. ": evening palette selection changes the composed scene")
  Assert.isTrue(night.image ~= day.image, versionId .. ": night palette selection changes the composed scene")
  local cave = compileScene(compiler, romFs, versionId, manifest, "cave_1", "cave", "day")
  Assert.isTrue(cave.image ~= day.image, versionId .. ": a second background family follows its own recipe")
  local dayAgain = compileScene(compiler, romFs, versionId, manifest, "general", "grass", "day")
  Assert.equal(dayAgain.image, day.image, versionId .. ": scene compilation is deterministic")
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

return RomSuite.fromFacts(T)
