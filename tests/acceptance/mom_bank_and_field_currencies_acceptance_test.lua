-- The player house Mom bank counter through the production field. Her own
-- object script opens the transient savings window, offers the four source
-- rows (WITHDRAW, DEPOSIT MONEY, CHANGE, EXIT), refuses a full destination or
-- an empty source before the amount screen, and runs the source six-cell
-- number entry whose accepted amount transfers exactly once between the saved
-- wallet and Mom's saved savings. Only audio, screen fades and the wall clock
-- are host boundaries; the script, the windows, the keypad and both canonical
-- owners are production-owned, and the render trap stays active.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local LuaWriter = require("libs.codec.src.LuaWriter")

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = {
      "field-runtime",
      -- MAP_NEW_BARK_PLAYER_HOUSE_1F (map 63) owns the Mom object script and
      -- the house bank message bank (545).
      "map:63",
      "map-data:63",
      "message-bank:545",
      -- The transient savings window prints the shared field UI rows
      -- (bank 191: the two balance labels and the money value row).
      "message-bank:191",
    },
    tags = { "field", "script", "money", "bank", "save" },
  },
  tests = {},
}

local HOUSE_1F = "MAP_NEW_BARK_PLAYER_HOUSE_1F"
-- Mom stands on local (6,7); the documented New Bark house spawn tile faces
-- her from (6,8).
local MOM_TILE = { fieldX = 6, fieldZ = 8, facing = "north" }
-- The house object script Mom's own object event runs.
local BANK_SCRIPT = "vanilla.hgss.scr_seq.0845.script_001"

-- The source bank rows in the order the script adds them (message ids 29..32
-- of bank 545).
local BANK_ROW = { withdraw = 0, deposit = 1, change = 2, exit = 3 }
local BANK_ROW_COUNT = 4

-- The house bank script's own source results (bank 545).
local BANK_MESSAGE = {
  cancel = 21,
  noSavings = 22,
  deposited = 23,
  withdrawn = 24,
  noMoney = 26,
  bankFull = 27,
  walletFull = 28,
}

-- The source ceilings the transfer clamps against.
local MAX_MONEY = 999999
local MAX_BANK = 999999

local FLAGS = FieldScriptSymbols.flagsByName
local VARS = FieldScriptSymbols.variablesByName

local function pressAction(game)
  game.runtime:pressAction()
  game:step()
  game.runtime:releaseAction()
end

---@param game table
---@param scriptId string
---@return string[] the named script's own published faults
local function scriptFaults(game, scriptId)
  local list = {}
  for _, record in ipairs(game:recordsForScript(scriptId, "script.error")) do
    local payload = record.payload or {}
    local context = payload.context or {}
    list[#list + 1] = string.format(
      "%s/%s/%s",
      tostring(payload.code),
      tostring(context.command or context.originalName or "unknown"),
      tostring(payload.message)
    )
  end
  return list
end

---@param game table
---@param scriptId string
---@return table[] the script's own end records
local function scriptEnds(game, scriptId)
  return game:recordsForScript(scriptId, "script.ended")
end

---@param game table
---@return table? the live bank transaction host
local function bankHost(game)
  return game.runtime.bankHost
end

---@param game table
---@return boolean whether the source amount screen owns the field
local function keypadOpen(game)
  local host = bankHost(game)
  return host ~= nil and host:isActive() and host:status() ~= nil
end

---@param game table
---@param label string
---@return table the live amount screen status
local function waitKeypad(game, label)
  for _ = 1, 200 do
    local host = bankHost(game)
    if host ~= nil and host:isActive() then
      local status = host:status()
      if status ~= nil and type(status.keys) == "table" then
        return status
      end
    end
    game:step()
  end
  error("the source amount screen never opened before " .. label, 0)
end

-- One source key of the amount screen: the ten digit cells plus the clear,
-- confirm and cancel affordances the native entry screen offers.
---@param status table the amount screen status
---@param role string "digit"|"clear"|"confirm"|"cancel"
---@param digit integer? the digit a digit key enters
---@return table
local function sourceKey(status, role, digit)
  for _, key in ipairs(status.keys) do
    if key.role == role and (digit == nil or key.digit == digit) then
      return key
    end
  end
  error("the source amount screen offers no " .. role .. " key", 0)
end

---@param game table
---@param key table one source key rectangle
local function tapKey(game, key)
  local x, y = key.x + key.width / 2, key.y + key.height / 2
  game.runtime.input:pointerDown("mouse:1", x, y)
  game:step()
  game.runtime.input:pointerUp("mouse:1", x, y)
end

---@param game table
---@param digits integer[] the digit keys to tap in order
local function tapDigits(game, digits)
  for _, digit in ipairs(digits) do
    tapKey(game, sourceKey(assert(bankHost(game):status(), "the amount screen is open"), "digit", digit))
  end
end

---@param game table
---@param role string
local function tapRole(game, role)
  local status = assert(bankHost(game):status(), "the amount screen is open")
  tapKey(game, sourceKey(status, role))
end

---@param game table
---@return integer the field wallet the canonical profile owns
local function wallet(game)
  local playerData = assert(game.runtime.playerData, "the runtime owns the player data")
  return assert(playerData.profile.money, "the canonical profile owns its money")
end

---@param game table
---@return integer the saved Mom savings balance
local function savings(game)
  local state = assert(game.runtime.pokegearState, "the field runtime owns the phone state")
  return state:readPhone().mom.balance
end

---@param game table
---@return table the saved Mom savings record
local function savingsRecord(game)
  local state = assert(game.runtime.pokegearState, "the field runtime owns the phone state")
  return state:readPhone().mom
end

-- Clicks one generated source menu row and waits until it is no longer the
-- active menu, so the next observation is the following source state.
---@param game table
---@param row integer zero-based source row
local function clickMenuRow(game, row)
  local snapshot = game:snapshot()
  local menu = assert(snapshot.menu, "the bank rows own the field menu")
  local layout = assert(menu.layout, "the bank rows expose their production layout")
  Assert.equal(layout.itemCount, BANK_ROW_COUNT, "the bank offers its four source rows")
  local rect = assert(menu.itemRects[row], "the bank exposes row " .. tostring(row) .. " geometry")
  local x, y = rect.x + rect.width / 2, rect.y + rect.height / 2
  game.runtime.input:pointerDown("mouse:1", x, y)
  game:step()
  game.runtime.input:pointerUp("mouse:1", x, y)
  for _ = 1, 60 do
    local current = game:snapshot().menu
    if current == nil or current.layout ~= layout or current.modal ~= true then
      return
    end
    game:step()
  end
  error("the bank kept row " .. tostring(row) .. " active", 0)
end

---@class BankPlan
---@field row integer the bank row the player picks
---@field keypad fun(game: table, status: table) the amount screen interaction
---@field onWindow fun(game: table)? observed while the savings window is open
---@field maxTicks integer?
---@field refuseStale boolean? the transfer aborts on its own revalidation, which
-- still has to be attributed to the bank transfer command rather than to a
-- plausible generic failure

-- A refused transfer may be reported as an attributed fault; when it is, the
-- fault has to name the source bank transfer it refused.
---@param faults string[]
local function assertFaultsNameTheBankTransfer(faults)
  for _, fault in ipairs(faults) do
    Assert.isTrue(
      fault:find("793", 1, true) ~= nil or fault:find("BankTransaction", 1, true) ~= nil,
      "a refused transfer is attributed to the source bank transfer: " .. fault
    )
  end
end

-- Drives one Mom bank interaction the way a player does: dismiss printed
-- messages, click the planned bank row, run the planned amount-screen
-- interaction, then let the script finish. Any published fault of the bank
-- script fails the scenario at the tick it appears.
---@param game table
---@param plan BankPlan
---@return { printed: integer[], clickedRow: boolean, keypad: boolean }
local function driveBank(game, plan)
  local messages = {}
  local clickedRow = false
  local keypadVisited = false
  local lastPrinted = nil
  local ended = #scriptEnds(game, BANK_SCRIPT)
  for _ = 1, plan.maxTicks or 6000 do
    local faults = scriptFaults(game, BANK_SCRIPT)
    if plan.refuseStale then
      assertFaultsNameTheBankTransfer(faults)
    else
      Assert.equal(
        #faults,
        0,
        "the source bank script completes every native operation: " .. table.concat(faults, ",")
      )
    end
    local snapshot = game:snapshot()
    if snapshot.dialogue.modal then
      local messageId = snapshot.dialogue.messageId
      if messageId ~= nil and messageId ~= lastPrinted then
        messages[#messages + 1] = messageId
        lastPrinted = messageId
      end
    else
      lastPrinted = nil
    end
    if #scriptEnds(game, BANK_SCRIPT) > ended then
      return { printed = messages, clickedRow = clickedRow, keypad = keypadVisited }
    end
    if snapshot.menu ~= nil and snapshot.menu.modal == true then
      clickedRow = true
      clickMenuRow(game, plan.row)
    elseif keypadOpen(game) then
      if plan.onWindow ~= nil then
        plan.onWindow(game)
        plan.onWindow = nil
      end
      if not keypadVisited then
        keypadVisited = true
        local status = waitKeypad(game, "the amount screen interaction")
        plan.keypad(game, status)
      else
        game:step()
      end
    elseif snapshot.dialogue.modal then
      pressAction(game)
    else
      game:step()
    end
  end
  error(
    "the source bank script never finished; row="
      .. tostring(clickedRow)
      .. ", keypad="
      .. tostring(keypadVisited)
      .. ", menu="
      .. tostring(game:snapshot().menu ~= nil)
      .. ", modal="
      .. tostring(game:snapshot().dialogue.modal)
      .. ", message="
      .. tostring(game:snapshot().dialogue.messageId)
      .. ", savings="
      .. tostring(savings(game))
      .. ", faults="
      .. table.concat(scriptFaults(game, BANK_SCRIPT), ","),
    0
  )
end

---@param printed integer[]
---@param messageId integer
---@return boolean
local function sawMessage(printed, messageId)
  for _, value in ipairs(printed) do
    if value == messageId then
      return true
    end
  end
  return false
end

---@class MomBankOptions
---@field money integer? the saved wallet the scenario starts with
---@field savings integer? the saved Mom savings the scenario starts with

---@param options MomBankOptions
---@param body fun(game: table)
local function withBank(options, body)
  local harness = AcceptanceHarness.new()
  local createGame = harness.gameFactory
  harness.gameFactory = function(versionId, map)
    local game = createGame(versionId, map)
    game.location = { mapSymbol = HOUSE_1F, fieldX = MOM_TILE.fieldX, fieldZ = MOM_TILE.fieldZ, facing = MOM_TILE.facing }
    game.playerData.profile.money = options.money or 3000
    return game
  end
  local game = harness:boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = HOUSE_1F,
    save = "fresh",
    fieldOptions = { recordingScriptHosts = true, audioHost = "recording" },
  })
  local ok, err = xpcall(function()
    -- Documented post-opening source state: the house opening scene has run
    -- (its own scene variable moved off its frame rule) and Elm's lab scene is
    -- past its fourth step, and Mom's first savings offer has been answered,
    -- so her object script answers with the money rows.
    game:setWorldState({ variable = VARS.VAR_SCENE_PLAYERS_HOUSE_1F, value = 1 })
    game:setWorldState({ variable = VARS.VAR_SCENE_ELMS_LAB, value = 4 })
    game:setWorldState({ flag = FLAGS.FLAG_TALKED_TO_MOM_AFTER_NAMING_RIVAL })
    game:setWorldState({ flag = FLAGS.FLAG_SYS_MOMS_SAVINGS })
    local state = assert(game.runtime.pokegearState, "the field runtime owns the phone state")
    state:setMom({ balance = options.savings or 0, purchases = {}, gifts = {} })
    game:waitForFieldEntry()
    game:pressAction()
    Assert.equal(game:interaction().scriptId, BANK_SCRIPT, "Mom's own object script answers the interaction")
    body(game)
    Assert.equal(game:renderAttempts(), 0, "the bank journey stops before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

-- ---------------------------------------------------------------------------
-- A deposit runs the source amount screen and moves exactly the accepted
-- amount from the wallet into the saved savings once.
-- ---------------------------------------------------------------------------

function T.tests.mom_deposits_the_accepted_amount_through_the_source_amount_screen()
  withBank({ money = 3000, savings = 1000 }, function(game)
    local result = driveBank(game, {
      row = BANK_ROW.deposit,
      onWindow = function(inner)
        local box = assert(inner.runtime.savingsBox, "the field runtime owns its savings window")
        local shown = box:snapshot()
        Assert.isTrue(shown.visible, "the deposit row opens the saved-balance window first")
        Assert.equal(shown.tileX, 1, "the window opens at its own source column")
        Assert.equal(shown.tileY, 1, "the window opens at its own source row")
        Assert.equal(box.WIDTH, 128, "the window is sixteen eight-pixel tiles wide")
        Assert.equal(box.HEIGHT, 64, "the window is eight eight-pixel tiles high")
        Assert.equal(shown.rows[1].y, 16, "the first balance row sits at the source offset")
        Assert.equal(shown.rows[2].y, 48, "the second balance row sits at the source offset")
        Assert.equal(shown.rows[1].value, 1000, "the window shows the deposited savings")
        Assert.equal(shown.rows[2].value, 3000, "the window shows the held money")

        -- Saving is denied while the bank owns an in-flight transfer.
        local saveOk, record = pcall(inner.runtime.captureGameSave, inner.runtime)
        Assert.isTrue(
          not saveOk or record == nil,
          "a save request while the bank owns the transfer is denied"
        )
      end,
      keypad = function(inner, status)
        -- Both live balances are captured when the screen opens: the deposit
        -- cap is the lesser of the held money and the savings capacity.
        Assert.equal(status.maxAmount, 3000, "a deposit is capped by the held money here")
        Assert.equal(status.maxDigits, 4, "the digit cells follow the actual maximum")

        -- The source amount screen offers ten digit cells plus clear, confirm
        -- and cancel affordances on the bottom display, laid out as a dpad
        -- grid the player can walk.
        local columns, rowsSeen, cells = {}, {}, {}
        for digit = 0, 9 do
          local key = sourceKey(status, "digit", digit)
          Assert.isTrue(key.width > 0 and key.height > 0, "digit " .. digit .. " keeps a touch rectangle")
          Assert.isTrue(
            key.x >= 0 and key.y >= 0 and key.x + key.width <= 256 and key.y + key.height <= 192,
            "digit " .. digit .. " stays on the bottom display"
          )
          local column, rowSeen = string.format("%.0f", key.x), string.format("%.0f", key.y)
          columns[column] = true
          rowsSeen[rowSeen] = true
          local cell = column .. ":" .. rowSeen
          Assert.isNil(cells[cell], "digit " .. digit .. " keeps its own grid cell")
          cells[cell] = true
        end
        local columnCount, rowCount = 0, 0
        for _ in pairs(columns) do
          columnCount = columnCount + 1
        end
        for _ in pairs(rowsSeen) do
          rowCount = rowCount + 1
        end
        -- sRodata.padHitboxes: digits 0-4 on one row and 5-9 on the next, 48
        -- pixels each from x 8 / y 56, and the three action buttons on their
        -- own 32-pixel row below.
        Assert.equal(columnCount, 5, "the digit cells form the source five-column pad")
        Assert.equal(rowCount, 2, "the digit cells form the source two-row pad")
        for _, key in ipairs(status.keys) do
          if key.role ~= "digit" then
            Assert.equal(key.y, 160, "the source action buttons sit on their own row")
          end
        end
        for _, role in ipairs({ "clear", "confirm", "cancel" }) do
          sourceKey(status, role)
        end

        tapDigits(inner, { 1, 2, 0, 0 })
        local entered = assert(bankHost(inner):status(), "the amount screen stays open")
        Assert.equal(entered.amount, 1200, "the digit cells spell the accepted amount")

        -- NumberEntry_UpdateBlink: a pressed key blinks the first frame for
        -- four ticks and the second for two, so the entry feedback toggles on
        -- the fixed tick that follows the last digit.
        local blink = entered.blinkVisible
        local toggled = false
        for _ = 1, 120 do
          inner:step()
          local current = assert(bankHost(inner):status(), "the amount screen stays open")
          if current.blinkVisible ~= blink then
            toggled = true
            break
          end
        end
        Assert.isTrue(toggled, "the source pressed-key blink runs on the fixed tick")
        tapRole(inner, "confirm")
      end,
    })

    Assert.isTrue(result.clickedRow, "the scenario selects the source deposit row")
    Assert.isTrue(result.keypad, "the scenario reaches the source amount screen")
    Assert.isTrue(sawMessage(result.printed, BANK_MESSAGE.deposited), "the source confirms the deposit")
    Assert.isFalse(sawMessage(result.printed, BANK_MESSAGE.cancel), "a confirmed deposit is not a cancel")

    local saved = savingsRecord(game)
    Assert.equal(wallet(game), 1800, "the deposit leaves the wallet it did not transfer")
    Assert.equal(saved.balance, 2200, "the deposit reaches Mom's savings exactly once")
    Assert.deepEqual(saved.gifts, {}, "a manual deposit never queues a Mom purchase gift")
    Assert.deepEqual(saved.purchases, {}, "a manual deposit never claims a Mom purchase")
    Assert.isTrue(
      game.runtime.scripts.worldState:isFlagSet(FLAGS.FLAG_SYS_MOMS_SAVINGS),
      "a manual deposit leaves the savings choice alone"
    )

    -- The window is closed by the script and the finished transfer is never
    -- replayed by a later tick.
    local box = assert(game.runtime.savingsBox, "the field runtime owns its savings window")
    Assert.isFalse(box:snapshot().visible, "the script closes the savings window")
    for _ = 1, 60 do
      game:step()
    end
    Assert.equal(wallet(game), 1800, "a finished deposit is not replayed")
    Assert.equal(savings(game), 2200, "a finished deposit is not credited twice")

    -- The settled field saves the transfer, and the saved envelope carries
    -- both owners.
    local capture = nil
    for _ = 1, 480 do
      local ok, record = pcall(game.runtime.captureGameSave, game.runtime)
      if ok and record ~= nil then
        capture = record
        break
      end
      game:step()
    end
    capture = assert(capture, "the settled field accepts its save after the transfer")
    Assert.equal(capture.playerData.profile.money, 1800, "the save keeps the transferred wallet")
    Assert.equal(capture.playerData.profile.coins, 0, "a new journey carries no Game Corner coins")
    Assert.equal(capture.pokegear.phone.mom.balance, 2200, "the save keeps the transferred savings")
  end)
end

-- ---------------------------------------------------------------------------
-- A withdrawal is capped by the deposited savings and moves exactly the
-- accepted amount back into the wallet.
-- ---------------------------------------------------------------------------

function T.tests.mom_withdraws_only_up_to_the_deposited_savings()
  withBank({ money = 3000, savings = 1500 }, function(game)
    local result = driveBank(game, {
      row = BANK_ROW.withdraw,
      keypad = function(inner, status)
        Assert.equal(status.maxAmount, 1500, "a withdrawal is capped by the deposited savings")
        Assert.equal(status.maxDigits, 4, "the digit cells follow the withdrawn maximum")
        tapDigits(inner, { 1, 5, 0, 0 })
        Assert.equal(
          assert(bankHost(inner):status(), "the amount screen stays open").amount,
          1500,
          "the digit cells spell the whole deposited balance"
        )
        tapRole(inner, "confirm")
      end,
    })

    Assert.isTrue(sawMessage(result.printed, BANK_MESSAGE.withdrawn), "the source confirms the withdrawal")
    Assert.equal(wallet(game), 4500, "the withdrawal reaches the wallet exactly once")
    Assert.equal(savings(game), 0, "the withdrawal leaves the emptied savings")
  end)
end

-- ---------------------------------------------------------------------------
-- The destination capacity and the source balance are checked before the
-- amount screen, so a full destination or an empty source never opens it.
-- ---------------------------------------------------------------------------

function T.tests.a_full_destination_or_empty_source_refuses_before_the_amount_screen()
  local cases = {
    {
      label = "a full savings account refuses a deposit",
      money = 3000,
      savings = MAX_BANK,
      row = BANK_ROW.deposit,
      expected = BANK_MESSAGE.bankFull,
      wallet = 3000,
      savings = MAX_BANK,
    },
    {
      label = "a full wallet refuses a withdrawal",
      money = MAX_MONEY,
      savings = 1000,
      row = BANK_ROW.withdraw,
      expected = BANK_MESSAGE.walletFull,
      wallet = MAX_MONEY,
      savings = 1000,
    },
    {
      label = "an empty savings account refuses a withdrawal",
      money = 3000,
      savings = 0,
      row = BANK_ROW.withdraw,
      expected = BANK_MESSAGE.noSavings,
      wallet = 3000,
      savings = 0,
    },
    {
      label = "an empty wallet refuses a deposit",
      money = 0,
      savings = 500,
      row = BANK_ROW.deposit,
      expected = BANK_MESSAGE.noMoney,
      wallet = 0,
      savings = 500,
    },
  }
  for _, case in ipairs(cases) do
    withBank({ money = case.money, savings = case.savings }, function(game)
      local result = driveBank(game, {
        row = case.row,
        keypad = function()
          error(case.label .. ": the amount screen must not open", 0)
        end,
      })
      Assert.isFalse(result.keypad, case.label .. ": no amount screen opens")
      Assert.isTrue(sawMessage(result.printed, case.expected), case.label .. ": the source says why")
      Assert.equal(wallet(game), case.wallet, case.label .. ": the wallet is untouched")
      Assert.equal(savings(game), case.savings, case.label .. ": the savings are untouched")
    end)
  end
end

-- ---------------------------------------------------------------------------
-- A zero entry, a cleared entry and a cancelled screen change nobody's money.
-- ---------------------------------------------------------------------------

function T.tests.a_zero_cleared_or_cancelled_entry_moves_nothing()
  local plans = {
    {
      label = "a confirmed zero entry",
      keypad = function(inner)
        tapRole(inner, "confirm")
      end,
    },
    {
      label = "a backspaced entry",
      keypad = function(inner, status)
        Assert.equal(status.amount, 0, "a fresh amount screen starts empty")
        tapDigits(inner, { 0, 0 })
        local zeroed = assert(bankHost(inner):status(), "the amount screen stays open")
        -- NumberEntry_ComputeValue reads the fixed cells, so a fresh four-cell
        -- entry typed as 0,0 still spells zero.
        Assert.equal(zeroed.amount, 0, "the fixed digit cells still spell zero")
        Assert.equal(zeroed.cursor, 2, "each digit advances the entry cursor")
        tapRole(inner, "clear")
        local back = assert(bankHost(inner):status(), "the amount screen stays open")
        -- The source button is labelled BACK and only walks the cursor left;
        -- the fixed cells keep their digits.
        Assert.equal(back.cursor, 1, "the source BACK key walks the cursor left")
        Assert.equal(back.amount, 0, "the source BACK key leaves the entered cells alone")
        tapRole(inner, "confirm")
      end,
    },
    {
      label = "a cancelled screen",
      keypad = function(inner)
        tapDigits(inner, { 7, 5, 0 })
        tapRole(inner, "cancel")
      end,
    },
  }
  for _, plan in ipairs(plans) do
    withBank({ money = 3000, savings = 1000 }, function(game)
      local result = driveBank(game, { row = BANK_ROW.deposit, keypad = plan.keypad })
      Assert.isTrue(result.keypad, plan.label .. ": reaches the amount screen")
      Assert.isTrue(sawMessage(result.printed, BANK_MESSAGE.cancel), plan.label .. ": the source cancels")
      Assert.isFalse(sawMessage(result.printed, BANK_MESSAGE.deposited), plan.label .. ": nothing is deposited")
      Assert.equal(wallet(game), 3000, plan.label .. ": the wallet is untouched")
      Assert.equal(savings(game), 1000, plan.label .. ": the savings are untouched")
    end)
  end
end

-- ---------------------------------------------------------------------------
-- The transfer revalidates both owners against what it captured when the
-- amount screen opened: an outside savings write aborts it without touching
-- either balance and closes the screen.
-- ---------------------------------------------------------------------------

function T.tests.a_stale_savings_revision_aborts_the_transfer_without_touching_either_owner()
  withBank({ money = 3000, savings = 1000 }, function(game)
    local result = driveBank(game, {
      row = BANK_ROW.deposit,
      keypad = function(inner)
        tapDigits(inner, { 1, 2, 0, 0 })
        -- An unrelated owner write (a phone purchase spending part of the
        -- savings) moves the savings revision between open and confirm.
        local state = assert(inner.runtime.pokegearState, "the field runtime owns the phone state")
        state:setMom({ balance = 1600, purchases = {}, gifts = {} })
        tapRole(inner, "confirm")
        for _ = 1, 120 do
          if not keypadOpen(inner) then
            break
          end
          inner:step()
        end
      end,
      maxTicks = 6000,
      refuseStale = true,
    })

    Assert.isTrue(result.keypad, "the scenario reaches the source amount screen")
    assertFaultsNameTheBankTransfer(scriptFaults(game, BANK_SCRIPT))
    Assert.isFalse(keypadOpen(game), "the stale transfer closes the amount screen")
    Assert.equal(wallet(game), 3000, "the stale transfer never charges the wallet")
    Assert.equal(savings(game), 1600, "the stale transfer never overwrites the outside savings write")
    Assert.isFalse(sawMessage(result.printed, BANK_MESSAGE.deposited), "the stale transfer is not a deposit")
  end)
end

-- ---------------------------------------------------------------------------
-- A save written before the canonical coin balance existed gains exactly the
-- empty coin field on the profile, keeps every owner the earlier release
-- wrote, and continues.
-- ---------------------------------------------------------------------------

local PREVIOUS_GAME_SCHEMA = "g4-game-save-v18"

---@param value table
---@return table
local function deepCopy(value)
  if type(value) ~= "table" then
    return value
  end
  local copy = {}
  for key, item in pairs(value) do
    copy[key] = deepCopy(item)
  end
  return copy
end

---@param game table
---@return string the save payload directory inside the acceptance save root
local function payloadDirectory(game)
  return game.saveNamespace .. "/global/games"
end

---@param game table
---@param record table
---@return boolean
local function writePayload(game, record)
  assert(love.filesystem.createDirectory(payloadDirectory(game)), "the acceptance save root holds its payload")
  return love.filesystem.write(payloadDirectory(game) .. "/" .. record.saveId .. ".lua", LuaWriter.encode(record))
end

---@param record table
---@return string[] the record's top-level owners, sorted
local function ownerNames(record)
  local names = {}
  for key in pairs(record) do
    names[#names + 1] = key
  end
  table.sort(names)
  return names
end

---@param record table the record to continue from
---@return table game
local function bootFrom(record)
  return AcceptanceHarness.new({
    gameFactory = function()
      return record
    end,
  }):boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = HOUSE_1F,
    save = "continue",
    seedSave = record,
    fieldOptions = { recordingScriptHosts = true, audioHost = "recording" },
  })
end

---@param game table
---@param label string
---@return table the settled captured game save
local function settledCapture(game, label)
  local lastError = nil
  for _ = 1, 480 do
    local ok, record, reason = pcall(game.runtime.captureGameSave, game.runtime)
    if ok and record ~= nil then
      return record
    end
    lastError = ok and tostring(reason or "capture returned no record") or tostring(record)
    game:step()
  end
  error("the settled field never accepted its save: " .. label .. "; last failure: " .. tostring(lastError), 0)
end

function T.tests.the_previous_envelope_gains_an_empty_coin_owner()
  local versionId = AcceptanceHarness.defaultVersion()
  local first = AcceptanceHarness.new():boot({
    versionId = versionId,
    map = HOUSE_1F,
    save = "fresh",
    fieldOptions = { recordingScriptHosts = true, audioHost = "recording" },
  })
  local captured, migrated = nil, nil
  local ok, err = xpcall(function()
    -- Documented post-opening state: the house opening scene has already run,
    -- so its frame rule no longer owns the field during the save work.
    first:setWorldState({ variable = VARS.VAR_SCENE_PLAYERS_HOUSE_1F, value = 1 })
    first:waitForFieldEntry()
    captured = settledCapture(first, "the fresh journey")
    local profile = assert(captured.playerData.profile, "the save carries the canonical profile")
    Assert.equal(profile.money, 3000, "a new journey carries its starting money")
    Assert.equal(profile.coins, 0, "a new journey carries an empty coin balance")

    local store = assert(first.runtime.saveStore, "the field runtime owns its save store")
    Assert.isTrue(store:publishFirst(captured), "the journey publishes its own save")

    local legacy = deepCopy(captured)
    legacy.schema = PREVIOUS_GAME_SCHEMA
    legacy.playerData.profile.coins = nil
    Assert.isTrue(writePayload(first, legacy), "the earlier envelope is written")

    migrated = assert(store:load(captured.saveId), "the published save loads through the production store")
    Assert.equal(migrated.schema, captured.schema, "the migrated envelope carries the current schema")
    Assert.equal(migrated.playerData.profile.coins, 0, "the migration initializes an empty coin balance")
    Assert.equal(migrated.playerData.profile.money, 3000, "the migration keeps the saved money")

    local added = {}
    local previous = {}
    for _, name in ipairs(ownerNames(legacy)) do
      previous[name] = true
    end
    for _, name in ipairs(ownerNames(migrated)) do
      if not previous[name] then
        added[#added + 1] = name
      end
    end
    Assert.deepEqual(added, {}, "the migration adds no owner beyond the coin balance field")
    Assert.deepEqual(migrated.pokegear, captured.pokegear, "the migration keeps the phone and savings state")
    Assert.deepEqual(migrated.mons, captured.mons, "the migration keeps the canonical party and boxes")
  end, debug.traceback)
  first:close()
  if not ok then
    error(err, 0)
  end

  -- Continue through the production store: the migrated save boots and
  -- republishes the empty coin balance unchanged.
  local resumed = bootFrom(migrated)
  local resumedOk, resumedErr = xpcall(function()
    resumed:waitForFieldEntry()
    local republished = settledCapture(resumed, "the continued journey")
    Assert.equal(republished.playerData.profile.coins, 0, "Continue keeps the empty coin balance")
    Assert.equal(republished.playerData.profile.money, 3000, "Continue keeps the saved money")
    Assert.equal(resumed:renderAttempts(), 0, "the save transition stops before GPU rendering")
  end, debug.traceback)
  resumed:close()
  if not resumedOk then
    error(resumedErr, 0)
  end

  -- A current save whose coin balance is out of the source range is refused
  -- instead of being clamped into a plausible balance.
  local corrupt = deepCopy(migrated)
  corrupt.playerData.profile.coins = 50001
  local rejected = AcceptanceHarness.new({
    gameFactory = function()
      return corrupt
    end,
  })
  local bootOk, bootErr = pcall(function()
    rejected:boot({
      versionId = versionId,
      map = HOUSE_1F,
      save = "continue",
      seedSave = corrupt,
      fieldOptions = { recordingScriptHosts = true, audioHost = "recording" },
    })
  end)
  Assert.isFalse(bootOk, "a coin balance above the source cap is refused: " .. tostring(bootErr))

  -- A present coin field that is not an integer is refused too.
  local malformed = deepCopy(migrated)
  malformed.playerData.profile.coins = 12.5
  local malformedHarness = AcceptanceHarness.new({
    gameFactory = function()
      return malformed
    end,
  })
  local malformedOk, malformedErr = pcall(function()
    malformedHarness:boot({
      versionId = versionId,
      map = HOUSE_1F,
      save = "continue",
      seedSave = malformed,
      fieldOptions = { recordingScriptHosts = true, audioHost = "recording" },
    })
  end)
  Assert.isFalse(
    malformedOk,
    "a fractional coin balance is refused: " .. tostring(malformedErr)
  )
end

return T
