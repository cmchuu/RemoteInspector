--[[
	Author: @rinqLK, MIT licensed
	
	Desc:	Owns the dock widget and draws the log into it
--]]

-- Services

const RunService = game:GetService("RunService")
const Selection = game:GetService("Selection")
const StudioService = game:GetService("StudioService")

-- Modules

const Config = require(script.Parent.Config)
const Capture = require(script.Parent.Capture)
const Maid = require(script.Parent.MiniMaid)

const CaptureConfig = Config.Capture
const Warnings = Config.Warnings

const ToServer = Config.Directions.ToServer
const DirectionFor = {
	ToServer = Config.Directions.ToServer,
	ToClient = Config.Directions.ToClient,
}

const IsLocalDirection = {
	[Config.Directions.ServerLocal] = true,
	[Config.Directions.ClientLocal] = true,
}

-- what the panel can change. Group is the table in Config it lives under
const SettingSpec = {
	{Head = "Capture"},
	{Group = "Capture", Key = "Enabled", Kind = "bool", Restart = true,
		Label = "Capture on play", Note = "off means nothing is hooked at all"},
	{Group = "Capture", Key = "Bindables", Kind = "bool", Restart = true,
		Label = "Track bindables", Note = "BindableEvent and BindableFunction, they never touch the network"},
	{Group = "Capture", Key = "ProxyRemoteFunctions", Kind = "bool", Restart = true,
		Label = "Capture RemoteFunctions", Note = "round trip per call, causes InvokeClient to error. doesnt work when referenced very early"},
	{Group = "Capture", Key = "Replay", Kind = "bool", Restart = true,
		Label = "Allow rerunning calls", Note = "keeps the real arguments so a call can be fired again, right click a row"},
	{Group = "Capture", Key = "MaxReplays", Kind = "number",
		Label = "Calls kept for rerun", Note = "each one holds onto its arguments, older rows lose the option"},
	{Group = "Capture", Key = "SignalModule", Kind = "text", Restart = true,
		Label = "Signal module path", Note = "blank to skip, only works on class-based signal like GoodSignal/Signal by Stravant/sleitnick"},
	{Group = "Capture", Key = "MaxEntries", Kind = "number",
		Label = "Events kept", Note = "oldest are dropped past this"},
	{Group = "Capture", Key = "MaxRows", Kind = "number",
		Label = "Rows drawn", Note = "higher costs frames on a busy game"},
	{Group = "Capture", Key = "RenderInterval", Kind = "number",
		Label = "Seconds between repaints", Note = "lower is smoother and heavier"},
	{Group = "Capture", Key = "MessageSeconds", Kind = "number",
		Label = "Message bar seconds", Note = "how long a message line stays at the bottom"},

	{Head = "Warnings"},
	{Group = "Warnings", Key = "LargePayload", Kind = "number",
		Label = "Large payload bytes", Note = "one call over this gets flagged"},
	{Group = "Warnings", Key = "BurstThreshold", Kind = "number",
		Label = "Calls per second before flagging", Note = "counted per player, may catch missing ratelimits"},
	{Group = "Warnings", Key = "PreviewChars", Kind = "number",
		Label = "String characters in a row", Note = "cut off past this, the full one is in expanded view"},
	{Group = "Warnings", Key = "PreviewBytes", Kind = "number",
		Label = "Buffer bytes in a row", Note = "shown as hex next to the length"},

	{Head = "Expanded view"},
	{Group = "Detail", Key = "MaxBytes", Kind = "number",
		Label = "Buffer bytes hex dumped", Note = "drop this first if capture costs frames"},
	{Group = "Detail", Key = "MaxChars", Kind = "number",
		Label = "Characters in a dump", Note = "truncated past this"},
	{Group = "Detail", Key = "MaxDepth", Kind = "number",
		Label = "Table nesting shown", Note = "anything deeper shows as { ... }"},
}

-- UI

const UIStorage = script.Parent.UI
const MainTemplate = UIStorage.Main
const TrafficRowTemplate = UIStorage.TrafficRow
const RemoteRowTemplate = UIStorage.RemoteRow
const SettingHeadTemplate = UIStorage:FindFirstChild("SettingHead")

const SettingTemplates = {
	bool = UIStorage:FindFirstChild("SettingToggle"),
	number = UIStorage:FindFirstChild("SettingNumber"),
	text = UIStorage:FindFirstChild("SettingText"),
}
const ByteRowTemplate = UIStorage.ByteRow

const IgnoreKey = "IgnoredRemotes"

-- three copies of this run at once and ids are unique per plugin, not per data
-- model. CreatePluginAction just hands back nil on a clash and blows up AddAction
const Scope = if RunService:IsEdit() then "Edit"  -- three copies, three sets of ids
	elseif RunService:IsServer() then "Server"
	else "Client"
const ChartKey = "ChartExcluded"

const Interface = {
	View = "Traffic",		-- "Traffic" | "Remotes" | "Bytes"
	Filter = "All",			-- "All" | "ToServer" | "ToClient"

	Collapse = true,		-- runs of identical calls stack into one row
	Open = nil,				-- entry the detail panel is showing
	SettingsOpen = false,
	MenuOpen = false,		-- ShowAsync errors if two menus overlap
	WasRunning = false,
	WarnedFull = false,
	MessageUntil = 0,
	LastRender = 0,
	PulseAt = 0,
	PulseSeen = 0,
	PulsePeak = 5,

	Maid = Maid.new(),
}

local Pools = {Traffic = {}, Remotes = {}, Bytes = {}}
local Excluded = {}		-- [path] = true, left out of the share chart only, still logged
local RowTarget = {}		-- [row] = entry in the Traffic pool, stat in the Remotes pool
local RowRepeat = {}		-- [row] = how many calls that row is standing in for

const Studio = settings().Studio
local IconCache = {}

-- same two off the logo that the builder uses. these do not follow the studio
-- theme on purpose, theyre the plugins own
const Accent = Color3.fromRGB(124, 58, 237)
const AccentDim = Color3.fromRGB(62, 40, 96)
const Inbound = Color3.fromRGB(232, 150, 60)

--[[
	StudioColor() returns Color3
	Gets a colour from Studios theme

	@name: StudioStyleGuideColor name
--]]
local function StudioColor(name: string): Color3
	return Studio.Theme:GetColor(Enum.StudioStyleGuideColor[name])
end

--[[
	ThemeOne() returns nil
	Themes one instance from its attributes

	@object: the instance
--]]
local function ThemeOne(object: Instance)
	const Background = object:GetAttribute("ThemeColor")
	if Background then
		object.BackgroundColor3 = StudioColor(Background)
	end

	const Text = object:GetAttribute("ThemeTextColor")
	if Text then
		object.TextColor3 = StudioColor(Text)
	end
end

--[[
	Notify() returns nil
	Shows a message in the message bar

	@text: what to say
--]]
function Interface:Notify(text: string)
	self.Message.Text = text
	self.MessageUntil = os.clock() + CaptureConfig.MessageSeconds
end

--[[
	BuildMenus() returns nil
	Makes the right click and dropdown menus

	@Plugin: the plugin global
--]]
-- every action has to exist before any AddAction touches it. had one created 14
-- lines below where it was used, CreatePluginAction handed back nil, AddAction
-- threw, Start died half way and the button just sat there doing nothing
function Interface:BuildMenus(Plugin: Plugin)
	local function Action(id: string, text: string, tip: string)
		return Plugin:CreatePluginAction(`RemoteInspector_{Scope}_{id}`, text, tip, "", false)
	end

	self.ExpandAction = Action("Expand", "Expand this call", "Open the full argument dump")
	self.RerunAction = Action("Rerun", "Rerun this call", "Fire it again with the same arguments")
	self.IgnoreAction = Action("Ignore", "Toggle ignore", "Stop or resume logging this remote")
	self.SelectAction = Action("Select", "Select in Explorer", "Select the remote instance")
	self.PathAction = Action("Path", "Show full path", "Print the full path to the message bar")
	self.ClearIgnoresAction = Action("ClearIgnores", "Stop ignoring everything", "Empty the ignore list")

	self.TrafficMenu = Plugin:CreatePluginMenu(`RemoteInspector_{Scope}_TrafficMenu`, "Remote")
	self.TrafficMenu:AddAction(self.ExpandAction)
	-- traffic only. a summary row is a remote, not a call, theres no args behind it
	self.TrafficMenu:AddAction(self.RerunAction)
	self.TrafficMenu:AddAction(self.IgnoreAction)
	self.TrafficMenu:AddAction(self.SelectAction)
	self.TrafficMenu:AddAction(self.PathAction)

	self.RemoteMenu = Plugin:CreatePluginMenu(`RemoteInspector_{Scope}_RemoteMenu`, "Remote")
	self.RemoteMenu:AddAction(self.IgnoreAction)
	self.RemoteMenu:AddAction(self.SelectAction)
	self.RemoteMenu:AddAction(self.PathAction)
	self.RemoteMenu:AddAction(self.ClearIgnoresAction)

	self.ViewTrafficAction = Action("ViewTraffic", "Traffic", "Live log of every call")
	self.ViewRemotesAction = Action("ViewRemotes", "Remotes", "Totals and warnings per remote")
	self.ViewBytesAction = Action("ViewBytes", "Byte share", "Share of total bytes per remote")

	self.ViewMenu = Plugin:CreatePluginMenu(`RemoteInspector_{Scope}_ViewMenu`, "View")
	self.ViewMenu:AddAction(self.ViewTrafficAction)
	self.ViewMenu:AddAction(self.ViewRemotesAction)
	self.ViewMenu:AddAction(self.ViewBytesAction)

	self.DirAllAction = Action("DirAll", "All directions", "Show both directions")
	self.DirToServerAction = Action("DirToServer", "Client -> server", "Only inbound calls")
	self.DirToClientAction = Action("DirToClient", "Server -> client", "Only outbound calls")
	self.DirLocalAction = Action("DirLocal", "Signal and bindables", "Only same context events")

	self.DirectionMenu = Plugin:CreatePluginMenu(`RemoteInspector_{Scope}_DirectionMenu`, "Direction")
	self.DirectionMenu:AddAction(self.DirAllAction)
	self.DirectionMenu:AddAction(self.DirToServerAction)
	self.DirectionMenu:AddAction(self.DirToClientAction)
	self.DirectionMenu:AddAction(self.DirLocalAction)

	self.Maid:GiveTask(self.TrafficMenu)
	self.Maid:GiveTask(self.RemoteMenu)
	self.Maid:GiveTask(self.ViewMenu)
	self.Maid:GiveTask(self.DirectionMenu)
end

--[[
	ShowDropdown() returns PluginAction?
	Shows a menu and gives back what was picked

	@menu: the menu
--]]
function Interface:ShowDropdown(menu: PluginMenu)
	if self.MenuOpen then return nil end

	self.MenuOpen = true
	const Chosen = menu:ShowAsync()
	self.MenuOpen = false

	return Chosen
end

--[[
	ShowRowMenu() returns nil
	Shows the right click menu for a row

	@view: which pool
	@target: entry or stat
--]]
function Interface:ShowRowMenu(view: string, target: any)
	const Menu = (view == "Traffic" and self.TrafficMenu) or self.RemoteMenu
	const Chosen = self:ShowDropdown(Menu)

	if not Chosen then return end

	if Chosen == self.ExpandAction then
		self:ShowDetail(target)
	elseif Chosen == self.RerunAction then
		self:Rerun(target)
	elseif Chosen == self.IgnoreAction then
		self:ToggleIgnore(target.Path)
	elseif Chosen == self.SelectAction then
		if target.Remote and target.Remote.Parent then
			Selection:Set({target.Remote})
		else
			self:Notify("That remote no longer exists")
		end
	elseif Chosen == self.PathAction then
		self:Notify(target.Path)
	elseif Chosen == self.ClearIgnoresAction then
		Capture.Ignored = {}
		self.Plugin:SetSetting(IgnoreKey, {})
		self:Notify("Ignore list emptied")
		self:Render(true)
	end
end

--[[
	WireButtons() returns nil
	Hover on every button in one go. AutoButtonColor is off so they do nothing on
	their own now

	@parent: whatever holds them
--]]
function Interface:WireButtons(parent: Instance)
	for _, Object in parent:GetDescendants() do
		const Glow = Object:IsA("TextButton") and Object:FindFirstChild("Glow")
		if not Glow then continue end

		const Base = Object.BackgroundColor3

		self.Maid:GiveTask(Object.MouseEnter:Connect(function()
			Object.BackgroundColor3 = Base:Lerp(Accent, 0.25)
		end))

		self.Maid:GiveTask(Object.MouseLeave:Connect(function()
			Object.BackgroundColor3 = Base
		end))
	end
end

--[[
	RefreshIgnoreButton() returns nil
	Updates the ignore button text
--]]
function Interface:RefreshIgnoreButton()
	if not self.Open then return end

	if Capture:IsIgnored(self.Open.Path) then
		self.Detail.IgnoreButton.Text = "Stop ignoring"
	else
		self.Detail.IgnoreButton.Text = "Ignore this remote"
	end
end

--[[
	RefreshRerunButton() returns nil
	Hides the button for anything that cant be fired again
--]]
function Interface:RefreshRerunButton()
	const Entry = self.Open

	self.RerunButton.Visible = CaptureConfig.Replay
		and Entry ~= nil
		and Entry.ReplayId ~= nil
		and Entry.Source ~= nil
end

--[[
	Rerun() returns nil
	Fires a captured call again. The args live in whichever data model caught it,
	so this only asks. What comes back is an ordinary new row

	@entry: the entry
--]]
function Interface:Rerun(entry)
	const Sent, Message = Capture:RequestReplay(entry)

	self:Notify(Message)

	if Sent then
		self:Render(true)
	end
end

--[[
	ShowDetail() returns nil
	Opens the expanded view for a call

	@entry: the entry
--]]
function Interface:ShowDetail(entry, repeats: number?)
	self.Open = entry
	self.Detail.Title.Text = entry.Path

	local Meta = `{entry.Direction}   {entry.Player}   {entry.Bytes} B   at {entry.Clock}`

	if entry.Duration then
		Meta ..= `   handler {string.format("%.2f", entry.Duration * 1000)}ms`
	end

	if entry.Error then
		Meta ..= `   ERRORED: {entry.Error}`
	end

	if repeats and repeats > 1 then
		Meta ..= `   {repeats} identical in a row, this is the newest`
	end

	self.Detail.Meta.Text = Meta
	self.Detail.Content.Text.Text = entry.Detail
	-- open a second call without this and it keeps the last ones scroll position
	self.Detail.Content.CanvasPosition = Vector2.zero
	self.Detail.Visible = true

	-- self.Detail.Visible = true and nothing else
	-- ^ drew over the rows fine but every click landed on them anyway
	-- leave this or the clicks will go thru
	self.Body.Visible = false

	self:RefreshIgnoreButton()
	self:RefreshRerunButton()
end

function Interface:HideDetail()
	self.Open = nil
	self.Detail.Visible = false
	self.Body.Visible = true
end

--[[
	ToggleIgnore() returns nil
	Ignores or unignores a remote and saves it

	@path: full name
--]]
function Interface:ToggleIgnore(path: string)
	const Name = path:match("[^%.]+$") or path

	if Capture:ToggleIgnore(path) then
		self:Notify(`Ignoring {Name}, its traffic is hidden and no longer logged`)
	else
		self:Notify(`No longer ignoring {Name}`)
	end

	self.Plugin:SetSetting(IgnoreKey, Capture.Ignored)
	self:RefreshIgnoreButton()
	self:Render(true)
end

--[[
	ToggleExclude() returns nil
	Adds or removes a remote from the byte chart

	@path: full name
--]]
function Interface:ToggleExclude(path: string)
	if Excluded[path] then
		Excluded[path] = nil
	else
		Excluded[path] = true
	end

	self.Plugin:SetSetting(ChartKey, Excluded)
	self:Render(true)
end

--[[
	GetRow() returns TextButton
	Gets a row from the pool

	@view: Traffic, Remotes or Bytes
	@index: row number
--]]
function Interface:GetRow(view: string, index: number)
	const Pool = Pools[view]
	local Row = Pool[index]

	if Row then return Row end

	local Template = RemoteRowTemplate

	if view == "Traffic" then
		Template = TrafficRowTemplate
	elseif view == "Bytes" then
		Template = ByteRowTemplate
	end

	-- self.Body:ClearAllChildren() then clone everything fresh each render
	-- looked fine at 20 rows, chugged at 200

	Row = Template:Clone()
	Row.LayoutOrder = index
	Row.Visible = false
	Row.Parent = self.Body

	Pool[index] = Row

	-- Row.Activated:Once() down in the render loop before this
	-- ^ a fresh connection every repaint, 10 a second, they just stacked
	-- here and nowhere else
	if view == "Traffic" then
		self.Maid:GiveTask(Row.Activated:Connect(function()
			self:ShowDetail(RowTarget[Row], RowRepeat[Row])
		end))
	elseif view == "Bytes" then
		-- if i hook include too itll toggle twice
		self.Maid:GiveTask(Row.Activated:Connect(function()
			self:ToggleExclude(RowTarget[Row].Path)
		end))
	else
		self.Maid:GiveTask(Row.Activated:Connect(function()
			self:ToggleIgnore(RowTarget[Row].Path)
		end))
	end

	const Hover = Row:FindFirstChild("Hover")

	if Hover then
		self.Maid:GiveTask(Row.MouseEnter:Connect(function()
			Hover.BackgroundTransparency = 0.92
			Hover.Edge.BackgroundTransparency = 0
		end))

		self.Maid:GiveTask(Row.MouseLeave:Connect(function()
			Hover.BackgroundTransparency = 1
			Hover.Edge.BackgroundTransparency = 1
		end))
	end

	self.Maid:GiveTask(Row.InputBegan:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.MouseButton2 then return end

		-- yields
		task.spawn(function()
			self:ShowRowMenu(view, RowTarget[Row])
		end)
	end))

	return Row
end

--[[
	HideRows() returns nil
--]]
function Interface:HideRows(view: string, from: number)
	const Pool = Pools[view]
	if not Pool then return end

	for Index = from, #Pool do
		Pool[Index].Visible = false
	end
end

--[[
	Matches() returns boolean
--]]
function Interface:Matches(text: string): boolean
	const Query = self.FilterBox.Text
	if Query == "" then return true end

	-- return text:find(Query, 1, true) ~= nil
	-- ^ case sensitive, nobody types remote names with the right caps
	return text:lower():find(Query:lower(), 1, true) ~= nil
end

-- ignored remotes skipped here too, so hiding one also hides what it already logged
--TODO:_silently_stops_at_MaxRows_with_nothing_on_screen_saying_so
--[[
	RenderTraffic() returns nil
	Draws the live log
--]]
function Interface:RenderTraffic()
	const Stripe = StudioColor("TableItem")
	const Base = StudioColor("MainBackground")
	const Dim = StudioColor("DimmedText")
	const Sub = StudioColor("SubText")
	const Text = StudioColor("MainText")
	const Warn = StudioColor("WarningText")
	const Bad = StudioColor("ErrorText")
	const Link = StudioColor("LinkText")

	local Shown = 0
	local LastKey = nil
	local LastRow = nil
	local Runs = 0

	Capture:ForEachNewest(function(entry: Capture.T_Entry)
		if Shown >= CaptureConfig.MaxRows then return false end

		if Capture:IsIgnored(entry.Path) then return end
		--[[if self.Filter == "ToServer" and entry.Direction ~= ToServer then return end
		if self.Filter == "ToClient" and entry.Direction == ToServer then return end]]
		-- was anything thats not toserver for client, which would swallow our newly added bindables yippee
		if self.Filter == "Local" then
			if not IsLocalDirection[entry.Direction] then return end
		elseif self.Filter ~= "All" and entry.Direction ~= DirectionFor[self.Filter] then
			return
		end

		if not (self:Matches(entry.Name) or self:Matches(entry.Player) or self:Matches(entry.Preview)) then
			return
		end

		-- newest first, so a run of identical calls is still next to each other in
		-- here. the row keeps the newest ones time and counts up from there
		if self.Collapse and entry.Key == LastKey then
			Runs += 1
			RowRepeat[LastRow] = Runs
			LastRow.Remote.Text = `{Runs}x {entry.Name}`
			return
		end

		Shown += 1

		local Row = self:GetRow("Traffic", Shown)
		RowTarget[Row] = entry
		RowRepeat[Row] = 1

		LastKey = entry.Key
		LastRow = Row
		Runs = 1

		Row.Visible = true
		Row.BackgroundColor3 = (Shown % 2 == 0) and Stripe or Base

		-- the old row template has no ms column and a Time column too narrow for a
		-- clock, so it tells me which layout im drawing into
		const MsLabel = Row:FindFirstChild("Ms")

		-- signals arent instances so they borrow whichever script icon fits the side
		local IconName = entry.Class

		if IconName == "Signal" then
			IconName = entry.Direction == Config.Directions.ClientLocal and "LocalScript" or "Script"
		end

		if IconCache[IconName] == nil then
			const Found, Result = pcall(StudioService.GetClassIcon, StudioService, IconName)
			IconCache[IconName] = (Found and Result) or false
		end

		const Icon = IconCache[IconName] or nil
		if Icon then
			Row.Icon.Image = Icon.Image
			Row.Icon.ImageRectOffset = Icon.ImageRectOffset
			Row.Icon.ImageRectSize = Icon.ImageRectSize
			Row.Icon.Visible = true
		else
			Row.Icon.Visible = false
		end

		Row.Time.Text = (MsLabel and entry.Clock) or string.format("%7.2f", entry.Time)
		Row.Dir.Text = entry.Direction
		Row.Remote.Text = entry.Name
		Row.Player.Text = entry.Player
		if entry.Class == "UnreliableRemoteEvent" then
			Row.Bytes.Text = string.format("%d %d%%", entry.Bytes,
				entry.Bytes / Warnings.UnreliableLimit * 100)
		else
			Row.Bytes.Text = tostring(entry.Bytes)
		end

		if MsLabel then
			MsLabel.Text = entry.Duration and string.format("%.1f", entry.Duration * 1000) or ""
			MsLabel.TextColor3 = Dim
			Row.Args.Text = entry.Preview
		elseif entry.Duration then
			Row.Args.Text = string.format("[%.1fms] %s", entry.Duration * 1000, entry.Preview)
		else
			Row.Args.Text = entry.Preview
		end

		Row.Time.TextColor3 = Dim
		if entry.Direction == ToServer then
			Row.Dir.TextColor3 = Inbound
			Row.Dir.BackgroundColor3 = Inbound
		elseif IsLocalDirection[entry.Direction] then
			Row.Dir.TextColor3 = Dim
			Row.Dir.BackgroundColor3 = Dim
		else
			Row.Dir.TextColor3 = Link
			Row.Dir.BackgroundColor3 = Link
		end

		Row.Remote.TextColor3 = Text
		Row.Player.TextColor3 = Sub
		if entry.Bytes > Warnings.LargePayload then
			Row.Bytes.TextColor3 = Bad
		elseif entry.Class == "UnreliableRemoteEvent"
			and entry.Bytes > Warnings.UnreliableLimit * Warnings.UnreliableWarn then
			Row.Bytes.TextColor3 = Warn
		else
			Row.Bytes.TextColor3 = Sub
		end
		Row.Args.TextColor3 = entry.Error and Bad or Sub

		return true
	end)

	self:HideRows("Traffic", Shown + 1)

	self.EmptyLabel.Visible = (Shown == 0)

	if Capture.Count == 0 then
		self.EmptyLabel.Text = "No traffic captured yet."
	else
		self.EmptyLabel.Text = "No rows match the filter."
	end
end

--[[
	RenderRemotes() returns nil
	Draws the per remote summary
--]]
function Interface:RenderRemotes()
	const Stripe = StudioColor("TableItem")
	const Base = StudioColor("MainBackground")
	const Dim = StudioColor("DimmedText")
	const Sub = StudioColor("SubText")
	const Text = StudioColor("MainText")
	const Warn = StudioColor("WarningText")

	const List = {}

	for _, Stat in Capture.StatOrder do
		if self:Matches(Stat.Name) then
			table.insert(List, Stat)
		end
	end

	table.sort(List, function(a, b)
		if a.Calls ~= b.Calls then
			return a.Calls > b.Calls
		end

		return a.Name < b.Name
	end)

	local Shown = 0

	for _, Stat in List do
		if Shown >= CaptureConfig.MaxRows then break end

		Shown += 1

		local Row = self:GetRow("Remotes", Shown)
		const Ignored = Capture:IsIgnored(Stat.Path)

		RowTarget[Row] = Stat

		Row.Visible = true
		Row.BackgroundColor3 = (Shown % 2 == 0) and Stripe or Base

		local Average = nil
		if #Stat.Durations > 0 then
			Average = (Stat.DurationTotal / #Stat.Durations) * 1000
		end

		const Labels = {}
		for _, Code in Stat.FlagOrder do
			table.insert(Labels, Capture:GetFlagLabel(Stat, Code))
		end

		Row.Remote.Text = Stat.Name
		Row.Class.Text = Stat.Class
		Row.Calls.Text = tostring(Stat.Calls)
		Row.In.Text = tostring(Stat.ToServer)
		Row.Out.Text = tostring(Stat.ToClient)
		Row.KB.Text = string.format("%.1f", Stat.Bytes / 1024)
		Row.AvgMs.Text = Average and string.format("%.2f", Average) or "-"

		-- flags before never fired. a RemoteFunction always has 0 calls so never
		-- fired was sat on top of the reason it had none
		if Ignored then
			Row.Warnings.Text = "ignored, click to unignore"
		elseif #Labels > 0 then
			Row.Warnings.Text = table.concat(Labels, "  ")
		elseif Stat.Calls == 0 then
			Row.Warnings.Text = Config.Flags.Unused
		else
			Row.Warnings.Text = ""
		end

		Row.Remote.TextColor3 = Ignored and Dim or Text
		Row.Class.TextColor3 = Dim
		Row.Calls.TextColor3 = Ignored and Dim or Sub
		Row.In.TextColor3 = Ignored and Dim or Sub
		Row.Out.TextColor3 = Ignored and Dim or Sub
		Row.KB.TextColor3 = Ignored and Dim or Sub
		Row.AvgMs.TextColor3 = Ignored and Dim or Sub

		if Ignored then
			Row.Warnings.TextColor3 = Dim
		elseif #Labels > 0 or Stat.Calls == 0 then
			Row.Warnings.TextColor3 = Warn
		else
			Row.Warnings.TextColor3 = Dim
		end
	end

	self:HideRows("Remotes", Shown + 1)

	self.EmptyLabel.Visible = (Shown == 0)
	self.EmptyLabel.Text = "No remotes found in this place."
end

--[[
	RenderBytes() returns nil
	Draws the byte share chart
--]]
-- unticking pulls a remote out of the total so the rest recalculate. built this
-- because one replication remote was 90% of everything and the chart was useless
function Interface:RenderBytes()
	const Stripe = StudioColor("TableItem")
	const Base = StudioColor("MainBackground")
	const Dim = StudioColor("DimmedText")
	const Sub = StudioColor("SubText")
	const Text = StudioColor("MainText")

	const List = {}
	local Total = 0

	for _, Stat in Capture.StatOrder do
		if Stat.Bytes > 0 and self:Matches(Stat.Name) then
			table.insert(List, Stat)

			if not Excluded[Stat.Path] then
				Total += Stat.Bytes
			end
		end
	end

	table.sort(List, function(a, b)
		if a.Bytes ~= b.Bytes then
			return a.Bytes > b.Bytes
		end

		return a.Name < b.Name
	end)

	local Shown = 0

	for _, Stat in List do
		if Shown >= CaptureConfig.MaxRows then break end

		Shown += 1

		const Row = self:GetRow("Bytes", Shown)
		const Included = not Excluded[Stat.Path]
		const Share = (Included and Total > 0) and Stat.Bytes / Total or 0

		RowTarget[Row] = Stat

		Row.Visible = true
		Row.BackgroundColor3 = (Shown % 2 == 0) and Stripe or Base

		Row.Include.Text = Included and "[x]" or "[ ]"
		Row.Remote.Text = Stat.Name
		Row.Share.Text = Included and string.format("%.1f%%", Share * 100) or ""
		Row.KB.Text = string.format("%.1f", Stat.Bytes / 1024)
		Row.Calls.Text = tostring(Stat.Calls)
		-- Row.Bar.Fill.Size = UDim2.fromScale(Stat.Bytes / List[1].Bytes, 1)
		-- scaled to the biggest one, looked better but the bars stopped matching the %
		Row.Bar.Fill.Size = UDim2.fromScale(Share, 1)

		-- the ones actually costing you bandwidth should look like it
		if Share > 0.4 then
			Row.Bar.Fill.BackgroundColor3 = StudioColor("ErrorText")
		elseif Share > 0.15 then
			Row.Bar.Fill.BackgroundColor3 = StudioColor("WarningText")
		else
			Row.Bar.Fill.BackgroundColor3 = StudioColor("LinkText")
		end


		Row.Include.TextColor3 = Included and Text or Dim
		Row.Remote.TextColor3 = Included and Text or Dim
		Row.Share.TextColor3 = Sub
		Row.KB.TextColor3 = Included and Sub or Dim
		Row.Calls.TextColor3 = Included and Sub or Dim
	end

	self:HideRows("Bytes", Shown + 1)

	self.EmptyLabel.Visible = (Shown == 0)
	self.EmptyLabel.Text = "Nothing has sent any bytes yet."
end

--[[
	RenderSettings() returns nil
	Draws the settings list. Rebuilt from scratch each time its opened, its a
	handful of rows and it only opens on a click
--]]
function Interface:RenderSettings()
	const Text = StudioColor("MainText")
	const Dim = StudioColor("DimmedText")

	for _, Old in self.SettingsPanel.Content:GetChildren() do
		if Old:IsA("GuiObject") then Old:Destroy() end
	end

	for Index, Entry in SettingSpec do
		if Entry.Head then
			const Head = SettingHeadTemplate:Clone()
			Head.LayoutOrder = Index
			Head.Label.Text = Entry.Head
			Head.Parent = self.SettingsPanel.Content

			continue
		end

		const Template = SettingTemplates[Entry.Kind]
		if not Template then continue end

		const Row = Template:Clone()
		Row.LayoutOrder = Index
		Row.Parent = self.SettingsPanel.Content

		const Value = Config[Entry.Group][Entry.Key]
		const Stale = Entry.Restart and Capture.Running and self.Applied[Entry.Key] ~= Value

		Row.Label.Text = Entry.Label
		Row.Label.TextColor3 = Text

		if Stale then
			Row.Note.Text = "* stop and start play again to apply"
			Row.Note.TextColor3 = StudioColor("WarningText")
		else
			Row.Note.Text = Entry.Note or ""
			Row.Note.TextColor3 = Dim
		end

		self.Maid:GiveTask(Row.MouseEnter:Connect(function()
			Row.Edge.BackgroundTransparency = 0
		end))

		self.Maid:GiveTask(Row.MouseLeave:Connect(function()
			Row.Edge.BackgroundTransparency = 1
		end))

		if Entry.Kind == "bool" then
			Row.Check.Tick.Visible = Value

			self.Maid:GiveTask(Row.Activated:Connect(function()
				Config[Entry.Group][Entry.Key] = not Config[Entry.Group][Entry.Key]
				Capture:SaveSettings(self.Plugin, SettingSpec)
				self:RenderSettings()
			end))

			continue
		end

		Row.Box.Text = tostring(Value)

		self.Maid:GiveTask(Row.Box.FocusLost:Connect(function()
			if Entry.Kind == "text" then
				Config[Entry.Group][Entry.Key] = Row.Box.Text
				Capture:SaveSettings(self.Plugin, SettingSpec)

				return
			end

			const Typed = tonumber(Row.Box.Text)

			if not Typed then
				Row.Box.Text = tostring(Config[Entry.Group][Entry.Key])
				return
			end

			Config[Entry.Group][Entry.Key] = Typed
			Capture:SaveSettings(self.Plugin, SettingSpec)
			self:Notify(`{Entry.Label} set to {Typed}`)
		end))
	end
end

--[[
	ShowSettings() returns nil
	Opens the panel over everything else
--]]
-- the whole panel is rebuilt every time it opens. its 14 rows and it only opens
-- on a click, not worth pooling
function Interface:ShowSettings()
	if not self.SettingsPanel or not SettingTemplates.bool then
		self:Notify("Re-run 0_BuildUI to get the settings panel")
		return
	end

	self:HideDetail()

	self.SettingsOpen = true
	self.SettingsPanel.Visible = true
	self.Body.Visible = false

	self:RenderSettings()
end

--[[
	HideSettings() returns nil
	Back to the list
--]]
function Interface:HideSettings()
	self.SettingsOpen = false
	self.SettingsPanel.Visible = false
	self.Body.Visible = true

	self:Render(true)
end

--[[
	Render() returns nil
	Redraws the panel

	@force: skip the throttle
--]]
function Interface:Render(force: boolean?)
	const Now = os.clock()

	if not force and Now - self.LastRender < CaptureConfig.RenderInterval then
		return
	end

	self.LastRender = Now

	if self.Rate then
		const Elapsed = Now - Capture.StartedAt
		local Recent = 0

		-- walks newest first and stops the second it leaves the window, so its
		-- only ever touching the last seconds worth
		Capture:ForEachNewest(function(entry: Capture.T_Entry)
			if entry.Time < Elapsed - 1 then return false end

			Recent += 1
			return true
		end)

		self.Rate.Text = Capture.Running and `{Recent}/s` or ""
	end

	if self.Pulse then
		if self.PulseAt == 0 then self.PulseAt = Now end

		if Now - self.PulseAt >= 1 then
			self.PulseAt = Now
			const Since = Capture.Count - self.PulseSeen

			self.PulsePeak = math.max(self.PulsePeak * 0.95, Since, 5)
			self:StepPulse(Since, self.PulsePeak)


			self.PulseSeen = Capture.Count
		end
	end

	if self.MessageUntil > 0 and Now > self.MessageUntil then
		self.Message.Text = ""
		self.MessageUntil = 0
	end

	-- Edit never runs so IsRunning is always false here, the test data model
	-- tells us instead
	const Running = Capture.Running

	if Running ~= self.WasRunning then
		self.WasRunning = Running
		self.WarnedFull = false

		if Running then
			for _, Entry in SettingSpec do
				if Entry.Restart then
					self.Applied[Entry.Key] = Config[Entry.Group][Entry.Key]
				end
			end
		end

		if Running and #Capture.StatOrder == 0 then
			self:Notify("No remotes found. Team Test runs in its own process the plugin cant reach, use Play instead")
		elseif Running then
			self:Notify(`Capturing {#Capture.StatOrder} remotes`)
		else
			self:Notify(`Session ended, {Capture.Count} events captured`)
		end
	end

	if Running and not self.WarnedFull and Capture.Count >= CaptureConfig.MaxEntries then
		self.WarnedFull = true
		self:Notify(`Log is full at {CaptureConfig.MaxEntries}, oldest events are being dropped`)
	end

	if not self.Open and not self.SettingsOpen then
		if self.View == "Traffic" then
			self:RenderTraffic()
		elseif self.View == "Remotes" then
			self:RenderRemotes()
		else
			self:RenderBytes()
		end
	end

	if not CaptureConfig.Enabled then
		self.Status.Text = "Capture is off in settings"
	elseif Running then
		const Elapsed = math.max(Now - Capture.StartedAt, 0.001) -- no /0 :)

		-- numbers in accent, words left dim. reads at a glance without the whole
		-- line shouting
		self.Status.Text = string.format(
			"<font color=\"#E8963C\">%d</font> events . <font color=\"#E8963C\">%.1f</font> KB"
				.. " . <font color=\"#E8963C\">%.1f</font>/s . <font color=\"#E8963C\">%d</font> remotes",
			Capture.Count,
			Capture.TotalBytes / 1024,
			Capture.Count / Elapsed,
			#Capture.StatOrder
		)
	elseif Capture.Count > 0 then
		self.Status.Text = string.format(
			"Session ended - <font color=\"#E8963C\">%d</font> events, <font color=\"#E8963C\">%.1f</font> KB",
			Capture.Count,
			Capture.TotalBytes / 1024
		)
	else
		self.Status.Text = "Press Play to start capturing"
	end
end

--[[
	StepPulse() returns nil
	Shuffles the activity bars along one place and drops the newest on the end

	@count: events since the last step
	@peak: the busiest step were scaling against
--]]
function Interface:StepPulse(count: number, peak: number)
	-- by name, not GetChildren. the UICorner in there is not a bar and sorting
	-- on it gave me tonumber("rner")
	const Bars = {}

	for Index = 1, 29 do
		const Bar = self.Pulse:FindFirstChild(`Bar{Index}`)
		if not Bar then return end

		Bars[Index] = Bar
	end

	for Index = 1, #Bars - 1 do
		Bars[Index].Size = Bars[Index + 1].Size
		Bars[Index].BackgroundColor3 = Bars[Index + 1].BackgroundColor3
	end

	const Last = Bars[#Bars]
	const Height = math.clamp(count / peak, 0, 1)

	Last.Size = UDim2.new(0, 3, 0, 2 + math.floor(Height * 12))
	Last.BackgroundColor3 = count > 0 and Accent or AccentDim
end

--[[
	ApplyTheme() returns nil
--]]
function Interface:ApplyTheme()
	ThemeOne(self.UI)

	for _, Object in self.UI:GetDescendants() do
		ThemeOne(Object)
	end
end

--[[
	ToggleRecording() returns nil
	Pauses or resumes the log
--]]
--[[
	ToggleGrouping() returns nil
	Switches between stacking identical calls and showing every one
--]]
function Interface:ToggleGrouping()
	self.Collapse = not self.Collapse
	self.TopBar.GroupButton.Text = self.Collapse and "Grouped" or "All calls"
	self:Render(true)
end

function Interface:ToggleRecording()
	Capture.Recording = not Capture.Recording

	self.TopBar.RecordButton.Text = Capture.Recording and "Recording" or "Paused"

	if Capture.Recording then
		self:Notify("Recording")
	else
		self:Notify("Paused, remotes stay hooked so nothing is missed when you resume")
	end
end

--[[
	SetFilter() returns nil
	Sets the direction filter

	@filter: All, ToServer or ToClient
--]]
function Interface:SetFilter(filter: string)
	self.Filter = filter

	if filter == "ToServer" then
		self.TopBar.DirectionButton.Text = "Client -> server"
	elseif filter == "ToClient" then
		self.TopBar.DirectionButton.Text = "Server -> client"
	elseif filter == "Local" then
		self.TopBar.DirectionButton.Text = "Signal and bindables"
	else
		self.TopBar.DirectionButton.Text = "All directions"
	end

	self:Render(true)
end

--[[
	ShowDirectionMenu() returns nil
	Opens the direction dropdown
--]]
function Interface:ShowDirectionMenu()
	const Chosen = self:ShowDropdown(self.DirectionMenu)
	if not Chosen then return end

	if Chosen == self.DirToServerAction then
		self:SetFilter("ToServer")
	elseif Chosen == self.DirToClientAction then
		self:SetFilter("ToClient")
	elseif Chosen == self.DirLocalAction then
		self:SetFilter("Local")
	elseif Chosen == self.DirAllAction then
		self:SetFilter("All")
	end
end

--[[
	SetView() returns nil
	Switches view

	@view: Traffic, Remotes or Bytes
--]]
function Interface:SetView(view: string)
	self:HideDetail()

	self.View = view

	self.TrafficHeader.Visible = (view == "Traffic")
	self.RemoteHeader.Visible = (view == "Remotes")
	self.BytesHeader.Visible = (view == "Bytes")

	if view == "Remotes" then
		self.TopBar.ViewButton.Text = "Remotes"
	elseif view == "Bytes" then
		self.TopBar.ViewButton.Text = "Byte share"
	else
		self.TopBar.ViewButton.Text = "Traffic"
	end

	for Name in Pools do
		if Name ~= view then
			self:HideRows(Name, 1)
		end
	end

	self:Render(true)
end

--[[
	ShowViewMenu() returns nil
	Opens the view dropdown
--]]
function Interface:ShowViewMenu()
	const Chosen = self:ShowDropdown(self.ViewMenu)
	if not Chosen then return end

	if Chosen == self.ViewTrafficAction then
		self:SetView("Traffic")
	elseif Chosen == self.ViewRemotesAction then
		self:SetView("Remotes")
	elseif Chosen == self.ViewBytesAction then
		self:SetView("Bytes")
	end
end

--[[
	Start() returns nil
	Sets the plugin up

	@Plugin: the plugin global
--]]
function Interface:Start(Plugin: Plugin)
	self.Plugin = Plugin

	-- what the session is actually running on, so the panel can flag when
	-- youve changed something that wont take effect until the next one
	self.Applied = {}

	for _, Entry in SettingSpec do
		if Entry.Restart then
			self.Applied[Entry.Key] = Config[Entry.Group][Entry.Key]
		end
	end

	Capture.Ignored = Plugin:GetSetting(IgnoreKey) or {}
	Excluded = Plugin:GetSetting(ChartKey) or {}

	self.Toolbar = Plugin:CreateToolbar(Scope == "Edit" and "Remote Inspector" or `Remote Inspector ({Scope})`)
	self.Button = self.Toolbar:CreateButton(
		`RemoteInspector_{Scope}`,
		"Inspect remote traffic during playtests",
		"rbxassetid://129262754615111",
		"Remote Inspector"
	)

	-- lets just start adding async to the end of every function why dont we
	self.Widget = Plugin:CreateDockWidgetPluginGuiAsync(
		`RemoteInspector_{Scope}`,
		DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Bottom, false, false, 820, 320, 420, 180)
	)

	self.Widget.Title = "Remote Traffic"
	self.Widget.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	self.UI = MainTemplate:Clone()
	self.UI.Parent = self.Widget

	self.TopBar = self.UI.TopBar
	self.FilterBox = self.TopBar.FilterBox
	self.Status = self.TopBar.Status
	self.Status.RichText = true
	self.TrafficHeader = self.UI.TrafficHeader
	self.RemoteHeader = self.UI.RemoteHeader
	self.BytesHeader = self.UI.BytesHeader
	self.Body = self.UI.Body
	self.EmptyLabel = self.UI.EmptyLabel
	self.Detail = self.UI.Detail
	self.SettingsPanel = self.UI:FindFirstChild("Settings")
	self.Message = self.UI.MessageBar.Text
	self.Pulse = self.UI.MessageBar:FindFirstChild("Pulse")
	self.Rate = self.UI.MessageBar:FindFirstChild("Rate")
	self.RerunButton = self.Detail.RerunButton

	self:BuildMenus(Plugin)
	self.Maid:GiveTask(self.UI)

	self:ApplyTheme()
	self:WireButtons(self.UI)

	local IgnoredCount = 0
	for _ in Capture.Ignored do
		IgnoredCount += 1
	end

	if IgnoredCount > 0 then
		self:Notify(`{IgnoredCount} remotes still ignored from last time, right click a row to change that`)
	end

	self.Maid:GiveTask(self.TopBar.RecordButton.Activated:Connect(function()
		self:ToggleRecording()
	end))

	self.Maid:GiveTask(self.TopBar.GroupButton.Activated:Connect(function()
		self:ToggleGrouping()
	end))

	self.Maid:GiveTask(self.TopBar.ClearButton.Activated:Connect(function()
		const Cleared = Capture.Count

		Capture:Clear()
		self.WarnedFull = false
		self:HideDetail()
		self:Notify(`Cleared {Cleared} events, ignore list kept`)
		self:Render(true)
	end))

	self.Maid:GiveTask(self.TopBar.DirectionButton.Activated:Connect(function()
		task.spawn(function()
			self:ShowDirectionMenu()
		end)
	end))

	self.Maid:GiveTask(self.TopBar.ViewButton.Activated:Connect(function()
		task.spawn(function()
			self:ShowViewMenu()
		end)
	end))

	const SettingsButton = self.TopBar:FindFirstChild("SettingsButton")

	if SettingsButton and self.SettingsPanel then
		self.Maid:GiveTask(SettingsButton.Activated:Connect(function()
			if self.SettingsOpen then
				self:HideSettings()
			else
				self:ShowSettings()
			end
		end))

		self.Maid:GiveTask(self.SettingsPanel.CloseButton.Activated:Connect(function()
			self:HideSettings()
		end))
	elseif SettingsButton then
		self.Maid:GiveTask(SettingsButton.Activated:Connect(function()
			self:Notify("Re-run 0_BuildUI to get the settings panel")
		end))
	end

	self.Maid:GiveTask(self.Detail.CloseButton.Activated:Connect(function()
		self:HideDetail()
		self:Render(true)
	end))

	self.Maid:GiveTask(self.Detail.SelectButton.Activated:Connect(function()
		if self.Open.Remote.Parent then
			Selection:Set({self.Open.Remote})
		else
			self:Notify("That remote no longer exists")
		end
	end))

	self.Maid:GiveTask(self.Detail.IgnoreButton.Activated:Connect(function()
		if self.Open then
			self:ToggleIgnore(self.Open.Path)
		end
	end))

	self.Maid:GiveTask(self.RerunButton.Activated:Connect(function()
		if self.Open then
			self:Rerun(self.Open)
		end
	end))

	self.Maid:GiveTask(self.FilterBox:GetPropertyChangedSignal("Text"):Connect(function()
		self:Render(true)
	end))

	self.Maid:GiveTask(self.Button.Click:Connect(function()
		self.Widget.Enabled = not self.Widget.Enabled
	end))

	self.Maid:GiveTask(self.Widget:GetPropertyChangedSignal("Enabled"):Connect(function()
		self.Button:SetActive(self.Widget.Enabled)

		if self.Widget.Enabled then
			self:Render(true)
		end
	end))

	self.Maid:GiveTask(Studio.ThemeChanged:Connect(function()
		self:ApplyTheme()
		self:Render(true)
	end))

	self.Maid:GiveTask(RunService.Heartbeat:Connect(function()
		if self.Widget.Enabled then
			self:Render(false)
		end
	end))
end

function Interface:Stop()
	self.Maid:DoCleaning()

	-- Bytes was missing from this for ages after that view went in, so those rows
	-- leaked every time the plugin reloaded
	Pools = {Traffic = {}, Remotes = {}, Bytes = {}}
	RowTarget = {}
	RowRepeat = {}
end

return Interface
