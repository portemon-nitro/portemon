-- Rocket HQ traps. The original hideout map binds each trap tile to its own
-- source script: the trap sound, the trap model effect and the authored trap
-- battle, after which the committed battle result decides whether the trap is
-- spent or the source failure branch runs. The hideout's alarm background event
-- runs the source siren operation before its trainer engagement, and the B2F
-- floor projects the powered prop animation set on its own map entry. The
-- render trap stays active throughout: only logical field and battle state is
-- observed.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FieldBattleDriver = require("tests.acceptance.support.FieldBattleDriver")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = {
      "field-runtime",
      "map-data:247",
      "map:247",
      "map-data:248",
      "map:248",
      "message-bank:112",
    },
    tags = { "field", "script", "battle", "rocket" },
  },
  tests = {},
}

local HIDEOUT_MAP = "MAP_TEAM_ROCKET_HEADQUARTERS_B1F"
local PROP_MAP = "MAP_TEAM_ROCKET_HEADQUARTERS_B2F"
local FAILURE_SCRIPT = "vanilla.hgss.scr_seq.0089.script_028"
local POWER_PROP_SCRIPT = "vanilla.hgss.scr_seq.0090.script_002"
local ALARM_SCRIPT = "vanilla.hgss.scr_seq.0089.script_005"
-- The alarm cutscene is the source's own one-shot coordinate event on the
-- hideout floor: stepping onto the alarm tile starts the script that plays the
-- siren, blocks on the alarm operation, wipes the room and then engages its
-- trainers. Its event variable is spent by the scene itself, so the scene runs
-- once per save.
local ALARM_APPROACH_TILE = { fieldX = 18, fieldZ = 5 }
local SIREN_SOUND = "SEQ_SE_GS_AJITO_SIREN"

-- The three source trap families the hideout tiles script. Each entry is one
-- real coordinate event: its approach tile, trap tile, script identity, source
-- sound, authored battle species and the source variable the success branch
-- writes.
local TRAPS = {
  {
    approach = { fieldX = 13, fieldZ = 15 },
    tile = { fieldX = 13, fieldZ = 16 },
    scriptId = "vanilla.hgss.scr_seq.0089.script_014",
    sound = "SEQ_SE_GS_DENKI_TRAP",
    species = "VOLTORB",
    spentVar = FieldScriptSymbols.variablesByName.VAR_ROCKET_TRAP_VOLTORB_1,
  },
  {
    approach = { fieldX = 12, fieldZ = 16 },
    tile = { fieldX = 12, fieldZ = 17 },
    scriptId = "vanilla.hgss.scr_seq.0089.script_013",
    sound = "SEQ_SE_GS_DOKU_TRAP",
    species = "KOFFING",
    spentVar = FieldScriptSymbols.variablesByName.VAR_ROCKET_TRAP_KOFFING_1,
  },
  {
    approach = { fieldX = 15, fieldZ = 15 },
    tile = { fieldX = 15, fieldZ = 16 },
    scriptId = "vanilla.hgss.scr_seq.0089.script_015",
    sound = "SEQ_SE_GS_IWA_TRAP",
    species = "GEODUDE",
    spentVar = FieldScriptSymbols.variablesByName.VAR_ROCKET_TRAP_GEODUDE_1,
  },
}

local OTHER_TRAP_SPECIES = { VOLTORB = true, KOFFING = true, GEODUDE = true }

---@param map string|nil map the acceptance field boots on
---@param position { fieldX: integer, fieldZ: integer, facing: string }|nil
---@return table booted acceptance game
local function boot(map, position)
  local options = {
    versionId = AcceptanceHarness.defaultVersion(),
    map = map,
    save = "fresh",
    fieldOptions = { recordingScriptHosts = true },
  }
  local harness
  if position ~= nil then
    local baseFactory = AcceptanceHarness.new().gameFactory
    harness = AcceptanceHarness.new({
      gameFactory = function(versionId, requestedMap)
        local game = baseFactory(versionId, requestedMap)
        game.location.fieldX = position.fieldX
        game.location.fieldZ = position.fieldZ
        game.location.facing = position.facing
        return game
      end,
    })
  else
    harness = AcceptanceHarness.new()
  end
  local game
  local ok, err = pcall(function()
    game = harness:boot(options)
    game:waitForFieldEntry()
  end)
  if not ok then
    if game ~= nil then
      pcall(game.close, game)
    end
    error("the hideout floor must construct every source actor before its scripts can run: " .. tostring(err), 0)
  end
  return game
end

local function failureText(game, scriptId)
  local faults = game:recordsForScript(scriptId, "script.error")
  if #faults == 0 then
    return "no fault"
  end
  local payload = faults[1].payload or {}
  local context = payload.context or {}
  return tostring(payload.code)
    .. " ("
    .. tostring(context.command or context.originalName or "unknown")
    .. ": "
    .. tostring(payload.message)
    .. ")"
end

local function effectIndex(game, entry)
  for index, effect in ipairs(game:hostEffects()) do
    if effect == entry then
      return index
    end
  end
  return nil
end

-- A strong lead survives every source trap encounter; the first slot carries an
-- always-hitting move so the outcome never depends on an accuracy draw.
local function giveWinningLead(game)
  Assert.isTrue(
    game.runtime.monService:giveMon({ species = "CHIKORITA", level = 60, form = 0, heldItem = "NONE" }),
    "the party lead enters through the production gift operation"
  )
  game.runtime.monService:setMove(0, 0, "SWIFT")
end

local function strikeAndDecline(request)
  if request.kind == "learn_move" then
    return FieldBattleDriver.decline(request)
  end
  return FieldBattleDriver.strike(request)
end

-- One real committed step onto the trap tile starts the tile's own script.
---@param game table booted acceptance game
---@param trap table source trap under test
local function stepOntoTrap(game, trap)
  game:face("south")
  game:move("south")
  local stepped = game:advanceUntil("the trap step settles", function(snapshot)
    return snapshot.player.motion == "idle"
  end, 240)
  Assert.equal(stepped.player.fieldX, trap.tile.fieldX, "the committed step lands on the source trap tile")
  Assert.equal(stepped.player.fieldZ, trap.tile.fieldZ, "the committed step lands on the source trap tile")
  game:advanceUntil("the trap tile's own script starts", function()
    return #game:recordsForScript(trap.scriptId, "script.started") > 0
  end, 240)
  -- The trap script blocks on its own effect and battle, so the first
  -- observable boundary is either its fault or the battle handoff.
  game:advanceUntil("the trap script fights or reports", function()
    return #game:recordsForScript(trap.scriptId, "script.error") > 0
      or game.runtime.battleCoordinator:activeBattle() ~= nil
  end, 600)
  Assert.equal(
    #game:recordsForScript(trap.scriptId, "script.error"),
    0,
    "the source trap script completes its own operations: " .. failureText(game, trap.scriptId)
  )
end

---@param trap table source trap under test
local function assertTrapJourney(trap)
  local game = boot(HIDEOUT_MAP, { fieldX = trap.approach.fieldX, fieldZ = trap.approach.fieldZ, facing = "south" })
  local ok, err = xpcall(function()
    giveWinningLead(game)
    stepOntoTrap(game, trap)

    game:advanceUntil("the trap sound plays", function()
      return effectIndex(game, "audio:" .. trap.sound) ~= nil
    end, 240)
    local soundPosition = assert(effectIndex(game, "audio:" .. trap.sound), "the source trap sound plays")

    FieldBattleDriver.waitForLaunch(game, "the authored trap battle starts", 600)
    Assert.isTrue(soundPosition <= #game:hostEffects(), "the trap effect and its source sound precede the trap battle")

    FieldBattleDriver.drive(game, strikeAndDecline)

    local result = assert(game.runtime.battleCoordinator:lastBattleResult(), "the committed battle is readable")
    Assert.equal(result.nativeOutcome, 1, "the committed trap battle publishes the native win outcome word")
    Assert.equal(result.result, "win", "the generic battle result is unchanged")
    Assert.equal(result.sourceResult, 1, "the source won code is unchanged")

    game:advanceUntil("the won trap settles", function()
      return #game:recordsForScript(trap.scriptId, "script.ended") > 0
    end, 480)
    Assert.equal(game:snapshot().mapSymbol, HIDEOUT_MAP, "a won trap battle leaves the player on the hideout floor")
    Assert.equal(
      game.runtime.scripts.worldState:getVar(trap.spentVar),
      1,
      "the source success branch marks the trap spent"
    )
    Assert.equal(
      #game:recordsForScript(FAILURE_SCRIPT, "script.started"),
      0,
      "the source failure branch never runs after a won trap battle"
    )
    Assert.equal(
      #game:recordsForScript(trap.scriptId, "script.started"),
      1,
      "the trap publishes one script instance, never a duplicate"
    )
    local dex = assert(game.runtime.dexKnowledge, "the trap journey needs its live dex knowledge")
    Assert.isTrue(dex:isSeen(trap.species), "the trap battle launches the species its source script authored")
    for species in pairs(OTHER_TRAP_SPECIES) do
      if species ~= trap.species then
        Assert.isFalse(dex:isSeen(species), "the trap battle launches no other trap species")
      end
    end
    Assert.equal(game:renderAttempts(), 0, "the trap acceptance stops before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

function T.tests.electric_trap_tile_plays_the_source_trap_and_its_authored_battle()
  assertTrapJourney(TRAPS[1])
end

function T.tests.poison_trap_tile_plays_the_source_trap_and_its_authored_battle()
  assertTrapJourney(TRAPS[2])
end

function T.tests.rock_trap_tile_plays_the_source_trap_and_its_authored_battle()
  assertTrapJourney(TRAPS[3])
end

-- The hideout alarm runs the source cutscene, which plays the siren and then
-- blocks on the alarm operation before its own trainer engagement.
function T.tests.alarm_scene_runs_the_source_siren_before_its_trainer_engagement()
  local game = boot(HIDEOUT_MAP, {
    fieldX = ALARM_APPROACH_TILE.fieldX,
    fieldZ = ALARM_APPROACH_TILE.fieldZ,
    facing = "north",
  })
  local ok, err = xpcall(function()
    game:face("north")
    game:move("north")
    local stepped = game:advanceUntil("the alarm step settles", function(snapshot)
      return snapshot.player.motion == "idle"
    end, 240)
    Assert.equal(stepped.player.fieldZ, ALARM_APPROACH_TILE.fieldZ - 1, "the step enters the alarm tile")
    game:advanceUntil("the alarm script starts", function()
      return #game:recordsForScript(ALARM_SCRIPT, "script.started") > 0
    end, 240)
    game:advanceUntil("the alarm sound plays", function()
      return effectIndex(game, "audio:" .. SIREN_SOUND) ~= nil
    end, 600)
    local soundPosition = assert(effectIndex(game, "audio:" .. SIREN_SOUND), "the source siren plays")

    -- The alarm operation is blocking: the cutscene's own message only appears
    -- once it completes, so the message is the source wait boundary.
    game:advanceUntil("the alarm operation completes", function(snapshot)
      return snapshot.dialogue.modal
    end, 600)
    Assert.isTrue(#game:hostEffects() > soundPosition, "the alarm operation runs after its source siren")
    Assert.equal(
      #game:recordsForScript(ALARM_SCRIPT, "script.error"),
      0,
      "the source alarm script completes its own operations: " .. failureText(game, ALARM_SCRIPT)
    )

    -- Cancelling the cutscene releases everything the alarm claimed: ordinary
    -- field input returns and no field-level fault is recorded.
    local scheduler = game.runtime.scripts.scheduler
    local environmentId = assert(scheduler:foregroundEnvironmentId(), "the alarm cutscene owns the field")
    scheduler:cancelEnvironment(environmentId, "acceptance cancels the alarm cutscene")
    -- A cancelled script never reaches its own close-message step, so the
    -- field's dialogue owner releases the window it left open.
    game.runtime.dialogue:close(true)
    game:waitForFieldReady()
    Assert.isFalse(game:snapshot().fieldLocked, "cancelling the alarm returns ordinary field input")
    Assert.equal(game:renderAttempts(), 0, "the alarm acceptance stops before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

function T.tests.hideout_power_props_project_from_the_source_flags_on_entry()
  local game = boot(PROP_MAP, { fieldX = 20, fieldZ = 20, facing = "south" })
  local ok, err = xpcall(function()
    Assert.equal(
      #game:recordsForScript(POWER_PROP_SCRIPT, "script.error"),
      0,
      "the map's own power-prop projection completes: " .. failureText(game, POWER_PROP_SCRIPT)
    )
    Assert.equal(
      #game:recordsForScript(POWER_PROP_SCRIPT, "script.started"),
      1,
      "the source power-prop init script runs once on entry"
    )
    Assert.equal(game:renderAttempts(), 0, "the prop acceptance stops before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

return T
