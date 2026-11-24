-- Accuracy and hit-prevention semantics. Ordinary checks draw before
-- protection and semi-invulnerability; an explicit skipped check still
-- respects both without a draw. Rolled checks compare (draw % 100) + 1
-- against the final percentage, including zero and full accuracy. Signed
-- stages merge, clamp once, and use the canonical stage ratio. Every
-- outcome keeps its own reason for callers.

local StatStages = require("libs.battle.src.gen4.StatStages")

---@class HitTarget
---@field kind string
---@field position integer?

---@class AccuracyQuery
---@field accuracy integer?
---@field target HitTarget
---@field cause table<string, unknown>
---@field protected boolean
---@field semiInvulnerable boolean?
---@field skipCheck boolean?
---@field accuracyStage integer? signed battle-local accuracy stage of the user
---@field evasionStage integer? signed battle-local evasion stage of the target
---@field tutorial boolean? true while the scripted lesson skips its accuracy rolls

---@class HitResolution
---@field kind "hit"|"miss"|"protected"|"immune"|"unreachable"|"failed"
---@field reason string
---@field target HitTarget
---@field cause table<string, unknown>
local Accuracy = {}

Accuracy.ROLL_MODULUS = 100

---@param query AccuracyQuery hit query under test
local function requireQuery(query)
  assert(type(query) == "table", "hit prevention reads its query")
  assert(type(query.target) == "table" and type(query.target.kind) == "string", "hit prevention names its target")
  assert(type(query.cause) == "table", "hit prevention carries its semantic cause")
  if query.accuracy ~= nil then
    assert(
      type(query.accuracy) == "number" and query.accuracy % 1 == 0 and query.accuracy >= 0,
      "accuracy names a non-negative integer percentage"
    )
  end
  if query.accuracyStage ~= nil then
    assert(
      type(query.accuracyStage) == "number" and query.accuracyStage % 1 == 0,
      "accuracy stages are integer stage deltas"
    )
  end
  if query.evasionStage ~= nil then
    assert(
      type(query.evasionStage) == "number" and query.evasionStage % 1 == 0,
      "evasion stages are integer stage deltas"
    )
  end
end

---@param query AccuracyQuery hit query under test
---@param stream BattleRng labeled native battle stream
---@return HitResolution prevention outcome with its exact draw count
function Accuracy.resolve(query, stream)
  requireQuery(query)
  assert(type(stream) == "table" and type(stream.nextU16) == "function", "rolled checks draw from the battle stream")
  -- Tutorial strikes and explicit skipped checks spend no accuracy draw.
  if query.tutorial == true then
    if query.protected == true then
      return { kind = "protected", reason = "protection", target = query.target, cause = query.cause }
    end
    if query.semiInvulnerable == true then
      return { kind = "unreachable", reason = "semi_invulnerable", target = query.target, cause = query.cause }
    end
    return { kind = "hit", reason = "tutorial_skipped", target = query.target, cause = query.cause }
  end
  if query.skipCheck == true then
    if query.protected == true then
      return { kind = "protected", reason = "protection", target = query.target, cause = query.cause }
    end
    if query.semiInvulnerable == true then
      return { kind = "unreachable", reason = "semi_invulnerable", target = query.target, cause = query.cause }
    end
    return { kind = "hit", reason = "check_skipped", target = query.target, cause = query.cause }
  end
  local hit = true
  if query.accuracy ~= nil then
    local accuracyStage = query.accuracyStage or 0
    local evasionStage = query.evasionStage or 0
    local effectiveStage = accuracyStage - evasionStage
    if effectiveStage > 6 then
      effectiveStage = 6
    elseif effectiveStage < -6 then
      effectiveStage = -6
    end
    local ratio = StatStages.multiplier(effectiveStage, "accuracy")
    local chance = math.floor((query.accuracy * ratio.numerator) / ratio.denominator)
    local draw = stream:nextU16("accuracy_check", query.cause)
    local roll = (draw % Accuracy.ROLL_MODULUS) + 1
    hit = roll <= chance
  end
  -- Ordinary accuracy draws happen before protection checks in the retail
  -- battle flow; prevention still takes precedence over the roll result.
  if query.protected == true then
    return { kind = "protected", reason = "protection", target = query.target, cause = query.cause }
  end
  if query.semiInvulnerable == true then
    return { kind = "unreachable", reason = "semi_invulnerable", target = query.target, cause = query.cause }
  end
  if not hit then
    return { kind = "miss", reason = "accuracy_miss", target = query.target, cause = query.cause }
  end
  return {
    kind = "hit",
    reason = query.accuracy == nil and "no_accuracy_check" or "accuracy_roll",
    target = query.target,
    cause = query.cause,
  }
end

return Accuracy
