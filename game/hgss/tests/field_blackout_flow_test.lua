-- Retail blackout ordering and message/input ownership.

local Assert = require("tests.support.Assert")
local FieldBlackoutFlow = require("game.hgss.src.field.FieldBlackoutFlow")
local FieldMapDataCache = require("libs.assets.src.field.FieldMapDataCache")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")

local T = {}

local function harness(initialPhase)
  local events = {}
  local lifecyclePhase = initialPhase or "absent"
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
  })
  return {
    flow = flow,
    events = events,
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
  Assert.equal(h.flow:status().phase, "leave")
  h.setPhase("absent")
  h.flow:updateFixed({ pressedAction = true })
  Assert.equal(h.flow:status().phase, "relocate")
  Assert.equal(h.events[2][1], "load")
  h.finishSwap()
  h.flow:updateFixed()
  Assert.equal(h.events[4][1], "clearFlag")
  Assert.equal(h.events[4][2], FieldScriptSymbols.flagsByName.FLAG_HAVE_FOLLOWER)
  Assert.equal(h.events[5][2], FieldScriptSymbols.variablesByName.VAR_FOLLOWER_TRAINER_NUM)
  Assert.equal(h.events[6][1], "heal")
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

return { tests = T }
