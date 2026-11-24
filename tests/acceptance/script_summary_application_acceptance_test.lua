-- The scripted Summary application through the production field. The Day Care
-- lady's own standard script offers the source Store/Summary/Quit rows after a
-- party pick; the Summary row opens the native Summary from that script and the
-- companion result command reports the final party slot back to the source loop,
-- so the script's own picker reopens with the party untouched.
--
-- This is the real script consumer of the Summary application and its
-- same-tick result read. Only audio, fades and the wall clock are host
-- boundaries; the party picker, the Summary application and the lady's script
-- are production-owned, and the render trap stays active.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local SummaryCache = require("libs.assets.src.SummaryCache")

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = {
      "field-runtime",
      "map:331",
      "map-data:331",
      "message-bank:435",
      "message-bank:439",
    },
    tags = { "field", "script", "daycare", "summary" },
  },
  tests = {},
}

local DAYCARE_MAP = "MAP_ROUTE_34_DAYCARE"
-- The map's Day-Care Lady runs the standard day-care script under its public id.
local DAYCARE_SCRIPT = "common.daycare_lady"
-- The lady stands at (3,5) behind the counter row at z=6, so the player answers
-- her across it from the open floor tile directly south of the counter.
local COUNTER_TILE = { fieldX = 3, fieldZ = 7, facing = "north" }
-- msg_0439_00021 is the source consent question answered with its Yes row.
local MSG_CONSENT = 21
local MSG_WHICH_MON = 22
-- The source refusal for a party that could not spare a parent.
local MSG_LAST_USABLE = 39

local function pressAction(game)
  game.runtime:pressAction()
  game:step()
  game.runtime:releaseAction()
end

local function pressCancel(game)
  game.runtime:pressCancel()
  game:step()
  game.runtime:releaseCancel()
end

local function pressDirection(game, direction)
  game.runtime:press(direction)
  game:step()
  game.runtime:release(direction)
end

---@param game table
---@return table the live mon service
local function mons(game)
  return assert(game.runtime.monService, "the field runtime owns its mon service")
end

---@param printed integer[]
---@param messageId integer
---@return boolean
local function printedLine(printed, messageId)
  for _, value in ipairs(printed) do
    if value == messageId then
      return true
    end
  end
  return false
end

---@param game table
---@return string[] the lady script's published faults
local function scriptFaults(game)
  local list = {}
  for _, record in ipairs(game:recordsForScript(DAYCARE_SCRIPT, "script.error")) do
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
---@return table? the live party selection status
local function pickerStatus(game)
  local host = game.runtime.partySelection
  if host == nil or not host:isActive() then
    return nil
  end
  return host:status()
end

---@param game table
---@param label string
---@return table the interactive picker status
local function waitPickerInteractive(game, label)
  for _ = 1, 160 do
    local status = pickerStatus(game)
    if
      status ~= nil
      and status.preparationState == "ready"
      and status.phase ~= "opening"
      and status.cursorNode ~= nil
    then
      return status
    end
    game:step()
  end
  error("the party selection never became interactive before " .. label, 0)
end

---@param cursor integer
---@param slot integer
---@return string
local function directionTo(cursor, slot)
  local cursorRow, cursorColumn = math.floor(cursor / 2), cursor % 2
  local slotRow, slotColumn = math.floor(slot / 2), slot % 2
  if slotRow ~= cursorRow then
    return slotRow > cursorRow and "down" or "up"
  end
  return slotColumn > cursorColumn and "right" or "left"
end

---@param game table
---@param slot integer
local function focusSlot(game, slot)
  for _ = 1, 16 do
    local status = waitPickerInteractive(game, "party slot " .. tostring(slot))
    if status.cursorNode == slot then
      return
    end
    local cursor = status.cursorNode
    local direction = type(cursor) == "number" and directionTo(cursor, slot) or "up"
    pressDirection(game, direction)
  end
  error("the party selection never focused slot " .. tostring(slot), 0)
end

---@param game table
---@return table the open source-ordered care menu
local function openCareMenu(game)
  for _ = 1, 8 do
    waitPickerInteractive(game, "the care menu")
    pressAction(game)
    for _ = 1, 40 do
      local status = assert(pickerStatus(game), "the party selection stays open while its care menu opens")
      if status.menu ~= nil then
        return status.menu
      end
      game:step()
    end
  end
  error("the party selection never opened a care menu", 0)
end

-- Chooses the source row whose semantic kind the scenario names, walking the
-- generated row order instead of pinning a position.
---@param game table
---@param kind string
local function chooseMenuRow(game, kind)
  local status = assert(pickerStatus(game), "the care menu belongs to the open party selection")
  local target = nil
  for index, entry in ipairs(assert(status.menu, "the care menu lists its source rows")) do
    if entry.kind == kind then
      target = index
    end
  end
  Assert.notNil(target, "the care menu offers the " .. kind .. " row")
  for _ = 1, 24 do
    status = assert(pickerStatus(game), "the party selection stays open while choosing a care row")
    Assert.notNil(status.menu, "choosing a care row keeps its menu open")
    if status.menuIndex == target then
      break
    end
    pressDirection(game, (status.menuIndex or 1) < target and "down" or "up")
  end
  pressAction(game)
  -- The source row press rides its visual cadence before the single dispatch.
  for _ = 1, 40 do
    local current = pickerStatus(game)
    if current == nil or current.menu == nil or current.menuIndex ~= target or current.menuPress == nil then
      return
    end
    game:step()
  end
end

---@param game table
---@param row integer zero-based source row
local function answerQuestion(game, row)
  for _ = 1, 200 do
    local choice = game:contextChoiceStatus()
    if choice == nil or choice.state ~= "active" then
      return
    end
    if choice.selected == row then
      pressAction(game)
      for _ = 1, 60 do
        local current = game:contextChoiceStatus()
        if current == nil or current.state ~= "active" then
          return
        end
        game:step()
      end
      return
    end
    pressDirection(game, (choice.selected or 0) < row and "down" or "up")
  end
  error("the source question never accepted row " .. tostring(row), 0)
end

---@param game table
---@return string[] every published script fault, whatever script owns it
local function allScriptFaults(game)
  local list = {}
  for _, record in ipairs(game:recordsNamed("script.error")) do
    local payload = record.payload or {}
    local context = payload.context or {}
    list[#list + 1] = string.format(
      "%s/%s/%s/%s",
      tostring(payload.scriptId),
      tostring(payload.code),
      tostring(context.command or context.originalName or "unknown"),
      tostring(payload.message)
    )
  end
  return list
end

-- The source Summary opens from the script and keeps the field: the script's
-- picker stays closed while the player browses, and closing the Summary hands its
-- once-only result back so the script's own loop reopens its picker.
---@param game table
local function closeSummaryUntilTheSourceLoopReturns(game)
  for _ = 1, 40 do
    local faults = scriptFaults(game)
    Assert.equal(
      #faults,
      0,
      "the scripted Summary application completes every native operation: " .. table.concat(faults, ",")
    )
    Assert.isNil(pickerStatus(game), "the script waits for its Summary application instead of its picker")
    game:step()
  end
  Assert.isTrue(game:snapshot().fieldLocked, "the source Summary keeps the field while it is open")
  for _ = 1, 600 do
    if pickerStatus(game) ~= nil then
      return
    end
    pressCancel(game)
  end
  error(
    "the source Summary never returned to the script loop; faults=" .. table.concat(scriptFaults(game), ","),
    0
  )
end

-- The presented field installs the one care presentation lease; the acceptance
-- composition stops before rendering, so the lease reports the validated
-- Summary family and no drawable bundle while the application runs its states.
---@param game table
local function bindCarePresentation(game)
  local manifest = SummaryCache.loadManifest(assert(game.runtime.cacheFs, "the field runtime owns its cache"))
  game.runtime:bindPokemonCarePresentation(function()
    local lease = {}
    function lease:prepare()
      return { kind = "ready", key = "care", assets = { manifest = manifest } }
    end
    function lease:presentation()
      return nil
    end
    function lease:release() end
    return lease
  end)
end

function T.tests.the_script_summary_returns_control_to_the_source_party_loop()
  local harness = AcceptanceHarness.new()
  local createGame = harness.gameFactory
  harness.gameFactory = function(versionId, map)
    local game = createGame(versionId, map)
    game.location = {
      mapSymbol = DAYCARE_MAP,
      fieldX = COUNTER_TILE.fieldX,
      fieldZ = COUNTER_TILE.fieldZ,
      facing = COUNTER_TILE.facing,
    }
    game.playerData.profile.money = 3000
    return game
  end
  local game = harness:boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = DAYCARE_MAP,
    save = "fresh",
    fieldOptions = { recordingScriptHosts = true, audioHost = "recording" },
  })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    Assert.isNil(
      game.runtime.session.mapEntryStage,
      "the day care map finishes its entry scripts: " .. table.concat(allScriptFaults(game), ",")
    )
    game.runtime:bindPartyIconPreparation(function()
      return true
    end, function() end)
    bindCarePresentation(game)
    -- Three party mons keep the source's last-usable refusal out of the path.
    for _, request in ipairs({
      { species = "RATTATA", level = 5 },
      { species = "PIDGEY", level = 5 },
      { species = "SNORLAX", level = 5 },
    }) do
      Assert.isTrue(mons(game):giveMon(request), "the scenario needs a full enough party to spare a parent")
    end

    local ended = #game:recordsForScript(DAYCARE_SCRIPT, "script.ended")
    game:pressAction()
    Assert.equal(game:interaction().scriptId, DAYCARE_SCRIPT, "the lady owns the interaction the scenario answers")

    -- The source consent question, then its own party pick.
    local printed, last = {}, nil
    for _ = 1, 1200 do
      local faults = scriptFaults(game)
      Assert.equal(#faults, 0, "the lady script completes every native operation: " .. table.concat(faults, ","))
      local snapshot = game:snapshot()
      if snapshot.dialogue.modal then
        local messageId = snapshot.dialogue.messageId
        if messageId ~= nil and messageId ~= last then
          printed[#printed + 1] = messageId
          last = messageId
        end
      else
        last = nil
      end
      local choice = game:contextChoiceStatus()
      if pickerStatus(game) ~= nil then
        break
      elseif choice ~= nil and choice.state == "active" then
        answerQuestion(game, 0)
      elseif snapshot.dialogue.modal then
        pressAction(game)
      else
        game:step()
      end
    end
    Assert.isTrue(printedLine(printed, MSG_CONSENT), "the lady asks the source consent question")
    Assert.isTrue(printedLine(printed, MSG_WHICH_MON), "the lady asks which Pokémon she should keep")
    Assert.isFalse(printedLine(printed, MSG_LAST_USABLE), "a party of three can spare a parent")

    focusSlot(game, 0)
    openCareMenu(game)
    chooseMenuRow(game, "summary")

    -- The Summary row reports the source Summary action, and the script waits for
    -- the native application before it asks for the same-tick result.
    closeSummaryUntilTheSourceLoopReturns(game)
    Assert.isTrue(pickerStatus(game) ~= nil, "the source loop asks for a Pokémon again after the Summary")
    Assert.equal(#scriptFaults(game), 0, "the scripted Summary returned without a native fault")

    -- Cancelling the source picker ends the scene; the party never gave up a mon.
    for _ = 1, 8 do
      if #game:recordsForScript(DAYCARE_SCRIPT, "script.ended") > ended then
        break
      end
      pressCancel(game)
      for _ = 1, 20 do
        if #game:recordsForScript(DAYCARE_SCRIPT, "script.ended") > ended then
          break
        end
        game:step()
      end
    end
    Assert.isTrue(
      #game:recordsForScript(DAYCARE_SCRIPT, "script.ended") > ended,
      "cancelling the party selection ends the day-care scene"
    )
    Assert.equal(#scriptFaults(game), 0, "the whole scene runs without a script fault")
    Assert.equal(mons(game):partyCount(), 3, "browsing the Summary puts no parent in the Day Care")
    Assert.equal(game:renderAttempts(), 0, "the scenario stops before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

return T
