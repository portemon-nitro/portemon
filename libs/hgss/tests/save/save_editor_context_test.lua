-- Tests the read-only validation context consumed by the save editor.

local Assert = require("tests.support.Assert")
local GameSaveValidation = require("libs.hgss.src.save.GameSaveValidation")

local T = {}

function T.version_context_is_cached_and_keeps_injected_contexts()
  local loads = 0
  local selected = {
    language = "english",
    marker = {},
    audioSequenceIds = {},
    scriptCompatibility = {},
  }
  local validation = GameSaveValidation.new({
    contextLoader = function(versionId)
      loads = loads + 1
      Assert.equal("heartgold", versionId)
      return selected
    end,
  })

  local first = validation:contextForVersion("heartgold")
  local second = validation:contextForVersion("heartgold")

  Assert.equal(selected, first)
  Assert.equal(first, second)
  Assert.equal(1, loads)
  Assert.equal("english", first.language)
end

return { tests = T }
