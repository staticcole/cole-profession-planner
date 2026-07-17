SPP = SPP or {}
SPP.Data = SPP.Data or { professions = {}, outputs = {}, conversions = {}, conversionOutputs = {} }

SPP.R = {
  SPELL = 1, NAME = 2, EXPANSION = 3, PHASE = 4, PHASE_EXACT = 5,
  OUTPUT = 6, OUTPUT_QTY = 7, RECIPE_ITEM = 8, LEARN = 9,
  ORANGE = 10, YELLOW = 11, GREEN = 12, GRAY = 13,
  SOURCE = 14, REAGENTS = 15, PROFESSION = 16
}

SPP.S = {
  TYPE = 1, NPC_ID = 2, NAME = 3, NPC_NAME = 4, LOCATION = 5,
  MAP_ID = 6, X = 7, Y = 8, MIN_LEVEL = 9, MAX_LEVEL = 10,
  RANK = 11, EXPANSION = 12, PHASE = 13, EXTRA = 14, FACTION = 15
}

local SOURCE_TYPES = {
  [0] = "Learned by default", [1] = "Trainer", [2] = "Vendor", [3] = "Mob drop",
  [4] = "Quest", [5] = "Seasonal", [6] = "Reputation", [7] = "World drop",
  [8] = "Special", [9] = "Crafted", [10] = "Unknown"
}
local NPC_RANKS = { [0] = "Normal", [1] = "Elite", [2] = "Rare Elite", [3] = "Boss", [4] = "Rare" }
local REPUTATION_STANDINGS = { [1] = "Friendly", [2] = "Honored", [3] = "Revered", [4] = "Exalted" }

local function getReputationStanding(value)
  if value == nil or value == "" then return "Required standing" end
  local numericValue = tonumber(value)
  if numericValue and REPUTATION_STANDINGS[numericValue] then
    return REPUTATION_STANDINGS[numericValue]
  end
  return tostring(value):gsub("^%l", string.upper)
end

function SPP.Data:RegisterProfession(profession, recipes)
  self.professions[profession] = recipes
  for _, recipe in ipairs(recipes) do
    recipe[SPP.R.PROFESSION] = profession
  end
end

function SPP.Data:Finalize()
  wipe(self.outputs)
  for _, recipes in pairs(self.professions) do
    for _, recipe in ipairs(recipes) do
      local output = recipe[SPP.R.OUTPUT]
      if output then
        self.outputs[output] = self.outputs[output] or {}
        table.insert(self.outputs[output], recipe)
      end
    end
  end

  self.conversions = SPP_CONVERSIONS or {}
  wipe(self.conversionOutputs)
  for _, conversion in ipairs(self.conversions) do
    local inputs, outputs = conversion[5], conversion[6]
    for index = 1, #outputs, 2 do
      local itemId = outputs[index]
      self.conversionOutputs[itemId] = self.conversionOutputs[itemId] or {}
      table.insert(self.conversionOutputs[itemId], { conversion = conversion, reverse = false })
    end
    if conversion[4] == 1 then
      for index = 1, #inputs, 2 do
        local itemId = inputs[index]
        self.conversionOutputs[itemId] = self.conversionOutputs[itemId] or {}
        table.insert(self.conversionOutputs[itemId], { conversion = conversion, reverse = true })
      end
    end
  end
end

function SPP.Data:IsAvailable(expansion, phase, maxExpansion, maxPhase)
  return expansion < maxExpansion or (expansion == maxExpansion and phase <= maxPhase)
end

function SPP.Data:GetProfessionNames()
  local names = {}
  for profession in pairs(self.professions) do table.insert(names, profession) end
  table.sort(names)
  return names
end

function SPP.Data:GetItemName(itemId)
  local name = GetItemInfo(itemId)
  if name then return name end
  local item = SPP_ITEM_DATA and SPP_ITEM_DATA[itemId]
  return item and item[1] or ("Item " .. tostring(itemId))
end

function SPP.Data:GetAvailableSources(recipe, maxExpansion, maxPhase)
  local result = {}
  local faction = UnitFactionGroup and UnitFactionGroup("player") or nil
  for _, sourceId in ipairs(recipe[SPP.R.SOURCE] or {}) do
    local source = SPP_SOURCE_DATA and SPP_SOURCE_DATA[sourceId]
    local factionCode = source and source[SPP.S.FACTION]
    local factionMatches = not factionCode or factionCode == 0
      or (factionCode == 1 and faction == "Alliance") or (factionCode == 2 and faction == "Horde")
    if source and factionMatches and self:IsAvailable(source[SPP.S.EXPANSION], source[SPP.S.PHASE], maxExpansion, maxPhase) then
      table.insert(result, source)
    end
  end
  return result
end

function SPP.Data:GetSourceText(source, includeDetails)
  if not source then return "Unknown source" end
  local S = SPP.S
  local sourceType = source[S.TYPE]
  local typeName = SOURCE_TYPES[sourceType] or "Unknown"
  local name = source[S.NPC_NAME] or source[S.NAME]
  local location = source[S.LOCATION]
  local text
  if sourceType == 6 then
    local standing = getReputationStanding(source[S.EXTRA])
    text = string.format("Reputation: %s (%s)", source[S.NAME] or "Unknown faction", standing)
    if source[S.NPC_NAME] then text = text .. "\nVendor: " .. source[S.NPC_NAME] end
  elseif sourceType == 7 then
    text = "World drop" .. (source[S.NAME] and (": " .. source[S.NAME]) or "")
  elseif sourceType == 8 then
    text = source[S.NAME] or "Special acquisition"
  else
    text = typeName .. (name and (": " .. name) or "")
  end
  if location then text = text .. "\nLocation: " .. location end
  if includeDetails and sourceType == 3 then
    local minLevel, maxLevel = source[S.MIN_LEVEL], source[S.MAX_LEVEL]
    if minLevel then
      text = text .. "\nLevel: " .. minLevel .. (maxLevel and maxLevel ~= minLevel and ("-" .. maxLevel) or "")
    end
    text = text .. "\nRank: " .. (NPC_RANKS[source[S.RANK] or 0] or "Unknown")
  end
  return text
end

function SPP.Data:GetSourceKind(source)
  if not source then return "Unknown" end
  local sourceType = source[SPP.S.TYPE]
  local sourceName = source[SPP.S.NAME]
  if sourceType == 8 and sourceName and sourceName:lower():find("learned by default", 1, true) then
    return "Learned by default"
  end
  if sourceType == 6 and source[SPP.S.NPC_NAME] then return "Reputation vendor" end
  return SOURCE_TYPES[sourceType] or "Unknown"
end

function SPP.Data:IsCommonRecipe(recipe, maxExpansion, maxPhase)
  for _, source in ipairs(self:GetAvailableSources(recipe, maxExpansion, maxPhase)) do
    local sourceType = source[SPP.S.TYPE]
    local sourceName = source[SPP.S.NAME]
    local learnedByDefault = sourceType == 8 and sourceName and sourceName:lower():find("learned by default", 1, true)
    if sourceType == 0 or sourceType == 1 or sourceType == 2 or learnedByDefault then return true end
  end
  return false
end

function SPP.Data:GetSourceSummary(recipe, maxExpansion, maxPhase)
  local sources = self:GetAvailableSources(recipe, maxExpansion, maxPhase)
  if #sources == 0 then return "No source available in this phase" end
  local firstLine = self:GetSourceText(sources[1], false):match("^[^\n]+")
  local kind = self:GetSourceKind(sources[1])
  local detail = firstLine:gsub("^" .. kind:gsub("([^%w])", "%%%1") .. ":?%s*", "")
  return "[" .. kind .. "] " .. detail .. (#sources > 1 and ("  +" .. (#sources - 1)) or "")
end

function SPP.Data:GetMappableSource(recipe, maxExpansion, maxPhase)
  return self:GetMappableSources(recipe, maxExpansion, maxPhase)[1]
end

function SPP.Data:GetMappableSources(recipe, maxExpansion, maxPhase)
  local result = {}
  for _, source in ipairs(self:GetAvailableSources(recipe, maxExpansion, maxPhase)) do
    if source[SPP.S.MAP_ID] then table.insert(result, source) end
  end
  table.sort(result, function(a, b)
    local aLocation = a[SPP.S.LOCATION] or ""
    local bLocation = b[SPP.S.LOCATION] or ""
    if aLocation ~= bLocation then return aLocation < bLocation end
    return (a[SPP.S.NPC_NAME] or a[SPP.S.NAME] or "") < (b[SPP.S.NPC_NAME] or b[SPP.S.NAME] or "")
  end)
  return result
end

function SPP.Data:GetVendorPrice(itemId)
  local item = SPP_ITEM_DATA and SPP_ITEM_DATA[itemId]
  return item and item[2] or nil
end

function SPP.Data:IsVendorItem(itemId)
  local price = self:GetVendorPrice(itemId)
  return type(price) == "number" and price > 0
end

function SPP.Data:GetColor(recipe, skill)
  local R = SPP.R
  if skill < recipe[R.LEARN] then return "locked" end
  local yellow, green, gray = recipe[R.YELLOW], recipe[R.GREEN], recipe[R.GRAY]
  if yellow > 0 and skill < yellow then return "orange" end
  if green > 0 and skill < green then return "yellow" end
  if gray > 0 and skill < gray then return "green" end
  return "gray"
end

function SPP.Data:GetSkillupChance(recipe, skill)
  local R = SPP.R
  if skill < recipe[R.LEARN] then return 0 end
  local orange, yellow, green, gray = recipe[R.ORANGE], recipe[R.YELLOW], recipe[R.GREEN], recipe[R.GRAY]
  if orange > 0 and yellow > 0 and skill < yellow then return 1 end
  if yellow > 0 and green > yellow and skill < green then
    return 1 - 0.5 * ((skill - yellow) / (green - yellow))
  end
  if green > 0 and gray > green and skill < gray then
    return 0.5 * (1 - ((skill - green) / (gray - green)))
  end
  return 0
end
