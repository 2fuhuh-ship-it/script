--[[
    Inventory Tracker v2  (Delta / Luau)  -  white glass edition
    - Player list with avatars, sorted by total blocks
    - Header card: avatar, rank badge, rank progress (exact "to go" + %)
    - Stat cards: Blocks / Gold / Item Types (full number + short form)
    - Items / Slots tabs, search, sort (Amount / A-Z)
    - Every item row shows the exact number and its share (%) of total blocks
    - Bottom-left, semi-transparent white UI, springy drag, press ripple + bounce
    - Toggle: RightShift (PC)  |  "-" minimize  |  "X" close
    - NEW: Slots tab -> "Find" bar: type a slot name (partial match), it is saved to a local file
      and the script hops to a NEW server each time until somebody has a matching slot, then stops.
      Leaving the game mid-search cancels it; after rejoining it only continues if you press Find.
]]

-- ========================= CONFIG =========================
local Config = {
    -- false: BLOCKS total = exactly the sum of the rows you can see in the list
    -- true : also count hidden items (Tool / names ending in X, Y, Z, XY, XZ, YZ) like the old script
    CountFilteredItems = false,
    AutoSelectSelf = true,
    ShakeFx = true,
    ToggleKey = Enum.KeyCode.RightShift,
    Glass = 0.12,   -- window transparency (0 = solid, 1 = invisible); panels/cards follow it
    Scale = 0.85,   -- max UI size (1 = full size); it also auto-shrinks on small screens

    -- ---------- Slot finder (server hop) ----------
    FindFile = "InventoryTracker_find.json",  -- local save file (executor workspace folder)
    -- The script must reload itself after every teleport. Use ONE of these:
    --   ScriptUrl : raw link of this script (loadstring(game:HttpGet(url)))
    --   ScriptFile: save this script in your executor's workspace folder with this exact name
    ScriptUrl = "",
    ScriptFile = "InventoryTracker.lua",
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

local GUI_NAME = "InventoryTrackerGui"

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
        local old = root:FindFirstChild(GUI_NAME)
        if old then old:Destroy() end
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
    if tpl then
        local ti = tpl:FindFirstChild("TypeIcon")
        if ti and ti:IsA("ImageLabel") then typeIconId = ti.Image end
        if tpl:IsA("ImageButton") then frameImageId = tpl.Image end
        templateCache[itemName] = {typeIconId, frameImageId}
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
local WIN_W, WIN_H, TITLE_H = 640, 440, 40
local MARGIN = 10
local camera = workspace.CurrentCamera
local viewport = camera and camera.ViewportSize or Vector2.new(1280, 720)
local uiScale = math.clamp(math.min(viewport.X / (WIN_W + 60), viewport.Y / (WIN_H + 50), Config.Scale), 0.45, 1)

-- anchored at the bottom-left corner
local Window = new("Frame", {
    Name = "Window",
    AnchorPoint = Vector2.new(0, 1),
    Size = UDim2.new(0, WIN_W, 0, WIN_H),
    Position = UDim2.new(MARGIN / viewport.X, 0, 1 - MARGIN / viewport.Y, 0),
    BackgroundColor3 = C.bg, BorderSizePixel = 0, ClipsDescendants = true, Active = true,
}, ScreenGui)
corner(Window, 12)
outline(Window, C.line, 1)
local WindowScale = new("UIScale", {Scale = uiScale * 0.85}, Window)

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
label({Text = "Inventory Tracker", Font = FONT_B, TextSize = 15,
    Position = UDim2.new(0, 32, 0, 0), Size = UDim2.new(0, 150, 1, 0)}, TitleBar)
label({Text = "v2  |  blocks / gold / slots", TextSize = 11, TextColor3 = C.sub,
    Position = UDim2.new(0, 186, 0, 0), Size = UDim2.new(0, 200, 1, 0)}, TitleBar)

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

-- press = shrink + ripple, release = springy bounce back
local function pressFx(btn)
    btn.ClipsDescendants = true
    local sc = new("UIScale", {Scale = 1}, btn)
    track(btn.MouseButton1Down:Connect(function()
        tween(sc, 0.07, {Scale = 0.88})
        ripple(btn)
    end))
    local function release()
        bounce(sc, 0.45, {Scale = 1})
    end
    track(btn.MouseButton1Up:Connect(release))
    track(btn.MouseLeave:Connect(release))
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

local Body = new("Frame", {
    Name = "Body", Position = UDim2.new(0, 0, 0, TITLE_H), Size = UDim2.new(1, 0, 1, -TITLE_H),
    BackgroundTransparency = 1,
}, Window)

-- dragging: the window follows through a spring (slight delay + overshoot)
do
    local sp = {
        x = Window.Position.X.Scale, y = Window.Position.Y.Scale, vx = 0, vy = 0,
        tx = Window.Position.X.Scale, ty = Window.Position.Y.Scale,
    }
    local K, D = 170, 16          -- stiffness / damping (lower D = more bounce)
    local dragging, dragStart, startX, startY = false, nil, 0, 0

    track(TitleBar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startX, startY = sp.tx, sp.ty
            bounce(WindowScale, 0.25, {Scale = uiScale * 1.03})
            local changed
            changed = input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                    changed:Disconnect()
                    bounce(WindowScale, 0.5, {Scale = uiScale})
                end
            end)
        end
    end))
    track(UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch) then
            local size = ScreenGui.AbsoluteSize
            local d = input.Position - dragStart
            sp.tx = math.clamp(startX + d.X / size.X, -0.25, 0.92)
            sp.ty = math.clamp(startY + d.Y / size.Y, 0.12, 1.02)
        end
    end))
    track(RunService.Heartbeat:Connect(function(dt)
        dt = math.min(dt, 1 / 30)
        local dx, dy = sp.tx - sp.x, sp.ty - sp.y
        if math.abs(dx) + math.abs(dy) + math.abs(sp.vx) + math.abs(sp.vy) < 2e-4 then
            if sp.x ~= sp.tx or sp.y ~= sp.ty then
                sp.x, sp.y, sp.vx, sp.vy = sp.tx, sp.ty, 0, 0
                Window.Position = UDim2.new(sp.x, 0, sp.y, 0)
            end
            return
        end
        sp.vx = sp.vx + (K * dx - D * sp.vx) * dt
        sp.vy = sp.vy + (K * dy - D * sp.vy) * dt
        sp.x = sp.x + sp.vx * dt
        sp.y = sp.y + sp.vy * dt
        Window.Position = UDim2.new(sp.x, 0, sp.y, 0)
    end))
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
        setFindStatus("Set Config.ScriptUrl, or save this script in the workspace as " .. Config.ScriptFile, C.bad)
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
    if minimized then
        Body.Visible = false
        tween(Window, 0.2, {Size = UDim2.new(0, WIN_W, 0, TITLE_H)})
    else
        Body.Visible = true
        bounce(Window, 0.45, {Size = UDim2.new(0, WIN_W, 0, WIN_H)})
    end
end))

local function cleanup()
    findToken = findToken + 1   -- stops a running search loop (in memory only, the file is untouched)
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

pcall(function()
    getgenv().__InvTrackerCleanup = cleanup
end)
