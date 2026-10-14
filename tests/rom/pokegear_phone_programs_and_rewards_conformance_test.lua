-- ROM conformance: every native caller selects its source program. The
-- compiled phonebook catalog carries all seventy-five native contacts with
-- distinct semantic keys fully covered by the contact order, and each
-- selector early return from the source-ordered branch tables resolves to
-- its own program identity with its own draw order. Expectations pin the
-- native contact count and the branch order independently of the dispatch
-- implementation under test. Member bytes are never committed to the
-- repository.

local Assert = require("tests.support.Assert")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}

-- Seventy-five native callers: the supplied HeartGold phonebook keeps its
-- whole-file identity of one count word plus seventy-five fixed records.
function T.native_script_dispatch_uses_exact_supported_family_routes()
  local PhoneCall = require("game.hgss.src.pokegear.PhoneCall")
  local PokegearState = require("libs.hgss.src.save.PokegearState")
  local contacts = {
    { key = "hg.trainer.200.map.0.contact.0", id = 7, family = "bike", map = 9, messageBank = 664 },
    { key = "hg.trainer.201.map.0.contact.1", id = 8, family = "bill", map = 9, messageBank = 675 },
  }
  local catalog = { contacts = contacts, locations = {} }
  local state = PokegearState.new({ seed = 1 }, { catalog = catalog })
  for _, contact in ipairs(contacts) do
    state:registerContact(contact.key)
  end
  local selected = {}
  local call = PhoneCall.new({
    state = state,
    catalog = catalog,
    messages = {
      greeting = "fixture.greeting",
      resolveLine = function(_, key, scriptId)
        selected[#selected + 1] = { key = key, scriptId = scriptId }
        return { tokens = { { kind = "glyph", text = "x" } } }
      end,
    },
    world = {
      signal = "strong",
      reception = "good",
      canCall = function()
        return true
      end,
      nativeSelectorFacts = function()
        return { localMap = true }
      end,
    },
  })
  local cases = {
    { contact = contacts[1], direction = "outgoing", expected = 84 },
    { contact = contacts[2], direction = "outgoing", expected = 92 },
    { contact = contacts[2], direction = "incoming", expected = 93 },
  }
  for index, case in ipairs(cases) do
    local handle = call:begin({
      id = "native-route-" .. index,
      contact = case.contact.key,
      direction = case.direction,
      kind = "ordinary",
    })
    call:step(handle, {})
    call:step(handle, {})
    local view = call:view(handle)
    Assert.equal(view.stage, "message", "a source-backed static route publishes its dialogue page")
    Assert.equal(selected[index].scriptId, case.expected, "the native selector supplies the exact phone script ID")
    call:cancel(handle, "fixture complete")
  end
end

local suite = RomSuite.fromFacts(T)
suite.metadata.capabilities = { "rom_dump" }
return suite
