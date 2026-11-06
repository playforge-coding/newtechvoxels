# Networking

## The transport interface

`net.Transport` is a struct of procedures: `poll` appends the events since the last call (connected, disconnected, message), `send` queues bytes to a connection on a channel, `disconnect`, `destroy`. The host and the client code never see what's underneath.

Implementations:

| Transport | Where | Status |
| --- | --- | --- |
| In-memory hub | `net/transport.odin` | done. A hub on the host side with any number of local clients; singleplayer and the host tests. |
| QUIC over noq | `src/net`, `sdk/noq`, `sdk/noq-ffi` | planned. A Rust C ABI shim over noq; iroh for P2P discovery, hole punching and relays. |

## Channels

What a message needs from the network decides its channel; on QUIC each channel maps to a kind of stream.

| Channel | Guarantee | QUIC mapping (planned) | Messages |
| --- | --- | --- | --- |
| `Control` | ordered, reliable | one bidirectional stream per connection | `Join`, `Welcome`, `Refused`, `Player_Left` |
| `Chunks` | reliable, independent per chunk | one unidirectional stream per chunk transfer, so a lost packet stalls only that chunk | `Chunk_Data`, `Unload_Chunk`, `Block_Changed` |
| `State` | unreliable, newest wins | datagrams (RFC 9221) | `Input_Msg`, `Player_State` |

## Messages

Each message is a tag byte followed by its fields, little-endian, written and read through `src/codec`. `PROTOCOL_VERSION` is bumped whenever a shape changes; a `Join` with another version is refused.

| Message | Direction | Fields |
| --- | --- | --- |
| `Join` | client to host | protocol version, name (at most 32 bytes) |
| `Welcome` | host to client | player id, host tick, tick rate |
| `Refused` | host to client | reason |
| `Input_Msg` | client to host | client input tick, the `sim.Input` |
| `Chunk_Data` | host to client | raw size, LZ4 bytes of the chunk's wire form |
| `Unload_Chunk` | host to client | chunk position |
| `Block_Changed` | host to client | block position, block id |
| `Player_State` | host to client | host tick, acked input tick (own player only), id, position, velocity, yaw, pitch, on ground, flying |
| `Player_Left` | host to client | player id |

Decoding never panics: every length is checked against the remaining input, a chunk's raw size is capped before decompressing, inputs are clamped and NaNs zeroed, unknown action values are refused, and anything truncated or with trailing bytes fails. A message that fails to decode is dropped.

## Prediction

The client numbers its inputs. The host applies the newest input it has for a player each tick and sends that tick number back in the player's own `Player_State`. The client drops acked inputs, snaps the predicted player to the host's state and replays what's left, so it stays ahead by exactly the round trip.
