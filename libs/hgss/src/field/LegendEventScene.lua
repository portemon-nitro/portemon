-- The source legendary-story field scenes that own their own fixed-tick
-- lifetime: the Kimono Girls' wing effect (src/field/script_field_effects.c
-- Task_ShowLegendaryWing), Lance's Lake of Rage departure
-- (Task_LanceFliesAway), the Sinjoh Unown circle and egg cutscenes
-- (src/field/event_cutscene_sinjoh.c) and the Arceus cinematic
-- (src/application/arceus_cinematic.c).
--
-- One scene instance per live field. A running scene owns its presented models,
-- its clip clocks, its screen cover and the child-script handoff the wing
-- effect needs; a cancellation releases all of them exactly once and leaves no
-- result behind. Nothing here decides story progression, grants a mon or writes
-- a story flag: the authored script owns every one of those decisions.
--
-- The wing effect is the one scene that runs a map script inside its own block:
-- the source queues map script 3 (zero-based entry 2) while the loop clip
-- plays, and its task does not resume until that script returned. The scene
-- publishes that request through `step`'s "child" answer and continues only
-- after `childComplete`, so a task that blocked the child would be the
-- source's own deadlock.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")
local AnimationPlayer = require("libs.hgss.src.presentation.AnimationPlayer")

---@class LegendEventScene.EffectPart
---@field model table<string, unknown> the normalized source model descriptor
---@field clips table<string, { ids: string[], frames: integer, frameCounts: table<string, integer> }> clip role -> source clips, longest frame count and per-channel durations

---@class LegendEventScene.EffectDefinition
---@field model table<string, unknown>? a single normalized source model
---@field parts LegendEventScene.EffectPart[]?
---@field models table<string, unknown>[]? the source models keyed by source slot
---@field machineModelMemberId integer? the placed machine the hall-of-fame balls anchor on
---@field clipIds string[]? the Lance departure's Dragonite clip ids
---@field trainerFrameDurations integer[]? the Lance departure's trainer frame durations
---@field ballAnimationFrameCount integer? the ball clip's source frame count
---@field ballPositions { role: string, offset: { x: number, y: number, z: number } }[]? one source ball offset per party slot
---@field sound string?
---@field layers table<integer, { path: string, width: integer, height: integer }>?
---@field sprite table<string, unknown>?
---@field bgm string?
---@field timeline number[][]?

---@class LegendEventSceneOptions
---@field definitions table<string, LegendEventScene.EffectDefinition> generated scene definitions by semantic kind
---@field audio table<string, unknown> the source audio host
---@field screen table<string, unknown>|nil the field screen-fade owner
---@field actors table<string, unknown> the field actor owner
---@field playerOf fun(): table<string, unknown> reads the live field player
---@field foregroundScript (fun(): string|nil)?
---@field currentScriptBankId (fun(): integer|nil)? the live map's source script bank
---@field anchorOf fun(modelMemberId: integer): { x: number, y: number, z: number }|nil? the live map's own placed-prop translation by source build model
---@field departureFactory (fun(definition: LegendEventScene.EffectDefinition, positions: table<string, { x: number, y: number, z: number }>): table<string, unknown>)? presented departure effect factory

---@class LegendEventScene.PartPresentation
---@field part integer one-based source part index
---@field model table<string, unknown>? the presented model handle
---@field x number
---@field y number
---@field z number

---@class LegendEventScene.CinematicPresentation
---@field layers table<integer, string> visible layer images by source layer index
---@field priorities table<integer, integer> layer draw priority by source layer index
---@field blend { plane1: integer?, plane2: integer?, ev: integer? }?
---@field sprite { visible: boolean, x: integer, y: integer, priority: integer }?

---@class LegendEventScene.Presentation
---@field kind string?
---@field parts LegendEventScene.PartPresentation[]?
---@field cinematic LegendEventScene.CinematicPresentation?
---@field departure { trainer: table<string, unknown>, flyer: table<string, unknown>?, model: table<string, unknown>? }?

---@class LegendEventScene
---@field private _definitions table<string, LegendEventScene.EffectDefinition>
---@field private _audio table<string, unknown>
---@field private _screen table<string, unknown>|nil
---@field private _actors table<string, unknown>
---@field private _playerOf fun(): table<string, unknown>
---@field private _foregroundScript (fun(): string|nil)?
---@field private _currentScriptBankId (fun(): integer|nil)?
---@field private _anchorOf (fun(modelMemberId: integer): { x: number, y: number, z: number }|nil)?
---@field private _modelFactory (fun(kind: string, part: table<string, unknown>, index: integer): table<string, unknown>)?
---@field private _departureFactory (fun(definition: LegendEventScene.EffectDefinition, positions: table<string, { x: number, y: number, z: number }>): table<string, unknown>)?
---@field private _montage table<string, unknown>? the prepared montage image owner
---@field private _ownerScript string?
---@field private _active table<string, unknown>|nil
local LegendEventScene = {}
LegendEventScene.__index = LegendEventScene

-- src/field/script_field_effects.c: the wing effect queues map script 3, which
-- is zero-based compiled entry 2 of the current map's script bank.
LegendEventScene.WING_CHILD_SCRIPT_ENTRY = 2

-- The source's own screen covers: BeginNormalPaletteFade(..., 2, 1).
LegendEventScene.WHITE_FADE_STEPS = 2
LegendEventScene.WHITE_FADE_SPEED = 1

-- src/field/event_cutscene_sinjoh.c: the Unown circle's two waits.
LegendEventScene.UNOWN_ANIMATE_TICKS = 100
LegendEventScene.ARCEUS_OBJECT_TICKS = 150

-- src/field/field_move_cut_in.c: the fly-with-object cut-in's own step table
-- (gFieldMoveCutInFlyWithObjectSteps, 12 steps). The port mirrors the step
-- order and gates with resource/flyer status, not a fixed tick count.
LegendEventScene.LANCE_PICKUP_WAIT_TICKS = 20
LegendEventScene.LANCE_FLY_SOUND = "SEQ_SE_DP_FW019"

-- src/application/arceus_cinematic.c::enum ArceusScriptCmdId. The timeline is a
-- closed command stream: an opcode followed by its own arguments.
local ARCEUS = {
  WAIT = 0,
  FADE_IN_FROM_BLACK = 1,
  FADE_OUT_TO_BLACK = 2,
  FADE_IN_FROM_WHITE = 3,
  FADE_OUT_TO_WHITE = 4,
  WAIT_FADE = 5,
  LOAD_BG = 6,
  TOGGLE_BG = 7,
  SET_BG_PRIORITY = 8,
  SET_BLEND_PLANE = 9,
  START_BLEND = 10,
  RESET_BLEND = 11,
  SAVE_BGM = 12,
  STOP_BGM = 13,
  PLAY_BGM = 14,
  SET_SPRITE_VISIBLE = 15,
  SET_SPRITE_POSITION = 16,
  SET_SPRITE_PRIORITY = 17,
  NOP = 18,
  END = 19,
}
LegendEventScene.ARCEUS_COMMANDS = ARCEUS

-- Each timeline entry is one command followed by its own arguments
-- (sArceusCinematicScriptCmdSizes' closed vocabulary); the cursor advances one
-- entry per executed command.

local FADE_COMMANDS = {
  [ARCEUS.FADE_IN_FROM_BLACK] = { direction = "in", color = "black" },
  [ARCEUS.FADE_OUT_TO_BLACK] = { direction = "out", color = "black" },
  [ARCEUS.FADE_IN_FROM_WHITE] = { direction = "in", color = "white" },
  [ARCEUS.FADE_OUT_TO_WHITE] = { direction = "out", color = "white" },
}

---@param options LegendEventSceneOptions
---@return LegendEventScene
function LegendEventScene.new(options)
  assert(type(options) == "table", "the legend event scene needs its collaborators")
  assert(type(options.definitions) == "table", "the legend event scene borrows the generated scene definitions")
  local audio = assert(options.audio, "the legend event scene needs the source audio host")
  assert(audio.play and audio.playMusic, "the legend event scene needs the source audio host")
  assert(options.actors and options.actors.actorIdForMapIndex, "the legend event scene needs the field actors")
  assert(type(options.playerOf) == "function", "the legend event scene reads the live field player")
  if options.foregroundScript ~= nil then
    assert(type(options.foregroundScript) == "function", "the foreground-script lookup must be a function")
  end
  if options.currentScriptBankId ~= nil then
    assert(type(options.currentScriptBankId) == "function", "the map script-bank lookup must be a function")
  end
  if options.anchorOf ~= nil then
    assert(type(options.anchorOf) == "function", "the map placement lookup must be a function")
  end
  if options.departureFactory ~= nil then
    assert(type(options.departureFactory) == "function", "the departure factory creates the fly-with-object effect")
  end
  return setmetatable({
    _definitions = options.definitions,
    _audio = audio,
    _screen = options.screen,
    _actors = options.actors,
    _playerOf = options.playerOf,
    _foregroundScript = options.foregroundScript,
    _currentScriptBankId = options.currentScriptBankId,
    _anchorOf = options.anchorOf,
    _modelFactory = nil,
    _departureFactory = options.departureFactory,
    _ownerScript = nil,
    _active = nil,
  }, LegendEventScene)
end

-- The presented composition installs the prepared source-model bridge once. A
-- headless composition never installs one: the scene then owns no visual and
-- presents an empty snapshot while its source timing stays exact.
---@param factory (fun(kind: string, part: table<string, unknown>, index: integer): table<string, unknown>)|nil
function LegendEventScene:setModelFactory(factory)
  if factory ~= nil then
    assert(type(factory) == "function", "the legend scene model factory creates one source part")
  end
  self:_releaseModels()
  self._modelFactory = factory
end

-- The presented composition supplies the source sprite/model owner for Lance's
-- departure. A headless composition constructs the same effect over a pure
-- ModelInstance when this factory is absent.
---@param factory (fun(definition: LegendEventScene.EffectDefinition, positions: table<string, { x: number, y: number, z: number }>): table<string, unknown>)|nil
function LegendEventScene:setDepartureFactory(factory)
  if factory ~= nil then
    assert(type(factory) == "function", "the departure factory creates the fly-with-object effect")
  end
  self._departureFactory = factory
end

---@private
function LegendEventScene:_releaseModels()
  local active = self._active
  if active == nil then
    return
  end
  local models = active.models
  if models == nil then
    return
  end
  active.models = nil
  for _, model in ipairs(models) do
    if model ~= nil then
      model:dispose()
    end
  end
end

---@return boolean
function LegendEventScene:isRunning()
  return self._active ~= nil
end

-- A running scene owns presented models, a screen cover and a child-script
-- handoff, so a capture taken while it runs describes a field whose scene has
-- not returned control.
---@return boolean
function LegendEventScene:isStableForSave()
  if self._active ~= nil then
    return false
  end
  local owner = self._ownerScript
  if owner == nil then
    return true
  end
  local current = self._foregroundScript ~= nil and self._foregroundScript() or nil
  if current ~= owner then
    self._ownerScript = nil
    return true
  end
  return false
end

---@param kind string
---@return LegendEventScene.EffectDefinition
function LegendEventScene:_requireDefinition(kind)
  local definition = self._definitions[kind]
  if definition == nil then
    Errors.raise(
      FieldErrors.FIELD_LEGEND_EFFECT_SOURCE_MISSING,
      "the legend scene's generated source asset is missing",
      {
        kind = kind,
      }
    )
  end
  return definition --[[@as LegendEventScene.EffectDefinition]]
end

-- The longest source clip of one role: the source waits for a phase's whole
-- animation set, so the phase lasts as long as its longest channel record.
---@param part LegendEventScene.EffectPart
---@param role string
---@return integer
local function clipFrames(part, role)
  local clip = assert(part.clips and part.clips[role], "the legend scene part carries its " .. role .. " clips")
  assert(type(clip.frames) == "number" and clip.frames > 0, "the legend clip has a frame count")
  return clip.frames --[[@as integer]]
end

-- Claim the presented source parts of one definition. A headless composition
-- claims nothing; a composed one instantiates each part from the factory.
---@param self LegendEventScene
---@param definition LegendEventScene.EffectDefinition
---@param kind string the generated definition key the parts belong to
---@param onlyIndex integer? one part to claim when the definition keys models by source kind
---@return table<integer, table<string, unknown>>
function LegendEventScene:_claimModels(definition, kind, onlyIndex)
  local models = {}
  local parts = definition.parts or {}
  for index, part in ipairs(parts) do
    if onlyIndex == nil or index == onlyIndex then
      models[index] = self:_claimModelPart(kind, part, index)
    end
  end
  return models
end

-- Claim one presented source part from the composed factory, or nothing in a
-- headless composition. `part` is the definition's own part record: the
-- generated scene definitions key theirs by `parts`, while an effect that
-- publishes a single model hands that model over directly.
---@param kind string
---@param part table<string, unknown>
---@param index integer
---@return table<string, unknown>|nil
function LegendEventScene:_claimModelPart(kind, part, index)
  local factory = self._modelFactory
  if factory == nil then
    return nil
  end
  return factory(kind, part, index)
end

-- The composed presentation hands over the prepared montage images once; the
-- scene only publishes which of them are visible this tick.
---@param montage table<string, unknown>|nil
function LegendEventScene:setMontage(montage)
  self._montage = montage
end

---@private
-- Play every source clip of one phase: the source loads a phase's whole
-- anim-list record set, so a phase is never just its first channel.
---@param model table<string, unknown>|nil
---@param part LegendEventScene.EffectPart
---@param role string
---@param loop boolean?
local function playRole(model, part, role, loop)
  if model == nil then
    return
  end
  local clip = assert(part.clips and part.clips[role], "the legend scene part carries its " .. role .. " clips")
  for _, id in ipairs(clip.ids) do
    model:play(id, loop and { loopMode = "loop" } or nil)
  end
end

-- Play one wing phase and retain the real attachment handles. A headless
-- composition advances the same AnimationPlayer state over each generated
-- channel's own duration; it does not own a second scalar phase clock.
---@param model table<string, unknown>|nil
---@param part LegendEventScene.EffectPart
---@param role string
---@param loop boolean?
---@return table<string, unknown>[]
local function playWingRole(model, part, role, loop)
  local clip = assert(part.clips and part.clips[role], "the legend scene part carries its " .. role .. " clips")
  local handles = {}
  for _, id in ipairs(clip.ids) do
    if model ~= nil then
      handles[#handles + 1] = model:play(id, { loopMode = loop and "loop" or "once" })
    else
      local frameCount = assert(clip.frameCounts and clip.frameCounts[id], "the wing clip has its channel duration")
      local player = AnimationPlayer.new({ frameCount = frameCount })
      player.loopMode = loop and "loop" or "once"
      handles[#handles + 1] = { player = player }
    end
  end
  return handles
end

---@param active table<string, unknown>
local function stopWingPlays(active)
  local model = active.models and active.models[1] or nil
  for _, handle in ipairs(active.plays or {}) do
    if model ~= nil then
      model:stop(handle)
    end
  end
  active.plays = {}
end

---@param active table<string, unknown>
---@return boolean
local function wingPlaysFinished(active)
  for _, handle in ipairs(active.plays or {}) do
    if not handle.player:isComplete() then
      return false
    end
  end
  return true
end

-- ScrCmd_ShowLegendaryWing (774): load the source wing model on the player,
-- play its own sound, run the intro clip, start the loop clip together with the
-- map's own child script, and only after the child returned let the loop finish
-- and the end clip run.
---@param kind integer
function LegendEventScene:_beginWing(kind)
  local definition = self:_requireDefinition("legend_wing")
  local part = assert(definition.parts and definition.parts[kind + 1], "the wing effect carries its source kind")
  local player = self._playerOf()
  assert(player ~= nil, "the wing effect needs the live field player")
  self._active = {
    kind = "legend_wing",
    sourceKind = kind,
    definition = definition,
    part = part,
    phase = "load",
    x = player.worldX,
    y = player.worldY,
    z = player.worldZ,
    plays = {},
  }
end

-- A headless departure still owns a real ModelDefinition/ModelInstance and
-- the real flyer state machine; only GPU-backed image handles are absent.
---@param definition LegendEventScene.EffectDefinition
---@param positions table<string, { x: number, y: number, z: number }>
---@return table<string, unknown>
local function headlessDeparture(definition, positions)
  local ModelDefinition = require("libs.hgss.src.presentation.ModelDefinition")
  local ModelInstance = require("libs.hgss.src.presentation.ModelInstance")
  local LanceDepartureEffect = require("libs.hgss.src.presentation.LanceDepartureEffect")
  local instance = ModelInstance.new(ModelDefinition.fromNitroDescriptor(assert(definition.model)))
  local handle = {}
  function handle:play(id, opts)
    return instance:play(id, opts)
  end
  function handle:stop(play)
    return instance:stop(play)
  end
  function handle:updateFixed()
    instance:updateFixed()
  end
  function handle:dispose() end
  return LanceDepartureEffect.new({
    model = handle,
    clipIds = assert(definition.clipIds),
    trainerFrameDurations = assert(definition.trainerFrameDurations),
    screenOffset = LanceDepartureEffect.screenOffsetFor(assert(positions.player), assert(positions.lance)),
  })
end

-- ScrCmd_LanceFlyAway (775): resolve the two source object ids and run the
-- fly-with-object take-off through the source's own step order. The generated
-- cut-in mon is the source Dragonite; the scene owns the two object
-- identities and never a generic Fly.
---@param first unknown
---@param second unknown
function LegendEventScene:_beginLanceDeparture(first, second)
  local function actorFor(objectIndex, label)
    if type(objectIndex) ~= "number" or objectIndex % 1 ~= 0 then
      Errors.raise(FieldErrors.FIELD_LEGEND_SCENE_ACTOR_MISSING, "the departure names a source object index", {
        label = label,
        objectIndex = tostring(objectIndex),
      })
    end
    local actorId = self._actors:actorIdForMapIndex(objectIndex)
    if actorId == nil then
      Errors.raise(FieldErrors.FIELD_LEGEND_SCENE_ACTOR_MISSING, "the departure's source object is not on the map", {
        label = label,
        objectIndex = objectIndex,
      })
    end
    return actorId
  end
  local lance = actorFor(first, "lance")
  local dragonite = actorFor(second, "dragonite")
  assert(
    self._actors.getById and self._actors.hide and self._actors.show,
    "the departure needs live object presentation"
  )
  local function positionOf(actorId, label)
    local actor = self._actors:getById(actorId)
    local position = actor ~= nil and actor:getWorldPosition() or nil
    if position == nil or position.x == nil or position.y == nil or position.z == nil then
      Errors.raise(
        FieldErrors.FIELD_LEGEND_SCENE_ACTOR_MISSING,
        "the departure's source object has no world position",
        {
          label = label,
          actorId = actorId,
        }
      )
    end
    return position --[[@as { x: number, y: number, z: number }]]
  end
  local player = assert(self._playerOf(), "the departure needs the live field player")
  local positions = {
    player = { x = player.worldX, y = player.worldY, z = player.worldZ },
    lance = positionOf(lance, "lance"),
    dragonite = positionOf(dragonite, "dragonite"),
  }
  local definition = self:_requireDefinition("lance_departure")
  local factory = self._departureFactory or headlessDeparture
  self._active = {
    kind = "lance_departure",
    phase = "load_sprites",
    timer = 0,
    actors = { lance, dragonite },
    dragonite = dragonite,
    positions = positions,
    departure = factory(definition, positions),
  }
end

---@param kind string
function LegendEventScene:_beginCinematicIfArceus(kind)
  if kind ~= 2 then
    -- Scenes 0 and 1 are the Bell Tower and Whirl Islands cinematics, which the
    -- map scene scripts drive through their own commands.
    Errors.raise(FieldErrors.FIELD_LEGEND_SCENE_UNSUPPORTED, "the cinematic scene is not this one", { scene = kind })
  end
  local definition = self:_requireDefinition("arceus_cinematic")
  assert(type(definition.timeline) == "table", "the Arceus cinematic carries its source timeline")
  self._active = {
    kind = "arceus_cinematic",
    definition = definition,
    phase = "running",
    cursor = 1,
    frame = 0,
    layers = {},
    priorities = {},
    blend = nil,
    sprite = { visible = false, x = 0, y = 0, priority = 0 },
    savedBgm = nil,
    blendStart = nil,
    blendTarget = nil,
    blendDuration = 0,
    awaiting = nil,
  }
end

---@param choice integer
function LegendEventScene:_beginEggCutscene(choice)
  local definition = self:_requireDefinition("sinjoh_egg")
  -- The generated parts are the three distinct source egg variants, not layers
  -- of one egg: the active claim keeps its own source index.
  local choiceIndex = choice + 1
  local part = assert(definition.parts and definition.parts[choiceIndex], "the egg cutscene names its source variant")
  local player = self._playerOf()
  assert(player ~= nil, "the egg cutscene needs the live field player")
  self._active = {
    kind = "egg_cutscene",
    definition = definition,
    choiceIndex = choiceIndex,
    part = part,
    phase = "fade_out",
    ticks = 0,
    x = player.worldX,
    y = player.worldY,
    z = player.worldZ,
  }
end

function LegendEventScene:_beginUnownCircle()
  local definition = self:_requireDefinition("sinjoh_unown")
  local player = self._playerOf()
  assert(player ~= nil, "the Unown circle needs the live field player")
  self._active = {
    kind = "unown_circle",
    definition = definition,
    phase = "fade_out",
    ticks = 0,
    timer = 0,
    x = player.worldX,
    y = player.worldY,
    z = player.worldZ,
  }
end

-- ScrCmd_HallOfFameAnim (514): the League ending's own machine effect
-- (src/field/field_move_effects.c::Task_HallOfFameBallAnim). The room's placed
-- machine provides the world anchor, one ball prop pops out of the machine for
-- every registered (non-Egg) party member with the source 16-call cadence
-- (fifteen waits, then a placement), and the balls' one-shot clip plays to its
-- own completion before the script continues to the game-clear transaction.
---@param count integer non-Egg party count the source reads through ScriptGetVar
function LegendEventScene:_beginHallOfFame(count)
  local definition = self:_requireDefinition("hall_of_fame_machine")
  local positions = assert(definition.ballPositions, "the Hall of Fame effect carries its source ball offsets")
  local anchorOf = self._anchorOf
  local anchor = anchorOf ~= nil and anchorOf(definition.machineModelMemberId) or nil
  if anchor == nil then
    Errors.raise(
      FieldErrors.FIELD_LEGEND_EFFECT_SOURCE_MISSING,
      "the Hall of Fame machine placement is missing from the active map",
      { modelMemberId = definition.machineModelMemberId }
    )
  end
  ---@cast anchor -nil
  self._active = {
    kind = "hall_of_fame_machine",
    definition = definition,
    count = count,
    numPlaced = 0,
    timer = 0,
    state = "load",
    positions = positions,
    anchor = { x = anchor.x, y = anchor.y, z = anchor.z },
    balls = {},
    frames = 0,
    frameCount = definition.ballAnimationFrameCount,
  }
end

-- Begin one blocking source scene. Every definition is resolved before the
-- scene claims anything, so a missing generated asset faults without leaving a
-- partial presentation behind.
---@param action string
---@param operands table<string, unknown>?
function LegendEventScene:begin(action, operands)
  if self._active ~= nil then
    Errors.raise(FieldErrors.FIELD_LEGEND_SCENE_BUSY, "another legend scene owns the field", { action = action })
  end
  operands = operands or {}
  self._ownerScript = self._foregroundScript ~= nil and self._foregroundScript() or nil
  if action == "wing" then
    self:_beginWing(assert(operands.kind, "the wing effect needs its source kind"))
    return
  end
  if action == "hall_of_fame" then
    self:_beginHallOfFame(assert(operands.count, "the Hall of Fame effect needs its party count"))
    return
  end
  if action == "lance_departure" then
    self:_beginLanceDeparture(operands.first, operands.second)
    return
  end
  if action == "unown_circle" then
    self:_beginUnownCircle()
    return
  end
  if action == "egg_cutscene" then
    self:_beginEggCutscene(assert(operands.choice, "the egg cutscene needs its source variant"))
    return
  end
  if action == "arceus_cinematic" then
    self:_beginCinematicIfArceus(assert(operands.kind, "the cinematic needs its scene number"))
    return
  end
  Errors.raise(FieldErrors.FIELD_LEGEND_SCENE_UNSUPPORTED, "unknown legend scene action", { action = tostring(action) })
end

---@private
---@param direction string
---@param color string
---@param duration integer
---@param speed integer
function LegendEventScene:_startCover(direction, color, duration, speed)
  local screen = self._screen
  if screen == nil then
    return
  end
  assert(type(screen.startFade) == "function", "the field screen owner starts covers")
  screen:startFade({ direction = direction, color = color, duration = duration, speed = speed, screenScope = "main" })
end

---@private
---@return boolean
function LegendEventScene:_coverDone()
  local screen = self._screen
  return screen == nil or type(screen.fadeDone) ~= "function" or screen:fadeDone() == true
end

-- The wing effect's own map child: the current map's script bank entry 2. The
-- task starts it through the scheduler's common-child mechanism while the loop
-- clip runs.
---@return string|nil
function LegendEventScene:childScriptId()
  local active = self._active
  if active == nil or active.phase ~= "child" or active.childRequested ~= true then
    return nil
  end
  local bankId = self._currentScriptBankId ~= nil and self._currentScriptBankId() or nil
  if type(bankId) ~= "number" then
    return nil
  end
  local ScriptIdentity = require("libs.assets.src.ScriptIdentity")
  return ScriptIdentity.formatVanilla(bankId, LegendEventScene.WING_CHILD_SCRIPT_ENTRY)
end

-- The child returned: stop the independent loop task and let every loop
-- channel finish its current iteration at its own checked terminal before the
-- end phase replaces the attachment set.
function LegendEventScene:childComplete()
  local active = self._active
  if active == nil or active.phase ~= "child" then
    return
  end
  for _, handle in ipairs(active.plays or {}) do
    handle.player:finishCurrentLoop()
  end
  active.phase = "loop"
  active.childRequested = nil
end

-- One fixed tick of the Hall of Fame machine, one native task invocation per
-- tick: load, place a ball, wait out the source interval, then play and wait for
-- the model's own one-shot clip. A headless composition keeps the identical
-- cadence and counts the compiled clip's frames itself.
---@param active table<string, unknown>
---@return string
function LegendEventScene:_stepHallOfFame(active)
  local definition = active.definition --[[@as table<string, unknown>]]
  local state = active.state
  if state == "load" then
    -- The ball is the only model this effect loads; the machine is the map's
    -- own placement and the scene never claims it.
    local model = self:_claimModelPart("hall_of_fame_machine", { model = assert(definition.models[1]) }, 1)
    active.models = model ~= nil and { model } or nil
    active.state = "place"
    return "wait"
  end
  if state == "place" then
    local index = active.numPlaced + 1
    local position = assert(active.positions[index], "the Hall of Fame effect has a ball position per source slot")
    local anchor = assert(active.anchor)
    local model = nil
    if active.models ~= nil then
      model = active.models[1]
    end
    active.balls[index] = {
      model = model,
      x = anchor.x + position.offset.x,
      y = anchor.y + position.offset.y,
      z = anchor.z + position.offset.z,
    }
    self._audio:play(assert(definition.placementSound))
    active.state = "wait_ball"
    return "wait"
  end
  if state == "wait_ball" then
    local interval = assert(definition.spawnIntervalSourceFrames)
    if active.timer < interval then
      active.timer = active.timer + 1
      return "wait"
    end
    active.timer = 0
    active.numPlaced = active.numPlaced + 1
    if active.numPlaced < active.count then
      active.state = "place"
    else
      active.state = "animate"
    end
    return "wait"
  end
  if state == "animate" then
    local first = assert(active.balls[1], "the Hall of Fame effect places at least one ball before playing")
    if first.model ~= nil then
      first.model:play(assert(definition.ballAnimation))
    end
    active.frames = 0
    active.state = "wait_anim"
    return "wait"
  end
  if state == "wait_anim" then
    -- The compiled clip's own frame count is the completion gate in both
    -- compositions: the presented instance plays exactly that clip, so the
    -- source wait is the same whether or not a model was claimed.
    active.frames = active.frames + 1
    if active.frames >= active.frameCount then
      self:_releaseHallOfFame(active)
      active.state = "end"
    end
    return "wait"
  end
  assert(state == "end", "the Hall of Fame effect is a closed state set")
  return "complete"
end

---@private
---@param active table<string, unknown>
function LegendEventScene:_releaseHallOfFame(active)
  local balls = active.balls or {}
  active.balls = {}
  for _, ball in ipairs(balls) do
    if ball.model ~= nil then
      ball.model:dispose()
    end
  end
  active.models = nil
end

---@private
---@param active table<string, unknown> the live scene claim
---@return string
function LegendEventScene:_stepWing(active)
  local part = active.part
  -- The wing definition keys one part per source kind, so the claim holds only
  -- the selected part as one dense instance.
  local kindIndex = active.sourceKind + 1
  local model = active.models and active.models[1] or nil
  if active.phase == "load" then
    local definition = active.definition
    if definition.sound ~= nil then
      self._audio:play(definition.sound)
    end
    local claimed = self:_claimModels(definition, "legend_wing", kindIndex)
    local claimedModel = claimed[kindIndex]
    active.models = claimedModel ~= nil and { claimedModel } or nil
    active.plays = playWingRole(claimedModel, part, "intro")
    active.phase = "intro"
    return "wait"
  end
  if active.phase == "intro" then
    if not wingPlaysFinished(active) then
      return "wait"
    end
    stopWingPlays(active)
    active.plays = playWingRole(model, part, "loop", true)
    active.phase = "child"
    active.childRequested = true
    return "child"
  end
  if active.phase == "child" then
    -- The task polls the map child without stepping the scene; the loop
    -- players advance in updatePresentation.
    return "wait"
  end
  if active.phase == "loop" then
    if not wingPlaysFinished(active) then
      return "wait"
    end
    stopWingPlays(active)
    active.plays = playWingRole(model, part, "end")
    active.phase = "end"
    return "wait"
  end
  assert(active.phase == "end", "the wing effect has no other phase")
  if not wingPlaysFinished(active) then
    return "wait"
  end
  stopWingPlays(active)
  self:_releaseModels()
  self._active = nil
  return "complete"
end

---@private
---@param active table<string, unknown> the live scene claim
---@return string
function LegendEventScene:_stepLanceDeparture(active)
  local phase = active.phase
  local departure = assert(active.departure, "the departure owns its presentation effect")
  if phase == "load_sprites" then
    departure:loadSpriteGraphics()
    active.phase = "wait_sprites"
    return "wait"
  end
  if phase == "wait_sprites" then
    if not departure:spritesReady() then
      return "wait"
    end
    active.phase = "create_trainer_sprite"
    return "wait"
  end
  if phase == "create_trainer_sprite" then
    departure:createTrainer()
    active.phase = "show_other_object"
    return "wait"
  end
  if phase == "show_other_object" then
    self._actors:hide(active.dragonite)
    departure:showOtherObject(active.positions.dragonite)
    active.phase = "wait_model_effect"
    return "wait"
  end
  if phase == "wait_model_effect" then
    if not departure:isModelDone() then
      return "wait"
    end
    departure:releaseModel()
    active.phase = "load_fly_graphics"
    return "wait"
  end
  if phase == "load_fly_graphics" then
    departure:loadFlyGraphics()
    active.phase = "wait_fly_graphics"
    return "wait"
  end
  if phase == "wait_fly_graphics" then
    if not departure:flyerReady() then
      return "wait"
    end
    active.phase = "wait_before_pickup"
    active.timer = 0
    return "wait"
  end
  if phase == "wait_before_pickup" then
    active.timer = active.timer + 1
    if active.timer < LegendEventScene.LANCE_PICKUP_WAIT_TICKS then
      return "wait"
    end
    active.timer = 0
    departure:createFlyer()
    departure:startPickup()
    active.phase = "wait_fly_away"
    return "wait"
  end
  if phase == "wait_fly_away" then
    if departure:flyerStatus() ~= 3 then
      return "wait"
    end
    self._audio:play(LegendEventScene.LANCE_FLY_SOUND)
    active.phase = "wait_fly_end"
    return "wait"
  end
  if phase == "wait_fly_end" then
    if departure:flyerStatus() ~= 2 then
      return "wait"
    end
    departure:destroyFlyer()
    active.phase = "free_sprites"
    return "wait"
  end
  assert(phase == "free_sprites", "the Lance departure is a closed step set")
  departure:dispose()
  for _, actorId in ipairs(active.actors) do
    self._actors:setPresentationOffset(actorId, { x = 0, y = 0, z = 0 })
  end
  self._active = nil
  return "complete"
end

---@private
---@param active table<string, unknown> the live scene claim
---@return string
function LegendEventScene:_stepUnownCircle(active)
  local phase = active.phase
  if phase == "fade_out" then
    self:_startCover("out", "white", LegendEventScene.WHITE_FADE_STEPS, LegendEventScene.WHITE_FADE_SPEED)
    active.phase = "fade_out_wait"
    return "wait"
  end
  if phase == "fade_out_wait" then
    if not self:_coverDone() then
      return "wait"
    end
    active.models = self:_claimModels(active.definition, "sinjoh_unown")
    self:_startCover("in", "white", LegendEventScene.WHITE_FADE_STEPS, LegendEventScene.WHITE_FADE_SPEED)
    active.phase = "fade_in_wait"
    return "wait"
  end
  if phase == "fade_in_wait" then
    if not self:_coverDone() then
      return "wait"
    end
    active.phase = "unown"
    active.timer = 0
    return "wait"
  end
  if phase == "unown" then
    active.timer = active.timer + 1
    if active.timer >= LegendEventScene.UNOWN_ANIMATE_TICKS then
      active.phase = "arceus_object"
      active.timer = 0
    end
    return "wait"
  end
  if phase == "arceus_object" then
    active.timer = active.timer + 1
    if active.timer >= LegendEventScene.ARCEUS_OBJECT_TICKS then
      self:_startCover("out", "white", LegendEventScene.WHITE_FADE_STEPS, LegendEventScene.WHITE_FADE_SPEED)
      active.phase = "final_fade"
    end
    return "wait"
  end
  assert(phase == "final_fade", "the Unown circle has no other phase")
  if not self:_coverDone() then
    return "wait"
  end
  self:_releaseModels()
  self._active = nil
  return "complete"
end

---@private
---@param active table<string, unknown> the live scene claim
---@return string
function LegendEventScene:_stepEggCutscene(active)
  local phase = active.phase
  if phase == "fade_out" then
    self:_startCover("out", "white", LegendEventScene.WHITE_FADE_STEPS, LegendEventScene.WHITE_FADE_SPEED)
    active.phase = "fade_out_wait"
    return "wait"
  end
  if phase == "fade_out_wait" then
    if not self:_coverDone() then
      return "wait"
    end
    -- Only the selected source variant is claimed and drawn; the other two
    -- belong to choices this scene did not make.
    local claimed = self:_claimModels(active.definition, "sinjoh_egg", active.choiceIndex)
    active.models = { claimed[active.choiceIndex] }
    self:_startCover("in", "white", LegendEventScene.WHITE_FADE_STEPS, LegendEventScene.WHITE_FADE_SPEED)
    active.phase = "fade_in_wait"
    return "wait"
  end
  if phase == "fade_in_wait" then
    if not self:_coverDone() then
      return "wait"
    end
    playRole(active.models[1], active.part, "all")
    active.phase = "animate"
    active.ticks = 0
    return "wait"
  end
  assert(phase == "animate", "the egg cutscene has no other phase")
  active.ticks = active.ticks + 1
  if active.ticks < clipFrames(active.part, "all") then
    return "wait"
  end
  self:_releaseModels()
  self._active = nil
  return "complete"
end

-- One Arceus timeline command. Returns "continue", "wait", "yield" or "done"
-- following the source command results.
---@private
---@param active table<string, unknown>
---@return string
function LegendEventScene:_runArceusCommand(active)
  local timeline = active.definition.timeline
  if active.cursor > #timeline then
    return "done"
  end
  local command = timeline[active.cursor]
  local opcode = command[1]
  if opcode == ARCEUS.END then
    return "done"
  end
  if opcode == ARCEUS.WAIT then
    if active.frame == command[2] then
      active.frame = 0
      active.cursor = active.cursor + 1
      return "yield"
    end
    active.frame = active.frame + 1
    return "wait"
  end
  local fade = FADE_COMMANDS[opcode]
  if fade ~= nil then
    self:_startCover(fade.direction, fade.color, command[2], command[3])
    active.cursor = active.cursor + 1
    return "continue"
  end
  if opcode == ARCEUS.WAIT_FADE then
    active.cursor = active.cursor + 1
    return "wait_fade"
  end
  if opcode == ARCEUS.LOAD_BG then
    local layer, fileId = command[2], command[3]
    local layers = active.definition.layers or {}
    local image = layers[fileId]
    if image == nil then
      Errors.raise(FieldErrors.FIELD_LEGEND_EFFECT_SOURCE_MISSING, "the Arceus montage layer is missing", {
        layer = layer,
        fileId = fileId,
      })
    end
    ---@cast image -nil
    active.layers[layer] = image.path
    active.cursor = active.cursor + 1
    return "continue"
  end
  if opcode == ARCEUS.TOGGLE_BG then
    if command[3] == 0 then
      active.layers[command[2]] = nil
    end
    active.cursor = active.cursor + 1
    return "continue"
  end
  if opcode == ARCEUS.SET_BG_PRIORITY then
    active.priorities[command[2]] = command[3]
    active.cursor = active.cursor + 1
    return "continue"
  end
  if opcode == ARCEUS.SET_BLEND_PLANE then
    active.blend = active.blend or {}
    if command[2] == 0 then
      active.blend.plane1 = command[3]
      active.blendStart = command[4]
    else
      active.blend.plane2 = command[3]
    end
    active.cursor = active.cursor + 1
    return "continue"
  end
  if opcode == ARCEUS.START_BLEND then
    active.blend = active.blend or {}
    active.blendTarget = command[2]
    active.blendDuration = command[3]
    active.blendFrame = 0
    active.blendStartEv = active.blendStart or 0
    active.cursor = active.cursor + 1
    return "blend"
  end
  if opcode == ARCEUS.RESET_BLEND then
    active.blend = nil
    active.blendStart = 0
    active.cursor = active.cursor + 1
    return "continue"
  end
  if opcode == ARCEUS.SAVE_BGM then
    active.savedBgm = active.definition.bgm
    active.cursor = active.cursor + 1
    return "continue"
  end
  if opcode == ARCEUS.STOP_BGM then
    self._audio:stopMusic()
    active.cursor = active.cursor + 1
    return "continue"
  end
  if opcode == ARCEUS.PLAY_BGM then
    local sequence = command[2] == -1 and active.savedBgm or command[2]
    if sequence ~= nil then
      self._audio:playMusic(sequence)
    end
    active.cursor = active.cursor + 1
    return "continue"
  end
  if opcode == ARCEUS.SET_SPRITE_VISIBLE then
    local sprite = assert(active.sprite, "the Arceus timeline keeps its sprite")
    sprite.visible = command[2] ~= 0
    active.cursor = active.cursor + 1
    return "continue"
  end
  if opcode == ARCEUS.SET_SPRITE_POSITION then
    local sprite = assert(active.sprite, "the Arceus timeline keeps its sprite")
    sprite.x, sprite.y = command[2], command[3]
    active.cursor = active.cursor + 1
    return "continue"
  end
  if opcode == ARCEUS.SET_SPRITE_PRIORITY then
    local sprite = assert(active.sprite, "the Arceus timeline keeps its sprite")
    sprite.priority = command[2]
    active.cursor = active.cursor + 1
    return "continue"
  end
  assert(opcode == ARCEUS.NOP, "the Arceus timeline carries a closed command")
  active.cursor = active.cursor + 1
  return "continue"
end

---@private
---@param active table<string, unknown> the live scene claim
---@return string
function LegendEventScene:_stepCinematic(active)
  if active.phase == "blend" then
    local duration = active.blendDuration
    if active.blendFrame == duration then
      active.blend.ev = active.blendTarget
      active.phase = "running"
      active.blend = { plane1 = active.blend.plane1, plane2 = active.blend.plane2, ev = active.blendTarget }
      return "wait"
    end
    local startEv, targetEv = active.blendStartEv, active.blendTarget
    local delta = math.abs(startEv - targetEv)
    local step = duration > 0 and math.floor(active.blendFrame * delta / duration) or delta
    local ev = startEv > targetEv and startEv - step or startEv + step
    active.blend.ev = ev
    active.blendFrame = active.blendFrame + 1
    return "wait"
  end
  if active.phase == "fade" then
    if not self:_coverDone() then
      return "wait"
    end
    active.phase = "running"
    return "wait"
  end
  assert(active.phase == "running", "the Arceus cinematic has no other phase")
  while true do
    local outcome = self:_runArceusCommand(active)
    if outcome == "done" then
      self._active = nil
      return "complete"
    end
    if outcome == "wait" then
      return "wait"
    end
    if outcome == "yield" then
      return "wait"
    end
    if outcome == "wait_fade" then
      active.phase = "fade"
      return "wait"
    end
    if outcome == "blend" then
      active.phase = "blend"
      return "wait"
    end
  end
end

-- One fixed tick of the running scene. Answers "wait" while it owns the field,
-- "child" when the wing effect wants its map child started, and "complete" once
-- the source scene returned.
---@return string
function LegendEventScene:step()
  local active = self._active
  if active == nil then
    return "complete"
  end
  if active.kind == "legend_wing" then
    return self:_stepWing(active)
  end
  if active.kind == "hall_of_fame_machine" then
    return self:_stepHallOfFame(active)
  end
  if active.kind == "lance_departure" then
    return self:_stepLanceDeparture(active)
  end
  if active.kind == "unown_circle" then
    return self:_stepUnownCircle(active)
  end
  if active.kind == "egg_cutscene" then
    return self:_stepEggCutscene(active)
  end
  assert(active.kind == "arceus_cinematic", "the legend scene is a closed set")
  return self:_stepCinematic(active)
end

-- The source boolean a blocking scene answers, taken exactly once by the task
-- that completed it. None of the scenes in this slice writes a script output:
-- their authored scripts own every result word.
---@return integer|nil
function LegendEventScene:takeResult()
  local result = self._result
  self._result = nil
  return result
end

-- Advance the presented source models one fixed tick. A headless wing owns
-- the same logical channel players as its presented counterpart; only the
-- model's GPU-backed evaluation is absent.
function LegendEventScene:updatePresentation()
  local active = self._active
  if active == nil then
    return
  end
  if active.kind == "lance_departure" then
    active.departure:updateFixed()
  end
  if active.models == nil then
    if active.kind == "legend_wing" then
      for _, handle in ipairs(active.plays or {}) do
        handle.player:updateFixed()
      end
    end
    return
  end
  for _, model in ipairs(active.models) do
    if model ~= nil then
      model:updateFixed()
    end
  end
end

-- The immutable per-tick snapshot the field draws: the presented models and,
-- for the Arceus cinematic, its montage layers, blends and sprite.
---@return LegendEventScene.Presentation
function LegendEventScene:presentation()
  local active = self._active
  if active == nil then
    return {}
  end
  local snapshot = { kind = active.kind } ---@type LegendEventScene.Presentation
  if active.kind == "lance_departure" then
    snapshot.departure = active.departure:snapshot()
    local model = snapshot.departure.model
    if model ~= nil then
      snapshot.parts = {
        {
          part = 1,
          model = model.handle,
          x = model.x,
          y = model.y,
          z = model.z,
          rotationDegrees = 0,
        },
      }
    end
  end
  local balls = active.balls
  if balls ~= nil then
    local placed = {}
    for index, ball in ipairs(balls) do
      if ball.model ~= nil then
        placed[#placed + 1] = {
          part = index,
          model = ball.model,
          x = ball.x,
          y = ball.y,
          z = ball.z,
          rotationDegrees = 0,
        }
      end
    end
    snapshot.parts = placed
  end
  local models = balls == nil and active.models or nil
  if models ~= nil then
    local parts = {}
    for index, model in ipairs(models) do
      if model ~= nil then
        parts[#parts + 1] = {
          part = index,
          model = model,
          x = active.x or 0,
          y = active.y or 0,
          z = active.z or 0,
          rotationDegrees = 0,
        }
      end
    end
    snapshot.parts = parts
  end
  if active.kind == "arceus_cinematic" then
    local layers = {}
    for layer, image in pairs(active.layers or {}) do
      layers[layer] = image
    end
    snapshot.cinematic = {
      layers = layers,
      priorities = active.priorities or {},
      blend = active.blend,
      sprite = active.sprite,
    }
  end
  return snapshot
end

-- Cancel the running scene: every presented model, screen cover and actor
-- offset is released exactly once and the phase clock stops. The screen cover
-- belongs to the field; a cancelled scene leaves the last known cover state to
-- the authored script's own fade commands.
---@param _ string?
function LegendEventScene:cancel(_)
  local active = self._active
  if active == nil then
    return
  end
  if active.kind == "lance_departure" then
    active.departure:dispose()
    self._actors:show(active.dragonite)
    for _, actorId in ipairs(active.actors) do
      self._actors:setPresentationOffset(actorId, { x = 0, y = 0, z = 0 })
    end
  end
  if active.kind == "hall_of_fame_machine" then
    self:_releaseHallOfFame(active)
  end
  self:_releaseModels()
  self._active = nil
end

return LegendEventScene
