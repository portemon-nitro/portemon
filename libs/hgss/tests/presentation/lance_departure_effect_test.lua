-- Lance's fly-with-object effect owns real model players and the flyer state
-- producer. Waiting consumers read readiness/status; they never advance them.

local Assert = require("tests.support.Assert")
local AnimationPlayer = require("libs.hgss.src.presentation.AnimationPlayer")
local LanceDepartureEffect = require("libs.hgss.src.presentation.LanceDepartureEffect")

local T = {}

local function modelHandle()
  local plays, stopped, disposed = {}, 0, 0
  local model = {}
  function model:play(id, opts)
    local frames = id == "joint" and 2 or 3
    local player = AnimationPlayer.new({ frameCount = frames })
    player.loopMode = opts.loopMode
    local handle = { player = player }
    plays[#plays + 1] = handle
    return handle
  end
  function model:stop(handle)
    for index, candidate in ipairs(plays) do
      if candidate == handle then
        table.remove(plays, index)
        stopped = stopped + 1
        return 1
      end
    end
    return 0
  end
  function model:updateFixed()
    for _, handle in ipairs(plays) do
      handle.player:updateFixed()
    end
  end
  function model:dispose()
    disposed = disposed + 1
  end
  return model, function()
    return disposed, stopped
  end
end

function T.resource_readiness_and_flyer_status_come_from_the_effect_owner()
  local model, counts = modelHandle()
  local effect = LanceDepartureEffect.new({
    model = model,
    clipIds = { "joint", "color" },
    trainerFrameDurations = { 1, 1 },
  })
  Assert.isFalse(effect:spritesReady(), "sprite transfer starts cold")
  effect:loadSpriteGraphics()
  effect:updateFixed()
  Assert.isTrue(effect:spritesReady(), "the resource owner publishes transfer completion")
  effect:createTrainer()
  Assert.isTrue(effect:snapshot().trainer.visible)

  effect:showOtherObject({ x = 4, y = 0, z = 6 })
  Assert.isFalse(effect:isModelDone(), "the model effect waits for its real players")
  for _ = 1, 2 do
    effect:updateFixed()
  end
  Assert.isFalse(effect:isModelDone(), "the longer color channel is still playing")
  effect:updateFixed()
  Assert.isTrue(effect:isModelDone(), "both model channels reached their own terminals")
  effect:releaseModel()

  Assert.isFalse(effect:flyerReady(), "fly graphics have a separate transfer")
  effect:loadFlyGraphics()
  effect:updateFixed()
  Assert.isTrue(effect:flyerReady())
  Assert.isNil(effect:flyerStatus(), "no flyer exists before CreateFlyer")
  effect:createFlyer()
  Assert.equal(effect:flyerStatus(), 0, "CreateFlyer owns a hidden flyer")
  effect:startPickup()
  Assert.equal(effect:flyerStatus(), 1, "StartFlyerPickUp publishes the pickup state")

  local sawAirborne = false
  for _ = 1, 100 do
    effect:updateFixed()
    local status = effect:flyerStatus()
    if status == 3 then
      sawAirborne = true
    elseif status == 2 then
      break
    end
  end
  Assert.isTrue(sawAirborne, "the real flyer effect passes through status 3")
  Assert.equal(effect:flyerStatus(), 2, "the same effect later publishes status 2")
  Assert.isTrue(effect:snapshot().flyer.visible)
  effect:destroyFlyer()
  Assert.isNil(effect:flyerStatus(), "DestroyFlyer releases the effect")
  effect:dispose()
  local disposed, stopped = counts()
  Assert.equal(disposed, 1, "the model handle releases exactly once")
  Assert.equal(stopped, 2, "releaseModel stops both real model attachments")
end

return { tests = T }
