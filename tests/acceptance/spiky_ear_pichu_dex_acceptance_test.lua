-- Production-composed contract for the Spiky-Ear Pichu script gift: the
-- successful source opcode-778 gift inserts the event Pichu through the
-- live party owner and registers it as seen and caught through the live
-- persistent Pokedex owner, surviving save/restore independently of later
-- party membership. A full party refuses before touching either owner, the
-- creation generator, or the Dex revision. Real ROM-derived maps, the real
-- field runtime, the real scheduler dispatch, and the real mon/Dex/save
-- owners stay in the path; only host boundaries (audio, saves, clock) are
-- faked by the harness. Retail behavior refuses
-- the gift on a full party before creation and registers the received non-egg species as caught.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local PlayTime = require("libs.hgss.src.save.PlayTime")

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = { "field-runtime", "map:7", "map-data:7" },
    tags = { "field", "script-gift", "pokedex", "acceptance" },
  },
  tests = {},
}

local MAP = "MAP_BURNED_TOWER_1F"
local GIFT_SCRIPT = "acceptance.spiky_ear_pichu_gift"

local GIFT_SCRIPTS = {
  [GIFT_SCRIPT] = [[
local S = require("gen4.script")

return S.script({
  api = 1,
  id = "acceptance.spiky_ear_pichu_gift",
  steps = {
    { op = "give_spiky_ear_pichu" },
    S.stop(),
  },
})
]],
}

local function harness()
  return AcceptanceHarness.new({
    gameFactory = function(versionId, map)
      return {
        saveId = "save-00000001",
        versionId = versionId,
        location = { mapSymbol = map, fieldX = 10, fieldZ = 10, facing = "south" },
        playerData = {
          profile = {
            name = "GOLD",
            gender = 0,
            trainerId = 1,
            money = 3000,
            badges = 0,
            nationalDex = false,
            runningShoes = false,
            runningShoesLock = false,
            rivalName = "Silver",
          },
          options = { textSpeed = "fastest", textFrame = 1 },
        },
        fieldTravel = { lastHealSpawn = "SPAWN_NEW_BARK" },
        fashionCase = require("libs.hgss.src.save.FashionCaseState").empty(),
        playTime = PlayTime.new(),
        worldState = FieldEventState.new(),
        mons = require("tests.support.MonBucket").emptyForVersion(versionId),
        bag = require("libs.hgss.src.save.BagSave").empty(),
        mart = require("libs.hgss.src.save.MartSave").empty(),
      }
    end,
  })
end

local function bootGiftGame()
  local game = harness():boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = MAP,
    save = "fresh",
    fieldOptions = { recordingScriptHosts = true, acceptanceScripts = GIFT_SCRIPTS },
  })
  game:waitForFieldEntry()
  return game
end

-- Runs the gift script through the production scheduler to its source end
-- and returns the completion payload. The gift opcode continues in the same
-- tick, so a bounded drive proves continuation instead of a stall.
local function runGiftToCompletion(game)
  local before = #game:recordsForScript(GIFT_SCRIPT, "script.ended")
  game:startScript(GIFT_SCRIPT)
  game:advanceUntil("the gift script reaches its source end", function()
    return #game:recordsForScript(GIFT_SCRIPT, "script.ended") > before
  end, 120)
  local records = game:recordsForScript(GIFT_SCRIPT, "script.ended")
  local completion = assert(records[#records], "the gift script must record its completion")
  Assert.isTrue(
    completion.payload.completed == true,
    "the gift script must complete normally, reason=" .. tostring(completion.payload.reason)
  )
  return completion.payload
end

local function containsKey(list, key)
  for _, entry in ipairs(assert(list, "a persisted list is required")) do
    if entry == key then
      return true
    end
  end
  return false
end

local function withGame(fn)
  local game = bootGiftGame()
  local ok, err = xpcall(function()
    fn(game)
    Assert.equal(game:renderAttempts(), 0, "the gift acceptance must stop before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

-- The successful gift changes both real owners through one scheduler
-- dispatch: exactly one Spiky-Ear Pichu enters the party and the persistent
-- Pokedex reports the species seen and caught. Both flags survive a normal
-- production save/restart, and they survive a second save/restart taken
-- after the gifted mon leaves the party, proving Dex knowledge is
-- independently persisted rather than inferred from party membership.
function T.tests.gift_registers_pichu_in_party_and_persistent_pokedex()
  withGame(function(game)
    local dex = assert(game.runtime.dexKnowledge, "the field owns live dex knowledge")
    local mons = game.runtime.monService
    Assert.equal(mons:partyCount(), 0, "the fresh save starts with an empty party")
    Assert.isFalse(dex:isSeen("PICHU"), "the fresh dex has no Pichu sighting")
    Assert.isFalse(dex:isCaught("PICHU"), "the fresh dex has no Pichu catch")
    local dexRevisionBefore = dex:revision()

    runGiftToCompletion(game)

    Assert.equal(mons:partyCount(), 1, "the successful gift publishes exactly one mon")
    local gifted = mons:partyMon(0)
    Assert.equal(gifted.species, "PICHU", "the gift publishes the event species")
    Assert.equal(gifted.form, 1, "the gift publishes the Spiky-Ear form")
    Assert.isTrue(dex:isSeen("PICHU"), "the successful gift registers the sighting")
    Assert.isTrue(dex:isCaught("PICHU"), "the successful gift registers the catch")
    Assert.equal(
      dex:revision(),
      dexRevisionBefore + 1,
      "the successful gift publishes its staged catch exactly once"
    )
    local saved = assert(game.runtime:captureGameSave(), "a stable field must provide a save record")
    local pokedexBucket = assert(saved.pokedex, "the save record carries the persisted dex bucket")
    Assert.isTrue(containsKey(pokedexBucket.caught, "PICHU"), "the save bucket persists the catch")
    Assert.isTrue(containsKey(pokedexBucket.seen, "PICHU"), "the save bucket persists the sighting")

    game:save()
    game:restart()
    game:waitForFieldEntry()
    local reloadedDex = assert(game.runtime.dexKnowledge, "the restarted field owns live dex knowledge")
    Assert.isTrue(reloadedDex:isSeen("PICHU"), "the sighting survives save/restore")
    Assert.isTrue(reloadedDex:isCaught("PICHU"), "the catch survives save/restore")
    Assert.equal(game.runtime.monService:partyCount(), 1, "the gifted mon survives save/restore")

    -- Dex independence: the gifted mon leaves the party, yet a further
    -- save/restore keeps both flags.
    Assert.notNil(game.runtime.monService:removeMon(0), "the gifted mon leaves the party")
    Assert.equal(game.runtime.monService:partyCount(), 0, "the party is empty after removal")
    game:save()
    game:restart()
    game:waitForFieldEntry()
    local independentDex = assert(game.runtime.dexKnowledge, "the reloaded field owns live dex knowledge")
    Assert.isTrue(independentDex:isSeen("PICHU"), "the sighting survives without the party mon")
    Assert.isTrue(independentDex:isCaught("PICHU"), "the catch survives without the party mon")
  end)
end

-- The full-party refusal is observably side-effect free: party count and
-- revision, the creation generator draw state, and both Dex flags and the
-- Dex revision are unchanged, and the script still completes. A repeat gift
-- into freed space over already-known knowledge adds the mon without
-- advancing the Dex revision again.
function T.tests.full_party_refuses_without_dex_rng_or_party_side_effects()
  withGame(function(game)
    local mons = game.runtime.monService
    local dex = assert(game.runtime.dexKnowledge, "the field owns live dex knowledge")
    for _ = 1, 6 do
      Assert.isTrue(
        mons:giveMon({ species = "CHIKORITA", level = 5, heldItem = "NONE", form = 0 }),
        "setup gifts fill the party"
      )
    end
    Assert.equal(mons:partyCount(), 6, "the party is full before the refused gift")
    Assert.isFalse(dex:isSeen("PICHU"), "the dex has no Pichu sighting before the refused gift")
    Assert.isFalse(dex:isCaught("PICHU"), "the dex has no Pichu catch before the refused gift")
    local partyRevisionBefore = mons:partyRevision()
    local dexRevisionBefore = dex:revision()
    local rngBefore = mons:capture().rng

    runGiftToCompletion(game)

    Assert.equal(mons:partyCount(), 6, "the refused gift never overflows the full party")
    Assert.equal(
      mons:partyRevision(),
      partyRevisionBefore,
      "the refused gift bumps no party revision"
    )
    Assert.deepEqual(mons:capture().rng, rngBefore, "the refused gift consumes no generator draws")
    Assert.isFalse(dex:isSeen("PICHU"), "the refused gift registers no sighting")
    Assert.isFalse(dex:isCaught("PICHU"), "the refused gift registers no catch")
    Assert.equal(dex:revision(), dexRevisionBefore, "the refused gift advances no dex revision")

    -- Already-known knowledge: freeing one slot and pre-registering the
    -- species through the live dex owner lets the repeat gift add its mon
    -- while leaving the unchanged dex revision alone.
    Assert.notNil(mons:removeMon(5), "one setup mon leaves to free a slot")
    local staged = dex:capture("PICHU")
    staged.publish()
    Assert.isTrue(dex:isCaught("PICHU"), "the setup registers the catch through the live dex owner")
    local knownRevision = dex:revision()

    runGiftToCompletion(game)

    Assert.equal(mons:partyCount(), 6, "the repeat gift fills the freed slot")
    local repeated = mons:partyMon(5)
    Assert.equal(repeated.species, "PICHU", "the repeat gift publishes the event species")
    Assert.isTrue(dex:isCaught("PICHU"), "the repeat gift keeps the catch")
    Assert.equal(
      dex:revision(),
      knownRevision,
      "a repeat gift over known knowledge advances no dex revision"
    )
  end)
end

return T
