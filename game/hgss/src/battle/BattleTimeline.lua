local BattleAudio = require("libs.hgss.src.audio.BattleAudio")

-- Bounded visible-cue player for one battle launch. Translates the
-- detached delivery packets of the battle runtime into an ordered queue
-- of small typed cues (messages, health interpolation, hit recoil,
-- fainting, withdrawal, reveal, experience, waits, one-shot sounds) over
-- a displayed-state model, advanced only by accepted presentation time
-- at thirty ticks per second. The screen feeds packets in, ticks the
-- clock, and reads the displayed facts; drawing and input never advance
-- it. Unknown required effects play an explicit diagnostic cue instead
-- of vanishing. Message wording here is product-owned interim narration,
-- never a claim about original-game sentences.

local TextSpeedPolicy = require("libs.hgss.src.ui.TextSpeedPolicy")
local Utf8Glyphs = require("libs.assets.src.Utf8Glyphs")

---@class BattleTimeline
---@field _pendingSounds table<integer, table<string, unknown>> queued one-shot sound cues for the screen drain
---@field _battlers table<integer, table<string, unknown>> displayed facts by combatant identity
---@field _order integer[] player-first combatant identities for view order
---@field _queue table<integer, table<string, unknown>> ordered unplayed cues
---@field _active table<string, unknown>? cue consuming ticks
---@field _message string currently displayed narration page
---@field _messageId integer stable identity of the displayed narration
---@field _messageSeq integer narration counter
---@field _lastPacketId integer highest accepted per-launch packet identity
---@field _seen table<string, boolean> played event identities by launch and sequence
---@field _latest table<string, unknown>? newest after view for name and move facts
---@field _names table<integer, string> visible names by combatant identity across packets
---@field _ownMoves table<string, string> own move display names by combatant and move identity
---@field _moveName (fun(move: string): string?)? borrowed move display-name resolver for foe narration
---@field _revealPolicy { interGlyphDelay: integer, glyphBudget: integer, abAcceleration: boolean } per-launch narration cadence copied from the shared pace table
---@field _accum number fractional accepted seconds awaiting their tick
---@field _diagnostics string[] recorded unknown-effect occurrences
local BattleTimeline = {}
BattleTimeline.__index = BattleTimeline

BattleTimeline.TICKS_PER_SECOND = 30
BattleTimeline.MESSAGE_HOLD_TICKS = 12
BattleTimeline.HIT_TICKS = 6
BattleTimeline.HIT_DISPLACEMENT = 2
BattleTimeline.VANISH_TICKS = 12
BattleTimeline.EXP_TICKS_PER_SEGMENT = 24
BattleTimeline.HP_BAR_PIXELS = 48
BattleTimeline.HP_MAX_TICKS = 30
BattleTimeline.PAGE_GLYPHS = 54

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
---@field sound (fun(cue: table<string, unknown>))? sound-cue sink, drained immediately when supplied
---@field moveName (fun(move: string): string?)? display-name resolver for move identities the views never name
---@field textSpeed string? narration pace for this launch, defaulting to the middle pace

---@param opts BattleTimeline.Options?
---@return BattleTimeline
function BattleTimeline.new(opts)
  opts = opts or {}
  assert(type(opts) == "table", "the cue player requires options")
  local revealPolicy = TextSpeedPolicy.forSpeed(opts.textSpeed or "mid")
  return setmetatable({
    _sound = opts.sound,
    _moveName = opts.moveName,
    _revealPolicy = revealPolicy,
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
    _seen = {},
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
  local shown = {
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
  -- The native slot identity rides the displayed record for live
  -- active battlers only: benched or historic records never claim a
  -- slot, and the model position stays opaque (keyed verbatim, never
  -- reinterpreted here).
  if record.active ~= false then
    if type(record.position) == "number" then
      shown.position = record.position
    end
    if type(record.activation) == "number" then
      shown.activation = record.activation
    end
  end
  if type(record.portraitSelector) == "string" and record.portraitSelector ~= "" then
    shown.portraitSelector = record.portraitSelector
  end
  -- Presentation-only picture facts ride the displayed record when the
  -- model answers them: gender and caught marks, the signed height
  -- displacement, and the substitute channel. Absent facts stay absent;
  -- the renderer defaults them.
  if record.gender == "male" or record.gender == "female" or record.gender == "genderless" then
    shown.gender = record.gender
  end
  if type(record.caught) == "boolean" then
    shown.caught = record.caught
  end
  if type(record.height) == "number" then
    shown.height = record.height
  end
  if record.substitute == true then
    shown.substitute = true
  end
  return shown
end

-- Loud slot coherence: every currently visible record claiming a native
-- slot must hold a whole slot identity, and no slot is ever visibly
-- claimed twice. Records without a slot (legacy singles fixtures) are
-- exempt; hidden, benched and historic records never claim.
---@param self BattleTimeline
local function checkSlotClaims(self)
  local claimed = {}
  for id, shown in pairs(self._battlers) do
    if type(shown) == "table" and shown.visible ~= false and type(shown.position) == "number" then
      local slot = shown.position --[[@as integer]]
      assert(slot % 1 == 0, "native slots are whole slot identities (combatant " .. tostring(id) .. ")")
      local other = claimed[slot]
      assert(
        other == nil,
        "native slot "
          .. tostring(slot)
          .. " is visibly claimed twice (combatants "
          .. tostring(other)
          .. " and "
          .. tostring(id)
          .. ")"
      )
      claimed[slot] = id
    end
  end
end

-- True while a queued or playing cue still owns the slot transition for
-- one combatant: withdrawal, reveal and faint cues gate position and
-- activation updates so reconciliation can never outrun them.
---@param self BattleTimeline
---@param id integer combatant identity under reconciliation
---@return boolean gated
local function slotGated(self, id)
  local function gates(cue)
    if type(cue) ~= "table" or cue.combatant ~= id then
      return false
    end
    return cue.kind == "withdraw" or cue.kind == "reveal" or cue.kind == "faint"
  end
  if gates(self._active) then
    return true
  end
  for _, cue in ipairs(self._queue) do
    if gates(cue) then
      return true
    end
  end
  return false
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
  checkSlotClaims(self)
  self._queue = {}
  self._active = nil
end

---@param cue table<string, unknown>
local function enqueue(self, cue)
  cue.elapsed = 0
  cue.started = false
  self._queue[#self._queue + 1] = cue
end

---@param cue table<string, unknown> typed one-shot sound cue under queueing
local function emitSound(self, cue)
  assert(type(cue) == "table" and type(cue.kind) == "string", "sound cues carry their typed kind")
  self._pendingSounds[#self._pendingSounds + 1] = cue
  if self._sound ~= nil then
    self._sound(cue)
  end
end

-- One staged effect cue behind battle flows.
---@param symbol string staged effect sequence symbol
---@return table<string, unknown> typed effect cue
local function effectCue(symbol)
  assert(type(symbol) == "string" and symbol ~= "", "effect cues name their staged symbol")
  return { kind = "effect", symbol = symbol }
end

-- One send-out cry cue for a battler: the view-carried species and
-- form with its player/foe side. The screen resolves the numeric cry
-- identity and the side mix convention at dispatch.
---@param species string view-carried species key
---@param form integer|nil view-carried form, nil reads as the species bank
---@param foe boolean true for the foe send-out, false for the player send-out
---@return table<string, unknown> typed cry cue
local function cryCue(species, form, foe)
  assert(type(species) == "string" and species ~= "", "cry cues name their view species")
  return { kind = "cry", species = species, form = form, foe = foe == true }
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

-- Forward declaration: explicit playback readers below fall back to the
-- cause identity owned further down beside the intent translators.
local causeMoveKey

---@param event table<string, unknown> sanitized kernel event carrying its explicit playback facts
---@return integer? combatant identity of the first named actor, nil for legacy emissions
local function explicitActor(event)
  local actors = event.actors --[[@as table<integer, unknown>?]]
  if type(actors) ~= "table" then
    return nil
  end
  local first = actors[1] --[[@as table<string, unknown>?]]
  if type(first) ~= "table" then
    return nil
  end
  local id = (first --[[@as table<string, unknown>]]).combatant
  if type(id) == "number" and id % 1 == 0 and id >= 1 then
    return id --[[@as integer]]
  end
  return nil
end

---@param event table<string, unknown> sanitized kernel event carrying its explicit playback facts
---@return integer? combatant identity of the first named target, nil for legacy emissions
local function explicitTarget(event)
  local targets = event.targets --[[@as table<integer, unknown>?]]
  if type(targets) ~= "table" then
    return nil
  end
  local first = targets[1] --[[@as table<string, unknown>?]]
  if type(first) ~= "table" then
    return nil
  end
  local id = (first --[[@as table<string, unknown>]]).combatant
  if type(id) == "number" and id % 1 == 0 and id >= 1 then
    return id --[[@as integer]]
  end
  return nil
end

---@param event table<string, unknown> sanitized kernel event carrying its explicit playback facts
---@return string executed move identity: explicit facts first, cause identity next
local function explicitMove(event)
  local move = event.move --[[@as table<string, unknown>?]]
  if type(move) == "table" and type(move.executed) == "string" then
    return move.executed --[[@as string]]
  end
  return causeMoveKey(event)
end

---@param self BattleTimeline
---@param event table<string, unknown> sanitized kernel event under translation
local function translateStruck(self, event)
  local payload = event.payload --[[@as table<string, unknown>]]
  -- Explicit playback facts name the true attacker and recipient;
  -- only legacy emissions without them fall back to display order.
  local target = explicitTarget(event)
  if target == nil and type(payload.target) == "number" then
    target = payload.target --[[@as integer]]
  end
  assert(type(target) == "number", "strikes name their recipient")
  local attacker = explicitActor(event)
  if attacker == nil then
    for _, id in ipairs(self._order) do
      if id ~= target then
        local shown = self:_shown(id)
        if shown ~= nil and shown.visible ~= false then
          attacker = id
          break
        end
      end
    end
  end
  local moveKey = explicitMove(event)
  local attackerName = attacker ~= nil and combatName(self, attacker) or "The foe"
  enqueueMessage(self, attackerName .. " used " .. moveName(self, attacker or -1, moveKey) .. "!", false)
  enqueue(self, {
    kind = "hit",
    combatant = target,
    duration = BattleTimeline.HIT_TICKS,
    requiresImage = self:_imageKeyFor(target),
  })
  -- Each damaging turn records its impact and effectiveness voices at
  -- the hit moment: the exact per-move route arrives with the native
  -- animation programs through this same sink, while the timing and
  -- ownership proof rides these staged battle-domain cues.
  enqueue(self, {
    kind = "sound",
    cue = effectCue(BattleAudio.SINK_SOUNDS.impact),
    duration = 0,
  })
  enqueue(self, {
    kind = "sound",
    cue = effectCue(BattleAudio.SINK_SOUNDS.effectiveness),
    duration = 0,
  })
  local after = event.after --[[@as table<string, unknown>]]
  local hp = after.hp --[[@as table<string, unknown>?]]
  if type(hp) == "table" and type(hp[target]) == "number" then
    enqueueHealth(self, target, hp[target] --[[@as integer]])
  end
end

---@param id integer combatant identity under image lookup
---@return string|boolean exact battler image key, or false when the battler carries no image demand
function BattleTimeline:_imageKeyFor(id)
  -- The cue gates on the displayed combatant's exact canonical
  -- portrait selector. A battler without one carries no image demand:
  -- nothing plausible stands in for its picture.
  local function selectorOf(record)
    if type(record) == "table" and type(record.portraitSelector) == "string" and record.portraitSelector ~= "" then
      return "mon:" .. record.portraitSelector
    end
    return nil
  end
  if self._latest ~= nil then
    for _, group in ipairs({ self._latest.own, self._latest.foes }) do
      if type(group) == "table" then
        for _, record in ipairs(group) do
          if type(record) == "table" and record.combatant == id then
            local key = selectorOf(record)
            if key ~= nil then
              return key
            end
          end
        end
      end
    end
  end
  local shown = self:_shown(id)
  local key = selectorOf(shown)
  if key ~= nil then
    return key
  end
  return false
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
    requiresImage = self:_imageKeyFor(target),
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
    enqueue(self, {
      kind = "sound",
      cue = effectCue(BattleAudio.SINK_SOUNDS.levelUp),
      duration = 0,
    })
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
    requiresImage = self:_imageKeyFor(target),
  })
end

---@param self BattleTimeline
---@param event table<string, unknown> sanitized kernel event under translation
local function translateMoveUsed(self, event)
  local payload = event.payload --[[@as table<string, unknown>]]
  local moveKey = explicitMove(event)
  local user = explicitActor(event)
  if user == nil and type(payload.user) == "number" then
    user = payload.user --[[@as integer]]
  end
  if user == nil then
    user = moveOwner(self, moveKey)
  end
  local userName = type(user) == "number" and combatName(self, user --[[@as integer]]) or "The foe"
  enqueueMessage(self, userName .. " used " .. moveName(self, user or -1, moveKey) .. "!", false)
end

---@param self BattleTimeline
---@param target unknown combatant identity from an event payload
---@return string
local function nameOrBattler(self, target)
  return type(target) == "number" and combatName(self, target --[[@as integer]]) or "The battler"
end

---@param event table<string, unknown> sanitized kernel event
---@return string
function causeMoveKey(event)
  local cause = event.cause --[[@as table<string, unknown>]]
  return type(cause.key) == "string" and cause.key or "strike"
end

---@param self BattleTimeline
---@param combatant integer combatant to reveal
local function enqueueReveal(self, combatant)
  enqueue(self, {
    kind = "reveal",
    combatant = combatant,
    duration = BattleTimeline.VANISH_TICKS,
    requiresImage = self:_imageKeyFor(combatant),
  })
end

-- Narrates one target-addressed event and follows it with the checkpoint
-- health motion; an event without a numeric target stays silent.
---@param field string payload field naming the target combatant
---@param suffix string narration appended to the target's name
---@return fun(self: BattleTimeline, event: table<string, unknown>)
local function hurtOrHealed(field, suffix)
  local function translate(self, event)
    local target = (event.payload --[[@as table<string, unknown>]])[field]
    if type(target) == "number" then
      enqueueMessage(self, combatName(self, target --[[@as integer]]) .. suffix, false)
      enqueueCheckpointHealth(self, target --[[@as integer]], event)
    end
  end
  return translate
end

-- Narrates a target-addressed event whose sentence is the target's name
-- followed by a fixed suffix.
---@param field string payload field naming the target combatant
---@param suffix string
---@return fun(self: BattleTimeline, event: table<string, unknown>)
local function targetMessage(field, suffix)
  local function translate(self, event)
    local target = (event.payload --[[@as table<string, unknown>]])[field]
    enqueueMessage(self, nameOrBattler(self, target) .. suffix, false)
  end
  return translate
end

---@param self BattleTimeline
---@param event table<string, unknown>
local function translateFlee(self, event)
  local payload = event.payload --[[@as table<string, unknown>]]
  if payload.escaped == true then
    -- The terminal result owns the successful-escape narration; the
    -- event itself yields its moment with the parting voice in order.
    enqueue(self, {
      kind = "sound",
      cue = effectCue(BattleAudio.SINK_SOUNDS.escape),
      duration = 0,
    })
    enqueue(self, { kind = "wait", duration = BattleTimeline.HIT_TICKS })
  else
    enqueueMessage(self, nameOrBattler(self, payload.combatant) .. " could not escape!", false)
  end
end

---@param self BattleTimeline
---@param event table<string, unknown>
local function translateStage(self, event)
  local payload = event.payload --[[@as table<string, unknown>]]
  local who = nameOrBattler(self, payload.target)
  local before = payload.before
  local after = payload.after
  if type(before) == "number" and type(after) == "number" and after ~= before then
    local direction = after > before and "rose" or "fell"
    enqueueMessage(self, who .. "'s " .. tostring(payload.stat) .. " " .. direction .. ".", false)
  else
    enqueueMessage(self, who .. " felt the effect.", false)
  end
end

---@param self BattleTimeline
---@param event table<string, unknown>
local function translateItem(self, event)
  local item = (event.payload --[[@as table<string, unknown>]]).item
  enqueueMessage(self, "Used " .. tostring(type(item) == "string" and item or "an item") .. ".", false)
end

-- Narrates a move learn-or-decline outcome named by the payload field
-- holding the move key.
---@param moveField string payload field naming the move
---@param verb string past-tense outcome phrase
---@param ender string closing punctuation
---@param targetField string payload field naming the combatant
---@return fun(self: BattleTimeline, event: table<string, unknown>)
local function moveOutcome(targetField, moveField, verb, ender)
  local function translate(self, event)
    local payload = event.payload --[[@as table<string, unknown>]]
    local target = payload[targetField]
    local move = type(payload[moveField]) == "string" and payload[moveField] or "a move"
    enqueueMessage(
      self,
      nameOrBattler(self, target) .. " " .. verb .. " " .. moveName(self, target or -1, move --[[@as string]]) .. ender,
      false
    )
  end
  return translate
end

---@param self BattleTimeline
---@param event table<string, unknown>
local function translateTransformed(self, event)
  local payload = event.payload --[[@as table<string, unknown>]]
  local who = nameOrBattler(self, payload.target)
  local copied = payload.copiedFrom
  if type(copied) == "number" then
    enqueueMessage(self, who .. " transformed into " .. combatName(self, copied --[[@as integer]]) .. "!", false)
  else
    enqueueMessage(self, who .. " transformed.", false)
  end
end

-- Replacements name their departure and arrival combatants; older shapes
-- named a withdrawing battler plus its incoming record.
---@param self BattleTimeline
---@param event table<string, unknown>
local function translateSwitch(self, event)
  local payload = event.payload --[[@as table<string, unknown>]]
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
      requiresImage = self:_imageKeyFor(departed),
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
    enqueueReveal(self, incoming --[[@as integer]])
  end
end

local STATUS_GATE_MESSAGES = {
  sleep = " is fast asleep.",
  paralysis = " is paralyzed and cannot move.",
  freeze = " is frozen solid.",
}

---@param self BattleTimeline
---@param event table<string, unknown>
local function translateStatusGate(self, event)
  local payload = event.payload --[[@as table<string, unknown>]]
  local who = nameOrBattler(self, payload.combatant)
  local outcome = payload.outcome
  local text
  if outcome == "woke" then
    text = " woke up."
  elseif outcome == "thawed" then
    text = " thawed out."
  else
    text = STATUS_GATE_MESSAGES[tostring(payload.key)] or " cannot move."
  end
  enqueueMessage(self, who .. text, false)
end

-- Forcing and item moves narrate through their target: any following
-- switch event owns the withdrawal/reveal presentation.
---@param self BattleTimeline
---@param event table<string, unknown>
local function translateIntent(self, event)
  local target = (event.payload --[[@as table<string, unknown>]]).target
  local who = nameOrBattler(self, target)
  enqueueMessage(self, who .. " was hit by " .. moveName(self, target or -1, causeMoveKey(event)) .. ".", false)
end

-- Reserve arrivals outside the replacement switch path still reveal their
-- battler; any withdrawal narration belongs to the switch.
---@param self BattleTimeline
---@param event table<string, unknown>
local function translateJoin(self, event)
  local incoming = (event.payload --[[@as table<string, unknown>]]).combatant
  if type(incoming) == "number" then
    enqueueReveal(self, incoming --[[@as integer]])
  end
end

-- Pure action bookkeeping with no observable change: the matching strike,
-- switch, item, or flee event already carries the moment.
local function translateSilent() end

local function translateMissed(self)
  enqueueMessage(self, "The attack missed!", false)
end

---@param self BattleTimeline
---@param event table<string, unknown>
local function translateStatus(self, event)
  local payload = event.payload --[[@as table<string, unknown>]]
  enqueueMessage(
    self,
    nameOrBattler(self, payload.target) .. " was afflicted with " .. tostring(payload.key) .. ".",
    false
  )
end

---@param self BattleTimeline
---@param event table<string, unknown>
local function translateCured(self, event)
  local payload = event.payload --[[@as table<string, unknown>]]
  enqueueMessage(self, nameOrBattler(self, payload.target) .. " recovered from " .. tostring(payload.key) .. ".", false)
end

---@param self BattleTimeline
---@param event table<string, unknown>
local function translateTick(self, event)
  local payload = event.payload --[[@as table<string, unknown>]]
  local target = payload.combatant
  if type(target) == "number" then
    enqueueMessage(
      self,
      combatName(self, target --[[@as integer]]) .. " is hurt by " .. tostring(payload.key) .. ".",
      false
    )
    enqueueCheckpointHealth(self, target --[[@as integer]], event)
  end
end

local translateRegained = hurtOrHealed("target", " regained health.")
local translateRecoil = hurtOrHealed("target", " was hurt by recoil.")
local translateDrained = hurtOrHealed("target", " absorbed health.")
local translateLeveled = hurtOrHealed("target", "'s health was evened out.")
local translateLearn = moveOutcome("combatant", "move", "learned", "!")
local translateDeclined = moveOutcome("combatant", "move", "did not learn", ".")
local translateSketched = moveOutcome("target", "copied", "sketched", ".")
local translateCharged = targetMessage("target", " began to charge.")
local translateProtected = targetMessage("target", " protected itself.")
local translateSubstituteBroke = targetMessage("target", "'s substitute broke.")

---@param self BattleTimeline
---@param event table<string, unknown>
local function translateDelayed(self, event)
  local target = (event.payload --[[@as table<string, unknown>]]).target
  enqueueMessage(self, "An attack was foretold for " .. nameOrBattler(self, target) .. ".", false)
end

---@param self BattleTimeline
---@param event table<string, unknown> capture throw event under translation
local function translateThrow(self, event)
  local payload = event.payload --[[@as table<string, unknown>]]
  local user = explicitActor(event)
  if user == nil and type(payload.user) == "number" then
    user = payload.user --[[@as integer]]
  end
  local ball = type(payload.ball) == "string" and payload.ball or "a ball"
  local who = user ~= nil and combatName(self, user --[[@as integer]]) or "The battler"
  enqueueMessage(self, who .. " threw a " .. ball .. ".", false)
  enqueue(self, { kind = "wait", duration = BattleTimeline.HIT_TICKS })
end

---@param self BattleTimeline
---@param event table<string, unknown> capture shake event under translation
local function translateShake(self, event)
  local payload = event.payload --[[@as table<string, unknown>]]
  local index = payload.index
  if type(index) == "number" then
    local times = index --[[@as integer]] == 1 and " time." or " times."
    enqueueMessage(self, "The ball shook " .. tostring(index) .. times, false)
  else
    enqueueMessage(self, "The ball is shaking.", false)
  end
  enqueue(self, {
    kind = "sound",
    cue = effectCue(BattleAudio.SINK_SOUNDS.shake),
    duration = 0,
  })
  enqueue(self, { kind = "wait", duration = BattleTimeline.HIT_TICKS })
end

---@param self BattleTimeline
---@return string visible name of the single wild foe under capture narration
local function captureFoeName(self)
  -- Captures only run in single wild encounters, so the one visible
  -- foe is structural, never a display-order guess among several.
  if self._latest ~= nil then
    local foes = (self._latest --[[@as table<string, unknown>]]).foes
    if type(foes) == "table" and type(foes[1]) == "table" then
      local foe = (foes --[[@as table<integer, table<string, unknown>>]])[1]
      if type(foe.name) == "string" then
        return foe.name --[[@as string]]
      end
    end
  end
  return "The foe"
end

---@param self BattleTimeline
local function translateCaught(self)
  enqueueMessage(self, "Gotcha! " .. captureFoeName(self) .. " was caught!", false)
  enqueue(self, {
    kind = "sound",
    cue = effectCue(BattleAudio.SINK_SOUNDS.caught),
    duration = 0,
  })
  enqueue(self, { kind = "wait", duration = BattleTimeline.MESSAGE_HOLD_TICKS })
end

---@param self BattleTimeline
---@param event table<string, unknown> native capture event under translation
local function translateBrokeFree(self, event)
  local sourceText = assert(event.sourceText, "capture outcomes require selected native source text")
  assert(type(sourceText) == "string", "capture outcome source text is a string")
  enqueueMessage(self, sourceText, false)
  enqueue(self, { kind = "wait", duration = BattleTimeline.HIT_TICKS })
end

---@param self BattleTimeline
---@param event table<string, unknown> generic scripted-kernel strike under translation
local function translateStrike(self, event)
  local payload = event.payload --[[@as table<string, unknown>]]
  local user = explicitActor(event)
  local who = user ~= nil and combatName(self, user --[[@as integer]]) or "The battler"
  enqueueMessage(self, who .. " struck with " .. explicitMove(event) .. ".", false)
  local target = explicitTarget(event)
  if target == nil and type(payload.resolved) == "number" then
    target = payload.resolved --[[@as integer]]
  end
  if target ~= nil then
    enqueueCheckpointHealth(self, target --[[@as integer]], event)
  end
end

-- Every remaining kernel event kind the native session actually emits
-- receives its intentional treatment here. Accounting-only events stay
-- silent; everything else narrates, moves health, or changes visibility.
-- Kinds outside this table are genuinely unknown and keep the explicit
-- diagnostic instead of vanishing.
---@type table<string, fun(self: BattleTimeline, event: table<string, unknown>)>
local OTHER_TRANSLATORS = {
  flee = translateFlee,
  missed = translateMissed,
  ["move-used"] = translateMoveUsed,
  status = translateStatus,
  cured = translateCured,
  stage = translateStage,
  healed = translateRegained,
  tick = translateTick,
  recoil = translateRecoil,
  drained = translateDrained,
  fainted = translateFainted,
  leveled = translateLeveled,
  item = translateItem,
  learn = translateLearn,
  declined = translateDeclined,
  charged = translateCharged,
  delayed = translateDelayed,
  protected = translateProtected,
  transformed = translateTransformed,
  sketched = translateSketched,
  switch = translateSwitch,
  ["status-gate"] = translateStatusGate,
  ["item-intent"] = translateIntent,
  ["switch-intent"] = translateIntent,
  ["substitute-broke"] = translateSubstituteBroke,
  acknowledge = translateSilent,
  join = translateJoin,
  throw = translateThrow,
  shake = translateShake,
  caught = translateCaught,
  broke_free = translateBrokeFree,
  strike = translateStrike,
}

---@param self BattleTimeline
---@param event table<string, unknown> sanitized kernel event under translation
local function translateOther(self, event)
  local kind = event.kind --[[@as string]]
  local translate = OTHER_TRANSLATORS[kind]
  if translate == nil then
    self._diagnostics[#self._diagnostics + 1] = "unrepresentable effect: " .. kind
    enqueueMessage(self, "Something unrepresentable happened (" .. kind .. ").", false)
    return
  end
  translate(self, event)
end

-- Accepts one delivery packet in order: unseen identities translate
-- their events into cues behind the retained final facts; a repeated
-- identity is rejected without touching state. A completion naming an
-- entry token without actor identity is stale and never unblocks.
---@param packet table<string, unknown> detached delivery packet
---@param sourceMessages table<integer, string>? selected source text by event sequence
---@return boolean accepted
function BattleTimeline:present(packet, sourceMessages)
  assert(type(packet) == "table", "the cue player consumes delivery packets")
  local id = packet.packetId --[[@as integer]]
  assert(type(id) == "number" and id % 1 == 0 and id >= 1, "delivery packets carry a monotonic identity")
  if id <= self._lastPacketId then
    return false
  end
  local launch = type(packet.launchId) == "string" and packet.launchId or ""
  local events = {} ---@type table<integer, table<string, unknown>>
  if type(packet.events) == "table" then
    for _, event in
      ipairs(packet.events --[[@as table<integer, unknown>]])
    do
      if type(event) == "table" then
        if event.kind == "broke_free" then
          assert(
            type(event.sequence) == "number" and event.sequence % 1 == 0 and event.sequence >= 0,
            "capture outcomes carry an event sequence"
          )
        end
        local sourceText = sourceMessages ~= nil and sourceMessages[event.sequence] or nil
        if event.kind == "broke_free" then
          assert(type(sourceText) == "string", "capture outcomes require selected native source text")
        end
        if type(sourceText) == "string" then
          local detached = copyValue(event) --[[@as table<string, unknown>]]
          detached.sourceText = sourceText
          events[#events + 1] = detached
        else
          events[#events + 1] = event --[[@as table<string, unknown>]]
        end
      end
    end
  end
  for _, event in ipairs(events) do
    if event.kind == "acknowledge" then
      local payload = event.payload --[[@as table<string, unknown>?]]
      if type(payload) == "table" and type(payload.activation) == "number" and explicitActor(event) == nil then
        return false
      end
    end
  end
  -- Exactly-once across deliveries: an event already played under its
  -- launch identity never queues again, and a delivery carrying
  -- nothing new changes nothing. Emissions without a sequence predate
  -- identities and always play.
  local fresh = {} ---@type table<integer, table<string, unknown>>
  for _, event in ipairs(events) do
    local key = nil
    if type(event.sequence) == "number" and type(event.kind) == "string" then
      key = launch .. "\0" .. tostring(event.sequence) .. "\0" .. event.kind
    end
    if
      key == nil or self._seen[
        key --[[@as string]]
      ] ~= true
    then
      fresh[#fresh + 1] = event
    end
  end
  if #events > 0 and #fresh == 0 then
    return false
  end
  self._lastPacketId = id
  for _, event in ipairs(fresh) do
    if type(event.sequence) == "number" and type(event.kind) == "string" then
      self._seen[launch .. "\0" .. tostring(event.sequence) .. "\0" .. event.kind] = true
    end
  end
  indexFacts(self, packet.before)
  if type(packet.after) == "table" then
    self._latest = packet.after
  end
  indexFacts(self, packet.after)
  for _, event in ipairs(fresh) do
    if type(event.kind) == "string" then
      local kind = event.kind --[[@as string]]
      if kind == "struck" then
        translateStruck(self, event)
      elseif kind == "faint" then
        translateFaint(self, event)
      elseif kind == "exp" then
        translateExp(self, event, packet)
      elseif kind == "stats" then
        translateStats(self, event, packet)
      else
        translateOther(self, event)
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
  local ownForm = nil
  local foeSpecies = nil
  local foeForm = nil
  local leadSelector = nil
  if type(view.foes) == "table" and type(view.foes[1]) == "table" then
    local foe = view.foes[1] --[[@as table<string, unknown>]]
    if type(foe.name) == "string" then
      foeName = foe.name --[[@as string]]
    end
    if type(foe.species) == "string" then
      foeSpecies = foe.species --[[@as string]]
    end
    if type(foe.form) == "number" then
      foeForm = foe.form --[[@as integer]]
    end
  end
  -- The send-out names the actual active lead, never the first party
  -- slot: a benched fainted slot stays silent while the live lead
  -- walks out. Records that predate the active flag read as active,
  -- matching the previous first-slot opening; an opening with no
  -- active lead at all is impossible and fails loudly instead of
  -- hailing a guessed battler.
  local lead = nil
  if type(view.own) == "table" then
    for _, record in ipairs(view.own) do
      if type(record) == "table" and record.active ~= false then
        lead = record
        break
      end
    end
  end
  assert(lead ~= nil, "the opening needs its active lead")
  local own = lead --[[@as table<string, unknown>]]
  if type(own.name) == "string" then
    ownName = own.name --[[@as string]]
  end
  if type(own.species) == "string" then
    ownSpecies = own.species --[[@as string]]
  end
  if type(own.form) == "number" then
    ownForm = own.form --[[@as integer]]
  end
  if type(own.portraitSelector) == "string" and own.portraitSelector ~= "" then
    leadSelector = "mon:" .. own.portraitSelector --[[@as string]]
  end
  -- The encounter narration shows the real active enemy; the foe cry
  -- voices beside the encounter and the player send-out cry follows
  -- beside its back image, so same-species pairings keep one sound
  -- identity per battler start.
  if wild then
    enqueueMessage(self, "Wild " .. foeName .. " appeared!", false)
  else
    enqueueMessage(self, "The foe wants to battle!", false)
  end
  -- Each send-out cry names its real battler; without one no cry
  -- queues rather than a guessed species call. The player send-out
  -- voices first beside its message, the foe answer overlaps beside
  -- the encounter, so same-species pairings keep one sound identity
  -- per battler start.
  if type(ownSpecies) == "string" then
    enqueue(self, { kind = "sound", cue = cryCue(ownSpecies, ownForm, false), duration = 0 })
  end
  if type(foeSpecies) == "string" then
    enqueue(self, { kind = "sound", cue = cryCue(foeSpecies, foeForm, true), duration = 0 })
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
    requiresImage = leadSelector or false,
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
    emitSound(self, cue.cue --[[@as table<string, unknown>]])
  elseif cue.kind == "message" then
    cue.revealedCount = 0
    cue.delayCounter = 0
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
    checkSlotClaims(self)
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
  local full = #glyphs
  local policy = self._revealPolicy
  if type(cue.revealedCount) ~= "number" then
    cue.revealedCount = 0
  end
  if type(cue.delayCounter) ~= "number" then
    cue.delayCounter = 0
  end
  local shown = cue.revealedCount --[[@as integer]]
  if shown < full then
    -- Each eligible tick prints at most the pace budget of glyphs, then
    -- waits out the blank-tick pause. A zero pause still prints only its
    -- budget, never the whole page. A fast-forwarded reveal persists: an
    -- accelerated page never collapses back into its paced run on the
    -- next tick, so the following edge can turn the page instead of
    -- accelerating again.
    if
      cue.delayCounter --[[@as integer]]
      > 0
    then
      cue.delayCounter = cue.delayCounter --[[@as integer]] - 1
      self._message = table.concat(glyphs, "", 1, shown)
      self._messageId = cue.id --[[@as integer]]
      return false
    end
    local target = math.min(full, shown + policy.glyphBudget)
    cue.revealedCount = target
    cue.delayCounter = policy.interGlyphDelay
    self._message = table.concat(glyphs, "", 1, target)
    self._messageId = cue.id --[[@as integer]]
    if target < full then
      return false
    end
  else
    self._message = page
    self._messageId = cue.id --[[@as integer]]
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
      cue.revealedCount = 0
      cue.delayCounter = 0
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
    current.delayCounter = 0
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
    current.delayCounter = 0
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

-- Drains the queued one-shot sound cues in order. Playback
-- availability never gates a cue; the screen routes each cue to its
-- audio boundary and drops the results.
---@return table<integer, table<string, unknown>> typed sound cues in cue-start order
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
    if record.gender == "male" or record.gender == "female" or record.gender == "genderless" then
      shown.gender = record.gender
    else
      shown.gender = nil
    end
    if type(record.caught) == "boolean" then
      shown.caught = record.caught
    else
      shown.caught = nil
    end
    if type(record.height) == "number" then
      shown.height = record.height
    else
      shown.height = nil
    end
    if record.substitute == true then
      shown.substitute = true
    else
      shown.substitute = nil
    end
    -- The displayed image identity tracks the active combatant: a
    -- switch or reveal rebinds the exact canonical selector while
    -- visibility still changes only through explicit cues.
    if type(record.portraitSelector) == "string" and record.portraitSelector ~= "" then
      shown.portraitSelector = record.portraitSelector
    else
      shown.portraitSelector = nil
    end
    -- Slot identity follows only when no withdrawal, reveal or faint
    -- cue for this combatant is still queued or playing: a withdrawn
    -- record keeps its old slot until its withdrawal cue hides it,
    -- and a new occupant takes its slot on its reveal cue. Health and
    -- name reconciliation never moves a slot and never changes
    -- visibility; cue owns that.
    if not slotGated(self, id) and record.active ~= false then
      if type(record.position) == "number" then
        shown.position = record.position
      end
      if type(record.activation) == "number" then
        shown.activation = record.activation
      end
    end
    checkSlotClaims(self)
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
