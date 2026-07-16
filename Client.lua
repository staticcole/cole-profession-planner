SPP.Client = SPP.Client or {}

local PROFESSION_IDS = {
  [171] = "alchemy", [164] = "blacksmithing", [185] = "cooking", [333] = "enchanting",
  [202] = "engineering", [129] = "first-aid", [755] = "jewelcrafting",
  [165] = "leatherworking", [186] = "mining", [197] = "tailoring"
}

local FALLBACK_NAMES = {
  alchemy = "Alchemy", blacksmithing = "Blacksmithing", cooking = "Cooking",
  enchanting = "Enchanting", engineering = "Engineering", ["first-aid"] = "First Aid",
  jewelcrafting = "Jewelcrafting", leatherworking = "Leatherworking", mining = "Mining",
  tailoring = "Tailoring"
}

local ANNIVERSARY_INTERFACE_PHASES = {
  [20505] = 1,
  [20506] = 2
}

local ANNIVERSARY_PHASE_STARTS = {
  { phase = 2, timestamp = 1778796060 } -- 2026-05-14 22:01 UTC
}

local function getCurrentTime()
  local serverTime = GetServerTime and GetServerTime() or nil
  if serverTime and serverTime > 0 then return serverTime end
  return time and time() or 0
end

local function getAnniversaryPhase(interface)
  local phase = ANNIVERSARY_INTERFACE_PHASES[interface] or 1
  local basis = ANNIVERSARY_INTERFACE_PHASES[interface] and "Anniversary client build" or "Anniversary release calendar"
  local currentTime = getCurrentTime()
  for _, release in ipairs(ANNIVERSARY_PHASE_STARTS) do
    if currentTime >= release.timestamp and release.phase > phase then
      phase = release.phase
      basis = "Anniversary release calendar"
    end
  end
  return phase, basis
end

function SPP.Client:Detect()
  local version, build, buildDate, interface = GetBuildInfo()
  local season = C_Seasons and C_Seasons.GetActiveSeason and C_Seasons.GetActiveSeason() or nil
  local expansion = WOW_PROJECT_ID == WOW_PROJECT_BURNING_CRUSADE_CLASSIC and 2 or 1
  local phase = expansion == 2 and 5 or 6
  local phaseBasis = "client family default"

  local isTbcAnniversaryBuild = expansion == 2 and interface and interface >= 20505 and interface < 20600
  local isAnniversary = season == 11 or isTbcAnniversaryBuild
  if isAnniversary then
    if expansion == 2 then
      phase, phaseBasis = getAnniversaryPhase(interface)
    else
      phase = 6
      phaseBasis = "Anniversary client family"
    end
  end
  if ColeProfessionPlannerDB and ColeProfessionPlannerDB.phaseOverride then
    phase = ColeProfessionPlannerDB.phaseOverride
    phaseBasis = "manual override"
  end

  self.info = {
    version = version, build = build, buildDate = buildDate, interface = interface,
    projectId = WOW_PROJECT_ID, seasonId = season, expansion = expansion, phase = phase,
    phaseBasis = phaseBasis, maxSkill = expansion == 2 and 375 or 300,
    label = expansion == 2 and (isAnniversary and "TBC Anniversary" or "Burning Crusade Classic") or "Classic"
  }
  return self.info
end

function SPP.Client:GetInfo()
  return self.info or self:Detect()
end

function SPP.Client:GetDefaultPhase(expansion)
  local info = self:GetInfo()
  if expansion == info.expansion then return info.phase end
  return expansion == 1 and 6 or expansion == 2 and 5 or 4
end

function SPP.Client:GetProfessions()
  local result = {}
  if GetProfessions and GetProfessionInfo then
    local indices = { GetProfessions() }
    for position = 1, 6 do
      local index = indices[position]
      if index then
        local name, icon, rank, maxRank, _, _, skillLineId = GetProfessionInfo(index)
        local key = PROFESSION_IDS[skillLineId]
        if key then result[key] = { name = name, icon = icon, rank = rank or 0, maxRank = maxRank or 0, skillLineId = skillLineId } end
      end
    end
  end
  if not next(result) and GetNumSkillLines and GetSkillLineInfo then
    local byName = {}
    for key, name in pairs(FALLBACK_NAMES) do byName[name:lower()] = key end
    for index = 1, GetNumSkillLines() do
      local name, isHeader, _, rank, _, _, maxRank = GetSkillLineInfo(index)
      local key = name and byName[name:lower()]
      if key and not isHeader then result[key] = { name = name, rank = rank or 0, maxRank = maxRank or 0 } end
    end
  end
  return result
end

local function characterIdentity()
  local name = UnitName and UnitName("player") or nil
  local realm = GetNormalizedRealmName and GetNormalizedRealmName()
    or GetRealmName and GetRealmName():gsub("[%s%-]", "") or nil
  local faction = UnitFactionGroup and UnitFactionGroup("player") or nil
  return name, realm, faction
end

local function connectedRealms(realm)
  local realms = {}
  if realm then realms[realm] = true end
  if GetAutoCompleteRealms then
    for _, connectedRealm in ipairs({ GetAutoCompleteRealms() }) do realms[connectedRealm] = true end
  end
  return realms
end

function SPP.Client:RecordCharacterProfessions()
  if not ColeProfessionPlannerDB then return false end
  local name, realm, faction = characterIdentity()
  if not name or not realm then return false end
  ColeProfessionPlannerDB.characterProfessions = ColeProfessionPlannerDB.characterProfessions or {}
  local professions = {}
  for key, details in pairs(self:GetProfessions()) do
    professions[key] = { rank = details.rank or 0, maxRank = details.maxRank or 0 }
  end
  ColeProfessionPlannerDB.characterProfessions[name .. "-" .. realm] = {
    name = name, realm = realm, faction = faction, professions = professions,
    updatedAt = getCurrentTime()
  }
  return true
end

function SPP.Client:GetAvailableProfessions()
  local available = {}
  for key in pairs(self:GetProfessions()) do available[key] = true end
  local _, realm, faction = characterIdentity()
  local realms = connectedRealms(realm)
  for _, character in pairs(ColeProfessionPlannerDB and ColeProfessionPlannerDB.characterProfessions or {}) do
    if realms[character.realm] and (not faction or not character.faction or character.faction == faction) then
      for key in pairs(character.professions or {}) do available[key] = true end
    end
  end
  return available
end

function SPP.Client:HasAvailableProfession(profession)
  return self:GetAvailableProfessions()[profession] == true
end

function SPP.Client:GetProfessionChoices()
  local known = self:GetProfessions()
  local choices = {}
  for _, key in ipairs(SPP.Data:GetProfessionNames()) do
    local profession = known[key]
    local label = profession and string.format("%s  (%d/%d)", profession.name, profession.rank, profession.maxRank)
      or (FALLBACK_NAMES[key] or key:gsub("^%l", string.upper))
    table.insert(choices, { value = key, label = label, known = profession ~= nil, rank = profession and profession.rank or 0 })
  end
  table.sort(choices, function(a, b)
    if a.known ~= b.known then return a.known end
    if a.rank ~= b.rank then return a.rank > b.rank end
    return a.label < b.label
  end)
  return choices, known
end
