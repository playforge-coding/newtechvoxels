// The messages between client and host, and their byte form. Each message
// is a tag byte followed by its fields. Decoding checks every length and
// never panics on bad input; a message that fails to decode is dropped by
// the receiver.
package net

import "core:c"

import lz4 "vendor:compress/lz4"

import "../codec"
import "../sim"
import "../world"

// Bumped whenever a message changes shape. A join with another version is
// refused.
PROTOCOL_VERSION :: 1

MAX_NAME :: 32
// An encoded chunk is at most this big (16-bit indices plus the palette);
// anything claiming more is refused before allocating.
MAX_CHUNK_BYTES :: world.CHUNK_VOLUME * 2 + world.MAX_PALETTE * 2 + 64

Message :: union {
	Join,
	Welcome,
	Refused,
	Input_Msg,
	Chunk_Data,
	Unload_Chunk,
	Block_Changed,
	Player_State,
	Player_Left,
}

// Client to host, first message on Control.
Join :: struct {
	protocol: u32,
	name:     string,
}

// Host to client, answering Join.
Welcome :: struct {
	player:    sim.Player_Id,
	tick:      u64,
	tick_rate: u32,
}

Refused :: struct {
	reason: string,
}

// Client to host, every tick, on State.
Input_Msg :: struct {
	tick:  u64,
	input: sim.Input,
}

// Host to client on Chunks: a chunk in its wire form, LZ4-compressed.
Chunk_Data :: struct {
	// The decoded chunk bytes (world.chunk_encode's output); the wire holds
	// them compressed. Points into a decoder-owned buffer, so copy or decode
	// before the next message.
	chunk: []u8,
}

Unload_Chunk :: struct {
	pos: world.Chunk_Pos,
}

Block_Changed :: struct {
	pos: world.Block_Pos,
	id:  world.Block_Id,
}

// Host to client on State, every tick for every visible player.
Player_State :: struct {
	tick:       u64,
	// For the receiving player's own state: the tick of its newest input
	// the host has applied. 0 for other players.
	ack:        u64,
	id:         sim.Player_Id,
	pos, vel:   [3]f32,
	yaw, pitch: f32,
	on_ground:  bool,
	flying:     bool,
}

Player_Left :: struct {
	id: sim.Player_Id,
}

@(private = "file")
Tag :: enum u8 {
	Join = 1,
	Welcome,
	Refused,
	Input,
	Chunk_Data,
	Unload_Chunk,
	Block_Changed,
	Player_State,
	Player_Left,
}

// The channel a message belongs on.
channel_of :: proc(m: Message) -> Channel {
	switch _ in m {
	case Join, Welcome, Refused, Player_Left:
		return .Control
	case Chunk_Data, Unload_Chunk, Block_Changed:
		return .Chunks
	case Input_Msg, Player_State:
		return .State
	}
	return .Control
}

// Appends the wire form of a message to `buf`.
encode :: proc(m: Message, buf: ^[dynamic]u8) {
	w := codec.writer(buf)
	switch v in m {
	case Join:
		codec.put_u8(w, u8(Tag.Join))
		codec.put_u32(w, v.protocol)
		codec.put_string(w, v.name)
	case Welcome:
		codec.put_u8(w, u8(Tag.Welcome))
		codec.put_u32(w, u32(v.player))
		codec.put_u64(w, v.tick)
		codec.put_u32(w, v.tick_rate)
	case Refused:
		codec.put_u8(w, u8(Tag.Refused))
		codec.put_string(w, v.reason)
	case Input_Msg:
		codec.put_u8(w, u8(Tag.Input))
		codec.put_u64(w, v.tick)
		put_input(w, v.input)
	case Chunk_Data:
		codec.put_u8(w, u8(Tag.Chunk_Data))
		put_compressed(w, v.chunk)
	case Unload_Chunk:
		codec.put_u8(w, u8(Tag.Unload_Chunk))
		put_i32x3(w, ([3]i32)(v.pos))
	case Block_Changed:
		codec.put_u8(w, u8(Tag.Block_Changed))
		put_i32x3(w, ([3]i32)(v.pos))
		codec.put_u16(w, u16(v.id))
	case Player_State:
		codec.put_u8(w, u8(Tag.Player_State))
		codec.put_u64(w, v.tick)
		codec.put_u64(w, v.ack)
		codec.put_u32(w, u32(v.id))
		put_f32x3(w, v.pos)
		put_f32x3(w, v.vel)
		codec.put_f32(w, v.yaw)
		codec.put_f32(w, v.pitch)
		codec.put_bool(w, v.on_ground)
		codec.put_bool(w, v.flying)
	case Player_Left:
		codec.put_u8(w, u8(Tag.Player_Left))
		codec.put_u32(w, u32(v.id))
	}
}

// Reads one message. Slices in the result point into `data` or into
// `scratch`, which the caller owns and the decoder grows as needed (the
// decompressed chunk lives there).
decode :: proc(data: []u8, scratch: ^[dynamic]u8) -> (m: Message, ok: bool) {
	r := codec.reader(data)
	tag, _ := codec.get_u8(&r)
	if r.bad {
		return nil, false
	}
	switch Tag(tag) {
	case .Join:
		protocol, _ := codec.get_u32(&r)
		name, _ := codec.get_string(&r, MAX_NAME)
		m = Join {
			protocol = protocol,
			name     = name,
		}
	case .Welcome:
		player, _ := codec.get_u32(&r)
		tick, _ := codec.get_u64(&r)
		rate, _ := codec.get_u32(&r)
		m = Welcome {
			player    = sim.Player_Id(player),
			tick      = tick,
			tick_rate = rate,
		}
	case .Refused:
		reason, _ := codec.get_string(&r, 256)
		m = Refused {
			reason = reason,
		}
	case .Input:
		tick, _ := codec.get_u64(&r)
		input := get_input(&r)
		m = Input_Msg {
			tick  = tick,
			input = input,
		}
	case .Chunk_Data:
		chunk, cok := get_compressed(&r, scratch)
		if !cok {
			return nil, false
		}
		m = Chunk_Data {
			chunk = chunk,
		}
	case .Unload_Chunk:
		m = Unload_Chunk {
			pos = world.Chunk_Pos(get_i32x3(&r)),
		}
	case .Block_Changed:
		pos := get_i32x3(&r)
		id, _ := codec.get_u16(&r)
		m = Block_Changed {
			pos = world.Block_Pos(pos),
			id  = world.Block_Id(id),
		}
	case .Player_State:
		s: Player_State
		s.tick, _ = codec.get_u64(&r)
		s.ack, _ = codec.get_u64(&r)
		id, _ := codec.get_u32(&r)
		s.id = sim.Player_Id(id)
		s.pos = get_f32x3(&r)
		s.vel = get_f32x3(&r)
		s.yaw, _ = codec.get_f32(&r)
		s.pitch, _ = codec.get_f32(&r)
		s.on_ground, _ = codec.get_bool(&r)
		s.flying, _ = codec.get_bool(&r)
		m = s
	case .Player_Left:
		id, _ := codec.get_u32(&r)
		m = Player_Left {
			id = sim.Player_Id(id),
		}
	case:
		return nil, false
	}
	if !codec.finished(&r) {
		return nil, false
	}
	return m, true
}

@(private = "file")
put_input :: proc(w: codec.Writer, i: sim.Input) {
	put_f32x3(w, i.move)
	codec.put_f32(w, i.yaw)
	codec.put_f32(w, i.pitch)
	codec.put_bool(w, i.jump)
	codec.put_bool(w, i.flying)
	codec.put_u8(w, u8(i.action))
	codec.put_u16(w, u16(i.place_block))
}

@(private = "file")
get_input :: proc(r: ^codec.Reader) -> (i: sim.Input) {
	i.move = get_f32x3(r)
	i.yaw, _ = codec.get_f32(r)
	i.pitch, _ = codec.get_f32(r)
	i.jump, _ = codec.get_bool(r)
	i.flying, _ = codec.get_bool(r)
	action, _ := codec.get_u8(r)
	if action > u8(max(sim.Action)) {
		r.bad = true
	}
	i.action = sim.Action(action)
	block, _ := codec.get_u16(r)
	i.place_block = world.Block_Id(block)
	// Inputs come from clients; keep them in range so a bad one can't send
	// the sim's floats off the rails.
	for k in 0 ..< 3 {
		i.move[k] = clamp(sane(i.move[k]), -1, 1)
	}
	i.yaw = sane(i.yaw)
	i.pitch = sane(i.pitch)
	return
}

// Replaces NaN and infinity with 0.
@(private = "file")
sane :: proc "contextless" (v: f32) -> f32 {
	return v == v && v > -1e30 && v < 1e30 ? v : 0
}

@(private = "file")
put_i32x3 :: proc(w: codec.Writer, v: [3]i32) {
	for x in v {
		codec.put_i32(w, x)
	}
}

@(private = "file")
get_i32x3 :: proc(r: ^codec.Reader) -> (v: [3]i32) {
	for k in 0 ..< 3 {
		v[k], _ = codec.get_i32(r)
	}
	return
}

@(private = "file")
put_f32x3 :: proc(w: codec.Writer, v: [3]f32) {
	for x in v {
		codec.put_f32(w, x)
	}
}

@(private = "file")
get_f32x3 :: proc(r: ^codec.Reader) -> (v: [3]f32) {
	for k in 0 ..< 3 {
		v[k], _ = codec.get_f32(r)
	}
	return
}

// LZ4 for the wire: the raw size, then the compressed bytes.
@(private = "file")
put_compressed :: proc(w: codec.Writer, raw: []u8) {
	bound := int(lz4.compressBound(c.int(len(raw))))
	tmp := make([]u8, bound, context.temp_allocator)
	n := lz4.compress_default(raw_data(raw), raw_data(tmp), c.int(len(raw)), c.int(bound))
	codec.put_u32(w, u32(len(raw)))
	codec.put_bytes(w, tmp[:n])
}

// Decompresses into `scratch`, refusing sizes over MAX_CHUNK_BYTES, so a
// small packet can't expand into gigabytes.
@(private = "file")
get_compressed :: proc(r: ^codec.Reader, scratch: ^[dynamic]u8) -> ([]u8, bool) {
	raw_len, _ := codec.get_u32(r)
	if r.bad || int(raw_len) > MAX_CHUNK_BYTES {
		return nil, false
	}
	packed, ok := codec.get_bytes(r, MAX_CHUNK_BYTES)
	if !ok {
		return nil, false
	}
	resize(scratch, int(raw_len))
	if raw_len == 0 {
		return scratch[:0], len(packed) == 0
	}
	n := lz4.decompress_safe(
		raw_data(packed),
		raw_data(scratch^),
		c.int(len(packed)),
		c.int(raw_len),
	)
	if int(n) != int(raw_len) {
		return nil, false
	}
	return scratch[:raw_len], true
}
