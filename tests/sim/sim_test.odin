package test_sim

import "core:math"
import "core:testing"

import "../../src/sim"
import "../../src/world"

STONE :: world.Block_Id(world.Builtin.Stone)
BRICK :: world.Block_Id(world.Builtin.Brick)

// A flat stone world up to y=40 with a sim on it.
Fixture :: struct {
	reg:  world.Registry,
	flat: world.Flat,
	w:    world.World,
	s:    sim.Sim,
}

fixture_init :: proc(f: ^Fixture) {
	world.registry_init(&f.reg)
	world.register_builtin_blocks(&f.reg)
	f.flat = {
		height = 40,
		block  = STONE,
	}
	world.world_init(&f.w, &f.reg, world.flat_generator(&f.flat))
	config := sim.DEFAULT_CONFIG
	config.load_radius = 1
	sim.sim_init(&f.s, &f.w, config)
}

fixture_destroy :: proc(f: ^Fixture) {
	sim.sim_destroy(&f.s)
	world.world_destroy(&f.w)
	world.registry_destroy(&f.reg)
}

run_ticks :: proc(s: ^sim.Sim, id: sim.Player_Id, input: sim.Input, n: int) {
	inputs := make(map[sim.Player_Id]sim.Input, context.temp_allocator)
	inputs[id] = input
	for _ in 0 ..< n {
		sim.sim_step(s, inputs)
	}
}

@(test)
player_spawns_on_ground_and_stays :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f)
	defer fixture_destroy(&f)
	id := sim.sim_add_player(&f.s)
	p := f.s.players[id]
	testing.expect_value(t, p.pos.y, f32(40))

	run_ticks(&f.s, id, {}, 40)
	p = f.s.players[id]
	testing.expect(t, p.on_ground, "player should rest on the ground")
	testing.expect(t, abs(p.pos.y - 40) < 0.01, "player sank or floated")
	testing.expect_value(t, f.s.tick, u64(40))
}

@(test)
player_walks_and_jumps :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f)
	defer fixture_destroy(&f)
	id := sim.sim_add_player(&f.s)
	run_ticks(&f.s, id, {}, 5)
	start := f.s.players[id].pos

	// Forward at yaw 0 is +z.
	run_ticks(&f.s, id, {move = {0, 0, 1}}, 20)
	p := f.s.players[id]
	testing.expect(t, p.pos.z > start.z + 4, "player should have walked forward about 4.5 blocks")
	testing.expect(t, abs(p.pos.x - start.x) < 0.001, "player drifted sideways")

	// A jump leaves the ground and comes back.
	run_ticks(&f.s, id, {jump = true}, 1)
	run_ticks(&f.s, id, {}, 3)
	testing.expect(t, f.s.players[id].pos.y > 40.5, "player should be in the air")
	run_ticks(&f.s, id, {}, 40)
	testing.expect(t, f.s.players[id].on_ground, "player should land")
}

@(test)
walls_stop_the_player :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f)
	defer fixture_destroy(&f)
	id := sim.sim_add_player(&f.s)
	run_ticks(&f.s, id, {}, 5)
	// A wall two blocks ahead (+z), two high.
	world.world_set_block(&f.w, {0, 40, 2}, STONE)
	world.world_set_block(&f.w, {0, 41, 2}, STONE)
	run_ticks(&f.s, id, {move = {0, 0, 1}}, 40)
	p := f.s.players[id]
	testing.expect(t, p.pos.z < 2 - 0.3 + 0.01, "player went through the wall")
	testing.expect(t, p.pos.z > 1.5, "player should be pressed against the wall")
}

@(test)
flying_ignores_gravity :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f)
	defer fixture_destroy(&f)
	id := sim.sim_add_player(&f.s)
	run_ticks(&f.s, id, {flying = true, move = {0, 1, 0}}, 10)
	p := f.s.players[id]
	testing.expect(t, p.pos.y > 45, "flying up should gain height")
	run_ticks(&f.s, id, {flying = true}, 10)
	testing.expect(t, abs(f.s.players[id].pos.y - p.pos.y) < 0.001, "flying player fell")
}

@(test)
break_and_place_change_blocks :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f)
	defer fixture_destroy(&f)
	id := sim.sim_add_player(&f.s)
	run_ticks(&f.s, id, {}, 5)

	// Look straight down and break the block under the feet.
	down := sim.Input {
		pitch  = -math.PI / 2 + 0.01,
		action = .Break,
	}
	run_ticks(&f.s, id, down, 1)
	testing.expect_value(t, len(f.s.changes), 1)
	testing.expect_value(t, f.s.changes[0].pos, world.Block_Pos{0, 39, 0})
	testing.expect_value(t, f.s.changes[0].id, world.AIR)
	testing.expect_value(t, world.world_get_block(&f.w, {0, 39, 0}), world.AIR)
	clear(&f.s.changes)
	// The player falls into the hole.
	run_ticks(&f.s, id, {}, 20)
	testing.expect(t, abs(f.s.players[id].pos.y - 39) < 0.01, "player should stand in the hole")

	// Place on the face of a block ahead: looking forward and slightly
	// down hits the floor beyond the hole, so the brick goes on top of it.
	ahead := sim.Input {
		pitch       = -0.6,
		action      = .Place,
		place_block = BRICK,
	}
	run_ticks(&f.s, id, ahead, 1)
	testing.expect_value(t, len(f.s.changes), 1)
	testing.expect_value(t, f.s.changes[0].id, BRICK)
	testing.expect_value(t, world.world_get_block(&f.w, f.s.changes[0].pos), BRICK)
	// Placing where the player stands is refused.
	clear(&f.s.changes)
	run_ticks(&f.s, id, down, 0)
	place_down := down
	place_down.action = .Place
	place_down.place_block = BRICK
	run_ticks(&f.s, id, place_down, 1)
	testing.expect_value(t, len(f.s.changes), 0)
}

@(test)
raycast_finds_the_floor :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f)
	defer fixture_destroy(&f)
	id := sim.sim_add_player(&f.s)
	_ = id
	hit := sim.raycast(&f.w, {0.5, 45, 0.5}, {0, -1, 0}, 10)
	testing.expect(t, hit.ok)
	testing.expect_value(t, hit.pos, world.Block_Pos{0, 39, 0})
	testing.expect_value(t, hit.normal, [3]i32{0, 1, 0})
	// Out of reach.
	hit = sim.raycast(&f.w, {0.5, 60, 0.5}, {0, -1, 0}, 10)
	testing.expect(t, !hit.ok)
	// A diagonal ray through air into the floor.
	hit = sim.raycast(&f.w, {0.5, 41.5, 0.5}, {0.6, -0.5, 0.6}, 10)
	testing.expect(t, hit.ok)
	testing.expect_value(t, hit.pos.y, i32(39))
}

@(test)
same_inputs_same_state :: proc(t: ^testing.T) {
	a, b: Fixture
	fixture_init(&a)
	fixture_init(&b)
	defer fixture_destroy(&a)
	defer fixture_destroy(&b)
	ia := sim.sim_add_player(&a.s)
	ib := sim.sim_add_player(&b.s)
	script := [?]sim.Input {
		{move = {1, 0, 1}, yaw = 0.3},
		{move = {0, 0, 1}, yaw = 0.7, jump = true},
		{move = {-1, 0, 0}, yaw = 1.1, pitch = -0.4, action = .Break},
		{flying = true, move = {0, 1, 1}, yaw = 2},
		{yaw = 2.5, pitch = -1, action = .Place, place_block = BRICK},
	}
	for input in script {
		run_ticks(&a.s, ia, input, 7)
		run_ticks(&b.s, ib, input, 7)
	}
	testing.expect_value(t, a.s.players[ia], b.s.players[ib])
	testing.expect_value(t, len(a.s.changes), len(b.s.changes))
}
