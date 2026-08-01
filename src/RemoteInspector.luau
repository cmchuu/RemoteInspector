--[[
	Author: @rinqLK, MIT licensed
	Desc:	Entry point. Runs three times, once per data model, and each copy has
			to work out which one its in before doing anything
--]]

const RunService = game:GetService("RunService")
const Link = require(script.Link)
const Capture = require(script.Capture)

Capture:LoadSettings(plugin)

-- three copies of this run at once adn for a long time i only knew about one
if Link:IsEdit() then
	const Interface = require(script.Interface)

	Capture.Draws = true

	Link.OnPayload = function(payload)
		Capture:HandlePayload(payload)
	end

	Link:StartEdit()
	Interface:Start(plugin)

	plugin.Unloading:Connect(function()
		Interface:Stop()
		Link:Stop()
	end)
else
	Link:StartTest()

	-- studio only draws the widget belonging to whichever data model is on
	-- screen, and during a playtest thats the client. so the client half gets a
	-- window of its own and edit forwards the servers events over to it
	if not RunService:IsServer() then
		const Interface = require(script.Interface)

		Capture.Mirror = true
		Capture.Draws = true

		Link.OnPayload = function(payload)
			Capture:HandlePayload(payload)
		end

		Interface:Start(plugin)

		plugin.Unloading:Connect(function()
			Interface:Stop()
		end)
	else
		-- the server draws nothing and never used to listen at all. it does now,
		-- a rerun of anything it caught has to be run by it
		Link.OnPayload = function(payload)
			Capture:HandlePayload(payload)
		end
	end

	Capture:Start()

	plugin.Unloading:Connect(function()
		Capture:Stop()
		Link:Stop()
	end)
end
