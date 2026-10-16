-- Side-door (escalator) one-shot animation role: retail resolves the
-- Goldenrod Department Store escalators through the side-door transition
-- (pret/pokeheartgold src/field/door_transition.c
-- DoorTransition_WalkOutOfSideDoor / DoorTransition_WalkIntoSideDoor, tag
-- SIDE_DOOR_ANIM_TAG, SEQ_SE_DP_ESUKA). The prop is one of the interior
-- build models gSideDoorExitModels / gSideDoorEntryModels (asm/
-- door_transition_area_light_data.s): members 11, 12, 13, 14. The model id
-- selects the animation: MapPropOneShotAnimationManager_LoadPropAnimations
-- is called with animationCount 1, so one-shot index 0 loads anim-list slot
-- 0 of that model's record. Indoors the anim list is interior_build_anim_list
-- (HGSS a/1/0/8, selected by AreaDataManager_Alloc for buildModelKind 0):
-- members 11/12 reference build_anim (a/1/0/6) resource 62
-- (stair_pc_u01u), members 13/14 reference resource 63 (stair_pc_u01d);
-- members 168-171 repeat the same pairs. The records carry header
-- 01 03 00 00 00 00 01 01 (registration 1, policy 3 -- the
-- interaction/door-managed one-shot policy, never the ordinary ambient
-- registrar).
--
-- Portemon plays the prop with SceneProp:play("escalator") (FieldTransition
-- profile 2, the same owner FieldRuntime wires). The generated descriptors
-- already embed the stair_pc_u01* clips under their Nitro names, but with no
-- semantic role the lookup raises MAP_PROP_ANIM_UNKNOWN. The producer must
-- stamp the escalator role onto exactly these clips -- the door.open /
-- door.close precedent in MapPropAnimCompiler -- so the runtime address
-- resolves. Synthetic: fixture PAT bytes under the real Nitro names through
-- the real side-door header, then through the full MapAssetCompiler.
-- Member ids, resource ids, names, and header bytes above are verified ROM
-- facts, not payload.

local Assert = require("tests.support.Assert")
local BinaryWriter = require("libs.codec.src.BinaryWriter")
local AnimationFixture = require("tests.support.AnimationFixture")
local MapPropAnimCompiler = require("romdump.src.digest.model.MapPropAnimCompiler")
local MapAssetCompiler = require("romdump.src.digest.map.MapAssetCompiler")
local MapRomFixture = require("tests.support.MapRomFixture")
local ModelDefinition = require("libs.hgss.src.presentation.ModelDefinition")

local T = {}

-- The real side-door record header: 01 03 00 00 00 00 01 01. Bytes 4-7
-- stay on the wire for the real corpus layout; only the registrar bytes
-- select behavior (see BuildModelAnimList).
local function sideDoorRecord(ids)
  local bw = BinaryWriter.new()
  bw:u8(1) -- registration
  bw:u8(3) -- policy: interaction/door-managed one-shot, never ambient
  bw:u8(0) -- control
  bw:u8(0) -- areaGate
  bw:u8(0)
  bw:u8(0)
  bw:u8(1)
  bw:u8(1)
  for _, id in ipairs(ids) do
    bw:u32(id)
  end
  for _ = 1, 4 - #ids do
    bw:u32(0xFFFFFFFF)
  end
  assert(#bw:tostring() == 0x18)
  return bw:tostring()
end

local function resNarc(members)
  return {
    readMember = function(_, memberId)
      local bytes = assert(members[memberId], "no resource member " .. memberId)
      return bytes
    end,
  }
end

local function onlyModel(bundle)
  local found
  for _, model in pairs(bundle.models) do
    if model.memberId == MapRomFixture.BUILDING_MODEL_MEMBER_ID then
      assert(not found, "expected one authored building model")
      found = model
    end
  end
  return assert(found, "expected one building model")
end

function T.side_door_up_clip_carries_the_escalator_role()
  -- Interior members 11/12 (and 168/169) reference build_anim resource 62,
  -- stair_pc_u01u: the single one-shot the side-door exit/enter plays.
  local result = MapPropAnimCompiler.compile(sideDoorRecord({ 62 }), resNarc({
    [62] = AnimationFixture.patNamed("stair_pc_u01u"),
  }), {
    archiveAlias = "interior_build_anim_list",
    memberId = 11,
  })
  Assert.equal(#result.clips, 1)
  Assert.equal(result.clips[1].name, "stair_pc_u01u")
  Assert.deepEqual(result.clips[1].semanticNames, { "escalator" }, "the up one-shot is addressable as escalator")
  Assert.isNil(result.clips[1].ambientLoop, "a door-policy record never plays at load")
  Assert.isNil(result.clips[1].timeBand, "a door-policy record carries no time band")
  Assert.equal(result.clips[1].source.archive, "build_anim")
  Assert.equal(result.clips[1].source.memberId, 62)
  Assert.isNil(result.doorSoundType, "the escalator record selects no door sound")
end

function T.side_door_down_clip_carries_the_escalator_role()
  -- Interior members 13/14 (and 170/171) reference build_anim resource 63,
  -- stair_pc_u01d: the down-direction one-shot.
  local result = MapPropAnimCompiler.compile(sideDoorRecord({ 63 }), resNarc({
    [63] = AnimationFixture.patNamed("stair_pc_u01d"),
  }), {
    archiveAlias = "interior_build_anim_list",
    memberId = 13,
  })
  Assert.equal(#result.clips, 1)
  Assert.equal(result.clips[1].name, "stair_pc_u01d")
  Assert.deepEqual(result.clips[1].semanticNames, { "escalator" }, "the down one-shot is addressable as escalator")
  Assert.isNil(result.clips[1].ambientLoop, "a door-policy record never plays at load")
  Assert.isNil(result.clips[1].timeBand, "a door-policy record carries no time band")
  Assert.equal(result.clips[1].source.archive, "build_anim")
  Assert.equal(result.clips[1].source.memberId, 63)
  Assert.isNil(result.doorSoundType, "the escalator record selects no door sound")
end

function T.generated_side_door_model_addresses_its_clip_as_escalator()
  -- The full producer seam: a fixture indoor map whose building model's
  -- anim-list record is the real side-door shape must generate a
  -- nitro-dynamic descriptor whose clip the runtime lookup resolves --
  -- the exact address SceneProp:play("escalator") needs.
  local romFs = MapRomFixture.build({
    interiorBuildAnimList = {
      [MapRomFixture.BUILDING_MODEL_MEMBER_ID] = sideDoorRecord({ 62 }),
    },
    buildAnim = { [62] = AnimationFixture.patNamed("stair_pc_u01u") },
  })
  local bundle = assert(MapAssetCompiler.compile(romFs, MapRomFixture.MAP_SYMBOL))
  local model = onlyModel(bundle)
  Assert.equal(model.kind, "nitro-dynamic")
  Assert.equal(#model.animations, 1)
  Assert.deepEqual(model.animations[1].semanticNames, { "escalator" })
  local definition = ModelDefinition.fromNitroDescriptor(model, { key = model.key })
  local clip = definition:animation("escalator")
  Assert.notNil(clip, "the generated model resolves the escalator address")
  Assert.equal(clip.name, "stair_pc_u01u")
end

return { tests = T }
