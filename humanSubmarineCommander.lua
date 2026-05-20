HumanSubmarineCommander = {}
HumanSubmarineCommander.__index = HumanSubmarineCommander

-- Creates F10 coalition menus to control submarines
-- ownerCoalition: coalition.side.RED or coalition.side.BLUE
-- submarines: a table of VirtualSubmarine instances
function HumanSubmarineCommander:new(ownerCoalition, submarines, targetCoalition, buoys, detectableObjects)
    local obj = {
        ownerCoalition = ownerCoalition or coalition.side.RED,
        submarines = submarines or {},
        targetCoalition = targetCoalition or coalition.side.BLUE,
        buoys = buoys or {},
        detectableObjects = detectableObjects or {},  -- shared table that buoys scan
        torpedoes = {},
        torpedoIdCounter = 0,
        noiseMakers = {},
        noiseMakerIdCounter = 0
    }
    setmetatable(obj, HumanSubmarineCommander)
    obj:buildMenus()
    return obj
end

function HumanSubmarineCommander:buildMenus()
    local side = self.ownerCoalition
    local rootMenu = MENU_COALITION:New(side, "Submarine Command")

    for _, sub in ipairs(self.submarines) do
        local subMenu = MENU_COALITION:New(side, sub.name, rootMenu)

        -- Heading submenu
        local headingMenu = MENU_COALITION:New(side, "Change Heading", subMenu)
        local headingDeltas = {-90, -50, -25, -10, -5, 5, 10, 25, 50, 90}
        for _, delta in ipairs(headingDeltas) do
            local label = (delta > 0 and "+" or "") .. delta .. "°"
            MENU_COALITION_COMMAND:New(side, label, headingMenu, self.changeHeading, self, sub, delta)
        end

        -- Set Heading submenu
        local setHeadingMenu = MENU_COALITION:New(side, "Set Heading", subMenu)
        local headings = {
            {0, "N (000°)"}, {45, "NE (045°)"}, {90, "E (090°)"}, {135, "SE (135°)"},
            {180, "S (180°)"}, {225, "SW (225°)"}, {270, "W (270°)"}, {315, "NW (315°)"}
        }
        for _, h in ipairs(headings) do
            MENU_COALITION_COMMAND:New(side, h[2], setHeadingMenu, self.setHeading, self, sub, h[1])
        end

        -- Speed submenu
        local speedMenu = MENU_COALITION:New(side, "Change Speed", subMenu)
        local speedDeltas = {-10, -5, -2, -1, 1, 2, 5, 10}
        for _, delta in ipairs(speedDeltas) do
            local label = (delta > 0 and "+" or "") .. delta .. " m/s"
            MENU_COALITION_COMMAND:New(side, label, speedMenu, self.changeSpeed, self, sub, delta)
        end

        -- Depth submenu
        local depthMenu = MENU_COALITION:New(side, "Change Depth", subMenu)
        local depthDeltas = {-100, -50, -25, -10, 10, 25, 50, 100}
        for _, delta in ipairs(depthDeltas) do
            local label = (delta > 0 and "+" or "") .. delta .. "m"
            MENU_COALITION_COMMAND:New(side, label, depthMenu, self.changeDepth, self, sub, delta)
        end

        -- Quick depth commands
        MENU_COALITION_COMMAND:New(side, "Dive (max depth)", depthMenu, self.dive, self, sub)
        MENU_COALITION_COMMAND:New(side, "Periscope Depth", depthMenu, self.periscopeDepth, self, sub)
        MENU_COALITION_COMMAND:New(side, "Level (hold depth)", depthMenu, self.level, self, sub)

        -- Torpedo submenu
        local torpedoMenu = MENU_COALITION:New(side, "Torpedoes", subMenu)
        MENU_COALITION_COMMAND:New(side, "Fire Torpedo!", torpedoMenu, self.fireTorpedo, self, sub)
        MENU_COALITION_COMMAND:New(side, "Torpedo Status", torpedoMenu, self.torpedoStatus, self, sub)

        -- Noise Maker submenu
        local decoyMenu = MENU_COALITION:New(side, "Noise Makers", subMenu)
        local delayMenu = MENU_COALITION:New(side, "Deploy Noise Maker", decoyMenu)
        for _, delay in ipairs({0, 60, 120, 180, 240}) do
            local label = delay == 0 and "Immediate" or (delay .. "s delay")
            MENU_COALITION_COMMAND:New(side, label, delayMenu, self.deployNoiseMaker, self, sub, delay)
        end
        MENU_COALITION_COMMAND:New(side, "Noise Maker Status", decoyMenu, self.noiseMakerStatus, self, sub)
    end
end

function HumanSubmarineCommander:changeHeading(sub, delta)
    if not sub:isAlive() then return end
    local newHeading = (sub.targetHeading + delta) % 360
    sub:setCourse(newHeading)
end

function HumanSubmarineCommander:setHeading(sub, heading)
    if not sub:isAlive() then return end
    sub:setCourse(heading)
end

function HumanSubmarineCommander:changeSpeed(sub, delta)
    if not sub:isAlive() then return end
    local newSpeed = math.max(0, sub.targetSpeed + delta)
    sub:setSpeed(newSpeed)
end

function HumanSubmarineCommander:changeDepth(sub, delta)
    if not sub:isAlive() then return end
    local newDepth = math.max(0, sub.targetDepth + delta)
    sub:setTargetDepth(newDepth)
end

function HumanSubmarineCommander:dive(sub)
    if not sub:isAlive() then return end
    sub:setTargetDepth(sub.maxDepth)
end

function HumanSubmarineCommander:periscopeDepth(sub)
    if not sub:isAlive() then return end
    sub:setTargetDepth(20)
end

function HumanSubmarineCommander:level(sub)
    if not sub:isAlive() then return end
    sub:setTargetDepth(sub.depth)
end

function HumanSubmarineCommander:fireTorpedo(sub)
    if not sub:isAlive() then return end
    if sub.torpedoCount <= 0 then
        self:message(sub.name .. ": No torpedoes remaining!")
        return
    end
    if sub.depth > 30 then
        self:message(sub.name .. ": Must be at periscope depth (< 30m) to fire! Current depth: " .. string.format("%.0f", sub.depth) .. "m")
        return
    end

    sub.torpedoCount = sub.torpedoCount - 1
    self.torpedoIdCounter = self.torpedoIdCounter + 1
    local torpedoName = sub.name .. "-Torpedo-" .. self.torpedoIdCounter

    local torpedo = SubmarineTorpedo:new(
        torpedoName, sub.x, sub.z, sub.heading,
        self.ownerCoalition, self.targetCoalition, self.buoys
    )

    self.torpedoes[#self.torpedoes + 1] = torpedo
    self:message(sub.name .. ": Torpedo fired! Heading: " .. string.format("%.0f", sub.heading) .. "° | Remaining: " .. sub.torpedoCount .. "/" .. sub.maxTorpedoes)

    -- Torpedo launch sound for sub coalition + target coalition
    if ASW_SOUND then
        ASW_SOUND:playForCoalition(self.ownerCoalition, "torpedo_launch")
        ASW_SOUND:playForCoalition(self.targetCoalition, "torpedo_launch")
    end
end

function HumanSubmarineCommander:torpedoStatus(sub)
    local activeTorpedoes = 0
    for _, torp in ipairs(self.torpedoes) do
        if torp:isActive() then
            activeTorpedoes = activeTorpedoes + 1
        end
    end

    local depthOk = sub.depth <= 30
    local msg = string.format("%s Torpedo Status:\nRemaining: %d/%d\nActive in water: %d\nDepth: %.0fm %s",
        sub.name, sub.torpedoCount, sub.maxTorpedoes, activeTorpedoes,
        sub.depth, depthOk and "(READY)" or "(TOO DEEP - need < 30m)")
    self:message(msg, 10)
end

function HumanSubmarineCommander:message(msg, duration)
    duration = duration or 10
    trigger.action.outTextForCoalition(self.ownerCoalition, msg, duration, false)
end

-- ===== NOISE MAKERS =====

function HumanSubmarineCommander:deployNoiseMaker(sub, delay)
    if not sub:isAlive() then return end
    if sub.noiseMakerCount <= 0 then
        self:message(sub.name .. ": No noise makers remaining!")
        return
    end

    sub.noiseMakerCount = sub.noiseMakerCount - 1
    self.noiseMakerIdCounter = self.noiseMakerIdCounter + 1
    local decoyName = sub.name .. "-Decoy-" .. self.noiseMakerIdCounter

    local decoy = NoiseMaker:new(
        decoyName, sub.x, sub.z, sub.depth, delay,
        self.ownerCoalition, sub.thermalLayerDepth
    )

    self.noiseMakers[#self.noiseMakers + 1] = decoy
    -- Add to the shared detectable objects table so buoys will detect it
    self.detectableObjects[#self.detectableObjects + 1] = decoy

    self:message(string.format("%s: Noise maker deployed! Activates in %ds | Remaining: %d/%d",
        sub.name, delay, sub.noiseMakerCount, sub.maxNoiseMakers))
end

function HumanSubmarineCommander:noiseMakerStatus(sub)
    local activeCount = 0
    local standbyCount = 0
    for _, decoy in ipairs(self.noiseMakers) do
        if decoy:isDeployed() then
            if decoy:isAlive() then
                activeCount = activeCount + 1
            else
                standbyCount = standbyCount + 1
            end
        end
    end

    local msg = string.format("%s Noise Maker Status:\nRemaining: %d/%d\nStandby: %d | Active: %d",
        sub.name, sub.noiseMakerCount, sub.maxNoiseMakers, standbyCount, activeCount)
    self:message(msg, 10)
end
