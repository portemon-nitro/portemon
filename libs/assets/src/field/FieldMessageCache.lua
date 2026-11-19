-- Readiness and paths for the derived field-message cache. Message banks are
-- one of the independently rebuildable derived classes (map geometry, actor
-- visuals, messages/font): changing the message compiler must not disturb the
-- raw ROM dump or any compiled map. Each source bank is one readable Lua file,
-- and the family index selects the complete set of banks a build provides. A
-- bank's own job receipt is its completion proof, so the payload carries no
-- proof of its own; an explicit validator still checks the bank shape.
-- Paths are cache-relative; all IO goes through a CacheFs.

local FieldMessageCache = {}

---@class FieldMessageCache.Index
---@field schema string
---@field version string
---@field bankIds integer[]

local Validate = require("libs.assets.src.Validate")
local Contract = require("libs.assets.src.DerivedAssetContract")

FieldMessageCache.FORMAT = Contract.messages.cacheFormat
FieldMessageCache.SCHEMA = Contract.messages.schema
FieldMessageCache.INDEX_SCHEMA = Contract.messages.indexSchema

local DATA_DIR = "data/generated/field/messages"

function FieldMessageCache.dir()
  return DATA_DIR
end
function FieldMessageCache.indexPath()
  return DATA_DIR .. "/index.lua"
end

function FieldMessageCache.bankPath(bankId)
  assert(Validate.isNonNegativeInteger(bankId), "bankId must be a non-negative integer")
  return string.format("%s/banks/%04d.lua", DATA_DIR, bankId)
end

function FieldMessageCache.marker(romSha1, depHash)
  return string.format("%s:%s:%s", FieldMessageCache.FORMAT, romSha1, depHash)
end

-- True when the bank file loads with the current schema and matching
-- identity. The bank's job receipt is what proves it is current; this checks
-- the payload a consumer is about to read.
---@param cacheFs CacheFs
---@param bankId integer
---@return boolean
function FieldMessageCache.isBankReady(cacheFs, bankId)
  local bank = cacheFs:loadLua(FieldMessageCache.bankPath(bankId)) ---@type table?
  if type(bank) ~= "table" or bank.schema ~= FieldMessageCache.SCHEMA or bank.bankId ~= bankId then
    return false
  end
  if not Validate.isNonNegativeInteger(bank.messageCount) or type(bank.messages) ~= "table" then
    return false
  end
  return true
end

-- True when the family index loads with the expected schema, selects a
-- non-empty bank array, and every selected bank loads with the expected
-- schema and matching identity.
---@param cacheFs CacheFs
---@return boolean
function FieldMessageCache.isReady(cacheFs)
  local index = cacheFs:loadLua(FieldMessageCache.indexPath()) ---@type table?
  if type(index) ~= "table" or index.schema ~= FieldMessageCache.INDEX_SCHEMA then
    return false
  end
  if not Validate.isArray(index.bankIds) or #index.bankIds == 0 then
    return false
  end
  for _, bankId in ipairs(index.bankIds) do
    if not Validate.isNonNegativeInteger(bankId) then
      return false
    end
    if not FieldMessageCache.isBankReady(cacheFs, bankId) then
      return false
    end
  end
  return true
end

return FieldMessageCache
