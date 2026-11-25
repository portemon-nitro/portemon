-- The specialty-NPC query leaf: the fishing-competition size record, the ribbon
-- identity reads/names, the effort-value total, the Kenya Mail reference checks,
-- the stat judge and the Hidden Power type. Every expected value below comes
-- from the pinned native sources named in the module: the source table and
-- integer arithmetic, the retail ribbon table's own bindings, Mail_Compare, the
-- rotating judge position and the individual-value formulas.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local FieldNpcServices = require("game.hgss/src/field/FieldNpcServices")
local ScriptErrors = require("libs.script.src.errors")

local T = {}

local SIZE_RECORD_VAR = require("libs.assets.src.field.FieldScriptSymbols").variablesByName.VAR_MAGIKARP_SIZE_RECORD

---@param ivs table<string, integer>?
---@param overrides table<string, unknown>?
---@return table
local function mon(ivs, overrides)
  local record = {
    species = "MAGIKARP",
    personality = 0x1234,
    isEgg = false,
    heldItem = "NONE",
    ivs = ivs
      or { hp = 0, attack = 0, defense = 0, speed = 0, specialAttack = 0, specialDefense = 0 },
    evs = { hp = 0, attack = 0, defense = 0, speed = 0, specialAttack = 0, specialDefense = 0 },
    ribbons = { gba = 0, ds1 = 0, ds2 = 0 },
    mail = nil,
  }
  for key, value in pairs(overrides or {}) do
    record[key] = value
  end
  return record
end

---@class NpcHarness
---@field service FieldNpcServices
---@field parties table<string, table[]>
---@field vars table<integer, integer>
---@field texts table<string, string>
---@field mail table<string, unknown> the reference letter the fake trade service authors
---@field draws integer how many reference letters were authored
---@field mailbox table<integer, table>

---@param options table?
---@return NpcHarness
local function harness(options)
  options = options or {}
  -- The fixture accepts either a zero-based party table or a plain array; the
  -- fake owner answers zero-based source slots either way.
  local source = options.party or { [0] = mon() }
  local zeroBased = source[0] ~= nil
  local parties = {}
  for key, value in pairs(source) do
    parties[zeroBased and (tonumber(key) + 1) or tonumber(key)] = value
  end
  local vars = options.vars or {}
  local texts = options.texts or {}
  local draws = 0
  local state = {
    parties = parties,
    vars = vars,
    texts = texts,
    draws = 0,
    mailbox = options.mailbox or {},
  }
  local mons = {
    partyCount = function()
      return #parties
    end,
    partyMon = function(_, slot)
      return parties[slot + 1]
    end,
    catalog = function()
      return {
        speciesKeyByNativeId = function(_, nativeId)
          local byNativeId = options.speciesByNativeId or { [129] = "MAGIKARP" }
          return byNativeId[nativeId]
        end,
      }
    end,
  }
  local reference = options.reference or { type = 0, author = { trainerId = 7 } }
  local npcTrade = {
    createKenyaMail = function()
      state.draws = state.draws + 1
      return reference
    end,
    mailMatches = function(_, left, right)
      if options.match == nil then
        return left == right
      end
      return options.match(left, right)
    end,
  }
  local mailbox = {
    count = function()
      return #state.mailbox
    end,
    get = function(_, slot)
      return state.mailbox[slot + 1]
    end,
  }
  state.service = FieldNpcServices.new({
    mons = mons,
    npcTrade = npcTrade,
    mailbox = mailbox,
    world = {
      getVar = function(_, id)
        return vars[id] or 0
      end,
      setVar = function(_, id, value)
        vars[id] = value
      end,
    },
    dexHeight = function(species)
      return (options.heights or { MAGIKARP = 9 })[species]
    end,
    resolveText = function(bankId, messageId)
      return assert(texts[bankId .. ":" .. tostring(messageId)], "the fixture resolves " .. bankId .. ":" .. messageId)
    end,
    isMailItem = function(itemKey)
      return itemKey:find("MAIL", 1, true) ~= nil
    end,
    ribbonEntries = function()
      return assert(options.ribbons, "the fixture carries its ribbon table")
    end,
    ribbonNameFor = function(entry)
      return "Ribbon " .. tostring(entry.key)
    end,
  })
  return state
end

local IV_KEYS = { "hp", "attack", "defense", "speed", "specialAttack", "specialDefense" }

---@param values integer[]
---@return table<string, integer>
local function ivs(values)
  local record = {}
  for index, key in ipairs(IV_KEYS) do
    record[key] = values[index] or 0
  end
  return record
end

local function faultCode(fn)
  local ok, err = pcall(fn)
  Assert.isFalse(ok, "the query must not succeed")
  Assert.isTrue(Errors.is(err), "the failure is attributed: " .. tostring(err))
  ---@cast err Errors.Error
  return err.code
end

-- GetMonSizeHash/GetMonSize/LengthConvertToImperial: an all-zero individual
-- spread hashes to the personality's high byte and sizes from the dex height.
function T.the_size_record_uses_the_source_hash_and_size_table()
  local state = harness({
    party = { mon(ivs({ 0, 0, 0, 0, 0, 0 }), { personality = 0 }) },
    vars = { [SIZE_RECORD_VAR] = 65535 },
  })
  -- hash 0 selects the first size-table row, so a 9dm Magikarp reads 9 * 290 / 10
  -- and cannot beat the largest record.
  Assert.equal(state.service:sizeCompare(0), "smaller", "a fresh mon is shorter than the largest record")
  Assert.equal(state.vars[SIZE_RECORD_VAR], 65535, "a comparison never writes the record")
  state.service:sizeRecordUpdate(0)
  Assert.equal(state.vars[SIZE_RECORD_VAR], 0, "the update stores the mon's own hash")
  Assert.equal(state.service:sizeCompare(0), "equal", "the saved record now matches the mon")
end

-- The seen table: a higher hash selects a larger multiplier and a larger size.
function T.a_bigger_hash_reports_a_larger_mon()
  local party = { mon(ivs({ 0, 0, 0, 0, 0, 0 }), { personality = 0 }) }
  local state = harness({ party = party, vars = { [SIZE_RECORD_VAR] = 65535 } })
  Assert.equal(state.service:sizeCompare(0), "smaller", "the largest record beats a fresh mon")
  state.service:sizeRecordUpdate(0)
  Assert.equal(state.service:sizeCompare(0), "equal", "the saved record now matches its own mon")
  state.parties[1] = mon(ivs({ 15, 15, 15, 15, 15, 15 }), { personality = 0xFFFF })
  Assert.equal(state.service:sizeCompare(0), "larger", "a full individual spread beats the empty record")
end

-- FormatSizeRecord buffers a left-aligned three-cell whole count and one tenth.
-- GetMonSizeHash mixes the personality bytes with the low individual-value
-- nibbles, so the fixture's default personality selects the 800-multiplier row
-- and a 9dm Magikarp reads 30 inches and three tenths.
function T.the_size_buffers_carry_the_whole_inch_and_the_tenth()
  local state = harness()
  local own = state.service:monSizeText(0)
  Assert.equal(own.whole, "30 ", "the whole count fills its three left-aligned source cells")
  Assert.equal(own.fraction, "3", "the tenth rides its one source cell")

  -- The record buffer formats the saved record's own hash: zero selects the
  -- first table row, which reads ten inches and three tenths.
  state.vars[SIZE_RECORD_VAR] = 0
  local record = state.service:recordSizeText(129)
  Assert.equal(record.whole, "10 ", "the record buffer formats the saved record")
  Assert.equal(record.fraction, "3", "the record tenth is a single source cell")
  Assert.equal(
    faultCode(function()
      state.service:recordSizeText("MAGIKARP")
    end),
    ScriptErrors.SCRIPT_INVALID_REFERENCE,
    "a non-numeric species identity faults"
  )
end

-- MonHasRibbon/BufferRibbonName read the retail ribbon table's own binding.
function T.ribbon_queries_read_the_source_binding()
  local ribbons = {
    { key = "champion_ribbon", bitGroup = "gba", bit = 20, name = "ribbon-name-0" },
    { key = "cool_ribbon", bitGroup = "gba", bit = 0, name = "ribbon-name-1" },
  }
  local party = {
    [0] = mon(ivs({ 0, 0, 0, 0, 0, 0 }), { ribbons = { gba = 2 ^ 0, ds1 = 0, ds2 = 0 } }),
  }
  local state = harness({ party = party, ribbons = ribbons })
  Assert.isTrue(state.service:monHasRibbon(0, 1), "the stored cool-ribbon bit answers true")
  Assert.isFalse(state.service:monHasRibbon(0, 0), "an unset ribbon answers false")
  Assert.equal(state.service:ribbonName(0), "Ribbon champion_ribbon", "the name resolves display text")
  Assert.equal(
    faultCode(function()
      state.service:monHasRibbon(0, 99)
    end),
    ScriptErrors.SCRIPT_INVALID_REFERENCE,
    "an unknown source ribbon identity faults"
  )
end

-- GetEVTotal sums the six effort values.
function T.the_effort_value_total_sums_every_stat()
  local party = {
    [0] = mon(ivs({ 0, 0, 0, 0, 0, 0 }), {
      evs = { hp = 100, attack = 50, defense = 25, speed = 12, specialAttack = 8, specialDefense = 5 },
    }),
  }
  local state = harness({ party = party })
  Assert.equal(state.service:evTotal(0), 200, "the six effort values sum once")
end

-- ScrCmd_KenyaCheck: no Mail answers false without authoring the reference
-- letter; a zero selector answers true for any Mail; the exact check authors
-- the letter once (its two source draws).
function T.kenya_checks_borrow_the_reference_letter_and_its_draws()
  local letter = { type = 0 }
  local party = { mon(ivs({ 0, 0, 0, 0, 0, 0 }), { heldItem = "NONE" }) }
  local state = harness({ party = party, reference = letter })
  Assert.isFalse(state.service:kenyaCheck(0, false), "a mon holding no Mail answers false")
  Assert.isFalse(state.service:kenyaCheck(0, true), "the exact check also answers false")
  Assert.equal(state.draws, 0, "no reference letter is authored for a mon holding no Mail")

  party[1].heldItem = "GRASS_MAIL"
  Assert.isTrue(state.service:kenyaCheck(0, false), "a Mail holder answers true without the comparison")
  Assert.equal(state.draws, 0, "the zero selector stops before the reference letter")

  party[1].mail = letter
  Assert.isTrue(state.service:kenyaCheck(0, true), "the exact check compares the held letter")
  Assert.equal(state.draws, 1, "the exact check authors the reference letter once")
end

-- ScrCmd_KenyaCheckPartyOrMailbox: one reference letter answers both scans.
function T.the_party_or_mailbox_check_scans_both_owners_once()
  local letter = { type = 0 }
  local party = {
    [0] = mon(ivs({ 0, 0, 0, 0, 0, 0 }), { heldItem = "GRASS_MAIL", mail = { type = 1 } }),
  }
  local state = harness({ party = party, reference = letter, mailbox = { { mail = letter } } })
  Assert.equal(#state.parties, 1, "the fixture normalizes its party copy")
  Assert.isTrue(state.service:kenyaCheckPartyOrMailbox(), "the mailbox letter matches the reference")
  Assert.equal(state.draws, 1, "the scan authors exactly one reference letter")

  state.mailbox[1] = { mail = { type = 2 } }
  Assert.isFalse(state.service:kenyaCheckPartyOrMailbox(), "neither owner holds the reference letter")
  Assert.equal(state.draws, 2, "each scan authors its own reference letter")

  state.parties[1].mail = letter
  Assert.isTrue(state.service:kenyaCheckPartyOrMailbox(), "a party letter matches the reference")
end

-- ScrCmd_StatJudge: the total, the highest individual value and the best-stat
-- message, with the source's rotating tie-break.
function T.the_stat_judge_rotates_through_tied_best_stats()
  local party = { mon(ivs({ 31, 31, 0, 0, 0, 0 })) }
  local state = harness({ party = party, texts = { ["96:122"] = "The best potential lies in its HP." } })
  local first = state.service:statJudge(0)
  Assert.equal(first.total, 62, "the judge totals the individual values")
  Assert.equal(first.highest, 31, "the judge reports the highest individual value")
  Assert.equal(first.messageId, 122, "the first tie reports the HP row")
  local second = state.service:statJudge(0)
  Assert.equal(second.messageId, 123, "the next tie reports the Attack row")
  local third = state.service:statJudge(0)
  Assert.equal(third.messageId, 122, "the rotation wraps back to the first tied stat")
  Assert.equal(
    state.service:statJudgeMessageText(122),
    "The best potential lies in its HP.",
    "the judge's message row resolves through bank 96"
  )
end

-- The judge's message ids follow the source table's stat order.
function T.the_stat_judge_maps_every_stat_to_its_source_message()
  local expected = { [1] = 122, [2] = 123, [3] = 124, [4] = 127, [5] = 125, [6] = 126 }
  for stat = 1, 6 do
    local values = { 0, 0, 0, 0, 0, 0 }
    values[stat] = 31
    local state = harness({ party = { mon(ivs(values)) } })
    Assert.equal(state.service:statJudge(0).messageId, expected[stat], "stat " .. stat .. " names its own row")
  end
end

-- ScrCmd_GetHiddenPowerType: the individual-value low bits pick the native type
-- past mystery, and the refused species report the -1 sentinel.
function T.hidden_power_reports_the_derived_type_and_the_refusal_sentinel()
  local allOnes = harness({ party = { mon(ivs({ 31, 31, 31, 31, 31, 31 }), { species = "PIKACHU" }) } })
  -- 63 * 15 / 63 + 1 = 16, and sixteen skips the unused mystery slot.
  Assert.equal(allOnes.service:hiddenPowerType(0), 17, "every low bit set reports the last native type")
  local allZero = harness({ party = { mon(ivs({ 0, 0, 0, 0, 0, 0 }), { species = "PIKACHU" }) } })
  Assert.equal(allZero.service:hiddenPowerType(0), 1, "no low bits report the first native type")
  local one = harness({ party = { mon(ivs({ 1, 0, 0, 0, 0, 0 }), { species = "PIKACHU" }) } })
  Assert.equal(one.service:hiddenPowerType(0), 1, "one low bit still reports the first type")
  local fighting = harness({ party = { mon(ivs({ 1, 1, 0, 0, 0, 0 }), { species = "PIKACHU" }) } })
  Assert.equal(fighting.service:hiddenPowerType(0), 1, "two low bits stay below the second type step")

  local refused = harness({ party = { mon(ivs({ 31, 31, 31, 31, 31, 31 }), { species = "MAGIKARP" }) } })
  Assert.equal(refused.service:hiddenPowerType(0), -1, "a refused species reports the source sentinel")
  local egg = harness({ party = { mon(ivs({ 0, 0, 0, 0, 0, 0 }), { species = "MAGIKARP", isEgg = true }) } })
  Assert.equal(egg.service:hiddenPowerType(0), 1, "an egg skips the species refusal")
end

-- A missing party slot and an unoccupied owner fault instead of answering.
function T.a_missing_slot_or_owner_faults()
  local state = harness({ party = {} })
  Assert.equal(
    faultCode(function()
      state.service:evTotal(0)
    end),
    require("libs.mons.src.errors").RECORD_INVALID,
    "an empty party slot faults with the mon owner's code"
  )
  local noTrade = harness({ party = { mon(ivs({ 0, 0, 0, 0, 0, 0 }), { heldItem = "GRASS_MAIL" }) } })
  noTrade.service._npcTrade = nil
  Assert.equal(
    faultCode(function()
      noTrade.service:kenyaCheck(0, true)
    end),
    ScriptErrors.SCRIPT_SERVICE_MISSING,
    "the exact Kenya check needs the NPC trade service"
  )
end

return { tests = T }
