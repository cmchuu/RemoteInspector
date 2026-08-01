--[[
	Author: @rinqLK
	
	Desc:	Cut down maid
--]]

const Maid = {}
Maid.__index = Maid

export type T_Maid = typeof(setmetatable({} :: {_tasks: {any}}, Maid))

--[[
	new() returns T_Maid
	Makes a maid
--]]
function Maid.new(): T_Maid
	return setmetatable({_tasks = {}}, Maid)
end

--[[
	GiveTask() returns any
	Gives the maid something to clean up

	@item: connection, function or instance
--]]
function Maid:GiveTask(item: any): any
	table.insert(self._tasks, item)
	return item
end

--[[
	DoCleaning() returns nil
	Cleans everything up
--]]
function Maid:DoCleaning()
	const Tasks = self._tasks
	self._tasks = {}

	for _, Item in Tasks do
		if typeof(Item) == "RBXScriptConnection" then
			Item:Disconnect()
		elseif typeof(Item) == "function" then
			Item()
		elseif typeof(Item) == "Instance" then
			Item:Destroy()
		end
	end
end

return Maid
