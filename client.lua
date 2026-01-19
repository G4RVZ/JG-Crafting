-- JG-Crafting/client.lua (cleaned + optimized)
local QBCore = exports['qb-core']:GetCoreObject()

-- ======================
-- RESOURCE DETECTION
-- ======================
local function HasRes(res) return GetResourceState(res) == 'started' end

local HAS_OX_INV    = HasRes('ox_inventory')
local HAS_OX_LIB    = HasRes('ox_lib')
local HAS_OX_TARGET = HasRes('ox_target')

-- ox_lib exposes global `lib` when running; keep a safe handle
local OX = (HAS_OX_LIB and _G.lib) or nil

-- ======================
-- SYSTEM DETECTION (Config override aware)
-- ======================
local function ResolveSystem(name)
    local pref = (Config.Systems and Config.Systems[name]) or 'auto'
    pref = tostring(pref):lower()

    if pref ~= 'auto' then
        return pref -- 'qb' or 'ox'
    end

    if name == 'Target' then
        return HAS_OX_TARGET and 'ox' or 'qb'
    end

    if name == 'Inventory' then
        return HAS_OX_INV and 'ox' or 'qb'
    end

    -- Menu/Input/Progress default to ox if ox_lib is running, otherwise qb
    return HAS_OX_LIB and 'ox' or 'qb'
end

local MenuSystem      = ResolveSystem('Menu')
local InputSystem     = ResolveSystem('Input')
local ProgressSystem  = ResolveSystem('Progress')
local TargetSystem    = ResolveSystem('Target')
local InventorySystem = ResolveSystem('Inventory')

-- Admin menu can be forced separately; defaults to MenuSystem if not explicitly set
local AdminMenuSystem = (Config.Systems and Config.Systems.AdminMenu and tostring(Config.Systems.AdminMenu):lower()) or 'auto'
if AdminMenuSystem == 'auto' then
    AdminMenuSystem = MenuSystem
end

-- ======================
-- STATE
-- ======================
local benches = {}
local spawned = {}

local placing = false
local placingObj = nil
local placingHeading = 0.0

local menuOpen = false
local activeBenchType = nil
local activeBenchId = nil

local previewProp = nil

local craftingQueue = {}
local isCrafting = false

local isAdmin = false

-- camera
local previewCam = nil
local camActive = false
local camBenchId = nil
local lastCamInterp = 500

local PromptBenchAccess

-- local hide loop state
local hiddenLoopRunning = false
local allowVisibleWhileMenu = false


-- ======================
-- ADMIN STATE
-- ======================
local function RefreshAdmin()
    TriggerServerEvent('JG-Crafting:server:CheckAdmin')
end

RegisterNetEvent('QBCore:Client:OnPlayerLoaded', RefreshAdmin)
RegisterNetEvent('QBCore:Client:OnJobUpdate', RefreshAdmin)

RegisterNetEvent('JG-Crafting:client:SetAdmin', function(state)
    isAdmin = (state == true)
end)

CreateThread(function()
    Wait(1500)
    RefreshAdmin()
end)

-- ======================
-- UTILS
-- ======================
local function LoadModel(model)
    model = (type(model) == 'number') and model or joaat(model)
    if HasModelLoaded(model) then return true end

    RequestModel(model)
    local timeout = GetGameTimer() + 5000
    while not HasModelLoaded(model) do
        if GetGameTimer() > timeout then return false end
        Wait(0)
    end
    return true
end

local function SnapObjectToGround(obj)
    if not DoesEntityExist(obj) then return end
    FreezeEntityPosition(obj, false)
    PlaceObjectOnGroundProperly(obj)
    FreezeEntityPosition(obj, true)
end

local function GetLocalItemCount(item)
    -- ox_inventory path
    if InventorySystem == 'ox' and HasRes('ox_inventory') then
        local result = exports.ox_inventory:Search('count', item)

        -- Some versions/cases can return a table; normalize to a number
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

        return tonumber(result) or 0
    end

    -- qb inventory path
    local pData = QBCore.Functions.GetPlayerData()
    local items = (pData and pData.items) or {}

    for _, it in pairs(items) do
        if it and it.name == item then
            return tonumber(it.amount) or 0
        end
    end

    return 0
end

local function CanCraftItem(def)
    local req = def and def.requires or {}
    for reqItem, amount in pairs(req) do
        local need = tonumber(amount) or 0
        if need > 0 and GetLocalItemCount(reqItem) < need then
            return false
        end
    end
    return true
end

local function CanDismantleItem(def)
    if not def or not def.name then return false end
    local need = tonumber(def.removeAmount) or 1
    if need < 1 then need = 1 end
    return GetLocalItemCount(def.name) >= need
end

local function GetCraftAnimForSystem()
    local c = Config.Crafting or {}

    -- qb-progressbar expects: { animDict = '', anim = '', flags = 49 }
    if ProgressSystem ~= 'ox' then
        return c
    end

    -- ox_lib expects: { dict = '', clip = '', flag = 49 }
    local dict = c.dict or c.animDict
    local clip = c.clip or c.anim
    local flag = c.flag or c.flags or 49

    if not dict or not clip then return nil end
    return { dict = dict, clip = clip, flag = flag }
end

-- ======================
-- ITEM LIST (for restriction picker)
-- ======================
local _itemOptionsCache = nil
local _itemOptionsCacheAt = 0
local ITEM_CACHE_MS = 60 * 1000 -- rebuild list every 60s

local function BuildItemOptions()
    -- cache to avoid rebuilding a huge list constantly
    if _itemOptionsCache and (GetGameTimer() - _itemOptionsCacheAt) < ITEM_CACHE_MS then
        return _itemOptionsCache
    end

    local opts = {}

    -- 1) ox_inventory (preferred when running)
    if HasRes('ox_inventory') and exports.ox_inventory and exports.ox_inventory.Items then
        local ok, items = pcall(function()
            return exports.ox_inventory:Items()
        end)

        if ok and type(items) == 'table' then
            for name, data in pairs(items) do
                local label = (data and data.label) or name
                opts[#opts+1] = { label = (label .. " (" .. name .. ")"), value = name }
            end
        end
    end

    -- 2) QBCore.Shared.Items fallback
    if #opts == 0 then
        local items = (QBCore.Shared and QBCore.Shared.Items) or {}
        for name, data in pairs(items) do
            local label = (data and data.label) or name
            opts[#opts+1] = { label = (label .. " (" .. name .. ")"), value = name }
        end
    end

    table.sort(opts, function(a,b) return a.label < b.label end)

    -- optional: add a "None" option at top
    table.insert(opts, 1, { label = "None (no restriction)", value = "__none" })

    _itemOptionsCache = opts
    _itemOptionsCacheAt = GetGameTimer()
    return opts
end

-- ======================
-- PLAYER VISIBILITY (LOCAL ONLY)
-- ======================
local function ShowLocalPlayer()
    local ped = PlayerPedId()
    SetPlayerInvisibleLocally(PlayerId(), false)
    ResetEntityAlpha(ped)
    SetEntityVisible(ped, true, false)
end

local function EnsureHiddenLoop()
    if hiddenLoopRunning then return end
    hiddenLoopRunning = true

    CreateThread(function()
        while (menuOpen or camActive) do
            if not allowVisibleWhileMenu then
                local ped = PlayerPedId()
                SetEntityLocallyInvisible(ped)
                SetPlayerInvisibleLocally(PlayerId(), true)
            end
            Wait(0)
        end

        ShowLocalPlayer()
        hiddenLoopRunning = false
    end)
end


local function HideLocalPlayer()
    local ped = PlayerPedId()
    SetEntityVisible(ped, false, false)
    SetEntityAlpha(ped, 0, false)
    SetPlayerInvisibleLocally(PlayerId(), true)
    EnsureHiddenLoop()
end

-- ======================
-- RAYCAST FROM CAMERA (for placement)
-- ======================
local function RotationToDirection(rot)
    local z = math.rad(rot.z)
    local x = math.rad(rot.x)
    local num = math.abs(math.cos(x))
    return vector3(-math.sin(z) * num, math.cos(z) * num, math.sin(x))
end

local function RaycastFromCamera(distance)
    local camRot = GetGameplayCamRot(2)
    local camPos = GetGameplayCamCoord()
    local dir = RotationToDirection(camRot)
    local dest = camPos + (dir * (distance or 10.0))

    local ray = StartShapeTestRay(
        camPos.x, camPos.y, camPos.z,
        dest.x, dest.y, dest.z,
        -1, PlayerPedId(), 0
    )

    local _, hit, endCoords = GetShapeTestResult(ray)
    return hit == 1, endCoords
end

-- ======================
-- PREVIEW PROP
-- ======================
local function RemovePreviewProp()
    if previewProp and DoesEntityExist(previewProp) then
        DeleteEntity(previewProp)
    end
    previewProp = nil
end

local function SpawnPreviewPropOnBench(benchEntity, preview)
    RemovePreviewProp()
    if not preview or not preview.model then return end
    if not DoesEntityExist(benchEntity) then return end
    if not LoadModel(preview.model) then return end

    previewProp = CreateObject(joaat(preview.model), 0.0, 0.0, 0.0, false, false, false)
    if not DoesEntityExist(previewProp) then
        previewProp = nil
        return
    end

    SetEntityCollision(previewProp, false, false)
    SetEntityInvincible(previewProp, true)
    FreezeEntityPosition(previewProp, true)

    local off = preview.offset or vector3(0.0, 0.0, 1.0)
    local baseRot = preview.rotation or vector3(0.0, 0.0, 0.0)

    local function Attach(rotZ)
        AttachEntityToEntity(
            previewProp, benchEntity, 0,
            off.x, off.y, off.z,
            baseRot.x, baseRot.y, baseRot.z + (rotZ or 0.0),
            false, false, false, false, 2, true
        )
    end

    Attach(0.0)

    if preview.rotate == nil or preview.rotate == true then
        CreateThread(function()
            local h = 0.0
            local speed = 0.6
            if Config.Preview and Config.Preview.rotateSpeed then
                speed = tonumber(Config.Preview.rotateSpeed) or speed
            end

            while menuOpen and previewProp and DoesEntityExist(previewProp) and DoesEntityExist(benchEntity) do
                h = (h + speed) % 360.0
                Attach(h)
                Wait(0)
            end

            RemovePreviewProp()
        end)
    end
end

-- ======================
-- PREVIEW CAMERA
-- ======================
local function StopPreviewCam()
    if previewCam then
        SetCamActive(previewCam, false)
    end

    RenderScriptCams(false, false, 0, true, true)
    DestroyAllCams(true)

    previewCam = nil
    camActive = false
    camBenchId = nil

    ClearFocus()
    -- DO NOT ShowLocalPlayer() here (menu/crafting decides visibility)
end


-- ======================
-- FORCE STOP PREVIEW CAM ON ESC (while menu is open)
-- ======================
CreateThread(function()
    while true do
        if not menuOpen then
            Wait(250)
        else
            Wait(0)

            -- ESC / Pause keys (covers most setups)
            if IsControlJustPressed(0, 322) or IsControlJustPressed(0, 200) then
                -- Only kill the cam (do NOT HardCleanup here unless you want full cleanup)
                StopPreviewCam()

                -- Optional: also remove preview prop when escaping
                RemovePreviewProp()

                -- Prevent double-trigger if key is held
                Wait(250)
            end
        end
    end
end)

local function StartPreviewCam(benchEntity, focusEntity)
    if not Config.PreviewCam or Config.PreviewCam.enabled == false then return end
    if not DoesEntityExist(benchEntity) then return end

    StopPreviewCam()

    local cfg = Config.PreviewCam.default or {}
    if activeBenchType and Config.PreviewCam[activeBenchType] then
        cfg = Config.PreviewCam[activeBenchType]
    end

    local fov     = cfg.fov or 45.0
    local interp  = cfg.interpMs or 650
    local camOff  = cfg.offset or vector3(0.0, -1.25, 0.90)
    local lookOff = cfg.lookAtOffset or vector3(0.0, 0.0, 0.12)

    lastCamInterp = interp

    previewCam = CreateCam('DEFAULT_SCRIPTED_CAMERA', true)
    SetCamFov(previewCam, fov)

    local camPos = GetOffsetFromEntityInWorldCoords(benchEntity, camOff.x, camOff.y, camOff.z)
    SetCamCoord(previewCam, camPos.x, camPos.y, camPos.z)

    local target = (focusEntity and DoesEntityExist(focusEntity)) and focusEntity or benchEntity
    local tPos = GetEntityCoords(target)
    PointCamAtCoord(previewCam, tPos.x + lookOff.x, tPos.y + lookOff.y, tPos.z + lookOff.z)

    SetCamActive(previewCam, true)
    RenderScriptCams(true, true, interp, true, true)
    camActive = true

    HideLocalPlayer()
end

-- ======================
-- MENU HELPERS
-- ======================

local function ExitBenchMenuForProgress()
    -- Close any UI (works even if CloseMenuUI isn't defined yet)
    if HasRes('qb-menu') then
        exports['qb-menu']:closeMenu()
    end
    if OX then
        OX.hideContext()
    end

    -- Mark menu as closed so nothing restores cam/hide
    menuOpen = false
    activeBenchType = nil
    activeBenchId = nil

    -- Kill preview stuff
    RemovePreviewProp()
    StopPreviewCam()
    camBenchId = nil
    camActive = false

    -- Make sure player is visible for progress
    allowVisibleWhileMenu = true
    ShowLocalPlayer()
end

local function CloseMenuUI()
    if MenuSystem == 'ox' and OX then
        OX.hideContext()
        return
    end

    if HasRes('qb-menu') then
        exports['qb-menu']:closeMenu()
    end
end

local function ForceCloseAnyMenu()
    if HasRes('qb-menu') then
        exports['qb-menu']:closeMenu()
    end
    if OX then
        OX.hideContext()
    end
end

local function OpenMenu(menu)
    if MenuSystem == 'ox' and OX then
        local options = {}
        local title = (menu[1] and menu[1].header) or 'Menu'

        for i = 2, #menu do
            local row = menu[i]
            options[#options + 1] = {
                title = row.header,
                description = row.text or '',
                disabled = row.disabled == true,
                onSelect = (row.disabled == true) and nil or function()
                    if row.params then
                        TriggerEvent(row.params.event, row.params.args)
                    end
                end
            }
        end

        OX.registerContext({ id = 'jg_crafting_menu', title = title, options = options })
        OX.showContext('jg_crafting_menu')
        return
    end

    -- qb-menu fallback: remove params for disabled so it can't be clicked
    local fixed = {}
    for i = 1, #menu do
        local row = menu[i]
        if row and row.disabled == true then
            fixed[#fixed + 1] = { header = row.header, text = row.text or '', disabled = true }
        else
            fixed[#fixed + 1] = row
        end
    end

    if HasRes('qb-menu') then
        exports['qb-menu']:openMenu(fixed)
    end
end

-- ======================
-- CENTRAL CLEANUP
-- ======================
local function HardCleanup()
    menuOpen = false
    activeBenchType = nil
    activeBenchId = nil
    camBenchId = nil

    RemovePreviewProp()
    StopPreviewCam()
    ShowLocalPlayer()

    ForceCloseAnyMenu()
end

-- Failsafe cleanup:
-- qb-menu uses NUI focus; ox_lib context does NOT reliably keep NUI focus.
CreateThread(function()
    while true do
        Wait(200)

        if (menuOpen or camActive) then
            -- If pause menu is open, ALWAYS cleanup (ESC often leads here)
            if IsPauseMenuActive() then
                HardCleanup()
                goto continue
            end

            if MenuSystem == 'ox' and OX then
                local shouldCleanup = false

                -- Best case: newer ox_lib
                if OX.getOpenContext then
                    local ok, ctx = pcall(OX.getOpenContext)
                    if ok and ctx == nil then
                        shouldCleanup = true
                    end
                else
                    -- Fallback: if we can't query context state, use NUI focus loss
                    -- (when ESC closes the context, focus usually drops)
                    local nuiFocused = IsNuiFocused() or IsNuiFocusKeepingInput()
                    if not nuiFocused then
                        shouldCleanup = true
                    end
                end

                if shouldCleanup then
                    HardCleanup()
                end
            else
                local nuiFocused = IsNuiFocused() or IsNuiFocusKeepingInput()
                if not nuiFocused then
                    HardCleanup()
                end
            end
        end

        ::continue::
    end
end)

-- ======================
-- INPUT (amount prompts)
-- ======================
local function InputAmount(cb)
    if InputSystem == 'ox' and OX and OX.inputDialog then
        local input = OX.inputDialog('How many?', {
            { type = 'number', label = 'Amount', required = true, min = 1 }
        })
        if input and input[1] then cb(tonumber(input[1])) end
        return
    end

    if HasRes('qb-input') then
        local r = exports['qb-input']:ShowInput({
            header = 'How many?',
            submitText = 'Queue',
            inputs = {
                { text = 'Amount', name = 'amount', type = 'number', isRequired = true }
            }
        })
        if r and r.amount then cb(tonumber(r.amount)) end
    end
end

local function PromptDismantleAmount(item)
    if not item or not item.name then return nil end

    local removePer = tonumber(item.removeAmount) or 1
    if removePer < 1 then removePer = 1 end

    local have = GetLocalItemCount(item.name)
    local maxQty = math.floor((tonumber(have) or 0) / removePer)

    if maxQty < 1 then
        QBCore.Functions.Notify(('You don’t have enough %s.'):format(item.label or item.name), 'error')
        return nil
    end

    local title = ('Dismantle %s'):format(item.label or item.name)

    if InputSystem == 'ox' and OX and OX.inputDialog then
        local input = OX.inputDialog(title, {
            { type = 'number', label = ('Amount (1-%s)'):format(maxQty), required = true, min = 1, max = maxQty }
        })
        if input and input[1] then
            local amt = tonumber(input[1])
            if amt and amt >= 1 and amt <= maxQty then
                return amt
            end
        end
        return nil
    end

    if HasRes('qb-input') then
        local r = exports['qb-input']:ShowInput({
            header = title,
            submitText = 'Dismantle',
            inputs = {
                { text = ('Amount (1-%s)'):format(maxQty), name = 'amount', type = 'number', isRequired = true }
            }
        })

        if r and r.amount then
            local amt = tonumber(r.amount)
            if amt and amt >= 1 and amt <= maxQty then
                return amt
            end
            QBCore.Functions.Notify(('Invalid amount (1-%s).'):format(maxQty), 'error')
        end
        return nil
    end

    -- last resort
    return 1
end

-- ======================
-- ACCESS HELPERS
-- ======================
local function GetPlayerJobAndGrade()
    local pData = QBCore.Functions.GetPlayerData() or {}
    local job = pData.job or {}

    local name = job.name
    local grade = 0
    if job.grade then
        if type(job.grade) == 'table' then
            grade = tonumber(job.grade.level) or tonumber(job.grade.grade) or 0
        else
            grade = tonumber(job.grade) or 0
        end
    end

    return name, grade
end

local function GetPlayerGangAndGrade()
    local pData = QBCore.Functions.GetPlayerData() or {}
    local gang = pData.gang or {}

    local name = gang.name
    local grade = 0
    if gang.grade then
        if type(gang.grade) == 'table' then
            grade = tonumber(gang.grade.level) or tonumber(gang.grade.grade) or 0
        else
            grade = tonumber(gang.grade) or 0
        end
    end

    return name, grade
end

-- STEP 4 (SAFE – GANG LOGIC PRESERVED)
local function HasBenchAccess(benchRow)
    if not benchRow then return false end

    -- Inventory restriction (deny if player HAS item)
    local rItem = benchRow.restrict_item
    local rAmt  = tonumber(benchRow.restrict_amount) or 1
    if rItem and rItem ~= '' and rAmt > 0 then
        if GetLocalItemCount(rItem) >= rAmt then
            return false
        end
    end

    -- Gang restriction
    if benchRow.gang and benchRow.gang ~= '' then
        local myGang, myGangGrade = GetPlayerGangAndGrade()
        local needGrade = tonumber(benchRow.min_grade) or 0

        if myGang ~= benchRow.gang then return false end
        if myGangGrade < needGrade then return false end

        return true
    end

    -- Job restriction
    if benchRow.job and benchRow.job ~= '' then
        local myJob, myJobGrade = GetPlayerJobAndGrade()
        local needGrade = tonumber(benchRow.min_grade) or 0

        if myJob ~= benchRow.job then return false end
        if myJobGrade < needGrade then return false end

        return true
    end

    -- Public bench (no job/gang set)
    return true
end

-- ======================
-- EMAIL
-- ======================
local function SendRequirementsEmail(item)
    if not item then return end

    local label = item.label or item.name or 'Item'
    local lines = { ('Required items to craft %s:'):format(label) }

    for reqItem, amount in pairs(item.requires or {}) do
        lines[#lines + 1] = ('%sx %s'):format(amount, reqItem)
    end

    local msg = table.concat(lines, '\n')

    if HasRes('qb-phone') then
        TriggerEvent('qb-phone:client:sendNewMail', {
            sender = 'Crafting Bench',
            subject = ('Crafting Requirements: %s'):format(label),
            message = msg,
            button = {}
        })
        QBCore.Functions.Notify('Requirements sent to your phone', 'success')
        return
    end

    if OX then
        OX.notify({ title = 'Crafting Requirements', description = msg, type = 'inform' })
    else
        QBCore.Functions.Notify(msg, 'primary', 8000)
    end
end

-- ======================
-- BENCH PLACEMENT
-- ======================
local function BeginPlacement(benchType, onConfirm)
    local bench = Config.BenchTypes and Config.BenchTypes[benchType]
    if not bench or placing then return end

    placing = true
    placingHeading = GetEntityHeading(PlayerPedId())

    if not LoadModel(bench.prop) then
        placing = false
        return
    end

    local pcoords = GetEntityCoords(PlayerPedId())
    placingObj = CreateObject(joaat(bench.prop), pcoords.x, pcoords.y, pcoords.z, false, false, false)

    SetEntityAlpha(placingObj, 180, false)
    SetEntityCollision(placingObj, false, false)
    FreezeEntityPosition(placingObj, true)

    if OX and OX.showTextUI then
        OX.showTextUI('[SCROLL] Rotate | [E] Confirm | [BACKSPACE] Cancel')
    end

    CreateThread(function()
        while placing do
            Wait(0)

            local hit, endCoords = RaycastFromCamera(10.0)
            if hit and placingObj and DoesEntityExist(placingObj) then
                local z = endCoords.z + (bench.placeZOffset or 0.0)
                SetEntityCoordsNoOffset(placingObj, endCoords.x, endCoords.y, z, false, false, false)
                SetEntityHeading(placingObj, placingHeading)
                SnapObjectToGround(placingObj)
            end

            if IsControlPressed(0, 15) then placingHeading = placingHeading + 1.5 end -- scroll up
            if IsControlPressed(0, 14) then placingHeading = placingHeading - 1.5 end -- scroll down

            if IsControlJustPressed(0, 38) then -- E
                placing = false
                if OX and OX.hideTextUI then OX.hideTextUI() end

                if placingObj and DoesEntityExist(placingObj) then
                    SnapObjectToGround(placingObj)

                    local coords = GetEntityCoords(placingObj)
                    local heading = GetEntityHeading(placingObj)

                    DeleteEntity(placingObj)
                    placingObj = nil

                    if onConfirm then onConfirm(coords, heading) end
                end
                break
            end

            if IsControlJustPressed(0, 177) then -- Backspace
                placing = false
                if OX and OX.hideTextUI then OX.hideTextUI() end
                if placingObj and DoesEntityExist(placingObj) then
                    DeleteEntity(placingObj)
                end
                placingObj = nil
                break
            end
        end
    end)
end

-- ======================
-- BENCH ACCESS PROMPT (Job/Gang/Public)
-- ======================
PromptBenchAccess = function(cb)
    -- OX input
    if InputSystem == 'ox' and OX and OX.inputDialog then
        local input = OX.inputDialog('Bench Access', {
            {
                type = 'select',
                label = 'Access Type',
                options = {
                    { label = 'Public', value = 'public' },
                    { label = 'Job', value = 'job' },
                    { label = 'Gang', value = 'gang' },
                },
                required = true
            },
            { type = 'input', label = 'Job/Gang Name (only if Job/Gang)', required = false },
            { type = 'number', label = 'Minimum Grade (only if Job/Gang)', required = false, min = 0, default = 0 },
        })

        if not input then cb(nil) return end

        local mode = input[1]
        local name = (input[2] and tostring(input[2])) or ''
        local grade = tonumber(input[3]) or 0

        if mode == 'public' then
            cb({ job = nil, gang = nil, minGrade = 0 })
            return
        end

        if name == '' then cb(nil) return end

        if mode == 'job' then
            cb({ job = name, gang = nil, minGrade = grade })
        else
            cb({ job = nil, gang = name, minGrade = grade })
        end
        return
    end

    -- QB input
    if HasRes('qb-input') then
        local r = exports['qb-input']:ShowInput({
            header = 'Bench Access',
            submitText = 'Confirm',
            inputs = {
                { text = 'Access type (public/job/gang)', name = 'mode', type = 'text', isRequired = true },
                { text = 'Job/Gang name (only if job/gang)', name = 'name', type = 'text', isRequired = false },
                { text = 'Minimum grade (only if job/gang)', name = 'grade', type = 'number', isRequired = false }
            }
        })

        if not r then cb(nil) return end

        local mode = tostring(r.mode or ''):lower()
        local name = (r.name and tostring(r.name)) or ''
        local grade = tonumber(r.grade) or 0

        if mode == 'public' then
            cb({ job = nil, gang = nil, minGrade = 0 })
            return
        end

        if (mode ~= 'job' and mode ~= 'gang') or name == '' then
            cb(nil)
            return
        end

        if mode == 'job' then
            cb({ job = name, gang = nil, minGrade = grade })
        else
            cb({ job = nil, gang = name, minGrade = grade })
        end
        return
    end

    -- no input system available
    cb(nil)
end

-- ======================
-- BENCH RESTRICTION PROMPT (deny if player HAS item)
-- ======================
local function PromptBenchRestriction(cb)
    local itemOpts = BuildItemOptions()

    -- ---------- OX (ox_lib) ----------
    if InputSystem == 'ox' and OX and OX.inputDialog then
        local input = OX.inputDialog('Bench Restriction (Optional)', {
            {
                type = 'select',
                label = 'Restricted Item (blocks if player HAS it)',
                options = itemOpts,
                required = true
            },
            {
                type = 'number',
                label = 'Restricted Amount',
                description = 'Minimum amount to block access (default 1)',
                required = false,
                min = 1,
                default = 1
            }
        })

        if not input then
            cb(nil)
            return
        end

        local picked = input[1]
        local amount = tonumber(input[2]) or 1

        if picked == "__none" then
            cb({ item = nil, amount = 1 })
        else
            cb({ item = picked, amount = math.max(1, amount) })
        end
        return
    end

    -- ---------- QB fallback (qb-menu list) ----------
    if HasRes('qb-menu') then
        local menu = { { header = 'Bench Restriction (Optional)', isMenuHeader = true } }

        for _, opt in ipairs(itemOpts) do
            menu[#menu+1] = {
                header = opt.label,
                params = {
                    event = 'JG-Crafting:client:_pickRestrictItem',
                    args = { value = opt.value }
                }
            }
        end

        menu[#menu+1] = { header = 'Cancel', params = { event = 'JG-Crafting:client:_pickRestrictCancel' } }
        exports['qb-menu']:openMenu(menu)

        local function cleanup()
            RemoveEventHandler(_G.__JG_RESTRICT_ITEM or 0)
            RemoveEventHandler(_G.__JG_RESTRICT_CANCEL or 0)
            _G.__JG_RESTRICT_ITEM = nil
            _G.__JG_RESTRICT_CANCEL = nil
        end

        _G.__JG_RESTRICT_ITEM = AddEventHandler('JG-Crafting:client:_pickRestrictItem', function(data)
            cleanup()

            local picked = data and data.value
            if not picked or picked == "__none" then
                cb({ item = nil, amount = 1 })
                return
            end

            -- ask amount (qb-input)
            if HasRes('qb-input') then
                local r = exports['qb-input']:ShowInput({
                    header = 'Restricted Amount',
                    submitText = 'Confirm',
                    inputs = {
                        { text = 'Amount (default 1)', name = 'amount', type = 'number', isRequired = false }
                    }
                })

                local amt = (r and tonumber(r.amount)) or 1
                cb({ item = picked, amount = math.max(1, amt) })
            else
                cb({ item = picked, amount = 1 })
            end
        end)

        _G.__JG_RESTRICT_CANCEL = AddEventHandler('JG-Crafting:client:_pickRestrictCancel', function()
            cleanup()
            cb(nil)
        end)

        return
    end

    -- no UI available
    cb(nil)
end

-- ======================
-- BENCH ACCESS PROMPT (Job/Gang/Public) with job/gang dropdowns
-- ======================
local function BuildJobOptions()
    local opts = {}
    local jobs = (QBCore.Shared and QBCore.Shared.Jobs) or {}
    for name, data in pairs(jobs) do
        local label = (data and data.label) or name
        opts[#opts + 1] = { label = label .. ' (' .. name .. ')', value = name }
    end
    table.sort(opts, function(a,b) return a.label < b.label end)
    return opts
end

local function BuildGangOptions()
    local opts = {}
    local gangs = (QBCore.Shared and (QBCore.Shared.Gangs or QBCore.Shared.Gang)) or {}
    if type(gangs) == 'table' then
        for name, data in pairs(gangs) do
            local label = (data and data.label) or name
            opts[#opts + 1] = { label = label .. ' (' .. name .. ')', value = name }
        end
    end
    table.sort(opts, function(a,b) return a.label < b.label end)
    return opts
end

-- ======================
-- BENCH ACCESS PROMPT (Job/Gang/Public) with job/gang dropdowns
-- ======================
local function BuildJobOptions()
    local opts = {}
    local jobs = (QBCore.Shared and QBCore.Shared.Jobs) or {}
    for name, data in pairs(jobs) do
        local label = (data and data.label) or name
        opts[#opts + 1] = { label = label .. ' (' .. name .. ')', value = name }
    end
    table.sort(opts, function(a,b) return a.label < b.label end)
    return opts
end

local function BuildGangOptions()
    local opts = {}
    local gangs = (QBCore.Shared and (QBCore.Shared.Gangs or QBCore.Shared.Gang)) or {}
    if type(gangs) == 'table' then
        for name, data in pairs(gangs) do
            local label = (data and data.label) or name
            opts[#opts + 1] = { label = label .. ' (' .. name .. ')', value = name }
        end
    end
    table.sort(opts, function(a,b) return a.label < b.label end)
    return opts
end

PromptBenchAccess = function(cb)
    -- ---------- OX (ox_lib) ----------
    if InputSystem == 'ox' and OX and OX.inputDialog then
        local step1 = OX.inputDialog('Bench Access', {
            {
                type = 'select',
                label = 'Access Type',
                options = {
                    { label = 'Public', value = 'public' },
                    { label = 'Job', value = 'job' },
                    { label = 'Gang', value = 'gang' },
                },
                required = true
            }
        })

        if not step1 then cb(nil) return end
        local mode = step1[1]

        if mode == 'public' then
            cb({ job = nil, gang = nil, minGrade = 0 })
            return
        end

        if mode == 'job' then
            local jobOpts = BuildJobOptions()
            if #jobOpts == 0 then cb(nil) return end

            local step2 = OX.inputDialog('Job Restriction', {
                { type = 'select', label = 'Job', options = jobOpts, required = true },
                { type = 'number', label = 'Minimum Grade', required = false, min = 0, default = 0 },
            })

            if not step2 then cb(nil) return end
            cb({ job = step2[1], gang = nil, minGrade = tonumber(step2[2]) or 0 })
            return
        end

        if mode == 'gang' then
            local gangOpts = BuildGangOptions()
            if #gangOpts == 0 then
                -- If your server doesn’t expose gangs in QBCore.Shared, you can swap this to your own list.
                QBCore.Functions.Notify('No gang list found in QBCore.Shared.Gangs', 'error')
                cb(nil)
                return
            end

            local step2 = OX.inputDialog('Gang Restriction', {
                { type = 'select', label = 'Gang', options = gangOpts, required = true },
                { type = 'number', label = 'Minimum Grade', required = false, min = 0, default = 0 },
            })

            if not step2 then cb(nil) return end
            cb({ job = nil, gang = step2[1], minGrade = tonumber(step2[2]) or 0 })
            return
        end

        cb(nil)
        return
    end

    -- ---------- QB fallback (qb-menu if available) ----------
    if HasRes('qb-menu') then
        exports['qb-menu']:openMenu({
            { header = 'Bench Access', isMenuHeader = true },

            {
                header = 'Public',
                text = 'Anyone can use this bench',
                params = { event = 'JG-Crafting:client:_benchAccessResult', args = { job=nil, gang=nil, minGrade=0 } }
            },
            {
                header = 'Job Restriction',
                text = 'Pick a job from the list',
                params = { event = 'JG-Crafting:client:_benchAccessPickJob', args = {} }
            },
            {
                header = 'Gang Restriction',
                text = 'Pick a gang from the list',
                params = { event = 'JG-Crafting:client:_benchAccessPickGang', args = {} }
            },
            { header = 'Cancel', params = { event = 'JG-Crafting:client:_benchAccessCancel' } }
        })

        -- one-shot temporary handlers
        local function cleanupHandlers()
            RemoveEventHandler(_G.__JG_BENCH_ACCESS_RES or 0)
            RemoveEventHandler(_G.__JG_BENCH_ACCESS_CANCEL or 0)
            RemoveEventHandler(_G.__JG_BENCH_ACCESS_PICKJOB or 0)
            RemoveEventHandler(_G.__JG_BENCH_ACCESS_PICKGANG or 0)
            _G.__JG_BENCH_ACCESS_RES = nil
            _G.__JG_BENCH_ACCESS_CANCEL = nil
            _G.__JG_BENCH_ACCESS_PICKJOB = nil
            _G.__JG_BENCH_ACCESS_PICKGANG = nil
        end

        _G.__JG_BENCH_ACCESS_RES = AddEventHandler('JG-Crafting:client:_benchAccessResult', function(data)
            cleanupHandlers()
            cb(data)
        end)

        _G.__JG_BENCH_ACCESS_CANCEL = AddEventHandler('JG-Crafting:client:_benchAccessCancel', function()
            cleanupHandlers()
            cb(nil)
        end)

        _G.__JG_BENCH_ACCESS_PICKJOB = AddEventHandler('JG-Crafting:client:_benchAccessPickJob', function()
            local jobOpts = BuildJobOptions()
            if #jobOpts == 0 then
                QBCore.Functions.Notify('No jobs found.', 'error')
                cleanupHandlers()
                cb(nil)
                return
            end

            local menu = { { header = 'Select Job', isMenuHeader = true } }
            for _, o in ipairs(jobOpts) do
                menu[#menu+1] = {
                    header = o.label,
                    params = { event = 'JG-Crafting:client:_benchAccessAskGradeJob', args = { job = o.value } }
                }
            end
            menu[#menu+1] = { header = 'Back', params = { event = 'JG-Crafting:client:_benchAccessCancel' } }
            exports['qb-menu']:openMenu(menu)
        end)

        _G.__JG_BENCH_ACCESS_PICKGANG = AddEventHandler('JG-Crafting:client:_benchAccessPickGang', function()
            local gangOpts = BuildGangOptions()
            if #gangOpts == 0 then
                QBCore.Functions.Notify('No gangs found in QBCore.Shared.Gangs.', 'error')
                cleanupHandlers()
                cb(nil)
                return
            end

            local menu = { { header = 'Select Gang', isMenuHeader = true } }
            for _, o in ipairs(gangOpts) do
                menu[#menu+1] = {
                    header = o.label,
                    params = { event = 'JG-Crafting:client:_benchAccessAskGradeGang', args = { gang = o.value } }
                }
            end
            menu[#menu+1] = { header = 'Back', params = { event = 'JG-Crafting:client:_benchAccessCancel' } }
            exports['qb-menu']:openMenu(menu)
        end)

        -- grade prompts (qb-input)
        RegisterNetEvent('JG-Crafting:client:_benchAccessAskGradeJob', function(args)
            local r = HasRes('qb-input') and exports['qb-input']:ShowInput({
                header = 'Minimum Job Grade',
                submitText = 'Confirm',
                inputs = { { text = 'Min grade (0 = any)', name = 'grade', type = 'number', isRequired = false } }
            }) or nil

            local grade = (r and tonumber(r.grade)) or 0
            TriggerEvent('JG-Crafting:client:_benchAccessResult', { job = args.job, gang = nil, minGrade = grade })
        end)

        RegisterNetEvent('JG-Crafting:client:_benchAccessAskGradeGang', function(args)
            local r = HasRes('qb-input') and exports['qb-input']:ShowInput({
                header = 'Minimum Gang Grade',
                submitText = 'Confirm',
                inputs = { { text = 'Min grade (0 = any)', name = 'grade', type = 'number', isRequired = false } }
            }) or nil

            local grade = (r and tonumber(r.grade)) or 0
            TriggerEvent('JG-Crafting:client:_benchAccessResult', { job = nil, gang = args.gang, minGrade = grade })
        end)

        return
    end

    -- No UI available
    cb(nil)
end

-- ======================
-- BENCH PLACEMENT FLOW
-- ======================
local function StartBenchPlacement(benchType)
    BeginPlacement(benchType, function(coords, heading)
        PromptBenchAccess(function(access)
            if not access then
                QBCore.Functions.Notify('Bench placement cancelled', 'error')
                return
            end

            PromptBenchRestriction(function(restrict)
                if restrict == nil then
                    QBCore.Functions.Notify('Bench placement cancelled', 'error')
                    return
                end

                TriggerServerEvent('JG-Crafting:server:PlaceBench',
                    benchType,
                    coords,
                    heading,
                    access.job,
                    access.minGrade,
                    access.gang,
                    access.gangGrade,
                    restrict.item,
                    restrict.amount
                )
            end)
        end)
    end)
end

local function StartBenchPlacementForMove(benchId, benchType)
    BeginPlacement(benchType, function(coords, heading)
        TriggerServerEvent('JG-Crafting:server:UpdateBench', benchId, coords, heading)
    end)
end

RegisterNetEvent('JG-Crafting:client:PlaceBench', function(benchType)
    StartBenchPlacement(benchType)
end)

-- ======================
-- ADMIN MENU (your existing admin options preserved)
-- ======================
local function CopyBenchInfo(benchRow)
    local info = ('id=%s type=%s xyz=%.2f,%.2f,%.2f heading=%.2f'):format(
        benchRow.id, benchRow.bench_type, benchRow.x, benchRow.y, benchRow.z, benchRow.heading
    )

    if OX and OX.setClipboard then
        OX.setClipboard(info)
        OX.notify({ title = 'Bench', description = 'Copied bench info to clipboard', type = 'success' })
    else
        QBCore.Functions.Notify(info, 'primary', 8000)
    end
end

local function OpenAdminBenchMenu(benchRow)
    if not isAdmin then
        QBCore.Functions.Notify('Admins only', 'error')
        return
    end

    local title = ('Manage Bench #%s (%s)'):format(benchRow.id, benchRow.bench_type)

    if AdminMenuSystem == 'ox' and OX then
        OX.registerContext({
            id = 'jg_crafting_admin_bench',
            title = title,
            options = {
                {
                    title = 'Move / Reposition',
                    description = 'Move this bench and save its position',
                    onSelect = function()
                        StartBenchPlacementForMove(benchRow.id, benchRow.bench_type)
                    end
                },
                {
                    title = 'Pick Up (return item)',
                    description = 'Remove bench and return item (admin)',
                    onSelect = function()
                        TriggerServerEvent('JG-Crafting:server:PickupBench', benchRow.id)
                    end
                },
                {
                    title = 'Delete (no item)',
                    description = 'Hard delete (no item returned)',
                    onSelect = function()
                        TriggerServerEvent('JG-Crafting:server:DeleteBench', benchRow.id)
                    end
                },
                {
                    title = 'Info (copy)',
                    description = 'Copy id/type/coords/heading',
                    onSelect = function()
                        CopyBenchInfo(benchRow)
                    end
                }
            }
        })
        OX.showContext('jg_crafting_admin_bench')
        return
    end

    if HasRes('qb-menu') then
        exports['qb-menu']:openMenu({
            { header = title, isMenuHeader = true },
            { header = 'Move / Reposition', text = 'Move this bench and save its position', params = { event = 'JG-Crafting:client:AdminMoveBench', args = benchRow } },
            { header = 'Pick Up (return item)', text = 'Remove bench and return item (admin)', params = { event = 'JG-Crafting:client:AdminPickupBench', args = benchRow } },
            { header = 'Delete (no item)', text = 'Hard delete (no item returned)', params = { event = 'JG-Crafting:client:AdminDeleteBench', args = benchRow } },
            { header = 'Info (copy)', text = 'Copy id/type/coords/heading', params = { event = 'JG-Crafting:client:AdminInfoBench', args = benchRow } },
            { header = 'Close', params = { event = 'JG-Crafting:client:CloseMenu' } }
        })
    end
end

RegisterNetEvent('JG-Crafting:client:AdminMoveBench', function(benchRow)
    if not isAdmin then return end
    StartBenchPlacementForMove(benchRow.id, benchRow.bench_type)
end)

RegisterNetEvent('JG-Crafting:client:AdminPickupBench', function(benchRow)
    if not isAdmin then return end
    TriggerServerEvent('JG-Crafting:server:PickupBench', benchRow.id)
end)

RegisterNetEvent('JG-Crafting:client:AdminDeleteBench', function(benchRow)
    if not isAdmin then return end
    TriggerServerEvent('JG-Crafting:server:DeleteBench', benchRow.id)
end)

RegisterNetEvent('JG-Crafting:client:AdminInfoBench', function(benchRow)
    if not isAdmin then return end
    CopyBenchInfo(benchRow)
end)

-- ======================
-- MENUS (Craft + Dismantle)
-- ======================
function OpenCraftMenu(benchType, benchId)
    local station = Config.BenchTypes and Config.BenchTypes[benchType]
    if not station then return end

    menuOpen = true
    activeBenchType = benchType
    activeBenchId = benchId

    RemovePreviewProp()
    StopPreviewCam()
    HideLocalPlayer()

    -- Start cam immediately when opening
    local benchEntity = spawned[benchId]
    if benchEntity and DoesEntityExist(benchEntity) then
        if (not camActive) or camBenchId ~= benchId then
            StartPreviewCam(benchEntity, benchEntity)
            camBenchId = benchId
        end
    end

    local menu = { { header = station.label, isMenuHeader = true } }

    local isOxContext = (MenuSystem == 'ox' and OX)
    local NL = isOxContext and '\n' or '<br>'

    for _, item in pairs(station.items or {}) do
        local lines = {}

        for r, a in pairs(item.requires or {}) do
            local have = GetLocalItemCount(r)
            local need = tonumber(a) or 0

            if have < need then
                lines[#lines+1] = ('%sx %s (you have %s)'):format(need, r, have)
            else
                lines[#lines+1] = ('%sx %s'):format(need, r)
            end
        end

        local canCraft = CanCraftItem(item)
        local txt = table.concat(lines, NL)

        if not canCraft then
            txt = txt .. NL .. (isOxContext and 'Missing materials' or '<b>Missing materials</b>')
        end

        menu[#menu+1] = {
            header = (canCraft and '' or '✖ ') .. (item.label or item.name),
            text = txt,
            disabled = not canCraft,
            params = canCraft and {
                event = 'JG-Crafting:client:SelectItem',
                args = { benchType = benchType, benchId = benchId, item = item }
            } or nil
        }
    end

    menu[#menu + 1] = { header = 'Close', params = { event = 'JG-Crafting:client:CloseMenu' } }
    OpenMenu(menu)
end

function OpenDismantleMenu(benchType, benchId)
    local station = Config.BenchTypes and Config.BenchTypes[benchType]
    if not station then return end

    menuOpen = true
    activeBenchType = benchType
    activeBenchId = benchId

    RemovePreviewProp()
    StopPreviewCam()
    HideLocalPlayer()

    local benchEntity = spawned[benchId]
    if benchEntity and DoesEntityExist(benchEntity) then
        if (not camActive) or camBenchId ~= benchId then
            StartPreviewCam(benchEntity, benchEntity)
            camBenchId = benchId
        end
    end

    local menu = { { header = station.label, isMenuHeader = true } }

    local isOxContext = (MenuSystem == 'ox' and OX)
    local NL = isOxContext and '\n' or '<br>'

    for _, item in pairs(station.items or {}) do
        local lines = {}

        local removeAmt = tonumber(item.removeAmount) or 1
        if removeAmt < 1 then removeAmt = 1 end

        lines[#lines+1] = ('Consumes: %sx %s'):format(removeAmt, item.name)

        -- NOTE: if you removed manual returns and auto-calc on server, this may show "None".
        -- This is just UI text; server will still return correctly.
        local mult = (Config.Dismantle and tonumber(Config.Dismantle.returnMultiplier)) or 1.0
        local retLines = {}
        for r, a in pairs(item.returns or {}) do
            local amt = (tonumber(a) or 0) * mult
            if not (Config.Dismantle and Config.Dismantle.roundDown == false) then
                amt = math.floor(amt)
            else
                amt = math.floor(amt + 0.5)
            end
            if amt > 0 then
                retLines[#retLines+1] = ('%sx %s'):format(amt, r)
            end
        end

        lines[#lines+1] = 'Returns:'
        lines[#lines+1] = (#retLines > 0 and table.concat(retLines, NL) or 'Auto (server)')

        local canDo = CanDismantleItem(item)
        local txt = table.concat(lines, NL)

        if not canDo then
            txt = txt .. NL .. (isOxContext and 'Missing item to dismantle' or '<b>Missing item to dismantle</b>')
        end

        menu[#menu+1] = {
            header = (canDo and '' or '✖ ') .. (item.label or item.name),
            text = txt,
            disabled = not canDo,
            params = canDo and {
                event = 'JG-Crafting:client:SelectDismantleItem',
                args = { benchType = benchType, benchId = benchId, item = item }
            } or nil
        }
    end

    menu[#menu + 1] = { header = 'Close', params = { event = 'JG-Crafting:client:CloseMenu' } }
    OpenMenu(menu)
end

RegisterNetEvent('JG-Crafting:client:CloseMenu', function()
    CloseMenuUI()
    HardCleanup()
end)

RegisterNetEvent('JG-Crafting:client:SelectItem', function(data)
    if not data or not data.item or not data.benchType then return end
    local benchEntity = spawned[data.benchId]
    if not benchEntity then return end

    if data.item.preview then
        SpawnPreviewPropOnBench(benchEntity, data.item.preview)
    else
        RemovePreviewProp()
    end

    OpenMenu({
        { header = data.item.label or data.item.name, isMenuHeader = true },
        { header = 'Craft', params = { event = 'JG-Crafting:client:InputCraft', args = data } },
        { header = 'Send Email', params = { event = 'JG-Crafting:client:SendEmail', args = data.item } },
        { header = 'Back', params = { event = 'JG-Crafting:client:Back', args = data.benchType } }
    })
end)

RegisterNetEvent('JG-Crafting:client:SelectDismantleItem', function(data)
    if not data or not data.item or not data.benchType then return end
    local benchEntity = spawned[data.benchId]
    if not benchEntity then return end

    if data.item.preview then
        SpawnPreviewPropOnBench(benchEntity, data.item.preview)
    else
        RemovePreviewProp()
    end

    OpenMenu({
        { header = data.item.label or data.item.name, isMenuHeader = true },
        { header = 'Dismantle', params = { event = 'JG-Crafting:client:DoDismantle', args = data } },
        { header = 'Back', params = { event = 'JG-Crafting:client:BackDismantle', args = data.benchType } }
    })
end)

RegisterNetEvent('JG-Crafting:client:BackDismantle', function(benchType)
    RemovePreviewProp()
    OpenDismantleMenu(benchType, activeBenchId)
end)

RegisterNetEvent('JG-Crafting:client:DoDismantle', function(data)
    if not data or not data.item then return end

    local item = data.item
    local amount = PromptDismantleAmount(item)
    if not amount or amount < 1 then
        QBCore.Functions.Notify('Dismantling cancelled', 'error')
        return
    end

    data.dismantleAmount = amount

    local per = tonumber(item.time) or (Config.DefaultCraftTime or 3000)
    local duration = per * amount
    if duration > 120000 then duration = 120000 end

    ExitBenchMenuForProgress() -- ✅ closes menu + kills cam + makes player visible

    local label = ('Dismantling %sx %s'):format(amount, (item.label or item.name))

    local function onFinish()
        TriggerServerEvent('JG-Crafting:server:DismantleItem', data)

        -- ✅ progress ended, normal state (no menu restore)
        allowVisibleWhileMenu = false
        ShowLocalPlayer()
        menuOpen = false
        camActive = false
        camBenchId = nil
    end

    local function onCancel()
        QBCore.Functions.Notify('Dismantling cancelled', 'error')

        -- ✅ progress ended, normal state (no menu restore)
        allowVisibleWhileMenu = false
        ShowLocalPlayer()
        menuOpen = false
        camActive = false
        camBenchId = nil
    end

    if ProgressSystem == 'ox' and OX and OX.progressCircle then
        local ok = OX.progressCircle({
            duration = duration,
            label = label,
            disable = { move = true, combat = true },
            canCancel = true,
        })
        if ok then onFinish() else onCancel() end
        return
    end

    QBCore.Functions.Progressbar(
        'jg_dismantle_' .. (item.name or 'item'),
        label,
        duration,
        false,
        true,
        { disableMovement = true, disableCarMovement = true, disableMouse = false, disableCombat = true },
        Config.Crafting,
        {},
        {},
        onFinish,
        onCancel
    )
end)

RegisterNetEvent('JG-Crafting:client:SendEmail', function(item)
    SendRequirementsEmail(item)
end)

RegisterNetEvent('JG-Crafting:client:Back', function(benchType)
    RemovePreviewProp()
    OpenCraftMenu(benchType, activeBenchId)
end)

-- ======================
-- CRAFT QUEUE
-- ======================
RegisterNetEvent('JG-Crafting:client:InputCraft', function(data)
    InputAmount(function(amount)
        if amount and amount > 0 then
            for _ = 1, amount do
                craftingQueue[#craftingQueue + 1] = data
            end
            if not isCrafting then
                TriggerEvent('JG-Crafting:client:ProcessCraftQueue')
            end
        end
    end)
end)

RegisterNetEvent('JG-Crafting:client:ProcessCraftQueue', function()
    if isCrafting or #craftingQueue == 0 then return end
    isCrafting = true

    local data = table.remove(craftingQueue, 1)
    ExitBenchMenuForProgress()

    RemovePreviewProp()
    StopPreviewCam()
    camBenchId = nil
    camActive = false

    allowVisibleWhileMenu = true
    ShowLocalPlayer()

    local function finishSuccess()
        TriggerServerEvent('JG-Crafting:server:CraftItem', data)

            allowVisibleWhileMenu = false
            ShowLocalPlayer()
            menuOpen = false
            camActive = false
            camBenchId = nil

        isCrafting = false
        if #craftingQueue > 0 then
            TriggerEvent('JG-Crafting:client:ProcessCraftQueue')
        end
    end

    local function finishCancel()
        QBCore.Functions.Notify('Crafting cancelled', 'error')

            allowVisibleWhileMenu = false
            ShowLocalPlayer()
            menuOpen = false
            camActive = false
            camBenchId = nil

        isCrafting = false
        if #craftingQueue > 0 then
            TriggerEvent('JG-Crafting:client:ProcessCraftQueue')
        end
    end

    if ProgressSystem == 'ox' and OX and OX.progressCircle then
        local success = OX.progressCircle({
            duration = data.item.time or Config.DefaultCraftTime,
            label = 'Crafting ' .. (data.item.label or data.item.name),
            disable = { move = true, combat = true },
            anim = GetCraftAnimForSystem(),
            canCancel = true
        })
        if success then finishSuccess() else finishCancel() end
        return
    end

    QBCore.Functions.Progressbar(
        'craft_' .. (data.item.name or 'item'),
        'Crafting ' .. (data.item.label or data.item.name),
        data.item.time or Config.DefaultCraftTime,
        false, true,
        { disableMovement = true, disableCombat = true },
        Config.Crafting, {}, {},
        finishSuccess,
        finishCancel
    )
end)

RegisterNetEvent('JG-Crafting:client:RemoveCraftProp', function()
    RemovePreviewProp()
end)

-- ======================
-- BENCH SPAWNING / TARGETS
-- ======================
local function ClearBenches()
    for _, obj in pairs(spawned) do
        if DoesEntityExist(obj) then
            DeleteEntity(obj)
        end
    end
    spawned = {}
end

local function SpawnBenches()
    ClearBenches()

    for _, bench in pairs(benches) do
        local def = Config.BenchTypes and Config.BenchTypes[bench.bench_type]
        if def and LoadModel(def.prop) then
            local obj = CreateObject(joaat(def.prop), bench.x, bench.y, bench.z, false, false, false)
            SetEntityHeading(obj, bench.heading)

            ResetEntityAlpha(obj)
            SetEntityCollision(obj, true, true)

            SnapObjectToGround(obj)
            FreezeEntityPosition(obj, true)
            spawned[bench.id] = obj

            if TargetSystem == 'ox' and HasRes('ox_target') then
                exports.ox_target:addLocalEntity(obj, {
                    {
                        label = (def.mode == 'dismantle') and 'Open Dismantler Bench' or 'Open Crafting Table',
                        icon = (def.mode == 'dismantle') and 'recycle' or 'hammer',
                        canInteract = function() return HasBenchAccess(bench) end,
                        onSelect = function()
                            if not HasBenchAccess(bench) then
                                if bench.restrict_item and bench.restrict_item ~= '' then
                                    QBCore.Functions.Notify(('You cannot use this bench while carrying: %s'):format(bench.restrict_item), 'error')
                                else
                                    QBCore.Functions.Notify('You do not have access to use this bench', 'error')
                                end
                                return
                            end
                            if def.mode == 'dismantle' then
                                OpenDismantleMenu(bench.bench_type, bench.id)
                            else
                                OpenCraftMenu(bench.bench_type, bench.id)
                            end
                        end
                    },
                    {
                        label = 'Admin: Manage Bench',
                        icon = 'gear',
                        canInteract = function() return isAdmin end,
                        onSelect = function()
                            OpenAdminBenchMenu(bench)
                        end
                    }
                })
            elseif HasRes('qb-target') then
                exports['qb-target']:AddTargetEntity(obj, {
                    options = {
                        {
                            label = (def.mode == 'dismantle') and 'Open Dismantler Bench' or 'Open Crafting Table',
                            icon = (def.mode == 'dismantle') and 'fa-solid fa-recycle' or 'fa-solid fa-hammer',
                            canInteract = function() return HasBenchAccess(bench) end,
                            action = function()
                                if not HasBenchAccess(bench) then
                                    if bench.restrict_item and bench.restrict_item ~= '' then
                                        QBCore.Functions.Notify(('You cannot use this bench while carrying: %s'):format(bench.restrict_item), 'error')
                                    else
                                        QBCore.Functions.Notify('You do not have access to use this bench', 'error')
                                    end
                                    return
                                end
                                if def.mode == 'dismantle' then
                                    OpenDismantleMenu(bench.bench_type, bench.id)
                                else
                                    OpenCraftMenu(bench.bench_type, bench.id)
                                end
                            end
                        },
                        {
                            label = 'Admin: Manage Bench',
                            icon = 'fa-solid fa-gear',
                            canInteract = function() return isAdmin end,
                            action = function()
                                OpenAdminBenchMenu(bench)
                            end
                        }
                    },
                    distance = 2.0
                })
            end
        end
    end
end

-- ======================
-- LOAD FROM SERVER
-- ======================
local function RefreshBenches()
    QBCore.Functions.TriggerCallback('JG-Crafting:server:GetBenches', function(result)
        benches = result or {}
        SpawnBenches()
    end)
end

RegisterNetEvent('JG-Crafting:client:RefreshBenches', RefreshBenches)

CreateThread(function()
    Wait(1500)
    RefreshBenches()
end)

-- ======================
-- CLEANUP
-- ======================
AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    placing = false
    ClearBenches()
    if placingObj and DoesEntityExist(placingObj) then DeleteEntity(placingObj) end
    placingObj = nil
    HardCleanup()
end)
