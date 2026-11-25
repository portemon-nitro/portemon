-- The specialty-NPC query leaf through the production field: the Route 31
-- Kenya hand-back script, the Route 35 gatehouse letter scan, the Battle Tower
-- individual-value judge, the Celadon Prize Corner Hidden Power reader and the
-- Blackthorn east-house effort-ribbon reader. Every script, message row,
-- party picker, party record, mailbox slot and saved script variable below is
-- production-owned; only audio, screen fades, the wall clock and the save root
-- are host boundaries, and the render trap stays active.
--
-- Every expected message row and script-variable transition comes from the
-- retail script the scenario runs, and every expected record identity comes
-- from the loan and letter the NPC trade owner authored.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local FinalizedGameFixture = require("tests.support.FinalizedGameFixture")
local LocalClock = require("game.src.LocalClock")

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = {
      "field-runtime",
      -- MAP_ROUTE_31 runs the script that hands Kenya back (member 230); the
      -- resident coverage streams the five-by-five cells around the player.
      "map:35",
      "map-data:35",
      "field-cell:0-296",
      "field-cell:0-297",
      "field-cell:0-298",
      "field-cell:0-299",
      "field-cell:0-300",
      "field-cell:0-343",
      "field-cell:0-344",
      "field-cell:0-345",
      "field-cell:0-346",
      "field-cell:0-347",
      "field-cell:0-390",
      "field-cell:0-391",
      "field-cell:0-392",
      "field-cell:0-393",
      "field-cell:0-394",
      "field-cell:0-437",
      "field-cell:0-438",
      "field-cell:0-439",
      "field-cell:0-440",
      "field-cell:0-441",
      "field-cell:0-484",
      "field-cell:0-485",
      "field-cell:0-486",
      "field-cell:0-487",
      "field-cell:0-488",
      -- The represented neighbor maps the coverage region carries.
      "map-data:73",
      "map-data:34",
      "map-data:36",
      "message-bank:378",
      -- MAP_ROUTE_35_GOLDENROD_GATEHOUSE runs the letter scan (member 241).
      "map:101",
      "map-data:101",
      "message-bank:388",
      -- MAP_BATTLE_TOWER runs the individual-value judge (member 69).
      "map:265",
      "map-data:265",
      "message-bank:96",
      -- MAP_CELADON_PRIZE_CORNER runs the Hidden Power reader (member 804),
      -- whose type-name row reads the generated type names.
      "map:382",
      "map-data:382",
      "message-bank:509",
      "message-bank:735",
      -- MAP_BLACKTHORN_EAST_HOUSE runs the effort-ribbon reader (member 947).
      "map:290",
      "map-data:290",
      "message-bank:634",
      -- MAP_PEWTER_MUSEUM_OF_SCIENCE runs the fossil restoration reader
      -- (member 755).
      "map:471",
      "map-data:471",
      "message-bank:464",
      -- MAP_LAKE_OF_RAGE_FISHING_GURU_HOUSE runs the fishing-competition size
      -- reader (member 940).
      "map:295",
      "map-data:295",
      "message-bank:628",
    },
    tags = { "field", "script", "mons", "mail", "npc" },
  },
  tests = {},
}

-- Retail object scripts: the Route 31 deliverer's hand-back, the Route 35
-- gatehouse letter scan, the Battle Tower judge, the Celadon Prize Corner
-- reader and the Blackthorn east-house effort-ribbon reader.
local KENYA_RETURN_SCRIPT = "vanilla.hgss.scr_seq.0230.script_001"
local GATEHOUSE_SCAN_SCRIPT = "vanilla.hgss.scr_seq.0241.script_000"
local JUDGE_SCRIPT = "vanilla.hgss.scr_seq.0069.script_023"
local HIDDEN_POWER_SCRIPT = "vanilla.hgss.scr_seq.0804.script_002"
local EFFORT_RIBBON_SCRIPT = "vanilla.hgss.scr_seq.0947.script_001"
local FOSSIL_SCRIPT = "vanilla.hgss.scr_seq.0755.script_001"
local SIZE_RECORD_SCRIPT = "vanilla.hgss.scr_seq.0940.script_000"

-- The maps and the tiles the player talks from, each adjacent to the object
-- whose own source script runs. A route map is compiled around its own world
-- origin, so its boot location is the tile measured from that origin while
-- every later coordinate stays global.
local ROUTE_31 = {
  map = "MAP_ROUTE_31",
  tile = { fieldX = 540, fieldZ = 272 },
  facing = "north",
  origin = { x = 512, z = 256 },
}
local GATEHOUSE = {
  map = "MAP_ROUTE_35_GOLDENROD_GATEHOUSE",
  tile = { fieldX = 2, fieldZ = 8 },
  facing = "west",
}
local BATTLE_TOWER = { map = "MAP_BATTLE_TOWER", tile = { fieldX = 24, fieldZ = 8 }, facing = "north" }
local PRIZE_CORNER = { map = "MAP_CELADON_PRIZE_CORNER", tile = { fieldX = 6, fieldZ = 3 }, facing = "east" }
local BLACKTHORN = { map = "MAP_BLACKTHORN_EAST_HOUSE", tile = { fieldX = 8, fieldZ = 6 }, facing = "north" }
local PEWTER_MUSEUM = {
  map = "MAP_PEWTER_MUSEUM_OF_SCIENCE",
  tile = { fieldX = 26, fieldZ = 10 },
  facing = "north",
}
local FISHING_GURU_HOUSE = {
  map = "MAP_LAKE_OF_RAGE_FISHING_GURU_HOUSE",
  tile = { fieldX = 5, fieldZ = 6 },
  facing = "north",
}

-- The source loan and letter this slice borrows from the NPC trade owner.
local KENYA_TRADE_ID = 7
local KENYA_LEVEL = 20
local KENYA_MAP_ID = 101
-- The Mail pocket item the Kenya letter uses.
local KENYA_MAIL_ITEM = "GRASS_MAIL"
-- The source ribbon identity the Blackthorn reader awards: sRibbonInfo's row
-- 24 is the effort ribbon, stored in the GBA ribbon word at bit 24.
local EFFORT_RIBBON_ID = 24
local EFFORT_RIBBON_GROUP = "gba"
local EFFORT_RIBBON_BIT = 24
-- ScrCmd_GetPartyLeadAlive feeds the source effort threshold; 510 is the total
-- that earns the ribbon and the row below it is the source's own near miss.
local EFFORT_THRESHOLD = 510
local EFFORT_NEAR_MISS = 509

-- Message rows of the retail scripts this suite runs.
local KENYA_ROW = {
  intro = 1,
  noMail = 2,
  wrongLetter = 3,
  returned = 5,
  reward = 7,
  farewell = 8,
}
local GATEHOUSE_ROW = { letterFound = 6, letterMissing = 9 }
local JUDGE_ROW = {
  decentTotal = 118,
  bestHp = 122,
  bestAttack = 123,
  bestPotential = 131,
}
-- The reader's own rows: the cancelled prompt, the type it names for a mon
-- that would learn Hidden Power, the type it names for one that already knows
-- it, and the refusal. Hidden Power's native move identity is 237.
local HIDDEN_POWER_ROW = { cancel = 6, learnedType = 4, currentType = 5, refused = 8 }
local HIDDEN_POWER_MOVE = 237
local EFFORT_ROW = {
  alreadyHas = 14,
  enough = 6,
  awarded = 7,
  farewell = 8,
  nearMiss = 13,
}

-- Message rows of the retail fishing-competition reader (bank 628): the
-- prompt, the outstanding-record reward, its record note, the equal-size row
-- and the below-record row.
local SIZE_RECORD_ROW = { prompt = 3, larger = 4, reward = 5, equal = 6, smaller = 7 }
-- The source memento the reader hands out for an outstanding record: one
-- Ether, as a native item identity.
local SIZE_RECORD_PRIZE = 38
-- The source species the reader measures.
local MAGIKARP_SPECIES = 129
-- GetMonSizeHash for the measured record's staged spread: personality 0x1200
-- with low individual-value nibbles 1..6 mixes to this saved hash.
local SIZE_RECORD_HASH = 286

-- The source fossil the museum reader offers: the Helix Fossil it revives into
-- an Omanyte, and the row set its script prints for each answer.
local FOSSIL_ITEM = "HELIX_FOSSIL"
local FOSSIL_SPECIES = "OMANYTE"
local FOSSIL_ROW = { declined = 2, accepted = 3, noFossil = 6, offer = 7 }
local FOSSIL_SPECIES_VAR = assert(
  FieldScriptSymbols.variablesByName.VAR_UNK_407F,
  "the fossil species variable resolves"
)
local ACTION_FLAG = assert(FieldScriptSymbols.flagsByName.FLAG_ACTION_SET, "the museum action flag resolves")

local VARS = FieldScriptSymbols.variablesByName
local LOAN_VAR = assert(VARS.VAR_LOAN_SPEAROW, "the loan progress variable resolves")
-- ScrCmd_StatJudge writes its three source outputs into these script variables.
local JUDGE_TOTAL_VAR = assert(VARS.VAR_SPECIAL_x8001, "the judge total variable resolves")
local JUDGE_MESSAGE_VAR = assert(VARS.VAR_SPECIAL_x8002, "the judge message variable resolves")
local JUDGE_HIGHEST_VAR = assert(VARS.VAR_SPECIAL_x8003, "the judge highest-value variable resolves")
-- The record the size reader raises and the flag it sets once it accepts a
-- new record.
local SIZE_RECORD_VAR = assert(VARS.VAR_MAGIKARP_SIZE_RECORD, "the size record variable resolves")
local SIZE_RECORD_FLAG = assert(FieldScriptSymbols.flagsByName.FLAG_UNK_139, "the record-accepted flag resolves")
-- The gatehouse script records the missing letter in this saved state.
local LETTER_MISSING_STATE = 6
-- The hand-back script records a completed return in this saved state; its
-- reward branch writes the "returned and rewarded" value when the bag accepts
-- the source item, and the "returned without room" value otherwise.
local RETURNED_STATE = 3

---@param value unknown
---@return unknown
local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  local result = {}
  for key, child in pairs(value) do
    result[key] = copy(child)
  end
  return result
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
---@return table the live NPC trade service
local function tradeService(game)
  return assert(game.runtime.npcTrade, "the field runtime owns its NPC trade service")
end

---@param game table
---@return table the saved mailbox owner
local function mailbox(game)
  return assert(game.runtime.mailbox, "the field runtime owns the canonical mailbox")
end

---@param game table
---@return table the live script world state
local function world(game)
  return assert(game.runtime.scripts and game.runtime.scripts.worldState, "the field owns its world state")
end

---@param game table
---@return integer the saved mon generator's own draw count
local function rngCalls(game)
  return assert(mons(game):capture().rng.calls, "the saved mon generator reports its draw count")
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
---@return string[] every published script fault
local function allFaults(game)
  local list = {}
  for _, record in ipairs(game:recordsNamed("script.error")) do
    local payload = record.payload or {}
    local context = payload.context or {}
    list[#list + 1] = string.format(
      "%s/%s/%s",
      tostring(payload.scriptId),
      tostring(context.command or context.originalName or "unknown"),
      tostring(payload.message)
    )
  end
  return list
end

---@param amount integer
---@return table<string, integer> the six effort values carrying the total
local function effortSpread(amount)
  local spread = { hp = 0, attack = 0, defense = 0, speed = 0, specialAttack = 0, specialDefense = 0 }
  -- The judge and effort reader read the source's own stat order; spread the
  -- total over two stats so the record keeps a legal individual cap.
  spread.hp = math.min(amount, 255)
  spread.attack = amount - spread.hp
  return spread
end

---@param game table
---@param slot0 integer
---@param change fun(mon: table)
local function stageMon(game, slot0, change)
  local service = mons(game)
  local mon = copy(service:partyMon(slot0))
  change(mon)
  -- Staged individual values or effort values change the derived maximum, so
  -- the record keeps its own derived full health.
  mon.condition = { currentHp = service:derive(mon).maxHp, effects = {} }
  local preparation, reason = service:preparePartyChanges(service:partyRevision(), { { slot = slot0, mon = mon } })
  Assert.isNil(reason, "the prepared party change stages cleanly")
  assert(preparation).publish()
end

---@param withDate table
---@return table a recording clock host boundary
local function clockAt(withDate)
  return LocalClock.new(function()
    return copy(withDate)
  end)
end

local ORDINARY_DATE = { year = 2000, month = 1, day = 5, hour = 12, minute = 0, second = 0 }

---@class FieldPlace
---@field map string map symbol
---@field tile { fieldX: integer, fieldZ: integer } the global tile the player talks from
---@field facing string the direction the object stands in
---@field origin { x: integer, z: integer }? the map's compiled world origin

---@class FieldBoot
---@field place FieldPlace
---@field mons table?
---@field worldState table?

---@param options FieldBoot
---@return table acceptance game standing on a fresh finalized field
local function bootField(options)
  local place = options.place
  local origin = place.origin or { x = 0, z = 0 }
  local harness = AcceptanceHarness.new({
    gameFactory = function(versionId, _)
      return FinalizedGameFixture.build(versionId, {
        location = {
          mapSymbol = place.map,
          fieldX = place.tile.fieldX - origin.x,
          fieldZ = place.tile.fieldZ - origin.z,
          facing = place.facing,
        },
        mons = options.mons,
        worldState = options.worldState,
      })
    end,
  })
  local game = harness:boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = options.place.map,
    save = "fresh",
    fieldOptions = { recordingScriptHosts = true, audioHost = "recording", localClock = clockAt(ORDINARY_DATE) },
  })
  game:waitForFieldEntry()
  -- Headless composition binds the explicit no-image preparation: the party
  -- picker reports ready without realizing GPU icons it never draws.
  game.runtime:bindPartyIconPreparation(function()
    return true
  end, function() end)
  return game
end

---@param game table
---@param speciesKeys string[]
---@param level integer
local function giftParty(game, speciesKeys, level)
  for _, species in ipairs(speciesKeys) do
    Assert.isTrue(mons(game):giveMon({ species = species, level = level }), "the party accepts the staged " .. species)
  end
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

-- The picker grid is the generated two-column party layout (slot 0 at the top
-- left, then down the left column, then the right one).
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

-- Answers the script's own question with one source row.
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

---@class ScriptAction
---@field kind "pick"|"cancel_pick"|"choose"
---@field slot integer?
---@field row integer?

---@class ScriptRun
---@field bank integer[] the bank of every printed row, in print order
---@field message integer[] every printed row id, in print order

-- Drives one foreground source script the way a player does: dismiss printed
-- messages, answer its questions, hand every party selection to the next
-- planned action, and stop when the script ends. Any published fault of the
-- running script fails the scenario at the tick it appears.
---@param game table
---@param scriptId string
---@param actions ScriptAction[]
---@param label string
---@return ScriptRun
local function runScript(game, scriptId, actions, label)
  local queue = actions or {}
  local nextAction = 1
  local run = { bank = {}, message = {} }
  local last = nil
  local ended = #game:recordsForScript(scriptId, "script.ended")
  for _ = 1, 8000 do
    local faults = scriptFaults(game, scriptId)
    Assert.equal(
      #faults,
      0,
      "the source script completes every native operation before " .. label .. ": " .. table.concat(faults, ",")
    )
    local snapshot = game:snapshot()
    -- A print-only source row leaves its box open without owning the modal,
    -- so every open row is observed rather than only blocking dialogue.
    local messageId = snapshot.dialogue.messageId
    if messageId ~= nil and messageId ~= last then
      run.message[#run.message + 1] = messageId
      run.bank[#run.bank + 1] = snapshot.dialogue.bankId
    end
    last = messageId
    if
      #game:recordsForScript(scriptId, "script.ended") > ended
      and not snapshot.dialogue.modal
      and not snapshot.fieldLocked
      and game:contextChoiceStatus() == nil
      and pickerStatus(game) == nil
    then
      return run
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

---@param game table
---@param scriptId string
local function talkTo(game, scriptId)
  local before = #game:recordsForScript(scriptId, "script.started")
  game:pressAction()
  local started = {}
  for _, record in ipairs(game:recordsNamed("script.started")) do
    started[#started + 1] = tostring(record.payload and record.payload.scriptId)
  end
  Assert.equal(
    #game:recordsForScript(scriptId, "script.started"),
    before + 1,
    "the object's own source script starts from the interaction (started: "
      .. table.concat(started, ",")
      .. "; player "
      .. tostring(game:snapshot().player.fieldX)
      .. ","
      .. tostring(game:snapshot().player.fieldZ)
      .. " facing "
      .. tostring(game:snapshot().player.facing)
      .. "; faults "
      .. table.concat(allFaults(game), ",")
      .. ")"
  )
end

---@param run ScriptRun
---@param rows integer[]
---@return boolean whether every row was printed in that order
local function printedInOrder(run, rows)
  local position = 1
  for _, messageId in ipairs(run.message) do
    if messageId == rows[position] then
      position = position + 1
      if position > #rows then
        return true
      end
    end
  end
  return false
end

---@param run ScriptRun
---@param row integer
---@return boolean
local function printed(run, row)
  for _, messageId in ipairs(run.message) do
    if messageId == row then
      return true
    end
  end
  return false
end

---@param game table
---@return integer the saved loan progress state
local function loanState(game)
  return world(game):getVar(LOAN_VAR)
end

---@param mon table
---@return table the record with the source letter removed
local function withoutLetter(mon)
  -- The mon owner's own empty-Mail record is the "no letter" value.
  mon.mail = {}
  mon.heldItem = "NONE"
  return mon
end

-- The source letter the NPC trade owner authors for the reference comparison.
-- Authoring it costs the dummy record's own two individual-value draws.
---@param game table
---@return table the detached canonical Kenya letter
local function referenceLetter(game)
  return tradeService(game):createKenyaMail()
end

---@param game table
---@param slot0 integer
---@param letter table
local function storeMailboxLetter(game, slot0, letter)
  local owner = mailbox(game)
  local preparation, reason = owner:prepareChanges(owner:revision(), { { slot = slot0, value = copy(letter) } })
  Assert.isNil(reason, "the canonical mailbox stages the letter")
  assert(preparation).publish()
end

---@param game table
---@param slot0 integer
local function clearMailboxSlot(game, slot0)
  local owner = mailbox(game)
  local preparation, reason = owner:prepareChanges(owner:revision(), { { slot = slot0, value = false } })
  Assert.isNil(reason, "the canonical mailbox stages the cleared slot")
  assert(preparation).publish()
end

-- The Route 31 deliverer hands Kenya back only when the selected record holds
-- the authored letter: the lax check answers for any Mail without authoring a
-- reference, the exact check authors the reference letter (its two draws) and
-- compares the full identity, and only then does the source return the record.
function T.tests.the_route_31_deliverer_takes_back_the_authored_letter()
  local game = bootField({ place = ROUTE_31 })
  local ok, err = xpcall(function()
    giftParty(game, { "PIDGEY" }, 20)
    local service = tradeService(game)
    Assert.notNil(
      service:giveLoan({ tradeId = KENYA_TRADE_ID, level = KENYA_LEVEL, mapId = KENYA_MAP_ID }),
      "the scenario lends the source Kenya record"
    )
    local slot = mons(game):partyCount() - 1
    Assert.equal(mons(game):partyMon(slot).species, "SPEAROW", "the loan lands in the party")
    game:setWorldState({ variable = LOAN_VAR, value = 1 })
    local drawsBefore = rngCalls(game)

    talkTo(game, KENYA_RETURN_SCRIPT)
    local run = runScript(game, KENYA_RETURN_SCRIPT, { { kind = "pick", slot = slot } }, "the returned record")
    Assert.isTrue(
      printedInOrder(run, { KENYA_ROW.intro, KENYA_ROW.returned, KENYA_ROW.reward, KENYA_ROW.farewell }),
      "the source hand-back prints its own rows in order: " .. table.concat(run.message, ",")
    )
    Assert.equal(
      rngCalls(game) - drawsBefore,
      2,
      "the exact check authors one reference letter and pays its two draws"
    )
    Assert.equal(mons(game):partyCount(), 1, "the hand-back removes the loaned record")
    Assert.isTrue(mons(game):partyMon(0).species ~= "SPEAROW", "the loaned record left the party")
    Assert.equal(
      loanState(game),
      RETURNED_STATE,
      "the script records its completed return (state " .. tostring(loanState(game)) .. ")"
    )
    local settled = settledCapture(game, "the returned loan")
    Assert.equal(#allFaults(game), 0, "the hand-back journey publishes no unrelated script fault")
    Assert.equal(settled.world.variables[LOAN_VAR], RETURNED_STATE, "the settled save keeps the returned state")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

-- Any Mail satisfies the lax check but never the exact one: the source authors
-- its reference letter for the comparison (paying its two draws), finds the
-- selected letter different and ends without returning the record.
function T.tests.the_route_31_deliverer_rejects_a_letter_that_is_not_the_authored_one()
  local game = bootField({ place = ROUTE_31 })
  local ok, err = xpcall(function()
    giftParty(game, { "PIDGEY" }, 20)
    local letter = referenceLetter(game)
    letter.author.trainerId = (letter.author.trainerId + 1) % 256
    stageMon(game, 0, function(mon)
      mon.heldItem = KENYA_MAIL_ITEM
      mon.mail = copy(letter)
    end)
    game:setWorldState({ variable = LOAN_VAR, value = 1 })
    local drawsBefore = rngCalls(game)

    talkTo(game, KENYA_RETURN_SCRIPT)
    local run = runScript(game, KENYA_RETURN_SCRIPT, { { kind = "pick", slot = 0 } }, "the unrelated letter")
    Assert.isTrue(printed(run, KENYA_ROW.wrongLetter), "the exact check refuses the unrelated letter")
    Assert.isFalse(printed(run, KENYA_ROW.noMail), "the unrelated letter still satisfied the lax check")
    Assert.equal(
      rngCalls(game) - drawsBefore,
      2,
      "the exact check still authors its reference letter and pays its two draws"
    )
    Assert.equal(mons(game):partyCount(), 1, "the refused letter returns nothing")
    Assert.equal(mons(game):partyMon(0).species, "PIDGEY", "the refused record stays in the party")
    Assert.equal(loanState(game), 1, "a refused hand-back keeps the loan progress state")
    Assert.equal(#allFaults(game), 0, "the refused hand-back publishes no unrelated script fault")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

-- A record holding no Mail stops at the lax check, so the source never authors
-- its reference letter: the script answers its own "no Mail" row and the mon
-- generator draws nothing.
function T.tests.the_route_31_deliverer_leaves_a_mail_less_record_alone()
  local game = bootField({ place = ROUTE_31 })
  local ok, err = xpcall(function()
    giftParty(game, { "PIDGEY" }, 20)
    game:setWorldState({ variable = LOAN_VAR, value = 1 })
    local drawsBefore = rngCalls(game)

    talkTo(game, KENYA_RETURN_SCRIPT)
    local run = runScript(game, KENYA_RETURN_SCRIPT, { { kind = "pick", slot = 0 } }, "the Mail-less record")
    Assert.isTrue(printed(run, KENYA_ROW.noMail), "the lax check answers for a record with no Mail")
    Assert.equal(rngCalls(game) - drawsBefore, 0, "no Mail authors no reference letter")
    Assert.equal(loanState(game), 1, "the Mail-less record leaves the loan progress state alone")
    Assert.equal(#allFaults(game), 0, "the Mail-less journey publishes no script fault")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

-- The Route 35 gatehouse script scans the held letter and then the twenty
-- saved mailbox slots for the authored letter, not for the carrier: a mailbox
-- letter answers for a party that holds none, a party letter answers for an
-- empty mailbox, and neither the loaned Spearow nor any other record satisfies
-- the scan once the letter itself is gone.
function T.tests.the_gatehouse_letter_scan_follows_the_letter_into_the_mailbox()
  local worldState = FieldEventState.new()
  worldState:setVar(LOAN_VAR, 1)
  local game = bootField({ place = GATEHOUSE, worldState = worldState })
  local ok, err = xpcall(function()
    local letter = referenceLetter(game)
    storeMailboxLetter(game, 0, letter)

    local drawsBefore = rngCalls(game)
    talkTo(game, GATEHOUSE_SCAN_SCRIPT)
    local found = runScript(game, GATEHOUSE_SCAN_SCRIPT, {}, "the mailbox letter")
    Assert.isTrue(
      printed(found, GATEHOUSE_ROW.letterFound),
      "the mailbox letter answers the scan: " .. table.concat(found.message, ",")
    )
    Assert.equal(
      rngCalls(game) - drawsBefore,
      2,
      "the scan authors one reference letter and pays its two draws"
    )
    Assert.equal(loanState(game), 1, "a found letter keeps the loan progress state")

    clearMailboxSlot(game, 0)
    drawsBefore = rngCalls(game)
    game:waitForFieldReady()
    talkTo(game, GATEHOUSE_SCAN_SCRIPT)
    local missing = runScript(game, GATEHOUSE_SCAN_SCRIPT, {}, "the missing letter")
    Assert.isTrue(
      printed(missing, GATEHOUSE_ROW.letterMissing),
      "an empty mailbox leaves the scan without its letter: " .. table.concat(missing.message, ",")
    )
    Assert.equal(rngCalls(game) - drawsBefore, 2, "every scan authors its own reference letter")
    Assert.equal(loanState(game), LETTER_MISSING_STATE, "the script records the missing letter")
    Assert.equal(#allFaults(game), 0, "the gatehouse journey publishes no unrelated script fault")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

-- The scan answers for a letter held by any party record, and stops answering
-- for the loaned Spearow itself once its letter is gone.
function T.tests.the_gatehouse_letter_scan_reads_the_letter_and_not_the_carrier()
  local worldState = FieldEventState.new()
  worldState:setVar(LOAN_VAR, 1)
  local holder = bootField({ place = GATEHOUSE, worldState = worldState })
  local ok, err = xpcall(function()
    giftParty(holder, { "PIDGEY" }, 20)
    local letter = referenceLetter(holder)
    stageMon(holder, 0, function(mon)
      mon.heldItem = KENYA_MAIL_ITEM
      mon.mail = copy(letter)
    end)
    local drawsBefore = rngCalls(holder)
    talkTo(holder, GATEHOUSE_SCAN_SCRIPT)
    local found = runScript(holder, GATEHOUSE_SCAN_SCRIPT, {}, "the party letter")
    Assert.isTrue(
      printed(found, GATEHOUSE_ROW.letterFound),
      "a party letter answers the scan: " .. table.concat(found.message, ",")
    )
    Assert.equal(rngCalls(holder) - drawsBefore, 2, "the party scan authors one reference letter")
    Assert.equal(loanState(holder), 1, "a found party letter keeps the loan progress state")
  end, debug.traceback)
  holder:close()
  if not ok then
    error(err, 0)
  end

  local carrierState = FieldEventState.new()
  carrierState:setVar(LOAN_VAR, 1)
  local carrier = bootField({ place = GATEHOUSE, worldState = carrierState })
  local okCarrier, errCarrier = xpcall(function()
    local service = tradeService(carrier)
    Assert.notNil(
      service:giveLoan({ tradeId = KENYA_TRADE_ID, level = KENYA_LEVEL, mapId = KENYA_MAP_ID }),
      "the scenario lends the source Kenya record"
    )
    local slot = mons(carrier):partyCount() - 1
    Assert.equal(mons(carrier):partyMon(slot).species, "SPEAROW", "the loaned carrier holds the party slot")
    stageMon(carrier, slot, withoutLetter)
    local drawsBefore = rngCalls(carrier)
    talkTo(carrier, GATEHOUSE_SCAN_SCRIPT)
    local missing = runScript(carrier, GATEHOUSE_SCAN_SCRIPT, {}, "the letterless carrier")
    Assert.isTrue(
      printed(missing, GATEHOUSE_ROW.letterMissing),
      "the loaned carrier without its letter does not answer the scan: " .. table.concat(missing.message, ",")
    )
    Assert.equal(
      rngCalls(carrier) - drawsBefore,
      2,
      "the letterless carrier still pays the scan's own reference letter"
    )
    Assert.equal(loanState(carrier), LETTER_MISSING_STATE, "the scan records the carrier's missing letter")
    Assert.equal(#allFaults(carrier), 0, "the letterless carrier journey publishes no script fault")
  end, debug.traceback)
  carrier:close()
  if not okCarrier then
    error(errCarrier, 0)
  end
end

-- The Battle Tower judge reports the source rows for the total, the best stat
-- and the highest individual value, and rotates its volatile cursor through
-- tied best stats: two consecutive readings of one tied record name different
-- stats, and a field restored from the captured save starts over at the first
-- tied stat instead of continuing the rotation.
function T.tests.the_battle_tower_judge_rotates_its_tied_best_stat()
  local game = bootField({ place = BATTLE_TOWER })
  local ok, err = xpcall(function()
    giftParty(game, { "PIDGEY" }, 30)
    -- Two tied best individual values: the source cursor decides which of the
    -- two the judge names first, then advances past it.
    stageMon(game, 0, function(mon)
      mon.ivs = { hp = 31, attack = 31, defense = 0, speed = 0, specialAttack = 0, specialDefense = 0 }
    end)
    local drawsBefore = rngCalls(game)

    talkTo(game, JUDGE_SCRIPT)
    local first = runScript(game, JUDGE_SCRIPT, { { kind = "pick", slot = 0 } }, "the first judge reading")
    Assert.isTrue(printed(first, JUDGE_ROW.decentTotal), "the judge reports its total row")
    Assert.isTrue(printed(first, JUDGE_ROW.bestPotential), "the judge reports its highest-value row")
    Assert.equal(world(game):getVar(JUDGE_TOTAL_VAR), 62, "the judge sums the six individual values")
    Assert.equal(world(game):getVar(JUDGE_HIGHEST_VAR), 31, "the judge reports the highest individual value")
    Assert.equal(
      world(game):getVar(JUDGE_MESSAGE_VAR),
      JUDGE_ROW.bestHp,
      "the first reading names the tied HP row"
    )
    Assert.equal(rngCalls(game) - drawsBefore, 0, "the judge never draws from the mon generator")

    game:waitForFieldReady()
    talkTo(game, JUDGE_SCRIPT)
    local second = runScript(game, JUDGE_SCRIPT, { { kind = "pick", slot = 0 } }, "the second judge reading")
    Assert.equal(
      world(game):getVar(JUDGE_MESSAGE_VAR),
      JUDGE_ROW.bestAttack,
      "the rotating cursor names the other tied stat next"
    )
    Assert.isTrue(printed(second, JUDGE_ROW.bestPotential), "the second reading keeps its highest-value row")

    -- The cursor is field-volatile: a save captured here and booted again
    -- answers from the first tied stat, proving no cursor reaches the save.
    settledCapture(game, "the judged party")
    game:restart({ map = BATTLE_TOWER.map })
    game:waitForFieldEntry()
    game.runtime:bindPartyIconPreparation(function()
      return true
    end, function() end)
    talkTo(game, JUDGE_SCRIPT)
    local restored = runScript(game, JUDGE_SCRIPT, { { kind = "pick", slot = 0 } }, "the restored judge reading")
    Assert.equal(
      world(game):getVar(JUDGE_MESSAGE_VAR),
      JUDGE_ROW.bestHp,
      "a restored field starts the rotation over at the first tied stat"
    )
    Assert.isTrue(printed(restored, JUDGE_ROW.bestPotential), "the restored reading keeps its highest-value row")
    Assert.equal(rngCalls(game), drawsBefore, "no judge reading ever draws from the mon generator")
    Assert.equal(#allFaults(game), 0, "the judge journey publishes no script fault")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

-- The Celadon Prize Corner reader answers its own prompt rows: cancelling
-- stops before any query, an Egg record takes the script's own branch instead
-- of a type query, and the species the source refuses ends in the sentinel row
-- without the reader ever drawing from the mon generator. A species the source
-- accepts reaches the type query: the answer is written as the script's
-- comparison value and the reader names that type through its own type-name
-- row.
function T.tests.the_prize_corner_reader_refuses_the_source_species()
  local game = bootField({ place = PRIZE_CORNER })
  local ok, err = xpcall(function()
    giftParty(game, { "BURMY" }, 20)
    local drawsBefore = rngCalls(game)

    talkTo(game, HIDDEN_POWER_SCRIPT)
    local cancelled = runScript(game, HIDDEN_POWER_SCRIPT, {
      { kind = "choose", row = 1 },
    }, "the cancelled reading")
    Assert.isTrue(printed(cancelled, HIDDEN_POWER_ROW.cancel), "the cancelled prompt answers its own row")
    Assert.equal(rngCalls(game), drawsBefore, "a cancelled reading never draws")

    game:waitForFieldReady()
    talkTo(game, HIDDEN_POWER_SCRIPT)
    local refused = runScript(game, HIDDEN_POWER_SCRIPT, {
      { kind = "choose", row = 0 },
      { kind = "pick", slot = 0 },
    }, "the refused species")
    Assert.isTrue(
      printedInOrder(refused, { HIDDEN_POWER_ROW.refused }),
      "the refused species answers the sentinel row: " .. table.concat(refused.message, ",")
    )
    Assert.equal(rngCalls(game), drawsBefore, "the type query never draws from the mon generator")
    Assert.equal(#allFaults(game), 0, "the reader journey publishes no script fault")
    Assert.equal(game:renderAttempts(), 0, "the reader journey stops before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end

  local accepted = bootField({ place = PRIZE_CORNER })
  local okAccepted, errAccepted = xpcall(function()
    giftParty(accepted, { "PIDGEY" }, 20)
    local service = mons(accepted)
    local knowsHiddenPower = service:monHasMove(0, service:catalog():moveKeyByNativeId(HIDDEN_POWER_MOVE))
    local drawsBefore = rngCalls(accepted)

    talkTo(accepted, HIDDEN_POWER_SCRIPT)
    local reading = runScript(accepted, HIDDEN_POWER_SCRIPT, {
      { kind = "choose", row = 0 },
      { kind = "pick", slot = 0 },
    }, "the accepted species")
    local expectedRow = knowsHiddenPower and HIDDEN_POWER_ROW.currentType or HIDDEN_POWER_ROW.learnedType
    Assert.isTrue(
      printed(reading, expectedRow),
      "the accepted species names its type through the reader's own row: " .. table.concat(reading.message, ",")
    )
    Assert.isFalse(printed(reading, HIDDEN_POWER_ROW.refused), "the accepted species never reaches the refusal row")
    Assert.equal(rngCalls(accepted), drawsBefore, "the accepted reading never draws from the mon generator")
    Assert.equal(#allFaults(accepted), 0, "the accepted reading publishes no script fault")
    Assert.equal(accepted:renderAttempts(), 0, "the accepted reading stops before GPU rendering")
  end, debug.traceback)
  accepted:close()
  if not okAccepted then
    error(errAccepted, 0)
  end
end

-- The Blackthorn east-house reader sums the lead record's six effort values
-- through the source command, refuses the total below the source threshold,
-- awards the effort ribbon exactly once for the qualifying total while every
-- other stored ribbon bit survives, and answers with its own row once the
-- record already carries the ribbon.
function T.tests.the_blackthorn_reader_awards_the_effort_ribbon_once()
  local game = bootField({ place = BLACKTHORN })
  local ok, err = xpcall(function()
    giftParty(game, { "PIDGEY" }, 20)
    -- One unrelated ribbon bit proves the award preserves the other bits.
    stageMon(game, 0, function(mon)
      mon.ribbons = { gba = 1, ds1 = 0, ds2 = 0 }
      mon.evs = effortSpread(EFFORT_NEAR_MISS)
    end)
    local drawsBefore = rngCalls(game)

    talkTo(game, EFFORT_RIBBON_SCRIPT)
    local nearMiss = runScript(game, EFFORT_RIBBON_SCRIPT, {}, "the below-threshold total")
    Assert.isTrue(
      printed(nearMiss, EFFORT_ROW.nearMiss),
      "the source total row answers below the threshold: " .. table.concat(nearMiss.message, ",")
    )
    Assert.equal(mons(game):partyMon(0).ribbons.gba, 1, "the refused total awards no ribbon")

    game:waitForFieldReady()
    stageMon(game, 0, function(mon)
      mon.evs = effortSpread(EFFORT_THRESHOLD)
    end)
    talkTo(game, EFFORT_RIBBON_SCRIPT)
    local awarded = runScript(game, EFFORT_RIBBON_SCRIPT, {}, "the qualifying total")
    Assert.isTrue(
      printedInOrder(awarded, { EFFORT_ROW.enough, EFFORT_ROW.awarded, EFFORT_ROW.farewell }),
      "the qualifying total awards the source ribbon: " .. table.concat(awarded.message, ",")
    )
    local awardedRibbons = mons(game):partyMon(0).ribbons
    Assert.equal(
      awardedRibbons[EFFORT_RIBBON_GROUP],
      1 + 2 ^ EFFORT_RIBBON_BIT,
      "the source ribbon bit lands beside the other stored bits (awarded: "
        .. tostring(awardedRibbons[EFFORT_RIBBON_GROUP])
        .. ", ds1 "
        .. tostring(awardedRibbons.ds1)
        .. ", ds2 "
        .. tostring(awardedRibbons.ds2)
        .. "; rows "
        .. table.concat(awarded.message, ",")
        .. ")"
    )
    Assert.equal(awardedRibbons.ds1, 0, "the award leaves the ds1 ribbon word alone")
    Assert.equal(awardedRibbons.ds2, 0, "the award leaves the ds2 ribbon word alone")

    game:waitForFieldReady()
    talkTo(game, EFFORT_RIBBON_SCRIPT)
    local repeated = runScript(game, EFFORT_RIBBON_SCRIPT, {}, "the already-awarded record")
    Assert.isTrue(
      printed(repeated, EFFORT_ROW.alreadyHas),
      "an already-awarded record answers its own row: " .. table.concat(repeated.message, ",")
    )
    Assert.equal(
      mons(game):partyMon(0).ribbons.gba,
      1 + 2 ^ EFFORT_RIBBON_BIT,
      "a repeated award changes nothing"
    )
    Assert.equal(rngCalls(game) - drawsBefore, 0, "the ribbon reader never draws from the mon generator")
    Assert.equal(#allFaults(game), 0, "the ribbon journey publishes no script fault")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

-- The Pewter Museum fossil reader counts the fossils the bag holds, offers the
-- one it can revive, and exchanges exactly that fossil only when the offer is
-- accepted: an empty bag, a declined offer and an accepted offer each answer
-- their own source row, and only the accepted offer takes the item and leaves
-- the species the next visit revives.
function T.tests.the_pewter_museum_reader_exchanges_only_the_fossil_it_accepts()
  local game = bootField({ place = PEWTER_MUSEUM })
  local ok, err = xpcall(function()
    local bag = assert(game.runtime.bagService, "the field runtime owns the live bag service")
    local drawsBefore = rngCalls(game)

    talkTo(game, FOSSIL_SCRIPT)
    local empty = runScript(game, FOSSIL_SCRIPT, {}, "the empty bag")
    Assert.isTrue(
      printed(empty, FOSSIL_ROW.noFossil),
      "an empty bag answers the reader's own refusal row: " .. table.concat(empty.message, ",")
    )
    Assert.equal(bag:quantity(FOSSIL_ITEM), 0, "the refusal takes nothing from the bag")

    game:waitForFieldReady()
    Assert.isTrue(bag:add(FOSSIL_ITEM, 1), "the journey stocks the source fossil")
    local revision = bag:revision()
    talkTo(game, FOSSIL_SCRIPT)
    local declined = runScript(game, FOSSIL_SCRIPT, { { kind = "choose", row = 1 } }, "the declined offer")
    Assert.isTrue(printed(declined, FOSSIL_ROW.offer), "the reader offers the fossil it found")
    Assert.isTrue(
      printedInOrder(declined, { FOSSIL_ROW.offer, FOSSIL_ROW.declined }),
      "a declined offer answers the reader's own row: " .. table.concat(declined.message, ",")
    )
    Assert.equal(bag:quantity(FOSSIL_ITEM), 1, "a declined offer keeps the fossil")
    Assert.equal(bag:revision(), revision, "a declined offer leaves the bag revision alone")
    Assert.equal(world(game):getVar(FOSSIL_SPECIES_VAR), 0, "a declined offer names no species")

    game:waitForFieldReady()
    talkTo(game, FOSSIL_SCRIPT)
    local accepted = runScript(game, FOSSIL_SCRIPT, { { kind = "choose", row = 0 } }, "the accepted offer")
    Assert.isTrue(printed(accepted, FOSSIL_ROW.offer), "the accepted offer prints the fossil it found")
    Assert.isTrue(
      printed(accepted, FOSSIL_ROW.accepted),
      "an accepted offer answers the reader's own row: " .. table.concat(accepted.message, ",")
    )
    Assert.equal(bag:quantity(FOSSIL_ITEM), 0, "the accepted offer takes exactly one fossil")
    local speciesId = world(game):getVar(FOSSIL_SPECIES_VAR)
    Assert.isTrue(speciesId ~= 0, "the accepted offer leaves the species to revive")
    Assert.equal(
      mons(game):catalog():speciesKeyByNativeId(speciesId),
      FOSSIL_SPECIES,
      "the Helix Fossil names the species it revives into"
    )
    Assert.equal(rngCalls(game), drawsBefore, "the reader never draws from the mon generator")
    Assert.equal(#allFaults(game), 0, "the fossil journey publishes no script fault")
    Assert.equal(game:renderAttempts(), 0, "the fossil journey stops before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

-- The Lake of Rage fishing guru measures the party's Magikarp against the
-- saved record through the source's own party-species gate: an outstanding
-- record prints the measured size and the reward row, raises the saved record,
-- sets its flag and hands out its memento exactly once; the next visit finds
-- the record equal, yields a source tick without writing the comparison result
-- (so the script reads the species gate's own answer) and prints its
-- equal-size row; a shorter record then prints the measured size against the
-- saved one.
function T.tests.the_fishing_guru_measures_the_record_magikarp()
  local worldState = FieldEventState.new()
  worldState:setFlag(assert(FieldScriptSymbols.flagsByName.FLAG_ROCKET_HIDEOUT_CLEARED, "the story flag resolves"))
  local game = bootField({ place = FISHING_GURU_HOUSE, worldState = worldState })
  local ok, err = xpcall(function()
    giftParty(game, { "MAGIKARP" }, 20)
    Assert.equal(mons(game):partyMonSpecies(0), MAGIKARP_SPECIES, "the party holds the measured species")
    -- A deterministic individual spread and personality: the source hash then
    -- sizes this record above the empty saved record.
    stageMon(game, 0, function(mon)
      mon.personality = 0x1200
      mon.ivs = { hp = 1, attack = 2, defense = 3, speed = 4, specialAttack = 5, specialDefense = 6 }
    end)
    Assert.equal(world(game):getVar(SIZE_RECORD_VAR), 0, "a fresh field carries no saved size record")
    local prize = assert(mons(game):catalog():itemKeyByNativeId(SIZE_RECORD_PRIZE), "the memento resolves")
    local bag = assert(game.runtime.bagService, "the field runtime owns the live bag service")
    local drawsBefore = rngCalls(game)

    talkTo(game, SIZE_RECORD_SCRIPT)
    local measured = runScript(game, SIZE_RECORD_SCRIPT, { { kind = "pick", slot = 0 } }, "the measured record")
    Assert.isTrue(
      printedInOrder(measured, { SIZE_RECORD_ROW.prompt, SIZE_RECORD_ROW.larger, SIZE_RECORD_ROW.reward }),
      "an outstanding record prints its own rows in order: " .. table.concat(measured.message, ",")
    )
    local record = world(game):getVar(SIZE_RECORD_VAR)
    Assert.equal(record, SIZE_RECORD_HASH, "the reader saves the record's own source hash")
    Assert.isTrue(
      world(game):isFlagSet(SIZE_RECORD_FLAG),
      "the reader records the accepted record"
    )
    Assert.equal(bag:quantity(prize), 1, "the reader hands out its memento once")

    game:waitForFieldReady()
    talkTo(game, SIZE_RECORD_SCRIPT)
    local equal = runScript(game, SIZE_RECORD_SCRIPT, { { kind = "pick", slot = 0 } }, "the equal record")
    Assert.isTrue(
      printedInOrder(equal, { SIZE_RECORD_ROW.prompt, SIZE_RECORD_ROW.equal }),
      "an equal record prints the source's own equal-size row: " .. table.concat(equal.message, ",")
    )
    Assert.equal(world(game):getVar(SIZE_RECORD_VAR), record, "an equal record leaves the saved record alone")
    Assert.equal(bag:quantity(prize), 1, "an equal record hands out no second memento")

    game:waitForFieldReady()
    stageMon(game, 0, function(mon)
      mon.personality = 0
      mon.ivs = { hp = 0, attack = 0, defense = 0, speed = 0, specialAttack = 0, specialDefense = 0 }
    end)
    talkTo(game, SIZE_RECORD_SCRIPT)
    local smaller = runScript(game, SIZE_RECORD_SCRIPT, { { kind = "pick", slot = 0 } }, "the shorter record")
    Assert.isTrue(
      printedInOrder(smaller, { SIZE_RECORD_ROW.prompt, SIZE_RECORD_ROW.smaller }),
      "a shorter record prints the saved size beside its own: " .. table.concat(smaller.message, ",")
    )
    Assert.equal(world(game):getVar(SIZE_RECORD_VAR), record, "a shorter record never lowers the saved record")
    Assert.equal(bag:quantity(prize), 1, "a shorter record hands out no memento")
    Assert.equal(rngCalls(game) - drawsBefore, 0, "the size reader never draws from the mon generator")
    Assert.equal(#allFaults(game), 0, "the size record journey publishes no script fault")
    Assert.equal(game:renderAttempts(), 0, "the size record journey stops before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

return T
