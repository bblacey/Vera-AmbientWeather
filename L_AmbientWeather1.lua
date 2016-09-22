module("L_AmbientWeather1", package.seeall)

local pluginName = "AmbientWeather"
local observerIP = nil

-- UPnP Constants
local UPNP = {
        TEMP = {
                SID  = "urn:upnp-org:serviceId:TemperatureSensor1",
                FILE = "D_TemperatureSensor1.xml"
        },
        HUMID = {
                SID  = "urn:micasaverde-com:serviceId:HumiditySensor1",
                FILE = "D_HumiditySensor1.xml"
        },
        AW = {
                SID  = "urn:blacey-com:serviceId:AW1",
                FILE = "D_AmbientWeather1.xml"
        }
}

-- Ambient Weather Device Map
local devices = {
        inTemp  = { id = nil, sid = UPNP.TEMP.SID , file = UPNP.TEMP.FILE , variable = "CurrentTemperature", description = "Inside Temperature" , readings = {} },
        inHumi  = { id = nil, sid = UPNP.HUMID.SID, file = UPNP.HUMID.FILE, variable = "CurrentLevel"      , description = "Inside Humidity"    , readings = {} },
        outTemp = { id = nil, sid = UPNP.TEMP.SID , file = UPNP.TEMP.FILE , variable = "CurrentTemperature", description = "Outside Temperature", readings = {} },
        outHumi = { id = nil, sid = UPNP.HUMID.SID, file = UPNP.HUMID.FILE, variable = "CurrentLevel"      , description = "Outside Humidity" 	, readings = {} }
}

local LOG = { 
	ERROR = 1, 
	WARN  = 2, 
	DEBUG = 35, 
	INFO  = 50 
}

-- ------------------------------------------------------------------
-- Convenience functions for consistent logging convention throughput AmbientWeather 
-- grep '\(^01\|^02\|^35\|^50\).*AmbientWeather' /var/log/cmh/LuaUPnP.log
-- ------------------------------------------------------------------
function log(text, level)
        luup.log(pluginName .. ": " .. text, (level or LOG.INFO))
end

function log_info(text)   -- Appears as normal text
        log(text, LOG.INFO)     -- grep '^50.*AmbientWeather'
end

function log_warn(text)   -- Appears as yellow text [02]
        log(text, LOG.WARN)     -- grep '^2.*AmbientWeather'
end

function log_error(text)  -- Appears as red text  [01]
        log(text, LOG.ERROR)    -- grep '^1.*AmbientWeather'
end

function log_debug(text)  -- Reported with verbose logging enabled [35]
        log(text, LOG.DEBUG)    -- grep '^35.*AmbientWeather'
end

function altIdForDevice(tag, parent)
        return ( parent .. "-" .. tag )
end

function findChild(parent, altId) -- credit to @guessed
	log_debug("Looking for child for parent " .. parent .. " with alt id " .. altId)
	for num, dev in pairs(luup.devices) do
		log_debug("Checking parent " .. dev.device_num_parent .. " for alt id " .. dev.id)
		if ( dev.device_num_parent == parent and dev.id == altId ) then
			return num
		end
	end

	-- Dump a copy of the Global Module list for debugging purposes.
	log_warn("findChild cannot find child, parent: " .. tostring(parent) .. " alt id: " .. altId)
	for num, dev in pairs(luup.devices) do
		log_warn("Device Number: " .. num ..
			" dev.device_type: " .. tostring(dev.device_type) ..
			" dev.device_num_parent: " .. tostring(dev.device_num_parent) ..
			" dev.id: " .. tostring(dev.id)
			)
	end
end

function setVar(service, name, value, device) -- credit to @akbooker

	device = device or this_device
	local old = luup.variable_get (service, name, device)
	if tostring(value) ~= old then
		log_debug("Setting variable " .. name .. " for service " .. service .. " to " .. tostring(value))
		luup.variable_set(service, name, value, device)
	end
end

function getHTMLValueFor(tag, fromHTMLContent)

	local regex = "name=\"" .. tag .. "\"[^>]*value=\"([^\"]+)"
	local value = fromHTMLContent:match(regex)
	return tonumber(value)
end

function getLiveData(url)

	log_debug("getLiveData(\"" .. url .. "\")")
	local status, html = luup.inet.wget(url, 20)

	if ( status ~= 0 ) then
		log_warn("Error retrieving sensor readings from " .. url .. ", status = " .. status)
		return nil
	end

	return html
end

function getSensorReadings()

	function observerURL(ip) return "http://" .. ip .. "/livedata.htm" end

	log_debug("getSensorReadings()...")

	luup.call_delay("getSensorReadings", 60)

	local liveData = getLiveData(observerURL(observerIP))

	if ( liveData ~= nil ) then
		for key, dev in pairs( devices ) do
			local value = getHTMLValueFor(key, liveData) or 0
			local avg   = movingAverage(dev.readings, value)
			log_debug(key .. " reading = " .. tostring(value) .. " average = " .. tostring(avg))
			log_info("Setting " .. key .. "." .. dev.variable .. " to " .. value)
			setVar( dev.sid, dev.variable, value, dev.id )
			setVar( dev.sid, "Average"   , avg  , dev.id )
		end
	else
		log_warn("No sensor readings returned...")
	end
end

function movingAverage(r, n)
        local function f(a, b, ...) if b then return f(a+b, ...) else return a end end
        if #r == 10 then table.remove(r, 1) end
        r[#r + 1] = n
        return f(unpack(r)) / #r
end

function createChildDevices(parent, devices)

	-- get a pointer to the child devices
        local childDevices = luup.chdev.start( parent )

	-- add child devices
        for key, dev in pairs( devices ) do
                log_info( "Adding child device " .. altIdForDevice(key, parent) )
                log_debug( "luup.chdev.append(" ..parent.. ", childDevices, " ..  altIdForDevice(key, parent) .. ", " ..dev.description.. ", \"\", " ..dev.file.. ", \"\", \"\", true)" )
                luup.chdev.append( parent, childDevices, altIdForDevice(key, parent), dev.description, "", dev.file, "", "", true)
        end

        -- sync child devices
        luup.chdev.sync( parent, childDevices )

        -- add the id for each child device to the lookup map
        for key, dev in pairs( devices ) do
		log_debug("Looking for child device " .. altIdForDevice(key, parent))
                dev.id = findChild( parent, altIdForDevice(key, parent) )
                log_info( "Child " .. altIdForDevice(key, parent) .. " device id = " .. (dev.id or "none") )
        end
end

function init(lul_device)

	log_info( "Loading...  device=" .. lul_device )
	
	-- Add callback(s) to global namespace
	_G.getSensorReadings = getSensorReadings

	-- Create sensor children
	createChildDevices(lul_device, devices)

	-- Set control parameters from UI
	observerIP = luup.variable_get(UPNP.AW.SID, "AmbientObserverIP", lul_device)
	if ( observerIP == nil ) then
		observerIP = "0.0.0.0:0000"
		luup.variable_set(UPNP.AW.SID, "AmbientObserverIP", observerIP, lul_device)
	end

	refreshInterval = luup.variable_get(UPNP.AW.SID, "RefreshInterval", lul_device)
	if ( refreshInterval == nil ) then
		refreshInterval = 300 -- 5 minutes
		luup.variable_set(UPNP.AW.SID, "RefreshInterval", refreshInterval, lul_device)
	end

	numAverageSamples = luup.variable_get(UPNP.AW.SID, "NumAvgSamples", lul_device)
	if ( numAverageSamples == nil ) then
		numAverageSamples = 12 -- 60 minutes
		luup.variable_set(UPNP.AW.SID, "NumAvgSamples", numAverageSamples, lul_device)
	end

	-- Kick-off the sensor reading collection
	luup.call_delay("getSensorReadings", 5)
end

