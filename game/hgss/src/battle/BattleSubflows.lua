-- Battle-local child selection over detached battle data. Voluntary
-- switch, forced replacement, bag browsing, item-target picking, and
-- move learning run on small battle-owned cursor records over the
-- detached snapshots the parent intent carries. Party focus walks the
-- shared six-slot/cancel neighbor topology while skipping rows the
-- kernel did not project; bag browsing keeps its per-pocket cursor,
-- scroll, and focus through the shared bag cursor and native pocket
-- order with six visible cells. Every success copies a kernel-projected
-- choice fragment bound to the opening launch and request, every
-- permitted Back reports a bound cancellation, and stale or foreign
-- input never seals. No field screen is constructed, no hidden clock is
-- stepped, and no live party, bag, or save owner is touched; the kernel
-- executes and the committer publishes.

local BagCursor = require("libs.hgss.src.items.BagCursor")
local BagSave = require("libs.hgss.src.save.BagSave")
local PartyScreenLayout = require("libs.hgss.src.ui.PartyScreenLayout")

---@class BattleSubflows
---@field _launchId string owning launch identity
---@field _itemCatalog table<string, unknown>? borrowed immutable item catalog for pocket grouping
---@field _monCatalog table<string, unknown>? borrowed immutable mon catalog for machine display facts
---@field _active string? live child kind: party, bag, target, or learn
---@field _purpose string? selection purpose behind the active child
---@field _cancellable boolean cancel permission behind the active child
---@field _requestId integer open request identity behind the active child
---@field _epoch integer open request epoch behind the active child
---@field _controller string open request controller behind the active child
---@field _pending table<string, unknown>? staged bound result awaiting collection
---@field _notice string? refusal explanation behind the active child
---@field _openOptionsValue table<string, unknown>? decision options behind the active child
---@field _openPartyValue table<integer, table<string, unknown>>? party snapshot behind the active child
---@field _party table<string, unknown>? battle-local party/target picker cursor behind selection
---@field _stagedItem string? staged battle item behind target selection
---@field _bag table<string, unknown>? battle-local bag browser behind bag selection
---@field _retained table<string, unknown>? retained bag browser behind target selection
---@field _learn table<string, unknown>? active learning prompt state
---@field _disposed boolean
local BattleSubflows = {}
BattleSubflows.__index = BattleSubflows

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

---@param catalog table<string, unknown> borrowed immutable item catalog
---@param key string stocked item identity under lookup
---@return table<string, unknown> validated item record
local function catalogItem(catalog, key)
  local lookup = catalog.item --[[@as fun(collab: table<string, unknown>, key: string): table<string, unknown>]]
  assert(type(lookup) == "function", "the item catalog answers item records")
  local record = lookup(catalog, key)
  assert(type(record) == "table", "stocked items resolve through the catalog")
  return record --[[@as table<string, unknown>]]
end

---@param reason string? supplied refusal reason under display
---@return string visible refusal text
local function refusalText(reason)
  if type(reason) == "string" and reason ~= "" then
    return reason
  end
  return "That choice is unavailable."
end

---@class BattleSubflows.Options
---@field launchId string owning launch identity
---@field itemCatalog table<string, unknown>? borrowed immutable item catalog for pocket grouping
---@field monCatalog table<string, unknown>? borrowed immutable mon catalog for machine display facts

---@param opts BattleSubflows.Options
---@return BattleSubflows
function BattleSubflows.new(opts)
  assert(type(opts) == "table", "battle children require options")
  assert(type(opts.launchId) == "string" and opts.launchId ~= "", "battle children need their launch identity")
  if opts.itemCatalog ~= nil then
    assert(type(opts.itemCatalog) == "table", "the item catalog arrives as a record")
  end
  if opts.monCatalog ~= nil then
    assert(type(opts.monCatalog) == "table", "the mon catalog arrives as a record")
  end
  return setmetatable({
    _launchId = opts.launchId,
    _itemCatalog = opts.itemCatalog,
    _monCatalog = opts.monCatalog,
    _active = nil,
    _purpose = nil,
    _cancellable = false,
    _requestId = 0,
    _epoch = 0,
    _controller = "",
    _pending = nil,
    _notice = nil,
    _openOptionsValue = nil,
    _openPartyValue = nil,
    _party = nil,
    _stagedItem = nil,
    _bag = nil,
    _retained = nil,
    _learn = nil,
    _disposed = false,
  }, BattleSubflows)
end

---@param intent table<string, unknown> child intent under validation
local function checkIntent(intent)
  assert(type(intent) == "table", "child intents arrive as records")
  assert(
    intent.kind == "party" or intent.kind == "bag" or intent.kind == "learn",
    "child intents name party, bag, or learn"
  )
  assert(type(intent.purpose) == "string" and intent.purpose ~= "", "child intents name their purpose")
  assert(type(intent.launchId) == "string" and intent.launchId ~= "", "child intents carry their launch")
  assert(type(intent.requestId) == "number" and intent.requestId % 1 == 0, "child intents carry their request identity")
  assert(type(intent.epoch) == "number" and intent.epoch % 1 == 0, "child intents carry their epoch")
  assert(type(intent.controller) == "string" and intent.controller ~= "", "child intents carry their controller")
  assert(type(intent.request) == "table", "child intents carry their request")
  assert(type(intent.options) == "table", "child intents carry their options")
  assert(type(intent.party) == "table", "child intents carry their party snapshot")
  assert(type(intent.inventory) == "table", "child intents carry their inventory snapshot")
end

---@param options table<string, unknown> decision options under projection
---@return table<integer, table<string, unknown>> enabled switch fragments by replacement combatant
local function enabledSwitches(options)
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
          and choice.choice.kind == "switch"
          and type(choice.choice.payload) == "table"
          and type(choice.choice.payload.replacement) == "number"
        then
          found[choice.choice.payload.replacement] = choice.choice
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

---@param options table<string, unknown> decision options under projection
---@param key string stocked item identity under projection
---@return boolean legality true while a native choice can execute the item
---@return string? first native refusal reason, nil while selectable
local function itemLegality(options, key)
  local reason = nil
  if type(options.actors) ~= "table" then
    return false, nil
  end
  for _, actor in ipairs(options.actors) do
    if type(actor) == "table" and type(actor.choices) == "table" then
      for _, choice in ipairs(actor.choices) do
        if
          type(choice) == "table"
          and type(choice.choice) == "table"
          and choice.choice.kind == "item"
          and type(choice.choice.payload) == "table"
          and choice.choice.payload.item == key
        then
          if choice.enabled == true then
            return true, nil
          end
          if reason == nil and type(choice.reason) == "string" then
            reason = choice.reason --[[@as string]]
          end
        end
      end
    end
  end
  return false, reason
end

-- Binds one projected fragment to the open launch and request. Fragments
-- are copied, never rebuilt, so the kernel keeps owning their shape.
---@param fragment table<string, unknown> projected choice fragment under binding
---@return table<string, unknown> bound staged reply
function BattleSubflows:_bind(fragment)
  return {
    requestId = self._requestId,
    epoch = self._epoch,
    controller = self._controller,
    launchId = self._launchId,
    choices = { copyValue(fragment) },
  }
end

-- Records the open identity and clears any previous child state. A new
-- open supersedes its predecessor without applying it.
---@param intent table<string, unknown> validated child intent under capture
function BattleSubflows:_capture(intent)
  self:closeChild()
  self._active = intent.kind --[[@as string]]
  self._purpose = intent.purpose --[[@as string]]
  self._cancellable = intent.cancellable == true
  self._requestId = intent.requestId --[[@as integer]]
  self._epoch = intent.epoch --[[@as integer]]
  self._controller = intent.controller --[[@as string]]
  self._openOptionsValue = intent.options --[[@as table<string, unknown>]]
  self._openPartyValue = intent.party --[[@as table<integer, table<string, unknown>>]]
  self._pending = nil
  self._notice = nil
end

---@return table<string, unknown> decision options behind the active child
function BattleSubflows:_openOptions()
  return assert(self._openOptionsValue, "options travel with the active child")
end

---@return table<integer, table<string, unknown>> party snapshot behind the active child
function BattleSubflows:_openParty()
  return assert(self._openPartyValue, "the party snapshot travels with the active child")
end

-- Party picker cursors: one battle-local focus over the six roster
-- slots plus Cancel. Only occupied rows carrying a kernel-projected
-- fragment are selectable; every other row keeps its visible refusal
-- instead of submitting. Focus topology reuses the shared default
-- slot-column neighbors; navigation skips rows that cannot seal.

---@param state table<string, unknown> battle-local picker state under inspection
---@param node integer|string slot or Cancel under inspection
---@return boolean selectable true while confirming the node can seal
local function partySelectable(state, node)
  if node == "cancel" then
    return state.cancellable == true
  end
  if type(node) ~= "number" or node % 1 ~= 0 or node < 0 or node > 5 then
    return false
  end
  local slots = state.slots --[[@as table<integer, table<string, unknown>>]]
  local record = slots[node]
  if type(record) ~= "table" or type(record.combatant) ~= "number" then
    return false
  end
  local eligible = state.eligible --[[@as table<integer, boolean>]]
  return eligible[record.combatant] == true
end

---@param state table<string, unknown> battle-local picker state under inspection
---@param from integer? slot to scan forward from under inspection
---@return integer|string? first selectable node in slot order, nil when nothing seals
local function partyNearest(state, from)
  local start = 0
  if type(from) == "number" then
    start = from
  end
  for offset = 0, 5 do
    local candidate = (start + offset) % 6
    if partySelectable(state, candidate) then
      return candidate
    end
  end
  if state.cancellable == true then
    return "cancel"
  end
  return nil
end

-- Walks one direction through the shared neighbor topology, skipping
-- rows that cannot seal. Dropping into Cancel remembers the column so
-- rising from Cancel restores it instead of the fixed return.
---@param state table<string, unknown> battle-local picker state under motion
---@param direction string navigation direction under motion
local function partyMove(state, direction)
  assert(
    direction == "up" or direction == "down" or direction == "left" or direction == "right",
    "unknown UI direction"
  )
  local neighbors = PartyScreenLayout.defaultNeighbors(state.cancellable == true)
  local start = state.focus --[[@as integer|string]]
  local node = start
  if node == "cancel" and direction == "up" then
    local remembered = 4 + (
        state.footerColumn --[[@as integer?]]
        or 1
      )
    if partySelectable(state, remembered) then
      state.focus = remembered
      return
    end
    node = remembered
  end
  local seen = { [start] = true }
  for _ = 1, 8 do
    local links = neighbors[node]
    if type(links) ~= "table" then
      return
    end
    local following = links[direction]
    if following == nil or following == node or seen[following] then
      return
    end
    seen[following] = true
    if following == "cancel" and type(node) == "number" then
      state.footerColumn = node % 2
    end
    if partySelectable(state, following) then
      state.focus = following
      return
    end
    node = following
  end
end

-- Opens one battle-local party picker over the detached roster: slot
-- occupancy comes from the snapshot, eligibility from the already
-- narrowed native fragments, and focus rests on the first selectable
-- slot in slot order. Construction failures report a reason instead of
-- opening a half-owned selection.
---@param roster table<integer, table<string, unknown>> detached own-party snapshot under opening
---@param eligible table<integer, boolean> eligible combatants under opening
---@param fragments table<integer, table<string, unknown>> projected fragments by eligible combatant
---@param cancellable boolean cancel permission under opening
---@return table<string, unknown>? battle-local picker state, nil on failure
---@return string? failure cause
local function openPartyPicker(roster, eligible, fragments, cancellable)
  ---@type table<integer, table<string, unknown>>
  local slots = {}
  for _, record in ipairs(roster) do
    if type(record) == "table" and type(record.slot) == "number" and type(record.combatant) == "number" then
      assert(slots[record.slot] == nil, "battle roster slots stay unique")
      slots[record.slot] = record
    end
  end
  ---@type table<string, unknown>
  local state = {
    cancellable = cancellable,
    focus = 0,
    eligible = eligible,
    fragments = fragments,
    slots = slots,
    footerColumn = 1,
  }
  local focus = partyNearest(state, 0)
  if focus == nil then
    return nil, "the picker has no selectable slot"
  end
  state.focus = focus
  return state
end

-- Confirms one picker slot: an eligible row stages its exact projected
-- fragment once, while a visibly disabled row explains itself without
-- submitting. Focus never moves onto the refusal.
---@param slot integer roster slot under confirmation
local function confirmPartySlot(self, slot)
  local state = assert(self._party, "party selection confirms its own picker")
  local slots = state.slots --[[@as table<integer, table<string, unknown>>]]
  local record = slots[slot]
  local combatant = type(record) == "table" and record.combatant or nil
  local fragments = state.fragments --[[@as table<integer, table<string, unknown>>]]
  local fragment = type(combatant) == "number" and fragments[combatant] or nil
  if fragment ~= nil then
    self._pending = { kind = "choice", reply = self:_bind(fragment) }
    return
  end
  local hp = type(record) == "table" and record.hp or nil
  if type(hp) == "number" and hp <= 0 then
    self._notice = "It is fainted."
  else
    self._notice = refusalText(nil)
  end
end

-- Cancels target selection back to the retained bag browser without
-- sealing or moving stock. The retained browser keeps its pocket,
-- focus, scroll, and counts.
local function cancelTarget(self)
  self._bag = assert(self._retained, "target cancel reactivates its bag")
  self._retained = nil
  self._party = nil
  self._active = "bag"
  self._stagedItem = nil
  self._notice = nil
end

-- Cancels picker selection without ever auto-choosing: backing out of
-- the target picker reactivates the retained bag browser, backing out
-- of a cancellable picker reports its bound cancellation, and a forced
-- picker holds silently at its input boundary.
local function cancelParty(self)
  if self._active == "target" then
    cancelTarget(self)
    return
  end
  if not self._cancellable then
    return
  end
  self._pending = {
    kind = "cancelled",
    requestId = self._requestId,
    epoch = self._epoch,
    controller = self._controller,
    launchId = self._launchId,
  }
end

-- Bag browser cursors: one battle-local browse record over the detached
-- stock. Pocket identity follows the native pocket order, per-pocket
-- position and scroll ride the shared bag cursor, and focus walks a
-- small grid/tab/Cancel graph: grid siblings sideways, the top row up
-- to the active tab, the last logical row down to Cancel, tabs wrapping
-- through the pocket order while switching pockets at once, and Cancel
-- rising back to the remembered cell.

---@param node unknown browse node under inspection
---@return integer? absolute grid cell, nil outside the grid
local function parseSlotNode(node)
  if type(node) ~= "string" then
    return nil
  end
  local absolute = node:match("^slot:(%d+)$")
  if absolute == nil then
    return nil
  end
  return math.floor(assert(tonumber(absolute), "slot nodes carry a numeric cell"))
end

---@param node unknown browse node under inspection
---@return string? pocket identity, nil outside the tabs
local function parseTabNode(node)
  if type(node) ~= "string" then
    return nil
  end
  local pocketKey = node:match("^tab:(.+)$")
  if pocketKey == nil then
    return nil
  end
  for _, known in ipairs(BagSave.POCKET_ORDER) do
    if known == pocketKey then
      return pocketKey
    end
  end
  return nil
end

---@param itemCatalog table<string, unknown>? borrowed immutable item catalog
---@param monCatalog table<string, unknown>? borrowed immutable mon catalog
---@param inventory table<string, integer> detached battle stock under indexing
---@return table<string, table<integer, table<string, unknown>>>? stocked entries by native pocket, nil on failure
---@return string? failure cause
local function bagItemsFor(itemCatalog, monCatalog, inventory)
  ---@type table<integer, { item: string, quantity: integer, pocket: string }>
  local stocked = {}
  for key, quantity in pairs(inventory) do
    if type(quantity) == "number" and quantity >= 1 then
      if itemCatalog == nil then
        return nil, "the stocked bag needs its item catalog"
      end
      local ok, record = pcall(catalogItem, itemCatalog, key)
      if not ok then
        return nil, "the stocked bag names an unknown item"
      end
      assert(type(record) == "table", "stocked items resolve through the catalog")
      if record.tmhmMoveNativeId ~= nil and monCatalog == nil then
        return nil, "machine display needs its mon catalog"
      end
      local pocket = record.pocket
      assert(type(pocket) == "string", "stocked items group into a native pocket")
      stocked[#stocked + 1] = { item = key, quantity = quantity, pocket = pocket }
    end
  end
  ---@type table<string, table<integer, table<string, unknown>>>
  local items = {}
  for _, pocketKey in ipairs(BagSave.POCKET_ORDER) do
    ---@type table<integer, { item: string, quantity: integer }>
    local list = {}
    for _, entry in ipairs(stocked) do
      if entry.pocket == pocketKey then
        list[#list + 1] = { item = entry.item, quantity = entry.quantity }
      end
    end
    table.sort(list, function(a, b)
      return a.item < b.item
    end)
    items[pocketKey] = list
  end
  return items
end

---@param bag table<string, unknown> battle-local browser under inspection
---@return integer stocked count in the current pocket
local function bagCount(bag)
  local cursor = bag.cursor --[[@as BagCursor]]
  local items = bag.items --[[@as table<string, table<integer, table<string, unknown>>>]]
  return #items[cursor:currentPocket()]
end

---@param count integer stocked count under windowing
---@param scroll integer borrowed scroll offset under windowing
---@return integer clamped even window start
local function clampBagStart(count, scroll)
  if count <= 6 then
    return 0
  end
  local start = math.min(math.max(scroll, 0), count - 1)
  return start - (start % 2)
end

-- The logical browse grid covers the six currently visible cells and
-- otherwise pads occupied items to a complete two-column row, so a
-- visible trailing cell can own focus without inventing inventory.
---@param bag table<string, unknown> battle-local browser under inspection
---@return integer logical cell count
local function bagSlotCount(bag)
  local cursor = bag.cursor --[[@as BagCursor]]
  local count = bagCount(bag)
  local padded = math.max(6, math.ceil(count / 2) * 2)
  local start = clampBagStart(count, cursor:scroll(cursor:currentPocket()))
  return math.max(padded, start + 6)
end

-- Builds the ephemeral browse graph over the current pocket, item count,
-- and remembered cell. Grid adjacency is absolute: same-row siblings
-- sideways (missing neighbors stay put, never wrap), two cells
-- vertically, the top row up to the active-pocket tab, and the last
-- logical row down to Cancel. Tabs wrap through the pocket order and
-- travel vertically back to the remembered cell, as does Cancel upward.
---@param bag table<string, unknown> battle-local browser under inspection
---@return table<string, table<string, string?>> single-target browse graph
local function bagGraph(bag)
  local cursor = bag.cursor --[[@as BagCursor]]
  local pocket = cursor:currentPocket()
  local slotCount = bagSlotCount(bag)
  local remembered = "slot:" .. tostring(math.min(math.max(bag.lastSlot --[[@as integer]], 0), slotCount - 1))
  local graph = {}
  for absolute = 0, slotCount - 1 do
    local id = "slot:" .. tostring(absolute)
    local left = nil
    if absolute % 2 == 1 then
      left = "slot:" .. tostring(absolute - 1)
    end
    local right = nil
    if absolute % 2 == 0 and absolute + 1 < slotCount then
      right = "slot:" .. tostring(absolute + 1)
    end
    local up = "tab:" .. pocket
    if absolute - 2 >= 0 then
      up = "slot:" .. tostring(absolute - 2)
    end
    local down = "cancel"
    if absolute + 2 < slotCount then
      down = "slot:" .. tostring(absolute + 2)
    end
    graph[id] = { up = up, down = down, left = left, right = right }
  end
  local order = BagSave.POCKET_ORDER
  for position, pocketKey in ipairs(order) do
    local previous = order[((position - 2) % #order) + 1]
    local following = order[(position % #order) + 1]
    graph["tab:" .. pocketKey] = {
      left = "tab:" .. previous,
      right = "tab:" .. following,
      up = remembered,
      down = remembered,
    }
  end
  graph["cancel"] = { up = remembered }
  return graph
end

-- Enters a pocket through the cursor API: the stored per-pocket offsets
-- return, clamped to whatever the pocket holds now. Focus stays with the
-- caller, so keyboard tab travel keeps tab focus while pointer travel
-- moves to the grid explicitly at its own call site. The remembered grid
-- cell follows the clamped per-pocket cursor position either way.
---@param bag table<string, unknown> battle-local browser under entry
---@param pocketKey string pocket identity under entry
local function bagEnterPocket(bag, pocketKey)
  local cursor = bag.cursor --[[@as BagCursor]]
  local items = bag.items --[[@as table<string, table<integer, table<string, unknown>>>]]
  cursor:setPocket(pocketKey)
  local count = #items[pocketKey]
  if count == 0 then
    cursor:setPosition(pocketKey, 0)
    cursor:setScroll(pocketKey, 0)
    bag.lastSlot = 0
    return
  end
  local position = cursor:position(pocketKey)
  cursor:setPosition(pocketKey, math.min(math.max(position, 0), count - 1))
  local start = cursor:scroll(pocketKey)
  if start > count - 1 then
    start = count - 1
  end
  if start < 0 then
    start = 0
  end
  cursor:setScroll(pocketKey, start - (start % 2))
  bag.lastSlot = cursor:position(pocketKey)
end

-- Focuses one absolute grid cell: the window slides in row steps until
-- the cell is visible, an occupied cell also becomes the cursor
-- selection, and an empty cell leaves the cursor alone. Requests past
-- the logical grid clamp to its last cell.
---@param bag table<string, unknown> battle-local browser under focus
---@param absolute integer absolute grid cell under focus
local function bagFocusSlot(bag, absolute)
  local cursor = bag.cursor --[[@as BagCursor]]
  local pocket = cursor:currentPocket()
  local count = bagCount(bag)
  local slotCount = bagSlotCount(bag)
  local clamped = math.min(math.max(absolute, 0), slotCount - 1)
  bag.focusNode = "slot:" .. tostring(clamped)
  bag.lastSlot = clamped
  local start = cursor:scroll(pocket)
  while clamped < start do
    start = start - 2
  end
  while clamped >= start + 6 do
    start = start + 2
  end
  if start ~= cursor:scroll(pocket) then
    cursor:setScroll(pocket, start)
  end
  if clamped < count then
    cursor:setPosition(pocket, clamped)
  end
end

-- Applies one resolved browse node: grid cells focus through the shared
-- slot path, while tabs switch pockets at once and only move focus.
---@param bag table<string, unknown> battle-local browser under focus
---@param node string resolved browse node under focus
local function bagApplyFocus(bag, node)
  local absolute = parseSlotNode(node)
  if absolute ~= nil then
    bagFocusSlot(bag, absolute)
    return
  end
  assert(node == "cancel" or parseTabNode(node) ~= nil, "focus nodes stay inside the browse graph")
  local tab = parseTabNode(node)
  if tab ~= nil then
    local cursor = bag.cursor --[[@as BagCursor]]
    if tab ~= cursor:currentPocket() then
      bagEnterPocket(bag, tab)
    end
  end
  bag.focusNode = node
end

---@param bag table<string, unknown> battle-local browser under motion
---@param direction string navigation direction under motion
local function bagMove(bag, direction)
  assert(
    direction == "up" or direction == "down" or direction == "left" or direction == "right",
    "unknown UI direction"
  )
  local graph = bagGraph(bag)
  if
    graph[
      bag.focusNode --[[@as string]]
    ] == nil
  then
    bag.focusNode = "slot:" .. tostring(bag.lastSlot --[[@as integer]])
  end
  local links = graph[
    bag.focusNode --[[@as string]]
  ]
  if type(links) ~= "table" then
    return
  end
  local target = links[direction]
  if target == nil then
    return
  end
  bagApplyFocus(bag, target)
end

-- Steps pocket focus through the same semantic edges keyboard travel
-- uses: up to the tab strip, one step sideways across tabs (which
-- switches pockets at once), then down to the grid. Pointer tabs and
-- keyboard tab hops land on the same remembered cell.
---@param direction string lateral tab travel under stepping: "left" or "right"
local function stepPocket(self, direction)
  local bag = assert(self._bag, "pocket travel keeps its browser")
  assert(bag.empty ~= true, "pocket travel keeps its stock")
  assert(direction == "left" or direction == "right", "pocket travel steps sideways")
  local cursor = bag.cursor --[[@as BagCursor]]
  bagApplyFocus(bag, "tab:" .. cursor:currentPocket())
  bagMove(bag, direction)
  bagMove(bag, "down")
end

-- Confirms the focused bag node: Cancel closes back, tabs keep their
-- focus, an occupied cell stages through the item path only while
-- kernel-legal, and a refused cell names its native reason. Empty cells
-- never activate.
local function confirmBagCell(self)
  local bag = assert(self._bag, "the bag confirms its own cells")
  local node = bag.focusNode --[[@as string]]
  if node == "cancel" then
    self._pending = {
      kind = "cancelled",
      requestId = self._requestId,
      epoch = self._epoch,
      controller = self._controller,
      launchId = self._launchId,
    }
    return
  end
  local tab = parseTabNode(node)
  if tab ~= nil then
    local cursor = bag.cursor --[[@as BagCursor]]
    if tab ~= cursor:currentPocket() then
      bagEnterPocket(bag, tab)
    end
    return
  end
  local absolute = parseSlotNode(node)
  if absolute == nil then
    return
  end
  local cursor = bag.cursor --[[@as BagCursor]]
  local items = bag.items --[[@as table<string, table<integer, table<string, unknown>>>]]
  local list = items[cursor:currentPocket()]
  if absolute >= #list then
    return
  end
  local entry = list[absolute + 1]
  local key = entry.item
  assert(type(key) == "string", "stocked cells carry their item key")
  local options = self:_openOptions()
  local legal, reason = itemLegality(options, key)
  if legal == true then
    self:stageItem(key)
  else
    self._notice = refusalText(reason)
  end
end

---@param intent table<string, unknown> party selection intent under opening
---@return boolean opened
---@return string? failure cause
local function openParty(self, intent)
  local options = intent.options --[[@as table<string, unknown>]]
  local roster = intent.party --[[@as table<integer, table<string, unknown>>]]
  local fragments = enabledSwitches(options)
  if next(fragments) == nil then
    return false, "no eligible reserve answers the request"
  end
  local eligible = {}
  for combatant in pairs(fragments) do
    eligible[combatant] = true
  end
  self:_capture(intent)
  local picker, pickerErr = openPartyPicker(roster, eligible, fragments, self._cancellable)
  if picker == nil then
    self:closeChild()
    return false, pickerErr
  end
  self._party = picker
  return true
end

---@param intent table<string, unknown> battle bag intent under opening
---@return boolean opened
---@return string? failure cause
local function openBag(self, intent)
  local inventory = intent.inventory --[[@as table<string, integer>]]
  local items, itemsErr = bagItemsFor(self._itemCatalog, self._monCatalog, inventory)
  if items == nil then
    return false, itemsErr
  end
  local stocked = false
  for _, pocketKey in ipairs(BagSave.POCKET_ORDER) do
    if #items[pocketKey] > 0 then
      stocked = true
      break
    end
  end
  self:_capture(intent)
  if not stocked then
    self._bag = { empty = true }
    return true
  end
  local cursor = BagCursor.new()
  local bag = { cursor = cursor, items = items, focusNode = "slot:0", lastSlot = 0 }
  local pocket = cursor:currentPocket()
  local count = #items[pocket]
  if count > 0 then
    cursor:setPosition(pocket, 0)
  end
  self._bag = bag
  return true
end

---@param options table<string, unknown> decision options under learning lookup
---@param id string projected learning choice identity under lookup
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

---@param intent table<string, unknown> learning intent under opening
---@return boolean opened
---@return string? failure cause
local function openLearn(self, intent)
  local request = intent.request --[[@as table<string, unknown>]]
  local options = intent.options --[[@as table<string, unknown>]]
  local actors = request.actors --[[@as table<integer, table<string, unknown>>?]]
  if type(actors) ~= "table" or type(actors[1]) ~= "table" or type(actors[1].combatant) ~= "number" then
    return false, "learning prompts address their recipient"
  end
  if actors[1].activation ~= nil then
    return false, "learning answers carry no entry token"
  end
  local moves = request.currentMoves --[[@as table<integer, table<string, unknown>>?]]
  if type(moves) ~= "table" or #moves ~= 4 then
    return false, "learning prompts carry their held move set"
  end
  if type(request.incomingMove) ~= "string" or request.incomingMove == "" then
    return false, "learning prompts name their incoming move"
  end
  local fragments = {}
  for slot = 0, 3 do
    local fragment = learnFragment(options, "learn:replace:" .. tostring(slot))
    if fragment == nil then
      return false, "the held slot stays replaceable"
    end
    fragments[slot] = fragment
  end
  local decline = learnFragment(options, "learn:decline")
  if decline == nil then
    return false, "the prompt stays declinable"
  end
  self:_capture(intent)
  self._learn = {
    recipient = actors[1].combatant,
    incomingMove = request.incomingMove,
    currentMoves = copyValue(moves),
    replace = fragments,
    decline = decline,
    focus = 1,
    confirmation = nil,
  }
  return true
end

---@class BattleSubflows.Intent
---@field kind "party"|"bag"|"learn" child kind under opening
---@field purpose string selection purpose under opening
---@field launchId string owning launch identity under opening
---@field requestId integer open request identity under opening
---@field epoch integer open request epoch under opening
---@field controller string open request controller under opening
---@field cancellable boolean? cancel permission under opening
---@field request table<string, unknown> mirrored open request under opening
---@field options table<string, unknown> decision options under opening
---@field party table<integer, table<string, unknown>> detached own-party snapshot under opening
---@field inventory table<string, integer> detached battle stock under opening

---@param intent BattleSubflows.Intent child intent under opening
---@return boolean opened
---@return string? failure cause
function BattleSubflows:open(intent)
  if self._disposed then
    return false, "the children are disposed"
  end
  local ok, checkErr = pcall(checkIntent, intent)
  if not ok then
    return false, tostring(checkErr)
  end
  if intent.launchId ~= self._launchId then
    return false, "children answer their own launch"
  end
  -- Children select for exactly one addressed entry: the parent narrows
  -- the intent options to the acting entry, and the narrowed entry stays
  -- authoritative here instead of unioning fragments across entries.
  local actors = intent.options.actors --[[@as table<integer, table<string, unknown>>?]]
  if type(actors) ~= "table" or #actors ~= 1 or type(actors[1]) ~= "table" then
    return false, "children answer exactly one addressed entry"
  end
  if intent.kind == "party" then
    return openParty(self, intent)
  elseif intent.kind == "bag" then
    return openBag(self, intent)
  end
  return openLearn(self, intent)
end

---@param allowed table<string, boolean> accepted input edges under routing
---@param event table<string, unknown> semantic input under routing
---@return boolean routed true for lane-owned edges
local function laneEvent(allowed, event)
  return type(event) == "table" and allowed[event.type] == true
end

local BAG_EVENTS = { navigate = true, confirm = true, cancel = true, pointer_cancel = true }
local LIST_EVENTS = { navigate = true, confirm = true, cancel = true }

-- Stages one battle item: capture throws directly at the opposing
-- holder through its native fragment, while servings retain the local
-- bag browser and open admitted-target selection on a second local
-- picker. Refused staging explains itself.
---@param itemKey string staged battle item identity under routing
function BattleSubflows:stageItem(itemKey)
  local intentOptions = self:_openOptions()
  local roster = self:_openParty()
  local own = {}
  for _, record in ipairs(roster) do
    if type(record) == "table" and type(record.combatant) == "number" then
      own[record.combatant] = true
    end
  end
  local targets = enabledItemTargets(intentOptions, itemKey)
  local foeFragment = nil
  local ownFragments = {}
  for combatant, fragment in pairs(targets) do
    if own[combatant] then
      ownFragments[combatant] = fragment
    elseif foeFragment == nil then
      foeFragment = fragment
    end
  end
  local catalog = self._itemCatalog
  local isBall = false
  if catalog ~= nil then
    local ok, record = pcall(catalogItem, catalog, itemKey)
    if ok and type(record) == "table" and record.isBall == true then
      isBall = true
    end
  end
  if isBall then
    if foeFragment == nil then
      self._notice = refusalText(nil)
      return
    end
    self._pending = { kind = "choice", reply = self:_bind(foeFragment) }
    return
  end
  if next(ownFragments) == nil then
    self._notice = refusalText(nil)
    return
  end
  local eligible = {}
  for combatant in pairs(ownFragments) do
    eligible[combatant] = true
  end
  local picker, pickerErr = openPartyPicker(roster, eligible, ownFragments, true)
  assert(picker ~= nil, tostring(pickerErr or "target selection opens its picker"))
  self._retained = assert(self._bag, "target selection retains its bag")
  self._bag = nil
  self._active = "target"
  self._stagedItem = itemKey
  self._party = picker
end

---@param direction string navigation direction under learning focus
local function moveLearnFocus(self, direction)
  local learn = assert(self._learn, "learning moves its own focus")
  local focus = learn.focus --[[@as integer]]
  if direction == "down" then
    focus = math.min(focus + 1, 5)
  elseif direction == "up" then
    focus = math.max(focus - 1, 1)
  else
    return
  end
  learn.focus = focus
end

-- Confirms the focused learning row: a move stages its replace
-- confirmation, the decline row stages its decline confirmation, and
-- confirming a staged confirmation seals its projected fragment. No path
-- declines without an explicit confirmation.
local function confirmLearn(self)
  local learn = assert(self._learn, "learning confirms its own rows")
  if learn.confirmation == nil then
    local focus = learn.focus --[[@as integer]]
    if focus <= 4 then
      learn.confirmation = { kind = "replace", slot = focus - 1 }
    else
      learn.confirmation = { kind = "decline" }
    end
    return
  end
  local confirmation = learn.confirmation --[[@as table<string, unknown>]]
  if confirmation.kind == "replace" then
    local fragments = learn.replace --[[@as table<integer, table<string, unknown>>]]
    local fragment = assert(fragments[confirmation.slot], "confirmed slots project their fragment")
    self._pending = { kind = "choice", reply = self:_bind(fragment) }
  else
    local decline = assert(learn.decline, "declines project their fragment")
    self._pending = { kind = "choice", reply = self:_bind(decline) }
  end
end

-- Cancels learning without ever auto-declining: backing out of the list
-- opens the explicit stop confirmation, rejecting any confirmation
-- returns to the list with its focus kept.
local function cancelLearn(self)
  local learn = assert(self._learn, "learning cancels its own rows")
  if learn.confirmation == nil then
    learn.confirmation = { kind = "stop" }
    return
  end
  learn.confirmation = nil
end

-- Confirms the stop-learning prompt: only this explicit confirmation
-- declines the prompt without replacing a move.
local function confirmStopLearn(self)
  local learn = assert(self._learn, "stop confirmations decline their prompt")
  local decline = assert(learn.decline, "declines project their fragment")
  self._pending = { kind = "choice", reply = self:_bind(decline) }
end

---@param event table<string, unknown> semantic input under learning routing
local function updateLearn(self, event)
  local learn = assert(self._learn, "learning owns its input lane")
  if event.type == "navigate" then
    if learn.confirmation == nil then
      moveLearnFocus(self, event.direction --[[@as string]])
    end
  elseif event.type == "confirm" then
    if learn.confirmation == nil then
      confirmLearn(self)
    elseif learn.confirmation.kind == "stop" then
      confirmStopLearn(self)
    else
      confirmLearn(self)
    end
  elseif event.type == "cancel" then
    cancelLearn(self)
  elseif event.type == "pointer_cancel" then
    self:cancelPointerCapture()
  end
end

---@param events table<integer, table<string, unknown>> semantic input batch under routing
function BattleSubflows:update(events)
  if self._disposed or self._active == nil or self._pending ~= nil then
    return
  end
  assert(type(events) == "table", "child input arrives as an event list")
  for _, event in ipairs(events) do
    if self._pending ~= nil then
      break
    end
    if type(event) ~= "table" or type(event.type) ~= "string" then
      break
    end
    if self._active == "party" or self._active == "target" then
      if not laneEvent(LIST_EVENTS, event) then
        break
      end
      local state = assert(self._party, "the picker owns its input lane")
      if event.type == "navigate" then
        partyMove(state, event.direction --[[@as string]])
      elseif event.type == "confirm" then
        if state.focus == "cancel" then
          cancelParty(self)
        else
          confirmPartySlot(self, state.focus --[[@as integer]])
        end
      elseif event.type == "cancel" then
        cancelParty(self)
      end
    elseif self._active == "bag" then
      if not laneEvent(BAG_EVENTS, event) then
        break
      end
      local bag = assert(self._bag, "the browser owns its input lane")
      if event.type == "pointer_cancel" then
        self:cancelPointerCapture()
      elseif bag.empty == true then
        if event.type == "cancel" then
          self._pending = {
            kind = "cancelled",
            requestId = self._requestId,
            epoch = self._epoch,
            controller = self._controller,
            launchId = self._launchId,
          }
        end
      else
        if event.type == "navigate" then
          bagMove(assert(self._bag, "the browser owns its input lane"), event.direction --[[@as string]])
        elseif event.type == "confirm" then
          confirmBagCell(self)
        elseif event.type == "cancel" then
          if not self._cancellable then
            self._notice = "That choice cannot be cancelled."
          else
            self._pending = {
              kind = "cancelled",
              requestId = self._requestId,
              epoch = self._epoch,
              controller = self._controller,
              launchId = self._launchId,
            }
          end
        end
      end
    elseif self._active == "learn" then
      if not laneEvent(LIST_EVENTS, event) then
        break
      end
      updateLearn(self, event)
    end
  end
end

-- The battle child owns no transient clock: browsing and picking answer
-- at once, so the fixed step is a semantic no-op and never warms a
-- hidden controller.
function BattleSubflows:tick() end

---@param entry unknown held move entry under labeling
---@return string visible move wording
local function learnMoveLabel(entry)
  if type(entry) == "table" then
    for _, key in ipairs({ "move", "name", "key" }) do
      local wording = entry[key]
      if type(wording) == "string" and wording ~= "" then
        return wording
      end
    end
  elseif type(entry) == "string" and entry ~= "" then
    return entry
  end
  return "Unknown"
end

-- Detached party/target rows for paint and hit regions: every roster
-- slot lists with its display name, level, health, and eligibility.
-- Only kernel-projected fragments enable a row; anything else names
-- its refusal without submitting.
---@param self BattleSubflows
---@return table<string, unknown> detached party/target child view
local function partyChildView(self)
  local state = self._party
  local shell = {
    kind = self._active,
    purpose = self._purpose,
    interactive = true,
    notice = self._notice,
    cancellable = self._cancellable,
    rows = {},
    focusId = nil,
  } --[[@as table<string, unknown>]]
  if state == nil then
    return shell
  end
  local slots = state.slots --[[@as table<integer, table<string, unknown>>]]
  local fragments = state.fragments --[[@as table<integer, table<string, unknown>>]]
  local rows = {}
  for slot = 0, 5 do
    local record = slots[slot]
    local label = "Empty"
    local sub = nil
    local detail = ""
    local enabled = false
    local reason = nil
    local occupied = false
    if type(record) == "table" then
      occupied = true
      local name = record.name
      label = tostring(type(name) == "string" and name ~= "" and name or "Unknown")
      if type(record.level) == "number" then
        sub = "Lv" .. tostring(record.level)
      end
      local hp = tonumber(record.hp) or 0
      local maxHp = tonumber(record.maxHp) or 0
      detail = "HP " .. tostring(hp) .. "/" .. tostring(maxHp)
      local combatant = record.combatant
      if type(combatant) == "number" and fragments[combatant] ~= nil then
        enabled = true
        detail = detail .. " OK"
      elseif hp <= 0 then
        reason = "It is fainted."
        detail = detail .. " KO"
      else
        reason = refusalText(nil)
      end
    end
    rows[#rows + 1] = {
      id = "party:" .. tostring(slot),
      label = label,
      sub = sub,
      detail = detail,
      enabled = enabled,
      reason = reason,
      occupied = occupied,
    }
  end
  local focus = state.focus --[[@as integer|string]]
  if type(focus) == "number" then
    shell.focusId = "party:" .. tostring(focus)
  elseif focus == "cancel" then
    shell.focusId = "back"
  end
  shell.rows = rows
  return shell
end

---@param self BattleSubflows
---@param key string stocked item identity under labeling
---@return string visible item name for one stocked key
local function bagItemLabel(self, key)
  local catalog = assert(self._itemCatalog, "stocked cells resolve their catalog")
  local record = catalogItem(catalog, key)
  if type(record.name) == "string" and record.name ~= "" then
    return record.name --[[@as string]]
  end
  return key
end

-- Detached bag rows for paint and hit regions: the six visible pocket
-- cells with their catalog names, quantities, and kernel legality,
-- plus pocket identity and page facts. Empty cells stay visible but
-- never activate.
---@param self BattleSubflows
---@return table<string, unknown> detached bag child view
local function bagChildView(self)
  local bag = self._bag
  if bag == nil or bag.empty == true then
    return {
      kind = "bag",
      purpose = self._purpose,
      interactive = true,
      notice = self._notice or "The bag is empty.",
      cancellable = self._cancellable,
      rows = {},
      focusId = "back",
      pockets = {},
      currentPocket = nil,
      page = { current = 1, count = 1 },
      empty = true,
    } --[[@as table<string, unknown>]]
  end
  local cursor = bag.cursor --[[@as BagCursor]]
  local items = bag.items --[[@as table<string, table<integer, table<string, unknown>>>]]
  local pocket = cursor:currentPocket()
  local list = items[pocket]
  local count = #list
  local start = clampBagStart(count, cursor:scroll(pocket))
  local position = cursor:position(pocket)
  local selected = 0
  if count > 0 then
    selected = math.min(math.max(position, 0), count - 1)
  end
  local pageCount = math.max(1, math.ceil(count / 6))
  local pageCurrent = 1
  if count > 0 then
    pageCurrent = math.min(math.floor(selected / 6) + 1, pageCount)
  end
  local options = self:_openOptions()
  local rows = {}
  for cell = 1, 6 do
    local entry = list[start + cell]
    if entry ~= nil then
      local key = entry.item
      assert(type(key) == "string", "stocked cells carry their item key")
      local legal, reason = itemLegality(options, key)
      rows[#rows + 1] = {
        id = "bag:" .. tostring(cell - 1),
        label = bagItemLabel(self, key),
        sub = "x" .. tostring(entry.quantity or 0),
        detail = legal == true and "OK" or refusalText(reason),
        enabled = legal == true,
        reason = legal == true and nil or refusalText(reason),
      }
    else
      rows[#rows + 1] = {
        id = "bag:" .. tostring(cell - 1),
        label = "Empty",
        detail = "",
        enabled = false,
        empty = true,
      }
    end
  end
  local focusId = nil
  local node = bag.focusNode --[[@as string]]
  local absolute = parseSlotNode(node)
  if absolute ~= nil then
    focusId = "bag:" .. tostring(absolute - start)
  elseif node == "cancel" then
    focusId = "back"
  end
  local pockets = {}
  for _, pocketKey in ipairs(BagSave.POCKET_ORDER) do
    pockets[#pockets + 1] = pocketKey
  end
  return {
    kind = "bag",
    purpose = self._purpose,
    interactive = true,
    notice = self._notice,
    cancellable = self._cancellable,
    rows = rows,
    focusId = focusId,
    pockets = pockets,
    currentPocket = pocket,
    page = { current = pageCurrent, count = pageCount },
    stock = count,
  } --[[@as table<string, unknown>]]
end

-- Detached learning rows for paint and hit regions: the four held
-- moves, the decline entry, the focused row, and the staged
-- confirmation. Rows never seal on their own; taps route through the
-- same focus/confirm helpers as keyboard input.
---@param self BattleSubflows
---@return table<string, unknown>? detached learning child view, nil without its prompt
local function learnChildView(self)
  local learn = self._learn
  if learn == nil then
    return nil
  end
  local moves = learn.currentMoves --[[@as table<integer, unknown>]]
  local rows = {}
  for index = 1, 4 do
    rows[#rows + 1] = {
      id = "learn:" .. tostring(index - 1),
      label = learnMoveLabel(moves[index]),
      detail = "Replace",
      enabled = true,
    }
  end
  rows[#rows + 1] = { id = "learn:decline", label = "Decline", detail = "Keep moves", enabled = true }
  local focus = learn.focus --[[@as integer]]
  return {
    kind = "learn",
    purpose = self._purpose,
    interactive = true,
    notice = self._notice,
    cancellable = false,
    rows = rows,
    focusId = focus <= 4 and ("learn:" .. tostring(focus - 1)) or "learn:decline",
    confirmation = copyValue(learn.confirmation),
    incomingMove = learn.incomingMove,
  } --[[@as table<string, unknown>]]
end

---@return table<string, unknown> detached child status for the parent plan
function BattleSubflows:status()
  if self._disposed or self._active == nil then
    return { active = false }
  end
  local record = {
    active = true,
    kind = self._active,
    purpose = self._purpose,
    cancellable = self._cancellable,
    notice = self._notice,
    requestId = self._requestId,
    epoch = self._epoch,
    controller = self._controller,
    launchId = self._launchId,
  } --[[@as table<string, unknown>]]
  if self._stagedItem ~= nil then
    record.stagedItem = self._stagedItem
  end
  if self._learn ~= nil then
    local learn = self._learn --[[@as table<string, unknown>]]
    record.focus = learn.focus
    record.confirmation = copyValue(learn.confirmation)
    record.incomingMove = learn.incomingMove
    record.currentMoves = copyValue(learn.currentMoves)
  end
  record.childView = self:_projectChildView()
  return record
end

-- Projects the detached child view for paint and hit regions from the
-- current battle-local cursor state. Party/target rows read the picker
-- slots, focus, and projected fragments; bag rows read the browser
-- pocket window and kernel item policy; learning rows read the staged
-- prompt. Read-only snapshots only.
---@return table<string, unknown>? detached child view, nil while no child owns input
function BattleSubflows:_projectChildView()
  if self._disposed or self._active == nil then
    return nil
  end
  if self._active == "party" or self._active == "target" then
    return partyChildView(self)
  elseif self._active == "bag" then
    return bagChildView(self)
  elseif self._active == "learn" then
    return learnChildView(self)
  end
  return nil
end

---@param id string stable row/control identity under activation
---@return boolean consumed true when the tap belonged to the open child
function BattleSubflows:_activatePartyControl(id)
  if id == "back" then
    if self._active == "target" then
      cancelParty(self)
      return true
    end
    if not self._cancellable then
      self._notice = "That choice cannot be cancelled."
      return true
    end
    cancelParty(self)
    return true
  end
  local slot = tonumber(id:match("^party:(%d+)$") or "")
  if slot == nil or slot < 0 or slot > 5 then
    return false
  end
  local state = assert(self._party, "picker taps keep their picker")
  local fragments = state.fragments --[[@as table<integer, table<string, unknown>>]]
  local slots = state.slots --[[@as table<integer, table<string, unknown>>]]
  local record = slots[slot]
  local combatant = type(record) == "table" and record.combatant or nil
  local fragment = type(combatant) == "number" and fragments[combatant] or nil
  if fragment ~= nil then
    self._pending = { kind = "choice", reply = self:_bind(fragment) }
    return true
  end
  -- A visibly disabled row explains itself without submitting.
  local hp = type(record) == "table" and record.hp or nil
  if type(hp) == "number" and hp <= 0 then
    self._notice = "It is fainted."
  else
    self._notice = refusalText(nil)
  end
  return true
end

---@param id string stable row/control identity under activation
---@return boolean consumed true when the tap belonged to the open child
function BattleSubflows:_activateBagControl(id)
  local bag = self._bag
  if bag == nil then
    return false
  end
  if id == "back" then
    if not self._cancellable then
      self._notice = "That choice cannot be cancelled."
      return true
    end
    if bag.empty == true then
      self._pending = {
        kind = "cancelled",
        requestId = self._requestId,
        epoch = self._epoch,
        controller = self._controller,
        launchId = self._launchId,
      }
      return true
    end
    self._pending = {
      kind = "cancelled",
      requestId = self._requestId,
      epoch = self._epoch,
      controller = self._controller,
      launchId = self._launchId,
    }
    return true
  end
  if bag.empty == true then
    return false
  end
  if id == "pocket_prev" then
    stepPocket(self, "left")
    return true
  end
  if id == "pocket_next" then
    stepPocket(self, "right")
    return true
  end
  local cell = tonumber(id:match("^bag:(%d+)$") or "")
  if cell == nil or cell < 0 or cell > 5 then
    return false
  end
  local cursor = bag.cursor --[[@as BagCursor]]
  local items = bag.items --[[@as table<string, table<integer, table<string, unknown>>>]]
  local list = items[cursor:currentPocket()]
  local start = clampBagStart(#list, cursor:scroll(cursor:currentPocket()))
  local entry = list[start + cell + 1]
  if entry == nil then
    return true
  end
  local key = entry.item
  assert(type(key) == "string", "stocked cells carry their item key")
  local options = self:_openOptions()
  local legal, reason = itemLegality(options, key)
  if legal == true then
    self:stageItem(key)
  else
    self._notice = refusalText(reason)
  end
  return true
end

---@param id string stable row/control identity under activation
---@return boolean consumed true when the tap belonged to the open child
function BattleSubflows:_activateLearnControl(id)
  local learn = self._learn
  if learn == nil then
    return false
  end
  if id == "back" then
    cancelLearn(self)
    return true
  end
  if id == "confirm" then
    local confirmation = learn.confirmation --[[@as table<string, unknown>?]]
    if confirmation == nil then
      return true
    end
    if confirmation.kind == "stop" then
      confirmStopLearn(self)
    else
      confirmLearn(self)
    end
    return true
  end
  local tapped = nil
  local slot = tonumber(id:match("^learn:(%d+)$") or "")
  if slot ~= nil and slot >= 0 and slot <= 3 then
    tapped = slot
    learn.focus = slot + 1
  elseif id == "learn:decline" then
    tapped = "decline"
    learn.focus = 5
  else
    return false
  end
  -- Taps stage their explicit confirmation without ever sealing on
  -- their own: only the shared confirmation helper seals, exactly
  -- like the keyboard flow. Tapping another row restages instead,
  -- and tapping away from the stop prompt abandons it.
  if tapped == "decline" then
    learn.confirmation = { kind = "decline" }
  else
    learn.confirmation = { kind = "replace", slot = tapped }
  end
  return true
end

-- Routes one tap to the current bound fragments through the existing
-- bind/stage/learn helpers, never a second policy. Party and target
-- rows bind their already projected switch/item fragment, bag item
-- rows stage through the existing item path only while visible and
-- legal, and learn rows share the keyboard focus/confirm helpers. A
-- tap on a visibly disabled row shows its reason without submitting;
-- unknown ids never seal.
---@param id string stable row/control identity under activation
---@return boolean consumed true when the tap belonged to the open child
function BattleSubflows:activateControl(id)
  if self._disposed or self._active == nil or self._pending ~= nil then
    return false
  end
  assert(type(id) == "string" and id ~= "", "child taps name their control")
  if self._active == "party" or self._active == "target" then
    return self:_activatePartyControl(id)
  elseif self._active == "bag" then
    return self:_activateBagControl(id)
  elseif self._active == "learn" then
    return self:_activateLearnControl(id)
  end
  return false
end

---@return table<string, unknown>? staged bound result, exactly once
function BattleSubflows:takeResult()
  if self._disposed or self._active == nil then
    return nil
  end
  local result = self._pending
  self._pending = nil
  if result ~= nil then
    self._notice = nil
  end
  return result
end

-- Closes the active child and drops its retained browser. The battle
-- owns every cursor record, so closing only clears references without
-- sealing. Staged state clears without sealing.
function BattleSubflows:closeChild()
  self._party = nil
  self._stagedItem = nil
  self._bag = nil
  self._retained = nil
  self._learn = nil
  self._active = nil
  self._purpose = nil
  self._pending = nil
  self._notice = nil
  self._openOptionsValue = nil
  self._openPartyValue = nil
end

-- Cancels a held press through the active owner so a stale release never
-- activates after remeasure. The battle keeps no held-press state of its
-- own: press arming lives with the parent, and cursor focus and stored
-- request identity stay put.
function BattleSubflows:cancelPointerCapture() end

-- Idempotent release of the child lifetime: staged results clear, and
-- borrowed catalogs stay usable.
function BattleSubflows:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  self:closeChild()
end

return BattleSubflows
