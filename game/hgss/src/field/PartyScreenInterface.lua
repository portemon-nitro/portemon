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

-- The native pane extent the reveal covers: each covered pane carries one
-- opaque black rectangle in pane-local coordinates, bottom-anchored so
-- the covered region retreats downward as its leg advances.
local REVEAL_WIDTH = 256
local REVEAL_HEIGHT = 192
local REVEAL_STEPS = 6

-- Names the completed step driving one pane's cover: interaction content
-- clears with the second leg while any leading detail pane clears with the
-- first. A lone content pane therefore stays covered through the first leg
-- and clears with the second, so the wipe keeps its twelve-step recurrence
-- on single-pane topologies with no re-cover and no clear-but-gated window.
---@param opening table<string, unknown> the wrapper reveal progress
---@param paneId string the plan pane identity
---@return integer the completed steps for this pane
local function revealStep(opening, paneId)
  local first = assert(opening.subStep, "the reveal progress carries its first-leg step")
  local second = assert(opening.mainStep, "the reveal progress carries its second-leg step")
  assert(type(first) == "number", "the reveal progress carries its first-leg step")
  assert(type(second) == "number", "the reveal progress carries its second-leg step")
  if paneId == "content" then
    return second
  end
  return first
end

-- Draws one pane's reveal cover above its content: full cover at step
-- zero shrinking bottom-anchored to nothing at the final step, which
-- draws nothing. Restores the borrowed graphics color afterwards.
---@param graphics table<string, unknown> the injected host graphics
---@param opening table<string, unknown>? the reveal progress, or nil once interactive
---@param paneId string the plan pane identity
local function drawRevealCover(graphics, opening, paneId)
  if opening == nil then
    return
  end
  assert(type(opening) == "table", "the reveal progress stays a table while covered")
  local step = assert(revealStep(opening, paneId), "every pane maps to a reveal step")
  if step >= REVEAL_STEPS then
    return
  end
  assert(step >= 0 and step == math.floor(step), "the reveal step stays within its leg")
  local height = REVEAL_HEIGHT - (REVEAL_HEIGHT / REVEAL_STEPS) * step
  if height <= 0 then
    return
  end
  local setColor = assert(graphics.setColor, "the reveal cover borrows its host color")
  local red, green, blue, alpha = 1, 1, 1, 1
  if graphics.getColor then
    red, green, blue, alpha = graphics.getColor()
  end
  local ok, err = pcall(function()
    setColor(0, 0, 0, 1)
    graphics.rectangle("fill", 0, REVEAL_HEIGHT - height, REVEAL_WIDTH, height)
  end)
  if graphics.setColor then
    graphics.setColor(red, green, blue, alpha)
  end
  if not ok then
    error(err, 0)
  end
end

---@param resources table<string, unknown> borrowed application collaborators
---@param view table<string, unknown> the wrapper semantic snapshot
---@param plan ApplicationPlan
local function renderParty(resources, view, plan)
  local renderer = assert(resources.partyScreenRenderer, "the party render borrows its renderer")
  local icons = assert(resources.icons, "the party render borrows its icon provider")
  local graphics = assert(resources.graphics, "the party render borrows its host graphics")
  local LogicalSurface = require("libs.ui.src.LogicalSurface")
  local panes = assert(plan.panes, "the party plan carries its panes")
  for _, pane in ipairs(panes) do
    local placement = assert(pane.placement, "party panes carry placements")
    LogicalSurface.draw(graphics, placement, function()
      renderer.drawPane(renderer, view, pane, plan.content, icons)
      drawRevealCover(graphics, view.opening, assert(pane.id, "party panes carry identities"))
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
