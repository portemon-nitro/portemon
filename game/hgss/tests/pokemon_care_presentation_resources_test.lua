-- The field's hatch presentation owner: one lease prepares the generated
-- hatch family through the shared image pool, commits one renderer bundle,
-- and returns every acquired image lease exactly once. A missing manifest
-- fails the lease instead of drawing a blank scene, a second concurrent
-- acquire is a composition error, and the field-lifetime release is
-- idempotent.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local PokemonCareCache = require("libs.assets.src.PokemonCareCache")
local SharedImagePoolFake = require("tests.support.SharedImagePoolFake")

local T = { tests = {} }

-- A minimal but schema-valid hatch manifest whose images are staged paths the
-- pool fake resolves without any real pixels.
local function manifest()
  local image = function(name)
    return { image = PokemonCareCache.hatchDir() .. "/" .. name .. ".png", width = 8, height = 8 }
  end
  local particles = function(name)
    return {
      emitters = { { id = 0, textureImage = PokemonCareCache.hatchDir() .. "/" .. name .. "-texture.png" } },
      textures = { { image = PokemonCareCache.hatchDir() .. "/" .. name .. "-texture.png", width = 8, height = 8 } },
    }
  end
  return {
    schema = PokemonCareCache.HATCH_SCHEMA,
    background = image("background"),
    window = { x = 16, y = 152, width = 216, height = 32 },
    egg = { frames = { image("egg-0"), image("egg-1") } },
    bars = { frames = { image("bars-0") } },
    messages = {
      hatched = { id = 0, text = "{name} hatched from the Egg!" },
      nicknameQuestion = { id = 1, text = "Give a nickname to {name}?", align = "center" },
      yes = { id = 2, text = "Yes", align = "center" },
      no = { id = 3, text = "No", align = "center" },
    },
    particles = { egg = particles("egg"), manaphy = particles("manaphy") },
  }
end

local function graphics()
  return { draw = function() end }
end

local function recordingWindow()
  return {
    drawWindow = function() end,
  }
end

local function textRenderer()
  return {
    windowBackgroundColor = function()
      return { 0, 0, 0 }
    end,
    drawTextWithPalette = function() end,
    drawFocusIndicator = function() end,
  }
end

---@param seedManifest boolean
---@return table owner, table pool
local function owner(seedManifest)
  local cacheFs = CacheFs.forVersion("soulsilver", FakeCache.new())
  if seedManifest then
    cacheFs:writeLua(PokemonCareCache.hatchManifestPath(), manifest())
  end
  local PokemonCarePresentationResources = require("game.hgss.src.field.PokemonCarePresentationResources")
  local pool = SharedImagePoolFake.new()
  return PokemonCarePresentationResources.new({
    cacheFs = cacheFs,
    graphics = graphics(),
    imagePool = pool,
    text = textRenderer(),
    window = recordingWindow(),
    fontDef = {},
    frameIndex = 0,
  }), pool
end

function T.tests.a_lease_prepares_and_commits_one_bundle()
  local resources = owner(true)
  local lease = resources:acquire({ kind = "hatch", variant = "egg", species = 172, form = 0, nickname = "PICHU" })
  local outcome = lease:prepare()
  Assert.equal(outcome.kind, "ready", "the prepared family commits one bundle")
  Assert.notNil(outcome.presentation.renderer, "the bundle carries its renderer")
  Assert.equal(outcome.presentation.name, "PICHU", "the bundle carries the hatched default name")
  Assert.notNil(lease:presentation(), "the committed bundle stays readable")
  local again = lease:prepare()
  Assert.equal(again.kind, "ready", "a repeated prepare serves the committed bundle")
  Assert.equal(again.presentation, outcome.presentation, "the same bundle is never rebuilt")
  lease:release()
  Assert.isNil(lease:presentation(), "a released lease serves no bundle")
  lease:release()
end

function T.tests.a_missing_family_fails_the_lease()
  local resources = owner(false)
  local lease = resources:acquire({ kind = "hatch", variant = "egg", species = 172, form = 0, nickname = "PICHU" })
  local outcome = lease:prepare()
  Assert.equal(outcome.kind, "failed", "a missing hatch family fails instead of drawing nothing")
  Assert.isTrue(tostring(outcome.error):find("manifest", 1, true) ~= nil, "the failure names the missing manifest")
  Assert.isNil(lease:presentation(), "a failed lease commits no bundle")
  lease:release()
end

function T.tests.one_lease_owns_the_presented_lifetime()
  local resources = owner(true)
  local lease = resources:acquire({ kind = "hatch", variant = "egg", species = 172, form = 0, nickname = "PICHU" })
  Assert.notNil(lease)
  local ok, err = pcall(resources.acquire, resources, {
    kind = "hatch",
    variant = "egg",
    species = 172,
    form = 0,
    nickname = "PICHU",
  })
  Assert.isFalse(ok, "one hatch application owns the presentation")
  assert(type(err) == "string", "the refusal names the owner")
  lease:release()
  local nextLease = resources:acquire({ kind = "hatch", variant = "egg", species = 172, form = 0, nickname = "PICHU" })
  Assert.notNil(nextLease, "a released lease frees the owner for the next application")
  nextLease:release()
  resources:release()
  resources:release()
end

function T.tests.release_returns_every_image_lease_once()
  local resources = owner(true)
  local lease = resources:acquire({ kind = "hatch", variant = "egg", species = 172, form = 0, nickname = "PICHU" })
  Assert.equal(lease:prepare().kind, "ready")
  local acquired = 0
  for _ in pairs(lease._acquired) do
    acquired = acquired + 1
  end
  Assert.equal(acquired, #PokemonCareCache.referencedHatchPaths(manifest()), "every referenced image is acquired")
  local releases = {}
  for path, handle in pairs(lease._acquired) do
    releases[path] = handle
    local original = handle.release
    handle.release = function(self, ...)
      handle.__releases = (handle.__releases or 0) + 1
      return original(self, ...)
    end
  end
  resources:release()
  for path, handle in pairs(releases) do
    Assert.equal(handle.__releases, 1, "image lease released exactly once: " .. path)
  end
  Assert.equal(lease:prepare().kind, "failed", "a released lifetime serves no further lease")
end

return T
