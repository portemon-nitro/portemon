-- The native battle outcome word beside the generic result. Every terminal
-- fact the hideout's electric trap battle can settle - win, loss, draw,
-- capture, player flight and foe flight - publishes its own native outcome
-- after the battle commits and the field returns, while the generic result, the
-- source won code and the authored source branch stay exactly as they were.
-- The render trap stays active throughout.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FieldBattleDriver = require("tests.acceptance.support.FieldBattleDriver")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    -- The failure branch runs the source whiteout, so the blackout destination
    -- (the player's house) is part of the journey's own derived closure.
    derivedAssets = { "field-runtime", "map-data:247", "map:247", "map-data:63", "map:63" },
    tags = { "field", "script", "battle", "rocket", "outcome" },
  },
  tests = {},
}

local HIDEOUT_MAP = "MAP_TEAM_ROCKET_HEADQUARTERS_B1F"
local TRAP_APPROACH_TILE = { fieldX = 13, fieldZ = 15 }
local TRAP_TILE = { fieldX = 13, fieldZ = 16 }
local TRAP_SCRIPT = "vanilla.hgss.scr_seq.0089.script_014"
-- The source failure branch's own conclusion: it runs the whiteout, so a
-- source-false trap outcome returns the player to the blackout destination
-- instead of leaving them on the hideout floor.
local BLACKOUT_MAP = "MAP_NEW_BARK_PLAYER_HOUSE_1F"
local TRAP_SPECIES = "VOLTORB"
local TRAP_VAR = FieldScriptSymbols.variablesByName.VAR_ROCKET_TRAP_VOLTORB_1

local function failureText(game, scriptId)
  local faults = game:recordsForScript(scriptId, "script.error")
  if #faults == 0 then
    return "no fault"
  end
  local payload = faults[1].payload or {}
  local context = payload.context or {}
  return tostring(payload.code) .. " (" .. tostring(context.command or context.originalName or "unknown") .. ")"
end

---@param prepare fun(game: table) party preparation for the leg under test
---@param choose fun(request: table<string, unknown>, turn: integer): table|table[]
---@return table committed battle result as the field publishes it
---@return table the booted acceptance game still owning the trap script
local function runTrapBattle(prepare, choose)
  local baseFactory = AcceptanceHarness.new().gameFactory
  local harness = AcceptanceHarness.new({
    gameFactory = function(versionId, requestedMap)
      local game = baseFactory(versionId, requestedMap)
      game.location.fieldX = TRAP_APPROACH_TILE.fieldX
      game.location.fieldZ = TRAP_APPROACH_TILE.fieldZ
      game.location.facing = "south"
      return game
    end,
  })
  local game
  local bootOk, bootErr = pcall(function()
    game = harness:boot({
      versionId = AcceptanceHarness.defaultVersion(),
      map = HIDEOUT_MAP,
      save = "fresh",
      fieldOptions = { recordingScriptHosts = true },
    })
    game:waitForFieldEntry()
  end)
  if not bootOk then
    if game ~= nil then
      pcall(game.close, game)
    end
    error("the hideout floor must construct every source actor before its scripts can run: " .. tostring(bootErr), 0)
  end
  local result
  local ran, err = xpcall(function()
    prepare(game)
    game:face("south")
    game:move("south")
    local stepped = game:advanceUntil("the trap step settles", function(snapshot)
      return snapshot.player.motion == "idle"
    end, 240)
    Assert.equal(stepped.player.fieldX, TRAP_TILE.fieldX, "the committed step lands on the source trap tile")
    Assert.equal(stepped.player.fieldZ, TRAP_TILE.fieldZ, "the committed step lands on the source trap tile")
    game:advanceUntil("the trap tile's own script starts", function()
      return #game:recordsForScript(TRAP_SCRIPT, "script.started") > 0
    end, 240)
    -- The trap script blocks on its own effect and battle, so the first
    -- observable boundary is either its fault or the battle handoff.
    game:advanceUntil("the trap script fights or reports", function()
      return #game:recordsForScript(TRAP_SCRIPT, "script.error") > 0
        or game.runtime.battleCoordinator:activeBattle() ~= nil
    end, 600)
    Assert.equal(
      #game:recordsForScript(TRAP_SCRIPT, "script.error"),
      0,
      "the source trap script completes its own operations: " .. failureText(game, TRAP_SCRIPT)
    )
    FieldBattleDriver.waitForLaunch(game, "the authored trap battle starts", 600)
    FieldBattleDriver.drive(game, choose)
    result = assert(game.runtime.battleCoordinator:lastBattleResult(), "the committed battle is readable")
  end, debug.traceback)
  if not ran then
    game:close()
    error(err, 0)
  end
  return result, game
end

-- The source 220 polarity: only a native loss or draw leaves the trap armed and
-- continues into the source failure branch; every other native outcome spends
-- the trap. The trap script jumps into that branch, so the branch's own whiteout
-- is its observable conclusion rather than a second script instance.
local function assertTrapSpent(game)
  game:advanceUntil("the source success branch settles the trap", function()
    return game.runtime.scripts.worldState:getVar(TRAP_VAR) == 1
  end, 480)
  Assert.equal(
    game:snapshot().mapSymbol,
    HIDEOUT_MAP,
    "a source-true battle outcome leaves the player on the hideout floor"
  )
end

local function assertTrapArmed(game)
  game:advanceUntil("the source failure branch blacks the player out", function(snapshot)
    return snapshot.mapSymbol == BLACKOUT_MAP
  end, 960)
  Assert.equal(
    game.runtime.scripts.worldState:getVar(TRAP_VAR),
    0,
    "a source-false battle outcome keeps the trap armed"
  )
  Assert.equal(
    #game:recordsForScript(TRAP_SCRIPT, "script.error"),
    0,
    "the trap script never faults through its failure branch"
  )
end

---@param label string leg name used in the failure diagnostics
---@param prepare fun(game: table)
---@param choose fun(request: table<string, unknown>, turn: integer): table|table[]
---@param expected { native: integer, word: string, source: integer, armed: boolean }
local function runLeg(label, prepare, choose, expected)
  local result, game = runTrapBattle(prepare, choose)
  local ok, err = xpcall(function()
    Assert.equal(
      result.nativeOutcome,
      expected.native,
      "the committed " .. label .. " publishes its native outcome word"
    )
    Assert.equal(result.result, expected.word, "the " .. label .. " keeps its generic battle result")
    Assert.equal(result.sourceResult, expected.source, "the " .. label .. " keeps its source won code")
    -- The trap's own source branch reads the native query, not the generic
    -- won code: only a native loss or draw leaves it armed.
    if expected.armed then
      assertTrapArmed(game)
    else
      assertTrapSpent(game)
    end
    Assert.equal(game:renderAttempts(), 0, "the outcome acceptance stops before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

local function giveLead(game, level, move)
  Assert.isTrue(
    game.runtime.monService:giveMon({ species = "CHIKORITA", level = level, form = 0, heldItem = "NONE" }),
    "the party lead enters through the production gift operation"
  )
  if move ~= nil then
    game.runtime.monService:setMove(0, 0, move)
  end
end

local function setLeadHitPoints(game, hp)
  local lead = assert(game.runtime.monService:removeMon(0), "the fixture party contains its prepared lead")
  lead.condition.currentHp = hp
  Assert.isTrue(game.runtime.monService:addMon(lead), "the prepared lead returns through the party owner")
end

local function strike(request)
  if request.kind == "learn_move" then
    return FieldBattleDriver.decline(request)
  end
  return FieldBattleDriver.strike(request)
end

function T.tests.native_win_outcome_coexists_with_the_generic_result()
  runLeg("win", function(game)
    giveLead(game, 60, "SWIFT")
  end, strike, { native = 1, word = "win", source = 1, armed = false })
end

function T.tests.native_loss_outcome_coexists_with_the_generic_result()
  runLeg("loss", function(game)
    giveLead(game, 5, "MEMENTO")
    setLeadHitPoints(game, 1)
  end, strike, { native = 2, word = "loss", source = 0, armed = true })
end

function T.tests.native_draw_outcome_coexists_with_the_generic_result()
  runLeg("draw", function(game)
    giveLead(game, 60, "EXPLOSION")
  end, strike, { native = 3, word = "draw", source = 0, armed = true })
end

function T.tests.native_capture_outcome_keeps_the_generic_capture_result()
  local foeCombatant = nil
  local partyBefore = nil
  local result, game = runTrapBattle(function(game_)
    giveLead(game_, 60, "SWIFT")
    Assert.isTrue(game_.runtime.bagService:add("MASTER_BALL", 2), "the trap journey stocks its guaranteed ball")
    partyBefore = game_.runtime.monService:partyCount()
    foeCombatant = partyBefore + 1
  end, function(request)
    if request.kind == "learn_move" then
      return FieldBattleDriver.decline(request)
    end
    local choices = {}
    for _, actor in ipairs(assert(request.actors, "a decision request names its actors")) do
      choices[#choices + 1] = {
        actor = actor,
        kind = "item",
        payload = { item = "MASTER_BALL", target = { kind = "combatant", combatant = foeCombatant } },
      }
    end
    return choices
  end)
  local ok, err = xpcall(function()
    Assert.equal(result.nativeOutcome, 4, "the committed capture publishes its native outcome word")
    Assert.equal(result.result, "capture", "the capture keeps its generic battle result")
    Assert.equal(result.sourceResult, 1, "a capture reports the source won code")
    Assert.equal(
      game.runtime.monService:partyCount(),
      partyBefore + 1,
      "the captured source trap Pokemon joins the live party through its owner"
    )
    Assert.equal(
      game.runtime.monService:partyMon(partyBefore).species,
      TRAP_SPECIES,
      "the trap battle launches the species its source script authored"
    )
    assertTrapSpent(game)
    Assert.equal(game:renderAttempts(), 0, "the outcome acceptance stops before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

function T.tests.native_player_flight_outcome_is_a_source_success()
  runLeg("player flight", function(game)
    giveLead(game, 60, "SWIFT")
  end, function(request)
    if request.kind == "learn_move" then
      return FieldBattleDriver.decline(request)
    end
    local choices = {}
    for _, actor in ipairs(assert(request.actors, "a decision request names its actors")) do
      choices[#choices + 1] = { actor = actor, kind = "run", payload = {} }
    end
    return choices
  end, { native = 5, word = "flee", source = 0, armed = false })
end

function T.tests.native_foe_flight_outcome_is_a_source_success()
  runLeg("foe flight", function(game)
    giveLead(game, 60, "ROAR")
  end, strike, { native = 6, word = "flee", source = 0, armed = false })
end

return T
