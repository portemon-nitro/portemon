-- The current Bag's four function references with matching render and
-- input callbacks. DualDisplay maps the hero to the world surface and the
-- interaction to auxiliary; wide pairs hero left of interaction and tall
-- stacks hero above, sharing one integer scale with no synthetic gap;
-- nativeLike shows only the interaction pane with the canonical description
-- fallback. The lower pane never crops (its controls reach the source
-- edges); the hero may use the default four-edge budget only for a true
-- cover of its own physical display. A pair that cannot fit 1x falls back
-- to the nativeLike case. Underfilled panes carry fitted chrome: one
-- complete outer frame around the pair envelope, or one per underfilled
-- physical pane. Resolvers require the complete context the owning
-- session supplies.

local ApplicationLayout = require("game.hgss.src.ui.ApplicationLayout")
local BagLayout = require("libs.hgss.src.ui.BagLayout")
local NativeDisplay = require("libs.ui.src.NativeDisplay")

---@class BagInterface
local BagInterface = {}

local HERO_NATIVE = { id = "hero", width = NativeDisplay.WIDTH, height = NativeDisplay.HEIGHT }
local INTERACTION_NATIVE = { id = "interaction", width = NativeDisplay.WIDTH, height = NativeDisplay.HEIGHT }
local INPUT_KEY = "bag"
local ZERO_CROP = { left = 0, right = 0, top = 0, bottom = 0 }

---@param resources table<string, unknown> borrowed application collaborators
---@param view table<string, unknown> the wrapper semantic snapshot
---@param plan ApplicationPlan
local function renderBag(resources, view, plan)
  local renderer = assert(resources.bagRenderer, "the bag render borrows its renderer")
  local icons = assert(resources.icons, "the bag render borrows its icon provider")
  renderer --[[@as { draw: fun(self: table<string, unknown>, presentation: table<string, unknown>, plan: table<string, unknown>, collaborators: table<string, unknown>) }]].draw(
    renderer,
    view,
    plan,
    { icons = icons }
  )
end

---@param event table<string, unknown> session-inverted logical input
---@return table<string, unknown>? the app event, or nil when the bag ignores it
local function mapBagInput(event, _, _)
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
    inputKey = "bag-inactive",
    render = noopRender,
    mapInput = noopMap,
  }
end

---@param manifest table<string, unknown> the validated bag presentation manifest
---@param heroVisible boolean true when the resolved panes include the hero
---@param panes table<integer, table<string, unknown>> the resolved ordered panes
---@param frames table<integer, table<string, unknown>> the static outer-frame geometry
---@return ApplicationPlan
local function bagPlan(manifest, heroVisible, panes, frames)
  return {
    panes = panes,
    frames = frames,
    content = BagLayout.resolve({ manifest = manifest, heroVisible = heroVisible }),
    inputKey = INPUT_KEY,
    render = renderBag,
    mapInput = mapBagInput,
  }
end

-- Binds the validated manifest and returns the default resolver set: the
-- manifest rides the resolver closures; the effective nativeLike entry
-- backs the pair fallback below.
---@param manifest table<string, unknown> the validated bag presentation manifest
---@return table<string, fun(context: ApplicationLayout.Context, view: table<string, unknown>): ApplicationPlan>
function BagInterface.defaults(manifest)
  assert(type(manifest) == "table", "the bag interface requires its validated manifest")

  local set = {}

  -- DualDisplay: hero on the world surface, interaction on auxiliary. The
  -- hero may use the default four-edge crop budget only to cover its own
  -- display; the edge-reaching lower pane never crops. Each underfilled
  -- physical pane carries its own complete outer frame.
  ---@param context ApplicationLayout.Context
  ---@param view table<string, unknown>
  ---@return ApplicationPlan
  local function dualDisplay(context, view)
    local _ = view
    local geometry = ApplicationLayout.nativeDual(context, HERO_NATIVE, INTERACTION_NATIVE, {
      lower = { maxOverdraw = ZERO_CROP },
    })
    local hero = geometry.placements[HERO_NATIVE.id]
    local interaction = geometry.placements[INTERACTION_NATIVE.id]
    if hero == nil or interaction == nil then
      return inactivePlan()
    end
    return bagPlan(manifest, true, {
      { id = HERO_NATIVE.id, placement = hero, interactive = false },
      { id = INTERACTION_NATIVE.id, placement = interaction, interactive = true },
    }, geometry.frames or {})
  end

  -- NativeLike: only the interaction pane with the canonical description
  -- fallback carrying the compact information the hidden hero would show.
  -- A covered target stays unframed; an underfilled one refits as a
  -- complete decorated box with zero crop.
  ---@param context ApplicationLayout.Context
  ---@param view table<string, unknown>
  ---@return ApplicationPlan
  local function nativeLike(context, view)
    local _ = view
    local geometry = ApplicationLayout.coverOrFrame(context, INTERACTION_NATIVE, { maxOverdraw = ZERO_CROP })
    local interaction = geometry.placements[INTERACTION_NATIVE.id]
    if interaction == nil then
      return inactivePlan()
    end
    return bagPlan(manifest, false, {
      { id = INTERACTION_NATIVE.id, placement = interaction, interactive = true },
    }, geometry.frames or {})
  end
  set.nativeLike = nativeLike

  -- Wide: hero left, interaction right, one shared integer scale with no
  -- gap and one frame around the common envelope. A pair that cannot fit
  -- 1x falls back to the effective nativeLike entry without changing the
  -- measured configuration.
  ---@param context ApplicationLayout.Context
  ---@param view table<string, unknown>
  ---@return ApplicationPlan
  local function wide(context, view)
    local geometry = ApplicationLayout.sideBySide(context, HERO_NATIVE, INTERACTION_NATIVE)
    if geometry == nil then
      return context.nativeLikeInterface(context, view)
    end
    local hero = geometry.placements[HERO_NATIVE.id]
    local interaction = geometry.placements[INTERACTION_NATIVE.id]
    if hero == nil or interaction == nil then
      return inactivePlan()
    end
    return bagPlan(manifest, true, {
      { id = HERO_NATIVE.id, placement = hero, interactive = false },
      { id = INTERACTION_NATIVE.id, placement = interaction, interactive = true },
    }, geometry.frames or {})
  end

  -- Tall: hero above, interaction below, one shared integer scale with no
  -- gap and one fitted frame around the common envelope, with the same 1x
  -- fallback as wide.
  ---@param context ApplicationLayout.Context
  ---@param view table<string, unknown>
  ---@return ApplicationPlan
  local function tall(context, view)
    local geometry = ApplicationLayout.stacked(context, HERO_NATIVE, INTERACTION_NATIVE)
    if geometry == nil then
      return context.nativeLikeInterface(context, view)
    end
    local hero = geometry.placements[HERO_NATIVE.id]
    local interaction = geometry.placements[INTERACTION_NATIVE.id]
    if hero == nil or interaction == nil then
      return inactivePlan()
    end
    return bagPlan(manifest, true, {
      { id = HERO_NATIVE.id, placement = hero, interactive = false },
      { id = INTERACTION_NATIVE.id, placement = interaction, interactive = true },
    }, geometry.frames or {})
  end

  set.dualDisplay = dualDisplay
  set.wide = wide
  set.tall = tall
  return set
end

return BagInterface
