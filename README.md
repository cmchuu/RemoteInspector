# Why I made this

I spent a **long time** debugging network traffic by printing inside every OnServerEvent, it works but it is miserable. I wanted something that showed me what was going over the wire while I played.

There are a couple tools that have similar use cases as this, most notably:
[Packet Profiler](https://devforum.roblox.com/t/packet-profiler-easily-measure-all-of-your-remotes/1890924) by PysephDEV
[RAT](https://devforum.roblox.com/t/rat-remote-events-analyzer-tool/3102898) by trmz_dev

If bandwidth usage is what you care about, PacketProfiler does a better job at this than I do. RAT is a simpler take on the same idea I had.

What neither of them do is Bindables or Signals, which I wanted to include in mine as these also matter to me when inspecting traffic in my game.

---

# The plugin

https://create.roblox.com/store/asset/111624145776068/Remote-Inspector

<img width="908" height="397" alt="image" src="https://github.com/user-attachments/assets/50df80af-47de-422a-bf8c-2c04a872a12a" />

---

# How to use
Install it and open **Remote Inspector** from the Plugins tab, then press Play. It will begin logging on its own.

There are three views you switch between, and this is done via the drop down in the top bar.

**Traffic** is the live log, ordered by newest first. If a repeated call fires consecutively, it will collapse into one row and display a count. You can switch this to **Grouped** to **All calls** if you'd rather view them separately.

**Remotes** is the total fires per remote, with any warnings that may apply. These warnings are explained below.

**Byte share** is the percentage of the traffic within the game that a certain remote is responsible for. You can click on them to ignore them, which will cause the rest to recalculate and display the usage with these ignored. I added this because in one of the games I tested in, a replication remote was 90% of it, and thought this may be relevant for other users too.

You can click on any row to open up an expanded view and view the full arguments. Buffers will just get a hex dump. You can right click a row to ignore that remote's calls, select it in explorer. or copy the path.

For signals, there is a TextBox in Settings that allows you to point the plugin to a Signal module. It works with class-based Signal implementations, like those built off GoodSignal.

---


# Warnings
Not sure how useful this will be, I just thought some things were worth warning a user about.

| Warning | Means |
| --- | --- |
| instance from client | a client passed an Instance reference |
| no rate limit | one player fired something over 20 times a second |
| large payload | a single call over 4KB |
| near the 1000 B unreliable limit | past that the engine silently drops it |
| NaN or infinite number | a broken number made it onto the wire |
| handler errored | a RemoteFunction handler threw |
| never fired | it exists, nothing has used it, and it is still callable by anyone |

---

# Things you should know
**The byte counts are only estimates.** Roblox doesn't provide an API for this so the sizes are just worked out from the type of argument. Buffers are an exception as buffer.len is exact, but Roblox still compresses those before sending so the real number is lower than what you see. Use this to compare remotes rather than get exact figures.

**RemoteFunctions only work in some cases and I am not happy about it.** While you can set a callback in Luau, you cannot read one. There isn't a way to hook onto whatever your game put there. The only option is to proxy it, this works on specific cases such as when you index the path at the point of calling:

```lua
ReplicatedStorage.BuyItem:InvokeServer("sword")
```

but not if you grabbed the reference at the top of your script, which is how most people write it:

```lua
local BuyItem = ReplicatedStorage:WaitForChild("BuyItem")
BuyItem:InvokeServer("sword")
```

The plugin loads after the code does, by the time it can swap anything, your references may already be holding the real one. I spent a lot of time researching but I don't think there is a way past this (if I am wrong, PLEASE let me know how to do this). There is a setting to turn RemoteFunction capture off entirely. It costs a round trip per call and breaks InvokeClient, so if those matter leave it off. Never used InvokeClient myself though.

**There is a master switch in Settings.** If you turn it off, nothing gets hooked at all. Your game runs the same as if you didn't have the plugin installed.

---

If there is something this does not capture and you'd like me to add it, please suggest below. This is relevant for other popular Signal modules, if any do not work please let me know and I'll do my best to add them.
