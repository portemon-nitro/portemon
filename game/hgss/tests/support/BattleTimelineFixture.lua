-- Timeline unit tests resolve narration through synthetic staged message records.
local BattlePresentationManifestFixture = require("tests.support.BattlePresentationManifestFixture")
local BattleTimeline = require("game.hgss.src.battle.BattleTimeline")
local FieldMessageText = require("libs.assets.src.field.FieldMessageText")

local BattleTimelineFixture = {}
local BACKPIC_THROW_DURATIONS = { 8, 16, 6, 2, 4, 2, 2, 52, 2 }

---@param key string semantic staged message key
---@param substitutions string[] ordered source values
---@return string rendered fixture source text
local function resolve(_, key, substitutions)
  local entries = BattlePresentationManifestFixture.manifest().messages.entries
  local record = assert(entries[key], "timeline fixture stages message key: " .. key)
  local values = {}
  local substitutionIndex = 1
  for _, token in ipairs(record.tokens) do
    if token.kind == "substitution" then
      values[#values + 1] = {
        kind = "glyph",
        text = assert(substitutions[substitutionIndex], "timeline fixture receives source substitutions"),
      }
      substitutionIndex = substitutionIndex + 1
    else
      values[#values + 1] = token
    end
  end
  assert(substitutionIndex == #substitutions + 1, "timeline fixture consumes all source substitutions")
  return FieldMessageText.tokensToText(values)
end

---@param view table<string, unknown>? detached view under fixture enrichment
local function completeView(view)
  if type(view) ~= "table" then
    return
  end
  view.format = view.format or "single"
  view.playerTrainer = view.playerTrainer or { classKey = "PKMN_TRAINER_ETHAN", name = "ETHAN" }
  view.playerTrainer.classKey = view.playerTrainer.classKey or "PKMN_TRAINER_ETHAN"
  view.playerTrainer.name = view.playerTrainer.name or "ETHAN"
  view.playerName = view.playerName or "ETHAN"
  view.foeTrainers = view.foeTrainers or { { classKey = "YOUNGSTER", name = "WHITNEY" } }
  view.participants = view.participants or {}
  for _, trainer in ipairs(view.foeTrainers) do
    trainer.classKey = trainer.classKey or "YOUNGSTER"
    trainer.name = trainer.name or "WHITNEY"
  end
  for _, group in ipairs({ view.own or {}, view.foes or {} }) do
    if type(group) == "table" then
      for _, battler in ipairs(group) do
        if type(battler) == "table" then
          battler.ballKey = battler.ballKey or "POKE_BALL"
          battler.name = battler.name or battler.species
        end
      end
    end
  end
  if #view.participants == 0 then
    local seen = {}
    for _, foe in ipairs(view.foes or {}) do
      if type(foe.participant) == "number" and not seen[foe.participant] then
        seen[foe.participant] = true
        view.participants[#view.participants + 1] = {
          participant = foe.participant,
          side = 2,
          controller = "trainer:" .. tostring(foe.participant),
        }
      end
    end
  end
end

---@param timeline table source timeline owner
---@param view table<string, unknown> detached test view
local function installTrainerPictures(timeline, view)
  timeline._trainerPictures = {}
  local selectors = {}
  selectors[#selectors + 1] = "back:" .. view.playerTrainer.classKey
  for _, trainer in ipairs(view.foeTrainers) do
    selectors[#selectors + 1] = "front:" .. trainer.classKey
  end
  for _, selector in ipairs(selectors) do
    local drawableKey = "trainer:" .. selector
    local function frames(sourceSequence, count)
      local result = {}
      for sourceFrame = 0, count - 1 do
        result[#result + 1] = {
          drawableKey = sourceSequence == 0
              and (sourceFrame == 0 and drawableKey or drawableKey .. ":frame:" .. tostring(sourceFrame))
            or drawableKey .. ":sequence:" .. tostring(sourceSequence) .. ":frame:" .. tostring(sourceFrame),
          sourceFrame = sourceFrame,
          userAttr = sourceSequence == 1 and selector:match("^front:") ~= nil and sourceFrame == 0 and 1
            or (sourceSequence == 1 and selector:match("^front:") ~= nil and sourceFrame == 1 and 0xFFF or 0),
          durationTicks = sourceSequence == 1 and BACKPIC_THROW_DURATIONS[sourceFrame + 1]
            or (sourceFrame == 0 and 2 or 5),
          rasterOffset = { x = sourceFrame, y = 0 },
        }
      end
      return result
    end
    timeline._trainerPictures[selector] = {
      drawableKey = drawableKey,
      rasterOffset = { x = 0, y = 0 },
      animation = {
        sourceSequence = 0,
        playMode = "forward_loop",
        loopStartFrameIdx = 0,
        frames = frames(0, 2),
        sequences = {
          [1] = { sourceSequence = 0, playMode = "forward_loop", loopStartFrameIdx = 0, frames = frames(0, 2) },
          [2] = { sourceSequence = 1, playMode = "forward", loopStartFrameIdx = 0, frames = frames(1, 9) },
          [3] = { sourceSequence = 2, playMode = "forward_loop", loopStartFrameIdx = 0, frames = frames(2, 2) },
        },
      },
      throwOffsets = {
        { x = 0, y = 128 },
        { x = -34, y = 4 },
        { x = -28, y = -11 },
        { x = 50, y = -12 },
        { x = 32767, y = 32767 },
        { x = 32767, y = 32767 },
      },
    }
  end
end

---@return table staged synthetic source palette buffers and fill for headless encounter tests
local function syntheticEncounterSource()
  -- Synthetic 256-entry RGB555 buffers with distinct colors per
  -- sixteen-color bank. The seeds and overrides mirror the frozen
  -- encounter palette expectations: banks stay distinguishable, one
  -- equal-RGB pair spans object banks 2 and 5, and the transparent
  -- slots carry their native clears.
  local function stagedBuffer(seed)
    local buffer = {}
    for index = 0, 255 do
      local bank = math.floor(index / 16)
      buffer[index + 1] = (seed + bank * 173 + index * 7) % 32768
    end
    return buffer
  end
  local source = {
    mainBg = stagedBuffer(11),
    mainObj = {},
    mainObjPostFill = {},
    subBg = stagedBuffer(97),
    subObj = stagedBuffer(501),
    fill = 24 + 12 * 32 + 3 * 1024,
  }
  for index = 1, 224 do
    source.mainObj[index] = (409 + math.floor((index - 1) / 16) * 173 + (index - 1) * 7) % 32768
  end
  local shared = 7 + 13 * 32 + 29 * 1024
  source.mainObj[41] = shared
  source.mainObj[89] = shared
  source.mainBg[1] = 0
  source.subBg[1] = 0
  source.subObj[1] = 31 + 31 * 32 + 31 * 1024
  source.subBgOpaque = source.subBg
  source.subObjOpaque = source.subObj
  local initialSubBg = {}
  local initialSubObj = {}
  for index = 1, 255 do
    initialSubBg[index] = 0
    initialSubObj[index] = 31 + 31 * 32 + 31 * 1024
  end
  initialSubBg[256] = source.subBg[256]
  initialSubObj[256] = source.subObj[256]
  source.initialDisplayed = { subBg = initialSubBg, subObj = initialSubObj }
  return source
end

---@param opts game.hgss.src.battle.BattleTimeline.Options?
---@return game.hgss.src.battle.BattleTimeline
function BattleTimelineFixture.new(opts)
  opts = opts or {}
  opts.encounterSource = opts.encounterSource or syntheticEncounterSource()
  opts.messageText = opts.messageText or resolve
  opts.encounterFadeColor = opts.encounterFadeColor or "white"
  opts.moveName = opts.moveName or function(move)
    return move == "TACKLE" and "Tackle" or move
  end
  opts.itemName = opts.itemName or function(item)
    return item
  end
  opts.speciesName = opts.speciesName or function(species)
    return species
  end
  -- Headless drivers select frozen requests through the staged slot
  -- rows and complete admitted visuals instantly unless the test
  -- owns its recording collaborator: every admitted request still
  -- starts exactly once behind its ledger identity.
  if opts.slotGeometry == nil then
    opts.slotGeometry = BattlePresentationManifestFixture.manifest().battlefield.slots
  end
  if opts.effects == nil then
    opts.effects = {
      start = function(_)
        return { phase = "complete" }
      end,
      status = function(handle)
        return handle.phase
      end,
      cancel = function(handle)
        handle.phase = "cancelled"
        return true
      end,
      retire = function(_)
        return true
      end,
    }
  elseif opts.effects == false then
    -- An explicit false keeps the collaborator absent while staying
    -- distinct from a never-provided one: Flow still selects and the
    -- Timeline still enqueues, so the routed cue with nowhere to run
    -- fails loudly in beginNativeEffect instead of holding silently.
  end
  local timeline = BattleTimeline.new(opts)
  local reset = timeline.reset
  function timeline:reset(view)
    completeView(view)
    installTrainerPictures(self, view)
    return reset(self, view)
  end
  local intro = timeline.intro
  function timeline:intro(view, wild)
    completeView(view)
    installTrainerPictures(self, view)
    local restoreType = view.encounterRestoreType
    if restoreType == nil then
      if view.format == "double" or view.format == "wild-double" then
        restoreType = "ordinary-doubles"
      else
        restoreType = wild and "wild" or "trainer"
      end
    end
    self._encounterSource.restoreType = restoreType
    return intro(self, view, wild)
  end
  local present = timeline.present
  function timeline:present(packet, sourceMessages)
    for _, name in ipairs({ "before", "after" }) do
      completeView(packet[name])
    end
    if self._openingPresentation == nil and type(packet.before) == "table" then
      installTrainerPictures(self, packet.before --[[@as table<string, unknown>]])
    end
    return present(self, packet, sourceMessages)
  end
  return timeline
end

return BattleTimelineFixture
