-- Calling-move selection and settlement: metronome-class draws, party and
-- sleep calling, and copy-move eligibility. Selection resolves at the
-- action-to-move transition through choose, which consumes exactly one
-- labeled candidate roll on success and consumes nothing when the eligible
-- set is empty; step handlers settle frames that already carry a drawn
-- move and resume frames that still name their calling move, so a called
-- execution charges its caller exactly once and never spends the drawn
-- move entry. Candidate filtering mirrors the source eligibility rules in
-- src/battle/battle_command.c and overlay 12 (CheckLegalMetronomeMove
-- over sMetronomeUnuseableMoves, plus CheckMoveCallsOtherMove for assist);
-- the tables below are the single edit point for eligibility changes.
-- Metronome draws raw native identities one at a time and retries
-- without a ceiling, exactly like the source loop: each attempt consumes
-- one labeled roll, maps the drawn identity through the native-ordered
-- roster, rejects the attacker's own moves first, then applies the
-- dynamic gravity and heal-block legality before the static ban list.

local BattleErrors = require("libs.battle.src.errors")
local BattleRng = require("libs.battle.src.gen4.BattleRng")

---@class CalledMoves
local CalledMoves = {}

-- Moves metronome never draws, mirroring the source static ban table
-- sMetronomeUnuseableMoves (retail ROM).
-- The caller supplies the native-ordered roster (native identity to
-- semantic key); each drawn identity maps through that roster before this
-- table filters it, so every native entry stays reachable and struggle
-- can never surface as a fallback.
CalledMoves.METRONOME_BANNED = {
  METRONOME = true,
  STRUGGLE = true,
  SKETCH = true,
  MIMIC = true,
  CHATTER = true,
  SLEEP_TALK = true,
  ASSIST = true,
  MIRROR_MOVE = true,
  COUNTER = true,
  MIRROR_COAT = true,
  PROTECT = true,
  DETECT = true,
  ENDURE = true,
  DESTINY_BOND = true,
  THIEF = true,
  FOLLOW_ME = true,
  SNATCH = true,
  HELPING_HAND = true,
  COVET = true,
  TRICK = true,
  FOCUS_PUNCH = true,
  FEINT = true,
  COPYCAT = true,
  ME_FIRST = true,
  SWITCHEROO = true,
}

-- Moves metronome rejects while gravity holds the field, mirroring the
-- source gravity table sGravityUnusableMoves beside
-- BattleContext_CheckMoveUnuseableInGravity
-- (retail ROM).
CalledMoves.GRAVITY_ILLEGAL = {
  FLY = true,
  BOUNCE = true,
  JUMP_KICK = true,
  HI_JUMP_KICK = true,
  SPLASH = true,
  MAGNET_RISE = true,
}

-- Moves metronome rejects while heal block seals the user, mirroring the
-- source heal-block table sHealBlockUnusableMoves beside
-- BattleContext_CheckMoveHealBlocked
-- (retail ROM).
CalledMoves.HEALBLOCK_ILLEGAL = {
  RECOVER = true,
  SOFTBOILED = true,
  REST = true,
  MILK_DRINK = true,
  MORNING_SUN = true,
  SYNTHESIS = true,
  MOONLIGHT = true,
  SWALLOW = true,
  HEAL_ORDER = true,
  SLACK_OFF = true,
  ROOST = true,
  LUNAR_DANCE = true,
  HEALING_WISH = true,
  WISH = true,
}

-- Native move identities drawn by metronome, 1-based and contiguous over
-- the usable source move range.
local NATIVE_MOVE_COUNT = 467

local CALLING = {
  METRONOME = true,
  ASSIST = true,
  SLEEP_TALK = true,
  MIRROR_MOVE = true,
  COPYCAT = true,
  ME_FIRST = true,
  NATURE_POWER = true,
}

-- Moves assist refuses to call. The native assist filter conjoins
-- CheckMoveCallsOtherMove with CheckLegalMetronomeMove (retail ROM BtlCmd_TryAssist),
-- and every calling convolution refused by the former (sleep talk, copycat,
-- assist, me first, mirror move, metronome) already sits in the ban table
-- above, so the assist filter shares that one table rather than copying it.

-- Sleep talk never calls its own slot and never falls back to struggle.
local SLEEP_TALK_BANNED = {
  NONE = true,
  METRONOME = true,
  SLEEP_TALK = true,
  COPYCAT = true,
  ASSIST = true,
  ME_FIRST = true,
  MIRROR_MOVE = true,
  FOCUS_PUNCH = true,
  UPROAR = true,
  CHATTER = true,
  BIDE = true,
  RAZOR_WIND = true,
  SKY_ATTACK = true,
  SOLAR_BEAM = true,
  SKULL_BASH = true,
  FLY = true,
  DIVE = true,
  DIG = true,
  BOUNCE = true,
  SHADOW_FORCE = true,
  STRUGGLE = true,
}

-- Effect identities rejected by BattleCtx_IsIdenticalToCurrentMove during
-- BtlCmd_TrySleepTalk (battle_util.c / battle_command.c).
local SLEEP_TALK_BANNED_EFFECTS = {
  "BIDE",
  "RAZOR_WIND",
  "SKY_ATTACK",
  "SKULL_BASH",
  "SOLAR_BEAM",
  "FLY",
  "DIVE",
  "DIG",
  "BOUNCE",
  "SHADOW_FORCE",
}

local NATURE_POWER_TERRAIN_MOVES = {
  plain = "EARTHQUAKE",
  sand = "EARTHQUAKE",
  grass = "SEED_BOMB",
  puddle = "SEED_BOMB",
  mountain = "ROCK_SLIDE",
  cave = "ROCK_SLIDE",
  snow = "BLIZZARD",
  water = "HYDRO_PUMP",
  ice = "ICE_BEAM",
  building = "TRI_ATTACK",
  great_marsh = "MUD_BOMB",
  unknown = "AIR_SLASH",
  will = "TRI_ATTACK",
  koga = "TRI_ATTACK",
  bruno = "TRI_ATTACK",
  karen = "TRI_ATTACK",
  lance = "TRI_ATTACK",
  distortion_world = "TRI_ATTACK",
  giratina = "TRI_ATTACK",
  battle_tower = "TRI_ATTACK",
  battle_factory = "TRI_ATTACK",
  battle_arcade = "TRI_ATTACK",
  battle_castle = "TRI_ATTACK",
  battle_hall = "TRI_ATTACK",
}

local MIRROR_MOVE_BANNED_EFFECTS = { "TRANSFORM", "MIMIC", "SKETCH", "MIRROR_MOVE", "ENCORE", "STRUGGLE" }
local ME_FIRST_BANNED_EFFECTS = { "COUNTER", "MIRROR_COAT", "THIEF", "COVET", "FOCUS_PUNCH", "CHATTER" }

---@param moveFacts unknown move facts indexed by semantic move key
---@param candidate string copied move identity under legality checking
---@param bannedMoves string[] move keys whose effects cannot be copied
---@return boolean true when the candidate effect differs from each source-banned effect
local function effectIsAllowed(moveFacts, candidate, bannedMoves)
  if type(moveFacts) ~= "table" then
    error(BattleErrors.missingBehavior("copied-move checks read the immutable move facts", { key = candidate }))
  end
  local facts = moveFacts --[[@as table<string, unknown>]]
  local candidateFacts = facts[candidate]
  if type(candidateFacts) ~= "table" then
    error(BattleErrors.missingBehavior("copied-move checks resolve the copied move", { key = candidate }))
  end
  local effect = (candidateFacts --[[@as table<string, unknown>]]).effect
  if type(effect) ~= "number" then
    error(BattleErrors.missingBehavior("copied-move checks resolve the copied move effect", { key = candidate }))
  end
  for _, key in ipairs(bannedMoves) do
    local bannedFacts = facts[key]
    if type(bannedFacts) ~= "table" then
      error(BattleErrors.missingBehavior("copied-move checks resolve a banned reference move", { key = key }))
    end
    local bannedEffect = (bannedFacts --[[@as table<string, unknown>]]).effect
    if type(bannedEffect) ~= "number" then
      error(BattleErrors.missingBehavior("copied-move checks resolve a banned reference effect", { key = key }))
    end
    if bannedEffect == effect then
      return false
    end
  end
  return true
end

---@param select table<string, unknown> unresolved calling-move selection
---@param candidate string copied move identity under legality checking
---@return boolean true when the source Copycat checks admit the candidate
local function copycatAllows(select, candidate)
  return candidate ~= "NONE"
    and CalledMoves.METRONOME_BANNED[candidate] ~= true
    and not (select.gravity == true and CalledMoves.GRAVITY_ILLEGAL[candidate] == true)
    and not (select.healBlock == true and CalledMoves.HEALBLOCK_ILLEGAL[candidate] == true)
end

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

---@param list unknown native-ordered roster under test, indexed by native move identity
---@param what string selection the roster feeds
---@return table<integer, string> semantic move key by native move identity
local function checkNativeRoster(list, what)
  if type(list) ~= "table" then
    error(BattleErrors.invalidState(what .. " reads its native move roster", {}))
  end
  local roster = list --[[@as table<integer, unknown>]]
  local byNative = {}
  for nativeId, entry in pairs(roster) do
    if type(nativeId) == "number" and nativeId % 1 == 0 then
      if type(entry) ~= "string" or entry == "" then
        error(BattleErrors.invalidState(what .. " candidates must name their move", { index = nativeId }))
      end
      byNative[nativeId] = entry --[[@as string]]
    end
  end
  return byNative
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

---@param move string candidate move under dynamic eligibility
---@param gravity boolean whether Gravity makes the candidate unusable
---@param healBlock boolean whether Heal Block makes the candidate unusable
---@return boolean true when the source dynamic checks admit the candidate
local function dynamicallyLegal(move, gravity, healBlock)
  return not (gravity and CalledMoves.GRAVITY_ILLEGAL[move] == true)
    and not (healBlock and CalledMoves.HEALBLOCK_ILLEGAL[move] == true)
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

--- Resolves an unresolved metronome call the source way: draw one raw
--- native identity per attempt, map it through the native-ordered roster,
--- reject the attacker's own moves, then the gravity-illegal,
--- heal-blocked, and statically banned candidates, and repeat without a
--- ceiling until the first legal candidate is accepted. Every rejected
--- attempt consumes its draw. A drawn identity with no roster entry fails
--- explicitly; an accepted candidate without a bound handler stays
--- accepted here and fails at the existing post-selection check instead
--- of biasing the draw.
---@param select table<string, unknown> unresolved metronome selection under test
---@return table<string, string> decision carrying executingMove or failed
local function chooseMetronome(select)
  local byNative = checkNativeRoster(select.byNative, "metronome")
  local stream = checkStream(select.stream)
  local cause = { key = select.requestedMove }
  local userMoves = {}
  if type(select.userMoves) == "table" then
    for _, key in
      pairs(select.userMoves --[[@as table<string, unknown>]])
    do
      if type(key) == "string" and key ~= "" then
        userMoves[key] = true
      end
    end
  end
  local gravity = select.gravity == true
  local healBlock = select.healBlock == true
  while true do
    local nativeId = (stream:nextU16("metronome", cause) % NATIVE_MOVE_COUNT) + 1
    local candidate = byNative[nativeId]
    if candidate == nil then
      error(BattleErrors.missingBehavior("metronome maps its drawn native identity", { nativeId = nativeId }))
    end
    if
      userMoves[candidate] ~= true
      and not (gravity and CalledMoves.GRAVITY_ILLEGAL[candidate] == true)
      and not (healBlock and CalledMoves.HEALBLOCK_ILLEGAL[candidate] == true)
      and CalledMoves.METRONOME_BANNED[candidate] ~= true
    then
      return { executingMove = candidate }
    end
  end
end

--- Resolves an unresolved calling move to its drawn identity. Returns nil
--- when the executing move needs no calling-move selection; otherwise
--- returns either the drawn move or a failure naming the empty set.
--- Assist and sleep-talk draws happen only for nonempty eligible sets,
--- so those failures spend no power points and consume no selection
--- draws; metronome retries its raw draws until a legal candidate wins.
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
    return chooseMetronome(select)
  end
  if calling == "ASSIST" then
    local pool = eligible(checkRoster(select.party, "assist"), CalledMoves.METRONOME_BANNED)
    local legal = {}
    for _, key in ipairs(pool) do
      if key ~= "NONE" and dynamicallyLegal(key, select.gravity == true, select.healBlock == true) then
        legal[#legal + 1] = key
      end
    end
    pool = legal
    if #pool == 0 then
      return { failed = "no-eligible-moves" }
    end
    return { executingMove = drawFrom(select, pool, "assist") }
  end
  if calling == "SLEEP_TALK" then
    -- Sleep Talk only speaks while its user sleeps; the waking fail
    -- closes loudly through the shared failed selection instead of
    -- redrawing or crashing on the missing precondition.
    if select.userAsleep ~= true then
      return { failed = "wide-awake" }
    end
    local pool = eligible(checkRoster(select.usable, "sleep talk"), SLEEP_TALK_BANNED)
    local legal = {}
    for _, key in ipairs(pool) do
      if effectIsAllowed(select.moveFacts, key, SLEEP_TALK_BANNED_EFFECTS) then
        legal[#legal + 1] = key
      end
    end
    pool = legal
    if #pool == 0 then
      return { failed = "no-eligible-moves" }
    end
    return { executingMove = drawFrom(select, pool, "sleep-talk") }
  end
  if calling == "NATURE_POWER" then
    local terrain = select.terrain
    if type(terrain) ~= "string" or terrain == "" then
      return { failed = "no-terrain-facts" }
    end
    local move = NATURE_POWER_TERRAIN_MOVES[terrain]
    if move == nil then
      error(BattleErrors.invalidState("Nature Power receives a native terrain identity", { terrain = terrain }))
    end
    return { executingMove = move }
  end
  if calling == "MIRROR_MOVE" or calling == "COPYCAT" or calling == "ME_FIRST" then
    local copiedMove = select.copiedMove
    if calling == "MIRROR_MOVE" and (type(copiedMove) ~= "string" or copiedMove == "" or copiedMove == "NONE") then
      local candidates = select.mirrorMoveCandidates
      if type(candidates) == "table" then
        local candidateMoves = candidates --[[@as table<integer, string?>]]
        local hasCandidate = false
        for index = 1, 4 do
          local candidate = candidateMoves[index]
          if type(candidate) == "string" and candidate ~= "" and candidate ~= "NONE" then
            hasCandidate = true
            break
          end
        end
        if hasCandidate then
          local stream = checkStream(select.stream)
          repeat
            local index = stream:nextU16("mirror_move", { kind = "called-move", move = calling }) % 4 + 1
            copiedMove = candidateMoves[index]
          until type(copiedMove) == "string" and copiedMove ~= "" and copiedMove ~= "NONE"
        end
      end
    end
    if type(copiedMove) ~= "string" or copiedMove == "" or copiedMove == "NONE" then
      return { failed = "nothing-to-copy" }
    end
    if calling == "COPYCAT" and not copycatAllows(select, copiedMove) then
      return { failed = "nothing-to-copy" }
    end
    if calling == "MIRROR_MOVE" and not effectIsAllowed(select.moveFacts, copiedMove, MIRROR_MOVE_BANNED_EFFECTS) then
      return { failed = "nothing-to-copy" }
    end
    if calling == "ME_FIRST" then
      local facts = select.moveFacts
      local candidateFacts = type(facts) == "table" and (facts --[[@as table<string, unknown>]])[copiedMove] or nil
      if type(candidateFacts) ~= "table" then
        error(BattleErrors.missingBehavior("Me First resolves the selected move facts", { key = copiedMove }))
      end
      local power = (candidateFacts --[[@as table<string, unknown>]]).power
      if type(power) ~= "number" then
        error(BattleErrors.missingBehavior("Me First resolves the selected move power", { key = copiedMove }))
      end
      if power <= 0 or not effectIsAllowed(select.moveFacts, copiedMove, ME_FIRST_BANNED_EFFECTS) then
        return { failed = "nothing-to-copy" }
      end
    end
    return { executingMove = copiedMove }
  end
  return { failed = "no-terrain-facts" }
end

---@param move unknown move identity copied by Mimic
---@return boolean true when the source static Mimic check admits the copied move
function CalledMoves.isMimicMoveLegal(move)
  return type(move) == "string" and move ~= "" and move ~= "NONE" and CalledMoves.METRONOME_BANNED[move] ~= true
end

---@param frame table<string, unknown> move frame under settlement
---@return table<string, unknown> selection record rebuilt from the frame
local function selectFromFrame(frame)
  local locals = frame.locals --[[@as table<string, unknown>]]
  return {
    requestedMove = frame.requestedMove,
    executingMove = frame.executingMove,
    stream = frame.stream,
    byNative = locals.byNative,
    party = locals.party,
    usable = locals.usable,
    copiedMove = locals.copiedMove,
    mirrorMoveCandidates = locals.mirrorMoveCandidates,
    moveFacts = locals.moveFacts,
    userMoves = locals.userMoves,
    gravity = locals.gravity,
    healBlock = locals.healBlock,
    userAsleep = locals.userAsleep,
    terrain = locals.terrain,
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
