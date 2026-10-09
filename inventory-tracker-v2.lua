-- Auto Build Hub (loader)
-- Run THIS file. It keeps the full script in memory (needed by the Inventory slot finder's server hop)
-- and also saves a copy to your workspace as "AutoBuildHub.lua".
local SRC = [==[
--[[
    AUTO BUILD  v3   (Delta / Luau)   -   one window, three tabs
      [Auto Build]  MAIN: choose a build file -> Preview -> Build Now / Stop,
                    "Auto Build on Join" switch, build settings (scale / delay / offsets)
      [Copy Build]  pick a player -> save their build as a file (shows up in Auto Build)
      [Inventory]   EXTENSION: the old Inventory Tracker (players, blocks, gold, slots, slot finder)
    Toggle: RightShift  |  "-" minimize  |  "X" close
]]

local AB = (function()
-- AUTO BUILD ON JOIN (trimmed from SPRB)
-- Automatically builds the selected .Build file after you join the game.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")
local UserInputService = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer or Players:WaitForChild("LocalPlayer", 30)

local function safeWaitChild(parent, childName, timeout)
    local started = tick()
    timeout = timeout or 30
    while parent and (tick() - started) < timeout do
        local ok, child = pcall(function()
            return parent:FindFirstChild(childName)
        end)
        if ok and child then return child end
        task.wait(0.05)
    end
    local ok, child = pcall(function()
        return parent and parent:FindFirstChild(childName)
    end)
    if ok then return child end
    return nil
end

local Character = LocalPlayer.Character
while not Character do
    Character = LocalPlayer.Character
    task.wait(0.05)
end
LocalPlayer.CharacterAdded:Connect(function(newChar)
    Character = newChar
end)

local BlocksFolder = safeWaitChild(Workspace, "Blocks", 30) or safeWaitChild(Workspace, "Block", 30)
local BlockData = safeWaitChild(LocalPlayer, "Data", 30)

------------------------------------------------------------------
-- Paths / settings
------------------------------------------------------------------
local FOLDER_PATH = "SOPERA_WORKSPACE"
local FOLDER_PREFIX = FOLDER_PATH .. "/"
local SETTINGS_PATH = "SoPeRa2_Settings.json"
local FARM_SETTINGS_PATH = "SPRB_FarmSettings.json"

local Settings = {
    buildScale = 1.0,
    buildOffsetX = 0,
    buildOffsetY = 3,
    buildOffsetZ = 0,
    skyHeight = 500,
    previewTransparency = 0.5,
    buildSpeed = 0,
    excludedBlocks = {},
    blockReplacements = {},
}

local farmSettings = { autoBuild = false, autoBuildFile = "" }

local function ensureFolder()
    if isfolder(FOLDER_PATH) then return end
    makefolder(FOLDER_PATH)
end

-- Reuse the original script's build settings (scale / offset / speed) if present
local function loadSettings()
    if not isfile(SETTINGS_PATH) then return end
    local ok, data = pcall(function() return HttpService:JSONDecode(readfile(SETTINGS_PATH)) end)
    if not ok or type(data) ~= "table" then return end
    for _, k in ipairs({"buildScale", "buildOffsetX", "buildOffsetY", "buildOffsetZ", "skyHeight", "buildSpeed", "previewTransparency"}) do
        if type(data[k]) == "number" then Settings[k] = data[k] end
    end
    Settings.buildScale = math.clamp(Settings.buildScale, 0.1, 10)
    Settings.previewTransparency = math.clamp(Settings.previewTransparency, 0, 1)
    if type(data.excludedBlocks) == "table" then Settings.excludedBlocks = data.excludedBlocks end
end

local function loadFarmSettings()
    local ok, data = pcall(function() return HttpService:JSONDecode(readfile(FARM_SETTINGS_PATH)) end)
    if ok and type(data) == "table" then
        farmSettings.autoBuild = data.autoBuild == true
        farmSettings.autoBuildFile = data.autoBuildFile or ""
    end
end

local function saveFarmSettings()
    pcall(function()
        -- merge into the existing file so other keys are not lost
        local existing = {}
        local ok, data = pcall(function() return HttpService:JSONDecode(readfile(FARM_SETTINGS_PATH)) end)
        if ok and type(data) == "table" then existing = data end
        existing.autoBuild = farmSettings.autoBuild
        existing.autoBuildFile = farmSettings.autoBuildFile
        writefile(FARM_SETTINGS_PATH, HttpService:JSONEncode(existing))
    end)
end

------------------------------------------------------------------
-- State
------------------------------------------------------------------
local isBuilding = false
local stopBuild = false
local shareBlocksOriginal = false
local recentlyPlacedBlocks = {}
local statusSink = nil

local function setStatus(text)
    if statusSink then statusSink(text) end
end

------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------
local function getBlockID(blockName)
    local c = BlockData:FindFirstChild(blockName)
    return c and c.Value or 0
end

local function getPlayerZone(player)
    for _, zone in pairs(Workspace:GetChildren()) do
        if zone:FindFirstChild("TeamColor") and zone.TeamColor.Value == player.TeamColor then
            return zone
        end
    end
end

local function cfStr(cf)
    return string.format("%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f", cf:GetComponents())
end

local function parseNums(s)
    if type(s) ~= "string" then return {} end
    local r = {}
    for p in s:gmatch("[^,%s]+") do
        local n = tonumber(p)
        if n then table.insert(r, n) end
    end
    return r
end

local function strV3(s)
    if type(s) == "string" then
        local c = {}
        for v in s:gmatch("[^,]+") do table.insert(c, tonumber(v:match("^%s*(.-)%s*$")) or 0) end
        return #c >= 3 and Vector3.new(c[1],c[2],c[3]) or Vector3.new(0,0,0)
    elseif type(s) == "table" then
        local x = tonumber(s[1] or s.X) or 0
        local y = tonumber(s[2] or s.Y) or 0
        local z = tonumber(s[3] or s.Z) or 0
        return Vector3.new(x, y, z)
    end
    return Vector3.new(0,0,0)
end

local function v3Str(v) return string.format("%.4f,%.4f,%.4f", v.X, v.Y, v.Z) end

local function strCF(s)
    if type(s) ~= "string" then return nil end
    local c = {}
    for v in s:gmatch("[^,]+") do
        local n = tonumber(v:match("^%s*(.-)%s*$"))
        if n then table.insert(c, n) end
    end
    if #c >= 12 then return CFrame.new(table.unpack(c)) end
    return nil
end

local function strCol(s)
    if type(s) ~= "string" then return Color3.new(1,1,1) end
    local c = {}
    for v in s:gmatch("[^,]+") do table.insert(c, tonumber(v) or 1) end
    if #c >= 3 then
        local r,g,b = c[1],c[2],c[3]
        if r > 1 or g > 1 or b > 1 then
            r = r/255; g = g/255; b = b/255
        end
        return Color3.new(math.clamp(r,0,1), math.clamp(g,0,1), math.clamp(b,0,1))
    end
    return Color3.new(1,1,1)
end

local function getBlockCF(bi)
    if bi.CFrame then
        if type(bi.CFrame) == "string" then
            local cf = strCF(bi.CFrame)
            if cf then return cf end
        elseif type(bi.CFrame) == "table" and #bi.CFrame >= 12 then
            return CFrame.new(table.unpack(bi.CFrame))
        end
    end

    local posRaw = bi.Position or bi.position or bi.Pos or bi.pos
    local rotRaw = bi.Rotation or bi.rotation or bi.Rot or bi.rot
    if posRaw then
        local pos = strV3(posRaw)
        if rotRaw then
            local r = {}
            if type(rotRaw) == "string" then
                for v in rotRaw:gmatch("[^,]+") do
                    local n = tonumber(v:match("^%s*(.-)%s*$"))
                    if n then table.insert(r, math.rad(n)) end
                end
            elseif type(rotRaw) == "table" then
                for i = 1, 3 do
                    local v = rotRaw[i] or rotRaw[("XYZ"):sub(i,i)]
                    table.insert(r, math.rad(tonumber(v) or 0))
                end
            end
            if #r >= 3 then
                return CFrame.new(pos) * CFrame.Angles(r[1], r[2], r[3])
            end
        end
        return CFrame.new(pos)
    end

    return CFrame.new(0, 0, 0)
end

local function cloneJsonValue(value)
    if type(value) ~= "table" then
        return value
    end
    local out = {}
    for k, v in pairs(value) do
        out[k] = cloneJsonValue(v)
    end
    return out
end

------------------------------------------------------------------
-- ASU / PRS / BH build file conversion
------------------------------------------------------------------
local ASU_MAPPED_KEYS = {
    Position = true, position = true, Pos = true, pos = true,
    Rotation = true, rotation = true, Rot = true, rot = true,
    CFrame = true, cframe = true,
    Size = true, size = true,
    Color = true, color = true, Col = true, col = true,
    Transparency = true, transparency = true,
    ShowShadow = true, showShadow = true,
    Material = true, material = true,
    Text = true, text = true,
    Anchored = true, anchored = true,
    CanCollide = true, canCollide = true,
    BoolValues = true, boolValues = true,
    NumberValues = true, numberValues = true,
    BindTable = true, bindTable = true,
    ID = true, id = true,
    SecondaryPartPosition = true, secondaryPartPosition = true,
    SecondaryPartRotation = true, secondaryPartRotation = true,
    SecCFrame = true, secCFrame = true,
    Stiffness = true, stiffness = true,
    Damping = true, damping = true,
    TargetLength = true, targetLength = true,
    MaxLength = true, maxLength = true,
    MinLength = true, minLength = true,
    Length = true, length = true,
    AngleLimit = true, angleLimit = true,
    MatchRotation = true, matchRotation = true,
    ShowConstraint = true, showConstraint = true,
    ServoTorque = true, servoTorque = true,
    ServoSpeed = true, servoSpeed = true,
    BarLength = true, barLength = true,
    WheelTorque = true, wheelTorque = true,
    MaxForce = true, maxForce = true,
    Speed = true, speed = true,
    WaitDuration = true, waitDuration = true,
    Health = true, health = true,
    ExtendLength = true, extendLength = true,
    LastDirrection = true, lastDirrection = true,
}

local function collectAsuExtras(block)
    local extras = {}
    for k, v in pairs(block) do
        if not ASU_MAPPED_KEYS[k] then
            extras[k] = cloneJsonValue(v)
        end
    end
    if next(extras) then
        return extras
    end
    return nil
end

local function mergePropertyMaps(boolValues, numberValues, extras)
    local outBool = {}
    local outNum = {}

    if type(boolValues) == "table" then
        for k, v in pairs(boolValues) do
            outBool[k] = v
        end
    end
    if type(numberValues) == "table" then
        for k, v in pairs(numberValues) do
            outNum[k] = v
        end
    end
    if type(extras) == "table" then
        for k, v in pairs(extras) do
            local vt = type(v)
            if vt == "boolean" then
                if outBool[k] == nil then
                    outBool[k] = v
                end
            elseif vt == "number" then
                if outNum[k] == nil then
                    outNum[k] = v
                end
            elseif vt == "string" then
                local lower = string.lower(v)
                if outBool[k] == nil and (lower == "true" or lower == "false") then
                    outBool[k] = lower == "true"
                elseif outNum[k] == nil then
                    local n = tonumber(v)
                    if n ~= nil then
                        outNum[k] = n
                    end
                end
            end
        end
    end

    return outBool, outNum
end

local function asuToCF(pos, rot)
    local p = {0,0,0}
    if type(pos) == "string" then
        local v = parseNums(pos)
        if #v >= 3 then p = {v[1],v[2],v[3]} end
    elseif type(pos) == "table" then p = pos end
    local r = {0,0,0}
    if type(rot) == "string" then
        local v = parseNums(rot)
        if #v >= 3 then r = {math.rad(v[1]),math.rad(v[2]),math.rad(v[3])} end
    elseif type(rot) == "table" then
        for i,v in ipairs(rot) do r[i] = math.rad(tonumber(v) or 0) end
    end
    return CFrame.new(p[1] or 0, p[2] or 0, p[3] or 0) * CFrame.Angles(r[1] or 0, r[2] or 0, r[3] or 0)
end

local function convertAsuToPRS(asuData)
    if type(asuData) ~= "table" then return nil end
    local prs = {}
    local entriesById = {}
    local pendingBindTables = {}
    local globalIdCounter = 1
    for blockName, blocks in pairs(asuData) do
        if type(blocks) == "table" then
            prs[blockName] = prs[blockName] or {}
            for _, block in ipairs(blocks) do
                if type(block) == "table" then
                    local pos = block.Position or block.position or block.Pos or block.pos
                    local rot = block.Rotation or block.rotation or block.Rot or block.rot
                    if not pos then continue end
                    local cf
                    if type(pos) == "string" or type(rot) == "string" then
                        cf = asuToCF(tostring(pos), rot and tostring(rot) or "0,0,0")
                    else
                        cf = CFrame.new(
                            (type(pos)=="table") and (pos[1] or pos.X or 0) or 0,
                            (type(pos)=="table") and (pos[2] or pos.Y or 0) or 0,
                            (type(pos)=="table") and (pos[3] or pos.Z or 0) or 0
                        ) * CFrame.Angles(
                            math.rad((type(rot)=="table") and (rot[1] or rot.X or 0) or 0),
                            math.rad((type(rot)=="table") and (rot[2] or rot.Y or 0) or 0),
                            math.rad((type(rot)=="table") and (rot[3] or rot.Z or 0) or 0)
                        )
                    end
                    local sz = block.Size or block.size
                    local col = block.Color or block.color or block.Col or block.col
                    local sizeStr = nil
                    if sz then
                        local sizeVec = Vector3.new(1,1,1)
                        if type(sz) == "string" then
                            local v = parseNums(sz)
                            if #v >= 3 then sizeVec = Vector3.new(v[1],v[2],v[3]) end
                        elseif type(sz) == "table" then
                            sizeVec = Vector3.new(sz[1] or sz.X or 1, sz[2] or sz.Y or 1, sz[3] or sz.Z or 1)
                        elseif type(sz) == "number" then
                            sizeVec = Vector3.new(sz,sz,sz)
                        end
                        sizeStr = v3Str(sizeVec)
                    end
                    local colStr2 = nil
                    if col and type(col) == "string" then
                        local cv = parseNums(col)
                        if #cv >= 3 then
                            local r2,g2,b2 = cv[1],cv[2],cv[3]
                            if r2>1 or g2>1 or b2>1 then r2=r2/255; g2=g2/255; b2=b2/255 end
                            colStr2 = string.format("%.4f,%.4f,%.4f", math.clamp(r2,0,1), math.clamp(g2,0,1), math.clamp(b2,0,1))
                        end
                    end
                    local extras = collectAsuExtras(block)
                    local mergedBoolValues, mergedNumberValues = mergePropertyMaps(block.BoolValues, block.NumberValues, extras)
                    if mergedNumberValues then
                        if mergedNumberValues.LastDirrection ~= nil and mergedNumberValues.LastDirection == nil then
                            mergedNumberValues.LastDirection = mergedNumberValues.LastDirrection
                            mergedNumberValues.LastDirrection = nil
                        end
                    end
                    local assignedId = block.ID or globalIdCounter
                    globalIdCounter = globalIdCounter + 1
                    local entry = {
                        CFrame = cfStr(cf),
                        ID = assignedId,
                        Size = sizeStr,
                        Col = colStr2,
                        Transparency = block.Transparency,
                        Anchored = block.Anchored,
                        CanCollide = block.CanCollide,
                        ShowShadow = block.ShowShadow,
                        ASUExtra = extras,
                        BoolValues = mergedBoolValues,
                        NumberValues = mergedNumberValues,
                    }

                    if block.SecondaryPartPosition then entry.SecondaryPartPosition = tostring(block.SecondaryPartPosition) end
                    if block.SecondaryPartRotation then entry.SecondaryPartRotation = tostring(block.SecondaryPartRotation) end
                    if block.Stiffness ~= nil then entry.Stiffness = block.Stiffness end
                    if block.Damping ~= nil then entry.Damping = block.Damping end
                    if block.TargetLength ~= nil then entry.TargetLength = block.TargetLength end
                    if block.MaxLength ~= nil then entry.MaxLength = block.MaxLength end
                    if block.MinLength ~= nil then entry.MinLength = block.MinLength end
                    if block.Length ~= nil then entry.Length = block.Length end
                    if block.AngleLimit ~= nil then entry.AngleLimit = block.AngleLimit end
                    if block.MatchRotation ~= nil then entry.MatchRotation = block.MatchRotation end
                    if block.ShowConstraint ~= nil then entry.ShowConstraint = block.ShowConstraint end
                    if block.ServoTorque ~= nil then entry.ServoTorque = block.ServoTorque end
                    if block.ServoSpeed ~= nil then entry.ServoSpeed = block.ServoSpeed end
                    if block.BarLength ~= nil then entry.BarLength = block.BarLength end
                    if block.WheelTorque ~= nil then entry.WheelTorque = block.WheelTorque end
                    if block.Text then entry.Text = block.Text end
                    if type(block.BindTable) == "table" then
                        entry.BindTable = cloneJsonValue(block.BindTable)
                        pendingBindTables[#pendingBindTables + 1] = entry.BindTable
                    end
                    if entry.ID ~= nil then
                        entriesById[entry.ID] = entry
                        entriesById[tostring(entry.ID)] = entry
                    end
                    table.insert(prs[blockName], entry)
                end
            end
        end
    end
    for _, bindTable in ipairs(pendingBindTables) do
        for _, row in ipairs(bindTable) do
            if type(row) == "table" then
                local target = entriesById[row[1]] or entriesById[tostring(row[1])]
                local bindName = row[2]
                if target and bindName then
                    target.NumberValues = target.NumberValues or {}
                    target.NumberValues[bindName] = tonumber(row[3]) or row[3]
                end
            end
        end
    end
    return prs
end

local function convertMcLaren(rawData)
    local converted = {}
    local invertedBinds = {}
    local idToKey = {}

    for blockName, blocks in pairs(rawData) do
        if type(blocks) == "table" and #blocks > 0 then
            local arr = {}
            for idx, bi in ipairs(blocks) do
                local entry = {}
                entry.ID = bi.ID
                entry.Transparency = bi.Transparency
                entry.Anchored = bi.Anchored
                entry.CanCollide = bi.CanCollide
                entry.CFrame = bi.CFrame
                entry.Size = bi.Size

                if bi.Color then
                    local hex = tostring(bi.Color):gsub("^#","")
                    local r = tonumber(hex:sub(1,2), 16) or 255
                    local g = tonumber(hex:sub(3,4), 16) or 255
                    local b = tonumber(hex:sub(5,6), 16) or 255
                    entry.Col = string.format("%.6f,%.6f,%.6f", r/255, g/255, b/255)
                end

                if bi.CastShadow ~= nil then
                    entry.ShowShadow = bi.CastShadow
                end

                if bi.MValues and type(bi.MValues) == "table" then
                    local numV, boolV = {}, {}
                    for k, v in pairs(bi.MValues) do
                        if type(v) == "number" then
                            numV[k] = v
                        elseif type(v) == "boolean" then
                            boolV[k] = v
                        else
                            numV[k] = v
                        end
                    end
                    if next(numV) then entry.NumberValues = numV end
                    if next(boolV) then entry.BoolValues = boolV end
                end

                if bi.SecCFrame then
                    entry.SecCFrame = bi.SecCFrame
                end

                local knownKeys = {ID=true, Transparency=true, Anchored=true, CanCollide=true,
                    CFrame=true, Size=true, Color=true, CastShadow=true, Binds=true, MValues=true, SecCFrame=true}
                local extra = {}
                for k, v in pairs(bi) do
                    if not knownKeys[k] then extra[k] = v end
                end
                if next(extra) then entry.ASUExtra = extra end
                arr[#arr+1] = entry

                if bi.ID then
                    idToKey[bi.ID] = {blockName = blockName, idx = idx}
                end

                if bi.Binds and type(bi.Binds) == "table" then
                    for _, bindRow in ipairs(bi.Binds) do
                        if type(bindRow) == "table" and bindRow[1] then
                            local sourceID = bindRow[1]
                            local bindName = bindRow[2]
                            local bindValue = bindRow[3]
                            if not invertedBinds[sourceID] then
                                invertedBinds[sourceID] = {}
                            end
                            local bindEntry = {bi.ID, bindName, bindValue}
                            table.insert(invertedBinds[sourceID], bindEntry)
                        end
                    end
                end
            end
            converted[blockName] = arr
        end
    end

    for sourceID, bindList in pairs(invertedBinds) do
        local key = idToKey[sourceID]
        if key then
            local arr = converted[key.blockName]
            if arr and arr[key.idx] then
                arr[key.idx].BindTable = bindList
            end
        end
    end

    return converted
end

local function loadBuildFromFile(fileName)
    ensureFolder()
    local json
    local searchPaths = {FOLDER_PREFIX, FOLDER_PATH .. "/", ""}
    for _, root in ipairs(searchPaths) do
        local paths = {
            root .. fileName .. ".Build",
            root .. fileName .. ".build",
            root .. fileName .. ".json",
            root .. fileName .. ".bh",
            root .. fileName .. ".BH",
            root .. fileName .. ".txt",
            root .. fileName,
        }
        for _, p in ipairs(paths) do
            if isfile(p) then json = readfile(p) ; break end
        end
        if json then break end
    end
    if not json then return nil, nil end

    json = json:match("^%s*(.-)%s*$") or json
    if json:byte(1) == 0xEF and json:byte(2) == 0xBB and json:byte(3) == 0xBF then
        json = json:sub(4)
    end

    if json:find("BuilderHub") or json:find("%[Build%]") then
        local buildLine = json:match("Build%s*=%s*(%b{})")
        if buildLine then
            local okB, decB = pcall(function() return HttpService:JSONDecode(buildLine) end)
            if okB and decB and decB.b and type(decB.b) == "table" then
                local dataObj = decB.b
                for bn, blist in pairs(dataObj) do
                    if type(blist) == "table" then
                        for _, b in ipairs(blist) do
                            if type(b) == "table" then
                                if b.p then b.Position = b.p end
                                if b.r then b.Rotation = b.r end
                                if b.cl then b.Color = b.cl end
                                if b.sz then b.Size = b.sz end
                                if b.a ~= nil then b.Anchored = b.a end
                                if b.cc ~= nil then b.CanCollide = b.cc end
                                if b.ss ~= nil then b.ShowShadow = b.ss end
                                if b.i then b.ID = b.i end
                                if b.nv then b.NumberValues = b.nv end
                                if b.bd then b.BindTable = b.bd end
                            end
                        end
                    end
                end
                return dataObj, "Asu"
            end
        end
    end

    local ok, dec = pcall(function() return HttpService:JSONDecode(json) end)
    if not ok or not dec then
        local compacted = json:gsub("\r\n", " "):gsub("\n", " "):gsub("\r", " "):gsub("%s+", " ")
        ok, dec = pcall(function() return HttpService:JSONDecode(compacted) end)
    end
    if not ok or not dec then return nil, nil end

    if type(dec) == "table" and dec.Data and type(dec.Data) == "table" and not dec.format then
        local inner = dec.Data
        for _, v in pairs(inner) do
            if type(v) == "table" and #v > 0 and type(v[1]) == "table" then
                local fb = v[1]
                if fb.CFrame and (type(fb.CFrame) == "table" or type(fb.CFrame) == "string") then
                    return convertMcLaren(inner), "BH"
                end
            end
        end
    end
    if type(dec) == "table" and #dec >= 2 then
        local cats, dataObj = dec[1], dec[2]
        if type(cats) == "table" and type(dataObj) == "table" then
            for _, blocks in pairs(dataObj) do
                if type(blocks) == "table" and #blocks > 0 then
                    local fb = blocks[1]
                    if type(fb) == "table" and (fb.Position or fb.position) then
                        return dataObj, "Asu"
                    end
                end
            end
        end
    end
    if dec.format and dec.data then
        if dec.format == "Asu" then
            return dec.data, "Asu"
        end
        return dec.data, dec.format
    end

    if type(dec) == "table" and dec.b and type(dec.b) == "table" and dec.t then
        local dataObj = dec.b
        for _, blocks in pairs(dataObj) do
            if type(blocks) == "table" and #blocks > 0 then
                local fb = blocks[1]
                if type(fb) == "table" and (fb.p or fb.cl or fb.i) then
                    for bn, blist in pairs(dataObj) do
                        if type(blist) == "table" then
                            for _, b in ipairs(blist) do
                                if type(b) == "table" then
                                    if b.p then b.Position = b.p end
                                    if b.r then b.Rotation = b.r end
                                    if b.cl then b.Color = b.cl end
                                    if b.sz then b.Size = b.sz end
                                    if b.a ~= nil then b.Anchored = b.a end
                                    if b.cc ~= nil then b.CanCollide = b.cc end
                                    if b.ss ~= nil then b.ShowShadow = b.ss end
                                    if b.i then b.ID = b.i end
                                    if b.nv then b.NumberValues = b.nv end
                                    if b.sv then
                                        b.StringValues = b.sv
                                        if b.sv.ActionName then
                                            b.NumberValues = b.NumberValues or {}
                                        end
                                    end
                                    if b.bd then b.BindTable = b.bd end
                                end
                            end
                        end
                    end
                    return dataObj, "Asu"
                end
            end
        end
    end
    if type(dec) == "table" and not dec.format and #dec == 0 then
        local hasBlockData = false
        for _, v in pairs(dec) do
            if type(v) == "table" and #v > 0 and type(v[1]) == "table" then
                hasBlockData = true
                local fb = v[1]

                if fb.CFrame and type(fb.CFrame) == "string" then
                    return dec, "PRS"
                end

                if fb.CFrame and type(fb.CFrame) == "table" then
                    for _, blocks in pairs(dec) do
                        if type(blocks) == "table" then
                            for _, b in ipairs(blocks) do
                                if type(b) == "table" then
                                    if type(b.Size) == "table" then
                                        b.Size = table.concat({b.Size[1], b.Size[2], b.Size[3]}, ", ")
                                    end
                                    if b.MValues and type(b.MValues) == "table" then
                                        local mv_num, mv_bool = {}, {}
                                        for mk, mv in pairs(b.MValues) do
                                            if type(mv) == "boolean" then
                                                mv_bool[mk] = mv
                                            else
                                                mv_num[mk] = mv
                                            end
                                        end
                                        if next(mv_num) then b.NumberValues = mv_num end
                                        if next(mv_bool) then b.BoolValues = mv_bool end
                                    end
                                    if b.Binds then b.BindTable = b.Binds end
                                    if b.CastShadow ~= nil then b.ShowShadow = b.CastShadow end
                                end
                            end
                        end
                    end
                    return dec, "PRS"
                end

                if fb.Position or fb.position or fb.Pos or fb.pos then
                    return dec, "Asu"
                end
            end
        end
        if hasBlockData then
            return dec, "Asu"
        end
    end
    return dec, "PRS"
end

------------------------------------------------------------------
-- Tools / block helpers
------------------------------------------------------------------
local function equipAllTools()
    local ch = Character or LocalPlayer.Character
    if not ch or not LocalPlayer:FindFirstChild("Backpack") then return end
    local buildToolNames = {"BuildingTool", "PaintingTool", "PropertiesTool", "ScalingTool", "DeleteTool", "TrowelTool", "BindTool"}
    for _, tool in pairs(LocalPlayer.Backpack:GetChildren()) do
        if tool:IsA("Tool") then
            local isBuild = false
            for _, bn in ipairs(buildToolNames) do
                if tool.Name == bn then isBuild = true; break end
            end
            if isBuild then
                pcall(function() tool.Parent = ch end)
            end
        end
    end
    task.wait(0.03)
    for _, tool in pairs(ch:GetChildren()) do
        if tool:IsA("Tool") then
            pcall(function() tool:Activate() end)
        end
    end
end

local function isRegularBlock(blockName)
    return blockName:sub(-5) == "Block"
end

local function calcSlots(sz)
    if not sz then return 1 end
    local vol = sz.X * sz.Y * sz.Z
    return math.max(1, math.ceil(vol / 8))
end

local function isSpecialPropBlock(name)
    return name == "Piston" or name == "Hinge" or name == "Bar" or name == "Rope" or name == "Spring"
end

local function isMoveWeldBlock(name)
    return name == "Piston" or name == "Hinge"
end

local function isRotateConstraintBlock(name)
    return name == "Bar" or name == "Rope" or name == "Spring"
end

local function buildDataToFlat(buildData, myZone)
    local regularFlat = {}
    local funcFlat = {}
    local sc = Settings.buildScale
    local off = Vector3.new(Settings.buildOffsetX, Settings.buildOffsetY, Settings.buildOffsetZ)

    for blockName, blocks in pairs(buildData) do
        if Settings.excludedBlocks[blockName] then continue end

        local effectiveName = blockName
        if Settings.blockReplacements and Settings.blockReplacements[blockName] then
            effectiveName = Settings.blockReplacements[blockName]
        end
        local regular = isRegularBlock(effectiveName)
        for _, bi in pairs(blocks) do
            local relCF = getBlockCF(bi)
            local pos = (relCF.Position * sc) + off
            local scaledCF = CFrame.new(pos) * (relCF - relCF.Position)
            local worldCF = myZone.CFrame:ToWorldSpace(scaledCF)
            local hasSz = bi.Size ~= nil and bi.Size ~= ""
            local sz = hasSz and (strV3(bi.Size) * sc) or nil
            local hasCo = bi.Col ~= nil and bi.Col ~= ""
            local col = hasCo and strCol(bi.Col) or nil
            local mergedBoolValues, mergedNumberValues = mergePropertyMaps(bi.BoolValues, bi.NumberValues, bi.ASUExtra)
            local entry = {
                Name = effectiveName,
                ID = bi.ID,
                worldCF = worldCF,
                skyWorldCF = nil,
                Relative = myZone,
                Size = sz,
                Col = col,
                hasSz = hasSz,
                hasCo = hasCo,
                isRegular = regular,
                slotCount = regular and calcSlots(sz) or 1,
                Transparency = bi.Transparency,
                Anchored = bi.Anchored,
                CanCollide = bi.CanCollide,
                ShowShadow = bi.ShowShadow,
                BoolValues = mergedBoolValues,
                NumberValues = mergedNumberValues,
                BindTable = bi.BindTable,
                ASUExtra = bi.ASUExtra,
                IsTwoPart = (bi.SecondaryPartPosition ~= nil
                    or (bi.ASUExtra and bi.ASUExtra.SecondaryPartPosition ~= nil)
                    or (bi.SecCFrame ~= nil)
                    or (bi.ASUExtra and bi.ASUExtra.SecCFrame ~= nil)),
                SecondaryWorldCF = nil,
            }
            if entry.IsTwoPart then
                local rawSecCF = bi.SecCFrame or (bi.ASUExtra and bi.ASUExtra.SecCFrame)
                if rawSecCF and type(rawSecCF) == "table" and #rawSecCF >= 12 then
                    local secRelCF = CFrame.new(table.unpack(rawSecCF))
                    local secPos = secRelCF.Position
                    local scaledSecPos = Vector3.new(secPos.X * sc, secPos.Y * sc, secPos.Z * sc) + off
                    local secRotCF = secRelCF - secRelCF.Position
                    local secWorldCF = CFrame.new(scaledSecPos) * secRotCF
                    entry.SecondaryWorldCF = myZone.CFrame:ToWorldSpace(secWorldCF)
                else
                    local rawSecPos = bi.SecondaryPartPosition or (bi.ASUExtra and bi.ASUExtra.SecondaryPartPosition)
                    local secPos = parseNums(rawSecPos)
                    local secPosV = #secPos >= 3 and Vector3.new(secPos[1]*sc, secPos[2]*sc, secPos[3]*sc) + off or Vector3.zero
                    local ppRotCF = relCF - relCF.Position
                    local secCF = CFrame.new(secPosV) * ppRotCF
                    entry.SecondaryWorldCF = myZone.CFrame:ToWorldSpace(secCF)
                end
                entry.SpringProps = {}

                local extra = bi.ASUExtra or {}
                local numV = bi.NumberValues or {}
                local function getProp(k)
                    if bi[k] ~= nil then return bi[k] end
                    if numV[k] ~= nil then return numV[k] end
                    if extra[k] ~= nil then return extra[k] end
                    return nil
                end
                local stiff = getProp("Stiffness")
                if stiff then entry.SpringProps.Stiffness = tostring(stiff) end
                local damp = getProp("Damping")
                if damp then entry.SpringProps.Damping = tostring(damp) end
                local tl = getProp("TargetLength")
                if tl then entry.SpringProps.TargetLength = tostring(tl) end
                local mxl = getProp("MaxLength")
                if mxl then entry.SpringProps.MaxLength = tostring(mxl) end
                local mnl = getProp("MinLength")
                if mnl then entry.SpringProps.MinLength = tostring(mnl) end
                local ln = getProp("Length")
                if ln then entry.SpringProps.Length = tostring(ln) end
                local al = getProp("AngleLimit")
                if al then entry.SpringProps.AngleLimit = tostring(al) end
                local mr = getProp("MatchRotation")
                if mr ~= nil then entry.SpringProps.MatchRotation = mr end
                local sc2 = getProp("ShowConstraint")
                if sc2 ~= nil then entry.SpringProps.ShowConstraint = sc2 end
            end
            if regular then
                regularFlat[#regularFlat+1] = entry
            else
                entry.skyWorldCF = worldCF
                funcFlat[#funcFlat+1] = entry
            end
        end
    end

    local AREA = 25
    local HALF = AREA / 2
    local SPACING = 3
    local COLS = math.floor(AREA / SPACING)
    local PER_LAYER = COLS * COLS
    local cx = myZone.Position.X
    local cz = myZone.Position.Z
    local startY = myZone.Position.Y + 20
    for i, v in ipairs(regularFlat) do
        local idx = i - 1
        local layer = math.floor(idx / PER_LAYER)
        local inLayer = idx % PER_LAYER
        local col = inLayer % COLS
        local row = math.floor(inLayer / COLS)
        local x = cx - HALF + col * SPACING + math.random(0, 1)
        local z = cz - HALF + row * SPACING + math.random(0, 1)
        local y = startY + layer * SPACING
        v.skyWorldCF = CFrame.new(x, y, z) * (v.worldCF - v.worldCF.Position)
    end

    local flat = {}
    for _, v in ipairs(regularFlat) do flat[#flat+1] = v end
    for _, v in ipairs(funcFlat) do flat[#flat+1] = v end
    return flat
end

------------------------------------------------------------------
-- Property helpers
------------------------------------------------------------------
local BLOCKED_PROPS = {Health=true, LastGlobalTick=true, Anchored=true}

local function firePropertyRF(propRF, ...)
    if not propRF then return false end
    local args = {...}
    task.spawn(function() pcall(function() propRF:InvokeServer(unpack(args)) end) end)
    return true
end

local function invokeWithTimeout(rf, args, timeout)
    if not rf then return false end
    local done = false
    local ok = false
    task.spawn(function()
        ok = pcall(function() rf:InvokeServer(unpack(args)) end)
        done = true
    end)
    local t0 = tick()
    while not done and tick() - t0 < (timeout or 0.5) do
        task.wait(0.05)
        if stopBuild then return false end
    end
    return ok
end

local function applyNumberValues(b, numVals, propRF)
    if not numVals or not b or type(numVals) ~= "table" then return end
    for propName, propVal in pairs(numVals) do
        if BLOCKED_PROPS[propName] then continue end
        local remotePropName = propName
        if b.Name == "Piston" and propName == "ExtendLength" then
            remotePropName = "Piston length"
        elseif b.Name == "Piston" and propName == "Speed" then
            remotePropName = "Piston speed"
        elseif b.Name == "Piston" and propName == "LastDirection" then
            remotePropName = "Piston direction"
        elseif b.Name == "Servo" and propName == "Angle" then
            remotePropName = "Servo angle"
        elseif b.Name == "Servo" and propName == "Speed" then
            remotePropName = "Servo speed"
        elseif b.Name == "JetTurbine" and propName == "Speed" then
            remotePropName = "Jet speed"
        elseif b.Name == "JetTurbine" and (propName == "Force" or propName == "JetForce" or propName == "MaxForce") then
            remotePropName = "Jet force"
        elseif b.Name == "Motor" and propName == "MaxSpeed" then
            remotePropName = "Max speed"
        elseif b.Name == "Motor" and propName == "WheelTorque" then
            remotePropName = "Wheel torque"
        elseif b.Name == "Motor" and propName == "ReverseSpin" then
            remotePropName = "Reverse spin"
        end
        local numericVal = tonumber(propVal)
        if numericVal == nil and type(propVal) == "boolean" then
            numericVal = propVal and 1 or 0
        end
        if numericVal == nil then numericVal = 0 end
        pcall(function()
            for _, target in ipairs({b, b.PPart}) do
                if target then
                    local pv = target:FindFirstChild(propName) or target:FindFirstChild(propName, true)
                    if not pv and remotePropName ~= propName then
                        pv = target:FindFirstChild(remotePropName) or target:FindFirstChild(remotePropName, true)
                    end
                    if pv then
                        if pv:IsA("NumberValue") or pv:IsA("IntValue") then
                            pv.Value = numericVal
                        elseif pv:IsA("BoolValue") then
                            pv.Value = numericVal ~= 0
                        end
                    end
                end
            end
        end)
        if propRF then
            task.spawn(function() pcall(function() propRF:InvokeServer(remotePropName, {b}, tostring(numericVal)) end) end)
        end
    end
end

local function applyBoolValues(b, boolVals, propRF)
    if not boolVals or not b or type(boolVals) ~= "table" then return end
    for propName, propVal in pairs(boolVals) do
        if BLOCKED_PROPS[propName] then continue end
        local desired = propVal == true
        local currentValue = nil
        pcall(function()
            for _, target in ipairs({b, b.PPart}) do
                if target then
                    local pv = target:FindFirstChild(propName) or target:FindFirstChild(propName, true)
                    if pv and pv:IsA("BoolValue") then
                        if currentValue == nil then currentValue = pv.Value end
                    end
                end
            end
        end)
        local needToggle = false
        if currentValue == nil then
            needToggle = desired
        else
            needToggle = currentValue ~= desired
        end
        if propRF and needToggle then
            firePropertyRF(propRF, propName, {b})
        end
    end
end

local function shouldLegacySwitch(entry)
    if not entry or not entry.block or not entry.v or entry.block.Name ~= "Switch" then return false end
    local bv = entry.v.BoolValues
    if bv and bv.Legacy == false then return false end
    return true
end

local function getPropertiesRF()
    local backpack = LocalPlayer:FindFirstChild("Backpack")
    local propTool = (Character and Character:FindFirstChild("PropertiesTool")) or (backpack and backpack:FindFirstChild("PropertiesTool"))
    if not propTool then
        equipAllTools()
        propTool = (Character and Character:FindFirstChild("PropertiesTool")) or (backpack and backpack:FindFirstChild("PropertiesTool"))
    end
    return propTool and propTool:FindFirstChild("SetPropertieRF")
end

local function applyLegacySwitches(styledList, propRF)
    propRF = propRF or getPropertiesRF()
    if not propRF then return 0 end
    local targets = {}
    for _, entry in ipairs(styledList or {}) do
        if shouldLegacySwitch(entry) then
            targets[#targets + 1] = entry.block
        end
    end
    if #targets == 0 then return 0 end
    for i = 1, #targets, 40 do
        local chunk = {}
        for j = i, math.min(i + 39, #targets) do chunk[#chunk + 1] = targets[j] end
        pcall(function() propRF:InvokeServer("Legacy", chunk) end)
        task.wait(0.05)
    end
    return #targets
end

local function activatePistonViaQueue(pistonBlock, buttonBlock)
    if not pistonBlock then return false end
    local currentChar = LocalPlayer.Character or Character
    if not currentChar then return false end
    local inputLocalScript = ReplicatedStorage:FindFirstChild("InputLocalScript")
    if not inputLocalScript then return false end
    local queueRF = inputLocalScript:FindFirstChild("QueueBlocksRequest")
    if not queueRF then return false end
    local args = {
        {
            pistonBlock,
            true,
            false,
            buttonBlock or false,
            currentChar,
            true,
            false,
            true,
            true,
            false
        }
    }
    return pcall(function()
        queueRF:FireServer(args)
    end)
end

------------------------------------------------------------------
-- Build engine
------------------------------------------------------------------
local function pasteBuild(buildData, statusCb)
    if not buildData or isBuilding then return false end
    isBuilding = true
    stopBuild = false

    local teamLeaderName = nil
    local isTeamLeader = false
    pcall(function()
        local myTeam = LocalPlayer.Team
        if myTeam then
            local tlObj = myTeam:FindFirstChild("TeamLeader")
            if tlObj then
                teamLeaderName = tlObj.Value and tostring(tlObj.Value) or tostring(tlObj.Value)
                if not teamLeaderName or teamLeaderName == "" then
                    pcall(function()
                        teamLeaderName = tlObj.Value.Name
                    end)
                end
                isTeamLeader = (teamLeaderName == LocalPlayer.Name)
            end
        end
    end)
    shareBlocksOriginal = false
    pcall(function()
        local settingsFolder = LocalPlayer:FindFirstChild("Settings")
        if settingsFolder then
            local sbVal = settingsFolder:FindFirstChild("ShareBlocks")
            if sbVal then
                shareBlocksOriginal = (sbVal.Value == true)
            end
        end
    end)
    local shareBlocks = shareBlocksOriginal
    pcall(function()
        local settingsFolder = LocalPlayer:FindFirstChild("Settings")
        if settingsFolder then
            local sbVal = settingsFolder:FindFirstChild("ShareBlocks")
            if sbVal then
                shareBlocks = (sbVal.Value == true)
            end
        end
    end)
    if isTeamLeader and not shareBlocks then
        shareBlocks = true
        pcall(function()
            local settingsFolder = LocalPlayer:FindFirstChild("Settings")
            if not settingsFolder then
                settingsFolder = Instance.new("Folder")
                settingsFolder.Name = "Settings"
                settingsFolder.Parent = LocalPlayer
            end
            local sbVal = settingsFolder:FindFirstChild("ShareBlocks")
            if not sbVal then
                sbVal = Instance.new("BoolValue")
                sbVal.Name = "ShareBlocks"
                sbVal.Parent = settingsFolder
            end
            sbVal.Value = true
        end)
    end
    local buildTargetName = LocalPlayer.Name
    if not isTeamLeader and shareBlocks and teamLeaderName then
        buildTargetName = teamLeaderName
    end

    local myZone = getPlayerZone(LocalPlayer)
    if not myZone then isBuilding = false ; return false end

    local flat = buildDataToFlat(buildData, myZone)
    local total = #flat
    if total == 0 then isBuilding = false ; return false end

    local folder = BlocksFolder:FindFirstChild(buildTargetName)
    if not folder then
        folder = Instance.new("Folder")
        folder.Name = buildTargetName
        folder.Parent = BlocksFolder
    end

    equipAllTools()
    local placeTool = Character:FindFirstChild("BuildingTool")
    local scaleTool = Character:FindFirstChild("ScalingTool")
    local paintTool = Character:FindFirstChild("PaintingTool")
    local deleteTool = Character:FindFirstChild("DeleteTool") or Character:FindFirstChild("DeletingTool")
    local bindTool = Character:FindFirstChild("BindTool")

    local function updProg(msg, pct)
        if statusCb then statusCb(msg, pct) end
    end

    local function waitForN(minN, maxWait)
        local t0 = tick()
        local lastN, sameFor = 0, 0
        local stableNeed = minN > 200 and 0.4 or 0.6
        repeat
            task.wait(0.15)
            local n = #folder:GetChildren()
            if n == lastN then sameFor = sameFor + 0.15 else sameFor = 0 end
            lastN = n
        until (lastN >= minN and sameFor >= stableNeed) or tick()-t0 > maxWait or stopBuild
        return lastN
    end

    local function findNearest(name, skyPos, list, used)
        local best, bestD = nil, math.huge
        for _, b in ipairs(list) do
            if b and b.Parent and not used[b] and b.Name == name then
                local ppart = b:FindFirstChild("PPart")
                if ppart and ppart.Parent then
                    local d = (ppart.Position - skyPos).Magnitude
                    if d < bestD then bestD = d ; best = b end
                end
            end
        end
        if best then used[best] = true end
        return best
    end

    local placeRF = placeTool and placeTool:FindFirstChild("RF")
    local scaleRF = scaleTool and scaleTool:FindFirstChild("RF")
    local paintRF = (paintTool and paintTool:FindFirstChild("RF"))
        or (LocalPlayer.Backpack:FindFirstChild("PaintingTool") and LocalPlayer.Backpack.PaintingTool:FindFirstChild("RF"))
    local deleteRF = deleteTool and deleteTool:FindFirstChild("RF")
    local propertiesTool = Character:FindFirstChild("PropertiesTool")
    local propertiesRF = propertiesTool and propertiesTool:FindFirstChild("SetPropertieRF")
    local bindRF = bindTool and bindTool:FindFirstChild("RF")
    local placedById = {}

    local function fireScale(b, sz, cf)
        if not scaleRF or not b then return end
        task.spawn(function()
            pcall(function() scaleRF:InvokeServer(b, sz, cf) end)
        end)
    end

    local function fastPlace(v)
        if not placeRF then return end
        task.spawn(function()
            pcall(function()
                if v.IsTwoPart and v.SecondaryWorldCF then
                    placeRF:InvokeServer(
                        v.Name, getBlockID(v.Name), v.Relative,
                        v.Relative.CFrame:ToObjectSpace(v.skyWorldCF),
                        true,
                        v.SecondaryWorldCF,
                        v.skyWorldCF
                    )
                else
                    placeRF:InvokeServer(
                        v.Name, getBlockID(v.Name), v.Relative,
                        v.Relative.CFrame:ToObjectSpace(v.skyWorldCF),
                        true
                    )
                end
            end)
        end)
    end

    local function fastRescale(b, cf, sz)
        if not b or not b:FindFirstChild("PPart") then return false end
        pcall(function()
            b.PPart.Size = sz
            b.PPart.CFrame = cf
        end)
        if scaleRF then
            fireScale(b, sz, cf)
            return true
        end
        return false
    end

    local function batchPaintSync(pairs_list)
        if not paintRF or #pairs_list == 0 then return end
        task.spawn(function()
            pcall(function() paintRF:InvokeServer(pairs_list) end)
            task.wait(0.5)
            for _, pair in ipairs(pairs_list) do
                local b = pair[1]
                local col = pair[2]
                if b and b.Parent and col then
                    local c3 = strCol(tostring(col))
                    pcall(function()
                        for _, desc in ipairs(b:GetDescendants()) do
                            if desc:IsA("Decal") then
                                desc.Color3 = c3
                            end
                        end
                    end)
                end
            end
        end)
    end

    local function runPlacePhase(subset, label, p0, p1)
        local BATCH = 60
        local delayTime = Settings.buildSpeed > 0 and Settings.buildSpeed * 0.01 or 0
        for i = 1, #subset do
            if stopBuild then break end
            fastPlace(subset[i])
            if delayTime > 0 and i % BATCH == 0 then
                task.wait(delayTime)
            end
        end
        updProg(label .. #subset .. " placed", p1)
    end

    local function runStylePhase(subset, baseList, used, p0, p1)
        local regularStyled = {}
        local funcStyled = {}
        local paintQueue = {}
        local unmatched = {}

        local nameGroups = {}
        for _, blk in ipairs(baseList) do
            if blk and blk.Parent and blk.Name then
                nameGroups[blk.Name] = nameGroups[blk.Name] or {}
                table.insert(nameGroups[blk.Name], blk)
            end
        end
        local nameIdx = {}

        for i = 1, #subset do
            if stopBuild then break end
            local v = subset[i]
            local b = nil

            nameIdx[v.Name] = (nameIdx[v.Name] or 0) + 1
            local group = nameGroups[v.Name]
            if group then
                for j = nameIdx[v.Name], #group do
                    local candidate = group[j]
                    if candidate and candidate.Parent and not used[candidate] and candidate:FindFirstChild("PPart") then
                        b = candidate
                        used[b] = true
                        nameIdx[v.Name] = j
                        break
                    end
                end
            end

            if not b then
                b = findNearest(v.Name, v.skyWorldCF.Position, baseList, used)
            end
            if b and b:FindFirstChild("PPart") then
                if v.ID ~= nil then
                    placedById[v.ID] = b
                    placedById[tostring(v.ID)] = b
                end
                if v.isRegular then
                    if v.hasCo and v.Col then
                        paintQueue[#paintQueue+1] = {b, v.Col}
                    end
                    if v.hasSz and v.Size then
                        fastRescale(b, v.skyWorldCF, v.Size)
                        regularStyled[#regularStyled+1] = {block=b, worldCF=v.worldCF, v=v}
                    else
                        pcall(function() b.PPart.CFrame = v.skyWorldCF end)
                        regularStyled[#regularStyled+1] = {block=b, worldCF=v.worldCF, v=v}
                    end
                else
                    funcStyled[#funcStyled+1] = {block=b, worldCF=v.worldCF, v=v}
                end
            else
                unmatched[#unmatched+1] = v
            end
        end

        if #unmatched > 0 then
            updProg("Retrying " .. #unmatched .. " unmatched blocks...", p0 + 60)
            task.wait(1.5)
            local refreshedBase = folder:GetChildren()
            local refreshedGroups = {}
            for _, blk in ipairs(refreshedBase) do
                if blk and blk.Parent and blk.Name and not used[blk] then
                    refreshedGroups[blk.Name] = refreshedGroups[blk.Name] or {}
                    table.insert(refreshedGroups[blk.Name], blk)
                end
            end
            for _, v in ipairs(unmatched) do
                if stopBuild then break end
                local b = nil
                local grp = refreshedGroups[v.Name]
                if grp then
                    for j = 1, #grp do
                        local candidate = grp[j]
                        if candidate and candidate.Parent and not used[candidate] and candidate:FindFirstChild("PPart") then
                            b = candidate
                            used[b] = true
                            break
                        end
                    end
                end
                if not b then
                    b = findNearest(v.Name, v.skyWorldCF and v.skyWorldCF.Position or v.worldCF.Position, refreshedBase, used)
                end
                if b and b:FindFirstChild("PPart") then
                    used[b] = true
                    if v.ID ~= nil then
                        placedById[v.ID] = b
                        placedById[tostring(v.ID)] = b
                    end
                    if v.isRegular then
                        if v.hasCo and v.Col then
                            paintQueue[#paintQueue+1] = {b, v.Col}
                        end
                        if v.hasSz and v.Size then
                            fastRescale(b, v.skyWorldCF, v.Size)
                            regularStyled[#regularStyled+1] = {block=b, worldCF=v.worldCF, v=v}
                        else
                            pcall(function() b.PPart.CFrame = v.skyWorldCF end)
                            regularStyled[#regularStyled+1] = {block=b, worldCF=v.worldCF, v=v}
                        end
                    else
                        funcStyled[#funcStyled+1] = {block=b, worldCF=v.worldCF, v=v}
                    end
                end
            end
        end

        updProg("Painting " .. #paintQueue .. " blocks...", p0 + 70)
        if #paintQueue > 0 then
            batchPaintSync(paintQueue)
        end

        local allStyled = {}
        for _, e in ipairs(regularStyled) do allStyled[#allStyled+1] = e end
        for _, e in ipairs(funcStyled) do allStyled[#allStyled+1] = e end

        return allStyled
    end

    local function applyBindTables(styledList, p0, p1)
        if not bindTool or not bindTool.Parent then
            bindTool = Character:FindFirstChild("BindTool") or LocalPlayer.Backpack:FindFirstChild("BindTool")
            if bindTool and bindTool.Parent ~= Character then bindTool.Parent = Character ; task.wait(0.05) end
            bindRF = bindTool and bindTool:FindFirstChild("RF")
        end
        if not bindRF then updProg("No BindTool RF, skipping binds", p0) return end
        local unbindRF = bindTool and bindTool:FindFirstChild("UnbindRF")
        local hasAnyBinds = false
        for _, e in ipairs(styledList) do
            if e.v and type(e.v.BindTable) == "table" then
                local bt = e.v.BindTable
                local cnt = 0
                for _ in pairs(bt) do cnt = cnt + 1 end
                if cnt > 0 then hasAnyBinds = true break end
            end
        end
        if not hasAnyBinds then return end
        do
            local unbound = {}
            for _, entry in ipairs(styledList) do
                if stopBuild then break end
                local bt = entry.v and entry.v.BindTable
                if type(bt) == "table" then
                    local sb = entry.block
                    if sb and unbindRF and not unbound[sb] then
                        unbound[sb] = true
                        invokeWithTimeout(unbindRF, {{sb}})
                    end
                end
            end
        end
        local done = 0
        for i, entry in ipairs(styledList) do
            if stopBuild then break end
            local bindTable = entry.v and entry.v.BindTable
            if type(bindTable) ~= "table" then continue end
            local seatBlock = entry.block
            if not seatBlock then continue end

            local isSwitchType = seatBlock.Name:find("Switch") ~= nil
                or seatBlock.Name:find("Delay") ~= nil
                or seatBlock.Name:find("Sensor") ~= nil
            local actionMap = {}
            for _, bindRow in pairs(bindTable) do
                if type(bindRow) ~= "table" then continue end
                local targetBlock = placedById[bindRow[1]] or placedById[tostring(bindRow[1])]
                local bindName = bindRow[2]
                local bindValue = tonumber(bindRow[3]) or bindRow[3]
                if not targetBlock or not bindName then continue end
                local bindObject = targetBlock:FindFirstChild(bindName) or targetBlock:FindFirstChild(bindName, true)
                if not bindObject then
                    pcall(function() bindObject = targetBlock:WaitForChild(bindName, 3) end)
                    if not bindObject then
                        pcall(function() bindObject = targetBlock:FindFirstChild(bindName, true) end)
                    end
                end
                if not bindObject then continue end

                local actionName
                if bindName == "BindUp" then
                    actionName = "Push"
                elseif bindName == "BindDown" then
                    actionName = "Pull"
                elseif bindName == "BindFire" or bindName == "BindActivate" then
                    actionName = "Activate"
                else
                    actionName = bindName:gsub("^Bind", "")
                end
                if not actionMap[actionName] then
                    actionMap[actionName] = {objs = {}, keys = {}}
                end
                table.insert(actionMap[actionName].objs, bindObject)
                table.insert(actionMap[actionName].keys, bindValue)
                done = done + 1
            end
            for actName, group in pairs(actionMap) do
                local firstArg = {[actName] = group.objs}
                local keyVal = #group.keys == 1 and group.keys[1] or group.keys

                local thirdArg = isSwitchType and {} or {[actName] = keyVal}
                if isSwitchType then
                    task.spawn(function()
                        pcall(function() bindRF:InvokeServer(firstArg, seatBlock, thirdArg, false) end)
                    end)
                else
                    invokeWithTimeout(bindRF, {firstArg, seatBlock, thirdArg, false})
                end
            end
            if i % 5 == 0 then task.wait() end
        end
        if done > 0 then updProg("Bound " .. done .. " controls", p1) end
    end

    local function applyPropertiesPhase(styledList, p0, p1, skipTransp)
        if not propertiesRF then updProg("No PropertiesTool RF, skipping props", p0) return end

        task.wait(0.05)

        local pbDone = 0
        for _, entry in ipairs(styledList) do
            if stopBuild then break end
            if not entry.block or not entry.v then continue end
            local v = entry.v
            local b = entry.block
            if b.Name == "Switch" and shouldLegacySwitch(entry) then
                v.BoolValues = v.BoolValues or {}
                if v.BoolValues.Legacy == nil then
                    v.BoolValues.Legacy = true
                end
            end

            if not ((v.NumberValues and next(v.NumberValues)) or (v.BoolValues and next(v.BoolValues)) or (v.SpringProps and next(v.SpringProps))) then continue end
            applyBoolValues(b, v.BoolValues, propertiesRF)
            applyNumberValues(b, v.NumberValues, propertiesRF)
            if v.SpringProps and next(v.SpringProps) then
                local sp = v.SpringProps
                if sp.Stiffness then firePropertyRF(propertiesRF, "Stiffness", {b}, sp.Stiffness) end
                if sp.Damping then firePropertyRF(propertiesRF, "Damping", {b}, sp.Damping) end
                if sp.TargetLength then firePropertyRF(propertiesRF, "Target length", {b}, sp.TargetLength) end
                if sp.MaxLength then firePropertyRF(propertiesRF, "Max length", {b}, sp.MaxLength) end
                if sp.MinLength then firePropertyRF(propertiesRF, "Min length", {b}, sp.MinLength) end
                if sp.Length then firePropertyRF(propertiesRF, "Length", {b}, sp.Length) end
                if sp.AngleLimit then firePropertyRF(propertiesRF, "Angle limit", {b}, sp.AngleLimit) end
                if sp.MatchRotation then firePropertyRF(propertiesRF, "Match rotation", {b}) end
                if sp.ShowConstraint then firePropertyRF(propertiesRF, "Show constraint", {b}) end
            end
            pbDone = pbDone + 1
            if pbDone % 30 == 0 then task.wait() end
        end
        updProg("Properties done", p1)
    end

    local function runMovePhase(styledList, p0, p1)
        local moveOpRF = nil
        local trowelTool = Character:FindFirstChild("TrowelTool") or LocalPlayer.Backpack:FindFirstChild("TrowelTool")
        if trowelTool then
            moveOpRF = trowelTool:FindFirstChild("OperationRF")
            if trowelTool.Parent ~= Character then trowelTool.Parent = Character ; task.wait(0.05) end
        end
        for i, entry in ipairs(styledList) do
            if stopBuild then break end
            local b = entry.block
            if b and b:FindFirstChild("PPart") then
                local cf = entry.worldCF
                local isBlock = b.Name:sub(-5) == "Block"
                pcall(function() b.PPart.CFrame = cf end)
                if isBlock and scaleRF then
                    task.spawn(function()
                        pcall(function() scaleRF:InvokeServer(b, b.PPart.Size, cf) end)
                    end)
                elseif not isBlock and moveOpRF then
                    task.spawn(function()
                        pcall(function() moveOpRF:InvokeServer({b}, cf, cf, "Move") end)
                    end)
                end
            end
        end
        updProg("Moved " .. #styledList .. " blocks", p1)
    end

    local function deleteBlock(b)
        if not b or not b.Parent then return false end
        local ok = false
        if deleteRF then
            ok = pcall(function() deleteRF:InvokeServer(b) end) or ok
            ok = pcall(function() deleteRF:InvokeServer({b}) end) or ok
            ok = pcall(function() deleteRF:InvokeServer({{b}}) end) or ok
        end
        if not ok then
            pcall(function() b:Destroy() end)
        end
        return true
    end

    equipAllTools()
    placeTool = Character:FindFirstChild("BuildingTool")
    scaleTool = Character:FindFirstChild("ScalingTool")
    paintTool = Character:FindFirstChild("PaintingTool")
    deleteTool = Character:FindFirstChild("DeleteTool") or Character:FindFirstChild("DeletingTool")
    propertiesTool = Character:FindFirstChild("PropertiesTool")
    bindTool = Character:FindFirstChild("BindTool")
    placeRF = placeTool and placeTool:FindFirstChild("RF")
    scaleRF = scaleTool and scaleTool:FindFirstChild("RF")
    paintRF = (paintTool and paintTool:FindFirstChild("RF"))
        or (LocalPlayer.Backpack:FindFirstChild("PaintingTool") and LocalPlayer.Backpack.PaintingTool:FindFirstChild("RF"))
    deleteRF = deleteTool and deleteTool:FindFirstChild("RF")
    propertiesRF = propertiesTool and propertiesTool:FindFirstChild("SetPropertieRF")
    bindRF = bindTool and bindTool:FindFirstChild("RF")

    local pistonFlat, restFlat = {}, {}
    for _, v in ipairs(flat) do
        if v.Name == "Piston" then
            pistonFlat[#pistonFlat + 1] = v
        else
            restFlat[#restFlat + 1] = v
        end
    end

    local allStyled, styledPistons = {}, {}
    if #pistonFlat > 0 and not stopBuild then
        updProg("Placing " .. #pistonFlat .. " pistons...", 0)
        runPlacePhase(pistonFlat, "Pistons ", 0, 15)
        if stopBuild then isBuilding = false ; setStatus("Stopped") ; return false end
        updProg("Waiting for pistons...", 16)
        waitForN(math.floor(#pistonFlat * 0.95), math.max(5, #pistonFlat * 0.08))
        styledPistons = runStylePhase(pistonFlat, folder:GetChildren(), {}, 18, 30)
        if stopBuild then isBuilding = false ; setStatus("Stopped") ; return false end
        updProg("Moving " .. #styledPistons .. " pistons...", 30)
        runMovePhase(styledPistons, 30, 40)
        if stopBuild then isBuilding = false ; setStatus("Stopped") ; return false end
        updProg("Piston properties (no transparency)...", 40)
        applyPropertiesPhase(styledPistons, 40, 50, true)

        local pistonsToActivate = {}
        for _, entry in ipairs(styledPistons) do
            local ld = entry.v and entry.v.NumberValues and entry.v.NumberValues.LastDirection
            if entry.block and entry.block:FindFirstChild("PPart") and ld == 1 then
                pistonsToActivate[#pistonsToActivate + 1] = {block = entry.block, worldCF = entry.worldCF, v = entry.v}
            end
        end

        if #pistonsToActivate >= 2 and not stopBuild then
            updProg("Pre-positioning pistons (moving up 10k studs)...", 48)
            local trowelTool = Character:FindFirstChild("TrowelTool") or LocalPlayer.Backpack:FindFirstChild("TrowelTool")
            if trowelTool then
                if trowelTool.Parent ~= Character then trowelTool.Parent = Character ; task.wait(0.05) end
                local moveOpRF = trowelTool:FindFirstChild("OperationRF")
                if moveOpRF then
                    for _, pd in ipairs(pistonsToActivate) do
                        local b = pd.block
                        if b and b:FindFirstChild("PPart") then
                            local currentCF = b:GetPivot()
                            local highCF = currentCF * CFrame.new(0, 10000, 0)
                            pcall(function() b.PPart.CFrame = highCF end)
                            task.spawn(function()
                                pcall(function() moveOpRF:InvokeServer({b}, currentCF, highCF, "Move") end)
                            end)
                            task.wait(0.1)
                        end
                    end
                    task.wait(0.5)

                    local pistonSet = {}
                    for _, pd in ipairs(pistonsToActivate) do pistonSet[pd.block] = true end
                    local otherPositions = {}
                    for _, b in ipairs(folder:GetChildren()) do
                        if not pistonSet[b] and b:FindFirstChild("PPart") then
                            otherPositions[#otherPositions + 1] = b.PPart.Position
                        end
                    end

                    local baseX = pistonsToActivate[1].block:FindFirstChild("PPart") and pistonsToActivate[1].block.PPart.Position.X or 0
                    local baseZ = pistonsToActivate[1].block:FindFirstChild("PPart") and pistonsToActivate[1].block.PPart.Position.Z or 0
                    local highY = pistonsToActivate[1].block:FindFirstChild("PPart") and pistonsToActivate[1].block.PPart.Position.Y or 10000

                    for idx, pd in ipairs(pistonsToActivate) do
                        local b = pd.block
                        if b and b:FindFirstChild("PPart") then
                            local targetX = baseX + (idx - 1) * 5
                            local targetZ = baseZ
                            local targetY = highY

                            local needsAdjust = true
                            local adjustOffset = 0
                            while needsAdjust and adjustOffset < 50 do
                                needsAdjust = false
                                local testPos = Vector3.new(targetX + adjustOffset, targetY, targetZ)
                                for _, op in ipairs(otherPositions) do
                                    if (testPos - op).Magnitude < 5 then
                                        needsAdjust = true
                                        adjustOffset = adjustOffset + 5
                                        break
                                    end
                                end

                                for prevIdx = 1, idx - 1 do
                                    local prevB = pistonsToActivate[prevIdx].block
                                    if prevB and prevB:FindFirstChild("PPart") then
                                        if (testPos - prevB.PPart.Position).Magnitude < 5 then
                                            needsAdjust = true
                                            adjustOffset = adjustOffset + 5
                                            break
                                        end
                                    end
                                end
                            end

                            targetX = targetX + adjustOffset
                            local currentCF = b:GetPivot()

                            local worldCF = pd.worldCF
                            local spacedCF = CFrame.new(targetX, targetY, targetZ) * (worldCF - worldCF.Position)
                            pcall(function() b.PPart.CFrame = spacedCF end)
                            task.spawn(function()
                                pcall(function() moveOpRF:InvokeServer({b}, currentCF, spacedCF, "Move") end)
                            end)
                            task.wait(0.1)
                        end
                    end
                    task.wait(0.5)
                end
            end
        end
        if #pistonsToActivate > 0 and not stopBuild and placeRF and myZone then
            updProg("Activating " .. #pistonsToActivate .. " pistons via button...", 50)
            local inputLocalScript = ReplicatedStorage:FindFirstChild("InputLocalScript")
            local queueBlocksRF = inputLocalScript and inputLocalScript:FindFirstChild("QueueBlocksRequest")
            if queueBlocksRF then
                for _, pd in ipairs(pistonsToActivate) do
                    if stopBuild then break end
                    local pistonBlock = pd.block
                    if pistonBlock and pistonBlock.Parent and pistonBlock:FindFirstChild("PPart") then
                        local foundBtn = nil
                        local bt = pd.v and pd.v.BindTable
                        if type(bt) == "table" then
                            for _, bindRow in pairs(bt) do
                                if type(bindRow) == "table" then
                                    local targetBlock = placedById[bindRow[1]] or placedById[tostring(bindRow[1])]
                                    if targetBlock and (targetBlock.Name == "Button" or targetBlock.Name == "Switch" or targetBlock.Name == "Sensor" or targetBlock.Name == "Delay") then
                                        foundBtn = targetBlock
                                        break
                                    end
                                end
                            end
                        end
                        activatePistonViaQueue(pistonBlock, foundBtn)
                        task.wait(3)
                    end
                end
                updProg("Pistons activated via QueueBlocksRequest", 55)
            else
                local buttonBlockID = getBlockID("Button")
                local activationBindTool = Character:FindFirstChild("BindTool") or LocalPlayer.Backpack:FindFirstChild("BindTool")
                local activationBindRF = activationBindTool and activationBindTool:FindFirstChild("RF")
                if buttonBlockID > 0 and activationBindRF then
                    local beforeSet = {}
                    for _, b in ipairs(folder:GetChildren()) do beforeSet[b] = true end
                    local hrp = Character:FindFirstChild("HumanoidRootPart") or myZone
                    pcall(function() placeRF:InvokeServer("Button", buttonBlockID, myZone, myZone.CFrame:ToObjectSpace(CFrame.new(hrp.Position + Vector3.new(0, 5, 0))), true) end)
                    task.wait(0.5)
                    local placedBtn
                    for _, b in ipairs(folder:GetChildren()) do
                        if not beforeSet[b] and b.Name == "Button" and b:FindFirstChild("PPart") then placedBtn = b ; break end
                    end
                    if placedBtn then
                        local pushParts, pullParts = {}, {}
                        for _, pd in ipairs(pistonsToActivate) do
                            local bUp = pd.block:FindFirstChild("BindUp") or pd.block:FindFirstChild("BindUp", true)
                            local bDn = pd.block:FindFirstChild("BindDown") or pd.block:FindFirstChild("BindDown", true)
                            if bUp then pullParts[#pullParts + 1] = bUp end
                            if bDn then pushParts[#pushParts + 1] = bDn end
                        end
                        local bindFirstArg = {}
                        if #pushParts > 0 then bindFirstArg.Push = pushParts end
                        if #pullParts > 0 then bindFirstArg.Pull = pullParts end
                        if next(bindFirstArg) then
                            invokeWithTimeout(activationBindRF, {bindFirstArg, placedBtn, {}, false})
                            task.wait(0.3)
                            for _, pd in ipairs(pistonsToActivate) do
                                if stopBuild then break end
                                activatePistonViaQueue(pd.block, placedBtn)
                                task.wait(3)
                            end
                        end
                        pcall(function() deleteBlock(placedBtn) end)
                        updProg("Pistons activated", 55)
                    else
                        updProg("Piston activation: button not found", 55)
                    end
                end
            end
        end
        for _, entry in ipairs(styledPistons) do allStyled[#allStyled + 1] = entry end
        task.wait(0.2)
    end

    local restP0 = #pistonFlat > 0 and 60 or 0
    if #restFlat > 0 and not stopBuild then
        updProg("Placing " .. #restFlat .. " blocks...", restP0)
        runPlacePhase(restFlat, "Placing ", restP0, restP0 + 20)
        if stopBuild then isBuilding = false ; setStatus("Stopped") ; return false end
        updProg("Waiting for blocks...", restP0 + 21)
        waitForN(math.floor((#pistonFlat + #restFlat) * 0.95), math.max(10, (#pistonFlat + #restFlat) * 0.04))
        local rUsed = {}
        for _, entry in ipairs(allStyled) do if entry.block then rUsed[entry.block] = true end end
        local styledRest = runStylePhase(restFlat, folder:GetChildren(), rUsed, restP0 + 23, restP0 + 50)
        if stopBuild then isBuilding = false ; setStatus("Stopped") ; return false end
        updProg("Moving " .. #styledRest .. " blocks...", restP0 + 50)
        runMovePhase(styledRest, restP0 + 50, restP0 + 55)
        if stopBuild then isBuilding = false ; setStatus("Stopped") ; return false end
        applyPropertiesPhase(styledRest, restP0 + 55, restP0 + 60)
        for _, entry in ipairs(styledRest) do allStyled[#allStyled + 1] = entry end
    end

    local legacyCount = applyLegacySwitches(allStyled, propertiesRF)
    if legacyCount > 0 then
        updProg("Legacy switches: " .. legacyCount, 94)
        task.wait(0.25)
    end

    applyBindTables(allStyled, 95, 99)
    if stopBuild then isBuilding = false ; setStatus("Stopped") ; return false end

    if #styledPistons > 0 and not stopBuild then
        updProg("Activating pistons via QueueBlocksRequest...", 99)
        for _, entry in ipairs(styledPistons) do
            if entry.block and entry.block.Parent and entry.block.Name == "Piston" and entry.block:FindFirstChild("PPart") then
                local ld = entry.v and entry.v.NumberValues and entry.v.NumberValues.LastDirection
                if ld == 1 then
                    local foundBtn = nil
                    local bt = entry.v and entry.v.BindTable
                    if type(bt) == "table" then
                        for _, bindRow in pairs(bt) do
                            if type(bindRow) == "table" then
                                local targetBlock = placedById[bindRow[1]] or placedById[tostring(bindRow[1])]
                                if targetBlock and (targetBlock.Name == "Button" or targetBlock.Name == "Switch" or targetBlock.Name == "Sensor" or targetBlock.Name == "Delay") then
                                    foundBtn = targetBlock
                                    break
                                end
                            end
                        end
                    end
                    if not foundBtn then
                        for _, otherEntry in ipairs(allStyled) do
                            if otherEntry.block and otherEntry.block.Name == "Button" and otherEntry.v and type(otherEntry.v.BindTable) == "table" then
                                local obBt = otherEntry.v.BindTable
                                for _, bindRow in pairs(obBt) do
                                    if type(bindRow) == "table" and (bindRow[1] == entry.v.ID or bindRow[1] == tostring(entry.v.ID)) then
                                        foundBtn = otherEntry.block
                                        break
                                    end
                                end
                                if foundBtn then break end
                            end
                        end
                    end
                    local ok = activatePistonViaQueue(entry.block, foundBtn)
                    if not ok then
                        pcall(function()
                            activatePistonViaQueue(entry.block, foundBtn)
                        end)
                    end
                    task.wait(3)
                end
            end
        end
    end

    if not stopBuild and #allStyled > 0 then
        updProg("Waiting for blocks to settle...", 97)
        local totalCount = #allStyled
        local maxWait = 12
        local startT = tick()
        local function countSettled()
            local settledCount = 0
            for _, entry in ipairs(allStyled) do
                local b = entry.block
                if b and b.Parent and b:FindFirstChild("PPart") then
                    local pp = b.PPart
                    local target = entry.worldCF
                    if target and (pp.Position - target.Position).Magnitude < 1.5 then
                        settledCount = settledCount + 1
                    end
                else
                    settledCount = settledCount + 1
                end
            end
            return settledCount
        end
        while countSettled() < totalCount * 0.9 and tick() - startT < maxWait do
            if stopBuild then break end
            task.wait(0.2)
        end
        updProg("Weld fix: ensuring collision ON on everything...", 97)
        if propertiesRF then
            local needCCOn = {}
            for _, entry in ipairs(allStyled) do
                if entry.block and entry.block.Parent and entry.block:FindFirstChild("PPart") and not isSpecialPropBlock(entry.block.Name) then
                    if not entry.block.PPart.CanCollide then
                        needCCOn[#needCCOn+1] = entry.block
                    end
                end
            end
            if #needCCOn > 0 then
                for i = 1, #needCCOn, 50 do
                    local chunk = {}
                    for j = i, math.min(i + 49, #needCCOn) do
                        chunk[#chunk+1] = needCCOn[j]
                    end
                    pcall(function() propertiesRF:InvokeServer("Collision", chunk) end)
                end
                task.wait(0.2)
            end
        end

        for _, entry in ipairs(allStyled) do
            if entry.v and entry.v.IsTwoPart and entry.block and entry.block.Parent and entry.block:FindFirstChild("PPart") and not isSpecialPropBlock(entry.block.Name) then
                pcall(function()
                    entry.block.PPart.CanCollide = true
                    for _, desc in ipairs(entry.block:GetDescendants()) do
                        if desc:IsA("BasePart") then
                            desc.CanCollide = true
                        end
                    end
                end)
            end
        end

        updProg("Weld fix (non-Block, batch Rotate)...", 98)
        local nonBlockList = {}
        local trowelTool = Character:FindFirstChild("TrowelTool") or LocalPlayer.Backpack:FindFirstChild("TrowelTool")
        if trowelTool and trowelTool.Parent ~= Character then trowelTool.Parent = Character ; task.wait(0.05) end
        local weldOpRF = trowelTool and trowelTool:FindFirstChild("OperationRF")

        for _, entry in ipairs(allStyled) do
            if stopBuild then break end
            if entry.block and entry.block.Parent and entry.block:FindFirstChild("PPart") then
                local isBlock = entry.block.Name:sub(-5) == "Block"
                if not isBlock then
                    nonBlockList[#nonBlockList+1] = entry
                end
            end
        end

        if #nonBlockList > 0 and weldOpRF then
            local identityCF = CFrame.new(0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1)
            local BATCH = 15

            local moveNonBlockList = {}
            local rotateConstraintList = {}
            local otherNonBlockList = {}
            for _, entry in ipairs(nonBlockList) do
                if entry.block and isMoveWeldBlock(entry.block.Name) then
                    moveNonBlockList[#moveNonBlockList + 1] = entry
                elseif entry.block and isRotateConstraintBlock(entry.block.Name) then
                    rotateConstraintList[#rotateConstraintList + 1] = entry
                else
                    otherNonBlockList[#otherNonBlockList + 1] = entry
                end
            end

            if #otherNonBlockList > 0 then
                for pass = 1, 3 do
                    if stopBuild then break end
                    updProg("Weld fix Rotate pass " .. pass .. "/3 (" .. #otherNonBlockList .. " parts)", 98)
                    local rotated = 0
                    for i = 1, #otherNonBlockList, BATCH do
                        if stopBuild then break end
                        local batch = {}
                        for j = i, math.min(i + BATCH - 1, #otherNonBlockList) do
                            local e = otherNonBlockList[j]
                            if e.block and e.block.Parent and e.block:FindFirstChild("PPart") then
                                batch[#batch+1] = e.block
                            end
                        end
                        if #batch > 0 then
                            pcall(function() weldOpRF:InvokeServer(batch, identityCF, identityCF, "Rotate") end)
                            rotated = rotated + #batch
                            task.wait(0.08)
                        end
                    end
                    task.wait(0.25)
                    if rotated == 0 then break end
                end
            end

            if #rotateConstraintList > 0 then
                updProg("Weld fix Bar/Rope/Spring (" .. #rotateConstraintList .. " parts)...", 98)
                for i = 1, #rotateConstraintList, BATCH do
                    if stopBuild then break end
                    local batch = {}
                    local batchCFs = {}
                    for j = i, math.min(i + BATCH - 1, #rotateConstraintList) do
                        local e = rotateConstraintList[j]
                        if e.block and e.block.Parent and e.block:FindFirstChild("PPart") and e.worldCF then
                            batch[#batch+1] = e.block
                            batchCFs[#batchCFs+1] = e.worldCF
                        end
                    end
                    if #batch > 0 then
                        for k, b in ipairs(batch) do
                            pcall(function()
                                local cf = batchCFs[k]
                                local rotCF = cf - cf.Position
                                b.PPart.CFrame = cf * CFrame.Angles(0, 0.01, 0)
                                weldOpRF:InvokeServer({b}, rotCF, rotCF * CFrame.Angles(0, 0.01, 0), "Rotate")
                            end)
                            task.wait(0.08)
                        end
                        task.wait(0.1)

                        for k, b in ipairs(batch) do
                            pcall(function()
                                local cf = batchCFs[k]
                                local rotCF = cf - cf.Position
                                b.PPart.CFrame = cf
                                weldOpRF:InvokeServer({b}, rotCF * CFrame.Angles(0, 0.01, 0), rotCF, "Rotate")
                            end)
                            task.wait(0.08)
                        end
                        task.wait(0.1)
                    end
                end
            end

            if #moveNonBlockList > 0 then
                updProg("Weld fix constraint blocks (" .. #moveNonBlockList .. " parts)...", 98)
                for i = 1, #moveNonBlockList, BATCH do
                    if stopBuild then break end
                    local batch = {}
                    local batchCFs = {}
                    for j = i, math.min(i + BATCH - 1, #moveNonBlockList) do
                        local e = moveNonBlockList[j]
                        if e.block and e.block.Parent and e.block:FindFirstChild("PPart") and e.worldCF then
                            batch[#batch+1] = e.block
                            batchCFs[#batchCFs+1] = e.worldCF
                        end
                    end
                    if #batch > 0 then
                        for k, b in ipairs(batch) do
                            pcall(function()
                                local cf = batchCFs[k]
                                b.PPart.CFrame = cf * CFrame.new(0, 0.1, 0)
                                weldOpRF:InvokeServer({b}, cf, cf * CFrame.new(0, 0.1, 0), "Move")
                            end)
                            task.wait(0.08)
                        end
                        task.wait(0.1)

                        for k, b in ipairs(batch) do
                            pcall(function()
                                local cf = batchCFs[k]
                                b.PPart.CFrame = cf
                                weldOpRF:InvokeServer({b}, cf * CFrame.new(0, 0.1, 0), cf, "Move")
                            end)
                            task.wait(0.08)
                        end
                        task.wait(0.1)
                    end
                end
            end

            updProg("Weld fix: restoring positions...", 98)
            for i = 1, #nonBlockList, BATCH do
                if stopBuild then break end
                local batch = {}
                local batchCFs = {}
                for j = i, math.min(i + BATCH - 1, #nonBlockList) do
                    local e = nonBlockList[j]
                    if e.block and e.block.Parent and e.block:FindFirstChild("PPart") and e.worldCF
                        and not isRotateConstraintBlock(e.block.Name) then
                        batch[#batch+1] = e.block
                        batchCFs[#batchCFs+1] = e.worldCF
                    end
                end
                if #batch > 0 then
                    for k, b in ipairs(batch) do
                        pcall(function()
                            local targetCF = batchCFs[k]
                            local currentCF = b:GetPivot()
                            b.PPart.CFrame = targetCF
                            weldOpRF:InvokeServer({b}, currentCF, targetCF, "Move")
                        end)
                        task.wait(0.05)
                    end
                    task.wait(0.05)
                end
            end
            task.wait(0.3)
        end

        if #nonBlockList > 0 and not stopBuild then
            local propTool = Character:FindFirstChild("PropertiesTool") or LocalPlayer.Backpack:FindFirstChild("PropertiesTool")
            if propTool and propTool.Parent ~= Character then propTool.Parent = Character ; task.wait(0.05) end
            propertiesRF = propTool and propTool:FindFirstChild("SetPropertieRF") or propertiesRF

            if propertiesRF then
                local ccToggleOn = {}
                for _, entry in ipairs(nonBlockList) do
                    local b = entry.block
                    local pp = b.PPart
                    local isConstraint = isSpecialPropBlock(b.Name)
                    if not isConstraint and not pp.CanCollide then
                        ccToggleOn[#ccToggleOn+1] = b
                    end
                end

                if #ccToggleOn > 0 then
                    pcall(function() propertiesRF:InvokeServer("Collision", ccToggleOn) end)
                    task.wait(0.1)
                end

                local twoPartCCToggle = {}
                for _, entry in ipairs(nonBlockList) do
                    if entry.v and entry.v.IsTwoPart and entry.block and entry.block.Parent and not isSpecialPropBlock(entry.block.Name) then
                        pcall(function()
                            entry.block.PPart.CanCollide = true
                            for _, desc in ipairs(entry.block:GetDescendants()) do
                                if desc:IsA("BasePart") then
                                    desc.CanCollide = true
                                end
                            end
                        end)
                        if not entry.block.PPart.CanCollide then
                            twoPartCCToggle[#twoPartCCToggle+1] = entry.block
                        end
                    end
                end
                if #twoPartCCToggle > 0 then
                    pcall(function() propertiesRF:InvokeServer("Collision", twoPartCCToggle) end)
                end
                task.wait(0.15)

                local nbTransp = 0
                for _, entry in ipairs(nonBlockList) do
                    if stopBuild then break end
                    local v = entry.v
                    if v and v.Transparency ~= nil and not isSpecialPropBlock(entry.block.Name) then
                        local t = tonumber(v.Transparency)
                        if t then
                            t = math.clamp(t, 0, 1)
                            pcall(function()
                                propertiesRF:InvokeServer("Transparency", {entry.block}, tostring(math.floor(t * 100 + 0.5)))
                            end)
                            pcall(function()
                                for _, desc in ipairs(entry.block:GetDescendants()) do
                                    if desc:IsA("BasePart") and desc.Name ~= "PPart" then
                                        desc.Transparency = t
                                    end
                                end
                            end)
                            nbTransp = nbTransp + 1
                        end
                    end
                    if nbTransp % 10 == 0 then task.wait(0.05) end
                end
                if nbTransp > 0 then task.wait(0.1) end
            end
            updProg("Weld fix done (" .. #nonBlockList .. " non-Block rotated)", 99)
        else
            updProg("Weld fix done", 99)
        end
    end

    if not stopBuild and propertiesRF then
        updProg("Applying all properties post-weld-fix...", 99)
        local postAnchorOn, postAnchorOff = {}, {}
        local postCcOn, postCcOff = {}, {}
        for _, entry in ipairs(allStyled) do
            if not entry.block or not entry.block.Parent or not entry.v or not entry.block:FindFirstChild("PPart") then continue end
            local v = entry.v
            local b = entry.block
            local pp = b.PPart
            local isBlock = b.Name:sub(-5) == "Block"

            local wantAnchor
            if v.Anchored ~= nil then
                wantAnchor = v.Anchored == true
            elseif not isBlock then
                wantAnchor = true
            end
            if wantAnchor ~= nil and pp.Anchored ~= wantAnchor then
                if wantAnchor then postAnchorOn[#postAnchorOn+1] = b else postAnchorOff[#postAnchorOff+1] = b end
            end

            if not isSpecialPropBlock(b.Name) then
                if v.CanCollide == false and pp.CanCollide then
                    postCcOff[#postCcOff+1] = b
                elseif v.CanCollide ~= false and not pp.CanCollide then
                    postCcOn[#postCcOn+1] = b
                end
            end
        end
        if #postAnchorOn > 0 then pcall(function() propertiesRF:InvokeServer("Anchored", postAnchorOn) end) end
        task.wait(0.05)
        if #postAnchorOff > 0 then pcall(function() propertiesRF:InvokeServer("Anchored", postAnchorOff) end) end
        task.wait(0.05)
        if #postCcOn > 0 then pcall(function() propertiesRF:InvokeServer("Collision", postCcOn) end) end
        task.wait(0.05)

        local postTranspGroups = {}
        local postShadowGroups = {}
        for _, entry in ipairs(allStyled) do
            if not entry.block or not entry.block.Parent or not entry.v or not entry.block:FindFirstChild("PPart") then continue end
            local v = entry.v
            local b = entry.block
            if v.Transparency ~= nil and not isSpecialPropBlock(b.Name) then
                local t = tonumber(v.Transparency)
                if t then
                    t = math.clamp(t, 0, 1)
                    local tStr = tostring(math.floor(t * 100 + 0.5))
                    postTranspGroups[tStr] = postTranspGroups[tStr] or {}
                    table.insert(postTranspGroups[tStr], b)
                end
            end
            if v.ShowShadow ~= nil then
                local val = v.ShowShadow == true
                local key = val and "1" or "0"
                postShadowGroups[key] = postShadowGroups[key] or {}
                table.insert(postShadowGroups[key], b)
            end
        end
        for valKey, blocks in pairs(postTranspGroups) do
            if #blocks > 0 then pcall(function() propertiesRF:InvokeServer("Transparency", blocks, valKey) end) end
            task.wait(0.05)
        end
        for valKey, blocks in pairs(postShadowGroups) do
            if #blocks > 0 then pcall(function() propertiesRF:InvokeServer("Cast shadow", blocks, valKey) end) end
            task.wait(0.05)
        end
        if #postCcOff > 0 then
            for i = 1, #postCcOff, 50 do
                local chunk = {}
                for j = i, math.min(i + 49, #postCcOff) do chunk[#chunk+1] = postCcOff[j] end
                pcall(function() propertiesRF:InvokeServer("Collision", chunk) end)
            end
            task.wait(0.1)
        end
        updProg("Properties applied", 99)
    end

    -- Transparency for Piston / Hinge / Bar / Rope / Spring (applied last)
    if not stopBuild and propertiesRF then
        local doneCount = 0
        for _, entry in ipairs(allStyled) do
            if stopBuild then break end
            local b = entry.block
            if b and entry.v and entry.v.Transparency ~= nil and isSpecialPropBlock(b.Name) and b:FindFirstChild("PPart") then
                local transparency = tonumber(entry.v.Transparency)
                if transparency then
                    transparency = math.clamp(transparency, 0, 1)
                    firePropertyRF(propertiesRF, "Transparency", {b}, tostring(math.floor(transparency * 100 + 0.5)))
                    doneCount = doneCount + 1
                end
            end
            if doneCount > 0 and doneCount % 30 == 0 then task.wait() end
        end
        if doneCount > 0 then
            task.wait(0.3)
            updProg("Constraint block transparency done (" .. doneCount .. ")", 99)
        end
    end

    if not stopBuild and propertiesRF then
        local ccOffConstraint = {}
        for _, entry in ipairs(allStyled) do
            if entry.block and entry.block.Parent and entry.block:FindFirstChild("PPart") then
                local b = entry.block
                local v = entry.v
                if isSpecialPropBlock(b.Name) and v and v.CanCollide == false then
                    if b.PPart.CanCollide then
                        ccOffConstraint[#ccOffConstraint+1] = b
                    end
                end
            end
        end
        if #ccOffConstraint > 0 then
            updProg("Disabling collision on " .. #ccOffConstraint .. " constraint blocks...", 99)
            for i = 1, #ccOffConstraint, 50 do
                local chunk = {}
                for j = i, math.min(i + 49, #ccOffConstraint) do
                    chunk[#chunk+1] = ccOffConstraint[j]
                end
                pcall(function() propertiesRF:InvokeServer("Collision", chunk) end)
            end
            task.wait(0.1)
        end
    end

    updProg(stopBuild and "Stopped" or "Done! " .. total .. " blocks", 100)
    isBuilding = false
    pcall(function()
        local settingsFolder = LocalPlayer:FindFirstChild("Settings")
        if settingsFolder then
            local sbVal = settingsFolder:FindFirstChild("ShareBlocks")
            if sbVal then
                sbVal.Value = shareBlocksOriginal
            end
        end
    end)
    return true, placedById
end

------------------------------------------------------------------
-- Save / Preview / File list / Player copy
------------------------------------------------------------------
local BuildingParts = ReplicatedStorage:FindFirstChild("BuildingParts")
local PreviewFolder = Workspace:FindFirstChild("SPRB_Preview") or Instance.new("Folder")
PreviewFolder.Name = "SPRB_Preview"
PreviewFolder.Parent = Workspace

local selectedPlayer = nil
local currentBuild = nil
local previewActive = false
local previewParts = {}
local selectionBoxes = {}
local updatePreviewButtonGlobal = nil
local updateBlocksDisplayGlobal = nil

local function colStr(c) return string.format("%.4f,%.4f,%.4f", c.R, c.G, c.B) end

local function convertPRStoBH(prsData)
    if type(prsData) ~= "table" then return nil end
    local data = {}
    for blockName, blocks in pairs(prsData) do
        if type(blocks) == "table" and #blocks > 0 then
            local arr = {}
            for idx, bi in ipairs(blocks) do
                local entry = {}
                entry.ID = bi.ID or idx
                entry.Anchored = bi.Anchored ~= false
                entry.CanCollide = bi.CanCollide ~= false
                entry.Transparency = bi.Transparency or 0
                entry.CastShadow = bi.ShowShadow ~= false
                if bi.CFrame then
                    if type(bi.CFrame) == "string" then
                        local nums = {}
                        for v in bi.CFrame:gmatch("[^,]+") do
                            local n = tonumber(v:match("^%s*(.-)%s*$"))
                            if n then table.insert(nums, n) end
                        end
                        entry.CFrame = nums
                    elseif type(bi.CFrame) == "table" then
                        entry.CFrame = bi.CFrame
                    end
                end
                if bi.Size then
                    if type(bi.Size) == "string" then
                        local nums = {}
                        for v in bi.Size:gmatch("[^,]+") do
                            local n = tonumber(v:match("^%s*(.-)%s*$"))
                            if n then table.insert(nums, n) end
                        end
                        entry.Size = nums
                    elseif type(bi.Size) == "table" then
                        entry.Size = bi.Size
                    end
                end
                if bi.Col then
                    local cv = {}
                    for v in bi.Col:gmatch("[^,]+") do
                        local n = tonumber(v:match("^%s*(.-)%s*$"))
                        if n then table.insert(cv, n) end
                    end
                    if #cv >= 3 then
                        local r = math.floor((cv[1] or 1) * 255 + 0.5)
                        local g = math.floor((cv[2] or 1) * 255 + 0.5)
                        local b = math.floor((cv[3] or 1) * 255 + 0.5)
                        entry.Color = string.format("%02x%02x%02x", r, g, b)
                    end
                end
                local mVals = {}
                if bi.NumberValues and type(bi.NumberValues) == "table" then
                    for k, v in pairs(bi.NumberValues) do mVals[k] = v end
                end
                if bi.BoolValues and type(bi.BoolValues) == "table" then
                    for k, v in pairs(bi.BoolValues) do mVals[k] = v end
                end
                if next(mVals) then entry.MValues = mVals end
                if bi.SecCFrame then
                    if type(bi.SecCFrame) == "string" then
                        local nums = {}
                        for v in bi.SecCFrame:gmatch("[^,]+") do
                            local n = tonumber(v:match("^%s*(.-)%s*$"))
                            if n then table.insert(nums, n) end
                        end
                        entry.SecCFrame = nums
                    elseif type(bi.SecCFrame) == "table" then
                        entry.SecCFrame = bi.SecCFrame
                    end
                end
                if bi.BindTable and type(bi.BindTable) == "table" then
                    local idToBlock = {}
                    for bName, bList in pairs(prsData) do
                        if type(bList) == "table" then
                            for _, bEntry in ipairs(bList) do
                                if bEntry.ID then idToBlock[bEntry.ID] = bName end
                            end
                        end
                    end
                    for _, bindRow in ipairs(bi.BindTable) do
                        if type(bindRow) == "table" and bindRow[1] then
                            local targetID = bindRow[1]
                            local bindName = bindRow[2]
                            local bindValue = bindRow[3]
                            local targetName = idToBlock[targetID]
                            if not entry.Binds then entry.Binds = {} end
                            table.insert(entry.Binds, {targetID, bindName, bindValue})
                        end
                    end
                end
                table.insert(arr, entry)
            end
            data[blockName] = arr
        end
    end
    return {Data = data, AutoBuild_Version = "v1"}
end

local function saveBuildToFile(fileName, buildData)
    ensureFolder()
    local bhData = convertPRStoBH(buildData)
    if bhData then

        local function jsonEncode(val)
            if val == nil then return "null" end
            if type(val) == "boolean" then return val and "true" or "false" end
            if type(val) == "number" then return tostring(val) end
            if type(val) == "string" then return '"' .. val:gsub('\\','\\\\'):gsub('"','\\"'):gsub('\n','\\n'):gsub('\r','\\r'):gsub('\t','\\t') .. '"' end
            if type(val) ~= "table" then return "null" end

            local isArray = true
            local maxIdx = 0
            for k in pairs(val) do
                if type(k) == "number" and k == math.floor(k) and k >= 1 then
                    if k > maxIdx then maxIdx = k end
                else
                    isArray = false; break
                end
            end
            if isArray and maxIdx == #val then

                local parts = {}
                parts[#parts+1] = '['
                for i = 1, #val do
                    if i > 1 then parts[#parts+1] = ',' end
                    parts[#parts+1] = jsonEncode(val[i])
                end
                parts[#parts+1] = ']'
                return table.concat(parts)
            else

                local parts = {}
                parts[#parts+1] = '{'
                local sortedKeys = {}
                for k in pairs(val) do sortedKeys[#sortedKeys+1] = k end
                table.sort(sortedKeys, function(a, b) return tostring(a) < tostring(b) end)
                local first = true
                for _, k in ipairs(sortedKeys) do
                    if not first then parts[#parts+1] = ',' end
                    first = false
                    parts[#parts+1] = '"' .. tostring(k) .. '":'
                    parts[#parts+1] = jsonEncode(val[k])
                end
                parts[#parts+1] = '}'
                return table.concat(parts)
            end
        end
        local ok, result = pcall(function()
            return jsonEncode(bhData)
        end)
        if ok and result then
            writefile(FOLDER_PREFIX .. fileName .. ".Build", result)
            return true, "BH"
        end
    end
    return false
end

local function copyBuild()
    if not selectedPlayer then return nil end
    local playerBlocks = BlocksFolder:FindFirstChild(selectedPlayer.Name)
    if not playerBlocks then return nil end
    local playerZone = getPlayerZone(selectedPlayer)
    if not playerZone then return nil end
    local buildData = {}
    local idCounter = 1
    local idToBlock = {}
    for _, block in pairs(playerBlocks:GetChildren()) do
        if block:FindFirstChild("PPart") then
            local ppart = block.PPart
            local relCF = playerZone.CFrame:ToObjectSpace(ppart.CFrame)
            local isBlock = block.Name:sub(-5) == "Block"
            local realTransp = ppart.Transparency
            if not isBlock then
                for _, desc in pairs(block:GetChildren()) do
                    if (desc:IsA("BasePart") or desc:IsA("UnionOperation")) and desc ~= ppart and desc.Transparency < 1 then
                        realTransp = desc.Transparency
                        break
                    end
                end
            end
            buildData[block.Name] = buildData[block.Name] or {}
            local entry = {
                CFrame = cfStr(relCF),
                Size = v3Str(ppart.Size),
                Col = colStr(ppart.Color),
                Transparency = realTransp,
                Anchored = ppart.Anchored,
                CanCollide = ppart.CanCollide,
                ShowShadow = ppart.CastShadow ~= false,
                ID = idCounter,
            }
            idCounter = idCounter + 1
            local boolVals = {}
            local numVals = {}
            for _, child in pairs(block:GetChildren()) do
                if child:IsA("BoolValue") then
                    boolVals[child.Name] = child.Value
                elseif (child:IsA("NumberValue") or child:IsA("IntValue")) and not child.Name:find("^Bind") then
                    numVals[child.Name] = child.Value
                end
            end
            for _, child in pairs(ppart:GetChildren()) do
                if child:IsA("BoolValue") then
                    boolVals[child.Name] = child.Value
                elseif (child:IsA("NumberValue") or child:IsA("IntValue")) and not child.Name:find("^Bind") then
                    numVals[child.Name] = child.Value
                end
            end
            if block.Name:find("Piston") then
                local fwd = block:GetAttribute("Forward")
                numVals.LastDirection = (fwd == true) and 1 or 0
            end
            if next(boolVals) then entry.BoolValues = boolVals end
            if next(numVals) then entry.NumberValues = numVals end
            table.insert(buildData[block.Name], entry)
            idToBlock[idCounter - 1] = block
        end
    end
    do
        local BKEYS = {"BindFire","BindActivate","BindUp","BindLeft","BindDown","BindRight"}
        local CONTROLLER_NAMES = {
            SwitchBig = true, Button = true, CarSeat = true, Switch = true,
            SensorBlock = true, RemoteController = true, PilotSeat = true,
            Lever = true, Gate = true, Delay = true,
        }
        local tBinds = {}
        for _, blk in pairs(playerBlocks:GetChildren()) do
            if blk:FindFirstChild("PPart") then
                for _, bk in ipairs(BKEYS) do
                    local bv = blk:FindFirstChild(bk)
                    if bv then
                        local keyCode = nil
                        local kc = bv:FindFirstChild("DefaultInputKeyCode")
                        if kc and (kc:IsA("IntValue") or kc:IsA("NumberValue")) then
                            keyCode = kc.Value
                        end
                        local tid = nil
                        if bv:IsA("ObjectValue") and bv.Value then
                            for id2, b2 in pairs(idToBlock) do
                                if b2 == bv.Value then tid = id2 break end
                            end
                        elseif bv:IsA("IntValue") or bv:IsA("NumberValue") then
                            for id2, b2 in pairs(idToBlock) do
                                if b2 == blk then tid = id2 break end
                            end
                        end
                        if tid then
                            tBinds[tid] = tBinds[tid] or {}
                            table.insert(tBinds[tid], {bk, keyCode or bv.Value or -1})
                        end
                    end
                end
            end
        end
        for _, blk in pairs(playerBlocks:GetChildren()) do
            if not blk:FindFirstChild("PPart") then continue end
            if not CONTROLLER_NAMES[blk.Name] then continue end
            local bid = nil
            for id2, b2 in pairs(idToBlock) do if b2 == blk then bid = id2 break end end
            if not bid then continue end
            local bEntry = nil
            for _, ent in ipairs(buildData[blk.Name] or {}) do
                if ent.ID == bid then bEntry = ent break end
            end
            if not bEntry then continue end
            local bSet = {}
            for _, ch in pairs(blk:GetChildren()) do
                if ch:IsA("ObjectValue") and ch.Value then
                    for id2, b2 in pairs(idToBlock) do if b2 == ch.Value then bSet[id2] = true break end end
                end
            end
            local pp2 = blk:FindFirstChild("PPart")
            if pp2 then
                for _, ch in pairs(pp2:GetChildren()) do
                    if ch:IsA("ObjectValue") and ch.Value then
                        for id2, b2 in pairs(idToBlock) do if b2 == ch.Value then bSet[id2] = true break end end
                    end
                end
            end
            local bt = {}
            for tid, bds in pairs(tBinds) do
                if bSet[tid] then
                    for _, bd in ipairs(bds) do table.insert(bt, {tid, bd[1], bd[2]}) end
                end
            end
            local hasT = false
            for _ in pairs(tBinds) do hasT = true break end
            if #bt == 0 and hasT then
                local asgn = {}
                for bn2, _ in pairs(buildData) do
                    for _, e2 in ipairs(buildData[bn2]) do
                        if e2.BindTable then
                            for _, r in ipairs(e2.BindTable) do if r[1] then asgn[r[1]] = true end end
                        end
                    end
                end
                for tid, bds in pairs(tBinds) do
                    if not asgn[tid] then
                        for _, bd in ipairs(bds) do table.insert(bt, {tid, bd[1], bd[2]}) end
                    end
                end
            end
            if #bt > 0 then bEntry.BindTable = bt end
        end
    end
    return buildData
end

local function getSavedBuilds()
    ensureFolder()
    local builds, seen = {}, {}
    local function scanDir(dir, depth)
        if depth > 3 then return end
        local ok, items = pcall(listfiles, dir)
        if not ok or type(items) ~= "table" then return end
        for _, fp in ipairs(items) do
            if isfolder(fp) then
                scanDir(fp, depth + 1)
            else
                local n = fp:match("([^/\\]+)%.[Bb]uild$") or fp:match("([^/\\]+)%.json$") or fp:match("([^/\\]+)%.[Bb][Hh]$")
                if n and not seen[n:lower()] then
                    table.insert(builds, n)
                    seen[n:lower()] = true
                end
            end
        end
    end
    scanDir(FOLDER_PATH, 0)
    table.sort(builds, function(a, b) return a:lower() < b:lower() end)
    return builds
end

local function clearPreview()
    for _, o in pairs(PreviewFolder:GetChildren()) do o:Destroy() end
    for _, b in pairs(selectionBoxes) do if b then pcall(function() b:Destroy() end) end end
    previewParts = {}
    selectionBoxes = {}
    previewActive = false
    selectedObjectName = nil
    if updatePreviewButtonGlobal then updatePreviewButtonGlobal() end
end

local function createPreview(buildData, selBlock)
    clearPreview()
    local myZone = getPlayerZone(LocalPlayer)
    if not myZone then return false end
    local sc = Settings.buildScale
    local off = Vector3.new(Settings.buildOffsetX, Settings.buildOffsetY, Settings.buildOffsetZ)
    local targetT = Settings.previewTransparency
    local allFadeParts = {}
    local created = 0
    for blockName, blocks in pairs(buildData) do
        local tmpl = BuildingParts:FindFirstChild(blockName)
        if not tmpl then continue end
        for _, bi in pairs(blocks) do
            local relCF = getBlockCF(bi)
            local pos = (relCF.Position * sc) + off
            local scaledCF = CFrame.new(pos) * (relCF - relCF.Position)
            local worldCF = myZone.CFrame:ToWorldSpace(scaledCF)
            local pb = tmpl:Clone()
            if pb:FindFirstChild("PPart") then

                local partOffsets = {}
                for _, d in pairs(pb:GetDescendants()) do
                    if (d:IsA("BasePart") or d:IsA("UnionOperation")) and d ~= pb.PPart then
                        partOffsets[d] = pb.PPart.CFrame:ToObjectSpace(d.CFrame)
                    end
                end
                pb.PPart.CFrame = worldCF

                for d, offsetCF in pairs(partOffsets) do
                    pcall(function() d.CFrame = worldCF * offsetCF end)
                end
                local rawSize = bi.Size or bi.size
                if rawSize and rawSize ~= "" then
                    pcall(function() pb.PPart.Size = strV3(rawSize) * sc end)
                end
                local rawCol = bi.Col or bi.Color or bi.color or bi.col
                if rawCol and rawCol ~= "" then
                    pcall(function() pb.PPart.Color = strCol(tostring(rawCol)) end)
                end
                pb.PPart.Transparency = 1
                pb.PPart.CanCollide = false
                pb.PPart.Anchored = true
                allFadeParts[#allFadeParts + 1] = pb.PPart
                for _, d in pairs(pb:GetDescendants()) do
                    if d:IsA("BasePart") or d:IsA("UnionOperation") then
                        d.Transparency = 1
                        d.CanCollide = false
                        d.Anchored = true
                        allFadeParts[#allFadeParts + 1] = d
                    end
                end
                pb.Name = blockName
                pb.Parent = PreviewFolder
                if selBlock and blockName == selBlock then
                    local hl = Instance.new("Highlight")
                    hl.Adornee = pb.PPart
                    hl.FillColor = Color3.fromRGB(255,255,255)
                    hl.OutlineColor = Color3.fromRGB(255,255,255)
                    hl.FillTransparency = 0.7
                    hl.OutlineTransparency = 0.3
                    hl.Parent = pb.PPart
                    selectionBoxes[blockName] = hl
                end
                table.insert(previewParts, pb)
                created = created + 1
                if created % 80 == 0 then task.wait() end
            end
        end
    end
    previewActive = true
    if updatePreviewButtonGlobal then updatePreviewButtonGlobal() end
    if updateBlocksDisplayGlobal then updateBlocksDisplayGlobal() end
    task.spawn(function()
        local startT = tick()
        local dur = 0.45
        while true do
            local el = tick() - startT
            local a = math.clamp(el / dur, 0, 1)
            local tVal = 1 + (targetT - 1) * a
            for _, p in ipairs(allFadeParts) do
                if p and p.Parent then p.Transparency = tVal end
            end
            if a >= 1 then break end
            if not previewActive then break end
            task.wait(0.03)
        end
    end)
    return true
end

local function updateSelectionHighlight(blockName)
    for _, b in pairs(selectionBoxes) do if b then pcall(function() b:Destroy() end) end end
    selectionBoxes = {}
    if blockName then
        for _, p in pairs(previewParts) do
            if p.Name == blockName and p:FindFirstChild("PPart") then
                local hl = Instance.new("Highlight")
                hl.Adornee = p.PPart
                hl.FillColor = Color3.fromRGB(255,255,255)
                hl.OutlineColor = Color3.fromRGB(255,255,255)
                hl.FillTransparency = 0.7
                hl.OutlineTransparency = 0.3
                hl.Parent = p.PPart
                selectionBoxes[blockName] = hl
                break
            end
        end
    end
end

------------------------------------------------------------------
-- Auto build runner
------------------------------------------------------------------
local function runAutoBuild(progressCb)
    if isBuilding then setStatus("Already building!") return end
    local name = tostring(farmSettings.autoBuildFile or ""):match("^%s*(.-)%s*$")
    if name == "" then setStatus("Enter a build file name") return end

    setStatus("Loading " .. name .. "...")
    local data, fmt = loadBuildFromFile(name)
    if not data then setStatus("File not found: " .. name) return end
    if fmt == "Asu" then data = convertAsuToPRS(data) end
    if not data or not next(data) then setStatus("Build is empty") return end

    -- wait until the plot zone exists
    local t0 = tick()
    while not getPlayerZone(LocalPlayer) and tick() - t0 < 30 do task.wait(0.5) end

    setStatus("Keep all tools equipped until build finishes")
    task.wait(0.8)

    local ok, placed, ids = pcall(function()
        return pasteBuild(data, function(msg, pct)
            setStatus(msg)
            if progressCb then progressCb(pct) end
        end)
    end)
    if not ok then
        setStatus("Build error: " .. tostring(placed))
    elseif ids then
        recentlyPlacedBlocks = {}
        for _, blk in pairs(ids) do
            if type(blk) == "userdata" and blk:FindFirstChild("PPart") then
                recentlyPlacedBlocks[blk] = true
            end
        end
    end
    stopBuild = false
    isBuilding = false
    pcall(function()
        local sf = LocalPlayer:FindFirstChild("Settings")
        if sf then
            local sb = sf:FindFirstChild("ShareBlocks")
            if sb then sb.Value = shareBlocksOriginal end
        end
    end)
end

------------------------------------------------------------------
-- Public API used by the hub UI (the old AutoBuild window was removed)
------------------------------------------------------------------
local SETTING_KEYS = {"buildScale", "buildOffsetX", "buildOffsetY", "buildOffsetZ", "skyHeight", "buildSpeed", "previewTransparency"}

local function saveSettings()
    pcall(function()
        local existing = {}
        if isfile(SETTINGS_PATH) then
            local ok, data = pcall(function() return HttpService:JSONDecode(readfile(SETTINGS_PATH)) end)
            if ok and type(data) == "table" then existing = data end
        end
        for _, k in ipairs(SETTING_KEYS) do existing[k] = Settings[k] end
        writefile(SETTINGS_PATH, HttpService:JSONEncode(existing))
    end)
end

local loadedName = nil
local API = {}
API.Settings = Settings
API.farmSettings = farmSettings
API.saveFarm = saveFarmSettings
API.saveSettings = saveSettings
API.getSavedBuilds = getSavedBuilds
API.runAutoBuild = runAutoBuild

function API.setSink(fn) statusSink = fn end
function API.setPreviewHook(fn) updatePreviewButtonGlobal = fn end
function API.isBuilding() return isBuilding end
function API.isPreviewActive() return previewActive end
function API.clearPreview() clearPreview() end
function API.loadedName() return loadedName end
function API.setSelectedPlayer(p) selectedPlayer = p end
function API.getSelectedPlayer() return selectedPlayer end

function API.requestStop()
    if isBuilding then
        stopBuild = true
        return true
    end
    return false
end

-- loads a build file into memory; returns blockCount, or nil + error text
function API.loadBuild(fName)
    local okc, lb, lf = pcall(loadBuildFromFile, fName)
    if not okc then return nil, "Load error: " .. tostring(lb) end
    if not lb then return nil, "File not found: " .. tostring(fName) end
    local data = lb
    if lf == "Asu" then data = convertAsuToPRS(lb) end
    if not data or not next(data) then return nil, "Build is empty" end
    currentBuild = data
    loadedName = fName
    local n = 0
    for _, bl in pairs(data) do
        if type(bl) == "table" then n = n + #bl end
    end
    if previewActive then createPreview(currentBuild) end
    return n
end

-- how many of each block the loaded build needs vs. how many you own
-- returns { list = {{name, need, have, parts}...}, totalNeed, totalHave, missingTypes } or nil
function API.getRequirements()
    if not currentBuild or not next(currentBuild) then return nil end
    local sc = Settings.buildScale or 1
    local list, totalNeed, totalHave, missingTypes = {}, 0, 0, 0
    for blockName, blocks in pairs(currentBuild) do
        if type(blocks) == "table" and not Settings.excludedBlocks[blockName] then
            local regular = isRegularBlock(blockName)
            local need, parts = 0, 0
            for _, bi in pairs(blocks) do
                parts = parts + 1
                local sz = nil
                if regular and type(bi) == "table" and bi.Size ~= nil and bi.Size ~= "" then
                    sz = strV3(bi.Size) * sc
                end
                need = need + (regular and calcSlots(sz) or 1)
            end
            local okh, have = pcall(getBlockID, blockName)
            have = (okh and tonumber(have)) or 0
            totalNeed = totalNeed + need
            totalHave = totalHave + math.min(have, need)
            if have < need then missingTypes = missingTypes + 1 end
            list[#list + 1] = {name = blockName, need = need, have = have, parts = parts}
        end
    end
    table.sort(list, function(a, b)
        local am, bm = a.have < a.need, b.have < b.need
        if am ~= bm then return am end
        return a.name:lower() < b.name:lower()
    end)
    return {list = list, totalNeed = totalNeed, totalHave = totalHave, missingTypes = missingTypes}
end

function API.createPreview()
    if not currentBuild or not next(currentBuild) then return false end
    return createPreview(currentBuild) and true or false
end

-- copies the selected player's build and saves it; returns blockCount, format, fileName  (or nil + error text)
function API.saveSelected(fileName)
    if not selectedPlayer then return nil, "Select a player first!" end
    local fn = tostring(fileName or ""):match("^%s*(.-)%s*$")
    if fn == "" then return nil, "Enter a file name!" end
    fn = fn:gsub('[\\/:*?"<>|]', "_")
    local ok, buildData = pcall(copyBuild)
    if not ok or not buildData or not next(buildData) then
        return nil, "No blocks found for " .. selectedPlayer.Name
    end
    local okS, saved, fmt = pcall(saveBuildToFile, fn, buildData)
    if okS and saved then
        local count = 0
        for _, bl in pairs(buildData) do
            if type(bl) == "table" then count = count + #bl end
        end
        return count, fmt, fn
    end
    return nil, "Save failed!"
end

ensureFolder()
loadSettings()
loadFarmSettings()
return API

end)()

-- ========================= CONFIG =========================
local Config = {
    -- false: BLOCKS total = exactly the sum of the rows you can see in the list
    -- true : also count hidden items (Tool / names ending in X, Y, Z, XY, XZ, YZ) like the old script
    CountFilteredItems = false,
    AutoSelectSelf = true,
    ShakeFx = true,
    ToggleKey = Enum.KeyCode.RightShift,
    AutoBuildDelay = 8,   -- seconds to wait after joining before "Auto Build on Join" starts
    ChatDbUrl = "https://build-a-boat-chat-default-rtdb.firebaseio.com",       -- World Chat database URL (Firebase Realtime Database). Leave "" to set it inside the chat tab
    ChatPoll = 2.5,       -- seconds between chat refreshes
    Glass = 0.12,   -- window transparency (0 = solid, 1 = invisible); panels/cards follow it
    Scale = 0.85,   -- max UI size (1 = full size); it also auto-shrinks on small screens

    -- ---------- Slot finder (server hop) ----------
    FindFile = "InventoryTracker_find.json",  -- local save file (executor workspace folder)
    -- The script must reload itself after every teleport. Use ONE of these:
    --   ScriptUrl : raw link of this script (loadstring(game:HttpGet(url)))
    --   ScriptFile: save this script in your executor's workspace folder with this exact name
    ScriptUrl = "",
    ScriptFile = "AutoBuildHub.lua",
    SearchSelf = false,     -- also search your own slots in each server
    ScanMinStay = 2.5,      -- seconds to wait in a server before giving up on it (if data is loaded)
    ScanTimeout = 9,        -- max seconds to wait for slot data to load in a server
    ArriveDelay = 1.5,      -- extra wait after joining a server before scanning
    ResumeWindow = 120,     -- auto-continue only if the hop happened less than this many seconds ago
    TeleportTimeout = 25,   -- seconds before a stuck teleport is retried with another server
    ServerPages = 3,        -- pages of 100 servers to read from the server list
}

-- ========================= SERVICES =========================
local Players = game:GetService("Players")
local CoreGui = game:GetService("CoreGui")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")
local StarterGui = game:GetService("StarterGui")

local GUI_NAME = "AutoBuildHubGui"

local function getGuiParent()
    local ok, ui = pcall(function()
        return gethui and gethui()
    end)
    if ok and typeof(ui) == "Instance" then
        return ui
    end
    return CoreGui
end

-- run cleanup of a previous execution, then remove leftovers
pcall(function()
    local env = getgenv and getgenv()
    if env and env.__InvTrackerCleanup then
        env.__InvTrackerCleanup()
    end
end)
for _, root in ipairs({CoreGui, getGuiParent()}) do
    pcall(function()
        for _, nm in ipairs({GUI_NAME, "InventoryTrackerGui", "AutoBuildGUI"}) do
            local old = root:FindFirstChild(nm)
            if old then old:Destroy() end
        end
    end)
end

-- ========================= THEME / HELPERS =========================
local function rgb(r, g, b) return Color3.fromRGB(r, g, b) end

local C = {
    bg     = rgb(255, 255, 255),
    panel  = rgb(242, 245, 251),
    card   = rgb(250, 251, 255),
    cardHi = rgb(219, 230, 255),
    hover  = rgb(234, 239, 250),
    line   = rgb(205, 211, 226),
    text   = rgb(28, 32, 46),
    sub    = rgb(112, 120, 144),
    accent = rgb(64, 110, 235),
    gold   = rgb(214, 150, 0),
    good   = rgb(30, 170, 90),
    warn   = rgb(214, 140, 0),
    bad    = rgb(230, 70, 70),
}

-- transparency per surface (derived from Config.Glass)
local A = {
    win   = Config.Glass,
    panel = math.min(Config.Glass + 0.18, 0.9),
    card  = math.min(Config.Glass + 0.06, 0.9),
}

local FONT, FONT_M, FONT_B = Enum.Font.Gotham, Enum.Font.GothamMedium, Enum.Font.GothamBold

local function new(class, props, parent)
    local inst = Instance.new(class)
    if props then
        for k, v in pairs(props) do inst[k] = v end
        -- surfaces get their glass transparency automatically (by colour)
        if props.BackgroundTransparency == nil and props.BackgroundColor3 then
            local bc = props.BackgroundColor3
            if bc == C.bg then
                inst.BackgroundTransparency = A.win
            elseif bc == C.panel then
                inst.BackgroundTransparency = A.panel
            elseif bc == C.card or bc == C.cardHi then
                inst.BackgroundTransparency = A.card
            end
        end
    end
    if parent then inst.Parent = parent end
    return inst
end

local function corner(inst, r)
    return new("UICorner", {CornerRadius = (r == "full") and UDim.new(1, 0) or UDim.new(0, r)}, inst)
end

local function outline(inst, color, thickness)
    return new("UIStroke", {
        Color = color, Thickness = thickness or 1,
        ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
    }, inst)
end

local function label(props, parent)
    local p = {
        BackgroundTransparency = 1, Font = FONT_M, TextColor3 = C.text, TextSize = 13,
        TextXAlignment = Enum.TextXAlignment.Left, Text = "", BorderSizePixel = 0,
    }
    for k, v in pairs(props) do p[k] = v end
    return new("TextLabel", p, parent)
end

local function tween(inst, t, props)
    TweenService:Create(inst, TweenInfo.new(t, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), props):Play()
end

-- springy tween: overshoots a little, then settles
local function bounce(inst, t, props)
    TweenService:Create(inst, TweenInfo.new(t, Enum.EasingStyle.Back, Enum.EasingDirection.Out), props):Play()
end

-- ========================= GLOBAL STATE =========================
local connections = {}        -- connections that live as long as the GUI
local function track(conn)
    table.insert(connections, conn)
    return conn
end

local liveConnections = {}    -- connections of the currently displayed list
local rainbowElements = {}    -- [instance] = "Text" | "Image" | "Bg" | "Stroke"
local shakingFrames = {}      -- [frame] = true

local trackers = {}           -- [player] = tracker
local playerRows = {}         -- [player] = row record
local selectedPlayer = nil
local activeTracker = nil
local onActiveStatsChanged = nil

local rowList = {}            -- rows of the displayed list
local rowByItem = {}          -- [ValueBase] = row record
local currentTab = "Items"
local sortMode = "Amount"
local loadToken = 0
local listLoading = false

-- ========================= SCREEN GUI =========================
local ScreenGui = new("ScreenGui", {
    Name = GUI_NAME,
    ResetOnSpawn = false,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
    DisplayOrder = 999,
    IgnoreGuiInset = true,
})
pcall(function()
    if syn and syn.protect_gui then syn.protect_gui(ScreenGui) end
end)
ScreenGui.Parent = getGuiParent()

-- ========================= NUMBER FORMAT =========================
local function commas(n)
    if n ~= n or n == math.huge or n == -math.huge then return tostring(n) end
    local neg = n < 0
    n = math.abs(n)
    local s
    if n % 1 == 0 then
        s = string.format("%.0f", n)
    else
        s = string.format("%.2f", n)
    end
    local int, frac = s:match("^(%d+)(.*)$")
    int = int:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
    if frac ~= "" then
        frac = frac:gsub("0+$", "")
        if frac == "." then frac = "" end
    end
    return (neg and "-" or "") .. int .. frac
end

local SHORT_UNITS = {{1e12, "T"}, {1e9, "B"}, {1e6, "M"}, {1e3, "K"}}
local function short(n)
    local a = math.abs(n)
    for _, u in ipairs(SHORT_UNITS) do
        if a >= u[1] then
            local s = string.format("%.2f", n / u[1]):gsub("%.?0+$", "")
            return s .. u[2]
        end
    end
    return commas(n)
end

local function toNumber(raw)
    if type(raw) == "number" or type(raw) == "string" then
        return tonumber(raw)
    end
    return nil
end

-- ========================= RANKS =========================
local RANKS = {
    {min = 0,        name = "Starter",     color = rgb(130, 135, 150)},
    {min = 100,      name = "Little Pro",  color = rgb(20, 180, 90)},
    {min = 1000,     name = "Pro",         color = rgb(214, 160, 0)},
    {min = 5000,     name = "Very Pro",    color = rgb(230, 50, 50)},
    {min = 20000,    name = "Serious Pro", color = rgb(150, 50, 230)},
    {min = 100000,   name = "OG",          color = rgb(240, 110, 0)},
    {min = 1000000,  name = "Hacker",      color = rgb(0, 185, 90)},
    {min = 10000000, name = "GOD",         color = rgb(255, 255, 255), rainbow = true},
}

local function getRank(total)
    local idx = 1
    for i, r in ipairs(RANKS) do
        if total >= r.min then idx = i end
    end
    return RANKS[idx], RANKS[idx + 1]
end

local function styleRankLabel(lbl, rank)
    rainbowElements[lbl] = nil
    if rank.rainbow then
        lbl.TextStrokeTransparency = 1
        rainbowElements[lbl] = "Text"
        return
    end
    lbl.TextColor3 = rank.color
    if rank.stroke then
        lbl.TextStrokeColor3 = rank.stroke
        lbl.TextStrokeTransparency = 0
    else
        lbl.TextStrokeTransparency = 1
    end
end

local function styleRankStroke(stroke, rank)
    rainbowElements[stroke] = nil
    if rank.rainbow then
        rainbowElements[stroke] = "Stroke"
    else
        stroke.Color = rank.color
    end
end

-- ========================= RAINBOW / SHAKE LOOP =========================
task.spawn(function()
    local rng = Random.new()
    while ScreenGui.Parent do
        local color = Color3.fromHSV((os.clock() % 1.5) / 1.5, 0.9, 0.85)
        for el, mode in pairs(rainbowElements) do
            if el.Parent then
                if mode == "Text" then
                    el.TextColor3 = color
                elseif mode == "Image" then
                    el.ImageColor3 = color
                elseif mode == "Bg" then
                    el.BackgroundColor3 = color
                elseif mode == "Stroke" then
                    el.Color = color
                end
            else
                rainbowElements[el] = nil
            end
        end
        for frame in pairs(shakingFrames) do
            if frame.Parent then
                frame.Position = UDim2.new(0, rng:NextNumber(-1.5, 1.5), 0, rng:NextNumber(-1.5, 1.5))
            else
                shakingFrames[frame] = nil
            end
        end
        task.wait()
    end
end)

-- ========================= AVATARS =========================
local thumbCache = {}

local function loadAvatar(img, userId, kind)
    local key = kind .. tostring(userId)
    img:SetAttribute("AvatarKey", key)
    local cached = thumbCache[key]
    if cached then
        img.Image = cached
        return
    end
    img.Image = ""
    task.spawn(function()
        for _ = 1, 3 do
            local ok, content = pcall(function()
                local ttype = (kind == "bust") and Enum.ThumbnailType.AvatarBust or Enum.ThumbnailType.HeadShot
                local tsize = (kind == "bust") and Enum.ThumbnailSize.Size180x180 or Enum.ThumbnailSize.Size100x100
                return (Players:GetUserThumbnailAsync(userId, ttype, tsize))
            end)
            if ok and content and content ~= "" then
                thumbCache[key] = content
                if img.Parent and img:GetAttribute("AvatarKey") == key then
                    img.Image = content
                end
                return
            end
            task.wait(1.5)
        end
    end)
end

-- ========================= GAME DATA HELPERS =========================
local function isFiltered(itemName)
    if string.find(itemName, "Tool") then
        return true
    end
    local badSuffixes = {"XY", "XZ", "YZ", "X", "Y", "Z"}
    for _, suffix in ipairs(badSuffixes) do
        if string.sub(itemName, -string.len(suffix)) == suffix then
            return true
        end
    end
    return false
end

local function isGoldName(name)
    return string.find(string.lower(name), "gold", 1, true) ~= nil
end

local templateCache = {}
local function getInventoryTemplateData(itemName)
    local cached = templateCache[itemName]
    if cached then return cached[1], cached[2] end

    local typeIconId, frameImageId = "", ""
    local lp = Players.LocalPlayer
    local node = lp and lp:FindFirstChildOfClass("PlayerGui")
    node = node and node:FindFirstChild("BuildGui")
    node = node and node:FindFirstChild("InventoryFrame")
    node = node and node:FindFirstChild("ScrollingFrame")
    node = node and node:FindFirstChild("BlocksFrame")
    local tpl = node and node:FindFirstChild(itemName)
    if not tpl then
        -- not in BlocksFrame (functional items live elsewhere): search the whole inventory GUI
        local inv = lp and lp:FindFirstChildOfClass("PlayerGui")
        inv = inv and inv:FindFirstChild("BuildGui")
        inv = inv and inv:FindFirstChild("InventoryFrame")
        tpl = inv and inv:FindFirstChild(itemName, true)
    end
    if tpl then
        local ti = tpl:FindFirstChild("TypeIcon", true)
        if ti and ti:IsA("GuiObject") then
            local okI, img = pcall(function() return ti.Image end)
            if okI and type(img) == "string" then typeIconId = img end
        end
        if tpl:IsA("ImageButton") or tpl:IsA("ImageLabel") then frameImageId = tpl.Image end
        if typeIconId ~= "" or frameImageId ~= "" then
            templateCache[itemName] = {typeIconId, frameImageId}
        end
    end
    return typeIconId, frameImageId
end

-- colour tiers for numbers (same thresholds as the old script)
local function applyValueStyle(row, valueLabel, images, num)
    rainbowElements[valueLabel] = nil
    shakingFrames[row] = nil
    for _, img in ipairs(images) do
        rainbowElements[img] = nil
        img.ImageColor3 = Color3.new(1, 1, 1)
    end
    valueLabel.TextStrokeTransparency = 1
    row.Position = UDim2.new(0, 0, 0, 0)
    row.BackgroundColor3 = C.card

    if num == nil then
        valueLabel.TextColor3 = C.text
        return
    end

    if num >= 10000000 then
        rainbowElements[valueLabel] = "Text"
        if Config.ShakeFx then shakingFrames[row] = true end
        for _, img in ipairs(images) do rainbowElements[img] = "Image" end
    elseif num < 10 then
        valueLabel.TextColor3 = rgb(0, 170, 80)
    elseif num < 100 then
        valueLabel.TextColor3 = rgb(205, 150, 0)
    elseif num < 1000 then
        valueLabel.TextColor3 = rgb(225, 45, 45)
    elseif num < 10000 then
        valueLabel.TextColor3 = rgb(150, 45, 230)
    elseif num < 100000 then
        valueLabel.TextColor3 = rgb(240, 110, 0)
        valueLabel.TextStrokeColor3 = rgb(0, 0, 0)
        valueLabel.TextStrokeTransparency = 0.55
    elseif num < 1000000 then
        valueLabel.TextColor3 = rgb(255, 255, 255)
        valueLabel.TextStrokeColor3 = rgb(0, 0, 0)
        valueLabel.TextStrokeTransparency = 0
    else
        rainbowElements[valueLabel] = "Text"
    end
end

-- ========================= PER-PLAYER TRACKER =========================
local function recompute(tr)
    local data = tr.player:FindFirstChild("Data")
    local s = {blocks = 0, gold = 0, types = 0, kinds = 0, hasGold = false, hasData = data ~= nil}
    if data then
        for _, v in ipairs(data:GetChildren()) do
            if v:IsA("ValueBase") then
                local n = toNumber(v.Value)
                if n then
                    if isGoldName(v.Name) then
                        s.gold = s.gold + n
                        s.hasGold = true
                    elseif Config.CountFilteredItems or not isFiltered(v.Name) then
                        s.blocks = s.blocks + n
                        s.kinds = s.kinds + 1
                        if n > 0 then s.types = s.types + 1 end
                    end
                end
            end
        end
    end
    tr.stats = s
    for _, fn in ipairs(tr.listeners) do fn(s) end
    if tr == activeTracker and onActiveStatsChanged then
        onActiveStatsChanged(s)
    end
end

local function markDirty(tr)
    if tr.dirty or tr.dead then return end
    tr.dirty = true
    task.defer(function()
        tr.dirty = false
        if not tr.dead then recompute(tr) end
    end)
end

local function hookValue(tr, v)
    if tr.hooked[v] or not v:IsA("ValueBase") then return end
    tr.hooked[v] = true
    table.insert(tr.conns, v.Changed:Connect(function() markDirty(tr) end))
end

local function hookData(tr, data)
    for _, v in ipairs(data:GetChildren()) do hookValue(tr, v) end
    table.insert(tr.conns, data.ChildAdded:Connect(function(v)
        hookValue(tr, v)
        markDirty(tr)
    end))
    table.insert(tr.conns, data.ChildRemoved:Connect(function() markDirty(tr) end))
    markDirty(tr)
end

local function startTracker(player)
    local tr = {
        player = player,
        stats = {blocks = 0, gold = 0, types = 0, kinds = 0, hasGold = false, hasData = false},
        conns = {}, hooked = {}, listeners = {}, dirty = false, dead = false,
    }
    trackers[player] = tr
    local data = player:FindFirstChild("Data")
    if data then hookData(tr, data) end
    recompute(tr)
    table.insert(tr.conns, player.ChildAdded:Connect(function(child)
        if child.Name == "Data" then hookData(tr, child) end
    end))
    return tr
end

local function stopTracker(player)
    local tr = trackers[player]
    if not tr then return end
    tr.dead = true
    for _, c in ipairs(tr.conns) do c:Disconnect() end
    trackers[player] = nil
end

-- ========================= UI: WINDOW =========================
local WIN_W, WIN_H, TITLE_H = 740, 700, 46
local MARGIN = 10
local camera = workspace.CurrentCamera
local viewport = camera and camera.ViewportSize or Vector2.new(1280, 720)
local uiScale = math.clamp(math.min(viewport.X / (WIN_W + 60), viewport.Y / (WIN_H + 50), Config.Scale), 0.45, 1)

-- anchored at the bottom-left corner
local Window = new("Frame", {
    Name = "Window",
    AnchorPoint = Vector2.new(0.5, 0.5),
    Size = UDim2.new(0, WIN_W, 0, WIN_H),
    Position = UDim2.new((MARGIN + WIN_W * uiScale / 2) / viewport.X, 0, 1 - (MARGIN + WIN_H * uiScale / 2) / viewport.Y, 0),
    BackgroundColor3 = C.bg, BorderSizePixel = 0, ClipsDescendants = true, Active = true,
}, ScreenGui)
corner(Window, 12)
local WindowStroke = outline(Window, C.line, 1)
local WindowScale = new("UIScale", {Scale = uiScale * 0.8}, Window)
local DragSpring

local TitleBar = new("Frame", {
    Name = "TitleBar", Size = UDim2.new(1, 0, 0, TITLE_H),
    BackgroundTransparency = 1, BorderSizePixel = 0,
}, Window)
new("Frame", {
    AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 0, 1, 0), Size = UDim2.new(1, 0, 0, 1),
    BackgroundColor3 = C.line, BackgroundTransparency = 0.4, BorderSizePixel = 0,
}, TitleBar)

local Logo = new("Frame", {
    Size = UDim2.new(0, 10, 0, 10), Position = UDim2.new(0, 14, 0.5, -5),
    BackgroundColor3 = C.accent, BorderSizePixel = 0,
}, TitleBar)
corner(Logo, "full")
label({Text = "Auto Build", Font = FONT_B, TextSize = 16,
    Position = UDim2.new(0, 32, 0, 0), Size = UDim2.new(0, 110, 1, 0)}, TitleBar)
label({Text = "v3  |  build  /  copy  /  chat  /  inventory", TextSize = 11, TextColor3 = C.sub,
    Position = UDim2.new(0, 142, 0, 0), Size = UDim2.new(0, 260, 1, 0)}, TitleBar)

-- soft circle that expands from the centre of a button / row and fades out
local function ripple(btn)
    btn.ClipsDescendants = true
    local w, h = btn.AbsoluteSize.X, btn.AbsoluteSize.Y
    local d = math.max(w, h) / math.max(WindowScale.Scale, 0.1) * 1.25
    local c = new("Frame", {
        AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0.5, 0),
        Size = UDim2.new(0, 0, 0, 0), BackgroundColor3 = C.accent, BackgroundTransparency = 0.6,
        BorderSizePixel = 0, ZIndex = btn.ZIndex + 1,
    }, btn)
    corner(c, "full")
    local t = TweenService:Create(c, TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
        {Size = UDim2.new(0, d, 0, d), BackgroundTransparency = 1})
    t.Completed:Connect(function() c:Destroy() end)
    t:Play()
end

-- hover = gentle grow, press = shrink + ripple, release = springy bounce back
local function pressFx(btn)
    btn.ClipsDescendants = true
    local sc = new("UIScale", {Scale = 1}, btn)
    local hover, rest = false, 1
    track(btn.MouseEnter:Connect(function()
        hover = true
        local w = btn.AbsoluteSize.X / math.max(WindowScale.Scale, 0.1)
        rest = 1 + math.clamp(5 / math.max(w, 1), 0.006, 0.045)
        tween(sc, 0.14, {Scale = rest})
    end))
    track(btn.MouseButton1Down:Connect(function()
        tween(sc, 0.07, {Scale = 0.9})
        ripple(btn)
    end))
    track(btn.MouseButton1Up:Connect(function()
        bounce(sc, 0.5, {Scale = hover and rest or 1})
    end))
    track(btn.MouseLeave:Connect(function()
        hover = false
        bounce(sc, 0.4, {Scale = 1})
    end))
end

local function titleButton(text, xOffset, hoverColor)
    local b = new("TextButton", {
        Text = text, Font = FONT_B, TextSize = 14, TextColor3 = C.text, AutoButtonColor = false,
        BackgroundColor3 = C.card, BorderSizePixel = 0, Size = UDim2.new(0, 26, 0, 26),
        AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, xOffset, 0.5, 0),
    }, TitleBar)
    corner(b, 7)
    track(b.MouseEnter:Connect(function()
        b.BackgroundColor3 = hoverColor
        b.TextColor3 = (hoverColor == C.bad) and rgb(255, 255, 255) or C.text
    end))
    track(b.MouseLeave:Connect(function()
        b.BackgroundColor3 = C.card
        b.TextColor3 = C.text
    end))
    pressFx(b)
    return b
end
local MinBtn = titleButton("-", -44, C.cardHi)
local CloseBtn = titleButton("X", -10, C.bad)

local Body   -- the Inventory page (created in HUB CHROME below)

-- soft drop shadow: follows the window, grows and deepens while you drag
local Shadow = new("ImageLabel", {
    Name = "Shadow", BackgroundTransparency = 1, Image = "rbxassetid://1316045217",
    ImageColor3 = rgb(24, 32, 70), ImageTransparency = 0.82, ScaleType = Enum.ScaleType.Slice,
    SliceCenter = Rect.new(10, 10, 118, 118), ZIndex = 0,
}, ScreenGui)

-- dragging: soft spring follow, leans into the motion, rubber-band edges, little "throw" on release
do
    local sp = {
        x = Window.Position.X.Scale, y = Window.Position.Y.Scale, vx = 0, vy = 0,
        tx = Window.Position.X.Scale, ty = Window.Position.Y.Scale,
    }
    DragSpring = sp
    local K, D = 240, 23          -- stiffness / damping (slightly under-damped = one tiny, classy overshoot)
    local XLO, XHI, YLO, YHI = 0.02, 0.98, 0.1, 0.98
    local dragging, dragStart, startX, startY = false, nil, 0, 0
    local tilt, lift = 0, 0
    local PAD = 28
    local QUINT = Enum.EasingStyle.Quint

    -- while the window is still moving, an invisible shield eats clicks (so a click right after a drag can never glitch)
    local Shield = new("Frame", {
        Name = "Shield", Position = UDim2.new(0, 0, 0, TITLE_H), Size = UDim2.new(1, 0, 1, -TITLE_H),
        BackgroundTransparency = 1, BorderSizePixel = 0, Active = true, ZIndex = 100, Visible = false,
    }, Window)

    local function rubber(v, lo, hi)
        if v < lo then return lo + (v - lo) * 0.3 end
        if v > hi then return hi + (v - hi) * 0.3 end
        return v
    end
    local function overWindowButtons(pos)
        for _, b in ipairs({MinBtn, CloseBtn}) do
            local p, s = b.AbsolutePosition, b.AbsoluteSize
            if pos.X >= p.X - 2 and pos.X <= p.X + s.X + 2 then return true end
        end
        return false
    end
    local function endDrag()
        if not dragging then return end
        dragging = false
        -- a little momentum carries the window after you let go; rubber-banded edges snap back inside
        sp.tx = math.clamp(sp.tx + sp.vx * 0.10, XLO, XHI)
        sp.ty = math.clamp(sp.ty + sp.vy * 0.10, YLO, YHI)
        TweenService:Create(WindowScale, TweenInfo.new(0.45, QUINT, Enum.EasingDirection.Out), {Scale = uiScale}):Play()
    end

    track(TitleBar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            if overWindowButtons(input.Position) then return end
            dragging = true
            dragStart = input.Position
            startX, startY = sp.tx, sp.ty
            TweenService:Create(WindowScale, TweenInfo.new(0.28, QUINT, Enum.EasingDirection.Out),
                {Scale = uiScale * 1.035}):Play()
            local changed
            changed = input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    changed:Disconnect()
                    endDrag()
                end
            end)
        end
    end))
    track(UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            endDrag()
        end
    end))
    track(UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch) then
            local size = ScreenGui.AbsoluteSize
            local d = input.Position - dragStart
            sp.tx = rubber(startX + d.X / size.X, XLO, XHI)
            sp.ty = rubber(startY + d.Y / size.Y, YLO, YHI)
        end
    end))
    track(RunService.Heartbeat:Connect(function(dt)
        dt = math.min(dt, 1 / 30)
        local sw, sh = ScreenGui.AbsoluteSize.X, ScreenGui.AbsoluteSize.Y
        local dx, dy = sp.tx - sp.x, sp.ty - sp.y
        if math.abs(dx) + math.abs(dy) + math.abs(sp.vx) + math.abs(sp.vy) >= 2e-4 then
            sp.vx = sp.vx + (K * dx - D * sp.vx) * dt
            sp.vy = sp.vy + (K * dy - D * sp.vy) * dt
            sp.x = sp.x + sp.vx * dt
            sp.y = sp.y + sp.vy * dt
        else
            sp.x, sp.y, sp.vx, sp.vy = sp.tx, sp.ty, 0, 0
        end
        Window.Position = UDim2.new(sp.x, 0, sp.y, 0)

        -- lean into the motion (horizontal speed -> a few degrees), then settle smoothly
        local target = math.clamp(sp.vx * sw / 300, -3.2, 3.2)
        tilt = tilt + (target - tilt) * math.min(1, dt * 10)
        if math.abs(tilt) < 0.01 and target == 0 then tilt = 0 end
        Window.Rotation = tilt
        lift = lift + ((dragging and 1 or 0) - lift) * math.min(1, dt * 12)

        -- click shield while anything is still visibly moving
        local speedPx = math.abs(sp.vx) * sw + math.abs(sp.vy) * sh
        local distPx = math.abs(dx) * sw + math.abs(dy) * sh
        local scaleOff = math.abs(WindowScale.Scale - (dragging and uiScale * 1.035 or uiScale))
        local busy = dragging or speedPx > 60 or distPx > 6 or scaleOff > 0.012 or math.abs(tilt) > 0.8
        if Shield.Visible ~= busy then Shield.Visible = busy end

        -- shadow follows the window and lifts while dragging
        Shadow.Visible = Window.Visible
        local ap, as = Window.AbsolutePosition, Window.AbsoluteSize
        Shadow.Position = UDim2.fromOffset(ap.X - PAD, ap.Y - PAD + 6 + 18 * lift)
        Shadow.Size = UDim2.fromOffset(as.X + PAD * 2, as.Y + PAD * 2)
        Shadow.Rotation = tilt
        Shadow.ImageTransparency = 0.84 - 0.28 * lift

        -- window edge glows accent-blue while held
        WindowStroke.Color = C.line:Lerp(C.accent, lift * 0.85)
        WindowStroke.Thickness = 1 + lift

        -- the little logo dot breathes
        Logo.BackgroundTransparency = 0.05 + 0.2 * (0.5 + 0.5 * math.sin(os.clock() * 2.4))
    end))
end

-- ========================= HUB CHROME (tabs / pages / status bar) =========================
-- Auto Build is the main feature. Copy Build is a helper. Inventory (the old tracker) is an extension tab.
local Hub = {pages = {}, tabs = {}, order = {}, current = nil}
do
    local TAB_H, STATUS_H = 40, 28

    Hub.TabBar = new("Frame", {
        Name = "TabBar", Position = UDim2.new(0, 0, 0, TITLE_H), Size = UDim2.new(1, 0, 0, TAB_H),
        BackgroundTransparency = 1,
    }, Window)
    new("UIListLayout", {FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 4),
        SortOrder = Enum.SortOrder.LayoutOrder, VerticalAlignment = Enum.VerticalAlignment.Center}, Hub.TabBar)
    new("UIPadding", {PaddingLeft = UDim.new(0, 10)}, Hub.TabBar)

    Hub.TopLine = new("Frame", {
        Position = UDim2.new(0, 0, 0, TITLE_H + TAB_H - 1), Size = UDim2.new(1, 0, 0, 1),
        BackgroundColor3 = C.line, BackgroundTransparency = 0.4, BorderSizePixel = 0,
    }, Window)

    Hub.Host = new("Frame", {
        Name = "Pages", Position = UDim2.new(0, 0, 0, TITLE_H + TAB_H),
        Size = UDim2.new(1, 0, 1, -(TITLE_H + TAB_H + STATUS_H)),
        BackgroundTransparency = 1, ClipsDescendants = true,
    }, Window)

    -- soft white veil that fades away whenever you switch tabs
    Hub.Veil = new("Frame", {
        Size = UDim2.new(1, 0, 1, 0), BackgroundColor3 = C.bg, BackgroundTransparency = 1,
        BorderSizePixel = 0, ZIndex = 50, Visible = false,
    }, Hub.Host)
    local veilToken = 0

    Hub.StatusBar = new("Frame", {
        Name = "StatusBar", AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 0, 1, 0),
        Size = UDim2.new(1, 0, 0, STATUS_H), BackgroundTransparency = 1,
    }, Window)
    new("Frame", {Size = UDim2.new(1, 0, 0, 1), BackgroundColor3 = C.line, BackgroundTransparency = 0.4,
        BorderSizePixel = 0}, Hub.StatusBar)
    Hub.StatusDot = new("Frame", {
        Position = UDim2.new(0, 14, 0.5, -4), Size = UDim2.new(0, 8, 0, 8),
        BackgroundColor3 = C.good, BorderSizePixel = 0,
    }, Hub.StatusBar)
    corner(Hub.StatusDot, "full")
    Hub.DotScale = new("UIScale", {Scale = 1}, Hub.StatusDot)
    Hub.StatusText = label({Text = "Ready - choose a build file in the Auto Build tab", TextSize = 11, TextColor3 = C.sub,
        TextTruncate = Enum.TextTruncate.AtEnd,
        Position = UDim2.new(0, 30, 0, 1), Size = UDim2.new(1, -210, 1, -1)}, Hub.StatusBar)
    label({Text = "RightShift = show / hide", TextSize = 10, TextColor3 = C.sub,
        TextXAlignment = Enum.TextXAlignment.Right,
        Position = UDim2.new(1, -190, 0, 1), Size = UDim2.new(0, 176, 1, -1)}, Hub.StatusBar)

    local BAD = {"error", "fail", "not found", "empty", "first", "enter a", "no blocks", "no build", "already", "not building"}
    local GOOD = {"done", "saved", "loaded", "created", "cleared", "finished", ": on", "refreshed"}
    local function hasAny(text, words)
        for _, w in ipairs(words) do
            if string.find(text, w, 1, true) then return true end
        end
        return false
    end

    -- one line of feedback for every tab (colour dot: green = ok, red = problem, blue = info)
    function Hub.status(text, kind)
        text = tostring(text or "")
        if not kind then
            local l = string.lower(text)
            if hasAny(l, BAD) then kind = "bad"
            elseif hasAny(l, GOOD) then kind = "good"
            else kind = "info" end
        end
        Hub.StatusText.Text = text
        Hub.StatusText.TextColor3 = (kind == "bad") and C.bad or C.sub
        Hub.StatusText.TextTransparency = 1
        tween(Hub.StatusText, 0.3, {TextTransparency = 0})
        Hub.DotScale.Scale = 1.9
        bounce(Hub.DotScale, 0.5, {Scale = 1})
        tween(Hub.StatusDot, 0.15, {
            BackgroundColor3 = (kind == "bad" and C.bad) or (kind == "good" and C.good) or C.accent,
        })
    end

    function Hub.show(key)
        if not Hub.pages[key] then return end
        local changed = (Hub.current ~= nil and Hub.current ~= key)
        Hub.current = key
        for k, page in pairs(Hub.pages) do
            local on = (k == key)
            page.Visible = on
            if on and changed then
                -- cards rise into place one after another
                local i = 0
                for _, child in ipairs(page:GetChildren()) do
                    if child:IsA("GuiObject") then
                        i = i + 1
                        local base = child:GetAttribute("bp")
                        if not base then
                            base = child.Position
                            child:SetAttribute("bp", base)
                        end
                        child.Position = base + UDim2.new(0, 0, 0, 22)
                        task.delay(0.05 * (i - 1), function()
                            TweenService:Create(child, TweenInfo.new(0.5, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
                                {Position = base}):Play()
                        end)
                    end
                end
            end
            tween(Hub.tabs[k], 0.15, {
                BackgroundTransparency = on and A.card or 1,
                TextColor3 = on and C.accent or C.sub,
            })
        end
    end

    function Hub.veil()
        veilToken = veilToken + 1
        local my = veilToken
        Hub.Veil.BackgroundTransparency = 0.25
        Hub.Veil.Visible = true
        local t = TweenService:Create(Hub.Veil, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
            {BackgroundTransparency = 1})
        t.Completed:Connect(function()
            if my == veilToken then Hub.Veil.Visible = false end
        end)
        t:Play()
    end

    function Hub.setChrome(on)
        Hub.TabBar.Visible = on
        Hub.TopLine.Visible = on
        Hub.Host.Visible = on
        Hub.StatusBar.Visible = on
    end

    function Hub.addPage(key, title, width, tag)
        local page = new("Frame", {Name = key, Size = UDim2.new(1, 0, 1, 0), BackgroundTransparency = 1,
            Visible = false}, Hub.Host)
        local btn = new("TextButton", {
            Text = title, Font = FONT_B, TextSize = 13, TextColor3 = C.sub, AutoButtonColor = false,
            BackgroundColor3 = C.cardHi, BackgroundTransparency = 1, BorderSizePixel = 0,
            Size = UDim2.new(0, width, 0, 30), LayoutOrder = #Hub.order + 1,
            TextXAlignment = Enum.TextXAlignment.Left,
        }, Hub.TabBar)
        corner(btn, 8)
        new("UIPadding", {PaddingLeft = UDim.new(0, 12)}, btn)
        if tag then
            local chip = new("TextLabel", {
                Text = tag, Font = FONT_B, TextSize = 9, TextColor3 = rgb(255, 255, 255),
                BackgroundColor3 = C.accent, BorderSizePixel = 0, AnchorPoint = Vector2.new(1, 0.5),
                Position = UDim2.new(1, 0, 0.5, 0), Size = UDim2.new(0, 32, 0, 16),
            }, btn)
            corner(chip, 8)
        end
        pressFx(btn)
        track(btn.MouseButton1Click:Connect(function()
            if Hub.current ~= key then Hub.veil() end
            Hub.show(key)
        end))
        track(btn.MouseEnter:Connect(function()
            if Hub.current ~= key then tween(btn, 0.12, {BackgroundTransparency = 0.65, TextColor3 = C.text}) end
        end))
        track(btn.MouseLeave:Connect(function()
            if Hub.current ~= key then tween(btn, 0.12, {BackgroundTransparency = 1, TextColor3 = C.sub}) end
        end))
        Hub.tabs[key] = btn
        Hub.pages[key] = page
        table.insert(Hub.order, key)
        return page
    end
end

-- ========================= HUB PAGES =========================
do
    local LP = Players.LocalPlayer

    ---------------------------------------------------------------- UI kit (small reusable widgets)
    local kit = {}

    function kit.card(parent, pos, size)
        local f = new("Frame", {BackgroundColor3 = C.panel, BorderSizePixel = 0, Position = pos, Size = size}, parent)
        corner(f, 10)
        local s = outline(f, C.line, 1)
        s.Transparency = 0.55
        return f
    end

    -- step badge + title + 2-line hint
    function kit.heading(parent, step, title, hint)
        local x = 14
        if step then
            local b = new("TextLabel", {
                Text = step, Font = FONT_B, TextSize = 11, TextColor3 = rgb(255, 255, 255),
                BackgroundColor3 = C.accent, BorderSizePixel = 0,
                Position = UDim2.new(0, 12, 0, 10), Size = UDim2.new(0, 20, 0, 20),
            }, parent)
            corner(b, "full")
            x = 40
        end
        label({Text = title, Font = FONT_B, TextSize = 14, Position = UDim2.new(0, x, 0, 9),
            Size = UDim2.new(1, -x - 10, 0, 20)}, parent)
        if hint then
            label({Text = hint, TextSize = 10, TextColor3 = C.sub, TextWrapped = true,
                TextYAlignment = Enum.TextYAlignment.Top,
                Position = UDim2.new(0, x, 0, 28), Size = UDim2.new(1, -x - 10, 0, 26)}, parent)
        end
    end

    local function styleButton(b, kind)
        local bg, fg = C.card, C.text
        if kind == "primary" then bg, fg = C.accent, rgb(255, 255, 255)
        elseif kind == "danger" then bg, fg = C.bad, rgb(255, 255, 255) end
        b.BackgroundColor3 = bg
        b.TextColor3 = fg
        b:SetAttribute("base", bg)
        b:SetAttribute("kind", kind)
    end

    function kit.button(parent, text, kind, pos, size)
        local b = new("TextButton", {
            Text = text, Font = FONT_B, TextSize = 12, AutoButtonColor = false, BorderSizePixel = 0,
            Position = pos, Size = size,
        }, parent)
        corner(b, 8)
        if kind == "ghost" then
            local s = outline(b, C.line, 1)
            s.Transparency = 0.2
        end
        styleButton(b, kind)
        if kind == "primary" or kind == "danger" then
            new("UIGradient", {Rotation = 90, Color = ColorSequence.new(rgb(255, 255, 255), rgb(206, 214, 248))}, b)
        end
        track(b.MouseEnter:Connect(function()
            local base = b:GetAttribute("base")
            if b:GetAttribute("kind") == "ghost" then
                tween(b, 0.12, {BackgroundColor3 = C.cardHi})
            else
                tween(b, 0.12, {BackgroundColor3 = base:Lerp(rgb(255, 255, 255), 0.18)})
            end
        end))
        track(b.MouseLeave:Connect(function()
            tween(b, 0.12, {BackgroundColor3 = b:GetAttribute("base")})
        end))
        pressFx(b)
        return b
    end

    function kit.input(parent, placeholder, text, pos, size)
        local f = new("Frame", {BackgroundColor3 = C.card, BorderSizePixel = 0, Position = pos, Size = size}, parent)
        corner(f, 8)
        local st = outline(f, C.line, 1)
        local t = new("TextBox", {
            BackgroundTransparency = 1, BorderSizePixel = 0, Position = UDim2.new(0, 10, 0, 0),
            Size = UDim2.new(1, -20, 1, 0), Font = FONT, TextSize = 12, TextColor3 = C.text,
            PlaceholderText = placeholder, PlaceholderColor3 = C.sub, Text = text or "",
            ClearTextOnFocus = false, TextXAlignment = Enum.TextXAlignment.Left,
        }, f)
        track(t.Focused:Connect(function() st.Color = C.accent end))
        track(t.FocusLost:Connect(function() st.Color = C.line end))
        return t
    end

    -- iOS style on/off switch
    function kit.switch(parent, pos, value, onChange)
        local OFF = rgb(196, 202, 220)
        local sw = new("TextButton", {
            Text = "", AutoButtonColor = false, BorderSizePixel = 0,
            BackgroundColor3 = value and C.good or OFF, Position = pos, Size = UDim2.new(0, 44, 0, 24),
        }, parent)
        corner(sw, "full")
        local knob = new("Frame", {
            BackgroundColor3 = rgb(255, 255, 255), BorderSizePixel = 0, Size = UDim2.new(0, 18, 0, 18),
            Position = value and UDim2.new(1, -21, 0.5, -9) or UDim2.new(0, 3, 0.5, -9),
        }, sw)
        corner(knob, "full")
        local state = value and true or false
        track(sw.MouseButton1Click:Connect(function()
            state = not state
            tween(sw, 0.15, {BackgroundColor3 = state and C.good or OFF})
            bounce(knob, 0.3, {Position = state and UDim2.new(1, -21, 0.5, -9) or UDim2.new(0, 3, 0.5, -9)})
            if onChange then onChange(state) end
        end))
        return sw
    end

    local function scrollList(parent, pos, size)
        local list = new("ScrollingFrame", {
            Position = pos, Size = size, BackgroundTransparency = 1, BorderSizePixel = 0,
            ScrollBarThickness = 3, ScrollBarImageColor3 = C.line, CanvasSize = UDim2.new(0, 0, 0, 0),
            AutomaticCanvasSize = Enum.AutomaticSize.Y,
        }, parent)
        new("UIListLayout", {Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder}, list)
        return list
    end

    ---------------------------------------------------------------- PAGE 1: AUTO BUILD
    local function buildBuildPage(page)
        local S, SET = AB.farmSettings, AB.Settings
        local refreshReq = function() end   -- filled in by the "Required blocks" card below

        -- ===== left card: step 1 - choose a build file
        local left = kit.card(page, UDim2.new(0, 8, 0, 8), UDim2.new(0, 300, 1, -16))
        kit.heading(left, "1", "Choose a build", "Pick a saved file from your SOPERA_WORKSPACE folder.\nIt will be the one that gets built.")
        local search = kit.input(left, "Search files...", "", UDim2.new(0, 10, 0, 58), UDim2.new(1, -82, 0, 30))
        local reloadBtn = kit.button(left, "Reload", "ghost", UDim2.new(1, -66, 0, 58), UDim2.new(0, 56, 0, 30))
        local list = scrollList(left, UDim2.new(0, 10, 0, 96), UDim2.new(1, -20, 1, -150))
        local emptyLbl = label({
            Text = "No build files found.\nPut .Build / .json files into SOPERA_WORKSPACE, or save one from the Copy Build tab.",
            TextSize = 11, TextColor3 = C.sub, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Center,
            Position = UDim2.new(0, 16, 0, 110), Size = UDim2.new(1, -32, 0, 80), Visible = false,
        }, left)

        local selBox = new("Frame", {BackgroundColor3 = C.card, BorderSizePixel = 0,
            Position = UDim2.new(0, 10, 1, -48), Size = UDim2.new(1, -20, 0, 38)}, left)
        corner(selBox, 8)
        label({Text = "SELECTED", Font = FONT_B, TextSize = 9, TextColor3 = C.sub,
            Position = UDim2.new(0, 10, 0, 3), Size = UDim2.new(1, -20, 0, 12)}, selBox)
        local selLabel = label({Text = "-", Font = FONT_B, TextSize = 12, TextTruncate = Enum.TextTruncate.AtEnd,
            Position = UDim2.new(0, 10, 0, 16), Size = UDim2.new(1, -20, 0, 18)}, selBox)

        local function showSelected(n)
            local name = S.autoBuildFile or ""
            if name == "" then
                selLabel.Text = "Nothing selected yet"
            else
                selLabel.Text = name .. (n and ("   |   " .. n .. " blocks") or "")
            end
            refreshReq()
        end

        local rows = {}
        local function setRowOn(r, on)
            tween(r.btn, 0.15, {BackgroundColor3 = on and C.cardHi or C.card, TextColor3 = on and C.accent or C.text})
            r.bar.Visible = on
        end

        local function pick(name)
            S.autoBuildFile = name
            AB.saveFarm()
            for nm, r in pairs(rows) do setRowOn(r, nm == name) end
            showSelected(nil)
            Hub.status("Loading " .. name .. "...", "info")
            task.spawn(function()
                local n, err = AB.loadBuild(name)
                if S.autoBuildFile ~= name then return end
                if n then
                    showSelected(n)
                    Hub.status("Loaded " .. name .. " (" .. n .. " blocks) - ready to preview or build", "good")
                else
                    showSelected(nil)
                    Hub.status(err or "Load failed", "bad")
                end
            end)
        end

        local function populate()
            for _, r in pairs(rows) do r.btn:Destroy() end
            rows = {}
            local q = string.lower(search.Text or "")
            local shown = 0
            for i, name in ipairs(AB.getSavedBuilds()) do
                if q == "" or string.find(string.lower(name), q, 1, true) then
                    shown = shown + 1
                    local btn = new("TextButton", {
                        Text = name, Font = FONT_M, TextSize = 12, TextColor3 = C.text, AutoButtonColor = false,
                        BackgroundColor3 = C.card, BorderSizePixel = 0, Size = UDim2.new(1, -4, 0, 32),
                        LayoutOrder = i, TextXAlignment = Enum.TextXAlignment.Left,
                        TextTruncate = Enum.TextTruncate.AtEnd,
                    }, list)
                    corner(btn, 8)
                    new("UIPadding", {PaddingLeft = UDim.new(0, 14), PaddingRight = UDim.new(0, 8)}, btn)
                    local bar = new("Frame", {BackgroundColor3 = C.accent, BorderSizePixel = 0,
                        Position = UDim2.new(0, -10, 0, 6), Size = UDim2.new(0, 3, 1, -12), Visible = false}, btn)
                    corner(bar, "full")
                    local r = {btn = btn, bar = bar}
                    rows[name] = r
                    setRowOn(r, name == S.autoBuildFile)
                    pressFx(btn)
                    btn.MouseEnter:Connect(function()
                        if name ~= S.autoBuildFile then tween(btn, 0.1, {BackgroundColor3 = C.hover}) end
                    end)
                    btn.MouseLeave:Connect(function()
                        if name ~= S.autoBuildFile then tween(btn, 0.1, {BackgroundColor3 = C.card}) end
                    end)
                    btn.MouseButton1Click:Connect(function() pick(name) end)
                end
            end
            emptyLbl.Visible = (shown == 0)
            return shown
        end

        track(search:GetPropertyChangedSignal("Text"):Connect(populate))
        track(reloadBtn.MouseButton1Click:Connect(function()
            local n = populate()
            Hub.status("File list refreshed (" .. n .. " files)", "good")
        end))

        -- ===== right column, card A: step 2 - preview and build
        local cardA = kit.card(page, UDim2.new(0, 316, 0, 8), UDim2.new(1, -324, 0, 148))
        kit.heading(cardA, "2", "Preview & build",
            "Preview shows see-through ghost blocks on your plot.\nHappy with it? Press Build Now to place the real blocks.")
        local btnRow = new("Frame", {Position = UDim2.new(0, 10, 0, 58), Size = UDim2.new(1, -20, 0, 32),
            BackgroundTransparency = 1}, cardA)
        new("UIListLayout", {FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 8),
            SortOrder = Enum.SortOrder.LayoutOrder}, btnRow)
        local function rowBtn(text, kind, order)
            local b = kit.button(btnRow, text, kind, UDim2.new(0, 0, 0, 0), UDim2.new(1 / 3, -6, 1, 0))
            b.LayoutOrder = order
            return b
        end
        local previewBtn = rowBtn("Preview", "ghost", 1)
        local buildBtn = rowBtn("Build Now", "primary", 2)
        local stopBtn = rowBtn("Stop", "danger", 3)

        local barBg = new("Frame", {Position = UDim2.new(0, 10, 0, 102), Size = UDim2.new(1, -20, 0, 8),
            BackgroundColor3 = C.line, BackgroundTransparency = 0.5, BorderSizePixel = 0}, cardA)
        corner(barBg, "full")
        local barFill = new("Frame", {Size = UDim2.new(0, 0, 1, 0), BackgroundColor3 = C.accent,
            BorderSizePixel = 0}, barBg)
        corner(barFill, "full")
        local shine = new("Frame", {Size = UDim2.new(1, 0, 1, 0), BackgroundColor3 = rgb(255, 255, 255),
            BorderSizePixel = 0, Visible = false}, barFill)
        corner(shine, "full")
        local shineGrad = new("UIGradient", {Transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.5, 0.3), NumberSequenceKeypoint.new(1, 1)})}, shine)
        track(RunService.Heartbeat:Connect(function()
            local building = AB.isBuilding()
            if shine.Visible ~= building then shine.Visible = building end
            if building then shineGrad.Offset = Vector2.new((os.clock() * 1.1) % 2 - 1, 0) end
        end))
        local pctLbl = label({Text = "Idle - not building", TextSize = 10, TextColor3 = C.sub,
            Position = UDim2.new(0, 10, 0, 114), Size = UDim2.new(1, -20, 0, 14)}, cardA)

        local function setProgress(p)
            p = math.clamp(tonumber(p) or 0, 0, 100)
            tween(barFill, 0.12, {Size = UDim2.new(p / 100, 0, 1, 0)})
            if p >= 100 then
                pctLbl.Text = "Finished"
            elseif p <= 0 then
                pctLbl.Text = "Starting..."
            else
                pctLbl.Text = string.format("%d%%   -   keep all tools equipped until it finishes", math.floor(p))
            end
        end

        AB.setPreviewHook(function()
            previewBtn.Text = AB.isPreviewActive() and "Clear Preview" or "Preview"
        end)

        track(previewBtn.MouseButton1Click:Connect(function()
            task.spawn(function()
                local name = S.autoBuildFile or ""
                if AB.isPreviewActive() then
                    AB.clearPreview()
                    Hub.status("Preview cleared", "good")
                    return
                end
                if name == "" then Hub.status("Choose a build file first (step 1)", "bad") return end
                if AB.loadedName() ~= name then
                    Hub.status("Loading " .. name .. "...", "info")
                    local n, err = AB.loadBuild(name)
                    if not n then Hub.status(err or "Load failed", "bad") return end
                    showSelected(n)
                end
                local ok = AB.createPreview()
                if ok then
                    Hub.status("Preview created - ghost blocks are shown on your plot", "good")
                else
                    Hub.status("Preview failed (no plot zone?)", "bad")
                end
            end)
        end))

        track(buildBtn.MouseButton1Click:Connect(function()
            if AB.isBuilding() then Hub.status("Already building!", "bad") return end
            if (S.autoBuildFile or "") == "" then Hub.status("Choose a build file first (step 1)", "bad") return end
            setProgress(0)
            task.spawn(function()
                local ok, err = pcall(AB.runAutoBuild, setProgress)
                if not ok then Hub.status("Build error: " .. tostring(err), "bad") end
            end)
        end))

        track(stopBtn.MouseButton1Click:Connect(function()
            if AB.requestStop() then
                Hub.status("Stopping...", "info")
            else
                Hub.status("Not building right now", "bad")
            end
        end))

        -- ===== right column, card B: auto build on join
        local cardB = kit.card(page, UDim2.new(0, 316, 0, 164), UDim2.new(1, -324, 0, 78))
        label({Text = "Auto Build on Join", Font = FONT_B, TextSize = 14,
            Position = UDim2.new(0, 14, 0, 9), Size = UDim2.new(1, -80, 0, 20)}, cardB)
        label({Text = "Join the game -> wait a few seconds -> the selected file is built for you.",
            TextSize = 10, TextColor3 = C.sub, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top,
            Position = UDim2.new(0, 14, 0, 30), Size = UDim2.new(1, -80, 0, 40)}, cardB)
        kit.switch(cardB, UDim2.new(1, -58, 0, 12), S.autoBuild, function(v)
            S.autoBuild = v
            AB.saveFarm()
            Hub.status(v and "Auto Build on Join: ON" or "Auto Build on Join: OFF", v and "good" or "info")
        end)

        -- ===== right column, card C: build settings
        local cardC = kit.card(page, UDim2.new(0, 316, 0, 250), UDim2.new(1, -324, 0, 168))
        kit.heading(cardC, nil, "Build settings", "Used by Preview and Build. Press Enter / click away to apply.\nEverything is saved automatically.")
        local fields = {
            {"buildScale", "Scale", 1, 0.1, 10},
            {"buildSpeed", "Delay (0 = fastest)", 1, 0, 100},
            {"previewTransparency", "Ghost opacity", 1, 0, 1},
            {"buildOffsetX", "Offset X", 2, -500, 500},
            {"buildOffsetY", "Offset Y (height)", 2, -500, 500},
            {"buildOffsetZ", "Offset Z", 2, -500, 500},
        }
        local rowFrames = {}
        for r = 1, 2 do
            local rf = new("Frame", {Position = UDim2.new(0, 10, 0, 58 + (r - 1) * 50), Size = UDim2.new(1, -20, 0, 44),
                BackgroundTransparency = 1}, cardC)
            new("UIListLayout", {FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 8),
                SortOrder = Enum.SortOrder.LayoutOrder}, rf)
            rowFrames[r] = rf
        end
        for i, f in ipairs(fields) do
            local key, text, r, lo, hi = f[1], f[2], f[3], f[4], f[5]
            local cell = new("Frame", {Size = UDim2.new(1 / 3, -6, 1, 0), BackgroundTransparency = 1, LayoutOrder = i},
                rowFrames[r])
            label({Text = text, Font = FONT_B, TextSize = 10, TextColor3 = C.sub, TextTruncate = Enum.TextTruncate.AtEnd,
                Size = UDim2.new(1, 0, 0, 14)}, cell)
            local box = kit.input(cell, "", tostring(SET[key]), UDim2.new(0, 0, 0, 16), UDim2.new(1, 0, 0, 28))
            track(box.FocusLost:Connect(function()
                local v = tonumber(box.Text)
                if v then
                    v = math.clamp(v, lo, hi)
                    SET[key] = v
                    AB.saveSettings()
                    Hub.status("Saved setting: " .. text:match("^%S+") .. " = " .. tostring(v), "good")
                    refreshReq()
                end
                box.Text = tostring(SET[key])
            end))
        end

        -- ===== right column, card D: required blocks (scrollable)
        local cardD = kit.card(page, UDim2.new(0, 316, 0, 426), UDim2.new(1, -324, 1, -434))
        label({Text = "Required blocks", Font = FONT_B, TextSize = 14,
            Position = UDim2.new(0, 14, 0, 7), Size = UDim2.new(0, 130, 0, 20)}, cardD)
        local reqSummary = label({Text = "", Font = FONT_B, TextSize = 10, TextColor3 = C.sub,
            TextXAlignment = Enum.TextXAlignment.Right, TextTruncate = Enum.TextTruncate.AtEnd,
            Position = UDim2.new(0, 144, 0, 7), Size = UDim2.new(1, -156, 0, 20)}, cardD)
        local reqScroll = new("ScrollingFrame", {
            Position = UDim2.new(0, 8, 0, 32), Size = UDim2.new(1, -16, 1, -38),
            BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 3,
            ScrollBarImageColor3 = C.line, CanvasSize = UDim2.new(0, 0, 0, 0),
            AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollingDirection = Enum.ScrollingDirection.Y,
        }, cardD)
        new("UIGridLayout", {CellSize = UDim2.new(0.5, -4, 0, 40), CellPadding = UDim2.new(0, 6, 0, 6),
            SortOrder = Enum.SortOrder.LayoutOrder}, reqScroll)
        new("UIPadding", {PaddingRight = UDim.new(0, 4), PaddingBottom = UDim.new(0, 4)}, reqScroll)
        local reqEmpty = label({Text = "Select a build file to see which blocks it needs.", TextSize = 11,
            TextColor3 = C.sub, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Center,
            Position = UDim2.new(0, 16, 0, 40), Size = UDim2.new(1, -32, 1, -50)}, cardD)

        local function prettyName(n)
            local t = n:gsub("Block$", ""):gsub("(%l)(%u)", "%1 %2")
            t = t:match("^%s*(.-)%s*$")
            return t ~= "" and t or n
        end

        local reqSig = nil
        local function clearReqCells()
            for _, ch in ipairs(reqScroll:GetChildren()) do
                if ch:IsA("GuiObject") then ch:Destroy() end
            end
        end

        refreshReq = function()
            local name = S.autoBuildFile or ""
            local info = (name ~= "" and AB.loadedName() == name) and AB.getRequirements() or nil
            if not info or #info.list == 0 then
                if reqSig ~= "empty" then
                    reqSig = "empty"
                    clearReqCells()
                end
                reqEmpty.Text = (name == "") and "Select a build file to see which blocks it needs."
                    or "Loading blocks..."
                reqEmpty.Visible = true
                reqSummary.Text = ""
                return
            end
            -- only rebuild the cells when something actually changed
            local parts = {}
            for _, e in ipairs(info.list) do pcall(getInventoryTemplateData, e.name)
                parts[#parts + 1] = e.name .. ":" .. e.need .. ":" .. e.have .. (templateCache[e.name] and "i" or "n")
            end
            local sig = table.concat(parts, "|")
            if sig == reqSig then return end
            reqSig = sig
            reqEmpty.Visible = false
            clearReqCells()

            if info.missingTypes == 0 then
                reqSummary.Text = string.format("%d types  |  all ready", #info.list)
                reqSummary.TextColor3 = C.good
            else
                reqSummary.Text = string.format("%d types  |  %d missing", #info.list, info.missingTypes)
                reqSummary.TextColor3 = C.bad
            end

            for i, e in ipairs(info.list) do
                local enough = e.have >= e.need
                local col = enough and C.good or C.bad
                local cell = new("Frame", {BackgroundColor3 = C.card, BorderSizePixel = 0, LayoutOrder = i}, reqScroll)
                corner(cell, 8)
                local st = outline(cell, col, 1)
                st.Transparency = 0.5

                local icon = new("ImageLabel", {BackgroundTransparency = 1, ScaleType = Enum.ScaleType.Fit,
                    Position = UDim2.new(0, 5, 0, 5), Size = UDim2.new(0, 28, 0, 28),
                    Image = "rbxassetid://12328114032"}, cell)
                pcall(function()
                    -- the block's own picture is the button image; "TypeIcon" is the star badge, so skip it
                    local _, fi = getInventoryTemplateData(e.name)
                    if fi and fi ~= "" then icon.Image = fi end
                end)
                label({Text = prettyName(e.name), Font = FONT_B, TextSize = 11,
                    TextTruncate = Enum.TextTruncate.AtEnd,
                    Position = UDim2.new(0, 39, 0, 3), Size = UDim2.new(1, -44, 0, 16)}, cell)
                label({Text = string.format("%d need / %d have", e.need, e.have), Font = FONT_M, TextSize = 10,
                    TextColor3 = col, TextTruncate = Enum.TextTruncate.AtEnd,
                    Position = UDim2.new(0, 39, 0, 19), Size = UDim2.new(1, -44, 0, 14)}, cell)
                local bar = new("Frame", {BackgroundColor3 = C.line, BackgroundTransparency = 0.4, BorderSizePixel = 0,
                    Position = UDim2.new(0, 8, 1, -4), Size = UDim2.new(1, -16, 0, 2)}, cell)
                corner(bar, "full")
                local fill = new("Frame", {BackgroundColor3 = col, BorderSizePixel = 0,
                    Size = UDim2.new(math.clamp(e.have / math.max(e.need, 1), 0, 1), 0, 1, 0)}, bar)
                corner(fill, "full")
            end
        end

        -- keep the counts live while you collect blocks
        task.spawn(function()
            while cardD.Parent do
                task.wait(2)
                pcall(refreshReq)
            end
        end)

        populate()
        showSelected(nil)
        -- a file was already chosen last session: load it so the required blocks show up right away
        if (S.autoBuildFile or "") ~= "" and AB.loadedName() ~= S.autoBuildFile then
            task.spawn(function()
                local name = S.autoBuildFile
                local ok, n = pcall(AB.loadBuild, name)
                if ok and n and S.autoBuildFile == name then showSelected(n) end
            end)
        end
        return setProgress, populate
    end

    ---------------------------------------------------------------- PAGE 2: COPY BUILD
    local function buildCopyPage(page, refreshFiles)
        local left = kit.card(page, UDim2.new(0, 8, 0, 8), UDim2.new(0, 300, 1, -16))
        kit.heading(left, "1", "Pick a player", "Whose build do you want to copy?\nTap a player to select them.")
        local list = scrollList(left, UDim2.new(0, 10, 0, 58), UDim2.new(1, -20, 1, -68))

        local right = kit.card(page, UDim2.new(0, 316, 0, 8), UDim2.new(1, -324, 1, -16))
        kit.heading(right, "2", "Save it", "Copies the blocks from their plot and stores them as a file.\nYou can build it later from the Auto Build tab.")

        local who = new("Frame", {BackgroundColor3 = C.card, BorderSizePixel = 0,
            Position = UDim2.new(0, 10, 0, 62), Size = UDim2.new(1, -20, 0, 52)}, right)
        corner(who, 10)
        local whoImg = new("ImageLabel", {BackgroundColor3 = C.cardHi, BorderSizePixel = 0, Image = "",
            Position = UDim2.new(0, 8, 0, 8), Size = UDim2.new(0, 36, 0, 36)}, who)
        corner(whoImg, "full")
        local whoName = label({Text = "No player selected", Font = FONT_B, TextSize = 13,
            TextTruncate = Enum.TextTruncate.AtEnd, Position = UDim2.new(0, 54, 0, 8), Size = UDim2.new(1, -64, 0, 18)}, who)
        local whoSub = label({Text = "Pick someone in the list on the left", TextSize = 10, TextColor3 = C.sub,
            TextTruncate = Enum.TextTruncate.AtEnd, Position = UDim2.new(0, 54, 0, 27), Size = UDim2.new(1, -64, 0, 14)}, who)

        label({Text = "FILE NAME", Font = FONT_B, TextSize = 10, TextColor3 = C.sub,
            Position = UDim2.new(0, 12, 0, 128), Size = UDim2.new(1, -24, 0, 14)}, right)
        local nameBox = kit.input(right, "e.g. MyShip", "", UDim2.new(0, 10, 0, 144), UDim2.new(1, -20, 0, 32))
        local saveBtn = kit.button(right, "Save Build", "primary", UDim2.new(0, 10, 0, 188), UDim2.new(1, -20, 0, 36))
        label({Text = "After saving, the file shows up in the Auto Build tab under Choose a build.",
            TextSize = 10, TextColor3 = C.sub, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top,
            Position = UDim2.new(0, 12, 0, 234), Size = UDim2.new(1, -24, 0, 40)}, right)

        -- ===== spectate: see the selected player's camera view
        local viewDiv = new("Frame", {Position = UDim2.new(0, 10, 0, 284), Size = UDim2.new(1, -20, 0, 1),
            BackgroundColor3 = C.line, BackgroundTransparency = 0.4, BorderSizePixel = 0}, right)
        label({Text = "Look at their build first", Font = FONT_B, TextSize = 12,
            Position = UDim2.new(0, 12, 0, 294), Size = UDim2.new(1, -24, 0, 16)}, right)
        local viewBtn = kit.button(right, "View Player's Camera", "ghost", UDim2.new(0, 10, 0, 316), UDim2.new(1, -20, 0, 36))
        label({Text = "Switches your camera to the selected player so you can see what they see. Press again to go back to yourself.",
            TextSize = 10, TextColor3 = C.sub, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top,
            Position = UDim2.new(0, 12, 0, 358), Size = UDim2.new(1, -24, 0, 40)}, right)

        local viewing = nil
        local function ownHumanoid()
            local ch = LP.Character
            return ch and ch:FindFirstChildOfClass("Humanoid")
        end
        local function stopView()
            viewing = nil
            pcall(function()
                local cam = workspace.CurrentCamera
                local hum = ownHumanoid()
                if cam and hum then cam.CameraSubject = hum end
            end)
            pcall(function() viewBtn.Text = "View Player's Camera" end)
        end
        Hub.stopView = stopView
        local function startView(p)
            local hum = p.Character and p.Character:FindFirstChildOfClass("Humanoid")
            if not hum then Hub.status(p.DisplayName .. " has no character right now", "bad") return end
            viewing = p
            workspace.CurrentCamera.CameraSubject = hum
            viewBtn.Text = "Stop Viewing " .. p.DisplayName
            Hub.status("Viewing " .. p.DisplayName .. "'s camera", "good")
        end
        track(viewBtn.MouseButton1Click:Connect(function()
            if viewing then
                stopView()
                Hub.status("Camera back to you", "good")
                return
            end
            local p = AB.getSelectedPlayer()
            if not p then Hub.status("Select a player first (step 1)", "bad") return end
            if p == LP then Hub.status("That's you - pick someone else", "bad") return end
            startView(p)
        end))
        -- follow the player through respawns; stop if they leave
        track(RunService.Heartbeat:Connect(function()
            if not viewing then return end
            if not viewing.Parent then stopView() return end
            local hum = viewing.Character and viewing.Character:FindFirstChildOfClass("Humanoid")
            local cam = workspace.CurrentCamera
            if hum and cam and cam.CameraSubject ~= hum then cam.CameraSubject = hum end
        end))

        local rows = {}
        local function selectPl(p)
            AB.setSelectedPlayer(p)
            for pl, r in pairs(rows) do
                tween(r.btn, 0.15, {BackgroundColor3 = (pl == p) and C.cardHi or C.card})
                r.bar.Visible = (pl == p)
            end
            whoName.Text = p.DisplayName .. ((p == LP) and "  (you)" or "")
            whoSub.Text = "@" .. p.Name
            loadAvatar(whoImg, p.UserId, "head")
            Hub.status("Selected player: " .. p.Name, "info")
        end

        local function refreshPlayers()
            for _, r in pairs(rows) do r.btn:Destroy() end
            rows = {}
            local cur = AB.getSelectedPlayer()
            for i, p in ipairs(Players:GetPlayers()) do
                local btn = new("TextButton", {Text = "", AutoButtonColor = false, BackgroundColor3 = C.card,
                    BorderSizePixel = 0, Size = UDim2.new(1, -4, 0, 44), LayoutOrder = i}, list)
                corner(btn, 8)
                local bar = new("Frame", {BackgroundColor3 = C.accent, BorderSizePixel = 0,
                    Position = UDim2.new(0, 0, 0, 8), Size = UDim2.new(0, 3, 1, -16), Visible = false}, btn)
                corner(bar, "full")
                local img = new("ImageLabel", {BackgroundColor3 = C.cardHi, BorderSizePixel = 0, Image = "",
                    Position = UDim2.new(0, 10, 0, 7), Size = UDim2.new(0, 30, 0, 30)}, btn)
                corner(img, "full")
                loadAvatar(img, p.UserId, "head")
                label({Text = p.DisplayName .. ((p == LP) and "  (you)" or ""), Font = FONT_B, TextSize = 12,
                    TextTruncate = Enum.TextTruncate.AtEnd, Position = UDim2.new(0, 50, 0, 5), Size = UDim2.new(1, -58, 0, 16)}, btn)
                label({Text = "@" .. p.Name, TextSize = 10, TextColor3 = C.sub, TextTruncate = Enum.TextTruncate.AtEnd,
                    Position = UDim2.new(0, 50, 0, 22), Size = UDim2.new(1, -58, 0, 14)}, btn)
                rows[p] = {btn = btn, bar = bar}
                if p == cur then
                    btn.BackgroundColor3 = C.cardHi
                    bar.Visible = true
                end
                pressFx(btn)
                btn.MouseEnter:Connect(function()
                    if AB.getSelectedPlayer() ~= p then tween(btn, 0.1, {BackgroundColor3 = C.hover}) end
                end)
                btn.MouseLeave:Connect(function()
                    if AB.getSelectedPlayer() ~= p then tween(btn, 0.1, {BackgroundColor3 = C.card}) end
                end)
                btn.MouseButton1Click:Connect(function() selectPl(p) end)
            end
        end

        track(Players.PlayerAdded:Connect(function() task.defer(refreshPlayers) end))
        track(Players.PlayerRemoving:Connect(function(p)
            if AB.getSelectedPlayer() == p then
                AB.setSelectedPlayer(nil)
                whoName.Text = "No player selected"
                whoSub.Text = "Pick someone in the list on the left"
                whoImg.Image = ""
            end
            task.defer(refreshPlayers)
        end))

        track(saveBtn.MouseButton1Click:Connect(function()
            if not AB.getSelectedPlayer() then Hub.status("Select a player first (step 1)", "bad") return end
            Hub.status("Copying build from " .. AB.getSelectedPlayer().Name .. "...", "info")
            task.spawn(function()
                local count, fmt, fn = AB.saveSelected(nameBox.Text)
                if count then
                    refreshFiles()
                    Hub.status("Saved " .. count .. " blocks to " .. fn .. " (" .. tostring(fmt or "?") .. ")", "good")
                else
                    Hub.status(fmt or "Save failed!", "bad")
                end
            end)
        end))

        refreshPlayers()
    end

    ---------------------------------------------------------------- PAGE 3: WORLD CHAT + PRIVATE MESSAGES
    local CHAT_CFG_FILE = "AutoBuildHub_chat.json"

    local function buildChatPage(page)
        local me = LP
        local dbUrl = tostring(Config.ChatDbUrl or "")

        local function cleanUrl(u)
            u = tostring(u or ""):match("^%s*(.-)%s*$")
            u = u:gsub("%.json$", ""):gsub("/+$", "")
            return u
        end
        dbUrl = cleanUrl(dbUrl)
        if dbUrl == "" then
            pcall(function()
                if type(isfile) == "function" and isfile(CHAT_CFG_FILE) then
                    local d = HttpService:JSONDecode(readfile(CHAT_CFG_FILE))
                    if type(d) == "table" and type(d.url) == "string" then dbUrl = cleanUrl(d.url) end
                end
            end)
        end

        local reqFn = (type(request) == "function" and request)
            or (type(http_request) == "function" and http_request)
            or (syn and syn.request)
        local function http(method, url, body)
            if not reqFn then return nil, "executor has no request function" end
            local ok, r = pcall(reqFn, {Url = url, Method = method,
                Headers = {["Content-Type"] = "application/json"}, Body = body})
            if not ok or type(r) ~= "table" then return nil, "request failed" end
            local code = tonumber(r.StatusCode) or 0
            if code < 200 or code >= 300 then return nil, "HTTP " .. code end
            return r.Body or ""
        end

        -- ---------- state
        local threads, seen, lastKey = {}, {}, {}
        local current = "world"
        local initialLoad = true
        local rowOrder = 0
        local openDM, switchThread, refreshThreads

        local function getThread(key, name, userId, user)
            local t = threads[key]
            if not t then
                t = {key = key, name = name or key, user = user, userId = userId, msgs = {}, unread = 0, last = 0}
                threads[key] = t
            else
                if name and key ~= "world" then t.name = name end
                if user then t.user = user end
            end
            return t
        end
        getThread("world", "World Chat")

        -- ---------- layout
        local left = kit.card(page, UDim2.new(0, 8, 0, 8), UDim2.new(0, 220, 1, -16))
        label({Text = "Chats", Font = FONT_B, TextSize = 14, Position = UDim2.new(0, 14, 0, 9),
            Size = UDim2.new(1, -28, 0, 20)}, left)
        local threadList = scrollList(left, UDim2.new(0, 8, 0, 36), UDim2.new(1, -16, 1, -44))

        local right = kit.card(page, UDim2.new(0, 236, 0, 8), UDim2.new(1, -244, 1, -16))

        -- setup panel (shown until a database URL is saved)
        local setup = new("Frame", {BackgroundTransparency = 1, Size = UDim2.new(1, 0, 1, 0), Visible = false}, right)
        kit.heading(setup, nil, "Set up World Chat", nil)
        label({
            Text = "Messages travel through a free Firebase Realtime Database that everyone using this script shares.\n\n"
                .. "1. Open console.firebase.google.com and create a project.\n"
                .. "2. Build > Realtime Database > Create database (start in test mode).\n"
                .. "3. Open the Rules tab, set  { \"rules\": { \".read\": true, \".write\": true } }  and Publish.\n"
                .. "4. Copy the database URL (looks like https://xxxx-default-rtdb.firebaseio.com) and paste it below.\n\n"
                .. "Everybody must use the same URL. When you share the script, put it in Config.ChatDbUrl.",
            TextSize = 11, TextColor3 = C.sub, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top,
            Position = UDim2.new(0, 14, 0, 34), Size = UDim2.new(1, -28, 0, 200),
        }, setup)
        local urlBox = kit.input(setup, "https://your-project-default-rtdb.firebaseio.com", dbUrl,
            UDim2.new(0, 10, 0, 244), UDim2.new(1, -20, 0, 32))
        local saveUrlBtn = kit.button(setup, "Save & Connect", "primary", UDim2.new(0, 10, 0, 286), UDim2.new(1, -20, 0, 36))
        local setupMsg = label({Text = "", TextSize = 11, TextColor3 = C.sub, TextWrapped = true,
            TextYAlignment = Enum.TextYAlignment.Top,
            Position = UDim2.new(0, 12, 0, 330), Size = UDim2.new(1, -24, 0, 44)}, setup)

        -- chat panel
        local chatUI = new("Frame", {BackgroundTransparency = 1, Size = UDim2.new(1, 0, 1, 0), Visible = false}, right)

        local hBadge = new("TextLabel", {Text = "W", Font = FONT_B, TextSize = 16, TextColor3 = rgb(255, 255, 255),
            BackgroundColor3 = C.accent, BorderSizePixel = 0,
            Position = UDim2.new(0, 10, 0, 8), Size = UDim2.new(0, 36, 0, 36)}, chatUI)
        corner(hBadge, "full")
        local hImg = new("ImageLabel", {BackgroundColor3 = C.cardHi, BorderSizePixel = 0, Image = "",
            Position = UDim2.new(0, 10, 0, 8), Size = UDim2.new(0, 36, 0, 36), Visible = false}, chatUI)
        corner(hImg, "full")
        local hTitle = label({Text = "World Chat", Font = FONT_B, TextSize = 14, TextTruncate = Enum.TextTruncate.AtEnd,
            Position = UDim2.new(0, 56, 0, 8), Size = UDim2.new(1, -190, 0, 18)}, chatUI)
        local hSub = label({Text = "", TextSize = 10, TextColor3 = C.sub, TextTruncate = Enum.TextTruncate.AtEnd,
            Position = UDim2.new(0, 56, 0, 27), Size = UDim2.new(1, -190, 0, 14)}, chatUI)
        local connLbl = label({Text = "connecting...", Font = FONT_B, TextSize = 10, TextColor3 = C.sub,
            TextXAlignment = Enum.TextXAlignment.Right,
            Position = UDim2.new(1, -176, 0, 8), Size = UDim2.new(0, 100, 0, 18)}, chatUI)
        local setupBtn = kit.button(chatUI, "Setup", "ghost", UDim2.new(1, -68, 0, 10), UDim2.new(0, 58, 0, 28))
        -- the database URL is built into the script (Config.ChatDbUrl), so everyone shares the same chat
        local BUILTIN = tostring(Config.ChatDbUrl or "") ~= ""
        if BUILTIN then
            setupBtn.Visible = false
            connLbl.Position = UDim2.new(1, -116, 0, 8)
        end
        new("Frame", {Position = UDim2.new(0, 0, 0, 52), Size = UDim2.new(1, 0, 0, 1),
            BackgroundColor3 = C.line, BackgroundTransparency = 0.4, BorderSizePixel = 0}, chatUI)

        local msgScroll = scrollList(chatUI, UDim2.new(0, 8, 0, 58), UDim2.new(1, -16, 1, -106))
        local inputBox = kit.input(chatUI, "Type a message (中文 / English)...", "",
            UDim2.new(0, 10, 1, -42), UDim2.new(1, -90, 0, 32))
        local sendBtn = kit.button(chatUI, "Send", "primary", UDim2.new(1, -72, 1, -42), UDim2.new(0, 62, 0, 32))

        -- ---------- helpers
        local function setConn(ok, err)
            if ok then
                connLbl.Text = "online"
                connLbl.TextColor3 = C.good
            else
                connLbl.Text = "offline" .. (err and (" (" .. tostring(err) .. ")") or "")
                connLbl.TextColor3 = C.bad
            end
        end

        local function updateBadge()
            local n = 0
            for _, t in pairs(threads) do n = n + t.unread end
            Hub.tabs.chat.Text = (n > 0) and ("World Chat  (" .. n .. ")") or "World Chat"
        end

        local function viewing(key)
            return key == current and page.Visible and Window.Visible
        end

        -- "HH:mm" (or "MM/dd HH:mm" for messages older than a day), in the viewer's local time
        local function fmtTime(ms)
            ms = tonumber(ms) or (os.time() * 1000)
            local ok, s = pcall(function()
                local dt = DateTime.fromUnixTimestampMillis(ms)
                local old = (os.time() * 1000 - ms) > 86400000
                return dt:FormatLocalTime(old and "MM/dd HH:mm" or "HH:mm", "en-us")
            end)
            if ok and type(s) == "string" and s ~= "" then return s end
            -- fallback without DateTime formatting (UTC+8 fixed offset is wrong for other zones, so use os.date)
            local ok2, s2 = pcall(function() return os.date("%H:%M", math.floor(ms / 1000)) end)
            return ok2 and s2 or ""
        end

        local function appendRow(m)
            local nearBottom = msgScroll.CanvasPosition.Y + msgScroll.AbsoluteWindowSize.Y
                >= msgScroll.AbsoluteCanvasSize.Y - 40
            rowOrder = rowOrder + 1
            local row = new("Frame", {
                BackgroundColor3 = m.mine and C.cardHi or C.card, BorderSizePixel = 0,
                Size = UDim2.new(1, -4, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = rowOrder,
            }, msgScroll)
            corner(row, 8)
            new("UIPadding", {PaddingBottom = UDim.new(0, 6)}, row)
            local av = new("ImageLabel", {BackgroundColor3 = C.cardHi, BorderSizePixel = 0, Image = "",
                Position = UDim2.new(0, 6, 0, 6), Size = UDim2.new(0, 32, 0, 32)}, row)
            corner(av, "full")
            loadAvatar(av, m.uid, "head")
            local avBtn = new("TextButton", {Text = "", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 1, 0),
                ZIndex = 3}, av)
            local st = outline(av, C.accent, 2)
            st.Transparency = 1
            avBtn.MouseEnter:Connect(function() tween(st, 0.12, {Transparency = 0}) end)
            avBtn.MouseLeave:Connect(function() tween(st, 0.12, {Transparency = 1}) end)
            avBtn.MouseButton1Click:Connect(function() openDM(m.uid, m.display, m.name) end)
            label({Text = m.display .. "   @" .. m.name .. "   ID " .. tostring(m.uid), Font = FONT_B, TextSize = 11,
                TextColor3 = m.mine and C.accent or C.sub, TextTruncate = Enum.TextTruncate.AtEnd,
                Position = UDim2.new(0, 46, 0, 4), Size = UDim2.new(1, -112, 0, 14)}, row)
            label({Text = fmtTime(m.ts), Font = FONT_M, TextSize = 10, TextColor3 = C.sub,
                TextXAlignment = Enum.TextXAlignment.Right,
                Position = UDim2.new(1, -108, 0, 4), Size = UDim2.new(0, 100, 0, 14)}, row)
            label({Text = m.text, Font = FONT_M, TextSize = 13, TextWrapped = true,
                TextYAlignment = Enum.TextYAlignment.Top, AutomaticSize = Enum.AutomaticSize.Y,
                Position = UDim2.new(0, 46, 0, 19), Size = UDim2.new(1, -54, 0, 0)}, row)
            if nearBottom or m.mine then
                task.defer(function()
                    task.wait()
                    msgScroll.CanvasPosition = Vector2.new(0, math.max(0,
                        msgScroll.AbsoluteCanvasSize.Y - msgScroll.AbsoluteWindowSize.Y))
                end)
            end
        end

        local function addMessage(key, m, silent)
            local t = threads[key]
            if not t then return end
            table.insert(t.msgs, m)
            if #t.msgs > 150 then table.remove(t.msgs, 1) end
            t.last = os.clock()
            if key == current then appendRow(m) end
            if not m.mine and not viewing(key) then
                t.unread = t.unread + 1
                if key ~= "world" and not silent then
                    Hub.status("New message from " .. m.display, "info")
                    pcall(function()
                        StarterGui:SetCore("SendNotification", {Title = "Private message from " .. m.display,
                            Text = m.text:sub(1, 80), Duration = 6})
                    end)
                end
            end
            refreshThreads()
            updateBadge()
        end

        -- ---------- thread list
        refreshThreads = function()
            for _, ch in ipairs(threadList:GetChildren()) do
                if ch:IsA("GuiObject") then ch:Destroy() end
            end
            local keys = {}
            for k in pairs(threads) do if k ~= "world" then keys[#keys + 1] = k end end
            table.sort(keys, function(a, b) return threads[a].last > threads[b].last end)
            table.insert(keys, 1, "world")
            for i, k in ipairs(keys) do
                local t = threads[k]
                local on = (k == current)
                local btn = new("TextButton", {Text = "", AutoButtonColor = false,
                    BackgroundColor3 = on and C.cardHi or C.card, BorderSizePixel = 0,
                    Size = UDim2.new(1, -4, 0, 46), LayoutOrder = i}, threadList)
                corner(btn, 8)
                if k == "world" then
                    local g = new("TextLabel", {Text = "W", Font = FONT_B, TextSize = 14, TextColor3 = rgb(255, 255, 255),
                        BackgroundColor3 = C.accent, BorderSizePixel = 0,
                        Position = UDim2.new(0, 8, 0, 8), Size = UDim2.new(0, 30, 0, 30)}, btn)
                    corner(g, "full")
                else
                    local img = new("ImageLabel", {BackgroundColor3 = C.cardHi, BorderSizePixel = 0, Image = "",
                        Position = UDim2.new(0, 8, 0, 8), Size = UDim2.new(0, 30, 0, 30)}, btn)
                    corner(img, "full")
                    loadAvatar(img, t.userId, "head")
                end
                label({Text = (k == "world") and "World Chat" or t.name, Font = FONT_B, TextSize = 12,
                    TextTruncate = Enum.TextTruncate.AtEnd,
                    Position = UDim2.new(0, 46, 0, 6), Size = UDim2.new(1, -78, 0, 16)}, btn)
                local lastMsg = t.msgs[#t.msgs]
                label({Text = lastMsg and lastMsg.text or ((k == "world") and "Everyone" or "Private chat"),
                    TextSize = 10, TextColor3 = C.sub, TextTruncate = Enum.TextTruncate.AtEnd,
                    Position = UDim2.new(0, 46, 0, 24), Size = UDim2.new(1, -78, 0, 14)}, btn)
                if t.unread > 0 then
                    local pill = new("TextLabel", {Text = tostring(math.min(t.unread, 99)), Font = FONT_B, TextSize = 10,
                        TextColor3 = rgb(255, 255, 255), BackgroundColor3 = C.bad, BorderSizePixel = 0,
                        AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -8, 0.5, 0),
                        Size = UDim2.new(0, 22, 0, 18)}, btn)
                    corner(pill, "full")
                end
                btn.MouseEnter:Connect(function() if k ~= current then tween(btn, 0.1, {BackgroundColor3 = C.hover}) end end)
                btn.MouseLeave:Connect(function() if k ~= current then tween(btn, 0.1, {BackgroundColor3 = C.card}) end end)
                btn.MouseButton1Click:Connect(function() switchThread(k) end)
            end
        end

        switchThread = function(key)
            local t = threads[key]
            if not t then return end
            current = key
            t.unread = 0
            for _, ch in ipairs(msgScroll:GetChildren()) do
                if ch:IsA("GuiObject") then ch:Destroy() end
            end
            rowOrder = 0
            if key == "world" then
                hBadge.Visible, hImg.Visible = true, false
                hTitle.Text = "World Chat"
                hSub.Text = "Max 100 characters  -  click an avatar to send a private message (unlimited)"
            else
                hBadge.Visible, hImg.Visible = false, true
                loadAvatar(hImg, t.userId, "head")
                hTitle.Text = t.name
                hSub.Text = "Private message" .. (t.user and ("  -  @" .. t.user) or "")
            end
            for _, m in ipairs(t.msgs) do appendRow(m) end
            task.defer(function()
                task.wait()
                msgScroll.CanvasPosition = Vector2.new(0, math.max(0,
                    msgScroll.AbsoluteCanvasSize.Y - msgScroll.AbsoluteWindowSize.Y))
            end)
            refreshThreads()
            updateBadge()
        end

        openDM = function(uid, display, user)
            uid = tonumber(uid)
            if not uid then return end
            if uid == me.UserId then
                Hub.status("That's you - pick someone else for a private message", "bad")
                return
            end
            getThread(tostring(uid), display or user, uid, user)
            if Hub.current ~= "chat" then Hub.veil() Hub.show("chat") end
            switchThread(tostring(uid))
            pcall(function() inputBox:CaptureFocus() end)
        end

        -- ---------- network
        local WORLD_LIMIT = 100      -- max characters per world message (private messages are unlimited)
        local DM_SAFETY = 20000      -- only a sanity cap so a broken client can't freeze the UI

        local function cutChars(text, n)
            local len = utf8.len(text)
            if not len then return text:sub(1, n) end
            if len <= n then return text end
            local cut = utf8.offset(text, n + 1)
            return cut and text:sub(1, cut - 1) or text
        end

        -- Firebase push keys start with an 8-char timestamp (ms since 1970, base-64 digits).
        -- Used as a reliable time source when a message has no (or a broken) "ts" field.
        local PUSH_CHARS = "-0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ_abcdefghijklmnopqrstuvwxyz"
        local function keyTime(key)
            if type(key) ~= "string" or #key < 8 then return nil end
            local t = 0
            for i = 1, 8 do
                local idx = string.find(PUSH_CHARS, key:sub(i, i), 1, true)
                if not idx then return nil end
                t = t * 64 + (idx - 1)
            end
            return t
        end

        local function goodTime(t, nowMs)
            -- accept only believable values: after 2020 and not more than a day in the future
            return type(t) == "number" and t > 1577836800000 and t < nowMs + 86400000
        end

        local function parseMsg(d, isDM, key)
            if type(d) ~= "table" then return nil end
            local uid = tonumber(d.id)
            local text = d.t
            if not uid or type(text) ~= "string" or text == "" then return nil end
            local name = tostring(d.n or "?")
            text = cutChars(text, isDM and DM_SAFETY or WORLD_LIMIT)
            local nowMs = os.time() * 1000
            local ts = tonumber(d.ts)
            if not goodTime(ts, nowMs) then ts = keyTime(key) end
            if not goodTime(ts, nowMs) then ts = nowMs end   -- fixed at receive time, never changes afterwards
            return {uid = uid, name = name, display = tostring(d.d or name), text = text,
                ts = ts, mine = (uid == me.UserId)}
        end

        local function fetchPath(path, onMsg)
            if dbUrl == "" then return false, "no url" end
            local url = dbUrl .. "/" .. path .. ".json?orderBy=%22%24key%22"
            local lk = lastKey[path]
            if lk then url = url .. "&startAt=%22" .. lk .. "%22" else url = url .. "&limitToLast=40" end
            local body, err = http("GET", url)
            if not body then return false, err end
            local ok, data = pcall(function() return HttpService:JSONDecode(body) end)
            if not ok then return false, "bad data" end
            if type(data) == "table" then
                local keys = {}
                for k in pairs(data) do keys[#keys + 1] = tostring(k) end
                table.sort(keys)
                for _, k in ipairs(keys) do
                    local id = path .. "/" .. k
                    if not seen[id] and not (lk and k <= lk) then
                        seen[id] = true
                        local m = parseMsg(data[k], path ~= "world", k)
                        if m then onMsg(m) end
                    end
                    if k > (lastKey[path] or "") then lastKey[path] = k end
                end
            end
            return true
        end

        local function onWorld(m) addMessage("world", m, true) end
        local function onDM(m)
            local k = tostring(m.uid)
            getThread(k, m.display, m.uid, m.name)
            addMessage(k, m, initialLoad)
        end

        local function pollWorld() return fetchPath("world", onWorld) end

        local function clip(text, limit)
            text = tostring(text or ""):gsub("[\0-\8\11-\31]", " ")
            text = text:match("^%s*(.-)%s*$")
            if limit then text = cutChars(text, limit) end
            return text
        end

        local lastSend = 0
        local function doSend()
            if dbUrl == "" then return end
            local text = clip(inputBox.Text, (current == "world") and WORLD_LIMIT or nil)
            if text == "" then return end
            if os.clock() - lastSend < 1.2 then Hub.status("Slow down a little...", "bad") return end
            lastSend = os.clock()
            inputBox.Text = ""
            local key = current
            local t = threads[key]
            task.spawn(function()
                local payload = {id = me.UserId, n = me.Name, d = me.DisplayName, t = text,
                    ts = {[".sv"] = "timestamp"}}   -- Firebase fills in the server time (ms)
                local path = "world"
                if key ~= "world" then
                    path = "dm/" .. tostring(t.userId)
                    payload.to = t.userId
                end
                local body, err = http("POST", dbUrl .. "/" .. path .. ".json", HttpService:JSONEncode(payload))
                if not body then
                    Hub.status("Send failed: " .. tostring(err), "bad")
                    inputBox.Text = text
                    return
                end
                if key == "world" then
                    pollWorld()
                else
                    addMessage(key, {uid = me.UserId, name = me.Name, display = me.DisplayName, text = text,
                        ts = os.time() * 1000, mine = true})
                end
            end)
        end

        track(sendBtn.MouseButton1Click:Connect(doSend))
        track(inputBox.FocusLost:Connect(function(enter)
            if enter then
                doSend()
                task.defer(function() pcall(function() inputBox:CaptureFocus() end) end)
            end
        end))

        -- ---------- setup flow
        local function showSetup(on)
            setup.Visible = on
            chatUI.Visible = not on
        end
        track(setupBtn.MouseButton1Click:Connect(function()
            urlBox.Text = dbUrl
            showSetup(true)
        end))
        track(saveUrlBtn.MouseButton1Click:Connect(function()
            local u = cleanUrl(urlBox.Text)
            if not u:match("^https://") then
                setupMsg.Text = "The URL must start with https://"
                setupMsg.TextColor3 = C.bad
                return
            end
            setupMsg.Text = "Testing connection..."
            setupMsg.TextColor3 = C.sub
            task.spawn(function()
                local body, err = http("GET", u .. "/.json?shallow=true")
                if not body then
                    setupMsg.Text = "Can't reach it (" .. tostring(err) .. "). Check the URL and that the rules allow read + write."
                    setupMsg.TextColor3 = C.bad
                    return
                end
                dbUrl = u
                lastKey, seen, initialLoad = {}, {}, true
                for _, t in pairs(threads) do t.msgs = {} end
                pcall(function() writefile(CHAT_CFG_FILE, HttpService:JSONEncode({url = u})) end)
                setupMsg.Text = ""
                showSetup(false)
                switchThread(current)
                Hub.status("World Chat connected", "good")
            end)
        end))

        -- mark as read when the tab is opened
        track(page:GetPropertyChangedSignal("Visible"):Connect(function()
            if page.Visible then
                threads[current].unread = 0
                refreshThreads()
                updateBadge()
            end
        end))

        -- poll loop
        task.spawn(function()
            while ScreenGui.Parent do
                if dbUrl ~= "" then
                    local ok1, e1 = pollWorld()
                    local ok2, e2 = fetchPath("dm/" .. tostring(me.UserId), onDM)
                    setConn(ok1 and ok2, e1 or e2)
                    if ok1 and ok2 then initialLoad = false end
                end
                task.wait(tonumber(Config.ChatPoll) or 2.5)
            end
        end)

        switchThread("world")
        showSetup(dbUrl == "")
    end

    ---------------------------------------------------------------- create the tabs
    local buildPage = Hub.addPage("build", "Auto Build", 112)
    local copyPage = Hub.addPage("copy", "Copy Build", 112)
    local chatPage = Hub.addPage("chat", "World Chat", 132)
    Body = Hub.addPage("inventory", "Inventory", 124, "EXT")   -- the old Inventory Tracker lives in this tab

    AB.setSink(Hub.status)
    local setProgress, refreshFiles = buildBuildPage(buildPage)
    buildCopyPage(copyPage, refreshFiles)
    buildChatPage(chatPage)
    Hub.setProgress = setProgress
    Hub.show("build")
end

-- ========================= UI: SIDEBAR =========================
local Sidebar = new("Frame", {
    Position = UDim2.new(0, 8, 0, 8), Size = UDim2.new(0, 190, 1, -16),
    BackgroundColor3 = C.panel, BorderSizePixel = 0,
}, Body)
corner(Sidebar, 10)

label({Text = "PLAYERS", Font = FONT_B, TextSize = 11, TextColor3 = C.sub,
    Position = UDim2.new(0, 12, 0, 0), Size = UDim2.new(0.5, 0, 0, 32)}, Sidebar)
local PlayerCount = label({Text = "0", Font = FONT_B, TextSize = 11, TextColor3 = C.sub,
    TextXAlignment = Enum.TextXAlignment.Right,
    Position = UDim2.new(0.5, 0, 0, 0), Size = UDim2.new(0.5, -12, 0, 32)}, Sidebar)

local PlayerScroll = new("ScrollingFrame", {
    Position = UDim2.new(0, 6, 0, 32), Size = UDim2.new(1, -12, 1, -38),
    BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 3,
    ScrollBarImageColor3 = C.line, CanvasSize = UDim2.new(0, 0, 0, 0),
    AutomaticCanvasSize = Enum.AutomaticSize.Y,
}, Sidebar)
new("UIListLayout", {Padding = UDim.new(0, 5), SortOrder = Enum.SortOrder.LayoutOrder}, PlayerScroll)

-- ========================= UI: CONTENT =========================
local Content = new("Frame", {
    Position = UDim2.new(0, 206, 0, 8), Size = UDim2.new(1, -214, 1, -16),
    BackgroundTransparency = 1,
}, Body)

-- header card
local Header = new("Frame", {
    Size = UDim2.new(1, 0, 0, 92), BackgroundColor3 = C.panel, BorderSizePixel = 0,
}, Content)
corner(Header, 10)

local HeaderAvatar = new("ImageLabel", {
    Size = UDim2.new(0, 48, 0, 48), Position = UDim2.new(0, 12, 0, 10),
    BackgroundColor3 = C.card, BorderSizePixel = 0, ScaleType = Enum.ScaleType.Crop, Image = "",
}, Header)
corner(HeaderAvatar, "full")
local HeaderAvatarStroke = outline(HeaderAvatar, C.line, 2)
local HeaderAvatarScale = new("UIScale", {Scale = 1}, HeaderAvatar)

local HeaderName = label({Text = "Select a player", Font = FONT_B, TextSize = 17,
    TextTruncate = Enum.TextTruncate.AtEnd,
    Position = UDim2.new(0, 70, 0, 10), Size = UDim2.new(1, -214, 0, 22)}, Header)
local HeaderSub = label({Text = "Pick someone from the list", TextSize = 11, TextColor3 = C.sub,
    TextTruncate = Enum.TextTruncate.AtEnd,
    Position = UDim2.new(0, 70, 0, 34), Size = UDim2.new(1, -214, 0, 14)}, Header)

local Badge = new("Frame", {
    AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -12, 0, 10),
    Size = UDim2.new(0, 124, 0, 24), BackgroundColor3 = C.card, BorderSizePixel = 0,
}, Header)
corner(Badge, 12)
local BadgeStroke = outline(Badge, C.line, 1.5)
local BadgeLabel = label({Text = "-", Font = FONT_B, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Center,
    Size = UDim2.new(1, 0, 1, 0)}, Badge)

local StatusRow = new("Frame", {
    AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -12, 0, 38),
    Size = UDim2.new(0, 124, 0, 14), BackgroundTransparency = 1,
}, Header)
local StatusDot = new("Frame", {
    Position = UDim2.new(0, 2, 0, 3), Size = UDim2.new(0, 8, 0, 8),
    BackgroundColor3 = C.sub, BorderSizePixel = 0,
}, StatusRow)
corner(StatusDot, "full")
local StatusLabel = label({Text = "IDLE", Font = FONT_B, TextSize = 10, TextColor3 = C.sub,
    Position = UDim2.new(0, 16, 0, 0), Size = UDim2.new(1, -16, 1, 0)}, StatusRow)

local ProgressText = label({Text = "", TextSize = 11, TextColor3 = C.sub,
    TextTruncate = Enum.TextTruncate.AtEnd,
    Position = UDim2.new(0, 12, 0, 63), Size = UDim2.new(1, -100, 0, 14)}, Header)
local ProgressPct = label({Text = "", Font = FONT_B, TextSize = 11, TextXAlignment = Enum.TextXAlignment.Right,
    AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -12, 0, 63), Size = UDim2.new(0, 80, 0, 14)}, Header)
local ProgressTrack = new("Frame", {
    Position = UDim2.new(0, 12, 0, 79), Size = UDim2.new(1, -24, 0, 6),
    BackgroundColor3 = C.line, BorderSizePixel = 0,
}, Header)
corner(ProgressTrack, 3)
local ProgressFill = new("Frame", {
    Size = UDim2.new(0, 0, 1, 0), BackgroundColor3 = C.accent, BorderSizePixel = 0,
}, ProgressTrack)
corner(ProgressFill, 3)

-- stat cards
local StatsRow = new("Frame", {
    Position = UDim2.new(0, 0, 0, 98), Size = UDim2.new(1, 0, 0, 44), BackgroundTransparency = 1,
}, Content)
new("UIListLayout", {FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6),
    SortOrder = Enum.SortOrder.LayoutOrder}, StatsRow)

local function makeStatCard(order, title, valueColor)
    local card = new("Frame", {
        Size = UDim2.new(1 / 3, -4, 1, 0), BackgroundColor3 = C.panel,
        BorderSizePixel = 0, LayoutOrder = order,
    }, StatsRow)
    corner(card, 10)
    label({Text = title, Font = FONT_B, TextSize = 10, TextColor3 = C.sub,
        Position = UDim2.new(0, 10, 0, 5), Size = UDim2.new(0.5, 0, 0, 12)}, card)
    local tag = label({Font = FONT_M, TextSize = 10, TextColor3 = C.sub,
        TextXAlignment = Enum.TextXAlignment.Right,
        Position = UDim2.new(0.4, 0, 0, 5), Size = UDim2.new(0.6, -10, 0, 12)}, card)
    local value = label({Text = "-", Font = FONT_B, TextSize = 16, TextScaled = true, TextColor3 = valueColor,
        Position = UDim2.new(0, 10, 0, 19), Size = UDim2.new(1, -20, 0, 20)}, card)
    new("UITextSizeConstraint", {MaxTextSize = 16, MinTextSize = 8}, value)
    return value, tag
end
local BlocksValue, BlocksTag = makeStatCard(1, "BLOCKS", C.text)
local GoldValue, GoldTag = makeStatCard(2, "GOLD", C.gold)
local TypesValue, TypesTag = makeStatCard(3, "ITEM TYPES", C.accent)

-- tools row: tabs / search / sort
local TabsFrame = new("Frame", {
    Position = UDim2.new(0, 0, 0, 148), Size = UDim2.new(0, 128, 0, 28),
    BackgroundColor3 = C.panel, BorderSizePixel = 0,
}, Content)
corner(TabsFrame, 8)

local function makeTab(text, pos)
    local b = new("TextButton", {
        Text = text, Font = FONT_B, TextSize = 12, TextColor3 = C.sub, AutoButtonColor = false,
        BackgroundColor3 = C.panel, BorderSizePixel = 0,
        Position = pos, Size = UDim2.new(0.5, -4, 1, -6),
    }, TabsFrame)
    corner(b, 6)
    pressFx(b)
    return b
end
local ItemsTab = makeTab("Items", UDim2.new(0, 3, 0, 3))
local SlotsTab = makeTab("Slots", UDim2.new(0.5, 1, 0, 3))

local SearchBar = new("TextBox", {
    Name = "SearchBar", Position = UDim2.new(0, 136, 0, 148), Size = UDim2.new(1, -228, 0, 28),
    BackgroundColor3 = C.panel, BorderSizePixel = 0, Font = FONT, TextSize = 12,
    TextColor3 = C.text, PlaceholderText = "Search item or slot...", PlaceholderColor3 = C.sub,
    Text = "", ClearTextOnFocus = false, TextXAlignment = Enum.TextXAlignment.Left,
}, Content)
corner(SearchBar, 8)
new("UIPadding", {PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10)}, SearchBar)

local SortBtn = new("TextButton", {
    Text = "Sort: Amount", Font = FONT_B, TextSize = 11, TextColor3 = C.text, AutoButtonColor = false,
    BackgroundColor3 = C.panel, BorderSizePixel = 0, AnchorPoint = Vector2.new(1, 0),
    Position = UDim2.new(1, 0, 0, 148), Size = UDim2.new(0, 84, 0, 28),
}, Content)
corner(SortBtn, 8)
pressFx(SortBtn)

-- list
local ListHolder = new("Frame", {
    Position = UDim2.new(0, 0, 0, 182), Size = UDim2.new(1, 0, 1, -182),
    BackgroundColor3 = C.panel, BorderSizePixel = 0,
}, Content)
corner(ListHolder, 10)

local ItemScroll = new("ScrollingFrame", {
    Position = UDim2.new(0, 6, 0, 6), Size = UDim2.new(1, -12, 1, -12),
    BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 3,
    ScrollBarImageColor3 = C.line, CanvasSize = UDim2.new(0, 0, 0, 0),
    AutomaticCanvasSize = Enum.AutomaticSize.Y,
}, ListHolder)
local ItemLayout = new("UIListLayout", {Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder}, ItemScroll)

local EmptyLabel = label({Text = "Select a player on the left", TextColor3 = C.sub, TextSize = 13,
    TextXAlignment = Enum.TextXAlignment.Center, TextWrapped = true,
    Size = UDim2.new(1, -20, 1, 0), Position = UDim2.new(0, 10, 0, 0)}, ListHolder)

-- slot finder bar (only visible on the Slots tab)
local FindBar = new("Frame", {
    Name = "FindBar", Position = UDim2.new(0, 0, 0, 182), Size = UDim2.new(1, 0, 0, 32),
    BackgroundTransparency = 1, Visible = false,
}, Content)
local FindBox = new("TextBox", {
    Name = "FindBox", Position = UDim2.new(0, 0, 0, 0), Size = UDim2.new(0, 150, 1, 0),
    BackgroundColor3 = C.panel, BorderSizePixel = 0, Font = FONT, TextSize = 12,
    TextColor3 = C.text, PlaceholderText = "Find slot name...", PlaceholderColor3 = C.sub,
    Text = "", ClearTextOnFocus = false, TextXAlignment = Enum.TextXAlignment.Left,
}, FindBar)
corner(FindBox, 8)
new("UIPadding", {PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10)}, FindBox)
local FindBtn = new("TextButton", {
    Text = "Find", Font = FONT_B, TextSize = 12, TextColor3 = rgb(255, 255, 255), AutoButtonColor = false,
    BackgroundColor3 = C.accent, BorderSizePixel = 0,
    Position = UDim2.new(0, 156, 0, 0), Size = UDim2.new(0, 64, 1, 0),
}, FindBar)
corner(FindBtn, 8)
pressFx(FindBtn)
local FindStatus = label({Text = "", TextSize = 10, TextColor3 = C.sub, TextWrapped = true,
    TextYAlignment = Enum.TextYAlignment.Center,
    Position = UDim2.new(0, 228, 0, 0), Size = UDim2.new(1, -228, 1, 0)}, FindBar)

-- ========================= UI LOGIC =========================
local function setListMessage(text)
    if text then
        EmptyLabel.Text = text
        EmptyLabel.Visible = true
    else
        EmptyLabel.Visible = false
    end
end

local function setStatus(kind)
    if kind == "live" then
        StatusDot.BackgroundColor3 = C.good
        StatusLabel.Text = "LIVE"
        StatusLabel.TextColor3 = C.good
    elseif kind == "wait" then
        StatusDot.BackgroundColor3 = C.warn
        StatusLabel.Text = "WAITING FOR DATA"
        StatusLabel.TextColor3 = C.warn
    else
        StatusDot.BackgroundColor3 = C.sub
        StatusLabel.Text = "IDLE"
        StatusLabel.TextColor3 = C.sub
    end
end

local function setProgress(pct, color, rainbow)
    rainbowElements[ProgressFill] = nil
    if rainbow then
        rainbowElements[ProgressFill] = "Bg"
    else
        ProgressFill.BackgroundColor3 = color
    end
    tween(ProgressFill, 0.25, {Size = UDim2.new(math.clamp(pct, 0, 1), 0, 1, 0)})
end

local function refreshHeader()
    local pl, tr = selectedPlayer, activeTracker
    if not pl or not tr then
        HeaderName.Text = "Select a player"
        HeaderSub.Text = "Pick someone from the list"
        HeaderAvatar.Image = ""
        HeaderAvatar:SetAttribute("AvatarKey", "")
        BadgeLabel.Text = "-"
        BadgeLabel.TextColor3 = C.sub
        BadgeLabel.TextStrokeTransparency = 1
        rainbowElements[BadgeLabel] = nil
        rainbowElements[BadgeStroke] = nil
        BadgeStroke.Color = C.line
        rainbowElements[HeaderAvatarStroke] = nil
        HeaderAvatarStroke.Color = C.line
        BlocksValue.Text, GoldValue.Text, TypesValue.Text = "-", "-", "-"
        BlocksTag.Text, GoldTag.Text, TypesTag.Text = "", "", ""
        ProgressText.Text, ProgressPct.Text = "", ""
        setProgress(0, C.accent, false)
        setStatus("idle")
        return
    end

    local s = tr.stats
    if not s.hasData then
        BadgeLabel.Text = "NO DATA"
        rainbowElements[BadgeLabel] = nil
        BadgeLabel.TextColor3 = C.sub
        BadgeLabel.TextStrokeTransparency = 1
        rainbowElements[BadgeStroke] = nil
        BadgeStroke.Color = C.line
        rainbowElements[HeaderAvatarStroke] = nil
        HeaderAvatarStroke.Color = C.line
        BlocksValue.Text, GoldValue.Text, TypesValue.Text = "-", "-", "-"
        BlocksTag.Text, GoldTag.Text, TypesTag.Text = "", "", ""
        ProgressText.Text, ProgressPct.Text = "Waiting for the Data folder...", ""
        setProgress(0, C.accent, false)
        setStatus("wait")
        return
    end

    local rank, nextRank = getRank(s.blocks)
    BadgeLabel.Text = rank.name
    styleRankLabel(BadgeLabel, rank)
    styleRankStroke(BadgeStroke, rank)
    styleRankStroke(HeaderAvatarStroke, rank)

    BlocksValue.Text = commas(s.blocks)
    BlocksTag.Text = (math.abs(s.blocks) >= 1000) and short(s.blocks) or ""
    GoldValue.Text = s.hasGold and commas(s.gold) or "-"
    GoldTag.Text = (s.hasGold and math.abs(s.gold) >= 1000) and short(s.gold) or ""
    TypesValue.Text = commas(s.types)
    TypesTag.Text = "of " .. commas(s.kinds)

    if nextRank then
        local pct = (s.blocks - rank.min) / (nextRank.min - rank.min)
        ProgressText.Text = string.format("Next: %s  -  %s to go", nextRank.name, commas(nextRank.min - s.blocks))
        ProgressPct.Text = string.format("%.1f%%", math.clamp(pct, 0, 1) * 100)
        setProgress(pct, rank.color, rank.rainbow)
    else
        ProgressText.Text = "Max rank reached"
        ProgressPct.Text = "100%"
        setProgress(1, rank.color, true)
    end
    setStatus("live")
end

-- share % of each block row (relative to the BLOCKS total)
local function refreshShares()
    local total = activeTracker and activeTracker.stats.blocks or 0
    for _, r in ipairs(rowList) do
        if r.kind == "item" then
            if r.isGold then
                r.sub.Text = "currency"
                r.sub.TextColor3 = C.gold
                r.track.Visible = false
            else
                r.track.Visible = true
                local pct = (total > 0 and r.num > 0) and math.clamp(r.num / total, 0, 1) or 0
                local pctText
                if pct == 0 then
                    pctText = "0%"
                elseif pct * 100 < 0.01 then
                    pctText = "<0.01%"
                else
                    pctText = string.format("%.2f%%", pct * 100)
                end
                if math.abs(r.num) >= 1000 then
                    pctText = pctText .. "  |  " .. short(r.num)
                end
                r.sub.Text = pctText
                r.sub.TextColor3 = C.sub
                r.fill.Size = UDim2.new(pct, 0, 1, 0)
            end
        end
    end
end

onActiveStatsChanged = function()
    refreshHeader()
    refreshShares()
end

-- search filter
local function applyFilter()
    local q = string.lower(SearchBar.Text)
    local shown = 0
    for _, r in ipairs(rowList) do
        local ok = (q == "") or (string.find(r.search, q, 1, true) ~= nil)
        r.container.Visible = ok
        if ok then shown = shown + 1 end
    end
    if listLoading or not selectedPlayer then return end
    if #rowList == 0 then
        setListMessage("Nothing to show")
    elseif shown == 0 then
        setListMessage("No match for \"" .. SearchBar.Text .. "\"")
    else
        setListMessage(nil)
    end
end
track(SearchBar:GetPropertyChangedSignal("Text"):Connect(applyFilter))

local function applySortOrder()
    if currentTab == "Items" and sortMode == "Name" then
        ItemLayout.SortOrder = Enum.SortOrder.Name
    else
        ItemLayout.SortOrder = Enum.SortOrder.LayoutOrder
    end
end

local function clearRows()
    for _, c in ipairs(liveConnections) do c:Disconnect() end
    liveConnections = {}
    for _, r in ipairs(rowList) do
        rainbowElements[r.value] = nil
        shakingFrames[r.row] = nil
        for _, img in ipairs(r.images) do rainbowElements[img] = nil end
    end
    for _, child in ipairs(ItemScroll:GetChildren()) do
        if child:IsA("Frame") then child:Destroy() end
    end
    rowList = {}
    rowByItem = {}
end

local function removeRowFor(item)
    local rec = rowByItem[item]
    if not rec then return end
    rowByItem[item] = nil
    for i, r in ipairs(rowList) do
        if r == rec then
            table.remove(rowList, i)
            break
        end
    end
    rainbowElements[rec.value] = nil
    shakingFrames[rec.row] = nil
    for _, img in ipairs(rec.images) do rainbowElements[img] = nil end
    rec.container:Destroy()
    applyFilter()
end

local FALLBACK_IMAGE = "rbxassetid://12328114032"

local function newValueLabel(parent, props)
    local p = {
        Font = FONT_B, TextXAlignment = Enum.TextXAlignment.Right,
    }
    for k, v in pairs(props) do p[k] = v end
    return label(p, parent)
end

local function addItemRow(item)
    if rowByItem[item] or not item:IsA("ValueBase") or isFiltered(item.Name) then return end
    local gold = isGoldName(item.Name)

    local container = new("Frame", {
        Name = item.Name, Size = UDim2.new(1, 0, 0, 36), BackgroundTransparency = 1,
    }, ItemScroll)
    local row = new("Frame", {
        Name = "RowFrame", Size = UDim2.new(1, 0, 1, 0), BackgroundColor3 = C.card, BorderSizePixel = 0,
    }, container)
    corner(row, 7)

    local typeIconAsset, frameButtonAsset = getInventoryTemplateData(item.Name)
    local buttonDecal = new("ImageLabel", {
        Size = UDim2.new(0, 26, 0, 26), Position = UDim2.new(0, 6, 0, 5), BackgroundTransparency = 1,
        Image = (frameButtonAsset ~= "") and frameButtonAsset or FALLBACK_IMAGE,
    }, row)
    local typeDecal = new("ImageLabel", {
        Size = UDim2.new(0, 26, 0, 26), Position = UDim2.new(0, 36, 0, 5), BackgroundTransparency = 1,
        Image = (typeIconAsset ~= "") and typeIconAsset or FALLBACK_IMAGE,
    }, row)

    label({Text = item.Name, TextSize = 13, TextTruncate = Enum.TextTruncate.AtEnd,
        Position = UDim2.new(0, 68, 0, 0), Size = UDim2.new(1, -226, 1, -4)}, row)

    local valueLabel = newValueLabel(row, {
        TextScaled = true, AnchorPoint = Vector2.new(1, 0),
        Position = UDim2.new(1, -8, 0, 3), Size = UDim2.new(0, 150, 0, 17),
    })
    new("UITextSizeConstraint", {MaxTextSize = 14, MinTextSize = 8}, valueLabel)
    local subLabel = newValueLabel(row, {
        Font = FONT_M, TextSize = 10, TextColor3 = C.sub, AnchorPoint = Vector2.new(1, 0),
        Position = UDim2.new(1, -8, 0, 20), Size = UDim2.new(0, 150, 0, 11),
    })

    local track_ = new("Frame", {
        Position = UDim2.new(0, 8, 1, -5), Size = UDim2.new(1, -16, 0, 2),
        BackgroundColor3 = C.line, BorderSizePixel = 0,
    }, row)
    corner(track_, 1)
    local fill = new("Frame", {
        Size = UDim2.new(0, 0, 1, 0), BackgroundColor3 = C.accent, BorderSizePixel = 0,
    }, track_)
    corner(fill, 1)

    local rec = {
        kind = "item", item = item, container = container, row = row, value = valueLabel,
        sub = subLabel, track = track_, fill = fill, images = {buttonDecal, typeDecal},
        isGold = gold, num = 0, search = string.lower(item.Name),
    }
    rowByItem[item] = rec
    table.insert(rowList, rec)

    local first = true
    local function update()
        local old = rec.num
        local num = toNumber(item.Value) or 0
        rec.num = num
        valueLabel.Text = commas(num)
        applyValueStyle(row, valueLabel, rec.images, num)
        if not first and num ~= old and num < 10000000 then
            -- quick green (up) / red (down) flash that fades back
            row.BackgroundColor3 = (num > old) and rgb(200, 245, 215) or rgb(255, 214, 214)
            tween(row, 0.7, {BackgroundColor3 = C.card})
        end
        first = false
        if gold then
            container.LayoutOrder = -2147483000
        else
            container.LayoutOrder = -math.floor(math.clamp(num, -2e9, 2e9))
        end
    end
    update()
    table.insert(liveConnections, item.Changed:Connect(update))
end

local function addSlotRow(item)
    if rowByItem[item] or not item:IsA("ValueBase") then return end
    if not string.match(item.Name, "^NameOfSlot%d*$") then return end

    local numValue = tonumber(string.match(item.Name, "%d+$")) or 1
    local display = (numValue > 1) and ("Slot Name " .. tostring(numValue)) or "Slot Name"

    local container = new("Frame", {
        Name = item.Name, Size = UDim2.new(1, 0, 0, 34), BackgroundTransparency = 1,
        LayoutOrder = numValue,
    }, ItemScroll)
    local row = new("Frame", {
        Name = "RowFrame", Size = UDim2.new(1, 0, 1, 0), BackgroundColor3 = C.card, BorderSizePixel = 0,
    }, container)
    corner(row, 7)

    label({Text = display, TextSize = 13, Position = UDim2.new(0, 12, 0, 0),
        Size = UDim2.new(0.4, -12, 1, 0)}, row)
    local valueLabel = newValueLabel(row, {
        TextSize = 13, TextTruncate = Enum.TextTruncate.AtEnd,
        Position = UDim2.new(0.4, 0, 0, 0), Size = UDim2.new(0.6, -12, 1, 0),
    })

    local rec = {
        kind = "slot", item = item, container = container, row = row, value = valueLabel,
        images = {}, search = string.lower(display),
    }
    rowByItem[item] = rec
    table.insert(rowList, rec)

    local function update()
        local raw = item.Value
        local text = tostring(raw)
        rec.search = string.lower(display .. " " .. text)
        if text == "" then
            valueLabel.Text = "(empty)"
            applyValueStyle(row, valueLabel, {}, nil)
            valueLabel.TextColor3 = C.sub
        else
            local num = toNumber(raw)
            valueLabel.Text = num and commas(num) or text
            applyValueStyle(row, valueLabel, {}, num)
        end
        applyFilter()
    end
    update()
    table.insert(liveConnections, item.Changed:Connect(update))
end

local function rebuildList()
    loadToken = loadToken + 1
    local token = loadToken
    clearRows()
    applySortOrder()

    local pl = selectedPlayer
    if not pl then
        listLoading = false
        setListMessage("Select a player on the left")
        return
    end

    listLoading = true
    setListMessage("Loading...")
    local folderName = (currentTab == "Items") and "Data" or "OtherData"
    local build = (currentTab == "Items") and addItemRow or addSlotRow

    task.spawn(function()
        local folder = pl:FindFirstChild(folderName) or pl:WaitForChild(folderName, 5)
        if token ~= loadToken then return end
        if not folder then
            listLoading = false
            setListMessage("No " .. folderName .. " folder found for this player")
            return
        end

        table.insert(liveConnections, folder.ChildAdded:Connect(function(c)
            if token ~= loadToken then return end
            build(c)
            refreshShares()
            applyFilter()
        end))
        table.insert(liveConnections, folder.ChildRemoved:Connect(function(c)
            if token ~= loadToken then return end
            removeRowFor(c)
        end))

        for i, child in ipairs(folder:GetChildren()) do
            if token ~= loadToken then return end
            build(child)
            if i % 20 == 0 then
                task.wait()
                if token ~= loadToken then return end
            end
        end

        listLoading = false
        refreshShares()
        applyFilter()
    end)
end

-- ========================= TABS / SORT =========================
local function refreshTabVisuals()
    local function paint(btn, active)
        btn.BackgroundColor3 = C.accent
        btn.BackgroundTransparency = active and 0 or 1
        btn.TextColor3 = active and rgb(255, 255, 255) or C.sub
    end
    paint(ItemsTab, currentTab == "Items")
    paint(SlotsTab, currentTab == "Slots")
    local items = currentTab == "Items"
    SortBtn.Visible = items
    SearchBar.Size = items and UDim2.new(1, -228, 0, 28) or UDim2.new(1, -136, 0, 28)
    FindBar.Visible = not items
    ListHolder.Position = items and UDim2.new(0, 0, 0, 182) or UDim2.new(0, 0, 0, 220)
    ListHolder.Size = items and UDim2.new(1, 0, 1, -182) or UDim2.new(1, 0, 1, -220)
end

local function setTab(tab)
    if currentTab == tab then return end
    currentTab = tab
    refreshTabVisuals()
    rebuildList()
end
track(ItemsTab.MouseButton1Click:Connect(function() setTab("Items") end))
track(SlotsTab.MouseButton1Click:Connect(function() setTab("Slots") end))

track(SortBtn.MouseButton1Click:Connect(function()
    sortMode = (sortMode == "Amount") and "Name" or "Amount"
    SortBtn.Text = (sortMode == "Amount") and "Sort: Amount" or "Sort: A-Z"
    applySortOrder()
end))
refreshTabVisuals()

-- ========================= PLAYER LIST =========================
local function refreshRowColor(player, hovering)
    local pr = playerRows[player]
    if not pr then return end
    local selected = (player == selectedPlayer)
    pr.accent.Visible = selected
    if selected then
        pr.container.BackgroundColor3 = C.cardHi
    elseif hovering then
        pr.container.BackgroundColor3 = C.hover
    else
        pr.container.BackgroundColor3 = C.card
    end
end

local function updatePlayerRow(pr, s)
    if not s.hasData then
        rainbowElements[pr.rank] = nil
        pr.rank.Text = "[No Data]"
        pr.rank.TextColor3 = C.sub
        pr.rank.TextStrokeTransparency = 1
        rainbowElements[pr.stroke] = nil
        pr.stroke.Color = C.line
        pr.count.Text = "Blocks: -"
        pr.container.LayoutOrder = 0
        return
    end
    local rank = getRank(s.blocks)
    pr.rank.Text = rank.name
    styleRankLabel(pr.rank, rank)
    styleRankStroke(pr.stroke, rank)
    pr.count.Text = "Blocks: " .. commas(s.blocks)
    pr.container.LayoutOrder = -math.floor(math.clamp(s.blocks, -2e9, 2e9))
end

local function selectPlayer(player)
    selectedPlayer = player
    activeTracker = trackers[player]

    HeaderName.Text = player.DisplayName .. ((player == Players.LocalPlayer) and "  (you)" or "")
    HeaderSub.Text = "@" .. player.Name .. "   |   ID " .. tostring(player.UserId)
    HeaderAvatarScale.Scale = 0.7
    bounce(HeaderAvatarScale, 0.5, {Scale = 1})
    loadAvatar(HeaderAvatar, player.UserId, "bust")

    for p in pairs(playerRows) do refreshRowColor(p, false) end
    refreshHeader()
    refreshShares()
    rebuildList()
end

local function updatePlayerCount()
    local n = 0
    for _ in pairs(playerRows) do n = n + 1 end
    PlayerCount.Text = tostring(n)
end

local function addPlayerRow(player)
    if playerRows[player] then return end
    local tr = startTracker(player)

    local container = new("Frame", {
        Name = player.Name, Size = UDim2.new(1, 0, 0, 52), BackgroundColor3 = C.card, BorderSizePixel = 0,
    }, PlayerScroll)
    corner(container, 8)

    local accent = new("Frame", {
        Position = UDim2.new(0, 0, 0.5, -14), Size = UDim2.new(0, 3, 0, 28),
        BackgroundColor3 = C.accent, BorderSizePixel = 0, Visible = false,
    }, container)
    corner(accent, 2)

    local avatar = new("ImageLabel", {
        Size = UDim2.new(0, 36, 0, 36), Position = UDim2.new(0, 10, 0, 8),
        BackgroundColor3 = C.bg, BorderSizePixel = 0, ScaleType = Enum.ScaleType.Crop, Image = "",
    }, container)
    corner(avatar, "full")
    local avatarStroke = outline(avatar, C.line, 2)
    loadAvatar(avatar, player.UserId, "head")

    local nameText = player.DisplayName .. ((player == Players.LocalPlayer) and " (you)" or "")
    label({Text = nameText, Font = FONT_B, TextSize = 12, TextTruncate = Enum.TextTruncate.AtEnd,
        Position = UDim2.new(0, 54, 0, 5), Size = UDim2.new(1, -60, 0, 16)}, container)
    local rankLabel = label({Text = "...", Font = FONT_B, TextSize = 11, TextColor3 = C.sub,
        Position = UDim2.new(0, 54, 0, 21), Size = UDim2.new(1, -60, 0, 14)}, container)
    local countLabel = label({Text = "Blocks: ...", TextSize = 10, TextColor3 = C.sub,
        TextTruncate = Enum.TextTruncate.AtEnd,
        Position = UDim2.new(0, 54, 0, 35), Size = UDim2.new(1, -60, 0, 12)}, container)

    local btn = new("TextButton", {
        Text = "", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 1, 0), ZIndex = 5,
    }, container)

    local pr = {container = container, accent = accent, rank = rankLabel, count = countLabel, stroke = avatarStroke}
    playerRows[player] = pr
    table.insert(tr.listeners, function(s) updatePlayerRow(pr, s) end)
    updatePlayerRow(pr, tr.stats)

    local avScale = new("UIScale", {Scale = 1}, avatar)
    track(btn.MouseButton1Down:Connect(function()
        ripple(container)
        tween(avScale, 0.07, {Scale = 0.8})
    end))
    local function avRelease() bounce(avScale, 0.5, {Scale = 1}) end
    track(btn.MouseButton1Up:Connect(avRelease))
    track(btn.MouseLeave:Connect(avRelease))
    track(btn.MouseButton1Click:Connect(function() selectPlayer(player) end))
    track(btn.MouseEnter:Connect(function() refreshRowColor(player, true) end))
    track(btn.MouseLeave:Connect(function() refreshRowColor(player, false) end))
    updatePlayerCount()
end

local function removePlayerRow(player)
    local pr = playerRows[player]
    if pr then
        rainbowElements[pr.rank] = nil
        rainbowElements[pr.stroke] = nil
        pr.container:Destroy()
        playerRows[player] = nil
    end
    stopTracker(player)
    updatePlayerCount()

    if selectedPlayer == player then
        selectedPlayer = nil
        activeTracker = nil
        SearchBar.Text = ""
        refreshHeader()
        rebuildList()
    end
end

-- ========================= SLOT FINDER (SERVER HOP) =========================
local hasFS = type(writefile) == "function" and type(readfile) == "function" and type(isfile) == "function"

local function trim(str)
    return (str:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function newFindState()
    return {query = "", active = false, visited = {}, hops = 0, hopAt = 0, placeId = 0, foundJob = ""}
end

local findState = newFindState()
do
    if hasFS then
        local ok, data = pcall(function()
            if isfile(Config.FindFile) then
                return HttpService:JSONDecode(readfile(Config.FindFile))
            end
        end)
        if ok and type(data) == "table" then
            for k in pairs(findState) do
                if data[k] ~= nil then findState[k] = data[k] end
            end
        end
    end
    if type(findState.visited) ~= "table" then findState.visited = {} end
end

local function saveFindState()
    if not hasFS then return end
    pcall(function()
        writefile(Config.FindFile, HttpService:JSONEncode(findState))
    end)
end

-- did this execution come from our own teleport? (set by the queued bootstrap, one-shot)
local resumeFlag = false
pcall(function()
    local env = getgenv()
    resumeFlag = (env.__InvTrackerResume == true)
    env.__InvTrackerResume = nil
end)

local finding = false
local findToken = 0
local teleportFailed = false
local queuedThisSession = false

local function getQueueFn()
    local ok, fn = pcall(function()
        return queue_on_teleport or queueonteleport or (syn and syn.queue_on_teleport)
            or (fluxus and fluxus.queue_on_teleport)
    end)
    if ok and type(fn) == "function" then return fn end
    return nil
end

local function getBootstrap()
    local pre = "getgenv().__InvTrackerResume = true\n"
    if Config.ScriptUrl ~= "" then
        return pre .. "loadstring(game:HttpGet(\"" .. Config.ScriptUrl .. "\"))()"
    end
    -- preferred: the loader leaves the full source in getgenv, so no file is needed
    local OPEN, CLOSE = "[" .. "==[", "]" .. "==]"   -- built in pieces so they never end a long string early
    local okS, embedded = pcall(function() return getgenv().__InvTrackerSrc end)
    if okS and type(embedded) == "string" and embedded ~= "" and not string.find(embedded, CLOSE, 1, true) then
        return pre .. "getgenv().__InvTrackerSrc = " .. OPEN .. "\n" .. embedded .. "\n" .. CLOSE
            .. "\nloadstring(getgenv().__InvTrackerSrc)()"
    end
    local ok, exists = pcall(function() return hasFS and isfile(Config.ScriptFile) end)
    if ok and exists then
        return pre .. "loadstring(readfile(\"" .. Config.ScriptFile .. "\"))()"
    end
    return nil
end

local function httpGet(url)
    local ok, res = pcall(function() return game:HttpGet(url) end)
    if ok and type(res) == "string" and res ~= "" then return res end
    local ok2, req = pcall(function() return request or http_request or (syn and syn.request) end)
    if ok2 and type(req) == "function" then
        local ok3, r = pcall(req, {Url = url, Method = "GET"})
        if ok3 and type(r) == "table" and type(r.Body) == "string" and r.Body ~= "" then
            return r.Body
        end
    end
    return nil
end

local function setFindStatus(text, color)
    FindStatus.Text = text
    FindStatus.TextColor3 = color or C.sub
end

local function setFinding(on)
    finding = on
    FindBtn.Text = on and "Stop" or "Find"
    FindBtn.BackgroundColor3 = on and C.bad or C.accent
end

local function stopFind(msg, color)
    findToken = findToken + 1
    setFinding(false)
    findState.active = false
    saveFindState()
    setFindStatus(msg or "Stopped", color or C.sub)
end

-- look through every player's OtherData slots for the query (partial, case-insensitive)
local function scanServer(q, token)
    local lp = Players.LocalPlayer
    local t0 = os.clock()
    while token == findToken do
        local total, ready = 0, 0
        for _, pl in ipairs(Players:GetPlayers()) do
            if pl ~= lp or Config.SearchSelf then
                total = total + 1
                local od = pl:FindFirstChild("OtherData")
                local hasSlots = false
                if od then
                    for _, v in ipairs(od:GetChildren()) do
                        if v:IsA("ValueBase") and string.match(v.Name, "^NameOfSlot%d*$") then
                            hasSlots = true
                            local text = tostring(v.Value)
                            if text ~= "" and string.find(string.lower(text), q, 1, true) then
                                return pl, v
                            end
                        end
                    end
                end
                if hasSlots then ready = ready + 1 end
            end
        end
        if total == 0 then return nil end   -- nobody else here
        local elapsed = os.clock() - t0
        if elapsed >= Config.ScanTimeout or (ready == total and elapsed >= Config.ScanMinStay) then
            return nil
        end
        task.wait(0.4)
    end
    return nil
end

-- returns server, nil  |  nil, "http"  |  nil, "empty"
local function pickServer(token)
    local visited = findState.visited
    local pool = {}
    local cursor
    local gotAny = false
    for _ = 1, Config.ServerPages do
        if token ~= findToken then return nil, "http" end
        local url = "https://games.roblox.com/v1/games/" .. tostring(game.PlaceId)
            .. "/servers/Public?sortOrder=Desc&limit=100"
        if cursor then url = url .. "&cursor=" .. cursor end
        local body = httpGet(url)
        if not body then break end
        local ok, data = pcall(function() return HttpService:JSONDecode(body) end)
        if not ok or type(data) ~= "table" or type(data.data) ~= "table" then break end
        gotAny = true
        for _, sv in ipairs(data.data) do
            local playing, maxP = sv.playing or 0, sv.maxPlayers or 0
            if sv.id ~= game.JobId and not visited[sv.id] and playing >= 1 and playing < maxP then
                table.insert(pool, sv)
            end
        end
        cursor = data.nextPageCursor
        if not cursor or #pool >= 25 then break end
    end
    if #pool > 0 then
        return pool[math.random(#pool)], nil
    end
    return nil, gotAny and "empty" or "http"
end

local function onFound(pl, v)
    findToken = findToken + 1
    setFinding(false)
    findState.active = false
    findState.foundJob = game.JobId
    saveFindState()

    local text = tostring(v.Value)
    local slotNo = tonumber(string.match(v.Name, "%d+$")) or 1
    local slotName = (slotNo > 1) and ("Slot Name " .. slotNo) or "Slot Name"
    setFindStatus(string.format("FOUND  %s  -  %s: %s", pl.DisplayName, slotName, text), C.good)

    -- show it in the list
    if currentTab ~= "Slots" then setTab("Slots") end
    selectPlayer(pl)
    SearchBar.Text = findState.query

    pcall(function()
        StarterGui:SetCore("SendNotification", {
            Title = "Inventory Tracker",
            Text = "Found \"" .. text .. "\" on " .. pl.DisplayName,
            Duration = 10,
        })
    end)
end

local function runFind(token, skipFirstScan)
    local q = string.lower(findState.query)
    local first = true
    while token == findToken do
        -- 1) scan this server
        if not (first and skipFirstScan) then
            setFindStatus(string.format("Scanning this server...  (hops: %d)", findState.hops), C.warn)
            local pl, v = scanServer(q, token)
            if token ~= findToken then return end
            if pl then
                onFound(pl, v)
                return
            end
        end
        first = false

        -- 2) choose a server we have not visited yet
        setFindStatus("Looking for a new server...", C.warn)
        local server, why = pickServer(token)
        if token ~= findToken then return end
        if not server then
            if why == "empty" then
                findState.visited = {}
                saveFindState()
                setFindStatus("Visited every listed server, restarting the list...", C.warn)
                task.wait(3)
            else
                setFindStatus("Server list unavailable (rate limit?), retrying...", C.warn)
                task.wait(6)
            end
            continue
        end

        -- 3) hop
        local n = 0
        for _ in pairs(findState.visited) do n = n + 1 end
        if n > 3000 then findState.visited = {} end
        findState.visited[game.JobId] = true
        findState.visited[server.id] = true
        findState.hops = findState.hops + 1
        findState.hopAt = os.time()
        findState.placeId = game.PlaceId
        findState.active = true
        saveFindState()

        teleportFailed = false
        setFindStatus(string.format("Teleporting to a new server...  (hop #%d)", findState.hops), C.accent)
        local ok = pcall(function()
            TeleportService:TeleportToPlaceInstance(game.PlaceId, server.id, Players.LocalPlayer)
        end)
        local t0 = os.clock()
        while token == findToken and ok and not teleportFailed and os.clock() - t0 < Config.TeleportTimeout do
            task.wait(0.25)
        end
        if token ~= findToken then return end
        setFindStatus("Teleport failed, trying another server...", C.warn)
        task.wait(1.5)
    end
end

local function startFind(resuming)
    local raw = resuming and findState.query or trim(FindBox.Text)
    if raw == "" then
        setFindStatus("Type a slot name first", C.warn)
        return
    end
    if not hasFS then
        setFindStatus("This executor has no file functions (writefile/readfile)", C.bad)
        return
    end
    local queueFn = getQueueFn()
    if not queueFn then
        setFindStatus("This executor has no queue_on_teleport", C.bad)
        return
    end
    local bootstrap = getBootstrap()
    if not bootstrap then
        setFindStatus("Run InventoryTracker_loader.lua (not the plain script), or set Config.ScriptUrl", C.bad)
        return
    end

    local sameQuery = (findState.query == raw)
    if not sameQuery then
        findState.visited = {}
        findState.hops = 0
        findState.foundJob = ""
    end
    findState.query = raw
    findState.active = true
    findState.placeId = game.PlaceId
    findState.hopAt = os.time()
    saveFindState()                       -- keep the name in the local file

    if not queuedThisSession then
        local ok = pcall(queueFn, bootstrap)
        if not ok then
            findState.active = false
            saveFindState()
            setFindStatus("queue_on_teleport failed", C.bad)
            return
        end
        queuedThisSession = true
    end

    findToken = findToken + 1
    local token = findToken
    setFinding(true)
    -- pressing Find again inside the server where it was already found -> skip that server
    local skip = (not resuming) and sameQuery and findState.foundJob == game.JobId
    task.spawn(runFind, token, skip)
end

track(TeleportService.TeleportInitFailed:Connect(function()
    teleportFailed = true
end))

track(FindBtn.MouseButton1Click:Connect(function()
    if finding then
        stopFind("Stopped.  Saved: \"" .. findState.query .. "\"", C.sub)
    else
        startFind(false)
    end
end))
track(FindBox.FocusLost:Connect(function(enter)
    if enter and not finding then startFind(false) end
end))

if findState.query ~= "" then FindBox.Text = findState.query end

-- ========================= WINDOW BUTTONS =========================
local minimized = false
track(MinBtn.MouseButton1Click:Connect(function()
    minimized = not minimized
    MinBtn.Text = minimized and "+" or "-"
    do
        local shift = (WIN_H - TITLE_H) / 2 * WindowScale.Scale / math.max(ScreenGui.AbsoluteSize.Y, 1)
        DragSpring.ty = DragSpring.ty + (minimized and -shift or shift)
    end
    if minimized then
        Hub.setChrome(false)
        tween(Window, 0.2, {Size = UDim2.new(0, WIN_W, 0, TITLE_H)})
    else
        Hub.setChrome(true)
        bounce(Window, 0.45, {Size = UDim2.new(0, WIN_W, 0, WIN_H)})
    end
end))

local function cleanup()
    if Hub.stopView then pcall(Hub.stopView) end   -- give the camera back
    findToken = findToken + 1   -- stops a running search loop (in memory only, the file is untouched)
    pcall(AB.clearPreview)
    AB.setSink(nil)
    for _, c in ipairs(connections) do pcall(function() c:Disconnect() end) end
    connections = {}
    for _, c in ipairs(liveConnections) do pcall(function() c:Disconnect() end) end
    liveConnections = {}
    for player in pairs(trackers) do stopTracker(player) end
    if ScreenGui then ScreenGui:Destroy() end
end
track(CloseBtn.MouseButton1Click:Connect(function()
    if finding then stopFind("Stopped") end
    cleanup()
end))

track(UserInputService.InputBegan:Connect(function(input, processed)
    if processed then return end
    if input.KeyCode == Config.ToggleKey then
        Window.Visible = not Window.Visible
    end
end))

-- ========================= START =========================
track(Players.PlayerAdded:Connect(addPlayerRow))
track(Players.PlayerRemoving:Connect(removePlayerRow))
for _, p in ipairs(Players:GetPlayers()) do
    addPlayerRow(p)
end

refreshHeader()
if Config.AutoSelectSelf and Players.LocalPlayer and playerRows[Players.LocalPlayer] then
    selectPlayer(Players.LocalPlayer)
end

-- pop-in
bounce(WindowScale, 0.55, {Scale = uiScale})

-- slot finder: continue ONLY if we just arrived through our own hop; a normal join / re-execute stays paused
do
    local canResume = resumeFlag and findState.active and findState.query ~= ""
        and findState.placeId == game.PlaceId
        and (os.time() - (tonumber(findState.hopAt) or 0)) <= Config.ResumeWindow
    if canResume then
        task.spawn(function()
            if not game:IsLoaded() then game.Loaded:Wait() end
            task.wait(Config.ArriveDelay)
            if not ScreenGui.Parent then return end
            Hub.show("inventory")
            setTab("Slots")
            startFind(true)
        end)
    else
        if findState.active then
            findState.active = false
            saveFindState()
        end
        if findState.query ~= "" then
            setFindStatus(string.format("Paused. Saved: \"%s\"  -  press Find to continue", findState.query), C.sub)
        end
    end
end

-- Auto Build on Join (skipped while the slot finder is hopping servers)
task.spawn(function()
    if not AB.farmSettings.autoBuild then return end
    if resumeFlag and findState.active then return end
    task.wait(Config.AutoBuildDelay)
    if not ScreenGui.Parent or not AB.farmSettings.autoBuild then return end
    Hub.status("Auto Build on Join: starting...", "info")
    pcall(AB.runAutoBuild, Hub.setProgress)
end)

pcall(function()
    getgenv().__InvTrackerCleanup = cleanup
end)

]==]

pcall(function() getgenv().__InvTrackerSrc = SRC end)
pcall(function()
    if writefile then writefile("AutoBuildHub.lua", SRC) end
end)

local fn, err = loadstring(SRC)
if fn then
    fn()
else
    warn("Auto Build Hub load error: " .. tostring(err))
end
