-- Entry ability families: weather setters, stat interference, and
-- scouting announcements that fire when a combatant takes the field.
-- Each announcement is a trigger event carrying the source identity with
-- the affected holder and, for weather setters, the weather they
-- establish; simultaneous entries
-- resolve by sampled speed in the dispatch owner, so registration order
-- never decides. Abilities with no entry checkpoint live in the sibling
-- timing families instead.

local EntryAbilities = {}

---@param instance table<string, unknown> dispatched effect instance under handling
---@return integer? holder combatant owning the instance
local function holderOf(instance)
  local scope = instance.scope
  if type(scope) ~= "table" then
    return nil
  end
  local combatant = (scope --[[@as table<string, unknown>]]).combatant
  if type(combatant) ~= "number" then
    return nil
  end
  return combatant
end

local ENTRY_WEATHER = {
  DRIZZLE = "rain",
  DROUGHT = "sun",
  SAND_STREAM = "sand",
  SNOW_WARNING = "hail",
}

local ENTRY_ANNOUNCE = {
  "INTIMIDATE",
  "TRACE",
  "DOWNLOAD",
  "FRISK",
  "FOREWARN",
  "ANTICIPATION",
  "FORECAST",
  "MULTITYPE",
}

local ENTRY_SUPPRESS_WEATHER = {
  "CLOUD_NINE",
  "AIR_LOCK",
}

---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> entry pass context under handling
---@return table<string, unknown> entry announcement carrying the source identity
local function announceEntry(instance, context)
  assert(type(context) == "table", "entry handlers read their pass context")
  return { kind = "trigger", key = instance.key, combatant = holderOf(instance) }
end

---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> entry pass context under handling
---@return table<string, unknown> weather announcement naming the established weather
local function announceWeather(instance, context)
  assert(type(context) == "table", "entry handlers read their pass context")
  return { kind = "trigger", key = instance.key, combatant = holderOf(instance), weather = ENTRY_WEATHER[instance.key] }
end

---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> entry pass context under handling
---@return table<string, unknown> suppression announcement clearing established weather
local function announceSuppression(instance, context)
  assert(type(context) == "table", "entry handlers read their pass context")
  return { kind = "trigger", key = instance.key, combatant = holderOf(instance), weather = "none" }
end

--- Binds the entry timing handlers into the owner table.
---@param owned table<string, fun(instance: table<string, unknown>, context: table<string, unknown>): table<string, unknown>?> handler owner receiving the family bindings
function EntryAbilities.register(owned)
  assert(type(owned) == "table", "entry abilities register into their owner table")
  for _, key in ipairs(ENTRY_ANNOUNCE) do
    owned[key] = announceEntry
  end
  for key in pairs(ENTRY_WEATHER) do
    owned[key] = announceWeather
  end
  for _, key in ipairs(ENTRY_SUPPRESS_WEATHER) do
    owned[key] = announceSuppression
  end
end

return EntryAbilities
