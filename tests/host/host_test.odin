package test_host

import "core:math"
import "core:testing"

import "../../src/host"
import "../../src/net"
import "../../src/session"
import "../../src/sim"
import "../../src/world"

STONE :: world.Block_Id(world.Builtin.Stone)
BRICK :: world.Block_Id(world.Builtin.Brick)

Fixture :: struct {
	reg:  world.Registry,
	flat: world.Flat,
	w:    world.World,
	hub:  net.Memory_Hub,
	h:    host.Host,
}

fixture_init :: proc(f: ^Fixture, view_radius: i32 = 1) {
	world.registry_init(&f.reg)
	world.register_builtin_blocks(&f.reg)
	f.flat = {
		height = 40,
		block  = STONE,
	}
	world.world_init(&f.w, &f.reg, world.flat_generator(&f.flat))
	net.memory_hub_init(&f.hub)
	config := host.DEFAULT_CONFIG
	config.view_radius = view_radius
	config.chunks_per_tick = 8
	sim_config := sim.DEFAULT_CONFIG
	sim_config.load_radius = 1
	host.host_init(&f.h, &f.w, net.memory_hub_transport(&f.hub), config, sim_config)
}

fixture_destroy :: proc(f: ^Fixture) {
	host.host_destroy(&f.h)
	world.world_destroy(&f.w)
	world.registry_destroy(&f.reg)
}

connect :: proc(f: ^Fixture, c: ^session.Client, name: string) {
	session.client_init(c, &f.reg, net.memory_connect(&f.hub), name)
}

// Runs a tick on every client, then the host, so a round trip takes one
// tick each way as it would over a network.
tick :: proc(f: ^Fixture, clients: []^session.Client, inputs: []sim.Input, n: int) {
	for _ in 0 ..< n {
		for c, i in clients {
			session.client_tick(c, inputs[i])
		}
		host.host_tick(&f.h)
	}
}

@(test)
client_joins_and_receives_chunks :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f)
	defer fixture_destroy(&f)
	c: session.Client
	connect(&f, &c, "a")
	defer session.client_destroy(&c)

	tick(&f, {&c}, {{}}, 3)
	testing.expect_value(t, c.status, session.Status.Joined)
	testing.expect_value(t, c.me, sim.Player_Id(1))
	testing.expect_value(t, c.tick_rate, u32(20))

	// A view radius of 1 is 27 chunks, at 8 per tick.
	tick(&f, {&c}, {{}}, 4)
	testing.expect_value(t, c.stats.chunks_received, 27)
	testing.expect_value(t, len(c.mirror.chunks), 27)
	// The mirrored chunk matches the host's.
	hc := world.world_chunk(&f.w, {0, 1, 0})
	cc := world.world_chunk(&c.mirror, {0, 1, 0})
	testing.expect(t, hc != nil && cc != nil)
	testing.expect_value(t, cc.non_air, hc.non_air)
	testing.expect_value(t, world.chunk_get(cc, 3, 7, 3), STONE)
	// The client has not loaded anything by itself.
	testing.expect(t, len(c.changed) == 27, "every received chunk is reported once")
}

@(test)
prediction_matches_host :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f)
	defer fixture_destroy(&f)
	c: session.Client
	connect(&f, &c, "a")
	defer session.client_destroy(&c)
	tick(&f, {&c}, {{}}, 8)

	// Walk, turn, jump. After each burst the host's player and the
	// client's prediction agree once the pipeline has drained.
	inputs := [?]sim.Input {
		{move = {0, 0, 1}, yaw = 0.4},
		{move = {1, 0, 0}, yaw = 1.2, jump = true},
		{move = {0, 0, -1}, yaw = 2.0},
	}
	// Joining starts the prediction before any chunk has arrived, which
	// costs a correction; count from here.
	c.stats.corrections = 0
	for input in inputs {
		tick(&f, {&c}, {input}, 15)
		// In this lockstep loop the host has applied every input the client
		// has sent by the time a tick ends, so the two agree exactly.
		hp := f.h.game.players[1]
		cp, ok := session.local_player(&c)
		testing.expect(t, ok)
		d := hp.pos - cp.pos
		testing.expectf(
			t,
			math.abs(d.x) < 0.001 && math.abs(d.y) < 0.001 && math.abs(d.z) < 0.001,
			"prediction off by %v with %v pending",
			d,
			len(c.pending),
		)
	}
	testing.expect(t, c.stats.corrections == 0, "a smooth run should need no corrections")
}

@(test)
block_changes_reach_every_client :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f)
	defer fixture_destroy(&f)
	a, b: session.Client
	connect(&f, &a, "a")
	connect(&f, &b, "b")
	defer session.client_destroy(&a)
	defer session.client_destroy(&b)
	tick(&f, {&a, &b}, {{}, {}}, 10)
	testing.expect_value(t, a.status, session.Status.Joined)
	testing.expect_value(t, b.status, session.Status.Joined)
	// Both see each other.
	testing.expect(t, b.me in a.players, "a should see b")
	testing.expect(t, a.me in b.players, "b should see a")

	// a breaks the block under its feet.
	down := sim.Input {
		pitch  = -math.PI / 2 + 0.01,
		action = .Break,
	}
	tick(&f, {&a, &b}, {down, {}}, 1)
	// Predicted at once on a.
	testing.expect_value(t, world.world_get_block(&a.mirror, {0, 39, 0}), world.AIR)
	tick(&f, {&a, &b}, {{}, {}}, 2)
	testing.expect_value(t, world.world_get_block(&f.w, {0, 39, 0}), world.AIR)
	testing.expect_value(t, world.world_get_block(&b.mirror, {0, 39, 0}), world.AIR)

	// b places a brick on the floor ahead; a sees it.
	place := sim.Input {
		pitch       = -0.7,
		yaw         = 1,
		action      = .Place,
		place_block = BRICK,
	}
	tick(&f, {&a, &b}, {{}, place}, 1)
	tick(&f, {&a, &b}, {{}, {}}, 2)
	found := false
	for _, c in f.w.chunks {
		for i in 0 ..< world.CHUNK_VOLUME {
			if world.chunk_get_index(c, i) == BRICK {
				found = true
			}
		}
	}
	testing.expect(t, found, "the brick should be in the host world")
	found_a := false
	for _, c in a.mirror.chunks {
		for i in 0 ..< world.CHUNK_VOLUME {
			if world.chunk_get_index(c, i) == BRICK {
				found_a = true
			}
		}
	}
	testing.expect(t, found_a, "the brick should have reached a")
}

@(test)
leaving_and_refusing :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f)
	f.h.config.max_players = 1
	defer fixture_destroy(&f)
	a, b: session.Client
	connect(&f, &a, "a")
	defer session.client_destroy(&a)
	tick(&f, {&a}, {{}}, 3)
	connect(&f, &b, "b")
	defer session.client_destroy(&b)
	tick(&f, {&a, &b}, {{}, {}}, 3)
	testing.expect_value(t, b.status, session.Status.Refused)
	testing.expect_value(t, b.reason, "server is full")
	testing.expect_value(t, len(f.h.game.players), 1)

	net.transport_disconnect(a.transport, net.SERVER)
	tick(&f, {&a}, {{}}, 2)
	testing.expect_value(t, len(f.h.game.players), 0)
	testing.expect_value(t, a.status, session.Status.Disconnected)
}

@(test)
moving_streams_and_unloads_chunks :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f)
	defer fixture_destroy(&f)
	c: session.Client
	connect(&f, &c, "a")
	defer session.client_destroy(&c)
	tick(&f, {&c}, {{}}, 10)
	testing.expect_value(t, len(c.mirror.chunks), 27)

	// Fly far along +z: chunks behind get unloaded, chunks ahead arrive.
	fly := sim.Input {
		flying = true,
		move   = {0, 0, 1},
	}
	tick(&f, {&c}, {fly}, 200)
	p, _ := session.local_player(&c)
	testing.expect(t, p.pos.z > 100, "player should have flown far")
	testing.expect(t, len(c.removed) > 0, "chunks behind should be unloaded")
	testing.expect(
		t,
		world.world_chunk(&c.mirror, {0, 1, 0}) == nil,
		"the start chunk should be gone",
	)
	center := world.chunk_pos_of(p.pos)
	testing.expect(
		t,
		world.world_chunk(&c.mirror, center) != nil,
		"the chunk under the player is loaded",
	)
	// The host evicted what nobody is near.
	for pos in f.w.loaded {
		testing.expect(t, abs(pos.z - center.z) <= 6, "a far chunk is still loaded on the host")
	}
}
