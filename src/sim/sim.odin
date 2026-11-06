// The authoritative game logic as a library. A Sim holds the players and
// the world, takes one tick of inputs and advances everything. It knows
// nothing about sockets, threads, windows or clocks, so the dedicated
// server, the singleplayer client, a P2P host and the client's prediction
// all run this same code.
package sim

import "core:math"

import "../world"

Player_Id :: distinct u32

// What a player wants this tick. Movement is in the player's own frame;
// the sim turns it into velocity and resolves collisions.
Input :: struct {
	// x is strafe (+right), y is vertical intent while flying, z is forward.
	// Each in -1..1.
	move:        [3]f32,
	// Radians. Yaw 0 faces +z and grows toward +x; pitch is up.
	yaw, pitch:  f32,
	jump:        bool,
	flying:      bool,
	action:      Action,
	// The block to place for Action.Place.
	place_block: world.Block_Id,
}

Action :: enum u8 {
	None,
	Break,
	Place,
}

Player :: struct {
	id:         Player_Id,
	// Feet center.
	pos:        [3]f32,
	vel:        [3]f32,
	yaw, pitch: f32,
	on_ground:  bool,
	flying:     bool,
}

// Tunables. Benchmark scenes and tests pass their own.
Config :: struct {
	tick_rate:     int,
	gravity:       f32,
	walk_speed:    f32,
	fly_speed:     f32,
	jump_speed:    f32,
	// How far a player can break or place, in blocks.
	reach:         f32,
	player_width:  f32,
	player_height: f32,
	eye_height:    f32,
	// Chunks loaded around each player, as a radius in chunks.
	load_radius:   i32,
}

DEFAULT_CONFIG :: Config {
	tick_rate     = 20,
	gravity       = 28,
	walk_speed    = 4.5,
	fly_speed     = 14,
	jump_speed    = 9,
	reach         = 5,
	player_width  = 0.6,
	player_height = 1.8,
	eye_height    = 1.62,
	load_radius   = 3,
}

// A block that changed during a tick, for the host to broadcast.
Block_Change :: struct {
	pos: world.Block_Pos,
	id:  world.Block_Id,
	by:  Player_Id,
}

Sim :: struct {
	world:       ^world.World,
	config:      Config,
	players:     map[Player_Id]Player,
	tick:        u64,
	next_player: u32,
	// Appended by sim_step; the host drains it after each tick.
	changes:     [dynamic]Block_Change,
}

sim_init :: proc(
	s: ^Sim,
	w: ^world.World,
	config := DEFAULT_CONFIG,
	allocator := context.allocator,
) {
	s.world = w
	s.config = config
	s.players = make(map[Player_Id]Player, allocator)
	s.changes = make([dynamic]Block_Change, 0, 16, allocator)
	s.next_player = 1
}

sim_destroy :: proc(s: ^Sim) {
	delete(s.players)
	delete(s.changes)
}

tick_seconds :: proc "contextless" (s: ^Sim) -> f32 {
	return 1.0 / f32(s.config.tick_rate)
}

// Adds a player standing on the ground at the spawn column and returns
// its id. Loads the chunks around it.
sim_add_player :: proc(s: ^Sim) -> Player_Id {
	id := Player_Id(s.next_player)
	s.next_player += 1
	p := Player {
		id  = id,
		pos = find_spawn(s, 0, 0),
	}
	s.players[id] = p
	ensure_loaded(s, p.pos)
	return id
}

sim_remove_player :: proc(s: ^Sim, id: Player_Id) {
	delete_key(&s.players, id)
}

// Where a player at the given column stands: just above the highest solid
// block, searching down from a safe height.
find_spawn :: proc(s: ^Sim, x, z: i32) -> [3]f32 {
	top := i32(128)
	for y := top; y > -64; y -= 1 {
		cpos, _, _, _ := world.split_block_pos({x, y, z})
		world.world_load_chunk(s.world, cpos)
		if world.world_is_solid(s.world, {x, y, z}) {
			return {f32(x) + 0.5, f32(y + 1), f32(z) + 0.5}
		}
	}
	return {f32(x) + 0.5, f32(top), f32(z) + 0.5}
}

// Loads every chunk within the load radius of a position.
ensure_loaded :: proc(s: ^Sim, pos: [3]f32) {
	center := world.chunk_pos_of(pos)
	r := s.config.load_radius
	for dy in -r ..= r {
		for dz in -r ..= r {
			for dx in -r ..= r {
				world.world_load_chunk(s.world, {center.x + dx, center.y + dy, center.z + dz})
			}
		}
	}
}

// Advances one tick with the given inputs. Players without an input this
// tick keep moving under physics with no intent.
sim_step :: proc(s: ^Sim, inputs: map[Player_Id]Input) {
	dt := tick_seconds(s)
	for id, &p in s.players {
		input := inputs[id] or_else Input{yaw = p.yaw, pitch = p.pitch, flying = p.flying}
		step_player(s, &p, input, dt)
		ensure_loaded(s, p.pos)
		if input.action != .None {
			apply_action(s, &p, input)
		}
	}
	s.tick += 1
}

// The direction a player looks along.
look_dir :: proc "contextless" (yaw, pitch: f32) -> [3]f32 {
	cp := math.cos(pitch)
	return {math.sin(yaw) * cp, math.sin(pitch), math.cos(yaw) * cp}
}

eye_pos :: proc "contextless" (s: ^Sim, p: ^Player) -> [3]f32 {
	return p.pos + {0, s.config.eye_height, 0}
}

@(private = "file")
step_player :: proc(s: ^Sim, p: ^Player, input: Input, dt: f32) {
	c := s.config
	p.yaw = input.yaw
	p.pitch = clamp(input.pitch, -math.PI / 2 + 0.001, math.PI / 2 - 0.001)
	p.flying = input.flying

	forward := [3]f32{math.sin(p.yaw), 0, math.cos(p.yaw)}
	right := [3]f32{math.cos(p.yaw), 0, -math.sin(p.yaw)}
	wish := forward * input.move.z + right * input.move.x
	if l := wish.x * wish.x + wish.z * wish.z; l > 1 {
		wish /= math.sqrt(l)
	}

	if p.flying {
		p.vel = wish * c.fly_speed
		p.vel.y = clamp(input.move.y, -1, 1) * c.fly_speed
	} else {
		p.vel.x = wish.x * c.walk_speed
		p.vel.z = wish.z * c.walk_speed
		p.vel.y -= c.gravity * dt
		if input.jump && p.on_ground {
			p.vel.y = c.jump_speed
		}
	}
	move_and_collide(s, p, p.vel * dt)
}

// Moves the player's box by `delta`, one axis at a time, stopping at solid
// blocks. Sets on_ground when a downward move was stopped.
@(private = "file")
move_and_collide :: proc(s: ^Sim, p: ^Player, delta: [3]f32) {
	half := s.config.player_width / 2
	height := s.config.player_height
	p.on_ground = false
	for axis in 0 ..< 3 {
		d := delta[axis]
		if d == 0 {
			continue
		}
		next := p.pos
		next[axis] += d
		lo := [3]f32{next.x - half, next.y, next.z - half}
		hi := [3]f32{next.x + half, next.y + height, next.z + half}
		// The blocks the moved box overlaps; hi is exclusive, so a box
		// exactly on a block boundary doesn't touch the block beyond it.
		min_b := world.block_pos_of(lo)
		max_b := world.block_pos_of(hi - 0.0001)
		hit := false
		search: for by in min_b.y ..= max_b.y {
			for bz in min_b.z ..= max_b.z {
				for bx in min_b.x ..= max_b.x {
					if world.world_is_solid(s.world, {bx, by, bz}) {
						hit = true
						break search
					}
				}
			}
		}
		if !hit {
			p.pos = next
			continue
		}
		// Stop flush against the blocking block.
		if d > 0 {
			edge := f32(max_b[axis])
			size := axis == 1 ? height : half
			p.pos[axis] = edge - size - 0.0001
		} else {
			edge := f32(min_b[axis] + 1)
			size := axis == 1 ? 0 : half
			p.pos[axis] = edge + size + 0.0001
			if axis == 1 {
				p.on_ground = true
			}
		}
		p.vel[axis] = 0
	}
}

// What a ray from the eye hits: the block and the face it entered through.
Hit :: struct {
	pos:    world.Block_Pos,
	normal: [3]i32,
	ok:     bool,
}

// Steps a ray through the voxel grid (Amanatides and Woo) up to `reach`
// blocks and returns the first solid block.
raycast :: proc(w: ^world.World, origin, dir: [3]f32, reach: f32) -> Hit {
	pos := world.block_pos_of(origin)
	step: [3]i32
	t_max, t_delta: [3]f32
	for i in 0 ..< 3 {
		if dir[i] > 0 {
			step[i] = 1
			t_max[i] = (f32(pos[i] + 1) - origin[i]) / dir[i]
			t_delta[i] = 1 / dir[i]
		} else if dir[i] < 0 {
			step[i] = -1
			t_max[i] = (origin[i] - f32(pos[i])) / -dir[i]
			t_delta[i] = -1 / dir[i]
		} else {
			step[i] = 0
			t_max[i] = math.F32_MAX
			t_delta[i] = math.F32_MAX
		}
	}
	normal: [3]i32
	t: f32
	for t <= reach {
		if world.world_is_solid(w, pos) {
			return Hit{pos = pos, normal = normal, ok = true}
		}
		axis := 0
		if t_max.y < t_max[axis] {
			axis = 1
		}
		if t_max.z < t_max[axis] {
			axis = 2
		}
		t = t_max[axis]
		t_max[axis] += t_delta[axis]
		pos[axis] += step[axis]
		normal = {}
		normal[axis] = -step[axis]
	}
	return {}
}

@(private = "file")
apply_action :: proc(s: ^Sim, p: ^Player, input: Input) {
	hit := raycast(s.world, eye_pos(s, p), look_dir(p.yaw, p.pitch), s.config.reach)
	if !hit.ok {
		return
	}
	switch input.action {
	case .None:
	case .Break:
		if world.world_set_block(s.world, hit.pos, world.AIR) {
			append(&s.changes, Block_Change{pos = hit.pos, id = world.AIR, by = p.id})
		}
	case .Place:
		if input.place_block == world.AIR {
			return
		}
		target := world.Block_Pos(([3]i32)(hit.pos) + hit.normal)
		if world.world_get_block(s.world, target) != world.AIR {
			return
		}
		// Not inside any player.
		for _, other in s.players {
			if box_overlaps_block(s, other.pos, target) {
				return
			}
		}
		if world.world_set_block(s.world, target, input.place_block) {
			append(&s.changes, Block_Change{pos = target, id = input.place_block, by = p.id})
		}
	}
}

@(private = "file")
box_overlaps_block :: proc(s: ^Sim, feet: [3]f32, b: world.Block_Pos) -> bool {
	half := s.config.player_width / 2
	lo := [3]f32{feet.x - half, feet.y, feet.z - half}
	hi := [3]f32{feet.x + half, feet.y + s.config.player_height, feet.z + half}
	bl := [3]f32{f32(b.x), f32(b.y), f32(b.z)}
	bh := bl + 1
	return lo.x < bh.x && hi.x > bl.x && lo.y < bh.y && hi.y > bl.y && lo.z < bh.z && hi.z > bl.z
}
