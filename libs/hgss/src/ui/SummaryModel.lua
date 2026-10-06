-- The summary-screen value projection: one fresh immutable facts record
-- per build over the live mon service. Every displayed value is read
-- from the current mon record, the service derivation, the explicit
-- display context, or the generated summary family; the projection
-- copies nothing it cannot name and mutates nothing it borrows. Shiny
-- leaves stay a six-bit observation: bits 0..4 select five independent
-- badges, bit 5 selects the crown and suppresses every leaf. Pure module:
-- no love, no I/O.

local Experience = require("libs.mons.src.gen4.Experience")
local Mon = require("libs.mons.src.Mon")
local MonCache = require("libs.assets.src.MonCache")
local PartyScreenTheme = require("libs.hgss.src.ui.PartyScreenTheme")
local Personality = require("libs.mons.src.gen4.Personality")
local Stats = require("libs.mons.src.gen4.Stats")
local SummaryAssetSchema = require("libs.assets.src.SummaryAssetSchema")
local SummaryMemo = require("libs.hgss.src.ui.SummaryMemo")

---@class SummaryModel
local SummaryModel = {}

SummaryModel.LEAF_COUNT = 5
SummaryModel.CROWN_BIT = 32
SummaryModel.WRAP_WIDTH_CHARS = 38

-- Splits text into word-aware lines of at most widthChars characters: a
-- conservative layout hint for scroll decisions. Measured pagination owns
-- the drawn truth; this estimate never shortens or invents content.
---@param text string
---@param widthChars integer
---@return string[]
function SummaryModel.wrapLines(text, widthChars)
  assert(type(text) == "string", "wrapping needs the source text")
  assert(
    type(widthChars) == "number" and widthChars % 1 == 0 and widthChars >= 1,
    "wrapping needs a positive character width"
  )
  local lines = {}
  local line = ""
  for word in text:gmatch("%S+") do
    local candidate = line == "" and word or (line .. " " .. word)
    if #candidate <= widthChars then
      line = candidate
    else
      if line ~= "" then
        lines[#lines + 1] = line
      end
      line = word
    end
  end
  if line ~= "" then
    lines[#lines + 1] = line
  end
  if #lines == 0 then
    lines[1] = ""
  end
  return lines
end

-- Source stat order for the daily performance calculation.
local SOURCE_INDEX = { power = 0, stamina = 1, skill = 2, jump = 3, speed = 4 }

-- Presentation order for the performance rows.
local DISPLAY_ORDER = { "speed", "power", "skill", "stamina", "jump" }

local APRIJUICE_KEYS = { "power", "stamina", "skill", "jump", "speed" }

local UNKNOWN_DEX_TEXT = "???"

---@param mask integer
---@return { leaves: boolean[], crown: boolean }
local function projectLeaves(mask)
  assert(
    type(mask) == "number" and mask % 1 == 0 and mask >= 0 and mask < 64,
    "shiny leaves stay a six-bit observation"
  )
  local crown = math.floor(mask / SummaryModel.CROWN_BIT) % 2 == 1
  local leaves = {}
  for index = 0, SummaryModel.LEAF_COUNT - 1 do
    leaves[index + 1] = not crown and math.floor(mask / (2 ^ index)) % 2 == 1
  end
  return { leaves = leaves, crown = crown }
end

---@param value unknown
---@param bit integer
---@return boolean
local function hasBit(value, bit)
  assert(type(value) == "number", "ribbon fields are numeric")
  return math.floor(value / (2 ^ bit)) % 2 == 1
end

---@param currentHp integer
---@param maxHp integer
---@param length integer
---@return integer, string
local function projectHpBar(currentHp, maxHp, length)
  assert(type(currentHp) == "number" and currentHp % 1 == 0 and currentHp >= 0, "health is a non-negative integer")
  assert(type(maxHp) == "number" and maxHp % 1 == 0 and maxHp > 0, "maximum health is positive")
  assert(currentHp <= maxHp, "current health cannot exceed its maximum")
  local pixels = math.floor((currentHp * length) / maxHp)
  if pixels == 0 and currentHp ~= 0 then
    pixels = 1
  end
  local color = "critical"
  if pixels * 2 > length then
    color = "high"
  elseif pixels * 5 > length then
    color = "low"
  end
  return pixels, color
end

---@param experience integer
---@param level integer
---@param curve integer[]
---@param length integer
---@return integer
local function projectExpBar(experience, level, curve, length)
  if level >= Stats.MAX_LEVEL then
    return 0
  end
  local base = Experience.expFor(curve, level)
  local following = Experience.expFor(curve, level + 1)
  local span = following - base
  if span <= 0 then
    return 0
  end
  local earned = experience - base
  if earned <= 0 then
    return 0
  end
  local pixels = math.floor((earned * length) / span)
  if pixels == 0 then
    pixels = 1
  end
  if pixels > length then
    pixels = length
  end
  return pixels
end

---@param catalog MonCatalog
---@param mon table<string, unknown>
---@return string
local function portraitSelectorFor(catalog, mon)
  local speciesKey = assert(mon.species, "stored mons carry their species")
  assert(type(speciesKey) == "string", "species keys are strings")
  local form = assert(mon.form, "stored mons carry their form")
  assert(type(form) == "number", "form indices are numeric")
  local personality = assert(mon.personality, "stored mons carry their personality")
  assert(type(personality) == "number", "personalities are numeric")
  local origin = assert(mon.origin, "stored mons carry their origin")
  assert(type(origin) == "table", "origins are records")
  local trainerId = assert(origin.trainerId, "origins carry the trainer identity")
  assert(
    type(trainerId) == "number" and trainerId % 1 == 0 and trainerId >= 0 and trainerId <= 4294967295,
    "trainer identities are unsigned integers"
  )
  ---@cast trainerId integer
  local shiny = Personality.shiny(trainerId, personality)
  local species = catalog:species(speciesKey)
  local gender = Personality.gender(assert(species.genderRatio, "catalog species carry a gender ratio"), personality)
  if gender == "male" or gender == "female" then
    return MonCache.portraitSelector(speciesKey, form, gender, shiny)
  end
  assert(gender == "genderless", "portrait genders stay binary or genderless")
  -- Genderless species reuse the generated form's available portrait
  -- variant, recomposed with the actual shininess; nothing is guessed.
  local formRecord = catalog:form(speciesKey, form)
  local declared = assert(formRecord.portrait, "generated forms declare their portrait variant")
  assert(type(declared) == "string", "portrait variants are selectors")
  local variant = declared:match("^[^/]+/[^/]+/([^/]+)/[^/]+$")
  assert(variant == "male" or variant == "female", "generated portrait variants stay binary")
  return MonCache.portraitSelector(speciesKey, form, variant --[[@as string]], shiny)
end

---@param catalog MonCatalog
---@param heldItem unknown
---@return string?
local function heldItemName(catalog, heldItem)
  assert(type(heldItem) == "string", "stored held items are keys")
  if heldItem == "NONE" then
    return nil
  end
  local item = catalog:item(heldItem)
  local name = assert(item.name, "catalog items carry a display name")
  assert(type(name) == "string" and name ~= "", "catalog items carry a display name")
  return name
end

---@param pokerus unknown
---@return string
local function pokerusKey(pokerus)
  assert(type(pokerus) == "number" and pokerus % 1 == 0 and pokerus >= 0 and pokerus <= 255, "pokerus is a byte")
  if pokerus == 0 then
    return "none"
  end
  if pokerus % 16 ~= 0 then
    return "active"
  end
  return "cured"
end

---@param markings unknown
---@return boolean[]
local function projectMarkings(markings)
  assert(type(markings) == "number" and markings % 1 == 0 and markings >= 0 and markings <= 255, "markings are a byte")
  local out = {}
  for index = 0, 5 do
    out[index + 1] = math.floor(markings / (2 ^ index)) % 2 == 1
  end
  return out
end

---@param context table<string, unknown>
---@param slotCount integer
local function checkContext(context, slotCount)
  assert(type(context) == "table", "the summary needs its display context")
  local profile = assert(context.profile, "the display context carries the trainer profile")
  assert(type(profile) == "table", "the trainer profile is a record")
  assert(
    type(profile.trainerId) == "number"
      and profile.trainerId % 1 == 0
      and profile.trainerId >= 0
      and profile.trainerId <= 4294967295,
    "the profile carries the full unsigned trainer identity"
  )
  assert(type(profile.name) == "string" and profile.name ~= "", "the profile carries the exact trainer name")
  assert(profile.gender == 0 or profile.gender == 1, "the profile carries the numeric trainer gender")
  assert(
    type(context.dayOfMonth) == "number"
      and context.dayOfMonth % 1 == 0
      and context.dayOfMonth >= 1
      and context.dayOfMonth <= 31,
    "the display context carries the day of the month"
  )
  assert(
    context.dexMode == "regional" or context.dexMode == "national",
    "the display context names its dex display mode"
  )
  assert(type(context.performanceEnabled) == "boolean", "the display context enables performance explicitly")
  local aprijuiceBySlot = assert(context.aprijuiceBySlot, "the display context carries aprijuice modifiers")
  assert(type(aprijuiceBySlot) == "table", "aprijuice modifiers are a dense slot array")
  assert(#aprijuiceBySlot == slotCount, "aprijuice modifiers match the party size")
  for slot = 1, slotCount do
    local row = aprijuiceBySlot[slot]
    assert(type(row) == "table", "aprijuice row " .. slot .. " is a record")
    for _, key in ipairs(APRIJUICE_KEYS) do
      assert(
        type(row[key]) == "number" and row[key] % 1 == 0 and row[key] >= -128 and row[key] <= 127,
        "aprijuice row " .. slot .. " carries a signed modifier for " .. key
      )
    end
  end
  local specials = assert(context.specialRibbonDescriptions, "the display context carries special-ribbon descriptions")
  assert(type(specials) == "table", "special-ribbon descriptions are an array")
  assert(#specials == 14, "special-ribbon descriptions cover fourteen slots")
  for slot = 1, 14 do
    assert(type(specials[slot]) == "string" and specials[slot] ~= "", "special-ribbon slot " .. slot .. " carries text")
  end
end

---@param context table<string, unknown>
---@return string
local function contextKey(context)
  local profile = assert(context.profile, "the display context carries the trainer profile")
  assert(type(profile) == "table", "the trainer profile is a record")
  assert(type(context.performanceEnabled) == "boolean", "the context carries performance enablement")
  local parts = {
    tostring(assert(profile.trainerId, "the profile carries the trainer identity")),
    tostring(assert(profile.name, "the profile carries the trainer name")),
    tostring(assert(profile.gender, "the profile carries the trainer gender")),
    tostring(assert(context.dayOfMonth, "the context carries the day")),
    tostring(assert(context.dexMode, "the context carries the dex mode")),
    tostring(context.performanceEnabled),
  }
  local aprijuiceBySlot = assert(context.aprijuiceBySlot, "the context carries aprijuice modifiers")
  assert(type(aprijuiceBySlot) == "table", "aprijuice modifiers are an array")
  for _, row in ipairs(aprijuiceBySlot) do
    assert(type(row) == "table", "aprijuice rows are records")
    parts[#parts + 1] = string.format("%d,%d,%d,%d,%d", row.power, row.stamina, row.skill, row.jump, row.speed)
  end
  local specials = assert(context.specialRibbonDescriptions, "the context carries special-ribbon descriptions")
  assert(type(specials) == "table", "special-ribbon descriptions are an array")
  for _, text in ipairs(specials) do
    parts[#parts + 1] = tostring(text)
  end
  return table.concat(parts, "|")
end

---@param mon table<string, unknown>
---@param context table<string, unknown>
---@return boolean
local function isMine(mon, context)
  local profile = assert(context.profile, "the display context carries the trainer profile")
  assert(type(profile) == "table", "the trainer profile is a record")
  local origin = assert(mon.origin, "stored mons carry their origin")
  assert(type(origin) == "table", "origins are records")
  return origin.trainerId == profile.trainerId
    and origin.trainerName == profile.name
    and origin.trainerGender == profile.gender
end

---@param manifest table<string, unknown>
---@return table<string, unknown>, table<string, string>, integer, integer
local function checkManifestRoles(manifest)
  local dexNumbers = assert(manifest.dexNumbers, "the summary family carries dex numbers")
  assert(type(dexNumbers) == "table", "dex numbers are a record")
  local text = assert(manifest.text, "the summary family carries lowered text")
  assert(type(text) == "table", "lowered text is a record")
  local labels = assert(text.labels, "the summary family carries text labels")
  assert(type(labels) == "table", "text labels are a record")
  local bars = assert(manifest.bars, "the summary family carries bar rules")
  assert(type(bars) == "table", "bar rules are a record")
  local hp = assert(bars.hp, "the summary family carries its health bar rule")
  assert(type(hp) == "table" and type(hp.length) == "number", "the health bar carries its pixel length")
  local exp = assert(bars.exp, "the summary family carries its experience bar rule")
  assert(type(exp) == "table" and type(exp.length) == "number", "the experience bar carries its pixel length")
  local hpLength = hp.length
  local expLength = exp.length
  return dexNumbers,
    labels, --[[@as table<string, string>]]
    hpLength,
    expLength
end

---@param catalog MonCatalog
---@param moves table[]
---@return table[]
local function projectMoves(catalog, moves)
  local rows = {}
  for moveSlot = 0, 3 do
    local entry = moves[moveSlot + 1]
    if entry == nil then
      rows[#rows + 1] = { kind = "empty", moveSlot = moveSlot }
    else
      local key = assert(entry.move, "stored move entries carry their key")
      assert(type(key) == "string", "stored move keys are strings")
      local definition = catalog:move(key)
      local basePp = assert(definition.basePp, "catalog moves carry base power points")
      assert(type(basePp) == "number", "base power points are numeric")
      local pp = assert(entry.pp, "stored move entries carry current power points")
      assert(type(pp) == "number", "current power points are numeric")
      local ppUps = assert(entry.ppUps, "stored move entries carry power-point ups")
      assert(type(ppUps) == "number", "power-point ups are numeric")
      local power = assert(definition.power, "catalog moves carry power")
      local accuracy = assert(definition.accuracy, "catalog moves carry accuracy")
      local powerText = tostring(power)
      if power == 0 or power == 1 then
        powerText = "—"
      end
      local accuracyText = tostring(accuracy)
      if accuracy == 0 then
        accuracyText = "—"
      end
      rows[#rows + 1] = {
        kind = "move",
        moveSlot = moveSlot,
        key = key,
        name = assert(definition.name, "catalog moves carry a display name"),
        type = assert(definition.moveType, "catalog moves carry a type"),
        category = assert(definition.category, "catalog moves carry a category"),
        powerText = powerText,
        accuracyText = accuracyText,
        description = assert(definition.description, "catalog moves carry a description"),
        pp = pp,
        ppMax = basePp + math.floor(basePp * ppUps / 5),
        ppUps = ppUps,
      }
    end
  end
  return rows
end

---@param mon table<string, unknown>
---@return table<string, unknown>?
local function eggFacts(mon)
  if not mon.isEgg then
    return nil
  end
  local egg = assert(mon.egg, "eggs carry their origin record")
  local met = assert(mon.met, "eggs carry their met record")
  return {
    location = assert(egg.location, "eggs carry their location"),
    date = egg.date,
    metLocation = assert(met.location, "eggs carry their met location"),
    metLevel = assert(met.level, "eggs carry their met level"),
  }
end

---@param mon table<string, unknown>
---@param context table<string, unknown>
---@param manifest table<string, unknown>
---@return table[]
local function projectRibbons(mon, context, manifest)
  local section = assert(manifest.ribbons, "the summary family carries ribbon definitions")
  assert(type(section) == "table", "ribbon definitions are a record")
  local entries = assert(section.entries, "ribbon definitions carry entries")
  assert(type(entries) == "table", "ribbon entries are an array")
  local text = assert(manifest.text, "the summary family carries lowered text")
  assert(type(text) == "table", "lowered text is a record")
  local labels = assert(text.labels, "the summary family carries text labels")
  assert(type(labels) == "table", "text labels are a record")
  local specials = assert(context.specialRibbonDescriptions, "the context carries special-ribbon descriptions")
  assert(type(specials) == "table", "special-ribbon descriptions are an array")
  local stored = assert(mon.ribbons, "stored mons carry ribbon fields")
  assert(type(stored) == "table", "ribbon fields are a record")
  local earned = {}
  for _, entry in ipairs(entries) do
    assert(type(entry) == "table", "ribbon entries are records")
    local group = assert(entry.bitGroup, "ribbon entries carry their bit group")
    local bit = assert(entry.bit, "ribbon entries carry their bit")
    assert(type(bit) == "number" and bit % 1 == 0 and bit >= 0 and bit <= 31, "ribbon bits address a boxed bit")
    ---@cast bit integer
    local field = stored[group]
    assert(type(field) == "number" and field % 1 == 0, "stored ribbon fields are integers")
    ---@cast field integer
    if hasBit(field, bit) then
      local nameKey = assert(entry.name, "ribbon entries carry their name reference")
      local description = nil
      if entry.special ~= nil then
        assert(type(entry.special) == "number", "special ribbon slots are numeric")
        local resolved = specials[entry.special]
        assert(
          type(resolved) == "string" and resolved ~= "",
          "the context resolves special-ribbon slot " .. entry.special
        )
        description = resolved
      else
        local descriptionKey = assert(entry.description, "ribbon entries carry their description reference")
        local textValue = labels[descriptionKey]
        assert(type(textValue) == "string" and textValue ~= "", "ribbon descriptions resolve display text")
        description = textValue
      end
      local nameValue = labels[nameKey]
      assert(type(nameValue) == "string" and nameValue ~= "", "ribbon names resolve display text")
      local art = assert(entry.art, "ribbon entries carry their visuals")
      assert(type(art) == "table", "ribbon visuals are records")
      earned[#earned + 1] = {
        key = assert(entry.key, "ribbon entries carry their key"),
        name = nameValue,
        description = description,
        art = {
          image = assert(art.image, "ribbon visuals carry an image"),
          width = assert(art.width, "ribbon visuals carry a width"),
          height = assert(art.height, "ribbon visuals carry a height"),
          palette = assert(art.palette, "ribbon visuals carry a palette"),
        },
      }
    end
  end
  return earned
end

---@param score integer
---@return integer
local function starAdjustment(score)
  if score <= -120 then
    return -4
  elseif score <= -80 then
    return -3
  elseif score <= -40 then
    return -2
  elseif score <= -15 then
    return -1
  elseif score <= 14 then
    return 0
  elseif score <= 39 then
    return 1
  elseif score <= 79 then
    return 2
  elseif score <= 119 then
    return 3
  else
    return 4
  end
end

---@param value integer
---@param position integer
---@return integer
local function pidDigit(value, position)
  return math.floor(value / (10 ^ position)) % 10
end

---@param mon table<string, unknown>
---@param slot0 integer
---@param context table<string, unknown>
---@param manifest table<string, unknown>
---@return table[]?
local function projectPerformance(mon, slot0, context, manifest)
  if context.performanceEnabled ~= true then
    return nil
  end
  if mon.isEgg == true then
    return nil
  end
  local section = assert(manifest.performance, "the summary family carries performance tables")
  assert(type(section) == "table", "performance tables are a record")
  local forms = assert(section.forms, "performance tables carry form rows")
  assert(type(forms) == "table", "performance form rows are a record")
  local natureModifiers = assert(section.natureModifiers, "performance tables carry nature modifiers")
  assert(type(natureModifiers) == "table", "nature modifiers are an array")
  local formKey = tostring(assert(mon.species, "stored mons carry their species"))
    .. "/f"
    .. tostring(assert(mon.form, "stored mons carry their form"))
  local form = forms[formKey]
  assert(type(form) == "table", "performance tables cover form " .. formKey)
  local pid = assert(mon.personality, "stored mons carry their personality")
  assert(type(pid) == "number", "personalities are numeric")
  local nature = Personality.nature(pid)
  local modifiers = natureModifiers[nature + 1]
  assert(type(modifiers) == "table", "nature modifiers cover nature " .. nature)
  local day = assert(context.dayOfMonth, "the display context carries the day of the month")
  assert(type(day) == "number", "the day of the month is numeric")
  local aprijuiceBySlot = assert(context.aprijuiceBySlot, "the context carries aprijuice modifiers")
  assert(type(aprijuiceBySlot) == "table", "aprijuice modifiers are an array")
  local juice = aprijuiceBySlot[slot0 + 1]
  assert(type(juice) == "table", "aprijuice modifiers cover the selected slot")
  local rows = {}
  for _, stat in ipairs(DISPLAY_ORDER) do
    local sourceIndex = assert(SOURCE_INDEX[stat], "performance covers stat " .. stat)
    local modifier = assert(modifiers[stat], "nature modifiers cover stat " .. stat)
    assert(type(modifier) == "number", "nature modifiers are numeric")
    local extra = assert(juice[stat], "aprijuice modifiers cover stat " .. stat)
    assert(type(extra) == "number", "aprijuice modifiers are numeric")
    local residue = (pidDigit(pid, sourceIndex) + (day + 7 - sourceIndex) * (day + sourceIndex + 3)) % 10
    local score = modifier + 2 * residue - 9 + extra
    local bounds = assert(form[stat], "performance form rows cover stat " .. stat)
    assert(type(bounds) == "table", "performance bounds are records")
    local base = assert(bounds.base, "performance bounds carry a base")
    local lo = assert(bounds.lo, "performance bounds carry a minimum")
    local hi = assert(bounds.hi, "performance bounds carry a maximum")
    assert(type(base) == "number" and type(lo) == "number" and type(hi) == "number", "performance bounds are numeric")
    local stars = base + starAdjustment(score)
    if stars < lo then
      stars = lo
    end
    if stars > hi then
      stars = hi
    end
    local tone = "base"
    if stars < base then
      tone = "below"
    elseif stars > base then
      tone = "above"
    end
    rows[#rows + 1] = { stat = stat, base = base, min = lo, max = hi, stars = stars, tone = tone, modifier = extra }
  end
  return rows
end

-- Builds one immutable facts record for the mon in zero-based slot0 from
-- the live service, the explicit read-only display context, and the
-- validated summary family. Reading never writes the domain, consumes no
-- generator draws, and loads no images. A changed party revision aborts
-- the refresh instead of assembling mixed-generation facts.
---@param service HgssMonService the live mon service (partyCount/partyRevision/partyMon/derive/catalog)
---@param slot0 integer
---@param context table<string, unknown> explicit read-only display context
---@param manifest table<string, unknown> validated summary family
---@return table<string, unknown>
function SummaryModel.build(service, slot0, context, manifest)
  assert(type(service) == "table", "the summary needs the live mon service")
  assert(type(service.partyCount) == "function", "the summary needs the party count")
  assert(type(service.partyRevision) == "function", "the summary needs the party revision")
  assert(type(service.partyMon) == "function", "the summary needs party reads")
  assert(type(service.derive) == "function", "the summary needs the derived-stat projection")
  assert(type(service.catalog) == "function", "the summary needs the mon catalog")
  assert(type(manifest) == "table", "the summary needs the summary family")
  SummaryAssetSchema.assertManifest(manifest)
  local slotCount = service:partyCount()
  assert(type(slotCount) == "number" and slotCount % 1 == 0 and slotCount >= 1, "the summary needs a nonempty party")
  assert(
    type(slot0) == "number" and slot0 % 1 == 0 and slot0 >= 0 and slot0 < slotCount,
    "the summary needs an occupied party slot"
  )
  assert(type(context) == "table", "the summary needs its display context")
  checkContext(context, slotCount)
  local dexNumbers, labels, hpLength, expLength = checkManifestRoles(manifest)
  local pictures = assert(manifest.pictures, "the summary family carries pictures")
  assert(type(pictures) == "table", "pictures are a record")

  local revision = service:partyRevision()
  local catalog = service:catalog()
  local mon = service:partyMon(slot0)
  local owned = isMine(mon, context)
  local memo = SummaryMemo.build(mon, owned, context, manifest)

  local roster = {}
  for slot = 0, slotCount - 1 do
    local member = service:partyMon(slot)
    local memberIsEgg = member.isEgg == true
    local iconKey = nil
    local portraitSelector = nil
    if memberIsEgg then
      iconKey = MonCache.iconSelector("EGG", 0, true)
    else
      iconKey = MonCache.iconSelector(
        assert(member.species, "stored mons carry their species"),
        assert(member.form, "stored mons carry their form"),
        false
      )
      portraitSelector = portraitSelectorFor(catalog, member)
    end
    roster[#roster + 1] = { slot = slot, isEgg = memberIsEgg, iconKey = iconKey, portraitSelector = portraitSelector }
  end

  local snapshot = nil
  if mon.isEgg == true then
    local origin = assert(mon.origin, "stored mons carry their origin")
    assert(type(origin) == "table", "origins are records")
    local eggOtId = assert(origin.trainerId, "origins carry the trainer identity")
    assert(type(eggOtId) == "number", "trainer identities are numeric")
    local eggOtName = assert(origin.trainerName, "origins carry the trainer name")
    assert(type(eggOtName) == "string", "trainer names are strings")
    local eggHeldItem = assert(mon.heldItem, "stored mons carry their held item")
    local eggExperience = assert(mon.experience, "stored mons carry experience")
    assert(type(eggExperience) == "number", "experience is numeric")
    local unknownText = labels["synUnknownDex"]
    if type(unknownText) ~= "string" or unknownText == "" then
      unknownText = UNKNOWN_DEX_TEXT
    end
    snapshot = {
      revision = revision,
      contextKey = contextKey(context),
      slot = slot0,
      slotCount = slotCount,
      roster = roster,
      isEgg = true,
      identity = {
        species = "EGG",
        form = 0,
        personality = assert(mon.personality, "stored mons carry their personality"),
        nickname = nil,
        displayName = "EGG",
        otName = eggOtName,
        gender = "genderless",
        shiny = false,
      },
      pictureKey = "EGG",
      portraitSelector = nil,
      iconKey = MonCache.iconSelector("EGG", 0, true),
      memo = memo,
      info = {
        dexNumber = 0,
        dexText = unknownText,
        otIdText = string.format("%05d", eggOtId % 65536),
        experience = eggExperience,
        expToNext = 0,
        expBar = { length = 0 },
        heldItem = eggHeldItem,
        heldItemName = heldItemName(catalog, eggHeldItem),
        ball = assert(origin.ball, "origins carry the ball"),
      },
      skills = nil,
      moves = {},
      ribbons = projectRibbons(mon, context, manifest),
      performance = nil,
      indicators = nil,
    }
    local mask = assert(mon.shinyLeaves, "stored mons carry their leaf mask")
    local crown = projectLeaves(mask)
    local condition = assert(mon.condition, "stored mons carry their condition")
    assert(type(condition) == "table", "conditions are records")
    local eggHp = assert(condition.currentHp, "conditions carry current health")
    assert(type(eggHp) == "number" and eggHp % 1 == 0 and eggHp >= 0, "current health is a non-negative integer")
    ---@cast eggHp integer
    snapshot.indicators = {
      status = PartyScreenTheme.statusKey(assert(condition.status, "conditions carry status bits"), eggHp),
      pokerus = pokerusKey(assert(mon.pokerus, "stored mons carry pokerus")),
      markings = projectMarkings(assert(mon.markings, "stored mons carry markings")),
      leaves = crown.leaves,
      crown = crown.crown,
      shiny = false,
    }
  else
    local speciesKey = assert(mon.species, "stored mons carry their species")
    assert(type(speciesKey) == "string", "species keys are strings")
    local species = catalog:species(speciesKey)
    local speciesName = assert(species.name, "catalog species carry a display name")
    assert(type(speciesName) == "string" and speciesName ~= "", "catalog species carry a display name")
    local formRecord = catalog:form(speciesKey, assert(mon.form, "stored mons carry their form"))
    local formTypes = assert(formRecord.types, "catalog forms carry types")
    assert(type(formTypes) == "table", "form types are an array")
    local types = {}
    for index, typeName in ipairs(formTypes) do
      assert(type(typeName) == "string", "form types are strings")
      types[index] = typeName
    end
    local origin = assert(mon.origin, "stored mons carry their origin")
    assert(type(origin) == "table", "origins are records")
    local otName = assert(origin.trainerName, "origins carry the trainer name")
    assert(type(otName) == "string", "trainer names are strings")
    local trainerId = assert(origin.trainerId, "origins carry the trainer identity")
    assert(
      type(trainerId) == "number" and trainerId % 1 == 0 and trainerId >= 0 and trainerId <= 4294967295,
      "trainer identities are unsigned integers"
    )
    ---@cast trainerId integer
    local personality = assert(mon.personality, "stored mons carry their personality")
    local gender = Personality.gender(assert(species.genderRatio, "catalog species carry a gender ratio"), personality)
    local shiny = Personality.shiny(trainerId, personality)
    local derived = service:derive(mon)
    local level = assert(derived.level, "derivation carries the level")
    local maxHp = assert(derived.maxHp, "derivation carries maximum health")
    local condition = assert(mon.condition, "stored mons carry their condition")
    assert(type(condition) == "table", "conditions are records")
    local currentHp = assert(condition.currentHp, "conditions carry current health")
    assert(
      type(currentHp) == "number" and currentHp % 1 == 0 and currentHp >= 0,
      "current health is a non-negative integer"
    )
    ---@cast currentHp integer
    local abilityKey = assert(mon.ability, "stored mons carry their ability")
    assert(type(abilityKey) == "string", "ability keys are strings")
    local ability = catalog:ability(abilityKey)
    local nature = Personality.nature(personality)
    local up, down = SummaryMemo.natureShift(nature)
    local barLength, hpColor = projectHpBar(currentHp, maxHp, hpLength)
    local numbers = dexNumbers[speciesKey]
    assert(type(numbers) == "table", "dex numbers cover species " .. speciesKey)
    local dexMode = assert(context.dexMode, "the context carries the dex mode")
    local dexNumber = nil
    if dexMode == "regional" then
      dexNumber = assert(numbers.regional, "dex numbers carry a regional entry")
    else
      dexNumber = assert(numbers.national, "dex numbers carry a national entry")
    end
    assert(type(dexNumber) == "number", "dex numbers are numeric")
    local dexText = tostring(dexNumber)
    if dexMode == "regional" and dexNumber == 0 then
      local unknownText = labels["synUnknownDex"]
      if type(unknownText) == "string" and unknownText ~= "" then
        dexText = unknownText
      else
        dexText = UNKNOWN_DEX_TEXT
      end
    end
    local experience = assert(mon.experience, "stored mons carry experience")
    assert(type(experience) == "number", "experience is numeric")
    local expToNext = 0
    if level < Stats.MAX_LEVEL then
      local curve = catalog:growthCurve(assert(species.growthCurve, "catalog species carry a growth curve"))
      expToNext = Experience.expFor(curve, level + 1) - experience
    end
    local pictureKey = speciesKey
    assert(pictures[pictureKey] ~= nil, "the summary family carries picture " .. pictureKey)
    snapshot = {
      revision = revision,
      contextKey = contextKey(context),
      slot = slot0,
      slotCount = slotCount,
      roster = roster,
      isEgg = false,
      identity = {
        species = speciesKey,
        form = assert(mon.form, "stored mons carry their form"),
        personality = personality,
        nickname = mon.nickname,
        displayName = Mon.displayName(mon, catalog),
        speciesName = speciesName,
        types = types,
        otName = otName,
        gender = gender,
        shiny = shiny,
      },
      pictureKey = pictureKey,
      portraitSelector = roster[slot0 + 1].portraitSelector,
      iconKey = MonCache.iconSelector(speciesKey, assert(mon.form, "stored mons carry their form"), false),
      memo = memo,
      info = {
        dexNumber = dexNumber,
        dexText = dexText,
        otIdText = string.format("%05d", trainerId % 65536),
        experience = experience,
        expToNext = expToNext,
        expBar = {
          length = projectExpBar(
            experience,
            level,
            catalog:growthCurve(assert(species.growthCurve, "catalog species carry a growth curve")),
            expLength
          ),
        },
        heldItem = assert(mon.heldItem, "stored mons carry their held item"),
        heldItemName = heldItemName(catalog, assert(mon.heldItem, "stored mons carry their held item")),
        ball = assert(origin.ball, "origins carry the ball"),
      },
      skills = {
        level = level,
        currentHp = currentHp,
        maxHp = maxHp,
        attack = assert(derived.attack, "derivation carries attack"),
        defense = assert(derived.defense, "derivation carries defense"),
        speed = assert(derived.speed, "derivation carries speed"),
        specialAttack = assert(derived.specialAttack, "derivation carries special attack"),
        specialDefense = assert(derived.specialDefense, "derivation carries special defense"),
        ability = abilityKey,
        abilityName = assert(ability.name, "catalog abilities carry a display name"),
        abilityDescription = assert(ability.description, "catalog abilities carry a description"),
        nature = { up = up, down = down },
        hpBar = { length = barLength, color = hpColor },
      },
      moves = projectMoves(catalog, assert(mon.moves, "stored mons carry their moves")),
      ribbons = projectRibbons(mon, context, manifest),
      performance = projectPerformance(mon, slot0, context, manifest),
      indicators = nil,
    }
    local mask = assert(mon.shinyLeaves, "stored mons carry their leaf mask")
    local crown = projectLeaves(mask)
    snapshot.indicators = {
      status = PartyScreenTheme.statusKey(assert(condition.status, "conditions carry status bits"), currentHp),
      pokerus = pokerusKey(assert(mon.pokerus, "stored mons carry pokerus")),
      markings = projectMarkings(assert(mon.markings, "stored mons carry markings")),
      leaves = crown.leaves,
      crown = crown.crown,
      shiny = shiny,
    }
  end

  assert(pictures[snapshot.pictureKey] ~= nil, "the picture selection exists in the summary family")
  local closing = service:partyRevision()
  assert(closing == revision, "the party revision moved during a read-only refresh")
  snapshot.revision = closing
  return snapshot
end

-- Projects one detached occupied subject through the same catalog and
-- derivation used for party summaries. The caller owns address selection.
---@param mon table<string, unknown>
---@param options { revision: integer, index: integer, count: integer, catalog: MonCatalog, derive: fun(mon: table<string, unknown>): table<string, unknown> }
---@return table<string, unknown>
function SummaryModel.buildMon(mon, options)
  assert(type(mon) == "table", "the summary subject is a copied mon")
  assert(type(options) == "table", "the summary projection needs subject facts")
  assert(type(options.revision) == "number" and options.revision % 1 == 0, "summary revisions are integers")
  assert(
    type(options.index) == "number" and options.index % 1 == 0 and options.index >= 0,
    "subject indexes are zero-based"
  )
  assert(
    type(options.count) == "number" and options.count % 1 == 0 and options.count > options.index,
    "summary subjects are occupied"
  )
  assert(type(options.derive) == "function", "the summary projection needs service derivation")
  local catalog = assert(options.catalog, "the summary projection needs the mon catalog")
  local mask = assert(mon.shinyLeaves, "stored mons carry their leaf mask")
  assert(type(mask) == "number", "leaf masks are numeric")
  local species = catalog:species(assert(mon.species, "stored mons carry their species"))
  local form = catalog:form(mon.species, assert(mon.form, "stored mons carry their form"))
  local origin = assert(mon.origin, "stored mons carry their origin")
  local trainerId = assert(origin.trainerId, "origins carry the trainer identity")
  local personality = assert(mon.personality, "stored mons carry their personality")
  local gender = Personality.gender(assert(species.genderRatio, "catalog species carry a gender ratio"), personality)
  local shiny = Personality.shiny(trainerId, personality)
  local abilityKey = assert(mon.ability, "stored mons carry their ability")
  assert(type(abilityKey) == "string", "ability keys are strings")
  local ability = catalog:ability(abilityKey)
  local heldItem = assert(mon.heldItem, "stored mons carry their held item")
  assert(type(heldItem) == "string", "held item keys are strings")
  local heldItemName = nil
  if heldItem ~= "NONE" then
    heldItemName = assert(catalog:item(heldItem).name, "held items carry a display name")
  end
  local condition = assert(mon.condition, "stored mons carry their condition")
  local types = {}
  for _, typeKey in ipairs(assert(form.types, "catalog forms carry types")) do
    types[#types + 1] = typeKey
  end
  local facts = {
    revision = options.revision,
    slot = options.index,
    slotCount = options.count,
    isEgg = mon.isEgg == true,
    displayName = Mon.displayName(mon, catalog),
    speciesName = assert(species.name, "catalog species carry a display name"),
    gender = gender,
    shiny = shiny,
    types = types,
    otName = assert(origin.trainerName, "origins carry the trainer name"),
    otVisibleId = trainerId % 65536,
    nature = Personality.nature(personality),
    ability = abilityKey,
    abilityName = assert(ability.name, "catalog abilities carry a display name"),
    abilityDescription = assert(ability.description, "catalog abilities carry a description"),
    heldItem = heldItem,
    heldItemName = heldItemName,
    status = PartyScreenTheme.statusKey(
      assert(condition.status, "conditions carry status bits"),
      assert(condition.currentHp, "conditions carry current health")
    ),
    currentHp = condition.currentHp,
    leaves = projectLeaves(mask),
    portraitSelector = nil,
    iconKey = MonCache.iconSelector(mon.species, mon.form, mon.isEgg == true),
    stats = nil,
    experience = nil,
    expToNext = nil,
    moves = {},
    egg = nil,
    level = nil,
    maxHp = nil,
    bodyLineEstimate = 0,
  }
  if facts.isEgg then
    facts.egg = eggFacts(mon)
    return facts
  end
  local derived = options.derive(mon)
  facts.level = assert(derived.level, "derivation carries the level")
  facts.maxHp = assert(derived.maxHp, "derivation carries maximum health")
  facts.stats = {
    attack = assert(derived.attack, "derivation carries attack"),
    defense = assert(derived.defense, "derivation carries defense"),
    speed = assert(derived.speed, "derivation carries speed"),
    specialAttack = assert(derived.specialAttack, "derivation carries special attack"),
    specialDefense = assert(derived.specialDefense, "derivation carries special defense"),
  }
  local experience = assert(mon.experience, "stored mons carry experience")
  assert(type(experience) == "number", "experience is numeric")
  facts.experience = experience
  if facts.level < 100 then
    local curve = catalog:growthCurve(assert(species.growthCurve, "catalog species carry a growth curve"))
    facts.expToNext = Experience.expFor(curve, facts.level + 1) - experience
  end
  facts.moves = projectMoves(catalog, assert(mon.moves, "stored mons carry their moves"))
  local portraitGender = gender
  if portraitGender == "genderless" then
    portraitGender = "male"
  end
  facts.portraitSelector = MonCache.portraitSelector(mon.species, mon.form, portraitGender, shiny)
  facts.bodyLineEstimate = #SummaryModel.wrapLines(facts.abilityDescription, SummaryModel.WRAP_WIDTH_CHARS)
  return facts
end

return SummaryModel
