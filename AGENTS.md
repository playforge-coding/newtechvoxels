# newtechvoxels

## Overview

New Tech Voxels is an experimental 3D voxel game aiming to harness the strengths of modern software. It is also a research project: it asks whether a modern, data-oriented stack is actually worth it, measured against early Minecraft (Alpha through Beta 1.7.3) on the same machine with matched settings. Every major subsystem is there to test a claim, so it has to be measurable (see Telemetry and benchmarks).

Nothing is built yet. This file describes the plan; sections marked "planned" are decisions, not code. When a planned part lands, rewrite its description to say what the code does and drop the marker.

The game is open source, in one monorepo, under two licenses (see Licensing).

### The stack

| Area | Choice | How it's reached | Status |
| --- | --- | --- | --- |
| Language | Odin | toolchain pinned in `mise.toml` | planned |
| Windowing and input | SDL3 | `vendor:sdl3` | planned |
| Rendering and compute | WebGPU through wgpu-native | `vendor:wgpu`, surface from `vendor:wgpu/sdl3glue` | planned |
| Shaders | hand-written WGSL in `shaders/` | loaded with `wgpu.DeviceCreateShaderModule` | planned |
| Network transport | QUIC through noq (n0's fork of Quinn), with iroh for P2P discovery, hole punching and relays | our own Rust C ABI shim, bound from Odin | planned |
| Network compression | LZ4 | `vendor:compress/lz4` | planned |
| World storage compression | Zstandard | our own Odin bindings to libzstd (Odin's vendor collection has none) | planned |
| CPU math | SIMD | `core:simd` | planned |
| Physics (selective) | Box3D | `vendor:box3d` | later |
| Voice chat (toggleable) | Opus over MoQ (iroh-live) | bindings | later |
| Webcam sharing (toggleable) | AV1 (dav1d to decode, an encoder to be picked), AV2 as an experiment | bindings | later |
| Modding | undecided: WebAssembly (leading), Lua or JavaScript | see Modding | later |
| Shader generation | unipute (our Rust shaders-as-code library, `../unipute`) | Odin bindings | later, once unipute is mature |

Choices that are still open: the modding runtime, the AV1 encoder, and whether noq is used directly or through iroh's endpoint API. Don't settle one of them as a side effect of other work. Raise it, and record the decision here when it's made.

### Architecture (planned)

```mermaid
flowchart TD
  sdl[SDL3: window, input, audio devices] --> client
  client[client: input, prediction, UI] --> render
  client --> netc[net: client side]
  render[render: wgpu device, passes] --> mesh[GPU meshing compute pass]
  mesh --> indirect[indirect draws]
  client --> netc[net: transport interface]
  host[host: sessions, players, tick loop] --> netc
  netc -.implemented by.-> mem[in-memory transport]
  netc -.implemented by.-> quic[QUIC transport]
  netc -.implemented by.-> p2p[P2P transport]
  quic -.-> shim[sdk/noq-ffi: Rust C ABI shim over noq and iroh]
  p2p -.-> shim
  dedicated[server executable] --> host
  client -->|singleplayer or P2P host| host
  host --> sim[sim: authoritative game logic]
  client -->|prediction| sim
  sim --> world[world: chunks, palettes, generation]
  world --> store[storage interface]
  store -.implemented by.-> region[region files, Zstandard]
```

- The game logic is authoritative and lives in one place, `src/sim/`. It is a library, not a server: it holds the game state, takes player inputs for a tick, advances the world, and returns what changed. It knows nothing about sockets, threads, windows, clocks or how it is hosted, so the same code runs in every mode.
- `src/host/` drives the simulation for remote or local players: it accepts connections from any transport, maps them to players, runs the fixed tick loop, and sends each player the changes they can see. Every hosting mode is the same host with different parts plugged in:
  - Dedicated server: the `src/server/` executable runs a host with the QUIC transport and no client.
  - Singleplayer: the client runs a host in the same process and connects to it over the in-memory transport.
  - P2P: one peer's client runs a host with the P2P transport, and the other peers connect to it like they would to a dedicated server.

  Adding a hosting mode means adding a transport or a small `main`, never changing `sim` or `host`.
- The client runs the same `sim` code for prediction (moving the local player and showing block edits before the host confirms them) and reconciles with what the host sends. It never has its own copy of a game rule.
- The simulation runs at a fixed tick rate, decoupled from rendering. The renderer interpolates between the last two ticks.
- Chunks are cubic, 32 by 32 by 32 voxels, so world height isn't a hard limit. Block ids are a global `u16`, and each chunk stores a palette plus packed indices sized to the palette. The same packed form goes to the GPU, across the network (under LZ4) and to disk (under Zstandard), so a chunk is never re-encoded between them. Benchmark scenes that compare with Minecraft limit world height to match the version under test.
- Meshing runs on the GPU: chunk data is uploaded raw, a compute pass culls faces and writes vertices and indirect draw arguments, and the CPU never reads geometry back. A CPU mesher using `core:simd` exists as the reference and fallback, and tests compare the two.
- Network traffic is split by what loss means for it: ordered reliable streams for control (join, leave, handshakes), a stream per chunk transfer so one lost packet doesn't stall the others, and unreliable datagrams for state that goes stale (positions, later voice and video). Channel assignments live in one table in `src/net/` and in `docs/networking.md`.

### Layout (planned)

The repository is a monorepo. Odin packages are directories, and the `sdk` collection is passed with `-collection:sdk=sdk`.

- `src/client/`: the game executable. SDL3 window and event loop, input, prediction, UI. Runs a host in the same process for singleplayer and P2P hosting.
- `src/server/`: the dedicated, headless server executable, a small `main` around `src/host/`. It must build and run without SDL3 or a GPU.
- `src/sim/`: the authoritative game logic as a library (see Architecture). Imports only `src/world/`, `core:` and the `vendor:` libraries the rules need (Box3D, later).
- `src/host/`: sessions, players, the tick loop and change broadcasting over the transport interface. Shared by every hosting mode.
- `src/world/`: chunks, palettes, block registry, world generation, the storage interface and its region file implementation. No rendering or networking imports.
- `src/render/`: the wgpu device, surface, pipelines, GPU meshing, the CPU reference mesher.
- `src/net/`: the transport interface, the in-memory transport, the QUIC transport over `sdk/noq`, message encoding.
- `src/telemetry/`: frame and tick timing, counters, CSV output.
- `shaders/`: WGSL sources, one file per pipeline, embedded with `#load` so a build has no loose files.
- `sdk/`: BSD-3-Clause code: the modding API, and bindings meant for reuse outside the game (`sdk/zstd/`, `sdk/noq/` for the Odin side, `sdk/noq-ffi/` for the Rust shim crate).
- `bench/`: benchmark scenes, scripts that run them, the matching Minecraft setups and `docs/benchmarks.md` notes.
- `tests/`: Odin tests, one package per area.
- `tools/`: helper programs (network condition setups with `tc netem`, plotting the telemetry CSVs).

### Reusability and flexibility

The hosting modes above are one case of a rule for the whole codebase: write each piece so it can be reused somewhere else and swapped for another implementation without changing its callers.

- Dependencies point one way: `world` at the bottom, then `sim`, then `host` and `render`, then the executables. A lower package never imports a higher one, and nothing below the executables imports SDL3. If a lower package needs something from above, pass it in (a procedure, an interface, or data) instead of importing it.
- No global state in the libraries. Every procedure gets its state, its allocator and its configuration as parameters or through `context`. Several worlds, simulations and hosts must be able to exist in one process at once (tests, a singleplayer client that also hosts, portals to another dimension, a benchmark that runs many headless clients).
- Seams where implementations differ are explicit interfaces, defined next to their consumer: the transport, storage, the world generator, the mesher (GPU and CPU), later the audio and video codecs and the mod runtime. A runtime choice is a struct of procedures plus a `rawptr` for the implementation's data. A compile-time choice uses parametric polymorphism or `when`. Each interface has at least one in-memory or fake implementation for tests.
- Keep data and the code that moves it apart. Game state, messages and chunk formats are plain structs with no handles in them, so they can be copied, saved, sent, replayed and compared. Encoding to bytes lives in one place per format.
- Behavior that someone may want to change is configuration, not a constant buried in code: tick rate, view distance, network limits, generation parameters. Configuration is a struct passed in by the executable, with defaults in one place. Things that the data formats depend on (chunk size, the block id width) stay compile-time constants, each defined once.
- Game content is data where it can be. Blocks, items and their properties are registered through the same registry the modding API will use, so built-in content and mods go through one path.
- Flexibility is not speculation. Don't add an interface, option or hook that nothing uses yet and that isn't planned in this file; add it when the second implementation or the planned feature arrives. Keeping packages small and free of globals is what makes that later step cheap.

## Licensing

- Everything is AGPL-3.0-or-later unless a directory says otherwise. The root `LICENSE` holds it.
- `sdk/` is BSD-3-Clause, with its own `sdk/LICENSE`, so mods and the reusable bindings can be under any license.
- Code under `sdk/` must not import anything outside `sdk/` or `vendor:`/`core:`. Moving AGPL code into `sdk/` relicenses it, so only do it when the user asks.
- Every new dependency must be compatible with both: permissive (MIT, BSD, Apache-2.0, zlib, ISC) for anything `sdk/` links, and nothing that is incompatible with AGPL anywhere. Check the license before adding it and say what it is in the commit.

## Originality

This is an original game in the voxel sandbox genre, not a copy of Minecraft. Minecraft is the benchmark baseline and a source of player complaints to address (r/minecraftsuggestions and the official feedback site), nothing else.

- No Minecraft code, decompiled or deobfuscated sources, mappings, textures, sounds, models, names of its blocks, items or mobs, or its UI layout. Don't read decompiled Minecraft code to copy a mechanic, even for benchmark parity; describe the behavior from observation instead.
- Art, audio and fonts are made for the project or come from sources whose license allows redistribution under the project's terms. Record the source and license of every third-party asset in `assets/CREDITS.md`.
- When a feature comes from a community suggestion, link the suggestion in the issue or doc that describes it.

## Building and testing (planned)

- Odin, Rust and helper tools come from mise. `mise.toml` pins Odin to a monthly release tag (not a nightly) and ols (which ships `odinfmt`). Rust's version is pinned in `sdk/noq-ffi/rust-toolchain.toml`. Do not install Odin another way alongside mise.
- Commands live in a `justfile` at the root: `just build`, `just run`, `just server`, `just test`, `just check`, `just fmt`, `just bench`. Add a recipe only for a step those don't cover. Compiler settings that apply to the whole project (collections, vet flags) live in the justfile's shared variables, not repeated per recipe.
- `just build` builds the Rust shim first (`cargo build --release`, which also writes its C header with cbindgen), then the Odin executables.
- Tests use `core:testing` and run with `odin test`. Add a test with every behavior change. Areas that need tests from the start: palette packing round trips, chunk codecs (including truncated and malicious input), world generation determinism (a seed gives the same chunk bytes on every platform, checked against committed hashes), GPU versus CPU mesher agreement, the message encoding, and the simulation driven headless by scripted inputs (the same inputs give the same state, and a client predicting with `sim` ends up where the host does). Host tests use the in-memory transport, so they cover every hosting mode without a network.
- GPU tests need an adapter. They skip with a printed message when none is found, so `just test` runs on headless CI; CI runs them where a software adapter (lavapipe or WARP) is available.
- Validate every WGSL file in `shaders/` with naga (`naga-cli`) in `just check` and in CI, so a shader error fails before the game starts.
- `odin check` gives fast type errors without a full build. Code for another platform can be checked from any machine with `-target:windows_amd64`, `-target:darwin_arm64` and so on. Do this when touching platform code you can't run.
- CI runs `just check` and `just test` on Linux, macOS and Windows, builds both executables there, and checks formatting. It skips changes that only touch `docs/`, Markdown files or `zensical.toml`.

## Telemetry and benchmarks

The research question needs numbers, so measurement is a feature, not an afterthought.

- Every subsystem reports its time per frame or tick through `src/telemetry/`. `--bench <scene>` runs a scripted scene (flying through new terrain, mass block edits, many explosions, joining a loaded server, packet loss) and writes a CSV of frame times, tick times, memory, chunk throughput and network bytes.
- Report frame times as percentiles (average, 1% low, 0.1% low), not averages alone.
- A benchmark is only valid with its setup written down: hardware, OS, driver, the build flags, and for the baseline the exact Minecraft version, its settings and JVM flags. These go in `docs/benchmarks.md` next to the results.
- Comparisons must be fair. Match view distance, world height and lighting work to the baseline, and say in the results where a difference can't be matched.
- Don't tune a benchmark scene to flatter the stack. If a result is bad, record it; a bad result is still a research result.

## Odin rules

- Format with `odinfmt` (from ols), configured by `odinfmt.json` at the root. CI rejects unformatted code.
- Build and check with `-vet -strict-style -warnings-as-errors`. Unused imports and variables are errors, not noise.
- Naming follows Odin's core library: `snake_case` for procedures, variables and packages, `Ada_Case` for types, `SCREAMING_SNAKE_CASE` for constants. Foreign procedures keep the C name through `@(link_name)` while the Odin name follows Odin style.
- Memory: say where every allocation goes. Per-frame scratch goes in `context.temp_allocator`, freed once per frame. Long-lived data uses explicit arenas or pools owned by the system that uses it. No allocation inside per-voxel or per-vertex loops. Prefer fixed-capacity arrays and `#soa` where the data is hot.
- Errors are values: procedures that can fail return an error enum or union as the last value, and callers handle it with `or_return` or explicitly. Bytes from the network, from disk or from a mod never cause a panic, an out-of-bounds read or an unbounded allocation. Every length and count from outside is checked against the remaining input and a hard limit before anything is allocated for it, and decompression takes a maximum output size (a small packet must not expand into gigabytes).
- Use `distinct` types for things that shouldn't mix: block ids, chunk coordinates, world coordinates, entity ids.
- Reach for `core:` and `vendor:` before adding a dependency.

## FFI rules

- Bind only what the code calls. Bindings live in their own package under `sdk/` with `foreign import`, and a thin Odin layer on top that takes slices and strings instead of pointer and length pairs.
- Native handles are owned by one Odin struct with a matching `destroy` procedure. Don't copy owning structs.
- The Rust shim (`sdk/noq-ffi/`) exposes a C ABI only: `extern "C"` functions, `#[repr(C)]` types, opaque handles, cbindgen for the header. A panic must never cross the boundary: wrap every exported function so a panic becomes an error code.
- Rust never calls into Odin from its own threads. The shim runs its async runtime on its own threads and hands events (new connection, stream data, datagram) to Odin through a queue that the game drains once per tick. Buffers passed to the shim are copied or stay valid until the shim says it's done with them; the binding documents which.
- Rust code is formatted with `rustfmt`, linted with `cargo clippy -- -D warnings`, and uses edition 2024.

## Shaders

- Hand-written WGSL for now, one file per pipeline in `shaders/`. Keep bind group layouts declared next to the pipeline that uses them in `src/render/`, and keep the WGSL `@group`/`@binding` numbers and the Odin layout in step; a test or startup check compares them.
- Shared structs used by both Odin and WGSL (chunk headers, vertex formats, indirect arguments) are defined once in Odin with `#packed` or explicit alignment, and the WGSL copy says which Odin type it mirrors. Size asserts (`#assert(size_of(T) == N)`) guard the layout.
- unipute will replace the hand-written compute kernels once it's mature. Keep kernels small and plain (no clever preprocessing of WGSL text) so that move is mechanical.

## Modding (later)

Mods will be sandboxed, and the API lives in `sdk/` under BSD-3-Clause. WebAssembly is the leading option because it is sandboxed and language-agnostic (JavaScript through Javy, Rust, Zig, Odin). Lua and JavaScript are still being considered. Whatever runtime is picked, the API is data-oriented: mods record batches of changes into buffers that the engine applies in bulk, never a host call per block. Don't add mod hooks before the runtime is chosen.

## Current phase: the MVP

The MVP is a single-player-capable, multiplayer-ready voxel world with the benchmark harness, and nothing more. In scope: the SDL3 window and wgpu renderer, cubic chunks with palettes, deterministic terrain generation, GPU meshing with the CPU reference, breaking and placing blocks, a first-person player with collision, `sim` and `host` with singleplayer over the in-memory transport, Zstandard region files, the QUIC transport for a dedicated server with LZ4 chunk streams, and the telemetry plus the first benchmark scenes. Out of scope until the MVP is done: P2P, voice, video, physics, modding, unipute, lighting beyond a simple directional light with ambient occlusion. If a task drifts into an out-of-scope area, stop and ask.

## Searching the codebase

Use fast, modern tools instead of the slow defaults:

- [`rg`](https://github.com/BurntSushi/ripgrep) (ripgrep) for text search, not `grep`. It respects `.gitignore` for you.
- [`fd`](https://github.com/sharkdp/fd) for finding files by name, not `find`.
- [`ast-grep`](https://ast-grep.github.io) for structural searches and rewrites in languages it supports (Rust, not Odin or WGSL; use `rg` for those). Call it as `ast-grep`. The `sg` alias is deprecated, so don't use it.
- `jq` for reading and querying JSON.

If your harness has dedicated search or file tools that already wrap these, those are fine too.

## Docs (IMPORTANT!!!)

Always update the docs if necessary when changing or adding code. If the docs already contain outdated information, expand your scope to cover that info too. That includes this file: when the layout, build, stack or tooling change, update the overview and the build section here.

The docs will be a [Zensical](https://zensical.org) site: `zensical.toml` at the root, pages in `docs/`. `uvx zensical build --strict` checks it and writes `site/` (ignored by git), and `uvx zensical serve` previews it. Planned pages:

- `index.md`: what the game is and the research question.
- `getting-started.md`: installing the toolchain, building, running the client and the server.
- `architecture.md`: the subsystems, threads, and data flow; the chunk format and why it's shared between GPU, network and disk.
- `networking.md`: the transport interface, the channel table, message formats, and the P2P plan.
- `rendering.md`: the passes, GPU meshing, bind group layouts.
- `benchmarks.md`: method, setups and results.
- `modding.md`: once a runtime is chosen.
- `roadmap.md`: what's done and what's planned.

Compile the examples you put in the docs before committing them.

When a roadmap item is finished, check it off (`- [x]`) where it is. DO NOT move it into an earlier section like "Done: the MVP". The roadmap shows how each goal is progressing, so finished items stay with the section they belong to.

The README is only an entry point: what the game is, building, and links into the docs. Put details in the docs, not the README.

## Diagrams as Mermaid, not ASCII art

Never draw a flow, pipeline or architecture picture out of characters in a code block. Make a Mermaid diagram instead.

## Outdated packages

PLEASE, PLEASE do not use a package that is old or deprecated. EVEN IF IT IS "INDUSTRY STANDARD" THAT DOES NOT MEAN IT IS GOOD!!! USE THE BEST PACKAGE AND LATEST VERSION LIKE A NORMAL PERSON WOULD!

Check a library's repository for its latest release tag (and whether it is still maintained) before adding or bumping it, whether it's a Rust crate, a C library we bind, or a GitHub Action in the workflows. The same goes for APIs: target current ones (SDL3, not SDL2; WebGPU, not OpenGL fallbacks; current QUIC drafts that noq implements).

## Keep things human

Do not use em dashes or other special symbols not normally found in writing. Do not word things in a weird way. Keep it looking human. If you need to use, for example, an arrow icon, use an SVG instead.

Replacing an em dash with a hyphen is NOT a fix. A spaced hyphen doing an em dash's job ("the limit - 4 bytes", "fast - but wrong") is the same tic with a different character. Reword the sentence instead: use a comma, a colon, parentheses, or the actual word ("minus", "to", "through"). Plain hyphens in compound words and numeric ranges like 0-1 are fine.

## Use American spelling

It's fine to be British in the chat if the person is actually in a region where it's spelled like that. But if not, just use American spelling. The thing itself MUST use American spelling.
