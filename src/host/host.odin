// The host drives a Sim for whoever is connected: it accepts connections
// from any transport, maps them to players, runs the fixed tick loop and
// sends each player the chunks and state they can see. The dedicated
// server, the singleplayer client and a P2P host are all this with a
// different transport.
package host

import "core:mem"
import "core:strings"

import "../net"
import "../sim"
import "../world"

Config :: struct {
	// Chunks sent around each player, as a radius in chunks.
	view_radius:     i32,
	max_players:     int,
	// New chunks sent to one client per tick, so a join doesn't flood.
	chunks_per_tick: int,
	// Every this many ticks, chunks no player is near are saved and freed.
	evict_every:     u64,
}

DEFAULT_CONFIG :: Config {
	view_radius     = 4,
	max_players     = 16,
	chunks_per_tick = 24,
	evict_every     = 100,
}

Session :: struct {
	conn:   net.Conn_Id,
	player: sim.Player_Id,
	joined: bool,
	name:   string,
	// Chunks this client holds.
	sent:   map[world.Chunk_Pos]bool,
	// The client's tick number on the newest input applied, echoed back so
	// the client can reconcile its prediction.
	ack:    u64,
}

Host :: struct {
	game:      sim.Sim,
	transport: net.Transport,
	config:    Config,
	sessions:  map[net.Conn_Id]^Session,
	by_player: map[sim.Player_Id]net.Conn_Id,
	// Scratch, reused every tick.
	events:    [dynamic]net.Event,
	inputs:    map[sim.Player_Id]sim.Input,
	buf:       [dynamic]u8,
	scratch:   [dynamic]u8,
	wanted:    [dynamic]world.Chunk_Pos,
	allocator: mem.Allocator,
	// Seconds not yet turned into ticks by host_advance.
	accum:     f32,
}

// Takes the world (not owned) and the transport (owned: destroyed with
// the host).
host_init :: proc(
	h: ^Host,
	w: ^world.World,
	transport: net.Transport,
	config := DEFAULT_CONFIG,
	sim_config := sim.DEFAULT_CONFIG,
	allocator := context.allocator,
) {
	sim.sim_init(&h.game, w, sim_config, allocator)
	h.transport = transport
	h.config = config
	h.allocator = allocator
	h.sessions = make(map[net.Conn_Id]^Session, allocator)
	h.by_player = make(map[sim.Player_Id]net.Conn_Id, allocator)
	h.events = make([dynamic]net.Event, 0, 64, allocator)
	h.inputs = make(map[sim.Player_Id]sim.Input, allocator)
	h.buf = make([dynamic]u8, 0, 4096, allocator)
	h.scratch = make([dynamic]u8, 0, 4096, allocator)
	h.wanted = make([dynamic]world.Chunk_Pos, 0, 1024, allocator)
}

host_destroy :: proc(h: ^Host) {
	for _, s in h.sessions {
		session_free(h, s)
	}
	delete(h.sessions)
	delete(h.by_player)
	delete(h.events)
	delete(h.inputs)
	delete(h.buf)
	delete(h.scratch)
	delete(h.wanted)
	net.transport_destroy(h.transport)
	sim.sim_destroy(&h.game)
}

// Runs as many ticks as `dt` seconds call for. The owner calls it from its
// loop with the real elapsed time.
host_advance :: proc(h: ^Host, dt: f32) -> (ticks: int) {
	h.accum += dt
	step := sim.tick_seconds(&h.game)
	// Never try to catch up more than a second; after a long stall, time
	// is dropped rather than simulated in a burst.
	if h.accum > 1 {
		h.accum = 1
	}
	for h.accum >= step {
		h.accum -= step
		host_tick(h)
		ticks += 1
	}
	return
}

// One tick: network in, simulate, network out.
host_tick :: proc(h: ^Host) {
	clear(&h.events)
	net.transport_poll(h.transport, &h.events)
	for e in h.events {
		switch e.kind {
		case .Connected:
			s := new(Session, h.allocator)
			s.conn = e.conn
			s.sent = make(map[world.Chunk_Pos]bool, h.allocator)
			h.sessions[e.conn] = s
		case .Disconnected:
			if s, ok := h.sessions[e.conn]; ok {
				leave(h, s)
			}
		case .Message:
			if s, ok := h.sessions[e.conn]; ok {
				handle(h, s, e)
			}
		}
	}

	clear(&h.game.changes)
	sim.sim_step(&h.game, h.inputs)
	clear(&h.inputs)

	// Block changes go to everyone who holds the chunk.
	for ch in h.game.changes {
		cpos, _, _, _ := world.split_block_pos(ch.pos)
		for _, s in h.sessions {
			if s.joined && cpos in s.sent {
				send(h, s.conn, net.Block_Changed{pos = ch.pos, id = ch.id})
			}
		}
	}

	for _, s in h.sessions {
		if !s.joined {
			continue
		}
		stream_chunks(h, s)
	}
	// Everyone's state to everyone.
	for _, p in h.game.players {
		state := net.Player_State {
			tick      = h.game.tick,
			id        = p.id,
			pos       = p.pos,
			vel       = p.vel,
			yaw       = p.yaw,
			pitch     = p.pitch,
			on_ground = p.on_ground,
			flying    = p.flying,
		}
		for _, s in h.sessions {
			if s.joined {
				state.ack = s.player == p.id ? s.ack : 0
				send(h, s.conn, state)
			}
		}
	}

	if h.config.evict_every > 0 && h.game.tick % h.config.evict_every == 0 {
		evict(h)
	}
}

@(private = "file")
send :: proc(h: ^Host, to: net.Conn_Id, m: net.Message) -> bool {
	clear(&h.buf)
	net.encode(m, &h.buf)
	return net.transport_send(h.transport, to, net.channel_of(m), h.buf[:])
}

@(private = "file")
handle :: proc(h: ^Host, s: ^Session, e: net.Event) {
	m, ok := net.decode(e.data, &h.scratch)
	if !ok {
		return
	}
	switch v in m {
	case net.Join:
		if s.joined {
			return
		}
		if v.protocol != net.PROTOCOL_VERSION {
			send(h, s.conn, net.Refused{reason = "protocol version mismatch"})
			net.transport_disconnect(h.transport, s.conn)
			return
		}
		if len(h.by_player) >= h.config.max_players {
			send(h, s.conn, net.Refused{reason = "server is full"})
			net.transport_disconnect(h.transport, s.conn)
			return
		}
		s.joined = true
		s.name = strings.clone(v.name, h.allocator)
		s.player = sim.sim_add_player(&h.game)
		h.by_player[s.player] = s.conn
		send(
			h,
			s.conn,
			net.Welcome {
				player = s.player,
				tick = h.game.tick,
				tick_rate = u32(h.game.config.tick_rate),
			},
		)
	case net.Input_Msg:
		if s.joined && v.tick >= s.ack {
			h.inputs[s.player] = v.input
			s.ack = v.tick
		}
	case net.Welcome,
	     net.Refused,
	     net.Chunk_Data,
	     net.Unload_Chunk,
	     net.Block_Changed,
	     net.Player_State,
	     net.Player_Left:
	// Host-to-client messages; a client sending them is ignored.
	}
}

@(private = "file")
leave :: proc(h: ^Host, s: ^Session) {
	if s.joined {
		sim.sim_remove_player(&h.game, s.player)
		delete_key(&h.by_player, s.player)
		for _, other in h.sessions {
			if other != s && other.joined {
				send(h, other.conn, net.Player_Left{id = s.player})
			}
		}
	}
	delete_key(&h.sessions, s.conn)
	session_free(h, s)
}

@(private = "file")
session_free :: proc(h: ^Host, s: ^Session) {
	delete(s.sent)
	delete(s.name, h.allocator)
	free(s, h.allocator)
}

// Sends the chunks around the player that the client doesn't have yet,
// nearest first, and tells it to drop the ones it has moved away from.
@(private = "file")
stream_chunks :: proc(h: ^Host, s: ^Session) {
	p, ok := h.game.players[s.player]
	if !ok {
		return
	}
	center := world.chunk_pos_of(p.pos)
	r := h.config.view_radius
	clear(&h.wanted)
	world.chunks_around(center, r, &h.wanted)

	budget := h.config.chunks_per_tick
	for pos in h.wanted {
		if budget == 0 {
			break
		}
		if pos in s.sent {
			continue
		}
		c, _ := world.world_load_chunk(h.game.world, pos)
		clear(&h.scratch)
		world.chunk_encode(c, &h.scratch)
		if send(h, s.conn, net.Chunk_Data{chunk = h.scratch[:]}) {
			s.sent[pos] = true
			budget -= 1
		}
	}
	// One chunk of slack so walking back and forth over a border doesn't
	// resend.
	drop := make([dynamic]world.Chunk_Pos, 0, 16, context.temp_allocator)
	for pos in s.sent {
		d := max(abs(pos.x - center.x), abs(pos.y - center.y), abs(pos.z - center.z))
		if d > r + 1 {
			append(&drop, pos)
		}
	}
	for pos in drop {
		send(h, s.conn, net.Unload_Chunk{pos = pos})
		delete_key(&s.sent, pos)
	}
}

// Saves and frees chunks that no player is near.
@(private = "file")
evict :: proc(h: ^Host) {
	keep := h.config.view_radius + h.game.config.load_radius + 1
	w := h.game.world
	i := 0
	for i < len(w.loaded) {
		pos := w.loaded[i]
		near := false
		for _, p in h.game.players {
			c := world.chunk_pos_of(p.pos)
			if max(abs(pos.x - c.x), abs(pos.y - c.y), abs(pos.z - c.z)) <= keep {
				near = true
				break
			}
		}
		if near {
			i += 1
		} else {
			// Unloading swaps the last position into this index.
			world.world_unload_chunk(w, pos)
		}
	}
}
