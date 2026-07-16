SPP.Planner = SPP.Planner or {}

local LOOKAHEAD_POINTS = 5
local STICKINESS = 1.08
local REFRESH_QUANTITY_CAP = 500

local function currentTime()
  local serverTime = GetServerTime and GetServerTime() or nil
  if serverTime and serverTime > 0 then return serverTime end
  if time then return time() end
  return os and os.time and os.time() or 0
end

local function recipeCostWithStock(recipe, expectedCrafts, stock, options)
  local trial = SPP.Inventory:Copy(stock)
  local shopping = {}
  local reagents = recipe[SPP.R.REAGENTS]
  local total, usedInventory = 0, false
  for index = 1, #reagents, 2 do
    local itemId = reagents[index]
    local required = reagents[index + 1] * expectedCrafts
    local remaining = SPP.Inventory:Consume(itemId, required, trial)
    if remaining < required then usedInventory = true end
    if remaining > 0 then
      local price = SPP.Price:GetEffectivePrice(itemId, options, {})
      if not price then return nil, itemId end
      total = total + price * remaining
      SPP.Price:AddShoppingMaterials(itemId, remaining, options, shopping)
    end
  end
  return total, nil, trial, shopping, usedInventory
end

local function addRecipeOutput(recipe, expectedCrafts, stock)
  local outputItem = recipe[SPP.R.OUTPUT]
  if outputItem then
    stock[outputItem] = (stock[outputItem] or 0) + expectedCrafts * (recipe[SPP.R.OUTPUT_QTY] or 1)
  end
end

local function getLookaheadScore(recipe, skill, targetSkill, stock, options)
  local trial = SPP.Inventory:Copy(stock)
  local total, covered = 0, 0
  local lastSkill = math.min(targetSkill - 1, skill + LOOKAHEAD_POINTS - 1)
  for futureSkill = skill, lastSkill do
    local chance = SPP.Data:GetSkillupChance(recipe, futureSkill)
    if chance <= 0 then break end
    local expectedCrafts = 1 / chance
    local expectedCost, _, nextStock = recipeCostWithStock(recipe, expectedCrafts, trial, options)
    if not expectedCost then return nil end
    total = total + expectedCost
    covered = covered + 1
    trial = nextStock
    addRecipeOutput(recipe, expectedCrafts, trial)
  end
  if covered == 0 then return nil end
  local desired = lastSkill - skill + 1
  local shortRoutePenalty = 1 + ((desired - covered) * 0.02)
  return (total / covered) * shortRoutePenalty, covered
end

local function isRecipeKnown(recipe, options)
  local spellId = recipe[SPP.R.SPELL]
  return options.knownRecipes and options.knownRecipes[spellId]
    or IsSpellKnown and IsSpellKnown(spellId)
    or IsPlayerSpell and IsPlayerSpell(spellId)
end

local function shouldEvaluateRecipe(recipe, options)
  return isRecipeKnown(recipe, options)
    or SPP.Data:IsCommonRecipe(recipe, options.maxExpansion or 2, options.maxPhase or 9)
    or options.includeRareRecipes
end

local function addRefreshMaterial(shopping, itemId, quantity, options, visiting)
  quantity = math.min(quantity, options.refreshQuantityCap or REFRESH_QUANTITY_CAP)
  shopping[itemId] = math.max(shopping[itemId] or 0, quantity)
  if visiting[itemId] then return end
  visiting[itemId] = true

  for _, recipe in ipairs(SPP.Data.outputs[itemId] or {}) do
    if SPP.Price:CanCraftRecipe(recipe, options)
      and SPP.Data:IsAvailable(recipe[SPP.R.EXPANSION], recipe[SPP.R.PHASE], options.maxExpansion or 2, options.maxPhase or 9) then
      local outputQuantity = recipe[SPP.R.OUTPUT_QTY] or 1
      local reagents = recipe[SPP.R.REAGENTS]
      for index = 1, #reagents, 2 do
        addRefreshMaterial(shopping, reagents[index], quantity * reagents[index + 1] / outputQuantity, options, visiting)
      end
    end
  end

  for _, entry in ipairs(SPP.Data.conversionOutputs[itemId] or {}) do
    local conversion = entry.conversion
    if SPP.Data:IsAvailable(conversion[2], conversion[3], options.maxExpansion or 2, options.maxPhase or 9) then
      local inputs = entry.reverse and conversion[6] or conversion[5]
      local outputs = entry.reverse and conversion[5] or conversion[6]
      local outputQuantity = 1
      for index = 1, #outputs, 2 do
        if outputs[index] == itemId then outputQuantity = outputs[index + 1] break end
      end
      for index = 1, #inputs, 2 do
        addRefreshMaterial(shopping, inputs[index], quantity * inputs[index + 1] / outputQuantity, options, visiting)
      end
    end
  end
  visiting[itemId] = nil
end

local function getRecipeAccess(recipe, options, acquiredRecipes)
  local spellId = recipe[SPP.R.SPELL]
  if isRecipeKnown(recipe, options) then return true end
  if SPP.Data:IsCommonRecipe(recipe, options.maxExpansion or 2, options.maxPhase or 9) then return true end
  if not options.includeRareRecipes then return false end
  local recipeItem = recipe[SPP.R.RECIPE_ITEM]
  if not recipeItem then return false end
  if acquiredRecipes[spellId] then return true end
  local price = SPP.Price:GetAuctionPrice(recipeItem)
  if price then return true, recipeItem, price end
  return false, recipeItem
end

function SPP.Planner:BuildRefreshShopping(profession, startSkill, targetSkill, options)
  options = options or {}
  options.refreshQuantityCap = options.refreshQuantityCap or REFRESH_QUANTITY_CAP
  local shopping = {}
  for _, recipe in ipairs(SPP.Data.professions[profession] or {}) do
    if SPP.Data:IsAvailable(
      recipe[SPP.R.EXPANSION], recipe[SPP.R.PHASE], options.maxExpansion or 2, options.maxPhase or 9
    ) and shouldEvaluateRecipe(recipe, options) then
      local firstSkill = math.max(startSkill, recipe[SPP.R.LEARN])
      local lastSkill = math.min(targetSkill - 1, recipe[SPP.R.GRAY] - 1)
      local expectedCrafts = 0
      for skill = firstSkill, lastSkill do
        local chance = SPP.Data:GetSkillupChance(recipe, skill)
        if chance > 0 then expectedCrafts = expectedCrafts + (1 / chance) end
      end
      if expectedCrafts > 0 then
        local reagents = recipe[SPP.R.REAGENTS]
        for index = 1, #reagents, 2 do
          local itemId = reagents[index]
          local quantity = reagents[index + 1] * expectedCrafts
          addRefreshMaterial(shopping, itemId, quantity, options, {})
        end
      end
    end
  end
  return shopping
end

function SPP.Planner:GetRefreshQuantityCap()
  return REFRESH_QUANTITY_CAP
end

function SPP.Planner:BuildPriceScan(profession, startSkill, targetSkill, options)
  local shopping, count = {}, 0
  local refreshShopping = self:BuildRefreshShopping(profession, startSkill, targetSkill, options)
  for itemId, quantity in pairs(refreshShopping) do
    if not SPP.Price:GetUnitPrice(itemId) then
      shopping[itemId] = math.ceil(quantity)
      count = count + 1
    end
  end
  if count == 0 then return nil end
  return {
    profession = profession, fromSkill = startSkill, toSkill = targetSkill,
    totalCost = nil, steps = {}, shopping = shopping, usedInventory = options.inventory ~= nil,
    refreshShopping = refreshShopping, priceDiscovery = true, missingPriceCount = count
  }
end

function SPP.Planner:Build(profession, startSkill, targetSkill, options)
  options = options or {}
  local recipes = SPP.Data.professions[profession]
  if not recipes then return nil, "Unknown profession" end
  local maxSkill = (options.maxExpansion or 2) == 1 and 300 or 375
  if startSkill < 1 or targetSkill > maxSkill or startSkill >= targetSkill then return nil, "Invalid skill range" end

  SPP.Price:ClearCache()
  local refreshShopping = self:BuildRefreshShopping(profession, startSkill, targetSkill, options)
  local priceScan = self:BuildPriceScan(profession, startSkill, targetSkill, options)
  if priceScan then
    return nil, string.format("Prices are missing for %d route materials", priceScan.missingPriceCount), priceScan
  end
  local steps, total, shopping = {}, 0, {}
  local missingItems = {}
  local stock = SPP.Inventory:Copy(options.inventory)
  local previousRecipe, inventoryApplied = nil, false
  local acquiredRecipes, opportunityMap = {}, {}
  for skill = startSkill, targetSkill - 1 do
    local candidates, best, rareCandidates
    for _, recipe in ipairs(recipes) do
      if SPP.Data:IsAvailable(recipe[SPP.R.EXPANSION], recipe[SPP.R.PHASE], options.maxExpansion or 2, options.maxPhase or 9)
        and recipe[SPP.R.LEARN] <= skill then
        local chance = SPP.Data:GetSkillupChance(recipe, skill)
        if chance > 0 then
          local expectedCrafts = 1 / chance
          local expectedCost, missingItem, trialStock, trialShopping, usedInventory = recipeCostWithStock(recipe, expectedCrafts, stock, options)
          if expectedCost then
            local allowed, acquisitionItem, acquisitionCost = getRecipeAccess(recipe, options, acquiredRecipes)
            if allowed then
              local lookahead, covered = getLookaheadScore(recipe, skill, targetSkill, stock, options)
              local totalExpectedCost = expectedCost + (acquisitionCost or 0)
              local candidate = {
                recipe = recipe, expectedCost = totalExpectedCost, reagentCost = expectedCost,
                craftCost = expectedCost / expectedCrafts, chance = chance,
                stock = trialStock, shopping = trialShopping, usedInventory = usedInventory,
                acquisitionItem = acquisitionItem, acquisitionCost = acquisitionCost,
                score = (lookahead or expectedCost) + ((acquisitionCost or 0) / (covered or 1))
              }
              candidates = candidates or {}
              table.insert(candidates, candidate)
              if not best or candidate.score < best.score then best = candidate end
            elseif acquisitionItem and options.includeRareRecipes then
              rareCandidates = rareCandidates or {}
              table.insert(rareCandidates, {
                recipe = recipe, itemId = acquisitionItem, expectedCost = expectedCost
              })
            end
          elseif missingItem then
            missingItems[missingItem] = true
          end
        end
      end
    end
    if not best then
      local missing = {}
      for itemId in pairs(missingItems) do table.insert(missing, SPP.Data:GetItemName(itemId)) end
      table.sort(missing)
      return nil, #missing > 0 and ("Missing prices: " .. table.concat(missing, ", ")) or ("No usable recipe at skill " .. skill)
    end

    if previousRecipe then
      for _, candidate in ipairs(candidates or {}) do
        if candidate.recipe == previousRecipe and candidate.score <= best.score * STICKINESS then
          best = candidate
          break
        end
      end
    end

    for _, opportunity in ipairs(rareCandidates or {}) do
      local savings = best.expectedCost - opportunity.expectedCost
      if savings > 0 then
        local entry = opportunityMap[opportunity.itemId]
        if not entry then
          entry = {
            itemId = opportunity.itemId, recipe = opportunity.recipe,
            fromSkill = skill, toSkill = skill + 1, estimatedSavings = 0
          }
          opportunityMap[opportunity.itemId] = entry
        end
        entry.fromSkill = math.min(entry.fromSkill, skill)
        entry.toSkill = math.max(entry.toSkill, skill + 1)
        entry.estimatedSavings = entry.estimatedSavings + savings
      end
    end

    local expectedCrafts = 1 / best.chance
    stock = best.stock
    for itemId, quantity in pairs(best.shopping or {}) do shopping[itemId] = (shopping[itemId] or 0) + quantity end
    if best.acquisitionItem then
      shopping[best.acquisitionItem] = (shopping[best.acquisitionItem] or 0) + 1
      acquiredRecipes[best.recipe[SPP.R.SPELL]] = true
    end
    addRecipeOutput(best.recipe, expectedCrafts, stock)
    inventoryApplied = inventoryApplied or best.usedInventory
    local previous = steps[#steps]
    if previous and previous.recipe == best.recipe then
      previous.toSkill = skill + 1
      previous.expectedCrafts = previous.expectedCrafts + expectedCrafts
      previous.cost = previous.cost + best.expectedCost
      previous.usedInventory = previous.usedInventory or best.usedInventory
      previous.acquisitionItem = previous.acquisitionItem or best.acquisitionItem
    else
      table.insert(steps, {
        recipe = best.recipe,
        fromSkill = skill,
        toSkill = skill + 1,
        expectedCrafts = expectedCrafts,
        unitCost = best.craftCost,
        cost = best.expectedCost,
        usedInventory = best.usedInventory,
        acquisitionItem = best.acquisitionItem
      })
    end
    total = total + best.expectedCost
    previousRecipe = best.recipe
  end
  local recipeOpportunities = {}
  for _, opportunity in pairs(opportunityMap) do table.insert(recipeOpportunities, opportunity) end
  table.sort(recipeOpportunities, function(a, b) return a.estimatedSavings > b.estimatedSavings end)
  return {
    profession = profession, fromSkill = startSkill, toSkill = targetSkill,
    totalCost = total, steps = steps, shopping = shopping, usedInventory = inventoryApplied,
    refreshShopping = refreshShopping,
    recipeOpportunities = recipeOpportunities,
    calculatedAt = currentTime(),
    selection = string.format("%d-point lookahead, %d%% switch threshold", LOOKAHEAD_POINTS, math.floor((STICKINESS - 1) * 100 + 0.5))
  }
end

function SPP:FormatMoney(copper)
  if not copper then return "?" end
  local rounded = math.floor(copper + 0.5)
  local gold = math.floor(rounded / 10000)
  local silver = math.floor((rounded % 10000) / 100)
  local bronze = rounded % 100
  if gold > 0 then return string.format("%dg %02ds %02dc", gold, silver, bronze) end
  if silver > 0 then return string.format("%ds %02dc", silver, bronze) end
  return bronze .. "c"
end
