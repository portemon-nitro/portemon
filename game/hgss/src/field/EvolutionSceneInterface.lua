-- Host placement of the menu-opened evolution scene with matching render
-- and input callbacks. Dual pairs main above sub; wide and tall pair them
-- at one shared integer scale, falling back to the single-display entry
-- when a pair cannot fit. The single-display entry shows the main pane and
-- switches to the sub pane while the learn menu or the Summary move picker
-- owns the scene. New touches on the sub pane reach the scene in its
-- lower-screen local coordinates; every other pointer edge is dropped.

local ApplicationLayout = require("libs.ui.src.ApplicationLayout")
local BattleRenderer = require("game.hgss.src.battle.BattleRenderer")
local LogicalSurface = require("libs.ui.src.LogicalSurface")

---@class EvolutionSceneInterface
local EvolutionSceneInterface = {}

local MAIN_NATIVE = { id = "main", width = 256, height = 192 }
local SUB_NATIVE = { id = "sub", width = 256, height = 192 }
local ZERO_CROP = { left = 0, right = 0, top = 0, bottom = 0 }

---@param view table<string, unknown> evolution scene status
---@return boolean sub true while the sub screen carries the scene's interaction
local function subActive(view)
  local presentation = (view.evolution --[[@as table<string, unknown>]]).presentation --[[@as table<string, unknown>?]]
  return presentation ~= nil and (presentation.learnMenu ~= nil or presentation.phase == "summary")
end

---@param resources table<string, unknown> borrowed application collaborators
---@param view table<string, unknown> evolution scene status
---@param plan ApplicationPlan
local function render(resources, view, plan)
  local graphics = assert(resources.graphics, "the evolution render borrows its host graphics")
  local evolution = assert(view.evolution, "the evolution status carries its scene view") --[[@as table<string, unknown>]]
  local drawResources = {
    graphics = graphics,
    assets = view.assets,
    windows = resources.windows,
    text = resources.text,
    summaryRenderer = resources.summaryRenderer,
  }
  local only = nil ---@type string?
  if
    (plan --[[@as table<string, unknown>]]).nativeLike == true
  then
    only = subActive(view) and SUB_NATIVE.id or MAIN_NATIVE.id
  end
  for _, pane in ipairs(plan.panes) do
    if only == nil or pane.id == only then
      LogicalSurface.draw(graphics, pane.placement, function()
        if evolution.presentation == nil then
          graphics.setColor(0, 0, 0, 1)
          graphics.rectangle("fill", 0, 0, 256, 192)
        else
          BattleRenderer.drawEvolutionScreen(drawResources, evolution, pane.id --[[@as "main"|"sub"]], view.textPalette)
        end
      end)
    end
  end
end

---@param event table<string, unknown> session-inverted logical input
---@return table<string, unknown>? lower-screen touch, nil for anything else
local function mapInput(event, _, _)
  if event.type == "pointer_down" and event.paneId == SUB_NATIVE.id and event.outside ~= true then
    return { type = "pointer_down", pointerId = event.pointerId, x = event.x, y = event.y }
  end
  return nil
end

---@param panes table[] resolved panes
---@param frames table[] resolved outer frames
---@param nativeLike boolean whether the plan is the single-display entry
---@return ApplicationPlan
local function evolutionPlan(panes, frames, nativeLike)
  return {
    panes = panes,
    frames = frames,
    content = {},
    inputKey = "evolution",
    nativeLike = nativeLike,
    render = render,
    mapInput = mapInput,
  }
end

---@return table<string, fun(context: ApplicationLayout.Context, view: table<string, unknown>): ApplicationPlan>
function EvolutionSceneInterface.defaults()
  -- Unavailable display space resolves to a plan without panes.
  ---@param geometry table<string, unknown> resolved geometry
  ---@param ids string[] pane identities in draw order
  ---@param nativeLike boolean whether the plan is the single-display entry
  ---@return ApplicationPlan
  local function resolved(geometry, ids, nativeLike)
    local placements = geometry.placements --[[@as table<string, LayoutGeometry.Placement>]]
    local panes = {}
    for _, id in ipairs(ids) do
      local placement = nativeLike and placements[SUB_NATIVE.id] or placements[id]
      if placement ~= nil then
        panes[#panes + 1] = { id = id, placement = placement, interactive = id == SUB_NATIVE.id }
      end
    end
    return evolutionPlan(panes, geometry.frames or {}, nativeLike)
  end

  ---@param context ApplicationLayout.Context
  ---@return ApplicationPlan
  local function nativeLike(context, _)
    local geometry = ApplicationLayout.coverOrFrame(context, SUB_NATIVE, { maxOverdraw = ZERO_CROP })
    return resolved(geometry, { MAIN_NATIVE.id, SUB_NATIVE.id }, true)
  end

  local function dualDisplay(context, _)
    local geometry =
      ApplicationLayout.nativeDual(context, MAIN_NATIVE, SUB_NATIVE, { lower = { maxOverdraw = ZERO_CROP } })
    return resolved(geometry, { MAIN_NATIVE.id, SUB_NATIVE.id }, false)
  end

  local function wide(context, view)
    local geometry = ApplicationLayout.sideBySide(context, MAIN_NATIVE, SUB_NATIVE)
    if geometry == nil then
      return context.nativeLikeInterface(context, view)
    end
    return resolved(geometry, { MAIN_NATIVE.id, SUB_NATIVE.id }, false)
  end

  local function tall(context, view)
    local geometry = ApplicationLayout.stacked(context, MAIN_NATIVE, SUB_NATIVE)
    if geometry == nil then
      return context.nativeLikeInterface(context, view)
    end
    return resolved(geometry, { MAIN_NATIVE.id, SUB_NATIVE.id }, false)
  end

  return { dualDisplay = dualDisplay, nativeLike = nativeLike, wide = wide, tall = tall }
end

return EvolutionSceneInterface
