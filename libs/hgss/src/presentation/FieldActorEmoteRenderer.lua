-- Presentation adapter for every overhead emote: the movement emotes
-- (currently exclamation only; other decoded emote kinds draw nothing until a
-- proven source model is compiled for them) and the follower reactions. Each
-- draw record whose activeEmoteKind names a compiled kind gets its icon at the
-- record's presented world position plus the shared source anchor and the
-- entrance bounce at the record's emote tick (FieldActorEmote). The draw
-- record is already presentation-ready, so no actor offset is applied here.
--
-- Static art draws its prepared batches; animated art is a ModelInstance
-- whose clip frame follows the emote tick, so drawing never advances it.
-- Source models mark their batches billboard (Nitro's BB opcode) with a
-- captured base transform, following the camera-independent billboard
-- placement of the static building path (ModelInstance:drawItems /
-- BillboardTransform), so the badge always faces the camera exactly like
-- the source's NNSi_G3dFuncSbc_BB effect.

local Matrix3 = require("libs.math.src.Matrix3")
local Matrix4 = require("libs.math.src.Matrix4")
local FixedPoint = require("libs.math.src.FixedPoint")
local AnimationPlayer = require("libs.hgss.src.presentation.AnimationPlayer")
local FieldActorEmote = require("libs.hgss.src.actors.FieldActorEmote")
local ModelDefinition = require("libs.hgss.src.presentation.ModelDefinition")
local ModelInstance = require("libs.hgss.src.presentation.ModelInstance")
local SceneDescriptor = require("libs.hgss.src.presentation.SceneDescriptor")
local BillboardTransform = require("libs.hgss.src.presentation.BillboardTransform")
local PoseContract = require("libs.assets.src.model.PoseContract")

local IDENTITY_MODEL_NORMAL = Matrix3.identity()
local EFFECT_TAG = "movement_emote"

---@class FieldActorEmoteRenderer
---@field prepared table<string, table<string, unknown>> emote kind -> prepared static or animated art
---@field pool table<string, unknown>
---@field instances table<string, { kind: string, instance: ModelInstance, player: table<string, unknown> }> actor id -> animated emote instance
local FieldActorEmoteRenderer = {}
FieldActorEmoteRenderer.__index = FieldActorEmoteRenderer

-- The presentation sprite layer projects billboards from their extents
-- around the model-space center (GxRenderer.projectSpriteBounds); pooled
-- meshes carry a min/max box.
local function spriteBounds(aabb)
  assert(aabb, "billboard emote mesh needs its bounds for the presentation sprite layer")
  return {
    width = aabb.maxX - aabb.minX,
    height = aabb.maxY - aabb.minY,
    depth = aabb.maxZ - aabb.minZ,
  }
end

local function materials(model, pool)
  local out = {}
  for _, record in ipairs(model.materials) do
    local wrap = SceneDescriptor.wrap(record)
    out[record.id] = {
      id = record.id,
      name = record.name,
      image = pool:imageFor(record.texture, wrap.x, wrap.y),
      texMatrix = { 1, 0, 0, 0, 1, 0, 0, 0, 1 },
      wrap = wrap,
    }
  end
  return out
end

local function prepareStatic(model, pool)
  assert(type(model.batches) == "table" and type(model.materials) == "table", "static emote art is incomplete")
  local materialById = materials(model, pool)
  local batches = {}
  for _, batch in ipairs(model.batches) do
    local mesh = pool:meshFor(batch.geometry)
    local isBillboard = batch.transformMode == PoseContract.BILLBOARD
    batches[#batches + 1] = {
      mesh = mesh.mesh,
      material = materialById[batch.material],
      center = mesh.center,
      bounds = isBillboard and spriteBounds(mesh.bounds) or nil,
      isBillboard = isBillboard,
      baseTransform = batch.baseTransform,
      alphaClass = batch.alphaClass,
      cullMode = batch.cullMode,
      polygonAlpha = batch.polygonAlpha / FixedPoint.RGB5_MAX,
      polygonMode = batch.polygonMode,
      polygonId = batch.polygonId,
      translucentDepthWrite = batch.translucentDepthWrite,
      depthEqual = batch.depthEqual,
      lightMask = batch.lightMask,
      fogEnabled = batch.fogEnabled,
    }
  end
  return { batches = batches }
end

local function prepareAnimated(kind, model, pool)
  local animations = model.animations
  assert(type(animations) == "table" and #animations == 1, "animated emote art requires one clip")
  local clip = animations[1]
  local definition = ModelDefinition.fromNitroDescriptor(model, { key = "field-emote:" .. kind })
  local renderMeshesById, boundsByRenderMesh = {}, {}
  for _, mesh in ipairs(definition.meshes) do
    local resource = pool:meshFor(mesh.geometry)
    renderMeshesById[mesh.id] = resource.mesh
    boundsByRenderMesh[resource.mesh] = spriteBounds(resource.bounds)
    mesh.center = resource.center
  end
  return {
    definition = definition,
    renderMeshesById = renderMeshesById,
    boundsByRenderMesh = boundsByRenderMesh,
    wraps = SceneDescriptor.wrapByMaterial(model.materials),
    clipName = clip.name,
    frameCount = clip.frameCount,
  }
end

---@param modelsByKind table<string, table<string, unknown>> emote kind -> static or nitro-dynamic model descriptor
---@param pool table<string, unknown> GpuAssetPool-shaped mesh/image pool
---@return FieldActorEmoteRenderer
function FieldActorEmoteRenderer.new(modelsByKind, pool)
  assert(type(modelsByKind) == "table", "field emote renderer requires its compiled models by kind")
  assert(pool and pool.meshFor and pool.imageFor and pool.build, "field emote renderer requires an asset pool")
  local prepared = pool:build(function()
    local out = {}
    for kind, model in pairs(modelsByKind) do
      assert(type(model) == "table", "field emote model for " .. tostring(kind) .. " is invalid")
      if model.kind == "static" then
        out[kind] = prepareStatic(model, pool)
      elseif model.kind == "nitro-dynamic" then
        out[kind] = prepareAnimated(kind, model, pool)
      else
        error("field emote model for " .. tostring(kind) .. " has unsupported kind " .. tostring(model.kind))
      end
    end
    return out
  end)
  return setmetatable({ prepared = prepared, pool = pool, instances = {} }, FieldActorEmoteRenderer)
end

local function drawStatic(prepared, anchorTransform, actorId, items)
  for _, batch in ipairs(prepared.batches) do
    local transform, modelNormal, billboardCenter, billboardScale
    if batch.isBillboard then
      transform = Matrix4.multiply(
        anchorTransform,
        assert(batch.baseTransform, "billboard batch needs a captured base transform")
      )
      billboardCenter, billboardScale = BillboardTransform.components(transform)
      modelNormal = IDENTITY_MODEL_NORMAL
    else
      transform = anchorTransform
      modelNormal = Matrix3.modelNormal(transform)
    end
    items[#items + 1] = {
      mesh = batch.mesh,
      material = batch.material,
      transform = transform,
      modelNormal = modelNormal,
      billboardCenter = billboardCenter,
      billboardScale = billboardScale,
      billboardProjection = batch.isBillboard,
      bounds = batch.bounds,
      center = batch.center,
      alphaClass = batch.alphaClass,
      cullMode = batch.cullMode,
      polygonAlpha = batch.polygonAlpha,
      polygonMode = batch.polygonMode,
      polygonId = batch.polygonId,
      translucentDepthWrite = batch.translucentDepthWrite,
      depthEqual = batch.depthEqual,
      lightMask = batch.lightMask,
      fogEnabled = batch.fogEnabled,
      worldSpace = true,
      fieldEffect = EFFECT_TAG,
      actorId = actorId,
    }
  end
end

local function animatedInstance(renderer, actorId, kind, prepared)
  local entry = renderer.instances[actorId]
  if entry == nil or entry.kind ~= kind then
    local pool = renderer.pool
    local function resolveImage(path, materialId)
      local wrap = assert(prepared.wraps[materialId], "missing field emote material wrap")
      return pool:imageFor(path, wrap.x, wrap.y)
    end
    local instance = ModelInstance.new(prepared.definition, { resolveImage = resolveImage })
    local handle = instance:play(prepared.clipName, { loopMode = "once" })
    entry = { kind = kind, instance = instance, player = handle.player }
    renderer.instances[actorId] = entry
  end
  return entry
end

local function drawAnimated(entry, prepared, tick, anchorTransform, actorId, items)
  entry.player.frameFx = FieldActorEmote.reactionFrame(tick, prepared.frameCount) * AnimationPlayer.FRAME_UNIT
  local instance = entry.instance
  instance.transform = anchorTransform
  instance:evaluatePose()
  for _, item in ipairs(instance:drawItems(prepared.renderMeshesById)) do
    local isBillboard = item.billboardCenter ~= nil
    item.billboardProjection = isBillboard
    item.bounds = isBillboard and assert(prepared.boundsByRenderMesh[item.mesh], "emote mesh bounds are missing") or nil
    item.worldSpace = true
    item.fieldEffect = EFFECT_TAG
    item.actorId = actorId
    items[#items + 1] = item
  end
end

-- records: FieldActorManager:drawRecords() output. Returns the draw items of
-- every record whose activeEmoteKind has compiled art. Animated items are
-- live per-actor views valid until the next call.
function FieldActorEmoteRenderer:drawItems(records)
  assert(type(records) == "table", "field emote renderer requires the actor draw records")
  local items = {}
  local drawn = {}
  for _, record in ipairs(records) do
    local kind = record.activeEmoteKind
    local prepared = kind and self.prepared[kind]
    if prepared and record.world then
      local tick = record.activeEmoteTick
      local anchor = FieldActorEmote.ANCHOR_OFFSET
      local anchorTransform = Matrix4.translate(
        record.world.x + anchor.x,
        record.world.y + anchor.y + FieldActorEmote.bounceOffsetY(tick),
        record.world.z + anchor.z
      )
      if prepared.batches then
        drawStatic(prepared, anchorTransform, record.actorId, items)
      else
        local entry = animatedInstance(self, record.actorId, kind, prepared)
        drawAnimated(entry, prepared, tick, anchorTransform, record.actorId, items)
        drawn[record.actorId] = true
      end
    end
  end
  for actorId in pairs(self.instances) do
    if not drawn[actorId] then
      self.instances[actorId] = nil
    end
  end
  return items
end

function FieldActorEmoteRenderer:dispose()
  self.prepared = nil
  self.instances = nil
end

return FieldActorEmoteRenderer
