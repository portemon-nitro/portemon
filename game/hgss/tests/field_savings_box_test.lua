-- The transient source savings window: one 16x8-tile field window that prints
-- Mom's deposited savings and the player's held money from message bank 191,
-- repaints both balances only on an explicit update, and releases the window
-- on hide (src/field/script_menu.c::SavingsBox_New/SavingsBox_Update and
-- src/field/headbutt.c::ScrCmd_ShowSavingsBox/SavingsBox_Update). The window
-- owns presentation state only: it borrows the live profile and phone state.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local FieldMessageText = require("libs.assets.src.field.FieldMessageText")
local FieldSavingsBox = require("game.hgss.src.field.FieldSavingsBox")
local ScriptErrors = require("libs.script.src.errors")

local T = {}

-- bank 191 #330 "DEPOSITED MONEY", #331 "HELD MONEY" and #332
-- "${STRVAR_1 55, 0, 0}".
local function rows()
  local function label(bankId, messageId, text)
    return { bankId = bankId, messageId = messageId, text = text, tokens = { { kind = "eos", raw = { 0xFFFF } } } }
  end
  return {
    [330] = label(191, 330, "DEPOSITED MONEY"),
    [331] = label(191, 331, "HELD MONEY"),
    [332] = {
      bankId = 191,
      messageId = 332,
      text = "${STRVAR_1 55, 0, 0}",
      tokens = {
        { kind = "substitution", control = FieldMessageText.STRVAR_1 + 55, args = { 0, 0 } },
        { kind = "eos", raw = { 0xFFFF } },
      },
    },
  }
end

local function messages()
  local table_ = rows()
  return {
    acquireBank = function()
      return {}
    end,
    get = function(_, _bankId, messageId)
      return table_[messageId]
    end,
    releaseBank = function() end,
  }
end

local function savingsOwner(balance)
  return {
    readPhone = function()
      return { mom = { balance = balance, purchases = {}, gifts = {} } }
    end,
  }
end

local function box(profile, phone, provider)
  return FieldSavingsBox.new({
    profile = profile,
    pokegearState = phone,
    messages = provider or messages(),
  })
end

local function faultCode(fn)
  local ok, err = pcall(fn)
  Assert.isFalse(ok, "the command must not succeed")
  Assert.isTrue(Errors.is(err), "the failure is attributed: " .. tostring(err))
  ---@cast err Errors.Error
  return err.code
end

-- AddWindowParameterized(..., x, y, 16, 8, ...): the frame is sixteen
-- eight-pixel tiles wide and eight high, with the two labels on pixel rows 0
-- and 32 and the two balances on rows 16 and 48.
function T.the_window_is_sixteen_by_eight_tiles_with_two_balance_rows()
  Assert.equal(FieldSavingsBox.WIDTH, 128, "the frame is sixteen eight-pixel tiles wide")
  Assert.equal(FieldSavingsBox.HEIGHT, 64, "the frame is eight eight-pixel tiles high")
  local window = box({ money = 3000, coins = 0 }, savingsOwner(1000))
  window:show(1, 1)
  local shown = window:snapshot()
  Assert.isTrue(shown.visible, "the shown window is visible")
  Assert.equal(shown.tileX, 1, "the frame opens at its source column")
  Assert.equal(shown.tileY, 1, "the frame opens at its source row")
  Assert.deepEqual(shown.rows, {
    { label = "DEPOSITED MONEY", labelY = 0, y = 16, value = 1000, text = "1000" },
    { label = "HELD MONEY", labelY = 32, y = 48, value = 3000, text = "3000" },
  }, "the two source rows carry the deposited savings and the held money")
end

-- SavingsBox_Update is the only repaint: account or wallet changes while the
-- window is open never reach the drawn snapshot.
function T.the_snapshot_repaints_only_on_an_explicit_update()
  local profile = { money = 3000, coins = 0 }
  local savings = { balance = 1000 }
  local phone = {
    readPhone = function()
      return { mom = { balance = savings.balance, purchases = {}, gifts = {} } }
    end,
  }
  local window = box(profile, phone)
  window:show(3, 2)
  profile.money = 500
  savings.balance = 200
  Assert.deepEqual(
    { window:snapshot().rows[1].value, window:snapshot().rows[2].value },
    { 1000, 3000 },
    "no live read reaches the drawn rows"
  )
  window:update()
  Assert.deepEqual(
    { window:snapshot().rows[1].value, window:snapshot().rows[2].value },
    { 200, 500 },
    "an explicit update repaints both balances"
  )
end

-- A second show, an update before show and a hide after hide are attributed
-- window-state failures, and teardown closes the window exactly once.
function T.lifecycle_commands_fault_outside_their_one_open_window()
  local window = box({ money = 1, coins = 0 }, savingsOwner(0))
  Assert.equal(
    faultCode(function()
      window:update()
    end),
    ScriptErrors.SCRIPT_INVALID_REFERENCE,
    "an update with no open window faults"
  )
  Assert.equal(
    faultCode(function()
      window:hide()
    end),
    ScriptErrors.SCRIPT_INVALID_REFERENCE,
    "hiding a closed window faults"
  )
  window:show(0, 0)
  Assert.equal(
    faultCode(function()
      window:show(1, 1)
    end),
    ScriptErrors.SCRIPT_INVALID_REFERENCE,
    "a second show cannot open a second window"
  )
  window:hide()
  Assert.isFalse(window:snapshot().visible, "hiding closes the window")
  window:show(2, 3)
  window:dispose()
  Assert.isFalse(window:snapshot().visible, "field teardown closes the window")
  window:dispose()
  Assert.isFalse(window:snapshot().visible, "a repeated teardown is a no-op")
end

-- A missing owner or a value template without the money marker faults before
-- the window publishes anything.
function T.a_missing_owner_or_marker_faults_before_the_window_opens()
  local noProfile = box(nil, savingsOwner(0))
  Assert.equal(
    faultCode(function()
      noProfile:show(0, 0)
    end),
    ScriptErrors.SCRIPT_SERVICE_MISSING,
    "the window never opens without the live wallet"
  )
  Assert.isFalse(noProfile:snapshot().visible, "a failed show opens no window")

  local noSavings = box({ money = 1, coins = 0 }, nil)
  Assert.equal(
    faultCode(function()
      noSavings:show(0, 0)
    end),
    ScriptErrors.SCRIPT_SERVICE_MISSING,
    "the window never opens without the live savings"
  )

  local markerless = rows()
  markerless[332] = {
    bankId = 191,
    messageId = 332,
    text = "0",
    tokens = { { kind = "glyph", code = 0x01A8, text = "0", raw = { 0x01A8 } }, { kind = "eos", raw = { 0xFFFF } } },
  }
  local broken = FieldSavingsBox.new({
    profile = { money = 1, coins = 0 },
    pokegearState = savingsOwner(0),
    messages = {
      acquireBank = function()
        return {}
      end,
      get = function(_, _bankId, messageId)
        return markerless[messageId]
      end,
      releaseBank = function() end,
    },
  })
  Assert.equal(
    faultCode(function()
      broken:show(0, 0)
    end),
    ScriptErrors.SCRIPT_MONEY_BOX_MESSAGE_INVALID,
    "a value template without the marker faults"
  )
  Assert.isFalse(broken:snapshot().visible, "a faulted show opens no window")
end

return { tests = T }
