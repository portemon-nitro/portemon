-- The transient source money box owns exactly one window's presentation
-- snapshot: opening captures the borrowed profile balance, an explicit update
-- repaints it, and closing frees the window so a repeated lifecycle command is
-- an attributed script fault rather than a quiet success.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local FieldMoneyBox = require("game.hgss.src.field.FieldMoneyBox")
local FieldScriptSliceFixture = require("tests.support.FieldScriptSliceFixture")
local ScriptErrors = require("libs.script.src.errors")

local T = {}

local function moneyBox(money)
  local profile = { money = money }
  local box = FieldMoneyBox.new({
    profile = profile,
    messages = FieldScriptSliceFixture.moneyMessageProvider(),
  })
  return box, profile
end

local function faultCode(fn)
  local ok, err = pcall(fn)
  Assert.isFalse(ok, "the command must not succeed")
  Assert.isTrue(Errors.is(err), "the failure is attributed: " .. tostring(err))
  ---@cast err Errors.Error
  return err.code
end

function T.snapshot_captures_the_open_balance_and_repaints_only_on_update()
  local box, profile = moneyBox(150)
  Assert.isFalse(box:snapshot().visible, "an unopened box is invisible")

  box:show(3, 5)
  local shown = box:snapshot()
  Assert.isTrue(shown.visible)
  Assert.equal(shown.tileX, 3)
  Assert.equal(shown.tileY, 5)
  Assert.equal(shown.label, "MONEY", "the label comes from message bank 435")
  Assert.equal(shown.displayedMoney, 150, "opening captures the live balance")
  -- msg_0435_00031 is "${STRVAR_1 55, 0, 0}": the template's own dollar glyph
  -- followed by the six-wide balance the source buffers into its marker.
  -- String16_FormatInteger pads a right-aligned integer with narrow spaces, so
  -- a low balance carries leading blanks, never leading zeros.
  Assert.equal(shown.valueText, "$   150", "the value row is the dollar glyph plus the space-padded balance")

  profile.money = 200
  Assert.equal(box:snapshot().displayedMoney, 150, "the drawn balance never follows the wallet")
  box:update()
  Assert.equal(box:snapshot().displayedMoney, 200, "an explicit update repaints the current balance")
  Assert.equal(box:snapshot().valueText, "$   200", "the update repaints the same space-padded balance row")
  Assert.isNil(box:snapshot().valueText:find("150", 1, true), "the stale balance is replaced")

  box:hide()
  Assert.isFalse(box:snapshot().visible, "hiding closes the window")
end

-- The source window is 10x4 tiles at the source tile coordinate and takes u8
-- tile operands even though ScriptGetVar reads a u16 value.
function T.source_geometry_and_tile_operands_match_the_money_box_window()
  Assert.equal(FieldMoneyBox.WIDTH, 80)
  Assert.equal(FieldMoneyBox.HEIGHT, 32)
  Assert.equal(FieldMoneyBox.MONEY_ROW_Y, 16)
  local box = moneyBox(0)
  box:show(0x0103, 0x0105)
  Assert.equal(box:snapshot().tileX, 3)
  Assert.equal(box:snapshot().tileY, 5)
  Assert.equal(box:snapshot().displayedMoney, 0, "a zero balance still draws its value row")
  Assert.equal(box:snapshot().valueText, "$     0", "a zero balance is blank-padded to the six source cells")
end

function T.lifecycle_commands_fault_outside_their_one_open_window()
  local box = moneyBox(100)
  Assert.equal(
    faultCode(function()
      box:update()
    end),
    ScriptErrors.SCRIPT_INVALID_REFERENCE,
    "an update with no open window faults"
  )
  Assert.equal(
    faultCode(function()
      box:hide()
    end),
    ScriptErrors.SCRIPT_INVALID_REFERENCE,
    "hiding a closed window faults"
  )

  box:show(0, 0)
  Assert.equal(
    faultCode(function()
      box:show(1, 1)
    end),
    ScriptErrors.SCRIPT_INVALID_REFERENCE,
    "a second show cannot open a second window"
  )
  box:hide()
end

function T.teardown_closes_the_window_exactly_once()
  local box = moneyBox(100)
  box:show(2, 4)
  box:dispose()
  Assert.isFalse(box:snapshot().visible, "field teardown closes the window")
  box:dispose()
  Assert.isFalse(box:snapshot().visible, "a repeated teardown is a no-op")
end

function T.missing_wallet_owner_faults_before_the_window_opens()
  local box = FieldMoneyBox.new({
    messages = FieldScriptSliceFixture.moneyMessageProvider(),
  })
  Assert.equal(
    faultCode(function()
      box:show(0, 0)
    end),
    ScriptErrors.SCRIPT_SERVICE_MISSING,
    "the box never opens without the live profile"
  )
  Assert.isFalse(box:snapshot().visible)
end

-- A value template without the source money marker has no field for the
-- balance: the box fails with its own attributed code rather than printing the
-- template's glyphs as the amount.
function T.value_template_without_the_source_money_marker_faults()
  local template = {
    bankId = 435,
    messageId = 31,
    text = "000000",
    tokens = {
      { kind = "glyph", code = 0x0121, text = "000000", raw = { 0x0121 } },
      { kind = "eos", raw = { 0xFFFF } },
    },
  }
  local box = FieldMoneyBox.new({
    profile = { money = 150 },
    messages = {
      acquireBank = function()
        return {}
      end,
      get = function()
        return template
      end,
      releaseBank = function() end,
    },
  })
  local err = Assert.throws(function()
    box:show(0, 0)
  end)
  Assert.isTrue(Errors.is(err), "the marker-less template is an attributed fault")
  Assert.equal((err --[[@as Errors.Error]]).code, ScriptErrors.SCRIPT_MONEY_BOX_MESSAGE_INVALID)
  Assert.isFalse(box:snapshot().visible, "a faulted show opens no window")
end

return { tests = T }
