-- Adapts the Ho-Oh scene renderer to the asset-needs registry: a job prepares
-- the live game version and time-of-day variant one unit per step, and
-- releases the renderer's assets when its need goes away.

local HoOhAssetPreparer = {}

---@class HoOhAssetPreparer.Scene
---@field currentVariant fun(self: HoOhAssetPreparer.Scene): integer
---@field status fun(self: HoOhAssetPreparer.Scene): table<string, unknown>

---@class HoOhAssetPreparer.Runtime
---@field versionId string
---@field hoOhAppearanceScene HoOhAssetPreparer.Scene?

---@class HoOhAssetPreparer.Renderer
---@field prepareStep fun(self: HoOhAssetPreparer.Renderer, versionId: string, variant: integer): boolean
---@field cancel fun(self: HoOhAssetPreparer.Renderer)

---@param runtime HoOhAssetPreparer.Runtime
---@param renderer HoOhAssetPreparer.Renderer
---@return AssetNeedsRegistry.Preparer
function HoOhAssetPreparer.new(runtime, renderer)
  local preparer = {}

  ---@param id string
  ---@return AssetNeedsRegistry.Job?
  function preparer.start(id)
    local scene = runtime.hoOhAppearanceScene
    if id ~= "ho_oh_appearance" or scene == nil then
      return nil
    end
    local job = {}
    function job.step()
      -- The scene draws from what the renderer holds: preparation never
      -- replaces it mid-run.
      if scene:status().active == true then
        return true
      end
      return renderer:prepareStep(runtime.versionId, scene:currentVariant())
    end
    function job.cancel()
      renderer:cancel()
    end
    return job
  end

  return preparer
end

return HoOhAssetPreparer
