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
local BagCursor = require("libs.hgss.src.items.BagCursor")
local BagScreenState = require("game.hgss.src.field.BagScreenState")
local MailActions = require("libs.hgss.src.field.MailActions")
local MailboxScreenState = require("game.hgss.src.pc.MailboxScreenState")
local PartyScreenState = require("game.hgss.src.field.PartyScreenState")
local StorageScreenState = require("game.hgss.src.pc.StorageScreenState")
local PhotoAlbumScreenState = require("game.hgss.src.pc.PhotoAlbumScreenState")
local SummaryScreenState = require("game.hgss.src.field.SummaryScreenState")
local BoxNamingState = require("game.hgss.src.pc.BoxNamingState")

---@class PokemonMenuComposition
---@field partyActions table<string, unknown> borrowed action coordinator
---@field mailActions table<string, unknown> borrowed action coordinator
---@field fieldMoves table<string, unknown> owned field-move runtime
---@field fieldTravel table<string, unknown>? borrowed travel owner
---@field makeBagFlow fun(): table<string, unknown>
---@field makePartyFlow fun(): table<string, unknown>
---@field makeMailboxChild fun(): table<string, unknown>
---@field makeStorageChild fun(mode: integer): table<string, unknown>
---@field makePhotoAlbumChild fun(): table<string, unknown>
---@field pcManifest table<string, unknown> validated PC manifest borrowed by leaf owners
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
---@field photoAlbum table<string, unknown> persistent PhotoAlbum (borrowed)
---@field pcManifest table<string, unknown> validated PC manifest (borrowed)
---@field profile table<string, unknown> live player profile (borrowed)
---@field versionId string selected game version
---@field cacheFs table<string, unknown>? selected version cache reader
---@field derivedAssets table<string, function> semantic asset host
---@field charmap table<string, unknown> generated HGSS character map
---@field heroGender string "male" or "female"
---@field measureDisplay fun(): table<string, unknown> current display facts
---@field prepareIcons fun(iconKeys: string[]): boolean, string? presented icon preparation (borrowed binding)
---@field cancelIconPreparation fun() presented preparation release (borrowed binding)
---@field contextSources fun(): table<string, unknown> live world reads per check
---@field worldPorts table<string, unknown> field world ports (borrowed owners)
---@field fieldTravel table<string, unknown>? durable travel owner (borrowed)
---@field overrides table<string, unknown>? per-case application overrides
---@field effect (fun(sequence: string))? the production semantic sound boundary for bag children
---@field playCry (fun(species: integer, pattern: integer, form: integer))? the production cry boundary for summary children
---@field textPolicy table<string, unknown>? the copied player text-speed cadence for bag children
---@field summaryManifest table<string, unknown>? the borrowed summary family for summary children
---@field summaryContext fun(): table<string, unknown>? the explicit summary display context per refresh
---@field readSummaryNavigation fun(): table<string, unknown>? the read-only summary navigation sample
---@field acquireSummaryPreparation fun(): table<string, unknown>? the per-open summary lease factory

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
  local photoAlbum = assert(deps.photoAlbum, "the menu composition borrows the persistent Photo Album")
  local pcManifest = assert(deps.pcManifest, "the menu composition borrows the compiled PC manifest")
  local profile = assert(deps.profile, "the menu composition borrows the live player profile")
  local versionId = assert(deps.versionId, "the menu composition requires the selected game version")
  local cacheFs = assert(deps.cacheFs, "the menu composition requires the selected version cache")
  local derivedAssets = assert(deps.derivedAssets, "the menu composition requires semantic asset access")
  local charmap = assert(deps.charmap, "the menu composition requires the generated character map")
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
  assert(deps.playCry == nil or type(deps.playCry) == "function", "the menu composition carries a cry function")
  assert(deps.textPolicy == nil or type(deps.textPolicy) == "table", "the menu composition carries a text policy")
  if deps.summaryManifest ~= nil then
    assert(type(deps.summaryManifest) == "table", "the menu composition borrows the summary family")
  end
  if deps.summaryContext ~= nil then
    assert(type(deps.summaryContext) == "function", "the menu composition carries its summary context")
  end
  if deps.readSummaryNavigation ~= nil then
    assert(type(deps.readSummaryNavigation) == "function", "the menu composition carries its summary navigation sample")
  end
  if deps.acquireSummaryPreparation ~= nil then
    assert(type(deps.acquireSummaryPreparation) == "function", "the menu composition carries its summary lease factory")
  end

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
    summaryManifest = deps.summaryManifest,
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
      playCry = deps.playCry,
      textPolicy = deps.textPolicy,
      summaryContext = deps.summaryContext,
      readSummaryNavigation = deps.readSummaryNavigation,
      acquireSummaryPreparation = deps.acquireSummaryPreparation,
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
      partyHasMembers = mons:partyCount() > 0,
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
  local function makeStorageChild(mode)
    local function makeHeldItemPicker(_)
      local pocket = bagCursor:currentPocket()
      local pickerCursor = BagCursor.new()
      pickerCursor:setPocket(pocket)
      pickerCursor:setPosition(pocket, bagCursor:position(pocket))
      pickerCursor:setScroll(pocket, bagCursor:scroll(pocket))
      return BagScreenState.new({
        service = bag,
        cursor = pickerCursor,
        manifest = bagManifest,
        uiManifest = uiManifest,
        monCatalog = monCatalog,
        heroGender = deps.heroGender,
        measureDisplay = measureDisplay,
        context = "pick_held",
        partyEmpty = mons:partyCount() == 0,
        effect = deps.effect,
        textPolicy = deps.textPolicy,
      })
    end
    local function makeSummary(request)
      local source = assert(request.source, "Storage summary carries its subject address")
      local subjectPort
      if source.kind == "box" then
        local box = assert(source.box, "boxed summary carries its box index")
        local function slots()
          local result = {}
          for slot = 0, 29 do
            if mons:boxMon(box, slot) ~= nil then
              result[#result + 1] = slot
            end
          end
          return result
        end
        local function countSubjects()
          return #slots()
        end
        local function boxRevision()
          return mons:boxRevision()
        end
        local function readSubject(index)
          local slot = assert(slots()[index + 1], "boxed summary subject remains occupied")
          return assert(mons:boxMon(box, slot), "boxed summary reads a copied mon")
        end
        local function publishSubject(index, mon, expectedRevision)
          local currentSlots = slots()
          local slot = currentSlots[index + 1]
          if expectedRevision ~= mons:boxRevision() or slot == nil then
            return { kind = "stale" }
          end
          local preparation, reason = mons:preparePcChanges({
            partyRevision = mons:partyRevision(),
            boxRevision = expectedRevision,
          }, { boxUpdates = { { box = box, slot = slot, mon = mon } } })
          if preparation == nil then
            assert(reason == "stale", "boxed summary publication only refuses stale revisions")
            return { kind = "stale" }
          end
          preparation.publish()
          return { kind = "changed" }
        end
        subjectPort = {
          count = countSubjects,
          revision = boxRevision,
          read = readSubject,
          publish = publishSubject,
        }
      end
      return SummaryScreenState.new({
        mons = mons,
        manifest = assert(deps.summaryManifest, "boxed summaries require the summary family"),
        initialSlot = subjectPort == nil and source.slot or 0,
        measureDisplay = measureDisplay,
        subjectPort = subjectPort,
        mode = "summary",
        context = assert(deps.summaryContext, "boxed summaries require their display context"),
        readNavigation = assert(deps.readSummaryNavigation, "boxed summaries require their navigation sample"),
        acquirePreparation = assert(deps.acquireSummaryPreparation, "boxed summaries require preparation"),
        effect = deps.effect,
        playCry = deps.playCry,
        textPolicy = deps.textPolicy,
      })
    end
    local function makeBoxName(request)
      local box = assert(request.box, "box naming carries its box index")
      local metadata = mons:boxMetadata(box)
      local child = BoxNamingState.new({ charmap = charmap, measureDisplay = measureDisplay })
      child:open({ currentText = metadata.name, maxLength = 16 })
      return child
    end
    return StorageScreenState.new({
      mode = mode,
      mons = mons,
      bag = bag,
      manifest = pcManifest,
      measureDisplay = measureDisplay,
      audio = { play = deps.effect },
      overrides = overrides and overrides.storage,
      childFactories = {
        summary = makeSummary,
        boxName = makeBoxName,
        heldItemPicker = makeHeldItemPicker,
      },
    })
  end
  local function makePhotoAlbumChild()
    return PhotoAlbumScreenState.new({
      album = photoAlbum,
      manifest = pcManifest,
      measureDisplay = measureDisplay,
      profile = profile,
      versionId = versionId,
      monCatalog = monCatalog,
      cacheFs = cacheFs,
      derivedAssets = derivedAssets,
      overrides = overrides and overrides.photoAlbum,
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
    makeStorageChild = makeStorageChild,
    makePhotoAlbumChild = makePhotoAlbumChild,
    pcManifest = pcManifest,
    mailboxCount = mailboxCount,
    dispose = dispose,
  }
end

return PokemonMenuComposition
