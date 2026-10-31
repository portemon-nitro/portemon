-- Player gameplay-options contract: the six-field canonical record behind the
-- live player record. Covers defaults for records predating the newer
-- fields, detached canonicalization, preservation of the long-standing text
-- keys, rejection of malformed present values without caller mutation, and
-- survival of all six values through battle-reward preparation. Pure and
-- headless: validation receives the generated charmap plus the imported
-- dialogue frame-index set, so no I/O occurs here.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local PlayerData = require("libs.hgss.src.save.PlayerData")

local T = {}

local CHARMAP = {
  G = 305,
  O = 313,
  L = 310,
  D = 302,
  H = 306,
  I = 307,
  K = 309,
  A = 299,
  R = 316,
}
local FRAME_INDEXES = { [0] = true, [1] = true, [2] = true }

local function context(overrides)
  local value = { charmap = CHARMAP, frameIndexes = FRAME_INDEXES }
  for key, item in pairs(overrides or {}) do
    value[key] = item
  end
  return value
end

local function options(overrides)
  local value = {
    textSpeed = "fastest",
    textFrame = 0,
    battleStyle = "shift",
    battleScene = true,
    soundMode = "stereo",
    battleSpeed = 1,
  }
  for key, item in pairs(overrides or {}) do
    value[key] = item
  end
  return value
end

local function record(overrides)
  local value = {
    profile = {
      name = "GOLD",
      rivalName = "HIKARI",
      gender = 0,
      trainerId = 0,
      money = 3000,
      badges = {},
      nationalDex = false,
      runningShoes = false,
      runningShoesLock = false,
    },
    options = options(),
  }
  for key, item in pairs(overrides or {}) do
    if type(item) == "table" and type(value[key]) == "table" then
      for field, fieldValue in pairs(item) do
        value[key][field] = fieldValue
      end
    else
      value[key] = item
    end
  end
  return value
end

local function codeOf(fn)
  local _, err = fn()
  Assert.isTrue(Errors.is(err), "a malformed value reports a structured failure")
  return err.code
end

function T.default_options_carry_the_full_six_field_record()
  Assert.deepEqual(options(), {
    textSpeed = "fastest",
    textFrame = 0,
    battleStyle = "shift",
    battleScene = true,
    soundMode = "stereo",
    battleSpeed = 1,
  })
  Assert.deepEqual(PlayerData.defaultOptions(), options())
end

function T.validate_options_round_trips_a_canonical_detached_copy()
  local input = options({
    textSpeed = "mid",
    textFrame = 2,
    battleStyle = "set",
    battleScene = false,
    soundMode = "mono",
    battleSpeed = 4,
  })
  local canonical = assert(PlayerData.validateOptions(input, context()))
  Assert.deepEqual(canonical, input)
  Assert.isFalse(rawequal(canonical, input), "validation must not return the caller's table")
  canonical.textSpeed = "fast"
  canonical.battleSpeed = 1
  Assert.equal(input.textSpeed, "mid", "mutating the candidate must not touch the caller's record")
  Assert.equal(input.battleSpeed, 4)
end

function T.validate_options_defaults_only_absent_new_fields()
  local legacy = { textSpeed = "mid", textFrame = 1, battleStyle = "shift" }
  local canonical = assert(PlayerData.validateOptions(legacy, context()))
  Assert.deepEqual(canonical, {
    textSpeed = "mid",
    textFrame = 1,
    battleStyle = "shift",
    battleScene = true,
    soundMode = "stereo",
    battleSpeed = 1,
  })
  Assert.isNil(legacy.battleScene, "defaulting must not write back into the caller's record")
end

function T.validate_options_keeps_both_long_standing_text_keys()
  Assert.equal(assert(PlayerData.validateOptions(options({ textSpeed = "slow" }), context())).textSpeed, "slow")
  Assert.equal(assert(PlayerData.validateOptions(options({ textSpeed = "fastest" }), context())).textSpeed, "fastest")
end

function T.validate_options_rejects_malformed_present_values_without_mutation()
  local cases = {
    { field = "textSpeed", value = "turbo" },
    { field = "textSpeed", value = "MID" },
    { field = "textSpeed", value = 2 },
    { field = "textSpeed", value = 0 / 0 },
    { field = "textFrame", value = 3 },
    { field = "textFrame", value = -1 },
    { field = "textFrame", value = 1.5 },
    { field = "textFrame", value = "0" },
    { field = "battleStyle", value = "auto" },
    { field = "battleStyle", value = "" },
    { field = "battleScene", value = 1 },
    { field = "battleScene", value = "true" },
    { field = "soundMode", value = "surround" },
    { field = "soundMode", value = "STEREO" },
    { field = "battleSpeed", value = 0 },
    { field = "battleSpeed", value = 3 },
    { field = "battleSpeed", value = 1.5 },
    { field = "battleSpeed", value = "2" },
    { field = "battleSpeed", value = 0 / 0 },
  }
  for _, case in ipairs(cases) do
    local input = options({ [case.field] = case.value })
    local canonical, err = PlayerData.validateOptions(input, context())
    Assert.isNil(canonical, case.field .. "=" .. tostring(case.value) .. " must not validate")
    Assert.isTrue(Errors.is(err), case.field .. " reports a structured failure")
    -- NaN never equals itself, so the untouched check compares by shape:
    -- the same key set and an identically non-equal field value.
    Assert.keySet(
      input,
      "battleScene,battleSpeed,battleStyle,soundMode,textFrame,textSpeed",
      "a rejected candidate keeps the caller's key set"
    )
    Assert.equal(
      input[case.field] ~= input[case.field],
      case.value ~= case.value,
      "a rejected candidate leaves " .. case.field .. " untouched"
    )
    if case.value == case.value then
      Assert.equal(input[case.field], case.value, "a rejected candidate leaves " .. case.field .. " untouched")
    end
  end
end

function T.validate_options_keeps_zero_frame_and_explicit_off_false_values()
  local canonical =
    assert(PlayerData.validateOptions(options({ textFrame = 0, battleScene = false, soundMode = "mono" }), context()))
  Assert.equal(canonical.textFrame, 0, "zero is a valid frame, never defaulted away")
  Assert.isFalse(canonical.battleScene)
  Assert.equal(canonical.soundMode, "mono")
end

function T.validate_options_discards_unknown_keys()
  local input = options()
  input.futureThing = true
  local canonical = assert(PlayerData.validateOptions(input, context()))
  Assert.keySet(
    canonical,
    "battleScene,battleSpeed,battleStyle,soundMode,textFrame,textSpeed",
    "canonicalization must drop unknown option keys"
  )
end

function T.validate_options_rejects_non_records()
  for _, bad in ipairs({ nil, 42, "fast" }) do
    local canonical, err = PlayerData.validateOptions(bad, context())
    Assert.isNil(canonical)
    Assert.isTrue(Errors.is(err), "a non-record reports a structured failure")
  end
end

function T.full_record_validation_preserves_all_six_fields()
  local validated = assert(PlayerData.validate(record(), context()))
  Assert.deepEqual(validated.options, options())
  local legacy = record()
  legacy.options.battleScene = nil
  legacy.options.soundMode = nil
  legacy.options.battleSpeed = nil
  legacy.options.battleStyle = nil
  local defaulted = assert(PlayerData.validate(legacy, context()))
  Assert.deepEqual(defaulted.options, options())
  local broken = record({ options = { battleSpeed = 8 } })
  Assert.equal(
    codeOf(function()
      return PlayerData.validate(broken, context())
    end),
    "PLAYER_DATA_INVALID"
  )
end

function T.battle_reward_preparation_carries_all_six_fields()
  local wealthy = record({
    options = {
      textSpeed = "mid",
      textFrame = 2,
      battleStyle = "set",
      battleScene = false,
      soundMode = "mono",
      battleSpeed = 4,
    },
  })
  local prepared = PlayerData.prepareBattleChanges(wealthy, context(), { moneyDelta = 500 })
  Assert.deepEqual(prepared.options, wealthy.options, "reward settlement touches money, never options")
  Assert.equal(prepared.profile.money, 3500)
  local legacy = record()
  legacy.options.battleScene = nil
  legacy.options.soundMode = nil
  legacy.options.battleSpeed = nil
  local preparedLegacy = PlayerData.prepareBattleChanges(legacy, context(), { moneyDelta = 0 })
  Assert.deepEqual(preparedLegacy.options, options(), "reward settlement defaults absent fields like validation")
end

return { tests = T }
