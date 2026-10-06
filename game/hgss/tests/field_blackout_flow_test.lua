-- Retail blackout ordering and message/input ownership.

local Assert = require("tests.support.Assert")
local FieldBlackoutFlow = require("game.hgss.src.field.FieldBlackoutFlow")
local FieldMapDataCache = require("libs.assets.src.field.FieldMapDataCache")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")

local T = {}

local function harness(initialPhase, indexOverride)
  local events = {}
  local lifecyclePhase = initialPhase or "absent"
  local travelWrites = {}
  local travelValue = nil
  local transition = { phase = "idle", sourceMap = nil }
  transition.startCoveredSwap = function(_, sourceMap, trigger, facing)
    transition.phase = "covered_swap"
    transition.sourceMap = sourceMap
    transition.trigger = trigger
    transition.facing = facing
    events[#events + 1] = { "covered_swap", sourceMap, trigger, facing }
  end
  local audioFadeActive = true
  local world = {
    clearFlag = function(_, flag)
      events[#events + 1] = { "clearFlag", flag }
    end,
    setVar = function(_, var, value)
      events[#events + 1] = { "setVar", var, value }
    end,
  }
  local overworld = {
    phase = function()
      return lifecyclePhase
    end,
    requestLeave = function()
      lifecyclePhase = "leaving"
      events[#events + 1] = { "leave" }
    end,
    requestRestore = function()
      lifecyclePhase = "restoring"
      events[#events + 1] = { "restore" }
    end,
  }
  local flow = FieldBlackoutFlow.new({
    cacheFs = {
      loadLua = function(_, path)
        Assert.equal(path, FieldMapDataCache.spawnIndexPath())
        if indexOverride ~= nil then
          return indexOverride
        end
        return {
          schema = FieldMapDataCache.SPAWN_INDEX_SCHEMA,
          spawns = { SPAWN_CHERRYGROVE = { map = "MAP_CHERRYGROVE", fieldX = 1, fieldZ = 2 } },
          blackoutSpawns = {
            SPAWN_NEW_BARK = {
              map = "MAP_NEW_BARK_PLAYER_HOUSE_1F",
              fieldX = 6,
              fieldZ = 8,
              facing = "north",
            },
            SPAWN_CHERRYGROVE = {
              map = "MAP_CHERRYGROVE_POKECENTER_1F",
              fieldX = 8,
              fieldZ = 13,
              facing = "north",
            },
          },
          specialSpawns = {
            SPAWN_NEW_BARK = {
              map = "MAP_NEW_BARK",
              fieldX = 695,
              fieldZ = 397,
              warpId = -1,
              direction = "south",
            },
            SPAWN_CHERRYGROVE = {
              map = "MAP_CHERRYGROVE",
              fieldX = 564,
              fieldZ = 392,
              warpId = -1,
              direction = "south",
            },
          },
        }
      end,
    },
    loader = {
      load = function(_, map)
        events[#events + 1] = { "load", map }
        return { mapId = 69, coordinateOrigin = { x = 100, z = 200 } }
      end,
    },
    transition = transition,
    sourceMap = function()
      return { mapId = 7 }
    end,
    world = world,
    mons = {
      healParty = function()
        events[#events + 1] = { "heal" }
      end,
    },
    audio = {
      fadeMusicOut = function(_, spec)
        events[#events + 1] = { "fadeMusicOut", spec }
      end,
      isMusicFadeActive = function()
        return audioFadeActive
      end,
      stopMusic = function()
        events[#events + 1] = { "stopMusic" }
      end,
    },
    overworld = overworld,
    resolveMessage = function(message, bindings, textArgs)
      events[#events + 1] = { "resolveMessage", message, bindings, textArgs }
      return { tokens = { { kind = "glyph", code = 1, text = "R" } } }
    end,
    travel = {
      setSpecialSpawn = function(_, record)
        travelWrites[#travelWrites + 1] = record
        travelValue = record
      end,
      specialSpawn = function()
        return travelValue
      end,
    },
  })
  return {
    flow = flow,
    events = events,
    travelWrites = travelWrites,
    transition = transition,
    setPhase = function(phase)
      lifecyclePhase = phase
    end,
    finishSwap = function()
      transition.sourceMap = nil
      transition.phase = "idle"
    end,
    finishMusicFade = function()
      audioFadeActive = false
    end,
  }
end

T["mother recovery waits for covered relocation, audio, fade, input and restore"] = function()
  local h = harness("present")
  local runId = h.flow:start("SPAWN_NEW_BARK")
  Assert.equal(#h.travelWrites, 1, "start records the durable special destination")
  Assert.deepEqual(h.travelWrites[1], {
    map = "MAP_NEW_BARK",
    fieldX = 695,
    fieldZ = 397,
    warpId = -1,
    direction = "south",
  })
  Assert.equal(h.events[1][1], "clearFlag")
  Assert.equal(h.events[1][2], FieldScriptSymbols.flagsByName.FLAG_HAVE_FOLLOWER)
  Assert.deepEqual(h.events[2], { "setVar", FieldScriptSymbols.variablesByName.VAR_FOLLOWER_TRAINER_NUM, 0 })
  Assert.equal(h.events[3][1], "heal")
  Assert.equal(h.events[4][1], "leave")
  Assert.equal(h.flow:status().phase, "leave")
  h.setPhase("absent")
  h.flow:updateFixed({ pressedAction = true })
  Assert.equal(h.flow:status().phase, "relocate")
  Assert.equal(h.events[5][1], "load")
  h.finishSwap()
  h.flow:updateFixed()
  Assert.equal(h.events[7][1], "fadeMusicOut")
  Assert.equal(h.events[7][2].durationTicks, 20)
  Assert.equal(h.flow:status().phase, "fade_music")
  h.finishMusicFade()
  h.flow:updateFixed()
  local resolvedMessage = h.events[#h.events]
  Assert.equal(resolvedMessage[1], "resolveMessage")
  Assert.equal(resolvedMessage[2], "msg.hgss.0203.00004")
  Assert.equal(resolvedMessage[4][0].text, "player_name")
  Assert.equal(h.flow:status().phase, "message_in")
  Assert.deepEqual(h.flow:status().message.tokens, { { kind = "glyph", code = 1, text = "R" } })
  Assert.equal(h.flow:status().coverColor, "white")
  Assert.equal(h.flow:status().coverAlpha, 1)

  h.flow:updateFixed({ pressedAction = true })
  Assert.equal(h.flow:status().phase, "message_in", "early input cannot skip the white fade")
  for _ = 1, 8 do
    h.flow:updateSourceFrame()
  end
  h.flow:updateFixed()
  Assert.equal(h.flow:status().phase, "message_wait")
  h.flow:updateFixed({ pressedAction = true })
  Assert.equal(h.flow:status().phase, "message_out")
  h.flow:updateFixed({ pressedCancel = true })
  Assert.equal(h.flow:status().phase, "message_out", "input cannot skip the black fade")
  for _ = 1, 8 do
    h.flow:updateSourceFrame()
  end
  h.flow:updateFixed({ touchPressed = true })
  Assert.equal(h.flow:status().phase, "restore")
  h.setPhase("present")
  h.flow:updateFixed()
  Assert.equal(h.flow:status().followup, "common.whited_out_to_mom")
  Assert.equal(h.flow:consumeResult(runId), "common.whited_out_to_mom")
  Assert.equal(h.flow:status().phase, "idle")
end

T["center recovery selects the Pokémon Center message and rejects transitions it did not start"] = function()
  local h = harness("absent")
  h.flow:start("SPAWN_CHERRYGROVE")
  h.flow:updateFixed()
  h.finishSwap()
  h.flow:updateFixed()
  h.finishMusicFade()
  h.flow:updateFixed()
  Assert.equal(h.events[#h.events][2], "msg.hgss.0203.00003")
  Assert.equal(h.flow:status().followup, nil)

  for _, phase in ipairs({ "leaving", "restoring" }) do
    local transitioning = harness(phase)
    local ok = pcall(transitioning.flow.start, transitioning.flow, "SPAWN_CHERRYGROVE")
    Assert.isFalse(ok, "whiteout cannot race a lifecycle " .. phase)
    Assert.equal(#transitioning.travelWrites, 0, "a raced lifecycle writes no durable record")
    Assert.equal(transitioning.events[1], nil, "a raced lifecycle mutates no recovery state")
  end
end

T["invalid blackout destination leaves a present overworld untouched"] = function()
  local h = harness("present")
  local ok = pcall(h.flow.start, h.flow, "SPAWN_MISSING")
  Assert.isFalse(ok)
  Assert.equal(h.events[1], nil, "destination validation precedes lifecycle mutation")
  Assert.equal(h.flow:status().phase, "idle")
end

T["cancel and disposal discard a static message without dialogue cleanup"] = function()
  local cancelled = harness("absent")
  local cancelId = cancelled.flow:start("SPAWN_NEW_BARK")
  cancelled.flow:updateFixed()
  cancelled.finishSwap()
  cancelled.flow:updateFixed()
  cancelled.finishMusicFade()
  cancelled.flow:updateFixed()
  Assert.notNil(cancelled.flow:status().message)
  cancelled.flow:cancel(cancelId)
  Assert.equal(cancelled.flow:status().phase, "idle")

  local disposed = harness("absent")
  disposed.flow:start("SPAWN_NEW_BARK")
  disposed.flow:updateFixed()
  disposed.finishSwap()
  disposed.flow:updateFixed()
  disposed.finishMusicFade()
  disposed.flow:updateFixed()
  Assert.notNil(disposed.flow:status().message)
  disposed.flow:dispose()
  Assert.equal(disposed.flow:status().phase, "idle")
end

local function countKind(events, kind)
  local count = 0
  for _, event in ipairs(events) do
    if event[1] == kind then
      count = count + 1
    end
  end
  return count
end

T["accepted start records recovery state before relocation completes"] = function()
  local h = harness("present")
  h.flow:start("SPAWN_NEW_BARK")
  Assert.equal(#h.travelWrites, 1, "one durable special record is written at start")
  Assert.deepEqual(h.travelWrites[1], {
    map = "MAP_NEW_BARK",
    fieldX = 695,
    fieldZ = 397,
    warpId = -1,
    direction = "south",
  })
  Assert.equal(countKind(h.events, "clearFlag"), 1, "follower state clears at start")
  Assert.equal(countKind(h.events, "setVar"), 1, "follower trainer clears at start")
  Assert.equal(countKind(h.events, "heal"), 1, "the party heals at start")
  h.setPhase("absent")
  h.flow:updateFixed()
  Assert.equal(h.flow:status().phase, "relocate")
  h.finishSwap()
  h.flow:updateFixed()
  Assert.equal(#h.travelWrites, 1, "relocation never rewrites the durable record")
  Assert.equal(countKind(h.events, "heal"), 1, "recovery heals exactly once")
  Assert.equal(countKind(h.events, "clearFlag"), 1, "relocation never re-clears follower state")
  Assert.equal(countKind(h.events, "setVar"), 1, "relocation never re-zeroes the follower trainer")
end

T["missing special destination refuses before any recovery mutation"] = function()
  local index = {
    schema = FieldMapDataCache.SPAWN_INDEX_SCHEMA,
    spawns = { SPAWN_NEW_BARK = { map = "MAP_NEW_BARK", fieldX = 695, fieldZ = 397 } },
    blackoutSpawns = {
      SPAWN_NEW_BARK = { map = "MAP_NEW_BARK_PLAYER_HOUSE_1F", fieldX = 6, fieldZ = 8, facing = "north" },
    },
    specialSpawns = {},
  }
  local h = harness("present", index)
  local ok = pcall(h.flow.start, h.flow, "SPAWN_NEW_BARK")
  Assert.isFalse(ok, "a missing special record refuses start")
  Assert.equal(#h.travelWrites, 0, "no durable record is written")
  Assert.equal(h.events[1], nil, "no follower or healing mutation runs")
  Assert.equal(h.flow:status().phase, "idle")
end

T["malformed special destination refuses before any recovery mutation"] = function()
  local index = {
    schema = FieldMapDataCache.SPAWN_INDEX_SCHEMA,
    spawns = { SPAWN_NEW_BARK = { map = "MAP_NEW_BARK", fieldX = 695, fieldZ = 397 } },
    blackoutSpawns = {
      SPAWN_NEW_BARK = { map = "MAP_NEW_BARK_PLAYER_HOUSE_1F", fieldX = 6, fieldZ = 8, facing = "north" },
    },
    specialSpawns = {
      SPAWN_NEW_BARK = { map = "MAP_NEW_BARK", fieldX = 695, fieldZ = 397, warpId = -1, direction = "up" },
    },
  }
  local h = harness("present", index)
  local ok = pcall(h.flow.start, h.flow, "SPAWN_NEW_BARK")
  Assert.isFalse(ok, "a malformed special record refuses start")
  Assert.equal(#h.travelWrites, 0, "no durable record is written")
  Assert.equal(h.events[1], nil, "no follower or healing mutation runs")
  Assert.equal(h.flow:status().phase, "idle")
end

T["failed relocation keeps the accepted recovery state without rehealing"] = function()
  local h = harness("present")
  h.flow:start("SPAWN_NEW_BARK")
  Assert.equal(#h.travelWrites, 1, "initialization runs at start")
  h.setPhase("absent")
  h.flow:updateFixed()
  Assert.equal(h.flow:status().phase, "relocate")
  h.transition.error = { message = "swap failed" }
  h.flow:updateFixed()
  Assert.notNil(h.flow:status().error, "the swap failure surfaces")
  Assert.equal(#h.travelWrites, 1, "the durable record is retained")
  Assert.equal(countKind(h.events, "heal"), 1, "failure never reheals")
  Assert.equal(countKind(h.events, "clearFlag"), 1, "failure never re-clears")
end

T["repeated start is rejected before a second initialization"] = function()
  local h = harness("present")
  h.flow:start("SPAWN_NEW_BARK")
  local ok = pcall(h.flow.start, h.flow, "SPAWN_NEW_BARK")
  Assert.isFalse(ok, "a second start while active is rejected")
  Assert.equal(#h.travelWrites, 1, "initialization runs exactly once")
  Assert.equal(countKind(h.events, "heal"), 1, "the party heals exactly once")
end

T["construction requires the durable travel owner"] = function()
  local h = harness("present")
  local ok = pcall(FieldBlackoutFlow.new, {
    cacheFs = h.flow.cacheFs,
    loader = h.flow.loader,
    transition = h.flow.transition,
    sourceMap = h.flow.sourceMap,
    world = h.flow.world,
    mons = h.flow.mons,
    audio = h.flow.audio,
    overworld = h.flow.overworld,
    resolveMessage = h.flow.resolveMessage,
  })
  Assert.isFalse(ok, "blackout construction without travel fails")
end

return { tests = T }
