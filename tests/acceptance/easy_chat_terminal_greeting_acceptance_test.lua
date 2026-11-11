-- Global Terminal greeting through the production field: the actual
-- retail greeting interaction asks its question, opens the shared word
-- editor for the separate terminal phrase on YES, restores the field
-- itself, and persists acceptance distinctly from the Battle Tower
-- phrases across a save roundtrip. Cancellation writes zero and saves
-- nothing; unchanged acceptance still writes one. Every leg boots the
-- real field runtime over real maps, scripts, and state owners; only
-- host audio, host input snapshots, the wall clock, and the save root
-- are recording boundaries. No ROM text is asserted here and no editor
-- implementation is faked.

local Assert = require("tests.support.Assert")
local Fixture = require("tests.support.PokegearJourneyFixture")
local Drive = require("tests.support.EasyChatScriptDrive")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = (function()
      local assets = { "message-bank:600" }
      for _, asset in ipairs(Fixture.JOURNEY_ASSETS) do
        assets[#assets + 1] = asset
      end
      return assets
    end)(),
    tags = { "easychat" },
  },
  tests = {},
}

local GREETING_SCRIPT = "vanilla.hgss.scr_seq.0907.script_016"
local VAR_ANSWER = FieldScriptSymbols.variablesByName.VAR_SPECIAL_RESULT
local VAR_GREETING_RESULT = FieldScriptSymbols.variablesByName.VAR_SPECIAL_x8004

-- Answers the greeting question affirmatively: the retail question asks
-- through GetMenuChoice, so the opening say is dismissed first and the
-- default contextual row writes the source YES value.
---@param game table
local function answerYes(game)
  game:advanceUntil("the greeting question opens its choice", function()
    if game:contextChoiceStatus() ~= nil then
      return true
    end
    if game:snapshot().dialogue.modal then
      game:pressAction()
    end
    return false
  end, 480)
  Drive.send(game, { { type = "confirm" } })
  Assert.equal(
    game.runtime.scripts.worldState:getVar(VAR_ANSWER),
    0,
    "confirming the default choice answers YES with the source value"
  )
end

-- Runs the retail greeting interaction until its script-owned editor is
-- ready, answering YES on the way. Returns the host and its live child
-- handle.
---@param game table
---@return table host, unknown handle
local function openGreetingEditor(game)
  game:startScript(GREETING_SCRIPT)
  game:advanceUntil("the greeting interaction locks the field", function(snapshot)
    return snapshot.fieldLocked
  end, 480)
  answerYes(game)
  local host = Drive.waitEditorOpen(game)
  local handle = assert(host:activeHandle(), "the open editor publishes its live child handle")
  Drive.waitEditorReady(game, host)
  return host, handle
end

-- Settles the finished greeting script back to a free field, dismissing
-- its trailing retail say on the way.
---@param game table
local function settleScript(game)
  game:advanceUntil("the greeting script releases the field", function(snapshot)
    if snapshot.dialogue.modal then
      game:pressAction()
      return false
    end
    return snapshot.foregroundScript == nil and not snapshot.fieldLocked and not snapshot.dialogue.modal
  end, 480)
end

-- Accepting the greeting unchanged still writes one, restores the
-- field exactly once, and leaves every Battle Tower phrase alone.
function T.tests.accepting_the_greeting_unchanged_writes_one_and_restores()
  Fixture.withGame(Fixture.TOWN, function(game)
    Drive.requireScriptModules()
    local runtime = game.runtime
    local state = assert(runtime.easyChatState, "the field runtime owns the saved word state")
    local catalog = assert(runtime.easyChatCatalog, "the field runtime owns the shared word catalog")
    Assert.equal(
      catalog:messageStatus(state:terminalGreeting()),
      "complete",
      "the default terminal phrase is complete, so acceptance takes the answer path"
    )
    local before = state:capture()
    local binding, releases = Drive.bindHeadlessEditor(runtime)
    local unbind =
      assert(runtime.unbindEasyChatPreparation, "the field runtime releases the word editor preparation binding")

    local host, handle = openGreetingEditor(game)
    Drive.focusConfirm(game)
    Drive.send(game, { { type = "confirm" } })
    Drive.acceptAnswerPrompt(game, host)
    local result = Drive.takeResult(game, host, handle)
    Assert.isFalse(result.cancelled, "confirming YES accepts the greeting")
    Assert.isFalse(result.changed, "the untouched draft reports no change")
    Assert.deepEqual(result.message, before.terminalGreeting, "acceptance returns the terminal phrase")
    settleScript(game)
    Assert.equal(
      runtime.scripts.worldState:getVar(VAR_GREETING_RESULT),
      1,
      "an unchanged acceptance still writes the accepted result"
    )
    Assert.deepEqual(state:capture(), before, "an unchanged acceptance saves the same phrases back")
    unbind(runtime, binding)
    Assert.equal(releases(), 1, "the per-open lease releases exactly once")
    Assert.equal(game:renderAttempts(), 0, "the greeting journey stops before GPU rendering")
  end)
end

-- Cancelling the greeting writes zero, saves nothing, and still
-- restores the field to a free state.
function T.tests.cancelling_the_greeting_writes_zero_and_saves_nothing()
  Fixture.withGame(Fixture.TOWN, function(game)
    Drive.requireScriptModules()
    local runtime = game.runtime
    local state = assert(runtime.easyChatState, "the field runtime owns the saved word state")
    local before = state:capture()
    local binding, releases = Drive.bindHeadlessEditor(runtime)
    local unbind =
      assert(runtime.unbindEasyChatPreparation, "the field runtime releases the word editor preparation binding")

    local host, handle = openGreetingEditor(game)
    Drive.send(game, { { type = "cancel" } })
    local status = nil
    for _ = 1, 240 do
      status = host:status()
      if status ~= nil and status.view ~= nil and status.view.level == "prompt" then
        break
      end
      game:step()
    end
    status = assert(host:status(), "the cancelled edit answers with its quit prompt")
    Assert.equal(status.view.prompt.kind, "quit", "the cancel key takes the quit path")
    Drive.send(game, { { type = "navigate", direction = "down" } })
    for _ = 1, 12 do
      game:step()
    end
    Assert.equal(host:status().view.prompt.selected, "yes", "a vertical step toggles the quit choice")
    Drive.send(game, { { type = "confirm" } })
    local result = Drive.takeResult(game, host, handle)
    Assert.isTrue(result.cancelled, "quitting with YES cancels the greeting")
    Assert.isFalse(result.changed, "a cancelled greeting reports no change")
    settleScript(game)
    Assert.equal(
      runtime.scripts.worldState:getVar(VAR_GREETING_RESULT),
      0,
      "a cancelled greeting writes the cancelled result"
    )
    Assert.deepEqual(state:capture(), before, "a cancelled greeting saves nothing")
    unbind(runtime, binding)
    Assert.equal(releases(), 1, "the per-open lease releases exactly once")
    Assert.equal(game:renderAttempts(), 0, "the greeting journey stops before GPU rendering")
  end)
end

-- Editing the greeting persists the new terminal phrase across a save
-- roundtrip while every Battle Tower phrase stays exactly as it was.
function T.tests.editing_the_greeting_persists_across_save_and_reload()
  Fixture.withGame(Fixture.TOWN, function(game)
    Drive.requireScriptModules()
    local runtime = game.runtime
    local state = assert(runtime.easyChatState, "the field runtime owns the saved word state")
    local before = state:capture()
    local binding, releases = Drive.bindHeadlessEditor(runtime)
    local unbind =
      assert(runtime.unbindEasyChatPreparation, "the field runtime releases the word editor preparation binding")

    local host, handle = openGreetingEditor(game)
    local landed = false
    for _ = 1, 105 do
      Drive.send(game, { { type = "navigate", direction = "left" } })
      for _ = 1, 6 do
        game:step()
      end
      Drive.focusConfirm(game)
      Drive.send(game, { { type = "confirm" } })
      local status = nil
      for _ = 1, 240 do
        status = host:status()
        if status ~= nil and status.view ~= nil and status.view.level == "prompt" then
          break
        end
        game:step()
      end
      status = assert(host:status(), "the template draft answers with a prompt")
      if status.view.prompt.kind == "answer" then
        landed = true
        break
      end
      Drive.send(game, { { type = "confirm" } })
      game:advanceUntil("the notice dismisses back to composition", function()
        return host:status().view.level == "composition"
      end, 240)
    end
    Assert.isTrue(landed, "a changed template eventually completes its sentence")
    Assert.equal(host:status().view.prompt.selected, "yes", "the answer confirmation starts on YES")
    Drive.send(game, { { type = "confirm" } })
    local result = Drive.takeResult(game, host, handle)
    Assert.isFalse(result.cancelled, "confirming YES accepts the edited greeting")
    Assert.isTrue(result.changed, "switching the template counts as changed")
    Assert.isTrue(
      result.message.bank ~= before.terminalGreeting.bank or result.message.number ~= before.terminalGreeting.number,
      "the accepted greeting keeps its new template identity"
    )
    settleScript(game)
    Assert.equal(
      runtime.scripts.worldState:getVar(VAR_GREETING_RESULT),
      1,
      "an edited acceptance writes the accepted result"
    )
    local edited = state:capture()
    Assert.deepEqual(edited.towerMessages, before.towerMessages, "editing the greeting never moves tower phrases")
    Assert.deepEqual(edited.terminalGreeting, result.message, "the accepted greeting saves its terminal phrase")
    unbind(runtime, binding)
    Assert.equal(releases(), 1, "the per-open lease releases exactly once")

    game:setWorldState({ flag = FieldScriptSymbols.flagsByName.FLAG_GOT_SAVE_BUTTON })
    Fixture.saveAndReload(game)
    Assert.deepEqual(
      game.runtime.easyChatState:capture().terminalGreeting,
      edited.terminalGreeting,
      "the save roundtrip retains the edited terminal phrase"
    )
    Assert.deepEqual(
      game.runtime.easyChatState:capture().towerMessages,
      before.towerMessages,
      "the save roundtrip retains every tower phrase"
    )
    Assert.equal(game:renderAttempts(), 0, "the greeting journey stops before GPU rendering")
  end)
end

return T
