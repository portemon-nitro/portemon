-- The closed value vocabulary shared by the care script host, its blocking
-- task and the care presentation. One application kind exists today: the egg
-- hatch scene. Requests, live status snapshots and terminal results are plain
-- records with exactly the fields named here; the validators refuse anything
-- else, so a new application kind is an explicit edit of this file instead of
-- an arbitrary extension table.
--
-- No live state lives here: the host owns the child, the state machine owns
-- its frame, and the renderer borrows an immutable snapshot.

---@class PokemonCareInterface
local PokemonCareInterface = {}

-- The closed application-kind set.
PokemonCareInterface.KINDS = {
  hatch = "hatch",
}

-- The source hatch scene variants (HatchEggSceneType): an ordinary egg scene
-- and the Ranger-origin Manaphy scene.
PokemonCareInterface.HATCH_VARIANTS = {
  egg = "egg",
  manaphy = "manaphy",
}

-- Ordered scene stages. Frames, effects and waits follow the source scene
-- functions; the renderer reads this name instead of inferring from a timer.
PokemonCareInterface.HATCH_PHASES = {
  FADE_IN = "fade_in",
  WAIT_BEFORE_SHAKE = "wait_before_shake",
  SHAKE_ONCE = "shake_once",
  SHAKE_TWICE = "shake_twice",
  SHAKE_CRACK = "shake_crack",
  HATCH = "hatch",
  WAIT_CRY = "wait_cry",
  WAIT_FANFARE = "wait_fanfare",
  ASK_NICKNAME = "ask_nickname",
  CHOOSE_NICKNAME = "choose_nickname",
  FADE_OUT = "fade_out",
  DONE = "done",
}

---@class PokemonCareHatchRequest
---@field kind "hatch"
---@field variant "egg"|"manaphy"
---@field species integer native species identity of the hatched record
---@field form integer the hatched record's form
---@field nickname string default species name the scene prints

---@class PokemonCareHatchStatus
---@field kind "hatch"
---@field variant "egg"|"manaphy"
---@field phase string current source stage
---@field frame integer frames spent in the current stage
---@field eggFrame integer the source egg animation frame, -1 when hidden
---@field eggOffsetX integer source shake displacement
---@field eggOffsetY integer source shake displacement
---@field scaleX number source shake scale
---@field scaleY number source shake scale
---@field bars boolean whether the reveal bars are on screen
---@field barsOffset integer the source bar slide offset
---@field messageId integer? the source msg_0187 line currently printed
---@field question boolean whether the nickname question is on screen
---@field selection string "yes"|"no" the current answer
---@field done boolean whether the scene finished
---@field presentationReady boolean whether the renderer has its generated bundle
---@field preparationError string? why the generated bundle is unusable
---@field particles integer[] source emitter identities requested on this frame

---@class PokemonCareHatchResult
---@field kind "hatch"
---@field wantToName boolean the source yes/no answer
---@field done boolean

---@param value unknown
---@return boolean
function PokemonCareInterface.isKind(value)
  return type(value) == "string" and PokemonCareInterface.KINDS[value] ~= nil
end

---@param value unknown
---@return boolean
function PokemonCareInterface.isHatchVariant(value)
  return type(value) == "string" and PokemonCareInterface.HATCH_VARIANTS[value] ~= nil
end

-- Validates one hatch request: the scene variant, the native species identity
-- the scene prints and draws, its form, and the default name the message
-- substitutes. Unknown fields fail, so a caller cannot smuggle state through
-- the request record.
---@param request unknown
---@return PokemonCareHatchRequest
function PokemonCareInterface.assertHatchRequest(request)
  assert(type(request) == "table", "care hatch requests are records")
  local typed = request --[[@as table<string, unknown>]]
  for key in pairs(typed) do
    assert(
      key == "kind" or key == "variant" or key == "species" or key == "form" or key == "nickname",
      "care hatch request carries an unknown field " .. tostring(key)
    )
  end
  assert(typed.kind == PokemonCareInterface.KINDS.hatch, "care hatch request names its kind")
  assert(PokemonCareInterface.isHatchVariant(typed.variant), "care hatch request names its scene variant")
  assert(
    type(typed.species) == "number" and typed.species % 1 == 0 and typed.species >= 1,
    "care hatch request carries the native species identity"
  )
  assert(type(typed.form) == "number" and typed.form % 1 == 0 and typed.form >= 0, "care hatch request carries a form")
  assert(type(typed.nickname) == "string" and typed.nickname ~= "", "care hatch request carries the default name")
  return typed --[[@as PokemonCareHatchRequest]]
end

-- Validates one terminal hatch result: the scene kind, the source yes/no
-- answer the naming step reads, and the completion flag.
---@param result unknown
---@return PokemonCareHatchResult
function PokemonCareInterface.assertHatchResult(result)
  assert(type(result) == "table", "care hatch results are records")
  local typed = result --[[@as table<string, unknown>]]
  for key in pairs(typed) do
    assert(
      key == "kind" or key == "wantToName" or key == "done",
      "care hatch result carries an unknown field " .. tostring(key)
    )
  end
  assert(typed.kind == PokemonCareInterface.KINDS.hatch, "care hatch result names its kind")
  assert(type(typed.wantToName) == "boolean", "care hatch result carries the source answer")
  assert(type(typed.done) == "boolean", "care hatch result carries its completion flag")
  return typed --[[@as PokemonCareHatchResult]]
end

-- Validates one live status snapshot. The renderer consumes this record as an
-- immutable value, so it carries only scalars a draw call can read.
---@param status unknown
---@return PokemonCareHatchStatus
function PokemonCareInterface.assertHatchStatus(status)
  assert(type(status) == "table", "care hatch status is a record")
  local typed = status --[[@as table<string, unknown>]]
  assert(typed.kind == PokemonCareInterface.KINDS.hatch, "care hatch status names its kind")
  assert(PokemonCareInterface.isHatchVariant(typed.variant), "care hatch status names its scene variant")
  for _, key in ipairs({ "phase", "selection" }) do
    assert(type(typed[key]) == "string", "care hatch status carries " .. key)
  end
  for _, key in ipairs({ "frame", "eggFrame", "eggOffsetX", "eggOffsetY", "barsOffset" }) do
    assert(type(typed[key]) == "number" and typed[key] % 1 == 0, "care hatch status carries an integer " .. key)
  end
  for _, key in ipairs({ "scaleX", "scaleY" }) do
    assert(type(typed[key]) == "number", "care hatch status carries a numeric " .. key)
  end
  for _, key in ipairs({ "bars", "question", "done", "presentationReady" }) do
    assert(type(typed[key]) == "boolean", "care hatch status carries a boolean " .. key)
  end
  assert(type(typed.particles) == "table", "care hatch status carries its particle requests")
  for _, emitterId in ipairs(typed.particles) do
    assert(
      type(emitterId) == "number" and emitterId % 1 == 0 and emitterId >= 0,
      "care hatch status particle requests are source emitter identities"
    )
  end
  return typed --[[@as PokemonCareHatchStatus]]
end

return PokemonCareInterface
