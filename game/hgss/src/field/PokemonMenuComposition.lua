-- Concrete production composition root for the Pokemon menu feature:
-- PartyActions over the live mon/Bag services, the single field-move
-- runtime and world over the live owners, and Bag/Party flow factories
-- with current assets and display facts. Borrows services, manifests,
-- catalogs, and ports; owns only the field runtime/world pair it builds.
-- Disposal cancels owned field work exactly once and never releases
-- borrowed collaborators. Game-side leaf: never imports producer code.

local PartyActions = require("libs.hgss.src.field.PartyActions")
local FieldMoveRuntime = require("libs.hgss.src.field.FieldMoveRuntime")
local FieldMovePolicy = require("libs.hgss.src.field.FieldMovePolicy")
local FieldMoveContext = require("game.hgss.src.field.FieldMoveContext")
local FieldMapDataCache = require("libs.assets.src.field.FieldMapDataCache")
local FieldMoveWorld = require("game.hgss.src.field.FieldMoveWorld")
local PokemonMenuFlow = require("game.hgss.src.field.PokemonMenuFlow")
local MailActions = require("libs.hgss.src.field.MailActions")
local MailboxScreenState = require("game.hgss.src.pc.MailboxScreenState")
local PartyScreenState = require("game.hgss.src.field.PartyScreenState")

---@class PokemonMenuComposition
---@field partyActions table<string, unknown> borrowed action coordinator
---@field mailActions table<string, unknown> borrowed action coordinator
---@field fieldMoves table<string, unknown> owned field-move runtime
---@field fieldTravel table<string, unknown>? borrowed travel owner
---@field makeBagFlow fun(): table<string, unknown>
---@field makePartyFlow fun(): table<string, unknown>
---@field makeMailboxChild fun(): table<string, unknown>
---@field mailboxCount fun(): integer
---@field dispose fun()
local PokemonMenuComposition = {}

---@class PokemonMenuCompositionDependencies
---@field mons table<string, unknown> live mon service (borrowed)
---@field bag table<string, unknown> live Bag service (borrowed)
---@field bagCursor table<string, unknown> runtime Bag cursor (borrowed)
---@field itemCatalog table<string, unknown> shared item catalog (borrowed)
---@field monCatalog table<string, unknown> shared mon catalog (borrowed)
---@field bagManifest table<string, unknown> generated Bag manifest (borrowed)
---@field partyManifest table<string, unknown> generated Party manifest (borrowed)
---@field uiManifest table<string, unknown> validated field-UI manifest (borrowed)
---@field mailbox table<string, unknown> persistent Mailbox (borrowed)
---@field pcManifest table<string, unknown> validated PC manifest (borrowed)
---@field heroGender string "male" or "female"
---@field measureDisplay fun(): table<string, unknown> current display facts
---@field prepareIcons fun(iconKeys: string[]): boolean, string? presented icon preparation (borrowed binding)
---@field cancelIconPreparation fun() presented preparation release (borrowed binding)
---@field contextSources fun(): table<string, unknown> live world reads per check
---@field worldPorts table<string, unknown> field world ports (borrowed owners)
---@field fieldTravel table<string, unknown>? durable travel owner (borrowed)
---@field cacheFs table<string, unknown>? version cache reader for cited spawn landings
---@field overrides table<string, unknown>? per-case application overrides
---@field effect (fun(sequence: string))? the production semantic sound boundary for bag children
---@field textPolicy table<string, unknown>? the copied player text-speed cadence for bag children

-- The menu flow's field-check port: capture the current world facts on
-- every call, then answer the source eligibility decision. Fresh reads
-- per call keep badge, map, and tile changes visible without caching.
local function checkFieldMove(contextSources, request)
  assert(type(request) == "table", "field checks need a request record")
  local move = assert(request.move, "field checks need a move key")
  assert(type(move) == "string" and move ~= "", "field checks need a move key")
  local context = FieldMoveContext.capture(assert(contextSources, "field checks need live sources")())
  return FieldMovePolicy.check(move, context)
end

-- Cited spawn landings read through the version cache: unknown keys
-- resolve to nil so planning refuses loudly, and a missing index fails
-- loudly instead of warping somewhere convenient.
local function spawnResolver(cacheFs)
  local function destinationFor(_, spawnKey)
    return FieldMapDataCache.spawnDestination(cacheFs, spawnKey)
  end
  return {
    destinationFor = destinationFor,
  }
end

---@param deps PokemonMenuCompositionDependencies
---@return PokemonMenuComposition
function PokemonMenuComposition.create(deps)
  assert(type(deps) == "table", "the menu composition requires its collaborators")
  local mons = assert(deps.mons, "the menu composition borrows the live mon service")
  local bag = assert(deps.bag, "the menu composition borrows the live bag service")
  local bagCursor = assert(deps.bagCursor, "the menu composition borrows the runtime bag cursor")
  local itemCatalog = assert(deps.itemCatalog, "the menu composition borrows the shared item catalog")
  local monCatalog = assert(deps.monCatalog, "the menu composition borrows the shared mon catalog")
  local bagManifest = assert(deps.bagManifest, "the menu composition borrows the generated bag manifest")
  local partyManifest = assert(deps.partyManifest, "the menu composition borrows the generated party manifest")
  local uiManifest = assert(deps.uiManifest, "the menu composition borrows the validated field-UI manifest")
  local mailbox = assert(deps.mailbox, "the menu composition borrows the persistent Mailbox")
  local pcManifest = assert(deps.pcManifest, "the menu composition borrows the compiled PC manifest")
  assert(deps.heroGender == "male" or deps.heroGender == "female", "the menu composition needs the hero gender")
  local measureDisplay = assert(deps.measureDisplay, "the menu composition needs the display facts")
  assert(type(measureDisplay) == "function", "the menu composition needs the display facts")
  local prepareIcons = assert(deps.prepareIcons, "the menu composition needs its icon preparation")
  assert(type(prepareIcons) == "function", "the menu composition needs its icon preparation")
  local cancelIconPreparation = assert(deps.cancelIconPreparation, "the menu composition needs its preparation release")
  assert(type(cancelIconPreparation) == "function", "the menu composition needs its preparation release")
  local contextSources = assert(deps.contextSources, "the menu composition needs live world reads")
  assert(type(contextSources) == "function", "the menu composition needs live world reads")
  local worldPorts = assert(deps.worldPorts, "the menu composition needs the field world ports")
  assert(type(worldPorts) == "table", "the menu composition needs the field world ports")
  local overrides = deps.overrides
  assert(deps.effect == nil or type(deps.effect) == "function", "the menu composition carries an effect function")
  assert(deps.textPolicy == nil or type(deps.textPolicy) == "table", "the menu composition carries a text policy")

  local partyActions = PartyActions.new({ mons = mons, bag = bag })
  local mailActions = MailActions.new({ mons = mons, mailbox = mailbox, bag = bag, manifest = pcManifest })
  local ports = {}
  for key, port in pairs(worldPorts) do
    ports[key] = port
  end
  if deps.cacheFs ~= nil then
    ports.spawns = spawnResolver(deps.cacheFs)
  end
  local world = FieldMoveWorld.new(ports)
  local fieldMoves = FieldMoveRuntime.new({
    policy = FieldMovePolicy,
    world = world,
  })

  local assets = {
    bagManifest = bagManifest,
    partyManifest = partyManifest,
    uiManifest = uiManifest,
    monCatalog = monCatalog,
    itemCatalog = itemCatalog,
    heroGender = deps.heroGender,
  }
  local function checkPort(request)
    return checkFieldMove(contextSources, request)
  end
  local function makeFlow(root)
    return PokemonMenuFlow.new({
      root = root,
      effect = deps.effect,
      textPolicy = deps.textPolicy,
      mons = mons,
      bag = bag,
      bagCursor = bagCursor,
      partyActions = partyActions,
      mailActions = mailActions,
      mailbox = mailbox,
      pcManifest = pcManifest,
      fieldMoves = { check = checkPort },
      assets = assets,
      measureDisplay = measureDisplay,
      overrides = overrides,
      prepareIcons = prepareIcons,
      cancelIconPreparation = cancelIconPreparation,
    })
  end

  local disposed = false
  local function dispose()
    if disposed then
      return
    end
    disposed = true
    -- Final idempotent backstop: the owned runtime releases its pending
    -- or active field work exactly once. Borrowed services, manifests,
    -- catalogs, and ports are never released here.
    fieldMoves:dispose()
  end

  local function makeBagFlow()
    return makeFlow("bag")
  end
  local function makePartyFlow()
    return makeFlow("party")
  end
  local function makeMailboxChild()
    local function makePartyPicker()
      return PartyScreenState.new({
        service = mons,
        manifest = partyManifest,
        uiManifest = uiManifest,
        context = "pick",
        measureDisplay = measureDisplay,
        prepareIcons = prepareIcons,
        cancelIconPreparation = cancelIconPreparation,
        effect = deps.effect,
      })
    end
    return MailboxScreenState.new({
      mode = "mailbox",
      mailbox = mailbox,
      mailActions = mailActions,
      manifest = pcManifest,
      itemCatalog = itemCatalog,
      monCatalog = monCatalog,
      measureDisplay = measureDisplay,
      audio = { play = deps.effect },
      createPartyPicker = makePartyPicker,
    })
  end
  local function mailboxCount()
    local count = 0
    for slot = 0, mailbox:count() - 1 do
      if mailbox:get(slot) ~= nil then
        count = count + 1
      end
    end
    return count
  end

  return {
    partyActions = partyActions,
    mailActions = mailActions,
    fieldMoves = fieldMoves,
    fieldTravel = deps.fieldTravel,
    makeBagFlow = makeBagFlow,
    makePartyFlow = makePartyFlow,
    makeMailboxChild = makeMailboxChild,
    mailboxCount = mailboxCount,
    dispose = dispose,
  }
end

return PokemonMenuComposition
