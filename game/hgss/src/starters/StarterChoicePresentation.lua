-- Game-local retail starter-application presentation. It realizes one
-- trusted published starter-application manifest through the shared model stack
-- (ModelDefinition/ModelInstance over a GpuAssetPool, drawn through
-- FieldRenderer under the manifest's outside/inside camera poses), the
-- cleared info surface, the three candidate portraits borrowed from the
-- mon portrait atlas, and the shared HGSS window primitive for the framed
-- message surfaces. Two logical 256x192 surfaces share one host drawable:
-- the machine surface carries the 3D machine/balls plus the bottom prompt,
-- and the info surface carries the semantic message plus the inspected
-- portrait companion. Pointer input resolves in the machine surface only.
-- Owned exclusively by StarterChoiceState, which is its only caller: this
-- helper never decides the choice, publishes mons, mutates saves, or polls
-- input. Graphics resources are prepared after the chooser opens and
-- realized in bounded steps per host update; the first visible draw sees
-- a fully realized scene. The presentation borrows the field graphics
-- backend through its own renderer wrapper and the field-owned window
-- primitive through its draw arguments, and releases its owned resources
-- exactly once on dispose.

local LogicalSurface = require("libs.ui.src.LogicalSurface")
local StarterChoicePreparation = require("game.hgss.src.starters.StarterChoicePreparation")
local StarterChoiceAssetCache = require("libs.assets.src.StarterChoiceAssetCache")
local FieldDialogueTheme = require("libs.hgss.src.ui.FieldDialogueTheme")
local FieldRenderer = require("libs.hgss.src.presentation.FieldRenderer")
local Matrix4 = require("libs.math.src.Matrix4")
local NativeDisplay = require("libs.ui.src.NativeDisplay")
local Rgb555 = require("libs.codec.src.Rgb555")

---@class StarterChoicePresentation
---@field _manifest table<string, unknown> immutable trusted starter-application manifest
---@field _cacheFs CacheFs generated-asset filesystem the model/texture bytes read through
---@field _portraits table[] per-candidate portrait descriptors ({ selector }) borrowed from state
---@field _frameIndex integer player-owned text-frame choice for the framed info message
---@field _machineTarget table<string, unknown>? owned source-sized machine raster once first drawn
---@field _renderer FieldRenderer? field renderer wrapper once preparation finishes
---@field _ready boolean preparation completed and the scene is drawable
---@field _disposed boolean
---@field _backend table<string, unknown>? borrowed field graphics backend for the wrapper
---@field _preparation StarterChoicePreparation? owned resource acquisition child
---@field _resources table<string, unknown>? borrowed ready resources from the child
---@field _staticDraws table[] realized tabletop draw items, built once at readiness and reused by every draw
---@field _clipNames { turntable: string, ballEffect: string, ballRock: string[], ballOpen: string } instance play names resolved from bindings
---@field _sceneRuntime table<string, unknown> minimal renderer scene state (edge colors, fog, flat lighting)
---@field _entryTransition string? transition of the last semantic clock sync
---@field _cameraKey string? last snapshot key the camera matrices were built for
---@field _cameraView number[]? cached view matrix for the camera key
---@field _cameraProjection number[]? cached projection matrix for the camera key
---@field _rotateSign number rotation direction sign while rotating
---@field _rotationAccum number turntable degrees accumulated in the active rotation
---@field _cameraStep integer camera interpolation steps taken in the active zoom path
---@field _arcStep integer selected ball arc steps taken in the active zoom path
---@field _lockCameraStep integer camera-out steps taken in the active lock exit
---@field _rockFrame integer selected ball rock frames advanced since inspect entry
---@field _rockSelection integer? selection the rock frame belongs to, nil while rock is inactive
---@field _infoFade integer info-surface white fade ticks in the active lock exit
---@field _machineFade integer machine-surface white fade ticks after the info fade
---@field _renderSamples table[]? immutable pre/mid/post source-boundary render samples
---@field _openFrame integer selected ball-open frames advanced in the active lock exit
---@field _effectFrame integer ball-effect frames advanced in the active lock exit
---@field _rockPlayingFor integer? selection the realized rock clip plays for, nil when unrealized/inactive
---@field _exitPlaying boolean the realized open/effect clips play for the active lock exit
local StarterChoicePresentation = {}
StarterChoicePresentation.__index = StarterChoicePresentation

local BALL_ROLES = { "ball1", "ball2", "ball3" }

-- Confirm state widens the inspected ball's hit region; the spacing-derived
-- base radius still comes from the projected scene.
local CONFIRM_RADIUS_SCALE = 1.5
-- White emissive register paint: the modal scene carries no field light
-- profile, so every material emits its texture (or its base color) flat
-- instead of resolving field lighting it was never given.
local EMISSIVE_WHITE = Rgb555.encode(31, 31, 31)

-- Submitted-but-unconsumed preparation tokens the chooser holds at once.
-- The worker answers faster than the main thread uploads, so an unbounded
-- window would retain an entire chooser's decoded payloads waiting for
-- one-frame-at-a-time upload; two keeps the worker fed while bounding
-- retained work.
-- Source message-printer policy for the chooser's typed copy: the window
-- opens on the reset tick, then one glyph per following source tick, with
-- no button acceleration. The field dialogue controller owns the same
-- interGlyphDelay/glyphBudget concepts; the chooser keeps its own local
-- copy because its messages are prepared glyph lines rather than laid out
-- dialogue pages, and input gates on completion instead of fast-forward.
local SOURCE_PRINTER = { interGlyphDelay = 1, glyphBudget = 1 }

---@param value unknown
---@return boolean
local function isFiniteNumber(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

-- Full homogeneous clip transform: Matrix4.transformPoint assumes an affine
-- matrix, while projection needs the w row for the perspective divide.
---@param matrix number[]
---@param x number
---@param y number
---@param z number
---@return number, number, number, number
local function clipPoint(matrix, x, y, z)
  return matrix[1] * x + matrix[5] * y + matrix[9] * z + matrix[13],
    matrix[2] * x + matrix[6] * y + matrix[10] * z + matrix[14],
    matrix[3] * x + matrix[7] * y + matrix[11] * z + matrix[15],
    matrix[4] * x + matrix[8] * y + matrix[12] * z + matrix[16]
end

-- Source machine BG1/BG2 prompt layers are enabled only in settled inspect and
-- confirm states.
---@param snapshot StarterChoiceController.Snapshot
---@return boolean
local function machinePromptVisible(snapshot)
  return snapshot.transition == "idle"
    and (snapshot.selectionState == "inspect" or snapshot.selectionState == "confirm")
end

---@param snapshot StarterChoiceController.Snapshot
---@return boolean
local function portraitVisible(snapshot)
  return snapshot.selectionState ~= "null" and snapshot.transition ~= "backOut"
end

-- Single-pane portrait origin on the 256x192 logical pane. The generated
-- info-surface portrait keeps the source two-screen placement; the compact
-- pane centers the same 80x80 quad near the top instead.
local ADAPTED_PORTRAIT = { x = 88, y = 16, width = 80, height = 80 }

---@class StarterChoicePresentation.Options
---@field manifest table<string, unknown> trusted published starter-application manifest
---@field cacheFs CacheFs generated-asset filesystem
---@field portraits table[] per-candidate portrait descriptors ({ selector: string, pageId: integer })
---@field frameIndex integer player-owned text-frame choice for the framed info message

---@param opts StarterChoicePresentation.Options
---@return StarterChoicePresentation
function StarterChoicePresentation.new(opts)
  assert(type(opts) == "table", "starter presentation requires its composition")
  assert(type(opts.manifest) == "table", "starter presentation requires the application manifest")
  assert(
    opts.cacheFs ~= nil and type(opts.cacheFs.read) == "function",
    "starter presentation requires the asset filesystem"
  )
  -- The manifest is a trusted published artifact: the schema identity is
  -- sufficient here, and the producer pipeline plus explicit audit own the
  -- full contract.
  assert(
    type(opts.manifest) == "table" and opts.manifest.schema == StarterChoiceAssetCache.SCHEMA,
    "starter presentation requires the current application manifest"
  )
  assert(
    type(opts.portraits) == "table" and #opts.portraits == 3,
    "starter presentation requires three portrait descriptors"
  )
  for index, descriptor in ipairs(opts.portraits) do
    assert(
      type(descriptor) == "table" and type(descriptor.selector) == "string",
      "starter portrait descriptor " .. index .. " carries its atlas selector"
    )
    assert(
      type(descriptor.pageId) == "number" and descriptor.pageId % 1 == 0 and descriptor.pageId >= 0,
      "starter portrait descriptor " .. index .. " carries its page"
    )
  end
  assert(
    type(opts.frameIndex) == "number" and opts.frameIndex % 1 == 0 and opts.frameIndex >= 0,
    "starter presentation requires the player-owned frame index"
  )
  local self = setmetatable({
    _manifest = opts.manifest,
    _cacheFs = opts.cacheFs,
    _portraits = opts.portraits,
    _frameIndex = opts.frameIndex,
    _machineTarget = nil,
    _renderer = nil,
    _ready = false,
    _disposed = false,
    _backend = nil,
    _preparation = nil,
    _resources = nil,
    _staticDraws = {},
    _clipNames = { turntable = "", ballEffect = "", ballRock = {}, ballOpen = "" },
    _sceneRuntime = {},
    _entryTransition = nil,
    _cameraKey = nil,
    _cameraView = nil,
    _cameraProjection = nil,
    _rotateSign = 0,
    _rotationAccum = 0,
    _cameraStep = 0,
    _arcStep = 0,
    _lockCameraStep = 0,
    _rockFrame = 0,
    _rockSelection = nil,
    _infoFade = 0,
    _machineFade = 0,
    _renderSamples = nil,
    _openFrame = 0,
    _effectFrame = 0,
    _rockPlayingFor = nil,
    _exitPlaying = false,
    _printerMessage = nil,
    _printerTyped = false,
    _printerRevealed = 0,
    _printerDelay = 0,
  }, StarterChoicePresentation)
  return self
end

-- Clears every semantic playback clock for a fresh open. Instances are
-- per-presentation, so a reset presentation starts with the camera outside,
-- no clip playing, and no fade covering either surface.
function StarterChoicePresentation:reset()
  self._entryTransition = nil
  self._cameraKey = nil
  self._cameraView = nil
  self._cameraProjection = nil
  self._rotateSign = 0
  self._rotationAccum = 0
  self._cameraStep = 0
  self._arcStep = 0
  self._lockCameraStep = 0
  self._rockFrame = 0
  self._rockSelection = nil
  self._infoFade = 0
  self._machineFade = 0
  self._renderSamples = nil
  self._openFrame = 0
  self._effectFrame = 0
  self._rockPlayingFor = nil
  self._exitPlaying = false
  self._printerMessage = nil
  self._printerTyped = false
  self._printerRevealed = 0
  self._printerDelay = 0
end

-- Copies only the controller identity and visual clocks needed by drawing.
-- Samples deliberately own no controller result table or presentation state.
---@param snapshot StarterChoiceController.Snapshot
---@return table<string, unknown>
local function renderSample(self, snapshot)
  return {
    snapshot = {
      selection = snapshot.selection,
      selectionState = snapshot.selectionState,
      transition = snapshot.transition,
      direction = snapshot.direction,
      done = snapshot.done,
    },
    rotationAccum = self._rotationAccum,
    rotateSign = self._rotateSign,
    cameraStep = self._cameraStep,
    arcStep = self._arcStep,
    lockCameraStep = self._lockCameraStep,
    infoFade = self._infoFade,
    machineFade = self._machineFade,
  }
end

-- Starts a field tick's render history after detecting transition entry so
-- its pre-step sample has the same clocks the first source update observes.
---@param snapshot StarterChoiceController.Snapshot
function StarterChoicePresentation:beginRenderTick(snapshot)
  assert(type(snapshot) == "table", "starter render sampling requires the controller snapshot")
  self:_detectEntry(snapshot)
  self._renderSamples = { renderSample(self, snapshot) }
end

-- Publishes a source boundary after the controller consumes that source
-- step's completion observation.
---@param snapshot StarterChoiceController.Snapshot
function StarterChoicePresentation:captureRenderSample(snapshot)
  assert(type(snapshot) == "table", "starter render sampling requires the controller snapshot")
  local samples = self._renderSamples
  assert(samples ~= nil and #samples < 3, "starter render tick captures exactly three source samples")
  samples[#samples + 1] = renderSample(self, snapshot)
end

---@param snapshot StarterChoiceController.Snapshot
function StarterChoicePresentation:finishRenderTick(snapshot)
  local samples = assert(self._renderSamples, "starter render tick must be started")
  while #samples < 3 do
    self:captureRenderSample(snapshot)
  end
  assert(#samples == 3, "starter render tick captures exactly three source samples")
end

---@param left table<string, unknown>
---@param right table<string, unknown>
---@return boolean
local function compatibleRenderSamples(left, right)
  local a = assert(left.snapshot)
  local b = assert(right.snapshot)
  return a.selection == b.selection
    and a.selectionState == b.selectionState
    and a.transition == b.transition
    and a.direction == b.direction
    and a.done == b.done
    and left.rotateSign == right.rotateSign
end

---@param left table<string, unknown>
---@param right table<string, unknown>
---@param alpha number
---@return table<string, unknown>
local function interpolateRenderSamples(left, right, alpha)
  if not compatibleRenderSamples(left, right) then
    return alpha < 1 and left or right
  end
  local sample = { snapshot = left.snapshot, rotateSign = left.rotateSign }
  for _, clock in ipairs({ "rotationAccum", "cameraStep", "arcStep", "lockCameraStep", "infoFade", "machineFade" }) do
    sample[clock] = left[clock] + (right[clock] - left[clock]) * alpha
  end
  return sample
end

-- Selects one source half-frame from the immutable pre/mid/post history.
-- Input can change the settled snapshot before another fixed tick; in that
-- case draw uses a live-clock fallback for the new semantic state.
---@param snapshot StarterChoiceController.Snapshot
---@param alpha number
---@return table<string, unknown> sampled snapshot and clocks
function StarterChoicePresentation:_sampleForDraw(snapshot, alpha)
  assert(isFiniteNumber(alpha), "starter render alpha must be finite")
  alpha = math.max(0, math.min(1, alpha))
  local samples = self._renderSamples
  if samples == nil or #samples ~= 3 then
    return renderSample(self, snapshot)
  end
  local current = renderSample(self, snapshot)
  if not compatibleRenderSamples(samples[3], current) then
    return current
  end
  local left, right, localAlpha
  if alpha <= 0.5 then
    left, right, localAlpha = samples[1], samples[2], alpha * 2
  else
    left, right, localAlpha = samples[2], samples[3], (alpha - 0.5) * 2
  end
  return interpolateRenderSamples(left, right, localAlpha)
end

-- Interpolated camera pose for the current semantic clocks: the zoom path
-- dollies from the outside pose to the inside pose over the source camera
-- steps, reversal returns over the same steps, confirmation holds inside,
-- and the locking exit dollies back out over its own camera-out steps.
---@param snapshot StarterChoiceController.Snapshot
---@param sample table<string, unknown>?
---@return number 0..1
function StarterChoicePresentation:_cameraAlpha(snapshot, sample)
  local cameraTicks = self._manifest.scene.timing.cameraTicks
  local cameraStep = sample and sample.cameraStep or self._cameraStep
  local lockCameraStep = sample and sample.lockCameraStep or self._lockCameraStep
  if snapshot.transition == "zoomIn" then
    return math.min(1, cameraStep / cameraTicks)
  end
  if snapshot.transition == "waitZoom" then
    return 1
  end
  if snapshot.transition == "backOut" then
    return 1 - math.min(1, cameraStep / cameraTicks)
  end
  if snapshot.transition == "lockExit" or snapshot.transition == "done" then
    return 1 - math.min(1, lockCameraStep / cameraTicks)
  end
  if snapshot.selectionState == "confirm" then
    return 1
  end
  return 0
end

-- Selected ball X-arc for the current semantic clocks: in over the source
-- ball-arc steps with the camera, held inside through confirmation and the
-- lock exit, and back out with reversal.
---@param snapshot StarterChoiceController.Snapshot
---@param sample table<string, unknown>?
---@return number 0..1
function StarterChoicePresentation:_arcAlpha(snapshot, sample)
  local ballArcTicks = self._manifest.scene.timing.ballArcTicks
  local arcStep = sample and sample.arcStep or self._arcStep
  if snapshot.transition == "zoomIn" then
    return math.min(1, arcStep / ballArcTicks)
  end
  if snapshot.transition == "waitZoom" then
    return 1
  end
  if snapshot.transition == "backOut" then
    return 1 - math.min(1, arcStep / ballArcTicks)
  end
  if snapshot.selectionState == "confirm" then
    return 1
  end
  if snapshot.transition == "lockExit" or snapshot.transition == "done" then
    return 1
  end
  return 0
end

---@param out table<string, unknown> manifest camera pose
---@param inside table<string, unknown> manifest camera pose
---@param alpha number 0..1
---@return table<string, unknown> interpolated pose
local function interpolatePose(out, inside, alpha)
  local pose = {
    angleX = out.angleX + (inside.angleX - out.angleX) * alpha,
    perspective = out.perspective + (inside.perspective - out.perspective) * alpha,
    distance = out.distance + (inside.distance - out.distance) * alpha,
    target = {
      x = out.target.x + (inside.target.x - out.target.x) * alpha,
      y = out.target.y + (inside.target.y - out.target.y) * alpha,
      z = out.target.z + (inside.target.z - out.target.z) * alpha,
    },
  }
  return pose
end

-- View/projection matrices for a controller snapshot from the manifest's
-- camera poses: pitch around the look-at target at the posed distance with
-- the posed vertical field of view over the DS aspect. Pure in the snapshot
-- and memoized by it, so hit-region scans share one build per snapshot.
---@param snapshot StarterChoiceController.Snapshot
---@param sample table<string, unknown>?
---@return number[] view, number[] projection
function StarterChoicePresentation:cameraMatrices(snapshot, sample)
  if sample ~= nil then
    local camera = self._manifest.scene.camera
    local pose = interpolatePose(camera.out, camera.inside, self:_cameraAlpha(snapshot, sample))
    local pitch = math.rad(pose.angleX)
    local target = pose.target
    local eye = {
      target.x,
      target.y + math.sin(-pitch) * pose.distance,
      target.z + math.cos(pitch) * pose.distance,
    }
    local reference = self._manifest.reference
    return Matrix4.lookAt(eye, { target.x, target.y, target.z }, { 0, 1, 0 }),
      Matrix4.perspective(math.rad(pose.perspective), reference.width / reference.height, camera.near, camera.far)
  end
  local key = snapshot.transition
    .. "|"
    .. snapshot.selectionState
    .. "|"
    .. tostring(snapshot.selection)
    .. "|"
    .. tostring(self._cameraStep)
    .. "|"
    .. tostring(self._lockCameraStep)
    .. "|"
    .. tostring(snapshot.direction)
  if key ~= self._cameraKey then
    local camera = self._manifest.scene.camera
    local pose = interpolatePose(camera.out, camera.inside, self:_cameraAlpha(snapshot))
    local pitch = math.rad(pose.angleX)
    local target = pose.target
    local eye = {
      target.x,
      target.y + math.sin(-pitch) * pose.distance,
      target.z + math.cos(pitch) * pose.distance,
    }
    local reference = self._manifest.reference
    self._cameraView = Matrix4.lookAt(eye, { target.x, target.y, target.z }, { 0, 1, 0 })
    self._cameraProjection =
      Matrix4.perspective(math.rad(pose.perspective), reference.width / reference.height, camera.near, camera.far)
    self._cameraKey = key
  end
  return assert(self._cameraView, "starter camera has no view matrix"),
    assert(self._cameraProjection, "starter camera has no projection matrix")
end

-- Ring slot origins in turntable-local space: the source radius around Y at
-- the source model height, one slot angle per ball starting from the
-- selected ball, which always rests at the front of the ring. Rotation
-- reassigns the slots from the new selection while the platform yaw carries
-- the visual travel between assignments.
---@param snapshot StarterChoiceController.Snapshot controller snapshot carrying the selection
---@return table[] { x, y, z } per ball, 1-based in ball order
function StarterChoicePresentation:modelOrigins(snapshot)
  local layout = self._manifest.scene.ballLayout
  local origins = {}
  for ball = 1, 3 do
    local relative = (ball - 1 - snapshot.selection) % 3
    local angle = math.rad(layout.slotAnglesDegrees[relative + 1])
    origins[ball] = { x = layout.radius * math.sin(angle), y = layout.modelY, z = layout.radius * math.cos(angle) }
  end
  return origins
end

-- Touch centers in turntable-local space: the same rotated X/Z point as the
-- model origins, held above them by the source touch offset. Model and touch
-- centers are never interchangeable.
---@param snapshot StarterChoiceController.Snapshot controller snapshot carrying the selection
---@return table[] { x, y, z } per ball, 1-based in ball order
function StarterChoicePresentation:touchOrigins(snapshot)
  local layout = self._manifest.scene.ballLayout
  local origins = {}
  for ball = 1, 3 do
    local relative = (ball - 1 - snapshot.selection) % 3
    local angle = math.rad(layout.slotAnglesDegrees[relative + 1])
    origins[ball] = {
      x = layout.radius * math.sin(angle),
      y = layout.modelY + layout.touchYOffsetY,
      z = layout.radius * math.cos(angle),
    }
  end
  return origins
end

-- Projects turntable-local origins through the platform yaw and the
-- snapshot camera into the DS reference frame.
---@param origins table[]
---@param snapshot StarterChoiceController.Snapshot
---@return table[] { x, y } per ball, 1-based in ball order
function StarterChoicePresentation:projectOrigins(origins, snapshot)
  local yaw = self:yawForSnapshot(snapshot)
  local view, projection = self:cameraMatrices(snapshot)
  local combined = Matrix4.multiply(projection, Matrix4.multiply(view, Matrix4.rotateY(yaw)))
  local reference = self._manifest.reference
  local centers = {}
  for index, position in ipairs(origins) do
    local cx, cy, _, cw = clipPoint(combined, position.x, position.y, position.z)
    if cw ~= nil and cw > 0 and isFiniteNumber(cx / cw) and isFiniteNumber(cy / cw) then
      centers[index] = {
        x = (cx / cw * 0.5 + 0.5) * reference.width,
        y = (0.5 - cy / cw * 0.5) * reference.height,
      }
    else
      centers[index] = nil
    end
  end
  return centers
end

-- Projected model origins in the DS reference frame under the snapshot's
-- camera and platform rotation. Pure camera math over the manifest's ring
-- layout, shared by drawing alignment.
---@param snapshot StarterChoiceController.Snapshot
---@return table[] { x, y } per ball, 1-based in ball order
function StarterChoicePresentation:ballCenters(snapshot)
  return self:projectOrigins(self:modelOrigins(snapshot), snapshot)
end

-- Hit region radii from the projected scene: half the nearest-neighbor ball
-- spacing, widened for the inspected ball while confirming.
---@param centers table[]
---@param snapshot StarterChoiceController.Snapshot
---@return table[] radii per ball
local function ballRadii(centers, snapshot)
  local spacing = math.huge
  for first = 1, #centers do
    for second = first + 1, #centers do
      local a, b = centers[first], centers[second]
      if a ~= nil and b ~= nil then
        local distance = math.sqrt((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y))
        if distance < spacing then
          spacing = distance
        end
      end
    end
  end
  if spacing == math.huge or spacing <= 0 then
    return {}
  end
  local radii = {}
  for index = 1, #centers do
    radii[index] = spacing * 0.45
    if snapshot.selectionState == "confirm" and index == snapshot.selection + 1 then
      radii[index] = radii[index] * CONFIRM_RADIUS_SCALE
    end
  end
  return radii
end

-- Reference-frame pointer position onto the rendered balls: 1|2|3 for the
-- nearest ball whose region covers the point, nil outside every region.
-- Points outside the 256x192 reference frame never hit. Hit testing
-- projects the separate touch centers held above the model origins.
---@param x number
---@param y number
---@param snapshot StarterChoiceController.Snapshot
---@return integer?
function StarterChoicePresentation:ballAt(x, y, snapshot)
  assert(type(x) == "number" and type(y) == "number", "starter pointer position must be numeric")
  assert(type(snapshot) == "table", "starter hit testing requires the controller snapshot")
  local reference = self._manifest.reference
  if x < 0 or x >= reference.width or y < 0 or y >= reference.height then
    return nil
  end
  local centers = self:projectOrigins(self:touchOrigins(snapshot), snapshot)
  local radii = ballRadii(centers, snapshot)
  local best, bestDistance = nil, nil
  for index, center in ipairs(centers) do
    local radius = radii[index]
    if center ~= nil and radius ~= nil then
      local distance = math.sqrt((x - center.x) * (x - center.x) + (y - center.y) * (y - center.y))
      if distance <= radius and (bestDistance == nil or distance < bestDistance) then
        best, bestDistance = index, distance
      end
    end
  end
  return best
end

-- Whether the presentation scene is fully prepared and drawable.
---@return boolean
function StarterChoicePresentation:isReady()
  return self._ready
end

-- Advances bounded resource acquisition through the per-scene owner, then
-- installs its borrowed ready view before the presentation-specific setup.
---@param context StarterChoicePrepContext
---@param maxWorkUnits integer?
---@return integer completed units
function StarterChoicePresentation:advancePreparation(context, maxWorkUnits)
  assert(not self._disposed, "starter presentation is disposed")
  if self._ready then
    return 0
  end
  assert(type(context) == "table", "starter preparation requires its composition")
  self._backend = assert(context.gxRenderer, "starter preparation requires the field graphics backend")
  if self._preparation == nil then
    self._preparation = StarterChoicePreparation.new(self._manifest, self._cacheFs, self._portraits)
  end
  local ok, completed = pcall(self._preparation.advance, self._preparation, context, maxWorkUnits)
  if not ok then
    self:_releaseGpu()
    error(completed, 0)
  end
  if self._preparation:isReady() then
    self._resources = self._preparation:resources()
    local finishOk, finishError = pcall(self._finishPreparation, self)
    if not finishOk then
      self:_releaseGpu()
      error(finishError, 0)
    end
  end
  return completed
end

local function clipNameFor(role, descriptor, binding)
  assert(type(descriptor.animations) == "table", "starter model " .. role .. " owns no clips")
  for _, clip in ipairs(descriptor.animations) do
    if clip.id == binding or clip.name == binding then
      assert(type(clip.name) == "string", "starter model " .. role .. " clip carries no name")
      return clip.name
    end
  end
  error("starter animation binding " .. tostring(binding) .. " resolves to no clip on " .. role, 0)
end

-- Completes rendering-specific state after the child has published all
-- acquired resources. No cache or queue work occurs after this boundary.
function StarterChoicePresentation:_finishPreparation()
  self:_buildStaticDraws()
  local fogTable = {}
  for index = 1, 32 do
    fogTable[index] = 0
  end
  self._sceneRuntime = {
    lighting = {
      diffuseRgb555 = 0,
      ambientRgb555 = 0,
      specularRgb555 = 0,
      emissionRgb555 = EMISSIVE_WHITE,
      lights = {},
    },
    edgeColors = { [0] = 0, 0, 0, 0, 0, 0, 0, 0 },
    fog = { enabled = false, color = 0, offset = 0, slope = 0, alpha = 0, table = fogTable },
  }
  local clear = self._manifest.surfaces.machine.clearColor
  self._renderer = FieldRenderer.new({
    gxRenderer = assert(self._backend, "starter preparation owns no field graphics backend"),
    clearColor = { clear.r, clear.g, clear.b, clear.a },
  })
  local animations = self._manifest.animations
  local models = self._manifest.models
  self._clipNames = {
    turntable = clipNameFor("turntable", models.turntable, animations.turntable),
    ballEffect = clipNameFor("ballEffect", models.ballEffect, animations.ballEffect),
    ballRock = {
      clipNameFor("ball1", models.ball1, animations.ballRock[1]),
      clipNameFor("ball2", models.ball2, animations.ballRock[2]),
      clipNameFor("ball3", models.ball3, animations.ballRock[3]),
    },
    ballOpen = clipNameFor("ball1", models.ball1, animations.ballOpen),
  }
  local turntable =
    assert(self._resources.instances.turntable, "starter presentation is missing the turntable instance")
  turntable:play(self._clipNames.turntable, { loopMode = "loop" })
  self._ready = true
end

---@param instance { stop: fun(self: unknown, clip: string): integer }
---@param presentation StarterChoicePresentation
local function stopBallClips(instance, presentation)
  instance:stop(presentation._clipNames.ballOpen)
  for _, binding in ipairs(presentation._clipNames.ballRock) do
    instance:stop(binding)
  end
end

-- Whether the selected ball rocks under a snapshot: throughout inspection
-- (idle, rotating, zooming, waiting) and while confirmation idles. Reversal,
-- the lock exit, and the uninspected chooser park every ball at baseline.
---@param snapshot StarterChoiceController.Snapshot
---@return boolean
local function rockActive(snapshot)
  if snapshot.selectionState == "inspect" then
    return snapshot.transition ~= "backOut" and snapshot.transition ~= "lockExit" and snapshot.transition ~= "done"
  end
  return snapshot.selectionState == "confirm" and snapshot.transition == "idle"
end

---@param attachment table<string, unknown>|nil live clip attachment
---@param frames integer semantic frames to catch up
local function fastForward(attachment, frames)
  local player = attachment ~= nil and attachment.player or nil
  if player == nil or type(frames) ~= "number" or frames <= 0 then
    return
  end
  for _ = 1, frames do
    if player.completed then
      return
    end
    player:updateFixed()
  end
end

-- Starts the clips a snapshot needs on the realized instances, exactly once
-- per entry, without touching any semantic clock. Late realization
-- fast-forwards each new player to the current semantic frame so headless
-- progress and realized playback agree without replaying entry effects.
---@param snapshot StarterChoiceController.Snapshot
function StarterChoicePresentation:_syncRealized(snapshot)
  if not self._ready then
    return
  end
  if self._resources.instances.ball1 == nil then
    return
  end
  if rockActive(snapshot) then
    if self._rockPlayingFor ~= snapshot.selection then
      local selected = snapshot.selection + 1
      for index, role in ipairs(BALL_ROLES) do
        local instance = self._resources.instances[role]
        if instance ~= nil then
          stopBallClips(instance, self)
          if index == selected then
            fastForward(instance:play(self._clipNames.ballRock[index], { loopMode = "loop" }), self._rockFrame)
          end
        end
      end
      local effect = self._resources.instances.ballEffect
      if effect ~= nil then
        effect:stop(self._clipNames.ballEffect)
      end
      self._rockPlayingFor = snapshot.selection
      self._exitPlaying = false
    end
    return
  end
  if snapshot.transition == "lockExit" or snapshot.transition == "done" then
    if not self._exitPlaying then
      local selected = snapshot.selection + 1
      for index, role in ipairs(BALL_ROLES) do
        local instance = self._resources.instances[role]
        if instance ~= nil then
          stopBallClips(instance, self)
          if index == selected then
            fastForward(instance:play(self._clipNames.ballOpen, { loopMode = "once" }), self._openFrame)
          end
        end
      end
      local effect = self._resources.instances.ballEffect
      if effect ~= nil then
        effect:stop(self._clipNames.ballEffect)
        fastForward(effect:play(self._clipNames.ballEffect, { loopMode = "once" }), self._effectFrame)
      end
      self._exitPlaying = true
      self._rockPlayingFor = nil
    end
    return
  end
  if self._rockPlayingFor ~= nil or self._exitPlaying then
    for _, role in ipairs(BALL_ROLES) do
      local instance = self._resources.instances[role]
      if instance ~= nil then
        stopBallClips(instance, self)
      end
    end
    local effect = self._resources.instances.ballEffect
    if effect ~= nil then
      effect:stop(self._clipNames.ballEffect)
    end
    self._rockPlayingFor = nil
    self._exitPlaying = false
  end
end

-- Resets the clocks a newly entered transition owns. Selection and
-- interaction-state changes inside one transition are left to the advance
-- step, which restarts the rock frame when the inspected ball changes.
---@param snapshot StarterChoiceController.Snapshot
function StarterChoicePresentation:_detectEntry(snapshot)
  if snapshot.transition == self._entryTransition then
    return
  end
  if snapshot.transition == "rotate" then
    self._rotationAccum = 0
    self._rotateSign = snapshot.direction == "left" and -1 or 1
  elseif snapshot.transition == "zoomIn" then
    self._cameraStep = 0
    self._arcStep = 0
  elseif snapshot.transition == "backOut" then
    self._cameraStep = 0
    self._arcStep = 0
  elseif snapshot.transition == "lockExit" then
    self._lockCameraStep = 0
    self._infoFade = 0
    self._machineFade = 0
    self._openFrame = 0
    self._effectFrame = 0
  end
  if self._entryTransition == "rotate" and snapshot.transition ~= "rotate" then
    self._rotationAccum = 0
  end
  self._entryTransition = snapshot.transition
  self._cameraKey = nil
end

-- Advances every semantic clock one deterministic source tick for the
-- snapshot that opened the tick. Rotation accumulates its source degrees,
-- the zoom paths step their independent camera/arc clocks, the selected
-- rock frame runs whenever the ball visibly rocks, and the lock exit steps
-- ball-open/effect, the camera-out path, and the sequential surface fades.
---@param snapshot StarterChoiceController.Snapshot
function StarterChoicePresentation:_advance(snapshot)
  local timing = self._manifest.scene.timing
  local turntable = self._manifest.scene.turntable
  local transition = snapshot.transition
  if transition == "rotate" then
    self._rotationAccum =
      math.min(turntable.selectionStepDegrees, self._rotationAccum + turntable.rotationDegreesPerTick)
  elseif transition == "zoomIn" then
    self._cameraStep = math.min(timing.cameraTicks, self._cameraStep + 1)
    self._arcStep = math.min(timing.ballArcTicks, self._arcStep + 1)
  elseif transition == "backOut" then
    self._cameraStep = math.min(timing.cameraTicks, self._cameraStep + 1)
    self._arcStep = math.min(timing.ballArcTicks, self._arcStep + 1)
  elseif transition == "lockExit" then
    self._lockCameraStep = math.min(timing.cameraTicks, self._lockCameraStep + 1)
    self._openFrame = self._openFrame + 1
    self._effectFrame = self._effectFrame + 1
    if self._infoFade < timing.infoFadeTicks then
      self._infoFade = self._infoFade + 1
    else
      self._machineFade = math.min(timing.machineFadeTicks, self._machineFade + 1)
    end
  end
  if rockActive(snapshot) then
    if self._rockSelection ~= snapshot.selection then
      self._rockFrame = 0
      self._rockSelection = snapshot.selection
    end
    self._rockFrame = self._rockFrame + 1
  else
    self._rockFrame = 0
    self._rockSelection = nil
  end
end

-- Completion observation for the snapshot that opened the tick, from the
-- clocks the advance step just settled. Fields the controller's current
-- transition does not read are still populated; an all-false observation
-- never completes any transition.
---@param snapshot StarterChoiceController.Snapshot
---@return StarterChoiceController.Observation observation
function StarterChoicePresentation:_observation(snapshot)
  local timing = self._manifest.scene.timing
  local turntable = self._manifest.scene.turntable
  local inZoomPath = snapshot.transition == "zoomIn" or snapshot.transition == "backOut"
  return {
    rotationComplete = snapshot.transition == "rotate" and self._rotationAccum >= turntable.selectionStepDegrees - 1e-9,
    cameraComplete = inZoomPath and self._cameraStep >= timing.cameraTicks,
    ballArcComplete = inZoomPath and self._arcStep >= timing.ballArcTicks,
    smallWobbleReady = self._rockFrame >= timing.smallWobbleFrame,
    infoFadeComplete = self._infoFade >= timing.infoFadeTicks,
    machineFadeComplete = self._machineFade >= timing.machineFadeTicks,
  }
end

-- Displayed platform yaw: the accumulated source rotation while the
-- turntable travels, settled to zero otherwise. Slots are
-- selection-relative, so the settled yaw is always zero: rotation exits snap
-- back together with the slot reassignment, and the yaw purely carries the
-- visual travel between assignments. Pure in the semantic clocks, shared by
-- drawing and hit testing; it never advances a clock.
---@param snapshot StarterChoiceController.Snapshot
---@param sample table<string, unknown>?
---@return number radians
function StarterChoicePresentation:yawForSnapshot(snapshot, sample)
  if snapshot.transition == "rotate" then
    return (sample and sample.rotateSign or self._rotateSign)
      * math.rad(sample and sample.rotationAccum or self._rotationAccum)
  end
  return 0
end

-- Advances every semantic clock one deterministic tick for the snapshot that
-- opened the tick, synchronizes realized model/fade objects to those clocks,
-- and returns the completion observation for the controller. A safe,
-- deterministic progression before GPU realization so headless compositions
-- settle transitions without graphics; realized clips catch up to the same
-- clocks without replaying entry effects.
---@param snapshot StarterChoiceController.Snapshot
---@return StarterChoiceController.Observation observation
function StarterChoicePresentation:update(snapshot)
  assert(type(snapshot) == "table", "starter presentation update requires the controller snapshot")
  self:_detectEntry(snapshot)
  self:_advance(snapshot)
  self:_advancePrinter(snapshot)
  if self._ready then
    for _, role in ipairs({ "turntable", "ballEffect", "ball1", "ball2", "ball3" }) do
      local instance = self._resources.instances[role]
      if instance ~= nil then
        instance:updateFixed()
      end
    end
  end
  self:_syncRealized(snapshot)
  return self:_observation(snapshot)
end

-- Arcs a turntable-local point around the X axis by the inspect arc about
-- the selected inspect pivot. The source names this path after Y, but the
-- implementation arcs the selected translation around X pivoted at the
-- inspect height and records the same angle as the ball X rotation.
---@param point table<string, unknown> { x, y, z }
---@param pivot table<string, unknown> { x, y, z }
---@param arc number radians
---@return table<string, unknown> { x, y, z }
local function arcPoint(point, pivot, arc)
  local cosine, sine = math.cos(arc), math.sin(arc)
  local y, z = point.y - pivot.y, point.z - pivot.z
  return { x = point.x, y = y * cosine - z * sine + pivot.y, z = y * sine + z * cosine + pivot.z }
end

-- Realizes the tabletop batches into stable draw items once. Nothing in a
-- static item depends on selection or animation: the placement is the
-- identity, the normal is the identity, and mesh/material/center state is
-- fixed when preparation completes. Draws reference these records directly
-- instead of rebuilding them every frame.
function StarterChoicePresentation:_buildStaticDraws()
  local draws = {}
  for _, batch in ipairs(self._resources.staticBatches) do
    draws[#draws + 1] = {
      mesh = batch.mesh,
      material = batch.material,
      transform = Matrix4.identity(),
      modelNormal = Matrix4.identity(),
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
    }
  end
  self._staticDraws = draws
end

---@param snapshot StarterChoiceController.Snapshot
---@param sample table<string, unknown>?
---@return number[] items in source role order
function StarterChoicePresentation:_drawItems(snapshot, sample)
  local items = {}
  for _, item in ipairs(self._staticDraws) do
    items[#items + 1] = item
  end
  local layout = self._manifest.scene.ballLayout
  local arc = math.rad(layout.inspectArcDegrees * self:_arcAlpha(snapshot, sample))
  local selected = snapshot.selection + 1
  -- The balls ride the rotating platform: the platform yaw carries every
  -- slot origin, each ball keeps its slot Y orientation, and the inspected
  -- ball adds its own X-axis arc about the inspect pivot on top. Touch
  -- centers keep the interaction offset and never participate here.
  local platform = Matrix4.rotateY(self:yawForSnapshot(snapshot, sample))
  local origins = self:modelOrigins(snapshot)
  local touches = self:touchOrigins(snapshot)
  local pivots = {}
  for ball = 1, 3 do
    local touch = touches[ball]
    pivots[ball] = { x = touch.x, y = layout.modelY + layout.inspectPivotYOffsetY, z = touch.z }
  end
  local dynamicRoles = { "turntable", "ballEffect", "ball1", "ball2", "ball3" }
  for _, role in ipairs(dynamicRoles) do
    local instance = assert(self._resources.instances[role], "starter presentation is missing " .. role)
    if role == "turntable" then
      instance.transform = platform
    elseif role == "ballEffect" then
      local position = arcPoint(origins[selected], pivots[selected], arc)
      instance.transform = Matrix4.multiply(platform, Matrix4.translate(position.x, position.y, position.z))
    else
      local ballIndex = (role == "ball1" and 1) or (role == "ball2" and 2) or 3
      local relative = (ballIndex - 1 - snapshot.selection) % 3
      local slotYaw = Matrix4.rotateY(math.rad(layout.slotAnglesDegrees[relative + 1]))
      local position = origins[ballIndex]
      if ballIndex == selected then
        local arced = arcPoint(position, pivots[ballIndex], arc)
        instance.transform = Matrix4.multiply(
          platform,
          Matrix4.multiply(
            Matrix4.translate(arced.x, arced.y, arced.z),
            Matrix4.multiply(Matrix4.rotateX(arc), slotYaw)
          )
        )
      else
        instance.transform =
          Matrix4.multiply(platform, Matrix4.multiply(Matrix4.translate(position.x, position.y, position.z), slotYaw))
      end
    end
    instance:evaluatePose()
  end
  -- Source role order: tabletop, turntable, effect, then the three balls.
  -- The effect only draws while the lock plays it.
  local ordered = { "turntable", "ball1", "ball2", "ball3" }
  for _, role in ipairs(ordered) do
    local instance = self._resources.instances[role]
    for _, item in
      ipairs(instance:drawItems(assert(self._resources.renderMeshes[role], "starter meshes missing for " .. role)))
    do
      items[#items + 1] = item
    end
  end
  if snapshot.transition == "lockExit" or snapshot.transition == "done" then
    local effect = self._resources.instances.ballEffect
    for _, item in
      ipairs(effect:drawItems(assert(self._resources.renderMeshes.ballEffect, "starter effect meshes are missing")))
    do
      items[#items + 1] = item
    end
  end
  return items
end

-- Visible glyph prefix of prepared lines: the first `revealed` glyph
-- tokens in line order, with non-glyph control tokens carried through.
-- Later lines stay empty until earlier lines complete, so drawn lines
-- keep their source origins.
---@param lines table<integer, table<integer, table<string, unknown>>> prepared glyph lines
---@param revealed integer glyphs visible so far
---@return table<integer, table<integer, table<string, unknown>>>
local function visibleLinePrefix(lines, revealed)
  local out = {}
  local remaining = revealed
  for _, line in ipairs(lines) do
    local kept = {}
    for _, token in ipairs(line) do
      if type(token) == "table" and token.kind ~= "glyph" then
        kept[#kept + 1] = token
      elseif remaining > 0 then
        kept[#kept + 1] = token
        remaining = remaining - 1
      end
    end
    out[#out + 1] = kept
  end
  return out
end

-- Draws one source message at canonical coordinates under the caller's
-- logical scope. A framed region fills the window with the generated
-- chooser info background and the player-owned frame around the source
-- box; an unframed region draws text only, leaving the scene behind it
-- untouched. Every prepared line draws through the generated chooser
-- color variants on the given background. Prepared lines start exactly
-- at the source text origin: the retail text printer starts at the
-- window-local origin, never with an inset.
---@param region table<string, unknown> source message region ({ box, textOrigin, framed })
---@param message table<string, unknown> prepared message record ({ lines })
---@param text table<string, unknown> text provider ({ drawLineWithColorVariants })
---@param background table<string, unknown> glyph background role for these lines
---@param windowRenderer table<string, unknown> field-borrowed window primitive for the framed message
function StarterChoicePresentation:_drawMessageLines(region, message, text, background, windowRenderer)
  if region.framed then
    local textColors = assert(self._manifest.textColors, "starter presentation requires the generated chooser colors")
    local info = textColors.infoBackground
    assert(windowRenderer ~= nil, "starter message drawing borrows the field window renderer")
    assert(type(windowRenderer.drawWindow) == "function", "starter message drawing borrows the field window renderer")
    windowRenderer:drawWindow(region.box, self._frameIndex, { info.r / 255, info.g / 255, info.b / 255, 1 })
  end
  local textColors = assert(self._manifest.textColors, "starter presentation requires the generated chooser colors")
  local lines = assert(message.lines, "starter message carries its prepared lines")
  local drawLines = lines
  if message == self._printerMessage and self._printerTyped then
    drawLines = visibleLinePrefix(lines, self._printerRevealed)
  end
  for index, line in ipairs(drawLines) do
    text:drawLineWithColorVariants(
      line,
      region.textOrigin.x,
      region.textOrigin.y + (index - 1) * FieldDialogueTheme.lineHeight,
      textColors.variants,
      background
    )
  end
end

-- The transparent glyph background for unframed machine text: the glyph
-- background-class pixels reveal the scene artwork behind the text, so
-- the background role keeps its source RGB with zero alpha. The copy
-- never mutates the manifest color tables.
---@param background table<string, unknown> source RGB role
---@return table<string, unknown> the same RGB with zero alpha
local function transparentBackground(background)
  return { r = background.r, g = background.g, b = background.b, a = 0 }
end

-- Draws the generated info-surface artwork at the canonical origin under
-- the caller's logical scope: the base layer opaque, then the overlay
-- layer at exactly the source blend coefficient. Any color state the
-- overlay changes is restored so the sibling surface and diagnostics
-- never observe it.
function StarterChoicePresentation:_drawInfoArtwork()
  local graphics = assert(love and love.graphics, "starter presentation requires the graphics namespace")
  graphics.setColor(1, 1, 1, 1)
  local baseLease = self._resources.infoBaseLease
  if baseLease ~= nil then
    baseLease:draw(graphics, 0, 0)
  else
    graphics.draw(assert(self._resources.infoBaseImage, "starter presentation owns no info base layer"), 0, 0)
  end
  local red, green, blue, alpha = graphics.getColor()
  graphics.setColor(1, 1, 1, self._manifest.backgrounds.info.overlayAlpha)
  local overlayLease = self._resources.infoOverlayLease
  if overlayLease ~= nil then
    overlayLease:draw(graphics, 0, 0)
  else
    graphics.draw(assert(self._resources.infoOverlayImage, "starter presentation owns no info overlay layer"), 0, 0)
  end
  graphics.setColor(red, green, blue, alpha)
end

-- The native info pane is cleared between source phases where both retail
-- info background layers are disabled.
function StarterChoicePresentation:_drawInfoBackdrop()
  local graphics = assert(love and love.graphics, "starter presentation requires the graphics namespace")
  graphics.setColor(0, 0, 0, 1)
  graphics.rectangle("fill", 0, 0, NativeDisplay.WIDTH, NativeDisplay.HEIGHT)
end

-- Draws the sequential source white fade over the caller's full canonical
-- surface from its fade clock. Either overlay is absent while its clock
-- has not started. A read-only cover: it never advances a clock.
---@param alpha number 0..1 white coverage
function StarterChoicePresentation:_drawFade(alpha)
  if alpha <= 0 then
    return
  end
  if alpha > 1 then
    alpha = 1
  end
  local graphics = assert(love and love.graphics, "starter presentation requires the graphics namespace")
  graphics.setColor(1, 1, 1, alpha)
  graphics.rectangle("fill", 0, 0, NativeDisplay.WIDTH, NativeDisplay.HEIGHT)
end

-- The selected semantic info message and bottom prompt for one
-- snapshot, chosen exactly as the retail flow does: confirmation shows
-- the confirmed candidate, inspection the inspected one, otherwise the
-- initial top message with the normal prompt.
---@param snapshot StarterChoiceController.Snapshot controller snapshot
---@return table<string, unknown> infoText, table<string, unknown> promptText
local function infoMessageFor(self, snapshot)
  local messages = self._manifest.messages
  if snapshot.selectionState == "confirm" then
    return messages.confirm[snapshot.selection + 1], messages.bottom.confirm
  end
  if snapshot.selectionState == "inspect" then
    return messages.inspect[snapshot.selection + 1], messages.bottom.normal
  end
  return messages.topInitial, messages.bottom.normal
end

-- Total glyphs in a prepared message, counting only glyph tokens the same
-- way the field dialogue printer does.
---@param message table<string, unknown> prepared message record ({ lines })
---@return integer
local function messageGlyphTotal(message)
  local total = 0
  for _, line in ipairs(assert(message.lines, "starter message carries its prepared lines")) do
    for _, token in ipairs(line) do
      if type(token) ~= "table" or token.kind == "glyph" then
        total = total + 1
      end
    end
  end
  return total
end

-- Whether the snapshot's info copy types out: the opening and confirmation
-- messages reveal at source speed 1 while inspected detail stays instant.
---@param snapshot StarterChoiceController.Snapshot
---@return boolean
local function messageIsTyped(snapshot)
  return snapshot.selectionState ~= "inspect"
end

-- Advances the source printer one deterministic tick for the snapshot that
-- opened the tick. The printer resets only when the semantic message
-- identity changes; drawing reads the revealed prefix without advancing it.
---@param snapshot StarterChoiceController.Snapshot
function StarterChoicePresentation:_advancePrinter(snapshot)
  local info = infoMessageFor(self, snapshot)
  local typed = messageIsTyped(snapshot)
  if info ~= self._printerMessage or typed ~= self._printerTyped then
    self._printerMessage = info
    self._printerTyped = typed
    self._printerRevealed = 0
    self._printerDelay = SOURCE_PRINTER.interGlyphDelay
  end
  if not typed then
    self._printerRevealed = messageGlyphTotal(assert(info, "starter printer tracks its info copy"))
    return
  end
  if self._printerDelay > 0 then
    self._printerDelay = self._printerDelay - 1
    return
  end
  self._printerRevealed = math.min(
    messageGlyphTotal(assert(info, "starter printer tracks its info copy")),
    self._printerRevealed + SOURCE_PRINTER.glyphBudget
  )
  self._printerDelay = SOURCE_PRINTER.interGlyphDelay
end

-- Whether chooser input is eligible: the source printer has completed the
-- snapshot's info copy. Instant messages are always eligible; a typed
-- message the printer has not observed yet is not.
---@param snapshot StarterChoiceController.Snapshot?
---@return boolean
function StarterChoicePresentation:inputReady(snapshot)
  local message, typed
  if snapshot ~= nil then
    assert(type(snapshot) == "table", "starter printer readiness reads the controller snapshot")
    message = infoMessageFor(self, snapshot)
    typed = messageIsTyped(snapshot)
  else
    message, typed = self._printerMessage, self._printerTyped
  end
  if message == nil or not typed then
    return true
  end
  if message ~= self._printerMessage then
    return false
  end
  return self._printerRevealed >= messageGlyphTotal(message)
end

-- The owned source-sized machine raster, realized once on first draw and
-- released with every other owned resource. Drawn at canonical target
-- coordinates with nearest sampling, never host-scaled.
---@return table<string, unknown> the owned 256x192 raster target
function StarterChoicePresentation:_ensureMachineTarget()
  local target = self._machineTarget
  if target == nil then
    local graphics = assert(love and love.graphics, "starter presentation requires the graphics namespace")
    target = assert(
      graphics.newCanvas(NativeDisplay.WIDTH, NativeDisplay.HEIGHT, { dpiscale = 1 }),
      "starter presentation owns no machine raster target"
    )
    target:setFilter("nearest", "nearest")
    self._machineTarget = target
  end
  return target
end

-- Renders the 3D machine under the interpolated camera into the owned
-- source-sized raster: an identity target transform with the canonical
-- (0,0,256,192) viewport, so neither the camera nor any 2D transform
-- compensates for presentation cropping. The caller composites the
-- raster once through the resolved machine placement.
---@param snapshot StarterChoiceController.Snapshot controller snapshot
---@param sample table<string, unknown>?
function StarterChoicePresentation:_renderMachineTarget(snapshot, sample)
  local graphics = assert(love and love.graphics, "starter presentation requires the graphics namespace")
  local target = self:_ensureMachineTarget()
  local viewMatrix, projection = self:cameraMatrices(snapshot, sample)
  ---@return number[]
  local function cameraView()
    return viewMatrix
  end
  ---@return number[]
  local function cameraProjection()
    return projection
  end
  ---@return number[]
  local function cameraBillboardProjection()
    return projection
  end
  local camera = {
    far = self._manifest.scene.camera.far,
    zoom = 1,
    view = cameraView,
    projection = cameraProjection,
    billboardProjection = cameraBillboardProjection,
  }
  local previous = graphics.getCanvas()
  graphics.push("all")
  local ok, err = pcall(function()
    graphics.origin()
    graphics.setCanvas(target)
    graphics.setScissor()
    assert(self._renderer, "starter presentation has no renderer"):draw(
      self._sceneRuntime,
      camera,
      { self:_drawItems(snapshot, sample) },
      nil,
      {
        worldViewport = { x = 0, y = 0, width = NativeDisplay.WIDTH, height = NativeDisplay.HEIGHT },
        referenceFrame = { x = 0, y = 0, width = NativeDisplay.WIDTH, height = NativeDisplay.HEIGHT },
      },
      1
    )
    graphics.setCanvas(previous)
  end)
  graphics.pop()
  if not ok then
    error(err, 0)
  end
end

-- Draws the inspected portrait companion at the caller's origin under the
-- caller's logical scope.
---@param snapshot StarterChoiceController.Snapshot controller snapshot
---@param rect table<string, integer> draw origin and documented portrait size
function StarterChoicePresentation:_drawInfoPortrait(snapshot, rect)
  local framed = assert(
    self._resources.portraitQuads[snapshot.selection + 1],
    "starter presentation owns no portrait for the inspected candidate"
  )
  assert(type(rect) == "table", "starter portrait drawing requires its origin")
  assert(type(rect.x) == "number" and type(rect.y) == "number", "starter portrait drawing requires its origin")
  local graphics = assert(love and love.graphics, "starter presentation requires the graphics namespace")
  graphics.setColor(1, 1, 1, 1)
  if framed.lease ~= nil then
    framed.lease:drawQuad(graphics, framed.quad, rect.x, rect.y)
  else
    graphics.draw(framed.image, framed.quad, rect.x, rect.y)
  end
end

-- Draws every published outer application frame through the already-owned
-- window primitive with the player-owned frame choice, after content.
-- The body sits fully inside the exterior frame room, so the border
-- never hides body pixels. Every published frame keeps the border-only
-- draw. Unframed plans draw nothing extra and never touch the primitive.
---@param graphics table<string, unknown> host graphics namespace
---@param plan ApplicationPlan the resolved plan
---@param windowRenderer table<string, unknown>? field-borrowed window primitive; required when the plan carries frames
function StarterChoicePresentation:_drawOuterFrames(graphics, plan, windowRenderer)
  local frames = assert(plan and plan.frames, "starter outer-frame drawing requires the resolved plan frames")
  if #frames == 0 then
    return
  end
  assert(
    windowRenderer ~= nil and type(windowRenderer.drawApplicationFrame) == "function",
    "starter outer-frame drawing borrows the field window renderer"
  )
  for _, frame in ipairs(frames) do
    LogicalSurface.draw(graphics, assert(frame.placement, "the starter outer frame carries its placement"), function()
      local contentBox = assert(frame.contentBox, "the starter outer frame carries its content box")
      windowRenderer:drawApplicationFrame(contentBox, self._frameIndex)
    end)
  end
end

---@param plan ApplicationPlan the resolved native plan
---@param id string the pane identity to locate
---@return table<string, unknown> placement of the named pane
local function nativePane(plan, id)
  for _, pane in ipairs(plan.panes) do
    if pane.id == id then
      return assert(pane.placement, "the starter " .. id .. " pane carries its placement")
    end
  end
  error("the starter native plan carries its " .. id .. " pane", 0)
end

---@param plan ApplicationPlan the resolved native plan
---@param id string the pane identity to locate
---@return table<string, unknown>? placement of the named pane, or nil when the plan is single-pane
local function findPane(plan, id)
  for _, pane in ipairs(plan.panes) do
    if pane.id == id then
      return assert(pane.placement, "the starter " .. id .. " pane carries its placement")
    end
  end
  return nil
end

-- Renders one native application frame through the resolved plan: the 3D
-- machine raster composited once into the machine pane with the bottom
-- prompt beneath it, and the semantic message plus the inspected
-- portrait companion on the info pane. Repeated draws never advance
-- semantic clocks.
---@param snapshot StarterChoiceController.Snapshot controller snapshot
---@param view { candidates: table<string, unknown>[], names: string[] }
---@param text table<string, unknown> text provider ({ drawLineWithColorVariants })
---@param plan ApplicationPlan the resolved native plan
---@param windowRenderer table<string, unknown> field-borrowed window primitive for framed surfaces
---@param renderAlpha number field render interpolation alpha
function StarterChoicePresentation:drawNative(snapshot, view, text, plan, windowRenderer, renderAlpha)
  local _ = view
  assert(type(snapshot) == "table", "starter presentation draw requires the controller snapshot")
  assert(
    text ~= nil and type(text.drawLineWithColorVariants) == "function",
    "starter presentation requires the token-color-variant text provider"
  )
  assert(self._ready, "starter presentation is not prepared")
  local sampled = self:_sampleForDraw(snapshot, renderAlpha)
  local sampledSnapshot = sampled.snapshot --[[@as StarterChoiceController.Snapshot]]
  local machinePlacement = nativePane(plan, "machine")
  local infoPlacement = findPane(plan, "info")
  self:_syncRealized(snapshot)
  local graphics = assert(love and love.graphics, "starter presentation requires the graphics namespace")
  graphics.setColor(1, 1, 1, 1)
  self:_renderMachineTarget(sampledSnapshot, sampled)
  local target = assert(self._machineTarget, "starter presentation owns no machine raster target")
  local textColors = assert(self._manifest.textColors, "starter presentation requires the generated chooser colors")
  local surfaces = self._manifest.surfaces
  local timing = self._manifest.scene.timing
  if infoPlacement == nil then
    self:_drawAdaptedPane(sampledSnapshot, text, windowRenderer, machinePlacement, target, textColors, surfaces)
    LogicalSurface.draw(graphics, machinePlacement, function()
      self:_drawFade(sampled.machineFade / timing.machineFadeTicks)
    end)
    self:_drawOuterFrames(graphics, plan, windowRenderer)
    graphics.setColor(1, 1, 1, 1)
    return
  end
  local _, promptText = infoMessageFor(self, sampledSnapshot)
  LogicalSurface.draw(graphics, machinePlacement, function()
    graphics.draw(target, 0, 0)
    if machinePromptVisible(sampledSnapshot) then
      local machineLease = self._resources.machineBackgroundLease
      if machineLease ~= nil then
        machineLease:draw(graphics, 0, 0)
      else
        graphics.draw(assert(self._resources.machineBackgroundImage), 0, 0)
      end
      self:_drawMessageLines(
        surfaces.machine.prompt,
        promptText,
        text,
        transparentBackground(textColors.machineBackground),
        windowRenderer
      )
    end
  end)
  LogicalSurface.draw(graphics, infoPlacement, function()
    self:_drawInfoBackdrop()
    self:_drawInfoArtwork()
    if portraitVisible(sampledSnapshot) then
      self:_drawInfoPortrait(sampledSnapshot, surfaces.info.portrait)
    end
    local sampledInfoText, _ = infoMessageFor(self, sampledSnapshot)
    self:_drawMessageLines(surfaces.info.message, sampledInfoText, text, textColors.infoBackground, windowRenderer)
  end)
  LogicalSurface.draw(graphics, infoPlacement, function()
    self:_drawFade(sampled.infoFade / timing.infoFadeTicks)
  end)
  LogicalSurface.draw(graphics, machinePlacement, function()
    self:_drawFade(sampled.machineFade / timing.machineFadeTicks)
  end)
  self:_drawOuterFrames(graphics, plan, windowRenderer)
  graphics.setColor(1, 1, 1, 1)
end

-- Renders the machine-derived adapted chooser into one 256x192 pane: the
-- 3D machine raster with its lower artwork, the currently relevant info
-- copy in the machine's lower message area instead of the normal prompt,
-- and the selected starter portrait centered above that area. The reveal
-- prefix applies to the adapted info copy exactly as on the info surface.
---@param snapshot StarterChoiceController.Snapshot controller snapshot
---@param text table<string, unknown> text provider ({ drawLineWithColorVariants })
---@param windowRenderer table<string, unknown> field-borrowed window primitive for framed surfaces
---@param machinePlacement table<string, unknown> resolved machine pane placement
---@param target table<string, unknown> owned 256x192 machine raster
---@param textColors table<string, unknown> generated chooser colors
---@param surfaces table<string, unknown> source message/portrait surfaces
function StarterChoicePresentation:_drawAdaptedPane(
  snapshot,
  text,
  windowRenderer,
  machinePlacement,
  target,
  textColors,
  surfaces
)
  local graphics = assert(love and love.graphics, "starter presentation requires the graphics namespace")
  LogicalSurface.draw(graphics, machinePlacement, function()
    graphics.draw(target, 0, 0)
    local machineLease = self._resources.machineBackgroundLease
    if machineLease ~= nil then
      machineLease:draw(graphics, 0, 0)
    else
      graphics.draw(assert(self._resources.machineBackgroundImage), 0, 0)
    end
    local adaptedInfo, _ = infoMessageFor(self, snapshot)
    self:_drawMessageLines(
      surfaces.machine.prompt,
      adaptedInfo,
      text,
      transparentBackground(textColors.machineBackground),
      windowRenderer
    )
    if portraitVisible(snapshot) then
      self:_drawInfoPortrait(snapshot, ADAPTED_PORTRAIT)
    end
  end)
end

function StarterChoicePresentation:_releaseGpu()
  if self._preparation ~= nil then
    self._preparation:dispose()
    self._preparation = nil
  end
  self._resources = nil
  local target = self._machineTarget
  self._machineTarget = nil
  if target ~= nil then
    target:release()
  end
  if self._renderer ~= nil then
    self._renderer:release()
    self._renderer = nil
  end
  self._staticDraws = {}
  self._clipNames = { turntable = "", ballEffect = "", ballRock = {}, ballOpen = "" }
  self._ready = false
  self._backend = nil
end

-- Release every acquired GPU/model resource exactly once. Safe before
-- preparation and safe to repeat: closing during a transition or disposing
-- twice never touches a live object.
function StarterChoicePresentation:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  self._renderSamples = nil
  self._printerMessage = nil
  self._printerTyped = false
  self._printerRevealed = 0
  self._printerDelay = 0
  self:_releaseGpu()
end

return StarterChoicePresentation
