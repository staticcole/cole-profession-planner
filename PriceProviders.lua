SPP.Price = SPP.Price or { cache = {}, craftCache = {}, choiceCache = {} }
local CALLER = "ColeProfessionPlanner"
local BULK_CRAFT_SAVINGS_THRESHOLD = 0.15
local BULK_LEATHER_UPGRADES = {
  [20648] = true, -- Light Leather -> Medium Leather
  [20649] = true, -- Medium Leather -> Heavy Leather
  [20650] = true, -- Heavy Leather -> Thick Leather
  [22331] = true, -- Thick Leather -> Rugged Leather
  [32455] = true, -- Knothide Leather -> Heavy Knothide Leather
  [50936] = true  -- Borean Leather -> Heavy Borean Leather
}

local function validPrice(value)
  return type(value) == "number" and value > 0 and value < 100000000000
end

local function reliableBulkProvider(provider)
  return provider == "Auctionator (quantity)" or provider == "Manual"
end

function SPP.Price:ClearCache()
  wipe(self.cache)
  wipe(self.craftCache)
  wipe(self.choiceCache)
end

function SPP.Price:GetAuctionPrice(itemId)
  local cached = self.cache[itemId]
  if cached ~= nil then return cached or nil, self.cache[itemId .. "provider"] end

  local price, provider
  local volumePrice = SPP.Auctionator and SPP.Auctionator.GetVolumeUnitPrice and SPP.Auctionator:GetVolumeUnitPrice(itemId)
  if validPrice(volumePrice) then price, provider = volumePrice, "Auctionator (quantity)" end
  if Auctionator and Auctionator.API and Auctionator.API.v1 and Auctionator.API.v1.GetAuctionPriceByItemID then
    local ok, value = pcall(Auctionator.API.v1.GetAuctionPriceByItemID, "ColeProfessionPlanner", itemId)
    if not price and ok and validPrice(value) then price, provider = value, "Auctionator" end
  end
  if not price and Atr_GetAuctionBuyout then
    local ok, value = pcall(Atr_GetAuctionBuyout, itemId)
    if ok and validPrice(value) then price, provider = value, "Auctionator (legacy)" end
  end
  if not price and GetAuctionBuyout then
    local ok, value = pcall(GetAuctionBuyout, itemId)
    if ok and validPrice(value) then price, provider = value, "Auction database" end
  end
  if not price and TSM_API and TSM_API.GetCustomPriceValue then
    local ok, value = pcall(TSM_API.GetCustomPriceValue, "dbmarket", "i:" .. itemId)
    if ok and validPrice(value) then price, provider = value, "TSM" end
  end
  if not price and TSMAPI and TSMAPI.GetCustomPriceValue then
    local ok, value = pcall(TSMAPI.GetCustomPriceValue, TSMAPI, "DBMarket", "i:" .. itemId)
    if ok and validPrice(value) then price, provider = value, "TSM (legacy)" end
  end
  if not price and AucAdvanced and AucAdvanced.API and AucAdvanced.API.GetMarketValue then
    local ok, value = pcall(AucAdvanced.API.GetMarketValue, "item:" .. itemId)
    if ok and validPrice(value) then price, provider = value, "Auctioneer" end
  end
  if not price and Auctionator and Auctionator.Database and Auctionator.Database.GetPrice then
    local ok, value = pcall(Auctionator.Database.GetPrice, itemId)
    if ok and validPrice(value) then price, provider = value, "Auctionator" end
  end

  self.cache[itemId] = price or false
  self.cache[itemId .. "provider"] = provider
  return price, provider
end

function SPP.Price:GetAuctionAge(itemId)
  local api = Auctionator and Auctionator.API and Auctionator.API.v1
  if not api or not api.GetAuctionAgeByItemID then return nil end
  local ok, age = pcall(api.GetAuctionAgeByItemID, CALLER, itemId)
  return ok and type(age) == "number" and age or nil
end

function SPP.Price:GetPlanAuctionAge(plan)
  local usesAuction, oldest = false, nil
  for itemId in pairs(plan and plan.shopping or {}) do
    local _, provider = self:GetUnitPrice(itemId)
    if provider and provider:find("Auctionator", 1, true) then
      usesAuction = true
      local age = provider == "Auctionator (quantity)" and 0 or self:GetAuctionAge(itemId)
      if age and (not oldest or age > oldest) then oldest = age end
    end
  end
  return usesAuction, oldest
end

function SPP.Price:GetUnitPrice(itemId)
  local vendor = SPP.Data:GetVendorPrice(itemId)
  if validPrice(vendor) then return vendor, "Vendor" end

  local best, provider
  local manual = ColeProfessionPlannerDB and ColeProfessionPlannerDB.manualPrices and ColeProfessionPlannerDB.manualPrices[itemId]
  if validPrice(manual) then best, provider = manual, "Manual" end

  local auction, auctionProvider = self:GetAuctionPrice(itemId)
  if validPrice(auction) and (not best or auction < best) then best, provider = auction, auctionProvider end

  return best, provider
end

function SPP.Price:GetRecipeCost(recipe, options, visiting)
  local R = SPP.R
  local reagents = recipe[R.REAGENTS]
  local total = 0
  visiting = visiting or {}
  for index = 1, #reagents, 2 do
    local itemId, quantity = reagents[index], reagents[index + 1]
    local price = self:GetEffectivePrice(itemId, options, visiting)
    if not price then return nil, itemId end
    total = total + price * quantity
  end
  return total
end

local function professionOptionKey(options)
  if options.professionKey then return options.professionKey end
  if not options.availableProfessions then return "all" end
  local names = {}
  for profession, available in pairs(options.availableProfessions) do
    if available then table.insert(names, profession) end
  end
  table.sort(names)
  return table.concat(names, ",")
end

local function priceChoiceKey(itemId, options)
  return itemId .. ":" .. tostring(options.maxExpansion or 3) .. ":" .. tostring(options.maxPhase or 9)
    .. ":" .. professionOptionKey(options)
end

function SPP.Price:CanCraftRecipe(recipe, options)
  if not options or not options.availableProfessions then return true end
  return options.availableProfessions[recipe[SPP.R.PROFESSION]] == true
end

function SPP.Price:GetEffectivePrice(itemId, options, visiting)
  options = options or {}
  visiting = visiting or {}
  local key = priceChoiceKey(itemId, options)
  if self.craftCache[key] ~= nil then return self.craftCache[key] or nil end
  if visiting[itemId] then return self:GetUnitPrice(itemId) end
  visiting[itemId] = true

  local best, buyProvider = self:GetUnitPrice(itemId)
  local choice = best and { type = "buy" } or nil
  for _, recipe in ipairs(SPP.Data.outputs[itemId] or {}) do
    if self:CanCraftRecipe(recipe, options)
      and SPP.Data:IsAvailable(recipe[SPP.R.EXPANSION], recipe[SPP.R.PHASE], options.maxExpansion or 3, options.maxPhase or 9) then
      local cost = self:GetRecipeCost(recipe, options, visiting)
      local isBulkLeatherUpgrade = BULK_LEATHER_UPGRADES[recipe[SPP.R.SPELL]]
      local reliableBulkPrices = true
      if isBulkLeatherUpgrade then
        reliableBulkPrices = best and reliableBulkProvider(buyProvider)
        local reagents = recipe[SPP.R.REAGENTS]
        for index = 1, #reagents, 2 do
          local _, provider = self:GetUnitPrice(reagents[index])
          if not reliableBulkProvider(provider) then reliableBulkPrices = false break end
        end
      end
      if cost and reliableBulkPrices then
        cost = cost / (recipe[SPP.R.OUTPUT_QTY] or 1)
        local requiredSavings = isBulkLeatherUpgrade and BULK_CRAFT_SAVINGS_THRESHOLD or 0
        if (not best and not isBulkLeatherUpgrade) or (best and cost <= best * (1 - requiredSavings)) then
          best, choice = cost, { type = "recipe", recipe = recipe }
        end
      end
    end
  end

  for _, entry in ipairs(SPP.Data.conversionOutputs[itemId] or {}) do
    local conversion = entry.conversion
    if SPP.Data:IsAvailable(conversion[2], conversion[3], options.maxExpansion or 3, options.maxPhase or 9) then
      local inputs = entry.reverse and conversion[6] or conversion[5]
      local outputs = entry.reverse and conversion[5] or conversion[6]
      local inputCost, outputQuantity = 0, nil
      for index = 1, #inputs, 2 do
        local price = self:GetEffectivePrice(inputs[index], options, visiting)
        if not price then inputCost = nil break end
        inputCost = inputCost + price * inputs[index + 1]
      end
      for index = 1, #outputs, 2 do
        if outputs[index] == itemId then outputQuantity = outputs[index + 1] break end
      end
      if inputCost and outputQuantity then
        local unitCost = inputCost / outputQuantity
        if not best or unitCost < best then best, choice = unitCost, { type = "conversion", entry = entry } end
      end
    end
  end

  visiting[itemId] = nil
  self.craftCache[key] = best or false
  self.choiceCache[key] = choice or false
  return best
end

function SPP.Price:AddShoppingMaterials(itemId, quantity, options, shopping, visiting)
  options = options or {}
  shopping = shopping or {}
  visiting = visiting or {}
  local key = priceChoiceKey(itemId, options)
  self:GetEffectivePrice(itemId, options, {})
  local choice = self.choiceCache[key]
  if visiting[itemId] or not choice or choice.type == "buy" then
    shopping[itemId] = (shopping[itemId] or 0) + quantity
    return shopping
  end

  visiting[itemId] = true
  if choice.type == "recipe" then
    local recipe = choice.recipe
    local outputQuantity = recipe[SPP.R.OUTPUT_QTY] or 1
    local reagents = recipe[SPP.R.REAGENTS]
    for index = 1, #reagents, 2 do
      self:AddShoppingMaterials(reagents[index], quantity * reagents[index + 1] / outputQuantity, options, shopping, visiting)
    end
  elseif choice.type == "conversion" then
    local entry = choice.entry
    local conversion = entry.conversion
    local inputs = entry.reverse and conversion[6] or conversion[5]
    local outputs = entry.reverse and conversion[5] or conversion[6]
    local outputQuantity = 1
    for index = 1, #outputs, 2 do
      if outputs[index] == itemId then outputQuantity = outputs[index + 1] break end
    end
    for index = 1, #inputs, 2 do
      self:AddShoppingMaterials(inputs[index], quantity * inputs[index + 1] / outputQuantity, options, shopping, visiting)
    end
  end
  visiting[itemId] = nil
  return shopping
end

function SPP.Price:GetProviderLabel()
  local providers = {}
  if Auctionator then table.insert(providers, "Auctionator") end
  if Atr_GetAuctionBuyout and not Auctionator then table.insert(providers, "Auctionator") end
  if TSM_API or TSMAPI then table.insert(providers, "TSM") end
  if AucAdvanced then table.insert(providers, "Auctioneer") end
  if #providers == 0 then return "Manual / vendor prices" end
  return table.concat(providers, ", ")
end

function SPP.Price:GetProviderDiagnostics(itemId)
  local result = {}
  local function addResult(name, ok, value, detail)
    if ok and validPrice(value) then
      table.insert(result, name .. ": " .. SPP:FormatMoney(value))
    elseif ok then
      table.insert(result, name .. ": no price data")
    else
      table.insert(result, name .. ": error - " .. tostring(value or detail))
    end
  end

  if Auctionator and Auctionator.API and Auctionator.API.v1 and Auctionator.API.v1.GetAuctionPriceByItemID then
    local ok, value = pcall(Auctionator.API.v1.GetAuctionPriceByItemID, "ColeProfessionPlanner", itemId)
    addResult("Auctionator", ok, value)
  else
    table.insert(result, "Auctionator: API unavailable")
  end

  if TSM_API and TSM_API.GetCustomPriceValue then
    local ok, value, detail = pcall(TSM_API.GetCustomPriceValue, "dbmarket", "i:" .. itemId)
    addResult("TSM dbmarket", ok, value, detail)
  else
    table.insert(result, "TSM dbmarket: API unavailable")
  end

  local appHelperLoaded = C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("TradeSkillMaster_AppHelper")
    or IsAddOnLoaded and IsAddOnLoaded("TradeSkillMaster_AppHelper")
  table.insert(result, "TSM AppHelper: " .. (appHelperLoaded and "loaded" or "not loaded"))
  return result
end
