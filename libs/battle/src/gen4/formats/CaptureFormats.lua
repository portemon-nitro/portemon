-- Capture-only and special-capture battle policies with the native Safari
-- stage state. Native anchors: the battle-type flags for Safari, Pal
-- Park, tutorial, and Bug Contest battles from battle setup, the Pal Park
-- and tutorial early return in the native catch calculation, and the Safari
-- controller commands for throwing balls, bait, rocks, and running.
-- Registration binds the native action, counter, and outcome policies and
-- owns the Safari bait/rock stage state and transitions; Pal Park
-- transfers, tutorial scripting, and contest world judging stay with their
-- owners.

local Errors = require("libs.errors.src.Errors")

---@class CapturePolicy
---@field mode string capture mode this policy binds
---@field actions string[] admitted action vocabulary for the mode
---@field trainerCapture boolean true when trainer targets are permitted
---@field counter string? battle counter spent per special throw
---@field specialBall string? ball the mode counter pays for
---@field allowedBalls string[]? balls the mode admits, nil for battle stock
---@field scripted boolean true when throws belong to the script, not players
---@field compare ((fun(a: table<string, unknown>, b: table<string, unknown>): table<string, unknown>))? contest candidate ordering

---@class CaptureRegistry
---@field policies table<string, CapturePolicy> bound policies keyed by mode

local CaptureFormats = {}

--- Labeled native draw spent by a bait action.
CaptureFormats.BAIT_LABEL = "safari:bait"

--- Labeled native draw spent by a rock action.
CaptureFormats.ROCK_LABEL = "safari:rock"

---@param a table<string, unknown> earlier contest candidate under judging
---@param b table<string, unknown> later contest candidate under judging
---@return table<string, unknown> the leading candidate
local function compareContest(a, b)
  assert(type(a) == "table" and type(a.level) == "number", "contest candidates carry a level")
  assert(type(b) == "table" and type(b.level) == "number", "contest candidates carry a level")
  if
    b.level --[[@as number]]
    > a.level --[[@as number]]
  then
    return b
  end
  return a
end

---@param mode string capture mode under binding
---@param actions string[] admitted action vocabulary under binding
---@return CapturePolicy native policy carrying open defaults
local function nativePolicy(mode, actions)
  local admitted = {} ---@type string[]
  for _, action in ipairs(actions) do
    admitted[#admitted + 1] = action
  end
  return {
    mode = mode,
    actions = admitted,
    trainerCapture = false,
    scripted = false,
  }
end

---@return table<string, CapturePolicy> fresh native mode bindings
local function nativeBindings()
  local wild = nativePolicy("wild", { "attack", "throw_ball", "bag_item", "switch", "run" })
  local safari = nativePolicy("safari", { "throw_ball", "throw_bait", "throw_rock", "run" })
  safari.counter = "safariBalls"
  safari.specialBall = "SAFARI_BALL"
  local contest = nativePolicy("contest", { "throw_ball", "attack", "run" })
  contest.counter = "sportBalls"
  contest.specialBall = "SPORT_BALL"
  contest.compare = compareContest
  local park = nativePolicy("pal_park", { "throw_ball", "run" })
  park.counter = "parkBalls"
  park.specialBall = "PARK_BALL"
  park.allowedBalls = { "PARK_BALL" }
  local tutorial = nativePolicy("tutorial", { "throw_ball", "run" })
  tutorial.scripted = true
  return {
    wild = wild,
    safari = safari,
    contest = contest,
    pal_park = park,
    tutorial = tutorial,
  }
end

--- Custom mode bindings published through registration. Registration is the
--- explicit channel by which a custom format permits behavior the native
--- modes refuse, such as trainer captures; the throw path reads the merged
--- bindings so permitted custom throws take the same mechanics.
local customBindings = {} ---@type table<string, CapturePolicy>

--- Native Safari stage bounds: the catch-rate stage and the run-attempt
--- counter each live between zero and twelve and open at six.
local SAFARI_STAGE_MIN = 0
local SAFARI_STAGE_MAX = 12
local SAFARI_INITIAL_CATCH_STAGE = 6
local SAFARI_INITIAL_RUN_ATTEMPTS = 6

---@param code string refusal code under report
---@param message string human-readable reason under report
---@param context table<string, unknown>? structured blame under report
---@return Errors.Error typed failure carrying the refusal code
local function failure(code, message, context)
  return Errors.new(code, message, context or { code = code })
end

---@param binding unknown candidate custom binding under validation
---@return CapturePolicy detached copy of the validated binding
local function checkBinding(binding)
  if type(binding) ~= "table" then
    error(failure("invalid_binding", "capture bindings arrive as records", { code = "invalid_binding" }))
  end
  local candidate = binding --[[@as table<string, unknown>]]
  if type(candidate.mode) ~= "string" or candidate.mode == "" then
    error(failure("invalid_binding", "capture bindings name their mode", { code = "invalid_binding" }))
  end
  if
    type(candidate.actions) ~= "table"
    or #candidate.actions --[[@as string[] ]]
      < 1
  then
    error(
      failure(
        "invalid_binding",
        "capture bindings admit at least one action",
        { code = "invalid_binding", mode = candidate.mode }
      )
    )
  end
  local actions = {} ---@type string[]
  for _, action in
    ipairs(candidate.actions --[[@as string[] ]])
  do
    assert(type(action) == "string", "capture bindings admit named actions")
    actions[#actions + 1] = action
  end
  local policy = nativePolicy(candidate.mode --[[@as string]], actions)
  if candidate.trainerCapture == true then
    policy.trainerCapture = true
  end
  if type(candidate.counter) == "string" then
    policy.counter = candidate.counter --[[@as string]]
  end
  if type(candidate.specialBall) == "string" then
    policy.specialBall = candidate.specialBall --[[@as string]]
  end
  if type(candidate.allowedBalls) == "table" then
    local allowed = {} ---@type string[]
    for _, ball in
      ipairs(candidate.allowedBalls --[[@as string[] ]])
    do
      assert(type(ball) == "string", "capture bindings admit named balls")
      allowed[#allowed + 1] = ball
    end
    policy.allowedBalls = allowed
  end
  if candidate.scripted == true then
    policy.scripted = true
  end
  return policy
end

--- Publishes the native capture bindings plus any extra custom bindings.
--- Custom bindings persist as the explicit trainer-capture permit channel;
--- the returned registry carries a detached merged copy.
---@param extraBindings table<integer, unknown>? custom bindings under registration
---@return CaptureRegistry registry carrying the merged bindings
function CaptureFormats.register(extraBindings)
  if extraBindings ~= nil then
    assert(type(extraBindings) == "table", "extra capture bindings arrive as a list")
    for _, binding in
      ipairs(extraBindings --[[@as unknown[] ]])
    do
      local policy = checkBinding(binding)
      customBindings[policy.mode] = policy
    end
  end
  local merged = nativeBindings()
  for mode, policy in pairs(customBindings) do
    merged[mode] = policy
  end
  return { policies = merged }
end

--- Returns the policy bound for the mode. Unknown modes bind nothing.
---@param registry unknown registry carrying merged bindings
---@param mode unknown capture mode under lookup
---@return CapturePolicy the policy bound for the mode
function CaptureFormats.policyFor(registry, mode)
  assert(type(registry) == "table", "mode policies resolve through a registry")
  local bindings = (registry --[[@as CaptureRegistry]]).policies
  assert(type(bindings) == "table", "mode policies resolve through merged bindings")
  if type(mode) ~= "string" then
    error(failure("unknown_mode", "the capture mode is missing", { code = "unknown_mode" }))
  end
  local policy = bindings[mode]
  if type(policy) ~= "table" then
    error(failure("unknown_mode", "the capture mode binds no policy", { code = "unknown_mode", mode = mode }))
  end
  return policy --[[@as CapturePolicy]]
end

--- Returns fresh native format state for modes that own battle-local
--- capture state. Only safari owns state today; other known modes own none
--- and answer nil while unknown modes fail.
---@param mode unknown capture mode requesting initial state
---@return table<string, unknown>? fresh safari state, or nil when the mode owns none
function CaptureFormats.initialState(mode)
  local policy = CaptureFormats.policyFor(CaptureFormats.register(), mode)
  if policy.mode ~= "safari" then
    return nil
  end
  return {
    safariCatchRateStage = SAFARI_INITIAL_CATCH_STAGE,
    safariRunAttempts = SAFARI_INITIAL_RUN_ATTEMPTS,
  }
end

---@param state unknown candidate safari state under validation
---@return integer staged catch-rate stage between zero and twelve
---@return integer staged run attempts between zero and twelve
local function checkSafariState(state)
  if type(state) ~= "table" then
    error(failure("invalid_format_state", "safari actions mutate safari state", { code = "invalid_format_state" }))
  end
  local record = state --[[@as table<string, unknown>]]
  local stage = record.safariCatchRateStage
  if type(stage) ~= "number" or stage % 1 ~= 0 or stage < SAFARI_STAGE_MIN or stage > SAFARI_STAGE_MAX then
    error(
      failure(
        "invalid_format_state",
        "safari actions need a catch-rate stage from 0 to 12",
        { code = "invalid_format_state", stage = stage }
      )
    )
  end
  local attempts = record.safariRunAttempts
  if type(attempts) ~= "number" or attempts % 1 ~= 0 or attempts < SAFARI_STAGE_MIN or attempts > SAFARI_STAGE_MAX then
    error(
      failure(
        "invalid_format_state",
        "safari actions need run attempts from 0 to 12",
        { code = "invalid_format_state", attempts = attempts }
      )
    )
  end
  return stage, --[[@as integer]]
    attempts --[[@as integer]]
end

--- Executes one safari bait or rock action against the caller-owned format
--- state: consumes exactly one labeled draw, then mutates the two safari
--- integers with native clamps. Bait spends an attempt and, on a share not
--- divisible by ten, lowers the catch-rate stage; rock raises the
--- catch-rate stage and, on a share not divisible by ten, refunds an
--- attempt. Anything outside safari bait or rock fails before spending a
--- draw or mutating state.
---@param mode unknown capture mode requesting the action
---@param action unknown safari action under execution
---@param formatState unknown caller-owned safari state under mutation
---@param stream table<string, unknown> labeled native draw stream under execution
function CaptureFormats.applyAction(mode, action, formatState, stream)
  if mode ~= "safari" or (action ~= "throw_bait" and action ~= "throw_rock") then
    error(
      failure(
        "invalid_action",
        "safari actions run only as safari bait or rock",
        { code = "invalid_action", mode = mode, action = action }
      )
    )
  end
  assert(type(stream) == "table", "safari actions spend one labeled draw")
  local stage, attempts = checkSafariState(formatState)
  local state = formatState --[[@as table<string, unknown>]]
  local label = CaptureFormats.BAIT_LABEL
  if action == "throw_rock" then
    label = CaptureFormats.ROCK_LABEL
  end
  local draw = (stream --[[@as BattleRng]]):nextU16(label, { mode = mode, action = action })
  if action == "throw_bait" then
    if attempts > SAFARI_STAGE_MIN then
      state.safariRunAttempts = attempts - 1
    end
    if draw % 10 ~= 0 and stage > SAFARI_STAGE_MIN then
      state.safariCatchRateStage = stage - 1
    end
  else
    if stage < SAFARI_STAGE_MAX then
      state.safariCatchRateStage = stage + 1
    end
    if draw % 10 ~= 0 and attempts < SAFARI_STAGE_MAX then
      state.safariRunAttempts = attempts + 1
    end
  end
end

return CaptureFormats
