-- Owns the concrete GPU, UI, and field-effect resources used by FieldState.

local Errors = require("libs.errors.src.Errors")
local BagCache = require("libs.assets.src.BagCache")
local ApricornBoxAssetCache = require("libs.assets.src.ApricornBoxAssetCache")
local PcCache = require("libs.assets.src.PcCache")
local MartCache = require("libs.assets.src.MartCache")
local BagHeroRenderer = require("libs.hgss.src.presentation.BagHeroRenderer")
local BagRenderer = require("libs.hgss.src.ui.BagRenderer")
local ApricornBoxRenderer = require("libs.hgss.src.ui.ApricornBoxRenderer")
local MartRenderer = require("libs.hgss.src.ui.MartRenderer")
local FieldApplicationIds = require("libs.hgss.src.field.FieldApplicationIds")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")
local SummaryCache = require("libs.assets.src.SummaryCache")
local SummaryModel = require("libs.hgss.src.ui.SummaryModel")
local SummaryPresentationResources = require("game.hgss.src.field.SummaryPresentationResources")
local SummaryRenderer = require("libs.hgss.src.ui.SummaryRenderer")
local EasyChatPresentationResources = require("game.hgss.src.easychat.EasyChatPresentationResources")
local PokedexPresentationResources = require("game.hgss.src.pokedex.PokedexPresentationResources")
local FieldPresentationConfig = require("game.hgss.src.field.FieldPresentationConfig")
local FieldDialogueRenderer = require("libs.hgss.src.ui.FieldDialogueRenderer")
local FieldWindowRenderer = require("libs.hgss.src.ui.FieldWindowRenderer")
local FieldYesNoRenderer = require("libs.hgss.src.ui.FieldYesNoRenderer")
local LogicalSurface = require("libs.ui.src.LogicalSurface")
local FieldMenuRenderer = require("libs.hgss.src.ui.FieldMenuRenderer")
local FieldSignpostRenderer = require("libs.hgss.src.ui.FieldSignpostRenderer")
local FieldTextRenderer = require("libs.hgss.src.ui.FieldTextRenderer")
local FieldStaticEffectRenderer = require("libs.hgss.src.presentation.FieldStaticEffectRenderer")
local FieldActorEmoteRenderer = require("libs.hgss.src.presentation.FieldActorEmoteRenderer")
local FieldTerrainEffectRenderer = require("libs.hgss.src.presentation.FieldTerrainEffectRenderer")
local GpuAssetPool = require("libs.hgss.src.presentation.GpuAssetPool")
local FieldRenderer = require("libs.hgss.src.presentation.FieldRenderer")
local StartMenuRenderer = require("libs.hgss.src.ui.StartMenuRenderer")
local Utf8Glyphs = require("libs.assets.src.Utf8Glyphs")
local ApplicationPresentation = require("libs.ui.src.ApplicationPresentation")
local TrainerCardRenderer = require("libs.hgss.src.ui.TrainerCardRenderer")
local PartyScreenRenderer = require("libs.hgss.src.ui.PartyScreenRenderer")
local PartyCache = require("libs.assets.src.PartyCache")
local MonIconAssetProvider = require("libs.hgss.src.presentation.MonIconAssetProvider")
local ItemIconAssetProvider = require("libs.hgss.src.presentation.ItemIconAssetProvider")
local FollowingMonTransitionRenderer = require("libs.hgss.src.presentation.FollowingMonTransitionRenderer")
local PokemonCenterHealRenderer = require("libs.hgss.src.presentation.PokemonCenterHealRenderer")
local NamingScreenRenderer = require("libs.hgss.src.ui.NamingScreenRenderer")
local PcStorageRenderer = require("libs.hgss.src.ui.PcStorageRenderer")
local MailboxRenderer = require("libs.hgss.src.ui.MailboxRenderer")
local MailViewInterface = require("game.hgss.src.pc.MailViewInterface")
local PhotoAlbumRenderer = require("libs.hgss.src.ui.PhotoAlbumRenderer")
local FieldMapNameRenderer = require("game.hgss.src.field.FieldMapNameRenderer")
local OptionsRenderer = require("game.hgss.src.options.OptionsRenderer")
local FieldAreaPreviewRenderer = require("game.hgss.src.field.FieldAreaPreviewRenderer")

---@alias PartyIconPrepare fun(iconKeys: string[]): boolean, string?
---@alias PartyIconCancel fun()
---@alias SummaryPreparationAcquire fun(): table<string, unknown>
---@alias PokedexPreparationAcquire fun(options: table<string, unknown>): table<string, unknown>
---@alias EasyChatPreparationAcquire fun(): table<string, unknown>

---@class FieldPresentationResourcesRuntime
---@field cacheFs CacheFs
---@field imageAssets table<string, unknown>? the runtime-owned shared image owner borrowed by menu chrome
---@field assetPreparation table<string, unknown>? the runtime-owned preparation worker borrowed by scene owners
---@field derivedAssets table<string, function>? semantic derived-asset host in presented composition
---@field bindPartyIconPreparation fun(runtime: FieldPresentationResourcesRuntime, prepare: PartyIconPrepare, cancel: PartyIconCancel): integer? runtime party preparation binding in presented composition
---@field unbindPartyIconPreparation fun(runtime: FieldPresentationResourcesRuntime, binding: integer)? runtime preparation unbinding in presented composition
---@field bindSummaryPreparation fun(runtime: FieldPresentationResourcesRuntime, acquire: SummaryPreparationAcquire): integer runtime summary preparation binding in presented composition
---@field unbindSummaryPreparation fun(runtime: FieldPresentationResourcesRuntime, binding: integer) runtime summary preparation unbinding in presented composition
---@field bindPokedexPreparation fun(runtime: FieldPresentationResourcesRuntime, acquire: PokedexPreparationAcquire): integer runtime pokedex preparation binding in presented composition
---@field unbindPokedexPreparation fun(runtime: FieldPresentationResourcesRuntime, binding: integer) runtime pokedex preparation unbinding in presented composition
---@field bindEasyChatPreparation fun(runtime: FieldPresentationResourcesRuntime, acquire: EasyChatPreparationAcquire): integer runtime editor preparation binding in presented composition
---@field unbindEasyChatPreparation fun(runtime: FieldPresentationResourcesRuntime, binding: integer) runtime editor preparation unbinding in presented composition
---@field bindMailPreparation fun(runtime: FieldPresentationResourcesRuntime, prepare: fun(status: table<string, unknown>): boolean, string?): integer runtime Mail preparation binding in presented composition
---@field unbindMailPreparation fun(runtime: FieldPresentationResourcesRuntime, binding: integer) runtime Mail preparation unbinding in presented composition
---@field easyChatCatalog table<string, unknown>? the shared word catalog behind Mail reads
---@field monService table<string, unknown>? the live party mon service behind idle selector prediction
---@field monCatalog table<string, unknown>? the resolved mon catalog borrowed by pokedex composition
---@field pokedexCatalog table<string, unknown>? the borrowed generated dex catalog behind pokedex composition
---@field messageProvider table<string, unknown>? the borrowed field message provider
---@field audio table<string, unknown>? the borrowed field audio owner
---@field uiManifest table<string, unknown>
---@field playerData table<string, unknown> the validated profile/options authority
---@field windowStyles FieldWindowStyles
---@field fieldEntryManifest FieldEntryAssetCache.Manifest? the compiled map-name banner skins, palettes, and eligibility
---@field fieldEntranceIndicatorAsset table<string, unknown>
---@field fieldEmoteModels table<string, table<string, unknown>>
---@field fieldEffectAssets table<string, unknown>
---@field fieldTerrainEffectController FieldTerrainEffectController
---@field followerTransitionDefinition table<string, unknown>?
---@field followingMonTransition FollowingMonTransitionController?
---@field pokemonCenterHeal PokemonCenterHealFlow? active healing choreography
---@field pokemonCenterHealDefinition table<string, unknown>? generated healing-ball asset definition

---@class FieldPresentationResources
---@field cacheFs CacheFs generated asset filesystem
---@field uiManifest table<string, unknown> validated field UI manifest
---@field renderer FieldRenderer?
---@field windowRenderer FieldWindowRenderer? the one shared frame-strip atlas owner lent to dialogue rendering
---@field applicationFrameIndex integer? the snapshotted player-owned frame choice for application borders
---@field _seenFrameIndex integer? the last committed frame observed by option synchronization
---@field dialogueRenderer FieldDialogueRenderer?
---@field yesNoRenderer FieldYesNoRenderer
---@field menuRenderer FieldMenuRenderer
---@field signpostRenderer FieldSignpostRenderer?
---@field startMenuRenderer StartMenuRenderer?
---@field trainerCardRenderer TrainerCardRenderer?
---@field partyScreenRenderer PartyScreenRenderer?
---@field partyManifest table<string, unknown> validated native party-screen presentation geometry
---@field monIconProvider MonIconAssetProvider? the one shared party-icon demand owner for the state lifetime
---@field namingRenderer NamingScreenRenderer? lazily owned script naming renderer
---@field namingIconQuads table<string, table<integer, unknown>> prepared mon icon frames borrowed from the provider
---@field _imagePool table<string, unknown>? borrowed shared generated-image owner behind icons, Summary, and PC visuals
---@field _presentationRuntime FieldPresentationResourcesRuntime? borrowed runtime owning the party preparation binding
---@field _partyIconBinding integer? installed preparation binding identity
---@field _summaryBinding integer? installed summary preparation binding identity
---@field summaryResources SummaryPresentationResources? the one field-owned summary preparation leaf
---@field summaryRenderer SummaryRenderer? the one real summary pane renderer
---@field summaryManifest table<string, unknown>? validated generated Summary family
---@field _optionsRenderer OptionsRenderer? the one retained per-open options resource owner
---@field _pokedexBinding integer? installed pokedex preparation binding identity
---@field pokedexResources PokedexPresentationResources? the one lazily owned field pokedex preparation leaf
---@field _easyChatBinding integer? installed editor preparation binding identity
---@field _mailBinding integer? installed Mail preparation binding identity
---@field easyChatResources EasyChatPresentationResources? the one lazily owned field editor preparation leaf
---@field itemIconProvider ItemIconAssetProvider the one shared bag item-icon atlas
---@field _apricornBoxRenderer ApricornBoxRenderer? owned source graphics and row renderer
---@field heroRenderer BagHeroRenderer the one bag hero model renderer borrowed by the bag renderer
---@field bagRenderer BagRenderer the one field-bag pane renderer
---@field bagManifest table<string, unknown> validated native bag presentation geometry
---@field pcManifest table<string, unknown> validated PC manifest borrowed by its application renderers
---@field storageRenderer PcStorageRenderer PC Storage renderer (borrows the shared image owner)
---@field mailboxRenderer MailboxRenderer Mailbox renderer (borrows the shared image owner)
---@field photoAlbumRenderer PhotoAlbumRenderer Photo Album renderer (borrows the shared image owner)
---@field martRenderer MartRenderer? owned source-layered mart background and prompt images
---@field followingMonTransitionRenderer FollowingMonTransitionRenderer? transient follower-transition presentation (nil without the generated definition)
---@field pokemonCenterHealRenderer PokemonCenterHealRenderer? transient healing-ball presentation
---@field textRenderer FieldTextRenderer?
---@field phoneNameTextRenderer FieldTextRenderer? the borrowed phone-list name renderer (the battle menu renderer at source font 4)
---@field fieldEntryManifest FieldEntryAssetCache.Manifest? the compiled map-name banner source for the skin lease
---@field bannerRenderer FieldMapNameRenderer? the borrowed map-name banner renderer
---@field _bannerSkin { image: love.Image, palette: FieldEntryAssetCache.BannerTextPalette }? the one retained banner skin
---@field _bannerSkinKey integer? the style of the retained banner skin
---@field areaPreviewRenderer FieldAreaPreviewRenderer? the borrowed area-preview draw leaf
---@field _previewImage love.Image? the one retained selected area-preview image
---@field _previewImageKey string? the semantic key of the retained area-preview image
---@field battleTextRenderers table<string, FieldTextRenderer>?
---@field fieldEntranceIndicatorPool GpuAssetPool?
---@field fieldEntranceIndicatorRenderer FieldStaticEffectRenderer?
---@field fieldSurfRenderer FieldStaticEffectRenderer?
---@field surfPresentation table<string, unknown>
---@field fieldEmotePool GpuAssetPool?
---@field fieldEmoteRenderer FieldActorEmoteRenderer?
---@field fieldTerrainEffectRenderer FieldTerrainEffectRenderer?
---@field presenters table<string, FieldPresentationApplicationPresenter>? the per-instance application presenter map
---@field _warmPartyRevision integer? last observed live party revision behind the idle selector memo
---@field _warmPortraitSelectors string[]? predicted non-egg portrait selectors in stable slot order
---@field _warmNext string? next idle owner to progress first, summary or pokedex
---@field _applicationWarmupFailure string? last idle staging diagnostic, never a demand failure
local FieldPresentationResources = {}
FieldPresentationResources.__index = FieldPresentationResources

---@alias FieldPresentationApplicationPresenter fun(presentation: table<string, unknown>?, runtime: FieldRuntime?)

-- The explicit per-instance application presenter map: every presentable
-- application id resolves to the concrete renderer draw over resources this
-- owner holds. Presenters borrow those resources; they never acquire or
-- release them. An id without a presenter is a composition error, never a
-- fallback to another application surface.
-- Draws every published outer frame through the shared selected-frame owner
-- after application content: one logical scope per frame record, the
-- border-only selected frame, never content or host pixels. The application body
-- sits fully inside the exterior frame room, so no body pixel hides beneath
-- frame art. Plans without frames draw
-- nothing extra.
---@param graphics table<string, unknown> host graphics namespace
---@param owner FieldPresentationResources
---@param plan table<string, unknown> the resolved application plan
local function drawApplicationFrames(graphics, owner, plan)
  local frames = assert(plan and plan.frames, "application frame drawing requires the resolved plan frames")
  if #frames == 0 then
    return
  end
  local window = assert(owner.windowRenderer, "field presentation owns no window renderer")
  local frameIndex = assert(owner.applicationFrameIndex, "field presentation owns no application frame index")
  assert(type(graphics) == "table", "application frame drawing requires its graphics namespace")
  graphics.push("all")
  local ok, err = pcall(function()
    for _, frame in ipairs(frames) do
      LogicalSurface.draw(graphics, assert(frame.placement, "the outer frame carries its placement"), function()
        local contentBox = assert(frame.contentBox, "the outer frame carries its content box")
        window:drawApplicationFrame(contentBox, frameIndex)
      end)
    end
  end)
  graphics.pop()
  if not ok then
    error(err, 0)
  end
end

---@param owner FieldPresentationResources
---@return table<string, FieldPresentationApplicationPresenter>
local function buildPresenters(owner)
  -- The party wait screen is reachable from either menu-flow host: the
  -- bag opens party targets for Use/Give, so a pending party child must
  -- draw nothing through the bag application too; failure raises its cause.
  -- Drawing never invokes icon getters, so no draw ever acquires resources.
  ---@param presentation table<string, unknown>?
  ---@return boolean handled
  local function drawPartyWait(presentation)
    local state = presentation and presentation.preparationState
    if state ~= "pending" and state ~= "failed" then
      return false
    end
    if state == "failed" then
      error("party icon preparation failed: " .. tostring(assert(presentation).preparationError), 0)
    end
    return true
  end
  ---@param hostGraphics table<string, unknown>
  ---@param status table<string, unknown>
  ---@param plan table<string, unknown>
  local function drawPartyPlan(hostGraphics, status, plan)
    ApplicationPresentation.draw(hostGraphics, {
      graphics = hostGraphics,
      partyScreenRenderer = assert(owner.partyScreenRenderer, "party screen renderer is unavailable"),
      icons = assert(owner.monIconProvider, "party icon provider is unavailable"),
      text = assert(owner.textRenderer, "party text renderer is unavailable"),
    }, status, plan)
  end
  -- The summary wait screen covers the wrapper-owned preparation state:
  -- pending draws only the host preparation cover, failure shows the
  -- explicit cause with cancellation. Drawing never invokes bundle
  -- getters, so no draw ever acquires resources.
  ---@param presentation table<string, unknown>?
  ---@return boolean handled
  local function drawSummaryWait(presentation)
    local state = presentation and presentation.preparationState
    if state ~= "pending" and state ~= "failed" then
      return false
    end
    local plan = presentation and presentation.presentation
    local inputKey = type(plan) == "table" and plan.inputKey or nil
    if inputKey ~= "summary" and inputKey ~= "summary-inactive" then
      return false
    end
    if state == "failed" then
      error("summary preparation failed: " .. tostring(assert(presentation).preparationError), 0)
    end
    return true
  end
  ---@param hostGraphics table<string, unknown>
  ---@param status table<string, unknown>
  ---@param plan table<string, unknown>
  local function drawSummaryPlan(hostGraphics, status, plan)
    local resources = {
      graphics = hostGraphics,
      summaryRenderer = assert(owner.summaryRenderer, "summary renderer is unavailable"),
    }
    if plan.inputKey == "summary" then
      resources.summaryBundle = assert(status.resources, "the summary plan carries its ready bundle")
    end
    ApplicationPresentation.draw(hostGraphics, resources, status, plan)
  end
  ---@param hostGraphics table<string, unknown>
  ---@param status table<string, unknown>
  ---@param plan table<string, unknown>
  local function drawBagPlan(hostGraphics, status, plan)
    ApplicationPresentation.draw(hostGraphics, {
      graphics = hostGraphics,
      bagRenderer = assert(owner.bagRenderer, "bag renderer is unavailable"),
      heroRenderer = assert(owner.heroRenderer, "bag hero renderer is unavailable"),
      icons = assert(owner.itemIconProvider, "bag icon provider is unavailable"),
      text = assert(owner.textRenderer, "bag text renderer is unavailable"),
    }, status, plan)
  end
  ---@param hostGraphics table<string, unknown>
  ---@param transition table<string, unknown>?
  ---@param plan table<string, unknown>?
  local function drawMenuFlowTransition(hostGraphics, transition, plan)
    if transition == nil then
      return
    end
    local phase = assert(transition.phase, "menu transitions carry a semantic phase")
    local coefficient = assert(transition.brightnessCoefficient, "menu transitions carry their brightness coefficient")
    assert(
      type(coefficient) == "number" and coefficient % 1 == 0 and coefficient >= 0 and coefficient <= 16,
      "menu brightness coefficients stay in 0..16"
    )
    local inputKey
    local panes
    if phase == "app_exit" then
      if transition.panes ~= nil then
        inputKey = assert(transition.inputKey, "the completed app exit retains its app role")
        panes = transition.panes
      else
        local activePlan = assert(plan, "an app exit draws over the outgoing child plan")
        inputKey = assert(activePlan.inputKey, "the outgoing plan names its app")
        panes = assert(activePlan.panes, "the outgoing plan carries its panes")
      end
    else
      assert(phase == "menu_return", "menu transitions use an app exit or menu return phase")
      inputKey = assert(transition.inputKey, "menu return retains its plan role")
      panes = assert(transition.panes, "menu return retains pane placements")
    end
    if inputKey == "bag-inactive" or inputKey == "party-inactive" or inputKey == "summary-inactive" then
      return
    end
    local mainId, subId
    local summaryExit = false
    if inputKey == "bag" then
      mainId, subId = "interaction", "hero"
    elseif inputKey == "party" then
      mainId, subId = "content", "detail"
    elseif inputKey == "summary" then
      mainId, subId = "main", "sub"
      summaryExit = true
    elseif inputKey == "apricorn-box" then
      mainId, subId = "lower", "upper"
    else
      error("menu transitions cannot present plan " .. tostring(inputKey), 0)
    end
    local mainPane, subPane
    for _, pane in ipairs(panes) do
      if pane.id == mainId then
        assert(mainPane == nil, "a menu plan has one main pane")
        mainPane = pane
      elseif pane.id == subId then
        assert(subPane == nil, "a menu plan has one sub pane")
        subPane = pane
      end
    end
    assert(mainPane ~= nil or #panes == 0, "an active menu plan carries its main pane")
    local function drawBrightness(pane)
      if pane == nil then
        return
      end
      LogicalSurface.draw(hostGraphics, assert(pane.placement, "menu panes carry placements"), function()
        hostGraphics.setColor(0, 0, 0, coefficient / 16)
        hostGraphics.rectangle("fill", 0, 0, 256, 192)
      end)
    end
    if phase == "app_exit" then
      if summaryExit then
        drawBrightness(mainPane)
        drawBrightness(subPane)
        return
      end
      local step = assert(transition.step, "app exit carries its source shutter step")
      assert(type(step) == "number" and step % 1 == 0 and step >= 0 and step <= 6, "shutter steps stay in 0..6")
      if mainPane ~= nil then
        LogicalSurface.draw(hostGraphics, assert(mainPane.placement, "menu main pane carries its placement"), function()
          local edge = 16 * step
          hostGraphics.setColor(0, 0, 0, 1)
          hostGraphics.rectangle("fill", 0, 0, 256, edge)
          hostGraphics.rectangle("fill", 0, 192 - edge, 256, edge)
        end)
      end
      drawBrightness(subPane)
    else
      drawBrightness(mainPane)
      drawBrightness(subPane)
    end
  end
  -- Both menu applications run the shared Bag/Party flow, whose single
  -- live child follows the active page: the bag hosts party targets for
  -- Use/Give, the party hosts the bag picker for Give, and either hosts
  -- the native Summary child. Dispatch on the resolved child plan,
  -- never the application id, so a cross-page child draws through its
  -- own renderer with its own providers. A plan outside the owned
  -- bag/party/summary set is a composition error, never a fallback to
  -- another application surface.
  ---@param presentation table<string, unknown>?
  ---@param applicationId string
  local function drawMenuFlow(presentation, applicationId)
    local transition = presentation and presentation.transition
    if transition ~= nil and transition.phase == "menu_return" then
      local hostGraphics = love and love.graphics
      assert(type(hostGraphics) == "table", applicationId .. " drawing requires its host graphics namespace")
      drawMenuFlowTransition(hostGraphics, transition, nil)
      return
    end
    if drawSummaryWait(presentation) then
      if transition ~= nil then
        local hostGraphics = love and love.graphics
        assert(type(hostGraphics) == "table", applicationId .. " drawing requires its host graphics namespace")
        local status = assert(presentation, "the summary wait screen carries its presentation status")
        local plan = assert(status.presentation, "the summary wait carries its resolved pane plan")
        drawMenuFlowTransition(hostGraphics, transition, plan)
      end
      return
    end
    if drawPartyWait(presentation) then
      if transition ~= nil then
        local hostGraphics = love and love.graphics
        assert(type(hostGraphics) == "table", applicationId .. " drawing requires its host graphics namespace")
        local status = assert(presentation, "the party wait screen carries its presentation status")
        local plan = assert(status.presentation, "the party wait carries its resolved pane plan")
        drawMenuFlowTransition(hostGraphics, transition, plan)
      end
      return
    end
    local status = assert(presentation, "the " .. applicationId .. " application presents its status")
    local plan = assert(status.presentation, "the " .. applicationId .. " application presents its plan")
    local hostGraphics = love and love.graphics
    assert(type(hostGraphics) == "table", applicationId .. " drawing requires its host graphics namespace")
    local inputKey = assert(plan.inputKey, "the " .. applicationId .. " application presents its plan input key")
    if inputKey == "bag" or inputKey == "bag-inactive" then
      drawBagPlan(hostGraphics, status, plan)
    elseif inputKey == "party" or inputKey == "party-inactive" then
      drawPartyPlan(hostGraphics, status, plan)
    elseif inputKey == "summary" or inputKey == "summary-inactive" then
      drawSummaryPlan(hostGraphics, status, plan)
    elseif inputKey == "apricorn-box" or inputKey == "apricorn-box-inactive" then
      ApplicationPresentation.draw(hostGraphics, {
        graphics = hostGraphics,
        apricornBoxRenderer = owner:getApricornBoxRenderer(),
      }, status, plan)
    elseif inputKey == "mail-view" or inputKey == "mail-view-inactive" then
      -- Native MailView panes draw through the shared stationery
      -- renderer with no generic outer frame: the source chrome is
      -- already self-framed.
      local view = assert(status.view, "the MailView application presents its detached view")
      local geometry = MailViewInterface.TEXT
      local renderer = assert(owner.mailboxRenderer, "MailView drawing borrows its owned renderer")
      for _, pane in ipairs(plan.panes) do
        LogicalSurface.draw(hostGraphics, pane.placement, function()
          renderer:drawMailPane(view, pane.id, {
            textRenderer = assert(owner.textRenderer, "MailView drawing borrows the field text renderer"),
            windowRenderer = assert(owner.windowRenderer, "MailView drawing borrows the shared field-window renderer"),
            monIconProvider = assert(owner.monIconProvider, "MailView drawing borrows the shared mon icon provider"),
            applicationFrameIndex = assert(owner.applicationFrameIndex, "MailView drawing borrows the selected frame"),
            mailViewGeometry = geometry,
          })
        end)
      end
    elseif inputKey == "easy-chat" or inputKey == "easy-chat-inactive" then
      owner:drawEasyChat(status)
    else
      error("the " .. applicationId .. " application cannot present plan " .. tostring(inputKey), 0)
    end
    drawMenuFlowTransition(hostGraphics, status.transition, plan)
    drawApplicationFrames(hostGraphics, owner, plan)
  end
  local function drawPokemon(presentation, _)
    drawMenuFlow(presentation, FieldApplicationIds.POKEMON)
  end
  local function drawTrainerCard(presentation, _)
    local status = assert(presentation, "the card application presents its status")
    local plan = assert(status.presentation, "the card application presents its plan")
    local hostGraphics = love and love.graphics
    assert(type(hostGraphics) == "table", "card drawing requires its host graphics namespace")
    ApplicationPresentation.draw(hostGraphics, {
      graphics = hostGraphics,
      trainerCardRenderer = assert(owner.trainerCardRenderer, "trainer card renderer is unavailable"),
      text = assert(owner.textRenderer, "card text renderer is unavailable"),
    }, status, plan)
    drawApplicationFrames(hostGraphics, owner, plan)
  end
  local function drawBag(presentation, _)
    drawMenuFlow(presentation, FieldApplicationIds.BAG)
  end
  -- The pokedex presenter draws the committed whole bundle through the
  -- resolved plan: pending initial state keeps the existing host cover
  -- and the failed state surfaces its cause. Drawing never prepares.
  ---@param presentation table<string, unknown>?
  local function drawPokedex(presentation, _)
    local status = assert(presentation, "the pokedex application presents its status")
    local plan = assert(status.presentation, "the pokedex application presents its plan")
    local assets = status.assets
    if assets == nil then
      if status.preparationError ~= nil then
        error("pokedex preparation failed: " .. tostring(status.preparationError), 0)
      end
      return
    end
    local hostGraphics = love and love.graphics
    assert(type(hostGraphics) == "table", "pokedex drawing requires its host graphics namespace")
    ApplicationPresentation.draw(hostGraphics, {
      graphics = hostGraphics,
      renderer = assert(assets.renderer, "the committed bundle carries its shared renderer"),
    }, { view = status.view, assets = assets, compact = status.compact }, plan)
    drawApplicationFrames(hostGraphics, owner, plan)
  end
  -- The options presenter draws the committed per-open renderer through
  -- the resolved plan: pending preparation keeps the existing host cover
  -- and the failed state surfaces its cause. Drawing never prepares.
  ---@param presentation table<string, unknown>?
  local function drawOptions(presentation, _)
    local status = assert(presentation, "the options application presents its status")
    if status.preparing then
      return
    end
    local plan = assert(status.presentation, "the options application presents its plan")
    local hostGraphics = love and love.graphics
    assert(type(hostGraphics) == "table", "options drawing requires its host graphics namespace")
    -- The Options backing is already self-framed source art: no generic
    -- application frame paints over it. Sibling applications keep theirs.
    ApplicationPresentation.draw(hostGraphics, {
      graphics = hostGraphics,
      optionsRenderer = assert(owner._optionsRenderer, "options renderer is unavailable"),
    }, status, plan)
  end
  return {
    [FieldApplicationIds.POKEMON] = drawPokemon,
    [FieldApplicationIds.TRAINER_CARD] = drawTrainerCard,
    [FieldApplicationIds.BAG] = drawBag,
    [FieldApplicationIds.POKEDEX] = drawPokedex,
    [FieldApplicationIds.OPTIONS] = drawOptions,
  }
end

---@param runtime FieldPresentationResourcesRuntime
---@return FieldPresentationResources
function FieldPresentationResources.new(runtime)
  local self = setmetatable({ cacheFs = runtime.cacheFs, uiManifest = runtime.uiManifest }, FieldPresentationResources)
  local ok, err = pcall(function()
    self.renderer = FieldRenderer.new({
      clearColor = { 0, 0, 0, 1 },
      worldRasterScale = FieldPresentationConfig.WORLD_3D_RASTER_SCALE,
    })
    -- One frame-strip atlas for the field lifetime, lent to dialogue
    -- rendering and reused for every application outer frame. The selected
    -- frame index snapshots the current player option because no live
    -- in-field options mutation exists.
    -- One session image owner for the field lifetime, lent to icons,
    -- Summary, and PC composition instead of a second worker beside the
    -- runtime queue. The borrowed owner is never released or disposed
    -- here; a presentation composition without one cannot borrow image
    -- leases and fails fast below.
    local sharedImages = assert(runtime.imageAssets, "field presentation borrows the runtime-owned shared image owner")
    self._imagePool = sharedImages
    self.windowRenderer =
      FieldWindowRenderer.new({ cacheFs = runtime.cacheFs, manifest = runtime.uiManifest, imagePool = sharedImages })
    local textRenderer = FieldTextRenderer.new({ cacheFs = runtime.cacheFs, imagePool = sharedImages })
    self.textRenderer = textRenderer
    -- The transient area-name banner borrows this one text atlas and the
    -- generated field-entry skins. The renderer holds no image itself; the
    -- selected skin is leased lazily here and released on replacement or
    -- dispose, so a field that never shows a banner materializes no art.
    self.fieldEntryManifest = runtime.fieldEntryManifest
    local function imageFor(styleKey)
      return self:_bannerSkinFor(styleKey)
    end
    self.bannerRenderer = FieldMapNameRenderer.new({
      graphics = assert(love and love.graphics, "the map-name banner needs its graphics namespace"),
      text = textRenderer,
      imageFor = imageFor,
    })
    -- The area preview borrows the same text-less image surface leaf shape:
    -- the renderer holds no image; the one selected preview bitmap is leased
    -- lazily here and released on replacement or dispose, so a field that
    -- never shows a preview materializes no preview art.
    local function previewImageFor(imageKey)
      return self:_previewImageFor(imageKey)
    end
    self.areaPreviewRenderer = FieldAreaPreviewRenderer.new({
      graphics = assert(love and love.graphics, "the area preview needs its graphics namespace"),
      imageFor = previewImageFor,
    })
    self.battleTextRenderers = {}
    self.battleTextRenderers.narration = FieldTextRenderer.new({ cacheFs = runtime.cacheFs, fontId = 1 })
    self.battleTextRenderers.menu = FieldTextRenderer.new({ cacheFs = runtime.cacheFs, fontId = 4 })
    self.battleTextRenderers.hud = FieldTextRenderer.new({ cacheFs = runtime.cacheFs, fontId = 0 })
    -- The phone contact list prints its names with source font 4 while
    -- classes keep font 0: it borrows the battle menu renderer by
    -- reference instead of owning a second font-4 renderer.
    self.phoneNameTextRenderer = self.battleTextRenderers.menu
    local playerData = assert(runtime.playerData, "field presentation requires the validated player data")
    local playerOptions = assert(playerData.options, "field presentation requires the player options")
    local textFrame = assert(playerOptions.textFrame, "field presentation requires the player-owned frame index")
    assert(
      type(textFrame) == "number" and textFrame % 1 == 0 and textFrame >= 0,
      "field presentation requires the player-owned frame index"
    )
    ---@cast textFrame integer
    self.applicationFrameIndex = textFrame
    self._seenFrameIndex = textFrame
    self.dialogueRenderer = FieldDialogueRenderer.new({
      cacheFs = runtime.cacheFs,
      manifest = runtime.uiManifest,
      text = textRenderer,
      windowRenderer = self.windowRenderer,
      imagePool = sharedImages,
    })
    self.yesNoRenderer = FieldYesNoRenderer.new({ text = textRenderer, window = self.windowRenderer })
    self.menuRenderer = FieldMenuRenderer.new({ text = textRenderer, window = self.windowRenderer })
    self.signpostRenderer = FieldSignpostRenderer.new({
      cacheFs = runtime.cacheFs,
      manifest = runtime.uiManifest,
      text = textRenderer,
      windowStyles = runtime.windowStyles,
      imagePool = sharedImages,
    })
    self.startMenuRenderer = StartMenuRenderer.new({
      cacheFs = runtime.cacheFs,
      manifest = runtime.uiManifest,
      text = textRenderer,
      imagePool = sharedImages,
      selectionCursor = FieldPresentationResources._apricornSelectionCursor(runtime.cacheFs),
    })
    self.trainerCardRenderer = TrainerCardRenderer.new({
      cacheFs = runtime.cacheFs,
      manifest = runtime.uiManifest,
      text = textRenderer,
      imagePool = sharedImages,
    })
    self.partyManifest = PartyCache.loadManifest(runtime.cacheFs)
    self.partyScreenRenderer = PartyScreenRenderer.new({
      cacheFs = runtime.cacheFs,
      manifest = self.partyManifest,
      uiManifest = runtime.uiManifest,
      text = textRenderer,
      window = self.windowRenderer,
      frameIndex = self.applicationFrameIndex,
      imagePool = sharedImages,
    })
    -- Icon, Summary, and PC visuals resolve through the one session image
    -- owner above: a single physical GPU image owner for the field
    -- lifetime, with per-owner demand leases instead of private caches.
    self.monIconProvider = MonIconAssetProvider.new(runtime.cacheFs, {
      imagePool = sharedImages,
      derivedAssets = assert(runtime.derivedAssets, "presented party icons require the semantic cache host"),
    })
    self.namingIconQuads = {}
    local provider = assert(self.monIconProvider, "party icon provider is unavailable")
    local function preparePartyIcons(iconKeys)
      return provider:prepareKeys(iconKeys)
    end
    local function cancelPartyIconPreparation()
      provider:cancelPreparation()
    end
    self._presentationRuntime = runtime
    local bindPreparation =
      assert(runtime.bindPartyIconPreparation, "presented party icons require the runtime preparation binding")
    self._partyIconBinding = bindPreparation(runtime, preparePartyIcons, cancelPartyIconPreparation)
    -- The summary preparation owner is required for the field lifetime:
    -- construction fails when the generated family cannot be read, so a
    -- field never starts without its preparation capability. No image
    -- realizes here; a wrapper lease demands visuals later.
    self.summaryRenderer = SummaryRenderer.new({ text = textRenderer })
    self.summaryManifest = SummaryCache.loadManifest(runtime.cacheFs)
    self.summaryResources = SummaryPresentationResources.new({
      cacheFs = runtime.cacheFs,
      graphics = assert(love and love.graphics, "summary preparation needs its graphics namespace"),
      text = textRenderer,
      icons = provider,
      imagePool = sharedImages,
      derivedAssets = runtime.derivedAssets or {},
      manifest = self.summaryManifest,
    })
    local bindSummaryPreparation =
      assert(runtime.bindSummaryPreparation, "presented summary preparation requires the runtime preparation binding")
    local summaryOwner = assert(self.summaryResources, "summary preparation is unavailable")
    self._summaryBinding = bindSummaryPreparation(runtime, function()
      return summaryOwner:acquire()
    end)
    -- The pokedex acquisition binding stays late-bound through the
    -- runtime because the preparation owner itself is lazy: the factory
    -- resolves per pokedex open, when a screen is actually constructed.
    -- Installing the binding acquires no images and loads no graphics.
    local bindPokedexPreparation =
      assert(runtime.bindPokedexPreparation, "presented pokedex preparation requires the runtime preparation binding")
    self._pokedexBinding = bindPokedexPreparation(runtime, function(options)
      return self:pokedex():acquire(options)
    end)
    -- The editor acquisition binding stays late-bound through the
    -- runtime because the preparation owner itself is lazy: the factory
    -- resolves per editor open, when a screen is actually constructed.
    -- Installing the binding acquires no images and loads no graphics.
    local bindEasyChatPreparation =
      assert(runtime.bindEasyChatPreparation, "presented editor preparation requires the runtime preparation binding")
    self._easyChatBinding = bindEasyChatPreparation(runtime, function()
      return self:easyChat():acquire()
    end)
    -- Bag presentation resolves eagerly beside the party icons: field entry
    -- boots only when the compiled item/bag caches are present, and the
    -- launch-time capability gate in the FieldRuntime bag factory still
    -- fails fast on missing service/cursor/catalog/assets when Bag opens.
    self.itemIconProvider = ItemIconAssetProvider.new(runtime.cacheFs, { imagePool = sharedImages })
    -- The bag manifest loads once: the 2D pane renderer and the borrowed
    -- hero model renderer share the same validated table.
    local bagManifest = BagCache.loadManifest(runtime.cacheFs)
    self.bagManifest = bagManifest
    self.heroRenderer = BagHeroRenderer.new({
      cacheFs = runtime.cacheFs,
      manifest = bagManifest,
      imageAssets = sharedImages,
    })
    self.bagRenderer = BagRenderer.new({
      cacheFs = runtime.cacheFs,
      manifest = bagManifest,
      promptManifest = runtime.uiManifest,
      text = textRenderer,
      heroRenderer = self.heroRenderer,
      window = self.windowRenderer,
      frameIndex = self.applicationFrameIndex,
      imagePool = sharedImages,
    })
    self.martRenderer = MartRenderer.new({
      cacheFs = runtime.cacheFs,
      manifest = MartCache.loadManifest(runtime.cacheFs),
      uiManifest = runtime.uiManifest,
      text = textRenderer,
      window = self.windowRenderer,
      frameIndex = self.applicationFrameIndex,
      imagePool = sharedImages,
    })
    self.pcManifest = PcCache.loadManifest(runtime.cacheFs)
    local graphics = assert(love and love.graphics, "PC application rendering requires LÖVE graphics")
    -- PC-generated visuals resolve through the same shared image owner as
    -- every other menu. The renderer objects stay resident while their
    -- state visuals borrow and release.
    self.storageRenderer = PcStorageRenderer.new({
      graphics = graphics,
      cacheFs = runtime.cacheFs,
      manifest = self.pcManifest,
      text = textRenderer,
      imagePool = sharedImages,
    })
    self.mailboxRenderer = MailboxRenderer.new({
      graphics = graphics,
      cacheFs = runtime.cacheFs,
      manifest = self.pcManifest,
      catalog = assert(runtime.easyChatCatalog, "Mail reads expand through the shared word catalog"),
      imagePool = sharedImages,
    })
    -- The Mail preparation binding resolves per Mail open because the
    -- menu factories postdate these resources: composers and read leaves
    -- poll the bound renderer preparation without owning its leases.
    local mailboxOwner = assert(self.mailboxRenderer, "Mail preparation borrows its owned renderer")
    self._mailBinding = runtime:bindMailPreparation(function(status)
      return mailboxOwner:prepare(status)
    end)
    self.photoAlbumRenderer = PhotoAlbumRenderer.new({
      graphics = graphics,
      cacheFs = runtime.cacheFs,
      manifest = self.pcManifest,
      imagePool = sharedImages,
    })
    -- Entrance, surf, follower-transition, heal, and terrain effects draw
    -- through the session image owner instead of privately owned textures.
    local entrancePool = GpuAssetPool.new(runtime.cacheFs, { imageAssets = sharedImages })
    self.fieldEntranceIndicatorPool = entrancePool
    self.fieldEntranceIndicatorRenderer =
      FieldStaticEffectRenderer.new(runtime.fieldEntranceIndicatorAsset.model, entrancePool)
    -- The transient follower-transition presentation shares the field effect
    -- pool. Its renderer-backed part instances replace the runtime's
    -- headless factory, so script-started transitions render through the
    -- exact generated resources while keeping controller timing.
    -- Definition-less compositions leave the renderer nil; the draw
    -- short-circuit below and the nil-guarded dispose keep them inert.
    if runtime.followerTransitionDefinition ~= nil and runtime.followingMonTransition ~= nil then
      local transitionRenderer =
        FollowingMonTransitionRenderer.new({ transition = runtime.followerTransitionDefinition }, entrancePool)
      self.followingMonTransitionRenderer = transitionRenderer
      local function transitionModelFactory(part)
        return transitionRenderer:newInstance(part)
      end
      runtime.followingMonTransition:setModelFactory(transitionModelFactory)
    else
      self.followingMonTransitionRenderer = nil
    end
    if runtime.pokemonCenterHealDefinition ~= nil and runtime.pokemonCenterHeal ~= nil then
      local healRenderer =
        PokemonCenterHealRenderer.new({ definition = runtime.pokemonCenterHealDefinition }, entrancePool)
      self.pokemonCenterHealRenderer = healRenderer
      runtime.pokemonCenterHeal:setBallFactory(function(position, record, index)
        return healRenderer:newBall(position, record, index)
      end)
    else
      self.pokemonCenterHealRenderer = nil
    end
    local surfEffects = runtime.fieldEntranceIndicatorAsset.effects
    local surfAttachment =
      assert(surfEffects and surfEffects.surf_attachment, "field-effect cache is missing surf_attachment")
    self.surfPresentation = assert(surfAttachment.presentation, "field-effect cache is missing surf presentation")
    self.fieldSurfRenderer = FieldStaticEffectRenderer.new(surfAttachment.model, entrancePool)
    -- Actor emotes borrow the same session owner; a runtime without one
    -- keeps the pool's private ownership for headless composition.
    local emotePool = GpuAssetPool.new(runtime.cacheFs, { imageAssets = sharedImages })
    self.fieldEmotePool = emotePool
    self.fieldEmoteRenderer = FieldActorEmoteRenderer.new(runtime.fieldEmoteModels, emotePool)
    local fieldEffectAssets = assert(runtime.fieldEffectAssets, "field terrain-effect assets are unavailable")
    local terrainEffectRenderer = FieldTerrainEffectRenderer.new(fieldEffectAssets, entrancePool)
    self.fieldTerrainEffectRenderer = terrainEffectRenderer
    local function terrainModelFactory(kind)
      return terrainEffectRenderer:newInstance(kind)
    end
    local fieldTerrainEffectController =
      assert(runtime.fieldTerrainEffectController, "field terrain-effect controller is unavailable")
    fieldTerrainEffectController:setModelFactory(terrainModelFactory)
    self.presenters = buildPresenters(self)
  end)
  if not ok then
    self:dispose()
    error(err, 0)
  end
  return self
end

-- Creates naming chrome only after the shared icon provider reports readiness.
---@param owner FieldPresentationResources
---@return NamingScreenRenderer
local function ensureMonNamingRenderer(owner)
  if owner.namingRenderer ~= nil then
    return owner.namingRenderer
  end
  local graphics = assert(love and love.graphics, "Pokemon naming renderer requires graphics")
  -- Naming chrome borrows the session image owner like the other pooled
  -- field renderers: no private image construction stays beside the pool.
  local pool = assert(owner._imagePool, "Pokemon naming borrows the shared image owner")
  local function drawSubject(hostGraphics, subject, placement)
    local iconKey = assert(subject.iconKey, "Pokemon naming subject requires its icon key")
    local iconFrames =
      assert(owner.namingIconQuads[iconKey], "Pokemon naming icon frames were not prepared before draw")
    local quad = assert(iconFrames[placement.frameIndex], "Pokemon naming icon frame was not prepared before draw")
    -- Mon icon handles carry the shared pool-lease draw surface, so the subject
    -- resolves through the exact sampler with zero new imports.
    assert(owner.monIconProvider, "field presentation owns the mon icon provider")
      :handleFor(iconKey)
      :drawQuad(hostGraphics, quad, placement.x, placement.y)
  end
  local renderer = NamingScreenRenderer.new({
    graphics = graphics,
    text = assert(owner.textRenderer, "field text renderer is unavailable"),
    drawSubject = drawSubject,
    manifest = assert(owner.uiManifest, "field UI manifest is unavailable"),
    imagePool = pool,
  })
  owner.namingRenderer = renderer
  return renderer
end

---@param subject table<string, unknown>
---@return boolean ready
---@return string? failure
function FieldPresentationResources:prepareMonNamingSubject(subject)
  local iconKey = assert(subject.iconKey, "Pokemon naming subject requires its icon key")
  local icons = assert(self.monIconProvider, "field presentation owns the mon icon provider")
  local ready, failure = icons:prepareKeys({ iconKey })
  if not ready then
    return false, failure
  end
  if self.namingIconQuads[iconKey] == nil then
    local dimensions = icons:dimensions(iconKey)
    assert(
      dimensions.width == 32 and dimensions.height == 32,
      "Pokemon naming icon frames use the 32x32 source surface"
    )
    local naming = assert(self.uiManifest and self.uiManifest.namingScreen, "field UI naming manifest is unavailable")
    local frames =
      assert(naming.pokemonSubject and naming.pokemonSubject.frames, "Pokemon naming frames are unavailable")
    local prepared = {}
    for _, frame in ipairs(frames) do
      for _, part in ipairs(frame.parts) do
        if prepared[part.iconFrame] == nil then
          prepared[part.iconFrame] =
            assert(icons:quadFor(iconKey, part.iconFrame), "Pokemon naming icon quad was not prepared")
        end
      end
    end
    self.namingIconQuads[iconKey] = prepared
  end
  ensureMonNamingRenderer(self)
  return true, nil
end

---@return NamingScreenRenderer the renderer prepared by a successful naming preparation
function FieldPresentationResources:monNamingRenderer()
  return assert(self.namingRenderer, "field presentation owns no Pokemon naming renderer")
end

-- Draws the current application through its registered presenter. The map is
-- built once per instance alongside the renderers it borrows; a draw never
-- acquires resources. An application id without a presenter is a composition
-- error, never a fallback surface.
---@param applicationId string
---@param presentation table<string, unknown>?
---@param runtime FieldRuntime?
function FieldPresentationResources:drawApplication(applicationId, presentation, runtime)
  local map = assert(self.presenters, "the application presenter map is unavailable")
  local presenter = map[applicationId]
  if presenter == nil then
    Errors.raise(
      FieldErrors.FIELD_PRESENTATION_UNKNOWN_APPLICATION,
      "no presenter is registered for application " .. tostring(applicationId),
      { applicationId = applicationId }
    )
  end
  local draw = assert(presenter, "the application presenter is unavailable")
  -- Menu destinations publish through the bounded menu flow: the drawable
  -- leaf status rides one level down. Script-host and direct-controller
  -- statuses carry their own plan and pass through untouched; a plan-less
  -- flow status reaches the presenter, which fails loudly by contract.
  if type(presentation) == "table" and presentation.presentation == nil then
    local flowStatus = presentation
    presentation = flowStatus.child
    if presentation ~= nil and flowStatus.transition ~= nil then
      local childStatus = {}
      for key, value in pairs(presentation) do
        childStatus[key] = value
      end
      childStatus.transition = flowStatus.transition
      presentation = childStatus
    elseif flowStatus.transition ~= nil and flowStatus.transition.phase == "menu_return" then
      presentation = { transition = flowStatus.transition }
    end
  end
  draw(presentation, runtime)
end

-- Advances the active Bag leaf outside drawing: the field update forwards
-- the current application and script Mart sale statuses here before the
-- next present. A plan-less outer flow resolves through its child exactly
-- like the menu draw dispatch; ordinary Bag, inactive Bag, and sell-mart
-- leaves delegate to the shared Bag renderer while every other leaf is a
-- ready no-op that borrows nothing and draws nothing.
---@param status table<string, unknown> the active application or script mart status
---@return boolean ready
---@return string? failure
function FieldPresentationResources:prepareBagApplication(status)
  assert(type(status) == "table", "Bag preparation requires its active status")
  local leaf = status
  if leaf.presentation == nil and type(leaf.child) == "table" then
    leaf = leaf.child
  end
  local presentation = leaf.presentation
  if type(presentation) ~= "table" then
    return true
  end
  local inputKey = presentation.inputKey
  if inputKey ~= "bag" and inputKey ~= "bag-inactive" then
    return true
  end
  return assert(self.bagRenderer, "bag renderer is unavailable"):prepare(leaf)
end

-- Appends the mon icon keys one Storage view draws, skipping pages the
-- demand already holds. A non-view (no admitted parent yet) adds nothing.
---@param view table<string, unknown>?
---@param iconKeys string[]
---@param seen table<string, boolean>
---@return string[] iconKeys
local function iconKeysForStorageView(view, iconKeys, seen)
  if type(view) ~= "table" then
    return iconKeys
  end
  local function add(mon)
    if type(mon) == "table" and mon.iconKey ~= nil and not seen[mon.iconKey] then
      seen[mon.iconKey] = true
      iconKeys[#iconKeys + 1] = mon.iconKey
    end
  end
  if type(view.boxSlots) == "table" then
    for _, mon in ipairs(view.boxSlots) do
      add(mon)
    end
  end
  if type(view.party) == "table" then
    for _, mon in ipairs(view.party) do
      add(mon)
    end
  end
  if type(view.carry) == "table" then
    add(view.carry.mon)
  end
  return iconKeys
end

---@param status table<string, unknown> active PC status published by the host
---@param runtime FieldRuntime live mon catalog owner
---@return boolean ready
---@return string? failure
function FieldPresentationResources:preparePcApplication(status, runtime)
  local resources = self:pcApplicationResources(runtime)
  local iconKeys = {}
  if status.app == "photoAlbum" then
    return self.photoAlbumRenderer:advance(status, resources)
  elseif status.app == "storage" then
    -- A held-item picker admits through the shared Bag presenter: the
    -- live picker leaf gates the host while Storage wallpaper rests.
    if status.childKind == "heldItemPicker" then
      return self:prepareBagApplication(
        assert(status.bagChildStatus, "Storage picker preparation requires its Bag leaf")
      )
    end
    for _, mon in ipairs(assert(status.boxSlots, "Storage status publishes box icon snapshots")) do
      if mon ~= false then
        iconKeys[#iconKeys + 1] = mon.iconKey
      end
    end
    for _, mon in ipairs(assert(status.party, "Storage status publishes party icon snapshots")) do
      iconKeys[#iconKeys + 1] = mon.iconKey
    end
    local carry = status.carry
    if type(carry) == "table" and type(carry.mon) == "table" then
      iconKeys[#iconKeys + 1] = carry.mon.iconKey
    end
    local desiredCount = #iconKeys
    local seen = {} ---@type table<string, boolean>
    for _, key in ipairs(iconKeys) do
      seen[key] = true
    end
    -- The previously presented parent stays drawable while its replacement
    -- prepares, so its icon pages join the demand until the full cutover.
    iconKeysForStorageView(status.admittedParentView, iconKeys, seen)
    -- Readiness composes independent prerequisites without serializing enrollment.
    local iconsReady, iconsFailure =
      assert(self.monIconProvider, "PC applications borrow the shared mon icon provider"):prepareKeys(iconKeys)
    local imagesReady, imageFailure = assert(self.storageRenderer, "Storage borrows its owned renderer"):prepare(
      assert(status.visualView, "Storage preparation requires its published view")
    )
    if not iconsReady or not imagesReady then
      return iconsReady and imagesReady, iconsFailure or imageFailure
    end
    -- Both prerequisites are ready in this same update. An editor-free
    -- view installs at once, so the host cutover in this update draws the
    -- new view against its own leases. A transient editor view only
    -- stages: it draws through the staged group with no image-owner
    -- traffic, while the installed group keeps the admitted parent's
    -- leases until an editor-free replacement commits. Installing the
    -- editor chrome would retire paths a later pending fallback still
    -- needs, and the fallback must never show transient chooser state.
    local visualView = assert(status.visualView, "Storage preparation requires its published view")
    if status.editor == nil then
      assert(self.storageRenderer, "Storage borrows its owned renderer"):commitPrepared(visualView)
      if #iconKeys > desiredCount then
        local desiredKeys = {} ---@type string[]
        for index = 1, desiredCount do
          desiredKeys[index] = iconKeys[index]
        end
        -- The union already proved the desired pages ready, so demanding them
        -- alone retires only the pages the replacement no longer needs.
        local retired, retireFailure =
          assert(self.monIconProvider, "PC applications borrow the shared mon icon provider"):prepareKeys(desiredKeys)
        assert(retired, "Storage icon retirement preserves admitted readiness: " .. tostring(retireFailure))
      end
    end
    return true
  elseif status.app == "mailbox" then
    -- A composing PC child prepares only its active Mail leaf: while the
    -- shared editor owns the leaf its own lease governs readiness and no
    -- unrelated PC image is awaited.
    if status.compose ~= nil then
      if status.compose.child ~= nil then
        return true
      end
      local ready, failure = assert(self.mailboxRenderer, "Mailbox borrows its owned renderer"):prepare({
        viewMode = "write",
        stationeryType = assert(status.compose.stationeryType, "composition prepares its stationery"),
      })
      if not ready then
        return false, failure
      end
      return true
    end
    for _, icon in ipairs(assert(status.icons, "Mailbox status publishes message icon snapshots")) do
      iconKeys[#iconKeys + 1] = icon.iconKey
    end
    -- Readiness composes independent prerequisites without serializing
    -- enrollment: mon icon pages plus the Mailbox renderer's exact drawn
    -- visuals (list background and stationery backgrounds).
    local iconsReady, iconsFailure =
      assert(self.monIconProvider, "PC applications borrow the shared mon icon provider"):prepareKeys(iconKeys)
    local imagesReady, imageFailure = assert(self.mailboxRenderer, "Mailbox borrows its owned renderer"):prepare(status)
    if not iconsReady or not imagesReady then
      return false, iconsFailure or imageFailure
    end
    return true
  else
    error("PC application kind has no presentation preparation", 0)
  end
end

---@param runtime FieldRuntime runtime owners borrowed by the app renderers
---@return table<string, unknown>
function FieldPresentationResources:pcApplicationResources(runtime)
  local owner = self
  local function drawEasyChat(childStatus)
    return owner:drawEasyChat(childStatus)
  end
  return {
    drawEasyChat = drawEasyChat,
    mailViewGeometry = MailViewInterface.TEXT,
    icons = assert(self.monIconProvider, "PC applications borrow the shared mon icon provider"),
    itemIcons = assert(self.itemIconProvider, "Storage borrows the shared item icon provider"),
    storageRenderer = assert(self.storageRenderer, "Storage borrows its owned renderer"),
    mailboxRenderer = assert(self.mailboxRenderer, "Mailbox borrows its owned renderer"),
    photoAlbumRenderer = assert(self.photoAlbumRenderer, "Photo Album borrows its owned renderer"),
    monCatalog = assert(runtime.monCatalog, "Photo Album borrows the shared mon catalog"),
    monIconProvider = assert(self.monIconProvider, "Mailbox borrows the shared mon icon provider"),
    itemIconProvider = assert(self.itemIconProvider, "Mailbox borrows the shared item icon provider"),
    textRenderer = assert(self.textRenderer, "PC applications borrow the shared text renderer"),
    windowRenderer = assert(self.windowRenderer, "PC applications borrow the shared window renderer"),
    bagRenderer = assert(self.bagRenderer, "Storage borrows the shared Bag renderer"),
    heroRenderer = assert(self.heroRenderer, "Storage borrows the shared Bag hero renderer"),
    applicationFrameIndex = assert(self.applicationFrameIndex, "PC applications borrow the selected frame"),
  }
end

---@param host PcApplicationHost active retained PC host
---@param runtime FieldRuntime runtime owners borrowed by the app renderers
function FieldPresentationResources:drawPcApplication(host, runtime)
  host:draw(self:pcApplicationResources(runtime))
  local plan = host:presentationPlan()
  if plan ~= nil then
    drawApplicationFrames(
      assert(love.graphics, "PC application drawing requires its host graphics namespace"),
      self,
      plan
    )
  end
end

---@param status table<string, unknown> Kurt selector status carrying its resolved plan
function FieldPresentationResources:drawApricornBox(status)
  local hostGraphics = love and love.graphics
  assert(type(hostGraphics) == "table", "Kurt selector drawing requires its host graphics namespace")
  local plan = assert(status.presentation, "Kurt selector carries its resolved application plan")
  ApplicationPresentation.draw(hostGraphics, {
    graphics = hostGraphics,
    apricornBoxRenderer = self:getApricornBoxRenderer(),
  }, status, plan)
  drawApplicationFrames(hostGraphics, self, plan)
end

-- Draws the Start Menu through its resolved plan: one borrowed resource
-- record (the owned renderer plus the host graphics namespace) executes
-- the interface's chosen render callback. Ownership stays here; the
-- callback borrows and never releases.
---@param status table<string, unknown> the menu wrapper status carrying presentation=plan
---@param graphics table<string, unknown>? host graphics namespace (defaults to love.graphics)
function FieldPresentationResources:drawStartMenu(status, graphics)
  local presentation = assert(status and status.presentation, "the start menu draws through its presentation plan")
  local hostGraphics = graphics or (love and love.graphics)
  assert(type(hostGraphics) == "table", "start menu drawing requires its host graphics namespace")
  ApplicationPresentation.draw(hostGraphics, {
    graphics = hostGraphics,
    startMenuRenderer = assert(self.startMenuRenderer, "start menu renderer is unavailable"),
  }, status, presentation)
  drawApplicationFrames(hostGraphics, self, presentation)
end

-- Draws the script-owned party selection through the ordinary party
-- presenter: the same renderer and plan as the menu party. Draws only
-- while the host reports an active selection with a presentation plan;
-- an idle host or the plan-less empty shell draws nothing and fails
-- nothing. Never steps the screen.
---@param host table<string, unknown> the script-owned party selection host
function FieldPresentationResources:drawScriptParty(host)
  local status = host:status()
  if status == nil or status.presentation == nil then
    return
  end
  self:drawApplication(FieldApplicationIds.POKEMON, status)
end

-- Draws the active script mart over the retained field. Buy uses its
-- source-layered renderer; sale borrows the ordinary Bag presenter and its
-- already-owned hero and item resources.
---@param host table<string, unknown> the script-owned mart host
function FieldPresentationResources:drawMart(host)
  local status = host:status()
  if status == nil then
    return
  end
  if status.martKind == "sell" then
    self:drawApplication(FieldApplicationIds.BAG, status)
    return
  end
  assert(status.presentation, "active purchase child exposes a resolved mart plan")
  assert(self.martRenderer, "field presentation owns no mart renderer"):draw(
    status,
    status.presentation,
    { icons = assert(self.itemIconProvider, "mart rendering requires the shared item icons") }
  )
  -- The mart paints its resolved outer frames through the shared
  -- selected-frame pipeline like every other application does.
  drawApplicationFrames(
    assert(love and love.graphics, "mart frame drawing requires its host graphics namespace"),
    self,
    status.presentation
  )
end

-- Leases the one banner skin the status names and borrows the compiled
-- palette for its style. A replacement materializes the new image before
-- releasing the outgoing one, so a failed construction preserves the current
-- skin and at most one skin is retained for the field lifetime. The manifest
-- is required only when a status first draws.
---@param styleKey integer
---@return { image: love.Image, palette: FieldEntryAssetCache.BannerTextPalette }
function FieldPresentationResources:_bannerSkinFor(styleKey)
  local skin = self._bannerSkin
  if skin ~= nil and self._bannerSkinKey == styleKey then
    return skin
  end
  local manifest = assert(self.fieldEntryManifest, "the map-name banner requires the compiled field-entry manifest")
  local assetKey =
    assert(manifest.bannerStyles[styleKey], "the field-entry manifest has no banner style " .. tostring(styleKey))
  local asset = assert(manifest.assets[assetKey], "the field-entry manifest has no banner asset " .. assetKey)
  local path = assert(asset.image, "banner asset " .. assetKey .. " names no image")
  local sourcePalette = assert(
    manifest.bannerTextPalettes[styleKey],
    "the field-entry manifest has no banner palette " .. tostring(styleKey)
  )
  local viewPalette = {
    foreground = sourcePalette.foreground, -- borrowed, never mutated
    shadow = sourcePalette.shadow, -- borrowed, never mutated
    background = {
      r = sourcePalette.background.r,
      g = sourcePalette.background.g,
      b = sourcePalette.background.b,
      a = 0, -- normalized shader alpha, not persisted in the manifest
    },
  }
  local bytes = assert(self.cacheFs:read(path), "missing generated banner image " .. path)
  local graphics = assert(love and love.graphics, "the map-name banner needs its graphics namespace")
  local image = graphics.newImage(love.filesystem.newFileData(bytes, path))
  local filterOk, filterErr = pcall(function()
    image:setFilter("nearest", "nearest")
  end)
  if not filterOk then
    image:release()
    error(filterErr, 0)
  end
  if skin ~= nil then
    skin.image:release()
  end
  skin = { image = image, palette = viewPalette }
  self._bannerSkin = skin
  self._bannerSkinKey = styleKey
  return skin
end

-- Draws the transient area-name banner above the world and warp fade and below
-- script/foreground covers, anchored to the canonical MAIN reference frame.
-- A hidden banner paints nothing.
---@param banner FieldMapNameBanner the runtime's banner controller
---@param referenceFrame LayoutGeometry.Rect canonical MAIN field screen
function FieldPresentationResources:drawMapNameBanner(banner, referenceFrame)
  local status = banner:status()
  if status == nil then
    return
  end
  assert(self.bannerRenderer, "field presentation owns no map-name banner renderer"):draw(status, referenceFrame)
end

-- Leases the one selected area-preview image the status names. A replacement
-- materializes the new image before releasing the outgoing one, so a failed
-- construction preserves the current selection and at most one preview image
-- is retained for the field lifetime. A missing generated PNG is a terminal
-- cache-integrity error named by its path; it never degrades to a substitute.
---@param imageKey string
---@return love.Image
function FieldPresentationResources:_previewImageFor(imageKey)
  local retained = self._previewImage
  if retained ~= nil and self._previewImageKey == imageKey then
    return retained
  end
  local manifest = assert(self.fieldEntryManifest, "the area preview requires the compiled field-entry manifest")
  local asset = assert(manifest.assets[imageKey], "the field-entry manifest has no preview asset " .. imageKey)
  local path = assert(asset.image, "preview asset " .. imageKey .. " names no image")
  local bytes = assert(self.cacheFs:read(path), "missing generated preview image " .. path)
  local graphics = assert(love and love.graphics, "the area preview needs its graphics namespace")
  local image = graphics.newImage(love.filesystem.newFileData(bytes, path))
  image:setFilter("nearest", "nearest")
  if retained ~= nil then
    retained:release()
  end
  self._previewImage = image
  self._previewImageKey = imageKey
  return image
end

-- Draws the active time-aware area preview above the committed world and the
-- warp fade and below the area-name banner, anchored to the canonical MAIN
-- reference frame. The status carries the selected image key and alphas.
---@param status { imageKey: string, imageAlpha: number, blackAlpha: number }
---@param referenceFrame LayoutGeometry.Rect canonical MAIN field screen
function FieldPresentationResources:drawAreaPreview(status, referenceFrame)
  assert(self.areaPreviewRenderer, "field presentation owns no area-preview renderer"):draw(status, referenceFrame)
end

function FieldPresentationResources:dispose()
  self.presenters = nil
  -- A still-open options child returns its renderer here: borrowed owners
  -- are released after this, so the per-open leases return first.
  if self._optionsRenderer ~= nil then
    local renderer = assert(self._optionsRenderer, "a retained options renderer disposes before release")
    self._optionsRenderer = nil
    renderer:dispose()
  end
  if self.dialogueRenderer then
    self.dialogueRenderer:release()
    self.dialogueRenderer = nil
  end
  self.yesNoRenderer = nil
  -- Borrowers release before their owner: the bag renderer drops its
  -- borrowed window reference before dialogue rendering releases the
  -- shared atlas, so the owner releases exactly once here.
  if self.bagRenderer then
    self.bagRenderer:release()
    self.bagRenderer = nil
  end
  if self._apricornBoxRenderer then
    self._apricornBoxRenderer:release()
    self._apricornBoxRenderer = nil
  end
  if self.martRenderer then
    self.martRenderer:release()
    self.martRenderer = nil
  end
  if self.storageRenderer then
    self.storageRenderer:release()
    self.storageRenderer = nil
  end
  if self.mailboxRenderer then
    self.mailboxRenderer:release()
    self.mailboxRenderer = nil
  end
  if self.photoAlbumRenderer then
    self.photoAlbumRenderer:release()
    self.photoAlbumRenderer = nil
  end
  self.pcManifest = nil
  if self.windowRenderer then
    self.windowRenderer:release()
    self.windowRenderer = nil
  end
  self.applicationFrameIndex = nil
  if self.signpostRenderer then
    self.signpostRenderer:release()
    self.signpostRenderer = nil
  end
  if self.startMenuRenderer then
    self.startMenuRenderer:release()
    self.startMenuRenderer = nil
  end
  if self.trainerCardRenderer then
    self.trainerCardRenderer:release()
    self.trainerCardRenderer = nil
  end
  if self.namingRenderer then
    self.namingRenderer:dispose()
    self.namingRenderer = nil
  end
  self.namingIconQuads = {}
  if self.monIconProvider then
    self.monIconProvider:release()
    self.monIconProvider = nil
  end
  local partyIconBinding = self._partyIconBinding
  local summaryBinding = self._summaryBinding
  local pokedexBinding = self._pokedexBinding
  local easyChatBinding = self._easyChatBinding
  local mailBinding = self._mailBinding
  local presentationRuntime = self._presentationRuntime
  self._partyIconBinding = nil
  self._summaryBinding = nil
  self._pokedexBinding = nil
  self._easyChatBinding = nil
  self._mailBinding = nil
  self._presentationRuntime = nil
  if partyIconBinding ~= nil and presentationRuntime ~= nil then
    local unbindPreparation = assert(
      presentationRuntime.unbindPartyIconPreparation,
      "the installed preparation binding requires its runtime unbinding"
    )
    unbindPreparation(presentationRuntime, partyIconBinding)
  end
  if summaryBinding ~= nil and presentationRuntime ~= nil then
    local unbindSummary = assert(
      presentationRuntime.unbindSummaryPreparation,
      "the installed summary binding requires its runtime unbinding"
    )
    unbindSummary(presentationRuntime, summaryBinding)
  end
  if pokedexBinding ~= nil and presentationRuntime ~= nil then
    local unbindPokedex = assert(
      presentationRuntime.unbindPokedexPreparation,
      "the installed pokedex binding requires its runtime unbinding"
    )
    unbindPokedex(presentationRuntime, pokedexBinding)
  end
  if easyChatBinding ~= nil and presentationRuntime ~= nil then
    local unbindEasyChat = assert(
      presentationRuntime.unbindEasyChatPreparation,
      "the installed editor binding requires its runtime unbinding"
    )
    unbindEasyChat(presentationRuntime, easyChatBinding)
  end
  if mailBinding ~= nil and presentationRuntime ~= nil then
    local unbindMail =
      assert(presentationRuntime.unbindMailPreparation, "the installed Mail binding requires its runtime unbinding")
    unbindMail(presentationRuntime, mailBinding)
  end
  if self.pokedexResources then
    self.pokedexResources:release()
    self.pokedexResources = nil
  end
  if self.easyChatResources then
    self.easyChatResources:release()
    self.easyChatResources = nil
  end
  if self.summaryResources then
    self.summaryResources:release()
    self.summaryResources = nil
  end
  self.summaryRenderer = nil
  -- The session image owner stays borrowed: disposal returns demand
  -- leases through the owners above and never tears down the pool.
  self._imagePool = nil
  if self.itemIconProvider then
    self.itemIconProvider:release()
    self.itemIconProvider = nil
  end
  if self.heroRenderer then
    self.heroRenderer:release()
    self.heroRenderer = nil
  end
  if self.partyScreenRenderer then
    self.partyScreenRenderer:release()
    self.partyScreenRenderer = nil
  end
  if self.followingMonTransitionRenderer then
    self.followingMonTransitionRenderer:dispose()
    self.followingMonTransitionRenderer = nil
  end
  if self.pokemonCenterHealRenderer then
    self.pokemonCenterHealRenderer:dispose()
    self.pokemonCenterHealRenderer = nil
  end
  self.bannerRenderer = nil
  if self._bannerSkin then
    self._bannerSkin.image:release()
    self._bannerSkin = nil
    self._bannerSkinKey = nil
  end
  self.areaPreviewRenderer = nil
  if self._previewImage then
    self._previewImage:release()
    self._previewImage = nil
    self._previewImageKey = nil
  end
  self.fieldEntryManifest = nil
  if self.textRenderer then
    self.textRenderer:release()
    self.textRenderer = nil
  end
  if self.battleTextRenderers then
    for role, renderer in pairs(self.battleTextRenderers) do
      renderer:release()
      self.battleTextRenderers[role] = nil
    end
    self.battleTextRenderers = nil
    self.phoneNameTextRenderer = nil
  end
  if self.fieldEntranceIndicatorRenderer then
    self.fieldEntranceIndicatorRenderer:dispose()
    self.fieldEntranceIndicatorRenderer = nil
  end
  if self.fieldSurfRenderer then
    self.fieldSurfRenderer:dispose()
    self.fieldSurfRenderer = nil
  end
  if self.fieldTerrainEffectRenderer then
    self.fieldTerrainEffectRenderer:dispose()
    self.fieldTerrainEffectRenderer = nil
  end
  if self.fieldEntranceIndicatorPool then
    self.fieldEntranceIndicatorPool:release()
    self.fieldEntranceIndicatorPool = nil
  end
  if self.fieldEmoteRenderer then
    self.fieldEmoteRenderer:dispose()
    self.fieldEmoteRenderer = nil
  end
  if self.fieldEmotePool then
    self.fieldEmotePool:release()
    self.fieldEmotePool = nil
  end
  if self.renderer then
    self.renderer:release()
    self.renderer = nil
  end
end

-- Advances the field-owned idle application warmup under the shared one
-- GPU realization budget: predicts the live party portrait selectors from
-- validated party copies and alternates progress across the Summary and
-- Pokedex owners. The Pokedex turn only advances an already-opened leaf
-- and never constructs one or enrolls producer work. At most one new pool
-- lease or canvas realizes per call. Failures stay diagnostic and never
-- disable the ordinary demand path.
---@param remainingGpu integer 0 or 1 speculative GPU realizations for the call
---@return boolean usedGpu true when the call realized a new pool lease or canvas
function FieldPresentationResources:advanceApplicationWarmup(remainingGpu)
  assert(remainingGpu == 0 or remainingGpu == 1, "idle staging spends at most one GPU realization")
  local runtime = self._presentationRuntime
  local selectors = self._warmPortraitSelectors
  if runtime ~= nil then
    local service = runtime.monService
    if type(service) == "table" and type(service.partyRevision) == "function" then
      local okRevision, revision = pcall(function()
        return service:partyRevision()
      end)
      if okRevision and revision ~= self._warmPartyRevision then
        local nextSelectors = {}
        local catalog = runtime.monCatalog
        if catalog == nil and type(service.catalog) == "function" then
          local okCatalog, resolved = pcall(function()
            return service:catalog()
          end)
          if okCatalog then
            catalog = resolved
          end
        end
        if
          type(catalog) == "table"
          and type(service.partyCount) == "function"
          and type(service.partyMon) == "function"
        then
          local okCount, count = pcall(function()
            return service:partyCount()
          end)
          if okCount and type(count) == "number" then
            local seen = {}
            for slot = 0, count - 1 do
              local okMon, mon = pcall(function()
                return service:partyMon(slot)
              end)
              if okMon and type(mon) == "table" and mon.isEgg ~= true then
                local okSelector, selector = pcall(SummaryModel.portraitSelectorFor, catalog, mon)
                if okSelector and type(selector) == "string" and not seen[selector] then
                  seen[selector] = true
                  nextSelectors[#nextSelectors + 1] = selector
                end
              end
            end
          end
        end
        self._warmPartyRevision = revision
        self._warmPortraitSelectors = nextSelectors
        selectors = nextSelectors
      end
    end
  end
  selectors = selectors or {}
  local first, second
  if self._warmNext == "pokedex" then
    first, second = "pokedex", "summary"
  else
    first, second = "summary", "pokedex"
  end
  self._warmNext = second
  local remaining = remainingGpu
  local used = false
  for _, name in ipairs({ first, second }) do
    local owner = nil
    if name == "summary" then
      owner = self.summaryResources
    else
      owner = self.pokedexResources
    end
    if owner ~= nil and type(owner.advanceWarmup) == "function" then
      local ok, ownerUsed, failure
      if name == "summary" then
        local roster = assert(selectors, "idle staging carries its selector memo")
        ok, ownerUsed, failure = pcall(function()
          return owner:advanceWarmup(roster, remaining)
        end)
      else
        ok, ownerUsed, failure = pcall(function()
          return owner:advanceWarmup(remaining)
        end)
      end
      if not ok then
        self._applicationWarmupFailure = name .. " idle staging raised: " .. tostring(ownerUsed)
      else
        if type(failure) == "string" and failure ~= "" then
          self._applicationWarmupFailure = name .. " idle staging deferred: " .. failure
        end
        if ownerUsed == true then
          used = true
          remaining = 0
        end
      end
    end
  end
  return used
end

--- Returns the lazily owned field pokedex preparation leaf, creating it
--- once from borrowed session services. The owner builds the one shared
--- renderer and serves both the browser and registration lease purposes;
--- the modal topology prevents ordinary overlap, but independent leases
--- stay independently testable.
---@return PokedexPresentationResources the one field-owned pokedex preparation leaf
function FieldPresentationResources:pokedex()
  local owned = self.pokedexResources
  if owned ~= nil then
    return owned
  end
  local runtime = assert(self._presentationRuntime, "pokedex preparation borrows the presented runtime")
  local created = PokedexPresentationResources.new({
    cacheFs = runtime.cacheFs,
    graphics = love and love.graphics,
    imagePool = assert(self._imagePool, "pokedex preparation borrows the shared image owner"),
    derivedAssets = runtime.derivedAssets or {},
    monCatalog = assert(runtime.monCatalog, "pokedex preparation borrows the shared mon catalog"),
    catalog = assert(runtime.pokedexCatalog, "pokedex preparation borrows the generated dex catalog"),
    text = self.textRenderer,
    messages = runtime.messageProvider,
    audio = runtime.audio,
  })
  self.pokedexResources = created
  return created
end

function FieldPresentationResources:easyChat()
  local owned = self.easyChatResources
  if owned ~= nil then
    return owned
  end
  local runtime = assert(self._presentationRuntime, "editor preparation borrows the presented runtime")
  local created = EasyChatPresentationResources.new({
    cacheFs = runtime.cacheFs,
    graphics = love and love.graphics,
    imagePool = assert(self._imagePool, "editor preparation borrows the shared image owner"),
    derivedAssets = runtime.derivedAssets or {},
    uiManifest = runtime.uiManifest,
    text0 = assert(self.textRenderer, "editor preparation borrows the Font0 renderer"),
    text1 = assert(self.battleTextRenderers.narration, "editor preparation borrows the Font1 renderer"),
    text4 = assert(self.battleTextRenderers.menu, "editor preparation borrows the Font4 renderer"),
    window = assert(self.windowRenderer, "editor preparation borrows the window renderer"),
  })
  self.easyChatResources = created
  return created
end

-- Draws the committed editor bundle through the supplied application
-- plan: pending preparation draws black over the editor panes and the
-- failed state surfaces its cause. Drawing never prepares, acquires, or
-- paints a generic outer frame.
---@param status table<string, unknown> committed editor screen status
function FieldPresentationResources:drawEasyChat(status)
  assert(type(status) == "table", "the editor application presents its status")
  local plan = assert(status.presentation, "the editor application presents its plan")
  local assets = status.assets
  local hostGraphics = love and love.graphics
  assert(type(hostGraphics) == "table", "editor drawing requires its host graphics namespace")
  if assets == nil then
    if status.preparationError ~= nil then
      error("editor preparation failed: " .. tostring(status.preparationError), 0)
    end
    for _, pane in ipairs(plan.panes or {}) do
      LogicalSurface.draw(hostGraphics, pane.placement, function()
        hostGraphics.setColor(0, 0, 0, 1)
        hostGraphics.rectangle("fill", 0, 0, 256, 192)
        hostGraphics.setColor(1, 1, 1, 1)
      end)
    end
    return
  end
  ApplicationPresentation.draw(hostGraphics, {
    graphics = hostGraphics,
    images = assets.images,
  }, status, plan)
end

-- Adapts the shared field text owners to the Options source token
-- service: Font0 paints menu glyphs and authored strings in the native
-- source palette roles, Font1 paints the preview token lines in the
-- source preview triple. One palette-shader pass per label; the shader
-- keeps the shared glyph shadow, so no manual double draw exists. The
-- shared owners are borrowed, never retained.
---@param fieldText FieldTextRenderer the shared presented Font0 text owner
---@param previewText FieldTextRenderer? the shared presented Font1 text owner
---@return OptionsWidgets.TextCollaborator the borrowed Options token text service
local function adaptOptionsText(fieldText, previewText)
  local MessageText = require("libs.assets.src.field.FieldMessageText")
  local menuDef = assert(fieldText.fontDef, "options presentation borrows the field Font0 font definition")
  -- Source layout controls the Options painter interprets. Anything else
  -- in a menu label record (substitutions, style, printer, or unknown
  -- controls) fails explicitly at the label's semantic role instead of
  -- painting a diagnostic marker.
  local allowedLayout = {
    [MessageText.ALN_CENTER] = true,
    [MessageText.ALN_RIGHT] = true,
    [MessageText.CURSOR_X] = true,
    [MessageText.CURSOR_Y] = true,
  }
  local function checkTokens(tokens, role)
    assert(type(tokens) == "table" and #tokens >= 1, "options " .. role .. " carries its glyph tokens")
    local placed = false
    for _, token in ipairs(tokens) do
      assert(type(token) == "table", "options " .. role .. " carries token records")
      if token.kind == "eos" then
        break
      elseif token.kind == "glyph" then
        placed = true
      elseif type(token.control) == "number" and allowedLayout[token.control] then
        if placed then
          error("options " .. role .. " places a position control after glyph content", 0)
        end
        local args = token.args or {}
        if token.control == MessageText.CURSOR_X or token.control == MessageText.CURSOR_Y then
          assert(#args == 1 and type(args[1]) == "number", "options " .. role .. " carries one validated cursor step")
        else
          assert(#args == 0, "options " .. role .. " carries no alignment step")
        end
      else
        local name = nil
        if type(token.control) == "number" then
          name = MessageText.controlName(token.control)
        end
        error("options " .. role .. " carries an unsupported " .. (name or (token.kind or "control")), 0)
      end
    end
  end
  local function slotBytes(fontDef, slot)
    local palette = assert(fontDef.palette, "options text needs the field font palette")
    local entry = assert(palette[slot + 1], "field font palette has no slot " .. slot)
    local function byte(value)
      local number = assert(tonumber(value), "field font palette slots carry RGB components")
      if number > 1 then
        number = number / 255
      end
      return number * 255
    end
    return { r = byte(entry.r or entry[1]), g = byte(entry.g or entry[2]), b = byte(entry.b or entry[3]) }
  end
  local function rolePalette(fontDef, role)
    assert(role == "normal" or role == "selected" or role == "preview", "options text uses its source roles")
    local foreground = slotBytes(fontDef, role == "normal" and 15 or 1)
    local shadow = slotBytes(fontDef, 2)
    if role == "preview" then
      local background = slotBytes(fontDef, 15)
      return { foreground = foreground, shadow = shadow, background = background }
    end
    local background = slotBytes(fontDef, 0)
    background.a = 0
    return { foreground = foreground, shadow = shadow, background = background }
  end
  local text = {}
  function text:drawTokens(tokens, x, y, role, sourceRole)
    checkTokens(tokens, sourceRole or "options label")
    return fieldText:drawLineWithPalette(tokens, x, y, rolePalette(menuDef, role))
  end
  function text:drawPlain(line, x, y, role)
    assert(type(line) == "string", "authored options labels stay strings")
    fieldText:drawTextWithPalette(line, x, y, rolePalette(menuDef, role))
  end
  function text:measureTokens(tokens, sourceRole)
    checkTokens(tokens, sourceRole or "options label")
    local width = 0
    for _, token in ipairs(tokens) do
      if token.kind == "glyph" then
        local glyph = menuDef.glyphs[token.code] or menuDef.glyphs[0]
        width = width + glyph.advance + (menuDef.letterSpacing or 0)
      end
    end
    return width
  end
  function text:measurePlain(line)
    assert(type(line) == "string", "authored options labels measure their string")
    local width = 0
    for char in Utf8Glyphs.iter(line) do
      local code = menuDef.charmap[char]
      if not code then
        code = 0
      end
      local glyph = menuDef.glyphs[code] or menuDef.glyphs[0]
      width = width + glyph.advance + (menuDef.letterSpacing or 0)
    end
    return width
  end
  function text:drawPreviewTokens(tokens, x, y)
    local preview = assert(previewText, "options preview printing borrows the field Font1 renderer")
    local previewDef = assert(preview.fontDef, "options preview printing borrows the Font1 font definition")
    preview:drawLineWithPalette(tokens, x, y, rolePalette(previewDef, "preview"))
  end
  function text:windowBackgroundColor()
    return fieldText:windowBackgroundColor()
  end
  return text
end

-- Creates one per-open options resource owner and returns the narrow
-- dot-call preparation port the screen steps: prepare advances the pooled
-- chrome toward readiness without blocking, dispose releases the owned
-- leases and clears only this same retained renderer, exactly once. A
-- duplicate open is a composition error; a stale dispose never clears a
-- newer owner. Field teardown also releases a still-held renderer, so
-- either disposal order is safe.
---@class FieldPresentationResources.OptionsPresentationPort narrow per-open dot-call preparation port
---@field prepare fun(): boolean step pooled chrome toward readiness without blocking
---@field dispose fun() release owned leases and clear only the same retained renderer, exactly once
---@return FieldPresentationResources.OptionsPresentationPort
function FieldPresentationResources:openOptionsPresentation()
  assert(self._optionsRenderer == nil, "one options presentation owns the presented lifetime")
  local narration = self.battleTextRenderers ~= nil and self.battleTextRenderers.narration or nil
  -- The sliders borrow the bag quantity-decrement pressed visual, resolved
  -- through the validated bag manifest so the bag stays the single owner
  -- of that art.
  local bagManifest = assert(self.bagManifest, "options presentation borrows the bag manifest for its slider thumb")
  local quantity = assert(
    bagManifest.interactive and bagManifest.interactive.overlays and bagManifest.interactive.overlays.quantity,
    "the bag manifest carries its quantity overlay for the options slider thumb"
  )
  local decrement = assert(
    quantity.visuals and quantity.visuals.decrement,
    "the bag manifest carries its quantity decrement visuals for the options slider thumb"
  )
  local thumb = assert(
    decrement.pressed,
    "the bag manifest carries the quantity-decrement pressed visual for the options slider thumb"
  )
  local renderer = OptionsRenderer.new({
    cacheFs = self.cacheFs,
    manifest = assert(self.uiManifest, "options presentation requires the field-UI manifest"),
    imagePool = assert(self._imagePool, "options presentation borrows the shared image owner"),
    text = adaptOptionsText(
      assert(self.textRenderer, "options presentation borrows the field text renderer"),
      narration
    ),
    window = assert(self.windowRenderer, "options presentation borrows the field window renderer"),
    sliderThumb = thumb,
  })
  self._optionsRenderer = renderer
  local port = {}
  function port.prepare()
    return renderer:prepare()
  end
  function port.dispose()
    if self._optionsRenderer == renderer then
      self._optionsRenderer = nil
    end
    renderer:dispose()
  end
  return port
end

-- Synchronizes the field-owned cached frame with the committed player
-- options. When the committed frame changed, the application border index
-- and the present Bag/Party/Mart renderer defaults follow before the next
-- draw; unchanged frames cost one comparison. Scalar-only: no image
-- acquisition, no draw, and no presentation-graph reconstruction.
---@param options table<string, unknown> the live committed player options
function FieldPresentationResources:syncPlayerOptions(options)
  local committed = assert(options, "frame synchronization reads the live player options")
  local frame = assert(committed.textFrame, "frame synchronization reads the committed frame")
  assert(type(frame) == "number" and frame % 1 == 0 and frame >= 0, "frame synchronization reads the committed frame")
  if frame == self._seenFrameIndex then
    return
  end
  self._seenFrameIndex = frame
  self.applicationFrameIndex = frame
  if self.bagRenderer ~= nil then
    self.bagRenderer:setFrameIndex(frame)
  end
  if self.partyScreenRenderer ~= nil then
    self.partyScreenRenderer:setFrameIndex(frame)
  end
  if self.martRenderer ~= nil then
    self.martRenderer:setFrameIndex(frame)
  end
end

---@return ApricornBoxRenderer renderer owned by this field presentation lifetime
function FieldPresentationResources:getApricornBoxRenderer()
  if self._apricornBoxRenderer == nil then
    local manifest = ApricornBoxAssetCache.loadManifest(self.cacheFs)
    self._apricornBoxRenderer = ApricornBoxRenderer.new({
      cacheFs = self.cacheFs,
      manifest = manifest,
      text = assert(self.textRenderer, "Apricorn Box presentation requires the field text renderer"),
      uiManifest = self.uiManifest,
      imagePool = self._imagePool,
    })
  end
  return self._apricornBoxRenderer
end

-- The Running Shoes focus borrows the Apricorn Box selection cursor states
-- so the start menu animates the same source cursor above its button. The
-- borrow stays optional: when the Apricorn Box derived cache is absent or
-- incomplete the menu still boots and focused shoes simply draw no cursor.
---@param cacheFs CacheFs
---@return table<string, unknown>? the cursor states, or nil when unavailable
function FieldPresentationResources._apricornSelectionCursor(cacheFs)
  local ok, manifest = pcall(ApricornBoxAssetCache.loadManifest, cacheFs)
  if not ok or type(manifest) ~= "table" then
    return nil
  end
  local cursor = manifest.selectionCursor
  if type(cursor) ~= "table" or type(cursor.states) ~= "table" then
    return nil
  end
  for _, state in pairs(cursor.states) do
    if type(state) ~= "table" or type(state.frames) ~= "table" then
      return nil
    end
    for _, frame in ipairs(state.frames) do
      if type(frame) ~= "table" or type(frame.image) ~= "string" then
        return nil
      end
      local existsOk, exists = pcall(function()
        return cacheFs:exists(frame.image, "file")
      end)
      if not existsOk or not exists then
        return nil
      end
    end
  end
  return cursor
end

return FieldPresentationResources
