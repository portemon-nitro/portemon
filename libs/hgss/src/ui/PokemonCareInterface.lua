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
  trade = "trade",
  move_relearner = "move_relearner",
  summary_application = "summary_application",
}

-- The reminder application's two source modes: MoveRelearnerInit opens the
-- level-up list, MoveTutorInit the same application for one offered move.
PokemonCareInterface.RELEARNER_MODES = {
  relearn = "relearn",
  tutor = "tutor",
}

-- The source application states
-- (src/application/move_relearner/move_relearner_app.c enum MoveRelearnerState).
PokemonCareInterface.RELEARNER_PHASES = {
  WAIT_FADE = "wait_fade",
  INPUT = "input",
  WAIT_MESSAGE = "wait_message",
  SHOW_YES_NO = "show_yes_no",
  HANDLE_YES_NO = "handle_yes_no",
  TEACH_MOVE = "teach_move",
  PRINT_LEARNED = "print_learned",
  ASK_AFTER_SUMMARY = "ask_after_summary",
  FADE_OUT = "fade_out",
  EXIT = "exit",
  FADE_OUT_TO_SUMMARY = "fade_out_to_summary",
  RUN_SUMMARY = "run_summary",
  BUTTON_FLASH = "button_flash",
  ASK_GIVE_UP = "ask_give_up",
  ASK_TEACH = "ask_teach",
}

-- The source yes/no questions (enum MoveRelearnerQuestion).
PokemonCareInterface.RELEARNER_QUESTIONS = {
  teach = "teach",
  give_up = "give_up",
  delete_move = "delete_move",
  stop_teaching = "stop_teaching",
  forget_move = "forget_move",
}

-- The script Summary application's closed modes: the plain Summary read, the
-- move-picker page a machine or tutor replacement opens, and the deletion
-- picker OpenLearnForgetMove launches.
PokemonCareInterface.SUMMARY_MODES = {
  summary = "summary",
  move_picker = "move_picker",
  delete_move = "delete_move",
}

-- The app71 trade sequence's scenes in source order (sTradeSequenceScenes):
-- the send, depart and recede scenes play the departure, the exchange scene is
-- shared, and the approach, arrive and receive scenes play the arrival.
PokemonCareInterface.TRADE_PHASES = {
  SEND = "send",
  DEPART = "depart",
  RECEDE = "recede",
  EXCHANGE = "exchange",
  APPROACH = "approach",
  ARRIVE = "arrive",
  RECEIVE = "receive",
  DONE = "done",
}

-- TradeSequenceBackdrop: morning and day share the first backdrop, evening the
-- second and night the third.
PokemonCareInterface.TRADE_BACKDROPS = {
  day = "day",
  evening = "evening",
  night = "night",
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

---@class PokemonCareRelearnerRequest
---@field kind "move_relearner"
---@field mode "relearn"|"tutor"
---@field slot integer canonical party slot the lesson applies to
---@field revision integer the party revision the request was taken at
---@field nickname string the subject's display name
---@field moves string[] the ordered eligible moves (one for a tutor lesson)
---@field known string[] the subject's current moves in slot order
---@field subject PokemonCareRelearnerSubject the detached subject the main screen draws

-- The detached subject the reminder's main screen draws: the generated species
-- identity, the form, and the gender/palette its portrait reads.
---@class PokemonCareRelearnerSubject
---@field speciesKey string
---@field form integer
---@field gender "male"|"female"
---@field shiny boolean

---@class PokemonCareRelearnerResult
---@field kind "move_relearner"
---@field learned boolean whether the source published the selected move
---@field done boolean

-- One move the source list draws: its key, the row label and the move facts the
-- detail pane prints (src/application/move_relearner: MoveRelearner_PrintMoveInfo).
---@class PokemonCareRelearnerRow
---@field move string
---@field label string
---@field type string
---@field category string
---@field power integer
---@field accuracy integer
---@field description string
---@field pp integer
---@field maxPp integer

---@class PokemonCareRelearnerSnapshot
---@field kind "move_relearner"
---@field mode "relearn"|"tutor"
---@field phase string the source application state
---@field frame integer frames spent in the current phase
---@field nickname string the subject's display name
---@field cursor integer the focused list row
---@field scrollOffset integer the first drawn list row
---@field moves PokemonCareRelearnerRow[] every eligible move in source order
---@field visible integer[] the list rows on screen this frame
---@field known PokemonCareRelearnerRow[] the subject's known moves
---@field question { kind: string, selection: "yes"|"no" }? the open source question
---@field selected integer? the target move row the replacement Summary answered
---@field learnButton boolean whether the source's teach button is armed
---@field flash string? the source button the flash animates ("teach"|"return")
---@field done boolean
---@field presentationReady boolean
---@field preparationError string?

---@class PokemonCareSummaryRequest
---@field kind "summary_application"
---@field mode "summary"|"move_picker"|"delete_move"
---@field slot integer canonical party slot the Summary shows
---@field revision integer the party revision the request was taken at
---@field moveToLearn string? the prospective move a replacement picker previews

---@class PokemonCareSummaryResult
---@field kind "summary_application"
---@field partySlot integer the final party slot the application closed on
---@field moveSlot integer? the picked move row, 4 when the picker cancelled
---@field cancelled boolean
---@field done boolean

-- One depart light streak on screen: its source x, the head and tail y the
-- fall holds, and the animation tick the streak sheet runs at.
---@class PokemonCareTradeStreak
---@field x integer
---@field headY integer
---@field tailY integer
---@field tick integer

-- One mon picture on screen: which detached subject it shows and the picture's
-- source centre. The send/receive scenes anchor it at the source's pokepic
-- centre; the exchange scene slides its two pictures.
---@class PokemonCareTradePicture
---@field subject "outgoing"|"incoming"
---@field visible boolean
---@field x integer
---@field y integer

-- The Poke Ball model's live placement: model units, binary angle indices and
-- the source's 5-bit polygon alpha.
---@class PokemonCareTradeBalloon
---@field x number
---@field y number
---@field z number
---@field rotX integer
---@field rotY integer
---@field rotZ integer
---@field scale number
---@field alpha integer

-- The scene camera the model projects through (Camera_Init_FromTargetDistance
-- AndAngle at the origin).
---@class PokemonCareTradeCamera
---@field angleX integer
---@field angleY integer
---@field distance number
---@field fov integer
---@field perspectiveType integer 0 perspective, 1 orthographic
---@field near number
---@field far number

-- One effect-sheet sprite on screen: the source animation sequence it runs,
-- its source origin and the tick its animation is at.
---@class PokemonCareTradeSprite
---@field sequence integer
---@field x integer
---@field y integer
---@field tick integer

---@class PokemonCareTradeSubject
---@field species integer native species identity the scene draws and cries
---@field form integer the subject's form
---@field nickname string the subject's display name
---@field speciesKey string the subject's generated-asset species identity
---@field gender "male"|"female" the gender its front portrait reads
---@field shiny boolean whether its portrait reads the shiny palette

---@class PokemonCareTradeRequest
---@field kind "trade"
---@field outgoing PokemonCareTradeSubject the detached sent record
---@field incoming PokemonCareTradeSubject the detached received record
---@field playerName string the NPC OT name the source trade profile carries
---@field backdrop "day"|"evening"|"night" the source time-of-day backdrop

---@class PokemonCareTradeStatus
---@field kind "trade"
---@field phase string current source scene
---@field frame integer frames spent in the current scene
---@field backdrop "day"|"evening"|"night"
---@field messageId integer? the bank-179 line currently printed
---@field bgZoom number the scene's background zoom scale (1 when the scene has none)
---@field bgZoomCenterY integer the zoom's source reference point on the screen
---@field bgScrollY integer the scene's vertical background scroll in pixels
---@field sprites PokemonCareTradeSprite[] the scene's effect-sheet sprites on screen this frame
---@field streaks PokemonCareTradeStreak[] the depart light streaks on screen this frame
---@field pictures PokemonCareTradePicture[] the mon pictures on screen this frame
---@field pulses integer[] the source palette indices the link pulses hold white
---@field balloon PokemonCareTradeBalloon? the Poke Ball model's live placement
---@field camera PokemonCareTradeCamera? the scene camera the model projects through
---@field outgoing PokemonCareTradeSubject the detached sent record
---@field incoming PokemonCareTradeSubject the detached received record
---@field done boolean whether the sequence finished
---@field presentationReady boolean whether the renderer has its generated bundle
---@field preparationError string? why the generated bundle is unusable

---@class PokemonCareTradeResult
---@field kind "trade"
---@field done boolean

---@param value unknown
---@return boolean
function PokemonCareInterface.isTradeBackdrop(value)
  return type(value) == "string" and PokemonCareInterface.TRADE_BACKDROPS[value] ~= nil
end

---@param value unknown
---@param what string
---@return PokemonCareTradeSubject
local function assertTradeSubject(value, what)
  assert(type(value) == "table", "a care trade " .. what .. " is a record")
  local typed = value --[[@as table<string, unknown>]]
  for key in pairs(typed) do
    assert(
      key == "species" or key == "form" or key == "nickname" or key == "speciesKey" or key == "gender" or key == "shiny",
      "a care trade " .. what .. " carries " .. tostring(key)
    )
  end
  assert(
    type(typed.species) == "number" and typed.species % 1 == 0 and typed.species >= 1,
    "a care trade " .. what .. " carries its native species identity"
  )
  assert(type(typed.form) == "number" and typed.form % 1 == 0 and typed.form >= 0, "a care trade " .. what .. " carries its form")
  assert(type(typed.nickname) == "string" and typed.nickname ~= "", "a care trade " .. what .. " carries its name")
  assert(
    type(typed.speciesKey) == "string" and typed.speciesKey ~= "",
    "a care trade " .. what .. " carries its generated species identity"
  )
  assert(
    typed.gender == "male" or typed.gender == "female",
    "a care trade " .. what .. " carries the gender its portrait reads"
  )
  assert(type(typed.shiny) == "boolean", "a care trade " .. what .. " carries its portrait palette flag")
  return typed --[[@as PokemonCareTradeSubject]]
end

-- Validates one trade request: the two detached subjects and the source
-- backdrop the sequence opens on. Unknown fields fail, so a caller cannot
-- smuggle state through the request record.
---@param request unknown
---@return PokemonCareTradeRequest
function PokemonCareInterface.assertTradeRequest(request)
  assert(type(request) == "table", "care trade requests are records")
  local typed = request --[[@as table<string, unknown>]]
  for key in pairs(typed) do
    assert(
      key == "kind" or key == "outgoing" or key == "incoming" or key == "playerName" or key == "backdrop",
      "care trade request carries an unknown field " .. tostring(key)
    )
  end
  assert(typed.kind == PokemonCareInterface.KINDS.trade, "care trade request names its kind")
  assertTradeSubject(typed.outgoing, "outgoing subject")
  assertTradeSubject(typed.incoming, "incoming subject")
  assert(PokemonCareInterface.isTradeBackdrop(typed.backdrop), "care trade request names its source backdrop")
  assert(
    type(typed.playerName) == "string" and typed.playerName ~= "",
    "care trade request carries the trade profile name"
  )
  return typed --[[@as PokemonCareTradeRequest]]
end

-- Validates one live trade status snapshot. The renderer consumes this record
-- as an immutable value.
---@param status unknown
---@return PokemonCareTradeStatus
function PokemonCareInterface.assertTradeStatus(status)
  assert(type(status) == "table", "care trade status is a record")
  local typed = status --[[@as table<string, unknown>]]
  assert(typed.kind == PokemonCareInterface.KINDS.trade, "care trade status names its kind")
  assert(type(typed.phase) == "string", "care trade status carries its phase")
  assert(type(typed.frame) == "number" and typed.frame % 1 == 0, "care trade status carries its frame")
  assert(PokemonCareInterface.isTradeBackdrop(typed.backdrop), "care trade status carries its backdrop")
  assert(
    type(typed.bgZoom) == "number" and typed.bgZoom > 0,
    "care trade status carries a positive background zoom scale"
  )
  assert(
    type(typed.bgScrollY) == "number" and typed.bgScrollY % 1 == 0,
    "care trade status carries its integer background scroll"
  )
  assert(
    type(typed.bgZoomCenterY) == "number" and typed.bgZoomCenterY % 1 == 0 and typed.bgZoomCenterY >= 0,
    "care trade status carries its zoom reference point"
  )
  assertTradeSubject(typed.outgoing, "outgoing subject")
  assertTradeSubject(typed.incoming, "incoming subject")
  assert(type(typed.sprites) == "table", "care trade status carries its frame sprites")
  for index, sprite in ipairs(typed.sprites) do
    local where = "care trade status sprite " .. index
    assert(type(sprite) == "table", where .. " is a record")
    local record = sprite --[[@as table<string, unknown>]]
    for key in pairs(record) do
      assert(key == "sequence" or key == "x" or key == "y" or key == "tick", where .. " carries " .. tostring(key))
    end
    for _, key in ipairs({ "sequence", "x", "y", "tick" }) do
      assert(type(record[key]) == "number" and record[key] % 1 == 0, where .. " carries an integer " .. key)
    end
    assert(assert(record.sequence) --[[@as integer]] >= 0, where .. " names a source animation sequence")
    assert(assert(record.tick) --[[@as integer]] >= 0, where .. " runs from its first tick")
  end
  assert(type(typed.streaks) == "table", "care trade status carries its light streaks")
  for index, streak in ipairs(typed.streaks) do
    local where = "care trade status streak " .. index
    assert(type(streak) == "table", where .. " is a record")
    local record = streak --[[@as table<string, unknown>]]
    for key in pairs(record) do
      assert(key == "x" or key == "headY" or key == "tailY" or key == "tick", where .. " carries " .. tostring(key))
    end
    for _, key in ipairs({ "x", "headY", "tailY", "tick" }) do
      assert(type(record[key]) == "number" and record[key] % 1 == 0, where .. " carries an integer " .. key)
    end
    assert(assert(record.tick) --[[@as integer]] >= 0, where .. " runs from its first tick")
  end
  assert(type(typed.pictures) == "table", "care trade status carries its mon pictures")
  for index, picture in ipairs(typed.pictures) do
    local where = "care trade status picture " .. index
    assert(type(picture) == "table", where .. " is a record")
    local record = picture --[[@as table<string, unknown>]]
    for key in pairs(record) do
      assert(
        key == "subject" or key == "visible" or key == "x" or key == "y",
        where .. " carries " .. tostring(key)
      )
    end
    assert(record.subject == "outgoing" or record.subject == "incoming", where .. " names its subject")
    assert(type(record.visible) == "boolean", where .. " carries its visible flag")
    for _, key in ipairs({ "x", "y" }) do
      assert(type(record[key]) == "number" and record[key] % 1 == 0, where .. " carries an integer " .. key)
    end
  end
  assert(type(typed.pulses) == "table", "care trade status carries its link pulses")
  local seen = {}
  for _, index in ipairs(typed.pulses) do
    assert(
      type(index) == "number" and index % 1 == 0 and index >= 0,
      "care trade status pulse indices are source palette indices"
    )
    assert(not seen[index], "care trade status holds each pulse index once")
    seen[index] = true
  end
  if typed.balloon == nil then
    assert(typed.camera == nil, "a model without a camera cannot be drawn")
  else
    local balloon = typed.balloon --[[@as table<string, unknown>]]
    for key in pairs(balloon) do
      assert(
        key == "x" or key == "y" or key == "z" or key == "rotX" or key == "rotY" or key == "rotZ" or key == "scale" or key == "alpha",
        "care trade balloon carries " .. tostring(key)
      )
    end
    for _, key in ipairs({ "x", "y", "z", "scale" }) do
      assert(type(balloon[key]) == "number", "care trade balloon carries a numeric " .. key)
    end
    assert(assert(balloon.scale --[[@as number]]) > 0, "care trade balloon scale is positive")
    assert(
      type(balloon.alpha) == "number" and balloon.alpha % 1 == 0 and balloon.alpha >= 0 and balloon.alpha <= 31,
      "care trade balloon alpha is the source 5-bit polygon alpha"
    )
    for _, key in ipairs({ "rotX", "rotY", "rotZ" }) do
      assert(
        type(balloon[key]) == "number" and balloon[key] % 1 == 0 and balloon[key] >= 0 and balloon[key] <= 65535,
        "care trade balloon " .. key .. " is a binary angle index"
      )
    end
    assert(type(typed.camera) == "table", "a drawn model carries the scene camera")
    local camera = typed.camera --[[@as table<string, unknown>]]
    for key in pairs(camera) do
      assert(
        key == "angleX" or key == "angleY" or key == "distance" or key == "fov" or key == "perspectiveType"
          or key == "near" or key == "far",
        "care trade camera carries " .. tostring(key)
      )
    end
    for _, key in ipairs({ "angleX", "angleY" }) do
      assert(
        type(camera[key]) == "number" and camera[key] % 1 == 0 and camera[key] >= 0 and camera[key] <= 65535,
        "care trade camera " .. key .. " is a binary angle index"
      )
    end
    assert(
      type(camera.fov) == "number" and camera.fov % 1 == 0 and camera.fov > 0 and camera.fov <= 32768,
      "care trade camera fov is the source half-angle index"
    )
    assert(
      camera.perspectiveType == 0 or camera.perspectiveType == 1,
      "care trade camera names its source perspective type"
    )
    for _, key in ipairs({ "distance", "near", "far" }) do
      assert(type(camera[key]) == "number", "care trade camera carries a numeric " .. key)
    end
    assert(assert(camera.distance --[[@as number]]) > 0, "care trade camera distance is positive")
    assert(assert(camera.far --[[@as number]]) > assert(camera.near --[[@as number]]), "care trade camera clips outside in")
  end
  for _, key in ipairs({ "done", "presentationReady" }) do
    assert(type(typed[key]) == "boolean", "care trade status carries a boolean " .. key)
  end
  return typed --[[@as PokemonCareTradeStatus]]
end

-- Validates one terminal trade result.
---@param result unknown
---@return PokemonCareTradeResult
function PokemonCareInterface.assertTradeResult(result)
  assert(type(result) == "table", "care trade results are records")
  local typed = result --[[@as table<string, unknown>]]
  for key in pairs(typed) do
    assert(key == "kind" or key == "done", "care trade result carries an unknown field " .. tostring(key))
  end
  assert(typed.kind == PokemonCareInterface.KINDS.trade, "care trade result names its kind")
  assert(type(typed.done) == "boolean", "care trade result carries its completion flag")
  return typed --[[@as PokemonCareTradeResult]]
end

-- The scheduler input snapshot the care host receives, translated into the
-- event list the Summary application consumes. The care child is the modal's
-- input owner while it runs, so its raw edges are the same navigate/confirm/
-- cancel events the field's UI lane produces.
---@param input table<string, unknown>? the scheduler input snapshot
---@return { type: string, direction: string? }[]
function PokemonCareInterface.summaryInputEvents(input)
  if type(input) ~= "table" then
    return {}
  end
  local events = {}
  if type(input.pressedDirection) == "string" then
    events[#events + 1] = { type = "navigate", direction = input.pressedDirection }
  end
  if input.pressedAction == true then
    events[#events + 1] = { type = "confirm" }
  end
  if input.pressedCancel == true then
    events[#events + 1] = { type = "cancel" }
  end
  if input.menuPressed == true then
    events[#events + 1] = { type = "menu" }
  end
  return events
end

---@param value unknown
---@return boolean
function PokemonCareInterface.isKind(value)
  return type(value) == "string" and PokemonCareInterface.KINDS[value] ~= nil
end

---@param value unknown
---@return boolean
function PokemonCareInterface.isRelearnerMode(value)
  return type(value) == "string" and PokemonCareInterface.RELEARNER_MODES[value] ~= nil
end

---@param value unknown
---@return boolean
function PokemonCareInterface.isSummaryMode(value)
  return type(value) == "string" and PokemonCareInterface.SUMMARY_MODES[value] ~= nil
end

---@param slot unknown
---@param what string
local function assertPartySubject(slot, what)
  assert(
    type(slot) == "number" and slot % 1 == 0 and slot >= 0 and slot <= 5,
    what .. " names a party slot in 0..5"
  )
end

---@param moves unknown
---@param what string
local function assertMoveKeys(moves, what)
  assert(type(moves) == "table", what .. " arrives as a move list")
  for index, move in ipairs(moves) do
    assert(type(move) == "string" and move ~= "", what .. " carries a named move at " .. tostring(index))
  end
end

-- Validates one reminder application request: the source mode, the canonical
-- party slot and revision it was taken at, the subject's display name, the
-- ordered eligible list (one entry for a tutor lesson) and the moves the
-- subject already knows. Unknown fields fail, so a caller cannot smuggle
-- state through the request record.
---@param request unknown
---@return PokemonCareRelearnerRequest
function PokemonCareInterface.assertRelearnerRequest(request)
  assert(type(request) == "table", "care reminder requests are records")
  local typed = request --[[@as table<string, unknown>]]
  for key in pairs(typed) do
    assert(
      key == "kind" or key == "mode" or key == "slot" or key == "revision" or key == "nickname"
        or key == "moves" or key == "known" or key == "subject",
      "care reminder request carries an unknown field " .. tostring(key)
    )
  end
  assert(typed.kind == PokemonCareInterface.KINDS.move_relearner, "care reminder request names its kind")
  assert(PokemonCareInterface.isRelearnerMode(typed.mode), "care reminder request names its source mode")
  assertPartySubject(typed.slot, "care reminder request")
  assert(
    type(typed.revision) == "number" and typed.revision % 1 == 0 and typed.revision >= 0,
    "care reminder request carries its party revision"
  )
  assert(type(typed.nickname) == "string" and typed.nickname ~= "", "care reminder request carries its name")
  assertMoveKeys(typed.moves, "care reminder eligible list")
  assert(#typed.moves > 0, "care reminder requests are never opened empty")
  if typed.mode == PokemonCareInterface.RELEARNER_MODES.tutor then
    assert(#typed.moves == 1, "a tutor lesson offers exactly one move")
  end
  assertMoveKeys(typed.known, "care reminder known moves")
  local subject = assert(typed.subject, "care reminder request carries its subject")
  assert(type(subject) == "table", "a care reminder subject is a record")
  for key in pairs(subject --[[@as table<string, unknown>]]) do
    assert(
      key == "speciesKey" or key == "form" or key == "gender" or key == "shiny",
      "a care reminder subject carries " .. tostring(key)
    )
  end
  assert(
    type(subject.speciesKey) == "string" and subject.speciesKey ~= "",
    "a care reminder subject carries its generated species identity"
  )
  assert(
    type(subject.form) == "number" and subject.form % 1 == 0 and subject.form >= 0,
    "a care reminder subject carries its form"
  )
  assert(
    subject.gender == "male" or subject.gender == "female",
    "a care reminder subject carries the gender its portrait reads"
  )
  assert(type(subject.shiny) == "boolean", "a care reminder subject carries its portrait palette flag")
  return typed --[[@as PokemonCareRelearnerRequest]]
end

-- Validates one script Summary request: the closed mode, the party subject and
-- revision, and the prospective move a replacement picker previews.
---@param request unknown
---@return PokemonCareSummaryRequest
function PokemonCareInterface.assertSummaryRequest(request)
  assert(type(request) == "table", "care summary requests are records")
  local typed = request --[[@as table<string, unknown>]]
  for key in pairs(typed) do
    assert(
      key == "kind" or key == "mode" or key == "slot" or key == "revision" or key == "moveToLearn",
      "care summary request carries an unknown field " .. tostring(key)
    )
  end
  assert(typed.kind == PokemonCareInterface.KINDS.summary_application, "care summary request names its kind")
  assert(PokemonCareInterface.isSummaryMode(typed.mode), "care summary request names its mode")
  assertPartySubject(typed.slot, "care summary request")
  assert(
    type(typed.revision) == "number" and typed.revision % 1 == 0 and typed.revision >= 0,
    "care summary request carries its party revision"
  )
  if typed.mode == PokemonCareInterface.SUMMARY_MODES.summary then
    assert(typed.moveToLearn == nil, "a plain Summary previews no move")
  elseif typed.moveToLearn ~= nil then
    assert(
      type(typed.moveToLearn) == "string" and typed.moveToLearn ~= "",
      "a replacement picker previews a named move"
    )
    assert(
      typed.mode == PokemonCareInterface.SUMMARY_MODES.move_picker,
      "preview rows belong to the move picker"
    )
  end
  return typed --[[@as PokemonCareSummaryRequest]]
end

-- Validates one terminal reminder result: whether the source published a move.
---@param result unknown
---@return PokemonCareRelearnerResult
function PokemonCareInterface.assertRelearnerResult(result)
  assert(type(result) == "table", "care reminder results are records")
  local typed = result --[[@as table<string, unknown>]]
  for key in pairs(typed) do
    assert(key == "kind" or key == "learned" or key == "done", "care reminder result carries " .. tostring(key))
  end
  assert(typed.kind == PokemonCareInterface.KINDS.move_relearner, "care reminder result names its kind")
  assert(type(typed.learned) == "boolean", "care reminder result carries the source learned flag")
  assert(type(typed.done) == "boolean", "care reminder result carries its completion flag")
  return typed --[[@as PokemonCareRelearnerResult]]
end

-- Validates one terminal script Summary result: the final party slot, the
-- picked move row (absent when the Summary was not a picker) and the source
-- cancellation flag.
---@param result unknown
---@return PokemonCareSummaryResult
function PokemonCareInterface.assertSummaryResult(result)
  assert(type(result) == "table", "care summary results are records")
  local typed = result --[[@as table<string, unknown>]]
  for key in pairs(typed) do
    assert(
      key == "kind" or key == "partySlot" or key == "moveSlot" or key == "cancelled" or key == "done",
      "care summary result carries " .. tostring(key)
    )
  end
  assert(typed.kind == PokemonCareInterface.KINDS.summary_application, "care summary result names its kind")
  assertPartySubject(typed.partySlot, "care summary result")
  if typed.moveSlot ~= nil then
    assert(
      type(typed.moveSlot) == "number" and typed.moveSlot % 1 == 0 and typed.moveSlot >= 0 and typed.moveSlot <= 4,
      "care summary result carries its source move row, 4 when the picker cancelled"
    )
  end
  assert(type(typed.cancelled) == "boolean", "care summary result carries its cancellation flag")
  assert(type(typed.done) == "boolean", "care summary result carries its completion flag")
  return typed --[[@as PokemonCareSummaryResult]]
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
