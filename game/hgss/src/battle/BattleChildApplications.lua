-- Private battle child composition module. Builds the concrete child
-- applications behind the battle-local selection barrier with battle-local
-- data and command adapters, delegating to the real application mechanisms:
-- the retail battle-bag browser (pocket menu, item list, use-item pages)
-- over detached stock, the native Party
-- application in its pick and item-target contexts, the native
-- summary/move-selection presentation in move-pick mode, the existing
-- naming screen controller, and the native evolution presentation state.
-- This module never activates the field application host, never exposes the
-- paused field, and never reuses a field adapter that writes live
-- inventory or party state while a decision is still pending: every service
-- behind a composed child reads a detached battle snapshot, stages reply
-- fragments at most, and refuses live mutation loudly.
--
-- A composed child owns its mutable controller state and any acquired lease;
-- borrowed catalogs stay borrowed. Results report once through takeResult as
-- { identity, kind, choice } where identity binds the opening barrier, kind
-- is accepted/cancelled/failed, and choice is the exact authoritative
-- option/operation payload. An accepted UI row never seals on its own: the
-- barrier still binds kernel fragments, and native controller intents are
-- drained as evidence, never as acceptance.

local BattleBagPockets = require("game.hgss.src.battle.BattleBagPockets")
local BattleFinger = require("game.hgss.src.battle.BattleFinger")
local BattlePartyPages = require("game.hgss.src.battle.BattlePartyPages")
local MonCache = require("libs.assets.src.MonCache")
local NamingScreenController = require("libs.hgss.src.ui.NamingScreenController")
local PartyScreenController = require("libs.hgss.src.ui.PartyScreenController")
local PartyScreenLayout = require("libs.hgss.src.ui.PartyScreenLayout")
local SummaryController = require("libs.hgss.src.ui.SummaryController")
local SummaryScreenState = require("game.hgss.src.field.SummaryScreenState")

local BattleChildApplications = {}

-- Every tutorial page re-arms the lesson finger
-- (battle_bag_menu.c BattleBagMenu_UpdateTutorialFinger). The control each tutorial page's finger touches (RunTutorial): the
-- balls pocket, its first cell, then USE.
local TUTORIAL_FINGER_TARGETS = { pocket_menu = "bagpocket:2", item_list = "bag:0", use_item = "use" }

-- Canonical battle child hit geometry: the six list rows and the footer
-- Back share one coordinate space with the rows the battle renderer
-- paints and the battle session hit-tests for party, move, and learn
-- children, so a tap and its paint resolve through the same regions.
-- Row identities stay stable (party:N, move:N, learn:N, learn:decline);
-- geometry depends only on the row index, never on row content. Bag taps
-- ride the transcribed retail hitboxes through BattleBagPockets instead.
local CHILD_ROW = { x = 8, y = 32, width = 240, height = 20 }
local CHILD_BACK = { x = 8, y = 152, width = 80, height = 40 }
local CHILD_LEARN_BACK = { x = 8, y = 172, width = 240, height = 20 }

---@param rect table<string, number> canonical hit rectangle under testing
---@param x number tap horizontal position under testing
---@param y number tap vertical position under testing
---@return boolean inside true while the tap lands in the rectangle
local function hitContains(rect, x, y)
  return type(x) == "number"
    and type(y) == "number"
    and x >= rect.x
    and x < rect.x + rect.width
    and y >= rect.y
    and y < rect.y + rect.height
end

---@param index integer one-based row position under mapping
---@return table<string, number> canonical row rectangle
local function rowRect(index)
  return {
    x = CHILD_ROW.x,
    y = CHILD_ROW.y + (index - 1) * CHILD_ROW.height,
    width = CHILD_ROW.width,
    height = CHILD_ROW.height,
  }
end

---@param rect table<string, number> canonical hit rectangle under mapping
---@return table<string, number> rectangle center
local function rectCenter(rect)
  return { x = rect.x + rect.width / 2, y = rect.y + rect.height / 2 }
end

-- Resolves one native learning hit target over the canonical modal rows:
-- held rows select by move index while the fifth row and the footer
-- both decline through the shared cancel path.
---@param x number tap horizontal position under hit-testing
---@param y number tap vertical position under hit-testing
---@return table<string, unknown>? native hit target, nil outside every control
local function battleLearnHit(x, y)
  for index = 0, 3 do
    if hitContains(rowRect(index + 1), x, y) then
      return { kind = "move", index = index }
    end
  end
  if hitContains(rowRect(5), x, y) then
    return { kind = "return" }
  end
  if hitContains(CHILD_LEARN_BACK, x, y) then
    return { kind = "return" }
  end
  return nil
end

-- Resolves one native Restore PP hit target over the canonical modal
-- rows: held rows select by move index, the footer returns.
---@param x number tap horizontal position under hit-testing
---@param y number tap vertical position under hit-testing
---@return table<string, unknown>? native hit target, nil outside every control
local function battleMoveHit(x, y)
  for index = 0, 3 do
    if hitContains(rowRect(index + 1), x, y) then
      return { kind = "move", index = index }
    end
  end
  if hitContains(CHILD_BACK, x, y) then
    return { kind = "return" }
  end
  return nil
end

-- Maps one stable battle row/control identity to its canonical tap
-- center for pointer synthesis. Unknown identities map to nothing so a
-- foreign tap can never arm controller state.
---@param kind string composed child kind under mapping
---@param id string stable row/control identity under mapping
---@param layout table<string, unknown>? native resolved hit geometry
---@param _menus table<string, unknown>? borrowed menu renderers and manifests (reserved for native layouts)
---@return table<string, number>? tap center, nil for unknown identities
local function battleTapPoint(kind, id, layout, _menus)
  local _ = _menus
  if kind == "party" or kind == "target" then
    -- Party taps resolve through the native generated hit geometry
    -- alone: without it the tap names nothing instead of inventing a
    -- modal row that production never paints.
    if type(layout) ~= "table" then
      return nil
    end
    local slot = tonumber(id:match("^party:(%d+)$") or "")
    if slot ~= nil and slot % 1 == 0 and slot >= 0 and slot <= 5 then
      return rectCenter(assert(layout.slotRects[slot + 1], "native party layout carries every slot"))
    end
    if id == "back" then
      if layout.cancelRect ~= nil then
        return rectCenter(layout.cancelRect)
      end
      return nil
    end
    return nil
  end
  if kind == "bag" then
    -- Retail bag taps ride the transcribed touchscreen hitboxes
    -- (battle_bag_menu.c CheckTouchHitbox): each stable control
    -- identity centers on its hit region so pointer synthesis and
    -- paint resolve through the same decomp geometry. Unknown pages
    -- fall back to the item list order like hitRegions.
    local page = "item_list"
    if id == "use" or id == "back" then
      page = "use_item"
    elseif id:match("^bagpocket:") ~= nil or id == "last_used" then
      page = "pocket_menu"
    end
    for _, region in ipairs(BattleBagPockets.hitRegions(page)) do
      if region.id == id then
        return { x = region.x + region.w / 2, y = region.y + region.h / 2 }
      end
    end
    -- The use-item info row (bag:0) carries no hitbox (retail prints
    -- it through windows, not buttons): synthesize its tap at the USE
    -- button so a foreign info tap can never arm controller state.
    if id == "bag:0" then
      for _, region in ipairs(BattleBagPockets.hitRegions("use_item")) do
        if region.id == "use" then
          return { x = region.x + region.w / 2, y = region.y + region.h / 2 }
        end
      end
    end
    return nil
  end
  if kind == "move" then
    local slot = tonumber(id:match("^move:(%d+)$") or "")
    if slot ~= nil and slot % 1 == 0 and slot >= 0 and slot <= 3 then
      return rectCenter(rowRect(math.floor(slot) + 1))
    end
    if id == "back" then
      return rectCenter(CHILD_BACK)
    end
    return nil
  end
  if kind == "learn" then
    local slot = tonumber(id:match("^learn:(%d+)$") or "")
    if slot ~= nil and slot % 1 == 0 and slot >= 0 and slot <= 3 then
      return rectCenter(rowRect(math.floor(slot) + 1))
    end
    if id == "learn:decline" then
      return rectCenter(rowRect(5))
    end
    if id == "back" then
      return rectCenter(CHILD_LEARN_BACK)
    end
    return nil
  end
  return nil
end

-- Expands barrier taps into synthetic matched pointer pairs at their
-- canonical centers so keyboard and pointer travel the same native
-- controller actions. Unknown identities drop without arming anything.
---@param kind string composed child kind under expansion
---@param events table<integer, table<string, unknown>> semantic input batch under expansion
---@param layout table<string, unknown>? native resolved hit geometry
---@param menus table<string, unknown>? borrowed menu renderers and manifests
---@return table<integer, table<string, unknown>> batch with taps expanded to pointer pairs
local function expandTaps(kind, events, layout, menus)
  local expanded = {}
  local taps = 0
  for _, event in ipairs(events) do
    if type(event) == "table" and event.type == "tap" and type(event.id) == "string" then
      local point = battleTapPoint(kind, event.id, layout, menus)
      if point ~= nil then
        taps = taps + 1
        local pointerId = "battle-tap:" .. tostring(taps)
        expanded[#expanded + 1] = { type = "pointer_down", pointerId = pointerId, x = point.x, y = point.y }
        expanded[#expanded + 1] = { type = "pointer_up", pointerId = pointerId, x = point.x, y = point.y }
      end
    else
      expanded[#expanded + 1] = event
    end
  end
  return expanded
end

BattleChildApplications.KINDS = { party = true, bag = true, learn = true, naming = true, evolution = true }

-- Retail mon-menu tap identities behind their native menu entries:
-- the wrapper page paints the full-screen buttons while the native
-- controller keeps its dropdown geometry, so taps translate through
-- the generated menu touch targets.
local MONMENU_TAP_KINDS = { switch = "switch", summary = "summary", moves = "check_moves", back = "quit" }

-- Translates mon-menu page taps into the native controller pointer
-- pairs (battle_party_menu.c GetMonMenuInput touch-first order): over
-- the open mon menu, each wrapper identity drives the staged dropdown
-- entry it names; eggs carry no SUMMARY/CHECK MOVES entries, so those
-- taps drop silently like the retail egg break. Over the refusal
-- message, any tap acknowledges at the tapped region center. Every
-- other event travels untouched.
---@param child table<string, unknown> composed party child under routing
---@param events table<integer, table<string, unknown>> semantic input batch under routing
---@return table<integer, table<string, unknown>> batch with mon-menu taps translated
local function monMenuTaps(child, events)
  local status = child._controller:status()
  if type(status) ~= "table" or (status.state ~= "context" and status.state ~= "message") then
    return events
  end
  local menu = type(status.menu) == "table" and status.menu or {}
  local translated = {}
  local taps = 0
  for _, event in ipairs(events) do
    local id = type(event) == "table" and event.type == "tap" and type(event.id) == "string" and event.id or nil
    local kind = id ~= nil and MONMENU_TAP_KINDS[id] or nil
    if kind == nil then
      translated[#translated + 1] = event
    elseif status.state == "message" then
      -- The refusal message acknowledges any tap: reuse the tapped
      -- region center in native coordinates.
      local ids = BattlePartyPages.inputIds("mon_menu")
      local boxes = BattlePartyPages.hitboxes("mon_menu", child._partySection)
      local point = nil
      for pos, known in ipairs(ids) do
        if known == id and type(boxes[pos]) == "table" then
          local box = boxes[pos]
          point = { x = box.left + (box.right - box.left) / 2, y = box.top + (box.bottom - box.top) / 2 }
        end
      end
      if point == nil then
        local cancel = BattlePartyPages.CANCEL_RECT
        point =
          { x = cancel.left + (cancel.right - cancel.left) / 2, y = cancel.top + (cancel.bottom - cancel.top) / 2 }
      end
      taps = taps + 1
      local pointerId = "battle-menu-tap:" .. tostring(taps)
      translated[#translated + 1] = { type = "pointer_down", pointerId = pointerId, x = point.x, y = point.y }
      translated[#translated + 1] = { type = "pointer_up", pointerId = pointerId, x = point.x, y = point.y }
    else
      local index = nil
      for candidate, entry in ipairs(menu) do
        if type(entry) == "table" and entry.kind == kind then
          index = candidate
        end
      end
      if index == nil then
        -- No such entry (eggs hide SUMMARY/CHECK MOVES): silent.
      else
        local layout = child._layout
        local menuLayout = type(layout) == "table" and layout.menuLayout or nil
        local records = type(menuLayout) == "function" and menuLayout("topLevel", #menu) or nil
        local target = type(records) == "table" and records[index] or nil
        local touch = type(target) == "table" and target.touch or nil
        if type(touch) == "table" then
          local right = touch.right == 0 and 256 or touch.right
          taps = taps + 1
          local pointerId = "battle-menu-tap:" .. tostring(taps)
          local x = touch.left + (right - touch.left) / 2
          local y = touch.top + (touch.bottom - touch.top) / 2
          translated[#translated + 1] = { type = "pointer_down", pointerId = pointerId, x = x, y = y }
          translated[#translated + 1] = { type = "pointer_up", pointerId = pointerId, x = x, y = y }
        end
      end
    end
  end
  return translated
end

-- Retail HM set behind the battle forget guard (src/item.c sTMHMMoves
-- HM01-HM08): these held moves refuse with msg 60 instead of sealing.
BattleChildApplications.HM_MOVES = {
  CUT = true,
  FLY = true,
  SURF = true,
  STRENGTH = true,
  WHIRLPOOL = true,
  ROCK_SMASH = true,
  WATERFALL = true,
  ROCK_CLIMB = true,
}

BattleChildApplications.RECEIPTS = {
  party = "party",
  bag = "bag",
  learn = "summary",
  naming = "naming",
  evolution = "evolution",
}

-- The battle-local default keyboard map covers printable ASCII so the
-- native naming grid stays fully operable without the generated font. A
-- caller carrying the generated font charmap injects it through services
-- and the injected map wins.
---@return table<string, integer>
local function defaultCharmap()
  local map = {}
  for code = string.byte(" "), string.byte("~") do
    map[string.char(code)] = code
  end
  return map
end

-- Silent naming sound boundary while battle threads no audio through
-- child services: naming still composes (the controller requires a
-- boundary) until battle provides its own effect function.
local function silentNamingEffect() end

---@param value unknown
---@return unknown detached copy without shared mutable state
local function copyValue(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for key, item in pairs(value) do
    out[key] = copyValue(item)
  end
  return out
end

-- Binds one projected fragment to the opening barrier. Fragments are
-- copied, never rebuilt, so the kernel keeps owning their shape.
---@param identity table<string, unknown> opening barrier identity under binding
---@param fragment table<string, unknown> projected choice fragment under binding
---@return table<string, unknown> bound staged reply
local function bindFragment(identity, fragment)
  return {
    requestId = identity.requestId,
    epoch = identity.epoch,
    controller = identity.controller,
    launchId = identity.launchId,
    choices = { copyValue(fragment) },
  }
end

-- Reports the one-shot child result bound to the opening barrier. The
-- first take wins; every later take reports nil.
---@param child table<string, unknown> composed child under reporting
---@param kind string result kind under reporting
---@param choice table<string, unknown>? authoritative payload, nil for cancellations
---@return table<string, unknown>? bound result, nil once consumed
local function takeChildResult(child, kind, choice)
  if child._taken then
    return nil
  end
  child._taken = true
  local result = {
    kind = kind,
    requestId = child._identity.requestId,
    epoch = child._identity.epoch,
    controller = child._identity.controller,
    launchId = child._identity.launchId,
  }
  if kind == "choice" then
    result.reply = bindFragment(child._identity, assert(choice, "choices carry their fragment"))
  end
  return result
end

---@param intent table<string, unknown> child intent under validation
---@return table<string, unknown> opening barrier identity
local function checkIdentity(intent)
  assert(type(intent) == "table", "child intents arrive as records")
  assert(
    intent.kind == "party"
      or intent.kind == "bag"
      or intent.kind == "learn"
      or intent.kind == "naming"
      or intent.kind == "evolution",
    "child intents name party, bag, learn, naming, or evolution"
  )
  assert(type(intent.launchId) == "string" and intent.launchId ~= "", "child intents carry their launch")
  assert(type(intent.requestId) == "number" and intent.requestId % 1 == 0, "child intents carry their request identity")
  assert(type(intent.epoch) == "number" and intent.epoch % 1 == 0, "child intents carry their epoch")
  assert(type(intent.controller) == "string" and intent.controller ~= "", "child intents carry their controller")
  return {
    kind = intent.kind,
    launchId = intent.launchId,
    requestId = intent.requestId,
    epoch = intent.epoch,
    controller = intent.controller,
  }
end

---@param options table<string, unknown> decision options under projection
---@return table<integer, table<integer, table<string, unknown>>> enabled switch fragments by actor combatant then replacement
local function enabledSwitches(options)
  local found = {}
  if type(options.actors) ~= "table" then
    return found
  end
  for _, actor in ipairs(options.actors) do
    if type(actor) == "table" and type(actor.combatant) == "number" and type(actor.choices) == "table" then
      local byReplacement = found[actor.combatant]
      if byReplacement == nil then
        byReplacement = {}
        found[actor.combatant] = byReplacement
      end
      for _, choice in ipairs(actor.choices) do
        if
          type(choice) == "table"
          and choice.enabled == true
          and type(choice.choice) == "table"
          and choice.choice.kind == "switch"
          and type(choice.choice.payload) == "table"
          and type(choice.choice.payload.replacement) == "number"
        then
          byReplacement[choice.choice.payload.replacement] = choice.choice
        end
      end
    end
  end
  return found
end

---@param options table<string, unknown> decision options under projection
---@param key string staged item identity under projection
---@return table<integer, table<string, unknown>> enabled item fragments by target combatant
local function enabledItemTargets(options, key)
  local found = {}
  if type(options.actors) ~= "table" then
    return found
  end
  for _, actor in ipairs(options.actors) do
    if type(actor) == "table" and type(actor.choices) == "table" then
      for _, choice in ipairs(actor.choices) do
        if
          type(choice) == "table"
          and choice.enabled == true
          and type(choice.choice) == "table"
          and choice.choice.kind == "item"
          and type(choice.choice.payload) == "table"
          and choice.choice.payload.item == key
          and type(choice.choice.payload.target) == "table"
          and type(choice.choice.payload.target.combatant) == "number"
        then
          found[choice.choice.payload.target.combatant] = choice.choice
        end
      end
    end
  end
  return found
end

---@param options table<string, unknown> decision options under target explanation
---@param key string staged item identity under explanation
---@param combatant integer addressed target under explanation
---@return string? reason for this target, nil while enabled or unoffered
local function itemTargetReason(options, key, combatant)
  if type(options.actors) ~= "table" then
    return nil
  end
  for _, actor in ipairs(options.actors) do
    if type(actor) == "table" and type(actor.choices) == "table" then
      for _, choice in ipairs(actor.choices) do
        local fragment = type(choice) == "table" and choice.choice or nil
        local payload = type(fragment) == "table" and fragment.payload or nil
        local target = type(payload) == "table" and payload.target or nil
        if
          type(choice) == "table"
          and choice.enabled ~= true
          and type(fragment) == "table"
          and fragment.kind == "item"
          and type(payload) == "table"
          and payload.item == key
          and type(target) == "table"
          and target.combatant == combatant
          and type(choice.reason) == "string"
        then
          return choice.reason --[[@as string]]
        end
      end
    end
  end
  return nil
end

-- Battle-local party facts model over the detached roster: slot occupancy
-- comes from the snapshot, eligibility from the authoritative kernel
-- fragments, and health/status from the snapshot health. The controller
-- navigates, selects, and refuses through these facts; live party state is
-- never consulted.
---@param roster table<integer, table<string, unknown>> detached own-party snapshot under projection
---@param eligible table<integer, boolean> eligible combatants under projection
---@param gateActive boolean true while active mons stay ineligible behind the switch refusal
---@return table<string, unknown> battle-local party facts model
local function battlePartyModel(roster, eligible, gateActive)
  local function refreshModel()
    local slots = {}
    for slot = 0, 5 do
      slots[slot + 1] = { occupied = false, eligible = false }
    end
    for _, record in ipairs(roster) do
      if type(record) == "table" and type(record.slot) == "number" and type(record.combatant) == "number" then
        assert(slots[record.slot + 1] ~= nil, "battle roster slots stay unique")
        local fainted = (tonumber(record.hp) or 0) <= 0
        local condition = type(record.condition) == "string" and record.condition:lower() or ""
        local status = "ok"
        if fainted then
          status = "faint"
        elseif condition == "sleep" then
          status = "sleep"
        elseif condition == "poison" or condition == "bad-poison" or condition == "toxic" then
          status = "poison"
        elseif condition == "burn" or condition == "freeze" or condition == "paralysis" then
          status = condition
        end
        local iconKey = nil
        if type(record.species) == "string" then
          iconKey = MonCache.iconSelector(record.species, type(record.form) == "number" and record.form or 0, false)
        end
        -- Retail roster gates precede kernel eligibility for switching:
        -- fainted, egg, and active mons never switch even if a stale
        -- projection still marks them eligible. Item targeting answers
        -- the kernel alone, so an active holder stays eligible there.
        local kernelEligible = eligible[record.combatant] == true
        local rosterEligible = not fainted and record.isEgg ~= true and (gateActive ~= true or record.active ~= true)
        slots[record.slot + 1] = {
          occupied = true,
          eligible = kernelEligible and rosterEligible,
          combatant = record.combatant,
          displayName = type(record.name) == "string" and record.name or "Unknown",
          level = record.level,
          currentHp = tonumber(record.hp) or 0,
          maxHp = tonumber(record.maxHp) or 0,
          status = status,
          iconKey = iconKey,
          genderSymbol = record.gender,
          isEgg = record.isEgg == true,
          active = record.active == true,
          moves = record.moves,
        }
      end
    end
    return { revision = 1, slots = slots }
  end
  return { refresh = refreshModel }
end

-- Battle-local summary facts model over the staged learning prompt: the
-- four held rows carry their staged move, PP, and upgrade facts with the
-- incoming move flagged, in slot order. The move-pick presentation
-- navigates and selects through these facts; no live mon is ever edited.
---@param prompt table<string, unknown> staged learning prompt under projection
---@return table<string, unknown> battle-local summary facts model
---@return table<integer, table<string, unknown>> held-move fact rows in slot order
local function battleSummaryModel(prompt)
  local moves = assert(prompt.currentMoves, "learning prompts carry their held move set")
  assert(type(moves) == "table" and #moves == 4, "learning prompts carry four held moves")
  local incoming = prompt.incomingMove
  local rows = {}
  for slot = 1, 4 do
    local entry = moves[slot]
    assert(type(entry) == "table", "held moves arrive as records")
    rows[slot] = {
      kind = "move",
      slot = slot - 1,
      move = entry.move,
      pp = entry.pp,
      ppUps = entry.ppUps,
      incoming = entry.move == incoming,
    }
  end
  local function refreshModel(_)
    return { revision = 1, slotCount = 1, moves = copyValue(rows), incomingMove = incoming }
  end
  local model = { refresh = refreshModel }
  return model, rows
end

-- Resolves one projected learning fragment by choice identity. Stale or
-- refused identities resolve to nil so no invented reply can seal.
---@param options table<string, unknown> decision options under translation
---@param id string projected learning choice identity under translation
---@return table<string, unknown>? projected choice fragment, nil when absent or refused
local function learnFragment(options, id)
  if type(options.actors) ~= "table" then
    return nil
  end
  for _, actor in ipairs(options.actors) do
    if type(actor) == "table" and type(actor.choices) == "table" then
      for _, choice in ipairs(actor.choices) do
        if type(choice) == "table" and choice.id == id and choice.enabled == true then
          return choice.choice --[[@as table<string, unknown>]]
        end
      end
    end
  end
  return nil
end

---@param kind string composed child kind under construction
---@param intent table<string, unknown> validated child intent under construction
---@return table<string, unknown> bound barrier identity shared by the child
local function childIdentity(kind, intent)
  return {
    kind = kind,
    launchId = intent.launchId,
    requestId = intent.requestId,
    epoch = intent.epoch,
    controller = intent.controller,
  }
end

-- Routes one semantic edge batch to a real application controller. Only
-- the barrier-owned semantic edges travel: navigation, confirmation,
-- cancellation, pointer-capture release, and the barrier-synthesized tap
-- pointer pairs at canonical modal centers. Raw pointer press topology
-- stays with the barrier so a held or stale press can never arm
-- controller state; the controllers observe only matched synthetic pairs.
---@param controller table<string, unknown> real application controller under stepping
---@param events table<integer, table<string, unknown>> semantic input batch under routing
local function routeSemantic(controller, events)
  local batch = {}
  for _, event in ipairs(events) do
    if type(event) == "table" and type(event.type) == "string" then
      if
        event.type == "navigate"
        or event.type == "confirm"
        or event.type == "cancel"
        or event.type == "pointer_cancel"
        or event.type == "pointer_down"
        or event.type == "pointer_up"
      then
        batch[#batch + 1] = event
      end
    else
      break
    end
  end
  if #batch == 0 then
    return
  end
  if type(controller.applyEvent) == "function" then
    local apply = controller.applyEvent --[[@as fun(self: table<string, unknown>, event: table<string, unknown>)]]
    for _, event in ipairs(batch) do
      if event.type == "pointer_cancel" then
        apply(controller, event)
      else
        apply(controller, event)
      end
    end
    return
  end
  local step = controller.updateFixed --[[@as fun(self: table<string, unknown>, events: table<integer, table<string, unknown>>)]]
  assert(type(step) == "function", "composed controllers step their semantic batch")
  step(controller, batch)
end

---@param controller table<string, unknown> real application controller under draining
---@return table<string, unknown>? drained native intent, nil when the controller staged nothing
local function drainIntent(controller)
  local take = controller.takeIntent
  if type(take) ~= "function" then
    return nil
  end
  local emit = take --[[@as fun(self: table<string, unknown>): table<string, unknown>?]]
  return emit(controller)
end

---@param controller table<string, unknown> real application controller under draining
---@return table<string, unknown>? drained native result, nil when the controller sealed nothing
local function drainResult(controller)
  local take = controller.takeResult
  if type(take) ~= "function" then
    return nil
  end
  local emit = take --[[@as fun(self: table<string, unknown>): table<string, unknown>?]]
  return emit(controller)
end

-- Harvests one-shot native evidence into the child stash without
-- translating it: the barrier binds authoritative kernel fragments while
-- native intents and results stay observable exactly as the application
-- owners sealed them. The stash keeps the latest evidence per slot.
---@param child table<string, unknown> composed child under harvesting
---@param controller table<string, unknown>? real application controller under harvesting
local function harvest(child, controller)
  if controller == nil then
    return
  end
  local intent = drainIntent(controller)
  if intent ~= nil then
    child._nativeIntent = intent
  end
  local result = drainResult(controller)
  if result ~= nil then
    child._nativeResult = result
  end
end

-- Composes the native move picker in its PP-restore context over one
-- holder's detached roster moves, standing in for the native Restore PP
-- page. Rows carry the roster's move, PP, and maximum PP facts in slot
-- order; unheld slots stay empty so the picker never focuses them.
---@param record table<string, unknown> detached roster record of the holder
---@return table<string, unknown>? composed move picker
---@return string? failure cause
local function composeRestorePicker(record)
  local moves = record.moves
  assert(type(moves) == "table", "PP holders carry their roster moves")
  local rows = {}
  for index = 1, 4 do
    local entry = moves[index]
    if type(entry) == "table" then
      rows[index] = {
        kind = "move",
        moveSlot = index - 1,
        key = entry.move,
        name = entry.name,
        pp = entry.pp,
        maxPp = entry.maxPp,
      }
    else
      rows[index] = { kind = "empty", moveSlot = index - 1 }
    end
  end
  local function refreshModel(_)
    return { revision = 1, slotCount = 1, moves = copyValue(rows) }
  end
  local function moveLayout()
    return { hitTest = battleMoveHit }
  end
  local ok, controller = pcall(SummaryController.new, {
    mode = "move_pick",
    model = { refresh = refreshModel },
    resolveLayout = moveLayout,
    reorderMoves = nil,
    readNavigation = nil,
    request = { context = "pp_restore" },
  })
  if not ok then
    return nil, tostring(controller)
  end
  controller:refreshFacts()
  return controller
end

-- Retail battle-bag browser over detached stock (battle_bag_menu.c pages
-- 0 pocket menu, 1 item list, 2 use-item, plus the TryUseItem message).
-- Groups field stock into the four battle pockets via BattleBagPockets
-- (bit mask through sBattleBagPocketOrder) in saved-bag slot order,
-- pages six cells per pocket, and stages battle_select intents on USE.
-- Empty cells never stage. Last-used selects its item directly when
-- present and still stocked; otherwise the option stays disabled
-- without sound. Tutorial finger paths stay gated behind
-- intent.isTutorial. The browser stays silent; the subflows barrier
-- owns DECIDE/SELECT.
--
---@param inventory table<string, integer> detached battle stock under grouping
---@param catalog table<string, unknown>? borrowed immutable item catalog
---@param intent table<string, unknown> validated bag intent (lastUsed/isTutorial/slotOrder/battleCursor optional)
---@return table<string, unknown>? browser controller
---@return string? failure cause
local function newBattleBagBrowser(inventory, catalog, intent)
  if catalog == nil then
    return nil, "the stocked bag needs its item catalog"
  end
  local groups = BattleBagPockets.group(inventory, catalog, intent.slotOrder)
  local browser = {
    _groups = groups,
    _pages = { [0] = 0, [1] = 0, [2] = 0, [3] = 0 },
    _positions = { [0] = 0, [1] = 0, [2] = 0, [3] = 0 },
    _page = "pocket_menu",
    _menuFocus = 0,
    -- Recorded return-link position behind the pocket-menu cursor
    -- (BattleDpadCursor prevPosition): the cancel-adjacent edge
    -- (page-0 box 5 up 0x83) leads back through it, 0xFF/nil without one.
    _menuPrev = nil,
    _pocket = nil,
    _useCell = nil,
    -- Item-list d-pad cursor box behind the saved cell: retail keeps the
    -- BattleDpadCursor position apart from pocketPositions, so the cursor
    -- roams the six cells and the seventh Back box freely (even onto
    -- empty cells) while the saved cell only moves on a stocked confirm.
    -- 6 focuses Back; confirming it returns to the pocket menu.
    _cursor = 0,
    -- Recorded return-link position behind the item-list cursor: Back
    -- up (page-1 box 6 up 0x85) leads back to the cell the cursor came
    -- from (4 or 5), nil without one.
    _listPrev = nil,
    _message = nil,
    _intent = nil,
    _result = nil,
    _disposed = false,
    _lastUsed = nil,
    -- The catching-tutorial marker: the browser auto-plays behind the
    -- lesson finger instead of taking input (battle_bag_menu.c
    -- RunTutorial via BattleBagContext.isTutorial).
    _tutorial = intent.isTutorial == true,
    -- Lesson finger clock: the page the finger was last armed on and the
    -- ticks it has run there.
    _fingerPage = nil,
    _fingerTicks = 0,
    -- D-pad cursor visibility (BattleDpadCursor active flag): set by
    -- the first key press (TryActivate), cleared by touch
    -- (DeactivateCursor), and kept between openings
    -- (BattleBagContext.cursorActive). Fresh browsers start hidden.
    _cursorActive = intent.cursorActive == true,
    -- Press animation gate (WaitButtonAnim): the staged button and
    -- phase while the press dip shows, with the deferred page
    -- transition. Edges in between are dropped. USE stages its intent
    -- immediately and animates fire-and-forget (pending nil).
    _anim = nil,
    _pending = nil,
  }
  local lastUsed = intent.lastUsed
  if type(lastUsed) == "table" and type(lastUsed.item) == "string" then
    local pocket = tonumber(lastUsed.pocket)
    if pocket ~= nil and pocket % 1 == 0 and pocket >= 0 and pocket <= 3 then
      pocket = math.floor(pocket)
      local key = BattleBagPockets.POCKET_KEYS[pocket + 1]
      for _, entry in ipairs(groups[key]) do
        if entry.item == lastUsed.item then
          browser._lastUsed = { item = lastUsed.item, pocket = pocket }
          break
        end
      end
    end
  end
  -- Retail cursor memory (BattleBagMenu_Create reads BagCursor battle
  -- positions, pages, pocket, and last-used): the menu reopens on its
  -- saved pocket with each pocket's page and cell restored.
  local saved = intent.battleCursor
  if type(saved) == "table" then
    local pocket = tonumber(saved.pocket)
    if pocket ~= nil and pocket % 1 == 0 and pocket >= 0 and pocket <= 3 then
      browser._menuFocus = pocket --[[@as integer]]
    end
    if type(saved.pages) == "table" then
      for index = 0, 3 do
        local page = tonumber(saved.pages[index])
        if page ~= nil and page % 1 == 0 and page >= 0 then
          browser._pages[index] = page
        end
      end
    end
    if type(saved.positions) == "table" then
      for index = 0, 3 do
        local position = tonumber(saved.positions[index])
        if position ~= nil and position % 1 == 0 and position >= 0 then
          browser._positions[index] = position
        end
      end
    end
    if saved.cursorActive == true then
      browser._cursorActive = true
    end
  end
  ---@param pocket integer zero-based battle pocket under counting
  ---@return integer page count, at least 1
  local function pageCount(pocket)
    local key = BattleBagPockets.POCKET_KEYS[pocket + 1]
    local count = #groups[key]
    if count == 0 then
      return 1
    end
    return math.floor((count - 1) / 6) + 1
  end
  -- Restored pages clamp to the stocked page count on setup
  -- (SortItemsIntoPockets clamps pocketPages the same way).
  for index = 0, 3 do
    local count = pageCount(index)
    if browser._pages[index] >= count then
      browser._pages[index] = count - 1
    end
  end
  ---@param pocket integer zero-based battle pocket under clamping
  ---@return nil
  local function clampPage(pocket)
    -- SortItemsIntoPockets clamps only the page on setup: the saved
    -- cell reopens raw like the retail cursor, so an empty cell simply
    -- stages nothing.
    local pages = browser._pages
    local count = pageCount(pocket)
    if pages[pocket] < 0 then
      pages[pocket] = 0
    elseif pages[pocket] >= count then
      pages[pocket] = count - 1
    end
  end
  ---@param pocket integer zero-based battle pocket under entry
  ---@return nil
  local function enterPocket(pocket)
    browser._pocket = pocket
    browser._page = "item_list"
    -- Entering the list seats the cursor on the saved cell
    -- (ShowItemListPage seats the cursor at pocketPositions).
    -- SetBoxes resets the return-link record behind the new page.
    browser._cursor = browser._positions[pocket]
    browser._listPrev = nil
    clampPage(pocket)
  end
  -- Stages one button press behind the animation gate
  -- (BattleBagMenu_StartButtonAnim + WaitButtonAnim): the dip shows
  -- frames 1 then 2 while the deferred transition waits; every edge
  -- in between is dropped. A nil pending transition animates
  -- fire-and-forget behind the running USE page instead.
  ---@param button integer retail button identity under animation
  ---@param pending function? deferred page transition, nil for fire-and-forget
  ---@return nil
  local function startPress(button, pending)
    browser._anim = { button = button, phase = 1 }
    browser._pending = pending
  end
  -- Advances the staged press dip once per tick: frame 1 rebounds to
  -- frame 2, then the deferred transition applies and the gate lifts.
  -- Fire-and-forget presses simply clear after their rebound.
  ---@return nil
  local function advanceAnim()
    local anim = browser._anim
    if anim == nil then
      return
    end
    if anim.phase == 1 then
      anim.phase = 2
      return
    end
    local pending = browser._pending
    browser._anim = nil
    browser._pending = nil
    if pending ~= nil then
      pending()
    end
  end
  ---@param direction string D-pad direction under stepping
  ---@return integer decomp direction code behind the step
  local function bagDirectionCode(direction)
    if direction == "up" then
      return 0
    end
    if direction == "down" then
      return 1
    end
    if direction == "left" then
      return 2
    end
    assert(direction == "right", "bag dpad steps name their direction")
    return 3
  end
  ---@param box table<string, unknown> cursor box behind the neighbor lookup
  ---@param code integer decomp direction code under lookup
  ---@return integer neighbor box index with its return-link flag
  local function bagNeighbor(box, code)
    if code == 0 then
      return box.up
    end
    if code == 1 then
      return box.down
    end
    if code == 2 then
      return box.left
    end
    return box.right
  end
  ---@param box table<string, unknown> newly entered cursor box under link lookup
  ---@param code integer decomp direction code under lookup
  ---@return boolean linked true while the opposite edge carries the return flag
  local function bagHasReturnLink(box, code)
    -- BattleDpadCursor_HasReturnLink: the neighbor opposite the move
    -- direction carries bit 7 back to the box the cursor came from.
    if code == 0 then
      return (box.down % 256) >= 128
    end
    if code == 1 then
      return (box.up % 256) >= 128
    end
    if code == 2 then
      return (box.right % 256) >= 128
    end
    return (box.left % 256) >= 128
  end
  ---@param focus integer pocket-menu focus under motion
  ---@param direction string D-pad direction under motion
  ---@return integer settled pocket-menu focus
  local function moveMenuFocus(focus, direction)
    -- Neighbors ride the transcribed page-0 cursor boxes
    -- (sBattleBagPage0CursorBoxes) so motion and paint share one table.
    -- A flagged neighbor (bit 7, page-0 box 5 up 0x83) leads back
    -- through the recorded position when one exists, else strips its
    -- flag like the source (BattleDpadCursor_HandleInput).
    local boxes = BattleBagPockets.CURSOR_BOXES.pocket_menu
    local code = bagDirectionCode(direction)
    local row = boxes[focus + 1] or boxes[1]
    local raw = bagNeighbor(row, code) % 256
    local input = raw
    if input >= 128 then
      local prev = browser._menuPrev
      if prev ~= nil then
        input = prev
      else
        input = input - 128
      end
    end
    assert(type(boxes[input + 1]) == "table", "pocket-menu dpad neighbors stay on their page")
    if input == focus then
      return focus
    end
    local next = nil
    if bagHasReturnLink(boxes[input + 1], code) then
      next = focus
    end
    browser._menuPrev = next
    return input
  end
  -- Moves the item-list d-pad cursor across its static boxes: the six
  -- cells roam freely (even onto empty cells) with Back as box 6 below
  -- the bottom row, and edge motion against a multi-page pocket turns
  -- the page instead. Plain motion applies at once; the edge turn only
  -- reports its direction so the caller can stage the stepper dip
  -- behind the animation gate (HandleItemListInput animates buttons 12
  -- and 13 through WaitButtonAnim). Page turns reset only the saved
  -- cell (ChangeItemPage clears pocketPositions); the cursor keeps its box.
  -- Back up carries the 0x85 return link back to the recorded cell
  -- (4 or 5); down onto Back records it like the source.
  ---@param pocket integer zero-based battle pocket under motion
  ---@param direction string D-pad direction under motion
  ---@return integer? page-turn delta, nil for plain cursor motion
  local function moveListCursor(pocket, direction)
    local cursor = browser._cursor
    local code = bagDirectionCode(direction)
    if cursor == 6 then
      local boxes = BattleBagPockets.CURSOR_BOXES.item_list
      local raw = bagNeighbor(boxes[7], code) % 256
      local input = raw
      if input >= 128 then
        local prev = browser._listPrev
        if prev ~= nil then
          input = prev
        else
          input = input - 128
        end
      end
      if input == cursor then
        return nil
      end
      local next = nil
      if bagHasReturnLink(boxes[input + 1], code) then
        next = cursor
      end
      browser._listPrev = next
      browser._cursor = input
      return nil
    end
    local col = cursor % 2
    local row = math.floor(cursor / 2)
    local boxes = BattleBagPockets.CURSOR_BOXES.item_list
    if direction == "left" then
      if col == 0 then
        if pageCount(pocket) > 1 then
          return -1
        end
        return nil
      end
      local input = row * 2
      if input ~= cursor and bagHasReturnLink(boxes[input + 1], code) then
        browser._listPrev = cursor
      else
        browser._listPrev = nil
      end
      browser._cursor = input
    elseif direction == "right" then
      if col == 1 then
        if pageCount(pocket) > 1 then
          return 1
        end
        return nil
      end
      local input = row * 2 + 1
      if input ~= cursor and bagHasReturnLink(boxes[input + 1], code) then
        browser._listPrev = cursor
      else
        browser._listPrev = nil
      end
      browser._cursor = input
    elseif direction == "up" then
      if row == 0 then
        return nil
      end
      local input = (row - 1) * 2 + col
      if input ~= cursor and bagHasReturnLink(boxes[input + 1], code) then
        browser._listPrev = cursor
      else
        browser._listPrev = nil
      end
      browser._cursor = input
    elseif direction == "down" then
      if row == 2 then
        -- Down onto Back records the origin cell behind the 0x85
        -- return link (BattleDpadCursor_HasReturnLink checks the
        -- destination up edge on a down move).
        browser._listPrev = cursor
        browser._cursor = 6
        return nil
      end
      local input = (row + 1) * 2 + col
      if input ~= cursor and bagHasReturnLink(boxes[input + 1], code) then
        browser._listPrev = cursor
      else
        browser._listPrev = nil
      end
      browser._cursor = input
    end
    return nil
  end
  -- Retail tutorial auto-play (battle_bag_menu.c RunTutorial): the
  -- lesson finger owns the bag, so finger touches advance pocket 2
  -- Retail tutorial auto-play (battle_bag_menu.c RunTutorial): the
  -- lesson finger owns the bag (BattleFinger_HasTouched), so only
  -- finger touches advance pocket 2 (balls) → first cell → USE while
  -- every other edge is ignored and cancel never leaves. Confirm keys,
  -- D-pad motion, and pointer topology stay with the barrier: retail
  -- never reads gSystem.newKeys behind the tutorial, only the finger.
  -- Button-press motion rides the shared tick sounds behind the page turns.
  -- Page changes wait out the press dip behind the same gate as the
  -- interactive browser; USE fires its intent at once.
  ---@param event table<string, unknown> semantic input under tutorial stepping
  local function tutorialEvent(event)
    if browser._pending ~= nil then
      return
    end
    local kind = event.type
    if kind == "tap" and type(event.id) == "string" then
      local id = event.id --[[@as string]]
      if browser._page == "pocket_menu" and id == "bagpocket:2" then
        browser._menuFocus = 2
        browser._pocket = 2
        startPress(2, function()
          enterPocket(2)
        end)
      elseif browser._page == "item_list" and id == "bag:0" and browser._pocket ~= nil then
        local pocket = browser._pocket --[[@as integer]]
        local key = BattleBagPockets.POCKET_KEYS[pocket + 1]
        browser._positions[pocket] = 0
        browser._cursor = 0
        if groups[key][browser._pages[pocket] * 6 + 1] ~= nil then
          startPress(6, function()
            browser._useCell = 0
            browser._page = "use_item"
            browser._useFocus = "use"
          end)
        end
      elseif browser._page == "use_item" and id == "use" then
        browser._useFocus = "use"
        if browser._pocket ~= nil then
          local key = BattleBagPockets.POCKET_KEYS[browser._pocket + 1]
          local entry = groups[key][browser._pages[browser._pocket] * 6 + (browser._useCell or 0) + 1]
          if entry ~= nil then
            browser._intent = { kind = "battle_select", item = entry.item }
            startPress(15, nil)
          end
        end
      elseif browser._page == "message" and (id == "back" or id == "use") then
        browser._page = "use_item"
        browser._message = nil
      end
    elseif kind == "pointer_up" and type(event.x) == "number" and type(event.y) == "number" then
      local px, py = event.x, event.y
      if browser._page == "pocket_menu" then
        if BattleBagPockets.hitIndex(BattleBagPockets.HITBOXES.pocketMenu, px, py) == 2 then
          browser._menuFocus = 2
          browser._pocket = 2
          startPress(2, function()
            enterPocket(2)
          end)
        end
      elseif browser._page == "item_list" and browser._pocket ~= nil then
        if BattleBagPockets.hitIndex(BattleBagPockets.HITBOXES.itemList, px, py) == 0 then
          local pocket = browser._pocket --[[@as integer]]
          local key = BattleBagPockets.POCKET_KEYS[pocket + 1]
          browser._positions[pocket] = 0
          browser._cursor = 0
          if groups[key][browser._pages[pocket] * 6 + 1] ~= nil then
            startPress(6, function()
              browser._useCell = 0
              browser._page = "use_item"
              browser._useFocus = "use"
            end)
          end
        end
      elseif browser._page == "use_item" then
        if BattleBagPockets.hitIndex(BattleBagPockets.HITBOXES.useItem, px, py) == 0 then
          browser._useFocus = "use"
          if browser._pocket ~= nil then
            local key = BattleBagPockets.POCKET_KEYS[browser._pocket + 1]
            local entry = groups[key][browser._pages[browser._pocket] * 6 + (browser._useCell or 0) + 1]
            if entry ~= nil then
              browser._intent = { kind = "battle_select", item = entry.item }
              startPress(15, nil)
            end
          end
        end
      elseif browser._page == "message" then
        browser._page = "use_item"
        browser._message = nil
      end
    end
    -- Navigate, cancel, and pointer topology stay with the barrier:
    -- the lesson finger alone advances the auto-play.
  end
  -- Runs the lesson finger one tick: each shown page re-arms it, and it
  -- touches that page's control once its retail timing elapses.
  ---@return nil
  local function stepTutorialFinger()
    if browser._fingerPage ~= browser._page then
      browser._fingerPage = browser._page
      browser._fingerTicks = 0
    end
    local target = TUTORIAL_FINGER_TARGETS[browser._page]
    if target == nil or browser._pending ~= nil then
      return
    end
    browser._fingerTicks = browser._fingerTicks + 1
    if browser._fingerTicks == BattleFinger.TOUCH_TICKS then
      tutorialEvent({ type = "tap", id = target })
    end
  end
  ---@param events table<integer, table<string, unknown>> semantic input batch under stepping
  function browser:updateFixed(events)
    if browser._disposed then
      return
    end
    local animAtStart = browser._anim ~= nil
    for _, event in ipairs(events) do
      if type(event) ~= "table" or type(event.type) ~= "string" then
        break
      end
      if browser._tutorial == true then
        -- The lesson finger alone advances the auto-play; shared
        -- interactive input never runs behind it.
        tutorialEvent(event)
      elseif browser._pending ~= nil then
        -- The press dip gates input (WaitButtonAnim): edges in
        -- between are dropped, never queued.
      else
        local kind = event.type
        if kind == "tap" and type(event.id) == "string" then
          -- Touch deactivates the d-pad cursor (DeactivateCursor:
          -- active false plus ResetPosition to 0 with prev 0xFF)
          -- while the tap resolves through the hitboxes below.
          -- A disabled or empty tap keeps the reset position like
          -- the source instead of retaining the old focus.
          if browser._page == "pocket_menu" then
            browser._cursorActive = false
            browser._menuFocus = 0
            browser._menuPrev = nil
          elseif browser._page == "item_list" then
            browser._cursorActive = false
            browser._cursor = 0
            browser._listPrev = nil
          elseif browser._page == "use_item" then
            browser._cursorActive = false
            browser._useFocus = "use"
          end
          browser:handleTap(event.id)
        elseif kind == "navigate" and type(event.direction) == "string" then
          -- The first key press only activates the cursor
          -- (BattleDpadCursor_TryActivate); motion runs once active.
          if browser._cursorActive ~= true then
            browser._cursorActive = true
          elseif browser._page == "pocket_menu" then
            browser._menuFocus = moveMenuFocus(browser._menuFocus --[[@as integer]], event.direction)
          elseif browser._page == "item_list" and browser._pocket ~= nil then
            local pocket = browser._pocket --[[@as integer]]
            local turn = moveListCursor(pocket, event.direction)
            if turn ~= nil then
              local button = turn < 0 and 12 or 13
              startPress(button, function()
                local count = pageCount(pocket)
                browser._pages[pocket] = (browser._pages[pocket] + turn) % count
                -- Turning the page resets the saved cell
                -- (ChangeItemPage clears pocketPositions); the cursor
                -- keeps its box and its return-link record.
                browser._positions[pocket] = 0
                clampPage(pocket)
              end)
            end
          elseif browser._page == "use_item" then
            -- Retail use-item cursor (sBattleBagPage2CursorBoxes): USE
            -- holds up/down (0,0) and Back holds up/down (1,1); only
            -- left/right toggles. An up/down press keeps the focus.
            if event.direction == "left" or event.direction == "right" then
              browser._useFocus = browser._useFocus == "use" and "back" or "use"
            end
          end
        elseif kind == "confirm" then
          -- Message acknowledgement answers A/B directly (WaitMessageInput
          -- reads keys without the d-pad cursor); every browser page
          -- activates first like TryActivate, consuming the edge.
          if browser._page ~= "message" and browser._cursorActive ~= true then
            browser._cursorActive = true
          elseif browser._page == "pocket_menu" then
            local focus = browser._menuFocus
            if focus >= 0 and focus <= 3 then
              startPress(focus, function()
                enterPocket(focus)
              end)
            elseif focus == 4 then
              if browser._lastUsed ~= nil then
                startPress(4, function()
                  browser._pocket = browser._lastUsed.pocket
                  browser._page = "item_list"
                  clampPage(browser._pocket --[[@as integer]])
                  local key = BattleBagPockets.POCKET_KEYS[browser._pocket + 1]
                  for index, entry in ipairs(groups[key]) do
                    if entry.item == browser._lastUsed.item then
                      browser._pages[browser._pocket] = math.floor((index - 1) / 6)
                      browser._positions[browser._pocket] = (index - 1) % 6
                      break
                    end
                  end
                  browser._useCell = browser._positions[browser._pocket]
                  browser._page = "use_item"
                  browser._useFocus = "use"
                end)
              end
            elseif focus == 5 then
              browser._result = { kind = "closed" }
            end
          elseif browser._page == "item_list" and browser._pocket ~= nil then
            local pocket = browser._pocket --[[@as integer]]
            if browser._cursor == 6 then
              -- Confirming Back returns to the pocket menu with the
              -- pocket focused (ShowPocketMenuPage seats the cursor at
              -- the pocket, SetBoxes clearing the return record).
              startPress(14, function()
                browser._page = "pocket_menu"
                browser._menuFocus = pocket
                browser._menuPrev = nil
              end)
            else
              local key = BattleBagPockets.POCKET_KEYS[pocket + 1]
              local entry = groups[key][browser._pages[pocket] * 6 + browser._cursor + 1]
              if entry ~= nil then
                local cell = browser._cursor
                startPress(6 + cell, function()
                  browser._positions[pocket] = cell
                  browser._useCell = cell
                  browser._page = "use_item"
                  browser._useFocus = "use"
                end)
              end
            end
          elseif browser._page == "use_item" then
            if browser._useFocus == "use" and browser._pocket ~= nil then
              local key = BattleBagPockets.POCKET_KEYS[browser._pocket + 1]
              local entry = groups[key][browser._pages[browser._pocket] * 6 + (browser._useCell or 0) + 1]
              if entry ~= nil then
                browser._intent = { kind = "battle_select", item = entry.item }
                startPress(15, nil)
              end
            else
              startPress(16, function()
                browser._page = "item_list"
              end)
            end
          elseif browser._page == "message" then
            browser._page = "use_item"
            browser._message = nil
          end
        elseif kind == "cancel" then
          -- B also activates first like TryActivate; the message page
          -- answers B directly without the cursor.
          if browser._page ~= "message" and browser._cursorActive ~= true then
            browser._cursorActive = true
          elseif browser._page == "pocket_menu" then
            browser._result = { kind = "closed" }
          elseif browser._page == "item_list" then
            local pocket = browser._pocket --[[@as integer]]
            startPress(14, function()
              browser._page = "pocket_menu"
              browser._menuFocus = pocket
              browser._menuPrev = nil
            end)
          elseif browser._page == "use_item" then
            startPress(16, function()
              browser._page = "item_list"
            end)
          elseif browser._page == "message" then
            browser._page = "use_item"
            browser._message = nil
          end
        elseif kind == "pointer_up" and type(event.x) == "number" and type(event.y) == "number" then
          local px, py = event.x, event.y
          if browser._page == "pocket_menu" then
            local hit = BattleBagPockets.hitIndex(BattleBagPockets.HITBOXES.pocketMenu, px, py)
            if hit ~= nil then
              -- Touch deactivates with ResetPosition (active false,
              -- position 0, prev 0xFF); the hit then resolves like a tap.
              browser._cursorActive = false
              browser._menuFocus = 0
              browser._menuPrev = nil
              if hit >= 0 and hit <= 3 then
                browser._menuFocus = hit
                local pocket = hit
                startPress(pocket, function()
                  enterPocket(pocket)
                end)
              elseif hit == 4 then
                browser:handleTap("last_used")
              elseif hit == 5 then
                browser:handleTap("back")
              end
            end
          elseif browser._page == "item_list" and browser._pocket ~= nil then
            local hit = BattleBagPockets.hitIndex(BattleBagPockets.HITBOXES.itemList, px, py)
            if hit ~= nil then
              browser._cursorActive = false
              browser._cursor = 0
              browser._listPrev = nil
              if hit >= 0 and hit <= 5 then
                browser:handleTap("bag:" .. tostring(hit))
              elseif hit == 6 then
                browser:handleTap("back")
              elseif hit == 7 then
                browser:handleTap("page_prev")
              elseif hit == 8 then
                browser:handleTap("page_next")
              end
            end
          elseif browser._page == "use_item" then
            local hit = BattleBagPockets.hitIndex(BattleBagPockets.HITBOXES.useItem, px, py)
            if hit == 0 or hit == 1 then
              browser._cursorActive = false
              browser._useFocus = "use"
            end
            if hit == 0 then
              browser:handleTap("use")
            elseif hit == 1 then
              browser:handleTap("back")
            end
          elseif browser._page == "message" then
            browser._page = "use_item"
            browser._message = nil
          end
        elseif kind == "pointer_down" or kind == "pointer_cancel" then
          -- Press topology stays with the barrier; release resolves above.
        end
      end
    end
    if browser._tutorial == true then
      stepTutorialFinger()
    end
    if animAtStart then
      advanceAnim()
    end
  end
  ---@param id string stable row/control identity under activation
  function browser:handleTap(id)
    if browser._disposed then
      return
    end
    if browser._page == "pocket_menu" then
      local pocket = tonumber(id:match("^bagpocket:(%d+)$") or "")
      if pocket ~= nil and pocket % 1 == 0 and pocket >= 0 and pocket <= 3 then
        pocket = math.floor(pocket)
        browser._menuFocus = pocket
        startPress(pocket, function()
          enterPocket(pocket)
        end)
        return
      end
      if id == "last_used" then
        -- A disabled shortcut is ignored behind the touch reset
        -- (HandlePocketMenuInput breaks when lastUsedItem is none,
        -- DeactivateCursor already reseated the cursor at 0).
        if browser._lastUsed == nil then
          return
        end
        browser._menuFocus = 4
        local savedPocket = browser._lastUsed.pocket
        startPress(4, function()
          browser._pocket = savedPocket
          browser._page = "item_list"
          clampPage(math.floor(savedPocket))
          local key = BattleBagPockets.POCKET_KEYS[savedPocket + 1]
          for index, entry in ipairs(groups[key]) do
            if entry.item == browser._lastUsed.item then
              browser._pages[savedPocket] = math.floor((index - 1) / 6)
              browser._positions[savedPocket] = (index - 1) % 6
              break
            end
          end
          browser._useCell = browser._positions[savedPocket]
          browser._page = "use_item"
          browser._useFocus = "use"
        end)
        return
      end
      if id == "back" then
        browser._menuFocus = 5
        browser._result = { kind = "closed" }
        return
      end
      return
    end
    if browser._page == "item_list" and browser._pocket ~= nil then
      local pocket = browser._pocket --[[@as integer]]
      local cell = tonumber(id:match("^bag:(%d+)$") or "")
      if cell ~= nil and cell % 1 == 0 and cell >= 0 and cell <= 5 then
        cell = math.floor(cell)
        local key = BattleBagPockets.POCKET_KEYS[pocket + 1]
        local entry = groups[key][browser._pages[pocket] * 6 + cell + 1]
        -- Empty cells are ignored behind the touch reset
        -- (HandleItemListInput breaks when GetItemOnPage is none,
        -- DeactivateCursor already reseated the cursor at 0).
        if entry == nil then
          return
        end
        browser._cursor = cell
        browser._positions[pocket] = cell
        startPress(6 + cell, function()
          browser._useCell = cell
          browser._page = "use_item"
          browser._useFocus = "use"
        end)
        return
      end
      if id == "back" then
        startPress(14, function()
          browser._page = "pocket_menu"
          browser._menuFocus = pocket
          browser._menuPrev = nil
        end)
        return
      end
      if id == "page_prev" or id == "page_next" then
        local count = pageCount(pocket)
        if count > 1 then
          local button = id == "page_prev" and 12 or 13
          startPress(button, function()
            local page = browser._pages[pocket]
            if id == "page_prev" then
              browser._pages[pocket] = (page - 1) % count
            else
              browser._pages[pocket] = (page + 1) % count
            end
            -- Turning the page resets the saved cell
            -- (ChangeItemPage clears pocketPositions); the cursor keeps
            -- its box.
            browser._positions[pocket] = 0
            clampPage(pocket)
          end)
        end
        return
      end
      return
    end
    if browser._page == "use_item" then
      if id == "use" then
        browser._useFocus = "use"
        if browser._pocket ~= nil then
          local key = BattleBagPockets.POCKET_KEYS[browser._pocket + 1]
          local entry = groups[key][browser._pages[browser._pocket] * 6 + (browser._useCell or 0) + 1]
          if entry ~= nil then
            browser._intent = { kind = "battle_select", item = entry.item }
            startPress(15, nil)
          end
        end
        return
      end
      if id == "back" then
        startPress(16, function()
          browser._page = "item_list"
        end)
        return
      end
      return
    end
    if browser._page == "message" then
      if id == "back" or id == "use" then
        browser._page = "use_item"
        browser._message = nil
      end
      return
    end
  end
  ---@return table<string, unknown> drawable battle-bag record (renderer-agnostic data)
  function browser:status()
    if browser._disposed then
      return { open = false }
    end
    local pockets = {}
    for index, key in ipairs(BattleBagPockets.POCKET_KEYS) do
      pockets[index] = { pocket = key }
    end
    local stock = 0
    for _, key in pairs(inventory) do
      if type(key) == "number" then
        stock = stock + 1
      end
    end
    local record = {
      open = true,
      bagPage = browser._page,
      state = browser._page,
      pockets = pockets,
      stock = stock,
      message = browser._message,
      -- The tutorial marker rides the status so the finger projection
      -- and the message-page producer read the same auto-play source.
      tutorial = browser._tutorial == true,
      fingerTicks = browser._fingerTicks,
      -- D-pad cursor visibility (BattleDpadCursor active flag) and the
      -- staged press dip (button + frame) ride the status so paint and
      -- taps resolve through the same focus the browser owns.
      cursorActive = browser._cursorActive == true,
      anim = browser._anim ~= nil and { button = browser._anim.button, frame = browser._anim.phase } or nil,
    } --[[@as table<string, unknown>]]
    if browser._page == "pocket_menu" then
      record.pocket = nil
      record.page = { current = 1, count = 1 }
      record.focusedMenuIndex = browser._menuFocus
      if browser._menuFocus >= 0 and browser._menuFocus <= 3 then
        record.focusedPocket = browser._menuFocus
      end
      record.lastUsed = browser._lastUsed
      return record
    end
    local pocket = assert(browser._pocket, "listing pages carry their pocket") --[[@as integer]]
    local key = BattleBagPockets.POCKET_KEYS[pocket + 1]
    local list = groups[key]
    local count = pageCount(pocket)
    local page = browser._pages[pocket]
    record.pocket = key
    record.pocketIndex = pocket
    record.page = { current = page + 1, count = count }
    if browser._page == "item_list" then
      local cells = {}
      for cell = 0, 5 do
        local entry = list[page * 6 + cell + 1]
        if entry ~= nil then
          local definition = catalog.item(catalog, entry.item)
          cells[cell + 1] = {
            item = entry.item,
            quantity = entry.quantity,
            name = type(definition) == "table" and definition.name or entry.item,
          }
        else
          cells[cell + 1] = { empty = true }
        end
      end
      record.slots = list
      record.visibleSlots = cells
      if browser._cursor == 6 then
        record.focusedVisibleIndex = nil
        record.focus = "cancel"
      else
        record.focusedVisibleIndex = browser._cursor
        record.focus = nil
      end
      return record
    end
    local cell = browser._useCell or 0
    local entry = list[page * 6 + cell + 1]
    if entry ~= nil then
      local definition = catalog.item(catalog, entry.item)
      record.useCell = cell
      record.useItem = {
        item = entry.item,
        quantity = entry.quantity,
        name = type(definition) == "table" and definition.name or entry.item,
        description = type(definition) == "table" and definition.description or nil,
      }
      record.visibleSlots = {
        { item = entry.item, quantity = entry.quantity, name = record.useItem.name },
      }
      record.slots = list
    else
      record.visibleSlots = {}
      record.slots = list
    end
    record.focusedVisibleIndex = cell
    record.useFocus = browser._useFocus or "use"
    if browser._useFocus == "back" then
      record.focus = "cancel"
    end
    return record
  end
  ---@return table<string, unknown>? drained battle selection intent
  function browser:takeIntent()
    local stashed = browser._intent
    browser._intent = nil
    return stashed
  end
  ---@return table<string, unknown>? drained browser close
  function browser:takeResult()
    local stashed = browser._result
    browser._result = nil
    return stashed
  end
  -- Snapshots the retail exit cursor: the current pocket with every
  -- pocket's page and saved cell, plus the d-pad cursor visibility,
  -- for the barrier to store behind a sealed item (BattleBagMenu_Exit
  -- writes cursor state only when an item was chosen).
  ---@return BagBattleCursor battle cursor snapshot with zero-based pocket, pages, and cells
  function browser:cursorSnapshot()
    local pages = {}
    local positions = {}
    for pocket = 0, 3 do
      pages[pocket] = browser._pages[pocket]
      positions[pocket] = browser._positions[pocket]
    end
    return {
      pocket = browser._pocket,
      pages = pages,
      positions = positions,
      cursorActive = browser._cursorActive == true,
    }
  end
  -- Shows the retail TryUseItem refusal on the message page
  -- (ShowMessage, nextState 8): the use-item confirmation keeps its
  -- pocket, focus, and counts while the notice explains the refusal.
  -- Confirm or cancel returns to the use-item page.
  ---@param text string staged refusal text under display
  function browser:showMessage(text)
    assert(type(text) == "string" and text ~= "", "refusals carry their staged text")
    browser._message = text
    browser._page = "message"
  end
  -- Returns the browser to its resting item list after target selection
  -- closes: the use-item confirmation served its staging purpose.
  function browser:backToList()
    if browser._page == "use_item" or browser._page == "message" then
      browser._page = "item_list"
      browser._message = nil
    end
  end
  function browser:dispose()
    browser._disposed = true
    browser._intent = nil
    browser._result = nil
  end
  return browser
end

-- Composes the native Bag application in its battle context over the
-- detached stock. The kernel item policy drives the native refusal path;
-- stock mutation entries refuse loudly. Target selection composes the
-- native Party application in its item-target context on demand: the
-- retained bag browser keeps its pocket, focus, scroll, and counts while
-- the target picker owns input, and cancelling the target disposes only
-- the target picker.
---@param intent table<string, unknown> validated bag intent under composition
---@param services table<string, unknown> borrowed battle services under composition
---@return table<string, unknown>? composed bag child
---@return string? failure cause
local function openBagChild(intent, services)
  assert(type(intent.inventory) == "table", "bag children carry their detached stock")
  assert(type(intent.options) == "table", "bag children carry their decision options")
  local options = intent.options --[[@as table<string, unknown>]]
  local browser, browserErr =
    newBattleBagBrowser(intent.inventory --[[@as table<string, integer>]], services.itemCatalog, intent)
  if browser == nil then
    return nil, tostring(browserErr)
  end
  local controller = browser
  local identity = childIdentity("bag", intent)
  local child = {
    _kind = "bag",
    _identity = identity,
    _application = BattleChildApplications.RECEIPTS.bag,
    _controller = controller,
    _layout = nil,
    _menus = nil,
    _options = options,
    _party = intent.party,
    _target = nil,
    _nativeIntent = nil,
    _nativeResult = nil,
    _inputApplied = false,
    _targetIntent = nil,
    _targetResult = nil,
    _move = nil,
    _moveHolder = nil,
    _taken = false,
    _disposed = false,
  }
  -- Opens native item-target selection for one staged serving: a second
  -- Party application in its item-target context over the detached roster,
  -- gated by the kernel item fragments for the staged key. The retained
  -- bag browser is untouched.
  ---@param itemKey string staged battle item identity under targeting
  function child:openTarget(itemKey)
    assert(type(itemKey) == "string" and itemKey ~= "", "target selection stages its item")
    self:closeTarget()
    local roster = assert(self._party, "target selection reads the detached roster")
    assert(type(roster) == "table", "target selection reads the detached roster")
    local targets = enabledItemTargets(self._options, itemKey)
    local eligible = {}
    for combatant in pairs(targets) do
      eligible[combatant] = true
    end
    local target, targetErr =
      BattleChildApplications.openTargetPicker(roster, eligible, itemKey, services, self._options)
    if target == nil then
      error(targetErr, 0)
    end
    self._target = target
  end
  -- Opens the Restore PP move picker over the chosen holder while the
  -- target list waits on its pending use: the picker owns input until it
  -- closes back into that list.
  ---@param slot integer chosen roster slot under move selection
  function child:openMove(slot)
    assert(self._target ~= nil and self._move == nil, "move selection follows one chosen target")
    local holder = nil
    for _, record in
      ipairs(self._party --[[@as table<integer, table<string, unknown>>]])
    do
      if type(record) == "table" and record.slot == slot then
        holder = record
      end
    end
    assert(type(holder) == "table", "move selection reads the chosen roster record")
    local picker, pickerErr = composeRestorePicker(holder)
    if picker == nil then
      error(pickerErr, 0)
    end
    self._move = picker
    self._moveHolder = holder
  end
  -- Closes the move picker into the waiting target list: a refusal shows
  -- its text over the list, a plain return restores the list silently.
  ---@param refusal string? visible refusal text, nil for a plain return
  function child:closeMove(refusal)
    if self._move == nil then
      return
    end
    self._move:dispose()
    self._move = nil
    self._moveHolder = nil
    local target = assert(self._target, "move selection returns into its target list")
    target:completeAction(refusal ~= nil and { kind = "refused", text = refusal } or { kind = "no_op" })
  end
  -- Drains one native move-picker outcome without sealing.
  ---@return table<string, unknown>? move outcome, nil while the picker stays open
  function child:takeMoveOutcome()
    if self._move == nil then
      return nil
    end
    local result = drainResult(self._move)
    if type(result) == "table" and result.kind == "move_selected" and type(result.moveSlot) == "number" then
      return { kind = "move_selected", moveSlot = result.moveSlot }
    end
    if type(result) == "table" and result.kind == "cancelled" then
      return { kind = "cancelled" }
    end
    return nil
  end
  ---@return table<string, unknown>? native move picker status, nil without its picker
  function child:moveStatus()
    if self._move == nil then
      return nil
    end
    local view = self._move:status()
    view.holderName = self._moveHolder.name
    return view
  end
  -- Disposes only the target picker, keeping the retained bag browser.
  -- A disposed picker owns no input and seals nothing, so its pending
  -- evidence clears with it instead of leaking into the next picker.
  function child:closeTarget()
    if self._move ~= nil then
      self._move:dispose()
      self._move = nil
      self._moveHolder = nil
    end
    if self._target ~= nil then
      self._target:dispose()
      self._target = nil
    end
    self._targetIntent = nil
    self._targetResult = nil
    local bagBrowser = self._controller
    if type(bagBrowser) == "table" and type(bagBrowser.backToList) == "function" then
      bagBrowser:backToList()
    end
  end
  -- Refuses one item-target choice with retail text over the list
  -- (battle_party_menu.c TryUseItemOnMon msg 95): the picker shows
  -- the message and restores its origin instead of sealing.
  ---@param text string visible refusal text under display
  function child:refuseTarget(text)
    assert(type(text) == "string" and text ~= "", "target refusals carry their text")
    local target = assert(self._target, "target refusals keep their picker")
    target:completeAction({ kind = "refused", text = text })
  end
  ---@param events table<integer, table<string, unknown>> semantic input batch under routing
  function child:input(events)
    if self._disposed or self._taken then
      return
    end
    if self._move ~= nil then
      routeSemantic(self._move, expandTaps("move", events))
    elseif self._target ~= nil then
      self._target:updateFixed(expandTaps("target", events, self._target._layout, self._target._menus))
      local targetController = self._target._controller
      self._targetIntent = drainIntent(targetController) or self._targetIntent
      self._targetResult = drainResult(targetController) or self._targetResult
    else
      self._controller:updateFixed(events)
      harvest(self, self._controller)
    end
    self._inputApplied = true
  end
  ---@param _ integer source ticks under stepping
  function child:stepSourceTick(_)
    if self._inputApplied then
      self._inputApplied = false
      return
    end
    if self._move ~= nil then
      return
    end
    if self._target ~= nil then
      local target = assert(self._target, "an active target owns its controller")
      target:updateFixed({})
      local targetController = target._controller
      self._targetIntent = drainIntent(targetController) or self._targetIntent
      self._targetResult = drainResult(targetController) or self._targetResult
      return
    end
    self._controller:updateFixed({})
    harvest(self, self._controller)
  end
  ---@param _ table<string, unknown>? borrowed display facts (the returned record is renderer-agnostic data)
  ---@return table<string, unknown> drawable bag record from the native application
  function child:draw(_)
    local view = self._controller:status()
    assert(type(view) == "table", "the native bag projects its drawable record")
    view.layout = self._layout
    return view
  end
  -- Reports the native application receipt for the overlay currently
  -- owning input: the item-target picker is a Party application, the
  -- resting browser is the Bag application.
  ---@return string native application receipt
  function child:application()
    if self._move ~= nil then
      return BattleChildApplications.RECEIPTS.learn
    end
    if self._target ~= nil then
      return BattleChildApplications.RECEIPTS.party
    end
    return self._application
  end
  ---@return table<string, unknown> child status with its application receipt
  function child:status()
    return {
      active = not self._disposed,
      kind = "bag",
      application = self._application,
      native = self._nativeIntent or self._nativeResult,
    }
  end
  -- Drains one native battle selection intent without sealing: the item
  -- identity and its service revision snapshot for the owning barrier to
  -- translate against the current kernel fragments.
  ---@return table<string, unknown>? battle selection intent, nil when the browser staged nothing
  function child:takeBagIntent()
    harvest(self, self._controller)
    local stashed = self._nativeIntent
    self._nativeIntent = nil
    if type(stashed) == "table" and stashed.kind == "battle_select" and type(stashed.item) == "string" then
      local bagBrowser = self._controller
      if type(bagBrowser) == "table" and type(bagBrowser.cursorSnapshot) == "function" then
        stashed.cursor = bagBrowser:cursorSnapshot()
      end
      return stashed
    end
    return nil
  end
  -- Drains one native browser close without sealing: a closed empty or
  -- cancelled browser reports its navigation cancellation exactly once.  ---@return table<string, unknown>? browser close report, nil while the browser stays open
  function child:takeBagClose()
    harvest(self, self._controller)
    local result = self._nativeResult
    self._nativeResult = nil
    if type(result) == "table" and result.kind == "closed" then
      return { kind = "closed" }
    end
    return nil
  end
  -- Shows the retail TryUseItem refusal on the browser message page:
  -- the barrier resolved the staged text, the browser owns the page.
  ---@param text string staged refusal text under display
  function child:showMessage(text)
    local bagBrowser = assert(self._controller, "refusals keep their browser")
    bagBrowser:showMessage(text)
  end
  -- Drains one native item-target outcome without sealing: a compatible
  -- target reports its slot and item while a cancelled picker reports
  -- its navigation cancellation. Exactly once per native seal.
  ---@return table<string, unknown>? target outcome, nil while the picker stays open
  function child:takeTargetOutcome()
    if self._target == nil then
      return nil
    end
    local stashed = self._targetIntent
    self._targetIntent = nil
    if type(stashed) == "table" and stashed.kind == "use_item" and type(stashed.slot) == "number" then
      return { kind = "use_item", slot = stashed.slot, item = stashed.item }
    end
    local result = self._targetResult
    self._targetResult = nil
    if type(result) == "table" and result.kind == "cancelled" then
      return { kind = "cancelled" }
    end
    return nil
  end
  ---@return table<string, unknown>? native target picker status, nil without its picker
  function child:targetStatus()
    if self._target == nil then
      return nil
    end
    local view = self._target._controller:status()
    view.layout = self._target._layout
    view.targetPromptKey = "useTarget"
    return view
  end
  ---@return table<string, unknown>? bound result, exactly once
  function child:takeResult()
    harvest(self, self._controller)
    local result = self._nativeResult
    if type(result) == "table" and result.kind == "closed" then
      return takeChildResult(self, "cancelled")
    end
    return nil
  end
  function child:dispose()
    if self._disposed then
      return
    end
    self._disposed = true
    -- Disposal discards pending native evidence: a disposed child owns no
    -- input and seals nothing, so stale intents never report afterwards.
    self._nativeIntent = nil
    self._nativeResult = nil
    self:closeTarget()
    self._controller:dispose()
  end
  return child
end

---@param services table<string, unknown> borrowed battle services under composition
---@param key string staged message key under resolution
---@param fallback string current English text while no resolver is borrowed
---@return string resolved retail text or its fallback
local function resolveBattleLabel(services, key, fallback)
  local resolve = type(services) == "table" and services.resolveMessage or nil
  if type(resolve) == "function" then
    return resolve(key, {})
  end
  return fallback
end

-- Resolves one staged battle message with its source substitutions in
-- message order (battle_party_menu.c Buffer* + StringExpandPlaceholders).
-- Unknown resolvers fall back to English so tests without the manifest
-- still prove the refusal path owns a message.
---@param services table<string, unknown> borrowed battle services under resolution
---@param key string staged message key under resolution
---@param fallback string current English text while no resolver is borrowed
---@param subs table<integer, string>? source substitutions in message order
---@return string resolved retail text or its fallback
local function resolveBattleText(services, key, fallback, subs)
  local resolve = type(services) == "table" and services.resolveMessage or nil
  if type(resolve) == "function" then
    return resolve(key, subs or {})
  end
  return fallback
end

-- Composes one native Party target picker in its item-target context over
-- the detached roster. The kernel item fragments for the staged serving
-- own eligibility through the injected action policy; the picker stages
-- value-only intents and never touches live party state.
---@param roster table<integer, table<string, unknown>> detached own-party snapshot under composition
---@param eligible table<integer, boolean> eligible combatants under composition
---@param itemKey string staged battle item identity under composition
---@param services table<string, unknown> borrowed battle services under composition
---@param options table<string, unknown> current battle choice options under composition
---@return table<string, unknown>? composed target picker
---@return string? failure cause
function BattleChildApplications.openTargetPicker(roster, eligible, itemKey, services, options)
  assert(type(roster) == "table", "target pickers read the detached roster")
  assert(type(itemKey) == "string" and itemKey ~= "", "target pickers stage their item")
  local model = battlePartyModel(roster, eligible, false)
  local function evaluateTarget(record, _)
    assert(type(record) == "table", "target evaluation reads its slot record")
    if eligible[record.combatant] == true then
      return { compatible = true }
    end
    local reason = itemTargetReason(options, itemKey, record.combatant)
    if reason == "no_effect" or reason == "invalid_target" then
      return {
        compatible = false,
        note = resolveBattleLabel(services, "battle/narration/item-no-effect", "It won’t do any good to use that!"),
      }
    end
    return { compatible = false, note = "That choice is unavailable." }
  end
  local policy = { evaluateTarget = evaluateTarget }
  local battleMenus = type(services.battleMenus) == "table" and services.battleMenus or nil
  local partyMenus = battleMenus ~= nil and battleMenus.party or nil
  local partyManifest = type(partyMenus) == "table" and partyMenus.manifest or nil
  -- Target selection resolves through the native generated hit
  -- geometry alone: without a staged manifest the picker composes
  -- nothing instead of inventing modal rows production never paints.
  if type(partyManifest) ~= "table" then
    return nil, "target selection needs its native party manifest"
  end
  local okLayout, nativePartyLayout = pcall(PartyScreenLayout.resolve, { manifest = partyManifest, cancellable = true })
  if not okLayout then
    return nil, tostring(nativePartyLayout)
  end
  local function targetLayout()
    return nativePartyLayout
  end
  local ok, controller = pcall(PartyScreenController.new, {
    context = "item_target",
    model = model,
    layout = targetLayout,
    item = { key = itemKey, bagRevision = 1 },
    allowCancel = true,
    actionPolicy = policy,
  })
  if not ok then
    return nil, tostring(controller)
  end
  local picker = { _controller = controller, _disposed = false, _layout = nativePartyLayout, _menus = partyMenus }
  ---@param events table<integer, table<string, unknown>> semantic input batch under routing
  function picker:input(events)
    if not self._disposed then
      routeSemantic(self._controller, events)
    end
  end
  ---@param events table<integer, table<string, unknown>> semantic input batch under stepping
  function picker:updateFixed(events)
    if not self._disposed then
      self._controller:updateFixed(events)
    end
  end
  -- Resolves the pending target use: text shows over the list, anything
  -- else returns to it silently.
  ---@param outcome table<string, unknown> native action outcome under completion
  function picker:completeAction(outcome)
    if not self._disposed then
      self._controller:completeAction(outcome)
    end
  end
  function picker:dispose()
    if not self._disposed then
      self._disposed = true
      self._controller:dispose()
    end
  end
  return picker
end

-- Composes the native Party application in its pick context over the
-- detached roster. Eligibility comes from the authoritative kernel switch
-- fragments; the picker seals value-only selection results and never
-- touches live party state.
---@param intent table<string, unknown> validated party intent under composition
---@param services table<string, unknown> borrowed battle services under composition
---@return table<string, unknown>? composed party child
---@return string? failure cause
local function openPartyChild(intent, services)
  assert(type(intent.options) == "table", "party children carry their decision options")
  assert(type(intent.party) == "table", "party children carry their detached roster")
  local options = intent.options --[[@as table<string, unknown>]]
  local switches = enabledSwitches(options)
  local eligible = {}
  for _, byReplacement in pairs(switches) do
    for combatant in pairs(byReplacement) do
      eligible[combatant] = true
    end
  end
  -- Retail opens the party list even with no enabled reserve (trapped,
  -- all fainted): viewing summary/moves stays available while SHIFT
  -- refuses with its CanSwitch message. Forced replacement still fails
  -- closed without a legal reserve since the battle cannot continue.
  if next(eligible) == nil and intent.purpose == "replacement" then
    return nil, "no eligible reserve answers the request"
  end
  -- Kernel disabled switch reasons by replacement combatant for the
  -- trapped/reserved branches of CanSwitchToSelectedMon. Active,
  -- fainted, and egg refusals derive from the detached roster below.
  local disabledReasons = {}
  if type(options.actors) == "table" then
    for _, actor in ipairs(options.actors) do
      if type(actor) == "table" and type(actor.choices) == "table" then
        for _, choice in ipairs(actor.choices) do
          local fragment = type(choice) == "table" and choice.choice or nil
          local payload = type(fragment) == "table" and fragment.payload or nil
          if
            type(choice) == "table"
            and choice.enabled ~= true
            and type(fragment) == "table"
            and fragment.kind == "switch"
            and type(payload) == "table"
            and type(payload.replacement) == "number"
            and type(choice.reason) == "string"
          then
            disabledReasons[payload.replacement] = choice.reason
          end
        end
      end
    end
  end
  local actorCombatant = nil
  if type(options.actors) == "table" and type(options.actors[1]) == "table" then
    local actor = options.actors[1]
    if type(actor.combatant) == "number" then
      actorCombatant = actor.combatant
    end
  end
  local activeName = nil
  for _, record in
    ipairs(intent.party --[[@as table<integer, table<string, unknown>>]])
  do
    if type(record) == "table" and type(record.name) == "string" and record.name ~= "" then
      if record.active == true or record.combatant == actorCombatant then
        activeName = record.name
        break
      end
    end
  end
  if activeName == nil then
    for _, record in
      ipairs(intent.party --[[@as table<integer, table<string, unknown>>]])
    do
      if
        type(record) == "table"
        and record.combatant == actorCombatant
        and type(record.name) == "string"
        and record.name ~= ""
      then
        activeName = record.name
        break
      end
    end
  end
  local model = battlePartyModel(intent.party --[[@as table<integer, table<string, unknown>>]], eligible, true)
  local battleMenus = type(services.battleMenus) == "table" and services.battleMenus or nil
  local partyMenus = battleMenus ~= nil and battleMenus.party or nil
  local partyManifest = type(partyMenus) == "table" and partyMenus.manifest or nil
  -- Party selection resolves through the native generated hit geometry
  -- alone: without a staged manifest the picker composes nothing
  -- instead of inventing modal rows production never paints. The
  -- failure surfaces through the barrier as a visible refusal.
  if type(partyManifest) ~= "table" then
    return nil, "party selection needs its native party manifest"
  end
  local okLayout, nativePartyLayout =
    pcall(PartyScreenLayout.resolve, { manifest = partyManifest, cancellable = intent.cancellable == true })
  if not okLayout then
    return nil, tostring(nativePartyLayout)
  end
  local function pickLayout()
    return nativePartyLayout
  end
  local initialFocus = nil
  -- Mandatory replacement and the optional Shift offer both open on
  -- the first kernel-eligible reserve: confirming the focused row then
  -- names an authoritative switch fragment instead of a stale slot.
  if intent.purpose == "replacement" or intent.purpose == "shift" then
    for slot = 0, 5 do
      for _, record in
        ipairs(intent.party --[[@as table<integer, table<string, unknown>>]])
      do
        if record.slot == slot and eligible[record.combatant] == true then
          initialFocus = slot
          break
        end
      end
      if initialFocus ~= nil then
        break
      end
    end
    if intent.purpose == "replacement" then
      assert(initialFocus ~= nil, "reserve pickers focus an eligible reserve")
    end
  end
  -- Retail battle party mon menu (battle_party_menu.c PrintMonMenuPage
  -- with msg_0006_00015 SHIFT): selecting the mon offers SHIFT to switch,
  -- SUMMARY (00018) and CHECK MOVES (00019) for non-eggs (eggs hide the
  -- latter two, matching IsSelectedMonEgg guards), and cancelling
  -- returns to the list. Labels resolve through the borrowed staged
  -- messages when the barrier lends them.
  local function menuFor(slotFacts)
    local entries = {
      { kind = "switch", label = resolveBattleLabel(services, "battle/party/button/shift", "SHIFT") },
    }
    if type(slotFacts) ~= "table" or slotFacts.isEgg ~= true then
      entries[#entries + 1] =
        { kind = "summary", label = resolveBattleLabel(services, "battle/party/button/summary", "SUMMARY") }
      entries[#entries + 1] = {
        kind = "check_moves",
        label = resolveBattleLabel(services, "battle/party/button/check-moves", "CHECK MOVES"),
      }
    end
    entries[#entries + 1] =
      { kind = "quit", label = resolveBattleLabel(services, "battle/party/button/cancel", "CANCEL") }
    return entries
  end
  local function submenuFor(_, kind)
    error("battle party selection has no " .. tostring(kind) .. " submenu", 2)
  end
  -- Retail CanSwitchToSelectedMon order (battle_party_menu.c): partner,
  -- fainted (77), active (76), egg (79), reserved (93), trapped (78).
  -- Partner needs multi-battle position data the intent does not carry,
  -- so singles resolve the other five here with staged msg 0006 text.
  ---@param slot integer roster slot under refusal lookup
  ---@return string? refusal text, nil while the slot can switch
  local function switchRefusalText(slot)
    local target = nil
    for _, record in
      ipairs(intent.party --[[@as table<integer, table<string, unknown>>]])
    do
      if type(record) == "table" and record.slot == slot then
        target = record
        break
      end
    end
    if type(target) ~= "table" or type(target.combatant) ~= "number" then
      return nil
    end
    local name = type(target.name) == "string" and target.name ~= "" and target.name or "Unknown"
    -- Retail roster checks precede kernel eligibility in CanSwitch
    -- order: fainted (77), active (76), and egg (79) refuse even if a
    -- stale projection still marks the slot eligible.
    if (tonumber(target.hp) or 0) <= 0 then
      return resolveBattleText(
        services,
        "battle/party/message/no-energy",
        name .. " has no energy\nleft to battle!",
        { name }
      )
    end
    if target.active == true or target.combatant == actorCombatant then
      return resolveBattleText(
        services,
        "battle/party/message/already-in-battle",
        name .. " is already\nin battle!",
        { name }
      )
    end
    if target.isEgg == true then
      return resolveBattleText(services, "battle/party/message/egg", "An Egg can’t battle!", {})
    end
    if eligible[target.combatant] == true then
      return nil
    end
    local kernelReason = disabledReasons[target.combatant]
    if kernelReason == "reserved" then
      return resolveBattleText(
        services,
        "battle/party/message/already-selected",
        name .. " has already been\nselected.",
        { name }
      )
    end
    if kernelReason == "trapped" then
      local holder = activeName or name
      return resolveBattleText(
        services,
        "battle/party/message/cant-switch-out",
        holder .. " can’t be switched\nout!",
        { holder }
      )
    end
    if kernelReason == "fainted" then
      return resolveBattleText(
        services,
        "battle/party/message/no-energy",
        name .. " has no energy\nleft to battle!",
        { name }
      )
    end
    return resolveBattleText(services, "battle/party/message/no-effect", "That choice is unavailable.", {})
  end
  local ok, controller = pcall(PartyScreenController.new, {
    context = "battle_pick",
    model = model,
    layout = pickLayout,
    initialFocus = initialFocus,
    actionPolicy = { menuFor = menuFor, submenuFor = submenuFor, switchRefusalText = switchRefusalText },
    allowCancel = intent.cancellable == true,
  })
  if not ok then
    return nil, tostring(controller)
  end
  local identity = childIdentity("party", intent)
  -- Battle manifest party section behind the transcribed wrapper
  -- input geometry (hitboxes, cursor boxes); staged tables win while
  -- present, the pinned decomp transcriptions otherwise.
  local partySection = type(services.partySection) == "table" and services.partySection or nil
  local child = {
    _kind = "party",
    _identity = identity,
    _application = BattleChildApplications.RECEIPTS.party,
    _controller = controller,
    _layout = nativePartyLayout,
    _menus = partyMenus,
    _options = options,
    _partySection = partySection,
    _nativeIntent = nil,
    _nativeResult = nil,
    _inputApplied = false,
    _taken = false,
    _disposed = false,
    _page = nil,
    _pageSlot = nil,
    _selectedMove = 0,
    _acceptSeq = 0,
    _cursor = 0,
    _cursorActive = false,
    _prevCursor = nil,
    _press = nil,
  }
  -- Retail battle summary/move pages (battle_party_menu.c pages 2-4)
  -- over the detached roster: touch resolves through the transcribed
  -- hitboxes (CheckTouchHitbox order), the d-pad through the transcribed
  -- cursor boxes (BattleDpadCursor_HandleInput with its activation gate
  -- and return links), and every accepted press dips its button behind
  -- a gated press (WaitButtonAnim) before the transition applies. Pages
  -- never seal; only the list SHIFT seals its kernel fragment.
  ---@param slot integer roster slot under lookup
  ---@return table<string, unknown>? detached roster record
  local function rosterRecord(slot)
    for _, record in
      ipairs(intent.party --[[@as table<integer, table<string, unknown>>]])
    do
      if type(record) == "table" and record.slot == slot then
        return record
      end
    end
    return nil
  end
  ---@return table<integer, integer> occupied non-egg roster slots in ascending order
  local function occupiedSlots()
    local found = {}
    for _, record in
      ipairs(intent.party --[[@as table<integer, table<string, unknown>>]])
    do
      -- Retail FindNextMon skips eggs and empty slots when paging
      -- summary and check-moves: only occupied non-egg slots participate.
      if type(record) == "table" and type(record.slot) == "number" and record.isEgg ~= true then
        found[#found + 1] = record.slot
      end
    end
    table.sort(found)
    return found
  end
  ---@param slot integer displayed roster slot under stepping
  ---@param delta integer step direction under stepping
  ---@return integer neighboring occupied slot, staying put without one
  local function neighborSlot(slot, delta)
    local slots = occupiedSlots()
    local at = nil
    for index, candidate in ipairs(slots) do
      if candidate == slot then
        at = index
        break
      end
    end
    if at == nil then
      return slot
    end
    if #slots <= 1 then
      return slot
    end
    -- Retail wraps past the ends instead of clamping, returning 0xFF
    -- (stay) only when no other eligible mon exists.
    local step = delta < 0 and -1 or 1
    local nextIndex = ((at - 1 + step) % #slots) + 1
    return slots[nextIndex]
  end
  ---@param moveSlot integer held move slot under occupancy lookup
  ---@return boolean occupied true while the slot carries a known move
  local function moveOccupied(moveSlot)
    local record = rosterRecord(assert(child._pageSlot, "move pages name their mon"))
    local entry = type(record) == "table" and type(record.moves) == "table" and record.moves[moveSlot + 1] or nil
    -- Retail ignores empty move slots (MOVE_NONE breaks the tap).
    return type(entry) == "table" and (entry.move ~= nil or entry.key ~= nil)
  end
  ---@param apply fun() deferred page transition behind the press dip
  ---@param button integer decomp input index behind the button animation
  ---@return nil
  local function stagePress(apply, button)
    -- The staged button and its phase while the press dip shows
    -- (PRESS, HOLD, RELEASE like ButtonAnimState, then the release
    -- observation); edges in between are dropped and the deferred
    -- transition applies once the release is observed, matching
    -- WaitButtonAnim. Every staged press is an accepted input behind
    -- the barrier DECIDE beat.
    child._acceptSeq = child._acceptSeq + 1
    child._press = { button = button, phase = 1, apply = apply }
  end
  ---@param slot integer roster slot behind the summary page
  ---@return nil
  local function openSummary(slot)
    assert(rosterRecord(slot) ~= nil, "summary pages name an occupied slot")
    child._page = "summary"
    child._pageSlot = slot
    -- SetPageCursor seats no summary position (SetBoxes resets to 0);
    -- the cursor-active flag rides across pages untouched.
    child._cursor = BattlePartyPages.initialCursor("summary", child._selectedMove)
    child._prevCursor = nil
    child._press = nil
  end
  ---@param slot integer roster slot behind the move list
  ---@return nil
  local function openMoves(slot)
    assert(rosterRecord(slot) ~= nil, "move pages name an occupied slot")
    child._page = "moves"
    child._pageSlot = slot
    child._cursor = BattlePartyPages.initialCursor("moves", child._selectedMove)
    child._prevCursor = nil
    child._press = nil
  end
  ---@param slot integer roster slot behind move detail
  ---@param moveSlot integer selected move slot behind move detail
  ---@return nil
  local function openDetail(slot, moveSlot)
    assert(rosterRecord(slot) ~= nil, "move detail names its mon")
    child._page = "move_detail"
    child._pageSlot = slot
    child._selectedMove = moveSlot
    child._cursor = BattlePartyPages.initialCursor("move_detail", child._selectedMove)
    child._prevCursor = nil
    child._press = nil
  end
  ---@return nil
  local function closePage()
    -- CLOSE_MESSAGE returns to the mon menu with the menu retained:
    -- the controller keeps its focused entry, so no cursor is reseated
    -- here (retail only records monMenuPosition for its own cursor).
    child._page = nil
    child._pageSlot = nil
    child._press = nil
  end
  -- Drains one navigation intent from the native mon menu: SUMMARY and
  -- CHECK MOVES open their wrapper page while the controller returns
  -- to its menu; anything else stays stashed for the barrier.
  local function drainPageIntent()
    local stashed = child._nativeIntent
    if type(stashed) ~= "table" then
      return
    end
    if stashed.kind == "summary" and type(stashed.slot) == "number" then
      child._nativeIntent = nil
      child._controller:completeAction({ kind = "no_op" })
      openSummary(stashed.slot)
    elseif stashed.kind == "check_moves" and type(stashed.slot) == "number" then
      child._nativeIntent = nil
      child._controller:completeAction({ kind = "no_op" })
      openMoves(stashed.slot)
    end
  end
  -- Handles one decomp input index on the open wrapper page behind
  -- the press dip: paging wraps past the ends, empty move slots stay,
  -- and cancel returns to the mon menu while the controller keeps its
  -- focused entry. Anything unhandled stays without sealing.
  ---@param input integer decomp input index in Handle order
  ---@return nil
  local function handleWrapperInput(input)
    local page = child._page
    if page == "summary" then
      local slot = assert(child._pageSlot, "summary pages name their mon")
      if input == 0 then
        local next = neighborSlot(slot, -1)
        if next ~= slot then
          local target = next
          stagePress(function()
            child._pageSlot = target
          end, input)
        end
      elseif input == 1 then
        local next = neighborSlot(slot, 1)
        if next ~= slot then
          local target = next
          stagePress(function()
            child._pageSlot = target
          end, input)
        end
      elseif input == 2 then
        local target = slot
        stagePress(function()
          openMoves(target)
        end, input)
      elseif input == 3 then
        stagePress(closePage, input)
      end
      return
    end
    if page == "moves" then
      local slot = assert(child._pageSlot, "move pages name their mon")
      if input >= 0 and input <= 3 then
        if moveOccupied(input) then
          local moveSlot = input
          stagePress(function()
            openDetail(slot, moveSlot)
          end, input)
        end
        return
      end
      if input == 4 then
        local next = neighborSlot(slot, -1)
        if next ~= slot then
          local target = next
          stagePress(function()
            child._pageSlot = target
          end, input)
        end
      elseif input == 5 then
        local next = neighborSlot(slot, 1)
        if next ~= slot then
          local target = next
          stagePress(function()
            child._pageSlot = target
          end, input)
        end
      elseif input == 6 then
        local target = slot
        stagePress(function()
          openSummary(target)
        end, input)
      elseif input == 7 then
        stagePress(closePage, input)
      end
      return
    end
    if page == "move_detail" then
      local slot = assert(child._pageSlot, "move detail names its mon")
      if input >= 0 and input <= 3 then
        -- Reselecting the shown tab re-shows its detail immediately:
        -- the decomp plays DECIDE but stages no button animation for
        -- tab switches, returning straight to SHOW_MOVE_DETAIL. An
        -- empty tab breaks unless it is already selected.
        if input == child._selectedMove or moveOccupied(input) then
          child._acceptSeq = child._acceptSeq + 1
          openDetail(slot, input)
        end
        return
      end
      if input == 4 then
        local target = slot
        stagePress(function()
          openMoves(target)
        end, input)
      end
      return
    end
  end
  ---@param id string stable page control identity under activation
  ---@return integer? decomp input index in Handle order, nil for foreign identities
  local function wrapperInputForId(id)
    local page = child._page
    if type(page) ~= "string" or (page ~= "summary" and page ~= "moves" and page ~= "move_detail") then
      return nil
    end
    for index, known in ipairs(BattlePartyPages.inputIds(page)) do
      if known == id then
        return index - 1
      end
    end
    return nil
  end
  ---@param id string stable page control identity under activation
  ---@return nil
  local function pageTap(id)
    if child._press ~= nil then
      return
    end
    local input = wrapperInputForId(id)
    if input == nil then
      return
    end
    -- Touch deactivates the d-pad cursor and resets its position
    -- (DeactivateCursor); the transition reseats it behind
    -- SetPageCursor while paging refresh keeps the reset.
    child._cursorActive = false
    child._cursor = 0
    child._prevCursor = nil
    handleWrapperInput(input)
  end
  ---@param events table<integer, table<string, unknown>> semantic input batch under page routing
  ---@return nil
  local function pageInput(events)
    for _, event in ipairs(events) do
      if type(event) ~= "table" or type(event.type) ~= "string" then
        break
      end
      -- The press dip gates input like WaitButtonAnim: edges in
      -- between are dropped, never queued.
      if child._press ~= nil then
        break
      end
      local page = child._page
      if type(page) ~= "string" or (page ~= "summary" and page ~= "moves" and page ~= "move_detail") then
        break
      end
      if event.type == "tap" and type(event.id) == "string" then
        pageTap(event.id)
      elseif event.type == "navigate" and type(event.direction) == "string" then
        -- The first key press only activates the cursor (TryActivate);
        -- motion, A, and B run once it is active.
        if child._cursorActive ~= true then
          child._cursorActive = true
        else
          local step =
            BattlePartyPages.stepCursor(page, partySection, child._cursor, child._prevCursor, event.direction)
          child._cursor = step.pos
          child._prevCursor = step.prev
        end
      elseif event.type == "confirm" then
        if child._cursorActive ~= true then
          child._cursorActive = true
        else
          handleWrapperInput(child._cursor)
        end
      elseif event.type == "cancel" then
        -- B answers the page cancel button and voices its DECIDE, but
        -- the first press only activates the cursor like every other
        -- edge (TryActivate consumes it); the cursor stays as the next
        -- opening reseats it.
        if child._cursorActive ~= true then
          child._cursorActive = true
        else
          handleWrapperInput(BattlePartyPages.cancelInput(page))
        end
      end
    end
  end
  ---@param events table<integer, table<string, unknown>> semantic input batch under routing
  function child:input(events)
    if self._disposed or self._taken then
      return
    end
    if self._page ~= nil then
      pageInput(events)
      self._inputApplied = true
      return
    end
    self._controller:updateFixed(expandTaps("party", monMenuTaps(self, events), self._layout, self._menus))
    harvest(self, self._controller)
    drainPageIntent()
    self._inputApplied = true
  end
  ---@param _ integer source ticks under stepping
  function child:stepSourceTick(_)
    local press = self._press
    if press ~= nil then
      -- The press dip advances PRESS, HOLD, RELEASE like
      -- UpdateButtonAnim; the deferred transition applies once the
      -- release is observed while input stays gated. A press staged
      -- by this tick's input paints its first frame before advancing.
      if self._inputApplied and press.phase == 1 then
        self._inputApplied = false
        return
      end
      if press.phase < 3 then
        press.phase = press.phase + 1
      else
        self._press = nil
        press.apply()
      end
      self._inputApplied = false
      return
    end
    if self._inputApplied then
      self._inputApplied = false
      return
    end
    if self._page ~= nil then
      return
    end
    self._controller:updateFixed({})
    harvest(self, self._controller)
    drainPageIntent()
  end
  ---@param _ table<string, unknown>? borrowed display facts (the returned record is renderer-agnostic data)
  ---@return table<string, unknown> drawable party record from the native application
  function child:draw(_)
    local view = self._controller:status()
    assert(type(view) == "table", "the native party projects its drawable record")
    local nativeView = copyValue(view) --[[@as table<string, unknown>]]
    nativeView.layout = self._layout
    if self._page ~= nil then
      nativeView.page = self._page
      nativeView.pageSlot = self._pageSlot
      nativeView.pageMove = self._selectedMove
      -- Stable focus identity behind the numeric cursor plus the raw
      -- cursor state the barrier voices and paint resolve through.
      local ids = BattlePartyPages.inputIds(self._page)
      nativeView.pageFocus = ids[self._cursor + 1]
      nativeView.pageCursor = self._cursor
      nativeView.cursorActive = self._cursorActive
      if self._press ~= nil then
        nativeView.pagePress = { button = self._press.button, phase = self._press.phase }
      end
      nativeView.pageAccept = self._acceptSeq
    else
      -- The native mon-menu press stamps the barrier DECIDE beat like
      -- the decomp Handle call sites: the first draw the press arms
      -- bumps the sequence, and the release draw clears it silently.
      if view.menuPress ~= nil then
        if self._menuPressArmed ~= true then
          self._menuPressArmed = true
          self._acceptSeq = self._acceptSeq + 1
        end
      else
        self._menuPressArmed = nil
      end
      nativeView.menuAccept = self._acceptSeq
    end
    return nativeView
  end
  ---@return string native application receipt
  function child:application()
    return self._application
  end
  ---@return table<string, unknown> child status with its application receipt
  function child:status()
    return {
      active = not self._disposed,
      kind = "party",
      application = self._application,
      native = self._nativeIntent or self._nativeResult,
    }
  end
  -- Translates one native selection result into the authoritative switch
  -- fragment it names. Stale slots (no kernel fragment) translate to nil
  -- so no invented reply can seal.
  ---@param slot integer native roster slot under translation
  ---@return table<string, unknown>? authoritative switch fragment, nil when stale
  function child:translateSelection(slot)
    local roster = intent.party --[[@as table<integer, table<string, unknown>>]]
    local combatant = nil
    for _, record in ipairs(roster) do
      if type(record) == "table" and record.slot == slot and type(record.combatant) == "number" then
        combatant = record.combatant
        break
      end
    end
    if combatant == nil then
      return nil
    end
    local actors = options.actors --[[@as table<integer, table<string, unknown>>?]]
    if type(actors) ~= "table" then
      return nil
    end
    for _, actor in ipairs(actors) do
      if type(actor) == "table" and type(actor.choices) == "table" then
        for _, choice in ipairs(actor.choices) do
          if
            type(choice) == "table"
            and choice.enabled == true
            and type(choice.choice) == "table"
            and choice.choice.kind == "switch"
            and type(choice.choice.payload) == "table"
            and choice.choice.payload.replacement == combatant
          then
            return choice.choice --[[@as table<string, unknown>]]
          end
        end
      end
    end
    return nil
  end
  ---@return table<string, unknown>? bound result, exactly once
  function child:takeResult()
    if self._page ~= nil then
      harvest(self, self._controller)
      return nil
    end
    harvest(self, self._controller)
    local result = self._nativeResult
    if type(result) ~= "table" then
      return nil
    end
    if result.kind == "selected" and type(result.slot) == "number" then
      local fragment = self:translateSelection(result.slot)
      if fragment ~= nil then
        return takeChildResult(self, "choice", fragment)
      end
      return nil
    end
    if result.kind == "cancelled" or (result.kind == "closed" and intent.cancellable == true) then
      return takeChildResult(self, "cancelled")
    end
    return nil
  end
  function child:dispose()
    if self._disposed then
      return
    end
    self._disposed = true
    -- Disposal discards pending native evidence: a disposed child owns no
    -- input and seals nothing, so stale intents never report afterwards.
    self._nativeIntent = nil
    self._nativeResult = nil
    self._controller:dispose()
  end
  return child
end

-- Composes the native summary/move-selection presentation in move-pick
-- mode over the staged learning prompt. The facts model projects the same
-- held-move facts the presentation navigates; move_pick mode never
-- reorders, so the held set cannot mutate through selection. Held-move
-- detail facts stay readable through moveFacts for the barrier view.
-- Composes the native summary/move-selection presentation in move-pick
-- mode over one staged learning prompt. The facts model projects the
-- same held-move facts the presentation navigates; move_pick mode never
-- reorders, so the held set cannot mutate through selection. Shared by
-- the battle-action learning child and the post-battle evolution child,
-- which carries no kernel fragments and answers its own domain instead.
---@param prompt table<string, unknown> staged learning prompt under composition
---@param services table<string, unknown>? borrowed battle services for catalog PP facts
---@return table<string, unknown>? composed move picker
---@return string? failure cause
local function composeLearnPicker(prompt, services)
  assert(type(prompt) == "table", "learning pickers carry their staged prompt")
  local model, rows = battleSummaryModel(prompt)
  -- Retail learn rows print PP like the move list (PrintMoveListPP):
  -- resolve each held max from the mon catalog base PP and PP Ups,
  -- falling back to current PP without a catalog.
  local catalog = type(services) == "table" and services.monCatalog or nil
  if type(rows) == "table" then
    for _, row in ipairs(rows) do
      if type(row) == "table" and type(row.maxPp) ~= "number" then
        local max = tonumber(row.pp) or 0
        if type(catalog) == "table" then
          local lookup = catalog.move --[[@as fun(self: table<string, unknown>, key: string): table<string, unknown>?]]
          if type(lookup) == "function" and type(row.move) == "string" then
            local ok, facts = pcall(lookup, catalog, row.move)
            if ok and type(facts) == "table" and type(facts.basePp) == "number" then
              local ups = tonumber(row.ppUps) or 0
              max = facts.basePp + math.floor(facts.basePp * ups / 5)
            end
          end
        end
        row.maxPp = max
      end
    end
  end
  local function summaryLayout()
    return { hitTest = battleLearnHit }
  end
  -- Retail forget guards (battle_party_menu.c IsSelectedMoveHM): HM
  -- moves cannot be forgotten. The picker refuses these rows with its
  -- protected notice instead of sealing, matching the native message
  -- and stay-on-list behavior.
  local protected = nil
  local moves = prompt.currentMoves
  if type(moves) == "table" then
    for index = 1, 4 do
      local entry = moves[index]
      local key = type(entry) == "table" and entry.move or nil
      if type(key) == "string" and BattleChildApplications.HM_MOVES[key] == true then
        if protected == nil then
          protected = {}
        end
        protected[index] = "hm"
      end
    end
  end
  local ok, controller = pcall(SummaryController.new, {
    mode = "move_pick",
    model = model,
    resolveLayout = summaryLayout,
    -- Move-pick mode never reorders and samples no live navigation: both
    -- collaborators stay explicitly absent, which the controller asserts.
    reorderMoves = nil,
    readNavigation = nil,
    -- Battle learning borrows the picker's fifth keep-moves row through
    -- the machine replacement context: the native row cancels instead of
    -- sealing, and the barrier interprets that cancel as decline intent
    -- while every other cancel stays a stop question. Held rows seal
    -- their move selection natively exactly like the machine flow.
    request = {
      kind = "learn",
      context = "replace_machine",
      prospectiveMove = prompt.incomingMove,
      incomingMove = prompt.incomingMove,
      protected = protected,
    },
  })
  if not ok then
    return nil, tostring(controller)
  end
  return controller
end

-- Drains one native move-picker outcome without sealing: a selected
-- row reports its move slot while a cancelled picker reports the
-- focused row it cancelled from. Exactly once per native seal.
---@param result table<string, unknown>? drained native picker result under parsing
---@param lastFocus integer focused move slot before the draining batch
---@return table<string, unknown>? picker outcome, nil while the picker stays open
local function parsePickerOutcome(result, lastFocus)
  if type(result) ~= "table" then
    return nil
  end
  if result.kind == "move_selected" and type(result.moveSlot) == "number" then
    return { kind = "move_selected", moveSlot = result.moveSlot, focus = result.moveSlot }
  end
  if result.kind == "cancelled" then
    return { kind = "cancelled", focus = lastFocus }
  end
  return nil
end

---@param intent table<string, unknown> validated learning intent under composition
---@param services table<string, unknown> borrowed battle services under composition
---@return table<string, unknown>? composed learning child
---@return string? failure cause
local function openLearnChild(intent, services)
  local request = assert(intent.request, "learning children carry their staged prompt")
  assert(type(request) == "table", "learning children carry their staged prompt")
  assert(type(intent.options) == "table", "learning children carry their decision options")
  local _, rows = battleSummaryModel(request --[[@as table<string, unknown>]])
  local _ = services
  local controller, controllerErr = composeLearnPicker(request --[[@as table<string, unknown>]], services)
  if controller == nil then
    return nil, controllerErr
  end
  local identity = childIdentity("learn", intent)
  local options = intent.options --[[@as table<string, unknown>]]
  local child = {
    _kind = "learn",
    _identity = identity,
    _application = BattleChildApplications.RECEIPTS.learn,
    _controller = controller,
    _facts = rows,
    _options = options,
    _nativeIntent = nil,
    _nativeResult = nil,
    _lastFocus = 0,
    _taken = false,
    _disposed = false,
  }
  ---@return table<integer, table<string, unknown>> held-move detail facts in slot order
  function child:moveFacts()
    return copyValue(self._facts)
  end
  ---@param events table<integer, table<string, unknown>> semantic input batch under routing
  function child:input(events)
    if self._disposed or self._taken then
      return
    end
    -- Snapshot the picker focus before the batch runs: a terminal cancel
    -- closes the controller, so the barrier interprets that cancel
    -- against the row the picker showed when the batch arrived.
    local before = self._controller:status()
    if type(before) == "table" and before.open ~= false then
      self._lastFocus = before.moveSlot
    end
    routeSemantic(self._controller, expandTaps("learn", events))
    harvest(self, self._controller)
  end
  -- Drains one native move-picker outcome without sealing: a selected
  -- row reports its move slot while a cancelled picker reports the
  -- focused row it cancelled from. Exactly once per native seal.
  ---@return table<string, unknown>? picker outcome, nil while the picker stays open
  function child:takeLearnOutcome()
    harvest(self, self._controller)
    local result = self._nativeResult
    self._nativeResult = nil
    return parsePickerOutcome(result, self._lastFocus)
  end
  ---@param _ integer source ticks under stepping (event-stepped controllers keep no clock)
  function child:stepSourceTick(_) end
  ---@param _ table<string, unknown>? borrowed display facts (the returned record is renderer-agnostic data)
  ---@return table<string, unknown> drawable summary record from the native presentation
  function child:draw(_)
    local view = self._controller:status()
    assert(type(view) == "table", "the native summary projects its drawable record")
    return view
  end
  ---@return string native application receipt
  function child:application()
    return self._application
  end
  ---@return table<string, unknown> child status with its application receipt
  function child:status()
    return {
      active = not self._disposed,
      kind = "learn",
      application = self._application,
      native = self._nativeIntent or self._nativeResult,
    }
  end
  -- Translates one native move selection into the authoritative learning
  -- fragment it names: held slots bind their replace identity, the
  -- decline row binds its decline identity. Anything else translates to
  -- nil so no invented reply can seal.
  ---@param moveSlot integer native move slot under translation (0..3 held, 4 decline)
  ---@return table<string, unknown>? authoritative learning fragment, nil when stale
  function child:translateSelection(moveSlot)
    if type(moveSlot) ~= "number" or moveSlot % 1 ~= 0 then
      return nil
    end
    if moveSlot >= 0 and moveSlot <= 3 then
      return learnFragment(self._options, "learn:replace:" .. tostring(moveSlot))
    end
    if moveSlot == 4 then
      return learnFragment(self._options, "learn:decline")
    end
    return nil
  end
  ---@return table<string, unknown>? bound result, exactly once
  function child:takeResult()
    harvest(self, self._controller)
    local result = self._nativeResult
    if type(result) ~= "table" then
      return nil
    end
    if result.kind == "move_selected" and type(result.moveSlot) == "number" then
      local fragment = self:translateSelection(result.moveSlot)
      if fragment ~= nil then
        return takeChildResult(self, "choice", fragment)
      end
      return nil
    end
    if result.kind == "cancelled" then
      return takeChildResult(self, "cancelled")
    end
    return nil
  end
  function child:dispose()
    if self._disposed then
      return
    end
    self._disposed = true
    -- Disposal discards pending native evidence: a disposed child owns no
    -- input and seals nothing, so stale intents never report afterwards.
    self._nativeIntent = nil
    self._nativeResult = nil
    self._controller:dispose()
  end
  return child
end

-- Composes the existing naming screen for a captured subject. The subject
-- is the authoritative battle capture record the completion caller stages:
-- without it the real controller cannot name a species and the child
-- fails its boundary instead of inventing one. Text starts from the empty
-- default; the sealed text reports through takeResult exactly once.
---@param intent table<string, unknown> validated naming intent under composition
---@param services table<string, unknown> borrowed battle services under composition
---@return table<string, unknown>? composed naming child
---@return string? failure cause
local function openNamingChild(intent, services)
  local subject = intent.subject
  if type(subject) ~= "table" then
    return nil, "capture naming carries its committed subject"
  end
  if type(subject.species) ~= "number" or subject.species % 1 ~= 0 or subject.species <= 0 then
    return nil, "capture naming subjects name their species"
  end
  local charmap = services.charmap
  if charmap == nil then
    charmap = defaultCharmap()
  end
  assert(type(charmap) == "table", "capture naming maps its keyboard glyphs")
  local effect = services.effect
  if effect == nil then
    effect = silentNamingEffect
  end
  local namingSubject = { kind = "pokemon", species = subject.species }
  if subject.form ~= nil then
    namingSubject.form = subject.form
  end
  local ok, controller = pcall(NamingScreenController.new, {
    kind = "pokemon",
    maxLength = 10,
    initialText = "",
    charmap = charmap,
    subject = namingSubject,
    effect = effect,
  })
  if not ok then
    return nil, tostring(controller)
  end
  local identity = childIdentity("naming", intent)
  local child = {
    _kind = "naming",
    _identity = identity,
    _application = BattleChildApplications.RECEIPTS.naming,
    _controller = controller,
    _cancellable = intent.cancellable == true,
    _concluded = false,
    _disposed = false,
  }
  -- Routes one semantic edge batch to the native naming controller. Text
  -- and keyboard-cell edges travel beside navigation, confirmation, and
  -- cancellation; pointer press topology stays with the barrier.
  ---@param events table<integer, table<string, unknown>> semantic input batch under routing
  function child:input(events)
    if self._disposed or self._concluded then
      return
    end
    for _, event in ipairs(events) do
      if self._concluded then
        break
      end
      if type(event) ~= "table" or type(event.type) ~= "string" then
        break
      end
      if
        event.type == "navigate"
        or event.type == "confirm"
        or event.type == "cancel"
        or event.type == "text"
        or event.type == "name_cell"
        or event.type == "name_control"
        or event.type == "pointer_cancel"
      then
        if event.type == "cancel" and self._cancellable then
          self._concluded = "cancelled"
        else
          self._controller:applyEvent(event)
        end
      end
    end
  end
  ---@param tick integer source tick under stepping (advances the naming presentation clocks)
  function child:stepSourceTick(tick)
    if not self._disposed then
      self._controller:updateFixed(tick or 1)
    end
  end
  ---@param _ table<string, unknown>? borrowed display facts (the returned record is renderer-agnostic data)
  ---@return table<string, unknown> drawable naming record from the native screen
  function child:draw(_)
    local view = self._controller:snapshot()
    assert(type(view) == "table", "the native naming screen projects its drawable record")
    return view
  end
  ---@return string native application receipt
  function child:application()
    return self._application
  end
  ---@return table<string, unknown> child status with its application receipt
  function child:status()
    return {
      active = not self._disposed,
      kind = "naming",
      application = self._application,
      text = self._controller:text(),
    }
  end
  ---@return string current staged text (never seals on read)
  function child:namingText()
    return self._controller:text()
  end
  ---@return table<string, unknown>? bound result, exactly once
  function child:takeResult()
    if self._concluded == "cancelled" then
      self._concluded = true
      return {
        kind = "cancelled",
        requestId = self._identity.requestId,
        epoch = self._identity.epoch,
        controller = self._identity.controller,
        launchId = self._identity.launchId,
      }
    end
    if self._concluded then
      return nil
    end
    local sealed = self._controller:result()
    if type(sealed) ~= "table" or sealed.kind ~= "submit" then
      return nil
    end
    self._concluded = true
    return {
      kind = "choice",
      requestId = self._identity.requestId,
      epoch = self._identity.epoch,
      controller = self._identity.controller,
      launchId = self._identity.launchId,
      choice = { kind = "nickname", text = sealed.text },
    }
  end
  function child:dispose()
    self._disposed = true
  end
  return child
end

-- Composes the native evolution presentation state for a committed
-- subject behind the full frozen trigger context: the detached subject,
-- its party slot, and the launch-frozen clock, party, and inventory
-- facts the domain needs. Eligibility, planning, and transformation
-- stay with the evolution domain; the state owns the native
-- animation/cry/message/input sequence, and each pending learned move
-- pauses on the same native Summary picker the battle-action learning
-- child uses. The child owns its state and picker leases and releases
-- both exactly once; results report once as a typed completion answer.
---@param intent table<string, unknown> validated evolution intent under composition
---@param services table<string, unknown> borrowed battle services under composition
---@return table<string, unknown>? composed evolution child
---@return string? failure cause
local function openEvolutionChild(intent, services)
  local EvolutionState = require("game.hgss.src.battle.BattleEvolutionState")
  local mon = intent.subject
  if type(mon) ~= "table" then
    return nil, "evolution children carry their committed subject"
  end
  local triggerContext = intent.context
  if type(triggerContext) ~= "table" then
    return nil, "evolution children carry their full trigger context"
  end
  if type(triggerContext.trigger) ~= "table" then
    return nil, "evolution children carry their trigger identity"
  end
  -- The frozen launch clock rides the context untouched: a missing
  -- clock fails here instead of inventing a default behind the domain.
  if type(triggerContext.timeOfDay) ~= "string" or triggerContext.timeOfDay == "" then
    return nil, "evolution children carry their frozen time of day"
  end
  local catalog = services.monCatalog
  if catalog == nil then
    return nil, "evolution children need their mon catalog"
  end
  local context = {}
  for key, value in pairs(triggerContext) do
    context[key] = copyValue(value)
  end
  if context.party == nil then
    context.party = {}
  end
  if context.inventory == nil then
    context.inventory = {}
  end
  local ok, state = pcall(EvolutionState.new, {
    mon = copyValue(mon),
    context = context,
    catalog = catalog,
    source = intent.source,
    particles = services.evolutionParticles,
    splRandomState = services.splRandomState,
  })
  if not ok then
    return nil, tostring(state)
  end
  local subject = copyValue(mon) --[[@as table<string, unknown>]]
  local identity = childIdentity("evolution", intent)
  local child = {
    _kind = "evolution",
    _identity = identity,
    _application = BattleChildApplications.RECEIPTS.evolution,
    _state = state,
    _subject = subject,
    _catalog = catalog,
    _summary = nil --[[@as SummaryScreenState?]],
    _summaryEvents = {},
    _summaryPending = false,
    _cursorAnimations = services.evolutionCursor,
    _cursorPlayback = nil,
    _learnMenu = nil,
    _taken = false,
    _disposed = false,
  }
  function child:_openSummary()
    if self._summary ~= nil or self._summaryPending then
      return nil
    end
    local prompt = self._state:learnPrompt()
    if prompt == nil then
      return nil
    end
    self._state:beginLearnSummary()
    self._summaryPending = true
    return nil
  end
  function child:_createSummary()
    assert(self._summaryPending and self._summary == nil, "Summary opens after the scene fade-out")
    local prompt = assert(self._state:learnPrompt(), "the Summary transition retains its move prompt")
    local deps = assert(services.summary, "evolution move replacement requires the field Summary application")
    local summaryMon = copyValue(self._subject) --[[@as table<string, unknown>]]
    summaryMon.species = assert(self._state:draw().newSpecies)
    local heldMoves = summaryMon.moves --[[@as table<integer, table<string, unknown>>]]
    local currentMoves = prompt.currentMoves --[[@as string[] ]]
    local moves = {}
    for slot, moveKey in ipairs(currentMoves) do
      local retained = nil
      for _, entry in ipairs(heldMoves) do
        if entry.move == moveKey then
          retained = copyValue(entry)
          break
        end
      end
      if retained == nil then
        local move = self._catalog:move(moveKey)
        retained = { move = moveKey, pp = move.basePp, ppUps = 0 }
      end
      moves[slot] = retained
    end
    summaryMon.moves = moves
    local function subjectCount()
      return 1
    end
    local function subjectRevision()
      return 1
    end
    local function readSubject(index)
      assert(index == 0, "evolution Summary presents its one subject")
      return copyValue(summaryMon)
    end
    local function rejectPublish()
      return { kind = "stale" }
    end
    local subjectPort = {
      count = subjectCount,
      revision = subjectRevision,
      read = readSubject,
      publish = rejectPublish,
    }
    self._summary = SummaryScreenState.new({
      mons = deps.mons,
      manifest = deps.manifest,
      measureDisplay = deps.measureDisplay,
      mode = "move_pick",
      request = { context = "replace_machine", prospectiveMove = prompt.move },
      subjectPort = subjectPort,
      context = deps.context,
      readNavigation = deps.readNavigation,
      acquirePreparation = deps.acquirePreparation,
      effect = deps.effect,
      playCry = deps.playCry,
    })
    self._summaryPending = false
    return nil
  end
  function child:_drainSummary()
    local summary = self._summary
    if summary == nil then
      return
    end
    local result = summary:takeResult()
    if result == nil then
      return
    end
    summary:dispose()
    self._summary = nil
    local slot = result.kind == "move_selected" and result.moveSlot or 4
    self._state:finishLearnSummary(assert(slot, "Summary returns its selected move slot"))
    self:_startCursor("idle")
  end
  function child:completePaletteFade(channel, requestId)
    self._state:completePaletteFade(channel, requestId)
    if channel == "scene" and self._state:status().phase == "summary" then
      self:_createSummary()
    elseif channel == "scene" and self._state:status().phase == "stop_menu" then
      self._learnMenu = { kind = "stop", focus = 0 }
    end
  end
  function child:completeMessage()
    self._state:completeMessage()
  end
  function child:completeCry()
    self._state:completeCry()
  end
  function child:completePicture()
    self._state:completePicture()
  end
  function child:_setCursorFrame(index)
    local playback = assert(self._cursorPlayback, "evolution cursor playback is initialized with the scene")
    local role = assert(playback.role, "evolution cursor playback names its animation")
    local animations = assert(self._cursorAnimations, "evolution menus use the staged cursor animation")
    local animation = assert(animations[role], "evolution cursor animation is staged for " .. role)
    local frame = assert(animation.frames[index], "evolution cursor playback stays inside source frames")
    playback.index = index
    playback.remaining = frame.durationTicks
    playback.frame = frame
    self:_showCursorFrame()
  end
  function child:_showCursorFrame()
    local playback = assert(self._cursorPlayback, "evolution cursor playback is initialized with the scene")
    local menu = self._learnMenu
    if menu ~= nil then
      local frame = assert(playback.frame, "evolution cursor playback carries its source frame")
      menu.cursorRole = playback.role
      menu.cursorIndex = playback.index
      menu.cursorRemaining = playback.remaining
      menu.cursor = {
        role = playback.role,
        sourceFrame = frame.sourceFrame,
        rasterOffset = copyValue(frame.rasterOffset),
        position = { x = 128, y = menu.focus == 0 and 72 or 120 },
      }
    end
  end
  function child:_startCursor(role)
    local animations = assert(self._cursorAnimations, "evolution menus use the staged cursor animation")
    local animation = assert(animations[role], "evolution cursor animation is staged for " .. role)
    assert(#animation.frames > 0, "evolution cursor animations contain source frames")
    local playMode = assert(animation.playMode, "evolution cursor animations retain their source playback mode")
    assert(
      playMode == "forward" or playMode == "forward_loop" or playMode == "reverse" or playMode == "reverse_loop",
      "evolution cursor uses a supported source playback mode"
    )
    if role == "select" then
      assert(playMode == "forward" or playMode == "reverse", "selected cursor animation must finish")
    end
    self._cursorPlayback = { role = role }
    local first = 1
    if playMode == "reverse" or playMode == "reverse_loop" then
      first = #animation.frames
    end
    self:_setCursorFrame(first)
  end
  function child:_newLearnMenu(kind)
    self._learnMenu = { kind = kind, focus = 0 }
    if self._cursorPlayback == nil then
      self:_startCursor("idle")
    else
      self:_showCursorFrame()
    end
  end
  function child:_finishMenuSelection()
    local menu = assert(self._learnMenu, "evolution menu selection retains its focus")
    if menu.kind == "delete" and menu.focus == 0 then
      self._learnMenu = nil
      self:_openSummary()
    elseif menu.kind == "delete" then
      self._state:beginStopQuestion()
      self:_newLearnMenu("stop")
    elseif menu.focus == 0 then
      self._state:answerLearn({ choice = "decline", stopQuestionPresented = true })
      self._learnMenu = nil
    else
      self._state:retryLearn()
      self:_newLearnMenu("delete")
    end
  end
  function child:_advanceCursor()
    local playback = self._cursorPlayback
    if playback == nil or playback.finished == true then
      return
    end
    local animations = assert(self._cursorAnimations, "evolution menus use the staged cursor animation")
    local animation = assert(animations[assert(playback.role)], "evolution cursor animation is staged")
    playback.remaining = math.max(0, assert(playback.remaining) - 1)
    if playback.remaining > 0 then
      return
    end
    local reverse = animation.playMode == "reverse" or animation.playMode == "reverse_loop"
    local nextIndex = assert(playback.index) + (reverse and -1 or 1)
    local loop = animation.playMode == "forward_loop" or animation.playMode == "reverse_loop"
    if loop then
      local start = assert(animation.loopStartFrameIdx) + 1
      if reverse and nextIndex < start then
        nextIndex = #animation.frames
      elseif not reverse and nextIndex > #animation.frames then
        nextIndex = start
      end
      self:_setCursorFrame(nextIndex)
      return
    end
    if nextIndex >= 1 and nextIndex <= #animation.frames then
      self:_setCursorFrame(nextIndex)
      return
    end
    if playback.role == "select" then
      local menu = assert(self._learnMenu, "a finished select animation belongs to its active menu")
      assert(menu.selecting == true, "select cursor animation only runs after an answer")
      playback.finished = true
      self:_finishMenuSelection()
      return
    end
    self:_setCursorFrame(reverse and #animation.frames or 1)
    return error("evolution cursor animation uses unsupported playback mode " .. animation.playMode, 0)
  end
  if child._cursorAnimations ~= nil then
    child:_startCursor("idle")
  end
  ---@param events table<integer, table<string, unknown>> semantic input batch under routing
  function child:input(events)
    if self._disposed or self._taken then
      return
    end
    local phase = self._state:status().phase
    if
      self._state:status().printerPending
      or self._summaryPending
      or phase == "summary_out"
      or phase == "summary_in"
    then
      return
    end
    local summary = self._summary
    if summary ~= nil then
      for _, event in ipairs(events) do
        self._summaryEvents[#self._summaryEvents + 1] = event
      end
      return
    end
    local prompt = self._state:learnPrompt()
    if prompt ~= nil then
      if self._learnMenu == nil then
        self:_newLearnMenu(phase == "stop_menu" and "stop" or "delete")
      end
      local menu = assert(self._learnMenu, "evolution menu retains its current selection")
      for _, event in ipairs(events) do
        if menu.selecting then
          break
        end
        if event.type == "navigate" then
          local choice = event.direction == "up" and 0 or event.direction == "down" and 1 or nil
          if choice ~= nil and menu.focus ~= choice then
            menu.focus = choice
            self._state:menuSelect()
            if menu.cursor ~= nil then
              menu.cursor.position.y = choice == 0 and 72 or 120
            end
          end
        elseif event.type == "pointer_down" then
          -- Lower-screen local coordinates against the source's half-open
          -- {top, bottom, left, right} rectangles.
          local choice = nil
          if type(event.x) == "number" and type(event.y) == "number" and event.x >= 3 and event.x < 251 then
            if event.y >= 50 and event.y < 92 then
              choice = 0
            elseif event.y >= 99 and event.y < 140 then
              choice = 1
            end
          end
          if choice ~= nil then
            menu.focus = choice
            self._state:menuSelect()
            self._state:menuSelect()
            self:_startCursor("select")
            menu.selecting = true
          end
        elseif event.type == "cancel" then
          menu.focus = 1
          self._state:menuSelect()
          self:_startCursor("select")
          menu.selecting = true
        elseif event.type == "confirm" then
          self._state:menuSelect()
          self:_startCursor("select")
          menu.selecting = true
        end
      end
      return
    end
    self._state:input(events)
  end
  ---@param tick integer source tick under stepping
  function child:stepSourceTick(tick)
    if self._disposed or self._taken then
      return
    end
    if self._summary ~= nil then
      for _ = 1, tick do
        self._summary:updateFixed(self._summaryEvents)
        self._summaryEvents = {}
        self:_drainSummary()
      end
    else
      for _ = 1, tick do
        self._state:stepSourceTick(1)
        if self._learnMenu == nil and self._state:status().phase == "stop_menu" then
          self:_newLearnMenu("stop")
        end
      end
    end
  end
  ---@param tick integer evolution scene animation ticks under stepping
  function child:stepPresentationSourceTick(tick)
    if self._disposed or self._taken or self._summary ~= nil then
      return
    end
    assert(
      type(tick) == "number" and tick % 1 == 0 and tick >= 0,
      "evolution presentation ticks stay whole and non-negative"
    )
    for _ = 1, tick do
      self:_advanceCursor()
    end
    self._state:stepPresentationSourceTick(tick)
  end
  ---@param _ table<string, unknown>? borrowed display facts (the returned record is renderer-agnostic data)
  ---@return table<string, unknown> drawable evolution record from the native presentation or picker
  function child:draw(_)
    local view = self._state:draw()
    if self._summary ~= nil then
      view.phase = "summary"
      view.summaryStatus = self._summary:status()
    else
      local prompt = self._state:learnPrompt()
      local phase = self._state:status().phase
      if prompt ~= nil and not self._state:status().printerPending and (phase == "learn" or phase == "stop_menu") then
        if self._learnMenu == nil then
          self:_newLearnMenu(phase == "stop_menu" and "stop" or "delete")
        end
        view.learnMenu = copyValue(self._learnMenu)
      end
    end
    return view
  end
  ---@return string native application receipt
  function child:application()
    return self._application
  end
  ---@return table<string, unknown> child status with its application receipt
  function child:status()
    local inner = self._state:status()
    assert(type(inner) == "table", "the evolution state reports its status")
    inner.application = self._application
    return inner
  end
  ---@return table<integer, table<string, unknown>> sequenced effect requests in order (read-only evidence)
  function child:effects()
    return self._state:effects()
  end
  ---@return table<string, unknown>? pending learned-move prompt, nil outside the learning pause
  function child:learnPrompt()
    return self._state:learnPrompt()
  end
  ---@return table<string, unknown>? bound typed result, exactly once
  function child:takeResult()
    if self._taken then
      return nil
    end
    local settled = self._state:takeResult()
    if settled == nil then
      return nil
    end
    assert(type(settled) == "table", "the evolution state settles its result")
    self._taken = true
    local choice = assert(settled.choice, "evolution results carry their choice")
    local bound = {
      requestId = self._identity.requestId,
      epoch = self._identity.epoch,
      controller = self._identity.controller,
      launchId = self._identity.launchId,
    } --[[@as table<string, unknown>]]
    if choice.evolved == true then
      bound.kind = "evolution_complete"
      bound.staged = copyValue(assert(choice.staged, "completed evolutions carry their staged result"))
    else
      bound.kind = "evolution_cancelled"
      bound.reason = choice.reason
    end
    return bound
  end
  function child:dispose()
    if self._disposed then
      return
    end
    self._disposed = true
    -- Disposal releases both leases exactly once: a disposed child owns
    -- no input and seals nothing, so stale learning never reports
    -- afterwards.
    local summary = self._summary
    self._summary = nil
    if summary ~= nil then
      summary:dispose()
    end
    self._state:dispose()
  end
  return child
end

---@class BattleChildApplications.Services
---@field itemCatalog table<string, unknown>? borrowed immutable item catalog
---@field monCatalog table<string, unknown>? borrowed immutable mon catalog
---@field charmap table<string, integer>? injected generated font charmap for naming
---@field evolutionCursor table<string, unknown>? staged EvolutionScene cursor animations for the move menu
---@field effect fun(sequence: string)? injected sound boundary for naming; silent when the host provides none

-- Opens the concrete child application for one barrier identity over
-- battle-local data and command adapters. The initiating input terminates
-- at the barrier: every composed controller starts from its entry state
-- with no armed press and no staged intent, so opening consumes the edge
-- that opened it. A composition failure reports its boundary and owns
-- nothing.
---@param intent table<string, unknown> child intent under composition
---@param services table<string, unknown>? borrowed battle services under composition
---@return table<string, unknown>? composed child application
---@return string? failure cause
function BattleChildApplications.open(intent, services)
  local ok, identity = pcall(checkIdentity, intent)
  if not ok then
    return nil, tostring(identity)
  end
  local owned = services or {}
  assert(type(owned) == "table", "battle child services arrive as a record")
  if identity.kind == "party" then
    return openPartyChild(intent, owned)
  elseif identity.kind == "bag" then
    return openBagChild(intent, owned)
  elseif identity.kind == "learn" then
    return openLearnChild(intent, owned)
  elseif identity.kind == "naming" then
    return openNamingChild(intent, owned)
  end
  return openEvolutionChild(intent, owned)
end

return BattleChildApplications
