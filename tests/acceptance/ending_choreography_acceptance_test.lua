-- League ending choreography through production composition: the Hall of
-- Fame registration reveals each recorded mon in party order (alternating
-- sides, back picture with cry, follower sprite, header, front picture
-- with cry, species/level, caught detail) before the whole-party photo
-- waits for the player's terminal acknowledgment; the credit roll advances
-- its scenes, screen flips and cutscenes on the source timeline. Only
-- audio, fades, clock and the host's route callback are recorded - the
-- field, map, scripts, save store and every domain owner stay
-- production-owned, and the render trap stays active throughout.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = {
      "field-runtime",
      "map:306",
      "map-data:306",
      "message-bank:528",
      "map:64",
      "map-data:64",
      "message-bank:14",
      -- The League ending's own generated bundle: registration, showcase
      -- and credit-roll sections the congratulations and roll draw.
      "ending:global",
      -- The save-status window (bank 40), the registration text (bank
      -- 180), the recorded party's icon pages and the portrait pages and
      -- cry banks behind the revealed party.
      "message-bank:40",
      "mon-catalog:global",
      "mon-layout:global",
      "mon-icon-page:20",
      "mon-icon-page:29",
    },
    tags = { "field", "script", "ending", "save" },
  },
  tests = {},
}

local HOF_ROOM = "MAP_POKEMON_LEAGUE_HALL_OF_FAME"
local ENDING_SCRIPT = "vanilla.hgss.scr_seq.0825.script_000"
local HOF_APPROACH = { fieldX = 6, fieldZ = 22, facing = "north" }

local VAR_HOF_FRAME_ENTRY = assert(FieldScriptSymbols.variablesByName.VAR_TEMP_x4001)

local PARTY = {
  { species = "TYPHLOSION", level = 60, move = "FLAMETHROWER" },
  { species = "PIDGEOT", level = 55, move = "AERIAL_ACE" },
}

-- The source registration holds every recorded member through its own
-- reveal before the whole-party photo: a two-mon party needs well over a
-- thousand fixed ticks before the photo wait.
local REGISTRATION_AND_PHOTO_TICKS = 4000
local SOURCE_CREDITS_FRAMES = 4976

-- The shared recording audio adapter acknowledges every call but only names
-- play/playMusic/playFanfare; wrap playCry so the reveal's own cries stay
-- observable without changing the shared host for other suites.
---@param game table
---@return table[] recorded cries in call order
local function recordCries(game)
  local audio = assert(game.hosts.audio, "the recording hosts supply the audio adapter")
  local cries = {}
  local playCry = audio.playCry
  audio.playCry = function(self, ...)
    cries[#cries + 1] = { ... }
    return playCry(self, ...)
  end
  return cries
end

---@return AcceptanceHarness
local function harnessAt()
  local harness = AcceptanceHarness.new()
  local createGame = harness.gameFactory
  harness.gameFactory = function(versionId, map)
    local game = createGame(versionId, map)
    game.location = {
      mapSymbol = HOF_ROOM,
      fieldX = HOF_APPROACH.fieldX,
      fieldZ = HOF_APPROACH.fieldZ,
      facing = HOF_APPROACH.facing,
    }
    return game
  end
  return harness
end

---@param game table acceptance game
---@return table registration status snapshot
local function registrationStatus(game)
  local coordinator = assert(game.runtime.gameClear, "the field runtime owns its ending coordinator")
  local status = assert(coordinator:status(), "the active ending publishes its status")
  return assert(status.registration, "the congratulations phase publishes its registration scene")
end

-- Advances the fixed tick, answering source dialogue, until the caller's
-- boundary is reached or the budget runs out.
---@param game table acceptance game
---@param label string boundary description
---@param done fun(): boolean
---@param maxTicks integer
local function advanceEnding(game, label, done, maxTicks)
  for _ = 1, maxTicks do
    if done() then
      return game:snapshot().tick
    end
    if game:snapshot().dialogue.modal then
      game:pressAction()
    else
      game:step()
    end
  end
  local snapshot = game:snapshot()
  local coordinator = game.runtime.gameClear
  local status = coordinator ~= nil and coordinator:status() or {}
  error(
    "the source League ending did not reach "
      .. label
      .. "; tick="
      .. tostring(snapshot.tick)
      .. " phase="
      .. tostring(snapshot.foregroundScript)
      .. " ending="
      .. tostring(status.phase)
      .. " registration="
      .. tostring(status.registration ~= nil)
      .. " faults="
      .. tostring(#game:recordsForScript(ENDING_SCRIPT, "script.error")),
    0
  )
end
-- The registration reveals every recorded member in party order before the
-- whole-party photo: alternating sides, a back-picture cry and a
-- front-picture cry per member, then the photo wait that answers only the
-- terminal acknowledgment.
function T.tests.registration_reveals_each_mon_before_the_whole_party_photo()
  local game = harnessAt():boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = HOF_ROOM,
    save = "fresh",
    fieldOptions = { recordingScriptHosts = true, audioHost = "recording" },
  })
  local ok, err = xpcall(function()
    local party = assert(game.runtime.monService, "the field runtime owns its mon service")
    for slot0, member in ipairs(PARTY) do
      Assert.isTrue(
        party:giveMon({ species = member.species, level = member.level, form = 0, heldItem = "NONE" }),
        "the prepared party member enters through the production gift operation"
      )
      party:setMove(slot0 - 1, 0, member.move)
    end
    local cries = recordCries(game)

    -- The congratulations phase opens on the first recorded member.
    advanceEnding(game, "the registration reveal", function()
      local okStatus, status = pcall(registrationStatus, game)
      return okStatus and status.phase == "indiv"
    end, 1200)
    local first = registrationStatus(game)
    Assert.equal(first.monIndex, 0, "the reveal starts with the first recorded member")
    Assert.equal(first.side, "left", "the first reveal plays on the left side")

    -- Every recorded member gets its own reveal, alternating sides, with
    -- exactly one back-picture cry and one front-picture cry each.
    advanceEnding(game, "the whole-party photo wait", function()
      local okStatus, status = pcall(registrationStatus, game)
      return okStatus and status.phase == "whole"
    end, REGISTRATION_AND_PHOTO_TICKS)
    local seen = {}
    for _, cry in ipairs(cries) do
      seen[#seen + 1] = cry
    end
    Assert.equal(#cries, #PARTY * 2, "every recorded member cries its back and front pictures")
    Assert.equal(seen[1][1], 157, "the first cry names the first member's species cry")
    Assert.equal(seen[1][2], 0, "the first cry uses the default cry pattern")
    Assert.equal(seen[3][1], 18, "the second member's back picture cries its own species cry")

    -- The photo wait answers only the terminal acknowledgment: START alone
    -- never advances the registration.
    local photoTick = game:snapshot().tick
    for _ = 1, 30 do
      game.runtime:pressMenu()
      game:step()
      game.runtime:releaseMenu()
    end
    local still = registrationStatus(game)
    Assert.equal(still.phase, "whole", "START alone never advances the whole-party photo wait")
    Assert.isTrue(
      game:snapshot().tick > photoTick,
      "the photo wait holds its phase while START is pressed"
    )
    game:pressAction()
    -- Drive on with periodic action edges: the wait answers the first one
    -- it sees, and later edges are ignored while the flashes play out.
    -- Reaching saving alone never establishes publication: the save must
    -- reach save_status through the presented-frame gate and the
    -- transaction's own success report.
    local reachedSaving = false
    for step = 1, 600 do
      if step % 10 == 0 then
        game:pressAction()
      else
        game:step()
      end
      local coordinator = assert(game.runtime.gameClear, "the ending owns its coordinator")
      if coordinator:phase() == "saving" or coordinator:phase() == "save_status" then
        reachedSaving = true
        break
      end
    end
    Assert.isTrue(reachedSaving, "the acknowledged photo reaches its saving phase")
    do
      local coordinator = assert(game.runtime.gameClear, "the ending owns its coordinator")
      if type(coordinator.noteSavingPresented) == "function" then
        coordinator:noteSavingPresented()
      end
      local published = false
      for _ = 1, 60 do
        game:step()
        if coordinator:phase() == "save_status" then
          published = true
          break
        end
      end
      Assert.isTrue(published, "the acknowledged photo publishes its save")
    end
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

return T
