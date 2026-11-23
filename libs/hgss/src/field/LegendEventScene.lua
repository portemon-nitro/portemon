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

---@class LegendEventScene.EffectPart
---@field model table<string, unknown> the normalized source model descriptor
---@field clips table<string, { ids: string[], frames: integer }> clip role -> source clips and their longest frame count

---@class LegendEventScene.EffectDefinition
---@field parts LegendEventScene.EffectPart[]?
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

---@class LegendEventScene
---@field private _definitions table<string, LegendEventScene.EffectDefinition>
---@field private _audio table<string, unknown>
---@field private _screen table<string, unknown>|nil
---@field private _actors table<string, unknown>
---@field private _playerOf fun(): table<string, unknown>
---@field private _foregroundScript (fun(): string|nil)?
---@field private _currentScriptBankId (fun(): integer|nil)?
---@field private _modelFactory (fun(kind: string, part: table<string, unknown>, index: integer): table<string, unknown>)?
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

-- src/field/field_move_cut_in.c: the fly-with-object cut-in's own step table.
LegendEventScene.LANCE_FLY_STEPS = 12
-- The take-off lift applied over those steps: the source sprites rise by one
-- billboard unit per step before the cut-in releases them.
LegendEventScene.LANCE_FLY_LIFT_PER_STEP = 0.5

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
  return setmetatable({
    _definitions = options.definitions,
    _audio = audio,
    _screen = options.screen,
    _actors = options.actors,
    _playerOf = options.playerOf,
    _foregroundScript = options.foregroundScript,
    _currentScriptBankId = options.currentScriptBankId,
    _modelFactory = nil,
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
    Errors.raise(FieldErrors.FIELD_LEGEND_EFFECT_SOURCE_MISSING, "the legend scene's generated source asset is missing", {
      kind = kind,
    })
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
  local factory = self._modelFactory
  if factory == nil then
    return models
  end
  for index, part in ipairs(parts) do
    if onlyIndex == nil or index == onlyIndex then
      models[index] = factory(kind, part, index)
    end
  end
  return models
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
    ticks = 0,
    x = player.worldX,
    y = player.worldY,
    z = player.worldZ,
  }
end

-- ScrCmd_LanceFlyAway (775): resolve the two source object ids and run the
-- fly-with-object take-off over the source's own step count, lifting both
-- actors until the cut-in released them.
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
  self._active = {
    kind = "lance_departure",
    phase = "fly",
    ticks = 0,
    actors = { lance, dragonite },
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
  local part = assert(definition.parts and definition.parts[choice + 1], "the egg cutscene names its source variant")
  local player = self._playerOf()
  assert(player ~= nil, "the egg cutscene needs the live field player")
  self._active = {
    kind = "egg_cutscene",
    definition = definition,
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

-- The child returned: the wing effect resumes with its loop's remaining
-- source cycle before it switches to the end clip.
function LegendEventScene:childComplete()
  local active = self._active
  if active == nil or active.phase ~= "child" then
    return
  end
  active.phase = "loop"
  active.ticks = 0
end

---@private
---@return string
function LegendEventScene:_stepWing(active)
  local part = active.part
  -- The wing definition keys one part per source kind, so every phase plays the
  -- one part its own kind claimed.
  local kindIndex = active.sourceKind + 1
  if active.phase == "load" then
    local definition = active.definition
    if definition.sound ~= nil then
      self._audio:play(definition.sound)
    end
    active.models = self:_claimModels(definition, "legend_wing", kindIndex)
    playRole(active.models[kindIndex], part, "intro")
    active.phase = "intro"
    active.ticks = 0
    return "wait"
  end
  if active.phase == "intro" then
    active.ticks = active.ticks + 1
    if active.ticks >= clipFrames(part, "intro") then
      playRole(active.models[kindIndex], part, "loop", true)
      active.phase = "child"
      active.childRequested = true
      active.ticks = 0
      return "child"
    end
    return "wait"
  end
  if active.phase == "loop" then
    active.ticks = active.ticks + 1
    if active.ticks >= clipFrames(part, "loop") then
      playRole(active.models[kindIndex], part, "end")
      active.phase = "end"
      active.ticks = 0
    end
    return "wait"
  end
  assert(active.phase == "end", "the wing effect has no other phase")
  active.ticks = active.ticks + 1
  if active.ticks < clipFrames(part, "end") then
    return "wait"
  end
  self:_releaseModels()
  self._active = nil
  return "complete"
end

---@private
---@return string
function LegendEventScene:_stepLanceDeparture(active)
  active.ticks = active.ticks + 1
  local lift = active.ticks * LegendEventScene.LANCE_FLY_LIFT_PER_STEP
  for _, actorId in ipairs(active.actors) do
    self._actors:setPresentationOffset(actorId, { x = 0, y = lift, z = 0 })
  end
  if active.ticks < LegendEventScene.LANCE_FLY_STEPS then
    return "wait"
  end
  self._active = nil
  return "complete"
end

---@private
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
    active.models = self:_claimModels(active.definition, "sinjoh_egg")
    self:_startCover("in", "white", LegendEventScene.WHITE_FADE_STEPS, LegendEventScene.WHITE_FADE_SPEED)
    active.phase = "fade_in_wait"
    return "wait"
  end
  if phase == "fade_in_wait" then
    if not self:_coverDone() then
      return "wait"
    end
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

-- Advance the presented source models one fixed tick. Only the instances' own
-- clip clocks move here.
function LegendEventScene:updatePresentation()
  local active = self._active
  if active == nil or active.models == nil then
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
  local models = active.models
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
    for _, actorId in ipairs(active.actors) do
      self._actors:setPresentationOffset(actorId, { x = 0, y = 0, z = 0 })
    end
  end
  self:_releaseModels()
  self._active = nil
end

return LegendEventScene
