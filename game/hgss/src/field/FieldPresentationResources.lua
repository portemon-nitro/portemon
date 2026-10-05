-- Owns the concrete GPU, UI, and field-effect resources used by FieldState.

local Errors = require("libs.errors.src.Errors")
local BagCache = require("libs.assets.src.BagCache")
local PcCache = require("libs.assets.src.PcCache")
local MartCache = require("libs.assets.src.MartCache")
local BagHeroRenderer = require("libs.hgss.src.presentation.BagHeroRenderer")
local BagRenderer = require("libs.hgss.src.ui.BagRenderer")
local MartRenderer = require("libs.hgss.src.ui.MartRenderer")
local FieldApplicationIds = require("libs.hgss.src.field.FieldApplicationIds")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")
local SummaryCache = require("libs.assets.src.SummaryCache")
local SummaryPresentationResources = require("game.hgss.src.field.SummaryPresentationResources")
local SummaryRenderer = require("libs.hgss.src.ui.SummaryRenderer")
local AssetPreparationQueue = require("libs.hgss.src.presentation.AssetPreparationQueue")
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
local ApplicationPresentation = require("libs.ui.src.ApplicationPresentation")
local TrainerCardRenderer = require("libs.hgss.src.ui.TrainerCardRenderer")
local PartyScreenRenderer = require("libs.hgss.src.ui.PartyScreenRenderer")
local PartyCache = require("libs.assets.src.PartyCache")
local MonIconAssetProvider = require("libs.hgss.src.presentation.MonIconAssetProvider")
local ItemIconAssetProvider = require("libs.hgss.src.presentation.ItemIconAssetProvider")
local FollowingMonTransitionRenderer = require("libs.hgss.src.presentation.FollowingMonTransitionRenderer")
local NamingScreenRenderer = require("libs.hgss.src.ui.NamingScreenRenderer")
local PcStorageRenderer = require("libs.hgss.src.ui.PcStorageRenderer")
local MailboxRenderer = require("libs.hgss.src.ui.MailboxRenderer")
local PhotoAlbumRenderer = require("libs.hgss.src.ui.PhotoAlbumRenderer")

---@alias PartyIconPrepare fun(iconKeys: string[]): boolean, string?
---@alias PartyIconCancel fun()
---@alias SummaryPreparationAcquire fun(): table<string, unknown>

---@class FieldPresentationResourcesRuntime
---@field cacheFs CacheFs
---@field derivedAssets table<string, function>? semantic derived-asset host in presented composition
---@field bindPartyIconPreparation fun(runtime: FieldPresentationResourcesRuntime, prepare: PartyIconPrepare, cancel: PartyIconCancel): integer? runtime party preparation binding in presented composition
---@field unbindPartyIconPreparation fun(runtime: FieldPresentationResourcesRuntime, binding: integer)? runtime preparation unbinding in presented composition
---@field bindSummaryPreparation (fun(runtime: FieldPresentationResourcesRuntime, acquire: SummaryPreparationAcquire): integer)? runtime summary preparation binding in presented composition
---@field unbindSummaryPreparation (fun(runtime: FieldPresentationResourcesRuntime, binding: integer))? runtime summary preparation unbinding in presented composition
---@field uiManifest table<string, unknown>
---@field playerData table<string, unknown> the validated profile/options authority
---@field windowStyles FieldWindowStyles
---@field fieldEntranceIndicatorAsset table<string, unknown>
---@field fieldEmoteModels table<string, table<string, unknown>>
---@field fieldEffectAssets table<string, unknown>
---@field fieldTerrainEffectController FieldTerrainEffectController
---@field followerTransitionDefinition table<string, unknown>?
---@field followingMonTransition FollowingMonTransitionController?

---@class FieldPresentationResources
---@field cacheFs CacheFs generated asset filesystem
---@field uiManifest table<string, unknown> validated field UI manifest
---@field renderer FieldRenderer?
---@field windowRenderer FieldWindowRenderer? the one shared frame-strip atlas owner lent to dialogue rendering
---@field applicationFrameIndex integer? the snapshotted player-owned frame choice for application borders
---@field dialogueRenderer FieldDialogueRenderer?
---@field yesNoRenderer FieldYesNoRenderer
---@field menuRenderer FieldMenuRenderer
---@field signpostRenderer FieldSignpostRenderer?
---@field startMenuRenderer StartMenuRenderer?
---@field trainerCardRenderer TrainerCardRenderer?
---@field partyScreenRenderer PartyScreenRenderer?
---@field monIconProvider MonIconAssetProvider? the one shared party-icon atlas for the state lifetime
---@field namingRenderer NamingScreenRenderer? lazily owned script naming renderer
---@field namingIconQuads table<string, table<integer, unknown>> prepared mon icon frames borrowed from the provider
---@field imageQueue AssetPreparationQueue? the one owned worker decoding party icon pages
---@field _presentationRuntime FieldPresentationResourcesRuntime? borrowed runtime owning the party preparation binding
---@field _partyIconBinding integer? installed preparation binding identity
---@field _summaryBinding integer? installed summary preparation binding identity
---@field summaryResources SummaryPresentationResources? the one field-owned summary preparation leaf
---@field summaryRenderer SummaryRenderer? the one real summary pane renderer
---@field summaryBadgeImages table<string, table<string, unknown>>? realized leaf/crown art by frame image path
---@field _summaryPartyManifest table<string, unknown>? the borrowed party badge geometry for summary leaves
---@field itemIconProvider ItemIconAssetProvider the one shared bag item-icon atlas
---@field heroRenderer BagHeroRenderer the one bag hero model renderer borrowed by the bag renderer
---@field bagRenderer BagRenderer the one field-bag pane renderer
---@field pcManifest table<string, unknown> validated PC manifest borrowed by its application renderers
---@field storageRenderer PcStorageRenderer PC Storage renderer
---@field mailboxRenderer MailboxRenderer Mailbox renderer
---@field photoAlbumRenderer PhotoAlbumRenderer Photo Album renderer
---@field martRenderer MartRenderer? owned source-layered mart background and prompt images
---@field followingMonTransitionRenderer FollowingMonTransitionRenderer? transient follower-transition presentation (nil without the generated definition)
---@field textRenderer FieldTextRenderer?
---@field fieldEntranceIndicatorPool GpuAssetPool?
---@field fieldEntranceIndicatorRenderer FieldStaticEffectRenderer?
---@field fieldSurfRenderer FieldStaticEffectRenderer?
---@field surfPresentation table<string, unknown>
---@field fieldEmotePool GpuAssetPool?
---@field fieldEmoteRenderer FieldActorEmoteRenderer?
---@field fieldTerrainEffectRenderer FieldTerrainEffectRenderer?
---@field presenters table<string, FieldPresentationApplicationPresenter>? the per-instance application presenter map
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
  -- render its wait text through the bag application too. Drawing never
  -- invokes icon getters, so no draw ever acquires resources.
  ---@param presentation table<string, unknown>?
  ---@return boolean handled
  local function drawPartyWait(presentation)
    local state = presentation and presentation.preparationState
    if state ~= "pending" and state ~= "failed" then
      return false
    end
    local status = assert(presentation, "the party application presents its layout")
    local layout = assert(status.layout, "the party application presents its layout")
    local frame = assert(layout.frame, "the party layout carries its frame")
    local text = assert(owner.textRenderer, "party text renderer is unavailable")
    if state == "pending" then
      text:drawText("Preparing party icons...", frame.x + 8, frame.y + 8)
    else
      text:drawText("Party icons unavailable: " .. tostring(status.preparationError), frame.x + 8, frame.y + 8)
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
  -- The summary wait screen mirrors the party wait contract over the
  -- wrapper-owned preparation state: pending shows the host preparation
  -- cover, failure shows the explicit cause with cancellation. Drawing
  -- never invokes bundle getters, so no draw ever acquires resources.
  ---@param presentation table<string, unknown>?
  ---@return boolean handled
  local function drawSummaryWait(presentation)
    local state = presentation and presentation.preparationState
    if state ~= "pending" and state ~= "failed" then
      return false
    end
    local text = assert(owner.textRenderer, "summary text renderer is unavailable")
    if state == "pending" then
      text:drawText("Preparing summary...", 8, 8)
    else
      local status = assert(presentation, "the summary application presents its status")
      text:drawText("Summary unavailable: " .. tostring(status.preparationError), 8, 8)
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
      -- The draw bundle joins the wrapper's ready lease bundle (never
      -- copied GPU objects, only the record) with the field-owned party
      -- badge art the lease bundle does not own.
      local bundle = {}
      local ready = assert(status.resources, "the summary plan carries its ready bundle")
      assert(type(ready) == "table", "the summary plan carries its ready bundle")
      for key, value in pairs(ready) do
        bundle[key] = value
      end
      local badges = owner.summaryBadgeImages or {}
      bundle.partyManifest = bundle.partyManifest or owner._summaryPartyManifest
      bundle.badgeImage = bundle.badgeImage
        or function(frame)
          return badges[assert(frame.image, "badge frames carry their image path")]
        end
      resources.summaryBundle = bundle
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
  return {
    [FieldApplicationIds.POKEMON] = drawPokemon,
    [FieldApplicationIds.TRAINER_CARD] = drawTrainerCard,
    [FieldApplicationIds.BAG] = drawBag,
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
    self.windowRenderer = FieldWindowRenderer.new({ cacheFs = runtime.cacheFs, manifest = runtime.uiManifest })
    local textRenderer = FieldTextRenderer.new({ cacheFs = runtime.cacheFs })
    self.textRenderer = textRenderer
    local playerData = assert(runtime.playerData, "field presentation requires the validated player data")
    local playerOptions = assert(playerData.options, "field presentation requires the player options")
    local textFrame = assert(playerOptions.textFrame, "field presentation requires the player-owned frame index")
    assert(
      type(textFrame) == "number" and textFrame % 1 == 0 and textFrame >= 0,
      "field presentation requires the player-owned frame index"
    )
    ---@cast textFrame integer
    self.applicationFrameIndex = textFrame
    self.dialogueRenderer = FieldDialogueRenderer.new({
      cacheFs = runtime.cacheFs,
      manifest = runtime.uiManifest,
      text = textRenderer,
      windowRenderer = self.windowRenderer,
    })
    self.yesNoRenderer = FieldYesNoRenderer.new({ text = textRenderer, window = self.windowRenderer })
    self.menuRenderer = FieldMenuRenderer.new()
    self.signpostRenderer = FieldSignpostRenderer.new({
      cacheFs = runtime.cacheFs,
      manifest = runtime.uiManifest,
      text = textRenderer,
      windowStyles = runtime.windowStyles,
    })
    self.startMenuRenderer = StartMenuRenderer.new({
      cacheFs = runtime.cacheFs,
      manifest = runtime.uiManifest,
      text = textRenderer,
    })
    self.trainerCardRenderer = TrainerCardRenderer.new({
      cacheFs = runtime.cacheFs,
      manifest = runtime.uiManifest,
      text = textRenderer,
    })
    self.partyScreenRenderer = PartyScreenRenderer.new({
      cacheFs = runtime.cacheFs,
      manifest = PartyCache.loadManifest(runtime.cacheFs),
      uiManifest = runtime.uiManifest,
      text = textRenderer,
      window = self.windowRenderer,
      frameIndex = self.applicationFrameIndex,
    })
    self.imageQueue = AssetPreparationQueue.new(runtime.cacheFs)
    self.monIconProvider = MonIconAssetProvider.new(runtime.cacheFs, {
      preparationQueue = self.imageQueue,
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
    -- The summary preparation leaf is metadata-only at construction:
    -- no image realizes before a wrapper lease demands it. The leaf and
    -- its binding install only when the runtime offers the seam and the
    -- generated family reads; drawing always rides wrapper-supplied
    -- ready bundles either way, so a cache-unreadable harness still
    -- draws through the real renderer.
    self.summaryRenderer = SummaryRenderer.new({ text = textRenderer })
    self.summaryBadgeImages = self:_realizeSummaryBadges()
    local summaryOwnerOk, summaryOwner = pcall(function()
      return SummaryPresentationResources.new({
        cacheFs = runtime.cacheFs,
        graphics = assert(love and love.graphics, "summary preparation needs its graphics namespace"),
        text = textRenderer,
        icons = provider,
        preparationQueue = self.imageQueue,
        derivedAssets = runtime.derivedAssets or {},
        manifest = SummaryCache.loadManifest(runtime.cacheFs),
      })
    end)
    if summaryOwnerOk then
      self.summaryResources = summaryOwner
      if type(runtime.bindSummaryPreparation) == "function" then
        local owner = assert(self.summaryResources, "summary preparation is unavailable")
        local function acquireSummary()
          return owner:acquire()
        end
        self._summaryBinding = runtime.bindSummaryPreparation(runtime, acquireSummary)
      end
    end
    -- Bag presentation resolves eagerly beside the party icons: field entry
    -- boots only when the compiled item/bag caches are present, and the
    -- launch-time capability gate in the FieldRuntime bag factory still
    -- fails fast on missing service/cursor/catalog/assets when Bag opens.
    self.itemIconProvider = ItemIconAssetProvider.new(runtime.cacheFs)
    -- The bag manifest loads once: the 2D pane renderer and the borrowed
    -- hero model renderer share the same validated table.
    local bagManifest = BagCache.loadManifest(runtime.cacheFs)
    self.heroRenderer = BagHeroRenderer.new({ cacheFs = runtime.cacheFs, manifest = bagManifest })
    self.bagRenderer = BagRenderer.new({
      cacheFs = runtime.cacheFs,
      manifest = bagManifest,
      promptManifest = runtime.uiManifest,
      text = textRenderer,
      heroRenderer = self.heroRenderer,
      window = self.windowRenderer,
      frameIndex = self.applicationFrameIndex,
    })
    self.martRenderer = MartRenderer.new({
      cacheFs = runtime.cacheFs,
      manifest = MartCache.loadManifest(runtime.cacheFs),
      uiManifest = runtime.uiManifest,
      text = textRenderer,
      window = self.windowRenderer,
      frameIndex = self.applicationFrameIndex,
    })
    self.pcManifest = PcCache.loadManifest(runtime.cacheFs)
    local graphics = assert(love and love.graphics, "PC application rendering requires LÖVE graphics")
    self.storageRenderer = PcStorageRenderer.new({
      graphics = graphics,
      cacheFs = runtime.cacheFs,
      manifest = self.pcManifest,
      text = textRenderer,
    })
    self.mailboxRenderer = MailboxRenderer.new({
      graphics = graphics,
      cacheFs = runtime.cacheFs,
      manifest = self.pcManifest,
    })
    self.photoAlbumRenderer = PhotoAlbumRenderer.new({
      graphics = graphics,
      cacheFs = runtime.cacheFs,
      manifest = self.pcManifest,
    })
    local entrancePool = GpuAssetPool.new(runtime.cacheFs)
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
    local surfEffects = runtime.fieldEntranceIndicatorAsset.effects
    local surfAttachment =
      assert(surfEffects and surfEffects.surf_attachment, "field-effect cache is missing surf_attachment")
    self.surfPresentation = assert(surfAttachment.presentation, "field-effect cache is missing surf presentation")
    self.fieldSurfRenderer = FieldStaticEffectRenderer.new(surfAttachment.model, entrancePool)
    local emotePool = GpuAssetPool.new(runtime.cacheFs)
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

-- Realizes the two first-frame leaf/crown badge images from the party
-- family once for the field lifetime: the summary renderer draws them
-- through stable anchors without owning party art. A host without love
-- filesystem support (headless doubles) feeds raw bytes; production
-- wraps FileData. Missing badge records skip the layer instead of
-- failing the whole presentation owner.
---@return table<string, table<string, unknown>> realized badge images by frame image path
function FieldPresentationResources:_realizeSummaryBadges()
  local realized = {}
  local ok, partyManifest = pcall(PartyCache.loadManifest, self.cacheFs)
  if not ok then
    return realized
  end
  if type(partyManifest) ~= "table" then
    return realized
  end
  self._summaryPartyManifest = partyManifest
  if type(partyManifest.shinyLeaves) ~= "table" then
    return realized
  end
  local leavesRecord = partyManifest.shinyLeaves
  local frames = {}
  if type(leavesRecord.leaves) == "table" and type(leavesRecord.leaves.frames) == "table" then
    frames[#frames + 1] = leavesRecord.leaves.frames[1]
  end
  if type(leavesRecord.crown) == "table" and type(leavesRecord.crown.frames) == "table" then
    frames[#frames + 1] = leavesRecord.crown.frames[1]
  end
  local graphics = assert(love and love.graphics, "summary badges need their graphics namespace")
  for _, frame in ipairs(frames) do
    if type(frame) == "table" and type(frame.image) == "string" and realized[frame.image] == nil then
      local readOk, bytes = pcall(self.cacheFs.read, self.cacheFs, frame.image)
      if readOk then
        assert(bytes ~= nil, "summary badge missing at " .. frame.image)
        local image = nil
        if love.filesystem and love.filesystem.newFileData then
          image = graphics.newImage(love.filesystem.newFileData(bytes, frame.image))
        else
          image = graphics.newImage(bytes)
        end
        if type(image.setFilter) == "function" then
          image:setFilter("nearest", "nearest")
        end
        realized[frame.image] = image
      end
    end
  end
  return realized
end

-- Creates naming chrome only after the shared icon provider reports readiness.
---@param owner FieldPresentationResources
---@return NamingScreenRenderer
local function ensurePokemonNamingRenderer(owner)
  if owner.namingRenderer ~= nil then
    return owner.namingRenderer
  end
  local graphics = assert(love and love.graphics, "Pokemon naming renderer requires graphics")
  local function imageLoader(path)
    local bytes = assert(owner.cacheFs:read(path), "missing generated naming image " .. path)
    return graphics.newImage(love.filesystem.newFileData(bytes, path))
  end
  local function drawSubject(hostGraphics, subject, placement)
    local iconKey = assert(subject.iconKey, "Pokemon naming subject requires its icon key")
    local iconFrames =
      assert(owner.namingIconQuads[iconKey], "Pokemon naming icon frames were not prepared before draw")
    local quad = assert(iconFrames[placement.frameIndex], "Pokemon naming icon frame was not prepared before draw")
    hostGraphics.draw(
      assert(owner.monIconProvider, "field presentation owns the mon icon provider"):image(iconKey),
      quad,
      placement.x,
      placement.y
    )
  end
  local renderer = NamingScreenRenderer.new({
    graphics = graphics,
    text = assert(owner.textRenderer, "field text renderer is unavailable"),
    drawSubject = drawSubject,
    manifest = assert(owner.uiManifest, "field UI manifest is unavailable"),
    imageLoader = imageLoader,
  })
  owner.namingRenderer = renderer
  return renderer
end

---@param subject table<string, unknown>
---@return boolean ready
---@return string? failure
function FieldPresentationResources:preparePokemonNamingSubject(subject)
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
  ensurePokemonNamingRenderer(self)
  return true, nil
end

---@return NamingScreenRenderer the renderer prepared by a successful naming preparation
function FieldPresentationResources:pokemonNamingRenderer()
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
  elseif status.app == "mailbox" then
    for _, icon in ipairs(assert(status.icons, "Mailbox status publishes message icon snapshots")) do
      iconKeys[#iconKeys + 1] = icon.iconKey
    end
  else
    error("PC application kind has no presentation preparation", 0)
  end
  return assert(self.monIconProvider, "PC applications borrow the shared mon icon provider"):prepareKeys(iconKeys)
end

---@param runtime FieldRuntime runtime owners borrowed by the app renderers
---@return table<string, unknown>
function FieldPresentationResources:pcApplicationResources(runtime)
  return {
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
end

function FieldPresentationResources:dispose()
  self.presenters = nil
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
  local presentationRuntime = self._presentationRuntime
  self._partyIconBinding = nil
  self._summaryBinding = nil
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
  if self.summaryResources then
    self.summaryResources:release()
    self.summaryResources = nil
  end
  self.summaryRenderer = nil
  self._summaryPartyManifest = nil
  if self.summaryBadgeImages then
    for _, image in pairs(self.summaryBadgeImages) do
      if type(image.release) == "function" then
        image:release()
      end
    end
    self.summaryBadgeImages = nil
  end
  if self.imageQueue then
    self.imageQueue:release()
    self.imageQueue = nil
  end
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
  if self.textRenderer then
    self.textRenderer:release()
    self.textRenderer = nil
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

return FieldPresentationResources
