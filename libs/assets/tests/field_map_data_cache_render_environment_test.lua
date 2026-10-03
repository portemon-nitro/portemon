-- Field-map render-environment readiness: the current field record carries a
-- strict renderer-ready environment, and absent or malformed environments
-- fail readiness instead of reading as an empty feature. Scenarios compile
-- through the real production compiler and publish through the real family
-- writer.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local FieldMapDataCache = require("libs.assets.src.field.FieldMapDataCache")
local FieldMapDataCacheWriter = require("romdump.src.digest.field.FieldMapDataCacheWriter")
local FieldMapDataCompiler = require("romdump.src.digest.field.FieldMapDataCompiler")
local Fixture = require("tests.support.FieldMapDataFixture")
local HgssFieldEdgeColors = require("romdump.src.digest.field.HgssFieldEdgeColors")
local HgssFieldFog = require("romdump.src.digest.field.HgssFieldFog")

local T = {}

local function compile()
  local bundle, err = FieldMapDataCompiler.compile(Fixture.build(), 60)
  Assert.isTrue(bundle ~= nil, "compile failed: " .. tostring(err and err.message or err))
  return assert(bundle)
end

local function validEnvironment()
  return {
    lighting = {
      records = {
        {
          startHalfSeconds = 0,
          lights = {},
          diffuseRgb555 = 0,
          ambientRgb555 = 0,
          specularRgb555 = 0,
          emissionRgb555 = 0,
        },
      },
    },
    edgeColors = HgssFieldEdgeColors.tableForAreaLightPattern(0),
    weatherId = 0,
    fog = HgssFieldFog.runtimePreset(HgssFieldFog.resolve(0)),
  }
end

local function publishedWith(mutator)
  local bundle = compile()
  mutator(bundle.field)
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  FieldMapDataCacheWriter.write(cache, bundle)
  return cache, bundle
end

local function requireValidator()
  Assert.isTrue(
    type(FieldMapDataCache.hasRenderEnvironment) == "function",
    "the field-map cache exposes a render-environment validator"
  )
end

function T.complete_environment_passes_the_validator_and_readiness()
  requireValidator()
  local environment = validEnvironment()
  Assert.isTrue(FieldMapDataCache.hasRenderEnvironment(environment))
  local cache, bundle = publishedWith(function(field)
    field.renderEnvironment = environment
  end)
  Assert.isTrue(FieldMapDataCache.isReady(cache, 60, bundle.marker))
end

function T.absent_environment_fails_readiness()
  requireValidator()
  local cache, bundle = publishedWith(function(field)
    field.renderEnvironment = nil
  end)
  Assert.isFalse(FieldMapDataCache.hasRenderEnvironment(nil))
  Assert.isFalse(FieldMapDataCache.isReady(cache, 60, bundle.marker))
end

function T.unknown_weather_id_fails_the_validator_and_readiness()
  requireValidator()
  local cache, bundle = publishedWith(function(field)
    field.renderEnvironment = validEnvironment()
    field.renderEnvironment.weatherId = 99
  end)
  Assert.isFalse(FieldMapDataCache.hasRenderEnvironment(bundle.field.renderEnvironment))
  Assert.isFalse(FieldMapDataCache.isReady(cache, 60, bundle.marker))
end

function T.short_edge_color_table_fails_the_validator_and_readiness()
  requireValidator()
  local cache, bundle = publishedWith(function(field)
    field.renderEnvironment = validEnvironment()
    field.renderEnvironment.edgeColors = { [0] = 0, 1, 2, 3, 4, 5, 6 }
  end)
  Assert.isFalse(FieldMapDataCache.hasRenderEnvironment(bundle.field.renderEnvironment))
  Assert.isFalse(FieldMapDataCache.isReady(cache, 60, bundle.marker))
end

function T.short_fog_density_table_fails_the_validator_and_readiness()
  requireValidator()
  local cache, bundle = publishedWith(function(field)
    field.renderEnvironment = validEnvironment()
    local short = {}
    for i = 1, 31 do
      short[i] = (i - 1) * 4
    end
    field.renderEnvironment.fog = {
      enabled = false,
      color = 0,
      offset = 0,
      slope = 0,
      alpha = 0,
      table = short,
    }
  end)
  Assert.isFalse(FieldMapDataCache.hasRenderEnvironment(bundle.field.renderEnvironment))
  Assert.isFalse(FieldMapDataCache.isReady(cache, 60, bundle.marker))
end

function T.previous_schema_record_fails_readiness()
  local bundle = compile()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  FieldMapDataCacheWriter.write(cache, bundle)
  -- A leftover previous-schema artifact on disk never reads as current:
  -- the writer itself refuses to publish one, so place the stale bytes
  -- directly and prove readiness still rejects them.
  local stale = compile()
  stale.field.schema = "g4-field-map-v10"
  cache:writeLua(FieldMapDataCache.fieldPath(60), stale.field)
  Assert.isFalse(FieldMapDataCache.isReady(cache, 60, bundle.marker))
end

return { tests = T }
