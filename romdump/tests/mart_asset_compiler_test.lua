-- HGSS mart compiler failure contracts.
-- Source authority: pret/pokeheartgold@9d8b7591f09b65804da2fb2dfd56f320633e0d36,
-- src/scrcmd_mart.c, asm/overlay_31.s, and src/overlay_03/shop_menu.c.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")

local T = {}

function T.missing_required_source_member_returns_a_structured_mart_error()
  local compiler = require("romdump.src.digest.ui.MartAssetCompiler")
  local aliases = {
    NARC_a_0_6_0 = 0,
    NARC_data_resdat = 1,
    messages = 2,
  }
  local resdatMembers = { [64] = true, [65] = true, [66] = true, [67] = true, [88] = true }
  local romFs = {
    metadata = function()
      return { sha1 = string.rep("a", 40) }
    end,
    openNarc = function(_, alias)
      local fileId = aliases[alias]
      Assert.notNil(fileId, "compiler resolves a known semantic archive alias: " .. tostring(alias))
      return {
        readMember = function(_, memberId)
          if alias == "NARC_data_resdat" then
            Assert.isTrue(resdatMembers[memberId], "compiler reads only selected resdat correlation members")
            return "resdat member " .. memberId
          end
          if alias == "NARC_a_0_6_0" then
            Assert.equal(memberId, 0, "the first required main resource decode is the selected char")
          else
            Assert.equal(memberId, 435, "the message selector resolves the selected bank")
          end
          return nil, Errors.new("ROM_MEMBER_MISSING", "fixture has no selected member", { memberId = memberId })
        end,
      }
    end,
    resolvedNarc = function(_, alias)
      local fileId = aliases[alias]
      Assert.notNil(fileId, "compiler resolves a known semantic archive alias: " .. tostring(alias))
      return { fileId = fileId }
    end,
    read = function(_, fileId)
      Assert.isTrue(fileId >= 0 and fileId <= 2, "all selected semantic archive files are readable")
      return "archive bytes " .. fileId
    end,
  }

  local bundle, err = compiler.compile(romFs)
  Assert.isNil(bundle, "an incomplete source family cannot produce a plausible bundle")
  Assert.isTrue(Errors.is(err), "source failure remains structured")
  Assert.equal(err.code, compiler.ERROR.SOURCE_INVALID)
  Assert.equal(err.context.archive, "NARC_a_0_6_0")
  Assert.equal(err.context.memberId, 0)
  Assert.equal(err.context.role, "main-char", "source failure names its semantic role")
end

return { tests = T }
