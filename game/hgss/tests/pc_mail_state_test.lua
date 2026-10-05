-- Mailbox rows project occupied persistent slots without compacting custody.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local Mailbox = require("libs.hgss.src.save.Mailbox")
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
  return {
    schema = "g4-pc-v1",
    mailbox = { background = {}, geometry = { visibleLetters = 10 }, pageSize = 10 },
    mail = { stationery = stationery, geometry = { iconSlots = 3 }, text = { templates = {}, words = {} } },
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
    itemCatalog = { item = function(_, key) return { icon = key } end },
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

return { tests = T }
