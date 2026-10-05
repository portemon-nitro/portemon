-- Production field route for the source player-room Mailbox.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local ScriptIdentity = require("libs.assets.src.ScriptIdentity")
local FieldStatePresentationFixture = require("tests.support.FieldStatePresentationFixture")

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = {
      "field-runtime",
      "audio-bank:702",
      "message-bank:40",
      "message-bank:191",
      "map-data:64",
      "map-data:69",
      "map:64",
      "map:69",
      "pc:global",
    },
    tags = { "field", "pc", "acceptance" },
  },
  tests = {},
}

local PLAYER_ROOM = "MAP_NEW_BARK_PLAYER_HOUSE_2F"
local POKECENTER = "MAP_CHERRYGROVE_POKECENTER_1F"
local PC_STANDARD_SCRIPT = "common.pokecenter_pc"
local FLAG_HIDE_COMM_CLUB_CLOSED_LADIES = FieldScriptSymbols.flagsByName.FLAG_HIDE_COMM_CLUB_CLOSED_LADIES

-- TILE_BEHAVIOR_PC has source value 131 in
-- pret/pokeheartgold/include/constants/metatile_behavior.h.
local SOURCE_PC_METATILE_BEHAVIOR = 131

local function withPlayerRoom(fn)
  local harness = AcceptanceHarness.new()
  local createGame = harness.gameFactory
  harness.gameFactory = function(versionId, map)
    local game = createGame(versionId, map)
    -- These are the source fresh-game room coordinates (location_backup.c).
    game.location = { mapSymbol = PLAYER_ROOM, fieldX = 6, fieldZ = 6, facing = "south" }
    return game
  end
  local game = harness:boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = PLAYER_ROOM,
    save = "fresh",
    fieldOptions = {
      recordingScriptHosts = true,
      derivedAssets = FieldStatePresentationFixture.iconHost().derivedAssets,
    },
  })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    fn(game)
    Assert.equal(game:renderAttempts(), 0, "PC acceptance stops before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

local function playerRoomMailboxEvent(game)
  local map = game.runtime.runtimeMap
  local bank = assert(map.fieldData.scriptBankId, "the generated room declares its script bank")
  for _, event in ipairs(map.fieldData.events.background) do
    if event.scriptId == 1 then
      return event, ScriptIdentity.formatVanilla(bank, event.scriptId - 1)
    end
  end
  return nil, nil
end

local function hasEffect(effects, sound)
  for _, effect in ipairs(effects) do
    if effect == "audio:" .. sound then
      return true
    end
  end
  return false
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

local function activeMenuTask(game)
  for _, task in ipairs(game.runtime.scripts.scheduler:tasks()) do
    if task.taskType == "menu" then
      return task
    end
  end
  return nil
end

local function menuItemValues(task)
  local values = {}
  for _, item in ipairs(task.state.menuDefinition.items) do
    values[#values + 1] = item.value
  end
  return values
end

local function selectMenuValue(game, value)
  local task = assert(activeMenuTask(game), "the source PC menu is active")
  local targetIndex
  for index, item in ipairs(task.state.menuDefinition.items) do
    if item.value == value then
      targetIndex = index - 1
      break
    end
  end
  assert(targetIndex ~= nil, "the current source PC menu contains the requested value")
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
  Assert.equal(task.state.menuDefinition.items[targetIndex + 1].value, value, "the focused source menu entry carries the requested result")
  pressAction(game)
  local messageId = selectedItem.message.id
  if
    activeMenuTask(game) == task
    and game:snapshot().dialogue.modal
    and (messageId == 65 or (messageId >= 67 and messageId <= 70) or messageId == 73)
  then
    pressAction(game)
  end
end

local function photoRecord()
  return {
    schema = "g4-photo-v1",
    icon = 0,
    playerName = "GOLD",
    playerGender = 0,
    leadNickname = "CHIKORITA",
    avatarState = "walking",
    mapSymbol = POKECENTER,
    fieldX = 8,
    fieldZ = 13,
    date = { year = 2026, month = 10, day = 5, weekday = 1 },
    hour = 12,
    minute = 30,
    party = { { species = "CHIKORITA", form = 0, gender = 0, shiny = false }, false, false, false, false, false },
    sourcePartyCount = 1,
    hiddenPropModels = { false, false },
  }
end

local function mailRecord()
  return {
    schema = "g4-mail-v1",
    type = 0,
    author = { trainerId = 54321, name = "MISTY", gender = 1, language = 2, game = 8 },
    icons = { false, false, false },
    lines = {
      { template = "mail.line.first", words = { "word.water", false } },
      { template = "mail.line.second", words = { "word.friend", false } },
      { template = "mail.line.third", words = { "word.goodbye", false } },
    },
  }
end

local function seedMailbox(game, count)
  local mailbox = assert(game.runtime.mailbox, "the production save owns its Mailbox")
  local updates = {}
  for slot = 0, mailbox.CAPACITY - 1 do
    updates[#updates + 1] = { slot = slot, value = slot < count and mailRecord() or false }
  end
  local preparation = assert(mailbox:prepareChanges(mailbox:revision(), updates))
  preparation.publish()
  Assert.equal(mailbox:usedCount(), count, "the production Mailbox owns the seeded sparse records")
end

local function seedPhotos(game, count)
  local album = assert(game.runtime.photoAlbum, "the production save owns its Photo Album")
  local updates = {}
  for slot = 0, album.CAPACITY - 1 do
    updates[#updates + 1] = { slot = slot, value = slot < count and photoRecord() or false }
  end
  local preparation = assert(album:prepareChanges(album:revision(), updates))
  preparation.publish()
  Assert.equal(album:usedCount(), count, "the production Photo Album owns the seeded sparse records")
end

local function describe(value, seen)
  if type(value) ~= "table" then
    return type(value) == "string" and string.format("%q", value) or tostring(value)
  end
  seen = seen or {}
  if seen[value] then
    return "<cycle>"
  end
  seen[value] = true
  local entries = {}
  for key, item in pairs(value) do
    entries[#entries + 1] = describe(key, seen) .. "=" .. describe(item, seen)
  end
  table.sort(entries)
  seen[value] = nil
  return "{" .. table.concat(entries, ",") .. "}"
end

local function sourcePcDiagnostic(game)
  local runtime = game.runtime
  local records = game:hostEvents().records
  local trailingEvents = {}
  for index = math.max(1, #records - 39), #records do
    local record = records[index]
    trailingEvents[#trailingEvents + 1] = { name = record.name, payload = record.payload }
  end
  local scheduler = runtime.scripts.scheduler
  local snapshot = game:snapshot()
  return describe({
    tasks = scheduler:tasks(),
    trailingHostEvents = trailingEvents,
    screenFade = runtime.screenFade:status(),
    dialogue = runtime.dialogue:status(),
    menu = snapshot.menu,
    pcApplication = {
      active = runtime.pcApplicationHost:isActive(),
      status = runtime.pcApplicationHost:status(),
    },
    pcTerminal = {
      activeRole = runtime.pcTerminal._activeRole,
      hasActiveProp = runtime.pcTerminal._activeProp ~= nil,
    },
  })
end

local function advanceSourceDialogueUntil(game, label, predicate)
  for _ = 1, 480 do
    local snapshot = game:snapshot()
    if predicate(snapshot) then
      return snapshot
    end
    if snapshot.dialogue.modal then
      pressAction(game)
    else
      game:step()
    end
  end
  error(
    "timed out waiting for "
      .. label
      .. " in the source PC script; locked="
      .. tostring(game:snapshot().fieldLocked)
      .. ", diagnostic="
      .. sourcePcDiagnostic(game)
  )
end

local function withPokecenter(fn)
  local harness = AcceptanceHarness.new()
  local createGame = harness.gameFactory
  harness.gameFactory = function(versionId, map)
    local game = createGame(versionId, map)
    -- Source map spawn at the south entrance (pokeheartgold map spawn table).
    game.location = { mapSymbol = POKECENTER, fieldX = 8, fieldZ = 13, facing = "north" }
    -- Retail's closed Union Room ladies and its open receptionists share cells.
    game.worldState:setFlag(FLAG_HIDE_COMM_CLUB_CLOSED_LADIES)
    return game
  end
  local game = harness:boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = POKECENTER,
    save = "fresh",
    fieldOptions = {
      recordingScriptHosts = true,
      derivedAssets = FieldStatePresentationFixture.iconHost().derivedAssets,
    },
  })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    fn(game)
    Assert.equal(game:renderAttempts(), 0, "PC acceptance stops before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

local function pokecenterPcTile(game)
  local map = game.runtime.runtimeMap
  local origin = assert(map.coordinateOrigin, "the composed Center has a field coordinate origin")
  for localZ = 0, 31 do
    for localX = 0, 31 do
      if map.collision:containsLocal(localX, localZ) then
        local cell = map.collision:getLocal(localX, localZ)
        if cell.behavior == SOURCE_PC_METATILE_BEHAVIOR then
          local standX, standZ = localX, localZ + 1
          local neighbor = map.collision:containsLocal(localX + 1, localZ)
              and map.collision:getLocal(localX + 1, localZ)
            or nil
          if
            map.collision:containsLocal(standX, standZ)
            and not map.collision:getLocal(standX, standZ).blocked
            and neighbor ~= nil
            and neighbor.behavior ~= SOURCE_PC_METATILE_BEHAVIOR
            and map.collision:containsLocal(localX + 1, standZ)
            and not map.collision:getLocal(localX + 1, standZ).blocked
          then
            return {
              fieldX = origin.x + localX,
              fieldZ = origin.z + localZ,
              stand = { fieldX = origin.x + standX, fieldZ = origin.z + standZ },
              neighborStand = { fieldX = origin.x + localX + 1, fieldZ = origin.z + standZ },
            }
          end
        end
      end
    end
  end
  return nil
end

local function openSourcePc(game)
  local pc = assert(pokecenterPcTile(game), "the generated Center has an accessible PC tile")
  game:moveTo(pc.stand)
  game:face("north")
  game:pressAction()
  Assert.equal(game:interaction().scriptId, PC_STANDARD_SCRIPT, "the source PC metatile starts its canonical shell")
  game:advanceUntil("the source PC-on effect", function()
    return hasEffect(game:hostEffects(), "SEQ_SE_DP_PC_ON")
  end, 120)
  return advanceSourceDialogueUntil(game, "the source PC menu", function()
    return activeMenuTask(game) ~= nil
  end)
end

local function nextSourcePcMenu(game, previous)
  return advanceSourceDialogueUntil(game, "the next source PC menu", function()
    local task = activeMenuTask(game)
    return task ~= nil and task ~= previous
  end)
end

local function exitSourcePcMenu(game)
  local task = assert(activeMenuTask(game), "the generated source PC has an active menu")
  local item
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
    assert(item ~= nil, "the source submenu exposes its return entry")
    selectMenuValue(game, item.value)
    nextSourcePcMenu(game, previous)
    task = assert(activeMenuTask(game), "the source PC returns to its root menu")
    item = nil
    for _, candidate in ipairs(task.state.menuDefinition.items) do
      if candidate.message.id == 66 then
        item = candidate
        break
      end
    end
  end
  assert(item ~= nil, "the source PC root exposes its logoff entry")
  selectMenuValue(game, item.value)
  game:advanceUntil("the source PC shell releases field input", function(snapshot)
    return not snapshot.fieldLocked and not snapshot.menu.modal
  end, 240)
end

local function assertMessageIds(task, expected)
  local actual = {}
  for _, item in ipairs(task.state.menuDefinition.items) do
    actual[#actual + 1] = assert(item.message and item.message.id, "source menu item keeps its message identity")
  end
  Assert.deepEqual(actual, expected, "the source shell exposes the expected retained menu entries")
end

function T.tests.player_room_mailbox_event_shows_empty_mailbox_warning_and_returns()
  withPlayerRoom(function(game)
    local event, scriptId = playerRoomMailboxEvent(game)
    Assert.notNil(event, "the source player-room Mailbox background event is present in the generated map")
    Assert.equal(game:snapshot().mapSymbol, PLAYER_ROOM)

    game:moveTo({ fieldX = event.x, fieldZ = event.z + 1 })
    game:face("north")
    local before = #game:recordsForScript(scriptId)
    game:pressAction()
    Assert.equal(game:interaction().scriptId, scriptId, "the actual room event starts its canonical generated script")
    Assert.equal(#game:recordsForScript(scriptId), before + 1, "the source Mailbox script starts once")
    Assert.isTrue(game:snapshot().fieldLocked, "the source script owns the field while it checks Mailbox")

    game:advanceUntil("the source PC-on sound begins", function()
      return hasEffect(game:hostEffects(), "SEQ_SE_DP_PC_ON")
    end, 120)
    local effects = game:hostEffects()
    Assert.isTrue(hasEffect(effects, "SEQ_SE_DP_PC_ON"), "the source room route plays the PC-on effect")
    game:advanceDialogue()

    local host = assert(game.runtime.pcApplicationHost, "the production field owns the PC application host")
    Assert.isFalse(host:isActive(), "an empty Mailbox follows the source warning path without a blank child")
    Assert.isNil(game:snapshot().foregroundScript, "the source event continuation completes")
    Assert.isFalse(game:snapshot().fieldLocked, "the source event releases player input after the warning")
  end)
end

function T.tests.pokecenter_pc_metatile_routes_only_when_faced_north()
  withPokecenter(function(game)
    local pc = pokecenterPcTile(game)
    Assert.notNil(pc, "the generated Cherrygrove map contains an accessible source PC metatile")
    Assert.equal(game:snapshot().mapSymbol, POKECENTER)

    game:moveTo(pc.neighborStand)
    game:face("north")
    game:pressAction()
    Assert.isNil(game:interaction().scriptId, "an ordinary neighboring metatile does not bind the PC script")
    Assert.isFalse(game:snapshot().fieldLocked, "the neighboring metatile leaves field input available")

    game:moveTo(pc.stand)
    game:face("south")
    game:pressAction()
    Assert.isNil(game:interaction().scriptId, "the PC metatile does not bind when faced from the wrong direction")
    Assert.isFalse(game:snapshot().fieldLocked, "the wrong direction does not start the PC shell")

    game:face("north")
    local startsBefore = #game:recordsForScript(PC_STANDARD_SCRIPT)
    game:pressAction()
    Assert.equal(
      game:interaction().scriptId,
      PC_STANDARD_SCRIPT,
      "the real metatile dispatches its closed standard script"
    )
    Assert.equal(#game:recordsForScript(PC_STANDARD_SCRIPT), startsBefore + 1, "the source PC shell starts once")
    Assert.isTrue(game:snapshot().fieldLocked, "the source PC shell owns the field")
    game:advanceUntil("the source PC-on sound begins", function()
      return hasEffect(game:hostEffects(), "SEQ_SE_DP_PC_ON")
    end, 120)
    Assert.isTrue(hasEffect(game:hostEffects(), "SEQ_SE_DP_PC_ON"), "the source PC shell starts its terminal-on effect")

    local host = assert(game.runtime.pcApplicationHost, "the production field owns the PC application host")
    local shellState = advanceSourceDialogueUntil(game, "the source PC menu or Storage child", function(snapshot)
      return host:isActive() or (snapshot.menu ~= nil and snapshot.menu.modal)
    end)
    Assert.isTrue(shellState.fieldLocked, "the source PC shell retains field ownership")
    if not host:isActive() then
      -- The source top-level menu starts on its first option in this fresh
      -- save. Its selection opens the source Storage menu after the login
      -- message; selecting that menu's first option launches Storage.
      pressAction(game)
      local storageMenu = advanceSourceDialogueUntil(game, "the source Storage menu or child", function(snapshot)
        return host:isActive() or (snapshot.menu ~= nil and snapshot.menu.modal)
      end)
      Assert.isTrue(storageMenu.fieldLocked, "the source Storage menu retains field ownership")
    end
    if not host:isActive() then
      pressAction(game)
      advanceSourceDialogueUntil(game, "the source PC script opens Storage", function()
        return host:isActive()
      end)
    end
    Assert.isTrue(host:isActive(), "the selected source menu entry owns a real Storage child")

    local handle = assert(host:activeHandle(), "the open Storage child publishes its retained handle")
    -- The headless acceptance composition has no FieldState renderer to
    -- publish preparation completion; acknowledge the ready child explicitly.
    host:setPresentationReady(handle, true)
    game.runtime:pressCancel()
    game:step()
    game.runtime:releaseCancel()
    advanceSourceDialogueUntil(game, "the source shell returns to its Storage submenu", function(snapshot)
      return not host:isActive() and snapshot.menu ~= nil and snapshot.menu.modal
    end)
    Assert.isTrue(game:snapshot().fieldLocked, "returning from Storage keeps the source shell in control")
  end)
end

function T.tests.generated_pc_shell_uses_bill_photo_and_hall_of_fame_source_gates()
  withPokecenter(function(game)
    openSourcePc(game)
    local root = assert(activeMenuTask(game), "the generated PC shell opens its first source menu")
    Assert.equal(root.state.menuDefinition.items[1].message.id, 61, "before Bill the PC entry keeps its source label")
    Assert.deepEqual(menuItemValues(root), { 0, 1, 2 }, "the pre-clear shell retains its three source entries")
    exitSourcePcMenu(game)

    game:setWorldState({ flag = FieldScriptSymbols.flagsByName.FLAG_SYS_MET_BILL })
    game:setWorldState({ flag = FieldScriptSymbols.flagsByName.FLAG_GAME_CLEAR })
    local afterBillSnapshot = openSourcePc(game)
    Assert.isTrue(afterBillSnapshot.fieldLocked, "the generated shell owns input after opening")
    root = assert(activeMenuTask(game), "the post-Bill source menu is active")
    Assert.equal(root.state.menuDefinition.items[1].message.id, 62, "after Bill the PC entry uses the changed source label")
    Assert.deepEqual(menuItemValues(root), { 0, 1, 2, 3 }, "the cleared source shell adds its Hall of Fame entry")

    local previous = root
    selectMenuValue(game, 2)
    local hofWarning = game:advanceUntil("the source missing-record Hall of Fame warning", function(snapshot)
      return snapshot.dialogue.modal and snapshot.dialogue.messageId == 94
    end, 240)
    Assert.equal(hofWarning.dialogue.messageId, 94, "missing HOF data follows the source warning branch")
    Assert.isFalse(game.runtime.pcApplicationHost:isActive(), "the warning does not start an unavailable HOF child")
    pressAction(game)
    nextSourcePcMenu(game, previous)
    root = assert(activeMenuTask(game), "the source shell resumes its menu after the warning")
    Assert.isTrue(root ~= previous, "the source warning returns to a newly composed root menu")

    previous = root
    selectMenuValue(game, 1)
    nextSourcePcMenu(game, previous)
    local photoMenu = assert(activeMenuTask(game), "the source Mailbox and Photo Album submenu opens")
    assertMessageIds(photoMenu, { 73, 74, 75 })
    previous = photoMenu
    selectMenuValue(game, 0)
    local mailboxWarning = game:advanceUntil("the source empty Mailbox warning", function(snapshot)
      return snapshot.dialogue.modal and snapshot.dialogue.messageId == 47
    end, 240)
    Assert.equal(mailboxWarning.dialogue.messageId, 47, "the empty Mailbox shows its source warning")
    Assert.isFalse(game.runtime.pcApplicationHost:isActive(), "an empty Mailbox does not launch a blank child")
    pressAction(game)
    nextSourcePcMenu(game, previous)
    photoMenu = assert(activeMenuTask(game), "the empty Mailbox continuation opens its source submenu")
    assertMessageIds(photoMenu, { 73, 74, 75 })
    exitSourcePcMenu(game)

    seedMailbox(game, 20)
    openSourcePc(game)
    root = assert(activeMenuTask(game))
    previous = root
    selectMenuValue(game, 1)
    nextSourcePcMenu(game, previous)
    photoMenu = assert(activeMenuTask(game))
    previous = photoMenu
    selectMenuValue(game, 0)
    advanceSourceDialogueUntil(game, "the full Mailbox child", function()
      return game.runtime.pcApplicationHost:isActive()
    end)
    local mailboxHost = game.runtime.pcApplicationHost
    Assert.equal(mailboxHost:status().app, "mailbox", "full source Mailbox records open the production child")
    local mailboxHandle = assert(mailboxHost:activeHandle())
    mailboxHost:setPresentationReady(mailboxHandle, true)
    pressCancel(game)
    nextSourcePcMenu(game, previous)
    exitSourcePcMenu(game)
    seedMailbox(game, 0)

    for _, count in ipairs({ 1, 3 }) do
      seedPhotos(game, count)
      openSourcePc(game)
      root = assert(activeMenuTask(game))
      previous = root
      selectMenuValue(game, 1)
      nextSourcePcMenu(game, previous)
      photoMenu = assert(activeMenuTask(game), "saved photos add an entry to the source Photo Album submenu")
      assertMessageIds(photoMenu, { 73, 74, 65, 75 })
      previous = photoMenu
      selectMenuValue(game, 0)
      mailboxWarning = game:advanceUntil("the source empty Mailbox warning", function(snapshot)
        return snapshot.dialogue.modal and snapshot.dialogue.messageId == 47
      end, 240)
      Assert.equal(mailboxWarning.dialogue.messageId, 47)
      pressAction(game)
      nextSourcePcMenu(game, previous)
      photoMenu = assert(activeMenuTask(game), "the saved-photo source menu opens after Mailbox")
      assertMessageIds(photoMenu, { 73, 74, 65, 75 })

      previous = photoMenu
      selectMenuValue(game, 2)
      advanceSourceDialogueUntil(game, "the source Photo Album child", function()
        return game.runtime.pcApplicationHost:isActive()
      end)
      local host = game.runtime.pcApplicationHost
      Assert.equal(host:status().app, "photoAlbum", "saved photos expose the real source Album child")
      local handle = assert(host:activeHandle())
      host:setPresentationReady(handle, true)
      pressCancel(game)
      nextSourcePcMenu(game, previous)
      exitSourcePcMenu(game)
    end

    for mode = 0, 3 do
      openSourcePc(game)
      root = assert(activeMenuTask(game))
      previous = root
      selectMenuValue(game, 0)
      nextSourcePcMenu(game, previous)
      local modeMenu = assert(activeMenuTask(game), "the source Storage mode menu opens")
      local values = menuItemValues(modeMenu)
      Assert.isTrue(values[mode + 1] == mode, "the source menu retains each supported Storage mode")

      previous = modeMenu
      selectMenuValue(game, mode)
      advanceSourceDialogueUntil(game, "the selected source Storage child", function()
        return game.runtime.pcApplicationHost:isActive()
      end)
      local host = game.runtime.pcApplicationHost
      local status = host:status()
      Assert.equal(status.app, "storage", "the selected source mode opens the production Storage child")
      Assert.equal(status.mode, mode, "the source menu value reaches the matching Storage mode")
      local handle = assert(host:activeHandle())
      host:setPresentationReady(handle, true)
      pressCancel(game)
      nextSourcePcMenu(game, previous)
      exitSourcePcMenu(game)
    end
  end)
end

return T
