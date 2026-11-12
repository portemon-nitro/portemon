-- Static contract guard: keeps source-independent asset contracts grouped by
-- domain while leaving their exported values and serialized contracts alone.

local Assert = require("tests.support.Assert")

local T = {}

local BASE = love.filesystem.getSourceBaseDirectory()
local ASSET_SOURCE_ROOT = "libs/assets/src"

local DOMAINS = {
  audio = {
    "AudioBank",
    "AudioCache",
    "AudioCacheValidator",
    "AudioErrors",
    "AudioSample",
    "AudioSequence",
  },
  model = {
    "AnimationClip",
    "CompiledNsbtaClip",
    "G4MeshFormat",
    "MeshWriter",
    "ModelAsset",
    "NsbmdJointTransforms",
    "NsbmdSbcEvaluator",
    "PolygonState",
    "PoseContract",
    "VertexFormat",
  },
  field = {
    "CollisionGridAsset",
    "FieldActorCache",
    "FieldCameraCache",
    "FieldCellCache",
    "FieldEffectAssetCache",
    "FieldEmoteAssetCache",
    "FieldEntryAssetCache",
    "FieldFontCache",
    "FieldLightProfile",
    "FieldMapDataCache",
    "FieldMessageCache",
    "FieldMessageText",
    "FieldMoveCutInBannerAssetCache",
    "FieldObjectMovement",
    "FieldScriptSymbols",
    "FieldUiAssetCache",
    "FieldUiManifestChecks",
    "FieldUiNamingValidation",
    "FieldUiStartMenuValidation",
    "FieldWeatherCache",
    "HoOhCinematicParts",
  },
  newgame = {
    "IntroAssetCache",
    "NewGameInitCache",
  },
  battle = {
    "BattleAnimationSchema",
    "BattleDataCache",
    "BattleDataSchema",
    "BattlePresentationCache",
    "BattlePresentationParticles",
    "BattlePresentationSchema",
  },
  -- The private effective-image derivative format behind worker-side
  -- image classification: source-independent and love-free.
  image = {
    "RuntimeImageCache",
  },
}

local SHARED = {
  "BagAssetSchema",
  "BagCache",
  "ApricornBoxAssetCache",
  "BagHeroValidation",
  "BagInteractiveValidation",
  "BagManifestChecks",
  "DerivedAssetContract",
  "ErrorCodes",
  "ItemAssetSchema",
  "ItemCache",
  "MartAssetSchema",
  "MartCache",
  "MoveIconAssetSchema",
  "MoveIconCache",
  "MapAssetCache",
  "MenuProtocol",
  "MonAssetSchema",
  "MonCache",
  "MonSharedEnums",
  "PartyAssetSchema",
  "PartyCache",
  "PcAssetSchema",
  "PcCache",
  "PokegearAssetSchema",
  "PokegearCache",
  "EasyChatAssetSchema",
  "EasyChatCache",
  "PokedexAssetSchema",
  "PokedexCache",
  "SummaryAssetSchema",
  "SummaryCache",
  "PngWriter",
  "SchemaCheck",
  "ScriptCache",
  "ScriptIdentity",
  "ScriptOverrides",
  "StarterChoiceAssetCache",
  "StartupAssetCache",
  "Utf8Glyphs",
  "Validate",
  "errors",
}

local function pathExists(path)
  local handle = io.open(BASE .. "/" .. path, "r")
  if handle == nil then
    return false
  end
  handle:close()
  return true
end

local function luaFilesUnder(root)
  local command = "find '" .. BASE .. "/" .. root .. "' -type f -name '*.lua' -print 2>/dev/null"
  local pipe = assert(io.popen(command, "r"), "cannot list " .. root)
  local prefix = BASE .. "/"
  local files = {}
  for line in pipe:lines() do
    assert(line:sub(1, #prefix) == prefix, "unexpected path outside the repository: " .. line)
    files[#files + 1] = line:sub(#prefix + 1)
  end
  pipe:close()
  return files
end

local function expectedAssetFiles()
  local expected = {}
  for domain, modules in pairs(DOMAINS) do
    for _, moduleName in ipairs(modules) do
      expected[ASSET_SOURCE_ROOT .. "/" .. domain .. "/" .. moduleName .. ".lua"] = true
    end
  end
  for _, moduleName in ipairs(SHARED) do
    expected[ASSET_SOURCE_ROOT .. "/" .. moduleName .. ".lua"] = true
  end
  expected[ASSET_SOURCE_ROOT .. "/field/FollowerInteractionCache.lua"] = true
  return expected
end

local function requireFromNewPath(moduleName, label)
  local ok, loaded = pcall(require, moduleName)
  Assert.isTrue(ok, label .. " must load from its domain path: " .. tostring(loaded))
  Assert.equal(type(loaded), "table", label .. " must retain its module contract")
end

function T.asset_contracts_have_exact_shallow_domain_inventory()
  local expected = expectedAssetFiles()
  for path in pairs(expected) do
    Assert.isTrue(pathExists(path), "asset contract is missing from its target path: " .. path)
  end

  local unexpected = {}
  for _, path in ipairs(luaFilesUnder(ASSET_SOURCE_ROOT)) do
    if not expected[path] then
      unexpected[#unexpected + 1] = path
    end
  end
  table.sort(unexpected)
  Assert.isTrue(#unexpected == 0, "unexpected asset source files remain:\n" .. table.concat(unexpected, "\n"))
end

function T.representative_contracts_load_from_each_domain_path()
  requireFromNewPath("libs.assets.src.audio.AudioCache", "audio contracts")
  requireFromNewPath("libs.assets.src.model.ModelAsset", "model contracts")
  requireFromNewPath("libs.assets.src.field.FieldMapDataCache", "field contracts")
  requireFromNewPath("libs.assets.src.newgame.IntroAssetCache", "New Game contracts")
  requireFromNewPath("libs.assets.src.battle.BattleDataCache", "battle contracts")
end

return { tests = T }
