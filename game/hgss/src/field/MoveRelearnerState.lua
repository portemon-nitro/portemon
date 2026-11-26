-- The source move reminder / singleton move tutor application: one closed
-- state machine over the fixed tick. It presents the source's own flow -- the
-- entry fade, the eligible-move list with its details, the "teach this move?"
-- question, the "can't learn more than four moves" branch that reopens the
-- native Summary, the replacement confirmation, the learned message and the
-- give-up/stop-teaching refusals -- and answers the tutor task whether the
-- source published a move.
--
-- Teaching is delegated: the state asks its injected owner to publish the
-- selected move at the source's move row once, and reports learned only after
-- that publication. Refusals and the Summary's cancellation never write. Every
-- frame advances on the fixed tick; the renderer only reads snapshots.
--
-- Retail sources (tmp/refs/pokeheartgold):
-- src/application/move_relearner/move_relearner_app.c (MoveRelearner_Main, the
-- state handlers and sMoveRelearnerMessageIds) and src/scrcmd_move_relearner.c
-- (ScrCmd_MoveRelearnerInit, ScrCmd_MoveTutorInit,
-- ScrCmd_MoveRelearnerGetResult).

local PokemonCareInterface = require("libs.hgss.src.ui.PokemonCareInterface")

local PHASE = PokemonCareInterface.RELEARNER_PHASES
local QUESTION = PokemonCareInterface.RELEARNER_QUESTIONS

-- The source opens with BeginAppScreenFade and waits for it before the grid
-- accepts input (MOVE_RELEARNER_STATE_WAIT_FADE).
local ENTRY_FADE_FRAMES = 8
-- The closing fade runs the same cadence before the overlay exits.
local EXIT_FADE_FRAMES = 8
-- One printed line occupies the message window until its printer finishes;
-- the source waits on that printer before it advances (MoveRelearner_
-- WaitMessage).
local MESSAGE_FRAMES = 26
-- A pressed source button flashes before its state runs (MoveRelearner_
-- UpdateButtonFlash: one palette frame, four held frames, two more).
local FLASH_FRAMES = 7
-- MOVE_RELEARNER_VISIBLE_ROWS: the list draws four rows and scrolls one row
-- at a time.
local VISIBLE_ROWS = 4
-- POKEMON_SUMMARY_MOVE_SLOT_NEW: the Summary reports this row when its picker
-- was cancelled, which the application reads as "no replacement chosen".
local MOVE_SLOT_NEW = 4
-- MAX_MON_MOVES.
local MAX_MON_MOVES = 4
-- The source's own decision and cancel cues.
local SOUND = {
  decide = "SEQ_SE_DP_DECIDE",
  cancel = "SEQ_SE_GS_GEARCANCEL",
}

---@class MoveRelearnerState.Line
---@field index integer the source message index inside the mode's column
---@field frames integer print frames the line needs

---@class MoveRelearnerState
---@field private _mode "relearn"|"tutor"
---@field private _slot integer canonical party slot
---@field private _revision integer party revision the lesson was opened at
---@field private _nickname string the subject's display name
---@field private _moves PokemonCareRelearnerRow[] ordered eligible moves
---@field private _known PokemonCareRelearnerRow[] the subject's known moves
---@field private _audio table<string, unknown> source audio host
---@field private _teach fun(move: string, moveSlot0: integer): { kind: "changed"|"stale" }
---@field private _openSummary fun(request: table<string, unknown>): table<string, unknown>
---@field private _phase string current source state
---@field private _frame integer frames spent in the current phase
---@field private _cursor integer focused list row
---@field private _scrollOffset integer first drawn list row
---@field private _message integer? the printed source line index
---@field private _question string? the open source question
---@field private _selection "yes"|"no" the answer the question holds
---@field private _nextPhase string? the state the current wait continues into
---@field private _moveSlot integer? the replacement row the Summary answered
---@field private _cancelled boolean
---@field private _learned boolean
---@field private _done boolean
---@field private _flash string? the flashing source button
---@field private _presentationReady boolean
---@field private _preparationError string?
---@field private _summary table<string, unknown>? the open replacement Summary
local MoveRelearnerState = {}
MoveRelearnerState.__index = MoveRelearnerState

---@param catalog table<string, unknown> the validated mon catalog
---@param move string move key
---@param pp integer the power points the row prints
---@param maxPp integer
---@return PokemonCareRelearnerRow
local function row(catalog, move, pp, maxPp)
  local definition = catalog:move(move)
  return {
    move = move,
    label = assert(definition.name, "a catalog move carries its display name"),
    type = assert(definition.moveType, "a catalog move carries its type"),
    category = assert(definition.category, "a catalog move carries its category"),
    power = assert(definition.power, "a catalog move carries its power"),
    accuracy = assert(definition.accuracy, "a catalog move carries its accuracy"),
    description = assert(definition.description, "a catalog move carries its description"),
    pp = pp,
    maxPp = maxPp,
  }
end

---@param opts table<string, unknown>
---@return MoveRelearnerState
function MoveRelearnerState.new(opts)
  assert(type(opts) == "table", "the reminder application requires its options")
  local request = PokemonCareInterface.assertRelearnerRequest(opts.request)
  local catalog = assert(opts.catalog, "the reminder application requires the mon catalog")
  local audio = assert(opts.audio, "the reminder application requires its audio host")
  assert(type(opts.teach) == "function", "the reminder application requires its teaching owner")
  assert(type(opts.openSummary) == "function", "the reminder application requires its Summary child factory")
  local moves = {}
  for _, move in ipairs(request.moves) do
    local definition = catalog:move(move)
    moves[#moves + 1] = row(catalog, move, definition.basePp, definition.basePp)
  end
  local known = {}
  for index, move in ipairs(request.known) do
    local definition = catalog:move(move)
    known[index] = row(catalog, move, definition.basePp, definition.basePp)
  end
  assert(#known == #request.known, "the known list keeps its source order")
  return setmetatable({
    _mode = request.mode,
    _slot = request.slot,
    _revision = request.revision,
    _nickname = request.nickname,
    _moves = moves,
    _known = known,
    _audio = audio,
    _teach = opts.teach,
    _openSummary = opts.openSummary,
    _phase = PHASE.WAIT_FADE,
    _frame = 0,
    _cursor = 0,
    _scrollOffset = 0,
    _message = nil,
    _question = nil,
    _selection = "yes",
    _nextPhase = nil,
    _moveSlot = nil,
    _cancelled = false,
    _learned = false,
    _done = false,
    _flash = nil,
    _presentationReady = false,
    _preparationError = nil,
    _summary = nil,
  }, MoveRelearnerState)
end

---@param sound string
function MoveRelearnerState:_play(sound)
  if type(self._audio.play) == "function" then
    self._audio:play(sound)
  end
end

-- Prints one source line and continues into `nextPhase` when the printer
-- finishes; a question leaves the prompt open instead.
---@param index integer the source message index inside the mode's column
---@param nextPhase string
---@param question string?
function MoveRelearnerState:_printLine(index, nextPhase, question)
  self._message = index
  self._question = question
  self._nextPhase = nextPhase
  self._selection = "yes"
  self._phase = PHASE.WAIT_MESSAGE
  self._frame = 0
end

---@param phase string
function MoveRelearnerState:_enter(phase)
  self._phase = phase
  self._frame = 0
end

---@return PokemonCareRelearnerRow? the focused eligible move
function MoveRelearnerState:_focusedMove()
  return self._moves[self._scrollOffset + self._cursor + 1]
end

-- MoveRelearner_AskTeach: room for the move asks the teach question, a full
-- moveset asks the source's replacement question.
function MoveRelearnerState:_askTeach()
  if #self._known < MAX_MON_MOVES then
    self:_printLine(1, PHASE.HANDLE_YES_NO, QUESTION.teach)
    return
  end
  self:_printLine(4, PHASE.HANDLE_YES_NO, QUESTION.delete_move)
end

-- MoveRelearner_AskAfterSummary: the replacement Summary answered a real row,
-- so the source asks the forget confirmation; a cancelled picker answers
-- MOVE_SLOT_NEW and the source asks whether to stop teaching.
function MoveRelearnerState:_askAfterSummary()
  local target = self._moveSlot
  assert(target ~= nil, "the replacement Summary answered before the confirmation")
  if target < MOVE_SLOT_NEW then
    self:_printLine(10, PHASE.HANDLE_YES_NO, QUESTION.forget_move)
    return
  end
  self:_printLine(7, PHASE.HANDLE_YES_NO, QUESTION.stop_teaching)
end

---@param cancelled boolean whether the lesson ends without teaching
function MoveRelearnerState:_beginExit(cancelled)
  self._cancelled = cancelled
  self._message = nil
  self._question = nil
  self:_enter(PHASE.FADE_OUT)
end

-- The source buttons flash before their state runs.
---@param button "teach"|"return"
---@param nextPhase string
function MoveRelearnerState:_startFlash(button, nextPhase)
  self._flash = button
  self._nextPhase = nextPhase
  self:_enter(PHASE.BUTTON_FLASH)
end

-- MoveRelearner_TeachMove: the selected move lands once, through the owning
-- publication, before the closing fade. A stale revision or an owner failure
-- keeps the lesson unlearned.
function MoveRelearnerState:_teachSelectedMove()
  local selected = assert(self:_focusedMove(), "a lesson names the move it teaches")
  local target = self._moveSlot
  if target == nil or target >= MOVE_SLOT_NEW then
    target = #self._known
  end
  local outcome = self._teach(selected.move, target)
  if outcome.kind ~= "changed" then
    self:_beginExit(true)
    return
  end
  self._learned = true
  self._cancelled = false
  self._message = nil
  self._question = nil
  self:_enter(PHASE.FADE_OUT)
end

-- The replacement Summary runs as the application's own child overlay: the
-- source tears its own screen down, runs the Summary, then rebuilds and asks
-- where to continue.
---@param input { pressedAction: boolean?, pressedCancel: boolean?, pressedDirection: string? }?
function MoveRelearnerState:_runSummary(input)
  local summary = assert(self._summary, "the replacement Summary owns its child")
  summary:updateFixed(PokemonCareInterface.summaryInputEvents(input))
  local result = summary:takeResult()
  if result == nil then
    return
  end
  summary:dispose()
  self._summary = nil
  if result.kind == "move_selected" then
    self._moveSlot = result.moveSlot
  elseif result.kind == "cancelled" then
    -- The picker's own cancel answer is MOVE_SLOT_NEW: the source asks its
    -- stop-teaching question next.
    self._moveSlot = MOVE_SLOT_NEW
  else
    error("the replacement Summary answered " .. tostring(result.kind), 0)
  end
  self._nextPhase = PHASE.ASK_AFTER_SUMMARY
  self:_enter(PHASE.WAIT_FADE)
end

function MoveRelearnerState:_openSummaryChild()
  local child = self._openSummary({
    kind = PokemonCareInterface.KINDS.summary_application,
    mode = PokemonCareInterface.SUMMARY_MODES.move_picker,
    slot = self._slot,
    revision = self._revision,
    moveToLearn = assert(self:_focusedMove(), "the replacement Summary previews the selected move").move,
  })
  assert(type(child) == "table", "the replacement Summary answers a child screen")
  self._summary = child
  self:_enter(PHASE.RUN_SUMMARY)
end

-- One source yes/no answer runs its own action table
-- (sMoveRelearnerYesNoActions).
---@param answer "yes"|"no"
function MoveRelearnerState:_answerQuestion(answer)
  local question = assert(self._question, "a yes/no answer belongs to its question")
  self._question = nil
  if question == QUESTION.teach then
    if answer == "yes" then
      self._moveSlot = #self._known
      self:_printLine(3, PHASE.TEACH_MOVE, nil)
      return
    end
    self._message = nil
    self:_enter(PHASE.INPUT)
    return
  end
  if question == QUESTION.give_up then
    if answer == "yes" then
      self:_beginExit(true)
      return
    end
    self._message = nil
    self:_enter(PHASE.INPUT)
    return
  end
  if question == QUESTION.delete_move then
    if answer == "yes" then
      self:_enter(PHASE.FADE_OUT_TO_SUMMARY)
      return
    end
    self:_printLine(7, PHASE.HANDLE_YES_NO, QUESTION.stop_teaching)
    return
  end
  if question == QUESTION.stop_teaching then
    if answer == "yes" then
      self:_printLine(8, PHASE.HANDLE_YES_NO, nil)
      self._nextPhase = PHASE.FADE_OUT
      self._cancelled = true
      return
    end
    self:_printLine(4, PHASE.HANDLE_YES_NO, QUESTION.delete_move)
    return
  end
  assert(question == QUESTION.forget_move, "unknown source question " .. tostring(question))
  if answer == "yes" then
    self:_printLine(5, PHASE.PRINT_LEARNED, nil)
    return
  end
  self:_enter(PHASE.FADE_OUT_TO_SUMMARY)
end

-- The source grid: rows 0..3 focus list entries, up/down walk the visible rows
-- and scroll when the list continues past them, Confirm answers the focused
-- row and Cancel is the RETURN button.
---@param input { pressedAction: boolean?, pressedCancel: boolean?, pressedDirection: string? }?
function MoveRelearnerState:_handleListInput(input)
  local typed = input or {}
  local direction = typed.pressedDirection
  if direction == "up" or direction == "down" then
    local step = direction == "down" and 1 or -1
    local last = math.min(#self._moves, self._scrollOffset + VISIBLE_ROWS) - self._scrollOffset - 1
    local cursor = self._cursor + step
    if cursor < 0 then
      if self._scrollOffset > 0 then
        self._scrollOffset = self._scrollOffset - 1
        cursor = 0
      else
        cursor = 0
      end
    elseif cursor > last then
      if self._scrollOffset + VISIBLE_ROWS < #self._moves then
        self._scrollOffset = self._scrollOffset + 1
        cursor = last
      else
        cursor = last
      end
    end
    if cursor ~= self._cursor then
      self._cursor = cursor
      self:_play(SOUND.decide)
    end
    return
  end
  if typed.pressedCancel == true then
    self:_play(SOUND.cancel)
    self:_startFlash("return", PHASE.ASK_GIVE_UP)
    return
  end
  if typed.pressedAction == true then
    if self:_focusedMove() == nil then
      return
    end
    self:_play(SOUND.decide)
    self:_askTeach()
  end
end

---@param input { pressedAction: boolean?, pressedCancel: boolean?, pressedDirection: string? }?
function MoveRelearnerState:_handleQuestionInput(input)
  local typed = input or {}
  local direction = typed.pressedDirection
  if direction == "up" or direction == "left" then
    self._selection = "yes"
    return
  end
  if direction == "down" or direction == "right" then
    self._selection = "no"
    return
  end
  if typed.pressedCancel == true then
    self:_play(SOUND.cancel)
    self:_answerQuestion("no")
    return
  end
  if typed.pressedAction == true then
    self:_play(self._selection == "yes" and SOUND.decide or SOUND.cancel)
    self:_answerQuestion(self._selection)
  end
end

function MoveRelearnerState:_advanceWait()
  self._frame = self._frame + 1
  local phase = self._phase
  if phase == PHASE.WAIT_FADE then
    if self._frame < ENTRY_FADE_FRAMES then
      return
    end
    -- The entry fade hands the screen to the list; every later fade names the
    -- state it returns to (the rebuild after the replacement Summary).
    local nextPhase = self._nextPhase or PHASE.INPUT
    self._nextPhase = nil
    if nextPhase == PHASE.ASK_AFTER_SUMMARY then
      self:_askAfterSummary()
      return
    end
    self:_enter(nextPhase)
    return
  end
  if phase == PHASE.WAIT_MESSAGE then
    if self._frame < MESSAGE_FRAMES then
      return
    end
    local question = self._question
    local nextPhase = assert(self._nextPhase, "a printed line continues into its own state")
    if question ~= nil then
      -- The prompt opens once the printer finished; its answer belongs to the
      -- following ticks.
      self._nextPhase = nil
      self:_enter(PHASE.HANDLE_YES_NO)
      return
    end
    self._nextPhase = nil
    self._message = nil
    self:_enter(nextPhase)
    return
  end
  if phase == PHASE.SHOW_YES_NO then
    self:_enter(PHASE.HANDLE_YES_NO)
    return
  end
  if phase == PHASE.BUTTON_FLASH then
    if self._frame < FLASH_FRAMES then
      return
    end
    local nextPhase = assert(self._nextPhase, "a flashing button continues into its state")
    self._flash = nil
    self._nextPhase = nil
    self:_enter(nextPhase)
    return
  end
  if phase == PHASE.TEACH_MOVE then
    self:_teachSelectedMove()
    return
  end
  if phase == PHASE.PRINT_LEARNED then
    self:_printLine(6, PHASE.TEACH_MOVE, nil)
    return
  end
  if phase == PHASE.FADE_OUT_TO_SUMMARY then
    self:_openSummaryChild()
    return
  end
  if phase == PHASE.ASK_TEACH then
    self:_askTeach()
    return
  end
  if phase == PHASE.ASK_GIVE_UP then
    self:_printLine(2, PHASE.HANDLE_YES_NO, QUESTION.give_up)
    return
  end
  if phase == PHASE.FADE_OUT then
    if self._frame < EXIT_FADE_FRAMES then
      return
    end
    self._done = true
    self:_enter(PHASE.EXIT)
  end
end

-- One mapped pointer target from the presented plan: a list row, the two
-- source buttons, or the prompt's own answer boxes. Only the interaction
-- states accept taps -- the source's grid ignores touch while its prompt is up
-- and during the fades and the replacement Summary.
---@param target table<string, unknown>
function MoveRelearnerState:handlePointer(target)
  if self._done then
    return
  end
  assert(type(target) == "table" and type(target.kind) == "string", "a pointer target names its kind")
  local phase = self._phase
  if phase == PHASE.INPUT then
    if target.kind == "row" then
      -- MoveRelearner_GridOnTouch: a row press focuses that row and arms the
      -- teach button without starting the lesson.
      local index = assert(target.index, "a row target carries its list index")
      assert(type(index) == "number" and index % 1 == 0, "a row target index is an integer")
      local visible = math.max(0, index - self._scrollOffset)
      assert(visible < VISIBLE_ROWS, "a row target lies inside the drawn list")
      if index ~= self._scrollOffset + self._cursor then
        self:_play(SOUND.decide)
      end
      self._cursor = visible
      return
    end
    if target.kind == "teach" then
      if self:_focusedMove() == nil then
        return
      end
      self:_play(SOUND.decide)
      self:_startFlash("teach", PHASE.ASK_TEACH)
      return
    end
    if target.kind == "return" then
      self:_play(SOUND.cancel)
      self:_startFlash("return", PHASE.ASK_GIVE_UP)
    end
    return
  end
  if phase == PHASE.HANDLE_YES_NO and target.kind == "answer" then
    local answer = assert(target.answer, "a prompt answer names yes or no")
    assert(answer == "yes" or answer == "no", "a prompt answer names yes or no")
    self:_play(answer == "yes" and SOUND.decide or SOUND.cancel)
    self:_answerQuestion(answer)
  end
end

---@param input { pressedAction: boolean?, pressedCancel: boolean?, pressedDirection: string? }?
function MoveRelearnerState:updateFixed(input)
  if self._done then
    return
  end
  local phase = self._phase
  if phase == PHASE.RUN_SUMMARY then
    self:_runSummary(input)
    return
  end
  if phase ~= PHASE.FADE_OUT and phase ~= PHASE.EXIT and self._preparationError ~= nil then
    self:_beginExit(true)
    return
  end
  if phase == PHASE.INPUT then
    self._frame = self._frame + 1
    self:_handleListInput(input)
    return
  end
  if phase == PHASE.HANDLE_YES_NO then
    self._frame = self._frame + 1
    self:_handleQuestionInput(input)
    return
  end
  self:_advanceWait()
end

-- Reports the generated presentation's readiness. A lesson never claims a
-- learned move while its source screen cannot be drawn.
---@param ready boolean
---@param failure string?
---@param _ table<string, unknown>? the committed presentation bundle
function MoveRelearnerState:setPresentation(ready, failure, _)
  self._presentationReady = ready == true
  self._preparationError = failure
end

---@return boolean
function MoveRelearnerState:isDone()
  return self._done
end

---@return { kind: "move_relearner", learned: boolean, done: boolean }
function MoveRelearnerState:result()
  assert(self._done, "an unfinished reminder application has no result")
  return { kind = PokemonCareInterface.KINDS.move_relearner, learned = self._learned, done = true }
end

---@return table<string, unknown> immutable renderer input
function MoveRelearnerState:snapshot()
  local visible = {}
  for rowIndex = 1, VISIBLE_ROWS do
    local index = self._scrollOffset + rowIndex
    if index <= #self._moves then
      visible[#visible + 1] = index
    end
  end
  local question = nil
  if self._question ~= nil and (self._phase == PHASE.HANDLE_YES_NO or self._phase == PHASE.SHOW_YES_NO) then
    question = { kind = self._question, selection = self._selection }
  end
  local message = self._message
  return {
    kind = PokemonCareInterface.KINDS.move_relearner,
    mode = self._mode,
    phase = self._phase,
    frame = self._frame,
    nickname = self._nickname,
    cursor = self._cursor,
    scrollOffset = self._scrollOffset,
    moves = self._moves,
    visible = visible,
    known = self._known,
    question = question,
    selected = self._moveSlot,
    flash = self._flash,
    message = message,
    done = self._done,
    presentationReady = self._presentationReady,
    preparationError = self._preparationError,
  }
end

-- Releases the replacement child it still owns. The presentation lease and the
-- audio host belong to the host and the field.
function MoveRelearnerState:dispose()
  local summary = self._summary
  self._summary = nil
  if summary ~= nil then
    summary:dispose()
  end
  self._done = true
end

return MoveRelearnerState
