-- Source encounter-memo projection for the summary display. Selects the
-- authored condition branch from origin, met, egg, and fateful values plus
-- full-identity ownership, then emits the authored line positions with
-- named display text. The characteristic names the highest individual
-- value with a personality-ordered tie break and remainder; flavor follows
-- the nature relationship; egg watch follows friendship bands. Pure
-- module: no love, no I/O.

local Personality = require("libs.mons.src.gen4.Personality")

---@class SummaryMemo
local SummaryMemo = {}

-- Nature display names in native 0..24 order.
local NATURE_NAMES = {
  "Hardy",
  "Lonely",
  "Brave",
  "Adamant",
  "Naughty",
  "Bold",
  "Docile",
  "Relaxed",
  "Impish",
  "Lax",
  "Timid",
  "Hasty",
  "Serious",
  "Jolly",
  "Naive",
  "Modest",
  "Mild",
  "Quiet",
  "Bashful",
  "Rash",
  "Calm",
  "Gentle",
  "Sassy",
  "Careful",
  "Quirky",
}

-- Nature stat shifts in battle-stat order attack, defense, speed, special
-- attack, special defense: +1 raises the stat to 110%, -1 lowers it to 90%.
local NATURE_SHIFTS = {
  { 0, 0, 0, 0, 0 },
  { 1, -1, 0, 0, 0 },
  { 1, 0, -1, 0, 0 },
  { 1, 0, 0, -1, 0 },
  { 1, 0, 0, 0, -1 },
  { -1, 1, 0, 0, 0 },
  { 0, 0, 0, 0, 0 },
  { 0, 1, -1, 0, 0 },
  { 0, 1, 0, -1, 0 },
  { 0, 1, 0, 0, -1 },
  { -1, 0, 1, 0, 0 },
  { 0, -1, 1, 0, 0 },
  { 0, 0, 0, 0, 0 },
  { 0, 0, 1, -1, 0 },
  { 0, 0, 1, 0, -1 },
  { -1, 0, 0, 1, 0 },
  { 0, -1, 0, 1, 0 },
  { 0, 0, -1, 1, 0 },
  { 0, 0, 0, 0, 0 },
  { 0, 0, 0, 1, -1 },
  { -1, 0, 0, 0, 1 },
  { 0, -1, 0, 0, 1 },
  { 0, 0, -1, 0, 1 },
  { 0, 0, 0, -1, 1 },
  { 0, 0, 0, 0, 0 },
}

local SHIFT_KEYS = { "attack", "defense", "speed", "specialAttack", "specialDefense" }

local IV_ORDER = { "hp", "attack", "defense", "speed", "specialAttack", "specialDefense" }

-- Raised stat to position in the generated flavor list.
local FLAVOR_BY_STAT = {
  attack = 1,
  specialAttack = 2,
  speed = 3,
  specialDefense = 4,
  defense = 5,
}

local GIFT_LOCATION_LO = 4000
local GIFT_LOCATION_HI = 4099

-- Names the raised and lowered battle stats for a native 0..24 nature;
-- either side is "none" when the nature is neutral on that side.
---@param nature integer
---@return string, string
function SummaryMemo.natureShift(nature)
  assert(
    type(nature) == "number" and nature % 1 == 0 and nature >= 0 and nature <= 24,
    "nature shift requires an integer in 0..24"
  )
  local row = NATURE_SHIFTS[nature + 1]
  local up = "none"
  local down = "none"
  for index, key in ipairs(SHIFT_KEYS) do
    if row[index] == 1 then
      up = key
    elseif row[index] == -1 then
      down = key
    end
  end
  return up, down
end

---@param location unknown
---@return boolean
local function isGiftLocation(location)
  return type(location) == "number" and location >= GIFT_LOCATION_LO and location <= GIFT_LOCATION_HI
end

-- Selects the authored condition branch. Eggs read the egg branch, the
-- fateful flag reads its branch, the pal-park location reads migration, a
-- level-one meeting reads hatching, gift locations read the gift branch,
-- and everything else reads the ordinary wild branch. Every branch but
-- migration distinguishes ownership through its traded variant.
---@param mon table<string, unknown>
---@param isMine boolean
---@return string
local function selectCondition(mon, isMine)
  if mon.isEgg == true then
    if isMine then
      return "egg"
    end
    return "eggTraded"
  end
  if mon.fatefulEncounter == true then
    if isMine then
      return "fatefulEncounter"
    end
    return "fatefulEncounterTraded"
  end
  local met = assert(mon.met, "memo records carry their met record")
  assert(type(met) == "table", "memo met records are records")
  local location = assert(met.location, "memo met records carry a location")
  assert(type(location) == "number", "memo met locations are numeric")
  if location == 0 then
    return "migrated"
  end
  local metLevel = assert(met.level, "memo met records carry a level")
  assert(type(metLevel) == "number", "memo met levels are numeric")
  if metLevel == 1 then
    if isGiftLocation(location) and isMine then
      return "eggHatchedGift"
    end
    if isMine then
      return "eggHatched"
    end
    return "eggHatchedTraded"
  end
  if isGiftLocation(location) then
    if isMine then
      return "wildGift"
    end
    return "wildGiftTraded"
  end
  if isMine then
    return "wildEncounter"
  end
  return "wildEncounterTraded"
end

---@param manifest table<string, unknown>
---@return table<string, string>
local function memoLabels(manifest)
  local text = assert(manifest.text, "the summary family carries lowered text")
  assert(type(text) == "table", "lowered text is a record")
  local labels = assert(text.labels, "the summary family carries text labels")
  assert(type(labels) == "table", "text labels are a record")
  return labels --[[@as table<string, string>]]
end

---@param labels table<string, string>
---@param key string
---@param what string
---@return string
local function labelText(labels, key, what)
  local text = labels[key]
  assert(type(text) == "string" and text ~= "", what .. " resolves its display text")
  return text
end

---@param manifest table<string, unknown>
---@param location integer
---@return string
local function landmarkKey(manifest, location)
  local memoSection = assert(manifest.memo, "the summary family carries memo records")
  assert(type(memoSection) == "table", "memo records are a record")
  local landmarks = assert(memoSection.landmarks, "memo records carry landmarks")
  assert(type(landmarks) == "table", "memo landmarks are a record")
  if location == 0 then
    return assert(landmarks.fallback, "memo landmarks carry a fallback")
  end
  if isGiftLocation(location) then
    local giftByLocation = assert(landmarks.giftByLocation, "memo landmarks carry gift locations")
    assert(type(giftByLocation) == "table", "gift locations are a record")
    if type(giftByLocation[location]) == "string" then
      return giftByLocation[location]
    end
    return assert(landmarks.fallback, "memo landmarks carry a fallback")
  end
  local wildByLocation = assert(landmarks.wildByLocation, "memo landmarks carry wild locations")
  assert(type(wildByLocation) == "table", "wild locations are a record")
  if type(wildByLocation[location]) == "string" then
    return wildByLocation[location]
  end
  return assert(landmarks.fallback, "memo landmarks carry a fallback")
end

-- Names the characteristic individual-value position: the highest value
-- wins, ties break in personality order from personality mod six, and the
-- remainder selects within the winning position.
---@param mon table<string, unknown>
---@return integer, integer
local function characteristicPick(mon)
  local ivs = assert(mon.ivs, "memo records carry individual values")
  assert(type(ivs) == "table", "individual values are a record")
  local pid = assert(mon.personality, "memo records carry their personality")
  assert(type(pid) == "number", "personalities are numeric")
  local start = pid % 6
  local best = nil
  local bestValue = nil
  for offset = 0, 5 do
    local index = (start + offset) % 6 + 1
    local value = ivs[IV_ORDER[index]]
    assert(type(value) == "number" and value % 1 == 0 and value >= 0 and value <= 31, "individual values stay in 0..31")
    ---@cast value integer
    if bestValue == nil or value > bestValue then
      best = index
      bestValue = value
    end
  end
  assert(best ~= nil and bestValue ~= nil, "characteristic selection names one position")
  return best, bestValue % 5
end

---@param friendship unknown
---@param eggWatch table<string, unknown>
---@return integer
local function eggWatchIndex(friendship, eggWatch)
  assert(
    type(friendship) == "number" and friendship % 1 == 0 and friendship >= 0 and friendship <= 255,
    "egg watch reads the friendship byte"
  )
  local thresholds = assert(eggWatch.thresholds, "egg watch carries thresholds")
  assert(type(thresholds) == "table", "egg-watch thresholds are an array")
  local templates = assert(eggWatch.templates, "egg watch carries templates")
  assert(type(templates) == "table", "egg-watch templates are an array")
  for index, limit in ipairs(thresholds) do
    assert(type(limit) == "number", "egg-watch thresholds are numeric")
    if friendship <= limit then
      return index
    end
  end
  return #thresholds + 1
end

-- Builds the authored memo value for one copied mon: the selected
-- condition plus ordered line blocks with named text runs. Reads only the
-- copied mon, ownership, context profile identity, and generated records.
---@param mon table<string, unknown> copied mon record
---@param isMine boolean full-identity ownership
---@param context table<string, unknown> explicit display context
---@param manifest table<string, unknown> validated summary family
---@return { condition: string, blocks: { line: integer, runs: { text: string }[] }[] }
function SummaryMemo.build(mon, isMine, context, manifest)
  assert(type(mon) == "table", "the memo needs a mon record")
  assert(type(isMine) == "boolean", "the memo needs full-identity ownership")
  assert(type(context) == "table", "the memo needs the display context")
  assert(type(manifest) == "table", "the memo needs the summary family")
  local memoSection = assert(manifest.memo, "the summary family carries memo records")
  assert(type(memoSection) == "table", "memo records are a record")
  local conditions = assert(memoSection.conditions, "memo records carry conditions")
  assert(type(conditions) == "table", "memo conditions are a record")
  local condition = selectCondition(mon, isMine)
  local rule = conditions[condition]
  assert(type(rule) == "table", "the summary family covers memo condition " .. condition)
  local labels = memoLabels(manifest)
  local templateText = labelText(labels, assert(rule.template, "memo rules carry a template"), "the memo template")
  local blocks = {}

  local nature = nil
  if rule.nature > 0 or rule.flavor > 0 then
    local pid = assert(mon.personality, "memo records carry their personality")
    assert(type(pid) == "number", "personalities are numeric")
    nature = Personality.nature(pid)
  end
  if rule.nature > 0 then
    assert(nature ~= nil, "the nature line needs the nature")
    blocks[#blocks + 1] = {
      line = rule.nature,
      runs = { { text = templateText .. " " .. NATURE_NAMES[nature + 1] } },
    }
  end
  if rule.date > 0 then
    local met = assert(mon.met, "memo records carry their met record")
    assert(type(met) == "table", "memo met records are records")
    local location = assert(met.location, "memo met records carry a location")
    assert(type(location) == "number" and location % 1 == 0, "memo met locations are integers")
    ---@cast location integer
    local date = assert(met.date, "memo met records carry a date")
    assert(type(date) == "table", "memo met dates are records")
    assert(
      type(date.month) == "number" and date.month % 1 == 0 and date.month >= 1 and date.month <= 12,
      "memo months stay in 1..12"
    )
    assert(
      type(date.day) == "number" and date.day % 1 == 0 and date.day >= 1 and date.day <= 31,
      "memo days stay in 1..31"
    )
    local months = assert(memoSection.months, "memo records carry months")
    assert(type(months) == "table", "memo months are a record")
    local monthKey = assert(months[date.month], "memo months cover month " .. date.month)
    local text = labelText(labels, landmarkKey(manifest, location), "the memo landmark")
      .. " "
      .. labelText(labels, monthKey, "the memo month")
      .. " "
      .. tostring(date.day)
    blocks[#blocks + 1] = { line = rule.date, runs = { { text = text } } }
  end
  if rule.characteristic > 0 then
    local characteristics = assert(memoSection.characteristics, "memo records carry characteristics")
    assert(type(characteristics) == "table", "memo characteristics are a record")
    local position, remainder = characteristicPick(mon)
    local row = assert(characteristics[position], "memo characteristics cover position " .. position)
    assert(type(row) == "table", "characteristic rows are arrays")
    local key = assert(row[remainder + 1], "memo characteristics cover remainder " .. remainder)
    blocks[#blocks + 1] =
      { line = rule.characteristic, runs = { { text = labelText(labels, key, "the memo characteristic") } } }
  end
  if rule.flavor > 0 then
    assert(nature ~= nil, "the flavor line needs the nature")
    local flavors = assert(memoSection.flavors, "memo records carry flavors")
    assert(type(flavors) == "table", "memo flavors are a record")
    local up, _ = SummaryMemo.natureShift(nature)
    local key = nil
    if up == "none" then
      key = assert(flavors.default, "memo flavors carry a default")
    else
      local byFlavor = assert(flavors.byFlavor, "memo flavors carry the flavor list")
      assert(type(byFlavor) == "table", "the flavor list is an array")
      local index = assert(FLAVOR_BY_STAT[up], "flavors cover raised stat " .. up)
      key = assert(byFlavor[index], "memo flavors cover flavor " .. index)
    end
    blocks[#blocks + 1] = { line = rule.flavor, runs = { { text = labelText(labels, key, "the memo flavor") } } }
  end
  if rule.eggWatch > 0 then
    local eggWatch = assert(memoSection.eggWatch, "memo records carry egg watch")
    assert(type(eggWatch) == "table", "egg watch is a record")
    local templates = assert(eggWatch.templates, "egg watch carries templates")
    assert(type(templates) == "table", "egg-watch templates are an array")
    local index = eggWatchIndex(mon.friendship, eggWatch)
    local key = assert(templates[index], "egg watch covers band " .. index)
    local text = labelText(labels, key, "the egg-watch text")
    if rule.nature == 0 then
      text = templateText .. " " .. text
    end
    blocks[#blocks + 1] = { line = rule.eggWatch, runs = { { text = text } } }
  end

  table.sort(blocks, function(a, b)
    return a.line < b.line
  end)
  for _, block in ipairs(blocks) do
    assert(
      type(block.line) == "number" and block.line % 1 == 0 and block.line >= 1,
      "memo blocks keep positive source lines"
    )
    assert(type(block.runs) == "table" and #block.runs >= 1, "memo blocks carry text runs")
  end
  return { condition = condition, blocks = blocks }
end

return SummaryMemo
