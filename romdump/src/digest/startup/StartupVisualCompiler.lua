-- Bounded ROM-derived walking visuals sourced from HGSS field actor tables.

local Errors = require("libs.errors.src.Errors")
local FieldActorCompiler = require("romdump.src.digest.actor.FieldActorCompiler")
local Hashing = require("romdump.src.digest.Hashing")
local MonSources = require("romdump.src.config.MonSources")
local PlayerAvatar = require("romdump.src.catalog.hgss.player_avatar")

local StartupVisualCompiler = {}

local StartupAssetCache = require("libs.assets.src.StartupAssetCache")

local function assertEastWalk(visual, spriteId)
  local render = visual and visual.render
  local east = visual and visual.directions and visual.directions.east
  local walk = east and east.walk
  if render == nil or render.kind ~= "atlas" or type(walk) ~= "table" or type(walk.frames) ~= "table" then
    Errors.raise("STARTUP_VISUAL_NOT_ANIMATED", "startup sprite has no east-facing walk clip", {
      spriteId = spriteId,
    })
  end
  local frames = {}
  for _, segment in ipairs(walk.frames) do
    frames[segment.frameIndex] = true
  end
  local distinct = 0
  for _ in pairs(frames) do
    distinct = distinct + 1
  end
  if distinct < 2 then
    Errors.raise("STARTUP_VISUAL_NOT_ANIMATED", "startup sprite walk clip has fewer than two frames", {
      spriteId = spriteId,
    })
  end
end

local function selectedSpriteIds()
  local heroSprites = {
    ethan = PlayerAvatar.statesForGender(0).walking,
    lyra = PlayerAvatar.statesForGender(1).walking,
  }
  local followerSpecies = {}
  for pairIndex = 1, 32 do
    local choice = StartupAssetCache.walkerChoice(pairIndex)
    followerSpecies[choice.followerSpeciesId] = true
  end
  local orderedSpecies = {}
  for speciesId in pairs(followerSpecies) do
    orderedSpecies[#orderedSpecies + 1] = speciesId
  end
  table.sort(orderedSpecies)
  local followerSprites = {}
  for _, speciesId in ipairs(orderedSpecies) do
    local spriteId = MonSources.followerSpriteId(speciesId, 0, false)
    assert(spriteId ~= nil, "walking follower has no source sprite")
    followerSprites[speciesId] = spriteId
  end
  local seen = {}
  local spriteIds = {}
  local function include(spriteId)
    if not seen[spriteId] then
      seen[spriteId] = true
      spriteIds[#spriteIds + 1] = spriteId
    end
  end
  include(heroSprites.ethan)
  include(heroSprites.lyra)
  for _, speciesId in ipairs(orderedSpecies) do
    include(followerSprites[speciesId])
  end
  return spriteIds, heroSprites, followerSprites, orderedSpecies
end

local function startupVisual(sourceVisual, spriteId)
  assertEastWalk(sourceVisual, spriteId)
  return {
    render = {
      kind = "atlas",
      frameWidth = sourceVisual.render.frameWidth,
      frameHeight = sourceVisual.render.frameHeight,
      frameCount = sourceVisual.render.frameCount,
    },
    pivot = { x = 0.5, y = 1 },
    directions = { east = { walk = sourceVisual.directions.east.walk } },
  }
end

---@param romFs table<string, unknown>
---@return table<string, unknown>|nil
---@return Errors.Error|string|nil
function StartupVisualCompiler.compile(romFs)
  assert(romFs and type(romFs.metadata) == "function", "startup visuals require a ROM filesystem")
  local spriteIds, heroSprites, followerSprites, orderedSpecies = selectedSpriteIds()
  local compiled, err = FieldActorCompiler.compileSprites(romFs, spriteIds)
  if compiled == nil then
    return nil, err
  end
  local versionId = assert(romFs:version(), "startup visuals require an edition")
  local heroes = {}
  for _, heroId in ipairs({ "ethan", "lyra" }) do
    local spriteId = heroSprites[heroId]
    local path = "assets/generated/startup/loader/subjects/heroes/" .. heroId .. ".png"
    heroes[heroId] = {
      atlasPath = path,
      visual = startupVisual(assert(compiled.visuals[spriteId]), spriteId),
    }
  end
  local followers = {}
  for _, speciesId in ipairs(orderedSpecies) do
    local spriteId = followerSprites[speciesId]
    local path = "assets/generated/startup/loader/subjects/followers/" .. tostring(speciesId) .. ".png"
    followers[tostring(speciesId)] = {
      atlasPath = path,
      visual = startupVisual(assert(compiled.visuals[spriteId]), spriteId),
    }
  end
  local atlases = {}
  for heroId, entry in pairs(heroes) do
    atlases[entry.atlasPath] = assert(compiled.atlases[heroSprites[heroId]])
  end
  for key, entry in pairs(followers) do
    atlases[entry.atlasPath] = assert(compiled.atlases[followerSprites[tonumber(key)]])
  end
  local dependencies = {
    versionId = versionId,
    romSha1 = assert(romFs:metadata().sha1),
    actorSources = compiled.dependencies,
    spriteIds = spriteIds,
  }
  return {
    manifest = {
      schema = "g4-startup-walker-v2",
      versionId = versionId,
      heroes = heroes,
      followers = followers,
    },
    atlases = atlases,
    dependencies = dependencies,
    sourceHash = Hashing.hashLua(dependencies),
  }
end

return StartupVisualCompiler
