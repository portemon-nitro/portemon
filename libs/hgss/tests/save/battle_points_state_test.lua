-- The persisted Battle Point wallet: the one closed bucket behind the source
-- FrontierData battle-point action, its strict source range, one-use
-- replacement candidates, and the round trip that keeps a settled balance.
-- The source caps and floors live at the script operation, so the owner
-- rejects an out-of-range replacement instead of clamping it.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local BattlePointsState = require("libs.hgss.src.save.BattlePointsState")

local T = {}

local SCHEMA = "hgss-battle-points-v1"

local function assertRejected(fn, what)
  local err = Assert.throws(fn, what)
  Assert.isTrue(Errors.is(err), "rejections use the structured error path: " .. tostring(err))
  Assert.equal(err.code, "GAME_SAVE_BUCKET_INVALID", "rejections carry the save bucket identity")
end

function T.a_new_wallet_starts_empty_and_round_trips()
  local wallet = BattlePointsState.new()
  Assert.equal(wallet:balance(), 0, "a new wallet holds no point")
  Assert.equal(wallet:revision(), 0, "a new wallet starts at revision zero")
  Assert.deepEqual(wallet:capture(), { schema = SCHEMA, balance = 0 }, "the bucket carries its schema and balance")

  local restored = BattlePointsState.restore({ schema = SCHEMA, balance = 9999 })
  Assert.equal(restored:balance(), 9999, "the source maximum survives a restore")
  Assert.deepEqual(restored:capture(), { schema = SCHEMA, balance = 9999 }, "the captured balance is the stored one")
end

function T.a_missing_bucket_restores_the_source_initial_state()
  local restored = BattlePointsState.restore(nil)
  Assert.equal(restored:balance(), 0, "a save without a wallet has spent no point")
  Assert.equal(restored:revision(), 0, "a save without a wallet starts at revision zero")
end

function T.restore_rejects_malformed_buckets_instead_of_clamping()
  assertRejected(function()
    return BattlePointsState.restore({ schema = SCHEMA, balance = 10000 })
  end, "a balance above the source maximum")
  assertRejected(function()
    return BattlePointsState.restore({ schema = SCHEMA, balance = -1 })
  end, "a negative balance")
  assertRejected(function()
    return BattlePointsState.restore({ schema = SCHEMA, balance = 1.5 })
  end, "a fractional balance")
  assertRejected(function()
    return BattlePointsState.restore({ schema = SCHEMA, balance = "12" })
  end, "a non-numeric balance")
  assertRejected(function()
    return BattlePointsState.restore({ schema = "hgss-battle-points-v0", balance = 0 })
  end, "an unknown schema")
  assertRejected(function()
    return BattlePointsState.restore({ schema = SCHEMA, balance = 0, frontierChallenge = 1 })
  end, "an unknown field")
end

function T.a_prepared_balance_replaces_the_settled_one_exactly_once()
  local wallet = BattlePointsState.restore({ schema = SCHEMA, balance = 10 })
  local candidate = wallet:prepare(7)
  Assert.isTrue(candidate.changed, "a different balance reports the change")
  Assert.equal(wallet:balance(), 10, "preparation leaves the settled balance untouched")
  candidate.publish()
  Assert.equal(wallet:balance(), 7, "publication installs the prepared balance")
  Assert.equal(wallet:revision(), 1, "publication advances the revision")
  assertRejected(function()
    return candidate.publish()
  end, "a repeated publication")
  Assert.equal(wallet:balance(), 7, "a repeated publication changes nothing")
end

function T.an_unchanged_preparation_keeps_the_revision()
  local wallet = BattlePointsState.restore({ schema = SCHEMA, balance = 5 })
  local candidate = wallet:prepare(5)
  Assert.isFalse(candidate.changed, "an equal balance reports no change")
  candidate.publish()
  Assert.equal(wallet:revision(), 0, "an unchanged publication keeps the revision")
end

function T.a_stale_candidate_never_publishes()
  local wallet = BattlePointsState.restore({ schema = SCHEMA, balance = 5 })
  local stale = wallet:prepare(9)
  local current = wallet:prepare(1)
  current.publish()
  Assert.isFalse(stale:isCurrent(), "a replaced candidate is no longer current")
  local err = Assert.throws(function()
    return stale.publish()
  end, "a stale publication")
  Assert.isTrue(Errors.is(err), "a stale publication faults loudly")
  Assert.equal(wallet:balance(), 1, "the settled balance stays the current one")
end

function T.a_prepared_balance_is_validated_before_any_state_moves()
  local wallet = BattlePointsState.restore({ schema = SCHEMA, balance = 5 })
  assertRejected(function()
    return wallet:prepare(10000)
  end, "a prepared balance above the source maximum")
  assertRejected(function()
    return wallet:prepare(nil)
  end, "a prepared balance without a value")
  Assert.equal(wallet:balance(), 5, "an invalid preparation leaves the balance untouched")
  Assert.equal(wallet:revision(), 0, "an invalid preparation never advances the revision")
end

return { tests = T }
