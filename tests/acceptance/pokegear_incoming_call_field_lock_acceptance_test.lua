-- An incoming call locks the field and plays through the real
-- composition: a set trigger rings after its minutes, the live call
-- freezes player movement, it advances through its source pages to the
-- staged hangup, and the terminal result releases the field with the
-- source launch boundary closed. Both trigger kinds share one boot: an
-- ambient trigger answered on the action edge, then a forced trigger
-- whose source scene script rings the line and launches the call.
-- Production boot, real catalog/state/calendar/streams/host, ROM-derived
-- messages. Stops before GPU rendering.

local Assert = require("tests.support.Assert")
local Fixture = require("tests.support.PokegearJourneyFixture")
local LocalClock = require("game.src.LocalClock")

local DERIVED_ASSETS = {}
for _, key in ipairs(Fixture.JOURNEY_ASSETS) do
  DERIVED_ASSETS[#DERIVED_ASSETS + 1] = key
end
-- The answering caller's own bank, the generic time-of-day greeting
-- bank, the phone UI label bank, and the two phone class banks this
-- journey's Elm caller resolves through.
for _, bankId in ipairs({ 271, 279, 280, 640, 716, 730 }) do
  DERIVED_ASSETS[#DERIVED_ASSETS + 1] = "message-bank:" .. tostring(bankId)
end

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = DERIVED_ASSETS,
    tags = { "pokegear" },
  },
  tests = {},
}

---@param catalog table
---@return table trigger the Elm pokerus trigger behind slot 1
local function elmTrigger(catalog)
  for _, trigger in ipairs(assert(catalog.callTriggers, "the phone catalog carries its triggers")) do
    local record = trigger --[[@as table<string, unknown>]]
    if record.key == "gear.trigger.1" then
      return record
    end
  end
  error("the compiled phonebook carries the Elm pokerus trigger", 0)
end

---@param catalog table
---@param key string
---@return table trigger the forced source trigger behind the slot
local function forcedTrigger(catalog, key)
  for _, trigger in ipairs(assert(catalog.callTriggers, "the phone catalog carries its triggers")) do
    local record = trigger --[[@as table<string, unknown>]]
    if record.key == key then
      assert(record.forcePickUp == true, "the requested slot forces its pickup")
      return record
    end
  end
  error("the compiled phonebook carries " .. key, 0)
end

---@param catalog table
---@return table contact the Elm contact
local function elmContact(catalog)
  for _, entry in ipairs(assert(catalog.contacts, "the phone catalog carries its contacts")) do
    local record = entry --[[@as table<string, unknown>]]
    if record.family == "elm" then
      return record
    end
  end
  error("the native phonebook has an elm contact", 0)
end

---@param sample table<string, integer>
---@return table clock the production host clock over the mutable sample
local function clockAt(sample)
  return LocalClock.new(function()
    return {
      year = sample.year,
      month = sample.month,
      day = sample.day,
      hour = sample.hour,
      minute = sample.minute,
      second = sample.second,
    }
  end)
end

-- Held movement input across several ticks must move neither the tile,
-- the depth, nor the facing while the call owns the field.
---@param game table
---@param why string leading clause of every assertion message
local function assertFieldHolds(game, why)
  local locked = game:snapshot()
  game.runtime:press("north")
  for _ = 1, 30 do
    game:step()
  end
  game.runtime:release("north")
  local afterMove = game:snapshot()
  Assert.equal(afterMove.player.fieldX, locked.player.fieldX, why .. " freezes the field tile")
  Assert.equal(afterMove.player.fieldZ, locked.player.fieldZ, why .. " freezes the field depth")
  Assert.equal(afterMove.player.facing, locked.player.facing, why .. " freezes the field facing")
end

-- Action edges play the live call through its source pages to the staged
-- hangup and report whether any page published printable text.
---@param game table
---@param host table the companion script host owning the call
---@return boolean sawText
local function playCallToHangup(game, host)
  local sawText = false
  for _ = 1, 2000 do
    if not host:isActive() then
      break
    end
    local view = assert(host:status(), "the live call keeps its status").view.call
    if type(view) == "table" and type(view.lines) == "table" and #view.lines > 0 then
      sawText = true
    end
    game:pressAction()
  end
  return sawText
end

-- The released field answers live input again: held input turns the
-- player in place, which never traverses a warp and always answers, so a
-- wall cannot absorb it the way it absorbs a step.
---@param game table
---@param why string leading clause of the assertion message
local function assertFieldReleased(game, why)
  local settled = game:snapshot()
  local turnTo = settled.player.facing == "north" and "south" or "north"
  game.runtime:press(turnTo)
  for _ = 1, 30 do
    game:step()
    if game:snapshot().player.facing == turnTo then
      break
    end
  end
  game.runtime:release(turnTo)
  Assert.equal(game:snapshot().player.facing, turnTo, why .. " releases field input")
end

function T.tests.incoming_calls_lock_the_field_until_their_source_hangup()
  local sample = { year = 2024, month = 1, day = 8, hour = 10, minute = 0, second = 0 }
  Fixture.withGame(Fixture.TOWN, function(game)
    local catalog = assert(game.runtime.pokegearCatalog, "the field runtime owns the ROM-derived phone catalog")
    local state = assert(game.runtime.pokegearState, "the field runtime owns the phonebook state")
    local calls = assert(game.runtime.incomingCalls, "the field runtime owns the incoming-call policy")
    local host = assert(game.runtime.pokegear.scriptHost, "the field owns the script companion host")
    ---@param predicate fun(): boolean
    ---@return boolean reached
    local function advanceMinutes(predicate, ticks)
      for _ = 1, ticks do
        sample.minute = sample.minute + 1
        game:step()
        if predicate() then
          return true
        end
      end
      return false
    end

    -- An ambient trigger rings its owner past the accelerated threshold
    -- without opening anything on its own, and the action edge answers it.
    do
      local elm = elmContact(catalog)
      local trigger = elmTrigger(catalog)
      Assert.equal(trigger.contact, elm.key, "the Elm trigger rings its owner")
      state:registerContact(elm.key)
      calls:setTrigger(trigger.key, true)
      Assert.isTrue(advanceMinutes(function()
        return calls:notification() ~= false
      end, 30), "the ambient trigger rings after its minutes")
      local notice = calls:notification()
      Assert.equal((notice --[[@as table]]).contactKey, elm.key, "the ring names the trigger owner")

      -- Face away from anything interactable so the action edge answers
      -- the call instead of talking to a neighbour.
      for _, direction in ipairs({ "north", "south", "west", "east" }) do
        game:face(direction)
        if game:interaction().kind == nil then
          break
        end
      end
      Assert.isNil(game:interaction().kind, "the answer edge faces no interactable")
      game:pressAction()
      Assert.isTrue(host:isActive(), "answering acquires the companion host")
      local status = assert(host:status(), "the accepted call publishes its status")
      Assert.notNil(status.view.call, "the accepted call publishes its conversation view")

      assertFieldHolds(game, "the live call")
      Assert.isTrue(host:isActive(), "movement never leaks into the live call")

      local sawHangingUp = false
      local sawText = false
      for _ = 1, 2000 do
        if not host:isActive() then
          break
        end
        local view = assert(host:status(), "the live call keeps its status").view.call
        if view ~= nil then
          if view.stage == "hangingUp" then
            sawHangingUp = true
          end
          if type(view.lines) == "table" and #view.lines > 0 then
            sawText = true
          end
        end
        game:pressAction()
      end
      Assert.isTrue(sawText, "the accepted call publishes its conversation text")
      Assert.isTrue(sawHangingUp, "the accepted call reaches its staged hangup")
      Assert.isFalse(host:isActive(), "the terminal call releases the companion host")
      Assert.isFalse(calls:notification(), "acceptance ends the ring")
      Assert.equal(state:readPhone().triggers[trigger.key], nil, "the launch clears its own trigger flag")
      for _, list in pairs(assert(state:readPhone().history, "the phone state carries its call journal")) do
        for _, key in ipairs(list) do
          Assert.isTrue(key ~= elm.key, "a trigger launch records no recent caller")
        end
      end
      assertFieldReleased(game, "the ambient call")
    end

    -- A forced source trigger answers itself the way the source does: the
    -- field starts the standard-bank call scene script, which rings the
    -- line twice behind the caller window, and the launched call then
    -- plays to its hangup and lets the scene script resume.
    do
      local trigger = forcedTrigger(catalog, "gear.trigger.2")
      state:registerContact(trigger.contact)
      calls:setTrigger(trigger.key, true)
      local sceneScript = nil
      local tones = 0
      Assert.isTrue(advanceMinutes(function()
        if host:isActive() then
          return true
        end
        local notice = calls:notification()
        if notice == false then
          return false
        end
        local snapshot = game:snapshot()
        sceneScript = sceneScript or snapshot.foregroundScript
        Assert.equal((notice --[[@as table]]).contactKey, trigger.contact, "the caller window names the forced caller")
        Assert.isTrue(snapshot.fieldLocked, "the call scene script owns the field while it rings")
        Assert.equal(snapshot.screenFade.coefficient, 0, "no field cover hides the caller window")
        for _, effect in ipairs(game:hostEffects()) do
          if effect == "audio:SEQ_SE_GS_PHONE0" then
            tones = tones + 1
          end
        end
        return false
      end, 120), "a forced trigger publishes its caller window while it rings")
      Assert.equal(
        sceneScript,
        "vanilla.hgss.scr_seq.0003.script_047",
        "the forced call starts the source call scene script"
      )
      Assert.isTrue(tones >= 2, "the forced call rings the source tone pair first")
      Assert.isTrue(host:isActive(), "the scene script launches the forced call")
      Assert.isFalse(calls:notification(), "the launched call leaves no caller window behind")
      Assert.deepEqual(state:readPhone().triggers, {}, "the forced trigger clears at its launch")
      local status = assert(host:status(), "the forced call publishes its status")
      Assert.notNil(status.view.call, "the forced call publishes its conversation view")

      assertFieldHolds(game, "the forced call")
      Assert.isTrue(playCallToHangup(game, host), "the forced call publishes its conversation text")
      Assert.isFalse(host:isActive(), "the terminal forced call releases the companion host")

      -- The scene script resumes after its launch: it restores the
      -- overworld, reveals the field and returns, releasing its task.
      game:advanceUntil("the forced call scene script finishes", function()
        return game:snapshot().foregroundScript == nil
      end, 240)
      Assert.isFalse(game:snapshot().fieldLocked, "the finished forced call releases the field")
      assertFieldReleased(game, "the forced call")
    end
  end, { localClock = clockAt(sample) })
end

return T
