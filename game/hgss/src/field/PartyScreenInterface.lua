-- The native party screen's function references with matching render
-- and input callbacks. DualDisplay pairs detail on the world surface with
-- interaction on auxiliary; wide pairs detail left of interaction and
-- tall stacks detail above interaction, sharing one integer scale with no
-- synthetic gap; nativeLike shows the single interaction pane, and a
-- wrapper-owned host toggle appends the source-framed detail overlay
-- without touching native content. Pairs
-- that cannot fit 1x fall back to the effective nativeLike entry without
-- changing the measured configuration. The content is the canonical
-- manifest-backed native pane; input passes visible logical points to
-- the existing controller and drops matte taps. A per-case override
-- replaces the whole render/input pair, never a mode token. Resolvers
-- require the complete context the owning session supplies.

local ApplicationLayout = require("libs.ui.src.ApplicationLayout")
local NativeDisplay = require("libs.ui.src.NativeDisplay")
local PartyScreenLayout = require("libs.hgss.src.ui.PartyScreenLayout")

---@class PartyScreenInterface
local PartyScreenInterface = {}

local DETAIL_NATIVE = { id = "detail", width = NativeDisplay.WIDTH, height = NativeDisplay.HEIGHT }
local CONTENT_NATIVE = { id = "content", width = NativeDisplay.WIDTH, height = NativeDisplay.HEIGHT }
local INPUT_KEY = "party"
local ZERO_CROP = { left = 0, right = 0, top = 0, bottom = 0 }

---@param resources table<string, unknown> borrowed application collaborators
---@param view table<string, unknown> the wrapper semantic snapshot
---@param plan ApplicationPlan
local function renderParty(resources, view, plan)
  local renderer = assert(resources.partyScreenRenderer, "the party render borrows its renderer")
  local icons = assert(resources.icons, "the party render borrows its icon provider")
  local graphics = assert(resources.graphics, "the party render borrows its host graphics")
  local LogicalSurface = require("libs.ui.src.LogicalSurface")
  for _, pane in ipairs(assert(plan.panes, "the party plan carries its panes")) do
    local placement = assert(pane.placement, "party panes carry placements")
    LogicalSurface.draw(graphics, placement, function()
      renderer.drawPane(renderer, view, pane, plan.content, icons)
    end)
  end
end

---@param event table<string, unknown> session-inverted logical input
---@return table<string, unknown>? the app event, or nil when the party ignores it
local function mapPartyInput(event, _, _)
  if event.type == "pointer_down" and event.outside == true then
    return { type = "dismiss" }
  end
  return event
end

local function noopRender(_, _, _) end

---@return nil
local function noopMap(_, _, _)
  return nil
end

---@return ApplicationPlan a valid inactive plan: no panes, no targets, cancellation still deliverable
local function inactivePlan()
  return {
    panes = {},
    frames = {},
    content = {},
    inputKey = "party-inactive",
    render = noopRender,
    mapInput = noopMap,
  }
end

-- Binds the validated manifest and returns the default resolver set: the
-- manifest rides the resolver closures; the effective nativeLike entry
-- backs the below-1x framed fallback.
---@param manifest table<string, unknown> the validated party presentation manifest
---@return table<string, fun(context: ApplicationLayout.Context, view: table<string, unknown>): ApplicationPlan>
function PartyScreenInterface.defaults(manifest)
  assert(type(manifest) == "table", "the party interface requires its validated manifest")

  ---@param view table<string, unknown> the wrapper semantic snapshot
  ---@return table<string, unknown> the canonical native content for the controller's cancel permission
  local function partyContent(view)
    -- A closed snapshot carries no cancel permission; its plan is discarded
    -- at disposal, so the controller default applies without changing
    -- visible behavior.
    local cancellable = view.cancellable
    if type(cancellable) ~= "boolean" then
      cancellable = true
    end
    return PartyScreenLayout.resolve({ manifest = manifest, cancellable = cancellable })
  end

  ---@param panes table[] the resolved panes
  ---@param frames table[] the resolved outer frames
  ---@param content table<string, unknown> the canonical content
  ---@return ApplicationPlan
  local function partyPlan(panes, frames, content)
    return {
      panes = panes,
      frames = frames,
      content = content,
      inputKey = INPUT_KEY,
      render = renderParty,
      mapInput = mapPartyInput,
    }
  end

  -- Fullscreen party for the single-surface nativeLike case: one canonical
  -- interactive pane over the owned target region, never cropped. A target
  -- the pane genuinely covers stays unframed; an underfilled target refits
  -- as a complete decorated box with zero crop. The wrapper-owned host
  -- toggle appends the source-framed detail overlay at the same placement;
  -- native content carries no host target.
  ---@param context ApplicationLayout.Context
  ---@param view table<string, unknown>
  ---@return ApplicationPlan
  local function nativeLikeImpl(context, view)
    local geometry = ApplicationLayout.coverOrFrame(context, CONTENT_NATIVE, { maxOverdraw = ZERO_CROP })
    local placement = geometry.placements[CONTENT_NATIVE.id]
    if placement == nil then
      return inactivePlan()
    end
    local panes = { { id = CONTENT_NATIVE.id, placement = placement, interactive = true } }
    if view.detailOverlay == true then
      panes[#panes + 1] = { id = "overlay", placement = placement, interactive = false }
    end
    return partyPlan(panes, geometry.frames or {}, partyContent(view))
  end
  -- Static framed party for the wide and tall cases: detail beside the
  -- canonical pane at one shared integer scale. A pair that cannot fit 1x
  -- falls back to the effective nativeLike case with the same context and
  -- view; the configuration keeps describing the actual measured display.
  ---@param context ApplicationLayout.Context
  ---@param view table<string, unknown>
  ---@param horizontal boolean
  ---@return ApplicationPlan
  local function paired(context, view, horizontal)
    local geometry
    if horizontal then
      geometry = ApplicationLayout.sideBySide(context, DETAIL_NATIVE, CONTENT_NATIVE)
    else
      geometry = ApplicationLayout.stacked(context, DETAIL_NATIVE, CONTENT_NATIVE)
    end
    if geometry == nil then
      return context.nativeLikeInterface(context, view)
    end
    local detail = geometry.placements[DETAIL_NATIVE.id]
    local interaction = geometry.placements[CONTENT_NATIVE.id]
    if detail == nil or interaction == nil then
      return inactivePlan()
    end
    return partyPlan({
      { id = DETAIL_NATIVE.id, placement = detail, interactive = false },
      { id = CONTENT_NATIVE.id, placement = interaction, interactive = true },
    }, geometry.frames or {}, partyContent(view))
  end

  -- DualDisplay: detail on the world surface, interaction on auxiliary.
  -- Each underfilled physical pane carries its own complete outer frame.
  ---@param context ApplicationLayout.Context
  ---@param view table<string, unknown>
  ---@return ApplicationPlan
  local function dualDisplay(context, view)
    local geometry = ApplicationLayout.nativeDual(context, DETAIL_NATIVE, CONTENT_NATIVE, {
      lower = { maxOverdraw = ZERO_CROP },
    })
    local detail = geometry.placements[DETAIL_NATIVE.id]
    local interaction = geometry.placements[CONTENT_NATIVE.id]
    if detail == nil or interaction == nil then
      return inactivePlan()
    end
    return partyPlan({
      { id = DETAIL_NATIVE.id, placement = detail, interactive = false },
      { id = CONTENT_NATIVE.id, placement = interaction, interactive = true },
    }, geometry.frames or {}, partyContent(view))
  end

  ---@param context ApplicationLayout.Context
  ---@param view table<string, unknown>
  ---@return ApplicationPlan
  local function wideCase(context, view)
    return paired(context, view, true)
  end
  ---@param context ApplicationLayout.Context
  ---@param view table<string, unknown>
  ---@return ApplicationPlan
  local function tallCase(context, view)
    return paired(context, view, false)
  end

  return {
    dualDisplay = dualDisplay,
    nativeLike = nativeLikeImpl,
    wide = wideCase,
    tall = tallCase,
  }
end

return PartyScreenInterface
