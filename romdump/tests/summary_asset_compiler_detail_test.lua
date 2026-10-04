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

return { tests = T }
