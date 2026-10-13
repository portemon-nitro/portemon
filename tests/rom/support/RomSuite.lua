-- Adapts a real-ROM fact table into an explicit ROM-conformance suite. The
-- suite owns an open direct RomFs reader for every ready game version
-- between its hooks; each reader borrows the canonical --rom-source ROM.

local GameVersion = require("romdump.src.source.GameVersion")
local RomImporter = require("romdump.src.source.RomImporter")
local RomSourcePath = require("tests.rom.support.RomSourcePath")

local RomSuite = {}

local function closeAll(handles)
  for _, handle in ipairs(handles) do
    handle.romFs:close()
    if handle.source ~= nil then
      handle.source:release()
    end
  end
end

---@param options { tests: table<string, fun(romFs: table, versionId: string)>, readyVersions: string[], open: fun(versionId: string): table|nil, table|string|nil }
---@return table suite
function RomSuite.build(options)
  local tests = assert(options.tests, "RomSuite needs tests")
  local readyVersions = assert(options.readyVersions, "RomSuite needs ready versions")
  local open = assert(options.open, "RomSuite needs a RomFs opener")
  local handles = nil
  local suite = {
    metadata = { capabilities = { "rom_dump" } },
    tests = {},
  }

  function suite.beforeAll()
    local opened = {}
    handles = opened
    for _, versionId in ipairs(readyVersions) do
      local romFs, sourceOrErr = open(versionId)
      if romFs == nil then
        handles = nil
        closeAll(opened)
        error("cannot open the source ROM for " .. versionId .. ": " .. tostring(sourceOrErr), 0)
      end
      opened[#opened + 1] = { versionId = versionId, romFs = romFs, source = sourceOrErr }
    end
  end

  function suite.afterAll()
    local opened = handles
    handles = nil
    if opened ~= nil then
      closeAll(opened)
    end
  end

  for name, fn in pairs(tests) do
    suite.tests[name] = function(context)
      for _, handle in ipairs(assert(handles, "the ROM suite has no open source reader")) do
        local ok, err = pcall(fn, handle.romFs, handle.versionId, context)
        if not ok then
          if type(err) == "table" then
            error(err, 0)
          end
          error(handle.versionId .. ": " .. tostring(err), 0)
        end
      end
    end
  end
  return suite
end

---@param tests table<string, fun(romFs: table, versionId: string)>
---@return table suite
function RomSuite.fromFacts(tests)
  local readyVersions = {}
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      readyVersions[#readyVersions + 1] = versionId
    end
  end
  return RomSuite.build({ tests = tests, readyVersions = readyVersions, open = RomSourcePath.openReader })
end

return RomSuite
