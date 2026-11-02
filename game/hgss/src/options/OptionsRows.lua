-- The one private Options catalogue for the seven setting rows: their fixed
-- order, kinds, ordered semantic stops, and per-stop display labels. This
-- module is pure data and pure resolvers: it stores no draft, focus, scroll,
-- resources, or selection state, and it is imported only by the Options
-- feature (geometry, screen state, and painter). Generated semantic labels
-- supply the visible text where the contract curates it; the Turbo label is
-- project-authored for the fastest stop, which the generated contract does
-- not curate.

local OptionsRows = {}

OptionsRows.ROW_IDS = {
  "textSpeed",
  "battleScene",
  "battleStyle",
  "soundMode",
  "textFrame",
  "volume",
  "battleSpeed",
}

local KINDS = {
  textSpeed = "choice",
  battleScene = "choice",
  battleStyle = "choice",
  soundMode = "choice",
  textFrame = "cycle",
  volume = "slider",
  battleSpeed = "slider",
}

local DISCRETE_VALUES = {
  textSpeed = { "mid", "fast", "fastest" },
  battleScene = { true, false },
  battleStyle = { "shift", "set" },
  soundMode = { "stereo", "mono" },
}

local SPEED_STOPS = { 1, 2, 4 }
local FRAME_COUNT = 20
local VOLUME_COUNT = 101

---@param rowId string
local function checkRow(rowId)
  if KINDS[rowId] == nil then
    error("unknown options row " .. tostring(rowId), 0)
  end
end

---@param rowId string
---@return string "choice"|"cycle"|"slider"
function OptionsRows.rowKind(rowId)
  checkRow(rowId)
  return KINDS[rowId]
end

---@param rowId string
---@return integer the published value stop count
function OptionsRows.valueCount(rowId)
  checkRow(rowId)
  if rowId == "textSpeed" then
    return #DISCRETE_VALUES.textSpeed
  elseif rowId == "textFrame" then
    return FRAME_COUNT
  elseif rowId == "volume" then
    return VOLUME_COUNT
  elseif rowId == "battleSpeed" then
    return #SPEED_STOPS
  end
  return 2
end

---@param rowId string
---@param value unknown the semantic stored value
---@return integer the 1-based UI stop index
function OptionsRows.indexFor(rowId, value)
  checkRow(rowId)
  if rowId == "textFrame" then
    assert(type(value) == "number" and value % 1 == 0 and value >= 0 and value < FRAME_COUNT, "frame stays 0..19")
    return value + 1
  elseif rowId == "volume" then
    assert(type(value) == "number" and value % 1 == 0 and value >= 0 and value < VOLUME_COUNT, "volume stays 0..100")
    return value + 1
  elseif rowId == "battleSpeed" then
    for index, stop in ipairs(SPEED_STOPS) do
      if stop == value then
        return index
      end
    end
    error("unknown battle speed " .. tostring(value), 0)
  end
  local values = assert(DISCRETE_VALUES[rowId], "discrete rows carry their values")
  for index, entry in ipairs(values) do
    if entry == value then
      return index
    end
  end
  error("unknown options value " .. tostring(value) .. " for row " .. tostring(rowId), 0)
end

---@param rowId string
---@param index integer the 1-based UI stop index
---@return unknown the semantic stored value
function OptionsRows.valueAt(rowId, index)
  checkRow(rowId)
  assert(type(index) == "number" and index % 1 == 0, "option stops stay integral")
  if rowId == "textFrame" then
    assert(index >= 1 and index <= FRAME_COUNT, "frame stops stay 1..20")
    return index - 1
  elseif rowId == "volume" then
    assert(index >= 1 and index <= VOLUME_COUNT, "volume stops stay 1..101")
    return index - 1
  elseif rowId == "battleSpeed" then
    local stop = SPEED_STOPS[index]
    assert(stop ~= nil, "battle speed stops stay 1..3")
    return stop
  end
  local values = assert(DISCRETE_VALUES[rowId], "discrete rows carry their values")
  local value = values[index]
  assert(value ~= nil, "option stops stay within their row")
  return value
end

---@param group table<string, unknown>? one generated value-label group
---@param keys string[] ordered lookup keys, first hit wins
---@return string? the generated text, if a key resolves
local function generatedText(group, keys)
  if type(group) ~= "table" then
    return nil
  end
  for _, key in ipairs(keys) do
    local entry = group[key]
    if type(entry) == "table" and type(entry.text) == "string" then
      return entry.text
    end
  end
  return nil
end

---@param rowId string
---@param labels table<string, unknown>? generated semantic labels
---@return string[]? one visible label per discrete stop, nil for cycle/slider rows
function OptionsRows.choiceLabels(rowId, labels)
  checkRow(rowId)
  if KINDS[rowId] ~= "choice" then
    return nil
  end
  local group = nil
  local keys = nil
  local fallbacks = nil
  if rowId == "textSpeed" then
    group = labels ~= nil and labels.textSpeedValues or nil
    keys = { { "mid" }, { "fast" }, { "fastest", "turbo" } }
    fallbacks = { "MID", "FAST", "TURBO" }
  elseif rowId == "battleScene" then
    group = labels ~= nil and labels.battleSceneValues or nil
    keys = { { "on" }, { "off" } }
    fallbacks = { "ON", "OFF" }
  elseif rowId == "battleStyle" then
    group = labels ~= nil and labels.battleStyleValues or nil
    keys = { { "shift" }, { "set" } }
    fallbacks = { "SHIFT", "SET" }
  else
    assert(rowId == "soundMode", "unknown discrete options row " .. tostring(rowId))
    group = labels ~= nil and labels.soundModeValues or nil
    keys = { { "stereo" }, { "mono" } }
    fallbacks = { "STEREO", "MONO" }
  end
  local ordered = {}
  for stop, candidates in ipairs(keys) do
    ordered[stop] = generatedText(group, candidates) or fallbacks[stop]
  end
  return ordered
end

return OptionsRows
