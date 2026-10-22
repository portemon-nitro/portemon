-- Resolves the battle menu's type sprite through the source-generated bag visual.

local Assert = require("tests.support.Assert")
local BagCache = require("libs.assets.src.BagCache")
local BattlePresentationCache = require("libs.assets.src.battle.BattlePresentationCache")
local FieldBattlePresentation = require("game.hgss.src.field.FieldBattlePresentation")

local T = {}

function T.battle_move_type_icons_resolve_the_generated_source_visual()
  local iconPath = "assets/generated/bag/move-type-normal-frame-1.png"
  local manifest = {
    schema = BagCache.SCHEMA,
    hero = { moveSummary = { typeIcons = { normal = { image = iconPath } } } },
  }
  local cacheFs = { versionId = "battle-type-icon-probe" }
  function cacheFs:loadLua(path)
    if path == BattlePresentationCache.manifestPath() then
      return nil
    end
    if path == BagCache.manifestPath() then
      return manifest
    end
    return nil
  end
  function cacheFs:read(path)
    if path == iconPath then
      return "staged-type-icon-png"
    end
    return nil
  end

  local uploadedPath = nil
  local savedLove = rawget(_G, "love")
  rawset(_G, "love", {
    image = {
      newImageData = function(fileData)
        return fileData
      end,
    },
    filesystem = {
      newFileData = function(bytes, path)
        Assert.equal(bytes, "staged-type-icon-png", "the icon upload uses staged source bytes")
        uploadedPath = path
        return { path = path }
      end,
    },
  })
  local ok, failure = pcall(function()
    local envelope = FieldBattlePresentation.new({
      cacheFs = cacheFs,
      windows = {},
      text = {},
      measureDisplay = function()
        return {}
      end,
      graphics = {
        newImage = function(data)
          return {
            path = data.path,
            setFilter = function() end,
            release = function() end,
          }
        end,
      },
    })
    local icon = envelope:_preparationServices().drawable("battle:move-type-icon:normal")
    Assert.notNil(icon, "the type icon gets an owned image from the bag source visual")
    Assert.equal(uploadedPath, iconPath, "the drawable maps to the generated source type image")
    envelope:dispose()
  end)
  rawset(_G, "love", savedLove)
  if not ok then
    error(failure, 0)
  end
end

return { tests = T }
