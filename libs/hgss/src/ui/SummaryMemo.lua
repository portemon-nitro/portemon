-- Source encounter-memo projection for the summary display. Selects the
-- authored condition branch by ordered first-match over the generated
-- memo rules plus full-identity ownership, then expands the authored
-- line positions with generated display text. Location classes, month
-- and landmark wording, nature wording, characteristic, flavor, and egg
-- watch text all come from the generated family; this module owns only
-- the predicate matching and the segment expansion. The characteristic
-- names the highest individual value with a personality-ordered tie
-- break and remainder; flavor follows the nature relationship; egg
-- watch follows friendship bands. Pure module: no love, no I/O.

local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
local Personality = require("libs.mons.src.gen4.Personality")

---@class SummaryMemo
local SummaryMemo = {}

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

-- Closed rule-predicate vocabulary published by the generated family.
-- Absent predicates constrain nothing; order decides the branch.
local PREDICATES = { isEgg = true, fateful = true, mine = true, eggLocation = true, metLocation = true }

-- Closed egg-location classes published by the generated family. The
-- stored egg location resolves through the generated location sets: an
-- unset location reads "none" for met mons and "egg" for current eggs,
-- exact ranger and second-trade origins read their own class, generated
-- gift-egg origins read the gift class, and any other set location reads
-- the ordinary hatched class.
local EGG_LOCATION_CLASSES =
  { none = true, linkTrade2 = true, ranger = true, hatched = true, giftSet = true, egg = true }

-- Closed met-location classes published by the generated family. Exact
-- park and trade meetings read their own class, everything else reads
-- the ordinary wild class, and "notPalPark" constrains only the negative
-- side for fateful branches.
local MET_LOCATION_CLASSES = { palPark = true, notPalPark = true, linkTrade = true, wild = true }

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

---@param manifest table<string, unknown>
---@return table<string, unknown>
local function memoSection(manifest)
  local section = assert(manifest.memo, "the summary family carries memo records")
  assert(type(section) == "table", "memo records are a record")
  return section
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

---@param locations table<string, unknown>
---@param key string
---@return integer
local function locationId(locations, key)
  local value = assert(locations[key], "memo locations carry " .. key)
  assert(type(value) == "number" and value % 1 == 0, "memo location " .. key .. " is an integer")
  ---@cast value integer
  return value
end

-- Resolves the stored egg location to its generated class. The location
-- sets come from the generated family; only the class names are local.
---@param mon table<string, unknown>
---@param locations table<string, unknown>
---@return string
local function eggLocationClass(mon, locations)
  local egg = assert(mon.egg, "memo records carry their egg record")
  assert(type(egg) == "table", "memo egg records are records")
  local location = assert(egg.location, "memo egg records carry a location")
  assert(type(location) == "number", "memo egg locations are numeric")
  if location == 0 then
    if mon.isEgg == true then
      return "egg"
    end
    return "none"
  end
  if location == locationId(locations, "linkTrade2") then
    return "linkTrade2"
  end
  if location == locationId(locations, "ranger") then
    return "ranger"
  end
  local origins = assert(locations.giftEggOrigins, "memo locations carry gift egg origins")
  assert(type(origins) == "table", "gift egg origins are an array")
  for _, origin in ipairs(origins) do
    if location == origin then
      return "giftSet"
    end
  end
  return "hatched"
end

-- Resolves the stored met location to its generated class: exact park
-- and trade meetings read their own class, everything else reads wild.
---@param mon table<string, unknown>
---@param locations table<string, unknown>
---@return string
local function metLocationClass(mon, locations)
  local met = assert(mon.met, "memo records carry their met record")
  assert(type(met) == "table", "memo met records are records")
  local location = assert(met.location, "memo met records carry a location")
  assert(type(location) == "number", "memo met locations are numeric")
  if location == locationId(locations, "palPark") then
    return "palPark"
  end
  if location == locationId(locations, "linkTrade") then
    return "linkTrade"
  end
  return "wild"
end

-- Validates one generated rule against the closed predicate vocabulary.
-- Unknown predicate keys or location classes are a malformed family,
-- never a skipped rule.
---@param rule table<string, unknown>
---@param position integer
local function checkRule(rule, position)
  local what = "memo rule " .. position
  local key = rule.key
  assert(type(key) == "string" and key ~= "", what .. " names its branch")
  assert(type(rule.selectable) == "boolean", what .. " marks its selectability")
  local match = assert(rule.match, what .. " carries its predicates")
  assert(type(match) == "table", what .. " predicates are a record")
  for name in pairs(match) do
    assert(PREDICATES[name] == true, what .. " carries unknown predicate " .. tostring(name))
  end
  if match.eggLocation ~= nil then
    assert(
      EGG_LOCATION_CLASSES[match.eggLocation] == true,
      what .. " carries unknown egg class " .. tostring(match.eggLocation)
    )
  end
  if match.metLocation ~= nil then
    assert(
      MET_LOCATION_CLASSES[match.metLocation] == true,
      what .. " carries unknown met class " .. tostring(match.metLocation)
    )
  end
  local lines = assert(rule.lines, what .. " carries its line placement")
  assert(type(lines) == "table", what .. " line placement is a record")
  for _, line in ipairs({ "nature", "date", "characteristic", "flavor", "eggWatch" }) do
    local placement = lines[line]
    assert(type(placement) == "number" and placement % 1 == 0 and placement >= 0, what .. " places " .. line)
  end
end

---@param rule table<string, unknown>
---@param mon table<string, unknown>
---@param isMine boolean
---@param eggClass string
---@param metClass string
---@return boolean
local function ruleMatches(rule, mon, isMine, eggClass, metClass)
  local match = assert(rule.match, "memo rules carry predicates")
  assert(type(match) == "table", "memo predicates are a record")
  if match.isEgg ~= nil and match.isEgg ~= (mon.isEgg == true) then
    return false
  end
  if match.fateful ~= nil and match.fateful ~= (mon.fatefulEncounter == true) then
    return false
  end
  if match.mine ~= nil and match.mine ~= isMine then
    return false
  end
  if match.eggLocation ~= nil and match.eggLocation ~= eggClass then
    return false
  end
  if match.metLocation ~= nil then
    if match.metLocation == "notPalPark" then
      if metClass == "palPark" then
        return false
      end
    elseif match.metLocation ~= metClass then
      return false
    end
  end
  return true
end

-- Selects the authored condition branch: ordered first-match over the
-- selectable generated rules. Closure entries never select on their own.
-- No match is a generated-contract mismatch and fails instead of
-- guessing a branch.
---@param mon table<string, unknown>
---@param isMine boolean
---@param locations table<string, unknown>
---@param conditions table[]
---@return table<string, unknown>
local function selectRule(mon, isMine, locations, conditions)
  local eggClass = eggLocationClass(mon, locations)
  local metClass = metLocationClass(mon, locations)
  for position, rule in ipairs(conditions) do
    assert(type(rule) == "table", "memo rules are records")
    checkRule(rule, position)
    if rule.selectable ~= false and ruleMatches(rule, mon, isMine, eggClass, metClass) then
      return rule
    end
  end
  error("the summary family matches no memo rule for this mon", 0)
end

---@param manifest table<string, unknown>
---@param location integer
---@return string
local function landmarkKey(manifest, location)
  local landmarks = assert(memoSection(manifest).landmarks, "memo records carry landmarks")
  assert(type(landmarks) == "table", "memo landmarks are a record")
  local giftByLocation = landmarks.giftByLocation
  if type(giftByLocation) == "table" and type(giftByLocation[location]) == "string" then
    return giftByLocation[location]
  end
  local wildByLocation = landmarks.wildByLocation
  if type(wildByLocation) == "table" and type(wildByLocation[location]) == "string" then
    return wildByLocation[location]
  end
  local fallback = assert(landmarks.fallback, "memo landmarks carry a fallback")
  assert(type(fallback) == "string" and fallback ~= "", "the memo fallback names its text")
  return fallback
end

-- Names the generated month label for a 1..12 month number.
---@param section table<string, unknown>
---@param month integer
---@return string
local function monthKey(section, month)
  assert(type(month) == "number" and month % 1 == 0 and month >= 1 and month <= 12, "memo months stay in 1..12")
  local months = assert(section.months, "memo records carry months")
  assert(type(months) == "table", "memo months are a record")
  local key = months[month]
  assert(type(key) == "string" and key ~= "", "memo months cover month " .. month)
  return key
end

-- The migrated branch shows the arrival region for the mon's origin game
-- instead of a met landmark. The generated family binds each supported
-- game to its region wording; the runtime only looks the origin game up
-- in that map, so a game without generated wording fails here instead
-- of guessing a region.
---@param mon table<string, unknown>
---@param manifest table<string, unknown>
---@return string
local function migrationRegionText(mon, manifest)
  local origin = assert(mon.origin, "stored mons carry their origin")
  assert(type(origin) == "table", "origins are records")
  local game = assert(origin.game, "origins carry their game")
  local regions = assert(memoSection(manifest).migrationRegions, "memo records carry migration regions")
  assert(type(regions) == "table", "migration regions are a record")
  local regionKey = regions[game]
  assert(type(regionKey) == "string" and regionKey ~= "", "the migration map covers origin game " .. tostring(game))
  return labelText(memoLabels(manifest), regionKey, "the migration region for " .. tostring(game))
end

-- Maps one generated color selection to its semantic ink name. The
-- generated text roles publish both the ink names and their slot
-- bindings; a selection resolving to a known ink returns that name,
-- anything else keeps its slot-derived role name. Raw palette indices
-- never reach display facts.
---@param manifest table<string, unknown>
---@param color integer
---@return string
local function inkForColor(manifest, color)
  assert(type(color) == "number" and color % 1 == 0, "memo color selections are integers")
  local text = assert(manifest.text, "the summary family carries lowered text")
  assert(type(text) == "table", "lowered text is a record")
  local roles = assert(text.roles, "the summary family carries text roles")
  assert(type(roles) == "table", "text roles are a record")
  local slotName = "slot" .. color
  local slotRole = roles[slotName]
  if type(slotRole) ~= "table" then
    return slotName
  end
  local function channels(role)
    local parts = {}
    for _, layer in ipairs({ "foreground", "shadow", "background" }) do
      local entry = assert(role[layer], "text roles carry their layers")
      assert(type(entry) == "table", "text role layers are records")
      for _, channel in ipairs({ "r", "g", "b", "a" }) do
        parts[#parts + 1] = tostring(assert(entry[channel], "text role layers carry channels"))
      end
    end
    return table.concat(parts, ",")
  end
  local wanted = channels(slotRole)
  for name, role in pairs(roles) do
    if type(name) == "string" and name:sub(1, 4) ~= "slot" and type(role) == "table" then
      if channels(role) == wanted then
        return name
      end
    end
  end
  return slotName
end

---@param value unknown
---@param what string
---@return integer
local function dateNumber(value, what)
  assert(type(value) == "number" and value % 1 == 0, what .. " is an integer")
  ---@cast value integer
  return value
end

-- Renders a canonical meeting year in the stored-year form used by the
-- encounter memo: the semantic record keeps the full year while the
-- memo text carries the year offset from 2000 with minimum width 2
-- and leading zeros. Offsets past two digits keep their full width.
---@param year unknown
---@return string
local function formatNativeYear(year)
  local canonical = dateNumber(year, "memo years")
  assert(canonical >= 2000 and canonical <= 2255, "memo years stay in 2000..2255")
  return string.format("%02d", canonical - 2000)
end

-- Expands one generated template (a branch date template or a nature
-- template) into one display-ready run list per source line. Literal
-- text transfers verbatim, color selections change the run ink, and
-- every other segment binds a live mon field, a generated
-- month/landmark label, or the migration region. A line break finishes
-- the current source line and opens the next one under the active ink;
-- it never becomes drawable text. Adjacent equal-ink text stays
-- coalesced; unknown segment kinds fail.
---@param mon table<string, unknown>
---@param manifest table<string, unknown>
---@param segments table[]
---@return { text: string, ink: string }[][]
local function expandSegments(mon, manifest, segments)
  local section = memoSection(manifest)
  local labels = memoLabels(manifest)
  local met = assert(mon.met, "memo records carry their met record")
  assert(type(met) == "table", "memo met records are records")
  local metDate = assert(met.date, "memo met records carry a date")
  assert(type(metDate) == "table", "memo met dates are records")
  local metLocation = assert(met.location, "memo met records carry a location")
  assert(type(metLocation) == "number" and metLocation % 1 == 0, "memo met locations are integers")
  ---@cast metLocation integer
  local metLevel = assert(met.level, "memo met records carry a level")
  assert(type(metLevel) == "number", "memo met levels are numeric")
  local egg = assert(mon.egg, "memo records carry their egg record")
  assert(type(egg) == "table", "memo egg records are records")
  -- Stored mons never carry a separate egg date, so hatched and egg
  -- templates read the meeting date for the egg bindings.
  local eggDate = metDate
  if type(egg.date) == "table" then
    eggDate = egg.date
  end
  local eggLocation = assert(egg.location, "memo egg records carry a location")
  assert(type(eggLocation) == "number" and eggLocation % 1 == 0, "memo egg locations are integers")
  ---@cast eggLocation integer
  local lines = {}
  local current = {}
  local pieces = {}
  local ink = "ordinary"
  local function flush()
    if #pieces > 0 then
      current[#current + 1] = { text = table.concat(pieces), ink = ink }
      pieces = {}
    end
  end
  local function push(text)
    assert(type(text) == "string" and text ~= "", "memo substitutions resolve display text")
    pieces[#pieces + 1] = text
  end
  for position, segment in ipairs(segments) do
    assert(type(segment) == "table", "memo segments are records")
    local kind = segment.kind
    if kind == "text" then
      local value = segment.value
      assert(type(value) == "string", "memo text carries its wording")
      push(value)
    elseif kind == "lineBreak" then
      flush()
      lines[#lines + 1] = current
      current = {}
    elseif kind == "color" then
      flush()
      ink = inkForColor(manifest, segment.color)
    elseif kind == "metYear" then
      push(formatNativeYear(metDate.year))
    elseif kind == "metMonth" then
      push(labelText(labels, monthKey(section, metDate.month), "the memo month"))
    elseif kind == "metDay" then
      push(tostring(dateNumber(metDate.day, "memo days")))
    elseif kind == "metLevel" then
      push(tostring(dateNumber(metLevel, "memo levels")))
    elseif kind == "metLocation" then
      push(labelText(labels, landmarkKey(manifest, metLocation), "the memo landmark"))
    elseif kind == "eggYear" then
      push(formatNativeYear(eggDate.year))
    elseif kind == "eggMonth" then
      push(labelText(labels, monthKey(section, eggDate.month), "the memo month"))
    elseif kind == "eggDay" then
      push(tostring(dateNumber(eggDate.day, "memo days")))
    elseif kind == "eggLocation" then
      push(labelText(labels, landmarkKey(manifest, eggLocation), "the memo landmark"))
    elseif kind == "migrationRegion" then
      push(migrationRegionText(mon, manifest))
    else
      error("memo segment " .. position .. " carries unknown kind " .. tostring(kind), 0)
    end
  end
  flush()
  lines[#lines + 1] = current
  local total = 0
  for _, runs in ipairs(lines) do
    total = total + #runs
  end
  assert(total >= 1, "memo templates expand to text")
  return lines
end

-- Resolves one generated wording reference to one display-ready run list
-- per source line. The generated family carries wording as either a
-- plain label or a template with color and break segments; templates
-- expand through the same segment interpreter as date templates, labels
-- transfer as one ordinary run on one source line. A reference carried
-- by neither fails immediately.
---@param manifest table<string, unknown>
---@param mon table<string, unknown>
---@param key string
---@param what string
---@return { text: string, ink: string }[][]
local function textRuns(manifest, mon, key, what)
  local textSection = assert(manifest.text, "the summary family carries lowered text")
  assert(type(textSection) == "table", "lowered text is a record")
  local templates = textSection.templates
  if type(templates) == "table" and type(templates[key]) == "table" then
    local record = templates[key]
    local segments = assert(record.segments, what .. " carries segments")
    assert(type(segments) == "table" and #segments >= 1, what .. " carries segments")
    return expandSegments(mon, manifest, segments)
  end
  return { { { text = labelText(memoLabels(manifest), key, what), ink = "ordinary" } } }
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

-- Adds one template expansion to the public blocks: the first expanded
-- source line keeps the branch base line and later lines follow one per
-- line. Authored empty lines carry no block but still advance the line
-- numbers that follow them.
---@param blocks { line: integer, runs: { text: string, ink: string }[] }[]
---@param base integer branch base source line
---@param lines { text: string, ink: string }[][] one run list per source line
local function addBlocks(blocks, base, lines)
  for offset, runs in ipairs(lines) do
    if #runs >= 1 then
      blocks[#blocks + 1] = { line = base + offset - 1, runs = runs }
    end
  end
end

-- Builds the authored memo value for one copied mon: the selected
-- condition plus ordered line blocks with named text runs. Reads only the
-- copied mon, ownership, context profile identity, and generated records.
---@param mon table<string, unknown> copied mon record
---@param isMine boolean full-identity ownership
---@param context table<string, unknown> explicit display context
---@param manifest table<string, unknown> validated summary family
---@return { condition: string, blocks: { line: integer, runs: { text: string, ink: string }[] }[] }
function SummaryMemo.build(mon, isMine, context, manifest)
  assert(type(mon) == "table", "the memo needs a mon record")
  assert(type(isMine) == "boolean", "the memo needs full-identity ownership")
  assert(type(context) == "table", "the memo needs the display context")
  assert(type(manifest) == "table", "the memo needs the summary family")
  local section = memoSection(manifest)
  local conditions = assert(section.conditions, "memo records carry conditions")
  assert(type(conditions) == "table" and #conditions >= 1, "memo conditions arrive in order")
  local locations = assert(section.locations, "memo records carry locations")
  assert(type(locations) == "table", "memo locations are a record")
  local rule = selectRule(mon, isMine, locations, conditions)
  local condition = assert(rule.key, "memo rules name their branch")
  assert(type(condition) == "string", "memo branch keys are strings")
  local lines = assert(rule.lines, "memo rules carry line placement")
  assert(type(lines) == "table", "memo line placement is a record")
  local blocks = {}

  local nature = nil
  if lines.nature > 0 or lines.flavor > 0 then
    local pid = assert(mon.personality, "memo records carry their personality")
    assert(type(pid) == "number", "personalities are numeric")
    nature = Personality.nature(pid)
  end
  if lines.nature > 0 then
    assert(nature ~= nil, "the nature line needs the nature")
    -- The English name only derives the generated wording key; the
    -- displayed wording always comes from the generated family.
    local natureKey = "nature" .. HgssMonService.natureName(nature)
    addBlocks(blocks, lines.nature, textRuns(manifest, mon, natureKey, "the memo nature"))
  end
  if lines.date > 0 then
    local template = assert(rule.dateTemplate, "memo rules carry their date template")
    assert(type(template) == "table", "memo date templates are records")
    local segments = assert(template.segments, "memo date templates carry segments")
    assert(type(segments) == "table" and #segments >= 1, "memo date templates carry segments")
    addBlocks(blocks, lines.date, expandSegments(mon, manifest, segments))
  end
  if lines.characteristic > 0 then
    local characteristics = assert(section.characteristics, "memo records carry characteristics")
    assert(type(characteristics) == "table", "memo characteristics are a record")
    local position, remainder = characteristicPick(mon)
    local row = assert(characteristics[position], "memo characteristics cover position " .. position)
    assert(type(row) == "table", "characteristic rows are arrays")
    local key = assert(row[remainder + 1], "memo characteristics cover remainder " .. remainder)
    addBlocks(blocks, lines.characteristic, textRuns(manifest, mon, key, "the memo characteristic"))
  end
  if lines.flavor > 0 then
    assert(nature ~= nil, "the flavor line needs the nature")
    local flavors = assert(section.flavors, "memo records carry flavors")
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
    addBlocks(blocks, lines.flavor, textRuns(manifest, mon, key, "the memo flavor"))
  end
  if lines.eggWatch > 0 then
    local eggWatch = assert(section.eggWatch, "memo records carry egg watch")
    assert(type(eggWatch) == "table", "egg watch is a record")
    local templates = assert(eggWatch.templates, "egg watch carries templates")
    assert(type(templates) == "table", "egg-watch templates are an array")
    local index = eggWatchIndex(mon.friendship, eggWatch)
    local key = assert(templates[index], "egg watch covers band " .. index)
    addBlocks(blocks, lines.eggWatch, textRuns(manifest, mon, key, "the egg-watch text"))
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
