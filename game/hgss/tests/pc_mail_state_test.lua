-- Mailbox list projection, fresh erased-stationery composition, and the
-- three-line MailView composer with its nested shared sentence editor.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local Mailbox = require("libs.hgss.src.save.Mailbox")
local MailComposeState = require("game.hgss.src.pc.MailComposeState")
local MailboxScreenState = require("game.hgss.src.pc.MailboxScreenState")
local ScreenTopology = require("libs.ui.src.ScreenTopology")

local T = {}

local function letter(name)
  return {
    schema = "g4-mail-v2",
    type = 0,
    author = { trainerId = 222, name = name, gender = 0, language = 2, game = 7 },
    icons = { "CHIKORITA/f0", false, false },
    lines = {
      { template = "mail-template:2:4", words = { "1371", "1417" } },
      { template = "mail-template:3:1", words = { "1479", false } },
      false,
    },
  }
end

-- Faithful C01 double for the composer boundary.
local function fakeCatalog()
  return {
    template = function(_, bank, number)
      if bank == 0 and number == 0 then
        return { bank = 0, number = 0, wordCount = 2, tokens = {} }
      end
      return nil
    end,
    messageStatus = function(_, message)
      if type(message) ~= "table" or message.bank ~= 0 or message.number ~= 0 then
        return "invalid"
      end
      for _, id in ipairs(message.words) do
        if id ~= 0 and id ~= 1 and id ~= 65535 then
          return "invalid"
        end
      end
      if message.words[1] == 65535 or message.words[2] == 65535 then
        return "incomplete"
      end
      return "complete"
    end,
    expandMessage = function(_, message)
      return { { kind = "glyph", text = "w" .. tostring(message.words[1] % 4096) } }
    end,
  }
end

local function writeVisual(name)
  return { image = "assets/generated/pc/" .. name .. ".png", width = 64, height = 32, anchorX = 0, anchorY = 0 }
end

local function manifest()
  local stationery = {}
  for type = 0, 11 do
    local frames = {}
    for _ = 1, 14 do
      frames[#frames + 1] = writeVisual("stationery-" .. type .. "-highlight")
    end
    local controls = {
      { x = 24, y = 24, width = 208, height = 32 },
      { x = 24, y = 64, width = 208, height = 32 },
      { x = 24, y = 104, width = 208, height = 32 },
      { x = 24, y = 148, width = 64, height = 24 },
      { x = 160, y = 148, width = 64, height = 24 },
    }
    local highlights, hitMasks = {}, {}
    for _, control in ipairs(controls) do
      highlights[#highlights + 1] =
        { x = control.x, y = control.y, width = control.width, height = control.height, frames = frames }
      local rows = {}
      for _ = 1, control.height do
        rows[#rows + 1] = string.rep("1", control.width)
      end
      hitMasks[#hitMasks + 1] =
        { x = control.x, y = control.y, width = control.width, height = control.height, rows = rows }
    end
    stationery[type] = {
      itemKey = "MAIL_" .. type,
      background = writeVisual("stationery-" .. type),
      write = {
        background = writeVisual("stationery-" .. type .. "-write"),
        backdrop = writeVisual("stationery-" .. type .. "-backdrop"),
        highlights = highlights,
        hitMasks = hitMasks,
      },
    }
  end
  return {
    schema = "g4-pc-v4",
    mailbox = { background = {}, geometry = { visibleLetters = 10 }, pageSize = 10 },
    mail = { stationery = stationery, geometry = { iconSlots = 3 } },
    text = { banks = { [233] = { [0] = {}, [1] = {}, [2] = {}, [3] = {} } } },
    sequences = {},
  }
end

local function measurement()
  return {
    width = 256,
    height = 192,
    topology = ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = 256, height = 192 },
      role = "world",
      touch = true,
    }),
    pixelRatio = 1,
    signature = "pc-mail-test:256x192",
  }
end

local function freshLetter()
  return {
    schema = "g4-mail-v2",
    type = 0,
    author = { trainerId = 222, name = "GOLD", gender = 0, language = 2, game = 7 },
    icons = { "CHIKORITA/f0", "TOTODILE/f0", false },
    lines = { false, false, false },
  }
end

-- Scripted shared-editor double: opens with the requested message,
-- answers takeResult after two updates with the scripted verdict, and
-- counts its fixed ticks to prove the once-per-tick stepping contract.
local function fakeEditor(script)
  local editor = {
    _ticks = 0,
    _request = nil,
    _result = script.result,
    _consumed = false,
    disposed = false,
    uiInput = "easy-chat",
  }
  function editor:open(request)
    self._request = request
    return self
  end
  function editor:updateFixed(_)
    self._ticks = self._ticks + 1
  end
  function editor:status()
    return { uiInput = "easy-chat", view = { mode = 2 }, preparing = false, presentation = { inputKey = "easy-chat" } }
  end
  function editor:takeResult()
    if self._ticks >= (script.resultAfter or 6) and not self._consumed then
      self._consumed = true
      return self._result
    end
    return nil
  end
  function editor:cancelPointerCapture() end
  function editor:dispose()
    self.disposed = true
  end
  return editor
end

local function composerOpts(overrides)
  local opts = {
    letter = freshLetter(),
    catalog = fakeCatalog(),
    openEasyChat = function(_)
      error("the composer test opens no editor without a script", 0)
    end,
    prepare = function(_)
      return true
    end,
    manifest = manifest(),
    measureDisplay = measurement,
    audio = { play = function() end },
    inputMode = "buttons",
    readNavigation = function()
      return { buttonsHeld = false }
    end,
  }
  for key, value in pairs(overrides or {}) do
    opts[key] = value
  end
  return opts
end

local function settle(compose)
  for _ = 1, 30 do
    compose:updateFixed({})
    local status = compose:status()
    if status.phase == "write" then
      return status
    end
  end
  error("the composer never settles into its write screen", 0)
end

local function openMailbox(slots, partyHasMembers)
  local values = {}
  for slot = 0, Mailbox.CAPACITY - 1 do
    values[slot + 1] = slots[slot] or false
  end
  local mailbox = Mailbox.new({ schema = Mailbox.SCHEMA, slots = values })
  return MailboxScreenState.new({
    mode = "mailbox",
    partyHasMembers = partyHasMembers,
    mailbox = mailbox,
    mailActions = { preview = function() end, commit = function() end },
    manifest = manifest(),
    itemCatalog = {
      item = function(_, key)
        return { icon = key, name = key }
      end,
    },
    measureDisplay = measurement,
    audio = { play = function() end },
    charmap = CatalogFixture.CHARMAP,
    createPartyPicker = function()
      error("opening the list does not open a picker")
    end,
  }),
    mailbox
end

function T.mailbox_actions_follow_party_presence()
  local empty = openMailbox({ [0] = letter("MISTY") }, false)
  empty:updateFixed({ { type = "confirm" } })
  Assert.deepEqual(empty:status().menuActions, { "read", "cancel" })
  empty:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.equal(empty:status().action, "cancel", "empty Party action navigation ends at CANCEL")
  empty:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.equal(empty:status().action, "cancel", "empty Party action navigation stays within the source list")
  empty:updateFixed({ { type = "navigate", direction = "up" } })
  empty:updateFixed({ { type = "confirm" } })
  Assert.equal(empty:status().viewMode, "read", "READ remains available with an empty Party")
  empty:updateFixed({ { type = "cancel" } })
  Assert.equal(empty:status().phase, "list", "the letter viewer returns to the list")
  empty:dispose()

  local nonempty = openMailbox({ [0] = letter("BROCK") }, true)
  nonempty:updateFixed({ { type = "confirm" } })
  Assert.deepEqual(nonempty:status().menuActions, { "read", "erase", "give", "cancel" })
  nonempty:dispose()
end

function T.mailbox_mode_requires_party_presence_snapshot()
  local slots = { [0] = letter("MISTY") }
  local ok, err = pcall(function()
    openMailbox(slots)
  end)
  Assert.isFalse(ok, "mailbox mode requires Party presence at construction")
  Assert.isTrue(tostring(err):find("partyHasMembers", 1, true) ~= nil)
end

function T.sparse_list_rows_retain_their_source_slots_and_read_view_is_copy_only()
  local state, mailbox = openMailbox({ [0] = letter("MISTY"), [4] = letter("BROCK"), [19] = letter("DAWN") }, true)
  local status = state:status()
  Assert.equal(status.page, 0)
  Assert.deepEqual(status.visibleSlots, { 0, 4 }, "page zero maps rows to exact persisted slots")
  Assert.equal(status.selectedSlot, 0, "initial focus is the first occupied persistent slot")
  state:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.equal(state:status().selectedSlot, 4, "navigation follows the occupied source-slot order")

  local before = mailbox:capture()
  local projected = status.rows[1].letter
  projected.author.name = "CHANGED"
  Assert.deepEqual(mailbox:capture(), before, "editing a projected read value cannot mutate the owner")
  local revision = mailbox:revision()
  state:updateFixed({ { type = "confirm" } })
  Assert.equal(state:status().phase, "action", "confirm opens the Mailbox action pane")
  state:updateFixed({ { type = "confirm" } })
  local viewer = state:status()
  Assert.equal(viewer.viewMode, "read", "the first action opens the authored letter")
  Assert.deepEqual(viewer.letter.lines, letter("BROCK").lines, "reading follows the selected persistent slot")
  Assert.deepEqual(viewer.icons, { { iconKey = "CHIKORITA/f0" } }, "the read view carries stored icon selectors")
  viewer.letter.author.name = "EDITED"
  Assert.deepEqual(mailbox:get(0).author.name, "MISTY", "the read projection is copied from the owner")
  Assert.equal(mailbox:revision(), revision, "reading does not publish a mailbox revision")
  state:updateFixed({ { type = "cancel" } })
  Assert.equal(state:status().phase, "list", "backing out of the viewer returns to the list")
  state:updateFixed({ { type = "cancel" } })
  Assert.isNil(state:result(), "quit plays the sprite-3 flash before reporting closed")
  Assert.isTrue(state:isActive(), "the list stays active while the quit flash runs")
  for _ = 1, 8 do
    state:updateFixed({})
  end
  Assert.equal(state:result().kind, "closed")
  state:dispose()
end

function T.composer_starts_blank_and_gates_input_behind_its_entry_fade()
  local compose = MailComposeState.new(composerOpts())
  local status = compose:status()
  Assert.equal(status.preparing, true, "the composer polls its preparation first")
  compose:updateFixed({ { type = "confirm" } })
  status = compose:status()
  Assert.equal(status.phase, "enter", "readiness stages the entry fade")
  Assert.equal(status.fadeCoefficient, 16, "the entry fade starts at full black")
  compose:updateFixed({ { type = "confirm" } })
  Assert.equal(compose:status().phase, "enter", "input stays withheld through the entry fade")
  local settledStatus = settle(compose)
  Assert.equal(settledStatus.phase, "write")
  Assert.equal(settledStatus.stationeryType, 0)
  Assert.deepEqual(settledStatus.author.name, "GOLD", "the draft keeps its detached author")
  Assert.deepEqual(settledStatus.icons, { "CHIKORITA/f0", "TOTODILE/f0", false })
  for index = 1, 3 do
    Assert.isFalse(settledStatus.lines[index], "fresh line " .. index .. " starts blank")
  end
  Assert.equal(settledStatus.presentation.inputKey, "mail-view", "the write screen plans its native view")
  compose:dispose()
end

function T.preparation_failure_reports_without_a_result_or_custody_change()
  local compose = MailComposeState.new(composerOpts({
    prepare = function(_)
      return false, "mailbox image missing at boom"
    end,
  }))
  for _ = 1, 5 do
    compose:updateFixed({ { type = "confirm" } })
  end
  local status = compose:status()
  Assert.equal(status.preparing, true, "failed preparation keeps polling")
  Assert.equal(status.preparationError, "mailbox image missing at boom", "failures carry their cause")
  Assert.isNil(compose:takeResult(), "failed preparation publishes no result")
  compose:dispose()
end

function T.accepted_sentence_initializes_only_its_line_and_cancel_preserves_it()
  local editor = fakeEditor({
    result = {
      cancelled = false,
      changed = false,
      inputMode = "buttons",
      message = { bank = 0, number = 0, words = { 0, 1 } },
    },
  })
  local compose = MailComposeState.new(composerOpts({
    openEasyChat = function(request)
      Assert.equal(request.mode, 2, "the letter sentence editor opens the shared sentence mode")
      Assert.equal(request.promptId, 0, "sentence editing carries no prompt")
      Assert.isFalse(request.alwaysConfirm, "sentence editing never forces confirmation")
      Assert.deepEqual(
        request.message,
        { bank = 3, number = 0, words = { 65535, 65535 } },
        "blank lines start at bank 3/message 0"
      )
      return editor
    end,
  }))
  settle(compose)
  Assert.equal(editor._ticks, 0, "the nested editor owns its ticks only after its own fade")
  compose:updateFixed({ { type = "confirm" } })
  for _ = 1, 30 do
    compose:updateFixed({})
    if compose:status().child ~= nil then
      break
    end
  end
  local editing = compose:status()
  Assert.notNil(editing.child, "selecting a line parks the draft and opens the shared editor")
  Assert.equal(editing.uiInput, "easy-chat", "the nested editor profile routes while it owns input")
  Assert.equal(editing.presentation.inputKey, "easy-chat", "the shared editor plan routes while the child is pending")
  for _ = 1, 4 do
    compose:updateFixed({})
  end
  Assert.equal(editor._ticks, 4, "the composer steps the pending child exactly once per fixed tick")
  for _ = 1, 30 do
    compose:updateFixed({})
    if compose:status().child == nil then
      break
    end
  end
  local accepted = compose:status()
  Assert.isNil(accepted.child, "the accepted sentence disposes its editor exactly once")
  Assert.isTrue(editor.disposed, "the finished editor releases")
  Assert.deepEqual(
    accepted.lines[1],
    { template = "mail-template:0:0", words = { "0", "1" } },
    "accepted-but-unchanged still initializes the blank line"
  )
  Assert.isFalse(accepted.lines[2], "untouched line two stays blank")
  Assert.isFalse(accepted.lines[3], "untouched line three stays blank")
  compose:dispose()
end

function T.cancelled_sentence_preserves_its_line_exactly()
  local editor = fakeEditor({ result = { cancelled = true, changed = false, inputMode = "touch" } })
  local compose = MailComposeState.new(composerOpts({
    openEasyChat = function(_)
      return editor
    end,
  }))
  settle(compose)
  compose:updateFixed({ { type = "navigate", direction = "down" } })
  compose:updateFixed({ { type = "confirm" } })
  for _ = 1, 40 do
    compose:updateFixed({})
    if compose:status().child == nil and compose:status().phase == "write" then
      break
    end
  end
  local resumed = compose:status()
  Assert.isFalse(resumed.lines[2], "cancelling the sentence leaves the selected line exactly blank")
  Assert.equal(resumed.inputMode, "touch", "the composer retains the result modality")
  compose:dispose()
end

function T.all_blank_submit_warns_and_quit_confirms_then_reports_once()
  local compose = MailComposeState.new(composerOpts())
  settle(compose)
  compose:updateFixed({ { type = "navigate", direction = "down" } })
  compose:updateFixed({ { type = "navigate", direction = "down" } })
  compose:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.equal(compose:status().focusPos, 3, "three downs reach the button row")
  compose:updateFixed({ { type = "confirm" } })
  local warned = compose:status()
  Assert.isTrue(warned.warning, "the all-blank letter warns instead of submitting")
  Assert.isTrue(warned.modal, "the warning modals the draft")
  compose:updateFixed({ { type = "confirm" } })
  Assert.isFalse(compose:status().warning, "dismissing the warning keeps the draft")
  Assert.isNil(compose:takeResult(), "the warning publishes no result")

  compose:updateFixed({ { type = "cancel" } })
  local quit = compose:status()
  Assert.notNil(quit.quit, "quitting the letter asks its source confirmation")
  Assert.equal(quit.quit.cursor, "yes", "the quit prompt starts on YES")
  compose:updateFixed({ { type = "cancel" } })
  local resumed = compose:status()
  Assert.isNil(resumed.quit, "declining quit resumes the exact draft")
  Assert.equal(resumed.phase, "write")
  compose:updateFixed({ { type = "cancel" } })
  for _ = 1, 6 do
    compose:updateFixed({ { type = "navigate", direction = "down" } })
  end
  compose:updateFixed({ { type = "confirm" } })
  local result = nil
  for _ = 1, 20 do
    compose:updateFixed({})
    result = compose:takeResult()
    if result ~= nil then
      break
    end
  end
  Assert.deepEqual(result, { kind = "cancelled", inputMode = "buttons" }, "quit reports its one-shot result")
  Assert.isNil(compose:takeResult(), "results drain exactly once")
  compose:dispose()
end

function T.complete_letter_submits_once_after_its_exit_fade()
  local editor = fakeEditor({
    result = {
      cancelled = false,
      changed = true,
      inputMode = "buttons",
      message = { bank = 0, number = 0, words = { 0, 1 } },
    },
  })
  local compose = MailComposeState.new(composerOpts({
    openEasyChat = function(_)
      return editor
    end,
  }))
  settle(compose)
  compose:updateFixed({ { type = "confirm" } })
  for _ = 1, 40 do
    compose:updateFixed({})
    if compose:status().child == nil and compose:status().phase == "write" then
      break
    end
  end
  Assert.isTrue(compose:status().lines[1] ~= false, "the accepted sentence initializes its line")
  compose:updateFixed({ { type = "navigate", direction = "down" } })
  compose:updateFixed({ { type = "navigate", direction = "down" } })
  compose:updateFixed({ { type = "navigate", direction = "down" } })
  compose:updateFixed({ { type = "confirm" } })
  Assert.isNil(compose:takeResult(), "the result stays withheld through the exit fade")
  local result = nil
  for _ = 1, 20 do
    compose:updateFixed({})
    result = compose:takeResult()
    if result ~= nil then
      break
    end
  end
  Assert.equal(result.kind, "submitted")
  Assert.equal(result.inputMode, "buttons")
  Assert.equal(result.letter.schema, "g4-mail-v2", "submitted letters carry the current schema")
  Assert.deepEqual(result.letter.lines[1], { template = "mail-template:0:0", words = { "0", "1" } })
  Assert.isFalse(result.letter.lines[2], "blank slots persist as false")
  result.letter.lines[1].words[1] = "MUTATED"
  Assert.equal(compose:status().lines[1].words[1], "0", "submitted results detach from the live draft")
  Assert.isNil(compose:takeResult(), "submitted results drain exactly once")
  compose:dispose()
end

function T.touch_switches_modality_and_activates_while_keys_switch_back()
  local editor = fakeEditor({
    result = {
      cancelled = false,
      changed = true,
      inputMode = "touch",
      message = { bank = 0, number = 0, words = { 1, 0 } },
    },
  })
  local compose = MailComposeState.new(composerOpts({
    openEasyChat = function(_)
      return editor
    end,
    readNavigation = function()
      return { buttonsHeld = false }
    end,
  }))
  settle(compose)
  Assert.equal(compose:status().inputMode, "buttons")
  -- A buttons-mode touch both switches modality and activates its
  -- control in the same source input step.
  compose:updateFixed({ { type = "pointer_down", x = 100, y = 40 } })
  for _ = 1, 40 do
    compose:updateFixed({})
    if compose:status().child == nil and compose:status().phase == "write" then
      break
    end
  end
  local touched = compose:status()
  Assert.equal(touched.inputMode, "touch", "the activating touch switches modality")
  Assert.isTrue(touched.lines[1] ~= false, "the same touch activates the tapped line")
  -- Releasing the touch, then a key with no held touch switches back
  -- to buttons and is consumed.
  compose:updateFixed({ { type = "pointer_up" } })
  compose:updateFixed({ { type = "confirm" } })
  Assert.equal(compose:status().inputMode, "buttons", "the unconsumed key switches modality back")
  compose:dispose()
end

function T.held_touch_is_not_another_new_tap()
  local editor = fakeEditor({
    result = {
      cancelled = false,
      changed = true,
      inputMode = "touch",
      message = { bank = 0, number = 0, words = { 1, 0 } },
    },
  })
  local compose = MailComposeState.new(composerOpts({
    openEasyChat = function(_)
      return editor
    end,
    inputMode = "touch",
  }))
  settle(compose)
  compose:updateFixed({ { type = "pointer_down", x = 100, y = 40 } })
  for _ = 1, 40 do
    compose:updateFixed({})
    if compose:status().child == nil and compose:status().phase == "write" then
      break
    end
  end
  Assert.isTrue(compose:status().lines[1] ~= false, "the new tap activates line one")
  local ticks = editor._ticks
  for _ = 1, 5 do
    compose:updateFixed({})
  end
  Assert.isTrue(compose:status().lines[2] == false, "the held touch opens no second line")
  Assert.isTrue(editor._ticks >= ticks, "the composer keeps stepping its settled child")
  compose:updateFixed({ { type = "pointer_up" } })
  compose:dispose()
end

function T.disposal_releases_the_pending_child_exactly_once()
  local editor = fakeEditor({
    result = {
      cancelled = false,
      changed = true,
      inputMode = "buttons",
      message = { bank = 0, number = 0, words = { 0, 1 } },
    },
  })
  local compose = MailComposeState.new(composerOpts({
    openEasyChat = function(_)
      return editor
    end,
  }))
  settle(compose)
  compose:updateFixed({ { type = "confirm" } })
  for _ = 1, 30 do
    compose:updateFixed({})
    if compose:status().child ~= nil then
      break
    end
  end
  Assert.notNil(compose:status().child, "the line edit parks the draft behind its child")
  compose:dispose()
  Assert.isTrue(editor.disposed, "teardown disposes the pending child exactly once")
  compose:dispose()
  Assert.isTrue(editor.disposed, "disposal stays idempotent")
end

-- The erased follow-up opens the same fresh three-line composer the Bag
-- and Party entries use: the current author, three blank lines, and the
-- current icon snapshot instead of the erased values.
function T.hold_erased_mail_follow_up_composes_fresh_and_stored_give_moves_unchanged()
  local cues = {}
  local values = {}
  for slot = 0, Mailbox.CAPACITY - 1 do
    values[slot + 1] = slot == 0 and letter("MISTY") or false
  end
  local mailbox = Mailbox.new({ schema = Mailbox.SCHEMA, slots = values })
  local committed = {}
  local fakeActions = {
    revisionSnapshot = function()
      return { mailboxRevision = 0, partyRevision = 0, bagRevision = 0 }
    end,
    previewComposition = function(_, request)
      assert(request.targetSlot == 3, "composition preflights its picker recipient")
      assert(request.itemKey == "MAIL_0", "composition consumes the erased stationery")
      assert(request.partyRevision == 0 and request.bagRevision == 0, "composition carries live revisions")
      if request.confirmed ~= true then
        return { kind = "needs_confirmation", before = { heldItem = "NONE", form = 0, maxHp = 10 } }
      end
      return { kind = "ready", stationeryType = 0, before = { heldItem = "NONE", form = 0, maxHp = 10 } }
    end,
    preview = function(_, request)
      if request.kind == "eraseMailboxMessage" then
        return {
          kind = "confirm",
          token = 1,
          request = request,
          letter = letter("MISTY"),
          itemKey = "MAIL_0",
          operation = "erase",
        }
      end
      assert(request.kind == "composeGiveMail", "the hold follow-up previews its composed custody change")
      assert(request.targetSlot == 3, "composition carries the picker recipient")
      assert(request.itemKey == "MAIL_0", "composition consumes the erased stationery")
      return {
        kind = "ready",
        token = 2,
        request = request,
        letter = request.letter,
        itemKey = request.itemKey,
        operation = "compose",
      }
    end,
    commit = function(_, intent, confirmation)
      committed[#committed + 1] = { intent = intent, confirmation = confirmation }
      if confirmation == false then
        return { kind = "refused", reason = "declined" }
      end
      if intent.operation == "erase" then
        return { kind = "changed", outcome = "returned", itemKey = "MAIL_0" }
      end
      return {
        kind = "changed",
        outcome = "given",
        targetSlot = intent.request.targetSlot,
        before = { heldItem = "NONE", form = 0, maxHp = 10 },
        after = { heldItem = "MAIL_0", form = 0, maxHp = 10 },
        itemKey = "MAIL_0",
      }
    end,
  }
  local pickerSelected, pickerConfirmed, pickerCancelled, completions = false, false, false, {}
  local picker = {
    updateFixed = function() end,
    takeIntent = function(self)
      if not pickerSelected then
        pickerSelected = true
        return { kind = "give", slot = 3, partyRevision = 0, bagRevision = 0, item = "MAIL_0" }
      end
      if not pickerConfirmed then
        pickerConfirmed = true
        return { kind = "give", slot = 3, partyRevision = 0, bagRevision = 0, item = "MAIL_0", confirmed = true }
      end
      return nil
    end,
    takeResult = function()
      if pickerCancelled then
        pickerCancelled = false
        return { kind = "cancelled" }
      end
      return nil
    end,
    completeAction = function(_, outcome)
      completions[#completions + 1] = outcome
    end,
    dispose = function() end,
    cancelPointerCapture = function() end,
    draw = function() end,
  }
  local mons = {
    partyMon = function(_, slot)
      assert(slot == 3, "feedback names the composed recipient")
      return { nickname = "ABRA", heldItem = "MAIL_0", form = 0, mail = {} }
    end,
  }
  local state = MailboxScreenState.new({
    mode = "mailbox",
    partyHasMembers = true,
    mailbox = mailbox,
    mailActions = fakeActions,
    makeMailComposer = function(request)
      Assert.equal(request.targetSlot, 3, "the fresh factory carries the picker recipient")
      Assert.equal(request.itemKey, "MAIL_0", "the fresh factory carries the erased stationery")
      local draft = {
        schema = "g4-mail-v2",
        type = 0,
        author = { trainerId = 222, name = "GOLD", gender = 0, language = 2, game = 7 },
        icons = { "CHIKORITA/f0", "TOTODILE/f0", false },
        lines = { false, false, false },
      }
      return MailComposeState.new({
        letter = draft,
        catalog = fakeCatalog(),
        openEasyChat = function(_)
          local editor = fakeEditor({
            result = {
              cancelled = false,
              changed = true,
              inputMode = "buttons",
              message = { bank = 0, number = 0, words = { 0, 1 } },
            },
          })
          return editor
        end,
        prepare = function(_)
          return true
        end,
        manifest = manifest(),
        measureDisplay = measurement,
        audio = {
          play = function(sequence)
            cues[#cues + 1] = sequence
          end,
        },
        inputMode = "buttons",
        readNavigation = function()
          return { buttonsHeld = false }
        end,
      })
    end,
    mons = mons,
    manifest = manifest(),
    itemCatalog = {
      item = function(_, key)
        return { icon = key, name = key }
      end,
    },
    monCatalog = {
      species = function(_, key)
        return { name = key }
      end,
    },
    measureDisplay = measurement,
    audio = {
      play = function(sequence)
        cues[#cues + 1] = sequence
      end,
    },
    createPartyPicker = function(role, facts)
      Assert.equal(role, "compose", "the erased follow-up opens the give-target picker")
      Assert.equal(facts.itemKey, "MAIL_0", "the give-target picker carries the erased stationery")
      return picker
    end,
  })
  Assert.equal(state:status().lastPage, 0, "a single letter reports no second page")
  state:updateFixed({ { type = "confirm" } })
  state:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.equal(state:status().action, "erase")
  state:updateFixed({ { type = "confirm" } })
  Assert.equal(state:status().phase, "confirm", "erase confirmation shows compiled msg 10")
  Assert.deepEqual(state:status().prompt, { bank = 232, id = 10 })
  state:updateFixed({ { type = "confirm" } })
  Assert.equal(state:status().phase, "erased", "committed erasure reports msg 11 before the hold question")
  Assert.equal(committed[1].confirmation, true)
  state:updateFixed({ { type = "confirm" } })
  Assert.equal(state:status().phase, "holdMail", "the committed erase asks its hold follow-up")
  Assert.deepEqual(state:status().prompt, { bank = 232, id = 12 })
  state:updateFixed({ { type = "confirm" } })
  Assert.equal(state:status().phase, "picker", "accepting hold opens the recipient picker")
  for _ = 1, 10 do
    state:updateFixed({})
    if state:status().phase == "compose" then
      break
    end
  end
  local composing = state:status()
  Assert.equal(composing.phase, "compose", "the picked recipient opens the fresh letter composer")
  local draft = assert(composing.compose, "composition publishes its draft status")
  Assert.equal(draft.stationeryType, 0, "composition reuses the erased stationery type")
  Assert.equal(draft.author.name, "GOLD", "the follow-up captures the current author, not the erased one")
  for index = 1, 3 do
    Assert.isFalse(draft.lines[index], "the follow-up starts blank line " .. index)
  end
  -- The composer runs the shared editor for line one, then submits the
  -- whole letter; the mailbox commits custody once and feeds the Party
  -- give feedback back to the parked picker.
  for _ = 1, 60 do
    state:updateFixed({})
    if
      state:status().phase == "write" or (state:status().compose ~= nil and state:status().compose.phase == "write")
    then
      break
    end
  end
  -- Compose line one through the shared editor first: an all-blank
  -- letter would warn instead of submitting.
  state:updateFixed({ { type = "confirm" } })
  for _ = 1, 60 do
    state:updateFixed({})
    local cs = state:status()
    if cs.compose ~= nil and cs.compose.phase == "write" and cs.compose.lines[1] ~= false then
      break
    end
  end
  Assert.isTrue(state:status().compose.lines[1] ~= false, "the hold follow-up composes its first sentence")
  state:updateFixed({ { type = "navigate", direction = "down" } })
  state:updateFixed({ { type = "navigate", direction = "down" } })
  state:updateFixed({ { type = "navigate", direction = "down" } })
  state:updateFixed({ { type = "confirm" } })
  for _ = 1, 200 do
    state:updateFixed({})
    if state:status().phase == "picker" and #completions > 0 then
      break
    end
  end
  Assert.equal(state:status().phase, "picker", "submitted Mail parks feedback on its Party child")
  Assert.equal(completions[1].kind, "needs_confirmation", "the replacement question precedes the fresh draft")
  local feedback = completions[#completions]
  Assert.equal(feedback.kind, "changed", "the committed letter feeds the existing give feedback")
  Assert.equal(feedback.message.templateKey, "giveHeldItem", "an empty-handed recipient reports the plain give result")
  for _ = 1, 20 do
    state:updateFixed({})
  end
  pickerCancelled = true
  state:updateFixed({})
  Assert.equal(state:status().phase, "list", "acknowledging the feedback returns to the list")
  local decided = false
  for _, sequence in ipairs(cues) do
    decided = decided or sequence == "SEQ_SE_DP_DECIDE"
  end
  Assert.isTrue(decided, "confirmations cue DECIDE")
  state:dispose()
end

function T.hold_erased_mail_decline_reports_the_committed_bag_outcome()
  local values = {}
  for slot = 0, Mailbox.CAPACITY - 1 do
    values[slot + 1] = slot == 0 and letter("MISTY") or false
  end
  local mailbox = Mailbox.new({ schema = Mailbox.SCHEMA, slots = values })
  local fakeActions = {
    revisionSnapshot = function()
      return { mailboxRevision = 0, partyRevision = 0, bagRevision = 0 }
    end,
    preview = function(_, request)
      assert(request.kind == "eraseMailboxMessage")
      return {
        kind = "confirm",
        token = 1,
        request = request,
        letter = letter("MISTY"),
        itemKey = "MAIL_0",
        operation = "erase",
      }
    end,
    commit = function()
      return { kind = "changed", outcome = "discarded", itemKey = "MAIL_0" }
    end,
  }
  local state = MailboxScreenState.new({
    mode = "mailbox",
    partyHasMembers = true,
    mailbox = mailbox,
    mailActions = fakeActions,
    manifest = manifest(),
    itemCatalog = {
      item = function(_, key)
        return { icon = key, name = key }
      end,
    },
    measureDisplay = measurement,
    audio = { play = function() end },
    createPartyPicker = function()
      error("declining the hold question opens no picker")
    end,
  })
  state:updateFixed({ { type = "confirm" } })
  state:updateFixed({ { type = "navigate", direction = "down" } })
  state:updateFixed({ { type = "confirm" } })
  state:updateFixed({ { type = "confirm" } })
  state:updateFixed({ { type = "confirm" } })
  Assert.equal(state:status().phase, "holdMail")
  state:updateFixed({ { type = "cancel" } })
  local result = state:status()
  Assert.equal(result.phase, "result", "declining hold-mail reports the erase outcome")
  Assert.equal(result.outcome.outcome, "discarded", "the discarded outcome selects compiled msg 14")
  state:updateFixed({ { type = "confirm" } })
  Assert.equal(state:status().phase, "list")
  Assert.isNil(state:status().outcome, "returning to the list clears the reported outcome")
  state:dispose()
end

function T.read_and_confirm_close_paths_flash_with_unchanged_kinds()
  local reading = MailboxScreenState.new({
    mode = "read",
    manifest = manifest(),
    letter = letter("MISTY"),
    monCatalog = {
      iconSelection = function(_, icon)
        return icon
      end,
    },
    measureDisplay = measurement,
    audio = { play = function() end },
  })
  reading:updateFixed({ { type = "cancel" } })
  Assert.isNil(reading:result(), "the read close plays the flash before reporting closed")
  for _ = 1, 8 do
    reading:updateFixed({})
  end
  Assert.equal(reading:result().kind, "closed", "the read close keeps its result kind")
  reading:dispose()

  local confirming = MailboxScreenState.new({
    mode = "confirm",
    manifest = manifest(),
    prompt = { bank = 300, id = 1 },
    measureDisplay = measurement,
    audio = { play = function() end },
  })
  confirming:updateFixed({ { type = "confirm" } })
  for _ = 1, 8 do
    confirming:updateFixed({})
  end
  Assert.equal(confirming:result().kind, "confirmed", "the confirmed prompt keeps its result kind")
  confirming:dispose()

  local declined = MailboxScreenState.new({
    mode = "confirm",
    manifest = manifest(),
    prompt = { bank = 232, id = 10 },
    measureDisplay = measurement,
    audio = { play = function() end },
  })
  declined:updateFixed({ { type = "cancel" } })
  Assert.isNil(declined:result(), "the declined prompt plays the flash before reporting")
  for _ = 1, 8 do
    declined:updateFixed({})
  end
  Assert.equal(declined:result().kind, "declined", "the declined prompt keeps its result kind")
  declined:dispose()
end

return { tests = T }
