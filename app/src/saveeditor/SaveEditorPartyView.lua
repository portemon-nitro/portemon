-- Builds stable raw Pokemon editor and inspection rows from version catalogs.

local Errors = require("libs.errors.src.Errors")
local Experience = require("libs.mons.src.gen4.Experience")
local Personality = require("libs.mons.src.gen4.Personality")
local HgssMonService = require("libs.hgss.src.mons.HgssMonService")

local PartyView = {}
PartyView.__index = PartyView

---@alias SaveEditorPartyOptionKey string|integer
---@alias SaveEditorPartyOptionKeys table<integer|string, SaveEditorPartyOptionKey|boolean>
---@class SaveEditorPartyView
---@field private context table<string, unknown>
---@field private optionCache table<string, { key: string, label: string }[]>
---@field options fun(self: SaveEditorPartyView, key: string, keysFor: fun(): SaveEditorPartyOptionKeys, labelFor: fun(key: string): string, numericKeys: boolean?): { key: string, label: string }[]
---@field rows fun(self: SaveEditorPartyView, mon: table<string, unknown>, projection: SaveEditorMonProjection, subpage: string, editable: boolean, focusId: string?): table[]

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

local function dependencyHelp(focusId, subpage)
  local fieldId = type(focusId) == "string"
      and (focusId:match("^party:field:(.+)$") or focusId:match("^party:readonly:(.+)$"))
    or nil
  if fieldId == "experience" then
    return "Experience determines level; level, IVs, and EVs determine stats."
  elseif fieldId == "personality" then
    return "Personality determines nature and contributes to gender and shininess. Ability is stored separately."
  elseif fieldId == "trainerId" then
    return "OT trainer ID combines with Personality to determine shininess."
  elseif fieldId and (fieldId:match("^iv:") or fieldId:match("^ev:")) then
    return "IVs and EVs contribute to the computed stats."
  elseif fieldId == "level" and subpage == "Origin" then
    return "met level must track the experience-derived level"
  end
  return "Derived values are read only. Ability remains stored and is not replaced from Personality."
end

---@param mon table<string, unknown>
---@param projection SaveEditorMonProjection
---@param subpage string
---@param editable boolean
---@param focusId string?
---@return table[]
function PartyView:rows(mon, projection, subpage, editable, focusId)
  assert(
    subpage == "Identity" or subpage == "Training" or subpage == "Stats" or subpage == "Moves" or subpage == "Origin",
    "unsupported Party subpage"
  )
  local context = assert(self.context)
  local catalog = assert(context.monCatalog)
  local rows = {}
  local function add(fieldId, label, value, role, editor)
    rows[#rows + 1] = {
      role = editable and role or "read-only value",
      targetId = editable and editor and ("party:field:" .. fieldId) or ("party:readonly:" .. fieldId),
      id = fieldId,
      label = label,
      value = value,
      editor = editable and editor or nil,
      enabled = editable and editor ~= nil,
    }
  end
  local function integer(fieldId, label, value, minimum, maximum, base, setter)
    add(fieldId, label, value, "integer value", {
      kind = "integer",
      value = value,
      min = minimum,
      max = maximum,
      base = base or "decimal",
      setter = setter or "scalar",
      fieldId = fieldId,
    })
  end
  local function choice(fieldId, label, value, options, setter, convert)
    add(fieldId, label, value, "named choice", {
      kind = "choice",
      value = value,
      options = options,
      setter = setter or "scalar",
      fieldId = fieldId,
      convert = convert,
    })
  end
  local function textName(fieldId, label, value, kind, subject)
    add(fieldId, label, value, "action", {
      kind = "name",
      value = value or "",
      nameKind = kind,
      subject = subject,
      setter = fieldId == "nickname" and "scalar" or "origin",
      fieldId = fieldId,
    })
    if fieldId == "nickname" and editable then
      rows[#rows + 1] = {
        role = "action",
        targetId = "party:clear-nickname",
        id = "clear-nickname",
        label = "Clear nickname",
        enabled = true,
      }
    end
  end

  if subpage == "Identity" then
    local species = catalog:species(mon.species)
    local speciesOptions = self:options("species", function()
      return catalog:speciesKeys()
    end, function(key)
      return catalog:species(key).name or key
    end)
    local forms = {}
    for formId in pairs(species.forms) do
      forms[#forms + 1] = formId
    end
    table.sort(forms)
    local formOptions = self:options("forms:" .. mon.species, function()
      return forms
    end, function(key)
      return tostring(key)
    end)
    local abilityOptions = {}
    local formOk, form = pcall(catalog.form, catalog, mon.species, mon.form)
    if formOk then
      abilityOptions = self:options("abilities:" .. mon.species .. ":" .. tostring(mon.form), function()
        return form.abilities
      end, function(key)
        return catalog:ability(key).name or key
      end)
    end
    local itemCatalog = assert(context.itemCatalog)
    local heldOptions = self:options("items", function()
      return itemCatalog:itemKeys()
    end, function(key)
      return itemCatalog:item(key).name or key
    end)
    choice("species", "Species", mon.species, speciesOptions)
    choice("form", "Form", tostring(mon.form), formOptions, "scalar", "integer")
    textName(
      "nickname",
      "Nickname",
      mon.nickname,
      "pokemon",
      { kind = "pokemon", species = assert(species.nativeId), form = mon.form }
    )
    integer("personality", "Personality", mon.personality, 0, 4294967295, "hex")
    choice("ability", "Ability", mon.ability, abilityOptions)
    choice("heldItem", "Held item", mon.heldItem, heldOptions)
    local abilityId = "Unavailable"
    local abilityOk, abilityDefinition = pcall(catalog.ability, catalog, mon.ability)
    if abilityOk then
      abilityId = abilityDefinition.nativeId
    elseif not Errors.is(abilityDefinition) then
      error(abilityDefinition, 0)
    end
    add("species-native-id", "Native species ID", species.nativeId)
    add("form-native-id", "Native form ID", mon.form)
    add("ability-native-id", "Native ability ID", abilityId)
    ---@type string|integer
    local abilitySlot = "Unavailable"
    if formOk and projection.nature ~= nil then
      abilitySlot = Personality.abilitySlot(#form.abilities, mon.personality)
    end
    add("pid-ability-slot", "PID ability slot", abilitySlot)
    add("nature", "Nature (derived)", projection.nature or "Unavailable")
    add("gender", "Gender (derived)", projection.gender or "Unavailable")
    add("shiny", "Shiny (derived)", projection.shiny == nil and "Unavailable" or (projection.shiny and "Yes" or "No"))
  elseif subpage == "Training" then
    local species = catalog:species(mon.species)
    local expRange = "Unavailable"
    if projection.level then
      local curve = catalog:growthCurve(species.growthCurve)
      local lower = Experience.expFor(curve, projection.level)
      local upper = projection.level < 100 and Experience.expFor(curve, projection.level + 1) or nil
      expRange = tostring(lower) .. "–" .. tostring(upper or "MAX")
    end
    integer("experience", "Experience", mon.experience, 0, 4294967295)
    integer("friendship", "Friendship", mon.friendship, 0, 255)
    add("level", "Level (derived)", projection.level or "Unavailable")
    add("growth-curve", "Growth curve", species.growthCurve)
    add("exp-interval", "Current level EXP interval", expRange)
  elseif subpage == "Stats" then
    local names = {
      { "hp", "HP" },
      { "attack", "Attack" },
      { "defense", "Defense" },
      { "speed", "Speed" },
      { "specialAttack", "Special Attack" },
      { "specialDefense", "Special Defense" },
    }
    for _, stat in ipairs(names) do
      integer("iv:" .. stat[1], stat[2] .. " IV", mon.ivs[stat[1]], 0, 31, nil, "iv")
      integer("ev:" .. stat[1], stat[2] .. " EV", mon.evs[stat[1]], 0, 255, nil, "ev")
      add("stat:" .. stat[1], stat[2] .. " (derived)", projection.stats and projection.stats[stat[1]] or "Unavailable")
    end
    add("max-hp", "Maximum HP (derived)", projection.stats and projection.stats.hp or "Unavailable")
    integer("currentHp", "Current HP", mon.condition.currentHp, 0, 4294967295)
    integer("status", "Status", mon.condition.status, 0, 4294967295, "hex")
    local evTotal = 0
    for _, value in pairs(mon.evs) do
      evTotal = evTotal + value
    end
    add("ev-total", "EV total", evTotal)
    add("ev-limit", "EV limit", "510")
  elseif subpage == "Moves" then
    for slot0, move in ipairs(mon.moves) do
      local index0 = slot0 - 1
      local prefix = "move:" .. index0 .. ":"
      local moveOptions = self:options("moves", function()
        return catalog:moveKeys()
      end, function(key)
        return catalog:move(key).name or key
      end)
      choice(prefix .. "move", "Move " .. (index0 + 1), move.move, moveOptions, "move")
      local moveData = catalog:move(move.move)
      add(prefix .. "native-id", "Move native ID", moveData.nativeId)
      add(prefix .. "type", "Move type", moveData.type)
      add(prefix .. "power", "Move power", moveData.power)
      add(prefix .. "accuracy", "Move accuracy", moveData.accuracy)
      add(prefix .. "base-pp", "Base PP allowance", moveData.basePp)
      add(
        prefix .. "allowed-pp",
        "PP allowance at current Ups",
        moveData.basePp + math.floor(moveData.basePp * move.ppUps / 5)
      )
      integer(prefix .. "pp", "PP", move.pp, 0, 255, nil, "move")
      integer(prefix .. "ppUps", "PP Ups", move.ppUps, 0, 3, nil, "move")
      rows[#rows + 1] =
        { role = "action", targetId = "party:move:remove:" .. index0, label = "Remove move " .. (index0 + 1) }
    end
    if #mon.moves < 4 then
      rows[#rows + 1] = { role = "action", targetId = "party:move:add", label = "Add move" }
    end
  else
    local origin, met = mon.origin, mon.met
    local genders = { { key = "0", label = "Male" }, { key = "1", label = "Female" } }
    integer("trainerId", "Trainer ID", origin.trainerId, 0, 4294967295, "hex", "origin")
    textName("trainerName", "Trainer name", origin.trainerName, "player", {
      kind = "player",
      gender = origin.trainerGender,
    })
    choice("trainerGender", "Trainer gender", tostring(origin.trainerGender), genders, "origin", "integer")
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
      for _, key in ipairs(context.itemCatalog:itemKeys()) do
        if context.itemCatalog:item(key).pocket == "balls" then
          keys[#keys + 1] = key
        end
      end
      return keys
    end, function(key)
      return context.itemCatalog:item(key).name or key
    end)
    choice("ball", "Ball", origin.ball, ballOptions, "origin")
    integer("location", "Met location", met.location, 0, 65535, nil, "met")
    integer("year", "Met year", met.date.year, 2000, 2255, nil, "met")
    integer("month", "Met month", met.date.month, 1, 12, nil, "met")
    integer("day", "Met day", met.date.day, 1, 31, nil, "met")
    integer("level", "Met level", met.level, 1, 100, nil, "met")
    integer("terrain", "Met terrain", met.terrain, 0, 255, nil, "met")
  end
  rows[#rows + 1] = {
    role = "read-only value",
    targetId = "party:readonly:help",
    id = "help",
    label = "Field help",
    value = dependencyHelp(focusId, subpage),
  }
  return rows
end

return PartyView
