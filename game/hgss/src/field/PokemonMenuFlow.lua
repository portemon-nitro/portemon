-- Bounded Bag/Party/Summary menu flow: the single destination the Start
-- Menu sees for its Bag and Pokemon actions, delegating to one live
-- BagScreenState, PartyScreenState, or SummaryScreenState at a time with
-- a single value-only continuation. Replacements stage fully before the
-- previous child releases; the borrowed bag cursor and both domain
-- services survive children untouched. Item writes ride PartyActions
-- alone; field eligibility answers through the injected field port, and
-- production admission of a terminal field request belongs to the host.

local BagCursor = require("libs.hgss.src.items.BagCursor")
local Mon = require("libs.mons.src.Mon")
local BagScreenState = require("game.hgss.src.field.BagScreenState")
local PartyScreenState = require("game.hgss.src.field.PartyScreenState")
local SummaryScreenState = require("game.hgss.src.field.SummaryScreenState")
local MailboxScreenState = require("game.hgss.src.pc.MailboxScreenState")
local StandardFade = require("libs.hgss.src.presentation.StandardFade")

local TERMINAL_FIELD_ACTION = "pokemon.field_move"

local function silentAudio() end

-- The complete set of pages the flow's single live child can occupy.
local PAGE = {
  BAG_BROWSE = "bag_browse",
  BAG_PICK_HELD = "bag_pick_held",
  PARTY_BROWSE = "party_browse",
  PARTY_ITEM_TARGET = "party_item_target",
  PARTY_GIVE_TARGET = "party_give_target",
  SUMMARY = "summary",
  MOVE_PICK = "move_pick",
  MAIL_READ = "mail_read",
  MAIL_CONFIRM = "mail_confirm",
  MAIL_ERASE_CONFIRM = "mail_erase_confirm",
}

---@class PokemonMenuFlow
---@field private _effect (fun(sequence: string))? the production semantic sound boundary for menu children
---@field private _playCry (fun(species: integer, pattern: integer))? the production cry boundary for summary children
---@field private _textPolicy table<string, unknown>? the copied player text-speed cadence for bag children
---@field private _root string
---@field private _mons table<string, unknown>
---@field private _bag table<string, unknown>
---@field private _bagCursor table<string, unknown>
---@field private _partyActions table<string, unknown>
---@field private _mailActions table<string, unknown>
---@field private _mailbox table<string, unknown>
---@field private _pcManifest table<string, unknown>
---@field private _fieldMoves table<string, unknown>
---@field private _assets table<string, unknown>
---@field private _measureDisplay fun(): table<string, unknown>
---@field private _prepareIcons fun(iconKeys: string[]): boolean, string? presented icon preparation (borrowed binding)
---@field private _cancelIconPreparation fun() presented preparation release (borrowed binding)
---@field private _mailOutcome table<string, unknown>? latest Party Mail result for the composed child
---@field private _summaryContext fun(): table<string, unknown>? the explicit summary display context per refresh
---@field private _readSummaryNavigation fun(): table<string, unknown>? the read-only summary navigation sample
---@field private _acquireSummaryPreparation fun(): table<string, unknown>? the per-open summary lease factory
---@field private _overrides table<string, unknown>?
---@field private _page string
---@field private _child table<string, unknown>?
---@field private _continuation table<string, unknown>?
---@field private _picker table<string, unknown>? the live temporary picker cursor
---@field private _result table<string, unknown>?
---@field private _terminalResultPending table<string, unknown>? published after the final transparent return frame
---@field private _lastChildStatus table<string, unknown>?
---@field private _transition PokemonMenuFlow.Transition?
---@field private _terminalChildStatus table<string, unknown>?
---@field private _disposed boolean
local PokemonMenuFlow = {}
PokemonMenuFlow.__index = PokemonMenuFlow

---@class PokemonMenuFlow.ReplacementTransition
---@field settled boolean? whether the full-black summary frame published
---@field kind "replacement"
---@field phase "app_exit"
---@field fade StandardFade
---@field page string
---@field continuation table<string, unknown>?
---@field child table<string, unknown>
---@field childStatus table<string, unknown>? the last drawable outgoing child status

---@class PokemonMenuFlow.TerminalTransition
---@field settled boolean? whether the full-black summary frame published
---@field kind "terminal"
---@field phase "app_exit"|"menu_return"
---@field fade StandardFade
---@field result table<string, unknown>
---@field childStatus table<string, unknown> the last drawable outgoing child status
---@field inputKey string? retained app pane role during menu return
---@field panes table[]? retained pane placements during menu return

---@alias PokemonMenuFlow.Transition PokemonMenuFlow.ReplacementTransition|PokemonMenuFlow.TerminalTransition

local function checkServices(opts)
  local mons = assert(opts.mons, "the menu flow borrows the live mon service")
  assert(type(mons.partyRevision) == "function", "the menu flow needs the party revision")
  assert(type(mons.partyMon) == "function", "the menu flow needs party reads")
  assert(type(mons.partyCount) == "function", "the menu flow needs the party count")
  local bag = assert(opts.bag, "the menu flow borrows the live bag service")
  assert(type(bag.revision) == "function", "the menu flow needs the bag revision")
  assert(type(bag.catalog) == "function", "the menu flow needs the item catalog")
  local cursor = assert(opts.bagCursor, "the menu flow borrows the field bag cursor")
  assert(type(cursor.currentPocket) == "function", "the menu flow needs the cursor pocket")
  assert(type(cursor.position) == "function", "the menu flow needs cursor positions")
  assert(type(cursor.scroll) == "function", "the menu flow needs cursor scroll")
  local actions = assert(opts.partyActions, "the menu flow borrows the action coordinator")
  assert(type(actions.preview) == "function", "the menu flow needs action previews")
  assert(type(actions.commit) == "function", "the menu flow needs action publication")
  local fieldMoves = assert(opts.fieldMoves, "the menu flow needs its field-check port")
  assert(type(fieldMoves.check) == "function", "the field port answers eligibility checks")
  return mons, bag, cursor, actions, fieldMoves
end

local function checkAssets(assets)
  assert(type(assets) == "table", "the menu flow needs its borrowed asset bundle")
  assert(type(assets.bagManifest) == "table", "the menu flow needs the bag manifest")
  assert(type(assets.partyManifest) == "table", "the menu flow needs the party manifest")
  assert(type(assets.uiManifest) == "table", "the menu flow needs the field-UI manifest")
  assert(type(assets.monCatalog) == "table", "the menu flow needs the mon catalog")
  assert(type(assets.itemCatalog) == "table", "the menu flow needs the item catalog")
  assert(assets.heroGender == "male" or assets.heroGender == "female", "the menu flow needs the hero gender")
  return assets
end

-- Production label lookup over the party manifest text with English
-- fallbacks, mirroring the standalone party composition.
---@param manifest table<string, unknown>?
---@return table<string, string>
local function partyLabels(manifest)
  local labels = {}
  if type(manifest) == "table" then
    local text = manifest.text
    if type(text) == "table" and type(text.labels) == "table" then
      for key, value in pairs(text.labels) do
        if type(value) == "string" then
          labels[key] = value
        end
      end
    end
  end
  return labels
end

-- The source party-menu move set: only these learned-move identities
-- enter the Pokemon menu, in move-slot order. Milk Drink and Softboiled
-- ride the existing HP-transfer owner; the other fourteen ride the
-- field-move path. Private to this flow: field-check and runtime lists
-- intentionally cover a different set (Defog, Escape Rope) and omit the
-- HP-transfer moves, so they never serve as menu membership here.
local PARTY_FIELD_MOVES = {
  CUT = "field_move",
  FLY = "field_move",
  SURF = "field_move",
  STRENGTH = "field_move",
  ROCK_SMASH = "field_move",
  WATERFALL = "field_move",
  ROCK_CLIMB = "field_move",
  WHIRLPOOL = "field_move",
  FLASH = "field_move",
  TELEPORT = "field_move",
  DIG = "field_move",
  SWEET_SCENT = "field_move",
  CHATTER = "field_move",
  HEADBUTT = "field_move",
  MILK_DRINK = "transfer_hp",
  SOFTBOILED = "transfer_hp",
}

-- The flow-owned party action policy: source menu order (summary, switch,
-- item-or-mail, quit, then admitted source field moves in move-slot order;
-- eggs keep summary, switch, quit), the ordinary item submenu always lists
-- give, take, quit with take answering directly. Source-level target
-- rejection lives in the Party controller; the flow keeps a trivial
-- compatible verdict. Private to this leaf; the standalone
-- production and script policies keep their own owners.
---@param manifest table<string, unknown>?
---@return table<string, unknown>
local function flowPartyPolicy(manifest)
  local labels = partyLabels(manifest)
  local function text(key, fallback)
    local label = labels[key]
    if type(label) == "string" then
      return label
    end
    return fallback
  end
  local function menuFor(facts, _)
    assert(type(facts) == "table", "party menus read slot facts")
    if facts.isEgg == true then
      return {
        { kind = PAGE.SUMMARY, label = text(PAGE.SUMMARY, "SUMMARY") },
        { kind = "switch", label = text("switch", "SWITCH") },
        { kind = "quit", label = text("quit", "QUIT") },
      }
    end
    local entries = {
      { kind = PAGE.SUMMARY, label = text(PAGE.SUMMARY, "SUMMARY") },
      { kind = "switch", label = text("switch", "SWITCH") },
    }
    if facts.heldMarkerKind == "mail" then
      entries[#entries + 1] = { kind = "mail", label = text("mail", "MAIL") }
    else
      entries[#entries + 1] = { kind = "item", label = text("item", "ITEM") }
    end
    entries[#entries + 1] = { kind = "quit", label = text("quit", "QUIT") }
    for moveSlot, move in ipairs(facts.moves or {}) do
      assert(type(move) == "table", "move rows arrive as records")
      local admission = PARTY_FIELD_MOVES[assert(move.key, "move rows carry semantic keys")]
      if admission ~= nil then
        entries[#entries + 1] = { kind = admission, label = move.key, move = move.key, moveSlot = moveSlot - 1 }
      end
    end
    return entries
  end
  local function submenuFor(facts, menuKind)
    assert(type(facts) == "table", "party submenus read slot facts")
    if menuKind == "mail" then
      return {
        { kind = "read_mail", label = text("read", "READ") },
        { kind = "take_mail", label = text("take", "TAKE"), confirm = true },
        { kind = "quit", label = text("quit", "QUIT") },
      }
    end
    assert(menuKind == "item", "party submenus stay in the closed item/mail set")
    -- The ordinary submenu always offers Give, Take, Quit in that order.
    -- Take stays direct even for empty holders; the empty result answers
    -- through the generated template at commit time.
    return {
      { kind = "give", label = text("give", "GIVE") },
      { kind = "take", label = text("take", "TAKE") },
      { kind = "quit", label = text("quit", "QUIT") },
    }
  end
  local function evaluateTarget(facts, _)
    assert(type(facts) == "table", "target evaluation reads slot facts")
    return { compatible = true }
  end
  return { menuFor = menuFor, submenuFor = submenuFor, evaluateTarget = evaluateTarget }
end

-- One-based protected move rows for the picker: rows whose current move
-- the catalog marks hidden-machine taught stay visible but rejected.
---@param mons table<string, unknown>
---@param monCatalog table<string, unknown>
---@param itemCatalog table<string, unknown>
---@param slot integer
---@return table<integer, string>
local function protectedRows(mons, monCatalog, itemCatalog, slot)
  local mon = mons:partyMon(slot)
  local moves = assert(mon.moves, "stored mons carry their moves")
  assert(type(moves) == "table", "stored mons carry their moves")
  local hmMoves = itemCatalog:hmMoveNativeIds()
  assert(type(hmMoves) == "table", "the item catalog names hidden-machine moves")
  local protected = {}
  for index, entry in ipairs(moves) do
    assert(type(entry) == "table", "stored moves carry entry records")
    local nativeId = monCatalog:move(assert(entry.move, "entries name their move")).nativeId
    assert(type(nativeId) == "number", "catalog moves carry native identities")
    if hmMoves[nativeId] == true then
      protected[index] = "hm"
    end
  end
  return protected
end

---@param opts table<string, unknown>
---@return PokemonMenuFlow
function PokemonMenuFlow.new(opts)
  assert(type(opts) == "table", "the menu flow requires its collaborators")
  assert(opts.root == "bag" or opts.root == "party", "the menu flow opens from bag or party")
  local mons, bag, cursor, actions, fieldMoves = checkServices(opts)
  local assets = checkAssets(assert(opts.assets, "the menu flow needs its borrowed asset bundle"))
  assert(type(opts.measureDisplay) == "function", "the menu flow needs the display facts")
  local prepareIcons = assert(opts.prepareIcons, "the menu flow needs its icon preparation")
  assert(type(prepareIcons) == "function", "the menu flow needs its icon preparation")
  local cancelIconPreparation = assert(opts.cancelIconPreparation, "the menu flow needs its preparation release")
  assert(type(cancelIconPreparation) == "function", "the menu flow needs its preparation release")
  assert(opts.effect == nil or type(opts.effect) == "function", "the menu flow carries an effect function")
  assert(opts.playCry == nil or type(opts.playCry) == "function", "the menu flow carries a cry function")
  assert(opts.textPolicy == nil or type(opts.textPolicy) == "table", "the menu flow carries a text policy")
  if opts.summaryContext ~= nil then
    assert(type(opts.summaryContext) == "function", "the menu flow carries its summary context")
  end
  if opts.readSummaryNavigation ~= nil then
    assert(type(opts.readSummaryNavigation) == "function", "the menu flow carries its summary navigation sample")
  end
  if opts.acquireSummaryPreparation ~= nil then
    assert(type(opts.acquireSummaryPreparation) == "function", "the menu flow carries its summary lease factory")
  end
  local self = setmetatable({
    _root = opts.root,
    _mons = mons,
    _bag = bag,
    _bagCursor = cursor,
    _partyActions = actions,
    _mailActions = assert(opts.mailActions, "the menu flow borrows Mail actions"),
    _mailbox = assert(opts.mailbox, "the menu flow borrows the Mailbox"),
    _pcManifest = assert(opts.pcManifest, "the menu flow borrows the PC manifest"),
    _fieldMoves = fieldMoves,
    _assets = assets,
    _measureDisplay = opts.measureDisplay,
    _prepareIcons = prepareIcons,
    _cancelIconPreparation = cancelIconPreparation,
    _summaryContext = opts.summaryContext,
    _readSummaryNavigation = opts.readSummaryNavigation,
    _acquireSummaryPreparation = opts.acquireSummaryPreparation,
    _effect = opts.effect,
    _playCry = opts.playCry,
    _textPolicy = opts.textPolicy,
    _overrides = opts.overrides,
    _page = opts.root == "bag" and PAGE.BAG_BROWSE or PAGE.PARTY_BROWSE,
    _child = nil,
    _continuation = nil,
    _result = nil,
    _terminalResultPending = nil,
    _lastChildStatus = nil,
    _transition = nil,
    _mailOutcome = nil,
    _terminalChildStatus = nil,
    _disposed = false,
  }, PokemonMenuFlow)
  self._child = self:_openPage(self._page, nil)
  self._lastChildStatus = assert(self._child):status()
  return self
end

-- Opens one child for a page with an optional value-only continuation
-- record. Construction failures raise before anything publishes; the
-- caller stages the replacement before releasing the previous child.
---@param page string
---@param continuation table<string, unknown>?
---@return table<string, unknown>
function PokemonMenuFlow:_openPage(page, continuation)
  local assets = self._assets
  local measureDisplay = self._measureDisplay
  if page == PAGE.BAG_BROWSE then
    return BagScreenState.new({
      service = self._bag,
      cursor = self._bagCursor,
      manifest = assets.bagManifest,
      uiManifest = assets.uiManifest,
      monCatalog = assets.monCatalog,
      heroGender = assets.heroGender,
      measureDisplay = measureDisplay,
      context = "field",
      partyEmpty = self._mons:partyCount() == 0,
      effect = self._effect,
      textPolicy = self._textPolicy,
    })
  end
  if page == PAGE.BAG_PICK_HELD then
    local cont = assert(continuation, "the held picker opens for a captured mon")
    assert(cont.slot ~= nil, "the held picker opens for a captured slot")
    return BagScreenState.new({
      service = self._bag,
      cursor = assert(self._picker, "the picker carries its temporary cursor"),
      manifest = assets.bagManifest,
      uiManifest = assets.uiManifest,
      monCatalog = assets.monCatalog,
      heroGender = assets.heroGender,
      measureDisplay = measureDisplay,
      context = "pick_held",
      partyEmpty = self._mons:partyCount() == 0,
      effect = self._effect,
      textPolicy = self._textPolicy,
    })
  end
  if page == PAGE.PARTY_BROWSE then
    local focusSlot = nil
    local initialMessage = nil
    local context = "browse"
    local item = nil
    if type(continuation) == "table" then
      focusSlot = continuation.focusSlot
      initialMessage = continuation.initialMessage
      if continuation.operation == "give_from_party" then
        context = "give_resume"
        item = {
          key = assert(continuation.itemKey, "give continuations carry their item"),
          bagRevision = assert(continuation.bagRevision, "give continuations carry their bag revision"),
        }
      end
    end
    return PartyScreenState.new({
      service = self._mons,
      manifest = assets.partyManifest,
      actionPolicy = flowPartyPolicy(assets.partyManifest),
      uiManifest = assets.uiManifest,
      context = context,
      item = item,
      initialFocus = focusSlot,
      initialMessage = initialMessage,
      measureDisplay = measureDisplay,
      prepareIcons = self._prepareIcons,
      cancelIconPreparation = self._cancelIconPreparation,
      effect = self._effect,
    })
  end
  if page == PAGE.PARTY_ITEM_TARGET or page == PAGE.PARTY_GIVE_TARGET then
    local cont = assert(continuation, "target pages open for a captured item")
    local itemKey = assert(cont.itemKey, "target pages carry the item key")
    local context = page == PAGE.PARTY_ITEM_TARGET and "item_target" or "give_target"
    local targetPromptKey = "giveTarget"
    if page == PAGE.PARTY_ITEM_TARGET then
      if self:_useKind(itemKey) == "machine" then
        targetPromptKey = "teachTarget"
      else
        targetPromptKey = "useTarget"
      end
    end
    return PartyScreenState.new({
      service = self._mons,
      manifest = assets.partyManifest,
      actionPolicy = flowPartyPolicy(assets.partyManifest),
      uiManifest = assets.uiManifest,
      context = context,
      targetPromptKey = targetPromptKey,
      item = {
        key = itemKey,
        bagRevision = assert(cont.bagRevision, "target pages carry the bag revision"),
      },
      measureDisplay = measureDisplay,
      prepareIcons = self._prepareIcons,
      cancelIconPreparation = self._cancelIconPreparation,
      effect = self._effect,
    })
  end
  if page == PAGE.SUMMARY then
    local cont = assert(continuation, "the summary opens for a captured slot")
    return SummaryScreenState.new({
      mons = self._mons,
      manifest = assert(assets.summaryManifest, "presented summaries require the summary family"),
      initialSlot = assert(cont.slot, "the summary opens on a party slot"),
      measureDisplay = measureDisplay,
      mode = PAGE.SUMMARY,
      context = assert(self._summaryContext, "presented summaries require their display context"),
      readNavigation = assert(self._readSummaryNavigation, "presented summaries require their navigation sample"),
      acquirePreparation = assert(self._acquireSummaryPreparation, "presented summaries require preparation"),
      effect = self._effect,
      playCry = self._playCry,
      textPolicy = self._textPolicy,
      overrides = self._overrides,
    })
  end
  if page == PAGE.MOVE_PICK then
    local cont = assert(continuation, "the move picker opens for a pending operation")
    return SummaryScreenState.new({
      mons = self._mons,
      manifest = assert(assets.summaryManifest, "presented pickers require the summary family"),
      initialSlot = assert(cont.slot, "the picker opens on the pending slot"),
      measureDisplay = measureDisplay,
      mode = PAGE.MOVE_PICK,
      request = assert(cont.pickerRequest, "the picker carries its closed request"),
      context = assert(self._summaryContext, "presented pickers require their display context"),
      readNavigation = assert(self._readSummaryNavigation, "presented pickers require their navigation sample"),
      acquirePreparation = assert(self._acquireSummaryPreparation, "presented pickers require preparation"),
      effect = self._effect,
      playCry = self._playCry,
      textPolicy = self._textPolicy,
      overrides = self._overrides,
    })
  end
  if page == PAGE.MAIL_READ then
    local cont = assert(continuation, "the read view carries an authored letter copy")
    return MailboxScreenState.new({
      mode = "read",
      letter = assert(cont.letter),
      manifest = self._pcManifest,
      monCatalog = self._assets.monCatalog,
      measureDisplay = measureDisplay,
      audio = { play = silentAudio },
    })
  end
  if page == PAGE.MAIL_CONFIRM or page == PAGE.MAIL_ERASE_CONFIRM then
    assert(continuation, "the Mail confirmation retains its operation intent")
    return MailboxScreenState.new({
      mode = "confirm",
      prompt = page == PAGE.MAIL_CONFIRM and "Send this letter to the PC?"
        or "Erase this letter and return its stationery?",
      manifest = self._pcManifest,
      measureDisplay = measureDisplay,
      audio = { play = silentAudio },
    })
  end
  error("unknown menu flow page " .. tostring(page), 0)
end

---@param slot integer
---@param itemKey string
---@return { templateKey: "giveHeldItem", displayName: string, itemNames: string[] }
function PokemonMenuFlow:_giveHeldItemMessage(slot, itemKey)
  local mon = self._mons:partyMon(slot)
  local item = self._assets.itemCatalog:item(itemKey)
  local itemName = assert(item.name, "the item catalog publishes its display name")
  return {
    templateKey = "giveHeldItem",
    displayName = Mon.displayName(mon, self._mons:catalog()),
    itemNames = { itemName },
  }
end

-- A separate temporary picker cursor seeded from the field cursor: pocket
-- navigation inside the picker never disturbs the borrowed cursor until a
-- pick completes ordinarily.
---@return table<string, unknown>
function PokemonMenuFlow:_pickerCursor()
  local field = self._bagCursor
  local pocket = field:currentPocket()
  local picker = BagCursor.new()
  picker:setPocket(pocket)
  picker:setPosition(pocket, field:position(pocket))
  picker:setScroll(pocket, field:scroll(pocket))
  return picker
end

-- Writes picker navigation back onto the borrowed cursor. Only a retired
-- picker qualifies, and only after its replacement stages: retryable
-- refusals keep their owner, and cancellation and failed construction
-- leave the borrowed cursor untouched.
---@param picker table<string, unknown>
function PokemonMenuFlow:_adoptPickerCursor(picker)
  local pocket = picker:currentPocket()
  self._bagCursor:setPocket(pocket)
  self._bagCursor:setPosition(pocket, picker:position(pocket))
  self._bagCursor:setScroll(pocket, picker:scroll(pocket))
end

-- Stages a replacement before the outgoing fade, then publishes it at full
-- black and releases the outgoing child exactly once. The replacement never
-- sees the launching batch. A focusSlot-only continuation carries navigation
-- focus without operation identity.
---@param page string
---@param continuation table<string, unknown>?
function PokemonMenuFlow:_replace(page, continuation)
  assert(self._transition == nil, "menu replacements cannot overlap an app transition")
  local previous = assert(self._child, "replacement retires a live child")
  local replacement = self:_openPage(page, continuation)
  local currentStatus = previous:status()
  local outgoingStatus = currentStatus.open == true and currentStatus.presentation ~= nil and currentStatus
    or self._lastChildStatus
    or currentStatus
  previous:cancelPointerCapture()
  self._transition = {
    kind = "replacement",
    phase = "app_exit",
    fade = StandardFade.new({ direction = "out", color = 0 }),
    page = page,
    continuation = continuation,
    child = replacement,
    childStatus = outgoingStatus,
  }
end

-- A continuation stays valid only while both captured revisions still
-- match the live owners; anything else discards the operation safely.
---@param continuation table<string, unknown>?
---@return boolean
function PokemonMenuFlow:_continuationCurrent(continuation)
  if type(continuation) ~= "table" then
    return false
  end
  return self._mons:partyRevision() == continuation.partyRevision and self._bag:revision() == continuation.bagRevision
end

-- Reopens the recorded return page after an invalidated continuation or
-- a refused commit, clearing the operation. The borrowed cursor and both
-- revisions are reread live, so the rebuilt child cannot replay stale
-- identity.
---@param continuation table<string, unknown>
function PokemonMenuFlow:_rewind(continuation)
  local returnPage = continuation.returnPage
  assert(returnPage == PAGE.BAG_BROWSE or returnPage == PAGE.PARTY_BROWSE, "continuations return to a root browse page")
  self._picker = nil
  self:_replace(returnPage, nil)
end

-- Maps the expected empty-take outcome onto the generated template
-- descriptor the party message state expands; every other outcome
-- completes as its own kind. The empty template names the acting mon,
-- so the descriptor carries the same nickname-or-species name the party
-- screen shows for that slot.
---@param outcome table<string, unknown>
---@param displayName string
---@return table<string, unknown>
local function takeCompletion(outcome, displayName)
  assert(type(outcome) == "table", "take outcomes arrive as records")
  if outcome.kind == "no_effect" then
    assert(type(displayName) == "string", "empty takes name the acting mon")
    return { kind = outcome.kind, message = { templateKey = "takeNoItem", displayName = displayName } }
  end
  return { kind = outcome.kind }
end

-- Completes a parked party intent with a publication outcome; the child
-- shows carried text or a template descriptor and otherwise returns
-- silently to its origin.
---@param outcome table<string, unknown>
function PokemonMenuFlow:_completeParty(outcome)
  local child = assert(self._child, "completion answers the live child")
  assert(self._page ~= PAGE.BAG_BROWSE and self._page ~= PAGE.BAG_PICK_HELD, "party outcomes answer party children")
  child:completeAction(outcome)
end

-- Reads the catalog party-use kind for routing: machines teach, every
-- other cataloged effect heals through the item path.
---@param itemKey string
---@return string
function PokemonMenuFlow:_useKind(itemKey)
  local definition = self._assets.itemCatalog:item(itemKey)
  local partyUse = definition.partyUse
  if type(partyUse) == "table" and type(partyUse.kind) == "string" then
    return partyUse.kind
  end
  return "none"
end

-- Routes a bag intent into its party target page with a captured
-- continuation. The launching batch stays with the retired bag child.
---@param intent table<string, unknown>
function PokemonMenuFlow:_routeBagIntent(intent)
  assert(intent.kind == "use" or intent.kind == "give", "bag intents use or give")
  local itemKey = assert(intent.item, "bag intents snapshot their item")
  local operation = intent.kind == "use" and "use" or "give"
  local page = intent.kind == "use" and PAGE.PARTY_ITEM_TARGET or PAGE.PARTY_GIVE_TARGET
  self:_replace(page, {
    root = self._root,
    returnPage = PAGE.BAG_BROWSE,
    operation = operation,
    itemKey = itemKey,
    bagRevision = assert(intent.bagRevision, "bag intents snapshot the bag revision"),
    partyRevision = self._mons:partyRevision(),
  })
end

-- Routes a picker pick: the exchange previews without confirmation
-- first, so the action owner decides whether the pick needs the
-- replacement question. Retryable refusals hold the picker open with its
-- owner intact; a handled selection retires the picker only after its
-- replacement stages, and success returns to the captured party slot.
---@param intent table<string, unknown>
function PokemonMenuFlow:_routePick(intent)
  local continuation = assert(self._continuation, "picks resolve a captured mon")
  assert(continuation.operation == "give_from_party", "picks resolve party give operations")
  if not self:_continuationCurrent(continuation) then
    self:_rewind(continuation)
    return
  end
  local request = {
    kind = "give",
    slot = assert(continuation.slot, "give operations capture their slot"),
    partyRevision = assert(continuation.partyRevision, "give operations capture the party revision"),
    bagRevision = assert(intent.bagRevision, "picks snapshot the bag revision"),
    item = assert(intent.item, "picks snapshot their item"),
  }
  local decision = self._partyActions:preview(request)
  if decision.kind ~= "ready" and decision.kind ~= "needs_confirmation" then
    return
  end
  local slot = assert(continuation.slot, "give operations capture their slot")
  local staged = {
    root = self._root,
    returnPage = PAGE.PARTY_BROWSE,
    operation = "give_from_party",
    slot = slot,
    focusSlot = slot,
    itemKey = request.item,
    partyRevision = request.partyRevision,
    bagRevision = request.bagRevision,
  }
  self:_replace(PAGE.PARTY_BROWSE, {
    root = staged.root,
    returnPage = staged.returnPage,
    operation = staged.operation,
    slot = staged.slot,
    focusSlot = staged.focusSlot,
    itemKey = staged.itemKey,
    partyRevision = staged.partyRevision,
    bagRevision = staged.bagRevision,
  })
  local picker = assert(self._picker, "the picker holds its temporary cursor")
  self:_adoptPickerCursor(picker)
  self._picker = nil
end

-- Routes a party target selection for a bag-originated operation: the
-- item identity rides the continuation, the mon rides the intent.
---@param intent table<string, unknown>
function PokemonMenuFlow:_routeTargetIntent(intent)
  local continuation = assert(self._continuation, "target selections resolve a captured item")
  local operation = assert(continuation.operation, "continuations name their operation")
  assert(operation == "use" or operation == "give", "target selections resolve bag operations")
  if not self:_continuationCurrent(continuation) then
    self:_rewind(continuation)
    return
  end
  local itemKey = assert(continuation.itemKey, "bag operations capture their item")
  if operation == "give" then
    if intent.confirmed == true then
      continuation.slot = assert(intent.slot, "confirmed target requests name their slot")
      continuation.partyRevision = assert(intent.partyRevision, "confirmed target requests carry their party revision")
      continuation.bagRevision = assert(intent.bagRevision, "confirmed target requests carry their bag revision")
      self:_routeGiveIntent(intent)
      return
    end
    -- Initial selections never claim confirmation: the preview decides
    -- whether the exchange needs the replacement question.
    local request = {
      kind = "give",
      slot = assert(intent.slot, "target selections name their slot"),
      partyRevision = assert(intent.partyRevision, "target selections carry the party revision"),
      bagRevision = assert(intent.bagRevision, "target selections carry the bag revision"),
      item = itemKey,
    }
    local decision = self._partyActions:preview(request)
    local slot = assert(intent.slot, "target selections name their slot")
    continuation.slot = slot
    continuation.partyRevision = assert(intent.partyRevision, "target selections carry the party revision")
    continuation.bagRevision = assert(intent.bagRevision, "target selections carry the bag revision")
    local displayName = Mon.displayName(self._mons:partyMon(slot), self._mons:catalog())
    if decision.kind == "needs_confirmation" then
      local heldKey = assert(self._mons:partyMon(slot).heldItem, "the target mon carries its held item")
      local heldItem = self._assets.itemCatalog:item(heldKey)
      local heldItemName = assert(heldItem.name, "the item catalog publishes its display name")
      self:_completeParty({
        kind = "needs_confirmation",
        disposition = "bag",
        message = {
          templateKey = "switchHeldPrompt",
          displayName = displayName,
          itemNames = { heldItemName },
        },
      })
      return
    end
    if decision.kind ~= "ready" then
      self:_completeParty({ kind = decision.kind, disposition = "bag" })
      return
    end
    local outcome = self._partyActions:commit(request)
    self:_completeParty(self:_giveCompletion(outcome, slot, itemKey, "bag"))
    return
  end
  if self:_useKind(itemKey) == "machine" then
    self:_routeTeach(intent, continuation, itemKey)
    return
  end
  self:_routeUse(intent, continuation, itemKey)
end

-- Resolves a held-item request through PartyActions and sends only
-- presentation data back to the Party child.
---@param intent table<string, unknown>
function PokemonMenuFlow:_routeGiveIntent(intent)
  local continuation = assert(self._continuation, "held-item requests carry their caller")
  local slot = assert(continuation.slot, "held-item requests capture their slot")
  if not self:_continuationCurrent(continuation) then
    if continuation.returnPage == PAGE.BAG_BROWSE then
      self:_rewind(continuation)
    else
      self:_completeParty({ kind = "stale", disposition = "party" })
    end
    return
  end
  local request = {
    kind = "give",
    slot = assert(intent.slot, "held-item requests name their slot"),
    partyRevision = assert(intent.partyRevision, "held-item requests carry their party revision"),
    bagRevision = assert(intent.bagRevision, "held-item requests carry their bag revision"),
    item = assert(intent.item, "held-item requests name their item"),
    confirmed = intent.confirmed == true or nil,
  }
  assert(request.slot == slot, "held-item continuation keeps its original slot")
  assert(request.item == continuation.itemKey, "held-item continuation keeps its picked item")
  local decision = self._partyActions:preview(request)
  local disposition = continuation.returnPage == PAGE.PARTY_BROWSE and "party" or "bag"
  if decision.kind == "needs_confirmation" then
    local oldKey = assert(self._mons:partyMon(slot).heldItem, "the target mon carries its held item")
    local oldItem = self._assets.itemCatalog:item(oldKey)
    local oldItemName = assert(oldItem.name, "the item catalog publishes its display name")
    local displayName = Mon.displayName(self._mons:partyMon(slot), self._mons:catalog())
    self:_completeParty({
      kind = "needs_confirmation",
      disposition = disposition,
      message = {
        templateKey = "switchHeldPrompt",
        displayName = displayName,
        itemNames = { oldItemName },
      },
    })
    return
  end
  if decision.kind ~= "ready" then
    self:_completeParty({ kind = decision.kind, disposition = disposition })
    return
  end
  local outcome = self._partyActions:commit(request)
  self:_completeParty(self:_giveCompletion(outcome, slot, request.item, disposition))
end

---@param outcome table<string, unknown>
---@param slot integer
---@param itemKey string
---@param disposition "party"|"bag"
---@return table<string, unknown>
function PokemonMenuFlow:_giveCompletion(outcome, slot, itemKey, disposition)
  ---@type table<string, unknown>
  local completion = { kind = outcome.kind, disposition = disposition }
  if outcome.kind == "changed" then
    local item = self._assets.itemCatalog:item(itemKey)
    local message
    if type(outcome.before) == "table" and outcome.before.heldItem ~= "NONE" then
      local oldItem = self._assets.itemCatalog:item(outcome.before.heldItem)
      local oldItemName = assert(oldItem.name, "the item catalog publishes its display name")
      local newItemName = assert(item.name, "the item catalog publishes its display name")
      message = {
        templateKey = "switchHeldResult",
        displayName = Mon.displayName(self._mons:partyMon(slot), self._mons:catalog()),
        itemNames = { oldItemName, newItemName },
      }
    else
      message = self:_giveHeldItemMessage(slot, itemKey)
    end
    completion.message = message
  elseif outcome.kind == "bag_full" then
    completion.message = { templateKey = "bagFull" }
  end
  return completion
end

-- Routes a medicine/effect use: preview first, commit ready outcomes with
-- a visible completion, detour power-point choices through the picker,
-- and report refusals without publishing or consuming.
---@param intent table<string, unknown>
---@param continuation table<string, unknown>
---@param itemKey string
function PokemonMenuFlow:_routeUse(intent, continuation, itemKey)
  local slot = assert(intent.slot, "target selections name their slot")
  local request = {
    kind = "use_item",
    slot = slot,
    partyRevision = assert(intent.partyRevision, "target selections carry the party revision"),
    bagRevision = assert(intent.bagRevision, "target selections carry the bag revision"),
    item = itemKey,
  }
  local decision = self._partyActions:preview(request)
  if decision.kind == "stale" then
    self:_rewind(continuation)
    return
  end
  if decision.kind == "needs_move" then
    local definition = self._assets.itemCatalog:item(itemKey)
    local partyUse = assert(definition.partyUse, "usable items carry their effect")
    assert(type(partyUse) == "table", "usable items carry their effect")
    local context = "pp_restore"
    if partyUse.boost ~= nil then
      context = "pp_up"
    end
    continuation.operation = "use_move"
    continuation.slot = slot
    continuation.pickerRequest = { context = context }
    self:_replace(PAGE.MOVE_PICK, continuation)
    return
  end
  if decision.kind ~= "ready" then
    self:_completeParty({ kind = decision.kind })
    return
  end
  local outcome = self._partyActions:commit(request)
  self:_completeParty({ kind = outcome.kind })
end

-- Resolves the move the selected machine would teach: the item record
-- names its native move identity, the mon catalog folds it to the stored
-- move key, and the picker previews that key without owning it.
---@param itemKey string
---@return string move key behind the machine
function PokemonMenuFlow:_teachingMove(itemKey)
  local definition = self._assets.itemCatalog:item(itemKey)
  local nativeId = assert(definition.tmhmMoveNativeId, "machines carry their native move identity")
  assert(type(nativeId) == "number", "machine move identities are numeric")
  return self._assets.monCatalog:moveKeyByNativeId(nativeId)
end

-- Routes a machine use: free slots commit at once, full sets detour
-- through the protected picker, and known/incompatible sets report
-- without publishing or consuming.
---@param intent table<string, unknown>
---@param continuation table<string, unknown>
---@param itemKey string
function PokemonMenuFlow:_routeTeach(intent, continuation, itemKey)
  local slot = assert(intent.slot, "target selections name their slot")
  local request = {
    kind = "teach_move",
    slot = slot,
    partyRevision = assert(intent.partyRevision, "target selections carry the party revision"),
    bagRevision = assert(intent.bagRevision, "target selections carry the bag revision"),
    item = itemKey,
  }
  local decision = self._partyActions:preview(request)
  if decision.kind == "stale" then
    self:_rewind(continuation)
    return
  end
  if decision.kind == "needs_replacement" then
    continuation.operation = "teach_pick"
    continuation.slot = slot
    continuation.pickerRequest = {
      context = "replace_machine",
      protected = protectedRows(self._mons, self._assets.monCatalog, self._assets.itemCatalog, slot),
      prospectiveMove = self:_teachingMove(itemKey),
    }
    self:_replace(PAGE.MOVE_PICK, continuation)
    return
  end
  if decision.kind ~= "ready" then
    self:_completeParty({ kind = decision.kind })
    return
  end
  local outcome = self._partyActions:commit(request)
  self:_completeParty({ kind = outcome.kind })
end

-- Resolves a move-picker selection for a pending power-point or teaching
-- operation: revision-qualified commit, then home to the return page. A
-- stale pick rewinds instead of publishing.
---@param result table<string, unknown>
function PokemonMenuFlow:_resolveMovePick(result)
  local continuation = assert(self._continuation, "move picks resolve a pending operation")
  local operation = assert(continuation.operation, "continuations name their operation")
  assert(operation == "use_move" or operation == "teach_pick", "move picks resolve item operations")
  if not self:_continuationCurrent(continuation) then
    self:_rewind(continuation)
    return
  end
  local kind = operation == "use_move" and "use_item" or "teach_move"
  local request = {
    kind = kind,
    slot = assert(continuation.slot, "pending operations capture their slot"),
    partyRevision = assert(result.partyRevision, "picks carry the party revision"),
    bagRevision = assert(continuation.bagRevision, "pending operations capture the bag revision"),
    item = assert(continuation.itemKey, "pending operations capture their item"),
    moveSlot = assert(result.moveSlot, "picks name their move row"),
  }
  local outcome = self._partyActions:commit(request)
  if outcome.kind ~= "changed" then
    self:_rewind(continuation)
    return
  end
  self:_replace(assert(continuation.returnPage, "continuations name their return page"), nil)
end

-- Routes a party browse intent: summary opens read-only, give without an
-- item opens the held picker for the captured mon, take publishes in
-- place, and field entries check before leaving the application.
---@param intent table<string, unknown>
function PokemonMenuFlow:_routeBrowseIntent(intent)
  if intent.kind == PAGE.SUMMARY then
    local slot = assert(intent.slot, "summary intents name their slot")
    self:_replace(PAGE.SUMMARY, {
      root = self._root,
      returnPage = PAGE.PARTY_BROWSE,
      operation = PAGE.SUMMARY,
      slot = slot,
      partyRevision = self._mons:partyRevision(),
      bagRevision = self._bag:revision(),
    })
    return
  end
  if intent.kind == "give" then
    assert(intent.item == nil, "browse give names no item yet")
    local slot = assert(intent.slot, "give intents name their slot")
    self._picker = self:_pickerCursor()
    self:_replace(PAGE.BAG_PICK_HELD, {
      root = self._root,
      returnPage = PAGE.PARTY_BROWSE,
      operation = "give_from_party",
      slot = slot,
      partyRevision = assert(intent.partyRevision, "give intents carry the party revision"),
      bagRevision = self._bag:revision(),
    })
    return
  end
  if intent.kind == "take" then
    local slot = assert(intent.slot, "take intents name their slot")
    local outcome = self._partyActions:commit({
      kind = "take",
      slot = slot,
      partyRevision = assert(intent.partyRevision, "take intents carry the party revision"),
      bagRevision = self._bag:revision(),
    })
    self:_completeParty(takeCompletion(outcome, Mon.displayName(self._mons:partyMon(slot), self._mons:catalog())))
    return
  end
  if intent.kind == "transfer_hp" then
    local outcome = self._partyActions:commit({
      kind = "transfer_hp",
      slot = assert(intent.slot, "transfer intents name their donor slot"),
      targetSlot = assert(intent.targetSlot, "transfer intents name their target slot"),
      moveSlot = intent.moveSlot,
      partyRevision = assert(intent.partyRevision, "transfer intents carry the party revision"),
      bagRevision = self._bag:revision(),
    })
    self:_completeParty({ kind = outcome.kind })
    return
  end
  if intent.kind == "field_move" then
    self:_routeFieldMove(intent)
    return
  end
  if intent.kind == "read_mail" then
    local slot = assert(intent.slot, "Mail reads name their party slot")
    local decision = self._mailActions:preview({
      kind = "readParty",
      slot = slot,
      partyRevision = self._mons:partyRevision(),
    })
    if decision.kind ~= "ready" then
      self:_completeParty({ kind = "mail_refused", reason = decision.reason })
      return
    end
    self:_replace(PAGE.MAIL_READ, { letter = decision.letter, focusSlot = slot })
    return
  end
  if intent.kind == "take_mail" then
    local slot = assert(intent.slot, "Mail sends name their party slot")
    local operation = {
      kind = "sendPartyToMailbox",
      slot = slot,
      partyRevision = self._mons:partyRevision(),
      mailboxRevision = self._mailbox:revision(),
    }
    local decision = self._mailActions:preview(operation)
    if decision.kind ~= "confirm" then
      self:_completeParty({ kind = "mail_refused", reason = decision.reason })
      return
    end
    self:_replace(PAGE.MAIL_CONFIRM, { intent = decision, focusSlot = slot })
    return
  end
  error("unknown party browse intent " .. tostring(intent.kind), 0)
end

-- Checks one field entry before leaving the application: executable
-- checks emit the typed terminal handoff, the checked Fly branch restores
-- silently inside Party, and refusals hold the screen without publishing.
---@param intent table<string, unknown>
function PokemonMenuFlow:_routeFieldMove(intent)
  -- Party menu entries spell moves like the stored mon record (FLY);
  -- eligibility, admission, and the terminal handoff speak field-move
  -- keys (fly). Fold once at intake so every downstream owner agrees.
  local moveKey = assert(intent.move, "field intents name their move")
  assert(type(moveKey) == "string", "field intents name their move key")
  local move = string.lower(moveKey)
  local decision = self._fieldMoves.check({
    move = move,
    slot = assert(intent.slot, "field intents name their slot"),
    moveSlot = intent.moveSlot,
    partyRevision = self._mons:partyRevision(),
  })
  assert(type(decision) == "table" and type(decision.kind) == "string", "field checks answer decisions")
  if move == "fly" and decision.kind == "ok" then
    -- Fly: hand the selected party slot to Town Map when that application is available.
    local child = assert(self._child, "fly restores the live party child")
    child:cancelPointerCapture()
    child:completeAction({ kind = "no_op" })
    return
  end
  if decision.kind == "ok" then
    self:_terminate({
      kind = "field_action",
      actionId = TERMINAL_FIELD_ACTION,
      request = {
        move = move,
        slot = assert(intent.slot, "field intents name their slot"),
        moveSlot = intent.moveSlot,
      },
    })
    return
  end
  self:_completeParty({ kind = decision.kind })
end

-- Routes a summary result: a returned member reopens Party on the live
-- displayed slot, a move pick resolves its pending operation, and a
-- cancellation returns to the pending target page.
---@param result table<string, unknown>
function PokemonMenuFlow:_routeSummaryResult(result)
  if result.kind == "return" then
    local slot = assert(result.slot, "summary returns name their member")
    self:_replace(PAGE.PARTY_BROWSE, { focusSlot = slot })
    self._continuation = nil
    return
  end
  if result.kind == "move_selected" then
    self:_resolveMovePick(result)
    return
  end
  assert(result.kind == "cancelled", "summaries return, pick, or cancel")
  local continuation = assert(self._continuation, "cancellation returns to a pending operation")
  local operation = assert(continuation.operation, "continuations name their operation")
  if operation == PAGE.SUMMARY then
    local slot = assert(continuation.slot, "summary opens on a slot")
    local focus = nil
    if type(slot) == "number" and slot >= 0 and slot < self._mons:partyCount() then
      focus = slot
    end
    self:_replace(PAGE.PARTY_BROWSE, { focusSlot = focus })
    self._continuation = nil
    return
  end
  self:_replace(PAGE.PARTY_ITEM_TARGET, continuation)
end

-- Routes one drained child intent by its kind and the active page. Bag
-- picks resolve captured mons; party target selections resolve captured
-- items; browse intents open or publish; anything else fails loudly.
---@param intent table<string, unknown>
function PokemonMenuFlow:_routeIntent(intent)
  assert(type(intent) == "table" and type(intent.kind) == "string", "intents carry their kind")
  if self._page == PAGE.BAG_BROWSE and (intent.kind == "use" or intent.kind == "give") then
    self:_routeBagIntent(intent)
    return
  end
  if self._page == PAGE.BAG_PICK_HELD and intent.kind == "pick" then
    self:_routePick(intent)
    return
  end
  if (self._page == PAGE.PARTY_ITEM_TARGET or self._page == PAGE.PARTY_GIVE_TARGET) and intent.kind == "use_item" then
    self:_routeTargetIntent(intent)
    return
  end
  if (self._page == PAGE.PARTY_ITEM_TARGET or self._page == PAGE.PARTY_GIVE_TARGET) and intent.kind == "give" then
    self:_routeTargetIntent(intent)
    return
  end
  if self._page == PAGE.PARTY_BROWSE then
    if self._continuation ~= nil and self._continuation.operation == "give_from_party" and intent.kind == "give" then
      self:_routeGiveIntent(intent)
      return
    end
    self:_routeBrowseIntent(intent)
    return
  end
  error("intent " .. tostring(intent.kind) .. " cannot arrive on page " .. tostring(self._page), 0)
end

-- Routes one drained child result. Closes on the root page terminate to
-- the menu; closes and target declines on nested pages unwind one
-- operation to the recorded return page; summary records resolve through
-- their own router.
---@param result table<string, unknown>
function PokemonMenuFlow:_routeResult(result)
  assert(type(result) == "table" and type(result.kind) == "string", "results carry their kind")
  if self._page == PAGE.MAIL_READ then
    assert(result.kind == "closed", "the read-only letter view closes without mutation")
    local continuation = assert(self._continuation, "the Mail read view retains its party context")
    self:_replace(PAGE.PARTY_BROWSE, { focusSlot = continuation.focusSlot })
    return
  end
  if self._page == PAGE.MAIL_CONFIRM then
    local continuation = assert(self._continuation, "the send confirmation retains the pending request")
    if result.kind == "confirmed" then
      self._mailOutcome = self._mailActions:commit(continuation.intent, true)
    else
      assert(result.kind == "declined", "the Mail send offer is confirmed or declined")
      self._mailActions:commit(continuation.intent, false)
      local erase = self._mailActions:preview({
        kind = "erasePartyMessage",
        slot = continuation.focusSlot,
        partyRevision = self._mons:partyRevision(),
        bagRevision = self._bag:revision(),
      })
      if erase.kind == "confirm" then
        self:_replace(PAGE.MAIL_ERASE_CONFIRM, { intent = erase, focusSlot = continuation.focusSlot })
        return
      end
      self._mailOutcome = erase
    end
    self:_replace(PAGE.PARTY_BROWSE, { focusSlot = continuation.focusSlot })
    return
  end
  if self._page == PAGE.MAIL_ERASE_CONFIRM then
    local continuation = assert(self._continuation, "the Mail erase confirmation retains its pending request")
    if result.kind == "confirmed" then
      self._mailOutcome = self._mailActions:commit(continuation.intent, true)
    else
      assert(result.kind == "declined", "the Mail erase offer is confirmed or declined")
      self._mailOutcome = self._mailActions:commit(continuation.intent, false)
    end
    self:_replace(PAGE.PARTY_BROWSE, { focusSlot = continuation.focusSlot })
    return
  end
  if self._page == PAGE.PARTY_BROWSE and result.kind == "give_complete" then
    local continuation = assert(self._continuation, "Party completion clears its held-item continuation")
    assert(continuation.operation == "give_from_party", "Party completion belongs to the held-item operation")
    self._continuation = nil
    return
  end
  if self._page == PAGE.SUMMARY or self._page == PAGE.MOVE_PICK then
    self:_routeSummaryResult(result)
    return
  end
  if self._page == PAGE.BAG_BROWSE and self._root == "bag" then
    assert(result.kind == "close", "the root bag reports close")
    self:_terminate({ kind = "close" })
    return
  end
  if self._page == PAGE.PARTY_BROWSE and self._root == "party" then
    assert(result.kind == "close", "the root party reports close")
    self:_terminate({ kind = "close" })
    return
  end
  assert(result.kind == "close" or result.kind == "cancelled", "nested children close or decline their selection")
  local continuation = assert(self._continuation, "nested closes unwind a captured caller")
  self:_rewind(continuation)
end

-- Stages a terminal handoff with the last drawable child status. Root close
-- returns through the menu reveal; field actions publish at app closure.
---@param result table<string, unknown>
function PokemonMenuFlow:_terminate(result)
  assert(self._transition == nil, "menu termination cannot overlap an app transition")
  local child = assert(self._child, "termination retires a live child")
  child:cancelPointerCapture()
  self._transition = {
    kind = "terminal",
    phase = "app_exit",
    fade = StandardFade.new({ direction = "out", color = 0 }),
    result = result,
    childStatus = self._lastChildStatus or child:status(),
  }
end

-- Drains one intent from bag and party children; summaries answer
-- through results alone.
---@return table<string, unknown>?
function PokemonMenuFlow:_takeIntent()
  local child = assert(self._child, "intents drain from a live child")
  if self._page == PAGE.SUMMARY or self._page == PAGE.MOVE_PICK then
    return nil
  end
  return child:takeIntent()
end

---@param record table<string, unknown>
---@return table<string, unknown>
local function copyPresentationFacts(record)
  local copy = {}
  for key, value in pairs(record) do
    if type(value) == "table" then
      copy[key] = copyPresentationFacts(value)
    else
      copy[key] = value
    end
  end
  return copy
end

-- One fixed tick: the active child owns the batch, then one drained
-- intent or result routes exactly once. A replacement never sees the
-- launching batch; a terminal result ends input ownership.
---@param uiInput table[]
function PokemonMenuFlow:updateFixed(uiInput)
  assert(not self._disposed, "a disposed menu flow steps nothing")
  if self._result ~= nil then
    return
  end
  assert(type(uiInput) == "table", "the menu flow steps on an event list")
  if self._terminalResultPending ~= nil then
    self._result = self._terminalResultPending
    self._terminalResultPending = nil
    self._transition = nil
    return
  end
  if self._transition ~= nil then
    for _, event in ipairs(uiInput) do
      assert(type(event) == "table" and type(event.type) == "string", "menu events carry their type")
    end
    local transition = assert(self._transition, "active transitions remain published until completion")
    local fade = assert(transition.fade, "outgoing transitions own their standard fade")
    if transition.phase == "menu_return" then
      fade:updateSourceFrame()
      if fade.completed then
        self._terminalResultPending = transition.result
      end
      return
    end
    assert(transition.phase == "app_exit", "menu transition phase is recognized")
    local outgoing = assert(self._child, "app exit keeps its outgoing child alive")
    local childStatus = assert(transition.childStatus, "app exit retains the outgoing child status")
    local currentPlan = childStatus.presentation
    local currentInputKey = type(currentPlan) == "table" and currentPlan.inputKey or nil
    if
      currentInputKey == "bag"
      or currentInputKey == "bag-inactive"
      or currentInputKey == "party"
      or currentInputKey == "party-inactive"
    then
      local presentation = outgoing:refreshPresentation(childStatus)
      childStatus = {}
      for key, value in pairs(transition.childStatus) do
        childStatus[key] = value
      end
      childStatus.presentation = presentation
      transition.childStatus = childStatus
    end
    fade:updateSourceFrame()
    if fade.completed then
      local outgoingPlan = childStatus.presentation
      local outgoingKey = type(outgoingPlan) == "table" and outgoingPlan.inputKey or nil
      local incomingSummary = transition.kind == "replacement"
        and (transition.page == PAGE.SUMMARY or transition.page == PAGE.MOVE_PICK)
      if (outgoingKey == "summary" or incomingSummary) and transition.settled ~= true then
        -- A summary-involved exit publishes its full-black frame once
        -- before the handoff so the both-pane recurrence reads complete;
        -- sibling shutters keep their six-update cadence.
        transition.settled = true
        return
      end
      local previous = assert(self._child, "transition completion retires the published child")
      if transition.kind == "replacement" then
        self._child = transition.child
        self._page = transition.page
        self._continuation = transition.continuation
        self._lastChildStatus = assert(self._child):status()
        self._transition = nil
      else
        assert(transition.kind == "terminal", "active transitions have a replacement or terminal owner")
        if transition.result.kind == "close" then
          local plan = assert(transition.childStatus.presentation, "root close retains the outgoing pane plan")
          local inputKey = assert(plan.inputKey, "the returning application has a pane role")
          assert(inputKey == "bag" or inputKey == "party", "root close belongs to a Bag or Party plan")
          local panes = {}
          for _, pane in ipairs(assert(plan.panes, "the returning app plan carries its panes")) do
            if pane.id == "interaction" or pane.id == "hero" or pane.id == "content" or pane.id == "detail" then
              panes[#panes + 1] = { id = pane.id, placement = copyPresentationFacts(pane.placement) }
            end
          end
          assert(#panes > 0, "root close retains at least one app pane placement")
          transition.phase = "menu_return"
          transition.fade = StandardFade.new({ direction = "in", color = 0 })
          transition.inputKey = inputKey
          transition.panes = panes
          transition.childStatus = nil
          self._child = nil
          self._continuation = nil
          self._picker = nil
          self._terminalChildStatus = nil
        else
          self._terminalChildStatus = transition.childStatus
          self._child = nil
          self._continuation = nil
          self._picker = nil
          self._result = assert(transition.result, "terminal transitions publish a result at closure")
          self._transition = nil
        end
      end
      previous:dispose()
    end
    return
  end
  self._terminalChildStatus = nil
  local child = assert(self._child, "the flow owns one active child")
  self._lastChildStatus = child:status()
  child:updateFixed(uiInput)
  local currentChildStatus = child:status()
  if
    currentChildStatus.open == true
    and (currentChildStatus.presentation ~= nil or currentChildStatus.preparationState ~= nil)
  then
    self._lastChildStatus = currentChildStatus
  end
  local intent = self:_takeIntent()
  if intent ~= nil then
    self:_routeIntent(intent)
    return
  end
  local result = child:takeResult()
  if result ~= nil then
    self:_routeResult(result)
    return
  end
end

-- The presentation snapshot: root, active page, and the live child
-- status. The continuation never leaves the flow.
---@return table<string, unknown>
function PokemonMenuFlow:status()
  if self._disposed then
    return {
      open = false,
    }
  end
  local transition = self._transition
  if transition ~= nil and transition.phase == "menu_return" then
    local fade = assert(transition.fade, "menu return owns its brightness-in fade")
    local panes = {}
    for _, pane in ipairs(assert(transition.panes, "menu return retains its pane placements")) do
      panes[#panes + 1] = { id = pane.id, placement = copyPresentationFacts(pane.placement) }
    end
    return {
      open = true,
      root = self._root,
      page = self._page,
      transition = {
        phase = "menu_return",
        brightnessCoefficient = fade.coefficient,
        inputKey = assert(transition.inputKey),
        panes = panes,
      },
    }
  end
  if self._child == nil then
    return { open = false, child = self._terminalChildStatus }
  end
  local childStatus
  if transition ~= nil then
    childStatus = transition.childStatus
  else
    childStatus = self._child:status()
  end
  local status = { open = true, root = self._root, page = self._page, child = childStatus }
  if self._mailOutcome ~= nil then
    status.mailOutcome = copyPresentationFacts(self._mailOutcome)
  end
  if transition ~= nil then
    local fade = assert(transition.fade, "app exit owns its brightness-out fade")
    status.transition = {
      phase = "app_exit",
      step = fade.updates,
      brightnessCoefficient = fade.coefficient,
    }
  end
  return status
end

-- The one-shot host result: a root close or a checked field handoff, then
-- nil until the next terminal event.
---@return table<string, unknown>?
function PokemonMenuFlow:takeResult()
  local result = self._result
  self._result = nil
  return result
end

-- Cancels a held press through the live child, so a stale release never
-- activates across a replacement.
function PokemonMenuFlow:cancelPointerCapture()
  local child = self._child
  if child ~= nil then
    child:cancelPointerCapture()
  end
end

-- Idempotent release of the flow lifetime: the live child and any picked
-- cursor release exactly once, and no result survives disposal.
function PokemonMenuFlow:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  local child = self._child
  local transition = self._transition
  self._child = nil
  self._continuation = nil
  self._result = nil
  self._terminalResultPending = nil
  self._lastChildStatus = nil
  self._picker = nil
  self._transition = nil
  self._terminalChildStatus = nil
  if child ~= nil then
    child:dispose()
  end
  if transition ~= nil and transition.kind == "replacement" then
    transition.child:dispose()
  end
end

return PokemonMenuFlow
