package test_net

import "core:fmt"
import "core:testing"

import "../../src/net"
import "../../src/sim"
import "../../src/world"

@(test)
memory_transport_delivers_both_ways :: proc(t: ^testing.T) {
	hub: net.Memory_Hub
	net.memory_hub_init(&hub)
	host := net.memory_hub_transport(&hub)
	defer net.transport_destroy(host)
	client := net.memory_connect(&hub)
	client2 := net.memory_connect(&hub)

	events: [dynamic]net.Event
	defer delete(events)

	// Both sides see the connections.
	net.transport_poll(host, &events)
	testing.expect_value(t, len(events), 2)
	testing.expect_value(t, events[0].kind, net.Event_Kind.Connected)
	testing.expect_value(t, events[0].conn, net.Conn_Id(1))
	testing.expect_value(t, events[1].conn, net.Conn_Id(2))
	clear(&events)
	net.transport_poll(client, &events)
	testing.expect_value(t, len(events), 1)
	testing.expect_value(t, events[0].kind, net.Event_Kind.Connected)
	clear(&events)

	// Client to host, host to one client only.
	testing.expect(t, net.transport_send(client, net.SERVER, .State, {1, 2, 3}))
	net.transport_poll(host, &events)
	testing.expect_value(t, len(events), 1)
	testing.expect_value(t, events[0].conn, net.Conn_Id(1))
	testing.expect_value(t, events[0].channel, net.Channel.State)
	testing.expect_value(t, len(events[0].data), 3)
	testing.expect_value(t, events[0].data[2], u8(3))
	clear(&events)

	net.transport_poll(client2, &events)
	testing.expect_value(t, len(events), 1)
	clear(&events)
	testing.expect(t, net.transport_send(host, 2, .Chunks, {9}))
	net.transport_poll(client, &events)
	testing.expect_value(t, len(events), 0)
	net.transport_poll(client2, &events)
	testing.expect_value(t, len(events), 1)
	testing.expect_value(t, events[0].data[0], u8(9))
	clear(&events)

	// Disconnect shows up on both ends and later sends fail.
	net.transport_disconnect(client2, net.SERVER)
	net.transport_poll(host, &events)
	testing.expect_value(t, len(events), 1)
	testing.expect_value(t, events[0].kind, net.Event_Kind.Disconnected)
	testing.expect_value(t, events[0].conn, net.Conn_Id(2))
	clear(&events)
	net.transport_poll(client2, &events)
	testing.expect_value(t, events[0].kind, net.Event_Kind.Disconnected)
	testing.expect(t, !net.transport_send(host, 2, .Chunks, {9}))
	testing.expect(t, !net.transport_send(client2, net.SERVER, .Chunks, {9}))
	testing.expect(t, !net.transport_send(host, 77, .Chunks, {9}))
}

@(test)
messages_round_trip :: proc(t: ^testing.T) {
	buf: [dynamic]u8
	scratch: [dynamic]u8
	defer delete(buf)
	defer delete(scratch)

	c: world.Chunk
	world.chunk_init(&c, {1, 2, 3})
	defer world.chunk_destroy(&c)
	for i in 0 ..< 300 {
		world.chunk_set(&c, i % 32, i % 5, i % 9, world.Block_Id(1 + i % 3))
	}
	encoded: [dynamic]u8
	defer delete(encoded)
	world.chunk_encode(&c, &encoded)

	messages := []net.Message {
		net.Join{protocol = net.PROTOCOL_VERSION, name = "oliver"},
		net.Welcome{player = 7, tick = 1234567890123, tick_rate = 20},
		net.Refused{reason = "full"},
		net.Input_Msg {
			tick = 99,
			input = {
				move = {0.5, -1, 1},
				yaw = 1.5,
				pitch = -0.25,
				jump = true,
				action = .Place,
				place_block = 5,
			},
		},
		net.Chunk_Data{chunk = encoded[:]},
		net.Unload_Chunk{pos = {-1, 2, -3}},
		net.Block_Changed{pos = {10, -20, 30}, id = 4},
		net.Player_State {
			tick = 5,
			id = 2,
			pos = {1, 2, 3},
			vel = {0, -1, 0},
			yaw = 0.1,
			pitch = 0.2,
			on_ground = true,
			flying = false,
		},
		net.Player_Left{id = 3},
	}
	for m in messages {
		clear(&buf)
		net.encode(m, &buf)
		got, ok := net.decode(buf[:], &scratch)
		testing.expectf(t, ok, "decode failed for %v", m)
		switch v in m {
		case net.Chunk_Data:
			g := got.(net.Chunk_Data)
			testing.expect(t, string(g.chunk) == string(v.chunk), "chunk bytes differ")
			// The wire is smaller than the chunk: the compression did
			// something.
			testing.expect(t, len(buf) < len(v.chunk), "chunk wasn't compressed")
		case net.Join,
		     net.Welcome,
		     net.Refused,
		     net.Input_Msg,
		     net.Unload_Chunk,
		     net.Block_Changed,
		     net.Player_State,
		     net.Player_Left:
			testing.expectf(
				t,
				fmt.tprint(got) == fmt.tprint(m),
				"round trip changed %v into %v",
				m,
				got,
			)
		}
		// Truncations never decode.
		for n in 0 ..< len(buf) {
			if _, tok := net.decode(buf[:n], &scratch); tok {
				testing.expectf(t, false, "truncated %v decoded", m)
			}
		}
	}
	// An unknown tag and an empty message are refused.
	_, ok := net.decode({200}, &scratch)
	testing.expect(t, !ok)
	_, ok = net.decode({}, &scratch)
	testing.expect(t, !ok)
}

@(test)
inputs_are_sanitized :: proc(t: ^testing.T) {
	buf: [dynamic]u8
	scratch: [dynamic]u8
	defer delete(buf)
	defer delete(scratch)
	nan := transmute(f32)u32(0x7FC00000)
	net.encode(net.Input_Msg{input = {move = {9, nan, -4}, yaw = nan}}, &buf)
	got, ok := net.decode(buf[:], &scratch)
	testing.expect(t, ok)
	input := got.(net.Input_Msg).input
	testing.expect_value(t, input.move, [3]f32{1, 0, -1})
	testing.expect_value(t, input.yaw, f32(0))

	// An action byte past the enum is refused.
	clear(&buf)
	net.encode(net.Input_Msg{input = {action = sim.Action.Place}}, &buf)
	buf[len(buf) - 3] = 200
	_, ok = net.decode(buf[:], &scratch)
	testing.expect(t, !ok)
}

@(test)
oversized_chunk_is_refused :: proc(t: ^testing.T) {
	// A hand-built Chunk_Data claiming a huge raw size.
	buf := []u8{5, 0xFF, 0xFF, 0xFF, 0x7F, 1, 0, 0, 0, 0}
	scratch: [dynamic]u8
	defer delete(scratch)
	_, ok := net.decode(buf, &scratch)
	testing.expect(t, !ok)
	testing.expect_value(t, len(scratch), 0)
}
