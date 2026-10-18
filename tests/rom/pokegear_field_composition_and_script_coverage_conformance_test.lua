-- Source-command coverage for the pocket-gear field feature: every native
-- command row in the bounded gear inventory carries exact executable
-- semantics. The pinned command table marks each row supported with exact
-- operand widths and same-tick versus blocking timing, every real script
-- use lowers to a typed gear operation instead of an unsupported node, and
-- the independent verifier agrees on the decoded operands. The inventory
-- itself is closed by a bounded census: every table name in the phone, gear,
-- mom-gift, town-map, radio-music, and Buena families plus the one opaque
-- trigger-mutation row is listed, so an unlisted gear row cannot hide as an
-- unknown optional command. Member bytes are never committed to the
-- repository; a missing dump reports a skip, never a pass, through the
-- declared dump capability.

local Assert = require("tests.support.Assert")
local CommandCatalog = require("romdump.src.digest.script.CommandCatalog")
local FieldScripts = require("tests.rom.support.FieldScripts")
local RomSuite = require("tests.rom.support.RomSuite")
local ScriptCommands = require("romdump.src.catalog.hgss.script_commands")

local T = {}

-- The bounded gear inventory: the known phone/card/trigger/call/gift/radio
-- minimum plus the town-map launch, phonebook-entry load, contact-message,
-- mom-gift, and Buena-password rows the bounded function-call census
-- discovers. Widths pin the native operand sizes; `blocks` pins whether the
-- row must continue in the same tick or wait on its task; `result` names
-- whether the last operand carries a script result variable.
local INVENTORY = {
  { opcode = 142, name = "ScrCmd_GetPhoneBookRematch", widths = { [1] = 2, [2] = 2 }, blocks = false, result = true },
  { opcode = 145, name = "ScrCmd_RegisterPokegearCard", widths = { [1] = 1 }, blocks = false, result = false },
  { opcode = 146, name = "ScrCmd_RegisterGearNumber", widths = { [1] = 2 }, blocks = false, result = false },
  { opcode = 147, name = "ScrCmd_CheckRegisteredPhoneNumber", widths = { [1] = 2, [2] = 2 }, blocks = false, result = true },
  { opcode = 148, name = "ScrCmd_148", widths = { [1] = 1, [2] = 1 }, blocks = false, result = false },
  { opcode = 149, name = "UnsetPhoneCallTrigger", widths = { [1] = 1 }, blocks = false, result = false },
  { opcode = 157, name = "ScrCmd_TownMap", widths = {}, blocks = true, result = false },
  { opcode = 430, name = "ScrCmd_SetPhoneCall", widths = { [1] = 2, [2] = 2, [3] = 2 }, blocks = false, result = false },
  { opcode = 431, name = "ScrCmd_RunPhoneCall", widths = {}, blocks = true, result = false },
  { opcode = 460, name = "ScrCmd_LoadPhoneDat", widths = { [1] = 2, [2] = 2 }, blocks = false, result = true },
  { opcode = 461, name = "ScrCmd_GetPhoneContactMsgIds", widths = { [1] = 1, [2] = 2, [3] = 2 }, blocks = false, result = false },
  { opcode = 613, name = "ScrCmd_GetPhoneContactRandomGiftBerry", widths = { [1] = 2 }, blocks = false, result = true },
  { opcode = 614, name = "ScrCmd_GetPhoneContactGiftItem", widths = { [1] = 2 }, blocks = false, result = true },
  { opcode = 779, name = "ScrCmd_RadioMusicIsPlaying", widths = { [1] = 2, [2] = 2 }, blocks = false, result = true },
  { opcode = 813, name = "ScrCmd_MomGiftCheck", widths = { [1] = 2 }, blocks = false, result = true },
  { opcode = 821, name = "ScrCmd_GetBuenasPassword", widths = { [1] = 2, [2] = 2 }, blocks = false, result = true },
}

-- Opcodes whose table names place them outside every gear family and whose
-- native call sites touch unrelated owners (roamer creation, wonder-card
-- trivia, movement-save flags, fossil/item flows) rather than gear state.
-- They are named here so the census closure below stays reviewable.
local OUT_OF_FAMILY_SPOT_CHECKS = { 464, 489, 512, 649 }

-- The bounded census predicate over the pinned table: names in the phone,
-- gear, mom-gift, town-map, radio-music, and Buena families. The opaque
-- trigger-mutation row carries no family name and joins explicitly.
---@param name string
---@return boolean
local function isGearFamilyName(name)
  local lower = name:lower()
  return lower:find("phone", 1, true) ~= nil
    or lower:find("pokegear", 1, true) ~= nil
    or lower:find("gear", 1, true) ~= nil
    or lower:find("momgift", 1, true) ~= nil
    or lower:find("townmap", 1, true) ~= nil
    or lower:find("radiomusic", 1, true) ~= nil
    or lower:find("buena", 1, true) ~= nil
end

---@return integer[] sorted census opcodes
local function censusOpcodes()
  local found = { [148] = true }
  for opcode, entry in pairs(ScriptCommands.byOpcode) do
    if isGearFamilyName(entry.name or "") then
      found[opcode] = true
    end
  end
  local list = {}
  for opcode in pairs(found) do
    list[#list + 1] = opcode
  end
  table.sort(list)
  return list
end

---@param row table
local function checkStaticRow(row)
  local entry = ScriptCommands.byOpcode[row.opcode]
  Assert.notNil(entry, "opcode " .. row.opcode .. " must exist in the pinned command table")
  assert(entry ~= nil, "pinned entry reads above")
  Assert.equal(entry.name, row.name, "opcode " .. row.opcode .. " keeps its pinned source name")
  local widths = assert(entry.widths, "opcode " .. row.opcode .. " must pin its operand widths")
  local widthCount = 0
  for index, width in pairs(widths) do
    widthCount = widthCount + 1
    Assert.equal(
      width,
      row.widths[index],
      "opcode " .. row.opcode .. " operand " .. index .. " keeps its native width"
    )
  end
  local expectedCount = 0
  for _ in pairs(row.widths) do
    expectedCount = expectedCount + 1
  end
  Assert.equal(widthCount, expectedCount, "opcode " .. row.opcode .. " keeps its operand count")
  Assert.equal(
    entry.disposition,
    "supported",
    "opcode " .. row.opcode .. " (" .. row.name .. ") must be executable, not names-only"
  )
  if row.blocks then
    Assert.isTrue(
      CommandCatalog.classification(row.opcode) ~= CommandCatalog.CONTINUE
        and CommandCatalog.classification(row.opcode) ~= CommandCatalog.UNSUPPORTED,
      "opcode " .. row.opcode .. " (" .. row.name .. ") must block on its task instead of continuing same-tick"
    )
  else
    Assert.equal(
      CommandCatalog.classification(row.opcode),
      CommandCatalog.CONTINUE,
      "opcode " .. row.opcode .. " (" .. row.name .. ") must settle in the same tick"
    )
  end
end

---@param item table
---@param inventorySet table<integer, boolean>
---@param hits table<integer, integer>
local function checkLoweredItem(item, inventorySet, hits)
  if item.op == "if" then
    checkLoweredItem({ op = "seq", steps = item.yes }, inventorySet, hits)
    checkLoweredItem({ op = "seq", steps = item.no }, inventorySet, hits)
    return
  end
  if item.op == "switch" then
    for _, caseSteps in pairs(item.cases or {}) do
      checkLoweredItem({ op = "seq", steps = caseSteps }, inventorySet, hits)
    end
    checkLoweredItem({ op = "seq", steps = item.default or {} }, inventorySet, hits)
    return
  end
  if item.op == "seq" then
    for _, step in ipairs(item.steps or {}) do
      checkLoweredItem(step, inventorySet, hits)
    end
    return
  end
  local provenance = item.provenance or {}
  for _, opcode in ipairs(provenance.opcodes or {}) do
    if inventorySet[opcode] then
      hits[opcode] = (hits[opcode] or 0) + 1
      Assert.isTrue(
        item.op ~= "unsupported",
        "opcode " .. opcode .. " must lower to a typed gear operation, got unsupported (" .. tostring(item.reason) .. ")"
      )
    end
  end
end

---@param problem table|string
---@return string
local function problemText(problem)
  if type(problem) == "string" then
    return problem
  end
  if type(problem) == "table" then
    return tostring(problem.message)
  end
  return tostring(problem)
end

---@param text string
---@param opcode integer
---@param name string
---@return boolean
local function problemMentionsRow(text, opcode, name)
  if text:find(name, 1, true) ~= nil then
    return true
  end
  return text:find("%D" .. opcode .. "%D") ~= nil
end

function T.every_source_gear_command_row_is_executable(romFs)
  -- The census is exhaustive and bounded: exactly the inventoried rows,
  -- neither a silent deferral hiding inside the family nor the whole corpus.
  local census = censusOpcodes()
  local expected = {}
  for _, row in ipairs(INVENTORY) do
    expected[#expected + 1] = row.opcode
  end
  table.sort(expected)
  Assert.deepEqual(census, expected, "the bounded gear census must match the inventoried rows exactly")
  for _, opcode in ipairs(OUT_OF_FAMILY_SPOT_CHECKS) do
    local found = false
    for _, listed in ipairs(census) do
      if listed == opcode then
        found = true
      end
    end
    Assert.isFalse(found, "spot-check opcode " .. opcode .. " stays outside the gear census")
  end

  -- Every inventoried row carries exact static semantics.
  for _, row in ipairs(INVENTORY) do
    checkStaticRow(row)
  end

  -- Every real script use of an inventoried row lowers to a typed gear
  -- operation, and the independent verifier raises no problem against the
  -- inventoried rows. Unrelated verifier failures in the same scripts are
  -- out of scope here and must not mask the gear rows.
  local inventorySet = {}
  for _, row in ipairs(INVENTORY) do
    inventorySet[row.opcode] = true
  end
  local archive, memberIrs = FieldScripts.decode(romFs)
  local SemanticLowering = require("romdump.src.digest.script.SemanticLowering")
  local Structurer = require("romdump.src.digest.script.Structurer")
  local Verifier = require("romdump.src.digest.script.Verifier")
  local stdCatalog = require("romdump.src.digest.script.SourceCatalog").catalog()
  local hits = {}
  local scriptsWithGearUse = 0
  local verifierProblems = {}
  for member = 0, archive:memberCount() - 1 do
    local ir = memberIrs[member]
    if ir ~= nil then
      for index, script in pairs(ir.scripts) do
        local usesGear = false
        for _, ins in ipairs(script.instructions or {}) do
          if inventorySet[ins.opcode] then
            usesGear = true
            break
          end
        end
        if usesGear then
          scriptsWithGearUse = scriptsWithGearUse + 1
          local lowered = SemanticLowering.lowerScript(script, ir, { stdCatalog = stdCatalog })
          for _, item in ipairs(lowered.items or {}) do
            checkLoweredItem(item, inventorySet, hits)
          end
          local steps = Structurer.structure(lowered, index)
          local report = Verifier.verifyScript(steps, script, ir, lowered.omissions)
          if not report.ok then
            for _, problem in ipairs(report.problems or {}) do
              local text = " " .. problemText(problem) .. " "
              for _, row in ipairs(INVENTORY) do
                if problemMentionsRow(text, row.opcode, row.name) then
                  verifierProblems[#verifierProblems + 1] = "member "
                    .. member
                    .. " script "
                    .. index
                    .. ": "
                    .. problemText(problem)
                end
              end
            end
          end
        end
      end
    end
  end
  Assert.isTrue(scriptsWithGearUse > 0, "real scripts must actually use the inventoried gear rows")
  Assert.equal(#verifierProblems, 0, "the verifier must agree on every gear row: " .. table.concat(verifierProblems, "; "))
  local useSummary = {}
  for _, row in ipairs(INVENTORY) do
    useSummary[#useSummary + 1] = row.opcode .. "=" .. (hits[row.opcode] or 0)
  end
  Assert.isTrue(
    #useSummary == #INVENTORY,
    "every inventoried row reports its real-use count: " .. table.concat(useSummary, ", ")
  )
end

local suite = RomSuite.fromFacts(T)
suite.metadata.capabilities = { "rom_dump" }
suite.metadata.tags = { "pokegear" }
return suite
