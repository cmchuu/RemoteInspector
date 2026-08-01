--[[
	Author: @rinqLK, MIT licensed
	
	Desc:	Hooks every remote during a playtest and keeps the log
--]]

-- Services

const RunService = game:GetService("RunService")
const ReplicatedStorage = game:GetService("ReplicatedStorage")
const Players = game:GetService("Players")

-- Modules

const Config = require(script.Parent.Config)
const Maid = require(script.Parent.MiniMaid)
const Link = require(script.Parent.Link)

const CaptureConfig = Config.Capture
const Warnings = Config.Warnings
const Detail = Config.Detail
const Flags = Config.Flags
const TypeBytes = Config.TypeBytes

const ToServer = Config.Directions.ToServer
const ToClient = Config.Directions.ToClient
const ToServerLocal = Config.Directions.ServerLocal
const ToClientLocal = Config.Directions.ClientLocal

-- bindables never cross a boundary, so the direction is just whichever side we
-- happen to be on
const ToLocal = RunService:IsServer() and ToServerLocal or ToClientLocal

-- Maid lives as long as the plugin, SessionMaid gets wiped on every stop. one
-- maid for both meant stopping killed the Heartbeat watching for the next Play

const Capture = {
	Recording = true,
	Running = false,

	Entries = {},		-- ring buffer, Head is the newest
	Count = 0,
	Head = 0,

	Stats = {},			-- [remote] = T_Stat
	StatOrder = {},		-- keeps the summary from reshuffling every frame

	Ignored = {},
	Mirror = false,		-- true where this data model also draws a window		-- [path] = true
	Draws = false,		-- true where this data model has a window to draw into at all

	TotalBytes = 0,
	StartedAt = 0,

	Maid = Maid.new(),
	SessionMaid = Maid.new(),
}

local Attached = {}			-- [remote] = true
local StatsByPath = {}		-- [path] = T_Stat, edit side keys by path because the instance isnt here
local Relay = nil			-- the RemoteFunction every RemoteFunction proxy bounces through

-- the args never go over the Link, they wouldnt survive JSON. they stay in the
-- data model that caught them and edit asks for one back by id
local Replays = {}			-- [id] = T_Replay
local ReplayOrder = {}		-- ids oldest first, so the bounded drop is cheap
local ReplayCounter = 0
local ReplayBus = nil		-- RemoteEvent, the only way a replay can cross sides


export type T_Entry = {
	Time: number,
	Direction: string,
	Remote: Instance,
	Name: string,
	Path: string,
	Class: string,
	Player: string,
	Bytes: number,
	Clock: string,
	Preview: string,
	Detail: string,
	Key: string,

	Duration: number?,
	Error: string?,

	-- nil where the call cant be fired again, signals mostly
	ReplayId: string?,
	Source: string?,		-- "Server" | "Client", whoever still holds the args
}

export type T_Replay = {
	Args: {any},
	Path: string,
	Class: string,
	Direction: string,
	Player: string?,
}

export type T_Stat = {
	Remote: Instance,
	Name: string,
	Path: string,
	Class: string,

	Calls: number,
	Bytes: number,
	ToServer: number,
	ToClient: number,

	Recent: {[string]: {number}},

	Durations: {number},
	DurationTotal: number,

	Flags: {[string]: any},
	FlagOrder: {string},
}

--[[
	SizeOf() returns number
	Works out roughly how many bytes a value is

	@value: the value
	@seen: tables already done
	@depth: how deep we are
--]]
local function SizeOf(value: any, seen: {[any]: boolean}, depth: number): number
	-- guesswork, roblox wont tell me the real size of anything
	const Kind = typeof(value)
	const Fixed = TypeBytes[Kind]

	if Fixed then return Fixed end
	-- exact, but roblox compresses buffers before sending so the real wire size
	-- is lower. no idea how much lower
	if Kind == "buffer" then return buffer.len(value) end
	if Kind == "string" then return #value + 2 end

	if Kind ~= "table" then return 8 end
	if depth > 8 or seen[value] then return 4 end

	seen[value] = true
	local Total = 2

	for Key, Item in value do
		Total += SizeOf(Key, seen, depth + 1) + SizeOf(Item, seen, depth + 1) + 1
	end

	return Total
end

--[[
	Measure() returns number
	Adds up the size of every arg

	@args: packed args
--]]
local function Measure(args: {any}): number
	const Seen = {}
	local Total = 0

	for Index = 1, args.n do
		Total += SizeOf(args[Index], Seen, 0)
	end

	return Total
end

--[[
	Brief() returns string
	Shortens one value so it fits in a row

	@value: the value
	@depth: how deep we are
--]]
local function Brief(value: any, depth: number): string
	const Kind = typeof(value)

	if Kind == "buffer" then
		const Length = buffer.len(value)

		-- hex at the top level only, nested ones just get a length
		if depth > 0 then return `buffer({Length}B)` end

		const Shown = math.min(Length, Warnings.PreviewBytes)
		const Parts = {}

		for Index = 0, Shown - 1 do
			table.insert(Parts, string.format("%02x", buffer.readu8(value, Index)))
		end

		if Length > Shown then
			table.insert(Parts, "...")
		end

		return `buffer({Length}B) {table.concat(Parts, " ")}`
	elseif Kind == "string" then
		local Text = (value:gsub("[\r\n\t]", " "))
		if #Text > Warnings.PreviewChars then
			Text = Text:sub(1, Warnings.PreviewChars) .. "..."
		end

		return `"{Text}"`
	elseif Kind == "Instance" then
		return `{value.ClassName}:{value.Name}`
	elseif Kind == "table" then
		if depth > 1 then return "{...}" end

		const Parts = {}
		local Count = 0

		for Key, Item in value do
			Count += 1
			if Count <= 3 then
				table.insert(Parts, `{Key}={Brief(Item, depth + 1)}`)
			end
		end

		if Count > 3 then table.insert(Parts, "...") end
		return "{" .. table.concat(Parts, ", ") .. "}"
	end

	return tostring(value)
end

--[[
	PreviewArgs() returns string
	Turns the arg list into one line

	@args: packed args
--]]
local function PreviewArgs(args: {any}): string
	if args.n == 0 then return "()" end

	const Parts = {}
	const Shown = math.min(args.n, Warnings.PreviewArgs)

	for Index = 1, Shown do
		table.insert(Parts, Brief(args[Index], 0))
	end

	if args.n > Shown then
		table.insert(Parts, `+{args.n - Shown} more`)
	end

	return table.concat(Parts, ", ")
end

--[[
	HexDump() returns nil
	Writes a buffer out as hex

	@value: the buffer
	@lines: lines to add to
	@indent: leading whitespace
--]]
local function HexDump(value: buffer, lines: {string}, indent: string)
	const Length = buffer.len(value)
	const Shown = math.min(Length, Detail.MaxBytes)

	for Offset = 0, Shown - 1, 16 do
		const Hex = {}
		const Ascii = {}

		for Index = Offset, math.min(Offset + 15, Shown - 1) do
			const Byte = buffer.readu8(value, Index)
			table.insert(Hex, string.format("%02x", Byte))
			table.insert(Ascii, (Byte >= 32 and Byte < 127) and string.char(Byte) or ".")
		end

		table.insert(lines, string.format(
			"%s%08x  %-47s  %s",
			indent, Offset, table.concat(Hex, " "), table.concat(Ascii)
			))
	end

	if Length > Shown then
		table.insert(lines, `{indent}... {Length - Shown} more bytes`)
	end
end

--[[
	Leaf() returns string
	Turns one value into a string

	@value: the value
--]]
local function Leaf(value: any): string
	const Kind = typeof(value)

	if Kind == "string" then
		return `"{value}"`
	elseif Kind == "Instance" then
		return `{value.ClassName} {value:GetFullName()}`
	end

	return tostring(value)
end

--[[
	Dump() returns nil
	Writes a value out over multiple lines

	@value: the value
	@indent: leading whitespace
	@lines: lines to add to
	@depth: how deep we are
--]]
local function Dump(value: any, indent: string, lines: {string}, depth: number)
	const Kind = typeof(value)

	if Kind == "buffer" then
		table.insert(lines, `{indent}buffer({buffer.len(value)}B)`)
		HexDump(value, lines, indent .. "  ")
	elseif Kind == "table" then
		if depth > Detail.MaxDepth then
			table.insert(lines, indent .. "{ ... }")
			return
		end

		table.insert(lines, indent .. "{")

		local Count = 0

		for Key, Item in value do
			Count += 1

			if Count > Detail.MaxKeys then
				table.insert(lines, `{indent}  ... more keys`)
				break
			end

			const Head = `{indent}  [{Leaf(Key)}] =`
			const ItemKind = typeof(Item)

			if ItemKind == "table" or ItemKind == "buffer" then
				table.insert(lines, Head)
				Dump(Item, indent .. "    ", lines, depth + 1)
			else
				table.insert(lines, `{Head} {Leaf(Item)}`)
			end
		end

		table.insert(lines, indent .. "}")
	else
		table.insert(lines, indent .. Leaf(value))
	end
end

-- eager, the args are long gone by the time i click a row
-- TODO:_never_actually_profiled_the_caps_in_config.Detail
--[[
	BuildDetail() returns string
	Builds the text for the expanded view

	@args: packed args
--]]
local function BuildDetail(args: {any}): string
	-- every call. yes every call
	if args.n == 0 then return "(no arguments)" end

	const Lines = {}

	for Index = 1, args.n do
		table.insert(Lines, `#{Index}  {typeof(args[Index])}`)
		Dump(args[Index], "    ", Lines, 0)

		if Index < args.n then
			table.insert(Lines, "")
		end
	end

	local Text = table.concat(Lines, "\n")

	if #Text > Detail.MaxChars then
		Text = Text:sub(1, Detail.MaxChars) .. "\n\n... truncated, raise Config.Detail.MaxChars"
	end

	return Text
end

--[[
	Flag() returns nil
	Adds a warning to a remote

	@stat: the stat table
	@code: key from Config.Flags
	@detail: extra text, optional
--]]
local function Flag(stat: T_Stat, code: string, detail: string?)
	if stat.Flags[code] then return end

	stat.Flags[code] = detail or true
	table.insert(stat.FlagOrder, code)
end

--[[
	ScanValue() returns nil
	Checks a value for anything worth warning about

	@stat: the stat table
	@direction: ToServer or ToClient
	@value: the value
	@seen: tables already done
	@depth: how deep we are
--]]
local function ScanValue(stat: T_Stat, direction: string, value: any, seen: {[any]: boolean}, depth: number)
	-- buffers fall through, so anything packed into one is invisible to every
	-- warning below. instances cant go in a buffer so those still come through
	const Kind = typeof(value)

	if Kind == "Instance" then
		if direction == ToServer then
			Flag(stat, "InstanceFromClient", value.ClassName)
		end
	elseif Kind == "number" then
		if value ~= value or value == math.huge or value == -math.huge then
			Flag(stat, "BadNumber")
		end
	elseif Kind == "table" and depth <= 6 and not seen[value] then
		seen[value] = true

		for Key, Item in value do
			ScanValue(stat, direction, Key, seen, depth + 1)
			ScanValue(stat, direction, Item, seen, depth + 1)
		end
	end
end

--TODO:_this_rebuilds_the_whole_list_every_single_call_make_it_a_ring
--[[
	CheckBurst() returns nil
	Checks if a player is spamming a remote

	@stat: the stat table
	@playerName: who fired it
	@now: os.clock
--]]
local function CheckBurst(stat: T_Stat, playerName: string, now: number)
	const List = stat.Recent[playerName] or {}
	table.insert(List, now)

	const Cutoff = now - Warnings.BurstWindow
	const Kept = {}

	for _, Stamp in List do
		if Stamp >= Cutoff then
			table.insert(Kept, Stamp)
		end
	end

	stat.Recent[playerName] = Kept

	-- if #List > Warnings.BurstThreshold then
	-- ^ no pruning, one burst at the start left it flagged for the whole session
	if #Kept > Warnings.BurstThreshold then
		Flag(stat, "Burst", `{#Kept}/s from {playerName}`)
	end
end

--[[
	ResolvePath() returns Instance?
	Walks a full name back to an instance

	@path: full name from a payload
--]]
local function ResolvePath(path: string): Instance?
	local Current: any = game

	for Segment in path:gmatch("[^%.]+") do
		Current = Current:FindFirstChild(Segment)
		if not Current then return nil end
	end

	return Current
end

--[[
	GetFlagLabel() returns string
	Gets the text shown for a flag

	@stat: the stat table
	@code: key from Config.Flags
--]]
function Capture:GetFlagLabel(stat: T_Stat, code: string): string
	const Label = Flags[code] or code
	const Value = stat.Flags[code]

	if typeof(Value) == "string" then
		return `{Label} ({Value})`
	end

	return Label
end

--[[
	IsIgnored() returns boolean
	Checks if a remote is ignored

	@path: full name
--]]
function Capture:IsIgnored(path: string): boolean
	return self.Ignored[path] == true
end

--[[
	ToggleIgnore() returns boolean
	Ignores or unignores a remote

	@path: full name
--]]
function Capture:ToggleIgnore(path: string): boolean
	if self.Ignored[path] then
		self.Ignored[path] = nil
		return false
	end

	self.Ignored[path] = true
	return true
end

--[[
	Push() returns nil
--]]
function Capture:Push(entry: T_Entry)
	-- was table.insert plus remove(1) once. fine until a replication loop, thats
	-- 3000 elements shifting every frame

	self.Head = (self.Head % CaptureConfig.MaxEntries) + 1
	self.Entries[self.Head] = entry

	if self.Count < CaptureConfig.MaxEntries then
		self.Count += 1
	end
end

--[[
	ForEachNewest() returns nil
	Loops the log newest first, return false to stop

	@callback: runs per entry
--]]
function Capture:ForEachNewest(callback: (T_Entry) -> any)
	for Offset = 0, self.Count - 1 do
		-- negative but it works
		const Index = ((self.Head - 1 - Offset) % CaptureConfig.MaxEntries) + 1

		if callback(self.Entries[Index]) == false then
			return
		end
	end
end

--[[
	Clear() returns nil
--]]
function Capture:Clear()
	self.Entries = {}
	self.Count = 0
	self.Head = 0

	self.Stats = {}
	self.StatOrder = {}
	self.TotalBytes = 0

	StatsByPath = {}
end

--[[
	GetStat() returns T_Stat
	Gets the stats for a remote

	@remote: the remote
--]]
function Capture:GetStat(remote: Instance): T_Stat
	local Stat = self.Stats[remote]
	if Stat then return Stat end

	Stat = {
		Remote = remote,
		Name = remote.Name,
		Path = remote:GetFullName(),
		Class = remote.ClassName,

		Calls = 0,
		Bytes = 0,
		ToServer = 0,
		ToClient = 0,

		Recent = {},

		Durations = {},
		DurationTotal = 0,

		Flags = {},
		FlagOrder = {},
	}

	self.Stats[remote] = Stat
	table.insert(self.StatOrder, Stat)
	-- StatOrder just keeps iteration deterministic. the summary sort has a name
	-- tiebreak now so this probably isnt needed, leaving it

	return Stat
end

--[[
	Clock() returns string
	Wall clock in the shape the output window prints, so a row lines up against
	whatever the game logged next to it
--]]
local function Clock(): string
	return DateTime.now():FormatLocalTime("HH:mm:ss.SSS", "en-us")
end

--[[
	Identify() returns string, string
	Name and path with our proxy suffix taken back off, so rows read the name the
	game actually uses and the ignore list keys on it too

	@object: the remote
--]]
-- name FIRST then path. wrote Path = Identify(x) once and spent a while
-- wondering why every proxied path was just a name. yes im stupid
local function Identify(object: Instance): (string, string)
	local Name = object.Name
	local Path = object:GetFullName()

	if Name:sub(-3) == "_ri" then
		Name = Name:sub(1, -4)
		Path = Path:sub(1, -4)
	end

	return Name, Path
end

--[[
	LoadSettings() returns nil
	Pulls saved settings back over Config. Every data model calls this, the two
	that never draw a window still need to know what to capture

	@Plugin: the plugin global
--]]
-- these win over whatever is written in Config.lua. a stale saved value sitting
-- on top of a changed default cost me an hour once
function Capture:LoadSettings(Plugin: Plugin)
	const Saved = Plugin:GetSetting("Settings")
	if typeof(Saved) ~= "table" then return end

	for Group, Values in Saved do
		if typeof(Config[Group]) == "table" and typeof(Values) == "table" then
			for Key, Value in Values do
				if Config[Group][Key] ~= nil then
					Config[Group][Key] = Value
				end
			end
		end
	end
end

--[[
	SaveSettings() returns nil
	Writes the settings the panel can change back out

	@Plugin: the plugin global
	@spec: the list the panel is built from
--]]
function Capture:SaveSettings(Plugin: Plugin, spec: {any})
	const Saved = {}

	for _, Entry in spec do
		if Entry.Group then
			Saved[Entry.Group] = Saved[Entry.Group] or {}
			Saved[Entry.Group][Entry.Key] = Config[Entry.Group][Entry.Key]
		end
	end

	Plugin:SetSetting("Settings", Saved)
end

--[[
	ResetReplays() returns nil
	Drops everything being held for replay
--]]
local function ResetReplays()
	Replays = {}
	ReplayOrder = {}
	ReplayCounter = 0
end

--[[
	CanReplay() returns boolean
	Whether a class can be fired again at all

	@class: the class name
--]]
-- signals arent instances, theres nothing to fire again. the creation site is
-- enough to group them in the log and not enough to find one later
local function CanReplay(class: string): boolean
	return class == "RemoteEvent"
		or class == "UnreliableRemoteEvent"
		or class == "RemoteFunction"
		or class == "BindableEvent"
		or class == "BindableFunction"
end

--[[
	RememberReplay() returns string?
	Keeps the real args of one call so it can be fired again. These stay in this
	data model, only the id goes over the Link

	@remote: the remote
	@direction: ToServer or ToClient
	@player: who fired it, nil on server to client
	@args: packed args
	@path: the name stripped path, which is where the proxy sits for a proxied one
--]]
-- bounded. each one holds whatever the call carried, tables and buffers
-- included, so an unbounded store is just a leak
function Capture:RememberReplay(remote: Instance, direction: string, player: Player?, args: {any}, path: string): string?
	if not CaptureConfig.Replay then return nil end

	const Class = remote.ClassName
	if not CanReplay(Class) then return nil end

	ReplayCounter += 1

	-- side in the id so a server id and a client id can never collide on the
	-- edit window, which is looking at both at once
	const Id = `{Link.Side}:{ReplayCounter}`

	Replays[Id] = {
		Args = args,
		Path = path,
		Class = Class,
		Direction = direction,
		Player = player and player.Name or nil,
	}

	table.insert(ReplayOrder, Id)

	while #ReplayOrder > CaptureConfig.MaxReplays do
		Replays[table.remove(ReplayOrder, 1)] = nil
	end

	return Id
end

--[[
	Record() returns nil
	Logs one call

	@remote: the remote
	@direction: ToServer or ToClient
	@player: nil on server to client
	@args: packed args
	@extra: Duration and Error, optional
--]]
function Capture:Record(remote: Instance, direction: string, player: Player?, args: {any}, extra: {any}?)
	if not self.Recording then return end

	const Name, Path = Identify(remote)
	if self.Ignored[Path] then return end

	const Bytes = Measure(args)
	const Flags = {}
	const Seen = {}

	-- reusing ScanValue with a throwaway stat, cba rewriting it for one caller
	const Fake = {Flags = Flags, FlagOrder = {}}

	for Index = 1, args.n do
		ScanValue(Fake, direction, args[Index], Seen, 0)
	end

	if Bytes > Warnings.LargePayload then
		Flags.LargePayload = `{Bytes} B`
	end

	if remote.ClassName == "UnreliableRemoteEvent" and Bytes > Warnings.UnreliableLimit * Warnings.UnreliableWarn then
		Flags.UnreliableCap = `{Bytes} B`
	end

	if extra and extra.Error then
		Flags.HandlerError = tostring(extra.Error)
	end

	-- flattened here becuase it has to survive JSON on the way over. no
	-- instances, no buffers, the hex is already a string by this point
	const Payload = {
		Kind = "call",
		Path = Path,
		Name = Name,
		Class = remote.ClassName,
		Player = player and player.Name or "-",
		Direction = direction,
		Bytes = Bytes,
		Clock = Clock(),
		Preview = PreviewArgs(args),
		Detail = BuildDetail(args),
		Duration = extra and extra.Duration or nil,
		Error = extra and extra.Error and tostring(extra.Error) or nil,
		Flags = Flags,

		-- just the id. the args themselves stay here
		ReplayId = self:RememberReplay(remote, direction, player, args, Path),
	}

	Link:Send(Payload)

	if self.Mirror then
		self:Ingest(Payload)
	end
end

--[[
	Register() returns nil
	Tells Edit a remote exists without logging a call, so it lists in the summary
	before its ever fired

	@object: the remote
	@flags: anything to flag it with straight away
--]]
-- this exists because GetStat on the test side builds a stat in a store that
-- nothing ever draws. anything that never fired just didnt appear for ages
function Capture:Register(object: Instance, flags: {[string]: any}?)
	const Name, Path = Identify(object)

	const Payload = {
		Kind = "stat",
		Path = Path,
		Name = Name,
		Class = object.ClassName,
		Flags = flags or {},
	}

	Link:Send(Payload)

	if self.Mirror then
		self:Ingest(Payload)
	end
end

--[[
	Ingest() returns nil
	One payload off the Link, or one of our own when this data model also draws

	@payload: plain table
--]]
function Capture:Ingest(payload)
	-- anything thats not a call or a stat stops here, everything below assumes
	-- theres a path
	if payload.Kind == "ready" then return end

	-- a request, not a log line. it carries a Path so it would fall straight
	-- through into building a stat for it if this wasnt here
	if payload.Kind == "replay" then return end

	if not payload.Path then return end

	if payload.Kind == "session" then
		if payload.State == "start" then
			-- both test data models send one of these. only the first clears or
			-- the second wipes whatever the first already registered
			if not self.Running then
				self:Clear()
				self.StartedAt = os.clock()
			end

			self.Running = true
		else
			self.Running = false
		end

		return
	end

	local Stat = StatsByPath[payload.Path]

	if not Stat then
		Stat = {
			-- nil for anything in ServerStorage, it never replicates to us. the
			-- row just cant select in Explorer, everything else still works
			-- proxied ones sit at path_ri, everything else is just the path
			Remote = ResolvePath(`{payload.Path}_ri`) or ResolvePath(payload.Path),
			Name = payload.Name,
			Path = payload.Path,
			Class = payload.Class,

			Calls = 0,
			Bytes = 0,
			ToServer = 0,
			ToClient = 0,

			Recent = {},
			Durations = {},
			DurationTotal = 0,

			Flags = {},
			FlagOrder = {},
		}

		StatsByPath[payload.Path] = Stat
		table.insert(self.StatOrder, Stat)
	end

	for Code, Value in payload.Flags do
		Flag(Stat, Code, typeof(Value) == "string" and Value or nil)
	end

	if payload.Kind == "stat" then return end

	-- below the stat on purpose. up top meant an ignored remote had no row left
	-- to click, so no way to unignore it
	if self.Ignored[payload.Path] then return end

	const Now = os.clock()

	Stat.Calls += 1
	Stat.Bytes += payload.Bytes
	self.TotalBytes += payload.Bytes

	if payload.Direction == ToServer then
		Stat.ToServer += 1
		CheckBurst(Stat, payload.Player, Now)
	elseif payload.Direction == ToClient then
		Stat.ToClient += 1
	else
		CheckBurst(Stat, payload.Player, Now)
	end

	if payload.Duration then
		table.insert(Stat.Durations, payload.Duration)
		Stat.DurationTotal += payload.Duration

		if #Stat.Durations > CaptureConfig.MaxDurations then
			Stat.DurationTotal -= table.remove(Stat.Durations, 1)
		end
	end

	self:Push({
		Time = Now - self.StartedAt,
		Direction = payload.Direction,
		Remote = Stat.Remote,
		Name = payload.Name,
		Path = payload.Path,
		Class = payload.Class,
		Player = payload.Player,
		Bytes = payload.Bytes,
		Clock = payload.Clock,
		Preview = payload.Preview,
		Detail = payload.Detail,
		Key = `{payload.Path}|{payload.Direction}|{payload.Player}|{payload.Bytes}|{payload.Preview}`,

		Duration = payload.Duration,
		Error = payload.Error,

		-- Side is put on by Link:Send, so this is whichever data model caught the
		-- call and is still sat on its args
		ReplayId = payload.ReplayId,
		Source = payload.Side,
	})
end

local function IsRemote(object: Instance): boolean
	-- ignore our own stuff. the signal feed is a bindable so otherwise the pipe
	-- shows up instead of the signal
	if object.Name:sub(1, 15) == "RemoteInspector" then return false end

	if object:IsA("RemoteEvent") or object:IsA("RemoteFunction") or object:IsA("UnreliableRemoteEvent") then
		return true
	end

	-- bindables dont touch the network, byte counts still mean something
	-- becuase Roblox copeies tables through them, not just bandwidth
	if CaptureConfig.Bindables then
		return object:IsA("BindableEvent") or object:IsA("BindableFunction")
	end

	return false
end

--[[
	AttachEvent() returns nil
	Connects to both ends of a RemoteEvent

	@remote: the remote
--]]
function Capture:AttachEvent(remote: Instance)
	const ServerOk, ServerConnection = pcall(function()
		return remote.OnServerEvent:Connect(function(player, ...)
			self:Record(remote, ToServer, player, table.pack(...))
		end)
	end)

	if ServerOk then
		self.SessionMaid:GiveTask(ServerConnection)
	end

	-- throws in Run mode. ok
	const ClientOk, ClientConnection = pcall(function()
		return remote.OnClientEvent:Connect(function(...)
			self:Record(remote, ToClient, nil, table.pack(...))
		end)
	end)

	if ClientOk then
		self.SessionMaid:GiveTask(ClientConnection)
	end

	self:Register(remote)
end

--[[
	EnsureRelay() returns RemoteFunction
	One relay for every RemoteFunction proxy. Made on the server, answered on the
	client, only exists once something actually needs it
--]]
function Capture:EnsureRelay()
	if Relay then return Relay end

	Relay = Instance.new("RemoteFunction")
	Relay.Name = "RemoteInspectorRelay"
	Relay.Archivable = false

	Attached[Relay] = true
	Relay.Parent = ReplicatedStorage

	self.SessionMaid:GiveTask(Relay)
	self.SessionMaid:GiveTask(function()
		Relay = nil
	end)

	return Relay
end

--[[
	AnswerRelay() returns nil
	The client half. The server cant call its own OnServerInvoke so the proxy
	asks the player who made the call to do it, which also means the real handler
	still sees the right player
--]]
function Capture:AnswerRelay()
	task.spawn(function()
		const Bounce = ReplicatedStorage:WaitForChild("RemoteInspectorRelay", 30)
		if not Bounce then return end

		Attached[Bounce] = true
		Relay = Bounce

		Bounce.OnClientInvoke = function(path: string, ...)
			const Original = ResolvePath(path)
			if not Original then return end

			return Original:InvokeServer(...)
		end
	end)
end

--[[
	AttachRemoteFunction() returns nil
	Proxy in front, and the forward goes out to the calling client and back in
	because nothing on the server can trigger its own OnServerInvoke

	@remote: the remote function
--]]
-- only catches call sites that index the path each time. anything holding a
-- reference from startup goes to the original and we never see it
function Capture:AttachRemoteFunction(remote: Instance)
	if remote.Name:sub(-3) == "_ri" then
		self:Register(remote)
		return
	end

	const Bounce = self:EnsureRelay()
	const Parent = remote.Parent
	const RealName = remote.Name

	remote.Name = RealName .. "_ri"

	-- C to S only. S to C means fighting the game for OnClientInvoke and losing
	-- that race hangs the server thread forever. becuase callbacks are write only
	-- theres no way to check whos there first
	const Proxy = Instance.new("RemoteFunction")
	Proxy.Name = RealName

	Attached[Proxy] = true
	Proxy.Parent = Parent

	const Path = remote:GetFullName()

	Proxy.OnServerInvoke = function(player, ...)
		const Args = table.pack(...)
		const Started = os.clock()
		const Result = table.pack(pcall(Bounce.InvokeClient, Bounce, player, Path, ...))
		const Elapsed = os.clock() - Started

		if Result[1] then
			self:Record(remote, ToServer, player, Args, {Duration = Elapsed})
			return table.unpack(Result, 2, Result.n)
		end

		self:Record(remote, ToServer, player, Args, {Duration = Elapsed, Error = Result[2]})
		warn("[ri] forward failed for", Path, Result[2])
		error(Result[2], 0)
	end


	self:Register(remote)

	self.SessionMaid:GiveTask(function()
		const Success, Error = pcall(function()
			Proxy:Destroy()
			remote.Name = RealName
		end)

		if not Success then
			warn("[ri] proxy restore:", Error)
		end
	end)
end

--[[
	AttachBindableFunction() returns nil
	Renames the original and puts a proxy in its place. Only works because Invoke
	is callable from the same context, RemoteFunctions have no equivalent

	@remote: the bindable function
--]]
function Capture:AttachBindableFunction(remote: Instance)
	-- already ours from a session that didnt clean up properly
	if remote.Name:sub(-3) == "_ri" then
		self:Register(remote)
		return
	end

	const Parent = remote.Parent
	const RealName = remote.Name

	remote.Name = RealName .. "_ri"

	const Proxy = Instance.new("BindableFunction")
	Proxy.Name = RealName

	-- in Attached before its parented or DescendantAdded proxies the proxy
	Attached[Proxy] = true
	Proxy.Parent = Parent

	Proxy.OnInvoke = function(...)
		const Args = table.pack(...)
		const Started = os.clock()
		const Result = table.pack(pcall(remote.Invoke, remote, ...))
		const Elapsed = os.clock() - Started

		if Result[1] then
			self:Record(remote, ToLocal, nil, Args, {Duration = Elapsed})
			return table.unpack(Result, 2, Result.n)
		end

		self:Record(remote, ToLocal, nil, Args, {Duration = Elapsed, Error = Result[2]})
		error(Result[2], 0)
	end

	self:Register(remote)

	self.SessionMaid:GiveTask(function()
		const Success, Error = pcall(function()
			Proxy:Destroy()
			remote.Name = RealName
		end)

		if not Success then
			warn("[ri] proxy restore:", Error)
		end
	end)
end

--[[
	AttachBindable() returns nil
	Connects to a BindableEvent
	
	@remote: the bindable thing
--]]
function Capture:AttachBindable(remote: Instance)
	self.SessionMaid:GiveTask(remote.Event:Connect(function(...)
		self:Record(remote, ToLocal, nil, table.pack(...))
	end))

	self:Register(remote)
end

--[[
	RecordSignal() returns nil
	One signal fire, Signals arent instances so there is no path
	the creation site is the closest thing we can get to a sort of
	identity
	
	@object: the signal
	@args: packed args
--]]
function Capture:RecordSignal(where: string, args: {[any]: any})
	if not self.Recording then return end

	const Path = `Signal {where}`
	if self.Ignored[Path] then return end

	const Bytes = Measure(args)
	const Flags = {}
	const Seen = {}
	const Fake = {Flags = Flags, FlagOrder = {}}

	for Index = 1, args.n do
		ScanValue(Fake, ToLocal, args[Index], Seen, 0)
	end

	if Bytes > Warnings.LargePayload then
		Flags.LargePayload = `{Bytes} B`
	end

	const Payload = {
		Kind = "call",
		Path = Path,
		Name = where:match("[^%.]+$") or where,
		Class = "Signal",
		Player = "-",
		Direction = ToLocal,
		Bytes = Bytes,
		Clock = Clock(),
		Preview = PreviewArgs(args),
		Detail = BuildDetail(args),
		Flags = Flags,
	}

	Link:Send(Payload)

	if self.Mirror then
		self:Ingest(Payload)
	end
end

-- i hate that i have to do this but i cant think of a simpler way right now.
-- sorry to any future readers
const SignalAgent = [==[
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Feed = ReplicatedStorage:WaitForChild("%s", 10)
if not Feed then 
	warn("[ri] signal agent couldnt find its feed")
	return
end

local Node = game
for Segment in ("%s"):gmatch("[^%%.]+") do
	Node = Node:FindFirstChild(Segment)
	if not Node then return end
end

local Facade = require(Node)
if type(Facade) ~= "table" or type(Facade.new) ~= "function" then return end

local Class = getmetatable(Facade.new())
if type(Class) ~= "table" then return end

for _, Method in {"Fire", "FireDeferred"} do
	local Real = rawget(Class, Method)
	if type(Real) ~= "function" then continue end
	
	rawset(Class, Method, function(object, ...)
		local Source, Line
		
		for Level = 2, 8 do
			local S, L = debug.info(Level, "sl")
			if not S then break end
			
			if not S:find("RemoteInspector") then
				Source, Line = S, L
				break
			end
		end
		
		if Source then
			Feed:Fire(Source .. ":" .. Line, select("#", ...), ...)
		end
			
		return Real(object, ...)
	end)
end
]==]

--[[
	AttachSignals() returns nil
	Swaps Fire on the signal class itself, all signals share the table
	so it catches ones that were made before it too. boshhhhhhh
--]]
function Capture:AttachSignals()
	const Path = CaptureConfig.SignalModule
	if Path == "" then return end

	-- both datamodels run this and the serves instance replicates, without
	-- the suffix the client agent might listen to the servers feed. pls dont
	const FeedName = RunService:IsServer() and "RemoteInspectorSignalsServer" or "RemoteInspectorSignalsClient"

	const Feed = Instance.new("BindableEvent")
	Feed.Name = FeedName
	Feed.Archivable = false

	Attached[Feed] = true
	Feed.Parent = ReplicatedStorage

	self.SessionMaid:GiveTask(Feed)
	self.SessionMaid:GiveTask(Feed.Event:Connect(function(where, count, ...)
		const Args = table.pack(...)
		Args.n = count

		self:RecordSignal(where, Args)
	end))

	const Agent = Instance.new("Script")
	Agent.Name = "RemoteInspectorSignalAgent"
	Agent.Archivable = false
	Agent.RunContext = RunService:IsServer() and Enum.RunContext.Server or Enum.RunContext.Client
	Agent.Source = SignalAgent:format(FeedName, Path)
	Agent.Parent = ReplicatedStorage

	self.SessionMaid:GiveTask(Agent)
end

--[[
	EnsureReplayBus() returns nil
	Server half of replay. Only the server can send a call out to a client, so the
	client asks through here
--]]
function Capture:EnsureReplayBus()
	const Bus = Instance.new("RemoteEvent")
	Bus.Name = "RemoteInspectorReplayBus"
	Bus.Archivable = false

	Attached[Bus] = true
	Bus.Parent = ReplicatedStorage

	ReplayBus = Bus

	self.SessionMaid:GiveTask(Bus)
	self.SessionMaid:GiveTask(function()
		ReplayBus = nil
	end)

	self.SessionMaid:GiveTask(Bus.OnServerEvent:Connect(function(player, kind, path, ...)
		if kind ~= "toclient" then return end

		const Target = ResolvePath(path)
		if not Target then return end

		-- FireClient, not FireAllClients. a rerun goes back to whoever asked for
		-- it and nobody else
		if Target:IsA("RemoteEvent") or Target:IsA("UnreliableRemoteEvent") then
			Target:FireClient(player, ...)
		end
	end))
end

--[[
	AnswerReplayBus() returns nil
	Client half. Nothing on the server can start a call heading to the server, so
	a replay of one goes back out to the client that made it and it fires again
--]]
function Capture:AnswerReplayBus()
	task.spawn(function()
		const Bus = ReplicatedStorage:WaitForChild("RemoteInspectorReplayBus", 30)
		if not Bus then return end

		Attached[Bus] = true
		ReplayBus = Bus

		self.SessionMaid:GiveTask(function()
			ReplayBus = nil
		end)

		self.SessionMaid:GiveTask(Bus.OnClientEvent:Connect(function(kind, path, ...)
			const Target = ResolvePath(path)
			if not Target then return end

			if kind == "toserver" then
				if Target:IsA("RemoteEvent") or Target:IsA("UnreliableRemoteEvent") then
					Target:FireServer(...)
				end
			elseif kind == "invoke" then
				if not Target:IsA("RemoteFunction") then return end

				-- the proxy, not the real one, so the rerun logs the same way the
				-- first call did instead of going straight past us
				const Args = table.pack(...)

				task.spawn(function()
					-- yields a full round trip and the answer is thrown away, were
					-- running it to watch it
					const Success, Error = pcall(Target.InvokeServer, Target, table.unpack(Args, 1, Args.n))

					if not Success then
						warn("[ri] replay invoke:", path, Error)
					end
				end)
			end
		end))
	end)
end

--[[
	SendReplay() returns nil
	Hands a replay to the side that can actually send it

	@kind: "toserver", "toclient" or "invoke"
	@record: the stored replay
--]]
function Capture:SendReplay(kind: string, record: T_Replay)
	if not ReplayBus then
		warn("[ri] replay: no bus, either the session ended or replay is off")
		return
	end

	const Args = record.Args

	if RunService:IsServer() then
		-- goes back out to the player who made the original call, so the handler
		-- still sees the right person on the other end
		const Player = record.Player and Players:FindFirstChild(record.Player)

		if not Player then
			warn("[ri] replay:", record.Player or "?", "is not in the game any more")
			return
		end

		ReplayBus:FireClient(Player, kind, record.Path, table.unpack(Args, 1, Args.n))
	else
		ReplayBus:FireServer(kind, record.Path, table.unpack(Args, 1, Args.n))
	end
end

--[[
	Replay() returns nil
	Fires one stored call again. Runs on whichever data model caught it, thats the
	only one still holding the args

	@payload: a replay request, off the Link or one we made ourselves
--]]
function Capture:Replay(payload)
	const Stored = Replays[payload.ReplayId]

	-- the store is bounded, so a row far enough back has lost its args
	if not Stored then
		warn("[ri] replay: nothing stored for", payload.Path, "any more")
		return
	end

	const Args = Stored.Args
	const Class = Stored.Class

	-- bindables never left this data model, so they just go again from here
	if Class == "BindableEvent" or Class == "BindableFunction" then
		-- the proxy holds the real name, so this lands on ours and gets logged
		const Target = ResolvePath(Stored.Path)

		if not Target then
			warn("[ri] replay:", Stored.Path, "is gone")
			return
		end

		task.spawn(function()
			const Success, Error = pcall(function()
				if Class == "BindableEvent" then
					Target:Fire(table.unpack(Args, 1, Args.n))
				else
					Target:Invoke(table.unpack(Args, 1, Args.n))
				end
			end)

			if not Success then
				warn("[ri] replay:", Stored.Path, Error)
			end
		end)

		return
	end

	-- everything else has to cross the wire the same way it did the first time
	if Class == "RemoteFunction" then
		self:SendReplay("invoke", Stored)
	elseif Stored.Direction == ToServer then
		self:SendReplay("toserver", Stored)
	else
		self:SendReplay("toclient", Stored)
	end
end

--[[
	RequestReplay() returns boolean, string
	Asks for a call to be fired again. Called from the window, which is usually
	not the data model holding the args, so mostly this just posts the id

	@entry: the entry the row is showing
--]]
function Capture:RequestReplay(entry: T_Entry?): (boolean, string)
	if not CaptureConfig.Replay then
		return false, "Rerunning calls is turned off in settings"
	end

	if not entry then
		return false, "Nothing selected"
	end

	if not entry.ReplayId or not entry.Source then
		return false, `{entry.Name} cant be rerun, its arguments werent kept`
	end

	if not self.Running then
		return false, "The session has ended, press Play and catch it again"
	end

	const Payload = {
		Kind = "replay",
		Target = entry.Source,
		ReplayId = entry.ReplayId,
		Path = entry.Path,
	}

	-- the client window sees its own calls too, so sometimes the args are here
	if Link.Side == entry.Source then
		self:Replay(Payload)
	else
		Link:Send(Payload)
	end

	return true, `Rerunning {entry.Name}, watch for the new row`
end

--[[
	HandlePayload() returns nil
	One payload off the Link. Every data model wires this now, the server included,
	because it draws nothing but still has to hear replay requests

	@payload: plain table
--]]
function Capture:HandlePayload(payload)
	if payload.Kind == "replay" then
		-- both test data models get every batch, only one owns these args
		if payload.Target == Link.Side then
			self:Replay(payload)
		end

		return
	end

	if self.Draws then
		self:Ingest(payload)
	end
end

--[[
	Attach() returns nil
	Hooks a remote

	@object: the remote
--]]
function Capture:Attach(object: Instance)
	if Attached[object] then return end
	Attached[object] = true

	if object:IsA("BindableEvent") then
		self:AttachBindable(object)
	elseif object:IsA("BindableFunction") then
		-- only the server proxies. the rename and the proxy both replicate, so
		-- when the client did it too i got PlayEmote_ri_ri and a proxy wrapping
		-- a proxy. saw exactly that
		if RunService:IsServer() then
			self:AttachBindableFunction(object)
		else
			self:Register(object)
		end
	elseif object:IsA("RemoteFunction") then
		-- the server decides whether it gets proxied, so the client just lists it
		-- and doesnt flag anything, had two labels disagreeing with each other
		if not RunService:IsServer() then
			self:Register(object)
		elseif CaptureConfig.ProxyRemoteFunctions then
			self:AttachRemoteFunction(object)
		else
			self:Register(object, {ProxyOff = true})
		end
	else
		self:AttachEvent(object)
	end
end

--TODO:_turn_the_bottom_right_strip_into_a_proper_profiler_at_some_point
--[[
	StartSession() returns nil
	Hooks every remote in the place
--]]
function Capture:StartSession()

	if not CaptureConfig.Enabled then return end

	self:Clear()
	ResetReplays()

	self.Running = true
	self.StartedAt = os.clock()

	Attached = {}

	if CaptureConfig.ProxyRemoteFunctions then
		if RunService:IsServer() then
			-- has to exist before the client can go looking for it
			self:EnsureRelay()
		else
			self:AnswerRelay()
		end
	end

	-- same shape as the relay above and for the same reason
	if CaptureConfig.Replay then
		if RunService:IsServer() then
			self:EnsureReplayBus()
		else
			self:AnswerReplayBus()
		end
	end

	-- self:AttachSignals()
	const SignalOk, SignalErr = pcall(self.AttachSignals, self)

	if not SignalOk then
		warn(`[ri] signals:`, SignalErr)
	end

	-- both test data models send one of these and for a while both cleared, so
	-- whichever registered first got wiped by the other half a second later
	Link:Send({Kind = "session", State = "start"})

	for _, Object in game:GetDescendants() do
		if IsRemote(Object) then
			const Success, Error = pcall(self.Attach, self, Object)

			if not Success then
				warn("[ri] attach failed on", Object:GetFullName(), Error)
			end
		end
	end

	-- pcall each one. a single remote that wont proxy used to take the whole
	-- session loop with it and i got nothing at all with no clue why
	self.SessionMaid:GiveTask(game.DescendantAdded:Connect(function(object)
		if IsRemote(object) then
			pcall(self.Attach, self, object)
		end
	end))
end

--[[
	StopSession() returns nil
	Unhooks everything and puts the callbacks back
--]]
function Capture:StopSession()
	self.Running = false
	self.SessionMaid:DoCleaning()

	Link:Send({Kind = "session", State = "stop"})

	-- the only thing here holding onto what the game was passing around
	ResetReplays()

	Attached = {}
end

--[[
	Start() returns nil
	Starts watching for play mode
--]]
function Capture:Start()

	-- heartbeat runs in edit mode too
	local WasRunning = false

	self.Maid:GiveTask(RunService.Heartbeat:Connect(function()
		const Running = RunService:IsRunning()

		if Running ~= WasRunning then
			WasRunning = Running

			if Running then
				self:StartSession()
			else
				self:StopSession()
			end
		end

	end))
end

function Capture:Stop()
	self:StopSession()
	self.Maid:DoCleaning()
end

return Capture
