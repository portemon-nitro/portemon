-- Sinjoh's Mystri Stage through the production field composition. The map's
-- own stage scene initializes the three stage models with an unresolved choice,
-- each of the stage's coordinate events runs the source script for the creature
-- standing there, and that script plays the Unown circle, the Arceus cinematic
-- and the gift continuation before it hands over the source creature with its
-- orb. The chosen legend is a persisted part of the field's gym-mechanism union,
-- so it survives Continue; the gift happens exactly once per scene run and the
-- committed creature stays in the canonical party. Only audio, fade and clock
-- host boundaries are recorded; maps, actors, scripts, models and the mechanism
-- stay production-owned, and the render trap stays active throughout.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local GeneratedCacheFixture = require("tests.support.GeneratedCacheFixture")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local FinalizedGameFixture = require("tests.support.FinalizedGameFixture")
local NewGameInitialization = require("game.hgss.src.newgame.NewGameInitialization")

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = {
      "new-game-intro",
      "field-runtime",
      "map:522",
      "map-data:522",
      "message-bank:146",
      -- The scene's own exit: its gift continuation warps back to the Ruins of
      -- Alph underground hall, whose own map-init scene then runs.
      "map:315",
      "map-data:315",
      "message-bank:76",
    },
    tags = { "field", "script", "legend", "save" },
  },
  tests = {},
}

local SINJOH_STAGE = "MAP_SINJOH_RUINS_MYSTRI_STAGE"
-- The map's own stage-init script entry, and the story word whose stage values
-- make the map start it.
local STAGE_INIT_SCRIPT = "vanilla.hgss.scr_seq.0131.script_002"
local SCENE_VAR = assert(FieldScriptSymbols.variablesByName.VAR_SCENE_SINJOH_MYSTRI_ROOM)
local STAGE_READY = 7
-- The pedestal coordinate events only run while this word is still armed.
local STAGE_ARMED_VAR = assert(FieldScriptSymbols.variablesByName.VAR_UNK_4104)
local STAGE_ARMED = 1
local GIFT_RESULT_VAR = assert(FieldScriptSymbols.variablesByName.VAR_UNK_4103)
-- The retail New Game startup script hides Cynthia's Mystri Shrine object; the
-- stage's own pedestal scene then drives that same source object, so the story
-- reveals it once the player has reached the stage.
local CYNTHIA_HIDDEN_FLAG = assert(FieldScriptSymbols.flagsByName.FLAG_HIDE_SINJOH_MYSTRI_SHRINE_CYNTHIA)

-- The map's three stage pedestals: the tile the coordinate event covers, the
-- source script that pedestal runs, the raw choice that script stores, and the
-- creature, orb and result word its own gift continuation commits
-- (src/data/scr_seq/scr_seq.0131.s: the 820 argument preceding each 483/484/487
-- gift, and the 135/136/112 orb operand of that same gift).
local PEDESTALS = {
  {
    key = "dialga",
    tile = { fieldX = 12, fieldZ = 15 },
    approach = { fieldX = 12, fieldZ = 16 },
    scriptId = "vanilla.hgss.scr_seq.0131.script_004",
    choice = 1,
    species = "DIALGA",
    speciesId = 483,
    orbId = 135,
    form = 0,
    result = 1,
  },
  {
    key = "palkia",
    tile = { fieldX = 20, fieldZ = 15 },
    approach = { fieldX = 20, fieldZ = 16 },
    scriptId = "vanilla.hgss.scr_seq.0131.script_003",
    choice = 2,
    species = "PALKIA",
    speciesId = 484,
    orbId = 136,
    form = 0,
    result = 2,
  },
  {
    key = "giratina",
    tile = { fieldX = 16, fieldZ = 8 },
    approach = { fieldX = 16, fieldZ = 9 },
    scriptId = "vanilla.hgss.scr_seq.0131.script_005",
    choice = 3,
    species = "GIRATINA",
    speciesId = 487,
    orbId = 112,
    form = 1,
    result = 3,
  },
}

-- The source scenes' own effect sounds: the Unown circle's summoning effect and
-- the gift fanfare.
local UNOWN_SOUND = "SEQ_SE_GS_TAMASYUTUGEN"
local GIFT_FANFARE = "SEQ_ME_SHINKAOME"

-- A fresh finalized New Game's own field event state: the retail `_std_init`
-- startup script runs through the production initializer, so the story objects
-- it hides (Cynthia's Mystri Shrine object among them) are absent exactly as
-- they are for a real new game.
---@return table
local function stageWorldState()
  local worldState = FieldEventState.new()
  local versionId = AcceptanceHarness.defaultVersion()
  NewGameInitialization.apply({ versionId = versionId, worldState = worldState }, {
    cacheFs = GeneratedCacheFixture.reader(versionId),
    randomU16 = function()
      return 0
    end,
  })
  return worldState
end

---@param worldState table
---@return AcceptanceHarness
local function harnessFor(worldState)
  return AcceptanceHarness.new({
    gameFactory = function(versionId)
      return FinalizedGameFixture.build(versionId, {
        location = { mapSymbol = SINJOH_STAGE, fieldX = 16, fieldZ = 28, facing = "south" },
        worldState = worldState,
      })
    end,
  })
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

-- The persisted source choice, read from the field's own gym-mechanism union.
---@param game table
---@return table|nil
local function sinjohUnion(game)
  local owner = game.runtime.gymMechanism
  if owner == nil then
    return nil
  end
  local captured = owner:capture()
  if captured == nil or captured.kind ~= "sinjoh" then
    return nil
  end
  return captured
end

-- Writes one ordinary save from a settled field tick: a capture needs every
-- autonomous actor settled, so the scenario advances until the production save
-- entry accepts the field.
---@param game table
---@param label string
local function saveSettled(game, label)
  for _ = 1, 480 do
    if pcall(game.save, game) then
      return
    end
    game:step()
  end
  error("the settled field never accepted its save: " .. label, 0)
end

---@param game table
---@param scriptId string
---@return boolean
local function scriptEnded(game, scriptId)
  return #game:recordsForScript(scriptId, "script.ended") > 0
end

-- The gift continuation's own nickname offer: message 0146.00032 asks whether
-- to nickname the creature it just handed over, and the scenario answers "No"
-- so the source flow returns to the field instead of opening the naming screen.
local NICKNAME_OFFER_BANK = 146
local NICKNAME_OFFER_MESSAGE = 32

-- Advances the fixed tick, answering only source dialogue and contextual
-- prompts, until the caller's boundary is reached or the scene faults. Returns
-- the observed fade activity so a scenario can assert the scene's authored
-- screen fades without waiting on a blind tick count.
---@param game table
---@param scriptId string
---@param label string
---@param done fun(snapshot: table): boolean
---@param maxTicks integer
---@return table { fades: integer, choices: table<integer, boolean> }
local function driveScene(game, scriptId, label, done, maxTicks)
  local choices = {}
  local fades = 0
  for _ = 1, maxTicks do
    local snapshot = game:snapshot()
    local live = sinjohUnion(game)
    local choice = live ~= nil and live.data ~= nil and live.data.choice or nil
    if choice ~= nil then
      choices[choice] = true
    end
    if snapshot.screenFade ~= nil and snapshot.screenFade.active == true then
      fades = fades + 1
    end
    if done(snapshot) then
      return { fades = fades, choices = choices }
    end
    if #game:recordsForScript(scriptId, "script.error") > 0 then
      return { fades = fades, choices = choices }
    end
    if game:contextChoiceStatus() ~= nil then
      if
        snapshot.dialogue.bankId == NICKNAME_OFFER_BANK
        and snapshot.dialogue.messageId == NICKNAME_OFFER_MESSAGE
      then
        game.runtime:pressCancel()
        game:step()
        game.runtime:releaseCancel()
      else
        game:pressAction()
      end
    elseif snapshot.dialogue.modal then
      game:pressAction()
    else
      game:step()
    end
  end
  error(
    "the Sinjoh scene did not reach its boundary: "
      .. label
      .. "; foreground="
      .. tostring(game:snapshot().foregroundScript)
      .. ", modal="
      .. tostring(game:snapshot().dialogue.modal)
      .. ", choice="
      .. tostring(choice)
      .. ", tick="
      .. tostring(game:snapshot().tick),
    0
  )
end

---@param game table
---@param species string
---@return integer slot0, table mon
local function grantedSlot(game, species)
  local mons = game.runtime.monService
  for slot0 = 0, mons:partyCount() - 1 do
    local mon = mons:partyMon(slot0)
    if mon.species == species then
      return slot0, mon
    end
  end
  error("the gift continuation committed no " .. species)
end

---@param game table
---@param pedestal table
local function assertGift(game, pedestal)
  local mons = game.runtime.monService
  Assert.equal(mons:partyCount(), 2, "the scene adds exactly one creature to the prepared party")
  local _, mon = grantedSlot(game, pedestal.species)
  Assert.equal(mon.met and mon.met.level, 1, "the gifted " .. pedestal.species .. " carries its source level")
  Assert.equal(mon.form, pedestal.form, "the gifted " .. pedestal.species .. " keeps its source form")
  local orbKey = game.runtime.itemCatalog:itemKeyByNativeId(pedestal.orbId)
  Assert.equal(mon.heldItem, orbKey, "the gifted " .. pedestal.species .. " carries its own source orb")
  Assert.equal(
    game.runtime.scripts.worldState:getVar(GIFT_RESULT_VAR),
    pedestal.result,
    "the gift continuation publishes its source result word"
  )
end

-- Boots the stage, confirms the map's own init scene installed the unresolved
-- choice, walks onto one pedestal and drives its source scene to completion.
---@param pedestal table
---@return table game, table union, table drive
local function runPedestal(pedestal)
  local worldState = stageWorldState()
  worldState:setVar(SCENE_VAR, STAGE_READY)
  worldState:setVar(STAGE_ARMED_VAR, STAGE_ARMED)
  local game = harnessFor(worldState):boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = SINJOH_STAGE,
    save = "fresh",
    fieldOptions = { recordingScriptHosts = true, audioHost = "recording" },
  })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    Assert.isTrue(
      game.runtime.monService:giveMon({
        species = "TOTODILE",
        level = 40,
        form = 0,
        heldItem = "NONE",
        ability = "TORRENT",
      }),
      "the prepared party lead enters through the production gift operation"
    )
    game:waitForFieldReady(480)
    Assert.equal(
      game.runtime.monCatalog:speciesKeyByNativeId(pedestal.speciesId),
      pedestal.species,
      "the scenario names the pedestal's source species number"
    )
    -- The map runs its stage-init scene through the transition lifecycle; this
    -- boot has no transition, so the scenario starts that same generated script
    -- through the field's production script composition.
    game:startScript(STAGE_INIT_SCRIPT)
    driveScene(game, STAGE_INIT_SCRIPT, "the stage init scene installs the unresolved choice", function()
      return sinjohUnion(game) ~= nil
    end, 960)
    local initFaults = faultsFor(game, STAGE_INIT_SCRIPT)
    Assert.equal(#initFaults, 0, "the stage init scene runs its own native operations: " .. table.concat(initFaults, ","))
    game:waitForFieldReady(480)
    local initialized = assert(sinjohUnion(game), "the stage init scene installs the Sinjoh union")
    Assert.equal(initialized.data.choice, 0, "the initialized stage carries the unresolved source choice")
    -- The settled stage visit is an ordinary saveable field: the save carries
    -- the Sinjoh union and Continue reloads the same stage state.
    saveSettled(game, "the settled stage")
    Assert.notNil(game:snapshot(), "the settled stage publishes a game save")
    local stageBucket = game.runtime:captureGameSave()
    Assert.equal(stageBucket.gymmick.kind, "sinjoh", "the saved stage keeps its mechanism kind")
    Assert.equal(stageBucket.gymmick.data.choice, 0, "the saved stage keeps the unresolved source choice")
    game:restart()
    game:waitForFieldEntry()
    game:waitForFieldReady(480)
    local continued = assert(sinjohUnion(game), "Continue restores the Sinjoh union")
    Assert.equal(continued.data.choice, 0, "Continue restores the unresolved source choice")
    Assert.equal(game.runtime.monService:partyCount(), 1, "Continue keeps exactly the prepared party lead")
  end, debug.traceback)
  if not ok then
    game:close()
    error(err, 0)
  end

  game:moveTo(pedestal.approach)
  -- The stage scene starts from the story state its own script expects: the
  -- shrine companion has been revealed, so her source object exists for the
  -- scene's own object operations.
  game.runtime.scripts.worldState:clearFlag(CYNTHIA_HIDDEN_FLAG)
  game:step()
  game:waitForFieldReady(480)
  game:face("north")
  game:move("north")
  local union, drive
  local ok2, err2 = xpcall(function()
    game:advanceUntil("the pedestal scene starts", function()
      return #game:recordsForScript(pedestal.scriptId, "script.started") > 0
    end, 480)
    drive = driveScene(game, pedestal.scriptId, "the pedestal scene closes", function()
      return scriptEnded(game, pedestal.scriptId) and not game:snapshot().fieldLocked
    end, 12000)
    union = sinjohUnion(game)
  end, debug.traceback)
  if not ok2 then
    game:close()
    error(err2, 0)
  end
  return game, union, drive
end

-- ---------------------------------------------------------------------------
-- Every stage pedestal runs the same closed scene with its own source choice,
-- stores that choice, plays the circle and the cinematic, and then commits the
-- source creature, orb and result exactly once.
-- ---------------------------------------------------------------------------

function T.tests.each_stage_pedestal_commits_its_own_source_creature()
  local versionId = AcceptanceHarness.defaultVersion()
  for _, pedestal in ipairs(PEDESTALS) do
    local game, union, drive = runPedestal(pedestal)
    local ok, err = xpcall(function()
      local faults = faultsFor(game, pedestal.scriptId)
      Assert.equal(
        #faults,
        0,
        "the " .. pedestal.key .. " stage scene runs its own native operations: " .. table.concat(faults, ",")
      )
      local ended = game:recordsForScript(pedestal.scriptId, "script.ended")
      Assert.equal(#ended, 1, "the " .. pedestal.key .. " scene ends exactly once")
      Assert.equal(ended[1].payload.completed, true, "the " .. pedestal.key .. " scene completes instead of faulting")
      Assert.isTrue(
        drive.choices[pedestal.choice] == true,
        "the " .. pedestal.key .. " scene stores its raw source choice"
      )
      assertGift(game, pedestal)

      -- The scene's own effect and fanfare played, its summoning sound stopped
      -- again, and its authored screen fade ran.
      local playedSummon, stoppedSummon, playedFanfare = false, false, false
      for _, effect in ipairs(game:hostEffects()) do
        if effect == "audio:" .. UNOWN_SOUND then
          playedSummon = true
        elseif effect == "stop:" .. UNOWN_SOUND then
          stoppedSummon = true
        elseif effect == "fanfare:" .. GIFT_FANFARE then
          playedFanfare = true
        end
      end
      Assert.isTrue(playedSummon, "the " .. pedestal.key .. " scene plays the Unown circle effect")
      Assert.isTrue(stoppedSummon, "the " .. pedestal.key .. " scene stops the Unown circle effect")
      Assert.isTrue(playedFanfare, "the " .. pedestal.key .. " gift plays its source fanfare")
      Assert.isTrue(drive.fades > 0, "the " .. pedestal.key .. " scene runs its authored screen fade")
      Assert.isTrue(game:renderAttempts() == 0, "the scene acceptance stops before GPU rendering")

      -- The source scene ends by warping the player back to the Ruins of Alph
      -- hall, and a non-connection map entry clears the gym mechanism union:
      -- the stage's chosen legend belongs to the stage visit.
      Assert.equal(
        game:snapshot().mapSymbol,
        "MAP_RUINS_OF_ALPH_UNDERGROUND_HALL",
        "the " .. pedestal.key .. " scene ends on the hall its own exit warp names"
      )
      Assert.isNil(
        union,
        "the " .. pedestal.key .. " scene's exit warp clears the stage mechanism on the non-connection entry"
      )
      -- The committed creature and its result word are canonical state, so the
      -- settled destination field saves and reloads them unchanged.
      saveSettled(game, "the settled destination field")
      local bucket = game.runtime:captureGameSave()
      Assert.equal(bucket.gymmick.kind, "none", "the exit warp cleared the saved stage mechanism")
      game:restart()
      -- The destination map's own load-time scene runs on Continue; drive it
      -- through the production dialogue path until the field returns.
      for _ = 1, 4000 do
        local snapshot = game:snapshot()
        if not snapshot.fieldLocked and snapshot.mapEntryStage == nil and not snapshot.dialogue.modal then
          break
        end
        if snapshot.dialogue.modal or game:contextChoiceStatus() ~= nil then
          game:pressAction()
        else
          game:step()
        end
      end
      Assert.isNil(sinjohUnion(game), "Continue keeps the stage mechanism the exit warp settled")
      local mons = game.runtime.monService
      Assert.equal(mons:partyCount(), 2, "Continue keeps exactly the gifted creature in the party")
      grantedSlot(game, pedestal.species)
      assertGift(game, pedestal)
      Assert.equal(game:renderAttempts(), 0, "the scene acceptance stops before GPU rendering")
    end, debug.traceback)
    game:close()
    if not ok then
      error(versionId .. ": " .. tostring(err), 0)
    end
  end
end

-- Entering the stage without a resolvable pedestal still installs the
-- unresolved source choice and publishes the union in the save.
function T.tests.stage_entry_installs_the_unresolved_choice_and_saves_it()
  local worldState = stageWorldState()
  worldState:setVar(SCENE_VAR, STAGE_READY)
  local game = harnessFor(worldState):boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = SINJOH_STAGE,
    save = "fresh",
    fieldOptions = { recordingScriptHosts = true, audioHost = "recording" },
  })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    game:waitForFieldReady(480)
    game:startScript(STAGE_INIT_SCRIPT)
    driveScene(game, STAGE_INIT_SCRIPT, "the stage init scene installs the unresolved choice", function()
      return sinjohUnion(game) ~= nil
    end, 960)
    local faults = faultsFor(game, STAGE_INIT_SCRIPT)
    Assert.equal(#faults, 0, "the stage init scene runs its own native operations: " .. table.concat(faults, ","))
    local union = assert(sinjohUnion(game), "the stage entry installs the Sinjoh union")
    Assert.equal(union.data.choice, 0, "the stage entry carries the unresolved source choice")
    game:waitForFieldReady(480)
    local bucket = assert(game.runtime:captureGameSave(), "the stage entry leaves the field saveable")
    Assert.equal(bucket.gymmick.kind, "sinjoh", "the saved stage keeps its mechanism kind")
    Assert.equal(bucket.gymmick.data.choice, 0, "the saved stage keeps the unresolved source choice")
    Assert.equal(game:renderAttempts(), 0, "the scene acceptance stops before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

return T
