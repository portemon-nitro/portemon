-- Native Generation-IV type matrix installer. Installs the complete
-- directed effectiveness matrix over the native semantic type set into the
-- content builder, so the session chart resolves every pair with exact
-- integer rationals. Values follow the Generation-IV matchups from
-- pret/pokeheartgold: steel resists ghost and dark, poison cannot touch
-- steel, and mystery stays neutral everywhere. Unlisted pairs are exactly
-- neutral; nothing here invents a fallback, the builder still rejects an
-- incomplete matrix at freeze.

---@class NativeTypeChart
local NativeTypeChart = {}

-- Native semantic types in source identity order.
local TYPES = {
  { key = "normal", name = "Normal" },
  { key = "fighting", name = "Fighting" },
  { key = "flying", name = "Flying" },
  { key = "poison", name = "Poison" },
  { key = "ground", name = "Ground" },
  { key = "rock", name = "Rock" },
  { key = "bug", name = "Bug" },
  { key = "ghost", name = "Ghost" },
  { key = "steel", name = "Steel" },
  { key = "mystery", name = "Mystery" },
  { key = "fire", name = "Fire" },
  { key = "water", name = "Water" },
  { key = "grass", name = "Grass" },
  { key = "electric", name = "Electric" },
  { key = "psychic", name = "Psychic" },
  { key = "ice", name = "Ice" },
  { key = "dragon", name = "Dragon" },
  { key = "dark", name = "Dark" },
}

-- Non-neutral directed pairs as { attack, defend, numerator, denominator }.
local RELATIONS = {
  { "normal", "rock", 1, 2 },
  { "normal", "ghost", 0, 1 },
  { "normal", "steel", 1, 2 },
  { "fire", "fire", 1, 2 },
  { "fire", "water", 1, 2 },
  { "fire", "grass", 2, 1 },
  { "fire", "ice", 2, 1 },
  { "fire", "bug", 2, 1 },
  { "fire", "rock", 1, 2 },
  { "fire", "dragon", 1, 2 },
  { "fire", "steel", 2, 1 },
  { "water", "fire", 2, 1 },
  { "water", "water", 1, 2 },
  { "water", "grass", 1, 2 },
  { "water", "ground", 2, 1 },
  { "water", "rock", 2, 1 },
  { "water", "dragon", 1, 2 },
  { "electric", "water", 2, 1 },
  { "electric", "electric", 1, 2 },
  { "electric", "grass", 1, 2 },
  { "electric", "ground", 0, 1 },
  { "electric", "flying", 2, 1 },
  { "electric", "dragon", 1, 2 },
  { "grass", "fire", 1, 2 },
  { "grass", "water", 2, 1 },
  { "grass", "grass", 1, 2 },
  { "grass", "poison", 1, 2 },
  { "grass", "ground", 2, 1 },
  { "grass", "flying", 1, 2 },
  { "grass", "bug", 1, 2 },
  { "grass", "rock", 2, 1 },
  { "grass", "dragon", 1, 2 },
  { "grass", "steel", 1, 2 },
  { "ice", "fire", 1, 2 },
  { "ice", "water", 1, 2 },
  { "ice", "grass", 2, 1 },
  { "ice", "ice", 1, 2 },
  { "ice", "ground", 2, 1 },
  { "ice", "flying", 2, 1 },
  { "ice", "dragon", 2, 1 },
  { "ice", "steel", 1, 2 },
  { "fighting", "normal", 2, 1 },
  { "fighting", "ice", 2, 1 },
  { "fighting", "poison", 1, 2 },
  { "fighting", "flying", 1, 2 },
  { "fighting", "psychic", 1, 2 },
  { "fighting", "bug", 1, 2 },
  { "fighting", "rock", 2, 1 },
  { "fighting", "ghost", 0, 1 },
  { "fighting", "dark", 2, 1 },
  { "fighting", "steel", 2, 1 },
  { "poison", "grass", 2, 1 },
  { "poison", "poison", 1, 2 },
  { "poison", "ground", 1, 2 },
  { "poison", "rock", 1, 2 },
  { "poison", "ghost", 1, 2 },
  { "poison", "steel", 0, 1 },
  { "ground", "fire", 2, 1 },
  { "ground", "electric", 2, 1 },
  { "ground", "grass", 1, 2 },
  { "ground", "poison", 2, 1 },
  { "ground", "flying", 0, 1 },
  { "ground", "bug", 1, 2 },
  { "ground", "rock", 2, 1 },
  { "ground", "steel", 2, 1 },
  { "flying", "electric", 1, 2 },
  { "flying", "grass", 2, 1 },
  { "flying", "fighting", 2, 1 },
  { "flying", "bug", 2, 1 },
  { "flying", "rock", 1, 2 },
  { "flying", "steel", 1, 2 },
  { "psychic", "fighting", 2, 1 },
  { "psychic", "poison", 2, 1 },
  { "psychic", "psychic", 1, 2 },
  { "psychic", "dark", 0, 1 },
  { "psychic", "steel", 1, 2 },
  { "bug", "fire", 1, 2 },
  { "bug", "grass", 2, 1 },
  { "bug", "fighting", 1, 2 },
  { "bug", "poison", 1, 2 },
  { "bug", "flying", 1, 2 },
  { "bug", "psychic", 2, 1 },
  { "bug", "ghost", 1, 2 },
  { "bug", "dark", 2, 1 },
  { "bug", "steel", 1, 2 },
  { "rock", "fire", 2, 1 },
  { "rock", "ice", 2, 1 },
  { "rock", "fighting", 1, 2 },
  { "rock", "ground", 1, 2 },
  { "rock", "flying", 2, 1 },
  { "rock", "bug", 2, 1 },
  { "rock", "steel", 1, 2 },
  { "ghost", "normal", 0, 1 },
  { "ghost", "psychic", 2, 1 },
  { "ghost", "ghost", 2, 1 },
  { "ghost", "dark", 1, 2 },
  { "ghost", "steel", 1, 2 },
  { "dragon", "dragon", 2, 1 },
  { "dragon", "steel", 1, 2 },
  { "dark", "fighting", 1, 2 },
  { "dark", "psychic", 2, 1 },
  { "dark", "ghost", 2, 1 },
  { "dark", "dark", 1, 2 },
  { "dark", "steel", 1, 2 },
  { "steel", "fire", 1, 2 },
  { "steel", "water", 1, 2 },
  { "steel", "electric", 1, 2 },
  { "steel", "ice", 2, 1 },
  { "steel", "rock", 2, 1 },
  { "steel", "steel", 1, 2 },
}

--- Installs every native type with its complete directed relations into
--- the content builder. Carries no lookup of its own; the composed
--- session chart stays the single resolution path.
---@param builder table<string, unknown> live ordered content builder receiving the matrix
---@param owner string contributing owner naming the definitions
function NativeTypeChart.install(builder, owner)
  assert(type(builder) == "table", "the native chart installs through its builder")
  assert(type(owner) == "string" and owner ~= "", "the native chart names its owner")
  local define = builder --[[@as table<string, unknown>]].define
  assert(type(define) == "function", "the native chart installs through content definitions")
  local overrides = {} ---@type table<string, table<integer, unknown>>
  for _, entry in ipairs(RELATIONS) do
    local pair = entry --[[@as table<integer, unknown>]]
    overrides[
      pair[1] --[[@as string]] .. "\0" .. pair[2] --[[@as string]]
    ] = pair
  end
  for _, attack in ipairs(TYPES) do
    local attacking = attack --[[@as table<string, string>]]
    local relations = {} ---@type table<integer, table<string, unknown>>
    for _, defend in ipairs(TYPES) do
      local defending = defend --[[@as table<string, string>]]
      local hit = overrides[attacking.key .. "\0" .. defending.key]
      if hit ~= nil then
        local pair = hit --[[@as table<integer, unknown>]]
        relations[#relations + 1] = {
          attack = attacking.key,
          defend = defending.key,
          numerator = pair[3],
          denominator = pair[4],
        }
      else
        relations[#relations + 1] = { attack = attacking.key, defend = defending.key, numerator = 1, denominator = 1 }
      end
    end
    local defineFn = define --[[@as fun(self: table<string, unknown>, kind: string, key: string, record: table<string, unknown>, owner: string)]]
    defineFn(
      builder,
      "types",
      attacking.key,
      { key = attacking.key, name = attacking.name, relations = relations },
      owner
    )
  end
end

return NativeTypeChart
