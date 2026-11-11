-- Shared word editor through the production field: all three editor modes
-- answer through the original confirmation flow with exact changed and
-- cancellation semantics, an empty map annotation opens the rendered
-- editor through the ordinary application shell and commits exactly one
-- word back to the retained marking session, and learned words plus saved
-- phrases survive an ordinary save roundtrip with strict admission. Every
-- leg boots the real field runtime over real maps, scripts, and state
-- owners; only host audio, host input snapshots, the wall clock, and the
-- save root are recording boundaries. No ROM text is asserted here and no
-- editor implementation is faked.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local Fixture = require("tests.support.PokegearJourneyFixture")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = Fixture.JOURNEY_ASSETS,
    tags = { "easychat" },
  },
  tests = {},
}

local NULL_WORD = 0xFFFF
local HIGH_BIT = 0x1000
local READY_BUDGET = 240
local FLOW_BUDGET = 240
local EXIT_BUDGET = 240
local BROWSER_BUDGET = 40
local TEMPLATE_BUDGET = 105

-- Loads a word editor module that does not exist yet at this baseline.
-- The failure names the missing behaviour instead of surfacing as a
-- suite load error, so the pre-implementation red stays attributable.
---@param moduleName string
---@param missingMessage string
---@return table
local function requireFeature(moduleName, missingMessage)
  local ok, mod = pcall(require, moduleName)
  if not ok then
    error(missingMessage, 0)
  end
  assert(type(mod) == "table", missingMessage)
  return mod --[[@as table]]
end

-- Binds the documented headless preparation lease: the acceptance runtime
-- never realizes GPU images, so the editor commits a ready bundle of stub
-- assets at the field preparation seam instead of the real image pool.
-- The stub stands in for the GPU-owned bundle only; input, lifecycle, and
-- results stay production. Returns the binding identity and a release
-- counter proving every per-open lease releases exactly once.
---@param runtime table
---@return unknown bindingId, fun(): integer releases
local function bindHeadlessWordEditor(runtime)
  local releases = 0
  local bind = assert(runtime.bindEasyChatPreparation, "the field runtime binds the word editor preparation lease")
  local binding = bind(runtime, function()
    return {
      prepare = function()
        return { kind = "ready", assets = {} }
      end,
      release = function()
        releases = releases + 1
      end,
    }
  end)
  return binding, function()
    return releases
  end
end

-- Drives one directly owned editor screen with the shared semantic event
-- vocabulary used by every field screen.
---@param screen table
---@return fun(events: table)
local function directSend(screen)
  return function(events)
    screen:updateFixed(events)
  end
end

-- Drives the shell-owned editor through production game input: direction
-- keys, the action key, and the cancel key travel the same FieldState path
-- as the menus, so the shell's raw batch forwarding stays in the loop.
---@param game table
---@return fun(events: table)
local function keySend(game)
  local FieldState = require("game.hgss.src.field.FieldState")
  local callbacks = setmetatable({
    runtime = {
      input = game.runtime.input,
      actionKeys = game.runtime.actionKeys,
      cancelKeys = game.runtime.cancelKeys,
      menuKeys = game.runtime.menuKeys,
    },
  }, FieldState)
  return function(events)
    if #events == 0 then
      game:step()
      return
    end
    for _, event in ipairs(events) do
      if event.type == "confirm" then
        game.runtime.input:pressAction("key:return")
        game:step()
        game.runtime.input:releaseAction("key:return")
      elseif event.type == "cancel" then
        game.runtime:pressCancel()
        game:step()
        game.runtime:releaseCancel()
      elseif event.type == "navigate" then
        local key = "s"
        if event.direction == "up" then
          key = "w"
        elseif event.direction == "left" then
          key = "a"
        elseif event.direction == "right" then
          key = "d"
        end
        callbacks:keypressed(key)
        game:step()
        callbacks:keyreleased(key)
      else
        game:step()
      end
    end
  end
end

-- Bounded semantic wait: ticks the editor until the predicate holds. A
-- stall fails with the stalled state instead of hanging the suite.
---@param label string
---@param getStatus fun(): table
---@param send fun(events: table)
---@param want fun(status: table): boolean
---@param budget integer
---@return table status
local function waitFor(label, getStatus, send, want, budget)
  local status = nil
  for _ = 1, budget do
    status = getStatus()
    if status ~= nil and want(status) then
      return status
    end
    send({})
  end
  local state = "no status"
  if status ~= nil then
    state = "level=" .. tostring(status.view and status.view.level)
  end
  error("the shared word editor never " .. label .. " (" .. state .. ")", 0)
end

---@param getStatus fun(): table
---@param send fun(events: table)
---@return table status
local function waitReady(getStatus, send)
  return waitFor("becomes ready for input", getStatus, send, function(status)
    return status.preparing == false and status.uiInput == "easy-chat"
  end, READY_BUDGET)
end

-- Moves focus to CONFIRM from any composition focus without wrapping:
-- down to the clamped bottom, then one step up.
---@param send fun(events: table)
local function focusConfirm(send)
  for _ = 1, 5 do
    send({ { type = "navigate", direction = "down" } })
  end
  send({ { type = "navigate", direction = "up" } })
end

-- Accepts the answer confirmation, which always starts on YES for a
-- complete changed or forced draft.
---@param getStatus fun(): table
---@param send fun(events: table)
local function acceptAnswerPrompt(getStatus, send)
  local status = waitFor("asks its confirmation", getStatus, send, function(s)
    return s.view.level == "prompt"
  end, FLOW_BUDGET)
  Assert.equal(status.view.prompt.kind, "answer", "a complete draft asks its answer confirmation")
  Assert.equal(status.view.prompt.selected, "yes", "the answer confirmation starts on YES")
  send({ { type = "confirm" } })
end

-- Reads the one-shot terminal result after the exit fade completes. The
-- result is unavailable while the fade runs and reads exactly once.
---@param screen table
---@param send fun(events: table)
---@return table result
local function takeDirectResult(screen, send)
  for _ = 1, EXIT_BUDGET do
    local result = screen:takeResult()
    if result ~= nil then
      return result
    end
    send({})
  end
  error("the editor never publishes its terminal result after exit", 0)
end

-- Chooses any offered word through the retail browser: top field, open the
-- categories, scan groups until a word list opens, take the last row, and
-- return to composition. Empty groups reject in place, so the scan steps
-- past them. Bounded; a stall fails with the stalled level.
---@param getStatus fun(): table
---@param send fun(events: table)
local function selectAnyWord(getStatus, send)
  for _ = 1, 5 do
    send({ { type = "navigate", direction = "up" } })
  end
  send({ { type = "confirm" } })
  waitFor("opens its browser", getStatus, send, function(s)
    return s.view.level ~= "composition"
  end, FLOW_BUDGET)
  for _ = 1, BROWSER_BUDGET do
    local status = getStatus()
    local level = status.view.level
    if level == "list" then
      break
    end
    Assert.isTrue(
      level == "categories" or level == "abc",
      "the browser stays in its category lists, not " .. tostring(level)
    )
    send({ { type = "confirm" } })
    for _ = 1, 30 do
      send({})
    end
    local opened = getStatus()
    if opened.view.level == "list" then
      break
    end
    if opened.view.level == "composition" then
      send({ { type = "confirm" } })
    else
      send({ { type = "navigate", direction = "down" } })
    end
  end
  local status = getStatus()
  Assert.equal(status.view.level, "list", "the browser reaches a word list")
  for _ = 1, 6 do
    send({ { type = "navigate", direction = "down" } })
  end
  send({ { type = "navigate", direction = "up" } })
  send({ { type = "confirm" } })
  waitFor("returns to composition after a word choice", getStatus, send, function(s)
    return s.view.level == "composition"
  end, FLOW_BUDGET)
end

-- The shared editor answers one word, two words, and sentences through
-- the original confirmation flow: word choice returns to composition
-- without publishing, CONFIRM asks "is this your answer" with YES first,
-- unchanged drafts without force take the quit path with NO first,
-- cancellation returns the original payload, high-bit identities survive,
-- template switches normalize trailing fields, and every result publishes
-- exactly once after the exit fade with its entry modality.
function T.tests.shared_editor_answers_all_modes_through_confirmation_with_exact_identity()
  Fixture.withGame(Fixture.TOWN, function(game)
    local Composition = requireFeature(
      "game.hgss.src.easychat.EasyChatComposition",
      "the shared word editor is not composed yet: no mode can open, confirm, or publish a result"
    )
    local runtime = game.runtime
    local catalog =
      assert(runtime.easyChatCatalog, "the field runtime owns the shared word catalog before any editor opens")
    local state = assert(runtime.easyChatState, "the field runtime owns the saved word state before any editor opens")
    local binding, releases = bindHeadlessWordEditor(runtime)
    local unbind =
      assert(runtime.unbindEasyChatPreparation, "the field runtime releases the word editor preparation binding")

    local first = state:towerMessage(1)
    local w1 = first.words[1]
    local w2 = state:towerMessage(2).words[1]
    Assert.isTrue(w1 ~= NULL_WORD and w2 ~= NULL_WORD, "the default tower phrases carry usable word identities")
    Assert.isTrue(w1 < HIGH_BIT and w2 < HIGH_BIT, "the default tower words leave high bits free")

    -- Single-word mode: choose a word, confirm YES, and read the changed
    -- result exactly once after the exit fade.
    do
      local screen = Composition.open(runtime, {
        mode = 0,
        words = { NULL_WORD, NULL_WORD },
        promptId = 0,
        alwaysConfirm = false,
        inputMode = "buttons",
      })
      local send = directSend(screen)
      local getStatus = function()
        return screen:status()
      end
      waitReady(getStatus, send)
      selectAnyWord(getStatus, send)
      Assert.isNil(screen:takeResult(), "a word choice returns to composition without publishing")
      focusConfirm(send)
      send({ { type = "confirm" } })
      acceptAnswerPrompt(getStatus, send)
      Assert.isNil(screen:takeResult(), "no result publishes before the exit fade completes")
      local result = takeDirectResult(screen, send)
      Assert.equal(result.mode, 0, "the result names its single-word mode")
      Assert.isFalse(result.cancelled, "confirming YES accepts the word")
      Assert.isTrue(result.changed, "choosing a word from an empty draft counts as changed")
      Assert.isTrue(result.words[1] ~= NULL_WORD, "the chosen word reaches the terminal result")
      Assert.equal(result.words[2], NULL_WORD, "the single-word result carries no second word")
      Assert.equal(result.inputMode, "buttons", "the result echoes the entry modality")
      Assert.isNil(screen:takeResult(), "the terminal result publishes exactly once")
      screen:dispose()
    end

    -- Unchanged drafts without force take the quit path: NO resumes,
    -- YES quits with the original payload and no change.
    do
      local screen = Composition.open(runtime, {
        mode = 0,
        words = { NULL_WORD, NULL_WORD },
        promptId = 0,
        alwaysConfirm = false,
        inputMode = "buttons",
      })
      local send = directSend(screen)
      local getStatus = function()
        return screen:status()
      end
      waitReady(getStatus, send)
      focusConfirm(send)
      send({ { type = "confirm" } })
      local status = waitFor("asks to quit", getStatus, send, function(s)
        return s.view.level == "prompt"
      end, FLOW_BUDGET)
      Assert.equal(status.view.prompt.kind, "quit", "an unchanged draft takes the quit path")
      Assert.equal(status.view.prompt.selected, "no", "the quit confirmation starts on NO")
      send({ { type = "confirm" } })
      waitFor("resumes composition on NO", getStatus, send, function(s)
        return s.view.level == "composition"
      end, FLOW_BUDGET)
      Assert.isNil(screen:takeResult(), "resuming publishes no result")
      focusConfirm(send)
      send({ { type = "confirm" } })
      status = waitFor("asks to quit again", getStatus, send, function(s)
        return s.view.level == "prompt"
      end, FLOW_BUDGET)
      Assert.equal(status.view.prompt.kind, "quit", "the unchanged draft still takes the quit path")
      send({ { type = "navigate", direction = "down" } })
      for _ = 1, 12 do
        send({})
      end
      status = getStatus()
      Assert.equal(status.view.prompt.selected, "yes", "a vertical step toggles the quit choice")
      send({ { type = "confirm" } })
      local result = takeDirectResult(screen, send)
      Assert.isTrue(result.cancelled, "quitting with YES cancels the edit")
      Assert.isFalse(result.changed, "a cancelled edit reports no change")
      Assert.deepEqual(result.words, { NULL_WORD, NULL_WORD }, "cancellation returns the original payload")
      Assert.isNil(screen:takeResult(), "the cancelled result publishes exactly once")
      screen:dispose()
    end

    -- The cancel key opens the same quit path and returns the original
    -- two-word payload untouched.
    do
      local original = { w1, w2 }
      local screen = Composition.open(runtime, {
        mode = 1,
        words = { w1, w2 },
        promptId = 0,
        alwaysConfirm = false,
        inputMode = "buttons",
      })
      local send = directSend(screen)
      local getStatus = function()
        return screen:status()
      end
      waitReady(getStatus, send)
      send({ { type = "cancel" } })
      local status = waitFor("asks to quit on cancel", getStatus, send, function(s)
        return s.view.level == "prompt"
      end, FLOW_BUDGET)
      Assert.equal(status.view.prompt.kind, "quit", "the cancel key takes the quit path")
      Assert.equal(status.view.prompt.selected, "no", "the cancel path starts on NO")
      send({ { type = "navigate", direction = "up" } })
      for _ = 1, 12 do
        send({})
      end
      Assert.equal(getStatus().view.prompt.selected, "yes", "either vertical direction toggles the choice")
      send({ { type = "confirm" } })
      local result = takeDirectResult(screen, send)
      Assert.isTrue(result.cancelled, "the cancel path quits with YES")
      Assert.isFalse(result.changed, "the cancelled two-word edit reports no change")
      Assert.deepEqual(result.words, original, "cancellation returns the original two-word payload")
      Assert.isNil(screen:takeResult(), "the cancelled result publishes exactly once")
      screen:dispose()
    end

    -- Forced acceptance can be unchanged: the high-bit identity survives
    -- byte for byte while its display resolves through the low twelve
    -- bits exactly like the plain identity.
    do
      local high = w1 + HIGH_BIT
      local screen = Composition.open(runtime, {
        mode = 1,
        words = { high, w2 },
        promptId = 0,
        alwaysConfirm = true,
        inputMode = "buttons",
      })
      local send = directSend(screen)
      local getStatus = function()
        return screen:status()
      end
      waitReady(getStatus, send)
      focusConfirm(send)
      send({ { type = "confirm" } })
      acceptAnswerPrompt(getStatus, send)
      local result = takeDirectResult(screen, send)
      Assert.isFalse(result.cancelled, "forced confirmation accepts the unchanged draft")
      Assert.isFalse(result.changed, "an unchanged forced draft reports no change")
      Assert.deepEqual(result.words, { high, w2 }, "acceptance preserves the full word identities")
      Assert.deepEqual(
        catalog:wordTokens(high),
        catalog:wordTokens(w1),
        "display resolution uses the low twelve bits of the identity"
      )
      Assert.isNil(screen:takeResult(), "the unchanged result publishes exactly once")
      screen:dispose()
    end

    -- Sentence mode: switching the template changes the message, and the
    -- accepted result keeps only the fields the new template requires.
    -- Incomplete landings show their notice and dismiss back to
    -- composition; the first complete landing accepts.
    do
      local screen = Composition.open(runtime, {
        mode = 2,
        message = { bank = 0, number = 0, words = { w1, w2 } },
        promptId = 0,
        alwaysConfirm = false,
        inputMode = "buttons",
      })
      local send = directSend(screen)
      local getStatus = function()
        return screen:status()
      end
      waitReady(getStatus, send)
      local landed = false
      for _ = 1, TEMPLATE_BUDGET do
        send({ { type = "navigate", direction = "left" } })
        for _ = 1, 6 do
          send({})
        end
        focusConfirm(send)
        send({ { type = "confirm" } })
        local status = waitFor("answers the template draft", getStatus, send, function(s)
          return s.view.level == "prompt"
        end, FLOW_BUDGET)
        if status.view.prompt.kind == "answer" then
          Assert.equal(status.view.prompt.selected, "yes", "the answer confirmation starts on YES")
          landed = true
          break
        end
        send({ { type = "confirm" } })
        waitFor("dismisses its notice", getStatus, send, function(s)
          return s.view.level == "composition"
        end, FLOW_BUDGET)
      end
      Assert.isTrue(landed, "a changed template eventually completes its sentence")
      send({ { type = "confirm" } })
      Assert.isNil(screen:takeResult(), "no sentence result publishes before the exit fade completes")
      local result = takeDirectResult(screen, send)
      Assert.isFalse(result.cancelled, "confirming YES accepts the sentence")
      Assert.isTrue(result.changed, "switching the template counts as changed")
      Assert.isTrue(
        result.message.bank ~= 0 or result.message.number ~= 0,
        "the accepted sentence keeps its new template identity"
      )
      local arity = catalog:template(result.message.bank, result.message.number).wordCount
      for slot = 1, 2 do
        if slot <= arity then
          Assert.equal(
            result.message.words[slot],
            ({ w1, w2 })[slot],
            "the accepted sentence retains required word " .. slot
          )
        else
          Assert.equal(result.message.words[slot], NULL_WORD, "the accepted sentence normalizes unused word " .. slot)
        end
      end
      Assert.isNil(screen:takeResult(), "the sentence result publishes exactly once")
      screen:dispose()
    end

    unbind(runtime, binding)
    Assert.equal(releases(), 5, "every per-open lease releases exactly once")
    Assert.equal(game:renderAttempts(), 0, "the editor journey stops before GPU rendering")
  end)
end

---@param game table
local function prepareMapCard(game)
  local state = assert(game.runtime.pokegearState, "the composed field owns Pokegear state")
  state:registerCard("map")
  state:setPreference("lastApp", "map")
  game:setWorldState({ flag = FieldScriptSymbols.flagsByName.FLAG_GOT_POKEGEAR })
  game:setWorldState({ flag = FieldScriptSymbols.flagsByName.FLAG_GOT_SAVE_BUTTON })
end

---@param game table
local function openProductionMap(game)
  Fixture.openGearThroughMenu(game)
  local gear =
    assert(game.runtime.applicationHost:status().application, "the Start Menu owns the open gear application")
  Assert.equal(gear.tab, "map", "the saved card selection opens the Map card")
  local child = assert(gear.child, "the gear shell publishes its active card")
  Assert.equal(child.tab, "map", "the production Map card owns the child")
  return assert(child.view, "the production Map card publishes its map view")
end

-- Flattens saved markings into comparable slot entries for exact
-- commit diffing without naming any map symbol in the test. Empty slots
-- carry no annotation, so only committed words participate in the diff.
---@param markings table
---@return table<string, string>
local function wordSlots(markings)
  local slots = {}
  for symbol, marking in pairs(markings) do
    if type(marking) == "table" and type(marking.words) == "table" then
      for index, word in ipairs(marking.words) do
        if word ~= false then
          slots[tostring(symbol) .. ":" .. tostring(index)] = tostring(word)
        end
      end
    end
  end
  return slots
end

---@param before table<string, string>
---@param after table<string, string>
---@return table changedEntries, integer changedCount
local function diffSlots(before, after)
  local changed = {}
  local count = 0
  for key, value in pairs(after) do
    if before[key] ~= value then
      changed[key] = value
      count = count + 1
    end
  end
  for key in pairs(before) do
    if after[key] == nil then
      changed[key] = "removed"
      count = count + 1
    end
  end
  return changed, count
end

-- A production map annotation opens the rendered editor through the
-- ordinary shell, commits exactly one decimal word after YES, keeps the
-- retained marking session across a cancelled second slot, and survives a
-- save roundtrip with its display fragments resolving through the shared
-- catalog. The shell owns the child throughout: the map underneath stays
-- parked and no GPU call is attempted.
function T.tests.production_map_annotation_opens_returns_and_saves_through_the_shell()
  Fixture.withGame(Fixture.TOWN, function(game)
    prepareMapCard(game)
    local Composition = requireFeature(
      "game.hgss.src.easychat.EasyChatComposition",
      "the shared word editor is not composed yet: the map annotation cannot open its editor"
    )
    assert(Composition ~= nil, "the editor composition loads above")
    local runtime = game.runtime
    local catalog =
      assert(runtime.easyChatCatalog, "the field runtime owns the shared word catalog before the map opens")
    local gearState = assert(runtime.pokegearState, "the field runtime owns Pokegear state")
    local binding, _ = bindHeadlessWordEditor(runtime)
    local unbind =
      assert(runtime.unbindEasyChatPreparation, "the field runtime releases the word editor preparation binding")

    openProductionMap(game)
    local function shellStatus()
      return assert(game.runtime.applicationHost:status().application, "the gear application owns the tick")
    end
    local worldBefore = shellStatus().child.view.world
    local marksBefore = wordSlots(gearState:capture().markings)
    local send = keySend(game)

    -- Ordinary UI enters marking mode on the retained map card: the
    -- first confirm enters the remembered card from the strip, the second
    -- confirm opens the marking session.
    send({ { type = "confirm" } })
    game:advanceUntil("the strip enters the remembered card", function()
      return shellStatus().entered == true
    end, FLOW_BUDGET)
    send({ { type = "confirm" } })
    game:advanceUntil("marking mode owns the map card", function()
      return shellStatus().child.view.mode == "marking" and shellStatus().busy ~= true
    end, FLOW_BUDGET)

    -- Confirming an empty word slot hands a real editor child to the
    -- shell: the child answers with the editor input key while the map
    -- underneath stays parked. The first key after the touch-first
    -- marking entry only reveals the key cursor.
    send({ { type = "navigate", direction = "right" } })
    for _ = 1, 3 do
      send({ { type = "navigate", direction = "right" } })
    end
    send({ { type = "confirm" } })
    game:advanceUntil("the shell owns the word editor child", function()
      return shellStatus().easyChat
    end, FLOW_BUDGET)
    local editor = shellStatus().easyChat
    Assert.equal(editor.uiInput, "easy-chat", "the editor child owns the display input key")
    Assert.equal(
      shellStatus().child.view.mode,
      "marking",
      "the map underneath stays in marking mode while the child owns display"
    )

    -- Choosing a word and confirming YES commits through the shell once
    -- the child exits; the retained world view never moves.
    local function editorStatus()
      return shellStatus().easyChat
    end
    waitReady(editorStatus, send)
    selectAnyWord(editorStatus, send)
    focusConfirm(send)
    send({ { type = "confirm" } })
    acceptAnswerPrompt(editorStatus, send)
    send({ { type = "confirm" } })
    game:advanceUntil("the shell closes the word editor child", function()
      return shellStatus().easyChat == nil
    end, EXIT_BUDGET)
    local marksAfter = wordSlots(gearState:capture().markings)
    local changed, changedCount = diffSlots(marksBefore, marksAfter)
    Assert.equal(changedCount, 1, "confirming YES commits exactly one annotation slot")
    local committed = nil
    for _, value in pairs(changed) do
      committed = value
    end
    Assert.isTrue(committed ~= nil and committed:match("^%d+$") ~= nil, "the committed word is one decimal identity")
    Assert.deepEqual(shellStatus().child.view.world, worldBefore, "the word return leaves the recorded world view")
    Assert.equal(shellStatus().child.view.mode, "marking", "the word return stays in marking mode")

    -- Cancelling a second slot writes nothing and returns the same way.
    for _ = 1, 2 do
      send({ { type = "navigate", direction = "left" } })
    end
    send({ { type = "confirm" } })
    game:advanceUntil("the shell owns the second word editor child", function()
      return shellStatus().easyChat
    end, FLOW_BUDGET)
    waitReady(editorStatus, send)
    send({ { type = "cancel" } })
    local cancelStatus = waitFor("asks to quit the second edit", editorStatus, send, function(s)
      return s.view.level == "prompt"
    end, FLOW_BUDGET)
    Assert.equal(cancelStatus.view.prompt.kind, "quit", "the second edit takes the quit path")
    send({ { type = "navigate", direction = "down" } })
    for _ = 1, 12 do
      send({})
    end
    Assert.equal(editorStatus().view.prompt.selected, "yes", "the quit choice toggles to YES")
    send({ { type = "confirm" } })
    game:advanceUntil("the shell closes the cancelled child", function()
      return shellStatus().easyChat == nil
    end, EXIT_BUDGET)
    Assert.deepEqual(
      wordSlots(gearState:capture().markings),
      marksAfter,
      "a cancelled edit preserves the committed word and writes nothing"
    )
    Assert.deepEqual(shellStatus().child.view.world, worldBefore, "the cancelled return leaves the recorded world view")

    -- Leave the marking session through the ordinary cancel path
    -- before closing: the strip close only owns the tick once the map
    -- card is back.
    send({ { type = "cancel" } })
    game:advanceUntil("the marking session returns to the map", function()
      return shellStatus().child.view.mode == "map" and shellStatus().busy ~= true
    end, FLOW_BUDGET)
    Fixture.closeGearThroughMenu(game)
    Fixture.saveAndReload(game)
    local reloaded = wordSlots(game.runtime.pokegearState:capture().markings)
    Assert.deepEqual(reloaded, marksAfter, "the save roundtrip retains the committed annotation")
    Assert.notNil(committed, "one word committed above")
    local tokens = catalog:wordTokens(tonumber(committed))
    Assert.isTrue(#tokens > 0, "the reloaded annotation resolves its display fragments")
    unbind(runtime, binding)
    Assert.equal(game:renderAttempts(), 0, "the map journey stops before GPU rendering")
  end)
end

-- Learned words and saved phrases survive an ordinary save roundtrip with
-- strict admission: a missing bucket initializes source defaults, unseen
-- species and move words stay out of their menus until their owners
-- change, learned flags and all five phrases persist, display resolution
-- ignores selection locks, and a malformed present bucket fails instead
-- of resetting.
function T.tests.learned_words_and_saved_phrases_survive_capture_reload_and_admission()
  Fixture.withGame(Fixture.TOWN, function(game)
    local State = requireFeature(
      "libs.hgss.src.save.EasyChatState",
      "the shared word state has no save owner yet: unlocks and phrases cannot persist"
    )
    local runtime = game.runtime
    local catalog =
      assert(runtime.easyChatCatalog, "the field runtime owns the shared word catalog before words are learned")
    local state = assert(runtime.easyChatState, "the field runtime restores the shared word state")
    local language = assert(runtime.monLanguage, "the field runtime knows its semantic language")

    local fresh = State.restore(nil, language, catalog)
    Assert.deepEqual(state:capture(), fresh:capture(), "a current save without the bucket matches source defaults")
    local locked = catalog:buildMenu({ gameCleared = false, seen = {}, greetings = 0, trendy = 0 })
    Assert.equal(#locked.groups, 12, "the menu keeps twelve categories before any progress")
    Assert.equal(#locked.groups[3].wordIds, 0, "move words wait for game clear")
    local cleared = catalog:buildMenu({ gameCleared = true, seen = {}, greetings = 0, trendy = 0 })
    Assert.isTrue(#cleared.groups[3].wordIds > 0, "cleared play offers move words")
    local withheld = cleared.groups[3].wordIds[1]
    Assert.isTrue(#catalog:wordTokens(withheld) > 0, "a withheld word still resolves its display fragments")

    state:learnGreeting(2)
    state:learnTrendy(7)
    local terminal = state:terminalGreeting()
    state:setTerminalGreeting(state:towerMessage(2))
    local reread = state:terminalGreeting()
    Assert.isTrue(reread.words[1] ~= terminal.words[1], "setting the terminal phrase replaces it")
    local before = state:capture()
    local unlocks = state:readUnlocks()
    local unlocked = catalog:buildMenu({
      gameCleared = true,
      seen = {},
      greetings = unlocks.greetings,
      trendy = unlocks.trendy,
    })
    Assert.equal(
      #unlocked.groups[11].wordIds,
      #locked.groups[11].wordIds + 1,
      "one learned trendy word joins its category"
    )

    game:setWorldState({ flag = FieldScriptSymbols.flagsByName.FLAG_GOT_SAVE_BUTTON })
    Fixture.saveAndReload(game)
    Assert.deepEqual(
      game.runtime.easyChatState:capture(),
      before,
      "the save roundtrip preserves unlocks and all five phrases"
    )

    local bad = {
      schema = "bogus-schema",
      greetings = 0,
      trendy = 0,
      towerMessages = before.towerMessages,
      terminalGreeting = before.terminalGreeting,
    }
    local ok = pcall(State.restore, bad, language, catalog)
    Assert.isFalse(ok, "a malformed present bucket fails admission without reset")
    Assert.equal(game:renderAttempts(), 0, "the save journey stops before GPU rendering")
  end)
end

return T
