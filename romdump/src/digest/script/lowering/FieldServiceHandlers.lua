-- Field service, lifecycle, query, prop-animation, and heal lowerings.
-- They live here so their names never become more file-scoped locals
-- in the main field-handler chunk.

local Errors = require("libs.errors.src.Errors")
local Operands = require("romdump.src.digest.script.lowering.Operands")

---@class FieldServiceHandlers
local FieldServiceHandlers = {}

-- Source flag-action commands (set 1, clear 0, check 2 into a result var).
function FieldServiceHandlers.flagAction(ins, flag)
  local mode = Operands.operandValue(ins.operands[1])
  if mode == 0 then
    return { op = "clear_flag", flag = flag }
  end
  if mode == 1 then
    return { op = "set_flag", flag = flag }
  end
  if mode == 2 then
    return {
      op = "set_var",
      variable = Operands.varRef(ins.operands[2]),
      value = { value = "flag_value", flag = flag },
    }
  end
  Errors.raise("SCRIPT_UNKNOWN_FLAG_ACTION", "unknown flag action mode", {
    sourceOffset = ins.offset,
    opcode = ins.opcode,
    mode = mode,
  })
end

function FieldServiceHandlers.strengthFlagAction(ins)
  return FieldServiceHandlers.flagAction(ins, "FLAG_STRENGTH_ACTIVE")
end

-- ScrCmd_CheckEscortMode reads FLAG_HAVE_FOLLOWER into its result variable.
function FieldServiceHandlers.checkEscortMode(ins)
  return {
    op = "set_var",
    variable = Operands.varRef(ins.operands[1]),
    value = { value = "flag_value", flag = "FLAG_HAVE_FOLLOWER" },
  }
end

local function unsupportedNode(ins, reason)
  local arguments = {}
  for index, operand in ipairs(ins.operands) do
    arguments[index] = Operands.operandValue(operand)
  end
  return {
    op = "unsupported",
    command = ins.opcode,
    arguments = arguments,
    sourceOffset = ins.offset,
    reason = reason,
  }
end

-- ScrCmd_PlayFieldMoveCutIn reads the party slot of the move user.
function FieldServiceHandlers.fieldMoveCutIn(ins)
  return { op = "field_move_cut_in", slot = Operands.varRef(ins.operands[1]) }
end

-- ScrCmd_StartFieldMoveEffect takes the effect kind (0..5) and the variable
-- the effect task completes. Scripts only poll that variable, so it must be
-- a variable operand.
function FieldServiceHandlers.fieldMoveEffect(ins)
  local effect = Operands.operandValue(ins.operands[1])
  local done = Operands.varRef(ins.operands[2])
  if type(effect) ~= "number" or effect < 0 or effect > 5 or type(done) ~= "table" then
    return unsupportedNode(ins, "ScrCmd_StartFieldMoveEffect needs a literal effect kind and a variable operand")
  end
  return { op = "field_move_effect", effect = effect, done = done }
end

-- ScrCmd_SwapPlayerAndFollowMonPositions mode 1 steps the player into the
-- follower's tile; mode 2 (follower first) has no corpus caller.
function FieldServiceHandlers.swapPlayerAndFollower(ins)
  if Operands.operandValue(ins.operands[1]) ~= 1 then
    return unsupportedNode(ins, "ScrCmd_SwapPlayerAndFollowMonPositions follower-first mode is unsupported")
  end
  return { op = "follower_swap_with_player" }
end

function FieldServiceHandlers.followerFlash(ins)
  return {
    op = "follower_gesture",
    gesture = "flash",
    a = Operands.operandValue(ins.operands[1]),
    b = Operands.operandValue(ins.operands[2]),
  }
end

function FieldServiceHandlers.followerGrowAndShrink(_)
  return { op = "follower_gesture", gesture = "grow_shrink" }
end

function FieldServiceHandlers.followerJumpOnSpot(ins)
  return { op = "follower_gesture", gesture = "jump", a = Operands.operandValue(ins.operands[1]) }
end

function FieldServiceHandlers.followerAddMood(ins)
  return { op = "follower_add_mood", amount = Operands.operandValue(ins.operands[1]) }
end

-- ScrCmd_FollowMonIsInactiveOrVisible: true without a follower, else the
-- follower's visible flag.
function FieldServiceHandlers.followerInactiveOrVisible(ins)
  return { op = "follower_inactive_or_visible", result = Operands.varRef(ins.operands[1]) }
end

-- ScrCmd_FirstAliveMonHasType: native type id against the first alive mon.
function FieldServiceHandlers.partyLeadHasType(ins)
  return {
    op = "party_lead_has_type",
    type = Operands.operandValue(ins.operands[1]),
    result = Operands.varRef(ins.operands[2]),
  }
end

-- ScrCmd_Capitalize upper-cases the first character of one message buffer.
function FieldServiceHandlers.bufferCapitalize(ins)
  return { op = "buffer_capitalize", slot = Operands.operandValue(ins.operands[1]) }
end

-- ScrCmd_RockSmashItemCheck: whether the follower used the move, then the
-- found flag and item result variables.
function FieldServiceHandlers.rockSmashItemCheck(ins)
  return {
    op = "rock_smash_item_check",
    followerUsing = Operands.varRef(ins.operands[1]),
    found = Operands.varRef(ins.operands[2]),
    item = Operands.varRef(ins.operands[3]),
  }
end

-- ScrCmd_TryHeadbuttEncounter: the result variable answers whether a battle
-- started.
function FieldServiceHandlers.tryHeadbuttEncounter(ins)
  return { op = "try_headbutt_encounter", result = Operands.varRef(ins.operands[1]) }
end

-- ScrCmd_FollowMonRecall: the follower returns to the player's tile hidden.
function FieldServiceHandlers.followerRecallToPlayer(_)
  return { op = "follower_recall_to_player" }
end

-- ScrCmd_FollowMonIsNextToPlayer: whether a visible follower stands on a
-- cardinally adjacent tile.
function FieldServiceHandlers.followerIsNextToPlayer(ins)
  return { op = "follower_is_next_to_player", result = Operands.varRef(ins.operands[1]) }
end

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
