-- Deterministic logical-field dependency closure over plain field, script
-- and audio metadata. Every scenario calls the closure directly with
-- caller-owned data: no session, no worker and no cache take part, so a
-- passing suite proves the computation needs none of them.

local Assert = require("tests.support.Assert")
local LogicalFieldPlan = require("romdump.src.build.LogicalFieldPlan")

local T = {}

local MAP_ID = 5311
local MESSAGE_BANK_ID = 219
local SCRIPT_MEMBER_ID = 149

local function audioIndex()
  return {
    sequences = {
      [2] = { id = 2, bankId = 10 },
      [100] = { id = 100, symbol = "SEQ_DAY", bankId = 20 },
      [101] = { id = 101, symbol = "SEQ_NIGHT", bankId = 30 },
      [200] = { id = 200, symbol = "SEQ_SCRIPT_ONLY", bankId = 40 },
    },
    sequenceBySymbol = {
      SEQ_DAY = 100,
      SEQ_NIGHT = 101,
      SEQ_SCRIPT_ONLY = 200,
    },
  }
end

---@param music table<string, unknown>|nil
---@param plates table<string, unknown>[]|nil
---@return table<string, unknown>
local function fieldRecord(music, plates)
  return {
    mapId = MAP_ID,
    messageBankId = MESSAGE_BANK_ID,
    scriptBankId = SCRIPT_MEMBER_ID,
    music = music,
    soundplates = plates,
  }
end

local function divergentMusic()
  return {
    day = "SEQ_DAY",
    night = 2,
    flagOverrides = { { flagId = 9, sequence = "SEQ_NIGHT" } },
    traversalOverrides = { { traversal = "surf", sequence = 2 } },
  }
end

local function divergentPlates()
  return {
    { x = 0, z = 0, xBounds = 1, zBounds = 1, sequence = "SEQ_DAY", useFieldMusicBank = false },
  }
end

---@param members { kind: string, key: string }[]
---@return string[]
local function identities(members)
  local names = {}
  for _, member in ipairs(members) do
    names[#names + 1] = member.kind .. ":" .. member.key
  end
  return names
end

function T.fixed_members_come_first_with_banks_in_canonical_order()
  local members = LogicalFieldPlan.members(MAP_ID, fieldRecord(divergentMusic(), divergentPlates()), {}, audioIndex())
  Assert.deepEqual(identities(members), {
    "map-data:5311",
    "message-bank:219",
    "script-member:149",
    "script-summary:global",
    "audio-catalog:global",
    "audio-bank:10",
    "audio-bank:20",
    "audio-bank:30",
  })
end

function T.convergent_references_collapse_to_one_bank()
  local record = fieldRecord({ day = "SEQ_DAY", night = "SEQ_DAY" }, {
    { x = 0, z = 0, xBounds = 1, zBounds = 1, sequence = "SEQ_DAY", useFieldMusicBank = false },
  })
  local members = LogicalFieldPlan.members(MAP_ID, record, {}, audioIndex())
  Assert.deepEqual(identities(members), {
    "map-data:5311",
    "message-bank:219",
    "script-member:149",
    "script-summary:global",
    "audio-catalog:global",
    "audio-bank:20",
  })
end

function T.script_only_sequences_join_through_shared_resolution()
  local record = fieldRecord({ day = 2 }, nil)
  local members = LogicalFieldPlan.members(MAP_ID, record, { "SEQ_SCRIPT_ONLY" }, audioIndex())
  Assert.deepEqual(identities(members), {
    "map-data:5311",
    "message-bank:219",
    "script-member:149",
    "script-summary:global",
    "audio-catalog:global",
    "audio-bank:10",
    "audio-bank:40",
  })
end

function T.music_without_references_closes_over_no_bank()
  local members = LogicalFieldPlan.members(MAP_ID, fieldRecord(nil, nil), {}, audioIndex())
  Assert.deepEqual(identities(members), {
    "map-data:5311",
    "message-bank:219",
    "script-member:149",
    "script-summary:global",
    "audio-catalog:global",
  })
end

function T.unknown_sequence_symbol_fails_loudly()
  local record = fieldRecord({ day = "SEQ_MISSING" }, nil)
  local ok, err = pcall(LogicalFieldPlan.members, MAP_ID, record, {}, audioIndex())
  Assert.isFalse(ok, "an unknown adopted symbol never closes silently")
  Assert.isTrue(
    tostring(err):find("SEQ_MISSING", 1, true) ~= nil,
    "the failure names its symbol: " .. tostring(err)
  )
  local numeric = fieldRecord({ day = 999 }, nil)
  local numericOk, numericErr = pcall(LogicalFieldPlan.members, MAP_ID, numeric, {}, audioIndex())
  Assert.isFalse(numericOk, "an unknown adopted sequence id never closes silently")
  Assert.isTrue(
    tostring(numericErr):find("999", 1, true) ~= nil,
    "the failure names its sequence: " .. tostring(numericErr)
  )
  local scriptOk, scriptErr = pcall(LogicalFieldPlan.members, MAP_ID, fieldRecord(nil, nil), { "SEQ_MISSING" }, audioIndex())
  Assert.isFalse(scriptOk, "an unknown script sequence never closes silently")
  Assert.isTrue(
    tostring(scriptErr):find("SEQ_MISSING", 1, true) ~= nil,
    "the failure names its script symbol: " .. tostring(scriptErr)
  )
end

function T.missing_bank_ids_fail_loudly()
  local noMessage = fieldRecord(divergentMusic(), divergentPlates())
  noMessage.messageBankId = nil
  local messageOk, messageErr = pcall(LogicalFieldPlan.members, MAP_ID, noMessage, {}, audioIndex())
  Assert.isFalse(messageOk, "a record without a message bank never closes silently")
  Assert.isTrue(
    tostring(messageErr):find("message bank", 1, true) ~= nil,
    "the failure names its bank: " .. tostring(messageErr)
  )
  local noScript = fieldRecord(divergentMusic(), divergentPlates())
  noScript.scriptBankId = nil
  local scriptOk, scriptErr = pcall(LogicalFieldPlan.members, MAP_ID, noScript, {}, audioIndex())
  Assert.isFalse(scriptOk, "a record without a script member never closes silently")
  Assert.isTrue(
    tostring(scriptErr):find("script member", 1, true) ~= nil,
    "the failure names its member: " .. tostring(scriptErr)
  )
end

function T.unresolvable_bank_target_fails_loudly()
  local index = audioIndex()
  index.sequences[2] = { id = 2 }
  local ok, err = pcall(LogicalFieldPlan.members, MAP_ID, fieldRecord({ day = 2 }, nil), {}, index)
  Assert.isFalse(ok, "a sequence without a bank never closes silently")
  Assert.isTrue(
    tostring(err):find("no bank", 1, true) ~= nil,
    "the failure names its missing bank: " .. tostring(err)
  )
end

function T.closure_returns_fresh_lists_without_retained_state()
  local record = fieldRecord(divergentMusic(), divergentPlates())
  local first = LogicalFieldPlan.members(MAP_ID, record, {}, audioIndex())
  local second = LogicalFieldPlan.members(MAP_ID, record, {}, audioIndex())
  Assert.deepEqual(identities(first), identities(second), "repeated calls agree")
  first[#first + 1] = { kind = "audio-bank", key = "999" }
  local third = LogicalFieldPlan.members(MAP_ID, record, {}, audioIndex())
  Assert.deepEqual(identities(third), identities(second), "a caller-mutated result never leaks into later calls")
end

return { metadata = { capabilities = {} }, tests = T }
