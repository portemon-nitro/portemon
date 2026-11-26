-- The credit-roll choreography application: the twelve dancing mons, the
-- transition clouds, the screen flips and the sixteen story cutscenes over
-- the source roll timeline (tmp/pokeheartgold/src/credits/credits.c).
-- Scene backgrounds switch through the five source transition timings with
-- clouds covering the swap; the visible dance set follows the source screen
-- flips; each cutscene activates its sprites on their source times and
-- advances only when every active sprite finishes one play-through. The roll
-- ends at the source frame count; skipping stays the state owner's job, and
-- drawing stays the presentation owner's job behind the admitted bundle.

---@class CreditsScene
---@field _timer integer source frame counter
---@field _totalFrames integer source roll length
---@field _transitionTimings integer[] five source scene-switch frames
---@field _flipTimings integer[] five source display-flip frames
---@field _sceneIdx integer 0-based completed transitions
---@field _sceneIdxDup integer 0-based displayed scene driving dance and BGs
---@field _transState string "none" | "clouds_appear" | "switch_bg" | "clouds_dissipate"
---@field _transTimer integer ticks inside the transition state
---@field _sceneStartTimer integer roll frame of the last background swap
---@field _cloudAppearTimer integer roll frame clouds became visible
---@field _flipCount integer completed display flips
---@field _screensFlipped boolean source display mapping, starts swapped
---@field _danceSequences table<integer, table<string, unknown>> baked dance/cloud sequences by number
---@field _danceSeqsByScene integer[] dance sequence per displayed scene
---@field _cloudSeq integer baked cloud animation sequence
---@field _cutscenes table[] source cutscene params
---@field _cutsceneSprites table<integer, table<string, unknown>> realized cutscene sprite sequences by id
---@field _cutsceneIdx integer 0-based active cutscene
---@field _sprites table[] active cutscene sprite records
---@field _gender string "male" | "female" player gender for player/friend sprites
local CreditsScene = {}
CreditsScene.__index = CreditsScene

-- Source transition states behind the cloud cover (credits.c
-- SceneTransitionState).
CreditsScene.TRANS_NONE = "none"
CreditsScene.TRANS_CLOUDS_APPEAR = "clouds_appear"
CreditsScene.TRANS_SWITCH_BG = "switch_bg"
CreditsScene.TRANS_CLOUDS_DISSIPATE = "clouds_dissipate"

-- The source dissipate length: clouds hide thirty ticks after the swap.
CreditsScene.CLOUD_DISSIPATE_TICKS = 30

-- One play-through length of a baked animation sequence.
---@param sequence table<string, unknown> baked sequence with frames
---@return integer total duration ticks
local function sequenceDuration(sequence)
  assert(type(sequence) == "table", "a cutscene sprite carries its sequence")
  local frames = sequence.frames
  assert(type(frames) == "table", "a cutscene sprite carries its frames")
  local total = 0
  for _, frame in ipairs(frames) do
    total = total + (tonumber(frame.durationTicks) or 0)
  end
  assert(total > 0, "a cutscene animation plays at least one tick")
  return total
end
---@param sprites table<integer, table<string, unknown>> realized cutscene sprites by id
---@param spriteId number source sprite slot, integral
---@param animSeq number source animation sequence number, integral
---@param gender string "male" | "female"
---@return table<string, unknown> baked sequence
local function resolveSequence(sprites, spriteId, animSeq, gender)
  assert(type(sprites) == "table", "the choreography carries its cutscene sprites")
  local entry = sprites[spriteId]
  assert(type(entry) == "table", "the bundle carries the cutscene sprite: " .. tostring(spriteId))
  local sequences = entry.sequences
  if (spriteId == 5 or spriteId == 7) and gender == "female" then
    sequences = entry.femaleSequences
  end
  assert(type(sequences) == "table", "the bundle carries the cutscene sequences: " .. tostring(spriteId))
  local sequence = sequences[animSeq]
  assert(type(sequence) == "table", "the bundle carries the sprite animation: " .. tostring(animSeq))
  return sequence
end
---@param cutscene table<string, unknown> source cutscene params
---@param sprites table<integer, table<string, unknown>> realized cutscene sprites by id
---@param gender string "male" | "female"
---@return table[] staged sprite records
local function stageSprites(cutscene, sprites, gender)
  local params = cutscene.params
  assert(type(params) == "table", "a cutscene carries its sprite params")
  local spriteIds = cutscene.spriteIds
  assert(type(spriteIds) == "table", "a cutscene names its sprites")
  local staged = {}
  for _, param in ipairs(params) do
    -- Integral source ids stay numbers; Lua normalizes integral float keys,
    -- and the strict integer check below rejects fractional bundle damage.
    local slot = tonumber(param.spriteIdx)
    assert(type(slot) == "number" and slot % 1 == 0, "a cutscene param names its sprite slot")
    -- The param slot indexes the cutscene's sprite list, like the source
    -- spriteIdx into spriteIds.
    local spriteId = tonumber(spriteIds[slot + 1])
    assert(type(spriteId) == "number" and spriteId % 1 == 0, "a cutscene slot names its sprite")
    local animSeq = tonumber(param.animSeq)
    assert(type(animSeq) == "number" and animSeq % 1 == 0, "a cutscene param names its animation")
    local sequence = resolveSequence(sprites, spriteId, animSeq, gender)
    staged[#staged + 1] = {
      spriteId = spriteId,
      animSeq = animSeq,
      x = tonumber(param.x) or 0,
      y = tonumber(param.y) or 0,
      activateTime = math.floor(tonumber(param.activateTime) or 0),
      active = false,
      sequence = sequence,
      duration = sequenceDuration(sequence),
    }
  end
  return staged
end

---@param options table<string, unknown> bundle choreography data with gender and timelines
---@return CreditsScene
function CreditsScene.new(options)
  assert(type(options) == "table", "the credit choreography needs its bundle data")
  assert(type(options.danceSequences) == "table", "the choreography needs its dance sequences")
  assert(
    type(options.danceSeqsByScene) == "table" and #options.danceSeqsByScene == 6,
    "the choreography dances one sequence per scene"
  )
  assert(type(options.cloudSeq) == "number", "the choreography needs its cloud sequence")
  assert(type(options.cutscenes) == "table" and #options.cutscenes > 0, "the choreography needs its cutscenes")
  assert(type(options.cutsceneSprites) == "table", "the choreography needs its cutscene sprites")
  assert(options.gender == "male" or options.gender == "female", "the choreography needs the player gender")
  assert(type(options.totalFrames) == "number" and options.totalFrames > 0, "the choreography needs its roll length")
  assert(
    type(options.transitionTimings) == "table" and #options.transitionTimings == 5,
    "the choreography switches scenes on five source frames"
  )
  assert(
    type(options.flipTimings) == "table" and #options.flipTimings == 5,
    "the choreography flips displays on five source frames"
  )
  local cutscenes = options.cutscenes
  assert(type(cutscenes) == "table" and #cutscenes > 0, "the choreography stages its cutscenes")
  local spriteBank = options.cutsceneSprites
  assert(type(spriteBank) == "table", "the choreography needs its cutscene sprites")
  local gender = options.gender
  assert(gender == "male" or gender == "female", "the choreography needs the player gender")
  local first = assert(cutscenes[1], "the choreography opens on its first cutscene")
  local staged = stageSprites(first, spriteBank, gender)
  return setmetatable({
    _timer = 0,
    _totalFrames = math.floor(options.totalFrames),
    _transitionTimings = options.transitionTimings,
    _flipTimings = options.flipTimings,
    _sceneIdx = 0,
    _sceneIdxDup = 0,
    _transState = CreditsScene.TRANS_NONE,
    _transTimer = 0,
    _sceneStartTimer = 0,
    _cloudAppearTimer = 0,
    _flipCount = 0,
    _screensFlipped = true,
    _danceSequences = options.danceSequences,
    _danceSeqsByScene = options.danceSeqsByScene,
    _cloudSeq = options.cloudSeq,
    _cutscenes = cutscenes,
    _cutsceneSprites = options.cutsceneSprites,
    _cutsceneIdx = 0,
    _sprites = staged,
    _gender = options.gender,
  }, CreditsScene)
end

-- Stages the active cutscene's sprites, hidden until their source
-- activation frames. Advancement reuses the construction-time staging so a
-- bundle gap fails the same way mid-roll as before it.
function CreditsScene:_initCutscene()
  local cutscene = assert(self._cutscenes[self._cutsceneIdx + 1], "the choreography stages a cutscene")
  self._sprites = stageSprites(cutscene, self._cutsceneSprites, self._gender)
end

-- One roll frame: the source increments its counter first, then handles
-- page display, scene transitions, flips and cutscenes on the new counter.
-- The roll takes no input; skipping stays the state owner's job.
function CreditsScene:step(_)
  self._timer = self._timer + 1
  self:_stepTransition()
  self:_stepFlip()
  self:_stepCutscene()
end

-- The source scene transition (credits.c HandleSceneTransition): clouds
-- appear on the timing frame, backgrounds and dance sequences swap one
-- frame later, clouds dissipate over thirty frames, then the scene holds.
function CreditsScene:_stepTransition()
  if self._sceneIdx >= 5 then
    return
  end
  if self._timer == self._transitionTimings[self._sceneIdx + 1] and self._transState == CreditsScene.TRANS_NONE then
    self._transState = CreditsScene.TRANS_CLOUDS_APPEAR
  end
  if self._transState == CreditsScene.TRANS_CLOUDS_APPEAR then
    self._cloudAppearTimer = self._timer
    self._transTimer = 0
    self._transState = CreditsScene.TRANS_SWITCH_BG
    return
  end
  if self._transState == CreditsScene.TRANS_SWITCH_BG then
    self._transTimer = self._transTimer + 1
    if self._transTimer >= 1 then
      self._sceneIdxDup = (self._sceneIdxDup + 1) % 6
      self._sceneStartTimer = self._timer
      self._transTimer = 0
      self._transState = CreditsScene.TRANS_CLOUDS_DISSIPATE
    end
    return
  end
  if self._transState == CreditsScene.TRANS_CLOUDS_DISSIPATE then
    self._transTimer = self._transTimer + 1
    if self._transTimer >= CreditsScene.CLOUD_DISSIPATE_TICKS then
      self._transTimer = 0
      self._transState = CreditsScene.TRANS_NONE
      self._sceneIdx = self._sceneIdx + 1
    end
  end
end

-- The source display flip (credits.c HandleSceneFlip/RequestScreenFlip):
-- the mapping toggles on each of the five flip frames, swapping which
-- dance set the single pane shows.
function CreditsScene:_stepFlip()
  if self._flipCount >= 5 then
    return
  end
  if self._timer == self._flipTimings[self._flipCount + 1] then
    self._screensFlipped = not self._screensFlipped
    self._flipCount = self._flipCount + 1
  end
end

-- The source cutscene pump (credits.c HandleCutscenes): sprites activate
-- on their source frames, and the cutscene advances only once every
-- staged sprite finishes one play-through.
function CreditsScene:_stepCutscene()
  local cutscene = self._cutscenes[self._cutsceneIdx + 1]
  if cutscene == nil then
    return
  end
  for _, sprite in ipairs(self._sprites) do
    if not sprite.active and self._timer == sprite.activateTime then
      sprite.active = true
    end
  end
  local finished = 0
  for _, sprite in ipairs(self._sprites) do
    if sprite.active and (self._timer - sprite.activateTime) >= sprite.duration then
      finished = finished + 1
    end
  end
  if finished == #self._sprites then
    self._cutsceneIdx = self._cutsceneIdx + 1
    if self._cutscenes[self._cutsceneIdx + 1] ~= nil then
      self:_initCutscene()
    else
      self._sprites = {}
    end
  end
end

---@return boolean true once the roll reaches its source frame count
function CreditsScene:isDone()
  return self._timer >= self._totalFrames
end

-- One deterministic snapshot per tick for the presentation owner.
---@return table<string, unknown>
function CreditsScene:status()
  local danceSeq =
    assert(tonumber(self._danceSeqsByScene[self._sceneIdxDup + 1]), "every displayed scene dances a sequence")
  local sprites = {}
  for _, sprite in ipairs(self._sprites) do
    sprites[#sprites + 1] = {
      spriteId = sprite.spriteId,
      animSeq = sprite.animSeq,
      x = sprite.x,
      y = sprite.y,
      active = sprite.active,
      elapsed = sprite.active and (self._timer - sprite.activateTime) or 0,
    }
  end
  return {
    timer = self._timer,
    sceneIdx = self._sceneIdxDup,
    danceSeq = danceSeq,
    danceClock = self._timer - self._sceneStartTimer,
    cloudSeq = self._cloudSeq,
    cloudsVisible = self._transState ~= CreditsScene.TRANS_NONE,
    cloudClock = self._timer - self._cloudAppearTimer,
    screensFlipped = self._screensFlipped,
    flipCount = self._flipCount,
    cutsceneIdx = self._cutsceneIdx,
    cutsceneSprites = sprites,
    gender = self._gender,
    done = self:isDone(),
  }
end

return CreditsScene
