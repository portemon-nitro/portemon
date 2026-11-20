-- NitroModelFixture: the synthetic nitro-backed proof model for the animation
-- runtime tests: a compiled transform program, dynamic batch records (the
-- serialized descriptor shape referencing .g4mesh geometry), and compiled
-- NSBCA-style clips. The shapes mirror what the digest side emits
-- (NsbmdTransformProgram + MapPropAnimCompiler); the fixture builds them by
-- hand so the runtime tests never need raw Nitro bytes.
--
-- The door model: one node, one SBC draw, one segment mesh (a 2x2-tile quad
-- at the origin in tile space), a compiled rotation clip for door.open and
-- one for door.close. Test-only.

local ModelDefinition = require("libs.hgss.src.presentation.ModelDefinition")

local NitroModelFixture = {}

local function identity9()
  return { 1, 0, 0, 0, 1, 0, 0, 0, 1 }
end

-- A compiled NSBCA-style rotation clip over 8 frames (pivot A = 1 - i/16,
-- B = i/16, like the real `door_op`; pivot 4 = rotation about Y). `swing`
-- true opens (angle 0 -> peak), false closes (peak -> 0).
local function rotationClip(id, name, semantic, swing)
  local rotData = {}
  for i = 0, 7 do
    local a, b = 4096 - i * 256, i * 256
    if not swing then
      a, b = b, a
    end
    rotData[i + 1] = { control = 0x0024, a = a, b = b }
  end
  local keys = {}
  for i = 0, 7 do
    keys[i + 1] = 0x8000 + i
  end
  return {
    id = id,
    name = name,
    category = "joint",
    kind = "trs",
    frameCount = 8,
    tracks = { { target = 0, targetIndex = 0 } },
    semanticNames = { semantic },
    source = { type = "nitro", format = "NSBCA", archive = "build_anim", memberId = 1 },
    compiled = {
      anmFlags = 0,
      rotData = rotData,
      pivotData = {},
      targets = {
        {
          nodeIndex = 0,
          channels = {
            trans = { x = { source = "model" }, y = { source = "model" }, z = { source = "model" } },
            rot = { source = "curve", rate = 1, limit = 8, storage = "fx16", keys = keys },
            scale = { x = { source = "model" }, y = { source = "model" }, z = { source = "model" } },
          },
        },
      },
    },
  }
end

function NitroModelFixture.doorOpenClip()
  return rotationClip("fixture:door.open", "DoorOpen", "door.open", true)
end

function NitroModelFixture.doorCloseClip()
  return rotationClip("fixture:door.close", "DoorClose", "door.close", false)
end

-- The source elevator model's two directional one-shot animations, loaded and
-- selected by direction (src/field/map_prop_anims.c::ElevatorAnimCreate).
function NitroModelFixture.elevatorUpClip()
  return rotationClip("fixture:elevator.up", "ElevatorUp", "elevator.up", true)
end

function NitroModelFixture.elevatorDownClip()
  return rotationClip("fixture:elevator.down", "ElevatorDown", "elevator.down", false)
end

-- A compiled one-node program whose single draw drives one segment mesh.
function NitroModelFixture.doorProgram()
  return {
    name = "door",
    scalingRule = 0,
    posScale = 1,
    invPosScale = 1,
    tileScale = 1 / 16,
    nodes = {
      {
        index = 0,
        matrixStackIndex = 0,
        translation = { x = 0, y = 0, z = 0 },
        rotation = identity9(),
        scale = { x = 1, y = 1, z = 1 },
        transZero = true,
        rotZero = true,
        scaleOne = true,
      },
    },
    commands = {
      { opcode = 0x06, nodeIndex = 0, parentIndex = 0, flags = 0 },
      { opcode = 0x02, nodeIndex = 0, visible = true },
      { opcode = 0x04, materialIndex = 0 },
      { opcode = 0x05, shapeIndex = 0 },
      { opcode = 0x01 },
    },
    evpMatrices = nil,
  }
end

-- The 2x2-tile quad in tile space (MeshWriter vertex shape).
function NitroModelFixture.doorQuad()
  return {
    vertices = {
      {
        x = 0,
        y = 0,
        z = 0,
        u = 0,
        v = 0,
        nx = 0,
        ny = 1,
        nz = 0,
        r = 255,
        g = 255,
        b = 255,
        a = 255,
        colorSource = 0,
      },
      {
        x = 2,
        y = 0,
        z = 0,
        u = 1,
        v = 0,
        nx = 0,
        ny = 1,
        nz = 0,
        r = 255,
        g = 255,
        b = 255,
        a = 255,
        colorSource = 0,
      },
      {
        x = 2,
        y = 2,
        z = 0,
        u = 1,
        v = 1,
        nx = 0,
        ny = 1,
        nz = 0,
        r = 255,
        g = 255,
        b = 255,
        a = 255,
        colorSource = 0,
      },
      {
        x = 0,
        y = 2,
        z = 0,
        u = 0,
        v = 1,
        nx = 0,
        ny = 1,
        nz = 0,
        r = 255,
        g = 255,
        b = 255,
        a = 255,
        colorSource = 0,
      },
    },
    indices = { 0, 1, 2, 0, 2, 3 },
  }
end

-- The per-mesh draw record (polygon state compiled per segment). The polygon
-- light mask is part of the compiled state: the strict draw path requires it
-- on every backend record (ModelInstance.DRAW_STATE_FIELDS).
function NitroModelFixture.drawState()
  return {
    drawIndex = 0,
    positionSource = "draw",
    transformMode = "static",
    cullMode = "back",
    polygonMode = "modulation",
    polygonId = 0,
    translucentDepthWrite = false,
    depthEqual = false,
    polygonAlpha = 31,
    lightMask = 5,
  }
end

-- The one-node, one-quad model shape both fixture models are built on.
local function modelOptions(key, animations)
  return {
    key = key,
    nodes = {
      {
        index = 0,
        name = "root",
        translation = { x = 0, y = 0, z = 0 },
        rotation = identity9(),
        scale = { x = 1, y = 1, z = 1 },
      },
    },
    meshes = {
      {
        id = "draw0.seg0",
        nodeIndex = 0,
        materialIndex = 0,
        geometry = "fixtures/draw0.seg0.g4mesh",
        center = { 1, 0, 1 },
      },
    },
    materials = {
      {
        id = 0,
        name = "wall",
        baseColor = { r = 255, g = 255, b = 255, a = 255 },
        alphaMode = "opaque",
        doubleSided = false,
        polygonAlpha = 31,
        texMtxMode = 0,
        texWidth = 0,
        texHeight = 0,
      },
    },
    animations = animations,
    backend = {
      program = NitroModelFixture.doorProgram(),
      meshes = {
        ["draw0.seg0"] = NitroModelFixture.drawState(),
      },
    },
  }
end

-- The door model definition: one node, one segment mesh, one opaque
-- material, and the door open/close clips. `clips` overrides the default
-- clip list (e.g. for close-only or banded fixtures). The mesh references
-- the .g4mesh path shape of the serialized descriptors -- geometry never
-- embeds a batch in a definition (the render tests build their meshes from
-- doorQuad() by mesh id).
function NitroModelFixture.doorDefinition(clips)
  clips = clips or { NitroModelFixture.doorOpenClip(), NitroModelFixture.doorCloseClip() }
  return ModelDefinition.new(modelOptions("fixture:nitro-door", clips))
end

-- The source elevator prop model under its generated placement identity:
-- "<indoor|outdoor>:<source member id>:<descriptor sha1 prefix>" as
-- BuildingModelCompiler emits it, with member 0xD0 (MAP_PROP_ELEVATOR in
-- src/field/map_prop_anims.c). The definition carries no member-id field;
-- production locates the prop through the placement identity, so the fixture
-- does not invent one. `memberId` relabels the same model under another source
-- member -- the ordinary building a map without an elevator carries.
function NitroModelFixture.elevatorDefinition(memberId)
  local key = string.format("indoor:%d:0a1b2c3d4e5f", memberId or 0xD0)
  return ModelDefinition.new(modelOptions(key, {
    NitroModelFixture.elevatorUpClip(),
    NitroModelFixture.elevatorDownClip(),
  }))
end

return NitroModelFixture
