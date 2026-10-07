-- Failure-path contract for the native summary asset compiler: every
-- missing archive, malformed member, impossible selector, and motion
-- sensitivity violation fails loudly with its owner instead of
-- publishing a partial family. Synthetic archives only; no dump
-- required.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")

local T = {}

local function requireCompiler()
  local ok, compiler = pcall(require, "romdump.src.digest.ui.SummaryAssetCompiler")
  Assert.isTrue(ok, "the summary asset compiler is missing")
  return compiler
end

local function archiveWith(members, count)
  local archive = {}
  function archive:readMember(memberId)
    return members[memberId]
  end
  function archive:memberCount()
    return count or 0
  end
  return archive
end

local function validCatalog()
  return { species = { BULBASAUR = { forms = { [0] = {} } } } }
end

local function validPortraits()
  return { entries = { ["BULBASAUR/f0/male/plain"] = true } }
end

local function failsWith(romFs, catalog, portraits, code)
  local compiler = requireCompiler()
  local bundle, err = compiler.compile(romFs, catalog, portraits)
  Assert.isNil(bundle, "malformed input publishes nothing")
  Assert.isTrue(Errors.is(err), "malformed input fails structurally")
  Assert.equal(err.code, code, "the failure names its owner")
end

local function romFsOver(overrides)
  local romFs = {}
  function romFs:metadata()
    return { sha1 = "abc" }
  end
  function romFs:resolvedNarc(symbol)
    return { symbol = symbol }
  end
  function romFs:read(path)
    return nil
  end
  function romFs:openNarc(symbol)
    if overrides[symbol] ~= nil then
      if overrides[symbol] == false then
        return nil, Errors.new("ROMFS_NARC_UNRESOLVED", "no resolved NARC for " .. symbol, { name = symbol })
      end
      return overrides[symbol]
    end
    return nil, Errors.new("ROMFS_NARC_UNRESOLVED", "no resolved NARC for " .. symbol, { name = symbol })
  end
  return romFs
end

-- An unreadable ui archive fails before any pixel is produced.
function T.unreadable_ui_archive_fails()
  local romFs = romFsOver({ ["NARC_a_1_6_2"] = false })
  failsWith(romFs, validCatalog(), validPortraits(), "SUMMARY_SOURCE_INVALID")
end

-- A wrong member census on the ui archive fails instead of lowering
-- unknown members.
function T.wrong_ui_member_census_fails()
  local romFs = romFsOver({ ["NARC_a_1_6_2"] = archiveWith({}, 12) })
  failsWith(romFs, validCatalog(), validPortraits(), "SUMMARY_SOURCE_INVALID")
end

-- Compilation requires the mon catalog; without it there is no species
-- closure to bind selectors against.
function T.missing_catalog_fails()
  local romFs = romFsOver({})
  failsWith(romFs, nil, validPortraits(), "SUMMARY_SOURCE_INVALID")
end

-- A source reader without metadata fails before any archive opens.
function T.reader_without_metadata_fails()
  local compiler = requireCompiler()
  local romFs = { openNarc = function() end, resolvedNarc = function() end, read = function() end }
  local bundle, err = compiler.compile(romFs, validCatalog(), validPortraits())
  Assert.isNil(bundle, "malformed input publishes nothing")
  Assert.isTrue(Errors.is(err), "malformed input fails structurally")
  Assert.equal(err.code, "SUMMARY_SOURCE_INVALID", "the failure names its owner")
end

-- A catalog without species binds no closure.
function T.catalog_without_species_fails()
  local romFs = romFsOver({})
  failsWith(romFs, { species = {} }, validPortraits(), "SUMMARY_SOURCE_INVALID")
end

-- The producer inventory keeps the persistent fixed templates apart
-- from the three normal-group tables: info carries 8 source rows,
-- skills 18, and performance 8, in tile units. The scan below is
-- name-agnostic on purpose: role naming is producer-private, while the
-- row geometry itself is the locked source fact.
local EXPECTED_GROUP_ROWS = {
  { bg = "bg4", x = 12, y = 1, width = 3, height = 2 },
  { bg = "bg4", x = 9, y = 3, width = 9, height = 2 },
  { bg = "bg4", x = 9, y = 7, width = 9, height = 2 },
  { bg = "bg4", x = 11, y = 9, width = 5, height = 2 },
  { bg = "bg4", x = 10, y = 13, width = 7, height = 2 },
  { bg = "bg4", x = 11, y = 17, width = 6, height = 2 },
  { bg = "bg1", x = 0, y = 3, width = 18, height = 18 },
  { bg = "bg1", x = 1, y = 22, width = 11, height = 2 },
  { bg = "bg1", x = 11, y = 3, width = 7, height = 2 },
  { bg = "bg1", x = 13, y = 6, width = 3, height = 2 },
  { bg = "bg1", x = 13, y = 8, width = 3, height = 2 },
  { bg = "bg1", x = 13, y = 10, width = 3, height = 2 },
  { bg = "bg1", x = 13, y = 12, width = 3, height = 2 },
  { bg = "bg1", x = 13, y = 14, width = 3, height = 2 },
  { bg = "bg1", x = 9, y = 17, width = 9, height = 2 },
  { bg = "bg1", x = 0, y = 19, width = 19, height = 4 },
  { bg = "bg4", x = 5, y = 1, width = 11, height = 4 },
  { bg = "bg4", x = 5, y = 5, width = 11, height = 4 },
  { bg = "bg4", x = 5, y = 9, width = 11, height = 4 },
  { bg = "bg4", x = 5, y = 13, width = 11, height = 4 },
  { bg = "bg4", x = 5, y = 19, width = 11, height = 4 },
  { bg = "bg4", x = 27, y = 6, width = 3, height = 2 },
  { bg = "bg4", x = 27, y = 8, width = 3, height = 2 },
  { bg = "bg4", x = 17, y = 10, width = 15, height = 10 },
  { bg = "bg4", x = 1, y = 20, width = 15, height = 2 },
  { bg = "bg4", x = 1, y = 17, width = 10, height = 2 },
  { bg = "bg4", x = 13, y = 17, width = 5, height = 2 },
  { bg = "bg4", x = 1, y = 16, width = 21, height = 2 },
  { bg = "bg4", x = 1, y = 18, width = 30, height = 4 },
  { bg = "bg1", x = 1, y = 3, width = 10, height = 2 },
  { bg = "bg1", x = 1, y = 7, width = 10, height = 2 },
  { bg = "bg1", x = 1, y = 11, width = 10, height = 2 },
  { bg = "bg1", x = 1, y = 15, width = 10, height = 2 },
  { bg = "bg1", x = 1, y = 19, width = 10, height = 2 },
}

local function collectWindowRows(value, out, seen)
  if type(value) ~= "table" or seen[value] then
    return
  end
  seen[value] = true
  if
    type(value.bg) == "string"
    and type(value.x) == "number"
    and type(value.y) == "number"
    and type(value.width) == "number"
    and type(value.height) == "number"
  then
    out[#out + 1] = value.bg
      .. ":" .. value.x .. "," .. value.y .. "," .. value.width .. "x" .. value.height
  end
  for _, child in pairs(value) do
    collectWindowRows(child, out, seen)
  end
end

-- The normal-group inventory keeps its per-group census apart from the
-- fixed templates: info carries 8 source rows, skills 18, and performance
-- 8, in tile units. The compiler lowers each group inventory to the
-- matching semantic pane roles, so a dropped or reassigned row fails here
-- before it can reach the generated family.
function T.source_inventory_counts_normal_group_windows_per_group()
  local ok, sources = pcall(require, "romdump.src.config.SummarySources")
  Assert.isTrue(ok, "the summary source catalog is missing")
  local groups = assert(
    sources.groupWindows,
    "the source catalog keeps the normal-group window inventory apart from the fixed templates"
  )
  for _, expectation in ipairs({
    { name = "info", rows = 8 },
    { name = "skills", rows = 18 },
    { name = "performance", rows = 8 },
  }) do
    local inventory = assert(
      groups[expectation.name],
      "the source catalog carries the " .. expectation.name .. " group window inventory"
    )
    Assert.equal(
      #inventory,
      expectation.rows,
      "the " .. expectation.name .. " group keeps its source window census"
    )
  end
end

-- Every window row the producer inventory carries must resolve its
-- numeric palette slot through the transcribed text roles: the compiler
-- rejects a used slot without a binding instead of publishing an
-- unresolvable family, so this inventory check keeps the role coverage
-- complete across the fixed and normal-group tables.
function T.source_inventory_binds_every_window_palette_slot_to_a_text_role()
  local ok, sources = pcall(require, "romdump.src.config.SummarySources")
  Assert.isTrue(ok, "the summary source catalog is missing")
  local roles = assert(sources.textRoles, "the source catalog carries its window text roles")
  local slots = assert(roles.windowSlots, "the text roles bind their window palette slots")
  local function checkRows(rows, what)
    for index, row in ipairs(rows) do
      Assert.isTrue(
        slots[row.palette] ~= nil,
        what .. " row " .. index .. " palette slot " .. tostring(row.palette) .. " resolves through a text role"
      )
    end
  end
  checkRows(assert(sources.fixedWindows, "the source catalog carries its fixed window rows"), "fixed")
  local groups = assert(sources.groupWindows, "the source catalog carries its normal-group window rows")
  for _, name in ipairs({ "info", "skills", "performance" }) do
    checkRows(assert(groups[name], "the source catalog carries the " .. name .. " rows"), name)
  end
end

function T.source_inventory_separates_fixed_and_normal_group_windows()
  local ok, sources = pcall(require, "romdump.src.config.SummarySources")
  Assert.isTrue(ok, "the summary source catalog is missing")
  local rows = {}
  collectWindowRows(sources, rows, {})
  Assert.equal(#rows, 68, "the inventory keeps 34 fixed rows plus 8/18/8 normal-group rows")
  local seen = {}
  for _, row in ipairs(rows) do
    seen[row] = true
  end
  for _, expected in ipairs(EXPECTED_GROUP_ROWS) do
    local key = expected.bg .. ":" .. expected.x .. "," .. expected.y .. "," .. expected.width .. "x" .. expected.height
    Assert.isTrue(seen[key] == true, "the inventory omits the normal-group row " .. key)
  end
end

return { tests = T }
