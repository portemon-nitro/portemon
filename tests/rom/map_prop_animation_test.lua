-- Golden smoke: real HGSS field props still decode into dynamic model
-- descriptors with their compiled clips -- member/resource facts only.
-- New Bark's exterior places a door pair (wk_door3, member 26, NSBCA
-- door_op/door_cl) and a wind prop (member 28, NSBTA, 120 frames); Elm's
-- Lab 1F places a material-animated prop (member 29, NSBTA machine_l03).
-- The compiled clip shapes, cache memoization, and sampler behavior are
-- owned synthetically in romdump/tests (map_prop_anim_cache_test and the
-- clip-compiler suites), so a fixture change cannot ripple through this
-- file.

local Assert = require("tests.support.Assert")
local Hashing = require("romdump.src.digest.Hashing")
local MapAssetCompiler = require("romdump.src.digest.map.MapAssetCompiler")
local ModelDefinition = require("libs.hgss.src.presentation.ModelDefinition")
local ModelInstance = require("libs.hgss.src.presentation.ModelInstance")
local MapProps = require("libs.hgss.src.world.MapProps")
local CianwoodGym = require("libs.hgss.src.field.gymmick.CianwoodGym")

local T = {}

local function compileInto(romFs, symbol)
  return assert(MapAssetCompiler.compile(romFs, symbol))
end

-- Find the descriptor whose memberId matches, among the compiled models.
local function descriptorOf(bundle, memberId)
  for _, desc in pairs(bundle.models) do
    if desc.memberId == memberId then
      return desc
    end
  end
  return nil
end

local function clipOf(desc, name)
  ---@cast desc { animations: table[] }
  if desc.animations == nil then
    error("animation descriptor has no animations")
  end
  local animations = desc.animations
  for _, clip in ipairs(animations) do
    if clip.name == name then
      return clip
    end
  end
  return nil
end

-- The real members still decode: New Bark member 26 with the door pair
-- roles and resource facts, plus member facts for the wind (member 28)
-- and machine_l03 (member 29) census pins. The provenance sha1 of the
-- compiled door_op is the real build_anim member bytes.
function T.real_members_still_decode_with_their_clip_facts(romFs, _)
  local bundle = compileInto(romFs, "MAP_NEW_BARK")
  local door = descriptorOf(bundle, 26)
  assert(door, "wk_door3 descriptor present")
  Assert.equal(door.kind, "nitro-dynamic")
  local doorOp = clipOf(door, "door_op")
  local doorCl = clipOf(door, "door_cl")
  assert(doorOp and doorCl, "the door pair compiles")
  Assert.deepEqual(doorOp.semanticNames, { "door.open" })
  Assert.deepEqual(doorCl.semanticNames, { "door.close" })
  Assert.equal(doorOp.frameCount, 8)
  Assert.equal(doorOp.source.format, "NSBCA")
  Assert.equal(doorOp.source.archive, "build_anim")
  Assert.equal(doorOp.source.memberId, 1)

  -- Provenance: the clip's sha1 is the real build_anim member bytes.
  local animResNarc = assert(romFs:openNarc("build_anim"))
  Assert.equal(
    doorOp.source.sha1,
    Hashing.sha1hex(assert(animResNarc:readMember(doorOp.source.memberId))),
    "door_op provenance sha1 is the real resource bytes"
  )

  -- The wind prop is a 120-frame NSBTA ambient loop.
  local wind = clipOf(descriptorOf(bundle, 28), "wind")
  assert(wind, "the wind clip is present")
  Assert.equal(wind.source.format, "NSBTA")
  Assert.equal(wind.frameCount, 120)

  -- machine_l03 is a 61-frame NSBTA material clip.
  local lab = compileInto(romFs, "MAP_NEW_BARK_ELMS_LAB_1F")
  local machine = clipOf(descriptorOf(lab, 29), "machine_l03")
  assert(machine, "the machine_l03 clip is present")
  Assert.equal(machine.source.format, "NSBTA")
  Assert.equal(machine.frameCount, 61)
end

-- Cianwood's real target definitions own exact copies of source 174's four
-- record slots, and 175 identifies only record 0. Exercise the actual binding
-- and one-shot completion contracts over the generated ROM assets.
function T.cianwood_bound_clips_play_and_settle_on_the_real_target_models(romFs, _)
  local bundle = compileInto(romFs, "MAP_CIANWOOD_GYM")
  local water = ModelInstance.new(ModelDefinition.fromNitroDescriptor(assert(descriptorOf(bundle, 173))))
  local winch = ModelInstance.new(ModelDefinition.fromNitroDescriptor(assert(descriptorOf(bundle, 175))))
  local props = MapProps.new({
    placements = {
      { placementIndex = 0, modelKey = "indoor:173:test" },
      { placementIndex = 1, modelKey = "indoor:175:test" },
    },
    instances = { [0] = water, [1] = winch },
    doorTiles = {},
  })
  CianwoodGym.restoreSettled({ mapProps = props })
  local waterProp = assert(props:prop(0))
  local winchProp = assert(props:prop(1))
  local function ids(instance)
    local out = {}
    for _, category in ipairs({ "joint", "material" }) do
      for _, handle in ipairs(instance.animationState:attachments(category)) do
        out[#out + 1] = handle.clip.id
      end
    end
    table.sort(out)
    return out
  end
  local boundIds = ids(water)
  Assert.deepEqual(boundIds, {
    "cianwood.water.1.build_anim-146",
    "cianwood.water.2.build_anim-147",
    "cianwood.water.3.build_anim-148",
    "cianwood.water.4.build_anim-149",
  }, "173 owns exactly source 174's four record slots")
  Assert.deepEqual(ids(winch), { "cianwood.winch.0.build_anim-150" }, "175 restores only record 0")
  for _, category in ipairs({ "joint", "material" }) do
    for _, handle in ipairs(water.animationState:attachments(category)) do
      Assert.isTrue(handle.player:isComplete(), "reload settles the real bound clip at its terminal")
    end
  end

  waterProp:stopAll()
  local plays = {}
  for _, id in ipairs(boundIds) do
    plays[#plays + 1] = waterProp:play(id, { loopMode = "once" })
  end
  Assert.isFalse(waterProp:arePlaysFinished(plays), "the real one-shot starts incomplete")
  for _ = 1, 119 do
    water:updateFixed()
  end
  Assert.isFalse(waterProp:arePlaysFinished(plays), "the checked terminal has not been reached")
  water:updateFixed()
  Assert.isTrue(waterProp:arePlaysFinished(plays), "all four real channels complete at frame 120")
end

return require("tests.rom.support.RomSuite").fromFacts(T)
