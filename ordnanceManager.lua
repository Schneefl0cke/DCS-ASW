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
--   globalBuoyPool:   shared {count=N} table for mission-wide buoy reserve
--   buoyLifetime:     battery life in seconds per buoy (nil = unlimited)
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
        maxDepthCharges   = config.maxDepthCharges or 0,
        dcMaxAltitude     = config.dcMaxAltitude or 500,
        dcMaxSpeed        = config.dcMaxSpeed or 200,
        globalBuoyPool    = config.globalBuoyPool or {count = 0},
        buoyLifetime      = config.buoyLifetime,  -- nil = unlimited
        groupData         = {},
        buoyIdCounter     = 0,
        torpedoIdCounter  = 0,
        dcIdCounter       = 0,
        trackedGroups     = {},
    }
    setmetatable(obj, self)
    obj:validateConfig()
    obj:startGroupScanner()
    return obj
end

function OrdnanceManager:validateConfig()
    local prefix = "ASW [" .. self.hunterPrefix .. "]"

    -- Rearm zone
    if self.rearmZone and self.rearmZone ~= "" then
        if not trigger.misc.getZone(self.rearmZone) then
            trigger.action.outTextForCoalition(self.ownerCoalition,
                prefix .. " WARNING: Rearm zone '" .. self.rearmZone .. "' not found in mission.", 20)
            env.info(prefix .. " WARNING: Rearm zone '" .. self.rearmZone .. "' not found in mission.", false)
        end
    end

    -- Rearm units (late-activated units may not be visible at startup)
    for _, unitName in ipairs(self.rearmUnits) do
        if not Unit.getByName(unitName) then
            trigger.action.outTextForCoalition(self.ownerCoalition,
                prefix .. " WARNING: Rearm unit '" .. unitName .. "' not found (late-activated? wrong name?).", 20)
            env.info(prefix .. " WARNING: Rearm unit '" .. unitName .. "' not found.", false)
        end
    end
end

function OrdnanceManager:startGroupScanner()
    -- In multiplayer, players join slots after the mission starts.
    -- React immediately when a player enters a hunter group slot so their
    -- menus are created right at join time (avoids F10 menu sync issues).
    local mgr = self
    local playerEnterHandler = {}
    function playerEnterHandler:onEvent(event)
        if event.id == world.event.S_EVENT_PLAYER_ENTER_UNIT then
            local unit = event.initiator
            if unit and unit:isExist() then
                local group = unit:getGroup()
                if group then
                    local gName = group:getName()
                    if mgr:isHunterGroup(gName) and not mgr.trackedGroups[gName] then
                        mgr:initGroup(gName)
                    end
                end
            end
        end
    end
    world.addEventHandler(playerEnterHandler)

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
        if data and data.madDetector then
            data.madDetector:stopUpdateLoop()
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
    if self.trackedGroups[groupName] then
        return
    end

    local dcsGroup = Group.getByName(groupName)
    if dcsGroup then
        local units = dcsGroup:getUnits()
        if units and #units > 1 then
            self.trackedGroups[groupName] = true
            self:log("ASW: Group '" .. groupName .. "' has " .. #units .. " units. Hunter groups must have exactly 1 unit — skipping.")
            return
        end
    end

    self.groupData[groupName] = {
        freshCount        = self.maxBuoys,
        savedBuoys        = {},
        expiredCount      = 0,
        torpedoInventory  = self.maxTorpedoes,
        torpedoDepth      = 100,
        dcInventory       = self.maxDepthCharges,
        dcDepth           = 50,
        dcCount           = 4,
        dcSpacing         = 200,
        state             = "idle",
        prepareScheduleId = nil,
        menus             = {},
    }

    local mooseGroup = GROUP:FindByName(groupName)
    if not mooseGroup then
        self.groupData[groupName] = nil  -- clean up so the next scan cycle can retry
        return
    end

    self.trackedGroups[groupName] = true
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

    -- Depth charges submenu (only shown when inventory is configured)
    if self.maxDepthCharges > 0 then
        local dcMenu = MENU_GROUP:New(mooseGroup, "Depth Charges", rootMenu)
        data.menus.dc = dcMenu
        local dcDepthMenu = MENU_GROUP:New(mooseGroup, "Set Detonation Depth", dcMenu)
        for _, d in ipairs({25, 50, 100, 150, 200, 300}) do
            MENU_GROUP_COMMAND:New(mooseGroup, d .. "m", dcDepthMenu, self.setDCDepth, self, groupName, d)
        end
        local dcCountMenu = MENU_GROUP:New(mooseGroup, "Set Count", dcMenu)
        for _, c in ipairs({1, 2, 4, 6, 8}) do
            MENU_GROUP_COMMAND:New(mooseGroup, c .. " charge(s)", dcCountMenu, self.setDCCount, self, groupName, c)
        end
        local dcSpacingMenu = MENU_GROUP:New(mooseGroup, "Set Spacing", dcMenu)
        for _, s in ipairs({100, 200, 400, 600}) do
            MENU_GROUP_COMMAND:New(mooseGroup, s .. "m", dcSpacingMenu, self.setDCSpacing, self, groupName, s)
        end
        MENU_GROUP_COMMAND:New(mooseGroup, "Prepare to Drop", dcMenu, self.prepareToDrop, self, groupName)
        MENU_GROUP_COMMAND:New(mooseGroup, "Drop!", dcMenu, self.dropCharges, self, groupName)
    end

    -- General
    MENU_GROUP_COMMAND:New(mooseGroup, "Cancel", rootMenu, self.cancelPrepare, self, groupName)
    MENU_GROUP_COMMAND:New(mooseGroup, "Status", rootMenu, self.showStatus, self, groupName)
    MENU_GROUP_COMMAND:New(mooseGroup, "Rearm", rootMenu, self.rearmAll, self, groupName)

    local unit = self:getGroupUnit(groupName)
    local typeName = unit and unit:getTypeName() or groupName
    self:messageToGroup(groupName, "ASW hunter slot active: " .. typeName .. "\nUse F10 \226\134\146 ASW Operations to begin.", 15)

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

    local deployable = data.freshCount + #data.savedBuoys
    if deployable <= 0 then
        local hint = data.expiredCount > 0
            and string.format(" (%d expired buoys on board — rearm to revive)", data.expiredCount)
            or ""
        self:messageToGroup(groupName, "No buoys remaining! Return to rearm zone." .. hint, 5)
        return
    end

    data.state = "preparing_launch"
    local maxSpeedKt = self.maxSpeed * 1.943844

    local buoyInfo
    if #data.savedBuoys > 0 then
        local saved = data.savedBuoys[#data.savedBuoys]
        buoyInfo = "saved buoy (" .. saved:getBatteryText() .. " remaining)"
    elseif self.buoyLifetime then
        buoyInfo = string.format("fresh buoy (%d min battery)", math.floor(self.buoyLifetime / 60))
    else
        buoyInfo = "fresh buoy"
    end

    self:messageToGroup(groupName, string.format(
        "Preparing to launch buoy. Get into position.\nNext: %s\nAlt < %dm AGL | Speed < %.0f kt",
        buoyInfo, self.maxAltitude, maxSpeedKt), 5)
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

    local buoy
    if #data.savedBuoys > 0 then
        -- Redeploy a recovered buoy with its preserved battery
        local savedBuoy = table.remove(data.savedBuoys, #data.savedBuoys)
        local ok, err = savedBuoy:redeploy(pos.x, pos.z)
        if not ok then
            table.insert(data.savedBuoys, savedBuoy)
            self:messageToGroup(groupName, "Cannot deploy: " .. (err or "unknown error"), 5)
            self:stopPrepareMessages(groupName)
            data.state = "idle"
            return
        end
        buoy = savedBuoy
        self.buoys[#self.buoys + 1] = buoy
    else
        -- Deploy a fresh buoy (draws from freshCount)
        self.buoyIdCounter = self.buoyIdCounter + 1
        local buoyName = groupName .. "-Buoy-" .. self.buoyIdCounter
        buoy = Sonarbuoy:new(buoyName, pos.x, pos.z, self.ownerCoalition, nil, self.thermalLayerDepth, self.buoyLifetime)
        if not buoy then
            self:stopPrepareMessages(groupName)
            data.state = "idle"
            return
        end
        self.buoys[#self.buoys + 1] = buoy
        data.freshCount = data.freshCount - 1
    end

    local deployable = data.freshCount + #data.savedBuoys
    self:messageToGroup(groupName, string.format(
        "Buoy deployed! Ready: %d (%d fresh, %d saved) | Expired: %d | Pool: %d",
        deployable, data.freshCount, #data.savedBuoys, data.expiredCount, self.globalBuoyPool.count), 5)

    if ASW_SOUND then
        local enemyCoalition = self.ownerCoalition == coalition.side.BLUE and coalition.side.RED or coalition.side.BLUE
        ASW_SOUND:playOnce(groupName, "buoy_splash")
        ASW_SOUND:playForCoalition(self.ownerCoalition, "buoy_splash")
        ASW_SOUND:playForCoalition(enemyCoalition, "buoy_splash")
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

    local deployedActive = 0
    local deployedDead   = 0
    for _, buoy in ipairs(self.buoys) do
        if buoy.active then
            if buoy.batteryDepleted then deployedDead   = deployedDead   + 1
            else                         deployedActive = deployedActive + 1
            end
        end
    end

    local activeTorpedoes = 0
    for _, torpedo in ipairs(self.torpedoes) do
        if torpedo:isActive() then activeTorpedoes = activeTorpedoes + 1 end
    end

    local deployable = data.freshCount + #data.savedBuoys
    local msg = string.format(
        "=== ASW Status ===\n" ..
        "Buoys: %d ready (%d fresh, %d saved) | %d expired | Pool: %d\n" ..
        "Deployed: %d active, %d dead\n" ..
        "Torpedoes: %d/%d | Active: %d | Depth: %dm\n" ..
        "State: %s",
        deployable, data.freshCount, #data.savedBuoys, data.expiredCount, self.globalBuoyPool.count,
        deployedActive, deployedDead,
        data.torpedoInventory, self.maxTorpedoes, activeTorpedoes,
        data.torpedoDepth, data.state)

    if data.dippingSonar then
        msg = msg .. "\nDipping sonar: " .. (data.dippingSonar.operational and data.dippingSonar.state or "BROKEN")
    end
    if data.dcInventory and self.maxDepthCharges > 0 then
        msg = msg .. string.format("\nDepth charges: %d/%d | Depth: %dm | %d x %dm",
            data.dcInventory, self.maxDepthCharges, data.dcDepth, data.dcCount, data.dcSpacing)
    end
    if data.madDetector then
        msg = msg .. "\n" .. data.madDetector:getStatusText()
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

    for _, unitName in ipairs(self.rearmUnits) do
        local rearmDcsUnit = Unit.getByName(unitName)
        if rearmDcsUnit and rearmDcsUnit:isExist() then
            local rPos = rearmDcsUnit:getPoint()
            local dx = pos.x - rPos.x
            local dz = pos.z - rPos.z
            if math.sqrt(dx * dx + dz * dz) <= self.rearmRadius then
                inRange = true
                break
            end
        end
    end

    if not inRange then
        local zone = trigger.misc.getZone(self.rearmZone)
        if zone then
            local dx = pos.x - zone.point.x
            local dz = pos.z - zone.point.z
            inRange = math.sqrt(dx * dx + dz * dz) <= zone.radius
        end
    end

    if not inRange then
        self:messageToGroup(groupName, "Not inside rearm zone! Fly to the designated rearm area.", 5)
        return
    end

    -- Revive expired recovered buoys (carrier replaces batteries — free)
    local revived = data.expiredCount
    data.freshCount  = data.freshCount + revived
    data.expiredCount = 0

    -- Top up from global pool up to maxBuoys
    local space    = self.maxBuoys - data.freshCount - #data.savedBuoys
    local fromPool = math.min(math.max(0, space), self.globalBuoyPool.count)
    if fromPool > 0 then
        data.freshCount              = data.freshCount + fromPool
        self.globalBuoyPool.count    = self.globalBuoyPool.count - fromPool
    end

    data.torpedoInventory = self.maxTorpedoes

    local extras = ""
    if data.dippingSonar and not data.dippingSonar.operational then
        data.dippingSonar:repair()
        extras = extras .. " | Sonar: REPAIRED"
    end
    if data.dcInventory ~= nil and self.maxDepthCharges > 0 then
        data.dcInventory = self.maxDepthCharges
        extras = extras .. " | DC: restocked"
    end
    if data.madDetector then
        data.madDetector.charge = 100
        extras = extras .. " | MAD: recharged"
    end

    local deployable = data.freshCount + #data.savedBuoys
    local poolNote   = self.globalBuoyPool.count == 0 and " (pool empty — recover buoys!)" or ""
    self:messageToGroup(groupName, string.format(
        "Rearmed!\nBuoys: %d ready (%d fresh, %d saved) | %d revived | Pool: %d%s\nTorpedoes: %d/%d%s",
        deployable, data.freshCount, #data.savedBuoys, revived, self.globalBuoyPool.count, poolNote,
        data.torpedoInventory, self.maxTorpedoes, extras), 8)
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

        local _, msg
        if d.state == "preparing_dc" then
            _, msg = self:checkDCFlightParams(unit)
        else
            _, msg = self:checkFlightParams(unit)
        end

        if d.state == "preparing_launch" then
            local pos = unit:getPoint()
            local overWater = self:isPositionOverWater(pos.x, pos.z)
            msg = msg .. "\n" .. (overWater and "WATER OK" or "LAND - NO DEPLOY")
        end

        if d.state == "preparing_recover" then
            local pos = unit:getPoint()
            local nearestDist  = nil
            local nearestName  = nil
            local nearestState = nil
            -- Show both powered and depleted buoys — both are recoverable
            for _, buoy in ipairs(self.buoys) do
                if buoy.active then
                    local dx   = buoy.x - pos.x
                    local dz   = buoy.z - pos.z
                    local dist = math.sqrt(dx * dx + dz * dz)
                    if not nearestDist or dist < nearestDist then
                        nearestDist  = dist
                        nearestName  = buoy.name
                        nearestState = buoy.batteryDepleted and "DEAD" or buoy:getBatteryText()
                    end
                end
            end
            if nearestDist then
                local rangeOk = nearestDist <= self.recoveryRange
                msg = msg .. string.format("\nNearest: %s [%s] (%.0fm) %s",
                    nearestName, nearestState, nearestDist, rangeOk and "IN RANGE" or "TOO FAR")
            else
                msg = msg .. "\nNo buoys deployed!"
            end
        end

        if d.state == "preparing_torpedo" then
            local heading = self:getUnitHeading(unit)
            msg = msg .. string.format("\nTorpedo heading: %.0f° | Search depth: %dm", heading, d.torpedoDepth)
        end

        if d.state == "preparing_dc" then
            local heading = self:getUnitHeading(unit)
            local pos = unit:getPoint()
            local overWater = self:isPositionOverWater(pos.x, pos.z)
            msg = msg .. string.format("\nHeading: %.0f° | Depth: %dm | %d charge(s) x %dm spacing",
                heading, d.dcDepth, d.dcCount, d.dcSpacing)
            msg = msg .. "\n" .. (overWater and "WATER OK" or "OVER LAND — charges will be discarded")
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

-- ===== DEPTH CHARGES =====

function OrdnanceManager:checkDCFlightParams(unit)
    if not unit then return false, "No aircraft found" end
    local pos = unit:getPoint()
    local altitudeAGL = pos.y - land.getHeight({x = pos.x, y = pos.z})
    local velocity = unit:getVelocity()
    local speed = math.sqrt(velocity.x^2 + velocity.y^2 + velocity.z^2)
    local altOk = altitudeAGL <= self.dcMaxAltitude
    local spdOk = speed <= self.dcMaxSpeed
    local msg = string.format("Alt: %.0fm AGL %s | Speed: %.0f kt %s",
        altitudeAGL, altOk and "OK" or "TOO HIGH",
        speed * 1.943844, spdOk and "OK" or "TOO FAST")
    return altOk and spdOk, msg
end

function OrdnanceManager:setDCDepth(groupName, depth)
    local data = self.groupData[groupName]
    if not data then return end
    data.dcDepth = depth
    self:messageToGroup(groupName, "Depth charge detonation depth: " .. depth .. "m", 5)
end

function OrdnanceManager:setDCCount(groupName, count)
    local data = self.groupData[groupName]
    if not data then return end
    data.dcCount = count
    self:messageToGroup(groupName, "Depth charge count: " .. count, 5)
end

function OrdnanceManager:setDCSpacing(groupName, spacing)
    local data = self.groupData[groupName]
    if not data then return end
    data.dcSpacing = spacing
    self:messageToGroup(groupName, "Depth charge spacing: " .. spacing .. "m", 5)
end

function OrdnanceManager:prepareToDrop(groupName)
    local data = self.groupData[groupName]
    if not data then return end

    if data.state ~= "idle" then
        self:messageToGroup(groupName, "Cancel current operation first!", 5)
        return
    end

    if data.dcInventory <= 0 then
        self:messageToGroup(groupName, "No depth charges remaining! Return to rearm.", 5)
        return
    end

    data.state = "preparing_dc"
    local maxSpeedKt = math.floor(self.dcMaxSpeed * 1.943844)
    self:messageToGroup(groupName, string.format(
        "Preparing depth charge drop.\nDepth: %dm | %d charge(s) x %dm spacing\nAlt < %dm AGL | Speed < %d kt",
        data.dcDepth, data.dcCount, data.dcSpacing, self.dcMaxAltitude, maxSpeedKt), 5)
    self:startPrepareMessages(groupName)
end

function OrdnanceManager:dropCharges(groupName)
    local data = self.groupData[groupName]
    if not data then return end

    if data.state ~= "preparing_dc" then
        self:messageToGroup(groupName, "Use 'Prepare to Drop' first!", 5)
        return
    end

    local unit = self:getGroupUnit(groupName)
    local paramsOk, msg = self:checkDCFlightParams(unit)
    if not paramsOk then
        self:messageToGroup(groupName, "Cannot drop! " .. msg, 5)
        return
    end

    local count = math.min(data.dcCount, data.dcInventory)
    local pos = unit:getPoint()
    local heading = self:getUnitHeading(unit)
    local headingRad = math.rad(heading)
    local dirX = math.cos(headingRad)
    local dirZ = math.sin(headingRad)

    local dropped = 0
    local discarded = 0

    for i = 0, count - 1 do
        self.dcIdCounter = self.dcIdCounter + 1
        local charge = DepthCharge:new(
            groupName .. "-DC-" .. self.dcIdCounter,
            pos.x + dirX * i * data.dcSpacing,
            pos.z + dirZ * i * data.dcSpacing,
            data.dcDepth,
            self.ownerCoalition,
            self.submarines
        )
        if charge then dropped = dropped + 1 else discarded = discarded + 1 end
    end

    data.dcInventory = data.dcInventory - count

    local dropMsg = string.format(
        "Depth charges away! %d dropped | Depth: %dm | Spacing: %dm | Remaining: %d/%d",
        dropped, data.dcDepth, data.dcSpacing, data.dcInventory, self.maxDepthCharges)
    if discarded > 0 then
        dropMsg = dropMsg .. " | " .. discarded .. " discarded (over land)"
    end
    self:messageToGroup(groupName, dropMsg, 8)

    local enemyCoalition = self.ownerCoalition == coalition.side.BLUE and coalition.side.RED or coalition.side.BLUE
    trigger.action.outTextForCoalition(enemyCoalition, "WARNING: Depth charges in the water!", 10, false)
    if ASW_SOUND then
        ASW_SOUND:playForCoalition(enemyCoalition, "warning_torpedo")
    end

    self:stopPrepareMessages(groupName)
    data.state = "idle"
end

-- ===== DETECTION LOOP =====
-- Call this once after creating all managers that share the same buoys table.

function OrdnanceManager:startDetectionLoop()
    local function detect()
        for _, buoy in ipairs(self.buoys) do
            buoy:tickBattery()
            if buoy:canDetect() then
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
