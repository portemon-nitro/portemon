-- The Rocket hideout effect owner: the three source trap kinds and their
-- anchors, the alarm's two alpha pulses and siren wait, the powered prop
-- projection from its own three flags, the map event key magic table, the save
-- stability window and the exactly-once cancellation.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")
local FieldCoordinates = require("libs.hgss.src.field.FieldCoordinates")
local RocketHideoutEffects = require("libs.hgss.src.field.RocketHideoutEffects")

local T = {}

---@param overrides table<string, unknown>|nil
local function newOwner(overrides)
  overrides = overrides or {}
  local host = {
    sounds = {},
    stopped = {},
    overlayClaims = 0,
    foreground = overrides.foreground or "script-a",
  }
  host.audio = {
    play = function(_, idOrSymbol)
      host.sounds[#host.sounds + 1] = idOrSymbol
    end,
    stop = function(_, idOrSymbol)
      host.stopped[#host.stopped + 1] = idOrSymbol
    end,
    isEffectWaitComplete = function()
      return host.soundDone ~= false
    end,
  }
  host.world = {
    flags = {},
    variables = {},
    isFlagSet = function(self, id)
      return self.flags[id] == true
    end,
    setVar = function(self, id, value)
      self.variables[id] = value
    end,
  }
  host.player = { fieldX = 12, fieldZ = 17, worldY = 1 }
  host.runtimeMap = {
    mapId = 247,
    coordinateOrigin = { x = 0, z = 0 },
    collision = {
      containsLocal = function()
        return true
      end,
    },
    mapProps = { placements = {}, props = {} },
    terrain = {
      sampleHeight = function()
        return 1
      end,
    },
  }
  local models = {}
  host.owner = RocketHideoutEffects.new({
    playerOf = function()
      return host.player
    end,
    runtimeMapOf = function()
      return host.runtimeMap
    end,
    audio = host.audio,
    world = host.world,
    mapEventKeyVariableBase = 16438,
    electrodeFlagBase = 2411,
    foregroundScript = function()
      return host.foreground
    end,
  })
  host.owner:setModelFactory({
    trap = function(kind)
      local model = {
        kind = kind,
        started = 0,
        updates = 0,
        disposed = 0,
        complete = false,
      }
      function model:start()
        self.started = self.started + 1
      end
      function model:updateFixed()
        self.updates = self.updates + 1
      end
      function model:isComplete()
        return self.complete == true
      end
      function model:dispose()
        self.disposed = self.disposed + 1
      end
      models[#models + 1] = model
      return model
    end,
  })
  host.models = models
  return host
end

function T.the_three_source_trap_kinds_anchor_to_the_player()
  local host = newOwner()
  local expected = { [0] = "electric", [1] = "poison", [2] = "rock" }
  for kind, name in pairs(expected) do
    host.owner:begin("rocket_trap", { kind = kind })
    local model = host.models[#host.models]
    Assert.equal(model.kind, name, "trap selector " .. kind .. " loads the " .. name .. " model")
    Assert.equal(model.started, 1, "the trap starts its source clips once")
    local trap = assert(host.owner:presentation().trap, "the active trap publishes its anchor")
    Assert.equal(trap.kind, name)
    local anchor = FieldCoordinates.fieldToWorld(host.runtimeMap, 12, 17, 1)
    Assert.equal(trap.x, anchor.x, "the trap stands on the player's own tile")
    Assert.equal(trap.z, anchor.z)
    Assert.equal(trap.y, anchor.y, "the trap keeps the player's height")
    model.complete = true
    Assert.equal(host.owner:step(), "complete", "the finished trap completes")
    Assert.equal(model.disposed, 1, "a completed trap releases its model exactly once")
  end
end

function T.a_trap_outside_the_source_kinds_is_an_attributed_fault()
  local host = newOwner()
  local err = Assert.throws(function()
    host.owner:begin("rocket_trap", { kind = 3 })
  end)
  Assert.isTrue(Errors.is(err), "an unknown trap kind raises a structured error")
  Assert.equal(err.code, FieldErrors.FIELD_ROCKET_EFFECT_INVALID)
  Assert.equal(#host.models, 0, "a refused trap acquires no model")
end

function T.the_trap_blocks_until_its_clips_and_source_sound_finished()
  local host = newOwner()
  host.owner:begin("rocket_trap", { kind = 0 })
  local model = host.models[1]
  Assert.equal(host.sounds[1], "SEQ_SE_GS_DENKI_TRAP", "the trap plays its own source sound")
  host.soundDone = false
  for _ = 1, 5 do
    Assert.equal(host.owner:step(), "active", "an unfinished source sound holds the trap")
  end
  host.soundDone = true
  Assert.equal(host.owner:step(), "active", "unfinished clips hold the trap")
  model.complete = true
  Assert.equal(host.owner:step(), "complete", "the finished trap completes")
  Assert.isFalse(host.owner:isRunning(), "a completed trap owns nothing")
end

function T.the_alarm_runs_two_alpha_pulses_then_waits_for_the_siren()
  local host = newOwner()
  host.owner:setOverlayFactory(function()
    host.overlayClaims = host.overlayClaims + 1
    return { overlay = true }
  end)
  host.owner:begin("rocket_alarm")
  Assert.equal(host.sounds[1], "SEQ_SE_GS_AJITO_SIREN", "the alarm plays the source siren")
  Assert.equal(host.overlayClaims, 1, "the alarm claims the source overlay once")
  local pulsesSeen = {}
  local peak = 0
  local activeSteps = 0
  while host.owner:step() == "active" do
    activeSteps = activeSteps + 1
    local alarm = assert(host.owner:presentation().alarm, "an active alarm publishes its pulse")
    pulsesSeen[alarm.pulse] = true
    peak = math.max(peak, alarm.blend)
  end
  Assert.equal(peak, RocketHideoutEffects.ALARM_PULSE_PEAK, "the pulse ramps to the source peak")
  Assert.isTrue(pulsesSeen[0] == true and pulsesSeen[1] == true, "the alarm runs both source pulses")
  Assert.isTrue(
    activeSteps >= RocketHideoutEffects.ALARM_PULSES * RocketHideoutEffects.ALARM_PULSE_STEPS,
    "each pulse takes its own source steps"
  )
  Assert.isNil(host.owner:presentation().alarm, "a completed alarm publishes no overlay")
end

function T.a_cancelled_effect_stops_its_sound_and_releases_its_model_once()
  local host = newOwner()
  host.owner:begin("rocket_trap", { kind = 1 })
  local model = host.models[1]
  Assert.isFalse(host.owner:isStableForSave(), "a live trap is not stable for save")
  host.owner:cancelRide("script cancelled")
  host.owner:cancelRide("script cancelled")
  Assert.equal(model.disposed, 1, "cancelling twice releases the model exactly once")
  Assert.equal(#host.stopped, 1, "cancelling stops the owned sound exactly once")
  Assert.isTrue(host.owner:isStableForSave(), "a cancelled trap is stable for save again")
  Assert.equal(host.owner:step(), "complete", "a cancelled trap completes without a lease")
end

function T.the_owner_stays_unstable_while_its_own_script_frame_owns_the_field()
  local host = newOwner()
  host.owner:begin("rocket_trap", { kind = 2 })
  Assert.isFalse(host.owner:isStableForSave(), "a live trap is not stable for save")
  host.models[1].complete = true
  Assert.equal(host.owner:step(), "complete", "the finished trap completes")
  Assert.isFalse(
    host.owner:isStableForSave(),
    "the starting script frame keeps the finished activation unstable while it owns the field"
  )
  host.foreground = "script-b"
  Assert.isTrue(host.owner:isStableForSave(), "another frame's ownership settles the activation")
end

function T.the_map_event_key_writes_the_source_magic_value_per_slot()
  local host = newOwner()
  for slot = 0, 3 do
    host.owner:writeMapEventKey(slot, 1)
    Assert.equal(
      host.world.variables[16438 + slot],
      RocketHideoutEffects.MAP_EVENT_KEY_MAGIC[slot + 1],
      "slot " .. slot .. " writes its own source magic value"
    )
    host.owner:writeMapEventKey(slot, 0)
    Assert.equal(host.world.variables[16438 + slot], 0, "a zero action clears that slot")
  end
  local err = Assert.throws(function()
    host.owner:writeMapEventKey(4, 1)
  end)
  Assert.equal(err.code, FieldErrors.FIELD_ROCKET_EFFECT_INVALID, "a slot outside the source table faults")
end

-- One powered prop the source map scene places: its own model carries the two
-- animation records the defeated flag selects.
local function poweredProp(memberId, plays)
  local instance = {
    definition = {
      animations = { { name = "aji_mech" .. memberId }, { name = "aji_mech_stop" .. memberId } },
    },
  }
  local prop = { instance = instance }
  function prop:stopAll()
    plays[#plays + 1] = { stopAll = true, memberId = memberId }
    return 2
  end
  function prop:playAll(name, options)
    plays[#plays + 1] = { name = name, loopMode = options and options.loopMode, memberId = memberId }
    return { { name = name } }
  end
  return prop
end

function T.the_powered_props_replay_the_record_their_own_flags_select()
  local host = newOwner()
  local plays = {}
  local props = {}
  for index, source in ipairs(RocketHideoutEffects.POWER_PROPS) do
    props[index] = poweredProp(source.memberId, plays)
    host.runtimeMap.mapProps.placements[#host.runtimeMap.mapProps.placements + 1] =
      { placementIndex = index, modelKey = "indoor:" .. source.memberId .. ":sha" }
  end
  host.runtimeMap.mapProps.prop = function(_, placementIndex)
    return props[placementIndex]
  end

  host.owner:syncPowerProps()
  -- Each projection drops the prop's whole registered set before replaying the
  -- selected record, the same way the source re-registers a prop's animation.
  for index, source in ipairs(RocketHideoutEffects.POWER_PROPS) do
    local dropped = plays[(index - 1) * 2 + 1]
    local played = plays[(index - 1) * 2 + 2]
    Assert.isTrue(dropped.stopAll == true, "prop " .. index .. " drops its registered clips")
    Assert.equal(played.name, "aji_mech" .. source.memberId, "an undefeated prop plays its intact record")
    Assert.equal(played.loopMode, "loop", "the source registers the record as an ambient loop")
  end

  -- A repeated projection of the same records changes nothing.
  local before = #plays
  host.owner:syncPowerProps()
  Assert.equal(#plays, before, "an unchanged flag vector replays nothing")

  -- Defeating the middle prop selects its own second record.
  host.world.flags[2411 + 1] = true
  host.owner:syncPowerProps()
  local changed = {}
  for index = before + 1, #plays do
    changed[#changed + 1] = plays[index]
  end
  Assert.equal(#changed, 2, "one changed flag stops and replays exactly one prop")
  Assert.isTrue(changed[1].stopAll == true, "the changed prop drops its previous record")
  Assert.equal(changed[2].name, "aji_mech_stop" .. RocketHideoutEffects.POWER_PROPS[2].memberId)
  Assert.equal(changed[2].loopMode, "loop")

  local selections = assert(host.owner:presentation().powerProps, "the projection publishes its selection")
  Assert.equal(#selections, 3, "every powered prop publishes its selected record")
  Assert.equal(selections[2].clipIndex, 2, "the defeated prop selects its source defeated record")
  Assert.equal(selections[1].clipIndex, 1, "an intact prop keeps its intact record")
end

function T.a_map_without_the_powered_prop_faults_instead_of_skipping()
  local host = newOwner()
  local err = Assert.throws(function()
    host.owner:syncPowerProps()
  end)
  Assert.equal(err.code, FieldErrors.FIELD_ROCKET_EFFECT_INVALID, "a missing powered prop is an attributed fault")
end

function T.a_headless_projection_records_the_selection_without_a_live_model()
  local host = newOwner()
  for index, source in ipairs(RocketHideoutEffects.POWER_PROPS) do
    host.runtimeMap.mapProps.placements[#host.runtimeMap.mapProps.placements + 1] =
      { placementIndex = index, modelKey = "indoor:" .. source.memberId .. ":sha" }
  end
  host.runtimeMap.mapProps.prop = function()
    return { instance = nil }
  end
  host.owner:syncPowerProps()
  local selections = assert(host.owner:presentation().powerProps, "a headless projection still selects")
  Assert.equal(#selections, 3, "every powered prop records its selected record")
end

function T.a_second_blocking_effect_is_refused_while_one_is_active()
  local host = newOwner()
  host.owner:begin("rocket_alarm")
  local err = Assert.throws(function()
    host.owner:begin("rocket_trap", { kind = 0 })
  end)
  Assert.equal(err.code, FieldErrors.FIELD_ROCKET_EFFECT_INVALID, "one blocking effect owns the field at a time")
end

return { tests = T }
