-- Grouped native volatile definitions: the combatant-bound conditions
-- that live and die with one entry. Every key is flat lowercase; each
-- definition versions its typed state, binds only the finite mechanics
-- timings with its source category, and declares its stacking and
-- replacement transfer explicitly. Timed countdowns tick under the
-- expiration category, action gates under affliction. Duration bounds are
-- wide acceptance gates; the exact native rolls stay with the mechanics
-- that apply them.

local VolatileEffects = {}

VolatileEffects.MODULE = "libs.battle.src.gen4.behaviors.effects.VolatileEffects"
VolatileEffects.VERSION = 1

---@param version integer accepted state schema version
---@param state unknown
---@return table<string, unknown> the versioned record
local function checkVersioned(version, state)
  if type(state) ~= "table" then
    error("volatile states travel as records")
  end
  assert(type(state) == "table", "volatile state validated above")
  if state.version ~= version then
    error("volatile state carries its schema version")
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
    key = "confusion",
    stateVersion = 1,
    validateState = turnsState(1, 0, 8),
    -- The countdown ticks when the owner acts, never at turn end: a
    -- residual binding would spend the same turns twice.
    timings = {
      binding("beforeAction", "confusion", "affliction"),
    },
    lifecycle = lifecycle("replace", "clear"),
  },
  {
    key = "infatuation",
    stateVersion = 1,
    validateState = emptyState(1),
    timings = { binding("beforeAction", "infatuation", "affliction") },
    lifecycle = lifecycle("replace", "clear"),
  },
  -- Flinch carries a one-turn clock so an unspent mark expires at the
  -- residual pass instead of blocking a later turn: the native mark only
  -- ever gates the current turn.
  {
    key = "flinch",
    stateVersion = 1,
    validateState = turnsState(1, 0, 1),
    -- A one-turn marker: the block consumes it, and the turn-end pass
    -- silently clears markers inflicted after their owner already acted.
    timings = {
      binding("beforeAction", "flinch", "affliction"),
      binding("residual", "flinch", "expiration"),
    },
    lifecycle = lifecycle("replace", "clear"),
  },
  {
    key = "substitute",
    stateVersion = 1,
    validateState = (function()
      local function validateSubstitute(state)
        local checked = checkVersioned(1, state)
        local hp = checked.hp
        if type(hp) ~= "number" or hp % 1 ~= 0 or hp < 1 or hp > 9999 then
          error("the doll carries positive remaining health")
        end
        for name in pairs(checked) do
          if name ~= "version" and name ~= "hp" then
            error("the condition carries no further state")
          end
        end
        return { version = 1, hp = hp }
      end
      return validateSubstitute
    end)(),
    timings = { binding("beforeHit", "substitute", "affliction") },
    lifecycle = lifecycle("replace", "clear"),
  },
  {
    key = "leechseed",
    stateVersion = 1,
    validateState = emptyState(1),
    timings = { binding("residual", "leechseed", "affliction") },
    lifecycle = lifecycle("replace", "clear"),
  },
  {
    key = "aquaring",
    stateVersion = 1,
    validateState = emptyState(1),
    timings = { binding("residual", "aquaring", "recovery") },
    lifecycle = lifecycle("replace", "clear"),
  },
  {
    key = "curse",
    stateVersion = 1,
    validateState = emptyState(1),
    timings = { binding("residual", "curse", "affliction") },
    lifecycle = lifecycle("replace", "carry"),
  },
  {
    key = "perishsong",
    stateVersion = 1,
    validateState = turnsState(1, 0, 8),
    timings = { binding("residual", "perishsong", "expiration") },
    lifecycle = lifecycle("replace", "clear"),
  },
  -- Encore and disable name the forced move beside their countdown so
  -- the before-action timing can redirect or refuse the pending
  -- selection.
  {
    key = "encore",
    stateVersion = 1,
    validateState = (function()
      local function validateEncore(state)
        local checked = checkVersioned(1, state)
        local turns = checked.turns
        if type(turns) ~= "number" or turns % 1 ~= 0 or turns < 0 or turns > 8 then
          error("the encore countdown stays inside its declared bounds")
        end
        if type(checked.move) ~= "string" or checked.move == "" then
          error("encore names its forced move")
        end
        for name in pairs(checked) do
          if name ~= "version" and name ~= "turns" and name ~= "move" then
            error("the condition carries no further state")
          end
        end
        return { version = 1, turns = turns, move = checked.move }
      end
      return validateEncore
    end)(),
    timings = { binding("beforeAction", "encore", "affliction") },
    lifecycle = lifecycle("replace", "clear"),
  },
  {
    key = "disable",
    stateVersion = 1,
    validateState = (function()
      local function validateDisable(state)
        local checked = checkVersioned(1, state)
        local turns = checked.turns
        if type(turns) ~= "number" or turns % 1 ~= 0 or turns < 0 or turns > 8 then
          error("the disable countdown stays inside its declared bounds")
        end
        if type(checked.move) ~= "string" or checked.move == "" then
          error("disable names its refused move")
        end
        for name in pairs(checked) do
          if name ~= "version" and name ~= "turns" and name ~= "move" then
            error("the condition carries no further state")
          end
        end
        return { version = 1, turns = turns, move = checked.move }
      end
      return validateDisable
    end)(),
    timings = { binding("beforeAction", "disable", "affliction") },
    lifecycle = lifecycle("replace", "clear"),
  },
  {
    key = "taunt",
    stateVersion = 1,
    validateState = turnsState(1, 0, 8),
    timings = { binding("beforeAction", "taunt", "affliction") },
    lifecycle = lifecycle("replace", "clear"),
  },
  {
    key = "torment",
    stateVersion = 1,
    validateState = emptyState(1),
    timings = { binding("beforeAction", "torment", "affliction") },
    lifecycle = lifecycle("replace", "clear"),
  },
  {
    key = "embargo",
    stateVersion = 1,
    validateState = turnsState(1, 0, 8),
    timings = { binding("beforeAction", "embargo", "affliction") },
    lifecycle = lifecycle("replace", "clear"),
  },
  {
    key = "healblock",
    stateVersion = 1,
    validateState = turnsState(1, 0, 8),
    timings = { binding("beforeAction", "healblock", "affliction") },
    lifecycle = lifecycle("replace", "clear"),
  },
  {
    key = "imprison",
    stateVersion = 1,
    validateState = emptyState(1),
    timings = { binding("entry", "imprison", "affliction") },
    lifecycle = lifecycle("replace", "clear"),
  },
  -- Nightmare roots a sleeping defender for quarter-maximum residual
  -- damage until it wakes; the countdown survives while the victim
  -- sleeps and zeroes out on waking so the sweep drops it.
  {
    key = "nightmare",
    stateVersion = 1,
    validateState = turnsState(1, 0, 8),
    timings = { binding("residual", "nightmare", "affliction") },
    lifecycle = lifecycle("replace", "clear"),
  },
  -- Drowsiness counts the victim actions down to sleep through the
  -- before-action timing.
  {
    key = "yawn",
    stateVersion = 1,
    validateState = turnsState(1, 0, 8),
    timings = { binding("beforeAction", "yawn", "affliction") },
    lifecycle = lifecycle("replace", "clear"),
  },
  -- Binding traps for its countdown while dealing gradual damage
  -- through the residual pass.
  {
    key = "bind",
    stateVersion = 1,
    validateState = turnsState(1, 0, 8),
    timings = { binding("residual", "bind", "affliction") },
    lifecycle = lifecycle("replace", "clear"),
  },
  -- Pure trapping marker: escape and switch eligibility read it
  -- alongside the binding countdown. It binds the never-dispatched leave
  -- timing like the inert identity markers, so no pass collects it.
  {
    key = "trapped",
    stateVersion = 1,
    validateState = emptyState(1),
    timings = { binding("leave", "trapped", "affliction") },
    lifecycle = lifecycle("replace", "clear"),
  },
  -- Lock-on names the attacker whose next strike cannot miss; the
  -- accuracy checkpoint consumes it.
  {
    key = "lockon",
    stateVersion = 1,
    validateState = (function()
      local function validateLockon(state)
        local checked = checkVersioned(1, state)
        if type(checked.attacker) ~= "number" or checked.attacker % 1 ~= 0 or checked.attacker < 1 then
          error("lock-on names its aiming combatant")
        end
        for name in pairs(checked) do
          if name ~= "version" and name ~= "attacker" then
            error("the condition carries no further state")
          end
        end
        return { version = 1, attacker = checked.attacker }
      end
      return validateLockon
    end)(),
    timings = { binding("leave", "lockon", "affliction") },
    lifecycle = lifecycle("replace", "clear"),
  },
  -- Identification drops ghost immunity for normal and fighting
  -- strikes and pins negative evasion at zero until the entry leaves.
  {
    key = "foresight",
    stateVersion = 1,
    validateState = emptyState(1),
    timings = { binding("leave", "foresight", "affliction") },
    lifecycle = lifecycle("replace", "clear"),
  },
  -- Magnetic levitation grounds nothing for five turns.
  {
    key = "magnetrise",
    stateVersion = 1,
    validateState = turnsState(1, 0, 8),
    timings = { binding("residual", "magnetrise", "expiration") },
    lifecycle = lifecycle("replace", "clear"),
  },
  -- Ingrain roots one sixteenth of maximum health every residual pass
  -- until the entry leaves.
  {
    key = "ingrain",
    stateVersion = 1,
    validateState = emptyState(1),
    timings = { binding("residual", "ingrain", "recovery") },
    lifecycle = lifecycle("replace", "clear"),
  },
  -- Focus energy sharpens later strikes by two critical stages until
  -- the entry leaves; the strike checkpoint reads it.
  {
    key = "focusenergy",
    stateVersion = 1,
    validateState = emptyState(1),
    timings = { binding("leave", "focusenergy", "affliction") },
    lifecycle = lifecycle("replace", "clear"),
  },
}

--- Publishes every native volatile definition through the shared behavior
--- surface under its owning contributor.
---@param behaviors table<string, unknown> behavior builder carrying registerEffect
---@param owner string contributing owner recorded for each definition
function VolatileEffects.register(behaviors, owner)
  assert(type(behaviors) == "table", "volatile definitions register through the behavior surface")
  assert(type(behaviors.registerEffect) == "function", "volatile definitions register through the effect surface")
  assert(type(owner) == "string" and owner ~= "", "volatile definitions record their owner")
  for _, definition in ipairs(DEFINITIONS) do
    behaviors.registerEffect(behaviors, definition.key, {
      module = VolatileEffects.MODULE,
      version = VolatileEffects.VERSION,
      key = definition.key,
      stateVersion = definition.stateVersion,
      validateState = definition.validateState,
      timings = definition.timings,
      lifecycle = definition.lifecycle,
    }, owner)
  end
end

return VolatileEffects
