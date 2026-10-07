-- Shared synthetic builders for the effect lifecycle suites: owner scope
-- records, causal source records, effect definition records with explicit
-- stacking and transfer policy, and minimal residual contexts over fixed
-- speeds and health. Nothing here implements native law; suites load the
-- real owners and fail loudly while they are absent.

local EffectFixture = {}

EffectFixture.TIMINGS = {
  "entry",
  "beforeAction",
  "modifyStat",
  "beforeHit",
  "afterHit",
  "afterMove",
  "residual",
  "leave",
}

---@return table field-wide owner scope
function EffectFixture.fieldScope()
  return { kind = "field" }
end

---@param side integer side identity owning the instance
---@return table side owner scope
function EffectFixture.sideScope(side)
  return { kind = "side", side = side }
end

---@param position integer position identity owning the instance
---@return table position owner scope
function EffectFixture.positionScope(position)
  return { kind = "position", position = position }
end

---@param combatant integer combatant identity owning the instance
---@return table roster owner scope pinned to a combatant
function EffectFixture.rosterScope(combatant)
  return { kind = "roster", combatant = combatant }
end

---@param combatant integer combatant identity owning the instance
---@param activation integer entry token owning the instance
---@return table active owner scope pinned to one entry
function EffectFixture.activeScope(combatant, activation)
  return { kind = "active", combatant = combatant, activation = activation }
end

---@param combatant integer acting combatant identity
---@param activation integer|nil entry token when the source is fielded
---@return table causal source record
function EffectFixture.cause(combatant, activation)
  local source = { kind = "probe", combatant = combatant }
  if activation ~= nil then
    source.activation = activation
  end
  return source
end

---@param state unknown candidate typed state
---@return table the state record unchanged
function EffectFixture.identityState(state)
  assert(type(state) == "table", "effect state travels as a record")
  return state --[[@as table]]
end

---@param version integer state schema version the counter belongs to
---@param minimum integer smallest accepted counter value
---@param maximum integer largest accepted counter value
---@return fun(state: unknown): table strict counter validator
function EffectFixture.counterState(version, minimum, maximum)
  return function(state)
    assert(type(state) == "table", "counter state travels as a record")
    assert(state --[[@as table]].version == version, "counter state carries its schema version")
    local counter = state --[[@as table]].counter
    assert(
      type(counter) == "number" and counter % 1 == 0 and counter >= minimum and counter <= maximum,
      "counter state stays inside its declared bounds"
    )
    return { version = version, counter = counter }
  end
end

---@class EffectSpec
---@field key string definition identity under test
---@field stateVersion integer? accepted state schema version
---@field stacking string? replace, reject, or stack
---@field maxStacks integer? bound for stacking families
---@field transfer string? clear, carry, or position
---@field persistent boolean? true when the state belongs on the canonical mon
---@field timings table? timing bindings under test
---@field validate fun(state: unknown): table? state validator under test

---@param spec EffectSpec definition shape under test
---@return table effect definition record
function EffectFixture.define(spec)
  assert(type(spec.key) == "string" and spec.key ~= "", "effect definitions carry a non-empty key")
  local definition = {
    key = spec.key,
    stateVersion = spec.stateVersion or 1,
    validateState = spec.validate or EffectFixture.identityState,
    timings = spec.timings
      or {
        { timing = "residual", handler = spec.key, orderClass = "affliction" },
      },
    lifecycle = {
      stacking = spec.stacking or "replace",
      transfer = spec.transfer or "clear",
      persistent = spec.persistent or false,
    },
  }
  if spec.maxStacks ~= nil then
    definition.lifecycle.maxStacks = spec.maxStacks
  end
  return definition
end

---@param timing string timing under test
---@param orderClass string source mechanic category under test
---@return table timing binding record naming its handler after its effect
function EffectFixture.binding(timing, orderClass)
  return { timing = timing, handler = timing .. "-handler", orderClass = orderClass }
end

---@param speeds table<integer, integer> sampled speed per combatant
---@param health table<integer, integer> battle-local health per combatant
---@param seed integer fixed generator state for the pass
---@return table residual context over synthetic combatants
function EffectFixture.residualContext(speeds, health, seed)
  local BattleRng = require("libs.battle.src.gen4.BattleRng")
  return { speeds = speeds, health = health, stream = BattleRng.new(seed) }
end

---@param entries table[] collected dispatch entries under test
---@return integer[] instance identities in dispatch order
function EffectFixture.collectedIds(entries)
  local ids = {}
  for _, entry in ipairs(entries) do
    ids[#ids + 1] = entry.instance.id
  end
  return ids
end

---@param events table[] emitted event records under test
---@return string[] compact event signatures in emission order
function EffectFixture.eventSignatures(events)
  local signatures = {}
  for _, event in ipairs(events) do
    signatures[#signatures + 1] = tostring(event.kind) .. ":" .. tostring(event.combatant or event.side or "-")
  end
  return signatures
end

return EffectFixture
