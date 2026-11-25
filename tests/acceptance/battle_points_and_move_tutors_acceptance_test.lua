-- The Battle Frontier move tutors and the Battle Point wallet they spend,
-- through the production field. The tutor house owns the native scripts: each
-- of its three tutors runs the standard-segment tutor body, which opens the
-- transient points window, asks for a party mon, pages the tutor's own move
-- list with its Next and Cancel rows, checks and takes the Battle Point price,
-- and teaches the selected move. Ilex Forest's charcoal maker runs the
-- Headbutt lesson from the same compatibility table.
--
-- The scenarios answer the source questions, hand the party picker its slot,
-- click the generated list rows, and read back the canonical party, the saved
-- Battle Point owner and the transient window's captured balance. Only audio,
-- screen fades and the wall clock are host boundaries; the scripts, the party
-- picker, the list menu and the points window are production-owned, and the
-- render trap stays active.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = {
      "field-runtime",
      -- MAP_FRONTIER_ACCESS_MOVE_TUTOR_HOUSE (map 531) owns the three tutors.
      "map:531",
      "map-data:531",
      "message-bank:105",
      -- The tutor body's own bank and the transient window's row bank.
      "message-bank:748",
      "message-bank:191",
      -- MAP_ILEX_FOREST (map 117) owns the Headbutt lesson.
      "map:117",
      "map-data:117",
      "message-bank:115",
    },
    tags = { "field", "script", "mons", "moves", "tutor", "battle-points" },
  },
  tests = {},
}

local TUTOR_MAP = "MAP_FRONTIER_ACCESS_MOVE_TUTOR_HOUSE"
-- The house's generated object scripts (scr_seq_0082_D32R0103.s). Each one
-- calls the same standard tutor segment with its own tutor selector.
local TOP_LEFT_TUTOR = "vanilla.hgss.scr_seq.0082.script_000"
local TOP_RIGHT_TUTOR = "vanilla.hgss.scr_seq.0082.script_001"

-- The middlemen stand at (5,5) and (8,5); the player answers each across the
-- counter row from an open floor tile the middleman faces. The counter blocks
-- (6,5), so the top-left middleman is answered from (4,5) looking east.
local TOP_LEFT_TILE = { fieldX = 4, fieldZ = 5, facing = "east" }
local TOP_RIGHT_TILE = { fieldX = 7, fieldZ = 5, facing = "east" }

local HEADBUTT_MAP = "MAP_ILEX_FOREST"
-- The charcoal maker's generated object script (scr_seq_0092_D36R0101.s).
local HEADBUTT_TUTOR = "vanilla.hgss.scr_seq.0092.script_002"
-- He stands at (36,37) facing north on the forest path. Ilex Forest spans
-- several sections and its field z origin is 32, so the boot location that
-- lands the player on (36,38) is the map-relative (36,6).
local HEADBUTT_TILE = { fieldX = 36, fieldZ = 6, facing = "north" }

-- The saved Battle Point owner the scenarios seed and read back.
local BATTLE_POINTS_SCHEMA = "hgss-battle-points-v1"

-- msg_0748 is the tutor body's bank and repeats one twelve-row block per tutor
-- (top-left from row 4, top-right from row 16, bottom-right from row 28).
local TOP_LEFT_MSG = {
  consent = 4,
  noMove = 5,
  giveUp = 7,
  bye = 15,
}
local TOP_RIGHT_MSG = {
  consent = 16,
  noMove = 17,
  noPoints = 18,
  giveUp = 19,
  fourMoves = 20,
  giveUpMove = 22,
  gaveUp = 23,
  bye = 27,
  learned = 26,
}

-- msg_0115_D36R0101 is Ilex Forest's bank; the charcoal maker's Headbutt
-- lesson uses these rows.
local HEADBUTT_MSG = {
  question = 11,
  whichMon = 14,
  cannotLearn = 16,
  poof = 21,
  stronger = 22,
  alreadyLearned = 23,
  learned = 26,
}

-- The moves the scenarios select. src/field/scrcmd_move_tutor.c::sTutorMoves
-- prices them 32 and 48 Battle Points and assigns both to the top-right tutor.
local MUD_SLAP = "MUD_SLAP"
local SUPERPOWER = "SUPERPOWER"
local MUD_SLAP_PRICE = 32
local SUPERPOWER_PRICE = 48

-- The source list rows: up to six moves, then the Next row while a further
-- page exists, then the Cancel row.
---@param moves integer
---@param hasNext boolean
---@return integer rows
local function listRows(moves, hasNext)
  return moves + 1 + (hasNext and 1 or 0)
end

---@param moves integer
---@return integer zero-based Next row
local function nextRow(moves)
  return moves
end

---@param moves integer
---@param hasNext boolean
---@return integer zero-based Cancel row
local function cancelRow(moves, hasNext)
  return moves + (hasNext and 1 or 0)
end

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

---@param game table
---@return table the catalog behind the live service
local function catalog(game)
  return assert(mons(game):catalog(), "the mon service owns the validated catalog")
end

---@param game table
---@return table the transient points window
local function pointsBox(game)
  local box = game.runtime.pointsBox
  Assert.notNil(box, "the field runtime owns its transient points window")
  return box
end

---@param snapshot table
---@return boolean whether a generated list menu owns the field
local function menuOpen(snapshot)
  return snapshot.menu ~= nil and snapshot.menu.modal == true
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

-- The picker grid is the generated two-column party layout, so navigation walks
-- rows first and then columns to the requested slot.
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

---@param game table
---@param slot integer
---@param label string
local function chooseSlot(game, slot, label)
  for _ = 1, 16 do
    local status = waitPickerInteractive(game, label)
    if status.cursorNode == slot then
      break
    end
    local cursor = status.cursorNode
    local direction = type(cursor) == "number" and directionTo(cursor, slot) or "up"
    pressDirection(game, direction)
  end
  for _ = 1, 8 do
    if pickerStatus(game) == nil then
      return
    end
    pressAction(game)
    for _ = 1, 40 do
      if pickerStatus(game) == nil then
        return
      end
      game:step()
    end
  end
  error("the party selection never accepted slot " .. tostring(slot) .. " before " .. label, 0)
end

---@param game table
---@param label string
local function cancelPicker(game, label)
  for _ = 1, 8 do
    if pickerStatus(game) == nil then
      return
    end
    pressCancel(game)
    for _ = 1, 12 do
      if pickerStatus(game) == nil then
        return
      end
      game:step()
    end
  end
  error("the party selection never cancelled before " .. label, 0)
end

-- Answers the script's own yes/no question with one source row. The provider
-- keeps the cursor the last answer left, so the row is read instead of assumed.
---@param game table
---@param row integer zero-based source row
---@param label string
local function answerQuestion(game, row, label)
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
  error("the source question never accepted row " .. tostring(row) .. " before " .. label, 0)
end

-- Clicks one generated list row and waits until the clicked list is no longer
-- the active one, so the next iteration observes the following source state
-- instead of pressing the same row twice.
---@param game table
---@param row integer zero-based row
---@param expectedRows integer the source row count of the clicked page
---@param label string
local function clickListRow(game, row, expectedRows, label)
  local snapshot = game:snapshot()
  local menu = assert(snapshot.menu, "the tutor list owns the field menu before " .. label)
  local layout = assert(menu.layout, "the tutor list exposes its production layout before " .. label)
  Assert.equal(
    layout.itemCount,
    expectedRows,
    "the tutor list offers its source rows before " .. label
  )
  Assert.isTrue(
    row < layout.itemCount,
    "the tutor list offers row " .. tostring(row) .. " before " .. label
  )
  local rect = assert(menu.itemRects[row], "the tutor list exposes row geometry before " .. label)
  local x, y = rect.x + rect.width / 2, rect.y + rect.height / 2
  game.runtime.input:pointerDown("mouse:1", x, y)
  game:step()
  game.runtime.input:pointerUp("mouse:1", x, y)
  for _ = 1, 240 do
    local current = game:snapshot().menu
    if current == nil or current.layout ~= layout or current.modal ~= true then
      return
    end
    game:step()
  end
  error("the tutor list kept the clicked row active before " .. label, 0)
end

---@class TutorAction
---@field kind "question"|"pick"|"cancel_pick"|"row"
---@field row integer?
---@field rows integer?
---@field value integer?
---@field slot integer?

-- Drives one foreground tutor script the way a player does: dismiss printed
-- messages, answer its questions, hand the party picker its slot, click the
-- generated list rows, and stop when the script ends. Any published fault of
-- the running script fails the scenario at the tick it appears.
---@param game table
---@param scriptId string
---@param actions TutorAction[]
---@param label string
---@param onMessage fun(game: table, messageId: integer)?
---@return integer[] printed message ids
local function runScript(game, scriptId, actions, label, onMessage)
  local queue = actions or {}
  local nextAction = 1
  local printed, last = {}, nil
  local ended = #game:recordsForScript(scriptId, "script.ended")
  for _ = 1, 4000 do
    local faults = scriptFaults(game, scriptId)
    Assert.equal(
      #faults,
      0,
      "the source script completes every native operation before " .. label .. ": " .. table.concat(faults, ",")
    )
    local snapshot = game:snapshot()
    if snapshot.dialogue.modal then
      local messageId = snapshot.dialogue.messageId
      if messageId ~= nil and messageId ~= last then
        printed[#printed + 1] = messageId
        if onMessage ~= nil then
          onMessage(game, messageId)
        end
        last = messageId
      end
    else
      last = nil
    end
    if
      #game:recordsForScript(scriptId, "script.ended") > ended
      and not snapshot.dialogue.modal
      and not snapshot.fieldLocked
      and game:contextChoiceStatus() == nil
      and pickerStatus(game) == nil
      and not menuOpen(snapshot)
    then
      return printed
    end
    local action = queue[nextAction]
    local choice = game:contextChoiceStatus()
    if menuOpen(snapshot) then
      Assert.notNil(action, "the tutor list asks for an unplanned row before " .. label)
      Assert.equal(action.kind, "row", "the tutor list is answered by its planned row before " .. label)
      nextAction = nextAction + 1
      clickListRow(
        game,
        assert(action.row, "a planned row names its index"),
        assert(action.rows, "a planned row names its page size"),
        label
      )
    elseif pickerStatus(game) ~= nil then
      Assert.notNil(action, "the script asks for an unplanned party selection before " .. label)
      Assert.isTrue(
        action.kind == "pick" or action.kind == "cancel_pick",
        "the party selection is answered by a pick or a cancel before " .. label
      )
      nextAction = nextAction + 1
      if action.kind == "cancel_pick" then
        cancelPicker(game, label)
      else
        chooseSlot(game, assert(action.slot, "a planned pick names its slot"), label)
      end
    elseif choice ~= nil and choice.state == "active" then
      Assert.notNil(action, "the script asks an unplanned question before " .. label)
      Assert.equal(action.kind, "question", "the script question is answered by its planned row before " .. label)
      nextAction = nextAction + 1
      answerQuestion(game, assert(action.row, "a planned answer names its row"), label)
    elseif snapshot.dialogue.modal then
      pressAction(game)
    else
      game:step()
    end
  end
  error(
    "the source script never reached "
      .. label
      .. "; selection="
      .. tostring(pickerStatus(game) ~= nil)
      .. ", menu="
      .. tostring(menuOpen(game:snapshot()))
      .. ", modal="
      .. tostring(game:snapshot().dialogue.modal)
      .. ", message="
      .. tostring(game:snapshot().dialogue.messageId)
      .. ", faults="
      .. table.concat(scriptFaults(game, scriptId), ","),
    0
  )
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

---@param game table
---@param label string
---@return table the saved Battle Point owner
local function savedBattlePoints(game, label)
  local capture = settledCapture(game, label)
  local bucket = assert(capture.battlePoints, "the saved game carries the Battle Point owner: " .. label)
  Assert.equal(bucket.schema, BATTLE_POINTS_SCHEMA, "the saved Battle Point owner carries its schema: " .. label)
  return bucket
end

---@param game table
---@param slot0 integer
---@param moves string[]
local function setMoves(game, slot0, moves)
  local service = mons(game)
  while service:countMonMoves(slot0) > 0 do
    service:deleteMove(slot0, 0)
  end
  for index, move in ipairs(moves) do
    service:setMove(slot0, index - 1, move)
  end
end

---@param game table
---@param slot0 integer
---@param move string
---@return integer the taught row
local function taughtRow(game, slot0, move)
  for index, entry in ipairs(mons(game):partyMon(slot0).moves) do
    if entry.move == move then
      return index
    end
  end
  error("the party slot never learned " .. move, 0)
end

---@class TutorFieldOptions
---@field battlePoints integer? the saved balance the boot candidate starts with
---@field setup fun(game: table)?

---@param map string
---@param tile { fieldX: integer, fieldZ: integer, facing: string }
---@param options TutorFieldOptions
---@param body fun(game: table)
local function withField(map, tile, options, body)
  local harness = AcceptanceHarness.new()
  local createGame = harness.gameFactory
  harness.gameFactory = function(versionId, requestedMap)
    local game = createGame(versionId, requestedMap)
    game.location = { mapSymbol = map, fieldX = tile.fieldX, fieldZ = tile.fieldZ, facing = tile.facing }
    if options.battlePoints ~= nil then
      game.battlePoints = { schema = BATTLE_POINTS_SCHEMA, balance = options.battlePoints }
    end
    return game
  end
  local game = harness:boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = map,
    save = "fresh",
    fieldOptions = { recordingScriptHosts = true, audioHost = "recording" },
  })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    Assert.isNil(
      game.runtime.session.mapEntryStage,
      "the map finishes its entry scripts: " .. table.concat(allScriptFaults(game), ",")
    )
    -- Headless composition binds the explicit no-image preparation: the party
    -- picker reports ready without realizing GPU icons it never draws.
    game.runtime:bindPartyIconPreparation(function()
      return true
    end, function() end)
    if options.setup ~= nil then
      options.setup(game)
    end
    body(game)
    Assert.equal(game:renderAttempts(), 0, "the scenarios stop before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

---@param game table
---@param scriptId string
---@param message string
local function talk(game, scriptId, message)
  game:pressAction()
  Assert.equal(game:interaction().scriptId, scriptId, message)
end

-- Mew learns twenty-one of the inventory's moves from the top-right tutor and
-- fourteen from the top-left one, so the same party member answers a different
-- page count at each counter. The source pages by six and keeps a Next row on
-- every page it opens, Cancel last.
function T.tests.the_tutor_pages_its_own_list_per_tutor_npc()
  withField(TUTOR_MAP, TOP_RIGHT_TILE, {
    battlePoints = 200,
    setup = function(game)
      Assert.isTrue(mons(game):giveMon({ species = "MEW", level = 30 }), "the paging scenario needs one party mon")
      setMoves(game, 0, { "TACKLE", "GROWL", "SCRATCH" })
    end,
  }, function(game)
    talk(game, TOP_RIGHT_TUTOR, "the top-right middleman owns the interaction the scenario answers")
    local printed = runScript(game, TOP_RIGHT_TUTOR, {
      { kind = "question", row = 0 },
      { kind = "pick", slot = 0 },
      -- Pages 0..2 carry six moves each; page 3 carries the remaining three.
      { kind = "row", row = nextRow(6), rows = listRows(6, true) },
      { kind = "row", row = nextRow(6), rows = listRows(6, true) },
      { kind = "row", row = nextRow(6), rows = listRows(6, true) },
      { kind = "row", row = nextRow(3), rows = listRows(3, true) },
      -- The Next row on the last page wraps back to the first one.
      { kind = "row", row = cancelRow(6, true), rows = listRows(6, true) },
      { kind = "question", row = 0 },
    }, "the top-right list wrapped")
    Assert.isTrue(printedLine(printed, TOP_RIGHT_MSG.consent), "the tutor asks its source consent question")
    Assert.isTrue(printedLine(printed, TOP_RIGHT_MSG.giveUp), "the Cancel row asks the source give-up question")
    Assert.isTrue(printedLine(printed, TOP_RIGHT_MSG.bye), "the cancelled lesson leaves through the source goodbye")
    Assert.isFalse(printedLine(printed, TOP_RIGHT_MSG.noMove), "a Mew has moves this tutor can teach")
    Assert.equal(mons(game):countMonMoves(0), 3, "the cancelled lesson teaches nothing")
    Assert.equal(savedBattlePoints(game, "the cancelled lesson").balance, 200, "the cancelled lesson spends no point")

    -- The same party member at the top-left counter: fourteen moves, three pages.
    game:moveTo({ fieldX = TOP_LEFT_TILE.fieldX, fieldZ = TOP_LEFT_TILE.fieldZ })
    game:face(TOP_LEFT_TILE.facing)
    talk(game, TOP_LEFT_TUTOR, "the top-left middleman answers on its own turn")
    local left = runScript(game, TOP_LEFT_TUTOR, {
      { kind = "question", row = 0 },
      { kind = "pick", slot = 0 },
      { kind = "row", row = nextRow(6), rows = listRows(6, true) },
      { kind = "row", row = nextRow(6), rows = listRows(6, true) },
      { kind = "row", row = cancelRow(2, true), rows = listRows(2, true) },
      { kind = "question", row = 0 },
    }, "the top-left list finished")
    Assert.isTrue(printedLine(left, TOP_LEFT_MSG.consent), "the other tutor asks its own consent question")
    Assert.isTrue(printedLine(left, TOP_LEFT_MSG.giveUp), "the top-left list offers its own Cancel row")
    Assert.isFalse(printedLine(left, TOP_LEFT_MSG.noMove), "a Mew has moves this tutor can teach too")
    Assert.equal(savedBattlePoints(game, "both cancelled lessons").balance, 200, "no cancelled lesson spends a point")
  end)
end

-- The list drops the moves the party member already knows, which changes the
-- page count: eight eligible moves fill two pages, seven fit on one.
function T.tests.known_moves_leave_the_tutor_list_page_count()
  withField(TUTOR_MAP, TOP_RIGHT_TILE, {
    battlePoints = 200,
    setup = function(game)
      Assert.isTrue(
        mons(game):giveMon({ species = "TYRANITAR", level = 55 }),
        "the known-move scenario needs one party mon"
      )
      setMoves(game, 0, { "TACKLE", "GROWL", "SCRATCH", "BITE" })
    end,
  }, function(game)
    talk(game, TOP_RIGHT_TUTOR, "the eight-move list")
    runScript(game, TOP_RIGHT_TUTOR, {
      { kind = "question", row = 0 },
      { kind = "pick", slot = 0 },
      { kind = "row", row = nextRow(6), rows = listRows(6, true) },
      -- The second page holds only the two remaining moves.
      { kind = "row", row = cancelRow(2, true), rows = listRows(2, true) },
      { kind = "question", row = 0 },
    }, "the eight-move list finished")

    -- One eligible move becomes known, so the list fits a single page: the
    -- seventh row is a move now, not the Next row.
    setMoves(game, 0, { "TACKLE", "GROWL", "SCRATCH", MUD_SLAP })
    talk(game, TOP_RIGHT_TUTOR, "the seven-move list")
    local printed = runScript(game, TOP_RIGHT_TUTOR, {
      { kind = "question", row = 0 },
      { kind = "pick", slot = 0 },
      { kind = "row", row = 6, rows = listRows(7, false) },
      { kind = "question", row = 1 },
      { kind = "question", row = 0 },
    }, "the seven-move list finished")
    Assert.isTrue(
      printedLine(printed, TOP_RIGHT_MSG.fourMoves),
      "the seventh row is the source move, not a further page"
    )
    Assert.isTrue(printedLine(printed, TOP_RIGHT_MSG.giveUpMove), "refusing the lesson asks its own question")
    Assert.equal(mons(game):countMonMoves(0), 4, "the refused lesson keeps the moveset")
    Assert.equal(savedBattlePoints(game, "the refused lesson").balance, 200, "the refused lesson spends no point")

    -- A party member this tutor cannot teach at all answers an empty list: no
    -- page opens and the source says so before the picker returns.
    Assert.isTrue(mons(game):giveMon({ species = "CATERPIE", level = 5 }), "the empty list needs one mon")
    talk(game, TOP_RIGHT_TUTOR, "the empty list")
    local empty = runScript(game, TOP_RIGHT_TUTOR, {
      { kind = "question", row = 0 },
      { kind = "pick", slot = 1 },
      { kind = "cancel_pick" },
    }, "the empty list finished")
    Assert.isTrue(printedLine(empty, TOP_RIGHT_MSG.noMove), "an empty list reports the source refusal")
    Assert.isTrue(printedLine(empty, TOP_RIGHT_MSG.bye), "the empty list leaves through the goodbye")

    -- The compatibility rows are indexed by species and form: the same
    -- species answers eight moves in its altered form and seven in its origin
    -- form, which is the difference between two pages and one.
    for _, request in ipairs({
      { species = "GIRATINA", level = 55, form = 0 },
      { species = "GIRATINA", level = 55, form = 1 },
    }) do
      Assert.isTrue(mons(game):giveMon(request), "the form rows need both forms of the same species")
      setMoves(game, mons(game):partyCount() - 1, { "TACKLE", "GROWL", "SCRATCH", "BITE" })
    end
    talk(game, TOP_RIGHT_TUTOR, "the altered form")
    runScript(game, TOP_RIGHT_TUTOR, {
      { kind = "question", row = 0 },
      { kind = "pick", slot = 2 },
      { kind = "row", row = nextRow(6), rows = listRows(6, true) },
      { kind = "row", row = cancelRow(2, true), rows = listRows(2, true) },
      { kind = "question", row = 0 },
    }, "the altered form finished")

    talk(game, TOP_RIGHT_TUTOR, "the origin form")
    local origin = runScript(game, TOP_RIGHT_TUTOR, {
      { kind = "question", row = 0 },
      { kind = "pick", slot = 3 },
      { kind = "row", row = 6, rows = listRows(7, false) },
      { kind = "question", row = 1 },
      { kind = "question", row = 0 },
    }, "the origin form finished")
    Assert.isTrue(
      printedLine(origin, TOP_RIGHT_MSG.fourMoves),
      "the origin form's seventh row is a move, so its list needs no second page"
    )
  end)
end

-- The source script owns the price: it checks the balance, takes the exact
-- price once, and the teaching command writes the move at its base power
-- points with no power-point up.
function T.tests.the_tutor_charges_each_source_price_once()
  withField(TUTOR_MAP, TOP_RIGHT_TILE, {
    -- Exactly the two prices, so the second lesson is affordable at the
    -- boundary the source compare allows.
    battlePoints = MUD_SLAP_PRICE + SUPERPOWER_PRICE,
    setup = function(game)
      for slot = 0, 1 do
        Assert.isTrue(
          mons(game):giveMon({ species = "MEW", level = 30 }),
          "the pricing scenario needs two party mons"
        )
        setMoves(game, slot, { "TACKLE", "GROWL", "SCRATCH" })
      end
    end,
  }, function(game)
    local movesBefore = mons(game):countMonMoves(0)
    talk(game, TOP_RIGHT_TUTOR, "the first lesson")
    local first = runScript(game, TOP_RIGHT_TUTOR, {
      { kind = "question", row = 0 },
      { kind = "pick", slot = 0 },
      { kind = "row", row = 0, rows = listRows(6, true) },
    }, "the first lesson finished")
    Assert.isTrue(printedLine(first, TOP_RIGHT_MSG.learned), "the source announces the learned move")
    Assert.isFalse(printedLine(first, TOP_RIGHT_MSG.noPoints), "the first price is affordable")
    local row = taughtRow(game, 0, MUD_SLAP)
    Assert.equal(row, movesBefore + 1, "the taught move appends after the known moves")
    local definition = catalog(game):move(MUD_SLAP)
    Assert.equal(mons(game):partyMon(0).moves[row].pp, definition.basePp, "the taught move starts at its base PP")
    Assert.equal(mons(game):partyMon(0).moves[row].ppUps, 0, "the taught move carries no PP Up")
    local afterFirst = savedBattlePoints(game, "the first lesson")
    Assert.equal(afterFirst.balance, SUPERPOWER_PRICE, "the source takes exactly one price")

    talk(game, TOP_RIGHT_TUTOR, "the second lesson")
    local second = runScript(game, TOP_RIGHT_TUTOR, {
      { kind = "question", row = 0 },
      { kind = "pick", slot = 1 },
      { kind = "row", row = 2, rows = listRows(6, true) },
    }, "the second lesson finished")
    Assert.isTrue(printedLine(second, TOP_RIGHT_MSG.learned), "the second lesson is announced")
    Assert.isFalse(printedLine(second, TOP_RIGHT_MSG.noPoints), "the exact remaining balance covers the price")
    local secondRow = taughtRow(game, 1, SUPERPOWER)
    Assert.equal(
      mons(game):partyMon(1).moves[secondRow].pp,
      catalog(game):move(SUPERPOWER).basePp,
      "the second taught move starts at its base PP"
    )
    local settled = settledCapture(game, "both lessons")
    Assert.equal(settled.battlePoints.balance, 0, "the charged prices leave the exact remaining balance")
    Assert.equal(
      settled.gameStats.battlePointsSpent,
      MUD_SLAP_PRICE + SUPERPOWER_PRICE,
      "the spent statistics count both requested prices once"
    )
    Assert.equal(settled.gameStats.battlePointsReceived, 0, "no lesson awards a point")
  end)
end

-- A balance below the selected move's price refuses the lesson before the
-- teaching command runs, and the price is the source's own table value.
function T.tests.the_tutor_refuses_a_move_the_balance_cannot_cover()
  withField(TUTOR_MAP, TOP_RIGHT_TILE, {
    battlePoints = SUPERPOWER_PRICE - 1,
    setup = function(game)
      Assert.isTrue(mons(game):giveMon({ species = "MEW", level = 30 }), "the refusal scenario needs one party mon")
      setMoves(game, 0, { "TACKLE", "GROWL", "SCRATCH" })
    end,
  }, function(game)
    talk(game, TOP_RIGHT_TUTOR, "the unaffordable lesson")
    local printed = runScript(game, TOP_RIGHT_TUTOR, {
      { kind = "question", row = 0 },
      { kind = "pick", slot = 0 },
      { kind = "row", row = 2, rows = listRows(6, true) },
    }, "the unaffordable lesson finished")
    Assert.isTrue(printedLine(printed, TOP_RIGHT_MSG.noPoints), "the source reports the missing points")
    Assert.isFalse(printedLine(printed, TOP_RIGHT_MSG.learned), "the refused lesson never announces a move")
    Assert.equal(mons(game):countMonMoves(0), 3, "the refused lesson teaches nothing")
    local settled = settledCapture(game, "the unaffordable lesson")
    Assert.equal(
      settled.battlePoints.balance,
      SUPERPOWER_PRICE - 1,
      "an unaffordable lesson leaves the balance untouched"
    )
    Assert.equal(settled.gameStats.battlePointsSpent, 0, "an unaffordable lesson spends no point")
  end)
end

-- The transient window paints the saved balance as the source's five-digit
-- right-aligned field, hides while the party picker owns the screen, repaints
-- only at the source update after the charge, and its balance survives
-- Continue.
function T.tests.the_points_window_paints_the_saved_balance_at_its_source_update()
  withField(TUTOR_MAP, TOP_RIGHT_TILE, {
    battlePoints = 200,
    setup = function(game)
      Assert.isTrue(mons(game):giveMon({ species = "MEW", level = 30 }), "the window scenario needs one party mon")
      setMoves(game, 0, { "TACKLE", "GROWL", "SCRATCH" })
    end,
  }, function(game)
    local box = pointsBox(game)
    Assert.equal(box.WIDTH, 80, "the source frame is ten eight-pixel tiles wide")
    Assert.equal(box.HEIGHT, 16, "the source frame is two eight-pixel tiles high")

    talk(game, TOP_RIGHT_TUTOR, "the window scenario")
    -- The consent prompt is a two-page message box (msg_0748_00016 carries the
    -- source's own page break), so the scenario pages through it the way a
    -- player does before the source choice opens.
    for _ = 1, 240 do
      local choice = game:contextChoiceStatus()
      if choice ~= nil and choice.state == "active" then
        break
      end
      game:step()
      local pending = game:contextChoiceStatus()
      local dialogue = game:snapshot().dialogue
      if (pending == nil or pending.state ~= "active") and dialogue.modal and dialogue.waiting then
        pressAction(game)
      end
    end
    local opened = box:snapshot()
    Assert.isTrue(opened.visible, "the tutor opens its transient window before asking")
    Assert.equal(opened.tileX, 21, "the source script places the window at its own byte column")
    Assert.equal(opened.tileY, 1, "the source script places the window at its own byte row")
    Assert.equal(opened.displayedValue, 200, "the window shows the saved balance when it opens")
    Assert.equal(opened.valueText, "  200", "the balance fills the source's five-digit right-aligned field")

    answerQuestion(game, 0, "the consent question")
    for _ = 1, 240 do
      if pickerStatus(game) ~= nil then
        break
      end
      game:step()
    end
    Assert.notNil(pickerStatus(game), "the tutor asks for a party member")
    Assert.isFalse(box:snapshot().visible, "the party picker hides the transient window")

    local printed = runScript(game, TOP_RIGHT_TUTOR, {
      { kind = "pick", slot = 0 },
      { kind = "row", row = 0, rows = listRows(6, true) },
    }, "the painted lesson finished", function(inner, messageId)
      if messageId == TOP_RIGHT_MSG.bye then
        local painted = box:snapshot()
        Assert.isTrue(painted.visible, "the window stays open through the source goodbye")
        Assert.equal(
          painted.displayedValue,
          200 - MUD_SLAP_PRICE,
          "the source update repaints the charged balance"
        )
      end
    end)
    Assert.isTrue(printedLine(printed, TOP_RIGHT_MSG.learned), "the lesson is announced")
    Assert.isFalse(box:snapshot().visible, "the source goodbye hides the transient window")
    Assert.equal(savedBattlePoints(game, "the painted lesson").balance, 200 - MUD_SLAP_PRICE, "the point is spent")

    -- Reopening the window captures the balance again.
    talk(game, TOP_RIGHT_TUTOR, "the reopened window")
    for _ = 1, 240 do
      local choice = game:contextChoiceStatus()
      if choice ~= nil and choice.state == "active" then
        break
      end
      game:step()
    end
    local reopened = box:snapshot()
    Assert.isTrue(reopened.visible, "the reopened window is visible again")
    Assert.equal(reopened.displayedValue, 200 - MUD_SLAP_PRICE, "the reopened window captures the current balance")
    local closed = runScript(game, TOP_RIGHT_TUTOR, {
      { kind = "question", row = 1 },
    }, "the declined lesson finished")
    Assert.isTrue(printedLine(closed, TOP_RIGHT_MSG.bye), "a declined lesson leaves through the source goodbye")
    Assert.isFalse(box:snapshot().visible, "the declined lesson hides the window")

    -- The saved balance and its spent statistic survive a continued game.
    game:restart()
    game:waitForFieldEntry()
    local continued = settledCapture(game, "the continued window scenario")
    Assert.equal(
      continued.battlePoints.balance,
      200 - MUD_SLAP_PRICE,
      "a continued game keeps the spent balance"
    )
    Assert.equal(continued.gameStats.battlePointsSpent, MUD_SLAP_PRICE, "a continued game keeps the spent statistic")
  end)
end

-- Ilex Forest's charcoal maker teaches Headbutt from the same compatibility
-- table: he accepts a party member whose rows list the move, appends it at the
-- empty row, refuses one the rows leave out, and reports a mon that already
-- knows it.
function T.tests.the_headbutt_tutor_uses_the_source_compatibility_rows()
  withField(HEADBUTT_MAP, HEADBUTT_TILE, {
    setup = function(game)
      Assert.isTrue(
        mons(game):giveMon({ species = "BULBASAUR", level = 20 }),
        "the Headbutt scenario needs a compatible mon"
      )
      setMoves(game, 0, { "TACKLE", "GROWL", "SCRATCH" })
      Assert.isTrue(
        mons(game):giveMon({ species = "MAGIKARP", level = 20 }),
        "the Headbutt refusal scenario needs an incompatible mon"
      )
      setMoves(game, 1, { "SPLASH", "TACKLE" })
      Assert.isTrue(
        mons(game):giveMon({ species = "BULBASAUR", level = 20 }),
        "the Headbutt known-move scenario needs a third mon"
      )
      setMoves(game, 2, { "TACKLE", "HEADBUTT" })
    end,
  }, function(game)
    talk(game, HEADBUTT_TUTOR, "the charcoal maker owns the interaction the scenario answers")
    local taught = runScript(game, HEADBUTT_TUTOR, {
      { kind = "question", row = 0 },
      { kind = "pick", slot = 0 },
    }, "the Headbutt lesson finished")
    Assert.isTrue(printedLine(taught, HEADBUTT_MSG.question), "the charcoal maker offers the source lesson")
    Assert.isTrue(printedLine(taught, HEADBUTT_MSG.whichMon), "the charcoal maker asks which Pokémon learns it")
    Assert.isTrue(printedLine(taught, HEADBUTT_MSG.poof), "the source plays its own lesson cadence")
    Assert.isTrue(printedLine(taught, HEADBUTT_MSG.learned), "the source announces the learned move")
    Assert.isTrue(printedLine(taught, HEADBUTT_MSG.stronger), "the charcoal maker reports the stronger mon")
    Assert.isFalse(printedLine(taught, HEADBUTT_MSG.cannotLearn), "a compatible mon is not refused")
    local row = taughtRow(game, 0, "HEADBUTT")
    Assert.equal(row, 4, "the taught move appends at the source row")
    Assert.equal(
      mons(game):partyMon(0).moves[row].pp,
      catalog(game):move("HEADBUTT").basePp,
      "the taught move starts at its base PP"
    )
    Assert.equal(mons(game):partyMon(0).moves[row].ppUps, 0, "the taught move carries no PP Up")
    Assert.equal(savedBattlePoints(game, "the Headbutt lesson").balance, 0, "the Headbutt lesson costs no point")

    talk(game, HEADBUTT_TUTOR, "the incompatible mon")
    local refused = runScript(game, HEADBUTT_TUTOR, {
      { kind = "question", row = 0 },
      { kind = "pick", slot = 1 },
      { kind = "cancel_pick" },
    }, "the incompatible mon finished")
    Assert.isTrue(printedLine(refused, HEADBUTT_MSG.cannotLearn), "the source refuses a mon outside its rows")
    Assert.isFalse(printedLine(refused, HEADBUTT_MSG.learned), "the refusal announces no move")
    Assert.equal(mons(game):countMonMoves(1), 2, "the refusal changes no moveset")

    talk(game, HEADBUTT_TUTOR, "the mon that already knows Headbutt")
    local known = runScript(game, HEADBUTT_TUTOR, {
      { kind = "question", row = 0 },
      { kind = "pick", slot = 2 },
      { kind = "cancel_pick" },
    }, "the known move finished")
    Assert.isTrue(printedLine(known, HEADBUTT_MSG.alreadyLearned), "the source reports the known move")
    Assert.isFalse(printedLine(known, HEADBUTT_MSG.learned), "a known move is not taught again")
    Assert.equal(mons(game):countMonMoves(2), 2, "the known move keeps its moveset")
  end)
end

return T
