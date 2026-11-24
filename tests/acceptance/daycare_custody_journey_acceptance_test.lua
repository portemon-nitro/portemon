-- The Route 34 Day Care through the production field: the lady's own script
-- takes two parents out of the party, the capsule confirmation keeps and then
-- clears a ball capsule, the party picker offers the source Store/Summary/Quit
-- rows (Summary/Quit for an Egg), the saved step counters follow committed
-- walks only, the withdrawn parents come back with derived full health and
-- their authored Mail, and the source price and crossed-level moves follow the
-- stored experience. Only audio, fade and the wall clock are recording
-- boundaries; maps, scripts, actors, the save store and every owning domain
-- stay production-owned, and the render trap stays active throughout.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local Experience = require("libs.mons.src.gen4.Experience")
local PcCache = require("libs.assets.src.PcCache")

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
    tags = { "field", "script", "daycare", "save" },
  },
  tests = {},
}

local DAYCARE_MAP = "MAP_ROUTE_34_DAYCARE"
-- The map's Day-Care Lady object runs the standard day-care script (std 9501),
-- which the generated catalog registers and composes under its public id.
local DAYCARE_SCRIPT = "common.daycare_lady"
-- The lady stands at (3,5) behind the counter row at z=6, so the player
-- answers her across it from the open floor tile directly south of the
-- counter, where ordinary walking works.
local COUNTER_TILE = { fieldX = 3, fieldZ = 7 }
-- The two reserved yard object slots rescript 715 replaces (daycare.c
-- ScrCmd_UpdateDaycareMonObjects: x = 8, y = 5 then x = 10, y = 9).
local YARD_SLOTS = { { fieldX = 8, fieldZ = 5 }, { fieldX = 10, fieldZ = 9 } }
local BUCKET_SCHEMA = "hgss-daycare-v1"
local STEP_BUDGET = 60
local OPPOSITE = { north = "south", south = "north", east = "west", west = "east" }

---@param options table
---@return AcceptanceHarness
local function harnessAt(options)
  local harness = AcceptanceHarness.new()
  local createGame = harness.gameFactory
  harness.gameFactory = function(versionId, map)
    local game = createGame(versionId, map)
    game.location = {
      mapSymbol = DAYCARE_MAP,
      fieldX = COUNTER_TILE.fieldX,
      fieldZ = COUNTER_TILE.fieldZ,
      facing = "north",
    }
    game.playerData.profile.money = options.money or 3000
    return game
  end
  return harness
end

---@param game table
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

---@return table game
local function boot()
  local game = harnessAt({ money = 3000 }):boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = DAYCARE_MAP,
    save = "fresh",
    fieldOptions = { recordingScriptHosts = true, audioHost = "recording" },
  })
  for _ = 1, 480 do
    if game.runtime.session.mapEntryStage == nil then
      break
    end
    game:step()
  end
  Assert.isNil(
    game.runtime.session.mapEntryStage,
    "the day care map finishes its entry scripts: " .. table.concat(allScriptFaults(game), ",")
  )
  -- Headless composition binds the explicit no-image preparation: the party
  -- picker reports ready without realizing GPU icons it never draws.
  game.runtime:bindPartyIconPreparation(function()
    return true
  end, function() end)
  return game
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
---@return integer how many times the lady's script has ended so far
local function scriptEndCount(game)
  return #game:recordsForScript(DAYCARE_SCRIPT, "script.ended")
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

-- The picker grid is the generated two-column party layout (slot 0 at the
-- top left, then down the left column, then the right one), so navigation
-- walks rows first and then columns to the requested slot.
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
  -- The opening reveal and its settling ticks discard input, so the confirm
  -- edge is retried like the cancellation edge below until it lands.
  for _ = 1, 8 do
    waitPickerInteractive(game, "the care menu")
    pressAction(game)
    for _ = 1, 40 do
      local status = assert(pickerStatus(game), "the party selection stays open while its care menu opens")
      if status.menu ~= nil then
        return status.menu
      end
      if status.prompt ~= nil then
        error("the party selection asked a confirmation before any care action", 0)
      end
      game:step()
    end
  end
  error("the party selection never opened a care menu", 0)
end

---@param game table
---@param index integer one-based source menu row
local function chooseMenuRow(game, index)
  for _ = 1, 24 do
    local status = assert(pickerStatus(game), "the party selection stays open while choosing a care action")
    Assert.notNil(status.menu, "choosing a care row keeps its menu open")
    if status.menuIndex == index then
      break
    end
    pressDirection(game, (status.menuIndex or 1) < index and "down" or "up")
  end
  pressAction(game)
  -- The source row press rides its visual cadence before the single dispatch:
  -- settle it so the caller observes the menu's answer, not the armed press.
  for _ = 1, 40 do
    local status = pickerStatus(game)
    if status == nil or status.menu == nil or status.menuIndex ~= index or status.menuPress == nil then
      return
    end
    game:step()
  end
end

---@param game table
---@return integer[] the open care menu's source order
local function menuRowKinds(game)
  local status = assert(pickerStatus(game), "the care menu belongs to the open party selection")
  local kinds = {}
  for _, entry in ipairs(assert(status.menu, "the care menu lists its source rows")) do
    kinds[#kinds + 1] = entry.kind
  end
  return kinds
end

---@param game table
---@param choice string "yes" or "no"
local function answerConfirmation(game, choice)
  for _ = 1, 200 do
    local status = assert(pickerStatus(game), "the party selection stays open while its confirmation is answered")
    local prompt = status.prompt
    if prompt ~= nil and prompt.active then
      if prompt.selected == choice then
        pressAction(game)
        -- The prompt publishes its answer after its own confirmation
        -- interval; settle it so the caller observes the answer, not the
        -- latched row.
        for _ = 1, 40 do
          local settled = pickerStatus(game)
          if settled == nil or settled.prompt == nil or settled.prompt.active ~= true then
            return
          end
          game:step()
        end
        return
      end
      pressDirection(game, prompt.selected == "yes" and "down" or "up")
    else
      game:step()
    end
  end
  error("the party selection never confirmed " .. choice, 0)
end

-- Cancels the open selection through production input, retrying the edge
-- while the screen settles its last row.
---@param game table
local function cancelPicker(game)
  for _ = 1, 8 do
    if pickerStatus(game) == nil then
      return
    end
    pressCancel(game)
    for _ = 1, 8 do
      if pickerStatus(game) == nil then
        return
      end
      game:step()
    end
  end
  error("the party selection never cancelled", 0)
end

---@param game table
---@return boolean
local function scriptMenuOpen(game)
  local host = game.runtime.menuHost
  return host ~= nil and host:isModal()
end

-- Drives the lady's own script as a player reading it would: dismiss the
-- messages, answer the source yes/no questions with their default row, and
-- hand every blocking picker or script menu to the next prepared handler.
---@class ScriptRunOptions
---@field noTo table<integer, boolean>? question message ids answered with the source No row
---@field maxTicks integer?

---@param game table
---@param label string the boundary the script must reach
---@param handlers fun(game: table, kind: string)[]
---@param done fun(): boolean
---@param options ScriptRunOptions?
---@return integer[] every dialogue message id the run printed
local function runScript(game, label, handlers, done, options)
  options = options or {}
  local queue = handlers or {}
  local nextHandler = 1
  local printed = {}
  local lastPrinted = nil
  local answeredNo = {}
  for _ = 1, options.maxTicks or 4000 do
    local faults = scriptFaults(game)
    Assert.equal(
      #faults,
      0,
      "the Day-Care Lady's script completes every native operation before " .. label .. ": " .. table.concat(faults, ",")
    )
    if done() then
      return printed
    end
    local kind = pickerStatus(game) ~= nil and "picker" or (scriptMenuOpen(game) and "menu" or nil)
    if kind ~= nil then
      local handler = queue[nextHandler]
      Assert.notNil(handler, "the script opens an unexpected " .. kind .. " before " .. label)
      nextHandler = nextHandler + 1
      handler(game, kind)
    elseif
      game:snapshot().dialogue.modal
      or game:contextChoiceStatus() ~= nil
      or game.runtime.scripts.dialogueHost:yesNoPresentation() ~= nil
    then
      local snapshot = game:snapshot()
      local messageId = snapshot.dialogue.modal and snapshot.dialogue.messageId or nil
      if messageId ~= nil and messageId ~= lastPrinted then
        printed[#printed + 1] = messageId
        lastPrinted = messageId
      end
      local wantsNo = messageId ~= nil and options.noTo ~= nil and options.noTo[messageId] == true
      if wantsNo and not answeredNo[messageId] then
        -- The source No row: advance the message printer to the two-choice
        -- provider, then move its live selection to No and confirm it. The
        -- provider keeps the cursor the player left it on, so the selection is
        -- read instead of assumed, and one message is answered exactly once.
        local presses = 0
        for _ = 1, 480 do
          local choice = game:contextChoiceStatus()
          if choice ~= nil and choice.state == "active" then
            if choice.selected ~= 1 then
              pressDirection(game, "down")
            else
              pressAction(game)
              answeredNo[messageId] = true
              break
            end
          elseif presses < 2 then
            presses = presses + 1
            pressAction(game)
          else
            game:step()
          end
        end
        Assert.isTrue(answeredNo[messageId] == true, "the script's No row answered " .. tostring(messageId))
      else
        pressAction(game)
      end
    else
      game:step()
    end
  end
  local snapshot = game:snapshot()
  error(
    "the Day-Care Lady's script never reached "
      .. label
      .. "; selection="
      .. tostring(pickerStatus(game) ~= nil)
      .. ", menu="
      .. tostring(scriptMenuOpen(game))
      .. ", modal="
      .. tostring(snapshot.dialogue.modal)
      .. ", message="
      .. tostring(snapshot.dialogue.messageId)
      .. ", foreground="
      .. tostring(snapshot.foregroundScript)
      .. ", faults="
      .. table.concat(scriptFaults(game), ","),
    0
  )
end

---@param game table
---@return table the live mon service
local function mons(game)
  return assert(game.runtime.monService, "the field runtime owns its mon service")
end

---@param game table
---@return table the mon catalog behind the live service
local function catalog(game)
  return assert(mons(game):catalog(), "the mon service owns the validated catalog")
end

---@param game table
---@param slot0 integer
---@param change fun(mon: table)
local function stageMon(game, slot0, change)
  local service = mons(game)
  local mon = service:partyMon(slot0)
  change(mon)
  local preparation, reason = service:preparePartyChanges(service:partyRevision(), { { slot = slot0, mon = mon } })
  Assert.isNil(reason, "the prepared party change stages cleanly")
  assert(preparation).publish()
end

---@param game table
---@param label string
---@return table the settled captured game save
local function settledCapture(game, label)
  local lastError = nil
  for _ = 1, 480 do
    local ok, record = pcall(game.runtime.captureGameSave, game.runtime)
    if ok and record ~= nil then
      return record
    end
    lastError = ok and "capture returned no record" or tostring(record)
    game:step()
  end
  error("the settled field never accepted its save: " .. label .. "; last failure: " .. tostring(lastError), 0)
end

---@param capture table the captured game save
---@return table the Day Care bucket
local function daycareBucket(capture)
  local bucket = assert(capture.daycare, "the current save carries the Day Care bucket")
  Assert.equal(bucket.schema, BUCKET_SCHEMA, "the saved Day Care carries its own schema identity")
  return bucket
end

-- Chooses a species and level whose own learnset offers exactly one move on
-- the next level and whose level span fits an indoor walk, so the withdrawal
-- observes a real crossed-level learning chance on a full move set.
---@param game table
---@return table fixture
local function levelUpFixture(game)
  local monCatalog = catalog(game)
  for _, speciesKey in ipairs(monCatalog:speciesKeys()) do
    local species = monCatalog:species(speciesKey)
    local curve = monCatalog:growthCurve(species.growthCurve)
    local form = monCatalog:form(speciesKey, 0)
    for level = 2, 20 do
      local span = Experience.expFor(curve, level + 1) - Experience.expFor(curve, level)
      if span <= STEP_BUDGET and span % 2 == 0 then
        local chances = {}
        for _, entry in ipairs(form.levelUpMoves) do
          if entry.level == level + 1 then
            chances[#chances + 1] = entry.move
          end
        end
        if #chances == 1 then
          return { species = speciesKey, level = level, move = chances[1], curve = curve, span = span }
        end
      end
    end
  end
  error("no species learns exactly one move on the next level within the walk budget", 0)
end

---@param game table
---@param count integer
---@param skip string
---@return string[] move keys
local function spareMoves(game, count, skip)
  local keys = {}
  for _, key in ipairs(catalog(game):moveKeys()) do
    if #keys >= count then
      break
    end
    if key ~= skip and key ~= "NONE" then
      keys[#keys + 1] = key
    end
  end
  Assert.equal(#keys, count, "the catalog offers spare move keys for the prepared move set")
  return keys
end

---@param game table
---@return { key: string, type: integer } the authored stationery
local function authorMail(game)
  local manifest = PcCache.loadManifest(assert(game.runtime.cacheFs, "the field runtime owns its cache"))
  local stationery = assert(manifest.mail.stationery, "the generated PC family carries stationery")
  for stationeryType = 0, 11 do
    local entry = stationery[stationeryType]
    if type(entry) == "table" and type(entry.itemKey) == "string" then
      return { key = entry.itemKey, type = stationeryType }
    end
  end
  error("the generated PC family carries no stationery item", 0)
end

---@param game table
---@param stationery { key: string, type: integer }
---@return table a validated authored Mail record
local function mailRecord(game, stationery)
  local profile = assert(game.runtime.playerData.profile, "the runtime owns the player profile")
  return {
    schema = "g4-mail-v2",
    type = stationery.type,
    author = {
      trainerId = profile.trainerId,
      name = profile.name,
      gender = profile.gender,
      language = 1,
      game = 1,
    },
    icons = { false, false, false },
    lines = { false, false, false },
  }
end

---@param game table
---@return table[] the yard actors the map currently holds, in reserved slot order
local function yardActors(game)
  local snapshot = game:snapshot()
  local found = {}
  for index, slot in ipairs(YARD_SLOTS) do
    local at = nil
    for _, actor in pairs(snapshot.actors) do
      if actor.fieldX == slot.fieldX and actor.fieldZ == slot.fieldZ then
        Assert.isNil(at, "one reserved yard object stands on reserved slot " .. index)
        at = actor
      end
    end
    if at ~= nil then
      found[#found + 1] = at
    end
  end
  return found
end

-- Turns the player without walking: the same facing-only domain operation a
-- script's turn performs, so no committed step is claimed.
---@param game table
---@param direction string
local function faceTile(game, direction)
  if game:snapshot().player.facing ~= direction then
    game:face(direction)
  end
end

---@param game table
---@param direction string
---@return boolean committed whether production movement left the tile
local function tryStep(game, direction)
  if game:snapshot().player.facing ~= direction then
    game:face(direction)
  end
  local before = game:snapshot().player
  game:move(direction)
  local after = game:advanceUntil("movement resolves", function(snapshot)
    return snapshot.player.motion == "idle"
  end, 120)
  return after.player.fieldX ~= before.fieldX or after.player.fieldZ ~= before.fieldZ
end

-- Walks `count` committed steps along one walkable line and back, so every
-- step is a real production movement and the player ends beside the counter.
---@param game table
---@param count integer even number of committed steps
local function walkAndReturn(game, count)
  Assert.isTrue(count % 2 == 0, "a returning walk uses an even number of steps")
  for _, direction in ipairs({ "south", "north", "east", "west" }) do
    if tryStep(game, direction) then
      local opposite = OPPOSITE[direction]
      if not tryStep(game, opposite) then
        error("the day care floor offers no return tile behind " .. direction, 0)
      end
      local walked = 2
      local forward = true
      while walked < count do
        local next = forward and direction or opposite
        if not tryStep(game, next) then
          error("the day care floor stopped offering committed steps after " .. tostring(walked), 0)
        end
        walked = walked + 1
        forward = not forward
      end
      return walked
    end
  end
  error("no direction commits a step from the counter tile", 0)
end

---@param game table
---@return integer, integer the two saved step counters
local function storedSteps(game)
  local bucket = daycareBucket(settledCapture(game, "the saved step counters"))
  return bucket.slots[1].steps, bucket.slots[2].steps
end

---@param game table
---@return integer the slots the party picker offered
local function depositFirstParent(game, withCapsule)
  waitPickerInteractive(game, "the first deposit")
  focusSlot(game, 0)
  openCareMenu(game)
  chooseMenuRow(game, 1)
  if not withCapsule then
    return 1
  end
  answerConfirmation(game, "no")
  Assert.isTrue(pickerStatus(game) ~= nil, "declining the capsule removal returns to the selection")
  focusSlot(game, 0)
  openCareMenu(game)
  chooseMenuRow(game, 1)
  answerConfirmation(game, "yes")
  return 2
end

---@param game table
local function depositSecondParent(game)
  waitPickerInteractive(game, "the second deposit")
  focusSlot(game, 0)
  openCareMenu(game)
  chooseMenuRow(game, 1)
end

---@param game table
local function talkToLady(game)
  game:pressAction()
  Assert.equal(game.lastInteraction.scriptId, DAYCARE_SCRIPT, "the lady owns the interaction the day-care script answers")
end

-- One whole talk: starts the lady's script and drives it until that run ends
-- and the field is quiet again.
---@param game table
---@param label string the boundary the run must reach
---@param handlers fun(game: table, kind: string)[]
---@param options ScriptRunOptions?
---@return integer[] every dialogue message id the run printed
local function talkAndRun(game, label, handlers, options)
  local finished = scriptEndCount(game)
  talkToLady(game)
  return runScript(game, label, handlers, function()
    return scriptEndCount(game) > finished
      and pickerStatus(game) == nil
      and not scriptMenuOpen(game)
      and not game:snapshot().dialogue.modal
  end, options)
end

-- First talk: two parents enter the Day Care, the capsule confirmation
-- returns to the selection on No, and the saved custody carries the source
-- deposit copy.
function T.tests.deposit_journey_keeps_two_parents_and_clears_party_only_state()
  local game = boot()
  local ok, err = xpcall(function()
    local fixture = levelUpFixture(game)
    local stationery = authorMail(game)
    local moves = spareMoves(game, 4, fixture.move)
    mons(game):giveMon({ species = fixture.species, level = fixture.level, form = 0, heldItem = "NONE" })
    for moveSlot0 = 0, 3 do
      mons(game):setMove(0, moveSlot0, moves[moveSlot0 + 1])
    end
    mons(game):giveMon({ species = "SNORLAX", level = 100, form = 0, heldItem = "NONE" })
    mons(game):giveMon({ species = "PIDGEY", level = 5, form = 0, heldItem = "NONE" })
    mons(game):giveMon({ species = "RATTATA", level = 5, form = 0, heldItem = "NONE" })

    stageMon(game, 0, function(mon)
      mon.capsule = { id = 7, seals = { { x = 1, y = 2, graphic = 3 } } }
      mon.condition.currentHp = 1
      mon.condition.effects = { { key = "poison", version = 1, state = {} } }
    end)
    stageMon(game, 1, function(mon)
      mon.heldItem = stationery.key
      mon.mail = mailRecord(game, stationery)
    end)
    local moverMaxHp = mons(game):derive(mons(game):partyMon(0)).maxHp
    local depositedExperience = mons(game):partyMon(0).experience

    talkAndRun(game, "both parents in care", {
      function(active, kind)
        Assert.equal(kind, "picker", "the deposit path opens the source party picker")
        depositFirstParent(active, true)
      end,
      function(active, kind)
        Assert.equal(kind, "picker", "the second deposit opens the source party picker")
        depositSecondParent(active)
      end,
    }, { maxTicks = 4000 })

    local capture = settledCapture(game, "the two deposited parents")
    local bucket = daycareBucket(capture)
    Assert.equal(#bucket.slots, 2, "the Day Care holds two parents")
    Assert.equal(bucket.pendingEggPid, 0, "no egg PID exists before its owner lands")
    Assert.equal(bucket.eggCycleCounter, 0, "no egg cycle counter exists before its owner lands")

    local stored = bucket.slots[1].mon
    local storedKeeper = bucket.slots[2].mon
    Assert.equal(stored.species, fixture.species, "the first stored parent keeps its species")
    Assert.equal(storedKeeper.species, "SNORLAX", "the second stored parent keeps its species")
    Assert.equal(stored.mood, 0, "the deposit resets the stored mood to the source value")
    Assert.equal(bucket.slots[1].steps, 0, "a fresh deposit starts with no stored steps")
    Assert.equal(bucket.slots[2].steps, 0, "a fresh deposit starts with no stored steps")
    Assert.equal(
      stored.condition.currentHp,
      moverMaxHp,
      "the stored parent keeps the boxed-equivalent full health instead of its party wound"
    )
    Assert.equal(#stored.condition.effects, 0, "the stored parent keeps no party status condition")
    Assert.equal(stored.capsule.id, 0, "the capsule confirmation removed the ball capsule")
    Assert.equal(stored.experience, depositedExperience, "the deposit snapshots the stored experience")
    Assert.equal(storedKeeper.heldItem, stationery.key, "the stored parent keeps its authored stationery")
    Assert.equal(storedKeeper.mail.type, stationery.type, "the stored parent keeps its authored Mail")

    local service = mons(game)
    Assert.equal(service:partyCount(), 2, "both deposits left the party")
    local personalities = {}
    for slot0 = 0, service:partyCount() - 1 do
      personalities[service:partyMon(slot0).personality] = true
    end
    Assert.isNil(personalities[stored.personality], "a deposited parent is no longer in the party")
    Assert.isNil(personalities[storedKeeper.personality], "a deposited parent is no longer in the party")
    Assert.equal(capture.gameStats.daycareDeposits, 2, "each deposit counts once in the stored statistics")
    Assert.equal(capture.gameStats.eggsHatched, 0, "a deposit hatches nothing")

    faceTile(game, "south")
    game:advanceUntil("movement resolves", function(snapshot)
      return snapshot.player.motion == "idle"
    end, 60)
    Assert.deepEqual({ storedSteps(game) }, { 0, 0 }, "a turn advances no stored step counter")

    local beforeBump = game:snapshot().player
    faceTile(game, "north")
    game:move("north")
    game:advanceUntil("movement resolves", function(snapshot)
      return snapshot.player.motion == "idle"
    end, 120)
    local afterBump = game:snapshot().player
    Assert.equal(afterBump.fieldX, beforeBump.fieldX, "the counter blocks the north step")
    Assert.equal(afterBump.fieldZ, beforeBump.fieldZ, "the counter blocks the north step")
    Assert.deepEqual({ storedSteps(game) }, { 0, 0 }, "a blocked step advances no stored step counter")

    walkAndReturn(game, 2)
    Assert.deepEqual({ storedSteps(game) }, { 2, 2 }, "each committed step advances both stored counters exactly once")

    -- Re-entering the map runs the room's own on-resume script, which replaces
    -- the two reserved yard actors instead of adding new ones.
    game:restart()
    game:waitForFieldEntry()
    game:advanceUntil("the yard objects settle", function()
      return #yardActors(game) >= 2
    end, 240)
    local actors = yardActors(game)
    Assert.equal(#actors, 2, "the yard holds exactly its two reserved parent objects")
    local restored = daycareBucket(settledCapture(game, "the re-entered map"))
    local monCatalog = catalog(game)
    Assert.equal(
      actors[1].spriteId,
      monCatalog:followerSelection(restored.slots[1].mon),
      "the first yard object uses the deposited parent's generated following visual"
    )
    Assert.equal(
      actors[2].spriteId,
      monCatalog:followerSelection(restored.slots[2].mon),
      "the second yard object uses the deposited parent's generated following visual"
    )
    Assert.deepEqual({ restored.slots[1].steps, restored.slots[2].steps }, { 2, 2 }, "the re-entry keeps the stored steps")
    Assert.equal(game:renderAttempts(), 0, "the deposit journey stops before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

-- Second talk: the source withdrawal price comes out of the script's own money
-- transaction, and the returned parents carry derived full health, their Mail
-- and the exact crossed-level move learning.
function T.tests.withdrawal_journey_pays_the_source_price_and_learns_crossed_moves()
  local game = boot()
  local ok, err = xpcall(function()
    local fixture = levelUpFixture(game)
    local stationery = authorMail(game)
    local moves = spareMoves(game, 4, fixture.move)
    mons(game):giveMon({ species = fixture.species, level = fixture.level, form = 0, heldItem = "NONE" })
    for moveSlot0 = 0, 3 do
      mons(game):setMove(0, moveSlot0, moves[moveSlot0 + 1])
    end
    mons(game):giveMon({ species = "SNORLAX", level = 100, form = 0, heldItem = "NONE" })
    mons(game):giveMon({ species = "PIDGEY", level = 5, form = 0, heldItem = "NONE" })
    mons(game):giveMon({ species = "RATTATA", level = 5, form = 0, heldItem = "NONE" })

    local keptPp = 1
    local keptPpUps = 2
    stageMon(game, 0, function(mon)
      mon.experience = Experience.expFor(fixture.curve, fixture.level + 1) - fixture.span
      mon.condition.currentHp = 1
      mon.condition.effects = { { key = "poison", version = 1, state = {} } }
      mon.moves[2].pp = keptPp
      mon.moves[2].ppUps = keptPpUps
    end)
    stageMon(game, 1, function(mon)
      mon.heldItem = stationery.key
      mon.mail = mailRecord(game, stationery)
    end)
    local moverDeposited = mons(game):partyMon(0).experience
    local keeperMail = mons(game):partyMon(1).mail
    local keeperExperience = mons(game):partyMon(1).experience
    local moneyBefore = assert(game.runtime.playerData.profile.money, "the profile owns its money")

    talkAndRun(game, "both parents in care", {
      function(active, kind)
        Assert.equal(kind, "picker", "the deposit path opens the source party picker")
        depositFirstParent(active, false)
      end,
      function(active, kind)
        Assert.equal(kind, "picker", "the second deposit opens the source party picker")
        depositSecondParent(active)
      end,
    }, { maxTicks = 4000 })
    Assert.equal(#daycareBucket(settledCapture(game, "the deposited parents")).slots, 2, "both parents are in care")

    walkAndReturn(game, fixture.span)
    local walked = settledCapture(game, "the walked parents")
    Assert.equal(daycareBucket(walked).slots[1].steps, fixture.span, "the walked steps belong to the first parent")
    Assert.equal(daycareBucket(walked).slots[2].steps, fixture.span, "the walked steps belong to the second parent")

    local dexBefore = walked.pokedex
    local statsBefore = walked.gameStats
    faceTile(game, "north")

    local withdrewSecond = false
    talkAndRun(game, "the first withdrawal covered by the source goodbye line", {
      function(active, kind)
        Assert.equal(kind, "menu", "the two-parent withdrawal opens the source parent list")
        for _ = 1, 40 do
          if scriptMenuOpen(active) then
            break
          end
          active:step()
        end
        for _ = 1, 4 do
          active:step()
        end
        pressDirection(active, "down")
        pressAction(active)
        withdrewSecond = true
      end,
    }, { maxTicks = 4000, noTo = { [28] = true } })
    Assert.isTrue(withdrewSecond, "the parent list offered the second parent")

    local afterFirst = settledCapture(game, "the first withdrawal")
    local oneLeft = daycareBucket(afterFirst)
    Assert.equal(#oneLeft.slots, 1, "withdrawing the second parent leaves one stored parent")
    Assert.equal(oneLeft.slots[1].mon.species, fixture.species, "the remaining parent compacts into the first slot")
    Assert.equal(oneLeft.slots[1].steps, fixture.span, "the compacted parent keeps its stored steps")

    local service = mons(game)
    local keeper = nil
    for slot0 = 0, service:partyCount() - 1 do
      local mon = service:partyMon(slot0)
      if mon.species == "SNORLAX" then
        keeper = mon
      end
    end
    Assert.notNil(keeper, "the withdrawn second parent returned to the party")
    local keeperCurve = catalog(game):growthCurve(catalog(game):species("SNORLAX").growthCurve)
    Assert.equal(Experience.level(keeperCurve, keeper.experience), 100, "the level-100 parent stays level 100")
    Assert.equal(keeper.experience, keeperExperience, "the level-100 ceiling keeps the stored experience")
    Assert.equal(keeper.heldItem, stationery.key, "the returned parent keeps its authored stationery")
    Assert.equal(keeper.mail.type, keeperMail.type, "the returned parent keeps its authored Mail")
    Assert.equal(
      keeper.condition.currentHp,
      service:derive(keeper).maxHp,
      "the returned parent keeps derived full health"
    )
    Assert.equal(#keeper.condition.effects, 0, "the returned parent carries no status condition")

    local moneyAfterFirst = assert(game.runtime.playerData.profile.money, "the profile owns its money")
    Assert.equal(
      moneyBefore - moneyAfterFirst,
      100,
      "the script charges the source price for a parent that grew no level"
    )

    -- The next talk offers the remaining parent on its own: the script reads
    -- the compacted slot zero, so declining another deposit still returns it.
    faceTile(game, "north")
    talkAndRun(game, "both parents back in the party", {}, { maxTicks = 4000, noTo = { [24] = true } })
    Assert.equal(service:partyCount(), 4, "both parents returned to the party")
    Assert.isNil(daycareBucket(settledCapture(game, "the empty Day Care")).slots[1], "the Day Care is empty")

    local mover = nil
    for slot0 = 0, service:partyCount() - 1 do
      local mon = service:partyMon(slot0)
      if mon.species == fixture.species then
        mover = mon
      end
    end
    Assert.notNil(mover, "the leveling parent returned to the party")
    Assert.equal(
      Experience.level(fixture.curve, mover.experience),
      fixture.level + 1,
      "the stored steps crossed exactly one level"
    )
    Assert.equal(
      mover.experience,
      moverDeposited + fixture.span,
      "the withdrawal adds the stored steps to the experience"
    )
    Assert.equal(
      mover.condition.currentHp,
      service:derive(mover).maxHp,
      "the returned parent keeps derived full health instead of its party wound"
    )
    Assert.equal(#mover.condition.effects, 0, "the returned parent carries no status condition")
    Assert.equal(#mover.moves, 4, "a full move set stays full across the crossed-level learning chance")
    Assert.equal(mover.moves[1].move, moves[2], "the full move set drops its first move")
    Assert.equal(mover.moves[2].move, moves[3], "the retained move keeps its position")
    Assert.equal(mover.moves[3].move, moves[4], "the retained move keeps its position")
    Assert.equal(mover.moves[4].move, fixture.move, "the crossed-level move is appended")
    Assert.equal(mover.moves[1].pp, keptPp, "a retained move keeps its remaining power points")
    Assert.equal(mover.moves[1].ppUps, keptPpUps, "a retained move keeps its power-point ups")
    local learned = catalog(game):move(fixture.move)
    Assert.equal(mover.moves[4].pp, learned.basePp, "the learned move starts at its base power points")
    Assert.equal(mover.moves[4].ppUps, 0, "the learned move starts with no power-point ups")

    local moneyAfter = assert(game.runtime.playerData.profile.money, "the profile owns its money")
    local moverGrowth = Experience.level(fixture.curve, mover.experience) - fixture.level
    Assert.equal(
      moneyBefore - moneyAfter,
      100 + 100 * (moverGrowth + 1),
      "the script charges the source price for both withdrawn parents"
    )

    local final = settledCapture(game, "the withdrawn parents")
    Assert.deepEqual(final.pokedex, dexBefore, "a withdrawal registers no Dex observation")
    Assert.deepEqual(final.gameStats.uniqueCaught, statsBefore.uniqueCaught, "a withdrawal registers no caught species")
    Assert.equal(final.gameStats.uniqueTotal, statsBefore.uniqueTotal, "a withdrawal adds no caught-species score")
    Assert.equal(final.gameStats.score, statsBefore.score, "a withdrawal adds no score")
    Assert.equal(final.gameStats.eggsHatched, statsBefore.eggsHatched, "a withdrawal counts no hatch")
    Assert.equal(final.gameStats.daycareDeposits, statsBefore.daycareDeposits, "a withdrawal is not a new deposit")
    Assert.equal(game:renderAttempts(), 0, "the withdrawal journey stops before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

-- The source refusals: an Egg offers only Summary and Quit, cancelling the
-- selection exits with the source slot 255, and a parent that would leave the
-- player with no battle-ready Pokémon is refused after the capsule
-- confirmation already removed its capsule.
function T.tests.deposit_refuses_eggs_and_the_last_usable_mon()
  local game = boot()
  local ok, err = xpcall(function()
    mons(game):giveMon({ species = "PIDGEY", level = 8, form = 0, heldItem = "NONE" })
    mons(game):giveMon({ species = "RATTATA", level = 5, form = 0, heldItem = "NONE" })
    mons(game):giveMon({ species = "SENTRET", level = 5, form = 0, heldItem = "NONE" })
    Assert.isTrue(
      mons(game):giveEgg({ species = "PICHU", locationOffset = 14 }),
      "the party carries one Egg through the production egg receipt"
    )
    stageMon(game, 0, function(mon)
      mon.capsule = { id = 7, seals = {} }
    end)
    stageMon(game, 1, function(mon)
      mon.condition.currentHp = 0
    end)
    stageMon(game, 2, function(mon)
      mon.condition.currentHp = 0
    end)

    local careRows = nil
    local printed = talkAndRun(game, "the cancelled selection", {
      function(active, kind)
        Assert.equal(kind, "picker", "the deposit path opens the source party picker")
        focusSlot(active, 0)
        openCareMenu(active)
        careRows = menuRowKinds(active)
        Assert.equal(#careRows, 3, "an ordinary parent offers the source Store, Summary and Quit rows")
        pressCancel(active)
        Assert.isTrue(pickerStatus(active) ~= nil, "cancelling the care menu returns to the selection")

        focusSlot(active, 3)
        openCareMenu(active)
        local eggRows = menuRowKinds(active)
        Assert.equal(#eggRows, 2, "an Egg offers only the source Summary and Quit rows")
        Assert.equal(eggRows[1], careRows[2], "an Egg offers the same Summary row an ordinary parent does")
        Assert.equal(eggRows[2], careRows[3], "an Egg offers the same Quit row an ordinary parent does")
        chooseMenuRow(active, 2)
        Assert.isTrue(pickerStatus(active) ~= nil, "quitting the Egg rows returns to the selection")
        cancelPicker(active)
      end,
    }, { maxTicks = 4000 })

    local cancelled = false
    for _, messageId in ipairs(printed) do
      if messageId == 29 then
        cancelled = true
      end
    end
    Assert.isTrue(cancelled, "cancelling the selection exits through the source goodbye line")

    local service = mons(game)
    local empty = settledCapture(game, "the cancelled deposit")
    Assert.isNil(daycareBucket(empty).slots[1], "a cancelled selection deposits nothing")
    Assert.equal(empty.gameStats.daycareDeposits, 0, "a cancelled selection counts no deposit")
    Assert.equal(service:partyCount(), 4, "a cancelled selection keeps the party")
    Assert.equal(service:partyMon(0).capsule.id, 7, "a cancelled selection keeps every capsule")

    -- The last usable parent: the script refuses after the capsule
    -- confirmation already accepted the slot, so the capsule stays removed and
    -- the parent stays in the party.
    faceTile(game, "north")
    printed = talkAndRun(game, "the last usable refusal", {
      function(active, kind)
        Assert.equal(kind, "picker", "the refusal path opens the source party picker")
        focusSlot(active, 0)
        openCareMenu(active)
        chooseMenuRow(active, 1)
        answerConfirmation(active, "yes")
      end,
    }, { maxTicks = 4000 })

    local refused = false
    for _, messageId in ipairs(printed) do
      if messageId == 38 then
        refused = true
      end
    end
    Assert.isTrue(refused, "the script refuses the parent the player would be left with")
    local after = settledCapture(game, "the refused deposit")
    Assert.isNil(daycareBucket(after).slots[1], "the refused parent never enters care")
    Assert.equal(after.gameStats.daycareDeposits, 0, "the refusal counts no deposit")
    Assert.equal(service:partyCount(), 4, "the refused parent stays in the party")
    Assert.equal(service:partyMon(0).capsule.id, 0, "the capsule confirmation removed the capsule before the refusal")
    Assert.equal(game:renderAttempts(), 0, "the refusal journey stops before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

-- The deposit's own form sanitize: a Rotom appliance loses its appliance move
-- through the established form policy, and a Giratina returns its held
-- Griseous Orb to the Bag before it enters care.
function T.tests.deposit_normalizes_altered_forms_and_returns_the_griseous_orb()
  local game = boot()
  local ok, err = xpcall(function()
    mons(game):giveMon({ species = "ROTOM", level = 30, form = 1, heldItem = "NONE" })
    mons(game):giveMon({ species = "GIRATINA", level = 70, form = 1, heldItem = "GRISEOUS_ORB" })
    mons(game):giveMon({ species = "PIDGEY", level = 5, form = 0, heldItem = "NONE" })
    mons(game):giveMon({ species = "RATTATA", level = 5, form = 0, heldItem = "NONE" })
    local appliance = "OVERHEAT"
    mons(game):setMove(0, 0, appliance)
    for index, move in ipairs(spareMoves(game, 3, appliance)) do
      mons(game):setMove(0, index, move)
    end
    Assert.equal(mons(game):countMonMoves(0), 4, "the appliance Rotom carries a full move set")
    Assert.isTrue(mons(game):monHasMove(0, appliance), "the appliance Rotom knows its source appliance move")
    local bag = assert(game.runtime.bagService, "the field runtime owns its bag service")
    local orbsBefore = bag:quantity("GRISEOUS_ORB")

    talkAndRun(game, "both altered parents in care", {
      function(active, kind)
        Assert.equal(kind, "picker", "the deposit path opens the source party picker")
        depositFirstParent(active, false)
      end,
      function(active, kind)
        Assert.equal(kind, "picker", "the second deposit opens the source party picker")
        depositSecondParent(active)
      end,
    }, { maxTicks = 4000 })

    local bucket = daycareBucket(settledCapture(game, "the normalized parents"))
    Assert.equal(#bucket.slots, 2, "both altered parents entered care")
    local storedRotom = bucket.slots[1].mon
    Assert.equal(storedRotom.species, "ROTOM", "the stored parent keeps its species")
    Assert.equal(storedRotom.form, 0, "the deposit normalizes the Rotom to its ordinary form")
    for _, entry in ipairs(storedRotom.moves) do
      Assert.isTrue(entry.move ~= appliance, "the deposit removes the appliance move through the form policy")
    end
    local storedGiratina = bucket.slots[2].mon
    Assert.equal(storedGiratina.species, "GIRATINA", "the stored parent keeps its species")
    Assert.equal(storedGiratina.form, 0, "the deposit normalizes the Giratina to its ordinary form")
    Assert.equal(storedGiratina.heldItem, "NONE", "the deposit removes the held Griseous Orb")
    Assert.equal(
      bag:quantity("GRISEOUS_ORB"),
      orbsBefore + 1,
      "the returned Griseous Orb lands in the Bag before the parent enters care"
    )
    Assert.equal(game:renderAttempts(), 0, "the sanitize journey stops before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

return T
