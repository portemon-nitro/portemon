-- Bounded visible-cue player for one battle launch. Translates the
-- detached delivery packets of the battle runtime into an ordered queue
-- of small typed cues (messages, health interpolation, hit recoil,
-- fainting, withdrawal, reveal, experience, waits, one-shot sounds) over
-- a displayed-state model, advanced only by accepted presentation time
-- at sixty ticks per second. The screen feeds packets in, ticks the
-- clock, and reads the displayed facts; drawing and input never advance
-- it. Unknown required effects play an explicit diagnostic cue instead
-- of vanishing. Message wording here is product-owned interim narration,
-- never a claim about original-game sentences.

local TextSpeedPolicy = require("libs.hgss.src.ui.TextSpeedPolicy")
local Utf8Glyphs = require("libs.assets.src.Utf8Glyphs")

---@class BattleTimeline
---@field _pendingSounds table<integer, string> queued one-shot sound intents for the screen drain
---@field _battlers table<integer, table<string, unknown>> displayed facts by combatant identity
---@field _order integer[] player-first combatant identities for view order
---@field _queue table<integer, table<string, unknown>> ordered unplayed cues
---@field _active table<string, unknown>? cue consuming ticks
---@field _message string currently displayed narration page
---@field _messageId integer stable identity of the displayed narration
---@field _messageSeq integer narration counter
---@field _lastPacketId integer highest accepted per-launch packet identity
---@field _latest table<string, unknown>? newest after view for name and move facts
---@field _names table<integer, string> visible names by combatant identity across packets
---@field _ownMoves table<string, string> own move display names by combatant and move identity
---@field _moveName (fun(move: string): string?)? borrowed move display-name resolver for foe narration
---@field _accum number fractional accepted seconds awaiting their tick
---@field _diagnostics string[] recorded unknown-effect occurrences
local BattleTimeline = {}
BattleTimeline.__index = BattleTimeline

BattleTimeline.TICKS_PER_SECOND = 60
BattleTimeline.MESSAGE_HOLD_TICKS = 12
BattleTimeline.HIT_TICKS = 6
BattleTimeline.HIT_DISPLACEMENT = 2
BattleTimeline.VANISH_TICKS = 12
BattleTimeline.EXP_TICKS_PER_SEGMENT = 24
BattleTimeline.HP_BAR_PIXELS = 48
BattleTimeline.HP_MAX_TICKS = 30
BattleTimeline.PAGE_GLYPHS = 54

local REVEAL = TextSpeedPolicy.forSpeed("mid")

---@param text string
---@return string[] pages of at most PAGE_GLYPHS glyphs, never empty
local function paginate(text)
  local pages = {}
  local glyphs = 0
  local current = {}
  -- Pagination counts glyphs, not bytes, so multibyte names never
  -- split a codepoint across pages.
  local codepoints = {}
  for char in Utf8Glyphs.iter(text) do
    codepoints[#codepoints + 1] = char
  end
  for index, char in ipairs(codepoints) do
    current[#current + 1] = char
    glyphs = glyphs + 1
    if glyphs >= BattleTimeline.PAGE_GLYPHS and (char == " " or index == #codepoints) then
      pages[#pages + 1] = table.concat(current)
      current = {}
      glyphs = 0
    end
  end
  if #current > 0 or #pages == 0 then
    pages[#pages + 1] = table.concat(current)
  end
  return pages
end

---@param value unknown
---@return unknown detached copy without shared mutable state
local function copyValue(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for key, item in pairs(value) do
    out[key] = copyValue(item)
  end
  return out
end

---@class BattleTimeline.Options
---@field sound (fun(name: string))? legacy sound-intent sink, drained immediately when supplied
---@field moveName (fun(move: string): string?)? display-name resolver for move identities the views never name

---@param opts BattleTimeline.Options?
---@return BattleTimeline
function BattleTimeline.new(opts)
  opts = opts or {}
  assert(type(opts) == "table", "the cue player requires options")
  return setmetatable({
    _sound = opts.sound,
    _moveName = opts.moveName,
    _pendingSounds = {},
    _names = {},
    _ownMoves = {},
    _battlers = {},
    _order = {},
    _queue = {},
    _active = nil,
    _message = "",
    _messageId = 0,
    _messageSeq = 0,
    _lastPacketId = 0,
    _latest = nil,
    _accum = 0,
    _diagnostics = {},
  }, BattleTimeline)
end

---@param self BattleTimeline
---@param view table<string, unknown>? detached view carrying name and move facts
local function indexFacts(self, view)
  -- Names and own move labels index from every delivery so narration
  -- keeps working after its battler leaves the newest view.
  if type(view) ~= "table" then
    return
  end
  for _, group in ipairs({ view.own, view.foes }) do
    if type(group) == "table" then
      for _, record in ipairs(group) do
        if type(record) == "table" and type(record.combatant) == "number" then
          local id = record.combatant --[[@as integer]]
          if type(record.name) == "string" and self._names[id] == nil then
            self._names[id] = record.name --[[@as string]]
          end
          if type(record.moves) == "table" then
            for _, entry in ipairs(record.moves) do
              if type(entry) == "table" and type(entry.move) == "string" and type(entry.name) == "string" then
                local key = tostring(id) .. "\0" .. entry.move
                if
                  self._ownMoves[
                    key --[[@as string]]
                  ] == nil
                then
                  self._ownMoves[
                    key --[[@as string]]
                  ] = entry.name --[[@as string]]
                end
              end
            end
          end
        end
      end
    end
  end
end

---@param record table<string, unknown> model battler record under display
---@return table<string, unknown> displayed facts for one battler
local function displayedOf(record)
  return {
    combatant = record.combatant,
    side = record.side,
    hp = record.hp,
    maxHp = record.maxHp,
    visible = true,
    name = record.name,
    level = record.level,
    species = record.species,
    form = record.form,
    exp = record.experience,
    condition = record.condition,
    moves = copyValue(record.moves),
  }
end

-- Installs the opening displayed facts from the first detached view:
-- every listed battler shown at its exact health, player side first.
---@param view table<string, unknown> detached opening dynamic view
function BattleTimeline:reset(view)
  assert(type(view) == "table", "the cue player opens from its view")
  self._battlers = {}
  self._order = {}
  local function active(record)
    return record.active ~= false
  end
  local function installActive(records)
    if type(records) ~= "table" then
      return
    end
    for _, record in ipairs(records) do
      if type(record) == "table" and type(record.combatant) == "number" and active(record) then
        local id = record.combatant --[[@as integer]]
        if self._battlers[id] == nil then
          self._battlers[id] = displayedOf(record --[[@as table<string, unknown>]])
          self._order[#self._order + 1] = id
        end
      end
    end
  end
  installActive(view.own)
  installActive(view.foes)
  indexFacts(self, view)
  self._latest = view
  self._queue = {}
  self._active = nil
end

---@param cue table<string, unknown>
local function enqueue(self, cue)
  cue.elapsed = 0
  cue.started = false
  self._queue[#self._queue + 1] = cue
end

---@param name string
local function emitSound(self, name)
  self._pendingSounds[#self._pendingSounds + 1] = name
  if self._sound ~= nil then
    self._sound(name)
  end
end

---@param text string narration wording under presentation
---@param ackable boolean true when the page waits for acknowledgement instead of holding
local function enqueueMessage(self, text, ackable)
  self._messageSeq = self._messageSeq + 1
  enqueue(self, {
    kind = "message",
    text = text,
    id = self._messageSeq,
    pages = paginate(text),
    page = 1,
    revealed = 0,
    hold = 0,
    ackable = ackable == true,
  })
end

---@param id integer combatant identity under display
---@return table<string, unknown>? displayed facts, nil when never shown
function BattleTimeline:_shown(id)
  return self._battlers[id]
end

---@param self BattleTimeline
---@param combatant integer combatant identity under lookup
---@return string visible name when a delivery named it, else a plain combatant fallback
local function combatName(self, combatant)
  local known = self._names[combatant]
  if type(known) == "string" then
    return known
  end
  return "combatant " .. tostring(combatant)
end

---@param self BattleTimeline
---@param combatant integer striking combatant under lookup
---@param move string move identity under lookup
---@return string display name when a view or the resolver named it, else the raw identity
local function moveName(self, combatant, move)
  local known = self._ownMoves[tostring(combatant) .. "\0" .. move]
  if type(known) == "string" then
    return known
  end
  -- Foe move sets never enter the views, so foe narration resolves
  -- through the borrowed catalog names when the screen threaded one.
  -- The raw identity stays the honest fallback, never a guessed name.
  if type(self._moveName) == "function" then
    local ok, name = pcall(self._moveName, move)
    if ok and type(name) == "string" and name ~= "" then
      return name
    end
  end
  return move
end

---@param self BattleTimeline
---@param move string move identity under ownership lookup
---@return integer? combatant identity owning the move, nil when no view named it
local function moveOwner(self, move)
  for key, _ in pairs(self._ownMoves) do
    local sep = key:find("\0", 1, true)
    if sep ~= nil and key:sub(sep + 1) == move then
      local owner = tonumber(key:sub(1, sep - 1))
      if type(owner) == "number" and owner % 1 == 0 then
        return owner --[[@as integer]]
      end
    end
  end
  return nil
end

---@param self BattleTimeline
---@param target integer damaged combatant under translation
---@param to integer checkpoint health under translation
local function enqueueHealth(self, target, to)
  local shown = self:_shown(target)
  local maxHp = to
  if shown ~= nil and type(shown.maxHp) == "number" then
    maxHp = shown.maxHp --[[@as integer]]
  end
  local pixels = BattleTimeline.HP_BAR_PIXELS
  if shown ~= nil and type(shown.hp) == "number" then
    pixels = math.abs(shown.hp --[[@as integer]] - to) * BattleTimeline.HP_BAR_PIXELS / math.max(1, maxHp)
  end
  local ticks = math.max(1, math.min(BattleTimeline.HP_MAX_TICKS, math.ceil(pixels)))
  enqueue(self, { kind = "hp", combatant = target, to = to, from = nil, duration = ticks, requiresImage = false })
end

---@param self BattleTimeline
---@param event table<string, unknown> sanitized kernel event under translation
local function translateStruck(self, event)
  local payload = event.payload --[[@as table<string, unknown>]]
  local target = payload.target --[[@as integer]]
  local attacker = nil
  for _, id in ipairs(self._order) do
    if id ~= target then
      local shown = self:_shown(id)
      if shown ~= nil and shown.visible ~= false then
        attacker = id
        break
      end
    end
  end
  local cause = event.cause --[[@as table<string, unknown>]]
  local moveKey = type(cause.key) == "string" and cause.key or "strike"
  local attackerName = attacker ~= nil and combatName(self, attacker) or "The foe"
  enqueueMessage(self, attackerName .. " used " .. moveName(self, attacker or -1, moveKey) .. "!", false)
  enqueue(self, {
    kind = "hit",
    combatant = target,
    duration = BattleTimeline.HIT_TICKS,
    requiresImage = self:_sideOf(target),
  })
  local after = event.after --[[@as table<string, unknown>]]
  local hp = after.hp --[[@as table<string, unknown>?]]
  if type(hp) == "table" and type(hp[target]) == "number" then
    enqueueHealth(self, target, hp[target] --[[@as integer]])
  end
end

---@param id integer
---@return string side image key for one combatant identity
function BattleTimeline:_sideOf(id)
  local shown = self:_shown(id)
  if shown ~= nil and shown.side == 1 then
    return "mon:player:back"
  end
  return "mon:enemy:front"
end

---@param self BattleTimeline
---@param event table<string, unknown> sanitized kernel event under translation
local function translateFaint(self, event)
  local payload = event.payload --[[@as table<string, unknown>]]
  local target = payload.combatant --[[@as integer]]
  enqueueMessage(self, combatName(self, target) .. " fainted!", false)
  enqueue(self, {
    kind = "faint",
    combatant = target,
    duration = BattleTimeline.VANISH_TICKS,
    requiresImage = self:_sideOf(target),
  })
end

---@param view table<string, unknown>? detached view carrying progression facts
---@param combatant integer combatant identity under lookup
---@return integer experience, integer? level
local function progressionOf(view, combatant)
  if type(view) == "table" and type(view.own) == "table" then
    for _, record in ipairs(view.own) do
      if type(record) == "table" and record.combatant == combatant then
        local exp = record.experience
        local level = record.level
        if type(exp) == "number" then
          local total = exp --[[@as integer]]
          local tier = (type(level) == "number" and level or nil) --[[@as integer?]]
          return total, tier
        end
      end
    end
  end
  return 0, nil
end

---@param self BattleTimeline
---@param event table<string, unknown> sanitized kernel event under translation
---@param packet table<string, unknown> delivery carrying the before and after views
local function translateExp(self, event, packet)
  local payload = event.payload --[[@as table<string, unknown>]]
  local target = payload.combatant --[[@as integer]]
  local gained = payload.gained --[[@as integer]]
  if type(gained) ~= "number" then
    gained = 0
  end
  local _, beforeLevel = progressionOf(packet.before, target)
  local afterExp, afterLevel = progressionOf(packet.after, target)
  enqueueMessage(self, combatName(self, target) .. " gained " .. tostring(gained) .. " EXP points!", false)
  enqueue(self, {
    kind = "exp",
    combatant = target,
    targetExp = afterExp,
    targetLevel = afterLevel or beforeLevel,
    startExp = nil,
    startLevel = nil,
    duration = nil,
  })
end

---@param self BattleTimeline
---@param event table<string, unknown> sanitized kernel event under translation
---@param packet table<string, unknown> delivery carrying the before and after views
local function translateStats(self, event, packet)
  local payload = event.payload --[[@as table<string, unknown>]]
  local target = payload.combatant --[[@as integer]]
  local _, beforeLevel = progressionOf(packet.before, target)
  local _, afterLevel = progressionOf(packet.after, target)
  if beforeLevel ~= nil and afterLevel ~= nil and afterLevel > beforeLevel then
    enqueueMessage(self, combatName(self, target) .. " grew to level " .. tostring(afterLevel) .. "!", false)
    enqueue(self, { kind = "wait", duration = BattleTimeline.MESSAGE_HOLD_TICKS })
  end
  -- A stat recompute without a visible change carries no presentation:
  -- the experience cue already showed the bar motion.
end

---@param self BattleTimeline
---@param target integer combatant identity under checkpoint lookup
---@param event table<string, unknown> sanitized kernel event carrying its event-time checkpoint
local function enqueueCheckpointHealth(self, target, event)
  local after = event.after --[[@as table<string, unknown>]]
  local hp = after.hp --[[@as table<string, unknown>?]]
  if type(hp) == "table" and type(hp[target]) == "number" then
    enqueueHealth(self, target, hp[target] --[[@as integer]])
  end
end

---@param self BattleTimeline
---@param event table<string, unknown> sanitized kernel event under translation
local function translateFainted(self, event)
  local payload = event.payload --[[@as table<string, unknown>]]
  -- Self-inflicted knockouts (Memento and its kin) address their victim
  -- as the move target rather than the faint owner.
  local target = payload.target
  if type(target) ~= "number" then
    target = payload.combatant
  end
  if type(target) ~= "number" then
    return
  end
  enqueueMessage(self, combatName(self, target --[[@as integer]]) .. " fainted!", false)
  enqueue(self, {
    kind = "faint",
    combatant = target,
    duration = BattleTimeline.VANISH_TICKS,
    requiresImage = self:_sideOf(target),
  })
end

---@param self BattleTimeline
---@param event table<string, unknown> sanitized kernel event under translation
local function translateMoveUsed(self, event)
  local payload = event.payload --[[@as table<string, unknown>]]
  local cause = event.cause --[[@as table<string, unknown>]]
  local moveKey = type(cause.key) == "string" and cause.key or "strike"
  local user = payload.user
  if type(user) ~= "number" then
    user = moveOwner(self, moveKey)
  end
  local userName = type(user) == "number" and combatName(self, user --[[@as integer]]) or "The foe"
  enqueueMessage(self, userName .. " used " .. moveName(self, user or -1, moveKey) .. "!", false)
end

-- Every remaining kernel event kind the native session actually emits
-- receives its intentional treatment here. Accounting-only events stay
-- silent; everything else narrates, moves health, or changes
-- visibility. Kinds outside this table are genuinely unknown and keep
-- the explicit diagnostic instead of vanishing.
---@param self BattleTimeline
---@param event table<string, unknown> sanitized kernel event under translation
---@param packet table<string, unknown> delivery carrying the before and after views
local function translateOther(self, event, packet)
  local kind = event.kind --[[@as string]]
  local payload = event.payload --[[@as table<string, unknown>]]
  if kind == "flee" then
    local target = payload.combatant
    local who = type(target) == "number" and combatName(self, target --[[@as integer]]) or "The battler"
    if payload.escaped == true then
      -- The terminal result owns the successful-escape narration; the
      -- event itself only yields its moment in order.
      enqueue(self, { kind = "wait", duration = BattleTimeline.HIT_TICKS })
    else
      enqueueMessage(self, who .. " could not escape!", false)
    end
  elseif kind == "missed" then
    enqueueMessage(self, "The attack missed!", false)
  elseif kind == "move-used" then
    translateMoveUsed(self, event)
  elseif kind == "status" then
    local target = payload.target
    local who = type(target) == "number" and combatName(self, target --[[@as integer]]) or "The battler"
    enqueueMessage(self, who .. " was afflicted with " .. tostring(payload.key) .. ".", false)
  elseif kind == "cured" then
    local target = payload.target
    local who = type(target) == "number" and combatName(self, target --[[@as integer]]) or "The battler"
    enqueueMessage(self, who .. " recovered from " .. tostring(payload.key) .. ".", false)
  elseif kind == "stage" then
    local target = payload.target
    local who = type(target) == "number" and combatName(self, target --[[@as integer]]) or "The battler"
    local before = payload.before
    local after = payload.after
    local stat = tostring(payload.stat)
    if type(before) == "number" and type(after) == "number" and after ~= before then
      local direction = after > before and "rose" or "fell"
      enqueueMessage(self, who .. "'s " .. stat .. " " .. direction .. ".", false)
    else
      enqueueMessage(self, who .. " felt the effect.", false)
    end
  elseif kind == "healed" then
    local target = payload.target
    if type(target) == "number" then
      enqueueMessage(self, combatName(self, target --[[@as integer]]) .. " regained health.", false)
      enqueueCheckpointHealth(self, target --[[@as integer]], event)
    end
  elseif kind == "tick" then
    local target = payload.combatant
    if type(target) == "number" then
      local who = combatName(self, target --[[@as integer]])
      enqueueMessage(self, who .. " is hurt by " .. tostring(payload.key) .. ".", false)
      enqueueCheckpointHealth(self, target --[[@as integer]], event)
    end
  elseif kind == "recoil" then
    local target = payload.target
    if type(target) == "number" then
      enqueueMessage(self, combatName(self, target --[[@as integer]]) .. " was hurt by recoil.", false)
      enqueueCheckpointHealth(self, target --[[@as integer]], event)
    end
  elseif kind == "drained" then
    local target = payload.target
    if type(target) == "number" then
      enqueueMessage(self, combatName(self, target --[[@as integer]]) .. " absorbed health.", false)
      enqueueCheckpointHealth(self, target --[[@as integer]], event)
    end
  elseif kind == "fainted" then
    translateFainted(self, event)
  elseif kind == "leveled" then
    local target = payload.target
    if type(target) == "number" then
      enqueueMessage(self, combatName(self, target --[[@as integer]]) .. "'s health was evened out.", false)
      enqueueCheckpointHealth(self, target --[[@as integer]], event)
    end
  elseif kind == "item" then
    local item = payload.item
    enqueueMessage(self, "Used " .. tostring(type(item) == "string" and item or "an item") .. ".", false)
  elseif kind == "learn" then
    local target = payload.combatant
    local who = type(target) == "number" and combatName(self, target --[[@as integer]]) or "The battler"
    local move = type(payload.move) == "string" and payload.move or "a move"
    enqueueMessage(self, who .. " learned " .. moveName(self, target or -1, move --[[@as string]]) .. "!", false)
  elseif kind == "declined" then
    local target = payload.combatant
    local who = type(target) == "number" and combatName(self, target --[[@as integer]]) or "The battler"
    local move = type(payload.move) == "string" and payload.move or "a move"
    enqueueMessage(self, who .. " did not learn " .. moveName(self, target or -1, move --[[@as string]]) .. ".", false)
  elseif kind == "charged" then
    local target = payload.target
    local who = type(target) == "number" and combatName(self, target --[[@as integer]]) or "The battler"
    enqueueMessage(self, who .. " began to charge.", false)
  elseif kind == "delayed" then
    local target = payload.target
    local who = type(target) == "number" and combatName(self, target --[[@as integer]]) or "The battler"
    enqueueMessage(self, "An attack was foretold for " .. who .. ".", false)
  elseif kind == "protected" then
    local target = payload.target
    local who = type(target) == "number" and combatName(self, target --[[@as integer]]) or "The battler"
    enqueueMessage(self, who .. " protected itself.", false)
  elseif kind == "transformed" then
    local target = payload.target
    local who = type(target) == "number" and combatName(self, target --[[@as integer]]) or "The battler"
    local copied = payload.copiedFrom
    if type(copied) == "number" then
      enqueueMessage(self, who .. " transformed into " .. combatName(self, copied --[[@as integer]]) .. "!", false)
    else
      enqueueMessage(self, who .. " transformed.", false)
    end
  elseif kind == "sketched" then
    local target = payload.target
    local who = type(target) == "number" and combatName(self, target --[[@as integer]]) or "The battler"
    local move = type(payload.copied) == "string" and payload.copied or "a move"
    enqueueMessage(self, who .. " sketched " .. moveName(self, target or -1, move --[[@as string]]) .. ".", false)
  elseif kind == "switch" then
    -- Replacements name their departure and arrival combatants; older
    -- shapes named a withdrawing battler plus its incoming record.
    local departed = payload.from
    if type(departed) ~= "number" then
      departed = payload.combatant
    end
    if type(departed) == "number" then
      enqueueMessage(self, combatName(self, departed --[[@as integer]]) .. " was withdrawn.", false)
      enqueue(self, {
        kind = "withdraw",
        combatant = departed,
        duration = BattleTimeline.VANISH_TICKS,
        requiresImage = self:_sideOf(departed),
      })
    end
    local incoming = payload.to
    if type(incoming) ~= "number" then
      incoming = payload.replacement
    end
    if type(incoming) ~= "number" then
      incoming = payload.incoming
    end
    if type(incoming) == "number" then
      enqueue(self, {
        kind = "reveal",
        combatant = incoming --[[@as integer]],
        duration = BattleTimeline.VANISH_TICKS,
        requiresImage = self:_sideOf(incoming --[[@as integer]]),
      })
    end
  elseif kind == "status-gate" then
    local target = payload.combatant
    local who = type(target) == "number" and combatName(self, target --[[@as integer]]) or "The battler"
    local key = tostring(payload.key)
    local outcome = payload.outcome
    if outcome == "woke" then
      enqueueMessage(self, who .. " woke up.", false)
    elseif outcome == "thawed" then
      enqueueMessage(self, who .. " thawed out.", false)
    elseif key == "sleep" then
      enqueueMessage(self, who .. " is fast asleep.", false)
    elseif key == "paralysis" then
      enqueueMessage(self, who .. " is paralyzed and cannot move.", false)
    elseif key == "freeze" then
      enqueueMessage(self, who .. " is frozen solid.", false)
    else
      enqueueMessage(self, who .. " cannot move.", false)
    end
  elseif kind == "item-intent" or kind == "switch-intent" then
    -- Forcing and item moves narrate through their target: any
    -- following switch event owns the withdrawal/reveal presentation.
    local target = payload.target
    local who = type(target) == "number" and combatName(self, target --[[@as integer]]) or "The battler"
    local cause = event.cause --[[@as table<string, unknown>]]
    local moveKey = type(cause.key) == "string" and cause.key or "strike"
    enqueueMessage(self, who .. " was hit by " .. moveName(self, target or -1, moveKey) .. ".", false)
  elseif kind == "substitute-broke" then
    local target = payload.target
    local who = type(target) == "number" and combatName(self, target --[[@as integer]]) or "The battler"
    enqueueMessage(self, who .. "'s substitute broke.", false)
  elseif kind == "acknowledge" then
    -- Pure action bookkeeping with no observable change: the matching
    -- strike, switch, item, or flee event already carries the moment.
  elseif kind == "join" then
    -- Reserve arrivals outside the replacement switch path still reveal
    -- their battler; any withdrawal narration belongs to the switch.
    local incoming = payload.combatant
    if type(incoming) == "number" then
      enqueue(self, {
        kind = "reveal",
        combatant = incoming --[[@as integer]],
        duration = BattleTimeline.VANISH_TICKS,
        requiresImage = self:_sideOf(incoming --[[@as integer]]),
      })
    end
  else
    local note = "unrepresentable effect: " .. kind
    self._diagnostics[#self._diagnostics + 1] = note
    enqueueMessage(self, "Something unrepresentable happened (" .. kind .. ").", false)
  end
  local _ = packet
end

-- Accepts one delivery packet in order: unseen identities translate
-- their events into cues behind the retained final facts; a repeated
-- identity is rejected without touching state.
---@param packet table<string, unknown> detached delivery packet
---@return boolean accepted
function BattleTimeline:present(packet)
  assert(type(packet) == "table", "the cue player consumes delivery packets")
  local id = packet.packetId --[[@as integer]]
  assert(type(id) == "number" and id % 1 == 0 and id >= 1, "delivery packets carry a monotonic identity")
  if id <= self._lastPacketId then
    return false
  end
  self._lastPacketId = id
  indexFacts(self, packet.before)
  if type(packet.after) == "table" then
    self._latest = packet.after
  end
  indexFacts(self, packet.after)
  if type(packet.events) == "table" then
    for _, event in ipairs(packet.events) do
      if type(event) == "table" and type(event.kind) == "string" then
        local kind = event.kind --[[@as string]]
        if kind == "struck" then
          translateStruck(self, event --[[@as table<string, unknown>]])
        elseif kind == "faint" then
          translateFaint(self, event --[[@as table<string, unknown>]])
        elseif kind == "exp" then
          translateExp(self, event --[[@as table<string, unknown>]], packet)
        elseif kind == "stats" then
          translateStats(self, event --[[@as table<string, unknown>]], packet)
        else
          translateOther(self, event --[[@as table<string, unknown>]], packet)
        end
      end
    end
  end
  return true
end

-- Queues the opening presentation: enemy cry and encounter narration,
-- then the player send-out with its cry. Both battlers are already
-- shown; the send-out cue holds on the missing back image instead of
-- skipping ahead.
---@param view table<string, unknown> detached opening dynamic view
---@param wild boolean true for a wild encounter, false for a trainer challenge
function BattleTimeline:intro(view, wild)
  assert(type(view) == "table", "the opening needs its view")
  indexFacts(self, view)
  self._latest = view
  local foeName = "The foe"
  local ownName = "Go"
  local ownSpecies = nil
  if type(view.foes) == "table" and type(view.foes[1]) == "table" then
    local foe = view.foes[1] --[[@as table<string, unknown>]]
    if type(foe.name) == "string" then
      foeName = foe.name --[[@as string]]
    end
  end
  if type(view.own) == "table" and type(view.own[1]) == "table" then
    local own = view.own[1] --[[@as table<string, unknown>]]
    if type(own.name) == "string" then
      ownName = own.name --[[@as string]]
    end
    if type(own.species) == "string" then
      ownSpecies = own.species --[[@as string]]
    end
  end
  -- The encounter narration shows the real active enemy; the one cry
  -- belongs to the player send-out beside its back image, so
  -- same-species pairings keep one sound identity per cue start.
  if wild then
    enqueueMessage(self, "Wild " .. foeName .. " appeared!", false)
  else
    enqueueMessage(self, "The foe wants to battle!", false)
  end
  -- The send-out cry names the real lead; without one no cry queues
  -- rather than a guessed species call.
  if type(ownSpecies) == "string" then
    enqueue(self, { kind = "sound", name = "cry:" .. ownSpecies, duration = 0 })
  end
  local sendOut = {
    kind = "message",
    text = "Go! " .. ownName .. "!",
    id = self._messageSeq + 1,
    pages = {},
    page = 1,
    revealed = 0,
    hold = 0,
    ackable = false,
    requiresImage = "mon:player:back",
  }
  self._messageSeq = self._messageSeq + 1
  sendOut.pages = paginate(sendOut.text --[[@as string]])
  sendOut.elapsed = 0
  sendOut.started = false
  self._queue[#self._queue + 1] = sendOut
end

---@param cue table<string, unknown>
---@param isAvailable (fun(key: string): boolean)? image availability probe
---@return boolean true when the cue may tick under the available images
local function cueReady(cue, isAvailable)
  local key = cue.requiresImage
  if type(key) == "string" and isAvailable ~= nil and not isAvailable(key) then
    return false
  end
  return true
end

---@param self BattleTimeline
---@param cue table<string, unknown> cue consuming its first tick
local function startCue(self, cue)
  cue.started = true
  if cue.kind == "sound" then
    emitSound(self, cue.name --[[@as string]])
  elseif cue.kind == "message" then
    self._message = cue.pages[1] or ""
    self._messageId = cue.id --[[@as integer]]
  elseif cue.kind == "hp" and cue.from == nil then
    local shown = self:_shown(cue.combatant --[[@as integer]])
    cue.from = (shown ~= nil and type(shown.hp) == "number") and shown.hp or cue.to
  elseif cue.kind == "exp" and cue.startExp == nil then
    local shown = self:_shown(cue.combatant --[[@as integer]])
    cue.startExp = (shown ~= nil and type(shown.exp) == "number") and shown.exp or cue.targetExp
    cue.startLevel = (shown ~= nil and type(shown.level) == "number") and shown.level or cue.targetLevel
    local segments = 1
    if type(cue.targetLevel) == "number" and type(cue.startLevel) == "number" and cue.targetLevel > cue.startLevel then
      segments = cue.targetLevel - cue.startLevel
    end
    cue.segments = segments
    cue.duration = BattleTimeline.EXP_TICKS_PER_SEGMENT * segments
  elseif cue.kind == "reveal" then
    self:_installReveal(cue.combatant --[[@as integer]])
  end
end

---@param id integer incoming combatant identity under reveal
function BattleTimeline:_installReveal(id)
  -- A new activation clears its transient pose and starts hidden; the
  -- reveal cue shows it at completion from the newest known facts.
  local record = nil
  if self._latest ~= nil then
    for _, group in ipairs({ self._latest.own, self._latest.foes }) do
      if type(group) == "table" then
        for _, entry in ipairs(group) do
          if type(entry) == "table" and entry.combatant == id then
            record = entry
          end
        end
      end
    end
  end
  if record ~= nil then
    self._battlers[id] = displayedOf(record --[[@as table<string, unknown>]])
    self._battlers[id].visible = false
    local seen = false
    for _, known in ipairs(self._order) do
      if known == id then
        seen = true
      end
    end
    if not seen then
      self._order[#self._order + 1] = id
    end
  elseif self._battlers[id] ~= nil then
    self._battlers[id].visible = false
  end
end

---@param self BattleTimeline
---@param cue table<string, unknown> narration cue under reveal
---@return boolean finished
local function tickMessage(self, cue)
  local pages = cue.pages --[[@as string[] ]]
  local page = pages[
    cue.page --[[@as integer]] or 1
  ] or ""
  -- The reveal counts glyphs so a multibyte name never shows a torn
  -- codepoint mid-reveal.
  local glyphs = {}
  for char in Utf8Glyphs.iter(page) do
    glyphs[#glyphs + 1] = char
  end
  cue.glyphTotal = #glyphs
  local speed = REVEAL.interGlyphDelay
  local full = #glyphs
  local target = full
  if speed > 0 then
    target = math.min(full, math.floor(cue.elapsed --[[@as integer]] / speed) + 1)
  end
  -- A fast-forwarded reveal persists: an accelerated page never
  -- collapses back into its typewriter run on the next tick, so the
  -- following edge can turn the page instead of accelerating again.
  local shown = cue.revealedCount
  if type(shown) == "number" and shown > target then
    target = math.min(full, shown)
  end
  if
    cue.revealed ~= true
    and cue.elapsed --[[@as integer]]
      == 0
  then
    cue.revealedCount = 0
  end
  cue.revealedCount = target
  self._message = table.concat(glyphs, "", 1, target)
  self._messageId = cue.id --[[@as integer]]
  if target < full then
    return false
  end
  if
    cue.page --[[@as integer]]
    < #pages
  then
    -- An acknowledged page turns only on its explicit edge; ordinary
    -- narration still turns on its hold so pacing never waits.
    if cue.ackable == true then
      return false
    end
    cue.hold = (cue.hold or 0) + 1
    if cue.hold >= BattleTimeline.MESSAGE_HOLD_TICKS then
      cue.page = cue.page --[[@as integer]] + 1
      cue.hold = 0
    end
    return false
  end
  if cue.ackable == true then
    -- A fully revealed terminal page holds until its explicit final
    -- acknowledgment; glyph completion alone never releases it.
    return cue.acknowledged == true
  end
  cue.hold = (cue.hold or 0) + 1
  return cue.hold >= BattleTimeline.MESSAGE_HOLD_TICKS
end

---@param self BattleTimeline
---@param cue table<string, unknown> active cue under advancement
---@return boolean finished
local function tickCue(self, cue)
  if cue.kind == "message" then
    return tickMessage(self, cue)
  elseif cue.kind == "sound" then
    return true
  elseif cue.kind == "wait" then
    local elapsed = cue.elapsed --[[@as integer]]
    local duration = cue.duration --[[@as integer]]
    return elapsed >= duration
  elseif cue.kind == "hp" then
    local shown = self:_shown(cue.combatant --[[@as integer]])
    local from = cue.from --[[@as integer]]
    local to = cue.to --[[@as integer]]
    local duration = cue.duration --[[@as integer]]
    local progress = math.min(1, cue.elapsed --[[@as integer]] / math.max(1, duration))
    local value = from + math.floor((to - from) * progress + 0.5)
    if
      cue.elapsed --[[@as integer]]
      >= duration
    then
      value = to
    end
    if shown ~= nil then
      shown.hp = value
    end
    return cue.elapsed --[[@as integer]] >= duration
  elseif cue.kind == "hit" then
    return cue.elapsed --[[@as integer]] >= BattleTimeline.HIT_TICKS
  elseif cue.kind == "faint" or cue.kind == "withdraw" then
    if
      cue.elapsed --[[@as integer]]
      >= BattleTimeline.VANISH_TICKS
    then
      local shown = self:_shown(cue.combatant --[[@as integer]])
      if shown ~= nil then
        shown.visible = false
      end
      return true
    end
    return false
  elseif cue.kind == "reveal" then
    if
      cue.elapsed --[[@as integer]]
      >= BattleTimeline.VANISH_TICKS
    then
      local shown = self:_shown(cue.combatant --[[@as integer]])
      if shown ~= nil then
        shown.visible = true
      end
      return true
    end
    return false
  elseif cue.kind == "exp" then
    local shown = self:_shown(cue.combatant --[[@as integer]])
    local duration = cue.duration or BattleTimeline.EXP_TICKS_PER_SEGMENT
    local segments = cue.segments or 1
    local progress = math.min(1, cue.elapsed --[[@as integer]] / math.max(1, duration --[[@as integer]]))
    local startExp = cue.startExp --[[@as integer]]
    local targetExp = cue.targetExp --[[@as integer]]
    local startLevel = cue.startLevel --[[@as integer]]
    local targetLevel = cue.targetLevel --[[@as integer]]
    if type(startExp) ~= "number" or type(targetExp) ~= "number" then
      return cue.elapsed --[[@as integer]] >= duration
    end
    -- Each represented level segment animates its own share and resets
    -- at its boundary; the shares are display interpolation while the
    -- final facts stay exact.
    local segmentFloat = math.min(segments, progress * segments)
    local whole = math.floor(segmentFloat)
    local fraction = segmentFloat - whole
    local share = (targetExp - startExp) / math.max(1, segments)
    local value = startExp + whole * share + fraction * share
    if progress >= 1 then
      value = targetExp
    end
    if shown ~= nil then
      shown.exp = math.floor(value + 0.5)
      if type(startLevel) == "number" and type(targetLevel) == "number" then
        shown.level = math.min(targetLevel, startLevel + whole + (fraction > 0 and 1 or 0))
        if progress >= 1 then
          shown.level = targetLevel
        end
      end
    end
    return progress >= 1
  end
  return true
end

-- Advances the player by accepted presentation seconds. Only whole
-- sixtieth ticks run cues, one cue at a time; a cue needing an
-- unavailable image holds the clock without advancing.
---@param dt number accepted presentation seconds
---@param isAvailable (fun(key: string): boolean)? image availability probe, all available when absent
function BattleTimeline:update(dt, isAvailable)
  assert(type(dt) == "number" and dt == dt and dt >= 0, "the cue player advances on accepted seconds")
  self._accum = self._accum + dt
  local step = 1 / BattleTimeline.TICKS_PER_SECOND
  while self._accum >= step do
    if self._active == nil then
      local next = self._queue[1]
      if next == nil then
        self._accum = 0
        break
      end
      if not cueReady(next, isAvailable) then
        self._accum = 0
        break
      end
      table.remove(self._queue, 1)
      self._active = next
      startCue(self, next)
      if next.kind == "sound" then
        self._active = nil
      else
        self._accum = self._accum - step
        next.elapsed = (next.elapsed or 0) + 1
        if tickCue(self, next) then
          self._active = nil
        end
      end
    else
      local current = assert(self._active, "advancement consumes its active cue")
      if not cueReady(current, isAvailable) then
        self._accum = 0
        break
      end
      self._accum = self._accum - step
      local elapsed = current.elapsed
      assert(type(elapsed) == "number", "active cues carry their elapsed ticks")
      current.elapsed = elapsed + 1
      if tickCue(self, current) then
        self._active = nil
      end
    end
  end
end

-- Completes the revealed page (or advances to the next one) for an
-- acknowledgement edge. The edge is always consumed while narration is
-- active so it never leaks into command input. An edge that finishes a
-- running reveal never acknowledges in the same edge; only an edge on a
-- fully revealed final ackable page reports its completion.
---@return boolean consumed
---@return boolean completedFinalPage true exactly on the explicit final-page acknowledgment
function BattleTimeline:ack()
  local current = self._active
  if current == nil then
    -- An edge arriving before the clock starts its narration still
    -- belongs to that page when the page is already queued first.
    local head = self._queue[1]
    if head == nil or head.kind ~= "message" then
      return false, false
    end
    table.remove(self._queue, 1)
    self._active = head
    startCue(self, head)
    current = head
  end
  if current.kind ~= "message" then
    return false, false
  end
  local pages = current.pages --[[@as string[] ]]
  local page = pages[
    current.page --[[@as integer]] or 1
  ] or ""
  local total = current.glyphTotal
  if type(total) ~= "number" then
    total = 0
    for _ in Utf8Glyphs.iter(page) do
      total = total + 1
    end
  end
  if (current.revealedCount or 0) < total then
    current.revealedCount = total
    self._message = page
    return true, false
  end
  if
    current.page --[[@as integer]]
    < #pages
  then
    current.page = current.page --[[@as integer]] + 1
    current.hold = 0
    current.revealedCount = 0
    return true, false
  end
  if current.ackable == true then
    -- The same edge never both accelerates and acknowledges: arrival
    -- here means the final page was already fully revealed, so this
    -- edge is the explicit acknowledgment. A repeated edge on an
    -- already acknowledged page consumes without completing again.
    if current.acknowledged == true then
      return true, false
    end
    current.acknowledged = true
    return true, true
  end
  current.hold = BattleTimeline.MESSAGE_HOLD_TICKS
  return true, false
end

---@return boolean true when no cue is waiting or consuming ticks
function BattleTimeline:settled()
  return self._active == nil and #self._queue == 0
end

---@return boolean true while a cue is waiting or consuming ticks
function BattleTimeline:busy()
  return self._active ~= nil or #self._queue > 0
end

---@return table<integer, table<string, unknown>> displayed battler facts, player side first
function BattleTimeline:battlers()
  local out = {}
  for _, id in ipairs(self._order) do
    local shown = self._battlers[id]
    if shown ~= nil then
      out[#out + 1] = copyValue(shown)
    end
  end
  return out
end

---@return string currently displayed narration page, possibly empty
function BattleTimeline:message()
  return self._message
end

---@return integer stable identity of the displayed narration
function BattleTimeline:messageId()
  return self._messageId
end

---@param id integer combatant identity under recoil
---@return integer horizontal logical-pixel displacement for the current tick
function BattleTimeline:shake(id)
  local current = self._active
  if current == nil or current.kind ~= "hit" or current.combatant ~= id then
    return 0
  end
  local step = (current.elapsed or 1) % BattleTimeline.HIT_TICKS
  local pattern = { 0, 1, 2, 1, 0, 0 }
  local offset = pattern[step + 1] or 0
  if offset > BattleTimeline.HIT_DISPLACEMENT then
    offset = BattleTimeline.HIT_DISPLACEMENT
  end
  return offset
end

---@return string[] recorded unknown-effect occurrences
function BattleTimeline:diagnostics()
  return copyValue(self._diagnostics) --[[@as string[] ]]
end

-- Queues one product-owned narration page outside event translation:
-- the opening encounter, send-out, and terminal result texts.
---@param text string narration wording under presentation
---@param ackable boolean true when the page waits for acknowledgement instead of holding
---@return integer stable narration identity
function BattleTimeline:announce(text, ackable)
  assert(type(text) == "string" and text ~= "", "announced narration carries its wording")
  self._messageSeq = self._messageSeq + 1
  local id = self._messageSeq
  enqueue(self, {
    kind = "message",
    text = text,
    id = id,
    pages = paginate(text),
    page = 1,
    revealed = 0,
    hold = 0,
    ackable = ackable == true,
  })
  return id
end

-- Drains the queued one-shot sound intents in order. Playback
-- availability never gates a cue; the screen routes each intent to its
-- audio boundary and drops the results.
---@return string[] sound names in cue-start order
function BattleTimeline:drainSounds()
  local sounds = self._pendingSounds
  self._pendingSounds = {}
  return sounds
end

---@return integer[] player-first combatant identities known to the player
function BattleTimeline:order()
  return copyValue(self._order) --[[@as integer[] ]]
end

-- Reconciles one final-view battler record: exact numbers always,
-- visibility never. Hidden battlers stay hidden until an explicit
-- reveal; unknown activations install hidden.
---@param record table<string, unknown> detached final-view battler record
---@param known boolean true when the identity already plays
function BattleTimeline:reconcileBattler(record, known)
  local id = record.combatant --[[@as integer]]
  if known and self._battlers[id] ~= nil then
    local shown = self._battlers[id] --[[@as table<string, unknown>]]
    shown.hp = record.hp
    shown.maxHp = record.maxHp
    shown.name = record.name
    shown.level = record.level
    shown.exp = record.experience
    shown.condition = record.condition
    shown.moves = copyValue(record.moves)
  elseif not known then
    self._battlers[id] = displayedOf(record)
    self._battlers[id].visible = false
    local seen = false
    for _, knownId in ipairs(self._order) do
      if knownId == id then
        seen = true
      end
    end
    if not seen then
      self._order[#self._order + 1] = id
    end
  end
end

return BattleTimeline
