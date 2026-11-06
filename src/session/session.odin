// The client side of a connection, without any rendering: joining, keeping
// a mirror of the world from the host's chunk messages, tracking other
// players, and predicting the local player with the same sim code the host
// runs, reconciled against the host's acknowledged inputs. The game client
// renders this; headless benchmark clients drive it directly.
package session

import "core:mem"

import "../net"
import "../sim"
import "../world"

Status :: enum u8 {
	Connecting,
	Joining,
	Joined,
	Refused,
	Disconnected,
}

Remote_Player :: struct {
	// The last two states, for interpolation by the renderer.
	prev, curr: net.Player_State,
}

Pending_Input :: struct {
	tick:  u64,
	input: sim.Input,
}

Client :: struct {
	transport:  net.Transport,
	name:       string,
	status:     Status,
	reason:     string,
	mirror:     world.World,
	// Prediction: a sim over the mirrored world holding only the local
	// player, never loading chunks of its own.
	predict:    sim.Sim,
	me:         sim.Player_Id,
	tick_rate:  u32,
	// The host's tick on the newest state received.
	host_tick:  u64,
	// The client's own input tick counter, sent with every input.
	input_tick: u64,
	pending:    [dynamic]Pending_Input,
	players:    map[sim.Player_Id]Remote_Player,
	// Chunk positions the host told us to drop since the last drain, for
	// the renderer to free their GPU memory.
	removed:    [dynamic]world.Chunk_Pos,
	// Block changes received since the last drain, for the renderer to
	// re-mesh.
	changed:    [dynamic]world.Chunk_Pos,
	events:     [dynamic]net.Event,
	buf:        [dynamic]u8,
	scratch:    [dynamic]u8,
	allocator:  mem.Allocator,
	// Counters for telemetry.
	stats:      Stats,
}

Stats :: struct {
	chunks_received: int,
	bytes_received:  int,
	bytes_sent:      int,
	corrections:     int,
}

// Takes the transport (owned) and the registry (not owned) the mirrored
// world will use. Sends the join on the first tick after connecting.
client_init :: proc(
	c: ^Client,
	registry: ^world.Registry,
	transport: net.Transport,
	name: string,
	sim_config := sim.DEFAULT_CONFIG,
	allocator := context.allocator,
) {
	c.transport = transport
	c.name = name
	c.allocator = allocator
	world.world_init(&c.mirror, registry, {}, {}, allocator)
	config := sim_config
	config.load_chunks = false
	sim.sim_init(&c.predict, &c.mirror, config, allocator)
	c.pending = make([dynamic]Pending_Input, 0, 64, allocator)
	c.players = make(map[sim.Player_Id]Remote_Player, allocator)
	c.removed = make([dynamic]world.Chunk_Pos, 0, 64, allocator)
	c.changed = make([dynamic]world.Chunk_Pos, 0, 64, allocator)
	c.events = make([dynamic]net.Event, 0, 64, allocator)
	c.buf = make([dynamic]u8, 0, 1024, allocator)
	c.scratch = make([dynamic]u8, 0, 4096, allocator)
}

client_destroy :: proc(c: ^Client) {
	net.transport_destroy(c.transport)
	sim.sim_destroy(&c.predict)
	world.world_destroy(&c.mirror)
	delete(c.pending)
	delete(c.players)
	delete(c.removed)
	delete(c.changed)
	delete(c.events)
	delete(c.buf)
	delete(c.scratch)
	delete(c.reason, c.allocator)
}

// The predicted local player, if joined.
local_player :: proc(c: ^Client) -> (sim.Player, bool) {
	if c.status != .Joined {
		return {}, false
	}
	return c.predict.players[c.me]
}

// One client tick: receive, then send this tick's input and predict it.
client_tick :: proc(c: ^Client, input: sim.Input) {
	clear(&c.events)
	net.transport_poll(c.transport, &c.events)
	for e in c.events {
		switch e.kind {
		case .Connected:
			if c.status == .Connecting {
				c.status = .Joining
				send(c, net.Join{protocol = net.PROTOCOL_VERSION, name = c.name})
			}
		case .Disconnected:
			if c.status != .Refused {
				c.status = .Disconnected
			}
		case .Message:
			c.stats.bytes_received += len(e.data)
			handle(c, e)
		}
	}
	if c.status != .Joined {
		return
	}
	c.input_tick += 1
	append(&c.pending, Pending_Input{tick = c.input_tick, input = input})
	send(c, net.Input_Msg{tick = c.input_tick, input = input})
	sim.sim_step_player(&c.predict, c.me, input)
	// Actions are applied locally too so a broken block disappears at
	// once; the host's Block_Changed confirms or corrects it.
	if input.action != .None {
		predict_action(c, input)
	}
}

@(private = "file")
send :: proc(c: ^Client, m: net.Message) {
	clear(&c.buf)
	net.encode(m, &c.buf)
	c.stats.bytes_sent += len(c.buf)
	net.transport_send(c.transport, net.SERVER, net.channel_of(m), c.buf[:])
}

@(private = "file")
handle :: proc(c: ^Client, e: net.Event) {
	m, ok := net.decode(e.data, &c.scratch)
	if !ok {
		return
	}
	switch v in m {
	case net.Welcome:
		if c.status != .Joining {
			return
		}
		c.status = .Joined
		c.me = v.player
		c.tick_rate = v.tick_rate
		c.host_tick = v.tick
		c.predict.config.tick_rate = int(v.tick_rate)
		sim.sim_add_player_at(&c.predict, c.me, {})
	case net.Refused:
		c.status = .Refused
		c.reason = clone_string(v.reason, c.allocator)
	case net.Chunk_Data:
		ch, err := world.chunk_decode(v.chunk, c.allocator)
		if err != .None {
			return
		}
		world.world_insert_chunk(&c.mirror, ch)
		append(&c.changed, ch.pos)
		c.stats.chunks_received += 1
	case net.Unload_Chunk:
		if world.world_chunk(&c.mirror, v.pos) != nil {
			world.world_unload_chunk(&c.mirror, v.pos)
			append(&c.removed, v.pos)
		}
	case net.Block_Changed:
		world.world_set_block(&c.mirror, v.pos, v.id)
		cpos, _, _, _ := world.split_block_pos(v.pos)
		append(&c.changed, cpos)
	case net.Player_State:
		if v.id == c.me {
			reconcile(c, v)
		} else {
			r := c.players[v.id] or_else Remote_Player{prev = v, curr = v}
			r.prev = r.curr
			r.curr = v
			c.players[v.id] = r
		}
		if v.tick > c.host_tick {
			c.host_tick = v.tick
		}
	case net.Player_Left:
		delete_key(&c.players, v.id)
	case net.Join, net.Input_Msg:
	// Client-to-host messages; ignored.
	}
}

// Snaps the local player to the host's state and replays the inputs the
// host hasn't applied yet, so the prediction stays ahead by exactly the
// round trip.
@(private = "file")
reconcile :: proc(c: ^Client, s: net.Player_State) {
	p := &c.predict.players[c.me]
	if p == nil {
		return
	}
	// Drop acknowledged inputs.
	keep := 0
	for pi in c.pending {
		if pi.tick > s.ack {
			c.pending[keep] = pi
			keep += 1
		}
	}
	resize(&c.pending, keep)

	before := p.pos
	p.pos = s.pos
	p.vel = s.vel
	p.on_ground = s.on_ground
	p.flying = s.flying
	for pi in c.pending {
		sim.sim_step_player(&c.predict, c.me, pi.input)
	}
	// Yaw and pitch are the client's own; the host only echoes them.
	after := c.predict.players[c.me].pos
	d := after - before
	if d.x * d.x + d.y * d.y + d.z * d.z > 0.0001 {
		c.stats.corrections += 1
	}
}

@(private = "file")
predict_action :: proc(c: ^Client, input: sim.Input) {
	p, ok := c.predict.players[c.me]
	if !ok {
		return
	}
	hit := sim.raycast(
		&c.mirror,
		sim.eye_pos(&c.predict, &p),
		sim.look_dir(p.yaw, p.pitch),
		c.predict.config.reach,
	)
	if !hit.ok {
		return
	}
	target := hit.pos
	id := world.AIR
	if input.action == .Place {
		target = world.Block_Pos(([3]i32)(hit.pos) + hit.normal)
		id = input.place_block
		if world.world_get_block(&c.mirror, target) != world.AIR {
			return
		}
	}
	if world.world_set_block(&c.mirror, target, id) {
		cpos, _, _, _ := world.split_block_pos(target)
		append(&c.changed, cpos)
	}
}

@(private = "file")
clone_string :: proc(s: string, allocator: mem.Allocator) -> string {
	b := make([]u8, len(s), allocator)
	copy(b, s)
	return string(b)
}
