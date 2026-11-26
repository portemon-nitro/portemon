-- NPC exchanges and loans through the production field. The Violet City
-- Bellsprout-for-Onix house runs its own vanilla script: the source message,
-- the source yes/no, the in-game-trade party picker with its capsule
-- confirmation, the app71 trade sequence with its seven scenes and their
-- sounds, and the field return; the exchanged record is created from the
-- source trade table, replaces the selected slot and registers its Dex and
-- score receipt once, before the fade-out. The Cianwood house hands out the
-- loaned Shuckle and takes it back through the source return checks, and the
-- Kenya loan publishes the source letter without a second dummy creation.
-- The party, Dex, statistics and world state are canonical saved owners, so
-- the return journey boots from the loan's captured record; only audio,
-- screen fades, the wall clock and the save root are host boundaries, and the
-- render trap stays active throughout.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local FinalizedGameFixture = require("tests.support.FinalizedGameFixture")
local GameStats = require("libs.hgss.src.mons.GameStats")
local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
local LocalClock = require("game.src.LocalClock")

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = {
      "field-runtime",
      -- The Violet City Bellsprout-for-Onix trade house and its own script
      -- bank.
      "map:162",
      "map-data:162",
      "message-bank:562",
      -- The Cianwood house that lends the Shuckle and its script bank.
      "map:232",
      "map-data:232",
      "message-bank:576",
    },
    tags = { "field", "script", "mons", "trade" },
  },
  tests = {},
}

-- Vanilla scripts: the Violet house's trade boy (scr_seq 0864 script 001) and
-- the Cianwood house's loan man (scr_seq 0880 script 000).
local ONIX_SCRIPT = "vanilla.hgss.scr_seq.0864.script_001"
local ONIX_MAP = "MAP_VIOLET_BELLSPROUT_ONYX_TRADE_HOUSE"
local ONIX_TILE = { fieldX = 2, fieldZ = 6 }
local LOAN_SCRIPT = "vanilla.hgss.scr_seq.0880.script_000"
local LOAN_MAP = "MAP_CIANWOOD_KIRKS_HOUSE"
local LOAN_TILE = { fieldX = 5, fieldZ = 6 }

local ONIX_FLAG = FieldScriptSymbols.flagsByName.FLAG_TRADE_VIOLET_CITY_BELLSPROUT_ONIX
local SHUCKIE_GIVEN_FLAG = FieldScriptSymbols.flagsByName.FLAG_GOT_LOAN_SHUCKLE
local SHUCKIE_RETURNED_FLAG = FieldScriptSymbols.flagsByName.FLAG_RETURNED_OR_INHERITED_LOAN_SHUCKLE

-- Source app71 scene order (`sTradeSequenceScenes`): the send, depart and
-- recede scenes play the departure, exchange is the shared scene, and
-- approach, arrive and receive play the arrival.
local TRADE_PHASES = { "send", "depart", "recede", "exchange", "approach", "arrive", "receive" }
local TRADE_MUSIC = "music:SEQ_GS_KOUKAN"
local TRADE_SEND_SE = "audio:SEQ_SE_DP_KOUKAN01"
local TRADE_EXCHANGE_SE = "audio:SEQ_SE_DP_KOUKAN03"
local TRADE_APPROACH_SE = "audio:SEQ_SE_DP_KOUKAN05"

-- Source NPC trade table (a/1/1/2) in `NpcTradeNum` order. Each record is the
-- identity the exchange must reproduce: the fixed personality, the OT id, the
-- six individual values written after the two creation draws, the held item,
-- the OT gender and the record language. Requested species 471/472 publishes
-- are the source `ask_species`; the loan records (Shuckle, Spearow) carry
-- their own species in that field because no script compares it.
---@class TradeIvs
---@field hp integer
---@field attack integer
---@field defense integer
---@field speed integer
---@field specialAttack integer
---@field specialDefense integer

---@class TradeRecord
---@field offeredSpecies string
---@field requestedSpecies string
---@field otId integer
---@field personality integer
---@field ivs TradeIvs
---@field heldItem string
---@field otGender integer
---@field language string

---@type TradeRecord[]
local TRADE_RECORDS = {
  {
    offeredSpecies = "ONIX",
    requestedSpecies = "BELLSPROUT",
    otId = 48926,
    personality = 9711,
    ivs = { hp = 25, attack = 20, defense = 25, speed = 15, specialAttack = 15, specialDefense = 15 },
    heldItem = "PERSIM_BERRY",
    otGender = 0,
    language = "english",
  },
  {
    offeredSpecies = "MACHOP",
    requestedSpecies = "DROWZEE",
    otId = 37460,
    personality = 8976,
    ivs = { hp = 15, attack = 25, defense = 20, speed = 20, specialAttack = 15, specialDefense = 15 },
    heldItem = "MACHO_BRACE",
    otGender = 0,
    language = "english",
  },
  {
    offeredSpecies = "VOLTORB",
    requestedSpecies = "KRABBY",
    otId = 29189,
    personality = 475,
    ivs = { hp = 15, attack = 20, defense = 15, speed = 25, specialAttack = 25, specialDefense = 15 },
    heldItem = "CHERI_BERRY",
    otGender = 0,
    language = "english",
  },
  {
    offeredSpecies = "DODRIO",
    requestedSpecies = "DRAGONAIR",
    otId = 283,
    personality = 130058,
    ivs = { hp = 20, attack = 20, defense = 20, speed = 15, specialAttack = 15, specialDefense = 15 },
    heldItem = "SMOKE_BALL",
    otGender = 1,
    language = "english",
  },
  {
    offeredSpecies = "RAPIDASH",
    requestedSpecies = "GLOOM",
    otId = 15616,
    personality = 97913,
    ivs = { hp = 15, attack = 20, defense = 15, speed = 25, specialAttack = 15, specialDefense = 20 },
    heldItem = "ASPEAR_BERRY",
    otGender = 0,
    language = "english",
  },
  {
    offeredSpecies = "STEELIX",
    requestedSpecies = "STEELIX",
    otId = 26491,
    personality = 1054102,
    ivs = { hp = 8, attack = 30, defense = 28, speed = 6, specialAttack = 18, specialDefense = 20 },
    heldItem = "SOOTHE_BELL",
    otGender = 1,
    language = "english",
  },
  {
    offeredSpecies = "SHUCKLE",
    requestedSpecies = "SHUCKLE",
    otId = 69872,
    personality = 136407,
    ivs = { hp = 15, attack = 20, defense = 15, speed = 20, specialAttack = 20, specialDefense = 20 },
    heldItem = "BERRY_JUICE",
    otGender = 0,
    language = "english",
  },
  {
    offeredSpecies = "SPEAROW",
    requestedSpecies = "SPEAROW",
    otId = 1001,
    personality = 27486,
    ivs = { hp = 15, attack = 20, defense = 15, speed = 20, specialAttack = 20, specialDefense = 20 },
    heldItem = "GRASS_MAIL",
    otGender = 0,
    language = "english",
  },
  {
    offeredSpecies = "MAGNETON",
    requestedSpecies = "DUGTRIO",
    otId = 50082,
    personality = 53558,
    ivs = { hp = 15, attack = 20, defense = 15, speed = 20, specialAttack = 20, specialDefense = 20 },
    heldItem = "METAL_COAT",
    otGender = 0,
    language = "english",
  },
  {
    offeredSpecies = "XATU",
    requestedSpecies = "HAUNTER",
    otId = 15616,
    personality = 13540,
    ivs = { hp = 15, attack = 20, defense = 15, speed = 20, specialAttack = 20, specialDefense = 20 },
    heldItem = "WACAN_BERRY",
    otGender = 0,
    language = "english",
  },
  {
    offeredSpecies = "PIKACHU",
    requestedSpecies = "PIKACHU",
    otId = 33038,
    personality = 4741238,
    ivs = { hp = 20, attack = 25, defense = 18, speed = 31, specialAttack = 25, specialDefense = 13 },
    heldItem = "YELLOW_SHARD",
    otGender = 0,
    language = "french",
  },
  {
    offeredSpecies = "RHYHORN",
    requestedSpecies = "BONSLY",
    otId = 6845,
    personality = 1218332,
    ivs = { hp = 22, attack = 31, defense = 13, speed = 0, specialAttack = 22, specialDefense = 9 },
    heldItem = "PASSHO_BERRY",
    otGender = 0,
    language = "english",
  },
  {
    offeredSpecies = "BELDUM",
    requestedSpecies = "FORRETRESS",
    otId = 23478,
    personality = 1226452,
    ivs = { hp = 28, attack = 29, defense = 24, speed = 23, specialAttack = 24, specialDefense = 25 },
    heldItem = "DAWN_STONE",
    otGender = 0,
    language = "english",
  },
}

-- Source loan operands: GiveLoanMon <trade id>, <level>, <map id>. The map id
-- resolves to the map section the loan's meeting memo records.
local KENYA_TRADE_ID = 7
local KENYA_LEVEL = 20
local KENYA_MAP_ID = 101
local KENYA_MAP_SECTION = 183 -- Route 35
local SHUCKIE_TRADE_ID = 6
local SHUCKIE_LEVEL = 20
local SHUCKIE_MAP_SECTION = 130 -- Cianwood City

-- The Kenya record's own OT id is 1001; CreateKenyaMail takes it as a byte, so
-- the letter's author id is its low byte.
local KENYA_AUTHOR_ID = 1001 % 256
-- CreateKenyaMail's three Easy Chat lines: bank 1 message 7 with
-- EC_WORD_LIFESTYLE_LETTER (1349), bank 1 message 15 with
-- EC_WORD_LIFESTYLE_ADVENTURE (1371), and bank 2 message 1 with
-- EC_WORD_POKEMON(SPECIES_ZUBAT) (41); every second field is the source NULL.
local KENYA_MAIL_LINES = {
  { template = "mail-template:1:7", words = { "1349", false } },
  { template = "mail-template:1:15", words = { "1371", false } },
  { template = "mail-template:2:1", words = { "41", false } },
}

local REGISTER_SCORE = GameStats.SCORE_POINTS[GameStats.SCORE_EVENT_REGISTER_SPECIES_CAUGHT]
local ORDINARY_DATE = { year = 2000, month = 1, day = 5, hour = 12, minute = 0, second = 0 }
local OUTGOING_LEVEL = 23
local STARTER_SPECIES = "BELLSPROUT"
local FILLER_SPECIES = { "PIDGEY", "RATTATA", "HOOTHOOT", "SENTRET", "GEODUDE" }

---@param value unknown
---@return unknown
local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for key, child in pairs(value) do
    out[key] = copy(child)
  end
  return out
end

---@param game table
---@param scriptId string
---@return string[] the named script's own published faults
local function scriptFaults(game, scriptId)
  local list = {}
  for _, record in ipairs(game:recordsForScript(scriptId, "script.error")) do
    local payload = record.payload or {}
    local context = payload.context or {}
    list[#list + 1] = string.format(
      "%s/%s/%s",
      tostring(payload.code),
      tostring(context.command or context.originalName or "unknown"),
      tostring(payload.message)
    )
  end
  return list
end

---@param game table
---@return string[] every published script fault
local function allFaults(game)
  local list = {}
  for _, record in ipairs(game:recordsNamed("script.error")) do
    local payload = record.payload or {}
    local context = payload.context or {}
    list[#list + 1] = string.format(
      "%s/%s/%s",
      tostring(payload.scriptId),
      tostring(context.command or context.originalName or "unknown"),
      tostring(payload.message)
    )
  end
  return list
end

local function pressAction(game)
  game.runtime:pressAction()
  game:step()
  game.runtime:releaseAction()
end

local function pressCancel(game)
  game.runtime:pressCancel()
  game:step()
  game.runtime:releaseCancel()
end

local function pressDirection(game, direction)
  game.runtime:press(direction)
  game:step()
  game.runtime:release(direction)
end

---@param game table
---@return table the live mon service
local function mons(game)
  return assert(game.runtime.monService, "the field runtime owns its mon service")
end

---@param game table
---@return integer the live trainer-card score
local function liveScore(game)
  return assert(game.runtime.gameStats, "the runtime owns its statistics"):score()
end

---@param game table
---@return table the live Dex knowledge owner
local function dex(game)
  return assert(game.runtime.dexKnowledge, "the field runtime owns its Dex knowledge")
end

---@param game table
---@return table the live NPC trade service
local function tradeService(game)
  return assert(game.runtime.npcTrade, "the field runtime owns its NPC trade service")
end

---@param game table
---@param label string
---@return table the settled captured game save
local function settledCapture(game, label)
  local lastError = nil
  for _ = 1, 480 do
    local ok, record, reason = pcall(game.runtime.captureGameSave, game.runtime)
    if ok and record ~= nil then
      return record
    end
    lastError = ok and tostring(reason or "capture returned no record") or tostring(record)
    game:step()
  end
  error("the settled field never accepted its save: " .. label .. "; last failure: " .. tostring(lastError), 0)
end

-- The saved mon generator's own draw count, read without touching the live
-- field state.
---@param game table
---@return integer
local function rngCalls(game)
  return assert(mons(game):capture().rng.calls, "the saved mon generator reports its draw count")
end

---@param game table
---@return string? the reason the live field refuses its save
local function deniedSaveReason(game)
  local record, reason = game.runtime:captureGameSave()
  if record ~= nil then
    return nil
  end
  return tostring(reason or "capture returned no record")
end

---@param game table
---@param slot0 integer
---@param change fun(mon: table)
local function stageMon(game, slot0, change)
  local service = mons(game)
  local mon = copy(service:partyMon(slot0))
  change(mon)
  -- Staged individual values or species change the derived maximum, so the
  -- record keeps its own derived full health instead of the health the
  -- original creation draw left.
  mon.condition = { currentHp = service:derive(mon).maxHp, effects = {} }
  local preparation, reason = service:preparePartyChanges(service:partyRevision(), { { slot = slot0, mon = mon } })
  Assert.isNil(reason, "the prepared party change stages cleanly")
  assert(preparation).publish()
end

---@param withDate table
---@return table a recording clock host boundary
local function clockAt(withDate)
  return LocalClock.new(function()
    return copy(withDate)
  end)
end

---@class FieldBoot
---@field map string
---@field tile { fieldX: integer, fieldZ: integer }
---@field mons table?
---@field worldState table?

---@param options FieldBoot
---@return table acceptance game standing on a fresh finalized field
local function bootField(options)
  local harness = AcceptanceHarness.new({
    gameFactory = function(versionId, _)
      return FinalizedGameFixture.build(versionId, {
        location = {
          mapSymbol = options.map,
          fieldX = options.tile.fieldX,
          fieldZ = options.tile.fieldZ,
          facing = "north",
        },
        mons = options.mons,
        worldState = options.worldState,
      })
    end,
  })
  local game = harness:boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = options.map,
    save = "fresh",
    fieldOptions = { recordingScriptHosts = true, audioHost = "recording", localClock = clockAt(ORDINARY_DATE) },
  })
  game:waitForFieldEntry()
  -- Headless composition binds the explicit no-image preparation: the party
  -- picker reports ready without realizing GPU icons it never draws.
  game.runtime:bindPartyIconPreparation(function()
    return true
  end, function() end)
  return game
end

---@param game table
---@param speciesKeys string[]
---@param level integer
local function giftParty(game, speciesKeys, level)
  for _, species in ipairs(speciesKeys) do
    Assert.isTrue(
      mons(game):giveMon({ species = species, level = level }),
      "the party accepts the staged " .. species
    )
  end
end

---@param game table
---@return table? the live party selection status
local function pickerStatus(game)
  local host = game.runtime.partySelection
  if host == nil or not host:isActive() then
    return nil
  end
  return host:status()
end

---@param game table
---@param label string
---@return table the interactive picker status
local function waitPickerInteractive(game, label)
  for _ = 1, 160 do
    local status = pickerStatus(game)
    if
      status ~= nil
      and status.preparationState == "ready"
      and status.phase ~= "opening"
      and status.cursorNode ~= nil
    then
      return status
    end
    game:step()
  end
  error("the party selection never became interactive before " .. label, 0)
end

-- The picker grid is the generated two-column party layout (slot 0 at the
-- top left, then down the left column, then the right one).
---@param cursor integer
---@param slot integer
---@return string
local function directionTo(cursor, slot)
  local cursorRow, cursorColumn = math.floor(cursor / 2), cursor % 2
  local slotRow, slotColumn = math.floor(slot / 2), slot % 2
  if slotRow ~= cursorRow then
    return slotRow > cursorRow and "down" or "up"
  end
  return slotColumn > cursorColumn and "right" or "left"
end

---@param game table
---@param slot integer
local function focusSlot(game, slot)
  for _ = 1, 16 do
    local status = waitPickerInteractive(game, "party slot " .. tostring(slot))
    if status.cursorNode == slot then
      return
    end
    local cursor = status.cursorNode
    local direction = type(cursor) == "number" and directionTo(cursor, slot) or "up"
    pressDirection(game, direction)
  end
  error("the party selection never focused slot " .. tostring(slot), 0)
end

---@param game table
---@param choice "yes"|"no"
local function answerConfirmation(game, choice)
  for _ = 1, 200 do
    local status = assert(pickerStatus(game), "the party selection stays open while its confirmation is answered")
    local prompt = status.prompt
    if prompt ~= nil and prompt.active then
      if prompt.selected == choice then
        pressAction(game)
        for _ = 1, 40 do
          local settled = pickerStatus(game)
          if settled == nil or settled.prompt == nil or settled.prompt.active ~= true then
            return
          end
          game:step()
        end
        return
      end
      pressDirection(game, prompt.selected == "yes" and "down" or "up")
    else
      game:step()
    end
  end
  error("the party selection never confirmed " .. choice, 0)
end

---@param game table
local function cancelPicker(game)
  for _ = 1, 8 do
    if pickerStatus(game) == nil then
      return
    end
    pressCancel(game)
    for _ = 1, 8 do
      if pickerStatus(game) == nil then
        return
      end
      game:step()
    end
  end
  error("the party selection never cancelled", 0)
end

-- Confirms the focused in-game-trade slot: a record carrying a ball capsule
-- asks the source capsule-removal question first, and every other record
-- selects immediately. The opening reveal discards input, so the confirm edge
-- is retried until it lands.
---@param game table
---@param slot integer
---@param capsuleAnswer "yes"|"no"
---@param observed table<string, unknown> receipt for prompt observations
local function confirmTradeSlot(game, slot, capsuleAnswer, observed)
  focusSlot(game, slot)
  for _ = 1, 8 do
    if pickerStatus(game) == nil then
      return
    end
    pressAction(game)
    for _ = 1, 40 do
      local status = pickerStatus(game)
      if status == nil then
        return
      end
      if status.prompt ~= nil and status.prompt.active then
        observed.capsulePrompts[#observed.capsulePrompts + 1] = status.prompt.selected
        answerConfirmation(game, capsuleAnswer)
        return
      end
      game:step()
    end
  end
  error("the trade picker never selected slot " .. tostring(slot), 0)
end

---@class TradeJourney
---@field phases string[] distinct trade phases in the order they were drawn
---@field preparationErrors string[] presentation failures reported by the scene
---@field capsulePrompts string[] every capsule-answer row the picker offered
---@field committed { species: string, score: integer, caught: boolean }? state at the first trade frame

---@return TradeJourney
local function newJourney()
  return { phases = {}, preparationErrors = {}, capsulePrompts = {}, committed = nil }
end

-- Reads the live care child and records the trade scene's own progress. The
-- receipt is committed before the sequence starts, so the first trade frame
-- is the point where the party, Dex and score must already show the exchange.
---@param game table
---@param journey TradeJourney
local function observeTradeChild(game, journey)
  local host = game.runtime.pokemonCareHost
  if host == nil then
    return
  end
  local snapshot = host:snapshot()
  if snapshot == nil or snapshot.kind ~= "trade" then
    return
  end
  if snapshot.phase ~= nil and journey.phases[#journey.phases] ~= snapshot.phase then
    journey.phases[#journey.phases + 1] = snapshot.phase
  end
  if snapshot.preparationError ~= nil then
    journey.preparationErrors[#journey.preparationErrors + 1] = tostring(snapshot.preparationError)
  end
  if journey.committed == nil then
    local service = mons(game)
    journey.committed = {
      species = service:partyCount() > 0 and service:partyMon(0).species or nil,
      score = liveScore(game),
      caught = dex(game):isCaught("ONIX"),
      saveDenied = deniedSaveReason(game),
    }
  end
end

---@param game table
---@param scriptId string
---@return integer how many times the named script ended
local function scriptEnds(game, scriptId)
  return #game:recordsForScript(scriptId, "script.ended")
end

---@param game table
---@param scriptId string
---@return integer how many times the named script ended
local function scriptEnds(game, scriptId)
  return #game:recordsForScript(scriptId, "script.ended")
end

---@param game table
---@param scriptId string
---@param label string
---@param handlers fun(game: table, status: table)[]
---@param done fun(): boolean
---@param journey TradeJourney?
---@return integer[] every dialogue message id the run printed
local function runSourceScript(game, scriptId, label, handlers, done, journey, maxTicks)
  local queue = handlers or {}
  local nextHandler = 1
  local printed = {}
  local lastPrinted = nil
  for _ = 1, maxTicks or 24000 do
    local faults = scriptFaults(game, scriptId)
    Assert.equal(
      #faults,
      0,
      "the source trade script completes every native operation before " .. label .. ": " .. table.concat(faults, ",")
    )
    if done() then
      return printed
    end
    if journey ~= nil then
      observeTradeChild(game, journey)
    end
    local status = pickerStatus(game)
    if status ~= nil then
      local handler = queue[nextHandler]
      Assert.notNil(handler, "the source script opens an unexpected party selection before " .. label)
      nextHandler = nextHandler + 1
      handler(game, status)
    elseif game:contextChoiceStatus() ~= nil then
      local choice = assert(game:contextChoiceStatus(), "the source choice provider stays live while answering")
      if choice.selected == 0 then
        pressAction(game)
      else
        pressDirection(game, "up")
      end
    elseif game:snapshot().dialogue.modal then
      local messageId = game:snapshot().dialogue.messageId
      if messageId ~= nil and messageId ~= lastPrinted then
        printed[#printed + 1] = messageId
        lastPrinted = messageId
      end
      pressAction(game)
    else
      game:step()
    end
  end
  error(
    "the source script never reached "
      .. label
      .. "; modal="
      .. tostring(game:snapshot().dialogue.modal)
      .. ", message="
      .. tostring(game:snapshot().dialogue.messageId)
      .. ", foreground="
      .. tostring(game:snapshot().foregroundScript)
      .. ", picker="
      .. tostring(pickerStatus(game) ~= nil)
      .. ", faults="
      .. table.concat(allFaults(game), ","),
    0
  )
end

-- The Violet City trade house boy receives the source exchange: the record is
-- built from the trade table, replaces the selected slot, registers the Dex
-- and score receipt once before the fade-out, and the seven app71 scenes play
-- with their own sounds while the field refuses to save.
function T.tests.the_source_trade_house_swaps_the_selected_mon_once()
  local game = bootField({ map = ONIX_MAP, tile = ONIX_TILE })
  local ok, err = xpcall(function()
    giftParty(game, { STARTER_SPECIES, unpack(FILLER_SPECIES) }, OUTGOING_LEVEL)
    Assert.equal(mons(game):partyCount(), 6, "the scenario trades away a mon from a full party")
    local outgoing = copy(mons(game):partyMon(0))
    local scoreBefore = liveScore(game)
    local drawsBefore = rngCalls(game)
    local effectsFrom = #game:hostEffects()

    local journey = newJourney()
    game:pressAction()
    runSourceScript(
      game,
      ONIX_SCRIPT,
      "the source exchange and field return",
      {
        function(active)
          confirmTradeSlot(active, 0, "no", journey)
        end,
      },
      function()
        return scriptEnds(game, ONIX_SCRIPT) > 0 and not game:snapshot().fieldLocked
      end,
      journey
    )

    Assert.equal(#scriptFaults(game, ONIX_SCRIPT), 0, "the source trade script publishes no fault")
    Assert.equal(#allFaults(game), 0, "the trade journey publishes no unrelated script fault")

    -- The receipt is committed before the source fade-out, so the first trade
    -- frame already sees the exchanged record, its Dex entry and its score.
    local committed = assert(journey.committed, "the trade sequence reports its own first frame")
    Assert.equal(committed.species, "ONIX", "the exchange replaces the selected slot before the sequence")
    Assert.isTrue(committed.caught, "the exchange registers the offered species before the sequence")
    Assert.equal(committed.score - scoreBefore, REGISTER_SCORE, "the exchange scores the registration once")
    Assert.notNil(committed.saveDenied, "the field refuses to save while the trade application owns it")

    Assert.deepEqual(
      journey.phases,
      TRADE_PHASES,
      "the trade plays the seven source scenes in order: " .. table.concat(journey.phases, ",")
    )
    Assert.equal(#journey.capsulePrompts, 0, "a capsule-free record trades without the removal question")

    local effects = {}
    for index = effectsFrom + 1, #game:hostEffects() do
      effects[#effects + 1] = game:hostEffects()[index]
    end
    local function position(wanted)
      for index, effect in ipairs(effects) do
        if effect == wanted then
          return index
        end
      end
      return nil
    end
    local music = position(TRADE_MUSIC)
    local sent = position(TRADE_SEND_SE)
    local exchanged = position(TRADE_EXCHANGE_SE)
    local approached = position(TRADE_APPROACH_SE)
    Assert.notNil(music, "the sequence starts the source trade music: " .. table.concat(effects, ","))
    Assert.notNil(sent, "the send scene plays its source sound")
    Assert.notNil(exchanged, "the exchange scene plays its source sound")
    Assert.notNil(approached, "the approach scene plays its source sound")
    Assert.isTrue(
      music < sent and sent < exchanged and exchanged < approached,
      "the trade sounds follow the source scene order"
    )

    Assert.equal(rngCalls(game) - drawsBefore, 2, "the exchange consumes the source's two creation draws")

    local settled = settledCapture(game, "the finished trade")
    Assert.equal(mons(game):partyCount(), 6, "an equal-slot exchange keeps the full party")
    local incoming = assert(settled.mons.party.mons[1], "the captured party carries the received record")
    Assert.equal(incoming.species, "ONIX", "the selected slot holds the offered species")
    Assert.isNil(settled.mons.party.mons[1].mail.author, "a normal exchange carries no source letter")
    for index = 1, mons(game):partyCount() do
      Assert.notNil(mons(game):partyMon(index - 1).species, "every party slot stays populated")
    end
    local survivours = {}
    for index = 0, mons(game):partyCount() - 1 do
      survivours[#survivours + 1] = mons(game):partyMon(index).personality
    end
    for _, personality in ipairs(survivours) do
      Assert.isTrue(personality ~= outgoing.personality, "the traded-away record left the party")
    end
    Assert.equal(
      settled.gameStats.score - scoreBefore,
      REGISTER_SCORE,
      "the finished trade scores the registration once"
    )
    Assert.isTrue(settled.world.flags[ONIX_FLAG] == true, "the source script sets its own trade flag")
    Assert.equal(scriptEnds(game, ONIX_SCRIPT), 1, "the source script completes exactly once")

    -- Repeated polling after completion never exchanges a second time.
    for _ = 1, 600 do
      game:step()
    end
    local repeated = settledCapture(game, "the settled trade")
    Assert.equal(#repeated.mons.party.mons, 6, "repeated polling never appends another record")
    Assert.equal(repeated.gameStats.score, settled.gameStats.score, "repeated polling never scores the exchange twice")
    Assert.equal(rngCalls(game), drawsBefore + 2, "repeated polling draws nothing")
    Assert.equal(scriptEnds(game, ONIX_SCRIPT), 1, "repeated polling never restarts the source script")
    Assert.equal(#game:recordsForScript(ONIX_SCRIPT, "script.started"), 1, "the source script started once")
    Assert.equal(game:renderAttempts(), 0, "the trade scenario stops before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

-- Every generated trade record produces its own source identity: the offered
-- and requested species 471/472 publish, the fixed personality and OT id, the
-- six individual values written after exactly two creation draws, the held
-- item, the OT gender and the record language, at the outgoing mon's level,
-- with the source meeting memo and no second Dex or score receipt.
function T.tests.every_source_trade_record_creates_its_recorded_identity()
  local game = bootField({ map = ONIX_MAP, tile = ONIX_TILE })
  local ok, err = xpcall(function()
    giftParty(game, { STARTER_SPECIES }, OUTGOING_LEVEL)
    local service = tradeService(game)
    local outgoing = copy(mons(game):partyMon(0))
    local drawsBefore = rngCalls(game)

    for index, expected in ipairs(TRADE_RECORDS) do
      local tradeId = index - 1
      local identity = service:tradeIdentity(tradeId)
      Assert.equal(
        identity.offeredSpecies,
        expected.offeredSpecies,
        "trade " .. tradeId .. " offers its source species"
      )
      Assert.equal(
        identity.requestedSpecies,
        expected.requestedSpecies,
        "trade " .. tradeId .. " requests its source species"
      )
      Assert.equal(identity.personality, expected.personality, "trade " .. tradeId .. " keeps its fixed personality")
      Assert.equal(identity.otId, expected.otId, "trade " .. tradeId .. " keeps its fixed OT id")
      Assert.equal(identity.heldItem, expected.heldItem, "trade " .. tradeId .. " keeps its source held item")
      Assert.equal(identity.otGender, expected.otGender, "trade " .. tradeId .. " keeps its source OT gender")
      Assert.equal(identity.language, expected.language, "trade " .. tradeId .. " keeps its source language")
      Assert.deepEqual(identity.ivs, expected.ivs, "trade " .. tradeId .. " keeps its source individual values")
      Assert.isTrue(
        type(identity.nickname) == "string" and #identity.nickname > 0,
        "trade " .. tradeId .. " carries the source message nickname"
      )
      Assert.isTrue(
        type(identity.otName) == "string" and #identity.otName > 0,
        "trade " .. tradeId .. " carries the source message OT name"
      )

      -- Restage the outgoing record so every trade starts from the same live
      -- party slot instead of trading the previous record away.
      local revision = mons(game):partyRevision()
      local preparation, reason = mons(game):preparePartyChanges(revision, { { slot = 0, mon = copy(outgoing) } })
      Assert.isNil(reason, "trade " .. tradeId .. " restages its outgoing record")
      assert(preparation).publish()
      local scoreBefore = liveScore(game)
      local caughtBefore = dex(game):isCaught(expected.offeredSpecies)

      local exchanged = service:exchange(tradeId, 0)
      Assert.notNil(exchanged, "trade " .. tradeId .. " completes its exchange")
      Assert.equal(
        exchanged.outgoing.personality,
        outgoing.personality,
        "trade " .. tradeId .. " reports the outgoing record"
      )
      local incoming = exchanged.incoming
      Assert.equal(incoming.species, expected.offeredSpecies, "trade " .. tradeId .. " receives the offered species")
      Assert.equal(incoming.personality, expected.personality, "trade " .. tradeId .. " receives the fixed personality")
      Assert.deepEqual(incoming.ivs, expected.ivs, "trade " .. tradeId .. " replaces all six individual values")
      Assert.equal(incoming.heldItem, expected.heldItem, "trade " .. tradeId .. " receives the source held item")
      Assert.equal(incoming.nickname, identity.nickname, "trade " .. tradeId .. " receives the source nickname")
      Assert.equal(incoming.origin.trainerId, expected.otId, "trade " .. tradeId .. " receives the source OT id")
      Assert.equal(incoming.origin.trainerName, identity.otName, "trade " .. tradeId .. " receives the source OT name")
      Assert.equal(
        incoming.origin.trainerGender,
        expected.otGender,
        "trade " .. tradeId .. " receives the source OT gender"
      )
      Assert.equal(incoming.origin.language, expected.language, "trade " .. tradeId .. " receives the source language")
      Assert.equal(incoming.origin.game, outgoing.origin.game, "trade " .. tradeId .. " keeps the current game")
      Assert.isFalse(incoming.isEgg, "trade " .. tradeId .. " receives a non-egg record")
      Assert.equal(incoming.capsule.id, 0, "trade " .. tradeId .. " receives no ball capsule")
      Assert.isTrue(next(incoming.mail) == nil, "trade " .. tradeId .. " receives no letter")
      Assert.equal(
        mons(game):derive(incoming).level,
        OUTGOING_LEVEL,
        "trade " .. tradeId .. " keeps the outgoing level"
      )
      Assert.deepEqual(
        incoming.met.date,
        { year = 2000, month = 1, day = 5 },
        "trade " .. tradeId .. " memo dates today"
      )
      Assert.equal(incoming.met.level, OUTGOING_LEVEL, "trade " .. tradeId .. " memo copies the outgoing level")
      Assert.equal(mons(game):partyCount(), 1, "trade " .. tradeId .. " replaces the slot instead of appending")
      Assert.equal(
        mons(game):partyMon(0).species,
        expected.offeredSpecies,
        "trade " .. tradeId .. " publishes the slot"
      )
      Assert.isTrue(dex(game):isCaught(expected.offeredSpecies), "trade " .. tradeId .. " registers the Dex receipt")
      local expectedScore = caughtBefore and scoreBefore or scoreBefore + REGISTER_SCORE
      Assert.equal(liveScore(game), expectedScore, "trade " .. tradeId .. " scores only a fresh registration")
    end

    -- A repeated exchange of an already registered species never scores again.
    local revision = mons(game):partyRevision()
    local preparation, reason = mons(game):preparePartyChanges(revision, { { slot = 0, mon = copy(outgoing) } })
    Assert.isNil(reason, "the repeated trade restages its outgoing record")
    assert(preparation).publish()
    local scoreBefore = liveScore(game)
    tradeService(game):exchange(0, 0)
    Assert.equal(liveScore(game), scoreBefore, "a repeated exchange of the same species scores nothing")

    local settled = settledCapture(game, "every source trade record")
    Assert.equal(settled.gameStats.score, liveScore(game), "the settled save keeps the live score")
    Assert.equal(
      rngCalls(game) - drawsBefore,
      (#TRADE_RECORDS + 1) * 2,
      "every exchange consumes exactly the source's two creation draws"
    )
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

-- The Cianwood house lends the source Shuckle: GiveLoanMon publishes the
-- level-20 record from the loan operands with the map section meeting memo,
-- its Dex receipt and score, no letter and no trade sequence. The return
-- branch then asks the source return check, removes the record through the
-- ordinary removal primitive and sets the source flags.
function T.tests.the_source_loan_hands_out_and_takes_back_the_shuckle()
  local given = bootField({ map = LOAN_MAP, tile = LOAN_TILE })
  local record = nil
  local ok, err = xpcall(function()
    giftParty(given, { "PIDGEY", "RATTATA" }, OUTGOING_LEVEL)
    local scoreBefore = liveScore(given)
    local drawsBefore = rngCalls(given)
    local effectsFrom = #given:hostEffects()

    local journey = newJourney()
    given:pressAction()
    runSourceScript(
      given,
      LOAN_SCRIPT,
      "the loaned record",
      {},
      function()
        return scriptEnds(given, LOAN_SCRIPT) > 0 and not given:snapshot().fieldLocked
      end,
      journey
    )
    Assert.equal(#scriptFaults(given, LOAN_SCRIPT), 0, "the source loan script publishes no fault")
    Assert.equal(mons(given):partyCount(), 3, "the loan appends its record to the party")
    local loaned = mons(given):partyMon(2)
    Assert.equal(loaned.species, "SHUCKLE", "the loan hands out the source species")
    Assert.equal(mons(given):derive(loaned).level, SHUCKIE_LEVEL, "the loan hands out the source level")
    Assert.equal(
      loaned.personality,
      TRADE_RECORDS[SHUCKIE_TRADE_ID + 1].personality,
      "the loan keeps its fixed personality"
    )
    Assert.equal(loaned.origin.trainerId, TRADE_RECORDS[SHUCKIE_TRADE_ID + 1].otId, "the loan keeps its source OT id")
    Assert.equal(loaned.met.location, SHUCKIE_MAP_SECTION, "the loan memo records the source map section")
    Assert.equal(loaned.met.level, SHUCKIE_LEVEL, "the loan memo records the loan level")
    Assert.isTrue(dex(given):isCaught("SHUCKLE"), "the loan registers its Dex receipt")
    Assert.equal(loaned.heldItem, "BERRY_JUICE", "the loan keeps the source record's held item")
    Assert.equal(liveScore(given) - scoreBefore, REGISTER_SCORE, "the loan scores the registration once")
    Assert.isTrue(next(loaned.mail) == nil, "the Shuckle loan carries no source letter")
    Assert.equal(#journey.phases, 0, "a source loan adds no trade sequence: " .. table.concat(journey.phases, ","))
    local effects = {}
    for index = effectsFrom + 1, #given:hostEffects() do
      effects[#effects + 1] = given:hostEffects()[index]
    end
    for _, effect in ipairs(effects) do
      Assert.isTrue(effect ~= TRADE_MUSIC, "a source loan plays no trade music: " .. table.concat(effects, ","))
    end
    Assert.equal(
      rngCalls(given) - drawsBefore,
      2,
      "the loan consumes the source's two creation draws"
    )
    record = settledCapture(given, "the loaned party")
  end, debug.traceback)
  given:close()
  if not ok then
    error(err, 0)
  end

  -- The return branch runs on the next day's save: the daily gate is cleared
  -- and the source "loan taken" flag is set by the give branch the record
  -- carries.
  local worldState = FieldEventState.new()
  worldState:setFlag(SHUCKIE_GIVEN_FLAG)
  local returned = bootField({ map = LOAN_MAP, tile = LOAN_TILE, mons = copy(record.mons), worldState = worldState })
  local okReturn, errReturn = xpcall(function()
    Assert.equal(mons(returned):partyCount(), 3, "the continued save carries the loaned record")
    -- The source return check refuses a record that still holds an item, so
    -- the player takes the source Berry Juice off first.
    stageMon(returned, 2, function(mon)
      mon.heldItem = "NONE"
    end)
    returned:pressAction()
    runSourceScript(
      returned,
      LOAN_SCRIPT,
      "the returned record",
      {
        function(active)
          confirmTradeSlot(active, 2, "no", newJourney())
        end,
      },
      function()
        return scriptEnds(returned, LOAN_SCRIPT) > 0 and not returned:snapshot().fieldLocked
      end,
      nil
    )
    Assert.equal(#scriptFaults(returned, LOAN_SCRIPT), 0, "the source return script publishes no fault")
    Assert.equal(mons(returned):partyCount(), 2, "the return removes the loaned record")
    for index = 0, mons(returned):partyCount() - 1 do
      Assert.isTrue(mons(returned):partyMon(index).species ~= "SHUCKLE", "the returned record left the party")
    end
    local settled = settledCapture(returned, "the returned loan")
    Assert.isTrue(settled.world.flags[SHUCKIE_RETURNED_FLAG] == true, "the source script flags its own return")
    Assert.equal(#allFaults(returned), 0, "the return journey publishes no unrelated script fault")
    Assert.equal(returned:renderAttempts(), 0, "the loan scenarios stop before GPU rendering")
  end, debug.traceback)
  returned:close()
  if not okReturn then
    error(errReturn, 0)
  end
end

-- The Kenya loan keeps the source identity and publishes the source letter:
-- the record's own map section memo, one Dex/score receipt, and the attached
-- letter the helper builds from the record's OT id, its OT name, the current
-- language/game and the three Easy Chat lines. The letter costs the loan no
-- second dummy creation, while an independent helper call consumes the dummy's
-- own two draws and returns the same detached letter.
function T.tests.the_kenya_loan_carries_the_source_letter()
  local game = bootField({ map = ONIX_MAP, tile = ONIX_TILE })
  local ok, err = xpcall(function()
    giftParty(game, { STARTER_SPECIES }, OUTGOING_LEVEL)
    local service = tradeService(game)
    local drawsBefore = rngCalls(game)
    local scoreBefore = liveScore(game)

    local received = service:giveLoan({ tradeId = KENYA_TRADE_ID, level = KENYA_LEVEL, mapId = KENYA_MAP_ID })
    Assert.notNil(received, "the Kenya loan hands out its record")
    Assert.equal(received.species, "SPEAROW", "the loan hands out the source species")
    Assert.equal(mons(game):derive(received).level, KENYA_LEVEL, "the loan hands out the source level")
    Assert.equal(received.personality, TRADE_RECORDS[KENYA_TRADE_ID + 1].personality, "the loan keeps its personality")
    Assert.equal(received.origin.trainerId, TRADE_RECORDS[KENYA_TRADE_ID + 1].otId, "the loan keeps its OT id")
    Assert.equal(received.met.location, KENYA_MAP_SECTION, "the loan memo records the source map section")
    Assert.equal(received.met.level, KENYA_LEVEL, "the loan memo records the loan level")
    Assert.deepEqual(received.met.date, { year = 2000, month = 1, day = 5 }, "the loan memo dates today")
    Assert.isTrue(dex(game):isCaught("SPEAROW"), "the loan registers its Dex receipt")
    Assert.equal(liveScore(game) - scoreBefore, REGISTER_SCORE, "the loan scores the registration once")
    Assert.equal(
      rngCalls(game) - drawsBefore,
      2,
      "the Kenya loan consumes only the record's two creation draws"
    )

    local mail = assert(received.mail, "the Kenya loan attaches the source letter")
    Assert.equal(mail.schema, "g4-mail-v2", "the loan carries the current Mail record")
    Assert.equal(mail.type, 0, "the letter uses the source grass-mail stationery")
    Assert.equal(mail.author.trainerId, KENYA_AUTHOR_ID, "the letter author id is the source byte truncation")
    Assert.equal(mail.author.gender, TRADE_RECORDS[KENYA_TRADE_ID + 1].otGender, "the letter keeps the loan OT gender")
    Assert.equal(
      mail.author.language,
      HgssMonService.LANGUAGES[assert(game.runtime.monLanguage, "the field names its mon language")],
      "the letter keeps the current language"
    )
    Assert.equal(
      mail.author.game,
      HgssMonService.GAMES[assert(game.runtime.versionId, "the field names its version")],
      "the letter keeps the current game"
    )
    Assert.equal(mail.author.name, received.origin.trainerName, "the letter author is the loan's own OT name")
    Assert.equal(mail.icons[1], "SPEAROW/f0", "the first letter icon is the loaned species")
    Assert.isFalse(mail.icons[2], "the second letter icon stays empty")
    Assert.isFalse(mail.icons[3], "the third letter icon stays empty")
    Assert.deepEqual(mail.lines, KENYA_MAIL_LINES, "the letter carries the three source Easy Chat lines")

    local mailDrawsBefore = rngCalls(game)
    local independent = service:createKenyaMail()
    Assert.equal(
      rngCalls(game) - mailDrawsBefore,
      2,
      "an independent reference letter pays the dummy creation's own two draws"
    )
    Assert.deepEqual(independent, mail, "the helper returns the same detached source letter")
    Assert.equal(mons(game):partyCount(), 2, "the reference letter never creates a second loan record")
    Assert.equal(mons(game):partyMon(1).species, "SPEAROW", "the loaned record stays in its party slot")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

-- The source return check ranks a wrong identity first, then a ball capsule,
-- then a party that cannot spare the record, then a held item, and finally
-- accepts the loan. Kenya's record accepts both its own species and the
-- evolved Fearow; the Shuckle loan accepts only its own species.
function T.tests.the_return_check_ranks_identity_before_capsule_party_and_held_item()
  local game = bootField({ map = ONIX_MAP, tile = ONIX_TILE })
  local ok, err = xpcall(function()
    giftParty(game, { STARTER_SPECIES, "PIDGEY" }, OUTGOING_LEVEL)
    local service = tradeService(game)
    Assert.notNil(
      service:giveLoan({ tradeId = KENYA_TRADE_ID, level = KENYA_LEVEL, mapId = KENYA_MAP_ID }),
      "the scenario lends the Kenya record"
    )
    local slot = mons(game):partyCount() - 1
    Assert.equal(mons(game):partyMon(slot).species, "SPEAROW", "the loan lands in the party")
    Assert.equal(
      service:checkReturn(KENYA_TRADE_ID, slot),
      2,
      "the loan's own source held item blocks the return until it is taken off"
    )

    local companions = { copy(mons(game):partyMon(0)), copy(mons(game):partyMon(1)) }

    ---@param record table
    ---@return table the same record carrying its own derived full health
    local function withFullHealth(record)
      local candidate = copy(record)
      candidate.condition = { currentHp = mons(game):derive(candidate).maxHp, effects = {} }
      return candidate
    end

    ---@param record table
    ---@param target integer
    local function store(record, target)
      local preparation, reason =
        mons(game):preparePartyChanges(mons(game):partyRevision(), { { slot = target, mon = copy(record) } })
      Assert.isNil(reason, "the staged party change prepares")
      assert(preparation).publish()
    end

    -- The pristine reference is the loan with its source item taken off: the
    -- player has to remove the held item before the return check accepts it.
    local pristine = copy(mons(game):partyMon(slot))
    pristine.heldItem = "NONE"
    store(withFullHealth(pristine), slot)
    Assert.equal(service:checkReturn(KENYA_TRADE_ID, slot), 0, "the loan without its held item returns cleanly")

    ---@param change fun(mon: table)
    ---@param expected integer
    ---@param label string
    local function check(change, expected, label)
      local variant = copy(pristine)
      change(variant)
      store(withFullHealth(variant), slot)
      Assert.equal(service:checkReturn(KENYA_TRADE_ID, slot), expected, label)
    end

    check(function(mon)
      mon.nickname = "BIRD"
    end, 1, "a renamed loan record fails the identity check")
    check(function(mon)
      mon.origin.trainerName = "NOTKENY"
    end, 1, "a different OT name fails the identity check")
    check(function(mon)
      mon.origin.trainerId = TRADE_RECORDS[KENYA_TRADE_ID + 1].otId + 1
    end, 1, "a different OT id fails the identity check")
    check(function(mon)
      mon.personality = TRADE_RECORDS[KENYA_TRADE_ID + 1].personality + 2
    end, 1, "a different personality fails the identity check")
    check(function(mon)
      mon.origin.trainerGender = 1
    end, 1, "a different OT gender fails the identity check")
    check(function(mon)
      mon.origin.language = "french"
    end, 1, "a different language fails the identity check")
    check(function(mon)
      mon.origin.game = "diamond"
    end, 1, "a different game fails the identity check")
    check(function(mon)
      mon.species = "PIDGEY"
    end, 1, "an unrelated species fails the identity check")
    check(function(mon)
      mon.species = "FEAROW"
    end, 0, "the evolved Fearow is still the source loan record")
    check(function(mon)
      mon.capsule = { id = 4, seals = {} }
    end, 3, "a ball capsule blocks the return")

    local capsuleAndNickname = copy(pristine)
    capsuleAndNickname.capsule = { id = 4, seals = {} }
    capsuleAndNickname.nickname = "BIRD"
    store(withFullHealth(capsuleAndNickname), slot)
    Assert.equal(service:checkReturn(KENYA_TRADE_ID, slot), 1, "a wrong identity outranks the ball capsule")

    -- A party that cannot spare the loan outranks the held item.
    store(withFullHealth(pristine), slot)
    for index = 1, 2 do
      local fainted = copy(companions[index])
      fainted.condition = { currentHp = 0, effects = {} }
      store(fainted, index - 1)
    end
    local heldVariant = copy(pristine)
    heldVariant.heldItem = "ORAN_BERRY"
    store(withFullHealth(heldVariant), slot)
    Assert.equal(service:checkReturn(KENYA_TRADE_ID, slot), 4, "a party without two living records blocks the return")

    -- With both companions living again the held item decides.
    for index = 1, 2 do
      store(withFullHealth(companions[index]), index - 1)
    end
    Assert.equal(service:checkReturn(KENYA_TRADE_ID, slot), 2, "a held item blocks the return")
    store(withFullHealth(pristine), slot)
    Assert.equal(service:checkReturn(KENYA_TRADE_ID, slot), 0, "the loan returns once the checks pass")

    -- The Shuckle loan shares the identity and held-item rules but has no
    -- evolved allowance, and the ordinary removal primitive is unchanged.
    Assert.notNil(
      service:giveLoan({ tradeId = SHUCKIE_TRADE_ID, level = SHUCKIE_LEVEL, mapId = 75 }),
      "the scenario also lends the Shuckle"
    )
    local shuckieSlot = mons(game):partyCount() - 1
    local shuckie = copy(mons(game):partyMon(shuckieSlot))
    Assert.equal(shuckie.species, "SHUCKLE", "the second loan lands in the party")
    Assert.equal(
      service:checkReturn(SHUCKIE_TRADE_ID, shuckieSlot),
      2,
      "the Shuckle loan's own source held item blocks the return"
    )
    shuckie.heldItem = "NONE"
    store(withFullHealth(shuckie), shuckieSlot)
    Assert.equal(
      service:checkReturn(SHUCKIE_TRADE_ID, shuckieSlot),
      0,
      "the loan without its held item returns cleanly"
    )
    local evolved = copy(shuckie)
    evolved.species = "FEAROW"
    evolved.ability = "KEEN_EYE"
    store(withFullHealth(evolved), shuckieSlot)
    Assert.equal(service:checkReturn(SHUCKIE_TRADE_ID, shuckieSlot), 1, "the Shuckle loan has no evolved allowance")
    store(withFullHealth(shuckie), shuckieSlot)
    Assert.equal(service:checkReturn(SHUCKIE_TRADE_ID, shuckieSlot), 0, "the restored loan passes again")

    local counted = mons(game):partyCount()
    local removed = mons(game):returnLoanMon(shuckieSlot)
    Assert.equal(removed.species, "SHUCKLE", "the ordinary removal primitive returns the record")
    Assert.equal(mons(game):partyCount(), counted - 1, "the ordinary removal primitive shrinks the party")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

-- The source capsule question decides the trade. A declined removal returns to
-- the picker and a cancelled selection leaves the party, the capsule and the
-- source flag untouched; an accepted removal clears the capsule through the
-- existing mon owner and trades the record as usual.
function T.tests.a_declined_capsule_confirmation_leaves_the_trade_undone()
  local game = bootField({ map = ONIX_MAP, tile = ONIX_TILE })
  local ok, err = xpcall(function()
    giftParty(game, { STARTER_SPECIES }, OUTGOING_LEVEL)
    local service = mons(game)
    stageMon(game, 0, function(mon)
      mon.capsule = { id = 7, seals = {} }
    end)
    local outgoing = copy(service:partyMon(0))
    local scoreBefore = liveScore(game)

    local journey = newJourney()
    game:pressAction()
    runSourceScript(
      game,
      ONIX_SCRIPT,
      "the declined trade",
      {
        function(active)
          confirmTradeSlot(active, 0, "no", journey)
          cancelPicker(active)
        end,
      },
      function()
        return scriptEnds(game, ONIX_SCRIPT) > 0 and not game:snapshot().fieldLocked
      end,
      journey
    )
    Assert.equal(#scriptFaults(game, ONIX_SCRIPT), 0, "the declined trade publishes no script fault")
    Assert.equal(#journey.capsulePrompts, 1, "the picker asked the source capsule question once")
    Assert.equal(mons(game):partyCount(), 1, "the declined confirmation exchanges nothing")
    Assert.equal(mons(game):partyMon(0).personality, outgoing.personality, "the selected record stays in its slot")
    Assert.equal(mons(game):partyMon(0).capsule.id, 7, "a declined confirmation keeps the ball capsule")
    Assert.equal(liveScore(game), scoreBefore, "a declined confirmation scores nothing")
    Assert.isFalse(dex(game):isCaught("ONIX"), "a declined confirmation registers nothing")
    Assert.equal(#journey.phases, 0, "a declined confirmation never plays the trade sequence")
    local settled = settledCapture(game, "the declined trade")
    Assert.isNil(settled.world.flags[ONIX_FLAG], "the source script keeps its trade flag unset")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end

  local accepted = bootField({ map = ONIX_MAP, tile = ONIX_TILE })
  local okAccepted, errAccepted = xpcall(function()
    giftParty(accepted, { STARTER_SPECIES }, OUTGOING_LEVEL)
    stageMon(accepted, 0, function(mon)
      mon.capsule = { id = 7, seals = {} }
    end)
    local acceptedScore = liveScore(accepted)
    local acceptedJourney = newJourney()
    accepted:pressAction()
    runSourceScript(
      accepted,
      ONIX_SCRIPT,
      "the accepted trade",
      {
        function(active)
          confirmTradeSlot(active, 0, "yes", acceptedJourney)
        end,
      },
      function()
        return scriptEnds(accepted, ONIX_SCRIPT) > 0 and not accepted:snapshot().fieldLocked
      end,
      acceptedJourney
    )
    Assert.equal(#scriptFaults(accepted, ONIX_SCRIPT), 0, "the accepted trade publishes no script fault")
    Assert.equal(#acceptedJourney.capsulePrompts, 1, "the accepted trade answers the source capsule question")
    Assert.equal(#acceptedJourney.phases, #TRADE_PHASES, "the accepted trade plays every source scene")
    Assert.equal(mons(accepted):partyCount(), 1, "the accepted trade keeps the party size")
    Assert.equal(mons(accepted):partyMon(0).species, "ONIX", "the accepted trade replaces the selected slot")
    Assert.equal(liveScore(accepted) - acceptedScore, REGISTER_SCORE, "the accepted trade scores once")
    Assert.isTrue(dex(accepted):isCaught("ONIX"), "the accepted trade registers the offered species")
    local settled = settledCapture(accepted, "the accepted trade")
    Assert.isTrue(settled.world.flags[ONIX_FLAG] == true, "the accepted trade sets its source flag")
    Assert.equal(accepted:renderAttempts(), 0, "the capsule scenarios stop before GPU rendering")
  end, debug.traceback)
  accepted:close()
  if not okAccepted then
    error(errAccepted, 0)
  end
end

-- A presentation failure after the committed exchange keeps exactly one
-- receipt: the record, its Dex entry and its score publish once, the scene
-- reports the failure instead of replaying the exchange, and the child plus
-- its presentation lease are released exactly once.
function T.tests.a_failed_trade_presentation_keeps_one_receipt_and_releases_the_application()
  local game = bootField({ map = ONIX_MAP, tile = ONIX_TILE })
  local ok, err = xpcall(function()
    giftParty(game, { STARTER_SPECIES }, OUTGOING_LEVEL)
    local scoreBefore = liveScore(game)
    local lease = { prepared = 0, released = 0 }
    function lease:prepare()
      self.prepared = self.prepared + 1
      return { kind = "failed", error = "acceptance presentation failure" }
    end
    function lease:presentation()
      return nil
    end
    function lease:release()
      self.released = self.released + 1
    end
    game.runtime:bindPokemonCarePresentation(function()
      return lease
    end)

    local journey = newJourney()
    game:pressAction()
    runSourceScript(
      game,
      ONIX_SCRIPT,
      "the failed presentation",
      {
        function(active)
          confirmTradeSlot(active, 0, "no", journey)
        end,
      },
      function()
        return scriptEnds(game, ONIX_SCRIPT) > 0 and not game:snapshot().fieldLocked
      end,
      journey
    )

    Assert.isTrue(#journey.preparationErrors > 0, "the trade scene reports its unusable presentation")
    Assert.equal(#scriptFaults(game, ONIX_SCRIPT), 0, "a presentation failure does not fault the source script")
    Assert.equal(mons(game):partyCount(), 1, "the failed presentation keeps one exchanged record")
    local received = 0
    for index = 0, mons(game):partyCount() - 1 do
      if mons(game):partyMon(index).species == "ONIX" then
        received = received + 1
      end
    end
    Assert.equal(received, 1, "the failed presentation never duplicates the received record")
    Assert.equal(liveScore(game) - scoreBefore, REGISTER_SCORE, "the failed presentation scores the receipt once")
    Assert.equal(lease.released, 1, "the presentation lease is released exactly once")
    Assert.isFalse(
      assert(game.runtime.pokemonCareHost, "the field owns its care host"):isActive(),
      "the failed presentation releases the care child"
    )
    Assert.isNil(
      assert(game.runtime.pokemonCareHost, "the field owns its care host"):snapshot(),
      "no trade scene survives the released child"
    )
    local settled = settledCapture(game, "the failed presentation")
    Assert.equal(settled.gameStats.score - scoreBefore, REGISTER_SCORE, "the settled save keeps one score")
    Assert.equal(#allFaults(game), 0, "the failed presentation publishes no unrelated script fault")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

return T
