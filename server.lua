-- JG-Crafting/server.lua (cleaned + safer + auto usable benches)
local QBCore = exports['qb-core']:GetCoreObject()

-- ======================
-- RESOURCE HELPERS
-- ======================
local function HasRes(res) return GetResourceState(res) == 'started' end

-- ======================
-- DISCORD WEBHOOK LOGS
-- ======================
local function Safe(v)
    if v == nil then return "N/A" end
    local s = tostring(v)
    if s == "" then return "N/A" end
    return s
end

local function GetDiscordWebhook(kind)
    if not Config.Webhooks or Config.Webhooks.enabled ~= true then return nil end
    return Config.Webhooks.urls and Config.Webhooks.urls[kind] or nil
end

local function WebhookColor(kind)
    if not Config.Webhooks or not Config.Webhooks.color then return 0 end
    return tonumber(Config.Webhooks.color[kind]) or 0
end

local function SendDiscordWebhook(kind, title, fields)
    local url = GetDiscordWebhook(kind)
    if not url or url == "" then return end

    local embed = {
        title = title,
        color = WebhookColor(kind),
        fields = fields or {},
        footer = { text = os.date("Crafting Bench • %Y-%m-%d %H:%M:%S") }
    }

    local payload = {
        username = (Config.Webhooks and Config.Webhooks.botName) or "Crafting Bench Logs",
        avatar_url = (Config.Webhooks and Config.Webhooks.botAvatar) or nil,
        embeds = { embed }
    }

    PerformHttpRequest(url, function() end, 'POST', json.encode(payload), { ['Content-Type'] = 'application/json' })
end

local function PlayerFields(src, Player)
    local name = GetPlayerName(src) or "Unknown"
    local cid = (Player and Player.PlayerData and Player.PlayerData.citizenid) or "Unknown"
    return {
        { name = "Player", value = ("%s (%s)"):format(name, src), inline = true },
        { name = "CitizenID", value = Safe(cid), inline = true }
    }
end

local function BenchFields(benchType, id, coords, heading, job, minGrade, gang, gangGrade, restrictItem, restrictAmount)
    local c = coords or {}
    local xyz = ("x=%.2f, y=%.2f, z=%.2f"):format(tonumber(c.x) or 0.0, tonumber(c.y) or 0.0, tonumber(c.z) or 0.0)
    return {
        { name = "Bench Type", value = Safe(benchType), inline = true },
        { name = "Bench ID", value = Safe(id), inline = true },
        { name = "Coords", value = xyz, inline = false },
        { name = "Heading", value = Safe(heading), inline = true },
        { name = "Access (Job)", value = ("%s | min grade: %s"):format(Safe(job), Safe(minGrade)), inline = false },
        { name = "Access (Gang)", value = ("%s | min grade: %s"):format(Safe(gang), Safe(gangGrade)), inline = false },
        { name = "Item Restriction", value = ("%s x%s"):format(Safe(restrictItem), Safe(restrictAmount)), inline = false }
    }
end

-- ======================
-- SYSTEM / INVENTORY
-- ======================
local function UsingOxInventory()
    local pref = (Config.Systems and Config.Systems.Inventory) or 'auto'
    pref = tostring(pref):lower()

    if pref == 'ox' then return true end
    if pref == 'qb' then return false end
    return HasRes('ox_inventory')
end

local function NormalizeCount(result)
    if type(result) == 'number' then return result end
    if type(result) == 'string' then return tonumber(result) or 0 end

    if type(result) == 'table' then
        local total = 0
        for _, v in pairs(result) do
            if type(v) == 'number' then
                total = total + v
            elseif type(v) == 'table' then
                total = total + (tonumber(v.count) or tonumber(v.amount) or 0)
            end
        end
        return total
    end

    return 0
end

local function GetItemCount(src, Player, item)
    if UsingOxInventory() then
        local result = exports.ox_inventory:Search(src, 'count', item)
        return NormalizeCount(result)
    end

    local it = Player.Functions.GetItemByName(item)
    return (it and tonumber(it.amount)) or 0
end

local function NormalizeOxSuccess(ret)
    if type(ret) == 'boolean' then return ret end
    if type(ret) == 'number' then return ret > 0 end
    if type(ret) == 'table' then return true end
    return ret ~= nil
end

local function RemoveItem(src, Player, item, amount)
    amount = tonumber(amount) or 0
    if amount <= 0 then return false end

    if UsingOxInventory() then
        local ok = exports.ox_inventory:RemoveItem(src, item, amount)
        return NormalizeOxSuccess(ok)
    end

    return Player.Functions.RemoveItem(item, amount)
end

local function AddItem(src, Player, item, amount)
    amount = tonumber(amount) or 0
    if amount <= 0 then return false end

    if UsingOxInventory() then
        local ok = exports.ox_inventory:AddItem(src, item, amount)
        return NormalizeOxSuccess(ok)
    end

    return Player.Functions.AddItem(item, amount)
end

-- ======================
-- AUTO-RETURNS: FIND CRAFT RECIPE
-- ======================
local function FindCraftRecipe(itemName)
    for benchType, bench in pairs(Config.BenchTypes or {}) do
        if bench and bench.mode ~= 'dismantle' then
            for _, it in pairs(bench.items or {}) do
                if it and it.name == itemName and type(it.requires) == 'table' then
                    local craftOut = tonumber(it.amount) or 1
                    if craftOut < 1 then craftOut = 1 end
                    return it.requires, craftOut, benchType
                end
            end
        end
    end
    return nil
end

-- ======================
-- ADMIN CHECK
-- ======================
local function IsAdmin(src)
    if QBCore.Functions.HasPermission
        and (QBCore.Functions.HasPermission(src, 'admin') or QBCore.Functions.HasPermission(src, 'god')) then
        return true
    end

    if HasRes('qbx_core') then
        local ok, group = pcall(function()
            return exports.qbx_core:GetGroup(src)
        end)
        if ok and group and (group == 'admin' or group == 'god') then
            return true
        end
    end

    return false
end

RegisterNetEvent('JG-Crafting:server:CheckAdmin', function()
    local src = source
    TriggerClientEvent('JG-Crafting:client:SetAdmin', src, IsAdmin(src))
end)

-- ======================
-- USABLE BENCH ITEMS (AUTO FROM CONFIG)
-- ======================
local function GetBenchItemName(benchDef)
    if benchDef and benchDef.item and benchDef.item ~= '' then
        return benchDef.item
    end
    if benchDef and benchDef.placeItem and benchDef.placeItem ~= '' then
        return benchDef.placeItem
    end
    return nil
end

local function RegisterBenchUsables()
    if not Config.BenchTypes then return end

    local registered = {}
    for benchType, benchDef in pairs(Config.BenchTypes) do
        local itemName = GetBenchItemName(benchDef)

        if itemName and not registered[itemName] then
            registered[itemName] = true

            QBCore.Functions.CreateUseableItem(itemName, function(src)
                if not IsAdmin(src) then
                    TriggerClientEvent('QBCore:Notify', src, 'Only admins can place benches', 'error')
                    return
                end
                TriggerClientEvent('JG-Crafting:client:PlaceBench', src, benchType)
            end)
        end
    end
end

CreateThread(function()
    Wait(0)
    RegisterBenchUsables()
end)

-- ======================
-- LOAD BENCHES
-- ======================
QBCore.Functions.CreateCallback('JG-Crafting:server:GetBenches', function(_, cb)
    local rows = exports.oxmysql:querySync('SELECT * FROM crafting_benches') or {}
    cb(rows)
end)

-- ======================
-- BENCH MANAGEMENT (ADMIN)
-- ======================
RegisterNetEvent('JG-Crafting:server:UpdateBench', function(id, coords, heading)
    local src = source
    if not IsAdmin(src) then return end
    if not id or not coords then return end

    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end

    local old = exports.oxmysql:singleSync('SELECT * FROM crafting_benches WHERE id = ?', { id })

    exports.oxmysql:execute(
        'UPDATE crafting_benches SET x = ?, y = ?, z = ?, heading = ? WHERE id = ?',
        { coords.x, coords.y, coords.z, heading or 0.0, id }
    )

    do
        local fields = {}
        for _, f in ipairs(PlayerFields(src, Player)) do fields[#fields+1] = f end

        if old then
            fields[#fields+1] = { name = "Bench ID", value = Safe(old.id), inline = true }
            fields[#fields+1] = { name = "Bench Type", value = Safe(old.bench_type), inline = true }
            fields[#fields+1] = { name = "Old Coords", value = ("x=%.2f, y=%.2f, z=%.2f"):format(old.x, old.y, old.z), inline = false }
            fields[#fields+1] = { name = "New Coords", value = ("x=%.2f, y=%.2f, z=%.2f"):format(coords.x, coords.y, coords.z), inline = false }
            fields[#fields+1] = { name = "Old Heading", value = Safe(old.heading), inline = true }
            fields[#fields+1] = { name = "New Heading", value = Safe(heading), inline = true }
            fields[#fields+1] = { name = "Access (Job)", value = ("%s | min grade: %s"):format(Safe(old.job), Safe(old.min_grade)), inline = false }
            fields[#fields+1] = { name = "Access (Gang)", value = ("%s | min grade: %s"):format(Safe(old.gang), Safe(old.gang_grade)), inline = false }
            fields[#fields+1] = { name = "Item Restriction", value = ("%s x%s"):format(Safe(old.restrict_item), Safe(old.restrict_amount)), inline = false }
        else
            fields[#fields+1] = { name = "Bench ID", value = Safe(id), inline = true }
            fields[#fields+1] = { name = "New Coords", value = ("x=%.2f, y=%.2f, z=%.2f"):format(coords.x, coords.y, coords.z), inline = false }
            fields[#fields+1] = { name = "New Heading", value = Safe(heading), inline = true }
        end

        SendDiscordWebhook("moved", "Bench Moved", fields)
    end

    TriggerClientEvent('JG-Crafting:client:RefreshBenches', -1)
end)

RegisterNetEvent('JG-Crafting:server:DeleteBench', function(id)
    local src = source
    if not IsAdmin(src) then return end
    if not id then return end

    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end

    local bench = exports.oxmysql:singleSync('SELECT * FROM crafting_benches WHERE id = ?', { id })
    exports.oxmysql:execute('DELETE FROM crafting_benches WHERE id = ?', { id })

    do
        local fields = {}
        for _, f in ipairs(PlayerFields(src, Player)) do fields[#fields+1] = f end

        if bench then
            local coords = { x = bench.x, y = bench.y, z = bench.z }
            for _, f in ipairs(BenchFields(bench.bench_type, bench.id, coords, bench.heading, bench.job, bench.min_grade, bench.gang, bench.gang_grade, bench.restrict_item, bench.restrict_amount)) do
                fields[#fields+1] = f
            end
        else
            fields[#fields+1] = { name = "Bench ID", value = Safe(id), inline = true }
        end

        fields[#fields+1] = { name = "Returned Item?", value = "No", inline = false }
        SendDiscordWebhook("deleted_no_item", "Bench Deleted (No Item Returned)", fields)
    end

    TriggerClientEvent('JG-Crafting:client:RefreshBenches', -1)
end)

-- NOTE: signature includes gang + gangGrade + restrictItem + restrictAmount
RegisterNetEvent('JG-Crafting:server:PlaceBench', function(benchType, coords, heading, job, minGrade, gang, gangGrade, restrictItem, restrictAmount)
    local src = source
    if not IsAdmin(src) then
        TriggerClientEvent('QBCore:Notify', src, 'Only admins can place benches', 'error')
        return
    end

    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    if not benchType or not coords then return end

    local benchDef = (Config.BenchTypes and Config.BenchTypes[benchType]) or nil
    if not benchDef then
        TriggerClientEvent('QBCore:Notify', src, ('Invalid bench type: %s'):format(tostring(benchType)), 'error')
        return
    end

    -- prefer benchDef.item, fallback to placeItem, then crafting_bench
    local itemName = (benchDef.item or benchDef.placeItem or 'crafting_bench')
    if itemName == '' then itemName = 'crafting_bench' end

    local have = GetItemCount(src, Player, itemName)
    if have < 1 then
        TriggerClientEvent('QBCore:Notify', src, ('Missing item: %s'):format(itemName), 'error')
        return
    end

    if not RemoveItem(src, Player, itemName, 1) then
        TriggerClientEvent('QBCore:Notify', src, ('Failed to remove item: %s'):format(itemName), 'error')
        return
    end

    -- sanitize
    if job == '' then job = nil end
    if gang == '' then gang = nil end

    minGrade = tonumber(minGrade) or 0
    gangGrade = tonumber(gangGrade) or 0
    if minGrade < 0 then minGrade = 0 end
    if gangGrade < 0 then gangGrade = 0 end

    if restrictItem == '' then restrictItem = nil end
    restrictAmount = tonumber(restrictAmount) or 1
    if restrictAmount < 1 then restrictAmount = 1 end

    -- IMPORTANT: ensure your SQL table has these columns:
    -- restrict_item, restrict_amount
    local newId = exports.oxmysql:insertSync(
        'INSERT INTO crafting_benches (bench_type, x, y, z, heading, owner, job, min_grade, gang, gang_grade, restrict_item, restrict_amount) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        {
            benchType,
            coords.x, coords.y, coords.z,
            heading or 0.0,
            Player.PlayerData.citizenid,
            job, minGrade,
            gang, gangGrade,
            restrictItem, restrictAmount
        }
    )

    do
        local fields = {}
        for _, f in ipairs(PlayerFields(src, Player)) do fields[#fields+1] = f end
        for _, f in ipairs(BenchFields(benchType, newId, coords, heading, job, minGrade, gang, gangGrade, restrictItem, restrictAmount)) do
            fields[#fields+1] = f
        end
        fields[#fields+1] = { name = "Bench Item", value = Safe(itemName), inline = true }
        SendDiscordWebhook("placed", "Bench Placed", fields)
    end

    TriggerClientEvent('JG-Crafting:client:RefreshBenches', -1)
end)

RegisterNetEvent('JG-Crafting:server:PickupBench', function(id)
    local src = source
    if not IsAdmin(src) then
        TriggerClientEvent('QBCore:Notify', src, 'Only admins can pick up benches', 'error')
        return
    end

    local Player = QBCore.Functions.GetPlayer(src)
    if not Player or not id then return end

    local bench = exports.oxmysql:singleSync('SELECT * FROM crafting_benches WHERE id = ?', { id })
    if not bench then return end

    exports.oxmysql:execute('DELETE FROM crafting_benches WHERE id = ?', { id })

    local benchDef = Config.BenchTypes and Config.BenchTypes[bench.bench_type]
    local itemName = (benchDef and (benchDef.item or benchDef.placeItem)) or 'crafting_bench'
    if itemName == '' then itemName = 'crafting_bench' end

    AddItem(src, Player, itemName, 1)

    do
        local fields = {}
        for _, f in ipairs(PlayerFields(src, Player)) do fields[#fields+1] = f end

        local coords = { x = bench.x, y = bench.y, z = bench.z }
        for _, f in ipairs(BenchFields(bench.bench_type, bench.id, coords, bench.heading, bench.job, bench.min_grade, bench.gang, bench.gang_grade, bench.restrict_item, bench.restrict_amount)) do
            fields[#fields+1] = f
        end

        fields[#fields+1] = { name = "Returned Item", value = Safe(itemName), inline = true }
        fields[#fields+1] = { name = "Returned Item?", value = "Yes", inline = true }

        SendDiscordWebhook("deleted_with_item", "Bench Picked Up (Item Returned)", fields)
    end

    TriggerClientEvent('JG-Crafting:client:RefreshBenches', -1)
end)

-- ======================
-- CRAFT ITEM
-- ======================
RegisterNetEvent('JG-Crafting:server:CraftItem', function(data)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player or not data or not data.item then return end

    local item = data.item
    local requires = item.requires or {}

    for reqItem, amount in pairs(requires) do
        local need = tonumber(amount) or 0
        if need > 0 then
            local have = GetItemCount(src, Player, reqItem)
            if have < need then
                TriggerClientEvent('QBCore:Notify', src,
                    ('Missing %sx %s (you have %s)'):format(need, reqItem, have),
                    'error', 8000
                )
                return
            end
        end
    end

    for reqItem, amount in pairs(requires) do
        local need = tonumber(amount) or 0
        if need > 0 and not RemoveItem(src, Player, reqItem, need) then
            TriggerClientEvent('QBCore:Notify', src,
                ('Could not remove %sx %s'):format(need, reqItem),
                'error', 8000
            )
            return
        end
    end

    local giveAmount = tonumber(item.amount) or 1
    AddItem(src, Player, item.name, giveAmount)

    do
        local fields = {}
        for _, f in ipairs(PlayerFields(src, Player)) do fields[#fields+1] = f end

        fields[#fields+1] = { name = "Bench Type", value = Safe(data.benchType), inline = true }
        fields[#fields+1] = { name = "Bench ID", value = Safe(data.benchId), inline = true }
        fields[#fields+1] = { name = "Crafted Item", value = ("%s x%s"):format(Safe(item.name), Safe(giveAmount)), inline = false }
        fields[#fields+1] = { name = "Label", value = Safe(item.label), inline = true }
        fields[#fields+1] = { name = "Craft Time (ms)", value = Safe(item.time), inline = true }

        local reqLines = {}
        for reqItem, amount in pairs(requires) do
            reqLines[#reqLines+1] = ("%sx %s"):format(tonumber(amount) or 0, tostring(reqItem))
        end
        fields[#fields+1] = { name = "Requirements", value = (#reqLines > 0 and table.concat(reqLines, "\n") or "None"), inline = false }

        SendDiscordWebhook("crafted", "Item Crafted", fields)
    end

    TriggerClientEvent('JG-Crafting:client:RemoveCraftProp', src)
end)

-- ======================
-- DISMANTLE ITEM
-- ======================
RegisterNetEvent('JG-Crafting:server:DismantleItem', function(data)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player or not data or not data.item then return end

    local benchType = data.benchType
    local benchDef = Config.BenchTypes and Config.BenchTypes[benchType]
    if not benchDef or benchDef.mode ~= 'dismantle' then return end

    local itemName = data.item and data.item.name
    if not itemName then return end

    local itemDef = nil
    for _, it in pairs(benchDef.items or {}) do
        if it and it.name == itemName then
            itemDef = it
            break
        end
    end
    if not itemDef then return end

    local removePer = tonumber(itemDef.removeAmount) or 1
    if removePer < 1 then removePer = 1 end

    local times = tonumber(data.dismantleAmount) or 1
    if times < 1 then times = 1 end

    local removeAmt = removePer * times

    local have = GetItemCount(src, Player, itemName)
    if have < removeAmt then
        TriggerClientEvent('QBCore:Notify', src,
            ('Missing %sx %s (you have %s)'):format(removeAmt, itemName, have),
            'error', 8000
        )
        return
    end

    if not RemoveItem(src, Player, itemName, removeAmt) then
        TriggerClientEvent('QBCore:Notify', src,
            ('Could not remove %sx %s'):format(removeAmt, itemName),
            'error', 8000
        )
        return
    end

    local mult = 1.0
    if Config.Dismantle and Config.Dismantle.returnMultiplier then
        mult = tonumber(Config.Dismantle.returnMultiplier) or 1.0
    end

    local baseReturns = itemDef.returns

    if baseReturns == nil then
        local requires, craftOut = FindCraftRecipe(itemName)
        if requires then
            baseReturns = {}
            for reqItem, reqAmt in pairs(requires) do
                local perOne = (tonumber(reqAmt) or 0) / craftOut
                baseReturns[reqItem] = perOne
            end
        else
            baseReturns = {}
        end
    end

    local returnedLines = {}
    for retItem, baseAmount in pairs(baseReturns) do
        local amt = (tonumber(baseAmount) or 0) * times * mult

        if Config.Dismantle and Config.Dismantle.roundDown ~= false then
            amt = math.floor(amt)
        else
            amt = math.floor(amt + 0.5)
        end

        if amt > 0 then
            AddItem(src, Player, retItem, amt)
            returnedLines[#returnedLines+1] = ("%s x%s"):format(retItem, amt)
        end
    end

    do
        local fields = {}
        for _, f in ipairs(PlayerFields(src, Player)) do fields[#fields+1] = f end

        fields[#fields+1] = { name = "Bench Type", value = Safe(data.benchType), inline = true }
        fields[#fields+1] = { name = "Bench ID", value = Safe(data.benchId), inline = true }

        fields[#fields+1] = { name = "Dismantled Item", value = ("%s x%s"):format(Safe(itemName), Safe(times)), inline = false }
        fields[#fields+1] = { name = "Removed Amount", value = Safe(removeAmt), inline = true }
        fields[#fields+1] = { name = "Label", value = Safe(itemDef.label), inline = true }
        fields[#fields+1] = { name = "Time (ms)", value = Safe(itemDef.time), inline = true }
        fields[#fields+1] = { name = "Multiplier", value = Safe(mult), inline = true }
        fields[#fields+1] = { name = "Returns", value = (#returnedLines > 0 and table.concat(returnedLines, "\n") or "None"), inline = false }

        SendDiscordWebhook("dismantled", "Item Dismantled", fields)
    end

    TriggerClientEvent('JG-Crafting:client:RemoveCraftProp', src)
end)
