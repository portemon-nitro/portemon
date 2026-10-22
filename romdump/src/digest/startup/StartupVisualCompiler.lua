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

local function selectedSpriteIds(pairIndex)
  local choice = StartupAssetCache.walkerChoice(pairIndex)
  local gender = choice.heroId == "ethan" and 0 or 1
  local heroSprite = PlayerAvatar.statesForGender(gender).walking
  local followerSprite = MonSources.followerSpriteId(choice.followerSpeciesId, 0, false)
  assert(followerSprite ~= nil, "walking pair follower has no source sprite")
  local spriteIds = { heroSprite, followerSprite }
  if heroSprite == followerSprite then
    spriteIds = { heroSprite }
  end
  assert(#spriteIds == 2, "one walking pair compiles exactly one hero and one follower sprite")
  return spriteIds, heroSprite, followerSprite, choice
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
---@param pairIndex integer
---@return table<string, unknown>|nil
---@return Errors.Error|string|nil
function StartupVisualCompiler.compile(romFs, pairIndex)
  assert(romFs and type(romFs.metadata) == "function", "startup visuals require a ROM filesystem")
  assert(
    type(pairIndex) == "number" and pairIndex % 1 == 0 and pairIndex >= 1 and pairIndex <= 32,
    "walking pair index must be an integer 1..32"
  )
  local spriteIds, heroSprite, followerSprite, choice = selectedSpriteIds(pairIndex)
  local compiled, err = FieldActorCompiler.compileSprites(romFs, spriteIds)
  if compiled == nil then
    return nil, err
  end
  local versionId = assert(romFs:version(), "startup visuals require an edition")
  local root = "assets/generated/startup/loader/pairs/" .. tostring(pairIndex)
  local heroPath = root .. "/hero.png"
  local followerPath = root .. "/follower.png"
  local heroVisual = startupVisual(assert(compiled.visuals[heroSprite]), heroSprite)
  local followerVisual = startupVisual(assert(compiled.visuals[followerSprite]), followerSprite)
  local atlases = {
    [heroPath] = assert(compiled.atlases[heroSprite]),
    [followerPath] = assert(compiled.atlases[followerSprite]),
  }
  local dependencies = {
    versionId = versionId,
    romSha1 = assert(romFs:metadata().sha1),
    actorSources = compiled.dependencies,
    spriteIds = spriteIds,
    pairIndex = pairIndex,
    followerSpeciesId = choice.followerSpeciesId,
    heroId = choice.heroId,
  }
  return {
    manifest = {
      schema = "g4-startup-walker-v1",
      versionId = versionId,
      pairIndex = pairIndex,
      hero = { atlasPath = heroPath, visual = heroVisual },
      follower = {
        speciesId = choice.followerSpeciesId,
        atlasPath = followerPath,
        visual = followerVisual,
      },
    },
    atlases = atlases,
    dependencies = dependencies,
    sourceHash = Hashing.hashLua(dependencies),
  }
end

return StartupVisualCompiler
