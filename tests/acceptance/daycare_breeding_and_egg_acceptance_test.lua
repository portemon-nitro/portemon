-- Route 34 Day Care breeding and egg production through the production field:
-- the parents' own stored records drive the source compatibility category and
-- the source roll, the breeding check lands exactly on the source step, the
-- egg cycle counter follows the party and the native date, and the Day-Care
-- Man's own script hands out the generated egg with its inherited identity.
-- The parent records, the pending egg identity, the step counters and the
-- cycle counter are canonical saved Day Care state, so the scenarios boot the
-- real runtime from prepared owner state instead of replaying hundreds of
-- identical steps; the deposit and withdrawal custody path is proven by the
-- Day Care custody journey. Every random value still comes from the running
-- field's own generators: the saved mon generator is seeded through the mons
-- bucket, and the source's compatibility, Everstone and individual-value
-- draws are read back from it. Only audio, fade and the wall clock are
-- recording boundaries; maps, scripts, actors, the save store and every
-- owning domain stay production-owned, and the render trap stays active
-- throughout.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FinalizedGameFixture = require("tests.support.FinalizedGameFixture")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local LocalClock = require("game.src.LocalClock")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local Moves = require("libs.mons.src.gen4.Moves")
local Personality = require("libs.mons.src.gen4.Personality")
local U32 = require("libs.codec.src.U32")

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = {
      "field-runtime",
      "map:38",
      "map-data:38",
      "map:74",
      "map-data:74",
      "map:76",
      "map-data:76",
      "map:331",
      "map-data:331",
      "message-bank:384",
      "message-bank:435",
      "message-bank:439",
      -- The physical cell in front of the Day Care door, which the Route 34
      -- map closure does not already generate.
      "field-cell:0-529",
    },
    tags = { "field", "script", "daycare", "mons" },
  },
  tests = {},
}

local DAYCARE_MAP = "MAP_ROUTE_34_DAYCARE"
-- The room's open floor tile south of the counter, the same approach the
-- custody journey uses to reach the Day-Care Lady.
local DAYCARE_TILE = { fieldX = 3, fieldZ = 7 }
-- The room's own door warp tile. The man scenarios enter Route 34 through it so
-- the route's on-transition script runs on the production entry instead of a
-- cold boot of the outdoor map.
local DAYCARE_DOOR_TILE = { fieldX = 3, fieldZ = 12 }
-- The door lands on the outdoor tile by the Day-Care door; the man is answered
-- three committed steps west of it, facing north.
local ROUTE_APPROACH_STEPS = 3
-- The stored step counters the man scenarios stage before the approach: the
-- real entry spends committed steps of its own, so the scenarios stop short of
-- the source check and finish the approach with the steps that remain.
local STAGED_ROUTE_STEPS = 240
-- The Route 34 Day-Care Man (std_daycare_man) stands at global (365,410);
-- map-local coordinates are relative to the map's own coordinate origin, so
-- the player answers him from the tile directly south of him.
local MAN_MAP = "MAP_ROUTE_34"
local MAN_STAND = { fieldX = 13, fieldZ = -5 }
local MAN_SCRIPT = "common.daycare_man"
local DAYCARE_MAP_SCRIPT = "vanilla.hgss.scr_seq.0237.script_000"
local BUCKET_SCHEMA = "hgss-daycare-v1"
local DAYCARE_TRIGGER = "gear.trigger.5"
local CYCLE_LIMIT = 255
local SPECIAL_DATE_LIMIT = 230
local ORDINARY_DATE = { year = 2000, month = 1, day = 5, hour = 12, minute = 0, second = 0 }
-- January 12: the native day number 112 is on the source special-date list.
local SPECIAL_DATE = { year = 2000, month = 1, day = 12, hour = 12, minute = 0, second = 0 }

-- The source compatibility categories and the reply line each one prints
-- (msg_0439: 17 maximum, 18 medium, 19 low, 20 incompatible).
local COMPAT_MAX, COMPAT_MED, COMPAT_LOW, COMPAT_NONE = 70, 50, 20, 0
local COMPAT_LINE = { [COMPAT_MAX] = 17, [COMPAT_MED] = 18, [COMPAT_LOW] = 19, [COMPAT_NONE] = 20 }

-- Seeded saved-generator states whose first draws are the source rolls these
-- scenarios observe. The values are chosen, not computed by the test: the
-- scenarios only read the generator the field actually used.
local SEED_STEP = 1 -- first LC draw 16838: the 70 and 50 rolls succeed, 20 fails
local SEED_PAIRS = 1 -- the same roll as the step scenario
local SEED_IV = 1 -- first two LC draws give six initial individual values in 1..30
local SEED_EVERSTONE = 2 -- second LC draw 28355 activates a one-Everstone inheritance
local SEED_TWO_EVERSTONE = 4 -- second LC draw even, third 21608 activates inheritance
local SEED_EGG = 1

local HIGH_IVS = { hp = 31, attack = 31, defense = 31, speed = 31, specialAttack = 31, specialDefense = 31 }
local LOW_IVS = { hp = 0, attack = 0, defense = 0, speed = 0, specialAttack = 0, specialDefense = 0 }
local STAT_KEYS = { "hp", "attack", "defense", "speed", "specialAttack", "specialDefense" }

---@param value unknown
---@return unknown
local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for key, item in pairs(value) do
    out[key] = copy(item)
  end
  return out
end

---@param game table
---@return string[] every published script fault
local function faults(game)
  local list = {}
  for _, record in ipairs(game:recordsNamed("script.error")) do
    local payload = record.payload or {}
    local context = payload.context or {}
    list[#list + 1] = string.format(
      "%s/%s/%s/%s",
      tostring(payload.scriptId),
      tostring(payload.code),
      tostring(context.command or context.originalName or "unknown"),
      tostring(payload.message)
    )
  end
  return list
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

local function pressAction(game)
  game.runtime:pressAction()
  game:step()
  game.runtime:releaseAction()
end

local function pressDirection(game, direction)
  game.runtime:press(direction)
  game:step()
  game.runtime:release(direction)
end

---@param game table
---@param label string
---@return table the settled captured game save
local function settledCapture(game, label)
  local lastError = nil
  for _ = 1, 480 do
    local ok, record = pcall(game.runtime.captureGameSave, game.runtime)
    if ok and record ~= nil then
      return record
    end
    lastError = ok and "capture returned no record" or tostring(record)
    game:step()
  end
  error("the settled field never accepted its save: " .. label .. "; last failure: " .. tostring(lastError), 0)
end

---@param capture table
---@return table the Day Care bucket
local function daycareBucket(capture)
  local bucket = assert(capture.daycare, "the current save carries the Day Care bucket")
  Assert.equal(bucket.schema, BUCKET_SCHEMA, "the saved Day Care carries its own schema identity")
  return bucket
end

---@param game table
---@return table the live mon service
local function mons(game)
  return assert(game.runtime.monService, "the field runtime owns its mon service")
end

---@param game table
---@return MonCatalog the catalog behind the live service
local function catalog(game)
  return assert(mons(game):catalog(), "the mon service owns the validated catalog")
end

---@param game table
---@param slot0 integer
---@param change fun(mon: table)
local function stageMon(game, slot0, change)
  local service = mons(game)
  local mon = service:partyMon(slot0)
  change(mon)
  local preparation, reason = service:preparePartyChanges(service:partyRevision(), { { slot = slot0, mon = mon } })
  Assert.isNil(reason, "the prepared party change stages cleanly")
  assert(preparation).publish()
end

---@param seedU32 integer
---@param compatibility integer
---@return boolean whether the source roll accepts the generator's first draw
local function rollSucceeds(seedU32, compatibility)
  local draw = Lcrng.new(seedU32):nextU16()
  return compatibility > math.floor(draw * 100 / 0xFFFF)
end

-- A deterministic personality value the species' own ratio resolves to the
-- requested gender (and, when asked, nature).
---@param ratio integer
---@param gender string
---@param nature integer?
---@return integer
local function personalityFor(ratio, gender, nature)
  for index = 1, 800 do
    local candidate = (index * 7919 + 13) % U32.MAX
    if
      Personality.gender(ratio, candidate) == gender and (nature == nil or Personality.nature(candidate) == nature)
    then
      return candidate
    end
  end
  error("no personality resolves to " .. gender, 0)
end

---@class ParentSpec
---@field species string
---@field level integer?
---@field gender string?
---@field nature integer?
---@field ivs table<string, integer>?
---@field moves string[]?
---@field heldItem string?
---@field trainerId integer?
---@field language string?
---@field form integer?

---@param monCatalog MonCatalog
---@param mon table
---@param spec ParentSpec
local function applyParentSpec(monCatalog, mon, spec)
  local species = monCatalog:species(spec.species)
  if spec.gender ~= nil then
    mon.personality = personalityFor(species.genderRatio, spec.gender, spec.nature)
  end
  if spec.ivs ~= nil then
    mon.ivs = copy(spec.ivs)
  end
  if spec.moves ~= nil then
    local moves = {}
    for index, moveKey in ipairs(spec.moves) do
      moves[index] = { move = moveKey, pp = monCatalog:move(moveKey).basePp, ppUps = 0 }
    end
    mon.moves = moves
  end
  mon.heldItem = spec.heldItem or "NONE"
  if spec.trainerId ~= nil then
    mon.origin.trainerId = spec.trainerId
  end
  if spec.language ~= nil then
    mon.origin.language = spec.language
  end
  mon.form = spec.form or 0
end

---@class PreparedParents
---@field records table[] stored parent records in source slot order
---@field mons table the captured mons bucket with the parents removed
---@field profile table the owner profile the records were created for
---@field extra table? scenario facts resolved from the live catalog

-- Creates the requested parents through the production mon service in one
-- boot, then hands back their records and a settled mons bucket with the party
-- emptied: the Day Care owns them from here on.
---@param versionId string
---@param specOrBuilder ParentSpec[]|fun(monCatalog: MonCatalog): ParentSpec[], table
---@return PreparedParents
local function stageParents(versionId, specOrBuilder)
  local game = AcceptanceHarness.new():boot({
    versionId = versionId,
    map = DAYCARE_MAP,
    save = "fresh",
    fieldOptions = { recordingScriptHosts = true, audioHost = "recording" },
  })
  local prepared = nil
  local ok, err = xpcall(function()
    local monCatalog = catalog(game)
    local specs, extra = specOrBuilder, nil
    if type(specOrBuilder) == "function" then
      specs, extra = specOrBuilder(monCatalog)
    end
    Assert.isTrue(#specs <= 6, "one staging boot creates at most one party of parents")
    for _, spec in ipairs(specs) do
      Assert.isTrue(
        mons(game):giveMon({ species = spec.species, level = spec.level or 20, form = 0, heldItem = "NONE" }),
        "the staging gift admits " .. spec.species
      )
    end
    for index, spec in ipairs(specs) do
      stageMon(game, index - 1, function(mon)
        applyParentSpec(monCatalog, mon, spec)
        -- The staged individual values change the derived maximum, so the
        -- record keeps its own derived full health instead of the value the
        -- creation-time draw produced.
        mon.condition = { currentHp = mons(game):derive(mon).maxHp, effects = {} }
      end)
    end
    local capture = settledCapture(game, "the staged parents")
    local records = {}
    for index = 1, #specs do
      records[index] = copy(capture.mons.party.mons[index])
    end
    capture.mons.party.mons = {}
    prepared = {
      records = records,
      mons = capture.mons,
      profile = copy(game.runtime.playerData.profile),
      extra = extra,
    }
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
  return prepared
end

---@class CareOptions
---@field steps integer?
---@field pendingEggPid integer?
---@field eggCycleCounter integer?
---@field seedU32 integer?

---@param prepared PreparedParents
---@param options CareOptions?
---@return table the prepared Day Care bucket
local function careBucket(prepared, options)
  options = options or {}
  local slots = {}
  for index, record in ipairs(prepared.records) do
    slots[index] = { mon = copy(record), steps = options.steps or 0 }
  end
  return {
    schema = BUCKET_SCHEMA,
    slots = slots,
    pendingEggPid = options.pendingEggPid or 0,
    eggCycleCounter = options.eggCycleCounter or 0,
  }
end

---@param map string
---@param location { fieldX: integer, fieldZ: integer }
---@param state { mons: table, daycare: table, clock: table? }
---@param facing string?
---@return table acceptance game
local function bootField(map, location, state, facing)
  local harness = AcceptanceHarness.new({
    gameFactory = function(versionId, _)
      local worldState = FieldEventState.new()
      -- The Route 34 map frame script alternates its two policeman objects by
      -- time of day; the daytime state keeps exactly one of them, which is
      -- the source state this scenario boots in.
      worldState:setFlag(FieldScriptSymbols.flagsByName.FLAG_UNK_1D2)
      local game = FinalizedGameFixture.build(versionId, {
        location = { mapSymbol = map, fieldX = location.fieldX, fieldZ = location.fieldZ, facing = facing or "north" },
        worldState = worldState,
        mons = state.mons,
      })
      game.daycare = state.daycare
      return game
    end,
  })
  local fieldOptions = { recordingScriptHosts = true, audioHost = "recording" }
  if state.clock ~= nil then
    fieldOptions.localClock = state.clock
  end
  local game = harness:boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = map,
    save = "fresh",
    fieldOptions = fieldOptions,
  })
  game:waitForFieldEntry()
  return game
end

---@param prepared PreparedParents
---@param options CareOptions?
---@param clock table?
---@return table acceptance game in the Day Care room
local function bootCareRoom(prepared, options, clock)
  local state = {
    mons = copy(prepared.mons),
    daycare = careBucket(prepared, options),
    clock = clock,
  }
  state.mons.rng = Lcrng.new((options and options.seedU32) or SEED_EGG):capture()
  local game = bootField(DAYCARE_MAP, DAYCARE_TILE, state, "south")
  game.runtime:bindPartyIconPreparation(function()
    return true
  end, function() end)
  return game
end

---@param withDate table the fixed native date to report
---@return table a recording clock host boundary
local function clockAt(withDate)
  return LocalClock.new(function()
    return copy(withDate)
  end)
end

-- Turns the player without walking: the same facing-only domain operation a
-- script's turn performs, so no committed step is claimed.
---@param game table
---@param direction string
local function faceTile(game, direction)
  if game:snapshot().player.facing ~= direction then
    game:face(direction)
  end
end

---@param game table
---@param direction string
---@return boolean committed whether production movement left the tile
local function tryStep(game, direction)
  faceTile(game, direction)
  local before = game:snapshot().player
  game:move(direction)
  local after = game:advanceUntil("movement resolves", function(snapshot)
    return snapshot.player.motion == "idle"
  end, 120)
  return after.player.fieldX ~= before.fieldX or after.player.fieldZ ~= before.fieldZ
end

-- Walks exactly `count` real committed steps between two open room tiles, so
-- every step reaches the same field seam production uses.
---@param game table
---@param count integer
local function walkRoomSteps(game, count)
  local walked = 0
  while walked < count do
    Assert.isTrue(tryStep(game, "south"), "the day care room offers a committed step after " .. walked)
    walked = walked + 1
    if walked >= count then
      break
    end
    Assert.isTrue(tryStep(game, "north"), "the day care room offers its return step after " .. walked)
    walked = walked + 1
  end
end

-- Enters Route 34 the way the game does: the player walks across the room to
-- its own door and presses through it. The walk is what admits the neighbouring
-- outdoor map's frozen actors, so the route's on-transition script meets them
-- exactly as it does in play; the source door then answers the facing path.
---@param game table
---@return table the outdoor landing snapshot
local function enterRoute34(game)
  game:moveTo(DAYCARE_DOOR_TILE)
  local atDoor = game:snapshot().player
  Assert.deepEqual(
    { atDoor.fieldX, atDoor.fieldZ },
    { DAYCARE_DOOR_TILE.fieldX, DAYCARE_DOOR_TILE.fieldZ },
    "the room's own floor reaches its door tile"
  )
  local landed = false
  for _ = 1, 30 do
    game:move("south")
    game:advanceUntil("door ingress resolves", function(snapshot)
      return snapshot.player.motion == "idle"
    end, 120)
    if game:snapshot().mapSymbol == MAN_MAP then
      landed = true
      break
    end
  end
  Assert.isTrue(landed, "the Day Care room's door leads out to Route 34")
  game:waitForFieldEntry()
  return game:snapshot()
end

-- Walks the fixed approach from the door landing tile to the tile the man is
-- answered from, then faces him. Every step is a real committed step.
---@param game table
local function walkToManTile(game)
  local landing = game:snapshot().player
  for walked = 1, ROUTE_APPROACH_STEPS do
    Assert.isTrue(tryStep(game, "west"), "the route offers approach step " .. walked .. " west")
  end
  local arrived = game:snapshot().player
  Assert.equal(arrived.fieldX, landing.fieldX - ROUTE_APPROACH_STEPS, "the approach reaches the man's column")
  Assert.equal(arrived.fieldZ, landing.fieldZ, "the approach stays on the man's walkway")
  faceTile(game, "north")
end

---@param prepared PreparedParents
---@param options CareOptions?
---@return table acceptance game standing beside the Day-Care Man
local function bootManTile(prepared, options)
  local state = {
    mons = copy(prepared.mons),
    daycare = careBucket(prepared, options),
  }
  state.mons.rng = Lcrng.new((options and options.seedU32) or SEED_EGG):capture()
  local game = bootField(DAYCARE_MAP, DAYCARE_TILE, state, "south")
  enterRoute34(game)
  walkToManTile(game)
  return game
end

-- Finishes the approach to the source breeding step: the entry already spent
-- committed steps, so the walk covers exactly the counter values that remain
-- before the second parent's low byte reaches the source check.
---@param game table
---@param label string
local function walkToSourceCheck(game, label)
  local entered = daycareBucket(settledCapture(game, label .. " after the route approach"))
  local steps = entered.slots[2].steps
  Assert.isTrue(steps % 256 < 255, label .. " approaches the source check without crossing it")
  local remaining = 255 - (steps % 256)
  local walked, forward = 0, true
  while walked < remaining do
    local direction = forward and "east" or "west"
    Assert.isTrue(
      tryStep(game, direction),
      label .. " offers committed step " .. (walked + 1) .. " beside the man"
    )
    walked = walked + 1
    forward = not forward
  end
end

-- Talks to the Day-Care Man and drives his own script to its end: every
-- printed line is dismissed, and each source two-choice row is answered with
-- the requested row (0 confirm, 1 cancel).
---@param game table
---@param answer integer
---@return integer[] printed message ids
local function runManScript(game, answer)
  local ended = #game:recordsForScript(MAN_SCRIPT, "script.ended")
  game:pressAction()
  local interaction = game:interaction()
  Assert.equal(interaction.scriptId, MAN_SCRIPT, "the Day-Care Man owns the interaction the script answers")
  local printed, last = {}, nil
  for _ = 1, 1600 do
    local faultsNow = scriptFaults(game, MAN_SCRIPT)
    Assert.equal(
      #faultsNow,
      0,
      "the Day-Care Man's script completes every native operation: " .. table.concat(faultsNow, ",")
    )
    local choice = game:contextChoiceStatus()
    local snapshot = game:snapshot()
    if choice ~= nil and choice.state == "active" then
      if choice.selected ~= answer then
        pressDirection(game, answer == 0 and "up" or "down")
      else
        pressAction(game)
      end
    elseif snapshot.dialogue.modal then
      local messageId = snapshot.dialogue.messageId
      if messageId ~= nil and messageId ~= last then
        printed[#printed + 1] = messageId
        last = messageId
      end
      pressAction(game)
    else
      game:step()
    end
    if
      #game:recordsForScript(MAN_SCRIPT, "script.ended") > ended
      and game:contextChoiceStatus() == nil
      and not game:snapshot().dialogue.modal
    then
      return printed
    end
  end
  error(
    "the Day-Care Man's script never returned to the field: "
      .. table.concat(scriptFaults(game, MAN_SCRIPT), ",")
      .. " entry="
      .. table.concat(scriptFaults(game, DAYCARE_MAP_SCRIPT), ","),
    0
  )
end

---@param printed integer[]
---@param messageId integer
---@return boolean
local function printedLine(printed, messageId)
  for _, value in ipairs(printed) do
    if value == messageId then
      return true
    end
  end
  return false
end

---@param capture table
---@param species string
---@return table the party's only Egg
local function partyEgg(capture, species)
  local found = nil
  for _, mon in ipairs(capture.mons.party.mons) do
    if mon.isEgg == true then
      Assert.isNil(found, "the party carries one generated Egg at a time")
      found = mon
    end
  end
  Assert.notNil(found, "the collection appended an Egg to the party")
  if species ~= nil then
    Assert.equal(found.species, species, "the generated Egg carries its source species")
  end
  return found
end

---@param mon table
---@return string[] the move keys in slot order
local function moveKeys(mon)
  local keys = {}
  for index, entry in ipairs(mon.moves) do
    keys[index] = entry.move
  end
  return keys
end

---@param pid integer
---@return integer the source PRandom personality mixer
local function prandom(pid)
  return U32.add(U32.mul(pid, 1812433253), 1)
end

-- Source SetBreedEggStats' different-language path: the drawn personality
-- advances up to four PRandom steps until it is shiny for the receiving
-- trainer, keeping the last value it computed.
---@param trainerId integer
---@param pid integer
---@return integer
local function languagePersonality(trainerId, pid)
  if Personality.shiny(trainerId, pid) then
    return pid
  end
  local current = pid
  for _ = 1, 4 do
    current = prandom(current)
    if Personality.shiny(trainerId, current) then
      break
    end
  end
  return current
end

---@param mon table
---@return integer[] the individual values in source stat order
local function ivList(mon)
  local values = {}
  for index, key in ipairs(STAT_KEYS) do
    values[index] = mon.ivs[key]
  end
  return values
end

-- The source breeding check lands exactly on the source step, stores only the
-- pending personality, advances the cycle counter independently, and raises
-- the durable Day-Care phone trigger.
function T.tests.breeding_checks_land_on_the_source_step_and_keep_a_pending_pid()
  local versionId = AcceptanceHarness.defaultVersion()
  local prepared = stageParents(versionId, {
    { species = "SNORLAX", level = 20, gender = "female", ivs = HIGH_IVS, trainerId = 41 },
    { species = "SNORLAX", level = 20, gender = "male", ivs = LOW_IVS, trainerId = 42 },
  })
  local game = bootCareRoom(prepared, { steps = 0, seedU32 = SEED_STEP })
  local ok, err = xpcall(function()
    walkRoomSteps(game, 254)
    local walkedCapture = settledCapture(game, "254 committed steps")
    local walked = daycareBucket(walkedCapture)
    Assert.equal(walked.slots[1].steps, 254, "each committed step advances the first stored parent")
    Assert.equal(walked.slots[2].steps, 254, "each committed step advances the second stored parent")
    Assert.equal(walked.pendingEggPid, 0, "no breeding check runs before the source step")
    Assert.equal(walked.eggCycleCounter, 254, "the cycle counter advances once per committed step")
    Assert.equal(walkedCapture.mons.rng.calls, 0, "no random draw precedes the source step")

    -- A turn and a blocked push are not committed steps.
    faceTile(game, "north")
    local beforeBump = game:snapshot().player
    game:move("north")
    local bumped = game:advanceUntil("movement resolves", function(snapshot)
      return snapshot.player.motion == "idle"
    end, 120)
    Assert.equal(bumped.player.fieldX, beforeBump.fieldX, "the counter blocks the push north")
    Assert.equal(bumped.player.fieldZ, beforeBump.fieldZ, "the counter blocks the push north")
    local still = daycareBucket(settledCapture(game, "a turn and a blocked push"))
    Assert.equal(still.slots[1].steps, 254, "a turn advances no stored parent step")
    Assert.equal(still.eggCycleCounter, 254, "a turn advances no cycle counter")

    walkRoomSteps(game, 1)
    local bredCapture = settledCapture(game, "the source breeding step")
    local bred = daycareBucket(bredCapture)
    Assert.equal(bred.slots[1].steps, 255, "the source step lands on the first check")
    Assert.equal(bred.slots[2].steps, 255, "the second parent keeps the same walk")
    Assert.equal(bred.eggCycleCounter, 0, "the 255th counter value triggers its own cycle once")
    Assert.isTrue(
      rollSucceeds(SEED_STEP, COMPAT_MAX),
      "the seeded generator makes the same-species, different-trainer roll succeed"
    )
    Assert.isTrue(bred.pendingEggPid ~= 0, "a successful roll stores the pending egg personality")
    Assert.equal(bredCapture.mons.rng.calls, 1, "the compatibility roll draws exactly one saved generator value")
    Assert.equal(mons(game):partyCount(), 0, "the roll never builds a finished Egg")
    Assert.equal(#bred.slots, 2, "the breeding check keeps both parents in care")
    local phone = assert(game.runtime.pokegearState, "the runtime owns the phone state"):readPhone()
    Assert.isTrue(phone.triggers[DAYCARE_TRIGGER] == true, "a successful roll raises the durable Day-Care trigger")

    -- The identity is saved state, not live memory: re-entering from the
    -- published save keeps the pending egg and still no built Egg.
    game:restart()
    game:waitForFieldEntry()
    local resumed = daycareBucket(settledCapture(game, "the reloaded Day Care"))
    Assert.equal(resumed.pendingEggPid, bred.pendingEggPid, "Continue keeps the pending egg personality")
    Assert.equal(resumed.eggCycleCounter, bred.eggCycleCounter, "Continue keeps the cycle counter")
    Assert.equal(mons(game):partyCount(), 0, "Continue builds no Egg from the pending identity")
    Assert.equal(game:renderAttempts(), 0, "the breeding step scenario stops before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

-- The cycle counter: the ordinary 255 threshold, the native special date's
-- 230 threshold, the party ability's double decrement, and the party-order
-- stop at the first Egg that already reached zero cycles.
function T.tests.egg_cycles_follow_party_abilities_and_the_source_date()
  local versionId = AcceptanceHarness.defaultVersion()
  local prepared = stageParents(versionId, {
    { species = "SNORLAX", level = 20, gender = "female", trainerId = 41 },
    { species = "SNORLAX", level = 20, gender = "male", trainerId = 42 },
  })
  local function addEgg(game, friendship, slot0)
    Assert.isTrue(mons(game):giveEgg({ species = "PICHU", locationOffset = 14 }), "the party takes one Egg")
    stageMon(game, slot0, function(mon)
      mon.friendship = friendship
    end)
  end

  -- The source cycle check ignores Eggs and reads every other party member's
  -- ability, so the double decrement comes from a fainted carrier.
  local function addAbilityCarrier(game)
    local slot0 = mons(game):partyCount()
    Assert.isTrue(
      mons(game):giveMon({ species = "SLUGMA", level = 5, form = 0, heldItem = "NONE", ability = "MAGMA_ARMOR" }),
      "the party takes the ability carrier"
    )
    stageMon(game, slot0, function(mon)
      mon.condition = { currentHp = 0, effects = {} }
    end)
  end

  -- An ordinary native date: 230 does not trigger and 255 does, and a party
  -- ability doubles the decrement even while its owner has fainted.
  local game = bootCareRoom(prepared, { steps = 0, eggCycleCounter = SPECIAL_DATE_LIMIT - 1, seedU32 = SEED_EGG })
  local ok, err = xpcall(function()
    addEgg(game, 9, 0)
    addEgg(game, 1, 1)
    addAbilityCarrier(game)
    walkRoomSteps(game, 1)
    local stepped = settledCapture(game, "the ordinary date cycle")
    Assert.equal(
      daycareBucket(stepped).eggCycleCounter,
      SPECIAL_DATE_LIMIT,
      "an ordinary native date keeps counting past 230 toward the 255 threshold"
    )
    Assert.equal(stepped.mons.party.mons[1].friendship, 9, "no cycle completes before the source threshold")
    Assert.equal(stepped.mons.party.mons[2].friendship, 1, "no cycle completes before the source threshold")

    walkRoomSteps(game, CYCLE_LIMIT - SPECIAL_DATE_LIMIT)
    local cycled = settledCapture(game, "the completed cycle")
    Assert.equal(daycareBucket(cycled).eggCycleCounter, 0, "the 255th counter value completes the cycle")
    Assert.equal(cycled.mons.party.mons[1].friendship, 7, "the party ability doubles the cycle decrement")
    Assert.equal(cycled.mons.party.mons[2].friendship, 0, "a friendliness below the decrement loses exactly one point")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end

  -- The native special date completes a cycle at exactly 230.
  local dated = bootCareRoom(
    prepared,
    { steps = 0, eggCycleCounter = SPECIAL_DATE_LIMIT - 1, seedU32 = SEED_EGG },
    clockAt(SPECIAL_DATE)
  )
  local datedOk, datedErr = xpcall(function()
    addEgg(dated, 3, 0)
    walkRoomSteps(dated, 1)
    local cycle = settledCapture(dated, "the special date cycle")
    Assert.equal(daycareBucket(cycle).eggCycleCounter, 0, "the native special date completes its cycle at exactly 230")
    Assert.equal(cycle.mons.party.mons[1].friendship, 2, "the special date still decrements the party Egg")
  end, debug.traceback)
  dated:close()
  if not datedOk then
    error(datedErr, 0)
  end

  -- Party order: an Egg already at zero requests its hatch and stops the
  -- loop, so later Eggs are untouched.
  local staggered =
    bootCareRoom(prepared, { steps = 0, eggCycleCounter = CYCLE_LIMIT - 1, seedU32 = SEED_EGG }, clockAt(ORDINARY_DATE))
  local staggeredOk, staggeredErr = xpcall(function()
    addEgg(staggered, 0, 0)
    addEgg(staggered, 5, 1)
    walkRoomSteps(staggered, 1)
    -- The completed cycle with a zero-friendship Egg in front claims the step
    -- and starts the source hatch scene, so the field is unsavable until that
    -- scene returns; the owners below are the live production state it left.
    local hatch = assert(staggered.runtime.daycare:activeHatch(), "a ready Egg claims the completed cycle")
    Assert.equal(hatch.slot, 0, "the first ready Egg is the one that hatches")
    Assert.equal(staggered.runtime.daycareState:eggCycleCounter(), 0, "the cycle still completes and resets")
    Assert.isFalse(mons(staggered):partyMon(0).isEgg, "the first ready Egg becomes its mon")
    Assert.equal(mons(staggered):partyMon(1).friendship, 5, "an Egg after the first ready one is untouched")
    Assert.equal(mons(staggered):partyMon(1).isEgg, true, "an Egg after the first ready one stays an Egg")
  end, debug.traceback)
  staggered:close()
  if not staggeredOk then
    error(staggeredErr, 0)
  end
end

-- The source compatibility categories, read from the Day-Care Man's own reply
-- line, and the exact compatibility roll against the saved generator.
function T.tests.breeding_pairs_report_source_compatibility_and_roll()
  local versionId = AcceptanceHarness.defaultVersion()
  local prepared = stageParents(versionId, {
    { species = "SNORLAX", level = 20, gender = "female", trainerId = 41 },
    { species = "SNORLAX", level = 20, gender = "male", trainerId = 42 },
    { species = "PIKACHU", level = 20, gender = "male", trainerId = 41 },
    { species = "DITTO", level = 20, trainerId = 41 },
    { species = "MEWTWO", level = 20, trainerId = 41 },
    { species = "TOTODILE", level = 20, gender = "male", trainerId = 41 },
  })
  local female, male, pikachu, ditto, mewtwo, totodile = prepared.records[1],
    prepared.records[2],
    prepared.records[3],
    prepared.records[4],
    prepared.records[5],
    prepared.records[6]
  Assert.notNil(
    female and male and pikachu and ditto and mewtwo and totodile,
    "the staging boot created every parent"
  )

  local function withTrainer(record, trainerId)
    local staged = copy(record)
    staged.origin.trainerId = trainerId
    return staged
  end

  ---@type { label: string, parents: table[], compatibility: integer }[]
  local cases = {
    { label = "an undiscovered pair", parents = { mewtwo, withTrainer(ditto, 41) }, compatibility = COMPAT_NONE },
    {
      label = "two Ditto",
      parents = { withTrainer(ditto, 41), withTrainer(ditto, 42) },
      compatibility = COMPAT_NONE,
    },
    {
      label = "one Ditto with matching trainer identities",
      parents = { withTrainer(ditto, 41), withTrainer(pikachu, 41) },
      compatibility = COMPAT_LOW,
    },
    {
      label = "one Ditto with different trainer identities",
      parents = { withTrainer(ditto, 41), withTrainer(pikachu, 42) },
      compatibility = COMPAT_MED,
    },
    {
      label = "the same species with matching trainer identities",
      parents = { female, withTrainer(male, 41) },
      compatibility = COMPAT_MED,
    },
    {
      label = "the same species with different trainer identities",
      parents = { female, withTrainer(male, 42) },
      compatibility = COMPAT_MAX,
    },
    -- Snorlax and Totodile share the Monster egg group, so two different
    -- species from one trainer identity are the source's low category; the
    -- Pikachu pair that shares no egg group is incompatible instead.
    {
      label = "different species with matching trainer identities",
      parents = { female, totodile },
      compatibility = COMPAT_LOW,
    },
    {
      label = "different species without a matching egg group",
      parents = { female, withTrainer(pikachu, 41) },
      compatibility = COMPAT_NONE,
    },
  }

  for _, case in ipairs(cases) do
    local staged = { records = case.parents, mons = prepared.mons, profile = prepared.profile }
    local game = bootManTile(staged, { steps = STAGED_ROUTE_STEPS, seedU32 = SEED_PAIRS })
    local ok, err = xpcall(function()
      Assert.equal(
        #scriptFaults(game, DAYCARE_MAP_SCRIPT),
        0,
        case.label
          .. " enters the route with no script fault: "
          .. table.concat(scriptFaults(game, DAYCARE_MAP_SCRIPT), ",")
      )
      local printed = runManScript(game, 0)
      Assert.isTrue(
        printedLine(printed, COMPAT_LINE[case.compatibility]),
        case.label .. " reports the source compatibility line " .. COMPAT_LINE[case.compatibility]
      )

      -- The remaining committed steps land the first parent on its source check.
      walkToSourceCheck(game, case.label)
      local capture = settledCapture(game, case.label .. " after the source step")
      local bucket = daycareBucket(capture)
      Assert.equal(bucket.slots[2].steps % 256, 255, case.label .. " reaches the source check")
      Assert.equal(bucket.slots[1].steps, bucket.slots[2].steps, case.label .. " both parents keep the same walk")
      if rollSucceeds(SEED_PAIRS, case.compatibility) then
        Assert.isTrue(bucket.pendingEggPid ~= 0, case.label .. " stores the pending egg on a successful roll")
      else
        Assert.equal(bucket.pendingEggPid, 0, case.label .. " stores no pending egg on a failed roll")
      end
      Assert.equal(
        capture.mons.rng.calls,
        1,
        case.label .. " draws exactly one compatibility value, even for an incompatible pair"
      )
    end, debug.traceback)
    game:close()
    if not ok then
      error(err, 0)
    end
  end
end

-- Everstone nature inheritance: one Everstone forces its holder's nature, and
-- two Everstones resolve the contributing parent through the source parity
-- draw before the inheritance is activated.
function T.tests.everstones_select_the_source_nature()
  local versionId = AcceptanceHarness.defaultVersion()
  local prepared = stageParents(versionId, {
    -- Distinct forced natures keep the Everstone expectation unambiguous.
    { species = "SNORLAX", level = 20, gender = "female", nature = 0, trainerId = 41 },
    { species = "SNORLAX", level = 20, gender = "male", nature = 2, trainerId = 42 },
  })
  local femaleNature = Personality.nature(prepared.records[1].personality)
  local maleNature = Personality.nature(prepared.records[2].personality)
  Assert.equal(femaleNature, 0, "the staged first parent carries its requested nature")
  Assert.equal(maleNature, 2, "the staged second parent carries its requested nature")

  local function checkEverstone(records, seedU32, expectedNature, label)
    local staged = { records = records, mons = prepared.mons, profile = prepared.profile }
    local game = bootManTile(staged, { steps = STAGED_ROUTE_STEPS, seedU32 = seedU32 })
    local ok, err = xpcall(function()
      walkToSourceCheck(game, label)
      local bucket = daycareBucket(settledCapture(game, label))
      Assert.equal(bucket.slots[2].steps % 256, 255, label .. " reaches the source check")
      Assert.isTrue(bucket.pendingEggPid ~= 0, label .. " draws an egg personality")
      Assert.equal(
        Personality.nature(bucket.pendingEggPid),
        expectedNature,
        label .. " inherits the nature of the parent the source selects"
      )
    end, debug.traceback)
    game:close()
    if not ok then
      error(err, 0)
    end
  end

  local femaleStone = copy(prepared.records[1])
  femaleStone.heldItem = "EVERSTONE"
  checkEverstone({ femaleStone, copy(prepared.records[2]) }, SEED_EVERSTONE, femaleNature, "one Everstone")

  local bothFemale = copy(prepared.records[1])
  local bothMale = copy(prepared.records[2])
  bothFemale.heldItem = "EVERSTONE"
  bothMale.heldItem = "EVERSTONE"
  -- Two Everstones: the parity draw is even here, which the source maps to
  -- the second parent.
  checkEverstone({ bothFemale, bothMale }, SEED_TWO_EVERSTONE, maleNature, "two Everstones")
end

-- Collection through the Day-Care Man's own script: species selection, the
-- source move insertion order, inherited individual values with power items,
-- the different-language personality path, and the atomic state transition.
function T.tests.egg_collection_builds_the_source_egg()
  local versionId = AcceptanceHarness.defaultVersion()
  local moveParents = stageParents(versionId, function(monCatalog)
    local form = monCatalog:form("PICHU", 0)
    local defaults = {}
    for _, entry in ipairs(Moves.initial(form.levelUpMoves, 1, monCatalog)) do
      defaults[#defaults + 1] = entry.move
    end
    Assert.isTrue(#defaults >= 1, "the offspring has a level-one move set")
    local further = {}
    for _, entry in ipairs(form.levelUpMoves) do
      local known = false
      for _, moveKey in ipairs(defaults) do
        known = known or moveKey == entry.move
      end
      for _, moveKey in ipairs(further) do
        known = known or moveKey == entry.move
      end
      if entry.level > 1 and not known and #further < 3 then
        further[#further + 1] = entry.move
      end
    end
    Assert.equal(#further, 3, "the offspring's learn-up list offers three further shared moves")
    local fatherMoves = { defaults[1], further[1], further[2], further[3] }
    local motherMoves = { further[1], further[2], further[3], defaults[1] }
    return {
      -- A different-language pair: the receiving trainer's personality comes
      -- through the source PRandom path.
      {
        species = "PIKACHU",
        level = 20,
        gender = "female",
        trainerId = 41,
        language = "japanese",
        moves = motherMoves,
      },
      { species = "PIKACHU", level = 20, gender = "male", trainerId = 42, language = "english", moves = fatherMoves },
    }, { defaults = defaults, further = further }
  end)
  local incenseParents = stageParents(versionId, {
    { species = "SNORLAX", level = 20, gender = "female", trainerId = 41 },
    { species = "SNORLAX", level = 20, gender = "male", trainerId = 42 },
  })
  local splitParents = stageParents(versionId, {
    { species = "NIDORAN_F", level = 20, gender = "female", trainerId = 41 },
    { species = "NIDORAN_M", level = 20, gender = "male", trainerId = 42 },
  })
  local ivParents = stageParents(versionId, {
    { species = "MANAPHY", level = 20, trainerId = 41, ivs = HIGH_IVS },
    { species = "DITTO", level = 20, trainerId = 42, ivs = LOW_IVS },
  })

  local function withStored(prepared, first, second)
    return { records = { first, second }, mons = prepared.mons, profile = prepared.profile }
  end

  ---@param preparedParents table
  ---@param options CareOptions
  ---@param expectedSpecies string
  ---@param extra fun(game: table, capture: table, bucket: table, egg: table)
  local function collect(preparedParents, options, expectedSpecies, extra)
    local game = bootManTile(preparedParents, options)
    local ok, err = xpcall(function()
      local before = settledCapture(game, "before the collection")
      local printed = runManScript(game, 0)
      Assert.isTrue(printedLine(printed, 5), "the man hands the egg over with the source receipt line")
      local after = settledCapture(game, "the collected egg")
      local bucket = daycareBucket(after)
      local egg = partyEgg(after, expectedSpecies)
      Assert.equal(bucket.pendingEggPid, 0, "the collection clears the pending egg identity")
      Assert.equal(bucket.eggCycleCounter, 0, "the collection clears the cycle counter with the identity")
      Assert.equal(#bucket.slots, 2, "the collection keeps both parents in care")
      local phone = assert(game.runtime.pokegearState, "the runtime owns the phone state"):readPhone()
      Assert.isNil(phone.triggers[DAYCARE_TRIGGER], "offering the egg clears the pending Day-Care phone trigger")
      Assert.deepEqual(after.pokedex, before.pokedex, "a generated egg registers no Dex receipt")
      Assert.deepEqual(
        after.gameStats.uniqueCaught,
        before.gameStats.uniqueCaught,
        "a generated egg registers no caught species"
      )
      Assert.equal(after.gameStats.eggsHatched, before.gameStats.eggsHatched, "a generated egg is no hatch")
      Assert.equal(egg.experience, 0, "the generated Egg enters at level one")
      Assert.isTrue(egg.isEgg == true, "the generated record is an unhatched Egg")
      Assert.equal(egg.heldItem, "NONE", "the generated Egg holds nothing")
      Assert.isTrue(egg.egg.location > 0, "the generated Egg records its native gift location")
      Assert.equal(egg.met.location, 0, "the generated Egg carries no meeting record yet")
      if extra ~= nil then
        extra(game, after, bucket, egg)
      end
      Assert.equal(#faults(game), 0, "the collection publishes no unrelated script fault")
      Assert.equal(game:renderAttempts(), 0, "the collection scenario stops before GPU rendering")
    end, debug.traceback)
    game:close()
    if not ok then
      error(err, 0)
    end
  end

  -- Two Pikachu of different languages: the offspring is a Pichu whose
  -- level-one moves come first, then the father's compatible machines in
  -- father slot order, then the parents' shared learn-up moves, with
  -- already-known moves skipped and a full set dropping its first move; the
  -- personality takes the PRandom path.
  local pendingEggPid = 0x12345678
  collect(
    withStored(moveParents, moveParents.records[1], moveParents.records[2]),
    {
      pendingEggPid = pendingEggPid,
      eggCycleCounter = 12,
      seedU32 = SEED_EGG,
    },
    "PICHU",
    function(game, _, _, egg)
      local expected = {}
      local function insert(moveKey)
        for _, known in ipairs(expected) do
          if known == moveKey then
            return
          end
        end
        if #expected >= Moves.MAX_SLOTS then
          table.remove(expected, 1)
        end
        expected[#expected + 1] = moveKey
      end
      for _, moveKey in ipairs(moveParents.extra.defaults) do
        insert(moveKey)
      end
      local machines = {}
      for _, moveKey in ipairs(catalog(game):form("PICHU", 0).tmhm) do
        machines[moveKey] = true
      end
      for _, moveKey in ipairs(moveParents.extra.further) do
        if machines[moveKey] then
          insert(moveKey)
        end
      end
      for _, moveKey in ipairs(moveParents.extra.further) do
        insert(moveKey)
      end
      Assert.deepEqual(moveKeys(egg), expected, "the Egg keeps the source move insertion order")
      local trainerId = assert(game.runtime.playerData.profile.trainerId, "the profile owns its trainer identity")
      Assert.equal(
        egg.personality,
        languagePersonality(trainerId, pendingEggPid),
        "a different-language pair applies the source personality mixer"
      )
      Assert.equal(
        egg.friendship,
        catalog(game):species("PICHU").eggCycles,
        "the generated Egg starts at its species' egg-cycle friendliness"
      )
    end
  )

  -- A Light Ball makes the Pichu inherit Volt Tackle last, still dropping the
  -- first move of a full set.
  local lightBall = copy(moveParents.records[2])
  lightBall.heldItem = "LIGHT_BALL"
  collect(
    withStored(moveParents, moveParents.records[1], lightBall),
    {
      pendingEggPid = 0x0F0F0F0F,
      seedU32 = SEED_EGG,
    },
    "PICHU",
    function(_, _, _, egg)
      Assert.equal(moveKeys(egg)[#egg.moves], "VOLT_TACKLE", "a Light Ball appends Volt Tackle last")
      Assert.equal(#egg.moves, Moves.MAX_SLOTS, "the inherited move set stays full")
    end
  )

  -- Incense: the source egg species resolves through the personal table, and
  -- only the matching incense keeps the baby.
  collect(withStored(incenseParents, incenseParents.records[1], incenseParents.records[2]), {
    pendingEggPid = 0x11111111,
    seedU32 = SEED_EGG,
  }, "SNORLAX", nil)
  local fullIncense = copy(incenseParents.records[2])
  fullIncense.heldItem = "FULL_INCENSE"
  collect(withStored(incenseParents, incenseParents.records[1], fullIncense), {
    pendingEggPid = 0x11111111,
    seedU32 = SEED_EGG,
  }, "MUNCHLAX", nil)

  -- A Nidoran female's offspring splits by the drawn personality's high bit.
  collect(withStored(splitParents, splitParents.records[1], splitParents.records[2]), {
    pendingEggPid = 0x00008000,
    seedU32 = SEED_EGG,
  }, "NIDORAN_M", nil)
  collect(withStored(splitParents, splitParents.records[1], splitParents.records[2]), {
    pendingEggPid = 0x00004000,
    seedU32 = SEED_EGG,
  }, "NIDORAN_F", nil)

  -- A Manaphy parent always produces a Phione, and one power item forces its
  -- holder's individual value while three distinct values are inherited.
  local powerWeight = copy(ivParents.records[1])
  powerWeight.heldItem = "POWER_WEIGHT"
  collect(
    withStored(ivParents, powerWeight, ivParents.records[2]),
    {
      pendingEggPid = 0x22222222,
      seedU32 = SEED_IV,
    },
    "PHIONE",
    function(_, _, _, egg)
      local inherited = 0
      for _, value in ipairs(ivList(egg)) do
        if value == 31 or value == 0 then
          inherited = inherited + 1
        end
      end
      Assert.equal(inherited, 3, "exactly three distinct individual values are inherited")
      Assert.equal(egg.ivs.hp, 31, "a held power item forces its holder's own individual value")
    end
  )

  -- Two power items: the source draws once to pick which holder contributes,
  -- and this even draw selects the second parent.
  local braceWeight = copy(ivParents.records[1])
  local lensBracer = copy(ivParents.records[2])
  braceWeight.heldItem = "POWER_WEIGHT"
  lensBracer.heldItem = "POWER_LENS"
  collect(
    withStored(ivParents, braceWeight, lensBracer),
    { pendingEggPid = 0x33333333, seedU32 = SEED_IV },
    "PHIONE",
    function(_, _, _, egg)
      local inherited = 0
      for _, value in ipairs(ivList(egg)) do
        if value == 31 or value == 0 then
          inherited = inherited + 1
        end
      end
      Assert.equal(inherited, 3, "two power items still inherit exactly three distinct values")
      Assert.equal(egg.ivs.specialAttack, 0, "the parity draw selects the second holder's forced value")
    end
  )
end

-- The source refusals and the resettable pending state: a full party takes no
-- egg and draws nothing, and declining twice clears the pending identity and
-- the cycle counter together.
function T.tests.egg_collection_refuses_a_full_party_and_clears_on_request()
  local versionId = AcceptanceHarness.defaultVersion()
  local prepared = stageParents(versionId, {
    { species = "SNORLAX", level = 20, gender = "female", trainerId = 41 },
    { species = "SNORLAX", level = 20, gender = "male", trainerId = 42 },
  })

  local full = bootManTile(prepared, { pendingEggPid = 0x0BADF00D, eggCycleCounter = 77, seedU32 = SEED_EGG })
  local fullOk, fullErr = xpcall(function()
    for _ = 1, 6 do
      Assert.isTrue(
        mons(full):giveMon({ species = "RATTATA", level = 5, form = 0, heldItem = "NONE" }),
        "the party fills with a carrier"
      )
    end
    local before = settledCapture(full, "the full party")
    local printed = runManScript(full, 0)
    Assert.isTrue(printedLine(printed, 4), "the man refuses the egg because the party is full")
    local after = settledCapture(full, "the full-party refusal")
    local bucket = daycareBucket(after)
    Assert.equal(bucket.pendingEggPid, 0x0BADF00D, "the full-party refusal keeps the pending egg identity")
    Assert.equal(
      bucket.eggCycleCounter,
      daycareBucket(before).eggCycleCounter,
      "the full-party refusal keeps the cycle counter"
    )
    Assert.equal(#bucket.slots, 2, "the full-party refusal keeps both parents in care")
    Assert.equal(after.mons.rng.calls, before.mons.rng.calls, "the full-party refusal draws no random value")
    Assert.equal(#after.mons.party.mons, 6, "the full party keeps its six carriers")
    for _, mon in ipairs(after.mons.party.mons) do
      Assert.isTrue(mon.isEgg ~= true, "the full-party refusal appends no Egg")
    end
    Assert.equal(full:renderAttempts(), 0, "the refusal scenario stops before GPU rendering")
  end, debug.traceback)
  full:close()
  if not fullOk then
    error(fullErr, 0)
  end

  local declined = bootManTile(prepared, { pendingEggPid = 0x0BADF00D, eggCycleCounter = 77, seedU32 = SEED_EGG })
  local declinedOk, declinedErr = xpcall(function()
    local printed = runManScript(declined, 1)
    Assert.isTrue(printedLine(printed, 1), "the man offers the waiting egg first")
    Assert.isTrue(printedLine(printed, 10), "a cancelled offer asks the source second question")
    local after = settledCapture(declined, "the declined egg")
    local bucket = daycareBucket(after)
    Assert.equal(bucket.pendingEggPid, 0, "declining resets the pending egg identity")
    Assert.equal(bucket.eggCycleCounter, 0, "declining resets the cycle counter with the identity")
    Assert.equal(#bucket.slots, 2, "declining keeps both parents in care")
    Assert.equal(mons(declined):partyCount(), 0, "declining appends no Egg")
    Assert.equal(declined:renderAttempts(), 0, "the decline scenario stops before GPU rendering")
  end, debug.traceback)
  declined:close()
  if not declinedOk then
    error(declinedErr, 0)
  end
end

return T
