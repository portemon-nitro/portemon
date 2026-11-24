-- Field poison steps: every fourth committed step drains poisoned party
-- mons through the live mon service, plays the retail feedback, and
-- reports cure outcomes without disturbing the encounter boundary.

local Assert = require("tests.support.Assert")
local GameStats = require("libs.hgss.src.mons.GameStats")
local FieldPoison = require("libs.hgss.src.field.FieldPoison")
local FieldPoisonEffect = require("libs.hgss.src.field.FieldPoisonEffect")
local FieldRuntime = require("game.hgss.src.field.FieldRuntime")
local FieldRuntimeFixture = require("tests.support.FieldRuntimeFixture")

local T = { tests = {} }

local function poisonedMon(hp, key)
  return {
    isEgg = false,
    friendship = 70,
    mood = 0,
    condition = { currentHp = hp, effects = { { key = key or "poison", version = 1, state = {} } } },
  }
end

local function healthyMon(hp)
  return {
    isEgg = false,
    friendship = 70,
    mood = 0,
    condition = { currentHp = hp or 20, effects = {} },
  }
end

local function fakeMonService(party)
  local service = {
    _party = party,
    _revision = 7,
    staged = nil,
  }
  function service:partyCount()
    return #self._party
  end
  function service:partyMon(slot)
    return self._party[slot + 1]
  end
  function service:partyRevision()
    return self._revision
  end
  function service:countAliveMons()
    local count = 0
    for _, mon in ipairs(self._party) do
      if not mon.isEgg and mon.condition.currentHp > 0 then
        count = count + 1
      end
    end
    return count
  end
  function service:preparePartyChanges(revision, updates)
    Assert.equal(revision, self._revision, "poison stages against the live revision")
    self.staged = updates
    return {
      changed = true,
      isCurrent = function()
        return true
      end,
      publish = function()
        for _, update in ipairs(updates) do
          self._party[update.slot + 1] = update.mon
        end
        self._revision = self._revision + 1
      end,
    }
  end
  return service
end

local function fakeDialogue()
  local dialogue = { modal = false, opened = {}, completions = {} }
  function dialogue:isModal()
    return self.modal
  end
  function dialogue:open(request)
    self.modal = true
    self.opened[#self.opened + 1] = request
    local handle = {}
    function handle:onComplete(fn)
      dialogue.completions[#dialogue.completions + 1] = fn
      return handle
    end
    return handle
  end
  return dialogue
end

local function poisonRuntime(overrides)
  local steps = {}
  for _ = 1, (overrides and overrides.stepCount or 0) do
    steps[#steps + 1] = { fieldX = 5, fieldZ = 5 }
  end
  local dialogue = fakeDialogue()
  local encounters = { noted = 0, attempts = 0 }
  local runtime = FieldRuntimeFixture.withApricornDateOwner(setmetatable({
    _encounters = {
      noteStep = function()
        encounters.noted = encounters.noted + 1
      end,
      attempt = function()
        encounters.attempts = encounters.attempts + 1
        return { kind = "none", reason = "test-miss" }
      end,
    },
    encounters = encounters,
    session = {
      tick = 42,
      takeCommittedStep = function()
        return table.remove(steps, 1)
      end,
      mapEntryController = {
        isActive = function()
          return false
        end,
      },
      dialogue = dialogue,
      currentMap = {
        mapId = 1,
        mapSectionNativeId = 1,
        coordinateOrigin = { x = 0, z = 0 },
        collision = {
          containsLocal = function()
            return true
          end,
          getLocal = function()
            return { behavior = 2 }
          end,
        },
        fieldData = { wildEncounterMemberId = 7 },
      },
    },
    player = {
      fieldX = 5,
      fieldZ = 5,
      facing = "south",
      takeBikedSteps = function()
        return 0
      end,
    },
    gameStats = GameStats.new({ species = { CHIKORITA = true } }),
    playerData = { profile = {}, options = { textFrame = 3 } },
    battleCoordinator = {
      hasBattleWork = function()
        return false
      end,
      hasPresentationFactory = function()
        return false
      end,
    },
    pendingEncounterId = nil,
    monService = fakeMonService({ poisonedMon(20), healthyMon() }),
    fieldPoison = FieldPoison.new(),
    poisonEffect = FieldPoisonEffect.new(),
    audio = {
      played = {},
      play = function(self, symbol)
        self.played[#self.played + 1] = symbol
      end,
    },
    camera = {
      shakes = {},
      startShake = function(self, spec)
        self.shakes[#self.shakes + 1] = spec
      end,
    },
    scripts = {
      dialogueHost = {
        resolved = {},
        resolveMessage = function(self, message, bindings, textArgs)
          self.resolved[#self.resolved + 1] = { message = message, bindings = bindings, textArgs = textArgs }
          return { tokens = {} }
        end,
      },
      client = {
        started = {},
        startApplicationScript = function(self, scriptId, tick)
          self.started[#self.started + 1] = { scriptId = scriptId, tick = tick }
          return "started-application-script"
        end,
      },
      worldState = { rng = {
        nextRaw = function()
          return 0
        end,
      } },
    },
    localClock = {
      nowLocal = function()
        return { year = 2026, month = 1, day = 1, hour = 12 }
      end,
    },
    dialogue = dialogue,
  }, FieldRuntime))
  for key, value in pairs(overrides or {}) do
    if key ~= "stepCount" then
      runtime[key] = value
    end
  end
  return runtime
end

-- The damage path behind one poison tick: the counter fires every fourth
-- committed step, HP drains through the staged mon service, the retail
-- jingle and HBlank wobble fire (never the camera shake), and a plain
-- damage tick still resolves its encounter.
function T.tests.damage_tick_runs_every_fourth_step_through_the_live_party()
  local runtime = poisonRuntime({ stepCount = 5 })
  for _ = 1, 3 do
    runtime:_consumeCommittedStep()
  end
  Assert.isNil(runtime.monService.staged, "grace steps never touch the party")
  Assert.equal(#runtime.audio.played, 0, "grace steps play no jingle")
  runtime:_consumeCommittedStep()
  Assert.notNil(runtime.monService.staged, "the fourth step stages party damage")
  Assert.equal(runtime.monService:partyMon(0).condition.currentHp, 19, "poison drains one HP")
  Assert.equal(runtime.monService:partyMon(1).condition.currentHp, 20, "healthy mons are untouched")
  Assert.deepEqual(runtime.audio.played, { "SEQ_SE_DP_DOKU2" }, "the damage tick plays the poison jingle")
  Assert.equal(
    #runtime.camera.shakes,
    0,
    "the damage tick never shakes the camera: poison wobbles the 3D layer via HBlank"
  )
  Assert.isTrue(runtime.poisonEffect:isActive(), "the damage tick starts the HBlank wobble")
  local offsets =
    assert(runtime.poisonEffect:frame(), "the started wobble publishes its scanline frame").scanlineOffsets
  Assert.equal(#offsets, 192, "the wobble covers every native scanline")
  Assert.equal(#runtime.dialogue.opened, 0, "plain damage opens no message")
  Assert.equal(runtime.encounters.attempts, 4, "every step including the damage tick resolves its encounter")
end

-- The survive path behind one poison tick: mons floored at 1 HP shake
-- their status, each cured mon announces its nickname in slot order
-- through the player-framed field box, the step claims the encounter
-- boundary until every message dismisses, and the chain clears afterwards.
function T.tests.survive_tick_cures_in_slot_order_and_skips_encounters()
  local runtime = poisonRuntime({ stepCount = 1 })
  runtime.fieldPoison = FieldPoison.restore({ steps = 3 })
  runtime.monService = fakeMonService({ poisonedMon(2), poisonedMon(2) })
  runtime:_consumeCommittedStep()
  local first = runtime.monService:partyMon(0)
  Assert.equal(first.condition.currentHp, 1, "damage floors at 1 HP")
  Assert.deepEqual(first.condition.effects, {}, "the 1-HP mon shakes its status")
  Assert.isTrue(runtime.poisonEffect:isActive(), "the survive tick starts the HBlank wobble too")
  Assert.equal(#runtime.dialogue.opened, 1, "one cure message is open at a time")
  Assert.equal(runtime.scripts.dialogueHost.resolved[1].message, "msg.hgss.0040.00053")
  Assert.equal(runtime.dialogue.opened[1].frameIndex, 3, "the cure box carries the player-selected window frame")
  Assert.deepEqual(
    runtime.scripts.dialogueHost.resolved[1].textArgs[0],
    { text = "party_nickname", position = 0 },
    "the first cure names slot zero"
  )
  Assert.equal(runtime.encounters.attempts, 0, "the survive step never reaches the encounter roll")
  Assert.equal(runtime.encounters.noted, 0, "the survive step counts no grace either")
  runtime.dialogue.modal = false
  runtime.dialogue.completions[1]()
  Assert.equal(#runtime.dialogue.opened, 2, "dismissing chains the next cure")
  Assert.deepEqual(
    runtime.scripts.dialogueHost.resolved[2].textArgs[0],
    { text = "party_nickname", position = 1 },
    "the second cure names slot one"
  )
  runtime.dialogue.modal = false
  runtime.dialogue.completions[2]()
  Assert.isNil(runtime.poisonCure, "the chain clears after its last message")
end

return T
