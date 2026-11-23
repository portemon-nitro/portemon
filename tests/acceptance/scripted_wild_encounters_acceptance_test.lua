-- Scripted wild encounters through the real field composition. The Lake of
-- Rage source script reaches its authored wild launch, and the native result
-- queries it then runs report the committed raw outcome word for a defeat, a
-- capture, a player flight and a foe flight, with the authored success and
-- failure branches following that word only after the battle commits. The same
-- launch materializes the source's forced-shiny identity once, drawn from the
-- world stream, and that identity survives Continue. Only the audio, fade and
-- clock host boundaries are recorded; maps, scripts, actors, launches and saves
-- stay production-owned, and the render trap stays active throughout.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FieldBattleDriver = require("tests.acceptance.support.FieldBattleDriver")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local Personality = require("libs.mons.src.gen4.Personality")
local SessionFixture = require("libs.battle.tests.session_fixture")

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    -- The shared field runtime, the Lake of Rage map with its message bank, and
    -- the resident physical-cell window the shore spawn is placed inside
    -- (including Route 45's own neighbouring cells).
    derivedAssets = {
      "field-runtime",
      "map:88",
      "map-data:88",
      "message-bank:626",
      "map:45",
      "map-data:45",
      "field-cell:0-14",
      "field-cell:0-15",
      "field-cell:0-16",
      "field-cell:0-17",
      "field-cell:0-18",
      "field-cell:0-61",
      "field-cell:0-62",
      "field-cell:0-63",
      "field-cell:0-64",
      "field-cell:0-65",
      "field-cell:0-108",
      "field-cell:0-109",
      "field-cell:0-110",
      "field-cell:0-111",
      "field-cell:0-112",
      "field-cell:0-155",
      "field-cell:0-156",
      "field-cell:0-157",
      "field-cell:0-158",
      "field-cell:0-159",
      "field-cell:0-202",
      "field-cell:0-203",
      "field-cell:0-204",
      "field-cell:0-205",
      "field-cell:0-206",
    },
    tags = { "field", "script", "battle", "encounter" },
  },
  tests = {},
}

-- MAP_LAKE_OF_RAGE's own coordinate origin; a finalized new-game location is
-- local to it, so the scenario states its tiles globally and converts here.
local LAKE_OF_RAGE = "MAP_LAKE_OF_RAGE"
local LAKE_OF_RAGE_ORIGIN = { x = 512, z = 32 }
-- The red Gyarados object stands on the lake at (525,71); the scenario stands
-- on the water tile below it and faces north into the object.
local GYARADOS_APPROACH = { fieldX = 525, fieldZ = 72, facing = "north" }
local GYARADOS_SCRIPT = "vanilla.hgss.scr_seq.0938.script_001"
-- The species and level that script's own launch operand names.
local GYARADOS_SPECIES = "GYARADOS"
local GYARADOS_LEVEL = 30

local RESULT_VAR = assert(FieldScriptSymbols.variablesByName.VAR_SPECIAL_RESULT)
local OUTCOME_VAR = assert(FieldScriptSymbols.variablesByName.VAR_TEMP_x4002)
local RED_SCALE_FLAG = assert(FieldScriptSymbols.flagsByName.FLAG_GOT_RED_SCALE)
local CAUGHT_GYARADOS_FLAG = assert(FieldScriptSymbols.flagsByName.FLAG_CAUGHT_RED_GYARADOS)

-- The two source variables the driven script writes after its battle, seeded
-- before the launch so "not published yet" is distinguishable from the source's
-- own zero, plus a world variable that script never writes as the control.
local SENTINEL = 4242
local SENTINEL_VAR = assert(FieldScriptSymbols.variablesByName.VAR_UNK_40A1)

---@param lead { species: string, level: integer, move: string }
---@return AcceptanceHarness
local function harnessWithLead(lead)
  local baseFactory = AcceptanceHarness.new().gameFactory
  return AcceptanceHarness.new({
    gameFactory = function(versionId, map)
      local worldState = FieldEventState.new()
      worldState:setVar(SENTINEL_VAR, SENTINEL)
      worldState:setVar(RESULT_VAR, SENTINEL)
      worldState:setVar(OUTCOME_VAR, SENTINEL)
      local game = baseFactory(versionId, map)
      game.location = {
        mapSymbol = LAKE_OF_RAGE,
        fieldX = GYARADOS_APPROACH.fieldX - LAKE_OF_RAGE_ORIGIN.x,
        fieldZ = GYARADOS_APPROACH.fieldZ - LAKE_OF_RAGE_ORIGIN.z,
        facing = GYARADOS_APPROACH.facing,
      }
      game.worldState = worldState
      game.lead = lead
      return game
    end,
  })
end

-- Boots the Lake of Rage shore with one prepared party lead and returns the
-- live acceptance game.
---@param lead { species: string, level: integer, move: string, ability: string? }
---@return table game
local function bootLakeOfRage(lead)
  local game = harnessWithLead(lead):boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = LAKE_OF_RAGE,
    save = "fresh",
    fieldOptions = { recordingScriptHosts = true, audioHost = "recording" },
  })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    Assert.isTrue(
      game.runtime.monService:giveMon({
        species = lead.species,
        level = lead.level,
        form = 0,
        heldItem = "NONE",
        ability = lead.ability,
      }),
      "the prepared lead enters through the production gift operation"
    )
    game.runtime.monService:setMove(0, 0, lead.move)
    game:waitForFieldReady(480)
  end, debug.traceback)
  if not ok then
    game:close()
    error(err, 0)
  end
  return game
end

---@param game table acceptance game owning the production field runtime
---@param scriptId string canonical source script identity under test
---@return string[] faults the script published
local function faultsFor(game, scriptId)
  local faults = {}
  for _, record in ipairs(game:recordsForScript(scriptId, "script.error")) do
    local payload = record.payload or {}
    local context = payload.context or {}
    faults[#faults + 1] = string.format(
      "%s/%s/%s",
      tostring(payload.code),
      tostring(context.command or context.originalName or "unknown"),
      tostring(payload.message)
    )
  end
  return faults
end

---@param game table acceptance game owning the production field runtime
---@param scriptId string canonical source script identity under test
local function assertScriptClean(game, scriptId)
  local faults = faultsFor(game, scriptId)
  Assert.equal(#faults, 0, "the source script completes its own native operations: " .. table.concat(faults, ","))
end

-- One semantic driver for a launched source battle: it answers every open
-- decision through the caller's choice factory and advances the fixed tick
-- until the battle application releases the field.
---@param game table acceptance game owning the production field runtime
---@param choose fun(request: table): table[] player decisions for one request
local function fight(game, choose)
  local answered = nil
  for _ = 1, 4000 do
    local battle = game.runtime.battleCoordinator:activeBattle()
    if battle == nil then
      return
    end
    local status = battle:status()
    if status.phase == "failed" then
      error("the field battle application failed: " .. tostring(status.error), 0)
    end
    if status.phase == "running" and status.request ~= nil and status.request.requestId ~= answered then
      answered = status.request.requestId
      local request = status.request
      local choices = choose(request)
      Assert.equal(#choices, #request.actors, "every addressed combatant answers exactly once")
      Assert.isTrue(
        battle:submit(SessionFixture.replyFor(request, choices)),
        "the production battle accepts the semantic decision"
      )
    end
    game:step()
  end
  error("the field battle application did not release the field", 0)
end

local function strike(request)
  local choices = {}
  for _, actor in ipairs(assert(request.actors, "a decision request names its actors")) do
    choices[#choices + 1] =
      SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(FieldBattleDriver.FOE_POSITION))
  end
  return choices
end

local function runAway(request)
  local choices = {}
  for _, actor in ipairs(assert(request.actors, "a decision request names its actors")) do
    choices[#choices + 1] = { actor = actor, kind = "run", payload = {} }
  end
  return choices
end

local function throwBall(request)
  local choices = {}
  for _, actor in ipairs(assert(request.actors, "a decision request names its actors")) do
    choices[#choices + 1] = {
      actor = actor,
      kind = "item",
      payload = { item = "MASTER_BALL", target = { kind = "combatant", combatant = FieldBattleDriver.FOE_POSITION } },
    }
  end
  return choices
end

-- A battle that awards experience may also offer a learned move; declining
-- keeps the fixture party independent of that flow.
local function withDeclines(choices)
  return function(request)
    if request.kind == "learn_move" then
      return FieldBattleDriver.decline(request)
    end
    return choices(request)
  end
end

---@param game table acceptance game owning the production field runtime
---@param label string boundary description
---@return table snapshot at the settled field
local function settle(game, label)
  return game:advanceUntil(label, function(snapshot)
    if snapshot.dialogue.modal then
      game:pressAction()
    end
    return snapshot.foregroundScript == nil and not snapshot.fieldLocked and not snapshot.dialogue.modal
  end, 2400)
end

-- Starts the red Gyarados' own source interaction and returns once the battle
-- that script authored is running.
---@param game table
---@return table the launched battle application lifetime
local function launchGyarados(game)
  game:face("north")
  game:pressAction()
  game:advanceUntil("the red Gyarados script starts", function()
    return #game:recordsForScript(GYARADOS_SCRIPT, "script.started") > 0
  end, 240)
  if game:snapshot().dialogue.modal then
    game:pressAction()
  end
  return FieldBattleDriver.waitForLaunch(game, "the red Gyarados battle starts", 900)
end

---@param game table
---@return table receipt the published battle result
local function committedResult(game)
  local receipt = assert(game.runtime.battleCoordinator:lastBattleResult(), "the battle published its result")
  Assert.isTrue(type(receipt.nativeOutcome) == "number", "the committed result carries its native outcome word")
  return receipt
end

-- The source's own launch and its two result queries: the authored wild battle
-- runs, then the source asks whether the encounter was won and which raw outcome
-- word it settled on, and its authored branches follow only that word.
---@param label string leg name used in diagnostics
---@param lead { species: string, level: integer, move: string }
---@param choose fun(request: table): table[]
---@param prepare fun(game: table)? extra bag preparation for the leg
---@param expected { native: integer, caught: boolean, scale: boolean }
local function runLakeLeg(label, lead, choose, prepare, expected)
  local game = bootLakeOfRage(lead)
  local ok, err = xpcall(function()
    if prepare ~= nil then
      prepare(game)
    end
    launchGyarados(game)
    -- Before the commit the source queries have not run: the seeded sentinels
    -- are untouched and no authored branch has published.
    Assert.equal(
      game.runtime.scripts.worldState:getVar(SENTINEL_VAR),
      SENTINEL,
      "the script does not publish a branch while its battle is still live: " .. label
    )
    Assert.equal(
      game.runtime.scripts.worldState:getVar(OUTCOME_VAR),
      SENTINEL,
      "the source outcome query stays unpublished until the battle commits: " .. label
    )
    Assert.equal(
      game.runtime.scripts.worldState:getVar(RESULT_VAR),
      SENTINEL,
      "the source won query stays unpublished until the battle commits: " .. label
    )
    fight(game, choose)
    local receipt = committedResult(game)
    Assert.equal(
      receipt.nativeOutcome,
      expected.native,
      "the committed "
        .. label
        .. " publishes its native word (published "
        .. tostring(receipt.nativeOutcome)
        .. ", expected "
        .. tostring(expected.native)
        .. ")"
    )
    settle(game, "the red Gyarados script settles after the " .. label)
    assertScriptClean(game, GYARADOS_SCRIPT)
    -- The source reuses VAR_SPECIAL_RESULT after its won query: the authored
    -- Red Scale branch asks whether the bag has space and then runs the item
    -- gift, whose own pocket query writes this same variable. It is therefore
    -- a branch input, not a stable post-battle mirror, so the leg proves the
    -- query ran (the seeded sentinel is gone) and lets the authored branches
    -- below carry the polarity.
    Assert.isTrue(
      game.runtime.scripts.worldState:getVar(RESULT_VAR) ~= SENTINEL,
      "the source won query publishes into its authored variable after the " .. label
    )
    Assert.equal(
      game.runtime.scripts.worldState:getVar(OUTCOME_VAR),
      expected.native,
      "the source outcome query reports the committed raw word after the " .. label
    )
    Assert.equal(
      game.runtime.scripts.worldState:isFlagSet(CAUGHT_GYARADOS_FLAG),
      expected.caught,
      "the authored capture branch follows the committed word after the " .. label
    )
    Assert.equal(
      game.runtime.scripts.worldState:isFlagSet(RED_SCALE_FLAG),
      expected.scale,
      "the authored reward branch follows the committed word after the " .. label
    )
    Assert.equal(game:renderAttempts(), 0, "the encounter acceptance stops before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

function T.tests.scripted_wild_defeat_reports_the_win_word_and_its_reward_branch()
  runLakeLeg("defeat", { species = "TYPHLOSION", level = 100, move = "DRAGON_RAGE" }, withDeclines(strike), nil, {
    native = 1,
    caught = false,
    scale = true,
  })
end

function T.tests.scripted_wild_capture_reports_the_captured_word_and_its_capture_branch()
  runLakeLeg(
    "capture",
    { species = "TYPHLOSION", level = 100, move = "DRAGON_RAGE" },
    withDeclines(throwBall),
    function(game)
      Assert.isTrue(game.runtime.bagService:add("MASTER_BALL", 1), "the journey stocks its guaranteed ball")
    end,
    -- The authored script grants the Red Scale on a capture too: it sets the
    -- caught flag first and only skips the gift when the scale was already
    -- obtained.
    { native = 4, caught = true, scale = true }
  )
end

function T.tests.scripted_wild_player_flight_reports_the_player_fled_word()
  runLakeLeg("player flight", { species = "TYPHLOSION", level = 100, move = "DRAGON_RAGE" }, withDeclines(runAway), nil, {
    native = 5,
    caught = false,
    scale = true,
  })
end

function T.tests.scripted_wild_foe_flight_reports_the_foe_fled_word()
  -- Roar forces the opposing side out, so the source answers a foe flight
  -- rather than a player one.
  runLakeLeg("foe flight", { species = "TYPHLOSION", level = 100, move = "ROAR" }, withDeclines(strike), nil, {
    native = 6,
    caught = false,
    scale = true,
  })
end

-- ---------------------------------------------------------------------------
-- The source's forced shiny identity: the authored launch materializes the foe
-- once from the world stream. The captured foe is shiny by the source's own
-- trainer/personality rule, it carries the authored species and level, and the
-- identity is what the same restored journey draws again - so the palette comes
-- from the drawn identity, not from a cosmetic flag or an individual-value
-- retry, and the party lead's ability never enters the scripted construction.
-- ---------------------------------------------------------------------------

---@param mon table captured mon record as the party owner publishes it
---@return table identity the identity facts the scenario compares
local function identityOf(mon)
  return {
    species = mon.species,
    personality = mon.personality,
    heldItem = mon.heldItem,
    ivs = mon.ivs,
    level = assert(mon.met, "a captured mon records where it was met").level,
    shiny = Personality.shiny(mon.origin.trainerId, mon.personality),
  }
end

---@param lead { species: string, level: integer, move: string, ability: string? }
---@return table identity the captured source foe's identity facts
local function captureGyarados(lead)
  local game = bootLakeOfRage(lead)
  local identity
  local ok, err = xpcall(function()
    Assert.isTrue(game.runtime.bagService:add("MASTER_BALL", 1), "the journey stocks its guaranteed ball")
    launchGyarados(game)
    fight(game, withDeclines(throwBall))
    local receipt = committedResult(game)
    Assert.equal(receipt.nativeOutcome, 4, "the source foe is captured")
    settle(game, "the red Gyarados script settles after the capture")
    local party = game.runtime.monService
    local slot = assert(party:partyCount() > 0 and party:partyMon(party:partyCount() - 1), "the captured foe joined the party")
    Assert.equal(party:partyMon(0).species, lead.species, "the captured foe never replaces the prepared lead")
    identity = identityOf(party:partyMon(party:partyCount() - 1))
    Assert.equal(identity.species, GYARADOS_SPECIES, "the launch materializes the species its source operand names")
    Assert.equal(identity.level, GYARADOS_LEVEL, "the launch materializes the level its source operand names")
    Assert.isTrue(identity.shiny, "the forced source identity is shiny by its trainer/personality rule")
    for name, value in pairs(identity.ivs) do
      Assert.isTrue(
        type(value) == "number" and value >= 0 and value <= 31,
        "the forced source identity keeps individual value " .. tostring(name) .. " in range"
      )
    end
    assertScriptClean(game, GYARADOS_SCRIPT)
    -- Continue: the captured identity is persisted owner state, not a live
    -- launch artifact.
    game:save()
    game:restart()
    local restored = assert(game.runtime.monService:partyMon(party:partyCount() - 1), "the captured foe survives Continue")
    Assert.deepEqual(identityOf(restored), identity, "Continue restores the captured source identity unchanged")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
  return identity
end

function T.tests.source_forced_shiny_identity_is_drawn_once_and_survives_continue()
  local first = captureGyarados({ species = "TYPHLOSION", level = 100, move = "DRAGON_RAGE" })
  -- The same restored journey state draws the same identity: the launch
  -- consumes the source stream in a fixed order, so the palette and the
  -- individual values are its own creation and no retry re-rolls them.
  local second = captureGyarados({ species = "TYPHLOSION", level = 100, move = "DRAGON_RAGE" })
  Assert.deepEqual(second, first, "the same journey state draws the same forced source identity")
  -- A synchronizing lead never enters the scripted construction: the identity
  -- is identical to the one drawn without it.
  local withLeadAbility = captureGyarados({
    species = "ABRA",
    level = 20,
    move = "DRAGON_RAGE",
    ability = "SYNCHRONIZE",
  })
  Assert.deepEqual(withLeadAbility, first, "a lead ability never rewrites the scripted source identity")
end

return T
