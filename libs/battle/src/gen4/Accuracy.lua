-- Accuracy and hit-prevention semantics. Protection and semi-invulnerable
-- positions are decided before the roll and consume no draws; moves that
-- skip the ordinary accuracy check still respect both. Rolled checks
-- compare one labeled battle-stream draw against floor(accuracy*65536/100),
-- so full accuracy still rolls its check while a missing accuracy simply
-- hits. Battle-local accuracy and evasion stages reshape the percentage
-- through the exact native thirds law before the threshold derives, so a
-- missing stage reads as flat. Every outcome names a distinct reason so callers never conflate a
-- rolled miss with protection, an unreachable target, or a skipped check.

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

---@class HitResolution
---@field kind "hit"|"miss"|"protected"|"immune"|"unreachable"|"failed"
---@field reason string
---@field target HitTarget
---@field cause table<string, unknown>
local Accuracy = {}

Accuracy.ROLL_MODULUS = 65536

---@param query AccuracyQuery hit query under test
local function requireQuery(query)
  assert(type(query) == "table", "hit prevention reads its query")
  assert(type(query.target) == "table" and type(query.target.kind) == "string", "hit prevention names its target")
  assert(type(query.cause) == "table", "hit prevention carries its semantic cause")
  if query.accuracy ~= nil then
    assert(
      type(query.accuracy) == "number" and query.accuracy % 1 == 0 and query.accuracy >= 0 and query.accuracy <= 100,
      "accuracy names an integer percentage in 0..100"
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

---@param stage integer signed stage delta under the thirds law
---@return integer numerator of the exact native ratio
---@return integer denominator of the exact native ratio
local function thirdsRatio(stage)
  if stage >= 0 then
    return 3 + stage, 3
  end
  return 3, 3 - stage
end

---@param query AccuracyQuery hit query under test
---@param stream BattleRng labeled native battle stream
---@return HitResolution prevention outcome with its exact draw count
function Accuracy.resolve(query, stream)
  requireQuery(query)
  assert(type(stream) == "table" and type(stream.nextU16) == "function", "rolled checks draw from the battle stream")
  if query.protected == true then
    return { kind = "protected", reason = "protection", target = query.target, cause = query.cause }
  end
  if query.semiInvulnerable == true then
    return { kind = "unreachable", reason = "semi_invulnerable", target = query.target, cause = query.cause }
  end
  if query.skipCheck == true then
    return { kind = "hit", reason = "check_skipped", target = query.target, cause = query.cause }
  end
  if query.accuracy == nil then
    return { kind = "hit", reason = "no_accuracy_check", target = query.target, cause = query.cause }
  end
  local threshold = math.floor((query.accuracy * Accuracy.ROLL_MODULUS) / 100)
  local accuracyStage = query.accuracyStage or 0
  local evasionStage = query.evasionStage or 0
  if accuracyStage ~= 0 or evasionStage ~= 0 then
    local accuracyNumerator, accuracyDenominator = thirdsRatio(accuracyStage)
    local evasionNumerator, evasionDenominator = thirdsRatio(evasionStage)
    threshold = math.floor(
      (query.accuracy * accuracyNumerator * evasionDenominator * Accuracy.ROLL_MODULUS)
        / (accuracyDenominator * evasionNumerator * 100)
    )
  end
  local draw = stream:nextU16("accuracy_check", query.cause)
  if draw < threshold then
    return { kind = "hit", reason = "accuracy_roll", target = query.target, cause = query.cause }
  end
  return { kind = "miss", reason = "accuracy_miss", target = query.target, cause = query.cause }
end

return Accuracy
