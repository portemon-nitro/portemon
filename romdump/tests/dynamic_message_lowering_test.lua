-- Variable message opcodes retain their owning source message bank.
local Assert = require("tests.support.Assert")
local SemanticLowering = require("romdump.src.digest.script.SemanticLowering")
local SourceCatalog = require("romdump.src.digest.script.SourceCatalog")

local T = {}

function T.variable_message_uses_the_script_message_bank()
  local result = SemanticLowering.lowerScript(
    { instructions = { { opcode = 46, operands = { { raw = "VAR_SPECIAL_x8004" } }, offset = 373 } } },
    { member = 3, messageBank = 40, scripts = {}, movements = {} },
    { stdCatalog = SourceCatalog.catalog() }
  )
  Assert.deepEqual(result.items[1].message, {
    message = "external",
    bank = 40,
    id = { value = "var", id = "VAR_SPECIAL_x8004" },
  })
end

return { tests = T }
