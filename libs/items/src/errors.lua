-- Package error codes for the item domain. Production code raises these
-- through Errors.raise; tests match on the code. The generated asset schema
-- owns record shape, the catalog owns identity resolution.

local Errors = require("libs.errors.src.Errors")

---@class ItemErrors
local ItemErrors = {}

ItemErrors.RECORD_INVALID = "ITEM_RECORD_INVALID"

-- Raised when a catalog record reaches domain policy without the generated
-- party-use contract the schema requires. The code names the violated
-- generated contract, matching the validator in ItemAssetSchema.
ItemErrors.CATALOG_INVALID = "ITEM_CATALOG_INVALID"

---@param code string
---@param message string
---@param context table<string, Errors.Value>?
function ItemErrors.raise(code, message, context)
  Errors.raise(code, message, context or {})
end

return ItemErrors
