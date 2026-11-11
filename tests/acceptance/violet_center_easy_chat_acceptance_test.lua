-- Violet Pokemon Center local journeys through the production field: the
-- real Primo interaction checks its two Easy Chat passwords and publishes
-- wallpaper unlocks and one-time gift Eggs through the existing box, party,
-- flag, and save owners, while the real avatar selector resolves its
-- trainer-class text and persists its normalized choice without moving the
-- hero. Every leg boots the real field runtime over real maps, retail
-- scripts, messages, and state owners; only host audio, host input edges,
-- the wall clock, and the save root are recording boundaries. No script is
-- replaced, no network is faked, and no commercial text is asserted here.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local PlayTime = require("libs.hgss.src.save.PlayTime")
local BagSave = require("libs.hgss.src.save.BagSave")
local MonBucket = require("tests.support.MonBucket")
local Drive = require("tests.support.EasyChatScriptDrive")
local Journey = require("tests.support.PokegearJourneyFixture")
local Mon = require("libs.mons.src.Mon")
local PartyScreenModel = require("libs.hgss.src.ui.PartyScreenModel")
local FieldStatePresentationFixture = require("tests.support.FieldStatePresentationFixture")

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = {
      "field-runtime",
      "map-data:158",
      "map:158",
      "message-bank:559",
      "message-bank:191",
      "message-bank:731",
      "message-bank:46",
      "message-bank:40",
      "audio-bank:702",
      "pc:global",
    },
    tags = { "easychat", "violet" },
  },
  tests = {},
}

local CENTER_MAP = "MAP_VIOLET_POKECENTER_1F"
local PRIMO_SCRIPT = "vanilla.hgss.scr_seq.0860.script_004"
local AVATAR_SCRIPT = "vanilla.hgss.scr_seq.0860.script_005"
local NURSE_SCRIPT = "vanilla.hgss.scr_seq.0860.script_000"
local PC_SCRIPT = "common.pokecenter_pc"

local FLAGS = FieldScriptSymbols.flagsByName
local VARS = FieldScriptSymbols.variablesByName

local FLAG_MAREEP = FLAGS.FLAG_GOT_MAREEP_EGG_FROM_PRIMO
local FLAG_WOOPER = FLAGS.FLAG_GOT_WOOPER_EGG_FROM_PRIMO
local FLAG_SLUGMA = FLAGS.FLAG_GOT_SLUGMA_EGG_FROM_PRIMO
local FLAG_AVATAR_SET = FLAGS.FLAG_UNK_2C5
local FLAG_SAVE_BUTTON = FLAGS.FLAG_GOT_SAVE_BUTTON

local VAR_RESULT = VARS.VAR_SPECIAL_RESULT
local VAR_WORD1 = VARS.VAR_SPECIAL_x8000
local VAR_WORD2 = VARS.VAR_SPECIAL_x8001
local VAR_WORD3 = VARS.VAR_SPECIAL_x8002
local VAR_WORD4 = VARS.VAR_SPECIAL_x8003
local VAR_AVATAR_CHOICE = VARS.VAR_SPECIAL_x8004
local VAR_AVATAR_CLASS = VARS.VAR_SPECIAL_x8005

-- Password phrases behind the visible trainer identity below. Each entry
-- carries the two word pairs for the two consecutive prompts. Source word
-- identities, never copied text.
local WALLPAPER_FIRST = { { 1007, 1048 }, { 1050, 1064 } }
local EGG_MAREEP = { { 1150, 1413 }, { 1134, 1152 } }
local EGG_WOOPER = { { 1084, 1320 }, { 1354, 1410 } }
local EGG_SLUGMA = { { 1132, 1308 }, { 1007, 1077 } }

local TRAINER_ID = 12345
local GENDER = 0
local RECEIPT_LOCATION = 2014
local RECEIPT_DATE = { year = 2000, month = 1, day = 1 }

---@param options { gender: integer?, trainerId: integer? }?
---@return AcceptanceHarness
local function harness(options)
  local gender = (options ~= nil and options.gender) or GENDER
  local trainerId = (options ~= nil and options.trainerId) or TRAINER_ID
  return AcceptanceHarness.new({
    gameFactory = function(versionId, map)
      local worldState = FieldEventState.new()
      worldState:setFlag(FLAGS.FLAG_GOT_STARTER)
      return {
        saveId = "save-00000001",
        versionId = versionId,
        location = { mapSymbol = map or CENTER_MAP, fieldX = 8, fieldZ = 13, facing = "north" },
        playerData = {
          profile = {
            name = "GOLD",
            gender = gender,
            trainerId = trainerId,
            money = 3000,
            badges = {},
            nationalDex = false,
            runningShoes = false,
            runningShoesLock = false,
            rivalName = "Silver",
          },
          options = { textSpeed = "fastest", textFrame = 0 },
        },
        fieldTravel = { lastHealSpawn = "SPAWN_VIOLET" },
        fashionCase = require("libs.hgss.src.save.FashionCaseState").empty(),
        playTime = PlayTime.new(),
        worldState = worldState,
        mons = MonBucket.emptyForVersion(versionId),
        bag = BagSave.empty(),
        mart = require("libs.hgss.src.save.MartSave").empty(),
        mailbox = require("libs.hgss.src.save.Mailbox").new():capture(),
        photoAlbum = require("libs.hgss.src.save.PhotoAlbum").new():capture(),
      }
    end,
  })
end

---@param fn fun(game: table)
---@param options { gender: integer?, trainerId: integer? }?
local function withCenter(fn, options)
  local game = harness(options):boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = CENTER_MAP,
    save = "fresh",
    fieldOptions = {
      recordingScriptHosts = true,
      derivedAssets = FieldStatePresentationFixture.iconHost().derivedAssets,
    },
  })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    -- The headless composition never realizes GPU images, so the word
    -- editor commits a ready bundle of stub assets at the field
    -- preparation seam instead of the real image pool. Input, lifecycle,
    -- and results stay production; the binding releases on the way out.
    Drive.requireScriptModules()
    local bootedRuntime = game.runtime
    local binding, _ = Drive.bindHeadlessEditor(bootedRuntime)
    local unbind =
      assert(bootedRuntime.unbindEasyChatPreparation, "the field runtime releases the word editor preparation binding")
    local okInner, errInner = xpcall(function()
      fn(game)
    end, debug.traceback)
    unbind(bootedRuntime, binding)
    if not okInner then
      error(errInner, 0)
    end
    Assert.equal(game:renderAttempts(), 0, "the Violet journey stops before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

---@param game table
---@return table world state
local function world(game)
  return assert(game.runtime.scripts.worldState, "the field owns live world state")
end

---@param game table
---@return table mon service
local function mons(game)
  return assert(game.runtime.monService, "the field owns the live mon service")
end

---@param game table
---@return integer rng draw count
local function rngCalls(game)
  return mons(game):capture().rng.calls
end

---@param game table
---@return boolean[] bonus wallpaper unlocks
local function unlocks(game)
  return mons(game):boxBonusUnlocks()
end

---@param found boolean[]
---@return integer set count
local function countUnlocks(found)
  local count = 0
  for _, bit in ipairs(found) do
    if bit == true then
      count = count + 1
    end
  end
  return count
end

---@param game table
---@param label string
-- Names the first recorded script fault, digging into structured
-- payloads so an unsupported source command names itself.
---@param game table
---@return string? fault description
local function checkFault(game)
  for _, record in ipairs(game:hostEvents().records) do
    if record.name == "script.error" then
      local payload = record.payload or {}
      local message = payload.message
      local context = payload.context
      if type(context) ~= "table" and type(message) == "table" then
        context = message.context or message.fields
        message = message.message
      end
      local detail = tostring(message)
      if type(context) == "table" then
        detail = detail
          .. " scriptId="
          .. tostring(context.scriptId or payload.scriptId)
          .. " command="
          .. tostring(context.command)
          .. " original="
          .. tostring(context.originalName)
          .. " offset="
          .. tostring(context.sourceOffset)
      end
      return tostring(payload.code) .. ":" .. detail
    end
  end
  if game.runtime.errorText then
    return "runtime:" .. tostring(game.runtime.errorText)
  end
  return nil
end

local function assertNoFaults(game, label)
  local count = 0
  for _, record in ipairs(game:hostEvents().records) do
    if record.name == "script.error" then
      count = count + 1
    end
  end
  Assert.equal(count, 0, label .. " runs its retail scripts without faults; first fault=" .. tostring(checkFault(game)))
end

-- Drives production dialogue, contextual choices, script list menus, and
-- foreground scripts back to a free field. Returns whether the field came
-- free. A script menu answers B; anything else answers its default edge.
---@param game table
---@param budget integer?
---@return boolean settled
local function settleToFree(game, budget)
  for _ = 1, budget or 720 do
    if game.runtime.errorText then
      return false
    end
    local snapshot = game:snapshot()
    if game:contextChoiceStatus() ~= nil then
      game.runtime:pressAction()
      game:step()
      game.runtime:releaseAction()
    elseif game.runtime.scripts.dialogueHost:yesNoPresentation() ~= nil then
      game.runtime:pressAction()
      game:step()
      game.runtime:releaseAction()
    elseif snapshot.dialogue.modal then
      game.runtime:pressAction()
      game:step()
      game.runtime:releaseAction()
    else
      local menuTask = nil
      for _, task in ipairs(game.runtime.scripts.scheduler:tasks()) do
        if task.taskType == "menu" then
          menuTask = task
          break
        end
      end
      if menuTask ~= nil then
        game.runtime:pressCancel()
        game:step()
        game.runtime:releaseCancel()
      elseif snapshot.foregroundScript ~= nil or snapshot.fieldLocked then
        game:step()
      else
        return true
      end
    end
  end
  return false
end

---@param game table
---@return table? active script menu task
local function activeMenuTask(game)
  for _, task in ipairs(game.runtime.scripts.scheduler:tasks()) do
    if task.taskType == "menu" then
      return task
    end
  end
  return nil
end

---@param effects string[]
---@param sound string
---@return boolean
local function hasEffect(effects, sound)
  for _, effect in ipairs(effects) do
    if effect == "audio:" .. sound then
      return true
    end
  end
  return false
end

---@param game table
local function pressActionEdge(game)
  game.runtime:pressAction()
  game:step()
  game.runtime:releaseAction()
end

-- Waits for a contextual choice while dismissing lead-in dialogue,
-- failing fast with the script fault when the foreground ends first.
---@param game table
---@param label string
local function waitContextChoice(game, label)
  for _ = 1, 480 do
    if game:contextChoiceStatus() ~= nil then
      return
    end
    local fault = checkFault(game)
    if fault ~= nil then
      error(label .. " never opened its choice; script fault: " .. fault, 0)
    end
    if game:snapshot().dialogue.modal then
      pressActionEdge(game)
    else
      game:step()
    end
  end
  error(label .. " never opened its choice", 0)
end

-- Waits for the avatar source menu while dismissing lead-in dialogue,
-- failing fast with the script fault when the foreground ends first.
---@param game table
---@return table menu task
local function waitAvatarMenu(game)
  for _ = 1, 480 do
    local menu = activeMenuTask(game)
    if menu ~= nil then
      return menu
    end
    local fault = checkFault(game)
    if fault ~= nil then
      error("the avatar selector faulted before its menu opened: " .. fault, 0)
    end
    if game:snapshot().dialogue.modal then
      pressActionEdge(game)
    else
      game:step()
    end
  end
  error("the avatar selector never opens its source menu", 0)
end

-- Selects one source shell entry by its retained value through field
-- input, then dismisses the transitional message the shell prints on
-- the way to its submenu.
---@param game table
---@param value integer
local function selectShellValue(game, value)
  local task = assert(activeMenuTask(game), "the source PC menu is active")
  local targetIndex = nil
  for index, item in ipairs(task.state.menuDefinition.items) do
    if item.value == value then
      targetIndex = index - 1
      break
    end
  end
  Assert.notNil(targetIndex, "the current source PC menu contains the requested value")
  local selectedItem = task.state.menuDefinition.items[targetIndex + 1]
  for _ = 1, #task.state.menuDefinition.items do
    local selectedIndex = task.state.selectedIndex
    if selectedIndex == targetIndex then
      break
    end
    game:step({ direction = selectedIndex < targetIndex and "south" or "north" })
    task = assert(activeMenuTask(game), "the source menu stays active while navigating")
  end
  Assert.equal(task.state.selectedIndex, targetIndex, "field input focuses the requested source menu entry")
  pressActionEdge(game)
  local messageId = selectedItem.message.id
  if
    activeMenuTask(game) == task
    and game:snapshot().dialogue.modal
    and (messageId == 65 or (messageId >= 67 and messageId <= 70) or messageId == 73)
  then
    pressActionEdge(game)
  end
end

-- Waits for the next source shell menu after the given one.
---@param game table
---@param previous table
---@return table menu task
local function nextShellMenu(game, previous)
  for _ = 1, 480 do
    local task = activeMenuTask(game)
    if task ~= nil and task ~= previous then
      return task
    end
    if game:snapshot().dialogue.modal then
      pressActionEdge(game)
    else
      game:step()
    end
  end
  error("the source PC shell never opens its next menu", 0)
end

-- Leaves the source PC shell through its logoff entry.
---@param game table
local function exitShell(game)
  local task = assert(activeMenuTask(game), "the generated source PC has an active menu")
  local item = nil
  for _, candidate in ipairs(task.state.menuDefinition.items) do
    if candidate.message.id == 66 then
      item = candidate
      break
    end
  end
  if item == nil then
    local previous = task
    for _, candidate in ipairs(task.state.menuDefinition.items) do
      if candidate.message.id == 72 or candidate.message.id == 75 then
        item = candidate
        break
      end
    end
    Assert.notNil(item, "the source submenu exposes its return entry")
    selectShellValue(game, item.value)
    nextShellMenu(game, previous)
    task = assert(activeMenuTask(game), "the source PC returns to its root menu")
    item = nil
    for _, candidate in ipairs(task.state.menuDefinition.items) do
      if candidate.message.id == 66 then
        item = candidate
        break
      end
    end
  end
  Assert.notNil(item, "the source PC root exposes its logoff entry")
  selectShellValue(game, item.value)
  game:advanceUntil("the source PC shell releases field input", function(snapshot)
    return not snapshot.fieldLocked and not snapshot.menu.modal
  end, 240)
end

-- Reads the script id behind one live object actor through the production
-- interaction resolver without starting its script.
---@param game table
---@param actorId string
---@return string? script id
local function probeActorScript(game, actorId)
  local runtime = game.runtime
  local actor = runtime.actors:getById(actorId)
  if actor == nil then
    return nil
  end
  local player = runtime.player
  local intent = runtime.interactionResolver:resolve({
    runtimeMap = runtime.runtimeMap,
    fieldX = player.fieldX,
    fieldZ = player.fieldZ,
    surfaceId = player.surfaceId,
    worldY = player.worldY,
    facing = player.facing,
    tick = runtime.session and runtime.session.tick + 1 or 0,
  })
  if intent == nil or intent.object == nil or intent.object.actorId ~= actorId then
    return nil
  end
  local hit = runtime.scripts.client:resolve(intent)
  if hit == nil then
    return nil
  end
  return hit.trigger.scriptId
end

-- Stands next to the named actor through production movement. Returns
-- false when no adjacent tile is reachable.
---@param game table
---@param actorId string
---@return boolean reached
local function standNextTo(game, actorId)
  local live = game.runtime.actors:getById(actorId)
  if live == nil then
    return false
  end
  local committed = live:getFieldPosition()
  local neighbors = {
    { fieldX = committed.fieldX, fieldZ = committed.fieldZ + 1, facing = "north" },
    { fieldX = committed.fieldX, fieldZ = committed.fieldZ - 1, facing = "south" },
    { fieldX = committed.fieldX + 1, fieldZ = committed.fieldZ, facing = "west" },
    { fieldX = committed.fieldX - 1, fieldZ = committed.fieldZ, facing = "east" },
  }
  local FieldMovement = require("tests.acceptance.support.FieldMovement")
  for _, tile in ipairs(neighbors) do
    if FieldMovement.route(game, tile) ~= nil then
      local ok = pcall(function()
        game:moveTo(tile)
      end)
      if ok then
        game:face(tile.facing)
        return true
      end
    end
  end
  return false
end

-- Finds the live object actor behind one retail script without starting
-- any script: every object actor is faced in production space and its
-- trigger resolved through the production client.
---@param game table
---@param scriptId string
---@return string actor id
local function findScriptActor(game, scriptId)
  local candidates = {}
  for actorId in pairs(game:snapshot().actors) do
    if actorId:match(":object:%d+$") ~= nil then
      candidates[#candidates + 1] = actorId
    end
  end
  table.sort(candidates)
  -- Wandering actors keep moving between the stand and probe steps, so
  -- the candidate scan retries before reporting an actor missing.
  for _ = 1, 3 do
    for _, actorId in ipairs(candidates) do
      if standNextTo(game, actorId) and probeActorScript(game, actorId) == scriptId then
        return actorId
      end
    end
  end
  error("no live Violet actor resolves the retail script " .. scriptId, 0)
end

-- Starts the retail interaction behind one actor from an explicitly
-- addressed stance through a real Action edge. The caller owns the
-- resulting script. Counter-facing interactions resolve across their
-- blocked frontage, which no neighbor-tile search can stand on, so the
-- stance drives with production movement and faces explicitly.
---@param game table
---@param scriptId string expected retail script
---@param tile { fieldX: integer, fieldZ: integer } production stance
---@param facing string production facing
---@return string actor id
local function talkFrom(game, scriptId, tile, facing)
  game:moveTo(tile)
  game:face(facing)
  local resolved = nil
  for actorId in pairs(game:snapshot().actors) do
    if probeActorScript(game, actorId) == scriptId then
      resolved = actorId
      break
    end
  end
  Assert.notNil(resolved, "the addressed stance resolves " .. scriptId)
  assert(resolved ~= nil, "the addressed stance resolves its actor")
  game:pressAction()
  Assert.equal(game:interaction().actorId, resolved, "the Action edge starts the faced actor")
  return resolved
end

-- Starts the retail interaction behind one actor through a real Action
-- edge. The caller owns the resulting script.
---@param game table
---@param actorId string
local function talkTo(game, actorId)
  Assert.isTrue(standNextTo(game, actorId), "the Violet actor is reachable in production space: " .. actorId)
  game:pressAction()
  Assert.equal(game:interaction().actorId, actorId, "the Action edge starts the faced Violet actor")
end

-- Adds one healthy starter through the live mon service after boot. The
-- caller records_rng and revision baselines after this setup.
---@param game table
---@param species string?
---@return table mon service
local function ensureStarter(game, species)
  local service = mons(game)
  service:createStarter(species or "CHIKORITA", {
    location = game.runtime.runtimeMap.mapId,
    date = { year = RECEIPT_DATE.year, month = RECEIPT_DATE.month, day = RECEIPT_DATE.day },
  })
  return service
end

-- Rebuilds the exact per-open menu the production editor factory
-- snapshots: live Dex sightings, the live game-clear flag, and the saved
-- word unlocks over the shared catalog.
---@param game table
---@return table menu snapshot
local function offeredMenu(game)
  local runtime = game.runtime
  local catalog = assert(runtime.easyChatCatalog, "the field runtime owns the shared word catalog")
  local state = assert(runtime.easyChatState, "the field runtime owns the saved word state")
  local unlocksNow = state:readUnlocks()
  local seen = {}
  for _, key in ipairs(catalog:seenSpeciesKeys()) do
    local ok, sighted = pcall(runtime.dexKnowledge.isSeen, runtime.dexKnowledge, key)
    if ok and sighted == true then
      seen[key] = true
    end
  end
  local cleared = runtime.eventState:isFlagSet(FLAGS.FLAG_GAME_CLEAR) == true
  return catalog:buildMenu({
    gameCleared = cleared,
    seen = seen,
    greetings = unlocksNow.greetings,
    trendy = unlocksNow.trendy,
  })
end

-- Locates one word identity in the offered category lists. Fails loudly
-- when availability withholds it, so a missing word can never silently
-- steer the browser at a neighbor.
---@param menu table
---@param wordId integer
---@return integer zero-based group, integer zero-based index, integer group size
local function findWord(menu, wordId)
  for groupIndex, group in ipairs(menu.groups) do
    for position, offered in ipairs(group.wordIds) do
      if offered == wordId then
        return groupIndex - 1, position - 1, #group.wordIds
      end
    end
  end
  error("the retail browser withholds word identity " .. wordId .. " under the live availability", 0)
end

-- Waits for the script-owned editor, failing fast with the script fault
-- when the foreground ends first instead of masking it as a timeout.
---@param game table
---@param budget integer?
---@return table host
-- Steps production once, dismissing retail dialogue only while no word
-- editor owns input. Action edges never reach an open editor child.
---@param game table
local function driveDialogueTick(game)
  if game:snapshot().dialogue.modal and not Drive.hostOf(game):isActive() then
    pressActionEdge(game)
  else
    game:step()
  end
end

local function waitEditorOpenFaultAware(game, budget)
  local host = Drive.hostOf(game)
  for _ = 1, budget or 480 do
    if host:isActive() then
      return host
    end
    local snapshot = game:snapshot()
    if snapshot.foregroundScript == nil and not snapshot.fieldLocked and not snapshot.dialogue.modal then
      local faults = {}
      for _, record in ipairs(game:hostEvents().records) do
        if record.name == "script.error" then
          faults[#faults + 1] = tostring(record.payload and record.payload.code)
            .. ":"
            .. tostring(record.payload and record.payload.message)
        end
      end
      error(
        "the word script ended without opening its editor; result="
          .. tostring(world(game):getVar(VAR_RESULT))
          .. " faults={"
          .. table.concat(faults, ";")
          .. "}",
        0
      )
    end
    driveDialogueTick(game)
  end
  error("the word script never opened its script-owned editor", 0)
end

---@param game table
---@param host table
---@return table fresh host status
local function hostStatus(game, host)
  return assert(host:status(), "the script-owned word editor keeps its status")
end

-- Waits for the editor composition level through production ticks. The
-- wait only trusts ticks newer than the entry view, so a never-stepped
-- screen can never satisfy it with its construction projection.
---@param game table
---@param host table
---@param budget integer?
local function waitComposition(game, host, budget)
  local entered = hostStatus(game, host).view.time or 0
  for _ = 1, budget or 240 do
    local status = hostStatus(game, host)
    if status.view.level == "composition" and (status.view.time or 0) > entered then
      return status
    end
    game:step()
  end
  error("the word editor never returns to composition", 0)
end

-- Waits for a browser level (categories or list) through production
-- ticks. The wait only trusts ticks newer than the entry view.
---@param game table
---@param host table
---@param level string
---@param budget integer?
local function waitBrowser(game, host, level, budget)
  local entered = hostStatus(game, host).view.time or 0
  for _ = 1, budget or 240 do
    local status = hostStatus(game, host)
    if status.view.level == level and (status.view.time or 0) > entered then
      return status
    end
    game:step()
  end
  error("the word editor never opens its " .. level .. " browser", 0)
end

-- Focuses one composition field through the production focus order.
---@param game table
---@param host table
---@param field string
local function focusField(game, host, field)
  -- Password prompts open the two-word editor: word fields, then
  -- CONFIRM, then CANCEL. The screen only projects a fresh view after
  -- its first stepped tick, so wait for the public tick clock before
  -- trusting any focus read; the entry focus is read back every step,
  -- so the walk approaches from either side instead of assuming a start.
  local order = { field1 = 1, field2 = 2, confirm = 3, cancel = 4 }
  local target = assert(order[field], "the password editor focuses a known entry")
  for _ = 1, 120 do
    if (hostStatus(game, host).view.time or 0) > 0 then
      break
    end
    game:step()
  end
  local last = "none"
  for _ = 1, 8 do
    local status = hostStatus(game, host)
    Assert.equal(status.view.mode, 1, "the password prompt opens the two-word editor")
    local here = order[status.view.focus]
    last = "level="
      .. tostring(status.view.level)
      .. " focus="
      .. tostring(status.view.focus)
      .. " slot="
      .. tostring(status.view.slot)
    if status.view.focus == field then
      return
    end
    if here == nil then
      local kind = status.view.prompt ~= nil and status.view.prompt.kind or nil
      local words = status.view.words
      error(
        "the editor focus left its known entries: focus="
          .. tostring(status.view.focus)
          .. " level="
          .. tostring(status.view.level)
          .. " prompt="
          .. tostring(kind)
          .. " words={"
          .. tostring(words and words[1])
          .. ","
          .. tostring(words and words[2])
          .. "}",
        0
      )
    end
    local direction = here < target and "down" or "up"
    Drive.send(game, { { type = "navigate", direction = direction } })
  end
  error("the word editor never focuses " .. field .. " (" .. last .. ")", 0)
end

-- Steers the category cursor to the zero-based target group. The grid is
-- read back from live status after every step, so a wrong turn fails
-- loudly instead of choosing a neighboring word.
---@param game table
---@param host table
---@param target integer
local function gotoGroup(game, host, target)
  for _ = 1, 40 do
    local status = hostStatus(game, host)
    local group = assert(status.view.browser, "the browser exposes its cursor").group
    if group == target then
      return
    end
    if group == 0xFE then
      Drive.send(game, { { type = "navigate", direction = "down" } })
    else
      local row, col = math.floor(group / 3), group % 3
      local targetRow, targetCol = math.floor(target / 3), target % 3
      local direction = nil
      if row < targetRow then
        direction = "down"
      elseif row > targetRow then
        direction = "up"
      elseif col < targetCol then
        direction = "right"
      else
        direction = "left"
      end
      Drive.send(game, { { type = "navigate", direction = direction } })
    end
  end
  error("the word editor never reaches category group " .. target, 0)
end

-- Steers the word-list cursor to the zero-based target index. The cursor
-- is read back from live status after every step; a stalled cursor fails
-- instead of confirming a neighbor.
---@param game table
---@param host table
---@param target integer
---@param count integer
local function gotoListIndex(game, host, target, count)
  local idle = 0
  for _ = 1, count + 6 do
    local status = hostStatus(game, host)
    local list = assert(status.view.list, "the word list exposes its cursor")
    Assert.isFalse(list.quit == true, "word-list navigation stays off the quit row")
    local index = list.topRow * 2 + list.row * 2 + list.col
    if index == target then
      return
    end
    local before = tostring(status.view.list.topRow)
      .. ":"
      .. tostring(status.view.list.row)
      .. ":"
      .. tostring(status.view.list.col)
    if index + 1 == target then
      Drive.send(game, { { type = "navigate", direction = "right" } })
    else
      Drive.send(game, { { type = "navigate", direction = "down" } })
    end
    local afterStatus = hostStatus(game, host)
    local afterList = afterStatus.view.list
    local after = afterList ~= nil
        and (tostring(afterList.topRow) .. ":" .. tostring(afterList.row) .. ":" .. tostring(afterList.col))
      or afterStatus.view.level
    if after == before then
      idle = idle + 1
      Assert.isTrue(idle < 2, "word-list navigation reaches the required word instead of stalling")
    else
      idle = 0
    end
  end
  error("the word editor never reaches word list index " .. target, 0)
end

-- Chooses one exact word into one composition field through semantic
-- browser input only, then proves the draft carries that identity.
---@param game table
---@param host table
---@param slot integer 1 or 2
---@param wordId integer
---@param menu table offered menu snapshot
local function chooseWord(game, host, slot, wordId, menu)
  local group, index, count = findWord(menu, wordId)
  focusField(game, host, "field" .. slot)
  Drive.send(game, { { type = "confirm" } })
  waitBrowser(game, host, "categories")
  gotoGroup(game, host, group)
  Drive.send(game, { { type = "confirm" } })
  waitBrowser(game, host, "list")
  gotoListIndex(game, host, index, count)
  Drive.send(game, { { type = "confirm" } })
  local status = waitComposition(game, host)
  Assert.equal(status.view.words[slot], wordId, "the browser choice lands the required word identity in its field")
end

-- Answers one script-owned prompt with one exact word pair through
-- semantic editor input, then accepts its answer confirmation.
---@param game table
---@param words integer[] two word identities
---@param menu table offered menu snapshot
local function answerPrompt(game, words, menu)
  Drive.requireScriptModules()
  local host = waitEditorOpenFaultAware(game)
  Drive.waitEditorReady(game, host)
  chooseWord(game, host, 1, words[1], menu)
  chooseWord(game, host, 2, words[2], menu)
  focusField(game, host, "confirm")
  Drive.send(game, { { type = "confirm" } })
  Drive.acceptAnswerPrompt(game, host)
end

-- Drives one full Primo conversation through both script-owned prompts
-- with the given word pairs, then settles the retail script. When the
-- expected password answer is given, it is read while the answer's
-- dialogue still blocks the script: the retail script reuses the result
-- variable afterwards (party count, player facing), so post-settle reads
-- cannot observe the answer on gift and full-party paths.
---@param game table
---@param actorId string
---@param pairs integer[][] two word pairs
---@param answerCode integer? expected password answer at its dialogue
local function runPrimoPasswords(game, actorId, pairs, answerCode)
  talkTo(game, actorId)
  local menu = offeredMenu(game)
  -- The initial offer defaults to YES; confirm it to reach the prompts.
  waitContextChoice(game, "the initial offer")
  Drive.send(game, { { type = "confirm" } })
  answerPrompt(game, pairs[1], menu)
  -- The accepted editor reports its result only after its exit fade, so
  -- the next prompt must wait for this child to close before its own
  -- open can be observed; otherwise the stale handle satisfies the wait.
  for _ = 1, 240 do
    if not Drive.hostOf(game):isActive() then
      break
    end
    local fault = checkFault(game)
    if fault ~= nil then
      error("the first password prompt faulted before closing: " .. fault, 0)
    end
    driveDialogueTick(game)
  end
  Assert.isFalse(Drive.hostOf(game):isActive(), "the accepted prompt closes its editor child")
  answerPrompt(game, pairs[2], menu)
  if answerCode ~= nil then
    for _ = 1, 480 do
      local fault = checkFault(game)
      if fault ~= nil then
        error("the password answer faulted before its dialogue opened: " .. fault, 0)
      end
      if game:snapshot().dialogue.modal then
        break
      end
      game:step()
    end
    Assert.isTrue(game:snapshot().dialogue.modal, "the password answer blocks on its dialogue")
    Assert.equal(world(game):getVar(VAR_RESULT), answerCode, "the password answer reports its code")
  end
  Assert.isTrue(settleToFree(game), "the retail password script releases the field")
end

-- Answers NO at the initial offer, proving the refusal path checks,
-- unlocks, and gives nothing.
---@param game table
---@param actorId string
local function refusePrimoOffer(game, actorId)
  talkTo(game, actorId)
  waitContextChoice(game, "the initial offer")
  game:step({ direction = "south" })
  game.runtime:pressAction()
  game:step()
  game.runtime:releaseAction()
  local host = Drive.hostOf(game)
  if host:isActive() then
    -- A missed NO still refuses through the first prompt's quit path.
    Drive.waitEditorReady(game, host)
    Drive.send(game, { { type = "cancel" } })
    for _ = 1, 240 do
      local status = hostStatus(game, host)
      if status.view.level == "prompt" then
        break
      end
      game:step()
    end
    local status = hostStatus(game, host)
    if status.view.level == "prompt" and status.view.prompt.kind == "quit" then
      Drive.send(game, { { type = "navigate", direction = "down" } })
      for _ = 1, 12 do
        game:step()
      end
      Drive.send(game, { { type = "confirm" } })
    end
  end
  Assert.isTrue(settleToFree(game), "the refused offer releases the field")
end

-- Cancels the first password prompt through its quit path.
---@param game table
---@param actorId string
local function cancelFirstPrompt(game, actorId)
  talkTo(game, actorId)
  waitContextChoice(game, "the initial offer")
  Drive.send(game, { { type = "confirm" } })
  local host = waitEditorOpenFaultAware(game)
  Drive.waitEditorReady(game, host)
  Drive.send(game, { { type = "cancel" } })
  for _ = 1, 240 do
    local status = hostStatus(game, host)
    if status.view.level == "prompt" then
      break
    end
    game:step()
  end
  local status = hostStatus(game, host)
  Assert.equal(status.view.prompt.kind, "quit", "the cancelled prompt answers with its quit path")
  Drive.send(game, { { type = "navigate", direction = "down" } })
  for _ = 1, 12 do
    game:step()
  end
  Drive.send(game, { { type = "confirm" } })
  Assert.isTrue(settleToFree(game), "the cancelled prompt releases the field")
end

---@param game table
---@return integer box revision, integer party revision
local function revisions(game)
  return mons(game):boxRevision(), mons(game):partyRevision()
end

---@param game table
---@param actorId string
---@param pairs integer[][] two word pairs
---@param species string
---@param flag integer
---@return table egg record
local function expectGiftEgg(game, actorId, pairs, species, flag)
  local service = mons(game)
  local _, partyBefore = revisions(game)
  local rngBefore = rngCalls(game)
  local statsBefore = game.runtime.gameStats:revision()
  local dex = game.runtime.dexKnowledge
  local effectsBefore = #game:hostEffects()
  Assert.isFalse(dex:isSeen(species), "the gift species starts unseen")
  -- The retail script counts the party into the result before the gift
  -- explanation, so the Egg code itself is proven by the branch
  -- outcomes below together with the password service suites.
  runPrimoPasswords(game, actorId, pairs)
  assertNoFaults(game, "the gift password script")
  Assert.isTrue(world(game):isFlagSet(flag), "the claimed password sets its one-time flag")
  local effects = game:hostEffects()
  local fanned = false
  for index = effectsBefore + 1, #effects do
    if tostring(effects[index]):sub(1, 8) == "fanfare:" then
      fanned = true
      break
    end
  end
  Assert.isTrue(fanned, "the gift presentation plays the source Egg fanfare")
  Assert.equal(service:partyCount(), 2, "the gift Egg joins the party without auto-boxing")
  Assert.equal(rngCalls(game), rngBefore + 4, "one gift Egg draws exactly four mon randoms")
  local egg = service:partyMon(1)
  Assert.equal(egg.species, species, "the gift keeps its biological species")
  Assert.isTrue(egg.isEgg, "the gift arrives unhatched")
  Assert.isNil(egg.nickname, "the gift carries no custom nickname")
  Assert.isFalse(dex:isSeen(species), "receiving the Egg records no Dex sighting")
  Assert.isFalse(dex:isCaught(species), "receiving the Egg records no Dex capture")
  Assert.isFalse(game.runtime.gameStats:isCounted(species), "receiving the Egg counts no receipt statistics")
  Assert.equal(game.runtime.gameStats:revision(), statsBefore, "receiving the Egg moves no statistics owner")
  local _, partyAfter = revisions(game)
  Assert.isTrue(partyAfter ~= partyBefore, "the gift publishes one party update")
  return egg
end

function T.tests.wallpaper_unlock_persists_then_first_egg_arrives_unhatched()
  withCenter(function(game)
    Drive.requireScriptModules()
    local service = ensureStarter(game)
    Assert.equal(service:partyCount(), 1, "the journey starts with one party mon and a free slot")
    local primo = findScriptActor(game, PRIMO_SCRIPT)

    local boxBefore, _ = revisions(game)
    local rngBefore = rngCalls(game)
    local effectsBefore = #game:hostEffects()
    local unlocksBefore = countUnlocks(unlocks(game))
    runPrimoPasswords(game, primo, WALLPAPER_FIRST)
    assertNoFaults(game, "the first wallpaper password")
    Assert.equal(world(game):getVar(VAR_RESULT), 1, "the first wallpaper answer returns its one-based slot")
    Assert.equal(world(game):getVar(VAR_WORD1), WALLPAPER_FIRST[1][1], "the first prompt publishes its words")
    Assert.equal(world(game):getVar(VAR_WORD2), WALLPAPER_FIRST[1][2], "the first prompt publishes its words")
    Assert.equal(world(game):getVar(VAR_WORD3), WALLPAPER_FIRST[2][1], "the second prompt publishes its words")
    Assert.equal(world(game):getVar(VAR_WORD4), WALLPAPER_FIRST[2][2], "the second prompt publishes its words")
    local found = unlocks(game)
    Assert.isTrue(found[1], "the matching wallpaper bit stages exactly once")
    Assert.equal(countUnlocks(found), unlocksBefore + 1, "no neighboring wallpaper bit moves")
    Assert.isTrue(mons(game):boxRevision() ~= boxBefore, "the first unlock publishes one box update")
    Assert.equal(rngCalls(game), rngBefore, "password checks draw no mon randoms")
    for index = effectsBefore + 1, #game:hostEffects() do
      Assert.isFalse(
        tostring(game:hostEffects()[index]):sub(1, 8) == "fanfare:",
        "the wallpaper reward plays no Egg fanfare"
      )
    end
    Assert.equal(service:partyCount(), 1, "checking a password adds no party mon")
    Assert.isFalse(world(game):isFlagSet(FLAG_MAREEP), "wallpaper phrases set no Egg flag")
    Assert.isFalse(world(game):isFlagSet(FLAG_WOOPER), "wallpaper phrases set no Egg flag")
    Assert.isFalse(world(game):isFlagSet(FLAG_SLUGMA), "wallpaper phrases set no Egg flag")

    -- A repeated phrase is a durable duplicate: same answer shape, zero
    -- revision movement, and no hidden draw.
    boxBefore = mons(game):boxRevision()
    rngBefore = rngCalls(game)
    runPrimoPasswords(game, primo, WALLPAPER_FIRST)
    assertNoFaults(game, "the repeated wallpaper password")
    Assert.equal(world(game):getVar(VAR_RESULT), 0, "the duplicate answer reports its duplicate result")
    Assert.equal(countUnlocks(unlocks(game)), unlocksBefore + 1, "the duplicate stages no further bit")
    Assert.equal(mons(game):boxRevision(), boxBefore, "the duplicate publishes no box revision")
    Assert.equal(rngCalls(game), rngBefore, "the duplicate draws no mon randoms")

    -- The first Egg phrase gives exactly one Mareep Egg and survives a
    -- save roundtrip; repeating it afterwards adds nothing.
    local egg = expectGiftEgg(game, primo, EGG_MAREEP, "MAREEP", FLAG_MAREEP)
    Assert.equal(egg.friendship, game.runtime.monCatalog:species("MAREEP").eggCycles, "the Egg carries personal cycles")
    Assert.equal(egg.egg.location, RECEIPT_LOCATION, "the Egg keeps its gift receipt location")
    Assert.deepEqual(
      egg.egg.date,
      { year = RECEIPT_DATE.year, month = RECEIPT_DATE.month, day = RECEIPT_DATE.day },
      "the Egg keeps its gift receipt date"
    )
    Assert.equal(egg.met.location, 0, "the unhatched gift clears its met location")
    Assert.equal(egg.met.level, 0, "the unhatched gift clears its met level")
    Assert.isNil(egg.met.date, "the unhatched gift carries no met date")
    Assert.isFalse(egg.fatefulEncounter, "the gift is an ordinary encounter")
    Assert.equal(egg.heldItem, "NONE", "the gift holds no item")
    local derived = service:partyMonDerived(1)
    Assert.equal(derived.level, 1, "the gift arrives at level one")
    Assert.equal(egg.condition.currentHp, derived.maxHp, "the gift arrives with full level-one health")
    local displayName = Mon.displayName(egg, game.runtime.monCatalog)
    Assert.equal(
      displayName,
      game.runtime.monCatalog:species("EGG").name,
      "the unnamed Egg shows the localized Egg label"
    )
    local projected = PartyScreenModel.build(service, {})
    Assert.isTrue(projected.slots[2].isEgg, "the party projection keeps the Egg marked")
    Assert.equal(projected.slots[2].displayName, displayName, "the party projection shows the Egg label")
    Assert.equal(projected.slots[2].heldItem, "NONE", "the party projection keeps the Egg itemless")

    game:setWorldState({ flag = FLAG_SAVE_BUTTON })
    Journey.saveAndReload(game)
    Assert.isTrue(unlocks(game)[1], "Continue retains the wallpaper unlock")
    Assert.isTrue(world(game):isFlagSet(FLAG_MAREEP), "Continue retains the Egg flag")
    Assert.equal(service:partyCount(), 2, "Continue retains the gifted Egg")
    local kept = service:partyMon(1)
    Assert.equal(kept.personality, egg.personality, "Continue retains the exact gifted Egg")
    Assert.equal(kept.egg.location, RECEIPT_LOCATION, "Continue retains the Egg receipt location")
    Assert.deepEqual(
      kept.egg.date,
      { year = RECEIPT_DATE.year, month = RECEIPT_DATE.month, day = RECEIPT_DATE.day },
      "Continue retains the Egg receipt date"
    )
    -- The reload swaps in a fresh runtime, so later reads and editor
    -- opens use its live owners and its own headless preparation lease.
    service = mons(game)
    local rebinding, _ = Drive.bindHeadlessEditor(game.runtime)
    local reunbind = assert(
      game.runtime.unbindEasyChatPreparation,
      "the reloaded field runtime releases the word editor preparation binding"
    )
    primo = findScriptActor(game, PRIMO_SCRIPT)

    local rngAfter = rngCalls(game)
    runPrimoPasswords(game, primo, EGG_MAREEP, 8)
    assertNoFaults(game, "the repeated Egg password")
    Assert.equal(service:partyCount(), 2, "the repeated Egg phrase adds no second Egg")
    Assert.equal(rngCalls(game), rngAfter, "the repeated Egg phrase draws no mon randoms")
    reunbind(game.runtime, rebinding)
    Assert.equal(game:renderAttempts(), 0, "the Primo journey stops before GPU rendering")
  end)
end

function T.tests.refusals_full_party_and_retry_keep_each_reward_one_time()
  withCenter(function(game)
    Drive.requireScriptModules()
    local service = ensureStarter(game)
    for _, species in ipairs({ "CYNDAQUIL", "TOTODILE", "CHIKORITA", "CYNDAQUIL", "TOTODILE" }) do
      service:createStarter(species, {
        location = game.runtime.runtimeMap.mapId,
        date = { year = RECEIPT_DATE.year, month = RECEIPT_DATE.month, day = RECEIPT_DATE.day },
      })
    end
    Assert.equal(service:partyCount(), 6, "the refusal journey starts with a full party")
    local primo = findScriptActor(game, PRIMO_SCRIPT)

    -- A rejected offer and a cancelled prompt refuse without checking,
    -- unlocking, or giving anything.
    local rngBefore = rngCalls(game)
    local partyRevisionBefore = service:partyRevision()
    refusePrimoOffer(game, primo)
    assertNoFaults(game, "the refused offer")
    Assert.equal(service:partyCount(), 6, "a refused offer adds no party mon")
    Assert.equal(rngCalls(game), rngBefore, "a refused offer draws no mon randoms")
    Assert.equal(service:partyRevision(), partyRevisionBefore, "a refused offer publishes no party update")
    cancelFirstPrompt(game, primo)
    assertNoFaults(game, "the cancelled prompt")
    Assert.equal(service:partyCount(), 6, "a cancelled prompt adds no party mon")
    Assert.equal(rngCalls(game), rngBefore, "a cancelled prompt draws no mon randoms")
    Assert.isFalse(world(game):isFlagSet(FLAG_WOOPER), "refusals set no Egg flag")
    Assert.isFalse(world(game):isFlagSet(FLAG_SLUGMA), "refusals set no Egg flag")

    -- An incorrect phrase is invalid without consuming the gift.
    local menu = offeredMenu(game)
    local bank = assert(game.runtime.easyChatCatalog.primoWords, "the shared catalog carries the ordered password bank")
    local banked = {}
    for _, word in ipairs(bank) do
      banked[word] = true
    end
    local stray = nil
    for _, group in ipairs(menu.groups) do
      for _, word in ipairs(group.wordIds) do
        if banked[word] ~= true then
          stray = word
          break
        end
      end
      if stray ~= nil then
        break
      end
    end
    Assert.notNil(stray, "the offered menu carries a word outside the password bank")
    runPrimoPasswords(game, primo, { { stray, stray }, { stray, stray } }, 255)
    assertNoFaults(game, "the incorrect password")
    Assert.equal(world(game):getVar(VAR_RESULT), 255, "a non-password phrase reports its invalid result")
    Assert.isFalse(world(game):isFlagSet(FLAG_WOOPER), "an incorrect phrase sets no Egg flag")
    Assert.equal(service:partyCount(), 6, "an incorrect phrase adds no party mon")
    Assert.equal(rngCalls(game), rngBefore, "an incorrect phrase draws no mon randoms")

    -- A valid phrase on a full party explains the shortage, keeps the
    local partyRevisionBefore = service:partyRevision()
    local boxRevisionBefore = service:boxRevision()
    runPrimoPasswords(game, primo, EGG_WOOPER)
    assertNoFaults(game, "the full-party password")
    -- The refusal path counts the party into the result variable before
    -- explaining the shortage, so the Egg answer itself is only observable
    -- on the retry below; here the count proves the capacity branch ran.
    Assert.equal(world(game):getVar(VAR_RESULT), 6, "the full-party refusal leaves the party count")
    Assert.isFalse(world(game):isFlagSet(FLAG_WOOPER), "a full party leaves the Egg flag clear for retry")
    Assert.equal(service:partyCount(), 6, "a full party receives no Egg")
    Assert.equal(rngCalls(game), rngBefore, "a full party draws no mon randoms for the refused gift")
    Assert.equal(service:partyRevision(), partyRevisionBefore, "a full party publishes no party update")
    Assert.equal(service:boxRevision(), boxRevisionBefore, "a full party publishes no box update")
    Assert.isFalse(game.runtime.dexKnowledge:isSeen("WOOPER"), "the refused gift records no Dex sighting")

    -- Two real Storage deposits free two slots

    -- Two real Storage deposits free two slots; the retry then claims
    -- exactly one Wooper and leaves Slugma independently claimable.
    local host = assert(game.runtime.pcApplicationHost, "the field owns the production PC host")
    for _ = 1, 2 do
      local handle = host:open({ app = "storage", mode = 0 })
      host:setPresentationReady(handle, true)
      host:step(handle, { { type = "confirm" } })
      Assert.equal(host:status().phase, "menu", "the Storage child opens its party-slot menu")
      host:step(handle, { { type = "confirm" } })
      Assert.equal(host:status().phase, "carry", "the Storage child arms the deposit carry")
      host:step(handle, { { type = "confirm" } })
      host:step(handle, { { type = "cancel" } })
      host:step(handle, { { type = "cancel" } })
      Assert.notNil(host:result(handle), "the closed Storage child reports back once")
      host:close(handle)
    end
    Assert.equal(service:partyCount(), 4, "two production deposits free two party slots")
    runPrimoPasswords(game, primo, EGG_WOOPER)
    assertNoFaults(game, "the retried password")
    Assert.isTrue(world(game):isFlagSet(FLAG_WOOPER), "the retry sets only its own Egg flag")
    Assert.isFalse(world(game):isFlagSet(FLAG_SLUGMA), "claiming one species leaves the other claimable")
    Assert.equal(service:partyCount(), 5, "the retry claims exactly one Wooper Egg")
    local wooper = service:partyMon(4)
    Assert.isTrue(wooper.isEgg, "the retried gift arrives unhatched")
    Assert.equal(wooper.species, "WOOPER", "the retried gift keeps its biological species")
    Assert.isNil(wooper.nickname, "the retried gift carries no custom nickname")

    runPrimoPasswords(game, primo, EGG_SLUGMA)
    assertNoFaults(game, "the independent Slugma password")
    Assert.isTrue(world(game):isFlagSet(FLAG_SLUGMA), "the Slugma phrase sets its own Egg flag")
    Assert.equal(service:partyCount(), 6, "the Slugma phrase claims exactly one Egg")
    local slugma = service:partyMon(5)
    Assert.isTrue(slugma.isEgg, "the Slugma gift arrives unhatched")
    Assert.equal(slugma.species, "SLUGMA", "the Slugma gift keeps its biological species")
    Assert.equal(game:renderAttempts(), 0, "the retry journey stops before GPU rendering")
  end)
end

function T.tests.avatar_choice_confirms_persists_and_cancels_cleanly()
  withCenter(function(game)
    Drive.requireScriptModules()
    ensureStarter(game)
    local avatar = findScriptActor(game, AVATAR_SCRIPT)
    local heroBefore = game.runtime.avatar and game.runtime.avatar.id or nil
    local playerBefore = game:snapshot().player
    local catalog = assert(game.runtime.easyChatCatalog, "the field runtime owns the shared word catalog")
    local residue = TRAINER_ID % 8
    local expectedRow = assert(catalog.unionAvatars, "the shared catalog carries the avatar rows").choices[residue + 1][1 + 1]
      + GENDER * 8
    local expectedRowRecord =
      assert(catalog.unionAvatars.rows[expectedRow + 1], "the shared catalog carries the selected avatar row")
    local expectedClass = expectedRowRecord.classId or expectedRowRecord[2]

    -- Reject the first offered choice at its confirmation, then confirm
    -- the second: only the confirmed row persists.
    talkTo(game, avatar)
    local menu = waitAvatarMenu(game)
    local values = {}
    for _, item in ipairs(menu.state.menuDefinition.items) do
      values[#values + 1] = item.value
    end
    Assert.deepEqual(values, { 0, 1, 2, 3, 4 }, "the avatar menu offers its four choices in source order")
    local function selectValue(value)
      for _ = 1, 8 do
        local task = assert(activeMenuTask(game), "the avatar menu stays active while choosing")
        if task.state.selectedIndex == value then
          break
        end
        game:step({ direction = task.state.selectedIndex < value and "south" or "north" })
      end
      local task = assert(activeMenuTask(game), "the avatar menu focuses its required entry")
      Assert.equal(task.state.selectedIndex, value, "field input focuses the required avatar entry")
      game.runtime:pressAction()
      game:step()
      game.runtime:releaseAction()
    end
    selectValue(0)
    waitContextChoice(game, "the avatar confirmation")
    -- Answer NO: the selector loops back to its choices and saves nothing.
    game:step({ direction = "south" })
    game.runtime:pressAction()
    game:step()
    game.runtime:releaseAction()
    game:advanceUntil("the rejected choice reopens the menu", function()
      return activeMenuTask(game) ~= nil
    end, 480)
    Assert.isFalse(world(game):isFlagSet(FLAG_AVATAR_SET), "rejecting the choice sets no avatar flag")
    selectValue(1)
    waitContextChoice(game, "the second confirmation")
    game.runtime:pressAction()
    game:step()
    game.runtime:releaseAction()
    -- The selector reuses the class variable for the native sprite after
    -- the confirmation text, so the buffered class is read while its
    -- own dialogue still blocks the script.
    for _ = 1, 480 do
      local fault = checkFault(game)
      if fault ~= nil then
        error("the avatar confirmation faulted before its dialogue opened: " .. fault, 0)
      end
      if game:snapshot().dialogue.modal then
        break
      end
      game:step()
    end
    Assert.isTrue(game:snapshot().dialogue.modal, "the confirmed choice blocks on its dialogue")
    Assert.equal(world(game):getVar(VAR_AVATAR_CLASS), expectedClass, "the selector buffers the chosen class")
    Assert.isTrue(settleToFree(game), "the confirmed avatar releases the field")
    assertNoFaults(game, "the avatar selector")
    Assert.equal(world(game):getVar(VAR_AVATAR_CHOICE), 1, "the selector publishes the confirmed choice")
    Assert.isTrue(world(game):isFlagSet(FLAG_AVATAR_SET), "confirming the choice sets its flag")
    local profile = game.runtime.playerData.profile
    Assert.equal(profile.unionAvatar, expectedRow, "the confirmed choice persists its normalized row")
    local heroAfter = game.runtime.avatar and game.runtime.avatar.id or nil
    Assert.equal(heroAfter, heroBefore, "saving the identity never swaps the overworld hero")
    local playerAfter = game:snapshot().player
    Assert.deepEqual(
      { playerAfter.fieldX, playerAfter.fieldZ, playerAfter.facing },
      { playerBefore.fieldX, playerBefore.fieldZ, playerBefore.facing },
      "the selector leaves the player where the conversation found them"
    )

    -- Talking again reaches the remembered-choice branch; cancelling its
    -- menu preserves the saved row and the flag side effect stays put.
    talkTo(game, avatar)
    waitAvatarMenu(game)
    -- The menu opens over its lead-in message, so the cancellation
    -- retries across several ticks to reach the menu task itself.
    for _ = 1, 6 do
      game.runtime:pressCancel()
      game:step()
      game.runtime:releaseCancel()
      if activeMenuTask(game) == nil then
        break
      end
    end
    assertNoFaults(game, "the cancelled avatar menu")
    Assert.equal(game.runtime.playerData.profile.unionAvatar, expectedRow, "cancelling preserves the saved row")
    Assert.isTrue(world(game):isFlagSet(FLAG_AVATAR_SET), "cancelling preserves the avatar flag")
    -- Let the farewell print fully before pressing: the dismissal edge
    -- is armed only once printing completes.
    game:advanceUntil("the farewell finishes printing", function()
      return not game:snapshot().dialogue.modal or game.runtime.dialogue._state == "WAITING_CLOSE"
    end, 480)
    Assert.isTrue(settleToFree(game), "the cancelled menu releases the field")

    game:setWorldState({ flag = FLAG_SAVE_BUTTON })
    Journey.saveAndReload(game)
    Assert.equal(game.runtime.playerData.profile.unionAvatar, expectedRow, "Continue retains the saved avatar row")
    Assert.isTrue(world(game):isFlagSet(FLAG_AVATAR_SET), "Continue retains the avatar flag")
    Assert.equal(game:renderAttempts(), 0, "the avatar journey stops before GPU rendering")
  end)
end

function T.tests.local_center_paths_stay_usable_around_an_egg()
  withCenter(function(game)
    Drive.requireScriptModules()
    local service = ensureStarter(game)
    local primo = findScriptActor(game, PRIMO_SCRIPT)
    expectGiftEgg(game, primo, EGG_MAREEP, "MAREEP", FLAG_MAREEP)

    -- The nurse heals the ordinary mon while the machine count excludes
    -- the Egg; the Egg itself keeps its receipt metadata. Removing the
    -- starter and re-adding it appends behind the Egg, so the damaged
    -- mon rides slot one and the Egg rides slot zero below.
    local damaged = service:removeMon(0)
    damaged.condition.currentHp = 1
    Assert.isTrue(service:addMon(damaged), "the damaged starter returns to its production party")
    -- The nurse counter faces across its blocked frontage from the
    -- spawn tile, which neighbor-tile search cannot stand on.
    talkFrom(game, NURSE_SCRIPT, { fieldX = 8, fieldZ = 13 }, "north")
    local flow = assert(game.runtime.pokemonCenterHeal, "the field exposes its center-healing flow")
    -- The idle flow reports a zero count, so the wait tracks the phase:
    -- the greeting blocks for button presses until the machine starts.
    for _ = 1, 480 do
      if flow:status().phase ~= "idle" then
        break
      end
      local fault = checkFault(game)
      if fault ~= nil then
        error("the nurse interaction faulted before its machine started: " .. fault, 0)
      end
      if game:snapshot().dialogue.modal then
        pressActionEdge(game)
      else
        game:step()
      end
    end
    Assert.equal(flow:status().count, 1, "the healing machine counts only the non-Egg party")
    Assert.isTrue(settleToFree(game), "the nurse interaction releases the field")
    assertNoFaults(game, "the nurse interaction")
    Assert.equal(
      service:partyMon(1).condition.currentHp,
      service:partyMonDerived(1).maxHp,
      "the nurse heals the ordinary mon"
    )
    local nursed = service:partyMon(0)
    Assert.isTrue(nursed.isEgg, "nursing keeps the Egg unhatched")
    Assert.equal(nursed.egg.location, RECEIPT_LOCATION, "nursing preserves the Egg receipt location")
    Assert.equal(nursed.nickname, nil, "nursing adds no Egg nickname")

    -- Every remaining local conversation completes through its retail
    -- script without faults and releases the field.
    for _, scriptId in ipairs({
      "vanilla.hgss.scr_seq.0860.script_001",
      "vanilla.hgss.scr_seq.0860.script_002",
      "vanilla.hgss.scr_seq.0860.script_003",
    }) do
      local actor = findScriptActor(game, scriptId)
      local before = #game:recordsForScript(scriptId)
      talkTo(game, actor)
      Assert.isTrue(settleToFree(game), "the local conversation releases the field: " .. scriptId)
      Assert.equal(#game:recordsForScript(scriptId), before + 1, "the retail local script runs once: " .. scriptId)
      assertNoFaults(game, "the local conversation " .. scriptId)
    end

    -- The existing PC terminal still opens its production Storage child
    -- around the gift, then the shell exits and the party is untouched.
    local map = game.runtime.runtimeMap
    local origin = assert(map.coordinateOrigin, "the composed Center has a field coordinate origin")
    local tiles = nil
    for localZ = 0, 31 do
      for localX = 0, 31 do
        if map.collision:containsLocal(localX, localZ) then
          local cell = map.collision:getLocal(localX, localZ)
          if cell.behavior == 131 then
            local standX, standZ = localX, localZ + 1
            if map.collision:containsLocal(standX, standZ) and not map.collision:getLocal(standX, standZ).blocked then
              tiles = { stand = { fieldX = origin.x + standX, fieldZ = origin.z + standZ } }
              break
            end
          end
        end
      end
      if tiles ~= nil then
        break
      end
    end
    Assert.notNil(tiles, "the generated Center has an accessible PC tile")
    game:moveTo(tiles.stand)
    game:face("north")
    local startsBefore = #game:recordsForScript(PC_SCRIPT)
    game:pressAction()
    Assert.equal(game:interaction().scriptId, PC_SCRIPT, "the source PC metatile starts its canonical shell")
    Assert.equal(#game:recordsForScript(PC_SCRIPT), startsBefore + 1, "the source PC shell starts once")
    game:advanceUntil("the source PC-on effect", function()
      return hasEffect(game:hostEffects(), "SEQ_SE_DP_PC_ON")
    end, 120)
    local root = nil
    for _ = 1, 480 do
      root = activeMenuTask(game)
      if root ~= nil or game.runtime.pcApplicationHost:isActive() then
        break
      end
      if game:snapshot().dialogue.modal then
        pressActionEdge(game)
      else
        game:step()
      end
    end
    Assert.notNil(root, "the source PC shell reaches its root menu")
    local rootValues = {}
    for _, item in ipairs(root.state.menuDefinition.items) do
      rootValues[#rootValues + 1] = item.value
    end
    Assert.deepEqual(rootValues, { 0, 1, 2 }, "the pre-clear shell retains its three source entries")
    selectShellValue(game, 0)
    nextShellMenu(game, root)
    selectShellValue(game, 0)
    for _ = 1, 480 do
      if game.runtime.pcApplicationHost:isActive() then
        break
      end
      if game:snapshot().dialogue.modal then
        pressActionEdge(game)
      else
        game:step()
      end
    end
    local host = game.runtime.pcApplicationHost
    Assert.isTrue(host:isActive(), "the existing PC shell still opens its production child")
    Assert.equal(host:status().app, "storage", "the selected source mode opens the production Storage child")
    local handle = assert(host:activeHandle(), "the open Storage child publishes its retained handle")
    host:setPresentationReady(handle, true)
    -- B asks "Continue Box operations?"; a second B answers No and
    -- leaves through the field input path so the waiting script observes
    -- the child's own result.
    game.runtime:pressCancel()
    game:step()
    game.runtime:releaseCancel()
    game.runtime:pressCancel()
    game:step()
    game.runtime:releaseCancel()
    game:advanceUntil("the source shell returns to its Storage submenu", function()
      local snapshot = game:snapshot()
      return not host:isActive() and snapshot.menu ~= nil and snapshot.menu.modal
    end, 480)
    Assert.isTrue(game:snapshot().fieldLocked, "returning from Storage keeps the source shell in control")
    exitShell(game)
    assertNoFaults(game, "the PC terminal")
    Assert.equal(service:partyCount(), 2, "the PC visit moves no party mon")
    Assert.isTrue(service:partyMon(0).isEgg, "the PC visit keeps the Egg unhatched")
    Assert.equal(game:renderAttempts(), 0, "the local-paths journey stops before GPU rendering")
  end)
end

return T
