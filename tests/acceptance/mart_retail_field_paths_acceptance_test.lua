-- Production field-script journeys for the two Pokeathlon clerk launch paths
-- and the task-owned Bag sale child.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local AcceptanceScripts = require("tests.acceptance.support.AcceptanceScripts")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local PlayTime = require("libs.hgss.src.save.PlayTime")
local BagSave = require("libs.hgss.src.save.BagSave")
local MartSave = require("libs.hgss.src.save.MartSave")
local LocalClock = require("game.src.LocalClock")

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = {
      "field-runtime",
      "audio-bank:702",
      "audio-bank:709",
      "map-data:31",
      "map-data:33",
      "map-data:47",
      "map-data:48",
      "map-data:60",
      "map:7",
      "map:60",
      "map:281",
      "mart:global",
      "message-bank:138",
      "script-member:123",
    },
    tags = { "field", "mart", "acceptance" },
  },
  tests = {},
}

local ATHLETE_CLERK = "vanilla.hgss.scr_seq.0123.script_001"
local CARD_CLERK = "vanilla.hgss.scr_seq.0123.script_002"
local ATHLETE_CLERK_READY = FieldScriptSymbols.flagsByName.FLAG_UNK_114
local CARD_CLERK_READY = FieldScriptSymbols.flagsByName.FLAG_UNK_115
local CONTINUATION = FieldScriptSymbols.variablesByName.VAR_UNK_407C
local SELL_SCRIPT = "acceptance.mart_sell_field"
local BALLS_SCRIPT = "acceptance.mart_ten_balls"
local ATHLETE_SCRIPT = "acceptance.mart_athlete_matrix"
local CARD_SCRIPTS = { "acceptance.mart_card_group_before", "acceptance.mart_card_group_after" }
local SEAL_SCRIPT = "acceptance.mart_seal_legacy"
local DECORATION_SCRIPT = "acceptance.mart_decoration_legacy"

local scripts = {}
local hostStatus
local pressCancel
for scriptId, source in pairs(AcceptanceScripts) do
  scripts[scriptId] = source
end
scripts[SELL_SCRIPT] = [[
local S = require("gen4.script")

return S.script({
  api = 1,
  id = "acceptance.mart_sell_field",
  steps = {
    S.mart({ kind = "sell" }),
    S.setVar({ variable = "VAR_UNK_407C", value = 7 }),
    S.stop(),
  },
})
]]
local function martScript(id, kind, selector)
  local selectorStep = selector == nil and "" or (", selector = " .. tostring(selector))
  return ('local S = require("gen4.script")\n\nreturn S.script({\n'
    .. '  api = 1,\n  id = "' .. id .. '",\n  steps = {\n'
    .. '    S.mart({ kind = "' .. kind .. '"' .. selectorStep .. ' }),\n'
    .. '    S.stop(),\n  },\n})\n')
end
scripts[BALLS_SCRIPT] = martScript(BALLS_SCRIPT, "standard")
scripts[ATHLETE_SCRIPT] = martScript(ATHLETE_SCRIPT, "athlete")
scripts[CARD_SCRIPTS[1]] = martScript(CARD_SCRIPTS[1], "data_cards")
scripts[CARD_SCRIPTS[2]] = martScript(CARD_SCRIPTS[2], "data_cards")
scripts[SEAL_SCRIPT] = martScript(SEAL_SCRIPT, "seal", 0)
scripts[DECORATION_SCRIPT] = [[
local S = require("gen4.script")

return S.script({
  api = 1,
  id = "acceptance.mart_decoration_legacy",
  steps = {
    S.mart({ kind = "decoration", selector = 0 }),
    S.setVar({ variable = "VAR_UNK_407C", value = 8 }),
    S.stop(),
  },
})
]]

local function withGame(fn, options)
  options = options or {}
  local date = options.date or { year = 2000, month = 1, day = 1, hour = 12, minute = 0, second = 0 }
  local clock = LocalClock.new(function()
    return date
  end)
  local gameFactory = function(versionId, map)
    local worldState = FieldEventState.new()
    local mart = MartSave.empty()
    mart.athletePoints = 99999
    mart.ownedDataCardsMask = options.ownedDataCardsMask or 0
    return {
      saveId = "save-00000001",
      versionId = versionId,
      location = { mapSymbol = map, fieldX = 4, fieldZ = 10, facing = "south" },
      playerData = {
        profile = { name = "GOLD", gender = 0, trainerId = 1, money = 3000, badges = 0, nationalDex = false },
        options = { textSpeed = "fastest", textFrame = 0 },
      },
      fieldTravel = { lastHealSpawn = "SPAWN_NEW_BARK" },
      fashionCase = require("libs.hgss.src.save.FashionCaseState").empty(),
      playTime = PlayTime.new(),
      worldState = worldState,
      mons = require("tests.support.MonBucket").emptyForVersion(versionId),
      bag = BagSave.empty(),
      mart = mart,
    }
  end
  local game = AcceptanceHarness.new({ gameFactory = gameFactory }):boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = "MAP_NEW_BARK",
    save = "fresh",
    fieldOptions = {
      acceptanceScripts = scripts,
      localClock = clock,
      recordingScriptHosts = options.recordingScriptHosts == true,
    },
  })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    fn(game)
    Assert.equal(game:renderAttempts(), 0, "retail mart path acceptance must stop before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

local NAVIGATION = {
  [0] = { up = 4, down = 2, left = 6, right = 1 },
  [1] = { up = 8, down = 3, left = 0, right = 7 },
  [2] = { up = 0, down = 4, left = 6, right = 3 },
  [3] = { up = 1, down = 5, left = 2, right = 7 },
  [4] = { up = 2, down = 0, left = 6, right = 5 },
  [5] = { up = 3, down = 8, left = 4, right = 7 },
  [6] = { up = 4, down = 0, left = 8, right = 8 },
  [7] = { up = 4, down = 0, left = 8, right = 8 },
  [8] = { up = 5, down = 1, left = 8, right = 8 },
}

local function selectEntry(game, target)
  local start = hostStatus(game).selection
  local queue = { { selection = start, path = {} } }
  local visited = { [start] = true }
  local directions = { "up", "down", "left", "right" }
  local path
  local cursor = 1
  while cursor <= #queue do
    local current = queue[cursor]
    cursor = cursor + 1
    if current.selection == target then
      path = current.path
      break
    end
    for _, direction in ipairs(directions) do
      local nextSelection = NAVIGATION[current.selection][direction]
      if nextSelection < 6 and not visited[nextSelection] then
        visited[nextSelection] = true
        local nextPath = {}
        for _, step in ipairs(current.path) do
          nextPath[#nextPath + 1] = step
        end
        nextPath[#nextPath + 1] = direction
        queue[#queue + 1] = { selection = nextSelection, path = nextPath }
      end
    end
  end
  assert(path, "mart slot has a source navigation path: start=" .. tostring(start) .. ", target=" .. tostring(target))
  for _, direction in ipairs(path) do
    local fieldDirection = ({ up = "north", down = "south", left = "west", right = "east" })[direction]
    game:move(fieldDirection)
  end
  Assert.equal(hostStatus(game).selection, target, "source navigation focuses the requested stock slot")
end

local function openScriptMart(game, scriptId)
  game:startScript(scriptId)
  game:advanceUntil("the script-owned mart opens: " .. scriptId, function()
    return game.runtime.martHost:isActive()
  end, 480)
  return hostStatus(game)
end

local function advancePrinter(game, printerState, targetState, label, maxEdges)
  for _ = 1, maxEdges do
    local state = hostStatus(game).state
    if state == targetState then
      return
    end
    Assert.equal(state, printerState, label .. " advances only its source printer")
    game:pressAction()
  end
  Assert.equal(hostStatus(game).state, targetState, label .. " reaches its target state")
end

local function purchaseSelected(game, quantity)
  game:pressAction()
  if quantity ~= nil then
    game:advanceUntil("the source quantity prompt opens", function()
      return hostStatus(game).state == "quantity_prompt"
    end, 120)
    advancePrinter(game, "quantity_prompt", "quantity", "quantity prompt", 120)
    if quantity == 10 then
      game:move("east")
      game:move("south")
    end
    Assert.equal(hostStatus(game).quantity, quantity, "the production quantity selector retains the requested count")
    game:pressAction()
  end
  game:advanceUntil("the purchase confirmation printer opens", function()
    return hostStatus(game).state == "confirm_prompt"
  end, 180)
  advancePrinter(game, "confirm_prompt", "confirm", "purchase confirmation", 120)
  game:pressAction()
  game:advanceUntil("the purchase result printer opens", function()
    return hostStatus(game).state == "success_print"
  end, 120)
  advancePrinter(game, "success_print", "success_ack", "purchase result", 480)
end

local function acknowledgePurchase(game)
  game:pressAction()
  game:advanceUntil("purchase acknowledgement returns to browsing", function()
    return hostStatus(game).state == "browse"
  end, 240)
end

local function closeScriptMart(game)
  pressCancel(game)
  game:advanceUntil("the script mart returns to its caller", function()
    return not game.runtime.martHost:isActive() and game:snapshot().foregroundScript == nil
  end, 240)
end

local function addOneDay(date)
  local monthDays = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
  local leap = date.year % 4 == 0 and (date.year % 100 ~= 0 or date.year % 400 == 0)
  if leap then
    monthDays[2] = 29
  end
  date.day = date.day + 1
  if date.day > monthDays[date.month] then
    date.day = 1
    date.month = date.month + 1
    if date.month > 12 then
      date.month = 1
      date.year = date.year + 1
    end
  end
end

local function dateForAthleteStock(catalog)
  for offset = 0, 6 do
    local rows = catalog.athleteStocks[offset + 1]
    local apricorn, other
    for index = 1, math.min(6, #rows) do
      local row = rows[index]
      if catalog.apricorns[row.subjectKey] ~= nil then
        apricorn = apricorn or index
      else
        other = other or index
      end
    end
    if apricorn ~= nil and other ~= nil then
      return { year = 2000, month = 1, day = 2 + offset, hour = 12, minute = 0, second = 0 }, apricorn, other
    end
  end
  error("the real Athlete catalog has a weekday with an Apricorn and a Bag item in its first page")
end

hostStatus = function(game)
  local host = assert(game.runtime.martHost)
  Assert.isTrue(host:isActive(), "the field script keeps its mart child active")
  return assert(host:status())
end

pressCancel = function(game)
  game.runtime:pressCancel()
  game:step()
  game.runtime:releaseCancel()
end

local function reachRetailMart(game, scriptId)
  game:startScript(scriptId)
  for _ = 1, 160 do
    if game.runtime.martHost:isActive() then
      return hostStatus(game)
    end
    local menuTask
    for _, task in ipairs(game.runtime.scripts.scheduler:tasks()) do
      if task.taskType == "menu" then
        menuTask = task
        break
      end
    end
    if menuTask then
      local selected = menuTask.state.menuDefinition.items[menuTask.state.selectedIndex + 1]
      Assert.equal(selected.value, 0, scriptId .. " starts the source clerk menu on mart value zero")
      game:pressAction()
    elseif game.runtime.dialogue:status().state == "WAITING_BOUNDARY"
      or game.runtime.dialogue:status().state == "WAITING_CLOSE"
    then
      game:pressAction()
    else
      game:step()
    end
    if game.runtime.scripts.scheduler:foregroundScriptId() == nil then
      break
    end
  end
  Assert.isTrue(
    game.runtime.martHost:isActive(),
    scriptId .. " reaches the source mart command"
  )
  return hostStatus(game)
end

function T.tests.athlete_clerk_runs_the_zero_return_prelude_before_its_real_shop()
  withGame(function(game)
    local status = reachRetailMart(game, ATHLETE_CLERK)
    Assert.isTrue(game.runtime.scripts.worldState:isFlagSet(ATHLETE_CLERK_READY), "the source greeting marks the Athlete clerk ready")
    Assert.equal(status.presentationKind, "athlete_items", "opcode 771 opens the source Athlete stock")
    Assert.isTrue(
      game.runtime.scripts.worldState:getVar(CONTINUATION) ~= 7,
      "the script remains blocked before child return"
    )
    Assert.notNil(game:snapshot().foregroundScript, "the clerk script remains blocked by the child")
    pressCancel(game)
  end)
end

function T.tests.data_card_clerk_runs_its_prefix_query_before_the_real_shop()
  withGame(function(game)
    local status = reachRetailMart(game, CARD_CLERK)
    Assert.isTrue(game.runtime.scripts.worldState:isFlagSet(CARD_CLERK_READY), "the source greeting marks the Data Card clerk ready")
    Assert.equal(status.presentationKind, "athlete_cards", "opcode 772 opens the source Data Card stock")
    Assert.notNil(game:snapshot().foregroundScript, "the clerk script remains blocked by the child")
    pressCancel(game)
  end)
end

function T.tests.standard_stock_sells_ten_poke_balls_and_grants_one_acknowledged_bonus()
  withGame(function(game)
    game:waitForFieldEntry()
    game.runtime.scripts.worldState:setFlag(0x09A)
    local status = openScriptMart(game, BALLS_SCRIPT)
    Assert.equal(
      status.currentEntry.displayItemKey,
      "POKE_BALL",
      "flag 0x09A allows zero-badge stock to begin with Poké Balls"
    )
    local startingMoney = game.runtime.playerData.profile.money
    purchaseSelected(game, 10)

    Assert.equal(game.runtime.bagService:quantity("POKE_BALL"), 10, "the confirmed quantity grants ten Poké Balls")
    Assert.equal(game.runtime.bagService:quantity("PREMIER_BALL"), 0, "the bonus waits for success acknowledgement")
    Assert.equal(game.runtime.playerData.profile.money, startingMoney - 2000, "the ordinary item price is charged once")
    game:pressAction()
    game:advanceUntil("the Premier Ball bonus printer opens", function()
      return hostStatus(game).state == "bonus_print"
    end, 120)
    advancePrinter(game, "bonus_print", "bonus_ack", "Premier Ball bonus", 480)
    Assert.equal(game.runtime.bagService:quantity("PREMIER_BALL"), 1, "one acknowledged ten-ball purchase grants one Premier Ball")
    Assert.equal(game.runtime.martService:capture().statistics.premierBallsEarned, 1, "the bonus statistic records exactly one grant")
    game:pressAction()
    game:advanceUntil("bonus acknowledgement returns to browsing", function()
      return hostStatus(game).state == "browse"
    end, 120)
    closeScriptMart(game)
    Assert.equal(game.runtime.bagService:quantity("PREMIER_BALL"), 1, "closing the clerk does not replay the bonus")
  end)
end

function T.tests.athlete_shop_buys_apricorn_and_item_then_resets_daily_slots_after_date_rollover()
  local date = { year = 2000, month = 1, day = 2, hour = 12, minute = 0, second = 0 }
  withGame(function(game)
    game:waitForFieldEntry()
    local stockDate, apricornIndex, itemIndex = dateForAthleteStock(game.runtime.martCatalog)
    date.year, date.month, date.day = stockDate.year, stockDate.month, stockDate.day
    local initial = openScriptMart(game, ATHLETE_SCRIPT)
    Assert.equal(initial.presentationKind, "athlete_items", "the source Athlete opcode opens AP stock")
    local catalog = game.runtime.martCatalog
    local stockRows = catalog.athleteStocks[date.day - 1]
    local apricornRow, itemRow = stockRows[apricornIndex], stockRows[itemIndex]
    Assert.notNil(catalog.apricorns[apricornRow.subjectKey], "the selected source row is an Apricorn")
    Assert.isNil(catalog.apricorns[itemRow.subjectKey], "the second source row is a Bag item")

    selectEntry(game, apricornIndex - 1)
    Assert.equal(hostStatus(game).currentEntry.displayItemKey, apricornRow.subjectKey, "the retail stock selection resolves its Apricorn")
    local pointsBefore = game.runtime.martService:capture().athletePoints
    purchaseSelected(game)
    acknowledgePurchase(game)
    Assert.equal(game.runtime.martService:capture().apricorns[apricornRow.subjectKey], 1, "the purchase grants the selected Apricorn")
    Assert.isTrue(game.runtime.martService:capture().athletePoints < pointsBefore, "the Apricorn purchase spends AP")

    selectEntry(game, itemIndex - 1)
    Assert.equal(hostStatus(game).currentEntry.displayItemKey, itemRow.subjectKey, "the same source stock exposes its second AP item")
    local itemPointsBefore = game.runtime.martService:capture().athletePoints
    purchaseSelected(game)
    acknowledgePurchase(game)
    Assert.isTrue(game.runtime.bagService:quantity(itemRow.subjectKey) > 0, "the second AP purchase reaches the real Bag")
    Assert.isTrue(game.runtime.martService:capture().athletePoints < itemPointsBefore, "the second purchase spends AP")
    Assert.isTrue(game.runtime.martService:capture().dailyPurchasedMask ~= 0, "both purchases reserve source daily slots")
    closeScriptMart(game)

    local priorDay = game.runtime.martService:capture().lastProcessedDay
    addOneDay(date)
    openScriptMart(game, ATHLETE_SCRIPT)
    local rolled = game.runtime.martService:capture()
    Assert.equal(rolled.dailyPurchasedMask, 0, "opening on the next civil date clears the previous day's purchase slots")
    Assert.isTrue(rolled.lastProcessedDay > priorDay, "the date rollover advances the persisted processed-day ordinal")
    closeScriptMart(game)
  end, { date = date })
end

function T.tests.data_card_purchase_crosses_the_real_six_card_stock_group_boundary()
  withGame(function(game)
    game:waitForFieldEntry()
    local catalog = game.runtime.martCatalog
    local firstGroup = catalog.dataCardStocks[1]
    local unownedIndex
    for index, row in ipairs(firstGroup) do
      if catalog.cards[row.subjectKey].ownershipIndex == 5 then
        unownedIndex = index
        break
      end
    end
    Assert.notNil(unownedIndex, "the first Data Card group includes ownership index five")

    local before = openScriptMart(game, CARD_SCRIPTS[1])
    Assert.equal(before.presentationKind, "athlete_cards", "the Data Card opcode uses its source presentation")
    Assert.equal(game.runtime.martHost:query("card_prefix"), 5, "five seeded cards leave the prefix at the final item in group zero")
    selectEntry(game, unownedIndex - 1)
    local cardKey = firstGroup[unownedIndex].subjectKey
    Assert.equal(hostStatus(game).currentEntry.displayItemKey, cardKey, "the final group-zero card is selected from the generated stock")
    purchaseSelected(game)
    acknowledgePurchase(game)
    Assert.equal(game.runtime.martHost:query("card_prefix"), 6, "committing the sixth contiguous card advances the prefix")
    closeScriptMart(game)

    local after = openScriptMart(game, CARD_SCRIPTS[2])
    local nextGroup = catalog.dataCardStocks[2]
    Assert.equal(after.entryCount, #nextGroup, "the next opening resolves the adjacent six-card stock group")
    for index, row in ipairs(nextGroup) do
      Assert.equal(after.entries[index].displayItemKey, row.subjectKey, "the next stock group follows generated source order")
    end
    closeScriptMart(game)
  end, { ownedDataCardsMask = 31 })
end

function T.tests.seal_shop_grants_a_seal_while_legacy_decoration_stays_non_granting()
  withGame(function(game)
    game:waitForFieldEntry()
    local beforeSeals = game.runtime.martService:capture().sealCase.loose
    local seals = openScriptMart(game, SEAL_SCRIPT)
    Assert.equal(seals.presentationKind, "seals", "the legacy Seal command opens generated seal stock")
    local sealSlot = 0
    for index = 1, math.min(6, #seals.entries) do
      if seals.entries[index].price > 0 then
        sealSlot = index - 1
        break
      end
    end
    selectEntry(game, sealSlot)
    seals = hostStatus(game)
    local sealItem = seals.currentEntry.displayItemKey
    Assert.equal(seals.currentEntry.unitPrice, 100, "the source Seal Mart charges its fixed retail price")
    local moneyBeforeSeal = game.runtime.playerData.profile.money
    purchaseSelected(game, 1)
    acknowledgePurchase(game)
    local afterSeals = game.runtime.martService:capture().sealCase.loose
    local granted = 0
    for key, count in pairs(afterSeals) do
      granted = granted + count - (beforeSeals[key] or 0)
    end
    Assert.equal(granted, 1, "the confirmed Seal purchase grants exactly one seal to the seal case")
    Assert.equal(game.runtime.playerData.profile.money, moneyBeforeSeal - 100, "the Seal purchase deducts exactly 100 from player money")
    closeScriptMart(game)

    local moneyBeforeDecoration = game.runtime.playerData.profile.money
    local decoration = openScriptMart(game, DECORATION_SCRIPT)
    Assert.equal(decoration.presentationKind, "legacy_decorations", "the Decoration command retains its legacy presentation")
    Assert.isTrue(decoration.entryCount > 0, "the generated legacy Decoration stock has an outcome to select")
    local displayItem = decoration.currentEntry.displayItemKey
    local itemCount = game.runtime.bagService:quantity(displayItem)
    local spentBeforeDecoration = game.runtime.martService:capture().statistics.currencySpent
    game:pressAction()
    Assert.isTrue(game.runtime.martHost:isActive(), "selecting a legacy Decoration retains the owned modal")
    game:advanceUntil("the unsupported Decoration refusal opens", function()
      return hostStatus(game).state == "error_print"
    end, 120)
    advancePrinter(game, "error_print", "error_ack", "legacy Decoration refusal", 480)
    local faults = game:recordsForScript(DECORATION_SCRIPT, "script.error")
    Assert.equal(game.runtime.playerData.profile.money, moneyBeforeDecoration, "the unsupported Decoration outcome charges no money")
    Assert.equal(game.runtime.bagService:quantity(displayItem), itemCount, "the unsupported Decoration outcome grants no Bag item")
    Assert.equal(game.runtime.martService:capture().statistics.currencySpent, spentBeforeDecoration, "the failed legacy transaction records no spend")
    Assert.equal(#faults, 0, "the legacy Decoration return has no script fault: " .. tostring(faults[1] and faults[1].payload.message))
    game:pressAction()
    game:advanceUntil("the Decoration refusal returns to stock browsing", function()
      return hostStatus(game).state == "browse"
    end, 120)
    closeScriptMart(game)
    Assert.equal(game.runtime.scripts.worldState:getVar(CONTINUATION), 8, "the caller resumes after the legacy Decoration outcome")
    Assert.notNil(sealItem, "the generated Seal presentation supplied a semantic display item")
  end, { recordingScriptHosts = true })
end

function T.tests.script_sell_child_owns_modal_input_and_returns_to_the_field_once()
  withGame(function(game)
    Assert.isTrue(game.runtime.bagService:add("POTION", 2), "sale setup uses the production Bag service")
    game:startScript(SELL_SCRIPT)
    game:advanceUntil("the script-owned sell child opens", function()
      return game.runtime.martHost:isActive()
    end, 480)

    local status = hostStatus(game)
    Assert.equal(status.martKind, "sell", "the sell opcode presents the existing Bag sale child")
    Assert.equal(status.state, "browsing", "the sale child begins on the Bag selection state")
    Assert.isNil(game.runtime:captureGameSave(), "an active sale child prohibits save capture")
    game:advanceUntil("the Bag sale child finishes opening", function()
      return hostStatus(game).phase == "interactive"
    end, 60)
    local before = game:snapshot().player
    game:move("north")
    game.runtime:pressMenu()
    game:step()
    game.runtime:releaseMenu()
    Assert.isTrue(game.runtime.martHost:isActive(), "modal input does not dismiss the sell child")
    Assert.equal(game:snapshot().player.fieldX, before.fieldX, "sell modality suppresses field movement")
    Assert.equal(game:snapshot().player.fieldZ, before.fieldZ, "sell modality suppresses field movement")
    Assert.isFalse(game.runtime.applicationHost:isActive(), "sell modality suppresses the Start Menu")

    pressCancel(game)
    game:advanceUntil("the sell task returns to its caller", function()
      return not game.runtime.martHost:isActive()
        and game.runtime.scripts.worldState:getVar(CONTINUATION) == 7
        and game:snapshot().foregroundScript == nil
    end, 240)
    Assert.equal(game.runtime.bagService:quantity("POTION"), 2, "closing without a sale leaves the Bag unchanged")
    Assert.notNil(game.runtime:captureGameSave(), "save capture resumes after field return")
  end)
end

function T.tests.script_sell_child_commits_one_sale_before_returning_to_the_field()
  withGame(function(game)
    Assert.isTrue(game.runtime.bagService:add("POTION", 1), "sale setup uses the production Bag service")
    game:startScript(SELL_SCRIPT)
    game:advanceUntil("the script-owned sell child opens", function()
      return game.runtime.martHost:isActive()
    end, 480)
    game:advanceUntil("the Bag sale screen finishes opening", function()
      return hostStatus(game).phase == "interactive"
    end, 60)

    game:move("north")
    game:move("east")
    game:pressAction()
    game:move("south")
    local selection = hostStatus(game)
    local slots = {}
    for index, slot in ipairs(selection.slots) do
      slots[#slots + 1] = tostring(index - 1) .. ":" .. tostring(slot.item)
    end
    Assert.equal(
      selection.selected and selection.selected.item,
      "POTION",
      "Bag focus navigation selects the sale fixture; pocket="
        .. tostring(selection.pocket)
        .. "; focus=" .. tostring(selection.focus)
        .. "; absolute=" .. tostring(selection.focusedAbsoluteIndex)
        .. "; slots=" .. table.concat(slots, ",")
    )
    local startingMoney = game.runtime.playerData.profile.money
    game:pressAction()
    game:advanceUntil("the selected item enters its sale offer", function()
      return hostStatus(game).state == "sale_offer"
    end, 240)
    for _ = 1, 480 do
      local sale = hostStatus(game)
      if sale.state == "sale_result" then
        break
      end
      Assert.equal(sale.state, "sale_offer", "the sale offer consumes message and yes-confirm input")
      game:pressAction()
    end
    Assert.equal(hostStatus(game).state, "sale_result", "confirming the sale enters its result message")
    game:advanceUntil("the sale commits and reaches acknowledgement", function()
      return hostStatus(game).state == "sale_ack"
    end, 480)
    Assert.equal(game.runtime.bagService:quantity("POTION"), 0, "the confirmed sale removes one Potion")
    Assert.isTrue(game.runtime.playerData.profile.money > startingMoney, "the confirmed sale credits money")

    pressCancel(game)
    Assert.equal(hostStatus(game).state, "browsing", "acknowledging the sale returns to Bag browsing")
    pressCancel(game)
    game:advanceUntil("the sale child returns to its caller", function()
      return not game.runtime.martHost:isActive()
        and game.runtime.scripts.worldState:getVar(CONTINUATION) == 7
        and game:snapshot().foregroundScript == nil
    end, 240)

    Assert.equal(game.runtime.bagService:quantity("POTION"), 0, "field return does not restore the sold item")
    Assert.isTrue(game.runtime.playerData.profile.money > startingMoney, "field return does not replay the sale credit")
    Assert.notNil(game.runtime:captureGameSave(), "save capture resumes after the sale child returns")
  end)
end

return T
