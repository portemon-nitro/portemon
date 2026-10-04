-- Builds an isolated save root around a canonical record from the real runtime.

local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local GameSaveStore = require("libs.hgss.src.save.GameSaveStore")
local SaveFs = require("libs.storage.src.SaveFs")

local M = {}
local serial = 0

local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  local result = {}
  for key, entry in pairs(value) do
    result[key] = copy(entry)
  end
  return result
end

local function freshRecord()
  local game = AcceptanceHarness.new():boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = "MAP_BURNED_TOWER_1F",
    save = "fresh",
  })
  local ok, record = xpcall(function()
    game:waitForFieldReady()
    return assert(game.runtime:captureGameSave(), "the production runtime must provide a canonical save")
  end, debug.traceback)
  local closeOk, closeError = pcall(function()
    game:close()
  end)
  if not closeOk then
    error(closeError, 0)
  end
  if not ok then
    error(record, 0)
  end
  return record
end

local function isolatedBackend(namespace)
  local fs = love.filesystem
  local function map(path)
    return namespace .. "/" .. path:gsub("^saves/", "")
  end
  return {
    write = function(_, path, data)
      return fs.write(map(path), data)
    end,
    read = function(_, path)
      return fs.read(map(path))
    end,
    getInfo = function(_, path)
      return fs.getInfo(map(path))
    end,
    createDirectory = function(_, path)
      return fs.createDirectory(map(path))
    end,
    remove = function(_, path)
      return fs.remove(map(path))
    end,
    replace = function(_, sourcePath, destinationPath)
      return os.rename(
        fs.getSaveDirectory() .. "/" .. map(sourcePath),
        fs.getSaveDirectory() .. "/" .. map(destinationPath)
      )
    end,
  }
end

local function removeTree(path)
  local fs = love.filesystem
  local info = fs.getInfo(path)
  if info == nil then
    return
  end
  if info.type == "directory" then
    for _, child in ipairs(fs.getDirectoryItems(path)) do
      removeTree(path .. "/" .. child)
    end
  end
  assert(fs.remove(path), "acceptance cleanup must remove " .. path)
end

function M.new()
  serial = serial + 1
  local namespace = "acceptance/save-editor/" .. serial
  local saveFs = SaveFs.global(isolatedBackend(namespace))
  local store = GameSaveStore.new(saveFs)
  local saveId = store:reserve()
  local record = copy(freshRecord())
  record.saveId = saveId
  store:publishFirst(record)
  return {
    initial = copy(record),
    versionId = record.versionId,
    initialMoney = record.playerData.profile.money,
    saveId = saveId,
    saveFs = saveFs,
    store = store,
    namespace = namespace,
    cleanup = function()
      removeTree(namespace)
    end,
  }
end

return M
