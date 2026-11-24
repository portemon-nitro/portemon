-- The Move Deleter, the Move Reminder and Grandma Wilma's single-move tutor
-- through the production field. The Blackthorn move tutor house owns the
-- original scripts: the deleter's two-stage confirmation, the Move Maniac's
-- Heart Scale and relearn list, and the Draco Meteor lesson whose replacement
-- path reopens the native Summary. Each script runs its generated nodes, the
-- party picker and the native applications run their own source state machines,
-- and every published move, Heart Scale, friendship and saved record belongs to
-- its canonical owner.
--
-- The scenarios talk to the house objects across the floor, answer the source
-- questions, drive the native applications with the semantic button the source
-- asks for, and read back the canonical party, Bag and captured game record.
-- Only audio, screen fades and the wall clock are host boundaries; the render
-- trap stays active throughout, and no scenario assembles a session, a script,
-- a picker or a mon record by hand.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local Experience = require("libs.mons.src.gen4.Experience")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local SummaryCache = require("libs.assets.src.SummaryCache")

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = {
      "field-runtime",
      -- MAP_BLACKTHORN_MOVE_TUTOR_HOUSE (map 291) owns the four object scripts.
      "map:291",
      "map-data:291",
      "message-bank:635",
    },
    tags = { "field", "script", "mons", "moves", "summary" },
  },
  tests = {},
}

local HOUSE_MAP = "MAP_BLACKTHORN_MOVE_TUTOR_HOUSE"
-- The house's generated object scripts (scr_seq_0948_T30R0601.s).
local DELETER_SCRIPT = "vanilla.hgss.scr_seq.0948.script_000"
local REMINDER_SCRIPT = "vanilla.hgss.scr_seq.0948.script_001"
local DRACO_TUTOR_SCRIPT = "vanilla.hgss.scr_seq.0948.script_002"

-- 262_T30R0601.json: the deleter (gsmiddleman1) stands at (1,4), the Move Maniac
-- (gsbigman) at (3,4) and Grandma Wilma (gsoldwoman1) at (5,5). The player
-- answers each of them from the open floor tile directly south.
local DELETER_TILE = { fieldX = 1, fieldZ = 5, facing = "north" }
local REMINDER_TILE = { fieldX = 3, fieldZ = 5, facing = "north" }
local DRACO_TILE = { fieldX = 5, fieldZ = 6, facing = "north" }

-- msg_0635_T30R0601 bank ids the scenarios read back. The deleter's message 1
-- is its first source question ("force your Pokémon to forget some moves?").
local MSG_DELETER_WHICH_MON = 2
local MSG_DELETER_GOODBYE = 3
local MSG_DELETER_ONE_MOVE = 4
local MSG_DELETER_EGG = 5
local MSG_DELETER_WHICH_MOVE = 6
local MSG_DELETER_CONFIRM = 7
local MSG_DELETER_FORGOTTEN = 8
local MSG_REMINDER_NO_SCALE = 11
local MSG_REMINDER_WHICH_MON = 12
local MSG_REMINDER_WHICH_MOVE = 13
local MSG_REMINDER_NOTHING = 14
local MSG_REMINDER_EGG = 15
local MSG_REMINDER_HANDED_SCALE = 25
local MSG_DRACO_OFFER = 26
local MSG_DRACO_WHICH_MON = 30
local MSG_DRACO_NO_TRUST = 31
local MSG_DRACO_CANT_LEARN = 32
local MSG_DRACO_ALREADY_KNOWS = 34
local MSG_DRACO_TEACH = 62
local MSG_DRACO_TAUGHT = 42

local MOVE_DRACO_METEOR = "DRACO_METEOR"
-- MoveRelearner_Init waits for the application's own screen fade before it
-- accepts the source buttons; the scenarios let that one presentation cadence
-- finish before they press the Return or Confirm button.
local APPLICATION_ENTRY_TICKS = 60
-- METLOC_DAY_CARE_COUPLE (2000) narrowed with the source offset the gift egg
-- receipt uses; only the egg's isEgg identity matters to these scripts.
local GIFT_EGG_LOCATION_OFFSET = 14

---@param value unknown
---@return unknown
local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for key, item in pairs(value) do
    out[key] = copy(item)
  end
  return out
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
---@return table the live Bag service
local function bag(game)
  return assert(game.runtime.bagService, "the field runtime owns its Bag")
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
---@return table the care application host
local function careHost(game)
  return assert(game.runtime.pokemonCareHost, "the field runtime owns its care application host")
end

---@param game table
---@return boolean whether a care application currently owns the script modal
local function careActive(game)
  local host = game.runtime.pokemonCareHost
  return host ~= nil and host:isActive()
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
---@param slot integer
local function chooseSlot(game, slot)
  focusSlot(game, slot)
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
  error("the party selection never accepted slot " .. tostring(slot), 0)
end

---@param game table
local function cancelPicker(game)
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
  error("the party selection never cancelled", 0)
end

-- Answers the script's own question with one source row. The provider keeps the
-- cursor the last answer left, so the row is read instead of assumed.
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

-- Runs one source application to its own exit. Teaching is the source's single
-- Confirm answer in every state it owns (the move row, the "teach this move?"
-- question, the replacement moveset row and its confirmation, the learned
-- message). Cancelling presses the source's Return button once the application's
-- entry fade is over and then answers the give-up question, which the action
-- button accepts.
---@param game table
---@param mode "teach"|"cancel"
---@param label string
local function driveApplication(game, mode, label)
  local host = careHost(game)
  if mode == "teach" then
    for _ = 1, 900 do
      if not host:isActive() then
        return
      end
      pressAction(game)
    end
    error("the care application never finished teaching before " .. label, 0)
  end
  Assert.equal(mode, "cancel", "care applications are driven to teach or to cancel before " .. label)
  for _ = 1, APPLICATION_ENTRY_TICKS do
    Assert.isTrue(host:isActive(), "the care application stays open through its entry before " .. label)
    game:step()
  end
  pressCancel(game)
  for _ = 1, 900 do
    if not host:isActive() then
      return
    end
    pressAction(game)
  end
  error("the care application never cancelled before " .. label, 0)
end

---@class ScriptAction
---@field kind "pick"|"cancel_pick"|"care"|"choose"
---@field slot integer?
---@field row integer?
---@field mode string?

-- Drives one foreground source script the way a player does: dismiss printed
-- messages, answer its questions, hand every party selection and every native
-- application to the next prepared action, and stop when the script ends. Any
-- published fault of the running script fails the scenario at the tick it
-- appears.
---@param game table
---@param scriptId string
---@param actions ScriptAction[]
---@param label string
---@return integer[] printed message ids
local function runScript(game, scriptId, actions, label)
  local queue = actions or {}
  local nextAction = 1
  local printed, last = {}, nil
  local ended = #game:recordsForScript(scriptId, "script.ended")
  for _ = 1, 6000 do
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
      and not careActive(game)
    then
      return printed
    end
    local choice = game:contextChoiceStatus()
    local action = queue[nextAction]
    if pickerStatus(game) ~= nil then
      Assert.notNil(action, "the script asks for an unplanned party selection before " .. label)
      Assert.isTrue(
        action.kind == "pick" or action.kind == "cancel_pick",
        "the party selection is answered by a pick or a cancel before " .. label
      )
      nextAction = nextAction + 1
      if action.kind == "cancel_pick" then
        cancelPicker(game)
      else
        chooseSlot(game, assert(action.slot, "a planned pick names its slot"))
      end
    elseif careActive(game) then
      Assert.notNil(action, "the script opens an unplanned application before " .. label)
      Assert.equal(action.kind, "care", "the native application is driven by its planned action before " .. label)
      nextAction = nextAction + 1
      driveApplication(game, assert(action.mode, "a planned application names its mode"), label)
    elseif choice ~= nil and choice.state == "active" then
      Assert.notNil(action, "the script asks an unplanned question before " .. label)
      Assert.equal(action.kind, "choose", "the script question is answered by its planned row before " .. label)
      nextAction = nextAction + 1
      answerQuestion(game, assert(action.row, "a planned answer names its row"))
    elseif snapshot.dialogue.modal then
      pressAction(game)
    else
      game:step()
    end
  end
  local snapshot = game:snapshot()
  error(
    "the source script never reached "
      .. label
      .. "; selection="
      .. tostring(pickerStatus(game) ~= nil)
      .. ", application="
      .. tostring(careActive(game))
      .. ", modal="
      .. tostring(snapshot.dialogue.modal)
      .. ", message="
      .. tostring(snapshot.dialogue.messageId)
      .. ", foreground="
      .. tostring(snapshot.foregroundScript)
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
---@param scriptId string
---@param label string
local function talk(game, scriptId, label)
  game:pressAction()
  Assert.equal(game:interaction().scriptId, scriptId, "the object the scenario answers runs its own script before " .. label)
end

-- Binds the one care presentation lease the presented field would install. The
-- acceptance composition stops before rendering, so the lease reports the
-- validated Summary family and no drawable bundle; the application still runs
-- its own source states.
---@param game table
---@return table recorder with requests, leases and released counters
local function bindCarePresentation(game)
  local manifest = SummaryCache.loadManifest(assert(game.runtime.cacheFs, "the field runtime owns its cache"))
  local record = { requests = {}, leases = 0, released = 0 }
  game.runtime:bindPokemonCarePresentation(function(request)
    record.requests[#record.requests + 1] = copy(request)
    record.leases = record.leases + 1
    local lease = {}
    function lease:prepare()
      return { kind = "ready", key = "care", assets = { manifest = manifest } }
    end
    function lease:presentation()
      return nil
    end
    function lease:release()
      record.released = record.released + 1
    end
    return lease
  end)
  return record
end

-- Binds a care presentation whose preparation fails, so the application must
-- refuse to report a learned move instead of publishing one it cannot show.
---@param game table
---@return table recorder with leases and released counters
local function bindFailingCarePresentation(game)
  local record = { leases = 0, released = 0 }
  game.runtime:bindPokemonCarePresentation(function()
    record.leases = record.leases + 1
    local lease = {}
    function lease:prepare()
      return { kind = "failed", error = "the acceptance presentation has no source relearner art" }
    end
    function lease:presentation()
      return nil
    end
    function lease:release()
      record.released = record.released + 1
    end
    return lease
  end)
  return record
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

-- The source reminder list (MoveRelearner_GetEligibleLevelUpMoves): the current
-- form's level-up list in source order, every entry at or below the mon's level,
-- moves it does not already know, and a repeated entry only once.
---@param game table
---@param mon table
---@return string[] ordered move keys
local function reminderList(game, mon)
  local monCatalog = catalog(game)
  local species = monCatalog:species(mon.species)
  local level = Experience.level(monCatalog:growthCurve(species.growthCurve), mon.experience)
  local form = monCatalog:form(mon.species, mon.form)
  local known, seen, list = {}, {}, {}
  for _, entry in ipairs(assert(mon.moves, "the mon carries its moves")) do
    known[entry.move] = true
  end
  for _, entry in ipairs(assert(form.levelUpMoves, "the form carries its level-up list")) do
    if entry.level <= level and not known[entry.move] and not seen[entry.move] then
      seen[entry.move] = true
      list[#list + 1] = entry.move
    end
  end
  return list
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

-- Stages one canonical party change through the owned prepared publication, the
-- same path the field uses for authored mon updates.
---@param game table
---@param slot0 integer
---@param change fun(mon: table)
local function stageMon(game, slot0, change)
  local service = mons(game)
  local mon = service:partyMon(slot0)
  change(mon)
  mon.condition = { currentHp = service:derive(mon).maxHp, effects = {} }
  local preparation, reason = service:preparePartyChanges(service:partyRevision(), { { slot = slot0, mon = mon } })
  Assert.isNil(reason, "the prepared party change stages cleanly")
  assert(preparation).publish()
end

---@param game table
---@param slot0 integer
---@param friendship integer
local function setFriendship(game, slot0, friendship)
  stageMon(game, slot0, function(mon)
    mon.friendship = friendship
  end)
end

---@param tile { fieldX: integer, fieldZ: integer, facing: string }
---@param setup fun(game: table)?
---@param body fun(game: table)
local function withHouse(tile, setup, body)
  local harness = AcceptanceHarness.new()
  local createGame = harness.gameFactory
  harness.gameFactory = function(versionId, map)
    local game = createGame(versionId, map)
    game.location = { mapSymbol = HOUSE_MAP, fieldX = tile.fieldX, fieldZ = tile.fieldZ, facing = tile.facing }
    return game
  end
  local game = harness:boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = HOUSE_MAP,
    save = "fresh",
    fieldOptions = { recordingScriptHosts = true, audioHost = "recording" },
  })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    Assert.isNil(
      game.runtime.session.mapEntryStage,
      "the move tutor house finishes its entry scripts: " .. table.concat(allScriptFaults(game), ",")
    )
    -- Headless composition binds the explicit no-image preparation: the party
    -- picker reports ready without realizing GPU icons it never draws.
    game.runtime:bindPartyIconPreparation(function()
      return true
    end, function() end)
    if setup ~= nil then
      setup(game)
    end
    body(game)
    Assert.equal(game:renderAttempts(), 0, "the scenarios stop before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

-- The deleter's picker is the native learn-forget Summary: the first move row is
-- where the cursor opens, and the move it accepts is the one the source script
-- then asks about. An HM is a legal answer for the deleter (the HM guard belongs
-- to the replacement paths that teach a move), and the mon keeps every move
-- until the source script's own confirmation accepts the deletion.
function T.tests.the_deleter_forgets_the_hm_only_after_the_source_confirmation()
  withHouse(DELETER_TILE, function(game)
    Assert.isTrue(mons(game):giveMon({ species = "RATTATA", level = 20 }), "the deleter scenario needs one party mon")
    setMoves(game, 0, { "CUT", "TACKLE", "GROWL", "SCRATCH" })
    local hmMove = assert(mons(game):partyMon(0).moves[1], "the setup mon carries its first move").move
    Assert.equal(hmMove, "CUT", "the hidden machine sits in the row the picker opens on")
    local hmMoves = assert(game.runtime.itemCatalog, "the runtime owns the item catalog"):hmMoveNativeIds()
    Assert.isTrue(
      hmMoves[catalog(game):move(hmMove).nativeId] == true,
      "the selected move is one the source marks as a hidden machine"
    )
    Assert.equal(mons(game):countMonMoves(0), 4, "the setup mon knows four moves")
    bindCarePresentation(game)
  end, function(game)
    talk(game, DELETER_SCRIPT, "the deleter answers")
    local printed = runScript(game, DELETER_SCRIPT, {
      { kind = "choose", row = 0 },
      { kind = "pick", slot = 0 },
      { kind = "care", mode = "teach" },
      { kind = "choose", row = 1 },
      { kind = "pick", slot = 0 },
      { kind = "care", mode = "teach" },
      { kind = "choose", row = 0 },
    }, "the deleter has finished")
    Assert.isTrue(printedLine(printed, MSG_DELETER_WHICH_MON), "the deleter asks which Pokémon forgets a move")
    Assert.isTrue(printedLine(printed, MSG_DELETER_WHICH_MOVE), "the deleter asks which move is forgotten")
    Assert.isTrue(printedLine(printed, MSG_DELETER_CONFIRM), "the source script asks its own confirmation")
    Assert.isTrue(printedLine(printed, MSG_DELETER_FORGOTTEN), "the deletion is confirmed back to the player")
    Assert.isFalse(printedLine(printed, MSG_DELETER_GOODBYE), "the accepted deletion is not the goodbye branch")

    local mon = mons(game):partyMon(0)
    Assert.equal(#mon.moves, 3, "exactly one move leaves the record")
    for index, entry in ipairs(mon.moves) do
      Assert.isTrue(entry.move ~= "CUT", "the selected hidden machine is the move that was forgotten at " .. index)
    end
    Assert.equal(mon.moves[1].move, "TACKLE", "the forgotten row compacts the remaining moves in order")
    Assert.equal(mon.moves[2].move, "GROWL", "the forgotten row compacts the remaining moves in order")
    Assert.equal(mon.moves[3].move, "SCRATCH", "the forgotten row compacts the remaining moves in order")

    local settled = settledCapture(game, "the forgotten move")
    Assert.equal(settled.mons.party.mons[1].moves[1].move, "TACKLE", "the saved record keeps the deletion")

    -- Further ticks republish nothing: the deletion happened at the source
    -- command that owns it, not in the script's teardown.
    for _ = 1, 8 do
      game:step()
    end
    local again = settledCapture(game, "the forgotten move after further ticks")
    Assert.equal(#again.mons.party.mons[1].moves, 3, "no later tick repeats the deletion")

    game:restart()
    game:waitForFieldEntry()
    local continued = settledCapture(game, "the continued field")
    Assert.equal(continued.mons.party.mons[1].moves[1].move, "TACKLE", "a continued field keeps the forgotten move")
    Assert.equal(#continued.mons.party.mons[1].moves, 3, "a continued field keeps the shortened moveset")
  end)
end

-- Cancelling the move picker reports the source's own cancellation value: the
-- script returns to "which Pokémon", the mon keeps every move, and cancelling
-- the party selection afterwards leaves through the goodbye branch.
function T.tests.the_deleter_picker_cancel_returns_to_the_source_selection()
  withHouse(DELETER_TILE, function(game)
    Assert.isTrue(mons(game):giveMon({ species = "RATTATA", level = 20 }), "the cancel scenario needs one party mon")
    setMoves(game, 0, { "CUT", "TACKLE", "GROWL", "SCRATCH" })
    bindCarePresentation(game)
  end, function(game)
    talk(game, DELETER_SCRIPT, "the cancelled deletion")
    local printed = runScript(game, DELETER_SCRIPT, {
      { kind = "choose", row = 0 },
      { kind = "pick", slot = 0 },
      { kind = "care", mode = "cancel" },
      { kind = "cancel_pick" },
    }, "the cancelled deletion has finished")
    -- Cancelling the picker answers 255, and only that value sends the script
    -- back to "which Pokémon should forget a move?" instead of the confirmation.
    local whichMon = 0
    for _, messageId in ipairs(printed) do
      if messageId == MSG_DELETER_WHICH_MON then
        whichMon = whichMon + 1
      end
    end
    Assert.equal(whichMon, 2, "the cancelled picker returns to the source's own selection prompt")
    Assert.isFalse(printedLine(printed, MSG_DELETER_CONFIRM), "a cancelled picker never asks for confirmation")
    Assert.isFalse(printedLine(printed, MSG_DELETER_FORGOTTEN), "a cancelled picker never forgets a move")
    Assert.isTrue(printedLine(printed, MSG_DELETER_GOODBYE), "cancelling the selection leaves through the goodbye")

    local mon = mons(game):partyMon(0)
    Assert.equal(#mon.moves, 4, "cancelling deletes nothing")
    Assert.equal(mon.moves[1].move, "CUT", "cancelling keeps the highlighted move")
    local settled = settledCapture(game, "the cancelled deletion")
    Assert.equal(#settled.mons.party.mons[1].moves, 4, "the saved record keeps every move")
  end)
end

-- The source script refuses an Egg and a mon that knows a single move before it
-- ever opens the picker; both refusals return to the source's own Pokémon
-- question and leave a moveset untouched.
function T.tests.the_deleter_refuses_an_egg_and_a_single_move_without_a_picker()
  withHouse(DELETER_TILE, function(game)
    Assert.isTrue(mons(game):giveMon({ species = "RATTATA", level = 20 }), "the refusal scenario needs a party mon")
    setMoves(game, 0, { "CUT", "TACKLE", "GROWL", "SCRATCH" })
    Assert.isTrue(
      mons(game):giveEgg({ species = "TOGEPI", locationOffset = GIFT_EGG_LOCATION_OFFSET }),
      "the refusal scenario needs an egg"
    )
  end, function(game)
    talk(game, DELETER_SCRIPT, "the egg refusal")
    local egg = runScript(game, DELETER_SCRIPT, {
      { kind = "choose", row = 0 },
      { kind = "pick", slot = 1 },
      { kind = "cancel_pick" },
    }, "the egg refusal has finished")
    Assert.isTrue(printedLine(egg, MSG_DELETER_EGG), "the source script refuses an Egg")
    Assert.isFalse(printedLine(egg, MSG_DELETER_WHICH_MOVE), "an Egg never reaches the move picker")
    Assert.isTrue(printedLine(egg, MSG_DELETER_GOODBYE), "the refused selection leaves through the goodbye")
    Assert.equal(#mons(game):partyMon(0).moves, 4, "an Egg refusal changes no move")

    setMoves(game, 0, { "CUT" })
    talk(game, DELETER_SCRIPT, "the single-move refusal")
    local single = runScript(game, DELETER_SCRIPT, {
      { kind = "choose", row = 0 },
      { kind = "pick", slot = 0 },
      { kind = "cancel_pick" },
    }, "the single-move refusal has finished")
    Assert.isTrue(printedLine(single, MSG_DELETER_ONE_MOVE), "the source script refuses a mon with one move")
    Assert.isFalse(printedLine(single, MSG_DELETER_WHICH_MOVE), "a one-move mon never reaches the move picker")
    local moves = mons(game):partyMon(0).moves
    Assert.equal(#moves, 1, "a one-move refusal forgets nothing")
    Assert.equal(moves[1].move, "CUT", "a one-move refusal keeps the only move")
  end)
end

-- The reminder teaches the source's own ordered list: the current form's
-- level-up moves at or below the mon's level, without the moves it already
-- knows and with a repeated level-up entry offered once. Each teach publishes
-- exactly the selected move with the move's base power points and no power-point
-- up, leaves friendship untouched, and spends one Heart Scale after the source
-- reports success.
function T.tests.the_reminder_teaches_the_ordered_relearn_list_once_per_scale()
  withHouse(REMINDER_TILE, function(game)
    game:setWorldState({ flag = FieldScriptSymbols.flagsByName.FLAG_MET_MOVE_MANIAC })
    Assert.isTrue(
      mons(game):giveMon({ species = "PIDGEY", level = 22 }),
      "the reminder scenario needs one party mon"
    )
    -- Keep only the newest level-up move so the relearn list carries the
    -- species' repeated level-1/level-10 entry beside its later moves.
    local service = mons(game)
    local keep = service:partyMon(0).moves[service:countMonMoves(0)].move
    setMoves(game, 0, { keep })
    Assert.isTrue(bag(game):add("HEART_SCALE", 2), "the reminder spends one Heart Scale per lesson")
    local expected = reminderList(game, service:partyMon(0))
    Assert.isTrue(#expected >= 2, "the setup mon must offer at least two relearn moves")
    bindCarePresentation(game)
  end, function(game)
    local service = mons(game)
    local friendship = service:partyMon(0).friendship
    local scales = bag(game):quantity("HEART_SCALE")
    local expected = reminderList(game, service:partyMon(0))

    for index = 1, 2 do
      talk(game, REMINDER_SCRIPT, "reminder lesson " .. tostring(index))
      local printed = runScript(game, REMINDER_SCRIPT, {
        { kind = "pick", slot = 0 },
        { kind = "care", mode = "teach" },
      }, "reminder lesson " .. tostring(index) .. " has finished")
      Assert.isTrue(printedLine(printed, MSG_REMINDER_WHICH_MON), "the reminder asks which Pokémon is tutored")
      Assert.isTrue(printedLine(printed, MSG_REMINDER_WHICH_MOVE), "the reminder opens the source relearn list")
      Assert.isTrue(printedLine(printed, MSG_REMINDER_HANDED_SCALE), "the source hands over exactly one Heart Scale")
      Assert.isFalse(printedLine(printed, MSG_REMINDER_NOTHING), "an eligible mon is not refused")

      local mon = service:partyMon(0)
      Assert.equal(#mon.moves, index + 1, "each lesson appends one move")
      Assert.equal(
        mon.moves[index + 1].move,
        expected[index],
        "the reminder offers the relearn entries in source order at position " .. tostring(index)
      )
      local definition = catalog(game):move(expected[index])
      Assert.equal(mon.moves[index + 1].pp, definition.basePp, "the taught move starts at its base power points")
      Assert.equal(mon.moves[index + 1].ppUps, 0, "the taught move carries no power-point up")
      Assert.equal(mon.friendship, friendship, "relearning a level-up move awards no friendship")
      Assert.equal(bag(game):quantity("HEART_SCALE"), scales - index, "each success spends exactly one Heart Scale")
      for first = 1, #mon.moves do
        for second = first + 1, #mon.moves do
          Assert.isTrue(
            mon.moves[first].move ~= mon.moves[second].move,
            "the published moveset never repeats a move (" ..
              tostring(mon.moves[first].move) .. " at " .. tostring(first) .. " and " .. tostring(second) .. ")"
          )
        end
      end
    end

    local settled = settledCapture(game, "the relearned moves")
    local saved = settled.mons.party.mons[1]
    Assert.equal(#saved.moves, 3, "the saved record keeps the known move and both lessons")
    Assert.equal(saved.moves[2].move, expected[1], "the saved record keeps the first relearned move")
    Assert.equal(saved.moves[3].move, expected[2], "the saved record keeps the second relearned move")
    Assert.equal(saved.friendship, friendship, "the saved record keeps the mon's friendship")

    game:restart()
    game:waitForFieldEntry()
    local continued = settledCapture(game, "the continued reminder")
    Assert.equal(continued.mons.party.mons[1].moves[3].move, expected[2], "a continued field keeps the lesson")
  end)
end

-- The reminder's own gates stay in the script: no Heart Scale, an Egg, and a mon
-- with nothing left to relearn are refused before the application opens.
function T.tests.the_reminder_refuses_without_a_scale_an_egg_and_an_empty_list()
  withHouse(REMINDER_TILE, function(game)
    game:setWorldState({ flag = FieldScriptSymbols.flagsByName.FLAG_MET_MOVE_MANIAC })
    Assert.isTrue(
      mons(game):giveMon({ species = "PIDGEY", level = 22 }),
      "the reminder refusal scenario needs a party mon"
    )
    Assert.isTrue(
      mons(game):giveMon({ species = "MAGIKARP", level = 15 }),
      "the empty-list scenario needs a mon that already knows its whole level-up list"
    )
    Assert.isTrue(
      mons(game):giveEgg({ species = "TOGEPI", locationOffset = GIFT_EGG_LOCATION_OFFSET }),
      "the reminder Egg refusal needs an Egg"
    )
  end, function(game)
    talk(game, REMINDER_SCRIPT, "the missing Heart Scale")
    local scale = runScript(game, REMINDER_SCRIPT, {}, "the missing Heart Scale has finished")
    Assert.isTrue(printedLine(scale, MSG_REMINDER_NO_SCALE), "the reminder asks for a Heart Scale before anything else")
    Assert.isFalse(printedLine(scale, MSG_REMINDER_WHICH_MON), "no Heart Scale means no selection")

    Assert.isTrue(bag(game):add("HEART_SCALE", 1), "the refusals still need one Heart Scale")

    talk(game, REMINDER_SCRIPT, "the Egg refusal")
    local egg = runScript(game, REMINDER_SCRIPT, {
      { kind = "pick", slot = 2 },
    }, "the Egg refusal has finished")
    Assert.isTrue(printedLine(egg, MSG_REMINDER_EGG), "the reminder refuses an Egg")
    Assert.isFalse(printedLine(egg, MSG_REMINDER_WHICH_MOVE), "an Egg never opens the relearn list")

    talk(game, REMINDER_SCRIPT, "the empty relearn list")
    local empty = runScript(game, REMINDER_SCRIPT, {
      { kind = "pick", slot = 1 },
    }, "the empty relearn list has finished")
    Assert.isTrue(printedLine(empty, MSG_REMINDER_NOTHING), "a mon with nothing to relearn is refused")
    Assert.isFalse(printedLine(empty, MSG_REMINDER_WHICH_MOVE), "an empty list never opens the application")
    Assert.isFalse(printedLine(empty, MSG_REMINDER_HANDED_SCALE), "a refusal spends no Heart Scale")
    Assert.equal(bag(game):quantity("HEART_SCALE"), 1, "every refusal keeps the Heart Scale")
    Assert.equal(#mons(game):partyMon(1).moves, 2, "a refusal changes no moveset")
    Assert.isTrue(mons(game):partyMon(2).isEgg == true, "the refused egg is still an unhatched record")
  end)
end

-- Stopping the reminder application teaches nothing and reports the source's
-- cancellation: the script says goodbye, the mon keeps its list, and the Heart
-- Scale stays in the Bag.
function T.tests.the_reminder_cancel_teaches_nothing_and_keeps_the_scale()
  withHouse(REMINDER_TILE, function(game)
    game:setWorldState({ flag = FieldScriptSymbols.flagsByName.FLAG_MET_MOVE_MANIAC })
    Assert.isTrue(mons(game):giveMon({ species = "PIDGEY", level = 22 }), "the cancel scenario needs one party mon")
    local service = mons(game)
    local keep = service:partyMon(0).moves[service:countMonMoves(0)].move
    setMoves(game, 0, { keep })
    Assert.isTrue(bag(game):add("HEART_SCALE", 1), "the reminder needs a Heart Scale to open")
  end, function(game)
    local service = mons(game)
    local movesBefore = copy(service:partyMon(0).moves)
    local presentation = bindCarePresentation(game)
    talk(game, REMINDER_SCRIPT, "the cancelled lesson")
    local printed = runScript(game, REMINDER_SCRIPT, {
      { kind = "pick", slot = 0 },
      { kind = "care", mode = "cancel" },
    }, "the cancelled lesson has finished")
    Assert.isTrue(printedLine(printed, MSG_REMINDER_WHICH_MOVE), "the cancelled lesson still opens the relearn list")
    Assert.isTrue(printedLine(printed, MSG_REMINDER_NO_SCALE), "a cancelled lesson leaves through the source goodbye")
    Assert.isFalse(printedLine(printed, MSG_REMINDER_HANDED_SCALE), "nothing is learned, so no Heart Scale is handed over")
    Assert.deepEqual(service:partyMon(0).moves, movesBefore, "cancelling changes no move")
    Assert.equal(bag(game):quantity("HEART_SCALE"), 1, "cancelling spends no Heart Scale")
    Assert.equal(presentation.released, presentation.leases, "the closed application releases every lease it took")
    Assert.isNil(game:snapshot().foregroundScript, "the field returns to the player")
    Assert.equal(game:snapshot().fieldLocked, false, "the cancelled lesson releases the field")
  end)
end

-- A care presentation that cannot be prepared never reports a learned move: the
-- application closes, the mon keeps its moves and the Heart Scale stays spent on
-- nothing.
function T.tests.the_reminder_fails_closed_without_its_source_presentation()
  withHouse(REMINDER_TILE, function(game)
    game:setWorldState({ flag = FieldScriptSymbols.flagsByName.FLAG_MET_MOVE_MANIAC })
    Assert.isTrue(mons(game):giveMon({ species = "PIDGEY", level = 22 }), "the failure scenario needs one party mon")
    local service = mons(game)
    local keep = service:partyMon(0).moves[service:countMonMoves(0)].move
    setMoves(game, 0, { keep })
    Assert.isTrue(bag(game):add("HEART_SCALE", 1), "the failure scenario needs a Heart Scale")
  end, function(game)
    local service = mons(game)
    local movesBefore = copy(service:partyMon(0).moves)
    local presentation = bindFailingCarePresentation(game)
    talk(game, REMINDER_SCRIPT, "the unprepared lesson")
    local printed = runScript(game, REMINDER_SCRIPT, {
      { kind = "pick", slot = 0 },
      { kind = "care", mode = "teach" },
    }, "the unprepared lesson has finished")
    Assert.isFalse(
      printedLine(printed, MSG_REMINDER_HANDED_SCALE),
      "an application without its source presentation reports no learned move"
    )
    Assert.deepEqual(service:partyMon(0).moves, movesBefore, "the unprepared lesson teaches nothing")
    Assert.equal(bag(game):quantity("HEART_SCALE"), 1, "the unprepared lesson spends no Heart Scale")
    Assert.isTrue(presentation.leases >= 1, "the application asked for its source presentation")
    Assert.equal(presentation.released, presentation.leases, "the failed application releases every lease it took")
    Assert.equal(game:snapshot().fieldLocked, false, "the failed application releases the field")
  end)
end

-- Grandma Wilma's lesson is the same application in tutor mode: one offered move,
-- the native replacement Summary when the mon already knows four moves, and the
-- move published at its base power points without any friendship award.
function T.tests.the_draco_tutor_replaces_through_the_native_summary()
  withHouse(DRACO_TILE, function(game)
    Assert.isTrue(mons(game):giveMon({ species = "DRATINI", level = 30 }), "the tutor scenario needs a party mon")
    setMoves(game, 0, { "TACKLE", "GROWL", "SCRATCH", "BITE" })
    setFriendship(game, 0, 255)
    Assert.equal(mons(game):countMonMoves(0), 4, "the tutor scenario starts with a full moveset")
  end, function(game)
    local service = mons(game)
    talk(game, DRACO_TUTOR_SCRIPT, "the Draco Meteor lesson")
    local printed = runScript(game, DRACO_TUTOR_SCRIPT, {
      { kind = "choose", row = 0 },
      { kind = "pick", slot = 0 },
      { kind = "care", mode = "teach" },
    }, "the Draco Meteor lesson has finished")
    Assert.isTrue(printedLine(printed, MSG_DRACO_OFFER), "the tutor offers the source lesson")
    Assert.isTrue(printedLine(printed, MSG_DRACO_WHICH_MON), "the tutor asks which Pokémon learns the move")
    Assert.isTrue(printedLine(printed, MSG_DRACO_TEACH), "the tutor names the mon it will teach")
    Assert.isTrue(printedLine(printed, MSG_DRACO_TAUGHT), "the tutor confirms the finished lesson")
    Assert.isFalse(printedLine(printed, MSG_DRACO_NO_TRUST), "a fully bonded Dragon is not refused")
    Assert.isFalse(printedLine(printed, MSG_DRACO_CANT_LEARN), "a Dragon is not refused as unable to learn")

    local mon = service:partyMon(0)
    Assert.equal(#mon.moves, 4, "the full moveset keeps its four entries")
    Assert.equal(mon.moves[1].move, MOVE_DRACO_METEOR, "the replacement Summary's first row is the replaced move")
    Assert.equal(mon.moves[2].move, "GROWL", "the untouched entries keep their order")
    Assert.equal(mon.moves[3].move, "SCRATCH", "the untouched entries keep their order")
    Assert.equal(mon.moves[4].move, "BITE", "the untouched entries keep their order")
    local definition = catalog(game):move(MOVE_DRACO_METEOR)
    Assert.equal(mon.moves[1].pp, definition.basePp, "the taught move starts at its base power points")
    Assert.equal(mon.moves[1].ppUps, 0, "the taught move carries no power-point up")
    Assert.equal(mon.friendship, 255, "the tutor awards no friendship")

    local settled = settledCapture(game, "the tutor lesson")
    Assert.equal(settled.mons.party.mons[1].moves[1].move, MOVE_DRACO_METEOR, "the saved record keeps the lesson")
  end)
end

-- Grandma Wilma's own gates stay in her script: an unbonded Dragon, a mon that
-- cannot learn the move and one that already knows it are each answered without
-- opening the application.
function T.tests.the_draco_tutor_keeps_its_source_gates()
  withHouse(DRACO_TILE, function(game)
    Assert.isTrue(mons(game):giveMon({ species = "DRATINI", level = 30 }), "the gate scenario needs a Dragon")
    setMoves(game, 0, { "TACKLE", "GROWL", "SCRATCH", "BITE" })
    setFriendship(game, 0, 254)
    Assert.isTrue(mons(game):giveMon({ species = "PIDGEY", level = 22 }), "the gate scenario needs a non-Dragon")
    Assert.isTrue(
      mons(game):giveMon({ species = "DRAGONAIR", level = 30 }),
      "the gate scenario needs a Dragon that already knows the lesson"
    )
    setMoves(game, 2, { MOVE_DRACO_METEOR, "GROWL", "SCRATCH", "BITE" })
    setFriendship(game, 2, 255)
  end, function(game)
    local service = mons(game)
    local untrusted = copy(service:partyMon(0).moves)
    local presentation = bindCarePresentation(game)

    talk(game, DRACO_TUTOR_SCRIPT, "the unbonded Dragon")
    local unbonded = runScript(game, DRACO_TUTOR_SCRIPT, {
      { kind = "choose", row = 0 },
      { kind = "pick", slot = 0 },
    }, "the unbonded Dragon has finished")
    Assert.isTrue(printedLine(unbonded, MSG_DRACO_NO_TRUST), "the tutor refuses a mon that trusts the player too little")
    Assert.isFalse(printedLine(unbonded, MSG_DRACO_TEACH), "no lesson starts for an unbonded mon")
    Assert.deepEqual(service:partyMon(0).moves, untrusted, "the refusal teaches nothing")
    Assert.equal(presentation.leases, 0, "the refusal never opens the application")

    talk(game, DRACO_TUTOR_SCRIPT, "the non-Dragon")
    local unable = runScript(game, DRACO_TUTOR_SCRIPT, {
      { kind = "choose", row = 0 },
      { kind = "pick", slot = 1 },
    }, "the non-Dragon has finished")
    Assert.isTrue(printedLine(unable, MSG_DRACO_CANT_LEARN), "the tutor refuses a mon that cannot learn the move")
    Assert.isFalse(printedLine(unable, MSG_DRACO_TEACH), "no lesson starts for a mon that cannot learn")
    Assert.equal(presentation.leases, 0, "the refusal never opens the application")

    talk(game, DRACO_TUTOR_SCRIPT, "the mon that already knows the move")
    local known = runScript(game, DRACO_TUTOR_SCRIPT, {
      { kind = "choose", row = 0 },
      { kind = "pick", slot = 2 },
    }, "the known move has finished")
    Assert.isTrue(
      printedLine(known, MSG_DRACO_ALREADY_KNOWS),
      "the tutor refuses a mon that already knows the offered move"
    )
    Assert.isFalse(printedLine(known, MSG_DRACO_TEACH), "no lesson starts for a known move")
    Assert.equal(presentation.leases, 0, "the refusal never opens the application")
  end)
end

return T
