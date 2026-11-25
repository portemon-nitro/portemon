-- The transient source points window: one non-modal field window that prints
-- the source battle-point balance row from message bank 191. The source opens
-- it at a tile coordinate, repaints only on an explicit update, and deletes the
-- window on hide (src/field/script_menu.c::PointsBox_New/PointsBox_Update and
-- src/overlay_22.c). The box owns presentation state only: it borrows the live
-- wallet for the displayed balance and the message provider for the source
-- row, and it never stores a second balance.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local FieldPointsBox = require("game.hgss.src.field.FieldPointsBox")
local FieldScriptSliceFixture = require("tests.support.FieldScriptSliceFixture")
local ScriptErrors = require("libs.script.src.errors")

local T = {}

local BATTLE_POINTS_TYPE = 1

local function pointsBox(balance)
  local wallet = { balance = balance }
  local box = FieldPointsBox.new({
    messages = FieldScriptSliceFixture.pointsMessageProvider(),
    battlePoints = {
      balance = function()
        return wallet.balance
      end,
    },
  })
  return box, wallet
end

local function faultCode(fn)
  local ok, err = pcall(fn)
  Assert.isFalse(ok, "the command must not succeed")
  Assert.isTrue(Errors.is(err), "the failure is attributed: " .. tostring(err))
  ---@cast err Errors.Error
  return err.code
end

-- The source frame is a 10x2-tile window on the main display
-- (AddWindowParameterized(..., x, y, 10, 2, ...)), and the value row is the
-- fully expanded bank-191 line right-aligned inside those 80 pixels.
function T.source_geometry_matches_the_points_window_frame()
  Assert.equal(FieldPointsBox.WIDTH, 80, "the frame is ten eight-pixel tiles wide")
  Assert.equal(FieldPointsBox.HEIGHT, 16, "the frame is two eight-pixel tiles high")
  local box = pointsBox(0)
  box:show(BATTLE_POINTS_TYPE, 21, 1)
  local shown = box:snapshot()
  Assert.equal(shown.tileX, 21, "the frame opens at its own source column")
  Assert.equal(shown.tileY, 1, "the frame opens at its own source row")
  Assert.equal(shown.displayedValue, 0, "a zero balance still paints its value row")
  Assert.equal(shown.valueText, "    0", "a zero balance is blank-padded to the five source cells")
  Assert.equal(shown.text, "    0 BP", "the expanded source row keeps the template's own suffix")
end

function T.snapshot_captures_the_open_balance_and_repaints_only_on_update()
  local box, wallet = pointsBox(200)
  Assert.isFalse(box:snapshot().visible, "an unopened window is invisible")

  box:show(BATTLE_POINTS_TYPE, 21, 1)
  local shown = box:snapshot()
  Assert.isTrue(shown.visible)
  Assert.equal(shown.displayedValue, 200, "opening captures the saved balance")
  -- BufferIntegerAsString(msgFmt, 0, value, 5, PRINTING_MODE_RIGHT_ALIGN, TRUE)
  -- fills a five-cell field with leading narrow spaces, never leading zeros.
  Assert.equal(shown.valueText, "  200", "the value field is five cells wide and right aligned")

  wallet.balance = 9999
  Assert.equal(box:snapshot().displayedValue, 200, "the drawn balance never follows the wallet")
  box:update(BATTLE_POINTS_TYPE)
  Assert.equal(box:snapshot().displayedValue, 9999, "an explicit update repaints the current balance")
  Assert.equal(box:snapshot().valueText, " 9999", "the update repaints the same five-cell field")
  Assert.equal(box:snapshot().text, " 9999 BP", "the update keeps the template's own suffix")

  box:hide()
  Assert.isFalse(box:snapshot().visible, "hiding closes the window")
end

-- The window keeps the captured value while it is open: only show and update
-- read the wallet, so a balance change between them is never painted.
function T.the_captured_value_survives_a_wallet_change_until_the_next_update()
  local box, wallet = pointsBox(200)
  box:show(BATTLE_POINTS_TYPE, 21, 1)
  wallet.balance = 168
  Assert.equal(box:snapshot().displayedValue, 200, "no live read reaches the drawn snapshot")
  box:update(BATTLE_POINTS_TYPE)
  Assert.equal(box:snapshot().displayedValue, 168, "the update reads the wallet once")
end

function T.lifecycle_commands_fault_outside_their_one_open_window()
  local box = pointsBox(100)
  Assert.equal(
    faultCode(function()
      box:update(BATTLE_POINTS_TYPE)
    end),
    ScriptErrors.SCRIPT_POINTS_BOX_WINDOW_STATE,
    "an update with no open window faults"
  )
  Assert.equal(
    faultCode(function()
      box:hide()
    end),
    ScriptErrors.SCRIPT_POINTS_BOX_WINDOW_STATE,
    "hiding a closed window faults"
  )

  box:show(BATTLE_POINTS_TYPE, 0, 0)
  Assert.equal(
    faultCode(function()
      box:show(BATTLE_POINTS_TYPE, 1, 1)
    end),
    ScriptErrors.SCRIPT_POINTS_BOX_WINDOW_STATE,
    "a second show cannot open a second window"
  )
  box:hide()
end

-- This window owns the battle-point row only. The coin and athlete rows belong
-- to the features that own those wallets, so asking for one here is an
-- attributed fault rather than a plausible number.
function T.only_the_battle_point_row_is_available_here()
  local box = pointsBox(200)
  for _, valueType in ipairs({ 0, 2, 3 }) do
    Assert.equal(
      faultCode(function()
        box:show(valueType, 21, 1)
      end),
      ScriptErrors.SCRIPT_POINTS_BOX_TYPE_UNSUPPORTED,
      "type " .. valueType .. " belongs to another owner"
    )
  end
  Assert.isFalse(box:snapshot().visible, "a refused type opens no window")
  box:show(BATTLE_POINTS_TYPE, 21, 1)
  Assert.equal(
    faultCode(function()
      box:update(0)
    end),
    ScriptErrors.SCRIPT_POINTS_BOX_TYPE_UNSUPPORTED,
    "an update names the row it repaints"
  )
  box:hide()
end

function T.teardown_closes_the_window_exactly_once()
  local box = pointsBox(100)
  box:show(BATTLE_POINTS_TYPE, 2, 4)
  box:dispose()
  Assert.isFalse(box:snapshot().visible, "field teardown closes the window")
  box:dispose()
  Assert.isFalse(box:snapshot().visible, "a repeated teardown is a no-op")
end

function T.missing_wallet_owner_faults_before_the_window_opens()
  local box = FieldPointsBox.new({ messages = FieldScriptSliceFixture.pointsMessageProvider() })
  Assert.equal(
    faultCode(function()
      box:show(BATTLE_POINTS_TYPE, 0, 0)
    end),
    ScriptErrors.SCRIPT_SERVICE_MISSING,
    "the window never opens without the live wallet"
  )
  Assert.isFalse(box:snapshot().visible)
end

-- A value template without the source battle-point marker has no field for the
-- balance: the box fails with its own attributed code instead of printing the
-- template's glyphs as the amount.
function T.value_template_without_the_source_marker_faults()
  local template = {
    bankId = 191,
    messageId = 220,
    text = "BP",
    tokens = {
      { kind = "glyph", code = 0x01A8, text = "BP", raw = { 0x01A8 } },
      { kind = "eos", raw = { 0xFFFF } },
    },
  }
  local box = FieldPointsBox.new({
    messages = {
      acquireBank = function()
        return {}
      end,
      get = function()
        return template
      end,
      releaseBank = function() end,
    },
    battlePoints = {
      balance = function()
        return 150
      end,
    },
  })
  local err = Assert.throws(function()
    box:show(BATTLE_POINTS_TYPE, 0, 0)
  end)
  Assert.isTrue(Errors.is(err), "the marker-less template is an attributed fault")
  Assert.equal((err --[[@as Errors.Error]]).code, ScriptErrors.SCRIPT_POINTS_BOX_MESSAGE_INVALID)
  Assert.isFalse(box:snapshot().visible, "a faulted show opens no window")
end

return { tests = T }
