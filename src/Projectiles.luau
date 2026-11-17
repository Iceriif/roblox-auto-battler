--!strict
-- Straight-flying projectiles for ranged attacks. Simulated in 2D like the fighters; any level
-- rect (walls, blocks, platforms) stops them, and the hit is reported to Destruction (a platform
-- loses HP by the projectile's damage; anything else throws rubble). Each match's projectiles
-- live in its own World.
--
-- Shots from the two fighters collide in mid-air: a much stronger one (EAT_RATIO times the
-- damage) eats the smaller one and keeps flying; about even, they cancel each other in a clash
-- burst CANCEL_CHANCE of the time and otherwise fly past each other. A firing beam burns away the enemy shots it touches too (Projectiles.Eat).

local Destruction = require(script.Parent.Destruction)
local Effects = require(script.Parent.Effects)
local Physics2D = require(script.Parent.Physics2D)
local World = require(script.Parent.World)

export type Target = { Body: Physics2D.Body, Dead: boolean }

type Projectile = {
	Part: BasePart,
	X: number,
	Y: number,
	VX: number,
	VY: number,
	Radius: number,
	Life: number,
	Target: Target,
	OnHit: () -> (),
	Noticed: boolean, -- the target's AI has already reacted to this one
	Damage: number, -- what it does to a platform it hits (Destruction.luau); also its weight in a collision
	Gone: boolean?, -- destroyed in a collision this frame (removed after the collision pass)
	Passed: { [any]: boolean }?, -- shots it met that rolled "fly past" (so the pair isn't rolled again)
	Smasher: boolean?, -- shatters every breakable platform its body touches and flies on (MakeSmasher)
	Pierce: boolean?, -- flies through everything but the floor (MakePiercing)
	OnLand: ((number, number) -> ())?, -- called (x, y) where it hits the level (Projectiles.OnLand)
	Turn: number?, -- steers toward the target this fast, radians/s (Projectiles.Curve)
}

local Projectiles = {}

-- a shot with this many times the other's damage eats it instead of both cancelling
local EAT_RATIO = 2
local CLASH_HITSTOP = 0.04
-- evenly matched shots that meet only cancel this often (rolled once per pair); otherwise they
-- fly past each other. In mirror matches both fire down the same line, and with every meeting
-- cancelling, almost nothing got through (fights timed out)
local CANCEL_CHANCE = 0.3
local rng = Random.new()

local function active(): { Projectile }
	return World.Get().Projectiles :: { Projectile }
end

function Projectiles.Spawn(
	x: number,
	y: number,
	dirX: number,
	dirY: number,
	speed: number,
	radius: number,
	color: Color3,
	target: Target,
	onHit: () -> (),
	range: number?, -- studs it can travel before fizzling (default: 3 seconds of flight)
	damage: number? -- its damage, also dealt to a platform it hits (default 0)
): BasePart -- (returned so a caller can restyle it; it's moved by Position, so a turn it's given stays)
	local part = Instance.new("Part")
	part.Name = "Projectile"
	part.Shape = Enum.PartType.Ball
	part.Size = Vector3.one * radius * 2 * World.Get().Scale -- radius is in arena units
	part.Color = color
	part.Material = Enum.Material.Neon
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Position = World.Point(x, y)
	part.Parent = World.Get().EffectsFolder

	table.insert(active(), {
		Part = part,
		X = x,
		Y = y,
		VX = dirX * speed,
		VY = dirY * speed,
		Radius = radius,
		Life = if range then range / speed else 3,
		Target = target,
		OnHit = onHit,
		Noticed = false,
		Damage = damage or 0,
	})
	return part
end

-- Makes the projectile drawn by `part` pass straight through platforms and other pieces of the
-- level, stopping only at the floor (Cursed King's Twin Rend, the user's ask 2026-11-01).
function Projectiles.MakePiercing(part: BasePart)
	for _, p in active() do
		if p.Part == part then
			p.Pierce = true
		end
	end
end

-- Calls `fn(x, y)` (arena units) when the projectile drawn by `part` hits the level instead of
-- its target (the Giga Orb's explosion where it lands, 2026-11-03).
function Projectiles.OnLand(part: BasePart, fn: (number, number) -> ())
	for _, p in active() do
		if p.Part == part then
			p.OnLand = fn
		end
	end
end

-- Sends the projectile drawn by `part` off on a curve: its launch turned `lift` radians up (minus
-- = down; mirrored for one flying left), then it steers toward its target's middle at up to
-- `turn` radians a second (Spirit Caster's triple shot arcing over and under, 2026-11-03).
function Projectiles.Curve(part: BasePart, lift: number, turn: number)
	for _, p in active() do
		if p.Part == part then
			local a = (if p.VX >= 0 then lift else -lift)
			local c, s = math.cos(a), math.sin(a)
			p.VX, p.VY = p.VX * c - p.VY * s, p.VX * s + p.VY * c
			p.Turn = turn
		end
	end
end

-- Makes the projectile drawn by `part` a smasher (see Update): it breaks through platforms.
function Projectiles.MakeSmasher(part: BasePart)
	for _, p in active() do
		if p.Part == part then
			p.Smasher = true
		end
	end
end

-- True once per projectile when one aimed at `target` will hit it within `horizon` seconds.
-- The AI uses this to decide whether to jump over the shot.
function Projectiles.Incoming(target: Target, horizon: number): boolean
	local b = target.Body
	for _, p in active() do
		if p.Target == target and not p.Noticed then
			local r = p.Radius
			local t = Physics2D.SegmentBox(
				p.X,
				p.Y,
				p.X + p.VX * horizon,
				p.Y + p.VY * horizon,
				b.X - b.HalfW - r,
				b.Y - r,
				b.X + b.HalfW + r,
				b.Y + b.Height + r
			)
			if t then
				p.Noticed = true
				return true
			end
		end
	end
	return false
end

-- the floor pieces only (solid, their tops at the floor's height): what a piercing shot stops at
local function floorsOf(rects: { any }): { any }
	local out = {}
	for _, r in rects do
		if not r.OneWay and r.MaxY <= 4 then
			table.insert(out, r)
		end
	end
	return out
end

local function vanish(p: Projectile, burst: number)
	p.Gone = true
	local at = p.Part.Position
	Effects.Pop(at, p.Radius * burst, p.Part.Color, 0.15)
	Effects.Sparks(at, 4, p.Part.Color, 2 + p.Radius * 2, 0.2)
	p.Part:Destroy()
end

-- Two shots meeting: the much stronger one eats the other, or (evenly matched) they cancel in a
-- clash burst, CANCEL_CHANCE of the time; otherwise they fly past each other.
local function collide(p: Projectile, q: Projectile, x: number, y: number)
	if p.Passed and p.Passed[q] then
		return
	end
	local pw, qw = math.max(p.Damage, p.Radius), math.max(q.Damage, q.Radius)
	if pw >= qw * EAT_RATIO then
		vanish(q, 2.5)
	elseif qw >= pw * EAT_RATIO then
		vanish(p, 2.5)
	elseif rng:NextNumber() >= CANCEL_CHANCE then
		p.Passed = p.Passed or {}
		;(p.Passed :: { [any]: boolean })[q] = true
	else
		local at = Effects.Point(x, y)
		local color = p.Part.Color:Lerp(q.Part.Color, 0.5):Lerp(Color3.new(1, 1, 1), 0.35)
		Effects.ClashBurst(at, 1.6 + (p.Radius + q.Radius) * 1.2, color, 0.3)
		Effects.Pop(at, 1.5 + p.Radius + q.Radius, Color3.new(1, 1, 1), 0.15)
		Effects.Sparks(at, 8, color, 4, 0.25)
		-- a burst of energy where they cancel (client Sounds "ShotClash")
		local world = World.Current
		if world and world.OnSound then
			world.OnSound(x, y, 0, "ShotClash", false, nil)
		end
		vanish(p, 1.5)
		vanish(q, 1.5)
		World.HitStop(CLASH_HITSTOP)
	end
end

-- Finds shots from opposite fighters that meet during this frame (swept, so fast head-on shots
-- can't pass through each other between frames).
local function collisions(list: { Projectile }, dt: number)
	for i = #list, 2, -1 do
		local p = list[i]
		for j = i - 1, 1, -1 do
			local q = list[j]
			if p.Gone then
				break
			end
			if not q.Gone and p.Target ~= q.Target then
				-- closest approach of q relative to p within this frame
				local dx, dy = q.X - p.X, q.Y - p.Y
				local rvx, rvy = q.VX - p.VX, q.VY - p.VY
				local rv2 = rvx * rvx + rvy * rvy
				local t = if rv2 > 1e-6 then math.clamp(-(dx * rvx + dy * rvy) / rv2, 0, dt) else 0
				local cx, cy = dx + rvx * t, dy + rvy * t
				local reach = p.Radius + q.Radius
				if cx * cx + cy * cy <= reach * reach then
					-- they meet between their centers at that moment
					local share = p.Radius / reach
					collide(p, q, p.X + p.VX * t + cx * share, p.Y + p.VY * t + cy * share)
				end
			end
		end
	end
	for i = #list, 1, -1 do
		if list[i].Gone then
			table.remove(list, i)
		end
	end
end

-- The nearest shot aimed at `target` within `radius` of (x, y), as its position (nil if none):
-- Null Breaker's anti-magic swings at shots about to reach it.
function Projectiles.Nearest(target: Target, x: number, y: number, radius: number): Vector2?
	local best: Vector2?, bestD = nil, radius
	for _, p in active() do
		if p.Target == target and not p.Gone then
			local d = math.sqrt((p.X - x) ^ 2 + (p.Y - y) ^ 2) - p.Radius
			if d <= bestD then
				best, bestD = Vector2.new(p.X, p.Y), d
			end
		end
	end
	return best
end

-- A beam (from x0, y0 to x1, y1, `halfWidth` either side) burns away the shots aimed at its
-- owner (`target`) that it touches, unless they're at least `maxDamage` strong.
function Projectiles.Eat(x0: number, y0: number, x1: number, y1: number, halfWidth: number, target: Target, maxDamage: number)
	local list = active()
	local lx, ly = x1 - x0, y1 - y0
	local len2 = math.max(lx * lx + ly * ly, 1e-6)
	for i = #list, 1, -1 do
		local p = list[i]
		if p.Target == target and p.Damage < maxDamage then
			local t = math.clamp(((p.X - x0) * lx + (p.Y - y0) * ly) / len2, 0, 1)
			local dx, dy = p.X - (x0 + lx * t), p.Y - (y0 + ly * t)
			local reach = halfWidth + p.Radius
			if dx * dx + dy * dy <= reach * reach then
				vanish(p, 2)
				table.remove(list, i)
			end
		end
	end
end

-- Catches the shots aimed at `target` within `radius` of (x, y) (Crimson Warlord's fan), unless
-- they're at least `maxDamage` strong: they vanish. Returns the damage they would have dealt.
function Projectiles.Absorb(target: Target, x: number, y: number, radius: number, maxDamage: number): number
	local list = active()
	local total = 0
	for i = #list, 1, -1 do
		local p = list[i]
		if p.Target == target and not p.Gone and p.Damage < maxDamage then
			local d = math.sqrt((p.X - x) ^ 2 + (p.Y - y) ^ 2) - p.Radius
			if d <= radius then
				total += p.Damage
				vanish(p, 1)
				table.remove(list, i)
			end
		end
	end
	return total
end

-- Sends the shots aimed at `target` within `radius` of (x, y) back the other way at `newTarget`
-- (Sorrow God's repelling pushes), unless they're at least `maxDamage` strong. Each one flies at
-- `speedScale` times its speed toward newTarget's chest; `onHit(damage, dirX)` is what it does when
-- it lands there now. Returns how many it turned.
function Projectiles.Reflect(target: Target, x: number, y: number, radius: number, newTarget: Target, maxDamage: number, speedScale: number, onHit: (number, number) -> ()): number
	local turned = 0
	for _, p in active() do
		if p.Target == target and not p.Gone and p.Damage < maxDamage then
			local d = math.sqrt((p.X - x) ^ 2 + (p.Y - y) ^ 2) - p.Radius
			if d <= radius then
				local b = newTarget.Body
				local dx, dy = b.X - p.X, b.Y + b.Height / 2 - p.Y
				local len = math.max(math.sqrt(dx * dx + dy * dy), 1e-3)
				local speed = math.sqrt(p.VX * p.VX + p.VY * p.VY) * speedScale
				p.VX, p.VY = dx / len * speed, dy / len * speed
				p.Target = newTarget
				p.Noticed = false
				p.Passed = nil
				-- (styled shots fly point-first: turned to point the new way)
				local pos = p.Part.Position
				p.Part.CFrame = CFrame.lookAt(pos, pos + Effects.V(dx, dy).Unit, Effects.Outward())
				p.Life = math.max(p.Life, len / speed + 0.5)
				local damage = p.Damage
				local dirX = if dx >= 0 then 1 else -1
				p.OnHit = function()
					onHit(damage, dirX)
				end
				turned += 1
			end
		end
	end
	return turned
end

function Projectiles.Update(dt: number, rects: { Physics2D.Rect })
	local list = active()
	collisions(list, dt)
	for i = #list, 1, -1 do
		local p = list[i]
		-- (a curving shot steers toward its target's middle: Projectiles.Curve)
		if p.Turn and not p.Target.Dead then
			local b = p.Target.Body
			local want = math.atan2(b.Y + b.Height / 2 - p.Y, b.X - p.X)
			local now = math.atan2(p.VY, p.VX)
			local diff = (want - now + math.pi) % (2 * math.pi) - math.pi
			local a = now + math.clamp(diff, -p.Turn * dt, p.Turn * dt)
			local speed = math.sqrt(p.VX * p.VX + p.VY * p.VY)
			p.VX, p.VY = math.cos(a) * speed, math.sin(a) * speed
		end
		local nx, ny = p.X + p.VX * dt, p.Y + p.VY * dt
		p.Life -= dt

		-- a smasher (the Giga Orb) shatters every breakable platform its whole body touches on the
		-- way and keeps going (walls, the floor and solid blocks still stop it)
		if p.Smasher then
			local r = p.Radius
			local minX, maxX = math.min(p.X, nx) - r, math.max(p.X, nx) + r
			local minY, maxY = math.min(p.Y, ny) - r, math.max(p.Y, ny) + r
			local speed = math.max(math.sqrt(p.VX * p.VX + p.VY * p.VY), 1e-3)
			for _, rect in table.clone(rects) do
				if rect.MaxX >= minX and rect.MinX <= maxX and rect.MaxY >= minY and rect.MinY <= maxY then
					Destruction.Smash(rect, nx, ny, p.VX / speed, p.VY / speed)
				end
			end
		end

		local tWall, wall = Physics2D.RaycastRect(p.X, p.Y, nx, ny, if p.Pierce then floorsOf(rects) else rects)
		local tHit: number? = nil
		if not p.Target.Dead then
			local b, r = p.Target.Body, p.Radius
			tHit = Physics2D.SegmentBox(p.X, p.Y, nx, ny, b.X - b.HalfW - r, b.Y - r, b.X + b.HalfW + r, b.Y + b.Height + r)
		end

		-- (a shade guarding the target, World.Shades, takes a shot that reaches it first)
		local shade, tShade = nil, nil
		local shades = World.Get().Shades
		if shades then
			for _, s in shades do
				if s.Guard == p.Target and not s.Dead then
					local b, r = s.Body, p.Radius
					local ts = Physics2D.SegmentBox(p.X, p.Y, nx, ny, b.X - b.HalfW - r, b.Y - r, b.X + b.HalfW + r, b.Y + b.Height + r)
					if ts and (tShade == nil or ts < tShade) then
						shade, tShade = s, ts
					end
				end
			end
		end

		if shade and tShade and (tWall == nil or tShade <= tWall) and (tHit == nil or tShade < tHit) then
			shade.Hit(math.max(p.Damage, 2), if p.VX >= 0 then 1 else -1, 10)
			vanish(p, 2)
			table.remove(list, i)
		elseif tHit and (tWall == nil or tHit <= tWall) then
			p.OnHit()
			p.Part:Destroy()
			table.remove(list, i)
		elseif tWall or p.Life <= 0 then
			if tWall then
				-- it hit the level: chips a platform, or throws rubble off the ground/walls
				local hx, hy = p.X + (nx - p.X) * tWall, p.Y + (ny - p.Y) * tWall
				local speed = math.max(math.sqrt(p.VX * p.VX + p.VY * p.VY), 1e-3)
				Destruction.Hit(wall, hx, hy, p.Damage, p.VX / speed, p.VY / speed)
				if p.OnLand then
					p.OnLand(hx, hy)
				end
			end
			p.Part:Destroy()
			table.remove(list, i)
		else
			p.X, p.Y = nx, ny
			p.Part.Position = World.Point(nx, ny)
		end
	end
end

function Projectiles.Clear()
	if not World.Current then
		return
	end
	local list = active()
	for _, p in list do
		p.Part:Destroy()
	end
	table.clear(list)
end

return Projectiles
