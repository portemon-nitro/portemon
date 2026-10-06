local Assert = require("tests.support.Assert")
local Flow = require("libs.hgss.src.field.PokemonCenterHealFlow")

local T = { tests = {} }

local function rig(ballCount)
  local calls = { spawned = {}, ballHandles = {}, fanfare = 0, machine = 0, released = 0 }
  local mapId = "center"
  local audio = { playing = false }
  calls.audio = audio
  function audio:playFanfare(_)
    calls.fanfare = calls.fanfare + 1
    self.playing = true
  end
  function audio:play(_)
    calls.placement = (calls.placement or 0) + 1
  end
  function audio:isFanfarePlaying()
    return self.playing
  end
  local anchor = { position = { x = 10, y = 0, z = 20 } }
  function anchor:startAnimation(_)
    calls.machine = calls.machine + 1
    local handle = { finished = false }
    calls.machineHandle = handle
    function handle:startAnimation()
      self.started = true
    end
    handle:startAnimation()
    function handle:isFinished()
      return self.finished
    end
    function handle:updateFixed()
      self.fixedTicks = (self.fixedTicks or 0) + 1
    end
    function handle:release()
      calls.released = calls.released + 1
    end
    return handle
  end
  local flow = Flow.new({
    definition = {
      machineAnimation = "heal",
      fanfare = "heal",
      placementSound = "ball",
      ballPositions = {
        { role = "one", offset = { x = 0, y = 0, z = 0 } },
        { role = "two", offset = { x = 1, y = 0, z = 0 } },
        { role = "three", offset = { x = 2, y = 0, z = 0 } },
        { role = "four", offset = { x = 3, y = 0, z = 0 } },
        { role = "five", offset = { x = 4, y = 0, z = 0 } },
        { role = "six", offset = { x = 5, y = 0, z = 0 } },
      },
    },
    mapId = function()
      return mapId
    end,
    resolveAnchor = function()
      return anchor
    end,
    spawnBall = function(position, record)
      calls.spawned[#calls.spawned + 1] = { position = position, record = record }
      local handle = { finished = false }
      calls.ballHandles[#calls.ballHandles + 1] = handle
      function handle:startAnimation()
        self.started = true
      end
      function handle:updateFixed()
        self.finished = true
      end
      function handle:isFinished()
        return self.finished
      end
      function handle:dispose()
        calls.released = calls.released + 1
      end
      return handle
    end,
    audio = audio,
  })
  function calls:tick(count)
    for _ = 1, count or 1 do
      flow:updateFixed()
    end
  end
  function calls:finishGates()
    for _, handle in ipairs(self.ballHandles) do
      handle.finished = true
    end
    self.machineHandle.finished = true
    audio.playing = false
  end
  function calls:changeMap()
    mapId = "elsewhere"
  end
  return flow, calls
end

function T.tests.spawns_each_ball_after_a_full_delay_then_threshold_transition_and_waits_for_all_gates()
  local flow, calls = rig()
  flow:start(3)
  Assert.equal(#flow:status().balls, 1)
  -- Twelve delay invocations create nothing and start nothing.
  calls:tick(12)
  Assert.equal(#flow:status().balls, 1)
  Assert.equal(calls.machine, 0)
  Assert.equal(calls.fanfare, 0)
  -- The threshold-observation invocation selects the next ball without
  -- creating it or starting the machine.
  calls:tick(1)
  Assert.equal(#flow:status().balls, 1)
  Assert.equal(calls.machine, 0)
  Assert.equal(calls.fanfare, 0)
  -- Only the following invocation creates the next ball.
  calls:tick(1)
  Assert.equal(#flow:status().balls, 2)
  calls:tick(12)
  Assert.equal(#flow:status().balls, 2)
  calls:tick(1)
  Assert.equal(#flow:status().balls, 2)
  Assert.equal(calls.machine, 0)
  Assert.equal(calls.fanfare, 0)
  calls:tick(1)
  Assert.equal(#flow:status().balls, 3)
  -- The same delay/transition sequence runs after the final ball before
  -- the machine starts.
  calls:tick(12)
  Assert.equal(#flow:status().balls, 3)
  Assert.equal(calls.machine, 0)
  Assert.equal(calls.fanfare, 0)
  calls:tick(1)
  Assert.equal(calls.machine, 0)
  Assert.equal(calls.fanfare, 0)
  calls:tick(1)
  Assert.equal(calls.machine, 1)
  Assert.equal(calls.fanfare, 1)
  Assert.isTrue(calls.machineHandle.started)
  for _, handle in ipairs(calls.ballHandles) do
    Assert.isTrue(handle.started)
  end
  Assert.equal(flow:status().phase, "waiting")
  for _, handle in ipairs(calls.ballHandles) do
    handle.finished = true
  end
  calls.machineHandle.finished = true
  calls:tick()
  Assert.equal(flow:status().phase, "waiting", "animation completion cannot bypass an active fanfare")
  calls.audio.playing = false
  calls:finishGates()
  calls:tick()
  Assert.equal(flow:status().phase, "complete")
  Assert.equal(#flow:status().balls, 0)
  Assert.equal(calls.released, 4)
end

function T.tests.zero_count_still_runs_animation_and_fanfare()
  local flow, calls = rig()
  flow:start(0)
  calls:tick()
  Assert.equal(#calls.spawned, 0)
  Assert.equal(calls.machine, 1)
  Assert.equal(calls.fanfare, 1)
end

function T.tests.presentation_can_replace_the_headless_ball_factory_before_a_flow_starts()
  local flow, calls = rig()
  local presented = 0
  local headlessFactory = flow.spawnBall
  flow:setBallFactory(function(position, record, index)
    presented = presented + 1
    Assert.equal(index, 1)
    local handle = headlessFactory(position, record, index)
    handle.presented = true
    return handle
  end)
  flow:start(1)
  Assert.equal(presented, 1)
  Assert.isTrue(calls.ballHandles[1].presented)
end

function T.tests.one_and_six_party_members_use_the_generated_position_boundaries()
  local one, oneCalls = rig()
  one:start(1)
  Assert.equal(#oneCalls.spawned, 1)
  Assert.equal(one:status().balls[1].index, 1)
  oneCalls:tick(12)
  Assert.equal(oneCalls.machine, 0, "the delay still runs for a single ball")
  oneCalls:tick(1)
  Assert.equal(oneCalls.machine, 0, "the threshold step must not start the machine early")
  oneCalls:tick(1)
  Assert.equal(oneCalls.machine, 1, "the paired animation stage starts after the full delay sequence")

  local six, sixCalls = rig()
  six:start(6)
  for expected = 2, 6 do
    sixCalls:tick(12)
    Assert.equal(#sixCalls.spawned, expected - 1)
    sixCalls:tick(1)
    Assert.equal(#sixCalls.spawned, expected - 1)
    sixCalls:tick(1)
    Assert.equal(#sixCalls.spawned, expected)
  end
  sixCalls:tick(12)
  Assert.equal(sixCalls.machine, 0)
  sixCalls:tick(1)
  Assert.equal(sixCalls.machine, 0)
  sixCalls:tick(1)
  Assert.equal(sixCalls.machine, 1)
  Assert.equal(sixCalls.placement, 6)
end

function T.tests.flow_advances_machine_clock_once_per_waiting_fixed_tick()
  local flow, calls = rig()
  flow:start(0)
  calls:tick()
  Assert.equal(calls.machineHandle.fixedTicks, nil, "the start tick only begins playback")
  calls:tick(2)
  Assert.equal(calls.machineHandle.fixedTicks, 2, "the flow owns only semantic/headless machine clocks")
end

function T.tests.rejects_unsupported_count_and_cleans_on_map_invalidation()
  local flow, calls = rig()
  Assert.throws(function()
    flow:start(7)
  end)
  flow:start(2)
  calls:changeMap()
  calls:tick()
  Assert.notNil(flow:status().error)
  Assert.equal(#flow:status().balls, 0)
  Assert.equal(calls.released, 1)
end

function T.tests.invalid_anchor_becomes_a_structured_flow_failure()
  local flow, _ = rig()
  flow.resolveAnchor = function()
    return { position = { x = 0, y = 0 } }
  end
  flow:start(1)
  Assert.equal(flow:status().phase, "failed")
  Assert.notNil(flow:status().error)
  Assert.equal(#flow:status().balls, 0)
end

function T.tests.fanfare_failure_releases_started_machine_animation()
  local flow, calls = rig()
  flow.audio.playFanfare = function()
    error("injected fanfare failure")
  end
  flow:start(0)
  calls:tick()
  Assert.equal(flow:status().phase, "failed")
  Assert.equal(calls.machineHandle.started, true)
  Assert.equal(calls.released, 1)
end

function T.tests.failure_during_later_spawn_releases_already_owned_balls()
  local flow, calls = rig()
  local originalSpawn = flow.spawnBall
  local spawnCount = 0
  flow.spawnBall = function(...)
    spawnCount = spawnCount + 1
    if spawnCount == 2 then
      error("injected second spawn failure")
    end
    return originalSpawn(...)
  end
  flow:start(2)
  calls:tick(13)
  Assert.equal(flow:status().phase, "spawning", "the second spawn waits for the full delay and threshold steps")
  calls:tick(1)
  Assert.equal(flow:status().phase, "failed")
  Assert.notNil(flow:status().error)
  Assert.equal(#flow:status().balls, 0)
  Assert.equal(calls.released, 1)
end

return T
