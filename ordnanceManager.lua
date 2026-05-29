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

-- Base class for ASW hunter group management.
-- Handles buoy deployment, torpedo launch, inventory, rearm, and F10 menus.
-- Subclasses override initGroup() to add type-specific capabilities
-- (dipping sonar, buoy recovery, etc.).
--
-- config table:
--   ownerCoalition:   coalition side for ASW hunters
--   submarines:       table of detectable objects (VirtualSubmarine + NoiseMakers)
--   hunterPrefix:     group name prefix to find hunter groups
--   rearmZone:        trigger zone name for rearming (static fallback)
--   rearmUnits:       table of DCS unit names as moving rearm points (overrides rearmZone)
--   rearmRadius:      radius around each rearmUnit in meters (default 500)
--   maxBuoys:         max buoys per group (default 4)
--   maxTorpedoes:     max torpedoes per group (default 1)
--   maxAltitude:      max AGL in meters for deploy/launch operations (default 50)
--   maxSpeed:         max speed in m/s for deploy/launch operations (default 60)
--   recoveryRange:    max distance to recover a buoy in meters (default 10)
--   thermalLayerDepth thermal layer depth for spawned ordnance (default 90)
--   detectInterval:   seconds between sonarbuoy detection cycles (default 5)
--   buoys:            shared buoy pool table (default: new empty table)
--   torpedoes:        shared torpedo pool table (default: new empty table)
--   dippingSonars:    shared dipping sonar pool table (default: new empty table)
function OrdnanceManager:new(config)
    local obj = {
        ownerCoalition    = config.ownerCoalition or coalition.side.BLUE,
        submarines        = config.submarines or {},
        hunterPrefix      = config.hunterPrefix or "_asw_hunter",
        rearmZone         = config.rearmZone or "ASW_Hunter_Rearming",
        rearmUnits        = config.rearmUnits or {},
        rearmRadius       = config.rearmRadius or 500,
        maxBuoys          = config.maxBuoys or 4,
        maxTorpedoes      = config.maxTorpedoes or 1,
        maxAltitude       = config.maxAltitude or 50,
        maxSpeed          = config.maxSpeed or 60,
        recoveryRange     = config.recoveryRange or 10,
        thermalLayerDepth = config.thermalLayerDepth or 90,
        detectInterval    = config.detectInterval or 5,
        buoys             = config.buoys or {},
        torpedoes         = config.torpedoes or {},
        dippingSonars     = config.dippingSonars or {},
        groupData         = {},
        buoyIdCounter     = 0,
        torpedoIdCounter  = 0,
        trackedGroups     = {},
    }
    setmetatable(obj, self)
    obj:startGroupScanner()
    return obj
end

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
        self:cleanupDestroyedGroups()
        timer.scheduleFunction(function() scan() end, nil, timer.getTime() + 10)
    end
    scan()
end

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

-- Initialize tracking and menus for a hunter group.
-- Builds buoy deploy + torpedo + general menus, and stores handles in
-- data.menus so subclasses can extend them after calling this.
function OrdnanceManager:initGroup(groupName)
    self.trackedGroups[groupName] = true
    self.groupData[groupName] = {
        inventory         = self.maxBuoys,
        torpedoInventory  = self.maxTorpedoes,
        torpedoDepth      = 100,
        state             = "idle",
        prepareScheduleId = nil,
        menus             = {},
    }

    local mooseGroup = GROUP:FindByName(groupName)
    if not mooseGroup then return end

    local data = self.groupData[groupName]
    local rootMenu = MENU_GROUP:New(mooseGroup, "ASW Operations")
    data.menus.root = rootMenu

    -- Sonarbuoy submenu
    local buoyMenu = MENU_GROUP:New(mooseGroup, "Sonarbuoys", rootMenu)
    data.menus.buoy = buoyMenu
    MENU_GROUP_COMMAND:New(mooseGroup, "Prepare to Launch Buoy", buoyMenu, self.prepareToLaunch, self, groupName)
    MENU_GROUP_COMMAND:New(mooseGroup, "Launch Buoy!", buoyMenu, self.launchBuoy, self, groupName)

    -- Torpedo submenu
    local torpedoMenu = MENU_GROUP:New(mooseGroup, "Torpedo", rootMenu)
    data.menus.torpedo = torpedoMenu
    local depthMenu = MENU_GROUP:New(mooseGroup, "Set Search Depth", torpedoMenu)
    for _, d in ipairs({0, 50, 100, 150, 200, 250, 300, 400, 500}) do
        MENU_GROUP_COMMAND:New(mooseGroup, d .. "m", depthMenu, self.setTorpedoDepth, self, groupName, d)
    end
    MENU_GROUP_COMMAND:New(mooseGroup, "Prepare to Launch Torpedo", torpedoMenu, self.prepareToLaunchTorpedo, self, groupName)
    MENU_GROUP_COMMAND:New(mooseGroup, "Launch Torpedo!", torpedoMenu, self.launchTorpedo, self, groupName)

    -- General
    MENU_GROUP_COMMAND:New(mooseGroup, "Cancel", rootMenu, self.cancelPrepare, self, groupName)
    MENU_GROUP_COMMAND:New(mooseGroup, "Status", rootMenu, self.showStatus, self, groupName)
    MENU_GROUP_COMMAND:New(mooseGroup, "Rearm", rootMenu, self.rearmAll, self, groupName)

    debugMessage("ASW Hunter group registered: " .. groupName)
end

function OrdnanceManager:getGroupUnit(groupName)
    local dcsGroup = Group.getByName(groupName)
    if not dcsGroup or not dcsGroup:isExist() then return nil end
    local units = dcsGroup:getUnits()
    if units and #units > 0 and units[1]:isExist() then
        return units[1]
    end
    return nil
end

function OrdnanceManager:getUnitHeading(unit)
    if not unit then return 0 end
    local pos = unit:getPosition()
    local hdg = math.deg(math.atan2(pos.x.z, pos.x.x))
    if hdg < 0 then hdg = hdg + 360 end
    return hdg
end

function OrdnanceManager:checkFlightParams(unit)
    if not unit then return false, "No aircraft found" end

    local pos = unit:getPoint()
    local landHeight = land.getHeight({x = pos.x, y = pos.z})
    local altitudeAGL = pos.y - landHeight
    local velocity = unit:getVelocity()
    local speed = math.sqrt(velocity.x^2 + velocity.y^2 + velocity.z^2)

    local altOk = altitudeAGL <= self.maxAltitude
    local spdOk = speed <= self.maxSpeed
    local speedKt = speed * 1.943844

    local msg = string.format("Alt: %.0fm AGL %s | Speed: %.0f kt %s",
        altitudeAGL, altOk and "OK" or "TOO HIGH",
        speedKt, spdOk and "OK" or "TOO FAST")

    return altOk and spdOk, msg
end

function OrdnanceManager:isPositionOverWater(x, z)
    local _, waterDepth = land.getSurfaceHeightWithSeabed({x = x, y = z})
    return waterDepth > 0
end

-- ===== SONARBUOY =====

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
    local maxSpeedKt = self.maxSpeed * 1.943844
    self:messageToGroup(groupName, "Preparing to launch buoy. Get into position.\nAlt < " .. self.maxAltitude .. "m AGL | Speed < " .. string.format("%.0f", maxSpeedKt) .. " kt", 5)
    self:startPrepareMessages(groupName)
end

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

    local pos = unit:getPoint()
    if not self:isPositionOverWater(pos.x, pos.z) then
        self:messageToGroup(groupName, "Cannot launch! You are over land, buoys must be deployed over water!", 5)
        return
    end

    self.buoyIdCounter = self.buoyIdCounter + 1
    local buoyName = groupName .. "-Buoy-" .. self.buoyIdCounter
    local buoy = Sonarbuoy:new(buoyName, pos.x, pos.z, self.ownerCoalition, nil, self.thermalLayerDepth)

    if buoy then
        self.buoys[#self.buoys + 1] = buoy
        data.inventory = data.inventory - 1
        self:messageToGroup(groupName, "Buoy deployed! Remaining: " .. data.inventory .. "/" .. self.maxBuoys, 5)

        if ASW_SOUND then
            local enemyCoalition = self.ownerCoalition == coalition.side.BLUE and coalition.side.RED or coalition.side.BLUE
            ASW_SOUND:playOnce(groupName, "buoy_splash")
            ASW_SOUND:playForCoalition(self.ownerCoalition, "buoy_splash")
            ASW_SOUND:playForCoalition(enemyCoalition, "buoy_splash")
        end
    end

    self:stopPrepareMessages(groupName)
    data.state = "idle"
end

-- ===== TORPEDO =====

function OrdnanceManager:setTorpedoDepth(groupName, depth)
    local data = self.groupData[groupName]
    if not data then return end
    data.torpedoDepth = depth
    self:messageToGroup(groupName, "Torpedo search depth set to " .. depth .. "m", 5)
end

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
    local maxSpeedKt = self.maxSpeed * 1.943844
    self:messageToGroup(groupName, "Preparing to launch torpedo.\nSearch depth: " .. data.torpedoDepth .. "m\nAlt < " .. self.maxAltitude .. "m AGL | Speed < " .. string.format("%.0f", maxSpeedKt) .. " kt\nTorpedo will follow your current heading.", 5)
    self:startPrepareMessages(groupName)
end

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

        if ASW_SOUND then
            local enemyCoalition = self.ownerCoalition == coalition.side.BLUE and coalition.side.RED or coalition.side.BLUE
            ASW_SOUND:playOnce(groupName, "torpedo_launch")
            ASW_SOUND:playForCoalition(self.ownerCoalition, "torpedo_launch")
            ASW_SOUND:playForCoalition(enemyCoalition, "warning_torpedo")
        end
    end

    self:stopPrepareMessages(groupName)
    data.state = "idle"
end

-- ===== GENERAL =====

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

function OrdnanceManager:showStatus(groupName)
    local data = self.groupData[groupName]
    if not data then return end

    local activeBuoys = 0
    for _, buoy in ipairs(self.buoys) do
        if buoy:isActive() then activeBuoys = activeBuoys + 1 end
    end

    local activeTorpedoes = 0
    for _, torpedo in ipairs(self.torpedoes) do
        if torpedo:isActive() then activeTorpedoes = activeTorpedoes + 1 end
    end

    local msg = string.format(
        "=== ASW Status ===\nBuoys: %d/%d | Active (all): %d\nTorpedoes: %d/%d | Active (all): %d\nTorpedo depth: %dm\nState: %s",
        data.inventory, self.maxBuoys, activeBuoys,
        data.torpedoInventory, self.maxTorpedoes, activeTorpedoes,
        data.torpedoDepth, data.state)

    if data.dippingSonar then
        msg = msg .. "\nDipping sonar: " .. (data.dippingSonar.operational and data.dippingSonar.state or "BROKEN")
    end

    self:messageToGroup(groupName, msg, 10)
end

function OrdnanceManager:rearmAll(groupName)
    local data = self.groupData[groupName]
    if not data then return end

    local unit = self:getGroupUnit(groupName)
    if not unit then return end

    local pos = unit:getPoint()
    local inRange = false

    if self.rearmUnits and #self.rearmUnits > 0 then
        for _, unitName in ipairs(self.rearmUnits) do
            local rearmDcsUnit = Unit.getByName(unitName)
            if rearmDcsUnit and rearmDcsUnit:isExist() then
                local rPos = rearmDcsUnit:getPoint()
                local dx = pos.x - rPos.x
                local dz = pos.z - rPos.z
                local dist = math.sqrt(dx * dx + dz * dz)
                if dist <= self.rearmRadius then
                    inRange = true
                    break
                end
            end
        end
    else
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

    local sonarStatus = ""
    if data.dippingSonar and not data.dippingSonar.operational then
        data.dippingSonar:repair()
        sonarStatus = " | Dipping sonar: REPAIRED"
    end

    self:messageToGroup(groupName, string.format(
        "Rearmed! Buoys: %d/%d | Torpedoes: %d/%d%s",
        data.inventory, self.maxBuoys, data.torpedoInventory, self.maxTorpedoes, sonarStatus), 5)
end

-- ===== PREPARE MODE HUD =====

function OrdnanceManager:startPrepareMessages(groupName)
    local data = self.groupData[groupName]
    if not data then return end

    local function sendMessages()
        local d = self.groupData[groupName]
        if not d or d.state == "idle" then return end

        local unit = self:getGroupUnit(groupName)
        if not unit then return end

        local _, msg = self:checkFlightParams(unit)

        if d.state == "preparing_launch" then
            local pos = unit:getPoint()
            local overWater = self:isPositionOverWater(pos.x, pos.z)
            msg = msg .. "\n" .. (overWater and "WATER OK" or "LAND - NO DEPLOY")
        end

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
-- Call this once after creating all managers that share the same buoys table.

function OrdnanceManager:startDetectionLoop()
    local function detect()
        for _, buoy in ipairs(self.buoys) do
            if buoy:isActive() then
                buoy:detect(self.submarines)
            end
        end
        timer.scheduleFunction(function() detect() end, nil, timer.getTime() + self.detectInterval)
    end
    timer.scheduleFunction(function() detect() end, nil, timer.getTime() + self.detectInterval)
end

-- ===== UTILITY =====

function OrdnanceManager:getDippingSonars()
    return self.dippingSonars
end

function OrdnanceManager:log(message)
    trigger.action.outTextForCoalition(self.ownerCoalition, message, 15, false)
    env.info(message, false)
end

function OrdnanceManager:messageToGroup(groupName, message, duration)
    local mooseGroup = GROUP:FindByName(groupName)
    if mooseGroup then
        trigger.action.outTextForGroup(mooseGroup:GetDCSObject():getID(), message, duration or 5, false)
    end
end
