--[[
	Author: @rinqLK, MIT licensed
	
	Desc:	Limits, thresholds and flag labels
--]]

const Config = {
	["Capture"] = {
		["Enabled"] = true,				-- master switch bcuz this kinda slows down running
		["MaxEntries"] = 3000,			-- events kept in the ring
		["MaxRows"] = 200,				-- rows drawn at once
		["RenderInterval"] = 0.1,		-- seconds between repaints
		["MaxDurations"] = 200,			-- handler times we average over
		["MessageSeconds"] = 6,			-- how long a message bar line sticks around
		["Bindables"] = true, 			-- should we pay attention to bindables

		-- proxies every RemoteFunction so the calls can be seen. costs a full
		-- client round trip per call and breaks anything using InvokeClient
		["ProxyRemoteFunctions"] = true,

		-- decided to add signal support since bindableevents suck and its more usefl
		["SignalModule"] = "ReplicatedStorage.Packages.Signal",

		-- keeps the real args of a call around so it can be fired again. off means
		-- rows still log, they just cant be rerun
		["Replay"] = true,

		-- how many calls hold onto their args. every one of these is keeping a
		-- table or buffer alive that would otherwise be collected, so its low
		["MaxReplays"] = 200,

	},

	["Warnings"] = {
		["BurstWindow"] = 1,			-- seconds
		["BurstThreshold"] = 20,		-- calls per player per window before we flag
		["LargePayload"] = 4096,		-- bytes in one call
		["UnreliableLimit"] = 1000,		-- engine drops unreliable payloads over this
		-- had this at 900 for ages, thats what half the docs still say. its 1000
		["UnreliableWarn"] = 0.9,		-- flag once a call passes this fraction of it
		["PreviewArgs"] = 5,			-- args in a row before "+n more"
		["PreviewChars"] = 28,			-- string chars in a row
		["PreviewBytes"] = 8,			-- buffer bytes in a row as hex
	},

	-- built for every call as it comes in, so keep these sane
	["Detail"] = {
		["MaxDepth"] = 4,				-- table nesting shown
		["MaxKeys"] = 40,				-- keys per table
		["MaxBytes"] = 256,				-- buffer bytes hex dumped
		["MaxChars"] = 6000,			-- characters in one dump
	},

	-- only things measurable off the wire
	["Flags"] = {
		["InstanceFromClient"] = "instance from client",
		["Burst"] = "no rate limit",
		["LargePayload"] = "large payload",
		["UnreliableCap"] = "near the 1000 B unreliable limit",
		["BadNumber"] = "NaN or infinite number",
		["HandlerError"] = "handler errored",
		["InvokeClient"] = "server invokes client",
		["ProxyOff"] = "not captured, RemoteFunctions are turned off in settings",
		["Unused"] = "never fired",
	},

	["Directions"] = {
		["ToServer"] = "C->S",
		["ToClient"] = "S->C",
		["ServerLocal"] = "S->S",
		["ClientLocal"] = "C->C",
	},

	-- guesses, buffers are the exception since buffer.len is exact
	["TypeBytes"] = {
		["nil"] = 1,
		["boolean"] = 1,
		["number"] = 8,
		["Vector2"] = 8,
		["Vector3"] = 12,
		["Vector2int16"] = 4,
		["Vector3int16"] = 6,
		["CFrame"] = 48,
		["Color3"] = 12,
		["UDim"] = 8,
		["UDim2"] = 16,
		["Rect"] = 16,
		["BrickColor"] = 2,
		["EnumItem"] = 4,
		["Instance"] = 8,
		["NumberRange"] = 8,
		["Ray"] = 24,
		["Region3"] = 24,
	},
}

return Config
