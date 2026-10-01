-- The KO-response style is a mechanics decision carried explicitly:
-- only the shift style in an eligible singles format requests the optional
-- exchange through the decision protocol with exactly the permitted
-- information about the arrival, the set style and ineligible formats
-- continue without any prompt, the style travels as an explicit option,
-- and a required replacement ignores trapping without counting as a
-- voluntary exchange.

local Assert = require("tests.support.Assert")
local SessionFixture = require("libs.battle.tests.session_fixture")
local BattleErrors = require("libs.battle.src.errors")

local T = {}

---@param behavior string missing owner under test
---@return table the loaded exchange-continuation owner
local function switchingOwner(behavior)
  return SessionFixture.requirePresent("libs.battle.src.gen4.Switching", behavior)
end

---@param style string KO-response style under test
---@param activeSlots integer active positions per side under test
---@return table eligibility query for the optional exchange
local function shiftQuery(style, activeSlots)
  return {
    position = 1,
    incoming = 2,
    reason = "shift",
    style = style,
    topology = { activePerSide = activeSlots },
    trap = { held = false },
    reserves = { 2, 3 },
  }
end

-- Only the shift style requests the optional exchange: the prompt vocabulary
-- exists in the decision protocol, eligibility holds, and the preview
-- carries exactly the permitted arrival identity.
function T.only_shift_style_requests_the_optional_exchange()
  local Switching = switchingOwner("the source exchange continuation owns switch sequencing")
  local Protocol = SessionFixture.requirePresent(
    "libs.battle.src.BattleProtocol",
    "the typed decision protocol owns prompt vocabulary"
  )
  Assert.isTrue(Protocol.isDecisionKind("shift"), "the optional exchange flows through the decision protocol")
  local accepted = Protocol.validateChoice(
    { actor = { combatant = 1 }, kind = "switch", payload = { replacement = 2 } },
    "shift"
  )
  Assert.equal(accepted.kind, "switch", "the shift prompt accepts the exchange choice")
  local verdict = Switching.eligible(shiftQuery("shift", 1))
  Assert.isTrue(verdict.ok, "the shift style in singles requests the optional exchange")
  local frame = Switching.validateFrame(Switching.start({
    position = 1,
    outgoing = { combatant = 1, activation = 7 },
    incoming = 2,
    reason = "shift",
    style = "shift",
    topology = { activePerSide = 1 },
    trap = { held = false },
    reserves = { 2, 3 },
  }))
  Assert.equal(frame.reason, "shift", "the frame keeps its exchange reason")
  Assert.keySet(frame.preview, "incoming", "the prompt carries exactly the permitted information")
  Assert.equal(frame.preview.incoming, 2, "the preview names the arrival and nothing else")
end

-- The set style continues without a prompt: eligibility fails and starting
-- the optional exchange is rejected as invalid input.
function T.set_style_continues_without_a_prompt()
  local Switching = switchingOwner("the source exchange continuation owns switch sequencing")
  local verdict = Switching.eligible(shiftQuery("set", 1))
  Assert.isFalse(verdict.ok, "the set style never requests the optional exchange")
  Assert.notNil(verdict.reason, "the refusal names its reason")
  local failure = Assert.throws(function()
    Switching.start({
      position = 1,
      outgoing = { combatant = 1, activation = 7 },
      incoming = 2,
      reason = "shift",
      style = "set",
      topology = { activePerSide = 1 },
      trap = { held = false },
      reserves = { 2, 3 },
    })
  end)
  Assert.isTrue(
    type(failure) == "table" and failure.code == BattleErrors.INPUT,
    "a shift exchange under the set style fails as invalid input"
  )
end

-- Ineligible formats never offer the prompt even when the style is shift:
-- only single-position sides are asked.
function T.ineligible_formats_never_offer_the_prompt()
  local Switching = switchingOwner("the source exchange continuation owns switch sequencing")
  local doubles = Switching.eligible(shiftQuery("shift", 2))
  Assert.isFalse(doubles.ok, "multi-position formats never request the optional exchange")
  local multi = Switching.eligible({
    position = 1,
    incoming = 2,
    reason = "shift",
    style = "shift",
    topology = { activePerSide = 1, partners = true },
    trap = { held = false },
    reserves = { 2, 3 },
  })
  Assert.isFalse(multi.ok, "partner formats never request the optional exchange")
end

-- A required replacement ignores trapping and is not a voluntary exchange:
-- every documented reason validates, and only the voluntary reason counts
-- as voluntary.
function T.required_replacement_ignores_trapping_and_is_not_voluntary()
  local Switching = switchingOwner("the source exchange continuation owns switch sequencing")
  local verdict = Switching.eligible({
    position = 1,
    incoming = 2,
    reason = "faint",
    trap = { held = true },
    reserves = { 2, 3 },
  })
  Assert.isTrue(verdict.ok, "a required replacement answers despite the trap")
  local frame = Switching.validateFrame(Switching.start({
    position = 1,
    outgoing = { combatant = 1, activation = 7 },
    incoming = 2,
    reason = "faint",
    trap = { held = true },
    reserves = { 2, 3 },
  }))
  Assert.isFalse(frame.voluntary, "a required replacement is not a voluntary exchange")
  for _, reason in ipairs({ "voluntary", "forced", "faint", "u_turn", "baton_pass", "shift" }) do
    local candidate = Switching.validateFrame({
      position = 1,
      outgoing = { combatant = 1, activation = 7 },
      incoming = 2,
      reason = reason,
      voluntary = reason == "voluntary",
      activation = 11,
      cursor = "start",
      transferredEffects = {},
    })
    Assert.equal(candidate.reason, reason, "the documented reason validates: " .. reason)
  end
end

-- The style travels as an explicit option: identical queries differing only
-- in the style field decide differently, so no hidden preference is read.
function T.style_travels_as_an_explicit_option()
  local Switching = switchingOwner("the source exchange continuation owns switch sequencing")
  local shifted = Switching.eligible(shiftQuery("shift", 1))
  local settled = Switching.eligible(shiftQuery("set", 1))
  Assert.isTrue(shifted.ok, "the explicit shift option requests the exchange")
  Assert.isFalse(settled.ok, "the explicit set option withholds the exchange")
end

return { tests = T }
