-- Native weather, side, hazard, and delayed slot definitions: the
-- conditions owned above a single entry. Screens and hazards attach to a
-- side, weather and room states to the field, and delayed strikes and
-- wishes to a position so they outlive their occupant. Every key is flat
-- lowercase; each definition versions its typed state, binds only the
-- finite mechanics timings with its source category, and declares its
-- stacking and transfer explicitly. No uniform timer rule covers the
-- families: hazards layer, screens refresh, and weather replaces.

local FieldEffects = {}

FieldEffects.MODULE = "libs.battle.src.gen4.behaviors.effects.FieldEffects"
FieldEffects.VERSION = 1

---@param version integer accepted state schema version
---@param state unknown
---@return table<string, unknown> the versioned record
local function checkVersioned(version, state)
  if type(state) ~= "table" then
    error("field states travel as records")
  end
  assert(type(state) == "table", "field state validated above")
  if state.version ~= version then
    error("field state carries its schema version")
  end
  return state
end

---@param version integer
---@return fun(state: unknown): table<string, unknown> validator accepting only the version record
local function emptyState(version)
  local function validateEmpty(state)
    local checked = checkVersioned(version, state)
    for name in pairs(checked) do
      if name ~= "version" then
        error("the condition carries no further state")
      end
    end
    return { version = version }
  end
  return validateEmpty
end

---@param version integer
---@param minimum integer
---@param maximum integer
---@return fun(state: unknown): table<string, unknown> validator for a bounded turn counter
local function turnsState(version, minimum, maximum)
  local function validateTurns(state)
    local checked = checkVersioned(version, state)
    local turns = checked.turns
    if type(turns) ~= "number" or turns % 1 ~= 0 or turns < minimum or turns > maximum then
      error("the turn counter stays inside its declared bounds")
    end
    for name in pairs(checked) do
      if name ~= "version" and name ~= "turns" then
        error("the condition carries no further state")
      end
    end
    return { version = version, turns = turns }
  end
  return validateTurns
end

---@param version integer
---@param minimum integer
---@param maximum integer
---@return fun(state: unknown): table<string, unknown> validator for a bounded hazard layer count
local function layersState(version, minimum, maximum)
  local function validateLayers(state)
    local checked = checkVersioned(version, state)
    local layers = checked.layers
    if type(layers) ~= "number" or layers % 1 ~= 0 or layers < minimum or layers > maximum then
      error("the hazard layer count stays inside its declared bounds")
    end
    for name in pairs(checked) do
      if name ~= "version" and name ~= "layers" then
        error("the condition carries no further state")
      end
    end
    return { version = version, layers = layers }
  end
  return validateLayers
end

---@param timing string
---@param handler string
---@param orderClass string
---@return table<string, string> timing binding record
local function binding(timing, handler, orderClass)
  return { timing = timing, handler = handler, orderClass = orderClass }
end

---@param stacking string
---@param transfer string
---@param maxStacks integer?
---@return table<string, unknown> lifecycle policy record
local function lifecycle(stacking, transfer, maxStacks)
  local policy = { stacking = stacking, transfer = transfer, persistent = false }
  if maxStacks ~= nil then
    policy.maxStacks = maxStacks
  end
  return policy
end

local DEFINITIONS = {
  {
    key = "reflect",
    stateVersion = 1,
    validateState = turnsState(1, 0, 8),
    timings = {
      binding("entry", "reflect", "affliction"),
      binding("residual", "reflect", "expiration"),
    },
    lifecycle = lifecycle("replace", "clear"),
  },
  {
    key = "lightscreen",
    stateVersion = 1,
    validateState = turnsState(1, 0, 8),
    timings = {
      binding("entry", "lightscreen", "affliction"),
      binding("residual", "lightscreen", "expiration"),
    },
    lifecycle = lifecycle("replace", "clear"),
  },
  {
    key = "safeguard",
    stateVersion = 1,
    validateState = turnsState(1, 0, 8),
    timings = {
      binding("entry", "safeguard", "affliction"),
      binding("residual", "safeguard", "expiration"),
    },
    lifecycle = lifecycle("replace", "clear"),
  },
  {
    key = "mist",
    stateVersion = 1,
    validateState = turnsState(1, 0, 8),
    timings = {
      binding("entry", "mist", "affliction"),
      binding("residual", "mist", "expiration"),
    },
    lifecycle = lifecycle("replace", "clear"),
  },
  {
    key = "stealthrock",
    stateVersion = 1,
    validateState = emptyState(1),
    timings = { binding("entry", "stealthrock", "affliction") },
    lifecycle = lifecycle("reject", "clear"),
  },
  {
    key = "spikes",
    stateVersion = 1,
    validateState = layersState(1, 1, 3),
    timings = { binding("entry", "spikes", "affliction") },
    lifecycle = lifecycle("stack", "clear", 3),
  },
  {
    key = "toxicspikes",
    stateVersion = 1,
    validateState = layersState(1, 1, 2),
    timings = { binding("entry", "toxicspikes", "affliction") },
    lifecycle = lifecycle("stack", "clear", 2),
  },
  {
    key = "raindance",
    stateVersion = 1,
    validateState = turnsState(1, 0, 8),
    timings = {
      binding("entry", "raindance", "weather"),
      binding("residual", "raindance", "weather"),
    },
    lifecycle = lifecycle("replace", "clear"),
  },
  {
    key = "sunnyday",
    stateVersion = 1,
    validateState = turnsState(1, 0, 8),
    timings = {
      binding("entry", "sunnyday", "weather"),
      binding("residual", "sunnyday", "weather"),
    },
    lifecycle = lifecycle("replace", "clear"),
  },
  {
    key = "sandstorm",
    stateVersion = 1,
    validateState = turnsState(1, 0, 8),
    timings = {
      binding("entry", "sandstorm", "weather"),
      binding("residual", "sandstorm", "weather"),
    },
    lifecycle = lifecycle("replace", "clear"),
  },
  {
    key = "hail",
    stateVersion = 1,
    validateState = turnsState(1, 0, 8),
    timings = {
      binding("entry", "hail", "weather"),
      binding("residual", "hail", "weather"),
    },
    lifecycle = lifecycle("replace", "clear"),
  },
  {
    key = "gravity",
    stateVersion = 1,
    validateState = turnsState(1, 0, 8),
    timings = {
      binding("entry", "gravity", "affliction"),
      binding("residual", "gravity", "expiration"),
    },
    lifecycle = lifecycle("replace", "clear"),
  },
  {
    key = "trickroom",
    stateVersion = 1,
    validateState = turnsState(1, 0, 8),
    timings = {
      binding("entry", "trickroom", "affliction"),
      binding("residual", "trickroom", "expiration"),
    },
    lifecycle = lifecycle("replace", "clear"),
  },
  {
    key = "futuresight",
    stateVersion = 1,
    validateState = turnsState(1, 0, 8),
    timings = { binding("residual", "futuresight", "expiration") },
    lifecycle = lifecycle("replace", "position"),
  },
  {
    key = "wish",
    stateVersion = 1,
    validateState = turnsState(1, 0, 8),
    timings = { binding("residual", "wish", "recovery") },
    lifecycle = lifecycle("replace", "position"),
  },
}

--- Publishes every native field, side, and delayed slot definition
--- through the shared behavior surface under its owning contributor.
---@param behaviors table<string, unknown> behavior builder carrying registerEffect
---@param owner string contributing owner recorded for each definition
function FieldEffects.register(behaviors, owner)
  assert(type(behaviors) == "table", "field definitions register through the behavior surface")
  assert(type(behaviors.registerEffect) == "function", "field definitions register through the effect surface")
  assert(type(owner) == "string" and owner ~= "", "field definitions record their owner")
  for _, definition in ipairs(DEFINITIONS) do
    behaviors.registerEffect(behaviors, definition.key, {
      module = FieldEffects.MODULE,
      version = FieldEffects.VERSION,
      key = definition.key,
      stateVersion = definition.stateVersion,
      validateState = definition.validateState,
      timings = definition.timings,
      lifecycle = definition.lifecycle,
    }, owner)
  end
end

return FieldEffects
