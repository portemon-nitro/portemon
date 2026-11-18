-- Retail phone greeting entries: bank 640 message numbers from the
-- source sGreetingMsgIDs table. Each row of 12 splits into an outgoing
-- group of six and an incoming group of six; each group of six splits
-- into morning, day, and night pairs, each pair into player-gender
-- entries (male, female). Rows index the contact greeting set.

---@class PhoneGreetingSets
local PhoneGreetingSets = {}

PhoneGreetingSets.ROWS = {
  { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 },
  { 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23 },
  { 72, 72, 73, 73, 74, 74, 72, 72, 73, 73, 74, 74 },
  { 75, 75, 76, 76, 77, 77, 75, 75, 76, 76, 77, 77 },
  { 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35 },
  { 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47 },
  { 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59 },
  { 60, 61, 62, 63, 64, 65, 66, 67, 68, 69, 70, 71 },
}

-- Resolves one greeting entry: timeOfDay 0 selects the morning pair, 1
-- the day pair, 2 the night pair; gender 0 selects the male entry, 1
-- the female entry.
---@param set integer greeting set 0..7
---@param timeOfDay integer 0 morning, 1 day, 2 night
---@param isIncoming boolean
---@param gender integer 0 male, 1 female
---@return integer bank 640 entry number
function PhoneGreetingSets.entry(set, timeOfDay, isIncoming, gender)
  assert(
    type(set) == "number" and set % 1 == 0 and set >= 0 and set < #PhoneGreetingSets.ROWS,
    "greetings name their set"
  )
  assert(timeOfDay == 0 or timeOfDay == 1 or timeOfDay == 2, "greetings read the call time band")
  assert(gender == 0 or gender == 1, "greetings read the player gender")
  local row = PhoneGreetingSets.ROWS[set + 1]
  local index = (isIncoming and 6 or 0) + timeOfDay * 2 + gender
  return row[index + 1]
end

-- Parses one staged word reference behind WORD side effects: the
-- producer records the bank entry as a msg_BANK_ENTRY identity and the
-- runtime adds the drawn pick to the entry number.
---@param ref string staged word bank reference, e.g. msg_0680_00023
---@param pick integer drawn pick
---@return integer bank id
---@return integer entry number
function PhoneGreetingSets.wordEntry(ref, pick)
  assert(type(ref) == "string", "word picks carry their bank reference")
  assert(type(pick) == "number" and pick % 1 == 0 and pick >= 0, "word picks draw their entry offset")
  local bank, entry = ref:match("^msg_(%d+)_(%d+)$")
  assert(bank ~= nil and entry ~= nil, "word picks reference bank entries")
  local bankId = tonumber(bank) --[[@as integer]]
  local entryBase = tonumber(entry) --[[@as integer]]
  return bankId, entryBase + pick
end

return PhoneGreetingSets
