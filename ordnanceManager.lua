OrdnanceManager = {}
OrdnanceManager.__index = OrdnanceManager

local function debugMessage(message, duration)
    local dbg = trigger.misc.getUserFlag("Debug")
    if dbg == 1 then
        duration = duration or 10
        trigger.action.outText(message, duration, false)
        env.info(message, false)
    end
end

-- Constructor
-- config table:
--   ownerCoalition: coalition side for ASW hunters
--   submarines: table of VirtualSubmarine instances to detect
--   hunterPrefix: group name prefix to find hunter groups (e.g. "_asw_hunter")
--   rearmZone: trigger zone name where hunters can rearm (static fallback)
--   rearmUnit: DCS unit name to use as moving rearm point (e.g. carrier), overrides rearmZone
--   rearmRadius: radius around rearmUnit for rearming (default 500)
--   maxBuoys: max buoys per group (default 4)
--   maxTorpedoes: max torpedoes per group (default 1)
--   maxAltitude: max altitude AGL in meters for deploy/recover/launch (default 50)
--   maxSpeed: max speed in m/s for deploy/recover/launch (default 60)
--   recoveryRange: max distance to recover a buoy (default 10)
--   thermalLayerDepth: thermal layer depth for spawned buoys and torpedoes (default 90)
--   detectInterval: seconds between detection cycles (default 5)
function OrdnanceManager:new(config)
    local obj = {
        ownerCoalition = config.ownerCoalition or coalition.side.BLUE,
        submarines = config.submarines or {},
        hunterPrefix = config.hunterPrefix or "_asw_hunter",
        rearmZone = config.rearmZone or "ASW_Hunter_Rearming",
        rearmUnit = config.rearmUnit or nil,
        rearmRadius = config.rearmRadius or 500,
        maxBuoys = config.maxBuoys or 4,
        maxTorpedoes = config.maxTorpedoes or 1,
        maxAltitude = config.maxAltitude or 50,
        maxSpeed = config.maxSpeed or 60,
        recoveryRange = config.recoveryRange or 10,
        thermalLayerDepth = config.thermalLayerDepth or 90,
        detectInterval = config.detectInterval or 5,
        buoys = {},          -- all deployed buoys
        torpedoes = {},      -- all active torpedoes
        groupData = {},      -- per-group state
        buoyIdCounter = 0,   -- global counter for unique buoy names
        torpedoIdCounter = 0, -- global counter for unique torpedo names
        trackedGroups = {},   -- groups we've already set up menus for
        dippingSonars = {}    -- live list of all dipping sonars (shared with AI)
    }
    setmetatable(obj, OrdnanceManager)
    obj:startGroupScanner()
    obj:startDetectionLoop()
    return obj
end

-- Periodically scan for new hunter groups and set up menus
function OrdnanceManager:startGroupScanner()
    local function scan()
        local allGroups = coalition.getGroups(self.ownerCoalition)
        if allGroups then
            for _, dcsGroup in ipairs(allGroups) do
                if dcsGroup and dcsGroup:isExist() then
                    local groupName = dcsGroup:getName()
                    if self:isHunterGroup(groupName) and not self.trackedGroups[groupName] then
                        self:initGroup(groupName)
                    end
                end
            end
        end

        -- Clean up destroyed groups
        self:cleanupDestroyedGroups()

        timer.scheduleFunction(function()
            scan()
        end, nil, timer.getTime() + 10)
    end
    scan()
end

-- Remove tracking data for groups that no longer exist
function OrdnanceManager:cleanupDestroyedGroups()
    local toRemove = {}
    for groupName, _ in pairs(self.trackedGroups) do
        local dcsGroup = Group.getByName(groupName)
        if not dcsGroup or not dcsGroup:isExist() then
            toRemove[#toRemove + 1] = groupName
        end
    end

    for _, groupName in ipairs(toRemove) do
        local data = self.groupData[groupName]
        if data and data.dippingSonar then
            if data.dippingSonar:isDeployed() then
                data.dippingSonar:breakCable("Aircraft destroyed!")
            end
            data.dippingSonar:stopUpdateLoop()
            -- Remove from live dipping sonars list
            for i, sonar in ipairs(self.dippingSonars) do
                if sonar == data.dippingSonar then
                    table.remove(self.dippingSonars, i)
                    break
                end
            end
        end
        self.groupData[groupName] = nil
        self.trackedGroups[groupName] = nil
        debugMessage("ASW Hunter group destroyed, cleaned up: " .. groupName)
    end
end

function OrdnanceManager:isHunterGroup(groupName)
    return string.find(groupName, self.hunterPrefix, 1, true) ~= nil
end

-- Initialize tracking and menus for a hunter group
function OrdnanceManager:initGroup(groupName)
    self.trackedGroups[groupName] = true
    self.groupData[groupName] = {
        inventory = self.maxBuoys,
        torpedoInventory = self.maxTorpedoes,
        torpedoDepth = 100,      -- default search depth
        state = "idle",          -- idle, preparing_launch, preparing_recover, preparing_torpedo
        prepareScheduleId = nil,
        dippingSonar = DippingSonar:new(groupName, self.ownerCoalition, self.thermalLayerDepth, self.submarines)
    }

    -- Add to live dipping sonars list
    self.dippingSonars[#self.dippingSonars + 1] = self.groupData[groupName].dippingSonar

    local mooseGroup = GROUP:FindByName(groupName)
    if not mooseGroup then return end

    local rootMenu = MENU_GROUP:New(mooseGroup, "ASW Operations")

    -- Buoy submenu
    local buoyMenu = MENU_GROUP:New(mooseGroup, "Sonarbuoys", rootMenu)
    MENU_GROUP_COMMAND:New(mooseGroup, "Prepare to Launch Buoy", buoyMenu, self.prepareToLaunch, self, groupName)
    MENU_GROUP_COMMAND:New(mooseGroup, "Launch Buoy!", buoyMenu, self.launchBuoy, self, groupName)
    MENU_GROUP_COMMAND:New(mooseGroup, "Prepare to Recover Buoy", buoyMenu, self.prepareToRecover, self, groupName)
    MENU_GROUP_COMMAND:New(mooseGroup, "Recover Buoy!", buoyMenu, self.recoverBuoy, self, groupName)

    -- Torpedo submenu
    local torpedoMenu = MENU_GROUP:New(mooseGroup, "Torpedo", rootMenu)
    local depthMenu = MENU_GROUP:New(mooseGroup, "Set Search Depth", torpedoMenu)
    for _, d in ipairs({0, 100, 200, 300, 400, 500}) do
        MENU_GROUP_COMMAND:New(mooseGroup, d .. "m", depthMenu, self.setTorpedoDepth, self, groupName, d)
    end
    MENU_GROUP_COMMAND:New(mooseGroup, "Prepare to Launch Torpedo", torpedoMenu, self.prepareToLaunchTorpedo, self, groupName)
    MENU_GROUP_COMMAND:New(mooseGroup, "Launch Torpedo!", torpedoMenu, self.launchTorpedo, self, groupName)

    -- Dipping Sonar submenu
    local sonarMenu = MENU_GROUP:New(mooseGroup, "Dipping Sonar", rootMenu)
    local extendMenu = MENU_GROUP:New(mooseGroup, "Extend Cable", sonarMenu)
    for _, d in ipairs({10, 25, 50, 100}) do
        MENU_GROUP_COMMAND:New(mooseGroup, "+" .. d .. "m", extendMenu, self.adjustSonarCable, self, groupName, d)
    end
    local retractMenu = MENU_GROUP:New(mooseGroup, "Retract Cable", sonarMenu)
    for _, d in ipairs({10, 25, 50, 100}) do
        MENU_GROUP_COMMAND:New(mooseGroup, "-" .. d .. "m", retractMenu, self.adjustSonarCable, self, groupName, -d)
    end
    MENU_GROUP_COMMAND:New(mooseGroup, "Lower Sonar", sonarMenu, self.lowerSonar, self, groupName)
    MENU_GROUP_COMMAND:New(mooseGroup, "Stop Sonar", sonarMenu, self.stopSonar, self, groupName)
    MENU_GROUP_COMMAND:New(mooseGroup, "Raise Sonar", sonarMenu, self.raiseSonar, self, groupName)

    -- General
    MENU_GROUP_COMMAND:New(mooseGroup, "Cancel", rootMenu, self.cancelPrepare, self, groupName)
    MENU_GROUP_COMMAND:New(mooseGroup, "Status", rootMenu, self.showStatus, self, groupName)
    MENU_GROUP_COMMAND:New(mooseGroup, "Rearm", rootMenu, self.rearmAll, self, groupName)

    debugMessage("ASW Hunter group registered: " .. groupName)
end

-- Get the DCS unit for a group (single player group)
function OrdnanceManager:getGroupUnit(groupName)
    local dcsGroup = Group.getByName(groupName)
    if not dcsGroup or not dcsGroup:isExist() then return nil end
    local units = dcsGroup:getUnits()
    if units and #units > 0 and units[1]:isExist() then
        return units[1]
    end
    return nil
end

-- Get heading of the unit in degrees (0-360)
function OrdnanceManager:getUnitHeading(unit)
    if not unit then return 0 end
    local pos = unit:getPosition()
    local hdg = math.deg(math.atan2(pos.x.z, pos.x.x))
    if hdg < 0 then hdg = hdg + 360 end
    return hdg
end

-- Check if unit meets flight parameters for deploy/recover/launch
function OrdnanceManager:checkFlightParams(unit)
    if not unit then return false, "No aircraft found" end

    local pos = unit:getPoint()
    local landHeight = land.getHeight({x = pos.x, y = pos.z})
    local altitudeAGL = pos.y - landHeight
    local velocity = unit:getVelocity()
    local speed = math.sqrt(velocity.x^2 + velocity.y^2 + velocity.z^2)

    local altOk = altitudeAGL <= self.maxAltitude
    local spdOk = speed <= self.maxSpeed

    local msg = string.format("Alt: %.0fm AGL %s | Speed: %.0f m/s %s",
        altitudeAGL, altOk and "OK" or "TOO HIGH",
        speed, spdOk and "OK" or "TOO FAST")

    return altOk and spdOk, msg
end

-- ===== PREPARE TO LAUNCH BUOY =====
function OrdnanceManager:prepareToLaunch(groupName)
    local data = self.groupData[groupName]
    if not data then return end

    if data.state ~= "idle" then
        self:messageToGroup(groupName, "Cancel current operation first!", 5)
        return
    end

    if data.inventory <= 0 then
        self:messageToGroup(groupName, "No buoys remaining! Return to rearm.", 5)
        return
    end

    data.state = "preparing_launch"
    self:messageToGroup(groupName, "Preparing to launch buoy. Get into position.\nAlt < " .. self.maxAltitude .. "m AGL | Speed < " .. self.maxSpeed .. " m/s", 5)
    self:startPrepareMessages(groupName)
end

-- ===== LAUNCH BUOY =====
function OrdnanceManager:launchBuoy(groupName)
    local data = self.groupData[groupName]
    if not data then return end

    if data.state ~= "preparing_launch" then
        self:messageToGroup(groupName, "Use 'Prepare to Launch' first!", 5)
        return
    end

    local unit = self:getGroupUnit(groupName)
    local paramsOk, msg = self:checkFlightParams(unit)

    if not paramsOk then
        self:messageToGroup(groupName, "Cannot launch! " .. msg, 5)
        return
    end

    -- Deploy the buoy
    self.buoyIdCounter = self.buoyIdCounter + 1
    local buoyName = groupName .. "-Buoy-" .. self.buoyIdCounter
    local pos = unit:getPoint()
    local buoy = Sonarbuoy:new(buoyName, pos.x, pos.z, self.ownerCoalition, nil, self.thermalLayerDepth)

    if buoy then
        self.buoys[#self.buoys + 1] = buoy
        data.inventory = data.inventory - 1
        self:messageToGroup(groupName, "Buoy deployed! Remaining: " .. data.inventory .. "/" .. self.maxBuoys, 5)

        -- Splash sound for deploying group and enemy coalition (submarine)
        if ASW_SOUND then
            ASW_SOUND:playOnce(groupName, "buoy_splash")
            local enemyCoalition = self.ownerCoalition == coalition.side.BLUE and coalition.side.RED or coalition.side.BLUE
            ASW_SOUND:playForCoalition(enemyCoalition, "buoy_splash")
        end
    end

    self:stopPrepareMessages(groupName)
    data.state = "idle"
end

-- ===== PREPARE TO RECOVER BUOY =====
function OrdnanceManager:prepareToRecover(groupName)
    local data = self.groupData[groupName]
    if not data then return end

    if data.state ~= "idle" then
        self:messageToGroup(groupName, "Cancel current operation first!", 5)
        return
    end

    data.state = "preparing_recover"
    self:messageToGroup(groupName, "Preparing to recover buoy. Fly near a deployed buoy.\nAlt < " .. self.maxAltitude .. "m AGL | Speed < " .. self.maxSpeed .. " m/s | Range < " .. self.recoveryRange .. "m", 5)
    self:startPrepareMessages(groupName)
end

-- ===== RECOVER BUOY =====
function OrdnanceManager:recoverBuoy(groupName)
    local data = self.groupData[groupName]
    if not data then return end

    if data.state ~= "preparing_recover" then
        self:messageToGroup(groupName, "Use 'Prepare to Recover' first!", 5)
        return
    end

    local unit = self:getGroupUnit(groupName)
    local paramsOk, msg = self:checkFlightParams(unit)

    if not paramsOk then
        self:messageToGroup(groupName, "Cannot recover! " .. msg, 5)
        return
    end

    -- Find nearest active buoy in range
    local pos = unit:getPoint()
    local nearestBuoy = nil
    local nearestDist = self.recoveryRange + 1

    for _, buoy in ipairs(self.buoys) do
        if buoy:isActive() then
            local dx = buoy.x - pos.x
            local dz = buoy.z - pos.z
            local dist = math.sqrt(dx * dx + dz * dz)
            if dist < nearestDist then
                nearestDist = dist
                nearestBuoy = buoy
            end
        end
    end

    if not nearestBuoy then
        self:messageToGroup(groupName, "No buoy within " .. self.recoveryRange .. "m range!", 5)
        return
    end

    nearestBuoy:remove()
    data.inventory = math.min(data.inventory + 1, self.maxBuoys)
    self:messageToGroup(groupName, nearestBuoy.name .. " recovered! Inventory: " .. data.inventory .. "/" .. self.maxBuoys, 5)

    -- Recover splash sound for recovering group and enemy coalition (submarine)
    if ASW_SOUND then
        ASW_SOUND:playOnce(groupName, "recover_splash")
        local enemyCoalition = self.ownerCoalition == coalition.side.BLUE and coalition.side.RED or coalition.side.BLUE
        ASW_SOUND:playForCoalition(enemyCoalition, "recover_splash")
    end

    self:stopPrepareMessages(groupName)
    data.state = "idle"
end

-- ===== SET TORPEDO SEARCH DEPTH =====
function OrdnanceManager:setTorpedoDepth(groupName, depth)
    local data = self.groupData[groupName]
    if not data then return end

    data.torpedoDepth = depth
    self:messageToGroup(groupName, "Torpedo search depth set to " .. depth .. "m", 5)
end

-- ===== PREPARE TO LAUNCH TORPEDO =====
function OrdnanceManager:prepareToLaunchTorpedo(groupName)
    local data = self.groupData[groupName]
    if not data then return end

    if data.state ~= "idle" then
        self:messageToGroup(groupName, "Cancel current operation first!", 5)
        return
    end

    if data.torpedoInventory <= 0 then
        self:messageToGroup(groupName, "No torpedoes remaining! Return to rearm.", 5)
        return
    end

    data.state = "preparing_torpedo"
    self:messageToGroup(groupName, "Preparing to launch torpedo.\nSearch depth: " .. data.torpedoDepth .. "m\nAlt < " .. self.maxAltitude .. "m AGL | Speed < " .. self.maxSpeed .. " m/s\nTorpedo will follow your current heading.", 5)
    self:startPrepareMessages(groupName)
end

-- ===== LAUNCH TORPEDO =====
function OrdnanceManager:launchTorpedo(groupName)
    local data = self.groupData[groupName]
    if not data then return end

    if data.state ~= "preparing_torpedo" then
        self:messageToGroup(groupName, "Use 'Prepare to Launch Torpedo' first!", 5)
        return
    end

    local unit = self:getGroupUnit(groupName)
    local paramsOk, msg = self:checkFlightParams(unit)

    if not paramsOk then
        self:messageToGroup(groupName, "Cannot launch torpedo! " .. msg, 5)
        return
    end

    -- Launch the torpedo
    self.torpedoIdCounter = self.torpedoIdCounter + 1
    local torpedoName = groupName .. "-Torpedo-" .. self.torpedoIdCounter
    local pos = unit:getPoint()
    local heading = self:getUnitHeading(unit)

    local torpedo = AntiSubmarineTorpedo:new(
        torpedoName, pos.x, pos.z, heading, data.torpedoDepth,
        self.ownerCoalition, self.submarines, self.thermalLayerDepth
    )

    if torpedo then
        self.torpedoes[#self.torpedoes + 1] = torpedo
        data.torpedoInventory = data.torpedoInventory - 1
        self:messageToGroup(groupName, string.format(
            "Torpedo away! Heading: %.0f° | Depth: %dm | Torpedoes remaining: %d/%d",
            heading, data.torpedoDepth, data.torpedoInventory, self.maxTorpedoes), 5)

        -- Torpedo launch sound for hunter group + warning for enemy coalition
        if ASW_SOUND then
            ASW_SOUND:playOnce(groupName, "torpedo_launch")
            local enemyCoalition = self.ownerCoalition == coalition.side.BLUE and coalition.side.RED or coalition.side.BLUE
            ASW_SOUND:playForCoalition(enemyCoalition, "warning_torpedo")
        end
    end

    self:stopPrepareMessages(groupName)
    data.state = "idle"
end

-- ===== CANCEL =====
function OrdnanceManager:cancelPrepare(groupName)
    local data = self.groupData[groupName]
    if not data then return end

    if data.state == "idle" then
        self:messageToGroup(groupName, "Nothing to cancel.", 5)
        return
    end

    self:stopPrepareMessages(groupName)
    data.state = "idle"
    self:messageToGroup(groupName, "Operation cancelled.", 5)
end

-- ===== STATUS =====
function OrdnanceManager:showStatus(groupName)
    local data = self.groupData[groupName]
    if not data then return end

    local activeBuoys = 0
    for _, buoy in ipairs(self.buoys) do
        if buoy:isActive() then
            activeBuoys = activeBuoys + 1
        end
    end

    local activeTorpedoes = 0
    for _, torpedo in ipairs(self.torpedoes) do
        if torpedo:isActive() then
            activeTorpedoes = activeTorpedoes + 1
        end
    end

    local msg = string.format(
        "=== ASW Status ===\nBuoys: %d/%d | Active (all): %d\nTorpedoes: %d/%d | Active (all): %d\nTorpedo depth: %dm\nDipping sonar: %s\nState: %s",
        data.inventory, self.maxBuoys, activeBuoys,
        data.torpedoInventory, self.maxTorpedoes, activeTorpedoes,
        data.torpedoDepth,
        data.dippingSonar and (data.dippingSonar.operational and data.dippingSonar.state or "BROKEN") or "N/A",
        data.state)
    self:messageToGroup(groupName, msg, 10)
end

-- ===== REARM =====
function OrdnanceManager:rearmAll(groupName)
    local data = self.groupData[groupName]
    if not data then return end

    local unit = self:getGroupUnit(groupName)
    if not unit then return end

    local pos = unit:getPoint()
    local inRange = false

    -- Check rearm unit first (moving platform like a carrier)
    if self.rearmUnit then
        local rearmDcsUnit = Unit.getByName(self.rearmUnit)
        if rearmDcsUnit and rearmDcsUnit:isExist() then
            local rPos = rearmDcsUnit:getPoint()
            local dx = pos.x - rPos.x
            local dz = pos.z - rPos.z
            local dist = math.sqrt(dx * dx + dz * dz)
            inRange = dist <= self.rearmRadius
        end
    else
        -- Fallback to static trigger zone
        local zone = trigger.misc.getZone(self.rearmZone)
        if not zone then
            self:messageToGroup(groupName, "Rearm zone not configured!", 5)
            return
        end
        local dx = pos.x - zone.point.x
        local dz = pos.z - zone.point.z
        local dist = math.sqrt(dx * dx + dz * dz)
        inRange = dist <= zone.radius
    end

    if not inRange then
        self:messageToGroup(groupName, "Not inside rearm zone! Fly to the designated rearm area.", 5)
        return
    end

    data.inventory = self.maxBuoys
    data.torpedoInventory = self.maxTorpedoes
    if data.dippingSonar and not data.dippingSonar.operational then
        data.dippingSonar:repair()
    end
    self:messageToGroup(groupName, string.format(
        "Rearmed! Buoys: %d/%d | Torpedoes: %d/%d | Dipping sonar: %s",
        data.inventory, self.maxBuoys, data.torpedoInventory, self.maxTorpedoes,
        data.dippingSonar and (data.dippingSonar.operational and "OK" or "REPAIRED") or "N/A"), 5)
end

-- ===== DIPPING SONAR =====
function OrdnanceManager:adjustSonarCable(groupName, delta)
    local data = self.groupData[groupName]
    if not data or not data.dippingSonar then return end
    local sonar = data.dippingSonar
    sonar:adjustCable(delta)
    local waterDepth = sonar:getWaterDepth()
    local msg
    if sonar:isDeployed() then
        msg = string.format("Cable target: %dm (current: %.0fm) | Sonar depth: %.0fm",
            sonar.targetCableLength, sonar.currentCableLength, waterDepth)
    else
        msg = string.format("Cable target set to %dm (deploy with Lower Sonar)", sonar.targetCableLength)
    end
    self:messageToGroup(groupName, msg, 5)
end

function OrdnanceManager:lowerSonar(groupName)
    local data = self.groupData[groupName]
    if not data or not data.dippingSonar then return end
    local ok, msg = data.dippingSonar:lower()
    self:messageToGroup(groupName, msg, 5)
end

function OrdnanceManager:stopSonar(groupName)
    local data = self.groupData[groupName]
    if not data or not data.dippingSonar then return end
    local ok, msg = data.dippingSonar:stop()
    self:messageToGroup(groupName, msg, 5)
end

function OrdnanceManager:raiseSonar(groupName)
    local data = self.groupData[groupName]
    if not data or not data.dippingSonar then return end
    local ok, msg = data.dippingSonar:raise()
    self:messageToGroup(groupName, msg, 5)
end

-- ===== PREPARE MODE MESSAGES =====
function OrdnanceManager:startPrepareMessages(groupName)
    local data = self.groupData[groupName]
    if not data then return end

    local function sendMessages()
        local d = self.groupData[groupName]
        if not d or d.state == "idle" then return end

        local unit = self:getGroupUnit(groupName)
        if not unit then return end

        local _, msg = self:checkFlightParams(unit)

        -- For recover mode, also show distance to nearest buoy
        if d.state == "preparing_recover" then
            local pos = unit:getPoint()
            local nearestDist = nil
            local nearestName = nil
            for _, buoy in ipairs(self.buoys) do
                if buoy:isActive() then
                    local dx = buoy.x - pos.x
                    local dz = buoy.z - pos.z
                    local dist = math.sqrt(dx * dx + dz * dz)
                    if not nearestDist or dist < nearestDist then
                        nearestDist = dist
                        nearestName = buoy.name
                    end
                end
            end

            if nearestDist then
                local rangeOk = nearestDist <= self.recoveryRange
                msg = msg .. string.format("\nNearest buoy: %s (%.0fm) %s", nearestName, nearestDist, rangeOk and "IN RANGE" or "TOO FAR")
            else
                msg = msg .. "\nNo active buoys deployed!"
            end
        end

        -- For torpedo mode, show heading and depth setting
        if d.state == "preparing_torpedo" then
            local heading = self:getUnitHeading(unit)
            msg = msg .. string.format("\nTorpedo heading: %.0f° | Search depth: %dm", heading, d.torpedoDepth)
        end

        self:messageToGroup(groupName, msg, 1)

        data.prepareScheduleId = timer.scheduleFunction(function()
            sendMessages()
        end, nil, timer.getTime() + 1)
    end

    sendMessages()
end

function OrdnanceManager:stopPrepareMessages(groupName)
    local data = self.groupData[groupName]
    if data and data.prepareScheduleId then
        timer.removeFunction(data.prepareScheduleId)
        data.prepareScheduleId = nil
    end
end

-- ===== DETECTION LOOP =====
function OrdnanceManager:startDetectionLoop()
    local function detect()
        for _, buoy in ipairs(self.buoys) do
            if buoy:isActive() then
                buoy:detect(self.submarines)
            end
        end

        timer.scheduleFunction(function()
            detect()
        end, nil, timer.getTime() + self.detectInterval)
    end

    -- Start after a short delay to let everything initialize
    timer.scheduleFunction(function()
        detect()
    end, nil, timer.getTime() + self.detectInterval)
end

-- ===== UTILITY =====
function OrdnanceManager:getDippingSonars()
    return self.dippingSonars
end

function OrdnanceManager:messageToGroup(groupName, message, duration)
    local mooseGroup = GROUP:FindByName(groupName)
    if mooseGroup then
        trigger.action.outTextForGroup(mooseGroup:GetDCSObject():getID(), message, duration or 5, false)
    end
end
