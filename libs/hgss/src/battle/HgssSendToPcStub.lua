-- Explicit full-party capture handoff. There is no PC backend: when a
-- caught mon cannot join a full party, this stub is the only authorized
-- behavior. It stores nothing, writes no overflow bucket, consumes no
-- additional resources, and never claims the mon reached a box. It returns
-- retained=false with destination "pc" and reason "pc_unimplemented" so
-- the battle host and the future interface report the limitation honestly
-- instead of a fake storage success. The ball stays consumed and the
-- capture stays registered through the normal battle result path; only
-- retention is refused. A future PC implementation replaces this module
-- by storing the mon and returning retained=true; until then no caller
-- may synthesize storage elsewhere to hide this no-op. Pure function: no
-- live state is read or mutated.

---@class HgssSendToPcStub
local HgssSendToPcStub = {}

-- Reports the honest unplaced handoff for a caught mon that cannot join
-- the party. The mon record and party context are accepted so callers
-- pass the real capture through, but neither is retained.
---@param mon table<string, unknown>
---@param context { partyCount: integer?, captureId: integer? }?
---@return { retained: boolean, destination: string, reason: string, captureId: integer? }
function HgssSendToPcStub.send(mon, context)
  assert(type(mon) == "table", "the party-overflow handoff requires the caught mon")
  local seen = context or {}
  assert(type(seen) == "table", "the party-overflow handoff context must be a record")
  return {
    retained = false,
    destination = "pc",
    reason = "pc_unimplemented",
    captureId = seen.captureId,
  }
end

return HgssSendToPcStub
