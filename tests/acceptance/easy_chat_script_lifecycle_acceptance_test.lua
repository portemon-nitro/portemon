-- Script-owned editor lifecycle through the production field: while
-- the retail greeting interaction owns its editor child, implicit saves
-- refuse capture and held confirmation neither moves the player nor
-- answers anything; cancelling the owning script releases the child,
-- its capture, and its resource lease exactly once with no published
-- result; and a preparation failure propagates its original error while
-- retaining the last good scene. Every leg boots the real field runtime
-- over real maps, scripts, and state owners; only host audio, host input
-- snapshots, the wall clock, and the save root are recording
-- boundaries. No ROM text is asserted here and no host implementation
-- is faked.

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
local VAR_GREETING_RESULT = FieldScriptSymbols.variablesByName.VAR_SPECIAL_x8004

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
  local host = Drive.waitEditorOpen(game)
  local handle = assert(host:activeHandle(), "the open editor publishes its live child handle")
  Drive.waitEditorReady(game, host)
  return host, handle
end

-- While the editor owns the field, implicit saves refuse capture and
-- held confirmation moves nobody and answers nothing; once the child
-- returns, the save owner publishes again.
function T.tests.pending_editor_blocks_saves_and_owns_held_input()
  Fixture.withGame(Fixture.TOWN, function(game)
    Drive.requireScriptModules()
    local runtime = game.runtime
    assert(runtime.easyChatState, "the field runtime owns the saved word state")
    Assert.notNil(runtime:captureGameSave(), "a free field captures its implicit save")
    local binding, releases = Drive.bindHeadlessEditor(runtime)
    local unbind =
      assert(runtime.unbindEasyChatPreparation, "the field runtime releases the word editor preparation binding")

    local host, _ = openGreetingEditor(game)
    Assert.isNil(runtime:captureGameSave(), "a pending editor refuses implicit save capture")
    local before = game:snapshot().player
    game.runtime:pressAction("acceptance")
    for _ = 1, 30 do
      game:step()
    end
    local held = game:snapshot().player
    Assert.deepEqual(
      { held.fieldX, held.fieldZ, held.facing },
      { before.fieldX, before.fieldZ, before.facing },
      "held confirmation moves nobody while the editor owns input"
    )
    Assert.isTrue(host:isActive(), "held confirmation answers nothing on its own")
    Assert.isNil(host:result(host:activeHandle()), "held confirmation publishes no terminal result")
    game.runtime:releaseAction("acceptance")

    -- The held edge fires once on its first tick and opens the slot
    -- browser (the greeting sentence offers one field). Unwind to
    -- composition first; an already-open answer prompt stays put.
    game:advanceUntil("the held editor returns to composition", function()
      local level = assert(host:status(), "the held editor keeps its status").view.level
      if level == "composition" or level == "prompt" then
        return true
      end
      Drive.send(game, { { type = "cancel" } })
      return false
    end, 480)
    local heldStatus = assert(host:status(), "the held editor keeps its status")
    if heldStatus.view.level == "composition" then
      Drive.focusConfirm(game)
      Drive.send(game, { { type = "confirm" } })
    end
    Drive.acceptAnswerPrompt(game, host)
    game:advanceUntil("the greeting script releases the field", function(snapshot)
      if snapshot.dialogue.modal then
        game:pressAction()
        return false
      end
      return snapshot.foregroundScript == nil and not snapshot.fieldLocked and not snapshot.dialogue.modal
    end, 480)
    Assert.notNil(runtime:captureGameSave(), "the returned child hands the save owner back")
    unbind(runtime, binding)
    Assert.equal(releases(), 1, "the per-open lease releases exactly once")
    Assert.equal(game:renderAttempts(), 0, "the lifecycle journey stops before GPU rendering")
  end)
end

-- Cancelling the owning script while its editor is pending releases
-- the child, its capture, and its lease exactly once, publishes
-- nothing, and returns a free field.
function T.tests.cancelling_the_owner_releases_the_pending_editor_without_publishing()
  Fixture.withGame(Fixture.TOWN, function(game)
    Drive.requireScriptModules()
    local runtime = game.runtime
    assert(runtime.easyChatState, "the field runtime owns the saved word state")
    local binding, releases = Drive.bindHeadlessEditor(runtime)
    local unbind =
      assert(runtime.unbindEasyChatPreparation, "the field runtime releases the word editor preparation binding")

    local host, _ = openGreetingEditor(game)
    local scheduler = assert(runtime.scripts.scheduler, "the field owns its script scheduler")
    local environmentId = assert(scheduler:foregroundEnvironmentId(), "the greeting script owns the foreground")
    scheduler:cancelEnvironment(environmentId, "acceptance injected owner cancellation")
    game:advanceUntil("the cancelled owner releases the field", function(snapshot)
      return snapshot.foregroundScript == nil and not snapshot.fieldLocked
    end, 480)
    Assert.isFalse(host:isActive(), "cancellation releases the owned editor child")
    Assert.equal(
      runtime.scripts.worldState:getVar(VAR_GREETING_RESULT),
      0,
      "a cancelled owner publishes no greeting result"
    )
    Assert.notNil(runtime:captureGameSave(), "the released child hands the save owner back")
    unbind(runtime, binding)
    Assert.equal(releases(), 1, "cancellation releases the per-open lease exactly once")
    Assert.equal(Fixture.scriptFaults(game), 0, "an owner cancellation is not a script fault")
    Assert.equal(game:renderAttempts(), 0, "the lifecycle journey stops before GPU rendering")
  end)
end

-- A preparation failure is not a player cancel: the original error
-- propagates to the owning script, owned leases still release, and the
-- player stays where the last good scene left them.
function T.tests.preparation_failure_propagates_its_original_error()
  Fixture.withGame(Fixture.TOWN, function(game)
    Drive.requireScriptModules()
    local runtime = game.runtime
    assert(runtime.easyChatState, "the field runtime owns the saved word state")
    local releases = 0
    local bind = assert(runtime.bindEasyChatPreparation, "the field runtime binds the word editor preparation lease")
    local unbind =
      assert(runtime.unbindEasyChatPreparation, "the field runtime releases the word editor preparation binding")
    local binding = bind(runtime, function()
      return {
        prepare = function()
          error("acceptance injected editor preparation failure", 0)
        end,
        release = function()
          releases = releases + 1
        end,
      }
    end)
    local parked = game:snapshot().player

    game:startScript(GREETING_SCRIPT)
    game:advanceUntil("the greeting interaction locks the field", function(snapshot)
      return snapshot.fieldLocked
    end, 480)
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
    game:advanceUntil("the failed owner releases the field", function(snapshot)
      return snapshot.foregroundScript == nil and not snapshot.fieldLocked
    end, 480)
    local faults = Fixture.scriptFaults(game)
    Assert.isTrue(faults > 0, "a preparation failure faults its owning script")
    local found = false
    for _, record in ipairs(game:hostEvents().records) do
      if
        record.name == "script.error"
        and tostring(record.payload and record.payload.message):find(
          "acceptance injected editor preparation failure",
          1,
          true
        )
      then
        found = true
      end
    end
    Assert.isTrue(found, "the fault carries the original preparation error")
    local after = game:snapshot().player
    Assert.deepEqual(
      { after.fieldX, after.fieldZ },
      { parked.fieldX, parked.fieldZ },
      "the failed open retains the last good scene"
    )
    Assert.equal(
      runtime.scripts.worldState:getVar(VAR_GREETING_RESULT),
      0,
      "a failed open publishes no greeting result"
    )
    unbind(runtime, binding)
    Assert.equal(releases, 1, "the failed open still releases its lease exactly once")
    Assert.equal(game:renderAttempts(), 0, "the lifecycle journey stops before GPU rendering")
  end)
end

return T
