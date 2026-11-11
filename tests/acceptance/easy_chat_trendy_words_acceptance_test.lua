-- Route16 daily word through the production field: the actual retail
-- trendy-saying interaction learns exactly one word per civil day behind
-- its consent and daily-use flag, refuses a second grant the same day,
-- survives a same-day reload, reopens after a forward day advance, and
-- never reopens on a backward clock adjustment. Every leg boots the real
-- field runtime over real maps, scripts, clock observation, and state
-- owners; only host audio, host input snapshots, the wall clock, and
-- the save root are recording boundaries. No ROM text is asserted here
-- and no learning implementation is faked.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local Fixture = require("tests.support.PokegearJourneyFixture")
local Drive = require("tests.support.EasyChatScriptDrive")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local LocalClock = require("game.src.LocalClock")

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = (function()
      local assets = { "message-bank:355" }
      for _, asset in ipairs(Fixture.JOURNEY_ASSETS) do
        assets[#assets + 1] = asset
      end
      return assets
    end)(),
    tags = { "easychat" },
  },
  tests = {},
}

local TRENDY_SCRIPT = "vanilla.hgss.scr_seq.0206.script_001"
local VAR_RESULT = FieldScriptSymbols.variablesByName.VAR_SPECIAL_RESULT
local FLAG_DAILY_USED = FieldScriptSymbols.flagsByName.FLAG_UNK_ABA

---@param mask integer
---@return integer population count
local function popcount(mask)
  local count = 0
  local rest = mask
  while rest > 0 do
    count = count + (rest % 2)
    rest = math.floor(rest / 2)
  end
  return count
end

---@param clock table mutable civil date
---@param onGame fun(game: table)
local function bootOnClock(clock, onGame)
  local game = AcceptanceHarness.new():boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = Fixture.TOWN,
    save = "fresh",
    fieldOptions = {
      recordingScriptHosts = true,
      localClock = LocalClock.new(function()
        return {
          year = clock.year,
          month = clock.month,
          day = clock.day,
          hour = clock.hour,
          minute = clock.minute,
          second = clock.second,
        }
      end),
    },
  })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    onGame(game)
    Assert.equal(game:renderAttempts(), 0, "the daily word journey stops before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

---@param game table
---@return integer learned mask
local function learnedMask(game)
  return game.runtime.easyChatState:readUnlocks().trendy
end

---@param game table
---@return boolean
local function dailyUsed(game)
  return game.runtime.scripts.worldState:isFlagSet(FLAG_DAILY_USED)
end

-- Runs the retail trendy interaction to a free field, answering its
-- consent affirmatively through the production yes/no owner.
---@param game table
local function runTrendyInteraction(game)
  game:startScript(TRENDY_SCRIPT)
  Assert.isTrue(Fixture.settleScripting(game, 720), "the trendy interaction settles back to a free field")
end

-- One civil day of the daily word: consent grants exactly one new word
-- with its daily flag, a same-day repeat grants nothing, a same-day
-- reload preserves both, a forward day reopens the grant, and a
-- backward adjustment never does.
function T.tests.daily_word_grants_once_per_civil_day_across_reload_and_clock_moves()
  local clock = { year = 2000, month = 1, day = 10, hour = 12, minute = 0, second = 0 }
  bootOnClock(clock, function(game)
    Drive.requireScriptModules()
    assert(game.runtime.easyChatState, "the field runtime owns the saved word state before the daily word runs")
    Assert.equal(learnedMask(game), 0, "a fresh save has learned no trendy words")
    Assert.isFalse(dailyUsed(game), "a fresh save has not used its daily word")

    -- First consent grants exactly one word and sets the daily flag.
    runTrendyInteraction(game)
    local first = learnedMask(game)
    Assert.equal(popcount(first), 1, "the first consent learns exactly one trendy word")
    local granted = game.runtime.scripts.worldState:getVar(VAR_RESULT)
    Assert.isTrue(granted >= 0 and granted <= 31, "the grant reports its local word index")
    Assert.isTrue(dailyUsed(game), "the grant sets the daily-use flag")

    -- A second consent the same day grants nothing more.
    runTrendyInteraction(game)
    Assert.equal(learnedMask(game), first, "a same-day repeat learns no further word")
    Assert.isTrue(dailyUsed(game), "a same-day repeat keeps the daily-use flag")

    -- A same-day reload preserves the mask and the flag.
    game:setWorldState({ flag = FieldScriptSymbols.flagsByName.FLAG_GOT_SAVE_BUTTON })
    Fixture.saveAndReload(game)
    Assert.equal(learnedMask(game), first, "a same-day reload preserves the learned word")
    Assert.isTrue(dailyUsed(game), "a same-day reload preserves the daily-use flag")

    -- A forward civil day clears only the gate, never the learned bits.
    clock.day = 11
    game:advanceUntil("the forward day clears the daily-use flag", function()
      return not dailyUsed(game)
    end, 480)
    Assert.equal(learnedMask(game), first, "a forward day never clears learned words")

    -- The new day grants exactly one further word.
    runTrendyInteraction(game)
    local second = learnedMask(game)
    Assert.equal(popcount(second), 2, "the new day learns exactly one further word")
    Assert.isTrue(dailyUsed(game), "the new grant sets the daily-use flag again")

    -- A backward clock adjustment never reopens the gate.
    clock.day = 9
    for _ = 1, 120 do
      game:step()
    end
    Assert.isTrue(dailyUsed(game), "a backward adjustment does not clear the daily-use flag")
    Assert.equal(learnedMask(game), second, "a backward adjustment learns nothing")
  end)
end

return T
