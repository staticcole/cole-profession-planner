SPP.Inventory = SPP.Inventory or {}

function SPP.Inventory:GetBagCounts()
  local counts = {}
  local lastBag = NUM_BAG_SLOTS or 4
  for bag = 0, lastBag do
    local slots
    if C_Container and C_Container.GetContainerNumSlots then
      slots = C_Container.GetContainerNumSlots(bag)
    elseif GetContainerNumSlots then
      slots = GetContainerNumSlots(bag)
    end
    for slot = 1, slots or 0 do
      local itemId, quantity
      if C_Container and C_Container.GetContainerItemInfo then
        local info = C_Container.GetContainerItemInfo(bag, slot)
        if info then itemId, quantity = info.itemID, info.stackCount end
      elseif GetContainerItemInfo then
        local _, count, _, _, _, _, link = GetContainerItemInfo(bag, slot)
        itemId = link and tonumber(link:match("item:(%d+)"))
        quantity = count
      end
      if itemId and quantity then counts[itemId] = (counts[itemId] or 0) + quantity end
    end
  end
  return counts
end

local function currentCharacter()
  local name = UnitName and UnitName("player") or nil
  local realm = GetNormalizedRealmName and GetNormalizedRealmName()
    or GetRealmName and GetRealmName():gsub("[%s%-]", "") or nil
  return name, realm
end

local function connectedRealms(realm)
  local realms = {}
  if realm then realms[realm] = true end
  if GetAutoCompleteRealms then
    for _, connectedRealm in ipairs({ GetAutoCompleteRealms() }) do realms[connectedRealm] = true end
  end
  return realms
end

local function addCount(counts, itemId, quantity, filter)
  itemId, quantity = tonumber(itemId), tonumber(quantity)
  if itemId and quantity and quantity > 0 and (not filter or filter[itemId]) then
    counts[itemId] = (counts[itemId] or 0) + quantity
  end
end

local function getSyndicatorCounts(itemIds)
  if not Syndicator or not Syndicator.API or not Syndicator.API.GetInventoryInfoByItemID then return nil end
  local counts, characters = {}, {}
  local currentName, currentRealm = currentCharacter()
  local currentFullName = Syndicator.API.GetCurrentCharacter and Syndicator.API.GetCurrentCharacter()

  for itemId in pairs(itemIds or SPP_ITEM_DATA or {}) do
    local ok, info = pcall(Syndicator.API.GetInventoryInfoByItemID, itemId, true, true)
    if ok and info then
      for _, entry in ipairs(info.characters or {}) do
        local isCurrent = currentFullName and (entry.character .. "-" .. entry.realmNormalized) == currentFullName
          or entry.character == currentName and entry.realmNormalized == currentRealm
        if not isCurrent then
          local quantity = (entry.bags or 0) + (entry.bank or 0)
          addCount(counts, itemId, quantity)
          if quantity > 0 then characters[entry.character .. "-" .. entry.realmNormalized] = true end
        end
      end
    end
  end
  return counts, { provider = "Baganator", characters = characters }
end

local function getSyndicatorCurrentBankCounts(itemIds)
  if not Syndicator or not Syndicator.API or not Syndicator.API.GetInventoryInfoByItemID then return nil end
  local counts = {}
  local currentName, currentRealm = currentCharacter()
  local currentFullName = Syndicator.API.GetCurrentCharacter and Syndicator.API.GetCurrentCharacter()
  for itemId in pairs(itemIds or SPP_ITEM_DATA or {}) do
    local ok, info = pcall(Syndicator.API.GetInventoryInfoByItemID, itemId, true, true)
    if ok and info then
      for _, entry in ipairs(info.characters or {}) do
        local isCurrent = currentFullName and (entry.character .. "-" .. entry.realmNormalized) == currentFullName
          or entry.character == currentName and entry.realmNormalized == currentRealm
        if isCurrent then addCount(counts, itemId, entry.bank or 0) end
      end
    end
  end
  return counts, { provider = "Baganator" }
end

local function parseBagnonItem(value)
  if type(value) ~= "string" then return nil end
  local payload, count = value:match("^([^;]+);?(%d*)$")
  local itemId = payload and tonumber(payload:match("^(%d+)"))
  return itemId, tonumber(count) or 1
end

local function getBagnonCounts(itemIds)
  if type(BrotherBags) ~= "table" then return nil end
  local counts, characters = {}, {}
  local currentName, realm = currentCharacter()
  local currentAlliance = UnitFactionGroup and UnitFactionGroup("player") == "Alliance" or nil
  for connectedRealm in pairs(connectedRealms(realm)) do
    local owners = BrotherBags[connectedRealm]
    for name, cache in pairs(type(owners) == "table" and owners or {}) do
      if type(cache) == "table" and not (name == currentName and connectedRealm == realm)
        and (cache.faction == nil or currentAlliance == nil or cache.faction == currentAlliance) then
        local hasItems = false
        for bagId, bag in pairs(cache) do
          if type(bagId) == "number" and type(bag) == "table" and type(bag.items) == "table" then
            for _, value in pairs(bag.items) do
              local itemId, quantity = parseBagnonItem(value)
              if itemId and (not itemIds or itemIds[itemId]) then
                addCount(counts, itemId, quantity)
                hasItems = true
              end
            end
          end
        end
        if hasItems then characters[name .. "-" .. connectedRealm] = true end
      end
    end
  end
  return counts, { provider = "Bagnon", characters = characters }
end

local function getBagnonCurrentBankCounts(itemIds)
  if type(BrotherBags) ~= "table" then return nil end
  local counts = {}
  local currentName, realm = currentCharacter()
  local cache = realm and currentName and BrotherBags[realm] and BrotherBags[realm][currentName]
  if type(cache) ~= "table" then return counts, { provider = "Bagnon" } end
  local bankContainer = BANK_CONTAINER or -1
  local lastBag = NUM_BAG_SLOTS or 4
  for bagId, bag in pairs(cache) do
    if type(bagId) == "number" and (bagId == bankContainer or bagId > lastBag)
      and type(bag) == "table" and type(bag.items) == "table" then
      for _, value in pairs(bag.items) do
        local itemId, quantity = parseBagnonItem(value)
        if itemId and (not itemIds or itemIds[itemId]) then addCount(counts, itemId, quantity) end
      end
    end
  end
  return counts, { provider = "Bagnon" }
end

function SPP.Inventory:GetAltCounts(itemIds)
  local counts, info = getSyndicatorCounts(itemIds)
  if counts then return counts, info end
  counts, info = getBagnonCounts(itemIds)
  if counts then return counts, info end
  return {}, { provider = nil, characters = {} }
end

function SPP.Inventory:GetCurrentBankCounts(itemIds)
  local counts, info = getSyndicatorCurrentBankCounts(itemIds)
  if counts then return counts, info end
  counts, info = getBagnonCurrentBankCounts(itemIds)
  if counts then return counts, info end
  return {}, { provider = nil }
end

function SPP.Inventory:GetAltProviderName()
  if Syndicator and Syndicator.API and Syndicator.API.GetInventoryInfoByItemID then return "Baganator" end
  if type(BrotherBags) == "table" then return "Bagnon" end
  return nil
end

function SPP.Inventory:Merge(target, source)
  target = target or {}
  for itemId, quantity in pairs(source or {}) do target[itemId] = (target[itemId] or 0) + quantity end
  return target
end

function SPP.Inventory:Copy(source)
  local result = {}
  for itemId, quantity in pairs(source or {}) do result[itemId] = quantity end
  return result
end

local function quantityFor(itemId, items)
  for index = 1, #items, 2 do
    if items[index] == itemId then return items[index + 1] end
  end
  return nil
end

function SPP.Inventory:Consume(itemId, required, stock)
  local available = stock[itemId] or 0
  local direct = math.min(required, available)
  stock[itemId] = available - direct
  local remaining = required - direct
  if remaining <= 0 then return 0 end

  for _, entry in ipairs(SPP.Data.conversionOutputs[itemId] or {}) do
    local conversion = entry.conversion
    local inputs = entry.reverse and conversion[6] or conversion[5]
    local outputs = entry.reverse and conversion[5] or conversion[6]
    local outputQuantity = quantityFor(itemId, outputs)
    if outputQuantity then
      local possibleBatches
      for index = 1, #inputs, 2 do
        local inputId, inputQuantity = inputs[index], inputs[index + 1]
        local batches = (stock[inputId] or 0) / inputQuantity
        possibleBatches = possibleBatches and math.min(possibleBatches, batches) or batches
      end
      local batches = math.min(remaining / outputQuantity, possibleBatches or 0)
      if batches > 0 then
        for index = 1, #inputs, 2 do
          local inputId, inputQuantity = inputs[index], inputs[index + 1]
          stock[inputId] = (stock[inputId] or 0) - inputQuantity * batches
        end
        remaining = remaining - outputQuantity * batches
        if remaining <= 0.000001 then return 0 end
      end
    end
  end
  return remaining
end

function SPP.Inventory:GetRelevantCount(counts)
  local total = 0
  for itemId, quantity in pairs(counts or {}) do
    if SPP_ITEM_DATA[itemId] then total = total + quantity end
  end
  return total
end
