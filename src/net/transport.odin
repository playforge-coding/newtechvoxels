// The transport interface the host and the client talk through, and the
// in-memory implementation. A transport moves byte messages on channels
// between connections; what the bytes mean is messages.odin's business.
// The QUIC transport implements the same interface over sdk/noq.
package net

import "core:mem"

Conn_Id :: distinct u32

// What a message needs from the network. On QUIC each channel maps to a
// kind of stream; the table lives in docs/networking.md.
Channel :: enum u8 {
	// Ordered and reliable: join, welcome, leave.
	Control,
	// Reliable, one stream per chunk so a lost packet stalls only that
	// chunk.
	Chunks,
	// Unreliable: positions and other state that goes stale.
	State,
}

Event_Kind :: enum u8 {
	Connected,
	Disconnected,
	Message,
}

Event :: struct {
	kind:    Event_Kind,
	conn:    Conn_Id,
	channel: Channel,
	// Valid until the next poll on the same transport.
	data:    []u8,
}

Transport :: struct {
	data:       rawptr,
	// Appends everything that happened since the last poll to `out`.
	poll:       proc(data: rawptr, out: ^[dynamic]Event),
	// Queues a message. The bytes are copied, so the caller may reuse them.
	// False when the connection is gone.
	send:       proc(data: rawptr, to: Conn_Id, channel: Channel, bytes: []u8) -> bool,
	disconnect: proc(data: rawptr, conn: Conn_Id),
	destroy:    proc(data: rawptr),
}

transport_poll :: proc(t: Transport, out: ^[dynamic]Event) {
	t.poll(t.data, out)
}

transport_send :: proc(t: Transport, to: Conn_Id, channel: Channel, bytes: []u8) -> bool {
	return t.send(t.data, to, channel, bytes)
}

transport_disconnect :: proc(t: Transport, conn: Conn_Id) {
	t.disconnect(t.data, conn)
}

transport_destroy :: proc(t: Transport) {
	if t.destroy != nil {
		t.destroy(t.data)
	}
}

// The server-side connection id a client uses for "the server".
SERVER :: Conn_Id(0)

// An in-memory transport: a hub on the host side with any number of local
// clients, each a Transport of its own. Everything stays in the process and
// on one thread; singleplayer and the host tests use it.
Memory_Hub :: struct {
	links:     map[Conn_Id]^Memory_Link,
	next_conn: u32,
	// Events for the host side.
	inbox:     [dynamic]Event,
	// Buffers handed out by the last poll, freed on the next one.
	handed:    [dynamic][]u8,
	allocator: mem.Allocator,
}

Memory_Link :: struct {
	hub:    ^Memory_Hub,
	conn:   Conn_Id,
	inbox:  [dynamic]Event,
	handed: [dynamic][]u8,
	open:   bool,
}

memory_hub_init :: proc(h: ^Memory_Hub, allocator := context.allocator) {
	h.links = make(map[Conn_Id]^Memory_Link, allocator)
	h.inbox = make([dynamic]Event, 0, 64, allocator)
	h.handed = make([dynamic][]u8, 0, 64, allocator)
	h.allocator = allocator
	h.next_conn = 1
}

// The host side of the hub as a transport.
memory_hub_transport :: proc(h: ^Memory_Hub) -> Transport {
	return Transport {
		data = h,
		poll = hub_poll,
		send = hub_send,
		disconnect = hub_disconnect,
		destroy = hub_destroy,
	}
}

// Connects a new local client. Both sides get a Connected event on their
// next poll. The returned transport is owned by the hub and dies with it,
// or with a disconnect from either side.
memory_connect :: proc(h: ^Memory_Hub) -> Transport {
	link := new(Memory_Link, h.allocator)
	link.hub = h
	link.conn = Conn_Id(h.next_conn)
	h.next_conn += 1
	link.inbox = make([dynamic]Event, 0, 64, h.allocator)
	link.handed = make([dynamic][]u8, 0, 64, h.allocator)
	link.open = true
	h.links[link.conn] = link
	append(&h.inbox, Event{kind = .Connected, conn = link.conn})
	append(&link.inbox, Event{kind = .Connected, conn = SERVER})
	return Transport {
		data = link,
		poll = link_poll,
		send = link_send,
		disconnect = link_disconnect,
		destroy = link_destroy,
	}
}

@(private = "file")
drain :: proc(
	inbox: ^[dynamic]Event,
	handed: ^[dynamic][]u8,
	out: ^[dynamic]Event,
	allocator: mem.Allocator,
) {
	for b in handed {
		delete(b, allocator)
	}
	clear(handed)
	for e in inbox {
		append(out, e)
		if e.data != nil {
			append(handed, e.data)
		}
	}
	clear(inbox)
}

@(private = "file")
deliver :: proc(
	inbox: ^[dynamic]Event,
	from: Conn_Id,
	channel: Channel,
	bytes: []u8,
	allocator: mem.Allocator,
) {
	copied := make([]u8, len(bytes), allocator)
	copy(copied, bytes)
	append(inbox, Event{kind = .Message, conn = from, channel = channel, data = copied})
}

@(private = "file")
hub_poll :: proc(data: rawptr, out: ^[dynamic]Event) {
	h := (^Memory_Hub)(data)
	drain(&h.inbox, &h.handed, out, h.allocator)
}

@(private = "file")
hub_send :: proc(data: rawptr, to: Conn_Id, channel: Channel, bytes: []u8) -> bool {
	h := (^Memory_Hub)(data)
	link, ok := h.links[to]
	if !ok || !link.open {
		return false
	}
	deliver(&link.inbox, SERVER, channel, bytes, h.allocator)
	return true
}

@(private = "file")
close_link :: proc(link: ^Memory_Link) {
	if !link.open {
		return
	}
	link.open = false
	h := link.hub
	append(&h.inbox, Event{kind = .Disconnected, conn = link.conn})
	append(&link.inbox, Event{kind = .Disconnected, conn = SERVER})
}

@(private = "file")
hub_disconnect :: proc(data: rawptr, conn: Conn_Id) {
	h := (^Memory_Hub)(data)
	if link, ok := h.links[conn]; ok {
		close_link(link)
	}
}

@(private = "file")
free_link :: proc(link: ^Memory_Link) {
	alloc := link.hub.allocator
	for e in link.inbox {
		delete(e.data, alloc)
	}
	for b in link.handed {
		delete(b, alloc)
	}
	delete(link.inbox)
	delete(link.handed)
	free(link, alloc)
}

@(private = "file")
hub_destroy :: proc(data: rawptr) {
	h := (^Memory_Hub)(data)
	for _, link in h.links {
		free_link(link)
	}
	delete(h.links)
	for e in h.inbox {
		delete(e.data, h.allocator)
	}
	for b in h.handed {
		delete(b, h.allocator)
	}
	delete(h.inbox)
	delete(h.handed)
}

@(private = "file")
link_poll :: proc(data: rawptr, out: ^[dynamic]Event) {
	link := (^Memory_Link)(data)
	drain(&link.inbox, &link.handed, out, link.hub.allocator)
}

@(private = "file")
link_send :: proc(data: rawptr, to: Conn_Id, channel: Channel, bytes: []u8) -> bool {
	link := (^Memory_Link)(data)
	if !link.open || to != SERVER {
		return false
	}
	deliver(&link.hub.inbox, link.conn, channel, bytes, link.hub.allocator)
	return true
}

@(private = "file")
link_disconnect :: proc(data: rawptr, conn: Conn_Id) {
	link := (^Memory_Link)(data)
	close_link(link)
}

// The hub owns the link's memory, so a client destroying its transport
// only closes the connection.
@(private = "file")
link_destroy :: proc(data: rawptr) {
	link := (^Memory_Link)(data)
	close_link(link)
}
