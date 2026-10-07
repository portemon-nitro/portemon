-- Projects the selected mon edit draft into the three player-facing pages:
-- a sprite selector strip, semantic Stats/Moves/Details models, and nothing
-- else. Technical record state never leaves this owner.

local Errors = require("libs.errors.src.Errors")
local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
local Moves = require("libs.mons.src.gen4.Moves")
local PartyScreenTheme = require("libs.hgss.src.ui.PartyScreenTheme")
local Draft = require("app.src.saveeditor.SaveEditorMonDraft")

local PartyView = {}
PartyView.__index = PartyView

---@alias SaveEditorPartyOptionKey string|integer
---@alias SaveEditorPartyOptionKeys table<integer|string, SaveEditorPartyOptionKey|boolean>

---@class SaveEditorPartySelectorSlot
---@field kind "member"|"add"|"empty"
---@field slot0 integer?
---@field iconKey string?
---@field descriptiveLabel string?
---@field active boolean?

---@class SaveEditorPartyHeaderFact
---@field id string
---@field label string
---@field value unknown
---@field display string?
---@field maxHp integer?
---@field targetId string?
---@field editor SaveEditorPartyEditorDescriptor?
---@field help string?

---@class SaveEditorPartyEditorDescriptor
---@field kind string
---@field value unknown?
---@field min number?
---@field max number?
---@field base string?
---@field setter string?
---@field fieldId string?
---@field options { key: string, label: string }[]?
---@field convert string?
---@field nameKind string?
---@field subject table<string, unknown>?

---@class SaveEditorPartyStatsCell
---@field targetId string
---@field editor SaveEditorPartyEditorDescriptor?
---@field help string

---@class SaveEditorPartyStatsRow
---@field key string
---@field label string
---@field iv number
---@field ivEditor SaveEditorPartyStatsCell
---@field ev number
---@field evEditor SaveEditorPartyStatsCell

---@class SaveEditorPartyMoveSlot
---@field kind "move"|"add"|"empty"
---@field slot0 integer?
---@field label string?
---@field targetId string?

---@class SaveEditorPartyDetailsRow
---@field role string
---@field targetId string
---@field id string
---@field label string
---@field value unknown?
---@field editor SaveEditorPartyEditorDescriptor?
---@field enabled boolean?
---@field semantic string?

---@class SaveEditorPartyView
---@field private context table<string, unknown>
---@field private optionCache table<string, { key: string, label: string }[]>
---@field options fun(self: SaveEditorPartyView, key: string, keysFor: fun(): SaveEditorPartyOptionKeys, labelFor: fun(key: string): string, numericKeys: boolean?): { key: string, label: string }[]
---@field selector fun(self: SaveEditorPartyView, members: { slot0: integer, mon: table<string, unknown> }[], selectedSlot0: integer?): { slots: SaveEditorPartySelectorSlot[] }
---@field stats fun(self: SaveEditorPartyView, record: table<string, unknown>, projection: SaveEditorMonProjection): { header: SaveEditorPartyHeaderFact[], rows: SaveEditorPartyStatsRow[] }
---@field moves fun(self: SaveEditorPartyView, record: table<string, unknown>): { slots: SaveEditorPartyMoveSlot[] }
---@field details fun(self: SaveEditorPartyView, record: table<string, unknown>, projection: SaveEditorMonProjection): { rows: SaveEditorPartyDetailsRow[] }

local function catalogOptions(keys, labelFor, numericKeys)
  local options = {}
  for key, value in pairs(keys) do
    local optionKey = numericKeys and key or value
    if not numericKeys and type(key) == "number" then
      optionKey = value
    end
    local textKey = tostring(optionKey)
    options[#options + 1] = { key = textKey, label = labelFor(textKey) }
  end
  table.sort(options, function(a, b)
    return a.key < b.key
  end)
  return options
end

---@param context table<string, unknown>
---@return SaveEditorPartyView
function PartyView.new(context)
  assert(type(context) == "table" and type(context.monCatalog) == "table" and type(context.itemCatalog) == "table")
  return setmetatable({ context = context, optionCache = {} }, PartyView)
end

---@param key string
---@param keysFor fun(): SaveEditorPartyOptionKeys
---@param labelFor fun(key: string): string
---@param numericKeys boolean?
---@return { key: string, label: string }[]
function PartyView:options(key, keysFor, labelFor, numericKeys)
  local cached = self.optionCache[key]
  if not cached then
    cached = catalogOptions(keysFor(), labelFor, numericKeys)
    self.optionCache[key] = cached
  end
  local options = {}
  for _, option in ipairs(cached) do
    options[#options + 1] = { key = option.key, label = option.label }
  end
  return options
end

-- Six-position strip: one entry per member, `+ Add` on the first empty
-- position, inert placeholders after it. Selection is persistent active
-- state, never keyboard focus.
---@param members { slot0: integer, mon: table<string, unknown> }[]
---@param selectedSlot0 integer?
---@return { slots: SaveEditorPartySelectorSlot[] }
function PartyView:selector(members, selectedSlot0)
  assert(type(members) == "table", "the selector needs its staged members")
  local catalog = assert(self.context.monCatalog)
  local slots = {}
  for position = 1, 6 do
    local member = members[position]
    if member ~= nil then
      local mon = assert(member.mon)
      local species = catalog:species(mon.species)
      slots[position] = {
        kind = "member",
        slot0 = member.slot0,
        iconKey = catalog:iconSelection(mon),
        descriptiveLabel = mon.nickname ~= nil and mon.nickname ~= "" and mon.nickname or species.name or mon.species,
        active = member.slot0 == selectedSlot0,
      }
    elseif position == #members + 1 then
      slots[position] = { kind = "add", slot0 = #members }
    else
      slots[position] = { kind = "empty" }
    end
  end
  return { slots = slots }
end

---@param record table<string, unknown>
---@return integer
local function evTotal(record)
  local total = 0
  for _, value in pairs(record.evs) do
    total = total + value
  end
  return total
end

-- Stats header plus the IV/EV table. Computed stat values are omitted: the
-- table tunes inputs, and the header carries the semantic identity fields.
---@param record table<string, unknown>
---@param projection SaveEditorMonProjection
---@return { header: SaveEditorPartyHeaderFact[], rows: SaveEditorPartyStatsRow[] }
function PartyView:stats(record, projection)
  local maxHp = projection.stats and projection.stats.hp or nil
  local statusKey = PartyScreenTheme.statusKey(assert(record.condition, "save editor records carry their condition"))
  local header = {
    {
      id = "level",
      label = "Level",
      value = projection.level,
      targetId = "party:field:level",
      editor = {
        kind = "integer",
        value = projection.level,
        min = 1,
        max = 100,
        base = "decimal",
        setter = "level",
        fieldId = "level",
      },
      help = "Level writes the threshold experience for that level.",
    },
    {
      id = "experience",
      label = "Exp",
      value = record.experience,
      targetId = "party:field:experience",
      editor = self:_experienceEditor(record),
      help = "Experience determines level; level, IVs, and EVs determine stats.",
    },
    {
      id = "friendship",
      label = "Friendship",
      value = record.friendship,
      targetId = "party:field:friendship",
      editor = {
        kind = "integer",
        value = record.friendship,
        min = 0,
        max = 255,
        base = "decimal",
        setter = "scalar",
        fieldId = "friendship",
      },
    },
    {
      id = "currentHp",
      label = "HP",
      value = record.condition.currentHp,
      display = maxHp and (record.condition.currentHp .. "/" .. maxHp) or tostring(record.condition.currentHp),
      maxHp = maxHp,
      targetId = "party:field:currentHp",
      editor = maxHp and {
        kind = "integer",
        value = record.condition.currentHp,
        min = 0,
        max = maxHp,
        base = "decimal",
        setter = "scalar",
        fieldId = "currentHp",
      } or nil,
    },
    {
      id = "status",
      label = "Status",
      value = PartyScreenTheme.statusLabel(statusKey) or "OK",
      key = statusKey,
      targetId = "party:readonly:status",
    },
  }
  local total = evTotal(record)
  local rows = {}
  for _, pair in ipairs({
    { "hp", "HP" },
    { "attack", "Attack" },
    { "defense", "Defense" },
    { "speed", "Speed" },
    { "specialAttack", "Sp. Atk" },
    { "specialDefense", "Sp. Def" },
  }) do
    local key, label = pair[1], pair[2]
    local ivId, evId = "iv:" .. key, "ev:" .. key
    rows[#rows + 1] = {
      key = key,
      label = label,
      iv = record.ivs[key],
      ivEditor = {
        targetId = "party:field:" .. ivId,
        editor = {
          kind = "integer",
          value = record.ivs[key],
          min = 0,
          max = 31,
          base = "decimal",
          setter = "iv",
          fieldId = ivId,
        },
        help = "IVs contribute to the computed stats.",
      },
      ev = record.evs[key],
      evEditor = {
        targetId = "party:field:" .. evId,
        editor = {
          kind = "integer",
          value = record.evs[key],
          min = 0,
          max = math.min(255, record.evs[key] + (510 - total)),
          base = "decimal",
          setter = "ev",
          fieldId = evId,
        },
        help = "EVs contribute to the computed stats.",
      },
    }
  end
  return { header = header, rows = rows }
end

---@param record table<string, unknown>
---@return SaveEditorPartyEditorDescriptor?
function PartyView:_experienceEditor(record)
  local catalog = assert(self.context.monCatalog)
  local ok, species = pcall(catalog.species, catalog, record.species)
  local maximum = 4294967295
  if ok then
    local curveOk, curve = pcall(catalog.growthCurve, catalog, species.growthCurve)
    if curveOk then
      maximum = curve[100]
    end
  elseif not Errors.is(species) then
    error(species, 0)
  end
  return {
    kind = "integer",
    value = record.experience,
    min = 0,
    max = maximum,
    base = "decimal",
    setter = "scalar",
    fieldId = "experience",
  }
end

-- Four move slots in order: occupied slots name their move with current and
-- maximum PP, the first empty slot offers `+ Add`, later empties stay inert.
---@param record table<string, unknown>
---@return { slots: SaveEditorPartyMoveSlot[] }
function PartyView:moves(record)
  local catalog = assert(self.context.monCatalog)
  local slots = {}
  for slot0 = 0, 3 do
    local entry = record.moves[slot0 + 1]
    if entry ~= nil then
      local definition = catalog:move(entry.move)
      local maxPp = Moves.maxPp(definition.basePp, entry.ppUps)
      slots[slot0 + 1] = {
        kind = "move",
        slot0 = slot0,
        label = (definition.name or entry.move) .. " " .. entry.pp .. "/" .. maxPp,
        targetId = "party:move:" .. slot0,
      }
    elseif slot0 == #record.moves then
      slots[slot0 + 1] = { kind = "add", targetId = "party:move:add", label = "+ Add" }
    else
      slots[slot0 + 1] = { kind = "empty" }
    end
  end
  return { slots = slots }
end

-- Player-facing instance data only. Species catalog facts, native ids, raw
-- personality, growth/EXP internals, met terrain, and move metadata never
-- leave this owner.
---@param record table<string, unknown>
---@param projection SaveEditorMonProjection
---@return { rows: SaveEditorPartyDetailsRow[] }
function PartyView:details(record, projection)
  local catalog = assert(self.context.monCatalog)
  local rows = {}
  local function integer(fieldId, label, value, minimum, maximum, base, setter)
    rows[#rows + 1] = {
      role = "integer value",
      targetId = "party:field:" .. fieldId,
      id = fieldId,
      label = label,
      value = value,
      editor = {
        kind = "integer",
        value = value,
        min = minimum,
        max = maximum,
        base = base or "decimal",
        setter = setter or "scalar",
        fieldId = fieldId,
      },
      enabled = true,
    }
  end
  local function choice(fieldId, label, value, options, setter, convert)
    rows[#rows + 1] = {
      role = "named choice",
      targetId = "party:field:" .. fieldId,
      id = fieldId,
      label = label,
      value = value,
      editor = {
        kind = "choice",
        value = value,
        options = options,
        setter = setter or "scalar",
        fieldId = fieldId,
        convert = convert,
      },
      enabled = true,
    }
  end
  local function readonly(fieldId, label, value)
    rows[#rows + 1] = {
      role = "read-only value",
      targetId = "party:readonly:" .. fieldId,
      id = fieldId,
      label = label,
      value = value,
    }
  end

  local speciesOptions = self:options("species", function()
    return catalog:speciesKeys()
  end, function(key)
    return catalog:species(key).name or key
  end)
  choice("species", "Species", record.species, speciesOptions, "species")
  local species = catalog:species(record.species)
  local formIds = {}
  for formId in pairs(species.forms) do
    formIds[#formIds + 1] = formId
  end
  if #formIds > 1 then
    table.sort(formIds)
    choice(
      "form",
      "Form",
      tostring(record.form),
      self:options("forms:" .. record.species, function()
        return formIds
      end, function(key)
        return tostring(key)
      end),
      "form",
      "integer"
    )
  end
  rows[#rows + 1] = {
    role = "action",
    targetId = "party:field:nickname",
    id = "nickname",
    label = "Nickname",
    value = record.nickname or "",
    editor = {
      kind = "name",
      value = record.nickname or "",
      nameKind = "pokemon",
      subject = { kind = "pokemon", species = assert(species.nativeId), form = record.form },
      setter = "scalar",
      fieldId = "nickname",
    },
    enabled = true,
  }
  rows[#rows + 1] = {
    role = "action",
    targetId = "party:use-species-name",
    id = "use-species-name",
    label = "Use species name",
    enabled = true,
  }
  readonly("nature", "Nature", HgssMonService.natureName(assert(projection.nature)))
  readonly("gender", "Gender", projection.gender)
  readonly("shiny", "Shiny", projection.shiny == nil and "Unavailable" or (projection.shiny and "Yes" or "No"))
  local formOk, form = pcall(catalog.form, catalog, record.species, record.form)
  if formOk then
    choice(
      "ability",
      "Ability",
      record.ability,
      self:options("abilities:" .. record.species .. ":" .. tostring(record.form), function()
        return form.abilities
      end, function(key)
        return catalog:ability(key).name or key
      end)
    )
  elseif not Errors.is(form) then
    error(form, 0)
  end
  local itemCatalog = assert(self.context.itemCatalog)
  local heldOptions = self:options("items", function()
    return itemCatalog:itemKeys()
  end, function(key)
    return itemCatalog:item(key).name or key
  end)
  choice("heldItem", "Held item", record.heldItem, heldOptions)
  local origin = record.origin
  rows[#rows + 1] = {
    role = "action",
    targetId = "party:field:trainerName",
    id = "trainerName",
    label = "Trainer name",
    value = origin.trainerName,
    editor = {
      kind = "name",
      value = origin.trainerName,
      nameKind = "player",
      subject = { kind = "player", gender = origin.trainerGender },
      setter = "origin",
      fieldId = "trainerName",
    },
    enabled = true,
  }
  choice(
    "trainerGender",
    "Trainer gender",
    tostring(origin.trainerGender),
    { { key = "0", label = "Male" }, { key = "1", label = "Female" } },
    "origin",
    "integer"
  )
  integer("trainerId", "Trainer ID", origin.trainerId, 0, 4294967295, "hex", "origin")
  choice(
    "game",
    "Origin game",
    origin.game,
    self:options("games", function()
      return HgssMonService.GAMES
    end, function(key)
      return key
    end, true),
    "origin"
  )
  choice(
    "language",
    "Language",
    origin.language,
    self:options("languages", function()
      return HgssMonService.LANGUAGES
    end, function(key)
      return key
    end, true),
    "origin"
  )
  local ballOptions = self:options("balls", function()
    local keys = {}
    for _, key in ipairs(itemCatalog:itemKeys()) do
      if itemCatalog:item(key).pocket == "balls" then
        keys[#keys + 1] = key
      end
    end
    return keys
  end, function(key)
    return itemCatalog:item(key).name or key
  end)
  choice("ball", "Ball", origin.ball, ballOptions, "origin")
  local met = record.met
  integer("location", "Met location", met.location, 0, 65535, nil, "met")
  integer("year", "Met year", met.date.year, 2000, 2255, nil, "met")
  integer("month", "Met month", met.date.month, 1, 12, nil, "met")
  integer("day", "Met day", met.date.day, 1, 31, nil, "met")
  rows[#rows + 1] = {
    role = "integer value",
    targetId = "party:field:metLevel",
    id = "metLevel",
    label = "Met level",
    value = met.level,
    editor = {
      kind = "integer",
      value = met.level,
      min = 1,
      max = 100,
      base = "decimal",
      setter = "met",
      fieldId = "level",
    },
    enabled = true,
  }
  return { rows = rows }
end

return PartyView
