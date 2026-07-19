SPP.Planner = SPP.Planner or {}

local BLOCK_SKILL_POINTS = 5
local SWITCH_SAVINGS_THRESHOLD = 0.12
local FAST_SWITCH_THRESHOLD = 0.05
local REFRESH_QUANTITY_CAP = 500
local VENDOR_STOCK_TTL_SECONDS = 10 * 60

local function currentTime()
  local serverTime = GetServerTime and GetServerTime() or nil
  if serverTime and serverTime > 0 then return serverTime end
  if time then return time() end
  return os and os.time and os.time() or 0
end

local function getRecipeCraftTime(recipe)
  local spellId = recipe[SPP.R.SPELL]
  local castTime
  if C_Spell and C_Spell.GetSpellInfo then
    local ok, info = pcall(C_Spell.GetSpellInfo, spellId)
    if ok and type(info) == "table" then castTime = info.castTime end
  end
  if (not castTime or castTime <= 0) and GetSpellInfo then
    local ok, _, _, _, legacyCastTime = pcall(GetSpellInfo, spellId)
    if ok then castTime = legacyCastTime end
  end
  if type(castTime) == "number" and castTime > 0 then return castTime / 1000, false end
  return 3, true
end

local function recipeCostWithStock(recipe, expectedCrafts, craftedStock, inventoryStock, options)
  local craftedTrial = SPP.Inventory:Copy(craftedStock)
  local inventoryTrial = SPP.Inventory:Copy(inventoryStock)
  local shopping = {}
  local reagents = recipe[SPP.R.REAGENTS]
  local total, usedInventory = 0, false
  for index = 1, #reagents, 2 do
    local itemId = reagents[index]
    local required = reagents[index + 1] * expectedCrafts
    local remaining = SPP.Inventory:Consume(itemId, required, craftedTrial)
    local afterInventory = SPP.Inventory:Consume(itemId, remaining, inventoryTrial)
    if afterInventory < remaining then usedInventory = true end
    remaining = afterInventory
    if remaining > 0 then
      local price = SPP.Price:GetEffectivePrice(itemId, options, {})
      if not price then return nil, itemId end
      total = total + price * remaining
      SPP.Price:AddShoppingMaterials(itemId, remaining, options, shopping)
    end
  end
  return total, nil, craftedTrial, inventoryTrial, shopping, usedInventory
end

local function addRecipeOutput(recipe, expectedCrafts, stock)
  local outputItem = recipe[SPP.R.OUTPUT]
  if outputItem then
    stock[outputItem] = (stock[outputItem] or 0) + expectedCrafts * (recipe[SPP.R.OUTPUT_QTY] or 1)
  end
end

local function mergeShopping(target, source)
  for itemId, quantity in pairs(source or {}) do
    target[itemId] = (target[itemId] or 0) + quantity
  end
end

local function evaluateRecipeBlock(recipe, skill, targetSkill, craftedStock, inventoryStock, options)
  local craftedTrial = SPP.Inventory:Copy(craftedStock)
  local inventoryTrial = SPP.Inventory:Copy(inventoryStock)
  local shopping = {}
  local total, expectedCrafts, covered, usedInventory = 0, 0, 0, false
  local lastSkill = math.min(targetSkill - 1, skill + BLOCK_SKILL_POINTS - 1)
  for futureSkill = skill, lastSkill do
    local chance = SPP.Data:GetSkillupChance(recipe, futureSkill)
    if chance <= 0 then break end
    local crafts = 1 / chance
    local expectedCost, missingItem, nextCrafted, nextInventory, stepShopping, stepUsedInventory = recipeCostWithStock(
      recipe, crafts, craftedTrial, inventoryTrial, options
    )
    if not expectedCost then return nil, missingItem end
    total = total + expectedCost
    expectedCrafts = expectedCrafts + crafts
    covered = covered + 1
    craftedTrial = nextCrafted
    inventoryTrial = nextInventory
    mergeShopping(shopping, stepShopping)
    usedInventory = usedInventory or stepUsedInventory
    addRecipeOutput(recipe, crafts, craftedTrial)
  end
  if covered == 0 then return nil end
  local desired = lastSkill - skill + 1
  local shortRoutePenalty = 1 + ((desired - covered) * 0.02)
  return {
    reagentCost = total,
    expectedCrafts = expectedCrafts,
    covered = covered,
    score = (total / covered) * shortRoutePenalty,
    craftedStock = craftedTrial,
    inventoryStock = inventoryTrial,
    shopping = shopping,
    usedInventory = usedInventory
  }
end

local function isBetterCandidate(candidate, current, routeMode)
  if not current then return true end
  if routeMode == "fast" and math.abs(candidate.fastScore - current.fastScore) > 0.001 then
    return candidate.fastScore < current.fastScore
  end
  return candidate.score < current.score
end

local function shouldSwitchRecipe(previous, best, routeMode)
  if routeMode == "fast" then
    local speedSavings = previous.fastScore > 0 and ((previous.fastScore - best.fastScore) / previous.fastScore) or 0
    if speedSavings >= FAST_SWITCH_THRESHOLD then return true end
    local costSavings = previous.score > 0 and ((previous.score - best.score) / previous.score) or 0
    return math.abs(speedSavings) < 0.01 and costSavings >= SWITCH_SAVINGS_THRESHOLD
  end
  local savings = previous.score > 0 and ((previous.score - best.score) / previous.score) or 0
  return savings >= SWITCH_SAVINGS_THRESHOLD
end

local function isRecipeKnown(recipe, options)
  local spellId = recipe[SPP.R.SPELL]
  return options.knownRecipes and options.knownRecipes[spellId]
    or IsSpellKnown and IsSpellKnown(spellId)
    or IsPlayerSpell and IsPlayerSpell(spellId)
end

local function shouldEvaluateRecipe(recipe, options)
  if not isRecipeKnown(recipe, options)
    and SPP.Data:IsSeasonalRecipe(recipe, options.maxExpansion or 2, options.maxPhase or 9) then
    return false
  end
  return isRecipeKnown(recipe, options)
    or SPP.Data:IsCommonRecipe(recipe, options.maxExpansion or 2, options.maxPhase or 9)
    or SPP.Data:IsVendorRecipe(recipe, options.maxExpansion or 2, options.maxPhase or 9)
    or options.includeRareRecipes
end

local function getCompletedMandatoryRank(recipes, craftedStock, inventoryStock)
  local completedRank = 0
  for _, recipe in ipairs(recipes) do
    local rank = recipe[SPP.R.MANDATORY]
    local output = recipe[SPP.R.OUTPUT]
    if rank and output and ((craftedStock[output] or 0) + (inventoryStock[output] or 0)) >= 1 then
      completedRank = math.max(completedRank, rank)
    end
  end
  return completedRank
end

local function getMandatoryProgression(recipes, skill, targetSkill, craftedStock, inventoryStock, options)
  local completedRank = getCompletedMandatoryRank(recipes, craftedStock, inventoryStock)
  local dueRecipe, nextSkill
  for _, recipe in ipairs(recipes) do
    local rank = recipe[SPP.R.MANDATORY]
    local learn = recipe[SPP.R.LEARN]
    if rank and rank > completedRank and learn < targetSkill
      and SPP.Data:IsAvailable(
        recipe[SPP.R.EXPANSION], recipe[SPP.R.PHASE], options.maxExpansion or 2, options.maxPhase or 9
      ) then
      if learn <= skill then
        if not dueRecipe or rank < dueRecipe[SPP.R.MANDATORY] then dueRecipe = recipe end
      elseif not nextSkill or learn < nextSkill then
        nextSkill = learn
      end
    end
  end
  return dueRecipe, nextSkill
end

local function recipeOverlapsSkillRange(recipe, startSkill, targetSkill)
  local firstSkill = math.max(startSkill, recipe[SPP.R.LEARN])
  local lastSkillExclusive = math.min(targetSkill, recipe[SPP.R.GRAY])
  return firstSkill < lastSkillExclusive, firstSkill, lastSkillExclusive
end

local function addRefreshMaterial(shopping, itemId, quantity, options, visiting)
  quantity = math.max(0, quantity - ((options.inventory and options.inventory[itemId]) or 0))
  if quantity <= 0 then return end
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
  if acquiredRecipes[spellId] then return true end
  local maxExpansion, maxPhase = options.maxExpansion or 2, options.maxPhase or 9
  local recipeItem = recipe[SPP.R.RECIPE_ITEM]
  if SPP.Data:IsSeasonalRecipe(recipe, maxExpansion, maxPhase) then
    return false, recipeItem, nil, "seasonal"
  end
  if SPP.Data:IsCommonRecipe(recipe, maxExpansion, maxPhase) then
    return true, nil, nil, "trainer"
  end
  local vendorRecipe = SPP.Data:IsVendorRecipe(recipe, maxExpansion, maxPhase)
  if vendorRecipe then
    if recipeItem and options.inventory and (options.inventory[recipeItem] or 0) >= 1 then
      return true, nil, nil, "owned", recipeItem
    end
    local limited = SPP.Data:IsLimitedVendorRecipe(recipe, maxExpansion, maxPhase)
    local stock = recipeItem and ColeProfessionPlannerDB and ColeProfessionPlannerDB.vendorRecipeStock
      and ColeProfessionPlannerDB.vendorRecipeStock[recipeItem] or nil
    local freshStock = stock and currentTime() - (stock.checkedAt or 0) <= VENDOR_STOCK_TTL_SECONDS
    if options.includeVendorRecipes and (not limited or (freshStock and stock.available)) then
      return true, recipeItem, SPP.Data:GetVendorPrice(recipeItem) or 0, "vendor", recipeItem
    end
  end
  local blockedKind = vendorRecipe
    and (options.includeVendorRecipes and "vendor-unconfirmed" or "vendor-optional")
    or nil
  local blockedCost = vendorRecipe and (SPP.Data:GetVendorPrice(recipeItem) or 0) or nil
  if not options.includeRareRecipes then return false, recipeItem, blockedCost, blockedKind, recipeItem end
  if not recipeItem then return false end
  local available, price
  if SPP.Auctionator and SPP.Auctionator.IsItemCurrentlyAvailable then
    available, price = SPP.Auctionator:IsItemCurrentlyAvailable(recipeItem)
  end
  if available and price then return true, recipeItem, price, "auction", recipeItem end
  local kind = blockedKind or "auction"
  return false, recipeItem, blockedCost, kind, recipeItem
end

local function getNextRecipeUnlock(recipes, skill, targetSkill, options, acquiredRecipes)
  local nextSkill
  for _, recipe in ipairs(recipes) do
    local learn = recipe[SPP.R.LEARN]
    if not recipe[SPP.R.MANDATORY] and learn > skill and learn < targetSkill
      and SPP.Data:IsAvailable(
        recipe[SPP.R.EXPANSION], recipe[SPP.R.PHASE], options.maxExpansion or 2, options.maxPhase or 9
      ) then
      local allowed = getRecipeAccess(recipe, options, acquiredRecipes)
      if allowed and (not nextSkill or learn < nextSkill) then nextSkill = learn end
    end
  end
  return nextSkill
end

function SPP.Planner:BuildRefreshShopping(profession, startSkill, targetSkill, options)
  options = options or {}
  options.refreshQuantityCap = options.refreshQuantityCap or REFRESH_QUANTITY_CAP
  local shopping = {}
  local recipes = SPP.Data.professions[profession] or {}
  local completedMandatoryRank = getCompletedMandatoryRank(recipes, {}, options.inventory or {})
  for _, recipe in ipairs(recipes) do
    local overlaps, firstSkill, lastSkillExclusive = recipeOverlapsSkillRange(recipe, startSkill, targetSkill)
    local mandatoryRank = recipe[SPP.R.MANDATORY]
    local mandatory = mandatoryRank and mandatoryRank > completedMandatoryRank
      and recipe[SPP.R.LEARN] < targetSkill
    local eligible = mandatory or (not mandatoryRank and overlaps)
    if eligible and SPP.Data:IsAvailable(
      recipe[SPP.R.EXPANSION], recipe[SPP.R.PHASE], options.maxExpansion or 2, options.maxPhase or 9
    ) and shouldEvaluateRecipe(recipe, options) then
      if options.includeRareRecipes
        and not isRecipeKnown(recipe, options)
        and not SPP.Data:IsCommonRecipe(recipe, options.maxExpansion or 2, options.maxPhase or 9)
        and recipe[SPP.R.RECIPE_ITEM] then
        shopping[recipe[SPP.R.RECIPE_ITEM]] = math.max(shopping[recipe[SPP.R.RECIPE_ITEM]] or 0, 1)
      end
      local expectedCrafts = mandatory and 1 or 0
      if not mandatory then
        for skill = firstSkill, lastSkillExclusive - 1 do
          local chance = SPP.Data:GetSkillupChance(recipe, skill)
          if chance > 0 then expectedCrafts = expectedCrafts + (1 / chance) end
        end
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

local function buildPriceScan(profession, startSkill, targetSkill, options, refreshShopping, requiredItems)
  local shopping, count = {}, 0
  for itemId, quantity in pairs(refreshShopping) do
    if (not requiredItems or requiredItems[itemId]) and not SPP.Price:GetUnitPrice(itemId) then
      shopping[itemId] = math.ceil(quantity)
      count = count + 1
    end
  end
  if count == 0 then return nil end
  return {
    profession = profession, fromSkill = startSkill, toSkill = targetSkill,
    maxExpansion = options.maxExpansion or 2, maxPhase = options.maxPhase or 9,
    routeMode = options.routeMode or "economy",
    includeVendorRecipes = options.includeVendorRecipes == true,
    totalCost = nil, steps = {}, shopping = shopping, usedInventory = options.inventory ~= nil,
    refreshShopping = refreshShopping, priceDiscovery = true, missingPriceCount = count
  }
end

function SPP.Planner:BuildPriceScan(profession, startSkill, targetSkill, options)
  options = options or {}
  local refreshShopping = self:BuildRefreshShopping(profession, startSkill, targetSkill, options)
  return buildPriceScan(profession, startSkill, targetSkill, options, refreshShopping)
end

function SPP.Planner:Build(profession, startSkill, targetSkill, options)
  options = options or {}
  local routeMode = options.routeMode == "fast" and "fast" or "economy"
  local recipes = SPP.Data.professions[profession]
  if not recipes then return nil, "Unknown profession" end
  local maxSkill = (options.maxExpansion or 2) == 1 and 300 or 375
  if startSkill < 1 or targetSkill > maxSkill or startSkill >= targetSkill then return nil, "Invalid skill range" end

  SPP.Price:ClearCache()
  local refreshShopping = self:BuildRefreshShopping(profession, startSkill, targetSkill, options)
  local steps, total, shopping = {}, 0, {}
  local skippedMissingItems = {}
  local craftedStock = {}
  local inventoryStock = SPP.Inventory:Copy(options.inventory)
  local previousRecipe, inventoryApplied = nil, false
  local acquiredRecipes, opportunityMap, seasonalMap, retiredRecipes = {}, {}, {}, {}
  local skill = startSkill
  while skill < targetSkill do
    local mandatoryRecipe, nextMandatorySkill = getMandatoryProgression(
      recipes, skill, targetSkill, craftedStock, inventoryStock, options
    )
    if mandatoryRecipe then
      local allowed, acquisitionItem, acquisitionCost, acquisitionKind, recipeItem = getRecipeAccess(
        mandatoryRecipe, options, acquiredRecipes
      )
      if not allowed then
        local recipeItem = mandatoryRecipe[SPP.R.RECIPE_ITEM]
        return nil, "Required progression recipe is unavailable: " .. mandatoryRecipe[SPP.R.NAME],
          recipeItem and buildPriceScan(
            profession, startSkill, targetSkill, options, refreshShopping, { [recipeItem] = true }
          ) or nil
      end
      local reagentCost, missingItem, nextCrafted, nextInventory, stepShopping, stepUsedInventory = recipeCostWithStock(
        mandatoryRecipe, 1, craftedStock, inventoryStock, options
      )
      if not reagentCost then
        return nil, "Missing price for required progression material: " .. SPP.Data:GetItemName(missingItem),
          buildPriceScan(profession, startSkill, targetSkill, options, refreshShopping, { [missingItem] = true })
      end
      craftedStock = nextCrafted
      inventoryStock = nextInventory
      addRecipeOutput(mandatoryRecipe, 1, craftedStock)
      local stepMaterials = {}
      mergeShopping(stepMaterials, stepShopping)
      mergeShopping(shopping, stepShopping)
      if acquisitionItem then
        shopping[acquisitionItem] = (shopping[acquisitionItem] or 0) + 1
        stepMaterials[acquisitionItem] = (stepMaterials[acquisitionItem] or 0) + 1
      end
      if acquisitionKind then acquiredRecipes[mandatoryRecipe[SPP.R.SPELL]] = true end
      local craftSeconds, craftTimeEstimated = getRecipeCraftTime(mandatoryRecipe)
      local stepEnd = math.min(targetSkill, skill + 1)
      table.insert(steps, {
        recipe = mandatoryRecipe,
        fromSkill = skill,
        toSkill = stepEnd,
        expectedCrafts = 1,
        unitCost = reagentCost,
        cost = reagentCost + (acquisitionCost or 0),
        materials = stepMaterials,
        craftSeconds = craftSeconds,
        craftTimeEstimated = craftTimeEstimated,
        usedInventory = stepUsedInventory,
        acquisitionItem = acquisitionItem,
        acquisitionKind = acquisitionKind,
        recipeItem = recipeItem,
        mandatory = true
      })
      total = total + reagentCost + (acquisitionCost or 0)
      inventoryApplied = inventoryApplied or stepUsedInventory
      previousRecipe = nil
      skill = stepEnd
    else
    local candidates, best, bestRetired, rareCandidates, missingItems = nil, nil, nil, nil, {}
    local nextUnlockSkill = getNextRecipeUnlock(recipes, skill, targetSkill, options, acquiredRecipes)
    local blockTargetSkill = targetSkill
    if nextMandatorySkill then blockTargetSkill = math.min(blockTargetSkill, nextMandatorySkill) end
    if nextUnlockSkill then blockTargetSkill = math.min(blockTargetSkill, nextUnlockSkill) end
    for _, recipe in ipairs(recipes) do
      if SPP.Data:IsAvailable(recipe[SPP.R.EXPANSION], recipe[SPP.R.PHASE], options.maxExpansion or 2, options.maxPhase or 9)
        and not recipe[SPP.R.MANDATORY] and recipe[SPP.R.LEARN] <= skill then
        local block, missingItem = evaluateRecipeBlock(
          recipe, skill, blockTargetSkill, craftedStock, inventoryStock, options
        )
        if block then
            local allowed, acquisitionItem, acquisitionCost, acquisitionKind, recipeItem = getRecipeAccess(
              recipe, options, acquiredRecipes
            )
            if allowed then
              local totalExpectedCost = block.reagentCost + (acquisitionCost or 0)
              local craftSecondsPerCast = getRecipeCraftTime(recipe)
              local candidate = {
                recipe = recipe, expectedCost = totalExpectedCost, reagentCost = block.reagentCost,
                expectedCrafts = block.expectedCrafts, covered = block.covered,
                craftCost = block.reagentCost / block.expectedCrafts,
                craftedStock = block.craftedStock, inventoryStock = block.inventoryStock,
                shopping = block.shopping, usedInventory = block.usedInventory,
                acquisitionItem = acquisitionItem, acquisitionCost = acquisitionCost,
                acquisitionKind = acquisitionKind, recipeItem = recipeItem,
                score = block.score + ((acquisitionCost or 0) / block.covered),
                fastScore = (block.expectedCrafts * craftSecondsPerCast) / block.covered
              }
              candidates = candidates or {}
              table.insert(candidates, candidate)
              if retiredRecipes[recipe] then
                if isBetterCandidate(candidate, bestRetired, routeMode) then bestRetired = candidate end
              elseif isBetterCandidate(candidate, best, routeMode) then
                best = candidate
              end
            elseif acquisitionKind == "seasonal" then
              seasonalMap[recipe[SPP.R.SPELL]] = recipe
            elseif acquisitionItem and (options.includeRareRecipes or acquisitionKind == "vendor-optional"
              or acquisitionKind == "vendor-unconfirmed") then
              rareCandidates = rareCandidates or {}
              table.insert(rareCandidates, {
                recipe = recipe, itemId = acquisitionItem,
                expectedCost = block.reagentCost + (acquisitionCost or 0),
                score = block.score + ((acquisitionCost or 0) / block.covered),
                covered = block.covered, acquisitionKind = acquisitionKind
              })
            end
        elseif missingItem then
          missingItems[missingItem] = true
          skippedMissingItems[missingItem] = true
        end
      end
    end
    best = best or bestRetired
    if not best then
      local missing = {}
      for itemId in pairs(missingItems) do table.insert(missing, SPP.Data:GetItemName(itemId)) end
      table.sort(missing)
      local priceScan = buildPriceScan(
        profession, startSkill, targetSkill, options, refreshShopping, missingItems
      )
      local message = #missing > 0 and ("Missing prices at skill " .. skill .. ": " .. table.concat(missing, ", "))
        or ("No usable recipe at skill " .. skill)
      return nil, message, priceScan
    end

    if previousRecipe and best.recipe ~= previousRecipe then
      for _, candidate in ipairs(candidates or {}) do
        if candidate.recipe == previousRecipe then
          if not shouldSwitchRecipe(candidate, best, routeMode) then best = candidate end
          break
        end
      end
    end

    for _, opportunity in ipairs(rareCandidates or {}) do
      local comparablePoints = math.min(best.covered, opportunity.covered)
      local savings = (best.score - opportunity.score) * comparablePoints
      if savings > 0 then
        local entry = opportunityMap[opportunity.itemId]
        if not entry then
          entry = {
            itemId = opportunity.itemId, recipe = opportunity.recipe,
            fromSkill = skill, toSkill = skill + comparablePoints, estimatedSavings = 0,
            acquisitionKind = opportunity.acquisitionKind
          }
          opportunityMap[opportunity.itemId] = entry
        end
        entry.fromSkill = math.min(entry.fromSkill, skill)
        entry.toSkill = math.max(entry.toSkill, skill + comparablePoints)
        entry.estimatedSavings = entry.estimatedSavings + savings
      end
    end

    if previousRecipe and best.recipe ~= previousRecipe then retiredRecipes[previousRecipe] = true end
    craftedStock = best.craftedStock
    inventoryStock = best.inventoryStock
    local stepMaterials = {}
    mergeShopping(stepMaterials, best.shopping)
    for itemId, quantity in pairs(best.shopping or {}) do shopping[itemId] = (shopping[itemId] or 0) + quantity end
    if best.acquisitionItem then
      shopping[best.acquisitionItem] = (shopping[best.acquisitionItem] or 0) + 1
      stepMaterials[best.acquisitionItem] = (stepMaterials[best.acquisitionItem] or 0) + 1
    end
    if best.acquisitionKind then acquiredRecipes[best.recipe[SPP.R.SPELL]] = true end
    inventoryApplied = inventoryApplied or best.usedInventory
    local blockEnd = skill + best.covered
    local craftSecondsPerCast, craftTimeEstimated = getRecipeCraftTime(best.recipe)
    local blockCraftSeconds = craftSecondsPerCast * best.expectedCrafts
    local previous = steps[#steps]
    if previous and previous.recipe == best.recipe then
      previous.toSkill = blockEnd
      previous.expectedCrafts = previous.expectedCrafts + best.expectedCrafts
      previous.cost = previous.cost + best.expectedCost
      previous.craftSeconds = previous.craftSeconds + blockCraftSeconds
      previous.craftTimeEstimated = previous.craftTimeEstimated or craftTimeEstimated
      mergeShopping(previous.materials, stepMaterials)
      previous.usedInventory = previous.usedInventory or best.usedInventory
      previous.acquisitionItem = previous.acquisitionItem or best.acquisitionItem
      previous.acquisitionKind = previous.acquisitionKind or best.acquisitionKind
      previous.recipeItem = previous.recipeItem or best.recipeItem
    else
      table.insert(steps, {
        recipe = best.recipe,
        fromSkill = skill,
        toSkill = blockEnd,
        expectedCrafts = best.expectedCrafts,
        unitCost = best.craftCost,
        cost = best.expectedCost,
        materials = stepMaterials,
        craftSeconds = blockCraftSeconds,
        craftTimeEstimated = craftTimeEstimated,
        usedInventory = best.usedInventory,
        acquisitionItem = best.acquisitionItem,
        acquisitionKind = best.acquisitionKind,
        recipeItem = best.recipeItem
      })
    end
    total = total + best.expectedCost
    previousRecipe = best.recipe
    skill = blockEnd
    end
  end
  local recipeOpportunities = {}
  for _, opportunity in pairs(opportunityMap) do table.insert(recipeOpportunities, opportunity) end
  table.sort(recipeOpportunities, function(a, b) return a.estimatedSavings > b.estimatedSavings end)
  local seasonalExclusions = {}
  for _, recipe in pairs(seasonalMap) do table.insert(seasonalExclusions, recipe) end
  table.sort(seasonalExclusions, function(a, b) return a[SPP.R.LEARN] < b[SPP.R.LEARN] end)
  local skippedMissingPriceCount = 0
  for _ in pairs(skippedMissingItems) do skippedMissingPriceCount = skippedMissingPriceCount + 1 end
  return {
    profession = profession, fromSkill = startSkill, toSkill = targetSkill,
    maxExpansion = options.maxExpansion or 2, maxPhase = options.maxPhase or 9,
    routeMode = routeMode,
    includeVendorRecipes = options.includeVendorRecipes == true,
    totalCost = total, steps = steps, shopping = shopping, usedInventory = inventoryApplied,
    refreshShopping = refreshShopping,
    recipeOpportunities = recipeOpportunities,
    seasonalExclusions = seasonalExclusions,
    skippedMissingPriceCount = skippedMissingPriceCount,
    calculatedAt = currentTime(),
    selection = (routeMode == "fast"
      and string.format("Fast: up to %d-point blocks, %d%% faster to switch", BLOCK_SKILL_POINTS, math.floor(FAST_SWITCH_THRESHOLD * 100 + 0.5))
      or string.format("Economy: up to %d-point blocks, %d%% minimum savings to switch", BLOCK_SKILL_POINTS, math.floor(SWITCH_SAVINGS_THRESHOLD * 100 + 0.5)))
      .. (options.includeVendorRecipes and " | vendor trips allowed" or " | no vendor travel")
  }
end

local function copyNumberMap(source)
  local result = {}
  for key, value in pairs(source or {}) do
    if type(key) == "number" and type(value) == "number" then result[key] = value end
  end
  return result
end

function SPP.Planner:SerializePlan(plan)
  if not plan or plan.priceDiscovery or not plan.profession then return nil end
  local saved = {
    schema = 1,
    profession = plan.profession,
    fromSkill = plan.fromSkill,
    toSkill = plan.toSkill,
    maxExpansion = plan.maxExpansion,
    maxPhase = plan.maxPhase,
    routeMode = plan.routeMode,
    includeVendorRecipes = plan.includeVendorRecipes == true,
    totalCost = plan.totalCost,
    usedInventory = plan.usedInventory,
    skippedMissingPriceCount = plan.skippedMissingPriceCount,
    calculatedAt = plan.calculatedAt,
    selection = plan.selection,
    shopping = copyNumberMap(plan.shopping),
    steps = {},
    recipeOpportunities = {},
    seasonalExclusions = {}
  }
  for _, step in ipairs(plan.steps or {}) do
    table.insert(saved.steps, {
      spellId = step.recipe and step.recipe[SPP.R.SPELL],
      fromSkill = step.fromSkill,
      toSkill = step.toSkill,
      expectedCrafts = step.expectedCrafts,
      unitCost = step.unitCost,
      cost = step.cost,
      materials = copyNumberMap(step.materials),
      craftSeconds = step.craftSeconds,
      craftTimeEstimated = step.craftTimeEstimated,
      usedInventory = step.usedInventory,
      acquisitionItem = step.acquisitionItem,
      acquisitionKind = step.acquisitionKind,
      recipeItem = step.recipeItem,
      mandatory = step.mandatory
    })
  end
  for _, opportunity in ipairs(plan.recipeOpportunities or {}) do
    table.insert(saved.recipeOpportunities, {
      spellId = opportunity.recipe and opportunity.recipe[SPP.R.SPELL],
      itemId = opportunity.itemId,
      fromSkill = opportunity.fromSkill,
      toSkill = opportunity.toSkill,
      estimatedSavings = opportunity.estimatedSavings,
      acquisitionKind = opportunity.acquisitionKind
    })
  end
  for _, recipe in ipairs(plan.seasonalExclusions or {}) do
    table.insert(saved.seasonalExclusions, recipe[SPP.R.SPELL])
  end
  return saved
end

function SPP.Planner:RestorePlan(saved)
  if type(saved) ~= "table" or saved.schema ~= 1 or not SPP.Data.professions[saved.profession] then return nil end
  local recipesBySpell = {}
  for _, recipe in ipairs(SPP.Data.professions[saved.profession]) do
    recipesBySpell[recipe[SPP.R.SPELL]] = recipe
  end
  local includeVendorRecipes = saved.includeVendorRecipes == true
  if saved.includeVendorRecipes == nil then
    for _, savedStep in ipairs(saved.steps or {}) do
      if savedStep.acquisitionKind == "vendor" then
        includeVendorRecipes = true
        break
      end
    end
  end
  local plan = {
    profession = saved.profession,
    fromSkill = saved.fromSkill,
    toSkill = saved.toSkill,
    maxExpansion = saved.maxExpansion,
    maxPhase = saved.maxPhase,
    routeMode = saved.routeMode == "fast" and "fast" or "economy",
    includeVendorRecipes = includeVendorRecipes,
    totalCost = saved.totalCost,
    usedInventory = saved.usedInventory,
    skippedMissingPriceCount = saved.skippedMissingPriceCount or 0,
    calculatedAt = saved.calculatedAt,
    selection = saved.selection,
    shopping = copyNumberMap(saved.shopping),
    steps = {},
    recipeOpportunities = {},
    seasonalExclusions = {},
    restored = true
  }
  for _, savedStep in ipairs(saved.steps or {}) do
    local recipe = recipesBySpell[savedStep.spellId]
    if not recipe then return nil end
    table.insert(plan.steps, {
      recipe = recipe,
      fromSkill = savedStep.fromSkill,
      toSkill = savedStep.toSkill,
      expectedCrafts = savedStep.expectedCrafts,
      unitCost = savedStep.unitCost,
      cost = savedStep.cost,
      materials = copyNumberMap(savedStep.materials),
      craftSeconds = savedStep.craftSeconds,
      craftTimeEstimated = savedStep.craftTimeEstimated,
      usedInventory = savedStep.usedInventory,
      acquisitionItem = savedStep.acquisitionItem,
      acquisitionKind = savedStep.acquisitionKind,
      recipeItem = savedStep.recipeItem,
      mandatory = savedStep.mandatory
    })
  end
  for _, savedOpportunity in ipairs(saved.recipeOpportunities or {}) do
    local recipe = recipesBySpell[savedOpportunity.spellId]
    if recipe then
      table.insert(plan.recipeOpportunities, {
        recipe = recipe,
        itemId = savedOpportunity.itemId,
        fromSkill = savedOpportunity.fromSkill,
        toSkill = savedOpportunity.toSkill,
        estimatedSavings = savedOpportunity.estimatedSavings,
        acquisitionKind = savedOpportunity.acquisitionKind
      })
    end
  end
  for _, spellId in ipairs(saved.seasonalExclusions or {}) do
    if recipesBySpell[spellId] then table.insert(plan.seasonalExclusions, recipesBySpell[spellId]) end
  end
  return plan
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
