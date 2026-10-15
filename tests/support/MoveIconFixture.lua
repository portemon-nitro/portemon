-- A synthetic shared move-icons manifest in generated shape: one small
-- static image record per semantic type and damage-category key.

local MoveIconCache = require("libs.assets.src.MoveIconCache")

local MoveIconFixture = {}

---@return table<string, unknown>
function MoveIconFixture.manifest()
  local function records(keys, prefix)
    local set = {}
    for _, key in ipairs(keys) do
      set[key] = {
        image = MoveIconCache.assetDir() .. "/" .. prefix .. "-" .. key .. ".png",
        width = 32,
        height = 16,
      }
    end
    return set
  end
  return {
    schema = MoveIconCache.SCHEMA,
    types = records(MoveIconCache.TYPE_KEYS, "type"),
    categories = records(MoveIconCache.CATEGORY_KEYS, "category"),
  }
end

return MoveIconFixture
