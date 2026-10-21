-- Bounded ROM-derived walking visuals sourced from HGSS field actor tables.

local Errors = require("libs.errors.src.Errors")
local FieldActorCompiler = require("romdump.src.digest.actor.FieldActorCompiler")
local Hashing = require("romdump.src.digest.Hashing")
local MonSources = require("romdump.src.config.MonSources")
local PlayerAvatar = require("romdump.src.catalog.hgss.player_avatar")

local StartupVisualCompiler = {}

local FOLLOWER_SPECIES = { "CHIKORITA", "CYNDAQUIL", "TOTODILE", "MARILL" }
local AVATARS = { ethan = 0, lyra = 1 }

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

local function addSprite(ordered, seen, spriteId)
  if not seen[spriteId] then
    seen[spriteId] = true
    ordered[#ordered + 1] = spriteId
  end
end

local function selectedSpriteIds()
  local spriteIds, seen = {}, {}
  for _, gender in pairs(AVATARS) do
    addSprite(spriteIds, seen, PlayerAvatar.statesForGender(gender).walking)
  end
  local followers = {}
  for _, speciesKey in ipairs(FOLLOWER_SPECIES) do
    local speciesId = assert(MonSources.speciesId(speciesKey), "startup follower species is unknown")
    local spriteId = MonSources.followerSpriteId(speciesId, 0, false)
    local paramIndex = MonSources.followerParamIndex(speciesId, 0, false)
    assert(spriteId ~= nil and paramIndex ~= nil, speciesKey .. " has no follower visual")
    addSprite(spriteIds, seen, spriteId)
    followers[#followers + 1] = {
      speciesId = speciesId,
      spriteId = spriteId,
      visualId = MonSources.followerVisualId(paramIndex),
    }
  end
  table.sort(spriteIds)
  assert(#spriteIds >= 6 and #spriteIds <= 8, "startup sprite closure must remain bounded to 6-8 sources")
  return spriteIds, followers
end

local function startupVisual(sourceVisual, spriteId, identity)
  assertEastWalk(sourceVisual, spriteId)
  return {
    identity = identity,
    render = {
      kind = "atlas",
      frameWidth = sourceVisual.render.frameWidth,
      frameHeight = sourceVisual.render.frameHeight,
      frameCount = sourceVisual.render.frameCount,
    },
    directions = { east = { walk = sourceVisual.directions.east.walk } },
  }
end

local function authoredBackdrop()
  local width, height = 256, 192
  local pixels = {}
  for y = 0, height - 1 do
    for _ = 0, width - 1 do
      pixels[#pixels + 1] = string.char(
        16 + math.floor(y * 24 / height),
        28 + math.floor(y * 36 / height),
        48 + math.floor(y * 48 / height),
        255
      )
    end
  end
  return { width = width, height = height, pixels = table.concat(pixels) }
end

---@param romFs table<string, unknown>
---@return table<string, unknown>|nil
---@return Errors.Error|string|nil
function StartupVisualCompiler.compile(romFs)
  assert(romFs and type(romFs.metadata) == "function", "startup visuals require a ROM filesystem")
  local spriteIds, followers = selectedSpriteIds()
  local compiled, err = FieldActorCompiler.compileSprites(romFs, spriteIds)
  if compiled == nil then
    return nil, err
  end
  local versionId = assert(romFs:version(), "startup visuals require an edition")
  local atlases, heroes, normalizedFollowers = {}, {}, {}
  local heroSprites = {}
  for identity, gender in pairs(AVATARS) do
    heroSprites[identity] = PlayerAvatar.statesForGender(gender).walking
  end
  for identity, spriteId in pairs(heroSprites) do
    local path = "assets/generated/startup/loader/hero-" .. identity .. ".png"
    heroes[identity] = {
      visual = startupVisual(assert(compiled.visuals[spriteId]), spriteId, identity),
      atlasPath = path,
    }
    atlases[path] = assert(compiled.atlases[spriteId])
  end
  for _, follower in ipairs(followers) do
    local path = "assets/generated/startup/loader/follower-" .. follower.speciesId .. ".png"
    local sourceVisual = assert(compiled.visuals[follower.spriteId])
    normalizedFollowers[#normalizedFollowers + 1] = {
      speciesId = follower.speciesId,
      visual = startupVisual(sourceVisual, follower.spriteId, "follower:" .. follower.speciesId),
      atlasPath = path,
    }
    atlases[path] = assert(compiled.atlases[follower.spriteId])
  end
  local dependencies = {
    versionId = versionId,
    romSha1 = assert(romFs:metadata().sha1),
    actorSources = compiled.dependencies,
    spriteIds = spriteIds,
    followerSpecies = FOLLOWER_SPECIES,
  }
  return {
    manifest = {
      schema = "g4-startup-loader-v1",
      versionId = versionId,
      heroes = heroes,
      followers = normalizedFollowers,
      backdrop = { kind = "authored", width = 256, height = 192 },
    },
    atlases = atlases,
    backdrop = authoredBackdrop(),
    dependencies = dependencies,
    sourceHash = Hashing.hashLua(dependencies),
  }
end

return StartupVisualCompiler
