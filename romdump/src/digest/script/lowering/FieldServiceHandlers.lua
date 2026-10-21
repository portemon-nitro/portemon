-- Field service, lifecycle, query, prop-animation, and heal lowerings.
-- They live here so their names never become more file-scoped locals
-- in the main field-handler chunk.

local Operands = require("romdump.src.digest.script.lowering.Operands")

---@class FieldServiceHandlers
local FieldServiceHandlers = {}

function FieldServiceHandlers.whiteout(_)
  return { op = "whiteout" }
end

function FieldServiceHandlers.celebiTimeTravel(_)
  -- ScrCmd_CelebiTimeTravel carries no operands: the source starts its
  -- cutscene task and waits for it.
  return { op = "celebi_time_travel" }
end

function FieldServiceHandlers.legendCutscene(op, ins)
  local step = { op = op }
  if ins.operands[1] ~= nil then
    step.destination = Operands.operandValue(ins.operands[1])
  end
  return step
end

function FieldServiceHandlers.legendCutsceneBellBegin(ins)
  return FieldServiceHandlers.legendCutscene("legend_cutscene_bell_begin", ins)
end
function FieldServiceHandlers.legendCutsceneBellEnd(ins)
  return FieldServiceHandlers.legendCutscene("legend_cutscene_bell_end", ins)
end
function FieldServiceHandlers.legendCutsceneBellRise(ins)
  return FieldServiceHandlers.legendCutscene("legend_cutscene_bell_rise", ins)
end
function FieldServiceHandlers.legendCutsceneBellShimmer(ins)
  return FieldServiceHandlers.legendCutscene("legend_cutscene_bell_shimmer", ins)
end
function FieldServiceHandlers.legendCutsceneCameraMove(ins)
  return FieldServiceHandlers.legendCutscene("legend_cutscene_camera_move", ins)
end
function FieldServiceHandlers.legendCutsceneCameraPan(ins)
  return FieldServiceHandlers.legendCutscene("legend_cutscene_camera_pan", ins)
end
function FieldServiceHandlers.legendCutsceneCameraWait(ins)
  return FieldServiceHandlers.legendCutscene("legend_cutscene_camera_wait", ins)
end
function FieldServiceHandlers.legendCutsceneBirdApproach(ins)
  return FieldServiceHandlers.legendCutscene("legend_cutscene_bird_approach", ins)
end
function FieldServiceHandlers.legendCutsceneLugiaEyeGlimmer(ins)
  return FieldServiceHandlers.legendCutscene("legend_cutscene_lugia_eye_glimmer", ins)
end
function FieldServiceHandlers.legendCutsceneLugiaArrivesBegin(ins)
  return FieldServiceHandlers.legendCutscene("legend_cutscene_lugia_arrives_begin", ins)
end
function FieldServiceHandlers.legendCutsceneLugiaArrivesEnd(ins)
  return FieldServiceHandlers.legendCutscene("legend_cutscene_lugia_arrives_end", ins)
end
function FieldServiceHandlers.legendCutsceneLugiaArrivesCameraPan(ins)
  return FieldServiceHandlers.legendCutscene("legend_cutscene_lugia_arrives_camera_pan", ins)
end
function FieldServiceHandlers.legendCutsceneEffectBegin(ins)
  return FieldServiceHandlers.legendCutscene("legend_cutscene_effect_begin", ins)
end
function FieldServiceHandlers.legendCutsceneEffectEnd(ins)
  return FieldServiceHandlers.legendCutscene("legend_cutscene_effect_end", ins)
end
function FieldServiceHandlers.legendCinematic(ins)
  return FieldServiceHandlers.legendCutscene("legend_cinematic", ins)
end
function FieldServiceHandlers.screenShake(ins)
  -- ScrCmd_ScreenShake amplitudeX, amplitudeY, repeats, period: the source
  -- returns TRUE at once while its shake task runs beside the script, so
  -- the script-owned shake_camera operation is a pinned same-tick
  -- passthrough and the caller's own waits cover the shake. Variable
  -- operands stay explicit like the other value-or-variable lowerings.
  local amplitudeX = Operands.varRef(ins.operands[1])
  local amplitudeY = Operands.varRef(ins.operands[2])
  local repeats = Operands.varRef(ins.operands[3])
  local period = Operands.varRef(ins.operands[4])
  if
    type(amplitudeX) ~= "number"
    or type(amplitudeY) ~= "number"
    or type(repeats) ~= "number"
    or type(period) ~= "number"
  then
    return {
      op = "unsupported",
      command = 561,
      arguments = {
        Operands.operandValue(ins.operands[1]),
        Operands.operandValue(ins.operands[2]),
        Operands.operandValue(ins.operands[3]),
        Operands.operandValue(ins.operands[4]),
      },
      sourceOffset = ins.offset,
      reason = "ScrCmd_561 variable shake operands are unsupported",
    }
  end
  return {
    op = "shake_camera",
    amplitudeX = amplitudeX,
    amplitudeY = amplitudeY,
    intervalTicks = period,
    count = repeats,
  }
end

function FieldServiceHandlers.followMonResetMovement(_)
  return { op = "follower_reset_movement" }
end

function FieldServiceHandlers.processSoundplate()
  return { op = "process_soundplate" }
end

function FieldServiceHandlers.overworldLeave(_)
  return { op = "overworld_leave" }
end

function FieldServiceHandlers.currentMapId(ins)
  return { op = "current_map_id", result = Operands.varRef(ins.operands[1]) }
end

function FieldServiceHandlers.playerState(ins)
  return { op = "player_state", result = Operands.varRef(ins.operands[1]) }
end

function FieldServiceHandlers.playerOnBikeCheck(ins)
  -- ScrCmd_PlayerOnBikeCheck result: the source comparison against the
  -- cycling avatar state becomes the semantic bike query writing 1 or 0
  -- in the same tick.
  return { op = "player_on_bike_check", result = Operands.varRef(ins.operands[1]) }
end

function FieldServiceHandlers.createCameraTarget(ins)
  -- ScrCmd_CreateCameraTarget x, y: the source pins its invisible focus
  -- object on the tile and fixes the camera on it. The focus object
  -- itself never moves, so the semantic operation carries the tile the
  -- camera holds; focus height resolves against the bound map at run time.
  return {
    op = "camera_focus_set",
    fieldX = Operands.varRef(ins.operands[1]),
    fieldZ = Operands.varRef(ins.operands[2]),
  }
end

function FieldServiceHandlers.removeCameraTarget(_)
  return { op = "camera_focus_clear" }
end

function FieldServiceHandlers.followerReleaseNextToPlayer(_)
  -- ScrCmd_FollowMonReleaseNextToPlayer carries no operands: with an
  -- active permitted follower it moves next to the player hidden until
  -- its first step, otherwise it is a same-tick no-op.
  return { op = "follower_release_next_to_player" }
end

function FieldServiceHandlers.timeOfDay(ins)
  return { op = "time_of_day", result = Operands.varRef(ins.operands[1]) }
end

function FieldServiceHandlers.weekday(ins)
  return { op = "weekday", result = Operands.varRef(ins.operands[1]) }
end

function FieldServiceHandlers.discardValue(ins)
  return { op = "discard_value", value = Operands.varRef(ins.operands[1]) }
end

function FieldServiceHandlers.trainerCardStars(ins)
  return { op = "trainer_card_stars", result = Operands.varRef(ins.operands[1]) }
end

function FieldServiceHandlers.propAnimationLoad(ins)
  local chunkX = Operands.operandValue(ins.operands[1])
  local chunkZ = Operands.operandValue(ins.operands[2])
  local localX = Operands.varRef(ins.operands[3])
  local localZ = Operands.varRef(ins.operands[4])
  assert(type(chunkX) == "number" and type(chunkZ) == "number", "prop animation chunks must be numeric")
  return {
    op = "prop_animation_load",
    fieldX = { value = "scaled_coordinate", coordinate = localX, chunkOffset = chunkX },
    fieldZ = { value = "scaled_coordinate", coordinate = localZ, chunkOffset = chunkZ },
    slot = Operands.operandValue(ins.operands[5]),
  }
end

function FieldServiceHandlers.propAnimationPlay(ins, direction)
  return { op = "prop_animation_play", slot = Operands.varRef(ins.operands[1]), direction = direction }
end

function FieldServiceHandlers.propAnimationPlayForward(ins)
  return FieldServiceHandlers.propAnimationPlay(ins, "forward")
end

function FieldServiceHandlers.propAnimationPlayReverse(ins)
  return FieldServiceHandlers.propAnimationPlay(ins, "reverse")
end

function FieldServiceHandlers.propAnimationWait(ins)
  return { op = "prop_animation_wait", slot = Operands.varRef(ins.operands[1]) }
end

function FieldServiceHandlers.propAnimationUnload(ins)
  return { op = "prop_animation_unload", slot = Operands.varRef(ins.operands[1]) }
end

function FieldServiceHandlers.pokemonCenterHeal(ins)
  return { op = "pokemon_center_heal", count = Operands.varRef(ins.operands[1]) }
end

function FieldServiceHandlers.martOpen(kind, selector)
  local step = { op = "mart_open", kind = kind }
  if selector ~= nil then
    step.selector = selector
  end
  return step
end

function FieldServiceHandlers.martSpecial(ins)
  return FieldServiceHandlers.martOpen("special", Operands.varRef(ins.operands[1]))
end

function FieldServiceHandlers.martDecoration(ins)
  return FieldServiceHandlers.martOpen("decoration", Operands.varRef(ins.operands[1]))
end

function FieldServiceHandlers.martSeal(ins)
  return FieldServiceHandlers.martOpen("seal", Operands.varRef(ins.operands[1]))
end

function FieldServiceHandlers.martAthlete()
  return FieldServiceHandlers.martOpen("athlete")
end

function FieldServiceHandlers.martDataCards()
  return FieldServiceHandlers.martOpen("data_cards")
end

function FieldServiceHandlers.martSell()
  return FieldServiceHandlers.martOpen("sell")
end

function FieldServiceHandlers.martBuy(ins)
  -- The source halfword is consumed but does not select stock.
  assert(ins.operands[1] ~= nil, "MartBuy consumes its source operand")
  return FieldServiceHandlers.martOpen("standard")
end

function FieldServiceHandlers.martAthleteAvailable(ins)
  return { op = "mart_query", kind = "athlete_available", result = Operands.varRef(ins.operands[1]) }
end

function FieldServiceHandlers.martCardPrefix(ins)
  return { op = "mart_query", kind = "card_prefix", result = Operands.varRef(ins.operands[1]) }
end

return FieldServiceHandlers
