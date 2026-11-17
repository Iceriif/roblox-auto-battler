--!strict
-- A drop-in for TweenService:Create on the server that lets each player's computer play the
-- tween instead (the lag fix, 2026-10-20). A server tween changes the property every frame and
-- every change is sent to every player: dozens of fading effect parts per hit, in every match,
-- times every player in the server. Here the server sends the tween ONCE (as attributes on the
-- instance: from, to, timing, start time), the client (src/client/NetTweens.luau) plays it
-- locally, and the server sets the end value once when it's done (so anyone streaming the part
-- in later, and any server code reading it, sees the end state).
--
--   NetTween.Create(instance, TweenInfo, goal) -> { Play, Cancel, Completed, PlaybackState }
--
-- Attributes per tweened property <P>: NTi_<P> = "style,direction,time,repeat,reverses,delay",
-- NTf_<P> / NTt_<P> = from / to, NTs_<P> = server start time (set last: the client starts on it;
-- removed on Cancel). Values the attributes can't hold fall back to a real TweenService tween.

local CollectionService = game:GetService("CollectionService")
local TweenService = game:GetService("TweenService")

local NetTween = {}

local TAG = "NetTween"

export type Handle = {
	Play: (self: Handle) -> (),
	Cancel: (self: Handle) -> (),
	Completed: RBXScriptSignal,
	PlaybackState: Enum.PlaybackState,
}

local SUPPORTED = { number = true, Vector3 = true, CFrame = true, Color3 = true, UDim2 = true, Vector2 = true }

local function lerp(a: any, b: any, t: number): any
	if typeof(a) == "number" then
		return a + (b - a) * t
	end
	return a:Lerp(b, t)
end

-- the eased progress (0-1 of from -> to) `elapsed` seconds after the start (delay included)
function NetTween.Alpha(info: TweenInfo, elapsed: number): number
	local t = elapsed - info.DelayTime
	if t <= 0 then
		return 0
	end
	local dur = math.max(info.Time, 1e-3)
	local cycle = if info.Reverses then dur * 2 else dur
	local cycles = info.RepeatCount + 1
	if info.RepeatCount >= 0 and t >= cycle * cycles then
		return if info.Reverses then 0 else 1
	end
	local within = t % cycle
	local a = if info.Reverses and within > dur then 1 - (within - dur) / dur else within / dur
	return TweenService:GetValue(math.clamp(a, 0, 1), info.EasingStyle, info.EasingDirection)
end

function NetTween.Create(instance: Instance, info: TweenInfo, goal: { [string]: any }): Handle
	-- anything the attributes can't carry: a plain server tween
	for key, value in goal do
		local ok, current = pcall(function()
			return (instance :: any)[key]
		end)
		if not SUPPORTED[typeof(value)] or not ok or typeof(current) ~= typeof(value) then
			return TweenService:Create(instance, info, goal) :: any
		end
	end

	local done = Instance.new("BindableEvent")
	local handle: any = { PlaybackState = Enum.PlaybackState.Begin, Completed = done.Event }
	local from: { [string]: any } = {}
	local started = 0
	local token = 0

	local function finish(state: Enum.PlaybackState)
		handle.PlaybackState = state
		done:Fire(state)
		task.defer(function()
			done:Destroy()
		end)
	end

	function handle.Play(_self)
		if handle.PlaybackState == Enum.PlaybackState.Playing then
			return
		end
		token += 1
		local mine = token
		started = workspace:GetServerTimeNow()
		handle.PlaybackState = Enum.PlaybackState.Playing
		local infoText = `{info.EasingStyle.Name},{info.EasingDirection.Name},{info.Time},{info.RepeatCount},{if info.Reverses then 1 else 0},{info.DelayTime}`
		for key, value in goal do
			from[key] = (instance :: any)[key]
			instance:SetAttribute("NTi_" .. key, infoText)
			instance:SetAttribute("NTf_" .. key, from[key])
			instance:SetAttribute("NTt_" .. key, value)
			instance:SetAttribute("NTs_" .. key, started) -- (last: the client starts on this one)
		end
		if not CollectionService:HasTag(instance, TAG) then
			CollectionService:AddTag(instance, TAG)
		end
		if info.RepeatCount < 0 then
			return -- (repeats forever: runs until cancelled)
		end
		local total = info.DelayTime + info.Time * (info.RepeatCount + 1) * (if info.Reverses then 2 else 1)
		task.delay(total, function()
			if mine ~= token or handle.PlaybackState ~= Enum.PlaybackState.Playing then
				return
			end
			-- the end value, set once on the server (the client is already there)
			if instance.Parent then
				for key, value in goal do
					pcall(function()
						(instance :: any)[key] = if info.Reverses then from[key] else value
					end)
				end
			end
			finish(Enum.PlaybackState.Completed)
		end)
	end

	function handle.Cancel(_self)
		if handle.PlaybackState ~= Enum.PlaybackState.Playing then
			return
		end
		token += 1
		-- stop where it is now: the server takes the value it had reached, the client stops too
		local alpha = NetTween.Alpha(info, workspace:GetServerTimeNow() - started)
		for key, value in goal do
			pcall(function()
				(instance :: any)[key] = lerp(from[key], value, alpha)
			end)
			instance:SetAttribute("NTs_" .. key, nil)
		end
		finish(Enum.PlaybackState.Cancelled)
	end

	return handle :: Handle
end

-- Shaped like TweenService (`Service:Create(...)`), so a module only swaps its
-- `local TweenService = game:GetService("TweenService")` line for this one.
NetTween.Service = {
	Create = function(_self: any, instance: Instance, info: TweenInfo, goal: { [string]: any }): Handle
		return NetTween.Create(instance, info, goal)
	end,
}

return NetTween
