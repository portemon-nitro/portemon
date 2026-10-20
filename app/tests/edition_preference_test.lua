-- The app preference is strict, edition-whitelisted, and atomically replaced.

local Assert = require("tests.support.Assert")
local EditionPreference = require("app.src.launcher.EditionPreference")

local T = {}
local FILE_NAME = "app-edition.lua"

local function withPreferenceFile(fn)
  love.filesystem.remove(FILE_NAME)
  love.filesystem.remove(FILE_NAME .. ".tmp")
  local ok, err = pcall(fn)
  love.filesystem.remove(FILE_NAME)
  love.filesystem.remove(FILE_NAME .. ".tmp")
  if not ok then
    error(err, 0)
  end
end

function T.read_accepts_only_the_known_version_one_record()
  withPreferenceFile(function()
    Assert.isNil(EditionPreference.read(), "missing preference is absent")
    local wrote = love.filesystem.write(FILE_NAME, 'return { schema = 1, versionId = "heartgold" }\n')
    Assert.isTrue(wrote)
    Assert.equal(EditionPreference.read(), "heartgold")
    local corrupt = {
      'return { schema = 2, versionId = "heartgold" }\n',
      'return { schema = 1, versionId = "unknown" }\n',
      'return { schema = 1, versionId = "heartgold", extra = true }\n',
    }
    for _, content in ipairs(corrupt) do
      love.filesystem.write(FILE_NAME, content)
      Assert.isNil(EditionPreference.read(), "invalid preference is treated as absent")
    end
  end)
end

function T.failed_atomic_replace_preserves_the_previous_preference()
  withPreferenceFile(function()
    local wrote, err = EditionPreference.recordPlayed("heartgold")
    Assert.isTrue(wrote, tostring(err))
    local expectedFailure = "injected replace failure"
    local previousRename = os.rename
    local previousFfi = package.loaded.ffi
    if love.system.getOS() == "Windows" then
      package.loaded.ffi = {
        cdef = function() end,
        load = function()
          error("injected replace failure")
        end,
      }
      expectedFailure = "Windows atomic replace is unavailable"
    else
      os.rename = function()
        return nil, "injected replace failure"
      end
    end
    local ok, failure = EditionPreference.recordPlayed("soulsilver")
    os.rename = previousRename
    package.loaded.ffi = previousFfi
    Assert.isFalse(ok)
    Assert.equal(failure, expectedFailure)
    Assert.equal(EditionPreference.read(), "heartgold", "failed replacement keeps the last good value")
    Assert.isNil(love.filesystem.getInfo(FILE_NAME .. ".tmp"), "failed staging file is removed")
  end)
end

return { tests = T }
