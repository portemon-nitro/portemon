-- Suites never silently pass for an absent ROM. A `RomImporter.isReady`
-- guard that answers a missing dump with a bare `return` reports a pass for
-- work it never did; the runner owns two loud alternatives instead — the
-- `rom_dump` capability (a missing capability skips the whole suite) and
-- `context:skip(reason)` (an explicit per-test skip). This gate flags only
-- the bare-return shape; guards that skip explicitly or fail loudly never
-- match it, and version collectors stay loud through the capability gate
-- and their own coverage asserts.

local Assert = require("tests.support.Assert")
local Runner = require("tests.run")

local T = {}

local listing = nil

local function corpus()
  if listing == nil then
    listing = Runner.list({})
  end
  return listing
end

local function sourceOf(moduleName)
  local path = moduleName:gsub("%.", "/") .. ".lua"
  local file = assert(io.open(path, "r"), "cannot read test source: " .. path)
  local source = file:read("*a")
  file:close()
  return path, source
end

-- Line numbers of every missing-ROM guard whose consequence is an immediate
-- bare `return`. Balanced parens cover every argument shape; anything but
-- whitespace may not intervene between `then` and `return`, so an explicit
-- skip or a loud failure never matches.
---@param source string
---@return integer[] lines
local function silentRomReturns(source)
  local lines = {}
  local start = 1
  while true do
    local found, finish = source:find("if not RomImporter%.isReady%b()%s*then%s*return%s", start)
    if found == nil then
      return lines
    end
    lines[#lines + 1] = select(2, source:sub(1, found):gsub("\n", "")) + 1
    start = finish + 1
  end
end

function T.no_suite_silently_passes_without_its_rom()
  local offenders = {}
  for _, suite in ipairs(corpus()) do
    local path, source = sourceOf(suite.module)
    for _, line in ipairs(silentRomReturns(source)) do
      offenders[#offenders + 1] = path .. ":" .. line
    end
  end

  Assert.isTrue(
    #offenders == 0,
    "missing-ROM guards must skip explicitly or fail loudly, never return into a pass:\n  "
      .. table.concat(offenders, "\n  ")
  )
end

-- The soulsilver-gated Lugia graphics coverage reports an explicit skip
-- when its dump is absent (a heartgold-only checkout): it never fails for
-- a missing ROM and never passes without drawing. The dump gate is stubbed
-- instead of touching the registered sources, so the checkout is unchanged.
function T.soulsilver_gated_lugia_coverage_skips_without_its_dump()
  local suite = require("tests.graphics.lugia_appearance_graphics_test")
  local names = {}
  for name in pairs(suite.tests) do
    names[#names + 1] = name
  end
  Assert.equal(#names, 1, "the lugia graphics suite owns its single gated test")
  local RomImporter = require("romdump.src.source.RomImporter")
  local originalIsReady = RomImporter.isReady
  RomImporter.isReady = function(versionId)
    return versionId ~= "soulsilver"
  end
  local skippedReason = nil
  local context = {
    skip = function(_, reason)
      skippedReason = reason
      error({ lugiaGuardSkip = true }, 0)
    end,
  }
  local ok = pcall(suite.tests[names[1]], context)
  RomImporter.isReady = originalIsReady
  Assert.isFalse(ok, "the gated test must not pass without its dump")
  Assert.isTrue(
    type(skippedReason) == "string" and skippedReason:find("soulsilver", 1, true) ~= nil,
    "the gated test skips explicitly and names the missing dump"
  )
end

return { tests = T }
