-- Start Menu unlock facts for acceptance setups. The source draws a normal
-- action only while its unlock gate is satisfied
-- (FieldSystem_ShouldDrawStartMenuIcon), so a scenario that exercises the menu
-- first grants the source facts it presents.

local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")

local StartMenuFacts = {}

-- The three right-column actions the Player House opening grants (trainer
-- card, save, options). Granting the whole column, not just the one entry a
-- scenario uses, keeps the generated directional graph able to cross it: a
-- hole in the middle of the column leaves the entries below it unreachable.
StartMenuFacts.RIGHT_COLUMN_FACTS = {
  "FLAG_GOT_TRAINER_CARD",
  "FLAG_GOT_SAVE_BUTTON",
  "FLAG_GOT_OPTIONS_BUTTON",
}

---@param game table an AcceptanceHarness game
---@param facts (string|integer)[] source flag names or generated flag ids
function StartMenuFacts.grant(game, facts)
  for _, fact in ipairs(facts) do
    local flag = fact
    if type(fact) == "string" then
      flag = assert(FieldScriptSymbols.flagsByName[fact], "unknown world flag " .. fact)
    end
    game:setWorldState({ flag = flag })
  end
end

---@param game table an AcceptanceHarness game
function StartMenuFacts.grantRightColumn(game)
  StartMenuFacts.grant(game, StartMenuFacts.RIGHT_COLUMN_FACTS)
end

return StartMenuFacts
