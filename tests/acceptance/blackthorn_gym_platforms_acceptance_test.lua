-- Blackthorn Gym's three source platforms. A completed step onto one of a
-- platform's buttons starts that platform's source action before the field's
-- ordinary step owners run, so the platform carries the rider with the source
-- gondola transport and the claimed step never reaches the per-step consumers.
-- Each platform's own floor is the only walkable ground over the lava, the
-- buttons move the platform in the direction its rotation implies, and a
-- blocked move or rotation returns the platform and its rider to the state they
-- started from. The render trap stays active throughout.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local TransportTrace = require("tests.acceptance.support.TransportTrace")

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = { "field-runtime", "map-data:141", "map:141" },
    tags = { "field", "script", "gym", "save" },
  },
  tests = {},
}

local MAP = "MAP_BLACKTHORN_GYM"
-- The gym is one field coordinate space whose runtime origin is (0, 32), so the
-- source tiles below are spawnable at the fixture's map-local (x, z - 32).
local MAP_ORIGIN_Z = 32
-- The map's own on-load script installs the platform union: the source
-- InitBlackthornGym places (13,75,0), (9,58,1) and (14,32,0).
local INIT_SCRIPT = "vanilla.hgss.scr_seq.0943.script_001"
-- src/field/gymmick/blackthorn.c: the moving platform sound (started when an
-- action begins and stopped when it finishes) and the sound of a platform that
-- hits a wall.
local MOVE_SEQUENCE = "SEQ_SE_GS_GONDORA_IDOU"
local BONK_SEQUENCE = "SEQ_SE_GS_GONDORA_KABEHIT"

local function bootPlatforms(spawn, facing)
  local baseFactory = AcceptanceHarness.new().gameFactory
  local harness = AcceptanceHarness.new({
    gameFactory = function(versionId, map)
      local game = baseFactory(versionId, map)
      game.location.fieldX = spawn.fieldX
      game.location.fieldZ = spawn.fieldZ - MAP_ORIGIN_Z
      game.location.facing = facing
      return game
    end,
  })
  local game = harness:boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = MAP,
    save = "fresh",
    fieldOptions = { recordingScriptHosts = true },
  })
  game:waitForFieldEntry()
  local spawned = game:snapshot().player
  assert(
    spawned.fieldX == spawn.fieldX and spawned.fieldZ == spawn.fieldZ,
    "the fixture spawns the player on the requested source tile"
  )
  return game
end

local function failureText(game, scriptId)
  local faults = game:recordsForScript(scriptId, "script.error")
  if #faults == 0 then
    return nil
  end
  local payload = faults[1].payload or {}
  local context = payload.context or {}
  return tostring(payload.code) .. " (command " .. tostring(context.command or context.originalName or "unknown") .. ")"
end

-- One observed fixed tick in the shape TransportTrace's span helper reads, so a
-- scenario asserts the source transport distance without touching the
-- mechanism.
---@return { x: number, y: number, z: number, fieldX: integer, fieldZ: integer, motion: string }
local function sample(snapshot)
  local player = snapshot.player
  return {
    x = player.worldX,
    y = player.worldY,
    z = player.worldZ,
    fieldX = player.fieldX,
    fieldZ = player.fieldZ,
    motion = player.motion,
  }
end

-- Whether the platform action's own gondola sound is still running: an action
-- starts it and the source stops it when the platform settles, which is the
-- only completion signal a rotation (which never moves the rider) publishes.
local function gondolaSoundPlaying(game)
  local playing = false
  for _, effect in ipairs(game:hostEffects()) do
    if effect == "audio:" .. MOVE_SEQUENCE then
      playing = true
    elseif effect == "stop:" .. MOVE_SEQUENCE then
      playing = false
    end
  end
  return playing
end

-- Drives the production fixed tick until the field settles: no platform action
-- sound is running and the idle player publishes the same tile and world pose
-- twice in a row.
local function settle(game, maxTicks)
  maxTicks = maxTicks or 240
  local samples = {}
  local stable = 0
  for _ = 1, maxTicks do
    samples[#samples + 1] = sample(game:step())
    local current = samples[#samples]
    local previous = samples[#samples - 1]
    if
      current.motion == "idle"
      and not gondolaSoundPlaying(game)
      and previous ~= nil
      and previous.motion == "idle"
      and previous.x == current.x
      and previous.z == current.z
      and previous.fieldX == current.fieldX
      and previous.fieldZ == current.fieldZ
    then
      stable = stable + 1
      if stable >= 2 then
        return samples
      end
    else
      stable = 0
    end
  end
  local last = samples[#samples] or { fieldX = "none", fieldZ = "none", motion = "none" }
  error(
    string.format(
      "the field did not settle within %d fixed ticks; last tile %s,%s, motion %s, gondola sound playing %s",
      maxTicks,
      tostring(last.fieldX),
      tostring(last.fieldZ),
      tostring(last.motion),
      tostring(gondolaSoundPlaying(game))
    )
  )
end

-- One production step in `direction`, observed until it settles.
local function walk(game, direction)
  game:face(direction)
  game:move(direction)
  return settle(game)
end

---@param samples table[]
---@return table
local function lastSample(samples)
  return samples[#samples]
end

-- The first sample that reports the tile a step committed.
local function committedIndex(samples, fieldX, fieldZ)
  for index, observed in ipairs(samples) do
    if observed.fieldX == fieldX and observed.fieldZ == fieldZ then
      return index
    end
  end
  return nil
end

local function countEffects(game, entry)
  local count = 0
  for _, effect in ipairs(game:hostEffects()) do
    if effect == entry then
      count = count + 1
    end
  end
  return count
end

-- The canonical field step phase, read from the published save: the field
-- advances it once per committed step that reaches its own per-step owners, so
-- a step a gym mechanism claimed must leave it where it was.
local function fieldStepPhase(game)
  local save = game.runtime:captureGameSave()
  Assert.notNil(save, "a settled field publishes a game save")
  return save.fieldPoison.steps
end

---@param observed table
---@return string
local function tile(observed)
  return tostring(observed.fieldX) .. "," .. tostring(observed.fieldZ)
end

function T.tests.walking_onto_a_platform_button_claims_the_step_and_carries_the_rider()
  local game = bootPlatforms({ fieldX = 15, fieldZ = 36 }, "north")
  local ok, err = xpcall(function()
    local initFault = failureText(game, INIT_SCRIPT)

    -- Three ordinary steps start the field's four-step phase, so the step onto
    -- the platform button is the one that would advance it.
    for _ = 1, 3 do
      walk(game, "north")
    end
    local approach = game:snapshot()
    Assert.equal(approach.player.fieldX, 15, "the approach ends on the pad's column")
    Assert.equal(approach.player.fieldZ, 33, "the approach ends one tile south of the source button")
    Assert.equal(
      fieldStepPhase(game),
      3,
      "ordinary steps reach the field's per-step phase (phase " .. tostring(fieldStepPhase(game)) .. ")"
    )

    local samples = walk(game, "north")
    local boardedAt = committedIndex(samples, 15, 32)
    Assert.notNil(
      boardedAt,
      "the approach step commits the source button tile (path " .. tile(lastSample(samples)) .. ")"
    )
    local arrived = lastSample(samples)

    -- The completed step starts the platform's own source action.
    local starts = countEffects(game, "audio:" .. MOVE_SEQUENCE)
    Assert.equal(starts, 1, "a completed step onto the source button starts the gondola move (starts " .. starts .. ")")
    local stops = countEffects(game, "stop:" .. MOVE_SEQUENCE)
    Assert.equal(stops, 1, "the settled move releases its gondola sound (stops " .. stops .. ")")
    local bonks = countEffects(game, "audio:" .. BONK_SEQUENCE)
    Assert.equal(bonks, 0, "an unobstructed move never plays the wall hit (hits " .. bonks .. ")")

    -- The platform carries the rider its source five tiles east: one tile per
    -- two 8-unit motion ticks, published as carried pose rather than as steps.
    Assert.equal(
      arrived.fieldX,
      20,
      "the move carries the rider onto the next button column (arrived " .. tile(arrived) .. ")"
    )
    Assert.equal(
      arrived.fieldZ,
      32,
      "the move carries the rider along the button row (arrived " .. tile(arrived) .. ")"
    )
    local carried = TransportTrace.span(samples).x
    Assert.near(
      carried,
      5,
      0.5,
      "the platform travels its source five tiles (carried " .. string.format("%.2f", carried) .. ")"
    )
    for index = boardedAt + 1, #samples do
      local observed = samples[index]
      Assert.isTrue(observed.motion ~= "walking", "the carried rider presents no walking step at sample " .. index)
      Assert.isTrue(
        (observed.fieldX == 15 or observed.fieldX == 20) and observed.fieldZ == 32,
        "the carried rider only reports the button tile and the arrival tile (sample "
          .. index
          .. ": "
          .. tile(observed)
          .. ")"
      )
    end

    -- The claim precedes the ordinary step owners: the claimed step never
    -- reaches the field's per-step update and admits no encounter.
    local claimedPhase = fieldStepPhase(game)
    Assert.equal(
      claimedPhase,
      3,
      "the claimed step never reaches the field's per-step update (phase " .. tostring(claimedPhase) .. ")"
    )
    Assert.isNil(game.runtime.pendingEncounterId, "a claimed step admits no encounter")

    -- An unclaimed step still reaches those owners.
    local afterMove = lastSample(walk(game, "north"))
    Assert.equal(
      afterMove.fieldZ,
      31,
      "the moved platform's own floor carries the next ordinary step (arrived " .. tile(afterMove) .. ")"
    )
    local ordinaryPhase = fieldStepPhase(game)
    Assert.equal(
      ordinaryPhase,
      0,
      "an unclaimed step still reaches the field's per-step update (phase " .. tostring(ordinaryPhase) .. ")"
    )

    Assert.isNil(initFault, "the map's own init command installs the source platform union: " .. tostring(initFault))
    Assert.equal(game:renderAttempts(), 0, "the platform acceptance stops before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

function T.tests.platform_geometry_blocks_the_lava_and_a_blocked_move_returns_to_its_start()
  -- The field's own lava is walkable terrain for the source map; only a
  -- platform's floor may be entered.
  local lava = bootPlatforms({ fieldX = 19, fieldZ = 49 }, "west")
  local lavaOk, lavaErr = xpcall(function()
    local before = lava:snapshot()
    local arrived = lastSample(walk(lava, "west"))
    Assert.equal(
      arrived.fieldX,
      before.player.fieldX,
      "the lava outside a platform floor refuses the step (arrived " .. tile(arrived) .. ")"
    )
    Assert.equal(
      arrived.fieldZ,
      before.player.fieldZ,
      "the lava outside a platform floor refuses the step (arrived " .. tile(arrived) .. ")"
    )
  end, debug.traceback)
  lava:close()
  if not lavaOk then
    error(lavaErr, 0)
  end

  -- Platform 1 stands at (9,58) with rotation 1, so its south button is
  -- (9,59); the platform's south-facing leading wall already reaches the
  -- room's floor, so the source finishes the action without moving at all.
  local south = bootPlatforms({ fieldX = 9, fieldZ = 58 }, "south")
  local southOk, southErr = xpcall(function()
    local bonk = walk(south, "south")
    local committed = committedIndex(bonk, 9, 59)
    Assert.notNil(
      committed,
      "the approach step commits the south-facing button (arrived " .. tile(lastSample(bonk)) .. ")"
    )
    local hits = countEffects(south, "audio:" .. BONK_SEQUENCE)
    Assert.equal(hits, 1, "a leading wall that is already blocked plays the wall hit (hits " .. hits .. ")")
    local stops = countEffects(south, "stop:" .. MOVE_SEQUENCE)
    Assert.equal(stops, 1, "the refused move still releases its gondola sound (stops " .. stops .. ")")
    local afterCommit = {}
    for index = committed, #bonk do
      afterCommit[#afterCommit + 1] = bonk[index]
    end
    local span = TransportTrace.span(afterCommit)
    Assert.near(span.x, 0, 1e-9, "a move blocked at its first tile never carries the rider (x " .. span.x .. ")")
    Assert.near(span.z, 0, 1e-9, "a move blocked at its first tile never carries the rider (z " .. span.z .. ")")
    local stayed = lastSample(bonk)
    Assert.equal(
      stayed.fieldX,
      9,
      "the refused south move leaves the rider on its button (arrived " .. tile(stayed) .. ")"
    )
    Assert.equal(
      stayed.fieldZ,
      59,
      "the refused south move leaves the rider on its button (arrived " .. tile(stayed) .. ")"
    )
  end, debug.traceback)
  south:close()
  if not southOk then
    error(southErr, 0)
  end

  -- Platform 0 stands at (13,75) with rotation 0: its rotate button is the
  -- anchor, its east button (14,75) and its west button (12,75).
  local game = bootPlatforms({ fieldX = 14, fieldZ = 80 }, "north")
  local ok, err = xpcall(function()
    for _ = 1, 4 do
      walk(game, "north")
    end

    -- Stepping onto the east button moves the platform until its leading wall
    -- reaches the room's floor, then the source returns it three tiles.
    local bonk = walk(game, "north")
    Assert.notNil(
      committedIndex(bonk, 14, 75),
      "the approach step commits the platform's east button (path " .. tile(lastSample(bonk)) .. ")"
    )
    local hits = countEffects(game, "audio:" .. BONK_SEQUENCE)
    Assert.equal(hits, 1, "the blocked leading wall plays the wall hit (hits " .. hits .. ")")
    local stops = countEffects(game, "stop:" .. MOVE_SEQUENCE)
    Assert.equal(stops, 1, "the blocked move releases its gondola sound (stops " .. stops .. ")")
    local carried = TransportTrace.span(bonk).x
    Assert.near(
      carried,
      3,
      0.5,
      "the blocked move travels three source tiles out (carried " .. string.format("%.2f", carried) .. ")"
    )
    local returned = lastSample(bonk)
    Assert.equal(
      returned.fieldX,
      14,
      "the blocked move returns the rider to the east button (arrived " .. tile(returned) .. ")"
    )
    Assert.equal(
      returned.fieldZ,
      75,
      "the blocked move returns the rider to the east button (arrived " .. tile(returned) .. ")"
    )

    -- A blocked rotation leaves the source angle and the geometry it implies
    -- alone: only the move sound starts, the rider stays on the button, and the
    -- next button still presses the unrotated platform.
    local rotation = lastSample(walk(game, "west"))
    Assert.equal(rotation.fieldX, 13, "a refused rotation never moves the rider (arrived " .. tile(rotation) .. ")")
    Assert.equal(rotation.fieldZ, 75, "a refused rotation never moves the rider (arrived " .. tile(rotation) .. ")")
    local starts = countEffects(game, "audio:" .. MOVE_SEQUENCE)
    Assert.equal(starts, 2, "a completed step onto the rotate button starts the move sound (starts " .. starts .. ")")
    local rotBonks = countEffects(game, "audio:" .. BONK_SEQUENCE)
    Assert.equal(rotBonks, 1, "a refused rotation never reaches the wall hit (hits " .. rotBonks .. ")")

    -- The west button still moves the unrotated platform five source tiles and
    -- carries the rider with it.
    local west = walk(game, "west")
    Assert.notNil(
      committedIndex(west, 12, 75),
      "the unrotated platform still answers its west button (arrived " .. tile(lastSample(west)) .. ")"
    )
    local finalStops = countEffects(game, "stop:" .. MOVE_SEQUENCE)
    Assert.equal(finalStops, 3, "every finished action releases its gondola sound (stops " .. finalStops .. ")")
    local arrived = lastSample(west)
    Assert.equal(arrived.fieldX, 7, "the west move carries the rider five tiles (arrived " .. tile(arrived) .. ")")
    Assert.equal(
      arrived.fieldZ,
      75,
      "the west move carries the rider along the button row (arrived " .. tile(arrived) .. ")"
    )

    -- The floor travels with the platform: the three columns under the new
    -- anchor are walkable and the column beyond them is lava again.
    walk(game, "north")
    walk(game, "east")
    walk(game, "east")
    local interior = lastSample(walk(game, "east"))
    Assert.equal(
      interior.fieldX,
      9,
      "the lava beyond the moved floor refuses the step (arrived " .. tile(interior) .. ")"
    )
    Assert.equal(
      interior.fieldZ,
      74,
      "the lava beyond the moved floor refuses the step (arrived " .. tile(interior) .. ")"
    )

    Assert.equal(game:renderAttempts(), 0, "the platform acceptance stops before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

function T.tests.continue_restores_the_settled_platform_geometry()
  -- Platform 1 stands at (9,58) with rotation 1: its north button is (9,57) and
  -- its rotate button is the anchor.
  local game = bootPlatforms({ fieldX = 8, fieldZ = 57 }, "east")
  local ok, err = xpcall(function()
    local moved = walk(game, "east")
    Assert.notNil(
      committedIndex(moved, 9, 57),
      "the step onto the turned platform's north button completes (arrived " .. tile(lastSample(moved)) .. ")"
    )
    local starts = countEffects(game, "audio:" .. MOVE_SEQUENCE)
    Assert.equal(starts, 1, "the moved platform plays its gondola sound (starts " .. starts .. ")")
    local north = lastSample(moved)
    Assert.equal(north.fieldX, 9, "the north move carries the rider four tiles (arrived " .. tile(north) .. ")")
    Assert.equal(north.fieldZ, 53, "the north move carries the rider four tiles (arrived " .. tile(north) .. ")")

    -- The rotate button now sits under the moved anchor; one completed step
    -- onto it turns the platform a quarter turn without moving the rider.
    local turned = walk(game, "south")
    Assert.notNil(
      committedIndex(turned, 9, 54),
      "the step onto the moved platform's rotate button completes (arrived " .. tile(lastSample(turned)) .. ")"
    )
    local stops = countEffects(game, "stop:" .. MOVE_SEQUENCE)
    Assert.equal(stops, 2, "the finished quarter turn releases its sound (stops " .. stops .. ")")
    local settled = lastSample(turned)
    Assert.equal(settled.fieldX, 9, "a quarter turn never moves the rider (arrived " .. tile(settled) .. ")")
    Assert.equal(settled.fieldZ, 54, "a quarter turn never moves the rider (arrived " .. tile(settled) .. ")")
    local settledHeight = settled.y

    -- The turned floor replaces the previous footprint: the platform now
    -- reaches four tiles north of the anchor.
    walk(game, "north")
    walk(game, "north")
    walk(game, "north")
    local northEdge = lastSample(walk(game, "north"))
    Assert.equal(
      northEdge.fieldX,
      9,
      "the turned platform's floor reaches four tiles north of its anchor (arrived " .. tile(northEdge) .. ")"
    )
    Assert.equal(
      northEdge.fieldZ,
      50,
      "the turned platform's floor reaches four tiles north of its anchor (arrived " .. tile(northEdge) .. ")"
    )
    local offFloor = lastSample(walk(game, "north"))
    Assert.equal(
      offFloor.fieldX,
      9,
      "the lava beyond the turned floor refuses the step (arrived " .. tile(offFloor) .. ")"
    )
    Assert.equal(
      offFloor.fieldZ,
      50,
      "the lava beyond the turned floor refuses the step (arrived " .. tile(offFloor) .. ")"
    )

    game:save()
    Assert.isTrue(game.lifecycle.saveWrites > 0, "the settled platforms publish through the ordinary save store")
    game:restart()

    -- The settled geometry is installed before the loaded position is sampled:
    -- the first continued snapshot already stands on the turned floor at the
    -- height the ride left it.
    local continued = game:snapshot()
    Assert.equal(continued.mapSymbol, MAP, "Continue returns to the gym")
    Assert.equal(
      continued.player.fieldX,
      9,
      "Continue restores the rider's tile (resumed " .. tostring(continued.player.fieldX) .. ")"
    )
    Assert.equal(
      continued.player.fieldZ,
      50,
      "Continue restores the rider's tile (resumed " .. tostring(continued.player.fieldZ) .. ")"
    )
    Assert.near(
      continued.player.worldY,
      settledHeight,
      1e-6,
      "Continue restores the settled platform height (resumed " .. string.format("%.2f", continued.player.worldY) .. ")"
    )
    Assert.isNil(
      game.runtime.errorText,
      "Continue leaves the field runtime healthy: " .. tostring(game.runtime.errorText)
    )
    game:waitForFieldEntry()

    -- The restored collision is the turned footprint: its own edges refuse the
    -- lava on both axes and its interior is walkable.
    local refusedNorth = lastSample(walk(game, "north"))
    Assert.equal(
      refusedNorth.fieldZ,
      50,
      "the restored platform's northern edge still refuses the lava (arrived " .. tile(refusedNorth) .. ")"
    )
    walk(game, "west")
    local westEdge = lastSample(walk(game, "west"))
    Assert.equal(
      westEdge.fieldX,
      8,
      "the restored platform's western edge still refuses the lava (arrived " .. tile(westEdge) .. ")"
    )
    Assert.equal(
      westEdge.fieldZ,
      50,
      "the restored platform's western edge still refuses the lava (arrived " .. tile(westEdge) .. ")"
    )
    walk(game, "east")
    walk(game, "east")
    local eastEdge = lastSample(walk(game, "east"))
    Assert.equal(
      eastEdge.fieldX,
      10,
      "the restored platform's eastern edge still refuses the lava (arrived " .. tile(eastEdge) .. ")"
    )
    Assert.equal(
      eastEdge.fieldZ,
      50,
      "the restored platform's eastern edge still refuses the lava (arrived " .. tile(eastEdge) .. ")"
    )

    Assert.equal(game:renderAttempts(), 0, "the Continue acceptance stops before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

return T
