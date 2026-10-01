-- Calling-move selection and settlement: metronome-class draws, party and
-- sleep calling, and copy-move eligibility. Selection resolves at the
-- action-to-move transition through choose, which consumes exactly one
-- labeled candidate roll on success and consumes nothing when the eligible
-- set is empty; step handlers settle frames that already carry a drawn
-- move and resume frames that still name their calling move, so a called
-- execution charges its caller exactly once and never spends the drawn
-- move entry. Candidate filtering mirrors the source eligibility rules in
-- src/battle/battle_command.c; the tables below are the single edit point
-- for eligibility changes.

local BattleErrors = require("libs.battle.src.errors")
local BattleRng = require("libs.battle.src.gen4.BattleRng")

---@class CalledMoves
local CalledMoves = {}

-- Eligible metronome candidates for the native candidate roll. The draw
-- selects index roll % #candidates + 1, so every entry stays reachable and
-- struggle can never surface as a fallback.
CalledMoves.METRONOME_CANDIDATES = { "TACKLE", "SPLASH", "PROTECT" }

local CALLING = {
  METRONOME = true,
  ASSIST = true,
  SLEEP_TALK = true,
  MIRROR_MOVE = true,
  COPYCAT = true,
  ME_FIRST = true,
  NATURE_POWER = true,
  MIMIC = true,
}

-- Moves assist refuses to call, mirroring the source ban list: calling
-- convolutions, counters, protections, and moves without a standalone
-- target never pass through an assist draw.
local ASSIST_BANNED = {
  ASSIST = true,
  CHATTER = true,
  COPYCAT = true,
  COUNTER = true,
  DESTINY_BOND = true,
  DETECT = true,
  ENDURE = true,
  FOCUS_PUNCH = true,
  FOLLOW_ME = true,
  HELPING_HAND = true,
  ME_FIRST = true,
  METRONOME = true,
  MIMIC = true,
  MIRROR_COAT = true,
  MIRROR_MOVE = true,
  PROTECT = true,
  SKETCH = true,
  SLEEP_TALK = true,
  SNATCH = true,
  STRUGGLE = true,
  THIEF = true,
  TRICK = true,
}

-- Sleep talk never calls its own slot and never falls back to struggle.
local SLEEP_TALK_BANNED = {
  SLEEP_TALK = true,
  STRUGGLE = true,
}

---@param stream unknown candidate source stream under test
---@return BattleRng the stream once it proves its draw contract
local function checkStream(stream)
  if type(stream) ~= "table" then
    error(BattleErrors.invalidState("called selection draws from the battle stream", {}))
  end
  local candidate = stream --[[@as table<string, unknown>]]
  if type(candidate.nextU16) ~= "function" then
    error(BattleErrors.invalidState("called selection draws from the battle stream", {}))
  end
  assert(BattleRng.ALGORITHM == "gen4-lcrng", "called selection draws from the native battle stream")
  return stream --[[@as BattleRng]]
end

---@param list unknown candidate roster under test
---@param what string selection the roster feeds
---@return string[] usable candidate names in roster order
local function checkRoster(list, what)
  if type(list) ~= "table" then
    error(BattleErrors.invalidState(what .. " reads its candidate roster", {}))
  end
  local roster = list --[[@as table<integer, unknown>]]
  local pool = {}
  for index = 1, #roster do
    local entry = roster[index]
    if type(entry) ~= "string" or entry == "" then
      error(BattleErrors.invalidState(what .. " candidates must name their move", { index = index }))
    end
    pool[#pool + 1] = entry --[[@as string]]
  end
  return pool
end

---@param pool string[] ordered candidates under filtering
---@param banned table<string, boolean> source ban set under test
---@return string[] eligible candidates in pool order
local function eligible(pool, banned)
  local kept = {}
  for _, key in ipairs(pool) do
    if banned[key] ~= true then
      kept[#kept + 1] = key
    end
  end
  return kept
end

---@param select table<string, unknown> unresolved calling-move selection under test
---@param pool string[] eligible candidates under the roll
---@param label string labeled draw site recording the candidate roll
---@return string the drawn candidate name
local function drawFrom(select, pool, label)
  local stream = checkStream(select.stream)
  local cause = { key = select.requestedMove }
  local roll = stream:nextU16(label, cause)
  return pool[(roll % #pool) + 1]
end

--- Resolves an unresolved calling move to its drawn identity. Returns nil
--- when the executing move needs no calling-move selection; otherwise
--- returns either the drawn move or a failure naming the empty set. Draws
--- happen only for nonempty eligible sets, so failures spend no power
--- points and consume no selection draws.
---@param select table<string, unknown> unresolved calling-move selection under test
---@return table<string, string>? decision carrying executingMove or failed
function CalledMoves.choose(select)
  assert(type(select) == "table", "called selection reads its selection record")
  local calling = select.executingMove
  if type(calling) ~= "string" or CALLING[calling] ~= true then
    return nil
  end
  if calling ~= select.requestedMove then
    return nil
  end
  if calling == "METRONOME" then
    return { executingMove = drawFrom(select, CalledMoves.METRONOME_CANDIDATES, "metronome") }
  end
  if calling == "ASSIST" then
    local pool = eligible(checkRoster(select.party, "assist"), ASSIST_BANNED)
    if #pool == 0 then
      return { failed = "no-eligible-moves" }
    end
    return { executingMove = drawFrom(select, pool, "assist") }
  end
  if calling == "SLEEP_TALK" then
    local pool = eligible(checkRoster(select.usable, "sleep talk"), SLEEP_TALK_BANNED)
    if #pool == 0 then
      return { failed = "no-eligible-moves" }
    end
    return { executingMove = drawFrom(select, pool, "sleep-talk") }
  end
  if calling == "MIRROR_MOVE" or calling == "COPYCAT" or calling == "MIMIC" or calling == "ME_FIRST" then
    if type(select.copiedMove) == "string" and select.copiedMove ~= "" then
      return { executingMove = select.copiedMove }
    end
    return { failed = "nothing-to-copy" }
  end
  return { failed = "no-terrain-facts" }
end

---@param frame table<string, unknown> move frame under settlement
---@return table<string, unknown> selection record rebuilt from the frame
local function selectFromFrame(frame)
  local locals = frame.locals --[[@as table<string, unknown>]]
  return {
    requestedMove = frame.requestedMove,
    executingMove = frame.executingMove,
    stream = frame.stream,
    party = locals.party,
    usable = locals.usable,
    copiedMove = locals.copiedMove,
  }
end

---@param frame table<string, unknown> move frame under copying
---@param executingMove string resolved drawn identity replacing the calling move
---@return table<string, unknown> resumed frame carrying the drawn identity
local function resolvedCopy(frame, executingMove)
  local copy = {}
  for key, value in pairs(frame) do
    copy[key] = value
  end
  local locals = {}
  for key, value in
    pairs(frame.locals --[[@as table<string, unknown>]])
  do
    locals[key] = value
  end
  copy.executingMove = executingMove
  copy.locals = locals
  return copy
end

---@param key string calling move identity owning the handler
---@return fun(ctx: BattleContext, frame: table<string, unknown>): table<string, unknown> step handler settling the calling move
local function makeStepHandler(key)
  local function stepCalled(ctx, frame)
    assert(type(ctx) == "table", "called moves step through the battle context")
    assert(type(frame) == "table", "called moves step from their move frame")
    local record = frame --[[@as table<string, unknown>]]
    if
      type((record.locals --[[@as table<string, unknown>]]).failed) == "string"
    then
      return { kind = "complete", result = "failed" }
    end
    if record.executingMove ~= key then
      return { kind = "complete", result = "failed" }
    end
    local decision = CalledMoves.choose(selectFromFrame(record))
    if decision == nil or decision.failed ~= nil then
      return { kind = "complete", result = "failed" }
    end
    return { kind = "push", frame = resolvedCopy(record, decision.executingMove) }
  end
  return stepCalled
end

--- Binds the calling-move step handlers into the owner table.
---@param owned table<string, fun(ctx: BattleContext, frame: table<string, unknown>): table<string, unknown>> handler owner receiving the family bindings
function CalledMoves.register(owned)
  assert(type(owned) == "table", "called moves register into their owner table")
  for key in pairs(CALLING) do
    owned[key] = makeStepHandler(key)
  end
end

return CalledMoves
