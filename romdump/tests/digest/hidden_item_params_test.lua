-- Synthetic checks for the indexed record semantics in the retail decomp's
-- script_manager.c::GetHiddenItemParams and hidden_items.h.

local Assert = require("tests.support.Assert")

local T = {}

local function u16(value)
  return string.char(value % 256, math.floor(value / 256) % 256)
end

local function row(itemId, quantity, unknownByte, unknownWord, index)
  return u16(itemId) .. string.char(quantity, unknownByte) .. u16(unknownWord) .. u16(index)
end

local function tableBytes()
  local rows = {
    row(17, 1, 0, 0, 0),
    row(92, 1, 0, 0, 1),
    row(92, 1, 0, 0, 225),
  }
  for index = 2, 230 do
    if index ~= 225 then
      rows[#rows + 1] = row(index == 230 and 53 or index + 1, 1, 0, 0, index)
    end
  end
  return table.concat(rows)
end

local function source(bytes)
  return {
    version = function()
      return "heartgold"
    end,
    readArm9 = function()
      return bytes
    end,
  }
end

function T.decodes_all_rows_by_their_explicit_index()
  local HiddenItemParams = require("romdump.src.digest.field.HiddenItemParams")
  local byIndex = assert(HiddenItemParams.load(source("prefix" .. tableBytes() .. "suffix")))
  local count = 0
  for _ in pairs(byIndex) do
    count = count + 1
  end
  Assert.equal(count, 231)
  Assert.deepEqual(byIndex[0], { itemId = 17, quantity = 1 })
  Assert.deepEqual(byIndex[1], { itemId = 92, quantity = 1 })
  Assert.deepEqual(byIndex[225], { itemId = 92, quantity = 1 })
  Assert.deepEqual(byIndex[230], { itemId = 53, quantity = 1 })
end

function T.rejects_missing_ambiguous_truncated_and_corrupt_tables()
  local HiddenItemParams = require("romdump.src.digest.field.HiddenItemParams")
  local bytes = tableBytes()
  local _, missing = HiddenItemParams.load(source("not the source table"))
  Assert.equal(assert(missing).code, "HIDDEN_ITEM_TABLE_NOT_FOUND")

  local _, ambiguous = HiddenItemParams.load(source(bytes .. bytes))
  Assert.equal(assert(ambiguous).code, "HIDDEN_ITEM_TABLE_AMBIGUOUS")

  local _, truncated = HiddenItemParams.load(source(bytes:sub(1, 100)))
  Assert.equal(assert(truncated).code, "HIDDEN_ITEM_TABLE_INVALID")

  local corruptions = {
    bytes:sub(1, 26) .. string.char(0) .. bytes:sub(28), -- zero quantity
    bytes:sub(1, 27) .. string.char(1) .. bytes:sub(29), -- unknown byte
    bytes:sub(1, 30) .. u16(225) .. bytes:sub(33), -- duplicate source index
  }
  for _, corrupt in ipairs(corruptions) do
    local _, invalid = HiddenItemParams.load(source(corrupt))
    Assert.equal(assert(invalid).code, "HIDDEN_ITEM_TABLE_INVALID")
  end
end

return { tests = T }
