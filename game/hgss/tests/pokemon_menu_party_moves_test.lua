-- Party-menu field-move membership and HP-transfer routing through the
-- production menu flow: only the source party-menu move identities enter
-- the menu in move-slot order, and the two HP-transfer moves reach the
-- existing party-action owner instead of field runtime. ROM-free: a
-- hand-built mon service stages semantic move keys the shared catalog
-- fixture never needs to know (the view projection copies keys without
-- catalog validation), while the synthetic presentation manifest carries
-- the layout sections the party child resolves.

local Assert = require("tests.support.Assert")
local BagCursor = require("libs.hgss.src.items.BagCursor")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local HgssBagService = require("libs.hgss.src.items.HgssBagService")
local ItemFixture = require("libs.items.tests.item_fixture")
local MailActions = require("libs.hgss.src.field.MailActions")
local Mailbox = require("libs.hgss.src.save.Mailbox")
local PartyPresentationFixture = require("tests.support.PartyPresentationFixture")
local ScreenTopology = require("libs.ui.src.ScreenTopology")

local T = {}

local function stubMeasurement()
  return {
    width = 256,
    height = 192,
    topology = ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = 256, height = 192 },
      touch = true,
      role = "world",
    }),
    pixelRatio = 1,
    signature = "party-moves-test:256x192",
  }
end

---@param moveKeys string[] semantic move keys in move-slot order
---@return table fake mon service with one or two staged mons
local function fakeMons(moveKeys, secondMoves)
  local catalog = CatalogFixture.makeCatalog()
  local revision = 5
  local function monRecord(moves)
    local entries = {}
    for _, key in ipairs(moves) do
      entries[#entries + 1] = { move = key, pp = 10, ppUps = 0 }
    end
    return {
      species = "CHIKORITA",
      form = 0,
      nickname = nil,
      personality = 0,
      condition = { status = 0, currentHp = 20 },
      moves = entries,
      heldItem = "NONE",
      isEgg = false,
      shinyLeaves = 0,
      capsule = nil,
    }
  end
  local records = { monRecord(moveKeys) }
  if secondMoves ~= nil then
    records[2] = monRecord(secondMoves)
  end
  return {
    partyCount = function()
      return #records
    end,
    partyRevision = function()
      return revision
    end,
    partyMon = function(_, slot)
      return records[slot + 1]
    end,
    partyMonDerived = function()
      return { level = 5, maxHp = 20 }
    end,
    catalog = function()
      return catalog
    end,
    swapPartyMons = function()
      revision = revision + 1
    end,
  }
end

---@param mons table
---@return table rig with the live flow and recording ports
local function openPartyFlow(mons)
  local Flow = require("game.hgss.src.field.PokemonMenuFlow")
  local bag = HgssBagService.new({ catalog = ItemFixture.makeCatalog() })
  local commits = {}
  local checks = {}
  local mailbox = Mailbox.new()
  local pcManifest = require("tests.support.PcPresentationFixture").manifest()
  local flow = Flow.new({
    root = "party",
    mons = mons,
    bag = bag,
    bagCursor = BagCursor.new(),
    partyActions = {
      preview = function(_)
        return { kind = "preview" }
      end,
      commit = function(_, request)
        commits[#commits + 1] = request
        return { kind = "no_op" }
      end,
    },
    mailActions = MailActions.new({ mons = mons, mailbox = mailbox, bag = bag, manifest = pcManifest }),
    mailbox = mailbox,
    pcManifest = pcManifest,
    fieldMoves = {
      check = function(request)
        checks[#checks + 1] = request
        return { kind = "ok" }
      end,
    },
    assets = {
      bagManifest = {},
      partyManifest = PartyPresentationFixture.manifest(),
      uiManifest = FieldUiFixture.manifest(),
      monCatalog = {
        moveByNativeId = function()
          error("move picks never open in the membership suite", 0)
        end,
      },
      itemCatalog = bag:catalog(),
      heroGender = "male",
    },
    measureDisplay = stubMeasurement,
    prepareIcons = function(_)
      return true, nil
    end,
    cancelIconPreparation = function() end,
  })
  return { flow = flow, mons = mons, bag = bag, commits = commits, checks = checks }
end

local function childStatus(rig)
  local status = rig.flow:status()
  Assert.isTrue(status.open, "the party flow stays open")
  return assert(status.child, "the party page carries its child status")
end

local function openContextMenu(rig)
  -- A fresh party page clears its open before input: wait for the leaf
  -- to turn interactive, then run out the handover ticks that still
  -- drop input so the confirm acts.
  for _ = 1, 30 do
    if childStatus(rig).phase == "interactive" then
      break
    end
    rig.flow:updateFixed({})
  end
  rig.flow:updateFixed({})
  rig.flow:updateFixed({})
  rig.flow:updateFixed({ { type = "confirm" } })
  local child = childStatus(rig)
  Assert.equal(child.state, "context", "confirming the lead opens its context menu")
  return child
end

---@param rig table
---@param kinds string[] expected entry kinds in order
local function assertMenuKinds(rig, kinds)
  local menu = assert(childStatus(rig).menu, "the context menu stays open")
  local actual = {}
  for _, entry in ipairs(menu) do
    actual[#actual + 1] = entry.kind
  end
  Assert.deepEqual(actual, kinds)
end

function T.only_source_field_moves_enter_the_menu_in_move_slot_order()
  local rig = openPartyFlow(fakeMons({ "TACKLE", "DEFOG", "CUT", "FLY" }))
  openContextMenu(rig)
  assertMenuKinds(rig, { "summary", "switch", "item", "quit", "field_move", "field_move" })
  local menu = childStatus(rig).menu
  Assert.equal(menu[5].move, "CUT", "admitted moves keep their learned identity")
  Assert.equal(menu[5].moveSlot, 2, "admitted moves keep their learned move slot")
  Assert.equal(menu[6].move, "FLY")
  Assert.equal(menu[6].moveSlot, 3)
  for _, entry in ipairs(menu) do
    Assert.isTrue(
      entry.move ~= "TACKLE" and entry.move ~= "DEFOG",
      "ordinary moves and field-check-only moves never enter the party menu"
    )
  end
end

function T.base_entries_keep_their_source_order_before_field_moves()
  local rig = openPartyFlow(fakeMons({ "SURF" }))
  openContextMenu(rig)
  local menu = assert(childStatus(rig).menu, "the context menu stays open")
  Assert.equal(menu[1].kind, "summary")
  Assert.equal(menu[2].kind, "switch")
  Assert.equal(menu[3].kind, "item")
  Assert.equal(menu[4].kind, "quit")
  Assert.equal(menu[5].kind, "field_move")
  Assert.equal(menu[5].move, "SURF")
  Assert.equal(#menu, 5, "one admitted move appends exactly one entry")
end

function T.hp_transfer_moves_enter_as_transfer_entries()
  local rig = openPartyFlow(fakeMons({ "MILK_DRINK", "SOFTBOILED" }))
  openContextMenu(rig)
  assertMenuKinds(rig, { "summary", "switch", "item", "quit", "transfer_hp", "transfer_hp" })
  local menu = childStatus(rig).menu
  Assert.equal(menu[5].moveSlot, 0, "Milk Drink keeps its learned move slot")
  Assert.equal(menu[6].moveSlot, 1, "Softboiled keeps its learned move slot")
end

function T.hp_transfer_reaches_the_party_action_owner_instead_of_field_runtime()
  local rig = openPartyFlow(fakeMons({ "MILK_DRINK" }, { "TACKLE" }))
  openContextMenu(rig)
  local menu = assert(childStatus(rig).menu, "the context menu stays open")
  local target = nil
  for position, entry in ipairs(menu) do
    if entry.kind == "transfer_hp" then
      target = position
    end
  end
  Assert.notNil(target, "Milk Drink enters as a transfer entry")
  local child = childStatus(rig)
  while (child.menuIndex or 0) < target do
    rig.flow:updateFixed({ { type = "navigate", direction = "down" } })
    child = childStatus(rig)
  end
  rig.flow:updateFixed({ { type = "confirm" } })
  -- The press gate owns its ticks before dispatch; the target pick then
  -- answers on the second slot.
  for _ = 1, 6 do
    rig.flow:updateFixed({})
    if #rig.commits > 0 then
      break
    end
    if childStatus(rig).state == "choose_hp_target" then
      break
    end
  end
  local state = childStatus(rig).state
  if state == "choose_hp_target" then
    -- The source dpad reaches the second slot laterally from the lead:
    -- down the lead column addresses an empty slot in this two-mon party.
    rig.flow:updateFixed({ { type = "navigate", direction = "right" } })
    rig.flow:updateFixed({ { type = "confirm" } })
    for _ = 1, 6 do
      rig.flow:updateFixed({})
      if #rig.commits > 0 then
        break
      end
    end
  end
  Assert.equal(#rig.commits, 1, "the transfer commits exactly once through party actions")
  local request = rig.commits[1]
  Assert.equal(request.kind, "transfer_hp")
  Assert.equal(request.slot, 0, "the donor is the menu slot")
  Assert.equal(request.targetSlot, 1, "the picked slot is the transfer target")
  Assert.equal(request.moveSlot, 0, "the commit keeps the learned move slot")
  Assert.equal(request.partyRevision, rig.mons:partyRevision())
  Assert.equal(request.bagRevision, rig.bag:revision())
  Assert.equal(#rig.checks, 0, "HP transfer never reaches field runtime checks")
end

function T.the_full_source_set_enters_in_move_slot_order_without_outsiders()
  -- Menus open at most eight source entries, so the sixteen admitted
  -- identities prove across four openable groups; each group keeps its
  -- learned order with learned move slots.
  local groups = {
    { "CUT", "FLY", "SURF", "STRENGTH" },
    { "ROCK_SMASH", "WATERFALL", "ROCK_CLIMB", "WHIRLPOOL" },
    { "FLASH", "TELEPORT", "DIG", "SWEET_SCENT" },
    { "CHATTER", "HEADBUTT", "MILK_DRINK", "SOFTBOILED" },
  }
  local seen = {}
  for _, moves in ipairs(groups) do
    local rig = openPartyFlow(fakeMons(moves))
    openContextMenu(rig)
    local menu = assert(childStatus(rig).menu, "the context menu stays open")
    Assert.equal(#menu, 8, "four admitted moves append to the four base entries")
    for position, key in ipairs(moves) do
      local entry = menu[position + 4]
      Assert.equal(entry.move, key, key .. " keeps its learned identity")
      Assert.equal(entry.moveSlot, position - 1, key .. " keeps its learned move slot")
      local expected = (key == "MILK_DRINK" or key == "SOFTBOILED") and "transfer_hp" or "field_move"
      Assert.equal(entry.kind, expected, key .. " rides its source owner")
      seen[key] = expected
    end
  end
  local count = 0
  for _ in pairs(seen) do
    count = count + 1
  end
  Assert.equal(count, 16, "every source party-menu identity enters exactly once")
  local rig = openPartyFlow(fakeMons({ "TACKLE", "DEFOG", "CUT" }))
  openContextMenu(rig)
  local menu = assert(childStatus(rig).menu, "the context menu stays open")
  Assert.equal(#menu, 5, "only the admitted move appends to the base entries")
  Assert.equal(menu[5].move, "CUT")
  for _, entry in ipairs(menu) do
    Assert.isTrue(
      entry.move ~= "TACKLE" and entry.move ~= "DEFOG",
      "ordinary moves and field-check-only moves never enter the party menu"
    )
  end
end

return { tests = T }
