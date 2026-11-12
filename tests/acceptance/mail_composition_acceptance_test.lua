-- Field letter composition through the production menu flows: fresh
-- stationery Give from the Bag and the Party menu opens one three-line
-- letter screen whose sentence editor is the shared word editor, the
-- Mailbox erase-and-hold follow-up starts a genuinely new letter, final
-- acceptance moves custody atomically with written-letter statistics,
-- saved letters keep their identities and appearance across every save
-- location, and the native stationery plan prepares without drawing.
-- Every leg boots the real field runtime over real maps, scripts, and
-- state owners; only host audio, host input edges, the wall clock, and
-- the save root are recording boundaries. No commercial text is asserted
-- and no editor, custody, or migration implementation is faked.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FieldStatePresentationFixture = require("tests.support.FieldStatePresentationFixture")
local Drive = require("tests.support.EasyChatScriptDrive")

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = {
      "field-runtime",
      "map:7",
      "map-data:7",
      "pc:global",
    },
    tags = { "mail", "easychat" },
  },
  tests = {},
}

local MAP = "MAP_BURNED_TOWER_1F"
local STATIONERY = "GRASS_MAIL"
local ORDINARY_HELD = "POTION"

---@param _ unknown
local function void(_) end

local function requireVersions(context)
  if context ~= nil and type(context.hasCapability) == "function" then
    if not context:hasCapability("rom_dump") then
      context:skip("requires rom_dump and prepared assets")
    end
  end
  local versions = { AcceptanceHarness.defaultVersion() }
  if #versions == 0 then
    if context ~= nil and type(context.hasCapability) == "function" then
      context:skip("requires rom_dump and prepared assets")
    end
    error("letter journeys need a ready ROM cache", 0)
  end
  return versions
end

---@param fn fun(game: table)
---@param context unknown
local function withMailGame(fn, context)
  requireVersions(context)
  local game = AcceptanceHarness.new():boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = MAP,
    save = "fresh",
    fieldOptions = {
      recordingScriptHosts = true,
      derivedAssets = FieldStatePresentationFixture.iconHost().derivedAssets,
    },
  })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    game.runtime:bindPartyIconPreparation(function(_)
      return true
    end, function() end)
    Drive.requireScriptModules()
    local binding, _ = Drive.bindHeadlessEditor(game.runtime)
    local unbind =
      assert(game.runtime.unbindEasyChatPreparation, "the field runtime releases the word editor preparation binding")
    -- Headless journeys never acquire image leases: the Mail preparation
    -- resolves ready at once, exactly like the headless editor lease.
    -- Real readiness, failure causes, and drawing stay with the
    -- presentation and graphics paths.
    local bindMail = assert(game.runtime.bindMailPreparation, "the field runtime releases the Mail preparation binding")
    local mailBinding = bindMail(game.runtime, function(_)
      return true
    end)
    local unbindMail =
      assert(game.runtime.unbindMailPreparation, "the field runtime releases the Mail preparation binding")
    local okInner, errInner = xpcall(function()
      fn(game)
    end, debug.traceback)
    unbindMail(game.runtime, mailBinding)
    unbind(game.runtime, binding)
    if not okInner then
      error(errInner, 0)
    end
    Assert.equal(game:renderAttempts(), 0, "letter journeys stop before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

---@param game table
local function composition(game)
  return assert(game.runtime.partyMenu, "the production runtime owns the menu composition")
end

---@param game table
local function giftTrio(game)
  local service = assert(game.runtime.monService, "the field runtime owns the live mon service")
  Assert.isTrue(service:giveMon({ species = "CHIKORITA", level = 5 }), "setup gift must enter the party")
  Assert.isTrue(service:giveMon({ species = "TOTODILE", level = 5 }), "setup gift must enter the party")
  Assert.isTrue(service:giveMon({ species = "CYNDAQUIL", level = 5 }), "setup gift must enter the party")
  Assert.equal(service:partyCount(), 3, "the letter journey starts with three party members")
end

---@param game table
local function stockBag(game)
  local bag = assert(game.runtime.bagService, "the field runtime owns the live bag service")
  Assert.isTrue(bag:add(STATIONERY, 2), "the letter journey stocks two stationery")
  Assert.isTrue(bag:add(ORDINARY_HELD, 1), "the letter journey stocks one ordinary held item")
end

---@param flow table
---@return table status
local function flowStatus(flow)
  local status = flow:status()
  Assert.isTrue(status.open, "the production flow stays open through the journey")
  return status
end

---@param flow table
---@param events table?
---@return table status
local function drive(flow, events)
  flow:updateFixed(events or {})
  for _ = 1, 10 do
    if flow:status().transition == nil then
      break
    end
    flow:updateFixed({})
  end
  return flowStatus(flow)
end

---@param flow table
---@param label string
---@param maxSteps integer
---@param predicate fun(status: table): boolean
---@return table status
local function driveUntil(flow, label, maxSteps, predicate)
  for _ = 1, maxSteps do
    local status = flowStatus(flow)
    if predicate(status) then
      return status
    end
    flow:updateFixed({})
  end
  error("the production flow never reaches " .. label, 0)
end

---@param status table
---@return table child
local function flowChild(status)
  return assert(status.child, "the active page carries its child status")
end

---@param flow table
local function drainOpen(flow)
  driveUntil(flow, "the open clears before input", 30, function(current)
    local child = current.child
    return child ~= nil and child.phase == "interactive"
  end)
  drive(flow, {})
  drive(flow, {})
end

---@param flow table
---@param pocket string
---@return table status
local function gotoPocket(flow, pocket)
  for _ = 1, 30 do
    local status = flowStatus(flow)
    local child = flowChild(status)
    if child.pocket == pocket and child.focus == "items" then
      return status
    end
    if child.focus == "tabs" then
      if child.tabFocusPocket == pocket then
        status = drive(flow, { { type = "confirm" } })
        status = drive(flow, { { type = "navigate", direction = "down" } })
      else
        status = drive(flow, { { type = "navigate", direction = "right" } })
      end
    else
      status = drive(flow, { { type = "navigate", direction = "up" } })
    end
  end
  error("the bag never reaches pocket " .. pocket, 0)
end

local BAG_NEIGHBORS = {
  [0] = { up = 2, down = 2, left = 1, right = 1 },
  [1] = { up = 3, down = 3, left = 0, right = 0 },
  [2] = { up = 0, down = 0, left = 4, right = 3 },
  [3] = { up = 1, down = 1, left = 2, right = 4 },
  [4] = { up = 4, down = 4, left = 3, right = 2 },
}

---@param flow table
---@param id string
---@return table status
local function chooseBagAction(flow, id)
  driveUntil(flow, "the Bag opening settles", 30, function(current)
    return current.child ~= nil and current.child.phase == "interactive"
  end)
  local status = drive(flow, { { type = "confirm" } })
  status = driveUntil(flow, "the stable action menu", 30, function(current)
    return current.child ~= nil and current.child.state == "action_menu"
  end)
  local child = flowChild(status)
  Assert.equal(child.state, "action_menu", "confirming an item must open the action menu")
  local target = nil
  for _, action in ipairs(assert(child.actions, "the action menu lists its actions")) do
    if action.id == id then
      target = assert(action.slot, "menu actions carry their physical slot")
    end
  end
  Assert.notNil(target, "the action menu must offer " .. id .. " for the selected stationery")
  for _ = 1, 8 do
    status = flowStatus(flow)
    child = flowChild(status)
    if child.actionNode == target then
      status = drive(flow, { { type = "confirm" } })
      return driveUntil(flow, "the settled action transition", 30, function(current)
        return current.page ~= "bag_browse" or current.child == nil
      end)
    end
    local node = assert(child.actionNode, "the action menu exposes its node")
    local queue = { { node = node, path = {} } }
    local seen = { [node] = true }
    local path = nil
    local head = 1
    while head <= #queue and path == nil do
      local current = queue[head]
      head = head + 1
      for _, direction in ipairs({ "up", "down", "left", "right" }) do
        local nextNode = BAG_NEIGHBORS[current.node][direction]
        if not seen[nextNode] then
          local nextPath = {}
          for index, step in ipairs(current.path) do
            nextPath[index] = step
          end
          nextPath[#nextPath + 1] = direction
          if nextNode == target then
            path = nextPath
            break
          end
          seen[nextNode] = true
          queue[#queue + 1] = { node = nextNode, path = nextPath }
        end
      end
    end
    local direction = assert(path and path[1], "the action node must be reachable")
    status = drive(flow, { { type = "navigate", direction = direction } })
  end
  error("the action menu never selects " .. id, 0)
end

---@param flow table
---@param slot integer
---@param direction string?
---@return table status
local function choosePartySlot(flow, slot, direction)
  for _ = 1, 30 do
    if flowChild(flowStatus(flow)).cursorNode ~= nil then
      break
    end
    drive(flow, {})
  end
  for _ = 1, 12 do
    local status = flowStatus(flow)
    local child = flowChild(status)
    if child.cursorNode == slot then
      return drive(flow, { { type = "confirm" } })
    end
    drive(flow, { { type = "navigate", direction = direction or "right" } })
  end
  error("the party cursor never reaches slot " .. tostring(slot), 0)
end

---@param flow table
---@param kind string
---@return table status
local function choosePartyMenu(flow, kind)
  for _ = 1, 40 do
    local status = flowStatus(flow)
    local child = flowChild(status)
    local menu = assert(child.menu, "the party context menu must be open")
    local index = nil
    for position, entry in ipairs(menu) do
      if entry.kind == kind then
        index = position
      end
    end
    Assert.notNil(index, "the party menu must offer " .. kind)
    if child.menuIndex == index then
      drive(flow, { { type = "confirm" } })
      return driveUntil(flow, "the gated menu dispatch", 10, function(current)
        local dispatched = flowChild(current)
        return dispatched.menuPress == nil and (dispatched.menu ~= menu or dispatched.state ~= "context")
      end)
    end
    local direction = child.menuIndex < index and "down" or "up"
    status = drive(flow, { { type = "navigate", direction = direction } })
  end
  error("the party menu never selects " .. kind, 0)
end

-- Searches a production status tree for the three-line letter draft the
-- fresh composer publishes. Returns nil while no composer owns the tick.
---@param status table
---@return table? composer child status
local function findComposer(status)
  local seen = {}
  local function visit(node)
    if type(node) ~= "table" or seen[node] then
      return nil
    end
    seen[node] = true
    if type(node.lines) == "table" and #node.lines == 3 then
      return node
    end
    for _, key in ipairs({ "child", "compose", "letter", "application" }) do
      local found = visit(node[key])
      if found ~= nil then
        return found
      end
    end
    return nil
  end
  return visit(status)
end

-- Searches a production status tree for the nested shared word editor,
-- which owns the display input key while it edits one sentence.
---@param status table
---@return table? editor child status
local function findNestedEditor(status)
  local seen = {}
  local function visit(node)
    if type(node) ~= "table" or seen[node] then
      return nil
    end
    seen[node] = true
    -- The composer forwards the nested profile while the child owns
    -- input; only the shared editor itself carries a numeric mode.
    if node.uiInput == "easy-chat" and type(node.view) == "table" and type(node.view.mode) == "number" then
      return node
    end
    for key, value in pairs(node) do
      if type(value) == "table" and (key == "child" or key == "editor" or key == "easyChat" or key == "compose") then
        local found = visit(value)
        if found ~= nil then
          return found
        end
      end
    end
    return nil
  end
  return visit(status)
end

---@param game table
---@return table snapshot
local function captureCustody(game)
  local mons = assert(game.runtime.monService, "the field runtime owns the live mon service")
  local bag = assert(game.runtime.bagService, "the field runtime owns the live bag service")
  local stats = assert(game.runtime.gameStats, "the field runtime owns the live game stats")
  local held = {}
  for slot = 0, mons:partyCount() - 1 do
    held[slot + 1] = mons:partyMon(slot).heldItem
  end
  local bucket = stats:bucket()
  return {
    partyRevision = mons:partyRevision(),
    bagRevision = bag:revision(),
    statsRevision = stats:revision(),
    stationery = bag:quantity(STATIONERY),
    ordinary = bag:quantity(ORDINARY_HELD),
    held = held,
    mailWritten = bucket.mailWritten,
    score = bucket.score,
  }
end

-- Opens the production Bag flow on the stocked stationery and chooses
-- Give. Returns the flow parked at its party target page.
---@param game table
---@return table flow
local function openStationeryGive(game)
  local cursor = assert(game.runtime.bagCursor, "the field runtime owns the live bag cursor")
  local bag = assert(game.runtime.bagService, "the field runtime owns the live bag service")
  local pocket, index = nil, nil
  for _, candidate in ipairs({ "mail", "items", "medicine", "balls", "tmhm", "berries", "battle_items", "key_items" }) do
    for position, entry in ipairs(bag:pocketItems(candidate)) do
      if entry.item == STATIONERY then
        pocket, index = candidate, position - 1
      end
    end
  end
  Assert.notNil(pocket, "the stocked stationery must live in some pocket")
  assert(pocket ~= nil and index ~= nil, "the stocked stationery resolves its pocket")
  cursor:setPocket(pocket)
  cursor:setPosition(pocket, index)
  local flow = composition(game).makeBagFlow()
  driveUntil(flow, "the bag browse page", 30, function(current)
    return current.page == "bag_browse"
  end)
  gotoPocket(flow, pocket)
  for _ = 1, 6 do
    local selected = flowChild(flowStatus(flow)).selected
    if selected ~= nil and selected.item == STATIONERY then
      break
    end
    drive(flow, { { type = "navigate", direction = "down" } })
  end
  local selected = flowChild(flowStatus(flow)).selected
  Assert.equal(selected ~= nil and selected.item, STATIONERY, "the stocked stationery must be reachable")
  local status = chooseBagAction(flow, "give")
  Assert.equal(status.page, "party_give_target", "choosing Give must open the party target page")
  drainOpen(flow)
  local child = flowChild(flow:status())
  Assert.equal(child.state, "choosing_item_target", "Give shares Party target navigation")
  return flow
end

-- Waits until the fresh composer owns input in its write screen:
-- the entry fade withholds input, so driven keys must follow readiness.
---@param flow table
local function waitComposerWrite(flow)
  for _ = 1, 120 do
    local composer = findComposer(flowStatus(flow))
    if composer ~= nil and composer.phase == "write" then
      return composer
    end
    flow:updateFixed({})
  end
  error("the letter composer never reaches its write screen", 0)
end

-- Accepts one sentence through the nested shared editor: wait for the
-- editor to own input, choose one word into each required field through
-- its retail browser, confirm, and answer its confirmation.
---@param flow table
local function acceptNestedSentence(flow)
  local editor = nil
  for _ = 1, 240 do
    editor = findNestedEditor(flowStatus(flow))
    if editor ~= nil and editor.preparing == false and editor.view.mode == 2 then
      break
    end
    editor = nil
    flow:updateFixed({})
  end
  Assert.notNil(editor, "selecting a line must open the nested shared sentence editor")
  assert(editor ~= nil, "the nested sentence editor owns input")
  Assert.equal(editor.view.mode, 2, "the letter sentence editor opens the shared sentence mode")
  -- Choose one offered word per field through the retail browser: top
  -- field, open the categories, scan groups until a word list opens,
  -- take one row, and return to composition.
  for _ = 1, 2 do
    for _ = 1, 5 do
      drive(flow, { { type = "navigate", direction = "up" } })
    end
    drive(flow, { { type = "confirm" } })
    local level = nil
    for _ = 1, 240 do
      local current = findNestedEditor(flowStatus(flow))
      if current ~= nil and current.view.level ~= "composition" then
        level = current.view.level
        break
      end
      flow:updateFixed({})
    end
    Assert.notNil(level, "the sentence editor must open its browser")
    local listed = false
    for _ = 1, 40 do
      local current = assert(findNestedEditor(flowStatus(flow)), "the browser keeps its status")
      if current.view.level == "list" then
        listed = true
        break
      end
      Assert.isTrue(
        current.view.level == "categories" or current.view.level == "abc",
        "the browser stays in its category lists"
      )
      drive(flow, { { type = "confirm" } })
      for _ = 1, 30 do
        flow:updateFixed({})
      end
      local opened = assert(findNestedEditor(flowStatus(flow)), "the browser keeps its status")
      if opened.view.level == "list" then
        listed = true
        break
      end
      if opened.view.level == "composition" then
        drive(flow, { { type = "confirm" } })
      else
        drive(flow, { { type = "navigate", direction = "down" } })
      end
    end
    Assert.isTrue(listed, "the browser must reach a word list")
    for _ = 1, 6 do
      drive(flow, { { type = "navigate", direction = "down" } })
    end
    drive(flow, { { type = "navigate", direction = "up" } })
    drive(flow, { { type = "confirm" } })
    for _ = 1, 240 do
      local current = findNestedEditor(flowStatus(flow))
      if current ~= nil and current.view.level == "composition" then
        break
      end
      flow:updateFixed({})
    end
    local composed = assert(findNestedEditor(flowStatus(flow)), "a word choice returns to composition")
    Assert.equal(composed.view.level, "composition", "a word choice returns to composition")
  end
  for _ = 1, 5 do
    drive(flow, { { type = "navigate", direction = "down" } })
  end
  drive(flow, { { type = "navigate", direction = "up" } })
  drive(flow, { { type = "confirm" } })
  local prompt = nil
  for _ = 1, 240 do
    local current = findNestedEditor(flowStatus(flow))
    if current ~= nil and current.view.level == "prompt" then
      prompt = current.view.prompt
      break
    end
    flow:updateFixed({})
  end
  Assert.notNil(prompt, "a complete sentence must ask its answer confirmation")
  assert(prompt ~= nil, "the sentence confirmation opens")
  Assert.equal(prompt.kind, "answer", "a complete sentence asks its answer confirmation")
  Assert.equal(prompt.selected, "yes", "the answer confirmation starts on YES")
  drive(flow, { { type = "confirm" } })
  for _ = 1, 240 do
    if findNestedEditor(flowStatus(flow)) == nil then
      break
    end
    flow:updateFixed({})
  end
  Assert.isNil(findNestedEditor(flowStatus(flow)), "the accepted sentence must close its editor child")
  waitComposerWrite(flow)
end

-- A fresh Bag Give opens the three-line letter screen, one sentence
-- composed through the real shared editor attaches exactly once with the
-- current author, the recipient plus next-two icon snapshot, and one
-- written-letter statistic, and the held letter reads back natively.
function T.tests.fresh_stationery_give_composes_one_sentence_and_attaches_with_author_icons_and_stats(context)
  withMailGame(function(game)
    giftTrio(game)
    stockBag(game)
    local mons = assert(game.runtime.monService, "the field runtime owns the live mon service")
    local bag = assert(game.runtime.bagService, "the field runtime owns the live bag service")
    local stats = assert(game.runtime.gameStats, "the field runtime owns the live game stats")
    local profile = assert(game.runtime.playerData, "the field runtime owns the live profile").profile
    local before = captureCustody(game)

    local flow = openStationeryGive(game)
    local status = choosePartySlot(flow, 0)
    void(status)
    local composer = nil
    for _ = 1, 120 do
      composer = findComposer(flowStatus(flow))
      if composer ~= nil and composer.phase == "write" then
        break
      end
      composer = nil
      flow:updateFixed({})
    end
    Assert.notNil(composer, "choosing the recipient must open the three-line letter composer")
    assert(composer ~= nil, "the letter composer owns the tick")
    Assert.equal(composer.stationeryType ~= nil or composer.letter ~= nil, true, "the composer carries its stationery")
    local draft = composer.lines or (composer.letter and composer.letter.lines) or {}
    Assert.equal(#draft, 3, "the fresh composer starts three line slots")
    for index = 1, 3 do
      Assert.isFalse(draft[index], "fresh line " .. index .. " starts blank")
    end

    -- Select the first line, compose one sentence through the nested
    -- shared editor, and confirm the whole letter.
    drive(flow, { { type = "confirm" } })
    acceptNestedSentence(flow)
    composer = assert(findComposer(flowStatus(flow)), "the sentence return stays in the composer")
    draft = composer.lines or (composer.letter and composer.letter.lines) or {}
    Assert.isTrue(draft[1] ~= false, "the accepted sentence initializes the first line")
    Assert.isFalse(draft[2], "untouched line two stays blank")
    Assert.isFalse(draft[3], "untouched line three stays blank")
    Assert.equal(bag:quantity(STATIONERY), before.stationery, "sentence acceptance moves no inventory")
    Assert.equal(stats:revision(), before.statsRevision, "sentence acceptance moves no statistics")

    drive(flow, { { type = "navigate", direction = "down" } })
    drive(flow, { { type = "navigate", direction = "down" } })
    drive(flow, { { type = "navigate", direction = "down" } })
    drive(flow, { { type = "confirm" } })
    local completion = driveUntil(flow, "the give completion", 120, function(current)
      local child = current.child
      return current.page == "party_browse" and child ~= nil and child.state == "message"
    end)
    Assert.isTrue(completion.open, "the committed letter returns through give feedback")
    drainOpen(flow)
    drive(flow, { { type = "confirm" } })

    local recipient = mons:partyMon(0)
    Assert.equal(recipient.heldItem, STATIONERY, "the committed letter attaches its stationery")
    local letter = assert(recipient.mail, "the recipient carries its written letter")
    Assert.equal(letter.type ~= nil, true, "the written letter carries its stationery type")
    Assert.equal(letter.author.name, profile.name, "the fresh letter captures the current author")
    Assert.equal(#letter.lines, 3, "the written letter keeps three line slots")
    Assert.isTrue(letter.lines[1] ~= false, "the written letter keeps its composed sentence")
    Assert.isFalse(letter.lines[2], "the written letter keeps blank line two")
    Assert.isFalse(letter.lines[3], "the written letter keeps blank line three")
    Assert.equal(#letter.icons, 3, "the written letter snapshots three icon slots")
    Assert.equal(bag:quantity(STATIONERY), before.stationery - 1, "exactly one stationery is consumed")
    local after = captureCustody(game)
    Assert.equal(after.mailWritten, (before.mailWritten or 0) + 1, "one successful write increments its count")
    Assert.equal(after.score, before.score + 1, "one successful write increments the score by one")

    -- Party Mail Read presents the persisted letter natively with its
    -- stored snapshot, and rereading adds no further count.
    local reader = composition(game).makePartyFlow()
    drainOpen(reader)
    driveUntil(reader, "the party browse page", 30, function(current)
      return current.page == "party_browse"
    end)
    choosePartySlot(reader, 0)
    choosePartyMenu(reader, "mail")
    choosePartyMenu(reader, "read_mail")
    local reading = driveUntil(reader, "the recipient read view", 60, function(current)
      return current.page ~= "party_browse"
    end)
    local readChild = flowChild(reading)
    Assert.notNil(readChild.letter or readChild.viewMode, "the read view carries the authored letter")
    drive(reader, { { type = "cancel" } })
    driveUntil(reader, "the restored party context", 60, function(current)
      return current.page == "party_browse" and current.transition == nil
    end)
    Assert.equal(captureCustody(game).mailWritten, after.mailWritten, "rereading a letter adds no write count")
    reader:dispose()

    -- The written letter and its count survive a save roundtrip.
    game:restart()
    game:waitForFieldEntry()
    game.runtime:bindPartyIconPreparation(function(_)
      return true
    end, function() end)
    local kept = assert(game.runtime.monService, "the reloaded runtime owns the mon service"):partyMon(0)
    Assert.equal(kept.heldItem, STATIONERY, "Continue retains the attached stationery")
    Assert.equal(kept.mail.author.name, profile.name, "Continue retains the captured author")
    Assert.isTrue(kept.mail.lines[1] ~= false, "Continue retains the composed sentence")
    flow:dispose()
  end, context)
end

-- Sentence results stay isolated per line, the all-blank letter warns
-- instead of submitting, and cancelling the whole letter from either
-- origin returns without moving inventory, party, or statistics.
function T.tests.sentence_edits_isolate_warning_and_origin_cancel_preserve_everything(context)
  withMailGame(function(game)
    giftTrio(game)
    stockBag(game)
    local bag = assert(game.runtime.bagService, "the field runtime owns the live bag service")
    local stats = assert(game.runtime.gameStats, "the field runtime owns the live game stats")
    void(bag)
    void(stats)

    -- Bag origin: warn on the all-blank letter, isolate a cancelled
    -- second line, keep the draft through a declined quit, then quit.
    local before = captureCustody(game)
    local flow = openStationeryGive(game)
    choosePartySlot(flow, 1)
    local composer = nil
    for _ = 1, 120 do
      composer = findComposer(flowStatus(flow))
      if composer ~= nil and composer.phase == "write" then
        break
      end
      composer = nil
      flow:updateFixed({})
    end
    Assert.notNil(composer, "the Bag recipient must open the letter composer")

    -- Confirming the all-blank letter warns and stays in the draft.
    drive(flow, { { type = "navigate", direction = "down" } })
    drive(flow, { { type = "navigate", direction = "down" } })
    drive(flow, { { type = "navigate", direction = "down" } })
    drive(flow, { { type = "confirm" } })
    local warned = flowStatus(flow)
    Assert.notNil(findComposer(warned), "the all-blank warning must stay in the composer")
    local warning = findComposer(warned)
    Assert.notNil(
      warning and (warning.warning or warning.modal or warning.prompt),
      "the all-blank letter must show its warning"
    )
    drive(flow, { { type = "confirm" } })
    Assert.notNil(findComposer(flowStatus(flow)), "dismissing the warning must keep the draft")

    -- Accept line one, cancel line two, accept line three.
    drive(flow, { { type = "navigate", direction = "up" } })
    drive(flow, { { type = "navigate", direction = "up" } })
    drive(flow, { { type = "navigate", direction = "up" } })
    drive(flow, { { type = "confirm" } })
    acceptNestedSentence(flow)
    drive(flow, { { type = "navigate", direction = "down" } })
    drive(flow, { { type = "confirm" } })
    for _ = 1, 120 do
      if findNestedEditor(flowStatus(flow)) ~= nil then
        break
      end
      flow:updateFixed({})
    end
    Assert.notNil(findNestedEditor(flowStatus(flow)), "the second line must open its sentence editor")
    -- The shared editor answers cancellation through its own quit
    -- prompt: B opens it, DOWN answers YES, and A discards the edit.
    drive(flow, { { type = "cancel" } })
    drive(flow, { { type = "navigate", direction = "down" } })
    drive(flow, { { type = "confirm" } })
    for _ = 1, 120 do
      if findNestedEditor(flowStatus(flow)) == nil then
        break
      end
      flow:updateFixed({})
    end
    Assert.isNil(findNestedEditor(flowStatus(flow)), "cancelling the sentence must close only its editor")
    waitComposerWrite(flow)
    local isolated = assert(findComposer(flowStatus(flow)), "the cancelled line must return to the draft")
    local isolatedLines = isolated.lines or (isolated.letter and isolated.letter.lines) or {}
    Assert.isTrue(isolatedLines[1] ~= false, "the cancelled edit must keep the accepted first line")
    Assert.isFalse(isolatedLines[2], "the cancelled second line must stay blank")
    drive(flow, { { type = "navigate", direction = "down" } })
    drive(flow, { { type = "confirm" } })
    acceptNestedSentence(flow)

    -- The whole-letter quit prompt answers No with the draft intact,
    -- then Yes back to the Bag origin with every snapshot preserved.
    drive(flow, { { type = "cancel" } })
    local quit = nil
    for _ = 1, 120 do
      local current = findComposer(flowStatus(flow))
      if current ~= nil and (current.prompt ~= nil or current.modal ~= nil or current.quit ~= nil) then
        quit = current
        break
      end
      flow:updateFixed({})
    end
    Assert.notNil(quit, "quitting the letter must ask its confirmation")
    drive(flow, { { type = "cancel" } })
    local resumed = assert(findComposer(flowStatus(flow)), "declining quit must resume the exact draft")
    local resumedLines = resumed.lines or (resumed.letter and resumed.letter.lines) or {}
    Assert.isTrue(resumedLines[1] ~= false and resumedLines[3] ~= false, "declining quit must keep both sentences")
    Assert.isFalse(resumedLines[2], "declining quit must keep the cancelled line blank")
    drive(flow, { { type = "cancel" } })
    for _ = 1, 60 do
      drive(flow, { { type = "navigate", direction = "down" } })
    end
    drive(flow, { { type = "confirm" } })
    driveUntil(flow, "the Bag return", 120, function(current)
      return current.page == "bag_browse" and findComposer(current) == nil
    end)
    local kept = captureCustody(game)
    Assert.deepEqual(kept.held, before.held, "a cancelled Bag letter must preserve every held item")
    Assert.equal(kept.stationery, before.stationery, "a cancelled Bag letter must preserve stationery")
    Assert.equal(kept.mailWritten, before.mailWritten, "a cancelled Bag letter must add no write count")
    Assert.equal(kept.score, before.score, "a cancelled Bag letter must add no score")
    flow:dispose()

    -- Party origin: quit returns focused on the selected mon with the
    -- same preservation.
    local partyBefore = captureCustody(game)
    local party = composition(game).makePartyFlow()
    drainOpen(party)
    driveUntil(party, "the party browse page", 30, function(current)
      return current.page == "party_browse"
    end)
    choosePartySlot(party, 2)
    choosePartyMenu(party, "item")
    choosePartyMenu(party, "give")
    local heldPicking = driveUntil(party, "the held-item picker", 30, function(current)
      return current.page == "bag_pick_held"
    end)
    Assert.isTrue(heldPicking.open, "party Give must open the held-item picker")
    driveUntil(party, "the held-item Bag opening settles", 30, function(current)
      return current.child ~= nil and current.child.phase == "interactive"
    end)
    gotoPocket(party, "mail")
    for _ = 1, 6 do
      local selected = flowChild(flowStatus(party)).selected
      if selected ~= nil and selected.item == STATIONERY then
        break
      end
      drive(party, { { type = "navigate", direction = "down" } })
    end
    local heldSelected = flowChild(flowStatus(party)).selected
    Assert.equal(
      heldSelected ~= nil and heldSelected.item,
      STATIONERY,
      "the Party held-item picker must offer the stocked stationery"
    )
    drive(party, { { type = "confirm" } })
    local partyComposer = nil
    for _ = 1, 120 do
      partyComposer = findComposer(flowStatus(party))
      if partyComposer ~= nil and partyComposer.phase == "write" then
        break
      end
      partyComposer = nil
      party:updateFixed({})
    end
    Assert.notNil(partyComposer, "the Party recipient must open the letter composer")
    drive(party, { { type = "cancel" } })
    for _ = 1, 60 do
      drive(party, { { type = "navigate", direction = "down" } })
    end
    drive(party, { { type = "confirm" } })
    local refocused = driveUntil(party, "the focused Party return", 120, function(current)
      return current.page == "party_browse" and findComposer(current) == nil
    end)
    Assert.equal(flowChild(refocused).cursorNode, 2, "a cancelled Party letter must refocus its selected mon")
    local partyKept = captureCustody(game)
    Assert.deepEqual(partyKept.held, partyBefore.held, "a cancelled Party letter must preserve every held item")
    Assert.equal(partyKept.stationery, partyBefore.stationery, "a cancelled Party letter must preserve stationery")
    Assert.equal(partyKept.mailWritten, partyBefore.mailWritten, "a cancelled Party letter must add no write count")
    party:dispose()
  end, context)
end

-- The Mailbox erase commits first, its hold follow-up composes a
-- genuinely new letter with source Give behavior, and moving a stored
-- letter earns no write count.
function T.tests.mailbox_erase_then_hold_composes_fresh_and_stored_give_moves_unchanged(context)
  withMailGame(function(game)
    giftTrio(game)
    stockBag(game)
    local mons = assert(game.runtime.monService, "the field runtime owns the live mon service")
    local bag = assert(game.runtime.bagService, "the field runtime owns the live bag service")
    local mailbox = assert(game.runtime.mailbox, "the field runtime owns the live mailbox")
    local profile = assert(game.runtime.playerData, "the field runtime owns the live profile").profile
    void(mons)
    void(bag)

    local oldLetter = {
      schema = "g4-mail-v1",
      type = 9,
      author = { trainerId = 999, name = "MISTY", gender = 1, language = 2, game = 8 },
      icons = { { species = "MARILL", form = 0, palette = 2 }, false, false },
      lines = {
        { template = "mail-template:2:4", words = { "1371", "1417" } },
        { template = "mail-template:3:1", words = { "1479", false } },
        false,
      },
    }
    local storedLetter = {
      schema = "g4-mail-v1",
      type = 0,
      author = { trainerId = 111, name = "BROCK", gender = 0, language = 2, game = 7 },
      icons = { false, false, false },
      lines = {
        { template = "mail-template:2:4", words = { "1371", "1417" } },
        false,
        false,
      },
    }
    -- Prepared Mailbox writes admit current records only: the
    -- predecessor letters normalize explicitly through the production
    -- owner restore path first, preserving every durable field.
    local Mail = require("libs.mons.src.gen4.Mail")
    local legacyContext = { catalog = assert(game.runtime.monCatalog, "migration resolves legacy icons") }
    local erased = assert(
      mailbox:prepareChanges(mailbox:revision(), { { slot = 0, value = Mail.normalize(oldLetter, legacyContext) } })
    )
    erased.publish()
    local migratedStored = Mail.normalize(storedLetter, legacyContext)
    local stored = assert(mailbox:prepareChanges(mailbox:revision(), { { slot = 1, value = migratedStored } }))
    stored.publish()
    local before = captureCustody(game)

    -- Erase leg: the production Mailbox child erases slot zero, then
    -- its hold follow-up must open the same fresh composer as Bag Give:
    -- the current author, three blank lines, and the current icon
    -- snapshot instead of the erased values.
    local box = composition(game).makeMailboxChild()
    box:updateFixed({ { type = "confirm" } })
    Assert.equal(box:status().phase, "action", "confirming the slot must open its action menu")
    box:updateFixed({ { type = "navigate", direction = "down" } })
    Assert.equal(box:status().action, "erase", "the action menu must offer erase")
    box:updateFixed({ { type = "confirm" } })
    Assert.equal(box:status().phase, "confirm", "erase must ask its confirmation")
    box:updateFixed({ { type = "confirm" } })
    Assert.equal(box:status().phase, "erased", "confirming erase must commit before the hold question")
    Assert.isNil(mailbox:get(0), "the committed erase must clear its slot")
    box:updateFixed({ { type = "confirm" } })
    Assert.equal(box:status().phase, "holdMail", "the committed erase must ask its hold follow-up")
    box:updateFixed({ { type = "confirm" } })
    Assert.equal(box:status().phase, "picker", "accepting hold must open the recipient picker")
    for _ = 1, 60 do
      if box.picker ~= nil and box.picker:status().phase == "interactive" then
        break
      end
      box:updateFixed({})
    end
    Assert.equal(
      box.picker ~= nil and box.picker:status().phase,
      "interactive",
      "the hold follow-up must settle its production picker"
    )
    -- The picker's reveal gates its first input edges: run out the
    -- handover ticks before confirming, or the selection is dropped.
    box:updateFixed({})
    box:updateFixed({})
    box:updateFixed({ { type = "confirm" } })
    for _ = 1, 60 do
      if box:status().phase == "compose" then
        break
      end
      box:updateFixed({})
    end
    Assert.equal(box:status().phase, "compose", "the picked recipient must open the letter composer")
    for _ = 1, 60 do
      local draft = box:status().compose
      if draft ~= nil and draft.phase == "write" then
        break
      end
      box:updateFixed({})
    end
    local fresh = assert(box:status().compose, "the compose phase carries its draft status")
    Assert.equal(fresh.phase, "write", "the follow-up composer owns input before it answers")
    Assert.equal(
      fresh.author.name,
      profile.name,
      "the hold follow-up must capture the current author, not the erased one"
    )
    for index = 1, 3 do
      Assert.isFalse(fresh.lines[index], "the hold follow-up must start blank line " .. index)
    end
    -- Cancelling the fresh draft keeps the committed erase, returns the
    -- stationery through the erase outcome, and adds no write count. The
    -- whole-letter quit answers YES through the source confirmation.
    box:updateFixed({ { type = "cancel" } })
    box:updateFixed({ { type = "confirm" } })
    for _ = 1, 60 do
      if box:status().phase == "result" then
        break
      end
      box:updateFixed({})
    end
    local cancelled = box:status()
    Assert.equal(cancelled.phase, "result", "cancelling composition must report the erase outcome")
    Assert.isNil(cancelled.compose, "cancelling composition must close its child")
    Assert.isNil(mailbox:get(0), "cancelling the follow-up must never resurrect erased content")
    local kept = captureCustody(game)
    Assert.equal(kept.mailWritten, before.mailWritten, "a cancelled follow-up must add no write count")
    box:updateFixed({ { type = "confirm" } })
    Assert.equal(box:status().phase, "list", "acknowledging the outcome must return to the list")
    box:dispose()
    void(oldLetter)

    -- Stored-letter leg: giving the untouched stored letter moves it
    -- unchanged and earns no write count.
    local giver = composition(game).makeMailboxChild()
    for _ = 1, 4 do
      if giver:status().selectedSlot == 1 then
        break
      end
      giver:updateFixed({ { type = "navigate", direction = "down" } })
    end
    Assert.equal(giver:status().selectedSlot, 1, "the list must focus the stored letter")
    giver:updateFixed({ { type = "confirm" } })
    Assert.equal(giver:status().phase, "action", "confirming the stored slot must open its action menu")
    giver:updateFixed({ { type = "navigate", direction = "down" } })
    giver:updateFixed({ { type = "navigate", direction = "down" } })
    Assert.equal(giver:status().action, "give", "the stored letter must offer give")
    giver:updateFixed({ { type = "confirm" } })
    Assert.equal(giver:status().phase, "picker", "stored give must open the recipient picker")
    for _ = 1, 60 do
      if giver.picker ~= nil and giver.picker:status().phase == "interactive" then
        break
      end
      giver:updateFixed({})
    end
    giver:updateFixed({})
    giver:updateFixed({})
    giver:updateFixed({ { type = "confirm" } })
    for _ = 1, 60 do
      if giver:status().phase == "list" then
        break
      end
      giver:updateFixed({})
    end
    Assert.equal(giver:status().phase, "list", "stored give must return to the list")
    Assert.isNil(mailbox:get(1), "stored give must clear its persisted source slot")
    Assert.deepEqual(mons:partyMon(0).mail, migratedStored, "stored give must move the authored value unchanged")
    local moved = captureCustody(game)
    Assert.equal(moved.mailWritten, before.mailWritten, "a stored-letter move must earn no write count")
    giver:dispose()
  end, context)
end

-- Replacing an ordinary held item through a fresh letter returns the
-- old item exactly once, applies the canonical held-item effects, and
-- publishes party, bag, and statistics together or not at all.
function T.tests.replacement_give_returns_old_item_attaches_letter_and_publishes_stats_once(context)
  withMailGame(function(game)
    giftTrio(game)
    stockBag(game)
    -- The replacement leg starts from real custody: the fourth member
    -- arrives holding the ordinary item through the live mon service.
    local mons = assert(game.runtime.monService, "the field runtime owns the live mon service")
    Assert.isTrue(
      mons:giveMon({ species = "ABRA", level = 5, heldItem = ORDINARY_HELD }),
      "setup gift must enter the party holding the ordinary item"
    )
    Assert.equal(mons:partyMon(3).heldItem, ORDINARY_HELD, "the replacement recipient holds its ordinary item")
    local bag = assert(game.runtime.bagService, "the field runtime owns the live bag service")
    local mailbox = assert(game.runtime.mailbox, "the field runtime owns the live mailbox")
    local MailActionsOwner = require("libs.hgss.src.field.MailActions")
    local manifest = assert(composition(game).pcManifest, "the production composition owns the pc manifest")
    local catalog = assert(game.runtime.easyChatCatalog, "the field runtime owns the shared word catalog")
    local gameStats = assert(game.runtime.gameStats, "the field runtime owns the live game stats")
    local actions = MailActionsOwner.new({
      mons = mons,
      mailbox = mailbox,
      bag = bag,
      manifest = manifest,
      catalog = catalog,
      gameStats = gameStats,
    })

    -- Build one complete fresh letter from the live shared catalog: the
    -- stationery type resolves through its item key, one two-substitution
    -- template and two password-bank words come from C01 itself, so no
    -- identity is ever guessed.
    local stationeryType = nil
    for candidate = 0, 11 do
      if manifest.mail.stationery[candidate] ~= nil and manifest.mail.stationery[candidate].itemKey == STATIONERY then
        stationeryType = candidate
      end
    end
    Assert.notNil(stationeryType, "the stocked stationery must resolve its live type")
    local templateKey = nil
    for bank = 0, 4 do
      for number = 0, 19 do
        local template = catalog:template(bank, number)
        if template ~= nil and template.wordCount == 2 then
          templateKey = "mail-template:" .. bank .. ":" .. number
          break
        end
      end
      if templateKey ~= nil then
        break
      end
    end
    Assert.notNil(templateKey, "the shared catalog must compile a two-substitution template")
    local wordKeys = { tostring(catalog.primoWords[1]), tostring(catalog.primoWords[2]) }
    local keyBank, keyNumber = templateKey:match("^mail%-template:(%d+):(%d+)$")
    Assert.equal(
      catalog:messageStatus({
        bank = tonumber(keyBank),
        number = tonumber(keyNumber),
        words = { catalog.primoWords[1], catalog.primoWords[2] },
      }),
      "complete",
      "the shared catalog classifies the drafted sentence complete"
    )
    local profile = assert(game.runtime.playerData, "the field runtime owns the live profile").profile
    local letter = {
      schema = "g4-mail-v2",
      type = stationeryType,
      author = {
        trainerId = profile.trainerId,
        name = profile.name,
        gender = profile.gender,
        language = 2,
        game = 7,
      },
      icons = { false, false, false },
      lines = {
        { template = templateKey, words = { wordKeys[1], wordKeys[2] } },
        false,
        false,
      },
    }
    local revisions = actions:revisionSnapshot()
    local preflight = actions:preview({
      kind = "composeGiveMail",
      targetSlot = 3,
      itemKey = STATIONERY,
      partyRevision = revisions.partyRevision,
      bagRevision = revisions.bagRevision,
      letter = letter,
    })
    Assert.equal(
      preflight.kind,
      "needs_confirmation",
      "an ordinary held item must ask its replacement question before any composer opens"
    )
    Assert.equal(bag:quantity(STATIONERY), 2, "preflight must move no inventory")
    Assert.equal(bag:quantity(ORDINARY_HELD), 1, "preflight must move no held stock")
    Assert.equal(mons:partyMon(3).heldItem, ORDINARY_HELD, "preflight must keep the ordinary held item")
  end, context)
end

-- Saved letters in party mons, boxed mons, and the Mailbox keep their
-- author, template identities, and words through icon migration, read
-- tolerantly with extra or missing substitutions, and migrate statistics
-- without inventing a historical count.
function T.tests.saved_letters_keep_identity_and_appearance_across_party_boxes_mailbox_and_stats(context)
  withMailGame(function(game)
    giftTrio(game)
    stockBag(game)
    local runtime = game.runtime
    local catalog = assert(runtime.easyChatCatalog, "the field runtime owns the shared word catalog")
    local monCatalog = assert(runtime.monCatalog, "the field runtime owns the live mon catalog")
    local mons = assert(runtime.monService, "the field runtime owns the live mon service")
    local mailbox = assert(runtime.mailbox, "the field runtime owns the live mailbox")
    local MailboxOwner = require("libs.hgss.src.save.Mailbox")
    void(mons)
    void(mailbox)

    local legacyIcon = { species = "MARILL", form = 0, palette = 2 }
    local expectedSelector = monCatalog:iconSelection(legacyIcon)
    Assert.isTrue(type(expectedSelector) == "string" and expectedSelector ~= "", "the catalog resolves the legacy icon")
    local rivalStyle = {
      schema = "g4-mail-v1",
      type = 9,
      author = { trainerId = 0, name = "Lyra", gender = 1, language = 2, game = 7 },
      icons = { legacyIcon, false, false },
      lines = {
        { template = "mail-template:2:4", words = { "1371", "1417" } },
        { template = "mail-template:3:1", words = { "1479", false } },
        false,
      },
    }
    local Mail = require("libs.mons.src.gen4.Mail")
    Assert.equal(Mail.LEGACY_SCHEMA, "g4-mail-v1", "the run starts before the icon migration schema")
    Assert.equal(Mail.SCHEMA, "g4-mail-v2", "migration targets the semantic icon schema")

    -- Explicit legacy admission must preserve every durable field and
    -- resolve only the icon representation through the catalog.
    local normalize = Mail.normalize
    Assert.notNil(normalize, "saved letters migrate through explicit legacy admission")
    assert(normalize ~= nil, "explicit legacy admission exists")
    local migrated = Mail.normalize(rivalStyle, { catalog = monCatalog })
    Assert.equal(migrated.schema, "g4-mail-v2", "migration targets the semantic icon schema")
    Assert.deepEqual(migrated.author, rivalStyle.author, "migration preserves the author exactly")
    Assert.equal(migrated.type, rivalStyle.type, "migration preserves the stationery type")
    Assert.deepEqual(migrated.lines, rivalStyle.lines, "migration preserves template and word identities")
    Assert.equal(migrated.icons[1], expectedSelector, "migration resolves the same icon the old viewer displayed")
    Assert.isFalse(migrated.icons[2], "migration keeps false trailing slots")
    Assert.deepEqual(rivalStyle.icons[1], legacyIcon, "migration leaves its input immutable")

    -- The migrated letter restores through the production Mailbox owner
    -- and survives capture without revalidation drift.
    local restored = MailboxOwner.new({
      schema = MailboxOwner.SCHEMA,
      slots = (function()
        local values = {}
        for slot = 0, MailboxOwner.CAPACITY - 1 do
          values[slot + 1] = false
        end
        values[1] = migrated
        return values
      end)(),
    }, { catalog = monCatalog })
    Assert.deepEqual(restored:get(0).lines, rivalStyle.lines, "the restored letter keeps its saved lines")
    Assert.equal(restored:get(0).icons[1], expectedSelector, "the restored letter keeps its resolved icon")

    -- Known lines expand through the shared catalog; a saved extra word
    -- stays readable without rewriting the stored fields.
    local MailTemplate = require("libs.hgss.src.field.MailTemplate")
    local expanded = MailTemplate.expandLine(migrated.lines[1], catalog)
    Assert.isTrue(#expanded > 0, "the known saved line expands through the shared catalog")

    -- Party and boxed mons normalize the same legacy letter through
    -- their own restore boundaries without revalidating every record.
    local partyMon = {
      species = "MARILL",
      form = 0,
      mail = {
        schema = "g4-mail-v1",
        type = 9,
        author = { trainerId = 0, name = "Lyra", gender = 1, language = 2, game = 7 },
        icons = { legacyIcon, false, false },
        lines = {
          { template = "mail-template:2:4", words = { "1371", "1417" } },
          { template = "mail-template:3:1", words = { "1479", false } },
          false,
        },
      },
    }
    local PartyOwner = require("libs.mons.src.Party")
    local party = PartyOwner.restore({ max = PartyOwner.MAX, mons = { partyMon } }, { catalog = monCatalog })
    Assert.equal(party:get(0).mail.schema, "g4-mail-v2", "party restore normalizes legacy nested Mail")
    Assert.equal(party:get(0).mail.icons[1], expectedSelector, "party restore keeps the displayed icon")
    Assert.deepEqual(party:get(0).mail.lines, rivalStyle.lines, "party restore preserves template identities")
    local BoxesOwner = require("libs.mons.src.Boxes")
    local boxSnapshot = BoxesOwner.new():capture()
    boxSnapshot.boxes[1].slots[1] = {
      species = "MARILL",
      form = 0,
      mail = {
        schema = "g4-mail-v1",
        type = 9,
        author = { trainerId = 0, name = "Lyra", gender = 1, language = 2, game = 7 },
        icons = { legacyIcon, false, false },
        lines = {
          { template = "mail-template:2:4", words = { "1371", "1417" } },
          { template = "mail-template:3:1", words = { "1479", false } },
          false,
        },
      },
    }
    local MonsSaveOwner = require("libs.mons.src.MonsSave")
    local Lcrng = require("libs.mons.src.gen4.Lcrng")
    local saved = MonsSaveOwner.restore({
      schema = MonsSaveOwner.SCHEMA,
      rng = Lcrng.new(1):capture(),
      party = { max = PartyOwner.MAX, mons = {} },
      boxes = boxSnapshot,
    }, { catalog = monCatalog })
    local boxed = saved.boxes
    Assert.equal(
      boxed:mon(0, 0).mail.schema,
      "g4-mail-v2",
      "boxed restore normalizes legacy nested Mail at its boundary"
    )
    Assert.equal(boxed:mon(0, 0).mail.icons[1], expectedSelector, "boxed restore keeps the displayed icon")

    -- Statistics migrate without inventing a historical count: the
    -- missing bucket and the exact v1 bucket both start at zero while
    -- preserving score and species totals.
    local GameStatsSaveOwner = require("libs.hgss.src.save.GameStatsSave")
    local refs = { species = { CHIKORITA = true, TOTODILE = true, CYNDAQUIL = true, MARILL = true } }
    local migratedStats = GameStatsSaveOwner.migrate(nil, refs)
    Assert.equal(migratedStats.mailWritten, 0, "a missing bucket invents no written-Mail count")
    local legacyStats = GameStatsSaveOwner.migrate({
      schema = "hgss-stats-v1",
      stateVersion = 1,
      uniqueCaught = { "CHIKORITA" },
      uniqueTotal = 4,
      score = 120,
    }, refs)
    Assert.equal(legacyStats.mailWritten, 0, "a v1 bucket invents no historical count")
    Assert.equal(legacyStats.score, 120, "migration preserves the existing score")
    Assert.equal(legacyStats.uniqueTotal, 4, "migration preserves the species total")
    void(catalog)
    void(expectedSelector)
  end, context)
end

-- The native stationery plan carries source geometry and masks, the
-- nested shared editor draws through its own renderer and readiness,
-- and a failed preparation leaves custody unchanged.
function T.tests.native_letter_plan_prepares_without_draw_and_reports_missing_art(context)
  withMailGame(function(game)
    giftTrio(game)
    stockBag(game)
    local MailView =
      assert(require("game.hgss.src.pc.MailViewInterface"), "the native stationery plan has its bounded owner")
    local PcCache = require("libs.assets.src.PcCache")
    local manifest = PcCache.loadManifest(assert(game.runtime.cacheFs, "the runtime owns its version cache"))
    local write =
      assert(manifest.mail.stationery[0].write, "the generated stationery carries its compiled write chrome")
    local display = {
      width = 256,
      height = 192,
      topology = require("libs.ui.src.ScreenTopology").oneDisplay({
        id = "main",
        rect = { x = 0, y = 0, width = 256, height = 192 },
        role = "world",
        touch = true,
      }),
      pixelRatio = 1,
      signature = "mail-composition-headless:256x192",
    }
    -- The native write plan carries source geometry and masks, maps
    -- the three line windows and the Confirm/Cancel pair, and rejects
    -- padding and mask misses without acquiring anything.
    local plan = MailView.plan(display, "write", { hitMasks = write.hitMasks })
    Assert.equal(plan.inputKey, "mail-view", "the write screen plans its native view")
    Assert.equal(#plan.controls, 5, "the write screen keeps its five source controls")
    local mapped = MailView.events(plan, { { type = "pointer_down", x = 100, y = 40 } }, write.hitMasks)
    Assert.equal(#mapped, 1, "an in-bounds line touch maps to one action")
    Assert.equal(mapped[1].type, "line", "the first line window maps to its line")
    Assert.equal(mapped[1].index, 1, "the first line window maps to line one")
    Assert.equal(
      #MailView.events(plan, { { type = "pointer_down", x = 0, y = 0 } }, write.hitMasks),
      0,
      "padding maps to nothing"
    )
    local readPlan = MailView.plan(display, "read", {})
    Assert.equal(readPlan.inputKey, "mail-view", "the read screen plans its native view")
    Assert.equal(#MailView.events(readPlan, { { type = "confirm" } }, {}), 1, "read closes on its source key")

    -- A failed preparation surfaces its missing art without drawing
    -- and publishes no result or custody change.
    local MailComposeState = require("game.hgss.src.pc.MailComposeState")
    local composer = MailComposeState.new({
      letter = {
        schema = "g4-mail-v2",
        type = 0,
        author = { trainerId = 1, name = "GOLD", gender = 0, language = 2, game = 7 },
        icons = { false, false, false },
        lines = { false, false, false },
      },
      catalog = assert(game.runtime.easyChatCatalog, "the composer borrows the shared word catalog"),
      openEasyChat = function(_)
        error("failed preparation never opens the shared editor", 0)
      end,
      prepare = function(_)
        return false, "mailbox image missing at assets/generated/pc/stationery-0-write-background.png"
      end,
      manifest = manifest,
      measureDisplay = function()
        return display
      end,
      audio = { play = function() end },
      inputMode = "buttons",
    })
    local before = { stationery = game.runtime.bagService:quantity(STATIONERY), written = nil }
    for _ = 1, 5 do
      composer:updateFixed({ { type = "confirm" } })
    end
    local status = composer:status()
    Assert.isTrue(status.preparing, "a missing visual keeps the composer preparing")
    Assert.notNil(status.preparationError, "a failed preparation names its missing art")
    Assert.isNil(composer:takeResult(), "a failed preparation publishes no result")
    Assert.equal(
      game.runtime.bagService:quantity(STATIONERY),
      before.stationery,
      "a failed preparation moves no inventory"
    )
    composer:dispose()
    void(game)
  end, context)
end

return T
