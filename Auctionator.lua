SPP.Auctionator = SPP.Auctionator or {}
local CALLER = "ColeProfessionPlanner"
local VOLUME_TTL_SECONDS = 30 * 60

local function currentTime()
  local serverTime = GetServerTime and GetServerTime() or nil
  if serverTime and serverTime > 0 then return serverTime end
  if time then return time() end
  return os and os.time and os.time() or 0
end

function SPP.Auctionator:GetVolumeUnitPrice(itemId)
  local records = ColeProfessionPlannerDB and ColeProfessionPlannerDB.volumePrices
  local record = records and records[itemId]
  if not record or not record.timestamp or currentTime() - record.timestamp > VOLUME_TTL_SECONDS then return nil end
  if not record.requested or record.requested <= 0 or not record.total or record.total <= 0 then return nil, record end
  return record.total / record.requested, record
end

function SPP.Auctionator:IsItemCurrentlyAvailable(itemId)
  local unitPrice, record = self:GetVolumeUnitPrice(itemId)
  if not record or not unitPrice or (record.available or 0) < 1 then return false end
  return true, unitPrice, record.available
end

local function cheapestStackCost(tiers, needed)
  local costs = { [0] = 0 }
  for _, tier in ipairs(tiers) do
    local nextCosts = {}
    for covered, cost in pairs(costs) do nextCosts[covered] = cost end
    for covered, cost in pairs(costs) do
      local nextCovered = math.min(needed, covered + tier.quantity)
      local nextCost = cost + tier.buyout
      if not nextCosts[nextCovered] or nextCost < nextCosts[nextCovered] then
        nextCosts[nextCovered] = nextCost
      end
    end
    costs = nextCosts
  end
  return costs[needed]
end

function SPP.Auctionator:CaptureVolumePrices(results, plan)
  local requested = plan and plan.shopping or {}
  local tiersByItem = {}
  local constants = Auctionator and Auctionator.Constants and Auctionator.Constants.AuctionItemInfo
  if not constants then return 0 end
  for _, result in ipairs(results or {}) do
    local resultItemId = C_Item and C_Item.GetItemInfoInstant and select(1, C_Item.GetItemInfoInstant(result.itemString)) or nil
    for _, auction in ipairs(result.entries or {}) do
      local info = auction.info or {}
      local itemId = info[constants.ItemID] or resultItemId
      local quantity = tonumber(info[constants.Quantity]) or 0
      local buyout = tonumber(info[constants.Buyout]) or 0
      if requested[itemId] and quantity > 0 and buyout > 0 then
        tiersByItem[itemId] = tiersByItem[itemId] or {}
        table.insert(tiersByItem[itemId], { quantity = quantity, buyout = buyout, unit = buyout / quantity })
      end
    end
  end

  ColeProfessionPlannerDB.volumePrices = ColeProfessionPlannerDB.volumePrices or {}
  local captured = 0
  for itemId, needed in pairs(requested) do
    local tiers = tiersByItem[itemId]
    if tiers then
      local requestedQuantity = math.ceil(needed)
      local available = 0
      for _, tier in ipairs(tiers) do available = available + tier.quantity end
      local total = cheapestStackCost(tiers, requestedQuantity)
      ColeProfessionPlannerDB.volumePrices[itemId] = {
        requested = requestedQuantity, available = available, total = total, timestamp = currentTime()
      }
      if total then captured = captured + 1 end
    else
      ColeProfessionPlannerDB.volumePrices[itemId] = {
        requested = math.ceil(needed), available = 0, timestamp = currentTime()
      }
    end
  end
  SPP.Price:ClearCache()
  return captured
end

function SPP.Auctionator:ReceiveEvent(eventName, results)
  local searchEnd = Auctionator and Auctionator.Shopping and Auctionator.Shopping.Tab
    and Auctionator.Shopping.Tab.Events and Auctionator.Shopping.Tab.Events.SearchEnd
  if not self.collecting or eventName ~= searchEnd then return end
  self.collecting = false
  local count = self:CaptureVolumePrices(results, self.activePlan)
  self.activePlan = nil
  print(string.format("|cff75c94fCole:|r captured quantity pricing for %d auction items; recalculating the route.", count))
  if SPP.UI and SPP.UI.OnAuctionPricesUpdated then SPP.UI:OnAuctionPricesUpdated(count) end
end

function SPP.Auctionator:RegisterSearchEvents()
  if self.eventsRegistered then return true end
  local event = Auctionator and Auctionator.Shopping and Auctionator.Shopping.Tab
    and Auctionator.Shopping.Tab.Events and Auctionator.Shopping.Tab.Events.SearchEnd
  if not event or not Auctionator.EventBus or not Auctionator.EventBus.Register then return false end
  Auctionator.EventBus:Register(self, { event })
  self.eventsRegistered = true
  return true
end

function SPP.Auctionator:IsAuctionHouseOpen()
  return (AuctionHouseFrame and AuctionHouseFrame:IsShown()) or (AuctionFrame and AuctionFrame:IsShown()) or false
end

function SPP.Auctionator:GetShoppingRows(plan, auctionOnly)
  local rows, unresolved = {}, {}
  for itemId, quantity in pairs(plan and plan.shopping or {}) do
    if quantity > 0.001 then
      local name = SPP.Data:GetItemName(itemId)
      local vendorPrice = SPP.Data:GetVendorPrice(itemId)
      if auctionOnly and vendorPrice then
        -- Profession supplies have a fixed vendor price and never belong in an AH scan.
      elseif name == "Item " .. tostring(itemId) then
        table.insert(unresolved, itemId)
      else
        table.insert(rows, {
          itemId = itemId, name = name, quantity = math.ceil(quantity),
          vendor = vendorPrice ~= nil, vendorPrice = vendorPrice
        })
      end
    end
  end
  table.sort(rows, function(a, b) return a.name < b.name end)
  return rows, unresolved
end

function SPP.Auctionator:GetRecipeOpportunityPlan(plan)
  local shopping = {}
  for _, opportunity in ipairs(plan and plan.recipeOpportunities or {}) do
    shopping[opportunity.itemId] = 1
  end
  return {
    profession = plan and plan.profession or "profession",
    fromSkill = plan and plan.fromSkill or 1,
    toSkill = plan and plan.toSkill or 1,
    maxExpansion = plan and plan.maxExpansion,
    maxPhase = plan and plan.maxPhase,
    shopping = shopping,
    recipeOpportunityScan = true
  }
end

function SPP.Auctionator:GetRefreshPlan(plan)
  local shopping = {}
  for itemId, quantity in pairs(plan and (plan.refreshShopping or plan.shopping) or {}) do
    shopping[itemId] = quantity
  end
  for itemId, quantity in pairs(plan and plan.shopping or {}) do
    shopping[itemId] = math.max(shopping[itemId] or 0, quantity)
  end
  for _, opportunity in ipairs(plan and plan.recipeOpportunities or {}) do
    shopping[opportunity.itemId] = math.max(shopping[opportunity.itemId] or 0, 1)
  end
  return {
    profession = plan and plan.profession or "profession",
    fromSkill = plan and plan.fromSkill or 1,
    toSkill = plan and plan.toSkill or 1,
    maxExpansion = plan and plan.maxExpansion,
    maxPhase = plan and plan.maxPhase,
    shopping = shopping,
    fullMarketRefresh = true,
    refreshQuantityCap = plan and plan.refreshQuantityCap
  }
end

function SPP.Auctionator:RefreshPrices(plan)
  local refreshPlan = self:GetRefreshPlan(plan)
  if not next(refreshPlan.shopping) then return false, "No candidate materials to refresh" end
  local count = #self:GetShoppingRows(refreshPlan, true)
  if count == 0 then
    return true, "All candidate materials in this range are sold by vendors; no auction scan is needed."
  end
  local ok, message = self:Search(refreshPlan)
  local capText = refreshPlan.refreshQuantityCap and string.format("; alternative quantities capped at %d", refreshPlan.refreshQuantityCap) or ""
  return ok, ok and string.format(
    "Refreshing %d materials for skill %d-%d%s",
    count, refreshPlan.fromSkill, refreshPlan.toSkill, capText
  ) or message
end

function SPP.Auctionator:SearchRecipeOpportunities(plan)
  local opportunityPlan = self:GetRecipeOpportunityPlan(plan)
  if not next(opportunityPlan.shopping) then return false, "No cheaper unknown recipes were found" end
  local ok, message = self:Search(opportunityPlan)
  return ok, ok and "Searching Auctionator for potentially cheaper recipes" or message
end

function SPP.Auctionator:GetSearchStrings(plan, advanced)
  local api = Auctionator and Auctionator.API and Auctionator.API.v1
  local terms = {}
  for _, row in ipairs(self:GetShoppingRows(plan, true)) do
    if advanced and api and api.ConvertToSearchString then
      table.insert(terms, api.ConvertToSearchString(CALLER, {
        searchString = row.name, isExact = true, quantity = row.quantity
      }))
    else
      table.insert(terms, row.name)
    end
  end
  return terms
end

function SPP.Auctionator:CreateList(plan)
  local api = Auctionator and Auctionator.API and Auctionator.API.v1
  if not api or not api.CreateShoppingList then return false, "Auctionator Shopping List API is unavailable" end
  local terms = self:GetSearchStrings(plan, true)
  if #terms == 0 then return false, "The route has nothing left to buy" end
  local suffix = plan.priceDiscovery and "price scan" or "materials"
  local name = string.format("Cole: %s %s %d-%d", plan.profession, suffix, plan.fromSkill, plan.toSkill)
  local ok, message = pcall(api.CreateShoppingList, CALLER, name, terms)
  return ok, ok and ("Created Auctionator list: " .. name) or tostring(message)
end

function SPP.Auctionator:Search(plan)
  local rows, unresolved = self:GetShoppingRows(plan, true)
  if #unresolved > 0 then
    return false, "Missing item names for IDs: " .. table.concat(unresolved, ", ")
  end
  if #rows == 0 then return false, "All required materials are sold by vendors; no auction search is needed." end
  local api = Auctionator and Auctionator.API and Auctionator.API.v1
  if not api then return false, "Auctionator is not installed" end
  if not self:IsAuctionHouseOpen() then return false, "Open the Auction House before starting the search" end
  self:RegisterSearchEvents()
  self.collecting = self.eventsRegistered or false
  local auctionShopping = {}
  for _, row in ipairs(rows) do auctionShopping[row.itemId] = row.quantity end
  self.activePlan = { shopping = auctionShopping }
  local ok, message
  if api.MultiSearchAdvanced then
    local terms = {}
    for _, row in ipairs(rows) do
      table.insert(terms, { searchString = row.name, isExact = true, quantity = row.quantity })
    end
    ok, message = pcall(api.MultiSearchAdvanced, CALLER, terms)
  elseif api.MultiSearchExact then
    ok, message = pcall(api.MultiSearchExact, CALLER, self:GetSearchStrings(plan, false))
  else
    return false, "Auctionator search API is unavailable"
  end
  if not ok then self.collecting, self.activePlan = false, nil return false, tostring(message) end
  if plan.priceDiscovery then return true, "Price scan started. When it finishes, click Calculate again." end
  return true, "Material search started in Auctionator"
end
