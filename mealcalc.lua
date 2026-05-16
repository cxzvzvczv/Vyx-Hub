if not WYNF_OBFUSCATED then
    WYNF_JIT = function(fn)
        return fn
    end
    WYNF_JIT_MAX = function(fn)
        return fn
    end
    WYNF_SECURE_CALLBACK = function(fn)
        return fn
    end
    WYNF_SECURE_CALL = function(fn)
        return fn
    end
end

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Registry = Shared:WaitForChild("Registry")

local function safeRequire(module)
    local ok, result = pcall(require, module)
    if ok then
        return result
    end
    return {}
end

local MutationRegistry = safeRequire(Registry:WaitForChild("MutationRegistry"))
local TraitRegistry = safeRequire(Registry:WaitForChild("TraitRegistry"))
local CatchableRegistry = safeRequire(Registry:WaitForChild("CatchableRegistry"))
local MealRegistry = safeRequire(Registry:WaitForChild("MealRegistry"))

local WeatherController
pcall(function()
    local Verdant = require(ReplicatedStorage:WaitForChild("Verdant"))
    WeatherController = require(Verdant.Controllers.WeatherController)
end)

local FOOD_TYPES = { "Protein", "Vegetables", "Fruit", "Dairy", "Grain" }
local WEIGHT_CLASSES = {
    { Name = "Tiny", Max = 0.1 },
    { Name = "Normal", Max = 0.789 },
    { Name = "Big", Max = 0.939 },
    { Name = "Huge", Max = 0.969 },
    { Name = "Massive", Max = 0.999 },
    { Name = "Colossal", Max = math.huge },
}
local WEIGHT_MULT = {
    Tiny = 0.75,
    Normal = 1,
    Big = 1.15,
    Huge = 1.3,
    Massive = 1.5,
    Colossal = 2,
}
local RARITY_RANK = {
    Common = 1,
    Uncommon = 2,
    Rare = 3,
    Epic = 4,
    Legendary = 5,
    Mythic = 6,
    Apex = 7,
}
local FORCED_RECIPES = {
    { TemplateId = "Sourdough", Required = { "SourLobster", "BlobDough" } },
}
local CANDIDATE_PROFILE = {
    cap = 40,
    top = 28,
    perId = 10,
    perMutation = 4,
    perWeight = 3,
}
local FOOD_TYPE_COUNT = #FOOD_TYPES
local MEAL_PROFILES = {}
local MUTATION_MULTIPLIERS = {}
local TRAIT_RULES = {
    allMutation = {},
    composition = {},
    duplicateCommon = {},
    ingredient = {},
    ingredientTrait = {},
}

for mutationId, mutation in pairs(MutationRegistry) do
    MUTATION_MULTIPLIERS[mutationId] = (type(mutation) == "table" and mutation.ValueMultiplier) or 1
end

local function ruleLess(a, b)
    return tostring(a.id) < tostring(b.id)
end

local function buildMealProfiles()
    local profiles = {}
    for mealId, template in pairs(MealRegistry) do
        if type(template) == "table" and not template.ForcedOnly then
            local composition = template.Composition or {}
            local total = 0
            local values = {}
            for index = 1, FOOD_TYPE_COUNT do
                local value = composition[FOOD_TYPES[index]] or 0
                values[index] = value
                total += value
            end
            for index = 1, FOOD_TYPE_COUNT do
                values[index] = total > 0 and values[index] / total or 0
            end
            profiles[#profiles + 1] = {
                id = mealId,
                template = template,
                values = values,
            }
        end
    end
    table.sort(profiles, ruleLess)
    return profiles
end

local function buildTraitRules()
    for traitId, trait in pairs(TraitRegistry) do
        local source = type(trait) == "table" and trait.Source
        local sourceType = source and source.Type
        if sourceType == "Composition" and source.Key then
            TRAIT_RULES.composition[#TRAIT_RULES.composition + 1] = {
                id = traitId,
                key = source.Key,
                threshold = source.Threshold or math.huge,
            }
        elseif sourceType == "Ingredient" then
            local required = {}
            for _, id in ipairs(source.Ingredients or {}) do
                required[id] = true
            end
            TRAIT_RULES.ingredient[#TRAIT_RULES.ingredient + 1] = {
                id = traitId,
                required = required,
            }
        elseif sourceType == "DuplicateCommon" then
            TRAIT_RULES.duplicateCommon[#TRAIT_RULES.duplicateCommon + 1] = {
                id = traitId,
            }
        elseif sourceType == "IngredientTrait" and source.Trait then
            TRAIT_RULES.ingredientTrait[#TRAIT_RULES.ingredientTrait + 1] = {
                id = traitId,
                trait = source.Trait,
            }
        elseif sourceType == "AllMutation" and source.Mutation then
            TRAIT_RULES.allMutation[#TRAIT_RULES.allMutation + 1] = {
                id = traitId,
                mutation = source.Mutation,
            }
        end
    end
    for _, list in pairs(TRAIT_RULES) do
        table.sort(list, ruleLess)
    end
end

MEAL_PROFILES = buildMealProfiles()
buildTraitRules()

local function decodeArray(value)
    if type(value) ~= "string" or value == "" then
        return {}
    end
    local ok, decoded = pcall(HttpService.JSONDecode, HttpService, value)
    if ok and type(decoded) == "table" then
        return decoded
    end
    return {}
end

local function pushUnique(list, seen, value)
    if value ~= nil and value ~= "" and not seen[value] then
        seen[value] = true
        list[#list + 1] = value
    end
end

local function comma(value)
    value = tonumber(value) or 0
    local sign = value < 0 and "-" or ""
    local whole = tostring(math.floor(math.abs(value) + 0.5))
    local left, num, right = string.match(whole, "^([^%d]*%d)(%d*)(.-)$")
    return sign .. (left or whole) .. (num or ""):reverse():gsub("(%d%d%d)", "%1,"):reverse() .. (right or "")
end

local function shortNum(value)
    value = tonumber(value) or 0
    local abs = math.abs(value)
    if abs >= 1000000000 then
        return string.format("%.2fB", value / 1000000000)
    elseif abs >= 1000000 then
        return string.format("%.2fM", value / 1000000)
    elseif abs >= 1000 then
        return string.format("%.1fK", value / 1000)
    end
    return comma(value)
end

local function weightClass(actualWeight)
    actualWeight = tonumber(actualWeight) or 0
    for index, class in ipairs(WEIGHT_CLASSES) do
        if actualWeight <= class.Max then
            return class.Name, index, WEIGHT_MULT[class.Name] or 1
        end
    end
    return "Colossal", #WEIGHT_CLASSES, 2
end

local function weatherActive()
    if not WeatherController then
        return false
    end
    local ok, active = pcall(function()
        return WeatherController:IsWeatherActive()
    end)
    return ok and active == true
end

local function scanContainer(container, out)
    if not container then
        return
    end
    for _, tool in ipairs(container:GetChildren()) do
        if tool:IsA("Tool") then
            local itemType = tool:GetAttribute("Type")
            if itemType == "Fish" or itemType == "Ingredient" then
                local id = tool:GetAttribute("Id")
                local baseValue = tonumber(tool:GetAttribute("BaseValue")) or 0
                if id and id ~= "" and baseValue > 0 and not tool:GetAttribute("Locked") then
                    local catch = CatchableRegistry[id] or {}
                    local traits = {}
                    local traitSet = {}
                    for _, trait in ipairs(decodeArray(tool:GetAttribute("Traits"))) do
                        pushUnique(traits, traitSet, trait)
                    end
                    for _, trait in ipairs(decodeArray(tool:GetAttribute("_traits"))) do
                        pushUnique(traits, traitSet, trait)
                    end
                    local mutations = {}
                    local mutationSet = {}
                    for _, mutation in ipairs(decodeArray(tool:GetAttribute("Mutations"))) do
                        pushUnique(mutations, mutationSet, mutation)
                    end
                    pushUnique(mutations, mutationSet, tool:GetAttribute("Mutation"))
                    local actualWeight = tonumber(tool:GetAttribute("ActualWeight")) or 0
                    local className, classIndex, weightMultiplier = weightClass(actualWeight)
                    local rarity = tool:GetAttribute("Rarity") or catch.Rarity or "Common"
                    local composition = catch.Composition or {}
                    local compositionValues = {}
                    for index = 1, FOOD_TYPE_COUNT do
                        compositionValues[index] = composition[FOOD_TYPES[index]] or 0
                    end
                    local primaryMutation = mutations[1]
                    local mutationMultiplier = primaryMutation and (MUTATION_MULTIPLIERS[primaryMutation] or 1) or 1
                    out[#out + 1] = {
                        uid = tool:GetAttribute("_id") or tool:GetDebugId(),
                        id = id,
                        type = itemType,
                        instance = tool,
                        displayName = tool:GetAttribute("DisplayName") or tool.Name,
                        baseValue = baseValue,
                        actualWeight = actualWeight,
                        weightClass = className,
                        weightIndex = classIndex,
                        weightMult = weightMultiplier,
                        rarity = rarity,
                        rarityRank = RARITY_RANK[rarity] or 0,
                        traits = traits,
                        traitSet = traitSet,
                        mutations = mutations,
                        mutationSet = mutationSet,
                        primaryMutation = primaryMutation,
                        primaryMutationMult = mutationMultiplier,
                        compositionValues = compositionValues,
                        traitComposition = catch.TraitComposition or {},
                        power = baseValue * weightMultiplier * mutationMultiplier,
                        spawnChance = catch.SpawnChance,
                    }
                end
            end
        end
    end
end

local function scanInventory()
    local items = {}
    scanContainer(LocalPlayer.Backpack, items)
    scanContainer(LocalPlayer.Character, items)
    table.sort(items, function(a, b)
        if a.baseValue == b.baseValue then
            if a.weightIndex == b.weightIndex then
                return a.uid < b.uid
            end
            return a.weightIndex > b.weightIndex
        end
        return a.baseValue > b.baseValue
    end)
    return items
end

local resolveTemplate = WYNF_JIT_MAX(function(combo)
    for _, recipe in ipairs(FORCED_RECIPES) do
        if #combo == #recipe.Required then
            local counts = {}
            for index = 1, #combo do
                local item = combo[index]
                counts[item.id] = (counts[item.id] or 0) + 1
            end
            local ok = true
            for _, required in ipairs(recipe.Required) do
                if counts[required] ~= 1 then
                    ok = false
                    break
                end
            end
            if ok then
                return recipe.TemplateId, MealRegistry[recipe.TemplateId], 0
            end
        end
    end
    local totals = table.create and table.create(FOOD_TYPE_COUNT, 0) or {}
    local total = 0
    for foodIndex = 1, FOOD_TYPE_COUNT do
        local value = 0
        for itemIndex = 1, #combo do
            value += combo[itemIndex].compositionValues[foodIndex] or 0
        end
        totals[foodIndex] = value
        total += value
    end
    local bestDistance = math.huge
    local bestId
    local bestTemplate
    for profileIndex = 1, #MEAL_PROFILES do
        local profile = MEAL_PROFILES[profileIndex]
        local distance = 0
        for foodIndex = 1, FOOD_TYPE_COUNT do
            local normalized = total > 0 and totals[foodIndex] / total or 0
            distance += math.abs(normalized - profile.values[foodIndex])
        end
        if distance < bestDistance then
            bestDistance = distance
            bestId = profile.id
            bestTemplate = profile.template
        end
    end
    return bestId, bestTemplate, bestDistance
end)

local resolveWeight = WYNF_JIT(function(combo)
    local bestIndex = 1
    for index = 1, #combo do
        local item = combo[index]
        if item.weightIndex > bestIndex then
            bestIndex = item.weightIndex
        end
    end
    local className = WEIGHT_CLASSES[bestIndex].Name
    return className, WEIGHT_MULT[className] or 1
end)

local resolveTraits = WYNF_JIT_MAX(function(combo)
    local out = {}
    local ids = {}
    for index = 1, #combo do
        local item = combo[index]
        ids[item.id] = true
    end
    for ruleIndex = 1, #TRAIT_RULES.composition do
        local rule = TRAIT_RULES.composition[ruleIndex]
        local total = 0
        for itemIndex = 1, #combo do
            total += combo[itemIndex].traitComposition[rule.key] or 0
        end
        if total >= rule.threshold then
            out[#out + 1] = rule.id
        end
    end
    for ruleIndex = 1, #TRAIT_RULES.ingredient do
        local rule = TRAIT_RULES.ingredient[ruleIndex]
        for required in pairs(rule.required) do
            if ids[required] then
                out[#out + 1] = rule.id
                break
            end
        end
    end
    if #TRAIT_RULES.duplicateCommon > 0 then
        local counts = {}
        local found = false
        for itemIndex = 1, #combo do
            local item = combo[itemIndex]
            if item.rarity == "Common" then
                local count = (counts[item.id] or 0) + 1
                counts[item.id] = count
                if count >= 2 then
                    found = true
                    break
                end
            end
        end
        if found then
            for ruleIndex = 1, #TRAIT_RULES.duplicateCommon do
                out[#out + 1] = TRAIT_RULES.duplicateCommon[ruleIndex].id
            end
        end
    end
    for ruleIndex = 1, #TRAIT_RULES.ingredientTrait do
        local rule = TRAIT_RULES.ingredientTrait[ruleIndex]
        for itemIndex = 1, #combo do
            if combo[itemIndex].traitSet[rule.trait] then
                out[#out + 1] = rule.id
                break
            end
        end
    end
    for ruleIndex = 1, #TRAIT_RULES.allMutation do
        local rule = TRAIT_RULES.allMutation[ruleIndex]
        local found = #combo > 0
        for itemIndex = 1, #combo do
            if not combo[itemIndex].mutationSet[rule.mutation] then
                found = false
                break
            end
        end
        if found then
            out[#out + 1] = rule.id
        end
    end
    table.sort(out)
    return out
end)

local mutationChances = WYNF_JIT_MAX(function(combo)
    local counts = {}
    local mutatedItems = 0
    for itemIndex = 1, #combo do
        local item = combo[itemIndex]
        local mutationCount = #item.mutations
        if mutationCount > 0 then
            mutatedItems += 1
        end
        for mutationIndex = 1, mutationCount do
            local mutation = item.mutations[mutationIndex]
            counts[mutation] = (counts[mutation] or 0) + 1
        end
    end
    local unmutated = #combo - mutatedItems
    local total = unmutated
    for _, count in pairs(counts) do
        total += count
    end
    local chances = {}
    if total <= 0 then
        return { { id = nil, chance = 1 } }
    end
    if unmutated > 0 then
        chances[#chances + 1] = { id = nil, chance = unmutated / total }
    end
    for mutation, count in pairs(counts) do
        chances[#chances + 1] = { id = mutation, chance = count / total }
    end
    table.sort(chances, function(a, b)
        if a.chance == b.chance then
            return tostring(a.id or "") < tostring(b.id or "")
        end
        return a.chance > b.chance
    end)
    return chances
end)

local revenueParts = WYNF_JIT(function(traits, activeWeather)
    local interval = 5
    local revenue = 0
    for index = 1, #traits do
        local traitId = traits[index]
        local trait = TraitRegistry[traitId]
        if trait then
            if trait.IntervalMult then
                interval *= trait.IntervalMult
            end
            if trait.Revenue then
                revenue += trait.Revenue
            end
            if trait.WeatherRevenue then
                revenue += activeWeather and (trait.WeatherRevenue.Weather or 0) or (trait.WeatherRevenue.Clear or 0)
            end
        end
    end
    return interval, math.max(0, revenue + 1), activeWeather
end)

local duplicateAndDiversity = WYNF_JIT(function(combo)
    local counts = {}
    for index = 1, #combo do
        local item = combo[index]
        counts[item.id] = (counts[item.id] or 0) + 1
    end
    local duplicatePenalty = 0
    local unique = 0
    for _, count in pairs(counts) do
        unique += 1
        if count > 1 then
            duplicatePenalty += (count - 1) * 0.25
        end
    end
    local duplicateMult = math.max(0, 1 - duplicatePenalty)
    local diversityMult = (#combo <= 1 or unique ~= #combo) and 1 or ((unique - 1) * 0.15 / (#combo - 1) + 1)
    return duplicateMult, diversityMult, unique
end)

local function chanceText(chances)
    local parts = {}
    for _, entry in ipairs(chances) do
        parts[#parts + 1] = (entry.id or "none") .. " " .. string.format("%.0f%%", entry.chance * 100)
    end
    return table.concat(parts, ", ")
end

local scoreCombo = WYNF_JIT_MAX(function(combo, activeWeather)
    local templateId, template = resolveTemplate(combo)
    local weightName, weightMult = resolveWeight(combo)
    local traits = resolveTraits(combo)
    local interval, revenueMult = revenueParts(traits, activeWeather)
    local duplicateMult, diversityMult, uniqueCount = duplicateAndDiversity(combo)
    local baseValue = 0
    local spawnSum = 0
    local bestRarity = "Common"
    local mutationRolls = mutationChances(combo)
    for index = 1, #combo do
        local item = combo[index]
        baseValue += item.baseValue
        if item.rarityRank > (RARITY_RANK[bestRarity] or 0) then
            bestRarity = item.rarity
        end
        if item.spawnChance and item.spawnChance > 0 then
            spawnSum += math.round(1 / item.spawnChance)
        end
    end
    local expectedRpm = 0
    local bestRoll
    for index = 1, #mutationRolls do
        local roll = mutationRolls[index]
        local mutationMult = roll.id and (MUTATION_MULTIPLIERS[roll.id] or 1) or 1
        local finalValue = math.round(baseValue * weightMult * mutationMult * duplicateMult * diversityMult)
        local rpm = finalValue * (60 / interval) * revenueMult
        expectedRpm += rpm * roll.chance
        if not bestRoll or rpm > bestRoll.rpm then
            bestRoll = {
                id = roll.id,
                chance = roll.chance,
                mutationMult = mutationMult,
                finalValue = finalValue,
                rpm = rpm,
            }
        end
    end
    local rarityMult = bestRoll and bestRoll.mutationMult or 1
    for index = 1, #traits do
        local traitId = traits[index]
        local trait = TraitRegistry[traitId]
        if trait and trait.Revenue and trait.Revenue > 0 then
            rarityMult *= 1 + trait.Revenue
        end
    end
    return {
        score = expectedRpm,
        expectedRpm = expectedRpm,
        bestRoll = bestRoll,
        templateId = templateId,
        dish = (template and (template.DisplayName or template.Name)) or templateId or "Unknown",
        weightName = weightName,
        weightMult = weightMult,
        traits = traits,
        interval = interval,
        revenueMult = revenueMult,
        activeWeather = activeWeather,
        duplicateMult = duplicateMult,
        diversityMult = diversityMult,
        uniqueCount = uniqueCount,
        baseValue = baseValue,
        rarity = bestRarity,
        rarityChance = math.max(1, math.round(spawnSum * rarityMult)),
        mutationRolls = mutationRolls,
    }
end)

local function itemPriorityLess(a, b)
    if a.power == b.power then
        if a.baseValue == b.baseValue then
            if a.weightIndex == b.weightIndex then
                return a.uid < b.uid
            end
            return a.weightIndex > b.weightIndex
        end
        return a.baseValue > b.baseValue
    end
    return a.power > b.power
end

local function addCandidate(target, seen, item)
    if item and not seen[item.uid] then
        seen[item.uid] = true
        target[#target + 1] = item
    end
end

local function candidatePool(items)
    if #items <= CANDIDATE_PROFILE.cap then
        return items
    end
    local pool = {}
    local seen = {}
    local byId = {}
    local byMutation = {}
    local byWeight = {}
    for _, item in ipairs(items) do
        byId[item.id] = byId[item.id] or {}
        byId[item.id][#byId[item.id] + 1] = item
        local mutationKey = item.primaryMutation or "None"
        byMutation[item.id .. "|" .. mutationKey] = byMutation[item.id .. "|" .. mutationKey] or {}
        byMutation[item.id .. "|" .. mutationKey][#byMutation[item.id .. "|" .. mutationKey] + 1] = item
        byWeight[item.id .. "|" .. item.weightClass] = byWeight[item.id .. "|" .. item.weightClass] or {}
        byWeight[item.id .. "|" .. item.weightClass][#byWeight[item.id .. "|" .. item.weightClass] + 1] = item
    end
    table.sort(items, itemPriorityLess)
    for i = 1, math.min(CANDIDATE_PROFILE.top, #items) do
        addCandidate(pool, seen, items[i])
    end
    local function takeBuckets(buckets, limit)
        for _, list in pairs(buckets) do
            table.sort(list, itemPriorityLess)
            for i = 1, math.min(limit, #list) do
                addCandidate(pool, seen, list[i])
            end
        end
    end
    takeBuckets(byId, CANDIDATE_PROFILE.perId)
    takeBuckets(byMutation, CANDIDATE_PROFILE.perMutation)
    takeBuckets(byWeight, CANDIDATE_PROFILE.perWeight)
    table.sort(pool, itemPriorityLess)
    while #pool > CANDIDATE_PROFILE.cap do
        table.remove(pool)
    end
    return pool
end

local combinationCount = WYNF_JIT(function(n, minSize, maxSize)
    local total = 0
    for size = minSize, maxSize do
        if n >= size then
            local value = 1
            for i = 1, size do
                value = value * (n - i + 1) / i
            end
            total += value
        end
    end
    return math.floor(total + 0.5)
end)

local function findBest(items, onProgress, exactOnly)
    local candidates = candidatePool(items)
    local minSize = exactOnly and 4 or 1
    local maxSize = math.min(4, #candidates)
    local totalCombos = combinationCount(#candidates, minSize, maxSize)
    local activeWeather = weatherActive()
    local checked = 0
    local best
    local current = {}
    local lastProgress = 0
    local lastYield = os.clock()
    local function visit(startIndex, depth, targetSize)
        if depth > targetSize then
            checked += 1
            local result = scoreCombo(current, activeWeather)
            if not best or result.score > best.score then
                result.combo = table.clone(current)
                best = result
            end
            if onProgress and (checked - lastProgress >= 8192 or checked == totalCombos) then
                onProgress(checked, totalCombos)
                lastProgress = checked
            end
            if checked % 4096 == 0 and os.clock() - lastYield >= 0.025 then
                lastYield = os.clock()
                task.wait()
            end
            return
        end
        local last = #candidates - (targetSize - depth)
        for index = startIndex, last do
            current[depth] = candidates[index]
            visit(index + 1, depth + 1, targetSize)
        end
    end
    for size = minSize, maxSize do
        visit(1, 1, size)
    end
    if best then
        table.sort(best.combo, itemPriorityLess)
    end
    return best, candidates, totalCombos
end

local function getPlot()
    local ok, controller = pcall(function()
        local verdant = require(ReplicatedStorage:WaitForChild("Verdant"))
        return require(verdant.Controllers.PlotController)
    end)
    if ok and controller and controller.Plot then
        return controller.Plot
    end
    local map = workspace:FindFirstChild("Map")
    local plots = map and map:FindFirstChild("Plots")
    if not plots then
        return nil
    end
    for _, plot in ipairs(plots:GetChildren()) do
        local owner = plot:GetAttribute("Owner") or plot:GetAttribute("OwnerId") or plot:GetAttribute("UserId")
        if owner == LocalPlayer.UserId or owner == LocalPlayer.Name or plot:GetAttribute("OwnerName") == LocalPlayer.Name then
            return plot
        end
    end
    return nil
end

local function promptOf(cooker, name)
    local attachment = cooker and cooker:FindFirstChild("Attachment")
    if not attachment then
        return nil
    end
    if name then
        return attachment:FindFirstChild(name)
    end
    return attachment:FindFirstChildWhichIsA("ProximityPrompt")
end

local function promptCookerCFrame(cooker)
    local visuals = cooker and cooker:FindFirstChild("CookerVisuals")
    local water = visuals and visuals:FindFirstChild("CookerWater")
    if water and water:IsA("BasePart") then
        local target = water.Position
        local position = target - water.CFrame.LookVector * 4 + Vector3.new(0, 6, 0)
        return CFrame.lookAt(position, target)
    end
    local attachment = cooker and cooker:FindFirstChild("Attachment")
    if attachment and attachment:IsA("Attachment") then
        local target = attachment.WorldPosition
        local position = target - attachment.WorldCFrame.LookVector * 4 + Vector3.new(0, 5, 0)
        return CFrame.lookAt(position, target)
    end
    if cooker and cooker:IsA("Model") then
        local cf = cooker:GetPivot()
        local target = cf.Position
        local position = target - cf.LookVector * 4 + Vector3.new(0, 6, 0)
        return CFrame.lookAt(position, target)
    end
    return nil
end

local function moveToCooker(cooker)
    local character = LocalPlayer.Character
    local rootPart = character and character:FindFirstChild("HumanoidRootPart")
    local cf = promptCookerCFrame(cooker)
    if rootPart and cf then
        rootPart.CFrame = cf
        task.wait(0.12)
    end
end

local function triggerPrompt(prompt)
    if not prompt or type(fireproximityprompt) ~= "function" then
        return false
    end
    local oldEnabled = prompt.Enabled
    local oldHold = prompt.HoldDuration
    prompt.Enabled = true
    prompt.HoldDuration = 0
    local ok = pcall(function()
        fireproximityprompt(prompt)
    end)
    task.wait(0.18)
    if prompt.Parent then
        prompt.HoldDuration = oldHold
        prompt.Enabled = oldEnabled
    end
    return ok
end

local function waitUntil(timeout, predicate)
    local start = os.clock()
    repeat
        if predicate() then
            return true
        end
        task.wait(0.08)
    until os.clock() - start > timeout
    return false
end

local function equipTool(tool)
    if not tool or not tool.Parent then
        return false
    end
    local character = LocalPlayer.Character
    local humanoid = character and character:FindFirstChildWhichIsA("Humanoid")
    if not humanoid then
        return false
    end
    humanoid:EquipTool(tool)
    return waitUntil(1.5, function()
        return tool.Parent == character
    end)
end

local function reEquipTool(tool)
    local character = LocalPlayer.Character
    local humanoid = character and character:FindFirstChildWhichIsA("Humanoid")
    if not humanoid then
        return false
    end
    humanoid:UnequipTools()
    task.wait(0.08)
    if not tool or not tool.Parent then
        return false
    end
    humanoid:EquipTool(tool)
    return waitUntil(1.2, function()
        return tool.Parent == character
    end)
end

local function currentItemsByUid()
    local out = {}
    for _, item in ipairs(scanInventory()) do
        out[item.uid] = item
    end
    return out
end

local function resolveLiveCombo(result)
    local byUid = currentItemsByUid()
    local combo = {}
    for _, item in ipairs(result.combo or {}) do
        local live = byUid[item.uid]
        if not live or not live.instance or not live.instance.Parent then
            return nil, item.displayName .. " is no longer in inventory"
        end
        if live.instance:GetAttribute("Locked") then
            return nil, live.displayName .. " is locked"
        end
        combo[#combo + 1] = live
    end
    return combo
end

local function getCookers()
    local plot = getPlot()
    local folder = plot and plot:FindFirstChild("Cookers")
    if not folder then
        return {}
    end
    local cookers = folder:GetChildren()
    table.sort(cookers, function(a, b)
        return a.Name < b.Name
    end)
    return cookers
end

local function findReadyCooker()
    for _, cooker in ipairs(getCookers()) do
        if cooker:GetAttribute("Owned") and not cooker:GetAttribute("Locked") then
            local state = cooker:GetAttribute("State") or "Idle"
            if state == "Finished" then
                moveToCooker(cooker)
                triggerPrompt(promptOf(cooker, "CookPrompt"))
                waitUntil(2, function()
                    return (cooker:GetAttribute("State") or "Idle") ~= "Finished"
                end)
            end
            state = cooker:GetAttribute("State") or "Idle"
            if state ~= "Cooking" and state ~= "Finished" and (cooker:GetAttribute("SlotCount") or 0) == 0 then
                return cooker
            end
        end
    end
    return nil
end

local function findCookingOil()
    local function scan(container)
        if not container then
            return nil
        end
        for _, tool in ipairs(container:GetChildren()) do
            if tool:IsA("Tool") and tool:GetAttribute("Id") == "CookingOil" and not tool:GetAttribute("Locked") then
                return tool
            end
        end
        return nil
    end
    return scan(LocalPlayer.Backpack) or scan(LocalPlayer.Character)
end

local function findOilPrompt(cooker)
    local attachment = cooker and cooker:FindFirstChild("Attachment")
    if not attachment then
        return nil
    end
    for _, child in ipairs(attachment:GetChildren()) do
        if child:IsA("ProximityPrompt") and string.find(child.ActionText or "", "Apply", 1, true) then
            return child
        end
    end
    return nil
end

local function cookTimeLeft(cooker)
    local endsAt = cooker and tonumber(cooker:GetAttribute("CookEndsAt")) or 0
    if endsAt <= 0 then
        return math.huge
    end
    return endsAt - os.time()
end

local function applyCookingOil(cooker)
    local remaining = cookTimeLeft(cooker)
    if remaining <= 15 then
        return false, "oil skipped under 15s"
    end
    local oil = findCookingOil()
    if not oil then
        return false, "no cooking oil"
    end
    for attempt = 1, 2 do
        oil = findCookingOil()
        if not oil then
            return false, "no cooking oil"
        end
        if cookTimeLeft(cooker) <= 15 then
            return false, "oil skipped under 15s"
        end
        if not reEquipTool(oil) then
            return false, "could not equip oil"
        end
        moveToCooker(cooker)
        local prompt
        waitUntil(1.25, function()
            prompt = findOilPrompt(cooker)
            return prompt ~= nil
        end)
        if prompt and triggerPrompt(prompt) then
            return true, "oil applied"
        end
        task.wait(0.18)
    end
    return false, "oil prompt failed"
end

local function explain(result)
    local parts = { result.weightName .. " weight" }
    if result.diversityMult > 1 then
        parts[#parts + 1] = "full diversity"
    end
    if result.duplicateMult < 1 then
        parts[#parts + 1] = "duplicate penalty"
    end
    if #result.traits > 0 then
        parts[#parts + 1] = #result.traits .. " traits"
    end
    if result.bestRoll and result.bestRoll.id then
        parts[#parts + 1] = result.bestRoll.id .. " peak"
    end
    return table.concat(parts, ", ")
end

for _, old in ipairs(LocalPlayer.PlayerGui:GetChildren()) do
    if old.Name == "MealOptimizer" then
        old:Destroy()
    end
end

local palette = {
    shell = Color3.fromRGB(11, 12, 14),
    surface = Color3.fromRGB(18, 19, 22),
    surface2 = Color3.fromRGB(24, 26, 30),
    surface3 = Color3.fromRGB(30, 33, 38),
    line = Color3.fromRGB(50, 54, 62),
    line2 = Color3.fromRGB(70, 76, 88),
    text = Color3.fromRGB(241, 242, 244),
    muted = Color3.fromRGB(151, 157, 168),
    faint = Color3.fromRGB(102, 108, 120),
    accent = Color3.fromRGB(222, 172, 92),
    accent2 = Color3.fromRGB(126, 181, 255),
    success = Color3.fromRGB(126, 220, 162),
    danger = Color3.fromRGB(229, 109, 113),
}

local screen = Instance.new("ScreenGui")
screen.Name = "MealOptimizer"
screen.ResetOnSpawn = false
screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screen.Parent = LocalPlayer.PlayerGui

local function corner(parent, radius)
    local value = Instance.new("UICorner")
    value.CornerRadius = UDim.new(0, radius or 10)
    value.Parent = parent
    return value
end

local function stroke(parent, color, thickness, transparency)
    local value = Instance.new("UIStroke")
    value.Color = color or palette.line
    value.Thickness = thickness or 1
    value.Transparency = transparency or 0
    value.Parent = parent
    return value
end

local function gradient(parent, a, b, rotation)
    local value = Instance.new("UIGradient")
    value.Color = ColorSequence.new(a, b)
    value.Rotation = rotation or 90
    value.Parent = parent
    return value
end

local function tween(instance, properties, duration)
    local info = TweenInfo.new(duration or 0.18, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
    local value = TweenService:Create(instance, info, properties)
    value:Play()
    return value
end

local function label(parent, text, size, font, color, xAlign)
    local value = Instance.new("TextLabel")
    value.BackgroundTransparency = 1
    value.Text = text or ""
    value.TextColor3 = color or palette.text
    value.Font = font or Enum.Font.Gotham
    value.TextSize = size or 12
    value.TextXAlignment = xAlign or Enum.TextXAlignment.Left
    value.TextYAlignment = Enum.TextYAlignment.Center
    value.TextTruncate = Enum.TextTruncate.AtEnd
    value.RichText = true
    value.Parent = parent
    return value
end

local function panel(parent, radius)
    local value = Instance.new("Frame")
    value.BackgroundColor3 = palette.surface
    value.BorderSizePixel = 0
    value.Parent = parent
    corner(value, radius or 12)
    stroke(value, palette.line, 1, 0.18)
    gradient(value, palette.surface2, palette.surface, 90)
    return value
end

local function button(parent, text, primary)
    local value = Instance.new("TextButton")
    value.AutoButtonColor = false
    value.BackgroundColor3 = primary and Color3.fromRGB(72, 82, 102) or palette.surface2
    value.BorderSizePixel = 0
    value.Text = text
    value.TextColor3 = palette.text
    value.Font = Enum.Font.GothamMedium
    value.TextSize = 12
    value.Parent = parent
    corner(value, 9)
    local outline = stroke(value, primary and Color3.fromRGB(92, 108, 136) or palette.line, 1, 0.08)
    value.MouseEnter:Connect(function()
        tween(value, { BackgroundColor3 = primary and Color3.fromRGB(84, 96, 120) or palette.surface3 }, 0.14)
        tween(outline, { Transparency = 0 }, 0.14)
    end)
    value.MouseLeave:Connect(function()
        tween(value, { BackgroundColor3 = primary and Color3.fromRGB(72, 82, 102) or palette.surface2 }, 0.16)
        tween(outline, { Transparency = 0.08 }, 0.16)
    end)
    return value
end

local root = Instance.new("Frame")
root.Name = "Root"
root.AnchorPoint = Vector2.new(0.5, 0.5)
root.Position = UDim2.new(0.5, 0, 0.5, 0)
root.Size = UDim2.new(0, 700, 0, 616)
root.BackgroundColor3 = palette.shell
root.BorderSizePixel = 0
root.Parent = screen
corner(root, 18)
stroke(root, Color3.fromRGB(54, 58, 66), 1, 0.05)
gradient(root, Color3.fromRGB(21, 23, 27), Color3.fromRGB(10, 11, 13), 90)

local scale = Instance.new("UIScale")
scale.Parent = root

local camera = workspace.CurrentCamera
local function updateScale()
    local viewport = camera and camera.ViewportSize or Vector2.new(1280, 720)
    scale.Scale = math.clamp(math.min((viewport.X - 36) / 700, (viewport.Y - 36) / 616), 0.62, 1)
end
updateScale()
if camera then
    camera:GetPropertyChangedSignal("ViewportSize"):Connect(updateScale)
end

local header = Instance.new("Frame")
header.Name = "Header"
header.BackgroundTransparency = 1
header.Position = UDim2.new(0, 24, 0, 20)
header.Size = UDim2.new(1, -48, 0, 54)
header.Active = true
header.Parent = root

local dragging = false
local dragInput
local dragStart
local dragPosition

local function updateDrag(input)
    local delta = input.Position - dragStart
    root.Position = UDim2.new(dragPosition.X.Scale, dragPosition.X.Offset + delta.X, dragPosition.Y.Scale, dragPosition.Y.Offset + delta.Y)
end

local function bindDrag(handle)
    handle.Active = true
    handle.InputBegan:Connect(function(input)
        if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then
            return
        end
        dragging = true
        dragStart = input.Position
        dragPosition = root.Position
        input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End then
                dragging = false
            end
        end)
    end)
    handle.InputChanged:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
            dragInput = input
        end
    end)
end

UserInputService.InputChanged:Connect(function(input)
    if dragging and input == dragInput then
        updateDrag(input)
    end
end)

bindDrag(header)

local title = label(header, "Meal Optimizer", 18, Enum.Font.GothamBold, palette.text)
title.Position = UDim2.new(0, 0, 0, 2)
title.Size = UDim2.new(0, 300, 0, 24)
bindDrag(title)

local subtitle = label(header, "inventory scan, ranked by expected meal output", 11, Enum.Font.Gotham, palette.muted)
subtitle.Position = UDim2.new(0, 0, 0, 29)
subtitle.Size = UDim2.new(0, 330, 0, 18)
bindDrag(subtitle)

local close = button(header, "Close", false)
close.AnchorPoint = Vector2.new(1, 0)
close.Position = UDim2.new(1, 0, 0, 8)
close.Size = UDim2.new(0, 74, 0, 36)
close.MouseButton1Click:Connect(function()
    tween(root, { BackgroundTransparency = 1 }, 0.16)
    task.wait(0.16)
    screen:Destroy()
end)

local runButton = button(header, "Refresh", true)
runButton.AnchorPoint = Vector2.new(1, 0)
runButton.Position = UDim2.new(1, -84, 0, 8)
runButton.Size = UDim2.new(0, 92, 0, 36)

local modeButton = button(header, "Best 1-4", false)
modeButton.AnchorPoint = Vector2.new(1, 0)
modeButton.Position = UDim2.new(1, -186, 0, 8)
modeButton.Size = UDim2.new(0, 94, 0, 36)

local progressTrack = Instance.new("Frame")
progressTrack.BackgroundColor3 = Color3.fromRGB(33, 35, 39)
progressTrack.BorderSizePixel = 0
progressTrack.Position = UDim2.new(0, 24, 0, 88)
progressTrack.Size = UDim2.new(1, -48, 0, 3)
progressTrack.Parent = root
corner(progressTrack, 2)

local progressFill = Instance.new("Frame")
progressFill.BackgroundColor3 = palette.accent
progressFill.BorderSizePixel = 0
progressFill.Size = UDim2.new(0, 0, 1, 0)
progressFill.Parent = progressTrack
corner(progressFill, 2)
gradient(progressFill, palette.accent, Color3.fromRGB(246, 210, 137), 0)

local status = label(root, "Ready", 11, Enum.Font.Gotham, palette.muted)
status.Position = UDim2.new(0, 24, 0, 96)
status.Size = UDim2.new(1, -48, 0, 18)

local hero = panel(root, 16)
hero.Position = UDim2.new(0, 24, 0, 126)
hero.Size = UDim2.new(0, 300, 0, 174)

local heroKicker = label(hero, "EXPECTED OUTPUT", 10, Enum.Font.GothamMedium, palette.muted)
heroKicker.Position = UDim2.new(0, 18, 0, 16)
heroKicker.Size = UDim2.new(1, -36, 0, 16)

local expectedValue = label(hero, "-", 32, Enum.Font.GothamBold, palette.success)
expectedValue.Position = UDim2.new(0, 18, 0, 42)
expectedValue.Size = UDim2.new(1, -36, 0, 42)

local dishValue = label(hero, "No result yet", 13, Enum.Font.GothamMedium, palette.text)
dishValue.Position = UDim2.new(0, 18, 0, 91)
dishValue.Size = UDim2.new(1, -36, 0, 22)

local whyValue = label(hero, "Run a scan to rank your inventory.", 11, Enum.Font.Gotham, palette.muted)
whyValue.Position = UDim2.new(0, 18, 0, 118)
whyValue.Size = UDim2.new(1, -36, 0, 38)
whyValue.TextWrapped = true
whyValue.TextYAlignment = Enum.TextYAlignment.Top

local metrics = Instance.new("Frame")
metrics.BackgroundTransparency = 1
metrics.Position = UDim2.new(0, 336, 0, 126)
metrics.Size = UDim2.new(1, -360, 0, 174)
metrics.Parent = root

local metricGrid = Instance.new("UIGridLayout")
metricGrid.CellPadding = UDim2.new(0, 10, 0, 10)
metricGrid.CellSize = UDim2.new(0.5, -5, 0, 82)
metricGrid.SortOrder = Enum.SortOrder.LayoutOrder
metricGrid.Parent = metrics

local function metric(labelText)
    local card = panel(metrics, 14)
    local l = label(card, labelText, 10, Enum.Font.GothamMedium, palette.muted)
    l.Position = UDim2.new(0, 14, 0, 10)
    l.Size = UDim2.new(1, -28, 0, 16)
    local v = label(card, "-", 19, Enum.Font.GothamBold, palette.text)
    v.Position = UDim2.new(0, 14, 0, 35)
    v.Size = UDim2.new(1, -28, 0, 26)
    local s = label(card, "", 10, Enum.Font.Gotham, palette.faint)
    s.Position = UDim2.new(0, 14, 0, 62)
    s.Size = UDim2.new(1, -28, 0, 16)
    return v, s
end

local peakValue, peakSub = metric("PEAK ROLL")
local searchValue, searchSub = metric("SEARCH")
local sellValue, sellSub = metric("SELL VALUE")
local clockValue, clockSub = metric("INCOME CLOCK")

local detail = panel(root, 15)
detail.Position = UDim2.new(0, 24, 0, 314)
detail.Size = UDim2.new(1, -48, 0, 122)

local detailRows = {}
local function detailItem(key, y, height)
    local k = label(detail, key, 10, Enum.Font.GothamMedium, palette.muted)
    k.Position = UDim2.new(0, 18, 0, y)
    k.Size = UDim2.new(0, 108, 0, height)
    local v = label(detail, "-", 12, Enum.Font.Gotham, palette.text)
    v.Position = UDim2.new(0, 132, 0, y)
    v.Size = UDim2.new(1, -150, 0, height)
    v.TextWrapped = true
    v.TextTruncate = Enum.TextTruncate.None
    v.TextYAlignment = Enum.TextYAlignment.Center
    detailRows[key] = v
end

detailItem("Multipliers", 12, 18)
detailItem("Mutation odds", 38, 18)
detailItem("Traits", 64, 32)
detailItem("Rarity", 98, 16)

local tablePanel = panel(root, 15)
tablePanel.Position = UDim2.new(0, 24, 0, 444)
tablePanel.Size = UDim2.new(1, -48, 0, 148)

local tableTitle = label(tablePanel, "Selected ingredients", 12, Enum.Font.GothamBold, palette.text)
tableTitle.Position = UDim2.new(0, 16, 0, 10)
tableTitle.Size = UDim2.new(0, 230, 0, 18)

local tableSummary = label(tablePanel, "-", 10, Enum.Font.Gotham, palette.faint)
tableSummary.Position = UDim2.new(0, 154, 0, 10)
tableSummary.Size = UDim2.new(1, -284, 0, 18)

local cookButton = button(tablePanel, "Auto Cook", true)
cookButton.AnchorPoint = Vector2.new(1, 0)
cookButton.Position = UDim2.new(1, -18, 0, 8)
cookButton.Size = UDim2.new(0, 108, 0, 28)
cookButton.TextSize = 11

local function columnHeader(text, x, width, align)
    local h = label(tablePanel, text, 9, Enum.Font.GothamMedium, palette.faint, align or Enum.TextXAlignment.Left)
    h.Position = UDim2.new(0, x, 0, 42)
    h.Size = UDim2.new(0, width, 0, 14)
    return h
end

columnHeader("#", 19, 22, Enum.TextXAlignment.Center)
columnHeader("Ingredient", 48, 196)
columnHeader("Base", 256, 70, Enum.TextXAlignment.Right)
columnHeader("Weight", 342, 78)
columnHeader("Mutation", 432, 88)
columnHeader("Traits", 532, 96)

local rows = {}
for i = 1, 4 do
    local row = Instance.new("Frame")
    row.BackgroundColor3 = i % 2 == 1 and palette.surface2 or Color3.fromRGB(22, 24, 28)
    row.BorderSizePixel = 0
    row.Position = UDim2.new(0, 16, 0, 60 + (i - 1) * 21)
    row.Size = UDim2.new(1, -32, 0, 19)
    row.Parent = tablePanel
    corner(row, 7)
    stroke(row, palette.line, 1, 0.58)
    local slot = label(row, tostring(i), 10, Enum.Font.GothamMedium, palette.faint, Enum.TextXAlignment.Center)
    slot.Position = UDim2.new(0, 0, 0, 0)
    slot.Size = UDim2.new(0, 26, 1, 0)
    local name = label(row, "-", 11, Enum.Font.GothamMedium, palette.text)
    name.Position = UDim2.new(0, 32, 0, 0)
    name.Size = UDim2.new(0, 196, 1, 0)
    local base = label(row, "-", 10, Enum.Font.Gotham, palette.text, Enum.TextXAlignment.Right)
    base.Position = UDim2.new(0, 238, 0, 0)
    base.Size = UDim2.new(0, 72, 1, 0)
    local weight = label(row, "-", 10, Enum.Font.Gotham, palette.muted)
    weight.Position = UDim2.new(0, 326, 0, 0)
    weight.Size = UDim2.new(0, 82, 1, 0)
    local mutation = label(row, "-", 10, Enum.Font.Gotham, palette.accent2)
    mutation.Position = UDim2.new(0, 420, 0, 0)
    mutation.Size = UDim2.new(0, 96, 1, 0)
    local traits = label(row, "-", 10, Enum.Font.Gotham, palette.muted)
    traits.Position = UDim2.new(0, 528, 0, 0)
    traits.Size = UDim2.new(1, -536, 1, 0)
    rows[i] = { name = name, base = base, weight = weight, mutation = mutation, traits = traits }
end

local exactFour = false
local running = false
local cooking = false
local lastResult

local function setStatus(text, progress)
    status.Text = text
    if progress then
        tween(progressFill, { Size = UDim2.new(math.clamp(progress, 0, 1), 0, 1, 0) }, 0.14)
    end
end

local function setDetail(key, value)
    if detailRows[key] then
        detailRows[key].Text = value
    end
end

local function renderEmpty(message)
    lastResult = nil
    expectedValue.Text = "-"
    dishValue.Text = "No meal selected"
    whyValue.Text = message or "Scan your inventory to find the best meal."
    peakValue.Text = "-"
    peakSub.Text = ""
    searchValue.Text = "-"
    searchSub.Text = ""
    sellValue.Text = "-"
    sellSub.Text = ""
    clockValue.Text = "-"
    clockSub.Text = ""
    setDetail("Multipliers", "-")
    setDetail("Mutation odds", "-")
    setDetail("Traits", "-")
    setDetail("Rarity", "-")
    tableSummary.Text = "waiting for scan"
    for _, row in ipairs(rows) do
        row.name.Text = "-"
        row.base.Text = "-"
        row.weight.Text = "-"
        row.mutation.Text = "-"
        row.traits.Text = "-"
    end
end

local function renderResult(result, inventoryCount, candidateCount, comboCount)
    lastResult = result
    expectedValue.Text = shortNum(result.expectedRpm) .. "/m"
    dishValue.Text = result.dish .. "  |  " .. result.weightName .. "  |  " .. result.rarity
    whyValue.Text = explain(result)
    peakValue.Text = shortNum(result.bestRoll.rpm) .. "/m"
    peakSub.Text = (result.bestRoll.id or "No mutation") .. " " .. string.format("%.0f%%", result.bestRoll.chance * 100)
    searchValue.Text = tostring(inventoryCount)
    searchSub.Text = candidateCount .. " kept, " .. shortNum(comboCount) .. " tested"
    sellValue.Text = comma(result.bestRoll.finalValue)
    sellSub.Text = comma(result.baseValue) .. " base"
    clockValue.Text = string.format("%.2fs", result.interval)
    clockSub.Text = "revenue x" .. string.format("%.2f", result.revenueMult)
    setDetail("Multipliers", "w x" .. string.format("%.2f", result.weightMult) .. "  dup x" .. string.format("%.2f", result.duplicateMult) .. "  div x" .. string.format("%.2f", result.diversityMult))
    setDetail("Mutation odds", chanceText(result.mutationRolls))
    setDetail("Traits", #result.traits > 0 and table.concat(result.traits, ", ") or "none")
    setDetail("Rarity", "1 in " .. comma(result.rarityChance))
    tableSummary.Text = #result.combo .. " items  |  " .. (findCookingOil() and "oil ready" or "no oil") .. "  |  " .. (result.activeWeather and "weather" or "clear")
    for i, row in ipairs(rows) do
        local item = result.combo[i]
        if item then
            local mutationText = item.primaryMutation or "none"
            if #item.mutations > 1 then
                mutationText = mutationText .. " +" .. tostring(#item.mutations - 1)
            end
            row.name.Text = item.displayName .. "  |  " .. item.rarity
            row.base.Text = shortNum(item.baseValue)
            row.weight.Text = item.weightClass .. " x" .. string.format("%.2f", item.weightMult)
            row.mutation.Text = mutationText
            row.traits.Text = #item.traits > 0 and table.concat(item.traits, ", ") or "none"
        else
            row.name.Text = "-"
            row.base.Text = "-"
            row.weight.Text = "-"
            row.mutation.Text = "-"
            row.traits.Text = "-"
        end
    end
    setStatus("Updated", 1)
end

local function autoCookBest()
    if cooking then
        return
    end
    cooking = true
    cookButton.Text = "Cooking"
    setStatus("Preparing cook", 0.08)
    task.defer(function()
        local result = lastResult
        if not result then
            local items = scanInventory()
            if #items == 0 then
                setStatus("No ingredients to cook", 0)
                cookButton.Text = "Auto Cook"
                cooking = false
                return
            end
            local candidates, totalCombos
            result, candidates, totalCombos = findBest(items, function(checked, total)
                setStatus("Picking recipe " .. math.floor(checked / math.max(total, 1) * 100) .. "%", 0.08 + checked / math.max(total, 1) * 0.35)
            end, exactFour)
            if not result then
                setStatus("No valid recipe found", 0)
                cookButton.Text = "Auto Cook"
                cooking = false
                return
            end
            renderResult(result, #items, #(candidates or {}), totalCombos or 0)
        end

        local combo, reason = resolveLiveCombo(result)
        if not combo then
            setStatus(reason or "Recipe changed, refresh first", 0)
            cookButton.Text = "Auto Cook"
            cooking = false
            return
        end

        local cooker = findReadyCooker()
        if not cooker then
            setStatus("No empty cooker ready", 0)
            cookButton.Text = "Auto Cook"
            cooking = false
            return
        end

        moveToCooker(cooker)
        for index, item in ipairs(combo) do
            setStatus("Adding " .. item.displayName, 0.18 + index * 0.1)
            if not equipTool(item.instance) then
                setStatus("Could not equip " .. item.displayName, 0)
                cookButton.Text = "Auto Cook"
                cooking = false
                return
            end
            moveToCooker(cooker)
            if not triggerPrompt(promptOf(cooker)) then
                setStatus("Could not add ingredient", 0)
                cookButton.Text = "Auto Cook"
                cooking = false
                return
            end
            if not waitUntil(2.5, function()
                return (cooker:GetAttribute("SlotCount") or 0) >= index
            end) then
                setStatus("Cooker did not accept item", 0)
                cookButton.Text = "Auto Cook"
                cooking = false
                return
            end
        end

        setStatus("Starting cooker", 0.72)
        moveToCooker(cooker)
        if not triggerPrompt(promptOf(cooker, "CookPrompt")) then
            setStatus("Could not start cooking", 0)
            cookButton.Text = "Auto Cook"
            cooking = false
            return
        end
        if not waitUntil(3, function()
            return (cooker:GetAttribute("State") or "Idle") == "Cooking" or (cooker:GetAttribute("State") or "Idle") == "Finished"
        end) then
            setStatus("Cooking did not start", 0)
            cookButton.Text = "Auto Cook"
            cooking = false
            return
        end

        setStatus("Applying cooking oil", 0.86)
        local oilOk, oilMessage = applyCookingOil(cooker)
        if oilOk then
            setStatus("Cooking started, oil applied", 1)
        else
            setStatus("Cooking started, " .. oilMessage, 1)
        end
        cookButton.Text = "Auto Cook"
        cooking = false
    end)
end

local function run()
    if running then
        return
    end
    running = true
    runButton.Text = "Scanning"
    setStatus("Scanning inventory", 0.08)
    task.defer(function()
        local items = scanInventory()
        if #items == 0 then
            renderEmpty("No fish or ingredients found.")
            runButton.Text = "Refresh"
            running = false
            setStatus("No inventory items found", 0)
            return
        end
        setStatus("Optimizing", 0.18)
        local best, candidates, totalCombos = findBest(items, function(checked, total)
            setStatus("Optimizing " .. math.floor(checked / math.max(total, 1) * 100) .. "%", 0.18 + checked / math.max(total, 1) * 0.76)
        end, exactFour)
        if best then
            renderResult(best, #items, #candidates, totalCombos)
        else
            renderEmpty("No valid meal combination found.")
            setStatus("No valid meal", 0)
        end
        runButton.Text = "Refresh"
        running = false
    end)
end

runButton.MouseButton1Click:Connect(run)
cookButton.MouseButton1Click:Connect(autoCookBest)
modeButton.MouseButton1Click:Connect(function()
    exactFour = not exactFour
    modeButton.Text = exactFour and "Exact 4" or "Best 1-4"
    run()
end)

renderEmpty()
task.defer(run)
