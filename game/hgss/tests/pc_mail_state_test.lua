-- Mailbox rows project occupied persistent slots without compacting custody.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local Mailbox = require("libs.hgss.src.save.Mailbox")
local MailComposeState = require("game.hgss.src.pc.MailComposeState")
local MailboxScreenState = require("game.hgss.src.pc.MailboxScreenState")
local ScreenTopology = require("libs.ui.src.ScreenTopology")

local T = {}

local function letter(name)
  return {
    schema = "g4-mail-v1",
    type = 0,
    author = { trainerId = 222, name = name, gender = 0, language = 2, game = 7 },
    icons = { false, false, false },
    lines = {
      { template = "mail.line.first", words = { "word.one", false } },
      { template = "mail.line.second", words = { "word.two", false } },
      { template = "mail.line.third", words = { "word.three", false } },
    },
  }
end

local function manifest()
  local stationery = {}
  for type = 0, 11 do
    stationery[type] = {
      itemKey = "MAIL_" .. type,
      background = {
        image = "assets/generated/pc/stationery-" .. type .. ".png",
        width = 256,
        height = 192,
        anchorX = 0,
        anchorY = 0,
      },
    }
  end
  -- Compose fixtures compile the retained templates with the two source
  -- EC slots each plus a small word dictionary in the first Easy Chat
  -- bank so the compose child browses real compiled entries.
  local function twoSlotTemplate()
    return {
      { kind = "text", value = "fixture" },
      { kind = "substitution" },
      { kind = "substitution" },
    }
  end
  local wordDictionary = {}
  for _, wordId in ipairs({ 0, 1, 2, 496, 497 }) do
    wordDictionary[tostring(wordId)] = { { kind = "text", value = "word" .. wordId } }
  end
  return {
    schema = "g4-pc-v2",
    mailbox = { background = {}, geometry = { visibleLetters = 10 }, pageSize = 10 },
    mail = {
      stationery = stationery,
      geometry = { iconSlots = 3 },
      text = {
        templates = {
          ["mail.line.first"] = twoSlotTemplate(),
          ["mail.line.second"] = twoSlotTemplate(),
          ["mail.line.third"] = twoSlotTemplate(),
        },
        words = {},
      },
      wordDictionary = wordDictionary,
    },
    text = {},
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
        return { icon = key }
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
  Assert.deepEqual(viewer.letter, letter("BROCK"), "reading follows the selected persistent slot")
  viewer.letter.author.name = "EDITED"
  Assert.deepEqual(mailbox:get(0), letter("MISTY"), "the read projection is copied from the owner")
  state:updateFixed({ { type = "cancel" } })
  Assert.equal(state:status().phase, "list", "back returns to the mailbox list")
  Assert.equal(mailbox:revision(), revision, "reading does not publish a mailbox revision")
  state:updateFixed({ { type = "cancel" } })
  Assert.isNil(state:result(), "quit plays the sprite-3 flash before reporting closed")
  Assert.isTrue(state:isActive(), "the list stays active while the quit flash runs")
  for _ = 1, 8 do
    state:updateFixed({})
  end
  Assert.equal(state:result().kind, "closed")
  state:dispose()
end

function T.source_page_hitboxes_route_mouse_and_touch_to_the_same_page_events()
  local slots = {}
  for slot = 0, Mailbox.CAPACITY - 1 do
    slots[slot] = letter("SENDER" .. slot)
  end
  local state = openMailbox(slots, true)
  state:updateFixed({ { type = "pointer_down", x = 48, y = 170 } })
  Assert.equal(state:status().page, 1, "the source right-page hitbox changes page")
  Assert.equal(state:status().selectedSlot, 10)
  state:updateFixed({ { type = "touch", x = 24, y = 170 } })
  Assert.equal(state:status().page, 0, "the source left-page hitbox accepts touch input")
  Assert.equal(state:status().selectedSlot, 0)
  state:dispose()
end

function T.second_page_tracks_its_persisted_slot_and_clamps_after_its_last_row_is_removed()
  local slots = {}
  for slot = 0, 9 do
    slots[slot] = letter("SENDER" .. slot)
  end
  slots[19] = letter("LAST")
  local state, mailbox = openMailbox(slots, true)
  state:updateFixed({ { type = "page", direction = "next" } })
  Assert.equal(state:status().page, 1)
  Assert.deepEqual(state:status().visibleSlots, { 19 }, "the second page keeps the sparse persisted slot")
  Assert.equal(state:status().selectedSlot, 19)

  local change = assert(mailbox:prepareChanges(mailbox:revision(), { { slot = 19, value = false } }))
  change.publish()
  state:updateFixed({})
  local status = state:status()
  Assert.equal(status.page, 0, "removing the final second-page row clamps to the remaining page")
  Assert.deepEqual(status.visibleSlots, { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 })
  Assert.equal(status.selectedSlot, 9, "focus clamps to the final row on the surviving page")
  state:dispose()
end

function T.page_controls_switch_a_full_mailbox_without_rekeying_its_rows()
  local slots = {}
  for slot = 0, Mailbox.CAPACITY - 1 do
    slots[slot] = letter("SENDER" .. slot)
  end
  local state = openMailbox(slots, true)
  Assert.deepEqual(state:status().visibleSlots, { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 })

  state:updateFixed({ { type = "page", direction = "next" } })
  local secondPage = state:status()
  Assert.equal(secondPage.page, 1)
  Assert.deepEqual(secondPage.visibleSlots, { 10, 11, 12, 13, 14, 15, 16, 17, 18, 19 })
  Assert.equal(secondPage.selectedSlot, 10)

  state:updateFixed({ { type = "page", direction = "previous" } })
  local firstPage = state:status()
  Assert.equal(firstPage.page, 0)
  Assert.deepEqual(firstPage.visibleSlots, { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 })
  Assert.equal(firstPage.selectedSlot, 0)
  state:dispose()
end

function T.list_shows_ten_mails_per_page_with_retail_grid_inputs()
  local slots = {}
  for slot = 0, Mailbox.CAPACITY - 1 do
    slots[slot] = letter("SENDER" .. slot)
  end
  local state = openMailbox(slots, true)
  local status = state:status()
  Assert.equal(#status.rows, 10, "the list shows ten mails per page")
  Assert.equal(status.cursorInput, 0, "the cursor starts on the first grid input")
  for input = 0, 9 do
    local row = status.rows[input + 1]
    Assert.equal(row.slot, input, "row order follows the page-relative slots")
    Assert.equal(row.input, input, "each status row carries its retail grid input")
    Assert.equal(row.selected, input == 0, "only the cursor row is selected")
  end
  state:updateFixed({ { type = "page", direction = "next" } })
  local second = state:status()
  Assert.equal(#second.rows, 10, "the second page shows ten mails")
  for input = 0, 9 do
    Assert.equal(second.rows[input + 1].slot, 10 + input)
    Assert.equal(second.rows[input + 1].input, input, "grid inputs restart on every page")
  end
  Assert.equal(second.cursorInput, 0, "paging parks the cursor on the first input")
  state:dispose()
end

function T.list_navigation_moves_columns_and_rows_on_the_retail_grid()
  local slots = {}
  for slot = 0, Mailbox.CAPACITY - 1 do
    slots[slot] = letter("SENDER" .. slot)
  end
  local state = openMailbox(slots, true)
  state:updateFixed({ { type = "navigate", direction = "right" } })
  Assert.equal(state:status().cursorInput, 1, "right moves across the row")
  Assert.equal(state:status().selectedSlot, 1)
  state:updateFixed({ { type = "navigate", direction = "right" } })
  Assert.equal(state:status().cursorInput, 1, "the right edge holds the cursor")
  state:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.equal(state:status().cursorInput, 3, "down moves down the column")
  state:updateFixed({ { type = "navigate", direction = "left" } })
  Assert.equal(state:status().cursorInput, 2, "left moves back across the row")
  state:updateFixed({ { type = "navigate", direction = "up" } })
  Assert.equal(state:status().cursorInput, 0, "up moves up the column")
  state:updateFixed({ { type = "navigate", direction = "up" } })
  Assert.equal(state:status().cursorInput, 0, "the top row holds the cursor")
  state:updateFixed({ { type = "navigate", direction = "left" } })
  Assert.equal(state:status().cursorInput, 0, "the left edge holds the cursor")
  state:dispose()
end

function T.list_navigation_reaches_close_and_returns_to_row_eight()
  local slots = {}
  for slot = 0, Mailbox.CAPACITY - 1 do
    slots[slot] = letter("SENDER" .. slot)
  end
  local state = openMailbox(slots, true)
  for _ = 1, 4 do
    state:updateFixed({ { type = "navigate", direction = "down" } })
  end
  Assert.equal(state:status().cursorInput, 8, "down walks the left column to row 8")
  state:updateFixed({ { type = "navigate", direction = "down" } })
  local closed = state:status()
  Assert.equal(closed.cursorInput, 10, "row 8 downs onto CLOSE")
  Assert.isNil(closed.selectedSlot, "CLOSE selects no mail row")
  state:updateFixed({ { type = "navigate", direction = "up" } })
  Assert.equal(state:status().cursorInput, 8, "up from CLOSE returns to row 8")
  Assert.equal(state:status().selectedSlot, 8)
  state:updateFixed({ { type = "navigate", direction = "right" } })
  state:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.equal(state:status().cursorInput, 10, "row 9 downs onto CLOSE")
  state:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.equal(state:status().cursorInput, 10, "down holds the cursor on CLOSE")
  state:dispose()
end

function T.list_navigation_skips_empty_cells()
  local state = openMailbox({ [0] = letter("MISTY"), [4] = letter("BROCK") }, true)
  state:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.equal(state:status().cursorInput, 4, "down skips the empty cells of the column")
  Assert.equal(state:status().selectedSlot, 4)
  state:updateFixed({ { type = "navigate", direction = "up" } })
  Assert.equal(state:status().cursorInput, 0, "up skips back to the occupied cell")
  state:dispose()

  local pair = openMailbox({ [0] = letter("MISTY"), [1] = letter("BROCK") }, true)
  pair:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.equal(pair:status().cursorInput, 1, "down with an empty column falls to the occupied neighbor")
  pair:updateFixed({ { type = "confirm" } })
  Assert.equal(pair:status().phase, "action", "the reached row still opens")
  pair:dispose()
end

function T.empty_mailbox_parks_the_cursor_on_close()
  local state = openMailbox({}, true)
  local status = state:status()
  Assert.equal(status.cursorInput, 10, "an empty list parks the cursor on CLOSE")
  Assert.isNil(status.selectedSlot, "an empty list selects no row")
  Assert.equal(#status.rows, 0, "an empty list shows no rows")
  state:updateFixed({ { type = "confirm" } })
  Assert.isNil(state:result(), "confirming CLOSE plays the flash before reporting closed")
  for _ = 1, 8 do
    state:updateFixed({})
  end
  Assert.equal(state:result().kind, "closed")
  state:dispose()
end

function T.pointer_taps_select_cells_and_close_on_the_retail_grid()
  local slots = {}
  for slot = 0, 9 do
    slots[slot] = letter("SENDER" .. slot)
  end
  local state = openMailbox(slots, true)
  -- Input 2 is the left column, second row: x 8-119, y 32-63.
  state:updateFixed({ { type = "pointer_down", x = 64, y = 48 } })
  local opened = state:status()
  Assert.equal(opened.phase, "action", "tapping a mail cell opens its action menu")
  Assert.equal(opened.selectedSlot, 2, "the tap selects the tapped grid cell")
  state:updateFixed({ { type = "cancel" } })
  Assert.equal(state:status().phase, "list", "the action menu still backs out to the list")
  -- CLOSE spans x 192-255, y 160-191.
  state:updateFixed({ { type = "pointer_down", x = 200, y = 170 } })
  Assert.isNil(state:result(), "tapping CLOSE plays the flash before reporting closed")
  for _ = 1, 8 do
    state:updateFixed({})
  end
  Assert.equal(state:result().kind, "closed")
  state:dispose()
end

function T.pointer_tap_on_an_empty_cell_keeps_the_cursor()
  local state = openMailbox({ [0] = letter("MISTY") }, true)
  -- Input 5 is the right column, third row: x 136-244, y 64-95.
  state:updateFixed({ { type = "pointer_down", x = 190, y = 80 } })
  local status = state:status()
  Assert.equal(status.phase, "list", "tapping an empty cell opens nothing")
  Assert.equal(status.cursorInput, 0, "the cursor stays on its occupied cell")
  Assert.equal(status.selectedSlot, 0)
  state:dispose()
end

function T.read_and_confirm_close_paths_flash_with_unchanged_kinds()
  local reading = MailboxScreenState.new({
    mode = "read",
    manifest = manifest(),
    letter = letter("MISTY"),
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
    mode = "read",
    manifest = manifest(),
    letter = letter("MISTY"),
    measureDisplay = measurement,
    audio = { play = function() end },
  })
  confirming:updateFixed({ { type = "confirm" } })
  for _ = 1, 8 do
    confirming:updateFixed({})
  end
  Assert.equal(confirming:result().kind, "closed", "the read confirm keeps its result kind")
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

  local agreed = MailboxScreenState.new({
    mode = "confirm",
    manifest = manifest(),
    prompt = { bank = 300, id = 1 },
    measureDisplay = measurement,
    audio = { play = function() end },
  })
  agreed:updateFixed({ { type = "confirm" } })
  for _ = 1, 8 do
    agreed:updateFixed({})
  end
  Assert.equal(agreed:result().kind, "confirmed", "the confirmed prompt keeps its result kind")
  agreed:dispose()
end

function T.hold_erased_mail_follow_up_reuses_the_picker_and_compiled_prompts()
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
        return { kind = "changed", outcome = "returned" }
      end
      return { kind = "changed", outcome = "held", targetSlot = intent.request.targetSlot }
    end,
  }
  local picked = false
  local picker = {
    updateFixed = function() end,
    takeResult = function()
      if not picked then
        picked = true
        return { kind = "selected", slot = 3 }
      end
      return nil
    end,
    dispose = function() end,
    draw = function() end,
  }
  local state = MailboxScreenState.new({
    mode = "mailbox",
    partyHasMembers = true,
    mailbox = mailbox,
    mailActions = fakeActions,
    manifest = manifest(),
    itemCatalog = {
      item = function(_, key)
        return { icon = key }
      end,
    },
    measureDisplay = measurement,
    audio = {
      play = function(sequence)
        cues[#cues + 1] = sequence
      end,
    },
    createPartyPicker = function()
      return picker
    end,
  })
  Assert.equal(state:status().lastPage, 0, "a single letter reports no second page")
  state:updateFixed({ { type = "confirm" } })
  state:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.equal(state:status().action, "erase")
  state:updateFixed({ { type = "confirm" } })
  local confirm = state:status()
  Assert.equal(confirm.phase, "confirm")
  Assert.deepEqual(confirm.prompt, { bank = 232, id = 10 }, "erase confirmation shows compiled msg 10")
  state:updateFixed({ { type = "confirm" } })
  Assert.equal(state:status().phase, "erased", "committed erasure reports msg 11 before the hold question")
  Assert.equal(committed[1].confirmation, true)
  state:updateFixed({ { type = "confirm" } })
  local hold = state:status()
  Assert.equal(hold.phase, "holdMail")
  Assert.deepEqual(hold.prompt, { bank = 232, id = 12 }, "the hold question shows compiled msg 12")
  state:updateFixed({ { type = "confirm" } })
  Assert.equal(state:status().phase, "picker")
  state:updateFixed({})
  local composing = state:status()
  Assert.equal(composing.phase, "compose", "the picker recipient opens word composition")
  Assert.isTrue(composing.compose ~= nil, "composition publishes its browser snapshot")
  Assert.equal(composing.compose.stationeryType, 0, "composition reuses the erased stationery")
  Assert.equal(composing.compose.author.name, "MISTY", "composition carries the retained author")
  Assert.equal(#composing.compose.slots, 6, "composition starts with every retained word slot empty")
  Assert.isFalse(composing.compose.submitReady, "empty slots cannot submit")
  -- Each retained slot browses the compiled dictionary: open the bank,
  -- open its words, and fill the first compiled entry.
  for _ = 1, 6 do
    state:updateFixed({ { type = "confirm" } })
    Assert.equal(state:status().compose.phase, "bank")
    state:updateFixed({ { type = "confirm" } })
    Assert.equal(state:status().compose.phase, "word")
    state:updateFixed({ { type = "confirm" } })
    Assert.equal(state:status().compose.phase, "edit")
  end
  local filled = state:status().compose
  Assert.isTrue(filled.submitReady, "filled slots satisfy the renderer contract")
  Assert.isNil(filled.error, "valid browsers report no composition error")
  state:updateFixed({ { type = "confirm" } })
  local done = state:status()
  Assert.equal(done.phase, "list", "submitting the composed letter returns to the list")
  Assert.isNil(done.compose, "submission closes the composition child")
  Assert.equal(done.outcome.outcome, "held", "the composed letter attaches through its own custody change")
  Assert.equal(committed[2].intent.operation, "compose")
  Assert.equal(committed[2].intent.request.kind, "composeGiveMail")
  Assert.equal(committed[2].intent.request.targetSlot, 3)
  Assert.isNil(committed[2].confirmation, "ready compose intents publish without confirmation")
  local composed = committed[2].intent.request.letter
  Assert.equal(composed.type, 0, "the composed letter reuses the erased stationery")
  Assert.equal(composed.author.name, "MISTY", "the composed letter keeps the retained author")
  for _, line in ipairs(composed.lines) do
    Assert.deepEqual(line.words, { "0", "0" }, "submission carries the browsed compiled words")
  end
  local decided, selected = false, false
  for _, sequence in ipairs(cues) do
    decided = decided or sequence == "SEQ_SE_DP_DECIDE"
    selected = selected or sequence == "SEQ_SE_DP_SELECT"
  end
  Assert.isTrue(decided, "confirmations cue DECIDE")
  Assert.isTrue(selected, "menu movement cues SELECT")
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
      return { kind = "changed", outcome = "discarded" }
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
        return { icon = key }
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

function T.mail_compose_browses_only_compiled_banks_and_cancels_cleanly()
  local played = {}
  local compose = MailComposeState.new({
    manifest = manifest(),
    stationeryType = 0,
    author = { trainerId = 222, name = "MISTY", gender = 0, language = 2, game = 7 },
    templates = { "mail.line.first", "mail.line.second", "mail.line.third" },
    measureDisplay = measurement,
    audio = {
      play = function(sequence)
        played[#played + 1] = sequence
      end,
    },
  })
  local status = compose:status()
  Assert.equal(status.phase, "edit")
  Assert.deepEqual(status.banks, { { bank = 0, count = 3 }, { bank = 1, count = 2 } })
  Assert.isNil(status.words, "the word list stays hidden until its bank opens")
  compose:updateFixed({ { type = "confirm" } })
  Assert.equal(compose:status().phase, "bank", "confirming a slot opens the bank browser")
  compose:updateFixed({ { type = "cancel" } })
  Assert.equal(compose:status().phase, "edit", "cancelling the bank browser returns to the slots")
  compose:updateFixed({ { type = "cancel" } })
  local result = compose:takeResult()
  Assert.deepEqual(result, { kind = "cancelled" }, "cancelling the slots closes without a letter")
  Assert.isNil(compose:takeResult(), "composition results are taken exactly once")
  Assert.isTrue(#played > 0, "composition cues its navigation")
  compose:dispose()
end

function T.mail_compose_rejects_unknown_words_and_mismatched_templates()
  local compose = MailComposeState.new({
    manifest = manifest(),
    stationeryType = 0,
    author = { trainerId = 222, name = "MISTY", gender = 0, language = 2, game = 7 },
    templates = { "mail.line.first", "mail.line.second", "mail.line.third" },
    measureDisplay = measurement,
    audio = { play = function() end },
  })
  local ok, reason = compose:submit()
  Assert.isFalse(ok, "empty slots cannot submit")
  Assert.equal(reason, "incomplete")
  Assert.equal(compose:status().error, "incomplete", "the failed submit publishes its reason")
  local wordOk = pcall(function()
    compose:setWord(1, 1, "9999")
  end)
  Assert.isFalse(wordOk, "uncompiled words never reach the custody intent")
  compose:setWord(1, 1, "0")
  compose:setWord(1, 2, "1")
  local partial, partialReason = compose:submit()
  Assert.isFalse(partial, "partially filled lines cannot submit")
  Assert.equal(partialReason, "incomplete")
  compose:dispose()

  local singleSlot = manifest()
  singleSlot.mail.text.templates["mail.line.first"] = { { kind = "substitution" } }
  local mismatched = MailComposeState.new({
    manifest = singleSlot,
    stationeryType = 0,
    author = { trainerId = 222, name = "MISTY", gender = 0, language = 2, game = 7 },
    templates = { "mail.line.first", false, false },
    measureDisplay = measurement,
    audio = { play = function() end },
  })
  mismatched:setWord(1, 1, "0")
  mismatched:setWord(1, 2, "1")
  local slotOk, slotReason = mismatched:validate()
  Assert.isFalse(slotOk, "slot counts mirror the renderer expansion check")
  Assert.equal(slotReason, "invalid_letter")
  mismatched:dispose()
end

function T.compose_cancel_reports_the_committed_erase_outcome_with_custody_unchanged()
  local values = {}
  for slot = 0, Mailbox.CAPACITY - 1 do
    values[slot + 1] = slot == 0 and letter("MISTY") or false
  end
  local mailbox = Mailbox.new({ schema = Mailbox.SCHEMA, slots = values })
  local mailboxBefore = mailbox:capture()
  local fakeActions = {
    revisionSnapshot = function()
      return { mailboxRevision = 0, partyRevision = 0, bagRevision = 0 }
    end,
    preview = function(_, request)
      assert(request.kind == "eraseMailboxMessage", "cancelling composition previews no custody change")
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
      return { kind = "changed", outcome = "returned" }
    end,
  }
  local picked = false
  local picker = {
    updateFixed = function() end,
    takeResult = function()
      if not picked then
        picked = true
        return { kind = "selected", slot = 3 }
      end
      return nil
    end,
    dispose = function() end,
    draw = function() end,
  }
  local state = MailboxScreenState.new({
    mode = "mailbox",
    partyHasMembers = true,
    mailbox = mailbox,
    mailActions = fakeActions,
    manifest = manifest(),
    itemCatalog = {
      item = function(_, key)
        return { icon = key }
      end,
    },
    measureDisplay = measurement,
    audio = { play = function() end },
    createPartyPicker = function()
      return picker
    end,
  })
  state:updateFixed({ { type = "confirm" } })
  state:updateFixed({ { type = "navigate", direction = "down" } })
  state:updateFixed({ { type = "confirm" } })
  state:updateFixed({ { type = "confirm" } })
  Assert.equal(state:status().phase, "erased")
  state:updateFixed({ { type = "confirm" } })
  Assert.equal(state:status().phase, "holdMail")
  state:updateFixed({ { type = "confirm" } })
  Assert.equal(state:status().phase, "picker")
  state:updateFixed({})
  Assert.equal(state:status().phase, "compose", "the picker recipient opens word composition")
  state:updateFixed({ { type = "cancel" } })
  local result = state:status()
  Assert.equal(result.phase, "result", "cancelling composition returns to the erase outcome")
  Assert.isNil(result.compose, "cancelling composition closes its child")
  Assert.equal(result.outcome.outcome, "returned", "the committed erase outcome still stands")
  Assert.deepEqual(mailbox:capture(), mailboxBefore, "cancelling composition changes no custody")
  state:updateFixed({ { type = "confirm" } })
  Assert.equal(state:status().phase, "list")
  Assert.isNil(state:status().outcome, "returning to the list clears the reported outcome")
  state:dispose()
end

function T.mail_compose_submits_single_slot_templates_with_trailing_null()
  local single = manifest()
  local function oneSlotTemplate()
    return {
      { kind = "text", value = "fixture" },
      { kind = "substitution" },
    }
  end
  single.mail.text.templates["mail.line.first"] = oneSlotTemplate()
  single.mail.text.templates["mail.line.second"] = oneSlotTemplate()
  single.mail.text.templates["mail.line.third"] = oneSlotTemplate()
  local compose = MailComposeState.new({
    manifest = single,
    stationeryType = 0,
    author = { trainerId = 222, name = "MISTY", gender = 0, language = 2, game = 7 },
    templates = { "mail.line.first", "mail.line.second", "mail.line.third" },
    measureDisplay = measurement,
    audio = { play = function() end },
  })
  local status = compose:status()
  Assert.equal(#status.slots, 3, "single-slot templates expose one fillable slot per line")
  Assert.isFalse(status.submitReady, "empty single-slot lines cannot submit")
  compose:setWord(1, 1, "0")
  compose:setWord(2, 1, "1")
  compose:setWord(3, 1, "2")
  Assert.isTrue(compose:status().submitReady, "filled first fields satisfy the retail slot rule")
  local ok, reason = compose:submit()
  Assert.isTrue(ok, "single-slot letters submit with trailing EC_WORD_NULL: " .. tostring(reason))
  local result = compose:takeResult()
  Assert.equal(result.kind, "submitted")
  for _, line in ipairs(result.letter.lines) do
    Assert.equal(#line.words, 2, "stored words keep both EC fields")
    Assert.equal(line.words[2], false, "the trailing field stays EC_WORD_NULL")
  end
  Assert.equal(result.letter.lines[1].words[1], "0")
  compose:dispose()
end

function T.mail_compose_submits_zero_slot_templates()
  local fixed = manifest()
  local plain = { { kind = "text", value = "plain" } }
  fixed.mail.text.templates["mail.line.first"] = plain
  fixed.mail.text.templates["mail.line.second"] = plain
  fixed.mail.text.templates["mail.line.third"] = plain
  local compose = MailComposeState.new({
    manifest = fixed,
    stationeryType = 0,
    author = { trainerId = 222, name = "MISTY", gender = 0, language = 2, game = 7 },
    templates = { "mail.line.first", "mail.line.second", "mail.line.third" },
    measureDisplay = measurement,
    audio = { play = function() end },
  })
  local status = compose:status()
  Assert.deepEqual(status.slots, {}, "zero-slot templates expose no fillable slots")
  Assert.isTrue(status.submitReady, "slotless letters submit immediately")
  local ok, reason = compose:submit()
  Assert.isTrue(ok, "zero-slot letters submit with null fields: " .. tostring(reason))
  local result = compose:takeResult()
  Assert.equal(result.kind, "submitted")
  for _, line in ipairs(result.letter.lines) do
    Assert.deepEqual(line.words, { false, false }, "slotless lines keep both EC_WORD_NULL fields")
  end
  compose:dispose()
end

function T.mail_compose_refuses_trailing_garbage_on_short_templates()
  local single = manifest()
  single.mail.text.templates["mail.line.first"] = {
    { kind = "text", value = "fixture" },
    { kind = "substitution" },
  }
  local compose = MailComposeState.new({
    manifest = single,
    stationeryType = 0,
    author = { trainerId = 222, name = "MISTY", gender = 0, language = 2, game = 7 },
    templates = { "mail.line.first", false, false },
    measureDisplay = measurement,
    audio = { play = function() end },
  })
  compose:setWord(1, 1, "0")
  compose:setWord(1, 2, "1")
  local ok, reason = compose:validate()
  Assert.isFalse(ok, "a filled trailing field on a single-slot template is garbage")
  Assert.equal(reason, "invalid_letter")
  local submitted, submitReason = compose:submit()
  Assert.isFalse(submitted, "trailing garbage cannot submit")
  Assert.equal(submitReason, "invalid_letter")
  Assert.equal(compose:status().error, "invalid_letter", "the failed submit publishes its reason")
  compose:dispose()
end

function T.mail_compose_draws_short_letters_without_asserting()
  local mixed = manifest()
  mixed.mail.text.templates["mail.line.first"] = {
    { kind = "text", value = "fixture" },
    { kind = "substitution" },
  }
  mixed.mail.text.templates["mail.line.second"] = { { kind = "text", value = "plain" } }
  local compose = MailComposeState.new({
    manifest = mixed,
    stationeryType = 0,
    author = { trainerId = 222, name = "MISTY", gender = 0, language = 2, game = 7 },
    templates = { "mail.line.first", "mail.line.second", "mail.line.third" },
    measureDisplay = measurement,
    audio = { play = function() end },
  })
  compose:setWord(1, 1, "0")
  compose:setWord(3, 1, "1")
  compose:setWord(3, 2, "2")
  local drawn = {}
  local resources = {
    textRenderer = {
      fontDef = { lineHeight = 16, charmap = {} },
      windowBackgroundColor = function()
        return { 1, 1, 1, 1 }
      end,
      drawText = function() end,
      drawLine = function(_, row)
        drawn[#drawn + 1] = row
      end,
    },
    windowRenderer = {
      drawWindow = function() end,
    },
    applicationFrameIndex = 1,
  }
  compose:draw(resources)
  Assert.isTrue(#drawn > 0, "the stored short letter expands through the draw path")
  compose:dispose()
end

return { tests = T }
