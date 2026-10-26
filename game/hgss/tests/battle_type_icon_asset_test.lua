-- Battle move icons resolve through the generated shared move-icons family.

local Assert = require("tests.support.Assert")
local MoveIconCache = require("libs.assets.src.MoveIconCache")
local FieldBattlePresentation = require("game.hgss.src.field.FieldBattlePresentation")

local T = {}

function T.battle_move_type_icons_use_the_generated_move_icon_manifest()
  local iconPath = "assets/generated/move-icons/type-normal.png"
  local manifest = {
    schema = MoveIconCache.SCHEMA,
    types = { normal = { image = iconPath, width = 32, height = 16, offset = { x = -1, y = 2 } } },
  }
  local cacheFs = { versionId = "battle-type-icon-probe" }
  function cacheFs:loadLua(path)
    if path == MoveIconCache.manifestPath() then
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
  local ok, drawable, failure = pcall(function()
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
    Assert.notNil(icon, "the type icon gets an owned image from the shared source visual")
    local width, height = icon:getDimensions()
    Assert.equal(width, 32, "the generated icon preserves its width")
    Assert.equal(height, 16, "the generated icon preserves its height")
    Assert.deepEqual(icon.offset, { x = -1, y = 2 }, "the generated sprite keeps its authored offset")
    envelope:dispose()
    return icon
  end)
  rawset(_G, "love", savedLove)
  if not ok then
    error(drawable, 0)
  end
  Assert.equal(uploadedPath, iconPath, "the drawable maps to the generated move icon image")
  Assert.notNil(drawable, "the generated icon remains available after its owned image was uploaded")
  Assert.isNil(failure, "the staged icon resolves without a terminal failure")
end

return { tests = T }
