ShipCommander = {}
ShipCommander.__index = ShipCommander

local ZIG_ZAG_AMPLITUDE = 20     -- degrees either side of target heading
local ZIG_ZAG_PERIOD    = 45     -- seconds per full oscillation
local WAYPOINT_REFRESH  = 5      -- seconds between waypoint pushes
local WAYPOINT_DISTANCE = 50000  -- 50 km lookahead

local function log(message, logCoalition, duration)
    duration = duration or 10
    trigger.action.outTextForCoalition(logCoalition, message, duration, false)
    env.info(message, false)
end

-- Constructor
-- config fields:
--   groupPrefix:       string prefix for ship group names (default "asw_ship")
--   ownerCoalition:    coalition.side.BLUE or RED
--   submarines:        shared detectableObjects table
--   thermalLayerDepth: number (meters)
function ShipCommander:new(config)
    config = config or {}
    local obj = {
        groupPrefix       = config.groupPrefix or "asw_ship",
        ownerCoalition    = config.ownerCoalition or coalition.side.BLUE,
        submarines        = config.submarines or {},
        thermalLayerDepth = config.thermalLayerDepth or 90,
        dcSupply          = config.dcSupply or 50,
        ships             = {},    -- shipData keyed by groupName
        rootMenu          = nil,
    }
    setmetatable(obj, ShipCommander)
    obj:discoverShips()
    return obj
end

-- ===== DISCOVERY =====

function ShipCommander:discoverShips()
    local groups = coalition.getGroups(self.ownerCoalition)
    local found  = 0
    for _, group in ipairs(groups) do
        local gName = group:getName()
        if gName:find(self.groupPrefix, 1, true) then
            local units = group:getUnits()
            if #units ~= 1 then
                log(string.format(
                    "ASW WARNING: Ship group '%s' has %d units — must be exactly 1. Skipped.",
                    gName, #units), self.ownerCoalition, 20)
            else
                self:initShip(gName)
                found = found + 1
            end
        end
    end
    if found == 0 then
        env.info("ShipCommander: no groups found with prefix '" .. self.groupPrefix .. "'", false)
    else
        env.info(string.format("ShipCommander: initialized %d ship(s).", found), false)
    end
end

-- Ship data fields:
--   groupName     string
--   sonar         ShipSonar
--   targetHeading number  (degrees 0-360, player-set compass heading)
--   targetSpeed   number  (knots)
--   dcDepth       number  (meters)
--   dcCount       number  (charges per pattern drop)
--   dcInterval    number  (seconds between pattern charges)
--   dcDropCounter number  (for naming individual charges)
--   aiZigZag      bool
function ShipCommander:initShip(groupName)
    local dcsGroup = Group.getByName(groupName)
    if not dcsGroup or not dcsGroup:isExist() then
        env.info("ShipCommander: group '" .. groupName .. "' not found at init.", false)
        return
    end
    local unit = dcsGroup:getUnit(1)
    if not unit or not unit:isExist() then return end

    local fwd      = unit:getPosition().x          -- forward axis of the unit's local frame
    local hdgDeg   = math.deg(math.atan2(fwd.x, fwd.z)) % 360
    local unitName = unit:getName()

    local data = {
        groupName     = groupName,
        unitName      = unitName,
        sonar         = ShipSonar:new(groupName, self.ownerCoalition, self.thermalLayerDepth, self.submarines),
        targetHeading = hdgDeg,
        targetSpeed   = 10,
        dcDepth       = 50,
        dcCount       = 5,
        dcInterval    = 10,
        dcDropCounter = 0,
        dcSupply      = self.dcSupply,
        aiZigZag      = false,
    }

    self.ships[groupName] = data
    self:buildMenus(groupName)
    self:startWaypointLoop(groupName)

    log(string.format("Ship '%s' online | HDG: %.0f° | Speed: %d kt",
        unitName, hdgDeg, data.targetSpeed), self.ownerCoalition, 10)
end

-- ===== MENUS (COALITION-WIDE) =====

function ShipCommander:buildMenus(groupName)
    local side = self.ownerCoalition
    local data = self.ships[groupName]

    if not self.rootMenu then
        self.rootMenu = MENU_COALITION:New(side, "ASW Ships")
    end

    local shipMenu = MENU_COALITION:New(side, data.unitName, self.rootMenu)

    -- Speed: relative adjustments
    local changeSpeedMenu = MENU_COALITION:New(side, "Change Speed", shipMenu)
    for _, delta in ipairs({-20, -10, -5, -2, -1, 1, 2, 5, 10, 20}) do
        local label = (delta > 0 and "+" or "") .. delta .. " kt"
        MENU_COALITION_COMMAND:New(side, label, changeSpeedMenu, self.changeSpeed, self, groupName, delta)
    end

    -- Speed: absolute presets
    local setSpeedMenu = MENU_COALITION:New(side, "Set Speed", shipMenu)
    for _, entry in ipairs({
        {0,  "Stop (0 kt)"},
        {5,  "Slow (5 kt)"},
        {10, "Cruise (10 kt)"},
        {15, "Fast (15 kt)"},
        {20, "Full (20 kt)"},
        {25, "Full (25 kt)"},
        {30, "Flank (30 kt)"},
    }) do
        MENU_COALITION_COMMAND:New(side, entry[2], setSpeedMenu, self.setSpeed, self, groupName, entry[1])
    end

    -- Heading: relative adjustments
    local changeHdgMenu = MENU_COALITION:New(side, "Change Heading", shipMenu)
    for _, delta in ipairs({-90, -50, -25, -10, -5, 5, 10, 25, 50, 90}) do
        local label = (delta > 0 and "+" or "") .. delta .. "°"
        MENU_COALITION_COMMAND:New(side, label, changeHdgMenu, self.changeHeading, self, groupName, delta)
    end

    -- Heading: absolute compass points
    local setHdgMenu = MENU_COALITION:New(side, "Set Heading", shipMenu)
    for _, entry in ipairs({
        {0, "N  (000°)"}, {45, "NE (045°)"}, {90, "E  (090°)"}, {135, "SE (135°)"},
        {180, "S  (180°)"}, {225, "SW (225°)"}, {270, "W  (270°)"}, {315, "NW (315°)"},
    }) do
        MENU_COALITION_COMMAND:New(side, entry[2], setHdgMenu, self.setHeading, self, groupName, entry[1])
    end

    -- Depth charges
    local dcMenu      = MENU_COALITION:New(side, "Depth Charges", shipMenu)
    local dcDepthMenu    = MENU_COALITION:New(side, "Set DC Depth",    dcMenu)
    local dcCountMenu    = MENU_COALITION:New(side, "Set Pattern Size", dcMenu)
    local dcIntervalMenu = MENU_COALITION:New(side, "Set Pattern Interval", dcMenu)
    MENU_COALITION_COMMAND:New(side, "Drop 1 Charge", dcMenu, self.dropDepthCharges, self, groupName)
    MENU_COALITION_COMMAND:New(side, "Drop Pattern",  dcMenu, self.dropPattern,      self, groupName)
    MENU_COALITION_COMMAND:New(side, "DC Status",     dcMenu, self.reportStatus,     self, groupName)
    for _, d in ipairs({30, 50, 100, 150, 200}) do
        MENU_COALITION_COMMAND:New(side, d .. "m", dcDepthMenu, self.setDCDepth, self, groupName, d)
    end
    for _, n in ipairs({5, 10}) do
        MENU_COALITION_COMMAND:New(side, n .. " charges", dcCountMenu, self.setDCCount, self, groupName, n)
    end
    for _, t in ipairs({10, 20, 30}) do
        MENU_COALITION_COMMAND:New(side, t .. " seconds", dcIntervalMenu, self.setDCInterval, self, groupName, t)
    end

    -- Sonar
    local sonarMenu = MENU_COALITION:New(side, "Sonar", shipMenu)
    MENU_COALITION_COMMAND:New(side, "Activate (Active Mode)",    sonarMenu, self.setSonarMode,      self, groupName, "active")
    MENU_COALITION_COMMAND:New(side, "Deactivate (Passive Mode)", sonarMenu, self.setSonarMode,      self, groupName, "passive")
    MENU_COALITION_COMMAND:New(side, "Sonar Status",              sonarMenu, self.reportSonarStatus, self, groupName)

    -- AI
    local aiMenu = MENU_COALITION:New(side, "AI Behavior", shipMenu)
    MENU_COALITION_COMMAND:New(side, "Toggle Zig-Zag", aiMenu, self.toggleZigZag, self, groupName)
    MENU_COALITION_COMMAND:New(side, "Ship Status",    aiMenu, self.reportStatus,  self, groupName)
end

-- ===== SPEED / HEADING =====

function ShipCommander:changeSpeed(groupName, delta)
    local data = self.ships[groupName]
    if not data then return end
    data.targetSpeed = math.max(0, data.targetSpeed + delta)
    log(string.format("%s speed → %d kt", data.unitName, data.targetSpeed), self.ownerCoalition)
end

function ShipCommander:setSpeed(groupName, kt)
    local data = self.ships[groupName]
    if not data then return end
    data.targetSpeed = math.max(0, kt)
    log(string.format("%s speed → %d kt", data.unitName, data.targetSpeed), self.ownerCoalition)
end

function ShipCommander:changeHeading(groupName, deltaDeg)
    local data = self.ships[groupName]
    if not data then return end
    data.targetHeading = (data.targetHeading + deltaDeg) % 360
    log(string.format("%s heading → %.0f°", data.unitName, data.targetHeading), self.ownerCoalition)
end

function ShipCommander:setHeading(groupName, deg)
    local data = self.ships[groupName]
    if not data then return end
    data.targetHeading = deg % 360
    log(string.format("%s heading → %.0f°", data.unitName, data.targetHeading), self.ownerCoalition)
end

-- ===== WAYPOINT LOOP =====

function ShipCommander:startWaypointLoop(groupName)
    local function refresh()
        local data = self.ships[groupName]
        if not data then return end

        local dcsGroup = Group.getByName(groupName)
        if not dcsGroup or not dcsGroup:isExist() then return end
        local unit = dcsGroup:getUnit(1)
        if not unit or not unit:isExist() then return end

        local pos     = unit:getPoint()
        local speedMs = data.targetSpeed * 0.514444   -- kt → m/s

        -- Apply zig-zag sine wave offset around the player-set heading
        local effectiveHeading = data.targetHeading
        if data.aiZigZag then
            local offset = math.sin(timer.getTime() * 2 * math.pi / ZIG_ZAG_PERIOD) * ZIG_ZAG_AMPLITUDE
            effectiveHeading = (effectiveHeading + offset) % 360
        end

        -- Compute a waypoint far ahead in the desired direction using MOOSE
        local coord       = COORDINATE:New(pos.x, 0, pos.z)
        local targetCoord = coord:Translate(WAYPOINT_DISTANCE, effectiveHeading)

        local wp = {
            type         = "Turning Point",
            action       = "Turning Point",
            x            = targetCoord.x,
            y            = targetCoord.z,   -- route point y = DCS world z
            speed        = speedMs,
            speed_locked = true,
            ETA_locked   = false,
        }

        dcsGroup:getController():setTask({
            id     = "Mission",
            params = { route = { points = { wp } } }
        })

        timer.scheduleFunction(function() refresh() end, nil, timer.getTime() + WAYPOINT_REFRESH)
    end

    timer.scheduleFunction(function() refresh() end, nil, timer.getTime() + 1)
end

-- ===== DEPTH CHARGES =====

function ShipCommander:dropDepthCharges(groupName)
    local data = self.ships[groupName]
    if not data then return end
    local dcsGroup = Group.getByName(groupName)
    if not dcsGroup then return end
    local unit = dcsGroup:getUnit(1)
    if not unit or not unit:isExist() then return end

    self:dropSingleCharge(data, unit)
end

function ShipCommander:dropSingleCharge(data, unit)
    if data.dcSupply <= 0 then
        log(data.unitName .. " | No depth charges remaining!", self.ownerCoalition)
        return false
    end
    local pos = unit:getPoint()
    data.dcDropCounter = data.dcDropCounter + 1
    data.dcSupply      = data.dcSupply - 1
    local name = data.unitName .. "-DC-" .. data.dcDropCounter
    local dc = DepthCharge:new(name, pos.x, pos.z, data.dcDepth, self.ownerCoalition, self.submarines)
    if dc then
        log(string.format("%s dropped %s at depth %dm (%d remaining)",
            data.unitName, name, data.dcDepth, data.dcSupply), self.ownerCoalition)
    end
    return true
end

function ShipCommander:dropPattern(groupName)
    local data = self.ships[groupName]
    if not data then return end

    if data.dcSupply <= 0 then
        log(data.unitName .. " | No depth charges remaining!", self.ownerCoalition)
        return
    end

    local count = math.min(data.dcCount, data.dcSupply)
    log(string.format("%s DC pattern: %d charges, %ds interval, depth %dm (%d remaining after)",
        data.unitName, count, data.dcInterval, data.dcDepth, data.dcSupply - count), self.ownerCoalition)

    local function dropNext(remaining)
        if remaining <= 0 then return end
        local dcsGroup = Group.getByName(groupName)
        if not dcsGroup then return end
        local unit = dcsGroup:getUnit(1)
        if not unit or not unit:isExist() then return end

        local ok = self:dropSingleCharge(data, unit)
        if ok and remaining > 1 then
            timer.scheduleFunction(function()
                dropNext(remaining - 1)
            end, nil, timer.getTime() + data.dcInterval)
        end
    end

    dropNext(count)
end

function ShipCommander:setDCDepth(groupName, depth)
    local data = self.ships[groupName]
    if not data then return end
    data.dcDepth = depth
    log(string.format("%s DC depth set to %dm", data.unitName, depth), self.ownerCoalition)
end

function ShipCommander:setDCCount(groupName, count)
    local data = self.ships[groupName]
    if not data then return end
    data.dcCount = count
    log(string.format("%s DC pattern size set to %d charges", data.unitName, count), self.ownerCoalition)
end

function ShipCommander:setDCInterval(groupName, interval)
    local data = self.ships[groupName]
    if not data then return end
    data.dcInterval = interval
    log(string.format("%s DC pattern interval set to %ds", data.unitName, interval), self.ownerCoalition)
end

-- ===== SONAR =====

function ShipCommander:setSonarMode(groupName, mode)
    local data = self.ships[groupName]
    if not data or not data.sonar then return end
    local msg = data.sonar:setMode(mode)
    log(data.unitName .. " | " .. msg, self.ownerCoalition)
end

function ShipCommander:reportSonarStatus(groupName)
    local data = self.ships[groupName]
    if not data or not data.sonar then return end
    log(data.unitName .. " | " .. data.sonar:getStatusText(), self.ownerCoalition)
end

-- ===== AI =====

function ShipCommander:toggleZigZag(groupName)
    local data = self.ships[groupName]
    if not data then return end
    data.aiZigZag = not data.aiZigZag
    local state = data.aiZigZag and "ENABLED" or "DISABLED"
    log(string.format("%s Zig-Zag %s (±%d° / %ds period)",
        data.unitName, state, ZIG_ZAG_AMPLITUDE, ZIG_ZAG_PERIOD), self.ownerCoalition)
end

-- ===== STATUS =====

function ShipCommander:reportStatus(groupName)
    local data = self.ships[groupName]
    if not data then return end
    local zigStr = data.aiZigZag and "ON" or "OFF"
    local msg = string.format(
        "%s | HDG: %.0f° | Speed: %d kt | Zig-Zag: %s\nDC: %d remaining | depth %dm | pattern %d charges @ %ds interval\n%s",
        data.unitName, data.targetHeading, data.targetSpeed, zigStr,
        data.dcSupply, data.dcDepth, data.dcCount, data.dcInterval,
        data.sonar and data.sonar:getStatusText() or "No sonar")
    log(msg, self.ownerCoalition, 10)
end
