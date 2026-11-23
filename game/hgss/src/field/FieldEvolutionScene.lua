-- Menu-opened evolution scene (start_menu.c Task_StartMenu_Evolution):
-- composes the shared EvolutionScenePresenter over field-owned ports and
-- exposes the page child interface of the Party menu flow. It owns the
-- scene's message printer, Pokepic pose scene, voice operations, asset
-- holder, and display session, and holds the automatic field-music policy
-- from construction until the scene result or disposal restores the map
-- music exactly once.

local ApplicationPresentation = require("libs.ui.src.ApplicationPresentation")
local BattleAudio = require("libs.hgss.src.audio.BattleAudio")
local BattleScene = require("libs.hgss.src.presentation.BattleScene")
local BattleStagedText = require("game.hgss.src.battle.BattleStagedText")
local BattleTimeline = require("game.hgss.src.battle.BattleTimeline")
local EvolutionScenePresenter = require("game.hgss.src.battle.EvolutionScenePresenter")
local EvolutionSceneInterface = require("game.hgss.src.field.EvolutionSceneInterface")
local SourceTick = require("libs.hgss.src.field.SourceTick")

---@class FieldEvolutionScene
---@field _presenter EvolutionScenePresenter? scene lane, nil until the verified presentation core stages
---@field _printer BattleTimeline? message printer behind the presenter
---@field _poses BattleScene? Pokepic pose scene behind the presenter
---@field _opts FieldEvolutionScene.Options
---@field _session ApplicationPresentation display session behind the plan and pointer capture
---@field _view table<string, unknown> latest presenter view published by status
---@field _textPalette table<string, unknown>? staged narration text palette
---@field _result table<string, unknown>? sealed scene result until taken
---@field _finished boolean true once the scene sealed its result
---@field _policyHeld boolean true while this scene holds the field-music policy
---@field _disposed boolean
local FieldEvolutionScene = {}
FieldEvolutionScene.__index = FieldEvolutionScene

---@class FieldEvolutionScene.Options
---@field request { slot: integer, subject: table<string, unknown>, context: table<string, unknown>, source: "field_level"|"field_item" } committed scene facts
---@field sceneId string unique scene identity behind poses, voices, and failures
---@field assets FieldEvolutionAssets asset holder owned by the scene
---@field audio table<string, unknown> field audio controller: voice ports plus the field-music policy hold
---@field monCatalog MonCatalog mon catalog
---@field splRandomState table<string, integer> boot SPL random stream
---@field summary table<string, unknown> field Summary dependencies behind the move-replacement picker
---@field measureDisplay fun(): table<string, unknown> live display facts
---@field textSpeed string live player text speed name

---@param opts FieldEvolutionScene.Options
---@return FieldEvolutionScene
function FieldEvolutionScene.new(opts)
  assert(type(opts) == "table", "field evolution scenes require options")
  for _, name in ipairs({
    "request",
    "sceneId",
    "assets",
    "audio",
    "monCatalog",
    "splRandomState",
    "summary",
    "measureDisplay",
    "textSpeed",
  }) do
    assert(opts[name] ~= nil, "field evolution scenes require " .. name)
  end
  local audio = opts.audio
  assert(type(audio.suspendFieldPolicy) == "function", "field evolution scenes hold the field-music policy")
  local session = ApplicationPresentation.new(EvolutionSceneInterface.defaults(), nil)
  session:resolve(opts.measureDisplay(), {})
  audio:suspendFieldPolicy(opts.sceneId)
  return setmetatable({
    _opts = opts,
    _presenter = nil,
    _printer = nil,
    _poses = nil,
    _session = session,
    _view = { kind = "evolution", interactive = false, cancellable = false, application = "evolution" },
    _textPalette = nil,
    _result = nil,
    _finished = false,
    _policyHeld = true,
    _disposed = false,
  }, FieldEvolutionScene)
end

-- Composes the presenter once the verified presentation core stages.
-- Returns false while the core is pending and raises on a terminal failure.
---@return boolean composed
function FieldEvolutionScene:_compose()
  if self._presenter ~= nil then
    return true
  end
  local opts = self._opts
  local manifest, failure = opts.assets:manifest()
  if failure ~= nil then
    error(failure, 0)
  end
  if manifest == nil then
    return false
  end
  local sceneId = opts.sceneId
  local request = opts.request
  local catalog = opts.monCatalog
  local battleAudio = BattleAudio.new({ sink = opts.audio, launchId = sceneId })
  local function rejectDirectNarration()
    error("field evolution narrates through announced messages only", 0)
  end
  local printer = BattleTimeline.new({
    encounterFadeColor = "black",
    textSpeed = opts.textSpeed,
    messageText = rejectDirectNarration,
  })
  local poses = BattleScene.new()
  ---@param key string
  ---@param substitutions string[]
  ---@param controls BattleStagedText.PrinterControls
  ---@return string
  local function sceneText(key, substitutions, controls)
    return BattleStagedText.decode(manifest, key, substitutions, controls)
  end
  ---@param cue { species: string, form: integer? }
  ---@return table<string, unknown>
  local function playCry(cue)
    local facts = catalog:species(cue.species)
    assert(type(facts.nativeId) == "number", "evolution cries name a cataloged species: " .. tostring(cue.species))
    return battleAudio:playCry({ species = facts.nativeId, speciesKey = cue.species, form = cue.form })
  end
  self._textPalette = manifest.messages.roles.narration.palette
  self._printer = printer
  self._poses = poses
  self._presenter = EvolutionScenePresenter.new({
    source = request.source,
    subject = request.subject,
    context = request.context,
    partySlot = request.slot,
    sceneId = sceneId,
    identity = { launchId = sceneId, requestId = 0, epoch = 0, controller = "player" },
    monCatalog = catalog,
    splRandomState = opts.splRandomState,
    summary = opts.summary,
    speed = 1,
    voiced = true,
    manifest = manifest,
    text = sceneText,
    printer = printer,
    poses = poses,
    audio = battleAudio,
    playCry = playCry,
    assets = opts.assets,
  })
  return true
end

-- Releases the field-music policy hold, restoring the map music.
function FieldEvolutionScene:_releaseMusic()
  if self._policyHeld then
    self._policyHeld = false
    self._opts.audio:resumeFieldPolicy(self._opts.sceneId, true)
  end
end

-- Advances the scene by one accepted source tick: mapped edges reach the
-- presenter, then the printer, pose, fade, and scene clocks step once.
---@param uiInput table[] ordered semantic events
function FieldEvolutionScene:updateFixed(uiInput)
  assert(not self._disposed, "a disposed evolution scene cannot update")
  local mapped = self._session:mapInput(uiInput, self._view)
  if self._finished or not self:_compose() then
    return
  end
  local presenter = self._presenter --[[@as EvolutionScenePresenter]]
  for _, event in ipairs(mapped) do
    presenter:input(event)
  end
  local assets = self._opts.assets
  assets:update()
  local printer = self._printer --[[@as BattleTimeline]]
  printer:update(
    SourceTick.DT,
    function(key)
      return assets:drawable(key) ~= nil
    end,
    nil,
    function(messageId, callback, controlIndex)
      return presenter:printerCallback(messageId, callback, controlIndex)
    end
  )
  local poses = self._poses --[[@as BattleScene]]
  poses:stepAnimationPictures(nil)
  presenter:stepTick()
  local result = presenter:advance()
  self._view = presenter:view()
  if result ~= nil then
    self._result = result
    self._finished = true
    self:_releaseMusic()
  end
  self._session:resolve(self._opts.measureDisplay(), self._view)
end

-- Cancels a held press so a stale release never reaches a successor.
function FieldEvolutionScene:cancelPointerCapture()
  assert(not self._disposed, "a disposed evolution scene has no pointer capture")
  self._session:cancelPointers()
end

---@return table<string, unknown> presentation status with the resolved plan and the scene view
function FieldEvolutionScene:status()
  assert(not self._disposed, "a disposed evolution scene has no status")
  return {
    open = true,
    presentation = self._session:plan(),
    evolution = self._view,
    assets = self._opts.assets,
    textPalette = self._textPalette,
  }
end

---@return table<string, unknown>? result `evolution_complete` with its staged evolution or `evolution_cancelled`, once
function FieldEvolutionScene:takeResult()
  assert(not self._disposed, "a disposed evolution scene returns no result")
  local result = self._result
  self._result = nil
  return result
end

---@return nil the scene publishes only its result
function FieldEvolutionScene:takeIntent()
  return nil
end

-- Releases the scene exactly once: the presenter, pose scene, assets, and
-- session release, and a still-held music policy restores the map music.
function FieldEvolutionScene:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  if self._presenter ~= nil then
    self._presenter:dispose()
    self._presenter = nil
  end
  if self._poses ~= nil then
    self._poses:release()
    self._poses = nil
  end
  self._opts.assets:dispose()
  self._session:dispose()
  self:_releaseMusic()
end

return FieldEvolutionScene
