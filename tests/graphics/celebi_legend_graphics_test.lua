-- Exercises the generated Celebi model through its real GPU model path.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FieldCamera = require("libs.hgss.src.field.FieldCamera")
local FieldEffectAssetCache = require("libs.assets.src.field.FieldEffectAssetCache")
local FieldRenderer = require("libs.hgss.src.presentation.FieldRenderer")
local FieldViewport = require("libs.hgss.src.presentation.FieldViewport")
local GameVersion = require("romdump.src.source.GameVersion")
local RomImporter = require("romdump.src.source.RomImporter")
local ModelDefinition = require("libs.hgss.src.presentation.ModelDefinition")
local CelebiTimeTravelRenderer = require("libs.hgss.src.presentation.CelebiTimeTravelRenderer")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")

local function readyVersions()
  local versions = {}
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      versions[#versions + 1] = versionId
    end
  end
  return versions
end

local function status(frame)
  return {
    active = true,
    modelVisible = true,
    animationFrame = frame,
    swirlFrame = nil,
    modelPosition = { x = 12.5, y = 3, z = -8 },
    blurActive = false,
    sequence = 1,
  }
end

local T = GraphicsSmoke.suite({
  ["original Celebi model draws with three source-clocked clips"] = function(scope)
    local versions = readyVersions()
    Assert.isTrue(#versions > 0, "a ready imported game version is required")
    for _, versionId in ipairs(versions) do
      local cache = CacheFs.forVersion(versionId)
      local record = assert(cache:loadLua(FieldEffectAssetCache.definitionPath("celebi_time_travel")))
      Assert.isTrue(type(record.model) == "table", versionId .. " publishes the Celebi model")
      local definition = ModelDefinition.fromNitroDescriptor(record.model, { key = "field-effect:celebi_time_travel" })
      local joint = assert(definition:animation("celebi.joint"))
      local pattern = assert(definition:animation("celebi.pattern"))
      local srt = assert(definition:animation("celebi.srt"))
      Assert.equal(pattern.name, joint.name, "pattern clip retains the shared Nitro dictionary name")
      Assert.equal(srt.name, joint.name, "SRT clip retains the shared Nitro dictionary name")
      local presenter = scope:own(CelebiTimeTravelRenderer.new(cache))
      local firstItems = presenter:drawItems(status(0))
      Assert.isTrue(#firstItems > 0, "the source model produces 3D draw items at frame zero")
      Assert.isTrue(firstItems[1].worldSpace, "the model enters the world render queue")
      Assert.equal(firstItems[1].fieldEffect, "celebi_time_travel", "draw items retain semantic diagnostics")
      local first = firstItems[1]
      local initial = {}
      for index, item in ipairs(firstItems) do
        initial[index] = {
          transform = { table.unpack(item.transform) },
          image = item.material and item.material.image,
          texMatrix = item.material and { table.unpack(item.material.texMatrix) } or nil,
        }
      end
      local repeatedItems = presenter:drawItems(status(0))
      Assert.equal(repeatedItems[1].transform[13], first.transform[13], "repeated draw does not advance X")

      local changed = false
      for frame = 1, 210 do
        local frameItems = presenter:drawItems(status(frame))
        Assert.isTrue(#frameItems > 0, "the model remains drawable during its beat")
        for itemIndex, item in ipairs(frameItems) do
          local initialItem = initial[itemIndex]
          local matrixChanged = false
          for index = 1, #initialItem.transform do
            if item.transform[index] ~= initialItem.transform[index] then
              matrixChanged = true
              break
            end
          end
          local textureChanged = item.material ~= nil and item.material.image ~= initialItem.image
          local uvChanged = false
          if item.material ~= nil and initialItem.texMatrix ~= nil then
            for index = 1, #initialItem.texMatrix do
              if item.material.texMatrix[index] ~= initialItem.texMatrix[index] then
                uvChanged = true
                break
              end
            end
          end
          changed = changed or matrixChanged or textureChanged or uvChanged
        end
      end
      Assert.isTrue(changed, "source animation changes model pose or material state")

      local cameraProfiles = assert(cache:loadLua("data/generated/field/camera/profiles.lua"))
      local camera = FieldCamera.new(cameraProfiles.profiles[0], { canonicalAspect = 4 / 3 })
      local renderer = scope:own(FieldRenderer.new({ clearColor = { 0, 0, 0, 1 } }))
      local viewport = FieldViewport.new(256, 192, { mode = "strict" })
      local target = scope:own(love.graphics.newCanvas(256, 192))
      local edgeColors, fogTable = {}, {}
      for index = 0, 7 do
        edgeColors[index] = 0
      end
      for index = 1, 32 do
        fogTable[index] = 0
      end
      love.graphics.setCanvas(target)
      renderer:draw({
        edgeColors = edgeColors,
        fog = { enabled = false, color = 0, offset = 0, slope = 0, alpha = 0, table = fogTable },
      }, camera, { presenter:drawItems(status(210)) }, nil, viewport, 0, 3)
      love.graphics.setCanvas()
      Assert.isTrue(renderer.stats.geometrySubmissions > 0, "Celebi reaches the real field graphics draw")
    end
  end,
}, { capabilities = { "graphics", "derived_assets" } })
T.metadata.derivedAssets = { "field-effects:global" }

return T
