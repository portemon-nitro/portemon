-- Definition-provider tests keep runtime actor composition independent of GPU
-- resources while preserving the manager's acquire/release ownership contract.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local FieldActorCache = require("libs.assets.src.field.FieldActorCache")
local FieldActorDefinitionProvider = require("libs.hgss.src.actors.FieldActorDefinitionProvider")
local FieldActorFixture = require("tests.support.FieldActorFixture")

local T = {}

local function cache()
  local result = CacheFs.forVersion("heartgold", FakeCache.new())
  result:writeLua(FieldActorCache.indexPath(), {
    schema = FieldActorCache.INDEX_SCHEMA,
    spriteIds = { 0 },
    runtime = { avatars = {}, variableSprites = { first = 1, last = 1, variableBase = 0 } },
    romVersion = "heartgold",
    variableSprites = {},
    recordCount = 1,
  })
  result:writeLua(FieldActorCache.visualPath(0), FieldActorFixture.visual(0, { frameCount = 8 }))
  return result
end

local function throwsCode(code, fn)
  local err = Assert.throws(fn)
  Assert.isTrue(Errors.is(err), "expected an Errors object, got " .. tostring(err))
  Assert.equal(err.code, code)
end

function T.loads_and_shares_actor_definitions_without_an_atlas()
  local provider = FieldActorDefinitionProvider.new(cache())
  local first = provider:acquire(0)
  local second = provider:acquire(0)
  Assert.isTrue(first == second, "runtime clients share one definition entry")
  Assert.equal(first.visual.spriteId, 0)
end

function T.releases_the_definition_after_its_last_owner()
  local provider = FieldActorDefinitionProvider.new(cache())
  local first = provider:acquire(0)
  provider:release(0)
  local second = provider:acquire(0)
  Assert.isTrue(first ~= second, "a released runtime definition is no longer resident")
  provider:release(0)
  throwsCode("FIELD_ACTOR_RELEASE_UNKNOWN", function()
    provider:release(0)
  end)
end

-- Published actor definitions are producer-validated before publication, so
-- runtime acquisition must use the loaded visual directly instead of
-- rerunning the full semantic walk. The counter fails while the provider
-- still calls the validator.
function T.published_definition_loads_without_semantic_runtime_validation()
  local calls = 0
  local original = FieldActorCache.isValidVisual
  rawset(FieldActorCache, "isValidVisual", function(...)
    calls = calls + 1
    return original(...)
  end)
  local ok, result = pcall(function()
    local provider = FieldActorDefinitionProvider.new(cache())
    return provider:acquire(0)
  end)
  rawset(FieldActorCache, "isValidVisual", original)
  if not ok then
    error(result, 0)
  end
  Assert.notNil(result, "a published visual must load through the runtime provider")
  Assert.equal(result.visual.spriteId, 0)
  Assert.equal(result.spriteId, 0)
  Assert.equal(calls, 0, "runtime acquisition must not rerun semantic visual validation")
end

-- The presentation provider owns the same trust boundary: atlas bytes load
-- and the visual is used directly, with no semantic revalidation. The
-- graphics stub below creates no GPU resource; it only records images.
local function stubGraphics(created)
  return {
    newImage = function()
      local image = {}
      function image:getWidth()
        return 64
      end
      function image:getHeight()
        return 32
      end
      function image:setFilter(_min, _mag) end
      function image:release()
        self.released = true
      end
      created[#created + 1] = image
      return image
    end,
    newQuad = function(x, y, w, h)
      return { x = x, y = y, w = w, h = h }
    end,
    newMesh = function(_, vertices)
      local mesh = { vertices = vertices }
      function mesh:setVertexMap(_map) end
      function mesh:release()
        self.released = true
      end
      return mesh
    end,
  }
end

function T.asset_provider_loads_published_visual_without_semantic_runtime_validation()
  local FieldActorAssetProvider = require("libs.hgss.src.presentation.FieldActorAssetProvider")
  local seeded = cache()
  seeded:write(FieldActorCache.atlasPath(0), "png-bytes")
  local calls = 0
  local original = FieldActorCache.isValidVisual
  rawset(FieldActorCache, "isValidVisual", function(...)
    calls = calls + 1
    return original(...)
  end)
  local created = {}
  local ok, entry = pcall(function()
    local provider = FieldActorAssetProvider.new(seeded, { graphics = stubGraphics(created) })
    return provider:acquire(0)
  end)
  rawset(FieldActorCache, "isValidVisual", original)
  if not ok then
    error(entry, 0)
  end
  Assert.notNil(entry, "a published visual must load through the presentation provider")
  Assert.equal(entry.spriteId, 0)
  Assert.equal(#created, 1, "the atlas still materializes exactly once")
  Assert.equal(calls, 0, "presentation loading must not rerun semantic visual validation")
end

-- Trust never means silence on absence: a compiled index entry with no
-- published visual still fails at load instead of resolving to anything.
function T.missing_published_visual_still_fails_at_load()
  local missing = CacheFs.forVersion("heartgold", FakeCache.new())
  missing:writeLua(FieldActorCache.indexPath(), {
    schema = FieldActorCache.INDEX_SCHEMA,
    spriteIds = { 0, 1 },
    runtime = { avatars = {}, variableSprites = { first = 1, last = 1, variableBase = 0 } },
    romVersion = "heartgold",
    variableSprites = {},
    recordCount = 2,
  })
  missing:writeLua(FieldActorCache.visualPath(0), FieldActorFixture.visual(0, { frameCount = 8 }))
  local provider = FieldActorDefinitionProvider.new(missing)
  local present = provider:acquire(0)
  Assert.equal(present.visual.spriteId, 0)
  Assert.throws(function()
    provider:acquire(1)
  end, "a missing published visual must fail at load")
end

return { tests = T }
