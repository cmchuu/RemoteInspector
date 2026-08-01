--[[
	Author: @rinqLK, MIT licensed
	
	Desc:	Talks across the data model boundary. Edit owns the UI, the two test
			data models do the capturing and post their events to it.

			the road here, for whoever reads this next:
			- 	cant hook FireServer, instance methods are locked behind a
			  	metatable and luau cant touch it
			- 	fine, listen at the receiving end instead. worked
			- 	RemoteFunctions have one callback slot so read it, keep it, put
			  	ours in, call theirs from inside ours
			- 	except callbacks are WRITE ONLY. cant read one, so cant chain
			  	onto one. dead end
			- 	so proxy it. rename the real one, drop a fake in its place
			- 	except nothing on the server can call its own OnServerInvoke so
			  	the proxy catches the call adn then has nothing to fowrard to
			- 	so bounce it out to a client and back in. this actaully works and
			  	also adds a full round trip to every call
			- 	somewhere in there noticed OnServerEvent had never fired once
			  	because the plugin was in the client data model the whole time
			- 	started writing an agent script to inject into ServerScriptService
			- 	THEN brooke henlo frens server pointed me at
			  	PluginConnectionService, which exists for exactly this.
			  	i would have gone insane cuz i had no idea this was a thing
			- 	turns out the plugin was already running server side the whole
				time. it just had no way to talk to the half holding the window
			- 	deleted the agent
			 
			it gets worse. i have been at this for ages. i have just realised
			that i was testing under the very specific working case for the
			remotefunction logging. i was getting the remotefunction at the
			point of calling it, ReplicatedStorage.TestFunction:InvokeServer()
			i had then gone into a game where it was referenced at the top of
			a script that ran before the plugin ran. i dont know how i didnt
			realised this, i was so focused on it working in this test place
			that i thought i really had done it. turns out no, same limitations
			that i was unable to get past. at least it works in some way, for
			those of you reading this that index them and fire at runtime rather
			than storing a reference/cache at the top of scripts or elsewhere
			and firing from that variable, this will work. for those of you that
			are the latter, remotefunctions wont work. at least i've got a pretty
			cool tool that im proud of though, just wish i hadn't got so hype
			about it.
			
--]]

const HttpService = game:GetService("HttpService")
const RunService = game:GetService("RunService")
const PluginConnectionService = game:GetService("PluginConnectionService")

const Maid = require(script.Parent.MiniMaid)

const TestType = Enum.PluginConnectionTargetType.Test
const EditType = Enum.PluginConnectionTargetType.Edit

const Link = {
	Side = "Edit",			-- "Edit" | "Server" | "Client"
	OnPayload = nil,		-- edit side hooks this
	Maid = Maid.new(),
}

local Queue = {}
local Target = nil

--[[
	IsEdit() returns boolean
	Whether this is the data model holding the window
--]]
function Link:IsEdit(): boolean
	-- only Edit can have Test connections. three copies of this plugin are
	-- running right now and this one line is how each works out which it is
	return PluginConnectionService:CanHaveConnectionType(TestType)
end

--[[
	Send() returns nil
	Queues one payload for the next flush

	@payload: plain table. no instances, no buffers, it has to survive JSON
--]]
function Link:Send(payload)
	payload.Side = self.Side
	table.insert(Queue, payload)
end

--[[
	Bind() returns nil
	Listens to one test data model

	@connection: the PluginConnection
--]]
-- one pcall per payload, not per batch. one bad message used to take the rest
-- of the batch with it and half a seconds traffic would just vanish
function Link:Bind(connection)
	const Binding = connection:BindToMessage(function(message: string)
		const Success, Batch = pcall(HttpService.JSONDecode, HttpService, message)
		if not Success then return end

		-- test data models cant reach each other, only edit. so the servers events
		-- get passed on to the client, whose window is the one studio draws
		if self.Side == "Edit" then
			for _, Other in PluginConnectionService:GetPluginConnectionsOfType(TestType) do
				if Other ~= connection and Other.Connected then
					pcall(function()
						Other:SendMessage(message)
					end)
				end
			end
		end

		for _, Payload in Batch do
			if Payload.Side == self.Side then continue end

			if self.OnPayload then
				const Handled, Failure = pcall(self.OnPayload, Payload)

				if not Handled then
					warn("[ri] OnPayload:", Failure, Payload.Kind, Payload.Path)
				end
			end
		end
	end)

	self.Maid:GiveTask(function()
		const Success, Error = pcall(function()
			Binding:Disconnect()
		end)

		if not Success then
			warn("[ri] binding disconnect:", Error)
		end
	end)
end

--[[
	StartEdit() returns nil
	Picks up the test data models
--]]
function Link:StartEdit()
	self.Side = "Edit"

	-- both of these. a connection can already exist AND turn up later, and the
	-- logs come out in an order that makes no sense either way
	for _, Connection in PluginConnectionService:GetPluginConnectionsOfType(TestType) do
		self:Bind(Connection)
	end

	self.Maid:GiveTask(PluginConnectionService.Connected:Connect(function(connection)
		if connection.Type == TestType then
			self:Bind(connection)
		end
	end))

	-- replay requests go the other way. both test data models get the batch and
	-- each drops whats not addressed to it, cheaper than working out which
	-- connection is which side
	self.Maid:GiveTask(RunService.Heartbeat:Connect(function()
		if #Queue == 0 then return end

		const Batch = Queue
		Queue = {}

		const Message = HttpService:JSONEncode(Batch)

		-- dropped if nothing is connected. a request landing in a session it
		-- wasnt meant for is worse than one that never lands at all
		for _, Connection in PluginConnectionService:GetPluginConnectionsOfType(TestType) do
			if Connection.Connected then
				pcall(function()
					Connection:SendMessage(Message)
				end)
			end
		end
	end))
end

--[[
	StartTest() returns nil
	Finds the way back to Edit and flushes whatever Capture queues
--]]
function Link:StartTest()
	self.Side = RunService:IsServer() and "Server" or "Client"

	task.spawn(function()
		Target = PluginConnectionService:GetPluginConnectionsOfType(EditType)[1]

		while not Target do
			const New = PluginConnectionService.Connected:Wait()

			if New.Type == EditType then
				Target = New
			end
		end

		self:Bind(Target)
	end)

	-- batched. one SendMessage per event locked studio solid on anything with a
	-- replication loop, which is exactly the thing i wanted to look at
	self.Maid:GiveTask(RunService.Heartbeat:Connect(function()
		if not Target or not Target.Connected or #Queue == 0 then return end

		const Batch = Queue
		Queue = {}

		pcall(function()
			Target:SendMessage(HttpService:JSONEncode(Batch))
		end)
	end))
end

function Link:Stop()
	self.Maid:DoCleaning()

	Queue = {}
	Target = nil
end

return Link
