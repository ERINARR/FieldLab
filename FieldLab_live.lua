-- FIELDLAB_BUILD: 8.6.10
-- Managed runtime capsule. The loader compiles new code before replacing the app.
-- A reload is a clean app restart, not an in-place rewrite of executing Lua functions.
do
    local env = (type(getgenv) == "function" and getgenv()) or _G
    local old = env.__FIELDLAB_APP
    if type(old) == "table" and type(old.Stop) == "function" then
        if env.__FIELDLAB_RESTORE == nil and type(old.Snapshot) == "function" then
            local ok, saved = pcall(old.Snapshot)
            if ok then env.__FIELDLAB_RESTORE = saved end
        end
        pcall(old.Stop)
    end
    local runtime = {Version = "8.6.10", Ready = false}
    function runtime.Stop()
        runtime.Ready = false
        -- Safe even if initialization failed before cleanup callbacks were installed.
        local player = game:GetService("Players").LocalPlayer
        local pg = player and player:FindFirstChildOfClass("PlayerGui")
        local gui = pg and pg:FindFirstChild("BSSHiveFieldUI")
        if gui then gui:Destroy() end
    end
    env.__FIELDLAB_APP = runtime
end

-- BSS HIVE / FIELD MANAGER v8.6.10 (Midnight UI + Managed Live Runtime)
-- Inventory is initialized inside its own function scope to keep the
-- main script below the Luau per-function local-register limit.
-- Farm: stable walking, Flame Heat, Precise Crosshair, Digital Bee Duped Tokens

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local PathfindingService = game:GetService("PathfindingService")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local VIM = game:GetService("VirtualInputManager")
local GuiService = game:GetService("GuiService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local HivePlatforms = workspace:WaitForChild("HivePlatforms")
local FlowerZones = workspace:WaitForChild("FlowerZones")

local TweenSpeed = 100
local WalkSpeed = 90
local HiveHeightOffset = 3
local selectedField = nil
local farmEnabled, clickEnabled = false, false
local farmToken, clickToken = 0, 0
local currentHiveTween = nil
local currentFarmTravelTween = nil
local hiveBusy = true
-- Combat is defined after the Farm UI. These callbacks give manual controls priority.
local CombatSignals = {PlanterBusy = false, AntBusy = false, AntCancel = nil, AntStatus = "", ToyBusy = false, ToyCancel = nil, LootBusy = false, Sprinkler = {Enabled = false, LastField = nil, LastAt = 0, RetryAt = 0, LastCharacter = nil}}
-- Combat-owned Stump Farm uses this shared avoidance state. Other farms are unaffected.
CombatSignals.AvoidMob = nil

-- v7.7: One physics-based flight controller shared by Hive / Farm / Combat / Quest.
-- Avoid several HumanoidRootPart CFrame tweens fighting physics or each other.
-- v8.4: pluggable JSON-safe settings. Modules register their own get/set callbacks.
-- Only preferences are restored; active jobs are never resumed automatically.
local ConfigManager = {Providers = {}, AutoLoad = true, Schema = 1}
function ConfigManager.Register(name, getter, setter)
    ConfigManager.Providers[name] = {Get = getter, Set = setter}
end
function ConfigManager.Capture()
    local sections = {}
    for name, provider in pairs(ConfigManager.Providers) do
        local ok, data = pcall(provider.Get)
        if ok and type(data) == "table" then sections[name] = data
        elseif not ok then warn("[BSS Config Capture]", name, data) end
    end
    return {Schema = ConfigManager.Schema, AutoLoad = ConfigManager.AutoLoad,
        Sections = sections}
end
function ConfigManager.Apply(data)
    if type(data) ~= "table" or type(data.Sections) ~= "table" then
        return false, "JSON must contain a Sections object"
    end
    if data.Schema and tonumber(data.Schema) ~= ConfigManager.Schema then
        return false, "Unsupported config schema " .. tostring(data.Schema)
    end
    if type(data.AutoLoad) == "boolean" then ConfigManager.AutoLoad = data.AutoLoad end
    local count = 0
    local errors = {}
    for name, provider in pairs(ConfigManager.Providers) do
        local section = data.Sections[name]
        if type(section) == "table" then
            local ok, err = pcall(provider.Set, section)
            if ok then count += 1
            else table.insert(errors, name .. ": " .. tostring(err)) end
        end
    end
    if #errors > 0 then return false, table.concat(errors, " | ") end
    return true, "Restored " .. count .. " settings sections"
end

local SmoothFlight = {}
do
    local active = nil
    local function release(handle)
        if not handle or handle.Closed then return end
        handle.Closed = true
        if handle.NoClipConnection then handle.NoClipConnection:Disconnect(); handle.NoClipConnection = nil end
        if handle.PartAddedConnection then handle.PartAddedConnection:Disconnect(); handle.PartAddedConnection = nil end
        if handle.Constraint then handle.Constraint:Destroy(); handle.Constraint = nil end
        if handle.Attachment then handle.Attachment:Destroy(); handle.Attachment = nil end
        if active == handle then active = nil end
        for part, originalCollide in pairs(handle.CollisionStates or {}) do
            if part.Parent then part.CanCollide = originalCollide end
        end
        local root, humanoid = handle.Root, handle.Humanoid
        if root and root.Parent then
            root.AssemblyLinearVelocity = Vector3.zero
            root.AssemblyAngularVelocity = Vector3.zero
        end
        if humanoid and humanoid.Parent then
            humanoid.AutoRotate = handle.OldAutoRotate
            if humanoid.Health > 0 then
                humanoid:ChangeState(Enum.HumanoidStateType.Freefall)
            end
        end
    end

    function SmoothFlight.Begin(root, speed)
        if active then active:Cancel() end
        if not root or not root.Parent then return nil end
        local humanoid = root.Parent:FindFirstChildOfClass("Humanoid")
        if not humanoid or humanoid.Health <= 0 then return nil end
        local handle = {
            Root = root, Humanoid = humanoid, OldAutoRotate = humanoid.AutoRotate,
            Closed = false, Target = root.Position, CollisionStates = {},
        }
        function handle:Cancel() release(self) end
        local attachment = Instance.new("Attachment")
        attachment.Name = "BSSSmoothFlightAttachment"
        attachment.Parent = root
        local constraint = Instance.new("AlignPosition")
        constraint.Name = "BSSSmoothFlightPosition"
        constraint.Mode = Enum.PositionAlignmentMode.OneAttachment
        constraint.Attachment0 = attachment
        constraint.ApplyAtCenterOfMass = true
        constraint.RigidityEnabled = false
        constraint.MaxForce = math.max(200000, root.AssemblyMass * workspace.Gravity * 45)
        constraint.MaxVelocity = math.clamp(tonumber(speed) or 85, 12, 200)
        constraint.Responsiveness = 19
        constraint.Position = root.Position
        constraint.Parent = root
        handle.Attachment, handle.Constraint = attachment, constraint
        -- NoClip must remain active for the WHOLE flight. The game can toggle
        -- CanCollide again mid-flight, so setting it once is not sufficient.
        -- Only change the local character; restore originals when flight ends.
        local function noClipPart(part)
            if not part:IsA("BasePart") then return end
            if handle.CollisionStates[part] == nil then
                handle.CollisionStates[part] = part.CanCollide
            end
            if part.CanCollide then part.CanCollide = false end
        end
        for _, part in ipairs(root.Parent:GetDescendants()) do noClipPart(part) end
        handle.PartAddedConnection = root.Parent.DescendantAdded:Connect(noClipPart)
        handle.NoClipConnection = RunService.Stepped:Connect(function()
            if handle.Closed then return end
            for part in pairs(handle.CollisionStates) do
                if part.Parent and part.CanCollide then part.CanCollide = false end
            end
        end)
        root.AssemblyLinearVelocity = Vector3.zero
        root.AssemblyAngularVelocity = Vector3.zero
        humanoid.AutoRotate = false
        humanoid:Move(Vector3.zero, false)
        humanoid:ChangeState(Enum.HumanoidStateType.Physics)
        active = handle
        return handle
    end

    function SmoothFlight.Move(handle, destination, keepGoing, tolerance)
        if not handle or handle.Closed or typeof(destination) ~= "Vector3" then return false end
        local root = handle.Root
        local allowedError = tolerance or 2.5
        local initialDistance = (root.Position - destination).Magnitude
        local limit = os.clock() + math.max(3.5, initialDistance / math.max(handle.Constraint.MaxVelocity, 12) * 3 + 2.5)
        handle.Target = destination
        handle.Constraint.Position = destination
        local closeTicks = 0
        while not handle.Closed and active == handle and root.Parent
            and handle.Humanoid.Health > 0 do
            if keepGoing and not keepGoing() then return false end
            local delta = (root.Position - destination).Magnitude
            if delta <= allowedError then
                closeTicks += 1
                if closeTicks >= 2 then return true end
            else
                closeTicks = 0
            end
            if os.clock() > limit then return false end
            task.wait(0.035)
        end
        return false
    end

    function SmoothFlight.Path(root, waypoints, keepGoing, speed, setHandle)
        if keepGoing and not keepGoing() then return false end
        local handle = SmoothFlight.Begin(root, speed)
        if not handle then return false end
        if setHandle then setHandle(handle) end
        local ok, reached = pcall(function()
            for _, position in ipairs(waypoints) do
                if not SmoothFlight.Move(handle, position, keepGoing, 2.5) then
                    return false
                end
            end
            return not keepGoing or keepGoing()
        end)
        if setHandle then setHandle(nil, handle) end
        handle:Cancel()
        if not ok then
            warn("[BSS SmoothFlight]", reached)
            return false
        end
        return reached == true
    end

    function SmoothFlight.Cancel()
        if active then active:Cancel() end
    end
end

-- Lock Facing is orientation-only. Farm locomotion remains controlled by Humanoid:Move.
local LockSettings = {
    Enabled = false,
    Types = {Flames = true, Bubble = true}, -- multi-selection
}

-- Flame Heat is OPTIONAL. It must never starve token collection.
-- Only field bounds apply to flame targets; no user-to-flame distance limit.
-- Stand briefly to approach the buff, then resume collecting tokens.
local FlameHeatSettings = {
    Enabled = false,
    StandSeconds = 0.5,          -- maximum time stopped at a flame
    GlobalCooldown = 7,        -- minimum token/patrol time between flame runs
}
-- Precise Bee Target Practice: touch 3 targets, hold last spot for the shot.
-- Only crosshairs inside the selected FlowerZone are eligible.
local PreciseSettings = {
    Enabled = false,
    SessionLimit = 10.0,       -- entire target sequence, including staggered spawns
    MaxShotWait = 5.0,        -- failsafe if shooting/cleanup event is not observable
    NextTargetGrace = 1.8,    -- give later marks time to appear
    ResumeWindow = 7.5,       -- preserve 1/3 or 2/3 across brief farm-loop restarts
    PointSeparation = 2.8,    -- clones around a touched mark count as the SAME point
    PointMemorySeconds = 6.0, -- don't retry the same location immediately
}
-- Progress must survive a brief gap between sequential Precise Bee marks.
local preciseProgress = nil
local recentPrecisePoints = {}

-- Digital Bee: hover tokens activate after standing under them for about one second.
-- The user-provided decal 5877939956 is the initial Smile marker; only FRONT
-- decal is inspected so a generic BackDecal does not mark everything as Smile.
local DigitalSettings = {
    Enabled = false,
    SmileTextureId = "5877939956",
    HoldSeconds = 1.25,
    TargetRetryDelay = 3.0,
}
local handledDuped = setmetatable({}, {__mode = "k"})
local trackedDupedFolder = nil
local lastDupedFolderCheck = -math.huge
local lastDupedScan = -math.huge
local cachedSmilePresence = false

local nextHeatVisitAt = 0
-- Mark every flame visited ONCE while its Instance is alive. Weak keys prevent leaks.
local visitedHeatFlames = setmetatable({}, {__mode = "k"})

local previous = playerGui:FindFirstChild("BSSHiveFieldUI")
if previous then previous:Destroy() end

local function ui(className, props, parent)
    local obj = Instance.new(className)
    for key, value in pairs(props) do obj[key] = value end
    obj.Parent = parent
    return obj
end

local white = Color3.fromRGB(246, 246, 246)
local black = Color3.fromRGB(0, 0, 0)

local screen = ui("ScreenGui", {
    Name = "BSSHiveFieldUI", ResetOnSpawn = false,
    ZIndexBehavior = Enum.ZIndexBehavior.Global, DisplayOrder = 100
}, playerGui)

local window = ui("Frame", {
    Name = "Window", AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.fromScale(0.5, 0.5),
    Size = UDim2.fromOffset(680, 380),
    BackgroundColor3 = black, BorderSizePixel = 0, Active = true
}, screen)

ui("UIStroke", {Color = Color3.fromRGB(125, 40, 255), Thickness = 2}, window)
ui("Frame", {
    Position = UDim2.fromOffset(108, 0), Size = UDim2.new(0, 1, 1, 0),
    BackgroundColor3 = Color3.fromRGB(225, 225, 225), BorderSizePixel = 0
}, window)

-- DRAG THE WINDOW BY ITS EMPTY BACKGROUND (MOUSE OR TOUCH).
local dragging = false
local dragStart = nil
local dragOrigin = nil
local dragInput = nil
local dragConnections = {}

local function beginDrag(input)
    if input.UserInputType ~= Enum.UserInputType.MouseButton1
        and input.UserInputType ~= Enum.UserInputType.Touch then
        return
    end
    dragging = true
    dragInput = input.UserInputType == Enum.UserInputType.Touch and input or nil
    dragStart = input.Position
    dragOrigin = window.Position
end
-- v8.5: dragging is bound to the new top-bar grip only; not the entire window.

table.insert(dragConnections, UserInputService.InputChanged:Connect(function(input)
    if not dragging or not dragStart or not dragOrigin then return end
    if input.UserInputType ~= Enum.UserInputType.MouseMovement and input ~= dragInput then
        return
    end
    local delta = input.Position - dragStart
    window.Position = UDim2.new(
        dragOrigin.X.Scale, dragOrigin.X.Offset + delta.X,
        dragOrigin.Y.Scale, dragOrigin.Y.Offset + delta.Y
    )
end))
table.insert(dragConnections, UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input == dragInput then
        dragging = false
        dragInput = nil
    end
end))

-- MINIMIZE; A SMALL SHOW BUTTON REMAINS ACCESSIBLE ON SCREEN.
local showMenu = ui("TextButton", {
    Name = "ShowMenu", Size = UDim2.fromOffset(83, 27),
    Position = UDim2.fromOffset(20, 90),
    BackgroundColor3 = black, TextColor3 = white,
    Text = "Show Menu", Font = Enum.Font.GothamBold, TextSize = 12,
    BorderSizePixel = 1, BorderColor3 = Color3.fromRGB(125, 40, 255),
    Visible = false, ZIndex = 100
}, screen)
local hideMenu = ui("TextButton", {
    Name = "HideMenu", Size = UDim2.fromOffset(22, 18),
    Position = UDim2.new(1, -25, 0, 4),
    Text = "−", Font = Enum.Font.GothamBold, TextSize = 17,
    TextColor3 = white, BackgroundColor3 = Color3.fromRGB(25, 25, 25),
    BorderSizePixel = 0, ZIndex = 80
}, window)
-- Dedicated drag strip (also works when the page covers the background).
local dragStrip = ui("TextLabel", {
    Name = "DragStrip", Position = UDim2.new(1, -153, 0, 2),
    Size = UDim2.fromOffset(119, 21), BackgroundTransparency = 1,
    Text = "≡", TextColor3 = Color3.fromRGB(170, 170, 170),
    Font = Enum.Font.GothamBold, TextSize = 17,
    Active = true, ZIndex = 78
}, window)
table.insert(dragConnections, dragStrip.InputBegan:Connect(beginDrag))

hideMenu.Activated:Connect(function()
    local p = window.AbsolutePosition
    local camera = workspace.CurrentCamera
    local viewport = camera and camera.ViewportSize or Vector2.new(1920, 1080)
    showMenu.Position = UDim2.fromOffset(
        math.clamp(math.floor(p.X), 0, math.max(0, viewport.X - 83)),
        math.clamp(math.floor(p.Y), 0, math.max(0, viewport.Y - 27))
    )
    window.Visible = false
    showMenu.Visible = true
end)
showMenu.Activated:Connect(function()
    showMenu.Visible = false
    window.Visible = true
end)

local pages = {}
local tabButtons = {}
local selectedTab = "Farm"
local tabNames = {"Main", "Farm", "Combat", "Toy", "Quest", "Upgrade", "Hive", "Plant", "Config"}

for i, name in ipairs(tabNames) do
    local b = ui("TextButton", {
        Name = name .. "Tab", Position = UDim2.fromOffset(8, 12 + (i - 1) * 30),
        Size = UDim2.fromOffset(92, 21), BackgroundColor3 = white,
        BorderSizePixel = 0, Text = name, TextColor3 = black,
        Font = Enum.Font.GothamBold, TextSize = 16,
        TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 2
    }, window)
    ui("UIPadding", {PaddingLeft = UDim.new(0, 3)}, b)
    tabButtons[name] = b
    pages[name] = ui("ScrollingFrame", {
        Name = name .. "Page", Position = UDim2.fromOffset(109, 0),
        Size = UDim2.new(1, -109, 1, 0), BackgroundTransparency = 1,
        BorderSizePixel = 0, ScrollBarThickness = 3,
        CanvasSize = UDim2.fromOffset(0, 381),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        ScrollingDirection = Enum.ScrollingDirection.Y,
        Visible = false, ZIndex = 2
    }, window)
end

local activeDot = ui("Frame", {
    Size = UDim2.fromOffset(7, 7), Position = UDim2.new(1, -5, 0, 7),
    BackgroundColor3 = Color3.fromRGB(0, 240, 125), BorderSizePixel = 0,
    ZIndex = 4
}, tabButtons.Farm)
ui("UICorner", {CornerRadius = UDim.new(1, 0)}, activeDot)

local function showTab(name)
    selectedTab = name
    for pageName, page in pairs(pages) do
        page.Visible = (pageName == name)
    end
    activeDot.Parent = tabButtons[name]
    activeDot.Visible = true
end
for name, b in pairs(tabButtons) do
    b.Activated:Connect(function() showTab(name) end)
end
showTab("Farm")

-- The inventory UI is isolated in a separate function: v6.8 had too many
-- locals in the top-level script and hit "exceeded limit 200" at runFarm.
do
    local function initializeInventory()
    -- MAIN PAGE: LIVE INVENTORY VIEWER (read-only)
    -- Dex hierarchy: Menus > Children > Eggs > Content > [EggRows] > EggRow
    -- Each EggRow exposes TypeName, Count, Description, and EggSlot/EggIcon.
    local inventoryPage = pages.Main
    local inventoryHeader = ui("TextLabel", {
        Name = "InventoryTitle", Position = UDim2.fromOffset(13, 12),
        Size = UDim2.new(1, -25, 0, 27), BackgroundTransparency = 1,
        Text = "INVENTORY", TextColor3 = white,
        TextXAlignment = Enum.TextXAlignment.Left,
        Font = Enum.Font.GothamBold, TextSize = 21, ZIndex = 5
    }, inventoryPage)

    local inventoryStatus = ui("TextLabel", {
        Name = "InventoryStatus", Position = UDim2.fromOffset(14, 39),
        Size = UDim2.new(1, -28, 0, 22), BackgroundTransparency = 1,
        Text = "Scanning game inventory...",
        TextColor3 = Color3.fromRGB(165, 165, 175),
        TextXAlignment = Enum.TextXAlignment.Left,
        Font = Enum.Font.Gotham, TextSize = 12, ZIndex = 5
    }, inventoryPage)

    local inventoryScroll = ui("ScrollingFrame", {
        Name = "InventoryList", Position = UDim2.fromOffset(10, 68),
        Size = UDim2.new(1, -22, 1, -80),
        BackgroundColor3 = Color3.fromRGB(12, 12, 18),
        BorderSizePixel = 0, ScrollBarThickness = 5,
        ScrollBarImageColor3 = Color3.fromRGB(145, 90, 255),
        ScrollingDirection = Enum.ScrollingDirection.Y,
        CanvasSize = UDim2.fromOffset(0, 0),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        ZIndex = 5
    }, inventoryPage)
    ui("UICorner", {CornerRadius = UDim.new(0, 6)}, inventoryScroll)
    ui("UIPadding", {
        PaddingTop = UDim.new(0, 7), PaddingBottom = UDim.new(0, 7),
        PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 6)
    }, inventoryScroll)
    ui("UIGridLayout", {
        Name = "ItemGrid", SortOrder = Enum.SortOrder.LayoutOrder,
        FillDirection = Enum.FillDirection.Horizontal,
        CellSize = UDim2.new(0.5, -7, 0, 79),
        CellPadding = UDim2.fromOffset(6, 6)
    }, inventoryScroll)

    local inventoryEmpty = ui("TextLabel", {
        Name = "InventoryEmpty", Position = UDim2.fromScale(0.5, 0.5),
        AnchorPoint = Vector2.new(0.5, 0.5),
        Size = UDim2.new(1, -45, 0, 62),
        BackgroundTransparency = 1,
        Text = "Inventory will open automatically when needed.",
        TextWrapped = true, Font = Enum.Font.Gotham,
        TextSize = 14, TextColor3 = Color3.fromRGB(185, 185, 195),
        ZIndex = 8
    }, inventoryPage)

    local cachedInventoryContent = nil
    local previousInventorySignature = nil
    local lastInventorySearch = -math.huge
    local inventorySearchEvery = 3

    local function findInventoryContent()
        -- Prefer the exact Dex path, not our own GUI or other unrelated EggRows.
        if cachedInventoryContent and cachedInventoryContent.Parent then
            return cachedInventoryContent
        end
        if os.clock() - lastInventorySearch < inventorySearchEvery then
            return nil
        end
        lastInventorySearch = os.clock()

        local bestContent, bestRows = nil, -1
        local roots = {playerGui}
        local okCore, coreGui = pcall(function()
            return game:GetService("CoreGui")
        end)
        if okCore and coreGui then
            table.insert(roots, coreGui)
        end

        for _, root in ipairs(roots) do
            local ok, descendants = pcall(function()
                return root:GetDescendants()
            end)
            if ok and descendants then
                for _, candidate in ipairs(descendants) do
                    if candidate.Name == "Content" then
                        local eggs = candidate.Parent
                        if eggs and eggs.Name == "Eggs"
                            and eggs:FindFirstAncestor("Menus") then
                            local count = 0
                            for _, item in ipairs(candidate:GetDescendants()) do
                                if item.Name == "EggRow" then
                                    count += 1
                                end
                            end
                            if count > bestRows then
                                bestRows = count
                                bestContent = candidate
                            end
                        end
                    end
                end
            end
        end

        cachedInventoryContent = bestContent
        return bestContent
    end

    local function inventoryText(row, childName)
        local child = row:FindFirstChild(childName, true)
        if child and (child:IsA("TextLabel")
            or child:IsA("TextButton") or child:IsA("TextBox")) then
            return child.Text
        end
        return ""
    end

    local function inventoryImage(row)
        local icon = row:FindFirstChild("EggIcon", true)
        if icon then
            if icon:IsA("ImageLabel") or icon:IsA("ImageButton") then
                if icon.Image ~= "" then return icon end
            end
            for _, desc in ipairs(icon:GetDescendants()) do
                if (desc:IsA("ImageLabel") or desc:IsA("ImageButton"))
                    and desc.Image ~= "" then
                    return desc
                end
            end
        end
        -- Alternate game UI layouts sometimes place the image directly in EggSlot.
        local slot = row:FindFirstChild("EggSlot", true)
        if slot then
            for _, desc in ipairs(slot:GetDescendants()) do
                if (desc:IsA("ImageLabel") or desc:IsA("ImageButton"))
                    and desc.Image ~= "" then
                    return desc
                end
            end
        end
        return nil
    end

    local function countValue(label)
        -- Examples: x2098, 489/500, x25/15. Empty means a non-stackable item.
        local s = tostring(label or ""):gsub(",", ""):gsub("%s", "")
        local first = s:match("^x?(%d+)")
        return first and tonumber(first) or nil
    end

    local function readInventory()
        local content = findInventoryContent()
        if not content then return nil end

        local byName = {}
        for _, row in ipairs(content:GetDescendants()) do
            if row.Name == "EggRow" then
                local name = inventoryText(row, "TypeName")
                local amount = inventoryText(row, "Count")
                local number = countValue(amount)
                if name ~= "" and not name:match("^%s*$")
                    and (number == nil or number > 0) then
                    local icon = inventoryImage(row)
                    local entry = {
                        name = name,
                        amount = amount,
                        quantity = number or -1,
                        description = inventoryText(row, "Description"),
                        image = icon and icon.Image or "",
                        rectOffset = icon and icon.ImageRectOffset or Vector2.zero,
                        rectSize = icon and icon.ImageRectSize or Vector2.zero,
                        resample = icon and icon.ResampleMode or Enum.ResamplerMode.Default,
                        scaleType = icon and icon.ScaleType or Enum.ScaleType.Stretch
                    }
                    local old = byName[name]
                    if not old or entry.quantity > old.quantity then
                        byName[name] = entry
                    end
                end
            end
        end
        local items = {}
        for _, item in pairs(byName) do
            table.insert(items, item)
        end
        table.sort(items, function(a, b)
            return a.name:lower() < b.name:lower()
        end)
        return items
    end

    local function createInventoryCard(item, order)
        local card = ui("Frame", {
            Name = "Item_" .. tostring(order), LayoutOrder = order,
            BackgroundColor3 = Color3.fromRGB(31, 31, 40),
            BorderSizePixel = 0, ZIndex = 6
        }, inventoryScroll)
        ui("UICorner", {CornerRadius = UDim.new(0, 6)}, card)
        ui("UIStroke", {
            Color = Color3.fromRGB(61, 59, 78), Thickness = 1
        }, card)

        local iconFrame = ui("Frame", {
            Position = UDim2.fromOffset(9, 15),
            Size = UDim2.fromOffset(48, 48),
            BackgroundColor3 = Color3.fromRGB(49, 49, 59),
            BorderSizePixel = 0, ZIndex = 7
        }, card)
        ui("UICorner", {CornerRadius = UDim.new(0, 6)}, iconFrame)
        if item.image ~= "" then
            ui("ImageLabel", {
                Name = "Icon", Position = UDim2.fromOffset(3, 3),
                Size = UDim2.new(1, -6, 1, -6),
                BackgroundTransparency = 1, Image = item.image,
                ImageRectOffset = item.rectOffset,
                ImageRectSize = item.rectSize,
                ResampleMode = item.resample,
                ScaleType = item.scaleType,
                ZIndex = 8
            }, iconFrame)
        end

        ui("TextLabel", {
            Name = "ItemName", Position = UDim2.fromOffset(65, 7),
            Size = UDim2.new(1, -72, 0, 23),
            BackgroundTransparency = 1, Text = item.name,
            Font = Enum.Font.GothamBold, TextSize = 13,
            TextColor3 = Color3.fromRGB(255, 255, 255),
            TextTruncate = Enum.TextTruncate.AtEnd,
            TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 8
        }, card)
        ui("TextLabel", {
            Name = "ItemCount", Position = UDim2.fromOffset(65, 30),
            Size = UDim2.new(1, -72, 0, 20),
            BackgroundTransparency = 1,
            Text = item.amount ~= "" and item.amount or "Owned",
            Font = Enum.Font.GothamBold, TextSize = 14,
            TextColor3 = Color3.fromRGB(134, 235, 166),
            TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 8
        }, card)
        ui("TextLabel", {
            Name = "ItemDescription", Position = UDim2.fromOffset(65, 52),
            Size = UDim2.new(1, -72, 0, 20),
            BackgroundTransparency = 1, Text = item.description,
            Font = Enum.Font.Gotham, TextSize = 10,
            TextColor3 = Color3.fromRGB(186, 186, 196),
            TextTruncate = Enum.TextTruncate.AtEnd,
            TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 8
        }, card)
    end

    local function refreshInventory()
        local items = readInventory()
        if not items then
            inventoryStatus.Text = "Waiting for Inventory GUI..."
            inventoryEmpty.Visible = true
            previousInventorySignature = nil
            return
        end

        local signatureParts = {}
        for _, item in ipairs(items) do
            table.insert(signatureParts,
                item.name .. "\0" .. item.amount .. "\0" .. item.description .. "\0" .. item.image)
        end
        local signature = table.concat(signatureParts, "\1")
        if signature == previousInventorySignature then return items end
        previousInventorySignature = signature

        -- Rebuild only when an item/count changes, preserving scroll position.
        local scrollY = inventoryScroll.CanvasPosition.Y
        for _, child in ipairs(inventoryScroll:GetChildren()) do
            if child:IsA("Frame") and child.Name:match("^Item_%d+$") then
                child:Destroy()
            end
        end
        for i, item in ipairs(items) do
            createInventoryCard(item, i)
        end
        inventoryScroll.CanvasPosition = Vector2.new(0, scrollY)
        inventoryStatus.Text = string.format("%d item types  |  Updates automatically", #items)
        inventoryEmpty.Visible = (#items == 0)
        if #items == 0 then
            inventoryEmpty.Text = "No items loaded yet. Trying Eggs Tab automatically..."
        end
        return items
    end

    -- Activate the game's Eggs Tab automatically. EggRow elements in Bee Swarm
    -- are lazily populated on opening that tab, so simply searching PlayerGui is
    -- not enough until its original UI code has run.
    -- This uses the same screen-coordinate click that was verified in Dex.
    local autoEggsAttempts = 0
    local autoEggsMaxAttempts = 4
    local autoEggsNextTryAt = 0
    local autoEggsWorking = false

    local function findGameEggsTab()
        local menus = playerGui:FindFirstChild("Menus", true)
        if not menus then return nil, "Menus not found" end
        local tabs = menus:FindFirstChild("ChildTabs", true)
        if not tabs then return nil, "ChildTabs not found" end
        local target = tabs:FindFirstChild("Eggs Tab", true)
        if not target or not target:IsA("GuiObject") then
            return nil, "Eggs Tab not found"
        end
        return target
    end

    local function guiCanReceiveClick(target)
        local cursor = target
        while cursor do
            if cursor:IsA("GuiObject") and not cursor.Visible then return false end
            if cursor:IsA("ScreenGui") and not cursor.Enabled then return false end
            cursor = cursor.Parent
        end
        return target.AbsoluteSize.X > 0 and target.AbsoluteSize.Y > 0
    end

    local function openGameEggsTab()
        local target, reason = findGameEggsTab()
        if not target then return false, reason end

        -- If native GUI is invisible, Roblox cannot hit-test it with the mouse.
        -- Try the standard GuiButton activation if applicable, without guessing
        -- other button coordinates or clicking unrelated parts of the screen.
        if not guiCanReceiveClick(target) then
            if target:IsA("GuiButton") then
                local ok = pcall(function() target:Activate() end)
                if ok then return true end
            end
            return false, "Eggs Tab exists but is hidden by the game"
        end

        local pos = target.AbsolutePosition + target.AbsoluteSize / 2
        local nativeScreen = target:FindFirstAncestorOfClass("ScreenGui")
        if nativeScreen and nativeScreen.ScreenInsets == Enum.ScreenInsets.CoreUISafeInsets then
            local inset = GuiService:GetGuiInset()
            pos += inset
        end
        local x, y = math.floor(pos.X), math.floor(pos.Y)

        -- Move our own overlay away temporarily so it cannot intercept the click.
        local originalVisibility = window.Visible
        if originalVisibility then window.Visible = false end
        task.wait()

        local ok, err = pcall(function()
            VIM:SendMouseMoveEvent(x, y, game)
            task.wait(0.15)
            VIM:SendMouseButtonEvent(x, y, 0, true, game, 0)
            task.wait(0.10)
            VIM:SendMouseButtonEvent(x, y, 0, false, game, 0)
        end)
        if originalVisibility and window.Parent then
            window.Visible = true
        end
        return ok, err and tostring(err) or nil
    end

    -- Retry a limited number of times only when Main is selected and Inventory
    -- actually has no rows. Once data exists, count/icon updates remain passive.
    task.spawn(function()
        local wasMain = false
        while screen.Parent do
            local isMain = selectedTab == "Main"
            if isMain then
                if not wasMain then
                    autoEggsAttempts = 0
                    autoEggsNextTryAt = 0
                end
                local ok, items = pcall(refreshInventory)
                if not ok then
                    inventoryStatus.Text = "Inventory scan error (see console)"
                    warn("[BSS Inventory]", items)
                elseif items and #items > 0 then
                    -- Inventory has rendered; no clicking is needed any more.
                    autoEggsAttempts = autoEggsMaxAttempts
                elseif not autoEggsWorking
                    and autoEggsAttempts < autoEggsMaxAttempts
                    and os.clock() >= autoEggsNextTryAt then

                    autoEggsWorking = true
                    autoEggsAttempts += 1
                    autoEggsNextTryAt = os.clock() + 5
                    inventoryStatus.Text = "Auto-opening Eggs Tab (" .. autoEggsAttempts .. "/" .. autoEggsMaxAttempts .. ")..."

                    local opened, message = openGameEggsTab()
                    if opened then
                        task.wait(0.8) -- Wait for the game's lazy EggRows to be created.
                        local readOK, refreshed = pcall(refreshInventory)
                        if not readOK then
                            warn("[BSS Inventory]", refreshed)
                        elseif refreshed and #refreshed > 0 then
                            autoEggsAttempts = autoEggsMaxAttempts
                        end
                    else
                        warn("[BSS Inventory Auto-Open]", message)
                        inventoryStatus.Text = "Auto-open failed: " .. tostring(message)
                    end
                    autoEggsWorking = false
                elseif autoEggsAttempts >= autoEggsMaxAttempts then
                    inventoryStatus.Text = "No inventory data. Select Main again to retry."
                end
            end
            wasMain = isMain
            task.wait(1.5)
        end
    end)
    end
    initializeInventory()
end

-- FARM PAGE: FIELD DROPDOWN
local farmPage = pages.Farm
local fieldButton = ui("TextButton", {
    Position = UDim2.fromOffset(8, 12), Size = UDim2.fromOffset(140, 22),
    BackgroundColor3 = Color3.fromRGB(190, 199, 208), BorderSizePixel = 0,
    Text = "🌼 Field", TextColor3 = black, Font = Enum.Font.GothamBold,
    TextSize = 16, TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 5
}, farmPage)
ui("UIPadding", {PaddingLeft = UDim.new(0, 7), PaddingRight = UDim.new(0, 22)}, fieldButton)
local arrow = ui("TextLabel", {
    AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -5, 0.5, 0),
    Size = UDim2.fromOffset(15, 18), BackgroundTransparency = 1,
    Text = "▼", TextColor3 = black, Font = Enum.Font.GothamBold,
    TextSize = 16, ZIndex = 6
}, fieldButton)
local dropdown = ui("ScrollingFrame", {
    Name = "FieldList", Position = UDim2.fromOffset(8, 37),
    Size = UDim2.fromOffset(195, 190), BackgroundColor3 = white,
    BorderSizePixel = 0, CanvasSize = UDim2.fromOffset(0, 0),
    AutomaticCanvasSize = Enum.AutomaticSize.Y,
    ScrollBarThickness = 5, Visible = false, ZIndex = 30
}, farmPage)
ui("UIPadding", {
    PaddingTop = UDim.new(0, 3), PaddingBottom = UDim.new(0, 3),
    PaddingLeft = UDim.new(0, 3), PaddingRight = UDim.new(0, 6)
}, dropdown)
ui("UIListLayout", {Padding = UDim.new(0, 3), SortOrder = Enum.SortOrder.LayoutOrder}, dropdown)

local function fieldIconName(name)
    local v = tostring(name or ""):lower()
    if v:find("sunflower", 1, true) then return "🌻"
    elseif v:find("dandelion", 1, true) then return "🌼"
    elseif v:find("mushroom", 1, true) then return "🍄"
    elseif v:find("blue flower", 1, true) then return "🔵"
    elseif v:find("clover", 1, true) then return "🍀"
    elseif v:find("spider", 1, true) then return "🕷️"
    elseif v:find("bamboo", 1, true) then return "🎋"
    elseif v:find("strawberry", 1, true) then return "🍓"
    elseif v:find("pine tree", 1, true) then return "🌲"
    elseif v:find("pumpkin", 1, true) then return "🎃"
    elseif v:find("cactus", 1, true) then return "🌵"
    elseif v:find("rose", 1, true) then return "🌹"
    elseif v:find("pineapple", 1, true) then return "🍍"
    elseif v:find("mountain", 1, true) then return "⛰️"
    elseif v:find("pepper", 1, true) then return "🌶️"
    elseif v:find("coconut", 1, true) then return "🥥"
    elseif v:find("stump", 1, true) then return "🪵"
    end
    return "🌼"
end

local fieldObjects = {}
for _, item in ipairs(FlowerZones:GetChildren()) do
    if item:IsA("BasePart") or item:IsA("Model") then
        table.insert(fieldObjects, item)
    end
end
table.sort(fieldObjects, function(a, b) return a.Name:lower() < b.Name:lower() end)

local function getHumanoidAndRoot()
    local char = player.Character or player.CharacterAdded:Wait()
    return char:WaitForChild("Humanoid"), char:WaitForChild("HumanoidRootPart")
end
-- Independent movement controller: not tied to MoveToFinished.
local walkBindingName = "BSSFieldWalk_" .. tostring(player.UserId)
local walkBound = false
local walkingHumanoid = nil
local originalWalkSpeed = nil
local walkDestination = nil

local function stopWalking()
    walkDestination = nil
    if walkBound then
        RunService:UnbindFromRenderStep(walkBindingName)
        walkBound = false
    end
    if walkingHumanoid and walkingHumanoid.Parent then
        walkingHumanoid:Move(Vector3.zero, false)
        if originalWalkSpeed then
            walkingHumanoid.WalkSpeed = originalWalkSpeed
        end
    end
    walkingHumanoid = nil
    originalWalkSpeed = nil
end

for i, field in ipairs(fieldObjects) do
    local row = ui("TextButton", {
        Size = UDim2.new(1, 0, 0, 26), BackgroundColor3 = Color3.fromRGB(240, 240, 240),
        BorderSizePixel = 0, Text = "", TextColor3 = black,
        Font = Enum.Font.Gotham, TextSize = 13,
        TextXAlignment = Enum.TextXAlignment.Left, LayoutOrder = i, ZIndex = 31
    }, dropdown)
    ui("TextLabel", {
        Position = UDim2.fromOffset(5, 2), Size = UDim2.fromOffset(21, 21),
        BackgroundTransparency = 1, Text = fieldIconName(field.Name),
        TextColor3 = black, Font = Enum.Font.SourceSansBold, TextSize = 18,
        ZIndex = 32
    }, row)
    ui("TextLabel", {
        Position = UDim2.fromOffset(28, 0), Size = UDim2.new(1, -32, 1, 0),
        BackgroundTransparency = 1, Text = field.Name, TextColor3 = black,
        Font = Enum.Font.Gotham, TextSize = 13,
        TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 32
    }, row)
    row.Activated:Connect(function()
        -- A manual field change also cancels an in-progress planter visit.
        if CombatSignals.CancelPlanter then CombatSignals.CancelPlanter() end
        -- Changing a field while farming claims movement for the player.
        if farmEnabled and CombatSignals.FieldSelected then
            CombatSignals.FieldSelected()
        end
        selectedField = field.Name
        fieldButton.Text = fieldIconName(field.Name) .. " " .. field.Name
        dropdown.Visible = false
        arrow.Text = "▼"
        if currentFarmTravelTween then
            currentFarmTravelTween:Cancel()
        end
        stopWalking() -- interrupt old target when field changes
    end)
end
fieldButton.Activated:Connect(function()
    dropdown.Visible = not dropdown.Visible
    arrow.Text = dropdown.Visible and "▲" or "▼"
end)

-- FARM PAGE: ROUND TOGGLES
local function circleToggle(x, label)
    local hit = ui("TextButton", {
        Position = UDim2.fromOffset(x, 12), Size = UDim2.fromOffset(107, 23),
        BackgroundTransparency = 1, BorderSizePixel = 0, Text = "", ZIndex = 7
    }, farmPage)
    local outer = ui("Frame", {
        Position = UDim2.fromOffset(0, 2), Size = UDim2.fromOffset(17, 17),
        BackgroundColor3 = Color3.fromRGB(211, 219, 226), BorderSizePixel = 0,
        ZIndex = 8
    }, hit)
    ui("UICorner", {CornerRadius = UDim.new(1, 0)}, outer)
    local dot = ui("Frame", {
        AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
        Size = UDim2.fromOffset(9, 9), BackgroundColor3 = Color3.fromRGB(0, 225, 110),
        BorderSizePixel = 0, Visible = false, ZIndex = 9
    }, outer)
    ui("UICorner", {CornerRadius = UDim.new(1, 0)}, dot)
    ui("TextLabel", {
        Position = UDim2.fromOffset(21, 0), Size = UDim2.fromOffset(85, 22),
        BackgroundTransparency = 1, Text = label, TextColor3 = white,
        TextXAlignment = Enum.TextXAlignment.Left, Font = Enum.Font.GothamBold,
        TextSize = (label == "Sprinkler") and 14 or 17, ZIndex = 8
    }, hit)
    return hit, function(state) dot.Visible = state end
end

local farmHit, paintFarm = circleToggle(164, "Farm")
local clickHit, paintClick = circleToggle(271, "click")
-- Third compact Quick Farm toggle. Scoped so this does not consume extra
-- top-level Luau local registers.
do
    local sprinklerHit, paintSprinkler = circleToggle(381, "Sprinkler")
    CombatSignals.PaintSprinkler = paintSprinkler
    sprinklerHit.Activated:Connect(function()
        local setting = CombatSignals.Sprinkler
        setting.Enabled = not setting.Enabled
        setting.LastField = nil
        setting.RetryAt = 0
        paintSprinkler(setting.Enabled)
    end)
end

-- FARM PAGE: SECTION DIVIDERS + FLAMES/BUBBLE MULTI-SELECT LOCK.
local separatorColor = Color3.fromRGB(109, 109, 109)
local function farmSeparator(y)
    return ui("Frame", {
        Name = "SectionSeparator", Position = UDim2.fromOffset(8, y),
        Size = UDim2.new(1, -20, 0, 1),
        BackgroundColor3 = separatorColor, BorderSizePixel = 0, ZIndex = 3
    }, farmPage)
end
local function farmLabel(y, label, fontSize)
    return ui("TextLabel", {
        Position = UDim2.fromOffset(9, y), Size = UDim2.new(1, -18, 0, 23),
        BackgroundTransparency = 1, Text = label, TextColor3 = white,
        TextXAlignment = Enum.TextXAlignment.Left,
        Font = Enum.Font.GothamBold, TextSize = fontSize or 14, ZIndex = 5
    }, farmPage)
end

farmSeparator(48)
farmLabel(56, "LOCK FACING", 15)
local facingToggle = ui("TextButton", {
    Name = "LockFacingToggle", Position = UDim2.fromOffset(9, 82),
    Size = UDim2.fromOffset(173, 25), BackgroundTransparency = 1,
    Text = "", BorderSizePixel = 0, ZIndex = 7
}, farmPage)
local facingCircle = ui("Frame", {
    Position = UDim2.fromOffset(0, 4), Size = UDim2.fromOffset(16, 16),
    BackgroundColor3 = Color3.fromRGB(211, 219, 226), BorderSizePixel = 0,
    ZIndex = 8
}, facingToggle)
ui("UICorner", {CornerRadius = UDim.new(1, 0)}, facingCircle)
local facingDot = ui("Frame", {
    AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
    Size = UDim2.fromOffset(9, 9), BackgroundColor3 = Color3.fromRGB(0, 225, 110),
    BorderSizePixel = 0, Visible = LockSettings.Enabled, ZIndex = 9
}, facingCircle)
ui("UICorner", {CornerRadius = UDim.new(1, 0)}, facingDot)
ui("TextLabel", {
    Position = UDim2.fromOffset(24, 1), Size = UDim2.fromOffset(146, 23),
    BackgroundTransparency = 1, Text = "Lock Direction",
    TextColor3 = white, TextXAlignment = Enum.TextXAlignment.Left,
    Font = Enum.Font.GothamBold, TextSize = 14, ZIndex = 8
}, facingToggle)
facingToggle.Activated:Connect(function()
    LockSettings.Enabled = not LockSettings.Enabled
    facingDot.Visible = LockSettings.Enabled
end)

farmSeparator(114)
farmLabel(121, "Lock targets  (multi-select)", 14)

local lockListButton = ui("TextButton", {
    Name = "LockTargetListbox", Position = UDim2.fromOffset(9, 151),
    Size = UDim2.fromOffset(226, 25), BackgroundColor3 = Color3.fromRGB(190, 199, 208),
    BorderSizePixel = 0, Text = "", TextColor3 = black,
    TextXAlignment = Enum.TextXAlignment.Left,
    Font = Enum.Font.GothamBold, TextSize = 13, ZIndex = 25
}, farmPage)
ui("UIPadding", {PaddingLeft = UDim.new(0, 8)}, lockListButton)
local lockOptions = ui("Frame", {
    Name = "LockTargetOptions", Position = UDim2.fromOffset(9, 178),
    Size = UDim2.fromOffset(226, 56), BackgroundColor3 = white,
    BorderSizePixel = 0, Visible = false, ZIndex = 40
}, farmPage)
local lockListLayout = ui("UIListLayout", {
    FillDirection = Enum.FillDirection.Vertical,
    SortOrder = Enum.SortOrder.LayoutOrder,
    Padding = UDim.new(0, 2)
}, lockOptions)
local lockOptionButtons = {}
local function updateLockList()
    local selected = {}
    for _, name in ipairs({"Flames", "Bubble"}) do
        local checked = LockSettings.Types[name]
        if checked then table.insert(selected, name) end
        if lockOptionButtons[name] then
            lockOptionButtons[name].Text = (checked and "[x]  " or "[ ]  ") .. name
            lockOptionButtons[name].BackgroundColor3 = checked
                and Color3.fromRGB(205, 245, 217) or Color3.fromRGB(240, 240, 240)
        end
    end
    local description = (#selected > 0) and table.concat(selected, " + ") or "None"
    lockListButton.Text = "Targets: " .. description .. "   ▼"
end
for i, name in ipairs({"Flames", "Bubble"}) do
    local option = ui("TextButton", {
        Name = name .. "Option", Size = UDim2.new(1, 0, 0, 27),
        LayoutOrder = i, BackgroundColor3 = white, BorderSizePixel = 0,
        TextColor3 = black, TextXAlignment = Enum.TextXAlignment.Left,
        Font = Enum.Font.GothamBold, TextSize = 13, ZIndex = 41
    }, lockOptions)
    ui("UIPadding", {PaddingLeft = UDim.new(0, 8)}, option)
    lockOptionButtons[name] = option
    option.Activated:Connect(function()
        LockSettings.Types[name] = not LockSettings.Types[name]
        updateLockList()
        -- Do not close the list; selecting both items is intentional.
    end)
end
updateLockList()
lockListButton.Activated:Connect(function()
    lockOptions.Visible = not lockOptions.Visible
    if lockOptions.Visible then dropdown.Visible = false; arrow.Text = "▼" end
end)
fieldButton.Activated:Connect(function()
    lockOptions.Visible = false
end)

farmSeparator(245)
farmLabel(251, "FLAME HEAT", 15)
local flameHeatToggle = ui("TextButton", {
    Name = "AutoFlameHeatToggle", Position = UDim2.fromOffset(9, 277),
    Size = UDim2.fromOffset(230, 25), BackgroundTransparency = 1,
    Text = "", BorderSizePixel = 0, ZIndex = 7
}, farmPage)
local heatCircle = ui("Frame", {
    Position = UDim2.fromOffset(0, 4), Size = UDim2.fromOffset(16, 16),
    BackgroundColor3 = Color3.fromRGB(211, 219, 226), BorderSizePixel = 0,
    ZIndex = 8
}, flameHeatToggle)
ui("UICorner", {CornerRadius = UDim.new(1, 0)}, heatCircle)
local heatDot = ui("Frame", {
    AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
    Size = UDim2.fromOffset(9, 9), BackgroundColor3 = Color3.fromRGB(0, 225, 110),
    BorderSizePixel = 0, Visible = FlameHeatSettings.Enabled, ZIndex = 9
}, heatCircle)
ui("UICorner", {CornerRadius = UDim.new(1, 0)}, heatDot)
ui("TextLabel", {
    Position = UDim2.fromOffset(24, 1), Size = UDim2.fromOffset(204, 23),
    BackgroundTransparency = 1, Text = "Auto Flame Heat",
    TextColor3 = white, TextXAlignment = Enum.TextXAlignment.Left,
    Font = Enum.Font.GothamBold, TextSize = 14, ZIndex = 8
}, flameHeatToggle)
local heatStatus = farmLabel(305, "Heat: off", 12)
heatStatus.TextColor3 = Color3.fromRGB(180, 180, 180)
flameHeatToggle.Activated:Connect(function()
    FlameHeatSettings.Enabled = not FlameHeatSettings.Enabled
    heatDot.Visible = FlameHeatSettings.Enabled
    heatStatus.Text = FlameHeatSettings.Enabled
        and (farmEnabled and "Heat: waiting for flame" or "Heat: waiting for farm") or "Heat: off"
end)
farmSeparator(331)
local lockStatus = farmLabel(339, "Facing: idle", 12)
lockStatus.TextColor3 = Color3.fromRGB(180, 180, 180)

-- Independent section to the RIGHT of Flame Heat. No settings are added to Config.
ui("Frame", {
    Name = "PreciseVerticalSeparator", Position = UDim2.fromOffset(285, 53),
    Size = UDim2.fromOffset(1, 279), BackgroundColor3 = separatorColor,
    BorderSizePixel = 0, ZIndex = 3
}, farmPage)
ui("TextLabel", {
    Position = UDim2.fromOffset(303, 57), Size = UDim2.fromOffset(250, 24),
    Text = "PRECISE BEE", BackgroundTransparency = 1,
    TextXAlignment = Enum.TextXAlignment.Left,
    Font = Enum.Font.GothamBold, TextSize = 15, TextColor3 = white, ZIndex = 5
}, farmPage)
local preciseHit = ui("TextButton", {
    Name = "AutoPreciseCrosshairToggle", Position = UDim2.fromOffset(303, 90),
    Size = UDim2.fromOffset(248, 28), BackgroundTransparency = 1,
    Text = "", BorderSizePixel = 0, ZIndex = 7
}, farmPage)
local preciseCircle = ui("Frame", {
    Position = UDim2.fromOffset(0, 4), Size = UDim2.fromOffset(16, 16),
    BackgroundColor3 = Color3.fromRGB(211, 219, 226),
    BorderSizePixel = 0, ZIndex = 8
}, preciseHit)
ui("UICorner", {CornerRadius = UDim.new(1, 0)}, preciseCircle)
local preciseDot = ui("Frame", {
    AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
    Size = UDim2.fromOffset(9, 9), BackgroundColor3 = Color3.fromRGB(0, 225, 110),
    BorderSizePixel = 0, Visible = PreciseSettings.Enabled, ZIndex = 9
}, preciseCircle)
ui("UICorner", {CornerRadius = UDim.new(1, 0)}, preciseDot)
ui("TextLabel", {
    Position = UDim2.fromOffset(24, 0), Size = UDim2.fromOffset(220, 26),
    Text = "Auto Crosshair", BackgroundTransparency = 1,
    TextXAlignment = Enum.TextXAlignment.Left, Font = Enum.Font.GothamBold,
    TextSize = 14, TextColor3 = white, ZIndex = 8
}, preciseHit)
local preciseStatus = ui("TextLabel", {
    Name = "PreciseStatus", Position = UDim2.fromOffset(303, 128),
    Size = UDim2.fromOffset(248, 23), BackgroundTransparency = 1,
    Text = "Precise: off", TextXAlignment = Enum.TextXAlignment.Left,
    Font = Enum.Font.Gotham, TextSize = 12,
    TextColor3 = Color3.fromRGB(185, 185, 185), ZIndex = 5
}, farmPage)
ui("TextLabel", {
    Position = UDim2.fromOffset(303, 159), Size = UDim2.fromOffset(244, 58),
    Text = "Touch 3 targets in the field;\nhold on the last until the shot.",
    BackgroundTransparency = 1, TextWrapped = true,
    TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
    Font = Enum.Font.Gotham, TextSize = 12,
    TextColor3 = Color3.fromRGB(180, 180, 180), ZIndex = 5
}, farmPage)
preciseHit.Activated:Connect(function()
    PreciseSettings.Enabled = not PreciseSettings.Enabled
    if not PreciseSettings.Enabled then preciseProgress = nil end
    preciseDot.Visible = PreciseSettings.Enabled
    preciseStatus.Text = PreciseSettings.Enabled and
        (farmEnabled and "Precise: searching" or "Precise: waiting for Farm")
        or "Precise: off"
end)

-- DIGITAL BEE: right-column section, separated from Precise Bee.
ui("Frame", {
    Name = "DigitalHorizontalSeparator", Position = UDim2.fromOffset(303, 228),
    Size = UDim2.fromOffset(247, 1), BackgroundColor3 = separatorColor,
    BorderSizePixel = 0, ZIndex = 3
}, farmPage)
ui("TextLabel", {
    Position = UDim2.fromOffset(303, 235), Size = UDim2.fromOffset(247, 23),
    Text = "DIGITAL BEE", BackgroundTransparency = 1,
    TextXAlignment = Enum.TextXAlignment.Left,
    Font = Enum.Font.GothamBold, TextSize = 15, TextColor3 = white, ZIndex = 5
}, farmPage)
local digitalHit = ui("TextButton", {
    Name = "AutoDupedTokensToggle", Position = UDim2.fromOffset(303, 264),
    Size = UDim2.fromOffset(250, 27), BackgroundTransparency = 1,
    Text = "", BorderSizePixel = 0, ZIndex = 7
}, farmPage)
local digitalCircle = ui("Frame", {
    Position = UDim2.fromOffset(0, 4), Size = UDim2.fromOffset(16, 16),
    BackgroundColor3 = Color3.fromRGB(211, 219, 226), BorderSizePixel = 0, ZIndex = 8
}, digitalHit)
ui("UICorner", {CornerRadius = UDim.new(1, 0)}, digitalCircle)
local digitalDot = ui("Frame", {
    AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
    Size = UDim2.fromOffset(9, 9), BackgroundColor3 = Color3.fromRGB(0, 225, 110),
    BorderSizePixel = 0, Visible = DigitalSettings.Enabled, ZIndex = 9
}, digitalCircle)
ui("UICorner", {CornerRadius = UDim.new(1, 0)}, digitalDot)
ui("TextLabel", {
    Position = UDim2.fromOffset(24, 0), Size = UDim2.fromOffset(219, 25),
    Text = "Auto Duped Tokens", BackgroundTransparency = 1,
    TextXAlignment = Enum.TextXAlignment.Left, Font = Enum.Font.GothamBold,
    TextSize = 14, TextColor3 = white, ZIndex = 8
}, digitalHit)
local digitalStatus = ui("TextLabel", {
    Name = "DigitalStatus", Position = UDim2.fromOffset(303, 300),
    Size = UDim2.fromOffset(250, 22), BackgroundTransparency = 1,
    Text = "Digital: off", TextXAlignment = Enum.TextXAlignment.Left,
    Font = Enum.Font.Gotham, TextSize = 12,
    TextColor3 = Color3.fromRGB(185, 185, 185), ZIndex = 5
}, farmPage)
ui("TextLabel", {
    Position = UDim2.fromOffset(303, 324), Size = UDim2.fromOffset(248, 45),
    BackgroundTransparency = 1, Text = "Smile first; stand beneath duped tokens\nfor ~1s, then resume collecting.",
    TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left,
    TextYAlignment = Enum.TextYAlignment.Top, Font = Enum.Font.Gotham,
    TextSize = 12, TextColor3 = Color3.fromRGB(180, 180, 180), ZIndex = 5
}, farmPage)
digitalHit.Activated:Connect(function()
    DigitalSettings.Enabled = not DigitalSettings.Enabled
    digitalDot.Visible = DigitalSettings.Enabled
    digitalStatus.Text = DigitalSettings.Enabled
        and (farmEnabled and "Digital: scanning" or "Digital: waiting for Farm")
        or "Digital: off"
end)

-- CONFIG PAGE: TWEEN SPEED FOR HIVE AND FIELD TRAVEL
ui("TextLabel", {
    Position = UDim2.fromOffset(12, 14), Size = UDim2.fromOffset(140, 24),
    BackgroundTransparency = 1, Text = "Fly Speed", TextColor3 = white,
    TextXAlignment = Enum.TextXAlignment.Left, Font = Enum.Font.GothamBold,
    TextSize = 15
}, pages.Config)
local speedBox = ui("TextBox", {
    Position = UDim2.fromOffset(158, 14), Size = UDim2.fromOffset(95, 24),
    BackgroundColor3 = white, TextColor3 = black,
    Text = tostring(TweenSpeed), ClearTextOnFocus = false,
    Font = Enum.Font.GothamBold, TextSize = 15
}, pages.Config)
speedBox.FocusLost:Connect(function()
    local n = tonumber(speedBox.Text)
    if n and n > 0 and n < math.huge then TweenSpeed = n end
    speedBox.Text = tostring(TweenSpeed)
end)

-- CONFIG: WALK SPEED DURING FARM (not the fly/tween speed)
ui("TextLabel", {
    Position = UDim2.fromOffset(12, 50), Size = UDim2.fromOffset(140, 24),
    BackgroundTransparency = 1, Text = "Walk Speed", TextColor3 = white,
    TextXAlignment = Enum.TextXAlignment.Left, Font = Enum.Font.GothamBold,
    TextSize = 15
}, pages.Config)
local walkSpeedBox = ui("TextBox", {
    Position = UDim2.fromOffset(158, 50), Size = UDim2.fromOffset(95, 24),
    BackgroundColor3 = white, TextColor3 = black,
    Text = tostring(WalkSpeed), ClearTextOnFocus = false,
    Font = Enum.Font.GothamBold, TextSize = 15
}, pages.Config)
walkSpeedBox.FocusLost:Connect(function()
    local n = tonumber(walkSpeedBox.Text)
    if n and n > 0 and n < math.huge then
        WalkSpeed = n
        if walkingHumanoid and walkingHumanoid.Parent then
            walkingHumanoid.WalkSpeed = WalkSpeed
        end
    end
    walkSpeedBox.Text = tostring(WalkSpeed)
end)

ConfigManager.Register("Farm", function()
    return {
        FlySpeed = TweenSpeed, WalkSpeed = WalkSpeed, Field = selectedField,
        Facing = LockSettings.Enabled,
        FacingTypes = {Flames = LockSettings.Types.Flames, Bubble = LockSettings.Types.Bubble},
        FlameHeat = FlameHeatSettings.Enabled,
        PreciseBee = PreciseSettings.Enabled,
        DigitalBee = DigitalSettings.Enabled,
        Sprinkler = CombatSignals.Sprinkler.Enabled,
    }
end, function(data)
    local fly, walk = tonumber(data.FlySpeed), tonumber(data.WalkSpeed)
    if fly and fly >= 5 and fly <= 250 then TweenSpeed = fly end
    -- Migrate the previous default of 16 to the new trial speed (90).
    -- Preserve non-default custom walk speeds.
    if walk and walk >= 5 and walk <= 120 then WalkSpeed = (walk == 16) and 90 or walk end
    speedBox.Text = tostring(TweenSpeed)
    walkSpeedBox.Text = tostring(WalkSpeed)
    if walkingHumanoid and walkingHumanoid.Parent then walkingHumanoid.WalkSpeed = WalkSpeed end
    if type(data.Field) == "string" and FlowerZones:FindFirstChild(data.Field) then
        selectedField = data.Field
        fieldButton.Text = fieldIconName(selectedField) .. " " .. selectedField
    end
    if type(data.Facing) == "boolean" then LockSettings.Enabled = data.Facing end
    if type(data.FacingTypes) == "table" then
        for _, kind in ipairs({"Flames", "Bubble"}) do
            if type(data.FacingTypes[kind]) == "boolean" then
                LockSettings.Types[kind] = data.FacingTypes[kind]
            end
        end
    end
    if type(data.FlameHeat) == "boolean" then FlameHeatSettings.Enabled = data.FlameHeat end
    if type(data.PreciseBee) == "boolean" then PreciseSettings.Enabled = data.PreciseBee end
    if type(data.DigitalBee) == "boolean" then DigitalSettings.Enabled = data.DigitalBee end
    if type(data.Sprinkler) == "boolean" then
        CombatSignals.Sprinkler.Enabled = data.Sprinkler
        CombatSignals.Sprinkler.LastField = nil
        CombatSignals.Sprinkler.RetryAt = 0
    end
    if CombatSignals.PaintSprinkler then
        CombatSignals.PaintSprinkler(CombatSignals.Sprinkler.Enabled)
    end
    facingDot.Visible = LockSettings.Enabled
    heatDot.Visible = FlameHeatSettings.Enabled
    preciseDot.Visible = PreciseSettings.Enabled
    digitalDot.Visible = DigitalSettings.Enabled
    updateLockList()
    heatStatus.Text = FlameHeatSettings.Enabled and "Heat: waiting for Farm" or "Heat: off"
    preciseStatus.Text = PreciseSettings.Enabled and "Precise: waiting for Farm" or "Precise: off"
    digitalStatus.Text = DigitalSettings.Enabled and "Digital: waiting for Farm" or "Digital: off"
end)

-- HIVE: AUTOMATICALLY FIND/CLAIM ON EXECUTION
local function hivePlatforms()
    local results = {}
    for _, m in ipairs(HivePlatforms:GetChildren()) do
        if m.Name == "Platform" and m:IsA("Model") then table.insert(results, m) end
    end
    return results
end
local function isMine(ref)
    if not (ref and ref:IsA("ObjectValue")) then return false end
    local value = ref.Value
    return value ~= nil and (value == player or value == player.Character or value.Name == player.Name)
end
local function ownsHive(platforms)
    for _, m in ipairs(platforms) do
        if isMine(m:FindFirstChild("PlayerRef")) then return true end
    end
    return false
end
local function hivePosition(m)
    local inner = m:FindFirstChild("Platform")
    local target = (inner and (inner:IsA("Model") or inner:IsA("BasePart"))) and inner or m
    return target:GetPivot().Position + Vector3.new(0, HiveHeightOffset, 0)
end
local function tweenToHive(position)
    if not screen.Parent then return false end
    local _, root = getHumanoidAndRoot()
    return SmoothFlight.Path(root, {position}, function()
        return screen.Parent ~= nil and not farmEnabled
    end, TweenSpeed, function(handle, previous)
        if previous then
            if currentHiveTween == previous then currentHiveTween = nil end
        else
            currentHiveTween = handle
        end
    end)
end
local function pressE()
    VIM:SendKeyEvent(true, Enum.KeyCode.E, false, game)
    task.wait(0.3)
    VIM:SendKeyEvent(false, Enum.KeyCode.E, false, game)
end
local function findHive()
    local platforms = hivePlatforms()
    if ownsHive(platforms) then return end
    for _, m in ipairs(platforms) do
        if not screen.Parent or ownsHive(platforms) then return end
        if not tweenToHive(hivePosition(m)) then return end
        local ref = m:FindFirstChild("PlayerRef")
        if ownsHive(platforms) then return end
        if ref and ref:IsA("ObjectValue") and ref.Value == nil then
            pressE()
            local started = os.clock()
            while screen.Parent and os.clock() - started < 1.5 do
                if ownsHive(platforms) then return end
                if ref.Value ~= nil then break end
                task.wait(0.1)
            end
        end
    end
end

-- FARM: travel with SmoothFlight; inside the field, follow a stable walking route.
-- Keep targets in a smaller safe rectangle to avoid hugging the field's edges.
local function bounds(field)
    if field:IsA("BasePart") then return field.CFrame, field.Size end
    if field:IsA("Model") then return field:GetBoundingBox() end
    return nil, nil
end

local function safeMargin(size)
    local narrow = math.min(size.X, size.Z)
    return math.min(10, math.max(3, narrow * 0.18), math.max(0, narrow / 2 - 2.5))
end

local function insideField(field, point, margin)
    local cf, size = bounds(field)
    if not cf then return false end
    local localPoint = cf:PointToObjectSpace(point)
    local m = margin or 0
    return math.abs(localPoint.X) <= math.max(0, size.X / 2 - m)
        and math.abs(localPoint.Z) <= math.max(0, size.Z / 2 - m)
end

local function onField(field, root)
    return insideField(field, root.Position, 0)
end

local function groundPosition(worldPoint)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    local exclude = {FlowerZones}
    local pr = workspace:FindFirstChild("Particles")
    if pr then table.insert(exclude, pr) end
    local camera = workspace.CurrentCamera
    local floatingTokens = camera and camera:FindFirstChild("DupedTokens")
    if floatingTokens then table.insert(exclude, floatingTokens) end
    if player.Character then table.insert(exclude, player.Character) end
    params.FilterDescendantsInstances = exclude
    params.RespectCanCollide = true
    local hit = workspace:Raycast(
        worldPoint + Vector3.new(0, 70, 0),
        Vector3.new(0, -250, 0), params
    )
    return hit and (hit.Position + Vector3.new(0, 2, 0)) or worldPoint
end

local function fieldCenter(field)
    local cf, size = bounds(field)
    if not cf then return nil end
    local top = cf:PointToWorldSpace(Vector3.new(0, size.Y / 2, 0))
    return groundPosition(top)
end

local function projectInside(field, worldPoint, marginOverride)
    local cf, size = bounds(field)
    if not cf then return nil end
    local p = cf:PointToObjectSpace(worldPoint)
    local margin = marginOverride or safeMargin(size)
    local x = math.max(0, size.X / 2 - margin)
    local z = math.max(0, size.Z / 2 - margin)
    return cf:PointToWorldSpace(Vector3.new(
        math.clamp(p.X, -x, x), p.Y, math.clamp(p.Z, -z, z)
    ))
end

-- Straight, predictable lawnmower lanes rather than random zigzags.
local PATROL_POINTS = {
    {-0.7, -0.7}, {0.7, -0.7},
    {0.7, 0}, {-0.7, 0},
    {-0.7, 0.7}, {0.7, 0.7}
}
local function patrolPoint(field, index)
    local cf, size = bounds(field)
    if not cf then return nil end
    local margin = safeMargin(size)
    local spanX = math.max(0, size.X / 2 - margin)
    local spanZ = math.max(0, size.Z / 2 - margin)
    local offsets = PATROL_POINTS[(index - 1) % #PATROL_POINTS + 1]
    local world = cf:PointToWorldSpace(Vector3.new(
        offsets[1] * spanX, size.Y / 2, offsets[2] * spanZ
    ))
    return groundPosition(world)
end

local function farmValid(token, fieldName)
    return screen.Parent ~= nil and farmEnabled and token == farmToken
        and selectedField == fieldName
end

local function horizontalDistance(a, b)
    return (Vector3.new(a.X - b.X, 0, a.Z - b.Z)).Magnitude
end

-- Avoid only during Combat's internal Stump Farm. Never affect manual Farm.
local function combatFarmUnsafe(point, extra)
    local threat = CombatSignals.AvoidMob
    if not threat or threat.Token ~= farmToken or threat.Field ~= selectedField then
        return false
    end
    -- If we cannot see the snail yet, park at the field center instead of
    -- wandering blindly into the edge of its circular path.
    if not threat.Position then return true end
    return point == nil or horizontalDistance(point, threat.Position)
        < threat.Radius + (extra or 0)
end

-- Collect only tokens within the SAFE interior, not the dangerous outer rim.
local particleRoot = nil
local collectibleFolder = nil
local lastFolderLookup = -math.huge
local collectibleCooldown = setmetatable({}, {__mode = "k"})
local function getCollectibleFolder()
    -- Prefer real collectible tokens even if the temporary Particles fallback
    -- was cached before Workspace.Collectibles finished loading.
    local direct = workspace:FindFirstChild("Collectibles")
    if direct then collectibleFolder = direct; return direct end
    if collectibleFolder and collectibleFolder.Parent then return collectibleFolder end
    if os.clock() - lastFolderLookup < 1 then return nil end
    lastFolderLookup = os.clock()
    collectibleFolder = workspace:FindFirstChild("Collectibles")
    if collectibleFolder then return collectibleFolder end
    particleRoot = workspace:FindFirstChild("Particles", true)
    if not particleRoot then return nil end
    collectibleFolder = particleRoot:FindFirstChild("Collectibles", true) or particleRoot
    return collectibleFolder
end

local function tokenInsideField(field, part)
    if not part or not part.Parent or not part:IsA("BasePart") then return false end
    local cf, size = bounds(field)
    if not cf or not insideField(field, part.Position, safeMargin(size)) then return false end
    local p = cf:PointToObjectSpace(part.Position)
    return p.Y >= -size.Y / 2 - 7 and p.Y <= size.Y / 2 + 18
end

local function nearestCollectible(field, root)
    local folder = getCollectibleFolder()
    if not folder then return nil, nil end
    local now = os.clock()
    local closestPart, closestDist = nil, math.huge
    for _, part in ipairs(folder:GetDescendants()) do
        if part:IsA("BasePart") and part.Name == "C"
            and (collectibleCooldown[part] or 0) <= now
            and tokenInsideField(field, part)
            and not combatFarmUnsafe(part.Position, 3) then
            local dist = horizontalDistance(root.Position, part.Position)
            -- rbxassetid://1629547638 outranks ordinary pollen/ability tokens.
            for _, decal in ipairs(part:GetChildren()) do
                if decal:IsA("Decal") or decal:IsA("Texture") then
                    if tostring(decal.Texture):match("(%d+)%D*$") == "1629547638" then
                        dist -= 100000
                        break
                    end
                end
            end
            if dist < closestDist then
                closestPart, closestDist = part, dist
            end
        end
    end
    if closestPart then
        local dest = groundPosition(closestPart.Position)
        local safeDest = projectInside(field, dest)
        if safeDest and horizontalDistance(dest, safeDest) < 1.5 then
            return closestPart, safeDest
        end
        collectibleCooldown[closestPart] = now + 3
    end
    return nil, nil
end

-- DIGITAL BEE DUPED TOKENS, located at Workspace.Camera.DupedTokens.
-- A Duped Token is a floating BasePart named C, and its client-side FrontDecal
-- carries the ability picture. Stand on the ground directly underneath it.
local function dupedFolder()
    local now = os.clock()
    if trackedDupedFolder and trackedDupedFolder.Parent then return trackedDupedFolder end
    if now - lastDupedFolderCheck < 0.65 then return nil end
    lastDupedFolderCheck = now
    local camera = workspace.CurrentCamera or workspace:FindFirstChild("Camera")
    trackedDupedFolder = camera and camera:FindFirstChild("DupedTokens")
    return trackedDupedFolder
end

local function frontDecalAssetId(part)
    local front = part:FindFirstChild("FrontDecal")
    if not front then return nil end
    for _, property in ipairs({"Texture", "ColorMap", "ColorMapContent"}) do
        local ok, val = pcall(function() return front[property] end)
        if ok and val then
            -- Supports both Decal.Texture and SurfaceAppearance.ColorMap.
            local id = tostring(val):match("%d+")
            if id then return id end
        end
    end
    return nil
end

local function isSmileDuped(part)
    if not part or not part.Parent then return false end
    local id = frontDecalAssetId(part)
    if id and id == DigitalSettings.SmileTextureId then return true end
    local name = string.lower(part.Name)
    if name:find("smile", 1, true) then return true end
    for _, child in ipairs(part:GetChildren()) do
        if string.lower(child.Name):find("smile", 1, true) then return true end
    end
    return false
end

local function dupedInField(field, part)
    if not DigitalSettings.Enabled or not part or not part.Parent
        or not part:IsA("BasePart") or part.Name ~= "C" then return false end
    local folder = dupedFolder()
    if not folder or not part:IsDescendantOf(folder) then return false end
    local cf, size = bounds(field)
    if not cf or not insideField(field, part.Position, 0.2) then return false end
    local localPos = cf:PointToObjectSpace(part.Position)
    -- Duped Tokens hover HIGH above the flowers; normal-token vertical limits
    -- would incorrectly filter them out. Reject tokens below the field only.
    return localPos.Y >= -size.Y / 2 - 5 and localPos.Y <= size.Y / 2 + 120
end

local function chooseDuped(field, root, smileOnly)
    if not DigitalSettings.Enabled then return nil, nil, nil end
    local folder = dupedFolder()
    if not folder then return nil, nil, nil end
    local now = os.clock()
    local best, dest, bestIsSmile, closest = nil, nil, false, math.huge
    for _, part in ipairs(folder:GetDescendants()) do
        if dupedInField(field, part) and (handledDuped[part] or 0) <= now
            and not combatFarmUnsafe(part.Position, 3) then
            local smile = isSmileDuped(part)
            if not smileOnly or smile then
                local ground = projectInside(field, groundPosition(part.Position), 0.4)
                if ground and horizontalDistance(ground, part.Position) <= 2.3 then
                    local d = horizontalDistance(root.Position, part.Position)
                    if (smile and not bestIsSmile) or (smile == bestIsSmile and d < closest) then
                        best, dest, bestIsSmile, closest = part, ground, smile, d
                    end
                end
            end
        end
    end
    return best, dest, bestIsSmile
end

local function hasSmileDuped(field)
    if not DigitalSettings.Enabled then return false end
    local now = os.clock()
    if now - lastDupedScan < 0.10 then return cachedSmilePresence end
    lastDupedScan = now
    local folder = dupedFolder()
    cachedSmilePresence = false
    if not folder then return false end
    for _, part in ipairs(folder:GetChildren()) do
        if dupedInField(field, part) and (handledDuped[part] or 0) <= now
            and isSmileDuped(part) then
            cachedSmilePresence = true
            return true
        end
    end
    return false
end

-- PRECISE TARGET TRACKING: event-driven, not GetDescendants() each frame.
-- Track all parts named Crosshair inside workspace.Particles, including nested ones.
local trackedCrosshairFolder = nil
local crosshairAddedConn = nil
local crosshairRemovedConn = nil
local crosshairRecords = setmetatable({}, {__mode = "k"})
local crosshairSerial = 0
local lastCrosshairFolderCheck = -math.huge
local function registerCrosshair(instance)
    if instance.Name ~= "Crosshair" or not instance:IsA("BasePart") then return end
    if crosshairRecords[instance] then return end
    crosshairSerial += 1
    crosshairRecords[instance] = {
        Serial = crosshairSerial,
        SeenAt = os.clock(),
        Visited = false,
        RetryAfter = 0,
    }
end
local function bindCrosshairFolder()
    if os.clock() - lastCrosshairFolderCheck < 0.75 then return end
    lastCrosshairFolderCheck = os.clock()
    local particles = workspace:FindFirstChild("Particles", true)
    if particles == trackedCrosshairFolder then return end
    if crosshairAddedConn then crosshairAddedConn:Disconnect(); crosshairAddedConn = nil end
    if crosshairRemovedConn then crosshairRemovedConn:Disconnect(); crosshairRemovedConn = nil end
    trackedCrosshairFolder = particles
    preciseProgress = nil -- Particles folder replaced; old point identities are invalid
    crosshairRecords = setmetatable({}, {__mode = "k"})
    if not particles then return end
    crosshairAddedConn = particles.DescendantAdded:Connect(registerCrosshair)
    crosshairRemovedConn = particles.DescendantRemoving:Connect(function(obj)
        if obj:IsA("BasePart") and obj.Name == "Crosshair" then
            -- Keep record until the loop sees destruction; don't reuse its identity.
            local info = crosshairRecords[obj]
            if info then info.RemovedAt = os.clock() end
        end
    end)
    for _, obj in ipairs(particles:GetDescendants()) do
        registerCrosshair(obj)
    end
end
-- Pick marks in appearance order, breaking ties by walking distance.
-- While waiting for the next mark, do not retarget a mark already touched.
local function crosshairInField(field, obj)
    if not trackedCrosshairFolder or not obj or not obj.Parent then return false end
    if not obj:IsDescendantOf(trackedCrosshairFolder) then return false end
    local cf, size = bounds(field)
    if not cf or not insideField(field, obj.Position, 0) then return false end
    local p = cf:PointToObjectSpace(obj.Position)
    return p.Y >= -size.Y / 2 - 9 and p.Y <= size.Y / 2 + 30
end
-- A new Instance can represent an OLD physical mark. Never count the
-- same X/Z location as another step just because Roblox spawned a clone.
local function samePrecisePoint(a, b)
    return a and b and horizontalDistance(a, b) <= PreciseSettings.PointSeparation
end
local function prunePrecisePoints()
    local now = os.clock()
    for i = #recentPrecisePoints, 1, -1 do
        if recentPrecisePoints[i].Expires <= now then
            table.remove(recentPrecisePoints, i)
        end
    end
end
local function alreadyTouchedPrecisePoint(field, pos, progress)
    if progress then
        for _, old in ipairs(progress.Positions) do
            if samePrecisePoint(old, pos) then return true end
        end
    end
    for _, entry in ipairs(recentPrecisePoints) do
        if entry.Field == field and samePrecisePoint(entry.Position, pos) then
            return true
        end
    end
    return false
end
local function validPreciseCandidate(field, obj, data, now, progress)
    -- Some effects recycle the same Part at a different location.
    -- Treat a genuinely relocated mark as a new step, not the old one.
    if data and data.Visited and data.TouchPosition
        and obj and obj.Parent and obj:IsA("BasePart")
        and not samePrecisePoint(obj.Position, data.TouchPosition) then
        crosshairSerial += 1
        data.Serial = crosshairSerial
        data.SeenAt = now
        data.Visited = false
        data.RetryAfter = 0
        data.TouchPosition = nil
    end
    return data ~= nil and not data.Visited and now >= (data.RetryAfter or 0)
        and crosshairInField(field, obj)
        and (not progress or data.Serial > (progress.LastSerial or 0))
        and not alreadyTouchedPrecisePoint(field, obj.Position, progress)
end
-- After touching 1 and 2, prefer the next forward point in the same
-- direction, instead of a marker behind us from another Precise volley.
local function preciseCandidateRank(progress, pos)
    if not progress or progress.Count < 2 then return 0 end
    local a = progress.Positions[progress.Count - 1]
    local b = progress.Positions[progress.Count]
    local step = Vector3.new(b.X - a.X, 0, b.Z - a.Z)
    if step.Magnitude <= PreciseSettings.PointSeparation then return 0 end
    local delta = Vector3.new(pos.X - b.X, 0, pos.Z - b.Z)
    local projection = delta:Dot(step.Unit)
    -- The three Precise targets are placed from closest to farthest.
    -- A backward-pointing candidate is a fallback, never first choice.
    if projection <= 0.75 then return 1 end
    return 0
end
local function nextPreciseCrosshair(field, root, progress)
    if not PreciseSettings.Enabled then return nil, nil end
    bindCrosshairFolder()
    prunePrecisePoints()
    local best, record, bestRank, bestSerial, nearest =
        nil, nil, math.huge, math.huge, math.huge
    local now = os.clock()
    for obj, data in pairs(crosshairRecords) do
        if validPreciseCandidate(field, obj, data, now, progress) then
            local rank = preciseCandidateRank(progress, obj.Position)
            local d = horizontalDistance(root.Position, obj.Position)
            if rank < bestRank
                or (rank == bestRank and data.Serial < bestSerial)
                or (rank == bestRank and data.Serial == bestSerial and d < nearest) then
                best, record = obj, data
                bestRank, bestSerial, nearest = rank, data.Serial, d
            end
        end
    end
    return best, record
end
local function hasPreciseCrosshair(field)
    if not PreciseSettings.Enabled then return false end
    bindCrosshairFolder()
    prunePrecisePoints()
    local now = os.clock()
    -- Check against any IN-PROGRESS volley so clones from 1 and 2 cannot
    -- interrupt walking/token collection between marks.
    local progress = preciseProgress
    if progress and (progress.Field ~= field or
        now - progress.LastAt > PreciseSettings.ResumeWindow) then
        progress = nil
    end
    for obj, data in pairs(crosshairRecords) do
        if validPreciseCandidate(field, obj, data, now, progress) then
            return true
        end
    end
    return false
end
local function confirmPreciseTouch(field, obj, rec, point)
    rec.Visited = true
    rec.TouchPosition = point
    prunePrecisePoints()
    table.insert(recentPrecisePoints, {
        Field = field,
        Position = point,
        Expires = os.clock() + PreciseSettings.PointMemorySeconds,
    })
    -- Multiple live Crosshair objects can refer to the same actual mark.
    -- Invalidate ALL clones at that location, not just this one Instance.
    for other, data in pairs(crosshairRecords) do
        if other.Parent and other:IsA("BasePart")
            and samePrecisePoint(other.Position, point) then
            data.Visited = true
            data.TouchPosition = point
        end
    end
end
local function getPreciseProgress(field, token, name)
    local now = os.clock()
    if preciseProgress and (
        preciseProgress.Field ~= field
        or preciseProgress.Token ~= token
        or preciseProgress.Name ~= name
        or now - preciseProgress.LastAt >= PreciseSettings.ResumeWindow
        or now - preciseProgress.StartedAt >= PreciseSettings.SessionLimit) then
        preciseProgress = nil
    end
    if not preciseProgress then
        preciseProgress = {
            Field = field, Token = token, Name = name,
            StartedAt = now, LastAt = now,
            Count = 0, LastSerial = 0, Positions = {},
            LastPosition = nil, LastObject = nil,
        }
    end
    return preciseProgress
end
local function unbindCrosshairFolder()
    if crosshairAddedConn then crosshairAddedConn:Disconnect(); crosshairAddedConn = nil end
    if crosshairRemovedConn then crosshairRemovedConn:Disconnect(); crosshairRemovedConn = nil end
    trackedCrosshairFolder = nil
    crosshairRecords = setmetatable({}, {__mode = "k"})
end

-- FACING LOCK: only real Flames/Bubble instances in the currently selected field.
-- No CFrame writes, no Humanoid:MoveTo, no positional forces, no walking state changes.
local faceAttachment, faceAlign, faceHumanoid = nil, nil, nil
local oldAutoRotate = nil
local facingTarget = nil -- {Object, Type, Position}
local nextFacingScan = 0
local lockFolderExpires = 0
local cachedFlames, cachedWTs = nil, nil
local facingScanInterval = 0.22

local function resetFacing()
    facingTarget = nil
    if faceAlign then faceAlign:Destroy(); faceAlign = nil end
    if faceAttachment then faceAttachment:Destroy(); faceAttachment = nil end
    if faceHumanoid and faceHumanoid.Parent and oldAutoRotate ~= nil then
        faceHumanoid.AutoRotate = oldAutoRotate
    end
    faceHumanoid = nil
    oldAutoRotate = nil
    if lockStatus.Parent then lockStatus.Text = "Facing: idle" end
end

local function getFacingFolders()
    local now = os.clock()
    if now < lockFolderExpires then return cachedFlames, cachedWTs end
    lockFolderExpires = now + 1.2
    local particles = workspace:FindFirstChild("Particles", true)
    cachedFlames = (particles and particles:FindFirstChild("PlayerFlames", true))
        or workspace:FindFirstChild("PlayerFlames", true)
    cachedWTs = (particles and particles:FindFirstChild("WTs", true))
        or workspace:FindFirstChild("WTs", true)
    return cachedFlames, cachedWTs
end

local function facingPosition(obj)
    if not obj or not obj.Parent then return nil end
    if obj:IsA("BasePart") then return obj.Position end
    if obj:IsA("Attachment") then return obj.WorldPosition end
    if obj:IsA("Model") then return obj:GetPivot().Position end
    return nil
end

local function facingInField(field, position)
    if not position or not insideField(field, position, 0) then return false end
    local cf, size = bounds(field)
    if not cf then return false end
    local p = cf:PointToObjectSpace(position)
    -- Ignore identical X/Z points from a different vertical layer of the map.
    return p.Y >= -size.Y / 2 - 9 and p.Y <= size.Y / 2 + 30
end

local function isFacingTargetValid(target, field)
    if not target or not LockSettings.Types[target.Type] then return false end
    local pos = facingPosition(target.Object)
    if not pos or not facingInField(field, pos) then return false end
    target.Position = pos
    return true
end

local function nearestFacingTarget(field, root)
    local best, bestDistance = nil, math.huge
    local flames, wts = getFacingFolders()
    local function consider(obj, kind)
        if not LockSettings.Types[kind] then return end
        local position = facingPosition(obj)
        if not facingInField(field, position) then return end
        local dist = horizontalDistance(root.Position, position)
        if dist >= bestDistance then return end
        best = {Object = obj, Type = kind, Position = position}
        bestDistance = dist
    end
    if LockSettings.Types.Flames and flames and flames.Parent then
        for _, object in ipairs(flames:GetChildren()) do
            if object.Name:match("^Flm") then consider(object, "Flames") end
        end
    end
    if LockSettings.Types.Bubble and wts and wts.Parent then
        for _, object in ipairs(wts:GetDescendants()) do
            if object.Name == "Bubble" and
                (object:IsA("BasePart") or object:IsA("Model")) then
                consider(object, "Bubble")
            end
        end
    end
    -- Hysteresis: maintain the current object to avoid twitching between
    -- neighboring effects; switch only when another becomes much closer.
    if isFacingTargetValid(facingTarget, field) then
        local oldDist = horizontalDistance(root.Position, facingTarget.Position)
        if not best or oldDist <= bestDistance * 1.35 then
            return facingTarget
        end
    end
    return best
end

local function setupFacing(humanoid, root)
    if faceAlign and faceAlign.Parent == root and faceHumanoid == humanoid then
        return true
    end
    resetFacing()
    faceHumanoid = humanoid
    oldAutoRotate = humanoid.AutoRotate
    humanoid.AutoRotate = false
    faceAttachment = Instance.new("Attachment")
    faceAttachment.Name = "BSSFacingAttachment"
    faceAttachment.Parent = root
    faceAlign = Instance.new("AlignOrientation")
    faceAlign.Name = "BSSFacingOnly"
    faceAlign.Mode = Enum.OrientationAlignmentMode.OneAttachment
    faceAlign.Attachment0 = faceAttachment
    faceAlign.RigidityEnabled = false
    faceAlign.Responsiveness = 27
    faceAlign.MaxTorque = 8000000
    faceAlign.MaxAngularVelocity = 16
    faceAlign.Parent = root
    return true
end

local facingConnection = RunService.Heartbeat:Connect(function()
    if not (screen.Parent and LockSettings.Enabled and farmEnabled and selectedField
        and (LockSettings.Types.Flames or LockSettings.Types.Bubble)) then
        if faceAlign or facingTarget then resetFacing() end
        return
    end
    local field = FlowerZones:FindFirstChild(selectedField)
    local char = player.Character
    local humanoid = char and char:FindFirstChildOfClass("Humanoid")
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if not field or not humanoid or humanoid.Health <= 0 or not root
        or not onField(field, root) then
        if faceAlign or facingTarget then resetFacing() end
        return
    end
    local now = os.clock()
    if now >= nextFacingScan or (facingTarget and not isFacingTargetValid(facingTarget, field)) then
        nextFacingScan = now + facingScanInterval
        facingTarget = nearestFacingTarget(field, root)
    end
    if not facingTarget then
        if faceAlign then resetFacing() end
        return
    end
    local selectedTarget = facingTarget
    if not setupFacing(humanoid, root) then return end
    -- Creating the constraint does not invalidate the already-validated target.
    if not facingTarget then facingTarget = selectedTarget end
    if not facingTarget then return end
    local pos = facingPosition(facingTarget.Object)
    if not facingInField(field, pos) then
        resetFacing()
        return
    end
    local horizontal = Vector3.new(pos.X - root.Position.X, 0, pos.Z - root.Position.Z)
    if horizontal.Magnitude > 0.2 then
        faceAlign.CFrame = CFrame.lookAt(Vector3.zero, horizontal.Unit)
    end
    lockStatus.Text = "Facing: " .. facingTarget.Type .. " / " .. facingTarget.Object.Name
end)

-- AUTO FLAME HEAT: use the same PlayerFlames objects as Facing Lock.
-- Standing NEAR a flame gives Heat; avoid snapping or teleporting onto it.
-- Only fires whose X/Z and height are in the selected FlowerZone are eligible.
local lastHeatScanAt = -math.huge
local cachedHeatFlame, cachedHeatDestination = nil, nil
local heatScanField = nil
local function nearestFlameForHeat(field, root)
    local now = os.clock()
    -- Allow token collection to continue uninterrupted between flame visits.
    if not FlameHeatSettings.Enabled or now < nextHeatVisitAt then
        return nil, nil
    end
    if now - lastHeatScanAt < 0.18 and heatScanField == field then
        local candidate = cachedHeatFlame
        if candidate and candidate.Parent and not visitedHeatFlames[candidate] then
            local pos = facingPosition(candidate)
            if facingInField(field, pos) then
                return candidate, cachedHeatDestination
            end
        elseif candidate == nil then
            return nil, nil
        end
    end
    lastHeatScanAt = now
    heatScanField = field
    cachedHeatFlame, cachedHeatDestination = nil, nil
    local flames = getFacingFolders() -- First return value is PlayerFlames.
    if not flames or not flames.Parent then return nil, nil end
    local nearestDistance = math.huge
    for _, obj in ipairs(flames:GetChildren()) do
        if obj:IsA("BasePart") and obj.Name:match("^Flm")
            and not visitedHeatFlames[obj] then
            local pos = obj.Position
            if facingInField(field, pos) then
                -- A flame near the boundary is allowed; stop 2 studs inside
                -- the field so walking never needs to cross into another field.
                local landing = projectInside(field, groundPosition(pos), 2)
                if landing and horizontalDistance(landing, pos) <= 2.6 then
                    local dist = horizontalDistance(root.Position, landing)
                    if dist < nearestDistance then
                        cachedHeatFlame = obj
                        cachedHeatDestination = landing
                        nearestDistance = dist
                    end
                end
            end
        end
    end
    return cachedHeatFlame, cachedHeatDestination
end

local function liveFlame(field, flame)
    return flame ~= nil and flame.Parent ~= nil
        and flame:IsA("BasePart") and facingInField(field, flame.Position)
end

-- Drive player movement continuously; do not bounce back to center near edges.
-- Every target is already clamped to the safe interior BEFORE movement begins.
local function beginWalking(field, token, name)
    local humanoid, root = getHumanoidAndRoot()
    if not farmValid(token, name) or humanoid.Health <= 0 then return false end
    if walkBound and walkingHumanoid == humanoid then return true end

    stopWalking()
    walkingHumanoid = humanoid
    originalWalkSpeed = humanoid.WalkSpeed
    humanoid.WalkSpeed = WalkSpeed
    local heading = Vector3.zero
    local cf, size = bounds(field)
    local hardMargin = cf and math.min(2, safeMargin(size) / 2) or 0

    RunService:BindToRenderStep(
        walkBindingName,
        Enum.RenderPriority.Input.Value + 2,
        function(dt)
            if not farmValid(token, name) or humanoid.Health <= 0 then
                humanoid:Move(Vector3.zero, false)
                return
            end
            if humanoid.WalkSpeed ~= WalkSpeed then humanoid.WalkSpeed = WalkSpeed end
            local goal = walkDestination
            if not goal then
                humanoid:Move(Vector3.zero, false)
                return
            end
            local vector = goal - root.Position
            local horizontal = Vector3.new(vector.X, 0, vector.Z)
            local desired = horizontal.Magnitude > 1.5 and horizontal.Unit or Vector3.zero

            -- Emergency recovery ONLY when actually outside the hard boundary.
            -- No per-frame 'turn toward center' near the normal walking area.
            if cf and not insideField(field, root.Position, hardMargin) then
                local rescue = projectInside(field, root.Position)
                if rescue then
                    local correction = rescue - root.Position
                    local flat = Vector3.new(correction.X, 0, correction.Z)
                    if flat.Magnitude > 1 then desired = flat.Unit end
                end
            end
            -- Live Stump Snail safety: retreat early, BEFORE contact. Tokens,
            -- crosshairs and patrol waypoints never override this steering.
            local threat = CombatSignals.AvoidMob
            if threat and threat.Token == token and threat.Field == name then
                if not threat.Position then
                    local center = threat.Center
                    if center then
                        local toCenter = Vector3.new(center.X-root.Position.X,
                            0,center.Z-root.Position.Z)
                        desired = toCenter.Magnitude > 3 and toCenter.Unit or Vector3.zero
                    else
                        desired = Vector3.zero
                    end
                else
                    local danger = threat.Position
                    local away = Vector3.new(root.Position.X-danger.X,0,
                        root.Position.Z-danger.Z)
                    local distance = away.Magnitude
                    local goalDangerous = goal and
                        horizontalDistance(goal,danger) < threat.Radius + 4
                    if distance < threat.Radius + 7 or goalDangerous then
                        local outward = distance > 0.1 and away.Unit or Vector3.new(1,0,0)
                        local step = math.max(9,threat.Radius + 11 - distance)
                        local escape = projectInside(field,root.Position + outward*step,0.5)
                        if not escape or horizontalDistance(escape,danger) < distance + 1 then
                            local center = threat.Center
                            if center and horizontalDistance(center,danger) > distance + 1 then
                                escape = center
                            else
                                local tangent = Vector3.new(-outward.Z,0,outward.X)
                                local a = projectInside(field,root.Position+tangent*13,0.5)
                                local b = projectInside(field,root.Position-tangent*13,0.5)
                                local da = a and horizontalDistance(a,danger) or -1
                                local db = b and horizontalDistance(b,danger) or -1
                                escape = da >= db and a or b
                            end
                        end
                        if escape and horizontalDistance(escape,danger) > distance + 0.5 then
                            local vector = Vector3.new(escape.X-root.Position.X,
                                0,escape.Z-root.Position.Z)
                            desired = vector.Magnitude > 0.8 and vector.Unit or Vector3.zero
                        else
                            desired = Vector3.zero
                        end
                        if distance < threat.Radius - 2 then humanoid.Jump = true end
                    end
                end
            end
            heading = heading:Lerp(desired, math.clamp(dt * 10, 0, 1))
            humanoid:Move(heading, false)
        end
    )
    walkBound = true
    return true
end

-- The ray only detects physical obstacles. Flower-zone markers and tokens
-- should not be interpreted as walls.
local function clearLine(from, to)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    local excluded = {FlowerZones}
    if player.Character then table.insert(excluded, player.Character) end
    if particleRoot then table.insert(excluded, particleRoot) end
    local camera = workspace.CurrentCamera
    local floatingTokens = camera and camera:FindFirstChild("DupedTokens")
    if floatingTokens then table.insert(excluded, floatingTokens) end
    params.FilterDescendantsInstances = excluded
    params.RespectCanCollide = true
    local source = from + Vector3.new(0, 1.5, 0)
    local finish = Vector3.new(to.X, from.Y, to.Z) + Vector3.new(0, 1.5, 0)
    return workspace:Raycast(source, finish - source, params) == nil
end

-- Shared loot walker used after combat and after planter harvest.
-- The priority decal 1629547638 is checked on actual C tokens, not icons.
-- Walking is controlled every render frame (same style as regular Farm),
-- never by a stream of HumanoidRootPart tweens.
local LootTools = {}
do
    local bindingName = "BSSRewardWalk_" .. tostring(player.UserId)
    function LootTools.IsPriority(part)
        if not part or not part:IsA("BasePart") then return false end
        for _, obj in ipairs(part:GetChildren()) do
            if obj:IsA("Decal") or obj:IsA("Texture") then
                local id = tostring(obj.Texture):match("(%d+)%D*$")
                if id == "1629547638" then return true end
            end
        end
        return false
    end
    function LootTools.Each(callback)
        local primary = workspace:FindFirstChild("Collectibles")
        local alternate = getCollectibleFolder()
        local visited = {}
        local folders = {}
        if primary then table.insert(folders, primary) end
        if alternate and alternate ~= primary then table.insert(folders, alternate) end
        for _, folder in ipairs(folders) do
            if folder and not visited[folder] then
                visited[folder] = true
                for _, part in ipairs(folder:GetDescendants()) do
                    if part:IsA("BasePart") and (part.Name == "C"
                        or (part.Name:lower():find("token", 1, true)
                            and part:FindFirstChildWhichIsA("Decal"))) then
                        callback(part)
                    end
                end
            end
        end
    end
    function LootTools.Snapshot()
        local seen = setmetatable({}, {__mode = "k"})
        LootTools.Each(function(part) seen[part] = true end)
        return seen
    end
    -- FieldLab v8.6.10: watch native Alerts > AlertBox text during a fight.
    -- These messages appear AFTER the server grants a reward. They identify
    -- reward sources ("from Ladybug"), not necessarily which 3D token spawned
    -- that reward before collection. Connections are disconnected per fight.
    function LootTools.BeginAlertTracker()
        local tracker = {Events = {}, Connections = {}, Seen = setmetatable({}, {__mode = "k"}),
            Active = true, Root = nil}
        local function normalized(value)
            return tostring(value or ""):lower():gsub("[^%w]","")
                :gsub("spawner",""):gsub("monster",""):gsub("%d+$","")
        end
        local function record(message)
            if not tracker.Active then return end
            local clean = tostring(message or ""):gsub("^%s+",""):gsub("%s+$","")
            if clean == "" then return end
            local source = clean:match("%(%s*[Ff][Rr][Oo][Mm]%s+([^%)]+)%)")
            local defeated = clean:match("[Dd]efeated%s+([^!]+)!")
            if not source and not defeated then return end
            table.insert(tracker.Events, {
                Text = clean, Source = source, Defeated = defeated, At = os.clock(),
            })
            if #tracker.Events > 90 then table.remove(tracker.Events, 1) end
        end
        local function isAlertLabel(node)
            if not node:IsA("TextLabel") then return false end
            if node.Name == "AlertBox" then return true end
            local parent = node.Parent
            return parent and parent.Name == "AlertBox"
        end
        local function watch(node, existing)
            if not isAlertLabel(node) or tracker.Seen[node] ~= nil then return end
            tracker.Seen[node] = node.Text
            if not existing then record(node.Text) end
            table.insert(tracker.Connections,
                node:GetPropertyChangedSignal("Text"):Connect(function()
                    if not tracker.Active then return end
                    local msg = node.Text
                    if tracker.Seen[node] == msg then return end
                    tracker.Seen[node] = msg
                    record(msg)
                end))
        end
        local function bindRoot(root)
            if tracker.Root == root then return end
            tracker.Root = root
            watch(root, true)
            for _,obj in ipairs(root:GetDescendants()) do watch(obj, true) end
            table.insert(tracker.Connections, root.DescendantAdded:Connect(function(node)
                watch(node, false)
            end))
        end
        local existingRoot = playerGui:FindFirstChild("Alerts", true)
        if existingRoot then bindRoot(existingRoot) end
        table.insert(tracker.Connections,playerGui.DescendantAdded:Connect(function(node)
            if not tracker.Active then return end
            if node.Name == "Alerts" then
                bindRoot(node)
            elseif tracker.Root and node:IsDescendantOf(tracker.Root) then
                watch(node, false)
            end
        end))
        function tracker:Summary(expectedSource)
            local wanted = normalized(expectedSource)
            local items, victory = {}, false
            for _,event in ipairs(self.Events) do
                if event.Source and wanted ~= "" and normalized(event.Source) == wanted then
                    local reward = event.Text:match("^(.-)%s*%(%s*[Ff][Rr][Oo][Mm]%s+")
                        or event.Text
                    local itemText = (reward:gsub("^%s+",""):gsub("%s+$",""))
                    table.insert(items, itemText)
                end
                if event.Defeated and wanted ~= ""
                    and normalized(event.Defeated) == wanted then
                    victory = true
                end
            end
            local preview={}
            for i=1,math.min(#items,5) do preview[i]=items[i] end
            return #items,table.concat(preview,", "),victory
        end
        function tracker:Stop()
            if not self.Active then return end
            self.Active=false
            for _,connection in ipairs(self.Connections) do
                pcall(function() connection:Disconnect() end)
            end
            table.clear(self.Connections)
        end
        return tracker
    end
    function LootTools.Walk(target, permitted, targetPart)
        if not permitted() then return false end
        local humanoid, root = getHumanoidAndRoot()
        if not humanoid or humanoid.Health <= 0 then return false end
        -- Make sure another Farm walking binding is not left driving Humanoid.
        stopWalking()
        local previousSpeed = humanoid.WalkSpeed
        humanoid.WalkSpeed = WalkSpeed
        local desiredPoint = target
        local heading = Vector3.zero
        local bound = false
        local function cleanup()
            if bound then RunService:UnbindFromRenderStep(bindingName); bound = false end
            if humanoid and humanoid.Parent then
                humanoid:Move(Vector3.zero, false)
                humanoid.WalkSpeed = previousSpeed
            end
        end
        local ok, arrived = pcall(function()
            RunService:BindToRenderStep(bindingName, Enum.RenderPriority.Input.Value + 2, function(dt)
                if humanoid.Health <= 0 or not permitted() then
                    humanoid:Move(Vector3.zero, false)
                    return
                end
                local vec = desiredPoint - root.Position
                local flat = Vector3.new(vec.X, 0, vec.Z)
                local wanted = flat.Magnitude > 1.2 and flat.Unit or Vector3.zero
                heading = heading:Lerp(wanted, math.clamp(dt * 9, 0, 1))
                humanoid:Move(heading, false)
            end)
            bound = true
            for attempt = 1, 2 do
                if not permitted() then return false end
                local points = nil
                if clearLine(root.Position, target) then
                    points = {{Position = target, Action = Enum.PathWaypointAction.Walk}}
                else
                    local path = PathfindingService:CreatePath({
                        AgentRadius = 2, AgentHeight = 5, AgentCanJump = true,
                        AgentCanClimb = true, WaypointSpacing = 6
                    })
                    local good = pcall(function() path:ComputeAsync(root.Position, target) end)
                    if good and path.Status == Enum.PathStatus.Success then
                        points = path:GetWaypoints()
                    end
                    path:Destroy()
                end
                if not points then return false end
                local blocked = false
                for wpIndex, wp in ipairs(points) do
                    desiredPoint = wp.Position
                    local before = os.clock()
                    local improvedAt, best = before, math.huge
                    local jumped = false
                    while permitted() and humanoid.Health > 0 do
                        if targetPart and not targetPart.Parent then return true end
                        local dist = horizontalDistance(root.Position, desiredPoint)
                        if dist <= (wpIndex == #points and 0.9 or 2.5) then break end
                        if dist < best - .25 then
                            best, improvedAt = dist, os.clock()
                        end
                        if wp.Action == Enum.PathWaypointAction.Jump and not jumped then
                            humanoid.Jump = true
                            jumped = true
                        end
                        if os.clock() - improvedAt > 1.7 then
                            if not jumped and humanoid.FloorMaterial ~= Enum.Material.Air then
                                humanoid.Jump = true
                                jumped = true
                                improvedAt = os.clock()
                            else blocked = true; break end
                        end
                        if os.clock() - before > math.max(4.5, dist / math.max(WalkSpeed, 1) * 2.4 + 2) then
                            blocked = true; break
                        end
                        task.wait(.05)
                    end
                    if blocked or not permitted() then break end
                end
                if horizontalDistance(root.Position, target) <= 1.25
                    or (targetPart and not targetPart.Parent) then return true end
                if not blocked then break end
            end
            return horizontalDistance(root.Position, target) <= 1.25
        end)
        cleanup()
        if not ok then warn("[BSS Loot walking]", arrived) end
        return ok and arrived == true
    end
    -- v8.6.10: one continuous steering session, not a new walk binding for
    -- every token. Keep the heading and WalkSpeed across target changes.
    function LootTools.CollectNew(options)
        local center = options.Center
        local centers = options.Centers or {center}
        local radius = options.Radius or 40
        local duration = options.Duration or 28
        local baseline = options.Before or {}
        local allowed = options.Allowed or function() return true end
        local field = options.Field
        local report = options.Report or function() end
        local initialGrace = math.clamp(options.DropGrace or 3, 1.5, 6)
        local quietPeriod = math.clamp(options.QuietPeriod or 1.4, 0.8, 2.5)
        local humanoid, root = getHumanoidAndRoot()
        if not humanoid or humanoid.Health <= 0 or not root then return 0 end
        if not allowed() then return 0 end

        local previousSpeed = humanoid.WalkSpeed
        local heading, desiredPoint = Vector3.zero, nil
        local target = nil
        local targetSince, bestDistance, improvedAt, nearSince = 0, math.huge, 0, nil
        local blockedUntil = setmetatable({}, {__mode = "k"})
        local seen = setmetatable({}, {__mode = "k"})
        local ownership = setmetatable({}, {__mode = "k"})
        local firstFound, lastNew, lastResolved = nil, nil, nil
        local collected, ignored, classified = 0, 0, 0
        local began = os.clock()
        local controllerBound = false
        local ownerFields = {"OwnerUserId", "OwnerId", "UserId", "Owner", "Player"}
        -- These are only definitive when the token actually exposes an owner.
        -- Normal BSS 'C' tokens usually do not expose a reliable monster source.
        local function foreignOwner(part)
            local cached = ownership[part]
            if cached ~= nil then return cached end
            local node = part
            for depth = 1, 2 do
                if not node or node == workspace then break end
                for _,key in ipairs(ownerFields) do
                    local val = node:GetAttribute(key)
                    local child = node:FindFirstChild(key)
                    if val == nil and child and child:IsA("ValueBase") then
                        val = child.Value
                    end
                    if val ~= nil then
                        if typeof(val) == "Instance" and val:IsA("Player") then
                            ownership[part] = val ~= player
                            return ownership[part]
                        end
                        local id = tonumber(val)
                        if id then
                            ownership[part] = id ~= player.UserId
                            return ownership[part]
                        elseif type(val) == "string" and val ~= "" then
                            local normalized = val:lower()
                            if normalized == player.Name:lower()
                                or normalized == player.DisplayName:lower() then
                                ownership[part] = false
                                return false
                            end
                        end
                    end
                end
                node = node.Parent
            end
            ownership[part] = false -- unknown, NOT proof of ownership
            return false
        end
        local function eligible(part)
            if not part or not part.Parent or baseline[part]
                or foreignOwner(part) then return false end
            local p = part.Position
            if field and not insideField(field, p, 0) then return false end
            for _,source in ipairs(centers) do
                if typeof(source) == "Vector3"
                    and horizontalDistance(p,source) <= radius
                    and math.abs(p.Y-source.Y) <= 80 then return true end
            end
            return false
        end
        local function resolveCurrent(now)
            if not target then return end
            if not target.Parent then
                if horizontalDistance(root.Position,desiredPoint or root.Position) <= 2.5 then
                    collected += 1
                end
                lastResolved = now
            end
            target, desiredPoint, nearSince = nil, nil, nil
        end
        local function beginTarget(part, now)
            target = part
            desiredPoint = groundPosition(part.Position)
            targetSince, improvedAt = now, now
            bestDistance = math.huge
            nearSince = nil
            report(string.format("Loot: %s | %d confirmed / %d new",
                options.Source or "reward", collected, classified))
        end
        -- Only one BindToRenderStep for the whole sweep; steering never resets
        -- between tokens and does not produce the walk/stop/walk stutter.
        local function drive(dt)
            if not allowed() or humanoid.Health <= 0 or not root.Parent then
                humanoid:Move(Vector3.zero,false)
                return
            end
            if humanoid.WalkSpeed ~= WalkSpeed then humanoid.WalkSpeed = WalkSpeed end
            local wanted = Vector3.zero
            if desiredPoint then
                local vec = desiredPoint - root.Position
                local flat = Vector3.new(vec.X,0,vec.Z)
                if flat.Magnitude > 0.95 then wanted = flat.Unit end
            end
            heading = heading:Lerp(wanted,math.clamp(dt*12,0,1))
            humanoid:Move(heading,false)
        end
        local function run()
            stopWalking()
            humanoid.WalkSpeed = WalkSpeed
            -- Only a single combat/planter task is expected to own the loot lock.
            pcall(function() RunService:UnbindFromRenderStep(bindingName) end)
            RunService:BindToRenderStep(bindingName,
                Enum.RenderPriority.Input.Value + 2,drive)
            controllerBound = true
            while allowed() and humanoid.Health > 0 and root.Parent
                and os.clock()-began < duration do
                local now = os.clock()
                local best, score = nil, math.huge
                local actionable = 0
                LootTools.Each(function(part)
                    if eligible(part) and (blockedUntil[part] or 0) <= now then
                        if not seen[part] then
                            seen[part] = now
                            firstFound = firstFound or now
                            lastNew = now
                            classified += 1
                        end
                        actionable += 1
                        local d = horizontalDistance(root.Position,part.Position)
                        local candidateScore = d - (LootTools.IsPriority(part) and 24 or 0)
                        if candidateScore < score then best,score = part,candidateScore end
                    end
                end)
                if target and not target.Parent then
                    resolveCurrent(now)
                elseif target and ((blockedUntil[target] or 0) > now or not eligible(target)) then
                    resolveCurrent(now)
                end
                -- Stick to the active token until collected or genuinely stuck.
                -- A newly spawned token does not make the character zigzag.
                if not target and best then beginTarget(best,now) end
                if target then
                    local distance = horizontalDistance(root.Position,desiredPoint)
                    if distance < bestDistance - 0.25 then
                        bestDistance,improvedAt = distance,now
                    end
                    if distance <= 1.25 then
                        nearSince = nearSince or now
                        if now-nearSince >= 0.65 then
                            -- This visible C was not picked up despite contact:
                            -- skip temporarily instead of standing and jittering.
                            blockedUntil[target] = now + 3.0
                            ignored += 1
                            lastResolved = now
                            target,desiredPoint,nearSince = nil,nil,nil
                        end
                    elseif now-improvedAt >= 2.0 or now-targetSince > 5.5 then
                        blockedUntil[target] = now + 3.0
                        ignored += 1
                        lastResolved = now
                        target,desiredPoint,nearSince = nil,nil,nil
                    end
                else
                    local idleSince = math.max(lastNew or began,lastResolved or began)
                    -- No drop: short replication grace. Existing bee/field
                    -- tokens from before the kill are never a reason to wait.
                    if not firstFound and now-began >= initialGrace then
                        report("Loot complete: no fresh drops after "
                            .. string.format("%.1fs",now-began))
                        break
                    end
                    -- Drops were observed: end as soon as all actionable fresh
                    -- tokens have vanished/been visited and the area stays quiet.
                    if firstFound and actionable==0 and now-idleSince >= quietPeriod then
                        report(string.format(
                            "Loot complete: %d near-contact, %d skipped, %.1fs",
                            collected,ignored,now-began))
                        break
                    end
                    -- All remaining targets are blocked/uncollectible. Do not
                    -- wait for the full 48/60s cap; give a short retry window.
                    if firstFound and actionable>0 and now-idleSince>=2.5 then
                        report(string.format("Loot exit: %d unreachable token(s)",actionable))
                        break
                    end
                end
                task.wait(0.10)
            end
        end
        local ok,err = pcall(run)
        if controllerBound then
            pcall(function() RunService:UnbindFromRenderStep(bindingName) end)
        end
        if humanoid and humanoid.Parent then
            humanoid:Move(Vector3.zero,false)
            humanoid.WalkSpeed = previousSpeed
        end
        if not ok then warn("[FieldLab Loot]",err) end
        return collected
    end
end

-- Commit to the current destination, and change targets only after arrival,
-- disappearance or an actual blockage. Never interrupt every 0.35 seconds.
local function navigateInField(field, destination, token, name, targetPart, flameObject, crosshairObject, dupedObject)
    if not beginWalking(field, token, name) then return false end
    local humanoid, root = getHumanoidAndRoot()
    destination = projectInside(field, destination,
        (crosshairObject or dupedObject) and 0.3 or (flameObject and 2 or nil))
    if not destination then return false end
    if combatFarmUnsafe(destination, 3) then
        walkDestination = nil
        if targetPart then collectibleCooldown[targetPart] = os.clock() + 2.5 end
        return false
    end
    if horizontalDistance(root.Position, destination) <=
        ((crosshairObject or dupedObject) and 1.15 or (flameObject and 1.4 or 2.8)) then
        return true
    end

    for attempt = 1, 2 do
        if not farmValid(token, name) then return false end
        -- Precise Bee outranks ongoing collectible, patrol and Flame movements.
        if not (dupedObject and isSmileDuped(dupedObject)) and hasSmileDuped(field) then
            walkDestination = nil
            return false
        end
        if not crosshairObject and not (dupedObject and isSmileDuped(dupedObject))
            and hasPreciseCrosshair(field) then
            walkDestination = nil
            return false
        end
        if crosshairObject and (not PreciseSettings.Enabled
            or not crosshairInField(field, crosshairObject)) then
            walkDestination = nil
            return false
        end
        if dupedObject and not dupedInField(field, dupedObject) then
            walkDestination = nil
            return false
        end
        if targetPart and not tokenInsideField(field, targetPart) then return false end
        if flameObject and (not FlameHeatSettings.Enabled or not liveFlame(field, flameObject)) then
            walkDestination = nil
            return false
        end
        local path = nil
        local waypointList = nil
        local blockedAhead = false
        local blockedConnection = nil
        local waypointIndex = 2

        if clearLine(root.Position, destination) then
            waypointList = {
                {Position = root.Position, Action = Enum.PathWaypointAction.Walk},
                {Position = destination, Action = Enum.PathWaypointAction.Walk}
            }
        else
            path = PathfindingService:CreatePath({
                AgentRadius = 2,
                AgentHeight = 5,
                AgentCanJump = true,
                AgentCanClimb = true,
                WaypointSpacing = 6
            })
            local ok = pcall(function()
                path:ComputeAsync(root.Position, destination)
            end)
            if not ok or path.Status ~= Enum.PathStatus.Success then
                path:Destroy()
                return false
            end
            waypointList = path:GetWaypoints()
            -- Pathfinding can leave the area to go around a nearby wall;
            -- reject those paths instead of chasing collectibles beyond the field.
            for _, wp in ipairs(waypointList) do
                if not insideField(field, wp.Position, 1.5) then
                    path:Destroy()
                    return false
                end
            end
            blockedConnection = path.Blocked:Connect(function(index)
                if index >= waypointIndex then blockedAhead = true end
            end)
        end

        local arrived = true
        local index = 2
        -- One continuous course, no zero-speed command at each waypoint.
        while index <= #waypointList do
            waypointIndex = index
            local wp = waypointList[index]
            local target = wp.Position
            local mustJump = wp.Action == Enum.PathWaypointAction.Jump

            -- Skip ONLY the next ordinary waypoint when a direct line is clear.
            -- Do not revisit a skipped waypoint or skip jump instructions.
            if not mustJump and index < #waypointList then
                local nextWp = waypointList[index + 1]
                if nextWp.Action ~= Enum.PathWaypointAction.Jump
                    and clearLine(root.Position, nextWp.Position) then
                    waypointIndex = index + 1
                    target = nextWp.Position
                end
            end
            walkDestination = target
            local started = os.clock()
            local lastProgressAt = started
            local lastBestDistance = math.huge
            local recoveryJumpAt = 0
            local jumped = false
            local threshold = (waypointIndex == #waypointList)
                and ((crosshairObject or dupedObject) and 1.15 or (flameObject and 1.5 or 2.6)) or 3.4

            while farmValid(token, name) do
                if humanoid.Health <= 0 or blockedAhead then break end
                if not (dupedObject and isSmileDuped(dupedObject)) and hasSmileDuped(field) then
                    blockedAhead = true
                    break
                end
                if not crosshairObject and not (dupedObject and isSmileDuped(dupedObject))
                    and hasPreciseCrosshair(field) then
                    blockedAhead = true
                    break
                end
                if crosshairObject and (not PreciseSettings.Enabled
                    or not crosshairInField(field, crosshairObject)) then
                    blockedAhead = true
                    break
                end
                if dupedObject and not dupedInField(field, dupedObject) then
                    blockedAhead = true
                    break
                end
                if targetPart and not tokenInsideField(field, targetPart) then break end
                if flameObject then
                    if not FlameHeatSettings.Enabled or not liveFlame(field, flameObject) then break end
                end
                local distance = horizontalDistance(root.Position, target)
                if distance <= threshold then break end

                local now = os.clock()
                if distance < lastBestDistance - 0.35 then
                    lastBestDistance = distance
                    lastProgressAt = now
                end
                if mustJump and distance <= 8 and not jumped then
                    humanoid.Jump = true
                    jumped = true
                end
                if now - lastProgressAt > 1.65 then
                    if recoveryJumpAt == 0 and humanoid.FloorMaterial ~= Enum.Material.Air then
                        humanoid.Jump = true
                        recoveryJumpAt = now
                        lastProgressAt = now
                    else
                        break
                    end
                end
                if now - started > math.max(4, distance / math.max(WalkSpeed, 1) * 2.1 + 3) then
                    break
                end
                task.wait(0.05)
            end
            if not farmValid(token, name) then arrived = false; break end
            if flameObject and (not FlameHeatSettings.Enabled or not liveFlame(field, flameObject)) then
                arrived = false
                break
            end
            if dupedObject and not dupedInField(field, dupedObject) then
                arrived = false
                break
            end
            if blockedAhead or (targetPart and not tokenInsideField(field, targetPart))
                or horizontalDistance(root.Position, target) > threshold then
                arrived = false
                break
            end
            index = waypointIndex + 1
        end

        if blockedConnection then blockedConnection:Disconnect() end
        if path then path:Destroy() end
        if not farmValid(token, name) then return false end
        if not (dupedObject and isSmileDuped(dupedObject)) and hasSmileDuped(field) then
            walkDestination = nil
            return false
        end
        if not crosshairObject and not (dupedObject and isSmileDuped(dupedObject))
            and hasPreciseCrosshair(field) then
            walkDestination = nil
            return false
        end
        if crosshairObject and (not PreciseSettings.Enabled
            or not crosshairInField(field, crosshairObject)) then
            walkDestination = nil
            return false
        end
        if dupedObject and not dupedInField(field, dupedObject) then
            walkDestination = nil
            return false
        end
        if targetPart and not tokenInsideField(field, targetPart) then return false end
        if flameObject and (not FlameHeatSettings.Enabled or not liveFlame(field, flameObject)) then
            walkDestination = nil
            return false
        end
        if arrived or horizontalDistance(root.Position, destination) <=
            ((crosshairObject or dupedObject) and 1.35 or (flameObject and 1.7 or 3)) then
            return true
        end
        -- Only replan after confirmed obstruction or being stuck; at most once.
    end
    return false
end
-- Fly using one physics constraint to the selected field, then walk normally.
local function goToField(field, token, name)
    if not farmValid(token, name) then return false end
    local _, root = getHumanoidAndRoot()
    local center = fieldCenter(field)
    if not center then return false end
    local destination = center + Vector3.new(0, 0.5, 0)
    -- Ascend first on long flights, then travel in one uninterrupted session.
    local waypoints = {}
    if (root.Position - destination).Magnitude > 28 then
        local altitude = math.max(root.Position.Y, destination.Y) + 15
        table.insert(waypoints, Vector3.new(root.Position.X, altitude, root.Position.Z))
        table.insert(waypoints, Vector3.new(destination.X, altitude, destination.Z))
    end
    table.insert(waypoints, destination)
    return SmoothFlight.Path(root, waypoints, function()
        return farmValid(token, name)
    end, TweenSpeed, function(handle, previous)
        if previous then
            if currentFarmTravelTween == previous then currentFarmTravelTween = nil end
        else
            currentFarmTravelTween = handle
        end
    end)
end

-- One sprinkler placement after arriving at the current field's center.
-- This is invoked by the Farm coroutine, so it cannot wrestle movement from
-- that same farm job. Calls the game's Sprinkler Builder item once, never in
-- a tight loop. The server may still reject the action (not owned/cooldown).
do
    function CombatSignals.PlaceSprinkler(field, token, name)
        local setting = CombatSignals.Sprinkler
        if not setting.Enabled or not farmValid(token, name) then return end
        local now = os.clock()
        if setting.LastCharacter ~= player.Character then
            setting.LastCharacter = player.Character
            setting.LastField = nil
            setting.RetryAt = 0
        end
        if setting.LastField == name or now < setting.RetryAt then return end
        local center = fieldCenter(field)
        if not center then setting.RetryAt = now + 12; return end
        -- Protect against repeated attempts if the remote is missing or blocked.
        setting.RetryAt = now + 18
        local _, root = getHumanoidAndRoot()
        if horizontalDistance(root.Position, center) > 3.8 then
            stopWalking()
            if not goToField(field, token, name) then return end
        end
        if not farmValid(token, name) or not setting.Enabled then return end
        _, root = getHumanoidAndRoot()
        if horizontalDistance(root.Position, center) > 5.0 or not onField(field, root) then
            return
        end
        local events = game:GetService("ReplicatedStorage"):FindFirstChild("Events")
        local remote = events and events:FindFirstChild("PlayerActivesCommand")
        if not remote or not remote:IsA("RemoteEvent") then
            warn("[FieldLab Sprinkler] Events.PlayerActivesCommand not available")
            return
        end
        local ok, err = pcall(function()
            remote:FireServer({Name = "Sprinkler Builder"})
        end)
        if ok then
            setting.LastField = name
            setting.LastAt = os.clock()
            print("[FieldLab Sprinkler] Placement requested at center of " .. name)
        else
            warn("[FieldLab Sprinkler] " .. tostring(err))
        end
    end
end

-- Target Practice can show all marks together or stagger them.
-- After the third touch, stand at its position until the final mark disappears (shot)
-- or until a bounded timeout. We do not assume client visuals expose a shot event.
local function runPreciseSession(field, token, name)
    if not PreciseSettings.Enabled then return false end
    local humanoid, root = getHumanoidAndRoot()
    if not hasPreciseCrosshair(field) then return false end
    local progress = getPreciseProgress(field, token, name)
    preciseStatus.Text = string.format("Precise: %d/3 tracking", progress.Count)

    while farmValid(token, name) and PreciseSettings.Enabled
        and humanoid.Health > 0
        and os.clock() - progress.StartedAt < PreciseSettings.SessionLimit
        and progress.Count < 3 do
        if hasSmileDuped(field) then break end
        local obj, rec = nextPreciseCrosshair(field, root, progress)
        if obj and rec then
            local targetPosition = obj.Position
            local landing = projectInside(field, groundPosition(targetPosition), 0.3)
            if not landing or horizontalDistance(landing, targetPosition) > 2.4 then
                rec.RetryAfter = os.clock() + 2
            else
                local expected = progress.Count + 1
                preciseStatus.Text = string.format("Precise: %d/3 -> target %d", progress.Count, expected)
                local arrived = navigateInField(field, landing, token, name, nil, nil, obj)
                walkDestination = nil
                if not farmValid(token, name) or not PreciseSettings.Enabled then break end

                -- Count exactly one spatially distinct point per step.
                -- If the object was replaced at the same position, its clone
                -- is still the SAME point, not the following one.
                local nearEnough = horizontalDistance(root.Position, landing) <= 1.8
                if nearEnough and (arrived or not crosshairInField(field, obj))
                    and not alreadyTouchedPrecisePoint(field, targetPosition, progress) then
                    confirmPreciseTouch(field, obj, rec, targetPosition)
                    progress.Count += 1
                    progress.LastSerial = rec.Serial
                    progress.LastAt = os.clock()
                    progress.LastPosition = landing
                    progress.LastObject = obj
                    table.insert(progress.Positions, targetPosition)
                    preciseStatus.Text = string.format("Precise: touched %d/3", progress.Count)
                    print(string.format("[Precise] Unique point %d/3: %s (serial %d)",
                        progress.Count, tostring(targetPosition), rec.Serial))
                    task.wait(0.07)
                else
                    -- Don't retry the exact same stale/blocked marker every frame.
                    rec.RetryAfter = os.clock() + 0.65
                    task.wait(0.08)
                end
            end
        else
            walkDestination = nil
            -- Short grace before resuming farming. Progress persists, so the
            -- next newly spawned mark becomes 2 or 3, never a fresh 1.
            if progress.Count == 0
                or os.clock() - progress.LastAt >= PreciseSettings.NextTargetGrace then
                break
            end
            preciseStatus.Text = string.format("Precise: waiting for %d/3", progress.Count + 1)
            task.wait(0.06)
        end
    end

    local touched = progress.Count
    if farmValid(token, name) and PreciseSettings.Enabled
        and touched >= 3 and progress.LastPosition then
        -- Hold at the THIRD DISTINCT location. New clones from 1/2 cannot
        -- change this destination or extend the hold indefinitely.
        walkDestination = nil
        preciseStatus.Text = "Precise: HOLD 3/3, waiting shot"
        local holdStarted = os.clock()
        local deadline = holdStarted + PreciseSettings.MaxShotWait
        local clearSince = nil
        while farmValid(token, name) and PreciseSettings.Enabled
            and humanoid.Health > 0 and os.clock() < deadline do
            if hasSmileDuped(field) then break end
            if not crosshairInField(field, progress.LastObject) then
                clearSince = clearSince or os.clock()
                if os.clock() - clearSince >= 0.18
                    and os.clock() - holdStarted >= 0.35 then break end
            else
                clearSince = nil
            end
            walkDestination = nil
            task.wait(0.06)
        end
        preciseStatus.Text = "Precise: 3/3 completed, resume farm"
        preciseProgress = nil
    else
        -- Not a fresh attempt next time: keep 1/3 or 2/3 until the volley
        -- expires, so target 3 is still counted as 3 after a brief pause.
        preciseStatus.Text = string.format("Precise: %d/3, resume farm", touched)
        if not PreciseSettings.Enabled then preciseProgress = nil end
    end
    walkDestination = nil
    return touched > 0
end

local function runDupedToken(field, token, name, obj, destination, smile)
    if not DigitalSettings.Enabled or not dupedInField(field, obj) then return end
    -- Prevent repeated visits to an already activated but still visible part.
    handledDuped[obj] = os.clock() + DigitalSettings.TargetRetryDelay
    lastDupedScan = -math.huge
    digitalStatus.Text = smile and "Digital: approaching SMILE" or "Digital: approaching duped"

    local reached = navigateInField(field, destination, token, name, nil, nil, nil, obj)
    walkDestination = nil
    if not farmValid(token, name) or not DigitalSettings.Enabled then return end
    local _, root = getHumanoidAndRoot()
    local near = horizontalDistance(root.Position, obj.Position) <= 2.3
    if reached and near and dupedInField(field, obj) then
        digitalStatus.Text = smile and "Digital: SMILE activating" or "Digital: activating"
        local untilTime = os.clock() + DigitalSettings.HoldSeconds
        while os.clock() < untilTime and farmValid(token, name)
            and DigitalSettings.Enabled and dupedInField(field, obj) do
            -- A new Smile preempts ordinary Duped Token activation.
            if not smile and hasSmileDuped(field) then break end
            if horizontalDistance(root.Position, obj.Position) > 2.5 then break end
            walkDestination = nil
            task.wait(0.06)
        end
    end
    handledDuped[obj] = os.clock() + DigitalSettings.TargetRetryDelay
    lastDupedScan = -math.huge
    digitalStatus.Text = smile and "Digital: SMILE done, continue" or "Digital: continue farm"
end

local function runFarm(token)
    while hiveBusy and farmEnabled and token == farmToken and screen.Parent do
        task.wait(0.1)
    end

    local previousField = nil
    local patrolIndex = 1
    while farmEnabled and token == farmToken and screen.Parent do
        local name = selectedField
        if not name then return end
        local field = FlowerZones:FindFirstChild(name)
        if not field then return end
        local _, root = getHumanoidAndRoot()

        -- Fly only when entering/changing field; never between farm targets.
        if previousField ~= name or not onField(field, root) then
            stopWalking()
            if not goToField(field, token, name) then
                if selectedField == name then return end
                continue
            end
            previousField = name
            patrolIndex = 1
            -- Re-entered after leaving this field: request a new placement
            -- only if at least 90 seconds passed since the previous request.
            local sprinkler = CombatSignals.Sprinkler
            if sprinkler.LastField == name and os.clock() - sprinkler.LastAt >= 90 then
                sprinkler.LastField = nil
            end
        end

        if farmValid(token, name) then
            CombatSignals.PlaceSprinkler(field, token, name)
        end

        if farmValid(token, name) then
            local smile, smileDest = chooseDuped(field, root, true)
            if smile and smileDest then
                runDupedToken(field, token, name, smile, smileDest, true)
            elseif PreciseSettings.Enabled and hasPreciseCrosshair(field) then
                runPreciseSession(field, token, name)
            else
            if PreciseSettings.Enabled then
                preciseStatus.Text = "Precise: searching"
            else
                preciseStatus.Text = "Precise: off"
            end
            local duped, dupedDestination, isSmile = chooseDuped(field, root, false)
            if duped and dupedDestination then
                runDupedToken(field, token, name, duped, dupedDestination, isSmile)
            else
            if DigitalSettings.Enabled then
                digitalStatus.Text = "Digital: scanning (smile first)"
            else
                digitalStatus.Text = "Digital: off"
            end
            local flame, flameDestination = nil, nil
            if FlameHeatSettings.Enabled then
                flame, flameDestination = nearestFlameForHeat(field, root)
            end
            if flame and flameDestination then
                -- Book the visit BEFORE walking so the same flame cannot be
                -- selected repeatedly (even if it expires while approaching).
                visitedHeatFlames[flame] = true
                nextHeatVisitAt = os.clock() + FlameHeatSettings.GlobalCooldown
                lastHeatScanAt = -math.huge
                heatStatus.Text = "Heat: walking to " .. flame.Name
                local reached = navigateInField(field, flameDestination, token, name, nil, flame)
                if reached and farmValid(token, name) and FlameHeatSettings.Enabled
                    and liveFlame(field, flame) then
                    -- Keep the stop short. Do NOT wait for the flame to disappear.
                    -- This only pauses walking; Facing Lock remains independent.
                    walkDestination = nil
                    heatStatus.Text = "Heat: brief touch"
                    local startedStanding = os.clock()
                    local untilTime = startedStanding + FlameHeatSettings.StandSeconds
                    while os.clock() < untilTime
                        and farmValid(token, name) and FlameHeatSettings.Enabled
                        and liveFlame(field, flame)
                        and not hasPreciseCrosshair(field)
                        and horizontalDistance(root.Position, flame.Position) <= 4.4 do
                        -- Allow a minimum brief contact, then yield to tokens.
                        -- Avoid rescanning thousands of collectible parts every frame.
                        if os.clock() - startedStanding >= 0.22 then
                            local tokenPart = nearestCollectible(field, root)
                            if tokenPart then break end
                        end
                        task.wait(0.09)
                    end
                end
                -- Cool down AFTER visiting too, so the next iterations farm
                -- tokens instead of chaining to another flame right away.
                nextHeatVisitAt = os.clock() + FlameHeatSettings.GlobalCooldown
                cachedHeatFlame, cachedHeatDestination = nil, nil
                lastHeatScanAt = -math.huge
                heatStatus.Text = FlameHeatSettings.Enabled and "Heat: collecting tokens" or "Heat: off"
            else
                if FlameHeatSettings.Enabled then
                    heatStatus.Text = os.clock() < nextHeatVisitAt
                        and "Heat: token priority" or "Heat: waiting for flame"
                else
                    heatStatus.Text = "Heat: off"
                end
                local tokenPart, tokenPosition = nearestCollectible(field, root)
                if tokenPart and tokenPosition then
                    -- Lock onto one token until reached/lost/blocked.
                    local reached = navigateInField(field, tokenPosition, token, name, tokenPart)
                    collectibleCooldown[tokenPart] = os.clock() + (reached and 1.5 or 4)
                else
                    -- Follow a stable sweeping lane when nothing can be collected.
                    local destination = patrolPoint(field, patrolIndex)
                    patrolIndex = patrolIndex % #PATROL_POINTS + 1
                    if destination then
                        navigateInField(field, destination, token, name)
                    else
                        task.wait(0.15)
                    end
                end
            end
            end -- ordinary Duped Token branch
            end -- Precise Crosshair priority branch
        end
    end
end

farmHit.Activated:Connect(function()
    -- Do not claim movement priority for a button that cannot start Farm.
    if not farmEnabled and not selectedField then return end
    if CombatSignals.CancelPlanter then CombatSignals.CancelPlanter() end
    -- A real click always wins over Auto Combat's autonomous movement.
    if CombatSignals.FarmClicked then
        CombatSignals.FarmClicked(not farmEnabled)
    end
    if farmEnabled then
        farmEnabled = false
        farmToken += 1
        preciseProgress = nil
        if currentFarmTravelTween then
            currentFarmTravelTween:Cancel()
            currentFarmTravelTween = nil
        end
        stopWalking()
        paintFarm(false)
        heatStatus.Text = FlameHeatSettings.Enabled and "Heat: waiting for farm" or "Heat: off"
        preciseStatus.Text = PreciseSettings.Enabled and "Precise: waiting for Farm" or "Precise: off"
        digitalStatus.Text = DigitalSettings.Enabled and "Digital: waiting for Farm" or "Digital: off"
        return
    end
    if not selectedField then return end
    farmEnabled = true
    farmToken += 1
    preciseProgress = nil
    -- Each new manual Farm session has its own sprinkler placement.
    CombatSignals.Sprinkler.LastField = nil
    CombatSignals.Sprinkler.RetryAt = 0
    local token = farmToken
    paintFarm(true)
    task.spawn(function()
        local ok, err = pcall(runFarm, token)
        if not ok then warn("[BSS Farm]", err) end
        if token == farmToken then
            farmEnabled = false
            paintFarm(false)
            stopWalking()
        end
    end)
end)


-- COMBAT PAGE: MonsterSpawners registry, selection list and respawn awareness.
-- v8.2: Quest combat selection is independent of manual Auto Combat checkboxes.
-- Scoped in a function to avoid Luau's 200-register limit in the outer chunk.
local CombatController = {}
do
    local function initializeCombat()
        local page = pages.Combat
        local spawnerFolder = workspace:FindFirstChild("MonsterSpawners")
        local state = {
            Enabled = false, Selected = {}, RunId = 0, Busy = false,
            CurrentTween = nil, RetryAt = {}, LastResult = "Select monsters to hunt.",
            LastRewardText = "Reward alerts: none yet",
            CombatMaxSeconds = 70, QuestPriority = false,
            ManualFarm = false, StumpStoppedByUser = false,
            CombatFarmToken = nil, Hover = nil, HoverAttachment = nil,
        }
        local rows = {}
        local dark = Color3.fromRGB(19, 19, 25)
        local purple = Color3.fromRGB(151, 91, 255)
        local gray = Color3.fromRGB(177, 183, 196)
        local function makeLabel(parent, text, size, position, fontSize)
            return ui("TextLabel", {
                Size = size, Position = position, BackgroundTransparency = 1,
                Text = text, TextColor3 = white, Font = Enum.Font.Gotham,
                TextSize = fontSize or 13, TextXAlignment = Enum.TextXAlignment.Left,
                TextWrapped = true,
            }, parent)
        end
        local function makeButton(parent, text, size, position)
            local button = ui("TextButton", {
                Size = size, Position = position, BackgroundColor3 = dark,
                BorderSizePixel = 1, BorderColor3 = purple, TextColor3 = white,
                Text = text, TextSize = 12, Font = Enum.Font.GothamBold,
            }, parent)
            ui("UICorner", {CornerRadius = UDim.new(0, 5)}, button)
            return button
        end
        makeLabel(page, "MONSTER COMBAT", UDim2.fromOffset(242, 28), UDim2.fromOffset(12, 8), 19).Font = Enum.Font.GothamBold
        local masterButton = makeButton(page, "AUTO COMBAT: OFF", UDim2.fromOffset(206, 28), UDim2.fromOffset(333, 8))
        local selectAll = makeButton(page, "Select regular", UDim2.fromOffset(157, 25), UDim2.fromOffset(12, 42))
        local clearButton = makeButton(page, "Clear selection", UDim2.fromOffset(156, 25), UDim2.fromOffset(178, 42))
        local explanation = makeLabel(page,
            "Live CD reads Attachment/TimerGui/TimerLabel. Cooldown = base duration.",
            UDim2.new(1, -24, 0, 31), UDim2.fromOffset(12, 72), 12)
        explanation.TextColor3 = gray
        local scroll = ui("ScrollingFrame", {
            Name = "MonsterListbox", Size = UDim2.new(1, -24, 0, 215),
            Position = UDim2.fromOffset(12, 104), BackgroundColor3 = dark,
            BorderSizePixel = 0, ScrollBarThickness = 6,
            AutomaticCanvasSize = Enum.AutomaticSize.Y,
            CanvasSize = UDim2.fromOffset(0, 0),
        }, page)
        ui("UIListLayout", {
            SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 3)
        }, scroll)
        ui("UIPadding", {
            PaddingTop = UDim.new(0, 4), PaddingBottom = UDim.new(0, 4),
            PaddingLeft = UDim.new(0, 4), PaddingRight = UDim.new(0, 10),
        }, scroll)
        local status = makeLabel(page, "Scanning MonsterSpawners...",
            UDim2.new(1, -24, 0, 50), UDim2.fromOffset(12, 325), 10)
        status.TextColor3 = gray
        status.TextYAlignment = Enum.TextYAlignment.Top
        local function getSpawners()
            if not spawnerFolder or not spawnerFolder.Parent then
                spawnerFolder = workspace:FindFirstChild("MonsterSpawners")
            end
            local result = {}
            if spawnerFolder then
                for _, obj in ipairs(spawnerFolder:GetChildren()) do
                    if obj:FindFirstChild("Territory") or obj:FindFirstChild("MonsterType") then
                        table.insert(result, obj)
                    end
                end
                table.sort(result, function(a, b) return a.Name:lower() < b.Name:lower() end)
            end
            return result
        end
        local function windyTarget()
            local monsters = workspace:FindFirstChild("Monsters")
            if monsters then
                for _, obj in ipairs(monsters:GetChildren()) do
                    if obj.Name:lower():find("windy", 1, true) then return obj end
                end
            end
            local npcBees = workspace:FindFirstChild("NPCBees")
            return npcBees and npcBees:FindFirstChild("Windy") or nil
        end
        local function windyPosition(target)
            if not target then return nil end
            if target:IsA("BasePart") then return target.Position end
            if target:IsA("Model") then
                local part = target.PrimaryPart or target:FindFirstChildWhichIsA("BasePart", true)
                return part and part.Position or nil
            end
            local part = target:FindFirstChildWhichIsA("BasePart",true)
            return part and part.Position or nil
        end
        local function valueOf(spawner, name)
            local child = spawner and spawner:FindFirstChild(name)
            if child and child:IsA("ValueBase") then
                return child.Value
            end
            return nil
        end
        -- Live respawn clock discovered in Dex:
        -- MonsterSpawners > Spider Cave > Attachment > TimerGui > TimerLabel
        -- e.g. Text = "Spider: 13:19". The separate Cooldown IntValue is
        -- the full respawn duration, NOT the time remaining.
        local function getTimer(spawner)
            if not spawner then return nil end
            local attachment = spawner:FindFirstChild("Attachment")
            local timerGui = attachment and attachment:FindFirstChild("TimerGui")
            local timer = timerGui and timerGui:FindFirstChild("TimerLabel")
            if not timer then timer = spawner:FindFirstChild("TimerLabel", true) end
            if timer and timer:IsA("TextLabel") then return timer end
            return nil
        end
        local function countdownSeconds(text)
            local raw = tostring(text or "")
            -- Match a time at the END of text so the colon in "Spider: ..."
            -- is harmless. Supports H:MM:SS and MM:SS.
            local hours, minutes, seconds = raw:match("(%d+):(%d+):(%d+)%s*$")
            if hours then
                return tonumber(hours) * 3600 + tonumber(minutes) * 60 + tonumber(seconds)
            end
            minutes, seconds = raw:match("(%d+):(%d+)%s*$")
            if minutes then
                return tonumber(minutes) * 60 + tonumber(seconds)
            end
            return nil
        end
        local function liveTimer(spawner)
            local timer = getTimer(spawner)
            if not timer then return nil, nil, false end
            local visible = timer.Visible
            local billboard = timer:FindFirstAncestorWhichIsA("BillboardGui")
            if billboard and not billboard.Enabled then visible = false end
            return timer, countdownSeconds(timer.Text), visible
        end
        local function cooldownState(spawner)
            local timer, remaining, visible = liveTimer(spawner)
            -- The live game countdown always takes priority over local retry guards.
            if visible and remaining ~= nil then
                if remaining > 0 then
                    return false, string.format("Live CD %d:%02d",
                        math.floor(remaining / 60), remaining % 60)
                end
                -- The timer explicitly reached zero: don't keep waiting for
                -- a stale local cooldown left by a previous unsuccessful attempt.
                state.RetryAt[spawner] = nil
                return true, "Live timer 0:00 (ready)"
            end
            if visible and timer and timer.Text ~= "" then
                local label = timer.Text:lower()
                if label:find("ready", 1, true) or label:find("available", 1, true) then
                    state.RetryAt[spawner] = nil
                    return true, "Ready"
                end
                -- Don't blindly treat unrecognized timer formats as a spawn.
                return false, "Timer: " .. timer.Text
            end
            local retryTime = state.RetryAt[spawner] or 0
            if os.clock() < retryTime then
                return false, string.format("Retry in %.1fs", retryTime - os.clock())
            end
            return true, timer and "Ready (timer hidden)" or "No active timer"
        end
        local function territoryPart(spawner)
            local target = valueOf(spawner, "Territory")
            if typeof(target) == "Instance" then
                if target:IsA("BasePart") then return target end
                if target:IsA("Model") then return target.PrimaryPart or target:FindFirstChildWhichIsA("BasePart", true) end
            end
            if spawner:IsA("BasePart") then return spawner end
            if spawner:IsA("Model") then return spawner.PrimaryPart or spawner:FindFirstChildWhichIsA("BasePart", true) end
            return nil
        end
        local function typeOf(spawner)
            local val = valueOf(spawner, "MonsterType")
            return val ~= nil and tostring(val) or spawner.Name
        end
        local function mobCategory(raw)
            local v = tostring(raw or ""):lower():gsub("[%s_%-]", "")
            if v:find("rhino", 1, true) then return "rhino"
            elseif v:find("ladybug", 1, true) then return "ladybug"
            elseif v:find("mantis", 1, true) or v:find("mantises", 1, true) then return "mantis"
            elseif v:find("scorpion", 1, true) then return "scorpion"
            elseif v:find("spider", 1, true) then return "spider"
            elseif v:find("werewolf", 1, true) then return "werewolf"
            elseif v:find("cavemonster", 1, true) then return "cavemonster"
            elseif v:find("kingbeetle", 1, true) then return "kingbeetle"
            elseif v:find("coconutcrab", 1, true) then return "coconutcrab"
            elseif v:find("tunnelbear", 1, true) then return "tunnelbear"
            elseif v:find("stumpsnail", 1, true) then return "stumpsnail"
            elseif v:find("commando", 1, true) then return "commando"
            end
            return v
        end
        local function mobIcon(raw)
            local cat = mobCategory(raw)
            if cat == "ladybug" then return "🐞"
            elseif cat == "rhino" then return "🪲"
            elseif cat == "mantis" then return "🦗"
            elseif cat == "scorpion" then return "🦂"
            elseif cat == "spider" then return "🕷️"
            elseif cat == "werewolf" then return "🐺"
            elseif cat == "cavemonster" then return "👹"
            elseif cat == "kingbeetle" then return "👑"
            elseif cat == "coconutcrab" then return "🦀"
            elseif cat == "tunnelbear" then return "🐻"
            elseif cat == "stumpsnail" then return "🐌"
            elseif cat == "commando" then return "🐥"
            end
            return "⚔️"
        end
        local function questCategory(text)
            local s = tostring(text or ""):lower()
            if not (s:find("defeat", 1, true) or s:find("kill", 1, true)
                or s:find("slay", 1, true) or s:find("vanquish", 1, true)) then
                return nil
            end
            if s:find("rhino beetle", 1, true) or s:find("rhino beetles", 1, true)
                or s:find("rhinobeetle", 1, true) then return "rhino"
            elseif s:find("ladybug", 1, true) then return "ladybug"
            elseif s:find("mantis", 1, true) or s:find("mantises", 1, true) then return "mantis"
            elseif s:find("scorpion", 1, true) then return "scorpion"
            elseif s:find("spider", 1, true) then return "spider"
            elseif s:find("werewolf", 1, true) or s:find("werewolves", 1, true) then return "werewolf"
            elseif s:find("king beetle", 1, true) or s:find("kingbeetle", 1, true) then return "kingbeetle"
            elseif s:find("coconut crab", 1, true) or s:find("coconutcrab", 1, true) then return "coconutcrab"
            elseif s:find("tunnel bear", 1, true) or s:find("tunnelbear", 1, true) then return "tunnelbear"
            elseif s:find("stump snail", 1, true) or s:find("stumpsnail", 1, true) then return "stumpsnail"
            elseif s:find("commando chick", 1, true) or s:find("commandochick", 1, true) then return "commando"
            end
            return nil
        end
        local function refreshList()
            for _, row in pairs(rows) do row.Button:Destroy() end
            table.clear(rows)
            for order, spawner in ipairs(getSpawners()) do
                local row = makeButton(scroll, "", UDim2.new(1, -6, 0, 42), UDim2.fromOffset(0, 0))
                row.Name = "Spawn_" .. spawner.Name
                row.LayoutOrder = order
                local icon = makeLabel(row, "", UDim2.fromOffset(7, 3), UDim2.fromOffset(28, 28), 22)
                icon.TextXAlignment = Enum.TextXAlignment.Center
                icon.TextYAlignment = Enum.TextYAlignment.Center
                local label = makeLabel(row, "", UDim2.new(1, -44, 1, -4), UDim2.fromOffset(38, 2), 12)
                local function update()
                    local checked = state.Selected[spawner.Name] == true
                    local level = valueOf(spawner, "MonsterLevel")
                    local cooldown = tonumber(valueOf(spawner, "Cooldown"))
                    local available, live = cooldownState(spawner)
                    icon.Text = mobIcon(typeOf(spawner))
                    icon.TextColor3 = checked and Color3.fromRGB(122, 255, 162) or white
                    label.TextColor3 = checked and Color3.fromRGB(122, 255, 162) or white
                    label.Text = string.format("[%s] %s  |  %s Lv%s\nRespawn %ss   |   %s",
                        checked and "x" or " ", spawner.Name, typeOf(spawner),
                        tostring(level or "?"), tostring(cooldown or "?"), live)
                end
                row.Activated:Connect(function()
                    state.Selected[spawner.Name] = not state.Selected[spawner.Name]
                    update()
                end)
                rows[spawner] = {Button = row, Update = update}
                update()
            end
            local windy = windyTarget()
            if windy then
                local row = makeButton(scroll, "", UDim2.new(1,-6,0,42), UDim2.fromOffset(0,0))
                row.Name = "WildWindyBee"
                row.LayoutOrder = 999
                local label = makeLabel(row,"",UDim2.new(1,-12,1,-3),
                    UDim2.fromOffset(7,2),12)
                local function updateWindy()
                    local checked = state.Selected["__WindyBee"] == true
                    local target = windyTarget()
                    label.Text = (checked and "[x]" or "[ ]")
                        .. " 💨 Windy Bee | NPCBees.Windy\n"
                        .. (windyPosition(target) and "Detected (state unverified)" or "Not active")
                    label.TextColor3 = checked and Color3.fromRGB(122,255,162) or white
                end
                row.Activated:Connect(function()
                    state.Selected["__WindyBee"] = not state.Selected["__WindyBee"]
                    updateWindy()
                end)
                rows[windy] = {Button=row,Update=updateWindy}
                updateWindy()
            end
            if not spawnerFolder then
                state.LastResult = "Workspace.MonsterSpawners missing."
            end
        end
        local function pauseFarm()
            -- Used by Quest-owned fights only. Autonomous Combat never forcibly
            -- disables a manually enabled Farm.
            local wasFarming = farmEnabled
            if farmEnabled then
                farmEnabled = false
                farmToken += 1
                preciseProgress = nil
                if currentFarmTravelTween then
                    currentFarmTravelTween:Cancel()
                    currentFarmTravelTween = nil
                end
                stopWalking()
                paintFarm(false)
            end
            return wasFarming
        end
        local function restoreFarm(wasFarming)
            if not wasFarming or farmEnabled or not selectedField or not screen.Parent then return end
            farmEnabled = true
            farmToken += 1
            local token = farmToken
            paintFarm(true)
            task.spawn(function()
                local ok, err = pcall(runFarm, token)
                if not ok then warn("[BSS Combat farm restore]", err) end
                if farmToken == token then
                    farmEnabled = false
                    paintFarm(false)
                    stopWalking()
                end
            end)
        end
        local function cancelHover()
            if state.Hover then
                state.Hover:Cancel()
                state.Hover = nil
            end
            state.HoverAttachment = nil
        end
        local function claimStumpFarm()
            local field = FlowerZones:FindFirstChild("Stump Field")
            if not field then return nil, nil, "Stump Field unavailable" end
            if farmEnabled then return nil, nil, "Farm already controlled elsewhere" end
            local previousField = selectedField
            selectedField = field.Name
            fieldButton.Text = fieldIconName(field.Name) .. " " .. field.Name
            farmEnabled = true
            farmToken += 1
            preciseProgress = nil
            local token = farmToken
            state.CombatFarmToken = token
            paintFarm(true)
            task.spawn(function()
                local ok, err = pcall(runFarm, token)
                if not ok then warn("[BSS Stump farm]", err) end
                if farmToken == token then
                    farmEnabled = false
                    farmToken += 1
                    paintFarm(false)
                    stopWalking()
                end
            end)
            return token, previousField
        end
        local function releaseStumpFarm(token, previousField)
            -- Never disable a different Farm session started by a real UI click.
            if not token or state.CombatFarmToken ~= token then return end
            state.CombatFarmToken = nil
            if farmToken ~= token then
                -- If the farm stopped itself, return the old field selection.
                if not farmEnabled and selectedField == "Stump Field" and previousField then
                    selectedField = previousField
                    fieldButton.Text = fieldIconName(previousField) .. " " .. previousField
                end
                return
            end
            farmEnabled = false
            farmToken += 1
            preciseProgress = nil
            if currentFarmTravelTween then
                currentFarmTravelTween:Cancel()
                currentFarmTravelTween = nil
            end
            stopWalking()
            paintFarm(false)
            if selectedField == "Stump Field" and previousField and previousField ~= "Stump Field" then
                selectedField = previousField
                fieldButton.Text = fieldIconName(previousField) .. " " .. previousField
            end
        end
        function CombatSignals.FarmClicked(willEnable)
            if not willEnable and state.CombatFarmToken == farmToken then
                -- The player turned OFF the Stump Farm intentionally.
                state.StumpStoppedByUser = true
                state.CombatFarmToken = nil
            end
            state.ManualFarm = willEnable
            if willEnable and CombatSignals.AntCancel then CombatSignals.AntCancel() end
            if willEnable and CombatSignals.ToyCancel then CombatSignals.ToyCancel() end
            if willEnable then
                if state.CurrentTween then state.CurrentTween:Cancel() end
                cancelHover()
            end
        end
        function CombatSignals.FieldSelected()
            -- Manual field selection while farming must not be overwritten
            -- by an ongoing automatic Stump session.
            if not farmEnabled then return end
            state.ManualFarm = true
            if CombatSignals.AntCancel then CombatSignals.AntCancel() end
            if CombatSignals.ToyCancel then CombatSignals.ToyCancel() end
            state.CombatFarmToken = nil
            if state.CurrentTween then state.CurrentTween:Cancel() end
            cancelHover()
        end
        local function movePath(root, points, keepGoing)
            return SmoothFlight.Path(root, points, keepGoing, TweenSpeed,
                function(handle, previous)
                    if previous then
                        if state.CurrentTween == previous then state.CurrentTween = nil end
                    else
                        state.CurrentTween = handle
                    end
                end)
        end
        local function moveLeg(root, destination, keepGoing)
            return movePath(root, {destination}, keepGoing)
        end
        -- Ordinary mobs: approach to attack range, never directly onto the
        -- MonsterSpawner center. Retreat if a moving monster gets too close.
        local function observedMobPosition(spawner)
            local monsters = workspace:FindFirstChild("Monsters")
            local territory = territoryPart(spawner)
            if not monsters or not territory then return nil end
            local category = mobCategory(typeOf(spawner))
            local best, nearest = nil, math.huge
            for _, mob in ipairs(monsters:GetChildren()) do
                if mobCategory(mob.Name) == category then
                    local pos = windyPosition(mob)
                    local dist = pos and horizontalDistance(pos,territory.Position)
                    if dist and dist < nearest and dist < 90 then
                        best,nearest = pos,dist
                    end
                end
            end
            return best
        end
        local function standoffPoint(enemy, from, radius)
            local away = Vector3.new(from.X-enemy.X,0,from.Z-enemy.Z)
            local dir = away.Magnitude > 0.5 and away.Unit or Vector3.new(1,0,0)
            return groundPosition(enemy+dir*radius+Vector3.new(0,3,0))
        end
        local function moveToSpawn(spawner, keepGoing)
            local territory = territoryPart(spawner)
            if not territory then return false end
            local humanoid, root = getHumanoidAndRoot()
            if not root or humanoid.Health <= 0 then return false end
            local center = territory.Position
            local livePosition = observedMobPosition(spawner)
            local ground = livePosition
                and standoffPoint(livePosition,root.Position,15)
                or standoffPoint(center,root.Position,12)
            local points = {}
            if (root.Position - ground).Magnitude > 28 then
                local altitude = math.max(root.Position.Y, ground.Y) + 18
                table.insert(points, Vector3.new(root.Position.X, altitude, root.Position.Z))
                table.insert(points, Vector3.new(ground.X, altitude, ground.Z))
            end
            table.insert(points, ground)
            return movePath(root, points, keepGoing)
        end
        local function isCoconut(spawner)
            return mobCategory(typeOf(spawner)) == "coconutcrab"
                or mobCategory(spawner.Name) == "coconutcrab"
        end
        local function isStump(spawner)
            return mobCategory(typeOf(spawner)) == "stumpsnail"
                or mobCategory(spawner.Name) == "stumpsnail"
        end
        -- Loot after a verified kill. One descent, then Farm-style walking.
        -- Shared post-kill barrier for both Quest fights and Auto Combat.
        -- Hold the movement lock until reward drops were observed and collected,
        -- or the finite loot timeout expires. Never let another automatic job
        -- steal control while the fight's reward tokens are still on the ground.
        local function collectMobLoot(spawner, before, keepGoing)
            local area = territoryPart(spawner)
            local _, root = getHumanoidAndRoot()
            if not area and not root then return 0 end
            local coconut = isCoconut(spawner)
            local snail = isStump(spawner)
            local targetField = coconut and FlowerZones:FindFirstChild("Coconut Field") or nil
            local cf, size = nil, nil
            if targetField then cf, size = bounds(targetField) end
            local center = (cf and cf.Position)
                or (area and area.Position)
                or (root and root.Position)
            local zoneSize = size or (area and area.Size) or Vector3.new(40, 4, 40)
            local radius = coconut and math.clamp(math.max(zoneSize.X, zoneSize.Z) * .82, 65, 120)
                or math.clamp(math.max(zoneSize.X, zoneSize.Z) * .80 + 20, 40, 75)
            local centers = {center}
            if root and horizontalDistance(root.Position, center) <= 135 then
                table.insert(centers, root.Position)
            end
            local function allowed()
                return keepGoing() and screen.Parent ~= nil and not state.ManualFarm
                    and not farmEnabled and not CombatSignals.AntBusy
                    and not CombatSignals.PlanterBusy and not CombatSignals.ToyBusy
            end
            if not allowed() then return 0 end
            -- Stump Snail historically awards directly to the inventory, unlike
            -- ordinary ring-of-token mobs. Briefly check for exceptional tokens.
            if snail then
                state.LastResult = "Stump Snail: checking reward delivery"
                local deadline = os.clock() + 3
                while allowed() and os.clock() < deadline do task.wait(0.15) end
                return 0
            end
            state.LastResult = "Waiting for reward drops: " .. spawner.Name
            -- The character may still be hovering high over the Coconut Crab.
            -- Return to ground BEFORE starting the collection walk.
            if root and root.Position.Y > center.Y + 11 and allowed() then
                local landing = targetField and fieldCenter(targetField)
                    or groundPosition(Vector3.new(root.Position.X, center.Y + 3, root.Position.Z))
                if landing then SmoothFlight.Path(root, {landing}, allowed, TweenSpeed) end
            end
            if not allowed() then return 0 end
            local total = LootTools.CollectNew({
                Center = center, Centers = centers, Radius = radius,
                Duration = coconut and 45 or 32, DropGrace = coconut and 3.8 or 2.8,
                QuietPeriod = 1.4, Before = before, Source = spawner.Name,
                -- Do not restrict combat drops to the flower-zone rectangle;
                -- boss rewards and normal mob rings can spawn at the edge.
                Allowed = allowed,
                Report = function(msg) state.LastResult = msg end
            })
            state.LastResult = spawner.Name .. ": reward sweep complete (" .. total .. " confirmed)"
            return total
        end

        local function findLiveCrab()
            -- Actual monster, not its spawn data. Supports both Model and MeshPart.
            local monsters = workspace:FindFirstChild("Monsters")
            if not monsters then return nil end
            local partCandidate = nil
            for _, obj in ipairs(monsters:GetDescendants()) do
                local name = obj.Name:lower():gsub("[%s_%-]", "")
                if name:find("coconutcrab", 1, true) then
                    if obj:IsA("Model") then return obj end
                    if obj:IsA("BasePart") then partCandidate = obj end
                end
            end
            return partCandidate
        end
        local function coconutHoverPosition(spawner)
            local coconutField = FlowerZones:FindFirstChild("Coconut Field")
            if not coconutField then return nil end
            local cf, size = bounds(coconutField)
            if not cf then return nil end
            local fieldTop = cf:PointToWorldSpace(Vector3.new(0, size.Y / 2, 0))
            local crab = findLiveCrab()
            -- v7.9: hold 42 studs above the top of Coconut Field.
            local x, z, y = fieldTop.X, fieldTop.Z, fieldTop.Y + 42
            if crab then
                local crabCF, crabSize
                if crab:IsA("Model") then
                    crabCF, crabSize = crab:GetBoundingBox()
                else
                    crabCF, crabSize = crab.CFrame, crab.Size
                end
                x, z = crabCF.Position.X, crabCF.Position.Z
                y = math.max(y, crabCF.Position.Y + crabSize.Y / 2 + 9)
            end
            -- Fixed hover height; watch for boss disengagement at this altitude.
            y = fieldTop.Y + 42
            local safePoint = projectInside(coconutField, Vector3.new(x, y, z), 3)
            return safePoint
        end
        local function fightCoconut(spawner, keepGoing)
            local hum, root = getHumanoidAndRoot()
            local target = coconutHoverPosition(spawner)
            if not target then
                state.LastResult = "Coconut Field is missing"
                return false
            end
            state.LastResult = "Flying higher above Coconut Crab..."
            -- Travel + hover use the SAME AlignPosition. There is no physical
            -- handoff between three tweens and a separate hover constraint.
            local flight = SmoothFlight.Begin(root, TweenSpeed)
            if not flight then return false end
            state.CurrentTween = flight
            state.Hover = flight
            local high = Vector3.new(root.Position.X,
                math.max(root.Position.Y, target.Y + 2), root.Position.Z)
            if (high - root.Position).Magnitude > 2 and
                not SmoothFlight.Move(flight, high, keepGoing, 2.5) then
                return false
            end
            if not SmoothFlight.Move(flight, target, keepGoing, 3) then return false end
            if state.CurrentTween == flight then state.CurrentTween = nil end
            if not keepGoing() then return false end
            -- Slower target interpolation avoids hard corrections as the crab moves.
            flight.Constraint.MaxVelocity = math.min(TweenSpeed, 60)
            flight.Constraint.Responsiveness = 13
            state.LastResult = "Holding high above Coconut Crab; tracking cooldown"
            local followPosition = target
            while keepGoing() and root.Parent and hum.Health > 0 and not flight.Closed do
                local _, remaining, displayed = liveTimer(spawner)
                if displayed and remaining and remaining > 0 then
                    state.LastResult = "Coconut Crab defeated; respawn countdown started"
                    return true
                end
                local nextPoint = coconutHoverPosition(spawner)
                if not nextPoint then break end
                followPosition = followPosition:Lerp(nextPoint, 0.35)
                flight.Constraint.Position = followPosition
                task.wait(0.14)
            end
            if hum.Health <= 0 then state.LastResult = "Coconut Crab: character died" end
            return false
        end
        local function stumpThreatPosition(spawner)
            local monsters = workspace:FindFirstChild("Monsters")
            local territory = territoryPart(spawner)
            if not monsters then return nil,nil end
            local best, nearest, bestRadius = nil, math.huge, 19
            for _,mob in ipairs(monsters:GetChildren()) do
                if mobCategory(mob.Name) == "stumpsnail" then
                    local pos = windyPosition(mob)
                    local dist = pos and territory
                        and horizontalDistance(pos,territory.Position) or 0
                    if pos and dist < nearest and dist < 130 then
                        nearest = dist
                        local head = mob:FindFirstChild("Head",true)
                            or mob:FindFirstChild("SnailHead",true)
                        if head and head:IsA("BasePart") then
                            best,bestRadius = head.Position,14
                        else
                            best,bestRadius = pos,19
                        end
                    end
                end
            end
            return best,bestRadius
        end
        local function fightStump(spawner, keepGoing)
            local token, previousField, errorMessage = claimStumpFarm()
            if not token then
                state.LastResult = errorMessage or "Unable to start Stump Farm"
                return false
            end
            local field = FlowerZones:FindFirstChild("Stump Field")
            local avoidance = {
                Field = "Stump Field", Token = token, Radius = 19,
                Position = nil, Center = field and fieldCenter(field),
            }
            CombatSignals.AvoidMob = avoidance
            state.LastResult = "Stump Snail: safe farming, keep away from snail"
            local success = false
            while keepGoing() and farmEnabled and farmToken == token
                and selectedField == "Stump Field" do
                avoidance.Position, avoidance.Radius = stumpThreatPosition(spawner)
                if not avoidance.Position then avoidance.Radius = 19 end
                local _, remaining, displayed = liveTimer(spawner)
                if displayed and remaining and remaining > 0 then
                    success = true
                    state.LastResult = "Stump Snail defeated; stopping combat-owned Farm"
                    break
                end
                local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
                if not hum or hum.Health <= 0 then
                    state.LastResult = "Stump Snail: character died"
                    break
                end
                -- Stump Snail takes longer than the 70-second normal mob limit.
                -- No movement from Combat: runFarm handles all field movement.
                task.wait(0.25)
            end
            -- Clear the avoidance overlay before handing movement back.
            if CombatSignals.AvoidMob == avoidance then CombatSignals.AvoidMob = nil end
            releaseStumpFarm(token, previousField)
            return success
        end
        -- Some monsters do not expose a readable live countdown. As a secondary
        -- confirmation, watch the actual monster model inside Workspace.Monsters.
        local function findLiveMob(spawner)
            local monsters = workspace:FindFirstChild("Monsters")
            local area = territoryPart(spawner)
            if not monsters or not area then return nil end
            local cat = mobCategory(typeOf(spawner))
            local best, bestDist = nil, math.huge
            for _, obj in ipairs(monsters:GetChildren()) do
                if mobCategory(obj.Name) == cat then
                    local pos = windyPosition(obj)
                    if pos then
                        local dist = horizontalDistance(pos, area.Position)
                        if dist < bestDist and dist <= 85 then
                            bestDist, best = dist, obj
                        end
                    end
                end
            end
            return best
        end
        local function monsterDefeated(obj)
            if not obj then return false end
            if not obj.Parent then return true end
            local hum = obj:FindFirstChildOfClass("Humanoid")
            if hum and hum.Health <= 0 then return true end
            local hp = obj:FindFirstChild("Health", true)
            return hp ~= nil and hp:IsA("NumberValue") and hp.Value <= 0
        end
        -- A new positive live timer OR actual monster defeat confirms combat.
        local function fight(spawner, keepGoing, restoreAfter)
            if state.Busy or not spawner or not spawner.Parent then
                return false, "Combat busy / spawner missing"
            end
            local available, reason = cooldownState(spawner)
            if not available then return false, reason end
            if not territoryPart(spawner) then
                return false, "No territory for " .. spawner.Name
            end
            -- Independent Auto Combat must never take control from manual Farm.
            if CombatSignals.PlanterBusy then
                return false, "Planter Manager is moving"
            end
            if restoreAfter and (farmEnabled or state.ManualFarm) then
                return false, "Farm has movement priority"
            end
            state.Busy = true
            local rewardAlerts = LootTools.BeginAlertTracker()
            -- Only newly appearing tokens near THIS spawner count as fight loot.
            local lootBaseline = not isStump(spawner) and LootTools.Snapshot() or nil
            -- Quest-owned fights may pause their quest Farm; independent fights do not.
            local wasFarming = not restoreAfter and pauseFarm() or false
            local ok, result = pcall(function()
                if isStump(spawner) then
                    return fightStump(spawner, keepGoing)
                elseif isCoconut(spawner) then
                    return fightCoconut(spawner, keepGoing)
                end
                state.LastResult = "Flying to " .. spawner.Name
                if not moveToSpawn(spawner, keepGoing) then return false end
                state.LastResult = "Fighting " .. spawner.Name .. " (bees attack automatically)"
                local liveMob = findLiveMob(spawner)
                local start = os.clock()
                local _, root = getHumanoidAndRoot()
                local origin = root and root.Position
                while keepGoing() and root and root.Parent
                    and os.clock() - start < state.CombatMaxSeconds do
                    local _, remaining, shown = liveTimer(spawner)
                    if shown and remaining and remaining > 0 then
                        state.LastResult = spawner.Name .. " defeated (respawning)"
                        return true
                    end
                    if monsterDefeated(liveMob) then
                        state.LastResult = spawner.Name .. " defeated (monster despawned)"
                        return true
                    end
                    if not liveMob then liveMob = findLiveMob(spawner) end
                    local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
                    if not humanoid or humanoid.Health <= 0 then
                        state.LastResult = "Character down; stopping Combat"
                        return false
                    end
                    -- No aimless drift into the monster. Reposition only
                    -- when the enemy enters a dangerous contact range.
                    local enemy = liveMob and windyPosition(liveMob)
                    if enemy and horizontalDistance(root.Position, enemy) < 11 then
                        local safe = standoffPoint(enemy,root.Position,17)
                        if safe and keepGoing() then
                            state.LastResult = spawner.Name .. ": dodging contact (17 stud)"
                            moveLeg(root,safe,keepGoing)
                        end
                    else
                        humanoid:Move(Vector3.zero,false)
                    end
                    task.wait(0.18)
                end
                local _, remaining, shown = liveTimer(spawner)
                if shown and remaining and remaining > 0 then return true end
                state.LastResult = "Timed out / combat ended: " .. spawner.Name
                return false
            end)
            cancelHover()
            -- The loot pass must finish before Quest evaluates the next task.
            -- A kill can be visible through new drops before the timer updates.
            local sawNewDrops = false
            if ok and lootBaseline and result ~= true and keepGoing() then
                local area = territoryPart(spawner)
                local _, root = getHumanoidAndRoot()
                local scanUntil = os.clock() + 2.5
                repeat
                    LootTools.Each(function(part)
                        if part.Parent and not lootBaseline[part]
                            and ((area and horizontalDistance(part.Position, area.Position) <= 90)
                                or (root and horizontalDistance(part.Position, root.Position) <= 90)) then
                            sawNewDrops = true
                        end
                    end)
                    if sawNewDrops or not keepGoing() then break end
                    task.wait(0.15)
                until os.clock() >= scanUntil
            end
            if ok and (result == true or sawNewDrops) and keepGoing() then
                CombatSignals.LootBusy = true
                state.LastResult = "Post-kill loot locked: " .. spawner.Name
                local lootOK, lootError = pcall(collectMobLoot, spawner,
                    lootBaseline or {}, keepGoing)
                CombatSignals.LootBusy = false
                if not lootOK then
                    warn("[BSS Combat Loot]", lootError)
                    state.LastResult = "Loot error: " .. tostring(lootError)
                end
            end
            -- Native reward notifications are a stronger attribution signal
            -- than token position. Ignore "from Pine Tree Forest" and other
            -- unrelated field rewards when summarizing this monster fight.
            local alertCount,rewardPreview,victoryAlert = rewardAlerts:Summary(typeOf(spawner))
            rewardAlerts:Stop()
            if alertCount > 0 then
                state.LastRewardText = string.format("Reward alerts [%s]: %s%s",
                    typeOf(spawner),rewardPreview,
                    alertCount>5 and (" (+"..(alertCount-5).." more)") or "")
            elseif victoryAlert then
                state.LastRewardText = "Defeated " .. typeOf(spawner)
                    .. " (no source-specific reward alert observed)"
            end
            -- Don't override manual Farm movement when its control was reclaimed.
            if not farmEnabled then
                local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
                if hum then hum:Move(Vector3.zero, false) end
            end
            state.Busy = false
            if not ok then
                warn("[BSS Combat]", result)
                state.LastResult = tostring(result)
            end
            local cd = tonumber(valueOf(spawner, "Cooldown")) or 30
            state.RetryAt[spawner] = os.clock()
                + ((ok and result == true) and 2 or (restoreAfter and math.min(cd, 15) or 3))
            if restoreAfter and screen.Parent and not state.QuestPriority then
                restoreFarm(wasFarming)
            end
            return ok and result == true, state.LastResult
        end
        function CombatController.FindForTask(text)
            local wanted = questCategory(text)
            if not wanted then return nil, "Not a supported kill objective" end
            -- Quest kills are NOT gated by state.Selected. That table belongs
            -- exclusively to standalone AUTO COMBAT in the Combat tab.
            local spawners = getSpawners()
            local matched, best, bestDistance = 0, nil, math.huge
            local blocked = nil
            local waiting = nil
            local nearestTime = math.huge
            local char = player.Character
            local root = char and char:FindFirstChild("HumanoidRootPart")
            for _, spawner in ipairs(spawners) do
                if mobCategory(typeOf(spawner)) == wanted
                    or mobCategory(spawner.Name) == wanted then
                    matched += 1
                    local location = territoryPart(spawner)
                    if location then
                        local available, reason = cooldownState(spawner)
                        if available then
                            local dist = root and (root.Position - location.Position).Magnitude or 0
                            if dist < bestDistance then
                                best, bestDistance = spawner, dist
                            end
                        else
                            local min, s = (reason or ""):match("Live CD (%d+):(%d+)")
                            local remaining = min and (tonumber(min) * 60 + tonumber(s)) or math.huge
                            if not waiting or remaining < nearestTime then
                                nearestTime = remaining
                                waiting = spawner.Name .. " | " .. tostring(reason)
                            end
                        end
                    else
                        blocked = spawner.Name .. ": missing territory"
                    end
                end
            end
            if best then return best, "READY: " .. best.Name end
            if matched == 0 then return nil, "No matching spawner for " .. wanted end
            return nil, waiting or blocked or "No ready " .. wanted .. " spawner"
        end
        function CombatController.IsQuestKill(text)
            return questCategory(text) ~= nil
        end
        function CombatController.FightQuest(spawner, keepGoing)
            return fight(spawner, keepGoing, false)
        end
        function CombatController.IsBusy()
            return state.Busy or CombatSignals.AntBusy or CombatSignals.ToyBusy
        end
        function CombatController.CanPlanterRun()
            -- An explicitly enabled Auto Planter may briefly pause/resume Farm.
            -- A manual Farm click cancels the active planter visit instead.
            return not state.Busy and not state.QuestPriority
                and not CombatSignals.AntBusy and not CombatSignals.ToyBusy
        end
        function CombatController.PrioritizeQuest(enabled)
            state.QuestPriority = enabled == true
            if state.QuestPriority and state.CurrentTween then
                state.CurrentTween:Cancel()
            end
        end
        clearButton.Activated:Connect(function()
            table.clear(state.Selected)
            refreshList()
        end)
        selectAll.Activated:Connect(function()
            for _, spawner in ipairs(getSpawners()) do
                local cat = mobCategory(typeOf(spawner))
                if cat == "ladybug" or cat == "rhino" or cat == "mantis"
                    or cat == "spider" or cat == "scorpion" or cat == "werewolf" then
                    state.Selected[spawner.Name] = true
                end
            end
            refreshList()
        end)
        -- Optional wild Windy fight from NPCBees; only runs when ticked.
        -- Do not mark it defeated until the live model disappears or health reaches 0.
        local function fightWindy(keepGoing)
            local target = windyTarget()
            local point = windyPosition(target)
            if not point or state.Busy then return false end
            if os.clock() < (state.RetryAt["__WindyBee"] or 0) then return false end
            state.Busy = true
            local rewardAlerts = LootTools.BeginAlertTracker()
            local before = LootTools.Snapshot()
            local ok, result = pcall(function()
                state.LastResult = "Wild Windy Bee: approaching"
                local _, root = getHumanoidAndRoot()
                if not movePath(root,{point + Vector3.new(0,4,0)},keepGoing) then return false end
                local started = os.clock()
                while keepGoing() and os.clock()-started<100 do
                    target = windyTarget()
                    local here = windyPosition(target)
                    if not target or not here then return true end
                    local hp = target:FindFirstChild("Health",true)
                    if hp and hp:IsA("NumberValue") and hp.Value <= 0 then return true end
                    if horizontalDistance(here,root.Position)>12 then
                        if not movePath(root,{here+Vector3.new(0,4,0)},keepGoing) then break end
                    end
                    task.wait(.25)
                end
                return false
            end)
            if ok and result == true and keepGoing() then
                CombatSignals.LootBusy = true
                local lootOK, lootError = pcall(function()
                    local _, latestRoot = getHumanoidAndRoot()
                    local centers = {point}
                    if latestRoot then table.insert(centers, latestRoot.Position) end
                    if latestRoot and latestRoot.Position.Y > point.Y + 11 then
                        SmoothFlight.Path(latestRoot, {groundPosition(point)}, keepGoing, TweenSpeed)
                    end
                    LootTools.CollectNew({Center=point,Centers=centers,
                        Radius=80,Duration=45,DropGrace=3.8,QuietPeriod=1.4,
                        Before=before,Source="Windy Bee",Allowed=keepGoing,
                        Report=function(msg) state.LastResult=msg end})
                end)
                CombatSignals.LootBusy = false
                if not lootOK then warn("[BSS Windy Loot]", lootError) end
                state.LastResult = "Windy Bee: reward sweep finished"
            elseif not ok then
                warn("[BSS Windy Combat]",result)
            end
            local n,rewardPreview,victory = rewardAlerts:Summary("Windy Bee")
            rewardAlerts:Stop()
            if n > 0 then
                state.LastRewardText = "Reward alerts [Windy Bee]: " .. rewardPreview
                    .. (n>5 and (" (+"..(n-5).." more)") or "")
            elseif victory then
                state.LastRewardText = "Defeated Windy Bee (reward alert not yet observed)"
            end
            state.RetryAt["__WindyBee"] = os.clock()+12
            state.Busy = false
            return ok and result == true
        end
        masterButton.Activated:Connect(function()
            state.Enabled = not state.Enabled
            state.RunId += 1
            state.StumpStoppedByUser = false
            if not state.Enabled then
                cancelHover()
            end
            masterButton.Text = state.Enabled and "AUTO COMBAT: ON" or "AUTO COMBAT: OFF"
            masterButton.BackgroundColor3 = state.Enabled and Color3.fromRGB(35, 96, 67) or dark
            if not state.Enabled and state.CurrentTween then state.CurrentTween:Cancel() end
            if not state.Enabled then return end
            local id = state.RunId
            task.spawn(function()
                while state.Enabled and state.RunId == id and screen.Parent do
                    local didFight = false
                    -- Any running Farm blocks autonomous combat. An internally
                    -- owned Stump Farm runs while state.Busy is true.
                    if not state.Busy and not state.QuestPriority and not farmEnabled
                        and not state.ManualFarm and not CombatSignals.PlanterBusy
                        and not CombatSignals.AntBusy and not CombatSignals.ToyBusy then
                        for _, spawner in ipairs(getSpawners()) do
                            if not state.Enabled or state.RunId ~= id or farmEnabled
                                or CombatSignals.PlanterBusy or CombatSignals.AntBusy
                                or CombatSignals.ToyBusy then break end
                            local available = cooldownState(spawner)
                            if state.Selected[spawner.Name] and available
                                and not (isStump(spawner) and state.StumpStoppedByUser) then
                                didFight = true
                                fight(spawner, function()
                                    return state.Enabled and state.RunId == id
                                        and screen.Parent ~= nil and not state.QuestPriority
                                        and not state.ManualFarm and not CombatSignals.PlanterBusy
                                end, true)
                                break
                            end
                        end
                        if not didFight and state.Selected["__WindyBee"]
                            and not CombatSignals.AntBusy and not CombatSignals.ToyBusy then
                            local windy = windyTarget()
                            if windyPosition(windy) then
                                didFight = true
                                fightWindy(function()
                                    return state.Enabled and state.RunId == id
                                        and screen.Parent ~= nil and not farmEnabled
                                        and not state.ManualFarm and not state.QuestPriority
                                        and not CombatSignals.PlanterBusy
                                        and not CombatSignals.AntBusy and not CombatSignals.ToyBusy
                                end)
                            end
                        end
                    end
                    task.wait(didFight and 0.25 or 1)
                end
            end)
        end)
        task.spawn(function()
            local oldNames = ""
            while screen.Parent do
                if selectedTab == "Combat" then
                    local names = {}
                    for _, spawner in ipairs(getSpawners()) do table.insert(names, spawner.Name) end
                    local signature = table.concat(names, "\0")
                    if signature ~= oldNames then
                        oldNames = signature
                        refreshList()
                    end
                    for spawner, row in pairs(rows) do
                        if spawner.Parent then row.Update() end
                    end
                    local amount = 0
                    for _, on in pairs(state.Selected) do if on then amount += 1 end end
                    local combatStatus = state.Busy and "Combat active"
                        or (state.Enabled and "Auto Combat ON" or "Auto Combat OFF")
                    if state.Enabled and state.ManualFarm and farmEnabled then
                        combatStatus = "Paused: Farm has priority"
                    elseif state.Enabled and state.StumpStoppedByUser then
                        combatStatus = "Stump paused by user; toggle Combat OFF/ON to reset"
                    end
                    status.Text = CombatSignals.AntBusy
                        and ("ANT CHALLENGE | " .. tostring(CombatSignals.AntStatus))
                        or string.format("Selected: %d | %s\n%s\n%s",
                            amount, combatStatus, state.LastResult,
                            state.LastRewardText or "Reward alerts: none yet")
                end
                task.wait(0.6)
            end
        end)
        screen.Destroying:Connect(function()
            state.Enabled = false
            state.RunId += 1
            if state.CurrentTween then state.CurrentTween:Cancel() end
            cancelHover()
            CombatSignals.FarmClicked = nil
            CombatSignals.FieldSelected = nil
        end)
        ConfigManager.Register("Combat", function()
            local chosen = {}
            for name, on in pairs(state.Selected) do
                if on == true then chosen[name] = true end
            end
            return {Selected = chosen}
        end, function(data)
            if type(data.Selected) ~= "table" then return end
            table.clear(state.Selected)
            for name, on in pairs(data.Selected) do
                if type(name) == "string" and on == true then
                    state.Selected[name] = true
                end
            end
            refreshList()
        end)
        refreshList()
    end
    initializeCombat()
end


-- v8.3 shared native-GUI interaction for Toy / Ant automation.
-- No guessed RemoteEvent arguments; send normal key and mouse input.
local NativeInteraction = {}
do
    local function visibleTarget(obj)
        if not obj or not obj:IsA("GuiObject") then return false end
        if obj.AbsoluteSize.X < 3 or obj.AbsoluteSize.Y < 3 then return false end
        local node = obj
        while node do
            if node:IsA("GuiObject") and not node.Visible then return false end
            if node:IsA("ScreenGui") and not node.Enabled then return false end
            node = node.Parent
        end
        return true
    end
    NativeInteraction.Visible = visibleTarget
    function NativeInteraction.PressE()
        return pcall(function()
            VIM:SendKeyEvent(true, Enum.KeyCode.E, false, game)
            task.wait(0.08)
            VIM:SendKeyEvent(false, Enum.KeyCode.E, false, game)
        end)
    end
    function NativeInteraction.Click(obj)
        if not visibleTarget(obj) then return false end
        local point = obj.AbsolutePosition + obj.AbsoluteSize / 2
        local parentScreen = obj:FindFirstAncestorOfClass("ScreenGui")
        if parentScreen and parentScreen.ScreenInsets == Enum.ScreenInsets.CoreUISafeInsets then
            point += GuiService:GetGuiInset()
        end
        local x, y = math.floor(point.X), math.floor(point.Y)
        local previous = window.Visible
        if previous then window.Visible = false end
        task.wait(0.02)
        local ok, err = pcall(function()
            VIM:SendMouseMoveEvent(x, y, game)
            task.wait(0.04)
            VIM:SendMouseButtonEvent(x, y, 0, true, game, 0)
            task.wait(0.06)
            VIM:SendMouseButtonEvent(x, y, 0, false, game, 0)
        end)
        if previous and window.Parent then window.Visible = true end
        if not ok then warn("[BSS v8.3 native click]", err) end
        return ok
    end
end

-- COMBAT: dedicated Ant Challenge controller. It never modifies ordinary
-- Auto Combat checkbox selections, and manual Farm cancels it immediately.
do
    local function initializeAntChallenge()
        local page = pages.Combat
        local busy = false
        local epoch = 0
        local dark = Color3.fromRGB(20, 22, 31)
        local activeButton = ui("TextButton", {
            Name = "AutoAntChallenge", Position = UDim2.fromOffset(346, 42),
            Size = UDim2.fromOffset(196, 25), BackgroundColor3 = dark,
            BorderSizePixel = 1, BorderColor3 = Color3.fromRGB(151, 91, 255),
            Text = "ANT CHALLENGE: OFF", TextColor3 = white,
            Font = Enum.Font.GothamBold, TextSize = 12,
        }, page)
        ui("UICorner", {CornerRadius = UDim.new(0, 5)}, activeButton)
        local function tell(s)
            CombatSignals.AntStatus = s
        end
        local function stopAnt()
            epoch += 1
            busy = false
            CombatSignals.AntBusy = false
            activeButton.Text = "ANT CHALLENGE: OFF"
            activeButton.BackgroundColor3 = dark
            local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
            if hum then hum:Move(Vector3.zero, false) end
        end
        CombatSignals.AntCancel = stopAnt
        local function findToy()
            local toys = workspace:FindFirstChild("Toys")
            return toys and toys:FindFirstChild("Ant Challenge")
        end
        local function nearestPart(root, characterPosition)
            if not root then return nil end
            if root:IsA("BasePart") then return root end
            local part, best = nil, math.huge
            for _, item in ipairs(root:GetDescendants()) do
                if item:IsA("BasePart") then
                    local d = (item.Position - characterPosition).Magnitude
                    if d < best then part, best = item, d end
                end
            end
            return part
        end
        local function insideArena(root, arena)
            if not arena then return false end
            return insideField(arena, root.Position, -2)
        end
        local function nearbyHazards(position)
            local enemies = {}
            local toys=workspace:FindFirstChild("Toys")
            local sources = {
                workspace:FindFirstChild("Monsters"), workspace:FindFirstChild("Ants"),
                workspace:FindFirstChild("Particles"),
                toys and toys:FindFirstChild("Ant Challenge")
            }
            for _, parent in ipairs(sources) do
                if parent then
                    for _, obj in ipairs(parent:GetDescendants()) do
                        local name = obj.Name:lower()
                        local normalized=name:gsub("[%s_%-]", "")
                        local isAnt=normalized:sub(1,3)=="ant"
                            or normalized:find("fireant",1,true)~=nil
                            or normalized:find("giantant",1,true)~=nil
                            or normalized:find("armyant",1,true)~=nil
                            or normalized:find("flyingant",1,true)~=nil
                        if (isAnt or name:find("mower", 1, true)
                            or name:find("lawn", 1, true))
                            and (obj:IsA("Model") or obj:IsA("BasePart")) then
                            local p
                            if obj:IsA("BasePart") then p = obj.Position
                            elseif obj.PrimaryPart then p = obj.PrimaryPart.Position end
                            if p and horizontalDistance(p, position) <= 43 then
                                table.insert(enemies, {
                                    Position = p, Distance = horizontalDistance(p, position),
                                    Mower = name:find("mower", 1, true) ~= nil
                                        or name:find("lawn", 1, true) ~= nil,
                                })
                            end
                        end
                    end
                end
            end
            table.sort(enemies, function(a,b) return a.Distance < b.Distance end)
            return enemies
        end
        local function runAnt(id)
            local arena = FlowerZones:FindFirstChild("Ant Field")
            local toy = findToy()
            if not toy then tell("Missing Workspace.Toys['Ant Challenge']"); return end
            if not arena then tell("Missing FlowerZones['Ant Field']; cannot dodge safely"); return end
            if farmEnabled or CombatSignals.PlanterBusy or CombatController.IsBusy() then
                -- IsBusy includes AntBusy, so check only BEFORE claiming it.
                tell("Stop Farm / finish Combat before starting Ant Challenge")
                return
            end
            CombatSignals.AntBusy = true
            local function allowed()
                return busy and epoch == id and screen.Parent ~= nil and not farmEnabled
            end
            local hum, root = getHumanoidAndRoot()
            local contact = nearestPart(toy, root.Position)
            if not contact then tell("Ant Challenge interaction point missing"); return end
            local point = contact.Position + Vector3.new(0, 3.5, 0)
            tell("Flying to Ant Challenge")
            if not SmoothFlight.Path(root, {point}, allowed, TweenSpeed) then
                tell("Couldn't reach Ant Challenge")
                return
            end
            -- Uses existing E interaction; never consumes passes through remote calls.
            for attempt = 1, 3 do
                if not allowed() then return end
                NativeInteraction.PressE()
                task.wait(0.35)
                -- Only confirm native buttons explicitly mentioning the Ant Challenge.
                for _,gui in ipairs(playerGui:GetDescendants()) do
                    if gui:IsA("TextButton") and NativeInteraction.Visible(gui) then
                        local text=gui.Text:lower()
                        if text:find("start ant",1,true) or text:find("play ant",1,true)
                            or text:find("ant pass",1,true) then
                            NativeInteraction.Click(gui)
                            task.wait(.25)
                            break
                        end
                    end
                end
                if insideArena(root, arena) then break end
            end
            if not insideArena(root, arena) then
                tell("Challenge not confirmed: check Ant Pass / E prompt")
                return
            end
            local cf, size = bounds(arena)
            local started, lastJump, lastClick = os.clock(), 0, 0
            local targetIndex = 1
            tell("Inside Ant Field: pollen / dodge active")
            -- The five-minute challenge is server-owned. Do not force an end.
            while allowed() and hum.Health > 0 and os.clock() - started < 310 do
                if not insideArena(root, arena) then
                    tell("Ant Field exited; stopping")
                    break
                end
                local threats = nearbyHazards(root.Position)
                local wish = nil
                local danger = false
                local nearest = threats[1]
                if nearest and nearest.Distance < (nearest.Mower and 34 or 16) then
                    local away = Vector3.new(root.Position.X - nearest.Position.X, 0,
                        root.Position.Z - nearest.Position.Z)
                    if away.Magnitude > .1 then wish = away.Unit; danger = true end
                end
                if not wish then
                    -- Cross-field patrol collects pollen and opens ant waves.
                    local patrol = {
                        Vector3.new(-.26, 0, -.22), Vector3.new(.27, 0, -.20),
                        Vector3.new(.27, 0, .22), Vector3.new(-.26, 0, .20),
                    }
                    local p = patrol[targetIndex]
                    local destination = cf:PointToWorldSpace(Vector3.new(
                        p.X * size.X, 0, p.Z * size.Z))
                    local delta = Vector3.new(destination.X-root.Position.X, 0,
                        destination.Z-root.Position.Z)
                    if delta.Magnitude < 5 then targetIndex = targetIndex % #patrol + 1
                    elseif delta.Magnitude > .1 then wish = delta.Unit end
                end
                if wish then
                    -- Keep the proposed target within Ant Field, not through the walls.
                    local proposed = root.Position + wish * 7
                    if insideField(arena, proposed, 4) then
                        hum:Move(wish, false)
                    else
                        hum:Move(-wish, false)
                    end
                end
                -- Use the collector while patrolling to fill the wave meter.
                if os.clock()-lastClick > .18 then
                    lastClick=os.clock()
                    local camera=workspace.CurrentCamera
                    if camera then
                        local vp=camera.ViewportSize
                        local x,y=math.floor(vp.X-16),math.floor(vp.Y*.52)
                        pcall(function()
                            VIM:SendMouseButtonEvent(x,y,0,true,game,0)
                            VIM:SendMouseButtonEvent(x,y,0,false,game,0)
                        end)
                    end
                end
                if danger and os.clock() - lastJump > 1.0
                    and hum.FloorMaterial ~= Enum.Material.Air then
                    hum.Jump = true
                    lastJump = os.clock()
                    tell("Dodging " .. (nearest.Mower and "lawnmower" or "ant") .. " + jumping")
                end
                task.wait(.12)
            end
        end
        activeButton.Activated:Connect(function()
            if busy then stopAnt(); return end
            if farmEnabled then tell("Turn off Farm before Ant Challenge"); return end
            if CombatController.IsBusy() or CombatSignals.PlanterBusy then
                tell("Finish current Combat / Planter action first")
                return
            end
            busy = true
            epoch += 1
            local id = epoch
            activeButton.Text = "ANT CHALLENGE: ON"
            activeButton.BackgroundColor3 = Color3.fromRGB(35, 95, 62)
            task.spawn(function()
                local ok, err = pcall(runAnt, id)
                if not ok then tell("Ant error: " .. tostring(err)); warn("[BSS Ant]", err) end
                if id == epoch then
                    local latest = CombatSignals.AntStatus
                    stopAnt()
                    tell(latest)
                end
            end)
        end)
        screen.Destroying:Connect(function() stopAnt(); CombatSignals.AntCancel = nil end)
    end
    initializeAntChallenge()
end

-- TOY: Blender crafting through the user's actual Blender GUI, using
-- the RecipeInfo/QuantitySelect controls found in Dex. Never click Tickets.
do
    local function initializeBlender()
        local page = pages.Toy
        local state = {Busy=false, Epoch=0, Recipes={}, Selected=nil, Quantity=1, PendingScan=false}
        local bg = Color3.fromRGB(19, 22, 30)
        local border = Color3.fromRGB(150, 89, 255)
        local hint = Color3.fromRGB(172, 181, 198)
        local function label(parent,text,pos,size,fontSize)
            return ui("TextLabel", {Position=pos,Size=size,BackgroundTransparency=1,
                Text=text,TextColor3=white,Font=Enum.Font.Gotham,
                TextSize=fontSize or 12,TextXAlignment=Enum.TextXAlignment.Left,
                TextWrapped=true},parent)
        end
        local function button(parent,text,pos,size)
            local b=ui("TextButton",{Position=pos,Size=size,BackgroundColor3=bg,
                Text=text,TextColor3=white,Font=Enum.Font.GothamBold,
                TextSize=12,BorderColor3=border,BorderSizePixel=1},parent)
            ui("UICorner",{CornerRadius=UDim.new(0,4)},b)
            return b
        end
        -- Compact accordion leaves the rest of Toy free for later features.
        local header = button(page, "▶  BLENDER  |  Crafting", UDim2.fromOffset(12, 10),
            UDim2.new(1, -26, 0, 28))
        header.Name = "BlenderSectionHeader"
        header.TextXAlignment = Enum.TextXAlignment.Left
        header.TextSize = 14
        local panel = ui("Frame", {
            Name = "BlenderSectionBody", Position = UDim2.fromOffset(12, 42),
            Size = UDim2.new(1, -26, 0, 199), BackgroundColor3 = bg,
            BorderSizePixel = 0, Visible = false,
        }, page)
        ui("UICorner", {CornerRadius = UDim.new(0, 5)}, panel)
        local scan = button(panel, "SCAN", UDim2.fromOffset(8, 7), UDim2.fromOffset(94, 23))
        local craft = button(panel, "CRAFT SELECTED", UDim2.fromOffset(277, 110),
            UDim2.new(1, -286, 0, 27))
        label(panel, "QTY", UDim2.fromOffset(277, 77), UDim2.fromOffset(43, 23), 12)
        local amount = ui("TextBox", {
            Name = "BlenderQuantity", Position = UDim2.fromOffset(322, 77),
            Size = UDim2.fromOffset(85, 24), BackgroundColor3 = bg, TextColor3 = white,
            Text = "1", ClearTextOnFocus = false, Font = Enum.Font.GothamBold,
            TextSize = 14, BorderColor3 = border, BorderSizePixel = 1,
        }, panel)
        local scroll = ui("ScrollingFrame", {
            Name = "BlenderRecipeList", Position = UDim2.fromOffset(8, 34),
            Size = UDim2.new(.48, -12, 0, 119), BackgroundColor3 = bg,
            BorderSizePixel = 0, ScrollBarThickness = 4,
            CanvasSize = UDim2.fromOffset(0, 0),
            AutomaticCanvasSize = Enum.AutomaticSize.Y,
        }, panel)
        ui("UIListLayout", {SortOrder = Enum.SortOrder.LayoutOrder,
            Padding = UDim.new(0, 2)}, scroll)
        ui("UIPadding", {PaddingTop = UDim.new(0, 2), PaddingLeft = UDim.new(0, 4),
            PaddingRight = UDim.new(0, 5)}, scroll)
        local selected = label(panel, "Selected: none", UDim2.fromOffset(277, 34),
            UDim2.new(1, -285, 0, 38), 12)
        local status = label(panel, "Open Blender, then Scan recipes.",
            UDim2.fromOffset(8, 157), UDim2.new(1, -16, 0, 38), 11)
        status.TextColor3 = hint
        status.TextYAlignment = Enum.TextYAlignment.Top
        header.Activated:Connect(function()
            panel.Visible = not panel.Visible
            header.Text = (panel.Visible and "▼  " or "▶  ") .. "BLENDER  |  Crafting"
        end)
        local function tell(text) status.Text=tostring(text) end
        local function available(id)
            return state.Busy and state.Epoch==id and screen.Parent ~= nil and not farmEnabled
        end
        local function findBox()
            local gui=playerGui:FindFirstChild("Blender",true)
            if not gui or gui:IsDescendantOf(screen) then return nil end
            local box=gui:FindFirstChild("Box",true)
            if box and box:IsA("GuiObject") then return box end
            return nil
        end
        local function textOf(parent,name)
            local obj=parent and parent:FindFirstChild(name,true)
            if obj and (obj:IsA("TextLabel") or obj:IsA("TextButton")) then
                return obj.Text
            end
            return ""
        end
        local function findButton(parent,name)
            local obj=parent and parent:FindFirstChild(name,true)
            if obj and (obj:IsA("ImageButton") or obj:IsA("TextButton")) then return obj end
            return nil
        end
        -- RecipeProgress stays visible even AFTER crafting has finished.
        -- Red EndButton means cancel an active craft; green EndButton means
        -- collect the finished batch. Never infer completion from the word
        -- 'Crafting' in ActionLabel: that text persists after completion.
        local function blenderPhase(box)
            local progress=box and box:FindFirstChild("RecipeProgress",true)
            if not progress or not progress:IsA("GuiObject")
                or not NativeInteraction.Visible(progress) then
                return "idle", ""
            end
            local timer=textOf(progress,"TimeLabel")
            local mm,ss=timer:match("(%d+)%s*:%s*(%d+)")
            local timeLeft=mm and (tonumber(mm)*60+tonumber(ss)) or nil
            local finish=findButton(progress,"EndButton")
            if finish and NativeInteraction.Visible(finish) then
                local color=finish.BackgroundColor3
                local green=color.G>0.32 and color.G>color.R*1.3
                    and color.G>color.B*1.12
                local bar=progress:FindFirstChild("ProgressBar",true)
                local fill=bar and bar:FindFirstChild("FillBar",true)
                local full=bar and fill and bar:IsA("GuiObject")
                    and fill:IsA("GuiObject") and bar.AbsoluteSize.X>3
                    and fill.AbsoluteSize.X / bar.AbsoluteSize.X >= 0.985
                if green or (full and (timeLeft==nil or timeLeft<=0)) then
                    return "ready",timer
                end
            end
            return "running",timer
        end
        local function craftingNow(box)
            return blenderPhase(box) ~= "idle"
        end
        local function moveToBlender(id)
            local box=findBox()
            if box and NativeInteraction.Visible(box) then return box end
            if not available(id) then return nil end
            local toys=workspace:FindFirstChild("Toys")
            local toy=toys and toys:FindFirstChild("Blender")
            if not toy then tell("Workspace.Toys.Blender not found"); return nil end
            local hum,root=getHumanoidAndRoot()
            local bestPart,near = nil,math.huge
            for _,obj in ipairs(toy:GetDescendants()) do
                if obj:IsA("BasePart") then
                    local d=(obj.Position-root.Position).Magnitude
                    if d<near then bestPart,near=obj,d end
                end
            end
            if toy:IsA("BasePart") then bestPart=toy end
            if not bestPart then tell("Blender interaction point missing"); return nil end
            tell("Flying to Blender...")
            local p=bestPart.Position+Vector3.new(0,3,0)
            if not SmoothFlight.Path(root,{p},function() return available(id) end,TweenSpeed)
                then tell("Blender travel cancelled/failed");return nil end
            for attempt=1,4 do
                if not available(id) then return nil end
                NativeInteraction.PressE()
                task.wait(.27)
                box=findBox()
                if box and NativeInteraction.Visible(box) then return box end
            end
            tell("Blender GUI did not open; inspect E prompt")
            return nil
        end
        local function displayRecipes()
            for _,obj in ipairs(scroll:GetChildren()) do
                if obj:IsA("TextButton") then obj:Destroy() end
            end
            for index,item in ipairs(state.Recipes) do
                local row=button(scroll,item.Name,UDim2.fromOffset(0,0),UDim2.new(1,-9,0,27))
                row.LayoutOrder=index
                row.TextXAlignment=Enum.TextXAlignment.Left
                row.Activated:Connect(function()
                    state.Selected=item.Name
                    selected.Text="Selected: "..item.Name.."\nPage "..tostring(item.Page)
                end)
            end
        end
        local function click(obj,id)
            if not available(id) then return false end
            return NativeInteraction.Click(obj)
        end
        local function cycleUntil(box,wanted,id)
            local recipe=box:FindFirstChild("RecipeInfo",true)
            local forward=findButton(box,"ForwardButton")
            if not recipe or not forward then return false end
            for turn=1,21 do
                if not available(id) then return false end
                local name=textOf(recipe,"RecipeName"):gsub("^%s*%-?%s*",""):gsub("%s*%-?%s*$","")
                if name:lower()==wanted:lower() then return true end
                if not click(forward,id) then return false end
                task.wait(.14)
            end
            return false
        end
        local function scanRecipes(id)
            local box=moveToBlender(id)
            if not box then return end
            local phase,timer=blenderPhase(box)
            if phase=="running" then
                -- Leave an active batch completely untouched. The background
                -- watcher will resume SCAN only after it becomes claimable.
                state.PendingScan=true
                tell("Crafting "..(timer~="" and timer or "in progress")
                    .." | Will collect and SCAN when finished")
                return
            end
            if phase=="ready" then
                -- The actual completed-batch action is RecipeProgress.EndButton.
                -- Clicking it while red would cancel crafting, so only click
                -- after blenderPhase says READY (green/full progress).
                tell("Craft complete! Collecting finished batch...")
                for attempt=1,2 do
                    if not available(id) then return end
                    local progress=box:FindFirstChild("RecipeProgress",true)
                    local finish=findButton(progress,"EndButton")
                    if not finish or not NativeInteraction.Visible(finish) then
                        tell("Completed craft has no visible EndButton")
                        return
                    end
                    if blenderPhase(box)~="ready" then break end
                    if not click(finish,id) then
                        tell("Unable to click green End Crafting button")
                        return
                    end
                    local deadline=os.clock()+3.0
                    local recipeReady=false
                    while available(id) and os.clock()<deadline do
                        local latest=findBox()
                        if latest then box=latest end
                        local recipe=box and box:FindFirstChild("RecipeInfo",true)
                        if blenderPhase(box)=="idle"
                            and recipe and NativeInteraction.Visible(recipe) then
                            recipeReady=true
                            break
                        end
                        task.wait(.13)
                    end
                    if not recipeReady and blenderPhase(box)=="idle" then
                        -- Claiming can close the native Blender popup entirely.
                        -- Re-open it before reading recipe names and turning pages.
                        local reopened=moveToBlender(id)
                        local recipe=reopened and reopened:FindFirstChild("RecipeInfo",true)
                        if reopened and recipe and NativeInteraction.Visible(recipe) then
                            box=reopened
                            recipeReady=true
                        end
                    end
                    if recipeReady then break end
                end
                local recipe=box and box:FindFirstChild("RecipeInfo",true)
                if blenderPhase(box)~="idle"
                    or not recipe or not NativeInteraction.Visible(recipe) then
                    tell("End Crafting clicked but recipe menu did not reopen")
                    return
                end
                tell("Rewards collected; scanning recipes...")
            end
            state.PendingScan=false
            local forward=findButton(box,"ForwardButton")
            local recipe=box:FindFirstChild("RecipeInfo",true)
            if not recipe or not forward then tell("RecipeInfo/ForwardButton missing");return end
            local items,seen={},{}
            for index=1,20 do
                if not available(id) then return end
                local raw=textOf(recipe,"RecipeName")
                local name=raw:gsub("^%s*%-?%s*",""):gsub("%s*%-?%s*$","")
                if name~="" and not seen[name] then
                    seen[name]=true
                    table.insert(items,{Name=name,Page=index})
                end
                if not click(forward,id) then break end
                task.wait(.13)
            end
            state.Recipes=items
            displayRecipes()
            tell("Found "..#items.." recipes; select item and quantity")
        end
        local function craftItem(id)
            local requested=state.Selected
            if not requested then tell("Select a recipe first");return end
            local qty=math.floor(tonumber(amount.Text) or 0)
            if qty<1 or qty>999 then tell("Enter quantity from 1 to 999");return end
            state.Quantity=qty
            local box=moveToBlender(id)
            if not box then return end
            local phase,timer=blenderPhase(box)
            if phase=="running" then
                tell("Blender is crafting ("..timer.."); SCAN will wait for completion")
                return
            elseif phase=="ready" then
                tell("Finished batch is unclaimed. Press SCAN to collect first")
                return
            end
            tell("Selecting "..requested)
            if not cycleUntil(box,requested,id) then
                tell("Recipe not found in Blender GUI");return end
            -- ButtonBlock is NOT the green "Make" button. The actual
            -- interactive control in the Blender GUI is SelectBox.SelectButton.
            -- NativeInteraction.Click returning true only means the click was
            -- dispatched, not that the Roblox game accepted the action.
            local selectBox=box:FindFirstChild("SelectBox",true)
            local make=findButton(selectBox,"SelectButton")
            if not make then
                tell("Blender SelectBox.SelectButton missing; UI changed")
                return
            end
            local quant=box:FindFirstChild("QuantitySelect",true)
            local opened=false
            for attempt=1,2 do
                if not available(id) then return end
                if not click(make,id) then
                    tell("Cannot click the Blender's Make button")
                    return
                end
                -- Native UI often updates later than the previous 0.15s wait.
                local deadline=os.clock()+1.5
                repeat
                    quant=box:FindFirstChild("QuantitySelect",true)
                    if quant and NativeInteraction.Visible(quant) then
                        opened=true
                        break
                    end
                    task.wait(.1)
                until not available(id) or os.clock()>=deadline
                if opened then break end
                if attempt==1 then
                    tell("Make clicked, but quantity dialog is delayed; retrying...")
                end
            end
            if not opened then
                tell("Game did not open quantity dialog; check Make button/materials")
                return
            end
            local plus=findButton(quant,"PlusButton")
            local minus=findButton(quant,"MinusButton")
            local confirm=findButton(quant,"ConfirmButton")
            local amountLabel=textOf(quant,"QuantityLabel")
            local current=tonumber(amountLabel:match("(%d+)")) or 1
            local count, stalls=0,0
            while current~=qty and available(id) and count<1200 do
                local target=(current<qty) and plus or minus
                if not target or not click(target,id) then break end
                task.wait(.09)
                local updated=textOf(quant,"QuantityLabel")
                local actual=tonumber(updated:match("(%d+)"))
                if actual and actual~=current then
                    current, stalls=actual,0
                else
                    stalls+=1
                    if stalls>=4 then
                        tell("Quantity button did not update native GUI; aborting")
                        return
                    end
                end
                count+=1
            end
            if not available(id) then return end
            if current~=qty then
                tell("Quantity not confirmed ("..current.."/"..qty..")");return end
            if not confirm or not click(confirm,id) then
                tell("ConfirmButton could not be clicked");return end
            task.wait(.32)
            local progress=box:FindFirstChild("RecipeProgress",true)
            local timer=textOf(progress,"TimeLabel")
            if craftingNow(box) or timer:match("%d+:%d+") then
                tell("Craft started: "..qty.."x "..requested.." | "..timer)
            else
                tell("Craft not confirmed; check materials or game response")
            end
        end
        local function start(action)
            if state.Busy then tell("Blender action already running");return end
            if farmEnabled or CombatController.IsBusy() or CombatSignals.PlanterBusy then
                tell("Turn off Farm and finish Combat/Planter before crafting")
                return
            end
            state.Busy=true
            state.Epoch+=1
            local id=state.Epoch
            CombatSignals.ToyBusy=true
            task.spawn(function()
                local ok,err=pcall(action,id)
                if not ok then tell("Blender error: "..tostring(err));warn("[BSS Blender]",err) end
                if id==state.Epoch then state.Busy=false;CombatSignals.ToyBusy=false end
            end)
        end
        ConfigManager.Register("Blender", function()
            return {Recipe = state.Selected, Quantity = tonumber(amount.Text) or state.Quantity}
        end, function(data)
            if type(data.Recipe) == "string" then
                state.Selected = data.Recipe
                selected.Text = "Selected: " .. state.Selected .. " (scan recipes to craft)"
            end
            local n = tonumber(data.Quantity)
            if n and n >= 1 and n <= 999 then
                state.Quantity = math.floor(n)
                amount.Text = tostring(state.Quantity)
            end
        end)

        scan.Activated:Connect(function() start(scanRecipes) end)
        craft.Activated:Connect(function()
            state.PendingScan=false
            start(craftItem)
        end)
        -- A SCAN pressed during crafting registers a passive intent. Poll the
        -- visible GUI instead of holding ToyBusy for the entire crafting timer.
        -- Never pull the player away from Farm/Combat/Planter work.
        task.spawn(function()
            while screen.Parent do
                task.wait(1.5)
                if state.PendingScan and not state.Busy and not farmEnabled
                    and not CombatController.IsBusy()
                    and not CombatSignals.PlanterBusy
                    and not CombatSignals.AntBusy then
                    local box=findBox()
                    if box and NativeInteraction.Visible(box) then
                        local phase=blenderPhase(box)
                        if phase=="ready" or phase=="idle" then
                            state.PendingScan=false
                            start(scanRecipes)
                        end
                    end
                end
            end
        end)
        CombatSignals.ToyCancel=function()
            state.PendingScan=false
            state.Epoch+=1
            state.Busy=false
            CombatSignals.ToyBusy=false
        end
        screen.Destroying:Connect(function()
            if CombatSignals.ToyCancel then CombatSignals.ToyCancel() end
        end)
    end
    initializeBlender()
end

-- QUEST PAGE: AUTO BEAR QUEST CONTROLLER (kept in a separate function to avoid
-- the 200-register limit in Luau's outer chunk).
do
    local function initBearQuests()
        local page = pages.Quest
        local NPCs = workspace:FindFirstChild("NPCs") or workspace:WaitForChild("NPCs", 12)
        local questState = {
            Enabled = false,
            AutoFarm = true,
            AutoTalk = true,
            Selected = {},
            RunId = 0,
            InVisit = false,
            Tween = nil,
            LastVisit = {},
            LastQuestsOpen = -math.huge,
            LastFieldSwitch = -math.huge,
            FieldStart = nil,
            LastMessage = "Select bear(s), then enable Auto Quest.",
            AutoCombat = true, NeedsEvaluation = true, PendingVisit = nil,
        }

        local bg = Color3.fromRGB(19, 19, 25)
        local accent = Color3.fromRGB(151, 91, 255)
        local gray = Color3.fromRGB(177, 183, 196)
        local function makeLabel(parent, text, pos, size, fontSize, color)
            return ui("TextLabel", {
                BackgroundTransparency = 1, Position = pos, Size = size,
                Text = text, TextColor3 = color or white,
                Font = Enum.Font.Gotham, TextSize = fontSize or 13,
                TextXAlignment = Enum.TextXAlignment.Left,
                TextYAlignment = Enum.TextYAlignment.Center,
                TextWrapped = true,
            }, parent)
        end
        local function makeButton(parent, text, pos, size)
            local b = ui("TextButton", {
                BackgroundColor3 = bg, BorderColor3 = accent, BorderSizePixel = 1,
                Position = pos, Size = size, Font = Enum.Font.GothamBold,
                Text = text, TextColor3 = white, TextSize = 12,
                AutoButtonColor = true,
            }, parent)
            ui("UICorner", {CornerRadius = UDim.new(0, 5)}, b)
            return b
        end
        local function setStatus(message)
            questState.LastMessage = message
        end
        local function isRunning(id)
            return questState.Enabled and questState.RunId == id and screen.Parent ~= nil
        end
        local function firstChildRecursive(root, childName)
            return root and root:FindFirstChild(childName, true)
        end
        local function readableText(obj)
            if obj and (obj:IsA("TextLabel") or obj:IsA("TextButton") or obj:IsA("TextBox")) then
                return tostring(obj.Text or "")
            end
            return ""
        end
        local function visibleGui(obj)
            if not obj or not obj:IsA("GuiObject") then return false end
            if obj.AbsoluteSize.X < 3 or obj.AbsoluteSize.Y < 3 then return false end
            local parent = obj
            while parent do
                if parent:IsA("GuiObject") and not parent.Visible then return false end
                if parent:IsA("ScreenGui") and not parent.Enabled then return false end
                parent = parent.Parent
            end
            return true
        end
        local function clickAtGui(target)
            if not visibleGui(target) then return false end
            local point = target.AbsolutePosition + target.AbsoluteSize / 2
            local gameScreen = target:FindFirstAncestorOfClass("ScreenGui")
            if gameScreen and gameScreen.ScreenInsets == Enum.ScreenInsets.CoreUISafeInsets then
                point += GuiService:GetGuiInset()
            end
            local x, y = math.floor(point.X), math.floor(point.Y)
            local restoreWindow = window.Visible
            if restoreWindow then window.Visible = false end
            task.wait(0.01)
            local ok, message = pcall(function()
                VIM:SendMouseMoveEvent(x, y, game)
                task.wait(0.025)
                VIM:SendMouseButtonEvent(x, y, 0, true, game, 0)
                task.wait(0.035)
                VIM:SendMouseButtonEvent(x, y, 0, false, game, 0)
            end)
            if restoreWindow and window.Parent then window.Visible = true end
            if not ok then warn("[BSS Quest Click]", message) end
            return ok
        end
        local function pressInteractionKey(id)
            if not isRunning(id) then return end
            local ok, message = pcall(function()
                VIM:SendKeyEvent(true, Enum.KeyCode.E, false, game)
                task.wait(0.075)
                VIM:SendKeyEvent(false, Enum.KeyCode.E, false, game)
            end)
            if not ok then warn("[BSS Quest E]", message) end
        end

        -- UI: Controls + scrollable bear checklist.
        makeLabel(page, "AUTO BEAR QUEST", UDim2.fromOffset(12, 9),
            UDim2.fromOffset(270, 28), 19, white).Font = Enum.Font.GothamBold
        local farmToggle = makeButton(page, "AUTO QUEST: OFF", UDim2.fromOffset(12, 43),
            UDim2.fromOffset(160, 25))
        local talkToggle = makeButton(page, "Auto talk: ON", UDim2.fromOffset(180, 43),
            UDim2.fromOffset(139, 25))
        makeLabel(page, "SELECT QUEST GIVERS", UDim2.fromOffset(12, 76),
            UDim2.fromOffset(207, 24), 14, gray)
        makeLabel(page, "QUEST MONITOR", UDim2.fromOffset(250, 76),
            UDim2.fromOffset(292, 24), 14, gray)
        local bearScroll = ui("ScrollingFrame", {
            Name = "BearChecklist", Position = UDim2.fromOffset(12, 102),
            Size = UDim2.fromOffset(225, 194), BackgroundColor3 = bg,
            BorderSizePixel = 0, ScrollBarThickness = 5,
            AutomaticCanvasSize = Enum.AutomaticSize.Y,
            CanvasSize = UDim2.fromOffset(0, 0),
        }, page)
        ui("UIPadding", {PaddingTop = UDim.new(0, 4), PaddingBottom = UDim.new(0, 5),
            PaddingLeft = UDim.new(0, 5), PaddingRight = UDim.new(0, 9)}, bearScroll)
        ui("UIListLayout", {SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 4)}, bearScroll)
        local monitor = ui("ScrollingFrame", {
            Name = "QuestMonitor", Position = UDim2.fromOffset(249, 102),
            Size = UDim2.new(1, -261, 0, 194), BackgroundColor3 = bg,
            BorderSizePixel = 0, ScrollBarThickness = 5,
            AutomaticCanvasSize = Enum.AutomaticSize.Y,
            CanvasSize = UDim2.fromOffset(0, 0),
        }, page)
        ui("UIPadding", {PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8),
            PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 10)}, monitor)
        ui("UIListLayout", {SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 5)}, monitor)
        local status = makeLabel(page, "Select one or more Bears.", UDim2.fromOffset(12, 303),
            UDim2.new(1, -24, 0, 61), 13, gray)
        status.TextYAlignment = Enum.TextYAlignment.Top
        local bearRows = {}
        local questRootCache = nil
        local function scanBears()
            if not NPCs then return end
            for _, old in pairs(bearRows) do old:Destroy() end
            table.clear(bearRows)
            local all = {}
            for _, candidate in ipairs(NPCs:GetChildren()) do
                local name = candidate.Name:lower()
                local validCircle = candidate:FindFirstChild("Circle", true)
                local questNPC = name:find("bear", 1, true)
                    or name:find("honey bee", 1, true)
                    or name:find("bucko bee", 1, true)
                    or name:find("riley bee", 1, true)
                    or name:find("stick bug", 1, true)
                    or name == "onett" or name:find("digital bee", 1, true)
                if candidate.Name ~= "Bear" and (validCircle or questNPC)
                    and not name:find("challenge info", 1, true) then
                    table.insert(all, candidate)
                end
            end
            table.sort(all, function(a, b) return a.Name < b.Name end)
            for index, model in ipairs(all) do
                local name = model.Name
                local row = makeButton(bearScroll, "", UDim2.fromOffset(0, 0),
                    UDim2.new(1, -4, 0, 28))
                row.Name = "NPC_" .. name
                row.LayoutOrder = index
                local check = makeLabel(row, "", UDim2.fromOffset(8, 3),
                    UDim2.new(1, -14, 1, -6), 13)
                local function paint()
                    local on = questState.Selected[name] == true
                    check.Text = (on and "[x] " or "[ ] ") .. name
                    check.TextColor3 = on and Color3.fromRGB(112, 255, 175) or white
                end
                row.Activated:Connect(function()
                    if not firstChildRecursive(model, "Circle") then
                        setStatus(name .. ": Circle not found, cannot auto-talk yet")
                        return
                    end
                    questState.Selected[name] = not questState.Selected[name]
                    paint()
                end)
                paint()
                table.insert(bearRows, row)
            end
            if #all == 0 then setStatus("No quest NPC models found under Workspace.NPCs") end
        end
        local function selectedNames()
            local result = {}
            for name, selected in pairs(questState.Selected) do
                if selected then table.insert(result, name) end
            end
            table.sort(result)
            return result
        end
        local function locateCircle(name)
            local model = NPCs and NPCs:FindFirstChild(name)
            if not model then return nil end
            local circle = firstChildRecursive(model, "Circle")
            if circle and circle:IsA("BasePart") then return circle end
            return nil
        end
        local function findQuestRoot()
            if questRootCache and questRootCache.Parent then return questRootCache end
            local menus = playerGui:FindFirstChild("Menus", true)
            local children = menus and menus:FindFirstChild("Children", true)
            local quests = children and children:FindFirstChild("Quests")
            if not quests then quests = menus and menus:FindFirstChild("Quests", true) end
            questRootCache = quests and quests:FindFirstChild("Content", true)
            return questRootCache
        end
        local function valueFromBar(description)
            local a, b = description:match("([%d,]+)%s*/%s*([%d,]+)")
            if not a then return nil end
            local current = tonumber((a:gsub(",", "")))
            local total = tonumber((b:gsub(",", "")))
            if current and total and total > 0 then return current >= total end
            return nil
        end
        local function getQuests()
            local root = findQuestRoot()
            local result = {}
            if not root then return result end
            for _, box in ipairs(root:GetDescendants()) do
                if box.Name == "QuestBox" then
                    local titleLabel = firstChildRecursive(box, "TitleBar")
                    local title = readableText(titleLabel)
                    if title ~= "" then
                        local tasks = {}
                        local allComplete = true
                        for _, child in ipairs(box:GetDescendants()) do
                            if child.Name == "TaskBar" then
                                local desc = readableText(firstChildRecursive(child, "Description"))
                                if desc ~= "" then
                                    local statusText = desc:lower()
                                    local completed = statusText:find("complete!", 1, true) ~= nil
                                        or statusText:match("^%s*complete%s*$") ~= nil
                                    local numeric = valueFromBar(desc)
                                    if numeric == true then completed = true end
                                    if not completed then allComplete = false end
                                    table.insert(tasks, {Text = desc, Complete = completed})
                                end
                            end
                        end
                        if #tasks == 0 then allComplete = false end
                        table.insert(result, {Title = title, Tasks = tasks,
                            Complete = allComplete, Object = box})
                    end
                end
            end
            return result
        end
        local function questForBear(quests, bearName)
            local needle = bearName:lower():gsub("gifted ", "")
            needle = needle:gsub(" bee", "")
            for _, quest in ipairs(quests) do
                local title = quest.Title:lower()
                if title:find(needle, 1, true) or
                    (bearName:lower():find("bucko", 1, true) and title:find("bucko", 1, true)) or
                    (bearName:lower():find("riley", 1, true) and title:find("riley", 1, true)) then
                    return quest
                end
            end
            return nil
        end
        local function tryLoadQuestMenu(id)
            if os.clock() - questState.LastQuestsOpen < 3 or not isRunning(id) then return end
            questState.LastQuestsOpen = os.clock()
            local menus = playerGui:FindFirstChild("Menus", true)
            local tabs = menus and menus:FindFirstChild("ChildTabs", true)
            local questTab = tabs and tabs:FindFirstChild("Quests Tab", true)
            if questTab and visibleGui(questTab) then
                setStatus("Loading Quests Tab from game UI...")
                clickAtGui(questTab)
                task.wait(0.25)
            else
                setStatus("Cannot open Quests Tab. Open the game's menu once.")
            end
        end
        local function chooseTaskField(taskDescription)
            local text = taskDescription:lower()
            local matching = nil
            for _, field in ipairs(fieldObjects) do
                local f = field.Name:lower()
                if text:find(f, 1, true)
                    and (not matching or #f > #matching.Name) then
                    matching = field
                end
            end
            if matching then return matching end
            local color
            if text:find("red pollen", 1, true) then color = "red"
            elseif text:find("blue pollen", 1, true) then color = "blue"
            elseif text:find("white pollen", 1, true) then color = "white" end
            if not color then
                -- Generic pollen/ability-token tasks can be progressed in a field,
                -- but kills, stickers, crafting and other special tasks are not
                -- falsely marked as automated.
                if text:find("pollen", 1, true) or text:find("ability tokens", 1, true) then
                    if selectedField then
                        return FlowerZones:FindFirstChild(selectedField)
                    end
                    for _, fallback in ipairs({"Mountain Top Field", "Pine Tree Forest", "Rose Field"}) do
                        local obj = FlowerZones:FindFirstChild(fallback)
                        if obj then return obj end
                    end
                    return fieldObjects[1]
                end
                return nil
            end
            local preferred = {
                red = {"Pepper Patch", "Rose Field", "Strawberry Field", "Mushroom Field"},
                blue = {"Pine Tree Forest", "Bamboo Field", "Blue Flower Field"},
                white = {"Coconut Field", "Spider Field", "Dandelion Field", "Clover Field"},
            }
            for _, name in ipairs(preferred[color]) do
                for _, field in ipairs(fieldObjects) do
                    if field.Name:lower() == name:lower() then return field end
                end
            end
            return nil
        end
        local function activateFarm(fieldName)
            if fieldName and FlowerZones:FindFirstChild(fieldName) then
                if selectedField ~= fieldName then
                    selectedField = fieldName
                    fieldButton.Text = fieldName
                    if currentFarmTravelTween then currentFarmTravelTween:Cancel() end
                    stopWalking()
                end
            end
            if farmEnabled or not selectedField or hiveBusy then return end
            farmEnabled = true
            farmToken += 1
            preciseProgress = nil
            local token = farmToken
            paintFarm(true)
            task.spawn(function()
                local ok, err = pcall(runFarm, token)
                if not ok then warn("[BSS Quest Farm]", err) end
                if token == farmToken then
                    farmEnabled = false
                    paintFarm(false)
                    stopWalking()
                end
            end)
        end
        local function suspendFarm()
            local wasFarming = farmEnabled
            if farmEnabled then
                farmEnabled = false
                farmToken += 1
                preciseProgress = nil
                if currentFarmTravelTween then
                    currentFarmTravelTween:Cancel()
                    currentFarmTravelTween = nil
                end
                stopWalking()
                paintFarm(false)
            end
            return wasFarming
        end
        -- Read the live Quest GUI whenever a TaskBar Description changes.
        -- This stops field movement without waiting for the normal monitor tick.
        local questConnections = {}
        local watchedLabels = setmetatable({}, {__mode = "k"})
        local watchedRoot = nil
        local questEventQueued = false
        local function onQuestDataChanged()
            if not questState.Enabled then return end
            questState.NeedsEvaluation = true
            local quests = getQuests()
            for _, name in ipairs(selectedNames()) do
                local q = questForBear(quests, name)
                if q and q.Complete then
                    -- Quest GUI often flips to Complete on the exact kill tick.
                    -- Never cancel combat or the post-kill loot pass for NPC return.
                    if CombatController.IsBusy() or CombatSignals.LootBusy then
                        setStatus(name .. ": complete; waiting for combat loot")
                        break
                    end
                    questState.PendingVisit = name
                    CombatController.PrioritizeQuest(true)
                    if farmEnabled then suspendFarm() end
                    setStatus(name .. ": complete, returning to NPC...")
                    break
                end
            end
        end
        local function scheduleQuestCheck()
            if questEventQueued then return end
            questEventQueued = true
            task.delay(0.10, function()
                questEventQueued = false
                if screen.Parent then onQuestDataChanged() end
            end)
        end
        local function bindQuestLabel(obj)
            if watchedLabels[obj] then return end
            if obj.Name ~= "Description" and obj.Name ~= "TitleBar" then return end
            if not (obj:IsA("TextLabel") or obj:IsA("TextButton")) then return end
            watchedLabels[obj] = true
            table.insert(questConnections, obj:GetPropertyChangedSignal("Text"):Connect(scheduleQuestCheck))
        end
        local function attachQuestSignals()
            local root = findQuestRoot()
            if not root or root == watchedRoot then return end
            for _, connection in ipairs(questConnections) do connection:Disconnect() end
            table.clear(questConnections)
            watchedLabels = setmetatable({}, {__mode = "k"})
            watchedRoot = root
            for _, element in ipairs(root:GetDescendants()) do bindQuestLabel(element) end
            table.insert(questConnections, root.DescendantAdded:Connect(function(obj)
                bindQuestLabel(obj)
                questState.NeedsEvaluation = true
            end))
            table.insert(questConnections, root.DescendantRemoving:Connect(function()
                questState.NeedsEvaluation = true
            end))
            questState.NeedsEvaluation = true
        end
        local function goToBear(circle, id)
            if not isRunning(id) then return false end
            local _, root = getHumanoidAndRoot()
            if not root or not root.Parent then return false end
            local target = circle.Position + Vector3.new(0, math.max(2.3, circle.Size.Y / 2 + 1.4), 0)
            local points = {}
            if (root.Position - target).Magnitude > 22 then
                local altitude = math.max(root.Position.Y, target.Y) + 18
                table.insert(points, Vector3.new(root.Position.X, altitude, root.Position.Z))
                table.insert(points, Vector3.new(target.X, altitude, target.Z))
            end
            table.insert(points, target)
            return SmoothFlight.Path(root, points, function()
                return isRunning(id)
            end, TweenSpeed, function(handle, previous)
                if previous then
                    if questState.Tween == previous then questState.Tween = nil end
                else
                    questState.Tween = handle
                end
            end)
        end
        local function findDialogueClick()
            local best, score = nil, -math.huge
            for _, element in ipairs(playerGui:GetDescendants()) do
                if element:IsA("GuiObject") and visibleGui(element) then
                    local text = readableText(element):lower()
                    if text ~= "" then
                        local points = 0
                        if text:find("click to continue", 1, true) then points = 100
                        elseif text:find("tap to continue", 1, true) then points = 90
                        elseif text == "continue" or text == "next" then points = 80
                        elseif text == "accept" or text == "claim" then points = 70
                        elseif text:find("continue", 1, true) then points = 40 end
                        if points > score and points > 0 then
                            best, score = element, points
                        end
                    end
                end
            end
            return best
        end
        local function chatWithBear(name, id)
            local circle = locateCircle(name)
            if not circle then return false, "Missing Circle for " .. name end
            suspendFarm()
            local ok, result = pcall(function()
                setStatus("Flying to " .. name .. " / Circle...")
                if not goToBear(circle, id) then return false end
                if not isRunning(id) then return false end
                setStatus("Talking to " .. name .. "...")
                local opened = false
                for attempt = 1, 4 do
                    if not isRunning(id) then return false end
                    if findDialogueClick() then opened = true; break end
                    pressInteractionKey(id)
                    task.wait(0.18)
                    if findDialogueClick() then opened = true; break end
                end
                if not questState.AutoTalk then return true end
                if not opened then
                    setStatus(name .. ": no dialogue; retrying soon")
                    return false
                end
                local clicks, missing = 0, 0
                local started = os.clock()
                while isRunning(id) and clicks < 45 and os.clock() - started < 13 do
                    local target = findDialogueClick()
                    if target then
                        missing = 0
                        setStatus(name .. ": clicking dialogue (" .. (clicks + 1) .. ")")
                        if clickAtGui(target) then clicks += 1 end
                        -- Short server/UI settle time. Do not enforce old 0.3s delay.
                        task.wait(0.11)
                    else
                        missing += 1
                        if missing >= 4 then break end
                        task.wait(0.11)
                    end
                end
                task.wait(0.15) -- allow new quest/reward GUI to refresh
                return clicks > 0
            end)
            questState.NeedsEvaluation = true
            if not ok then
                warn("[BSS Bear Quest]", result)
                return false, tostring(result)
            end
            return result == true, nil
        end
        local function renderQuests(quests)
            for _, child in ipairs(monitor:GetChildren()) do
                if child:IsA("TextLabel") then child:Destroy() end
            end
            local selected = selectedNames()
            if #selected == 0 then
                makeLabel(monitor, "Select bear(s) on the left.",
                    UDim2.fromOffset(0, 0), UDim2.new(1, -4, 0, 25), 13, gray)
                return
            end
            for index, name in ipairs(selected) do
                local q = questForBear(quests, name)
                local completed = q and q.Complete
                local title = q and q.Title or "No active quest detected"
                local progress = ""
                if q then
                    local finished = 0
                    local pending = nil
                    for _, taskInfo in ipairs(q.Tasks) do
                        if taskInfo.Complete then
                            finished += 1
                        elseif not pending then
                            pending = taskInfo.Text
                        end
                    end
                    progress = string.format("  Tasks: %d/%d", finished, #q.Tasks)
                    if pending then progress ..= "\n  " .. pending:sub(1, 100) end
                end
                local message = (completed and "[READY] " or "") .. name .. "\n" .. title .. progress
                local label = makeLabel(monitor, message,
                    UDim2.fromOffset(0, 0), UDim2.new(1, -5, 0, 83), 12,
                    completed and Color3.fromRGB(124, 255, 151) or white)
                label.LayoutOrder = index
            end
        end
        local function updateStatusText()
            local state = questState.Enabled and "ON" or "OFF"
            status.Text = "Auto Quest: " .. state .. " | " .. questState.LastMessage
        end
        local function stopAutoQuest()
            questState.Enabled = false
            questState.RunId += 1
            if questState.Tween then
                questState.Tween:Cancel()
                questState.Tween = nil
            end
            farmToggle.Text = "AUTO QUEST: OFF"
            farmToggle.BackgroundColor3 = bg
            questState.PendingVisit = nil
            CombatController.PrioritizeQuest(false)
            setStatus("Stopped. Manual Farm is still available.")
            updateStatusText()
        end
        CombatSignals.QuestIsBusy = function()
            return questState.InVisit
        end
        local function questLoop(id)
            local lastRender = -math.huge
            local lastEval = -math.huge
            local nextAllowedVisit = {}
            local lastFieldChoice = nil
            while isRunning(id) do
                if CombatSignals.AntBusy or CombatSignals.ToyBusy then
                    setStatus("Quest paused while Ant Challenge / Blender is active")
                    updateStatusText()
                    task.wait(0.3)
                else
                attachQuestSignals()
                -- Changes are event-driven; 0.35s polling handles missed GUI events.
                if not CombatSignals.PlanterBusy and not questState.InVisit
                    and (questState.NeedsEvaluation
                    or os.clock() - lastEval >= 0.35) then
                    questState.NeedsEvaluation = false
                    lastEval = os.clock()
                    local selected = selectedNames()
                    if #selected == 0 then
                        setStatus("Select at least one Bear.")
                    else
                        local quests = getQuests()
                        if #quests == 0 then
                            tryLoadQuestMenu(id)
                            quests = getQuests()
                        end
                        local visitTarget = nil
                        local taskBear, targetField, targetSpawner = nil, nil, nil
                        local fallbackText = nil
                        local pendingMonsterReason = nil
                        -- Return completed quests BEFORE selecting another field.
                        -- Finish a completed quest before visiting an NPC with
                        -- no quest: otherwise alphabetic order can delay turn-in.
                        for _, name in ipairs(selected) do
                            local q = questForBear(quests, name)
                            if q and q.Complete and os.clock() >= (nextAllowedVisit[name] or 0) then
                                visitTarget = name
                                break
                            end
                        end
                        if not visitTarget then
                            for _, name in ipairs(selected) do
                                local q = questForBear(quests, name)
                                if not q and os.clock() >= (nextAllowedVisit[name] or 0) then
                                    visitTarget = name
                                    break
                                end
                            end
                        end
                        if visitTarget and CombatController.IsBusy() then
                            CombatController.PrioritizeQuest(true)
                            setStatus("Stopping combat to return to " .. visitTarget)
                        elseif visitTarget then
                            CombatController.PrioritizeQuest(true)
                            questState.PendingVisit = nil
                            questState.InVisit = true
                            suspendFarm() -- completed quest must stop farm immediately
                            nextAllowedVisit[visitTarget] = os.clock() + 3
                            local success, reason = chatWithBear(visitTarget, id)
                            questState.InVisit = false
                            CombatController.PrioritizeQuest(false)
                            -- Do not impose the old 75-second ban on NPC visits.
                            nextAllowedVisit[visitTarget] = os.clock() + (success and 2 or 3.5)
                            if success then
                                setStatus("Talked to " .. visitTarget .. "; checking for a new quest")
                            else
                                setStatus(reason or ("Could not talk to " .. visitTarget .. "; retry pending"))
                            end
                            questState.NeedsEvaluation = true
                        else
                            local combatBear = nil
                            for _, name in ipairs(selected) do
                                local q = questForBear(quests, name)
                                if q and not q.Complete then
                                    for _, objective in ipairs(q.Tasks) do
                                        if not objective.Complete then
                                            if not fallbackText then fallbackText = name .. ": " .. objective.Text end
                                            local isKill = CombatController.IsQuestKill(objective.Text)
                                            if questState.AutoCombat and isKill and not targetSpawner then
                                                local spawner, reason = CombatController.FindForTask(objective.Text)
                                                if spawner then
                                                    targetSpawner, combatBear = spawner, name
                                                elseif not pendingMonsterReason then
                                                    pendingMonsterReason = name .. ": " .. tostring(reason)
                                                end
                                            end
                                            -- A kill task must never be treated as a field-farm task.
                                            if not isKill and not targetField then
                                                local field = chooseTaskField(objective.Text)
                                                if field then targetField = field; taskBear = name end
                                            end
                                        end
                                    end
                                end
                            end
                            if targetSpawner and not CombatController.IsBusy() then
                                questState.InVisit = true
                                suspendFarm()
                                setStatus(combatBear .. ": fighting " .. targetSpawner.Name)
                                local success, reason = CombatController.FightQuest(targetSpawner, function()
                                    return isRunning(id) and questState.InVisit
                                        and not questState.PendingVisit
                                end)
                                questState.InVisit = false
                                setStatus(success and ("Defeated " .. targetSpawner.Name)
                                    or ("Combat: " .. tostring(reason)))
                                questState.NeedsEvaluation = true
                            elseif targetField and questState.AutoFarm then
                                if not CombatController.IsBusy() then
                                    if selectedField ~= targetField.Name then
                                        questState.LastFieldSwitch = os.clock()
                                        lastFieldChoice = targetField.Name
                                    end
                                    activateFarm(targetField.Name)
                                    local msg = taskBear .. ": farming " .. targetField.Name
                                    if pendingMonsterReason then
                                        msg ..= " | Monster: " .. pendingMonsterReason
                                    end
                                    setStatus(msg)
                                else
                                    setStatus("Waiting for Combat to finish...")
                                end
                            elseif fallbackText then
                                if questState.AutoFarm and selectedField
                                    and not farmEnabled and not CombatController.IsBusy() then
                                    -- If nothing auto-completable is pending, preserve
                                    -- user's current field rather than wandering.
                                    activateFarm(selectedField)
                                end
                                setStatus(pendingMonsterReason or fallbackText)
                            else
                                setStatus(pendingMonsterReason or "Monitoring selected Bear quests...")
                            end
                        end
                    end
                    if os.clock() - lastRender >= 0.8 then
                        renderQuests(getQuests())
                        lastRender = os.clock()
                    end
                    updateStatusText()
                end
                task.wait(0.14)
                end -- Ant / Blender pause gate
            end
        end
        farmToggle.Activated:Connect(function()
            if questState.Enabled then
                stopAutoQuest()
                return
            end
            if #selectedNames() == 0 then
                setStatus("Select at least one Bear first.")
                updateStatusText()
                return
            end
            questState.Enabled = true
            questState.RunId += 1
            questState.AutoFarm = true
            questState.AutoCombat = true
            farmToggle.Text = "AUTO QUEST: ON"
            farmToggle.BackgroundColor3 = Color3.fromRGB(45, 102, 74)
            setStatus("Starting quest monitor...")
            questState.NeedsEvaluation = true
            updateStatusText()
            local id = questState.RunId
            task.spawn(function()
                local ok, err = pcall(questLoop, id)
                if not ok then
                    warn("[BSS Auto Quest]", err)
                    if id == questState.RunId then
                        stopAutoQuest()
                        setStatus("Error: " .. tostring(err))
                        updateStatusText()
                    end
                end
            end)
        end)
        talkToggle.Activated:Connect(function()
            questState.AutoTalk = not questState.AutoTalk
            talkToggle.Text = questState.AutoTalk and "Auto talk: ON" or "Auto talk: OFF"
        end)
        ConfigManager.Register("Quest", function()
            local chosen = {}
            for name, on in pairs(questState.Selected) do
                if on == true then chosen[name] = true end
            end
            return {SelectedNPCs = chosen, AutoTalk = questState.AutoTalk}
        end, function(data)
            if type(data.SelectedNPCs) == "table" then
                table.clear(questState.Selected)
                for name, on in pairs(data.SelectedNPCs) do
                    if type(name) == "string" and on == true then
                        questState.Selected[name] = true
                    end
                end
                scanBears()
                renderQuests(getQuests())
            end
            if type(data.AutoTalk) == "boolean" then
                questState.AutoTalk = data.AutoTalk
                talkToggle.Text = questState.AutoTalk and "Auto talk: ON" or "Auto talk: OFF"
            end
        end)

        screen.Destroying:Connect(function()
            stopAutoQuest()
            for _, connection in ipairs(questConnections) do connection:Disconnect() end
        end)
        scanBears()
        renderQuests(getQuests())
        updateStatusText()
    end
    initBearQuests()
end

-- PLANT PAGE v8.1: explicit Planter + Field + OK -> 3 slots; hover = rewards.
-- Only one action at a time. Confirm remote actions by observing Workspace.Planters.
-- Kept within its own function to avoid Luau's outer-function register limit.
do
    local function initializePlantManager()
        local page = pages.Plant
        local ReplicatedStorage = game:GetService("ReplicatedStorage")
        local state = {
            Enabled = false, Busy = false, Epoch = 0, Slots = {},
            PendingType = nil, PendingField = nil, HoverKey = nil,
            HarvestAt = 100, Last = "Chọn Planter, Field, nhấn OK để thêm Slot.",
            RetryAt = {}, ReentryAt = 0, InventoryAttempts = 0, ManualOverride = false,
            NextInventoryTry = 0, LastSignature = "", LastUiUpdate = 0, LastStatusAt = 0,
        }
        local palette = {
            bg = Color3.fromRGB(21, 23, 31),
            surface = Color3.fromRGB(34, 38, 49),
            accent = Color3.fromRGB(147, 98, 241),
            green = Color3.fromRGB(39, 105, 72),
            text = Color3.fromRGB(246, 248, 251),
            muted = Color3.fromRGB(172, 181, 200),
            alert = Color3.fromRGB(255, 193, 105),
        }
        -- Guaranteed entries are conditional on full 100% growth.
        -- Other entries are possibilities, not exact probabilities.
        local lootTable = {
            candyplanter = {full = "5 Gumdrops, 1 Jelly Bean, 1 Ticket", chance = "Glue, Oil, Treats, Tickets, random drops"},
            petalplanter = {full = "1 Glitter, 5 Tickets", chance = "Jelly Beans, Field Dice, Glitter, Star Jelly"},
            blueclayplanter = {full = "1 Blue Extract, 1 Micro-Converter, 3 Honeysuckles, 1 Ticket", chance = "Blue Extract, Micro-Converter, Honeysuckle, Pineapple"},
            redclayplanter = {full = "1 Red Extract, 2 Soft Waxes, 1 Ticket", chance = "Red Extract, Soft/Hard Wax, rare Caustic/Swirled Wax"},
            pesticideplanter = {full = "1 Neonberry, 2 Tickets", chance = "Bitterberries, Neonberries, Caustic Wax, Stingers"},
            tackyplanter = {full = "1 Field Dice, 1 Ticket", chance = "Sunflower Seeds, Field Dice, Smooth Dice, rare Loaded Dice"},
            hydroponicplanter = {full = "1 Blue Extract, 1 Oil, 3 Tickets", chance = "Blue Extract, Oil, Blueberries, other field drops"},
            heattreatedplanter = {full = "1 Red Extract, 1 Enzyme, 3 Tickets", chance = "Red Extract, Enzymes, Wax, Stingers"},
            planterofplenty = {full = "5 Neonberries, 10 Tickets", chance = "Waxes, Turpentine, Neonberries, Micro-Converters"},
            ticketplanter = {full = nil, chance = "Tickets, random tokens; Puffshroom at full growth"},
            plasticplanter = {full = nil, chance = "Treats, Tickets, Berries, rare materials"},
            paperplanter = {full = nil, chance = "Treats, Seeds, random materials"},
            stickerplanter = {full = nil, chance = "Stickers, other rewards"},
            festiveplanter = {full = nil, chance = "Event supplies, treats, random drops"},
        }
        local nectars = {
            dandelionfield = "Comforting", bamboofield = "Comforting", pinetreeforest = "Comforting",
            mushroomfield = "Motivating", spiderfield = "Motivating", stumpfield = "Motivating", rosefield = "Motivating",
            sunflowerfield = "Satisfying", pineapplepatch = "Satisfying", pumpkinpatch = "Satisfying",
            blueflowerfield = "Refreshing", strawberryfield = "Refreshing", coconutfield = "Refreshing",
            cloverfield = "Invigorating", cactusfield = "Invigorating", mountaintopfield = "Invigorating", pepperpatch = "Invigorating",
        }
        local typeNames = {
            candyplanter = "Candy Planter", petalplanter = "Petal Planter",
            blueclayplanter = "Blue Clay Planter", redclayplanter = "Red Clay Planter",
            pesticideplanter = "Pesticide Planter", tackyplanter = "Tacky Planter",
            hydroponicplanter = "Hydroponic Planter", heattreatedplanter = "Heat-Treated Planter",
            planterofplenty = "The Planter Of Plenty", ticketplanter = "Ticket Planter",
            plasticplanter = "Plastic Planter", paperplanter = "Paper Planter",
            stickerplanter = "Sticker Planter", festiveplanter = "Festive Planter",
        }
        local function norm(name)
            return tostring(name or ""):lower():gsub("^the%s+", ""):gsub("[^%w]", "")
        end
        local function canonical(name)
            return typeNames[norm(name)] or tostring(name or "")
        end
        local statusLine
        local function setStatus(message)
            state.Last = tostring(message or "")
            if statusLine and statusLine.Parent then statusLine.Text = state.Last end
        end
        local function label(parent, text, x, y, w, h, size, color)
            local obj = ui("TextLabel", {
                BackgroundTransparency = 1, Text = text,
                Position = UDim2.fromOffset(x, y), Size = UDim2.fromOffset(w, h),
                TextColor3 = color or palette.text, TextSize = size or 12,
                Font = Enum.Font.Gotham, TextXAlignment = Enum.TextXAlignment.Left,
                TextYAlignment = Enum.TextYAlignment.Center,
                TextWrapped = true, ZIndex = 6,
            }, parent)
            return obj
        end
        local function button(parent, text, x, y, w, h)
            local obj = ui("TextButton", {
                Position = UDim2.fromOffset(x, y), Size = UDim2.fromOffset(w, h),
                Text = text, TextColor3 = palette.text, TextSize = 12,
                TextWrapped = true, BackgroundColor3 = palette.surface,
                Font = Enum.Font.GothamBold, BorderSizePixel = 1,
                BorderColor3 = palette.accent, ZIndex = 7,
            }, parent)
            ui("UICorner", {CornerRadius = UDim.new(0, 5)}, obj)
            return obj
        end
        local function scrolling(parent, name, x, y, w, h)
            local frame = ui("ScrollingFrame", {
                Name = name, Position = UDim2.fromOffset(x, y),
                Size = UDim2.fromOffset(w, h), BackgroundColor3 = palette.bg,
                BorderSizePixel = 0, ScrollBarThickness = 5,
                AutomaticCanvasSize = Enum.AutomaticSize.Y,
                CanvasSize = UDim2.fromOffset(0, 0), ZIndex = 5,
            }, parent)
            ui("UIPadding", {PaddingTop = UDim.new(0, 4), PaddingBottom = UDim.new(0, 4),
                PaddingLeft = UDim.new(0, 4), PaddingRight = UDim.new(0, 9)}, frame)
            ui("UIListLayout", {SortOrder = Enum.SortOrder.LayoutOrder,
                Padding = UDim.new(0, 3)}, frame)
            return frame
        end
        local function clearList(frame)
            for _, obj in ipairs(frame:GetChildren()) do
                if obj:IsA("GuiObject") then obj:Destroy() end
            end
        end

        local title = label(page, "PLANT MANAGER", 12, 7, 225, 28, 19)
        title.Font = Enum.Font.GothamBold
        label(page, "Harvest at %", 12, 42, 97, 25, 12)
        local percentBox = ui("TextBox", {
            Name = "HarvestPercent", Position = UDim2.fromOffset(109, 42),
            Size = UDim2.fromOffset(61, 25), Text = "100", PlaceholderText = "1-100",
            ClearTextOnFocus = false, TextColor3 = palette.text,
            BackgroundColor3 = palette.surface, Font = Enum.Font.GothamBold,
            TextSize = 14, BorderColor3 = palette.accent, BorderSizePixel = 1, ZIndex = 6,
        }, page)
        local autoButton = button(page, "AUTO PLANTER: OFF", 181, 42, 174, 25)
        local counter = label(page, "Slots: 0/3", 368, 42, 173, 25, 12, palette.muted)
        label(page, "1. CHOOSE PLANTER", 12, 75, 225, 22, 12, palette.muted)
        label(page, "2. CHOOSE FIELD", 246, 75, 158, 22, 12, palette.muted)
        label(page, "3. YOUR SLOTS", 410, 75, 149, 22, 12, palette.muted)
        local typeList = scrolling(page, "OwnedPlanterList", 12, 99, 226, 144)
        local fieldList = scrolling(page, "PlanterFieldList", 246, 99, 156, 144)
        local slotList = scrolling(page, "ThreePlanterSlots", 410, 99, 148, 144)
        -- This live panel tracks DEPLOYED personal planters independently of
        -- the three planner slots. It is moved into its own Midnight accordion.
        local livePanel = ui("Frame", {
            Name = "LivePlanterPanel", Position = UDim2.fromOffset(12, 392),
            Size = UDim2.new(1, -34, 0, 194), BackgroundTransparency = 1,
            BorderSizePixel = 0, ZIndex = 5,
        }, page)
        local liveSummary = label(livePanel,
            "SCANNING DEPLOYED PLANTERS...", 0, 0, 520, 21, 12, palette.muted)
        local liveRows = {}
        for i = 1, 3 do
            local card = ui("Frame", {
                Name = "ActivePlanter" .. i,
                Position = UDim2.fromOffset(0, 24 + (i - 1) * 55),
                Size = UDim2.new(1, -6, 0, 51),
                BackgroundColor3 = palette.surface, BorderSizePixel = 0,
                Visible = false, ZIndex = 6,
            }, livePanel)
            ui("UICorner", {CornerRadius = UDim.new(0, 5)}, card)
            local nameLabel = label(card, "", 10, 3, 480, 19, 12, palette.text)
            nameLabel.Size = UDim2.new(1, -18, 0, 19)
            nameLabel.Font = Enum.Font.GothamBold
            local detailLabel = label(card, "", 10, 23, 480, 14, 11, palette.muted)
            detailLabel.Size = UDim2.new(1, -18, 0, 14)
            local track = ui("Frame", {
                Position = UDim2.fromOffset(10, 42),
                Size = UDim2.new(1, -20, 0, 5),
                BackgroundColor3 = palette.bg, BorderSizePixel = 0, ZIndex = 8,
            }, card)
            local fill = ui("Frame", {
                Size = UDim2.fromScale(0, 1), BackgroundColor3 = palette.accent,
                BorderSizePixel = 0, ZIndex = 9,
            }, track)
            liveRows[i] = {Card = card, Name = nameLabel, Detail = detailLabel,
                Fill = fill}
        end
        local pendingLabel = label(page, "Choose a planter and a field", 12, 248, 385, 23, 12, palette.muted)
        local okButton = button(page, "OK  + SLOT", 410, 247, 148, 26)
        label(page, "HOVER SLOT FOR REWARDS  |  CLICK A SLOT ON MOBILE", 12, 277, 545, 15, 10, palette.muted)
        local rewardLabel = label(page, "Select Planter + Field, then press OK.", 12, 294, 545, 54, 11, palette.text)
        rewardLabel.TextYAlignment = Enum.TextYAlignment.Top
        statusLine = label(page, state.Last, 12, 349, 545, 33, 11, palette.alert)
        statusLine.TextYAlignment = Enum.TextYAlignment.Top
        local function slotKey(config)
            return norm(config.Type) .. "@" .. norm(config.Field)
        end
        local function showRewards(config)
            if not config then
                rewardLabel.Text = "Di chuột lên Slot để xem Nectar / đảm bảo 100% / có cơ hội nhận."
                return
            end
            local info = lootTable[norm(config.Type)] or {}
            local buff = nectars[norm(config.Field)] or "Unknown Nectar"
            local assured = info.full and (state.HarvestAt == 100 and info.full
                or "Chưa bảo đảm vì thu hoạch trước 100%; ở 100%: " .. info.full)
                or "Chưa có dữ liệu xác nhận phần thưởng cố định"
            rewardLabel.Text = string.format("%s • %s  |  Nectar: %s\nBảo đảm: %s\nCó thể rơi: %s",
                config.Type, config.Field, buff, assured, info.chance or "Vật phẩm phụ thuộc field và loại planter")
        end
        local function updatePending()
            pendingLabel.Text = (state.PendingType or "[Planter?]") .. "  →  " .. (state.PendingField or "[Field?]")
        end
        local function inventoryRows()
            local menus = playerGui:FindFirstChild("Menus", true)
            local eggs = menus and menus:FindFirstChild("Eggs", true)
            local content = eggs and eggs:FindFirstChild("Content", true)
            local result = {}
            if content then
                for _, row in ipairs(content:GetDescendants()) do
                    if row.Name == "EggRow" then
                        local item = row:FindFirstChild("TypeName", true)
                        local name = item and item:IsA("TextLabel") and item.Text or ""
                        if norm(name):find("planter", 1, true) then
                            local quantity = row:FindFirstChild("Count", true)
                            local txt = quantity and quantity:IsA("TextLabel") and quantity.Text or ""
                            local n = tonumber(txt:gsub(",", ""):match("x?(%d+)"))
                            if n == nil or n > 0 then result[norm(name)] = canonical(name) end
                        end
                    end
                end
            end
            return result
        end
        local function ensureInventoryOpen()
            if next(inventoryRows()) or state.InventoryAttempts >= 4
                or os.clock() < state.NextInventoryTry then return end
            local menus = playerGui:FindFirstChild("Menus", true)
            local tabs = menus and menus:FindFirstChild("ChildTabs", true)
            local target = tabs and tabs:FindFirstChild("Eggs Tab", true)
            if not target or not target:IsA("GuiObject") then return end
            if target.AbsoluteSize.X <= 0 or target.AbsoluteSize.Y <= 0 then return end
            state.InventoryAttempts += 1
            state.NextInventoryTry = os.clock() + 5
            local middle = target.AbsolutePosition + target.AbsoluteSize / 2
            local screenGui = target:FindFirstAncestorOfClass("ScreenGui")
            if screenGui and screenGui.ScreenInsets == Enum.ScreenInsets.CoreUISafeInsets then
                middle += GuiService:GetGuiInset()
            end
            local wasVisible = window.Visible
            window.Visible = false
            task.wait(.04)
            pcall(function()
                VIM:SendMouseButtonEvent(math.floor(middle.X), math.floor(middle.Y), 0, true, game, 0)
                task.wait(.09)
                VIM:SendMouseButtonEvent(math.floor(middle.X), math.floor(middle.Y), 0, false, game, 0)
            end)
            if window.Parent then window.Visible = wasVisible end
        end
        -- The deployed objects shown in Dex are PlanterBulb models under
        -- Workspace.Planters. Their Name is not necessarily the planter type;
        -- the type comes from GuiAttach > PlanterGui > Bar > TextLabel.
        local function attachedGui(model)
            if not model then return nil end
            -- Dex shows actual names "Gui Attach" > "Planter Gui" in some
            -- servers; older builds used "GuiAttach" > "PlanterGui".
            -- Normalize whitespace/punctuation rather than exact FindFirstChild.
            local descendants = model:GetDescendants()
            for _, obj in ipairs(descendants) do
                if norm(obj.Name) == "guiattach" then
                    for _, child in ipairs(obj:GetDescendants()) do
                        if norm(child.Name) == "plantergui" then
                            return child
                        end
                    end
                end
            end
            -- Some game builds parent the BillboardGui directly to the bulb.
            for _, obj in ipairs(descendants) do
                if norm(obj.Name) == "plantergui" then return obj end
            end
            return nil
        end
        local function planterText(model)
            local gui = attachedGui(model)
            if not gui then return nil end
            local bar = gui:FindFirstChild("Bar", true)
            local name = bar and bar:FindFirstChild("TextLabel", true)
            if name and name:IsA("TextLabel") and name.Text ~= "" then
                return name.Text
            end
            for _, obj in ipairs(gui:GetDescendants()) do
                if obj:IsA("TextLabel") and obj.Text:find("Planter", 1, true) then
                    return obj.Text
                end
            end
            return nil
        end
        local function planterType(model)
            local shown = planterText(model)
            local name = shown and shown:match("^%s*(.-)%s*%(%s*[%d%.]+%s*%%%s*%)")
            if not name or name == "" then
                name = shown and shown:match("^%s*(.-)%s*%(")
            end
            if name and name ~= "" then return canonical(name) end
            if model and norm(model.Name) ~= "planterbulb" then
                return canonical(model.Name)
            end
            local parent = model and model.Parent
            if parent and norm(parent.Name):find("planter", 1, true)
                and norm(parent.Name) ~= "planters" then
                return canonical(parent.Name)
            end
            return "Unknown Planter"
        end
        local function activeModels()
            local folder = workspace:FindFirstChild("Planters")
            local result = {}
            if not folder then return result end
            -- Named templates also live under Planters. Only actual bulbs with
            -- a GrowthPercent ValueBase represent deployed instances.
            for _, model in ipairs(folder:GetDescendants()) do
                if norm(model.Name) == "planterbulb"
                    and (model:IsA("Model") or model:IsA("BasePart")) then
                    local value = model:FindFirstChild("GrowthPercent", true)
                    if value and value:IsA("ValueBase") then
                        table.insert(result, model)
                    end
                end
            end
            -- Older game layouts may put GrowthPercent inside a typed model.
            if #result == 0 then
                for _, model in ipairs(folder:GetChildren()) do
                    local value = model:FindFirstChild("GrowthPercent", true)
                    if value and value:IsA("ValueBase") then
                        table.insert(result, model)
                    end
                end
            end
            return result
        end
        local function mine(model)
            -- On this client's Dex layout only personal planters have their
            -- attached PlanterGui. Never assume an unknown owner is ours.
            if not attachedGui(model) then return false end
            for _, key in ipairs({"Owner", "Player", "OwnerUserId", "UserId"}) do
                local val = model:GetAttribute(key)
                local child = model:FindFirstChild(key, true)
                if val == nil and child and child:IsA("ValueBase") then val = child.Value end
                if val ~= nil then
                    return val == player or tostring(val) == player.Name
                        or tostring(val) == tostring(player.UserId)
                end
            end
            return true
        end
        local function modelPosition(model)
            if not model or not model.Parent then return nil end
            if model:IsA("BasePart") then return model.Position end
            local soil = model:FindFirstChild("Soil", true)
            if soil and soil:IsA("BasePart") then return soil.Position end
            local bulb = model:FindFirstChild("PlanterBulb", true)
            if bulb and bulb:IsA("BasePart") then return bulb.Position end
            if bulb and bulb:IsA("Model") then return bulb:GetPivot().Position end
            if model:IsA("Model") then return model:GetPivot().Position end
            local base = model:FindFirstChildWhichIsA("BasePart", true)
            return base and base.Position or nil
        end
        local function fieldFor(model)
            local pos = modelPosition(model)
            if not pos then return nil end
            for _, field in ipairs(fieldObjects) do
                if insideField(field, pos, 0) then return field.Name end
            end
            return nil
        end
        local function progress(model)
            -- GrowthPercent is a ratio (e.g. 0.501 = 50.1%). It is the primary
            -- numeric source. The attached label is a fallback and type source.
            local bulb = model.Name == "PlanterBulb" and model
                or model:FindFirstChild("PlanterBulb", true) or model
            local v = bulb:FindFirstChild("GrowthPercent", true)
            if v and v:IsA("ValueBase") then
                local number = tonumber(v.Value)
                if number then
                    return math.clamp(number <= 1 and number * 100 or number, 0, 100)
                end
            end
            local shown = planterText(model)
            local number = shown and tonumber(shown:match("(%d+%.?%d*)%s*%%"))
            return number and math.clamp(number, 0, 100) or nil
        end
        local function findModel(typ)
            for _, model in ipairs(activeModels()) do
                if mine(model) and norm(planterType(model)) == norm(typ) then
                    return model
                end
            end
            return nil
        end
        local function ownedTypes()
            local names = inventoryRows()
            for _, model in ipairs(activeModels()) do
                if mine(model) then
                    local typ = planterType(model)
                    if norm(typ) ~= "unknownplanter" then
                        names[norm(typ)] = typ
                    end
                end
            end
            local result = {}
            for _, name in pairs(names) do table.insert(result, name) end
            table.sort(result, function(a, b) return a:lower() < b:lower() end)
            return result
        end
        local function renderLive()
            local mineNow = {}
            local detectedBulbs = activeModels()
            for _, model in ipairs(detectedBulbs) do
                if mine(model) then table.insert(mineNow, model) end
            end
            table.sort(mineNow, function(a, b)
                return planterType(a):lower() < planterType(b):lower()
            end)
            local count = #mineNow
            liveSummary.Text = string.format("MY PLANTERS: %d/3   |   HARVEST TARGET: %d%%",
                count, state.HarvestAt)
            counter.Text = string.format("Slots: %d/3   |   Active: %d/3",
                #state.Slots, count)
            for i, row in ipairs(liveRows) do
                local model = mineNow[i]
                row.Card.Visible = model ~= nil
                if model then
                    local p = progress(model)
                    local typ = planterType(model)
                    local field = fieldFor(model) or "Field unknown"
                    local percentage = p and string.format("%.1f%%", p) or "??%"
                    local remaining = p and math.max(0, state.HarvestAt - p) or nil
                    local ready = p and p >= state.HarvestAt
                    row.Name.Text = string.format("%d. %s    |    %s", i, typ, field)
                    if not p then
                        row.Detail.Text = "GrowthPercent unavailable; check PlanterBulb"
                        row.Detail.TextColor3 = palette.alert
                    elseif ready then
                        row.Detail.Text = "GROWTH " .. percentage .. "   |   READY TO HARVEST"
                        row.Detail.TextColor3 = Color3.fromRGB(123, 236, 167)
                    else
                        row.Detail.Text = string.format(
                            "GROWTH %s   |   %.1f%% until harvest", percentage, remaining)
                        row.Detail.TextColor3 = palette.muted
                    end
                    row.Fill.Size = UDim2.fromScale(math.clamp((p or 0) / 100, 0, 1), 1)
                    row.Fill.BackgroundColor3 = ready and Color3.fromRGB(123, 236, 167)
                        or palette.accent
                end
            end
            if count == 0 then
                liveSummary.Text = string.format(
                    "MY PLANTERS: 0/3   |   Found %d bulbs; no personal GUI",
                    #detectedBulbs)
            end
        end
        local function selectedIndex(typ)
            for index, config in ipairs(state.Slots) do
                if norm(config.Type) == norm(typ) then return index end
            end
            return nil
        end
        local function renderTypes()
            local types = ownedTypes()
            local signature = table.concat(types, "|")
            if signature == state.LastSignature then return end
            state.LastSignature = signature
            clearList(typeList)
            for i, typ in ipairs(types) do
                local b = button(typeList, typ, 0, 0, 207, 27)
                b.LayoutOrder = i
                b.TextXAlignment = Enum.TextXAlignment.Left
                b.Activated:Connect(function()
                    state.PendingType = typ
                    updatePending()
                    renderTypes() -- signature is unchanged; color applied below
                    for _, child in ipairs(typeList:GetChildren()) do
                        if child:IsA("TextButton") then
                            child.BackgroundColor3 = child.Text == typ and palette.green or palette.surface
                        end
                    end
                    if state.PendingField then showRewards({Type = typ, Field = state.PendingField}) end
                end)
                b.BackgroundColor3 = typ == state.PendingType and palette.green or palette.surface
            end
            if #types == 0 then
                local bulbs = activeModels()
                if #bulbs > 0 then
                    setStatus(string.format(
                        "Thấy %d PlanterBulb nhưng chưa nhận diện được GUI sở hữu.",
                        #bulbs))
                else
                    setStatus("Chưa đọc được Planter. Mở Inventory > Eggs một lần rồi quay lại Plant.")
                end
            end
        end
        local function renderFields()
            clearList(fieldList)
            for i, field in ipairs(fieldObjects) do
                local b = button(fieldList, fieldIconName(field.Name) .. " " .. field.Name,
                    0, 0, 137, 28)
                b.TextXAlignment = Enum.TextXAlignment.Left
                b.TextSize = 11
                b.LayoutOrder = i
                b.BackgroundColor3 = state.PendingField == field.Name and palette.green or palette.surface
                b.Activated:Connect(function()
                    state.PendingField = field.Name
                    for _, obj in ipairs(fieldList:GetChildren()) do
                        if obj:IsA("TextButton") then obj.BackgroundColor3 = palette.surface end
                    end
                    b.BackgroundColor3 = palette.green
                    updatePending()
                    if state.PendingType then showRewards({Type = state.PendingType, Field = field.Name}) end
                end)
            end
        end
        local function renderSlots()
            local parts = {}
            for _, cfg in ipairs(state.Slots) do
                local active = findModel(cfg.Type)
                local p = active and progress(active)
                table.insert(parts, slotKey(cfg) .. "=" .. tostring(p and math.floor(p * 10) / 10 or "none"))
            end
            local signature = table.concat(parts, "|")
            if state.SlotSignature == signature then return end
            state.SlotSignature = signature
            clearList(slotList)
            for i, config in ipairs(state.Slots) do
                local deployed = findModel(config.Type)
                local grow = deployed and progress(deployed)
                local note = deployed and string.format("%.1f%%", grow or 0) or "not placed"
                local frame = button(slotList,
                    string.format("#%d %s\n%s | %s", i, config.Type, config.Field, note),
                    0, 0, 123, 47)
                frame.LayoutOrder = i
                frame.TextSize = 10
                frame.TextXAlignment = Enum.TextXAlignment.Left
                local key = slotKey(config)
                frame.MouseEnter:Connect(function()
                    state.HoverKey = key
                    showRewards(config)
                end)
                frame.MouseLeave:Connect(function()
                    if state.HoverKey == key then
                        state.HoverKey = nil
                        if state.PendingType and state.PendingField then
                            showRewards({Type = state.PendingType, Field = state.PendingField})
                        else
                            showRewards(nil)
                        end
                    end
                end)
                frame.Activated:Connect(function() showRewards(config) end)
                local remove = button(frame, "×", 101, 3, 19, 19)
                remove.BackgroundColor3 = Color3.fromRGB(117, 47, 53)
                remove.Activated:Connect(function()
                    for index, item in ipairs(state.Slots) do
                        if slotKey(item) == key then table.remove(state.Slots, index); break end
                    end
                    state.RetryAt[key] = nil
                    state.HoverKey = nil
                    renderSlots()
                    showRewards(nil)
                    setStatus("Đã xóa Slot " .. i)
                end)
            end
            if state.HoverKey then
                for _, cfg in ipairs(state.Slots) do
                    if slotKey(cfg) == state.HoverKey then showRewards(cfg); break end
                end
            end
        end
        local function addSlot()
            if not state.PendingType or not state.PendingField then
                setStatus("Chưa chọn đủ PLANTER + FIELD.")
                return
            end
            if selectedIndex(state.PendingType) then
                setStatus("Loại planter này đã có trong Slots (game không đặt 2 cùng loại).")
                return
            end
            if #state.Slots >= 3 then setStatus("Tối đa 3 Slots."); return end
            for _, slot in ipairs(state.Slots) do
                if slot.Field == state.PendingField then
                    setStatus("Field này đã được gán cho một Slot khác.")
                    return
                end
            end
            local config = {Type = canonical(state.PendingType), Field = state.PendingField}
            table.insert(state.Slots, config)
            state.RetryAt[slotKey(config)] = 0
            renderSlots()
            showRewards(config)
            setStatus("Thêm Slot " .. #state.Slots .. ": " .. config.Type .. " @ " .. config.Field)
        end
        okButton.Activated:Connect(addSlot)
        percentBox.FocusLost:Connect(function()
            state.HarvestAt = math.clamp(math.floor((tonumber(percentBox.Text) or 100) + .5), 1, 100)
            percentBox.Text = tostring(state.HarvestAt)
            if state.PendingType and state.PendingField then
                showRewards({Type = state.PendingType, Field = state.PendingField})
            end
        end)
        local function allowed(epoch)
            return state.Enabled and state.Epoch == epoch
                and CombatSignals.PlanterBusy and screen.Parent ~= nil
        end
        local function moveToPoint(point, epoch)
            if not point or not allowed(epoch) then return false end
            local humanoid, root = getHumanoidAndRoot()
            if not humanoid or humanoid.Health <= 0 then return false end
            local target = point + Vector3.new(0, 2.6, 0)
            local path = {}
            if (root.Position - target).Magnitude > 22 then
                local y = math.max(root.Position.Y, target.Y) + 17
                table.insert(path, Vector3.new(root.Position.X, y, root.Position.Z))
                table.insert(path, Vector3.new(target.X, y, target.Z))
            end
            table.insert(path, target)
            return SmoothFlight.Path(root, path, function() return allowed(epoch) end, TweenSpeed)
        end
        local function actorIdOf(model)
            for _, key in ipairs({"ActorID", "ActorId", "PlanterID", "PlanterId"}) do
                local value = model:GetAttribute(key)
                local obj = model:FindFirstChild(key, true)
                if value == nil and obj and obj:IsA("ValueBase") then value = obj.Value end
                if value ~= nil then return value end
            end
            -- Some BSS versions keep the IDs only in ReplicatedStorage.LocalPlanters.
            -- Optional compatibility with executors supporting debug.getupvalues.
            local module = ReplicatedStorage:FindFirstChild("LocalPlanters")
            local debugger = debug
            if not module or not module:IsA("ModuleScript") or type(debugger) ~= "table"
                or type(debugger.getupvalues) ~= "function" then return nil end
            local ok, loaded = pcall(require, module)
            if not ok or type(loaded) ~= "table" or type(loaded.LoadPlanter) ~= "function" then return nil end
            local valid, values = pcall(debugger.getupvalues, loaded.LoadPlanter)
            if not valid or type(values) ~= "table" then return nil end
            for _, t in pairs(values) do
                if type(t) == "table" then
                    for _, meta in pairs(t) do
                        if type(meta) == "table" and meta.IsMine == true and meta.ActorID ~= nil
                            and norm(meta.Type) == norm(planterType(model)) then
                            return meta.ActorID
                        end
                    end
                end
            end
            return nil
        end
        local function collectPlanter(model, epoch)
            local pos = modelPosition(model)
            if not pos then return false, "Không tìm thấy vị trí Planter" end
            if not moveToPoint(pos, epoch) then return false, "Không tới được Planter" end
            local actorId = actorIdOf(model)
            local events = ReplicatedStorage:FindFirstChild("Events")
            local remote = events and events:FindFirstChild("PlanterModelCollect")
            for attempt = 1, 4 do
                if not allowed(epoch) then return false, "Đã hủy" end
                setStatus(string.format("Thu hoạch %s (lần %d/4)", planterType(model), attempt))
                if actorId ~= nil and remote and remote:IsA("RemoteEvent") then
                    pcall(function() remote:FireServer(actorId) end)
                else
                    -- Fallback for setups without visible ActorID.
                    pcall(function()
                        VIM:SendKeyEvent(true, Enum.KeyCode.E, false, game)
                        task.wait(.12)
                        VIM:SendKeyEvent(false, Enum.KeyCode.E, false, game)
                    end)
                end
                local deadline = os.clock() + 2.0
                while allowed(epoch) and os.clock() < deadline do
                    if not model.Parent then return true end
                    task.wait(.12)
                end
            end
            return false, actorId == nil and "Không có ActorID; nhấn E không được game xác nhận"
                or "Game chưa xác nhận thu hoạch (đã thử 4 lần)"
        end
        local function placePlanter(config, epoch)
            local field = FlowerZones:FindFirstChild(config.Field)
            if not field then return false, "Không tìm được Field " .. config.Field end
            if findModel(config.Type) then return false, "Planter đã được đặt" end
            local total = 0
            for _, other in ipairs(activeModels()) do
                if mine(other) then
                    total += 1
                    if fieldFor(other) == config.Field then
                        return false, "Field đã có planter: " .. planterType(other)
                    end
                end
            end
            if total >= 3 then return false, "Game đã có 3 planter đang đặt" end
            local position = fieldCenter(field)
            if not moveToPoint(position, epoch) then return false, "Bay tới field thất bại" end
            local events = ReplicatedStorage:FindFirstChild("Events")
            local remote = events and events:FindFirstChild("PlayerActivesCommand")
            if not remote or not remote:IsA("RemoteEvent") then
                return false, "Không thấy Events.PlayerActivesCommand"
            end
            local itemName = canonical(config.Type)
            setStatus("Đặt " .. itemName .. " tại " .. config.Field .. " ...")
            local ok, err = pcall(function() remote:FireServer({Name = itemName}) end)
            if not ok then return false, tostring(err) end
            local deadline = os.clock() + 5
            while allowed(epoch) and os.clock() < deadline do
                local newModel = findModel(config.Type)
                if newModel and fieldFor(newModel) == config.Field then return true end
                task.wait(.15)
            end
            return false, "Không xác nhận được planter mới; kiểm tra số lượng Inventory/địa điểm"
        end
        local function claimMovement()
            if not state.Enabled or state.Busy or CombatSignals.PlanterBusy
                or CombatController.IsBusy() or not CombatController.CanPlanterRun()
                or (CombatSignals.QuestIsBusy and CombatSignals.QuestIsBusy()) then return nil end
            state.Busy = true
            state.ManualOverride = false
            CombatSignals.PlanterBusy = true
            local prevFarm = farmEnabled
            if farmEnabled then
                farmEnabled = false
                farmToken += 1
                preciseProgress = nil
                if currentFarmTravelTween then
                    currentFarmTravelTween:Cancel()
                    currentFarmTravelTween = nil
                end
                stopWalking()
                paintFarm(false)
            end
            return {Epoch = state.Epoch, FarmStamp = farmToken, ResumeFarm = prevFarm}
        end
        local function releaseMovement(handle)
            state.Busy = false
            CombatSignals.PlanterBusy = false
            if handle and handle.ResumeFarm and not state.ManualOverride
                and screen.Parent and not farmEnabled and farmToken == handle.FarmStamp
                and selectedField then
                farmEnabled = true
                farmToken += 1
                local token = farmToken
                paintFarm(true)
                task.spawn(function()
                    local ok, err = pcall(runFarm, token)
                    if not ok then warn("[BSS Planter Restore Farm]", err) end
                    if farmToken == token then
                        farmEnabled = false
                        paintFarm(false)
                        stopWalking()
                    end
                end)
            end
        end
        local function operate(config)
            local handle = claimMovement()
            if not handle then return end
            local epoch = handle.Epoch
            local ok, worked, message = pcall(function()
                local deployed = findModel(config.Type)
                if deployed then
                    local value = progress(deployed)
                    if not value then return false, "Không đọc được GrowthPercent" end
                    if value < state.HarvestAt then return true, "Đang lớn " .. string.format("%.1f%%", value) end
                    local before = LootTools.Snapshot()
                    local center = modelPosition(deployed)
                    local field = fieldFor(deployed)
                    local collected, why = collectPlanter(deployed, epoch)
                    if not collected then return false, why end
                    setStatus("Đang nhặt token từ planter ...")
                    if center and allowed(epoch) then
                        LootTools.CollectNew({Center = center, Radius = 46, Duration = 28,
                            DropGrace = 3.4, QuietPeriod = 1.4,
                            Before = before, Source = "Planter", Field = field and FlowerZones:FindFirstChild(field),
                            Allowed = function() return allowed(epoch) and not farmEnabled end,
                            Report = setStatus})
                    end
                    if not allowed(epoch) then return false, "Đã hủy" end
                    local planted, reason = placePlanter(config, epoch)
                    return planted, planted and ("Thu hoạch và trồng lại " .. config.Type)
                        or ("Đã thu hoạch, chưa trồng lại: " .. tostring(reason))
                end
                return placePlanter(config, epoch)
            end)
            releaseMovement(handle)
            local key = slotKey(config)
            state.RetryAt[key] = os.clock() + ((ok and worked) and 5 or 18)
            if not ok then
                warn("[BSS Auto Planter]", worked)
                setStatus("Plant lỗi: " .. tostring(worked))
            elseif worked then
                setStatus(message or ("Đã xử lý " .. config.Type))
            else
                setStatus(config.Type .. ": " .. tostring(message))
            end
        end
        CombatSignals.CancelPlanter = function()
            if not state.Busy then return end
            state.Epoch += 1
            state.ManualOverride = true
            state.ReentryAt = os.clock() + 8
            SmoothFlight.Cancel()
            setStatus("Đã nhường di chuyển cho Farm thủ công; Auto Planter sẽ tiếp tục sau.")
        end
        autoButton.Activated:Connect(function()
            if not state.Enabled and #state.Slots == 0 then
                setStatus("Chưa có Slot. Chọn Planter + Field → OK trước khi bật Auto.")
                return
            end
            state.Enabled = not state.Enabled
            state.Epoch += 1
            autoButton.Text = state.Enabled and "AUTO PLANTER: ON" or "AUTO PLANTER: OFF"
            autoButton.BackgroundColor3 = state.Enabled and palette.green or palette.surface
            if not state.Enabled then
                if state.Busy then SmoothFlight.Cancel() end
                setStatus("Auto Planter đã tắt")
            else
                for _, config in ipairs(state.Slots) do state.RetryAt[slotKey(config)] = 0 end
                setStatus("Auto Planter ON: kiểm tra " .. #state.Slots .. " Slot(s)...")
            end
        end)
        ConfigManager.Register("Planter", function()
            local saved = {}
            for _, cfg in ipairs(state.Slots) do
                table.insert(saved, {Type = cfg.Type, Field = cfg.Field})
            end
            return {Slots = saved, HarvestAt = state.HarvestAt}
        end, function(data)
            local threshold = tonumber(data.HarvestAt)
            if threshold then
                state.HarvestAt = math.clamp(math.floor(threshold + .5), 1, 100)
                percentBox.Text = tostring(state.HarvestAt)
            end
            if type(data.Slots) == "table" then
                local accepted, usedType, usedField = {}, {}, {}
                for _, item in ipairs(data.Slots) do
                    if #accepted >= 3 then break end
                    if type(item) == "table" and type(item.Type) == "string"
                        and type(item.Field) == "string"
                        and FlowerZones:FindFirstChild(item.Field) then
                        local key = norm(item.Type)
                        if not usedType[key] and not usedField[item.Field] then
                            usedType[key], usedField[item.Field] = true, true
                            table.insert(accepted, {Type = canonical(item.Type), Field = item.Field})
                        end
                    end
                end
                state.Slots = accepted
                state.RetryAt = {}
                renderSlots()
                setStatus("Đã nạp " .. #accepted .. " planter slots. Bật Auto thủ công khi cần.")
            end
        end)
        renderFields()
        renderTypes()
        renderSlots()
        renderLive()
        updatePending()
        task.spawn(function()
            while screen.Parent do
                if selectedTab == "Plant" then
                    if not next(inventoryRows()) then ensureInventoryOpen() end
                    renderTypes()
                    if os.clock() - state.LastUiUpdate >= 0.8 then
                        renderSlots()
                        renderLive()
                        state.LastUiUpdate = os.clock()
                    end
                end
                if state.Enabled and #state.Slots == 0 then
                    state.Enabled = false
                    autoButton.Text = "AUTO PLANTER: OFF"
                    autoButton.BackgroundColor3 = palette.surface
                    setStatus("Đã xóa hết Slots; Auto Planter tự tắt.")
                end
                if state.Enabled and not state.Busy and #state.Slots > 0
                    and os.clock() >= state.ReentryAt then
                    local busy = CombatController.IsBusy()
                        or not CombatController.CanPlanterRun()
                        or (CombatSignals.QuestIsBusy and CombatSignals.QuestIsBusy())
                    if busy then
                        if os.clock() - state.LastStatusAt >= 3 then
                            state.LastStatusAt = os.clock()
                            setStatus("Auto ON: chờ Combat/Quest hoàn tất để xử lý planter")
                        end
                    else
                        local waiting = nil
                        for _, config in ipairs(state.Slots) do
                            if not state.Enabled then break end
                            local model = findModel(config.Type)
                            local current = model and progress(model)
                            if not model or (current and current >= state.HarvestAt) then
                                if os.clock() >= (state.RetryAt[slotKey(config)] or 0) then
                                    operate(config)
                                    break
                                end
                            elseif current ~= nil then
                                waiting = string.format("%s @ %s: %.1f%%/%d%%",
                                    config.Type, fieldFor(model) or config.Field,
                                    current, state.HarvestAt)
                            else
                                waiting = "Có Planter nhưng chưa đọc được GrowthPercent: " .. config.Type
                            end
                        end
                        if waiting and not state.Busy and os.clock() - state.LastStatusAt >= 3 then
                            state.LastStatusAt = os.clock()
                            setStatus("Đang theo dõi: " .. waiting)
                        end
                    end
                end
                task.wait(.7)
            end
        end)
        screen.Destroying:Connect(function()
            state.Enabled = false
            state.Epoch += 1
            CombatSignals.PlanterBusy = false
            CombatSignals.CancelPlanter = nil
        end)
    end
    initializePlantManager()
end

-- AUTO CLICK: VIRTUAL CLICKS OUTSIDE SCRIPT MENU; DO NOT MOVE CURSOR
local function clickPosition()
    local camera = workspace.CurrentCamera
    if not camera then return nil end
    local v = camera.ViewportSize
    local w, h = math.floor(v.X), math.floor(v.Y)
    local p, s = window.AbsolutePosition, window.AbsoluteSize
    for _, candidate in ipairs({
        {w - 8, math.floor(h / 2)},
        {w - 8, h - 8}, {8, h - 8},
        {8, 8}, {math.floor(w / 2), math.floor(h / 2)}
    }) do
        local x, y = candidate[1], candidate[2]
        local overWindow = window.Visible
            and x >= p.X and x <= p.X + s.X
            and y >= p.Y and y <= p.Y + s.Y
        local op, os = showMenu.AbsolutePosition, showMenu.AbsoluteSize
        local overShow = showMenu.Visible
            and x >= op.X and x <= op.X + os.X
            and y >= op.Y and y <= op.Y + os.Y
        if x >= 0 and y >= 0 and x < w and y < h
            and not overWindow and not overShow then
            return x, y
        end
    end
    return nil
end
local function virtualClick()
    local x, y = clickPosition()
    if not x then return end
    VIM:SendMouseButtonEvent(x, y, 0, true, game, 0)
    task.wait(0.03)
    VIM:SendMouseButtonEvent(x, y, 0, false, game, 0)
end
clickHit.Activated:Connect(function()
    clickEnabled = not clickEnabled
    clickToken += 1
    local token = clickToken
    paintClick(clickEnabled)
    if not clickEnabled then return end
    task.spawn(function()
        while clickEnabled and token == clickToken and screen.Parent do
            local ok, err = pcall(virtualClick)
            if not ok then
                warn("[BSS Auto Click]", err)
                if token == clickToken then
                    clickEnabled = false
                    paintClick(false)
                end
                return
            end
            task.wait(0.1)
        end
    end)
end)

screen.Destroying:Connect(function()
    farmEnabled = false
    clickEnabled = false
    farmToken += 1
    clickToken += 1
    if currentHiveTween then currentHiveTween:Cancel() end
    if currentFarmTravelTween then currentFarmTravelTween:Cancel() end
    SmoothFlight.Cancel()
    CombatSignals.LootBusy = false
    CombatSignals.AvoidMob = nil
    stopWalking()
    resetFacing()
    if facingConnection then facingConnection:Disconnect() end
    trackedDupedFolder = nil
    unbindCrosshairFolder()
    for _, connection in ipairs(dragConnections) do
        connection:Disconnect()
    end
end)

-- v8.4 PERSISTENT CONFIG: Save/Load JSON, clipboard export & paste import,
-- Auto Load on next execution if executor provides readfile/writefile.
-- Isolated function avoids the top-level Luau 200-local-register ceiling.
do
    local function initializeConfigUI()
        local HttpService = game:GetService("HttpService")
        local page = pages.Config
        local filename = "BSS_FieldManager_v8_Config.json"
        local bg, edge = Color3.fromRGB(24, 27, 35), Color3.fromRGB(151, 91, 255)
        local function button(text, x, y, w, h)
            local obj = ui("TextButton", {
                Position = UDim2.fromOffset(x, y), Size = UDim2.fromOffset(w, h),
                BackgroundColor3 = bg, TextColor3 = white,
                Text = text, Font = Enum.Font.GothamBold, TextSize = 12,
                BorderColor3 = edge, BorderSizePixel = 1,
            }, page)
            ui("UICorner", {CornerRadius = UDim.new(0, 4)}, obj)
            return obj
        end
        ui("TextLabel", {
            Position = UDim2.fromOffset(12, 88), Size = UDim2.fromOffset(536, 24),
            BackgroundTransparency = 1, Text = "CONFIG  |  JSON PROFILES",
            TextColor3 = white, Font = Enum.Font.GothamBold, TextSize = 16,
            TextXAlignment = Enum.TextXAlignment.Left,
        }, page)
        local save = button("SAVE", 12, 117, 100, 27)
        local load = button("LOAD", 120, 117, 100, 27)
        local export = button("EXPORT JSON", 228, 117, 150, 27)
        local import = button("IMPORT JSON", 386, 117, 161, 27)
        local autoload = button("AUTO LOAD  ✔", 12, 153, 157, 26)
        local location = ui("TextLabel", {
            Position = UDim2.fromOffset(180, 153), Size = UDim2.fromOffset(367, 28),
            BackgroundTransparency = 1, TextColor3 = Color3.fromRGB(174, 182, 199),
            Font = Enum.Font.Gotham, TextSize = 11, TextXAlignment = Enum.TextXAlignment.Left,
            Text = filename, TextTruncate = Enum.TextTruncate.AtEnd,
        }, page)
        local jsonBox = ui("TextBox", {
            Name = "ConfigJsonEditor", Position = UDim2.fromOffset(12, 186),
            Size = UDim2.new(1, -25, 0, 126), BackgroundColor3 = bg,
            BorderColor3 = edge, BorderSizePixel = 1,
            TextColor3 = white, Font = Enum.Font.Code, TextSize = 12,
            ClearTextOnFocus = false, MultiLine = true, TextWrapped = false,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextYAlignment = Enum.TextYAlignment.Top,
            PlaceholderText = "JSON export hiện tại đây. Dán JSON rồi nhấn IMPORT.",
            Text = "",
        }, page)
        local status = ui("TextLabel", {
            Position = UDim2.fromOffset(12, 317), Size = UDim2.new(1, -24, 0, 49),
            BackgroundTransparency = 1, Text = "SAVE = lưu file; EXPORT = JSON/clipboard.",
            TextColor3 = Color3.fromRGB(175, 190, 209), TextSize = 12,
            Font = Enum.Font.Gotham, TextWrapped = true,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextYAlignment = Enum.TextYAlignment.Top,
        }, page)
        local function notify(msg)
            status.Text = tostring(msg)
        end
        local function updateAutoload()
            autoload.Text = ConfigManager.AutoLoad and "AUTO LOAD  ✔" or "AUTO LOAD  ✕"
            autoload.BackgroundColor3 = ConfigManager.AutoLoad
                and Color3.fromRGB(27, 86, 58) or bg
        end
        local function decode(raw)
            local ok, data = pcall(function() return HttpService:JSONDecode(raw) end)
            if not ok then return nil, "Invalid JSON: " .. tostring(data) end
            if type(data) ~= "table" or type(data.Sections) ~= "table" then
                return nil, "Expected object with Sections"
            end
            return data
        end
        local function readConfig()
            if type(readfile) ~= "function" then
                return nil, "Executor does not support readfile"
            end
            local ok, raw = pcall(readfile, filename)
            if not ok or type(raw) ~= "string" or raw == "" then
                return nil, "No saved config or file inaccessible"
            end
            return decode(raw)
        end
        local function writeConfig()
            if type(writefile) ~= "function" then
                return false, "Executor does not support writefile; use Export JSON"
            end
            local data = ConfigManager.Capture()
            local ok, raw = pcall(function() return HttpService:JSONEncode(data) end)
            if not ok then return false, tostring(raw) end
            local saved, err = pcall(writefile, filename, raw)
            if not saved then return false, tostring(err) end
            return true, "Saved " .. filename
        end
        save.Activated:Connect(function()
            local ok, msg = writeConfig()
            notify((ok and "✓ " or "✗ ") .. msg)
        end)
        load.Activated:Connect(function()
            local data, err = readConfig()
            if not data then notify("✗ " .. tostring(err)); return end
            local ok, msg = ConfigManager.Apply(data)
            updateAutoload()
            notify((ok and "✓ " or "✗ ") .. msg)
        end)
        export.Activated:Connect(function()
            local ok, raw = pcall(function()
                return HttpService:JSONEncode(ConfigManager.Capture())
            end)
            if not ok then notify("✗ JSONEncode: " .. tostring(raw)); return end
            jsonBox.Text = raw
            if type(setclipboard) == "function" then
                local copied = pcall(setclipboard, raw)
                notify(copied and "✓ JSON copied to clipboard and shown below"
                    or "✓ JSON shown below; clipboard unavailable")
            else
                notify("✓ JSON shown below. Select and copy text to export.")
            end
        end)
        import.Activated:Connect(function()
            local data, err = decode(jsonBox.Text)
            if not data then notify("✗ " .. tostring(err)); return end
            local ok, msg = ConfigManager.Apply(data)
            updateAutoload()
            notify((ok and "✓ " or "✗ ") .. msg
                .. ". Use SAVE if you want it on next launch.")
        end)
        autoload.Activated:Connect(function()
            ConfigManager.AutoLoad = not ConfigManager.AutoLoad
            updateAutoload()
            local ok, msg = writeConfig()
            notify(ok and ("✓ Auto Load preference saved: " .. tostring(ConfigManager.AutoLoad))
                or ("Auto Load changed for this run. " .. tostring(msg)))
        end)
        -- Read preference even when automatic restoration is disabled.
        local data, err = readConfig()
        if data then
            if type(data.AutoLoad) == "boolean" then
                ConfigManager.AutoLoad = data.AutoLoad
            end
            updateAutoload()
            if ConfigManager.AutoLoad then
                local ok, msg = ConfigManager.Apply(data)
                notify((ok and "✓ Auto Load: " or "✗ Auto Load: ") .. tostring(msg))
            else
                notify("Auto Load OFF: profile exists; press LOAD to restore manually")
            end
        else
            updateAutoload()
            notify("No existing config. " .. tostring(err)
                .. ". Use SAVE or export JSON.")
        end
    end
    initializeConfigUI()
end

-- v8.6: Live-update control surface. The loader lives independently in getgenv().
-- This card is reparented into the Config accordion by buildMidnightUI().
do
    local area = pages.Config
    local function createLiveButton(label, x, y, width)
        local button = ui("TextButton", {
            Name = "Live" .. label:gsub("%W", "") .. "Button",
            Position = UDim2.fromOffset(x, y), Size = UDim2.fromOffset(width, 27),
            BackgroundColor3 = Color3.fromRGB(30, 43, 63),
            BorderSizePixel = 0, Text = label, TextColor3 = white,
            Font = Enum.Font.GothamBold, TextSize = 12,
        }, area)
        ui("UICorner", {CornerRadius = UDim.new(0, 5)}, button)
        return button
    end
    local check = createLiveButton("CHECK UPDATE", 12, 397, 163)
    local toggle = createLiveButton("AUTO UPDATE ON", 183, 397, 175)
    local status = ui("TextLabel", {
        Name = "LiveUpdateStatus", Position = UDim2.fromOffset(12, 430),
        Size = UDim2.new(1, -26, 0, 36), BackgroundTransparency = 1,
        TextColor3 = Color3.fromRGB(172, 189, 209), TextSize = 12,
        Font = Enum.Font.Gotham, TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
        Text = "Live loader not detected. Start FieldLab_QuickStart.lua once.",
    }, area)
    local function getLoader()
        local env = (type(getgenv) == "function" and getgenv()) or _G
        return env.__FIELDLAB_LOADER
    end
    check.Activated:Connect(function()
        local loader = getLoader()
        if loader and type(loader.CheckNow) == "function" then
            task.spawn(loader.CheckNow)
        else
            status.Text = "Loader offline. Run FieldLab_QuickStart.lua."
        end
    end)
    toggle.Activated:Connect(function()
        local loader = getLoader()
        if loader then
            loader.Auto = not loader.Auto
        else
            status.Text = "Loader offline."
        end
    end)
    task.spawn(function()
        while screen.Parent do
            local loader = getLoader()
            if loader then
                toggle.Text = loader.Auto and "AUTO UPDATE ON" or "AUTO UPDATE OFF"
                status.Text = "v" .. tostring(loader.LastVersion or "8.6.10") .. "  |  "
                    .. tostring(loader.Status or "Running")
            end
            task.wait(0.7)
        end
    end)
end

-- v8.5 / MIDNIGHT UI OVERHAUL
-- Uses a navigational sidebar, top bar and responsive accordions. The automation
-- modules and their existing button handlers are preserved without replacement.
-- All content tabs now have actual scrollable canvas height, with touch/mouse wheel
-- scrolling and additional discrete scroll controls as a fallback.
do
    local function buildMidnightUI()
        local C = {
            background = Color3.fromRGB(11, 17, 27),
            sidebar = Color3.fromRGB(15, 23, 36),
            header = Color3.fromRGB(18, 27, 41),
            card = Color3.fromRGB(22, 32, 48),
            raised = Color3.fromRGB(31, 43, 62),
            hover = Color3.fromRGB(38, 52, 75),
            border = Color3.fromRGB(51, 66, 87),
            text = Color3.fromRGB(230, 237, 247),
            soft = Color3.fromRGB(168, 183, 203),
            accent = Color3.fromRGB(142, 117, 255),
            success = Color3.fromRGB(77, 225, 173),
        }

        window.Size = UDim2.fromOffset(730, 414)
        window.BackgroundColor3 = C.background
        window.BorderSizePixel = 0
        window.ClipsDescendants = false
        local outline = window:FindFirstChildOfClass("UIStroke")
        if outline then outline.Color = C.border; outline.Thickness = 1 end
        ui("UICorner", {CornerRadius = UDim.new(0, 11)}, window)
        for _, ch in ipairs(window:GetChildren()) do
            if ch:IsA("Frame") and ch.Size.X.Offset == 1
                and ch.Position.X.Offset == 108 then
                ch:Destroy() -- Remove legacy white divider.
            end
        end

        local side = ui("Frame", {
            Name = "MidnightSidebar", Position = UDim2.fromOffset(0, 0),
            Size = UDim2.new(0, 132, 1, 0), BorderSizePixel = 0,
            BackgroundColor3 = C.sidebar, ZIndex = 1,
        }, window)
        ui("Frame", {
            Position = UDim2.new(1, -1, 0, 0), Size = UDim2.new(0, 1, 1, 0),
            BackgroundColor3 = C.border, BorderSizePixel = 0, ZIndex = 2,
        }, side)
        ui("TextLabel", {
            Position = UDim2.fromOffset(15, 13), Size = UDim2.fromOffset(105, 23),
            BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 16,
            TextColor3 = C.text, Text = "◈  FIELD LAB", TextXAlignment = Enum.TextXAlignment.Left,
            ZIndex = 5,
        }, side)
        ui("TextLabel", {
            Position = UDim2.fromOffset(15, 37), Size = UDim2.fromOffset(108, 18),
            BackgroundTransparency = 1, Font = Enum.Font.Gotham, TextSize = 10,
            TextColor3 = C.soft, Text = "MIDNIGHT  /  v8.6.10",
            TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 5,
        }, side)

        local topBar = ui("Frame", {
            Name = "MidnightTopbar", Position = UDim2.fromOffset(132, 0),
            Size = UDim2.new(1, -132, 0, 48), BorderSizePixel = 0,
            BackgroundColor3 = C.header, ZIndex = 3,
        }, window)
        local topTitle = ui("TextLabel", {
            Position = UDim2.fromOffset(19, 7), Size = UDim2.new(1, -145, 0, 22),
            BackgroundTransparency = 1, Font = Enum.Font.GothamBold,
            TextSize = 16, TextColor3 = C.text, Text = "Farm",
            TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 7,
        }, topBar)
        local topDetail = ui("TextLabel", {
            Position = UDim2.fromOffset(20, 28), Size = UDim2.new(1, -145, 0, 14),
            BackgroundTransparency = 1, Font = Enum.Font.Gotham,
            TextSize = 10, TextColor3 = C.soft,
            Text = "Field routes & bee behaviors",
            TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 7,
        }, topBar)
        local grip = ui("TextButton", {
            Name = "MidnightDragHandle", Position = UDim2.fromOffset(1, 0),
            Size = UDim2.new(1, -37, 1, 0), BackgroundTransparency = 1,
            Text = "", ZIndex = 9,
        }, topBar)
        table.insert(dragConnections, grip.InputBegan:Connect(beginDrag))
        dragStrip.Visible = false
        hideMenu.Parent = topBar
        hideMenu.Position = UDim2.new(1, -33, 0, 10)
        hideMenu.Size = UDim2.fromOffset(24, 24)
        hideMenu.BackgroundColor3 = C.raised
        hideMenu.TextColor3 = C.text
        hideMenu.ZIndex = 80
        hideMenu.Text = "−"
        if not hideMenu:FindFirstChildOfClass("UICorner") then
            ui("UICorner", {CornerRadius = UDim.new(0, 5)}, hideMenu)
        end
        showMenu.BackgroundColor3 = C.sidebar
        showMenu.TextColor3 = C.text
        showMenu.BorderColor3 = C.accent
        showMenu.Text = "◈ FIELD LAB"
        showMenu.Size = UDim2.fromOffset(110, 29)
        ui("UICorner", {CornerRadius = UDim.new(0, 6)}, showMenu)

        local footer = ui("Frame", {
            Name = "MidnightFooter", Position = UDim2.new(0, 132, 1, -36),
            Size = UDim2.new(1, -132, 0, 36), BackgroundColor3 = C.header,
            BorderSizePixel = 0, ZIndex = 8,
        }, window)
        local statusText = ui("TextLabel", {
            Position = UDim2.fromOffset(18, 4), Size = UDim2.new(1, -131, 0, 28),
            BackgroundTransparency = 1, TextColor3 = C.soft, Font = Enum.Font.Gotham,
            TextSize = 11, Text = "● READY   •   Wheel / touch to scroll",
            TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 11,
        }, footer)
        local function scrollAction(label, position)
            local b = ui("TextButton", {
                Text = label, Position = position, Size = UDim2.fromOffset(30, 25),
                BackgroundColor3 = C.raised, TextColor3 = C.text, BorderSizePixel = 0,
                Font = Enum.Font.GothamBold, TextSize = 17, ZIndex = 12,
            }, footer)
            ui("UICorner", {CornerRadius = UDim.new(0, 5)}, b)
            return b
        end
        local scrollUp = scrollAction("▲", UDim2.new(1, -73, 0, 5))
        local scrollDown = scrollAction("▼", UDim2.new(1, -38, 0, 5))
        local function scrollPage(by)
            local page = pages[selectedTab]
            if not page then return end
            local maximum = math.max(0, page.AbsoluteCanvasSize.Y - page.AbsoluteWindowSize.Y)
            page.CanvasPosition = Vector2.new(0,
                math.clamp(page.CanvasPosition.Y + by, 0, maximum))
        end
        scrollUp.Activated:Connect(function() scrollPage(-180) end)
        scrollDown.Activated:Connect(function() scrollPage(180) end)

        local summaries = {
            Main = "Live inventory & item counts",
            Farm = "Field navigation, bee skills and precision collection",
            Combat = "Mobs, bosses, respawn timers and challenges",
            Toy = "Crafting & interactive utilities",
            Quest = "NPC selection, objectives and automatic turn-in",
            Upgrade = "Upgrade management",
            Hive = "Hive controls",
            Plant = "Planter slots, harvest thresholds and rewards",
            Config = "Movement settings and JSON profiles",
        }
        for i, name in ipairs(tabNames) do
            local b = tabButtons[name]
            b.Position = UDim2.fromOffset(8, 72 + (i - 1) * 35)
            b.Size = UDim2.fromOffset(116, 30)
            b.BackgroundColor3 = C.sidebar
            b.Text = "  " .. name
            b.TextColor3 = C.soft
            b.TextSize = 13
            b.Font = Enum.Font.GothamMedium
            b.TextXAlignment = Enum.TextXAlignment.Left
            b.BorderSizePixel = 0
            b.ZIndex = 5
            if not b:FindFirstChildOfClass("UICorner") then
                ui("UICorner", {CornerRadius = UDim.new(0, 6)}, b)
            end
            local page = pages[name]
            page.Position = UDim2.fromOffset(133, 52)
            page.Size = UDim2.new(1, -141, 1, -94)
            page.BackgroundTransparency = 1
            page.BorderSizePixel = 0
            page.Active = true
            page.ScrollingEnabled = true
            page.ScrollingDirection = Enum.ScrollingDirection.Y
            page.ScrollBarThickness = 7
            page.ScrollBarImageColor3 = C.accent
            page.ScrollBarImageTransparency = 0.1
            page.AutomaticCanvasSize = Enum.AutomaticSize.None
            page.CanvasSize = UDim2.fromOffset(0, 405)
            page.ClipsDescendants = true
        end
        activeDot.Position = UDim2.new(1, -13, 0.5, -3)
        activeDot.Size = UDim2.fromOffset(6, 6)
        activeDot.BackgroundColor3 = C.success

        local function repaintSidebar()
            for name, b in pairs(tabButtons) do
                local chosen = name == selectedTab
                b.BackgroundColor3 = chosen and C.raised or C.sidebar
                b.TextColor3 = chosen and C.text or C.soft
                b.Font = chosen and Enum.Font.GothamBold or Enum.Font.GothamMedium
            end
            activeDot.Parent = tabButtons[selectedTab]
            topTitle.Text = selectedTab
            topDetail.Text = summaries[selectedTab] or "Field Manager"
        end
        for _, b in pairs(tabButtons) do
            b.Activated:Connect(function()
                task.defer(repaintSidebar)
            end)
        end

        local function rounded(obj, amount)
            if not obj:FindFirstChildOfClass("UICorner") then
                ui("UICorner", {CornerRadius = UDim.new(0, amount)}, obj)
            end
        end
        local function recolorExisting()
            for _,obj in ipairs(screen:GetDescendants()) do
                if obj:IsA("GuiObject") then
                    if obj:IsA("ScrollingFrame") then
                        obj.ScrollingEnabled = true
                        obj.Active = true
                        obj.ScrollBarThickness = math.max(5, obj.ScrollBarThickness)
                        obj.ScrollBarImageColor3 = C.accent
                        obj.ScrollingDirection = Enum.ScrollingDirection.Y
                    elseif obj:IsA("TextBox") then
                        obj.BackgroundColor3 = C.raised
                        obj.TextColor3 = C.text
                        obj.PlaceholderColor3 = C.soft
                        obj.BorderSizePixel = 0
                        rounded(obj, 5)
                    elseif obj:IsA("TextButton") then
                        if obj.BackgroundTransparency < 0.9 and obj ~= showMenu
                            and obj ~= hideMenu and not obj:IsDescendantOf(side) then
                            local bg = obj.BackgroundColor3
                            local bright = (bg.R + bg.G + bg.B) / 3
                            if bright > 0.59 and math.abs(bg.R - bg.G) < 0.16
                                and math.abs(bg.G - bg.B) < 0.16 then
                                obj.BackgroundColor3 = C.raised
                                obj.TextColor3 = C.text
                            elseif bright < 0.19 then
                                obj.BackgroundColor3 = C.raised
                            end
                            obj.BorderSizePixel = 0
                            rounded(obj, 6)
                        end
                    elseif obj:IsA("TextLabel") then
                        if obj.TextColor3 == black then
                            obj.TextColor3 = C.text
                        elseif obj.TextColor3 == white then
                            obj.TextColor3 = C.text
                        end
                    elseif obj:IsA("Frame") and obj.Name ~= "Window" then
                        local bg = obj.BackgroundColor3
                        local brightness = (bg.R + bg.G + bg.B)/3
                        if obj.BackgroundTransparency < 0.9 and brightness > 0.65
                            and math.abs(bg.R - bg.G) < 0.13
                            and math.abs(bg.G - bg.B) < 0.13 then
                            obj.BackgroundColor3 = C.raised
                        end
                    end
                end
            end
        end

        -- Reparenting does not disconnect Activated/Changed handlers. Each
        -- accordion creates a shorter page while retaining the existing controls.
        local function accordions(pageName, defs, pick)
            local page = pages[pageName]
            local existing = {}
            for _,obj in ipairs(page:GetChildren()) do
                if obj:IsA("GuiObject") then
                    table.insert(existing, obj)
                end
            end
            local buckets = {}
            for _,spec in ipairs(defs) do buckets[spec.id] = {} end
            for _,obj in ipairs(existing) do
                if obj.Name == "SectionSeparator" or obj.Name == "PreciseVerticalSeparator"
                    or obj.Name == "DigitalHorizontalSeparator" then
                    obj:Destroy()
                else
                    local id = pick(obj, obj.Position.X.Offset, obj.Position.Y.Offset)
                    if id and buckets[id] then
                        table.insert(buckets[id], obj)
                    end
                end
            end
            local stack = ui("Frame", {
                Name = "MidnightSections", Position = UDim2.fromOffset(8, 9),
                Size = UDim2.new(1, -24, 0, 0), BackgroundTransparency = 1,
                BorderSizePixel = 0, ZIndex = 2,
            }, page)
            local layout = ui("UIListLayout", {
                SortOrder = Enum.SortOrder.LayoutOrder,
                Padding = UDim.new(0, 9),
            }, stack)
            local function updateCanvas()
                local h = layout.AbsoluteContentSize.Y
                stack.Size = UDim2.new(1, -24, 0, h)
                page.CanvasSize = UDim2.fromOffset(0,
                    math.max(page.AbsoluteSize.Y + 10, h + 29))
            end
            layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(updateCanvas)
            page:GetPropertyChangedSignal("AbsoluteSize"):Connect(updateCanvas)

            for order,spec in ipairs(defs) do
                local expanded = spec.open == true
                local card = ui("Frame", {
                    Name = spec.id .. "Card", LayoutOrder = order,
                    Size = UDim2.new(1, 0, 0, expanded and spec.height or 36),
                    BackgroundColor3 = C.card, BorderSizePixel = 0,
                    ClipsDescendants = false, ZIndex = 2,
                }, stack)
                rounded(card, 8)
                ui("UIStroke", {Color = C.border, Thickness = 1, Transparency = 0.15}, card)
                local header = ui("TextButton", {
                    Name = "Expand" .. spec.id,
                    Size = UDim2.new(1, -14, 0, 32), Position = UDim2.fromOffset(7, 2),
                    BackgroundTransparency = 1,
                    Text = (expanded and "▾  " or "▸  ") .. spec.title,
                    Font = Enum.Font.GothamBold, TextColor3 = C.text,
                    TextSize = 13, TextXAlignment = Enum.TextXAlignment.Left,
                    ZIndex = 16,
                }, card)
                ui("Frame", {
                    Position = UDim2.fromOffset(8, 34), Size = UDim2.new(1, -16, 0, 1),
                    BackgroundColor3 = C.border, BorderSizePixel = 0,
                    Visible = expanded, ZIndex = 3,
                }, card)
                local body = ui("Frame", {
                    Name = "Controls", Position = UDim2.fromOffset(9, 37),
                    Size = UDim2.new(1, -18, 1, -39), BackgroundTransparency = 1,
                    Visible = expanded, ClipsDescendants = false, ZIndex = 3,
                }, card)
                -- IMPORTANT: ScreenGui uses Enum.ZIndexBehavior.Global.
                -- Old controls often have ZIndex = 1, while the new card has
                -- ZIndex = 2. Without lifting their draw order, the card's
                -- background completely covers Combat, Quest and Plant UI.
                -- New rows are also generated dynamically by refreshList(),
                -- scanBears(), monitor updates, etc. Maintain the order for
                -- both existing and newly-added GuiObjects.
                local function fixLayers(node)
                    if node:IsA("GuiObject") then
                        local parent = node.Parent
                        if parent and parent:IsA("GuiObject") then
                            local required = parent.ZIndex + 1
                            if node.ZIndex < required then
                                node.ZIndex = required
                            end
                        end
                    end
                    for _, child in ipairs(node:GetChildren()) do
                        fixLayers(child)
                    end
                end
                for _,obj in ipairs(buckets[spec.id]) do
                    -- Duplicate legacy section labels are replaced by the
                    -- accordion's title; other controls retain their references.
                    local originalText = obj:IsA("TextLabel") and obj.Text or ""
                    if spec.hideTitles and spec.hideTitles[originalText] then
                        obj:Destroy()
                    else
                        local at = obj.Position
                        obj.Parent = body
                        obj.Position = UDim2.new(at.X.Scale,
                            at.X.Offset - (spec.xBase or 0) + 2,
                            at.Y.Scale, at.Y.Offset - (spec.yBase or 0) + 2)
                        fixLayers(obj)
                    end
                end
                body.DescendantAdded:Connect(function(node)
                    if not node:IsA("GuiObject") then return end
                    task.defer(function()
                        if node:IsDescendantOf(body) then
                            fixLayers(node)
                        end
                    end)
                end)
                if spec.info then
                    ui("TextLabel", {
                        Position = UDim2.fromOffset(spec.infoX or 320, 10),
                        Size = UDim2.new(1, -(spec.infoX or 320) - 12, 0, math.min(70, spec.height - 52)),
                        BackgroundTransparency = 1, TextColor3 = C.soft,
                        Font = Enum.Font.Gotham, TextSize = 11,
                        TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left,
                        TextYAlignment = Enum.TextYAlignment.Top,
                        Text = spec.info, ZIndex = 6,
                    }, body)
                end
                header.Activated:Connect(function()
                    expanded = not expanded
                    body.Visible = expanded
                    card.Size = UDim2.new(1, 0, 0, expanded and spec.height or 36)
                    header.Text = (expanded and "▾  " or "▸  ") .. spec.title
                    -- Collapse any expanded dropdown before hiding the card.
                    if not expanded and pageName == "Farm" then
                        dropdown.Visible = false
                        lockOptions.Visible = false
                    end
                    task.defer(updateCanvas)
                end)
            end
            task.defer(updateCanvas)
        end

        accordions("Farm", {
            {id="Quick",title="01  QUICK FARM",height=90,open=true,yBase=0,xBase=0},
            {id="Precise",title="02  PRECISE BEE",height=218,open=true,yBase=53,xBase=290,
             hideTitles={["PRECISE BEE"]=true},
             info="Ưu tiên ba Crosshair liên tiếp, giữ ở điểm cuối chờ bắn.",infoX=290},
            {id="Digital",title="03  DIGITAL BEE",height=185,open=false,yBase=230,xBase=290,
             hideTitles={["DIGITAL BEE"]=true},
             info="Ưu tiên token mặt cười rồi quay về đường farm.",infoX=290},
            {id="Facing",title="04  FACING LOCK",height=220,open=false,yBase=50,xBase=0,
             hideTitles={["LOCK FACING"]=true},
             info="Giữ hướng tới Flames/Bubble, không thay đổi mục tiêu farm.",infoX=290},
            {id="Heat",title="05  FLAME HEAT",height=175,open=false,yBase=245,xBase=0,
             hideTitles={["FLAME HEAT"]=true},
             info="Chạm flame để tăng Heat, sau đó tiếp tục nhặt token.",infoX=290},
        }, function(obj, x, y)
            if y < 50 then return "Quick" end
            if x >= 290 then return y < 230 and "Precise" or "Digital" end
            return y < 245 and "Facing" or "Heat"
        end)

        accordions("Combat", {
            {id="CombatControls",title="COMBAT  /  CONTROLS",height=140,
                open=true,yBase=0,xBase=0},
            {id="CombatTargets",title="TARGETS  /  BOSS TIMERS",height=315,
                open=true,yBase=100,xBase=0},
        }, function(obj, x, y)
            return y < 100 and "CombatControls" or "CombatTargets"
        end)

        accordions("Quest", {
            {id="QuestControls",title="QUEST  /  AUTOMATION",height=113,
                open=true,yBase=0,xBase=0,
                hideTitles={["AUTO BEAR QUEST"]=true}},
            {id="QuestList",title="NPC LIST  /  PROGRESS",height=344,
                open=true,yBase=75,xBase=0},
        }, function(obj,x,y)
            return y < 75 and "QuestControls" or "QuestList"
        end)

        accordions("Plant", {
            {id="PlantControls",title="PLANTER  /  AUTONOMY",height=115,
                open=true,yBase=0,xBase=0,
                hideTitles={["PLANT MANAGER"]=true}},
            {id="PlantSlots",title="PLANTERS  /  YOUR THREE SLOTS",height=348,
                open=true,yBase=75,xBase=0},
            {id="PlantLive",title="ACTIVE PLANTERS  /  GROWTH",height=244,
                open=true,yBase=380,xBase=0},
        }, function(obj,x,y)
            if y < 75 then return "PlantControls" end
            if y < 380 then return "PlantSlots" end
            return "PlantLive"
        end)

        accordions("Config", {
            {id="Movement",title="MOVEMENT  /  SPEED",height=127,
                open=true,yBase=0,xBase=0},
            {id="JsonProfiles",title="PROFILES  /  JSON SETTINGS",height=320,
                open=false,yBase=88,xBase=0,
                hideTitles={["CONFIG  |  JSON PROFILES"]=true}},
            {id="Live",title="LIVE UPDATE  /  DEPLOYMENT",height=145,
                open=true,yBase=375,xBase=0},
        }, function(obj,x,y)
            if y < 88 then return "Movement" end
            if y < 375 then return "JsonProfiles" end
            return "Live"
        end)

        -- The inventory's own grid is intentionally a nested scroll: this is
        -- a long list of objects and does not need a second accordion wrapper.
        local inventoryPage = pages.Main
        inventoryPage.CanvasSize = UDim2.fromOffset(0, 460)
        local inventoryList = inventoryPage:FindFirstChild("InventoryList")
        if inventoryList and inventoryList:IsA("ScrollingFrame") then
            inventoryList.Size = UDim2.new(1, -22, 1, -92)
            inventoryList.ScrollingEnabled = true
            inventoryList.Active = true
            inventoryList.ScrollBarThickness = 7
        end
        -- Toy already has an independent Blender accordion; its content is only
        -- allocated when expanded. Keep the native crafting widgets intact.
        local toyPage = pages.Toy
        local blenderPanel = toyPage:FindFirstChild("BlenderSectionBody")
        if blenderPanel then
            blenderPanel.Size = UDim2.new(1, -26, 0, 199)
            blenderPanel.BackgroundColor3 = C.card
            local header = toyPage:FindFirstChild("BlenderSectionHeader")
            if header then
                header.BackgroundColor3 = C.raised
                header.BorderSizePixel = 0
            end
        end
        local function ordinaryPageCanvas(page)
            local bottom = 0
            for _,obj in ipairs(page:GetChildren()) do
                if obj:IsA("GuiObject") and obj.Visible and obj.Name ~= "MidnightSections" then
                    local h = obj.AbsoluteSize.Y > 0 and obj.AbsoluteSize.Y
                        or obj.Size.Y.Offset + obj.Size.Y.Scale * page.AbsoluteSize.Y
                    bottom = math.max(bottom,
                        obj.Position.Y.Offset + obj.Position.Y.Scale * page.AbsoluteSize.Y + h)
                end
            end
            page.CanvasSize = UDim2.fromOffset(0,
                math.max(page.AbsoluteSize.Y + 9, bottom + 30))
        end
        task.spawn(function()
            while screen.Parent do
                for _,name in ipairs({"Toy", "Upgrade", "Hive"}) do
                    ordinaryPageCanvas(pages[name])
                end
                task.wait(0.8)
            end
        end)

        recolorExisting()
        -- Enforce navigation colors after automatic styling of legacy widgets.
        repaintSidebar()
        task.spawn(function()
            while screen.Parent do
                local mode = "READY"
                if CombatSignals.AntBusy then mode = "ANT CHALLENGE"
                elseif CombatSignals.PlanterBusy then mode = "PLANTER RUNNING"
                elseif farmEnabled then mode = "FARM ACTIVE"
                elseif clickEnabled then mode = "AUTO CLICK ACTIVE" end
                statusText.Text = "● " .. mode .. "    •    Wheel / touch to scroll"
                statusText.TextColor3 = mode == "READY" and C.soft or C.success
                task.wait(0.6)
            end
        end)
    end
    local ok, err = pcall(buildMidnightUI)
    if not ok then
        warn("[BSS Midnight UI]", err)
    end
end

-- FIND HIVE AS SOON AS SCRIPT IS RUN
 task.spawn(function()
    local ok, err = pcall(findHive)
    if not ok then warn("[BSS Hive]", err) end
    hiveBusy = false
end)

-- Managed update API, published only after the full GUI has initialized.
do
    local env = (type(getgenv) == "function" and getgenv()) or _G
    local runtime = env.__FIELDLAB_APP
    if runtime and runtime.Version == "8.6.10" then
        runtime.Screen = screen
        runtime.Snapshot = function()
            local pos = window.Position
            return {
                Config = ConfigManager.Capture(),
                SelectedTab = selectedTab,
                Position = {pos.X.Scale, pos.X.Offset, pos.Y.Scale, pos.Y.Offset},
                Minimized = showMenu.Visible,
            }
        end
        runtime.Stop = function()
            if not runtime.Ready and not screen.Parent then return end
            runtime.Ready = false
            if screen.Parent then screen:Destroy() end
        end
        local resume = env.__FIELDLAB_RESTORE
        env.__FIELDLAB_RESTORE = nil
        if type(resume) == "table" then
            if type(resume.Config) == "table" then
                local ok, applied, reason = pcall(ConfigManager.Apply, resume.Config)
                if not ok or not applied then
                    warn("[FieldLab Live] Restore:", reason or applied)
                end
            end
            if type(resume.SelectedTab) == "string" and pages[resume.SelectedTab] then
                showTab(resume.SelectedTab)
            end
            if type(resume.Position) == "table" and #resume.Position == 4 then
                local p = resume.Position
                if tonumber(p[1]) and tonumber(p[2]) and tonumber(p[3]) and tonumber(p[4]) then
                    window.Position = UDim2.new(p[1], p[2], p[3], p[4])
                end
            end
            if resume.Minimized == true then
                window.Visible = false
                showMenu.Visible = true
            end
        end
        -- Reject a partially initialized UI rather than calling it a healthy update.
        if not window:FindFirstChild("MidnightSidebar")
            or not window:FindFirstChild("MidnightTopbar") then
            error("Midnight UI did not initialize")
        end
        -- Deliberately do NOT resume active Farm/Combat/Quest loops after code reload.
        -- They may have changed shape. State is preserved; jobs restart manually.
        runtime.Ready = true
    end
end
